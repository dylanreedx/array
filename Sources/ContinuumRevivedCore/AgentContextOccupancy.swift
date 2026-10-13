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
/// Every provider we drive reports a per-request figure mid-turn: claude's
/// `message_start` (the request's full prompt, at the moment it is sent), codex
/// app-server's `thread/tokenUsage/updated.last`, pi's `message_end`. The meter
/// moves with each request, not once per turn. `AgentContextMeter` owns the
/// reading; this type only answers "how many prompt tokens does this snapshot
/// state".
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

/// The ONE owner of an agent's context-meter reading (T1, `.plans/69`). The
/// supervisor folds every provider snapshot and compaction lifecycle event
/// through here and hands the tile the result; the tile renders it and looks
/// nothing up.
///
/// The reading is the prompt of the LATEST request over a window. Three ways it
/// went wrong before this owned it, each a snapshot REPLACING the reading:
/// a settings-only snapshot (pi and codex send their auto-compaction policy at
/// every turn start) blanked the ring, the next usage snapshot dropped the
/// policy tick, and a cumulative result block painted the run's sum.
public enum AgentContextMeter {
    /// The prompt tokens a snapshot states for its request, or nil when it
    /// states none. Cumulative accounting never counts, even when an older
    /// derivation left used/max on it.
    public static func promptTokens(of snapshot: AgentContextWindowSnapshot) -> Int? {
        switch snapshot.source {
        case .codexTurnUsage, .claudeResultUsage:
            return nil
        default:
            if let prompt = AgentContextOccupancy.promptTokens(from: snapshot) { return prompt }
            guard let used = snapshot.usedTokens, used >= 0 else { return nil }
            return used
        }
    }

    /// The reading after one provider snapshot. `window` is the resolved
    /// denominator (provider-stated first, then pi's models-store); nil leaves
    /// the reading a bare prompt-token count, never a guessed percentage.
    ///
    /// A snapshot that states prompt tokens becomes the reading. One that does
    /// not (settings, accounting) merges into it: the reading stands, and only
    /// the fields the snapshot actually carries move. Policy, auto-compaction
    /// and cost are merged in both cases, so neither kind erases the other's.
    public static func reading(
        after incoming: AgentContextWindowSnapshot,
        current: AgentContextWindowSnapshot?,
        window: Int?
    ) -> AgentContextWindowSnapshot {
        var next: AgentContextWindowSnapshot
        if let prompt = promptTokens(of: incoming) {
            next = incoming
            next.usedTokens = prompt
            next.maxTokens = window
            next.compacting = current?.compacting
        } else if var carried = current {
            carried.maxTokens = window ?? carried.maxTokens
            next = carried
        } else {
            next = incoming
            next.usedTokens = nil
            next.maxTokens = window
        }
        next.automaticCompactionPolicy = incoming.automaticCompactionPolicy ?? current?.automaticCompactionPolicy
        next.automaticCompaction = incoming.automaticCompaction ?? current?.automaticCompaction
        if incoming.totalCostUsd != nil || incoming.totalProcessedTokens != nil {
            next.totalCostUsd = incoming.totalCostUsd
            next.costBasis = incoming.costBasis
            next.totalProcessedTokens = incoming.totalProcessedTokens
        } else {
            next.totalCostUsd = current?.totalCostUsd
            next.costBasis = current?.costBasis
            next.totalProcessedTokens = current?.totalProcessedTokens
        }
        return next
    }

    /// The reading after a compaction lifecycle event, or nil when it does not
    /// change. Running keeps the last reading, dimmed; success makes the
    /// boundary's `after` the reading (marked when the provider only estimated
    /// it), or clears it when the provider reported none — the pre-compaction
    /// number is no longer true; a failure only lifts the dimming.
    public static func reading(
        after lifecycle: AgentCompactionLifecycleEvent,
        current: AgentContextWindowSnapshot?,
        window: Int?
    ) -> AgentContextWindowSnapshot? {
        switch lifecycle.phase {
        case .requested, .running:
            guard var next = current, next.compacting != true else { return nil }
            next.compacting = true
            return next
        case .failed, .cancelled, .indeterminate:
            guard var next = current, next.compacting == true else { return nil }
            next.compacting = nil
            return next
        case .succeeded:
            var next = current ?? AgentContextWindowSnapshot(
                observedAt: lifecycle.observedAt, source: .unknown("compaction"), freshness: .live)
            next.compacting = nil
            next.usedTokens = lifecycle.afterTokens?.value
            next.usedTokensEstimated = lifecycle.afterTokens?.precision == .estimated ? true : nil
            next.maxTokens = window ?? next.maxTokens
            next.inputTokens = nil
            next.outputTokens = nil
            next.cacheReadTokens = nil
            next.cacheWriteTokens = nil
            next.source = lifecycle.provider == "claude" ? .claudeCompactBoundary : .unknown("compaction")
            next.observedAt = lifecycle.observedAt
            next.freshness = .live
            switch lifecycle.trigger {
            case .manual: next.automaticCompaction = false
            case .providerAutomatic, .threshold, .overflowRecovery: next.automaticCompaction = true
            case .unknown: break
            }
            return next
        }
    }
}
