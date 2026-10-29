import Foundation
import Crypto
import GRDB
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

private struct OutboxFailure: Error { let message: String }
private func verify(_ value: Bool, _ message: String) throws { if !value { throw OutboxFailure(message: message) } }

private final class OutboxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private final class OutboxLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RelayOutboxTrace] = []
    func append(_ value: RelayOutboxTrace) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func captured() -> [RelayOutboxTrace] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor OutboxTransport: RelayAPNSTransport {
    enum Step: Sendable { case response(Int, TimeInterval? = nil), failure }
    private let steps: [Step]
    private var requests: [RelayAPNSRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        let step = steps[min(requests.count, steps.count - 1)]
        requests.append(request)
        switch step {
        case .response(let status, let after): return .init(statusCode: status, retryAfter: after)
        case .failure: throw OutboxFailure(message: "private transport error /private/never-log-this")
        }
    }
    func captured() -> [RelayAPNSRequest] { requests }
}

private struct OutboxFixture {
    let directory: URL
    let path: String
    let key = Data(repeating: 22, count: 32)
    let store: RelayStore
    let desktop: RelayDesktopProvisioning
    let auth: RelayCredentialContext
    let phone: RelayCredentialContext
    let registration: UUID
    let clock = OutboxClock()
    let configuration: RelayAPNSConfiguration
    let log: OutboxLog

    static func make(_ log: OutboxLog) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-outbox-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("relay.sqlite").path
        let store = try RelayStore(path: path, masterKey: Data(repeating: 22, count: 32), outboxTrace: log.append)
        let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
        let desktop = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Fixture Mac"))
        let auth = try await store.authenticate(desktop.credential)
        let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Fixture phone")
        let paired = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Fixture phone"))
        let phone = try await store.authenticate(paired.credential)
        try await store.savePushToken(auth: phone, kind: .apns, token: Data("old-private-fixture-token".utf8))
        let registrations = try await store.pushRegistrations(instanceID: desktop.instanceID)
        guard let registration = registrations.first?.id else { throw OutboxFailure(message: "fixture registration") }
        let config = RelayAPNSConfiguration(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
        return .init(directory: directory, path: path, store: store, desktop: desktop, auth: auth, phone: phone,
                     registration: registration, configuration: config, log: log)
    }
    func reopen() throws -> RelayStore { try RelayStore(path: path, masterKey: key, outboxTrace: log.append) }
    func sender(_ transport: OutboxTransport, store override: RelayStore? = nil) throws -> RelayAPNSService<OutboxTransport> {
        try RelayAPNSService(store: override ?? store, configuration: configuration, transport: transport,
                             trace: { _ in }, clock: clock.now)
    }
    func event(agent: UUID = UUID(), status: String = "done", version: Int = 1) throws -> RelayEvent {
        var fields: [String: Any] = ["agentId": agent.uuidString, "status": status, "sequence": version,
                                    "occurredAtReferenceInterval": 1000 + version, "agentName": "PrivateFixtureLabel",
                                    "summary": "private summary /never-copy-this"]
        if status == "done" { fields["terminalOutcome"] = "succeeded" }
        if status == "needsAttention" { fields["approvalRequestId"] = "fixture-request-\(version)" }
        return .init(kind: "sync.message", payload: try JSONSerialization.data(withJSONObject: ["activity": ["event": fields]]))
    }
    func publish(_ event: RelayEvent) async throws -> RelayEvent {
        try await store.publish(auth: auth, request: .init(kind: event.kind, payload: event.payload), now: clock.now())
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

func runRelayOutboxChecks() async throws {
    let log = OutboxLog()
    try await checkOutboxAtomicCommit(log)
    try await checkOutboxV2Migration(log)
    try await checkOutboxRecoveryAndBackoff(log)
    try await checkOutboxRecipientCooldown(log)
    try await checkOutboxBoundsAndQuiet(log)
    try await checkOutboxRejectedState(log)
    try await checkOutboxAuthorityAndLeases(log)
    try await checkOutboxRevocationAndPublicationRecipients(log)
    try await checkOutboxCapacityAndCorruption(log)
    try await checkOutboxStorageFailure(log)
    let transitions = Set(log.captured().map(\.path))
    let required = Set(RelayOutboxTrace.Transition.allCases)
    try verify(transitions == required, "all thirteen outbox transitions need behavioral witnesses")
    let encoded = String(decoding: try JSONEncoder().encode(log.captured()), as: UTF8.self)
    for forbidden in ["PrivateFixtureLabel", "private summary", "fixture-token", "/never-copy", "authorization", "bearer", "never-log-this"] {
        try verify(!encoded.contains(forbidden), "outbox traces must contain only redacted metadata")
    }
    print("Relay outbox behavior passed: atomic commit/rollback, restart, backoff, five-attempt/age/capacity bounds, supersession, concurrent leases, revocation, token rotation, encryption, all OUT-01…OUT-13 transitions")
}

private func checkOutboxRejectedState(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    let agent = UUID()
    _ = try await f.publish(f.event(agent: agent))
    _ = try await f.publish(f.event(agent: agent, status: "future-unknown-state", version: 2))
    let provider = OutboxTransport([.response(200)]); let sender = try f.sender(provider)
    await sender.drainOutbox()
    try verify(await provider.captured().isEmpty, "rejected new state with known agent must withhold old completion")
    _ = try await f.publish(f.event(agent: agent, version: 3))
    _ = try await f.publish(.init(kind: "sync.message", payload: JSONSerialization.data(withJSONObject: ["transcriptEnvelope": ["agentId": agent.uuidString, "status": "unknown"]])))
    await sender.drainOutbox()
    try verify(await provider.captured().count == 1, "unrelated envelope must not invent authority to cancel known work")
}

private func checkOutboxStorageFailure(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    _ = try await f.publish(f.event())
    let db = try DatabaseQueue(path: f.path)
    let provider = OutboxTransport([.response(200)]); let sender = try f.sender(provider)
    try await db.write { try $0.execute(sql: "ALTER TABLE notification_outbox RENAME TO fixture_unavailable_outbox") }
    await sender.drainOutbox()
    try await db.write { try $0.execute(sql: "ALTER TABLE fixture_unavailable_outbox RENAME TO notification_outbox") }
    try verify(await provider.captured().isEmpty, "storage poll failure cannot invent a provider request")
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 1, "poll failure preserves committed intent")
    try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_acceptance BEFORE UPDATE ON notification_claims WHEN NEW.disposition IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture acceptance failure'); END") }
    await sender.drainOutbox()
    try verify(await provider.captured().count == 1, "provider may accept before acceptance persistence fails")
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 1, "failed acceptance transaction preserves leased intent")
    try await db.write { try $0.execute(sql: "DROP TRIGGER fail_acceptance") }
    f.clock.advance(120); await sender.drainOutbox()
    let attempts = await provider.captured()
    try verify(attempts.count == 2 && attempts[0].headers["apns-id"] == attempts[1].headers["apns-id"], "uncertain acceptance recovers at least once with stable provider ID")
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "recovery eventually persists acceptance")
}

