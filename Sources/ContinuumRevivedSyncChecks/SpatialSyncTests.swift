import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/61b-canvas-editor.md
// Real-path checks for the first spatial-op wire path: REAL `SpatialOpSender` +
// `SpatialOpReceiver` over a wrapped `FakeSyncTransport` (the 61a adapter
// precedent — `FakeReplicaSyncTransport`, made non-private in
// ActivityProjectionTests.swift for this file to reuse).

private func spatialLogged(_ lamport: UInt64, _ replica: UUID, _ op: Op) -> LoggedOp {
    LoggedOp(opId: OpId(lamport: lamport, replica: replica), op: op)
}

private func tickUntil(
    fake: ContinuumRevivedSync.FakeSyncTransport,
    timeoutSeconds: Double,
    condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        await fake.tick()
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

private actor SpatialBlackHoleTransport: ContinuumRevivedSync.SyncTransport {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private(set) var sentMessages: [SyncMessage] = []

    init() {
        (inbound, inboundContinuation) = AsyncStream<SyncMessage>.makeStream()
        let (states, stateContinuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
        stateContinuation.yield(.connected)
        connectionState = states
    }

    func send(_ message: SyncMessage) async throws {
        sentMessages.append(message)
    }

    func push(_ message: SyncMessage) {
        inboundContinuation.yield(message)
    }
}

private actor SpatialMaterializedProbe {
    private var count = 0

    func record(_ state: MaterializedState) {
        _ = state
        count += 1
    }

    func recordedCount() -> Int { count }
}

private func checkFreshSpatialSubscribeWaitsForRemoteDesktopState() async {
    let transport = SpatialBlackHoleTransport()
    let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: transport))
    await receiver.connect()
    let stream = await receiver.subscribe()
    let probe = SpatialMaterializedProbe()
    let task = Task {
        for await state in stream {
            await probe.record(state)
        }
    }

    try? await Task.sleep(for: .milliseconds(50))
    let countBeforeRemote = await probe.recordedCount()
    let spatialSeenBeforeRemote = await receiver.hasReceivedRemoteSpatial()
    expect(countBeforeRemote == 0, "ticket85 spatial receiver: subscribe does not emit local empty bootstrap canvas")
    expect(spatialSeenBeforeRemote == false, "ticket85 spatial receiver: remote flag is false before desktop spatial data")

    let snapshot = compact(log: [], through: 0).snapshot
    await transport.push(.snapshot(snapshot))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if await probe.recordedCount() > 0 { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let countAfterRemote = await probe.recordedCount()
    let spatialSeenAfterRemote = await receiver.hasReceivedRemoteSpatial()
    expect(countAfterRemote == 1, "ticket85 spatial receiver: real remote empty canvas snapshot is emitted")
    expect(spatialSeenAfterRemote == true, "ticket85 spatial receiver: remote flag flips after remote spatial data")

    task.cancel()
    await receiver.stop()
}

/// Connect, receive snapshot + tail; phone emits move + membership-change +
/// bring-to-front at operator scope; ops land in the store; both sides'
/// `MaterializedState.canonicalEncoded()` byte-identical. Also proves lamport
/// allocation and order-independence using ops the PRODUCTION emit path
/// actually produced.
private func checkSpatialOpSyncRealPathAtOperatorScope() async throws {
    let desktopReplica = UUID(uuidString: "61B10000-0000-4000-8000-0000000000D1")!
    let phoneReplica = UUID(uuidString: "61B10000-0000-4000-8000-0000000000D2")!
    let tileP = UUID(uuidString: "61B10000-0000-4000-8000-00000000000A")!
    let tileOther = UUID(uuidString: "61B10000-0000-4000-8000-00000000000B")!
    let zoneQ = UUID(uuidString: "61B10000-0000-4000-8000-0000000000A1")!

    let desktopOps: [LoggedOp] = [
        spatialLogged(1, desktopReplica, .createTile(id: tileP, kind: .terminal, title: "shell", frame: TileFrame(x: 0, y: 0, width: 400, height: 300), zPosition: FracIndex(value: 0.2))),
        spatialLogged(2, desktopReplica, .createTile(id: tileOther, kind: .browser, title: "web", frame: TileFrame(x: 500, y: 0, width: 400, height: 300), zPosition: FracIndex(value: 0.5))),
        spatialLogged(3, desktopReplica, .createZone(id: zoneQ, projectId: nil, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 900, height: 700), name: "Q", color: "mint")),
    ]
    let store = MemorySpatialOpLogStore(seeding: desktopOps)

    let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 61022)
    let (hostReplica, hostInbound) = await fake.makeReplica()
    let (observerReplica, observerInbound) = await fake.makeReplica()
    let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
    let observerTransport = FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound)

    let sender = SpatialOpSender(store: store, demux: SyncMessageDemux(transport: hostTransport), authorizedScope: .operator)
    await sender.start()
    let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: observerTransport), phoneReplicaId: phoneReplica)
    await receiver.connect()

    let expectedInitial = materialize(ops: desktopOps)
    let snapshotArrived = await tickUntil(fake: fake, timeoutSeconds: 2) {
        await (try? receiver.currentState().canonicalEncoded()) == (try? expectedInitial.canonicalEncoded())
    }
    expect(snapshotArrived, "spatial sync real path: cold .spatialSubscribe receives the full initial snapshot")

    // Phone edits at operator scope: move, membership-change, bring-to-front —
    // exactly one op per gesture end, via the production `CanvasEditIntent`
    // helpers and the production `emit` path.
    let newFrame = TileFrame(x: 42, y: 84, width: 360, height: 240)
    try await receiver.emit(CanvasEditIntent.moveEnded(tile: tileP, to: newFrame))
    _ = await tickUntil(fake: fake, timeoutSeconds: 2) { await store.allOps().count == desktopOps.count + 1 }

    try await receiver.emit(CanvasEditIntent.setZone(tile: tileP, zoneId: zoneQ))
    _ = await tickUntil(fake: fake, timeoutSeconds: 2) { await store.allOps().count == desktopOps.count + 2 }

    let sceneBeforeBringToFront = CanvasSceneProjection.scene(
        canvasState: await receiver.currentState().canvasState,
        workspaceDocument: await receiver.currentState().workspaceDocument
    )
    guard let bringToFrontOp = CanvasEditIntent.bringToFront(tile: tileP, scene: sceneBeforeBringToFront) else {
        expect(false, "spatial sync real path: bring-to-front must produce an op (tileP is not already frontmost)")
        return
    }
    try await receiver.emit(bringToFrontOp)

    let allLanded = await tickUntil(fake: fake, timeoutSeconds: 2) { await store.allOps().count == desktopOps.count + 3 }
    expect(allLanded, "spatial sync real path: all three phone ops land in the desktop-role store")

    let converged = await tickUntil(fake: fake, timeoutSeconds: 2) {
        let storeOps = await store.allOps()
        let storeEncoded = try? materialize(ops: storeOps).canonicalEncoded()
        let receiverEncoded = try? (await receiver.currentState()).canonicalEncoded()
        return storeEncoded != nil && storeEncoded == receiverEncoded
    }
    expect(converged, "spatial sync real path: store and receiver MaterializedState.canonicalEncoded() are byte-identical")

    let finalStoreOps = await store.allOps()
    let finalState = materialize(ops: finalStoreOps)
    let finalTile = finalState.canvasState.tiles.first { $0.id == tileP }
    expect(finalTile?.frame == newFrame, "spatial sync real path: tileP's final frame is the emitted move frame")
    expect(finalTile?.zoneId == zoneQ, "spatial sync real path: tileP's final zoneId is the emitted membership change")
    let otherZ = finalState.canvasState.tiles.first { $0.id == tileOther }?.zPosition
    expect(otherZ != nil && finalTile.map { $0.zPosition > otherZ! } == true, "spatial sync real path: bring-to-front sorts tileP's z after tileOther's prior frontmost")

    // Lamport allocation: after a snapshot whose max lamport is 3, every
    // phone-emitted OpId sorts after every observed op — i.e. lamports 4, 5, 6.
    let phoneOps = finalStoreOps.filter { $0.opId.replica == phoneReplica }.sorted { $0.opId < $1.opId }
    let phoneLamports = phoneOps.map(\.opId.lamport)
    expect(phoneLamports == [4, 5, 6], "spatial sync real path: phone lamports allocate strictly after the snapshot's max lamport (3), got \(phoneLamports)")

    // Order-independence spot check using ops the PRODUCTION emit path
    // actually produced (not hand-authored fixtures).
    let forward = try materialize(ops: desktopOps + phoneOps).canonicalEncoded()
    let backward = try materialize(ops: phoneOps + desktopOps).canonicalEncoded()
    expect(forward == backward, "spatial sync real path: materialize(desktop+phone) == materialize(phone+desktop)")

    print("spatial sync real path: snapshotMaxLamport=3 phoneLamports=\(phoneLamports) finalFrame=\(String(describing: finalTile?.frame)) finalZone=\(String(describing: finalTile?.zoneId)) finalZ=\(String(describing: finalTile?.zPosition.value)) storeOpsCount=\(finalStoreOps.count) orderIndependentBytes=\(forward.count)")

    await sender.stop()
    await receiver.stop()
}

