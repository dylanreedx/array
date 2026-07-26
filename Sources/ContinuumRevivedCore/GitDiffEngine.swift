import Foundation

public struct GitDiffEngine {
    public struct Configuration: Sendable {
        public var timeoutSeconds: TimeInterval
        public var maxOutputBytes: Int
        public init(timeoutSeconds: TimeInterval = 5, maxOutputBytes: Int = 1_000_000) {
            self.timeoutSeconds = timeoutSeconds
            self.maxOutputBytes = maxOutputBytes
        }
    }

    public enum Source: Equatable, Sendable {
        case workingTreeVsHEAD
        case branchVsBase(branch: String, base: String)
    }

    public enum DiffError: Error, Equatable, Sendable, CustomStringConvertible {
        case gitFailed(exitCode: Int32, stderr: String)
        case timedOut
        case outputTooLarge(limit: Int)
        case invalidRepository(String)

        public var description: String {
            switch self {
            case let .gitFailed(exitCode, stderr): return "git diff failed (\(exitCode)): \(stderr)"
            case .timedOut: return "git diff timed out"
            case let .outputTooLarge(limit): return "git diff exceeded \(limit) bytes"
            case let .invalidRepository(path): return "not a readable repository: \(path)"
            }
        }
    }

    public var configuration: Configuration
    private let gitExecutableURL: URL

    public init(configuration: Configuration = .init(), gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.configuration = configuration
        self.gitExecutableURL = gitExecutableURL
    }

    public func diff(repositoryURL: URL, source: Source) throws -> GitDiffModel {
        guard FileManager.default.fileExists(atPath: repositoryURL.path) else {
            throw DiffError.invalidRepository(repositoryURL.path)
        }
        var arguments = ["diff", "--no-ext-diff", "--find-renames"]
        switch source {
        case .workingTreeVsHEAD:
            arguments.append("HEAD")
        case let .branchVsBase(branch, base):
            arguments.append("\(base)...\(branch)")
        }
        let output = try runGit(arguments: arguments, repositoryURL: repositoryURL)
        return GitDiffParser.parse(output)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P2C.5-per-agent-diff.md
    //
    // How big is this change? — asked per row, so it must not depend on parsing
    // the diff BODY. `diff(repositoryURL:source:)` reads every hunk line and is
    // capped at `maxOutputBytes` (1MB by default), so a large agent diff answers
    // `outputTooLarge` rather than a number. `--numstat` is three fields per
    // FILE, so the same change is orders of magnitude smaller on the wire and the
    // counts survive where the full payload does not.
    public struct Counts: Equatable, Sendable {
        public var filesChanged: Int
        public var insertions: Int
        public var deletions: Int

        public init(filesChanged: Int, insertions: Int, deletions: Int) {
            self.filesChanged = filesChanged
            self.insertions = insertions
            self.deletions = deletions
        }

        public static let zero = Counts(filesChanged: 0, insertions: 0, deletions: 0)
    }

    public func counts(repositoryURL: URL, source: Source) throws -> Counts {
        guard FileManager.default.fileExists(atPath: repositoryURL.path) else {
            throw DiffError.invalidRepository(repositoryURL.path)
        }
        var arguments = ["diff", "--no-ext-diff", "--find-renames", "--numstat"]
        switch source {
        case .workingTreeVsHEAD:
            arguments.append("HEAD")
        case let .branchVsBase(branch, base):
            arguments.append("\(base)...\(branch)")
        }
        return Self.parseNumstat(try runGit(arguments: arguments, repositoryURL: repositoryURL))
    }

    /// Parses `git diff --numstat`: `<insertions>\t<deletions>\t<path>` per file.
    /// Pure, so the format handling is testable without a repository.
    ///
    /// A BINARY file prints `-` for both counts. It is still a changed file, so it
    /// counts as one — dropping the row would under-report the change, and reading
    /// the `-` as zero-and-therefore-unchanged would too.
    public static func parseNumstat(_ text: String) -> Counts {
        var counts = Counts.zero
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            counts.filesChanged += 1
            counts.insertions += Int(fields[0]) ?? 0
            counts.deletions += Int(fields[1]) ?? 0
        }
        return counts
    }

    private func runGit(arguments: [String], repositoryURL: URL) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let output = GitDiffProcessOutput(limit: configuration.maxOutputBytes)
        let error = GitDiffProcessOutput(limit: Int.max)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if output.append(chunk), process.isRunning { process.terminate() }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            _ = error.append(chunk)
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            if output.exceededLimit { process.terminate() }
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { process.interrupt() }
            throw DiffError.timedOut
        }
        Thread.sleep(forTimeInterval: 0.02)

        let outputData = output.data
        let errorData = error.data
        if output.exceededLimit || outputData.count > configuration.maxOutputBytes { throw DiffError.outputTooLarge(limit: configuration.maxOutputBytes) }
        if process.terminationStatus != 0 {
            throw DiffError.gitFailed(exitCode: process.terminationStatus, stderr: String(data: errorData, encoding: .utf8) ?? "")
        }
        return String(data: outputData, encoding: .utf8) ?? ""
        #else
        _ = arguments
        _ = repositoryURL
        throw DiffError.invalidRepository("git diff is only available on macOS")
        #endif
    }
}

