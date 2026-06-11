import ContinuumRevivedCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct FileTreeGitStatusProbe: Sendable {
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let maxOutputBytes: Int
    private let environment: [String: String]?
    private let executableURL: URL
    private let argumentPrefix: [String]

    public init(
        timeout: TimeInterval = 5,
        terminationGrace: TimeInterval = 0.5,
        maxOutputBytes: Int = 1_048_576,
        environment: [String: String]? = nil,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        argumentPrefix: [String] = ["git"]
    ) {
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.maxOutputBytes = maxOutputBytes
        self.environment = environment
        self.executableURL = executableURL
        self.argumentPrefix = argumentPrefix
    }

    public func statuses(root: URL) -> [String: FileTreeGitStatus] {
        let root = root.standardizedFileURL
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argumentPrefix + ["-C", root.path, "status", "--porcelain=v1", "-z"]
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outputState = OutputState(maxBytes: maxOutputBytes)
        do {
            try process.run()
        } catch {
            fputs("FileTreeGitStatusProbe git launch failed: \(error.localizedDescription)\n", stderr)
            return [:]
        }

        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stdoutPipe.fileHandleForReading, into: outputState)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stderrPipe.fileHandleForReading, into: nil)
            drainGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !outputState.exceededCap {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let exceededCap = outputState.exceededCap
        if process.isRunning {
            terminate(process, grace: terminationGrace)
            if exceededCap {
                fputs("FileTreeGitStatusProbe git status exceeded output cap for \(root.path)\n", stderr)
            } else {
                fputs("FileTreeGitStatusProbe git status timed out for \(root.path)\n", stderr)
            }
            _ = drainGroup.wait(timeout: .now() + 0.5)
            return [:]
        }

        _ = drainGroup.wait(timeout: .now() + 0.5)
        guard !outputState.exceededCap else {
            fputs("FileTreeGitStatusProbe git status exceeded output cap for \(root.path)\n", stderr)
            return [:]
        }

        guard process.terminationStatus == 0 else {
            fputs("FileTreeGitStatusProbe git status failed for \(root.path)\n", stderr)
            return [:]
        }

        guard let data = outputState.dataIfWithinCap else {
            fputs("FileTreeGitStatusProbe git status exceeded output cap for \(root.path)\n", stderr)
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

private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var output = Data()
    private var capExceeded = false

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    var exceededCap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capExceeded
    }

    var dataIfWithinCap: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capExceeded ? nil : output
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty else { return }
        let remaining = maxBytes - output.count
        if remaining <= 0 {
            capExceeded = true
            return
        }
        if chunk.count > remaining {
            output.append(chunk.prefix(remaining))
            capExceeded = true
        } else {
            output.append(chunk)
        }
    }
}

private func drain(_ handle: FileHandle, into outputState: OutputState?) {
    while true {
        let chunk = handle.readData(ofLength: 16 * 1024)
        if chunk.isEmpty {
            break
        }
        outputState?.append(chunk)
    }
}

private func terminate(_ process: Process, grace: TimeInterval) {
    process.terminate()
    let graceDeadline = Date().addingTimeInterval(grace)
    while process.isRunning && Date() < graceDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }

    guard process.isRunning else { return }
#if canImport(Darwin)
    kill(process.processIdentifier, SIGKILL)
#endif
    let killDeadline = Date().addingTimeInterval(max(0.2, grace))
    while process.isRunning && Date() < killDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
}
