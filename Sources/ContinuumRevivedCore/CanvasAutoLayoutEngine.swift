import CoreGraphics
import Foundation

private func autoLayoutFirstWinsDictionary<Key: Hashable, Value>(
    _ pairs: some Sequence<(Key, Value)>
) -> [Key: Value] {
    var result: [Key: Value] = [:]
    for (key, value) in pairs where result[key] == nil { result[key] = value }
    return result
}

public struct CanvasLayoutTransaction: Equatable, Sendable {
    public var tileFrames: [UUID: TileFrame]
    public var zonePlacements: [UUID: ZonePlacement]
    public var blockedZoneIds: Set<UUID>
    /// What the active move gesture is latched to: a sibling it exchanges
    /// slots with, or a slot in a row it slides into. Gesture state: the caller
    /// feeds it back into the next frame's solve as `latched` so the latch is
    /// hysteretic instead of re-derived from jittery per-frame geometry.
    public var moveLatch: CanvasAutoLayoutEngine.MoveLatch?
    /// Where the dragged tile lands if dropped now (WORLD), while latched.
    public var latchedSlot: TileFrame?
    public var swapTargetTileId: UUID? {
        if case let .swap(id) = moveLatch { return id }
        return nil
    }
    /// The zone each committed tile belongs to, alongside its frame: a drop into
    /// another zone changes membership in the same commit as geometry, and a
    /// writer that persisted the frame alone left the old stamp on disk.
    public var tileZoneIds: [UUID: UUID]

    public init(tileFrames: [UUID: TileFrame] = [:], zonePlacements: [UUID: ZonePlacement] = [:], blockedZoneIds: Set<UUID> = [], moveLatch: CanvasAutoLayoutEngine.MoveLatch? = nil, latchedSlot: TileFrame? = nil, tileZoneIds: [UUID: UUID] = [:]) {
        self.tileFrames = tileFrames
        self.zonePlacements = zonePlacements
        self.blockedZoneIds = blockedZoneIds
        self.moveLatch = moveLatch
        self.latchedSlot = latchedSlot
        self.tileZoneIds = tileZoneIds
    }
}

/// Deterministic world-space rectangle solver. Valid hand-positioned frames stay
/// where they are; only containment, collision, or a sub-preferred gap moves them.
public enum CanvasAutoLayoutEngine {
    public struct LayoutTile: Equatable, Sendable {
        public var id: UUID
        public var frame: TileFrame
        public var zoneId: UUID?
        public var minimumSize: CGSize
        /// What the tile is: the shape an explicit Tidy gives it
        /// (`TileGeometry.shapeRule`). Nil reads as a loose band.
        public var kind: TileKind?
        /// The lead agent's tile id, on the lead and on each helper. Only an
        /// explicit Tidy reads it, and only the Tidy entry point fills it in.
        public var clusterLead: UUID?

        public init(id: UUID, frame: TileFrame, zoneId: UUID?, minimumSize: CGSize? = nil, kind: TileKind? = nil, clusterLead: UUID? = nil) {
            self.id = id
            self.frame = frame
            self.zoneId = zoneId
            self.minimumSize = minimumSize ?? CGSize(width: frame.width, height: frame.height)
            self.kind = kind
            self.clusterLead = clusterLead
        }
    }

    public struct Scene: Equatable, Sendable {
        public var tiles: [LayoutTile]
        public var zones: [ZonePlacement]
        public var globalEnabled: Bool

        public init(tiles: [LayoutTile], zones: [ZonePlacement], globalEnabled: Bool = true) {
            self.tiles = tiles
            self.zones = zones
            self.globalEnabled = globalEnabled
        }
    }

    public enum Mutation: Equatable, Sendable {
        case tile(id: UUID, frame: TileFrame)
        case zone(id: UUID, placement: ZonePlacement)
        case tidy(zoneId: UUID?)
        /// Rest-state magnetism: pull every member of `zoneId` into exact
        /// gap-contact with the cluster. `anchor` is a just-moved tile that
        /// settles LAST, so the composition it was dropped into wins over its
        /// exact drop point. `pin` marks the anchor's position authoritative
        /// (a completed slot exchange): the anchor never relocates — residents
        /// it presses on are pushed aside instead, so a horizontal exchange can
        /// never resolve into a different lane.
        /// `grow` is a SPAWN: the unpinned anchor is a new tile the placement put
        /// where the camera is looking, possibly outside the zone, and the
        /// caller grows the zone around wherever it settles, in any direction.
        /// It is never clamped into the zone first. If it already sits at gap
        /// contact with a member and overlaps nothing it stays exactly there;
        /// otherwise it takes the contact slot most visible in `view` (WORLD),
        /// then the one nearest its placement. A neighbour the growth runs into
        /// is pushed afterwards (`pushPeers(ofGrownZone:)`).
        case settle(zoneId: UUID, anchor: UUID?, pin: Bool, grow: Bool = false, view: TileFrame? = nil)
    }

    /// What a member move is latched to.
    public enum MoveLatch: Equatable, Sendable {
        /// Exchange origins with this sibling: the pointer is over its middle
        /// half, or ⌥ is held over any part of it.
        case swap(UUID)
        /// Slide into row `row` (of `memberRows`, from the gesture baseline,
        /// without the dragged tile) before its `index`th tile: the row's
        /// other tiles reflow around an empty slot for the dragged one.
        case insert(row: Int, index: Int)
    }

