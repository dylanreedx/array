import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/58-activity-projection-transport.md
// Executable checks for the activity projection over the landed SyncTransport
// seam. These are intentionally in *Checks, not XCTest.

private actor LoopbackSyncTransport: ContinuumRevivedSync.SyncTransport {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private let connectionContinuation: AsyncStream<ContinuumRevivedSync.ConnectionState>.Continuation
    private var peer: LoopbackSyncTransport?
    private var dropPredicate: (@Sendable (SyncMessage) -> Bool)?
    private var delaySteps = 0
    private var pending: [(message: SyncMessage, countdown: Int)] = []
    private(set) var sentMessages: [SyncMessage] = []
    private(set) var deliveredMessages: [SyncMessage] = []

    init() {
        (inbound, inboundContinuation) = AsyncStream<SyncMessage>.makeStream()
        (connectionState, connectionContinuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
    }

    func attach(_ peer: LoopbackSyncTransport) { self.peer = peer }
    func setDropPredicate(_ predicate: @escaping @Sendable (SyncMessage) -> Bool) { dropPredicate = predicate }
    func setDelaySteps(_ steps: Int) { delaySteps = steps }

    func send(_ message: SyncMessage) async throws {
        sentMessages.append(message)
        if let dropPredicate, dropPredicate(message) { return }
        guard delaySteps > 0 else {
            await peer?.deliver(message)
            return
        }
        pending.append((message, delaySteps))
        await drainOneStep()
    }

    func drainOneStep() async {
        var ready: [SyncMessage] = []
        pending = pending.compactMap { entry in
            let next = entry.countdown - 1
            if next <= 0 {
                ready.append(entry.message)
                return nil
            }
            return (entry.message, next)
        }
        for message in ready {
            await peer?.deliver(message)
        }
    }

    func flushAll() async {
        let remaining = pending.map(\.message)
        pending.removeAll()
        for message in remaining {
            await peer?.deliver(message)
        }
    }

    func delivered() -> [SyncMessage] { deliveredMessages }
    func allSentMessages() -> [SyncMessage] { sentMessages }

    fileprivate func deliver(_ message: SyncMessage) {
        deliveredMessages.append(message)
        inboundContinuation.yield(message)
    }
}

private actor BlackHoleTransport: ContinuumRevivedSync.SyncTransport {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private let connectionContinuation: AsyncStream<ContinuumRevivedSync.ConnectionState>.Continuation
    private(set) var sentMessages: [SyncMessage] = []

    init() {
        (inbound, inboundContinuation) = AsyncStream<SyncMessage>.makeStream()
        (connectionState, connectionContinuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
    }

    func send(_ message: SyncMessage) async throws {
        sentMessages.append(message)
    }

    func push(_ message: SyncMessage) {
        inboundContinuation.yield(message)
    }

    func allSentMessages() -> [SyncMessage] { sentMessages }
}

private actor ActivityItemProbe {
    private var items: [ActivityStreamItem] = []

    func record(_ item: ActivityStreamItem) {
        items.append(item)
    }

    func count() -> Int { items.count }
    func first() -> ActivityStreamItem? { items.first }
}

// Not `private` — ticket 61b's SpatialSyncTests.swift reuses this exact
// adapter (the "61a adapter precedent") to drive the SpatialOpSender/Receiver
// real-path check over the same FakeSyncTransport substrate.
final class FakeReplicaSyncTransport: ContinuumRevivedSync.SyncTransport, @unchecked Sendable {
    private let fake: ContinuumRevivedSync.FakeSyncTransport
    private let replicaId: ContinuumRevivedSync.FakeSyncTransport.ReplicaId
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>

    init(fake: ContinuumRevivedSync.FakeSyncTransport, replicaId: ContinuumRevivedSync.FakeSyncTransport.ReplicaId, inbound: AsyncStream<SyncMessage>) {
        self.fake = fake
        self.replicaId = replicaId
        self.inbound = inbound
        let (states, continuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
        continuation.yield(.connected)
        self.connectionState = states
    }

    func send(_ message: SyncMessage) async throws {
        await fake.send(message, from: replicaId)
    }
}

private final class OneShotEventDrop: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<UInt64>

    init(sequences: Set<UInt64>) {
        pending = sequences
    }

    func shouldDrop(_ message: SyncMessage) -> Bool {
        guard case .activity(.event(let event)) = message else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard pending.contains(event.sequence) else { return false }
        pending.remove(event.sequence)
        return true
    }
}

private func makePair() async -> (host: LoopbackSyncTransport, observer: LoopbackSyncTransport) {
    let host = LoopbackSyncTransport()
    let observer = LoopbackSyncTransport()
    await host.attach(observer)
    await observer.attach(host)
    return (host, observer)
}

// P2A.8: these fixtures are TILE-BOUND agents, so the agent id and the tile hint are
// the same value — the same equality the legacy decode relies on. That keeps every
// existing assertion in this file addressing the same aggregate as before, while the
// key it addresses is now the agent's.
private func makeDraft(
    tileId: UUID,
    tone: ActivityEventTone = .info,
    status: AgentStatus,
    summary: String = "activity",
    occurredAt: Date = Date(timeIntervalSinceReferenceDate: 100),
    approvalRequestId: String? = nil
) -> AgentActivityEventDraft {
    AgentActivityEventDraft(
        agentId: tileId,
        tileId: tileId,
        runId: nil,
        tone: tone,
        kind: "status",
        status: status,
        summary: summary,
        occurredAt: occurredAt,
        approvalRequestId: approvalRequestId
    )
}

private func waitForDeliveredActivityItems(
    on transport: LoopbackSyncTransport,
    atLeast count: Int,
    timeoutSeconds: Double
) async -> [ActivityStreamItem] {
    func activityItems() async -> [ActivityStreamItem] {
        await transport.delivered().compactMap { message in
            if case .activity(let item) = message { return item }
            return nil
        }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        let items = await activityItems()
        if items.count >= count { return items }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await activityItems()
}

private func waitForConvergence(
    receiver: ActivityProjectionReceiver,
    expectedSequence: UInt64,
    timeoutSeconds: Double
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        if await receiver.currentSnapshot().snapshotSequence == expectedSequence { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await receiver.currentSnapshot().snapshotSequence == expectedSequence
}

private func checkFreshReceiverSubscribeWaitsForRemoteActivity() async {
    let transport = BlackHoleTransport()
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: transport), scope: .observer)
    await receiver.connect()
    let stream = await receiver.subscribe()
    let probe = ActivityItemProbe()
    let task = Task {
        for await item in stream {
            await probe.record(item)
        }
    }

    try? await Task.sleep(for: .milliseconds(50))
    let countBeforeRemote = await probe.count()
    let activitySeenBeforeRemote = await receiver.hasReceivedRemoteActivity()
    expect(countBeforeRemote == 0, "ticket85 activity receiver: subscribe does not emit local empty bootstrap snapshot")
    expect(activitySeenBeforeRemote == false, "ticket85 activity receiver: remote flag is false before CloudKit activity")

    await transport.push(.activity(.snapshot(.empty)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if await probe.count() > 0 { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let countAfterRemote = await probe.count()
    let activitySeenAfterRemote = await receiver.hasReceivedRemoteActivity()
    expect(countAfterRemote == 1, "ticket85 activity receiver: real remote empty snapshot is emitted")
    expect(activitySeenAfterRemote == true, "ticket85 activity receiver: remote flag flips after remote activity")
    if case .snapshot(let snapshot)? = await probe.first() {
        expect(snapshot == .empty, "ticket85 activity receiver: remote empty snapshot stays empty")
    } else {
        expect(false, "ticket85 activity receiver: first emitted item is a snapshot")
    }

    task.cancel()
    await receiver.stop()
}

private func checkSnapshotThenTailIsGapFree() async {
    let replicaId = UUID()
    let tileId = UUID()
    let store = ActivityStore(replicaId: replicaId)
    await store.append(makeDraft(tileId: tileId, status: .working))
    await store.append(makeDraft(tileId: tileId, tone: .tool, status: .working, summary: "tool ran"))

    let (host, observer) = await makePair()
    let hostDemux = SyncMessageDemux(transport: host)
    let observerDemux = SyncMessageDemux(transport: observer)
    let sender = ActivityProjectionSender(store: store, demux: hostDemux, authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: observerDemux, scope: .observer)
    await receiver.connect()

    let wireItems = await waitForDeliveredActivityItems(on: observer, atLeast: 1, timeoutSeconds: 2)
    expect(!wireItems.isEmpty, "snapshot-then-tail: activity item delivered")
    guard case .snapshot(let wireSnapshot)? = wireItems.first else {
        expect(false, "snapshot-then-tail: first wire item must be .snapshot")
        return
    }
    expect(wireSnapshot.snapshotSequence == 2, "snapshot-then-tail: snapshot carries both existing events")
    expect(wireSnapshot.byAgent[tileId]?.status == .working, "snapshot-then-tail: status projected")
    let snapshotProcessed = await waitForConvergence(receiver: receiver, expectedSequence: 2, timeoutSeconds: 2)
    expect(snapshotProcessed, "snapshot-then-tail: receiver folds snapshot")
    let receiverSnapshot = await receiver.currentSnapshot()
    let storeSnapshot = await store.currentSnapshot()
    expect(receiverSnapshot == storeSnapshot, "snapshot-then-tail: receiver equals store")

    await sender.stop()
    await receiver.stop()
}

private func checkGapDetectionTriggersReplay() async {
    let replicaId = UUID()
    let tileId = UUID()
    let store = ActivityStore(replicaId: replicaId)
    let (host, observer) = await makePair()
    let dropper = OneShotEventDrop(sequences: [2])
    await host.setDropPredicate { dropper.shouldDrop($0) }

    let sender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: host), authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: observer), scope: .observer, gapRetryBackoff: .milliseconds(5))
    await receiver.connect()

    await store.append(makeDraft(tileId: tileId, status: .working))
    await store.append(makeDraft(tileId: tileId, status: .needsAttention))
    await store.append(makeDraft(tileId: tileId, status: .done))

    let replayConverged = await waitForConvergence(receiver: receiver, expectedSequence: 3, timeoutSeconds: 2)
    expect(replayConverged, "gap detection: replay converges to sequence 3")
    let finalSnapshot = await receiver.currentSnapshot()
    let finalStoreSnapshot = await store.currentSnapshot()
    expect(finalSnapshot == finalStoreSnapshot, "gap detection: receiver equals store after replay")
    expect(finalSnapshot.byAgent[tileId]?.status == .done, "gap detection: final status is done")
    expect(finalSnapshot.byAgent[tileId]?.recent.count == 3, "gap detection: no double-application")

    await sender.stop()
    await receiver.stop()
}

private func checkFreshReceiverResumeFromPersistedCursorIsIncremental() async {
    let replicaId = UUID()
    let tileId = UUID()
    let seedTransport = BlackHoleTransport()
    let seededReceiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: seedTransport), scope: .observer)
    await seededReceiver.connect(cursor: ActivityCursor(sequence: 2, replicaId: replicaId))
    let firstPostCursorEvent = AgentActivityEvent(stamping: makeDraft(tileId: tileId, status: .working, summary: "event 3"), sequence: 3, replicaId: replicaId)
    await seedTransport.push(.activity(.event(firstPostCursorEvent)))
    let seedConverged = await waitForConvergence(receiver: seededReceiver, expectedSequence: 3, timeoutSeconds: 1)
    expect(seedConverged, "cursor resume: fresh receiver seeds local sequence state from persisted cursor")
    await seededReceiver.stop()

    let store = ActivityStore(replicaId: replicaId)
    await store.append(makeDraft(tileId: tileId, status: .working, summary: "event 1"))
    await store.append(makeDraft(tileId: tileId, status: .needsAttention, summary: "event 2"))

    let persistedCursor = ActivityCursor(sequence: 2, replicaId: replicaId)

    await store.append(makeDraft(tileId: tileId, status: .working, summary: "event 3"))
    await store.append(makeDraft(tileId: tileId, status: .done, summary: "event 4"))

    let (host, observer) = await makePair()
    let sender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: host), authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: observer), scope: .observer)
    await receiver.connect(cursor: persistedCursor)

    let wireItems = await waitForDeliveredActivityItems(on: observer, atLeast: 3, timeoutSeconds: 2)
    expect(wireItems.count >= 3, "cursor resume: snapshot plus post-cursor replay delivered")
    guard case .snapshot(let firstSnapshot)? = wireItems.first else {
        expect(false, "cursor resume: cursor-bearing serve starts with snapshot")
        await sender.stop()
        await receiver.stop()
        return
    }
    expect(firstSnapshot.snapshotSequence == 4, "cursor resume: leading snapshot is current")

    let replayedSequences = wireItems.dropFirst().compactMap { item -> UInt64? in
        if case .event(let event) = item { return event.sequence }
        return nil
    }
    expect(replayedSequences == [3, 4], "cursor resume: replay is incremental from persisted cursor, got \(replayedSequences)")

    let converged = await waitForConvergence(receiver: receiver, expectedSequence: 4, timeoutSeconds: 2)
    expect(converged, "cursor resume: fresh receiver converges through production receiver path")
    let finalSnapshot = await receiver.currentSnapshot()
    let storeSnapshot = await store.currentSnapshot()
    expect(finalSnapshot == storeSnapshot, "cursor resume: fresh receiver equals store")
    expect(finalSnapshot.byAgent[tileId]?.recent.map(\.sequence) == [1, 2, 3, 4], "cursor resume: final snapshot has the full folded activity history")

    await sender.stop()
    await receiver.stop()
}

