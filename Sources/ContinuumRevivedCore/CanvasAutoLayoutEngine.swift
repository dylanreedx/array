import CoreGraphics
import Foundation

public struct CanvasLayoutTransaction: Equatable, Sendable {
    public var tileFrames: [UUID: TileFrame]
    public var zonePlacements: [UUID: ZonePlacement]
    public var blockedZoneIds: Set<UUID>
    /// The sibling the active move gesture is currently exchanging slots with.
    /// Gesture state: the caller feeds it back into the next frame's solve as
    /// `latchedSwapTarget` so the exchange is hysteretic instead of re-derived
    /// from jittery per-frame geometry.
    public var swapTargetTileId: UUID?

    public init(tileFrames: [UUID: TileFrame] = [:], zonePlacements: [UUID: ZonePlacement] = [:], blockedZoneIds: Set<UUID> = [], swapTargetTileId: UUID? = nil) {
        self.tileFrames = tileFrames
        self.zonePlacements = zonePlacements
        self.blockedZoneIds = blockedZoneIds
        self.swapTargetTileId = swapTargetTileId
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

        public init(id: UUID, frame: TileFrame, zoneId: UUID?, minimumSize: CGSize? = nil) {
            self.id = id
            self.frame = frame
            self.zoneId = zoneId
            self.minimumSize = minimumSize ?? CGSize(width: frame.width, height: frame.height)
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
        case settle(zoneId: UUID, anchor: UUID?, pin: Bool)
    }

    public static func solve(scene: Scene, mutation: Mutation, gap preferredGap: Double, zonePadding preferredPadding: Double, headerHeight: Double, latchedSwapTarget: UUID? = nil) -> CanvasLayoutTransaction {
        let gap = max(0, preferredGap.isFinite ? preferredGap : 0)
        let padding = max(0, preferredPadding.isFinite ? preferredPadding : 0)
        let header = max(0, headerHeight.isFinite ? headerHeight : 0)
        var tiles = Dictionary(uniqueKeysWithValues: scene.tiles.map { ($0.id, $0) })
        var zones = Dictionary(uniqueKeysWithValues: scene.zones.map { ($0.zoneId, $0) })
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
        case let .settle(zoneId, _, _): targetZoneIds = [zoneId]
        case let .zone(id, _): targetZoneIds = [id]
        case let .tile(id, _): targetZoneIds = tiles[id]?.zoneId.map { [$0] } ?? []
        }

        // Direct resize is deliberately non-destructive. It is not a packing
        // request: the pointer-owned rectangle changes, passive rectangles stay
        // exact, and only the owning container may grow to contain the result.
        if let activeTile, activeTileResizeIsHorizontal != nil,
           let zoneId = tiles[activeTile]?.zoneId, var zone = zones[zoneId] {
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
            if let original = scene.tiles.first(where: { $0.id == activeTile }),
               let changed = tiles[activeTile]?.frame, changed != original.frame {
                result.tileFrames[activeTile] = changed
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
        var newSwapTarget: UUID?
        for zoneId in targetZoneIds {
            guard var zone = zones[zoneId], !zone.collapsed,
                  zone.autoLayoutMode.resolves(globalEnabled: scene.globalEnabled) else { continue }
            // A zone is a rigid body while it is moved. Its members already received
            // the exact origin delta above; repacking here would make a simple move
            // unexpectedly alter the composition inside the zone.
            if zoneId == activeZone, activeZoneOnlyTranslated { continue }
            let memberIds = tiles.values.filter { $0.zoneId == zoneId }.map(\.id).sorted(by: uuidLess)
            guard !memberIds.isEmpty else { continue }

            // Rest-state magnetism: tidy and settle pull members into exact
            // gap-contact with the cluster instead of running the packer.
            var settleMover: (mover: UUID?, pin: Bool)?
            if case let .settle(_, anchor, pin) = mutation { settleMover = (anchor, pin) }
            if case .tidy = mutation { settleMover = (nil, false) }
            if let (mover, pin) = settleMover {
                let settled = settleMembers(
                    memberIds: memberIds, tiles: tiles, zone: zone,
                    gap: gap, padding: padding, header: header, mover: mover, pinMover: pin)
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
                    latched: latchedSwapTarget)
                for (id, frame) in outcome.frames { tiles[id]?.frame = frame }
                newSwapTarget = outcome.latch
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

        var result = CanvasLayoutTransaction(blockedZoneIds: blocked, swapTargetTileId: newSwapTarget)
        for original in scene.tiles where tiles[original.id]?.frame != original.frame {
            result.tileFrames[original.id] = tiles[original.id]?.frame
        }
        for original in scene.zones where zones[original.zoneId] != original {
            result.zonePlacements[original.zoneId] = zones[original.zoneId]
        }
        return result
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

    /// The member-move solver: the active tile always keeps its pointer frame;
    /// siblings receive minimal single-axis pushes; entering a sibling's
    /// baseline frame latches an origin exchange that persists until the pointer
    /// returns home or crosses into a different sibling.
    private static func solveMemberMove(
        activeTile: UUID, originalFrame: TileFrame, memberIds: [UUID],
        tiles: [UUID: LayoutTile], zone: ZonePlacement,
        gap: Double, padding: Double, header: Double, latched: UUID?
    ) -> (frames: [UUID: TileFrame], latch: UUID?) {
        guard let requested = tiles[activeTile]?.frame else { return ([:], nil) }
        let content = contentRect(zone: zone, padding: padding, header: header)
        var baseline: [UUID: TileFrame] = [:]
        for id in memberIds { baseline[id] = tiles[id]?.frame }
        baseline[activeTile] = originalFrame

        let center = CGPoint(x: requested.x + requested.width / 2, y: requested.y + requested.height / 2)
        func contains(_ frame: TileFrame, _ point: CGPoint) -> Bool {
            point.x >= frame.x && point.x <= frame.x + frame.width
                && point.y >= frame.y && point.y <= frame.y + frame.height
        }

        // Latch state machine: enter a sibling's BASELINE frame (stable — a
        // pushed sibling can't run away from its own swap) to latch; release
        // when the pointer returns home OR clearly leaves the latched slot's
        // neighborhood (the hysteresis band keeps edge jitter from oscillating
        // the topology, while a drag that moves on can't drop a stale exchange
        // somewhere surprising); entering a different sibling re-latches.
        let releaseBand = max(24, gap * 1.5)
        var latch: UUID? = latched.flatMap { memberIds.contains($0) && $0 != activeTile ? $0 : nil }
        if let current = latch, let frame = baseline[current] {
            let expanded = TileFrame(
                x: frame.x - releaseBand, y: frame.y - releaseBand,
                width: frame.width + 2 * releaseBand, height: frame.height + 2 * releaseBand)
            if !contains(expanded, center) { latch = nil }
        }
        if contains(originalFrame, center) {
            latch = nil
        } else if let entered = memberIds.first(where: { id in
            id != activeTile && baseline[id].map { contains($0, center) } == true
        }) {
            latch = entered
        }

        var frames = baseline
        frames[activeTile] = requested

        if let latch, var displaced = frames[latch] {
            displaced.x = originalFrame.x
            displaced.y = originalFrame.y
            frames[latch] = clampIntoContent(displaced, content: content)
            // An exchanged tile larger than the slot it inherits may press on
            // other siblings; resolve that minimally, never against the active.
            propagatePushes(
                from: latch, frames: &frames, baseline: baseline,
                exclude: [activeTile], content: content, gap: gap)
        } else {
            propagatePushes(
                from: activeTile, frames: &frames, baseline: baseline,
                exclude: [], content: content, gap: gap)
        }
        return (frames, latch)
    }

    /// Rest-state magnetism: greedily grow a gap-contact cluster from the
    /// top-left-most stationary member, absorbing whichever tile can join with
    /// the least movement; a just-moved tile joins last. Tiles already at exact
    /// gap-contact never move.
    private static func settleMembers(
        memberIds: [UUID], tiles: [UUID: LayoutTile], zone: ZonePlacement,
        gap: Double, padding: Double, header: Double, mover: UUID?, pinMover: Bool
    ) -> [UUID: TileFrame] {
        let content = contentRect(zone: zone, padding: padding, header: header)
        guard content.width > 0, content.height > 0 else { return [:] }
        var result: [UUID: TileFrame] = [:]
        for id in memberIds { if let tile = tiles[id] { result[id] = clampIntoContent(tile.frame, content: content) } }
        guard result.count > 1 else { return result }
        var pending = memberIds.filter { result[$0] != nil }
        // A pinned mover (completed slot exchange) is authoritative: it seeds
        // the cluster at its exact frame, residents it presses on are pushed
        // aside along one axis, and everyone else magnetizes onto that. It can
        // never relocate — in particular never to a different lane.
        if pinMover, let mover, result[mover] != nil {
            propagatePushes(from: mover, frames: &result, baseline: result, exclude: [], content: content, gap: gap)
            var cluster: [TileFrame] = [result[mover]!]
            pending.removeAll { $0 == mover }
            absorb(pending: &pending, cluster: &cluster, result: &result, mover: nil, content: content, gap: gap)
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
        absorb(pending: &pending, cluster: &cluster, result: &result, mover: mover, content: content, gap: gap)
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
        mover: UUID?, content: CGRect, gap: Double
    ) {
        while !pending.isEmpty {
            let wave = pending.contains { $0 != mover } ? pending.filter { $0 != mover } : pending
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
        return candidates.filter(isValid).min { lhs, rhs in
            let a = squaredDistance(lhs, frame), b = squaredDistance(rhs, frame)
            if a != b { return a < b }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
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

    private static func resolveOuterCollisions(tiles: inout [UUID: LayoutTile], zones: inout [UUID: ZonePlacement], scene: Scene, activeZone: UUID?, preferredGap: Double) {
        enum Peer: Hashable { case zone(UUID), tile(UUID) }
        var peers = zones.keys.map(Peer.zone) + tiles.values.filter { $0.zoneId == nil }.map { Peer.tile($0.id) }
        peers.sort { String(describing: $0) < String(describing: $1) }
        // Only a directly moved/resized ZONE projects force onto the outer
        // canvas. Tiles never do: a dragged bare tile is freeform (it may cross
        // anything and settles by the drop policy), and a member tile's world
        // ends at its zone. "Zones push tiles; tiles never push zones."
        guard let active = activeZone.map(Peer.zone) else { return }
        let baselineTiles = Dictionary(uniqueKeysWithValues: scene.tiles.map { ($0.id, $0.frame) })
        let baselineZones = Dictionary(uniqueKeysWithValues: scene.zones.map { placement in
            (placement.zoneId, TileFrame(x: placement.origin.x, y: placement.origin.y, width: placement.size.width, height: placement.size.height))
        })
        func frame(_ peer: Peer) -> TileFrame? {
            switch peer {
            case let .zone(id): return zones[id].map { TileFrame(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            case let .tile(id): return tiles[id]?.frame
            }
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
    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.uuidString < rhs.uuidString }
}
