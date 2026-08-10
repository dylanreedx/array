import Foundation

// Plan: .plans/01-provider-cli-backends.md (claude CLI backend, first slice).
//
// The IMPURE half of the claude adapter: spawn the user's own `claude` binary
// headlessly (`-p --output-format stream-json`) and stream its stdout through
// the (pure, pinned) ClaudeEventTranslator. Compliance posture is the whole
// point of this backend: Array never touches credentials — the binary does
// its own subscription OAuth exactly as it would in a terminal, which is the
// pattern Anthropic sanctions for third-party orchestrators (their
// enforcement targets clients that extract the OAuth token and call the API
// themselves — pi's anthropic path — never local spawning of the real CLI).
//
// Session continuity mirrors the pi design: the id is DERIVED, not stored.
// Claude requires a literal UUID, so the agent record's own UUID is the
// session id (`ClaudeAgentRunner.sessionId(for:)` in AgentSupervisor). Every
// run tries `--resume <uuid>` first; the very first turn of an agent fails
// that instantly ("No conversation found", no API call, verified live on
// claude 2.1.226) and is retried once with `--session-id <uuid>`, which
// creates the conversation. Stateless and self-healing in both directions —
// no record field, no session file path coupling.
public enum ClaudeCLIBackend {
    /// Which runtime a managed agent's model routes to. Pure so the matrix can
    /// pin the policy. Anthropic models prefer the claude CLI when the machine
    /// has it: subscription-correct (no pi OAuth metering) and pi-free.
    public static func routesToClaude(model: String, claudeCLIAvailable: Bool) -> Bool {
        claudeCLIAvailable && model.hasPrefix("anthropic/")
    }