private func checkSharedDemuxRegistersBeforeSend() async {
    let replicaId = UUID()
    let tileId = UUID()
    let store = ActivityStore(replicaId: replicaId)
    await store.append(makeDraft(tileId: tileId, status: .working))

    let (host, observer) = await makePair()
    let sharedObserverDemux = SyncMessageDemux(transport: observer)

    actor Collector {
        private(set) var spatial: [SyncMessage] = []
        func addSpatial(_ message: SyncMessage) { spatial.append(message) }
        func spatialMessages() -> [SyncMessage] { spatial }
    }
    let collector = Collector()
    let spatialStream = await sharedObserverDemux.subscribe()
    let spatialTask = Task {
        for await message in spatialStream {
            if case .op = message { await collector.addSpatial(message) }
        }
    }

    let sender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: host), authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: sharedObserverDemux, scope: .observer)
    await receiver.connect()

    let op = LoggedOp(opId: OpId(lamport: 1, replica: UUID()), op: .setTileTitle(id: tileId, title: "spatial"))
    try? await host.send(.op(op))

    let sharedDemuxConverged = await waitForConvergence(receiver: receiver, expectedSequence: 1, timeoutSeconds: 2)
    expect(sharedDemuxConverged, "shared demux: receiver got snapshot even with pre-existing spatial subscriber")
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await collector.spatialMessages().count < 1 && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    let spatialMessages = await collector.spatialMessages()
    expect(spatialMessages == [.op(op)], "shared demux: pre-existing spatial subscriber saw its op")

    spatialTask.cancel()
    await sender.stop()
    await receiver.stop()
}

