import Foundation

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var viewport: CanvasViewport
    public var zones: [ZonePlacement]
    public var zoneZOrder: [UUID]
    public var lastActiveZoneId: UUID?

    public init(
        schemaVersion: Int = WorkspaceDocument.currentSchemaVersion,
        viewport: CanvasViewport,
        zones: [ZonePlacement],
        zoneZOrder: [UUID],
        lastActiveZoneId: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.viewport = viewport
        self.zones = zones
        self.zoneZOrder = zoneZOrder
        self.lastActiveZoneId = lastActiveZoneId
    }

    public func validateSchema(at url: URL) throws {
        if schemaVersion > WorkspaceDocument.currentSchemaVersion {
            throw ProjectStoreError.unknownFutureSchema(
                path: url.path,
                version: schemaVersion,
                supported: WorkspaceDocument.currentSchemaVersion
            )
        }
    }
}

public struct ZonePlacement: Codable, Equatable, Sendable {
    public let zoneId: UUID
    public var projectId: UUID
    public var origin: ZonePoint
    public var size: ZoneSize
    public var color: String
    public var collapsed: Bool
    public var hydrationPolicy: ZoneHydrationPolicy

    public init(
        zoneId: UUID,
        projectId: UUID,
        origin: ZonePoint,
        size: ZoneSize,
        color: String,
        collapsed: Bool,
        hydrationPolicy: ZoneHydrationPolicy
    ) {
        self.zoneId = zoneId
        self.projectId = projectId
        self.origin = origin
        self.size = size
        self.color = color
        self.collapsed = collapsed
        self.hydrationPolicy = hydrationPolicy
    }
}

public struct ZonePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ZoneSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum ZoneHydrationPolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case automatic
    case pinnedLive
}
