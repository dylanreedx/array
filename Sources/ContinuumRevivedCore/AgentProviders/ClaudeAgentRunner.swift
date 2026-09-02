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
// session id (`ClaudeAgentRunner.sessionId(for:)` in AgentSupervisor). A run
// tries the mode its config believes in and retries the other on the matching
// failure ("No conversation found" / "is already in use"), so it stays
// self-healing in both directions with no session file path coupling. The belief
// is an ordering hint: an agent with no recorded turn starts with
// `--session-id <uuid>`, everything else resumes. A wrong guess costs one extra
// CLI launch and still succeeds.
/// Whether a claude run continues an existing conversation or creates it.
public enum ClaudeSessionMode: Sendable, Equatable {
    case resume
    case start
    /// B7.2 — `/clear`'s session rotation: resume the OLD session id one last
    /// time with `--fork-session`, so claude mints a NEW id Array could not
    /// have predicted. Never part of the resume/start retry pair — a fork
    /// either succeeds outright or the rotation failed outright; retrying it
    /// as an ordinary resume or start would silently abandon the rotation.
    case fork
}

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

    /// Which session mode to try first, and which is then the retry.
    ///
    /// Pure so the ordering has an offline witness: the alternative is a witness
    /// that must spawn a real `claude`, which is exactly the kind of gate that
    /// never runs in the matrix.
    public static func sessionModeOrder(
        conversationMayExist: Bool
    ) -> (first: ClaudeSessionMode, retry: ClaudeSessionMode) {
        conversationMayExist ? (.resume, .start) : (.start, .resume)
    }

    /// Whether a failed attempt in `mode` should be retried in the other mode.
    ///
    /// Each direction has exactly one retryable failure, and it is the one that
    /// means "your belief about the conversation was wrong": a resume that found
    /// no conversation, or a create that found one already there. Anything else is
    /// terminal — retrying an auth or network failure in the other mode would only
    /// spawn a second doomed process.
    public static func retryIsWarranted(after mode: ClaudeSessionMode, stderr: String) -> Bool {
        switch mode {
        case .resume: return isUnknownSessionFailure(stderr: stderr)
        case .start: return isSessionInUseFailure(stderr: stderr)
        case .fork:
            // Unreachable in production: `ClaudeAgentRunner.run` never routes a
            // `.fork` attempt through this predicate (B7.2's rotation is a
            // single non-retryable attempt). False, never true, so a future
            // caller cannot accidentally wire a retry for it.
            return false
        }
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
        /// Whether the conversation behind `sessionId` is believed to exist.
        ///
        /// Only an ordering hint — both directions still self-heal — but it earns a
        /// field because getting it wrong costs a whole wasted CLI launch at the
        /// most visible moment there is. An agent that has never had a turn cannot
        /// have a conversation, so resuming one is a guaranteed-failing process
        /// spawn in front of the user's first prompt.
        ///
        /// Defaults to true, which is the historical resume-first behavior.
        public var conversationMayExist: Bool
        /// B7.2 — when true, `sessionId` is the OLD session to resume-and-fork
        /// FROM (`/clear`'s rotation), not the session to resume/start. Bypasses
        /// the resume/start ordering entirely: `run` makes exactly one
        /// `--fork-session` attempt with no retry.
        public var forkSession: Bool

        public init(
            model: String,
            effort: String? = nil,
            cwd: URL,
            sessionId: String,
            extraArgs: [String] = [],
            conversationMayExist: Bool = true,
            forkSession: Bool = false
        ) {
            self.model = model
            self.effort = effort
            self.cwd = cwd
            self.sessionId = sessionId
            self.extraArgs = extraArgs
            self.conversationMayExist = conversationMayExist
            self.forkSession = forkSession
        }
    }

    /// Whether this run continues the conversation or creates it.
    ///
    /// Platform-neutral so the ordering policy can live beside the other pure
    /// claude policy in `ClaudeCLIBackend` and be witnessed without a process.
    public typealias SessionMode = ClaudeSessionMode

    /// The claude args after the executable. `--verbose` is required by the
    /// CLI for stream-json in print mode. Permission mode is intentionally not
    /// overridden: the user's effective Claude configuration remains
    /// authoritative, while hook events expose native interaction seams.
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
        case .fork: sessionArgs = ["--resume", sessionId, "--fork-session"]
        }
        // C7: `--forward-subagent-text` is what makes a child's PROSE arrive.
        // Without it the stream carries a subagent's tool_use/tool_result blocks
        // and nothing it said, so a child transcript would be tool calls with no
        // answer in them. Documented for 2.1.211+ with the env twin
        // CLAUDE_CODE_FORWARD_SUBAGENT_TEXT; verified present in `claude --help`
        // on the installed 2.1.241, where it also states it only works with
        // --print and --output-format=stream-json, which is exactly this argv.
        return ["-p", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--include-hook-events",
                "--forward-subagent-text"]
            + ["--model", model]
            + (effort.map { ["--effort", $0] } ?? [])
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
    public var compactionCapabilities: AgentCompactionCapabilities {
        AgentCompactionCapabilities(
            supportsManual: config.conversationMayExist && !config.forkSession,
            supportsFocus: true,
            unavailableReason: config.conversationMayExist ? nil : "Nothing to compact yet"
        )
    }
    private let queue = DispatchQueue(label: "continuum.claude-agent-runner")
    private var translator: ClaudeEventTranslator
    private var buffer = Data()
    private var stderrBuffer = Data()   // queue-confined
    /// M1.8: see `ProcessGroupChild`. Queue-confined (set in run, read in stop).
    private var child: ProcessGroupChild?
    private var stopRequested = false   // queue-confined; suppresses the retry

    public init(config: Config) {
        self.config = config
        self.translator = ClaudeEventTranslator(workingDirectory: config.cwd)
    }

    /// Runs claude with `prompt`, streaming events to `onEvent` until it
    /// exits. Blocking; call off the main thread. `onEvent` is invoked on the
    /// runner's serial queue.
    ///
    /// Two orderings, one mechanism. `config.conversationMayExist` picks which mode
    /// is tried first and the other becomes the retry, so the pair self-heals in
    /// BOTH directions: a resume of a conversation that does not exist retries as
    /// `--session-id`, and a `--session-id` for one that already exists retries as
    /// `--resume`. A failing attempt streams nothing (the translator gates on init,
    /// and the failure emits no events), so a retry cannot duplicate content.
    ///
    /// Why the hint matters: this was resume-first unconditionally, so the first
    /// turn of every claude agent spawned a whole `claude --resume <uuid>` process,
    /// waited for it to fail, and only then spawned the real one — a guaranteed
    /// wasted CLI launch in front of the user's very first prompt.
    public func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        // B7.2 — `/clear`'s rotation is a single, non-retryable attempt: it
        // either forks (and the new id is adopted from `system/init` over the
        // runtime-observation channel) or it fails outright. Falling back to
        // an ordinary resume/start on failure would silently abandon the
        // rotation and keep talking to the OLD, un-cleared session.
        if config.forkSession {
            let result = try runOnce(mode: .fork, prompt: prompt, onEvent: onEvent)
            if result.exitCode != 0 {
                try throwStoppedIfRequested(stderr: result.stderr)
                throw RunError.claudeFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            return
        }
        let order = ClaudeCLIBackend.sessionModeOrder(
            conversationMayExist: config.conversationMayExist)
        let first = try runOnce(mode: order.first, prompt: prompt, onEvent: onEvent)
        if first.exitCode == 0 { return }
        guard ClaudeCLIBackend.retryIsWarranted(after: order.first, stderr: first.stderr) else {
            // M1.7: a Stop SIGTERMs the child, so this non-zero exit is the Stop
            // arriving, not a failure. The flag existed and was read only to
            // suppress the retry BELOW -- after this line had already thrown.
            try throwStoppedIfRequested(stderr: first.stderr)
            throw RunError.claudeFailed(exitCode: first.exitCode, stderr: first.stderr)
        }
        let shouldRetry: Bool = queue.sync { !stopRequested }
        guard shouldRetry else { throw AgentRunStopped(detail: first.stderr) }
        let second = try runOnce(mode: order.retry, prompt: prompt, onEvent: onEvent)
        if second.exitCode != 0 {
            try throwStoppedIfRequested(stderr: second.stderr)
            throw RunError.claudeFailed(exitCode: second.exitCode, stderr: second.stderr)
        }
    }

    /// Invoke Claude's native slash command without publishing its synthetic
    /// print-mode turn. Only the compaction lifecycle/boundary crosses this seam.
    public func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        guard compactionCapabilities.supportsManual else {
            throw RunError.launchFailed(compactionCapabilities.unavailableReason ?? "compaction unavailable")
        }
        let focus = request.focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = focus.flatMap { $0.isEmpty ? nil : $0 }.map { "/compact \($0)" } ?? "/compact"
        let result = try runOnce(mode: .resume, prompt: AgentPrompt(command)) { event in
            switch event {
            case .compactionChanged(let threadId, var lifecycle):
                lifecycle.operationID = request.operationID
                lifecycle.trigger = .manual
                onEvent(.compactionChanged(threadId: threadId, event: lifecycle))
            case .itemStarted(_, _, .compaction, _), .itemCompleted(_, _, .compaction, _), .contextWindowUpdated:
                onEvent(event)
            default:
                break
            }
        }
        if result.exitCode != 0 {
            try throwStoppedIfRequested(stderr: result.stderr)
            throw RunError.claudeFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// M1.7: consult the stop flag BEFORE every throw. `stopRequested` is set
    /// under `queue.sync` by `stop()`, which also sends the SIGTERM, so by the time
    /// a `run` sees a non-zero exit the flag is already true.
    private func throwStoppedIfRequested(stderr: String) throws {
        if queue.sync { stopRequested } { throw AgentRunStopped(detail: stderr) }
    }

    /// Text-only compatibility wrapper, matching PiAgentRunner's.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    public func stop() {
        // M1.8: the whole GROUP, at the interactive grace. See `ProcessGroupChild`.
        let running = queue.sync { () -> ProcessGroupChild? in
            stopRequested = true
            return child
        }
        running?.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
    }

    /// Claude has no `spawn_agent` — its Task tool spawns claude-internal
    /// sub-agents that surface as ordinary tool items. The handler is
    /// accepted for seam parity and never fires.
    /// C7 — this was a no-op, so every claude subagent announcement was dropped
    /// before it could reach the supervisor. It is the same seam pi uses; what
    /// arrives through it is an OBSERVED child (`observedOnly`), not a request to
    /// launch one.
    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        queue.sync { translator.onSpawnRequest = handler }
    }

    /// C7 — one observed child's own events, keyed by the spawning `Agent`
    /// call's `tool_use` id. Only `ClaudeAgentRunner` has these; pi and codex
    /// children are processes Array owns and stream on their own runners.
    public func observeSubagentEvents(
        _ handler: @escaping @Sendable (String, AgentRuntimeEvent) -> Void
    ) {
        queue.sync { translator.onSubagentEvent = handler }
    }

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
        let command = Self.liveResolvedCommand()
        let arguments = command.prefixArgs + Self.processArguments(
            model: config.model,
            effort: config.effort,
            sessionMode: mode,
            sessionId: config.sessionId,
            extraArgs: config.extraArgs,
            prompt: prompt
        )

        queue.sync { buffer.removeAll(); stderrBuffer.removeAll() }

        let spawned: ProcessGroupChild
        do {
            spawned = try ProcessGroupChild.spawn(
                executable: command.executable,
                arguments: arguments,
                // Same GUI-thin-PATH augmentation as pi's: an npm-installed claude is
                // a node script whose shebang needs node on PATH. (The native binary
                // doesn't, but augmenting is harmless there.) HOME and
                // CLAUDE_CONFIG_DIR stay untouched — overriding HOME relocates the
                // keychain lookup and the CLI stops finding its own login.
                environment: PiAgentRunner.childEnvironment(),
                currentDirectory: config.cwd,
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
        // Drain stderr CONCURRENTLY (the pi runner's deadlock lesson: a full
        // 64KB stderr pipe blocks the child while we block in waitUntilExit).
        spawned.standardError.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.stderrBuffer.append(chunk) }
        }

        let exitCode = spawned.wait()
        spawned.standardOutput.readabilityHandler = nil
        spawned.standardError.readabilityHandler = nil

        // The LEADER exited, but a descendant that inherited fd 1/2 (a Task
        // subagent, an MCP server, a backgrounded shell) keeps the pipe's write
        // end open, and `readDataToEndOfFile()` then blocks until THAT process
        // exits — potentially forever, parking this run() and its runner slot.
        // Kill whatever is left of the group so the pipes close (a clean exit
        // leaves nothing, making this a no-op), then drain with a bound.
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
        return (exitCode, errText)
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

/// The method already existed verbatim; this only names the capability so the
/// supervisor can ask for it instead of downcasting to this class.
extension ClaudeAgentRunner: SubagentEventObserving {}

#endif  // os(macOS)
