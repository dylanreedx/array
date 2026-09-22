import Foundation

/// Which providers the Pi harness is allowed to OFFER.
///
/// Anthropic models are removed from Pi deliberately. Array runs Anthropic
/// models on the user's own `claude` CLI (`ClaudeAgentRunner`), which is the
/// subscription-correct, Anthropic-sanctioned path; pi's anthropic path meters
/// the same models through pi's own OAuth instead. Offering both made one model
/// appear twice under two harnesses with different billing and different
/// transcript fidelity, which is a choice no user can make correctly.
///
/// This is an OFFERING policy, not a capability claim: pi can still run a model
/// a record was already persisted on (see `isRetiredSelection`). The exclusion
/// is applied where pi's live catalogue is written — `AgentModelCatalog`'s
/// `apply(listModelsOutput:)` — so pi's display-name and context-window maps,
/// which are keyed by id and shared with the claude harness, stay whole.
public enum PiCatalogPolicy {
    /// Provider segments (the part before the `/`) Pi must never offer.
    public static let excludedProviders: Set<String> = ["anthropic"]

    public static func excludes(_ model: String) -> Bool {
        excludedProviders.contains(AgentHarnessConfig.provider(forID: model))
    }

    /// The subset of `ids` the Pi harness may offer, in the given order.
    public static func offerable(_ ids: [String]) -> [String] {
        ids.filter { !excludes($0) }
    }

    /// A model Pi could run, and that a persisted record may still hold, but
    /// that Array no longer offers under Pi. Such a record keeps running and is
    /// never silently re-pointed at another CLI; it simply cannot be chosen
    /// again once the user moves off it.
    public static func isRetiredSelection(model: String, harness: AgentHarness) -> Bool {
        harness == .pi && excludes(model)
    }
}

public enum AgentModelConfig {
    public static let modelKey = "continuum.agents.model"
    public static let thinkingKey = "continuum.agents.thinking"

    /// The seed for a NEW agent under the default harness (Claude Code). An
    /// EXPLICIT id, never an alias: `anthropic/opus` renamed itself under the
    /// user on every Anthropic release and was not a key in the context-window
    /// map. Must stay an exact member of `ClaudeCLIBackend.curatedCatalogModels`.
    public static let defaultModel = "anthropic/claude-opus-5"
    public static let defaultThinking = "medium"

    /// Frozen Pi fixture for deterministic QA/offline presentation. It is never
    /// evidence that production Pi is authenticated.
    public static let fallbackModelOptions = [
        "openai-codex/gpt-5.6-sol",
        "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.6-terra",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini",
        "openai-codex/gpt-5.3-codex-spark",
    ]

    public static var modelOptions: [String] {
        modelOptions(for: AgentHarnessConfig.resolved())
    }

    public static func modelOptions(for harness: AgentHarness) -> [String] {
        AgentModelCatalog.shared.models(for: harness)
    }

    public static let thinkingOptions = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    public struct Resolution: Equatable, Sendable {
        public let model: String
        public let thinking: String

        public init(model: String, thinking: String) {
            self.model = model
            self.thinking = thinking
        }
    }

    public static func resolvedFromDefaults(defaults: UserDefaults = .standard) -> Resolution {
        resolvedFromDefaults(harness: AgentHarnessConfig.resolved(defaults: defaults), defaults: defaults)
    }

    /// Resolution scoped to a NAMED harness rather than whichever one settings
    /// currently seeds. A caller that already knows which CLI it is about to run
    /// must ask for that CLI's catalogue: under strict ownership the ambient
    /// harness can be Claude Code while the caller is Pi, and an anthropic id is
    /// not something Pi offers at all any more (`PiCatalogPolicy`).
    public static func resolvedFromDefaults(harness: AgentHarness, defaults: UserDefaults = .standard) -> Resolution {
        let options = modelOptions(for: harness)
        let harnessDefault = harness == .claudeCode ? defaultModel : (options.first ?? defaultModel)
        let stored = defaults.string(forKey: modelKey)
        return Resolution(
            model: oneOf(stored, options, harnessDefault),
            thinking: oneOf(defaults.string(forKey: thinkingKey), thinkingOptions, defaultThinking)
        )
    }

    /// Strict new-agent selection. A stored model that does not belong to the
    /// chosen harness is not rewritten or substituted.
    public static func launchSelection(
        harness explicitHarness: AgentHarness? = nil,
        model explicitModel: String? = nil,
        thinking explicitThinking: String? = nil,
        defaults: UserDefaults = .standard
    ) -> AgentLaunchSelection? {
        let harness = explicitHarness ?? AgentHarnessConfig.resolved(defaults: defaults)
        let model = explicitModel ?? defaults.string(forKey: modelKey) ?? (harness == .claudeCode ? defaultModel : "")
        let thinking = explicitThinking ?? defaults.string(forKey: thinkingKey) ?? defaultThinking
        guard modelOptions(for: harness).contains(model),
              AgentHarnessConfig.isProviderCompatible(model: model, harness: harness),
              thinkingOptions.contains(thinking) else { return nil }
        return AgentLaunchSelection(harness: harness, model: model, thinking: thinking)
    }

    public static func resolved(selection: String?, defaults: UserDefaults = .standard) -> Resolution? {
        let base = resolvedFromDefaults(defaults: defaults)
        guard let selection else { return base }
        let harness = AgentHarnessConfig.resolved(defaults: defaults)
        guard modelOptions(for: harness).contains(selection) else { return nil }
        return Resolution(model: selection, thinking: base.thinking)
    }

    public static func validates(_ selection: AgentLaunchSelection, requireReady: Bool = true) -> Bool {
        let snapshot = AgentModelCatalog.shared.snapshot(for: selection.harness)
        return (!requireReady || snapshot.readiness.canRun)
            && snapshot.models.contains(selection.model)
            && AgentHarnessConfig.isProviderCompatible(model: selection.model, harness: selection.harness)
            && thinkingOptions.contains(selection.thinking)
    }

    private static func oneOf(_ value: String?, _ options: [String], _ fallback: String) -> String {
        guard let value, options.contains(value) else { return fallback }
        return value
    }
}
