import Foundation

/// ACCOUNT-scoped provider quota: the rolling windows a subscription or plan
/// meters a whole account against, distinct in every way from the per-agent
/// context occupancy in `AgentContextOccupancy`.
///
/// The distinction is the whole point of this file, so state it once:
///
/// - **Occupancy** answers "how full is THIS conversation's context window".
///   It is per-agent, resets at compaction, and its denominator is the model's
///   published context window.
/// - **Quota** answers "how much of MY ACCOUNT's 5-hour (or 7-day) allowance is
///   spent". It is shared by every agent signed into the same harness — in this
///   project and in every other one — resets on a wall-clock schedule the
///   provider owns, and has no relationship to any single conversation.
///
/// Rendering one where the other belongs is the failure this type exists to
/// prevent: a per-agent number that silently means "your whole account" is
/// worse than no number, because it looks actionable per tile.
///
/// UNITS ARE THE TRAP. Three shapes carry this one concept, and two of them are
/// percentages while the model below is a FRACTION:
///
/// - claude's `rate_limit_event.rate_limit_info.unifiedWindows.<window>.utilization`
///   is already a fraction (`0.18`).
/// - claude's documented status-line `rate_limits.<window>.used_percentage` is
///   0-100 (`23.5`).
/// - codex app-server's `account/rateLimits/updated` `primary.usedPercent` is
///   0-100 (`3`).
///
/// Everything is normalized to a fraction at the parse boundary here, exactly
/// as `AgentContextWindowSnapshot.occupancyFraction` does for occupancy, so no
/// presenter ever has to know which provider it is looking at.
///
/// UNKNOWN IS NOT ZERO. Anthropic's own status-line documentation states that a
/// window "may be independently absent, and Claude Code drops a window once its
/// `resets_at` time passes" — so an absent window means expired, or a plan with
/// no such limit, and NEVER 0% used. `utilization` is optional for that reason
/// and callers must not coerce it.
public enum AgentQuotaWindowKind: Equatable, Hashable, Sendable, Codable {
    /// The rolling five-hour window. `five_hour` on both claude shapes.
    case fiveHour
    /// The weekly window. `seven_day` on claude; codex reports it as a
    /// `windowDurationMins` of 10080 rather than by name.
    case sevenDay
    /// A gateway-imposed spend limit. Its utilization may exceed 1.0 — the
    /// documentation is explicit that it runs "from 0 to 100, or above 100 once
    /// you exceed the limit" — so it must never be clamped.
    case spendLimit
    /// A window some newer provider build knows and this one does not,
    /// preserved verbatim rather than dropped. Same leniency, and the same
    /// reason, as `AgentContextWindowTelemetrySource.unknown`.
    case unknown(String)

    private var encodedValue: String {
        switch self {
        case .fiveHour: return "fiveHour"
        case .sevenDay: return "sevenDay"
        case .spendLimit: return "spendLimit"
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "fiveHour": self = .fiveHour
        case "sevenDay": self = .sevenDay
        case "spendLimit": self = .spendLimit
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    /// Provider wire names, normalized. Codex names its windows by duration
    /// instead, so it does not come through here.
    public init(providerName: String) {
        switch providerName {
        case "five_hour", "fiveHour": self = .fiveHour
        case "seven_day", "sevenDay", "weekly": self = .sevenDay
        case "spend_limit", "spendLimit": self = .spendLimit
        default: self = .unknown(providerName)
        }
    }

    /// A duration in minutes, which is how codex app-server names its windows.
    /// 300 minutes is five hours; 10080 is seven days. Anything else is kept as
    /// an explicit unknown rather than rounded into the nearest familiar name.
    public init(windowDurationMinutes: Int) {
        switch windowDurationMinutes {
        case 300: self = .fiveHour
        case 10080: self = .sevenDay
        default: self = .unknown("window-\(windowDurationMinutes)m")
        }
    }

    public var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        // NOT "spend". A spend limit is reported as a PERCENTAGE of a cap, and
        // labelling it "spend" next to the session-cost pill put two
        // money-looking readings in one row — one an amount, one a fraction.
        // "cap" says which of the two this is.
        case .spendLimit: return "cap"
        case .unknown(let raw): return raw
        }
    }

