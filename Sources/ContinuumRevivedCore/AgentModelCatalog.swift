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
/// list — and makes the list live: replaced by one successful bounded probe
/// per process (kicked at real-app startup). The same holds for the claude and
/// codex harnesses, each catalogued by its own CLI.
///
/// QA never calls `enableLiveRefresh()`, so every check sees the deterministic
/// `AgentCatalogQAFixture`, and the real app never does.
public final class AgentModelCatalog: @unchecked Sendable {
    public static let didRefreshNotification = Notification.Name("ArrayAgentModelCatalogDidRefresh")
    public static let shared = AgentModelCatalog()

    private let lock = NSLock()
    private var liveOptions: [String]?
    private var liveDisplayNames: [String: String] = [:]
    /// Published context-window sizes from pi's models-store, keyed by
    /// fully-qualified id. Empty when the store is absent — the meter then
    /// shows no percentage rather than a guessed one.
    private var liveContextWindows: [String: Int] = [:]
    /// Models the claude CLI reports for itself (its `initialize` handshake),
    /// applied only when a live probe saw the CLI installed AND logged in. Kept
    /// separate from `liveOptions` so a pi probe replacing the list cannot
    /// wipe them, and vice versa.
    private var claudeBackendModels: [String] = []
    private var claudeBackendDisplayNames: [String: String] = [:]
    private var claudeBackendDefault: String?
    /// Models the codex CLI backend contributes, kept in their own store for the
    /// same reason as claude's: a pi probe replacing `liveOptions` must not wipe
    /// them, and the two native probes must not clobber each other.
    private var codexBackendModels: [String] = []
    private var codexBackendDisplayNames: [String: String] = [:]
    private var codexBackendContextWindows: [String: Int] = [:]
    private var codexBackendDefault: String?
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
    /// iOS has no provider CLI to probe and never enables live refresh.
    public init() {}
    #endif

    public var probeLaunchCountForQA: Int { lock.withLock { probeLaunchCount } }
    public var refreshInFlightForQA: Bool { lock.withLock { refreshInFlight } }

    public func snapshot(for harness: AgentHarness) -> AgentHarnessCatalogSnapshot {
        lock.withLock {
            // Only the CLI's own answer, in the real app. `AgentCatalogQAFixture`
            // stands in for a CLI that has not answered ONLY while live refresh
            // is off, which is checks and previews; a live app whose probe found
            // nothing serves nothing rather than a list Array wrote down.
            let qa = !liveRefreshEnabled
            let readiness = readinessByHarness[harness] ?? .checking
            let refreshedAt = refreshedAtByHarness[harness]
            switch harness {
            case .claudeCode:
                if claudeBackendModels.isEmpty, qa {
                    let fixture = AgentCatalogQAFixture.claude
                    return AgentHarnessCatalogSnapshot(harness: harness, readiness: readiness, models: fixture.models, displayNames: fixture.displayNames, refreshedAt: refreshedAt, defaultModel: fixture.defaultModel)
                }
                return AgentHarnessCatalogSnapshot(harness: harness, readiness: readiness, models: claudeBackendModels, displayNames: claudeBackendDisplayNames, refreshedAt: refreshedAt, defaultModel: claudeBackendDefault)
            case .codex:
                if codexBackendModels.isEmpty, qa {
                    let fixture = AgentCatalogQAFixture.codex
                    return AgentHarnessCatalogSnapshot(harness: harness, readiness: readiness, models: fixture.models, displayNames: fixture.displayNames, refreshedAt: refreshedAt, defaultModel: fixture.defaultModel)
                }
                return AgentHarnessCatalogSnapshot(harness: harness, readiness: readiness, models: codexBackendModels, displayNames: codexBackendDisplayNames, contextWindows: codexBackendContextWindows, refreshedAt: refreshedAt, defaultModel: codexBackendDefault)
            case .pi:
                return AgentHarnessCatalogSnapshot(harness: harness, readiness: readiness, models: liveOptions ?? (qa ? AgentCatalogQAFixture.pi : []), displayNames: liveDisplayNames, contextWindows: liveContextWindows, refreshedAt: refreshedAt)
            }
        }
    }

