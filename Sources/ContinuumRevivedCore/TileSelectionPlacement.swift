import CoreGraphics
import Foundation

/// Runs a selection through the ordinary layout solver as one rigid envelope
/// per source zone. The envelope conservatively pushes residents even through
/// empty spaces between selected tiles; selected members never push each other.
public enum TileSelectionPlacement {
    public static func solve(
        scene: CanvasAutoLayoutEngine.Scene,
        frames: [UUID: TileFrame],
        gap: Double,
        zonePadding: Double,
        headerHeight: Double,
        latched: CanvasAutoLayoutEngine.MoveLatch? = nil,
        pointer: CGPoint? = nil,
        preferSwap: Bool = false,
        settle: Bool = false,
        honorSnap: Bool = false
    ) -> CanvasLayoutTransaction {
        // The first occurrence is the scene owner's authoritative occurrence,
        // matching the underlying solver's treatment of duplicate identities.
        var baseline: [UUID: CanvasAutoLayoutEngine.LayoutTile] = [:]
        for tile in scene.tiles where baseline[tile.id] == nil { baseline[tile.id] = tile }
        let selected = Set(frames.keys.filter { baseline[$0] != nil })
        var absolute = baseline.mapValues(\.frame)
        for id in selected { absolute[id] = frames[id] }
        var result = CanvasLayoutTransaction(tileFrames: absolute)
        guard !selected.isEmpty else { return result }

        var groups: [UUID: [UUID]] = [:]
        for id in selected {
            if let zoneId = baseline[id]?.zoneId { groups[zoneId, default: []].append(id) }
        }
        let oneZone = groups.count == 1 && groups.values.first?.count == selected.count
        let residents = scene.tiles.filter { !selected.contains($0.id) }
        for zoneId in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let ids = groups[zoneId]?.sorted(by: { $0.uuidString < $1.uuidString }),
                  let proxyId = ids.first,
                  let original = envelope(ids.compactMap { baseline[$0]?.frame }),
                  let requested = envelope(ids.compactMap { frames[$0] }) else { continue }
            // Reuse a selected identity only inside this temporary scene. No
            // synthetic tile or membership can reach the persistence boundary.
            let proxy = CanvasAutoLayoutEngine.LayoutTile(
                id: proxyId, frame: settle ? requested : original, zoneId: zoneId,
                minimumSize: CGSize(width: requested.width, height: requested.height))
            let virtualScene = CanvasAutoLayoutEngine.Scene(
                tiles: residents + [proxy], zones: scene.zones, globalEnabled: scene.globalEnabled)
            // A multi-zone selection has one authoritative requested translation.
            // Pointing inside the baseline envelope suppresses slot latching,
            // so each zone can push residents without snapping its subset apart.
            let probe = oneZone ? pointer : CGPoint(x: original.x + original.width / 2,
                                                    y: original.y + original.height / 2)
            let mutation: CanvasAutoLayoutEngine.Mutation = settle
                ? .settle(zoneId: zoneId, anchor: proxyId, pin: oneZone ? honorSnap : true)
                : .tile(id: proxyId, frame: requested)
            let solved = CanvasAutoLayoutEngine.solve(
                scene: virtualScene, mutation: mutation,
                gap: gap, zonePadding: zonePadding, headerHeight: headerHeight,
                latched: oneZone ? latched : nil, pointer: probe,
                preferSwap: oneZone && preferSwap)
            for (id, frame) in solved.tileFrames where !selected.contains(id) {
                result.tileFrames[id] = frame
            }
            for (id, placement) in solved.zonePlacements { result.zonePlacements[id] = placement }
            result.blockedZoneIds.formUnion(solved.blockedZoneIds)
            if oneZone {
                let landed = solved.tileFrames[proxyId] ?? requested
                let dx = landed.x - requested.x
                let dy = landed.y - requested.y
                for id in ids {
                    guard var frame = frames[id] else { continue }
                    frame.x += dx
                    frame.y += dy
                    result.tileFrames[id] = frame
                }
                if !settle {
                    result.moveLatch = solved.moveLatch
                    result.latchedSlot = solved.latchedSlot
                }
            }
        }
        // Membership stays source-owned. Unzoned members retain their requested
        // frames, and no intermediate proxy membership is published.
        return result
    }

    private static func envelope(_ frames: [TileFrame]) -> TileFrame? {
        guard let first = frames.first else { return nil }
        var left = first.x
        var top = first.y
        var right = first.x + first.width
        var bottom = first.y + first.height
        for frame in frames.dropFirst() {
            left = min(left, frame.x)
            top = min(top, frame.y)
            right = max(right, frame.x + frame.width)
            bottom = max(bottom, frame.y + frame.height)
        }
        return TileFrame(x: left, y: top, width: right - left, height: bottom - top)
    }
}
