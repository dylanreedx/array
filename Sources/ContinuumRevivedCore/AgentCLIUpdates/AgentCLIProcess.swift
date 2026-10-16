#if os(macOS)
import Foundation
import Darwin

/// Bounded, shell-free subprocesses for CLI maintenance: `--version` reads,
/// `brew info`, and the update itself. Explicit argv, an explicit environment
/// built from nothing, stdin on /dev/null (so nothing can sit waiting on a
/// password prompt), its own process group so a timeout stops everything it
/// started, and a capped output tail.
public enum AgentCLIProcess {
    public struct Outcome: Equatable, Sendable {
        /// Nil when the process never launched or was killed at the deadline.
        public let exitCode: Int32?
        public let output: String
        public let timedOut: Bool
        public let launchError: String?
    }

    /// Keeps the last `limit` bytes, trimmed to a line start.
    final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int) { self.limit = max(256, limit) }

        func append(_ chunk: Data) -> String {
            lock.withLock {
                data.append(chunk)
                if data.count > limit {
                    var cut = data.count - limit
                    if let newline = data[(data.startIndex + cut)...].firstIndex(of: 0x0A) {
                        cut = newline - data.startIndex + 1
                    }
                    data = Data(data.suffix(from: data.startIndex + cut))
                }
                return String(decoding: data, as: UTF8.self)
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// Runs `argv` to completion or `timeout`, streaming the combined
    /// stdout+stderr tail to `onOutput` from a background thread.
    public static func run(
        argv: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        outputLimit: Int = 16 * 1024,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) -> Outcome {
        guard let executable = argv.first else {
            return Outcome(exitCode: nil, output: "", timedOut: false, launchError: "empty command")
        }
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(
                executable: executable, arguments: Array(argv.dropFirst()), environment: environment,
                currentDirectory: currentDirectory, standardInput: .nullDevice)
        } catch {
            return Outcome(exitCode: nil, output: "", timedOut: false, launchError: "\(error)")
        }
        let tail = Tail(limit: outputLimit)
        let readers = DispatchGroup()
        for handle in [child.standardOutput, child.standardError] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                let descriptor = handle.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
                    if count > 0 {
                        let text = tail.append(Data(buffer.prefix(count)))
                        onOutput?(text)
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var raw: Int32?
        while raw == nil {
            raw = child.pollExitRaw()
            if raw != nil { break }
            if Date() >= deadline {
                child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.harness)
                _ = readers.wait(timeout: .now() + 2)
                try? child.standardOutput.close()
                try? child.standardError.close()
                return Outcome(exitCode: nil, output: tail.text, timedOut: true, launchError: nil)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // A finished leader can leave a descendant holding the pipes; the
        // update is done either way, so the group is not allowed to linger.
        if readers.wait(timeout: .now() + 2) == .timedOut {
            child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
            _ = readers.wait(timeout: .now() + 1)
        }
        try? child.standardOutput.close()
        try? child.standardError.close()
        let code: Int32 = {
            let status = raw ?? 0
            if status & 0x7F == 0 { return (status >> 8) & 0xFF }
            return 128 + (status & 0x7F)
        }()
        return Outcome(exitCode: code, output: tail.text, timedOut: false, launchError: nil)
    }

    /// The environment a maintenance child gets: built from nothing, so no API
    /// key, token or credential the app inherited ever reaches an installer.
    /// Only locale/identity basics, a PATH that leads with the installer's own
    /// bin directory, and the CLIs' own config-home overrides.
    public static func environment(
        for executable: String,
        base: [String: String] = ProcessInfo.processInfo.environment,
        extraDirs: [String]? = nil
    ) -> [String: String] {
        let extraDirs = extraDirs ?? PiAgentRunner.liveExtraDirs()
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                    "CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR"] {
            if let value = base[key], !value.isEmpty { environment[key] = value }
        }
        let leading = (executable as NSString).deletingLastPathComponent
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = ([leading] + extraDirs + system).filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["npm_config_update_notifier"] = "false"
        environment["npm_config_fund"] = "false"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        return environment
    }

    /// `<executable> --version`, parsed. Nil on any failure.
    public static func readVersion(
        executable: String,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) -> String? {
        let outcome = run(argv: [executable, "--version"],
                          environment: environment ?? Self.environment(for: executable),
                          currentDirectory: FileManager.default.temporaryDirectory,
                          timeout: timeout, outputLimit: 4096)
        guard outcome.exitCode == 0 else { return nil }
        return AgentCLIVersion.parse(versionOutput: outcome.output)
    }
}
#endif
