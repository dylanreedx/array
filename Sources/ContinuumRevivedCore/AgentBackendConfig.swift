import Foundation

// Plan: .plans/02-codex-backend-and-toggle.md §4 (the explicit backend toggle).
//
// A pure, UserDefaults-backed policy type — the same shape as `AgentModelConfig`
// / `FocusBorderConfig`: a resolver plus pure functions the matrix pins. It
// governs TWO things and nothing else:
//   · `filter(_:for:)` — which providers the model dropdown shows (Settings AND
//     the tile composer, via `AgentModelConfig.modelOptions`).
//   · `route(model:backend:...)` — which runner a spawn uses. Replaces the
//     ad-hoc anthropic prefix check that used to live in
//     `AgentSupervisor.productionRunner`.
//
// The DEFAULT is `.pi`, whose filter is nil (all providers) and whose routing is
// the SHIPPED native-preferring behaviour (anthropic → claude, openai-codex →
// codex, else pi). So a machine with no stored preference behaves byte-for-byte
// as before this plan — every existing check keeps its expected model set.

/// Which agent backend the user has chosen. The two explicit modes NARROW: they
/// hide every other provider and pin the native CLI for the one provider they
/// expose; `.pi` is the multi-provider default. Raw values are the human labels
/// shown by the generic settings `.choice` renderer (which uses the option
/// string as both title and stored value); the CASE names are what routing and
/// filtering switch on.
public enum AgentBackend: String, CaseIterable, Sendable {
    case pi = "pi (all providers)"
    case claudeCode = "Claude Code"
    case codex = "Codex"
}

public enum AgentBackendConfig {
    public static let key = "continuum.agents.backend"
    /// The default IS the current shipped behaviour (all providers, native
    /// routing). Changing the stored value is the only thing that narrows.
    public static let defaultBackend: AgentBackend = .pi

    /// The ordered option strings for the settings `.choice` (labels == stored
    /// values, per the generic renderer's contract).
    public static var options: [String] { AgentBackend.allCases.map(\.rawValue) }

    public static func resolved(defaults: UserDefaults = .standard) -> AgentBackend {
        AgentBackend(rawValue: defaults.string(forKey: key) ?? "") ?? defaultBackend
    }

    /// Persist a chosen backend (used by QA to exercise filtering/routing).
    public static func store(_ backend: AgentBackend, defaults: UserDefaults = .standard) {
        defaults.set(backend.rawValue, forKey: key)
    }

    /// The provider tail of a fully-qualified `provider/model` id. Slashless ids
    /// (off-catalogue record values) group under "other". This is the ONE copy
    /// of the split rule — `ProviderModelGrouping.provider(forID:)` in the app
    /// target delegates here so the app and the matrix pin the same logic.
    public static func provider(forID id: String) -> String {
        let parts = id.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : "other"
    }

    /// Providers visible for a backend. `.pi` ⇒ nil (no filter / all providers).
    public static func allowedProviders(for backend: AgentBackend) -> Set<String>? {
        switch backend {
        case .pi: return nil
        case .claudeCode: return ["anthropic"]
        case .codex: return ["openai-codex"]
        }
    }

    /// Pure dropdown filter, pinned in the matrix. `.pi` returns the ids
    /// unchanged (byte-identical to today). The caller owns the "never blank the
    /// picker" fallback (an empty result means fall back to the unfiltered list)
    /// — see `AgentModelConfig.modelOptions(for:)`.
    public static func filter(_ ids: [String], for backend: AgentBackend) -> [String] {
        guard let allow = allowedProviders(for: backend) else { return ids }
        return ids.filter { allow.contains(provider(forID: $0)) }
    }

    /// Which runner a model routes to under a backend, given live CLI
    /// availability. Pure and pinned in the matrix; replaces the ad-hoc check in
    /// `productionRunner`.
    public enum Route: Equatable, Sendable { case claude, codex, pi }

    public static func route(
        model: String,
        backend: AgentBackend,
        claudeAvailable: Bool,
        codexAvailable: Bool
    ) -> Route {
        switch backend {
        case .claudeCode:
            return claudeAvailable && model.hasPrefix("anthropic/") ? .claude : .pi
        case .codex:
            return codexAvailable && model.hasPrefix("openai-codex/") ? .codex : .pi
        case .pi:
            // The SHIPPED native-preferring routing, extended with codex.
            if claudeAvailable, model.hasPrefix("anthropic/") { return .claude }
            if codexAvailable, model.hasPrefix("openai-codex/") { return .codex }
            return .pi
        }
    }
}
