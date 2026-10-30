import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct RetentionRecoveryFailure: Error { let message: String }
private func retentionRecoveryExpect(_ value: Bool, _ label: String) throws {
    guard value else { throw RetentionRecoveryFailure(message: label) }
    print("PASS retention recovery: \(label)")
}
private final class RetentionRecoveryVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private final class RetentionRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private actor ManualConnection: SharedAreaControllerConnection {
    private let pair = AsyncStream<CollaborationSession.Status>.makeStream()
    func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
    func stop() async { pair.continuation.finish() }
    func emit(_ status: CollaborationSession.Status) { pair.continuation.yield(status) }
}
/// Serves either the cached schema or a future one through the real decoder.
private actor SchemaTransport: SharedAreaControllerTransport {
    let identityValue: Collaboration.Identity
    var state: Collaboration.State
    var future = false
    var latest: ManualConnection?
    init(identity: Collaboration.Identity, state: Collaboration.State) { identityValue = identity; self.state = state }
    func identity() async throws -> Collaboration.Identity { identityValue }
    func state() async throws -> Collaboration.State {
        guard future else { return state }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var document = json["document"] as! [String: Any]
        document["schema"] = 2; json["document"] = document
        return try JSONDecoder().decode(Collaboration.State.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection {
        let connection = ManualConnection(); latest = connection
        return connection
    }
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        var document = state.document
        let result = try document.apply(mutation.command)
        state = .init(scope: state.scope, document: document)
        switch result {
        case .applied(let revision): return .init(revision: revision, duplicate: false)
        case .duplicate(let revision): return .init(revision: revision, duplicate: true)
        }
    }
    func setFuture(_ value: Bool) { future = value }
}

@MainActor
private func settle(_ label: String, _ predicate: () throws -> Bool) async throws {
    for _ in 0..<500 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RetentionRecoveryFailure(message: "timeout: \(label)")
}

/// COL-19 client side: an unsupported schema leaves the cache bytes, drafts and
/// outbox exactly as they were; an ancient schema-2 cache behind a compacted
/// horizon recovers over real HTTP; executable requests that outlive their
/// authority window expire at the real host adapter instead of executing.
@MainActor
func runCollaborationRetentionRecoveryChecks() async throws {
    let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path).resolvingSymlinksInPath()
        .appendingPathComponent("array-collaboration-retention-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await incompatibleSchemaKeepsCache(root: root.appendingPathComponent("incompatible"))
    try await ancientCacheRecoversOverHTTP(root: root.appendingPathComponent("ancient"))
    try await offlineDispatchesExpire(root: root.appendingPathComponent("dispatch"))
    print("Collaboration retention recovery checks passed: incompatible schema keeps the cache, ancient cache recovers past compaction, executable requests expire under current authority.")
}

@MainActor
private func incompatibleSchemaKeepsCache(root: URL) async throws {
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://retention.example.test")!)
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    let credentials = CollaborationCredentialStore(vault: RetentionRecoveryVault(), bundleIdentifier: nil)
    let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
    try credentials.save(.init(identity: identity, token: "synthetic-retention-credential"), for: scope)
    let thread = SharedArea.Item(id: .init(), kind: .discussion)
    var document = SharedArea.Document()
    try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
        .admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 400, height: 300))),
        .post(.init(id: .init(), object: thread.id, author: identity.person, text: "Cached before the schema moved"))
    ]))
    let transport = SchemaTransport(identity: identity, state: .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document))
    let store = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint, person: identity.person, area: document.id)
    func controller() throws -> SharedAreaController {
        try .init(localStore: store, credentialStore: credentials, credentialScope: scope, bundleIdentifier: nil, transportFactory: { _, _, _ in transport })
    }
    let first = try controller()
    await first.open()
    try retentionRecoveryExpect(first.status == .connected, "compatible service connects and writes the cache")
    await first.close()
    // A private draft and an unsent exact operation ride along in the cache.
    guard var cached = try store.load() else { throw RetentionRecoveryFailure(message: "cache absent") }
    let draft = SharedAreaLocalDraft(object: thread.id, text: "draft that must survive")
    let unsent = SharedArea.Command(area: document.id, expectedRevision: document.revision,
        edits: [.post(.init(id: .init(), object: thread.id, author: identity.person, text: "unsent outbox entry"))])
    cached.drafts.append(draft)
    cached.operations.append(.init(command: unsent, actor: identity))
    cached = try store.save(cached)
    let bytes = try Data(contentsOf: store.layout.stateFile)

    await transport.setFuture(true)
    let refused = try controller()
    await refused.open()
    try retentionRecoveryExpect(refused.status == .unavailable(.incompatibleState) && refused.document == nil,
        "a future document schema is refused as incompatible, not applied")
    try retentionRecoveryExpect(try Data(contentsOf: store.layout.stateFile) == bytes,
        "the refusal leaves the local cache bytes unchanged")
    await refused.close()

    // The live-session path: incompatibility after connecting keeps the cache too.
    await transport.setFuture(false)
    let live = try controller()
    await live.open()
    try await settle("live controller connects") { live.status == .connected }
    try await settle("live controller settles its outbox") { (try store.load()?.operations.contains { !$0.isPending }) == true }
    let liveBytes = try Data(contentsOf: store.layout.stateFile)
    await transport.latest?.emit(.incompatible)
    try await settle("incompatible session closes the view") { live.status == .unavailable(.incompatibleState) }
    try retentionRecoveryExpect(try Data(contentsOf: store.layout.stateFile) == liveBytes,
        "an incompatible live session leaves the cache bytes unchanged")
    await live.close()

    let upgraded = try controller()
    let reread = try store.load()
    try retentionRecoveryExpect(upgraded.status == .cached && upgraded.document?.posts.count == 2
            && reread?.drafts.contains(draft) == true && reread?.accessDenied == false,
        "a later build reopens the cache readable, with its draft and settled outbox intact")
}

