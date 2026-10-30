import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private final class ControllerHTTPVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private func controllerHTTPCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw CheckFailure(label: label) }
    print("PASS controller HTTP: \(label)")
}
@MainActor
private func waitForController(_ label: String, _ predicate: () throws -> Bool) async throws {
    for _ in 0..<250 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CheckFailure(label: "controller timeout: \(label)")
}

/// This uses the production API/session/controller adapter against actual NIO
/// routes. All identities, credentials, projects and app support are disposable.
/// It does not stand in for mounting native views or measuring real runner counts.
@MainActor
func runSharedAreaControllerHTTPChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-controller-http-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source-project/.array", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let originalCanvas = Data("source-canvas-private-sentinel".utf8)
    let originalSession = Data("source-runner-private-sentinel".utf8)
    try originalCanvas.write(to: source.appendingPathComponent("canvas.json"))
    try originalSession.write(to: source.appendingPathComponent("managed-session.json"))
    let key = Data(repeating: 47, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    var controllers: [SharedAreaController] = []
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let endpoint = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
        let vault = ControllerHTTPVault()
        let credentials = CollaborationCredentialStore(vault: vault, bundleIdentifier: AppChannel.devBundleIdentifier)
        var accounts: [SharedArea.ID<SharedArea.Person>: CollaborationAccountController] = [:]
        func person(_ label: String) async throws -> Collaboration.Credential {
            let code = try await store.provisionPerson(label: label)
            let accountStore = try CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("account-\(UUID())"), bundleIdentifier: AppChannel.devBundleIdentifier)
            let model = try CollaborationAccountController(store: accountStore, credentialStore: credentials, bundleIdentifier: AppChannel.devBundleIdentifier)
            let account = try await model.enroll(endpoint: endpoint, code: code.code, deviceLabel: label, accountLabel: label)
            guard let credential = try credentials.load(for: .init(endpoint: endpoint, identity: account.identity)) else { throw CheckFailure(label: "actual HTTP enrollment did not persist a scoped credential") }
            accounts[credential.identity.person] = model
            return credential
        }
        let a = try await person("Participant A"), b = try await person("Participant B"), c = try await person("Excluded C")
        let apiA = try CollaborationAPI(baseURL: url, credential: a.token, allowsInsecureLoopback: true)
        let apiB = try CollaborationAPI(baseURL: url, credential: b.token, allowsInsecureLoopback: true)
        let accountA = accounts[a.identity.person]!, accountB = accounts[b.identity.person]!
        let created = try await accountA.createArea(label: "HTTP shared workspace"), area = created.document.id
        let invite = try await accountA.invite(area: area.rawValue, person: b.identity.person)
        _ = try await accountB.acceptInvitation(code: invite.code)
        let host = try await accountA.registerHost()
        try controllerHTTPCheck(accountA.activeAccount?.knownAreas.contains(where: { $0.id == area.rawValue }) == true
            && accountB.activeAccount?.knownAreas.contains(where: { $0.id == area.rawValue }) == true,
            "production account adapters enroll, create, invite, join and remember the actual HTTP workspace")
        let projectID = UUID(), workspaceID = UUID(), zoneID = UUID()
        var metadata = TileMetadata(filePath: source.path + "/private-host-content.swift")
        metadata.filesystemProjectId = projectID
        metadata.filesystemCheckoutRootPath = source.path
        let agentTile = Tile(id: UUID(), kind: .managedAgent, title: "private-host-title", frame: .init(x: 40, y: 80, width: 640, height: 480),
            zPosition: .fromLegacyRank(0), zoneId: zoneID, runtimeRef: .init(kind: .terminalSession, id: UUID()), metadata: metadata)
        let noteTile = Tile(id: UUID(), kind: .note, title: "private-note-title", frame: .init(x: 740, y: 80, width: 480, height: 480),
            zPosition: .fromLegacyRank(1), zoneId: zoneID, runtimeRef: nil, metadata: .init())
        let agentSource = SharedAreaPublication.SourceTile(projectID: projectID, tile: agentTile, agentID: .init(rawValue: UUID()))
        let noteSource = SharedAreaPublication.SourceTile(projectID: projectID, tile: noteTile, contentRevision: "captured-note-generation-1")
        let inventory = SharedAreaPublication.Inventory(workspaceID: workspaceID, coverage: .completeWorkspace, sources: [agentSource, noteSource])
        let choices: [SharedAreaPublication.Choice] = [.init(source: agentSource.key, content: .agentObservation),
            .init(source: noteSource.key, content: .discussion(text: "Reviewed starting discussion"))]
        let review = try SharedAreaPublication.prepare(inventory: inventory, selection: .workspace, choices: choices,
            area: area, author: a.identity.person, host: host, expectedRevision: 0)
        let confirmed = try SharedAreaPublication.confirm(review, expectedDigest: review.digest, inventory: inventory, choices: choices)
        func cache(_ credential: Collaboration.Credential, _ name: String) throws -> SharedAreaLocalStore {
            try credentials.save(credential, for: .init(endpoint: endpoint, identity: credential.identity))
            return try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent(name), bundleIdentifier: AppChannel.devBundleIdentifier,
                endpoint: endpoint, person: credential.identity.person, area: area)
        }
        func controller(_ credential: Collaboration.Credential, _ local: SharedAreaLocalStore) throws -> SharedAreaController {
            try .init(localStore: local, credentialStore: credentials, credentialScope: .init(endpoint: endpoint, identity: credential.identity),
                bundleIdentifier: AppChannel.devBundleIdentifier)
        }
        let localA = try cache(a, "support-a"), localB = try cache(b, "support-b"), localC = try cache(c, "support-c")
        _ = try localA.save(.init(scope: localA.scope, document: created.document, observedMembershipEpoch: created.scope.epoch))
        let owner = try controller(a, localA)
        controllers = [owner]
        await owner.open()
        let published = await owner.submitPublication(confirmed)
        guard case .accepted(let publishedReceipt) = published, publishedReceipt.revision == 1 else {
            throw CheckFailure(label: "confirmed publication controller did not reach the actual HTTP service: \(published)")
        }
        let accepted = try await apiA.state(area: area.rawValue)
        guard let observation = accepted.document.items.first(where: { $0.kind == .agentObservation }),
              let discussion = accepted.document.items.first(where: { $0.kind == .discussion }),
              let position = accepted.document.positions.first(where: { $0.object == observation.id }) else {
            throw CheckFailure(label: "reviewed capture did not reach the actual service")
        }
        try controllerHTTPCheck(position.rect == .init(x: 0, y: 0, width: 640, height: 480)
            && accepted.document.posts.first?.text == "Reviewed starting discussion", "confirmed reviewed capture reaches actual HTTP storage with exact content and area-local geometry")
        let publicationCache = try localA.load()!
        try controllerHTTPCheck(publicationCache.document == accepted.document && publicationCache.appliedRevision == publishedReceipt.revision
            && publicationCache.sourceBindings == confirmed.sourceBindings
            && publicationCache.resolution(for: observation.id) == .localReference(confirmed.sourceBindings[0]),
            "production publication submission retains exact local source bindings beside its acknowledged HTTP document/cursor")
        let draft = SharedAreaLocalDraft(object: discussion.id, text: "private-local-draft-sentinel")
        let cameraB = SharedAreaLocalView(x: 550, y: -260, zoom: 1.75, focusedObject: discussion.id)
        _ = try localB.save(.init(scope: localB.scope, document: accepted.document, observedMembershipEpoch: 1,
            view: cameraB, drafts: [draft]))
        let guest = try controller(b, localB), excluded = try controller(c, localC)
        controllers.append(contentsOf: [guest, excluded])
        try controllerHTTPCheck(guest.document == accepted.document && guest.scope == nil, "cached document is visible without a reusable membership grant")
        let cachedAttempt = await guest.submit(.init(area: area, expectedRevision: 1, edits: [.remove(discussion.id)]))
        if case .rejected = cachedAttempt {} else { throw CheckFailure(label: "cached controller submitted before online verification") }
        await guest.open(); await excluded.open()
        try await waitForController("independent A/B online") {
            guard case .connected = owner.status, case .connected = guest.status else { return false }
            return true
        }
        try await waitForController("excluded identity unavailable") { if case .unavailable = excluded.status { return true }; return false }
        try controllerHTTPCheck(excluded.document == nil && excluded.scope == nil, "excluded controller receives no document or write scope")
        let cameraA = SharedAreaLocalView(x: -80, y: 120, zoom: 0.75)
        try owner.setView(cameraA)
        let posted = SharedArea.Command(area: area, expectedRevision: 1, edits: [.post(.init(id: .init(), object: discussion.id,
            author: a.identity.person, text: "shared-discussion-from-owner"))])
        let submission = await owner.submit(posted)
        guard case .accepted = submission else { throw CheckFailure(label: "online controller submission was not accepted: \(submission)") }
        try await waitForController("B receives A post") { guest.document?.revision == 2 && owner.document?.revision == 2 }
        try controllerHTTPCheck(guest.document == owner.document, "actual A/B controllers converge through accepted HTTP updates")
        try controllerHTTPCheck(guest.view == cameraB && owner.view == cameraA && guest.drafts.contains(draft), "incoming updates preserve each private camera and draft")
        try controllerHTTPCheck(try localB.load()?.appliedRevision == 2, "native controller atomically persists the revision actually applied")

        let presence = try await apiB.beginPresence(area: area.rawValue)
        try await apiB.publishPresence(area: area.rawValue, value: .init(session: presence.id, sequence: 1, cursor: .init(x: 212, y: 144)))
        try await waitForController("A receives separate presence") { owner.presence.contains { $0.identity == b.identity && $0.cursor == .init(x: 212, y: 144) } }
        try controllerHTTPCheck(owner.document?.revision == 2, "presence delivery does not advance accepted document history")

        var moved = position; moved.rect = .init(x: -160, y: 340, width: 640, height: 480)
        let move = SharedArea.Command(area: area, expectedRevision: 2, edits: [.place(moved)])
        _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: move))
        let conflictDraft = SharedAreaLocalDraft(object: discussion.id, text: "stale-discussion-draft-sentinel")
        let stale = SharedArea.Command(area: area, expectedRevision: 2, edits: [.post(.init(id: .init(), object: discussion.id,
            author: b.identity.person, text: conflictDraft.text))])
        let staleOutcome = await guest.submit(stale, preserving: conflictDraft)
        guard case .rejected = staleOutcome else { throw CheckFailure(label: "stale client edit was silently rebased") }
        try await waitForController("B receives geometry") { guest.document?.revision == 3 }
        try controllerHTTPCheck(guest.drafts.contains(conflictDraft) && guest.document?.positions.first(where: { $0.id == position.id })?.rect == moved.rect,
            "stale edit stays private while accepted shared geometry arrives")
        let fresh = try await apiA.state(area: area.rawValue)
        let wire = String(decoding: try fresh.document.canonicalData(), as: UTF8.self)
        try controllerHTTPCheck(!wire.contains(draft.text) && !wire.contains(conflictDraft.text) && !wire.contains("source-canvas-private-sentinel") && !wire.contains("source-runner-private-sentinel"),
            "private drafts and source filesystem sentinels never enter the accepted service document")
        for sentinel in [projectID.uuidString, agentTile.id.uuidString, agentTile.runtimeRef!.id.uuidString, zoneID.uuidString, source.path, "private-host-title", "private-note-title"] {
            try controllerHTTPCheck(!wire.contains(sentinel), "reviewed publication excludes private source identifiers and metadata from service bytes")
        }
        try controllerHTTPCheck(try Data(contentsOf: source.appendingPathComponent("canvas.json")) == originalCanvas
            && Data(contentsOf: source.appendingPathComponent("managed-session.json")) == originalSession,
            "remote layout and native client persistence preserve source project bytes")

        let refusedDraft = SharedAreaLocalDraft(object: observation.id, text: "keep draft after forbidden operation")
        let forbidden = await guest.submit(.init(area: area, expectedRevision: 3, edits: [.remove(observation.id)]), preserving: refusedDraft)
        guard case .rejected(.forbidden) = forbidden else { throw CheckFailure(label: "source-ownership refusal was confused with loss of area access") }
        try controllerHTTPCheck(guest.status == .connected && guest.scope?.role == .editor && guest.document?.revision == 3
            && guest.drafts.contains(refusedDraft) && (try localB.load())?.accessDenied == false,
            "a forbidden object action preserves valid area membership, visible content and private draft")

        try await apiA.removeMember(area: area.rawValue, person: b.identity.person.rawValue, epoch: 1)
        try await waitForController("B is removed while subscribed") { if case .unavailable = guest.status { return true }; return false }
        try controllerHTTPCheck(guest.document == nil && guest.scope == nil && guest.presence.isEmpty, "active removal clears visible content and authority")
        await guest.close()
        let reopened = try controller(b, localB); controllers.append(reopened)
        try controllerHTTPCheck(reopened.document == nil && reopened.scope == nil && reopened.drafts.contains(conflictDraft), "persisted denial suppresses cached shared content on reopen and preserves private drafts")
        await reopened.open()
        try await waitForController("removed B cannot reconnect") { if case .unavailable = reopened.status { return true }; return false }
        try controllerHTTPCheck(reopened.document == nil, "online revalidation does not restore a removed area")
        await owner.close()
        let ownerReopened = try controller(a, localA); controllers.append(ownerReopened)
        try controllerHTTPCheck(ownerReopened.view == cameraA && ownerReopened.scope == nil, "closing and reopening retains only private navigation until current authority returns")
        for client in controllers { await client.close() }
        try await runCollaborationOverloadChecks(api: apiA, store: store, credentials: credentials, endpoint: endpoint,
            credential: a, root: root.appendingPathComponent("overload-recovery"))
        try await server.stop()
    } catch {
        for client in controllers { await client.close() }
        try? await server.stop()
        throw error
    }
}