    public var spokenLabel: String {
        switch self {
        case .fiveHour: return "5-hour usage"
        case .sevenDay: return "7-day usage"
        case .spendLimit: return "spend limit"
        case .unknown(let raw): return "\(raw) usage"
        }
    }

    /// Only a spend limit is documented as able to exceed its own ceiling.
    public var allowsOverage: Bool {
        if case .spendLimit = self { return true }
        return false
    }
}

/// One account window's reading. `utilization` nil means the provider did not
/// state one — never zero.
public struct AgentQuotaWindow: Equatable, Sendable, Codable {
    public var kind: AgentQuotaWindowKind
    /// Normalized 0...1 fraction (a spend limit may exceed 1.0). Nil when
    /// unknown.
    public var utilization: Double?
    /// Wall-clock instant the provider says this window resets. Nil when
    /// unstated.
    public var resetsAt: Date?

    public init(kind: AgentQuotaWindowKind, utilization: Double? = nil, resetsAt: Date? = nil) {
        self.kind = kind
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// A window whose stated reset instant has already passed. The provider
    /// drops such a window rather than restating it at 0, so a reading that
    /// outlives its own reset is EXPIRED — distinct from never-observed, and
    /// distinct from a real zero.
    public func isExpired(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public var percentText: String? {
        guard let utilization else { return nil }
        return "\(Int((utilization * 100).rounded()))%"
    }
}

/// Codex-only plan credit facts. `balance` arrives as a STRING on the wire
/// (`"balance": "0"`), so it is kept as one: a value the provider chose not to
/// type as a number is not one to parse into a Double and quietly round.
public struct AgentQuotaCredits: Equatable, Sendable, Codable {
    public var balance: String?
    public var hasCredits: Bool?
    public var unlimited: Bool?
    public var planLabel: String?

    public init(
        balance: String? = nil,
        hasCredits: Bool? = nil,
        unlimited: Bool? = nil,
        planLabel: String? = nil
    ) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.planLabel = planLabel
    }

    public var isEmpty: Bool {
        balance == nil && hasCredits == nil && unlimited == nil && planLabel == nil
    }
}

public enum AgentQuotaTelemetrySource: Equatable, Sendable, Codable {
    /// claude stream-json `rate_limit_event`. NOT part of the documented
    /// message-type union (the documented types are `system`, `assistant`,
    /// `user`, `stream_event` and `result`), so every field is treated as
    /// optional and an unrecognised window name is preserved rather than
    /// dropped. The SEMANTICS are documented — the status-line reference
    /// specifies the same `five_hour`/`seven_day`/`spend_limit` windows with
    /// `used_percentage` and `resets_at`.
    case claudeRateLimitEvent
    /// codex app-server `account/rateLimits/updated`, whose shape is declared
    /// by codex's own `app-server generate-json-schema` output.
    case codexAccountRateLimits
    /// claude's `get_usage` control request, asked on demand with no model
    /// turn. Marked experimental by the CLI, so every field stays optional.
    case claudeUsageRequest
    /// codex app-server `account/rateLimits/read`, the on-demand twin of
    /// `account/rateLimits/updated`, with the same `rateLimits` body.
    case codexRateLimitsRead
    case unknown(String)

