import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/55-synctransport-seam.md
//
// Executable checks for the `SyncTransport` protocol seam and the
// `FakeSyncTransport` adversarial fake. Every check is in-process with a
// seeded `FakeSyncTransport` and ticks advancing a fake clock — no file
// system (except the backend check's temp `ProjectStore` round-trip), no
// daemon, no real network, and (see below) NO WALL-CLOCK WAIT: assertions
// query `FakeSyncTransport.delivered(to:)` — actor state populated
// synchronously inside `deliver()` — instead of racing an externally-drained
// `AsyncStream` against a fixed sleep. `expect` and the `Fixtures/` helper
// come from `main.swift` / `OpLogBackendTests.swift` in this same target.

// MARK: - Test harness
//
// Checks below call `await transport.delivered(to:)` directly to read what
// was delivered. That query IS the synchronization point: by the time
// `tick()` returns, every message it delivered this tick is already
// appended to the actor's `deliveryLog`, so there is no scheduler-hop-vs-
// sleep race and no fixed-duration wait anywhere in this file. A prior
// revision drained a separately-collected `AsyncStream` via a background
// `Task` plus an 80ms `Task.sleep` "settle" after every tick batch — a real
// wall-clock dependency in a suite the ticket requires to be fake-clock
// deterministic; this replaces it.

private func opsOnly(_ messages: [SyncMessage]) -> [LoggedOp] {
    messages.compactMap { if case .op(let logged) = $0 { return logged } else { return nil } }
}

/// Minimal, real conformance to `SyncTransport` — proves the protocol is
/// actually satisfiable under Swift 6 strict concurrency with no
/// `@unchecked Sendable` workaround (Done-when #1), not merely declared and
/// never conformed to. Loops sent messages straight back to `inbound` so the
/// smoke check below has something to observe.
private actor NullSyncTransport: ContinuumRevivedSync.SyncTransport {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private let connectionContinuation: AsyncStream<ConnectionState>.Continuation

    init() {
        let (inboundStream, inboundContinuation) = AsyncStream<SyncMessage>.makeStream()
        let (stateStream, connectionContinuation) = AsyncStream<ConnectionState>.makeStream()
        self.inbound = inboundStream
        self.inboundContinuation = inboundContinuation
        self.connectionState = stateStream
        self.connectionContinuation = connectionContinuation
    }

    func send(_ message: SyncMessage) async throws {
        inboundContinuation.yield(message)
    }

    func announce(_ state: ConnectionState) {
        connectionContinuation.yield(state)
    }
}

private let repA = UUID(uuidString: "5A000000-0000-4000-8000-00000000000A")!
private let repB = UUID(uuidString: "5B000000-0000-4000-8000-00000000000B")!
private let repC = UUID(uuidString: "5C000000-0000-4000-8000-00000000000C")!

private func tileFrame(_ x: Double) -> TileFrame { TileFrame(x: x, y: 0, width: 200, height: 150) }

// A genuinely adversarial, hand-authored JSON blob carrying a forbidden
// token as an actual object KEY (not merely as a free-text value's
// contents) — the only way to exercise the key-anchored scan's positive
// case, since `Op`'s hand-written `Codable` conformance makes it impossible
// for any legitimately-constructed `SyncMessage` to encode a forbidden
// token as a key. This is the "test helper that forcibly injects ... into
// the encoded bytes" the ticket's "I5 on transit" check calls for.
private let adversarialKeyInjectionJSON =
    "{\"op\":{\"setTileTitle\":{\"id\":\"\(UUID().uuidString)\",\"title\":\"innocuous\"}},\"runtimeRef\":\"leaked-pid-1234\"}"

