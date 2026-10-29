import ContinuumRevivedCore
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import Foundation

/// `agent.notify` end to end, with no stand-ins: the host's task ledger, the
/// Sync wire mapping the Mac publishes, and the relay's own task policy. What
/// matters is the alert the phone would get: one "needs you" that survives the
/// turn ending and a relaunch, silence once answered, one completion after.
func runAgentNotifyPolicyChecks() throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-notify-policy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let instance = UUID()
    var ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    func decision(_ taskID: UUID) throws -> RelayNotificationDecision {
        let batch = try ledger.snapshot().relayTaskBatch
        guard let task = batch.tasks.first(where: { $0.taskID == taskID }) else { throw Failure(message: "task missing from the published batch") }
        return RelaySystemSurfaceProjection.evaluate(
            event: .init(kind: "task.state.v1", payload: try JSONEncoder().encode(task)), instanceID: instance)
    }
    func ended(_ run: CompanionTaskRunHandle, _ turn: String) throws {
        try ledger.observe(.turnCompleted(threadId: "t", turnId: turn, outcome: .completed, errorMessage: nil), run: run)
    }

    // The root asks for the user.
    let agent = UUID()
    let a = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "a"), run: a)
    try check(try decision(a.taskID).path == .taskActive && decision(a.taskID).projection?.notification == nil, "a working task is quiet")
    _ = try ledger.holdAttention(a, requestID: "notify-0123456789abcdef")
    let asked = try decision(a.taskID)
    try check(asked.path == .taskAttention && asked.projection?.notification != nil && asked.projection?.agentID == agent,
              "needs_input alerts once, naming the agent: \(asked.path.rawValue)")
    let identity = asked.projection?.notificationIdentity

    // Turn end and relaunch: the same decision, so the relay sends nothing new.
    try ended(a, "a")
    let afterTurn = try decision(a.taskID)
    try check(afterTurn.path == .taskAttention && afterTurn.projection?.notificationIdentity == identity,
              "turn end keeps the same attention decision, not a completion: \(afterTurn.path.rawValue)")
    ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    try check(try decision(a.taskID).projection?.notificationIdentity == identity, "relaunch keeps the same attention decision")

    // Answered: quiet while the answer runs, then exactly one completion.
    let answer = try ledger.begin(agentID: agent)
    try check(answer.taskID == a.taskID, "the answer continues the task")
    try ledger.observe(.turnStarted(threadId: "t", turnId: "answer"), run: answer)
    let answering = try decision(a.taskID)
    try check(answering.path == .taskActive && answering.projection?.notification == nil, "answered work is quiet: \(answering.path.rawValue)")
    try ended(answer, "answer")
    let finished = try decision(a.taskID)
    try check(finished.path == .taskCompletion && finished.projection?.notification != nil
              && finished.projection?.notificationIdentity != identity, "the task completes once after the answer")

    // A child asking while its parent works alerts for the child; the parent
    // finishing does not announce completion over it.
    let parentAgent = UUID(), childAgent = UUID()
    let p = try ledger.begin(agentID: parentAgent)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "p"), run: p)
    let c = try ledger.begin(agentID: childAgent, parent: p)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "c"), run: c)
    _ = try ledger.holdAttention(c, requestID: "notify-child")
    try ended(p, "p")
    try ended(c, "c")
    let childAsked = try decision(p.taskID)
    try check(childAsked.path == .taskAttention && childAsked.projection?.agentID == childAgent,
              "a waiting child holds the task in attention, naming the child: \(childAsked.path.rawValue)")

    // "completed" changes nothing, so a child cannot announce the task.
    let q = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "q"), run: q)
    let k = try ledger.begin(agentID: UUID(), parent: q)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "k"), run: k)
    let before = ledger.revision
    try check(try !ledger.releaseAttention(k) && ledger.revision == before, "completed with nothing held writes nothing")
    try ended(k, "k")
    try check(try decision(q.taskID).path == .taskActive && decision(q.taskID).projection?.notification == nil,
              "a child finishing while its parent works stays quiet")

    print("Agent notify policy checks passed: ledger → wire → relay; one attention alert across turn end and relaunch, quiet while answered, one completion after; a child's request names the child; completed cannot announce a task")
}