    /// `pointer` (WORLD) is where the user is pointing during a member move.
    /// Without one the dragged tile's centre stands in and the move can only
    /// swap, never slide in between. `preferSwap` is ⌥: swap only.
    public static func solve(scene: Scene, mutation: Mutation, gap preferredGap: Double, zonePadding preferredPadding: Double, headerHeight: Double, latched: MoveLatch? = nil, pointer: CGPoint? = nil, preferSwap: Bool = false, pointerSpeed: Double? = nil, previousFrames: [UUID: TileFrame]? = nil, interactive: Set<UUID>? = nil) -> CanvasLayoutTransaction {
        let gap = max(0, preferredGap.isFinite ? preferredGap : 0)
        let padding = max(0, preferredPadding.isFinite ? preferredPadding : 0)
        let header = max(0, headerHeight.isFinite ? headerHeight : 0)
        var tiles = autoLayoutFirstWinsDictionary(scene.tiles.map { ($0.id, $0) })
        var zones = autoLayoutFirstWinsDictionary(scene.zones.map { ($0.zoneId, $0) })
        var activeTile: UUID?
        var activeZone: UUID?
        var activeZoneOnlyTranslated = false
        var activeTileResizeIsHorizontal: Bool?
        var activeTileOriginalFrame: TileFrame?
        var activeTileMovedWithoutResize = false

        switch mutation {
        case let .tile(id, frame):
            if var tile = tiles[id] {
                activeTileOriginalFrame = tile.frame
                let widthDelta = abs(frame.width - tile.frame.width)
                let heightDelta = abs(frame.height - tile.frame.height)
                if widthDelta > 0.001 || heightDelta > 0.001 {
                    activeTileResizeIsHorizontal = widthDelta >= heightDelta
                } else {
                    activeTileMovedWithoutResize = abs(frame.x - tile.frame.x) > 0.001 || abs(frame.y - tile.frame.y) > 0.001
                }
                tile.frame = frame
                tiles[id] = tile
                activeTile = id
            }
        case let .zone(id, placement):
            if let previous = zones[id] {
                let originDX = placement.origin.x - previous.origin.x
                let originDY = placement.origin.y - previous.origin.y
                activeZoneOnlyTranslated = placement.size == previous.size
                    && (originDX != 0 || originDY != 0)
                if activeZoneOnlyTranslated && (originDX != 0 || originDY != 0) {
                    for tileId in tiles.keys where tiles[tileId]?.zoneId == id {
                        tiles[tileId]?.frame.x += originDX
                        tiles[tileId]?.frame.y += originDY
                    }
                }
            }
            zones[id] = placement
            activeZone = id
        case .tidy, .settle:
            break
        }

        let targetZoneIds: [UUID]
        switch mutation {
        case let .tidy(zoneId): targetZoneIds = zoneId.map { [$0] } ?? zones.keys.sorted(by: uuidLess)
        case let .settle(zoneId, _, _, _, _): targetZoneIds = [zoneId]
        case let .zone(id, _): targetZoneIds = [id]
        case let .tile(id, _): targetZoneIds = tiles[id]?.zoneId.map { [$0] } ?? []
        }

        // Resize pressure preserves dimensions and propagates only along the
        // expanding edges. Every solve starts from the gesture baseline.
        if let activeTile, activeTileResizeIsHorizontal != nil,
           let zoneId = tiles[activeTile]?.zoneId, var zone = zones[zoneId] {
            if zone.autoLayoutMode.resolves(globalEnabled: scene.globalEnabled), !zone.collapsed,
               let original = activeTileOriginalFrame, let requested = tiles[activeTile]?.frame {
                let members = scene.tiles.filter { $0.zoneId == zoneId }
                let pushed = resizeMembers(members, active: activeTile, original: original, requested: requested, gap: gap)
                for (id, frame) in pushed { tiles[id]?.frame = frame }
            }
            let members = tiles.values.filter { $0.zoneId == zoneId }.map(\.frame)
            if let first = members.first {
                let minX = members.dropFirst().reduce(first.x) { min($0, $1.x) }
                let minY = members.dropFirst().reduce(first.y) { min($0, $1.y) }
                let maxX = members.reduce(first.x + first.width) { max($0, $1.x + $1.width) }
                let maxY = members.reduce(first.y + first.height) { max($0, $1.y + $1.height) }
                let left = min(zone.origin.x, minX - padding)
                let top = min(zone.origin.y, minY - header - padding)
                let right = max(zone.origin.x + zone.size.width, maxX + padding)
                let bottom = max(zone.origin.y + zone.size.height, maxY + padding)
                zone.origin = ZonePoint(x: left, y: top)
                zone.size = ZoneSize(width: right - left, height: bottom - top)
                zones[zoneId] = zone
            }
            var result = CanvasLayoutTransaction()
            for original in scene.tiles where tiles[original.id]?.frame != original.frame {
                result.tileFrames[original.id] = tiles[original.id]?.frame
            }
            if let original = scene.zones.first(where: { $0.zoneId == zoneId }), zone != original {
                result.zonePlacements[zoneId] = zone
            }
            return result
        }

        // A manual zone resize clamps only the dragged container through the
        // padded member envelope. Members, peer zones, and outside tiles are
        // immutable; outward overlap is allowed.
        if let activeZone, !activeZoneOnlyTranslated, var zone = zones[activeZone],
           let original = scene.zones.first(where: { $0.zoneId == activeZone }),
           zone.size != original.size {
            let members = scene.tiles.filter { $0.zoneId == activeZone }.map(\.frame)
            if let first = members.first {
                let minX = members.dropFirst().reduce(first.x) { min($0, $1.x) }
                let minY = members.dropFirst().reduce(first.y) { min($0, $1.y) }
                let maxX = members.reduce(first.x + first.width) { max($0, $1.x + $1.width) }
                let maxY = members.reduce(first.y + first.height) { max($0, $1.y + $1.height) }
                let left = min(zone.origin.x, minX - padding)
                let top = min(zone.origin.y, minY - header - padding)
                let right = max(zone.origin.x + zone.size.width, maxX + padding)
                let bottom = max(zone.origin.y + zone.size.height, maxY + padding)
                zone.origin = ZonePoint(x: left, y: top)
                zone.size = ZoneSize(width: right - left, height: bottom - top)
            }
            return CanvasLayoutTransaction(zonePlacements: zone == original ? [:] : [activeZone: zone])
        }

        var blocked: Set<UUID> = []
        var newLatch: MoveLatch?
        var newSlot: TileFrame?
        for zoneId in targetZoneIds {
            let explicitTidy: Bool
            if case .tidy = mutation { explicitTidy = true } else { explicitTidy = false }
            guard var zone = zones[zoneId], !zone.collapsed,
                  explicitTidy || zone.autoLayoutMode.resolves(globalEnabled: scene.globalEnabled) else { continue }
            // A zone is a rigid body while it is moved. Its members already received
            // the exact origin delta above; repacking here would make a simple move
            // unexpectedly alter the composition inside the zone.
            if zoneId == activeZone, activeZoneOnlyTranslated { continue }
            let memberIds = tiles.values.filter { $0.zoneId == zoneId }.map(\.id).sorted(by: uuidLess)
            guard !memberIds.isEmpty else { continue }

            // Rest-state magnetism: tidy and settle pull members into exact
            // gap-contact with the cluster instead of running the packer.
            var settleMover: (mover: UUID?, pin: Bool, grow: Bool, view: TileFrame?)?
            if case let .settle(_, anchor, pin, grow, view) = mutation { settleMover = (anchor, pin, grow, view) }
            if explicitTidy {
                // The packer's frames sit on its 1/64 pt grid; so must the
                // origin they are made zone-local against (moves ≤ 1/128 pt).
                let snappedOrigin = ZonePoint(x: (zone.origin.x / CanvasTidyPacker.grid).rounded() * CanvasTidyPacker.grid,
                                              y: (zone.origin.y / CanvasTidyPacker.grid).rounded() * CanvasTidyPacker.grid)
                if snappedOrigin != zone.origin { zone.origin = snappedOrigin; zones[zoneId] = zone }
                let content = contentRect(zone: zone, padding: padding, header: header)
                let packed = CanvasTidyPacker.pack(
                    members: memberIds.compactMap { id in tiles[id].map {
                        CanvasTidyPacker.Member(id: id, frame: $0.frame, kind: $0.kind,
                                                minimumSize: $0.minimumSize, clusterLead: $0.clusterLead)
                    } },
                    content: content, gap: gap)
                // A tidy of a tidy zone re-solves to within a grid step of where
                // everything already is: that is no change, and reports nothing.
                // All or nothing, so old and new frames never mix.
                let size = ZoneSize(width: Double(packed.content.maxX) + padding - zone.origin.x,
                                    height: Double(packed.content.maxY) + padding - zone.origin.y)
                let unchanged = abs(size.width - zone.size.width) <= tidyTolerance
                    && abs(size.height - zone.size.height) <= tidyTolerance
                    && packed.frames.allSatisfy { id, frame in tiles[id].map { nearlyEqual($0.frame, frame) } ?? true }
                if unchanged {
                    if let original = scene.zones.first(where: { $0.zoneId == zoneId }) { zones[zoneId] = original }
                    continue
                }
                for (id, frame) in packed.frames { tiles[id]?.frame = frame }
                zone.size = size
                zones[zoneId] = zone
                continue
            }
            if let (mover, pin, grow, view) = settleMover {
                let settled = settleMembers(
                    memberIds: memberIds, tiles: tiles, zone: zone,
                    gap: gap, padding: padding, header: header, mover: mover, pinMover: pin,
                    growMover: grow, view: view)
                for (id, frame) in settled { tiles[id]?.frame = frame }
                continue
            }

            // A member MOVE never repacks the zone. The active tile is
            // pointer-owned; siblings only ever receive minimal single-axis
            // pushes or take part in an explicit, latched slot exchange.
            if activeTileMovedWithoutResize,
               let activeTile, let original = activeTileOriginalFrame,
               tiles[activeTile]?.zoneId == zoneId {
                let outcome = solveMemberMove(
                    activeTile: activeTile, originalFrame: original,
                    memberIds: memberIds, tiles: tiles, zone: zone,
                    gap: gap, padding: padding, header: header,
                    latched: latched, pointer: pointer, preferSwap: preferSwap, pointerSpeed: pointerSpeed,
                    previous: previousFrames, interactive: interactive)
                for (id, frame) in outcome.frames { tiles[id]?.frame = frame }
                newLatch = outcome.latch
                newSlot = outcome.slot
                continue
            }

            let activeResizeHere = activeTileResizeIsHorizontal != nil
                && activeTile.map { tiles[$0]?.zoneId == zoneId } == true
            // Zones are never affected by tiles except through resize pressure:
            // a .tile mutation that isn't a resize here (a no-op update; moves
            // already returned above) must not reach the packer, whose zone
            // clamp could reshape the zone.
            if case .tile = mutation, !activeResizeHere { continue }
            if !activeResizeHere {
                let minimum = minimumFeasibleSize(memberIds: memberIds, tiles: tiles, proposed: zone, header: header)
                if zone.size.width < minimum.width || zone.size.height < minimum.height {
                    blocked.insert(zoneId)
                    zone = clampPlacement(zone, previous: scene.zones.first { $0.zoneId == zoneId }, minimum: minimum)
                    zones[zoneId] = zone
                }
            }

            var packed = pack(
                memberIds: memberIds, tiles: tiles, zone: zone, gap: gap, padding: padding,
                header: header, pinned: activeTile, allowPinnedOutside: !activeResizeHere)
            if packed == nil {
                // Restore the configured inter-tile gap whenever the current
                // topology has room for it, even if a perpendicular zone edge
                // still requires compressed padding. Only then compress the gap.
                var low = 0.0, high = gap
                packed = pack(
                    memberIds: memberIds, tiles: tiles, zone: zone, gap: 0, padding: 0,
                    header: header, pinned: activeTile, allowPinnedOutside: !activeResizeHere)
                for _ in 0..<12 {
                    let middle = (low + high) / 2
                    if let result = pack(
                        memberIds: memberIds, tiles: tiles, zone: zone, gap: middle, padding: 0,
                        header: header, pinned: activeTile, allowPinnedOutside: !activeResizeHere) {
                        packed = result
                        low = middle
                    } else {
                        high = middle
                    }
                }
                let resolvedGap = low
                low = 0
                high = padding
                for _ in 0..<12 {
                    let middle = (low + high) / 2
                    if let result = pack(
                        memberIds: memberIds, tiles: tiles, zone: zone, gap: resolvedGap, padding: middle,
                        header: header, pinned: activeTile, allowPinnedOutside: !activeResizeHere) {
                        packed = result
                        low = middle
                    } else {
                        high = middle
                    }
                }
            }
            if packed == nil, activeResizeHere, let horizontal = activeTileResizeIsHorizontal,
               let shrunk = shrinkNeighborsAndPack(
                   memberIds: memberIds, tiles: tiles, zone: zone, padding: 0, header: header,
                   pinned: activeTile, horizontal: horizontal) {
                tiles = shrunk.tiles
                packed = shrunk.frames
            }
            if packed == nil, activeResizeHere {
                // Neighbor minima are exhausted. Grow only now, in the active
                // resize direction, so pressure order is gap → neighbor size → zone.
                for id in memberIds where id != activeTile {
                    guard var tile = tiles[id] else { continue }
                    if activeTileResizeIsHorizontal == true {
                        tile.frame.width = min(tile.frame.width, max(tile.minimumSize.width, 1))
                    } else {
                        tile.frame.height = min(tile.frame.height, max(tile.minimumSize.height, 1))
                    }
                    tiles[id] = tile
                }
                if let expanded = expandZoneAndPack(
                    memberIds: memberIds, tiles: tiles, zone: zone, header: header,
                    pinned: activeTile, horizontal: activeTileResizeIsHorizontal == true) {
                    zone = expanded.zone
                    zones[zoneId] = zone
                    packed = expanded.frames
                }
            }
            if let packed {
                for (id, frame) in packed { tiles[id]?.frame = frame }
            } else {
                blocked.insert(zoneId)
            }
        }

        resolveOuterCollisions(tiles: &tiles, zones: &zones, scene: scene, activeZone: activeZone, preferredGap: gap)

        var result = CanvasLayoutTransaction(blockedZoneIds: blocked, moveLatch: newLatch, latchedSlot: newSlot)
        for original in scene.tiles where tiles[original.id]?.frame != original.frame {
            result.tileFrames[original.id] = tiles[original.id]?.frame
        }
        for original in scene.zones where zones[original.zoneId] != original {
            result.zonePlacements[original.zoneId] = zones[original.zoneId]
        }
        return result
    }

