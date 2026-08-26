import Foundation

/// Live `pi --list-models` catalogue (follow-up to P0.10's explicit-model-id
/// work).
///
/// P0.10 froze the picker to a literal snapshot of `pi --list-models` because
/// `--model` takes a PATTERN and partial ids fuzzy-match. Freezing kept ids
/// exact but also invisible: pi lists only models whose provider is authed,
/// so when the user logs into a new provider (via pi's own `/login` CLI auth
/// flow — never pasted API keys) the picker stayed stuck on the snapshot.
/// This cache keeps the exactness rule — ids come verbatim from pi's own
/// list — and makes the list live: seeded with the frozen fallback, replaced
/// by one successful bounded probe per process (kicked at real-app startup).
///
/// QA never calls `startRefresh()`, so every check sees the deterministic
/// fallback.
public final class AgentModelCatalog: @unchecked Sendable {
    public static let shared = AgentModelCatalog()

    private let lock = NSLock()
    private var liveOptions: [String]?
    private var liveDisplayNames: [String: String] = [:]
    /// Published context-window sizes from pi's models-store, keyed by
    /// fully-qualified id. Empty when the store is absent — the meter then
    /// shows no percentage rather than a guessed one.
    private var liveContextWindows: [String: Int] = [:]
    /// Models the claude CLI backend contributes (curated aliases, applied
    /// only when a live probe saw the CLI installed AND logged in). Kept
    /// separate from `liveOptions` so a pi probe replacing the list cannot
    /// wipe them, and vice versa.
    private var claudeBackendModels: [String] = []
    private var claudeBackendDisplayNames: [String: String] = [:]
    /// Models the codex CLI backend contributes, kept in their own store for the
    /// same reason as claude's: a pi probe replacing `liveOptions` must not wipe
    /// them, and the two native probes must not clobber each other.
    private var codexBackendModels: [String] = []
    private var codexBackendDisplayNames: [String: String] = [:]
    /// Live refreshing is opt-in and only the real app opts in (startup).
    /// QA never enables it, so presenting pickers in checks can never spawn
    /// a probe or race fixture options.
    private var liveRefreshEnabled = false
    private var lastRefreshStartedAt: Date?
    private var refreshInFlight = false
    // The probe spawns a provider CLI, so both the executor seam and the resolved
    // command it speaks in are macOS-only. Naming `PiAgentRunner.ResolvedCommand`
    // unconditionally broke the iOS build of Core, which the macOS `swift build`
    // cannot see.
    #if os(macOS)
    public typealias ProbeExecutor = @Sendable (PiAgentRunner.ResolvedCommand, [String], TimeInterval) -> String?
    private let probeExecutor: ProbeExecutor?
    #endif
    private var probeLaunchCount = 0

    private var readinessByHarness: [AgentHarness: HarnessReadiness] = [
        .claudeCode: .ready, .codex: .ready, .pi: .ready,
    ]
    private var refreshedAtByHarness: [AgentHarness: Date] = [:]

    #if os(macOS)
    /// Public so checks can exercise instances without touching `shared`. An injected
    /// executor is used only by behavioral tests; production uses bounded Process.
    public init(probeExecutor: ProbeExecutor? = nil) {
        self.probeExecutor = probeExecutor
    }
    #else
    /// iOS has no provider CLI to probe: it serves the curated catalogues only.
    public init() {}
    #endif

    public var probeLaunchCountForQA: Int { lock.withLock { probeLaunchCount } }
    public var refreshInFlightForQA: Bool { lock.withLock { refreshInFlight } }

    public func snapshot(for harness: AgentHarness) -> AgentHarnessCatalogSnapshot {
        lock.withLock {
            switch harness {
            case .claudeCode:
                return AgentHarnessCatalogSnapshot(harness: harness, readiness: readinessByHarness[harness] ?? .checking, models: claudeBackendModels.isEmpty ? ClaudeCLIBackend.curatedCatalogModels : claudeBackendModels, displayNames: claudeBackendDisplayNames.isEmpty ? ClaudeCLIBackend.curatedCatalogDisplayNames : claudeBackendDisplayNames, refreshedAt: refreshedAtByHarness[harness])
            case .codex:
                return AgentHarnessCatalogSnapshot(harness: harness, readiness: readinessByHarness[harness] ?? .checking, models: codexBackendModels.isEmpty ? CodexCLIBackend.curatedCatalogModels : codexBackendModels, displayNames: codexBackendDisplayNames.isEmpty ? CodexCLIBackend.curatedCatalogDisplayNames : codexBackendDisplayNames, refreshedAt: refreshedAtByHarness[harness])
            case .pi:
                return AgentHarnessCatalogSnapshot(harness: harness, readiness: readinessByHarness[harness] ?? .checking, models: liveOptions ?? AgentModelConfig.fallbackModelOptions, displayNames: liveDisplayNames, contextWindows: liveContextWindows, refreshedAt: refreshedAtByHarness[harness])
            }
        }
    }