    private var encodedValue: String {
        switch self {
        case .claudeRateLimitEvent: return "claudeRateLimitEvent"
        case .codexAccountRateLimits: return "codexAccountRateLimits"
        case .claudeUsageRequest: return "claudeUsageRequest"
        case .codexRateLimitsRead: return "codexRateLimitsRead"
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "claudeRateLimitEvent": self = .claudeRateLimitEvent
        case "codexAccountRateLimits": self = .codexAccountRateLimits
        case "claudeUsageRequest": self = .claudeUsageRequest
        case "codexRateLimitsRead": self = .codexRateLimitsRead
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    public var displayLabel: String {
        switch self {
        case .claudeRateLimitEvent: return "Claude account rate limits"
        case .codexAccountRateLimits: return "Codex account rate limits"
        case .claudeUsageRequest: return "Claude usage, read on demand"
        case .codexRateLimitsRead: return "Codex rate limits, read on demand"
        case .unknown(let raw): return "unknown (\(raw))"
        }
    }
}

/// One account's quota reading. Keyed by harness by every consumer: this is not
/// per-agent state and must never be persisted onto an `AgentRecord`, which
/// would mint one racing copy per agent and resurrect a stale one per relaunch.
public struct AgentAccountQuotaSnapshot: Equatable, Sendable, Codable {
    public var harness: AgentHarness
    public var windows: [AgentQuotaWindow]
    public var credits: AgentQuotaCredits?
    public var observedAt: Date
    public var source: AgentQuotaTelemetrySource

    public init(
        harness: AgentHarness,
        windows: [AgentQuotaWindow],
        credits: AgentQuotaCredits? = nil,
        observedAt: Date,
        source: AgentQuotaTelemetrySource
    ) {
        self.harness = harness
        self.windows = windows
        self.credits = credits
        self.observedAt = observedAt
        self.source = source
    }

    public func window(_ kind: AgentQuotaWindowKind) -> AgentQuotaWindow? {
        windows.first { $0.kind == kind }
    }

    /// Nothing worth showing: no window carries a reading and there are no
    /// credit facts either. Emitting this would replace a real prior reading
    /// with a blank one, so producers drop it instead.
    public var isVacant: Bool {
        windows.allSatisfy { $0.utilization == nil && $0.resetsAt == nil }
            && (credits?.isEmpty ?? true)
    }
}

/// Pure parsers, deliberately in Core rather than inside the two translators:
/// they are the part worth pinning in checks, and keeping them here holds each
/// translator's diff to a single `case`.
public enum AgentAccountQuota {
    /// claude's `rate_limit_info` object.
    ///
    /// Two shapes exist in the wild and both are handled. Newer builds carry
    /// `unifiedWindows` — a dictionary of window name to
    /// `{utilization, resetsAt}` — and that is preferred because it states
    /// every window at once. Older builds carry only the flat
    /// `rateLimitType` + `resetsAt` pair, which names ONE window and gives it
    /// no utilization; that still yields a real reset instant, and a nil
    /// utilization, which is exactly the "unknown, not zero" case.
    public static func claudeSnapshot(
        rateLimitInfo: [String: Any],
        observedAt: Date
    ) -> AgentAccountQuotaSnapshot? {
        var windows: [AgentQuotaWindow] = []

        if let unified = rateLimitInfo["unifiedWindows"] as? [String: Any] {
            // Sorted for determinism: a dictionary's iteration order is not
            // stable, and a witness comparing whole snapshots would flake.
            for name in unified.keys.sorted() {
                guard let body = unified[name] as? [String: Any] else { continue }
                windows.append(AgentQuotaWindow(
                    kind: AgentQuotaWindowKind(providerName: name),
                    utilization: fraction(fromFraction: body["utilization"]),
                    resetsAt: epochSeconds(body["resetsAt"])))
            }
        }

        if windows.isEmpty, let type = rateLimitInfo["rateLimitType"] as? String, !type.isEmpty {
            windows.append(AgentQuotaWindow(
                kind: AgentQuotaWindowKind(providerName: type),
                utilization: nil,
                resetsAt: epochSeconds(rateLimitInfo["resetsAt"])))
        }

        let snapshot = AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: windows,
            credits: nil,
            observedAt: observedAt,
            source: .claudeRateLimitEvent)
        return snapshot.windows.isEmpty || snapshot.isVacant ? nil : snapshot
    }

    /// codex app-server's `params.rateLimits` object.
    ///
    /// Codex names its windows by DURATION, not by name: `primary` and
    /// `secondary` each carry a `windowDurationMins`, and the committed fixture's
    /// primary window is 10080 minutes — a weekly window, not the five-hour one
    /// its position might suggest. Mapping by position rather than by duration
    /// would mislabel it.
    public static func codexSnapshot(
        rateLimits: [String: Any],
        observedAt: Date,
        source: AgentQuotaTelemetrySource = .codexAccountRateLimits
    ) -> AgentAccountQuotaSnapshot? {
        var windows: [AgentQuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let body = rateLimits[key] as? [String: Any] else { continue }
            guard let minutes = intValue(body["windowDurationMins"]) else { continue }
            windows.append(AgentQuotaWindow(
                kind: AgentQuotaWindowKind(windowDurationMinutes: minutes),
                utilization: fraction(fromPercent: body["usedPercent"]),
                resetsAt: epochSeconds(body["resetsAt"])))
        }

        var credits: AgentQuotaCredits?
        if let block = rateLimits["credits"] as? [String: Any] {
            let reading = AgentQuotaCredits(
                balance: block["balance"] as? String,
                hasCredits: block["hasCredits"] as? Bool,
                unlimited: block["unlimited"] as? Bool,
                planLabel: rateLimits["planType"] as? String)
            credits = reading.isEmpty ? nil : reading
        } else if let plan = rateLimits["planType"] as? String, !plan.isEmpty {
            credits = AgentQuotaCredits(planLabel: plan)
        }

        let snapshot = AgentAccountQuotaSnapshot(
            harness: .codex,
            windows: windows,
            credits: credits,
            observedAt: observedAt,
            source: source)
        return snapshot.isVacant && snapshot.windows.isEmpty ? nil : snapshot
    }

    /// claude's `get_usage` control response body (`response.response`).
    ///
    /// UNITS AGAIN: here `rate_limits.<window>.utilization` is 0-100 (`11`),
    /// unlike the 0-1 fraction the same word means in `rate_limit_event`, and
    /// `resets_at` is an ISO-8601 string with microseconds rather than epoch
    /// seconds. `extra_usage` is overage credit, not a window: it is not read
    /// as one (its own `utilization` is also a percent, `0.37` meaning 0.37%).
    ///
    /// A signed-out config dir answers `rate_limits_available: false` with no
    /// windows; that is nil, never a row of zeros.
    public static func claudeUsageSnapshot(
        getUsageResponse response: [String: Any],
        observedAt: Date
    ) -> AgentAccountQuotaSnapshot? {
        guard (response["rate_limits_available"] as? Bool) != false,
              let limits = response["rate_limits"] as? [String: Any] else { return nil }
        var windows: [AgentQuotaWindow] = []
        for name in ["five_hour", "seven_day"] {
            guard let body = limits[name] as? [String: Any] else { continue }
            windows.append(AgentQuotaWindow(
                kind: AgentQuotaWindowKind(providerName: name),
                utilization: fraction(fromPercent: body["utilization"]),
                resetsAt: isoDate(body["resets_at"])))
        }
        let plan = response["subscription_type"] as? String
        let snapshot = AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: windows,
            credits: plan.map { AgentQuotaCredits(planLabel: $0) },
            observedAt: observedAt,
            source: .claudeUsageRequest)
        return windows.isEmpty || snapshot.isVacant ? nil : snapshot
    }

