import Foundation
import ContinuumRevivedCore

func runCompanionAgentDestinationChecks() throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-phone-detail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    let agent = UUID(), instance = UUID()
    let a = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "a"), run: a)
    let child = try ledger.begin(agentID: UUID(), parent: a)
    try ledger.observe(.turnStarted(threadId: "private", turnId: "child"), run: child)
    try ledger.observe(.turnCompleted(threadId: "private", turnId: "a", outcome: .completed, errorMessage: nil), run: a)
    let b = try ledger.begin(agentID: agent)
    let url = URL(string: "array://agent/\(agent)?task=\(a.taskID)&run=\(a.runID)&instance=\(instance)")!
    guard let route = CompanionAgentDestination(url: url, pairedInstanceID: instance) else { throw Failure(message: "valid exact destination refused") }
    let observation = CompanionTaskObservation(batch: try ledger.snapshot(), publishedAt: Date(timeIntervalSince1970: 10), sequence: 12)
    guard let task = observation.task(for: route) else { throw Failure(message: "exact historical task lost on reused agent") }
    try check(task.taskID == a.taskID && task.taskID != b.taskID, "notification must not select newer work on reused agent")
    let detail = CompanionTaskDetail(task: task)
    try check(detail.running == 1 && detail.succeeded == 1 && detail.summary == "Work remains on this task", "finished parent must expose remaining child")
    try check(CompanionAgentDestination(url: url, pairedInstanceID: UUID()) == nil, "foreign paired Mac must be rejected")
    try check(CompanionAgentDestination(url: url, pairedInstanceID: nil) == nil, "instance-bound link cannot bypass pairing")
    for raw in ["https://agent/\(agent)", "array://agent/no-id", "array://agent/\(agent)?task=bad", "array://agent/\(agent)?task=\(a.taskID)&task=\(b.taskID)", "array://agent/\(agent)/extra"] {
        try check(CompanionAgentDestination(url: URL(string: raw)!, pairedInstanceID: instance) == nil, "malformed/ambiguous destination accepted")
    }
    let legacy = CompanionAgentDestination(url: URL(string: "array://agent/\(agent)")!, pairedInstanceID: instance)!
    try check(legacy.agentID == agent && observation.task(for: legacy) == nil, "legacy link opens agent without guessing task")
    let absent = CompanionAgentDestination(url: URL(string: "array://agent/\(agent)?task=\(UUID())")!, pairedInstanceID: instance)!
    try check(observation.task(for: absent) == nil, "missing task must remain unavailable")
    let restored = try CompanionTaskLedger(applicationSupportDirectory: root)
    let unknown = try restored.snapshot().tasks.first { $0.taskID == a.taskID }!
    try check(CompanionTaskDetail(task: unknown).uncertain, "restart unknown must not appear as completed")
    try check(observation.publishedAt == Date(timeIntervalSince1970: 10), "replay must retain original receipt time")
    print("Companion agent destination checks passed: exact old-task/new-agent isolation, remaining child, pairing fence, legacy/missing/malformed links and unknown restart")
}
