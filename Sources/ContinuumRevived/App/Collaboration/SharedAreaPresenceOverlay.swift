import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI
import ContinuumRevivedCollaborationProtocol

/// Drawn cursors stay quiet. Token accounting exists only inside the transient
/// hover/accessibility-focus card, never beside every moving pointer. The same
/// card offers Follow; only that button and the follow banner take clicks.
@MainActor
final class SharedAreaPresenceOverlay: NSView {
    weak var scene: SharedAreaSceneView?
    var peers: [Collaboration.Presence] = [] { didSet { refreshGeometry() } }
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
    private var bannerFrame: NSRect? {
        guard followBanner != nil else { return nil }
        let width = min(bounds.width - 24, bannerTextWidth + 28)
        return NSRect(x: (bounds.width - width) / 2, y: 12, width: max(0, width), height: 28)
    }

    init(scene: SharedAreaSceneView) {
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
        inspectedDevice = device.flatMap { id in visiblePeers.contains(where: { $0.identity.device == id }) ? id : nil }
        if inspectedDevice == nil { renderedUsageText = nil; cardRect = .zero }
        needsDisplay = true
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
        return convert(scene.screenPoint(forAreaPoint: .init(x: cursor.x, y: cursor.y)), from: scene)
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
            AccentToken.accentWorking.color.nsColor(in: self).setFill(); cursor.fill()
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
