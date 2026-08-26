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
    /// The sandbox posture Array pins for every managed codex turn. `-c
    /// sandbox_mode=<this>` works on BOTH `exec` and `exec resume` (unlike the
    /// `-s` flag, which resume rejects), so it is deterministic regardless of
    /// the user's `~/.codex/config.toml`. `workspace-write` lets the agent edit
    /// its workspace and run commands with the network restricted — SAFER than
    /// claude's no-restriction posture while still functional. A single named
    /// constant so switching to `danger-full-access` later is a one-line change.
    public static let sandboxMode = "workspace-write"

    /// `provider/model` catalogue id → the codex `-m` argument. Codex takes the
    /// bare slug (`gpt-5.6-sol`); the `openai-codex/` prefix is Array's
    /// namespacing (identical to pi's, so routing/dedup line up). Pass-through
    /// when there is no prefix.
    public static func modelArgument(forCatalogId id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// pi `--thinking` level → codex `model_reasoning_effort`. Codex's set is
    /// {minimal, low, medium, high}; only an exact match passes through, and
    /// pi-only levels (off/xhigh/max) omit the config so codex takes its own
    /// default. Same exact-match-or-omit rule as `ClaudeCLIBackend`.
    public static let effortLevels: Set<String> = ["minimal", "low", "medium", "high"]
    public static func effortArgument(forThinking thinking: String) -> String? {
        effortLevels.contains(thinking) ? thinking : nil
    }

    /// The catalogue entries the codex backend contributes when the CLI is
    /// present and logged in. Codex's own model slugs (from
    /// `~/.codex/models_cache.json`), namespaced under `openai-codex/` exactly
    /// as pi lists them, so a pi machine's ids dedup against these. Exact ids,
    /// never patterns.
    public static let curatedCatalogModels: [String] = [
        "openai-codex/gpt-5.6-sol",
        "openai-codex/gpt-5.6-terra",
        "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini",
        "openai-codex/gpt-5.3-codex-spark",
    ]
    public static let curatedCatalogDisplayNames: [String: String] = [
        "openai-codex/gpt-5.6-sol": "GPT-5.6 Sol",
        "openai-codex/gpt-5.6-terra": "GPT-5.6 Terra",
        "openai-codex/gpt-5.6-luna": "GPT-5.6 Luna",
        "openai-codex/gpt-5.5": "GPT-5.5",
        "openai-codex/gpt-5.4": "GPT-5.4",
        "openai-codex/gpt-5.4-mini": "GPT-5.4 Mini",
        "openai-codex/gpt-5.3-codex-spark": "GPT-5.3 Codex Spark",
    ]

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
        prompt: AgentPrompt
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
        args += [promptArgument(prompt)]
        return args
    }

    /// Codex takes ONE positional prompt. The visible text and each
    /// attachment's `@/local/file` reference join with newlines — codex reads
    /// @-references itself, same as claude's.
    public static func promptArgument(_ prompt: AgentPrompt) -> String {
        var segments: [String] = []
        if !prompt.text.isEmpty { segments.append(prompt.text) }
        segments.append(contentsOf: prompt.imageAttachments.map(\.piPathReference))
        segments.append(contentsOf: prompt.fileReferences.map(\.piPathReference))
        return segments.joined(separator: "\n")
    }

    /// codex args for the `app-server` subprocess. Same `-c` overrides as
    /// `processArguments` (`approval_policy=never`, `sandbox_mode`) since those
    /// are process-level flags either way; there is no per-thread equivalent.
    /// `extraArgs` is always `[]` in production today (`codexRunnerConfig`
    /// never sets it — that field only carries pi's role `--tools` args) but
    /// is threaded through for the same reason `processArguments` threads it:
    /// a slot for a future per-agent override, not a currently-used one.
    public static func appServerArguments(extraArgs: [String]) -> [String] {
        var args = [
            "-c", "approval_policy=never",
            "-c", "sandbox_mode=\(sandboxMode)",
            "app-server",
        ]
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
        public init(
            model: String,
            effort: String? = nil,
            cwd: URL,
            threadId: String? = nil,
            extraArgs: [String] = []
        ) {
            self.model = model
            self.effort = effort
            self.cwd = cwd
            self.threadId = threadId
            self.extraArgs = extraArgs
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        case launchFailed(String)
        case codexFailed(exitCode: Int32, stderr: String)
        /// app-server path only: a JSON-RPC request failed for a reason other
        /// than the resume self-heal (`isUnknownSessionFailure`), or a turn
        /// ended without ever observing its own `turn/completed`.
        case appServerFailed(String)

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .codexFailed(let exitCode, let stderr):
                return "codexFailed(exitCode: \(exitCode), stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
            case .appServerFailed(let message):
                return "appServerFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
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

    static func liveResolvedCommand() -> PiAgentRunner.ResolvedCommand {
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
        let arguments = command.prefixArgs + CodexCLIBackend.appServerArguments(extraArgs: config.extraArgs)

        queue.sync {
            appServerTranslator = CodexAppServerEventTranslator(workingDirectory: config.cwd)
            appServerTranslator.onRuntimeObservation = runtimeObservationHandler
            appServerPrimaryThreadID = nil
            appServerLiveChildThreads.removeAll()
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
                environment: PiAgentRunner.childEnvironment(),
                currentDirectory: config.cwd,
                standardInput: .pipe)
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        queue.sync { self.child = spawned }

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
            queue.sync {
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

        let resolvedThreadId: String
        switch mode {
        case .fresh:
            let result = try transport.sendRequest(
                method: "thread/start",
                params: [
                    "cwd": config.cwd.path,
                    "model": config.model,
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
                params: ["threadId": id, "model": config.model],
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
            throw RunError.appServerFailed("turn/completed not observed")
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
        let (running, transport, activeTurn) = queue.sync {
            () -> (ProcessGroupChild?, CodexAppServerTransport?, (threadId: String, turnId: String)?) in
            stopRequested = true
            return (child, appServerTransport, appServerActiveTurn)
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
            prompt: prompt
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
                environment: PiAgentRunner.childEnvironment(),
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
}

extension CodexAgentRunner: ProviderSubagentActivityObserving {}

#endif  // os(macOS)