private func checkScopeGuardBlocksUnauthorizedSubscription() async {
    expect(Scope.observer.contains(.orchestrationRead), "scope guard: observer can read")
    expect(!Scope.observer.contains(.orchestrationOperate), "scope guard: observer cannot operate orchestration")
    expect(!Scope.observer.contains(.terminalOperate), "scope guard: observer cannot operate terminal")

    let store = ActivityStore(replicaId: UUID())
    await store.append(makeDraft(tileId: UUID(), status: .working))

    let (unauthorizedHost, unauthorizedObserver) = await makePair()
    let unauthorizedSender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: unauthorizedHost), authorizedScope: Scope())
    await unauthorizedSender.start()
    try? await unauthorizedObserver.send(.activitySubscribe(ActivitySubscribeRequest(cursor: nil)))
    let blocked = await waitForDeliveredActivityItems(on: unauthorizedObserver, atLeast: 1, timeoutSeconds: 0.15)
    expect(blocked.isEmpty, "scope guard: unauthorized sender serves zero items")
    await unauthorizedSender.stop()

    let (authorizedHost, authorizedObserver) = await makePair()
    let authorizedSender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: authorizedHost), authorizedScope: .observer)
    await authorizedSender.start()
    try? await authorizedObserver.send(.activitySubscribe(ActivitySubscribeRequest(cursor: nil)))
    let served = await waitForDeliveredActivityItems(on: authorizedObserver, atLeast: 1, timeoutSeconds: 1)
    expect(!served.isEmpty, "scope guard: authorized sender serves identical request")
    await authorizedSender.stop()
}

