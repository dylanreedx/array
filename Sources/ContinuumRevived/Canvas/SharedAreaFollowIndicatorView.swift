import AppKit

/// Following a teammate in a shared area: a frame in their colour around the
/// viewport and a pill, "Following Sam · Stop · esc" (IN-CANVAS panel 5). It is
/// screen-fixed, over the world plane, and takes clicks only on the pill.
@MainActor
final class SharedAreaFollowIndicatorView: NSView {
    var onStop: (() -> Void)?
    private(set) var name = ""
    private(set) var color = NSColor.systemOrange
    /// What the pill says, for witnesses.
    var pillText: String { "Following \(name)" }
    static let stopText = "Stop · esc"
    override var isFlipped: Bool { true }

    func configure(name: String, color: NSColor) {
        guard name != self.name || color != self.color else { return }
        self.name = name; self.color = color
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Following \(name). Press to stop following.")
        needsDisplay = true
    }

    var pillFrame: NSRect {
        let width = Self.textWidth(pillText, weight: .medium) + Self.textWidth(Self.stopText, weight: .regular) + 64
        return NSRect(x: (bounds.width - width) / 2, y: 14, width: width, height: 30)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        pillFrame.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        if pillFrame.contains(convert(event.locationInWindow, from: nil)) { onStop?() }
    }
    override func accessibilityPerformPress() -> Bool { onStop?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        edge.lineWidth = 3
        color.withAlphaComponent(0.85).setStroke(); edge.stroke()
        let pill = pillFrame
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        let label = NSAttributedString(string: pillText, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        label.draw(at: NSPoint(x: pill.minX + 16, y: pill.midY - label.size().height / 2))
        let stop = NSAttributedString(string: Self.stopText, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        stop.draw(at: NSPoint(x: pill.maxX - stop.size().width - 16, y: pill.midY - stop.size().height / 2))
    }

    private static func textWidth(_ text: String, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: weight == .medium ? 12 : 11, weight: weight)]).width
    }
}
