import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/86-relay-sync-transport.md (D4-R1)
// Executable checks for the RelayHub core: auth/scope, seq ordering, live
// fan-out, lossless catch-up (cursor / snapshot / eviction), no-dedupe
// doctrine, and the I5 taint gate on the publish path. All in-process: no
// sockets, no wall clock. Prints measured values; exits non-zero on the
// first failure (run-matrix.sh gates on it).

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let macToken = "check-mac-token"
let phoneToken = "check-phone-token"

let validator: RelayHub.TokenValidator = { token in
    switch token {
    case macToken: return RelayGrant(scopes: .operator)
    case phoneToken: return RelayGrant(scopes: .observer)
    default: return nil
    }
}

let replicaA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
let tile = UUID(uuidString: "0000D001-0000-4000-8000-000000000001")!

func opMessage(_ lamport: UInt64) -> SyncMessage {
    .op(LoggedOp(
        opId: OpId(lamport: lamport, replica: replicaA),
        op: .setTileFrame(id: tile, frame: TileFrame(x: Double(lamport), y: 0, width: 100, height: 100))
    ))
}

func snapshotMessage(through lamport: UInt64) -> SyncMessage {
    let log = (1...lamport).map { l in
        LoggedOp(
            opId: OpId(lamport: l, replica: replicaA),
            op: .setTileFrame(id: tile, frame: TileFrame(x: Double(l), y: 0, width: 100, height: 100))
        )
    }
    return .snapshot(compact(log: log, through: lamport).snapshot)
}

func hello(_ token: String, cursor: UInt64?) -> RelayClientHello {
    RelayClientHello(token: token, deviceLabel: "checks", cursor: cursor)
}

/// Drains exactly `count` envelopes from a stream. Deterministic because
/// every publish is awaited before collection and AsyncStream buffers.
func take(_ count: Int, from stream: AsyncStream<RelayEnvelope>) async -> [RelayEnvelope] {
    var collected: [RelayEnvelope] = []
    guard count > 0 else { return collected }
    for await envelope in stream {
        collected.append(envelope)
        if collected.count == count { break }
    }
    return collected
}

// 1. Auth: unknown token refused for subscribe and publish; observer scope
//    refused for publish (type-level D5 guarantee at the relay boundary).
do {
    let hub = RelayHub(validator: validator)
    do {
        _ = try await hub.subscribe(hello: hello("bogus", cursor: nil))
        expect(false, "assertion 1: unknown token must not subscribe")
    } catch let error as RelayHelloError {
        expect(error == .unauthorized, "assertion 1: expected unauthorized, got \(error)")
    }
    do {
        try await hub.publish(token: "bogus", message: opMessage(1))
        expect(false, "assertion 2: unknown token must not publish")
    } catch let error as RelayPublishError {
        expect(error == .unauthorized, "assertion 2: expected unauthorized, got \(error)")
    }
    do {
        try await hub.publish(token: phoneToken, message: opMessage(1))
        expect(false, "assertion 3: observer scope must not publish")
    } catch let error as RelayPublishError {
        expect(error == .scopeForbidsPublish, "assertion 3: expected scopeForbidsPublish, got \(error)")
    }
    do {
        _ = try await hub.subscribe(hello: RelayClientHello(protocolVersion: 99, token: phoneToken, deviceLabel: "checks", cursor: nil))
        expect(false, "assertion 4: protocol version 99 must be refused")
    } catch let error as RelayHelloError {
        expect(error == .unsupportedProtocolVersion(99), "assertion 4: expected unsupportedProtocolVersion, got \(error)")
    }
}

