import CoreGraphics
import Foundation

/// Where a newly created tile goes when the caller has expressed no spatial intent
/// (.plans/18).
///
/// The rule the user experiences: a new tile appears where they are looking. If the
/// centre of the viewport is empty the tile is centred on it; if a tile is already
/// there, that tile becomes the anchor and the new tile docks gap-adjacent on the
/// side that fits best. The old policy (`CanvasEngine.placementFrame`) scanned the
/// viewport top-left in 32pt row-major steps and took the first free slot, which is
/// deterministic but has no relationship to visual attention.
///
/// This is pure geometry: no view ownership, no persistence, no defaults reads.
///
/// **Coordinate space.** Everything here happens in ONE space chosen by the caller —
/// `viewport`, `siblings` and the returned frame must all be in it. The canvas has
/// two: flat `canvasState.tiles` are WORLD frames, while a `ZoneLayer`'s tiles are
/// ZONE-LOCAL and its placement origin is added back at layout time. Mixing them
/// produces a frame that looks right until the next workspace switch or relaunch.
public enum TileSpawnPlacement {

    public struct Context {
        /// The new tile's intended working size. It is never shrunk to make room.
        public var newSize: CGSize
        /// The viewport, in the placement space.
        public var viewport: CanvasViewport
        /// The visible canvas size in SCREEN points; `viewport.zoom` converts.
        public var visibleSize: CGSize
        /// Every tile the new one must not collide with, in the placement space.
        public var siblings: [Tile]
        /// The standard tile gap (`TileGapResolver.resolvedGap()`).
        public var gap: Double

        public init(
            newSize: CGSize,
            viewport: CanvasViewport,
            visibleSize: CGSize,
            siblings: [Tile],
            gap: Double
        ) {
            self.newSize = newSize
            self.viewport = viewport
            self.visibleSize = visibleSize
            self.siblings = siblings
            self.gap = gap
        }
    }

    /// Side order used only as the final tie-break. Right is the natural continuation
    /// for left-to-right work; left preserves the horizontal relationship when right
    /// has no room; vertical growth follows only after both horizontal options.
    /// It is declared here, in the order it is applied, so it cannot drift silently.
    enum Side: Int, CaseIterable {
        case right = 0
        case left = 1
        case below = 2
        case above = 3
    }

    /// How far a candidate was pushed away from its immediate adjacent position.
    /// Ring 0 is gap-adjacent to the anchor; higher rings have cleared a blocker.
    private struct Candidate {
        let rect: CGRect
        let side: Side
        let ring: Int
    }

    /// Areas and ratios are compared with an epsilon so the later tie-breaks actually
    /// fire instead of losing to floating-point dust in the visibility measurement.
    private static let ratioEpsilon = 0.001
    private static let areaEpsilon = 1.0
    /// Grid step for the ring search around an empty centre. Same 32pt grid the old
    /// first-fit scan used, so nudged placements still land on familiar coordinates.
    private static let gridStep = 32.0
    /// Bounded outward search: an immediate candidate plus at most two rings per side.
    /// Deliberately small — it stops a pathological canvas turning one click into an
    /// unbounded layout walk, and stops the tile landing so far from the anchor that
    /// their relationship is meaningless.
    private static let maxRing = 2