    public func models(for harness: AgentHarness) -> [String] { snapshot(for: harness).models }
    public func displayName(for id: String, harness: AgentHarness) -> String? { snapshot(for: harness).displayNames[id] }
    public func contextWindow(for id: String, harness: AgentHarness) -> Int? { snapshot(for: harness).contextWindows[id] }

    public func options(fallback: [String] = AgentModelConfig.fallbackModelOptions) -> [String] {
        lock.withLock {
            let base = liveOptions ?? fallback
            // Union, not replace: a machine with pi keeps pi's full catalogue
            // and gains the native aliases; a machine with only claude/codex
            // still gets usable entries on top of the frozen fallback. Each
            // native backend appends only ids not already present.
            var union = base
            union += claudeBackendModels.filter { !union.contains($0) }
            union += codexBackendModels.filter { !union.contains($0) }
            return union
        }
    }

    /// Legacy union presentation only. Strict selection must use snapshot(for:),
    /// which preserves harness provenance for models and metadata.
    /// Human display name for a fully-qualified id ("GPT-5.3 Codex Spark" for
    /// `openai-codex/gpt-5.3-codex-spark`), grabbed from pi's synced catalog
    /// (`~/.pi/agent/models-store.json`). Nil when the store has no entry —
    /// callers fall back to the id, which is also the QA state (no store is
    /// read outside `startRefresh`), so pinned titles never depend on it.
    public func displayName(for id: String) -> String? {
        lock.withLock { liveDisplayNames[id] ?? claudeBackendDisplayNames[id] ?? codexBackendDisplayNames[id] }
    }

    public func displayNamesSnapshot() -> [String: String] {
        lock.withLock {
            // pi's names win over curated ones (they are model-specific); the two
            // curated sets never share an id (anthropic/* vs openai-codex/*).
            claudeBackendDisplayNames
                .merging(codexBackendDisplayNames) { curated, _ in curated }
                .merging(liveDisplayNames) { _, pi in pi }
        }
    }

    /// Parse the `pi --list-models` table: a header row, then columns
    /// `provider  model  context  max-out  thinking  images` aligned with
    /// spaces. Returns fully-qualified `provider/model` ids in pi's own
    /// order. Pure — pinned in the matrix against a real fixture.
    public static func parse(listModelsOutput: String) -> [String] {
        var ids: [String] = []
        for rawLine in listModelsOutput.split(whereSeparator: \.isNewline) {
            // pi styles some terminal output; strip ANSI escapes defensively.
            let line = String(rawLine).replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let provider = String(fields[0])
            let model = String(fields[1])
            if provider == "provider", model == "model" { continue }
            ids.append("\(provider)/\(model)")
        }
        return ids
    }

    /// Parse pi's models-store (`{provider: {models: [{id, name, …}]}}`) into
    /// a fully-qualified-id → display-name map. Pure — pinned in the matrix.
    public static func parse(modelsStoreJSON data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (provider, value) in root {
            guard let entry = value as? [String: Any],
                  let models = entry["models"] as? [[String: Any]] else { continue }
            for model in models {
                guard let id = model["id"] as? String, !id.isEmpty,
                      let name = model["name"] as? String, !name.isEmpty else { continue }
                names["\(provider)/\(id)"] = name
            }
        }
        return names
    }

