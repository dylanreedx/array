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
//
// macOS-only: `Process` does not exist on iOS, and spawning a provider is
// inherently a desktop job — the phone OBSERVES agents (via the synced activity
// timeline) and never runs one. Same guard convention as the other
// Process-using Core types (RemoteSession, GitDiffEngine, ProcessTmuxControl).
// The pure halves of the adapter (PiEventTranslator,
// ManagedAgentActivityBridge) stay cross-platform.
#if os(macOS)

public final class PiAgentRunner: @unchecked Sendable {
    public struct Config: Sendable {
        public var model: String
        /// Pi `--thinking` level. Explicit for the same reason `model` is: the
        /// provider's implicit default is not ours to guess.
        public var thinking: String
        public var cwd: URL
        /// Stable Pi session id. When set, every prompt runs `--session-id <id>`
        /// so turns CONTINUE the same conversation (memory across prompts); Pi
        /// creates the session on first use and resumes it after. `nil` runs
        /// `--no-session` (ephemeral, one-shot) — used by the smoke harness.
        public var sessionId: String?
        /// Extra args before the prompt. The runner always adds
        /// `-p --mode json <model> --thinking <level>` and the session flag.
        public var extraArgs: [String]
        /// C8: `-e <path>` args for pi's extension loader — loads
        /// continuum-spawn-agent.ts so pi's `spawn_agent` tool registers.
        /// Defaults from `PiAgentRunner.installedExtensionPaths()`, which
        /// checks the real file's presence and resolves to `[]` if it isn't
        /// there (a `-e` pointed at a missing file is worse than no `-e`).
        public var extensionPaths: [String]

        /// `model`/`thinking` default from `AgentModelConfig` (Settings ▸ Agents),
        /// so changing the picker changes what the next prompt spawns.
        public init(
            model: String = AgentModelConfig.resolvedFromDefaults(harness: .pi).model,
            thinking: String = AgentModelConfig.resolvedFromDefaults(harness: .pi).thinking,
            cwd: URL,
            sessionId: String? = nil,
            extraArgs: [String] = [],
            extensionPaths: [String] = PiAgentRunner.installedExtensionPaths()
        ) {
            self.model = model
            self.thinking = thinking
            self.cwd = cwd
            self.sessionId = sessionId
            self.extraArgs = extraArgs
            self.extensionPaths = extensionPaths
        }
    }

    /// C8: the real, on-disk `-e` argument for a live Pi spawn — checks
    /// whether `PiExtensionInstaller`'s destination actually holds the file
    /// (its own `install()` may never have run, or a user could have removed
    /// it) and resolves to `[]` rather than pointing `-e` at a path that does
    /// not exist. This is the ONE place in the adapter that touches the
    /// filesystem for this; `processArguments` itself stays pure below.
    /// `fileExists` is injectable (same convention as `resolvedCommand`) so a
    /// check can pin both outcomes without touching the real ~/.pi.
    public static func installedExtensionPaths(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        let path = PiExtensionInstaller.defaultExtensionsDirectory()
            .appendingPathComponent(PiExtensionInstaller.extensionFileName).path
        return fileExists(path) ? [path] : []
    }

    /// The Pi args after the executable (and any `/usr/bin/env` prefix): the
    /// json/model flags, the session flag, extension loads, extras, then the
    /// provider prompt segments. Pure — no default reads the filesystem or
    /// the environment — so it can be pinned in the matrix. `Config`'s own
    /// `extensionPaths` (impure, resolved once per `Config`) is what actually
    /// reaches a live Pi spawn; see `run()`.
    public static func processArguments(model: String, thinking: String, sessionId: String?, extraArgs: [String], prompt: AgentPrompt, extensionPaths: [String] = []) -> [String] {
        let sessionArgs = sessionId.map { ["--session-id", $0] } ?? ["--no-session"]
        let extensionArgs = extensionPaths.flatMap { ["-e", $0] }
        return ["-p", "--mode", "json", "--model", model, "--thinking", thinking]
            + sessionArgs
            + extensionArgs
            + extraArgs
            + promptArgumentSegments(prompt)
    }

