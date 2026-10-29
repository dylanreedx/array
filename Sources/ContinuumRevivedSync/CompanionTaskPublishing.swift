import Foundation
import ContinuumRevivedCore
import ContinuumRevivedRelayProtocol

public struct CompanionTaskNotificationContext: Sendable {
    public var supported: Bool
    public var owner: RelayNotificationOwnership?
    public init(supported: Bool, owner: RelayNotificationOwnership?) { self.supported = supported; self.owner = owner }
}

/// Separate from SyncMessage so old phones can keep their inventory protocol.
/// Only a relay explicitly advertising task ownership may receive these batches.
public protocol CompanionTaskPublishingTransport: SyncTransport {
    func taskNotificationContext() async throws -> CompanionTaskNotificationContext
    func publishTaskNotifications(_ snapshot: CompanionTaskSnapshotBatch) async throws
}

public extension CompanionTaskSnapshotBatch {
    var relayTaskBatch: RelayTaskBatch {
        func state(_ source: CompanionTaskRunState) -> RelayTaskState.State {
            switch source {
            case .running: return .running
            case .queued: return .queued
            case .unknown: return .unknown
            case .needsInput: return .needsInput
            case .needsApproval: return .needsApproval
            case .succeeded: return .succeeded
            case .failed: return .failed
            case .cancelled: return .cancelled
            case .interrupted: return .interrupted
            }
        }
        return .init(publisherID: publisherID, revision: revision, tasks: tasks.map { task in
            .init(taskID: task.taskID, rootRunID: task.rootRunID, membershipComplete: task.membershipComplete,
                  members: task.members.map { .init(agentID: $0.agentID, runID: $0.runID, parentRunID: $0.parentRunID,
                                                   state: state($0.state), requestID: $0.requestID) })
        })
    }
}