// 2. Live fan-out: two observers subscribed before any publish both receive
//    every envelope in hub order; seq strictly monotonic from 1.
var measuredSeqs: [UInt64] = []
do {
    let hub = RelayHub(validator: validator)
    let (welcomeA, streamA) = try await hub.subscribe(hello: hello(phoneToken, cursor: nil))
    let (_, streamB) = try await hub.subscribe(hello: hello(phoneToken, cursor: nil))
    expect(welcomeA.latestSeq == 0, "assertion 5: latestSeq before any publish is 0, got \(welcomeA.latestSeq)")
    for lamport: UInt64 in 1...3 {
        let seq = try await hub.publish(token: macToken, message: opMessage(lamport))
        measuredSeqs.append(seq)
    }
    expect(measuredSeqs == [1, 2, 3], "assertion 6: seqs strictly monotonic from 1, got \(measuredSeqs)")
    let gotA = await take(3, from: streamA)
    let gotB = await take(3, from: streamB)
    expect(gotA.map(\.seq) == [1, 2, 3], "assertion 7: subscriber A order, got \(gotA.map(\.seq))")
    expect(gotB.map(\.seq) == [1, 2, 3], "assertion 8: subscriber B order, got \(gotB.map(\.seq))")
    let count = await hub.subscriberCount
    expect(count == 2, "assertion 9: two live subscribers, got \(count)")
}

// 3. Catch-up, cursor inside the ring: exactly the tail after the cursor —
//    no duplicates, no gaps. Cursor at the head → empty backlog, live only.
do {
    let hub = RelayHub(validator: validator)
    for lamport: UInt64 in 1...4 {
        try await hub.publish(token: macToken, message: opMessage(lamport))
    }
    let (welcome, stream) = try await hub.subscribe(hello: hello(phoneToken, cursor: 2))
    expect(welcome.latestSeq == 4, "assertion 10: latestSeq 4, got \(welcome.latestSeq)")
    let got = await take(2, from: stream)
    expect(got.map(\.seq) == [3, 4], "assertion 11: tail after cursor 2 is [3,4], got \(got.map(\.seq))")

    let (_, headStream) = try await hub.subscribe(hello: hello(phoneToken, cursor: 4))
    try await hub.publish(token: macToken, message: opMessage(5))
    let headGot = await take(1, from: headStream)
    expect(headGot.map(\.seq) == [5], "assertion 12: up-to-date cursor gets live-only feed, got \(headGot.map(\.seq))")
}

// 4. Fresh subscriber with a snapshot in the ring: snapshot first, then only
//    the tail after it — pre-snapshot envelopes are compacted away.
do {
    let hub = RelayHub(validator: validator)
    try await hub.publish(token: macToken, message: opMessage(1))
    try await hub.publish(token: macToken, message: opMessage(2))
    try await hub.publish(token: macToken, message: snapshotMessage(through: 2)) // seq 3
    try await hub.publish(token: macToken, message: opMessage(3))               // seq 4
    let (_, stream) = try await hub.subscribe(hello: hello(phoneToken, cursor: nil))
    let got = await take(2, from: stream)
    expect(got.map(\.seq) == [3, 4], "assertion 13: fresh subscriber gets snapshot(3) + tail(4), got \(got.map(\.seq))")
    if case .snapshot = got[0].message {} else {
        expect(false, "assertion 14: first backlog envelope must be the snapshot")
    }
}

// 5. Evicted cursor bridged by a snapshot whose tail survives in the ring:
//    lossless (snapshot covers everything the publisher emitted before it).
do {
    let hub = RelayHub(ringCapacity: 3, validator: validator)
    try await hub.publish(token: macToken, message: opMessage(1))               // seq 1 (evicted)
    try await hub.publish(token: macToken, message: opMessage(2))               // seq 2 (evicted)
    try await hub.publish(token: macToken, message: snapshotMessage(through: 2)) // seq 3
    try await hub.publish(token: macToken, message: opMessage(3))               // seq 4
    try await hub.publish(token: macToken, message: opMessage(4))               // seq 5; ring = [3,4,5]
    let (_, stream) = try await hub.subscribe(hello: hello(phoneToken, cursor: 1))
    let got = await take(3, from: stream)
    expect(got.map(\.seq) == [3, 4, 5], "assertion 15: evicted cursor 1 bridged by snapshot, got \(got.map(\.seq))")
}

