import Foundation

// MARK: - OpId

/// A deterministic, wall-clock-free total order for ops across replicas.
/// Ordering is (lamport, replica) lexicographic — never a timestamp.
public struct OpId: Comparable, Codable, Hashable, Sendable {
    public var lamport: UInt64
    public var replica: UUID

    public init(lamport: UInt64, replica: UUID) {
        self.lamport = lamport
        self.replica = replica
    }

    public static func < (lhs: OpId, rhs: OpId) -> Bool {
        if lhs.lamport != rhs.lamport { return lhs.lamport < rhs.lamport }
        // uuidString is canonical uppercase, fixed-width, hex+hyphen only,
        // so lexicographic string comparison is a stable byte-order proxy.
        return lhs.replica.uuidString < rhs.replica.uuidString
    }
}

// MARK: - FracIndex

/// A fractional z-order position in the open interval (0, 1). Both boundary
/// anchors (`first`, `last`) are concrete in-interval values, never sentinels,
/// so every consumer of `FracIndex` treats all values uniformly.
public struct FracIndex: Comparable, Codable, Sendable {
    public var value: Double

    public init(value: Double) {
        precondition(value > 0 && value < 1, "FracIndex value must be strictly between 0 and 1")
        self.value = value
    }

    /// Insert BEFORE the current lowest real item: `between(.first, x)`.
    public static let first = FracIndex(value: 0.25)
    /// Insert AFTER the current highest real item: `between(x, .last)`.
    public static let last = FracIndex(value: 0.75)

    /// Produces a value strictly between `lo` and `hi`. Callers must ensure
    /// `lo.value < hi.value`; traps in debug otherwise.
    public static func between(_ lo: FracIndex, _ hi: FracIndex) -> FracIndex {
        precondition(lo.value < hi.value, "FracIndex.between requires lo.value < hi.value")
        return FracIndex(value: (lo.value + hi.value) / 2.0)
    }

    public static func < (lhs: FracIndex, rhs: FracIndex) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        precondition(value > 0 && value < 1, "FracIndex value must be strictly between 0 and 1")
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Op

/// The closed set of spatial mutations that can be synced across replicas.
/// Associated values are drawn exclusively from spatial value types — no
/// `RuntimeRef`, `TerminalSessionDescriptor`, pid, or host-local path is
/// representable here. This is the type-level guarantee behind I5.
///
/// `Codable` is HAND-WRITTEN (not synthesized): the wire-format discriminator
/// strings below are a frozen, permanent on-disk API surface. See
/// docs/38-tickets/02-op-enum-logged-op-envelope.md "Wire format".
public enum Op: Sendable, Equatable {
    // --- Tile lifecycle ---
    case createTile(id: UUID, kind: TileKind, title: String, frame: TileFrame, zIndex: Int)
    case deleteTile(id: UUID)

    // --- Zone lifecycle ---
    case createZone(id: UUID, projectId: UUID?, origin: ZonePoint, size: ZoneSize, name: String, color: String)
    case deleteZone(id: UUID)

    // --- Per-field LWW registers on Tile ---
    case setTileFrame(id: UUID, frame: TileFrame)
    case setTileZIndex(id: UUID, zIndex: Int)
    case setTileTitle(id: UUID, title: String)
    case setTileKind(id: UUID, kind: TileKind)
    case setTileCollapsed(id: UUID, collapsed: Bool)

    // --- Per-field LWW registers on Zone ---
    case setZoneOrigin(id: UUID, origin: ZonePoint)
    case setZoneSize(id: UUID, size: ZoneSize)
    case setZoneName(id: UUID, name: String)
    case setZoneColor(id: UUID, color: String)
    case setZoneCollapsed(id: UUID, collapsed: Bool)
    case setZoneProjectId(id: UUID, projectId: UUID?)

    // --- Z-order (fractional index on zones) ---
    case setZonePosition(id: UUID, position: FracIndex)

    // --- Membership: LWW register ON the tile (not the zone's array) ---
    case setTileZone(tileId: UUID, zoneId: UUID?)

