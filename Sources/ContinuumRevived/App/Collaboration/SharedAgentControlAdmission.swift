import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

@MainActor
struct SharedAgentControlGate {
    let validate: @MainActor (Collaboration.AgentDispatchCommand?) async -> Bool
    let rememberQueued: @MainActor (UUID, Collaboration.AgentDispatchCommand) throws -> Void
    let queuedCommand: @MainActor (UUID) throws -> Collaboration.AgentDispatchCommand?
}

struct SharedAgentControlAdmission {
    let scope: String
    let command: Collaboration.AgentDispatchCommand
}
