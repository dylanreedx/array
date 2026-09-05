import ContinuumRevivedCore
import Foundation

/// ST-01 — account quota telemetry, replayed from the sanitized fixtures that
/// were already committed to this repo. No credentials, no live provider, no
/// session log: every assertion below is driven by a file in `Fixtures/`.
///
/// The load-bearing distinctions, each of which has its own assertion:
///
/// - a quota reading is ACCOUNT state and produces no `AgentRuntimeEvent`;
/// - three provider shapes carry the concept in TWO different units, and all of
///   them normalize to a fraction here;
/// - an absent utilization is UNKNOWN, never zero;
/// - a window past its own `resets_at` is EXPIRED, which is a third state again;
/// - a spend limit above 100% is not clamped.
func runAgentAccountQuotaChecks() {
    let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    func lines(_ name: String) -> [String] {
        let url = fixturesDir.appendingPathComponent(name, isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("FAIL: account-quota fixture missing at \(url.path)\n", stderr)
            Foundation.exit(1)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    let observedAt = Date(timeIntervalSince1970: 1_787_700_000)

    /// The translators hand observations out on a `@Sendable` closure, so the
    /// collector has to be one too (same shape as `ObservationSink` in the
    /// claude backend checks).
    final class QuotaSink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentAccountQuotaSnapshot] = []
        func append(_ observation: AgentRuntimeObservation) {
            guard case let .accountQuota(snapshot) = observation else { return }
            lock.lock(); values.append(snapshot); lock.unlock()
        }
        var all: [AgentAccountQuotaSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    }

    // MARK: - claude, new shape (unifiedWindows)

    // `Fixtures/claude-delegation-two-agents.jsonl` line 1 carries both windows.
    // Before ST-01 this line fell through `default:` in `ClaudeEventTranslator`
    // and produced nothing at all.
    let claudeSink = QuotaSink()
    var claudeTranslator = ClaudeEventTranslator(runToken: "quota", now: { observedAt })
    claudeTranslator.onRuntimeObservation = { claudeSink.append($0) }
    let claudeEvents = claudeTranslator.translate(stream: lines("claude-delegation-two-agents.jsonl"))
    let claudeQuotas = claudeSink.all

    expect(!claudeQuotas.isEmpty,
           "claude rate_limit_event must publish an account quota reading; got none")

    guard let claudeFirst = claudeQuotas.first else { return }
    expect(claudeFirst.harness == .claudeCode,
           "a claude quota reading must be filed under the claude harness, got \(claudeFirst.harness)")
    expect(claudeFirst.source == .claudeRateLimitEvent,
           "claude quota source mislabeled: \(claudeFirst.source)")

    // 0.18 on the wire is ALREADY a fraction. Multiplying it as if it were a
    // percentage would render 18% as 0%; dividing a percentage shape by 100
    // twice is the mirror error. Both are pinned by asserting the exact value.
    let fiveHour = claudeFirst.window(.fiveHour)
    expect(fiveHour?.utilization == 0.18,
           "claude five_hour utilization must stay a 0...1 fraction, got \(String(describing: fiveHour?.utilization))")
    expect(fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_787_765_400),
           "claude five_hour resetsAt must decode from epoch seconds, got \(String(describing: fiveHour?.resetsAt))")
    expect(claudeFirst.window(.sevenDay)?.utilization == 0.67,
           "claude seven_day utilization must be read, got \(String(describing: claudeFirst.window(.sevenDay)?.utilization))")
    expect(claudeFirst.window(.sevenDay)?.resetsAt == Date(timeIntervalSince1970: 1_787_896_800),
           "claude seven_day resetsAt must decode from epoch seconds")

    // ACCOUNT SCOPE. A quota reading is not thread state: it must not appear on
    // the normalized timeline at all, or it would ride the per-agent event log
    // across the I5 sync boundary and be mislabeled as this agent's usage.
    let quotaShapedEvents = claudeEvents.filter { event in
        if case let .contextWindowUpdated(_, snapshot) = event {
            // A context snapshot is fine; one carrying a quota-looking 18% max
            // would mean the two concepts had been merged.
            return snapshot.maxTokens == 18 || snapshot.usedTokens == 18
        }
        return false
    }
    expect(quotaShapedEvents.isEmpty,
           "an account quota must never become an AgentRuntimeEvent, found \(quotaShapedEvents.count)")

    // MARK: - claude, old shape (no unifiedWindows) — unknown is not zero

    // `claude-websearch-turn.jsonl` line 1 is the same event WITHOUT
    // `unifiedWindows`: it names one window and states a reset, but no
    // utilization. The reading must be a real window with a nil utilization —
    // not a 0% reading, and not a dropped event that loses the reset instant.
    let legacySink = QuotaSink()
    var legacyTranslator = ClaudeEventTranslator(runToken: "quota-legacy", now: { observedAt })
    legacyTranslator.onRuntimeObservation = { legacySink.append($0) }
    _ = legacyTranslator.translate(stream: lines("claude-websearch-turn.jsonl"))
    let legacyQuotas = legacySink.all

    expect(legacyQuotas.count >= 1,
           "a rate_limit_event without unifiedWindows must still publish its named window and reset")
    if let legacy = legacyQuotas.first {
        let window = legacy.window(.fiveHour)
        expect(window != nil,
               "the flat rateLimitType must map to a named window, got \(legacy.windows.map(\.kind))")
        expect(window?.utilization == nil,
               "an unstated utilization is UNKNOWN, never 0 — got \(String(describing: window?.utilization))")
        expect(window?.percentText == nil,
               "an unknown utilization must render no percentage at all")
        expect(window?.resetsAt == Date(timeIntervalSince1970: 1_787_548_200),
               "the flat shape's resetsAt must still be read, got \(String(describing: window?.resetsAt))")
    }

    // MARK: - codex app-server

    // `account/rateLimits/updated` is on the LIVE production path: app-server is
    // the default transport, so this frame arrives every turn and used to fall
    // through `default:`.
    let codexSink = QuotaSink()
    var codexTranslator = CodexAppServerEventTranslator(now: { observedAt })
    codexTranslator.onRuntimeObservation = { codexSink.append($0) }
    _ = codexTranslator.translate(stream: lines("codex-appserver-single-agent.jsonl"))
    let codexQuotas = codexSink.all

    expect(!codexQuotas.isEmpty,
           "codex account/rateLimits/updated must publish an account quota reading; got none")

    if let codex = codexQuotas.first {
        expect(codex.harness == .codex,
               "a codex quota reading must be filed under the codex harness, got \(codex.harness)")
        // WINDOW NAMING BY DURATION. The fixture's `primary` window is 10080
        // minutes — a WEEKLY window, despite being the primary one. Mapping by
        // position would have labeled it as the five-hour window.
        expect(codex.window(.sevenDay) != nil,
               "codex primary window of 10080 minutes is the SEVEN-DAY window, got \(codex.windows.map(\.kind))")
        expect(codex.window(.fiveHour) == nil,
               "codex reported no five-hour window in this fixture; inventing one would be a fabricated reading")
        // usedPercent 3 is a PERCENTAGE and must become the fraction 0.03.
        let weekly = codex.window(.sevenDay)
        expect(weekly?.utilization == 0.03,
               "codex usedPercent must be normalized from 0...100 to a fraction, got \(String(describing: weekly?.utilization))")
        expect(weekly?.resetsAt == Date(timeIntervalSince1970: 1_788_143_756),
               "codex resetsAt must decode from epoch seconds")
        // `balance` is a STRING on the wire and stays one.
        expect(codex.credits?.balance == "0" && codex.credits?.hasCredits == false,
               "codex credits must be carried verbatim, got \(String(describing: codex.credits))")
        expect(codex.credits?.planLabel == "prolite",
               "codex planType must be carried, got \(String(describing: codex.credits?.planLabel))")
    }

    // MARK: - expiry is a third state, distinct from unknown

    let past = AgentQuotaWindow(
        kind: .fiveHour, utilization: 0.4,
        resetsAt: Date(timeIntervalSince1970: 1_787_000_000))
    let future = AgentQuotaWindow(
        kind: .fiveHour, utilization: 0.4,
        resetsAt: Date(timeIntervalSince1970: 1_788_000_000))
    let undated = AgentQuotaWindow(kind: .fiveHour, utilization: 0.4)
    expect(past.isExpired(at: observedAt),
           "a window whose stated reset has passed is EXPIRED")
    expect(!future.isExpired(at: observedAt),
           "a window whose reset is still ahead is live")
    expect(!undated.isExpired(at: observedAt),
           "a window with no stated reset is unknown, not expired — the provider never promised a time")

    // MARK: - a spend limit is not clamped

    // The documentation is explicit that a spend limit's used percentage runs
    // "from 0 to 100, or above 100 once you exceed the limit". Clamping it is
    // how an over-limit account would look merely full, and it is the same
    // mistake the context ring deliberately avoids by keeping raw arithmetic.
    let overLimit = AgentAccountQuota.claudeSnapshot(
        rateLimitInfo: [
            "unifiedWindows": [
                "spend_limit": ["utilization": 1.18, "resetsAt": 1_788_000_000],
            ],
        ],
        observedAt: observedAt)
    expect(overLimit?.window(.spendLimit)?.utilization == 1.18,
           "an over-limit spend reading must survive raw, got \(String(describing: overLimit?.window(.spendLimit)?.utilization))")
    expect(overLimit?.window(.spendLimit)?.percentText == "118%",
           "an over-limit spend reading must render above 100%")
    expect(AgentQuotaWindowKind.spendLimit.allowsOverage,
           "only a spend limit may exceed its ceiling")
    expect(!AgentQuotaWindowKind.fiveHour.allowsOverage,
           "a rolling usage window does not overflow its own ceiling")

    // MARK: - an unknown window name is preserved, not dropped

    let futureShape = AgentAccountQuota.claudeSnapshot(
        rateLimitInfo: [
            "unifiedWindows": ["thirty_day": ["utilization": 0.5, "resetsAt": 1_788_000_000]],
        ],
        observedAt: observedAt)
    expect(futureShape?.windows.first?.kind == .unknown("thirty_day"),
           "a window name a newer build knows must be preserved verbatim, got \(String(describing: futureShape?.windows.first?.kind))")

    // MARK: - nothing worth showing publishes nothing

    // An empty or content-free payload must not replace a good prior reading
    // with a blank one.
    expect(AgentAccountQuota.claudeSnapshot(rateLimitInfo: [:], observedAt: observedAt) == nil,
           "an empty rate_limit_info must publish no reading at all")
    expect(AgentAccountQuota.claudeSnapshot(
            rateLimitInfo: ["status": "allowed"], observedAt: observedAt) == nil,
           "a status-only rate_limit_info names no window and must publish nothing")

    // MARK: - negatives are rejected rather than shown

    let negative = AgentAccountQuota.claudeSnapshot(
        rateLimitInfo: ["unifiedWindows": ["five_hour": ["utilization": -0.2]]],
        observedAt: observedAt)
    expect(negative == nil || negative?.window(.fiveHour)?.utilization == nil,
           "a negative utilization is invalid and must not be rendered")

    // MARK: - cost basis is carried and distinguishable

    // One Double rendered two incompatible meanings identically before this.
    var claudeCost: AgentContextWindowSnapshot?
    for event in claudeEvents {
        if case let .contextWindowUpdated(_, snapshot) = event, snapshot.totalCostUsd != nil {
            claudeCost = snapshot
        }
    }
    if let claudeCost {
        expect(claudeCost.costBasis == .listPriceEstimate,
               "claude's total_cost_usd is a list-price estimate, got \(String(describing: claudeCost.costBasis))")
    }
    expect(AgentCostBasis.listPriceEstimate.disclosureLabel != AgentCostBasis.providerMetered.disclosureLabel,
           "the two cost bases must not render with the same label")

    // MARK: - element toggles are independent, and default sanely

    let suiteName = "array.st01.status-elements.checks"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fputs("FAIL: could not open an isolated defaults suite for status element checks\n", stderr)
        Foundation.exit(1)
    }
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

    expect(AgentStatusElementConfig.isVisible(.contextMeter, defaults: defaults),
           "the context meter ships visible")
    expect(AgentStatusElementConfig.isVisible(.quotaFiveHour, defaults: defaults),
           "the 5-hour account window ships visible")
    expect(!AgentStatusElementConfig.isVisible(.cost, defaults: defaults),
           "cost ships hidden — it is an estimate that reads as a bill")

    // An explicit false must be distinguishable from an unset key: reading with
    // `bool(forKey:)` alone would report every never-configured element hidden.
    defaults.set(false, forKey: AgentStatusElement.quotaFiveHour.settingKey)
    expect(!AgentStatusElementConfig.isVisible(.quotaFiveHour, defaults: defaults),
           "an explicit false must hide the element")
    expect(AgentStatusElementConfig.isVisible(.contextMeter, defaults: defaults),
           "hiding one element must not disturb any other")
    defaults.set(true, forKey: AgentStatusElement.cost.settingKey)
    expect(AgentStatusElementConfig.isVisible(.cost, defaults: defaults),
           "an explicit true must show a default-hidden element")

    let visible = AgentStatusElementConfig.visibleElements(defaults: defaults)
    expect(visible == [.location, .activity, .contextMeter, .cost],
           "visible elements must come back in fixed presentation order, got \(visible)")

    // Every element owns a registered setting AND a field in the schema the
    // settings panel actually renders.
    //
    // The registry half alone is not enough, and shipping it alone is exactly
    // what went wrong: `BuiltInSettingRegistry.all()` feeds
    // `SettingsSchema.registeredDefinitions()`, a metadata/search bridge, while
    // the panel renders `SettingsSchema.sections()`. Asserting only the first
    // left seven toggles that existed, were honoured by the status row, and
    // could not be reached from the UI — with a green check. The panel witness
    // in `--settings-panel-check` drives the real control; this one keeps the
    // two sources from drifting apart again.
    let registeredKeys = Set(BuiltInSettingRegistry.all().map(\.id.rawValue))
    let agentsSection = SettingsSchema.sections().first { $0.id == "agents" }
    expect(agentsSection != nil, "the settings schema must still have an agents section")
    let renderedToggleKeys = Set((agentsSection?.fields ?? []).compactMap { field -> String? in
        guard case .toggle = field else { return nil }
        return field.key
    })
    for element in AgentStatusElement.allCases {
        expect(registeredKeys.contains(element.settingKey),
               "status element \(element.rawValue) has no registered setting")
        expect(renderedToggleKeys.contains(element.settingKey),
               "status element \(element.rawValue) has no toggle in the schema the panel renders — it would be unreachable from the UI")
    }

    // MARK: - overflow drops in the declared order, and location never goes

    // Pure arithmetic, so the DROP ORDER is witnessed here rather than inferred
    // from a screenshot at some particular width.
    let allOn = AgentStatusElement.presentationOrder
    let uniform: [AgentStatusElement: CGFloat] = Dictionary(
        uniqueKeysWithValues: allOn.map { ($0, CGFloat(40)) })

    // Wide enough for everything: nothing is dropped.
    let roomy = AgentStatusOverflowPolicy.fitting(
        allOn, widths: uniform, available: 4_000, spacing: 8, locationFloor: 48)
    expect(roomy == allOn, "a wide row drops nothing, got \(roomy)")

    // Squeeze it one element at a time and assert WHICH one goes, in order.
    // cost → spend → 7d → 5h → context → activity, location last and never.
    var previous = roomy
    var dropSequence: [AgentStatusElement] = []
    for width in stride(from: CGFloat(360), through: CGFloat(40), by: -40) {
        let kept = AgentStatusOverflowPolicy.fitting(
            allOn, widths: uniform, available: width, spacing: 8, locationFloor: 48)
        let gone = Set(previous).subtracting(kept)
        dropSequence.append(contentsOf: AgentStatusElement.overflowDropOrder.filter { gone.contains($0) })
        expect(kept.contains(.location),
               "location must never be dropped — it truncates instead; lost at width \(width)")
        // Survivors keep presentation order, never the drop order.
        expect(kept == AgentStatusElement.presentationOrder.filter({ kept.contains($0) }),
               "survivors must stay in presentation order at width \(width), got \(kept)")
        previous = kept
    }
    let expectedPrefix: [AgentStatusElement] = [
        .cost, .quotaSpendLimit, .quotaSevenDay, .quotaFiveHour, .contextMeter, .activity,
    ]
    expect(dropSequence == expectedPrefix,
           "elements must drop lowest-priority-first, got \(dropSequence)")

    // A disabled element is not a dropped one: only the requested set can be
    // dropped, so turning something off cannot resurrect it under pressure.
    let withoutQuota: [AgentStatusElement] = [.location, .activity, .contextMeter]
    let narrow = AgentStatusOverflowPolicy.fitting(
        withoutQuota, widths: uniform, available: 4_000, spacing: 8, locationFloor: 48)
    expect(!narrow.contains(.quotaFiveHour),
           "a disabled element must never appear, however much room there is")

    // Account-scoped elements must be identifiable as such, or the row cannot
    // label a shared number differently from a per-agent one.
    expect(AgentStatusElement.quotaFiveHour.isAccountScoped
            && AgentStatusElement.quotaSevenDay.isAccountScoped
            && AgentStatusElement.quotaSpendLimit.isAccountScoped,
           "quota elements are account-scoped")
    expect(!AgentStatusElement.contextMeter.isAccountScoped,
           "context occupancy is per-agent, not account state")

    print("AgentAccountQuota checks passed: claude rate_limit_event (unifiedWindows fractions and the flat legacy shape) and codex account/rateLimits/updated (percent normalized, windows named by duration, credits verbatim) publish account readings on the observation channel and NO runtime event; unknown stays unknown, an elapsed window reads expired, a spend limit is not clamped, an unrecognised window name survives; cost carries a metered vs list-price basis; status elements toggle independently with a registered setting each and drop lowest-priority-first with location never dropped")
}
