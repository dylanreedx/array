import Foundation

// Plan: .plans/02-codex-backend-and-toggle.md (codex CLI backend).
//
// The IMPURE half of the codex adapter (mirrors ClaudeAgentRunner): spawn the
// user's own `codex` binary headlessly (`codex exec --json`) and stream its
// stdout through the pure, pinned CodexEventTranslator. Compliance posture is
// the same as the claude backend: Array never touches credentials — the binary
// does its own ChatGPT subscription OAuth exactly as it would in a terminal,
// and Array only OBSERVES readiness (`codex login status`). Codex is MORE
// permissive than claude for local orchestration (cleared in plan 01).
//
// The one hard difference from claude: continuity is STORED, not derived. Claude
// mints its own session UUID and passes `--session-id`; codex mints its own
// `thread_id` and gives NO flag to set it. So the runner captures the id from
// the first turn's `thread.started` (out of band, on the observation side
// channel — see CodexEventTranslator) and the supervisor persists it to
// `AgentRecord.codexThreadId`. A later turn resumes with `codex exec resume
// <thread_id>`; a stale id fails and the runner self-heals to a fresh `exec`.

public enum CodexCLIBackend {
    /// Managed Codex has Full Access so local developer tools (including Xcode
    /// and CoreSimulator) can use services and caches outside the project root.
    /// Applied to fresh/resumed exec and every app-server process; approval
    /// policy remains `never`. Workspace API grants are controlled separately.
    public static let sandboxMode = "danger-full-access"

    /// `provider/model` catalogue id → the codex `-m` argument. Codex takes the
    /// bare slug (`gpt-5.6-sol`); the `openai-codex/` prefix is Array's
    /// namespacing (identical to pi's, so routing/dedup line up). Pass-through
    /// when there is no prefix.
    public static func modelArgument(forCatalogId id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// pi `--thinking` level → codex `model_reasoning_effort`. Codex's set is
    /// Only exact levels accepted by current Codex releases pass through;
    /// `off` remains Pi-only and omits the config so Codex takes its default.
    /// Same exact-match-or-omit rule as `ClaudeCLIBackend`.
    public static let effortLevels: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]
    public static func effortArgument(forThinking thinking: String) -> String? {
        effortLevels.contains(thinking) ? thinking : nil
    }

    /// `codex login status` → is a ChatGPT subscription login present. There is
    /// NO `--json` (`codex login status --json` errors), so this parses the real
    /// text shape: exit 0 AND stdout contains "Logged in". Pure — pinned against
    /// the captured output. Array only READS readiness; login is the CLI's own.
    public static func isLoggedIn(statusOutput: String, exitCode: Int32) -> Bool {
        exitCode == 0 && statusOutput.contains("Logged in")
    }

