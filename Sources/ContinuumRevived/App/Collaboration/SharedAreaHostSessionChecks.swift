import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// Real supervisor delivery and durable usage accounting, with a scripted
/// collaboration authority. No provider, window activation or Keychain access.
@MainActor
enum SharedAreaHostSessionChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS host usage lifecycle: \(message)")
    }
    private static func eventually(_ message: String, _ body: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await body() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(message: "timeout: " + message)
    }
    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(message: "isolated support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("host-usage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = Collaboration.Identity(person: .init(), device: UUID()), project = UUID()
        let agentA = AgentID(rawValue: UUID()), agentB = AgentID(rawValue: UUID())
        let hostA = SharedArea.ID<SharedArea.Host>(), hostB = SharedArea.ID<SharedArea.Host>()
        let objects = [hostA, hostB].map { host in
            SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: identity.person, host: host, binding: .init()))
        }
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: objects.enumerated().map { index, item in
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: Double(index * 340), y: 0, width: 300, height: 240)))
        }))
        let bindings = zip(objects, [agentA, agentB]).map { item, agent in
            SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: item.source!.host,
                projectID: project, agentID: agent)
        }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        for id in [agentA, agentB] {
            try store.upsert(.init(id: id, displayName: "Usage fixture", harness: .pi, model: "scripted/usage", thinking: "none",
                cwd: root.path, projectId: project, createdAt: Date(), lastActivityAt: Date()))
        }
        var executorConstructions = 0
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
            executorConstructions += 1; return ScriptedAgentRunner(script: [])
        })
        _ = supervisor.restore()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://host-usage.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-host-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil,
            endpoint: endpoint, person: identity.person, area: document.id)
        try cache.save(.init(scope: cache.scope, document: document, observedMembershipEpoch: 1, sourceBindings: [bindings[0]]))
        let authority = Authority(identity: identity, document: document)
        let controller = try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in authority })
        let handoff = try SharedAgentHandoffController(identity: identity, transport: authority, directory: cache.layout.areaDirectory)
        let session = try SharedAreaHostSession(controller: controller, handoffModel: handoff, supervisor: supervisor)
        session.start()
        defer { session.stop() }
        try await eventually("first host report") { await authority.reports.contains { $0.snapshot.host == hostA } }
        let first = await authority.reports.first { $0.snapshot.host == hostA }
        guard var state = try cache.load() else { throw Failure(message: "source cache absent") }
        state.sourceBindings = [bindings[1]]; try cache.save(state)
        // Adopt the newer private metadata through the controller's real merge
        // seam; an unchanged online document intentionally avoids a disk read.
        try controller.setView(controller.view)
        await controller.open(); await session.updateUsage()
        let second = await authority.reports.first { $0.snapshot.host == hostB }
        try expect(first?.snapshot.sequence == second?.snapshot.sequence && second != nil,
            "switching source hosts publishes equal-numbered snapshots independently")

        let openCount = await authority.opens
        session.stop(); session.start()
        try await eventually("stop/start reconnect") { await authority.opens > openCount && controller.status == .connected }
        let thread = AgentSupervisor.threadId(for: agentB)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "restarted-host"), to: agentB)
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: thread, snapshot: .init(inputTokens: 17, outputTokens: 3,
            totalCostUsd: nil, accountingObservationID: "restarted-message", observedAt: Date())), to: agentB)
        await session.updateUsage()
        try expect(session.lastUsage?.inputTokens == 17 && session.lastUsage?.outputTokens == 3,
            "restarting the same host restores its delivered-event observer and records new provider usage")
        let scene = SharedAreaSceneView(controller: controller, person: identity.person)
        scene.mount(); scene.unmount()
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: thread, snapshot: .init(inputTokens: 7, outputTokens: 2,
            totalCostUsd: nil, accountingObservationID: "after-view-closed", observedAt: Date())), to: agentB)
        await session.updateUsage()
        try expect(session.lastUsage?.inputTokens == 24 && session.lastUsage?.outputTokens == 5,
            "closing the shared presentation retains host accounting and its existing agent identity")
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: thread, snapshot: .init(inputTokens: 7, outputTokens: 2,
            totalCostUsd: nil, accountingObservationID: "after-view-closed", observedAt: Date())), to: agentB)
        await session.updateUsage()
        try expect(session.lastUsage?.inputTokens == 24 && session.lastUsage?.outputTokens == 5 && executorConstructions == 0,
            "replayed delivered usage is counted once without constructing any executor")
        session.stop(); await controller.close()
    }

    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock(); var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream()
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
    }
    private actor Authority: SharedAreaControllerTransport, SharedAgentHandoffTransport {
        let identityValue: Collaboration.Identity
        let document: SharedArea.Document
        var reports: [Collaboration.UsageReport] = []
        var opens = 0
        init(identity: Collaboration.Identity, document: SharedArea.Document) { identityValue = identity; self.document = document }
        func identity() async throws -> Collaboration.Identity { opens += 1; return identityValue }
        func state() async throws -> Collaboration.State { .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { Connection() }
        func reportUsage(_ report: Collaboration.UsageReport) async throws { reports.append(report) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { throw Failure(message: "unexpected document edit") }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { throw Failure(message: "no executable fixture host") }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { throw Failure(message: "no executable fixture host") }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Failure(message: "no handoff action") }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no prompt action") }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no prompt action") }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { [] }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no prompt action") }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no prompt action") }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(message: "no prompt action") }
    }
}
