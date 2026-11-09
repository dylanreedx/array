import AppKit
import QuartzCore

/// A short presentation over the native list. The table commits its new rows
/// immediately, so selection, accessibility and persistence never wait on motion.
/// Production unfolds native row layers on the render server. Legacy card
/// previews retain the image presentation. Neither path measures text or lays
/// out the table on an animation frame.
@MainActor
final class InboxFoldMotion: NSObject {
    static let expandDuration: TimeInterval = 0.18
    static let collapseDuration: TimeInterval = 0.15
    static let snapshotLimit = 40
    /// Where the spring's remaining travel drops under 0.5% for good, as a
    /// fraction of the duration. The presentation retires there instead of
    /// holding the real rows hidden through a tail nobody can see; the fade is
    /// paced to land at the same point.
    static let settleFraction: CGFloat = {
        let steps = 1_000
        var settled = 1.0
        for step in stride(from: steps, through: 0, by: -1) {
            let fraction = CGFloat(step) / CGFloat(steps)
            guard abs(1 - progress(at: fraction)) < 0.005 else { break }
            settled = Double(fraction)
        }
        return CGFloat(settled)
    }()

    struct Snapshot {
        let key: String
        let frame: NSRect
        let image: NSImage?
        var opacity: CGFloat = 1
        let order: Int
    }

    struct Pose {
        let frame: NSRect
        let opacity: CGFloat
    }

    private struct Track {
        let snapshot: Snapshot
        let view: ImageView
        let from: Pose
        let to: Pose
    }

