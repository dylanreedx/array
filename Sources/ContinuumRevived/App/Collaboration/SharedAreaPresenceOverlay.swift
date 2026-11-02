import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI
import ContinuumRevivedCollaborationProtocol

/// Drawn cursors stay quiet. Token accounting exists only inside the transient
/// hover/accessibility-focus card, never beside every moving pointer. The same
/// card offers Follow; only that button and the follow banner take clicks.
@MainActor
final class SharedAreaPresenceOverlay: NSView {
    weak var scene: (any SharedAreaPresenceSurface)?
    var peers: [Collaboration.Presence] = [] { didSet { retarget(); refreshGeometry() } }
    var onPointerExit: (() -> Void)?
    var onFollow: ((UUID) -> Void)?
    var onStopFollowing: (() -> Void)?
    /// The followed teammate's device, and a banner describing follow state:
    /// either "Following …" or why following ended. Nil draws nothing.
    var followedDevice: UUID? { didSet { if oldValue != followedDevice { refreshGeometry() } } }
    var followBanner: String? {
        didSet {
            guard oldValue != followBanner else { return }
            // Measured once per banner change, never in draw or hit testing.
            bannerTextWidth = followBanner.map { ($0 as NSString).size(withAttributes: [.font: NSFont.token(.label)]).width } ?? 0
            if followBanner != nil { bannerMeasurements += 1 }
            refreshGeometry()
        }
    }
    private var bannerTextWidth: CGFloat = 0
    /// Work counters for the budget witnesses: overlay paints, usage-card paints
    /// and banner text measurements.
    private(set) var drawCount = 0
    private(set) var cardDraws = 0
    private(set) var bannerMeasurements = 0
    /// Where the last paint put each teammate's cursor.
    private(set) var drawnCursors: [UUID: NSPoint] = [:]
    private(set) var inspectedDevice: UUID?
    private var pointer: NSPoint?
    private var pointerInspection = false
    private var pointerTracking: NSTrackingArea?
    private var cardRect: NSRect = .zero
    private(set) var renderedUsageText: String?
    /// Each teammate's cursor is played back from a short buffer of its
    /// positions, `delay` behind the newest, so it moves on every display frame
    /// at the pace the teammate moved — never stepping when a position arrives,
    /// never overshooting and pulling back. Lane positions carry the sender's
    /// sample time, and play back at that spacing whatever the network did to
    /// it; the delay covers the observed jitter plus one and a half sample
    /// intervals (about 2 samples: 30-50 ms at 60 Hz). Page positions carry no
    /// sample time, play back at their arrival spacing, and need a longer delay
    /// (capped at `maximumDelay`).
    struct Track {
        private(set) var samples: [(t: CFTimeInterval, p: CGPoint)] = []
        /// Recent (arrival - sample time) for lane positions. Their minimum is
        /// the fastest transit seen: it maps the sender's clock onto ours.
        private var transits: [CFTimeInterval] = []
        private var lastSentAt: Double?
        private var lastArrival: CFTimeInterval?
        private(set) var interval: CFTimeInterval = 1.0 / 60
        private(set) var delay: CFTimeInterval = SharedAreaPresenceOverlay.minimumDelay
        var target: CGPoint? { samples.last?.p }

