import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P0.10-explicit-model-id.md
//
// `pi --model` takes a *pattern*, not an id: an unqualified or partial string
// fuzzy-matches and Pi silently picks one candidate. The old default
// "openai-codex/gpt-5.6" matched three catalogue entries, so which model a tile
// ran was non-deterministic. These checks pin that every offered id is an EXACT
// catalogue entry.
func runAgentModelConfigChecks() {
    // Snapshot of `pi --list-models` (2026-07-25). Only openai-codex is authed
    // on this machine and --list-models lists only usable models, so this is
    // the whole catalogue. Pinned as a literal so the matrix stays offline and
    // deterministic; refresh it when the provider catalogue changes.
    let catalogue: Set<String> = [
        "openai-codex/gpt-5.3-codex-spark",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.4-mini",
        "openai-codex/gpt-5.5",
        "openai-codex/gpt-5.6-luna",
        "openai-codex/gpt-5.6-sol",
        "openai-codex/gpt-5.6-terra",
    ]

    // 1. The default is an exact catalogue id — not a prefix Pi has to guess at.
    expect(catalogue.contains(AgentModelConfig.defaultModel),
           "defaultModel must be an exact `pi --list-models` id, got \(AgentModelConfig.defaultModel)")

    // 2. The retired literal is the bug this ticket fixes: absent from the
    //    catalogue, yet a prefix of several ids — i.e. ambiguous by construction.
    let retired = "openai-codex/gpt-5.6"
    let retiredMatches = catalogue.filter { $0.hasPrefix(retired) }
    expect(!catalogue.contains(retired) && retiredMatches.count > 1,
           "the retired default \(retired) must be a non-id prefix of several ids (got \(retiredMatches.count)) — otherwise this check proves nothing")
    expect(AgentModelConfig.defaultModel != retired && !AgentModelConfig.modelOptions.contains(retired),
           "the ambiguous \(retired) must not be offered anywhere")

    // 3. Every offered model is fully qualified (provider/id) and exact.
    for model in AgentModelConfig.modelOptions {
        let parts = model.split(separator: "/", omittingEmptySubsequences: false)
        expect(parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty,
               "modelOptions entry must be fully qualified provider/id, got \(model)")
        expect(catalogue.contains(model),
               "modelOptions entry must be an exact catalogue id, got \(model)")
    }
    expect(Set(AgentModelConfig.modelOptions).count == AgentModelConfig.modelOptions.count,
           "modelOptions must not repeat an id")

    // 4. Thinking levels are exactly the ones `pi --thinking` documents.
    let piThinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    expect(Set(AgentModelConfig.thinkingOptions).isSubset(of: piThinkingLevels),
           "thinkingOptions must be a subset of pi's levels, got \(AgentModelConfig.thinkingOptions)")
    expect(AgentModelConfig.thinkingOptions.contains(AgentModelConfig.defaultThinking),
           "defaultThinking must be one of thinkingOptions, got \(AgentModelConfig.defaultThinking)")
    expect(Set(AgentModelConfig.thinkingOptions).count == AgentModelConfig.thinkingOptions.count,
           "thinkingOptions must not repeat a level")

    // 5. Resolution: empty defaults yield the defaults; a valid override wins;
    //    an unrecognized stored value falls back rather than reaching Pi (a typo
    //    must not reintroduce fuzzy matching).
    let suiteName = "AgentModelConfigChecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)

    let empty = AgentModelConfig.resolvedFromDefaults(defaults: defaults)
    expect(empty == .init(model: AgentModelConfig.defaultModel, thinking: AgentModelConfig.defaultThinking),
           "empty defaults must resolve to the defaults, got \(empty)")

    defaults.set("openai-codex/gpt-5.6-terra", forKey: AgentModelConfig.modelKey)
    defaults.set("xhigh", forKey: AgentModelConfig.thinkingKey)
    let overridden = AgentModelConfig.resolvedFromDefaults(defaults: defaults)
    expect(overridden == .init(model: "openai-codex/gpt-5.6-terra", thinking: "xhigh"),
           "a valid override must win, got \(overridden)")

    defaults.set(retired, forKey: AgentModelConfig.modelKey)
    defaults.set("ludicrous", forKey: AgentModelConfig.thinkingKey)
    let rejected = AgentModelConfig.resolvedFromDefaults(defaults: defaults)
    expect(rejected == .init(model: AgentModelConfig.defaultModel, thinking: AgentModelConfig.defaultThinking),
           "an unrecognized stored value must fall back to the default, got \(rejected)")

    // 6. Settings ▸ Agents surfaces both pickers, bound to the exact keys the
    //    resolver reads (so the picker actually drives the next spawn).
    let agentsFields = SettingsSchema.sections().first { $0.id == "agents" }?.fields ?? []
    let agentsKeys = Set(agentsFields.compactMap(\.key))
    expect(agentsKeys.contains(AgentModelConfig.modelKey) && agentsKeys.contains(AgentModelConfig.thinkingKey),
           "Settings ▸ Agents must bind both AgentModelConfig keys, got \(agentsKeys.sorted())")

    // 7. The runner's Config actually defaults from the resolver (a re-hardcoded
    //    literal would diverge from it), and both values reach the Pi argv.
    #if os(macOS)
    let resolved = AgentModelConfig.resolvedFromDefaults()
    let config = PiAgentRunner.Config(cwd: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
    expect(config.model == resolved.model && config.thinking == resolved.thinking,
           "PiAgentRunner.Config must default from AgentModelConfig, got model=\(config.model) thinking=\(config.thinking)")

    let argv = PiAgentRunner.processArguments(
        model: config.model, thinking: config.thinking, sessionId: nil, extraArgs: [], prompt: "hi")
    expect(argv.firstIndex(of: "--model").map { argv[$0 + 1] } == resolved.model,
           "the resolved model must reach Pi's argv, got \(argv)")
    expect(argv.firstIndex(of: "--thinking").map { argv[$0 + 1] } == resolved.thinking,
           "the resolved thinking level must reach Pi's argv (an inert picker is the bug), got \(argv)")
    #endif

    print("AgentModelConfig checks passed: default is an exact catalogue id, no ambiguous prefix offered, thinking levels valid, unrecognized values fall back, Settings binds both keys, Config defaults from the resolver and both values reach Pi's argv")
}
