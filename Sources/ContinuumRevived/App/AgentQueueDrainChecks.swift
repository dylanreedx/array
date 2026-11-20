import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI
import Foundation

/// Stale leads (`~/array-scratch/stale-leads/README.md`): a lead stopped
/// taking turns while agent-to-agent messages piled up in its queue, because
/// the queue was paused and nothing but a person could release it. Each
/// section drives the PRODUCTION supervisor, queue and restore path, and was
/// RED on 0.7.56 before its fix.
@MainActor
func runAgentQueueDrainChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }
    func require2<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }
    func waitFor(_ message: @autoclosure () -> String, timeout: TimeInterval = 15, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }

    final class Provider: AgentSteeringRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var stopped = false
        var threadId = ""
        private let gate = DispatchSemaphore(value: 0)
        var runs: Int { lock.withLock { started } }
        /// A turn that stays open until released or stopped.
        var blocks = true
        func release() { gate.signal() }
        var acceptsSteerNow: Bool { true }
        var hasBackgroundWork: Bool { false }
        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            let n = lock.withLock { started += 1; return started }
            onEvent(.turnStarted(threadId: threadId, turnId: "turn-\(n)"))
            if blocks { gate.wait() }
            let wasStopped = lock.withLock { stopped }
            onEvent(.turnCompleted(threadId: threadId, turnId: "turn-\(n)",
                outcome: wasStopped ? .interrupted : .completed, errorMessage: nil))
        }
        func steer(_ prompt: AgentPrompt, id: UUID) throws {}
        func interrupt() throws { lock.withLock { stopped = true }; gate.signal() }
        /// The provider ends its own turn as interrupted: nobody pressed Stop.
        func endInterrupted() { lock.withLock { stopped = true }; gate.signal() }
        func stop() { lock.withLock { stopped = true }; gate.signal() }
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
        func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
        func observeSteerDispositions(_ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void) {}
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("queue-drain-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let model = AgentCatalogQAFixture.pi[0]
    let previous = AgentModelCatalog.shared.snapshot(for: .pi)
    defer { AgentModelCatalog.shared.resetForQA(snapshot: previous) }
    AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready,
        models: [model], displayNames: [:], refreshedAt: Date()))

    func diagnostics(_ dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("agent-diagnostics.log"), encoding: .utf8)) ?? ""
    }

    // MARK: 0. Every pause and resume leaves a line with reason and depth.
    do {
        let dir = root.appendingPathComponent("s0", isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: dir.appendingPathComponent("agents"))
        let id = AgentID(rawValue: UUID())
        try store.upsert(.init(id: id, displayName: "Lead", harness: .pi, model: model, thinking: "medium",
            cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: dir.appendingPathComponent("drafts"), debounceInterval: 0)
        let provider = Provider()
        provider.threadId = AgentSupervisor.threadId(for: id)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in provider }, warn: { _ in },
            nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts)
        _ = supervisor.restore()
        try require(await supervisor.accept(.sendPrompt(.init("first turn")), for: id) == .accepted, "first turn starts")
        try await waitFor("first turn running") { provider.runs == 1 }
        var queued = await supervisor.accept(.queue(.init("queued behind the running turn")), for: id)
        for _ in 0..<150 where queued != .accepted {
            try await Task.sleep(for: .milliseconds(20))
            queued = await supervisor.accept(.queue(.init("queued behind the running turn")), for: id)
        }
        try require(queued == .accepted, "second prompt queues, got \(queued)")
        try require(await supervisor.accept(.stop, for: id) == .accepted, "the user Stop is accepted")
        let agentsDir = dir.appendingPathComponent("agents")
        try await waitFor("Stop leaves a 'queue paused reason=afterStop depth=' line") {
            diagnostics(agentsDir).contains("agent=\(id.rawValue.uuidString) queue paused reason=afterStop depth=")
        }
        supervisor.resumeQueue(for: id)
        try require(diagnostics(dir.appendingPathComponent("agents")).contains("queue resumed reason=afterStop"),
            "resuming leaves a 'queue resumed reason=afterStop' line")
    }

    // MARK: 1. A relaunch never strands agent-to-agent messages.
    // A queue a previous launch left behind waits for the person only when
    // the person typed something into it. Messages and results from other
    // agents were never typed by anyone: they run once the recipient is
    // hydrated, as they would have had the app stayed open.
    func relaunch(_ name: String, seed: (AgentComposerDraftStore, AgentID) async throws -> Void) async throws
        -> (supervisor: AgentSupervisor, provider: Provider, id: AgentID) {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: dir.appendingPathComponent("agents"))
        let id = AgentID(rawValue: UUID())
        try store.upsert(.init(id: id, displayName: "Lead", harness: .pi, model: model, thinking: "medium",
            cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: dir.appendingPathComponent("drafts"), debounceInterval: 0)
        try await seed(drafts, id)
        let provider = Provider()
        provider.blocks = false
        provider.threadId = AgentSupervisor.threadId(for: id)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in provider }, warn: { _ in },
            nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts)
        _ = supervisor.restore()
        return (supervisor, provider, id)
    }
    do {
        let sender = AgentID(rawValue: UUID())
        let agentOnly = try await relaunch("s1-agent") { drafts, id in
            let context = AgentMessageQueueContext(caller: sender, recipient: id, operationId: "op-1",
                idempotencyKey: "key-1", payloadHash: "h")
            try await drafts.enqueueAgentMessage(.init(text: "<array-agent-message>do the thing</array-agent-message>",
                queuedAt: Date(), agentMessageHops: 1, agentMessageContext: context), for: id)
        }
        try await waitFor("an agent message left in the queue runs after a relaunch") { agentOnly.provider.runs == 1 }
        try require(!agentOnly.supervisor.isQueuePaused(for: agentOnly.id), "an agent-only queue is not left paused")

        let typed = try await relaunch("s1-typed") { drafts, id in
            _ = await drafts.enqueueMessage(text: "a follow-up the person typed", for: id)
        }
        try await Task.sleep(for: .milliseconds(800))
        try require(typed.provider.runs == 0 && typed.supervisor.isQueuePaused(for: typed.id),
            "a follow-up the person typed still waits for them after a relaunch")
    }

    // MARK: 2. Only a person's Stop holds a queue.
    // A kill from anything else (closing a helper, a restart, a retry) used to
    // pause the queue too, and nothing ever resumed it: ED88C2A4 exited 143
    // with the perf lead's message still queued.
    do {
        func world(_ name: String, agentTraffic: Bool = false) async throws -> (AgentSupervisor, Provider, AgentID) {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let store = AgentStore(applicationSupportDirectory: dir.appendingPathComponent("agents"))
            let id = AgentID(rawValue: UUID())
            try store.upsert(.init(id: id, displayName: "Lead", harness: .pi, model: model, thinking: "medium",
                cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
            let sender = AgentID(rawValue: UUID())
            try store.upsert(.init(id: sender, displayName: "Sender", harness: .pi, model: model, thinking: "medium",
                cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
            let drafts = AgentComposerDraftStore(applicationSupportDirectory: dir.appendingPathComponent("drafts"), debounceInterval: 0)
            let provider = Provider(); provider.threadId = AgentSupervisor.threadId(for: id)
            let supervisor = AgentSupervisor(store: store, makeRunner: { _ in provider }, warn: { _ in },
                nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts)
            _ = supervisor.restore()
            try require(await supervisor.accept(.sendPrompt(.init("first turn")), for: id) == .accepted, "first turn starts")
            try await waitFor("first turn running") { provider.runs == 1 }
            if agentTraffic {
                let sent = supervisor.deliverAgentMessage("hold everything", from: sender, to: id, hops: 1)
                try require(sent.delivery != .refused, "an agent message queues behind the running turn: \(sent)")
            } else {
            var queued = await supervisor.accept(.queue(.init("second")), for: id)
            for _ in 0..<150 where queued != .accepted {
                try await Task.sleep(for: .milliseconds(20))
                queued = await supervisor.accept(.queue(.init("second")), for: id)
            }
            try require(queued == .accepted, "second prompt queues, got \(queued)")
            }
            return (supervisor, provider, id)
        }
        let programmatic = try await world("s2-kill")
        programmatic.1.endInterrupted()
        // 2026-11-20: a user's message the interrupt left unanswered is not history.
        // It returns to the top of the queue, held, for the user to send again.
        try await waitFor("an unrequested interrupt holds the user's unanswered message at the top of the queue") {
            programmatic.0.isQueuePaused(for: programmatic.2) && programmatic.0.queuedMessages(for: programmatic.2).first?.text == "first turn"
        }
        try await Task.sleep(for: .milliseconds(300))
        try require(programmatic.1.runs == 1 && programmatic.0.queuedMessages(for: programmatic.2).map(\.text) == ["first turn", "second"],
            "nothing runs by itself; the unanswered message precedes the queued one: \(programmatic.0.queuedMessages(for: programmatic.2).map(\.text))")
        // With another agent's message waiting, a held queue would strand it
        // (the stuck-lead failure): the unanswered message runs again at once.
        let agentWorld = try await world("s2-agent", agentTraffic: true)
        agentWorld.1.endInterrupted()
        try await waitFor("an unrequested interrupt with agent traffic queued lets the queue run") { agentWorld.1.runs == 2 }
        try require(!agentWorld.0.isQueuePaused(for: agentWorld.2), "agent traffic is never stranded behind a held queue")

        let user = try await world("s2-user")
        try require(await user.0.accept(.stop, for: user.2) == .accepted, "user Stop accepted")
        try await waitFor("the user's Stop holds the queue") { user.0.isQueuePaused(for: user.2) }
        try await Task.sleep(for: .milliseconds(500))
        try require(user.1.runs == 1, "the user's Stop keeps the queued message from running")
    }

    // MARK: 3. A drain that returned early is retried by the sweep.
    // The queue is idle, un-paused and holds a message, and no event is coming
    // to drain it: the shape a lead stayed in until a person typed.
    do {
        let dir = root.appendingPathComponent("s3", isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: dir.appendingPathComponent("agents"))
        let id = AgentID(rawValue: UUID())
        try store.upsert(.init(id: id, displayName: "Lead", harness: .pi, model: model, thinking: "medium",
            cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: dir.appendingPathComponent("drafts"), debounceInterval: 0)
        let provider = Provider(); provider.threadId = AgentSupervisor.threadId(for: id)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in provider }, warn: { _ in },
            nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts)
        _ = supervisor.restore()
        supervisor.queueSweepInterval = 0.3
        try require(await supervisor.accept(.sendPrompt(.init("first turn")), for: id) == .accepted, "first turn starts")
        try await waitFor("first turn running") { provider.runs == 1 }
        var queued = await supervisor.accept(.queue(.init("second")), for: id)
        for _ in 0..<150 where queued != .accepted {
            try await Task.sleep(for: .milliseconds(20))
            queued = await supervisor.accept(.queue(.init("second")), for: id)
        }
        try require(queued == .accepted, "second prompt queues, got \(queued)")
        supervisor.qaDropNextDrain = true
        provider.release()
        try await Task.sleep(for: .milliseconds(150))
        try await waitFor("the queued message runs without any new event") { provider.runs == 2 }
        try require(diagnostics(dir.appendingPathComponent("agents")).contains("queue sweep: retrying drain"),
            "the sweep says why it retried")
    }

    // MARK: 4. Expiry never silently drops an agent message.
    // A message held past 24 h folds into one "while you were away" note for
    // the recipient's next turn. It is not run, and not dropped.
    do {
        let sender = AgentID(rawValue: UUID())
        let agentsDir = root.appendingPathComponent("s4/agents", isDirectory: true)
        let outbox = AgentMessageOutbox(applicationSupportDirectory: agentsDir)
        let old = Date().addingTimeInterval(-72 * 3600)
        var recipient: AgentID?
        let world = try await relaunch("s4") { drafts, id in
            recipient = id
            let context = AgentMessageQueueContext(caller: sender, recipient: id, operationId: "op-old",
                idempotencyKey: "key-old", payloadHash: "h")
            let message = AgentComposerQueuedMessage(text: "<array-agent-message from=\"\(sender.rawValue.uuidString.lowercased())\" name=\"Perf lead\">\nskip the blind bisect\n</array-agent-message>",
                queuedAt: old, agentMessageHops: 1, agentMessageContext: context)
            try outbox.save(.init(context: context, message: message, queuePosition: 1))
            try await drafts.enqueueAgentMessage(message, for: id)
        }
        let id = recipient!
        try await waitFor("the stale message is settled with a record") {
            (try? outbox.lookup(caller: sender, key: "key-old"))??.phase == .cancelled
        }
        let entry = try outbox.lookup(caller: sender, key: "key-old")
        try require(entry?.result?.reason?.hasPrefix("Bundled, not run") == true,
            "the sender is told it was bundled, not dropped: \(String(describing: entry?.result?.reason))")
        let remaining = world.supervisor.queuedMessages(for: id)
        let bundle = remaining.map(\.text).first { $0.contains("While you were away") }
        try require(bundle?.contains("skip the blind bisect") == true && bundle?.contains("held 72 h") == true,
            "the content survives in one note: \(remaining)")
        try require(world.provider.runs == 0, "a bundled message does not start a turn")
        try require(diagnostics(agentsDir).contains("held agent messages bundled: count=1"), "the bundling is logged")
    }

    // MARK: 5. A queue whose agent has no record is archived, not stranded.
    do {
        let dir = root.appendingPathComponent("s5", isDirectory: true)
        let agentsDir = dir.appendingPathComponent("agents", isDirectory: true)
        let orphan = AgentID(rawValue: UUID()), sender = AgentID(rawValue: UUID())
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: dir.appendingPathComponent("drafts"), debounceInterval: 0)
        let outbox = AgentMessageOutbox(applicationSupportDirectory: agentsDir)
        let context = AgentMessageQueueContext(caller: sender, recipient: orphan, operationId: "op-orphan",
            idempotencyKey: "key-orphan", payloadHash: "h")
        let message = AgentComposerQueuedMessage(text: "message for an agent that is gone",
            queuedAt: Date().addingTimeInterval(-9 * 86400), agentMessageHops: 1, agentMessageContext: context)
        try outbox.save(.init(context: context, message: message, queuePosition: 1))
        try await drafts.enqueueAgentMessage(message, for: orphan)
        let store = AgentStore(applicationSupportDirectory: agentsDir)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in Provider() }, warn: { _ in },
            nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts)
        _ = supervisor.restore()
        let archived = agentsDir.appendingPathComponent("orphaned-queues/\(orphan.rawValue.uuidString).json")
        try require(FileManager.default.fileExists(atPath: archived.path)
            && ((try? String(contentsOf: archived, encoding: .utf8)) ?? "").contains("message for an agent that is gone"),
            "the orphaned queue is archived whole, not deleted")
        try require(!FileManager.default.fileExists(atPath: drafts.layout.queuedMessagesFile(for: orphan).path),
            "the live queue file is gone once archived")
        let entry = try outbox.lookup(caller: sender, key: "key-orphan")
        try require(entry?.phase == .cancelled && entry?.result?.reason?.contains("orphaned-queues") == true,
            "the sender is told where its message went: \(String(describing: entry?.result?.reason))")
        // Idempotent: a second restore finds nothing more to do.
        _ = supervisor.restore()
    }

    // MARK: 6. A message to a helper is queued, never refused, while a sibling writes its directory.
    // Orchestration review finding 7: "is writing this checkout now. Send again
    // once it finishes" made the sender remember to retry, and nobody did.
    do {
        let dir = root.appendingPathComponent("s6", isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: dir.appendingPathComponent("agents"))
        let lead = AgentID(rawValue: UUID()), a = AgentID(rawValue: UUID()), b = AgentID(rawValue: UUID())
        try store.upsert(.init(id: lead, displayName: "Lead", harness: .pi, mode: .managed, model: model, thinking: "medium",
            cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
        for (id, name) in [(a, "Earlier helper"), (b, "Later helper")] {
            try store.upsert(.init(id: id, displayName: name, harness: .pi, model: model, thinking: "medium",
                cwd: root.path, checkoutRoot: root.path, parentAgentID: lead, createdAt: Date(), lastActivityAt: Date(),
                latestTerminalEvent: id == a ? AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded, endedAt: Date()) : nil))
        }
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: dir.appendingPathComponent("drafts"), debounceInterval: 0)
        let providerA = Provider(), providerB = Provider()
        providerA.blocks = false
        providerA.threadId = AgentSupervisor.threadId(for: a)
        providerB.threadId = AgentSupervisor.threadId(for: b)
        let supervisor = AgentSupervisor(store: store, makeRunner: { launch in launch.record.id == a ? providerA : providerB },
            warn: { _ in }, nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts)
        _ = supervisor.restore()
        let previousClaude = AgentModelCatalog.shared.snapshot(for: .claudeCode)
        defer { AgentModelCatalog.shared.resetForQA(snapshot: previousClaude) }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready,
            models: [ManagedModeChecks.model], displayNames: [ManagedModeChecks.model: "Fixture"],
            contextWindows: [ManagedModeChecks.model: 200_000], effortLevels: [:]))
        try require(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model)
            && supervisor.setMode(.managed, for: lead), "the lead is a Managed lead")
        try require(supervisor.records[a]?.latestTerminalEvent != nil && supervisor.records[b]?.parentAgentID == lead,
            "the helpers are the lead's, and the earlier one has finished a turn")
        try require(await supervisor.accept(.sendPrompt(.init("write the checkout")), for: b) == .accepted, "the later helper starts writing")
        try await waitFor("the later helper is writing") { providerB.runs == 1 }
        try await waitFor("the supervisor sees the later helper running") { supervisor.isRunning(b) }
        let sent = supervisor.deliverAgentMessage("pick the work up again", from: lead, to: a, hops: 1)
        try require(sent.delivery != .refused, "a message to a helper whose sibling writes its directory is not refused: \(sent)")
        try await Task.sleep(for: .milliseconds(500))
        try require(providerA.runs == 0, "it does not run while the sibling writes the same directory")
        providerB.release()
        try await waitFor("it runs once the sibling finishes, with nobody retrying") { providerA.runs == 1 }
        // Helpers in directories of their own never conflict.
        var apart = try require2(supervisor.records[a], "record a")
        apart.cwd = root.appendingPathComponent(".worktrees/elsewhere").path
        try require(!AgentSupervisor.sharesWritableCheckout(apart, supervisor.records[b]!)
            && AgentSupervisor.sharesWritableCheckout(supervisor.records[a]!, supervisor.records[b]!),
            "sharing a checkout handle is not writing the same directory")
    }
    print("AgentQueueDrainChecks passed")
}