private func checkOutboxRecipientCooldown(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    let agent = UUID()
    let old = try await f.publish(f.event(agent: agent))
    let provider = OutboxTransport([.response(429, 120), .response(200)])
    let sender = try f.sender(provider)
    await sender.deliverPublished(event: old, instanceID: f.desktop.instanceID)
    let fresh = try await f.publish(f.event(agent: agent, status: "needsAttention", version: 2))
    await sender.deliverPublished(event: fresh, instanceID: f.desktop.instanceID)
    try verify(await provider.captured().count == 1, "fresh decision must not bypass recipient cooldown")
    f.clock.advance(120); await sender.drainOutbox()
    try verify(await provider.captured().count == 2, "current decision sends after shared cooldown")

    // Two leases can exist for independent tasks on one phone. If one learns a
    // provider cooldown before the other begins, the unused lease is returned.
    _ = try await f.publish(f.event()); _ = try await f.publish(f.event())
    guard let a = try await f.store.claimNextAlert(now: f.clock.now()),
          let b = try await f.store.claimNextAlert(now: f.clock.now()),
          let recipient = try await f.store.prepareAlertRecipient(a, now: f.clock.now()) else { throw OutboxFailure(message: "cooldown leases") }
    try await f.store.finishAlertAttempt(a, recipient: recipient, statusCode: 503, now: f.clock.now())
    try verify(try await f.store.prepareAlertRecipient(b, now: f.clock.now()) == nil, "cooldown learned after lease must prevent submission")
    f.clock.advance(900)
    guard let reused = try await f.store.claimNextAlert(now: f.clock.now()) else { throw OutboxFailure(message: "cooldown lease resume") }
    try verify(reused.attempt <= 2, "returning an unused lease must not burn attempt budget")
}

