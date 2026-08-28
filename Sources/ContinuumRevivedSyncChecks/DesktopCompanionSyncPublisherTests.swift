import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

private actor ScriptedSyncTransport: ContinuumRevivedSync.SyncTransport {
    let inbound: AsyncStream<SyncMessage>
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private var sentMessages: [SyncMessage] = []

    init() {
        (inbound, inboundContinuation) = AsyncStream<SyncMessage>.makeStream()
        let (states, stateContinuation) = AsyncStream<ContinuumRevivedSync.ConnectionState>.makeStream()
        stateContinuation.yield(.connected)
        connectionState = states
    }

    func send(_ message: SyncMessage) async throws {
        sentMessages.append(message)
    }

    func pushInbound(_ message: SyncMessage) {
        inboundContinuation.yield(message)
    }

    func sent() -> [SyncMessage] {
        sentMessages
    }
}

private actor RecordingFreshnessSink: CompanionLifecycleHintPublishing {
    private(set) var heartbeats: [CompanionFreshnessMetadata] = []
    private(set) var powerHints: [(CompanionDesktopPowerHint, CompanionFreshnessMetadata)] = []

    func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws {
        heartbeats.append(metadata)
    }

    func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws {
        powerHints.append((hint, metadata))
    }

    func heartbeatRecords() -> [CompanionFreshnessMetadata] {
        heartbeats
    }
}

private actor FetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func ticket75Pairing(
    scope: Scope = .operator,
    instanceId: UUID = UUID(uuidString: "75000000-0000-4000-8000-000000000001")!
) -> DesktopCompanionPairingSnapshot {
    DesktopCompanionPairingSnapshot(
        instanceId: instanceId,
        pairedDeviceCount: 1,
        authorizedScope: scope
    )
}

private func ticket75CanvasFixture() -> (CanvasState, WorkspaceDocument) {
    let tileId = UUID(uuidString: "75000000-0000-4000-8000-0000000000A1")!
    let zoneId = UUID(uuidString: "75000000-0000-4000-8000-0000000000B1")!
    let projectId = UUID(uuidString: "75000000-0000-4000-8000-0000000000C1")!
    let canvas = CanvasState(
        viewport: CanvasViewport(x: 99, y: 101, zoom: 0.5),
        tiles: [
            Tile(
                id: tileId,
                kind: .terminal,
                title: "Agent tile",
                frame: TileFrame(x: 10, y: 20, width: 300, height: 200),
                zPosition: FracIndex(value: 0.4),
                zoneId: zoneId,
                runtimeRef: RuntimeRef(kind: .terminalSession, id: UUID(uuidString: "75000000-0000-4000-8000-0000000000D1")!),
                metadata: TileMetadata(projectRelativeCwd: "private/local/path")
            )
        ],
        groups: [],
        lastActiveTileId: tileId
    )
    let workspace = WorkspaceDocument(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        zones: [
            ZonePlacement(
                zoneId: zoneId,
                projectId: projectId,
                origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 640, height: 480),
                color: "mint",
                collapsed: false,
                hydrationPolicy: .automatic,
                name: "Dogfood",
                navKey: nil,
                zPosition: FracIndex(value: 0.3)
            )
        ],
        lastActiveZoneId: zoneId
    )
    return (canvas, workspace)
}