@MainActor
private func ancientCacheRecoversOverHTTP(root: URL) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clock = RetentionRecoveryClock(), key = Data(repeating: 91, count: 32)
    let service = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key, clock: { clock.now() },
        retention: .init(operationTail: 8, operationAge: 60, compactionBatch: 16))
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: service)
    try await server.start()
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let endpoint = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
        let enrollment = try await service.provisionPerson(label: "Ancient client")
        let credential = try await service.redeem(.init(code: enrollment.code, deviceLabel: "Ancient client"))
        let api = try CollaborationAPI(baseURL: url, credential: credential.token, allowsInsecureLoopback: true)
        let created = try await api.createArea(), area = created.scope.area
        let thread = SharedArea.Item(id: .init(), kind: .discussion), artifact = SharedArea.Item(id: .init(), kind: .artifact)
        _ = try await api.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: 0, edits: [
            .admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 400, height: 300))),
            .admit(artifact, .init(id: .init(), object: artifact.id, rect: .init(x: 500, y: 0, width: 200, height: 120)))
        ])))
        let early = try await api.state(area: area.rawValue)

        // Write the cache exactly as a pre-outbox (schema 2) build left it.
        let credentials = CollaborationCredentialStore(vault: RetentionRecoveryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: credential.identity)
        try credentials.save(credential, for: scope)
        let store = try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent("support"), bundleIdentifier: nil,
            endpoint: endpoint, person: credential.identity.person, area: area)
        let draft = SharedAreaLocalDraft(object: thread.id, text: "ancient private draft")
        let current = SharedAreaLocalState(scope: store.scope, document: early.document, observedMembershipEpoch: 1, drafts: [draft])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        json["schema"] = 2; json["localGeneration"] = 1; json.removeValue(forKey: "operations")
        try FileManager.default.createDirectory(at: store.layout.areaDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: store.layout.stateFile)
        let ancientBytes = try Data(contentsOf: store.layout.stateFile)
        try retentionRecoveryExpect(try store.load()?.drafts == [draft] && (try Data(contentsOf: store.layout.stateFile)) == ancientBytes,
            "the schema-2 cache reads under the current build without rewriting its bytes")

        // Meanwhile the service deletes the artifact and compacts far past the cache.
        var head: UInt64 = 1
        head = try await api.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: head, edits: [.remove(artifact.id)]))).revision
        for index in 1...40 {
            head = try await api.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: head,
                edits: [.post(.init(id: .init(), object: thread.id, author: credential.identity.person, text: "While away \(index)"))]))).revision
        }
        clock.advance(120)
        head = try await api.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: head,
            edits: [.post(.init(id: .init(), object: thread.id, author: credential.identity.person, text: "After the window"))]))).revision
        let integrity = try await service.verifyIntegrity()
        try retentionRecoveryExpect((integrity.horizons[area.rawValue] ?? 0) > early.document.revision,
            "the service compacted past the ancient cache's revision")
        do {
            _ = try await api.updates(area: area.rawValue, request: .init(after: early.document.revision, waitMilliseconds: 0))
            throw RetentionRecoveryFailure(message: "ancient cursor was served a page")
        } catch CollaborationClientError.server(409, "snapshotRequired") {
            print("PASS retention recovery: the ancient cursor is refused with an explicit snapshot instruction")
        }

        let controller = try SharedAreaController(localStore: store, credentialStore: credentials, credentialScope: scope, bundleIdentifier: nil)
        try retentionRecoveryExpect(controller.status == .cached && controller.document?.items.contains { $0.id == artifact.id } == true,
            "before reconnecting, the ancient cache shows what it last accepted")
        await controller.open()
        try await settle("ancient controller connects") { controller.status == .connected }
        let authoritative = try await api.state(area: area.rawValue).document
        let saved = try store.load()
        let savedSchema = (try JSONSerialization.jsonObject(with: Data(contentsOf: store.layout.stateFile)) as? [String: Any])?["schema"] as? Int
        try retentionRecoveryExpect(try saved?.document.canonicalData() == authoritative.canonicalData() && saved?.document.revision == head,
            "the ancient client resnapshots to the exact authoritative document")
        try retentionRecoveryExpect(controller.document?.items.contains { $0.id == artifact.id } == false
                && saved?.drafts == [draft] && savedSchema == SharedAreaLocalState.currentSchema,
            "the deleted artifact is gone, the private draft survives and the cache migrates to the current schema")
        await controller.close()
        try await server.stop()
    } catch { try? await server.stop(); throw error }
}