/// Observer-scope emission: op sent by the phone is NOT appended to the
/// desktop-role store — the sender's `capability(for:)` authorization gate
/// drops it (there is no error channel in `SyncMessage` v1; defense in depth
/// is the phone UI independently disabling editing below operator scope).
private func checkObserverScopeEmissionIsDroppedAtTheSender() async throws {
    let store = MemorySpatialOpLogStore()
    let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 61023)
    let (hostReplica, hostInbound) = await fake.makeReplica()
    let (observerReplica, observerInbound) = await fake.makeReplica()
    let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
    let observerTransport = FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound)

    let sender = SpatialOpSender(store: store, demux: SyncMessageDemux(transport: hostTransport), authorizedScope: .observer)
    await sender.start()
    let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: observerTransport))
    await receiver.connect()
    for _ in 0..<10 { await fake.tick() } // let the cold snapshot settle

    let tileId = UUID()
    try await receiver.emit(.setTileTitle(id: tileId, title: "should be dropped"))
    for _ in 0..<10 { await fake.tick() } // drain fully; the drop must be permanent, not a race

    let opsAfter = await store.allOps()
    expect(opsAfter.isEmpty, "observer scope: unauthorized op is never appended to the store, got \(opsAfter.count) ops")

    await sender.stop()
    await receiver.stop()
}