private func checkActivityStreamItemNoForbiddenFields() {
    let forbidden: Set<String> = ["pid", "paneid", "tmuxwindowtarget", "scrollback", "transcript", "ptyfd", "runtimeref", "panetarget", "tmuxtarget"]
    func mirrorCheck(_ label: String, _ value: Any) {
        for child in Mirror(reflecting: value).children {
            let name = (child.label ?? "").lowercased().replacingOccurrences(of: "_", with: "")
            expect(!forbidden.contains(name), "I5 continuation: \(label) field \(child.label ?? "?") is forbidden")
        }
    }

    let event = AgentActivityEvent(stamping: makeDraft(tileId: UUID(), tone: .tool, status: .working, summary: "ran a tool"), sequence: 7, replicaId: UUID())
    let message = SyncMessage.activity(.event(event))
    mirrorCheck("AgentActivityEvent", event)
    mirrorCheck("ActivityLogSnapshot", apply(.empty, event))
    let encoded = try! JSONEncoder().encode(message)
    let decoded = try! JSONDecoder().decode(SyncMessage.self, from: encoded)
    guard case .activity(.event(let decodedEvent)) = decoded else {
        expect(false, "I5 continuation: activity event round-trips")
        return
    }
    expect(decodedEvent == event, "I5 continuation: event is lossless through wire envelope")
    mirrorCheck("decoded AgentActivityEvent", decodedEvent)
    expect(SyncPayloadTaint.violations(in: message).isEmpty, "I5 continuation: SyncPayloadTaint clean for activity")
}

private func checkGapRetryExhaustionFallsBackToColdReconnect() async {
    let replicaId = UUID()
    let tileId = UUID()
    let transport = BlackHoleTransport()
    let gapRetryLimit = 2
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: transport), scope: .observer, gapRetryLimit: gapRetryLimit, gapRetryBackoff: .milliseconds(5))
    await receiver.connect()

    let baseline = ActivityLogSnapshot(snapshotSequence: 1, snapshotReplicaId: replicaId, byAgent: [
        tileId: AgentActivity(status: .working, lastSummary: "s", recent: [], updatedAt: Date(), tileId: tileId)
    ])
    await transport.push(.activity(.snapshot(baseline)))
    let gapEvent = AgentActivityEvent(stamping: makeDraft(tileId: tileId, status: .done), sequence: 5, replicaId: replicaId)
    await transport.push(.activity(.event(gapEvent)))
    try? await Task.sleep(for: .milliseconds(200))

    let requests = await transport.allSentMessages().compactMap { message -> ActivitySubscribeRequest? in
        if case .activitySubscribe(let request) = message { return request }
        return nil
    }
    expect(requests.count == 1 + gapRetryLimit + 1, "gap retry: initial cold + retries + cold fallback")
    expect(requests.first?.cursor == nil, "gap retry: initial request is cold")
    expect(requests.last?.cursor == nil, "gap retry: final fallback is cold")
    for request in requests.dropFirst().dropLast() {
        expect(request.cursor == ActivityCursor(sequence: 1, replicaId: replicaId), "gap retry: retry carries cursor")
    }

    await receiver.stop()
}

