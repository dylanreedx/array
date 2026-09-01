import Foundation

public struct WorkspaceDocument: Equatable, Sendable {
    /// v2: grouped `groupZoneTiles` bag. v3: flat `ambientTiles` list with
    /// membership on each tile's `zoneId` LWW register (ticket 03).
    /// v4: zone stacking on `ZonePlacement.zPosition` fractional index; the
    /// `zoneZOrder` array is a decode-only legacy migration key (ticket 04).
    /// v5: durable agent-to-document relationships.
    /// v6: per-zone auto-layout override.
    /// v7: project-relative Home on zones. Project + Home form one creation
    /// scope and are changed atomically; legacy project zones migrate to the
    /// project root (`homeRelativePath == nil`).
    /// v8: workspace-local last explicitly confirmed creation scope. Focus and
    /// automatic navigation never write it.
    /// v9: per-workspace canvas background — an EXPLICIT `.inherit` or
    /// `.override`, never a materialised copy of the global value (WS7).
    public static let currentSchemaVersion = 9

    public let schemaVersion: Int
    public var viewport: CanvasViewport
    public var zones: [ZonePlacement]
    public var lastActiveZoneId: UUID?
    /// The tiles that live in this workspace's group zones (and formerly-zoned
    /// ambient tiles with `zoneId == nil`). This is the authoritative store for
    /// ambient tiles — they have no project `CanvasState`. Membership is derived
    /// from each tile's `zoneId` register, never from a per-zone list.
    public var ambientTiles: [Tile]
    public var documentLinks: [DocumentAgentLink]
    public var lastExplicitCreationScope: ZoneScope?
    /// WS7. Missing key decodes to `.inherit`, so every document written before
    /// v9 keeps following the global configuration — which is what it was
    /// implicitly doing.
    public var canvasBackground: WorkspaceCanvasBackground

    /// `zoneZOrder` is a RANK-STAMPING convenience mirroring the decoder's
    /// legacy migration: zones listed in it receive evenly distributed
    /// `zPosition` values in list order (later = frontmost), zones not listed
    /// keep the `zPosition` carried by their placement. Pass `[]` (the
    /// default) when placements already carry their positions. There is no
    /// stored order array — stacking lives on each zone's register.
    public init(
        schemaVersion: Int = WorkspaceDocument.currentSchemaVersion,
        viewport: CanvasViewport,
        zones: [ZonePlacement],
        zoneZOrder: [UUID] = [],
        lastActiveZoneId: UUID?,
        ambientTiles: [Tile] = [],
        documentLinks: [DocumentAgentLink] = [],
        lastExplicitCreationScope: ZoneScope? = nil,
        canvasBackground: WorkspaceCanvasBackground = .inherit
    ) {
        self.schemaVersion = schemaVersion
        self.viewport = viewport
        self.zones = Self.stampingZonePositions(zones, fromLegacyOrder: zoneZOrder)
        self.lastActiveZoneId = lastActiveZoneId
        self.ambientTiles = ambientTiles
        self.documentLinks = Self.deduplicated(documentLinks)
        self.lastExplicitCreationScope = lastExplicitCreationScope
        self.canvasBackground = canvasBackground
    }

    public mutating func linkDocument(_ tileId: UUID, to agentId: AgentID, at date: Date = Date()) {
        if let index = documentLinks.firstIndex(where: { $0.agentId == agentId && $0.documentTileId == tileId }) {
            documentLinks[index].updatedAt = date
        } else {
            documentLinks.append(DocumentAgentLink(agentId: agentId, documentTileId: tileId, createdAt: date, updatedAt: date))
        }
    }

    public mutating func removeDocumentLinks(agentId: AgentID? = nil, tileId: UUID? = nil) {
        documentLinks.removeAll { link in
            (agentId == nil || link.agentId == agentId) && (tileId == nil || link.documentTileId == tileId)
        }
    }

    private static func deduplicated(_ links: [DocumentAgentLink]) -> [DocumentAgentLink] {
        var result: [DocumentAgentLink] = []
        for link in links {
            if let index = result.firstIndex(where: { $0.agentId == link.agentId && $0.documentTileId == link.documentTileId }) {
                result[index].createdAt = min(result[index].createdAt, link.createdAt)
                result[index].updatedAt = max(result[index].updatedAt, link.updatedAt)
            } else {
                result.append(link)
            }
        }
        return result
    }

    /// Zones back-to-front: the (zPosition, zoneId) sort every render/hit-test
    /// consumer derives stacking from. Never array order.
    public var zonesInZOrder: [ZonePlacement] {
        zones.sorted { lhs, rhs in
            if lhs.zPosition != rhs.zPosition { return lhs.zPosition < rhs.zPosition }
            return lhs.zoneId.uuidString < rhs.zoneId.uuidString
        }
    }

