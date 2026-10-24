import CoreGraphics
import Foundation

/// Geometry for one group gesture, expressed entirely in WORLD coordinates.
/// Capture once at mouse-down and reuse for every pointer update so rounding and
/// minimum-size clamping never accumulate. Selection/focus and persistence belong
/// to the canvas owner; this helper neither moves zones nor changes membership.
public enum TileSelectionGeometry {
    public struct Snapshot: Sendable {
        public let bounds: TileFrame
        public let frames: [UUID: TileFrame]
        private let minimumScaleX: Double
        private let minimumScaleY: Double

        /// Rejects ambiguous or invalid baselines rather than partially transforming
        /// a selection. Kind minimums are sampled once, outside the pointer hot path.
        public init?(tiles: [Tile]) {
            guard !tiles.isEmpty else { return nil }
            var frames: [UUID: TileFrame] = [:]
            frames.reserveCapacity(tiles.count)
            var minX = Double.infinity
            var minY = Double.infinity
            var maxX = -Double.infinity
            var maxY = -Double.infinity
            var minimumScaleX = 0.0
            var minimumScaleY = 0.0
            for tile in tiles {
                let frame = tile.frame
                guard Self.isValid(frame), frames[tile.id] == nil else { return nil }
                let minimum = TileGeometry.minimumSize(for: tile.kind)
                minimumScaleX = max(minimumScaleX, Double(minimum.width) / frame.width)
                minimumScaleY = max(minimumScaleY, Double(minimum.height) / frame.height)
                frames[tile.id] = frame
                minX = min(minX, frame.x)
                minY = min(minY, frame.y)
                maxX = max(maxX, frame.x + frame.width)
                maxY = max(maxY, frame.y + frame.height)
            }
            let bounds = TileFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard Self.isValid(bounds), minimumScaleX.isFinite, minimumScaleY.isFinite else { return nil }
            self.frames = frames
            self.bounds = bounds
            self.minimumScaleX = minimumScaleX
            self.minimumScaleY = minimumScaleY
        }

        /// A rigid translation preserves every member's size and relative offset.
        public func translated(byWorldDelta delta: CGSize) -> [UUID: TileFrame]? {
            let dx = Double(delta.width)
            let dy = Double(delta.height)
            guard dx.isFinite, dy.isFinite else { return nil }
            var result: [UUID: TileFrame] = [:]
            result.reserveCapacity(frames.count)
            for (id, baseline) in frames {
                var frame = baseline
                frame.x += dx
                frame.y += dy
                guard Self.isValid(frame) else { return nil }
                result[id] = frame
            }
            return result
        }

        /// Resizes the arrangement, including its gaps, independently on each
        /// affected axis. Top/left coordinates increase down/right, like TileFrame.
        /// All members stop shrinking together when the first kind minimum is met.
        public func resized(byWorldDelta delta: CGSize, edge: ResizeEdge) -> [UUID: TileFrame]? {
            let dx = Double(delta.width)
            let dy = Double(delta.height)
            guard dx.isFinite, dy.isFinite else { return nil }
            let changesX = edge.touchesLeft || edge.touchesRight
            let changesY = edge.touchesTop || edge.touchesBottom
            let scaleX = changesX
                ? max(minimumScaleX, (bounds.width + (edge.touchesLeft ? -dx : dx)) / bounds.width)
                : 1
            let scaleY = changesY
                ? max(minimumScaleY, (bounds.height + (edge.touchesTop ? -dy : dy)) / bounds.height)
                : 1
            guard scaleX.isFinite, scaleY.isFinite else { return nil }
            // Use the fixed opposite edge as the affine anchor. An unaffected
            // axis is copied exactly, avoiding needless floating-point changes.
            let anchorX = edge.touchesLeft ? bounds.x + bounds.width : bounds.x
            let anchorY = edge.touchesTop ? bounds.y + bounds.height : bounds.y
            var result: [UUID: TileFrame] = [:]
            result.reserveCapacity(frames.count)
            for (id, baseline) in frames {
                let frame = TileFrame(
                    x: changesX ? anchorX + (baseline.x - anchorX) * scaleX : baseline.x,
                    y: changesY ? anchorY + (baseline.y - anchorY) * scaleY : baseline.y,
                    width: changesX ? baseline.width * scaleX : baseline.width,
                    height: changesY ? baseline.height * scaleY : baseline.height
                )
                guard Self.isValid(frame) else { return nil }
                result[id] = frame
            }
            return result
        }

        private static func isValid(_ frame: TileFrame) -> Bool {
            frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
                && (frame.x + frame.width).isFinite && (frame.y + frame.height).isFinite
        }
    }
}
