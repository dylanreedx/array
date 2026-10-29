import Foundation
import ContinuumRevivedRelayProtocol
import ContinuumRevivedRelayCore

private struct TaskFailure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws { if !value { throw TaskFailure(message: message) } }

func runTaskPolicyChecks(instance: UUID) throws -> Set<RelayNotificationPath> {
    let root = UUID(), child = UUID(), grandchild = UUID(), task = UUID()
    let rootAgent = UUID(), childAgent = UUID()
    func snapshot(_ states: [RelayTaskState.State], complete: Bool = true) -> RelayTaskState {
        .init(taskID: task, rootRunID: root, membershipComplete: complete, members: [
            .init(agentID: rootAgent, runID: root, state: states[0]),
            .init(agentID: childAgent, runID: child, parentRunID: root, state: states[1], requestID: "request"),
            .init(agentID: UUID(), runID: grandchild, parentRunID: child, state: states[2]),
        ])
    }
    func evaluate(_ value: RelayTaskState) throws -> RelayNotificationDecision {
        RelaySystemSurfaceProjection.evaluate(event: .init(kind: "task.state.v1", payload: try JSONEncoder().encode(value)), instanceID: instance)
    }
    var paths = Set<RelayNotificationPath>()
    let scenarios: [([RelayTaskState.State], Bool, RelayNotificationPath, Bool)] = [
        ([.succeeded, .running, .succeeded], true, .taskActive, false),
        ([.succeeded, .succeeded, .queued], true, .taskActive, false),
        ([.running, .succeeded, .succeeded], true, .taskActive, false),
        ([.succeeded, .unknown, .succeeded], true, .taskUnknown, false),
        ([.succeeded, .succeeded, .succeeded], false, .taskUnknown, false),
        ([.running, .needsApproval, .running], true, .taskAttention, true),
        ([.running, .needsInput, .running], true, .taskAttention, true),
        ([.running, .failed, .succeeded], true, .taskActive, false),
        ([.succeeded, .failed, .succeeded], true, .taskFailure, true),
        ([.succeeded, .succeeded, .succeeded], true, .taskCompletion, true),
        ([.cancelled, .succeeded, .succeeded], true, .taskCancelled, false),
        ([.interrupted, .succeeded, .succeeded], true, .taskCancelled, false),
        ([.succeeded, .cancelled, .succeeded], true, .taskUnknown, false),
    ]
    for (states, complete, expected, alert) in scenarios {
        let result = try evaluate(snapshot(states, complete: complete))
        try check(result.path == expected, "task \(states) must follow \(expected.rawValue), got \(result.path.rawValue)")
        try check((result.projection?.notification != nil) == alert, "task alert/silence must follow policy")
        if expected == .taskAttention { try check(result.projection?.agentID == childAgent, "attention must target actual child blocker") }
        if expected == .taskActive || expected == .taskUnknown { try check(result.projection?.terminal == false, "unsettled task must not end Live Activity") }
        paths.insert(result.path)
    }
    var invalid = snapshot([.succeeded, .succeeded, .succeeded])
    invalid.members[1].parentRunID = grandchild
    try check(try evaluate(invalid).path == .invalidTask, "cycle must fail closed")
    invalid.members[1].parentRunID = UUID()
    try check(try evaluate(invalid).path == .invalidTask, "missing parent must fail closed")
    invalid.members[1].runID = root
    try check(try evaluate(invalid).path == .invalidTask, "duplicate run must fail closed")
    invalid = snapshot([.running, .needsInput, .running]); invalid.members[1].requestID = nil
    try check(try evaluate(invalid).path == .invalidTask, "attention must have stable request identity")
    paths.insert(.invalidTask)
    let finished = snapshot([.succeeded, .succeeded, .succeeded])
    let identity = try evaluate(finished).projection?.notificationIdentity
    var reordered = finished; reordered.members.reverse()
    try check(try evaluate(reordered).projection?.notificationIdentity == identity, "reordering must not create new completion")
    var nextTask = finished; nextTask.taskID = UUID()
    try check(try evaluate(nextTask).projection?.notificationIdentity != identity, "new task on reused agents must remain eligible")
    print("Task policy checks passed: task/run graph, grandchildren/queued blockers, unknown membership, child attention, cancellation, stable task identity")
    return paths
}
