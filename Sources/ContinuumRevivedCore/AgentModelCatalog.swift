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
    /// Live refreshing is opt-in and only the real app opts in (startup).
    /// QA never enables it, so presenting pickers in checks can never spawn
    /// a probe or race fixture options.
    private var liveRefreshEnabled = false
    private var lastRefreshStartedAt: Date?
    private var refreshInFlight = false

    /// Public so checks can exercise instances without touching `shared`.
    public init() {}

    public func options(fallback: [String] = AgentModelConfig.fallbackModelOptions) -> [String] {
        lock.withLock { liveOptions } ?? fallback
    }

    /// Human display name for a fully-qualified id ("GPT-5.3 Codex Spark" for
    /// `openai-codex/gpt-5.3-codex-spark`), grabbed from pi's synced catalog
    /// (`~/.pi/agent/models-store.json`). Nil when the store has no entry —
    /// callers fall back to the id, which is also the QA state (no store is
    /// read outside `startRefresh`), so pinned titles never depend on it.
    public func displayName(for id: String) -> String? {
        lock.withLock { liveDisplayNames[id] }
    }

    public func displayNamesSnapshot() -> [String: String] {
        lock.withLock { liveDisplayNames }
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

    public func resetForQA(options: [String]? = nil, displayNames: [String: String] = [:]) {
        lock.withLock {
            liveOptions = options
            liveDisplayNames = displayNames
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

    private func startProbe(timeout: TimeInterval = 5.0) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.finishRefresh() }
            let command = PiAgentRunner.liveResolvedCommand()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.prefixArgs + ["--list-models"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = PiAgentRunner.augmentedPath(
                basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
            process.environment = environment
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do { try process.run() } catch { return }
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return }
            self?.apply(listModelsOutput: output)
            // Best-effort display names from pi's synced catalog; usable-model
            // membership stays owned by --list-models above (the store also
            // holds models whose provider isn't authed).
            let storeURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/models-store.json")
            if let storeData = try? Data(contentsOf: storeURL) {
                self?.apply(displayNames: Self.parse(modelsStoreJSON: storeData))
            }
        }
    }
}
