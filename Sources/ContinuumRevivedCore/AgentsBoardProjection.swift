import ContinuumRevivedAgentUI
import Foundation

// Ticket P1.8 removed `AgentStatusPresentation` and the `presentation` field
// that rode on this row. It carried a stringly-typed `colorToken` ("blue",
// "teal", "tertiaryLabel") that each consumer re-interpreted in its own private
// switch — which is precisely how `configuring` ended up teal on the board and
// purple in the tile. A row's appearance is a pure function of its `status`, so
// consumers now call `StatusChipPresenter.display(for: row.status)` and the
// second channel that could disagree with the first no longer exists.
// P2A.8: a row's identity is its AGENT (`id == agentId`), not the tile that happens
// to render it. `tileId` is the optional view hint — `nil` for a headless agent, whose
// row still shows on the phone; only "Show on canvas" needs it.
public struct AgentsBoardRow: Equatable, Sendable, Identifiable {
    public var id: UUID { agentId }
    public let agentId: UUID
    public let tileId: UUID?
    public let status: AgentStatus
    public let lastSummary: String
    public let recent: [AgentActivityEvent]
    public let updatedAt: Date
    /// P2B.3: project / zone / title / model, joined from `AgentContextIndex`.
    /// OPTIONAL, and defaulted, so every existing construction site (including
    /// the iOS one) keeps compiling and a consumer that has no index still gets
    /// rows. nil means "not joined", never "the agent has no context".
    public let context: AgentRowContext?

    public var terminalOutcome: AgentTerminalOutcome? {
        recent.last(where: { $0.terminalOutcome != nil })?.terminalOutcome
    }

    public init(
        agentId: UUID,
        tileId: UUID? = nil,
        status: AgentStatus,
        lastSummary: String,
        recent: [AgentActivityEvent],
        updatedAt: Date,
        context: AgentRowContext? = nil
    ) {
        self.agentId = agentId
        self.tileId = tileId
        self.status = status
        self.lastSummary = lastSummary
        self.recent = recent
        self.updatedAt = updatedAt
        self.context = context
    }
}

// Addressed by agent, because the approval belongs to the agent: a tile-addressed
// response could not answer a headless agent's request at all.
public struct ApprovalResponseTarget: Equatable, Sendable {
    public let agentId: UUID
    public let approvalRequestId: String

    public init(agentId: UUID, approvalRequestId: String) {
        self.agentId = agentId
        self.approvalRequestId = approvalRequestId
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P2B.7-incremental-refresh.md
//
// WHAT MOVED, so a list can update the rows that moved instead of reloading all
// of them. Named by AGENT identity, the key a row is identified by
// (`AgentsBoardRow.id == agentId`).
public struct AgentsBoardChangeSet: Equatable, Sendable {
    /// Agents with no row before and a row now.
    public let added: Set<UUID>
    /// Agents whose row is different — see `AgentsBoardProjection.changeSet(from:to:)`
    /// for what "different" means, which is narrower than `AgentActivity` equality.
    public let updated: Set<UUID>
    /// Agents that had a row and have none now.
    public let removed: Set<UUID>

    public static let empty = AgentsBoardChangeSet(added: [], updated: [], removed: [])

    public init(added: Set<UUID>, updated: Set<UUID>, removed: Set<UUID>) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }

    /// Every agent named, whichever way it moved.
    public var touched: Set<UUID> { added.union(updated).union(removed) }
}

public enum AgentsBoardProjection {
    /// `context` is keyed by agent identity, the same key `snapshot.byAgent` uses
    /// (see `AgentContextIndex.build`). Defaulted to empty so a caller with no
    /// index — the phone, a fixture — projects exactly the rows it did before.
    public static func rows(
        from snapshot: ActivityLogSnapshot,
        context: [UUID: AgentRowContext] = [:]
    ) -> [AgentsBoardRow] {
        snapshot.byAgent.map { agentId, activity in
            AgentsBoardRow(
                agentId: agentId,
                tileId: activity.tileId,
                status: activity.status,
                lastSummary: activity.lastSummary,
                recent: activity.recent,
                updatedAt: activity.updatedAt,
                context: context[agentId]
            )
        }
        .sorted(by: attentionFirst)
    }

    public static func applyEvent(_ event: AgentActivityEvent, to snapshot: ActivityLogSnapshot) -> ActivityLogSnapshot {
        apply(snapshot, event)
    }

    /// P2B.7: fold a locally-produced draft into a snapshot the host is already
    /// holding, WITHOUT rebuilding that snapshot from disk.
    ///
    /// The sequence is `snapshot.snapshotSequence + 1`, which is the whole
    /// correctness argument: the fold derives an agent's status / summary /
    /// updatedAt / tile hint from its canonically-LAST event, so a locally
    /// observed event has to sort after everything already folded or it would be
    /// ingested and then ignored. `AgentInventory.snapshot` numbers events
    /// positionally from a total order over its whole input, so a draft stamped
    /// with "one more than the highest sequence in the snapshot" cannot collide
    /// with a number that fold has used, and a later full rebuild renumbers
    /// everything anyway.
    ///
    /// Still ORDER-INDEPENDENT in the sense that matters: `apply` is a merge on
    /// `(sequence, replicaId)`, not an overwrite, so folding a foreign event that
    /// arrives afterwards with a HIGHER sequence still wins.
    public static func appendLocal(
        _ draft: AgentActivityEventDraft,
        to snapshot: ActivityLogSnapshot,
        replicaId: UUID
    ) -> ActivityLogSnapshot {
        apply(snapshot, AgentActivityEvent(
            stamping: draft,
            sequence: snapshot.snapshotSequence + 1,
            replicaId: replicaId
        ))
    }