        /// Drawn at `p` at once: a first sighting, or Reduce Motion.
        static func placed(_ p: CGPoint, at now: CFTimeInterval) -> Track {
            var track = Track(); track.samples = [(now - 1, p)]; return track
        }
        mutating func add(_ p: CGPoint, sentAt: Double?, at now: CFTimeInterval) {
            // Held still (first sighting, or playback caught up with the newest
            // position): only the held position matters.
            let held = !moving(at: now)
            if held, let last = samples.last { samples = [last] }
            var t = now, jitter: CFTimeInterval = 0
            if let sentAt {
                let transit = now - sentAt
                // A different sender clock (the teammate's app restarted).
                if let fastest = transits.min(), abs(transit - fastest) > 1 { transits = []; lastSentAt = nil }
                transits.append(transit)
                if transits.count > 90 { transits.removeFirst(transits.count - 90) }
                let fastest = transits.min() ?? transit
                jitter = (transits.max() ?? transit) - fastest
                t = sentAt + fastest
                if let last = lastSentAt, sentAt > last, sentAt - last < 0.25 { interval += (sentAt - last - interval) * 0.2 }
                lastSentAt = sentAt
            } else if let last = lastArrival, now - last < 0.5 {
                interval += (now - last - interval) * 0.3
            }
            lastArrival = now
            let wanted = min(SharedAreaPresenceOverlay.maximumDelay, max(SharedAreaPresenceOverlay.minimumDelay, jitter + 1.5 * interval))
            if let last = samples.last, t <= last.t { t = last.t + 0.001 }
            if held, let last = samples.last {
                // Movement starts from where the cursor is drawn, now: the held
                // position becomes the sample one interval before the new one,
                // and the delay is at least what puts playback on it. Taking a
                // shorter delay at once would start playback partway along and
                // skip the cursor forward.
                let start = max(last.t, t - interval)
                samples[samples.count - 1].t = start
                delay = max(wanted, now - start)
            } else {
                // Playback runs at `now - delay`, so a delay that grows faster
                // than time passes would run it backwards: the cursor would
                // retreat. Grow by at most 5 ms a sample (playback slows, never
                // reverses); shrink gently (it speeds up a little, never jumps).
                delay = wanted > delay ? min(wanted, delay + 0.005) : delay + (wanted - delay) * 0.05
            }
            samples.append((t, p))
            if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        }
        func position(at now: CFTimeInterval) -> CGPoint? {
            guard let last = samples.last else { return nil }
            let playback = now - delay
            if playback >= last.t { return last.p }
            guard let first = samples.first, playback > first.t else { return samples.first?.p }
            var index = samples.count - 1
            while index > 0, samples[index - 1].t > playback { index -= 1 }
            let a = samples[index - 1], b = samples[index]
            let f = CGFloat((playback - a.t) / max(0.000_001, b.t - a.t))
            return .init(x: a.p.x + (b.p.x - a.p.x) * f, y: a.p.y + (b.p.y - a.p.y) * f)
        }
        func moving(at now: CFTimeInterval) -> Bool { samples.count > 1 && now - delay < samples[samples.count - 1].t }
        /// Drops samples playback has passed, keeping the one it is leaving.
        mutating func trim(at now: CFTimeInterval) {
            let playback = now - delay
            var drop = 0
            while drop + 1 < samples.count, samples[drop + 1].t <= playback { drop += 1 }
            if drop > 0 { samples.removeFirst(drop) }
        }
    }
    nonisolated static let minimumDelay: CFTimeInterval = 0.03
    nonisolated static let maximumDelay: CFTimeInterval = 0.13
    private var tracks: [UUID: Track] = [:]
    private var frameLink: CADisplayLink?
    /// The instant this display frame shows; positions drawn and invalidated
    /// in one frame agree. Nil while no cursor is moving.
    private var frameTime: CFTimeInterval?
    /// Display frames the playback advanced, for the motion witness.
    private(set) var animationFrames = 0
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return followButtonFrame?.contains(local) == true || (followedDevice != nil && bannerFrame?.contains(local) == true) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if followedDevice != nil, bannerFrame?.contains(point) == true { onStopFollowing?(); return }
        guard followButtonFrame?.contains(point) == true, let id = inspectedDevice else { return }
        if id == followedDevice { onStopFollowing?() } else { onFollow?(id) }
    }
    /// The hover card's Follow / Stop following button, in overlay coordinates.
    var followButtonFrame: NSRect? {
        guard let id = inspectedDevice, let peer = visiblePeers.first(where: { $0.identity.device == id }),
              let card = cardFrame(for: peer) else { return nil }
        return NSRect(x: card.minX + 12, y: card.maxY - 40, width: min(160, card.width - 24), height: 28)
    }
    var followButtonTitle: String? {
        guard followButtonFrame != nil else { return nil }
        return inspectedDevice == followedDevice ? "Stop following" : "Follow view"
    }
    /// False in a canvas zone: the canvas draws follow state over the whole
    /// viewport (`SharedAreaFollowIndicatorView`), not inside the area.
    /// Each teammate's own colour, in a zone; nil keeps the working accent.
    var cursorColour: ((Collaboration.Presence) -> NSColor?)?
    var showsBanner = true { didSet { if oldValue != showsBanner { refreshGeometry() } } }
    private var bannerFrame: NSRect? {
        guard showsBanner, followBanner != nil else { return nil }
        let width = min(bounds.width - 24, bannerTextWidth + 28)
        return NSRect(x: (bounds.width - width) / 2, y: 12, width: max(0, width), height: 28)
    }

    init(scene: any SharedAreaPresenceSurface) {
        self.scene = scene
        super.init(frame: scene.areaCanvasView.bounds)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false); setAccessibilityRole(.group)
        setAccessibilityLabel("Collaborator cursors; inspect a teammate for reported usage")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    override func mouseExited(with event: NSEvent) {
        pointerMoved(to: nil); onPointerExit?()
    }
    func inspect(device: UUID?) {
        pointerInspection = false
        setInspected(device: device)
    }
    private func setInspected(device: UUID?) {
        let previous = inspectedDevice
        inspectedDevice = device.flatMap { id in visiblePeers.contains(where: { $0.identity.device == id }) ? id : nil }
        if inspectedDevice == nil { renderedUsageText = nil; cardRect = .zero }
        // No card before or after: nothing on screen changed, so a local mouse
        // move or a gliding cursor does not repaint the whole overlay.
        if previous != nil || inspectedDevice != nil { needsDisplay = true }
    }
    func pointerMoved(to point: NSPoint?) {
        pointer = point; pointerInspection = true
        reevaluatePointer()
    }
    /// Cursor updates, camera navigation and expiry can move the hit target
    /// while the physical mouse stays still. Re-check that same pointer.
    func refreshGeometry() {
        if pointerInspection { reevaluatePointer() }
        else if let id = inspectedDevice, !visiblePeers.contains(where: { $0.identity.device == id }) { setInspected(device: nil) }
        refreshAccessibility(); needsDisplay = true
    }
    private func reevaluatePointer() {
        guard let point = pointer else { setInspected(device: nil); return }
        if cardRect.contains(point), let id = inspectedDevice, let peer = visiblePeers.first(where: { $0.identity.device == id }),
           let frame = cardFrame(for: peer), frame.contains(point) { return }
        let nearest = visiblePeers.first { peer in
            guard let screen = cursorPoint(peer) else { return false }
            return hypot(screen.x - point.x, screen.y - point.y) <= 18
        }
        setInspected(device: nearest?.identity.device)
    }
    var visiblePeers: [Collaboration.Presence] {
        Array(peers.filter { $0.expiresAt > Date() && $0.cursor != nil }.prefix(64))
    }
    private func cursorPoint(_ peer: Collaboration.Presence) -> NSPoint? {
        guard let scene, let cursor = peer.cursor else { return nil }
        let area = tracks[peer.identity.device]?.position(at: frameTime ?? clock()) ?? CGPoint(x: cursor.x, y: cursor.y)
        return convert(scene.screenPoint(forAreaPoint: area), from: scene)
    }
    /// Page positions (a relay without the cursor lane, or before it opens).
    /// A lane position the controller already applied arrives here unchanged
    /// and adds nothing.
    private func retarget() {
        let now = clock(), snap = scene?.reduceMotion() ?? true
        var next: [UUID: Track] = [:]
        for peer in peers {
            guard let cursor = peer.cursor else { continue }
            let point = CGPoint(x: cursor.x, y: cursor.y), device = peer.identity.device
            guard var track = tracks[device], !snap else { next[device] = .placed(point, at: now); continue }
            if track.target != point { track.add(point, sentAt: nil, at: now) }
            next[device] = track
        }
        tracks = next
        updateFrameLink()
    }
    /// A lane position, stamped with the sender's sample time.
    func receive(_ update: SharedAreaController.CursorUpdate) {
        guard let cursor = update.cursor else { return }
        let now = clock(), point = CGPoint(x: cursor.x, y: cursor.y)
        if scene?.reduceMotion() ?? true || tracks[update.device] == nil {
            tracks[update.device] = .placed(point, at: now)
            invalidateCursor(update.device)
        } else if tracks[update.device]?.target != point {
            tracks[update.device]?.add(point, sentAt: update.sentAt, at: now)
        }
        updateFrameLink()
    }
    private func updateFrameLink() {
        let now = clock()
        let moving = tracks.values.contains { $0.moving(at: now) }
        if moving, frameLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(frameTick(_:)))
            link.add(to: .main, forMode: .common)
            frameLink = link
        } else if !moving, let link = frameLink {
            link.invalidate(); frameLink = nil; frameTime = nil
        }
    }
    @objc private func frameTick(_ link: CADisplayLink) { advanceFrame() }
    /// True while a display link is driving cursor playback.
    var isAnimating: Bool { frameLink != nil }
    /// One display frame of playback. Also stepped by the cursor motion witness,
    /// whose fixture window sits off every display where links do not tick.
    /// O(teammates): repaints only each cursor's old and new rect.
    func advanceFrame() {
        guard frameLink != nil else { return }
        animationFrames += 1
        let now = clock(); frameTime = now
        for device in Array(tracks.keys) { tracks[device]?.trim(at: now) }
        // A visible hover card follows its cursor.
        if inspectedDevice != nil { needsDisplay = true } else {
            for peer in visiblePeers { invalidateCursor(peer.identity.device) }
        }
        if pointerInspection { reevaluatePointer() }
        updateFrameLink()
    }
    private func invalidateCursor(_ device: UUID) {
        if let old = drawnCursors[device] { setNeedsDisplay(Self.cursorRect(at: old)) }
        if let peer = peers.first(where: { $0.identity.device == device }), let now = cursorPoint(peer) { setNeedsDisplay(Self.cursorRect(at: now)) }
    }
    /// The arrow and its name label.
    private static func cursorRect(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - 4, y: point.y - 10, width: 260, height: 34)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { frameLink?.invalidate(); frameLink = nil; frameTime = nil } else { updateFrameLink() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        renderedUsageText = nil; drawnCursors = [:]
        for peer in visiblePeers {
            guard let point = cursorPoint(peer), bounds.insetBy(dx: -20, dy: -20).contains(point) else { continue }
            drawnCursors[peer.identity.device] = point
            let cursor = NSBezierPath()
            cursor.move(to: point); cursor.line(to: .init(x: point.x + 5, y: point.y + 17))
            cursor.line(to: .init(x: point.x + 10, y: point.y + 11)); cursor.line(to: .init(x: point.x + 17, y: point.y + 10)); cursor.close()
            (cursorColour?(peer) ?? AccentToken.accentWorking.color.nsColor(in: self)).setFill(); cursor.fill()
            drawText(label(peer), at: .init(x: point.x + 20, y: point.y - 4), primary: true)
        }
        if let banner = followBanner, let frame = bannerFrame {
            let path = NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
            SurfaceToken.overlay.color.nsColor(in: self).setFill(); path.fill()
            LineToken.borderStrong.color.nsColor(in: self).setStroke(); path.lineWidth = 1; path.stroke()
            drawText(banner, at: .init(x: frame.minX + 14, y: frame.minY + 6), primary: true)
        }
        guard let id = inspectedDevice, let peer = visiblePeers.first(where: { $0.identity.device == id }), let frame = cardFrame(for: peer) else {
            cardRect = .zero; return
        }
        let lines = Self.usageLines(peer)
        cardDraws += 1
        cardRect = frame
        let path = NSBezierPath(roundedRect: cardRect, xRadius: CGFloat(CornerRole.card.radius), yRadius: CGFloat(CornerRole.card.radius))
        SurfaceToken.overlay.color.nsColor(in: self).setFill(); path.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); path.lineWidth = 1; path.stroke()
        for (offset, line) in lines.enumerated() {
            drawText(line, at: .init(x: cardRect.minX + 14, y: cardRect.minY + 12 + CGFloat(offset * 23)), primary: offset == 0)
        }
        if let button = followButtonFrame, let title = followButtonTitle {
            let shape = NSBezierPath(roundedRect: button, xRadius: CGFloat(CornerRole.card.radius), yRadius: CGFloat(CornerRole.card.radius))
            SurfaceToken.tileBody.color.nsColor(in: self).setFill(); shape.fill()
            LineToken.borderStrong.color.nsColor(in: self).setStroke(); shape.lineWidth = 1; shape.stroke()
            drawText(title, at: .init(x: button.minX + 12, y: button.minY + 6), primary: true)
        }
        renderedUsageText = lines.joined(separator: "\n")
    }
    private func cardFrame(for peer: Collaboration.Presence) -> NSRect? {
        guard let point = cursorPoint(peer), bounds.insetBy(dx: -20, dy: -20).contains(point) else { return nil }
        let width = min(380, max(240, bounds.width - 24)), height = CGFloat(Self.usageLines(peer).count * 23 + 30 + 40)
        return NSRect(x: max(12, min(bounds.width - width - 12, point.x + 24)),
            y: max(12, min(bounds.height - height - 12, point.y + 24)), width: width, height: height)
    }
    private func drawText(_ text: String, at point: NSPoint, primary: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.token(.label),
            .foregroundColor: (primary ? TextToken.textPrimary : .textSecondary).color.nsColor(in: self)]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
    func label(_ peer: Collaboration.Presence) -> String {
        String((peer.label ?? "Teammate \(peer.identity.person.rawValue.uuidString.prefix(6))").prefix(28))
    }
    static func usageLines(_ peer: Collaboration.Presence) -> [String] {
        let title = String((peer.label ?? "Teammate").prefix(28))
        guard let usage = peer.usage else { return [title, "Usage has not been reported", "Execution stays on its publishing host"] }
        guard usage.valid else { return [title, "Token usage unavailable", "Execution stays on its publishing host"] }
        var lines = [title, "\(usage.runningAgents) running · \(usage.coveredAgents) shared agents"]
        if let measured = usage.measuredAt {
            lines.append("Reported total: \(usage.inputTokens + usage.outputTokens) tokens")
            lines.append("Observed today (UTC): \(usage.todayInputTokens + usage.todayOutputTokens)")
            lines.append(usage.partial ? "Partial coverage · since \(ISO8601DateFormatter().string(from: usage.observedSince))" : "Provider-reported usage")
            lines.append("Last measurement: \(ISO8601DateFormatter().string(from: measured))")
        } else { lines.append("Token usage unavailable until a provider reports it") }
        return lines
    }
    private func refreshAccessibility() {
        let elements: [NSAccessibilityElement] = visiblePeers.compactMap { peer in
            guard let point = cursorPoint(peer) else { return nil }
            let element = SharedPresenceAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(label(peer)); inspect reported token usage")
            element.setAccessibilityFrameInParentSpace(.init(x: point.x - 10, y: point.y - 10, width: 36, height: 36))
            element.press = { [weak self] in self?.inspect(device: peer.identity.device) }
            let device = peer.identity.device
            element.setAccessibilityCustomActions([device == followedDevice
                ? NSAccessibilityCustomAction(name: "Stop following") { [weak self] in self?.onStopFollowing?(); return true }
                : NSAccessibilityCustomAction(name: "Follow \(label(peer))'s view") { [weak self] in self?.onFollow?(device); return true }])
            return element
        }
        var children: [NSAccessibilityElement] = elements
        if let banner = followBanner, let frame = bannerFrame {
            let element = SharedPresenceAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(followedDevice == nil ? .staticText : .button)
            element.setAccessibilityLabel(followedDevice == nil ? banner : "\(banner); press to stop following")
            element.setAccessibilityFrameInParentSpace(frame)
            if followedDevice != nil { element.press = { [weak self] in self?.onStopFollowing?() } }
            children.append(element)
        }
        setAccessibilityChildren(children)
    }
}

@MainActor
private final class SharedPresenceAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}