private func checkOutboxAtomicCommit(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    let db = try DatabaseQueue(path: f.path)
    try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_outbox BEFORE INSERT ON notification_outbox BEGIN SELECT RAISE(ABORT,'fixture write failure'); END") }
    do { _ = try await f.publish(f.event()); throw OutboxFailure(message: "failed outbox insert must roll back publication") }
    catch is DatabaseError {}
    try verify(try await f.store.events(auth: f.auth, after: 0).latestSequence == 0, "publication cursor must roll back with outbox insert")
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "failed transaction leaves no partial intent")
    try await db.write { try $0.execute(sql: "DROP TRIGGER fail_outbox") }
    let event = try await f.publish(f.event())
    let pending = try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID)
    try verify(event.sequence == 1 && pending == 1, "event and pending alert commit together")
    let sealed = try await db.read { try Data.fetchOne($0, sql: "SELECT sealed_intent FROM notification_outbox")! }
    try verify(!String(decoding: sealed, as: UTF8.self).contains("PrivateFixtureLabel"), "outbox stores encrypted intent")
    let normalized = SymmetricKey(data: Data(SHA256.hash(data: f.key)))
    let identity = RelaySystemSurfaceProjection.project(event: event, instanceID: f.desktop.instanceID)!.notificationIdentity
    let aad = Data("\(f.desktop.instanceID.uuidString)|\(f.registration.uuidString)|\(identity)".utf8)
    let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: normalized, authenticating: aad)
    let decoded = String(decoding: plaintext, as: UTF8.self)
    try verify(!decoded.contains("private summary") && !decoded.contains("fixture-token"), "sealed intent must exclude summary/token material too")
    let root = try JSONSerialization.jsonObject(with: plaintext) as! [String: Any]
    let body = String(decoding: Data(base64Encoded: root["payload"] as! String)!, as: UTF8.self)
    try verify(!body.contains("private summary") && !body.contains("fixture-token"), "stored alert body itself must be redacted")
}

private func checkOutboxV2Migration(_ log: OutboxLog) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-outbox-v2-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("relay.sqlite").path
    let db = try DatabaseQueue(path: path)
    try RelayStore.migrator.migrate(db, upTo: "relay-notification-deduplication")
    let instance = UUID(), registration = UUID(), device = UUID()
    let key = Data(repeating: 22, count: 32)
    let token = Data("v2-fixture-token".utf8)
    let sealed = try AES.GCM.seal(token, using: SymmetricKey(data: Data(SHA256.hash(data: key)))).combined!
    try await db.write { db in
        try db.execute(sql: "INSERT INTO instances(id,label,created_at) VALUES (?,?,?)", arguments: [instance.uuidString, "Legacy Mac", 1000])
        try db.execute(sql: "INSERT INTO credentials(id,instance_id,token_hash,role,capabilities,device_id,device_label,created_at) VALUES (?,?,?,?,?,?,?,?)",
                       arguments: [UUID().uuidString, instance.uuidString, Data(SHA256.hash(data: Data("v2-phone-credential".utf8))), "companion", "readActivity", device.uuidString, "Legacy phone", 1000])
        try db.execute(sql: "INSERT INTO push_registrations(id,instance_id,device_id,kind,sealed_token,created_at) VALUES (?,?,?,?,?,?)",
                       arguments: [registration.uuidString, instance.uuidString, device.uuidString, "apns", sealed, 1000])
        try db.execute(sql: "INSERT INTO notification_claims(registration_id,decision_key,claim_id,claimed_at,accepted_at) VALUES (?,?,?,?,?)",
                       arguments: [registration.uuidString, "v2-accepted-decision", UUID().uuidString, 1000, 1000])
    }
    let upgraded = try RelayStore(path: path, masterKey: key, outboxTrace: log.append)
    try verify(try await upgraded.health().schemaVersion == 4, "v2 migrates additively to outbox schema")
    try verify(try await upgraded.authenticate("v2-phone-credential").deviceID == device, "upgrade preserves credential authority")
    try verify(try await upgraded.pushRegistrations(instanceID: instance).first?.token == token, "upgrade preserves encrypted registration")
    try verify(try await upgraded.claimPushDecision(registrationID: registration, decisionKey: "v2-accepted-decision") == nil, "upgrade cannot re-alert accepted v2 identity")
    try verify(try await upgraded.pendingAlertCount(instanceID: instance) == 0, "upgrade must not reconstruct old history into new notifications")
}

