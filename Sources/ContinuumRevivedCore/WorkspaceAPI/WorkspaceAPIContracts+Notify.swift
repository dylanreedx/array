import Foundation

// MARK: - agent.notify

/// An agent tells the user it needs them, or that it is done. The caller is the
/// only subject: the host derives its task and run, so there is no target, no
/// recipient and no device in the request. Both reasons go through the task
/// policy (`docs/internals/notification-paths.md`, NOTIFY-*), never around it.
public struct AgentNotifyRequest: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// "I need you": the run waits as needsInput until its next turn.
        case needsInput = "needs_input"
        /// "This is done": announced by the task's own completion, not here.
        case completed
    }
    public static let messageLimit = 500

    public var reason: Reason
    /// What the agent needs or did, for its own transcript. It is not sent to
    /// the relay and never reaches the lock screen.
    public var message: String
    public var idempotencyKey: String?

    public init(reason: Reason, message: String, idempotencyKey: String? = nil) {
        self.reason = reason
        self.message = message
        self.idempotencyKey = idempotencyKey
    }
}

public struct AgentNotifyResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The task now needs the user; the policy may alert once.
        case recorded
        /// Folded into something already recorded; no new alert.
        case coalesced
        /// Nothing was recorded (no tracked task for this agent).
        case unavailable
    }
    /// Whether an alert can reach a phone at all, as of the last publication.
    public enum PhoneDelivery: String, Codable, Sendable {
        /// A phone is paired and the relay applies task alerts.
        case taskAlerts
        case noPairedPhone
        /// The relay predates task alerts, so it ignores this request.
        case relayWithoutTaskAlerts
        /// Not yet known (no publication since launch).
        case unknown
    }

    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var agentId: AgentID
    public var reason: AgentNotifyRequest.Reason
    public var outcome: Outcome
    public var phoneDelivery: PhoneDelivery
    /// One sentence the agent can repeat to the user as-is.
    public var explanation: String

    public init(operationId: String, agentId: AgentID, reason: AgentNotifyRequest.Reason,
                outcome: Outcome, phoneDelivery: PhoneDelivery, explanation: String) {
        self.operationId = operationId
        self.agentId = agentId
        self.reason = reason
        self.outcome = outcome
        self.phoneDelivery = phoneDelivery
        self.explanation = explanation
    }
}
