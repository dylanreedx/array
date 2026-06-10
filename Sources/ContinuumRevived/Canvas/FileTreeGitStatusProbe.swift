import ContinuumRevivedCore
import Foundation

public struct FileTreeGitStatusProbe: Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func statuses(root: URL) -> [String: FileTreeGitStatus] {
        let root = root.standardizedFileURL
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-git-status-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            fputs("FileTreeGitStatusProbe could not open temporary output file\n", stderr)
            return [:]
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "status", "--porcelain=v1", "-z"]
        process.standardOutput = outputHandle
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            fputs("FileTreeGitStatusProbe git launch failed: \(error.localizedDescription)\n", stderr)
            return [:]
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            fputs("FileTreeGitStatusProbe git status timed out for \(root.path)\n", stderr)
            return [:]
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            fputs("FileTreeGitStatusProbe git status failed for \(root.path)\n", stderr)
            return [:]
        }

        guard let data = try? Data(contentsOf: outputURL) else {
            fputs("FileTreeGitStatusProbe could not read git status output\n", stderr)
            return [:]
        }
        return Self.parsePorcelain(data)
    }

    public static func parsePorcelain(_ data: Data) -> [String: FileTreeGitStatus] {
        guard data.isEmpty || data.last == 0 else {
            return [:]
        }

        let parts = data.split(separator: 0, omittingEmptySubsequences: true)
        var statuses: [String: FileTreeGitStatus] = [:]
        var index = 0

        while index < parts.count {
            let entry = parts[index]
            guard entry.count >= 4,
                  let statusCode = String(bytes: entry.prefix(2), encoding: .utf8),
                  entry.dropFirst(2).first == 0x20,
                  let path = String(bytes: entry.dropFirst(3), encoding: .utf8),
                  let status = gitStatus(for: statusCode) else {
                return [:]
            }

            statuses[path] = status
            index += 1

            if statusCode.contains("R") || statusCode.contains("C") {
                guard index < parts.count else {
                    return [:]
                }
                index += 1
            }
        }

        return statuses
    }

    private static func gitStatus(for statusCode: String) -> FileTreeGitStatus? {
        if statusCode == "??" {
            return .untracked
        }

        if statusCode.contains("U")
            || statusCode == "AA"
            || statusCode == "DD"
            || statusCode == "AU"
            || statusCode == "UA"
            || statusCode == "DU"
            || statusCode == "UD" {
            return .conflicted
        }

        if statusCode.contains("R") || statusCode.contains("C") {
            return .renamed
        }

        if statusCode.contains("A") {
            return .added
        }

        if statusCode.contains("D") {
            return .deleted
        }

        if statusCode.contains("M") || statusCode.contains("T") {
            return .modified
        }

        return nil
    }
}