/// A transport whose `inbound` yields one seeded `.snapshot` (a real tile the
/// test can observe a title-change on) and then always throws on `send` — the
/// injected failure path for proving `SpatialOpReceiver.emit` reverts its
/// optimistic local apply. Unlike a transport with no real state at all, this
/// lets the check assert on a FIELD the emitted op actually mutates, so the
/// assertion is falsified (not tautologically true) if the revert code were
/// removed.
private final class SendFailsAfterSeededSnapshotTransport: ContinuumRevivedSync.SyncTransport, @unchecked Sendable {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>

    init(seededSnapshot: CompactedSnapshot) {
        let (inboundStream, continuation) = AsyncStream<SyncMessage>.makeStream()
        continuation.yield(.snapshot(seededSnapshot))
        inbound = inboundStream
        let (states, stateContinuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
        stateContinuation.yield(.connected)
        connectionState = states
    }

    func send(_ message: SyncMessage) async throws {
        throw SyncTransportError.sendFailed(reason: "test-injected failure")
    }
}

/// The phone-side optimistic apply reverts when the SEND itself fails (a
/// transport-level failure — distinct from a server-side scope rejection,
/// which has no ack channel to revert against). Seeds a REAL tile via a
/// snapshot first so the emitted `.setTileTitle` actually mutates observable
/// state; without a genuine mutation to roll back, "before == after" would
/// hold trivially even if the rollback code were deleted (`materialize`
/// silently ignores field-sets for unknown tile ids).
private func checkReceiverRevertsOptimisticApplyOnSendFailure() async throws {
    let tileId = UUID()
    let seedOpId = OpId(lamport: 1, replica: UUID())
    let createOp = LoggedOp(
        opId: seedOpId,
        op: .createTile(
            id: tileId,
            kind: .terminal,
            title: "original",
            frame: TileFrame(x: 0, y: 0, width: 100, height: 100),
            zPosition: FracIndex(value: 0.1)
        )
    )
    let seededSnapshot = compact(log: [createOp], through: seedOpId.lamport).snapshot

    let transport = SendFailsAfterSeededSnapshotTransport(seededSnapshot: seededSnapshot)
    let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: transport))
    await receiver.connect()

    var seeded = false
    for _ in 0..<50 {
        if await receiver.currentState().canvasState.tiles.first(where: { $0.id == tileId })?.title == "original" {
            seeded = true
            break
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    expect(seeded, "revert on failure: test setup — the seeded snapshot's tile lands before the failing emit")

    let before = try await receiver.currentState().canonicalEncoded()

    var threw = false
    do {
        try await receiver.emit(.setTileTitle(id: tileId, title: "renamed-by-a-write-that-will-fail"))
    } catch {
        threw = true
    }
    expect(threw, "revert on failure: emit() surfaces the send failure to the caller")

    let afterState = await receiver.currentState()
    let afterTitle = afterState.canvasState.tiles.first { $0.id == tileId }?.title
    expect(afterTitle == "original", "revert on failure: optimistic title change is rolled back after the send fails, got \(String(describing: afterTitle))")

    let after = try afterState.canonicalEncoded()
    expect(before == after, "revert on failure: optimistic local apply is reverted, state is byte-identical to before emit")

    await receiver.stop()
}

/// A transport whose `send` always succeeds (a no-op) but whose `inbound`
/// stream the test can push additional messages onto after `connect()` — lets
/// a check simulate a second, concurrent/stale `.snapshot` arriving after a
/// local optimistic emit.
private final class ScriptablePushTransport: ContinuumRevivedSync.SyncTransport, @unchecked Sendable {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation

    init() {
        let (inboundStream, continuation) = AsyncStream<SyncMessage>.makeStream()
        inbound = inboundStream
        inboundContinuation = continuation
        let (states, stateContinuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
        stateContinuation.yield(.connected)
        connectionState = states
    }

    func send(_ message: SyncMessage) async throws {}

    func push(_ message: SyncMessage) {
        inboundContinuation.yield(message)
    }
}

/// A stale/concurrent `.snapshot` that doesn't include a phone-emitted
/// optimistic op must not silently erase it from `tail` — `applySnapshot`
/// keeps exactly the ops the incoming snapshot hasn't absorbed. Without that
/// (e.g. a bare `tail = []` on every `.snapshot`), the phone's own in-flight
/// edit would vanish the moment any snapshot lands, before the phone's op is
/// ever folded into one.
private func checkReceiverPreservesUnfoldedLocalTailAcrossAStaleSnapshot() async throws {
    let tileId = UUID()
    let seedOpId = OpId(lamport: 1, replica: UUID())
    let createOp = LoggedOp(
        opId: seedOpId,
        op: .createTile(
            id: tileId,
            kind: .terminal,
            title: "seed",
            frame: TileFrame(x: 0, y: 0, width: 100, height: 100),
            zPosition: FracIndex(value: 0.1)
        )
    )
    let staleSnapshot = compact(log: [createOp], through: seedOpId.lamport).snapshot

    let transport = ScriptablePushTransport()
    transport.push(.snapshot(staleSnapshot))
    let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: transport))
    await receiver.connect()

    var seeded = false
    for _ in 0..<50 {
        if await receiver.currentState().canvasState.tiles.first(where: { $0.id == tileId })?.title == "seed" {
            seeded = true
            break
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    expect(seeded, "stale snapshot: test setup — the seeded snapshot's tile lands before the local edit")

    try await receiver.emit(.setTileTitle(id: tileId, title: "phone-local-edit"))
    let afterEmit = await receiver.currentState()
    expect(
        afterEmit.canvasState.tiles.first { $0.id == tileId }?.title == "phone-local-edit",
        "stale snapshot: test setup — the local optimistic edit is visible before the stale snapshot arrives"
    )

    // A second snapshot arrives that still only folds lamport 1 — it has no
    // knowledge of the phone's just-emitted op (lamport 2), exactly the
    // "concurrent snapshot doesn't include this replica's own in-flight edit"
    // hazard.
    transport.push(.snapshot(staleSnapshot))
    // Give the receiver's actor task room to process the pushed snapshot
    // before asserting on its effect.
    for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }

    let afterStaleSnapshot = await receiver.currentState()
    let titleAfter = afterStaleSnapshot.canvasState.tiles.first { $0.id == tileId }?.title
    expect(
        titleAfter == "phone-local-edit",
        "stale snapshot: local optimistic edit survives a subsequent snapshot that doesn't include it, got \(String(describing: titleAfter))"
    )

    await receiver.stop()
}

/// Minimal lock-protected counter — read from the check's task after being
/// written from the receiver actor's send-call context; a plain `var` would
/// race.
private final class LockedCounter: @unchecked Sendable {
    private var storage = 0
    private let lock = NSLock()
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        storage += 1
        return storage
    }
}