private func checkCompanionContainerConfigAgreement() throws {
    let expected = CompanionSyncConfig.cloudKitContainerIdentifier
    expect(expected == "iCloud.dev.dylanreedx.continuum", "ticket75 config: selected dogfood container is the installed iOS container")

    let desktopEntitlements = try String(
        contentsOfFile: "Sources/ContinuumRevived/ContinuumRevived.entitlements",
        encoding: .utf8
    )
    let iosEntitlements = try String(
        contentsOfFile: "ios/Continuum/Resources/Continuum.entitlements",
        encoding: .utf8
    )
    let iosSource = try String(contentsOfFile: "ios/Continuum/Sources/ContinuumApp.swift", encoding: .utf8)
    let systemSurfaceSource = try String(contentsOfFile: "ios/Continuum/Sources/SystemSurfaceCoordinator.swift", encoding: .utf8)

    expect(desktopEntitlements.contains("<string>\(expected)</string>"), "ticket75 config: desktop entitlements use shared CloudKit container \(expected)")
    expect(iosEntitlements.contains("<string>\(expected)</string>"), "ticket75 config: iOS entitlements use shared CloudKit container \(expected)")
    expect(iosSource.contains("CompanionSyncConfig.cloudKitContainerIdentifier"), "ticket75 config: iOS source reads shared CloudKit config, not a local identity/authority string")

    guard let loaderStart = iosSource.range(of: "private struct LoadingBoardView"),
          let loaderEnd = iosSource.range(of: "private struct PairingRequiredView", range: loaderStart.upperBound..<iosSource.endIndex) else {
        throw NSError(domain: "CompanionIOSSourceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "iOS loading board source boundary missing"])
    }
    let loaderSource = String(iosSource[loaderStart.lowerBound..<loaderEnd.lowerBound])
    expect(loaderSource.contains("DualPlaneGyroIndicator(isActive: true)"), "iOS home loading board uses the branded continuously animated gyro")
    expect(!loaderSource.contains("ProgressView("), "iOS home loading board does not regress to the generic progress spinner")
    expect(loaderSource.contains(".accessibilityLabel(\"Array is connecting\")"), "iOS home gyro exposes an honest loading accessibility label")
    expect(systemSurfaceSource.contains("if #available(iOS 17.2, *)"), "iOS guards ActivityKit push-to-start observation at its runtime availability")
    expect(systemSurfaceSource.contains("Activity<ArrayAgentActivityAttributes>.pushToStartTokenUpdates"), "iOS observes the ActivityKit push-to-start token stream")
    expect(systemSurfaceSource.contains("kind: .liveActivityStart"), "iOS registers push-to-start separately from per-activity update tokens")
}

private func checkDesktopActivitySnapshotIsSanitized() throws {
    let now = Date(timeIntervalSinceReferenceDate: 750)
    let tileId = UUID(uuidString: "75000000-0000-4000-8000-0000000000E1")!
    let descriptor = TerminalSessionDescriptor(
        id: UUID(uuidString: "75000000-0000-4000-8000-0000000000E2")!,
        tileId: tileId,
        launchProfileId: "claude",
        command: "/Users/dylan/private/bin/claude",
        args: ["--danger", "pane=%55", "pid=123"],
        cwd: "/Users/dylan/Documents/private/repo",
        env: ["SECRET_TOKEN": "raw-apns-token"],
        title: "pane %55 /Users/dylan/Documents/private/repo pid 123",
        createdAt: now,
        lastStartedAt: now,
        lastExit: nil,
        agentDescriptor: AgentDescriptor(
            agentKind: .claude,
            worktreePath: "/Users/dylan/Documents/private/repo",
            status: .working,
            statusUpdatedAt: now,
            runId: "local-run-id"
        ),
        scrollback: "transcript body /Users/dylan secret raw-apns-token"
    )

    let managedTileId = UUID(uuidString: "75000000-0000-4000-8000-0000000000E4")!
    // P2A.8: the aggregate key is the AGENT's, deliberately different from its tile id
    // here so a row keyed by the tile would be caught.
    let managedAgentId = UUID(uuidString: "75000000-0000-4000-8000-0000000000A4")!
    let snapshot = DegradedDesktopActivitySnapshotSource.snapshot(
        descriptors: [descriptor],
        liveStatuses: [tileId: .needsAttention],
        managedAgents: [DesktopManagedAgentActivity(agentId: managedAgentId, tileId: managedTileId, agentKind: .managed, status: .idle, updatedAt: now)],
        replicaId: UUID(uuidString: "75000000-0000-4000-8000-0000000000E3")!,
        now: now
    )

    expect(snapshot.byAgent[tileId]?.status == .needsAttention, "ticket75 activity: live status overrides persisted degraded descriptor status")
    expect(snapshot.byAgent[tileId]?.lastSummary == "Claude needs attention", "ticket75 activity: summary is short safe status copy")
    expect(snapshot.byAgent[managedAgentId]?.status == .idle, "ticket85 activity: managed-agent rows are included in the sanitized desktop snapshot")
    expect(snapshot.byAgent[managedAgentId]?.lastSummary == "Managed agent idle", "ticket85 activity: managed-agent summary is short safe status copy")

    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    for forbidden in ["/Users/", "private/repo", "SECRET_TOKEN", "raw-apns-token", "transcript body", "pane", "pid", "local-run-id"] {
        expect(!json.contains(forbidden), "ticket75 activity I5: degraded snapshot must not leak \(forbidden)")
    }

    // 88.4c: a managed agent's REAL timeline — built via ManagedAgentActivityBridge
    // from the runtime event stream — folds into the published snapshot's `recent`
    // (in canonical order), so the phone shows what the agent is doing, not just a
    // status badge. Content deltas are dropped and the payload stays I5-clean.
    let timelineTile = UUID(uuidString: "75000000-0000-4000-8000-0000000000E5")!
    let timelineAgent = UUID(uuidString: "75000000-0000-4000-8000-0000000000A5")!
    let events: [AgentRuntimeEvent] = [
        .turnStarted(threadId: "t", turnId: "t1"),
        .itemStarted(threadId: "t", itemId: "c1", kind: .commandExecution, title: "read"),
        .itemCompleted(threadId: "t", itemId: "c1", kind: .commandExecution, status: .completed),
        .contentDelta(threadId: "t", turnId: "t1", streamKind: .assistant, delta: "SECRET assistant body /Users/dylan"),
        .turnCompleted(threadId: "t", turnId: "t1", outcome: .completed, errorMessage: nil),
    ]
    let drafts = events.compactMap {
        ManagedAgentActivityBridge.draft(for: $0, agentId: timelineAgent, tileId: timelineTile, status: .working, now: now)
    }
    let timelineSnapshot = DegradedDesktopActivitySnapshotSource.snapshot(
        descriptors: [],
        liveStatuses: [:],
        managedAgents: [DesktopManagedAgentActivity(
            agentId: timelineAgent, tileId: timelineTile, agentKind: .managed, status: .working,
            updatedAt: now, recentEvents: drafts)],
        replicaId: UUID(uuidString: "75000000-0000-4000-8000-0000000000E6")!,
        now: now
    )
    let recentKinds = timelineSnapshot.byAgent[timelineAgent]?.recent.map(\.kind) ?? []
    expect(timelineSnapshot.byAgent[timelineTile] == nil && timelineSnapshot.byAgent[timelineAgent] != nil,
           "P2A.8: the published snapshot is keyed by agent id, not by the tile rendering it")
    expect(timelineSnapshot.byAgent[timelineAgent]?.tileId == timelineTile,
           "P2A.8: the tile rides along as the view hint")
    expect(recentKinds == ["turn.started", "tool.read", "tool.completed", "turn.completed"],
           "88.4c: managed timeline folds into snapshot.recent in order, content delta dropped — got \(recentKinds)")
    let timelineJson = String(decoding: try JSONEncoder().encode(SyncMessage.activity(.snapshot(timelineSnapshot))), as: UTF8.self)
    expect(SyncPayloadTaint.violations(inEncodedJSON: timelineJson).isEmpty,
           "88.4c I5: managed timeline crossing the wire is taint-clean")
    expect(!timelineJson.contains("SECRET assistant body") && !timelineJson.contains("/Users/dylan"),
           "88.4c I5: assistant/content text never rides the activity timeline")
}

private func checkDesktopSpatialBootstrapDeterminism() throws {
    let (canvas, workspace) = ticket75CanvasFixture()
    let replicaId = UUID(uuidString: "75000000-0000-4000-8000-0000000000F1")!
    let first = DesktopSpatialBootstrap.snapshot(canvasState: canvas, workspaceDocument: workspace, replicaId: replicaId)
    let second = DesktopSpatialBootstrap.snapshot(canvasState: canvas, workspaceDocument: workspace, replicaId: replicaId)

    let firstBytes = try JSONCodec.makeOpLogEncoder().encode(first)
    let secondBytes = try JSONCodec.makeOpLogEncoder().encode(second)
    expect(firstBytes == secondBytes, "ticket75 spatial: bootstrap snapshot bytes are deterministic")

    let tileId = canvas.tiles[0].id
    let zoneId = workspace.zones[0].zoneId
    let state = first.state
    expect(state.canvasState.tiles.first?.id == tileId, "ticket75 spatial: snapshot carries tile id")
    expect(state.canvasState.tiles.first?.frame == canvas.tiles[0].frame, "ticket75 spatial: snapshot carries tile frame")
    expect(state.canvasState.tiles.first?.zoneId == zoneId, "ticket75 spatial: snapshot carries tile membership")
    expect(state.workspaceDocument.zones.first?.zoneId == zoneId, "ticket75 spatial: snapshot carries zone id")

    let json = String(decoding: firstBytes, as: UTF8.self)
    for forbidden in ["runtimeRef", "private/local/path", "/Users/", "pid", "paneTarget", "scrollback"] {
        expect(!json.contains(forbidden), "ticket75 spatial I5: bootstrap snapshot must not leak \(forbidden)")
    }
}

private func checkDesktopCompanionServiceGatingAndFreshness() async throws {
    let transport = ScriptedSyncTransport()
    let freshness = RecordingFreshnessSink()
    let (canvas, workspace) = ticket75CanvasFixture()
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let clock = FakeClock(start: now)

    let service = DesktopCompanionSyncService(
        configuration: DesktopCompanionSyncConfiguration(
            containerIdentifier: CompanionSyncConfig.cloudKitContainerIdentifier,
            desktopBundleIdentifier: "dev.dylanreed.continuum.mac",
            iosBundleIdentifier: "dev.dylanreedx.continuum",
            signedWithICloudEntitlement: false
        ),
        transport: transport,
        pairingSnapshot: { DesktopCompanionPairingSnapshot.unpaired(instanceId: UUID(uuidString: "75000000-0000-4000-8000-000000000001")!) },
        canvasSnapshot: { (canvas, workspace) },
        activitySnapshot: { ActivityLogSnapshot.empty },
        freshnessPublisher: freshness,
        clock: clock
    )

    try await service.start()
    try await service.publishCurrentDesktopSnapshot(reason: .manual)
    var diagnostics = await service.diagnostics
    expect(diagnostics.isPaired == false, "ticket75 service: unpaired desktop publisher stays gated")
    expect(diagnostics.lastError == "Pair a companion before publishing", "ticket75 service: unpaired diagnostic is explicit")
    let unpairedHeartbeats = await freshness.heartbeatRecords()
    expect(unpairedHeartbeats.isEmpty, "ticket75 service: unpaired start does not publish heartbeat")
    let unpairedSent = await transport.sent()
    expect(unpairedSent.isEmpty, "ticket75 service: unpaired publish sends no transport messages")

    await service.updatePairingSnapshot(ticket75Pairing())
    try await service.start()
    try await service.publishCurrentDesktopSnapshot(reason: .manual)
    diagnostics = await service.diagnostics
    expect(diagnostics.isPaired, "ticket75 service: paired desktop publisher starts")
    expect(diagnostics.transportIsPairingProof == false, "ticket75 service: diagnostics state CloudKit transport is not pairing proof")
    expect(diagnostics.lastSpatialPublishAt == now, "ticket75 service: spatial publish timestamp recorded")
    expect(diagnostics.lastActivityPublishAt == now, "ticket75 service: activity publish timestamp recorded")

    let heartbeats = await freshness.heartbeatRecords()
    expect(heartbeats.count == 2, "ticket75 service: paired start and manual publish each publish heartbeat metadata")
    let latestHeartbeat = heartbeats.last
    expect(latestHeartbeat?.instanceId == ticket75Pairing().instanceId, "ticket75 service: heartbeat is bound to paired Continuum instance")
    expect(latestHeartbeat?.spatialWatermark != nil, "ticket75 service: heartbeat carries spatial freshness watermark")
    expect(latestHeartbeat?.activityWatermark != nil, "ticket75 service: heartbeat carries activity freshness watermark")

    let sent = await transport.sent()
    expect(sent.contains { if case .snapshot = $0 { return true } else { return false } }, "ticket75 service: paired manual publish sends spatial snapshot")
    expect(sent.contains { if case .activity(.snapshot) = $0 { return true } else { return false } }, "ticket75 service: paired manual publish sends activity snapshot")
}

private func checkHostedRelayPairingProjection() {
    let instanceID = UUID(uuidString: "75000000-0000-4000-8000-0000000000F1")!
    let unpaired = DesktopCompanionPairingSnapshot.hostedRelay(
        instanceId: instanceID, pairedDeviceCount: 0)
    expect(!unpaired.isPaired, "hosted relay pairing: zero relay devices stays unpaired")
    expect(unpaired.authorizedScope.isEmpty, "hosted relay pairing: zero relay devices grants no authority")

    let paired = DesktopCompanionPairingSnapshot.hostedRelay(
        instanceId: instanceID, pairedDeviceCount: 2)
    expect(paired.isPaired, "hosted relay pairing: relay devices unlock desktop publishing")
    expect(paired.instanceId == instanceID, "hosted relay pairing: relay instance identity is preserved")
    expect(paired.authorizedScope == .companionControl,
           "hosted relay pairing: server-fixed companion profile is preserved")
    expect(!paired.authorizedScope.contains(.terminalOperate),
           "hosted relay pairing: hosted phones never gain terminal authority")
}

private func checkDesktopCompanionFakeTransportFetchAndApprovalAck() async throws {
    let transport = ScriptedSyncTransport()
    let freshness = RecordingFreshnessSink()
    let fetchCounter = FetchCounter()
    let (canvas, workspace) = ticket75CanvasFixture()
    let requestId = "approval-750"

    let service = DesktopCompanionSyncService(
        configuration: DesktopCompanionSyncConfiguration(containerIdentifier: CompanionSyncConfig.cloudKitContainerIdentifier),
        transport: transport,
        pairingSnapshot: { ticket75Pairing(scope: .operator) },
        canvasSnapshot: { (canvas, workspace) },
        activitySnapshot: { ActivityLogSnapshot.empty },
        freshnessPublisher: freshness,
        fetchChanges: {
            await fetchCounter.increment()
            await transport.pushInbound(.approvalResponse(ApprovalResponseRequest(agentId: canvas.tiles[0].id, requestId: requestId, decision: .accept)))
        },
        clock: FakeClock(start: Date(timeIntervalSinceReferenceDate: 1_100))
    )

    try await service.start()
    try await service.fetchChanges(reason: .manual)
    let ackArrived = await waitUntil(timeoutSeconds: 2) {
        await transport.sent().contains {
            if case .approvalResponseAck(let ack) = $0 {
                return ack.requestId == requestId && ack.outcome == .unknownRequest
            }
            return false
        }
    }
    let fetchCount = await fetchCounter.count
    expect(fetchCount == 1, "ticket75 service: manual fetch invokes the transport fetch hook")
    expect(ackArrived, "ticket75 service: inbound approval response gets terminal unknownRequest ack before managed resolver exists")

    let diagnostics = await service.diagnostics
    expect(diagnostics.lastFetchAt != nil, "ticket75 service: diagnostics record manual fetch")
    expect(diagnostics.lastApprovalResponseOutcome == .unknownRequest, "ticket75 service: diagnostics record approval ack outcome")
}

private func waitUntil(timeoutSeconds: Double, condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

func runDesktopCompanionSyncPublisherChecks() async throws {
    try checkCompanionContainerConfigAgreement()
    try checkDesktopActivitySnapshotIsSanitized()
    try checkDesktopSpatialBootstrapDeterminism()
    checkHostedRelayPairingProjection()
    try await checkDesktopCompanionServiceGatingAndFreshness()
    try await checkDesktopCompanionFakeTransportFetchAndApprovalAck()
    print("desktop companion sync publisher: container agreement, I5-safe degraded activity, deterministic spatial bootstrap, paired gate/freshness heartbeat, fake-transport publish/fetch/approval ack all green")
}
