import Foundation

/// Host-authored membership for one user task. An agent's lifetime parent is
/// insufficient: each participating run is explicitly attached to this task.
public struct RelayTaskState: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, queued, unknown, needsInput, needsApproval
        case succeeded, failed, cancelled, interrupted
    }
    public struct Member: Codable, Sendable {
        public var agentID: UUID
        public var runID: UUID
        public var parentRunID: UUID?
        public var state: State
        public var requestID: String?
        public init(agentID: UUID, runID: UUID, parentRunID: UUID? = nil, state: State, requestID: String? = nil) {
            self.agentID = agentID; self.runID = runID; self.parentRunID = parentRunID
            self.state = state; self.requestID = requestID
        }
    }
    public var version: Int
    public var taskID: UUID
    public var rootRunID: UUID
    /// True only when the host knows the complete participating run set.
    public var membershipComplete: Bool
    public var members: [Member]
    public init(taskID: UUID, rootRunID: UUID, membershipComplete: Bool, members: [Member], version: Int = 1) {
        self.version = version; self.taskID = taskID; self.rootRunID = rootRunID
        self.membershipComplete = membershipComplete; self.members = members
    }
}