    // --- lastActive pointers (LWW registers) ---
    case setLastActiveTile(id: UUID?)
    case setLastActiveZone(id: UUID?)

    // NOTE: viewport is intentionally absent — per-device camera state,
    // excluded from sync (locked decision D3 / doc-38 E).
    // NOTE: runtimeRef is intentionally absent — a host-local handle; its
    // absence here is what makes I5 a compile-time guarantee.
}

extension Op: Codable {
    // Every rawValue below is written out EXPLICITLY, even though it is
    // textually identical to the case name. This is deliberate: an implicit
    // String-enum rawValue defaults to (and silently tracks) the case name,
    // so a future rename of the Swift case would rename the wire string too
    // — exactly the drift this ticket must prevent. Writing the string
    // literal makes the binding between the Swift case and the frozen wire
    // discriminator explicit and independent of the case's spelling; see
    // docs/38-tickets/02-op-enum-logged-op-envelope.md "Wire format".
    private enum CodingKeys: String, CodingKey {
        case createTile = "createTile"
        case deleteTile = "deleteTile"
        case createZone = "createZone"
        case deleteZone = "deleteZone"
        case setTileFrame = "setTileFrame"
        case setTileZIndex = "setTileZIndex"
        case setTileTitle = "setTileTitle"
        case setTileKind = "setTileKind"
        case setTileCollapsed = "setTileCollapsed"
        case setZoneOrigin = "setZoneOrigin"
        case setZoneSize = "setZoneSize"
        case setZoneName = "setZoneName"
        case setZoneColor = "setZoneColor"
        case setZoneCollapsed = "setZoneCollapsed"
        case setZoneProjectId = "setZoneProjectId"
        case setZonePosition = "setZonePosition"
        case setTileZone = "setTileZone"
        case setLastActiveTile = "setLastActiveTile"
        case setLastActiveZone = "setLastActiveZone"
        // rawValue == the FROZEN discriminator string above the case name.
        // Never change a rawValue; only add new cases/rows.
    }

    // Same rationale as CodingKeys above: every payload-key rawValue is an
    // explicit frozen string literal, not an implicit case-name default.
    private enum CreateTileKeys: String, CodingKey {
        case id = "id", kind = "kind", title = "title", frame = "frame", zIndex = "zIndex"
    }
    private enum DeleteTileKeys: String, CodingKey { case id = "id" }
    private enum CreateZoneKeys: String, CodingKey {
        case id = "id", projectId = "projectId", origin = "origin", size = "size", name = "name", color = "color"
    }
    private enum DeleteZoneKeys: String, CodingKey { case id = "id" }
    private enum SetTileFrameKeys: String, CodingKey { case id = "id", frame = "frame" }
    private enum SetTileZIndexKeys: String, CodingKey { case id = "id", zIndex = "zIndex" }
    private enum SetTileTitleKeys: String, CodingKey { case id = "id", title = "title" }
    private enum SetTileKindKeys: String, CodingKey { case id = "id", kind = "kind" }
    private enum SetTileCollapsedKeys: String, CodingKey { case id = "id", collapsed = "collapsed" }
    private enum SetZoneOriginKeys: String, CodingKey { case id = "id", origin = "origin" }
    private enum SetZoneSizeKeys: String, CodingKey { case id = "id", size = "size" }
    private enum SetZoneNameKeys: String, CodingKey { case id = "id", name = "name" }
    private enum SetZoneColorKeys: String, CodingKey { case id = "id", color = "color" }
    private enum SetZoneCollapsedKeys: String, CodingKey { case id = "id", collapsed = "collapsed" }
    private enum SetZoneProjectIdKeys: String, CodingKey { case id = "id", projectId = "projectId" }
    private enum SetZonePositionKeys: String, CodingKey { case id = "id", position = "position" }
    private enum SetTileZoneKeys: String, CodingKey { case tileId = "tileId", zoneId = "zoneId" }
    private enum SetLastActiveTileKeys: String, CodingKey { case id = "id" }
    private enum SetLastActiveZoneKeys: String, CodingKey { case id = "id" }

