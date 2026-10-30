import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

private struct PublicationSubmissionFailure: Error { let message: String }
private func publicationSubmissionExpect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PublicationSubmissionFailure(message: message) }
    print("PASS: \(message)")
}

private final class PublicationSubmissionVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}

private actor PublicationSubmissionConnection: SharedAreaControllerConnection {
    private let stream: AsyncStream<CollaborationSession.Status>
    private let continuation: AsyncStream<CollaborationSession.Status>.Continuation
    init() {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func start() async -> AsyncStream<CollaborationSession.Status> { stream }
    func stop() async { continuation.finish() }
    func emit(_ state: Collaboration.State) throws { continuation.yield(.connected(try CollaborationReplica(state: state))) }
}

private actor PublicationSubmissionTransport: SharedAreaControllerTransport {
    let connectionValue = PublicationSubmissionConnection()
    let identityValue: Collaboration.Identity
    private var stateValue: Collaboration.State
    private let beforeApply: @Sendable () throws -> Void
    private var loseNextReply: Bool
    private let replyRevisionOverride: UInt64?
    private(set) var commands: [SharedArea.Command] = []
    init(identity: Collaboration.Identity, state: Collaboration.State, loseNextReply: Bool = true, replyRevisionOverride: UInt64? = nil,
         beforeApply: @escaping @Sendable () throws -> Void) {
        identityValue = identity; stateValue = state; self.beforeApply = beforeApply
        self.loseNextReply = loseNextReply; self.replyRevisionOverride = replyRevisionOverride
    }
    func identity() async throws -> Collaboration.Identity { identityValue }
    func state() async throws -> Collaboration.State { stateValue }
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { connectionValue }
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        try beforeApply()
        commands.append(mutation.command)
        var document = stateValue.document
        let result = try document.apply(mutation.command)
        stateValue = .init(scope: stateValue.scope, document: document)
        if loseNextReply { loseNextReply = false; throw URLError(.networkConnectionLost) }
        switch result {
        case .applied(let revision): return .init(revision: replyRevisionOverride ?? revision, duplicate: false)
        case .duplicate(let revision): return .init(revision: replyRevisionOverride ?? revision, duplicate: true)
        }
    }
    func remove(_ object: SharedArea.ID<SharedArea.Object>) throws {
        var document = stateValue.document
        try document.apply(.init(area: document.id, expectedRevision: document.revision, edits: [.remove(object)]))
        stateValue = .init(scope: stateValue.scope, document: document)
    }
}

