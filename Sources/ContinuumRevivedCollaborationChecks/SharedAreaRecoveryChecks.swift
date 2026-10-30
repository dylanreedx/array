import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

private struct RecoveryFailure: Error { let message: String }
private func recoveryExpect(_ value: Bool, _ message: String) throws {
    guard value else { throw RecoveryFailure(message: message) }
    print("PASS durable recovery: \(message)")
}
private final class RecoveryVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private actor RecoveryConnection: SharedAreaControllerConnection {
    private let pair = AsyncStream<CollaborationSession.Status>.makeStream()
    func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
    func stop() async { pair.continuation.finish() }
}
private actor RecoveryAuthority: SharedAreaControllerTransport {
    enum Behavior: Equatable, Sendable { case accept, loseBeforeCommit, loseAfterCommit, timeoutAfterCommit, staleEpoch, forbidden }
    let identityValue: Collaboration.Identity
    var document: SharedArea.Document
    var epoch: Int64 = 1
    var role: Collaboration.Role = .owner
    var revoked = false
    var behavior: Behavior = .accept
    var requests: [SharedArea.Command] = []
    let beforeEffect: @Sendable (SharedArea.Command) throws -> Void
    init(identity: Collaboration.Identity, document: SharedArea.Document,
         beforeEffect: @escaping @Sendable (SharedArea.Command) throws -> Void = { _ in }) {
        identityValue = identity; self.document = document; self.beforeEffect = beforeEffect
    }
    func identity() async throws -> Collaboration.Identity { identityValue }
    func state() async throws -> Collaboration.State {
        guard !revoked else { throw CollaborationClientError.server(status: 404, code: "notFound") }
        return .init(scope: .init(area: document.id, epoch: epoch, role: role), document: document)
    }
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { RecoveryConnection() }
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        requests.append(mutation.command)
        try beforeEffect(mutation.command)
        guard !revoked else { throw CollaborationClientError.server(status: 404, code: "notFound") }
        guard mutation.epoch == epoch else { throw CollaborationClientError.server(status: 409, code: "staleEpoch") }
        guard role != .viewer else { throw CollaborationClientError.server(status: 403, code: "forbidden") }
        switch behavior {
        case .loseBeforeCommit: behavior = .accept; throw URLError(.networkConnectionLost)
        case .staleEpoch: behavior = .accept; epoch += 1; throw CollaborationClientError.server(status: 409, code: "staleEpoch")
        case .forbidden: throw CollaborationClientError.server(status: 403, code: "forbidden")
        case .accept, .loseAfterCommit, .timeoutAfterCommit: break
        }
        let result = try document.apply(mutation.command)
        if behavior == .loseAfterCommit { behavior = .accept; throw URLError(.networkConnectionLost) }
        if behavior == .timeoutAfterCommit { behavior = .accept; throw CollaborationClientError.server(status: 408, code: "cancelled") }
        switch result {
        case .applied(let revision): return .init(revision: revision, duplicate: false)
        case .duplicate(let revision): return .init(revision: revision, duplicate: true)
        }
    }
    func setBehavior(_ value: Behavior) { behavior = value }
    func setRevoked(_ value: Bool) { revoked = value; epoch += 1 }
    func setViewer() { role = .viewer; epoch += 1 }
    func changeEpoch() { epoch += 1 }
    func applyOther(_ command: SharedArea.Command) throws { try document.apply(command) }
}

