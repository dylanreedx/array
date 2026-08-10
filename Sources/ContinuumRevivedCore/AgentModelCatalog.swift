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

    /// Public so checks can exercise instances without touching `shared`.
    public init() {}

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

    /// A non-empty parse replaces the current options; an empty or failed
    /// probe changes nothing (the picker must never go blank).
    public func apply(listModelsOutput: String) {
        let parsed = Self.parse(listModelsOutput: listModelsOutput)
        guard !parsed.isEmpty else { return }
        lock.withLock { liveOptions = parsed }
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
        }
    }

    /// The codex probe's outcome, mirroring `apply(claudeBackendAvailable:)`.
    /// `available: false` clears, so uninstalling/logging out of codex drops the
    /// entries on the next probe. Independent of the claude store.
    public func apply(codexBackendAvailable available: Bool) {
        lock.withLock {
            codexBackendModels = available ? CodexCLIBackend.curatedCatalogModels : []
            codexBackendDisplayNames = available ? CodexCLIBackend.curatedCatalogDisplayNames : [:]
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
        lock.withLock { liveRefreshEnabled = true }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.finishRefresh() }
            self?.probePi(timeout: timeout)
            self?.probeClaudeBackend(timeout: timeout)
            self?.probeCodexBackend(timeout: timeout)
        }
    }

    private func probePi(timeout: TimeInterval) {
        let command = PiAgentRunner.liveResolvedCommand()
        guard let output = Self.boundedProbeOutput(
            command: command, arguments: ["--list-models"], timeout: timeout) else { return }
        apply(listModelsOutput: output)
        // Best-effort display names from pi's synced catalog; usable-model
        // membership stays owned by --list-models above (the store also
        // holds models whose provider isn't authed).
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/models-store.json")
        if let storeData = try? Data(contentsOf: storeURL) {
            apply(displayNames: Self.parse(modelsStoreJSON: storeData))
        }
    }

    /// The claude CLI backend's catalogue contribution: entries appear when
    /// the CLI is INSTALLED (an absolute path resolved — the env fallback
    /// proves nothing) and LOGGED IN (`claude auth status --json`). Runs
    /// independently of the pi probe so a pi-less machine still gets its
    /// anthropic models.
    private func probeClaudeBackend(timeout: TimeInterval) {
        let command = ClaudeAgentRunner.liveResolvedCommand()
        guard command.prefixArgs.isEmpty else {
            apply(claudeBackendAvailable: false)
            return
        }
        let output = Self.boundedProbeOutput(
            command: command, arguments: ["auth", "status", "--json"], timeout: timeout)
        let loggedIn = output.map { ClaudeCLIBackend.isLoggedIn(authStatusJSON: Data($0.utf8)) } ?? false
        apply(claudeBackendAvailable: loggedIn)
    }

    /// The codex CLI backend's catalogue contribution: entries appear when the
    /// CLI is INSTALLED (an absolute path resolved) and LOGGED IN (`codex login
    /// status` → exit 0 + "Logged in"). `boundedProbeOutput` returns stdout only
    /// on a clean exit, so a non-nil output already implies exit 0 — the
    /// `isLoggedIn` text check then confirms the sign-in. Independent of pi.
    private func probeCodexBackend(timeout: TimeInterval) {
        let command = CodexAgentRunner.liveResolvedCommand()
        guard command.prefixArgs.isEmpty else {
            apply(codexBackendAvailable: false)
            return
        }
        let output = Self.boundedProbeOutput(
            command: command, arguments: ["login", "status"], timeout: timeout)
        let loggedIn = output.map { CodexCLIBackend.isLoggedIn(statusOutput: $0, exitCode: 0) } ?? false
        apply(codexBackendAvailable: loggedIn)
    }

    /// One bounded subprocess: stdout on success, nil on launch failure,
    /// nonzero exit, or timeout. Silent on every failure — the fallback (or
    /// the previous probe's result) still stands.
    private static func boundedProbeOutput(
        command: PiAgentRunner.ResolvedCommand,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.prefixArgs + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #else
    private func startProbe(timeout: TimeInterval = 5.0) { finishRefresh() }
    #endif
}
