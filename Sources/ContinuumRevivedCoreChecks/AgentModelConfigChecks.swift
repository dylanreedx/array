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

    // Strict harness ownership gave each CLI its own catalogue, so "the exact id
    // rule" is now per-harness: an id is exact for the harness that owns it and
    // meaningless to the other two. Pinned as literals for the same reason the pi
    // list is — the matrix stays offline, and a curated list that moves must move
    // here too.
    //
    // These are also asked for EXPLICITLY, never through the ambient
    // `AgentHarnessConfig.resolved()`. Reading the ambient harness made this check
    // report whatever the operator's own `continuum.agents.backend` happened to
    // say: green on a machine storing "pi (all providers)", red in three places on
    // a clean one. A check that changes verdict with a preference is not a witness.
    let catalogueByHarness: [AgentHarness: Set<String>] = [
        .pi: catalogue,
        .claudeCode: ["anthropic/opus", "anthropic/sonnet", "anthropic/haiku"],
        .codex: catalogue,
    ]

    // 1. The default is an exact id of the harness that seeds a new agent — not a
    //    prefix a CLI has to guess at.
    let defaultHarness = AgentHarnessConfig.defaultHarness
    expect(catalogueByHarness[defaultHarness]?.contains(AgentModelConfig.defaultModel) == true,
           "defaultModel must be an exact id in \(defaultHarness.rawValue)'s catalogue, got \(AgentModelConfig.defaultModel)")

    // 2. The retired literal is the bug this ticket fixes: absent from the
    //    catalogue, yet a prefix of several ids — i.e. ambiguous by construction.
    let retired = "openai-codex/gpt-5.6"
    let retiredMatches = catalogue.filter { $0.hasPrefix(retired) }
    expect(!catalogue.contains(retired) && retiredMatches.count > 1,
           "the retired default \(retired) must be a non-id prefix of several ids (got \(retiredMatches.count)) — otherwise this check proves nothing")
    // 3. Every offered model is fully qualified (provider/id) and exact — for
    //    EVERY harness, not just whichever one is currently selected. The
    //    non-empty assertion is load-bearing: an empty catalogue would satisfy the
    //    loop vacuously while leaving the picker blank and every spawn refused.
    for harness in AgentHarness.allCases {
        let options = AgentModelConfig.modelOptions(for: harness)
        let expected = catalogueByHarness[harness] ?? []
        expect(!options.isEmpty, "\(harness.rawValue) must offer at least one model")
        expect(!options.contains(retired), "the ambiguous \(retired) must not be offered by \(harness.rawValue)")
        for model in options {
            let parts = model.split(separator: "/", omittingEmptySubsequences: false)
            expect(parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty,
                   "\(harness.rawValue) option must be fully qualified provider/id, got \(model)")
            expect(expected.contains(model),
                   "\(harness.rawValue) option must be an exact id in its own catalogue, got \(model)")
            expect(AgentHarnessConfig.isProviderCompatible(model: model, harness: harness),
                   "\(harness.rawValue) must not offer \(model), which belongs to another harness")
        }
        expect(Set(options).count == options.count, "\(harness.rawValue) must not repeat an id")
    }
    expect(AgentModelConfig.defaultModel != retired, "the ambiguous \(retired) must not be the default")

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

    // Every resolution below names its harness. `UserDefaults(suiteName:)` also
    // searches the app's own domain, so an ambient `continuum.agents.backend` on
    // the operator's machine reaches a "fresh" suite and silently decides which
    // catalogue these assertions run against.
    let empty = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode, defaults: defaults)
    expect(empty == .init(model: AgentModelConfig.defaultModel, thinking: AgentModelConfig.defaultThinking),
           "empty defaults must resolve to the defaults under the seeding harness, got \(empty)")

    let emptyPi = AgentModelConfig.resolvedFromDefaults(harness: .pi, defaults: defaults)
    expect(catalogue.contains(emptyPi.model),
           "empty defaults under Pi must resolve to an exact Pi id, never another harness's, got \(emptyPi.model)")

    defaults.set("openai-codex/gpt-5.6-terra", forKey: AgentModelConfig.modelKey)
    defaults.set("xhigh", forKey: AgentModelConfig.thinkingKey)
    let overridden = AgentModelConfig.resolvedFromDefaults(harness: .pi, defaults: defaults)
    expect(overridden == .init(model: "openai-codex/gpt-5.6-terra", thinking: "xhigh"),
           "a valid override must win, got \(overridden)")

    // The same stored id under a harness that does not own it is NOT substituted
    // into that harness's argv — it falls back to something that harness can run.
    let foreign = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode, defaults: defaults)
    expect(foreign.model == AgentModelConfig.defaultModel,
           "a stored id owned by another harness must not survive into Claude Code, got \(foreign.model)")

    defaults.set(retired, forKey: AgentModelConfig.modelKey)
    defaults.set("ludicrous", forKey: AgentModelConfig.thinkingKey)
    let rejected = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode, defaults: defaults)
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
    // Pi's Config defaults from PI's catalogue, not from whichever harness settings
    // currently seed. Under strict ownership the ambient harness can be Claude
    // Code, and `anthropic/opus` handed to `pi --model` is a PATTERN — the fuzzy
    // match P0.10 exists to prevent.
    let resolved = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let config = PiAgentRunner.Config(cwd: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
    expect(config.model == resolved.model && config.thinking == resolved.thinking,
           "PiAgentRunner.Config must default from AgentModelConfig under the Pi harness, got model=\(config.model) thinking=\(config.thinking)")
    expect(catalogue.contains(config.model),
           "PiAgentRunner.Config must default to an exact Pi catalogue id, got \(config.model)")

    let argv = PiAgentRunner.processArguments(
        model: config.model, thinking: config.thinking, sessionId: nil, extraArgs: [], prompt: "hi")
    expect(argv.firstIndex(of: "--model").map { argv[$0 + 1] } == resolved.model,
           "the resolved model must reach Pi's argv, got \(argv)")
    expect(argv.firstIndex(of: "--thinking").map { argv[$0 + 1] } == resolved.thinking,
           "the resolved thinking level must reach Pi's argv (an inert picker is the bug), got \(argv)")
    #endif

    print("AgentModelConfig checks passed: default is an exact catalogue id, no ambiguous prefix offered, thinking levels valid, unrecognized values fall back, Settings binds both keys, Config defaults from the resolver and both values reach Pi's argv")
}

