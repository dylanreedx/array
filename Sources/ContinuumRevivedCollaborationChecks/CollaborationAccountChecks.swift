import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

private struct AccountCheckFailure: Error { let label: String }
private func accountCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw AccountCheckFailure(label: label) }
    print("PASS accounts: \(label)")
}
private func accountStoreRefuses(_ expected: CollaborationAccountStoreError, _ body: () throws -> Void) throws {
    do { try body(); throw AccountCheckFailure(label: "expected account-store refusal \(expected)") }
    catch let error as CollaborationAccountStoreError { try accountCheck(error == expected, "refuses \(expected)") }
}
private final class AccountMemoryVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    var count: Int { lock.withLock { data.count } }
    func read(service: String, account: String) throws -> Data? { lock.withLock { data[service + account] } }
    func write(_ bytes: Data, service: String, account: String) throws { lock.withLock { data[service + account] = bytes } }
    func remove(service: String, account: String) throws { _ = lock.withLock { data.removeValue(forKey: service + account) } }
}
private final class AccountWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    private var savedBeforeMetadata = true
    func fail() { lock.withLock { failure = true } }
    func inspect(credentialCount: Int) throws {
        try lock.withLock {
            savedBeforeMetadata = savedBeforeMetadata && credentialCount > 0
            if failure { failure = false; throw AccountCheckFailure(label: "injected account metadata write failure") }
        }
    }
    var correctOrder: Bool { lock.withLock { savedBeforeMetadata } }
}
private actor AccountIdentityGate {
    private var waiting: CheckedContinuation<Collaboration.Identity, Never>?
    private var value: Collaboration.Identity?
    func wait() async -> Collaboration.Identity {
        if let value { return value }
        return await withCheckedContinuation { waiting = $0 }
    }
    func release(_ identity: Collaboration.Identity) {
        value = identity; waiting?.resume(returning: identity); waiting = nil
    }
}
private actor AccountTransportFixture: CollaborationAccountTransport {
    let credential: Collaboration.Credential
    let host = Collaboration.Host(id: .init())
    private var areaState: Collaboration.State
    private var identityGate: AccountIdentityGate?
    private var identityOverride: Collaboration.Identity?
    private var failStateRead = false
    private(set) var redemptions = 0
    private(set) var creates = 0
    private(set) var hosts = 0
    private(set) var acceptances = 0
    init(credential: Collaboration.Credential) {
        self.credential = credential
        let document = SharedArea.Document()
        areaState = .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document)
    }
    func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential { redemptions += 1; return credential }
    func identity() async throws -> Collaboration.Identity {
        if let identityGate { return await identityGate.wait() }
        return identityOverride ?? credential.identity
    }
    func createArea() async throws -> Collaboration.State { creates += 1; return areaState }
    func state(area: UUID) async throws -> Collaboration.State {
        if failStateRead { failStateRead = false; throw URLError(.networkConnectionLost) }
        return areaState
    }
    func accept(code: String) async throws -> Collaboration.Scope { acceptances += 1; return areaState.scope }
    func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation {
        .init(code: "fixture-area-invitation", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    func registerHost() async throws -> Collaboration.Host { hosts += 1; return host }
    func setGate(_ gate: AccountIdentityGate?) { identityGate = gate }
    func overrideIdentity(_ value: Collaboration.Identity) { identityOverride = value }
    func failNextStateRead() { failStateRead = true }
}

@MainActor
func runCollaborationAccountChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-accounts-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://accounts.example.test")!)
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    let credential = Collaboration.Credential(identity: identity, token: "device-credential-sentinel")
    let account = CollaborationLocalAccount(endpoint: endpoint, identity: identity, label: "Work")
    let store = try CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("registry"), bundleIdentifier: nil)
    var initial = try store.load()
    try accountCheck(initial.generation == 0 && initial.accounts.isEmpty && !FileManager.default.fileExists(atPath: store.stateFile.path),
        "reading an absent registry creates no account or file")
    initial.accounts = [account]; initial.selectedAccountID = account.id
    let saved = try store.save(initial)
    try accountCheck(try store.load() == saved && saved.generation == 1, "account navigation metadata round trips atomically")
    try accountStoreRefuses(.staleGeneration) { _ = try store.save(initial) }
    let otherChannel = try CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("registry"), bundleIdentifier: AppChannel.prodBundleIdentifier)
    try accountCheck(try otherChannel.load().accounts.isEmpty && otherChannel.stateFile != store.stateFile, "prod and dev account registries have separate paths")
    try FileManager.default.createDirectory(at: otherChannel.directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: store.stateFile, to: otherChannel.stateFile)
    try accountStoreRefuses(.scopeMismatch) { _ = try otherChannel.load() }
    try accountStoreRefuses(.scopeMismatch) { _ = try otherChannel.save(saved) }
    let original = try Data(contentsOf: store.stateFile)
    var future = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    future["schema"] = 2
    let futureBytes = try JSONSerialization.data(withJSONObject: future)
    try futureBytes.write(to: store.stateFile)
    try accountStoreRefuses(.unsupportedSchema) { _ = try store.load() }
    try accountStoreRefuses(.unsupportedSchema) { _ = try store.save(saved) }
    try accountCheck(try Data(contentsOf: store.stateFile) == futureBytes, "future registry bytes survive read and write refusal")
    let corrupt = Data([0xff, 0x01])
    try corrupt.write(to: store.stateFile)
    try accountStoreRefuses(.corruptState) { _ = try store.load() }
    try accountStoreRefuses(.corruptState) { _ = try store.save(saved) }
    try accountCheck(try Data(contentsOf: store.stateFile) == corrupt, "corrupt registry remains recoverable evidence")
    try original.write(to: store.stateFile)

    let vault = AccountMemoryVault()
    let credentials = CollaborationCredentialStore(vault: vault, bundleIdentifier: nil)
    let gate = AccountWriteGate()
    var files = AtomicWriterFileOperations.live
    let originalWrite = files.writeTemporary
    files.writeTemporary = { bytes, file in try gate.inspect(credentialCount: vault.count); try originalWrite(bytes, file) }
    let enrollmentStore = try CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("enrollment"), bundleIdentifier: nil, fileOperations: files)
    let fixture = AccountTransportFixture(credential: credential)
    let controller = try CollaborationAccountController(store: enrollmentStore, credentialStore: credentials, bundleIdentifier: nil,
        transportFactory: { _, _ in fixture })
    gate.fail()
    do {
        _ = try await controller.enroll(endpoint: endpoint, code: "one-time-enrollment-sentinel", deviceLabel: "This Mac", accountLabel: "Work")
        throw AccountCheckFailure(label: "injected metadata failure was lost")
    } catch CollaborationAccountFailure.credentialRetainedMetadataFailure {}
    try accountCheck(controller.activeAccount == nil && controller.pendingAccount?.identity == identity
        && vault.count == 1 && gate.correctOrder, "enrollment retains a saved credential before metadata failure without granting active access")
    let remembered = try controller.rememberRetainedCredential()
    try accountCheck(remembered.id == account.id && controller.pendingAccount == nil && controller.status != .ready,
        "explicit metadata repair does not redeem again or grant online access")
    let redemptions = await fixture.redemptions
    try accountCheck(redemptions == 1, "consumed enrollment code is never automatically replayed")
    let metadata = String(decoding: try Data(contentsOf: enrollmentStore.stateFile), as: UTF8.self)
    try accountCheck(!metadata.contains(credential.token) && !metadata.contains("one-time-enrollment-sentinel") && !metadata.contains("\"token\""),
        "registry and its repair contain no credential or enrollment code")
    _ = try await controller.select(accountID: remembered.id)
    try accountCheck(controller.status == .ready && controller.activeAccount?.identity == identity, "saved account is activated only after current online identity verification")
    gate.fail()
    let retainedAreaID: UUID
    do {
        _ = try await controller.createArea(label: "Design work")
        throw AccountCheckFailure(label: "successful area creation lost its metadata failure")
    } catch CollaborationAccountFailure.areaRetainedMetadataFailure(let id) { retainedAreaID = id }
    let createsBeforeRecovery = await fixture.creates
    try accountCheck(createsBeforeRecovery == 1 && controller.activeAccount?.knownAreas.isEmpty == true,
        "metadata failure retains the exact successful area ID without a second creation")
    let reopened = try await controller.openArea(id: retainedAreaID, label: "Design work")
    let createsAfterRecovery = await fixture.creates
    try accountCheck(reopened.document.id.rawValue == retainedAreaID && createsAfterRecovery == 1
        && controller.activeAccount?.knownAreas == [.init(id: retainedAreaID, label: "Design work")],
        "explicit open retries only local remembrance of the already created area")
    await fixture.failNextStateRead()
    do {
        _ = try await controller.acceptInvitation(code: "fixture-invitation", label: "Invited work")
        throw AccountCheckFailure(label: "accepted invitation lost the area ID on state fetch failure")
    } catch CollaborationAccountFailure.invitationAcceptedStateUnavailable(let id) {
        try accountCheck(id == retainedAreaID, "accepted invitation retains its exact destination when state loading fails")
    }
    _ = try await controller.openArea(id: retainedAreaID, label: "Invited work")
    let acceptanceCount = await fixture.acceptances
    try accountCheck(acceptanceCount == 1, "accepted invitation recovery opens the known area without replaying its code")
    let invitation = try await controller.invite(area: retainedAreaID, person: .init())
    try accountCheck(invitation.code == "fixture-area-invitation", "targeted invitation returns an explicit code without persisting it")
    let host = try await controller.registerHost()
    let sameHost = try await controller.registerHost()
    let hostRegistrations = await fixture.hosts
    try accountCheck(host == sameHost && controller.activeAccount?.hostID == host && hostRegistrations == 1,
        "device-scoped registered host is remembered without inventing an executor")
    let scene = try controller.makeSharedAreaController(area: retainedAreaID)
    try accountCheck(scene.scope == nil && !scene.canSubmit && scene.document == nil, "new area controller still requires its own current admission")
    controller.signOut()
    try accountCheck(controller.activeAccount == nil && controller.status == .signedOut
        && (try credentials.load(for: .init(endpoint: endpoint, identity: identity))) != nil, "disconnect retains scoped device credentials")

    let identityGate = AccountIdentityGate()
    await fixture.setGate(identityGate)
    let late = Task { try await controller.select(accountID: remembered.id) }
    for _ in 0..<100 {
        if controller.status == .connecting { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    controller.signOut()
    await identityGate.release(identity)
    do { _ = try await late.value; throw AccountCheckFailure(label: "late identity response was admitted") }
    catch CollaborationAccountFailure.superseded {}
    try accountCheck(controller.activeAccount == nil && controller.status == .signedOut, "late selection response cannot reconnect after explicit disconnect")
    await fixture.setGate(nil)
    await fixture.overrideIdentity(.init(person: .init(), device: UUID()))
    do { _ = try await controller.select(accountID: remembered.id); throw AccountCheckFailure(label: "forged service identity was admitted") }
    catch CollaborationAccountFailure.identityMismatch {}
    try accountCheck(controller.activeAccount == nil, "service identity mismatch cannot activate saved principal metadata")
    try credentials.remove(for: .init(endpoint: endpoint, identity: identity))
    do { _ = try await controller.select(accountID: remembered.id); throw AccountCheckFailure(label: "missing credential was recreated") }
    catch CollaborationAccountFailure.credentialsMissing {}
    try accountCheck(controller.status == .missingCredential && controller.accounts.count == 1,
        "missing credential stays explicit without creating a replacement person")
}
