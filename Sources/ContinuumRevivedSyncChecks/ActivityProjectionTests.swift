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

private func makeDraft(
    tileId: UUID,
    tone: ActivityEventTone = .info,
    status: AgentStatus,
    summary: String = "activity"
) -> AgentActivityEventDraft {
    AgentActivityEventDraft(
        tileId: tileId,
        runId: nil,
        tone: tone,
        kind: "status",
        status: status,
        summary: summary,
        occurredAt: Date(timeIntervalSinceReferenceDate: 100)
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
    expect(wireSnapshot.byTile[tileId]?.status == .working, "snapshot-then-tail: status projected")
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
    expect(finalSnapshot.byTile[tileId]?.status == .done, "gap detection: final status is done")
    expect(finalSnapshot.byTile[tileId]?.recent.count == 3, "gap detection: no double-application")

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
    expect(finalSnapshot.byTile[tileId]?.recent.map(\.sequence) == [1, 2, 3, 4], "cursor resume: final snapshot has the full folded activity history")

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

    let baseline = ActivityLogSnapshot(snapshotSequence: 1, snapshotReplicaId: replicaId, byTile: [
        tileId: TileActivity(status: .working, lastSummary: "s", recent: [], updatedAt: Date())
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
    expect(receiverStatuses == storeSnapshot.byTile.mapValues(\.status), "backend: status map matches")
    expect(receiverStatuses[tileIds[2]] == .done, "backend: final status is done")
    let recentCount = backendReceiverSnapshot.byTile[tileIds[2]]?.recent.count
    expect(recentCount == statusesForLastTile.count, "backend: no double-application")
    expect(elapsedMs < 100, "backend: completes within 100ms, got \(elapsedMs)")

    await sender.stop()
    await receiver.stop()
    return elapsedMs
}

func runActivityProjectionChecks() async throws {
    await checkSnapshotThenTailIsGapFree()
    await checkGapDetectionTriggersReplay()
    await checkFreshReceiverResumeFromPersistedCursorIsIncremental()
    await checkSharedDemuxRegistersBeforeSend()
    await checkScopeGuardBlocksUnauthorizedSubscription()
    checkActivityStreamItemNoForbiddenFields()
    await checkGapRetryExhaustionFallsBackToColdReconnect()
    let backendElapsedMs = await runActivityProjectionBackendCheck()

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
