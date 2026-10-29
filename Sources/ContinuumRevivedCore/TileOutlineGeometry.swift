import CoreGraphics
import Foundation

/// Resolves outline clearance in SCREEN coordinates. This is presentation only:
/// it never moves, resizes, or persists the tile bodies supplied by the caller.
public enum TileOutlineGeometry {
    public struct Item: Equatable, Sendable {
        public let id: UUID
        public let rect: CGRect
        public let gap: CGFloat
        public let zIndex: Int

        public init(id: UUID, rect: CGRect, gap: CGFloat, zIndex: Int) {
            self.id = id
            self.rect = rect
            self.gap = gap
            self.zIndex = zIndex
        }
    }

    public struct Result: Equatable, Sendable {
        public let id: UUID
        /// Full stroke bounds, rather than the stroke's centre-line rectangle.
        public let rect: CGRect
        /// Areas to subtract when painting this outline. Higher tiles own any
        /// intersection; expanding their bounds leaves a visible breathing gap.
        public let occluders: [CGRect]
    }

    private struct Outsets {
        var left: CGFloat
        var right: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    /// The return order matches `items`. Higher zIndex wins an overlap; for ties,
    /// the later input item wins, matching a back-to-front canvas ordering.
    public static func resolve(_ items: [Item], gutter: CGFloat = 2) -> [Result] {
        let gutter = gutter.isFinite ? max(0, gutter) : 2
        let bodies = items.map { sanitized($0.rect) }
        var outsets = items.map { item in
            let gap = item.gap.isFinite ? max(0, item.gap) : 0
            return Outsets(left: gap, right: gap, top: gap, bottom: gap)
        }

        for i in items.indices {
            for j in items.indices where j > i {
                let a = bodies[i]
                let b = bodies[j]
                let horizontal = max(b.minX - a.maxX, a.minX - b.maxX)
                let vertical = max(b.minY - a.maxY, a.minY - b.maxY)
                // Actual body overlaps retain their outline clearance. Their
                // hidden outline sections are removed by the z-order pass below.
                guard horizontal >= 0 || vertical >= 0 else { continue }
                // For diagonal neighbours, separating on the roomier axis also
                // prevents rounded corners from crossing without squeezing both.
                if horizontal >= vertical {
                    let cap = (horizontal - gutter) / 2
                    if a.maxX <= b.minX {
                        outsets[i].right = min(outsets[i].right, cap)
                        outsets[j].left = min(outsets[j].left, cap)
                    } else {
                        outsets[i].left = min(outsets[i].left, cap)
                        outsets[j].right = min(outsets[j].right, cap)
                    }
                } else {
                    let cap = (vertical - gutter) / 2
                    if a.maxY <= b.minY {
                        outsets[i].bottom = min(outsets[i].bottom, cap)
                        outsets[j].top = min(outsets[j].top, cap)
                    } else {
                        outsets[i].top = min(outsets[i].top, cap)
                        outsets[j].bottom = min(outsets[j].bottom, cap)
                    }
                }
            }
        }

        let rings = zip(bodies, outsets).map { body, outset in
            let minX = body.minX - outset.left
            let maxX = body.maxX + outset.right
            let minY = body.minY - outset.top
            let maxY = body.maxY + outset.bottom
            // Tiny or degenerate bodies can be narrower than the desired gutter.
            // Collapse their ring instead of producing negative dimensions.
            return CGRect(x: minX <= maxX ? minX : (minX + maxX) / 2,
                          y: minY <= maxY ? minY : (minY + maxY) / 2,
                          width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
        return items.indices.map { i in
            let occluders = items.indices.compactMap { j -> CGRect? in
                guard j != i,
                      items[j].zIndex > items[i].zIndex || (items[j].zIndex == items[i].zIndex && j > i),
                      !rings[j].isEmpty else { return nil }
                let exclusion = rings[j].insetBy(dx: -gutter, dy: -gutter)
                return rings[i].intersects(exclusion) ? exclusion : nil
            }
            return Result(id: items[i].id, rect: rings[i], occluders: occluders)
        }
    }

    private static func sanitized(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite else { return .zero }
        return rect.standardized
    }
}
