import Foundation

/// Model catalogues for QA ONLY. The real app never serves these.
///
/// Every catalogue Array offers comes from the CLI that will run the model:
/// claude's `initialize` handshake, codex's `model/list`, pi's `--list-models`.
/// Checks cannot spawn those CLIs, so `AgentModelCatalog` serves this data while
/// live refresh is off, which only checks and previews leave off. Once the real
/// app calls `enableLiveRefresh()`, an empty or failed probe serves an empty
/// catalogue, never this one (`--live-model-catalog-check`).
public enum AgentCatalogQAFixture {
    /// A real `claude` 2.1.285 `initialize` control_response, captured
    /// 2026-10-01 and reduced to its `models` array. Parsed by the same
    /// `ClaudeCLIBackend.parseInitializeModels` production uses.
    public static let claudeInitializeResponse = #"""
{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"models":[{"value":"default","resolvedModel":"claude-fable-5-1","displayName":"Default (recommended)","description":"Fable 5.1","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work and everyday tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},{"value":"claude-fable-5-1","resolvedModel":"claude-fable-5-1","displayName":"Fable 5.1","description":"For your toughest challenges","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"sonnet","resolvedModel":"claude-sonnet-5-5","displayName":"Sonnet 5.5","description":"Most efficient for simpler tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fastest for quick answers"},{"value":"claude-sonnet-5","resolvedModel":"claude-sonnet-5","displayName":"Sonnet 5","description":"Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"claude-opus-5","resolvedModel":"claude-opus-5","displayName":"Opus 5","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},{"value":"claude-fable-5","resolvedModel":"claude-fable-5","displayName":"Fable 5","description":"Most capable for your hardest and longest-running tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"claude-opus-4-8","resolvedModel":"claude-opus-4-8","displayName":"Opus 4.8","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},{"value":"claude-opus-4-7","resolvedModel":"claude-opus-4-7","displayName":"Opus 4.7","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"claude-opus-4-6","resolvedModel":"claude-opus-4-6","displayName":"Opus 4.6","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},{"value":"claude-sonnet-4-6","resolvedModel":"claude-sonnet-4-6","displayName":"Sonnet 4.6","description":"Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true}]}}}
"""#

    public static let claude: AgentHarnessCatalogSnapshot = {
        ClaudeCLIBackend.parseInitializeModels(controlResponseLine: claudeInitializeResponse)
            ?? AgentHarnessCatalogSnapshot(harness: .claudeCode, readiness: .ready, models: [])
    }()

    public static let codex = AgentHarnessCatalogSnapshot(
        harness: .codex, readiness: .ready,
        models: [
            "openai-codex/gpt-6-astra",
            "openai-codex/gpt-5.6-sol",
            "openai-codex/gpt-5.6-terra",
            "openai-codex/gpt-5.6-luna",
            "openai-codex/gpt-5.5",
            "openai-codex/gpt-5.4",
            "openai-codex/gpt-5.4-mini",
            "openai-codex/gpt-5.3-codex-spark",
        ],
        displayNames: [
            "openai-codex/gpt-6-astra": "GPT-6 Astra",
            "openai-codex/gpt-5.6-sol": "GPT-5.6 Sol",
            "openai-codex/gpt-5.6-terra": "GPT-5.6 Terra",
            "openai-codex/gpt-5.6-luna": "GPT-5.6 Luna",
            "openai-codex/gpt-5.5": "GPT-5.5",
            "openai-codex/gpt-5.4": "GPT-5.4",
            "openai-codex/gpt-5.4-mini": "GPT-5.4 Mini",
            "openai-codex/gpt-5.3-codex-spark": "GPT-5.3 Codex Spark",
        ],
        defaultModel: "openai-codex/gpt-6-astra")

    public static let pi: [String] = [
        "openai-codex/gpt-5.6-sol",
        "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.6-terra",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini",
        "openai-codex/gpt-5.3-codex-spark",
    ]
}

extension AgentCatalogQAFixture {
    /// Pin the AMBIENT new-agent selection — what `UserDefaults.standard` answers
    /// for harness, model and thinking — for the length of a check, and return the
    /// undo.
    ///
    /// A bare `swift build` binary has no bundle id, so its standard domain is
    /// `Array`: ONE persistent domain shared by every check leg, every worktree and
    /// every concurrent matrix run on the machine. A leg that saved, wrote and
    /// restored these keys there left `openai-codex/gpt-5.6-sol` behind once it lost
    /// a race or died before its `defer`; with the harness key later cleared that is
    /// a Codex model under Claude Code, and every leg that spawns through the
    /// ambient defaults refused "New agent refused:  is no longer offered…".
    ///
    /// This writes the argument domain, which outranks the persistent one and is
    /// never written to disk — the same in-process override `--zone-arming-check`
    /// uses. Inside the pin a write to the standard domain is shadowed, so a check
    /// that wants a different ambient harness pins again rather than storing one.
    public static func pinAmbientSelection(
        harness: AgentHarness,
        model: String,
        thinking: String = AgentModelConfig.defaultThinking,
        defaults: UserDefaults = .standard
    ) -> () -> Void {
        QADefaultsPin.pin([
            AgentHarnessConfig.key: harness.rawValue,
            AgentModelConfig.modelKey: model,
            AgentModelConfig.thinkingKey: thinking,
        ], defaults: defaults)
    }
}
