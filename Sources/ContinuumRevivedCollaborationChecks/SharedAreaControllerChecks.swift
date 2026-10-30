import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

private struct ControllerCheckFailure: Error { let message: String }
private func controllerExpect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ControllerCheckFailure(message: message) }
    print("PASS: \(message)")
}
@MainActor private func controllerEventually(_ condition: @MainActor () -> Bool, _ message: String) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ControllerCheckFailure(message: message)
}
private final class ControllerMemoryVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? {
        lock.withLock { data[service + ":" + account] }
    }
    func write(_ value: Data, service: String, account: String) throws {
        lock.withLock { data[service + ":" + account] = value }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { data.removeValue(forKey: service + ":" + account) }
    }
}
private actor ControllerIdentityGate {
    private var continuation: CheckedContinuation<Collaboration.Identity, Never>?
    private var result: Collaboration.Identity?
    func wait() async -> Collaboration.Identity {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: Collaboration.Identity) {
        result = value; continuation?.resume(returning: value); continuation = nil
    }
}
private actor ControllerStopGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
private actor ControllerFixtureConnection: SharedAreaControllerConnection {
    private let stream: AsyncStream<CollaborationSession.Status>
    private let continuation: AsyncStream<CollaborationSession.Status>.Continuation
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var completedStops = 0
    private var stopGate: ControllerStopGate?
    init() {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func start() async -> AsyncStream<CollaborationSession.Status> { starts += 1; return stream }
    func stop() async {
        stops += 1
        if let stopGate { await stopGate.wait() }
        continuation.finish(); completedStops += 1
    }
    func emit(_ value: CollaborationSession.Status) { continuation.yield(value) }
    func holdStop(_ gate: ControllerStopGate) { stopGate = gate }
}
private actor ControllerFixtureTransport: SharedAreaControllerTransport {
    enum ApplyBehavior: Sendable { case accept, conflict, forbidden, uncertain }
    let identityValue: Collaboration.Identity
    let fixtureConnection = ControllerFixtureConnection()
    private var stateValue: Collaboration.State
    private var gate: ControllerIdentityGate?
    private var behavior: ApplyBehavior = .accept
    private(set) var identityRequests = 0
    private(set) var stateRequests = 0
    private(set) var applyRequests = 0
    init(identity: Collaboration.Identity, state: Collaboration.State, gate: ControllerIdentityGate? = nil) {
        identityValue = identity; stateValue = state; self.gate = gate
    }
    func identity() async throws -> Collaboration.Identity {
        identityRequests += 1
        if let gate { return await gate.wait() }
        return identityValue
    }
    func state() async throws -> Collaboration.State { stateRequests += 1; return stateValue }
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { fixtureConnection }
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        applyRequests += 1
        switch behavior {
        case .conflict: throw CollaborationClientError.server(status: 409, code: "conflict")
        case .forbidden: throw CollaborationClientError.server(status: 403, code: "forbidden")
        case .uncertain: throw URLError(.networkConnectionLost)
        case .accept:
            var document = stateValue.document
            let result = try document.apply(mutation.command)
            stateValue = .init(scope: stateValue.scope, document: document)
            switch result {
            case .applied(let revision): return .init(revision: revision, duplicate: false)
            case .duplicate(let revision): return .init(revision: revision, duplicate: true)
            }
        }
    }
    func setBehavior(_ value: ApplyBehavior) { behavior = value }
    func setState(_ value: Collaboration.State) { stateValue = value }
    func replica() throws -> CollaborationReplica { try .init(state: stateValue) }
}

