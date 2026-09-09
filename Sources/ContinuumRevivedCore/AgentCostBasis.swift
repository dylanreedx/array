import Foundation

/// What a `totalCostUsd` figure actually IS.
///
/// One `Double?` carried two incompatible meanings and rendered both as
/// `cost $0.0150`, which is the defect this type fixes:
///
/// - **claude** reports `result.total_cost_usd`, which Anthropic's own
///   documentation describes as "computed client-side at list price" and which
///   "may differ from your actual bill". Under the CLI login Array requires
///   (provider auth is always the CLI's own OAuth flow — never API keys), a
///   Pro/Max subscription is not billed per token at all, so this number is a
///   what-the-API-would-have-charged estimate and nothing else.
/// - **pi** reports `usage.cost.total` for a metered account, which is a real
///   charge.
/// - **codex** reports no cost on either transport.
///
/// Presenting the first as money spent is the kind of confidently wrong number
/// this codebase has paid for before. The basis travels with the figure so the
/// presenter can say which one it is holding.
public enum AgentCostBasis: String, Equatable, Sendable, Codable {
    /// A real metered charge the provider computed for the account (pi).
    case providerMetered
    /// A client-side list-price estimate; not a bill (claude).
    case listPriceEstimate

    /// Suffix for a rendered amount. Deliberately not empty for either case:
    /// an unlabelled currency figure is the ambiguity being removed.
    public var disclosureLabel: String {
        switch self {
        case .providerMetered: return "metered"
        case .listPriceEstimate: return "list-price estimate"
        }
    }

    /// The long form for tooltips, where there is room to say why it matters.
    public var detailSentence: String {
        switch self {
        case .providerMetered:
            return "Cost basis: metered charge reported by the provider for this account."
        case .listPriceEstimate:
            return "Cost basis: client-side estimate at list price. Not a bill — a subscription login is not charged per token."
        }
    }
}
