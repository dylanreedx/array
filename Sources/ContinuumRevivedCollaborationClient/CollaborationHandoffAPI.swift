import Foundation
import ContinuumRevivedCollaborationProtocol

extension CollaborationAPI {
    public func registerAgentHost(area: UUID, request value: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState {
        try await request("POST", "areas/\(area)/agent-hosts", body: value)
    }
    public func agentControl(area: UUID, object: UUID) async throws -> Collaboration.AgentControlState {
        try await request("GET", "areas/\(area)/agents/\(object)/control", body: Optional<Int>.none)
    }
    public func changeAgentControl(area: UUID, object: UUID, request value: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState {
        try await request("POST", "areas/\(area)/agents/\(object)/control", body: value)
    }
    public func sendAgentPrompt(area: UUID, object: UUID, request value: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt {
        try await request("POST", "areas/\(area)/agents/\(object)/prompts", body: value)
    }
    public func agentDispatchReceipt(area: UUID, id: UUID) async throws -> Collaboration.AgentDispatchReceipt {
        try await request("GET", "areas/\(area)/agent-commands/\(id)", body: Optional<Int>.none)
    }
    public func pendingAgentDispatches(area: UUID, host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] {
        try await request("GET", "areas/\(area)/agent-hosts/\(host)/commands", body: Optional<Int>.none)
    }
    public func claimAgentDispatch(area: UUID, id: UUID, claim: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
        try await request("POST", "areas/\(area)/agent-commands/\(id)/claim", body: claim)
    }
    public func admitAgentDispatch(area: UUID, id: UUID, claim: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt {
        try await request("POST", "areas/\(area)/agent-commands/\(id)/admit", body: claim)
    }
    public func finishAgentDispatch(area: UUID, id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt {
        try await request("POST", "areas/\(area)/agent-commands/\(id)/outcome", body: outcome)
    }
}