    /// Push outward in baseline order; the zone is deliberately not a wall.
    /// Only the active rectangle and already displaced rectangles transmit force.
    private static func resizeMembers(
        _ members: [LayoutTile], active: UUID, original: TileFrame, requested: TileFrame, gap: Double
    ) -> [UUID: TileFrame] {
        let baseline = autoLayoutFirstWinsDictionary(members.map { ($0.id, $0.frame) })
        var frames = baseline
        frames[active] = requested
        let directions: [(horizontal: Bool, positive: Bool, enabled: Bool)] = [
            (true, true, requested.x + requested.width > original.x + original.width),
            (true, false, requested.x < original.x),
            (false, true, requested.y + requested.height > original.y + original.height),
            (false, false, requested.y < original.y)
        ]
        // Corner pressure can make a new contact on the perpendicular axis.
        // Each directional sweep is topological; repeat until no contact moves.
        for _ in 0..<max(1, members.count) {
            var changed = false
            for (horizontal, positive, enabled) in directions where enabled {
                func start(_ f: TileFrame) -> Double { horizontal ? f.x : f.y }
                func length(_ f: TileFrame) -> Double { horizontal ? f.width : f.height }
                let ordered = baseline.keys.sorted {
                    let a = start(baseline[$0]!), b = start(baseline[$1]!)
                    return a == b ? uuidLess($0, $1) : (positive ? a < b : a > b)
                }
                for source in ordered {
                    guard let a = frames[source], let oldA = baseline[source],
                          source == active || a != oldA else { continue }
                    for target in ordered where target != active && target != source {
                        guard var b = frames[target], let oldB = baseline[target] else { continue }
                        // Do not move tiles in another lane or reverse their baseline order.
                        let beyond = positive
                            ? start(oldB) >= start(oldA) + length(oldA) - 0.001
                            : start(oldB) + length(oldB) <= start(oldA) + 0.001
                        let overlap = horizontal
                            ? min(a.y + a.height, b.y + b.height) > max(a.y, b.y)
                            : min(a.x + a.width, b.x + b.width) > max(a.x, b.x)
                        guard beyond && overlap else { continue }
                        let destination = positive ? start(a) + length(a) + gap : start(a) - gap - length(b)
                        guard positive ? start(b) < destination : start(b) > destination else { continue }
                        if horizontal { b.x = destination } else { b.y = destination }
                        frames[target] = b
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
        return frames
    }

    /// True when the two frames sit edge-to-edge at approximately `gap` on one
    /// axis with real overlap on the other — the canvas's definition of
    /// "attached". Attaching a tile to a zone member is what adopts it and what
    /// entitles the zone to grow around it.
    public static func isGapAdjacent(_ a: TileFrame, _ b: TileFrame, gap: Double, tolerance: Double = 0.26) -> Bool {
        let sepX = max(a.x - (b.x + b.width), b.x - (a.x + a.width))
        let sepY = max(a.y - (b.y + b.height), b.y - (a.y + a.height))
        return (abs(sepX - gap) <= tolerance && sepY < 0) || (abs(sepY - gap) <= tolerance && sepX < 0)
    }

    private static func contentRect(zone: ZonePlacement, padding: Double, header: Double) -> CGRect {
        CGRect(x: zone.origin.x + padding, y: zone.origin.y + header + padding,
               width: max(0, zone.size.width - 2 * padding),
               height: max(0, zone.size.height - header - 2 * padding))
    }

    private static func clampIntoContent(_ frame: TileFrame, content: CGRect) -> TileFrame {
        TileFrame(x: min(max(frame.x, content.minX), max(content.minX, content.maxX - frame.width)),
                  y: min(max(frame.y, content.minY), max(content.minY, content.maxY - frame.height)),
                  width: frame.width, height: frame.height)
    }

    private enum PushAxis { case horizontal, vertical }

    /// The axis a pair pushes along for the WHOLE gesture: if their baseline
    /// frames were separated on exactly one axis they are lane-mates on that
    /// axis (row-mates push horizontally, stack-mates vertically). Diagonal
    /// baseline neighbors fall back to whichever current penetration is smaller.
    private static func pushAxis(baselineA: TileFrame, baselineB: TileFrame, currentA a: TileFrame, currentB b: TileFrame, gap: Double) -> PushAxis {
        let xSeparated = baselineA.x + baselineA.width <= baselineB.x + 0.5 || baselineB.x + baselineB.width <= baselineA.x + 0.5
        let ySeparated = baselineA.y + baselineA.height <= baselineB.y + 0.5 || baselineB.y + baselineB.height <= baselineA.y + 0.5
        if xSeparated != ySeparated { return xSeparated ? .horizontal : .vertical }
        let penX = b.x + b.width / 2 >= a.x + a.width / 2
            ? a.x + a.width + gap - b.x
            : b.x + b.width + gap - a.x
        let penY = b.y + b.height / 2 >= a.y + a.height / 2
            ? a.y + a.height + gap - b.y
            : b.y + b.height + gap - a.y
        return penX <= penY ? .horizontal : .vertical
    }

    /// Minimal single-axis push propagation. Each pushed tile moves exactly far
    /// enough to restore the gap, along one axis, and stops at the zone content
    /// wall instead of wrapping to a new lane. Solved fresh from the gesture
    /// baseline every frame, so retreating the drag relaxes every push.
    private static func propagatePushes(
        from sourceId: UUID, frames: inout [UUID: TileFrame], baseline: [UUID: TileFrame],
        exclude: Set<UUID>, content: CGRect, gap: Double
    ) {
        let ids = frames.keys.sorted(by: uuidLess)
        var queue = [sourceId]
        var visits = 0
        while !queue.isEmpty, visits < max(64, ids.count * ids.count * 4) {
            visits += 1
            let pusher = queue.removeFirst()
            guard let a = frames[pusher] else { continue }
            for id in ids where id != pusher && id != sourceId && !exclude.contains(id) {
                guard let b = frames[id], overlapsOrUnderGap(a, b, gap: gap) else { continue }
                let axis = pushAxis(
                    baselineA: baseline[pusher] ?? a, baselineB: baseline[id] ?? b,
                    currentA: a, currentB: b, gap: gap)
                var moved = b
                switch axis {
                case .horizontal:
                    let positive = b.x + b.width / 2 >= a.x + a.width / 2
                    moved.x = positive ? a.x + a.width + gap : a.x - gap - b.width
                    moved.x = min(max(moved.x, content.minX), max(content.minX, content.maxX - b.width))
                case .vertical:
                    let positive = b.y + b.height / 2 >= a.y + a.height / 2
                    moved.y = positive ? a.y + a.height + gap : a.y - gap - b.height
                    moved.y = min(max(moved.y, content.minY), max(content.minY, content.maxY - b.height))
                }
                if moved.x != b.x || moved.y != b.y {
                    frames[id] = moved
                    queue.append(id)
                }
            }
        }
    }

    /// Screen points per second above which a drag is passing over tiles
    /// rather than dwelling on one (.plans/107).
    public static let swapAcquireSpeed = 600.0

    /// Most tiles one live-drag frame may move by pushing (.plans/107).
    public static let livePushBudget = 3

    /// The live-drag push (.plans/107). A tile `source` presses on moves along
    /// the pair's own baseline axis, by the minimal amount, never past the
    /// content wall and never further than a quarter of its own length from
    /// rest. Pushes may chain, but at most `livePushBudget` tiles move: a push
    /// that would need one more does not happen and the pusher overlaps instead.
    /// Unbounded chains moved every tile of a zone at once, and an unbounded
    /// push let a swap teleport a tile back from far away.
    private static func pushNeighbors(
        of sourceId: UUID, frames: inout [UUID: TileFrame], baseline: [UUID: TileFrame],
        exclude: Set<UUID>, content: CGRect, gap: Double, reserved: Set<UUID> = []
    ) {
        let ids = frames.keys.sorted(by: uuidLess)
        var moved = Set<UUID>()
        var queue = [sourceId]
        // At most `livePushBudget` tiles can move, so a few expansions settle
        // it; the bound stops two pushers bouncing a tile back and forth.
        var expansions = 0
        while !queue.isEmpty, expansions < 4 * (livePushBudget + 1) {
            expansions += 1
            let pusher = queue.removeFirst()
            guard let a = frames[pusher] else { continue }
            let pusherRest = baseline[pusher] ?? a
            for id in ids where id != pusher && id != sourceId && !exclude.contains(id) {
                guard let b = frames[id], let rest = baseline[id], overlapsOrUnderGap(a, b, gap: gap) else { continue }
                guard moved.contains(id) || reserved.contains(id)
                        || moved.union(reserved).count < livePushBudget else { continue }
                let axis = pushAxis(baselineA: pusherRest, baselineB: rest, currentA: a, currentB: b, gap: gap)
                // The gap only exists along a shared edge. Two tiles that merely
                // meet at a corner do not push: hand jitter grazing that corner
                // twitched diagonal neighbours on and off every frame.
                let shared = axis == .horizontal
                    ? min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                    : min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                guard shared > 0.5 else { continue }
                var next = b
                switch axis {
                case .horizontal:
                    let positive = rest.x + rest.width / 2 >= pusherRest.x + pusherRest.width / 2
                    next.x = positive ? max(b.x, a.x + a.width + gap) : min(b.x, a.x - gap - b.width)
                    next.x = min(max(next.x, rest.x - rest.width / 4), rest.x + rest.width / 4)
                    next.x = min(max(next.x, content.minX), max(content.minX, content.maxX - b.width))
                case .vertical:
                    let positive = rest.y + rest.height / 2 >= pusherRest.y + pusherRest.height / 2
                    next.y = positive ? max(b.y, a.y + a.height + gap) : min(b.y, a.y - gap - b.height)
                    next.y = min(max(next.y, rest.y - rest.height / 4), rest.y + rest.height / 4)
                    next.y = min(max(next.y, content.minY), max(content.minY, content.maxY - b.height))
                }
                guard next != b else { continue }
                // A tile that may not move is a wall: never push into it.
                if exclude.contains(where: { frozen in
                    frames[frozen].map { overlapsOrUnderGap(next, $0, gap: gap - 0.26) } == true
                }) { continue }
                frames[id] = next
                moved.insert(id)
                queue.append(id)
            }
        }
    }

    /// The member-move solver: the active tile always keeps its pointer frame.
    /// Unlatched, siblings receive minimal single-axis pushes. Latched to a
    /// `.swap`, that sibling takes the active tile's old origin; latched to an
    /// `.insert`, the row's other tiles reflow around an empty slot. `slot` is
    /// where the active tile lands if it is dropped now.
    private static func solveMemberMove(
        activeTile: UUID, originalFrame: TileFrame, memberIds: [UUID],
        tiles: [UUID: LayoutTile], zone: ZonePlacement,
        gap: Double, padding: Double, header: Double, latched: MoveLatch?,
        pointer: CGPoint? = nil, preferSwap: Bool = false, pointerSpeed: Double? = nil,
        previous: [UUID: TileFrame]? = nil, interactive: Set<UUID>? = nil
    ) -> (frames: [UUID: TileFrame], latch: MoveLatch?, slot: TileFrame?) {
        guard let requested = tiles[activeTile]?.frame else { return ([:], nil, nil) }
        let content = contentRect(zone: zone, padding: padding, header: header)
        var baseline: [UUID: TileFrame] = [:]
        for id in memberIds { baseline[id] = tiles[id]?.frame }
        baseline[activeTile] = originalFrame
        let probe = pointer ?? CGPoint(x: requested.x + requested.width / 2, y: requested.y + requested.height / 2)
        // The hysteresis band keeps edge jitter from oscillating the topology.
        let releaseBand = max(24, gap * 1.5)
        // A helper dragged inside its lead's cluster (.plans/107 model B) only
        // ever disturbs that cluster: every other tile is a fixed obstacle that
        // is never pushed, swapped or slid.
        let frozen: Set<UUID> = interactive.map { cluster in
            Set(memberIds.filter { $0 != activeTile && !cluster.contains($0) })
        } ?? []
        let rows = memberRows(memberIds.filter { $0 != activeTile && !frozen.contains($0) }, frames: baseline)
        // Tiles the previous frame left off their rest: they count against the
        // push budget until they are back, so a handover between push sets
        // relaxes the old ones a frame before it pushes new ones.
        let stillDisplaced: Set<UUID> = Set(memberIds.filter { id in
            guard id != activeTile, let was = previous?[id], let rest = baseline[id] else { return false }
            return was != rest
        })

        /// The frames for one latch state, solved fresh from the gesture baseline.
        func arrange(_ latch: MoveLatch?, pushing: Bool = true) -> (frames: [UUID: TileFrame], slot: TileFrame?) {
            var frames = baseline
            frames[activeTile] = requested
            var slot: TileFrame?
            switch latch {
            case let .swap(sibling)?:
                if let reflow = unequalSwapReflow(
                    active: activeTile, sibling: sibling, home: originalFrame,
                    baseline: baseline, members: memberIds.filter { !frozen.contains($0) }) {
                    // Different widths: exchange the two ROW POSITIONS, and let the
                    // tiles after them close up or make room, instead of dropping
                    // a wide tile on a narrow tile's origin.
                    for (id, frame) in reflow.frames { frames[id] = frame }
                    pushNeighbors(of: sibling, frames: &frames, baseline: baseline,
                                  exclude: frozen.union([activeTile]), content: content, gap: gap, reserved: stillDisplaced)
                    slot = reflow.slot
                } else if var displaced = frames[sibling], let target = baseline[sibling] {
                    displaced.x = originalFrame.x
                    displaced.y = originalFrame.y
                    frames[sibling] = clampIntoContent(displaced, content: content)
                    // An exchanged tile larger than the slot it inherits may press
                    // on its new neighbours: one level, never against the active.
                    pushNeighbors(of: sibling, frames: &frames, baseline: baseline,
                                  exclude: frozen.union([activeTile]), content: content, gap: gap, reserved: stillDisplaced)
                    slot = TileFrame(x: target.x, y: target.y, width: requested.width, height: requested.height)
                }
            case let .insert(row, index)?:
                if rows.indices.contains(row) {
                    slot = layoutInsertion(
                        row: rows[row], index: index, active: requested, home: originalFrame,
                        baseline: baseline, frames: &frames, exclude: frozen.union([activeTile]), gap: gap)
                }
            case nil:
                if pushing {
                    pushNeighbors(of: activeTile, frames: &frames, baseline: baseline,
                                  exclude: frozen, content: content, gap: gap, reserved: stillDisplaced)
                }
            }
            return (frames, slot)
        }

        // A sibling is hit where it is DRAWN as well as where it rests: the
        // previous latch's arrangement is what is on screen. Pushes are capped
        // at a quarter tile, so the two never lie far apart, and a swap can no
        // longer fire over empty space a pushed tile has left (.plans/107).
        let shownArrangement = arrange(latched)
        let shown = shownArrangement.frames
        // Sliding in between is a pointer gesture. A move with no pointer (an
        // API or programmatic move) keeps the exchange-only latch, as does ⌥.
        var latch = preferSwap || pointer == nil
            ? swapOnlyLatch(probe: probe, home: originalFrame, siblings: rows.flatMap { $0 },
                            baseline: baseline, shown: shown, latched: latched, releaseBand: releaseBand)
            : slideOrSwapLatch(probe: probe, home: originalFrame, rows: rows,
                               baseline: baseline, shown: shown, latched: latched, releaseBand: releaseBand)
        // A pointer passing over tiles on its way elsewhere must not swap them
        // or slide in among them: a NEW latch is only acquired while the pointer
        // dwells. A held latch holds, a release releases, and a slide already
        // running in a row keeps following the pointer along it, at any speed.
        if let speed = pointerSpeed, speed > swapAcquireSpeed, let candidate = latch, candidate != latched {
            var slidingAlongRow = false
            if case let .insert(row, _) = candidate, case let .insert(heldRow, _)? = latched, row == heldRow {
                slidingAlongRow = true
            }
            if !slidingAlongRow { latch = nil }
        }
        var arranged = latch == latched ? shownArrangement : arrange(latch)
        // A new swap that would move more than the budget at once (its partner
        // plus every push relaxing) waits one frame: this frame only relaxes.
        if case let .swap(sibling)? = latch, latch != latched, let previous {
            // The tiles an unequal exchange shifts along its rows ARE the
            // exchange, not pushes relaxing: counting them deferred every
            // cross-row swap of unequal widths forever.
            let exchanged = Set(unequalSwapReflow(
                active: activeTile, sibling: sibling, home: originalFrame,
                baseline: baseline, members: memberIds.filter { !frozen.contains($0) })?.frames.keys ?? [:].keys)
            let changes = memberIds.filter { id in
                id != activeTile && !exchanged.contains(id) && previous[id] != nil && previous[id] != arranged.frames[id]
            }.count
            if changes > livePushBudget {
                latch = latched
                arranged = arrange(latched, pushing: false)
            }
        }
        return (arranged.frames, latch, arranged.slot)
    }

    /// An exchange of two tiles of DIFFERENT widths, as row positions
    /// (`.plans/auto-layout-night`). Tidy makes rows of tiles of different
    /// widths at exact gap contact; a raw origin exchange there drops a wide tile
    /// on a narrow tile's origin, over its new neighbours, and leaves a hole where
    /// the wide tile was. Here each tile takes the other's place in its row, and
    /// the tiles after that place in the row shift by the difference in width.
    /// Every row keeps its own gap sequence, so a hand-placed row keeps its
    /// spacing, and the tiles before the exchanged place do not move. A row that
    /// gets longer may run past the content edge: that is the zone needing to
    /// grow, which the drop does. Sizes never change.
    ///
    /// Nil for equal widths: the origin exchange is already exact.
    private static func unequalSwapReflow(
        active: UUID, sibling: UUID, home: TileFrame,
        baseline: [UUID: TileFrame], members: [UUID]
    ) -> (frames: [UUID: TileFrame], slot: TileFrame)? {
        guard let target = baseline[sibling], abs(target.width - home.width) > 0.5 else { return nil }
        var rest = baseline
        rest[active] = home
        let rows = memberRows(members.filter { rest[$0] != nil }, frames: rest)
        guard let rowA = rows.firstIndex(where: { $0.contains(active) }),
              let rowB = rows.firstIndex(where: { $0.contains(sibling) }) else { return nil }
        /// Lay `row` out again with `substitute` standing in for some of its tiles:
        /// positions before the first substitution keep their exact x; from it on,
        /// each place keeps the gap that followed it.
        func relay(_ row: [UUID], substitute: [UUID: UUID]) -> [UUID: TileFrame] {
            var out: [UUID: TileFrame] = [:]
            var cursor: Double?
            for (index, original) in row.enumerated() {
                guard let slot = rest[original] else { continue }
                let tile = substitute[original] ?? original
                guard var frame = rest[tile] else { continue }
                if cursor == nil, tile != original { cursor = slot.x }
                frame.x = cursor ?? slot.x
                if tile != original { frame.y = slot.y }
                out[tile] = frame
                if cursor != nil {
                    let gapAfter = index + 1 < row.count
                        ? (rest[row[index + 1]].map { $0.x - (slot.x + slot.width) } ?? 0) : 0
                    cursor = frame.x + frame.width + gapAfter
                }
            }
            return out
        }
        var frames: [UUID: TileFrame] = [:]
        if rowA == rowB {
            frames = relay(rows[rowA], substitute: [active: sibling, sibling: active])
        } else {
            frames = relay(rows[rowA], substitute: [active: sibling])
            for (id, frame) in relay(rows[rowB], substitute: [sibling: active]) { frames[id] = frame }
        }
        guard let slot = frames.removeValue(forKey: active) else { return nil }
        return (frames, slot)
    }

    /// Zone members grouped into rows, top to bottom, each left to right. A
    /// tile joins a row only if it overlaps the row's FIRST tile vertically by
    /// at least half the shorter height. The old rule chained (A overlaps B, B
    /// overlaps C), so a zone of mixed heights became one row and a slide-in
    /// re-laid every tile of it in a line (.plans/107).
    private static func memberRows(_ ids: [UUID], frames: [UUID: TileFrame]) -> [[UUID]] {
        let byTop = ids.filter { frames[$0] != nil }.sorted {
            let a = frames[$0]!, b = frames[$1]!
            return a.y == b.y ? uuidLess($0, $1) : a.y < b.y
        }
        var rows: [[UUID]] = []
        var seeds: [TileFrame] = []
        for id in byTop {
            let frame = frames[id]!
            if let index = seeds.firstIndex(where: { seed in
                let overlap = min(seed.y + seed.height, frame.y + frame.height) - max(seed.y, frame.y)
                return overlap >= min(seed.height, frame.height) / 2
            }) {
                rows[index].append(id)
            } else {
                rows.append([id])
                seeds.append(frame)
            }
        }
        return rows.map { row in
            row.sorted {
                let a = frames[$0]!, b = frames[$1]!
                return a.x == b.x ? uuidLess($0, $1) : a.x < b.x
            }
        }
    }

    private static func rowExtent(_ row: [UUID], frames: [UUID: TileFrame]) -> TileFrame {
        let members = row.compactMap { frames[$0] }
        guard let first = members.first else { return TileFrame(x: 0, y: 0, width: 0, height: 0) }
        let minX = members.map(\.x).min() ?? first.x
        let minY = members.map(\.y).min() ?? first.y
        let maxX = members.map { $0.x + $0.width }.max() ?? first.x
        let maxY = members.map { $0.y + $0.height }.max() ?? first.y
        return TileFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rectContains(_ frame: TileFrame, _ point: CGPoint, inset: Double = 0) -> Bool {
        point.x >= frame.x - inset && point.x <= frame.x + frame.width + inset
            && point.y >= frame.y - inset && point.y <= frame.y + frame.height + inset
    }

    /// ⌥ held: the exchange-only latch. Entering a sibling latches it; leaving
    /// it by more than the band, or returning home, releases it; entering a
    /// different sibling re-latches.
    private static func swapOnlyLatch(
        probe: CGPoint, home: TileFrame, siblings: [UUID], baseline: [UUID: TileFrame],
        shown: [UUID: TileFrame], latched: MoveLatch?, releaseBand: Double
    ) -> MoveLatch? {
        var latch: UUID?
        if case let .swap(id)? = latched, let frame = baseline[id], siblings.contains(id),
           rectContains(frame, probe, inset: releaseBand) {
            latch = id
        }
        if rectContains(home, probe) { return nil }
        if let entered = siblings.first(where: { id in
            [baseline[id], shown[id]].contains { $0.map { rectContains($0, probe) } == true }
        }) {
            latch = entered
        }
        return latch.map { .swap($0) }
    }

    /// Over a sibling's middle half the move swaps; over a row's outer quarters
    /// or its gaps it slides in at that edge. A swap holds until the pointer is
    /// the band past the middle half; a slide keeps its row within the band and
    /// changes index only once the pointer is past a sibling's midpoint by more
    /// than the band. Back over its own place, nothing is latched.
    private static func slideOrSwapLatch(
        probe: CGPoint, home: TileFrame, rows: [[UUID]], baseline: [UUID: TileFrame],
        shown: [UUID: TileFrame], latched: MoveLatch?, releaseBand: Double
    ) -> MoveLatch? {
        if rectContains(home, probe) { return nil }
        func middleHalf(_ id: UUID, in frames: [UUID: TileFrame] = baseline) -> TileFrame? {
            frames[id].map { TileFrame(x: $0.x + $0.width / 4, y: $0.y, width: $0.width / 2, height: $0.height) }
        }
        if case let .swap(id)? = latched, rows.contains(where: { $0.contains(id) }),
           let half = middleHalf(id), rectContains(half, probe, inset: releaseBand) {
            return .swap(id)
        }
        if let entered = rows.joined().first(where: { id in
            [middleHalf(id), middleHalf(id, in: shown)].contains { $0.map { rectContains($0, probe) } == true }
        }) {
            return .swap(entered)
        }
        var held: (row: Int, index: Int)?
        if case let .insert(row, index)? = latched, rows.indices.contains(row) { held = (row, index) }
        let heldRow = held.flatMap { held in
            rectContains(rowExtent(rows[held.row], frames: baseline), probe, inset: releaseBand) ? held.row : nil
        }
        guard let rowIndex = heldRow
            ?? rows.indices.first(where: { rectContains(rowExtent(rows[$0], frames: baseline), probe) })
        else { return nil }
        let row = rows[rowIndex]
        let mids = row.compactMap { baseline[$0].map { $0.x + $0.width / 2 } }
        var index = mids.filter { $0 < probe.x }.count
        if let held, held.row == rowIndex {
            let surelyPast = mids.filter { $0 < probe.x - releaseBand }.count
            let maybePast = mids.filter { $0 < probe.x + releaseBand }.count
            index = min(max(held.index, surelyPast), maybePast)
        }
        // A slide back into its own place is no slide.
        let extent = rowExtent(row, frames: baseline)
        let homeInRow = home.y < extent.y + extent.height && extent.y < home.y + home.height
        if homeInRow, index == mids.filter({ $0 < home.x + home.width / 2 }).count { return nil }
        return .insert(row: rowIndex, index: index)
    }

    /// Slide-in, kept local (.plans/107). Nobody's y changes, and only tiles
    /// actually in the way move, sideways:
    /// - the dragged tile came from this row: the tiles between its old place
    ///   and the slot shift one place toward it, a reorder;
    /// - it came from elsewhere: the tiles from the slot rightward shift right
    ///   by the minimum that clears it, and anything they then press on moves
    ///   right as well.
    /// The old version re-laid the whole row from its left edge with tops
    /// aligned, which flattened a zone of mixed heights into one line.
    /// Returns the slot.
    private static func layoutInsertion(
        row: [UUID], index: Int, active: TileFrame, home: TileFrame,
        baseline: [UUID: TileFrame], frames: inout [UUID: TileFrame], exclude: Set<UUID>, gap: Double
    ) -> TileFrame {
        let members = row.compactMap { baseline[$0] }
        guard !members.isEmpty else { return active }
        let extent = rowExtent(row, frames: baseline)
        let homeInRow = home.y < extent.y + extent.height && extent.y < home.y + home.height
        let step = active.width + gap
        let homeIndex = homeInRow ? members.filter { $0.x + $0.width / 2 < home.x + home.width / 2 }.count : nil
        // Align to the neighbour the slot sits beside.
        let neighbour = members[max(0, min(members.count - 1, index > 0 ? index - 1 : 0))]
        var slot = TileFrame(x: 0, y: neighbour.y, width: active.width, height: active.height)
        if let homeIndex {
            if index > homeIndex {
                for position in homeIndex..<index { frames[row[position]]?.x = members[position].x - step }
                slot.x = members[index - 1].x + members[index - 1].width - active.width
            } else {
                for position in index..<homeIndex { frames[row[position]]?.x = members[position].x + step }
                slot.x = members[index].x
            }
            return slot
        }
        slot.x = index == 0 ? members[0].x : members[index - 1].x + members[index - 1].width + gap
        // Shift right whatever the slot (then each shifted tile) presses on.
        var queue = [slot]
        var shifted = Set<UUID>()
        var visits = 0
        while !queue.isEmpty, visits < max(64, frames.count * 4) {
            visits += 1
            let pusher = queue.removeFirst()
            for id in frames.keys.sorted(by: uuidLess) where !exclude.contains(id) && !shifted.contains(id) {
                guard var b = frames[id], overlapsOrUnderGap(pusher, b, gap: gap - 0.26),
                      b.x + b.width / 2 >= pusher.x + pusher.width / 2 - 0.5 else { continue }
                b.x = max(b.x, pusher.x + pusher.width + gap)
                frames[id] = b
                shifted.insert(id)
                queue.append(b)
            }
        }
        return slot
    }

    /// Rest-state magnetism: greedily grow a gap-contact cluster from the
    /// top-left-most stationary member, absorbing whichever tile can join with
    /// the least movement; a just-moved tile joins last. Tiles already at exact
    /// gap-contact never move.
    private static func settleMembers(
        memberIds: [UUID], tiles: [UUID: LayoutTile], zone: ZonePlacement,
        gap: Double, padding: Double, header: Double, mover: UUID?, pinMover: Bool,
        growMover: Bool = false, view: TileFrame? = nil
    ) -> [UUID: TileFrame] {
        let content = contentRect(zone: zone, padding: padding, header: header)
        guard content.width > 0, content.height > 0 else { return [:] }
        let growing = growMover && mover != nil
        var result: [UUID: TileFrame] = [:]
        for id in memberIds {
            guard let tile = tiles[id] else { continue }
            // A spawn's placement is where the camera is looking. Clamping it
            // into the zone first is what threw that away (0.7.30). A zone's
            // first tile has nothing to dock onto and still goes inside.
            result[id] = growing && id == mover && memberIds.count > 1
                ? tile.frame : clampIntoContent(tile.frame, content: content)
        }
        guard result.count > 1 else { return result }
        var pending = memberIds.filter { result[$0] != nil }
        // A pinned mover (completed slot exchange) is authoritative: it seeds
        // the cluster at its exact frame, residents it presses on are pushed
        // aside along one axis, and everyone else magnetizes onto that. It can
        // never relocate — in particular never to a different lane.
        if pinMover, let mover, result[mover] != nil {
            propagatePushes(from: mover, frames: &result, baseline: result, exclude: [], content: content, gap: gap)
            return result
        }
        // A settle with a mover resolves the MOVER only (.plans/107). Every
        // other member keeps its place, so the cluster is all of them as they
        // stand. Re-growing the cluster from the topmost member re-placed any
        // tile that had touched the others only through the mover: dropping one
        // tile moved the lead agent across the zone.
        if let mover, result[mover] != nil, pending.contains(where: { $0 != mover }) {
            var cluster = pending.filter { $0 != mover }.compactMap { result[$0] }
            pending = [mover]
            let growContent = growing ? content.insetBy(dx: -1_000_000, dy: -1_000_000) : nil
            absorb(pending: &pending, cluster: &cluster, result: &result, mover: mover, content: content, gap: gap,
                   growContent: growContent, view: view)
            if let moved = result[mover],
               result.contains(where: { $0.key != mover && overlapsOrUnderGap(moved, $0.value, gap: gap - 0.26) }) {
                var frames = result
                propagatePushes(from: mover, frames: &frames, baseline: result, exclude: [], content: content, gap: gap)
                result = frames
            }
            return result
        }
        let anchorPool = pending.contains { $0 != mover } ? pending.filter { $0 != mover } : pending
        let anchor = anchorPool.min { lhs, rhs in
            let a = result[lhs]!, b = result[rhs]!
            if a.y != b.y { return a.y < b.y }
            if a.x != b.x { return a.x < b.x }
            return uuidLess(lhs, rhs)
        }!
        var cluster: [TileFrame] = [result[anchor]!]
        pending.removeAll { $0 == anchor }
        // A growing mover may settle past any edge; the zone follows it there.
        let growContent = growing
            ? content.insetBy(dx: -1_000_000, dy: -1_000_000)
            : nil
        absorb(pending: &pending, cluster: &cluster, result: &result, mover: mover, content: content, gap: gap,
               growContent: growContent, view: view)
        // A mover that found no contact placement (e.g. dropped against the
        // wall where its exchanged slot needs the row to shift) may still press
        // on the cluster: resolve it with the same minimal single-axis pushes
        // the live drag uses, never with a reflow.
        if let mover, let moved = result[mover],
           result.contains(where: { $0.key != mover && overlapsOrUnderGap(moved, $0.value, gap: gap - 0.26) }) {
            var frames = result
            propagatePushes(from: mover, frames: &frames, baseline: result, exclude: [], content: content, gap: gap)
            result = frames
        }
        return result
    }

    /// The greedy magnetism loop: repeatedly absorb whichever pending tile can
    /// join the gap-contact cluster with the least movement; `mover` (if any)
    /// always joins last.
    private static func absorb(
        pending: inout [UUID], cluster: inout [TileFrame], result: inout [UUID: TileFrame],
        mover: UUID?, content: CGRect, gap: Double, growContent: CGRect? = nil, view: TileFrame? = nil
    ) {
        while !pending.isEmpty {
            let wave = pending.contains { $0 != mover } ? pending.filter { $0 != mover } : pending
            if let growContent, let mover, wave == [mover], let frame = result[mover] {
                let settled = spawnPlacement(for: frame, cluster: cluster, content: growContent, gap: gap, view: view)
                    ?? frame
                result[mover] = settled
                cluster.append(settled)
                pending.removeAll { $0 == mover }
                continue
            }
            // memberIds (and therefore wave) retain stable UUID order. A
            // valid existing contact costs zero: no candidate search can beat
            // it. Check those contacts first, preserving the greedy tie-break,
            // before generating placements for disconnected tiles.
            if let touching = wave.first(where: { id in
                guard let frame = result[id] else { return false }
                return cluster.contains { isGapAdjacent(frame, $0, gap: gap, tolerance: 0.26) }
                    && valid(frame, in: content, against: cluster, gap: gap - 0.26)
            }) {
                cluster.append(result[touching]!)
                pending.removeAll { $0 == touching }
                continue
            }
            var best: (id: UUID, frame: TileFrame, cost: Double)?
            for id in wave {
                guard let frame = result[id] else { continue }
                guard let placement = contactPlacement(for: frame, cluster: cluster, content: content, gap: gap) else { continue }
                let cost = squaredDistance(placement, frame)
                if best == nil || cost < best!.cost || (cost == best!.cost && uuidLess(id, best!.id)) {
                    best = (id, placement, cost)
                }
            }
            if let best {
                result[best.id] = best.frame
                cluster.append(best.frame)
                pending.removeAll { $0 == best.id }
            } else {
                // The zone cannot host a contact placement (too small). Leave
                // the nearest pending tile where it is rather than flinging it.
                let id = wave.first!
                cluster.append(result[id]!)
                pending.removeAll { $0 == id }
            }
        }
    }

    /// The nearest position where `frame` sits at exact gap-contact with the
    /// cluster without overlapping or under-gapping any settled tile. Returns
    /// the frame unchanged (cost 0) when it already touches.
    private static func contactPlacement(for frame: TileFrame, cluster: [TileFrame], content: CGRect, gap: Double) -> TileFrame? {
        let tolerance = 0.26
        func isValid(_ candidate: TileFrame) -> Bool {
            valid(candidate, in: content, against: cluster, gap: gap - tolerance)
        }
        let touching = cluster.contains { isGapAdjacent(frame, $0, gap: gap, tolerance: tolerance) }
        if touching, isValid(frame) { return frame }
        return contactCandidates(for: frame, cluster: cluster, gap: gap).filter(isValid).min { lhs, rhs in
            let a = squaredDistance(lhs, frame), b = squaredDistance(rhs, frame)
            if a != b { return a < b }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
    }

    /// Where a spawned tile settles. Its placement already docked it where the
    /// camera is looking, so a placement at gap contact that overlaps nothing is
    /// kept exactly. Otherwise (the placement found no free slot on screen) the
    /// contact slot most visible in `view` wins, then the one nearest the
    /// placement — never "nearest" alone, which sent the tile to whichever edge
    /// of the zone was closest, on screen or not.
    private static func spawnPlacement(
        for frame: TileFrame, cluster: [TileFrame], content: CGRect, gap: Double, view: TileFrame?
    ) -> TileFrame? {
        let tolerance = 0.26
        func isValid(_ candidate: TileFrame) -> Bool {
            valid(candidate, in: content, against: cluster, gap: gap - tolerance)
        }
        let touching = cluster.contains { isGapAdjacent(frame, $0, gap: gap, tolerance: tolerance) }
        if touching, isValid(frame) { return frame }
        func visible(_ candidate: TileFrame) -> Double {
            guard let view else { return 0 }
            let w = max(0, min(candidate.x + candidate.width, view.x + view.width) - max(candidate.x, view.x))
            let h = max(0, min(candidate.y + candidate.height, view.y + view.height) - max(candidate.y, view.y))
            return w * h / max(candidate.width * candidate.height, 1)
        }
        return contactCandidates(for: frame, cluster: cluster, gap: gap).filter(isValid).min { lhs, rhs in
            let va = visible(lhs), vb = visible(rhs)
            if abs(va - vb) > 0.001 { return va > vb }
            let a = squaredDistance(lhs, frame), b = squaredDistance(rhs, frame)
            if a != b { return a < b }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
    }

    /// Every slot at exact gap contact with a cluster member: each side of each
    /// member, aligned to the frame's own position where it can be, else to
    /// either end of the member's edge.
    private static func contactCandidates(for frame: TileFrame, cluster: [TileFrame], gap: Double) -> [TileFrame] {
        func aligned(_ value: Double, edge: Double, edgeLength: Double, length: Double) -> [Double] {
            let far = edge + edgeLength - length
            return [min(max(value, min(edge, far)), max(edge, far)), edge, far]
        }
        var candidates: [TileFrame] = []
        for other in cluster {
            for y in aligned(frame.y, edge: other.y, edgeLength: other.height, length: frame.height) {
                candidates.append(TileFrame(x: other.x + other.width + gap, y: y, width: frame.width, height: frame.height))
                candidates.append(TileFrame(x: other.x - frame.width - gap, y: y, width: frame.width, height: frame.height))
            }
            for x in aligned(frame.x, edge: other.x, edgeLength: other.width, length: frame.width) {
                candidates.append(TileFrame(x: x, y: other.y + other.height + gap, width: frame.width, height: frame.height))
                candidates.append(TileFrame(x: x, y: other.y - frame.height - gap, width: frame.width, height: frame.height))
            }
        }
        return candidates
    }

    private static func shrinkNeighborsAndPack(
        memberIds: [UUID], tiles: [UUID: LayoutTile], zone: ZonePlacement,
        padding: Double, header: Double, pinned: UUID?, horizontal: Bool
    ) -> (tiles: [UUID: LayoutTile], frames: [UUID: TileFrame])? {
        func candidate(_ pressure: Double) -> [UUID: LayoutTile] {
            var result = tiles
            for id in memberIds where id != pinned {
                guard var tile = result[id] else { continue }
                if horizontal {
                    let minimum = min(tile.frame.width, max(1, tile.minimumSize.width))
                    tile.frame.width -= (tile.frame.width - minimum) * pressure
                } else {
                    let minimum = min(tile.frame.height, max(1, tile.minimumSize.height))
                    tile.frame.height -= (tile.frame.height - minimum) * pressure
                }
                result[id] = tile
            }
            return result
        }

        let fullyShrunk = candidate(1)
        guard var bestFrames = pack(
            memberIds: memberIds, tiles: fullyShrunk, zone: zone,
            gap: 0, padding: padding, header: header, pinned: pinned,
            allowPinnedOutside: false) else { return nil }
        var bestTiles = fullyShrunk
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            let trialTiles = candidate(middle)
            if let trialFrames = pack(
                memberIds: memberIds, tiles: trialTiles, zone: zone,
                gap: 0, padding: padding, header: header, pinned: pinned,
                allowPinnedOutside: false) {
                high = middle
                bestTiles = trialTiles
                bestFrames = trialFrames
            } else {
                low = middle
            }
        }
        return (bestTiles, bestFrames)
    }

    private static func expandZoneAndPack(
        memberIds: [UUID], tiles: [UUID: LayoutTile], zone: ZonePlacement,
        header: Double, pinned: UUID?, horizontal: Bool
    ) -> (zone: ZonePlacement, frames: [UUID: TileFrame])? {
        func attempt(_ extent: Double) -> (ZonePlacement, [UUID: TileFrame])? {
            var candidate = zone
            if horizontal { candidate.size.width = extent } else { candidate.size.height = extent }
            guard let frames = pack(
                memberIds: memberIds, tiles: tiles, zone: candidate,
                gap: 0, padding: 0, header: header, pinned: pinned,
                allowPinnedOutside: false) else { return nil }
            return (candidate, frames)
        }

        let current = horizontal ? zone.size.width : zone.size.height
        var low = current
        var high = max(current + 1, current * 2)
        var upper = attempt(high)
        for _ in 0..<12 where upper == nil {
            high *= 2
            upper = attempt(high)
        }
        guard upper != nil else { return nil }
        for _ in 0..<18 {
            let middle = (low + high) / 2
            if attempt(middle) != nil { high = middle } else { low = middle }
        }
        return attempt(ceil(high)) ?? upper
    }

    private static func minimumFeasibleSize(memberIds: [UUID], tiles: [UUID: LayoutTile], proposed: ZonePlacement, header: Double) -> CGSize {
        let widths = memberIds.compactMap { tiles[$0]?.frame.width }
        let heights = memberIds.compactMap { tiles[$0]?.frame.height }
        guard let widest = widths.max(), let tallest = heights.max() else { return .zero }
        var minimumWidth = widest
        var minimumHeight = tallest + header
        if proposed.size.height >= minimumHeight {
            var low = widest, high = max(proposed.size.width, widths.reduce(0, +))
            for _ in 0..<18 {
                let middle = (low + high) / 2
                var candidate = proposed; candidate.size.width = middle
                if pack(memberIds: memberIds, tiles: tiles, zone: candidate, gap: 0, padding: 0, header: header, pinned: nil) != nil { high = middle } else { low = middle }
            }
            minimumWidth = high
        }
        if proposed.size.width >= minimumWidth {
            var low = tallest + header, high = max(proposed.size.height, heights.reduce(0, +) + header)
            for _ in 0..<18 {
                let middle = (low + high) / 2
                var candidate = proposed; candidate.size.height = middle
                if pack(memberIds: memberIds, tiles: tiles, zone: candidate, gap: 0, padding: 0, header: header, pinned: nil) != nil { high = middle } else { low = middle }
            }
            minimumHeight = high
        }
        return CGSize(width: ceil(minimumWidth), height: ceil(minimumHeight))
    }

    private static func clampPlacement(_ proposed: ZonePlacement, previous: ZonePlacement?, minimum: CGSize) -> ZonePlacement {
        var result = proposed
        let old = previous ?? proposed
        if result.size.width < minimum.width {
            let proposedRight = result.origin.x + result.size.width
            if abs(proposedRight - (old.origin.x + old.size.width)) < abs(result.origin.x - old.origin.x) { result.origin.x = proposedRight - minimum.width }
            result.size.width = minimum.width
        }
        if result.size.height < minimum.height {
            let proposedBottom = result.origin.y + result.size.height
            if abs(proposedBottom - (old.origin.y + old.size.height)) < abs(result.origin.y - old.origin.y) { result.origin.y = proposedBottom - minimum.height }
            result.size.height = minimum.height
        }
        return result
    }

    /// Candidate positions come from the zone edges and already-placed tile edges.
    /// Choosing the candidate nearest the old frame produces minimal, spatially
    /// stable reflow without introducing a permanent row/column order.
    private static func pack(
        memberIds: [UUID], tiles: [UUID: LayoutTile], zone: ZonePlacement,
        gap: Double, padding: Double, header: Double, pinned: UUID?,
        allowPinnedOutside: Bool = true
    ) -> [UUID: TileFrame]? {
        let content = CGRect(x: zone.origin.x + padding, y: zone.origin.y + header + padding,
                             width: max(0, zone.size.width - 2 * padding), height: max(0, zone.size.height - header - 2 * padding))
        guard content.width > 0, content.height > 0 else { return nil }
        let ordered = memberIds.sorted { lhs, rhs in
            guard let a = tiles[lhs]?.frame, let b = tiles[rhs]?.frame else { return uuidLess(lhs, rhs) }
            if lhs == pinned { return true }; if rhs == pinned { return false }
            if a.y != b.y { return a.y < b.y }; if a.x != b.x { return a.x < b.x }
            return uuidLess(lhs, rhs)
        }
        func attempt(preserveExisting: Bool) -> [UUID: TileFrame]? {
            var placed: [UUID: TileFrame] = [:]
            for id in ordered {
                guard let source = tiles[id]?.frame, source.width <= content.width + 0.001, source.height <= content.height + 0.001 else { return nil }
                if id == pinned {
                    // Direct manipulation owns its requested geometry. In-bounds it
                    // becomes the fixed obstacle that neighbors pack around; outside
                    // the zone it stays untouched so the existing breakout/re-home
                    // policy can make the membership decision on mouse-up.
                    if valid(source, in: content, against: Array(placed.values), gap: gap) {
                        placed[id] = source
                    } else if !allowPinnedOutside {
                        return nil
                    }
                    continue
                }
                let clamped = TileFrame(x: min(max(source.x, content.minX), content.maxX - source.width),
                                        y: min(max(source.y, content.minY), content.maxY - source.height), width: source.width, height: source.height)
                if preserveExisting && valid(clamped, in: content, against: Array(placed.values), gap: gap) {
                    placed[id] = clamped
                    continue
                }
                var xs = [Double(content.minX)], ys = [Double(content.minY)]
                for frame in placed.values {
                    xs += [frame.x + frame.width + gap, frame.x - source.width - gap]
                    ys += [frame.y + frame.height + gap, frame.y - source.height - gap]
                }
                let candidates = xs.flatMap { x in ys.map { y in TileFrame(x: x, y: y, width: source.width, height: source.height) } }
                guard let best = candidates.filter({ valid($0, in: content, against: Array(placed.values), gap: gap) }).min(by: {
                    let da = squaredDistance($0, source), db = squaredDistance($1, source)
                    if da != db { return da < db }; if $0.y != $1.y { return $0.y < $1.y }; return $0.x < $1.x
                }) else { return nil }
                placed[id] = best
            }
            return placed
        }
        // First preserve every still-valid hand placement. Only if that topology
        // cannot fit do a full nearest-lane reflow from the usable zone edges.
        return attempt(preserveExisting: true) ?? attempt(preserveExisting: false)
    }

    /// A zone that GREW to take a spawned tile pushes what its growth ran into,
    /// exactly as a dragged zone does: the zone that grew keeps its place and the
    /// neighbouring zones (with their members) and bare tiles move away. Only a
    /// peer the growth reached FURTHER into is pushed: one the zone touched at
    /// `previous` and grows no deeper into stays put, so growing right never
    /// shoves a neighbour on the left.
    public static func pushPeers(ofGrownZone zoneId: UUID, from previous: ZonePlacement, scene: Scene, gap preferredGap: Double) -> CanvasLayoutTransaction {
        let gap = max(0, preferredGap.isFinite ? preferredGap : 0)
        var tiles = autoLayoutFirstWinsDictionary(scene.tiles.map { ($0.id, $0) })
        var zones = autoLayoutFirstWinsDictionary(scene.zones.map { ($0.zoneId, $0) })
        guard zones[zoneId] != nil else { return CanvasLayoutTransaction() }
        func rect(_ z: ZonePlacement) -> TileFrame {
            TileFrame(x: z.origin.x, y: z.origin.y, width: z.size.width, height: z.size.height)
        }
        let before = rect(previous)
        let grown = rect(zones[zoneId]!)
        // How far a zone rect, widened by the gap, reaches into a peer.
        func intrusion(_ z: TileFrame, _ peer: TileFrame) -> Double {
            max(0, min(z.x + z.width + gap, peer.x + peer.width) - max(z.x - gap, peer.x))
                * max(0, min(z.y + z.height + gap, peer.y + peer.height) - max(z.y - gap, peer.y))
        }
        let reachedNoDeeper = { (peer: TileFrame) in intrusion(grown, peer) <= intrusion(before, peer) + 0.001 }
        let touching = Set(
            scene.zones.filter { $0.zoneId != zoneId && reachedNoDeeper(rect($0)) }.map(\.zoneId)
            + scene.tiles.filter { $0.zoneId == nil && reachedNoDeeper($0.frame) }.map(\.id))
        var baseline = scene
        if let index = baseline.zones.firstIndex(where: { $0.zoneId == zoneId }) { baseline.zones[index] = previous }
        resolveOuterCollisions(tiles: &tiles, zones: &zones, scene: baseline, activeZone: zoneId,
                               preferredGap: gap, exempt: touching)
        var result = CanvasLayoutTransaction()
        for original in scene.tiles where tiles[original.id]?.frame != original.frame {
            result.tileFrames[original.id] = tiles[original.id]?.frame
        }
        for original in scene.zones where zones[original.zoneId] != original {
            result.zonePlacements[original.zoneId] = zones[original.zoneId]
        }
        return result
    }

    private static func resolveOuterCollisions(tiles: inout [UUID: LayoutTile], zones: inout [UUID: ZonePlacement], scene: Scene, activeZone: UUID?, preferredGap: Double, exempt: Set<UUID> = []) {
        enum Peer: Hashable { case zone(UUID), tile(UUID) }
        var peers = zones.keys.map(Peer.zone) + tiles.values.filter { $0.zoneId == nil }.map { Peer.tile($0.id) }
        // The order `String(describing:)` gave ("tile(…)" < "zone(…)", then the
        // id), without reflecting two strings per comparison.
        peers.sort { lhs, rhs in
            switch (lhs, rhs) {
            case let (.tile(a), .tile(b)), let (.zone(a), .zone(b)): return UUID.isOrderedBeforeByString(a, b)
            case (.tile, .zone): return true
            case (.zone, .tile): return false
            }
        }
        // Only a directly moved/resized ZONE projects force onto the outer
        // canvas. Tiles never do: a dragged bare tile is freeform (it may cross
        // anything and settles by the drop policy), and a member tile's world
        // ends at its zone. "Zones push tiles; tiles never push zones."
        guard let active = activeZone.map(Peer.zone) else { return }
        let baselineTiles = autoLayoutFirstWinsDictionary(scene.tiles.map { ($0.id, $0.frame) })
        let baselineZones = autoLayoutFirstWinsDictionary(scene.zones.map { placement in
            (placement.zoneId, TileFrame(x: placement.origin.x, y: placement.origin.y, width: placement.size.width, height: placement.size.height))
        })
        func frame(_ peer: Peer) -> TileFrame? {
            switch peer {
            case let .zone(id): return zones[id].map { TileFrame(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            case let .tile(id): return tiles[id]?.frame
            }
        }
        func id(_ peer: Peer) -> UUID {
            switch peer { case let .zone(id), let .tile(id): return id }
        }
        func baselineFrame(_ peer: Peer) -> TileFrame? {
            switch peer {
            case let .zone(id): return baselineZones[id]
            case let .tile(id): return baselineTiles[id]
            }
        }
        func translate(_ peer: Peer, _ dx: Double, _ dy: Double) {
            switch peer {
            case let .tile(id): tiles[id]?.frame.x += dx; tiles[id]?.frame.y += dy
            case let .zone(id):
                zones[id]?.origin.x += dx; zones[id]?.origin.y += dy
                for tileId in tiles.keys where tiles[tileId]?.zoneId == id { tiles[tileId]?.frame.x += dx; tiles[tileId]?.frame.y += dy }
            }
        }
        var queue = [active], visits = 0
        while !queue.isEmpty && visits < max(32, peers.count * peers.count * 2) {
            visits += 1
            let source = queue.removeFirst()
            guard let a = frame(source) else { continue }
            for other in peers where other != source && other != active {
                if source == active, exempt.contains(id(other)) { continue }
                guard let b = frame(other), overlapsOrUnderGap(a, b, gap: preferredGap) else { continue }
                // Push along the pair's own relation axis (how they were
                // separated before the gesture), not a global drag axis: a
                // corner graze must not shove a diagonal neighbor a full body
                // length sideways.
                let axis = pushAxis(
                    baselineA: baselineFrame(source) ?? a, baselineB: baselineFrame(other) ?? b,
                    currentA: a, currentB: b, gap: preferredGap)
                var dx = 0.0, dy = 0.0
                switch axis {
                case .horizontal:
                    dx = b.x + b.width / 2 >= a.x + a.width / 2
                        ? a.x + a.width + preferredGap - b.x
                        : a.x - preferredGap - b.x - b.width
                case .vertical:
                    dy = b.y + b.height / 2 >= a.y + a.height / 2
                        ? a.y + a.height + preferredGap - b.y
                        : a.y - preferredGap - b.y - b.height
                }
                if abs(dx) > 0.0001 || abs(dy) > 0.0001 { translate(other, dx, dy); queue.append(other) }
            }
        }
    }

    private static func valid(_ frame: TileFrame, in content: CGRect, against others: [TileFrame], gap: Double) -> Bool {
        frame.x >= content.minX - 0.001 && frame.y >= content.minY - 0.001
            && frame.x + frame.width <= content.maxX + 0.001 && frame.y + frame.height <= content.maxY + 0.001
            && !others.contains { overlapsOrUnderGap(frame, $0, gap: gap) }
    }

    private static func overlapsOrUnderGap(_ a: TileFrame, _ b: TileFrame, gap: Double) -> Bool {
        a.x < b.x + b.width + gap && a.x + a.width + gap > b.x && a.y < b.y + b.height + gap && a.y + a.height + gap > b.y
    }

    private static func squaredDistance(_ a: TileFrame, _ b: TileFrame) -> Double { let dx = a.x - b.x, dy = a.y - b.y; return dx * dx + dy * dy }
    /// A re-tidy solves from the first tidy's snapped frames, so its answer can
    /// land a grid step or two (1/64 pt each) from where tiles are: a real
    /// 22-tile zone moved 4 tiles by 1/32 pt. Less than 0.1 pt is no change.
    private static let tidyTolerance = 0.1
    private static func nearlyEqual(_ a: TileFrame, _ b: TileFrame) -> Bool {
        abs(a.x - b.x) <= tidyTolerance && abs(a.y - b.y) <= tidyTolerance
            && abs(a.width - b.width) <= tidyTolerance && abs(a.height - b.height) <= tidyTolerance
    }
    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool { UUID.isOrderedBeforeByString(lhs, rhs) }
}
