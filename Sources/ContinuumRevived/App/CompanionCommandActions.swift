import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

/// What a phone's Stop and Approve do on this Mac. The same seams the agent
/// tile uses: Stop is the composer's Stop (`accept(.stop)`, which interrupts
/// the turn or withdraws a held prompt), never the teardown `stop` that kills
/// the session; Approve is `respondToRequest`, which only answers a request
/// the agent actually has open.
@MainActor
enum CompanionCommandActions {
    static func stop(_ rawAgentID: UUID, supervisor: AgentSupervisor) async -> AgentStopOutcome {
        switch await supervisor.accept(.stop, for: AgentID(rawValue: rawAgentID)) {
        case .accepted: return .stopped
        case .refused(.unknownAgent): return .notFound
        case .refused(.noTurnInProgress): return .notRunning
        case .refused: return .unsupported
        }
    }

    /// The phone's message, as if typed into the agent's composer
    /// (`accept(.send)`), never `sendAgentMessage`. A running turn refuses it
    /// (`busy`): queueing and steering from the phone come once witnessed.
    static func send(_ rawAgentID: UUID, text: String, supervisor: AgentSupervisor) async -> AgentMessageOutcome {
        switch await supervisor.accept(.send(text), for: AgentID(rawValue: rawAgentID)) {
        case .accepted: return .accepted
        case .refused(.unknownAgent): return .notFound
        case .refused(.emptyDraft): return .empty
        case .refused(.turnNotReady): return .busy
        case .refused(.harnessNotReady): return .notReady
        case .refused: return .refused
        }
    }

    static func respond(_ rawAgentID: UUID, requestID: String, decision: ApprovalDecision, supervisor: AgentSupervisor) -> ApprovalRespondResult {
        supervisor.respondToRequest(agentID: AgentID(rawValue: rawAgentID), requestID: requestID, decision: decision) ? .sent : .unknownRequest
    }
}

/// The phone's approval seam over the supervisor.
final class CompanionSupervisorApprovals: ApprovalResponding, @unchecked Sendable {
    // Only touched on the main actor.
    private weak var supervisor: AgentSupervisor?
    init(supervisor: AgentSupervisor) { self.supervisor = supervisor }
    func respond(agentId: UUID, requestId: String, decision: ApprovalDecision) async -> ApprovalRespondResult {
        await MainActor.run {
            guard let supervisor else { return .unknownRequest }
            return CompanionCommandActions.respond(agentId, requestID: requestId, decision: decision, supervisor: supervisor)
        }
    }
}