private func checkOutboxRevocationAndPublicationRecipients(_ log: OutboxLog) async throws {
    for instanceRevocation in [false, true] {
        let f = try await OutboxFixture.make(log); defer { f.cleanup() }
        let event = try await f.publish(f.event())
        let provider = OutboxTransport([.response(503)]); let sender = try f.sender(provider)
        await sender.deliverPublished(event: event, instanceID: f.desktop.instanceID)
        if instanceRevocation { try await f.store.adminRevokeInstance(f.desktop.instanceID) }
        else { try await f.store.removePushToken(auth: f.phone, kind: .apns) }
        f.clock.advance(1); await sender.drainOutbox()
        try verify(await provider.captured().count == 1, "revocation during backoff must prevent later submission")
        try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "revoked backlog closes before retry due time")
    }
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    try await f.store.removePushToken(auth: f.phone, kind: .apns)
    let old = try await f.publish(f.event())
    try await f.store.savePushToken(auth: f.phone, kind: .apns, token: Data("newly-registered-token".utf8))
    let provider = OutboxTransport([.response(200)]); let sender = try f.sender(provider)
    await sender.deliverPublished(event: old, instanceID: f.desktop.instanceID)
    try verify(await provider.captured().isEmpty, "late committed-event wake must not retroactively enroll a phone")
    let current = try await f.publish(f.event())
    await sender.deliverPublished(event: current, instanceID: f.desktop.instanceID)
    try verify(await provider.captured().count == 1, "newly registered phone remains eligible for new source events")

    let other = try await OutboxFixture.make(log); defer { other.cleanup() }
    _ = try await f.publish(f.event()); _ = try await other.publish(other.event())
    let db = try DatabaseQueue(path: f.path), otherDB = try DatabaseQueue(path: other.path)
    let swapped = try await db.read { try Data.fetchOne($0, sql: "SELECT sealed_intent FROM notification_outbox LIMIT 1")! }
    try await otherDB.write { try $0.execute(sql: "UPDATE notification_outbox SET sealed_intent=?", arguments: [swapped]) }
    let isolatedProvider = OutboxTransport([.response(200)]); let isolatedSender = try other.sender(isolatedProvider)
    await isolatedSender.drainOutbox()
    try verify(await isolatedProvider.captured().isEmpty, "copied ciphertext cannot cross instance/recipient/decision boundaries")
    try verify(try await other.store.pendingAlertCount(instanceID: other.desktop.instanceID) == 0, "context authentication failure closes swapped intent")
}

private func checkOutboxRecoveryAndBackoff(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    let event = try await f.publish(f.event())
    let transport = OutboxTransport([.response(503), .response(200)])
    let first = try f.sender(transport)
    await first.deliverPublished(event: event, instanceID: f.desktop.instanceID)
    try verify(await transport.captured().count == 1, "initial attempt executes once")
    let restarted = try f.sender(transport, store: f.reopen())
    f.clock.advance(899); await restarted.drainOutbox()
    try verify(await transport.captured().count == 1, "5xx must wait Apple's minimum fifteen minutes")
    f.clock.advance(1); await restarted.drainOutbox()
    let requests = await transport.captured()
    try verify(requests.count == 2, "restart recovers retry without any republish")
    try verify(requests[0].body == requests[1].body && requests[0].headers["apns-id"] == requests[1].headers["apns-id"], "retry keeps persisted payload and stable provider ID")
    try verify(requests[1].headers["apns-expiration"] == String(Int(f.clock.now().addingTimeInterval(2700).timeIntervalSince1970)), "provider expiration matches fixed intent lifetime")
    await restarted.deliverPublished(event: event, instanceID: f.desktop.instanceID)
    try verify(await transport.captured().count == 2, "accepted alert never repeats after replay")
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "accepted payload is removed")

    let throttled = try await f.publish(f.event())
    let rate = OutboxTransport([.response(429, 120), .response(200)])
    let rateSender = try f.sender(rate)
    await rateSender.deliverPublished(event: throttled, instanceID: f.desktop.instanceID)
    f.clock.advance(119); await rateSender.drainOutbox()
    try verify(await rate.captured().count == 1, "429 respects provider Retry-After")
    f.clock.advance(1); await rateSender.drainOutbox()
    try verify(await rate.captured().count == 2, "429 retries when provider delay elapses")

    let failed = try await f.publish(f.event())
    let retry = OutboxTransport([.failure, .response(200)])
    let retrySender = try f.sender(retry)
    await retrySender.deliverPublished(event: failed, instanceID: f.desktop.instanceID)
    f.clock.advance(4); await retrySender.drainOutbox()
    try verify(await retry.captured().count == 1, "transport failure must not hot-loop")
    f.clock.advance(1); await retrySender.drainOutbox()
    try verify(await retry.captured().count == 2, "transport failure recovers without republish")
}