// MARK: - CRSC_TRAP_TEST subprocess hook (I5 structural trap)
//
// Swift `precondition`/`assert` traps are not catchable in-process. Proving
// the I5 scan is wired into `FakeSyncTransport`'s REAL enforcement path —
// `deliver()`, as invoked by `tick()` for every real message — means
// re-executing this binary in a subprocess and driving the adversarial,
// KEY-level-tainted bytes through THAT path (`testOnlyEnqueueTaintedRawEntry`
// + `tick()`, not a standalone call to the scanner), then asserting the
// subprocess crashes. If a regression ever removed the I5 call from
// `deliver()` itself, this would stop crashing and the check below would
// fail — the same `CRCC_TRAP_TEST` convention `ContinuumRevivedCoreChecks/
// main.swift` already uses for this exact class of problem.
func runSyncTransportTrapTestIfRequested() async {
    guard ProcessInfo.processInfo.environment["CRSC_TRAP_TEST"] == "FakeSyncTransport.i5TaintScan" else { return }
    let transport = FakeSyncTransport(seed: 1)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()
    await transport.testOnlyEnqueueTaintedRawEntry(adversarialKeyInjectionJSON, from: a, to: b)
    await transport.tick() // must preconditionFailure inside deliver(), the real tick()-driven codepath
    Foundation.exit(0) // unreachable if the scan traps, as expected
}

// MARK: - Logic checks

private func checkProtocolConformance() async throws {
    let transport = NullSyncTransport()
    let op = LoggedOp(opId: OpId(lamport: 1, replica: repA), op: .setTileTitle(id: UUID(), title: "protocol smoke"))
    try await transport.send(.op(op))
    await transport.announce(.connected)

    var inboundIterator = transport.inbound.makeAsyncIterator()
    let received = await inboundIterator.next()
    expect(received == .op(op), "protocol conformance: a minimal SyncTransport conformance round-trips send → inbound with no @unchecked Sendable")

    var stateIterator = transport.connectionState.makeAsyncIterator()
    let state = await stateIterator.next()
    expect(state == .connected, "protocol conformance: connectionState delivers the announced state")
    print("synctransport: protocol conformance — a real (non-fake) SyncTransport conformance compiles and round-trips under Swift 6 strict concurrency")
}

private func checkBasicDelivery() async {
    let transport = FakeSyncTransport(seed: 1)
    let (a, _) = await transport.makeReplica()
    let (b, streamB) = await transport.makeReplica()

    let ops = (0..<3).map { i in
        LoggedOp(opId: OpId(lamport: UInt64(i + 1), replica: repA), op: .setTileTitle(id: UUID(), title: "op\(i)"))
    }
    for op in ops { await transport.send(.op(op), from: a) }
    for _ in 0..<5 { await transport.tick() }

    let receivedB = await transport.delivered(to: b)
    let receivedA = await transport.delivered(to: a)
    expect(receivedB.count == 3, "basic delivery: B receives exactly 3 messages, got \(receivedB.count)")
    expect(opsOnly(receivedB) == ops, "basic delivery: B receives the exact same LoggedOp values, in the same order")
    expect(receivedA.isEmpty, "basic delivery: A (the sender) receives nothing back")

    // Cross-check against the real `AsyncStream` too (not just the actor's
    // delivery log): pull exactly `receivedB.count` items off `streamB`'s
    // own iterator. Each `.next()` call resolves immediately with no wait —
    // `tick()` already yielded synchronously into the stream's unbounded
    // buffer before it returned above — so this stays deterministic.
    var iteratorB = streamB.makeAsyncIterator()
    var fromStream: [SyncMessage] = []
    for _ in 0..<receivedB.count {
        if let next = await iteratorB.next() { fromStream.append(next) }
    }
    expect(fromStream == receivedB, "basic delivery: the real inbound AsyncStream carries the exact same messages as the delivery log")
    print("synctransport: basic delivery — 3/3 ops delivered A→B in order, 0 looped back to sender, AsyncStream matches the delivery log")
}

