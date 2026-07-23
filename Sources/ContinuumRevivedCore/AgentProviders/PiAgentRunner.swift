import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md
//
// The IMPURE half of the Pi adapter: spawn `pi -p --mode json`, stream its
// stdout line-by-line through the (pure, tested) PiEventTranslator, and hand
// each normalized AgentRuntimeEvent to a callback as it arrives. Streaming is
// the point — the tile updates turn-by-turn, not at the end.
//
// Thread-safety: FileHandle readability callbacks fire on a background queue;
// the translator + line buffer are confined to `queue`, so translation stays
// serial and the caller only ever sees events (which it hops to the main
// actor itself).
public final class PiAgentRunner: @unchecked Sendable {
    public struct Config: Sendable {
        public var model: String
        public var cwd: URL
        /// Stable Pi session id. When set, every prompt runs `--session-id <id>`
        /// so turns CONTINUE the same conversation (memory across prompts); Pi
        /// creates the session on first use and resumes it after. `nil` runs
        /// `--no-session` (ephemeral, one-shot) — used by the smoke harness.
        public var sessionId: String?
        /// Extra args before the prompt. The runner always adds
        /// `-p --mode json <model>` and the session flag.
        public var extraArgs: [String]

        public init(model: String = "openai-codex/gpt-5.6", cwd: URL, sessionId: String? = nil, extraArgs: [String] = []) {
            self.model = model
            self.cwd = cwd
            self.sessionId = sessionId
            self.extraArgs = extraArgs
        }
    }

    /// The Pi args after the executable (and any `/usr/bin/env` prefix): the
    /// json/model flags, the session flag, extras, then the prompt. Pure so it
    /// can be pinned in the matrix.
    public static func processArguments(model: String, sessionId: String?, extraArgs: [String], prompt: String) -> [String] {
        let sessionArgs = sessionId.map { ["--session-id", $0] } ?? ["--no-session"]
        return ["-p", "--mode", "json", "--model", model] + sessionArgs + extraArgs + [prompt]
    }

    public enum RunError: Error {
        case launchFailed(String)
        case piFailed(exitCode: Int32, stderr: String)
    }

    /// How the runner will invoke Pi: an executable + the args that must
    /// precede the model/prompt args. Either an absolute `pi` (GUI-safe) or
    /// the `/usr/bin/env pi` fallback (shell-launched, inherits PATH).
    public struct ResolvedCommand: Sendable, Equatable {
        public var executable: String
        public var prefixArgs: [String]

        public init(executable: String, prefixArgs: [String]) {
            self.executable = executable
            self.prefixArgs = prefixArgs
        }
    }

    /// Pure resolution: prefer an absolute `pi` found in `pathDirs` (the
    /// process PATH) or `extraDirs` (well-known install dirs a GUI launch
    /// omits — nvm bins, homebrew, ~/.local/bin). Falls back to
    /// `/usr/bin/env pi` when nothing is found, which still works for a
    /// shell launch that inherits a full PATH. See the ticket GUI watch-out.
    public static func resolvedCommand(
        pathDirs: [String],
        extraDirs: [String],
        fileExists: @escaping @Sendable (String) -> Bool
    ) -> ResolvedCommand {
        let detector = ToolDetector(fileExists: fileExists)
        if let absolute = detector.locate("pi", in: pathDirs + extraDirs) {
            return ResolvedCommand(executable: absolute, prefixArgs: [])
        }
        return ResolvedCommand(executable: "/usr/bin/env", prefixArgs: ["pi"])
    }

    /// Prepends `extraDirs` (that aren't already present) to `basePath`. Pi is
    /// a node script whose `#!/usr/bin/env node` shebang needs node on PATH;
    /// under a GUI-thin PATH neither pi NOR node is found, so resolving pi
    /// absolutely is not enough — the child's PATH must include the nvm/node
    /// bin. Pure + order-preserving so it can be pinned in the matrix.
    public static func augmentedPath(basePath: String, extraDirs: [String]) -> String {
        let baseDirs = ToolDetector.splitPath(basePath)
        var seen = Set(baseDirs)
        var prepend: [String] = []
        for dir in extraDirs where !dir.isEmpty && !seen.contains(dir) {
            seen.insert(dir)
            prepend.append(dir)
        }
        return (prepend + baseDirs).joined(separator: ":")
    }

    /// Well-known dirs a GUI launch omits: nvm node bins (expanded on disk,
    /// newest first), homebrew, ~/.local/bin, ~/bin. Both pi and node live in
    /// the nvm bin, so this is the dir set that fixes both lookups.
    static func liveExtraDirs() -> [String] {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/bin"
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            dirs += versions.sorted().reversed().map { "\(nvmRoot)/\($0)/bin" }
        }
        return dirs
    }

    /// Live wrapper around `resolvedCommand`: assembles the search dirs from
    /// the real environment + home, expanding nvm node versions on disk.
    static func liveResolvedCommand() -> ResolvedCommand {
        let env = ProcessInfo.processInfo.environment
        let pathDirs = ToolDetector.splitPath(env["PATH"] ?? "")
        return resolvedCommand(
            pathDirs: pathDirs,
            extraDirs: liveExtraDirs(),
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    private let config: Config
    private let queue = DispatchQueue(label: "continuum.pi-agent-runner")
    private var translator = PiEventTranslator()
    private var buffer = Data()
    private var process: Process?

    public init(config: Config) {
        self.config = config
    }

    /// Runs Pi with `prompt`, streaming events to `onEvent` until Pi exits.
    /// Blocking; call off the main thread. `onEvent` is invoked on the
    /// runner's serial queue.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let process = Process()
        // Resolve `pi` to an absolute path so a GUI-launched app (thin PATH)
        // finds it; falls back to `/usr/bin/env pi` for shell launches. See
        // the ticket GUI watch-out.
        let command = Self.liveResolvedCommand()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.prefixArgs + Self.processArguments(
            model: config.model,
            sessionId: config.sessionId,
            extraArgs: config.extraArgs,
            prompt: prompt
        )
        process.currentDirectoryURL = config.cwd

        // Augment PATH so the child finds both `pi` and the `node` its shebang
        // re-invokes — a GUI launch inherits a thin PATH missing the nvm bin.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.augmentedPath(basePath: environment["PATH"] ?? "", extraDirs: Self.liveExtraDirs())
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.consume(chunk, onEvent: onEvent) }
        }

        self.process = process
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        // Flush any trailing partial line + drain whatever the handler missed.
        let remainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        queue.sync {
            if !remainder.isEmpty { consume(remainder, onEvent: onEvent) }
            flushBuffer(onEvent: onEvent)
        }

        if process.terminationStatus != 0 {
            let errText = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RunError.piFailed(exitCode: process.terminationStatus, stderr: errText)
        }
    }

    public func stop() {
        process?.terminate()
    }

    // MARK: - queue-confined line assembly

    private func consume(_ chunk: Data, onEvent: @Sendable (AgentRuntimeEvent) -> Void) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            emit(lineData, onEvent: onEvent)
        }
    }

    private func flushBuffer(onEvent: @Sendable (AgentRuntimeEvent) -> Void) {
        guard !buffer.isEmpty else { return }
        emit(buffer[...], onEvent: onEvent)
        buffer.removeAll()
    }

    private func emit(_ lineData: Data.SubSequence, onEvent: @Sendable (AgentRuntimeEvent) -> Void) {
        guard let line = String(data: Data(lineData), encoding: .utf8) else { return }
        for event in translator.translate(line: line) {
            onEvent(event)
        }
    }
}