// Live catalogue (AgentModelCatalog): the frozen list above became the
// FALLBACK; a bounded `pi --list-models` probe replaces it in the running app
// so newly-authed providers (pi's own /login CLI flow) surface in the picker.
// QA never probes — these checks drive parse/apply with fixtures.
func runAgentModelCatalogChecks() {
    // 1. Parser: real table shape (header + aligned columns), provider/model
    //    fully qualified, pi's order preserved, ANSI styling stripped.
    let fixture = """
    provider      model                context  max-out  thinking  images
    openai-codex  gpt-5.6-sol          272K     128K     yes       yes
    anthropic     claude-fable-5       500K     128K     yes       yes
    \u{1B}[1manthropic\u{1B}[0m     claude-opus-5        500K     128K     yes       yes

    """
    let parsed = AgentModelCatalog.parse(listModelsOutput: fixture)
    expect(parsed == [
        "openai-codex/gpt-5.6-sol",
        "anthropic/claude-fable-5",
        "anthropic/claude-opus-5",
    ], "parse yields fully-qualified ids in pi's order, skipping the header and ANSI styling, got \(parsed)")
    expect(AgentModelCatalog.parse(listModelsOutput: "") == [], "empty output parses to no ids")
    expect(AgentModelCatalog.parse(listModelsOutput: "provider      model    context\n") == [],
           "header alone parses to no ids")

    // 2. Cache semantics: fallback until a NON-EMPTY apply; empty/garbage
    //    applies never blank the picker.
    let catalog = AgentModelCatalog()
    expect(catalog.options(fallback: ["f/one"]) == ["f/one"], "catalog serves the fallback before any apply")
    catalog.apply(listModelsOutput: "")
    expect(catalog.options(fallback: ["f/one"]) == ["f/one"], "an empty probe result must not blank the options")
    catalog.apply(listModelsOutput: fixture)
    expect(catalog.options(fallback: ["f/one"]) == parsed, "a successful probe replaces the fallback")

    // 3. The live catalogue is PI's — `resetForQA(options:)` seeds pi's probe
    //    result — so every assertion here names the Pi harness explicitly. Reading
    //    the ambient `modelOptions` instead made this section depend on the
    //    operator's stored `continuum.agents.backend`: green where it says pi, red
    //    on a machine where the default (Claude Code) stands.
    //
    //    Resolution falls back to the first USABLE model when the default's
    //    provider isn't authed — handing pi an unusable default fails every spawn.
    AgentModelCatalog.shared.resetForQA(options: ["anthropic/claude-fable-5", "anthropic/claude-opus-5"])
    defer { AgentModelCatalog.shared.resetForQA() }
    expect(AgentModelConfig.modelOptions(for: .pi) == ["anthropic/claude-fable-5", "anthropic/claude-opus-5"],
           "Pi's modelOptions reflects the live catalogue")
    let suiteName = "AgentModelCatalogChecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let resolved = AgentModelConfig.resolvedFromDefaults(harness: .pi, defaults: defaults)
    expect(resolved.model == "anthropic/claude-fable-5",
           "when the default model is unavailable, resolution falls back to the first usable id, got \(resolved.model)")
    defaults.set("anthropic/claude-opus-5", forKey: AgentModelConfig.modelKey)
    expect(AgentModelConfig.resolvedFromDefaults(harness: .pi, defaults: defaults).model == "anthropic/claude-opus-5",
           "a stored live-catalogue id wins")
    AgentModelCatalog.shared.resetForQA()
    expect(AgentModelConfig.modelOptions(for: .pi) == AgentModelConfig.fallbackModelOptions,
           "after reset the frozen fallback stands again")

    // 4. Display names from pi's synced models-store: fully-qualified keys,
    //    missing/empty names skipped, unknown ids nil (callers fall back to
    //    the id — the QA state, so no pinned title depends on the store).
    let storeFixture = """
    {
      "openai-codex": {"models": [
        {"id": "gpt-5.3-codex-spark", "name": "GPT-5.3 Codex Spark"},
        {"id": "nameless", "cost": {}}
      ]},
      "anthropic": {"models": [{"id": "claude-fable-5", "name": "Claude Fable 5"}]},
      "broken": "not an object"
    }
    """.data(using: .utf8)!
    let names = AgentModelCatalog.parse(modelsStoreJSON: storeFixture)
    expect(names == [
        "openai-codex/gpt-5.3-codex-spark": "GPT-5.3 Codex Spark",
        "anthropic/claude-fable-5": "Claude Fable 5",
    ], "models-store parse maps provider/id to name, skipping nameless and malformed entries, got \(names)")
    expect(AgentModelCatalog.parse(modelsStoreJSON: Data("garbage".utf8)) == [:],
           "malformed store parses to no names")
    let namedCatalog = AgentModelCatalog()
    expect(namedCatalog.displayName(for: "anthropic/claude-fable-5") == nil,
           "no display names before apply")
    namedCatalog.apply(displayNames: names)
    expect(namedCatalog.displayName(for: "anthropic/claude-fable-5") == "Claude Fable 5",
           "applied display names resolve by fully-qualified id")
    expect(namedCatalog.displayName(for: "anthropic/unknown") == nil,
           "unknown ids resolve to nil so callers fall back to the id")

    // 5. Live-refresh gating: QA-inert by construction (requestRefresh no-ops
    //    unless the real app enabled it), and the throttle decision is pure.
    let gated = AgentModelCatalog()
    expect(gated.requestRefresh(minimumInterval: 0) == false,
           "requestRefresh must no-op before enableLiveRefresh — QA can never spawn a probe")
    expect(AgentModelCatalog.refreshDue(lastStartedAt: nil, minimumInterval: 15, now: Date(timeIntervalSince1970: 100)),
           "a refresh is due when none ran yet")
    expect(!AgentModelCatalog.refreshDue(
        lastStartedAt: Date(timeIntervalSince1970: 90), minimumInterval: 15, now: Date(timeIntervalSince1970: 100)),
        "a refresh inside the minimum interval is throttled")
    expect(AgentModelCatalog.refreshDue(
        lastStartedAt: Date(timeIntervalSince1970: 80), minimumInterval: 15, now: Date(timeIntervalSince1970: 100)),
        "a refresh past the minimum interval is due again")

    print("AgentModelCatalog checks passed: table parse (header/ANSI/order), non-empty-replace semantics, live options drive resolution with first-usable fallback, models-store display names, QA-inert throttled refresh")
}
