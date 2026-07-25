import ContinuumRevivedAgentUI
import Foundation

public struct AgentStatusPresentation: Equatable, Sendable {
    public let glyph: String
    public let colorToken: String

    public init(glyph: String, colorToken: String) {
        self.glyph = glyph
        self.colorToken = colorToken
    }
}

public struct AgentsBoardRow: Equatable, Sendable, Identifiable {
    public var id: UUID { tileId }
    public let tileId: UUID
    public let status: AgentStatus
    public let lastSummary: String
    public let recent: [AgentActivityEvent]
    public let updatedAt: Date
    public let presentation: AgentStatusPresentation

    public init(
        tileId: UUID,
        status: AgentStatus,
        lastSummary: String,
        recent: [AgentActivityEvent],
        updatedAt: Date,
        presentation: AgentStatusPresentation
    ) {
        self.tileId = tileId
        self.status = status
        self.lastSummary = lastSummary
        self.recent = recent
        self.updatedAt = updatedAt
        self.presentation = presentation
    }
}

public struct ApprovalResponseTarget: Equatable, Sendable {
    public let tileId: UUID
    public let approvalRequestId: String

    public init(tileId: UUID, approvalRequestId: String) {
        self.tileId = tileId
        self.approvalRequestId = approvalRequestId
    }
}

public enum AgentsBoardProjection {
    public static func rows(from snapshot: ActivityLogSnapshot) -> [AgentsBoardRow] {
        snapshot.byTile.map { tileId, activity in
            AgentsBoardRow(
                tileId: tileId,
                status: activity.status,
                lastSummary: activity.lastSummary,
                recent: activity.recent,
                updatedAt: activity.updatedAt,
                presentation: presentation(for: activity.status)
            )
        }
        .sorted(by: attentionFirst)
    }

    public static func applyEvent(_ event: AgentActivityEvent, to snapshot: ActivityLogSnapshot) -> ActivityLogSnapshot {
        apply(snapshot, event)
    }

    public static func timelineEvents(for activity: TileActivity) -> [AgentActivityEvent] {
        Array(activity.recent.reversed())
    }

    public static func latestPendingAttentionEvent(in activity: TileActivity) -> AgentActivityEvent? {
        activity.recent.last { $0.status == .needsAttention || $0.tone == .approval }
    }

    public static func approvalsInboxRows(from snapshot: ActivityLogSnapshot) -> [AgentsBoardRow] {
        rows(from: snapshot).filter { $0.status == .needsAttention }
    }

    public static func attentionCount(from snapshot: ActivityLogSnapshot) -> Int {
        approvalsInboxRows(from: snapshot).count
    }

    public static func respondableRequest(in activity: TileActivity) -> ApprovalResponseTarget? {
        guard let event = latestPendingAttentionEvent(in: activity),
              event.status == .needsAttention,
              let approvalRequestId = event.approvalRequestId else {
            return nil
        }
        return ApprovalResponseTarget(tileId: event.tileId, approvalRequestId: approvalRequestId)
    }

    public static func presentation(for status: AgentStatus) -> AgentStatusPresentation {
        switch status {
        case .working:
            AgentStatusPresentation(glyph: "●", colorToken: "blue")
        case .needsAttention:
            AgentStatusPresentation(glyph: "◆", colorToken: "orange")
        case .done:
            AgentStatusPresentation(glyph: "✓", colorToken: "green")
        case .stale:
            AgentStatusPresentation(glyph: "◌", colorToken: "gray")
        case .configuring:
            AgentStatusPresentation(glyph: "◍", colorToken: "teal")
        case .idle:
            AgentStatusPresentation(glyph: "○", colorToken: "tertiaryLabel")
        }
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
        return lhs.tileId.uuidString < rhs.tileId.uuidString
    }
}
