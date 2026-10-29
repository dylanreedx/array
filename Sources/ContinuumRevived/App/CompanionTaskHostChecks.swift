import Foundation
import ContinuumRevivedCore

@MainActor
func runCompanionTaskHostChecks() async throws -> String {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    func wait(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<250 { if try predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw Failure(description: "host task predicate timed out")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-host-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = AgentModelConfig.resolvedFromDefaults()
    let drafts = AgentComposerDraftStore(applicationSupportDirectory: root)
    var runners: [ScriptedAgentRunner] = []
    let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { _ in
        let turn = "turn-\(runners.count)"
        let runner = ScriptedAgentRunner(script: [.turnStarted(threadId: "private/provider", turnId: turn)], holdUntilStopped: true)
        runners.append(runner); return runner
    }, submissionRecoveryStore: drafts)
    defer { for runner in runners { runner.stop() } }
    var pushes = 0
    supervisor.onCompanionTasksChanged = { pushes += 1 }
    let parent = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
    let child = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking, parentAgentID: parent)
    try require(supervisor.records[parent]?.tileId == nil && supervisor.subscriberCount(for: parent) == 0, "nonvacuity: witness must run without a tile/subscriber")
    try require(supervisor.send("private user prompt", to: parent), "accepted root send")
    try await wait { let state = try supervisor.companionTaskSnapshot().tasks.first?.members.first?.state; return runners.first?.runCount == 1 && state == .running }
    try require(supervisor.sendAgentMessage("private delegated prompt", from: parent, to: child), "accepted delegation")
    try await wait { runners.count == 2 && runners[1].runCount == 1 }
    let admission = await supervisor.accept(.queue(AgentPrompt("private queued prompt")), for: parent)
    try require(admission == .accepted, "accepted queued work")
    let queuedItems = await drafts.queuedWorkItems(for: parent)
    try require(queuedItems.count == 1, "nonvacuity: durable queue contains work")
    let before = try supervisor.companionTaskSnapshot()
    let task = before.tasks.first!
    try require(before.tasks.count == 1 && task.members.count == 3 && task.members.contains { $0.state == .queued }, "accepted user/delegated/queued work must share a task")
    let rootRun = task.rootRunID
    let childRun = task.members.first { $0.agentID == child.rawValue }!
    try require(childRun.parentRunID == rootRun, "delegation must bind actual parent run")
    try require(runners[0].emit(.turnCompleted(threadId: "private/provider", turnId: "turn-0", outcome: .completed, errorMessage: nil)), "root provider terminal emitted")
    runners[0].releaseRunAfterStop()
    try await wait { runners.count == 3 && runners[2].runCount == 1 }
    let drained = try supervisor.companionTaskSnapshot().tasks.first!
    try require(drained.members.contains { $0.runID == queuedItems[0].id && $0.state == .running }, "queue drain must reuse durable item run identity")
    try require(drained.members.contains { $0.runID == childRun.runID && $0.state == .running }, "parent completion must preserve running delegated child")
    try require(runners[2].emit(.turnCompleted(threadId: "private/provider", turnId: "turn-2", outcome: .completed, errorMessage: nil)), "queued result emitted")
    runners[2].releaseRunAfterStop()
    try await wait { !supervisor.isRunning(parent) }
    try require(supervisor.send("private new user task", to: parent), "new user task on reused agent")
    try await wait { runners.count == 4 && runners[3].runCount == 1 }
    let next = try supervisor.companionTaskSnapshot()
    let newTask = next.tasks.first { $0.taskID != task.taskID }!
    try require(newTask.members.count == 1 && newTask.rootRunID != rootRun, "ordinary later send must not inherit lifetime parent or old task")
    try require(runners[1].emit(.turnCompleted(threadId: "private/provider", turnId: "turn-1", outcome: .completed, errorMessage: nil)), "old child emitted result")
    runners[1].releaseRunAfterStop()
    try await wait { !supervisor.isRunning(child) }
    let settled = try supervisor.companionTaskSnapshot()
    try require(settled.tasks.first { $0.taskID == task.taskID }!.members.allSatisfy { $0.state == .succeeded }, "old task settles when its actual last member settles")
    try require(settled.tasks.first { $0.taskID == newTask.taskID }!.members.first?.state == .running, "old child must not finish new task")
    // A delayed result from the same current process also needs a turn-ID fence.
    let revision = settled.revision
    try require(runners[3].emit(.turnCompleted(threadId: "private/provider", turnId: "stale-turn", outcome: .completed, errorMessage: nil)), "stale provider result emitted")
    try await Task.sleep(for: .milliseconds(50))
    try require(try supervisor.companionTaskSnapshot().revision == revision, "stale terminal must not alter authoritative task state")
    let beforeContent = try supervisor.companionTaskSnapshot().revision
    supervisor.qaDeliver(.contentDelta(threadId: "private/provider", turnId: "turn-3", streamKind: .assistant, delta: "private body"), to: parent)
    try require(try supervisor.companionTaskSnapshot().revision == beforeContent, "content streaming must not write task ledger")
    let encoded = String(decoding: try JSONEncoder().encode(supervisor.companionTaskSnapshot()), as: UTF8.self)
    try require(!encoded.contains("private") && !encoded.contains(root.path) && pushes >= 6, "headless production callbacks publish only safe task metadata")
    let restored = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let restoredSnapshot = try restored.companionTaskSnapshot()
    try require(restoredSnapshot.publisherID == settled.publisherID && restoredSnapshot.tasks.first { $0.taskID == newTask.taskID }?.members.first?.state == .unknown,
                "relaunch must preserve membership and withhold unconfirmed completion")
    var discoveryPending = true
    let heldRunner = ScriptedAgentRunner(script: [.turnStarted(threadId: "private", turnId: "held")], holdUntilStopped: true)
    defer { heldRunner.stop() }
    let heldSupervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("held")), makeRunner: { _ in heldRunner })
    heldSupervisor.awaitsSessionDiscovery = { discoveryPending }
    let heldConfig = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode)
    let heldAgent = heldSupervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: heldConfig.model, thinking: heldConfig.thinking)
    let heldAcceptance = await heldSupervisor.accept(.send("private readiness prompt"), for: heldAgent)
    let heldSnapshot = try heldSupervisor.companionTaskSnapshot()
    try require(heldAcceptance == .accepted && heldRunner.runCount == 0 && heldSnapshot.tasks.first?.members.first?.state == .queued,
                "accepted readiness hold must already own a queued run before the runner exists")
    let heldRunID = heldSnapshot.tasks[0].rootRunID
    discoveryPending = false; heldSupervisor.releaseHeldPrompts()
    try await wait { heldRunner.runCount == 1 }
    try require(try heldSupervisor.companionTaskSnapshot().tasks.first?.rootRunID == heldRunID, "readiness release must reuse accepted run identity")
    let cancelSupervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("withdrawn")), makeRunner: { _ in ScriptedAgentRunner(script: []) })
    cancelSupervisor.awaitsSessionDiscovery = { true }
    let withdrawn = cancelSupervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: heldConfig.model, thinking: heldConfig.thinking)
    let withdrawnAcceptance = await cancelSupervisor.accept(.send("private held then stopped"), for: withdrawn)
    try require(withdrawnAcceptance == .accepted, "readiness withdrawal fixture must be accepted")
    _ = await cancelSupervisor.accept(.stop, for: withdrawn)
    try require(try cancelSupervisor.companionTaskSnapshot().tasks.first?.members.first?.state == .cancelled, "withdrawing held work must cancel its task member")
    return "CompanionTaskHostChecks passed: production headless supervisor, accepted/delegated/durable queued work, reused queue identity, parent/child settlement, old-child/new-task isolation, stale provider result, content privacy, restart unknown and readiness hold/release/withdrawal"
}