    /// The distinguishing stderr of `exec resume <id>` on a thread that no
    /// longer exists (deleted/archived/cleaned rollout) — the trigger for the
    /// self-heal to a fresh `exec`. Captured live: exit 1, empty stdout, stderr
    /// `… no rollout found for thread id <uuid> (code -32600)`.
    public static func isUnknownSessionFailure(stderr: String) -> Bool {
        let text = stripANSI(stderr)
        return text.contains("no rollout found for thread id") || text.contains("code -32600")
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// Whether this run continues a stored thread or starts a fresh one.
    public enum SessionMode: Sendable, Equatable {
        case fresh
        case resume
    }

    /// The codex args after the executable, both session modes. Pure so the
    /// matrix can pin them. `-C` (working root) is `exec`-only — resume rejects
    /// it, so the runner sets `currentDirectoryURL` there instead. `-c` overrides
    /// work on both. The prompt is ONE trailing positional (codex reads
    /// @-references itself, same contract as claude/pi).
    public static func processArguments(
        model: String,
        effort: String?,
        sessionMode: SessionMode,
        threadId: String?,
        cwdPath: String,
        extraArgs: [String],
        prompt: AgentPrompt,
        workspaceMCP: WorkspaceMCPConfiguration? = nil,
        hookOverrides: [String] = []
    ) -> [String] {
        var args: [String]
        switch sessionMode {
        case .fresh:
            args = ["exec"]
        case .resume:
            args = ["exec", "resume", threadId ?? ""]
        }
        args += [
            "--json", "--skip-git-repo-check",
            "-c", "approval_policy=never",
            "-c", "sandbox_mode=\(sandboxMode)",
            "-m", model,
        ]
        if let effort {
            args += ["-c", "model_reasoning_effort=\(effort)"]
        }
        if sessionMode == .fresh {
            // exec only; resume can't take -C.
            args += ["-C", cwdPath]
        }
        args += extraArgs
        for override in providerComputerUseOverrides { args += ["-c", override] }
        if let workspaceMCP {
            for override in workspaceMCP.codexConfigOverrides { args += ["-c", override] }
        }
        for override in hookOverrides { args += ["-c", override] }
        args += [promptArgument(prompt)]
        return args
    }

    /// Codex takes ONE positional prompt. The visible text and each
    /// attachment's `@/local/file` reference join with newlines — codex reads
    /// @-references itself, same as claude's.
    public static func promptArgument(_ prompt: AgentPrompt) -> String {
        var segments: [String] = []
        if !prompt.providerText.isEmpty { segments.append(prompt.providerText) }
        segments.append(contentsOf: prompt.imageAttachments.map(\.piPathReference))
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.joined(separator: "\n")
    }

    /// Managed agents start with the ChatGPT app's own computer use and browser
    /// use switched off. Those plugins load from the user's `~/.codex` into every
    /// codex process; inside Array they drove whole Mac apps by pixels, asked
    /// permission through prompts nobody could answer, and failed on every call
    /// (`.plans/80-browser-computer-use`, §9). Measured on codex 0.163.0
    /// (`research/s0-cli-probes.md`):
    /// - plugin keys must be UNQUOTED; `plugins."id".enabled` is silently ignored;
    /// - a plugin override for a plugin that is not installed is harmless;
    /// - `node_repl` is an `[mcp_servers]` entry, and `mcp_servers.X.enabled=false`
    ///   for a server the config lacks stops app-server answering `initialize`.
    ///   A whole disabled table is safe both when the entry exists and when it
    ///   does not.
    public static let providerComputerUseOverrides: [String] = [
        "plugins.unified-computer-use@openai-bundled.enabled=false",
        "plugins.computer-use@openai-bundled.enabled=false",
        "plugins.browser@openai-bundled.enabled=false",
        "mcp_servers.node_repl={command=\"/usr/bin/true\",enabled=false}",
    ]

    /// codex args for the `app-server` subprocess. Same `-c` overrides as
    /// `processArguments` (`approval_policy=never`, `sandbox_mode`). Thread and
    /// turn requests also pin these policies so resumed conversations cannot
    /// restore restrictive permissions from an older rollout.
    /// `extraArgs` is always `[]` in production today (`codexRunnerConfig`
    /// never sets it — that field only carries pi's role `--tools` args) but
    /// is threaded through for the same reason `processArguments` threads it:
    /// a slot for a future per-agent override, not a currently-used one.
    public static func appServerArguments(extraArgs: [String], workspaceMCP: WorkspaceMCPConfiguration? = nil, hookOverrides: [String] = []) -> [String] {
        var args = [
            "-c", "approval_policy=never",
            "-c", "sandbox_mode=\(sandboxMode)",
        ]
        for override in providerComputerUseOverrides { args += ["-c", override] }
        if let workspaceMCP {
            for override in workspaceMCP.codexConfigOverrides { args += ["-c", override] }
        }
        for override in hookOverrides { args += ["-c", override] }
        args += ["app-server"]
        args += extraArgs
        return args
    }

    /// App-server is the default because it is the only Codex transport with
    /// structured provider-owned subagent identity. `exec` remains an explicit
    /// emergency escape hatch.
    public enum Transport: String, Sendable { case exec, appServer }
    public static func transportOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Transport {
        environment["CONTINUUM_CODEX_TRANSPORT"] == "exec" ? .exec : .appServer
    }

    /// The distinguishing app-server JSON-RPC error for a `thread/resume` on a
    /// thread id whose rollout no longer exists — the app-server analogue of
    /// `isUnknownSessionFailure`'s stderr text match, except this one is a
    /// clean error CODE + message rather than parsed stderr. Measured live
    /// (codex-cli 0.148.0): `{"code": -32600, "message": "no rollout found for
    /// thread id <uuid>"}`.
    public static func isUnknownSessionFailure(appServerErrorMessage message: String) -> Bool {
        message.contains("no rollout found for thread id")
    }
}

#if os(macOS)

public final class CodexAgentRunner: @unchecked Sendable {
    public struct Config: Sendable {
        /// Codex-native model argument (already stripped of the `openai-codex/`
        /// catalogue prefix — `CodexCLIBackend.modelArgument`).
        public var model: String
        /// Codex `model_reasoning_effort`, or nil to take the CLI default.
        public var effort: String?
        public var cwd: URL
        /// The stored codex thread id, or nil for a fresh turn. Read back from
        /// `AgentRecord.codexThreadId`.
        public var threadId: String?
        /// Extra args before the prompt.
        public var extraArgs: [String]
        public var workspaceMCP: WorkspaceMCPConfiguration?
        /// The agent id every descendant carries — `PiAgentRunner.childEnvironment`.
        public var processOwner: String?
        /// .plans/101 — the account's home, passed as `CODEX_HOME`. nil keeps
        /// the CLI's own (inherited) home.
        public var codexHome: String?
        public init(
            model: String,
            effort: String? = nil,
            cwd: URL,
            threadId: String? = nil,
            extraArgs: [String] = [],
            workspaceMCP: WorkspaceMCPConfiguration? = nil,
            processOwner: String? = nil,
            codexHome: String? = nil
        ) {
            self.codexHome = codexHome
            self.model = model
            self.effort = effort
            self.cwd = cwd
            self.threadId = threadId
            self.extraArgs = extraArgs
            self.workspaceMCP = workspaceMCP
            self.processOwner = processOwner
        }
    }

    public enum RunError: Error, CustomStringConvertible, AgentRunFailureDescribing {
        case launchFailed(String)
        case codexFailed(exitCode: Int32, stderr: String)
        /// app-server path only: a JSON-RPC request failed for a reason other
        /// than the resume self-heal (`isUnknownSessionFailure`).
        case appServerFailed(String)
        /// app-server path only: the process went away before its own
        /// `turn/completed`. Carries what it wrote to stderr.
        case exitedMidTurn(stderr: String)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .codexFailed(let exitCode, let stderr):
                return "codexFailed(exitCode: \(exitCode), stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
            case .appServerFailed(let message):
                return "appServerFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .exitedMidTurn(let stderr):
                return "exitedMidTurn(stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
            }
        }

        public var userFacingDescription: String {
            switch self {
            case .launchFailed(let message):
                return "Codex could not start: \(SecretRedactor.redactLocalDiagnostics(message))"
            case .codexFailed(let exitCode, let stderr):
                let head = "Codex exited (code \(exitCode)) without finishing the turn"
                return AgentFailureText.stderrTail(stderr).map { "\(head): \($0)" } ?? "\(head)."
            case .appServerFailed(let message):
                return "Codex: \(SecretRedactor.redactLocalDiagnostics(message))"
            case .exitedMidTurn(let stderr):
                let head = "Codex exited without finishing the turn"
                return AgentFailureText.stderrTail(stderr).map { "\(head): \($0)" } ?? "\(head)."
            }
        }

