import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO
import ContinuumRevivedRelayProtocol

private struct OutboxHTTPFailure: Error { let message: String }
private actor RecoveryTransport: RelayAPNSTransport {
    let continuation: AsyncStream<RelayAPNSRequest>.Continuation
    private var requests: [RelayAPNSRequest] = []
    init(_ continuation: AsyncStream<RelayAPNSRequest>.Continuation) { self.continuation = continuation }
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        requests.append(request)
        continuation.yield(request)
        return .init(statusCode: 200)
    }
    func captured() -> [RelayAPNSRequest] { requests }
}

private func waitForOutboxTrace(_ stream: AsyncStream<RelayNotificationTrace>, outcome: RelayNotificationTrace.Outcome) async throws {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { for await value in stream where value.outcome == outcome { return true }; return false }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw OutboxHTTPFailure(message: "outbox worker timed out awaiting \(outcome)") }
        defer { group.cancelAll() }
        guard try await group.next() == true else { throw OutboxHTTPFailure(message: "notification trace ended") }
    }
}

func runRelayHTTPOutboxChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-outbox-http-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("relay.sqlite").path
    let key = Data(repeating: 18, count: 32)
    let store = try RelayStore(path: path, masterKey: key)
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Outbox Mac"))
    let auth = try await store.authenticate(mac.credential)
    let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Outbox phone")
    let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Outbox phone"))
    try await store.savePushToken(auth: try await store.authenticate(phone.credential), kind: .apns, token: Data("offline-fixture-token".utf8))
    // Publish with no sender, reproducing exit after durable event commit and
    // before the detached delivery task runs. Restart must need no republish.
    let first = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0))
    try await first.start()
    do {
        let payload = try JSONSerialization.data(withJSONObject: ["activity": ["event": [
            "agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded", "sequence": 1,
        ]]])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(first.listeningPublicPort!)/v2/events")!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(RelayPublishRequest(kind: "sync.message", payload: payload))
        request.setValue("Bearer \(mac.credential)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw OutboxHTTPFailure(message: "HTTP event publication") }
        try await first.stop()
    } catch { try? await first.stop(); throw error }
    let reopened = try RelayStore(path: path, masterKey: key)
    let stream = AsyncStream<RelayAPNSRequest>.makeStream()
    defer { stream.continuation.finish() }
    let traces = AsyncStream<RelayNotificationTrace>.makeStream()
    defer { traces.continuation.finish() }
    let transport = RecoveryTransport(stream.continuation)
    let sender = try RelayAPNSService(store: reopened,
        configuration: .init(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
        transport: transport, trace: { _ = traces.continuation.yield($0) })
    let restarted = RelayServer(store: reopened, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), pushDelivery: sender)
    try await restarted.start()
    do {
        try await waitForOutboxTrace(traces.stream, outcome: .acceptedByApple)
        guard try await reopened.pendingAlertCount(instanceID: mac.instanceID) == 0 else { throw OutboxHTTPFailure(message: "accepted queue body must be removed before stop") }
        guard let event = try await reopened.events(auth: auth, after: 0).events.last else { throw OutboxHTTPFailure(message: "persisted event missing") }
        await sender.deliverPublished(event: event, instanceID: mac.instanceID)
        guard await transport.captured().count == 1 else { throw OutboxHTTPFailure(message: "accepted replay must not resend") }
        try await restarted.stop()
    } catch { try? await restarted.stop(); throw error }
    print("Relay HTTP outbox checks passed: publish commit without sender → restart → real worker delivers persisted alert; fake APNs only")
    try await runHTTPOutboxRetryCheck(path: path, key: key, instance: mac.instanceID, auth: auth)
}

private final class HTTPOutboxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private actor RetryRecoveryTransport: RelayAPNSTransport {
    private var requests: [RelayAPNSRequest] = []
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        requests.append(request)
        return .init(statusCode: requests.count == 1 ? 503 : 200)
    }
    func captured() -> [RelayAPNSRequest] { requests }
}

@inline(never)
private func runHTTPOutboxRetryCheck(path: String, key: Data, instance: UUID, auth: RelayCredentialContext) async throws {
    let clock = HTTPOutboxClock(), transport = RetryRecoveryTransport()
    let store = try RelayStore(path: path, masterKey: key)
    let traces = AsyncStream<RelayNotificationTrace>.makeStream()
    defer { traces.continuation.finish() }
    let config = RelayAPNSConfiguration(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
    let event = try await store.publish(auth: auth, request: .init(kind: "sync.message", payload: JSONSerialization.data(withJSONObject: [
        "activity": ["event": ["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded"]],
    ])))
    // Publication uses the real server clock. Move the virtual worker clock
    // just beyond that commit before freezing time for the backoff witness.
    clock.advance(max(0, Date().timeIntervalSince(clock.now())) + 1)
    let sender = try RelayAPNSService(store: store, configuration: config, transport: transport,
                                     trace: { _ = traces.continuation.yield($0) }, clock: clock.now)
    let first = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), pushDelivery: sender)
    try await first.start()
    do {
        try await waitForOutboxTrace(traces.stream, outcome: .rejectedByApple)
        guard try await store.pendingAlertCount(instanceID: instance) == 1 else { throw OutboxHTTPFailure(message: "transient response must retain intent") }
        try await first.stop()
    } catch { try? await first.stop(); throw error }
    clock.advance(900)
    let reopened = try RelayStore(path: path, masterKey: key)
    let recovered = try RelayAPNSService(store: reopened, configuration: config, transport: transport,
                                        trace: { _ = traces.continuation.yield($0) }, clock: clock.now)
    let second = RelayServer(store: reopened, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), pushDelivery: recovered)
    try await second.start()
    do {
        try await waitForOutboxTrace(traces.stream, outcome: .acceptedByApple)
        await recovered.deliverPublished(event: event, instanceID: instance)
        let attempts = await transport.captured()
        guard attempts.count == 2, attempts[0].body == attempts[1].body,
              attempts[0].headers["apns-id"] == attempts[1].headers["apns-id"] else { throw OutboxHTTPFailure(message: "restart retry must reuse one persisted intent") }
        guard try await reopened.pendingAlertCount(instanceID: instance) == 0 else { throw OutboxHTTPFailure(message: "recovered accepted intent must be removed") }
        try await second.stop()
    } catch { try? await second.stop(); throw error }
    print("Relay outbox worker retry passed: transient 503 → shutdown → virtual +900 s → restarted worker accepts once; no republish")
}
