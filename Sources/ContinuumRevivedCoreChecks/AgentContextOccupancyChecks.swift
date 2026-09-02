import ContinuumRevivedCore
import Foundation

/// Pins the context-occupancy derivation that lets the radial meter show a real
/// percentage. The per-provider composition is the load-bearing part: claude
/// splits its prompt across input + cache counters, as does Pi; codex's
/// per-request `usedTokens` is already the total.
func runAgentContextOccupancyChecks() {
    let observedAt = Date(timeIntervalSince1970: 1_786_000_000)

    func snapshot(
        source: AgentContextWindowTelemetrySource,
        input: Int? = nil,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil,
        used: Int? = nil,
        max: Int? = nil
    ) -> AgentContextWindowSnapshot {
        AgentContextWindowSnapshot(
            usedTokens: used,
            maxTokens: max,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalProcessedTokens: (input ?? 0) + (output ?? 0),
            observedAt: observedAt,
            source: source,
            freshness: .live)
    }

    // claude: the prompt is input + cache read + cache write, read off ONE API
    // response — an `assistant` frame. Output is NOT part of the occupancy of
    // the request that just ran.
    let claude = snapshot(source: .claudeAssistantUsage, input: 1_200, output: 900, cacheRead: 40_000, cacheWrite: 800)
    expect(AgentContextOccupancy.promptTokens(from: claude) == 42_000,
           "claude occupancy must sum input + cache read + cache write, got \(String(describing: AgentContextOccupancy.promptTokens(from: claude)))")

    // THE 348% REGRESSION, and the reason this assertion used to name the wrong
    // source. `result.usage` sums every API request the RUN made — an agentic
    // turn issues one per tool round trip, each re-reading the whole
    // conversation from cache — so it is cost accounting wearing occupancy's
    // clothes, exactly like codex's `turn.completed.usage` below. This very
    // check pinned it as the claude occupancy source for four releases.
    let claudeRunSum = snapshot(source: .claudeResultUsage, input: 4, output: 330,
                                cacheRead: 42_081, cacheWrite: 9_586)
    expect(AgentContextOccupancy.promptTokens(from: claudeRunSum) == nil,
           "a claude result block has no occupancy — it is every request of the run added up, got \(String(describing: AgentContextOccupancy.promptTokens(from: claudeRunSum)))")
    let claudeNotEnriched = AgentContextOccupancy.withDerivedOccupancy(claudeRunSum, contextWindow: 200_000)
    expect(claudeNotEnriched.usedTokens == nil && claudeNotEnriched.maxTokens == nil,
           "…and it must not be enriched into one: that is the 348% reading, got \(String(describing: claudeNotEnriched.usedTokens))/\(String(describing: claudeNotEnriched.maxTokens))")

    // codex: ONLY a per-request reading counts. `token_count` sets `usedTokens`
    // from `last_token_usage`; that is the occupancy.
    let codex = snapshot(source: .codexRolloutTokenCount, input: 73_176, output: 1_203,
                         cacheRead: 70_400, used: 74_379, max: 258_400)
    expect(AgentContextOccupancy.promptTokens(from: codex) == 74_379,
           "codex occupancy is its per-request total, got \(String(describing: AgentContextOccupancy.promptTokens(from: codex)))")

    // THE 237% REGRESSION, with the exact numbers that produced it. A
    // `turn.completed.usage` block carries the session CUMULATIVE totals and no
    // `usedTokens`; deriving occupancy from its `inputTokens` divided 643,673 by
    // a 272,000 window and painted 237%. It must answer nil instead, and must
    // not be enriched into a fake reading either.
    let codexCumulative = snapshot(source: .codexTurnUsage, input: 643_673, output: 3_938,
                                   cacheRead: 557_824)
    expect(AgentContextOccupancy.promptTokens(from: codexCumulative) == nil,
           "a cumulative codex block has no occupancy — it is the whole session added up, got \(String(describing: AgentContextOccupancy.promptTokens(from: codexCumulative)))")
    let notEnriched = AgentContextOccupancy.withDerivedOccupancy(codexCumulative, contextWindow: 272_000)
    expect(notEnriched.usedTokens == nil && notEnriched.maxTokens == nil,
           "…and it must not be enriched into one: that is the 237% reading, got \(String(describing: notEnriched.usedTokens))/\(String(describing: notEnriched.maxTokens))")
    let persistedLegacy = snapshot(source: .codexTurnUsage, input: 4_160_000,
                                   used: 4_160_000, max: 272_000)
    let sanitizedLegacy = AgentContextOccupancy.withDerivedOccupancy(persistedLegacy, contextWindow: 272_000)
    expect(sanitizedLegacy.usedTokens == nil && sanitizedLegacy.maxTokens == nil,
           "a persisted legacy Codex used/max pair must be actively sanitized")

    // A window already ON the snapshot wins over the catalogue's — the process
    // running the turn is the authority on its own limit. No stream we consume
    // states one today (codex's `model_context_window` is in its rollout log,
    // not in `codex exec --json`), so this guards the seam rather than a live
    // path: the day a translator does report a window, the catalogue must not
    // overwrite it.
    let providerWindow = AgentContextOccupancy.withDerivedOccupancy(codex, contextWindow: 272_000)
    expect(providerWindow.maxTokens == 258_400,
           "a window the provider reported must not be overwritten by the catalogue's, got \(String(describing: providerWindow.maxTokens))")

    // Pi's own footer computes `latestPromptTokens` as input + cacheRead +
    // cacheWrite. Pin the Luna-shaped case that used to render an empty solid
    // ring (and, after restore, an empty dashed ring with a cumulative count).
    let pi = snapshot(
        source: .piMessageUsage,
        input: 3_742,
        output: 812,
        cacheRead: 161_280,
        cacheWrite: 1_024)
    expect(AgentContextOccupancy.promptTokens(from: pi) == 166_046,
           "pi occupancy must use input + cache read + cache write, got \(String(describing: AgentContextOccupancy.promptTokens(from: pi)))")
    let piLuna = AgentContextOccupancy.withDerivedOccupancy(pi, contextWindow: 272_000)
    expect(piLuna.usedTokens == 166_046 && piLuna.maxTokens == 272_000,
           "Pi GPT-5.6 Luna must derive a real occupancy pair, got \(String(describing: piLuna.usedTokens))/\(String(describing: piLuna.maxTokens))")

    // Enrichment needs BOTH a derivable occupancy and a published window.
    let enriched = AgentContextOccupancy.withDerivedOccupancy(claude, contextWindow: 200_000)
    expect(enriched.usedTokens == 42_000 && enriched.maxTokens == 200_000,
           "a derivable snapshot plus a published window must fill used/max, got \(String(describing: enriched.usedTokens))/\(String(describing: enriched.maxTokens))")

    // No window on file: the snapshot is untouched. A fabricated denominator is
    // exactly what this must never produce.
    let noWindow = AgentContextOccupancy.withDerivedOccupancy(claude, contextWindow: nil)
    expect(noWindow.usedTokens == nil && noWindow.maxTokens == nil,
           "without a published context window the snapshot must stay underived")
    let zeroWindow = AgentContextOccupancy.withDerivedOccupancy(claude, contextWindow: 0)
    expect(zeroWindow.maxTokens == nil,
           "a zero/invalid window must be rejected, not used as a denominator")

    // An authoritative snapshot that already carries used/max is never rewritten.
    let authoritative = snapshot(source: .providerSessionStats, used: 10, max: 100)
    let untouched = AgentContextOccupancy.withDerivedOccupancy(authoritative, contextWindow: 999)
    expect(untouched.usedTokens == 10 && untouched.maxTokens == 100,
           "an already-complete authoritative snapshot must not be overwritten")

    // The models-store parse reads the provider's published contextWindow, and
    // must NOT confuse it with maxTokens (max output per response).
    let storeJSON = Data("""
    {"anthropic":{"models":[{"id":"claude-opus-4-6","name":"Opus","contextWindow":1000000,"maxTokens":128000}]},
     "openai-codex":{"models":[{"id":"gpt-5.6","name":"GPT","contextWindow":272000,"maxTokens":128000},
                               {"id":"no-window","name":"NW"}]}}
    """.utf8)
    let windows = AgentModelCatalog.parse(modelsStoreContextWindows: storeJSON)
    expect(windows["anthropic/claude-opus-4-6"] == 1_000_000,
           "models-store parse must read contextWindow for a fully-qualified id, got \(String(describing: windows["anthropic/claude-opus-4-6"]))")
    expect(windows["openai-codex/gpt-5.6"] == 272_000,
           "models-store parse must cover every provider in the store")
    expect(windows["openai-codex/no-window"] == nil,
           "a model without a published contextWindow must be absent, not defaulted")
    expect(AgentModelCatalog.parse(modelsStoreContextWindows: Data("not json".utf8)).isEmpty,
           "an unreadable store must parse to no windows rather than throwing or inventing")

    print("AgentContextOccupancy checks passed: per-provider prompt composition (claude/pi sum cache, codex uses per-request occupancy), Pi Luna regression, enrichment only with a published window, authoritative snapshots preserved, and models-store contextWindow parsing")
}