    /// codex app-server `account/rateLimits/read` result. Its `rateLimits`
    /// object is the notification's body, so the same parser reads it.
    public static func codexReadSnapshot(
        rateLimitsReadResult result: [String: Any],
        observedAt: Date
    ) -> AgentAccountQuotaSnapshot? {
        guard let body = result["rateLimits"] as? [String: Any] else { return nil }
        return codexSnapshot(rateLimits: body, observedAt: observedAt, source: .codexRateLimitsRead)
    }

    // MARK: - value helpers

    /// A value already expressed as a 0...1 fraction. Rejects negatives; does
    /// NOT cap the upper end, because a spend limit legitimately exceeds 1.0
    /// and capping is how a wrong reading hides.
    private static func fraction(fromFraction raw: Any?) -> Double? {
        guard let value = doubleValue(raw), value >= 0 else { return nil }
        return value
    }

    /// A value expressed as 0...100.
    private static func fraction(fromPercent raw: Any?) -> Double? {
        guard let value = doubleValue(raw), value >= 0 else { return nil }
        return value / 100.0
    }

    private static func epochSeconds(_ raw: Any?) -> Date? {
        guard let value = doubleValue(raw), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// `2026-10-30T03:40:00.131578+00:00`. Foundation's ISO-8601 formatter
    /// reads at most milliseconds, so the fraction is dropped before parsing;
    /// a reset instant does not need sub-second precision.
    private static func isoDate(_ raw: Any?) -> Date? {
        guard var text = raw as? String, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text.removeSubrange(dot..<zone)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? Double { return Int(value) }
        return nil
    }
}