private func checkDropSemantics() async {
    let transport = FakeSyncTransport(seed: 2)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()

    await transport.setPolicy(DeliveryPolicy(dropRate: 1.0), from: a, to: b)
    let dropped = (0..<5).map { i in
        LoggedOp(opId: OpId(lamport: UInt64(i + 1), replica: repA), op: .setTileTitle(id: UUID(), title: "drop\(i)"))
    }
    for op in dropped { await transport.send(.op(op), from: a) }
    for _ in 0..<20 { await transport.tick() }
    let afterDrop = await transport.delivered(to: b)
    expect(afterDrop.isEmpty, "drop semantics: dropRate=1.0 delivers zero of 5 emitted ops")

    await transport.setPolicy(DeliveryPolicy(dropRate: 0.0), from: a, to: b)
    let survivor = LoggedOp(opId: OpId(lamport: 6, replica: repA), op: .setTileTitle(id: UUID(), title: "survivor"))
    await transport.send(.op(survivor), from: a)
    for _ in 0..<5 { await transport.tick() }
    let received = opsOnly(await transport.delivered(to: b))
    expect(received.count == 1, "drop semantics: dropRate=0.0 delivers exactly 1 op, got \(received.count)")
    expect(received == [survivor], "drop semantics: the surviving op matches exactly")
    print("synctransport: drop semantics — dropRate=1.0 drops 5/5, dropRate=0.0 delivers 1/1")
}

private func checkDuplicateSemantics() async {
    let transport = FakeSyncTransport(seed: 3)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()

    await transport.setPolicy(DeliveryPolicy(duplicates: 3), from: a, to: b)
    let tileId = UUID()
    let op = LoggedOp(
        opId: OpId(lamport: 1, replica: repA),
        op: .createTile(id: tileId, kind: .terminal, title: "dup", frame: tileFrame(0), zPosition: FracIndex(value: 0.5))
    )
    await transport.send(.op(op), from: a)
    for _ in 0..<5 { await transport.tick() }
    let received = opsOnly(await transport.delivered(to: b))
    expect(received.count == 3, "duplicate semantics: duplicates=3 delivers exactly 3 copies, got \(received.count)")
    expect(received.allSatisfy { $0 == op }, "duplicate semantics: all 3 copies are identical to the original (same OpId)")

    // Idempotency proof: materializing the log WITH duplicates present must
    // equal materializing it with the op present exactly once.
    let withDuplicates = try! materialize(ops: received).canonicalEncoded()
    let withoutDuplicates = try! materialize(ops: [op]).canonicalEncoded()
    expect(withDuplicates == withoutDuplicates, "duplicate semantics: materialize(3 duplicates) == materialize(1 copy) — idempotency holds end-to-end through the transport")
    print("synctransport: duplicate semantics — 3 copies delivered, materialize idempotent over duplicates")
}

private func checkDelaySemantics() async {
    let transport = FakeSyncTransport(seed: 4)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()

    await transport.setPolicy(DeliveryPolicy(delayTicks: 5), from: a, to: b)
    let op = LoggedOp(opId: OpId(lamport: 1, replica: repA), op: .setTileTitle(id: UUID(), title: "delayed"))
    await transport.send(.op(op), from: a)
    for _ in 0..<4 { await transport.tick() }
    let beforeDelay = await transport.delivered(to: b)
    expect(beforeDelay.isEmpty, "delay semantics: 4 ticks with delayTicks=5 delivers nothing")

    await transport.tick()
    let received = opsOnly(await transport.delivered(to: b))
    expect(received == [op], "delay semantics: the 5th tick delivers exactly the delayed op")
    print("synctransport: delay semantics — delayTicks=5 holds for 4 ticks, delivers on the 5th")
}