private func runActivityProjectionBackendCheck() async -> Double {
    let replicaId = UUID()
    let tileIds = (0..<3).map { _ in UUID() }
    let store = ActivityStore(replicaId: replicaId)
    let (host, observer) = await makePair()
    await host.setDelaySteps(2)
    let dropper = OneShotEventDrop(sequences: [5])
    await host.setDropPredicate { dropper.shouldDrop($0) }

    let sender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: host), authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: observer), scope: .observer, gapRetryBackoff: .milliseconds(5))
    await receiver.connect()

    let clock = ContinuousClock()
    let start = clock.now
    let statusesForLastTile: [AgentStatus] = [.working, .needsAttention, .done]
    var lastTileStatusIndex = 0
    for i in 0..<10 {
        let tileId = tileIds[i % 3]
        let status: AgentStatus
        if tileId == tileIds[2] {
            status = statusesForLastTile[min(lastTileStatusIndex, statusesForLastTile.count - 1)]
            lastTileStatusIndex += 1
        } else {
            status = .working
        }
        await store.append(makeDraft(tileId: tileId, status: status, summary: "event \(i)"))
        for _ in 0..<4 { await host.drainOneStep(); await observer.drainOneStep() }
    }

    let expectedSequence = await store.currentSnapshot().snapshotSequence
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        await host.drainOneStep()
        await observer.drainOneStep()
        await host.flushAll()
        await observer.flushAll()
        if await receiver.currentSnapshot().snapshotSequence == expectedSequence { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let elapsed = start.duration(to: clock.now)
    let elapsedMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

    let backendReceiverSnapshot = await receiver.currentSnapshot()
    let backendStoreSnapshot = await store.currentSnapshot()
    expect(backendReceiverSnapshot == backendStoreSnapshot, "backend: receiver equals store after delay/drop/replay")
    let receiverStatuses = await receiver.agentStatusesByTileId()
    let storeSnapshot = await store.currentSnapshot()
    // Tile-keyed vs agent-keyed, equal because every fixture agent is bound to a tile
    // of the same id; `agentStatusesByTileId` projects through the hint.
    expect(receiverStatuses == storeSnapshot.byAgent.mapValues(\.status), "backend: status map matches")
    expect(receiverStatuses[tileIds[2]] == .done, "backend: final status is done")
    let recentCount = backendReceiverSnapshot.byAgent[tileIds[2]]?.recent.count
    expect(recentCount == statusesForLastTile.count, "backend: no double-application")
    expect(elapsedMs < 100, "backend: completes within 100ms, got \(elapsedMs)")

    await sender.stop()
    await receiver.stop()
    return elapsedMs
}

private func waitForFakeReceiverConvergence(
    fake: ContinuumRevivedSync.FakeSyncTransport,
    receiver: ActivityProjectionReceiver,
    expectedSequence: UInt64,
    timeoutSeconds: Double
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        await fake.tick()
        if await receiver.currentSnapshot().snapshotSequence == expectedSequence { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await receiver.currentSnapshot().snapshotSequence == expectedSequence
}

private func checkAgentsBoardProjectionOverFakeSyncTransportRealPath() async {
    let replicaId = UUID(uuidString: "61000000-0000-4000-8000-00000000F001")!
    let tileA = UUID(uuidString: "61000000-0000-4000-8000-00000000F00A")!
    let tileB = UUID(uuidString: "61000000-0000-4000-8000-00000000F00B")!
    let tileC = UUID(uuidString: "61000000-0000-4000-8000-00000000F00C")!
    let base = Date(timeIntervalSinceReferenceDate: 6_161)
    let store = ActivityStore(replicaId: replicaId)
    await store.append(makeDraft(tileId: tileA, status: .done, summary: "A initially done", occurredAt: base))
    await store.append(makeDraft(tileId: tileB, status: .working, summary: "B initially working", occurredAt: base.addingTimeInterval(1)))

    let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 61)
    let (hostReplica, hostInbound) = await fake.makeReplica()
    let (observerReplica, observerInbound) = await fake.makeReplica()
    let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
    let observerTransport = FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound)
    let sender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: hostTransport), authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: observerTransport), scope: .observer, gapRetryBackoff: .milliseconds(5))
    await receiver.connect(cursor: nil)

    let snapshotArrived = await waitForFakeReceiverConvergence(fake: fake, receiver: receiver, expectedSequence: 2, timeoutSeconds: 2)
    expect(snapshotArrived, "agents board real path: cold connect(cursor:nil) receives the initial snapshot over FakeSyncTransport")

    await store.append(makeDraft(tileId: tileC, tone: .approval, status: .needsAttention, summary: "C needs review", occurredAt: base.addingTimeInterval(2)))
    await store.append(makeDraft(tileId: tileA, tone: .approval, status: .needsAttention, summary: "A needs approval", occurredAt: base.addingTimeInterval(3)))
    await store.append(makeDraft(tileId: tileB, status: .done, summary: "B finished", occurredAt: base.addingTimeInterval(4)))

    let tailArrived = await waitForFakeReceiverConvergence(fake: fake, receiver: receiver, expectedSequence: 5, timeoutSeconds: 2)
    expect(tailArrived, "agents board real path: three incremental events tail through the production receiver")

    let finalSnapshot = await receiver.currentSnapshot()
    let rows = AgentsBoardProjection.rows(from: finalSnapshot)
    expect(rows.map { $0.agentId } == [tileA, tileC, tileB], "agents board real path: rows are attention-first with newest tie-break inside priority")
    expect(rows.map { $0.status } == [AgentStatus.needsAttention, AgentStatus.needsAttention, AgentStatus.done], "agents board real path: final statuses match the sent tail")
    let measuredOrder = rows.map { $0.agentId.uuidString }.joined(separator: ",")
    let measuredStatuses = rows.map { $0.status.rawValue }.joined(separator: ",")
    let measuredSummaries = rows.map { $0.lastSummary }.joined(separator: " | ")
    print("agents board real path: fakeSyncTransport coldConnectCursor=nil snapshotSequence=\(finalSnapshot.snapshotSequence) measuredOrder=\(measuredOrder) statuses=\(measuredStatuses) summaries=\(measuredSummaries)")

    await sender.stop()
    await receiver.stop()
}

