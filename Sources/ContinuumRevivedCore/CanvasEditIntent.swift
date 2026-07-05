import Foundation

// Ticket: docs/38-tickets/61b-canvas-editor.md
//
// Pure gesture-end→Op helpers for the iOS canvas editor. No mid-drag ops:
// every helper here corresponds to exactly one op emitted on gesture end.

public enum CanvasEditIntent {
    /// Drag-end: the tile's final `TileFrame` after a move.
    public static func moveEnded(tile: UUID, to frame: TileFrame) -> Op {
        .setTileFrame(id: tile, frame: frame)
    }

    /// Resize-end: `setTileFrame` carries both position and size, so a resize
    /// gesture end produces the identical op shape as a move.
    public static func resizeEnded(tile: UUID, to frame: TileFrame) -> Op {
        .setTileFrame(id: tile, frame: frame)
    }

    /// The topmost zone (by the same `(zPosition, zoneId)` ascending order
    /// `CanvasSceneProjection`/`zonesInZOrder` render in — the LAST element in
    /// that order is frontmost) whose frame contains `point`, or nil if the
    /// point is outside every zone (an ambient drop).
    public static func dropTarget(point: ZonePoint, zones: [CanvasSceneZone]) -> UUID? {
        zones
            .filter { zone in
                point.x >= zone.origin.x && point.x <= zone.origin.x + zone.size.width
                    && point.y >= zone.origin.y && point.y <= zone.origin.y + zone.size.height
            }
            .sorted { lhs, rhs in
                if lhs.zPosition != rhs.zPosition { return lhs.zPosition < rhs.zPosition }
                return lhs.zoneId.uuidString < rhs.zoneId.uuidString
            }
            .last?.zoneId
    }

    /// The op a drop-into/out-of-zone gesture end produces (membership is an
    /// LWW register ON the tile, per D3 — no zone-side list to repair).
    public static func setZone(tile: UUID, zoneId: UUID?) -> Op {
        .setTileZone(tileId: tile, zoneId: zoneId)
    }

    /// The full ordered op list for a drag-drop gesture end: the move, then
    /// (only if the drop-target zone — resolved via `dropTarget(point:zones:)`
    /// at the dropped frame's center — differs from `currentZoneId`) the
    /// membership change. Pure and side-effect-free: callers are responsible
    /// for sending the ops in order and stopping at the first failure
    /// (`SpatialOpReceiver.emitAll`), so a completed move without its
    /// membership change is a valid state and never silently reordered.
    public static func moveDropOps(tile: UUID, currentZoneId: UUID?, to frame: TileFrame, zones: [CanvasSceneZone]) -> [Op] {
        var ops: [Op] = [moveEnded(tile: tile, to: frame)]
        let center = ZonePoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        let target = dropTarget(point: center, zones: zones)
        if target != currentZoneId {
            ops.append(setZone(tile: tile, zoneId: target))
        }
        return ops
    }

    /// Bring-to-front: `setTileZIndex` with `FracIndex.after(frontmost)` —
    /// never lowers an already-frontmost tile (04 doctrine; mirrors
    /// `WorkspaceDocument.bringZoneToFront`'s no-op-when-already-front guard).
    /// Returns nil when the tile is unknown or already strictly frontmost.
    public static func bringToFront(tile: UUID, scene: CanvasScene) -> Op? {
        guard scene.tiles.contains(where: { $0.tileId == tile }) else { return nil }
        guard let current = scene.tiles.first(where: { $0.tileId == tile })?.zPosition else { return nil }
        let othersMax = scene.tiles.filter { $0.tileId != tile }.map(\.zPosition).max()
        guard let othersMax else { return nil }        // only tile on the canvas — already front
        guard current <= othersMax else { return nil }  // already strictly frontmost
        return .setTileZIndex(id: tile, z: FracIndex.after(othersMax))
    }

    /// The scope predicate gating every editing gesture: only `.orchestrationOperate`
    /// may mutate spatial state. Observer scope is read-only + a lock badge.
    public static func isEditingPermitted(scope: Scope) -> Bool {
        scope.contains(.orchestrationOperate)
    }
}
