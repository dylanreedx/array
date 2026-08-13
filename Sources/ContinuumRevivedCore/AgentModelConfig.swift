import Foundation

public enum AgentModelConfig {
    public static let modelKey = "continuum.agents.model"
    public static let thinkingKey = "continuum.agents.thinking"

    public static let defaultModel = "anthropic/opus"
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
        let harness = AgentHarnessConfig.resolved(defaults: defaults)
        let options = modelOptions(for: harness)
        let harnessDefault = harness == .claudeCode ? defaultModel : (options.first ?? defaultModel)
        return Resolution(
            model: oneOf(defaults.string(forKey: modelKey), options, harnessDefault),
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