#if os(macOS)
private final class GitDiffProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()
    private let limit: Int
    private(set) var exceededLimit = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        data.append(chunk)
        if data.count > limit { exceededLimit = true }
        let result = exceededLimit
        lock.unlock()
        return result
    }
}
#endif

public struct GitDiffModel: Equatable, Codable, Sendable {
    public var files: [GitDiffFile]
    public init(files: [GitDiffFile]) { self.files = files }
}

public struct GitDiffFile: Equatable, Codable, Sendable {
    public enum Change: String, Codable, Sendable { case added, modified, deleted, renamed, binary }
    public var oldPath: String?
    public var newPath: String?
    public var change: Change
    public var hunks: [GitDiffHunk]
    public var isBinary: Bool

    public init(oldPath: String?, newPath: String?, change: Change, hunks: [GitDiffHunk] = [], isBinary: Bool = false) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.change = change
        self.hunks = hunks
        self.isBinary = isBinary
    }
}

public struct GitDiffHunk: Equatable, Codable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var header: String
    public var lines: [GitDiffLine]
    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String, lines: [GitDiffLine]) {
        self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart; self.newCount = newCount; self.header = header; self.lines = lines
    }
}

public struct GitDiffLine: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, addition, deletion, metadata }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.kind = kind; self.text = text; self.oldLine = oldLine; self.newLine = newLine
    }
}

public enum GitDiffParser {
    public static func parse(_ text: String) -> GitDiffModel {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: [GitDiffFile] = []
        var current: GitDiffFile?
        var currentHunk: GitDiffHunk?
        var oldLine = 0
        var newLine = 0

        func finishHunk() {
            if let h = currentHunk { current?.hunks.append(h) }
            currentHunk = nil
        }
        func finishFile() {
            finishHunk()
            if var f = current {
                if f.isBinary { f.change = .binary }
                files.append(f)
            }
            current = nil
        }
        func cleanPath(_ raw: String) -> String? {
            if raw == "/dev/null" { return nil }
            if raw.hasPrefix("a/") || raw.hasPrefix("b/") { return String(raw.dropFirst(2)) }
            return raw
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finishFile()
                let parts = line.split(separator: " ").map(String.init)
                current = GitDiffFile(oldPath: parts.count > 2 ? cleanPath(parts[2]) : nil, newPath: parts.count > 3 ? cleanPath(parts[3]) : nil, change: .modified)
            } else if line.hasPrefix("new file mode") {
                current?.change = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.change = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = String(line.dropFirst("rename from ".count)); current?.change = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.newPath = String(line.dropFirst("rename to ".count)); current?.change = .renamed
            } else if line.hasPrefix("Binary files ") {
                current?.isBinary = true
            } else if line.hasPrefix("--- ") {
                current?.oldPath = cleanPath(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                current?.newPath = cleanPath(String(line.dropFirst(4)))
            } else if line.hasPrefix("@@ ") {
                finishHunk()
                let parsed = parseHunkHeader(line)
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                currentHunk = GitDiffHunk(oldStart: parsed.oldStart, oldCount: parsed.oldCount, newStart: parsed.newStart, newCount: parsed.newCount, header: parsed.header, lines: [])
            } else if currentHunk != nil {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    currentHunk?.lines.append(.init(kind: .addition, text: String(line.dropFirst()), oldLine: nil, newLine: newLine)); newLine += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    currentHunk?.lines.append(.init(kind: .deletion, text: String(line.dropFirst()), oldLine: oldLine, newLine: nil)); oldLine += 1
                } else if line.hasPrefix("\\") {
                    currentHunk?.lines.append(.init(kind: .metadata, text: line, oldLine: nil, newLine: nil))
                } else {
                    let body = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                    currentHunk?.lines.append(.init(kind: .context, text: body, oldLine: oldLine, newLine: newLine)); oldLine += 1; newLine += 1
                }
            }
        }
        finishFile()
        return GitDiffModel(files: files)
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String) {
        let scanner = Scanner(string: line)
        _ = scanner.scanString("@@ -")
        let oldStart = scanner.scanInt() ?? 0
        let oldCount = scanner.scanString(",") == nil ? 1 : (scanner.scanInt() ?? 1)
        _ = scanner.scanString(" +")
        let newStart = scanner.scanInt() ?? 0
        let newCount = scanner.scanString(",") == nil ? 1 : (scanner.scanInt() ?? 1)
        return (oldStart, oldCount, newStart, newCount, line)
    }
}
