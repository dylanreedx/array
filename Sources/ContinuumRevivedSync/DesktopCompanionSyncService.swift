import CryptoKit
import ContinuumRevivedAgentUI
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedRelayProtocol
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

    /// The hardened relay, rather than the legacy local auth database, is the
    /// source of truth for hosted companion devices. Its phone profile is fixed
    /// server-side, so the desktop must not derive broader authority from client
    /// input when projecting that state into the sync service.
    public static func hostedRelay(instanceId: UUID, pairedDeviceCount: Int) -> DesktopCompanionPairingSnapshot {
        guard pairedDeviceCount > 0 else { return .unpaired(instanceId: instanceId) }
        // The relay decides per phone whether it may message (its
        // `sendMessages` capability); the Mac also needs the sealed text to
        // open under a key from that phone's pairing secret.
        return DesktopCompanionPairingSnapshot(
            instanceId: instanceId,
            pairedDeviceCount: pairedDeviceCount,
            authorizedScope: Scope.companionControl.union(.agentMessage)
        )
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
    /// Whether the relay applies task alerts, as of the last task publication
    /// attempt while paired. nil until one has run.
    public var taskAlertsSupported: Bool?

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
        lastError: String? = nil,
        taskAlertsSupported: Bool? = nil
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
        self.taskAlertsSupported = taskAlertsSupported
    }

    /// What `agent.notify` can promise, from what the last publication learned.
    public var notifyDelivery: AgentNotifyResult.PhoneDelivery {
        guard isPaired, pairedDeviceCount > 0 else { return .noPairedPhone }
        switch taskAlertsSupported {
        case true?: return .taskAlerts
        case false?: return .relayWithoutTaskAlerts
        case nil: return .unknown
        }
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
            ops.append(logged(
                &lamport,
                replicaId,
                .setZoneScope(
                    id: zone.zoneId,
                    projectId: zone.projectId,
                    homeRelativePath: zone.homeRelativePath
                )
            ))
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
    public typealias TranscriptChannelProvider = @Sendable () async -> [TranscriptChannelKey]
    public typealias TranscriptDocumentProvider = TranscriptProjectionSender.DocumentProvider
    public typealias AgentStopHandler = AgentStopResponder.StopHandler
    public typealias AgentMessageHandler = @Sendable (UUID, String) async -> AgentMessageOutcome
    public typealias FetchChangesHook = @Sendable () async throws -> Void
    public typealias SubscriptionHook = @Sendable () async throws -> Void

    private let configuration: DesktopCompanionSyncConfiguration
    private let transport: any SyncTransport
    private let demux: SyncMessageDemux
    private var pairingSnapshotProvider: PairingSnapshotProvider
    private let canvasSnapshotProvider: CanvasSnapshotProvider
    private let activitySnapshotProvider: ActivitySnapshotProvider
    private let transcriptChannelProvider: TranscriptChannelProvider
    private let transcriptDocumentProvider: TranscriptDocumentProvider
    private let agentStopHandler: AgentStopHandler
    private let agentMessageHandler: AgentMessageHandler
    private let approvals: any ApprovalResponding
    private let commandChannel: RelayCommandChannel?
    private let commandJournal: CompanionCommandJournal?
    private let commandDiagnostic: (@Sendable (String) -> Void)?
    private var commandReceiver: CompanionCommandReceiver?
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
    private var agentStopResponder: AgentStopResponder?
    private var transcriptSenders: [UUID: TranscriptProjectionSender] = [:]
    private var transcriptChannelKeys: [UUID: SymmetricKey] = [:]
    private var activityStore: ActivityStore?
    private var spatialStore: MemorySpatialOpLogStore?
    private let taskSnapshotProvider: (@Sendable (UInt64) async throws -> CompanionTaskSnapshotBatch)?
    private var taskPublication: Task<String?, Never>?
    private var taskPublicationAgain = false
    private var taskPulse: Task<Void, Never>?

    public private(set) var diagnostics: DesktopCompanionSyncDiagnostics

    public init(
        configuration: DesktopCompanionSyncConfiguration,
        transport: any SyncTransport,
        pairingSnapshot: @escaping PairingSnapshotProvider,
        canvasSnapshot: @escaping CanvasSnapshotProvider,
        activitySnapshot: @escaping ActivitySnapshotProvider,
        taskSnapshot: (@Sendable (UInt64) async throws -> CompanionTaskSnapshotBatch)? = nil,
        transcriptChannels: @escaping TranscriptChannelProvider = { [] },
        transcriptDocument: @escaping TranscriptDocumentProvider = { _ in nil },
        stopAgent: @escaping AgentStopHandler = { _ in .unsupported },
        sendMessage: @escaping AgentMessageHandler = { _, _ in .unsupported },
        approvals: (any ApprovalResponding)? = nil,
        commandChannel: RelayCommandChannel? = nil,
        commandJournal: CompanionCommandJournal? = nil,
        commandDiagnostic: (@Sendable (String) -> Void)? = nil,
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
        self.taskSnapshotProvider = taskSnapshot
        self.transcriptChannelProvider = transcriptChannels
        self.transcriptDocumentProvider = transcriptDocument
        self.agentStopHandler = stopAgent
        self.agentMessageHandler = sendMessage
        self.approvals = approvals ?? UnknownRequestApprovalSeam()
        self.commandChannel = commandChannel
        self.commandJournal = commandJournal
        self.commandDiagnostic = commandDiagnostic
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
                seam: approvals,
                demux: demux,
                authorizedScope: pairing.authorizedScope,
                onAck: { [weak self] ack in
                    await self?.recordApprovalAck(ack)
                }
            )
            let stopResponder = AgentStopResponder(
                demux: demux,
                authorizedScope: pairing.authorizedScope,
                stopHandler: agentStopHandler
            )
            await activity.start()
            await spatialSender.start()
            await responder.start()
            await stopResponder.start()
            activityStore = store
            spatialStore = spatial
            activitySender = activity
            self.spatialSender = spatialSender
            approvalResponder = responder
            agentStopResponder = stopResponder
            if let commandChannel {
                let scope = pairing.authorizedScope
                let receiver = CompanionCommandReceiver(channel: commandChannel, journal: commandJournal,
                                                        onDiagnostic: commandDiagnostic) { [weak self] command in
                    guard let self else { return RelayCommandResult(outcome: "unavailable") }
                    return await self.perform(command, scope: scope)
                }
                await receiver.start()
                commandReceiver = receiver
            }
            started = true
            if taskSnapshotProvider != nil, transport is any CompanionTaskPublishingTransport {
                taskPulse = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        guard let self else { return }
                        _ = await self.publishTaskNotifications()
                    }
                }
            }
        }

        await refreshTranscriptSenders(scope: pairing.authorizedScope)

        try await ensureSubscriptionHook()
        try await publishHeartbeat(pairing: pairing, spatialWatermark: "startup", activityWatermark: "startup")
    }

    public func stop() async {
        taskPulse?.cancel(); taskPulse = nil
        taskPublication?.cancel()
        _ = await taskPublication?.value
        taskPublication = nil
        inboundTask?.cancel()
        inboundTask = nil
        await activitySender?.stop()
        await spatialSender?.stop()
        await approvalResponder?.stop()
        await agentStopResponder?.stop()
        await commandReceiver?.stop()
        commandReceiver = nil
        for sender in transcriptSenders.values { await sender.stop() }
        activitySender = nil
        spatialSender = nil
        approvalResponder = nil
        agentStopResponder = nil
        transcriptSenders = [:]
        activityStore = nil
        spatialStore = nil
        started = false
    }

    /// One phone command, through the same handlers the sync messages use.
    /// The relay already checked the phone's capability; the pairing scope is
    /// checked again here so a narrower local grant still holds.
    func perform(_ command: RelayCommand, scope: Scope) async -> RelayCommandResult {
        switch command.kind {
        case RelayCommandKind.agentStop:
            guard scope.contains(.agentStop) else { return .init(outcome: AgentStopOutcome.unauthorized.rawValue) }
            return .init(outcome: await agentStopHandler(command.agentID).rawValue)
        case RelayCommandKind.approvalRespond:
            guard (try? authorize(.respondToApproval, grantedScopes: scope)) != nil else {
                return .init(outcome: ApprovalResponseOutcome.unauthorized.rawValue)
            }
            guard let payload = command.payload,
                  let approval = try? JSONDecoder().decode(CompanionApprovalCommand.self, from: payload) else {
                return .init(outcome: "invalid")
            }
            let outcome: ApprovalResponseOutcome
            switch await approvals.respond(agentId: command.agentID, requestId: approval.requestId, decision: approval.decision) {
            case .resolved: outcome = .resolved
            case .sent: outcome = .sent
            case .stale: outcome = .stale
            case .unknownRequest: outcome = .unknownRequest
            }
            diagnostics.lastApprovalResponseOutcome = outcome
            return .init(outcome: outcome.rawValue)
        case RelayCommandKind.transcriptRequest:
            guard scope.contains(.transcriptRead) else { return .init(outcome: CompanionTranscriptOutcome.unauthorized.rawValue) }
            guard let payload = command.payload,
                  let request = try? JSONDecoder().decode(CompanionTranscriptRequest.self, from: payload) else {
                return .init(outcome: "invalid")
            }
            // A phone paired since this service started brings a key the
            // senders were not built with; look again before saying no.
            if transcriptSenders[request.keyID] == nil { await refreshTranscriptSenders(scope: scope) }
            guard let sender = transcriptSenders[request.keyID] else {
                return .init(outcome: CompanionTranscriptOutcome.unknownKey.rawValue)
            }
            return .init(outcome: await sender.publish(agentID: command.agentID, knownVersion: request.knownVersion).rawValue)
        case RelayCommandKind.agentMessage:
            // Runs at most once per command: the receiver keeps an unposted
            // result and re-posts it rather than running the command again.
            guard scope.contains(.agentMessage) else { return .init(outcome: AgentMessageOutcome.unauthorized.rawValue) }
            guard let payload = command.payload,
                  let sealed = try? JSONDecoder().decode(CompanionSealedMessage.self, from: payload) else {
                return .init(outcome: AgentMessageOutcome.invalid.rawValue)
            }
            if transcriptChannelKeys[sealed.keyID] == nil { await refreshTranscriptSenders(scope: scope) }
            guard let key = transcriptChannelKeys[sealed.keyID] else { return .init(outcome: AgentMessageOutcome.unknownKey.rawValue) }
            guard let text = try? TranscriptSyncCrypto.openMessage(sealed, key: key, idempotencyKey: command.idempotencyKey, agentID: command.agentID) else {
                return .init(outcome: AgentMessageOutcome.invalid.rawValue)
            }
            return .init(outcome: await agentMessageHandler(command.agentID, text).rawValue)
        default:
            return .init(outcome: "unsupported")
        }
    }

    private func refreshTranscriptSenders(scope: Scope) async {
        let channels = scope.contains(.transcriptRead) ? await transcriptChannelProvider() : []
        transcriptChannelKeys = Dictionary(channels.map { ($0.keyID, $0.key) }, uniquingKeysWith: { first, _ in first })
        let wanted = Set(channels.map(\.keyID))
        let obsolete = transcriptSenders.keys.filter { !wanted.contains($0) }
        for keyID in obsolete {
            guard let sender = transcriptSenders[keyID] else { continue }
            await sender.stop()
            transcriptSenders.removeValue(forKey: keyID)
        }
        for channel in channels where transcriptSenders[channel.keyID] == nil {
            let sender = TranscriptProjectionSender(
                demux: demux,
                authorizedScope: scope,
                channelKey: channel.key,
                keyID: channel.keyID,
                documentProvider: transcriptDocumentProvider
            )
            await sender.start()
            transcriptSenders[channel.keyID] = sender
        }
    }

    public func publishCurrentDesktopSnapshot(reason: DesktopCompanionPublishReason) async throws {
        let pairing = await pairingSnapshotProvider()
        updateDiagnostics(for: pairing)
        guard pairing.isPaired else {
            diagnostics.lastError = "Pair a companion before publishing"
            return
        }

        // Task metadata must publish even when no canvas is mounted or inventory
        // reconciliation is still pending. Join ownership before legacy sends.
        let taskError = await publishTaskNotifications()
        let now = clock.now()
        let (canvas, workspace) = try await canvasSnapshotProvider()
        let spatial = DesktopSpatialBootstrap.snapshot(canvasState: canvas, workspaceDocument: workspace, replicaId: replicaId)
        let activity = try await activitySnapshotProvider()
        try await demux.send(.snapshot(spatial))
        try await demux.send(.activity(.snapshot(activity)))
        diagnostics.lastSpatialPublishAt = now
        diagnostics.lastActivityPublishAt = now
        diagnostics.lastError = taskError
        try await publishHeartbeat(
            pairing: pairing,
            spatialWatermark: "\(spatial.compactionOpId.lamport):\(spatial.compactionOpId.replica.uuidString)",
            activityWatermark: "\(activity.snapshotSequence):\(activity.snapshotReplicaId.uuidString)"
        )
    }

    private func publishTaskNotifications() async -> String? {
        guard let provider = taskSnapshotProvider, let publisher = transport as? any CompanionTaskPublishingTransport else { return nil }
        if let active = taskPublication {
            taskPublicationAgain = true
            return await active.value
        }
        let job = Task { [weak self] () -> String? in
            guard let self else { return nil }
            return await self.performTaskPublication(provider: provider, publisher: publisher)
        }
        taskPublication = job
        let error = await job.value
        taskPublication = nil
        return error
    }

    private func performTaskPublication(
        provider: @Sendable (UInt64) async throws -> CompanionTaskSnapshotBatch,
        publisher: any CompanionTaskPublishingTransport
    ) async -> String? {
        repeat {
            taskPublicationAgain = false
            if Task.isCancelled { return "Task notifications cancelled" }
            do {
                let pairing = await pairingSnapshotProvider()
                guard pairing.isPaired else { return nil }
                let context = try await publisher.taskNotificationContext()
                diagnostics.taskAlertsSupported = context.supported
                guard context.supported else { return nil }
                let snapshot = try await provider(context.owner?.revision ?? 0)
                if let owner = context.owner, owner.publisherID != snapshot.publisherID {
                    diagnostics.lastError = "Task notification owner mismatch"
                    return diagnostics.lastError
                }
                try await publisher.publishTaskNotifications(snapshot)
            } catch {
                // Do not export paths, request bodies, storage errors or auth.
                diagnostics.lastError = "Task notifications unavailable"
                return diagnostics.lastError
            }
        } while taskPublicationAgain
        if diagnostics.lastError == "Task notifications unavailable" { diagnostics.lastError = nil }
        return nil
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
        case .transcriptSubscribe:
            diagnostics.lastInboundMessageKind = "transcriptSubscribe"
        case .transcriptEnvelope:
            diagnostics.lastInboundMessageKind = "transcriptEnvelope"
        case .transcriptHistoryRequest:
            diagnostics.lastInboundMessageKind = "transcriptHistoryRequest"
        case .transcriptHistoryResponse:
            diagnostics.lastInboundMessageKind = "transcriptHistoryResponse"
        case .transcriptDetailRequest:
            diagnostics.lastInboundMessageKind = "transcriptDetailRequest"
        case .transcriptDetailResponse:
            diagnostics.lastInboundMessageKind = "transcriptDetailResponse"
        case .childLifecycle:
            diagnostics.lastInboundMessageKind = "childLifecycle"
        case .agentStopRequest:
            diagnostics.lastInboundMessageKind = "agentStopRequest"
        case .agentStopAck:
            diagnostics.lastInboundMessageKind = "agentStopAck"
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