// 6. Evicted cursor with NO bridging snapshot: refused, never a holey feed.
//    Same for a fresh subscriber after eviction with no snapshot at all.
do {
    let hub = RelayHub(ringCapacity: 3, validator: validator)
    try await hub.publish(token: macToken, message: snapshotMessage(through: 1)) // seq 1 (will be evicted)
    for lamport: UInt64 in 2...5 {
        try await hub.publish(token: macToken, message: opMessage(lamport))      // seqs 2..5; ring = [3,4,5]
    }
    do {
        _ = try await hub.subscribe(hello: hello(phoneToken, cursor: 1))
        expect(false, "assertion 16: snapshot evicted before its tail — must refuse")
    } catch let error as RelayHelloError {
        expect(error == .cursorUnrecoverable(cursor: 1, ringStart: 3), "assertion 16: expected cursorUnrecoverable(1,3), got \(error)")
    }

    let bare = RelayHub(ringCapacity: 2, validator: validator)
    for lamport: UInt64 in 1...4 {
        try await bare.publish(token: macToken, message: opMessage(lamport))     // ring = [3,4], no snapshot
    }
    do {
        _ = try await bare.subscribe(hello: hello(phoneToken, cursor: nil))
        expect(false, "assertion 17: fresh subscriber after eviction with no snapshot — must refuse")
    } catch let error as RelayHelloError {
        expect(error == .cursorUnrecoverable(cursor: 0, ringStart: 3), "assertion 17: expected cursorUnrecoverable(0,3), got \(error)")
    }
}

// 7. No dedupe: the same LoggedOp published twice is delivered twice with
//    distinct seqs — idempotency is materialize's job, not the relay's.
do {
    let hub = RelayHub(validator: validator)
    let (_, stream) = try await hub.subscribe(hello: hello(phoneToken, cursor: nil))
    let duplicate = opMessage(7)
    let first = try await hub.publish(token: macToken, message: duplicate)
    let second = try await hub.publish(token: macToken, message: duplicate)
    expect(first != second, "assertion 18: duplicate publishes get distinct seqs")
    let got = await take(2, from: stream)
    expect(got[0].message == got[1].message, "assertion 19: both duplicates delivered verbatim")
}

