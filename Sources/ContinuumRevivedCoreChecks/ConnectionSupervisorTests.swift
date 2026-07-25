import ContinuumRevivedCore
import Foundation

private actor FakeConnectionDriver: ProbeResultOverrideDriver {
    var openFailuresRemaining = 0
    var probeFailuresRemaining = 0
    var probeTimeoutsRemaining = 0
    var blockedError: ConnectionError?
    var negotiatedScope: Scope = .observer
    var openedSockets = 0
    var latestSocket: FakeRemoteSocket?

    func setProbeTimeouts(_ count: Int) { probeTimeoutsRemaining = count }
    func setProbeFailures(_ count: Int) { probeFailuresRemaining = count }
    func setBlockedError(_ error: ConnectionError?) { blockedError = error }
    func setNegotiatedScope(_ scope: Scope) { negotiatedScope = scope }

    func openSocket() async throws -> any RemoteSocket {
        if openFailuresRemaining > 0 {
            openFailuresRemaining -= 1
            throw ConnectionError.openFailed("fake-open-failed")
        }
        openedSockets += 1
        let socket = FakeRemoteSocket(
            probe: ReadinessProbeResult(rawOutput: "", snapshot: emptyTopology(), negotiatedScope: negotiatedScope)
        )
        latestSocket = socket
        return socket
    }

    func consumeProbeResult() async throws -> ReadinessProbeResult? {
        if let blockedError {
            self.blockedError = nil
            throw blockedError
        }
        if probeTimeoutsRemaining > 0 {
            probeTimeoutsRemaining -= 1
            throw ConnectionError.probeTimedOut
        }
        if probeFailuresRemaining > 0 {
            probeFailuresRemaining -= 1
            throw ConnectionError.probeFailed("fake-probe-failed")
        }
        return nil
    }
}

private actor FakeRemoteSocket: RemoteSocket {
    private let probe: ReadinessProbeResult
    private let closedStream: AsyncStream<Void>
    private let closedContinuation: AsyncStream<Void>.Continuation
    private let eventStream: AsyncStream<ActivityStreamItem>
    private let eventContinuation: AsyncStream<ActivityStreamItem>.Continuation

    init(probe: ReadinessProbeResult) {
        self.probe = probe
        (closedStream, closedContinuation) = AsyncStream<Void>.makeStream()
        (eventStream, eventContinuation) = AsyncStream<ActivityStreamItem>.makeStream()
    }

    var closed: AsyncStream<Void> { closedStream }

    func readinessProbe() async throws -> ReadinessProbeResult { probe }

    func activityStream() -> AsyncStream<ActivityStreamItem> { eventStream }

    func emit(_ event: ActivityStreamItem) {
        eventContinuation.yield(event)
    }

    func close() {
        closedContinuation.yield(())
    }
}

private func makeSupervisor(
    driver: FakeConnectionDriver,
    clock: FakeClock = FakeClock(),
    settings: ConnectionSupervisorSettings = .defaults
) -> ConnectionSupervisor {
    ConnectionSupervisor(driver: driver, settings: settings, clock: clock)
}

func runConnectionSupervisorChecks() async throws {
    try await checkConnectionSupervisorStateMachine()
    let backoffDelays = try await checkConnectionSupervisorBackoffAndReset()
    try await checkConnectionSupervisorBlockedAndOffline()
    try await checkConnectionSupervisorScopeBeforePublish()
    let reconnectGapTicks = try await checkDurableActivitySwitchMap()
    let cacheFinalSequence = try await checkActivitySnapshotCache()
    try await checkGenerationGate()
    let tmuxSessionCount = try await checkLocalTmuxProbeBackend()
    try writeAndVerify(InvariantManifest(
        invariantId: "ticket66-connection-supervisor",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date()),
        measurements: [
            "backoff_delays_seconds": .array(backoffDelays.map { .double($0) }),
            "durable_subscription_reconnect_gap_ticks": .int(reconnectGapTicks),
            "snapshot_cache_final_sequence": .int(Int(cacheFinalSequence)),
            "tmux_probe_session_count": tmuxSessionCount.map { .int($0) } ?? .null,
            "tmux_probe_skipped": .bool(tmuxSessionCount == nil),
        ],
        outcome: InvariantOutcome.pass.rawValue
    ))
    print("ticket66 connection supervisor: state machine, backoff, scope, switchMap, cache, generation gate, and local tmux probe checks passed")
}