    public func models(for harness: AgentHarness) -> [String] { snapshot(for: harness).models }
    public func displayName(for id: String, harness: AgentHarness) -> String? { snapshot(for: harness).displayNames[id] }
    public func contextWindow(for id: String, harness: AgentHarness) -> Int? { snapshot(for: harness).contextWindows[id] }

    public func options(fallback: [String] = AgentCatalogQAFixture.pi) -> [String] {
        lock.withLock {
            let base = liveOptions ?? (liveRefreshEnabled ? [] : fallback)
            // Union, not replace: a machine with pi keeps pi's full catalogue
            // and gains the native aliases; a machine with only claude/codex
            // still gets usable entries on top of the QA fixture in checks. Each
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
            // pi's names win over the native CLIs' (they are model-specific); the
            // two native sets never share an id (anthropic/* vs openai-codex/*).
            claudeBackendDisplayNames
                .merging(codexBackendDisplayNames) { claude, _ in claude }
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

    /// Parse the catalogue maintained by the Codex CLI. Malformed/newer
    /// shapes fail closed and leave the previous probe's answer in place. Only models
    /// Codex marks visible are offered; hidden service models stay hidden.
    public static func parseCodexModelsCache(_ data: Data) -> AgentHarnessCatalogSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["models"] as? [[String: Any]] else { return nil }
        var models: [String] = []
        var names: [String: String] = [:]
        var windows: [String: Int] = [:]
        for entry in entries {
            guard (entry["visibility"] as? String) != "hide",
                  let slug = entry["slug"] as? String, !slug.isEmpty else { continue }
            let id = "openai-codex/\(slug)"
            guard !models.contains(id) else { continue }
            models.append(id)
            if let name = entry["display_name"] as? String, !name.isEmpty { names[id] = name }
            if let window = entry["context_window"] as? Int, window > 0 { windows[id] = window }
        }
        guard !models.isEmpty else { return nil }
        return AgentHarnessCatalogSnapshot(
            harness: .codex, readiness: .ready, models: models,
            displayNames: names, contextWindows: windows)
    }

    /// Parse one `codex app-server` model/list result. Unlike the disk cache,
    /// this is account-aware and is the production source of membership.
    public static func parseCodexModelListResponse(_ result: [String: Any]) -> AgentHarnessCatalogSnapshot? {
        guard let entries = result["data"] as? [[String: Any]] else { return nil }
        var models: [String] = []
        var names: [String: String] = [:]
        var defaultModel: String?
        for entry in entries {
            guard (entry["hidden"] as? Bool) != true,
                  let slug = (entry["model"] as? String) ?? (entry["id"] as? String),
                  !slug.isEmpty else { continue }
            let id = "openai-codex/\(slug)"
            guard !models.contains(id) else { continue }
            models.append(id)
            if let name = entry["displayName"] as? String, !name.isEmpty { names[id] = name }
            if (entry["isDefault"] as? Bool) == true, defaultModel == nil { defaultModel = id }
        }
        guard !models.isEmpty else { return nil }
        return AgentHarnessCatalogSnapshot(
            harness: .codex, readiness: .ready, models: models, displayNames: names,
            defaultModel: defaultModel)
    }

    // `parseClaudeModelAliases(helpOutput:)` lived here: it scraped the quoted
    // words out of `claude --help`'s `--model` paragraph and offered them as
    // catalogue ids. By construction those are ALIASES ("opus", "sonnet") — the
    // one thing this catalogue must not serve, because an alias renames itself
    // under the user, is not a key in the context-window map, and can never name
    // a previous model. A hand-kept explicit list replaced it and went stale the
    // first time Anthropic shipped. The claude harness now serves the CLI's own
    // `initialize` catalogue, keyed by each entry's resolved id
    // (`ClaudeCLIBackend.parseInitializeModels`).

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
    ///
    /// `PiCatalogPolicy` is applied HERE rather than in `parse` so the parser
    /// stays an honest reading of pi's table, and rather than at the serving
    /// seam so the invariant is a property of the stored value: `liveOptions`
    /// never holds a provider Pi may not offer. The display-name and
    /// context-window maps read from pi's models-store are deliberately NOT
    /// filtered — they are keyed by id and the claude harness resolves its own
    /// `anthropic/*` windows through them.
    public func apply(listModelsOutput: String) {
        let parsed = PiCatalogPolicy.offerable(Self.parse(listModelsOutput: listModelsOutput))
        guard !parsed.isEmpty else { return }
        lock.withLock { liveOptions = parsed; readinessByHarness[.pi] = .ready; refreshedAtByHarness[.pi] = Date() }
    }

    public func apply(displayNames: [String: String]) {
        lock.withLock { liveDisplayNames = displayNames }
    }

    /// The claude login probe's outcome. Applied only from `startProbe` (real
    /// app) and QA fixtures — `available: false` clears, so a user who
    /// uninstalls claude loses the entries on the next probe. The models
    /// themselves arrive through `apply(claudeCatalog:)`.
    public func apply(claudeBackendAvailable available: Bool) {
        lock.withLock {
            if !available {
                claudeBackendModels = []
                claudeBackendDisplayNames = [:]
                claudeBackendDefault = nil
            }
            readinessByHarness[.claudeCode] = available ? .ready : .loggedOut
            refreshedAtByHarness[.claudeCode] = Date()
        }
    }

    /// The claude CLI's own catalogue. An empty one changes nothing, so a
    /// handshake that fails keeps the previous probe's answer.
    public func apply(claudeCatalog snapshot: AgentHarnessCatalogSnapshot) {
        guard snapshot.harness == .claudeCode, !snapshot.models.isEmpty else { return }
        lock.withLock {
            claudeBackendModels = snapshot.models
            claudeBackendDisplayNames = snapshot.displayNames
            claudeBackendDefault = snapshot.defaultModel
            readinessByHarness[.claudeCode] = .ready
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
            if !available {
                codexBackendModels = []
                codexBackendDisplayNames = [:]
                codexBackendContextWindows = [:]
                codexBackendDefault = nil
            }
            readinessByHarness[.codex] = available ? .ready : .loggedOut
            refreshedAtByHarness[.codex] = Date()
        }
    }

    public func apply(codexCatalog snapshot: AgentHarnessCatalogSnapshot) {
        guard snapshot.harness == .codex, !snapshot.models.isEmpty else { return }
        lock.withLock {
            codexBackendModels = snapshot.models
            codexBackendDisplayNames = snapshot.displayNames
            codexBackendContextWindows = snapshot.contextWindows
            codexBackendDefault = snapshot.defaultModel
            readinessByHarness[.codex] = .ready
            refreshedAtByHarness[.codex] = Date()
        }
    }

    public func resetForQA(options: [String]? = nil, displayNames: [String: String] = [:]) {
        lock.withLock {
            liveOptions = options
            liveDisplayNames = displayNames
            claudeBackendModels = []
            claudeBackendDisplayNames = [:]
            claudeBackendDefault = nil
            codexBackendModels = []
            codexBackendDisplayNames = [:]
            codexBackendContextWindows = [:]
            codexBackendDefault = nil
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
                claudeBackendModels = snapshot.models; claudeBackendDisplayNames = snapshot.displayNames; claudeBackendDefault = snapshot.defaultModel
            case .codex:
                codexBackendModels = snapshot.models; codexBackendDisplayNames = snapshot.displayNames; codexBackendContextWindows = snapshot.contextWindows; codexBackendDefault = snapshot.defaultModel
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
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didRefreshNotification, object: self)
        }
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
        // The catalogue BEFORE readiness, so claude never reads as ready with no
        // models while the handshake is out.
        if loggedIn, probeExecutor == nil,
           let catalog = Self.probeClaudeModels(command: command, timeout: timeout) {
            apply(claudeCatalog: catalog)
        }
        apply(claudeBackendAvailable: loggedIn)
    }