@MainActor
func runSharedAreaPublicationSubmissionChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-publication-submit-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://publication-submit.example.test")!)
    let identity = Collaboration.Identity(person: .init(), device: UUID()), area = SharedArea.ID<SharedArea.Area>()
    let host = SharedArea.ID<SharedArea.Host>()
    let project = UUID()
    let source = SharedAreaPublication.SourceTile(projectID: project,
        tile: .init(id: UUID(), kind: .managedAgent, title: "Private source", frame: .init(x: 120, y: 240, width: 640, height: 480),
            zPosition: .fromLegacyRank(0), zoneId: UUID(), runtimeRef: nil, metadata: .init()), agentID: .init(rawValue: UUID()))
    let inventory = SharedAreaPublication.Inventory(workspaceID: UUID(), coverage: .completeWorkspace, sources: [source])
    let choices: [SharedAreaPublication.Choice] = [.init(source: source.key, content: .agentObservation)]
    func confirmed(author: SharedArea.ID<SharedArea.Person>, targetArea: SharedArea.ID<SharedArea.Area>) throws -> SharedAreaPublication.Confirmed {
        let review = try SharedAreaPublication.prepare(inventory: inventory, selection: .workspace, choices: choices,
            area: targetArea, author: author, host: host, expectedRevision: 0)
        return try SharedAreaPublication.confirm(review, expectedDigest: review.digest, inventory: inventory, choices: choices)
    }
    let publication = try confirmed(author: identity.person, targetArea: area)
    let store = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil,
        endpoint: endpoint, person: identity.person, area: area)
    let original = SharedArea.Document(id: area)
    let camera = SharedAreaLocalView(x: 37, y: -51, zoom: 1.25)
    let draft = SharedAreaLocalDraft(text: "private-source-review-draft")
    try store.save(.init(scope: store.scope, document: original, observedMembershipEpoch: 1, view: camera, drafts: [draft]))
    let fixture = PublicationSubmissionTransport(identity: identity,
        state: .init(scope: .init(area: area, epoch: 1, role: .owner), document: original), beforeApply: {
            let retained = try store.load()
            guard retained?.sourceBindings == publication.sourceBindings else {
                throw PublicationSubmissionFailure(message: "transport ran before private binding retention")
            }
        })
    let credentials = CollaborationCredentialStore(vault: PublicationSubmissionVault(), bundleIdentifier: nil)
    let credentialScope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
    try credentials.save(.init(identity: identity, token: "fixture-publication-token"), for: credentialScope)
    let controller = try SharedAreaController(localStore: store, credentialStore: credentials, credentialScope: credentialScope,
        bundleIdentifier: nil, transportFactory: { _, _, _ in fixture })

    let offline = await controller.submitPublication(publication)
    if case .rejected(.notConnected) = offline {} else { throw PublicationSubmissionFailure(message: "cached publication could send") }
    try publicationSubmissionExpect(try store.load()?.sourceBindings.isEmpty == true,
        "cached publication retains no source grant or binding before online admission")
    await controller.open()
    let otherAuthor = try confirmed(author: .init(), targetArea: area)
    let otherArea = try confirmed(author: identity.person, targetArea: .init())
    for invalid in [otherAuthor, otherArea] {
        if case .rejected(.forbidden) = await controller.submitPublication(invalid) {} else {
            throw PublicationSubmissionFailure(message: "publication crossed author/area scope")
        }
    }
    let commandsBeforePublish = await fixture.commands
    try publicationSubmissionExpect(commandsBeforePublish.isEmpty && (try store.load()?.sourceBindings.isEmpty == true),
        "wrong author or area cannot persist private bindings or reach transport")

    let beforeFault = try Data(contentsOf: store.layout.stateFile)
    StoreFileWriter.install(.init(fault: .failWrite(1), scope: root))
    let failed = await controller.submitPublication(publication)
    _ = StoreFileWriter.uninstall()
    if case .rejected(.localPersistence) = failed {} else { throw PublicationSubmissionFailure(message: "preflight local save failure was not explicit") }
    try publicationSubmissionExpect(await fixture.commands.isEmpty, "failed source-binding save refuses publication before any remote effect")
    try publicationSubmissionExpect(try Data(contentsOf: store.layout.stateFile) == beforeFault,
        "failed source-binding commit preserves the prior complete cache generation")

    let uncertain = await controller.submitPublication(publication)
    if case .uncertain(let operation) = uncertain {
        try publicationSubmissionExpect(operation == publication.command.id, "lost publication reply retains its exact operation identity")
    } else { throw PublicationSubmissionFailure(message: "accepted lost reply was reported as certain") }
    let pending = try store.load()!
    try publicationSubmissionExpect(pending.sourceBindings == publication.sourceBindings && pending.appliedRevision == 0
        && pending.resolution(for: publication.sourceBindings[0].object) == .unavailable,
        "unknown publication retains private source IDs without falsely advancing a cursor or resolving an unadmitted object")
    let acceptedState = try await fixture.state()
    try await fixture.connectionValue.emit(acceptedState)
    let firstDeadline = ContinuousClock.now + .seconds(3)
    while controller.document?.revision != 1 && ContinuousClock.now < firstDeadline { await Task.yield() }
    let accepted = try store.load()!
    try publicationSubmissionExpect(accepted.appliedRevision == 1 && accepted.sourceBindings == publication.sourceBindings
        && accepted.view == camera && accepted.drafts == [draft]
        && accepted.resolution(for: publication.sourceBindings[0].object) == .localReference(publication.sourceBindings[0]),
        "accepted publication persists source binding and actual cursor together while preserving private camera and drafts")

    let retry = await controller.submitPublication(publication)
    if case .accepted(let receipt) = retry {
        try publicationSubmissionExpect(receipt.duplicate && receipt.revision == 1, "explicit identical publication retry recovers the original accepted receipt")
    } else { throw PublicationSubmissionFailure(message: "publication receipt recovery failed") }
    try await fixture.remove(publication.sourceBindings[0].object)
    let removedState = try await fixture.state()
    try await fixture.connectionValue.emit(removedState)
    let secondDeadline = ContinuousClock.now + .seconds(3)
    while controller.document?.revision != 2 && ContinuousClock.now < secondDeadline { await Task.yield() }
    let removedRetry = await controller.submitPublication(publication)
    if case .accepted(let receipt) = removedRetry {
        try publicationSubmissionExpect(receipt.duplicate && receipt.revision == 1 && controller.document?.revision == 2,
            "receipt recovery after source removal never resurrects the object or regresses its cursor")
    } else { throw PublicationSubmissionFailure(message: "removed publication could not recover its old receipt") }
    let sent = await fixture.commands
    try publicationSubmissionExpect(sent.count == 3 && sent.allSatisfy { $0 == publication.command },
        "unknown recovery always sends the same confirmed command and opaque publication identities")
    await controller.close()

    let viewerStore = try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent("viewer"), bundleIdentifier: nil,
        endpoint: endpoint, person: identity.person, area: area)
    let viewerTransport = PublicationSubmissionTransport(identity: identity,
        state: .init(scope: .init(area: area, epoch: 1, role: .viewer), document: original), beforeApply: {
            throw PublicationSubmissionFailure(message: "viewer publication reached transport")
        })
    let viewer = try SharedAreaController(localStore: viewerStore, credentialStore: credentials, credentialScope: credentialScope,
        bundleIdentifier: nil, transportFactory: { _, _, _ in viewerTransport })
    await viewer.open()
    let viewerResult = await viewer.submitPublication(publication)
    if case .rejected(.forbidden) = viewerResult {} else { throw PublicationSubmissionFailure(message: "viewer publication was not refused") }
    let viewerCommands = await viewerTransport.commands
    try publicationSubmissionExpect(viewerCommands.isEmpty && (try viewerStore.load()?.sourceBindings.isEmpty == true),
        "current viewer membership cannot retain source bindings or publish a confirmed capture")
    await viewer.close()

    let invalidReceiptStore = try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent("invalid-receipt"), bundleIdentifier: nil,
        endpoint: endpoint, person: identity.person, area: area)
    let invalidReceiptTransport = PublicationSubmissionTransport(identity: identity,
        state: .init(scope: .init(area: area, epoch: 1, role: .owner), document: original),
        loseNextReply: false, replyRevisionOverride: 0, beforeApply: {})
    let invalidReceiptController = try SharedAreaController(localStore: invalidReceiptStore, credentialStore: credentials,
        credentialScope: credentialScope, bundleIdentifier: nil, transportFactory: { _, _, _ in invalidReceiptTransport })
    await invalidReceiptController.open()
    let invalidReceiptResult = await invalidReceiptController.submitPublication(publication)
    if case .uncertain(let operation) = invalidReceiptResult {
        try publicationSubmissionExpect(operation == publication.command.id && invalidReceiptController.status == .unavailable(.incompatibleState)
            && (try invalidReceiptStore.load()?.appliedRevision == 0),
            "a mismatched acknowledgement cannot advance or bless the publication cursor")
    } else { throw PublicationSubmissionFailure(message: "malformed acknowledgement was accepted as a publication receipt") }
    await invalidReceiptController.close()
    print("Publication submission checks passed: scoped admission, binding-before-effect refusal, lost-reply identity, atomic accepted cache and removal-safe receipt recovery; no durable outbox claim.")
}
