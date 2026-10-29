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

    /// The claude CLI's own model catalogue, read from the `initialize`
    /// control handshake: the same list claude's `/model` picker shows, for this
    /// account and this CLI version. It sends no prompt and starts no turn.
    /// Hooks are disabled for the probe only, so a model listing never runs the
    /// user's SessionStart hooks (`disableAllHooks` changes no catalogue entry;
    /// checked against the live CLI 2026-10-01).
    public static let modelProbeArguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--tools", "", "--strict-mcp-config", "--setting-sources", "",
        "--settings", #"{"disableAllHooks":true}"#,
    ]
    public static let modelProbeRequestId = "array-models"
    public static var modelProbeRequestLine: String {
        #"{"type":"control_request","request_id":"\#(modelProbeRequestId)","request":{"subtype":"initialize"}}"#
    }

    /// One stdout line of the probe → a catalogue, or nil when the line is not
    /// the handshake's answer or names no model.
    ///
    /// Each entry's id is its `resolvedModel`, the exact id the alias stands
    /// for today: `opus` arrives as `claude-opus-5-5`, so a record says which
    /// model it ran and the context-window map has a key for it. The `default`
    /// entry is not a model of its own; it names the CLI's default. Order is the
    /// CLI's.
    public static func parseInitializeModels(controlResponseLine line: String) -> AgentHarnessCatalogSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              (object["type"] as? String) == "control_response",
              let envelope = object["response"] as? [String: Any],
              (envelope["subtype"] as? String) == "success",
              let response = envelope["response"] as? [String: Any],
              let entries = response["models"] as? [[String: Any]] else { return nil }
        var models: [String] = []
        var names: [String: String] = [:]
        var defaultModel: String?
        for entry in entries {
            guard let value = entry["value"] as? String else { continue }
            let resolved = (entry["resolvedModel"] as? String) ?? value
            guard resolved.hasPrefix("claude-") else { continue }
            let id = "anthropic/\(resolved)"
            if value == "default" {
                defaultModel = id
                continue
            }
            guard !models.contains(id) else { continue }
            models.append(id)
            if let name = entry["displayName"] as? String, !name.isEmpty { names[id] = name }
        }
        if let defaultModel, !models.contains(defaultModel) { models.insert(defaultModel, at: 0) }
        guard !models.isEmpty else { return nil }
        return AgentHarnessCatalogSnapshot(
            harness: .claudeCode, readiness: .ready, models: models,
            displayNames: names, defaultModel: defaultModel)
    }

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

