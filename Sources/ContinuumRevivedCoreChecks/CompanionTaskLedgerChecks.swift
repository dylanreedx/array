import Foundation
import ContinuumRevivedCore

private struct TaskLedgerCheckFailure: Error { let message: String }
private func taskExpect(_ condition: Bool, _ message: String) throws { if !condition { throw TaskLedgerCheckFailure(message: message) } }

func runCompanionTaskLedgerChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-ledger-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    let agent = UUID(), childAgent = UUID()
    let a = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "private/thread/path", turnId: "a"), run: a)
    let child = try ledger.begin(agentID: childAgent, parent: a)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "child"), run: child)
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "a", outcome: .completed, errorMessage: nil), run: a)
    let b = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "b"), run: b)
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "child", outcome: .completed, errorMessage: nil), run: child)
    let two = try ledger.snapshot()
    try taskExpect(a.taskID != b.taskID && two.tasks.first { $0.taskID == b.taskID }?.members.first?.state == .running,
                   "old child terminal must not complete a reused parent's new task")
    let observed = try ledger.adoptObserved(agentID: UUID(), parent: a, sourceID: "parent/tool-use-1")
    let repeated = try ledger.adoptObserved(agentID: UUID(), parent: b, sourceID: "parent/tool-use-1")
    try taskExpect(observed == repeated && observed.taskID == a.taskID, "provider child replay must retain original run membership")
    let item = UUID()
    let queued = try ledger.reserveQueued(agentID: agent, itemID: item)
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "b", outcome: .completed, errorMessage: nil), run: b)
    try taskExpect(try ledger.snapshot().tasks.first { $0.taskID == b.taskID }?.membershipComplete == false,
                   "unfinished admission barrier must prevent completion")
    try ledger.resolveQueuedReservation(queued, accepted: true)
    let adopted = try ledger.begin(agentID: agent, queuedID: item)
    try taskExpect(adopted == queued && adopted.taskID == b.taskID, "durable work item must retain parent task when drained")
    try ledger.observe(.turnStarted(threadId: "private", turnId: "queued"), run: adopted)
    let beforeStale = ledger.revision
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "late-old-a", outcome: .completed, errorMessage: nil), run: adopted)
    try taskExpect(try ledger.revision == beforeStale && (ledger.snapshot().tasks.first { $0.taskID == b.taskID }?.members.first { $0.runID == adopted.runID }?.state) == .running,
                   "mismatched provider turn must leave current run unchanged")
    let c = try ledger.begin(agentID: agent)
    let cancelledItem = UUID(), reserved = try ledger.reserveQueued(agentID: agent, itemID: cancelledItem)
    try ledger.resolveQueuedReservation(reserved, accepted: false)
    try taskExpect(!(try ledger.snapshot().tasks.flatMap(\.members).contains { $0.runID == cancelledItem }), "refused queue admission must remove reservation")
    let steerID = UUID(), steer = try ledger.reserveQueued(agentID: agent, itemID: steerID)
    try ledger.resolveQueuedReservation(steer, accepted: true); try ledger.applyQueuedToParent(steerID)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "c"), run: c)
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "c", outcome: .completed, errorMessage: nil), run: c)
    try taskExpect(try ledger.snapshot().tasks.first { $0.taskID == c.taskID }?.members.allSatisfy { $0.state == .succeeded } == true,
                   "consumed steer must settle with its actual parent turn")
    let lateParent = try ledger.begin(agentID: agent)
    let lateSteerID = UUID(), lateSteer = try ledger.reserveQueued(agentID: agent, itemID: lateSteerID)
    try ledger.resolveQueuedReservation(lateSteer, accepted: true)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "late-parent"), run: lateParent)
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "late-parent", outcome: .completed, errorMessage: nil), run: lateParent)
    try ledger.applyQueuedToParent(lateSteerID)
    let lateTask = try ledger.snapshot().tasks.first { $0.taskID == lateParent.taskID }!
    try taskExpect(!lateTask.membershipComplete && lateTask.members.first { $0.runID == lateSteerID }?.state == .unknown,
                   "late steer receipt cannot prove a promoted provider turn completed")
    let acceptedRoot = try ledger.reserveQueued(agentID: agent, itemID: UUID(), newTask: true)
    try ledger.resolveQueuedReservation(acceptedRoot, accepted: true)
    try taskExpect(acceptedRoot.taskID != lateParent.taskID, "readiness/force acceptance must reserve a new user root independently of old task work")
    try ledger.beginHostWork(acceptedRoot.runID); try ledger.settleHostWork(acceptedRoot.runID, state: .unknown)
    try taskExpect(try ledger.snapshot().tasks.first { $0.taskID == acceptedRoot.taskID }?.membershipComplete == false,
                   "indeterminate host work cannot become a failed or successful terminal")
    let fresh = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "new"), run: fresh)
    try ledger.observe(.userInputRequested(threadId: "private", requestId: "input-1", questions: []), run: fresh)
    try ledger.observe(.requestOpened(threadId: "private", requestId: "approval-1", kind: .commandExecutionApproval), run: fresh)
    try ledger.observe(.requestResolved(threadId: "private", requestId: "approval-1", decision: "approve"), run: fresh)
    try ledger.observe(.requestOpened(threadId: "private", requestId: "tool-input", kind: .toolUserInput), run: fresh)
    let pending = try ledger.snapshot().tasks.first { $0.taskID == fresh.taskID }!.members.first!
    try taskExpect(pending.state == .needsInput && pending.requestID == "input-1", "resolving one blocker must preserve other outstanding input")
    let before = try ledger.snapshot()
    let restored = try CompanionTaskLedger(applicationSupportDirectory: root)
    let after = try restored.snapshot()
    try taskExpect(before.publisherID == after.publisherID && after.revision > before.revision, "restart preserves publisher identity and advances state revision")
    try taskExpect(after.tasks.first { $0.taskID == fresh.taskID }?.members.first?.state == .unknown,
                   "restart must downgrade unconfirmed active work to unknown")
    let advanced = try restored.snapshot(revisionFloor: after.revision + 100)
    try taskExpect(advanced.revision > after.revision + 100 && advanced.tasks.allSatisfy { !$0.membershipComplete }, "server revision floor must fence restored backups conservatively")
    let encoded = String(decoding: try JSONEncoder().encode(advanced), as: UTF8.self)
    try taskExpect(!encoded.contains("private") && !encoded.contains("parent/tool") && !encoded.contains(root.path), "wire snapshot excludes provider/source/path metadata")
    let history = try CompanionTaskLedger(applicationSupportDirectory: root.appendingPathComponent("history"))
    let unknown = try history.beginUnknown(agentID: UUID())
    for index in 0..<140 {
        let settled = try history.begin(agentID: UUID())
        try history.observe(.turnStarted(threadId: "private", turnId: "h-\(index)"), run: settled)
        try history.observe(.turnCompleted(threadId: "private", turnId: "h-\(index)", outcome: .completed, errorMessage: nil), run: settled)
    }
    let known = try history.begin(agentID: UUID())
    try history.observe(.turnStarted(threadId: "private", turnId: "known"), run: known)
    try history.observe(.turnCompleted(threadId: "private", turnId: "known", outcome: .completed, errorMessage: nil), run: known)
    try history.setProviderMembershipUnknown(known, unknown: true)
    try taskExpect(try history.snapshot().tasks.first { $0.taskID == known.taskID }?.membershipComplete == false,
                   "unrouted provider events must withhold completion until membership is resolved")
    try history.setProviderMembershipUnknown(known, unknown: false)
    try taskExpect(try history.snapshot().tasks.first { $0.taskID == known.taskID }?.membershipComplete == true,
                   "confirmed provider routing may release only its own membership barrier")
    let bounded = try history.snapshot()
    try taskExpect(bounded.tasks.count == 129 && bounded.tasks.contains { $0.taskID == unknown.taskID }, "bounded settled history must never evict unknown work")
    let failingRoot = root.appendingPathComponent("unwritable")
    let failureLedger = try CompanionTaskLedger(applicationSupportDirectory: failingRoot)
    let priorRevision = failureLedger.revision
    let directory = failingRoot.appendingPathComponent("companion-tasks")
    try FileManager.default.removeItem(at: directory)
    try Data("occupied".utf8).write(to: directory)
    do { _ = try failureLedger.begin(agentID: UUID()); throw TaskLedgerCheckFailure(message: "unwritable ledger accepted work") }
    catch is TaskLedgerCheckFailure { throw TaskLedgerCheckFailure(message: "unwritable ledger accepted work") }
    catch {}
    try taskExpect(failureLedger.revision == priorRevision, "failed durable write must not mutate in-memory task truth")
    print("Companion task ledger checks passed: explicit root/child/queue provenance, old-child/new-task isolation, provider replay, admission barrier, stale terminal, steer settlement, restart unknown, revision floor and privacy")
}
