import ContinuumRevivedCore
import Foundation

/// Presentation for the ACCOUNT-scoped status elements, kept apart from
/// `AgentRadialContextMeterPresenter` on purpose: the two answer different
/// questions and the whole risk of putting them in one row is that they stop
/// looking different.
///
/// Every string this produces that describes an account window says so — the
/// short label carries a scope glyph, and the spoken label literally begins
/// with "Account". A number shared by every agent on the login must not read
/// like this tile's own.

/// Five states, because collapsing any two of them loses a real distinction:
///
/// - `known` — the provider stated a utilization.
/// - `warning` / `critical` — stated, and high enough to act on.
/// - `unknown` — never observed, or observed without a utilization. NOT zero.
/// - `expired` — observed, but the window's own `resets_at` has passed. The
///   provider drops such a window rather than restating it, so the last number
///   is no longer true; showing it would be confidently wrong, and showing
///   "unknown" would hide that we ever had a reading.
enum AgentQuotaElementState: String, Equatable, CaseIterable {
    case known
    case warning
    case critical
    case unknown
    case expired
}

struct AgentQuotaElementPresentation: Equatable {
    let element: AgentStatusElement
    let state: AgentQuotaElementState
    /// Raw fraction USED, uncapped. A spend limit above 1.0 stays above 1.0.
    let fraction: Double?
    /// What is LEFT, 0...1, for the bar. Remaining is what the row shows,
    /// because remaining is what Dylan asked to see; used stays in `fraction`
    /// for the thresholds, which are defined on it.
    var remainingFraction: Double? {
        guard state == .known || state == .warning || state == .critical, let fraction else { return nil }
        return max(0, min(1, 1 - fraction))
    }
    /// This element's OWN glyph. Not a shared account glyph: three chips
    /// carrying one repeated icon was half the reason the row read as a single
    /// string, because a repeated mark implies sameness.
    let symbolName: String
    /// The window's name, alone — `5h`, `7d`, `spend`.
    let shortLabel: String
    /// The reading, alone — `18%`, `! 94%`, or an em dash when there is none.
    let valueText: String
    /// Label and value joined, for surfaces that draw one string.
    var text: String { valueText.isEmpty ? shortLabel : "\(shortLabel) \(valueText)" }
    let accessibilityLabel: String
    let detailText: String
}

/// The account a tile is spending: the row chip, and the hover card that
/// replaced the plain-text tooltip (.plans/101, Option 2).
struct AgentAccountUsagePresentation: Equatable {
    /// `Max`. The plan, because that is the word that tells two logins apart
    /// at a glance; the provider when the plan is unknown.
    let chipText: String
    let chipAccessibilityLabel: String
    let card: AgentAccountUsageCardPresentation
}

struct AgentAccountUsageCardPresentation: Equatable {
    struct Window: Equatable {
        let kind: AgentQuotaWindowKind
        /// `5-hour`, `Weekly`.
        let title: String
        /// `84% left`, or an em dash when the provider stated none.
        let valueText: String
        /// 0...1 left, nil when unknown. Drives the bar.
        let remainingFraction: Double?
        let state: AgentQuotaElementState
        /// `Resets 3:10 PM · in 2h 17m`.
        let resetText: String
    }

    /// `Claude · Max`.
    let title: String
    /// The login's email (or organisation), so two accounts on one plan
    /// still read apart.
    let subtitle: String?
    let statusText: String
    let windows: [Window]
    let footnote: String
}

struct AgentCostElementPresentation: Equatable {
    let text: String
    let accessibilityLabel: String
    let detailText: String
}

enum AgentAccountQuotaPresenter {
    /// Same numbers as the context meter's shipped policy. Quota pressure is
    /// less immediately actionable than context pressure, but the thresholds
    /// mean the same thing to a reader and two different scales in one row
    /// would be its own defect.
    static let warningThreshold = 0.75
    static let criticalThreshold = 0.90

