import CoreGraphics
import Foundation

/// Which elements the managed-agent compact status row shows, each toggled
/// independently.
///
/// Two rules the toggles do NOT bend:
///
/// 1. **A toggle is visibility, never collection.** Telemetry keeps flowing for
///    a hidden element, so re-enabling one shows the current value immediately
///    instead of "unknown" until the agent happens to take another turn.
/// 2. **Order is fixed.** The row's overflow policy drops elements in a defined
///    order under width pressure and that order is what the geometry witness
///    pins; a user-reorderable row would make the drop order unprovable.
public enum AgentStatusElement: String, CaseIterable, Equatable, Hashable, Sendable {
    case location
    case activity
    case contextMeter
    case quotaFiveHour
    case quotaSevenDay
    case quotaSpendLimit
    case cost

    /// Whether this element describes THIS agent or the whole signed-in
    /// account. The row prefixes account-scoped elements, because a shared
    /// number rendered like a per-agent one reads as actionable per tile when
    /// it is not.
    public var isAccountScoped: Bool {
        switch self {
        case .quotaFiveHour, .quotaSevenDay, .quotaSpendLimit: return true
        case .location, .activity, .contextMeter, .cost: return false
        }
    }

    public var settingKey: String { "continuum.agent.status.\(rawValue).visible" }

    public var title: String {
        switch self {
        case .location: return "Home and Where"
        case .activity: return "Activity Phase"
        case .contextMeter: return "Context Meter"
        case .quotaFiveHour: return "Account 5-Hour Usage"
        case .quotaSevenDay: return "Account 7-Day Usage"
        case .quotaSpendLimit: return "Account Spend Limit"
        case .cost: return "Session Cost"
        }
    }

    public var settingDescription: String {
        switch self {
        case .location:
            return "Show the agent's project root and current working directory."
        case .activity:
            return "Show the current activity phase and how long it has been running."
        case .contextMeter:
            return "Show how full this agent's context window is, as of its last completed turn."
        case .quotaFiveHour:
            return "Show the provider's rolling 5-hour account allowance. Shared by every agent signed into the same provider, not just this one."
        case .quotaSevenDay:
            return "Show the provider's 7-day account allowance. Shared by every agent signed into the same provider, not just this one."
        case .quotaSpendLimit:
            return "Show a gateway spend limit when the provider reports one. Shared across the account."
        case .cost:
            return "Show the reported cost for this session, labelled with whether it is a metered charge or a list-price estimate."
        }
    }

    /// The default-on set. Location, activity and the context meter are the
    /// shipped row. The 5-hour window joins them because it is the number that
    /// predicts a stall; the 7-day window, spend limit and cost stay off,
    /// because they either rarely change within a session or, in cost's case,
    /// are an estimate that is easy to misread as a bill.
    public var defaultVisible: Bool {
        switch self {
        case .location, .activity, .contextMeter, .quotaFiveHour: return true
        case .quotaSevenDay, .quotaSpendLimit, .cost: return false
        }
    }

    /// Fixed presentation order, left to right.
    public static let presentationOrder: [AgentStatusElement] = [
        .location, .activity, .contextMeter,
        .quotaFiveHour, .quotaSevenDay, .quotaSpendLimit, .cost,
    ]

    /// The order elements are DROPPED in when the row runs out of width — the
    /// reverse of what a reader needs most. Location is last because it is the
    /// row's identity, and it truncates rather than vanishing.
    public static let overflowDropOrder: [AgentStatusElement] = [
        .cost, .quotaSpendLimit, .quotaSevenDay, .quotaFiveHour, .contextMeter, .activity,
    ]
}

public enum AgentStatusElementConfig {
    /// Reads the toggle. `defaults.object(forKey:) != nil` distinguishes an
    /// unset key from an explicit `false`, which is the same unknown-is-not-zero
    /// discipline the rest of this ticket runs on — `bool(forKey:)` alone
    /// reports a never-configured element as hidden.
    public static func isVisible(
        _ element: AgentStatusElement,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(forKey: element.settingKey) != nil else {
            return element.defaultVisible
        }
        return defaults.bool(forKey: element.settingKey)
    }

    public static func visibleElements(defaults: UserDefaults = .standard) -> [AgentStatusElement] {
        AgentStatusElement.presentationOrder.filter { isVisible($0, defaults: defaults) }
    }
}

/// Which elements survive the width available to them.
///
/// Pure, and separate from the view, so the drop order is witnessed by a
/// deterministic check rather than inferred from a screenshot. Elements are
/// removed in `AgentStatusElement.overflowDropOrder` — cost first, location
/// never (it truncates instead, and is the row's identity).
public enum AgentStatusOverflowPolicy {
    /// - Parameters:
    ///   - widths: measured width each element wants, keyed by element.
    ///   - available: the row's content width.
    ///   - spacing: inter-element spacing the row will add between survivors.
    ///   - floor: width reserved for the location element, which always stays.
    /// - Returns: the elements that fit, in presentation order.
    public static func fitting(
        _ requested: [AgentStatusElement],
        widths: [AgentStatusElement: CGFloat],
        available: CGFloat,
        spacing: CGFloat,
        locationFloor: CGFloat
    ) -> [AgentStatusElement] {
        var kept = AgentStatusElement.presentationOrder.filter { requested.contains($0) }
        guard available > 0 else { return kept }

        func total(_ elements: [AgentStatusElement]) -> CGFloat {
            let content = elements.reduce(CGFloat.zero) { sum, element in
                sum + (element == .location ? locationFloor : (widths[element] ?? 0))
            }
            let gaps = CGFloat(max(0, elements.count - 1)) * spacing
            return content + gaps
        }

        for candidate in AgentStatusElement.overflowDropOrder {
            guard total(kept) > available else { break }
            kept.removeAll { $0 == candidate }
        }
        return kept
    }
}