private actor FakeApprovalSeam: ApprovalResponding {
    private let store: ActivityStore
    private var resolved: Set<String> = []
    private(set) var callCount = 0
    private(set) var invocations: [(agentId: UUID, requestId: String, decision: ApprovalDecision)] = []

    init(store: ActivityStore) {
        self.store = store
    }

    func respond(agentId: UUID, requestId: String, decision: ApprovalDecision) async -> ApprovalRespondResult {
        callCount += 1
        guard requestId != "unknown-request" else { return .unknownRequest }
        guard !resolved.contains(requestId) else { return .stale }
        resolved.insert(requestId)
        invocations.append((agentId: agentId, requestId: requestId, decision: decision))
        if decision == .accept {
            await store.append(makeDraft(
                tileId: agentId,
                tone: .approval,
                status: .working,
                summary: "approval resolved",
                occurredAt: Date(timeIntervalSinceReferenceDate: 6_262)
            ))
        }
        return .resolved
    }

    func invocationCount() -> Int { invocations.count }
    func totalCallCount() -> Int { callCount }
    func allInvocations() -> [(agentId: UUID, requestId: String, decision: ApprovalDecision)] { invocations }
}

private actor ApprovalAckCollector {
    private var acks: [ApprovalResponseAck] = []
    func add(_ ack: ApprovalResponseAck) { acks.append(ack) }
    func all() -> [ApprovalResponseAck] { acks }
}

private func waitForApprovalAck(
    fake: ContinuumRevivedSync.FakeSyncTransport,
    collector: ApprovalAckCollector,
    requestId: String,
    count: Int = 1,
    timeoutSeconds: Double = 2
) async -> [ApprovalResponseAck] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        await fake.tick()
        let matches = await collector.all().filter { $0.requestId == requestId }
        if matches.count >= count { return matches }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await collector.all().filter { $0.requestId == requestId }
}

