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

        public var description: String {
            switch self {
            case .launchFailed(let message):
                return "launchFailed(\(SecretRedactor.redactLocalDiagnostics(message)))"
            case .codexFailed(let exitCode, let stderr):
                return "codexFailed(exitCode: \(exitCode), stderr: \(SecretRedactor.redactLocalDiagnostics(stderr)))"
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

    /// Text-only compatibility wrapper, matching the other runners'.
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

    /// Codex has no `spawn_agent` side channel (same as claude). The handler is
    /// accepted for seam parity and never fires.
    public func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}

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

        let remainder = spawned.standardOutput.readDataToEndOfFile()
        let stderrRemainder = spawned.standardError.readDataToEndOfFile()
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
}

#endif  // os(macOS)
