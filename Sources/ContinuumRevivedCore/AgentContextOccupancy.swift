import Foundation

/// Turns per-turn provider usage into a context-window OCCUPANCY reading.
///
/// No provider we drive reports occupancy directly, and none reports the window
/// size, so the radial meter had nothing to fill. Both numbers exist, though,
/// and neither is invented here:
///
/// - **Window size** comes from the provider when telemetry states one, and
///   otherwise from pi's published models-store (`contextWindow`). Codex states
///   it in its rollout log (not `exec --json`). Absent both, absent reading —
///   never a fabricated denominator.
/// - **Occupancy** is the prompt on the LAST REQUEST — everything the model had
///   in context at that moment. Per provider, from each translator's measured
///   shape, NOT assumed: claude's `input_tokens` excludes cache, so the cache
///   counters must be added; codex occupancy comes only from the rollout log's
///   per-request `last_token_usage.total_tokens`.
///
/// THE TRAP, paid for THREE times: a cumulative number is not an occupancy.
///
/// - Codex's `turn.completed.usage` totals the whole SESSION — measured at
///   15,005 then 30,026 across two turns of one thread — and drove the meter to
///   237%, a percentage that could only climb.
/// - Claude's `result.usage` sums every API request the RUN made. One agentic
///   turn issues a request per tool round trip and each re-reads the whole
///   conversation from cache, so the summed cache counters are a multiple of
///   anything the model ever held at once. Measured on the committed subagent
///   capture: `result` says 51,671 where the last request's prompt was 26,081.
///   Dylan's meter read 348%.
///
/// Occupancy must come from a per-request figure; anything cumulative belongs to
/// cost accounting. A source named for a turn or a result is accounting until
/// proven otherwise — read what it sums before believing it. Note that the
/// `claudeResultUsage` doc comment already SAID "per-turn aggregate … not
/// occupancy" while this file was summing it anyway.
///
/// This is a last-turn reading for every provider we drive. None of them reports
/// usage mid-turn on the streams we consume (codex's live `token_count` exists
/// only in its own rollout log, not in `codex exec --json`), so the meter moves
/// when a turn ends. Callers present it as such.
public enum AgentContextOccupancy {
    /// The prompt-token total for the observed turn, or nil when the snapshot's
    /// source has no documented occupancy shape.
    public static func promptTokens(from snapshot: AgentContextWindowSnapshot) -> Int? {
        switch snapshot.source {
        case .claudeAssistantUsage, .piMessageUsage:
            // Claude and Pi split the prompt into fresh input, cache reads, and
            // cache writes. Pi's own footer and session stats use this exact
            // arithmetic for `latestPromptTokens`/context usage; output belongs
            // to the response and is not part of the prompt occupancy.
            let parts = [snapshot.inputTokens, snapshot.cacheReadTokens, snapshot.cacheWriteTokens]
                .compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            let total = parts.reduce(0, +)
            return total > 0 ? total : nil
        case .codexRolloutTokenCount:
            guard let used = snapshot.usedTokens, used >= 0 else { return nil }
            return used
        case .codexTurnUsage, .claudeResultUsage:
            // Cumulative accounting, not occupancy — for codex over the whole
            // SESSION, for claude over every API request the run made. Never a
            // denominator's numerator, even when a legacy record already has
            // used/max populated from an older derivation.
            return nil
        case .providerSessionStats, .claudeCompactBoundary:
            // Authoritative occupancy is reported directly when it exists.
            // `compact_boundary.post_tokens` is exactly that: the size of the
            // conversation the NEXT turn will start from, stated by the harness.
            return snapshot.usedTokens
        case .unknown:
            return nil
        }
    }

    /// Fills `usedTokens`/`maxTokens` on a per-turn snapshot so the meter can
    /// render a real percentage. Returns the snapshot unchanged when either
    /// number is unavailable — a missing window size must leave the ring empty,
    /// never produce a fabricated denominator.
    public static func withDerivedOccupancy(
        _ snapshot: AgentContextWindowSnapshot,
        contextWindow: Int?
    ) -> AgentContextWindowSnapshot {
        if snapshot.source == .codexTurnUsage || snapshot.source == .claudeResultUsage {
            var sanitized = snapshot
            sanitized.usedTokens = nil
            sanitized.maxTokens = nil
            return sanitized
        }
        guard snapshot.usedTokens == nil || snapshot.maxTokens == nil else { return snapshot }
        guard let window = contextWindow, window > 0,
              let used = promptTokens(from: snapshot) else { return snapshot }
        var enriched = snapshot
        enriched.usedTokens = used
        enriched.maxTokens = window
        return enriched
    }
}