    /// Text-only compatibility wrapper. Keeps the historical argv byte shape
    /// for callers that have not adopted local attachments.
    public static func processArguments(model: String, thinking: String, sessionId: String?, extraArgs: [String], prompt: String, extensionPaths: [String] = []) -> [String] {
        processArguments(
            model: model,
            thinking: thinking,
            sessionId: sessionId,
            extraArgs: extraArgs,
            prompt: AgentPrompt(prompt),
            extensionPaths: extensionPaths
        )
    }

    /// Pi's print boundary receives safe argv elements, not a shell command.
    /// The visible text stays separate from local image path capabilities, and
    /// each image is materialized as its own `@/local/file` token.
    public static func promptArgumentSegments(_ prompt: AgentPrompt) -> [String] {
        var segments: [String] = []
        if !prompt.text.isEmpty { segments.append(prompt.text) }
        segments.append(contentsOf: prompt.imageAttachments.map(\.piPathReference))
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.isEmpty ? [""] : segments
    }

    public enum RunError: Error, CustomStringConvertible {
        case launchFailed(String)
        case piFailed(exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .piFailed(let exitCode, let stderr):
                return "piFailed(exitCode: \(exitCode), stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
            }
        }
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

    /// C8: the default `-e` argument for `processArguments` — the path Pi
    /// loads continuum-spawn-agent.ts from once `PiExtensionInstaller` has put
    /// it there (`~/.pi/agent/extensions/`, confirmed against pi's own
    /// resource-loader.js: `getAgentDir()` + "extensions"). A home-directory
    /// string, not a filesystem read, so `processArguments` stays pure.
    public static func installedExtensionPaths() -> [String] {
        [PiExtensionInstaller.defaultExtensionsDirectory()
            .appendingPathComponent(PiExtensionInstaller.extensionFileName).path]
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

    /// Descendants of a managed runner remain attributable to the GUI host on
    /// macOS. Mark that boundary so repositories which deliberately spawn
    /// crashing negative witnesses can defer only those witnesses while they are
    /// being worked on from inside Array. Ordinary external matrix/CI runs do not
    /// carry this marker and retain the full crash-witness coverage.
    public static let arrayHostedEnvironmentKey = "CONTINUUM_ARRAY_MANAGED_AGENT"

    public static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        extraDirs: [String]? = nil
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = augmentedPath(
            basePath: environment["PATH"] ?? "",
            extraDirs: extraDirs ?? liveExtraDirs())
        environment[arrayHostedEnvironmentKey] = "1"
        return environment
    }

    /// Readable so a check can assert what the PRODUCTION runner was configured
    /// with — P2C.2 needs `cwd` to be the agent's worktree, and an injected fake
    /// runner cannot witness that (from the cross-review).
    public let config: Config
    private let queue = DispatchQueue(label: "continuum.pi-agent-runner")
    private var translator: PiEventTranslator
    private var buffer = Data()
    private var stderrBuffer = Data()   // queue-confined
    private var stopRequested = false   // queue-confined (M1.7); a stopped run is not a failed one
    /// M1.8: a `ProcessGroupChild`, not a Foundation `Process`. `Process.terminate()`
    /// signals ONE pid, so every shell, MCP server and tool subprocess pi launched
    /// survived a Stop. Queue-confined (set in run, read in stop).
    private var child: ProcessGroupChild?

    public init(config: Config) {
        self.config = config
        self.translator = PiEventTranslator(workingDirectory: config.cwd)
    }

    /// Runs Pi with `prompt`, streaming events to `onEvent` until Pi exits.
    /// Blocking; call off the main thread. `onEvent` is invoked on the
    /// runner's serial queue.
    public func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        // Resolve `pi` to an absolute path so a GUI-launched app (thin PATH)
        // finds it; falls back to `/usr/bin/env pi` for shell launches. See
        // the ticket GUI watch-out.
        let command = Self.liveResolvedCommand()
        let arguments = command.prefixArgs + Self.processArguments(
            model: config.model,
            thinking: config.thinking,
            sessionId: config.sessionId,
            extraArgs: config.extraArgs,
            prompt: prompt,
            extensionPaths: config.extensionPaths
        )

