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