    /// P2B.7: which agents' rows differ between two snapshots.
    ///
    /// "Differ" is the fields a ROW carries out of `AgentActivity` — status,
    /// summary, updatedAt, tile hint — plus a renumbering-invariant witness of its
    /// event ring, and deliberately NOT `AgentActivity` equality. Sequence numbers
    /// are assigned POSITIONALLY by `AgentInventory.snapshot`, so one agent
    /// appearing shifts every later-sorting agent's numbers: an equality diff would
    /// report the entire board as updated every time a single agent was created,
    /// which is precisely the "reload everything" this ticket removes. Context
    /// (P2B.3) is joined after the snapshot and is therefore not visible here.
    ///
    /// The ring witness is count + newest kind + OLDEST timestamp, from the
    /// cross-review: `recent` is capped at 200, so at the cap a new event evicts the
    /// oldest one and the count stops moving. The oldest survivor's clock is what
    /// still moves there, and neither it nor the kind is touched by renumbering.
    public static func changeSet(
        from old: ActivityLogSnapshot,
        to new: ActivityLogSnapshot
    ) -> AgentsBoardChangeSet {
        func rowFields(_ activity: AgentActivity) -> [String] {
            [
                activity.status.rawValue,
                activity.lastSummary,
                String(activity.updatedAt.timeIntervalSinceReferenceDate),
                activity.tileId?.uuidString ?? "-",
                String(activity.recent.count),
                activity.recent.last?.kind ?? "-",
                activity.recent.first.map { String($0.occurredAt.timeIntervalSinceReferenceDate) } ?? "-",
            ]
        }

        var added: Set<UUID> = []
        var updated: Set<UUID> = []
        for (agentId, activity) in new.byAgent {
            guard let before = old.byAgent[agentId] else {
                added.insert(agentId)
                continue
            }
            if rowFields(before) != rowFields(activity) { updated.insert(agentId) }
        }
        let removed = Set(old.byAgent.keys).subtracting(new.byAgent.keys)
        return AgentsBoardChangeSet(added: added, updated: updated, removed: removed)
    }

    public static func timelineEvents(for activity: AgentActivity) -> [AgentActivityEvent] {
        Array(activity.recent.reversed())
    }

    public static func latestPendingAttentionEvent(in activity: AgentActivity) -> AgentActivityEvent? {
        activity.recent.last { $0.status == .needsAttention || $0.tone == .approval }
    }

    public static func approvalsInboxRows(from snapshot: ActivityLogSnapshot) -> [AgentsBoardRow] {
        rows(from: snapshot).filter { $0.status == .needsAttention }
    }

    public static func attentionCount(from snapshot: ActivityLogSnapshot) -> Int {
        approvalsInboxRows(from: snapshot).count
    }

    public static func respondableRequest(in activity: AgentActivity) -> ApprovalResponseTarget? {
        guard let event = latestPendingAttentionEvent(in: activity),
              event.status == .needsAttention,
              let approvalRequestId = event.approvalRequestId else {
            return nil
        }
        return ApprovalResponseTarget(agentId: event.agentId, approvalRequestId: approvalRequestId)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.2-five-states-three-colours.md
    //
    /// WHICH of the two things the agent wants from you, or nil if it wants
    /// nothing — the fact `AgentStatus.needsAttention` cannot carry, and the one
    /// input `AgentInboxRow.state(for:pending:)` needs beyond a status.
    ///
    /// Read off the ring's CANONICALLY-LAST event, which is the same element
    /// `apply` derives `AgentActivity.status` from (`recent` is kept in
    /// `(sequence, replicaId)` order, so `last` is that winner). Two consequences,
    /// both deliberate:
    ///
    ///   * Anything recorded AFTER a request means the agent moved on and nobody
    ///     is blocked — the interrupted run in `runInboxRowElapsedCheck`
    ///     (`working → needs-attention → working`) is a working agent, not a
    ///     waiting one. This is where it differs from `respondableRequest`, which
    ///     scans BACK past later events to find something to answer; that is the
    ///     right rule for "can this be responded to" and the wrong one for "is
    ///     this agent waiting on you right now".
    ///   * Reading the same element as the fold makes this consistent with the
    ///     status by construction rather than a second opinion that can contradict
    ///     it: nil exactly when the status is not `needsAttention`. The value it
    ///     ADDS is the split — the presence of the adapter's request id, something
    ///     to approve versus a plain question, which the status cannot express.
    ///
    /// Takes the ring rather than an `AgentActivity` because the inbox join holds
    /// an `AgentsBoardRow`.
    public static func pendingRequest(in events: [AgentActivityEvent]) -> PendingRequest? {
        guard let newest = events.last, newest.status == .needsAttention else { return nil }
        return newest.approvalRequestId == nil ? .input : .approval
    }

    public static func priority(for status: AgentStatus) -> Int {
        switch status {
        case .needsAttention:
            0
        case .working:
            1
        case .configuring, .idle, .done, .stale:
            2
        }
    }

    private static func attentionFirst(_ lhs: AgentsBoardRow, _ rhs: AgentsBoardRow) -> Bool {
        let leftPriority = priority(for: lhs.status)
        let rightPriority = priority(for: rhs.status)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.agentId.uuidString < rhs.agentId.uuidString
    }
}