private func checkReorderSemantics() async {
    let transport = FakeSyncTransport(seed: 5)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()

    await transport.setPolicy(DeliveryPolicy(reorder: true), from: a, to: b)
    let tileId = UUID()
    let create = LoggedOp(
        opId: OpId(lamport: 1, replica: repA),
        op: .createTile(id: tileId, kind: .terminal, title: "reorder-target", frame: tileFrame(0), zPosition: FracIndex(value: 0.5))
    )
    // 5 competing frame-writes at ascending Lamport — the LWW winner MUST be
    // lamport 6's frame no matter what order the transport delivers them in.
    let writes = (2...6).map { lamport in
        LoggedOp(opId: OpId(lamport: UInt64(lamport), replica: repA), op: .setTileFrame(id: tileId, frame: tileFrame(Double(lamport) * 100)))
    }
    let ops = [create] + writes
    for op in ops { await transport.send(.op(op), from: a) }
    await transport.tick() // delayTicks=0 → all 6 become "ready" on the same tick, then get shuffled

    let received = opsOnly(await transport.delivered(to: b))
    expect(received.count == 6, "reorder semantics: B receives all 6 ops, got \(received.count)")
    expect(Set(received.map(\.opId)) == Set(ops.map(\.opId)), "reorder semantics: B receives the same set of OpIds as were sent")
    let arrivedInOriginalOrder = received.map(\.opId) == ops.map(\.opId)
    // The load-bearing gate for `reorder: true`: with this fixed seed, the
    // delivered order must actually differ from send order. Without this,
    // a `FakeSyncTransport` that silently ignored `DeliveryPolicy.reorder`
    // entirely (never shuffled `ready`) would still pass every other
    // assertion in this check — the OpId-set check and the materialize
    // equivalence checks below hold regardless of delivery order by
    // construction (materialize sorts by Lamport before folding), so they
    // cannot distinguish "reordered" from "not reordered". This assertion
    // is what actually proves the fake reorders, not just that materialize
    // tolerates reordering.
    expect(!arrivedInOriginalOrder, "reorder semantics: seed 5 with reorder=true must deliver the 6 ops in a shuffled (non-original) order — a fake that ignored DeliveryPolicy.reorder would deliver original order and this would catch it")

    let fromArrival = try! materialize(ops: received).canonicalEncoded()
    let fromOriginal = try! materialize(ops: ops).canonicalEncoded()
    expect(fromArrival == fromOriginal, "reorder semantics: materialize(arrival order) == materialize(Lamport order) — materialize's sort absorbs transport reorder")
    expect(
        materialize(ops: received).canvasState.tiles.first(where: { $0.id == tileId })?.frame == tileFrame(600),
        "reorder semantics: LWW winner is lamport 6's frame regardless of delivery order"
    )
    print("synctransport: reorder semantics — seed 5 delivered a shuffled (non-original) order as asserted above; LWW winner and byte-identical materialize hold regardless")
}

private func checkPartitionAndHeal() async {
    let transport = FakeSyncTransport(seed: 6)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()

    // Asymmetric partition: only A→B is blocked; B→A stays open.
    await transport.setPolicy(DeliveryPolicy(partitioned: true), from: a, to: b)
    let fromA = (1...3).map { i in LoggedOp(opId: OpId(lamport: UInt64(i), replica: repA), op: .setTileTitle(id: UUID(), title: "a\(i)")) }
    let fromB = (1...2).map { i in LoggedOp(opId: OpId(lamport: UInt64(i), replica: repB), op: .setTileTitle(id: UUID(), title: "b\(i)")) }
    for op in fromA { await transport.send(.op(op), from: a) }
    for op in fromB { await transport.send(.op(op), from: b) }
    for _ in 0..<10 { await transport.tick() }

    var receivedA = opsOnly(await transport.delivered(to: a))
    var receivedB = opsOnly(await transport.delivered(to: b))
    expect(receivedA == fromB, "partition and heal: A (not partitioned inbound) receives B's 2 ops")
    expect(receivedB.isEmpty, "partition and heal: B receives nothing from A while partitioned")

    await transport.setPolicy(DeliveryPolicy(), from: a, to: b) // heal
    for _ in 0..<10 { await transport.tick() }
    receivedA = opsOnly(await transport.delivered(to: a))
    receivedB = opsOnly(await transport.delivered(to: b))
    expect(receivedB == fromA, "partition and heal: after healing, B receives A's 3 ops")

    // Each replica's FULL effective log is its own emitted ops (it always
    // knows those locally) plus whatever it received via the transport.
    let effectiveA = fromA + receivedA
    let effectiveB = fromB + receivedB
    expect(Set(effectiveA.map(\.opId)) == Set((fromA + fromB).map(\.opId)), "partition and heal: A's effective log is the full 5-op union")
    let materializedA = try! materialize(ops: effectiveA).canonicalEncoded()
    let materializedB = try! materialize(ops: effectiveB).canonicalEncoded()
    expect(materializedA == materializedB, "partition and heal: materializing each replica's full log (union of all 5 ops) produces byte-identical state")
    print("synctransport: partition and heal — asymmetric partition honored, heals cleanly, replicas converge byte-identical")
}