    /// Promote a zone above every other zone via its fractional register.
    /// No-op when the zone is already strictly frontmost (never churns or
    /// lowers the front item).
    public mutating func bringZoneToFront(_ zoneId: UUID) {
        guard let i = zones.firstIndex(where: { $0.zoneId == zoneId }) else { return }
        let othersMax = zones.filter { $0.zoneId != zoneId }.map(\.zPosition).max()
        guard let othersMax else { return }                       // only zone — already front
        guard zones[i].zPosition <= othersMax else { return }     // already strictly frontmost
        zones[i].zPosition = FracIndex.after(othersMax)
    }

    /// The migration/stamping shared by the decoder (legacy `zoneZOrder` key)
    /// and the memberwise init: listed zones get evenly distributed positions
    /// in list order (later = frontmost); unlisted zones follow, above the
    /// listed ones, in array order — matching the old renderer's "layers not
    /// in zoneZOrder are appended last (= topmost)". Lossless: every relative
    /// order the old representation could express is preserved.
    private static func stampingZonePositions(
        _ zones: [ZonePlacement],
        fromLegacyOrder legacyOrder: [UUID]
    ) -> [ZonePlacement] {
        guard !legacyOrder.isEmpty, !zones.isEmpty else { return zones }
        var rankSequence: [UUID] = []
        for id in legacyOrder where zones.contains(where: { $0.zoneId == id }) && !rankSequence.contains(id) {
            rankSequence.append(id)
        }
        for zone in zones where !rankSequence.contains(zone.zoneId) {
            rankSequence.append(zone.zoneId)
        }
        let positions = FracIndex.distribute(count: rankSequence.count)
        let rankMap = Dictionary(uniqueKeysWithValues: zip(rankSequence, positions))
        return zones.map { zone in
            var stamped = zone
            if let position = rankMap[zone.zoneId] { stamped.zPosition = position }
            return stamped
        }
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
        var placement = ZonePlacement(
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
        placement.zPosition = FracIndex.after(zones.map(\.zPosition).max() ?? .first)
        zones.append(placement)
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
        var placement = ZonePlacement(
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
        placement.zPosition = FracIndex.after(zones.map(\.zPosition).max() ?? .first)
        zones.append(placement)
        lastActiveZoneId = zoneId
        return placement
    }
}

extension WorkspaceDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        // `groupZoneTiles` (pre-v3) and `zoneZOrder` (pre-v4) are decode-only
        // legacy migration keys. Never re-emitted.
        case schemaVersion, viewport, zones, zoneZOrder, lastActiveZoneId, ambientTiles, groupZoneTiles, documentLinks, lastExplicitCreationScope, canvasBackground
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
        var decodedZones = try container.decode([ZonePlacement].self, forKey: .zones)
        if decodedVersion < 4 {
            // Pre-v4 zone stacking lived in the ordered `zoneZOrder` array
            // (later = frontmost; unlisted layers rendered on top). Stamp that
            // order onto each zone's fractional register, preserving every
            // relative position — never collapse to a shared placeholder.
            let legacyOrder = try container.decodeIfPresent([UUID].self, forKey: .zoneZOrder) ?? []
            decodedZones = Self.stampingZonePositions(decodedZones, fromLegacyOrder: legacyOrder)
        }
        zones = decodedZones
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
        documentLinks = Self.deduplicated(try container.decodeIfPresent([DocumentAgentLink].self, forKey: .documentLinks) ?? [])
        lastExplicitCreationScope = try container.decodeIfPresent(ZoneScope.self, forKey: .lastExplicitCreationScope)
        // Tolerant on purpose: a background that cannot be read must not cost the
        // user their zones. Absent or unreadable both mean "follow the global".
        canvasBackground = ((try? container.decodeIfPresent(WorkspaceCanvasBackground.self, forKey: .canvasBackground)) ?? nil) ?? .inherit

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
        // Zone stacking rides each placement's zPosition; the legacy zoneZOrder
        // key is never re-emitted.
        try container.encode(zones, forKey: .zones)
        try container.encodeIfPresent(lastActiveZoneId, forKey: .lastActiveZoneId)
        // Only the flat register-carrying list; the legacy grouped key is never re-emitted.
        try container.encode(ambientTiles, forKey: .ambientTiles)
        try container.encode(documentLinks, forKey: .documentLinks)
        try container.encodeIfPresent(lastExplicitCreationScope, forKey: .lastExplicitCreationScope)
        try container.encode(canvasBackground, forKey: .canvasBackground)
    }
}