    /// Ask claude for its own model list: the `initialize` control handshake
    /// over stream-json, which answers before any prompt and starts no turn
    /// (0.23s against claude 2.1.285). The group is terminated as soon as the
    /// answer arrives, or at `timeout`. Public so a check can drive the real
    /// spawn, pipe and parse against a fixture executable.
    public static func probeClaudeModels(
        command: PiAgentRunner.ResolvedCommand,
        timeout: TimeInterval
    ) -> AgentHarnessCatalogSnapshot? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        guard let child = try? ProcessGroupChild.spawn(
            executable: command.executable,
            arguments: command.prefixArgs + ClaudeCLIBackend.modelProbeArguments,
            environment: environment,
            currentDirectory: nil,
            standardInput: .pipe)
        else { return nil }
        defer { child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive) }
        guard let stdin = child.standardInput else { return nil }
        do {
            try stdin.write(contentsOf: Data((ClaudeCLIBackend.modelProbeRequestLine + "\n").utf8))
        } catch {
            return nil
        }
        // Non-blocking reads of both pipes until the answer or the deadline: a
        // blocking read would outlive `timeout` if claude never answers, and an
        // undrained stderr can wedge the child against a full pipe.
        let descriptors = [child.standardOutput.fileDescriptor, child.standardError.fileDescriptor]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            var stdoutOpen = true
            for (index, descriptor) in descriptors.enumerated() {
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
                    if count > 0 {
                        if index == 0 { pending.append(contentsOf: buffer.prefix(count)) }
                        continue
                    }
                    if count == 0, index == 0 { stdoutOpen = false }
                    break
                }
            }
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if let catalog = ClaudeCLIBackend.parseInitializeModels(controlResponseLine: line) {
                    return catalog
                }
            }
            guard stdoutOpen else { return nil }
            var fds = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            _ = poll(&fds, nfds_t(fds.count), Int32(min(remaining * 1000, 50)))
        }
        return nil
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

    /// Ask Codex itself for the account-aware model catalogue. This uses the
    /// same initialized app-server protocol as managed turns, with one large
    /// page so the startup probe stays bounded to a single request.
    private func probeCodexLiveCatalog(
        command: PiAgentRunner.ResolvedCommand,
        timeout: TimeInterval
    ) -> AgentHarnessCatalogSnapshot? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        guard let child = try? ProcessGroupChild.spawn(
            executable: command.executable,
            arguments: command.prefixArgs + CodexCLIBackend.appServerArguments(extraArgs: []),
            environment: environment,
            currentDirectory: nil,
            standardInput: .pipe)
        else { return nil }
        let transport = CodexAppServerTransport(child: child) { _ in }
        defer {
            transport.shutdown()
            child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        }
        do {
            _ = try transport.sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "array", "title": "Array", "version": "0.0.1"],
                    "capabilities": ["experimentalApi": true],
                ],
                timeout: timeout)
            try transport.sendNotification(method: "initialized", params: [:])
            let result = try transport.sendRequest(
                method: "model/list",
                params: ["includeHidden": false, "limit": 1_000],
                timeout: timeout)
            return Self.parseCodexModelListResponse(result)
        } catch {
            return nil
        }
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
        guard loggedIn, probeExecutor == nil else { return }
        if var live = probeCodexLiveCatalog(command: command, timeout: timeout) {
            // model/list owns membership. The CLI cache contributes context
            // windows when available because model/list does not expose them.
            let cacheURL = codexModelsCacheURL()
            if let data = try? Data(contentsOf: cacheURL),
               let cached = Self.parseCodexModelsCache(data) {
                live = AgentHarnessCatalogSnapshot(
                    harness: .codex, readiness: .ready, models: live.models,
                    displayNames: cached.displayNames.merging(live.displayNames) { _, live in live },
                    contextWindows: cached.contextWindows)
            }
            apply(codexCatalog: live)
            return
        }
        // Older Codex CLIs may lack model/list; their provider-maintained cache
        // is the compatibility fallback.
        let cacheURL = codexModelsCacheURL()
        if let data = try? Data(contentsOf: cacheURL),
           let snapshot = Self.parseCodexModelsCache(data) {
            apply(codexCatalog: snapshot)
        }
    }

    private func codexModelsCacheURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let cacheRoot: URL
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            cacheRoot = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        } else {
            cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return cacheRoot.appendingPathComponent("models_cache.json")
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