/// The dominant real-world failure mode: a device edits offline, then
/// reconnects and floods its backlog. Returns the number of `tick()` calls
/// needed AFTER `reconnect()` for every replica to have all 6 ops, for the
/// dogfood manifest.
private func checkOfflineReconnectFlood() async -> Int {
    let transport = FakeSyncTransport(seed: 7)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()
    let (c, _) = await transport.makeReplica()

    await transport.goOffline(c)
    let fromA = (1...2).map { i in LoggedOp(opId: OpId(lamport: UInt64(i), replica: repA), op: .setTileTitle(id: UUID(), title: "a\(i)")) }
    let fromB = (1...2).map { i in LoggedOp(opId: OpId(lamport: UInt64(i), replica: repB), op: .setTileTitle(id: UUID(), title: "b\(i)")) }
    let fromC = (1...2).map { i in LoggedOp(opId: OpId(lamport: UInt64(i), replica: repC), op: .setTileTitle(id: UUID(), title: "c\(i)")) }
    for op in fromA { await transport.send(.op(op), from: a) }
    for op in fromB { await transport.send(.op(op), from: b) }
    for op in fromC { await transport.send(.op(op), from: c) } // C is offline → held, not queued to A/B
    for _ in 0..<10 { await transport.tick() }

    let preReconnectA = opsOnly(await transport.delivered(to: a))
    let preReconnectB = opsOnly(await transport.delivered(to: b))
    let preReconnectC = await transport.delivered(to: c)
    expect(preReconnectA == fromB, "offline/reconnect: A has exactly B's 2 ops while C is offline")
    expect(preReconnectB == fromA, "offline/reconnect: B has exactly A's 2 ops while C is offline")
    expect(preReconnectC.isEmpty, "offline/reconnect: C (offline) has received nothing")
    let holdDepth = await transport.holdQueueDepth(c)
    expect(holdDepth == 2, "offline/reconnect: C's hold queue buffered exactly its own 2 emitted ops, got \(holdDepth)")

    await transport.reconnect(c)
    var ticksToDrain = 0
    while ticksToDrain < 20 {
        await transport.tick()
        ticksToDrain += 1
        let aCount = (await transport.delivered(to: a)).count
        let bCount = (await transport.delivered(to: b)).count
        let cCount = (await transport.delivered(to: c)).count
        if aCount == 4 && bCount == 4 && cCount == 4 { break }
    }
    expect(ticksToDrain < 20, "offline/reconnect: flood drains within the 20-tick budget, took \(ticksToDrain)")

    let effectiveA = fromA + opsOnly(await transport.delivered(to: a))
    let effectiveB = fromB + opsOnly(await transport.delivered(to: b))
    let effectiveC = fromC + opsOnly(await transport.delivered(to: c))
    let allSix = Set((fromA + fromB + fromC).map(\.opId))
    expect(Set(effectiveA.map(\.opId)) == allSix, "offline/reconnect: A ends up with all 6 ops")
    expect(Set(effectiveB.map(\.opId)) == allSix, "offline/reconnect: B ends up with all 6 ops")
    expect(Set(effectiveC.map(\.opId)) == allSix, "offline/reconnect: C ends up with all 6 ops")
    let mA = try! materialize(ops: effectiveA).canonicalEncoded()
    let mB = try! materialize(ops: effectiveB).canonicalEncoded()
    let mC = try! materialize(ops: effectiveC).canonicalEncoded()
    expect(mA == mB && mB == mC, "offline/reconnect: all three replicas materialize byte-identical state after the flood")
    print("synctransport: offline/reconnect flood — the dominant real case: 3 replicas converge on all 6 ops in \(ticksToDrain) tick(s) after reconnect")
    return ticksToDrain
}

