import AppKit
import ContinuumRevivedCore
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
            if !lock.withLock({ stopped }) {
                onEvent(.turnCompleted(threadId: threadId, turnId: "turn-\(n)", outcome: .completed, errorMessage: nil))
            }
        }
        func steer(_ prompt: AgentPrompt, id: UUID) throws {}
        func interrupt() throws {}
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
        supervisor.stop(id)
        let log = diagnostics(dir.appendingPathComponent("agents"))
        try require(log.contains("agent=\(id.rawValue.uuidString) queue paused reason=afterStop depth="),
            "Stop leaves a 'queue paused reason=afterStop depth=' line, got: \(log)")
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
    print("AgentQueueDrainChecks passed")
}
