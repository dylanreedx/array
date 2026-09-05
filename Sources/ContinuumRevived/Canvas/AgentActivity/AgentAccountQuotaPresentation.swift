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
    /// Raw fraction, uncapped. A spend limit above 1.0 stays above 1.0.
    let fraction: Double?
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
        case .spendLimit: return "creditcard"
        case .unknown: return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    static func present(
        _ snapshot: AgentAccountQuotaSnapshot?,
        element: AgentStatusElement,
        now: Date
    ) -> AgentQuotaElementPresentation {
        guard let kind = windowKind(for: element) else {
            return unknown(element: element, reason: "Not an account quota element.")
        }
        guard let snapshot else {
            return unknown(
                element: element,
                reason: "No account quota telemetry has been observed for this provider.")
        }
        guard let window = snapshot.window(kind) else {
            // The provider reported OTHER windows but not this one. On claude
            // that is documented to mean the window expired or the plan has no
            // such limit — never that it is empty.
            return unknown(
                element: element,
                reason: "The provider did not report a \(kind.spokenLabel) window. It may not apply to this plan, or it may have already reset.",
                snapshot: snapshot)
        }

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
        let state: AgentQuotaElementState
        let marker: String
        if fraction >= criticalThreshold {
            state = .critical
            marker = "! "
        } else if fraction >= warningThreshold {
            state = .warning
            marker = "⚠︎ "
        } else {
            state = .known
            marker = ""
        }

        var detail = [
            "Account \(kind.spokenLabel): \(percent)% used",
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
            valueText: "\(marker)\(percent)%",
            accessibilityLabel: "Account \(kind.spokenLabel) \(percent) percent used"
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

    // MARK: - helpers

    private static let scopeNote =
        "Scope: this whole provider account, shared by every agent signed into it — not this agent alone."

    private static func windowKind(for element: AgentStatusElement) -> AgentQuotaWindowKind? {
        switch element {
        case .quotaFiveHour: return .fiveHour
        case .quotaSevenDay: return .sevenDay
        case .quotaSpendLimit: return .spendLimit
        case .location, .activity, .contextMeter, .cost: return nil
        }
    }

    private static func unknown(
        element: AgentStatusElement,
        reason: String,
        snapshot: AgentAccountQuotaSnapshot? = nil
    ) -> AgentQuotaElementPresentation {
        let kind = windowKind(for: element)
        let kindLabel = kind?.shortLabel ?? "—"
        let spoken = kind?.spokenLabel ?? "usage"
        var lines = ["Account \(spoken): unknown", reason]
        if let snapshot { lines.append(observedLine(snapshot)) }
        lines.append(scopeNote)
        return AgentQuotaElementPresentation(
            element: element,
            state: .unknown,
            fraction: nil,
            symbolName: kind.map(symbolName(for:)) ?? "questionmark.circle",
            shortLabel: kindLabel,
            valueText: "—",
            accessibilityLabel: "Account \(spoken) unknown.",
            detailText: lines.joined(separator: "\n"))
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
