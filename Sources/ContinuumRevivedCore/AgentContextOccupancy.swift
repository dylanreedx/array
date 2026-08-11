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
/// THE TRAP, paid for twice: a cumulative number is not an occupancy. Codex's
/// `turn.completed.usage` totals the whole SESSION — measured at 15,005 then
/// 30,026 across two turns of one thread — and using it drove the meter to 237%,
/// a percentage that could only climb. Occupancy must come from a per-request
/// figure; anything cumulative belongs to cost accounting.
///
/// This is a last-turn reading for every provider we drive. None of them reports
/// usage mid-turn on the streams we consume (codex's live `token_count` exists
/// only in its own rollout log, not in `codex exec --json`), so the meter moves
/// when a turn ends. Callers present it as such.
public enum AgentContextOccupancy {
    /// The prompt-token total for the observed turn, or nil when the snapshot's
    /// source has no documented occupancy shape (pi's per-message usage does not
    /// state whether `input` already includes cache, so it is left alone rather
    /// than guessed at).
    public static func promptTokens(from snapshot: AgentContextWindowSnapshot) -> Int? {
        switch snapshot.source {
        case .claudeResultUsage:
            // claude's usage splits the prompt: fresh input, cache reads, and
            // cache writes are disjoint parts of the same request.
            let parts = [snapshot.inputTokens, snapshot.cacheReadTokens, snapshot.cacheWriteTokens]
                .compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            let total = parts.reduce(0, +)
            return total > 0 ? total : nil
        case .codexRolloutTokenCount:
            guard let used = snapshot.usedTokens, used >= 0 else { return nil }
            return used
        case .codexTurnUsage:
            // `turn.completed.usage` is session-cumulative accounting. It is
            // never context occupancy, even when a legacy record already has
            // used/max populated from an older derivation.
            return nil
        case .providerSessionStats:
            // Authoritative occupancy is reported directly when it exists.
            return snapshot.usedTokens
        case .piMessageUsage, .unknown:
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
        if snapshot.source == .codexTurnUsage {
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
