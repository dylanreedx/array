import Foundation
import Crypto
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-relay-check-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let path = directory.appendingPathComponent("relay.sqlite").path
let key = Data(repeating: 7, count: 32)
let store = try RelayStore(path: path, masterKey: key, eventTailLimit: 100)

func provision(_ label: String) async throws -> (RelayDesktopProvisioning, RelayCredentialContext) {
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let desktop = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: label))
    return (desktop, try await store.authenticate(desktop.credential))
}
let (first, firstAuth) = try await provision("Mac A")
let (_, secondAuth) = try await provision("Mac B")
let grant = try await store.createPairingGrant(auth: firstAuth, deviceLabel: "Phone")
let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Phone"))
let phoneAuth = try await store.authenticate(phone.credential)
expect(phone.instanceID == first.instanceID, "pairing must stay in instance")
expect(!phone.capabilities.contains(.publishState), "phone must not publish")

let published = try await store.publish(auth: firstAuth, request: .init(kind: "snapshot", payload: Data("safe".utf8), isSnapshot: true))
expect(published.sequence == 1, "first sequence")
let own = try await store.events(auth: phoneAuth, after: 0)
let other = try await store.events(auth: secondAuth, after: 0)
expect(own.snapshot?.payload == Data("safe".utf8), "own snapshot visible")
expect(other.snapshot == nil && other.events.isEmpty, "cross-instance isolation")
do { _ = try await store.publish(auth: phoneAuth, request: .init(kind: "bad", payload: Data())); fatalError("phone published") } catch RelayStoreError.forbidden {}
do { _ = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Replay")); fatalError("grant reused") } catch RelayStoreError.invalidOrExpiredCode {}
let cancellable = try await store.createPairingGrant(auth: firstAuth, deviceLabel: "Cancelled Phone")
do { try await store.cancelPairingGrant(auth: secondAuth, id: cancellable.id); fatalError("cross-instance cancellation") } catch RelayStoreError.invalidOrExpiredCode {}
try await store.cancelPairingGrant(auth: firstAuth, id: cancellable.id)
do { _ = try await store.exchangePairingGrant(.init(code: cancellable.code, deviceLabel: "Cancelled Phone")); fatalError("cancelled grant exchanged") } catch RelayStoreError.invalidOrExpiredCode {}
let racing = try await store.createPairingGrant(auth: firstAuth, deviceLabel: "Race Phone")
async let cancellationWon: Bool = { do { try await store.cancelPairingGrant(auth: firstAuth, id: racing.id); return true } catch { return false } }()
async let exchangeWon: Bool = { do { _ = try await store.exchangePairingGrant(.init(code: racing.code, deviceLabel: "Race Phone")); return true } catch { return false } }()
let raceOutcome = await (cancellationWon, exchangeWon)
expect(raceOutcome.0 != raceOutcome.1, "cancel/exchange race has exactly one winner")
let command = RelayCommandRequest(idempotencyKey: UUID(), kind: "agent.stop", agentID: UUID())
let receiptA = try await store.acceptCommand(auth: phoneAuth, request: command)
let receiptB = try await store.acceptCommand(auth: phoneAuth, request: command)
expect(receiptA.idempotencyKey == receiptB.idempotencyKey && receiptA.accepted == receiptB.accepted, "command receipt idempotency")
let pushToken = Data("plaintext-device-token-must-not-appear".utf8)
try await store.savePushToken(auth: phoneAuth, kind: .apns, token: pushToken)
try await store.savePushToken(auth: phoneAuth, kind: .widget, token: Data("widget-token".utf8))
try await store.savePushToken(auth: phoneAuth, kind: .liveActivity, token: Data("activity-update-token".utf8))
try await store.savePushToken(auth: phoneAuth, kind: .liveActivityStart, token: Data("activity-start-token".utf8))
let registeredKinds = try await store.pushRegistrationKinds(auth: phoneAuth)
expect(registeredKinds == [.apns, .widget, .liveActivity, .liveActivityStart], "distinct own push registrations")
expect(!((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()).contains(pushToken), "push token encrypted at rest")

actor APNSRecorder: RelayAPNSTransport {
    var requests: [RelayAPNSRequest] = []
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse { requests.append(request); return .init(statusCode: 200) }
    func captured() -> [RelayAPNSRequest] { requests }
}
let recorder = APNSRecorder()
let signingKey = P256.Signing.PrivateKey()
let apns = try RelayAPNSService(
    store: store,
    configuration: .init(keyID: "KEYID12345", teamID: "TEAMID1234", privateKeyPEM: signingKey.pemRepresentation),
    transport: recorder
)
let hostile = "private transcript /Users/dylan/secret.swift tool=terminal prompt=steal-me"
let activityPayload = try JSONSerialization.data(withJSONObject: [
    "activity": ["event": [
        "agentId": UUID().uuidString, "agentName": "Build Agent", "workspaceName": "Array",
        "status": "needsAttention", "approvalRequestId": "approval-safe-id", "summary": hostile,
    ]],
])
await apns.deliver(event: .init(kind: "sync.message", payload: activityPayload), instanceID: first.instanceID)
let apnsRequests = await recorder.captured()
expect(apnsRequests.count == 4, "APNs, widget, activity update, and activity start projected")
expect(apnsRequests.contains { $0.headers["apns-push-type"] == "alert" && $0.headers["apns-collapse-id"] == nil }, "approval is an uncoalesced alert")
expect(apnsRequests.filter { $0.headers["apns-push-type"] == "liveactivity" }.count == 2, "start and update ActivityKit pushes are distinct")
expect(apnsRequests.allSatisfy { !String(decoding: $0.body, as: UTF8.self).contains(hostile) && !String(decoding: $0.body, as: UTF8.self).contains("/Users/") }, "system surfaces exclude content and paths")
expect(apnsRequests.allSatisfy { ($0.headers["authorization"] ?? "").hasPrefix("bearer ") }, "APNs requests are signed")
let completionPayload = try JSONSerialization.data(withJSONObject: ["activity": ["event": ["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded", "summary": hostile]]])
await apns.deliver(event: .init(kind: "sync.message", payload: completionPayload), instanceID: first.instanceID)
let terminalAlert = await recorder.captured().last { $0.headers["apns-push-type"] == "alert" }
expect(terminalAlert?.headers["apns-collapse-id"] != nil, "completion bursts coalesce")
try await store.removePushToken(auth: phoneAuth, kind: .apns)
let remainingKinds = try await store.pushRegistrationKinds(auth: phoneAuth)
expect(remainingKinds == [.widget, .liveActivity, .liveActivityStart], "push token removal")
do { try await store.savePushToken(auth: firstAuth, kind: .apns, token: pushToken); fatalError("desktop registered push token") } catch RelayStoreError.forbidden {}

let restarted = try RelayStore(path: path, masterKey: key)
let restored = try await restarted.events(auth: try await restarted.authenticate(first.credential), after: 0)
expect(restored.latestSequence == 1, "restart persistence")
print("ContinuumRevivedRelayCoreChecks passed: isolation, one-use pairing, fixed scope, idempotency, restart")
