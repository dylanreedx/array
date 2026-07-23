import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md (slice 88.4c)
//
// The bridge from the RICH observation stream a managed-agent tile ingests
// (AgentRuntimeEvent) to the I5-safe activity log that crosses to the phone
// (AgentActivityEventDraft). Pure + total so it can be pinned in the matrix.
//
// It deliberately DROPS streaming content deltas: they are high-frequency and
// carry assistant/reasoning text, which must never become an activity summary
// (I5 forbids transcript bodies at the sync boundary). What crosses is the
// SHAPE of what the agent is doing — turn boundaries, tool names, approvals,
// errors — plus the derived status the tile already computes.
public enum ManagedAgentActivityBridge {
    /// Cap on how many recent drafts we keep per tile before publishing. The
    /// phone's fold caps `recent` at 200; this keeps the wire payload bounded.
    public static let recentCap = 100

    /// Map one runtime event to a syncable activity draft, or nil for events
    /// that should not appear on the timeline (streaming deltas, token usage).
    /// `status` is the tile's current derived status at ingest time.
    public static func draft(
        for event: AgentRuntimeEvent,
        tileId: UUID,
        status: AgentStatus,
        now: Date
    ) -> AgentActivityEventDraft? {
        switch event {
        case .turnStarted:
            return make(tileId, .info, "turn.started", status, "Turn started", now)
        case .turnCompleted(_, _, let outcome, let errorMessage):
            switch outcome {
            case .completed:
                return make(tileId, .info, "turn.completed", status, "Turn complete", now)
            case .failed:
                return make(tileId, .error, "turn.failed", status, short(errorMessage ?? "Turn failed"), now)
            case .interrupted, .cancelled:
                return make(tileId, .info, "turn.\(outcome.rawValue)", status, "Turn \(outcome.rawValue)", now)
            }
        case .itemStarted(_, _, let kind, let title):
            let name = title ?? kind.rawValue
            return make(tileId, tone(for: kind), "tool.\(name)", status, "Started \(name)", now)
        case .itemCompleted(_, _, let kind, let itemStatus):
            let tone: ActivityEventTone = (itemStatus == .failed) ? .error : .tool
            return make(tileId, tone, "tool.\(itemStatus.rawValue)", status, "\(kind.rawValue) \(itemStatus.rawValue)", now)
        case .requestOpened(_, let requestId, let kind):
            return make(tileId, .approval, "approval.\(kind.rawValue)", status, "Needs approval", now, approvalRequestId: requestId)
        case .requestResolved(_, let requestId, let decision):
            return make(tileId, .approval, "approval.resolved", status, "Approval \(decision)", now, approvalRequestId: requestId)
        case .runtimeError(_, let message):
            return make(tileId, .error, "error", status, short(message), now)
        case .sessionStateChanged, .contentDelta, .userInputRequested, .userInputResolved, .tokenUsageUpdated:
            // Status changes ride on the other events' `status` field; content
            // deltas / token usage never cross (I5 + noise).
            return nil
        }
    }

    private static func tone(for kind: ItemKind) -> ActivityEventTone {
        switch kind {
        case .error: return .error
        default: return .tool
        }
    }

    private static func short(_ s: String) -> String {
        s.count <= 200 ? s : String(s.prefix(200))
    }

    private static func make(
        _ tileId: UUID, _ tone: ActivityEventTone, _ kind: String,
        _ status: AgentStatus, _ summary: String, _ now: Date,
        approvalRequestId: String? = nil
    ) -> AgentActivityEventDraft {
        AgentActivityEventDraft(
            tileId: tileId, runId: nil, tone: tone, kind: kind,
            status: status, summary: summary, occurredAt: now,
            approvalRequestId: approvalRequestId
        )
    }
}
