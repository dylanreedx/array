import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

public struct DesktopCompanionSyncConfiguration: Equatable, Sendable {
    public var containerIdentifier: String
    public var desktopBundleIdentifier: String
    public var iosBundleIdentifier: String
    public var signedWithICloudEntitlement: Bool

    public init(
        containerIdentifier: String,
        desktopBundleIdentifier: String = "dev.dylanreed.continuum.mac",
        iosBundleIdentifier: String = "dev.dylanreedx.continuum",
        signedWithICloudEntitlement: Bool = false
    ) {
        self.containerIdentifier = containerIdentifier
        self.desktopBundleIdentifier = desktopBundleIdentifier
        self.iosBundleIdentifier = iosBundleIdentifier
        self.signedWithICloudEntitlement = signedWithICloudEntitlement
    }
}

public struct DesktopCompanionPairingSnapshot: Equatable, Sendable {
    public var instanceId: UUID
    public var pairedDeviceCount: Int
    public var authorizedScope: Scope

    public init(instanceId: UUID, pairedDeviceCount: Int, authorizedScope: Scope) {
        self.instanceId = instanceId
        self.pairedDeviceCount = pairedDeviceCount
        self.authorizedScope = authorizedScope
    }

    public static func unpaired(instanceId: UUID) -> DesktopCompanionPairingSnapshot {
        DesktopCompanionPairingSnapshot(instanceId: instanceId, pairedDeviceCount: 0, authorizedScope: [])
    }

    public var isPaired: Bool {
        pairedDeviceCount > 0 && authorizedScope.contains(.orchestrationRead)
    }
}

public enum DesktopCompanionPublishReason: String, Sendable {
    case startup
    case foreground
    case manual
    case timer
    case pairing
    case statusChanged
    case canvasChanged
}

public enum DesktopCompanionFetchReason: String, Sendable {
    case startup
    case foreground
    case manual
    case push
}

public struct DesktopCompanionSyncDiagnostics: Equatable, Sendable {
    public var containerIdentifier: String
    public var desktopBundleIdentifier: String
    public var iosBundleIdentifier: String
    public var signedWithICloudEntitlement: Bool
    public var transportAvailability: CompanionTransportAvailability
    public var transportIsPairingProof: Bool
    public var isPaired: Bool
    public var pairedDeviceCount: Int
    public var authorizedScope: Scope
    public var lastHeartbeatAt: Date?
    public var lastSpatialPublishAt: Date?
    public var lastActivityPublishAt: Date?
    public var lastFetchAt: Date?
    public var lastInboundMessageKind: String?
    public var lastApprovalResponseOutcome: ApprovalResponseOutcome?
    public var lastError: String?

    public init(
        containerIdentifier: String,
        desktopBundleIdentifier: String,
        iosBundleIdentifier: String,
        signedWithICloudEntitlement: Bool,
        transportAvailability: CompanionTransportAvailability = .connecting,
        transportIsPairingProof: Bool = false,
        isPaired: Bool = false,
        pairedDeviceCount: Int = 0,
        authorizedScope: Scope = [],
        lastHeartbeatAt: Date? = nil,
        lastSpatialPublishAt: Date? = nil,
        lastActivityPublishAt: Date? = nil,
        lastFetchAt: Date? = nil,
        lastInboundMessageKind: String? = nil,
        lastApprovalResponseOutcome: ApprovalResponseOutcome? = nil,
        lastError: String? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.desktopBundleIdentifier = desktopBundleIdentifier
        self.iosBundleIdentifier = iosBundleIdentifier
        self.signedWithICloudEntitlement = signedWithICloudEntitlement
        self.transportAvailability = transportAvailability
        self.transportIsPairingProof = transportIsPairingProof
        self.isPaired = isPaired
        self.pairedDeviceCount = pairedDeviceCount
        self.authorizedScope = authorizedScope
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastSpatialPublishAt = lastSpatialPublishAt
        self.lastActivityPublishAt = lastActivityPublishAt
        self.lastFetchAt = lastFetchAt
        self.lastInboundMessageKind = lastInboundMessageKind
        self.lastApprovalResponseOutcome = lastApprovalResponseOutcome
        self.lastError = lastError
    }
}

public struct DesktopManagedAgentActivity: Sendable {
    /// P2A.8 aggregate key — `AgentRecord.id.rawValue`.
    public var agentId: UUID
    /// Optional view hint: the tile rendering this agent, `nil` when headless.
    public var tileId: UUID?
    public var agentKind: AgentKind
    public var status: AgentStatus
    public var updatedAt: Date
    /// The agent's real activity timeline (turn/tool/approval/error events),
    /// built from the runtime event stream (ticket 88.4c). When present, these
    /// are folded into the snapshot's `recent` so the phone shows what the
    /// agent is doing — not just a status badge. Empty falls back to a single
    /// synthetic status event.
    public var recentEvents: [AgentActivityEventDraft]

