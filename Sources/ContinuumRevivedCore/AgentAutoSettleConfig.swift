import Foundation

/// How long an untouched agent stays in the inbox before it settles itself,
/// from UserDefaults, mirroring `FocusBorderConfig` / `AgentModelConfig`.
///
/// Ticket: docs/38-tickets/90-agent-ux/P4.3-auto-settle-inactivity.md
///
/// Why it exists: a list that never drains stops being read. This supplies the
/// window for rung 5 of `InboxLifecycle.resolve` (P4.2) — the rung that only a
/// `.neutral` override reaches, so the keep-active pin still suppresses it and
/// a blocker still outranks it.
///
/// INACTIVITY MEANS REAL AGENT ACTIVITY. The record adapter supplies `resolve`
/// with the latest prompt/turn stamp, never with metadata `lastActivityAt` or
/// when the human last looked at the row — otherwise a read or rename would
/// keep a dead row alive forever.
///
/// The window is DAYS × 86,400, deliberately calendar-free: `resolve` takes
/// seconds and takes no `Calendar`, so a DST boundary shifts a threshold by an
/// hour rather than making the rule impure. At a 1-day floor that is noise.
///
/// Nullable = off. Stored as the explicit word `"Off"` rather than an empty
/// string, so the `.choice` has a real option to show and "never set" is
/// distinguishable from "deliberately disabled".
public enum AgentAutoSettleConfig {
    public static let afterDaysKey = "continuum.agents.autoSettleAfterDays"

    public static let defaultDays = 3
    /// The packet's range. A stored number outside it is CLAMPED, not rejected:
    /// "300" plainly means "as long as possible", and falling back to 3 days
    /// there would settle rows far sooner than the human asked.
    public static let minimumDays = 1
    public static let maximumDays = 90

    /// The stored word that means "no auto-settle".
    public static let offOption = "Off"

    /// The day counts offered in Settings. A subset of 1...90 rather than all
    /// ninety: the field is one picker, and any other value a human writes into
    /// the key by hand still resolves (clamped).
    public static let dayOptions = [1, 2, 3, 5, 7, 14, 30, 90]

    /// The single source shared by `SettingsSchema` (the `.choice` options) and
    /// the checks. "Off" first, because it is the one non-numeric answer.
    public static let options: [String] = [offOption] + dayOptions.map(String.init)

    public static let defaultOption = String(defaultDays)

    public struct Resolution: Equatable, Sendable {
        /// nil = off. Otherwise within `minimumDays...maximumDays`.
        public let days: Int?

        public init(days: Int?) {
            self.days = days
        }

        /// What `InboxLifecycle.resolve(autoSettleAfter:)` takes — seconds, or
        /// nil for "never auto-settle".
        public var window: TimeInterval? {
            days.map { TimeInterval($0) * 86_400 }
        }
    }

    /// Unset resolves to the default; `"Off"` to nil; a number to itself,
    /// clamped; anything unparseable to the default (a typo must not silently
    /// turn the sweep off — that failure is invisible).
    public static func resolvedFromDefaults(defaults: UserDefaults = .standard) -> Resolution {
        guard let stored = defaults.string(forKey: afterDaysKey) else {
            return Resolution(days: defaultDays)
        }
        if stored == offOption { return Resolution(days: nil) }
        guard let parsed = Int(stored.trimmingCharacters(in: .whitespaces)) else {
            return Resolution(days: defaultDays)
        }
        return Resolution(days: min(max(parsed, minimumDays), maximumDays))
    }
}
