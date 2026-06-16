import Foundation

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

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

    @discardableResult
    public mutating func appendProjectZone(
        projectId: UUID,
        zoneId: UUID = UUID(),
        defaultSize: ZoneSize = ZoneSize(width: 1280, height: 720),
        gap: Double = 120,
        color: String = "mint"
    ) -> ZonePlacement {
        let maxX = zones.map { $0.origin.x + $0.size.width }.max() ?? 0
        let origin = zones.isEmpty
            ? ZonePoint(x: 0, y: 0)
            : ZonePoint(x: maxX + gap, y: 0)
        let placement = ZonePlacement(
            zoneId: zoneId,
            projectId: projectId,
            origin: origin,
            size: defaultSize,
            color: color,
            collapsed: false,
            hydrationPolicy: .automatic,
            name: "",
            navKey: nil
        )
        zones.append(placement)
        zoneZOrder.removeAll { $0 == zoneId }
        zoneZOrder.append(zoneId)
        lastActiveZoneId = zoneId
        return placement
    }
}

public struct ZonePlacement: Equatable, Sendable {
    public let zoneId: UUID
    public var projectId: UUID?
    public var origin: ZonePoint
    public var size: ZoneSize
    public var color: String
    public var collapsed: Bool
    public var hydrationPolicy: ZoneHydrationPolicy
    public var name: String
    public var navKey: String?

    public init(
        zoneId: UUID,
        projectId: UUID?,
        origin: ZonePoint,
        size: ZoneSize,
        color: String,
        collapsed: Bool,
        hydrationPolicy: ZoneHydrationPolicy,
        name: String = "",
        navKey: String? = nil
    ) {
        self.zoneId = zoneId
        self.projectId = projectId
        self.origin = origin
        self.size = size
        self.color = color
        self.collapsed = collapsed
        self.hydrationPolicy = hydrationPolicy
        self.name = name
        self.navKey = navKey
    }
}

extension ZonePlacement: Codable {
    private enum CodingKeys: String, CodingKey {
        case zoneId, projectId, origin, size, color, collapsed, hydrationPolicy, name, navKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoneId = try container.decode(UUID.self, forKey: .zoneId)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        origin = try container.decode(ZonePoint.self, forKey: .origin)
        size = try container.decode(ZoneSize.self, forKey: .size)
        color = try container.decode(String.self, forKey: .color)
        collapsed = try container.decode(Bool.self, forKey: .collapsed)
        hydrationPolicy = try container.decode(ZoneHydrationPolicy.self, forKey: .hydrationPolicy)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        navKey = try container.decodeIfPresent(String.self, forKey: .navKey)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(zoneId, forKey: .zoneId)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encode(origin, forKey: .origin)
        try container.encode(size, forKey: .size)
        try container.encode(color, forKey: .color)
        try container.encode(collapsed, forKey: .collapsed)
        try container.encode(hydrationPolicy, forKey: .hydrationPolicy)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(navKey, forKey: .navKey)
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

public enum HydrationTier: String, Codable, Equatable, Sendable, CaseIterable {
    case live
    case snapshot
    case cold
}
