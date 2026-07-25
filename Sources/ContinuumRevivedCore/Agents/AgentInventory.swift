import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2B.1-agent-inventory.md
//
// ONE DERIVATION OF "EVERY AGENT", NOT FOUR.
//
// The union of terminal sessions and managed agents existed in exactly one
// place, momentarily, inside the companion-sync closure:
// `DegradedDesktopActivitySnapshotSource.snapshot(...)` in
// `ContinuumRevivedSync`. The sidebar, the badges, the dock and the phone each
// re-derived their own version of it. This is that fold promoted to an
// app-lifetime value in Core, where the desktop can read it too — a PROMOTION,
// not a rewrite: `DegradedDesktopActivitySnapshotSource` is now a thin caller.
// Stated precisely, because the stronger version of this claim is not proven:
// `DesktopCompanionSyncPublisherTests` was deliberately NOT touched and still
// pins the companion payload's keys, statuses, summaries, tile hints, timeline
// order and I5 sweep — that is field-level equivalence on the fixtures it
// covers, not a byte-diff against the old implementation, which no longer
// exists to diff against.
//
// It folds with the EXISTING `apply(_:_:)` from `AgentActivityEvent.swift`.
// A second fold here would be a second definition of canonical order, and the
// phone folds the same events with the first one.
//
// I5 (sync-boundary purity): `ActivityLogSnapshot` crosses to the phone, and
// `AgentRecord` is host-bound (`cwd`, `worktreeBranch`). This function reads
// only `id`, `displayName`, `tileId` and `lastActivityAt` off a record —
// never a host path. `AgentInventoryChecks` witnesses that with the taint
// scanner over a record whose cwd and branch are deliberately distinctive.
public enum AgentInventory {
    /// Fold every agent the desktop knows about — terminal sessions and
    /// `AgentRecord`-backed agents, tiled or headless — into the one snapshot
    /// every consumer reads.
    ///
    /// `liveStatuses` is keyed by AGGREGATE IDENTITY, i.e. the same key
    /// `AgentActivityEvent.agentId` carries: `AgentRecord.id.rawValue` for an
    /// agent, and a terminal session's `tileId` (whose tile id IS its agent
    /// identity — it has no `AgentRecord`; see the note at the terminal loop).
    /// One keyspace, so a collision means the same agent, not two.
    public static func snapshot(
        terminalDescriptors: [TerminalSessionDescriptor],
        liveStatuses: [UUID: AgentStatus],
        agents: [AgentRecord],
        activityByAgent: [AgentID: [AgentActivityEventDraft]],
        replicaId: UUID,
        now: Date
    ) -> ActivityLogSnapshot {
        var snapshot = ActivityLogSnapshot.empty

        // Sequence numbers are assigned POSITIONALLY from a total order over the
        // input, not from a counter that happens to run in call order: the phone
        // folds on `(sequence, replicaId)`, so a non-deterministic assignment
        // would reorder its timeline between two publishes of identical state.
        let sortedDescriptors = terminalDescriptors.sorted { lhs, rhs in
            lhs.tileId.uuidString == rhs.tileId.uuidString
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.tileId.uuidString < rhs.tileId.uuidString
        }
        for (offset, descriptor) in sortedDescriptors.enumerated() {
            let kind = descriptor.agentDescriptor?.agentKind ?? .shell
            let status = liveStatuses[descriptor.tileId] ?? descriptor.agentDescriptor?.status ?? .idle
            let event = AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    // A terminal session has no AgentRecord, so its tile id IS its
                    // agent identity here — the same equality P2A.8's legacy decode
                    // relies on. The tile hint is that same id, so "Show on canvas"
                    // keeps working for these rows.
                    agentId: descriptor.tileId,
                    tileId: descriptor.tileId,
                    runId: nil,
                    tone: status == .needsAttention ? .approval : .info,
                    kind: "desktop.degradedStatus",
                    status: status,
                    summary: safeSummary(name: displayName(for: kind), status: status),
                    occurredAt: descriptor.agentDescriptor?.statusUpdatedAt ?? now
                ),
                sequence: UInt64(offset + 1),
                replicaId: replicaId
            )
            snapshot = apply(snapshot, event)
        }

        var sequence = UInt64(sortedDescriptors.count)
        // Sorted by identity, NOT by `AgentStore.isOrderedBefore` (most-recent
        // first): that order moves whenever an agent does anything, which would
        // renumber unrelated agents' events on the next publish.
        let sortedAgents = agents.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        for record in sortedAgents {
            // `record.tileId == nil` is a HEADLESS agent (P2A.6). It needs no
            // special case — the tile is only ever the optional view hint here,
            // never the key — which is the whole point of P2A.8's migration.
            let recorded = activityByAgent[record.id] ?? []
            // Prefer the agent's real timeline; fall back to a single synthetic
            // status event when no events have been recorded yet.
            let drafts: [AgentActivityEventDraft] = recorded.isEmpty
                ? [syntheticStatusDraft(for: record, liveStatuses: liveStatuses)]
                // The record is the CURRENT view binding; a recorded draft carries
                // the binding it had when it was recorded. Publishing the draft's
                // would let an agent that has since detached keep advertising a
                // tile — the phone's "Show on canvas" pointing at a tile that no
                // longer renders it, which is exactly the identity-is-the-view bug
                // P2A.6/P2A.8 removed. Rebind, do not inherit.
                : recorded.map { rebound($0, toTile: record.tileId) }
            for draft in drafts {
                sequence += 1
                snapshot = apply(snapshot, AgentActivityEvent(stamping: draft, sequence: sequence, replicaId: replicaId))
            }
        }
        return snapshot
    }

    private static func rebound(_ draft: AgentActivityEventDraft, toTile tileId: UUID?) -> AgentActivityEventDraft {
        guard draft.tileId != tileId else { return draft }
        return AgentActivityEventDraft(
            agentId: draft.agentId,
            tileId: tileId,
            runId: draft.runId,
            tone: draft.tone,
            kind: draft.kind,
            status: draft.status,
            summary: draft.summary,
            occurredAt: draft.occurredAt,
            approvalRequestId: draft.approvalRequestId
        )
    }

    private static func syntheticStatusDraft(
        for record: AgentRecord,
        liveStatuses: [UUID: AgentStatus]
    ) -> AgentActivityEventDraft {
        let status = liveStatuses[record.id.rawValue] ?? .idle
        return AgentActivityEventDraft(
            agentId: record.id.rawValue,
            tileId: record.tileId,
            runId: nil,
            tone: status == .needsAttention ? .approval : .info,
            kind: "desktop.managedStatus",
            status: status,
            // `displayName` only — no cwd, no branch, no path (I5).
            summary: safeSummary(name: record.displayName, status: status),
            occurredAt: record.lastActivityAt
        )
    }

    /// A summary that is a LABEL, never a transcript body (I5, enforced at
    /// `AgentActivityEvent`).
    public static func safeSummary(name: String, status: AgentStatus) -> String {
        "\(name) \(displayName(for: status))"
    }

    public static func displayName(for kind: AgentKind) -> String {
        switch kind {
        case .shell: "Shell"
        case .claude: "Claude"
        case .codex: "Codex"
        case .pi: "Pi"
        case .managed: "Managed agent"
        case .unknown: "Agent"
        }
    }

    public static func displayName(for status: AgentStatus) -> String {
        switch status {
        case .configuring: "configuring"
        case .working: "working"
        case .idle: "idle"
        case .needsAttention: "needs attention"
        case .done: "done"
        case .stale: "stale"
        }
    }
}
