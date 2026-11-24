import AppKit
import ContinuumRevivedCore
import Foundation

/// Where a surfaced helper's tile opens, and how big: one answer for every
/// route that gives a helper a tile (the sidebar pop-out, an inbox or chip
/// reveal, `agent.delegate`'s presentation).
///
/// The tile is square, as tall as its lead, in the next free slot of the
/// lead's helper group (`TileSpawnPlacement.helperGroupSlot`): rows of squares
/// at the lead's right, then below. Under auto layout only the group itself is
/// a wall; any other member of the zone in the slot is pushed aside by the
/// spawn's pinned settle (`arrangeAutoLayoutAfterSpawn`), along one axis, by
/// the minimum, and the zone grows to keep it. With auto layout off nothing may
/// move, so the slot must be clear of every tile and inside the zone; a group
/// with no such slot leaves the point nil and the zone's automatic placement
/// decides, still at the square size.
///
/// World frames throughout; the caller frames, dodges, z-orders and installs
/// against the same `zoneId` (hazard 9).
@MainActor
enum HelperTilePlacement {
    static func besideLead(
        canvas: CanvasNSView, zoneId: UUID, leadTileId: UUID, familyTileIds: Set<UUID>
    ) -> (center: CGPoint?, size: CGSize)? {
        guard let zone = canvas.installedZonePlacement(for: zoneId),
              let lead = canvas.navigationTileSnapshot(for: leadTileId)?.worldFrame else { return nil }
        let side = TileSpawnPlacement.helperSide(lead: lead, minimum: CanvasEngine.minimumFrame(for: .managedAgent))
        let gap = TileGapResolver.resolvedGap(defaults: canvas.autoLayoutDefaults)
        let zoneTiles = canvas.tilesInWorldFrames(forZoneId: zoneId) ?? []
        let slot: TileFrame?
        if canvas.isAutoLayoutActive(inZone: zoneId) {
            let group = zoneTiles.filter { familyTileIds.contains($0.id) || $0.id == leadTileId }.map(\.frame)
            slot = TileSpawnPlacement.firstFreeHelperSlot(lead: lead, side: side, occupied: group, gap: gap)
        } else {
            let zoneRect = CGRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
            slot = TileSpawnPlacement.firstFreeHelperSlot(
                lead: lead, side: side, occupied: zoneTiles.map(\.frame), gap: gap,
                allowed: { zoneRect.contains(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) })
        }
        return (slot.map { CGPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) },
                CGSize(width: side, height: side))
    }
}