@MainActor
func runSharedAreaControllerChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-controller-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://collaboration-controller.example.test")!)
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    let area = SharedArea.ID<SharedArea.Area>()
    let discussion = SharedArea.Item(id: .init(), kind: .discussion)
    var original = SharedArea.Document(id: area)
    try original.apply(.init(area: area, expectedRevision: 0, edits: [
        .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 0, y: 0, width: 640, height: 480)))
    ]))
    let ownerScope = Collaboration.Scope(area: area, epoch: 1, role: .owner)
    let originalState = Collaboration.State(scope: ownerScope, document: original)
    let vault = ControllerMemoryVault()
    let credentials = CollaborationCredentialStore(vault: vault, bundleIdentifier: nil)
    let credentialScope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
    try credentials.save(.init(identity: identity, token: "fixture-only-collaboration-device-token"), for: credentialScope)

    func makeStore(_ name: String) throws -> SharedAreaLocalStore {
        let store = try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent(name), bundleIdentifier: nil,
            endpoint: endpoint, person: identity.person, area: area)
        try store.save(.init(scope: store.scope, document: original, observedMembershipEpoch: 1))
        return store
    }
    func makeController(_ store: SharedAreaLocalStore, _ fixture: ControllerFixtureTransport) throws -> SharedAreaController {
        try SharedAreaController(localStore: store, credentialStore: credentials, credentialScope: credentialScope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in fixture })
    }
    func postCommand(_ document: SharedArea.Document, text: String) -> SharedArea.Command {
        .init(area: area, expectedRevision: document.revision,
            edits: [.post(.init(id: .init(), object: discussion.id, author: identity.person, text: text))])
    }

    let source = root.appendingPathComponent("source/.array", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceFiles = ["canvas.json", "managed-agents.json", "lock"].map { source.appendingPathComponent($0) }
    let sourceBytes = sourceFiles.map { Data("source-state-sentinel-\($0.lastPathComponent)".utf8) }
    for (file, bytes) in zip(sourceFiles, sourceBytes) { try bytes.write(to: file) }

    let store = try makeStore("live")
    let fixture = ControllerFixtureTransport(identity: identity, state: originalState)
    let controller = try makeController(store, fixture)
    var changes = 0; controller.onChange = { changes += 1 }
    try controllerExpect(controller.status == .cached && controller.document == original
        && controller.scope == nil && !controller.canSubmit, "cached native document is visible without online mutation authority")
    let offlineCommand = postCommand(original, text: "must-not-send-offline")
    let offlineResult = await controller.submit(offlineCommand)
    if case .rejected(.notConnected) = offlineResult {} else { throw ControllerCheckFailure(message: "cached submit was admitted") }
    try controllerExpect(await fixture.applyRequests == 0, "a cached operation never reaches transport")
    let draft = SharedAreaLocalDraft(object: discussion.id, text: "private-controller-draft-sentinel")
    try controller.saveDraft(draft)
    try controller.setView(.init(x: 43, y: -105, zoom: 1.4, focusedObject: discussion.id))
    await controller.open()
    let verifiedIdentityRequests = await fixture.identityRequests
    try controllerExpect(controller.status == .connected && controller.canSubmit && verifiedIdentityRequests == 1,
        "native open verifies credential identity before granting current membership")
    let verifiedStateRequests = await fixture.stateRequests
    try controllerExpect(verifiedStateRequests == 1 && controller.scope?.role == .owner,
        "current area state supplies the online role")
    let connection = fixture.fixtureConnection
    let oldReplica = try CollaborationReplica(state: originalState)
    let beforePresenceGeneration = try store.load()!.localGeneration
    var presenceReplica = oldReplica
    let collaborator = Collaboration.Identity(person: .init(), device: UUID())
    try presenceReplica.receive(.init(scope: ownerScope, after: original.revision, through: original.revision,
        events: [], nextCursor: original.revision, presenceVersion: UUID(),
        presence: [.init(identity: collaborator, cursor: .init(x: 20, y: 30), viewport: nil,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000))], serverTime: Date(timeIntervalSince1970: 1_799_999_999)))
    await connection.emit(.connected(presenceReplica))
    try await controllerEventually({ controller.presence.count == 1 }, "presence update not delivered")
    try controllerExpect(try store.load()!.localGeneration == beforePresenceGeneration,
        "presence-only render updates do not rewrite or back up the durable cache")

    // An external local generation arrives before a durable service update.
    var external = try store.load()!
    let otherDraft = SharedAreaLocalDraft(text: "another-view-private-draft")
    external.drafts.append(otherDraft)
    _ = try store.save(external)
    var advanced = original
    try advanced.apply(postCommand(advanced, text: "accepted-remote-message"))
    let advancedState = Collaboration.State(scope: ownerScope, document: advanced)
    await fixture.setState(advancedState)
    await connection.emit(.connected(try CollaborationReplica(state: advancedState)))
    try await controllerEventually({ controller.document?.revision == advanced.revision }, "durable update not delivered")
    let advancedCache = try store.load()!
    try controllerExpect(advancedCache.document == advanced && advancedCache.appliedRevision == 2
        && advancedCache.view.x == 43 && advancedCache.view.y == -105 && advancedCache.drafts.contains(otherDraft)
        && advancedCache.drafts.contains(draft), "accepted replica persists atomically while preserving latest private camera and both drafts")

    let submitted = postCommand(advanced, text: "acknowledged-local-message")
    let accepted = await controller.submit(submitted, preserving: draft)
    if case .accepted(let receipt) = accepted { try controllerExpect(receipt.revision == 3, "native submit returns its admitted revision") }
    else { throw ControllerCheckFailure(message: "authorized native submit was not accepted") }
    try controllerExpect(controller.document?.revision == 3 && !controller.drafts.contains(draft)
        && controller.drafts.contains(otherDraft), "successful acknowledgement removes only its unchanged private draft")

    // This exact race is easy to miss with a single fast localhost client: the
    // independent live reader still has a page from before the submit ACK.
    await connection.emit(.connected(oldReplica))
    for _ in 0..<20 { await Task.yield() }
    let cacheAfterDelayedPage = try store.load()!
    try controllerExpect(controller.status == .connected && controller.document?.revision == 3
        && cacheAfterDelayedPage.appliedRevision == 3 && cacheAfterDelayedPage.accessDenied == false,
        "delayed pre-ack live page cannot regress or revoke a healthy acknowledged document")
    await connection.emit(.connected(try await fixture.replica()))
    for _ in 0..<20 { await Task.yield() }
    try controllerExpect(controller.status == .connected && controller.document?.revision == 3,
        "live reader catches up to the acknowledged document without replacing the source owner")

    // Another view can persist a later accepted document before this stream
    // reaches it. Preserve that newer cache and stay read-only until covered.
    var anotherView = try store.load()!
    var newest = anotherView.document
    let newestCommand = postCommand(newest, text: "another-view-accepted-message")
    try newest.apply(newestCommand)
    anotherView.document = newest; anotherView.view.x = 912
    _ = try store.save(anotherView)
    await connection.emit(.connected(try CollaborationReplica(state: advancedState)))
    try await controllerEventually({ controller.document?.revision == newest.revision }, "newer cache not retained")
    try controllerExpect(controller.status == .reconnecting && !controller.canSubmit && controller.view.x == 912,
        "a newer shared cache remains read-only until this connection covers its accepted cursor")
    let newestState = Collaboration.State(scope: ownerScope, document: newest)
    await fixture.setState(newestState)
    await connection.emit(.connected(try CollaborationReplica(state: newestState)))
    try await controllerEventually({ controller.status == .connected }, "connection did not cover newer cache")

    await fixture.setBehavior(.conflict)
    let rejectedDraft = SharedAreaLocalDraft(object: discussion.id, text: "conflicting-edit-retained")
    let conflict = await controller.submit(postCommand(newest, text: rejectedDraft.text), preserving: rejectedDraft)
    if case .rejected(.conflict) = conflict {} else { throw ControllerCheckFailure(message: "conflict was not explicit") }
    try controllerExpect(controller.drafts.contains(rejectedDraft) && controller.document == newest,
        "a service conflict leaves the local draft and accepted document intact")
    await fixture.setBehavior(.forbidden)
    let forbidden = await controller.submit(postCommand(newest, text: "object-permission-refusal"), preserving: rejectedDraft)
    if case .rejected(.forbidden) = forbidden {} else { throw ControllerCheckFailure(message: "403 was not reported as an operation refusal") }
    let cacheAfterForbidden = try store.load()!
    try controllerExpect(controller.status == .connected && controller.scope?.role == .owner
        && controller.document == newest && !cacheAfterForbidden.accessDenied && controller.drafts.contains(rejectedDraft),
        "a forbidden object mutation retains live membership, visible content and its private draft")
    await fixture.setBehavior(.uncertain)
    let uncertainCommand = postCommand(newest, text: "unknown-admission")
    let uncertain = await controller.submit(uncertainCommand, preserving: rejectedDraft)
    if case .uncertain(let operation) = uncertain {
        try controllerExpect(operation == uncertainCommand.id && controller.drafts.contains(rejectedDraft),
            "an uncertain request preserves the operation identity and private draft for explicit recovery")
    } else { throw ControllerCheckFailure(message: "network ambiguity was reported as certain") }

    let heldStop = ControllerStopGate()
    await connection.holdStop(heldStop)
    await connection.emit(.unavailable)
    try await controllerEventually({ controller.status == .unavailable(.accessDenied) }, "access removal not delivered")
    try controllerExpect(controller.document == nil && controller.scope == nil && controller.presence.isEmpty && !controller.canSubmit,
        "access loss removes visible shared content and every mutation capability")
    try controllerExpect(try store.load()!.accessDenied && controller.drafts.contains(rejectedDraft),
        "access-loss suppression persists without deleting private draft recovery")
    let reopened = try makeController(store, fixture)
    try controllerExpect(reopened.document == nil && reopened.status == .unavailable(.accessDenied),
        "reopening after access removal does not redisplay suppressed cached content")
    let sourceBytesAfter = try sourceFiles.map { try Data(contentsOf: $0) }
    try controllerExpect(changes > 0 && sourceBytesAfter == sourceBytes,
        "native controller emits UI changes while preserving every source project byte")
    await heldStop.waitUntilEntered()
    var closeFinished = false
    let closing = Task { await controller.close(); closeFinished = true }
    try await controllerEventually({ controller.status == .closed }, "close did not enter its scoped shutdown")
    let incompleteStops = await connection.completedStops
    try controllerExpect(!closeFinished && incompleteStops == 0,
        "close waits for an already-retired subscription whose stop is held")
    await heldStop.release()
    await closing.value
    let stopCount = await connection.completedStops
    try controllerExpect(closeFinished && controller.status == .closed && stopCount >= 1,
        "closing completes only after this view subscription has stopped")

    let wrongIdentity = Collaboration.Identity(person: .init(), device: UUID())
    let mismatchedFixture = ControllerFixtureTransport(identity: wrongIdentity, state: originalState)
    let mismatch = try makeController(makeStore("mismatch"), mismatchedFixture)
    await mismatch.open()
    let mismatchStateRequests = await mismatchedFixture.stateRequests
    let mismatchApplyRequests = await mismatchedFixture.applyRequests
    try controllerExpect(mismatch.status == .unavailable(.identityMismatch) && mismatch.document == nil
        && mismatchStateRequests == 0 && mismatchApplyRequests == 0,
        "a stored credential with another online identity cannot fetch an area or submit")

    let gate = ControllerIdentityGate()
    let delayedFixture = ControllerFixtureTransport(identity: identity, state: originalState, gate: gate)
    let delayed = try makeController(makeStore("delayed"), delayedFixture)
    let opening = Task { await delayed.open() }
    let identityDeadline = ContinuousClock.now + .seconds(3)
    while await delayedFixture.identityRequests == 0 && ContinuousClock.now < identityDeadline { await Task.yield() }
    try controllerExpect(await delayedFixture.identityRequests == 1, "scripted open is held at online identity verification")
    await delayed.close()
    await gate.release(identity)
    await opening.value
    let closedStateRequests = await delayedFixture.stateRequests
    try controllerExpect(delayed.status == .closed && delayed.document == nil && closedStateRequests == 0,
        "a late identity response after view closure cannot reopen content or fetch state")

    let viewerFixture = ControllerFixtureTransport(identity: identity,
        state: .init(scope: .init(area: area, epoch: 1, role: .viewer), document: original))
    let viewer = try makeController(makeStore("viewer"), viewerFixture)
    await viewer.open()
    let viewerResult = await viewer.submit(offlineCommand, preserving: draft)
    if case .rejected(.forbidden) = viewerResult {} else { throw ControllerCheckFailure(message: "viewer mutation not refused") }
    let viewerApplyRequests = await viewerFixture.applyRequests
    try controllerExpect(viewerApplyRequests == 0 && viewer.drafts.contains(draft),
        "viewer keeps a private draft without sending a prohibited mutation")
    await viewer.close()
    print("Shared area controller checks passed: online identity, read-only cache, scoped lifecycle, monotonic replay/ACK, private persistence and explicit outcomes; no runner or native scene claim.")
}