    /// Parse pi's models-store into a fully-qualified-id → context-window-size
    /// map. This is the provider's own published window (`contextWindow`), not
    /// an assumption of ours — the same file the display names come from, and
    /// the only local source of a real window size. `maxTokens` in that file is
    /// the max OUTPUT per response and is deliberately not read here. Pure.
    public static func parse(modelsStoreContextWindows data: Data) -> [String: Int] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var windows: [String: Int] = [:]
        for (provider, value) in root {
            guard let entry = value as? [String: Any],
                  let models = entry["models"] as? [[String: Any]] else { continue }
            for model in models {
                guard let id = model["id"] as? String, !id.isEmpty,
                      let window = model["contextWindow"] as? Int, window > 0 else { continue }
                windows["\(provider)/\(id)"] = window
            }
        }
        return windows
    }

    /// The model's published context window, or nil when the store has no entry
    /// (pi not installed, or a model it does not list). Callers must degrade to
    /// "no percentage" rather than inventing a size.
    public func contextWindow(for id: String) -> Int? {
        lock.withLock { liveContextWindows[id] }
    }

    public func apply(contextWindows: [String: Int]) {
        lock.withLock { liveContextWindows = contextWindows }
    }

    /// A non-empty parse replaces the current options; an empty or failed
    /// probe changes nothing (the picker must never go blank).
    public func apply(listModelsOutput: String) {
        let parsed = Self.parse(listModelsOutput: listModelsOutput)
        guard !parsed.isEmpty else { return }
        lock.withLock { liveOptions = parsed; readinessByHarness[.pi] = .ready; refreshedAtByHarness[.pi] = Date() }
    }

    public func apply(displayNames: [String: String]) {
        lock.withLock { liveDisplayNames = displayNames }
    }

    /// The claude probe's outcome. Applied only from `startProbe` (real app)
    /// and QA fixtures — `available: false` clears, so a user who uninstalls
    /// claude loses the entries on the next probe.
    public func apply(claudeBackendAvailable available: Bool) {
        lock.withLock {
            claudeBackendModels = available ? ClaudeCLIBackend.curatedCatalogModels : []
            claudeBackendDisplayNames = available ? ClaudeCLIBackend.curatedCatalogDisplayNames : [:]
            readinessByHarness[.claudeCode] = available ? .ready : .loggedOut
            refreshedAtByHarness[.claudeCode] = Date()
        }
    }

    public func apply(readiness: HarnessReadiness, for harness: AgentHarness) {
        lock.withLock {
            readinessByHarness[harness] = readiness
            refreshedAtByHarness[harness] = Date()
        }
    }

    /// The codex probe's outcome, mirroring `apply(claudeBackendAvailable:)`.
    /// `available: false` clears, so uninstalling/logging out of codex drops the
    /// entries on the next probe. Independent of the claude store.
    public func apply(codexBackendAvailable available: Bool) {
        lock.withLock {
            codexBackendModels = available ? CodexCLIBackend.curatedCatalogModels : []
            codexBackendDisplayNames = available ? CodexCLIBackend.curatedCatalogDisplayNames : [:]
            readinessByHarness[.codex] = available ? .ready : .loggedOut
            refreshedAtByHarness[.codex] = Date()
        }
    }

    public func resetForQA(options: [String]? = nil, displayNames: [String: String] = [:]) {
        lock.withLock {
            liveOptions = options
            liveDisplayNames = displayNames
            claudeBackendModels = []
            claudeBackendDisplayNames = [:]
            codexBackendModels = []
            codexBackendDisplayNames = [:]
            liveRefreshEnabled = false
            lastRefreshStartedAt = nil
            refreshInFlight = false
            readinessByHarness = [.claudeCode: .checking, .codex: .checking, .pi: options == nil ? .checking : .ready]
            refreshedAtByHarness = [:]
        }
    }

    public func resetForQA(snapshot: AgentHarnessCatalogSnapshot) {
        lock.withLock {
            readinessByHarness[snapshot.harness] = snapshot.readiness
            if let refreshedAt = snapshot.refreshedAt { refreshedAtByHarness[snapshot.harness] = refreshedAt }
            switch snapshot.harness {
            case .claudeCode:
                claudeBackendModels = snapshot.models; claudeBackendDisplayNames = snapshot.displayNames
            case .codex:
                codexBackendModels = snapshot.models; codexBackendDisplayNames = snapshot.displayNames
            case .pi:
                liveOptions = snapshot.models; liveDisplayNames = snapshot.displayNames; liveContextWindows = snapshot.contextWindows
            }
        }
    }

    /// Pure throttle decision, pinned in the matrix: a refresh is due when
    /// none ran yet or the last one started at least `minimumInterval` ago.
    public static func refreshDue(lastStartedAt: Date?, minimumInterval: TimeInterval, now: Date) -> Bool {
        guard let lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= minimumInterval
    }

    /// Opt in to live probing and kick the first one. Called exactly once,
    /// from the real app's startup path — never from QA.
    public func enableLiveRefresh() {
        lock.withLock {
            liveRefreshEnabled = true
            readinessByHarness[.claudeCode] = .checking
            readinessByHarness[.codex] = .checking
            readinessByHarness[.pi] = .checking
        }
        requestRefresh(minimumInterval: 0)
    }

    /// Throttled re-probe for interaction points (picker open, onboarding
    /// re-check): a colleague who logs into a provider while the app runs
    /// gets the wider catalogue without relaunching. No-op unless the real
    /// app enabled live refreshing, and never overlaps an in-flight probe.
    @discardableResult
    public func requestRefresh(minimumInterval: TimeInterval = 15, now: Date = Date()) -> Bool {
        let shouldStart: Bool = lock.withLock {
            guard liveRefreshEnabled, !refreshInFlight,
                  Self.refreshDue(lastStartedAt: lastRefreshStartedAt, minimumInterval: minimumInterval, now: now) else {
                return false
            }
            lastRefreshStartedAt = now
            refreshInFlight = true
            return true
        }
        guard shouldStart else { return false }
        startProbe()
        return true
    }

    /// Bounded live probe: resolve pi the same way the runner does, run
    /// `--list-models`, apply on success, then read display names from pi's
    /// synced catalog. Silent on every failure — no pi, no auth, timeout —
    /// because the fallback still stands.
    private func finishRefresh() {
        lock.withLock { refreshInFlight = false }
    }

    // Probing spawns provider CLIs, which needs `Process` — macOS-only, like
    // the runners it borrows resolution from. iOS never opts into live refresh
    // (`enableLiveRefresh()` is called only from the macOS app's startup), so
    // `requestRefresh` short-circuits there and this is never reached; the stub
    // exists only so the symbol resolves. The pure parse/options/displayName
    // surface above stays cross-platform for the shared Core and the matrix.
    #if os(macOS)
    private func startProbe(timeout: TimeInterval = 5.0) {
        // CONCURRENTLY, and the ordering was costing real seconds. These three
        // probes are independent by design (each applies only its own harness's
        // readiness, and every mutation goes through `lock`), but they used to run
        // one after another on a single queue with a `timeout` cap EACH. On a
        // machine where a CLI is missing or slow to answer, worst-case readiness
        // took 3x the cap — and while readiness is `.checking`, `sendRefusal`
        // rejects prompts outright. So the serial ordering did not merely delay the
        // catalogue: it widened the window in which a user's message was dropped
        // with "still starting up".
        let group = DispatchGroup()
        let probes: [(AgentModelCatalog, TimeInterval) -> Void] = [
            { $0.probePi(timeout: $1) },
            { $0.probeClaudeBackend(timeout: $1) },
            { $0.probeCodexBackend(timeout: $1) },
        ]
        for probe in probes {
            DispatchQueue.global(qos: .utility).async(group: group) { [weak self] in
                guard let self else { return }
                probe(self, timeout)
            }
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            self?.finishRefresh()
        }
    }

    private func probePi(timeout: TimeInterval) {
        let command = PiAgentRunner.liveResolvedCommand()
        guard command.prefixArgs.isEmpty || probeExecutor != nil else {
            apply(readiness: .missing, for: .pi)
            return
        }
        guard let output = boundedProbeOutput(
            command: command, arguments: ["--list-models"], timeout: timeout) else {
            apply(readiness: .loggedOut, for: .pi)
            return
        }
        guard !Self.parse(listModelsOutput: output).isEmpty else {
            apply(readiness: .unavailable("model catalogue is empty"), for: .pi)
            return
        }
        apply(listModelsOutput: output)
        // Best-effort display names from pi's synced catalog; usable-model
        // membership stays owned by --list-models above (the store also
        // holds models whose provider isn't authed).
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/models-store.json")
        if let storeData = try? Data(contentsOf: storeURL) {
            apply(displayNames: Self.parse(modelsStoreJSON: storeData))
            apply(contextWindows: Self.parse(modelsStoreContextWindows: storeData))
        }
    }

    /// The claude CLI backend's catalogue contribution: entries appear when
    /// the CLI is INSTALLED (an absolute path resolved — the env fallback
    /// proves nothing) and LOGGED IN (`claude auth status --json`). Runs
    /// independently of the pi probe so a pi-less machine still gets its
    /// anthropic models.
    private func probeClaudeBackend(timeout: TimeInterval) {
        let command = ClaudeAgentRunner.liveResolvedCommand()
        guard command.prefixArgs.isEmpty || probeExecutor != nil else {
            apply(claudeBackendAvailable: false)
            apply(readiness: .missing, for: .claudeCode)
            return
        }
        let output = boundedProbeOutput(
            command: command, arguments: ["auth", "status", "--json"], timeout: timeout)
        let loggedIn = output.map { ClaudeCLIBackend.isLoggedIn(authStatusJSON: Data($0.utf8)) } ?? false
        apply(claudeBackendAvailable: loggedIn)
    }

    /// The codex CLI backend's catalogue contribution: entries appear when the
    /// CLI is INSTALLED (an absolute path resolved) and LOGGED IN (`codex login
    /// status` → exit 0 + "Logged in"). codex prints the sign-in line to STDERR
    /// with an EMPTY stdout (verified live 2026-08-26; the shape was captured
    /// live before too, but in a terminal, where the two streams interleave —
    /// the probe itself only ever saw stdout, so a signed-in codex could never
    /// read as logged in). The probe therefore feeds the COMBINED stdout+stderr
    /// text into the `isLoggedIn` check; a non-nil output still implies exit 0.
    /// Independent of pi.
    private func probeCodexBackend(timeout: TimeInterval) {
        let command = CodexAgentRunner.liveResolvedCommand()
        guard command.prefixArgs.isEmpty || probeExecutor != nil else {
            apply(codexBackendAvailable: false)
            apply(readiness: .missing, for: .codex)
            return
        }
        probeCodexBackend(command: command, timeout: timeout)
    }

    /// The production probe body, split from the installed-CLI guard so checks
    /// can drive the REAL `boundedProbeOutput` pipe handling with a fixture
    /// executable reproducing codex's stderr-only "Logged in" stream — an
    /// injected `probeExecutor` bypasses the pipes this exists to pin.
    public func probeCodexBackend(command: PiAgentRunner.ResolvedCommand, timeout: TimeInterval) {
        let output = boundedProbeOutput(
            command: command, arguments: ["login", "status"], includeStderr: true,
            timeout: timeout)
        let loggedIn = output.map { CodexCLIBackend.isLoggedIn(statusOutput: $0, exitCode: 0) } ?? false
        apply(codexBackendAvailable: loggedIn)
    }

    /// One bounded subprocess: output on success, nil on launch failure,
    /// nonzero exit, or timeout. Silent on every failure — the fallback (or
    /// the previous probe's result) still stands. `includeStderr` appends the
    /// stderr text to the returned output — codex reports login state there —
    /// and stays false for pi/claude, whose parsers (a table, JSON) must not
    /// see stderr noise like update nags. Both pipes are drained concurrently
    /// either way, so a chatty stream can never wedge the child against a full
    /// pipe buffer; the timeout terminator bounds both reads via EOF.
    private func boundedProbeOutput(

        command: PiAgentRunner.ResolvedCommand,
        arguments: [String],
        includeStderr: Bool = false,
        timeout: TimeInterval
    ) -> String? {
        let injected = lock.withLock { () -> ProbeExecutor? in
            probeLaunchCount += 1
            return probeExecutor
        }
        if let injected { return injected(command, arguments, timeout) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.prefixArgs + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain stderr off-thread while stdout reads here: two blocking reads on
        // one thread (or an unread stderr pipe filling its buffer) can deadlock
        // the child. The semaphore also publishes the box's bytes to this thread.
        final class StderrBox: @unchecked Sendable { var data = Data() }
        let stderrBox = StderrBox()
        let stderrDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            stderrDrained.signal()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let stdoutText = String(data: data, encoding: .utf8)
        guard includeStderr else { return stdoutText }
        return (stdoutText ?? "") + (String(data: stderrBox.data, encoding: .utf8) ?? "")
    }
    #else
    private func startProbe(timeout: TimeInterval = 5.0) { finishRefresh() }
    #endif
}