    public init(agentId: UUID, tileId: UUID?, agentKind: AgentKind, status: AgentStatus, updatedAt: Date,
                recentEvents: [AgentActivityEventDraft] = []) {
        self.agentId = agentId
        self.tileId = tileId
        self.agentKind = agentKind
        self.status = status
        self.updatedAt = updatedAt
        self.recentEvents = recentEvents
    }
}

/// The companion path's entry point into `AgentInventory` (P2B.1).
///
/// This used to BE the fold. It is now a thin caller: the union of terminal
/// sessions and agents lives in `AgentInventory` in Core, so the desktop reads
/// the same derivation the phone is published from instead of a fifth one of
/// its own. Behaviour here is unchanged on everything
/// `DesktopCompanionSyncPublisherTests` pins (keys, statuses, summaries, tile
/// hints, timeline order, the I5 sweep); that file was deliberately not touched,
/// so it is a regression witness rather than a test rewritten to match.
public enum DegradedDesktopActivitySnapshotSource {
    public static func snapshot(
        descriptors: [TerminalSessionDescriptor],
        liveStatuses: [UUID: AgentStatus],
        managedAgents: [DesktopManagedAgentActivity] = [],
        replicaId: UUID,
        now: Date
    ) -> ActivityLogSnapshot {
        // `DesktopManagedAgentActivity` is this module's transport shape: a
        // status + kind + timeline, with no `AgentRecord` behind it (a managed
        // session the supervisor has not claimed has none — P2A.8). Project it
        // onto the record shape `AgentInventory` folds, carrying ONLY what the
        // synthetic fallback event reads: id, display label, tile hint and
        // timestamp. The host-bound fields stay empty, and must: this value is
        // one step from the sync boundary (I5).
        var statuses = liveStatuses
        var records: [AgentRecord] = []
        var activityByAgent: [AgentID: [AgentActivityEventDraft]] = [:]
        for agent in managedAgents {
            let id = AgentID(rawValue: agent.agentId)
            statuses[agent.agentId] = agent.status
            records.append(AgentRecord(
                id: id,
                // The kind's label, so the synthesised summary is the same
                // "Managed agent idle" string this fold has always published.
                displayName: AgentInventory.displayName(for: agent.agentKind),
                model: "",
                thinking: "",
                cwd: "",
                createdAt: agent.updatedAt,
                lastActivityAt: agent.updatedAt,
                tileId: agent.tileId
            ))
            activityByAgent[id, default: []].append(contentsOf: agent.recentEvents)
        }
        return AgentInventory.snapshot(
            terminalDescriptors: descriptors,
            liveStatuses: statuses,
            agents: records,
            activityByAgent: activityByAgent,
            replicaId: replicaId,
            now: now
        )
    }
}

public enum DesktopSpatialBootstrap {
    public static func snapshot(
        canvasState: CanvasState,
        workspaceDocument: WorkspaceDocument,
        replicaId: UUID
    ) -> CompactedSnapshot {
        var lamport: UInt64 = 1
        var ops: [LoggedOp] = []

        for zone in workspaceDocument.zones.sorted(by: { $0.zoneId.uuidString < $1.zoneId.uuidString }) {
            ops.append(logged(&lamport, replicaId, .createZone(
                id: zone.zoneId,
                projectId: zone.projectId,
                origin: zone.origin,
                size: zone.size,
                name: zone.name,
                color: zone.color
            )))
            ops.append(logged(&lamport, replicaId, .setZonePosition(id: zone.zoneId, position: zone.zPosition)))
            ops.append(logged(&lamport, replicaId, .setZoneCollapsed(id: zone.zoneId, collapsed: zone.collapsed)))
            ops.append(logged(&lamport, replicaId, .setZoneProjectId(id: zone.zoneId, projectId: zone.projectId)))
            ops.append(logged(&lamport, replicaId, .setZoneAutoLayoutMode(id: zone.zoneId, mode: zone.autoLayoutMode)))
        }

        for tile in canvasState.tiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            ops.append(logged(&lamport, replicaId, .createTile(
                id: tile.id,
                kind: tile.kind,
                title: tile.title,
                frame: tile.frame,
                zPosition: tile.zPosition
            )))
            if tile.zoneId != nil {
                ops.append(logged(&lamport, replicaId, .setTileZone(tileId: tile.id, zoneId: tile.zoneId)))
            }
        }

