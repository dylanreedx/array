import Foundation

/// Gesture-only magnetic intent. World frames and stable neighbor identity keep
/// the pointer, preview and committed placement independent of animated views.
public enum MagneticPlacement {
    public struct Neighbor: Sendable {
        public var id: UUID
        public var frame: TileFrame
        public init(id: UUID, frame: TileFrame) { self.id = id; self.frame = frame }
    }
    public struct Target: Equatable, Sendable {
        public var neighborId: UUID
        public var guides: [TileArrangement.SnapGuide]
        public var frame: TileFrame
    }
    public struct Result: Sendable {
        public var frame: TileFrame
        public var target: Target?
        public init(frame: TileFrame, target: Target?) { self.frame = frame; self.target = target }
    }

    private static func remainsNearDock(_ frame: TileFrame, _ neighbor: TileFrame,
                                        guide: TileArrangement.SnapGuide?, tolerance: Double) -> Bool {
        switch guide {
        case .leadingToTrailingGap, .trailingToLeadingGap:
            return frame.y <= neighbor.y + neighbor.height + tolerance
                && frame.y + frame.height >= neighbor.y - tolerance
        case .topToBottomGap, .bottomToTopGap:
            return frame.x <= neighbor.x + neighbor.width + tolerance
                && frame.x + frame.width >= neighbor.x - tolerance
        default: return false
        }
    }

    /// Leaving an existing gap contact should feel like light resistance, not
    /// a 44-point dead zone. Other edge alignments retain their exact snap.
    public static func resizeContact(free: TileFrame, snapped: TileFrame, initial: TileFrame,
                                     edge: ResizeEdge, zoom: Double) -> TileFrame {
        guard zoom.isFinite, zoom > 0 else { return free }
        var result = snapped
        func blend(_ raw: Double, _ target: Double) -> Double {
            let t = min(1, abs(raw - target) * zoom / DragMagnetizeConfig.snapThresholdScreenPoints)
            let resistance = 0.35 * (1 - t * t * (3 - 2 * t))
            return raw + (target - raw) * resistance
        }
        if edge.touchesRight, free.x + free.width > initial.x + initial.width,
           abs(snapped.x + snapped.width - initial.x - initial.width) < 0.001 {
            result.width = blend(free.x + free.width, snapped.x + snapped.width) - result.x
        }
        if edge.touchesLeft, free.x < initial.x, abs(snapped.x - initial.x) < 0.001 {
            let right = result.x + result.width
            result.x = blend(free.x, snapped.x)
            result.width = right - result.x
        }
        if edge.touchesBottom, free.y + free.height > initial.y + initial.height,
           abs(snapped.y + snapped.height - initial.y - initial.height) < 0.001 {
            result.height = blend(free.y + free.height, snapped.y + snapped.height) - result.y
        }
        if edge.touchesTop, free.y < initial.y, abs(snapped.y - initial.y) < 0.001 {
            let bottom = result.y + result.height
            result.y = blend(free.y, snapped.y)
            result.height = bottom - result.y
        }
        return result
    }

    public static func resolve(free: TileFrame, neighbors: [Neighbor], previous: Target?, gap: Double, zoom: Double) -> Result {
        guard zoom.isFinite, zoom > 0 else { return Result(frame: free, target: nil) }
        let acquire = DragMagnetizeConfig.snapThresholdScreenPoints / zoom
        let release = DragMagnetizeConfig.snapReleaseScreenPoints / zoom
        var target: Target?
        if var held = previous, let neighbor = neighbors.first(where: { $0.id == held.neighborId }),
           remainsNearDock(free, neighbor.frame, guide: held.guides.first, tolerance: release) {
            var frame = free
            var guides: [TileArrangement.SnapGuide] = []
            for guide in held.guides {
                var candidate = frame
                let n = neighbor.frame
                switch guide {
                case .leadingToTrailingGap: candidate.x = n.x + n.width + gap
                case .trailingToLeadingGap: candidate.x = n.x - gap - free.width
                case .topToBottomGap: candidate.y = n.y + n.height + gap
                case .bottomToTopGap: candidate.y = n.y - gap - free.height
                case .leadingAligned: candidate.x = n.x
                case .trailingAligned: candidate.x = n.x + n.width - free.width
                case .topAligned: candidate.y = n.y
                case .bottomAligned: candidate.y = n.y + n.height - free.height
                }
                if max(abs(candidate.x - free.x), abs(candidate.y - free.y)) <= release {
                    frame = candidate
                    guides.append(guide)
                } else if guide == held.guides.first {
                    break // The dock itself was released: do not retain a stray corner.
                }
            }
            if !guides.isEmpty {
                // Acquire a perpendicular alignment while sliding along a held edge.
                let corner = TileArrangement.cornerSnap(free, others: [neighbor.frame], gap: gap, threshold: acquire)
                if corner.guides.first == guides.first, guides.count == 1, corner.guides.count > 1 {
                    frame = corner.frame
                    guides = corner.guides
                }
                held.frame = frame
                held.guides = guides
                target = held
            }
        }
        if target == nil {
            var bestDistance = Double.infinity
            for neighbor in neighbors.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let candidate = TileArrangement.cornerSnap(free, others: [neighbor.frame], gap: gap, threshold: acquire)
                guard !candidate.guides.isEmpty else { continue }
                let distance = max(abs(candidate.frame.x - free.x), abs(candidate.frame.y - free.y))
                if distance < bestDistance {
                    bestDistance = distance
                    target = Target(neighborId: neighbor.id, guides: candidate.guides, frame: candidate.frame)
                }
            }
        }
        guard let target else { return Result(frame: free, target: nil) }
        var attracted = free
        func pull(_ delta: Double) -> Double {
            let t = min(1, abs(delta) / acquire)
            return delta * (1 - t * t * (3 - 2 * t))
        }
        attracted.x += pull(target.frame.x - free.x)
        attracted.y += pull(target.frame.y - free.y)
        return Result(frame: attracted, target: target)
    }
}