private func checkI5OnTransit() async {
    // False-positive regression: a LEGITIMATE user-entered title that is
    // exactly equal to one of the forbidden tokens (e.g. a tile a user
    // named literally "pid" or "runtimeRef") must NOT trip the scan — it is
    // a free-text VALUE, not a JSON key. A prior revision used a bare
    // quoted-token pattern (`"pid"` with no colon) that matched this
    // exact scenario as a false positive; that was caught in review.
    for token in ["pid", "runtimeRef", "paneTarget", "scrollback", "tmuxTarget"] {
        let legitimateTitle = LoggedOp(opId: OpId(lamport: 1, replica: repA), op: .setTileTitle(id: UUID(), title: token))
        expect(SyncPayloadTaint.violations(in: .op(legitimateTitle)).isEmpty, "I5 on transit: a tile titled exactly \"\(token)\" produces zero violations (value, not a key — no false positive)")
    }
    let clean = LoggedOp(opId: OpId(lamport: 2, replica: repA), op: .setTileTitle(id: UUID(), title: "a perfectly normal title"))
    expect(SyncPayloadTaint.violations(in: .op(clean)).isEmpty, "I5 on transit: a normal title produces zero violations")

    // Genuine adversarial detection: `Op`'s hand-written Codable makes it
    // structurally IMPOSSIBLE for any real, type-safe SyncMessage to encode
    // a forbidden token as a JSON KEY (that's I5's actual guarantee — see
    // SpatialOp.swift), so the only way to exercise the scan's true
    // positive case is a hand-authored adversarial byte blob that bypasses
    // Op/LoggedOp/SyncMessage entirely, carrying the token as an actual key
    // — the "test helper that forcibly injects ... into the encoded bytes"
    // the ticket's "I5 on transit" check calls for.
    let violations = SyncPayloadTaint.violations(inEncodedJSON: adversarialKeyInjectionJSON)
    expect(violations.contains("\"runtimeRef\":"), "I5 on transit: the pure scan detects a forbidden token injected as an actual JSON key")

    // Prove the scan is STRUCTURAL — wired into `deliver()`, the exact
    // function `tick()` calls for every real message, not merely a
    // standalone helper nobody calls. The subprocess enqueues the tainted
    // bytes via `testOnlyEnqueueTaintedRawEntry` and calls `tick()` — the
    // SAME entry point real traffic uses — so a regression that removed the
    // I5 call from `deliver()` would make the subprocess exit 0 instead of
    // crashing, and this assertion would catch it. Swift `precondition`
    // traps are not catchable in-process, so drive the scenario in a
    // subprocess and assert it crashes (CRSC_TRAP_TEST, same convention as
    // ContinuumRevivedCoreChecks' CRCC_TRAP_TEST).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.environment = ProcessInfo.processInfo.environment.merging(["CRSC_TRAP_TEST": "FakeSyncTransport.i5TaintScan"]) { _, new in new }
    try? process.run()
    process.waitUntilExit()
    expect(process.terminationStatus != 0, "I5 on transit: FakeSyncTransport's real tick()-driven deliver() path traps on key-level-tainted bytes instead of proceeding")
    print("synctransport: I5 on transit — legitimate free-text values titled exactly \"pid\"/\"runtimeRef\"/etc. produce zero false positives; genuine key-level injection is detected; the real tick()/deliver() path traps structurally")
}

private func checkBootstrapSnapshot() async {
    let bootstrapTileId = UUID()
    let opsAll: [LoggedOp] = (1...10).map { i in
        if i == 1 {
            return LoggedOp(
                opId: OpId(lamport: 1, replica: repA),
                op: .createTile(id: bootstrapTileId, kind: .terminal, title: "bootstrap", frame: tileFrame(0), zPosition: FracIndex(value: 0.5))
            )
        }
        return LoggedOp(opId: OpId(lamport: UInt64(i), replica: repA), op: .setTileFrame(id: bootstrapTileId, frame: tileFrame(Double(i) * 10)))
    }
    let compaction = compact(log: opsAll, through: 5)
    expect(compaction.tail.count == 5, "bootstrap: tail has the 5 ops above lowWaterMark=5, got \(compaction.tail.count)")

    let transport = FakeSyncTransport(seed: 9)
    let (a, _) = await transport.makeReplica()
    let (fresh, _) = await transport.makeReplica()

    await transport.send(.snapshot(compaction.snapshot), from: a)
    for op in compaction.tail { await transport.send(.op(op), from: a) }
    for _ in 0..<5 { await transport.tick() }

    let received = await transport.delivered(to: fresh)
    expect(received.count == 1 + compaction.tail.count, "bootstrap: fresh replica receives the snapshot plus all 5 tail ops, got \(received.count)")
    guard case .snapshot(let receivedSnapshot)? = received.first else {
        expect(false, "bootstrap: the first delivered message must be the snapshot")
        return
    }
    expect(receivedSnapshot == compaction.snapshot, "bootstrap: the received snapshot is byte-identical to the one sent")

    let receivedTail = opsOnly(Array(received.dropFirst()))
    let materializedFresh = materialize(
        onto: receivedSnapshot.state,
        baseOpId: receivedSnapshot.compactionOpId,
        ledger: receivedSnapshot.ledger,
        tail: receivedTail
    )
    let fromFresh = try! materializedFresh.canonicalEncoded()
    let fromFull = try! materialize(ops: opsAll).canonicalEncoded()
    expect(fromFresh == fromFull, "bootstrap: fresh replica (snapshot + tail via the transport) materializes identically to the full 10-op log")
    print("synctransport: bootstrap snapshot — snapshot + 5 tail ops via the fake reproduce the full 10-op materialize exactly")
}

