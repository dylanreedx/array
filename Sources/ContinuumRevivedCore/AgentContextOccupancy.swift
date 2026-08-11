import Foundation

/// Turns per-turn provider usage into a context-window OCCUPANCY reading.
///
/// No provider we drive reports occupancy directly, and none reports the window
/// size, so the radial meter had nothing to fill. Both numbers exist, though,
/// and neither is invented here:
///
/// - **Window size** comes from the PROVIDER first when it says (codex reports
///   `model_context_window`, 258,400 for gpt-5.6-sol), and otherwise from pi's
///   published models-store (`contextWindow`, which says 272,000 for the same
///   model). The provider running the turn is the authority on its own window.
///   Absent both, absent reading.
/// - **Occupancy** is the prompt on the LAST REQUEST — everything the model had
///   in context at that moment. Per provider, from each translator's documented
///   shape, NOT assumed: claude's `input_tokens` excludes cache, so the cache
///   counters must be added; codex publishes a per-request block of its own.
///
/// THE TRAP, paid for once: a cumulative number is not an occupancy. Codex's
/// `turn.completed.usage` totals the whole SESSION, and using it drove the meter
/// to 237% — a percentage that only ever climbs. Occupancy must come from a
/// per-request reading, and anything cumulative belongs to cost accounting.
///
/// Liveness differs by provider: codex emits `token_count` repeatedly DURING a
/// turn, so its reading moves as the agent works. claude reports at turn end,
/// so its reading is last-turn. Callers present what they have.
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
        case .codexTurnUsage:
            // ONLY a per-request reading counts here. `token_count` sets
            // `usedTokens` from codex's `last_token_usage`; `turn.completed.usage`
            // carries the SESSION CUMULATIVE totals and sets no `usedTokens` at
            // all, so it correctly answers nil rather than offering a number that
            // grows without bound.
            //
            // This used to return `inputTokens`, on the true-but-irrelevant
            // grounds that codex does not split cache out of it. The number is
            // right about cache and wrong about scope: it is the whole session
            // added up, so the meter read 237% of a 272,000-token window off
            // 643,673 cumulative input.
            guard let used = snapshot.usedTokens, used > 0 else { return nil }
            return used
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
        guard snapshot.usedTokens == nil || snapshot.maxTokens == nil else { return snapshot }
        guard let window = contextWindow, window > 0,
              let used = promptTokens(from: snapshot) else { return snapshot }
        var enriched = snapshot
        enriched.usedTokens = used
        enriched.maxTokens = window
        return enriched
    }
}