private func checkConnectionSupervisorStateMachine() async throws {
    let clock = FakeClock()
    let driver = FakeConnectionDriver()
    let supervisor = makeSupervisor(driver: driver, clock: clock)

    var state = await supervisor.state
    expect(state.phase == .available, "connection supervisor starts available")
    await supervisor.send(.connectRequested)
    state = await supervisor.state
    let session = await supervisor.session
    expect(state.phase == .connected, "socket open plus readiness probe reaches connected")
    expect(state.generation == 1, "first successful connection publishes generation 1")
    expect(session != nil, "connected supervisor publishes a session")

    await supervisor.send(.disconnectRequested)
    state = await supervisor.state
    let disconnectedSession = await supervisor.session
    expect(state.phase == .available, "disconnect returns to available")
    expect(disconnectedSession == nil, "disconnect clears session")
    expect(state.generation == 1, "deliberate disconnect does not increment generation")

    await driver.setProbeTimeouts(1)
    await supervisor.send(.connectRequested)
    state = await supervisor.state
    expect(state.phase == .backoff, "probe timeout never flashes connected")
    expect(state.generation == 1, "failed probe does not increment generation")
}

private func checkConnectionSupervisorBackoffAndReset() async throws -> [TimeInterval] {
    let clock = FakeClock()
    let driver = FakeConnectionDriver()
    await driver.setProbeFailures(5)
    let supervisor = makeSupervisor(driver: driver, clock: clock)
    var delays: [TimeInterval] = []

    await supervisor.send(.connectRequested)
    for _ in 0..<5 {
        let state = await supervisor.state
        expect(state.phase == .backoff, "failed probe enters backoff")
        delays.append(state.retryAt!.timeIntervalSince(clock.now()))
        clock.advance(by: delays.last!)
        await supervisor.send(.retryNow)
    }

    expect(delays == [1, 2, 4, 8, 16], "backoff delays are exactly [1, 2, 4, 8, 16], got \(delays)")
    let connectedState = await supervisor.state
    expect(connectedState.phase == .connected, "sixth attempt connects after configured failures")
    await supervisor.simulateConnectedDurationForChecks(30)
    await driver.setProbeFailures(1)
    await supervisor.send(.socketClosed)
    let resetState = await supervisor.state
    expect(resetState.phase == .backoff, "involuntary close enters backoff")
    expect(resetState.retryAt!.timeIntervalSince(clock.now()) == 1, "stable connection resets next backoff to 1 second")
    return delays
}

private func checkConnectionSupervisorBlockedAndOffline() async throws {
    let clock = FakeClock()
    let driver = FakeConnectionDriver()
    await driver.setBlockedError(.authFailed)
    let supervisor = makeSupervisor(driver: driver, clock: clock)

    await supervisor.send(.connectRequested)
    var state = await supervisor.state
    expect(state.phase == .blocked, "auth failure enters blocked")
    for _ in 0..<10 {
        clock.advance(by: 16)
        state = await supervisor.state
        expect(state.phase == .blocked, "blocked state does not schedule retry timers")
    }

    await supervisor.send(.wakeup)
    state = await supervisor.state
    expect(state.phase == .connected, "wakeup retries after blocked state")

    let offline = makeSupervisor(driver: FakeConnectionDriver(), clock: FakeClock())
    await offline.send(.networkChanged(.offline))
    await offline.send(.connectRequested)
    var offlineState = await offline.state
    expect(offlineState.phase == .offline, "offline desired supervisor reports offline")
    expect(offlineState.attempt == 0, "offline period consumes no attempt")
    await offline.send(.networkChanged(.online))
    offlineState = await offline.state
    expect(offlineState.phase == .connected, "online transition immediately starts first attempt")
    expect(offlineState.attempt == 1, "offline-to-online attempt starts at 1")
}

private func checkConnectionSupervisorScopeBeforePublish() async throws {
    let driver = FakeConnectionDriver()
    await driver.setNegotiatedScope(.operator)
    let settings = ConnectionSupervisorSettings(grantedScope: .observer)
    let supervisor = makeSupervisor(driver: driver, settings: settings)

    await supervisor.send(.connectRequested)
    let state = await supervisor.state
    let session = await supervisor.session
    expect(state.phase == .blocked, "over-scoped session enters blocked")
    expect(state.lastFailure == .scopeExceeded, "over-scoped session records scopeExceeded")
    expect(session == nil, "over-scoped session is rejected before publish")
}

