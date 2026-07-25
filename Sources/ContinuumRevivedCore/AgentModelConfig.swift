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
/// Only `openai-codex` is authed on this machine, and `pi --list-models` only
/// lists usable models — so the options are exactly that provider's catalogue.
/// Adding a knob = one key + one field here + one `SettingsField`.
public enum AgentModelConfig {
    public static let modelKey = "continuum.agents.model"
    public static let thinkingKey = "continuum.agents.thinking"

    /// Pi's own default. Fully qualified: no fuzzy matching, no ambiguity.
    public static let defaultModel = "openai-codex/gpt-5.6-sol"
    public static let defaultThinking = "medium"

    /// Fully-qualified ids, verbatim from `pi --list-models` (openai-codex,
    /// 2026-07-25) — the single source shared by `SettingsSchema` (the `.choice`
    /// options) and the matrix check.
    public static let modelOptions = [
        "openai-codex/gpt-5.6-sol",
        "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.6-terra",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini",
        "openai-codex/gpt-5.3-codex-spark",
    ]

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
    /// handed to Pi — a typo must not reintroduce fuzzy matching.
    public static func resolvedFromDefaults(defaults: UserDefaults = .standard) -> Resolution {
        Resolution(
            model: oneOf(defaults.string(forKey: modelKey), modelOptions, defaultModel),
            thinking: oneOf(defaults.string(forKey: thinkingKey), thinkingOptions, defaultThinking)
        )
    }

    private static func oneOf(_ value: String?, _ options: [String], _ fallback: String) -> String {
        guard let value, options.contains(value) else { return fallback }
        return value
    }
}
