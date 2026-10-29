import AppKit
import ContinuumRevivedCore

/// A reversible presentation pose for an idle multi-selection. Tile records and
/// native content sizes stay untouched; actual view origins follow the pose so
/// hit-testing follows the lifted tile, including its title controls.
@MainActor
final class SelectionHoverPresentation {
    private struct Member: Equatable {
        let id: UUID
        var frame: TileFrame
    }
    private final class ViewReference {
        weak var view: TileNSView?
        init(_ view: TileNSView) { self.view = view }
    }
    private var posedIds: Set<UUID> = []
    private var views: [UUID: ViewReference] = [:]
    private var cachedMembers: [Member] = []
    private var cachedZoom: Double = 0
    private var cachedGap: CGFloat = 0
    private var cachedPose: [UUID: TileFrame] = [:]
    private static let animationKey = "selection.hover.position"

    /// Inputs and results are WORLD frames. Only the returned presentation
    /// frames, never these offsets, should be used by the selection's rings.
    func apply(canvas: CanvasNSView, frames: [(id: UUID, frame: TileFrame)],
               enabled: Bool, animated: Bool = true) -> [(id: UUID, frame: TileFrame)] {
        let zoom = canvas.viewport.zoom
        guard enabled, frames.count > 1, zoom.isFinite, zoom > 0 else {
            restore(canvas: canvas, ids: posedIds, animated: animated)
            posedIds.removeAll()
            cachedMembers = []
            cachedPose = [:]
            return frames
        }
        let members = frames.map { Member(id: $0.id, frame: $0.frame) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let ids = Set(members.map(\.id))
        restore(canvas: canvas, ids: posedIds.subtracting(ids), animated: animated)
        let gap = max(CGFloat(TileGapResolver.resolvedGap(defaults: canvas.autoLayoutDefaults) * zoom),
                      canvas.focusRingStyle.gap * 2 + 2)
        if members != cachedMembers || zoom != cachedZoom || gap != cachedGap {
            cachedMembers = members
            cachedZoom = zoom
            cachedGap = gap
            cachedPose = Self.pose(members, zoom: zoom, gap: gap)
        }
        posedIds = ids
        for member in members {
            guard let target = cachedPose[member.id], let view = view(for: member.id, canvas: canvas) else { continue }
            Self.move(view, to: CGPoint(x: target.x, y: target.y),
                      animated: animated && !canvas.autoLayoutReduceMotionProvider())
        }
        return frames.map { ($0.id, cachedPose[$0.id] ?? $0.frame) }
    }

    private func view(for id: UUID, canvas: CanvasNSView) -> TileNSView? {
        if let view = views[id]?.view, view.superview != nil, !view.hasRetiredFromScene, view.canvas === canvas {
            return view
        }
        guard let view = canvas.tileView(for: id) else { return nil }
        views[id] = ViewReference(view)
        return view
    }

    private func restore(canvas: CanvasNSView, ids: Set<UUID>, animated: Bool) {
        for id in ids {
            if let view = view(for: id, canvas: canvas), let tile = canvas.tileRecord(for: id) {
                let frame = canvas.worldFrame(forTileFrame: tile.frame, tileId: id)
                Self.move(view, to: CGPoint(x: frame.x, y: frame.y),
                          animated: animated && !canvas.autoLayoutReduceMotionProvider())
            } else {
                views[id]?.view?.layer?.removeAnimation(forKey: Self.animationKey)
            }
            views.removeValue(forKey: id)
        }
    }

    private static func pose(_ members: [Member], zoom: Double, gap: CGFloat) -> [UUID: TileFrame] {
        // Camera translation cancels out of pairwise clearance. Working in
        // scaled world space lets a pan reuse the pose without recomputing it.
        let original = members.map { member in
            CGRect(x: member.frame.x * zoom, y: member.frame.y * zoom,
                   width: member.frame.width * zoom, height: member.frame.height * zoom)
        }
        var rects = original
        for _ in 0..<max(8, min(32, members.count * 2)) {
            var changed = false
            for i in rects.indices {
                for j in rects.indices where j > i {
                    let a = rects[i], b = rects[j]
                    let horizontalGap = max(b.minX - a.maxX, a.minX - b.maxX)
                    let verticalGap = max(b.minY - a.maxY, a.minY - b.maxY)
                    if horizontalGap >= gap - 0.001 || verticalGap >= gap - 0.001 { continue }
                    // UUID-sorted input makes coincident centres deterministic.
                    let right = b.midX >= a.midX
                    let down = b.midY >= a.midY
                    let dx = right ? a.maxX + gap - b.minX : b.maxX + gap - a.minX
                    let dy = down ? a.maxY + gap - b.minY : b.maxY + gap - a.minY
                    if dx <= dy {
                        let half = dx / 2 * (right ? 1 : -1)
                        rects[i] = a.offsetBy(dx: -half, dy: 0)
                        rects[j] = b.offsetBy(dx: half, dy: 0)
                    } else {
                        let half = dy / 2 * (down ? 1 : -1)
                        rects[i] = a.offsetBy(dx: 0, dy: -half)
                        rects[j] = b.offsetBy(dx: 0, dy: half)
                    }
                    changed = true
                }
            }
            if !changed { break }
        }
        let count = CGFloat(members.count)
        let correctionX = zip(original, rects).reduce(CGFloat.zero) { $0 + $1.0.midX - $1.1.midX } / count
        let correctionY = zip(original, rects).reduce(CGFloat.zero) { $0 + $1.0.midY - $1.1.midY } / count
        return Dictionary(uniqueKeysWithValues: members.indices.map { i in
            var frame = members[i].frame
            // Selection should breathe, never visibly rearrange an overlapping
            // canvas. Outline clipping handles any overlap left by this cap.
            let dx = min(CGFloat(12), max(-12, rects[i].minX + correctionX - original[i].minX))
            let dy = min(CGFloat(12), max(-12, rects[i].minY + correctionY - original[i].minY))
            frame.x = Double(original[i].minX + dx) / zoom
            frame.y = Double(original[i].minY + dy - 4) / zoom
            return (members[i].id, frame)
        })
    }

    private static func move(_ view: TileNSView, to target: CGPoint, animated: Bool) {
        let layer = view.layer
        let from = layer?.presentation()?.position ?? layer?.position
        if !animated { layer?.removeAnimation(forKey: animationKey) }
        guard abs(view.frame.minX - target.x) > 0.001 || abs(view.frame.minY - target.y) > 0.001 else { return }
        // Setting one origin keeps AppKit's event geometry and visibility index
        // correct. Core Animation performs the finite visual settle afterwards.
        view.setFrameOrigin(target)
        guard animated, let layer, let from else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: layer.position)
        animation.duration = 0.11
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: animationKey)
    }
}
