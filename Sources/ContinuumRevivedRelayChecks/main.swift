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