    /// `provider/model` catalogue id → the claude CLI `--model` argument.
    /// Claude takes the bare model name or alias; the provider prefix is
    /// Array's namespacing. Pass-through when there is no prefix.
    public static func modelArgument(forCatalogId id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// pi `--thinking` level → claude `--effort` level. Only exact matches
    /// pass through; anything else (off/minimal/unknown) omits the flag and
    /// takes the CLI's own default rather than inventing a mapping.
    public static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    public static func effortArgument(forThinking thinking: String) -> String? {
        effortLevels.contains(thinking) ? thinking : nil
    }

    /// The catalogue entries the claude backend contributes when the CLI is
    /// present and logged in. These are claude's own documented ALIASES —
    /// deterministic names the CLI resolves to its latest models — not
    /// patterns, so the exact-id rule holds. pi's fully-qualified anthropic
    /// ids (when pi is also installed) route to the same backend.
    public static let curatedCatalogModels: [String] = [
        "anthropic/opus",
        "anthropic/sonnet",
        "anthropic/haiku",
    ]
    public static let curatedCatalogDisplayNames: [String: String] = [
        "anthropic/opus": "Claude Opus (latest)",
        "anthropic/sonnet": "Claude Sonnet (latest)",
        "anthropic/haiku": "Claude Haiku (latest)",
    ]

    /// `claude auth status --json` → is a subscription login present. Pure —
    /// pinned against the real output shape. Array only ever READS readiness;
    /// the login itself always happens in the user's own terminal.
    public static func isLoggedIn(authStatusJSON data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return (object["loggedIn"] as? Bool) ?? false
    }

    /// The distinguishing stderr of `--resume <id>` on a conversation that
    /// does not exist yet — the trigger for the one-shot `--session-id` retry.
    public static func isUnknownSessionFailure(stderr: String) -> Bool {
        stripANSI(stderr).contains("No conversation found with session ID")
    }

    /// The inverse failure (`--session-id` on an existing conversation).
    /// Reaching this after a resume-first attempt means a concurrent writer
    /// raced us; it is terminal, not retryable.
    public static func isSessionInUseFailure(stderr: String) -> Bool {
        stripANSI(stderr).contains("is already in use")
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

#if os(macOS)

public final class ClaudeAgentRunner: @unchecked Sendable {
    public struct Config: Sendable {
        /// Claude-native model argument (already stripped of the `anthropic/`
        /// catalogue prefix — `ClaudeCLIBackend.modelArgument`).
        public var model: String
        /// Claude `--effort` level, or nil to take the CLI default.
        public var effort: String?
        public var cwd: URL
        /// The conversation UUID (claude validates the format). Derived from
        /// the agent id by the supervisor, never persisted.
        public var sessionId: String
        /// Extra args before the prompt.
        public var extraArgs: [String]

        public init(
            model: String,
            effort: String? = nil,
            cwd: URL,
            sessionId: String,
            extraArgs: [String] = []
        ) {
            self.model = model
            self.effort = effort
            self.cwd = cwd
            self.sessionId = sessionId
            self.extraArgs = extraArgs
        }
    }

    /// Whether this run continues the conversation or creates it.
    public enum SessionMode: Sendable, Equatable {
        case resume
        case start
    }

    /// The claude args after the executable. `--verbose` is required by the
    /// CLI for stream-json in print mode. `--dangerously-skip-permissions`
    /// matches what a managed tile IS today: pi runs its role's tools without
    /// asking either — a surfaced approval flow is the follow-up for both
    /// backends, not a claude regression. Pure so the matrix can pin it.
    public static func processArguments(
        model: String,
        effort: String?,
        sessionMode: SessionMode,
        sessionId: String,
        extraArgs: [String],
        prompt: AgentPrompt
    ) -> [String] {
        let sessionArgs: [String]
        switch sessionMode {
        case .resume: sessionArgs = ["--resume", sessionId]
        case .start: sessionArgs = ["--session-id", sessionId]
        }
        return ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            + ["--model", model]
            + (effort.map { ["--effort", $0] } ?? [])
            + ["--dangerously-skip-permissions"]
            + sessionArgs
            + extraArgs
            + [promptArgument(prompt)]
    }

    /// Claude takes ONE positional prompt (pi takes segments). The visible
    /// text and each attachment's `@/local/file` reference join with
    /// newlines — claude reads @-references itself, same contract as pi's.
    public static func promptArgument(_ prompt: AgentPrompt) -> String {
        var segments: [String] = []
        if !prompt.text.isEmpty { segments.append(prompt.text) }
        segments.append(contentsOf: prompt.imageAttachments.map(\.piPathReference))
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.joined(separator: "\n")
    }

    public enum RunError: Error, CustomStringConvertible {
        case launchFailed(String)
        case claudeFailed(exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .claudeFailed(let exitCode, let stderr):
                return "claudeFailed(exitCode: \(exitCode), stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
            }
        }
    }

    /// Absolute-path resolution with the same GUI-thin-PATH strategy as pi's:
    /// prefer an absolute `claude` from PATH + well-known install dirs
    /// (~/.local/bin is the native installer's home), fall back to
    /// `/usr/bin/env claude` for shell launches. Pure for pinning.
    public static func resolvedCommand(
        pathDirs: [String],
        extraDirs: [String],
        fileExists: @escaping @Sendable (String) -> Bool
    ) -> PiAgentRunner.ResolvedCommand {
        let detector = ToolDetector(fileExists: fileExists)
        if let absolute = detector.locate("claude", in: pathDirs + extraDirs) {
            return PiAgentRunner.ResolvedCommand(executable: absolute, prefixArgs: [])
        }
        return PiAgentRunner.ResolvedCommand(executable: "/usr/bin/env", prefixArgs: ["claude"])
    }

    static func liveResolvedCommand() -> PiAgentRunner.ResolvedCommand {
        let env = ProcessInfo.processInfo.environment
        let pathDirs = ToolDetector.splitPath(env["PATH"] ?? "")
        return resolvedCommand(
            pathDirs: pathDirs,
            extraDirs: PiAgentRunner.liveExtraDirs(),
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Availability = an absolute `claude` actually resolves (the env
    /// fallback proves nothing). Cheap — file stats only, no subprocess — so
    /// the supervisor can consult it on the spawn path.
    public static func liveCLIAvailable() -> Bool {
        liveResolvedCommand().prefixArgs.isEmpty
    }

    public let config: Config
    private let queue = DispatchQueue(label: "continuum.claude-agent-runner")
    private var translator: ClaudeEventTranslator
    private var buffer = Data()
    private var stderrBuffer = Data()   // queue-confined
    private var process: Process?       // queue-confined (set in run, read in stop)
    private var stopRequested = false   // queue-confined; suppresses the retry

    public init(config: Config) {
        self.config = config
        self.translator = ClaudeEventTranslator(workingDirectory: config.cwd)
    }

    /// Runs claude with `prompt`, streaming events to `onEvent` until it
    /// exits. Blocking; call off the main thread. `onEvent` is invoked on the
    /// runner's serial queue. Resume-first: the failed first-ever resume
    /// streams nothing (the translator gates on init, and the failure emits
    /// none) and is retried once as `--session-id`.
    public func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let first = try runOnce(mode: .resume, prompt: prompt, onEvent: onEvent)
        if first.exitCode == 0 { return }
        guard ClaudeCLIBackend.isUnknownSessionFailure(stderr: first.stderr) else {
            throw RunError.claudeFailed(exitCode: first.exitCode, stderr: first.stderr)
        }
        let shouldRetry: Bool = queue.sync { !stopRequested }
        guard shouldRetry else { return }
        let second = try runOnce(mode: .start, prompt: prompt, onEvent: onEvent)
        if second.exitCode != 0 {
            throw RunError.claudeFailed(exitCode: second.exitCode, stderr: second.stderr)
        }
    }

    /// Text-only compatibility wrapper, matching PiAgentRunner's.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    public func stop() {
        queue.sync {
            stopRequested = true
            process?.terminate()
        }
    }

    /// Claude has no `spawn_agent` — its Task tool spawns claude-internal
    /// sub-agents that surface as ordinary tool items. The handler is
    /// accepted for seam parity and never fires.
    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}

    public func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {
        queue.sync { translator.onRuntimeObservation = handler }
    }

    // MARK: - one spawn

    private func runOnce(
        mode: SessionMode,
        prompt: AgentPrompt,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws -> (exitCode: Int32, stderr: String) {
        let process = Process()
        let command = Self.liveResolvedCommand()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.prefixArgs + Self.processArguments(
            model: config.model,
            effort: config.effort,
            sessionMode: mode,
            sessionId: config.sessionId,
            extraArgs: config.extraArgs,
            prompt: prompt
        )
        process.currentDirectoryURL = config.cwd

        // Same GUI-thin-PATH augmentation as pi's: an npm-installed claude is
        // a node script whose shebang needs node on PATH. (The native binary
        // doesn't, but augmenting is harmless there.) HOME and
        // CLAUDE_CONFIG_DIR stay untouched — overriding HOME relocates the
        // keychain lookup and the CLI stops finding its own login.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        queue.sync { buffer.removeAll(); stderrBuffer.removeAll() }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.consume(chunk, onEvent: onEvent) }
        }
        // Drain stderr CONCURRENTLY (the pi runner's deadlock lesson: a full
        // 64KB stderr pipe blocks the child while we block in waitUntilExit).
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.stderrBuffer.append(chunk) }
        }

        queue.sync { self.process = process }
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText: String = queue.sync {
            if !remainder.isEmpty { consume(remainder, onEvent: onEvent) }
            flushBuffer(onEvent: onEvent)
            stderrBuffer.append(stderrRemainder)
            let text = String(decoding: stderrBuffer, as: UTF8.self)
            self.process = nil
            return text
        }
        return (process.terminationStatus, errText)
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

#endif  // os(macOS)