// MARK: - Measured-value scenarios (dogfood manifest)

/// Ops-per-tick throughput at the N=5 replica scale the fuzz uses: one
/// replica broadcasts 20 ops to its 4 peers; with default policy (no delay)
/// every send is deliverable on the very next tick.
private func measureThroughput() async -> Int {
    let transport = FakeSyncTransport(seed: 99)
    var replicaIds: [ContinuumRevivedSync.FakeSyncTransport.ReplicaId] = []
    for _ in 0..<5 {
        let (id, _) = await transport.makeReplica()
        replicaIds.append(id)
    }
    let senderId = replicaIds[0]
    let opsPerSender = 20
    for i in 0..<opsPerSender {
        let op = LoggedOp(opId: OpId(lamport: UInt64(i + 1), replica: repA), op: .setTileTitle(id: UUID(), title: "throughput-\(i)"))
        await transport.send(.op(op), from: senderId)
    }
    await transport.tick()
    var totalDelivered = 0
    for id in replicaIds { totalDelivered += (await transport.delivered(to: id)).count }
    expect(totalDelivered == opsPerSender * 4, "throughput: 1 sender × 20 ops fanned out to 4 peers in a single tick delivers 80 total, got \(totalDelivered)")
    print("synctransport: throughput — \(totalDelivered) ops delivered in 1 tick at N=5 replicas (\(opsPerSender) sent × 4 peers)")
    return totalDelivered
}

/// Encoded-byte footprint of an offline replica's hold queue after 1,000 ops.
private func measureHoldQueueFootprint() async -> (depth: Int, bytes: Int) {
    let transport = FakeSyncTransport(seed: 100)
    let (a, _) = await transport.makeReplica()
    _ = await transport.makeReplica()
    await transport.goOffline(a)
    for i in 0..<1000 {
        let op = LoggedOp(opId: OpId(lamport: UInt64(i + 1), replica: repA), op: .setTileTitle(id: UUID(), title: "held-\(i)"))
        await transport.send(.op(op), from: a)
    }
    let depth = await transport.holdQueueDepth(a)
    let bytes = await transport.holdQueueByteFootprint(a)
    expect(depth == 1000, "hold queue: buffers exactly 1000 ops emitted while offline, got \(depth)")
    print("synctransport: hold queue at 1000 ops — depth=\(depth), \(bytes) bytes")
    return (depth, bytes)
}

