import ContinuumRevivedCore
import ContinuumRevivedAgentContent
import Foundation

/// A runner whose compaction can hang (the provider never answers), the way a
/// stalled `/compact`, `thread/compact/start` or pi `compact` really does.
private final class StallScriptRunner: AgentRunning, AgentCompactionRunning, @unchecked Sendable {
    enum Behaviour { case hang, fail, succeed }
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let behaviour: Behaviour
    private var stopped = false
    private var ops: [String] = []
    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    var compactionCapabilities: AgentCompactionCapabilities { AgentCompactionCapabilities(supportsManual: true, supportsFocus: false) }
    var keepsSessionAliveBetweenTurns: Bool { true }
    var canAcceptAnotherTurn: Bool { lock.withLock { !stopped } }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock { ops.append("run:\(prompt.text)"); stopped = false }
        let turnID = UUID().uuidString
        onEvent(.turnStarted(threadId: "provider", turnId: turnID))
        onEvent(.turnCompleted(threadId: "provider", turnId: turnID, outcome: .completed, errorMessage: nil))
    }

    func compact(_ request: AgentCompactionRequest,
                 onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock { ops.append("compact"); stopped = false }
        onEvent(.compactionChanged(threadId: "provider", event: AgentCompactionLifecycleEvent(
            operationID: request.operationID, phase: .running, trigger: .manual, provider: "script")))
        switch behaviour {
        case .hang:
            gate.wait()
            throw AgentRunStopped(detail: nil)
        case .fail:
            throw NSError(domain: "AgentCompactionStallCheck", code: 1)
        case .succeed:
            onEvent(.compactionChanged(threadId: "provider", event: AgentCompactionLifecycleEvent(
                operationID: request.operationID, boundaryID: "stall-boundary", phase: .succeeded, trigger: .manual,
                beforeTokens: AgentCompactionTokenReading(310_000, precision: .exact),
                afterTokens: AgentCompactionTokenReading(20_000, precision: .exact), provider: "script")))
        }
    }

    func stop() { lock.withLock { stopped = true }; gate.signal() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
    func operations() -> [String] { lock.withLock { ops } }
}