        ops.append(logged(&lamport, replicaId, .setLastActiveTile(id: canvasState.lastActiveTileId)))
        ops.append(logged(&lamport, replicaId, .setLastActiveZone(id: workspaceDocument.lastActiveZoneId)))

        return compact(log: ops, through: lamport).snapshot
    }

    private static func logged(_ lamport: inout UInt64, _ replicaId: UUID, _ op: Op) -> LoggedOp {
        defer { lamport += 1 }
        return LoggedOp(opId: OpId(lamport: lamport, replica: replicaId), op: op)
    }
}

private actor UnknownRequestApprovalSeam: ApprovalResponding {
    func respond(agentId: UUID, requestId: String, decision: ApprovalDecision) async -> ApprovalRespondResult {
        .unknownRequest
    }
}

public actor DesktopCompanionSyncService {
    public typealias PairingSnapshotProvider = @Sendable () async -> DesktopCompanionPairingSnapshot
    public typealias CanvasSnapshotProvider = @Sendable () async throws -> (CanvasState, WorkspaceDocument)
    public typealias ActivitySnapshotProvider = @Sendable () async throws -> ActivityLogSnapshot
    public typealias FetchChangesHook = @Sendable () async throws -> Void
    public typealias SubscriptionHook = @Sendable () async throws -> Void

    private let configuration: DesktopCompanionSyncConfiguration
    private let transport: any SyncTransport
    private let demux: SyncMessageDemux
    private var pairingSnapshotProvider: PairingSnapshotProvider
    private let canvasSnapshotProvider: CanvasSnapshotProvider
    private let activitySnapshotProvider: ActivitySnapshotProvider
    private let freshnessPublisher: any CompanionLifecycleHintPublishing
    private let fetchChangesHook: FetchChangesHook
    private let ensureSubscriptionHook: SubscriptionHook
    private let clock: any Clock
    private let replicaId: UUID
    private let bootId: String
    private var sequence: Int64 = 0
    private var started = false
    private var inboundTask: Task<Void, Never>?
    private var activitySender: ActivityProjectionSender?
    private var spatialSender: SpatialOpSender?
    private var approvalResponder: ApprovalResponder?
    private var activityStore: ActivityStore?
    private var spatialStore: MemorySpatialOpLogStore?

    public private(set) var diagnostics: DesktopCompanionSyncDiagnostics

    public init(
        configuration: DesktopCompanionSyncConfiguration,
        transport: any SyncTransport,
        pairingSnapshot: @escaping PairingSnapshotProvider,
        canvasSnapshot: @escaping CanvasSnapshotProvider,
        activitySnapshot: @escaping ActivitySnapshotProvider,
        freshnessPublisher: any CompanionLifecycleHintPublishing,
        fetchChanges: @escaping FetchChangesHook = {},
        ensureSubscription: @escaping SubscriptionHook = {},
        clock: any Clock = SystemClock(),
        replicaId: UUID = UUID(),
        bootId: String = UUID().uuidString
    ) {
        self.configuration = configuration
        self.transport = transport
        self.demux = SyncMessageDemux(transport: transport)
        self.pairingSnapshotProvider = pairingSnapshot
        self.canvasSnapshotProvider = canvasSnapshot
        self.activitySnapshotProvider = activitySnapshot
        self.freshnessPublisher = freshnessPublisher
        self.fetchChangesHook = fetchChanges
        self.ensureSubscriptionHook = ensureSubscription
        self.clock = clock
        self.replicaId = replicaId
        self.bootId = bootId
        self.diagnostics = DesktopCompanionSyncDiagnostics(
            containerIdentifier: configuration.containerIdentifier,
            desktopBundleIdentifier: configuration.desktopBundleIdentifier,
            iosBundleIdentifier: configuration.iosBundleIdentifier,
            signedWithICloudEntitlement: configuration.signedWithICloudEntitlement
        )
    }

    public func updatePairingSnapshot(_ snapshot: DesktopCompanionPairingSnapshot) {
        pairingSnapshotProvider = { snapshot }
        updateDiagnostics(for: snapshot)
    }

    public func start() async throws {
        let pairing = await pairingSnapshotProvider()
        updateDiagnostics(for: pairing)
        guard pairing.isPaired else {
            diagnostics.lastError = "Pair a companion before publishing"
            return
        }

        if !started {
            inboundTask = Task { [demux] in
                let stream = await demux.subscribe()
                await self.recordInbound(stream)
            }
            let store = ActivityStore(replicaId: replicaId)
            let spatial = MemorySpatialOpLogStore()
            let activity = ActivityProjectionSender(store: store, demux: demux, authorizedScope: pairing.authorizedScope)
            let spatialSender = SpatialOpSender(store: spatial, demux: demux, authorizedScope: pairing.authorizedScope)
            let responder = ApprovalResponder(
                seam: UnknownRequestApprovalSeam(),
                demux: demux,
                authorizedScope: pairing.authorizedScope,
                onAck: { [weak self] ack in
                    await self?.recordApprovalAck(ack)
                }
            )
            await activity.start()
            await spatialSender.start()
            await responder.start()
            activityStore = store
            spatialStore = spatial
            activitySender = activity
            self.spatialSender = spatialSender
            approvalResponder = responder
            started = true
        }

        try await ensureSubscriptionHook()
        try await publishHeartbeat(pairing: pairing, spatialWatermark: "startup", activityWatermark: "startup")
    }

    public func stop() async {
        inboundTask?.cancel()
        inboundTask = nil
        await activitySender?.stop()
        await spatialSender?.stop()
        await approvalResponder?.stop()
        activitySender = nil
        spatialSender = nil
        approvalResponder = nil
        activityStore = nil
        spatialStore = nil
        started = false
    }

    public func publishCurrentDesktopSnapshot(reason: DesktopCompanionPublishReason) async throws {
        let pairing = await pairingSnapshotProvider()
        updateDiagnostics(for: pairing)
        guard pairing.isPaired else {
            diagnostics.lastError = "Pair a companion before publishing"
            return
        }

        let now = clock.now()
        let (canvas, workspace) = try await canvasSnapshotProvider()
        let spatial = DesktopSpatialBootstrap.snapshot(canvasState: canvas, workspaceDocument: workspace, replicaId: replicaId)
        let activity = try await activitySnapshotProvider()
        try await demux.send(.snapshot(spatial))
        try await demux.send(.activity(.snapshot(activity)))
        diagnostics.lastSpatialPublishAt = now
        diagnostics.lastActivityPublishAt = now
        diagnostics.lastError = nil
        try await publishHeartbeat(
            pairing: pairing,
            spatialWatermark: "\(spatial.compactionOpId.lamport):\(spatial.compactionOpId.replica.uuidString)",
            activityWatermark: "\(activity.snapshotSequence):\(activity.snapshotReplicaId.uuidString)"
        )
    }

    public func fetchChanges(reason: DesktopCompanionFetchReason) async throws {
        let pairing = await pairingSnapshotProvider()
        updateDiagnostics(for: pairing)
        guard pairing.isPaired else {
            diagnostics.lastError = "Pair a companion before fetching"
            return
        }
        try await fetchChangesHook()
        diagnostics.lastFetchAt = clock.now()
        diagnostics.lastError = nil
    }

    private func publishHeartbeat(
        pairing: DesktopCompanionPairingSnapshot,
        spatialWatermark: String?,
        activityWatermark: String?
    ) async throws {
        sequence += 1
        let now = clock.now()
        let metadata = CompanionFreshnessMetadata(
            instanceId: pairing.instanceId,
            desktopReplicaId: replicaId.uuidString,
            bootId: bootId,
            sequence: sequence,
            publishedAt: now,
            receivedAt: now,
            powerHint: .active,
            spatialWatermark: spatialWatermark,
            activityWatermark: activityWatermark
        )
        try await freshnessPublisher.publishHeartbeat(metadata)
        diagnostics.lastHeartbeatAt = now
    }

    private func recordInbound(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            recordInbound(message)
        }
    }

    private func recordInbound(_ message: SyncMessage) {
        switch message {
        case .op:
            diagnostics.lastInboundMessageKind = "op"
        case .snapshot:
            diagnostics.lastInboundMessageKind = "snapshot"
        case .activity:
            diagnostics.lastInboundMessageKind = "activity"
        case .activitySubscribe:
            diagnostics.lastInboundMessageKind = "activitySubscribe"
        case .spatialSubscribe:
            diagnostics.lastInboundMessageKind = "spatialSubscribe"
        case .approvalResponse:
            diagnostics.lastInboundMessageKind = "approvalResponse"
        case .approvalResponseAck(let ack):
            diagnostics.lastInboundMessageKind = "approvalResponseAck"
            diagnostics.lastApprovalResponseOutcome = ack.outcome
        }
    }

    private func recordApprovalAck(_ ack: ApprovalResponseAck) {
        diagnostics.lastInboundMessageKind = "approvalResponseAck"
        diagnostics.lastApprovalResponseOutcome = ack.outcome
    }

    private func updateDiagnostics(for pairing: DesktopCompanionPairingSnapshot) {
        diagnostics.isPaired = pairing.isPaired
        diagnostics.pairedDeviceCount = pairing.pairedDeviceCount
        diagnostics.authorizedScope = pairing.authorizedScope
        diagnostics.transportIsPairingProof = false
    }
}
