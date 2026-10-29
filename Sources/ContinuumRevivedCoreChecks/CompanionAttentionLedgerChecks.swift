import Foundation
import ContinuumRevivedCore

private struct AttentionCheckFailure: Error { let message: String }
private func attentionExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw AttentionCheckFailure(message: message) }
}

/// `agent.notify` in the ledger: an agent's "I need you" outlives its turn, is
/// answered only by the agent's next accepted turn (which continues the task),
/// and can never be repeated, inherited or upgraded into a completion.
func runCompanionAttentionLedgerChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-attention-ledger-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    func member(_ run: CompanionTaskRunHandle) throws -> CompanionTaskSnapshot.Member? {
        try ledger.snapshot().tasks.first { $0.taskID == run.taskID }?.members.first { $0.runID == run.runID }
    }
    func task(_ id: UUID) throws -> CompanionTaskSnapshot? { try ledger.snapshot().tasks.first { $0.taskID == id } }
    func ended(_ run: CompanionTaskRunHandle, _ turn: String, _ outcome: TurnOutcome = .completed) throws {
        try ledger.observe(.turnCompleted(threadId: "t", turnId: turn, outcome: outcome, errorMessage: nil), run: run)
    }

    // Held mid-turn: the run needs input under the agent's own request id.
    let agent = UUID()
    let a = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "a"), run: a)
    try attentionExpect(try ledger.holdAttention(a, requestID: "notify-1") == .recorded, "first request is recorded")
    try attentionExpect(try member(a)?.state == .needsInput && member(a)?.requestID == "notify-1", "held request marks the run needsInput")
    let revision = ledger.revision
    try attentionExpect(try ledger.holdAttention(a, requestID: "notify-1") == .alreadyRecorded, "same request is idempotent")
    try attentionExpect(try ledger.holdAttention(a, requestID: "notify-2") == .coalesced, "a second request in one run is coalesced")
    try attentionExpect(ledger.revision == revision, "repeated or coalesced requests write nothing")
    do { _ = try ledger.holdAttention(a, requestID: "bad/id"); try attentionExpect(false, "a path-like request id was accepted") }
    catch CompanionTaskLedgerError.invalidRequest {}

    // A provider request still takes precedence while open, then hands back.
    try ledger.observe(.requestOpened(threadId: "t", requestId: "approval-1", kind: .commandExecutionApproval), run: a)
    try attentionExpect(try member(a)?.state == .needsApproval, "an open approval outranks the held request")
    try ledger.observe(.requestResolved(threadId: "t", requestId: "approval-1", decision: "approved"), run: a)
    try attentionExpect(try member(a)?.state == .needsInput && member(a)?.requestID == "notify-1", "resolving the approval leaves the held request")

    // The turn ends: still waiting, never success. Later process noise is ignored.
    try ended(a, "a")
    try attentionExpect(try member(a)?.state == .needsInput && task(a.taskID)?.membershipComplete == true,
                        "a held request survives turn end as needsInput, not success")
    try ledger.observe(.sessionStateChanged(.stopped), run: a)
    try ledger.observe(.runtimeError(threadId: "t", message: "exit"), run: a)
    try attentionExpect(try member(a)?.state == .needsInput, "the runner stopping after the turn does not withdraw the wait")
    try attentionExpect(try ledger.holdAttention(a, requestID: "notify-3") == .coalesced, "a waiting run cannot re-alert")

    // Restart keeps the wait: it is a settled fact, not lost live work.
    ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    try attentionExpect(try member(a)?.state == .needsInput && task(a.taskID)?.membershipComplete == true,
                        "restart preserves a waiting run and its task's completeness")

    // Unsolicited provider work does not answer the person's question.
    let stray = try ledger.beginUnknown(agentID: agent)
    try attentionExpect(stray.taskID != a.taskID && (try member(a)?.state) == .needsInput, "unknown work leaves the request open")
    try ledger.settleHostWork(stray.runID, state: .succeeded)

    // The answer continues the same task; the waiting turn had succeeded.
    let answer = try ledger.begin(agentID: agent)
    try attentionExpect(answer.taskID == a.taskID && (try member(answer)?.parentRunID) == a.runID,
                        "the answering turn joins the waiting task under the waiting run")
    try attentionExpect(try member(a)?.state == .succeeded && member(a)?.requestID == nil, "answering settles the waiting run")
    try ledger.observe(.turnStarted(threadId: "t", turnId: "answer"), run: answer)
    try ended(answer, "answer")
    try attentionExpect(try task(a.taskID)?.members.allSatisfy { $0.state == .succeeded } == true, "the task completes after the answer")
    try attentionExpect(try ledger.holdAttention(a, requestID: "notify-4") == .notRunning, "a settled run cannot be held again")

    // A child's request, answered through the queue even on a readiness hold.
    let parentAgent = UUID(), childAgent = UUID()
    let p = try ledger.begin(agentID: parentAgent)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "p"), run: p)
    let c = try ledger.begin(agentID: childAgent, parent: p)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "c"), run: c)
    try attentionExpect(try ledger.holdAttention(c, requestID: "notify-child") == .recorded, "a child may ask for the user")
    try ended(p, "p")
    try ended(c, "c")
    try attentionExpect(try task(p.taskID).map { t in t.members.contains { $0.runID == c.runID && $0.state == .needsInput } } == true,
                        "a parent finishing does not settle its waiting child")
    let item = UUID()
    let queued = try ledger.reserveQueued(agentID: childAgent, itemID: item, newTask: true)
    try attentionExpect(queued.taskID == p.taskID && (try member(queued)?.parentRunID) == c.runID,
                        "work queued for a waiting agent continues its task")
    try ledger.resolveQueuedReservation(queued, accepted: true)
    _ = try ledger.begin(agentID: childAgent, queuedID: item)
    try attentionExpect(try member(c)?.state == .succeeded && member(queued)?.state == .running, "draining the answer settles the child's wait")

    // Withdrawn before the turn ends: an ordinary success.
    let w = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "w"), run: w)
    _ = try ledger.holdAttention(w, requestID: "notify-w")
    try attentionExpect(try ledger.releaseAttention(w) && member(w)?.state == .running && member(w)?.requestID == nil, "release returns the run to running")
    try ended(w, "w")
    try attentionExpect(try member(w)?.state == .succeeded, "a released request does not hold the turn")

    // A failed or stopped turn drops its request; failure keeps its own path.
    let f = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "f"), run: f)
    _ = try ledger.holdAttention(f, requestID: "notify-f")
    try ended(f, "f", .failed)
    try attentionExpect(try member(f)?.state == .failed && member(f)?.requestID == nil, "a failed turn is a failure, not a wait")
    let s = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "s"), run: s)
    _ = try ledger.holdAttention(s, requestID: "notify-s")
    try ledger.observe(.sessionStateChanged(.stopped), run: s)
    try attentionExpect(try member(s)?.state == .interrupted && member(s)?.requestID == nil, "stopping mid-turn withdraws the request")

    print("Companion attention ledger checks passed: held request, idempotent/coalesced repeats, approval precedence, turn end waits, restart keeps the wait, unknown work does not answer, the answer continues the task, child wait via queue, release, failure and stop")
}