    /// One glyph per window kind, so two pills are never distinguishable only
    /// by their text. Account SCOPE is still stated — in the tooltip and the
    /// spoken label, where there is room to say it unambiguously rather than
    /// hint at it with a repeated mark.
    private static func symbolName(for kind: AgentQuotaWindowKind) -> String {
        switch kind {
        case .fiveHour: return "clock"
        case .sevenDay: return "calendar"
        // A gauge, not a credit card: the reading is how much of a cap is used,
        // and a payment glyph beside the cost pill implied a second price.
        case .spendLimit: return "gauge.with.dots.needle.bottom.50percent"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Nil means DRAW NOTHING.
    ///
    /// An em dash is a promise that a number is coming. For a provider that
    /// reports no quota at all (pi), or a window this plan does not have (a
    /// gateway spend limit on an account with no gateway), no number is ever
    /// coming — and a row of `5h — 7d — spend —` is three promises the app
    /// cannot keep. Absence is the honest rendering there, and the setting's
    /// own description is where the explanation belongs.
    ///
    /// A dash is still correct for the narrow case where the provider NAMED a
    /// window and withheld its value, or where a window we did have a reading
    /// for has passed its reset: those are real "unknown right now" states with
    /// a reading expected, and blanking them would hide that we are waiting.
    static func present(
        _ snapshot: AgentAccountQuotaSnapshot?,
        element: AgentStatusElement,
        now: Date
    ) -> AgentQuotaElementPresentation? {
        guard let kind = windowKind(for: element) else { return nil }
        // Never observed: no pill. This is the state a fresh launch is in before
        // the first reading arrives, and the state pi stays in forever.
        guard let snapshot else { return nil }
        // The provider reported other windows but not this one, so this plan
        // does not have it. Not unknown — absent.
        guard let window = snapshot.window(kind) else { return nil }

        let observed = Self.observedLine(snapshot)
        let resetLine = window.resetsAt.map { "Resets: \(absolute($0)) (\(relative($0, from: now)))" }
            ?? "Resets: unknown"

        if window.isExpired(at: now) {
            return AgentQuotaElementPresentation(
                element: element,
                state: .expired,
                fraction: window.utilization,
                symbolName: symbolName(for: kind),
                shortLabel: kind.shortLabel,
                valueText: "—",
                accessibilityLabel: "Account \(kind.spokenLabel) expired; awaiting a new reading.",
                detailText: [
                    "Account \(kind.spokenLabel): expired",
                    "The stated reset time has passed and the provider has not reported a new window yet. The previous reading is no longer true.",
                    resetLine, observed, scopeNote,
                ].joined(separator: "\n"))
        }

        guard let fraction = window.utilization else {
            return AgentQuotaElementPresentation(
                element: element,
                state: .unknown,
                fraction: nil,
                symbolName: symbolName(for: kind),
                shortLabel: kind.shortLabel,
                valueText: "—",
                accessibilityLabel: "Account \(kind.spokenLabel) unknown.",
                detailText: [
                    "Account \(kind.spokenLabel): unknown",
                    "The provider named this window but stated no usage for it. Unknown is not zero.",
                    resetLine, observed, scopeNote,
                ].joined(separator: "\n"))
        }

        let percent = Int((fraction * 100).rounded())
        let left = Self.percentLeft(used: fraction)
        let state = Self.state(used: fraction)

        var detail = [
            "Account \(kind.spokenLabel): \(left)% left (\(percent)% used)",
        ]
        if kind.allowsOverage, fraction > 1 {
            detail.append("Over the limit — a spend limit is reported past 100% rather than capped.")
        }
        detail.append(contentsOf: [resetLine, observed, scopeNote])
        if let credits = snapshot.credits, let line = creditsLine(credits) {
            detail.append(line)
        }

        return AgentQuotaElementPresentation(
            element: element,
            state: state,
            fraction: fraction,
            symbolName: symbolName(for: kind),
            shortLabel: kind.shortLabel,
            // LEFT, not used: `84%` beside a full bar. The bar and the colour
            // carry the state, so the old `!`/`⚠︎` prefixes are gone.
            valueText: "\(left)%",
            accessibilityLabel: "Account \(kind.spokenLabel) \(left) percent left"
                + (window.resetsAt.map { ", resets \(relative($0, from: now))" } ?? "")
                + ".",
            detailText: detail.joined(separator: "\n"))
    }

    /// Cost, always labelled with its basis. An unlabelled currency figure is
    /// the ambiguity this element exists to remove.
    static func presentCost(_ snapshot: AgentContextWindowSnapshot?) -> AgentCostElementPresentation? {
        guard let snapshot, let amount = snapshot.totalCostUsd else { return nil }
        let amountText = amount < 0.01 && amount > 0
            ? String(format: "$%.4f", amount)
            : String(format: "$%.2f", amount)
        guard let basis = snapshot.costBasis else {
            // A figure with no stated basis is not labelled as either kind.
            return AgentCostElementPresentation(
                text: "\(amountText)?",
                accessibilityLabel: "Session cost \(amountText), basis unknown.",
                detailText: "Session cost: \(amountText)\nCost basis: unknown — this figure's provenance was not recorded.")
        }
        return AgentCostElementPresentation(
            text: "\(amountText) \(basis == .listPriceEstimate ? "est" : "")".trimmingCharacters(in: .whitespaces),
            accessibilityLabel: "Session cost \(amountText), \(basis.disclosureLabel).",
            detailText: "Session cost: \(amountText) (\(basis.disclosureLabel))\n\(basis.detailSentence)")
    }

    /// Whole percent left, never negative: a spend limit past 100% has 0 left.
    static func percentLeft(used: Double) -> Int {
        max(0, Int(((1 - used) * 100).rounded()))
    }

    static func state(used: Double) -> AgentQuotaElementState {
        if used >= criticalThreshold { return .critical }
        if used >= warningThreshold { return .warning }
        return .known
    }

    /// The account the tile is spending, for the row chip and the hover card.
    /// Nil when there is nothing to say: no login was read and no window was
    /// reported, which is pi's permanent state.
    static func presentAccount(
        identity: AgentAccountIdentity?,
        quota: AgentAccountQuotaSnapshot?,
        now: Date
    ) -> AgentAccountUsagePresentation? {
        guard let harness = identity?.harness ?? quota?.harness else { return nil }
        let plan = identity?.planDisplayName
            ?? quota?.credits?.planLabel.flatMap {
                AgentAccountIdentity(harness: harness, plan: $0, observedAt: now).planDisplayName
            }
        let provider = providerName(harness)
        let chip = plan ?? provider
        let kinds: [AgentQuotaWindowKind] = [.fiveHour, .sevenDay]
        let windows: [AgentAccountUsageCardPresentation.Window] = kinds.compactMap { kind in
            guard let window = quota?.window(kind) else { return nil }
            return presentCardWindow(window, now: now)
        }
        var footnote = "Limits are per account, shared by every agent on it."
        if let quota {
            footnote += " Read \(ago(quota.observedAt, now: now))."
        } else {
            footnote += " No reading yet."
        }
        let who = identity?.email ?? identity?.organizationName
        return AgentAccountUsagePresentation(
            chipText: chip,
            chipAccessibilityLabel: "Account: \(provider) \(plan ?? "")\(who.map { ", \($0)" } ?? "")."
                .replacingOccurrences(of: " .", with: "."),
            card: AgentAccountUsageCardPresentation(
                title: plan.map { "\(provider) · \($0)" } ?? provider,
                subtitle: who,
                statusText: "in use",
                windows: windows,
                footnote: footnote))
    }

    private static func presentCardWindow(
        _ window: AgentQuotaWindow,
        now: Date
    ) -> AgentAccountUsageCardPresentation.Window {
        let title = window.kind == .fiveHour ? "5-hour" : "Weekly"
        if window.isExpired(at: now) {
            return .init(kind: window.kind, title: title, valueText: "—", remainingFraction: nil,
                         state: .expired, resetText: "Reset passed · waiting for a new reading")
        }
        let reset = window.resetsAt.map { resetText($0, now: now) } ?? "Reset time unknown"
        guard let used = window.utilization else {
            return .init(kind: window.kind, title: title, valueText: "—", remainingFraction: nil,
                         state: .unknown, resetText: reset)
        }
        return .init(
            kind: window.kind, title: title, valueText: "\(percentLeft(used: used))% left",
            remainingFraction: max(0, min(1, 1 - used)), state: state(used: used), resetText: reset)
    }

    private static func providerName(_ harness: AgentHarness) -> String {
        switch harness {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        }
    }

    /// `Resets 3:10 PM · in 2h 17m` inside a day; `Resets Thu 5 Nov, 1:00 AM`
    /// beyond it, where a countdown in days and hours reads worse than a date.
    static func resetText(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds > 0, seconds < 86_400 {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Resets \(formatter.string(from: date)) · \(relative(date, from: now))"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM j:mm")
        return "Resets \(formatter.string(from: date))"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    // MARK: - helpers

    private static let scopeNote =
        "Scope: this whole provider account, shared by every agent signed into it — not this agent alone."

    private static func windowKind(for element: AgentStatusElement) -> AgentQuotaWindowKind? {
        switch element {
        case .quotaFiveHour: return .fiveHour
        case .quotaSevenDay: return .sevenDay
        case .quotaSpendLimit: return .spendLimit
        case .location, .activity, .processes, .contextMeter, .cost: return nil
        }
    }

    private static func observedLine(_ snapshot: AgentAccountQuotaSnapshot) -> String {
        "Source: \(snapshot.source.displayLabel)\nObserved: \(absolute(snapshot.observedAt))"
    }

    private static func creditsLine(_ credits: AgentQuotaCredits) -> String? {
        var parts: [String] = []
        if let plan = credits.planLabel, !plan.isEmpty { parts.append("plan \(plan)") }
        if credits.unlimited == true {
            parts.append("credits unlimited")
        } else if let balance = credits.balance {
            parts.append("credit balance \(balance)")
        }
        guard !parts.isEmpty else { return nil }
        return "Account: " + parts.joined(separator: ", ")
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Relative reset wording. Spoken and shown in the tooltip; the row itself
    /// has no room for it.
    static func relative(_ date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "already passed" }
        if seconds < 60 { return "in under a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h \(minutes % 60)m" }
        return "in \(hours / 24)d \(hours % 24)h"
    }
}
