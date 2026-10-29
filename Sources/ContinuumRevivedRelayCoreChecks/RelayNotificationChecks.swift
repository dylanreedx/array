import Crypto
import Foundation
import GRDB
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

private struct NotificationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NotificationCheckFailure(description: message) }
}

private actor NotificationTransportFixture: RelayAPNSTransport {
    let status: Int
    let fails: Bool
    var requests: [RelayAPNSRequest] = []
    init(status: Int = 200, fails: Bool = false) { self.status = status; self.fails = fails }
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        requests.append(request)
        if fails { throw NotificationCheckFailure(description: "private transport detail /secret/path") }
        return .init(statusCode: status)
    }
    func captured() -> [RelayAPNSRequest] { requests }
}

private final class NotificationTraceFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RelayNotificationTrace] = []
    func append(_ value: RelayNotificationTrace) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func captured() -> [RelayNotificationTrace] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class NotificationClockFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

func runRelayNotificationChecks() async throws {
    let instance = UUID()
    func event(_ fields: [String: Any]) throws -> RelayEvent {
        .init(kind: "sync.message", payload: try JSONSerialization.data(withJSONObject: ["activity": ["event": fields]]))
    }
    var witnessed = Set<RelayNotificationPath>()
    let scenarios: [(String, String?, String?, RelayNotificationPath)] = [
        ("needsAttention", nil, "request", .approval),
        ("needsAttention", nil, nil, .input),
        ("done", "failed", nil, .failure),
        ("idle", "runtimeError", nil, .failure),
        ("done", "succeeded", nil, .completion),
        ("working", "succeeded", nil, .progress),
        ("configuring", "failed", nil, .progress),
        ("stale", "succeeded", nil, .progress),
        ("idle", nil, nil, .progress),
        ("done", "cancelled", nil, .cancelled),
        ("done", "interrupted", nil, .cancelled),
        ("unknown-future-status", nil, nil, .unsupportedState),
        ("done", "unknown-future-outcome", nil, .unsupportedState),
    ]
    for (status, outcome, approval, expected) in scenarios {
        var fields: [String: Any] = ["agentId": UUID().uuidString, "status": status]
        if let outcome { fields["terminalOutcome"] = outcome }
        if let approval { fields["approvalRequestId"] = approval }
        let result = RelaySystemSurfaceProjection.evaluate(event: try event(fields), instanceID: instance)
        try require(result.path == expected, "\(status)/\(outcome ?? "nil") must classify as \(expected.rawValue)")
        let alerts: Set<RelayNotificationPath> = [.approval, .input, .failure, .completion]
        try require((result.projection?.notification != nil) == alerts.contains(expected),
                    "\(expected.rawValue) must have the specified alert-or-silence outcome")
        witnessed.insert(result.path)
    }
    let invalid = RelaySystemSurfaceProjection.evaluate(
        event: try event(["agentId": "invalid-id", "status": "done"]), instanceID: instance)
    try require(invalid.path == .invalidIdentity && invalid.projection == nil, "invalid agent cannot receive guessed deep link")
    witnessed.insert(invalid.path)
    for value in [RelayEvent(kind: "unknown", payload: Data()), RelayEvent(kind: "sync.message", payload: Data("bad-json".utf8))] {
        let result = RelaySystemSurfaceProjection.evaluate(event: value, instanceID: instance)
        try require(result.path == .unprojectable && result.projection == nil, "unknown/malformed envelope must fail closed")
        witnessed.insert(result.path)
    }
    let unrelated = RelayEvent(kind: "sync.message", payload: try JSONSerialization.data(withJSONObject: [
        "transcriptEnvelope": ["status": "done", "agentId": UUID().uuidString],
    ]))
    try require(RelaySystemSurfaceProjection.evaluate(event: unrelated, instanceID: instance).path == .unprojectable,
                "unrelated sync payload must never be interpreted as an activity notification")
    let malformed = try event(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": 123])
    try require(RelaySystemSurfaceProjection.evaluate(event: malformed, instanceID: instance).path == .unsupportedState,
                "malformed terminal outcome must not fall back to successful completion")
    let futureFrame = RelayEvent(kind: "sync.message", payload: try JSONSerialization.data(withJSONObject: [
        "activity": ["futureCase": ["agentId": UUID().uuidString, "status": "done"]],
    ]))
    try require(RelaySystemSurfaceProjection.evaluate(event: futureFrame, instanceID: instance).path == .unprojectable,
                "unknown activity envelope case must not become a guessed alert")
    let snapshotAgent = UUID().uuidString
    let snapshot = RelayEvent(kind: "sync.message", payload: try JSONSerialization.data(withJSONObject: [
        "activity": ["_0": ["snapshot": ["_0": ["byAgent": [snapshotAgent, ["status": "working", "recent": [
            ["agentId": snapshotAgent, "status": "done", "terminalOutcome": "succeeded", "sequence": 1],
            ["agentId": snapshotAgent, "status": "working", "sequence": 2],
        ]]]]]]],
    ]))
    try require(RelaySystemSurfaceProjection.evaluate(event: snapshot, instanceID: instance).path == .progress,
                "snapshot must inspect the selected agent's newest event, not old completed history")
    witnessed.formUnion(try runTaskPolicyChecks(instance: instance))
    try require(witnessed == Set(RelayNotificationPath.allCases), "every registered decision path must have a behavioral witness")
    for outcome in ["cancelled", "interrupted"] {
        let value = try event(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": outcome])
        try require(RelaySystemSurfaceProjection.project(event: value, instanceID: instance)?.notification == nil,
                    "\(outcome) must never produce a successful completion alert")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-notification-check-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 11, count: 32)
    let path = directory.appendingPathComponent("relay.sqlite").path
    // Build a real v1 database first, then open it through the current store.
    // The migration must preserve instance/credential tables, not reset them.
    let oldDatabase = try DatabaseQueue(path: path)
    try RelayStore.migrator.migrate(oldDatabase, upTo: "relay-v1")
    let legacyInstance = UUID()
    try await oldDatabase.write { db in
        try db.execute(sql: "INSERT INTO instances(id,label,created_at) VALUES (?,?,?)",
                       arguments: [legacyInstance.uuidString, "Existing v1 Mac", 1000])
        try db.execute(sql: "INSERT INTO credentials(id,instance_id,token_hash,role,capabilities,device_label,created_at) VALUES (?,?,?,?,?,?,?)",
                       arguments: [UUID().uuidString, legacyInstance.uuidString, Data(SHA256.hash(data: Data("legacy-fixture-bearer".utf8))),
                                   "desktop", "publishState", "Existing Mac", 1000])
    }
    let store = try RelayStore(path: path, masterKey: key)
    try require(try await store.health().schemaVersion == 4, "v1 database must migrate to notification-outbox schema")
    try require(try await store.authenticate("legacy-fixture-bearer").instanceID == legacyInstance,
                "schema upgrade must preserve existing instance and credential authority")
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let desktop = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Fixture Mac"))
    let desktopAuth = try await store.authenticate(desktop.credential)
    func pair(_ label: String) async throws -> RelayCredentialContext {
        let grant = try await store.createPairingGrant(auth: desktopAuth, deviceLabel: label)
        let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: label))
        return try await store.authenticate(phone.credential)
    }
    let revoked = try await pair("Revoked")
    let retained = try await pair("Retained")
    for kind in RelayPushRegistrationKind.allCases {
        try await store.savePushToken(auth: revoked, kind: kind, token: Data("revoked-\(kind.rawValue)".utf8))
        try await store.savePushToken(auth: retained, kind: kind, token: Data("retained-\(kind.rawValue)".utf8))
    }
    let configuration = RelayAPNSConfiguration(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
    let duplicateTransport = NotificationTransportFixture()
    let duplicateSender = try RelayAPNSService(store: store, configuration: configuration,
                                              transport: duplicateTransport, trace: { _ in })
    var repeatEvent = try event(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded",
                                "sequence": 11, "replicaId": UUID().uuidString, "occurredAtReferenceInterval": 1000])
    await duplicateSender.deliver(event: repeatEvent, instanceID: desktop.instanceID)
    repeatEvent.sequence = 999 // Republish has a new relay sequence but the SAME source event.
    await duplicateSender.deliver(event: repeatEvent, instanceID: desktop.instanceID)
    let duplicateRequests = await duplicateTransport.captured()
    try require(duplicateRequests.filter { $0.headers["apns-push-type"] == "alert" }.count == 2,
                "same source event republished must alert each eligible phone only once")
    let reopened = try RelayStore(path: path, masterKey: key)
    let restartSender = try RelayAPNSService(store: reopened, configuration: configuration,
                                            transport: duplicateTransport, trace: { _ in })
    await restartSender.deliver(event: repeatEvent, instanceID: desktop.instanceID)
    try require(await duplicateTransport.captured().filter { $0.headers["apns-push-type"] == "alert" }.count == 2,
                "accepted source event remains deduplicated after restart")
    var nextPayload = (try JSONSerialization.jsonObject(with: repeatEvent.payload) as! [String: Any])["activity"] as! [String: Any]
    var nextFields = nextPayload["event"] as! [String: Any]
    nextFields["sequence"] = 900 // Inventory rebuild renumbers positional sequences.
    nextPayload["event"] = nextFields
    repeatEvent.payload = try JSONSerialization.data(withJSONObject: ["activity": nextPayload])
    await restartSender.deliver(event: repeatEvent, instanceID: desktop.instanceID)
    try require(await duplicateTransport.captured().filter { $0.headers["apns-push-type"] == "alert" }.count == 2,
                "positional inventory renumbering must not re-alert an unchanged source timestamp")
    nextFields["sequence"] = 12
    nextFields["occurredAtReferenceInterval"] = 1001 // New event, same agent/status.
    nextPayload["event"] = nextFields
    repeatEvent.payload = try JSONSerialization.data(withJSONObject: ["activity": nextPayload])
    let concurrentEvent = repeatEvent
    async let sendA: Void = duplicateSender.deliver(event: concurrentEvent, instanceID: desktop.instanceID)
    async let sendB: Void = restartSender.deliver(event: concurrentEvent, instanceID: desktop.instanceID)
    _ = await (sendA, sendB)
    try require(await duplicateTransport.captured().filter { $0.headers["apns-push-type"] == "alert" }.count == 4,
                "concurrent services deliver a new source event once per phone")
    guard let registration = try await store.pushRegistrations(instanceID: desktop.instanceID).first else {
        throw NotificationCheckFailure(description: "missing fixture registration")
    }
    let leaseKey = "fixture-abandoned-decision"
    guard let originalLease = try await store.claimPushDecision(registrationID: registration.id, decisionKey: leaseKey,
                                                               now: Date(timeIntervalSince1970: 1000)) else {
        throw NotificationCheckFailure(description: "first lease refused")
    }
    try require(try await reopened.claimPushDecision(registrationID: registration.id, decisionKey: leaseKey,
                                                    now: Date(timeIntervalSince1970: 1001)) == nil,
                "in-flight claim cannot be duplicated")
    guard let replacementLease = try await reopened.claimPushDecision(registrationID: registration.id, decisionKey: leaseKey,
                                                                      now: Date(timeIntervalSince1970: 1121)) else {
        throw NotificationCheckFailure(description: "abandoned lease not recoverable")
    }
    try await store.finishPushDecision(registrationID: registration.id, decisionKey: leaseKey, claimID: originalLease, accepted: true)
    try await reopened.finishPushDecision(registrationID: registration.id, decisionKey: leaseKey, claimID: replacementLease, accepted: false)
    try require(try await store.claimPushDecision(registrationID: registration.id, decisionKey: leaseKey,
                                                 now: Date(timeIntervalSince1970: 1122)) != nil,
                "stale lease owner must not mark a newer attempt accepted")
    let completion = try event(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded",
                                "summary": "private content /secret/path", "agentName": "/secret/path"])
    let deliveryClock = NotificationClockFixture()
    for (code, fails, expected) in [(200, false, RelayNotificationTrace.Outcome.acceptedByApple),
                                   (503, false, .rejectedByApple), (200, true, .transportFailure)] {
        let transport = NotificationTransportFixture(status: code, fails: fails)
        let traces = NotificationTraceFixture()
        let sender = try RelayAPNSService(store: store, configuration: configuration, transport: transport, trace: traces.append, clock: deliveryClock.now)
        let attemptEvent = try event(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded",
                                      "summary": "private content /secret/path", "agentName": "/secret/path"])
        await sender.deliver(event: attemptEvent, instanceID: desktop.instanceID)
        let attempts = await transport.captured()
        try require(attempts.count == 8, "all four surfaces of both eligible phones receive a request")
        try require(traces.captured().count == 8 && traces.captured().allSatisfy { $0.path == .completion && $0.outcome == expected },
                    "each actual attempt must report its path and provider outcome")
        let encoded = String(decoding: try JSONEncoder().encode(traces.captured()), as: UTF8.self)
        try require(!encoded.contains("secret") && !encoded.contains("token") && !encoded.contains("bearer"), "trace must not leak private content, tokens, headers or error details")
        let alert = attempts.first { $0.headers["apns-push-type"] == "alert" }
        let payload = try JSONSerialization.jsonObject(with: alert?.body ?? Data()) as? [String: Any]
        try require(payload?["notificationPath"] as? String == "H-04", "phone alert must identify the mapped decision")
        if code != 200 || fails {
            deliveryClock.advance(1000)
            let recoveryTransport = NotificationTransportFixture()
            let recoverySender = try RelayAPNSService(store: store, configuration: configuration,
                                                      transport: recoveryTransport, trace: { _ in },
                                                      clock: deliveryClock.now)
            await recoverySender.deliver(event: attemptEvent, instanceID: desktop.instanceID)
            try require(await recoveryTransport.captured().filter { $0.headers["apns-push-type"] == "alert" }.count == 2,
                        "failed attempt must not permanently deduplicate later recovery")
        }
        let quiet = try event(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "cancelled"])
        await sender.deliver(event: quiet, instanceID: desktop.instanceID)
        let afterCancellation = await transport.captured()
        try require(afterCancellation.count == attempts.count + 6, "cancelled task updates non-alert surfaces but sends no completion banner")
        for request in afterCancellation.dropFirst(attempts.count) where request.headers["apns-push-type"] == "liveactivity" {
            try require(!String(decoding: request.body, as: UTF8.self).contains("completed"), "cancelled Live Activity must not claim success")
        }
    }
    try await store.revokeCredential(auth: desktopAuth, credentialID: revoked.credentialID)
    let recipients = try await store.pushRegistrations(instanceID: desktop.instanceID)
    try require(recipients.count == 4 && recipients.allSatisfy { $0.deviceID == retained.deviceID },
                "credential revocation must remove every push surface for only the revoked phone")
    let restarted = try RelayStore(path: path, masterKey: key)
    try require(try await restarted.pushRegistrations(instanceID: desktop.instanceID) == recipients,
                "revocation must survive relay restart")
    let postRevocationTransport = NotificationTransportFixture()
    let postRevocationSender = try RelayAPNSService(store: restarted, configuration: configuration,
                                                   transport: postRevocationTransport, trace: { _ in }, clock: deliveryClock.now)
    await postRevocationSender.deliver(event: completion, instanceID: desktop.instanceID)
    let postRevocationRequests = await postRevocationTransport.captured()
    let expectedTokens = Set(recipients.map { registration in
        registration.token.map { String(format: "%02x", $0) }.joined()
    })
    try require(postRevocationRequests.count == 4
                && Set(postRevocationRequests.map { $0.url.lastPathComponent }) == expectedTokens,
                "actual sends after restart must target only the retained phone's four tokens")
    try await store.adminRevokeCredential(retained.credentialID)
    try require(try await store.pushRegistrations(instanceID: desktop.instanceID).isEmpty,
                "admin device revocation must stop all pushes")
    let last = try await pair("Instance revoked")
    try await store.savePushToken(auth: last, kind: .apns, token: Data("last-token".utf8))
    let invalidation = NotificationTransportFixture(status: 410)
    let invalidationTraces = NotificationTraceFixture()
    let invalidationSender = try RelayAPNSService(store: store, configuration: configuration, transport: invalidation, trace: invalidationTraces.append, clock: deliveryClock.now)
    await invalidationSender.deliver(event: completion, instanceID: desktop.instanceID)
    try require(try await store.pushRegistrations(instanceID: desktop.instanceID).isEmpty, "Apple 410 must remove expired token")
    try require(invalidationTraces.captured().map(\.outcome) == [.tokenInvalidated], "410 must be visible as token invalidation")
    try await store.savePushToken(auth: last, kind: .apns, token: Data("rotated-token".utf8))
    try await store.adminRevokeInstance(desktop.instanceID)
    try require(try await store.pushRegistrations(instanceID: desktop.instanceID).isEmpty,
                "instance revocation must stop all pushes")
    let emptyTransport = NotificationTransportFixture()
    let emptyTraces = NotificationTraceFixture()
    let emptySender = try RelayAPNSService(store: store, configuration: configuration, transport: emptyTransport, trace: emptyTraces.append)
    await emptySender.deliver(event: completion, instanceID: desktop.instanceID)
    try require(await emptyTransport.captured().isEmpty && emptyTraces.captured().map(\.outcome) == [.noRecipients], "revoked instance produces no request and explains why")
    print("Relay notification behavior passed: every decision path, cancellation, old outcome suppression, redacted delivery traces, 410, revocation, restart")
}