    /// Overlay chrome is never a second interactive or accessibility hierarchy.
    private final class Overlay: NSView {
        private let usesFlippedCoordinates: Bool
        init(in container: NSView) {
            usesFlippedCoordinates = container.isFlipped
            super.init(frame: container.bounds)
            setAccessibilityElement(false)
            setAccessibilityChildren([])
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { usesFlippedCoordinates }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class ImageView: NSView {
        let incoming: NSImageView
        let outgoing: NSImageView?
        init(image: NSImage, previous: NSImage?, frame: NSRect) {
            let contentFrame = NSRect(origin: .zero, size: frame.size)
            incoming = NSImageView(frame: contentFrame)
            outgoing = previous.map { _ in NSImageView(frame: contentFrame) }
            super.init(frame: frame)
            wantsLayer = true
            setAccessibilityElement(false)
            setAccessibilityChildren([])
            if let outgoing {
                outgoing.image = previous
                install(outgoing)
            }
            incoming.image = image
            install(incoming)
        }
        private func install(_ view: NSImageView) {
            view.imageScaling = .scaleAxesIndependently
            view.autoresizingMask = [.width, .height]
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        func blend(_ amount: CGFloat) {
            incoming.alphaValue = outgoing == nil ? 1 : amount
            outgoing?.alphaValue = 1 - amount
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private var overlay: Overlay?
    private var tracks: [Track] = []
    private var coveredViews: [(view: NSView, opacity: Float)] = []
    private var link: CADisplayLink?
    /// The clock time the presentation counts from, set one frame early so the
    /// frame committed with the click already shows motion.
    private var origin: CFTimeInterval?
    private(set) var duration: TimeInterval = 0
    private(set) var elapsed: TimeInterval = 0
    /// When the presentation retires: the spring's settle point.
    var settleTime: TimeInterval { duration * Double(Self.settleFraction) }
    var isAnimating: Bool { overlay != nil }
    var coveredViewsForQA: [NSView] { coveredViews.map(\.view) + liveTracks.map(\.view) }
    var usesRenderServerAnimationForQA: Bool {
        !liveTracks.isEmpty && link == nil
            && liveTracks.allSatisfy { $0.layer.animation(forKey: Self.liveAnimationKey) != nil }
    }
    var overlayPassesHitTestingForQA: Bool { overlay?.hitTest(.zero) == nil }
    var poses: [String: Pose] {
        if !liveTracks.isEmpty {
            return Dictionary(uniqueKeysWithValues: liveTracks.map { ($0.key, livePose($0, at: elapsed)) })
        }
        return Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.snapshot.key, Pose(frame: $0.view.frame, opacity: $0.view.alphaValue))
        })
    }
    var endpointsForQA: [String: (from: NSRect, to: NSRect)] {
        if !liveTracks.isEmpty {
            return Dictionary(uniqueKeysWithValues: liveTracks.map { ($0.key, ($0.from.frame, $0.to.frame)) })
        }
        return Dictionary(uniqueKeysWithValues: tracks.map { ($0.snapshot.key, ($0.from.frame, $0.to.frame)) })
    }

    /// The toolbar's firmer orientation spring gives the cards a little give
    /// without a visible bounce. Use a shorter response window to spread travel
    /// across the duration; normalizing the endpoint avoids a final snap.
    static func progress(at fraction: CGFloat) -> CGFloat {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        let spring = FloatingToolbarHostView.swing
        let decay = spring.damping / 2
        let frequency = sqrt(spring.stiffness - decay * decay)
        func response(_ time: CGFloat) -> CGFloat {
            1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
        }
        return response(fraction * 0.48) / response(0.48)
    }

    private struct LiveTrack {
        let key: String
        let view: NSView
        let layer: CALayer
        let coordinates: NSView
        let from: Pose
        let to: Pose
        let isGhost: Bool
    }
    private var liveTracks: [LiveTrack] = []
    private var manuallyAdvanced = false
    private var liveParent: (layer: CALayer, z: CGFloat)?
    private var retirement: DispatchWorkItem?
    private static let liveAnimationKey = "array.sidebar.unfold"

    private func livePose(_ track: LiveTrack, at time: TimeInterval) -> Pose {
        let fraction = CGFloat(time / duration)
        let movement = Self.progress(at: fraction)
        let fade = 1 - pow(1 - min(1, fraction / Self.settleFraction), 3)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * movement }
        let a = track.from.frame, b = track.to.frame
        return Pose(frame: NSRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY),
                                  width: mix(a.width, b.width), height: mix(a.height, b.height)),
                    opacity: mix(track.from.opacity, track.to.opacity))
    }

    /// Animate native card layers. No frame timer, text
    /// measurement or native layout runs during the unfold. Only departing
    /// visible children use snapshots; their AppKit-owned views stay in the table
    /// reuse pool. The click-through overlay owns only disposable image views.
    func startLive(from before: [String: Snapshot], to after: [String: Snapshot],
                   beforeViews: [String: NSView], afterViews: [String: NSView],
                   parentKey: String, expanded: Bool, container: NSView) {
        cancel()
        guard let parent = after[parentKey] ?? before[parentKey] else { return }
        let overlay = Overlay(in: container)
        overlay.wantsLayer = true
        self.overlay = overlay
        duration = expanded ? Self.expandDuration : Self.collapseDuration
        elapsed = 1 / Double(max(60, container.window?.screen?.maximumFramesPerSecond ?? 60))
        let parentFrame = parent.frame
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(overlay.bounds)
        path.addRect(parentFrame)
        mask.path = path
        mask.fillRule = .evenOdd
        overlay.layer?.mask = mask
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        if let row = afterViews[parentKey]?.superview {
            row.wantsLayer = true
            if let layer = row.layer {
                liveParent = (layer, layer.zPosition)
                layer.zPosition = 10_001
            }
        }
        for key in Set(beforeViews.keys).union(afterViews.keys).sorted() where key != parentKey {
            guard let snapshot = after[key] ?? before[key],
                  let view = afterViews[key] ?? beforeViews[key] else { continue }
            let depth = CGFloat(min(2, max(1, snapshot.order - parent.order)))
            func tucked(_ parent: NSRect) -> NSRect {
                NSRect(x: parent.minX + depth * 4,
                       y: container.isFlipped ? parent.maxY - snapshot.frame.height + depth * 3 : parent.minY - depth * 3,
                       width: max(1, parent.width - depth * 8), height: snapshot.frame.height)
            }
            let from = Pose(frame: before[key]?.frame ?? tucked(before[parentKey]?.frame ?? parentFrame),
                            opacity: before[key]?.opacity ?? 0)
            let to = Pose(frame: after[key]?.frame ?? tucked(parentFrame), opacity: after[key] == nil ? 0 : 1)
            guard from.frame != to.frame || from.opacity != to.opacity else { continue }
            let host: NSView
            if after[key] != nil {
                // Animate the card's own layer, never an AppKit row host that
                // can be recycled during a status reload.
                host = view
            } else {
                // AppKit still owns removed cards through its row reuse pool.
                // Never steal those views into an overlay or detach them later.
                guard let image = before[key]?.image else { continue }
                let ghost = ImageView(image: image, previous: nil, frame: to.frame)
                overlay.addSubview(ghost)
                host = ghost
            }
            host.wantsLayer = true
            guard let layer = host.layer else { continue }
            liveTracks.append(LiveTrack(key: key, view: host, layer: layer, coordinates: container,
                                        from: from, to: to, isGhost: after[key] == nil))
        }
        guard !liveTracks.isEmpty else { cancel(); return }
        installLiveAnimations()
        origin = CACurrentMediaTime() - elapsed
        let work = DispatchWorkItem { [weak self] in self?.cancel() }
        retirement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settleTime - elapsed), execute: work)
    }

    private func installLiveAnimations() {
        let count = 30
        for track in liveTracks {
            let transform = CAKeyframeAnimation(keyPath: "transform")
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            var transforms: [NSValue] = [], alphas: [NSNumber] = []
            for index in 0...count {
                let pose = livePose(track, at: duration * Double(index) / Double(count))
                let space = track.view.superview ?? track.view
                let reference = NSRect(origin: .zero, size: track.to.frame.size)
                var local = NSRect(x: pose.frame.minX - track.to.frame.minX,
                    y: pose.frame.minY - track.to.frame.minY,
                    width: pose.frame.width, height: pose.frame.height)
                if space.isFlipped != track.coordinates.isFlipped {
                    local.origin.y = reference.height - local.maxY
                }
                let base = space.convertToLayer(reference)
                let presented = space.convertToLayer(local)
                let sx = presented.width / max(1, base.width)
                let sy = presented.height / max(1, base.height)
                let anchor = track.layer.anchorPoint
                var value = CATransform3DMakeTranslation(
                    presented.minX - base.minX + base.width * anchor.x * (sx - 1),
                    presented.minY - base.minY + base.height * anchor.y * (sy - 1), 0)
                value = CATransform3DScale(value, sx, sy, 1)
                transforms.append(NSValue(caTransform3D: value))
                alphas.append(NSNumber(value: Double(pose.opacity)))
            }
            transform.values = transforms
            opacity.values = alphas
            let group = CAAnimationGroup()
            group.animations = [transform, opacity]
            group.duration = duration
            group.beginTime = track.layer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            track.layer.add(group, forKey: Self.liveAnimationKey)
        }
    }

    static func image(of view: NSView, in rect: NSRect? = nil) -> NSImage? {
        let rect = rect ?? view.bounds
        guard rect.width > 0, rect.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    /// Carry the currently drawn positions and pixels across a reversal. Restore
    /// the real cells before the caller takes its next native-list snapshot.
    func takePresentation() -> [String: Snapshot] {
        if !liveTracks.isEmpty {
            let time = manuallyAdvanced ? elapsed : (origin.map { CACurrentMediaTime() - $0 } ?? elapsed)
            let current = liveTracks.enumerated().map { index, track in
                let pose = livePose(track, at: min(duration, time))
                return Snapshot(key: track.key, frame: pose.frame, image: nil, opacity: pose.opacity, order: index)
            }
            cancel()
            return Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
        }
        let current = tracks.map { track -> Snapshot in
            let alpha = track.view.alphaValue
            track.view.alphaValue = 1
            let image = Self.image(of: track.view)
            track.view.alphaValue = alpha
            return Snapshot(key: track.snapshot.key, frame: track.view.frame,
                            image: image, opacity: alpha, order: track.snapshot.order)
        }
        cancel()
        return Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
    }

    func start(
        from before: [String: Snapshot], to after: [String: Snapshot],
        parentKey: String, expanded: Bool, container: NSView, covering liveViews: [NSView]
    ) {
        cancel()
        guard let parent = after[parentKey] ?? before[parentKey] else { return }
        let keys = Set(before.keys).union(after.keys).filter {
            before[$0]?.image != nil || after[$0]?.image != nil
        }
        guard !keys.isEmpty, keys.count <= Self.snapshotLimit else { return }
        let overlay = Overlay(in: container)
        self.overlay = overlay
        duration = expanded ? Self.expandDuration : Self.collapseDuration
        elapsed = 0
        // The parent row stays LIVE: it does not move, and its fold control
        // morphs on its own clock (`InboxSwarmFoldControl`). A photograph of it
        // would cross-fade a picture of the old glyph into a picture of the new
        // one and hide the real motion. The overlay is masked out over the
        // parent so the children still slide out from UNDER it.
        let parentFrame = (after[parentKey] ?? before[parentKey])?.frame ?? .zero
        for key in keys.sorted() where key != parentKey {
            guard let snapshot = after[key] ?? before[key],
                  let image = after[key]?.image ?? before[key]?.image else { continue }
            let depth = min(2, max(1, snapshot.order - parent.order))
            func tucked(under parentFrame: NSRect, height: CGFloat) -> NSRect {
                let inset = CGFloat(depth) * 4
                // Keep each child's real height, tucked behind the parent with
                // one or two small edges showing, like the resting decoration.
                let y = container.isFlipped
                    ? parentFrame.maxY - height + CGFloat(depth) * 3
                    : parentFrame.minY - CGFloat(depth) * 3
                return NSRect(x: parentFrame.minX + inset, y: y,
                              width: max(1, parentFrame.width - inset * 2), height: height)
            }
            let startFrame = before[key]?.frame
                ?? tucked(under: before[parentKey]?.frame ?? parent.frame, height: snapshot.frame.height)
            let endFrame = after[key]?.frame ?? tucked(under: parent.frame, height: snapshot.frame.height)
            let view = ImageView(image: image, previous: key == parentKey ? before[key]?.image : nil,
                                 frame: startFrame)
            view.layer?.zPosition = CGFloat(10_000 - snapshot.order)
            overlay.addSubview(view)
            tracks.append(Track(
                snapshot: snapshot, view: view,
                from: Pose(frame: startFrame, opacity: before[key]?.opacity ?? 0),
                to: Pose(frame: endFrame, opacity: after[key] == nil ? 0 : 1)))
        }
        guard !tracks.isEmpty else { cancel(); return }
        overlay.wantsLayer = true
        let mask = CAShapeLayer()
        let maskPath = CGMutablePath()
        maskPath.addRect(overlay.bounds)
        maskPath.addRect(parentFrame)
        mask.path = maskPath
        mask.fillRule = .evenOdd
        overlay.layer?.mask = mask
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        // The first frame presented after the click is already one frame in;
        // starting at fraction 0 would spend it repeating the old layout.
        let frame = 1 / Double(max(60, container.window?.screen?.maximumFramesPerSecond ?? 60))
        elapsed = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover(liveViews)
        draw(fraction: CGFloat(elapsed / duration))
        CATransaction.commit()
        let link = container.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        origin = CACurrentMediaTime() - frame
    }

    /// A streamed update may replace a native cell while the presentation keeps
    /// moving. Cover its replacement too; the latest content becomes visible at
    /// the existing deadline, without restarting or cutting short the unfold.
    func cover(_ views: [NSView]) {
        guard isAnimating else { return }
        if !liveTracks.isEmpty { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in views where !coveredViews.contains(where: { $0.view === view }) {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            coveredViews.append((view, layer.opacity))
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    /// Pose each frame for the moment it will be ON SCREEN, not the moment the
    /// callback happens to run.
    @objc private func tick(_ link: CADisplayLink) {
        guard let origin else { return }
        advance(by: link.targetTimestamp - origin - elapsed)
    }

    /// Also stepped by the production fold witness, without wall-clock sleeps.
    func advance(by dt: TimeInterval) {
        guard isAnimating else { return }
        elapsed = min(duration, elapsed + max(0, dt))
        if elapsed >= settleTime { cancel(); return }
        if !liveTracks.isEmpty { manuallyAdvanced = true; installLiveAnimations(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw(fraction: CGFloat(elapsed / duration))
        CATransaction.commit()
    }

    private func draw(fraction: CGFloat) {
        let movement = Self.progress(at: fraction)
        let fade = 1 - pow(1 - min(1, fraction / Self.settleFraction), 3)
        func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * movement }
        for track in tracks {
            let a = track.from.frame, b = track.to.frame
            let rect = NSRect(x: interpolate(a.minX, b.minX), y: interpolate(a.minY, b.minY),
                              width: interpolate(a.width, b.width), height: interpolate(a.height, b.height))
            if track.view.frame != rect { track.view.frame = rect }
            track.view.alphaValue = track.from.opacity + (track.to.opacity - track.from.opacity) * fade
            track.view.blend(fade)
        }
    }

    func cancel() {
        retirement?.cancel()
        retirement = nil
        for track in liveTracks {
            track.layer.removeAnimation(forKey: Self.liveAnimationKey)
            if track.isGhost, track.view.superview === overlay {
                track.view.removeFromSuperview()
            }
        }
        liveTracks.removeAll()
        manuallyAdvanced = false
        if let parent = liveParent { parent.layer.zPosition = parent.z }
        liveParent = nil
        link?.invalidate()
        link = nil
        origin = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (view, opacity) in coveredViews { view.layer?.opacity = opacity }
        coveredViews.removeAll()
        overlay?.removeFromSuperview()
        overlay = nil
        tracks.removeAll()
        CATransaction.commit()
    }

    isolated deinit { link?.invalidate() }
}