private func checkApprovalResponderOverFakeSyncTransportRealPath() async {
    let replicaId = UUID(uuidString: "62000000-0000-4000-8000-00000000F001")!
    let tileId = UUID(uuidString: "62000000-0000-4000-8000-00000000F00A")!
    let requestId = "approval-62"
    let base = Date(timeIntervalSinceReferenceDate: 6_260)
    let store = ActivityStore(replicaId: replicaId)
    await store.append(makeDraft(
        tileId: tileId,
        tone: .approval,
        status: .needsAttention,
        summary: "approve deploy",
        occurredAt: base,
        approvalRequestId: requestId
    ))

    let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 62)
    let (hostReplica, hostInbound) = await fake.makeReplica()
    let (observerReplica, observerInbound) = await fake.makeReplica()
    let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
    let observerTransport = FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound)
    let hostDemux = SyncMessageDemux(transport: hostTransport)
    let observerDemux = SyncMessageDemux(transport: observerTransport)
    let sender = ActivityProjectionSender(store: store, demux: hostDemux, authorizedScope: .observer)
    await sender.start()
    let seam = FakeApprovalSeam(store: store)
    let responder = ApprovalResponder(seam: seam, demux: hostDemux, authorizedScope: .operator)
    await responder.start()

    let receiver = ActivityProjectionReceiver(demux: observerDemux, scope: .observer, gapRetryBackoff: .milliseconds(5))
    await receiver.connect(cursor: nil)
    let ackCollector = ApprovalAckCollector()
    let ackStream = await observerDemux.subscribe()
    let ackTask = Task {
        for await message in ackStream {
            if case .approvalResponseAck(let ack) = message {
                await ackCollector.add(ack)
            }
        }
    }

    let seeded = await waitForFakeReceiverConvergence(fake: fake, receiver: receiver, expectedSequence: 1, timeoutSeconds: 2)
    expect(seeded, "approval responder real path: pending approval event reaches receiver")
    let seededSnapshot = await receiver.currentSnapshot()
    let seededActivity = seededSnapshot.byAgent[tileId]
    expect(seededActivity?.status == .needsAttention, "approval responder real path: receiver folds needsAttention")
    expect(AgentsBoardProjection.respondableRequest(in: seededActivity!)?.approvalRequestId == requestId, "approval responder real path: receiver exposes approvalRequestId")

    try? await observerDemux.send(.approvalResponse(ApprovalResponseRequest(agentId: tileId, requestId: requestId, decision: .accept)))
    let resolvedAcks = await waitForApprovalAck(fake: fake, collector: ackCollector, requestId: requestId)
    expect(resolvedAcks.last?.outcome == .resolved, "approval responder real path: operator accept acks resolved")
    let resolvedConverged = await waitForFakeReceiverConvergence(fake: fake, receiver: receiver, expectedSequence: 2, timeoutSeconds: 2)
    expect(resolvedConverged, "approval responder real path: resolution activity flows back through projection")
    let resolvedSnapshot = await receiver.currentSnapshot()
    expect(resolvedSnapshot.byAgent[tileId]?.status == .working, "approval responder real path: folded status clears needsAttention")
    let firstInvocationCount = await seam.invocationCount()
    expect(firstInvocationCount == 1, "approval responder real path: first accept invokes seam exactly once")
    let firstInvocations = await seam.allInvocations()
    let firstInvocation = firstInvocations.first
    expect(
        firstInvocations.count == 1 &&
            firstInvocation?.agentId == tileId &&
            firstInvocation?.requestId == requestId &&
            firstInvocation?.decision == .accept,
        "approval responder real path: first accept forwards exact agentId, requestId, and .accept decision to seam"
    )
    let firstCallCount = await seam.totalCallCount()
    expect(firstCallCount == 1, "approval responder real path: first accept calls seam exactly once")

    try? await observerDemux.send(.approvalResponse(ApprovalResponseRequest(agentId: tileId, requestId: requestId, decision: .accept)))
    let staleAcks = await waitForApprovalAck(fake: fake, collector: ackCollector, requestId: requestId, count: 2)
    expect(staleAcks.last?.outcome == .stale, "approval responder real path: second identical accept acks stale")
    let staleInvocationCount = await seam.invocationCount()
    expect(staleInvocationCount == 1, "approval responder real path: stale second accept does not re-invoke seam")
    let staleCallCount = await seam.totalCallCount()
    expect(staleCallCount == 1, "approval responder real path: stale second accept does not call seam again")

    let unauthorizedSeam = FakeApprovalSeam(store: store)
    let unauthorizedTransport = BlackHoleTransport()
    let unauthorizedDemux = SyncMessageDemux(transport: unauthorizedTransport)
    let unauthorizedResponder = ApprovalResponder(seam: unauthorizedSeam, demux: unauthorizedDemux, authorizedScope: .observer)
    await unauthorizedResponder.start()
    await unauthorizedTransport.push(.approvalResponse(ApprovalResponseRequest(agentId: tileId, requestId: "unauthorized-request", decision: .decline)))
    try? await Task.sleep(for: .milliseconds(50))
    let unauthorizedAck = await unauthorizedTransport.allSentMessages().compactMap { message -> ApprovalResponseAck? in
        if case .approvalResponseAck(let ack) = message { return ack }
        return nil
    }.last
    expect(unauthorizedAck?.outcome == .unauthorized, "approval responder real path: observer-scope responder acks unauthorized")
    let unauthorizedInvocationCount = await unauthorizedSeam.invocationCount()
    expect(unauthorizedInvocationCount == 0, "approval responder real path: unauthorized path never invokes seam")
    await unauthorizedResponder.stop()

    try? await observerDemux.send(.approvalResponse(ApprovalResponseRequest(agentId: tileId, requestId: "unknown-request", decision: .decline)))
    let unknownAcks = await waitForApprovalAck(fake: fake, collector: ackCollector, requestId: "unknown-request")
    expect(unknownAcks.last?.outcome == .unknownRequest, "approval responder real path: unknown request acks unknownRequest")

    let allAcks = await ackCollector.all()
    let measuredAcks = allAcks.map { "\($0.requestId):\($0.outcome.rawValue)" }.joined(separator: ",")
    let finalStatus = (await receiver.currentSnapshot()).byAgent[tileId]?.status.rawValue ?? "nil"
    let finalInvocationCount = await seam.invocationCount()
    let finalInvocations = await seam.allInvocations()
    let finalUnauthorizedInvocationCount = await unauthorizedSeam.invocationCount()
    let measuredInvocations = finalInvocations.map { "\($0.agentId.uuidString):\($0.requestId):\($0.decision.rawValue)" }.joined(separator: ",")
    print("approval responder real path: acks=\(measuredAcks) seamInvocations=\(finalInvocationCount) invocationTuples=\(measuredInvocations) finalStatus=\(finalStatus) unauthorizedInvocations=\(finalUnauthorizedInvocationCount)")

    ackTask.cancel()
    await responder.stop()
    await sender.stop()
    await receiver.stop()
}