/// Reconstructs controllers/stores at real atomic-file boundaries. The paired
/// process harness separately kills/relaunches actual Array processes.
@MainActor
func runSharedAreaRecoveryChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-durable-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://recovery.example.test")!)
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    let credentials = CollaborationCredentialStore(vault: RecoveryVault(), bundleIdentifier: nil)
    let credentialScope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
    try credentials.save(.init(identity: identity, token: "synthetic-recovery-credential"), for: credentialScope)
    let discussion = SharedArea.Item(id: .init(), kind: .discussion)
    var initial = SharedArea.Document()
    try initial.apply(.init(area: initial.id, expectedRevision: 0, edits: [
        .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: -320, y: 70, width: 260, height: 180)))
    ]))
    func store(_ name: String) throws -> SharedAreaLocalStore {
        try .init(applicationSupportRoot: root.appendingPathComponent(name), bundleIdentifier: nil,
                  endpoint: endpoint, person: identity.person, area: initial.id)
    }
    func controller(_ store: SharedAreaLocalStore, _ authority: RecoveryAuthority) throws -> SharedAreaController {
        try .init(localStore: store, credentialStore: credentials, credentialScope: credentialScope,
                  bundleIdentifier: nil, transportFactory: { _, _, _ in authority })
    }
    func command(_ text: String, id: SharedArea.ID<SharedArea.Operation> = .init()) -> SharedArea.Command {
        .init(area: initial.id, id: id, expectedRevision: initial.revision,
              edits: [.post(.init(id: .init(), object: discussion.id, author: identity.person, text: text))])
    }
    let before = try store("before-commit")
    let draft = SharedAreaLocalDraft(object: discussion.id, text: "unsent exact prompt")
    let movedDraft = SharedAreaLocalDraft(id: draft.id, object: discussion.id, text: "newer private edit after network loss")
    try before.save(.init(scope: before.scope, document: initial, observedMembershipEpoch: 1,
        view: .init(x: 43, y: -81, zoom: 1.2), drafts: [draft]))
    let proposal = command("durable original intent")
    let authority = RecoveryAuthority(identity: identity, document: initial) { value in
        let state = try before.load()
        guard let retained = state?.operations.first(where: { $0.command.id == value.id }),
              retained.command == value, retained.isPending, retained.attempts > 0 else {
            throw RecoveryFailure(message: "transport began before an exact durable outbox record")
        }
    }
    let original = try controller(before, authority)
    await original.open()
    let bytesBeforeFault = try Data(contentsOf: before.layout.stateFile)
    StoreFileWriter.install(.init(fault: .failWrite(1), scope: root))
    let fault = await original.submit(proposal)
    _ = StoreFileWriter.uninstall()
    if case .rejected(.localPersistence) = fault {} else { throw RecoveryFailure(message: "failed outbox write was admitted") }
    try recoveryExpect(await authority.requests.isEmpty && Data(contentsOf: before.layout.stateFile) == bytesBeforeFault,
        "outbox write failure preserves complete cache bytes and refuses every remote effect")
    await authority.setBehavior(.loseBeforeCommit)
    let lost = await original.submit(proposal, preserving: draft)
    if case .uncertain(let operation) = lost { try recoveryExpect(operation == proposal.id, "pre-commit disconnect retains original operation ID") }
    else { throw RecoveryFailure(message: "pre-commit disconnect was called certain") }
    let retained = try before.load()!
    try recoveryExpect(retained.operations.first?.command == proposal && retained.operations.first?.preservedDraft == draft
        && retained.operations.first?.attempts == 1 && original.pendingOperations.count == 1 && !original.canSubmit,
        "exact command, draft and attempt boundary are durable and block allocation of another mutation")
    try original.saveDraft(movedDraft)
    await original.close()
    await authority.changeEpoch()
    let restarted = try controller(try store("before-commit"), authority)
    try recoveryExpect(restarted.pendingOperations.first?.command == proposal && !restarted.canSubmit,
        "fresh controller reconstructs exact pending intent without offline authority")
    await restarted.open()
    let attempts = await authority.requests
    try recoveryExpect(attempts.count == 2 && attempts.allSatisfy { $0 == proposal }
        && restarted.pendingOperations.isEmpty && restarted.deliveryRecord(for: proposal.id)?.state == .accepted(2)
        && restarted.document?.posts.filter { $0.text == "durable original intent" }.count == 1,
        "relaunch revalidates the new epoch and sends the identical data intent exactly once in the document")
    try recoveryExpect(restarted.drafts == [movedDraft] && restarted.view.x == 43 && restarted.view.y == -81,
        "recovery preserves a newer private draft and independent camera")
    await restarted.close()

    let after = try store("after-commit")
    let committed = command("committed with lost reply")
    let afterAuthority = RecoveryAuthority(identity: identity, document: initial)
    let first = try controller(after, afterAuthority)
    await first.open(); await afterAuthority.setBehavior(.loseAfterCommit)
    if case .uncertain = await first.submit(committed) {} else { throw RecoveryFailure(message: "lost acknowledgement was called certain") }
    await first.close()
    let second = try controller(try store("after-commit"), afterAuthority)
    await second.open()
    try recoveryExpect(await afterAuthority.requests.count == 1 && second.pendingOperations.isEmpty
        && second.deliveryRecord(for: committed.id)?.state == .accepted(2) && second.document?.posts.count == 1,
        "authenticated retained receipt resolves a post-commit crash without resending or duplicating content")
    await second.close()

    let epochStore = try store("epoch-refresh")
    let epochAuthority = RecoveryAuthority(identity: identity, document: initial)
    let epochController = try controller(epochStore, epochAuthority)
    await epochController.open(); await epochAuthority.setBehavior(.staleEpoch)
    let epochCommand = command("same intent after epoch refresh")
    if case .uncertain(let operation) = await epochController.submit(epochCommand) {
        try recoveryExpect(operation == epochCommand.id, "a stale epoch preserves its exact pending operation")
    } else { throw RecoveryFailure(message: "stale epoch was finalized as revision conflict") }
    let deadline = ContinuousClock.now + .seconds(3)
    while epochController.deliveryRecord(for: epochCommand.id)?.state != .accepted(2), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let epochRequests = await epochAuthority.requests
    try recoveryExpect(epochRequests.count == 2 && epochRequests.allSatisfy { $0 == epochCommand }
        && epochController.scope?.epoch == 2 && epochController.deliveryRecord(for: epochCommand.id)?.state == .accepted(2),
        "online epoch refresh retries the identical ID without rebasing or discarding its intent")
    await epochController.close()

    let timeoutStore = try store("timeout-after-commit")
    let timeoutAuthority = RecoveryAuthority(identity: identity, document: initial)
    let timeoutController = try controller(timeoutStore, timeoutAuthority)
    await timeoutController.open(); await timeoutAuthority.setBehavior(.timeoutAfterCommit)
    let timedOut = command("committed before HTTP timeout")
    if case .uncertain = await timeoutController.submit(timedOut) {} else { throw RecoveryFailure(message: "HTTP timeout falsely finalized commit outcome") }
    await timeoutAuthority.setBehavior(.forbidden)
    if case .uncertain = await timeoutController.retryPending(timedOut.id) {} else { throw RecoveryFailure(message: "later forbidden claimed an uncertain prior request did not commit") }
    try recoveryExpect(timeoutController.pendingOperations.first?.command == timedOut,
        "HTTP timeout and a later forbidden response preserve exact unknown outcome")
    await timeoutController.close()
    let timeoutRestart = try controller(try store("timeout-after-commit"), timeoutAuthority)
    await timeoutRestart.open()
    try recoveryExpect(await timeoutAuthority.requests.count == 2
        && timeoutRestart.deliveryRecord(for: timedOut.id)?.state == .accepted(2),
        "a retained authoritative receipt resolves a timeout plus later permission denial without another effect")
    await timeoutRestart.close()

    let publicationStore = try store("publication")
    let source = SharedAreaPublication.SourceTile(projectID: UUID(),
        tile: .init(id: UUID(), kind: .managedAgent, title: "Private recovery source",
            frame: .init(x: -80, y: 120, width: 320, height: 260), zPosition: .fromLegacyRank(0),
            zoneId: UUID(), runtimeRef: nil, metadata: .init()), agentID: .init(rawValue: UUID()))
    let sourceInventory = SharedAreaPublication.Inventory(workspaceID: UUID(), coverage: .completeWorkspace, sources: [source])
    let choices: [SharedAreaPublication.Choice] = [.init(source: source.key, content: .agentObservation)]
    let review = try SharedAreaPublication.prepare(inventory: sourceInventory, selection: .workspace, choices: choices,
        area: initial.id, author: identity.person, host: .init(), expectedRevision: initial.revision)
    let confirmed = try SharedAreaPublication.confirm(review, expectedDigest: review.digest, inventory: sourceInventory, choices: choices)
    let publishingAuthority = RecoveryAuthority(identity: identity, document: initial) { value in
        guard let saved = try publicationStore.load(), let operation = saved.operations.first(where: { $0.command.id == value.id }),
              operation.sourceBindings == confirmed.sourceBindings, saved.sourceBindings == confirmed.sourceBindings,
              operation.publication?.reviewDigest == confirmed.reviewDigest else {
            throw RecoveryFailure(message: "publication lost its private binding or reviewed identity before transport")
        }
    }
    let publisher = try controller(publicationStore, publishingAuthority)
    await publisher.open(); await publishingAuthority.setBehavior(.loseBeforeCommit)
    if case .uncertain = await publisher.submitPublication(confirmed) {} else { throw RecoveryFailure(message: "unacknowledged publication was lost") }
    await publisher.close()
    let restoredPublisher = try controller(try store("publication"), publishingAuthority)
    await restoredPublisher.open()
    let publishedRequests = await publishingAuthority.requests
    try recoveryExpect(publishedRequests.count == 2 && publishedRequests.allSatisfy { $0 == confirmed.command }
        && restoredPublisher.pendingOperations.isEmpty && restoredPublisher.sourceBindings == confirmed.sourceBindings
        && restoredPublisher.document?.items.contains(where: { $0.id == confirmed.sourceBindings[0].object }) == true,
        "cold publication recovery preserves reviewed IDs and source bindings without reconstructing source inventory")
    await restoredPublisher.close()

    let conflictStore = try store("conflict")
    let conflictAuthority = RecoveryAuthority(identity: identity, document: initial)
    let conflict = try controller(conflictStore, conflictAuthority)
    await conflict.open(); await conflictAuthority.setBehavior(.loseBeforeCommit)
    let obsolete = command("must never silently rebase")
    _ = await conflict.submit(obsolete, preserving: draft)
    await conflict.close()
    try await conflictAuthority.applyOther(command("teammate won the revision"))
    let stale = try controller(try store("conflict"), conflictAuthority)
    await stale.open()
    try recoveryExpect(await conflictAuthority.requests.count == 1 && stale.pendingOperations.isEmpty
        && stale.deliveryRecord(for: obsolete.id)?.state == .rejected(.conflict) && stale.drafts.contains(draft)
        && stale.document?.posts.map(\.text) == ["teammate won the revision"],
        "later authoritative revision proves obsolete intent absent, preserves draft and never rebases its ID")
    await stale.close()

    let revokedStore = try store("revoked")
    let revokedAuthority = RecoveryAuthority(identity: identity, document: initial)
    let admitted = try controller(revokedStore, revokedAuthority)
    await admitted.open(); await revokedAuthority.setBehavior(.loseBeforeCommit)
    let denied = command("unknown while access is removed")
    _ = await admitted.submit(denied, preserving: draft)
    await admitted.close(); await revokedAuthority.setRevoked(true)
    let deniedAgain = try controller(try store("revoked"), revokedAuthority)
    await deniedAgain.open()
    try recoveryExpect(deniedAgain.document == nil && !deniedAgain.canSubmit && deniedAgain.pendingOperations.first?.command == denied
        && deniedAgain.drafts.contains(draft) && (try revokedStore.load()?.accessDenied == true),
        "revocation suppresses shared content while retaining exact unknown intent and private draft across relaunch")
    try recoveryExpect(await revokedAuthority.requests.count == 1, "revoked recovery sends no mutation with cached authority")
    await deniedAgain.close()

    // Schema 2 remains readable without rewriting bytes; missing current outbox
    // and future schema both refuse, preserving the operator's recovery evidence.
    let legacy = try store("legacy")
    try legacy.save(.init(scope: legacy.scope, document: initial, observedMembershipEpoch: 1, drafts: [draft]))
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy.layout.stateFile)) as! [String: Any]
    object["schema"] = 2; object.removeValue(forKey: "operations")
    let legacyBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try legacyBytes.write(to: legacy.layout.stateFile)
    let migrated = try legacy.load()!
    try recoveryExpect(migrated.schema == 3 && migrated.operations.isEmpty && migrated.drafts == [draft]
        && (try Data(contentsOf: legacy.layout.stateFile)) == legacyBytes,
        "schema-2 cache migration preserves original disk bytes until an atomic new save")
    let current = try legacy.save(migrated)
    object = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy.layout.stateFile)) as! [String: Any]
    object.removeValue(forKey: "operations")
    let damaged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try damaged.write(to: legacy.layout.stateFile)
    do { _ = try legacy.load(); throw RecoveryFailure(message: "missing current outbox was treated empty") }
    catch SharedAreaLocalStoreError.corruptState {}
    try recoveryExpect(try Data(contentsOf: legacy.layout.stateFile) == damaged, "missing current outbox refuses without discarding recovery bytes")
    object["schema"] = 999
    let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try future.write(to: legacy.layout.stateFile)
    do { _ = try legacy.load(); throw RecoveryFailure(message: "future outbox schema was adopted") }
    catch SharedAreaLocalStoreError.unsupportedSchema {}
    try recoveryExpect(try Data(contentsOf: legacy.layout.stateFile) == future && current.localGeneration > migrated.localGeneration,
        "future schema refusal preserves the previous complete recovery record")
    print("Durable recovery checks passed: cache-before-effect, cold reconstruction, exact retry/receipt reconciliation, current epoch, conflicts/revocation, draft/camera preservation and schema refusal.")
}
