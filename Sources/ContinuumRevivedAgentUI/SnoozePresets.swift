import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P4.5-snooze-presets.md
//
// "Not now, but come back" — the difference between deferring and forgetting.
//
// Four presets, deliberately SHORT: agent rhythms are hours (a CI run, a review,
// the next work session), not days.
//
// Everything here is pure — `now` and the `Calendar` are parameters, never
// `Date()` or `Calendar.current` read at the point of use — which is what lets
// the checks pin a DST spring-forward and fall-back day. AgentUI is
// Foundation-only, so this file is safe for iOS to consume as well.
//
// SCOPE, from the packet's "Watch out": a preset is UI COPY PLUS A DATE. The
// shelf (P4.7) and the wake logic (P4.6) are not wired here, and nothing in this
// file writes `snoozedUntil` — `InboxLifecycle.resolve` already knows what to do
// with the date once a caller stores it.

/// One "come back later" option: which preset it is, what it says, and the local
/// wall-clock instant it resolves to.
///
/// The date travels WITH the copy rather than being recomputed by the caller: a
/// menu that renders the title and then resolves the date a second later would
/// resolve it against a different `now`, and "this evening" is exactly the
/// preset where that matters (it is suppressed within an hour of 18:00, so the
/// offered-ness and the date must come from one instant).
public struct SnoozeOption: Equatable, Sendable {
    public let preset: SnoozePreset
    /// The menu item's label. `preset.title`, carried here so a renderer needs
    /// only this value.
    public let title: String
    /// The local wall-clock instant the row should come back.
    public let wakeAt: Date

    public init(preset: SnoozePreset, title: String, wakeAt: Date) {
        self.preset = preset
        self.title = title
        self.wakeAt = wakeAt
    }
}

/// The four snooze presets, in the order they are offered.
///
/// `String`-backed and `CaseIterable` for the same reasons `SettledOverride` is:
/// a persisted or logged choice reads as a word rather than an ordinal that
/// reordering the cases would silently repoint, and `allCases` is the order the
/// menu draws.
public enum SnoozePreset: String, CaseIterable, Sendable {
    /// One hour of real elapsed time from now.
    case inOneHour
    /// 18:00 local today — suppressed when it is less than an hour away.
    case thisEvening
    /// 09:00 local the next calendar day.
    case tomorrow
    /// 09:00 local on the Monday that FOLLOWS today.
    case nextWeek

    /// The hour "this evening" means, local.
    public static let eveningHour = 18
    /// The hour the two morning presets mean, local.
    public static let morningHour = 9
    /// How close to 18:00 is too close to bother offering "this evening" — under
    /// an hour and the option is a worse "in 1 hour", so it is hidden rather than
    /// offered as a near-duplicate.
    public static let eveningSuppressionWindow: TimeInterval = 3_600

    public var title: String {
        switch self {
        case .inOneHour: return "In 1 hour"
        case .thisEvening: return "This evening"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    /// The instant this preset resolves to.
    ///
    /// COMPUTED WITH `Calendar`, NEVER BY ADDING SECONDS. `now + 86_400` is the
    /// DST bug: across a spring-forward day it lands an hour late and across a
    /// fall-back day an hour early, so "Tomorrow" stops meaning 09:00. Calendar
    /// day arithmetic preserves the wall clock, and `date(bySettingHour:...)`
    /// then pins the hour on the resulting day.
    ///
    /// `.inOneHour` is the one preset that is about ELAPSED time rather than a
    /// wall-clock target — "come back in an hour" means an hour, even if the
    /// clocks move in between — so it adds an `.hour` component.
    public func wakeDate(from now: Date, calendar: Calendar) -> Date {
        switch self {
        case .inOneHour:
            return calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        case .thisEvening:
            return Self.time(hour: Self.eveningHour, onDayOf: now, calendar: calendar)
        case .tomorrow:
            return Self.time(hour: Self.morningHour, onDayOf: Self.dayAfter(now, calendar: calendar), calendar: calendar)
        case .nextWeek:
            return Self.time(hour: Self.morningHour, onDayOf: Self.followingMonday(after: now, calendar: calendar), calendar: calendar)
        }
    }

    /// Whether this preset is worth showing at `now`.
    ///
    /// Only "this evening" ever hides, and only because it collapses into "in 1
    /// hour" as 18:00 approaches. It is `<` and not `<=` against the window so a
    /// preset exactly an hour out is still offered.
    public func isOffered(at now: Date, calendar: Calendar) -> Bool {
        guard self == .thisEvening else { return true }
        let evening = wakeDate(from: now, calendar: calendar)
        return evening.timeIntervalSince(now) >= Self.eveningSuppressionWindow
    }

    /// The presets a menu should draw at `now`, in declaration order, each already
    /// carrying its copy and its date.
    public static func offered(at now: Date, calendar: Calendar) -> [SnoozeOption] {
        allCases
            .filter { $0.isOffered(at: now, calendar: calendar) }
            .map { SnoozeOption(preset: $0, title: $0.title, wakeAt: $0.wakeDate(from: now, calendar: calendar)) }
    }

    // MARK: - Calendar arithmetic

    /// `hour:00:00` local on the day containing `date`.
    ///
    /// Searching forward from the start of that day is what makes this safe on a
    /// spring-forward day: if the named hour does not exist locally (a 02:00 that
    /// was skipped), `matchingPolicy: .nextTime` answers the next instant that
    /// does rather than returning nil. 09:00 and 18:00 always exist, but the rule
    /// should not depend on which hours a future settings screen picks.
    private static func time(hour: Int, onDayOf date: Date, calendar: Calendar) -> Date {
        calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: date,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? calendar.startOfDay(for: date)
    }

    /// The start of the next calendar day. Day arithmetic, so a 23-hour or
    /// 25-hour local day still advances exactly one day.
    private static func dayAfter(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }

    /// The start of the first Monday STRICTLY AFTER today.
    ///
    /// The walk starts at tomorrow, which is the whole reason "next week" from a
    /// Monday lands seven days out instead of resolving to this morning: today is
    /// never a candidate. From a Sunday the very next day qualifies.
    ///
    /// Gregorian `weekday` is 1 = Sunday … 7 = Saturday and does NOT depend on the
    /// calendar's `firstWeekday`, so Monday is 2 regardless of locale.
    private static func followingMonday(after date: Date, calendar: Calendar) -> Date {
        let monday = 2
        var day = dayAfter(date, calendar: calendar)
        var guardCount = 0
        while calendar.component(.weekday, from: day) != monday, guardCount < 7 {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            guardCount += 1
        }
        return day
    }
}
