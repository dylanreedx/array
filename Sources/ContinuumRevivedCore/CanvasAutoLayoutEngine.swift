import CoreGraphics
import Foundation

public struct CanvasLayoutTransaction: Equatable, Sendable {
    public var tileFrames: [UUID: TileFrame]
    public var zonePlacements: [UUID: ZonePlacement]
    public var blockedZoneIds: Set<UUID>

    public init(tileFrames: [UUID: TileFrame] = [:], zonePlacements: [UUID: ZonePlacement] = [:], blockedZoneIds: Set<UUID> = []) {
        self.tileFrames = tileFrames
        self.zonePlacements = zonePlacements
        self.blockedZoneIds = blockedZoneIds
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
    }

    public static func solve(scene: Scene, mutation: Mutation, gap preferredGap: Double, zonePadding preferredPadding: Double, headerHeight: Double) -> CanvasLayoutTransaction {
        let gap = max(0, preferredGap.isFinite ? preferredGap : 0)
        let padding = max(0, preferredPadding.isFinite ? preferredPadding : 0)
        let header = max(0, headerHeight.isFinite ? headerHeight : 0)
        var tiles = Dictionary(uniqueKeysWithValues: scene.tiles.map { ($0.id, $0) })
        var zones = Dictionary(uniqueKeysWithValues: scene.zones.map { ($0.zoneId, $0) })
        var activeTile: UUID?
        var activeZone: UUID?
        var vector = CGVector(dx: 1, dy: 0)
        var activeZoneOnlyTranslated = false
        var activeTileResizeIsHorizontal: Bool?
        var activeTileOriginalFrame: TileFrame?
        var activeTileMovedWithoutResize = false

        switch mutation {
        case let .tile(id, frame):
            if var tile = tiles[id] {
                activeTileOriginalFrame = tile.frame
                vector = CGVector(dx: frame.x - tile.frame.x, dy: frame.y - tile.frame.y)
                let widthDelta = abs(frame.width - tile.frame.width)
                let heightDelta = abs(frame.height - tile.frame.height)
                if widthDelta > 0.001 || heightDelta > 0.001 {
                    activeTileResizeIsHorizontal = widthDelta >= heightDelta
                } else {
                    activeTileMovedWithoutResize = abs(vector.dx) > 0.001 || abs(vector.dy) > 0.001
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
                if originDX != 0 || originDY != 0 {
                    for tileId in tiles.keys where tiles[tileId]?.zoneId == id {
                        tiles[tileId]?.frame.x += originDX
                        tiles[tileId]?.frame.y += originDY
                    }
                }
                vector = CGVector(dx: placement.origin.x - previous.origin.x + placement.size.width - previous.size.width,
                                  dy: placement.origin.y - previous.origin.y + placement.size.height - previous.size.height)
            }
            zones[id] = placement
            activeZone = id
        case .tidy:
            break
        }

        let targetZoneIds: [UUID]
        switch mutation {
        case let .tidy(zoneId): targetZoneIds = zoneId.map { [$0] } ?? zones.keys.sorted(by: uuidLess)
        case let .zone(id, _): targetZoneIds = [id]
        case let .tile(id, _): targetZoneIds = tiles[id]?.zoneId.map { [$0] } ?? []
        }

        var blocked: Set<UUID> = []
        for zoneId in targetZoneIds {
            guard var zone = zones[zoneId], !zone.collapsed,
                  zone.autoLayoutMode.resolves(globalEnabled: scene.globalEnabled) else { continue }
            // A zone is a rigid body while it is moved. Its members already received
            // the exact origin delta above; repacking here would make a simple move
            // unexpectedly alter the composition inside the zone.
            if zoneId == activeZone, activeZoneOnlyTranslated { continue }
            let memberIds = tiles.values.filter { $0.zoneId == zoneId }.map(\.id).sorted(by: uuidLess)
            guard !memberIds.isEmpty else { continue }

            if activeTileMovedWithoutResize,
               let activeTile, let original = activeTileOriginalFrame,
               tiles[activeTile]?.zoneId == zoneId,
               applySlotSwapIfTargeted(
                    activeTile: activeTile, originalFrame: original,
                    memberIds: memberIds, tiles: &tiles, vector: vector,
                    zone: zone, padding: padding, header: header) {
                // A slot exchange is already a complete, collision-free layout.
                // Feeding it through the general packer can reinterpret unequal
                // tile sizes as a different lane and create a diagonal jump.
                continue
            }

            let activeResizeHere = activeTileResizeIsHorizontal != nil
                && activeTile.map { tiles[$0]?.zoneId == zoneId } == true
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

        resolveOuterCollisions(tiles: &tiles, zones: &zones, activeTile: activeTile, activeZone: activeZone, preferredGap: gap, vector: vector)

        var result = CanvasLayoutTransaction(blockedZoneIds: blocked)
        for original in scene.tiles where tiles[original.id]?.frame != original.frame {
            result.tileFrames[original.id] = tiles[original.id]?.frame
        }
        for original in scene.zones where zones[original.zoneId] != original {
            result.zonePlacements[original.zoneId] = zones[original.zoneId]
        }
        return result
    }

    private static func applySlotSwapIfTargeted(
        activeTile: UUID, originalFrame: TileFrame,
        memberIds: [UUID], tiles: inout [UUID: LayoutTile], vector: CGVector,
        zone: ZonePlacement, padding: Double, header: Double
    ) -> Bool {
        guard var active = tiles[activeTile] else { return false }
        let center = CGPoint(x: active.frame.x + active.frame.width / 2, y: active.frame.y + active.frame.height / 2)
        let originalCenter = CGPoint(
            x: originalFrame.x + originalFrame.width / 2,
            y: originalFrame.y + originalFrame.height / 2)
        let horizontal = abs(vector.dx) >= abs(vector.dy)
        let candidates = memberIds.compactMap { id -> (UUID, TileFrame)? in
            guard id != activeTile, let frame = tiles[id]?.frame else { return nil }
            let frameCenter = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            let sharesLane: Bool
            let crossedMidpoint: Bool
            if horizontal {
                let overlap = min(originalFrame.y + originalFrame.height, frame.y + frame.height)
                    - max(originalFrame.y, frame.y)
                sharesLane = overlap >= min(originalFrame.height, frame.height) * 0.5
                let inDirection = vector.dx < 0 ? frameCenter.x < originalCenter.x : frameCenter.x > originalCenter.x
                crossedMidpoint = inDirection && (vector.dx < 0 ? center.x <= frameCenter.x : center.x >= frameCenter.x)
            } else {
                let overlap = min(originalFrame.x + originalFrame.width, frame.x + frame.width)
                    - max(originalFrame.x, frame.x)
                sharesLane = overlap >= min(originalFrame.width, frame.width) * 0.5
                let inDirection = vector.dy < 0 ? frameCenter.y < originalCenter.y : frameCenter.y > originalCenter.y
                crossedMidpoint = inDirection && (vector.dy < 0 ? center.y <= frameCenter.y : center.y >= frameCenter.y)
            }
            guard sharesLane, crossedMidpoint else { return nil }
            return (id, frame)
        }
        guard let target = candidates.min(by: { lhs, rhs in
            let lhsCenter = CGPoint(x: lhs.1.x + lhs.1.width / 2, y: lhs.1.y + lhs.1.height / 2)
            let rhsCenter = CGPoint(x: rhs.1.x + rhs.1.width / 2, y: rhs.1.y + rhs.1.height / 2)
            let lhsDistance = pow(center.x - lhsCenter.x, 2) + pow(center.y - lhsCenter.y, 2)
            let rhsDistance = pow(center.x - rhsCenter.x, 2) + pow(center.y - rhsCenter.y, 2)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return uuidLess(lhs.0, rhs.0)
        }), var displaced = tiles[target.0] else { return false }

        // Exchange positions only on the drag axis. Pointer jitter must never
        // turn a horizontal swap into a diagonal lane change (or vice versa).
        if horizontal {
            active.frame.y = originalFrame.y
            if target.1.x < originalFrame.x {
                let existingGap = max(0, originalFrame.x - (target.1.x + target.1.width))
                active.frame.x = target.1.x
                displaced.frame.x = active.frame.x + active.frame.width + existingGap
            } else {
                let existingGap = max(0, target.1.x - (originalFrame.x + originalFrame.width))
                displaced.frame.x = originalFrame.x
                active.frame.x = displaced.frame.x + displaced.frame.width + existingGap
            }
        } else {
            active.frame.x = originalFrame.x
            if target.1.y < originalFrame.y {
                let existingGap = max(0, originalFrame.y - (target.1.y + target.1.height))
                active.frame.y = target.1.y
                displaced.frame.y = active.frame.y + active.frame.height + existingGap
            } else {
                let existingGap = max(0, target.1.y - (originalFrame.y + originalFrame.height))
                displaced.frame.y = originalFrame.y
                active.frame.y = displaced.frame.y + displaced.frame.height + existingGap
            }
        }

        let content = CGRect(
            x: zone.origin.x + padding, y: zone.origin.y + header + padding,
            width: max(0, zone.size.width - 2 * padding),
            height: max(0, zone.size.height - header - 2 * padding))
        let pair = [activeTile: active.frame, target.0: displaced.frame]
        let untouched = memberIds.compactMap { id -> TileFrame? in
            guard id != activeTile, id != target.0 else { return nil }
            return tiles[id]?.frame
        }
        guard pair.values.allSatisfy({ valid($0, in: content, against: untouched, gap: 0) }),
              !overlapsOrUnderGap(active.frame, displaced.frame, gap: 0) else { return false }

        tiles[activeTile] = active
        tiles[target.0] = displaced
        return true
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

    private static func resolveOuterCollisions(tiles: inout [UUID: LayoutTile], zones: inout [UUID: ZonePlacement], activeTile: UUID?, activeZone: UUID?, preferredGap: Double, vector: CGVector) {
        enum Peer: Hashable { case zone(UUID), tile(UUID) }
        var peers = zones.keys.map(Peer.zone) + tiles.values.filter { $0.zoneId == nil }.map { Peer.tile($0.id) }
        peers.sort { String(describing: $0) < String(describing: $1) }
        let active = activeZone.map(Peer.zone) ?? activeTile.flatMap { tiles[$0]?.zoneId == nil ? Peer.tile($0) : nil }
        guard let active else { return }
        let horizontal = abs(vector.dx) >= abs(vector.dy), positive = horizontal ? vector.dx >= 0 : vector.dy >= 0
        func frame(_ peer: Peer) -> TileFrame? {
            switch peer {
            case let .zone(id): return zones[id].map { TileFrame(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            case let .tile(id): return tiles[id]?.frame
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
                // Zone boundaries are intentionally one-way during direct tile
                // manipulation. A bare tile must be able to cross a zone boundary
                // so the canvas's existing drop policy can adopt/re-home it on
                // mouse-up. The inverse remains solid: an actively moved/resized
                // zone still pushes bare tiles, and any indirectly pushed tile
                // still treats a zone as an obstacle.
                if source == active, activeTile != nil, case .zone = other { continue }
                guard let b = frame(other), overlapsOrUnderGap(a, b, gap: preferredGap) else { continue }
                let dx = horizontal ? (positive ? a.x + a.width + preferredGap - b.x : a.x - preferredGap - b.x - b.width) : 0
                let dy = horizontal ? 0 : (positive ? a.y + a.height + preferredGap - b.y : a.y - preferredGap - b.y - b.height)
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
