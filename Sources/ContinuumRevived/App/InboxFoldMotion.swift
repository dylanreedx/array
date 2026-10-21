import AppKit
import QuartzCore

/// A short presentation over the native list. The table commits its new rows
/// immediately, so selection, accessibility and persistence never wait on motion.
/// Only materialized rows are photographed; the display link moves those images,
/// with no text measurement or table layout on a frame tick.
@MainActor
final class InboxFoldMotion: NSObject {
    static let expandDuration: TimeInterval = 0.26
    static let collapseDuration: TimeInterval = 0.21
    static let snapshotLimit = 40

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
    private var lastTimestamp: CFTimeInterval?
    private(set) var duration: TimeInterval = 0
    private(set) var elapsed: TimeInterval = 0
    var isAnimating: Bool { overlay != nil }
    var coveredViewsForQA: [NSView] { coveredViews.map(\.view) }
    var overlayPassesHitTestingForQA: Bool { overlay?.hitTest(.zero) == nil }
    var poses: [String: Pose] {
        Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.snapshot.key, Pose(frame: $0.view.frame, opacity: $0.view.alphaValue))
        })
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
        for key in keys.sorted() {
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
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover(liveViews)
        draw(fraction: 0)
        CATransaction.commit()
        let link = container.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = CACurrentMediaTime()
    }

    /// A streamed update may replace a native cell while the presentation keeps
    /// moving. Cover its replacement too; the latest content becomes visible at
    /// the existing deadline, without restarting or cutting short the unfold.
    func cover(_ views: [NSView]) {
        guard isAnimating else { return }
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

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { max(0, link.timestamp - $0) } ?? 1.0 / 60.0
        lastTimestamp = link.timestamp
        advance(by: dt)
    }

    /// Also stepped by the production fold witness, without wall-clock sleeps.
    func advance(by dt: TimeInterval) {
        guard isAnimating else { return }
        elapsed = min(duration, elapsed + max(0, dt))
        if elapsed >= duration { cancel(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw(fraction: CGFloat(elapsed / duration))
        CATransaction.commit()
    }

    private func draw(fraction: CGFloat) {
        let movement = Self.progress(at: fraction)
        let fade = 1 - pow(1 - fraction, 3)
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
        link?.invalidate()
        link = nil
        lastTimestamp = nil
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