// 8. I5 taint gate: wired into the real publish path (scanned byte count
//    grows), and refuses adversarial pre-encoded bytes that no type-safe
//    SyncMessage could produce.
var scannedBytes = 0
do {
    let hub = RelayHub(validator: validator)
    try await hub.publish(token: macToken, message: opMessage(1))
    scannedBytes = await hub.taintScannedByteCount
    expect(scannedBytes > 0, "assertion 20: publish path must scan encoded bytes, scanned \(scannedBytes)")
    do {
        try await hub.scanPreEncodedForChecks(token: macToken, encodedJSON: #"{"op":{"pid":1234,"tmuxTarget":"%7"}}"#)
        expect(false, "assertion 21: adversarial pid/tmuxTarget keys must be refused")
    } catch let error as RelayPublishError {
        guard case .taintViolation(let patterns) = error else {
            expect(false, "assertion 21: expected taintViolation, got \(error)")
            fatalError("unreachable")
        }
        expect(patterns.contains("\"pid\":") && patterns.contains("\"tmuxTarget\":"), "assertion 22: both forbidden keys reported, got \(patterns)")
    }
    do {
        try await hub.scanPreEncodedForChecks(token: phoneToken, encodedJSON: "{}")
        expect(false, "assertion 23: the adversarial seam honors scope too")
    } catch let error as RelayPublishError {
        expect(error == .scopeForbidsPublish, "assertion 23: expected scopeForbidsPublish, got \(error)")
    }
}

// 9. Disconnect: a removed subscriber's stream finishes and receives nothing
//    published afterward.
do {
    let hub = RelayHub(validator: validator)
    let (welcome, stream) = try await hub.subscribe(hello: hello(phoneToken, cursor: nil))
    try await hub.publish(token: macToken, message: opMessage(1))
    await hub.disconnect(welcome.sessionId)
    try await hub.publish(token: macToken, message: opMessage(2))
    var received: [UInt64] = []
    for await envelope in stream {
        received.append(envelope.seq)
    }
    expect(received == [1], "assertion 24: disconnected stream ends after pre-disconnect envelopes, got \(received)")
    let count = await hub.subscriberCount
    expect(count == 0, "assertion 25: subscriber registry empty after disconnect, got \(count)")
}

print("ContinuumRevivedRelayChecks passed: auth/scope refusals, seq order \(measuredSeqs) via publish, 2-subscriber fan-out, lossless catch-up (in-ring tail, snapshot bridge, unrecoverable refusals), no-dedupe doctrine, I5 gate on publish path (\(scannedBytes) bytes scanned via taintScannedByteCount), disconnect semantics")

// ── Slice 2, milestone A: stateless pull API (the HTTP adapter's primitive) ──

// 10. Pull with backlog available returns immediately; maxCount truncates;
//     cursor semantics identical to subscribe.
do {
    let hub = RelayHub(validator: validator)
    for lamport: UInt64 in 1...5 {
        try await hub.publish(token: macToken, message: opMessage(lamport))
    }
    let tail = try await hub.pollEnvelopes(token: phoneToken, afterSeq: 2)
    expect(tail.map(\.seq) == [3, 4, 5], "assertion 26: poll after 2 → [3,4,5], got \(tail.map(\.seq))")
    let truncated = try await hub.pollEnvelopes(token: phoneToken, afterSeq: 0, maxCount: 3)
    expect(truncated.map(\.seq) == [1, 2, 3], "assertion 27: maxCount 3 truncates, got \(truncated.map(\.seq))")
    do {
        _ = try await hub.pollEnvelopes(token: "bogus", afterSeq: 0)
        expect(false, "assertion 28: unknown token must not poll")
    } catch let error as RelayHelloError {
        expect(error == .unauthorized, "assertion 28: expected unauthorized, got \(error)")
    }
    let latest = try await hub.validateCursor(token: phoneToken, afterSeq: 2)
    expect(latest == 5, "assertion 29: validateCursor reports latestSeq 5, got \(latest)")
}

// 11. Pull on an empty hub suspends until a publish lands (either
//     interleaving of registration vs publish is correct).
do {
    let hub = RelayHub(validator: validator)
    let pollTask = Task { try await hub.pollEnvelopes(token: phoneToken, afterSeq: 0) }
    await Task.yield()
    try await hub.publish(token: macToken, message: opMessage(1))
    let got = try await pollTask.value
    expect(got.map(\.seq) == [1], "assertion 30: suspended poll resumes with [1], got \(got.map(\.seq))")
    let waiters = await hub.waiterCount
    expect(waiters == 0, "assertion 31: no waiters left after resume, got \(waiters)")
}

// 12. A cancelled waiter returns [] and leaks nothing.
do {
    let hub = RelayHub(validator: validator)
    let pollTask = Task { try await hub.pollEnvelopes(token: phoneToken, afterSeq: 0) }
    for _ in 0..<5 { await Task.yield() }
    pollTask.cancel()
    let got = try await pollTask.value
    expect(got.isEmpty, "assertion 32: cancelled poll returns [], got \(got.map(\.seq))")
    let waiters = await hub.waiterCount
    expect(waiters == 0, "assertion 33: cancelled waiter removed, got \(waiters)")
}

// 13. Unrecoverable cursors refuse through the pull API too.
do {
    let hub = RelayHub(ringCapacity: 2, validator: validator)
    for lamport: UInt64 in 1...4 {
        try await hub.publish(token: macToken, message: opMessage(lamport))
    }
    do {
        _ = try await hub.pollEnvelopes(token: phoneToken, afterSeq: 1)
        expect(false, "assertion 34: evicted cursor with no snapshot must refuse via poll")
    } catch let error as RelayHelloError {
        expect(error == .cursorUnrecoverable(cursor: 1, ringStart: 3), "assertion 34: expected cursorUnrecoverable(1,3), got \(error)")
    }
}

// ── Slice 2, milestone A: HTTP adapter on a real loopback socket ──
// (Socket-binding precedent: LocalPairingEndpointChecks. Correctness of hub
// semantics is proven above in-process; these assertions prove ROUTING —
// auth extraction, DTO round-trips, status-code mapping — with no sleeps:
// every long-poll below has its data published first.)

struct HTTPReply {
    var status: Int
    var body: Data
}

func request(_ method: String, _ url: String, token: String? = nil, body: Data? = nil) async throws -> HTTPReply {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    request.timeoutInterval = 10
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return HTTPReply(status: (response as! HTTPURLResponse).statusCode, body: data)
}

func decode<T: Decodable>(_ type: T.Type, _ reply: HTTPReply, _ label: String) -> T {
    guard let decoded = try? JSONDecoder().decode(type, from: reply.body) else {
        fputs("FAIL: \(label): body did not decode as \(type): \(String(decoding: reply.body, as: UTF8.self))\n", stderr)
        exit(1)
    }
    return decoded
}

var httpEnvelopeCount = 0
do {
    let registry = RelayTokenRegistry(seed: [
        macToken: RelayGrant(scopes: .operator),
        phoneToken: RelayGrant(scopes: .observer),
    ])
    let hub = RelayHub { token in await registry.grant(for: token) }
    let server = RelayHTTPServer(hub: hub, registry: registry)
    try server.start()
    let base = "http://127.0.0.1:\(server.port)"

    // 14. Health, no auth needed.
    let health = try await request("GET", "\(base)/v1/health")
    expect(health.status == 200, "assertion 35: health 200, got \(health.status)")
    expect(decode(RelayHealthResponse.self, health, "assertion 35b").latestSeq == 0, "assertion 35b: latestSeq 0")

    // 15. Hello: 401 without/with bad token; 426 wrong version; 200 with cursor validation.
    let helloBody = try JSONEncoder().encode(RelayHelloRequestBody(deviceLabel: "checks", cursor: nil))
    let helloNoToken = try await request("POST", "\(base)/v1/hello", body: helloBody)
    expect(helloNoToken.status == 401, "assertion 36: hello without token → 401, got \(helloNoToken.status)")
    let helloBadToken = try await request("POST", "\(base)/v1/hello", token: "bogus", body: helloBody)
    expect(helloBadToken.status == 401, "assertion 37: hello bad token → 401, got \(helloBadToken.status)")
    let wrongVersion = try JSONEncoder().encode(RelayHelloRequestBody(protocolVersion: 99, deviceLabel: "checks", cursor: nil))
    let helloWrongVersion = try await request("POST", "\(base)/v1/hello", token: phoneToken, body: wrongVersion)
    expect(helloWrongVersion.status == 426, "assertion 38: wrong protocol → 426, got \(helloWrongVersion.status)")
    let hello = try await request("POST", "\(base)/v1/hello", token: phoneToken, body: helloBody)
    expect(hello.status == 200, "assertion 39: hello → 200, got \(hello.status) \(String(decoding: hello.body, as: UTF8.self))")

    // 16. Publish: 403 for observer, 400 for garbage, 200 with seq for operator.
    let opBody = try JSONEncoder().encode(opMessage(1))
    let observerPublish = try await request("POST", "\(base)/v1/publish", token: phoneToken, body: opBody)
    expect(observerPublish.status == 403, "assertion 40: observer publish → 403, got \(observerPublish.status)")
    let garbagePublish = try await request("POST", "\(base)/v1/publish", token: macToken, body: Data("junk".utf8))
    expect(garbagePublish.status == 400, "assertion 41: garbage body → 400, got \(garbagePublish.status)")
    let published = try await request("POST", "\(base)/v1/publish", token: macToken, body: opBody)
    expect(published.status == 200, "assertion 42: operator publish → 200, got \(published.status)")
    expect(decode(RelayPublishResponse.self, published, "assertion 42b").seq == 1, "assertion 42b: first seq is 1")

    // 17. Poll: data already present → long-poll returns immediately with the
    //     tail; peek path (waitMs=0) at the head returns empty; DTO carries latestSeq.
    let poll = try await request("GET", "\(base)/v1/poll?after=0&waitMs=5000", token: phoneToken)
    expect(poll.status == 200, "assertion 43: poll → 200, got \(poll.status)")
    let pollDecoded = decode(RelayPollResponse.self, poll, "assertion 43b")
    httpEnvelopeCount = pollDecoded.envelopes.count
    expect(pollDecoded.envelopes.map(\.seq) == [1] && pollDecoded.latestSeq == 1, "assertion 43b: envelopes [1] latestSeq 1, got \(pollDecoded.envelopes.map(\.seq)) \(pollDecoded.latestSeq)")
    let drained = try await request("GET", "\(base)/v1/poll?after=1&waitMs=0", token: phoneToken)
    let drainedDecoded = decode(RelayPollResponse.self, drained, "assertion 44")
    expect(drained.status == 200 && drainedDecoded.envelopes.isEmpty, "assertion 44: peek at head → empty 200")

    // 18. Token registration: operator registers a new observer token → it
    //     can poll; observer may not register.
    let newToken = "check-registered-token"
    let registerBody = try JSONEncoder().encode(RelayRegisterTokenRequestBody(token: newToken, scopeRawValue: Scope.observer.rawValue))
    let observerRegister = try await request("POST", "\(base)/v1/tokens", token: phoneToken, body: registerBody)
    expect(observerRegister.status == 403, "assertion 45: observer register → 403, got \(observerRegister.status)")
    let operatorRegister = try await request("POST", "\(base)/v1/tokens", token: macToken, body: registerBody)
    expect(operatorRegister.status == 204, "assertion 46: operator register → 204, got \(operatorRegister.status)")
    let registeredPoll = try await request("GET", "\(base)/v1/poll?after=0&waitMs=0", token: newToken)
    expect(registeredPoll.status == 200, "assertion 47: registered token polls → 200, got \(registeredPoll.status)")

    // 19. Unknown route → 404.
    let unknownRoute = try await request("GET", "\(base)/v1/nope", token: phoneToken)
    expect(unknownRoute.status == 404, "assertion 48: unknown route → 404, got \(unknownRoute.status)")

    server.stop()
}

// 20. Unrecoverable cursor surfaces as HTTP 409 with machine-readable body.
do {
    let registry = RelayTokenRegistry(seed: [
        macToken: RelayGrant(scopes: .operator),
        phoneToken: RelayGrant(scopes: .observer),
    ])
    let hub = RelayHub(ringCapacity: 2) { token in await registry.grant(for: token) }
    let server = RelayHTTPServer(hub: hub, registry: registry)
    try server.start()
    let base = "http://127.0.0.1:\(server.port)"
    for lamport: UInt64 in 1...4 {
        let body = try JSONEncoder().encode(opMessage(lamport))
        _ = try await request("POST", "\(base)/v1/publish", token: macToken, body: body)
    }
    let conflict = try await request("GET", "\(base)/v1/poll?after=1&waitMs=0", token: phoneToken)
    expect(conflict.status == 409, "assertion 49: evicted cursor → 409, got \(conflict.status)")
    let errorBody = decode(RelayErrorBody.self, conflict, "assertion 50")
    expect(errorBody.code == "cursorUnrecoverable" && errorBody.ringStart == 3, "assertion 50: error body names cursorUnrecoverable ringStart 3, got \(errorBody)")
    server.stop()
}

print("ContinuumRevivedRelayChecks passed: pull API (immediate/suspend/cancel/unrecoverable, waiter hygiene), HTTP adapter on loopback (health, hello auth+version, publish 403/400/200, poll tail+peek DTO round-trip \(httpEnvelopeCount) envelope(s), runtime token registration, 404, 409 cursorUnrecoverable)")

// ── Slice 2, milestone B: RelaySyncTransport client against a live server ──
// Real loopback HTTP; retry/backoff schedules injected in milliseconds so
// convergence is fast. Every wait is bounded by a publish that has already
// happened or a retry loop that provably converges.

final class CursorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func record(_ value: UInt64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    var latest: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

func takeMessages(_ count: Int, from stream: AsyncStream<SyncMessage>) async -> [SyncMessage] {
    var collected: [SyncMessage] = []
    guard count > 0 else { return collected }
    for await message in stream {
        collected.append(message)
        if collected.count == count { break }
    }
    return collected
}

func takeStates(_ count: Int, from stream: AsyncStream<ContinuumRevivedSync.ConnectionState>) async -> [ContinuumRevivedSync.ConnectionState] {
    var collected: [ContinuumRevivedSync.ConnectionState] = []
    guard count > 0 else { return collected }
    for await state in stream {
        collected.append(state)
        if collected.count == count { break }
    }
    return collected
}

// 21. Backlog + live consumption, cursor advance, operator send() round-trip.
do {
    let registry = RelayTokenRegistry(seed: [
        macToken: RelayGrant(scopes: .operator),
        phoneToken: RelayGrant(scopes: .observer),
    ])
    let hub = RelayHub { token in await registry.grant(for: token) }
    let server = RelayHTTPServer(hub: hub, registry: registry)
    try server.start()
    let base = URL(string: "http://127.0.0.1:\(server.port)")!

    for lamport: UInt64 in 1...2 {
        let body = try JSONEncoder().encode(opMessage(lamport))
        let published = try await request("POST", "\(base)/v1/publish", token: macToken, body: body)
        expect(published.status == 200, "assertion 51: seed publish → 200, got \(published.status)")
    }

    let cursors = CursorRecorder()
    let observer = RelaySyncTransport(
        baseURL: base,
        bearerToken: phoneToken,
        deviceLabel: "checks-observer",
        pollWaitMs: 3_000,
        backoffNanoseconds: [10_000_000],
        onCursorChange: { cursors.record($0) }
    )
    observer.start()

    let backlog = await takeMessages(2, from: observer.inbound)
    expect(backlog == [opMessage(1), opMessage(2)], "assertion 52: transport consumes the backlog verbatim")
    expect(cursors.latest == 2, "assertion 53: cursor advanced to 2, got \(String(describing: cursors.latest))")

    let firstState = await takeStates(1, from: observer.connectionState)
    expect(firstState == [ContinuumRevivedSync.ConnectionState.connected], "assertion 54: first connection state is connected, got \(firstState)")

    // Live delivery through a parked long-poll: publish while the transport waits.
    let liveBody = try JSONEncoder().encode(opMessage(3))
    _ = try await request("POST", "\(base)/v1/publish", token: macToken, body: liveBody)
    let live = await takeMessages(1, from: observer.inbound)
    expect(live == [opMessage(3)], "assertion 55: live envelope delivered through the parked poll")
    expect(cursors.latest == 3, "assertion 56: cursor advanced to 3, got \(String(describing: cursors.latest))")

    // send(): the Mac leg publishes through the same transport type.
    let publisher = RelaySyncTransport(baseURL: base, bearerToken: macToken, deviceLabel: "checks-publisher", backoffNanoseconds: [10_000_000])
    try await publisher.send(opMessage(4))
    let sent = await takeMessages(1, from: observer.inbound)
    expect(sent == [opMessage(4)], "assertion 57: send() lands on the observer's stream")

    do {
        try await observer.send(opMessage(5))
        expect(false, "assertion 58: observer-token send must throw")
    } catch let error as SyncTransportError {
        expect(error == .sendFailed(reason: "scopeForbidsPublish"), "assertion 58: expected scopeForbidsPublish, got \(error)")
    }

    // stop(): both streams end.
    observer.stop()
    var trailingStates: [ContinuumRevivedSync.ConnectionState] = []
    for await state in observer.connectionState {
        trailingStates.append(state)
    }
    expect(trailingStates.last == ContinuumRevivedSync.ConnectionState.disconnected(reason: "stopped"), "assertion 59: stop ends the state stream with disconnected, got \(trailingStates)")
    var trailingMessages = 0
    for await _ in observer.inbound {
        trailingMessages += 1
    }
    expect(trailingMessages == 0, "assertion 60: inbound finishes empty after stop")
    publisher.stop()
    server.stop()
}

// 22. Bad token: the loop reports reconnecting, never connected.
do {
    let registry = RelayTokenRegistry(seed: [macToken: RelayGrant(scopes: .operator)])
    let hub = RelayHub { token in await registry.grant(for: token) }
    let server = RelayHTTPServer(hub: hub, registry: registry)
    try server.start()
    let transport = RelaySyncTransport(
        baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
        bearerToken: "bogus",
        deviceLabel: "checks-bad-token",
        backoffNanoseconds: [10_000_000]
    )
    transport.start()
    let states = await takeStates(1, from: transport.connectionState)
    expect(states == [ContinuumRevivedSync.ConnectionState.reconnecting], "assertion 61: bad token loops through reconnecting, got \(states)")
    transport.stop()
    server.stop()
}

// 23. cursorUnrecoverable self-heals: reset to 0, then whole again the
//     moment a bridging snapshot is published.
do {
    let registry = RelayTokenRegistry(seed: [
        macToken: RelayGrant(scopes: .operator),
        phoneToken: RelayGrant(scopes: .observer),
    ])
    let hub = RelayHub(ringCapacity: 2) { token in await registry.grant(for: token) }
    let server = RelayHTTPServer(hub: hub, registry: registry)
    try server.start()
    let base = URL(string: "http://127.0.0.1:\(server.port)")!
    for lamport: UInt64 in 1...4 {
        let body = try JSONEncoder().encode(opMessage(lamport))
        _ = try await request("POST", "\(base)/v1/publish", token: macToken, body: body)
    }

    let transport = RelaySyncTransport(
        baseURL: base,
        bearerToken: phoneToken,
        deviceLabel: "checks-heal",
        initialCursor: 1,
        pollWaitMs: 1_000,
        backoffNanoseconds: [50_000_000]
    )
    transport.start()
    let firstState = await takeStates(1, from: transport.connectionState)
    expect(firstState == [ContinuumRevivedSync.ConnectionState.reconnecting], "assertion 62: unrecoverable cursor reports reconnecting, got \(firstState)")

    // Publish the bridging snapshot; the retry loop must converge on it.
    let snapshotBody = try JSONEncoder().encode(snapshotMessage(through: 4))
    _ = try await request("POST", "\(base)/v1/publish", token: macToken, body: snapshotBody)
    let healed = await takeMessages(1, from: transport.inbound)
    if case .snapshot = healed[0] {} else {
        expect(false, "assertion 63: healed feed starts with the bridging snapshot, got \(healed)")
    }
    transport.stop()
    server.stop()
}

print("ContinuumRevivedRelayChecks passed: RelaySyncTransport against live loopback server (backlog+live consumption, cursor advance via onCursorChange, operator send() round-trip, observer send refusal, stop() stream hygiene, bad-token reconnect loop, cursorUnrecoverable self-heal via bridging snapshot)")

// ── Slice 2, milestone C plumbing: registerToken + startAtHead ──

// 24. The Mac leg registers a phone token through the transport; observer
//     grants may not register; startAtHead skips the backlog so the Mac's
//     inbound is live-only.
do {
    let registry = RelayTokenRegistry(seed: [macToken: RelayGrant(scopes: .operator)])
    let hub = RelayHub { token in await registry.grant(for: token) }
    let server = RelayHTTPServer(hub: hub, registry: registry)
    try server.start()
    let base = URL(string: "http://127.0.0.1:\(server.port)")!

    let mac = RelaySyncTransport(
        baseURL: base,
        bearerToken: macToken,
        deviceLabel: "checks-mac",
        startAtHead: true,
        pollWaitMs: 1_000,
        backoffNanoseconds: [10_000_000]
    )
    try await mac.send(opMessage(1))
    try await mac.send(opMessage(2))

    try await mac.registerToken("checks-phone-registered", scopes: .observer)
    let registeredPoll = try await request("GET", "\(base)/v1/poll?after=0&waitMs=0", token: "checks-phone-registered")
    expect(registeredPoll.status == 200, "assertion 64: transport-registered token polls → 200, got \(registeredPoll.status)")

    let observerTransport = RelaySyncTransport(baseURL: base, bearerToken: "checks-phone-registered", deviceLabel: "checks-registered-observer", backoffNanoseconds: [10_000_000])
    do {
        try await observerTransport.registerToken("escalation", scopes: .operator)
        expect(false, "assertion 65: observer registerToken must be refused")
    } catch let error as SyncTransportError {
        expect(error == .sendFailed(reason: "scopeForbidsPublish"), "assertion 65: expected scopeForbidsPublish, got \(error)")
    }
    observerTransport.stop()

    // startAtHead: connect AFTER two publishes; the connected signal implies
    // the hello fast-forward already ran, so the next publish is the first
    // (and only) inbound message.
    mac.start()
    let connected = await takeStates(1, from: mac.connectionState)
    expect(connected == [ContinuumRevivedSync.ConnectionState.connected], "assertion 66: mac transport connects, got \(connected)")
    try await mac.send(opMessage(3))
    let liveOnly = await takeMessages(1, from: mac.inbound)
    expect(liveOnly == [opMessage(3)], "assertion 67: startAtHead skips the backlog — first inbound is the post-start publish")
    mac.stop()
    server.stop()
}

print("ContinuumRevivedRelayChecks passed: milestone C plumbing (registerToken via transport incl. observer refusal, startAtHead live-only feed)")
