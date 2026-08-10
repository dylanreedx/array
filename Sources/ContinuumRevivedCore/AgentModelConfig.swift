import Foundation

/// Resolves which Pi model (and thinking level) a managed agent runs with, from
/// UserDefaults, mirroring `FocusBorderConfig` / `TileGapResolver`.
///
/// Ticket: docs/38-tickets/90-agent-ux/P0.10-explicit-model-id.md
///
/// Why this exists: the runner used to hardcode `"openai-codex/gpt-5.6"`, which
/// is NOT an id in Pi's catalogue — `--model` takes a *pattern*, so that string
/// fuzzy-matched across `gpt-5.6-luna` / `-sol` / `-terra` and the tile silently
/// ran whichever one Pi picked. Every id here is fully qualified
/// (`provider/model-id`) and exact.
///
/// The options are live: `AgentModelCatalog` probes `pi --list-models` at
/// real-app startup (pi lists only models whose provider is authed — via
/// pi's own `/login` CLI flow, never pasted API keys), falling back to the
/// frozen snapshot below when the probe hasn't run or pi is missing. QA never
/// probes, so checks always see the fallback.
public enum AgentModelConfig {
    public static let modelKey = "continuum.agents.model"
    public static let thinkingKey = "continuum.agents.thinking"

    /// Pi's own default. Fully qualified: no fuzzy matching, no ambiguity.
    public static let defaultModel = "openai-codex/gpt-5.6-sol"
    public static let defaultThinking = "medium"

    /// Frozen snapshot of `pi --list-models` (openai-codex, 2026-07-25): what
    /// the picker offers until the live probe succeeds, and always in QA.
    public static let fallbackModelOptions = [
        "openai-codex/gpt-5.6-sol",
        "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.6-terra",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini",
        "openai-codex/gpt-5.3-codex-spark",
    ]

    /// Fully-qualified ids, verbatim from pi's own list — the single source
    /// shared by `SettingsSchema` (the `.choice` options), the tile composer,
    /// and provider-settings validation.
    ///
    /// The list is narrowed to the resolved backend's providers (Plan 02 §4.4):
    /// filtering here auto-applies everywhere `modelOptions` is read, with zero
    /// call-site edits. The DEFAULT backend (`.pi`) filters to nil, so this is
    /// byte-identical to the pre-plan list — no existing check's model set moves.
    public static var modelOptions: [String] { modelOptions(for: AgentBackendConfig.resolved()) }

    /// The catalogue narrowed to `backend`'s providers, with the "never blank
    /// the picker" guard: if narrowing empties the list (e.g. Codex selected
    /// before the catalog union added `openai-codex/*`), fall back to the
    /// unfiltered list rather than showing nothing — the same rule
    /// `AgentModelCatalog.apply` and `resolvedFromDefaults` already follow.
    public static func modelOptions(for backend: AgentBackend) -> [String] {
        let all = AgentModelCatalog.shared.options()
        let filtered = AgentBackendConfig.filter(all, for: backend)
        return filtered.isEmpty ? all : filtered
    }

    /// The levels `pi --thinking <level>` accepts.
    public static let thinkingOptions = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    public struct Resolution: Equatable, Sendable {
        public let model: String
        public let thinking: String

        public init(model: String, thinking: String) {
            self.model = model
            self.thinking = thinking
        }
    }

    /// An unrecognized stored value falls back to the default rather than being
    /// handed to Pi — a typo must not reintroduce fuzzy matching. With a live
    /// catalogue the default itself can be unavailable (its provider not
    /// authed); the first usable model stands in, because handing Pi a model
    /// it can't run fails every spawn.
    public static func resolvedFromDefaults(defaults: UserDefaults = .standard) -> Resolution {
        let options = modelOptions
        let modelFallback = options.contains(defaultModel) ? defaultModel : (options.first ?? defaultModel)
        return Resolution(
            model: oneOf(defaults.string(forKey: modelKey), options, modelFallback),
            thinking: oneOf(defaults.string(forKey: thinkingKey), thinkingOptions, defaultThinking)
        )
    }

    private static func oneOf(_ value: String?, _ options: [String], _ fallback: String) -> String {
        guard let value, options.contains(value) else { return fallback }
        return value
    }
}