/// T5 (`.plans/69`, D3) — ONE long-lived `claude -p --input-format stream-json`
/// process per agent, fed one stream-json user message per prompt.
///
/// It used to be one process per turn with the prompt in argv, and the whole
/// process group was killed when that turn's process exited. That killed every
/// Bash background job and every background subagent claude had started — real
/// work, lost at the turn boundary — and it left no channel for a second
/// message while a turn ran. Now:
///
/// - the turn boundary is the `result` frame, never process exit;
/// - a steer is one more user message on stdin, which claude consumes at its
///   next tool boundary (or, when no boundary is left, runs as the next turn) and
///   confirms by replaying it (`--replay-user-messages`, `isReplay: true`);
/// - an interrupt is a `control_request`, which ends the turn and keeps the
///   process;
/// - a turn claude starts on its own (a promoted steer, a finished background
///   task's notification) is buffered and announced, so the supervisor can bind
///   it to the agent like any other turn.
///
/// Measured live on claude 2.1.291 (captures in `.plans/69`'s probe directory).
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
        /// Extra args after the session flags.
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
        /// FROM (`/clear`'s rotation), not the session to resume/start. The
        /// process's first spawn makes exactly one `--fork-session` attempt with
        /// no retry.
        public var forkSession: Bool
        public var workspaceMCP: WorkspaceMCPConfiguration?
        /// The agent id every descendant carries — `PiAgentRunner.childEnvironment`.
        public var processOwner: String?

        public init(
            model: String,
            effort: String? = nil,
            cwd: URL,
            sessionId: String,
            extraArgs: [String] = [],
            conversationMayExist: Bool = true,
            forkSession: Bool = false,
            workspaceMCP: WorkspaceMCPConfiguration? = nil,
            processOwner: String? = nil
        ) {
            self.model = model
            self.effort = effort
            self.cwd = cwd
            self.sessionId = sessionId
            self.extraArgs = extraArgs
            self.conversationMayExist = conversationMayExist
            self.forkSession = forkSession
            self.workspaceMCP = workspaceMCP
            self.processOwner = processOwner
        }
    }

    /// Whether this run continues the conversation or creates it.
    ///
    /// Platform-neutral so the ordering policy can live beside the other pure
    /// claude policy in `ClaudeCLIBackend` and be witnessed without a process.
    public typealias SessionMode = ClaudeSessionMode

    /// The claude args after the executable — the ONE place the argv is built.
    /// `--verbose` is required by the CLI for stream-json in print mode. No
    /// positional prompt: every prompt is a stdin message, so there is nothing
    /// after the options for `--mcp-config`'s variadic list to swallow.
    /// Permission mode is always `bypassPermissions`, as managed Codex runs
    /// with full access: a headless `-p` session has nobody to answer a
    /// permission prompt, so on the CLI's default mode every shell, Xcode,
    /// simulator, git or network call the agent needs is denied. The flag
    /// applies to fresh, resumed and forked sessions alike (measured on
    /// claude 2.1.312: a resume without it reports `default`). Array's own
    /// workspace grants are a separate layer and still gate its tools.
    public static func processArguments(
        model: String,
        effort: String?,
        sessionMode: SessionMode,
        sessionId: String,
        extraArgs: [String],
        workspaceMCP: WorkspaceMCPConfiguration? = nil
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
        // T5: `--replay-user-messages` is the consumption receipt for a steer.
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                "--verbose", "--include-partial-messages", "--replay-user-messages",
                "--include-hook-events", "--forward-subagent-text"]
            + ["--model", model]
            + (effort.map { ["--effort", $0] } ?? [])
            + ["--permission-mode", "bypassPermissions"]
            + sessionArgs
            + extraArgs
        if let workspaceMCP {
            // The guidance line rides in the system prompt because Claude
            // defers MCP tools behind tool search: without it the model never
            // learns Array's tools exist and reaches for tmux or curl instead.
            // Measured on claude 2.1.291 (-p, haiku): outside bypass mode every
            // MCP call is denied ("you haven't granted it yet") until
            // `--allowedTools mcp__array_workspace` names the server, so Array's
            // own approval is the only gate; `--disallowedTools ListAgents`
            // removes the tool that listed tmux peers as if they were tiles.
            args += ["--append-system-prompt", WorkspaceMCPConfiguration.agentGuidance,
                     "--allowedTools", "mcp__array_workspace",
                     "--disallowedTools", "ListAgents",
                     "--strict-mcp-config", "--mcp-config", workspaceMCP.claudeMCPConfigPath]
        }
        return args
    }

    /// The text of a prompt with every attachment as an `@/local/file`
    /// reference, newline-joined — the shape claude's argv prompt had, kept as
    /// the shared contract with codex's positional prompt.
    public static func promptArgument(_ prompt: AgentPrompt) -> String {
        var segments: [String] = []
        if !prompt.providerText.isEmpty { segments.append(prompt.providerText) }
        segments.append(contentsOf: prompt.imageAttachments.map(\.piPathReference))
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.joined(separator: "\n")
    }

    /// The text block of one stdin message: the visible text and each FILE
    /// reference as `@path` (claude's Read tool fetches it). Images travel as
    /// native image blocks instead — the same split pi's rpc prompt makes.
    public static func userMessageText(_ prompt: AgentPrompt) -> String {
        var segments: [String] = []
        if !prompt.providerText.isEmpty { segments.append(prompt.providerText) }
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.joined(separator: "\n")
    }

    /// One stream-json user message line. Text-only content stays a plain
    /// string, which is exactly the shape the live probe measured. `uuid`
    /// stamps a steer: claude echoes it on the replay and names it in an
    /// interrupt's `cancelled` / `still_queued` receipt.
    public static func userMessageLine(_ prompt: AgentPrompt, uuid: UUID? = nil) throws -> String {
        let text = userMessageText(prompt)
        let content: Any
        if prompt.imageAttachments.isEmpty {
            content = text
        } else {
            var blocks: [[String: Any]] = []
            if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            for attachment in prompt.imageAttachments {
                let data = try Data(contentsOf: attachment.fileURL, options: [.mappedIfSafe])
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": attachment.metadata.contentType
                            ?? PiRpcAgentRunner.inferredImageMIMEType(for: attachment.fileURL),
                        "data": data.base64EncodedString(),
                    ],
                ])
            }
            content = blocks
        }
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        if let uuid { object["uuid"] = uuid.uuidString.lowercased() }
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    /// The interrupt control request, measured live: answered by a
    /// `control_response` in ~10ms, the in-flight tool is declined, the turn's
    /// `result` is `error_during_execution`, and the process keeps reading.
    ///
    /// T5c — `cancel_queued`: without it, a steer claude holds but has not
    /// consumed survives the interrupt (`still_queued`) and claude runs it as
    /// its NEXT turn, so the agent kept working after the user's Stop (measured
    /// on 2.1.291). With it, claude cancels those messages and lists their uuids
    /// under `cancelled`; they come back to Array as `.returned`.
    public static func interruptRequestLine(requestId: String) -> String {
        #"{"type":"control_request","request_id":"\#(requestId)","request":{"subtype":"interrupt","cancel_queued":true}}"#
    }

    public enum RunError: Error, CustomStringConvertible, AgentRunFailureDescribing {
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

        public var userFacingDescription: String {
            switch self {
            case .launchFailed(let message):
                return "Claude Code could not start: \(SecretRedactor.redactLocalDiagnostics(message))"
            case .claudeFailed(let exitCode, let stderr):
                let head = "Claude Code exited (code \(exitCode)) without finishing the turn"
                return AgentFailureText.stderrTail(stderr).map { "\(head): \($0)" } ?? "\(head)."
            }
        }

        public var isProcessLoss: Bool {
            if case .claudeFailed = self { return true }
            return false
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

    public static func liveResolvedCommand() -> PiAgentRunner.ResolvedCommand {
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

    /// How long `interrupt()` waits for claude's `control_response`.
    public static let interruptAcknowledgementTimeout: TimeInterval = 5

    public let config: Config
    public var compactionCapabilities: AgentCompactionCapabilities {
        let established = queue.sync { conversationEstablished }
        let exists = config.conversationMayExist || established
        return AgentCompactionCapabilities(
            supportsManual: exists && (!config.forkSession || established),
            supportsFocus: true,
            unavailableReason: exists ? nil : "Nothing to compact yet"
        )
    }

    /// How a waited-on turn ended.
    private enum TurnEnd {
        case completed
        case stopped
        case exited(code: Int32, sawInit: Bool, stderr: String)
    }

    /// One `run`/`compact`/adoption waiting for `remaining` turn completions.
    private final class TurnWaiter: @unchecked Sendable {
        let onEvent: @Sendable (AgentRuntimeEvent) -> Void
        var remaining: Int
        var end: TurnEnd?
        let semaphore = DispatchSemaphore(value: 0)
        init(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void, remaining: Int) {
            self.onEvent = onEvent
            self.remaining = remaining
        }
    }

    /// Events of a turn claude started with nobody waiting, held until the
    /// supervisor adopts it. `open` counts turns begun and not yet completed.
    private struct UnsolicitedTurns {
        var events: [AgentRuntimeEvent] = []
        var open = 0
    }

    private let queue = DispatchQueue(label: "continuum.claude-agent-runner")
    /// Every stdin write goes through one serial queue (prompt, steer,
    /// interrupt), so two frames can never interleave their bytes.
    private let writeQueue = DispatchQueue(label: "continuum.claude-agent-runner.write")
    // Everything below is queue-confined.
    private var translator: ClaudeEventTranslator
    private var buffer = Data()
    private var stderrBuffer = Data()
    /// M1.8: see `ProcessGroupChild`. The LIVE session process, or nil.
    private var child: ProcessGroupChild?
    private var stopRequested = false
    private var forkConsumed = false
    /// An init has been seen from a process of this runner: the conversation
    /// exists now whatever the config believed.
    private var conversationEstablished = false
    /// The CURRENT process has started at least one turn. A process that dies
    /// before that is the only one the session-mode retry may replace.
    private var processSawInit = false
    private var turn: TurnWaiter?
    private var idleExitHandler: (@Sendable (Int32, String?, Bool) -> Void)?
    private var unsolicited: UnsolicitedTurns?
    /// Steers written to stdin and not yet replayed, oldest first.
    private var pendingSteers: [(id: UUID, text: String)] = []
    private var interruptRequested = false
    private var controlCounter = 0
    private var pendingControls: [String: (semaphore: DispatchSemaphore, success: Bool?)] = [:]
    /// claude's own `background_tasks_changed` list size: Bash background jobs
    /// and background subagents still running inside this process.
    private var backgroundTaskCount = 0
    private var spawnHandler: (@Sendable (SpawnRequest) -> Void)?
    private var observationHandler: (@Sendable (AgentRuntimeObservation) -> Void)?
    private var subagentHandler: (@Sendable (String, AgentRuntimeEvent) -> Void)?
    private var subagentProgressHandler: (@Sendable (String) -> Void)?
    private var steerDispositionHandler: (@Sendable (UUID, AgentSteerDisposition) -> Void)?
    private var unsolicitedTurnHandler: (@Sendable () -> Void)?

    public init(config: Config) {
        self.config = config
        self.translator = ClaudeEventTranslator(workingDirectory: config.cwd)
    }

    deinit {
        // An idle runner is retained between turns on purpose; if its owner
        // goes away without a stop, do not orphan claude or its jobs.
        child?.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
    }

    // MARK: - Session state

    /// True while the session process is alive and not being stopped.
    public var isSessionRunning: Bool {
        queue.sync { child != nil && !stopRequested }
    }

    /// True while a turn is waited on and a steer could be written into it.
    public var acceptsSteerNow: Bool {
        queue.sync { child != nil && !stopRequested && turn != nil && !interruptRequested }
    }

    /// Background jobs or subagents claude reports running in this process.
    /// The idle reaper keeps a session alive while this is true.
    public var hasBackgroundWork: Bool {
        queue.sync { backgroundTaskCount > 0 }
    }

    /// Claude children this session opened that are still running. Unlike
    /// `hasBackgroundWork` a shell job never counts: only a child holds the
    /// session open for the idle reaper.
    public var hasRunningSubagents: Bool {
        queue.sync { child != nil && translator.subagents.hasRunningChildren }
    }

    public func observeSubagentProgress(_ handler: @escaping @Sendable (String) -> Void) {
        queue.sync { subagentProgressHandler = handler; translator.onSubagentProgress = handler }
    }

    /// A turn claude began on its own is buffered and waiting to be adopted.
    public var hasUnsolicitedTurn: Bool {
        queue.sync { unsolicited != nil }
    }

    // MARK: - Turns

    /// Writes `prompt` to the session (starting it on first use) and blocks
    /// until the turn it starts reaches its `result`. `onEvent` is invoked on
    /// the runner's serial queue.
    ///
    /// The first spawn tries the session mode its config believes in and, only
    /// when that process dies before ever starting a turn with the matching
    /// stderr, retries the other mode with the same prompt — the self-healing
    /// pair from the one-shot runner, unchanged. A `/clear` rotation is one
    /// `--fork-session` attempt with no retry.
    public func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let line: String
        do {
            line = try Self.userMessageLine(prompt)
        } catch {
            throw RunError.launchFailed("could not prepare a local image attachment")
        }
        try drive(line: line, onEvent: onEvent)
    }

    /// Text-only compatibility wrapper, matching PiAgentRunner's.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    /// Invoke Claude's native slash command over the same stdin, without
    /// publishing its synthetic print-mode turn. Only the compaction
    /// lifecycle/boundary crosses this seam.
    public func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        guard compactionCapabilities.supportsManual else {
            throw RunError.launchFailed(compactionCapabilities.unavailableReason ?? "compaction unavailable")
        }
        let focus = request.focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = focus.flatMap { $0.isEmpty ? nil : $0 }.map { "/compact \($0)" } ?? "/compact"
        try drive(line: try Self.userMessageLine(AgentPrompt(command)), modes: [.resume]) { event in
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
    }

    /// Binds a turn claude started without a prompt from Array (a steer it
    /// promoted to its own turn, a background task's notification). Replays the
    /// buffered events into `onEvent`, then blocks until that turn's `result`.
    /// Returns at once when nothing is buffered.
    public func continueUnsolicitedTurn(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let waiter: TurnWaiter? = queue.sync {
            guard turn == nil, let buffered = unsolicited else { return nil }
            unsolicited = nil
            buffered.events.forEach(onEvent)
            guard buffered.open > 0, child != nil else { return nil }
            let waiter = TurnWaiter(onEvent: onEvent, remaining: buffered.open)
            turn = waiter
            return waiter
        }
        guard let waiter else { return }
        waiter.semaphore.wait()
        switch waiter.end ?? .completed {
        case .completed:
            return
        case .stopped:
            throw AgentRunStopped(detail: nil)
        case let .exited(code, _, stderr):
            if queue.sync(execute: { stopRequested }) { throw AgentRunStopped(detail: stderr) }
            if code != 0 { throw RunError.claudeFailed(exitCode: code, stderr: stderr) }
        }
    }

    private func drive(
        line: String,
        modes requestedModes: [SessionMode]? = nil,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        if queue.sync(execute: { stopRequested }) { throw AgentRunStopped(detail: nil) }
        let modes: [SessionMode]
        if let requestedModes {
            modes = requestedModes
        } else if config.forkSession && !queue.sync(execute: { forkConsumed }) {
            modes = [.fork]
        } else {
            let order = ClaudeCLIBackend.sessionModeOrder(
                conversationMayExist: config.conversationMayExist || queue.sync { conversationEstablished })
            modes = [order.first, order.retry]
        }
        for (index, mode) in modes.enumerated() {
            let wasWarm = queue.sync { child != nil }
            try ensureStarted(mode: mode)
            let waiter: TurnWaiter = try queue.sync {
                guard turn == nil else { throw RunError.launchFailed("a claude turn is already in flight") }
                // S3: a failure reports only its own turn's stderr. The buffer
                // used to reset per PROCESS, so turn N's error carried every
                // earlier turn's diagnostics. A cold process keeps what its
                // boot wrote: the resume self-heal reads it.
                if wasWarm { stderrBuffer.removeAll() }
                // A turn claude began on its own that nobody adopted yet comes
                // first: its events precede this prompt's, and this prompt's turn
                // only starts after it.
                var remaining = 1
                var buffered: [AgentRuntimeEvent] = []
                if let pending = unsolicited {
                    unsolicited = nil
                    buffered = pending.events
                    remaining += pending.open
                }
                let waiter = TurnWaiter(onEvent: onEvent, remaining: remaining)
                turn = waiter
                buffered.forEach(onEvent)
                return waiter
            }
            // A failed write means the process is going away; its exit path
            // completes the waiter with the real exit code and stderr.
            try? write(line)
            waiter.semaphore.wait()
            switch waiter.end ?? .completed {
            case .completed:
                return
            case .stopped:
                throw AgentRunStopped(detail: nil)
            case let .exited(code, sawInit, stderr):
                if queue.sync(execute: { stopRequested }) { throw AgentRunStopped(detail: stderr) }
                if !sawInit, index + 1 < modes.count,
                   ClaudeCLIBackend.retryIsWarranted(after: mode, stderr: stderr) {
                    continue
                }
                // Exit 0 with no result is the supervisor's to close ("exited
                // without reporting a result"); anything else is a failure.
                if code == 0 { return }
                throw RunError.claudeFailed(exitCode: code, stderr: stderr)
            }
        }
    }

    // MARK: - Steering and interrupt

    /// Hands one more user message to the turn in flight. claude takes it at
    /// its next tool boundary, or runs it as the next turn when the current one
    /// has no boundary left; either way the replay of the message is the
    /// receipt, reported through `observeSteerDispositions`. Once this returns
    /// only an interrupt can take it back (`returned`, see
    /// `interruptRequestLine`).
    public func steer(_ prompt: AgentPrompt, id: UUID) throws {
        let text = Self.userMessageText(prompt)
        let line: String
        do {
            line = try Self.userMessageLine(prompt, uuid: id)
        } catch {
            throw AgentSteerNotAccepted("could not prepare a local image attachment")
        }
        try queue.sync {
            guard child != nil, !stopRequested, turn != nil, !interruptRequested else {
                throw AgentSteerNotAccepted("no claude turn is in flight")
            }
            pendingSteers.append((id, text))
        }
        do {
            try write(line)
        } catch {
            queue.sync { pendingSteers.removeAll { $0.id == id } }
            throw AgentSteerNotAccepted("the claude session is not accepting input")
        }
    }

    /// Ends the turn in flight and keeps the process. Blocks until claude
    /// acknowledges; the turn then closes with `.interrupted`. A no-op when no
    /// turn is waited on.
    public func interrupt() throws {
        let request: (id: String, semaphore: DispatchSemaphore)? = try queue.sync {
            guard child != nil, !stopRequested else { throw RunError.launchFailed("claude session is not running") }
            guard turn != nil else { return nil }
            controlCounter += 1
            let id = "array-interrupt-\(controlCounter)"
            let semaphore = DispatchSemaphore(value: 0)
            pendingControls[id] = (semaphore, nil)
            interruptRequested = true
            return (id, semaphore)
        }
        guard let request else { return }
        do {
            try write(Self.interruptRequestLine(requestId: request.id))
        } catch {
            queue.sync { pendingControls[request.id] = nil; interruptRequested = false }
            throw RunError.launchFailed("claude session is not accepting input")
        }
        let answered = request.semaphore.wait(timeout: .now() + Self.interruptAcknowledgementTimeout) == .success
        let success = queue.sync { () -> Bool in
            defer { pendingControls[request.id] = nil }
            return pendingControls[request.id]?.success ?? false
        }
        guard answered, success else {
            queue.sync { interruptRequested = false }
            throw RunError.launchFailed("claude did not acknowledge the interrupt")
        }
    }

    /// Kills the whole session group — the process, its tools, its background
    /// jobs. The fallback behind `interrupt()`, and the end of the agent.
    public func stop() {
        // M1.8: the whole GROUP, at the interactive grace. See `ProcessGroupChild`.
        let running = queue.sync { () -> ProcessGroupChild? in
            stopRequested = true
            return child
        }
        running?.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        queue.sync { finishTurn(.stopped) }
    }

    // MARK: - Side channels

    /// C7 — this was a no-op, so every claude subagent announcement was dropped
    /// before it could reach the supervisor. It is the same seam pi uses; what
    /// arrives through it is an OBSERVED child (`observedOnly`), not a request to
    /// launch one.
    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        queue.sync { spawnHandler = handler; translator.onSpawnRequest = handler }
    }

    /// C7 — one observed child's own events, keyed by the spawning `Agent`
    /// call's `tool_use` id. Only `ClaudeAgentRunner` has these; pi and codex
    /// children are processes Array owns and stream on their own runners.
    public func observeSubagentEvents(
        _ handler: @escaping @Sendable (String, AgentRuntimeEvent) -> Void
    ) {
        queue.sync { subagentHandler = handler; translator.onSubagentEvent = handler }
    }

    public func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {
        queue.sync { observationHandler = handler; translator.onRuntimeObservation = handler }
    }

    /// A steer's id once claude has replayed it, i.e. consumed it, or
    /// `returned` when an interrupt cancelled it before claude read it.
    public func observeSteerDispositions(
        _ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void
    ) {
        queue.sync { steerDispositionHandler = handler }
    }

    /// Fired (on the runner's queue) when claude starts a turn nobody is
    /// waiting on. The handler hops threads itself and later calls
    /// `continueUnsolicitedTurn`.
    public func observeUnsolicitedTurns(_ handler: @escaping @Sendable () -> Void) {
        queue.sync { unsolicitedTurnHandler = handler }
    }

    // MARK: - Process

    private func ensureStarted(mode: SessionMode) throws {
        if queue.sync(execute: { child != nil }) { return }
        // `--strict-mcp-config --mcp-config <path>` names a file Array writes;
        // (re)write it now and refuse the launch with the real reason if that
        // fails, rather than start claude against a file that is not there.
        if let workspaceMCP = config.workspaceMCP {
            do {
                try workspaceMCP.materialize()
            } catch {
                throw RunError.launchFailed(String(describing: error))
            }
        }
        let command = Self.liveResolvedCommand()
        let arguments = command.prefixArgs + Self.processArguments(
            model: config.model,
            effort: config.effort,
            sessionMode: mode,
            sessionId: config.sessionId,
            extraArgs: config.extraArgs,
            workspaceMCP: config.workspaceMCP
        )
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
                environment: Self.childEnvironment(workspaceMCP: config.workspaceMCP, processOwner: config.processOwner),
                currentDirectory: config.cwd,
                standardInput: .pipe
            )
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        // A write after claude exits must fail as an error, never as a SIGPIPE
        // delivered to the app.
        if let stdin = spawned.standardInput {
            _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        queue.sync {
            child = spawned
            processSawInit = false
            buffer.removeAll()
            stderrBuffer.removeAll()
            if mode == .fork { forkConsumed = true }
        }
        spawned.standardOutput.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF: the dispatch source stays armed and re-fires forever.
                handle.readabilityHandler = nil
                return
            }
            self?.queue.sync { self?.consume(chunk) }
        }
        // Drain stderr CONCURRENTLY (the pi runner's deadlock lesson: a full
        // 64KB stderr pipe blocks the child). Bounded: the process now lives
        // for many turns.
        spawned.standardError.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.sync {
                guard let self else { return }
                self.stderrBuffer.append(chunk)
                if self.stderrBuffer.count > 65_536 {
                    self.stderrBuffer.removeFirst(self.stderrBuffer.count - 65_536)
                }
            }
        }
        // The LEADER's exit is the authoritative end, not stdout EOF: a
        // background job that inherited fd 1 keeps the pipe open after claude
        // itself is gone, and waiting for EOF would park the turn forever.
        let watcher = Thread { [weak self] in
            let code = spawned.wait()
            spawned.standardOutput.readabilityHandler = nil
            spawned.standardError.readabilityHandler = nil
            // claude is gone, so nothing it started can report back any more:
            // reap the rest of the group so the pipes close, then drain them
            // with a bound.
            spawned.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
            let remainder = ProcessGroupChild.drainRemainder(of: spawned.standardOutput)
            let stderrRemainder = ProcessGroupChild.drainRemainder(of: spawned.standardError)
            self?.queue.sync { self?.processExited(spawned, code: code, remainder: remainder, stderrRemainder: stderrRemainder) }
        }
        watcher.start()
    }

    private func processExited(_ process: ProcessGroupChild, code: Int32, remainder: Data, stderrRemainder: Data) {
        guard child === process else { return }
        if !remainder.isEmpty { consume(remainder) }
        if !buffer.isEmpty {
            handleLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        stderrBuffer.append(stderrRemainder)
        let stderr = String(decoding: stderrBuffer, as: UTF8.self)
        // S3 (N3): a session process that leaves between turns, unasked, used
        // to be silent — background jobs and subagents vanished with no row,
        // and the next send quietly respawned.
        if turn == nil, !stopRequested, let handler = idleExitHandler {
            let tail = AgentFailureText.stderrTail(stderr)
            let hadBackgroundWork = backgroundTaskCount > 0
            DispatchQueue.global(qos: .utility).async { handler(code, tail, hadBackgroundWork) }
        }
        child = nil
        backgroundTaskCount = 0
        // Every child dies with the process; the supervisor settles them.
        translator.subagents = ClaudeSubagentRoster()
        interruptRequested = false
        for (id, control) in pendingControls where control.success == nil {
            pendingControls[id] = (control.semaphore, false)
            control.semaphore.signal()
        }
        finishTurn(.exited(code: code, sawInit: processSawInit, stderr: stderr))
    }

    private func finishTurn(_ end: TurnEnd) {
        guard let waiter = turn else { return }
        turn = nil
        waiter.end = end
        waiter.semaphore.signal()
    }

    private func write(_ line: String) throws {
        guard let handle = queue.sync(execute: { child?.standardInput }) else {
            throw RunError.launchFailed("claude session is not running")
        }
        var data = Data(line.utf8)
        data.append(0x0A)
        try writeQueue.sync { try handle.write(contentsOf: data) }
    }

    /// The MCP server's endpoint and token reach it through its own config
    /// (`WorkspaceMCPConfiguration.claudeMCPConfigJSON`), never through
    /// claude's environment: every Bash call claude makes inherits that, and
    /// `env` printed the capability token into a transcript.
    public static func childEnvironment(
        workspaceMCP: WorkspaceMCPConfiguration?, processOwner: String? = nil
    ) -> [String: String] {
        PiAgentRunner.childEnvironment(processOwner: processOwner)
    }

    // MARK: - queue-confined line handling

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            handleLine(line)
        }
    }

    private func makeTranslator() -> ClaudeEventTranslator {
        var fresh = ClaudeEventTranslator(workingDirectory: config.cwd)
        fresh.onSpawnRequest = spawnHandler
        fresh.onRuntimeObservation = observationHandler
        fresh.onSubagentEvent = subagentHandler
        fresh.onSubagentProgress = subagentProgressHandler
        // Open children belong to the session, not to the turn that launched
        // them: a background child keeps working after its parent's result.
        fresh.subagents = translator.subagents
        return fresh
    }

    private func handleLine(_ line: String) {
        var announceUnsolicited = false
        if let data = line.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let type = object["type"] as? String {
            switch type {
            case "control_response":
                // Protocol-only; never part of the transcript.
                if let response = object["response"] as? [String: Any],
                   let requestID = response["request_id"] as? String,
                   let control = pendingControls[requestID] {
                    // T5c — steers the interrupt cancelled were never read:
                    // they are the user's message again.
                    let cancelled = Set(((response["response"] as? [String: Any])?["cancelled"] as? [String] ?? [])
                        .map { $0.lowercased() })
                    for steer in pendingSteers where cancelled.contains(steer.id.uuidString.lowercased()) {
                        steerDispositionHandler?(steer.id, .returned)
                    }
                    pendingSteers.removeAll { cancelled.contains($0.id.uuidString.lowercased()) }
                    pendingControls[requestID] = (control.semaphore, (response["subtype"] as? String) == "success")
                    control.semaphore.signal()
                }
                return
            case "system":
                switch object["subtype"] as? String {
                case "background_tasks_changed":
                    backgroundTaskCount = (object["tasks"] as? [Any])?.count ?? 0
                case "init":
                    // Each turn opens with its own init. A fresh translator per
                    // turn keeps the one-turn-per-translator contract its
                    // per-turn counters were written against.
                    processSawInit = true
                    conversationEstablished = true
                    translator = makeTranslator()
                    if turn == nil {
                        if unsolicited == nil {
                            unsolicited = UnsolicitedTurns()
                            announceUnsolicited = true
                        }
                        unsolicited?.open += 1
                    }
                default:
                    break
                }
            case "user":
                if (object["isReplay"] as? Bool) == true,
                   (object["parent_tool_use_id"] as? String) == nil,
                   let message = object["message"] as? [String: Any],
                   let text = Self.replayedText(message["content"]),
                   let index = pendingSteers.firstIndex(where: {
                       (object["uuid"] as? String)?.lowercased() == $0.id.uuidString.lowercased()
                   }) ?? pendingSteers.firstIndex(where: { $0.text == text }) {
                    let consumed = pendingSteers.remove(at: index)
                    steerDispositionHandler?(consumed.id, .consumed)
                }
            default:
                break
            }
        }
        for var event in translator.translate(line: line) {
            if case let .turnCompleted(threadId, turnId, _, _) = event, interruptRequested {
                // claude reports an interrupted turn as `error_during_execution`;
                // the interrupt was asked for, so it is not a failure.
                interruptRequested = false
                event = .turnCompleted(threadId: threadId, turnId: turnId, outcome: .interrupted, errorMessage: nil)
            }
            if let waiter = turn {
                waiter.onEvent(event)
                if case .turnCompleted = event { waiter.remaining -= 1 }
            } else if unsolicited != nil {
                unsolicited?.events.append(event)
                if case .turnCompleted = event { unsolicited?.open -= 1 }
            }
        }
        if let waiter = turn, waiter.remaining <= 0 { finishTurn(.completed) }
        if announceUnsolicited { unsolicitedTurnHandler?() }
    }

    /// The text of a replayed user message: a plain string, or its text blocks.
    private static func replayedText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

/// The method already existed verbatim; this only names the capability so the
/// supervisor can ask for it instead of downcasting to this class.
extension ClaudeAgentRunner: SubagentEventObserving {}

#endif  // os(macOS)

#if os(macOS)
extension ClaudeAgentRunner: AgentIdleExitReporting {
    public func observeIdleExit(_ handler: @escaping @Sendable (Int32, String?, Bool) -> Void) {
        queue.sync { idleExitHandler = handler }
    }
}
#endif
