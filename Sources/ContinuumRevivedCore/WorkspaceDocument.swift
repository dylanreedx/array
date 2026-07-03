import Foundation

public struct WorkspaceDocument: Equatable, Sendable {
    /// v2: grouped `groupZoneTiles` bag. v3: flat `ambientTiles` list with
    /// membership on each tile's `zoneId` LWW register (ticket 03).
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public var viewport: CanvasViewport
    public var zones: [ZonePlacement]
    public var zoneZOrder: [UUID]
    public var lastActiveZoneId: UUID?
    /// The tiles that live in this workspace's group zones (and formerly-zoned
    /// ambient tiles with `zoneId == nil`). This is the authoritative store for
    /// ambient tiles — they have no project `CanvasState`. Membership is derived
    /// from each tile's `zoneId` register, never from a per-zone list.
    public var ambientTiles: [Tile]

    public init(
        schemaVersion: Int = WorkspaceDocument.currentSchemaVersion,
        viewport: CanvasViewport,
        zones: [ZonePlacement],
        zoneZOrder: [UUID],
        lastActiveZoneId: UUID?,
        ambientTiles: [Tile] = []
    ) {
        self.schemaVersion = schemaVersion
        self.viewport = viewport
        self.zones = zones
        self.zoneZOrder = zoneZOrder
        self.lastActiveZoneId = lastActiveZoneId
        self.ambientTiles = ambientTiles
    }

    public func tiles(forZone zoneId: UUID) -> [Tile] {
        ambientTiles.filter { $0.zoneId == zoneId }
    }

    /// Field-scoped membership write: places `tiles` into the zone and clears
    /// tiles previously in the zone that are absent from the new list. For a
    /// tile already present in `ambientTiles` this mutates ONLY its `zoneId`
    /// register — a stale caller's copy of the tile must never clobber the
    /// stored frame/title/runtimeRef/metadata.
    public mutating func setTiles(_ tiles: [Tile], forZone zoneId: UUID) {
        let newIds = Set(tiles.map(\.id))
        for i in ambientTiles.indices
        where ambientTiles[i].zoneId == zoneId && !newIds.contains(ambientTiles[i].id) {
            ambientTiles[i].zoneId = nil
        }
        for tile in tiles {
            if let i = ambientTiles.firstIndex(where: { $0.id == tile.id }) {
                ambientTiles[i].zoneId = zoneId
            } else {
                ambientTiles.append(tile.with(zoneId: zoneId))
            }
        }
    }

    /// The LWW register write for one ambient tile — the production sink for
    /// `Op.setTileZone` targeting a tile stored on this document. Mutates ONLY
    /// the `zoneId` field of the addressed tile; every sibling field is
    /// untouched. No-op if the tile is not in `ambientTiles`.
    public mutating func setTileZone(_ tileId: UUID, zoneId: UUID?) {
        guard let i = ambientTiles.firstIndex(where: { $0.id == tileId }) else { return }
        ambientTiles[i].zoneId = zoneId
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

    @discardableResult
    public mutating func appendGroupZone(
        name: String,
        zoneId: UUID = UUID(),
        defaultSize: ZoneSize = ZoneSize(width: 1280, height: 720),
        gap: Double = 120,
        color: String = "mint"
    ) -> ZonePlacement {
        let maxX = zones.map { $0.origin.x + $0.size.width }.max() ?? 0
        let origin = zones.isEmpty ? ZonePoint(x: 0, y: 0) : ZonePoint(x: maxX + gap, y: 0)
        let placement = ZonePlacement(
            zoneId: zoneId,
            projectId: nil,
            origin: origin,
            size: defaultSize,
            color: color,
            collapsed: false,
            hydrationPolicy: .automatic,
            name: name,
            navKey: nil
        )
        zones.append(placement)
        zoneZOrder.removeAll { $0 == zoneId }
        zoneZOrder.append(zoneId)
        lastActiveZoneId = zoneId
        return placement
    }
}

extension WorkspaceDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        // `groupZoneTiles` is decode-only: the pre-v3 on-disk shape. Never re-emitted.
        case schemaVersion, viewport, zones, zoneZOrder, lastActiveZoneId, ambientTiles, groupZoneTiles
    }

    /// Decode-only parse of the pre-v3 grouped shape. Not public API; exists
    /// solely so the migration can flatten old documents into `ambientTiles`.
    private struct LegacyGroupZoneTiles: Decodable {
        let zoneId: UUID
        var tiles: [Tile]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        viewport = try container.decode(CanvasViewport.self, forKey: .viewport)
        zones = try container.decode([ZonePlacement].self, forKey: .zones)
        zoneZOrder = try container.decode([UUID].self, forKey: .zoneZOrder)
        lastActiveZoneId = try container.decodeIfPresent(UUID.self, forKey: .lastActiveZoneId)

        var tiles = try container.decodeIfPresent([Tile].self, forKey: .ambientTiles) ?? []
        if decodedVersion < 3 {
            // Flatten the pre-v3 grouped shape: the legacy list already holds the
            // full Tile values, so migration stamps each tile's zoneId register
            // directly and re-homes it — no cross-store lookup exists or is needed.
            let legacy = try container.decodeIfPresent([LegacyGroupZoneTiles].self, forKey: .groupZoneTiles) ?? []
            for group in legacy {
                for tile in group.tiles where !tiles.contains(where: { $0.id == tile.id }) {
                    tiles.append(tile.with(zoneId: group.zoneId))
                }
            }
        }
        ambientTiles = tiles

        // Migrate-forward-on-load: supported older versions decode into the current
        // in-memory shape and are stamped current. Future versions keep their stamp
        // so `validateSchema` fires instead of silently downgrading.
        schemaVersion = decodedVersion <= WorkspaceDocument.currentSchemaVersion
            ? WorkspaceDocument.currentSchemaVersion
            : decodedVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Re-stamp on save (see CanvasState.encode(to:) for the rationale). This
        // also covers every embedding — e.g. the WorkspaceDocument nested inside a
        // WorkspaceProfile — so no save path can write new fields under an old stamp.
        try container.encode(Swift.max(schemaVersion, WorkspaceDocument.currentSchemaVersion), forKey: .schemaVersion)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(zones, forKey: .zones)
        try container.encode(zoneZOrder, forKey: .zoneZOrder)
        try container.encodeIfPresent(lastActiveZoneId, forKey: .lastActiveZoneId)
        // Only the flat register-carrying list; the legacy grouped key is never re-emitted.
        try container.encode(ambientTiles, forKey: .ambientTiles)
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