private func checkOutboxBoundsAndQuiet(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    let event = try await f.publish(f.event())
    let failing = OutboxTransport([.failure]); let sender = try f.sender(failing)
    await sender.deliverPublished(event: event, instanceID: f.desktop.instanceID)
    for delay: TimeInterval in [5, 20, 80, 320] { f.clock.advance(delay); await sender.drainOutbox() }
    try verify(await failing.captured().count == 5, "retry limit includes exactly five total attempts")
    f.clock.advance(10000); await sender.drainOutbox()
    _ = try await f.publish(event)
    await sender.drainOutbox()
    try verify(await failing.captured().count == 5, "republish cannot reset exhausted attempt budget")

    let aged = try await f.publish(f.event())
    f.clock.advance(3600)
    let success = OutboxTransport([.response(200)]); let successful = try f.sender(success)
    await successful.drainOutbox()
    await successful.deliverPublished(event: aged, instanceID: f.desktop.instanceID)
    try verify(await success.captured().isEmpty, "expired pending work must not send or resurrect")
    let permanent = try await f.publish(f.event())
    let invalid = OutboxTransport([.response(400)]); let invalidSender = try f.sender(invalid)
    await invalidSender.deliverPublished(event: permanent, instanceID: f.desktop.instanceID)
    f.clock.advance(100); await invalidSender.drainOutbox()
    try verify(await invalid.captured().count == 1, "permanent 4xx is not retried")

    let agent = UUID()
    let old = try await f.publish(f.event(agent: agent))
    let unavailable = OutboxTransport([.response(503)]); let unavailableSender = try f.sender(unavailable)
    await unavailableSender.deliverPublished(event: old, instanceID: f.desktop.instanceID)
    _ = try await f.publish(f.event(agent: agent, status: "working", version: 2))
    f.clock.advance(900); await unavailableSender.drainOutbox()
    try verify(await unavailable.captured().count == 1, "new quiet state must cancel obsolete completion retry")
    let attention = try await f.publish(f.event(agent: agent, status: "needsAttention", version: 3))
    _ = try await f.publish(old)
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 1, "closed old completion replay must not cancel newer attention")
    await successful.deliverPublished(event: attention, instanceID: f.desktop.instanceID)
    try verify(await success.captured().count == 1, "current attention remains deliverable")
    _ = try await f.publish(f.event(agent: UUID(), status: "working"))
    var cancelled = try f.event()
    cancelled.payload = try JSONSerialization.data(withJSONObject: ["activity": ["event": ["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "cancelled"]]])
    _ = try await f.publish(cancelled)
    _ = try await f.publish(.init(kind: "unknown", payload: Data()))
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "quiet/cancelled/unknown events never enqueue alerts")
}

private func checkOutboxAuthorityAndLeases(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    let event = try await f.publish(f.event())
    let firstStore = try f.reopen()
    guard let first = try await f.store.claimNextAlert(now: f.clock.now()),
          let firstRecipient = try await f.store.prepareAlertRecipient(first, now: f.clock.now()) else { throw OutboxFailure(message: "first lease") }
    try verify(try await firstStore.claimNextAlert(now: f.clock.now()) == nil, "two stores cannot own one pending decision")
    f.clock.advance(120)
    guard let next = try await firstStore.claimNextAlert(now: f.clock.now()),
          let nextRecipient = try await firstStore.prepareAlertRecipient(next, now: f.clock.now()) else { throw OutboxFailure(message: "lease recovery") }
    try await f.store.finishAlertAttempt(first, recipient: firstRecipient, statusCode: 200, now: f.clock.now())
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 1, "stale lease cannot finalize replacement")
    try await firstStore.finishAlertAttempt(next, recipient: nextRecipient, statusCode: 200, now: f.clock.now())
    let accepted = OutboxTransport([.response(200)]); let acceptedSender = try f.sender(accepted)
    await acceptedSender.deliverPublished(event: event, instanceID: f.desktop.instanceID)
    try verify(await accepted.captured().isEmpty, "recovered accepted decision is deduplicated")

    let rotated = try await f.publish(f.event())
    guard let claim = try await f.store.claimNextAlert(now: f.clock.now()),
          let oldRecipient = try await f.store.prepareAlertRecipient(claim, now: f.clock.now()) else { throw OutboxFailure(message: "rotation lease") }
    let freshToken = Data("new-private-fixture-token".utf8)
    try await f.store.savePushToken(auth: f.phone, kind: .apns, token: freshToken)
    try await f.store.finishAlertAttempt(claim, recipient: oldRecipient, statusCode: 410, now: f.clock.now())
    try verify(try await f.store.pushRegistrations(instanceID: f.desktop.instanceID).first?.token == freshToken, "old 410 cannot revoke rotated token")
    await acceptedSender.deliverPublished(event: rotated, instanceID: f.desktop.instanceID)
    try verify(await accepted.captured().isEmpty, "invalid old intent is terminal after token rotation")

    let race = try await f.publish(f.event())
    let a = try f.sender(accepted), b = try f.sender(accepted, store: f.reopen())
    async let sendA: Void = a.deliverPublished(event: race, instanceID: f.desktop.instanceID)
    async let sendB: Void = b.deliverPublished(event: race, instanceID: f.desktop.instanceID)
    _ = await (sendA, sendB)
    let sent = await accepted.captured()
    try verify(sent.count == 1 && sent[0].url.path.hasSuffix(freshToken.map { String(format: "%02x", $0) }.joined()), "concurrent workers send once with current token")

    _ = try await f.publish(f.event())
    guard let revokeClaim = try await f.store.claimNextAlert(now: f.clock.now()) else { throw OutboxFailure(message: "revoke lease") }
    try await f.store.revokeCredential(auth: f.auth, credentialID: f.phone.credentialID)
    try verify(try await f.store.prepareAlertRecipient(revokeClaim, now: f.clock.now()) == nil, "revocation after lease blocks provider submission")
    await acceptedSender.drainOutbox()
    try verify(await accepted.captured().count == 1, "revoked recipient receives no recovered alert")
}

private func checkOutboxCapacityAndCorruption(_ log: OutboxLog) async throws {
    let f = try await OutboxFixture.make(log); defer { f.cleanup() }
    for _ in 0..<256 { _ = try await f.publish(f.event()) }
    let overflow = try await f.publish(f.event())
    try verify(overflow.sequence == 257, "full outbox must not prevent sync event publication")
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 256, "pending body storage is bounded per instance")
    f.clock.advance(3600)
    let transport = OutboxTransport([.response(200)]); let sender = try f.sender(transport)
    for _ in 0..<8 { await sender.drainOutbox() }
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "bounded drain batches reclaim expired capacity")
    try verify(await transport.captured().isEmpty, "expired backlog generates no provider traffic")
    _ = try await f.publish(overflow)
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 1, "capacity-rejected source can enqueue when capacity returns")
    let db = try DatabaseQueue(path: f.path)
    try await db.write { try $0.execute(sql: "UPDATE notification_outbox SET sealed_intent=X'00'") }
    await sender.drainOutbox()
    try verify(try await f.store.pendingAlertCount(instanceID: f.desktop.instanceID) == 0, "unreadable encrypted payload closes without looping")
    try verify(await transport.captured().isEmpty, "corrupt intent cannot reach provider")
}