/// Reproducibility with >1 receiver: the same seed must assign the same
/// sequence of `rng` draws to the same (sender, receiver) pairs across
/// independent `FakeSyncTransport` instances, so a failing fuzz seed can
/// actually be replayed. This is exactly the scenario review flagged as
/// UNPROVEN by the single-receiver drop/reorder checks above: `send`/`tick`
/// used to walk `Dictionary.keys` (iteration order seeded per-process and
/// dependent on the receivers' random `UUID`s' bucket placement), so which
/// RNG draw landed on which receiver varied run to run even for a fixed
/// seed. `replicaOrder` (registration order, not a dictionary) fixes that;
/// this check fails without the fix and passes with it.
private func checkSeedReproducibility() async {
    // Fixed content up front — held constant across both runs below — so
    // any divergence in the result can only come from delivery/drop/reorder
    // decisions, never from incidentally-different op payloads.
    let ops = (0..<30).map { i -> LoggedOp in
        let tileId = UUID(uuidString: String(format: "5D000000-0000-4000-8000-%012d", i))!
        return LoggedOp(opId: OpId(lamport: UInt64(i + 1), replica: repA), op: .setTileTitle(id: tileId, title: "seed-\(i)"))
    }

    func run(seed: UInt64) async -> [[LoggedOp]] {
        let transport = FakeSyncTransport(seed: seed)
        let (a, _) = await transport.makeReplica()
        var receivers: [ContinuumRevivedSync.FakeSyncTransport.ReplicaId] = []
        for i in 0..<4 {
            let (id, _) = await transport.makeReplica()
            receivers.append(id)
            // Distinct policies per receiver so the RNG is actually
            // exercised (drop and/or reorder), and asymmetrically enough
            // that a receiver-order mixup would show up as a different
            // per-receiver op count or op set.
            await transport.setPolicy(
                DeliveryPolicy(reorder: i % 2 == 0, dropRate: i == 0 ? 0.0 : Double(i) * 0.2),
                from: a, to: id
            )
        }
        for op in ops { await transport.send(.op(op), from: a) }
        for _ in 0..<10 { await transport.tick() }
        var perReceiver: [[LoggedOp]] = []
        for id in receivers { perReceiver.append(opsOnly(await transport.delivered(to: id))) }
        return perReceiver
    }

    let seed: UInt64 = 4242
    let run1 = await run(seed: seed)
    let run2 = await run(seed: seed)
    expect(run1.count == 4 && run2.count == 4, "seed reproducibility: both runs have 4 receivers")
    for i in 0..<4 {
        expect(run1[i] == run2[i], "seed reproducibility: receiver \(i) gets identical delivered ops (same drop/reorder decisions) across two independent FakeSyncTransport instances given the same seed, got \(run1[i].count) vs \(run2[i].count)")
    }
    print("synctransport: seed reproducibility — same seed reproduces identical per-receiver delivery/drop/reorder decisions across independent FakeSyncTransport instances with 4 receivers (guards the dictionary-iteration-order hazard)")
}

// MARK: - Entry point

func runSyncTransportChecks() async throws {
    try await checkProtocolConformance()
    await checkBasicDelivery()
    await checkDropSemantics()
    await checkDuplicateSemantics()
    await checkDelaySemantics()
    await checkReorderSemantics()
    await checkPartitionAndHeal()
    let ticksToDrain = await checkOfflineReconnectFlood()
    await checkI5OnTransit()
    await checkBootstrapSnapshot()
    await checkSeedReproducibility()
    let throughput = await measureThroughput()
    let holdQueue = await measureHoldQueueFootprint()

    let manifest = InvariantManifest(
        invariantId: "ticket55-synctransport-seam",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date()),
        measurements: [
            "fake_transport_throughput_ops_per_tick_n5": .int(throughput),
            "hold_queue_depth_at_1000_ops": .int(holdQueue.depth),
            "hold_queue_bytes_at_1000_ops": .int(holdQueue.bytes),
            "offline_reconnect_ticks_to_drain": .int(ticksToDrain),
        ],
        outcome: InvariantOutcome.pass.rawValue,
        failureReason: nil
    )
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-\(manifest.invariantId)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try InvariantManifestWriter.write(manifest, to: tmpDir)
    let file = tmpDir.appendingPathComponent("invariant-\(manifest.invariantId)-\(manifest.runId).json")
    let readBack = try JSONDecoder().decode(InvariantManifest.self, from: Data(contentsOf: file))
    expect(readBack == manifest, "ticket55-synctransport-seam: manifest round-trips through the real filesystem")

    print("ContinuumRevivedSyncChecks passed: SyncTransport seam — 10 logic checks (basic delivery, drop, duplicate+idempotency, delay, reorder, partition+heal, offline/reconnect flood, I5 on transit, bootstrap snapshot, seed reproducibility across independent transports) green, seeded RNG reproducible with a deterministic multi-receiver ordering, manifest at \(file.path)")
}