/// Wraps a REAL `FakeReplicaSyncTransport` (so a real store/sender sit behind
/// it) and fails the FIRST `.op` send attempt, forwarding every other message
/// (including any later `.op`, which `emitAll`'s stop-at-first-failure
/// contract must ensure never happens) through to the real fake bus. Counts
/// `.op` send attempts so a check can assert the second op was NEVER sent.
private final class FailFirstOpSendTransport: ContinuumRevivedSync.SyncTransport, @unchecked Sendable {
    private let inner: FakeReplicaSyncTransport
    private let opAttempts = LockedCounter()
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>

    init(inner: FakeReplicaSyncTransport) {
        self.inner = inner
        inbound = inner.inbound
        connectionState = inner.connectionState
    }

    func send(_ message: SyncMessage) async throws {
        if case .op = message {
            let attempt = opAttempts.increment()
            if attempt == 1 {
                throw SyncTransportError.sendFailed(reason: "test-injected failure on the first op send")
            }
        }
        try await inner.send(message)
    }

    var opSendAttemptCount: Int { opAttempts.value }
}

/// `SpatialOpReceiver.emitAll` over a REAL receiver/sender/store: the FIRST
/// op's send FAILS → the store receives ZERO new ops, the SECOND op is NEVER
/// sent (send-attempt count stays at 1), and the receiver's materialized
/// state reverts to exactly its pre-emit value. Also proves the success path:
/// both ops land in the store in order and both sides converge.
private func checkEmitAllStopsAtFirstFailureAndSuccessPathLandsInOrder() async throws {
    let tileId = UUID()
    let zoneId = UUID()
    let seedOpId = OpId(lamport: 1, replica: UUID())
    let createOp = LoggedOp(
        opId: seedOpId,
        op: .createTile(
            id: tileId,
            kind: .terminal,
            title: "seed",
            frame: TileFrame(x: 0, y: 0, width: 100, height: 100),
            zPosition: FracIndex(value: 0.1)
        )
    )
    let newFrame = TileFrame(x: 42, y: 84, width: 200, height: 150)
    let ops: [Op] = [
        .setTileFrame(id: tileId, frame: newFrame),
        .setTileZone(tileId: tileId, zoneId: zoneId),
    ]

    // ── Failure path: the FIRST op's send fails. ──
    do {
        let store = MemorySpatialOpLogStore(seeding: [createOp])
        let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 61024)
        let (hostReplica, hostInbound) = await fake.makeReplica()
        let (observerReplica, observerInbound) = await fake.makeReplica()
        let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
        let observerTransport = FailFirstOpSendTransport(inner: FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound))

        let sender = SpatialOpSender(store: store, demux: SyncMessageDemux(transport: hostTransport), authorizedScope: .operator)
        await sender.start()
        let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: observerTransport))
        await receiver.connect()

        let snapshotArrived = await tickUntil(fake: fake, timeoutSeconds: 2) {
            await receiver.currentState().canvasState.tiles.first(where: { $0.id == tileId })?.title == "seed"
        }
        expect(snapshotArrived, "emitAll stop-on-failure: test setup — cold snapshot lands before emitAll")

        let before = try await receiver.currentState().canonicalEncoded()

        var threw = false
        do {
            try await receiver.emitAll(ops)
        } catch {
            threw = true
        }
        expect(threw, "emitAll stop-on-failure: emitAll surfaces the first op's send failure to the caller")

        // Give the fake bus a few ticks to prove the drop is permanent, not a
        // race — if the second op HAD been sent, it would show up here.
        for _ in 0..<10 { await fake.tick() }
        let storeOpsAfter = await store.allOps()
        expect(storeOpsAfter.count == 1, "emitAll stop-on-failure: the store received ZERO new ops (still just the seed op), got \(storeOpsAfter.count - 1) new op(s)")
        expect(observerTransport.opSendAttemptCount == 1, "emitAll stop-on-failure: exactly 1 op send attempt — the second op was NEVER sent, got \(observerTransport.opSendAttemptCount)")

        let after = try await receiver.currentState().canonicalEncoded()
        expect(before == after, "emitAll stop-on-failure: receiver's materialized state reverted to exactly pre-emit, byte-identical")
        let afterTile = (await receiver.currentState()).canvasState.tiles.first { $0.id == tileId }
        expect(afterTile?.frame == TileFrame(x: 0, y: 0, width: 100, height: 100), "emitAll stop-on-failure: tile frame reverted to the pre-emit seed frame, got \(String(describing: afterTile?.frame))")
        expect(afterTile?.zoneId == nil, "emitAll stop-on-failure: zoneId never touched (op 2 never sent), got \(String(describing: afterTile?.zoneId))")

        await sender.stop()
        await receiver.stop()
    }

    // ── Success path: both ops land in order, both sides converge. ──
    do {
        let store = MemorySpatialOpLogStore(seeding: [createOp])
        let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 61025)
        let (hostReplica, hostInbound) = await fake.makeReplica()
        let (observerReplica, observerInbound) = await fake.makeReplica()
        let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
        let observerTransport = FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound)

        let sender = SpatialOpSender(store: store, demux: SyncMessageDemux(transport: hostTransport), authorizedScope: .operator)
        await sender.start()
        let receiver = SpatialOpReceiver(demux: SyncMessageDemux(transport: observerTransport))
        await receiver.connect()

        let snapshotArrived = await tickUntil(fake: fake, timeoutSeconds: 2) {
            await receiver.currentState().canvasState.tiles.first(where: { $0.id == tileId })?.title == "seed"
        }
        expect(snapshotArrived, "emitAll success path: test setup — cold snapshot lands before emitAll")

        try await receiver.emitAll(ops)
        let landed = await tickUntil(fake: fake, timeoutSeconds: 2) { await store.allOps().count == 3 }
        expect(landed, "emitAll success path: both ops land in the desktop-role store")

        let storeOps = await store.allOps()
        let newOpKinds = storeOps.filter { $0.opId != seedOpId }.map(\.op)
        expect(newOpKinds == ops, "emitAll success path: ops land in the store IN ORDER [setTileFrame, setTileZone], got \(newOpKinds)")

        let converged = await tickUntil(fake: fake, timeoutSeconds: 2) {
            let storeEncoded = try? materialize(ops: await store.allOps()).canonicalEncoded()
            let receiverEncoded = try? (await receiver.currentState()).canonicalEncoded()
            return storeEncoded != nil && storeEncoded == receiverEncoded
        }
        expect(converged, "emitAll success path: store and receiver MaterializedState converge byte-identically")

        let finalTile = (await receiver.currentState()).canvasState.tiles.first { $0.id == tileId }
        expect(finalTile?.frame == newFrame, "emitAll success path: final frame is the emitted move frame")
        expect(finalTile?.zoneId == zoneId, "emitAll success path: final zoneId is the emitted membership change")

        await sender.stop()
        await receiver.stop()
    }

    print("emitAll checks: stop-on-failure storeNewOps=0 opSendAttempts=1 revertedByteIdentical=true; success-path ordered=[setTileFrame,setTileZone] converged=true")
}

func runSpatialSyncChecks() async throws {
    await checkFreshSpatialSubscribeWaitsForRemoteDesktopState()
    try await checkSpatialOpSyncRealPathAtOperatorScope()
    try await checkObserverScopeEmissionIsDroppedAtTheSender()
    try await checkReceiverRevertsOptimisticApplyOnSendFailure()
    try await checkReceiverPreservesUnfoldedLocalTailAcrossAStaleSnapshot()
    try await checkEmitAllStopsAtFirstFailureAndSuccessPathLandsInOrder()
    print("ContinuumRevivedSyncChecks passed: spatial op sync — snapshot-then-tail, operator-scope move/membership/bring-to-front convergence + lamport allocation + order-independence, observer-scope drop, send-failure revert, stale-snapshot tail preservation, emitAll stop-on-first-failure + ordered success path")
}
