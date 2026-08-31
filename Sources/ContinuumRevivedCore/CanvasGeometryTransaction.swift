import Foundation

private func geometryFirstWinsDictionary<Key: Hashable, Value>(
    _ pairs: some Sequence<(Key, Value)>
) -> [Key: Value] {
    var result: [Key: Value] = [:]
    for (key, value) in pairs where result[key] == nil { result[key] = value }
    return result
}

/// The user-visible geometry operations that may participate in canvas undo.
/// Viewport navigation and entity lifecycle deliberately do not appear here.
public enum CanvasGeometryAction: String, Codable, Equatable, Sendable {
    case moveTile
    case resizeTile
    case dockTile
    case resizeTileToPreset
    case moveZone
    case resizeZone
    case tidy
    case autoLayout

    public var displayName: String {
        switch self {
        case .moveTile: return "Move Tile"
        case .resizeTile: return "Resize Tile"
        case .dockTile: return "Dock Tile"
        case .resizeTileToPreset: return "Resize Tile"
        case .moveZone: return "Move Zone"
        case .resizeZone: return "Resize Zone"
        case .tidy: return "Tidy Canvas"
        case .autoLayout: return "Auto Layout"
        }
    }
}

/// The complete undoable geometry carried by one tile. Keeping membership beside
/// the frame makes a drag across a zone boundary one atomic user action.
public struct CanvasTileGeometry: Codable, Equatable, Sendable {
    public var tileId: UUID
    public var frame: TileFrame
    public var zoneId: UUID?

    public init(tileId: UUID, frame: TileFrame, zoneId: UUID?) {
        self.tileId = tileId
        self.frame = frame
        self.zoneId = zoneId
    }
}

/// Only placement belongs to geometry history. Names, colors, collapse state,
/// hydration policy and z-order are intentionally preserved when undo applies.
public struct CanvasZoneGeometry: Codable, Equatable, Sendable {
    public var zoneId: UUID
    public var origin: ZonePoint
    public var size: ZoneSize

    public init(zoneId: UUID, origin: ZonePoint, size: ZoneSize) {
        self.zoneId = zoneId
        self.origin = origin
        self.size = size
    }
}

public struct CanvasGeometrySnapshot: Codable, Equatable, Sendable {
    public var tiles: [CanvasTileGeometry]
    public var zones: [CanvasZoneGeometry]

    public init(tiles: [CanvasTileGeometry], zones: [CanvasZoneGeometry]) {
        self.tiles = tiles.sorted { $0.tileId.uuidString < $1.tileId.uuidString }
        self.zones = zones.sorted { $0.zoneId.uuidString < $1.zoneId.uuidString }
    }
}

/// One semantic canvas edit. `before` and `after` contain only fields touched by
/// the edit, so applying either side cannot rewind unrelated canvas state.
public struct CanvasGeometryTransaction: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: CanvasGeometryAction
    public let before: CanvasGeometrySnapshot
    public let after: CanvasGeometrySnapshot

    public init(
        id: UUID = UUID(),
        action: CanvasGeometryAction,
        before: CanvasGeometrySnapshot,
        after: CanvasGeometrySnapshot
    ) {
        self.id = id
        self.action = action
        self.before = before
        self.after = after
    }

    public var isNoOp: Bool { before == after }

    public var changedEntityCount: Int {
        let beforeTiles = geometryFirstWinsDictionary(before.tiles.map { ($0.tileId, $0) })
        let beforeZones = geometryFirstWinsDictionary(before.zones.map { ($0.zoneId, $0) })
        let afterTiles = geometryFirstWinsDictionary(after.tiles.map { ($0.tileId, $0) })
        let afterZones = geometryFirstWinsDictionary(after.zones.map { ($0.zoneId, $0) })
        let changedTiles = afterTiles.lazy.filter { beforeTiles[$0.key] != $0.value }.count
        let changedZones = afterZones.lazy.filter { beforeZones[$0.key] != $0.value }.count
        return changedTiles + changedZones
    }
}