@MainActor
private func offlineDispatchesExpire(root: URL) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clock = RetentionRecoveryClock(), key = Data(repeating: 97, count: 32)
    let window: TimeInterval = 300
    let service = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key, clock: { clock.now() },
        retention: .init(dispatchAuthorityWindow: window))
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: service)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ name: String) async throws -> Collaboration.Credential {
            let enrollment = try await service.provisionPerson(label: name)
            return try await service.redeem(.init(code: enrollment.code, deviceLabel: name))
        }
        let a = try await person("Owner A"), b = try await person("Teammate B")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let initial = try await aa.createArea(), area = initial.document.id.rawValue
        _ = try await bb.accept(code: try await aa.invite(area: area, request: .init(person: b.identity.person)).code)
        let host = try await aa.registerHost()
        let object = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let context = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person, text: "Agreed change.")
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: initial.document.id, expectedRevision: 0, edits: [
            .admit(object, .init(id: .init(), object: object.id, rect: .init(x: 0, y: 0, width: 300, height: 200))),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 350, y: 0, width: 300, height: 200))), .context(context)
        ])))
        let binding = SharedAreaLocalSourceBinding(object: object.id, binding: object.source!.binding, host: host.id,
            projectID: UUID(), tileID: UUID(), agentID: .init(rawValue: UUID()))
        let hostDirectory = root.appendingPathComponent("owner-host", isDirectory: true)
        var executions: [UUID] = []
        let execute: SharedAgentHostDispatcher.Execute = { _, command in executions.append(command.id); return .accepted }
        let liveA = SharedAgentHandoffAPI(api: aa, area: area), liveB = SharedAgentHandoffAPI(api: bb, area: area)
        let hostDispatcher = SharedAgentHostDispatcher(identity: a.identity, transport: liveA,
            journal: try SharedAgentHostJournal(directory: hostDirectory), bootID: UUID(), execute: execute)
        await hostDispatcher.pollOnce(bindings: [binding])
        let clientA = try SharedAgentHandoffController(identity: a.identity, transport: liveA, directory: root.appendingPathComponent("client-a"))
        let clientB = try SharedAgentHandoffController(identity: b.identity, transport: liveB, directory: root.appendingPathComponent("client-b"))
        await clientA.refresh(object: object.id); await clientA.offer(to: b.identity.person)
        await clientB.refresh(object: object.id); await clientB.acceptOffer()
        try retentionRecoveryExpect(clientB.control?.controller == b.identity.person, "B holds control through the real handoff routes")

        // The host is offline when B sends; the relay records it, nothing runs.
        await clientB.send(text: "Run while the host sleeps.", context: context.id)
        guard let first = clientB.receipt else { throw RetentionRecoveryFailure(message: "first prompt not saved") }
        try retentionRecoveryExpect(first.phase == .queued && executions.isEmpty
                && SharedAgentHandoffController.receiptMessage(first.phase).contains("has not accepted"),
            "the relay receipt is queued, never reported as execution")
        clock.advance(window + 1)
        await hostDispatcher.pollOnce(bindings: [binding])
        let expired = try await bb.agentDispatchReceipt(area: area, id: first.command.id)
        try retentionRecoveryExpect(executions.isEmpty && expired.phase == .refused,
            "a request that outlives its authority window is refused when the host returns, not executed")
        let firstRequest = Collaboration.AgentPromptRequest(id: first.command.id, epoch: first.command.epoch,
            controlRevision: first.command.controlRevision, hostGeneration: first.command.hostGeneration,
            contextRevision: context.id, text: first.command.text, mode: first.command.mode)
        let retried = try await bb.sendAgentPrompt(area: area, object: object.id.rawValue, request: firstRequest)
        await hostDispatcher.pollOnce(bindings: [binding])
        try retentionRecoveryExpect(retried.phase == .refused && executions.isEmpty,
            "retrying the expired request's exact identity returns its refusal, never a fresh queue entry")

        // Reconfirmation is a new request under current authority.
        await clientB.refresh(object: object.id)
        await clientB.send(text: "Reconfirmed after the window.", context: context.id)
        guard let reconfirmed = clientB.receipt, reconfirmed.command.id != first.command.id else { throw RetentionRecoveryFailure(message: "reconfirmation absent") }
        await hostDispatcher.pollOnce(bindings: [binding])
        let accepted = try await bb.agentDispatchReceipt(area: area, id: reconfirmed.command.id)
        try retentionRecoveryExpect(executions == [reconfirmed.command.id] && accepted.phase == .accepted,
            "a reconfirmed request inside the window executes once through the host adapter")

        // Claimed but never admitted: the window still applies.
        await clientB.send(text: "Claimed, then the host vanished.", context: context.id)
        guard let claimedOnly = clientB.receipt else { throw RetentionRecoveryFailure(message: "claim fixture absent") }
        let journal = try SharedAgentHostJournal(directory: hostDirectory)
        let prepared = try journal.prepare(claimedOnly.command)
        _ = try await aa.claimAgentDispatch(area: area, id: claimedOnly.command.id,
            claim: .init(claimID: prepared.claimID, hostGeneration: claimedOnly.command.hostGeneration))
        clock.advance(window + 1)
        await hostDispatcher.pollOnce(bindings: [binding])
        let claimedReceipt = try await bb.agentDispatchReceipt(area: area, id: claimedOnly.command.id)
        try retentionRecoveryExpect(claimedReceipt.phase == .refused && executions.count == 1,
            "a claimed request not admitted within the window expires instead of executing")

        // An attempt already past admission is the host's record: never rewritten.
        await clientB.send(text: "Attempt interrupted inside the provider.", context: context.id)
        guard let attempted = clientB.receipt else { throw RetentionRecoveryFailure(message: "attempt fixture absent") }
        let attempt = try journal.prepare(attempted.command)
        let claim = Collaboration.AgentHostClaim(claimID: attempt.claimID, hostGeneration: attempted.command.hostGeneration)
        _ = try await aa.claimAgentDispatch(area: area, id: attempted.command.id, claim: claim)
        _ = try journal.beginAttempt(attempt, bootID: UUID())
        _ = try await aa.admitAgentDispatch(area: area, id: attempted.command.id, claim: claim)
        clock.advance(window + 1)
        let stillDispatching = try await bb.agentDispatchReceipt(area: area, id: attempted.command.id)
        await hostDispatcher.pollOnce(bindings: [binding])
        let recovered = try await bb.agentDispatchReceipt(area: area, id: attempted.command.id)
        try retentionRecoveryExpect(stillDispatching.phase == .dispatching && recovered.phase == .uncertain && executions.count == 1,
            "expiry never rewrites an admitted attempt; the host reports honest uncertainty and replays nothing")

        // Current membership, not the window, decides a fresh request too.
        await clientB.refresh(object: object.id)
        await clientB.send(text: "Queued before B is removed.", context: context.id)
        guard let removedLater = clientB.receipt else { throw RetentionRecoveryFailure(message: "membership fixture absent") }
        try await aa.removeMember(area: area, person: b.identity.person.rawValue, epoch: 1)
        await hostDispatcher.pollOnce(bindings: [binding])
        let revokedReceipt = try await aa.agentDispatchReceipt(area: area, id: removedLater.command.id)
        try retentionRecoveryExpect(revokedReceipt.phase == .refused && executions.count == 1,
            "a request inside the window is still refused once its requester loses membership")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
}