public struct ZonePlacement: Equatable, Sendable {
    public let zoneId: UUID
    public var projectId: UUID?
    /// A normalized path relative to the registered project root. `nil` means
    /// the project root. This is a default for filesystem-backed tiles created
    /// in the zone; changing it never retargets existing tiles.
    public var homeRelativePath: String?
    public var origin: ZonePoint
    public var size: ZoneSize
    public var color: String
    public var collapsed: Bool
    public var hydrationPolicy: ZoneHydrationPolicy
    public var autoLayoutMode: ZoneAutoLayoutMode
    public var name: String
    public var navKey: String?
    /// Zone stacking as a fractional-index LWW register (ticket 04): the field
    /// `Op.setZonePosition` folds into. Front-to-back order is the
    /// (zPosition, zoneId) sort — never array order. Pre-v4 documents carry no
    /// key here; the WorkspaceDocument decoder stamps positions from the
    /// legacy `zoneZOrder` array.
    public var zPosition: FracIndex

    public init(
        zoneId: UUID,
        projectId: UUID?,
        homeRelativePath: String? = nil,
        origin: ZonePoint,
        size: ZoneSize,
        color: String,
        collapsed: Bool,
        hydrationPolicy: ZoneHydrationPolicy,
        autoLayoutMode: ZoneAutoLayoutMode = .inherit,
        name: String = "",
        navKey: String? = nil,
        zPosition: FracIndex = .first
    ) {
        self.zoneId = zoneId
        self.projectId = projectId
        self.homeRelativePath = homeRelativePath
        self.origin = origin
        self.size = size
        self.color = color
        self.collapsed = collapsed
        self.hydrationPolicy = hydrationPolicy
        self.autoLayoutMode = autoLayoutMode
        self.name = name
        self.navKey = navKey
        self.zPosition = zPosition
    }

    public var scope: ZoneScope {
        get { ZoneScope(projectId: projectId, homeRelativePath: homeRelativePath) }
        set {
            projectId = newValue.projectId
            homeRelativePath = newValue.homeRelativePath
        }
    }
}

/// The atomic, syncable creation scope owned by a zone. `projectId == nil` is
/// retained only for migrated legacy zones that still need a project choice;
/// all newly committed zones require a project.
public struct ZoneScope: Codable, Equatable, Sendable {
    public var projectId: UUID?
    public var homeRelativePath: String?

    public init(projectId: UUID?, homeRelativePath: String? = nil) {
        self.projectId = projectId
        self.homeRelativePath = homeRelativePath
    }

    public var needsProject: Bool { projectId == nil }
}

extension ZonePlacement: Codable {
    private enum CodingKeys: String, CodingKey {
        case zoneId, projectId, homeRelativePath, origin, size, color, collapsed, hydrationPolicy, autoLayoutMode, name, navKey, zPosition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoneId = try container.decode(UUID.self, forKey: .zoneId)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        homeRelativePath = try container.decodeIfPresent(String.self, forKey: .homeRelativePath)
        origin = try container.decode(ZonePoint.self, forKey: .origin)
        size = try container.decode(ZoneSize.self, forKey: .size)
        color = try container.decode(String.self, forKey: .color)
        collapsed = try container.decode(Bool.self, forKey: .collapsed)
        hydrationPolicy = try container.decode(ZoneHydrationPolicy.self, forKey: .hydrationPolicy)
        autoLayoutMode = try container.decodeIfPresent(ZoneAutoLayoutMode.self, forKey: .autoLayoutMode) ?? .inherit
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        navKey = try container.decodeIfPresent(String.self, forKey: .navKey)
        // Pre-v4 placeholder; the WorkspaceDocument decoder overwrites it from
        // the legacy zoneZOrder ranks so relative order is never collapsed.
        zPosition = try container.decodeIfPresent(FracIndex.self, forKey: .zPosition) ?? .first
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(zoneId, forKey: .zoneId)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(homeRelativePath, forKey: .homeRelativePath)
        try container.encode(origin, forKey: .origin)
        try container.encode(size, forKey: .size)
        try container.encode(color, forKey: .color)
        try container.encode(collapsed, forKey: .collapsed)
        try container.encode(hydrationPolicy, forKey: .hydrationPolicy)
        try container.encode(autoLayoutMode, forKey: .autoLayoutMode)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(navKey, forKey: .navKey)
        try container.encode(zPosition, forKey: .zPosition)
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

public enum ZoneAutoLayoutMode: String, Codable, Equatable, Sendable, CaseIterable {
    case inherit
    case enabled
    case disabled

    public func resolves(globalEnabled: Bool) -> Bool {
        switch self {
        case .inherit: globalEnabled
        case .enabled: true
        case .disabled: false
        }
    }
}

public enum HydrationTier: String, Codable, Equatable, Sendable, CaseIterable {
    case live
    case snapshot
    case cold
}