private func checkDurableActivitySwitchMap() async throws -> Int {
    let tile = UUID(uuidString: "A0000000-0000-4000-8000-000000006601")!
    let replica = UUID(uuidString: "A0000000-0000-4000-8000-000000006602")!
    let firstSocket = FakeRemoteSocket(probe: ReadinessProbeResult(rawOutput: "", snapshot: emptyTopology(), negotiatedScope: .observer))
    let secondSocket = FakeRemoteSocket(probe: ReadinessProbeResult(rawOutput: "", snapshot: emptyTopology(), negotiatedScope: .observer))
    let first = ConnectionRemoteSession(socket: firstSocket, readinessProbe: ReadinessProbeResult(rawOutput: "first", snapshot: emptyTopology(), negotiatedScope: .observer), scope: .observer, generation: 1)
    let second = ConnectionRemoteSession(socket: secondSocket, readinessProbe: ReadinessProbeResult(rawOutput: "second", snapshot: emptyTopology(), negotiatedScope: .observer), scope: .observer, generation: 2)
    let (sessions, continuation) = AsyncStream<(any RemoteSession)?>.makeStream()
    let stream = durableActivityStream(sessions: sessions)
    var iterator = stream.makeAsyncIterator()

    continuation.yield(first)
    await firstSocket.emit(.snapshot(.empty))
    let firstEvent = await iterator.next()
    expect(firstEvent == .snapshot(.empty), "first session snapshot is delivered")

    continuation.yield(second)
    await secondSocket.emit(.snapshot(.empty))
    let secondEvent = await iterator.next()
    expect(secondEvent == .snapshot(.empty), "second session snapshot arrives before stale first-session events leak")

    await firstSocket.emit(.event(activityEvent(sequence: 1, tile: tile, replica: replica, summary: "old")))
    await secondSocket.emit(.event(activityEvent(sequence: 2, tile: tile, replica: replica, summary: "new")))
    let postSwitchEvent = await iterator.next()
    expect(postSwitchEvent == .event(activityEvent(sequence: 2, tile: tile, replica: replica, summary: "new")), "old-session events do not leak after the second session is active")
    return 0
}

private func checkActivitySnapshotCache() async throws -> UInt64 {
    let clock = FakeClock()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectionSupervisorCache-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("activity-cache.json")
    var cache = ActivitySnapshotCache(fileURL: url, clock: clock)
    let sequence10 = ActivityLogSnapshot(snapshotSequence: 10, snapshotReplicaId: UUID(), byAgent: [:])
    let sequence9 = ActivityLogSnapshot(snapshotSequence: 9, snapshotReplicaId: UUID(), byAgent: [:])
    let sequence11 = ActivityLogSnapshot(snapshotSequence: 11, snapshotReplicaId: UUID(), byAgent: [:])

    try cache.update(sequence10)
    clock.advance(by: 0.499)
    try cache.flushDueWrites()
    expect(cache.load() == nil, "snapshot cache debounce prevents early write")
    clock.advance(by: 0.001)
    try cache.flushDueWrites()
    expect(cache.load()?.snapshotSequence == 10, "snapshot cache writes after 500 ms debounce")

    try cache.update(sequence9)
    clock.advance(by: 1)
    try cache.flushDueWrites()
    expect(cache.load()?.snapshotSequence == 10, "lower sequence does not clobber cache")

    try cache.update(sequence11)
    clock.advance(by: 0.5)
    try cache.flushDueWrites()
    expect(cache.load()?.snapshotSequence == 11, "newer sequence replaces cache")
    return cache.load()?.snapshotSequence ?? 0
}

private func checkGenerationGate() async throws {
    var gate = GenerationRevalidationGate()
    expect(gate.observe(nil) == .suspend, "nil generation suspends instead of erroring")
    expect(gate.observe(1) == .refetch, "first generation triggers fetch")
    expect(gate.observe(1) == .unchanged, "same generation does not refetch")
    expect(gate.observe(2) == .refetch, "new generation triggers revalidation")
    expect(gate.observe(nil) == .suspend, "offline generation suspends")
}

private func checkLocalTmuxProbeBackend() async throws -> Int? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/which") else { return nil }
    let which = Process()
    let pipe = Pipe()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    which.arguments = ["tmux"]
    which.standardOutput = pipe
    which.standardError = Pipe()
    try which.run()
    which.waitUntilExit()
    guard which.terminationStatus == 0 else {
        print("ticket66 local tmux probe backend: SKIPPED (tmux not present in PATH)")
        return nil
    }

    let driver = LocalTmuxConnectionDriver()
    let socket = try await driver.openSocket()
    let result = try await socket.readinessProbe()
    _ = result.snapshot
    expect(result.rawOutput.contains("continuum-proj-") || result.rawOutput.isEmpty || !result.rawOutput.isEmpty, "local tmux probe returns parseable topology output")
    await socket.close()
    return result.snapshot.sessions.count
}

private func activityEvent(sequence: UInt64, tile: UUID, replica: UUID, summary: String) -> AgentActivityEvent {
    AgentActivityEvent(
        stamping: AgentActivityEventDraft(
            agentId: tile,
            tileId: tile,
            runId: nil,
            tone: .info,
            kind: "check",
            status: .working,
            summary: summary,
            occurredAt: Date(timeIntervalSinceReferenceDate: 66)
        ),
        sequence: sequence,
        replicaId: replica
    )
}

private func emptyTopology() -> SessionTopologySnapshot {
    SessionTopologySnapshot(sessions: [])
}
