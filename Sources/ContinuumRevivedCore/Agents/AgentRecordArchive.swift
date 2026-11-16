import Foundation

// Performance at scale, item 4: the agent store held 2,478 records on
// 2026-11-15, most of them helpers that finished days ago and have no tile.
// Boot decoded every one and every per-agent walk (the sidebar's row build
// among them) paid for it: 83 ms per row build with all of them, 11 ms with the
// 321 that are not old, finished and tile-less (debug build). An ARCHIVED
// record lives in `agents/archive/` instead — `loadAll` lists one level, so
// boot never reads it — and comes back, by id, the moment anything asks for it.

/// The gate. On by default: a person who never wrote the setting archives.
/// Writing `false` turns it off and brings every archived record back. A
/// supervisor with no settings wired (a bare one in a check) stays off.
public enum AgentRecordArchiveConfig {
    public static let enabledKey = "agents.recordArchive.enabled"
    /// Seven days: past the week a delivered helper-completion row is kept
    /// for a lookup (`AgentSupervisor.deliveredRowRetention`).
    public static let idleThreshold: TimeInterval = 7 * 86_400

    public static func enabled(defaults: UserDefaults?) -> Bool {
        guard let defaults else { return false }
        return defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// What one record says about itself. The supervisor adds what only it knows:
/// a running process, a queue, a parent's subscription or undelivered
/// completion, an unfinished child.
public enum AgentRecordArchivePolicy {
    public static func recordAllowsArchive(_ record: AgentRecord, now: Date,
                                           idleThreshold: TimeInterval = AgentRecordArchiveConfig.idleThreshold) -> Bool {
        // A tile on any canvas finds its agent by `tileId`; an archived record
        // would leave that tile unbound.
        guard record.tileId == nil, !record.pinned, record.helperTileOpenedAt == nil else { return false }
        // A Terminal face or another app may still own the session.
        guard record.externalSession == nil else { return false }
        // Finished: no turn started after the last one ended.
        if let turnAt = record.latestTurnAt {
            let ended = record.latestTerminalEvent?.endedAt ?? record.runCompletedAt ?? .distantPast
            guard ended >= turnAt else { return false }
        }
        if let phase = record.inFlightCompaction?.phase {
            guard phase == .succeeded || phase == .failed || phase == .cancelled else { return false }
        }
        // Things a person asked to see again.
        if let until = record.snoozedUntil, until > now { return false }
        guard record.settledOverride != .active, record.declaredStatus?.needsYou == nil else { return false }
        if record.parentAgentID == nil, record.isUnread { return false }
        let stamps: [Date?] = [record.lastActivityAt, record.latestPromptAt, record.latestTurnAt,
            record.runCompletedAt, record.failedAt, record.latestTerminalEvent?.endedAt, record.lastVisitedAt,
            record.settledAt, record.archivedAt, record.closeRequestedAt, record.lastReport?.filedAt]
        let latest = stamps.compactMap { $0 }.max() ?? record.createdAt
        return now.timeIntervalSince(max(latest, record.createdAt)) > idleThreshold
    }
}