// P2A.8 over the REAL sender/receiver path, with `agentId != tileId` and a headless
// agent. Every other fixture in this file binds an agent to a tile of the same id — which
// keeps their assertions addressing the same aggregate as before the key moved, but means
// a path that still keyed by tile would pass them. This one cannot: the two ids differ,
// so a tile-keyed fold lands under the wrong key, and the headless agent has no tile to
// land under at all.
private func checkAgentKeyedProjectionOverRealPath() async {
    let replicaId = UUID(uuidString: "61000000-0000-4000-8000-00000000F101")!
    let boundAgent = UUID(uuidString: "61000000-0000-4000-8000-00000000FA01")!
    let boundTile = UUID(uuidString: "61000000-0000-4000-8000-00000000FB01")!
    let headlessAgent = UUID(uuidString: "61000000-0000-4000-8000-00000000FA02")!
    let base = Date(timeIntervalSinceReferenceDate: 6_181)
    let store = ActivityStore(replicaId: replicaId)

    let fake = ContinuumRevivedSync.FakeSyncTransport(seed: 62)
    let (hostReplica, hostInbound) = await fake.makeReplica()
    let (observerReplica, observerInbound) = await fake.makeReplica()
    let hostTransport = FakeReplicaSyncTransport(fake: fake, replicaId: hostReplica, inbound: hostInbound)
    let observerTransport = FakeReplicaSyncTransport(fake: fake, replicaId: observerReplica, inbound: observerInbound)
    let sender = ActivityProjectionSender(store: store, demux: SyncMessageDemux(transport: hostTransport), authorizedScope: .observer)
    await sender.start()
    let receiver = ActivityProjectionReceiver(demux: SyncMessageDemux(transport: observerTransport), scope: .observer, gapRetryBackoff: .milliseconds(5))
    await receiver.connect(cursor: nil)

    await store.append(AgentActivityEventDraft(
        agentId: boundAgent, tileId: boundTile, runId: nil, tone: .info, kind: "status",
        status: .working, summary: "bound agent working", occurredAt: base))
    await store.append(AgentActivityEventDraft(
        agentId: headlessAgent, tileId: nil, runId: nil, tone: .approval, kind: "needs-attention",
        status: .needsAttention, summary: "headless agent needs approval", occurredAt: base.addingTimeInterval(1),
        approvalRequestId: "approval-headless"))

    let converged = await waitForFakeReceiverConvergence(fake: fake, receiver: receiver, expectedSequence: 2, timeoutSeconds: 2)
    expect(converged, "P2A.8 real path: agent-keyed events reach the production receiver")

    let snapshot = await receiver.currentSnapshot()
    expect(snapshot.byAgent[boundAgent] != nil && snapshot.byAgent[boundTile] == nil,
           "P2A.8 real path: the received snapshot is keyed by agent id, not by the tile hint")
    expect(snapshot.byAgent[boundAgent]?.tileId == boundTile,
           "P2A.8 real path: the tile hint survives the wire")
    expect(snapshot.byAgent[headlessAgent]?.tileId == nil,
           "P2A.8 real path: a headless agent arrives with no tile hint")

    let rows = AgentsBoardProjection.rows(from: snapshot)
    expect(rows.map(\.agentId) == [headlessAgent, boundAgent],
           "P2A.8 real path: both agents project rows, attention first — measured \(rows.map { $0.agentId.uuidString })")
    expect(rows.first(where: { $0.agentId == headlessAgent })?.tileId == nil,
           "P2A.8 real path: the headless row carries no tile, so the phone hides Show on canvas")

    // The one tile-keyed consumer left on this path: a headless agent must not appear in
    // it, and a bound one must appear under its TILE, not under its agent id.
    let statuses = await receiver.agentStatusesByTileId()
    expect(statuses == [boundTile: .working],
           "P2A.8 real path: agentStatusesByTileId projects through the hint only — measured \(statuses.map { "\($0.key.uuidString):\($0.value.rawValue)" }.sorted())")

    // The approval an operator would answer is addressed by the AGENT — which is the only
    // way a headless agent's approval can be answered at all.
    let target = snapshot.byAgent[headlessAgent].flatMap { AgentsBoardProjection.respondableRequest(in: $0) }
    expect(target == ApprovalResponseTarget(agentId: headlessAgent, approvalRequestId: "approval-headless"),
           "P2A.8 real path: a headless agent's approval is respondable, addressed by agent id")

    print("P2A.8 real path measured rows=\(rows.map { "\($0.agentId.uuidString.prefix(8)):\($0.tileId?.uuidString.prefix(8) ?? "none")" }.joined(separator: ",")) tileKeyedStatuses=\(statuses.count)")

    await sender.stop()
    await receiver.stop()
}

func runActivityProjectionChecks() async throws {
    await checkFreshReceiverSubscribeWaitsForRemoteActivity()
    await checkSnapshotThenTailIsGapFree()
    await checkGapDetectionTriggersReplay()
    await checkFreshReceiverResumeFromPersistedCursorIsIncremental()
    await checkSharedDemuxRegistersBeforeSend()
    await checkScopeGuardBlocksUnauthorizedSubscription()
    checkActivityStreamItemNoForbiddenFields()
    await checkGapRetryExhaustionFallsBackToColdReconnect()
    let backendElapsedMs = await runActivityProjectionBackendCheck()
    await checkAgentsBoardProjectionOverFakeSyncTransportRealPath()
    await checkAgentKeyedProjectionOverRealPath()
    await checkApprovalResponderOverFakeSyncTransportRealPath()

    let manifest = InvariantManifest(
        invariantId: "ticket58-activity-projection-transport",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date()),
        measurements: ["backend_gapfill_elapsed_ms": .double(backendElapsedMs)],
        outcome: InvariantOutcome.pass.rawValue,
        failureReason: nil
    )
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("continuum-\(manifest.invariantId)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try InvariantManifestWriter.write(manifest, to: tmpDir)
    let file = tmpDir.appendingPathComponent("invariant-\(manifest.invariantId)-\(manifest.runId).json")
    let readBack = try JSONDecoder().decode(InvariantManifest.self, from: Data(contentsOf: file))
    expect(readBack == manifest, "ticket58 manifest round-trips")

    print("ContinuumRevivedSyncChecks passed: activity projection over sync transport — snapshot-then-tail, cursor resume, replay, shared demux registration, sender-bound scope, I5, bounded retry, deterministic backend (\(String(format: "%.2f", backendElapsedMs)) ms), manifest at \(file.path)")
}
