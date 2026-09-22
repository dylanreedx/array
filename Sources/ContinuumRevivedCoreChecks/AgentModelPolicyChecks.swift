import ContinuumRevivedCore
import Foundation

// Two model-catalogue policies Dylan asked for on 2026-09-21, asserted as
// BEHAVIOUR over the served snapshots rather than as strings in source:
//
//   A. The Claude harness offers EXPLICIT model ids, including previous models.
//      Never an alias, never the word "latest".
//   B. The Pi harness never offers an anthropic model.
//
// A previous witness in this repo asserted that the app's SOURCE contained a
// string and stayed green while a reviewer inverted the behaviour it claimed to
// guard (CLAUDE.md, non-negotiable #2). So everything below drives the real
// seams: `AgentModelCatalog.snapshot(for:)` for what a harness serves, and
// `apply(listModelsOutput:)` — production's only writer of pi's live options —
// for the exclusion.
func runAgentModelPolicyChecks() {
    // MARK: A · the claude harness serves explicit ids only

    // The curated list is what `snapshot(for: .claudeCode)` serves on a fresh
    // instance, and also what a successful probe applies
    // (`apply(claudeBackendAvailable: true)`). Assert the SNAPSHOT, both ways.
    let fresh = AgentModelCatalog()
    let probed = AgentModelCatalog()
    probed.apply(claudeBackendAvailable: true)

    for (label, catalog) in [("fallback", fresh), ("after a successful probe", probed)] {
        let snapshot = catalog.snapshot(for: .claudeCode)
        expect(!snapshot.models.isEmpty,
               "claude-policy (\(label)): the claude harness must offer at least one model")

        for id in snapshot.models {
            // Fully qualified, and the tail is a CONCRETE model name, not one of
            // claude's moving aliases. `claude --help` documents `--model` as
            // taking "an alias for the latest model (e.g. 'fable', 'opus', or
            // 'sonnet') or a model's full name (e.g. 'claude-fable-5')" — so the
            // shape that distinguishes them is the `claude-` prefix on a full
            // name. An alias is a bare family word.
            let parts = id.split(separator: "/", omittingEmptySubsequences: false)
            expect(parts.count == 2 && parts[0] == "anthropic" && !parts[1].isEmpty,
                   "claude-policy (\(label)): every claude id must be anthropic/<model>, got \(id)")
            let argument = ClaudeCLIBackend.modelArgument(forCatalogId: id)
            expect(argument == String(parts[1]),
                   "claude-policy (\(label)): modelArgument must strip only the provider prefix, got \(argument) for \(id)")
            expect(argument.hasPrefix("claude-"),
                   "claude-policy (\(label)): \(argument) is an ALIAS, not a model's full name — `claude --model` would resolve it to whatever ships next, and it is not a key in the context-window map")
            expect(argument.contains(where: \.isNumber),
                   "claude-policy (\(label)): \(argument) names no model version — an unversioned name is an alias by another spelling")
            expect(!id.lowercased().contains("latest"),
                   "claude-policy (\(label)): no offered id may say 'latest', got \(id)")
            expect(AgentHarnessConfig.isProviderCompatible(model: id, harness: .claudeCode),
                   "claude-policy (\(label)): \(id) is not a model the claude harness owns")
        }

        for id in snapshot.models {
            guard let name = snapshot.displayNames[id] else {
                expect(false, "claude-policy (\(label)): \(id) is offered with no display name")
                continue
            }
            expect(!name.lowercased().contains("latest"),
                   "claude-policy (\(label)): the label for \(id) says 'latest' (\(name)) — a label that renames itself is the bug")
        }
        expect(Set(snapshot.models).count == snapshot.models.count,
               "claude-policy (\(label)): the claude catalogue must not repeat an id")
    }

    // PREVIOUS models are the half of the request that a "newest only" list
    // would silently drop. Assert that more than one generation is reachable.
    let offered = fresh.snapshot(for: .claudeCode).models
    expect(offered.contains("anthropic/claude-opus-5") && offered.contains("anthropic/claude-opus-4-5"),
           "claude-policy: previous models must stay selectable alongside the newest, got \(offered)")
    expect(offered.first == "anthropic/claude-opus-5",
           "claude-policy: the newest model must lead the list, got \(String(describing: offered.first))")

    // The seed for a new agent is one of those explicit ids.
    expect(offered.contains(AgentModelConfig.defaultModel),
           "claude-policy: defaultModel must be an id the claude harness actually offers, got \(AgentModelConfig.defaultModel)")

    // MARK: B · the pi harness never offers anthropic

    // A realistic `pi --list-models` reading (probed 2026-09-21 on a machine
    // authed for both providers), verbatim. The anthropic rows are the point.
    let listModels = """
    provider      model                       context  max-out  thinking  images
    anthropic     claude-fable-5              1M       128K     yes       yes
    anthropic     claude-fable-5-1            1M       128K     yes       yes
    anthropic     claude-haiku-4-5            200K     64K      yes       yes
    anthropic     claude-opus-4-5             200K     64K      yes       yes
    anthropic     claude-opus-5               1M       128K     yes       yes
    anthropic     claude-sonnet-4-5           1M       64K      yes       yes
    openai-codex  gpt-5.6-sol                 272K     128K     yes       yes
    openai-codex  gpt-5.6-luna                272K     128K     yes       yes
    openai-codex  gpt-5.3-codex-spark         272K     128K     yes       no
    """

    // Positive control: the parser itself still reads pi's table honestly, so a
    // zero-anthropic result below cannot be a parse failure wearing a costume.
    let parsed = AgentModelCatalog.parse(listModelsOutput: listModels)
    expect(parsed.filter { AgentHarnessConfig.provider(forID: $0) == "anthropic" }.count == 6,
           "pi-policy: the fixture must carry six anthropic rows THROUGH the parser, or the exclusion witnesses nothing — got \(parsed)")

    let piCatalog = AgentModelCatalog()
    piCatalog.apply(listModelsOutput: listModels)
    let piModels = piCatalog.snapshot(for: .pi).models
    expect(piModels.allSatisfy { AgentHarnessConfig.provider(forID: $0) != "anthropic" },
           "pi-policy: the Pi snapshot offered an anthropic model, got \(piModels)")
    expect(piModels == ["openai-codex/gpt-5.6-sol", "openai-codex/gpt-5.6-luna", "openai-codex/gpt-5.3-codex-spark"],
           "pi-policy: every non-anthropic row must survive, in pi's own order, got \(piModels)")
    expect(piModels.allSatisfy { AgentHarnessConfig.isProviderCompatible(model: $0, harness: .pi) },
           "pi-policy: Pi must own everything it offers, got \(piModels)")

    // The frozen fallback obeys the same rule (it is what QA and an unprobed app
    // serve), and so does the ownership predicate the pickers filter with.
    expect(AgentModelConfig.fallbackModelOptions.allSatisfy { !PiCatalogPolicy.excludes($0) },
           "pi-policy: the frozen Pi fallback must not contain an excluded provider")
    expect(!AgentHarnessConfig.isProviderCompatible(model: "anthropic/claude-opus-5", harness: .pi),
           "pi-policy: Pi must not own an anthropic id")
    expect(AgentHarnessConfig.isProviderCompatible(model: "anthropic/claude-opus-5", harness: .claudeCode),
           "pi-policy: anthropic ids still belong to the claude harness")
    expect(AgentHarnessConfig.isProviderCompatible(model: "google/gemini-3", harness: .pi),
           "pi-policy: Pi must keep every other provider")

    // An anthropic-only pi reading must NOT blank the picker: the guard is
    // `parsed.isEmpty` after the filter, so the previous options stand.
    let survivor = AgentModelCatalog()
    survivor.apply(listModelsOutput: listModels)
    survivor.apply(listModelsOutput: "provider  model  context\nanthropic  claude-opus-5  1M\n")
    expect(survivor.snapshot(for: .pi).models == piModels,
           "pi-policy: a reading that is entirely excluded must leave the previous options standing, not blank the picker, got \(survivor.snapshot(for: .pi).models)")

    // MARK: B' · a record already persisted on anthropic-under-Pi keeps running

    // The exclusion is an OFFERING policy. Pi can still speak anthropic, so a
    // record that ran fine yesterday must not start refusing every prompt — and
    // per CLAUDE.md it must not be silently re-pointed at another CLI either.
    expect(PiCatalogPolicy.isRetiredSelection(model: "anthropic/claude-opus-5", harness: .pi),
           "pi-policy: an anthropic model under Pi must read as a retired selection, not an impossible one")
    expect(!PiCatalogPolicy.isRetiredSelection(model: "openai-codex/gpt-5.6-sol", harness: .pi),
           "pi-policy: a model Pi still offers is not a retired selection")
    expect(!PiCatalogPolicy.isRetiredSelection(model: "anthropic/claude-opus-5", harness: .claudeCode),
           "pi-policy: the carve-out is Pi's alone — it must not excuse a model another harness truly cannot run")

    // And the legacy-harness rescue reaches the harness that owns the provider,
    // now that Pi no longer does.
    expect(LegacyAgentHarnessMigration.resolve(
        evidence: .init(hasCodexThread: false, hasClaudeConversation: true, hasPiSession: false),
        storedPreference: .pi) == .claudeCode,
        "pi-policy: a claude conversation must still resolve to the claude harness")

    print("agent model policy checks passed: the claude harness serves explicit versioned ids with no alias and no 'latest' label, previous models stay selectable, and a real pi --list-models reading loses every anthropic row while keeping the rest in order")
}