        queue.sync { buffer.removeAll(); stderrBuffer.removeAll() }

        let spawned: ProcessGroupChild
        do {
            spawned = try ProcessGroupChild.spawn(
                executable: command.executable,
                arguments: arguments,
                // Augment PATH so the child finds both `pi` and the `node` its shebang
                // re-invokes — a GUI launch inherits a thin PATH missing the nvm bin.
                environment: Self.childEnvironment(),
                currentDirectory: config.cwd,
                // pi inherits the app's stdin, exactly as it did under `Process`.
                standardInput: .inherit
            )
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        queue.sync { self.child = spawned }

        spawned.standardOutput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.consume(chunk, onEvent: onEvent) }
        }
        // Drain stderr CONCURRENTLY. Reading it only after waitUntilExit() lets
        // a chatty child fill its stderr pipe (~64KB) and block forever while
        // we block in waitUntilExit — a deadlock. Accumulate on the queue.
        spawned.standardError.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.stderrBuffer.append(chunk) }
        }

        let exitCode = spawned.wait()
        spawned.standardOutput.readabilityHandler = nil
        spawned.standardError.readabilityHandler = nil

        // Flush any trailing partial line + drain whatever the handlers missed.
        // Bounded, never `readDataToEndOfFile()`: a descendant that inherited
        // fd 1/2 keeps the write end open after the leader exits, and the
        // unbounded read then blocks until that process dies — potentially
        // forever. Kill the group's leftovers first so the pipes close (a clean
        // exit leaves nothing, making this a no-op).
        spawned.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        let remainder = ProcessGroupChild.drainRemainder(of: spawned.standardOutput)
        let stderrRemainder = ProcessGroupChild.drainRemainder(of: spawned.standardError)
        let errText: String = queue.sync {
            if !remainder.isEmpty { consume(remainder, onEvent: onEvent) }
            flushBuffer(onEvent: onEvent)
            stderrBuffer.append(stderrRemainder)
            let text = String(decoding: stderrBuffer, as: UTF8.self)
            self.child = nil
            return text
        }

        if exitCode != 0 {
            // M1.7: pi had NO stop flag at all -- `stop()` terminated the child and
            // this line then reported the resulting non-zero exit as a failure.
            if queue.sync { stopRequested } { throw AgentRunStopped(detail: errText) }
            throw RunError.piFailed(exitCode: exitCode, stderr: errText)
        }
    }

    /// Text-only compatibility wrapper for existing managed-agent callers.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    public func stop() {
        // M1.8: the whole GROUP, with escalation, at the interactive grace -- a
        // human is watching the button. `Process.terminate()` signalled the pi
        // leader alone and left everything it had launched running.
        let running = queue.sync { () -> ProcessGroupChild? in
            stopRequested = true
            return child
        }
        running?.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
    }

    /// P2D.2 — observe `spawn_agent` calls this agent makes, out of band.
    ///
    /// Set before `run`. The handler is invoked on the runner's serial queue (the
    /// same confinement the translator has), so a caller that needs the main actor
    /// hops itself, exactly as it already does for events.
    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        queue.sync { translator.onSpawnRequest = handler }
    }

    /// Queue 91 P2 — observe the private cwd/tool projection without widening
    /// AgentRuntimeEvent. Set before `run`; callbacks use this runner's serial
    /// queue, matching spawn observations and normalized event ordering.
    public func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {
        queue.sync { translator.onRuntimeObservation = handler }
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

extension PiAgentRunner: ObservedRunReporting {
    /// Where a `delegate_agent` child's transcript will be. Same confinement as
    /// `observeSpawnRequests`: set before `run`, delivered on the runner's serial
    /// queue, so a caller needing the main actor hops itself.
    public func observeObservedRuns(_ handler: @escaping @Sendable (ObservedRunHandle) -> Void) {
        queue.sync { translator.onObservedRun = handler }
    }
}

#endif  // os(macOS)