    public static func automatic(_ context: Context) -> TileFrame {
        let size = sanitizedSize(context.newSize)
        let zoom = context.viewport.zoom.isFinite && context.viewport.zoom > 0 ? context.viewport.zoom : 1
        let originX = context.viewport.x.isFinite ? context.viewport.x : 0
        let originY = context.viewport.y.isFinite ? context.viewport.y : 0
        let visibleWidth = max(Double(context.visibleSize.width).isFinite ? Double(context.visibleSize.width) : 0, 0) / zoom
        let visibleHeight = max(Double(context.visibleSize.height).isFinite ? Double(context.visibleSize.height) : 0, 0) / zoom
        let viewportRect = CGRect(x: originX, y: originY, width: visibleWidth, height: visibleHeight)
        let centre = CGPoint(x: viewportRect.midX, y: viewportRect.midY)
        let gap = context.gap.isFinite && context.gap > 0 ? context.gap : 0
        let obstacles = context.siblings.map { rect(for: $0.frame) }.filter { $0.width > 0 && $0.height > 0 }

        // A tile bigger than the viewport keeps its working size: centre the axis that
        // fits, and use a stable padded origin on an axis that cannot.
        if size.width > viewportRect.width || size.height > viewportRect.height {
            let x = size.width > viewportRect.width ? viewportRect.minX + gap : centre.x - size.width / 2
            let y = size.height > viewportRect.height ? viewportRect.minY + gap : centre.y - size.height / 2
            return TileFrame(x: x, y: y, width: size.width, height: size.height)
        }

        let candidates: [Candidate]
        if let anchor = anchorRect(at: centre, siblings: context.siblings) {
            candidates = dockCandidates(anchor: anchor, size: size, gap: gap, obstacles: obstacles)
        } else {
            candidates = centreCandidates(centre: centre, size: size)
        }

        // `candidates` is never empty: both generators always emit their ring-0 entries.
        let best = candidates.max { lhs, rhs in
            isBetter(rhs, than: lhs, viewport: viewportRect, obstacles: obstacles)
        }
        guard let chosen = best else {
            return TileFrame(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        }
        return TileFrame(x: chosen.rect.minX, y: chosen.rect.minY, width: size.width, height: size.height)
    }

    // MARK: - Anchor

    /// The topmost tile under the viewport centre, using the SAME z-order semantics as
    /// canvas hit-testing — an overlapped tile must not become the anchor merely
    /// because it happens to come first in storage.
    private static func anchorRect(at centre: CGPoint, siblings: [Tile]) -> CGRect? {
        guard let tile = CanvasEngine.hitTest(worldPoint: centre, tiles: siblings) else { return nil }
        let frame = rect(for: tile.frame)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    // MARK: - Candidate generation

    /// Empty centre: the new tile centred exactly on the point of attention, plus a
    /// compact ring of nearby offsets on the 32pt grid for the case where a tile's
    /// edge intrudes near the centre without containing it. Never the top-left scan.
    private static func centreCandidates(centre: CGPoint, size: CGSize) -> [Candidate] {
        let origin = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        var candidates = [Candidate(rect: CGRect(origin: origin, size: size), side: .right, ring: 0)]
        for ring in 1...maxRing {
            let step = gridStep * Double(ring)
            // The side carried here is only the tie-break label: it names the axis the
            // offset travels along, so ties between equally good ring offsets resolve
            // in the same documented order.
            let offsets: [(Double, Double, Side)] = [
                (step, 0, .right), (-step, 0, .left), (0, step, .below), (0, -step, .above),
                (step, step, .right), (-step, step, .left), (step, -step, .right), (-step, -step, .left)
            ]
            for (dx, dy, side) in offsets {
                let moved = CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
                candidates.append(Candidate(rect: moved, side: side, ring: ring))
            }
        }
        return candidates
    }

    /// Occupied centre: one gap-adjacent candidate per side, aligned to the anchor's
    /// centre on the perpendicular axis. Centre alignment is intentional — it makes
    /// two unequally sized tiles read as a relationship, where top alignment reads as
    /// another row-major layout artifact.
    ///
    /// Then, per side, up to `maxRing` outward candidates that advance past whatever
    /// blocks the previous one (plus the gap), preserving the side and the alignment.
    private static func dockCandidates(anchor: CGRect, size: CGSize, gap: Double, obstacles: [CGRect]) -> [Candidate] {
        var candidates: [Candidate] = []
        for side in Side.allCases {
            var current = immediate(side: side, anchor: anchor, size: size, gap: gap)
            candidates.append(Candidate(rect: current, side: side, ring: 0))
            for ring in 1...maxRing {
                // Clear ALL current blockers in one step, not just the first one found:
                // advancing past a nearer rectangle would land back inside a further
                // one and waste the ring.
                guard let blocker = furthestBlocker(of: current, in: obstacles, side: side) else { break }
                current = advanced(current, past: blocker, side: side, gap: gap)
                candidates.append(Candidate(rect: current, side: side, ring: ring))
            }
        }
        return candidates
    }

    private static func immediate(side: Side, anchor: CGRect, size: CGSize, gap: Double) -> CGRect {
        switch side {
        case .right:
            return CGRect(x: anchor.maxX + gap, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        case .left:
            return CGRect(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        case .below:
            return CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + gap, width: size.width, height: size.height)
        case .above:
            return CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        }
    }

    private static func advanced(_ candidate: CGRect, past blocker: CGRect, side: Side, gap: Double) -> CGRect {
        switch side {
        case .right:
            return CGRect(x: blocker.maxX + gap, y: candidate.minY, width: candidate.width, height: candidate.height)
        case .left:
            return CGRect(x: blocker.minX - gap - candidate.width, y: candidate.minY, width: candidate.width, height: candidate.height)
        case .below:
            return CGRect(x: candidate.minX, y: blocker.maxY + gap, width: candidate.width, height: candidate.height)
        case .above:
            return CGRect(x: candidate.minX, y: blocker.minY - gap - candidate.height, width: candidate.width, height: candidate.height)
        }
    }

    // MARK: - Ranking

    /// Lexicographic, in the order documented in .plans/18 §4. Deliberately not a
    /// weighted score: every decision this makes has to be explainable from the
    /// arrangement the user can see.
    private static func isBetter(_ lhs: Candidate, than rhs: Candidate, viewport: CGRect, obstacles: [CGRect]) -> Bool {
        let lhsVisible = visibleArea(lhs.rect, in: viewport)
        let rhsVisible = visibleArea(rhs.rect, in: viewport)

        // 0. On screen at all. This sits ABOVE the collision class deliberately: an
        //    outward ring that clears a very large blocker is collision-free but can
        //    land far outside the viewport, and a tile the user cannot see is always
        //    worse than one that overlaps something. .plans/18 §4 ranks collision
        //    first, which chose a slot 4,000pt off screen over a visible overlap.
        if (lhsVisible > 0) != (rhsVisible > 0) { return lhsVisible > 0 }

        // 1. Collision class — a free slot beats an overlapping one.
        let lhsFree = firstBlocker(of: lhs.rect, in: obstacles) == nil
        let rhsFree = firstBlocker(of: rhs.rect, in: obstacles) == nil
        if lhsFree != rhsFree { return lhsFree }

        // 2. Visible fraction of the tile. The infinite canvas is not the optimization
        //    target: the user cares where the tile lands NOW.
        let lhsArea = lhs.rect.width * lhs.rect.height
        let rhsArea = rhs.rect.width * rhs.rect.height
        let lhsRatio = lhsArea > 0 ? lhsVisible / lhsArea : 0
        let rhsRatio = rhsArea > 0 ? rhsVisible / rhsArea : 0
        if abs(lhsRatio - rhsRatio) > ratioEpsilon { return lhsRatio > rhsRatio }

        // 3. Absolute visible area, so a tiny fully visible sliver cannot beat a large
        //    tile that is equally visible in proportion.
        if abs(lhsVisible - rhsVisible) > areaEpsilon { return lhsVisible > rhsVisible }

        // 4. An immediate adjacent position beats one pushed further out.
        if lhs.ring != rhs.ring { return lhs.ring < rhs.ring }

        // 5. Stable direction order. Only ever a tie-break: it must never make a mostly
        //    offscreen right candidate beat a fully visible left one.
        //
        //    .plans/18 §4 has one more rule between rings and direction — prefer the
        //    candidate with more free room ahead of it. It is left out on purpose: with
        //    a centred anchor that is wider than it is tall, the vertical sides have
        //    more room than the horizontal ones, so the plan's own acceptance case
        //    ("all sides free and equally visible -> right wins") would fail, and side
        //    choice would swing on a measurement the user cannot see. Predictability is
        //    the whole point of this ticket: it goes right unless right is blocked or
        //    off screen.
        if lhs.side != rhs.side { return lhs.side.rawValue < rhs.side.rawValue }
        return false
    }

    // MARK: - Geometry helpers

    /// Strict intersection: edge-touching is legal, because the standard gap has
    /// already been applied to every candidate.
    private static func firstBlocker(of candidate: CGRect, in obstacles: [CGRect]) -> CGRect? {
        obstacles.first { obstacle in
            candidate.minX < obstacle.maxX && obstacle.minX < candidate.maxX
                && candidate.minY < obstacle.maxY && obstacle.minY < candidate.maxY
        }
    }

    /// The blocking rectangle that reaches furthest in the direction of travel, so one
    /// outward step clears every one of them.
    private static func furthestBlocker(of candidate: CGRect, in obstacles: [CGRect], side: Side) -> CGRect? {
        let blocking = obstacles.filter { obstacle in
            candidate.minX < obstacle.maxX && obstacle.minX < candidate.maxX
                && candidate.minY < obstacle.maxY && obstacle.minY < candidate.maxY
        }
        switch side {
        case .right: return blocking.max { $0.maxX < $1.maxX }
        case .left: return blocking.min { $0.minX < $1.minX }
        case .below: return blocking.max { $0.maxY < $1.maxY }
        case .above: return blocking.min { $0.minY < $1.minY }
        }
    }

    private static func visibleArea(_ rect: CGRect, in viewport: CGRect) -> Double {
        let intersection = rect.intersection(viewport)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        return Double(intersection.width * intersection.height)
    }

    private static func sanitizedSize(_ size: CGSize) -> CGSize {
        let width = Double(size.width).isFinite && size.width > 0 ? Double(size.width) : 1
        let height = Double(size.height).isFinite && size.height > 0 ? Double(size.height) : 1
        return CGSize(width: width, height: height)
    }

    private static func rect(for frame: TileFrame) -> CGRect {
        guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite, frame.height.isFinite else {
            return .null
        }
        return CGRect(x: frame.x, y: frame.y, width: max(0, frame.width), height: max(0, frame.height))
    }
}