        public var isProcessLoss: Bool {
            switch self {
            case .codexFailed, .exitedMidTurn: return true
            case .launchFailed, .appServerFailed: return false
            }
        }
    }

    /// Absolute-path resolution with the same GUI-thin-PATH strategy as pi's and
    /// claude's: prefer an absolute `codex` from PATH + well-known dirs, fall
    /// back to `/usr/bin/env codex`. Pure for pinning. (codex here is a node
    /// script under nvm, so PATH augmentation with node's dir is needed — the
    /// same `PiAgentRunner.liveExtraDirs` the claude runner uses.)
    public static func resolvedCommand(
        pathDirs: [String],
        extraDirs: [String],
        fileExists: @escaping @Sendable (String) -> Bool
    ) -> PiAgentRunner.ResolvedCommand {
        let detector = ToolDetector(fileExists: fileExists)
        if let absolute = detector.locate("codex", in: pathDirs + extraDirs) {
            return PiAgentRunner.ResolvedCommand(executable: absolute, prefixArgs: [])
        }
        return PiAgentRunner.ResolvedCommand(executable: "/usr/bin/env", prefixArgs: ["codex"])
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

    /// Availability = an absolute `codex` actually resolves (the env fallback
    /// proves nothing). Cheap — file stats only — so the supervisor can consult
    /// it on the spawn path.
    public static func liveCLIAvailable() -> Bool {
        liveResolvedCommand().prefixArgs.isEmpty
    }

    public let config: Config
    public var compactionCapabilities: AgentCompactionCapabilities {
        let appServer = CodexCLIBackend.transportOverride() == .appServer
        let hasThread = config.threadId?.isEmpty == false
        return AgentCompactionCapabilities(
            supportsManual: appServer && hasThread,
            supportsFocus: false,
            unavailableReason: !appServer
                ? "Codex compaction requires the app-server transport"
                : (hasThread ? nil : "Nothing to compact yet")
        )
    }
    private let queue = DispatchQueue(label: "continuum.codex-agent-runner")
    private var translator: CodexEventTranslator
    private var buffer = Data()
    private var stderrBuffer = Data()   // queue-confined
    private var pendingTerminalEvents: [AgentRuntimeEvent] = [] // queue-confined
    /// M1.8: see `ProcessGroupChild`. Queue-confined (set in run, read in stop).
    private var child: ProcessGroupChild?
    private var stopRequested = false   // queue-confined; suppresses the self-heal
    private var runtimeObservationHandler: (@Sendable (AgentRuntimeObservation) -> Void)?

    // MARK: - app-server transport (queue-confined; nil on the exec path)
    private var appServerTranslator = CodexAppServerEventTranslator()
    /// The live JSON-RPC connection for the turn in flight, so `stop()` (called
    /// from an arbitrary thread) can send `turn/interrupt` before the group-wide
    /// SIGTERM. Set right after `thread/start`/`thread/resume` succeeds, cleared
    /// when the turn ends.
    private var appServerTransport: CodexAppServerTransport?
    private var appServerActiveTurn: (threadId: String, turnId: String)?
    /// Set right after `turn/start`'s response; signaled by the notification
    /// handler once THIS thread/turn's `turn/completed` is observed. One per
    /// turn — `runOnceAppServer` owns the whole lifecycle of a single value.
    private var appServerTurnCompletion: (threadId: String, turnId: String, semaphore: DispatchSemaphore)?
    private var appServerTurnOutcome: AgentRuntimeEvent?
    private var appServerPrimaryThreadID: String?
    private var appServerLiveChildThreads: Set<String> = []
    private var appServerTurnAccepted = false
    private var providerSubagentActivityHandler: (@Sendable (ProviderSubagentActivity) -> Void)?
    /// Child threads with a turn open, by provider thread id → turn id.
    private var appServerChildTurns: [String: String] = [:]
    private var steerDispositionHandler: (@Sendable (UUID, AgentSteerDisposition) -> Void)?

    public init(config: Config) {
        self.config = config
        self.translator = CodexEventTranslator(workingDirectory: config.cwd)
    }

    /// Runs codex with `prompt`, streaming events to `onEvent` until it exits.
    /// Blocking; call off the main thread. `onEvent` is invoked on the runner's
    /// serial queue. Chooses fresh-vs-resume up front from stored state (unlike
    /// claude's resume-first probe): with no stored id it starts fresh; with a
    /// stored id it resumes and, only if that fails as an unknown/stale thread,
    /// self-heals to a fresh `exec` (which mints — and the observation persists —
    /// a NEW id).
    public func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        if CodexCLIBackend.transportOverride() == .appServer {
            do {
                try runAppServer(prompt: prompt, onEvent: onEvent)
                return
            } catch {
                // Startup compatibility fallback only. Once Codex accepted
                // `turn/start`, replaying the prompt through exec could repeat
                // filesystem or network side effects.
                let canFallback = queue.sync { !appServerTurnAccepted && !stopRequested }
                guard canFallback else { throw error }
            }
        }
        if config.threadId == nil {
            let result = try runOnce(mode: .fresh, threadId: nil, prompt: prompt, onEvent: onEvent)
            publish(result.finalEvents, onEvent: onEvent)
            if result.exitCode != 0 {
                try throwStoppedIfRequested(stderr: result.stderr)
                throw RunError.codexFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            return
        }
        let resumed = try runOnce(mode: .resume, threadId: config.threadId, prompt: prompt, onEvent: onEvent)
        if resumed.exitCode == 0 {
            publish(resumed.finalEvents, onEvent: onEvent)
            return
        }
        // Self-heal: a stored id whose rollout was deleted/archived/cleaned.
        guard CodexCLIBackend.isUnknownSessionFailure(stderr: resumed.stderr) else {
            publish(resumed.finalEvents, onEvent: onEvent)
            // M1.7: same as claude -- the flag was read only to gate the self-heal
            // BELOW, with three unguarded throws in front of it.
            try throwStoppedIfRequested(stderr: resumed.stderr)
            throw RunError.codexFailed(exitCode: resumed.exitCode, stderr: resumed.stderr)
        }
        let shouldHeal: Bool = queue.sync { !stopRequested }
        guard shouldHeal else {
            publish(resumed.finalEvents, onEvent: onEvent)
            throw AgentRunStopped(detail: resumed.stderr)
        }
        // The rejected resume's terminal/accounting/rollout telemetry is
        // deliberately dropped. A new translator gives the fresh process a
        // clean thread/turn identity and prevents stale-attempt state leaking.
        let fresh = try runOnce(mode: .fresh, threadId: nil, prompt: prompt, onEvent: onEvent)
        publish(fresh.finalEvents, onEvent: onEvent)
        if fresh.exitCode != 0 {
            try throwStoppedIfRequested(stderr: fresh.stderr)
            throw RunError.codexFailed(exitCode: fresh.exitCode, stderr: fresh.stderr)
        }
    }

    /// A dedicated app-server operation: initialize → resume → compact → wait
    /// for the provider boundary. It intentionally has no exec/prompt fallback.
    public func compact(
        _ request: AgentCompactionRequest,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        guard request.focus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw RunError.appServerFailed("Codex compaction does not accept focus instructions")
        }
        guard compactionCapabilities.supportsManual, let threadId = config.threadId else {
            throw RunError.appServerFailed(
                compactionCapabilities.unavailableReason ?? "compaction unavailable")
        }

        let command = Self.liveResolvedCommand()
        let arguments = command.prefixArgs + CodexCLIBackend.appServerArguments(extraArgs: config.extraArgs, workspaceMCP: config.workspaceMCP, hookOverrides: hookOverrides(command: command))
        let spawned: ProcessGroupChild
        do {
            spawned = try ProcessGroupChild.spawn(
                executable: command.executable,
                arguments: arguments,
                environment: childEnvironment(),
                currentDirectory: config.cwd,
                standardInput: .pipe)
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        queue.sync {
            child = spawned
            appServerTranslator = CodexAppServerEventTranslator(
                workingDirectory: config.cwd,
                compactionOperationID: request.operationID,
                compactionTrigger: .manual)
            appServerTranslator.onRuntimeObservation = runtimeObservationHandler
        }

        // Match the normal app-server turn path: an unread stderr pipe can
        // fill and block Codex before it writes the compaction boundary.
        let stderrTail = AgentStderrTail()
        spawned.standardError.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderrTail.append(chunk) }
        }

        let completion = DispatchSemaphore(value: 0)
        var terminal: AgentCompactionLifecycleEvent?
        var compactionTurnFailure: String?
        var signaled = false
        let transport = CodexAppServerTransport(child: spawned) { [weak self] line in
            guard let self else { return }
            self.queue.sync {
                for event in self.appServerTranslator.translate(line: line) {
                    switch event {
                    // app-server runs a compaction as its own provider TURN
                    // (measured on 0.159.3: `turn/started`, the
                    // `contextCompaction` item, `turn/completed`). That turn is
                    // this operation, not a user turn: forwarding its start
                    // armed the tile's presence, and the `turn/completed` that
                    // follows the item by ~2ms was still in the pipe when the
                    // transport shut — the tile sat "Working · Thinking"
                    // forever. Claude's `compact()` forwards no turn boundary
                    // either; the compaction lifecycle is the terminal.
                    case .turnStarted:
                        continue
                    case .turnCompleted(let eventThreadID, _, _, let errorMessage):
                        // A compaction turn that ends without its item
                        // completing ends the operation too, rather than
                        // waiting out the timeout.
                        if eventThreadID == threadId, terminal == nil, !signaled {
                            compactionTurnFailure = errorMessage
                                ?? "compaction turn ended without a contextCompaction item"
                            signaled = true
                            completion.signal()
                        }
                        continue
                    case .compactionChanged(let eventThreadID, let lifecycle)
                        where eventThreadID == threadId
                            && [.succeeded, .failed, .cancelled, .indeterminate].contains(lifecycle.phase):
                        onEvent(event)
                        terminal = lifecycle
                        if !signaled { signaled = true; completion.signal() }
                    default:
                        onEvent(event)
                    }
                }
            }
        }
        queue.sync { appServerTransport = transport }
        defer {
            transport.shutdown()
            spawned.terminateGroup(graceSeconds: ProcessGroupChild.Grace.harness)
            spawned.standardError.readabilityHandler = nil
            queue.sync { child = nil; appServerTransport = nil }
        }

        _ = try transport.sendRequest(
            method: "initialize",
            params: [
                "clientInfo": ["name": "array", "title": "Array", "version": "0.0.1"],
                "capabilities": ["experimentalApi": true],
            ],
            timeout: 15)
        try transport.sendNotification(method: "initialized", params: [:])

        if let configResult = try? transport.sendRequest(
            method: "config/read", params: [:], timeout: 5),
           let policy = Self.automaticCompactionPolicy(fromConfigRead: configResult) {
            onEvent(.contextWindowUpdated(
                threadId: threadId,
                snapshot: AgentContextWindowSnapshot(
                    automaticCompactionPolicy: policy,
                    observedAt: Date(),
                    source: .unknown("codex-config-read"),
                    freshness: .live)))
        }
        _ = try transport.sendRequest(
            method: "thread/resume",
            params: [
                "threadId": threadId, "model": config.model,
                "sandbox": CodexCLIBackend.sandboxMode, "approvalPolicy": "never",
            ],
            timeout: 30)
        _ = try transport.sendRequest(
            method: "thread/compact/start",
            params: ["threadId": threadId],
            timeout: 15)

        let exitWatcher = Thread {
            _ = spawned.wait()
            completion.signal()
        }
        exitWatcher.start()
        // Compaction is provider work, just like a normal turn: a large
        // context or provider retry can legitimately take over two minutes.
        // Wait for its terminal event; process exit (including Stop's group
        // termination) also signals completion so cancellation cannot hang.
        completion.wait()
        try throwStoppedIfRequested(stderr: "")
        let outcome = queue.sync { (terminal: terminal, failure: compactionTurnFailure) }
        guard let terminal = outcome.terminal else {
            if let failure = outcome.failure { throw RunError.appServerFailed(failure) }
            throw RunError.exitedMidTurn(stderr: stderrTail.text)
        }
        if terminal.phase == .failed {
            throw RunError.appServerFailed(terminal.errorMessage ?? "compaction failed")
        }
    }

    /// M1.7: consult the stop flag before every throw. See `AgentRunStopped`.
    private func throwStoppedIfRequested(stderr: String) throws {
        if queue.sync { stopRequested } { throw AgentRunStopped(detail: stderr) }
    }

    // MARK: - app-server transport

    /// The app-server analogue of `run(prompt:onEvent:)`: same fresh-vs-resume
    /// decision and the same self-heal-on-unknown-thread shape as the exec
    /// path, but resume failure is read off a JSON-RPC error CODE
    /// (`isUnknownSessionFailure(appServerErrorMessage:)`), never stderr text.
    ///
    /// Still process-per-turn at the OS level — one `codex app-server`
    /// subprocess is spawned, driven through exactly one turn, and torn down
    /// before this method returns. A single persistent process for the
    /// agent's WHOLE life (what `.plans/46` calls for) needs a live connection
    /// held BETWEEN `run()` calls, but `AgentSupervisor.codexRunner(for:)`
    /// constructs a fresh `CodexAgentRunner` for every send
    /// (`AgentSupervisor.swift`, off-limits to this ticket — see the report).
    /// What this DOES fix relative to exec: the transport is real JSON-RPC
    /// (clean request/response correlation, no stderr text matching), and the
    /// notification path has no terminal-event gate — every method is
    /// forwarded to `onEvent` as it streams, exactly as
    /// `CodexAppServerEventTranslator` already assumes.
    private func runAppServer(
        prompt: AgentPrompt,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        if config.threadId == nil {
            try runOnceAppServer(mode: .fresh, threadId: nil, prompt: prompt, onEvent: onEvent)
            return
        }
        do {
            try runOnceAppServer(mode: .resume, threadId: config.threadId, prompt: prompt, onEvent: onEvent)
            return
        } catch let error as CodexAppServerTransport.RPCError
            where CodexCLIBackend.isUnknownSessionFailure(appServerErrorMessage: error.message) {
            // Self-heal: a stored id whose rollout was deleted/archived/cleaned.
            // Same shape as exec's self-heal — the rejected resume's state is
            // deliberately dropped, and a fresh translator/thread starts clean.
            try throwStoppedIfRequested(stderr: "")
            try runOnceAppServer(mode: .fresh, threadId: nil, prompt: prompt, onEvent: onEvent)
        }
    }

    /// One app-server subprocess, driven through initialize → thread/start (or
    /// thread/resume) → turn/start → wait for the primary turn AND every
    /// announced child thread to complete → teardown. The app-server can emit a
    /// child's final frames after the parent's `turn/completed`; keeping one live
    /// child set here prevents teardown from truncating those frames. The pure
    /// translator independently remains ungated and is verified by
    /// `CodexAppServerParityChecks`; the process-lifetime half is verified by the
    /// late-child scenario in `CodexAppServerRunnerChecks`.
    private func runOnceAppServer(
        mode: CodexCLIBackend.SessionMode,
        threadId: String?,
        prompt: AgentPrompt,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws {
        let command = Self.liveResolvedCommand()
        let arguments = command.prefixArgs + CodexCLIBackend.appServerArguments(extraArgs: config.extraArgs, workspaceMCP: config.workspaceMCP, hookOverrides: hookOverrides(command: command))

        queue.sync {
            appServerTranslator = CodexAppServerEventTranslator(workingDirectory: config.cwd)
            appServerTranslator.onRuntimeObservation = runtimeObservationHandler
            appServerPrimaryThreadID = nil
            appServerLiveChildThreads.removeAll()
            appServerChildTurns.removeAll()
            appServerTurnAccepted = false
            appServerTurnOutcome = nil
            appServerTranslator.onSubagentAnnouncement = { [weak self] parent, child, item, label in
                guard let self else { return }
                self.appServerLiveChildThreads.insert(child)
                self.providerSubagentActivityHandler?(.childAnnounced(
                    parentProviderThreadID: parent,
                    childProviderThreadID: child,
                    sourceItemID: item,
                    displayLabel: label
                ))
            }
        }

        let spawned: ProcessGroupChild
        do {
            spawned = try ProcessGroupChild.spawn(
                executable: command.executable,
                arguments: arguments,
                environment: childEnvironment(),
                currentDirectory: config.cwd,
                standardInput: .pipe)
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        queue.sync { self.child = spawned }
        // S3: drained into a bounded tail. Never read before, so a crash said
        // nothing, and a chatty app-server could fill the pipe and block.
        let stderrTail = AgentStderrTail()
        spawned.standardError.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderrTail.append(chunk) }
        }

        let transport = CodexAppServerTransport(child: spawned) { [weak self] line in
            guard let self else { return }
            self.queue.sync {
                let providerThreadID = Self.appServerThreadID(in: line)
                let events = self.appServerTranslator.translate(line: line)
                for event in events {
                    if case .turnCompleted(let eventThreadId, let eventTurnId, _, _) = event {
                        if eventThreadId == self.appServerPrimaryThreadID,
                           self.appServerTurnCompletion?.turnId == nil
                            || eventTurnId == self.appServerTurnCompletion?.turnId {
                            self.appServerTurnOutcome = event
                        } else {
                            self.appServerLiveChildThreads.remove(eventThreadId)
                        }
                    }
                    if let providerThreadID,
                       let primary = self.appServerPrimaryThreadID,
                       providerThreadID != primary {
                        switch event {
                        case let .turnStarted(_, childTurnId):
                            self.appServerChildTurns[providerThreadID] = childTurnId
                            // A child that starts after Stop was asked for is
                            // stopped on arrival. Off this queue: the reply is
                            // read by the transport thread that called us.
                            if self.stopRequested, let transport = self.appServerTransport {
                                DispatchQueue.global(qos: .userInitiated).async {
                                    _ = try? transport.sendRequest(
                                        method: "turn/interrupt",
                                        params: ["threadId": providerThreadID, "turnId": childTurnId],
                                        timeout: 2.0)
                                }
                            }
                        case .turnCompleted:
                            self.appServerChildTurns[providerThreadID] = nil
                        default:
                            break
                        }
                        self.providerSubagentActivityHandler?(.threadEvent(
                            providerThreadID: providerThreadID,
                            event: event
                        ))
                    } else {
                        onEvent(event)
                    }
                }
                if let expected = self.appServerTurnCompletion,
                   self.appServerTurnOutcome != nil,
                   self.appServerLiveChildThreads.isEmpty {
                    expected.semaphore.signal()
                }
            }
        }

        defer {
            transport.shutdown()
            spawned.terminateGroup(graceSeconds: ProcessGroupChild.Grace.harness)
            spawned.standardError.readabilityHandler = nil
            queue.sync {
                // Every descendant lives inside this one app-server process, so
                // none outlives it: a child still open here was cut off by Stop
                // or a crash and is settled now, not left "working".
                let cutOff = self.appServerLiveChildThreads.union(self.appServerChildTurns.keys)
                for thread in cutOff.sorted() {
                    self.providerSubagentActivityHandler?(.threadEvent(
                        providerThreadID: thread,
                        event: .turnCompleted(
                            threadId: thread,
                            turnId: self.appServerChildTurns[thread] ?? "\(thread)#app-server-exited",
                            outcome: .interrupted,
                            errorMessage: "The Codex session ended before this child finished.")))
                }
                self.appServerChildTurns.removeAll()
                self.child = nil
                self.appServerTransport = nil
                self.appServerActiveTurn = nil
                self.appServerTurnCompletion = nil
                self.appServerPrimaryThreadID = nil
                self.appServerLiveChildThreads.removeAll()
            }
        }

        _ = try transport.sendRequest(
            method: "initialize",
            params: [
                "clientInfo": ["name": "array", "title": "Array", "version": "0.0.1"],
                "capabilities": ["experimentalApi": true],
            ],
            timeout: 15)
        try transport.sendNotification(method: "initialized", params: [:])
        if let configResult = try? transport.sendRequest(
            method: "config/read", params: [:], timeout: 5),
           let policy = Self.automaticCompactionPolicy(fromConfigRead: configResult) {
            onEvent(.contextWindowUpdated(
                threadId: config.threadId ?? "codex-pending",
                snapshot: AgentContextWindowSnapshot(
                    automaticCompactionPolicy: policy,
                    observedAt: Date(),
                    source: .unknown("codex-config-read"),
                    freshness: .live)))
        }

        let resolvedThreadId: String
        switch mode {
        case .fresh:
            let result = try transport.sendRequest(
                method: "thread/start",
                params: [
                    "cwd": config.cwd.path,
                    "model": config.model,
                    "sandbox": CodexCLIBackend.sandboxMode,
                    "approvalPolicy": "never",
                    "skipGitRepoCheck": true,
                    "multiAgentMode": "explicitRequestOnly",
                ],
                timeout: 30)
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty
            else { throw RunError.appServerFailed("thread/start returned no thread id") }
            resolvedThreadId = id
        case .resume:
            let id = threadId ?? ""
            _ = try transport.sendRequest(
                method: "thread/resume",
                params: [
                    "threadId": id, "model": config.model,
                    "sandbox": CodexCLIBackend.sandboxMode, "approvalPolicy": "never",
                ],
                timeout: 30)
            resolvedThreadId = id
            // Measured 2026-08-24: unlike a fresh `thread/start`, a successful
            // `thread/resume` emits NO `thread/started` notification — so
            // without this, the translator's session-ready/running events (and
            // its `onRuntimeObservation(.threadId(...))` projection) would
            // never fire for a resumed turn. `codex exec resume` does not have
            // this gap: it re-emits `thread.started` with the same id every
            // time (`CodexEventTranslator.swift:77-88`). Synthesizing the
            // notification here reuses the translator's own parsing rather
            // than duplicating its session-start logic.
            let synthetic = "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"\(id)\"}}}"
            queue.sync {
                for event in appServerTranslator.translate(line: synthetic) { onEvent(event) }
            }
        }

        queue.sync {
            appServerPrimaryThreadID = resolvedThreadId
            providerSubagentActivityHandler?(.primaryThread(providerThreadID: resolvedThreadId))
        }

        var turnParams: [String: Any] = [
            "threadId": resolvedThreadId,
            "input": [["type": "text", "text": CodexCLIBackend.promptArgument(prompt)]],
            "sandboxPolicy": ["type": "dangerFullAccess"],
            "approvalPolicy": "never",
        ]
        if let effort = config.effort { turnParams["effort"] = effort }
        let turnResult = try transport.sendRequest(method: "turn/start", params: turnParams, timeout: 15)
        guard let turn = turnResult["turn"] as? [String: Any], let turnId = turn["id"] as? String, !turnId.isEmpty
        else { throw RunError.appServerFailed("turn/start returned no turn id") }

        let semaphore = DispatchSemaphore(value: 0)
        queue.sync {
            self.appServerTransport = transport
            self.appServerActiveTurn = (resolvedThreadId, turnId)
            self.appServerTurnCompletion = (resolvedThreadId, turnId, semaphore)
            self.appServerTurnAccepted = true
            if self.appServerTurnOutcome != nil, self.appServerLiveChildThreads.isEmpty {
                semaphore.signal()
            }
        }

        // No timeout on the wait itself: matches `spawned.wait()`'s unbounded
        // block on the exec path, and does NOT gate notification forwarding —
        // every method still translates and forwards independently of this
        // wait, exactly as `CodexAppServerEventTranslator` has no gate. An
        // announced child keeps this wait unresolved after the primary's
        // completion until that child's own terminal event arrives. `stop()`
        // unblocks it two ways: `turn/interrupt` over the live connection
        // produces a `turn/completed(status: interrupted)` notification
        // (measured live) which resolves it normally, OR — if that races
        // (`stop()` reads `appServerActiveTurn` before it's set) or the
        // connection is wedged — the group-wide SIGTERM/SIGKILL below still
        // kills the process, and THIS thread is what turns that into a
        // return instead of a permanent hang: without it, a killed process
        // that never got to send `turn/completed` blocks here forever.
        // Detached deliberately: in the ordinary success path the process is
        // still alive here (it is only killed by the OUTER `defer` above,
        // AFTER this method returns), so this thread outlives `wait()` below
        // and exits on its own once that later kill actually happens — an
        // extra harmless `semaphore.signal()` after `wait()` has already
        // returned is a no-op.
        let exitWatcher = Thread {
            _ = spawned.wait()
            semaphore.signal()
        }
        exitWatcher.start()
        semaphore.wait()
        try throwStoppedIfRequested(stderr: "")
        let outcome = queue.sync { self.appServerTurnOutcome }
        guard case .turnCompleted(_, _, let turnOutcome, let errorMessage) = outcome else {
            // Let the pipe's last bytes land before reading the tail.
            Thread.sleep(forTimeInterval: 0.05)
            throw RunError.exitedMidTurn(stderr: stderrTail.text)
        }
        if turnOutcome == .failed {
            throw RunError.appServerFailed(errorMessage ?? "turn failed")
        }
    }

    /// Text-only compatibility wrapper, matching the other runners'.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    public func stop() {
        let (running, transport, activeTurn, childTurns) = queue.sync {
            () -> (ProcessGroupChild?, CodexAppServerTransport?, (threadId: String, turnId: String)?, [(String, String)]) in
            stopRequested = true
            return (child, appServerTransport, appServerActiveTurn, appServerChildTurns.map { ($0.key, $0.value) })
        }
        // Stop is for the whole family: interrupting the parent alone left every
        // child thread running, and "working" in the sidebar, until it finished.
        if let transport, !childTurns.isEmpty {
            DispatchQueue.concurrentPerform(iterations: childTurns.count) { index in
                _ = try? transport.sendRequest(
                    method: "turn/interrupt",
                    params: ["threadId": childTurns[index].0, "turnId": childTurns[index].1],
                    timeout: 2.0)
            }
        }
        // app-server only: ask for a graceful interrupt over the live
        // connection first (M7 item 4 — the analogue of `turn/interrupt`).
        // Best-effort with a short timeout so a wedged connection can't block
        // Stop; the group-wide SIGTERM/SIGKILL escalation right below is the
        // backstop regardless of whether this succeeds.
        if let transport, let activeTurn {
            try? transport.sendRequest(
                method: "turn/interrupt",
                params: ["threadId": activeTurn.threadId, "turnId": activeTurn.turnId],
                timeout: 2.0)
        }
        // M1.8: the whole GROUP, at the interactive grace. See `ProcessGroupChild`.
        running?.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
    }

    // MARK: - T5 steering and interrupt (app-server only)

    /// True while an app-server turn is live on its own connection. The
    /// app-server process lives exactly as long as the turn: thread state is
    /// codex's rollout, `thread/resume` is cheap, and a per-turn process keeps
    /// the late-child drain and teardown below unchanged. Steering only needs
    /// the connection while the turn runs, which this already holds.
    public var acceptsSteerNow: Bool {
        queue.sync { !stopRequested && appServerTransport != nil && appServerActiveTurn != nil }
    }

    /// `turn/steer` into the active turn, pinned by `expectedTurnId` so a steer
    /// can never land in a turn other than the one the user watched. The
    /// response IS the receipt. A turn that already ended, or a review/compact
    /// turn codex will not steer, refuses — and the supervisor keeps the
    /// message for the next turn instead.
    public func steer(_ prompt: AgentPrompt, id: UUID) throws {
        let (transport, activeTurn, handler) = queue.sync {
            () -> (CodexAppServerTransport?, (threadId: String, turnId: String)?, (@Sendable (UUID, AgentSteerDisposition) -> Void)?) in
            (stopRequested ? nil : appServerTransport, appServerActiveTurn, steerDispositionHandler)
        }
        guard let transport, let activeTurn else {
            throw AgentSteerNotAccepted("no codex app-server turn is in flight")
        }
        do {
            _ = try transport.sendRequest(
                method: "turn/steer",
                params: [
                    "threadId": activeTurn.threadId,
                    "expectedTurnId": activeTurn.turnId,
                    "input": [["type": "text", "text": CodexCLIBackend.promptArgument(prompt)]],
                    "clientUserMessageId": id.uuidString,
                ],
                timeout: 5)
        } catch {
            throw AgentSteerNotAccepted(String(describing: error))
        }
        handler?(id, .consumed)
    }

    /// `turn/interrupt` and nothing else: the turn ends `interrupted` and
    /// `run` returns normally. Killing is `stop()`'s job, the fallback.
    public func interrupt() throws {
        let (transport, activeTurn) = queue.sync {
            () -> (CodexAppServerTransport?, (threadId: String, turnId: String)?) in
            (appServerTransport, appServerActiveTurn)
        }
        guard let transport, let activeTurn else {
            throw RunError.appServerFailed("no codex app-server turn to interrupt")
        }
        _ = try transport.sendRequest(
            method: "turn/interrupt",
            params: ["threadId": activeTurn.threadId, "turnId": activeTurn.turnId],
            timeout: 5)
    }

    public func observeSteerDispositions(
        _ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void
    ) {
        queue.sync { steerDispositionHandler = handler }
    }

    /// Exec has no structured subagent side channel. App-server reports through
    /// `ProviderSubagentActivityObserving` below instead of pretending an
    /// Array-owned `spawn_agent` request occurred.
    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}

    public func observeProviderSubagentActivity(
        _ handler: @escaping @Sendable (ProviderSubagentActivity) -> Void
    ) {
        queue.sync { providerSubagentActivityHandler = handler }
    }

    public func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {
        queue.sync {
            runtimeObservationHandler = handler
            translator.onRuntimeObservation = handler
        }
    }

    private static func automaticCompactionPolicy(
        fromConfigRead result: [String: Any]
    ) -> AgentAutomaticCompactionPolicy? {
        let config = result["config"] as? [String: Any] ?? result
        let limit: Int? = {
            if let value = config["model_auto_compact_token_limit"] as? Int { return value }
            if let value = config["model_auto_compact_token_limit"] as? NSNumber { return value.intValue }
            return nil
        }()
        let scope = config["model_auto_compact_token_limit_scope"] as? String
        guard limit != nil || scope != nil else { return nil }
        return AgentAutomaticCompactionPolicy(
            enabled: limit.map { $0 > 0 }, thresholdTokens: limit, thresholdScope: scope)
    }

    private func hookOverrides(command: PiAgentRunner.ResolvedCommand) -> [String] {
        guard let workspaceMCP = config.workspaceMCP else { return [] }
        return AgentHookSurfaceCatalog.shared.codexOverrides(command: command, hookCommand: workspaceMCP.claudeHookCommand)
    }

    // MARK: - one spawn

    private func runOnce(
        mode: CodexCLIBackend.SessionMode,
        threadId: String?,
        prompt: AgentPrompt,
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) throws -> (exitCode: Int32, stderr: String, finalEvents: [AgentRuntimeEvent]) {
        let startingRolloutURL = threadId.flatMap { CodexRolloutTelemetry.rolloutURL(threadId: $0) }
        let startingOffset = startingRolloutURL.flatMap { CodexRolloutTelemetry.fileSize(of: $0) } ?? 0
        let command = Self.liveResolvedCommand()
        let arguments = command.prefixArgs + CodexCLIBackend.processArguments(
            model: config.model,
            effort: config.effort,
            sessionMode: mode,
            threadId: threadId,
            cwdPath: config.cwd.path,
            extraArgs: config.extraArgs,
            prompt: prompt,
            workspaceMCP: config.workspaceMCP,
            hookOverrides: hookOverrides(command: command)
        )

        queue.sync {
            buffer.removeAll()
            stderrBuffer.removeAll()
            pendingTerminalEvents.removeAll()
            translator = CodexEventTranslator(workingDirectory: config.cwd)
            translator.onRuntimeObservation = runtimeObservationHandler
        }

        let spawned: ProcessGroupChild
        do {
            spawned = try ProcessGroupChild.spawn(
                executable: command.executable,
                arguments: arguments,
                // Same GUI-thin-PATH augmentation as pi's/claude's: an npm-installed
                // codex is a node script whose shebang needs node on PATH. HOME and the
                // codex config dir stay untouched — overriding HOME relocates the login
                // lookup and the CLI stops finding its own auth.
                environment: childEnvironment(),
                // Set the cwd on BOTH paths: resume can't take `-C`, and it is harmless
                // on fresh (which also passes `-C`).
                currentDirectory: config.cwd,
                // Live turns printed "Reading additional input from stdin…" even with a
                // positional prompt; a null stdin removes any chance of a block. This
                // is the one runner that must NOT inherit the app's stdin.
                standardInput: .nullDevice
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
        // Drain stderr CONCURRENTLY (the pi/claude deadlock lesson: a full 64KB
        // stderr pipe blocks the child while we block waiting for it to exit).
        spawned.standardError.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.stderrBuffer.append(chunk) }
        }

        let exitCode = spawned.wait()
        spawned.standardOutput.readabilityHandler = nil
        spawned.standardError.readabilityHandler = nil

        // Bounded, never `readDataToEndOfFile()`: a descendant that inherited
        // fd 1/2 keeps the write end open after the leader exits, and the
        // unbounded read then blocks until that process dies — potentially
        // forever. Kill the group's leftovers first so the pipes close (a clean
        // exit leaves nothing, making this a no-op).
        spawned.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        let remainder = ProcessGroupChild.drainRemainder(of: spawned.standardOutput)
        let stderrRemainder = ProcessGroupChild.drainRemainder(of: spawned.standardError)
        let finalState: (stderr: String, threadId: String?, terminal: [AgentRuntimeEvent]) = queue.sync {
            if !remainder.isEmpty { consume(remainder, onEvent: onEvent) }
            flushBuffer(onEvent: onEvent)
            stderrBuffer.append(stderrRemainder)
            let text = String(decoding: stderrBuffer, as: UTF8.self)
            let providerThreadId = translator.providerThreadId
            let terminal = pendingTerminalEvents
            self.child = nil
            return (text, providerThreadId, terminal)
        }
        let providerThreadId = finalState.threadId ?? threadId
        // A resumed archived rollout can be moved back into sessions. Keep the
        // current-run offset while the original path still exists; if it was
        // moved, resolve the same exact thread again and treat the new file as
        // this run's file. Never fall back to offset zero on an unchanged file,
        // which would republish an old request when this process made none.
        let originalStillExists = startingRolloutURL.flatMap {
            CodexRolloutTelemetry.fileSize(of: $0)
        } != nil
        let resolvedURL: URL? = originalStillExists
            ? startingRolloutURL
            : providerThreadId.flatMap { CodexRolloutTelemetry.rolloutURL(threadId: $0) }
        let readOffset = originalStillExists ? startingOffset : 0
        let snapshot = resolvedURL.flatMap {
            CodexRolloutTelemetry.latestSnapshot(
                in: $0,
                afterOffset: readOffset,
                freshness: .live)
        }
        let finalEvents = CodexRolloutTelemetry.orderedFinalEvents(
            threadId: providerThreadId ?? "codex-unknown",
            terminalEvents: finalState.terminal,
            snapshot: snapshot)
        return (exitCode, finalState.stderr, finalEvents)
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
        let events = translator.translate(line: line)
        let isTerminal = events.contains {
            if case .turnCompleted = $0 { return true }
            return false
        }
        if isTerminal {
            pendingTerminalEvents.append(contentsOf: events)
            return
        }
        for event in events {
            onEvent(event)
        }
    }

    private func publish(
        _ events: [AgentRuntimeEvent],
        onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) {
        queue.sync { events.forEach(onEvent) }
    }

    private static func appServerThreadID(in line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? [String: Any]
        else { return nil }
        return params["threadId"] as? String
    }

    private func childEnvironment() -> [String: String] {
        Self.childEnvironment(
            workspaceMCP: config.workspaceMCP, processOwner: config.processOwner, codexHome: config.codexHome)
    }

    /// The MCP server's endpoint and token reach it through its own config
    /// (`mcp_servers.array_workspace.env`), never through codex's environment,
    /// which every shell command codex runs inherits.
    public static func childEnvironment(
        workspaceMCP: WorkspaceMCPConfiguration?, processOwner: String? = nil, codexHome: String? = nil
    ) -> [String: String] {
        var environment = PiAgentRunner.childEnvironment(processOwner: processOwner)
        // .plans/101: an account Array added is its own CODEX_HOME, which is
        // where codex keeps that login's auth.json. HOME is never touched.
        if let codexHome, !codexHome.isEmpty { environment["CODEX_HOME"] = codexHome }
        return environment
    }
}

extension CodexAgentRunner: ProviderSubagentActivityObserving {}

#endif  // os(macOS)
