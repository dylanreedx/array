import ContinuumRevivedCore
import Foundation

public enum CompanionDogfoodJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public struct CompanionDogfoodHealthReport: Codable, Equatable, Sendable {
    public var desktopSignedWithICloudEntitlement: Bool
    public var containerIdentifier: String
    public var desktopBundleIdentifier: String
    public var iosBundleIdentifier: String
    public var iCloudAccountAvailable: Bool
    public var pairedContinuumInstance: Bool
    public var pairedDeviceCount: Int
    public var authorizedScopeRawValue: Int
    public var transportAvailability: CompanionTransportAvailability
    public var transportIsPairingProof: Bool
    public var freshnessRequired: Bool
    public var lastHeartbeatAt: Date?
    public var lastSpatialPublishAt: Date?
    public var lastActivityPublishAt: Date?
    public var lastFetchAt: Date?
    public var lastInboundMessageKind: String?
    public var lastApprovalResponseOutcome: String?
    public var lastError: String?
    public var apnsTopic: String?
    public var teamIdentifier: String?

    public init(
        diagnostics: DesktopCompanionSyncDiagnostics,
        iCloudAccountAvailable: Bool,
        apnsTopic: String? = nil,
        teamIdentifier: String? = nil
    ) {
        self.desktopSignedWithICloudEntitlement = diagnostics.signedWithICloudEntitlement
        self.containerIdentifier = diagnostics.containerIdentifier
        self.desktopBundleIdentifier = diagnostics.desktopBundleIdentifier
        self.iosBundleIdentifier = diagnostics.iosBundleIdentifier
        self.iCloudAccountAvailable = iCloudAccountAvailable
        self.pairedContinuumInstance = diagnostics.isPaired
        self.pairedDeviceCount = diagnostics.pairedDeviceCount
        self.authorizedScopeRawValue = diagnostics.authorizedScope.rawValue
        self.transportAvailability = diagnostics.transportAvailability
        self.transportIsPairingProof = diagnostics.transportIsPairingProof
        self.freshnessRequired = true
        self.lastHeartbeatAt = diagnostics.lastHeartbeatAt
        self.lastSpatialPublishAt = diagnostics.lastSpatialPublishAt
        self.lastActivityPublishAt = diagnostics.lastActivityPublishAt
        self.lastFetchAt = diagnostics.lastFetchAt
        self.lastInboundMessageKind = diagnostics.lastInboundMessageKind
        self.lastApprovalResponseOutcome = diagnostics.lastApprovalResponseOutcome?.rawValue
        self.lastError = diagnostics.lastError
        self.apnsTopic = apnsTopic
        self.teamIdentifier = teamIdentifier
    }
}

public enum CompanionDogfoodFixtureMutationPolicy: String, Codable, Equatable, Sendable {
    case temporaryWorkspaceOnly
}

public struct CompanionDogfoodFixture: Codable, Equatable, Sendable {
    public var label: String
    public var mutationPolicy: CompanionDogfoodFixtureMutationPolicy
    public var canvas: CanvasState
    public var workspace: WorkspaceDocument
    public var activity: ActivityLogSnapshot

    public init(
        label: String,
        mutationPolicy: CompanionDogfoodFixtureMutationPolicy,
        canvas: CanvasState,
        workspace: WorkspaceDocument,
        activity: ActivityLogSnapshot
    ) {
        self.label = label
        self.mutationPolicy = mutationPolicy
        self.canvas = canvas
        self.workspace = workspace
        self.activity = activity
    }

    public static func make(now: Date) -> CompanionDogfoodFixture {
        let zoneId = UUID(uuidString: "76000000-0000-4000-8000-000000000001")!
        let agentTileId = UUID(uuidString: "76000000-0000-4000-8000-000000000002")!
        let noteTileId = UUID(uuidString: "76000000-0000-4000-8000-000000000003")!
        let projectId = UUID(uuidString: "76000000-0000-4000-8000-000000000004")!
        let replicaId = UUID(uuidString: "76000000-0000-4000-8000-000000000005")!

        let agentTile = Tile(
            id: agentTileId,
            kind: .terminal,
            title: "Dogfood Dummy Agent",
            frame: TileFrame(x: 80, y: 96, width: 360, height: 220),
            zPosition: FracIndex(value: 0.5),
            zoneId: zoneId,
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "dogfood-dummy-agent")
        )
        let noteTile = Tile(
            id: noteTileId,
            kind: .note,
            title: "Companion dogfood fixture",
            frame: TileFrame(x: 480, y: 128, width: 300, height: 180),
            zPosition: FracIndex(value: 0.6),
            zoneId: zoneId,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [agentTile, noteTile],
            groups: [],
            lastActiveTileId: agentTileId
        )
        let workspace = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [
                ZonePlacement(
                    zoneId: zoneId,
                    projectId: projectId,
                    origin: ZonePoint(x: 48, y: 48),
                    size: ZoneSize(width: 820, height: 420),
                    color: "teal",
                    collapsed: false,
                    hydrationPolicy: .automatic,
                    name: "Companion Dogfood Zone",
                    navKey: nil,
                    zPosition: FracIndex(value: 0.4)
                )
            ],
            lastActiveZoneId: zoneId
        )
        let event = AgentActivityEvent(
            stamping: AgentActivityEventDraft(
                // Fixture agent: its tile is its identity, so the row also has a
                // working "Show on canvas" hint.
                agentId: agentTileId,
                tileId: agentTileId,
                runId: nil,
                tone: .info,
                kind: "dogfood.fixture",
                status: .working,
                summary: "Dogfood Dummy Agent working",
                occurredAt: now
            ),
            sequence: 1,
            replicaId: replicaId
        )
        return CompanionDogfoodFixture(
            label: "Continuum Companion Dogfood Fixture",
            mutationPolicy: .temporaryWorkspaceOnly,
            canvas: canvas,
            workspace: workspace,
            activity: apply(.empty, event)
        )
    }
}
