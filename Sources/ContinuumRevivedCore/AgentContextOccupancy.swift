import Foundation

/// Turns per-turn provider usage into a context-window OCCUPANCY reading.
///
/// No provider we drive reports occupancy directly, and none reports the window
/// size, so the radial meter had nothing to fill. Both numbers exist, though,
/// and neither is invented here:
///
/// - **Window size** comes from pi's published models-store (`contextWindow`),
///   the same file the display names come from. Absent store, absent reading.
/// - **Occupancy** is the prompt actually sent on the last turn — everything the
///   model had in context at that moment. The composition differs per provider
///   and is taken from each translator's documented shape, NOT assumed:
///   claude's `input_tokens` excludes cache, so the cache counters must be added;
///   codex's `input_tokens` is already the total and must NOT be summed again.
///
/// This is a last-turn reading, not a live one: it is accurate as of the most
/// recent completed turn and does not move while a turn is in flight. Callers
/// present it as such.
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
            // codex's input_tokens is ALREADY the total prompt; cached_input_tokens
            // is a subset of it (see CodexEventTranslator). Summing double-counts.
            guard let input = snapshot.inputTokens, input > 0 else { return nil }
            return input
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
