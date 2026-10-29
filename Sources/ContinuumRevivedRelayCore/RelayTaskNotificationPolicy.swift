import Foundation
import Crypto
import ContinuumRevivedRelayProtocol

extension RelaySystemSurfaceProjection {
    /// The authenticated host supplies task membership; the relay validates the
    /// graph and applies policy. It never infers membership from UI ordering.
    static func evaluateTask(event: RelayEvent, instanceID: UUID) -> RelayNotificationDecision {
        guard let task = try? JSONDecoder().decode(RelayTaskState.self, from: event.payload),
              task.version == 1, !task.members.isEmpty, task.members.count <= 1000 else {
            return .init(path: .invalidTask, projection: nil)
        }
        let runs = Dictionary(task.members.map { ($0.runID, $0) }, uniquingKeysWith: { a, _ in a })
        guard runs.count == task.members.count, let root = runs[task.rootRunID], root.parentRunID == nil else {
            return .init(path: .invalidTask, projection: nil)
        }
        for member in task.members {
            var visited = Set<UUID>(); var current = member
            while current.runID != root.runID {
                guard visited.insert(current.runID).inserted,
                      let parent = current.parentRunID.flatMap({ runs[$0] }) else {
                    return .init(path: .invalidTask, projection: nil)
                }
                current = parent
            }
            if member.state == .needsInput || member.state == .needsApproval {
                guard let request = member.requestID, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      request.utf8.count <= 200 else { return .init(path: .invalidTask, projection: nil) }
            }
        }
        let ordered = task.members.sorted { $0.runID.uuidString < $1.runID.uuidString }
        let attention = ordered.first { $0.state == .needsApproval } ?? ordered.first { $0.state == .needsInput }
        let active = task.members.filter { $0.state == .running || $0.state == .queued }.count
        let path: RelayNotificationPath
        var target = root
        var fields: [String: Any] = ["agentId": root.agentID.uuidString, "status": "working"]
        if let attention {
            path = .taskAttention; target = attention
            fields = ["agentId": attention.agentID.uuidString, "status": "needsAttention"]
            if attention.state == .needsApproval { fields["approvalRequestId"] = attention.requestID }
        } else if !task.membershipComplete || task.members.contains(where: { $0.state == .unknown }) {
            path = .taskUnknown
        } else if active > 0 {
            path = .taskActive
        } else if root.state == .cancelled || root.state == .interrupted {
            path = .taskCancelled
            fields["status"] = "done"; fields["terminalOutcome"] = root.state.rawValue
        } else if task.members.contains(where: { $0.state == .failed }) {
            path = .taskFailure
            fields["status"] = "done"; fields["terminalOutcome"] = "failed"
        } else if task.members.allSatisfy({ $0.state == .succeeded }) {
            path = .taskCompletion
            fields["status"] = "done"; fields["terminalOutcome"] = "succeeded"
        } else {
            // A cancelled child is not evidence that the objective succeeded.
            path = .taskUnknown
        }
        let payload = (try? JSONSerialization.data(withJSONObject: ["activity": ["event": fields]])) ?? Data()
        guard var projection = evaluate(event: .init(kind: "sync.message", payload: payload), instanceID: instanceID).projection else {
            return .init(path: .invalidTask, projection: nil)
        }
        projection.runningCount = active
        projection.notificationTaskID = task.taskID
        projection.attentionCount = task.members.filter { $0.state == .needsApproval || $0.state == .needsInput }.count
        let identity = [task.taskID.uuidString, target.runID.uuidString, path.rawValue, target.requestID ?? ""].joined(separator: "|")
        projection.notificationIdentity = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if projection.notification != nil {
            projection.notification?.path = path
            projection.notification?.taskID = task.taskID
            projection.notification?.runID = target.runID
            projection.notification?.instanceID = instanceID
            projection.notification?.collapseID = "array-task-\(task.taskID.uuidString)"
            if path == .taskCompletion { projection.notification?.title = "Task finished" }
            if path == .taskFailure { projection.notification?.title = "Task failed" }
        }
        return .init(path: path, projection: projection)
    }
}
