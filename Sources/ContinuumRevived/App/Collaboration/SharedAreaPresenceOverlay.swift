import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI
import ContinuumRevivedCollaborationProtocol

/// Drawn cursors stay quiet. Token accounting exists only inside the transient
/// hover/accessibility-focus card, never beside every moving pointer.
@MainActor
final class SharedAreaPresenceOverlay: NSView {
    weak var scene: SharedAreaSceneView?
    var peers: [Collaboration.Presence] = [] { didSet { refreshGeometry() } }
    var onPointerExit: (() -> Void)?
    private(set) var inspectedDevice: UUID?
    private var pointer: NSPoint?
    private var pointerInspection = false
    private var pointerTracking: NSTrackingArea?
    private var cardRect: NSRect = .zero
    private(set) var renderedUsageText: String?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        renderedUsageText = nil
        for peer in visiblePeers {
            guard let point = cursorPoint(peer), bounds.insetBy(dx: -20, dy: -20).contains(point) else { continue }
            let cursor = NSBezierPath()
            cursor.move(to: point); cursor.line(to: .init(x: point.x + 5, y: point.y + 17))
            cursor.line(to: .init(x: point.x + 10, y: point.y + 11)); cursor.line(to: .init(x: point.x + 17, y: point.y + 10)); cursor.close()
            AccentToken.accentWorking.color.nsColor(in: self).setFill(); cursor.fill()
            drawText(label(peer), at: .init(x: point.x + 20, y: point.y - 4), primary: true)
        }
        guard let id = inspectedDevice, let peer = visiblePeers.first(where: { $0.identity.device == id }), let frame = cardFrame(for: peer) else {
            cardRect = .zero; return
        }
        let lines = Self.usageLines(peer)
        cardRect = frame
        let path = NSBezierPath(roundedRect: cardRect, xRadius: CGFloat(CornerRole.card.radius), yRadius: CGFloat(CornerRole.card.radius))
        SurfaceToken.overlay.color.nsColor(in: self).setFill(); path.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); path.lineWidth = 1; path.stroke()
        for (offset, line) in lines.enumerated() {
            drawText(line, at: .init(x: cardRect.minX + 14, y: cardRect.minY + 12 + CGFloat(offset * 23)), primary: offset == 0)
        }
        renderedUsageText = lines.joined(separator: "\n")
    }
    private func cardFrame(for peer: Collaboration.Presence) -> NSRect? {
        guard let point = cursorPoint(peer), bounds.insetBy(dx: -20, dy: -20).contains(point) else { return nil }
        let width = min(380, max(240, bounds.width - 24)), height = CGFloat(Self.usageLines(peer).count * 23 + 30)
        return NSRect(x: max(12, min(bounds.width - width - 12, point.x + 24)),
            y: max(12, min(bounds.height - height - 12, point.y + 24)), width: width, height: height)
    }
    private func drawText(_ text: String, at point: NSPoint, primary: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.token(.label),
            .foregroundColor: (primary ? TextToken.textPrimary : .textSecondary).color.nsColor(in: self)]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
    private func label(_ peer: Collaboration.Presence) -> String {
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
            return element
        }
        setAccessibilityChildren(elements)
    }
}

@MainActor
private final class SharedPresenceAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}