    /// A dynamic string key, used only to count the TOTAL number of keys in
    /// the top-level payload (including ones `CodingKeys` cannot represent).
    /// `KeyedDecodingContainer<CodingKeys>.allKeys` silently drops any key
    /// whose string doesn't match a `CodingKeys` case, so a payload with one
    /// known discriminator plus one unknown extra key would otherwise report
    /// `allKeys.count == 1` and decode successfully — exactly the silent
    /// drift this guards against.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKeyCount = try decoder.container(keyedBy: AnyKey.self).allKeys.count
        guard rawKeyCount == 1, c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "Op payload must have exactly one discriminator key, found \(rawKeyCount)"
            ))
        }
        switch key {
        case .createTile:
            let p = try c.nestedContainer(keyedBy: CreateTileKeys.self, forKey: .createTile)
            self = .createTile(
                id: try p.decode(UUID.self, forKey: .id),
                kind: try p.decode(TileKind.self, forKey: .kind),
                title: try p.decode(String.self, forKey: .title),
                frame: try p.decode(TileFrame.self, forKey: .frame),
                zIndex: try p.decode(Int.self, forKey: .zIndex)
            )
        case .deleteTile:
            let p = try c.nestedContainer(keyedBy: DeleteTileKeys.self, forKey: .deleteTile)
            self = .deleteTile(id: try p.decode(UUID.self, forKey: .id))
        case .createZone:
            let p = try c.nestedContainer(keyedBy: CreateZoneKeys.self, forKey: .createZone)
            self = .createZone(
                id: try p.decode(UUID.self, forKey: .id),
                projectId: try p.decodeIfPresent(UUID.self, forKey: .projectId),
                origin: try p.decode(ZonePoint.self, forKey: .origin),
                size: try p.decode(ZoneSize.self, forKey: .size),
                name: try p.decode(String.self, forKey: .name),
                color: try p.decode(String.self, forKey: .color)
            )
        case .deleteZone:
            let p = try c.nestedContainer(keyedBy: DeleteZoneKeys.self, forKey: .deleteZone)
            self = .deleteZone(id: try p.decode(UUID.self, forKey: .id))
        case .setTileFrame:
            let p = try c.nestedContainer(keyedBy: SetTileFrameKeys.self, forKey: .setTileFrame)
            self = .setTileFrame(id: try p.decode(UUID.self, forKey: .id), frame: try p.decode(TileFrame.self, forKey: .frame))
        case .setTileZIndex:
            let p = try c.nestedContainer(keyedBy: SetTileZIndexKeys.self, forKey: .setTileZIndex)
            self = .setTileZIndex(id: try p.decode(UUID.self, forKey: .id), zIndex: try p.decode(Int.self, forKey: .zIndex))
        case .setTileTitle:
            let p = try c.nestedContainer(keyedBy: SetTileTitleKeys.self, forKey: .setTileTitle)
            self = .setTileTitle(id: try p.decode(UUID.self, forKey: .id), title: try p.decode(String.self, forKey: .title))
        case .setTileKind:
            let p = try c.nestedContainer(keyedBy: SetTileKindKeys.self, forKey: .setTileKind)
            self = .setTileKind(id: try p.decode(UUID.self, forKey: .id), kind: try p.decode(TileKind.self, forKey: .kind))
        case .setTileCollapsed:
            let p = try c.nestedContainer(keyedBy: SetTileCollapsedKeys.self, forKey: .setTileCollapsed)
            self = .setTileCollapsed(id: try p.decode(UUID.self, forKey: .id), collapsed: try p.decode(Bool.self, forKey: .collapsed))
        case .setZoneOrigin:
            let p = try c.nestedContainer(keyedBy: SetZoneOriginKeys.self, forKey: .setZoneOrigin)
            self = .setZoneOrigin(id: try p.decode(UUID.self, forKey: .id), origin: try p.decode(ZonePoint.self, forKey: .origin))
        case .setZoneSize:
            let p = try c.nestedContainer(keyedBy: SetZoneSizeKeys.self, forKey: .setZoneSize)
            self = .setZoneSize(id: try p.decode(UUID.self, forKey: .id), size: try p.decode(ZoneSize.self, forKey: .size))
        case .setZoneName:
            let p = try c.nestedContainer(keyedBy: SetZoneNameKeys.self, forKey: .setZoneName)
            self = .setZoneName(id: try p.decode(UUID.self, forKey: .id), name: try p.decode(String.self, forKey: .name))
        case .setZoneColor:
            let p = try c.nestedContainer(keyedBy: SetZoneColorKeys.self, forKey: .setZoneColor)
            self = .setZoneColor(id: try p.decode(UUID.self, forKey: .id), color: try p.decode(String.self, forKey: .color))
        case .setZoneCollapsed:
            let p = try c.nestedContainer(keyedBy: SetZoneCollapsedKeys.self, forKey: .setZoneCollapsed)
            self = .setZoneCollapsed(id: try p.decode(UUID.self, forKey: .id), collapsed: try p.decode(Bool.self, forKey: .collapsed))
        case .setZoneProjectId:
            let p = try c.nestedContainer(keyedBy: SetZoneProjectIdKeys.self, forKey: .setZoneProjectId)
            self = .setZoneProjectId(id: try p.decode(UUID.self, forKey: .id), projectId: try p.decodeIfPresent(UUID.self, forKey: .projectId))
        case .setZonePosition:
            let p = try c.nestedContainer(keyedBy: SetZonePositionKeys.self, forKey: .setZonePosition)
            self = .setZonePosition(id: try p.decode(UUID.self, forKey: .id), position: try p.decode(FracIndex.self, forKey: .position))
        case .setTileZone:
            let p = try c.nestedContainer(keyedBy: SetTileZoneKeys.self, forKey: .setTileZone)
            self = .setTileZone(tileId: try p.decode(UUID.self, forKey: .tileId), zoneId: try p.decodeIfPresent(UUID.self, forKey: .zoneId))
        case .setLastActiveTile:
            let p = try c.nestedContainer(keyedBy: SetLastActiveTileKeys.self, forKey: .setLastActiveTile)
            self = .setLastActiveTile(id: try p.decodeIfPresent(UUID.self, forKey: .id))
        case .setLastActiveZone:
            let p = try c.nestedContainer(keyedBy: SetLastActiveZoneKeys.self, forKey: .setLastActiveZone)
            self = .setLastActiveZone(id: try p.decodeIfPresent(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .createTile(id, kind, title, frame, zIndex):
            var p = c.nestedContainer(keyedBy: CreateTileKeys.self, forKey: .createTile)
            try p.encode(id, forKey: .id)
            try p.encode(kind, forKey: .kind)
            try p.encode(title, forKey: .title)
            try p.encode(frame, forKey: .frame)
            try p.encode(zIndex, forKey: .zIndex)
        case let .deleteTile(id):
            var p = c.nestedContainer(keyedBy: DeleteTileKeys.self, forKey: .deleteTile)
            try p.encode(id, forKey: .id)
        case let .createZone(id, projectId, origin, size, name, color):
            var p = c.nestedContainer(keyedBy: CreateZoneKeys.self, forKey: .createZone)
            try p.encode(id, forKey: .id)
            try p.encodeIfPresent(projectId, forKey: .projectId)
            try p.encode(origin, forKey: .origin)
            try p.encode(size, forKey: .size)
            try p.encode(name, forKey: .name)
            try p.encode(color, forKey: .color)
        case let .deleteZone(id):
            var p = c.nestedContainer(keyedBy: DeleteZoneKeys.self, forKey: .deleteZone)
            try p.encode(id, forKey: .id)
        case let .setTileFrame(id, frame):
            var p = c.nestedContainer(keyedBy: SetTileFrameKeys.self, forKey: .setTileFrame)
            try p.encode(id, forKey: .id)
            try p.encode(frame, forKey: .frame)
        case let .setTileZIndex(id, zIndex):
            var p = c.nestedContainer(keyedBy: SetTileZIndexKeys.self, forKey: .setTileZIndex)
            try p.encode(id, forKey: .id)
            try p.encode(zIndex, forKey: .zIndex)
        case let .setTileTitle(id, title):
            var p = c.nestedContainer(keyedBy: SetTileTitleKeys.self, forKey: .setTileTitle)
            try p.encode(id, forKey: .id)
            try p.encode(title, forKey: .title)
        case let .setTileKind(id, kind):
            var p = c.nestedContainer(keyedBy: SetTileKindKeys.self, forKey: .setTileKind)
            try p.encode(id, forKey: .id)
            try p.encode(kind, forKey: .kind)
        case let .setTileCollapsed(id, collapsed):
            var p = c.nestedContainer(keyedBy: SetTileCollapsedKeys.self, forKey: .setTileCollapsed)
            try p.encode(id, forKey: .id)
            try p.encode(collapsed, forKey: .collapsed)
        case let .setZoneOrigin(id, origin):
            var p = c.nestedContainer(keyedBy: SetZoneOriginKeys.self, forKey: .setZoneOrigin)
            try p.encode(id, forKey: .id)
            try p.encode(origin, forKey: .origin)
        case let .setZoneSize(id, size):
            var p = c.nestedContainer(keyedBy: SetZoneSizeKeys.self, forKey: .setZoneSize)
            try p.encode(id, forKey: .id)
            try p.encode(size, forKey: .size)
        case let .setZoneName(id, name):
            var p = c.nestedContainer(keyedBy: SetZoneNameKeys.self, forKey: .setZoneName)
            try p.encode(id, forKey: .id)
            try p.encode(name, forKey: .name)
        case let .setZoneColor(id, color):
            var p = c.nestedContainer(keyedBy: SetZoneColorKeys.self, forKey: .setZoneColor)
            try p.encode(id, forKey: .id)
            try p.encode(color, forKey: .color)
        case let .setZoneCollapsed(id, collapsed):
            var p = c.nestedContainer(keyedBy: SetZoneCollapsedKeys.self, forKey: .setZoneCollapsed)
            try p.encode(id, forKey: .id)
            try p.encode(collapsed, forKey: .collapsed)
        case let .setZoneProjectId(id, projectId):
            var p = c.nestedContainer(keyedBy: SetZoneProjectIdKeys.self, forKey: .setZoneProjectId)
            try p.encode(id, forKey: .id)
            try p.encodeIfPresent(projectId, forKey: .projectId)
        case let .setZonePosition(id, position):
            var p = c.nestedContainer(keyedBy: SetZonePositionKeys.self, forKey: .setZonePosition)
            try p.encode(id, forKey: .id)
            try p.encode(position, forKey: .position)
        case let .setTileZone(tileId, zoneId):
            var p = c.nestedContainer(keyedBy: SetTileZoneKeys.self, forKey: .setTileZone)
            try p.encode(tileId, forKey: .tileId)
            try p.encodeIfPresent(zoneId, forKey: .zoneId)
        case let .setLastActiveTile(id):
            var p = c.nestedContainer(keyedBy: SetLastActiveTileKeys.self, forKey: .setLastActiveTile)
            try p.encodeIfPresent(id, forKey: .id)
        case let .setLastActiveZone(id):
            var p = c.nestedContainer(keyedBy: SetLastActiveZoneKeys.self, forKey: .setLastActiveZone)
            try p.encodeIfPresent(id, forKey: .id)
        }
    }
}

// MARK: - LoggedOp

/// The unit of sync: one record per operation, self-contained, orderable,
/// idempotent on replay.
public struct LoggedOp: Codable, Sendable, Equatable {
    public var opId: OpId
    public var op: Op

    public init(opId: OpId, op: Op) {
        self.opId = opId
        self.op = op
    }
}