/// `--compaction-stall-check`: the ways a compaction can leave an agent looking
/// stuck, each driven through the real supervisor (and, for Ask me, a real tile).
@MainActor
func runAgentCompactionStallChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expectEventually(_ message: String, timeout: TimeInterval = 6, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-compaction-stall-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let longReading = AgentContextWindowSnapshot(usedTokens: 310_000, maxTokens: 1_000_000, observedAt: Date(),
                                                 source: .providerSessionStats, freshness: .live)

    struct Rig {
        let supervisor: AgentSupervisor
        let runner: StallScriptRunner
        let store: AgentComposerDraftStore
        let id: AgentID
    }
    func makeRig(_ name: String, _ behaviour: StallScriptRunner.Behaviour, timeout: TimeInterval? = nil,
                 mode: AgentContextCompactionMode = .automatic) async throws -> Rig {
        let dir = root.appendingPathComponent(name)
        let runner = StallScriptRunner(behaviour)
        let store = AgentComposerDraftStore(applicationSupportDirectory: dir, debounceInterval: 0)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: dir), makeRunner: { _ in runner },
                                         submissionRecoveryStore: store)
        supervisor.qaContextCompactionMode = { mode }
        supervisor.qaCompactionTimeout = timeout
        let config = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode)
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: config.model, thinking: config.thinking)
        guard supervisor.send("seed", to: id) else { throw Failure(description: "\(name): seed refused") }
        try await expectEventually("\(name): seed did not settle") { !supervisor.isRunning(id) && runner.operations() == ["run:seed"] }
        return Rig(supervisor: supervisor, runner: runner, store: store, id: id)
    }

    // 1. A compaction the provider never answers is stopped at the timeout: the
    //    agent returns to idle, says so, keeps its queue open, and takes a message.
    do {
        let rig = try await makeRig("timeout", .hang, timeout: 0.6)
        defer { rig.supervisor.stopAll() }
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await expectEventually("timeout: automatic compaction did not start") { rig.runner.operations() == ["run:seed", "compact"] }
        try await expectEventually("timeout: a hung compaction never released the agent") {
            !rig.supervisor.isRunning(rig.id) && rig.supervisor.turnSnapshot(for: rig.id)?.state != .compacting
        }
        guard !rig.supervisor.isQueuePaused(for: rig.id) else {
            throw Failure(description: "timeout: the queue stayed paused after a timed-out automatic compaction")
        }
        guard rig.supervisor.send("after timeout", to: rig.id) else {
            throw Failure(description: "timeout: the agent refused a message after the compaction timed out")
        }
        try await expectEventually("timeout: the message after the timeout never ran") { rig.runner.operations().contains("run:after timeout") }
    }

    // 2. A person's message does not wait behind a running automatic compaction:
    //    it stops the compaction and runs.
    do {
        let rig = try await makeRig("send-supersedes", .hang, timeout: 60)
        defer { rig.supervisor.stopAll() }
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await expectEventually("send: automatic compaction did not start") { rig.runner.operations() == ["run:seed", "compact"] }
        _ = await rig.supervisor.accept(.queue(AgentPrompt("typed while compacting")), for: rig.id)
        try await expectEventually("send: a message sent during a compaction stayed blocked behind it", timeout: 3) {
            rig.runner.operations().contains("run:typed while compacting")
        }
        guard !rig.supervisor.isQueuePaused(for: rig.id) else {
            throw Failure(description: "send: superseding the compaction paused the queue")
        }
    }

    // 3. A compaction that fails by itself returns the agent to idle and does not
    //    hold the queue.
    do {
        let rig = try await makeRig("failure", .fail)
        defer { rig.supervisor.stopAll() }
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await expectEventually("failure: automatic compaction did not run") { rig.runner.operations() == ["run:seed", "compact"] }
        try await expectEventually("failure: the agent stayed busy after a failed compaction") { !rig.supervisor.isRunning(rig.id) }
        guard !rig.supervisor.isQueuePaused(for: rig.id) else {
            throw Failure(description: "failure: a failed automatic compaction paused the queue")
        }
        guard rig.supervisor.send("after failure", to: rig.id) else { throw Failure(description: "failure: message refused after a failed compaction") }
    }

    // 4. A compaction never starts under a typed draft; it starts once the draft is gone.
    do {
        let rig = try await makeRig("typing", .succeed)
        defer { rig.supervisor.stopAll() }
        await rig.store.save(ContinuumRevivedCore.AgentComposerDraft(text: "half a thought", selection: 0..<0, updatedAt: Date()), for: rig.id)
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await Task.sleep(nanoseconds: 400_000_000)
        guard rig.runner.operations() == ["run:seed"] else {
            throw Failure(description: "typing: a compaction started under a typed draft: \(rig.runner.operations())")
        }
        await rig.store.save(ContinuumRevivedCore.AgentComposerDraft(text: "", selection: 0..<0, updatedAt: Date()), for: rig.id)
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await expectEventually("typing: the deferred compaction never ran once the draft was empty") {
            rig.runner.operations() == ["run:seed", "compact"]
        }
    }

    // 5. Ask me: nothing runs on its own; a real tile shows the offer past the
    //    size, Dismiss hides it, and Compact now runs the compaction.
    do {
        let rig = try await makeRig("ask", .succeed, mode: .ask)
        defer { rig.supervisor.stopAll() }
        let tileID = UUID()
        let fixture = AgentContextCompactionTileFixture.makeAttachedTile(supervisor: rig.supervisor, id: rig.id, tileID: tileID, scratch: root.appendingPathComponent("ask-tile"))
        defer { fixture.window.orderOut(nil); fixture.tile.detach() }
        guard !fixture.tile.qaCompactOfferShown else { throw Failure(description: "ask: the offer showed before the context was long") }
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await expectEventually("ask: the composer never showed the offer past the size") { fixture.tile.qaCompactOfferShown }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard rig.runner.operations() == ["run:seed"] else {
            throw Failure(description: "ask: Ask me compacted without being asked: \(rig.runner.operations())")
        }
        guard fixture.tile.qaPressCompactOffer("Dismiss") else { throw Failure(description: "ask: no Dismiss button") }
        try await expectEventually("ask: Dismiss did not hide the offer") { !fixture.tile.qaCompactOfferShown }
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard !fixture.tile.qaCompactOfferShown else { throw Failure(description: "ask: a dismissed offer came back in the same context") }
        // A new context epoch is long again: reset the dismissal by pressing through a fresh rig state.
        rig.supervisor.dismissContextCompactionOffer(for: rig.id)
    }
    do {
        let rig = try await makeRig("ask-press", .succeed, mode: .ask)
        defer { rig.supervisor.stopAll() }
        let fixture = AgentContextCompactionTileFixture.makeAttachedTile(supervisor: rig.supervisor, id: rig.id, tileID: UUID(), scratch: root.appendingPathComponent("ask-press-tile"))
        defer { fixture.window.orderOut(nil); fixture.tile.detach() }
        rig.supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: rig.id)
        try await expectEventually("ask-press: the composer never showed the offer") { fixture.tile.qaCompactOfferShown }
        guard fixture.tile.qaPressCompactOffer("Compact now") else { throw Failure(description: "ask-press: no Compact now button") }
        try await expectEventually("ask-press: pressing Compact now did not run the compaction") { rig.runner.operations() == ["run:seed", "compact"] }
        try await expectEventually("ask-press: the offer stayed after compacting") { !fixture.tile.qaCompactOfferShown }
    }

    // 6. A delegated helper is never asked: Ask me compacts it automatically.
    do {
        let dir = root.appendingPathComponent("helper")
        let runner = StallScriptRunner(.succeed)
        let store = AgentComposerDraftStore(applicationSupportDirectory: dir, debounceInterval: 0)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: dir), makeRunner: { _ in runner }, submissionRecoveryStore: store)
        defer { supervisor.stopAll() }
        let config = AgentModelConfig.resolvedFromDefaults(harness: .claudeCode)
        let lead = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: config.model, thinking: config.thinking)
        let helper = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: config.model, thinking: config.thinking, parentAgentID: lead)
        guard supervisor.send("seed", to: helper) else { throw Failure(description: "helper: seed refused") }
        try await expectEventually("helper: seed did not settle") { !supervisor.isRunning(helper) }
        // Mode Ask me is the default; no override, so the real policy decides.
        supervisor.qaDeliver(.contextWindowUpdated(threadId: "t", snapshot: longReading), to: helper)
        try await expectEventually("helper: a delegated helper was not compacted automatically under Ask me") { runner.operations().contains("compact") }
        guard !supervisor.contextCompactionOffered(for: helper) else { throw Failure(description: "helper: a helper was offered a button nobody sees") }
    }
    print("compaction stall checks passed: timeout recovery, send supersedes, failure frees the queue, typing defers, Ask me offer and press, helpers stay automatic")
}
