import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// AppKit caches this static drawing until size, preference or appearance changes.
final class SidebarHeaderPatternView: NSView {
    var style: SidebarHeaderBackground = .none {
        didSet { if oldValue != style { needsDisplay = true } }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard style != .none, let context = NSGraphicsContext.current?.cgContext else { return }
        let ink = TextToken.textSecondary.color.nsColor(in: self)
        context.setLineWidth(0.5)
        // Horizontal strips fade the same paths towards the list without animation.
        for y in stride(from: CGFloat(0), to: bounds.height, by: 2) {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: y, width: bounds.width, height: 2))
            context.setStrokeColor(ink.withAlphaComponent(0.12 * (1 - y / max(1, bounds.height))).cgColor)
            context.setFillColor(ink.withAlphaComponent(0.15 * (1 - y / max(1, bounds.height))).cgColor)
            switch style {
            case .none: break
            case .dots:
                for x in stride(from: CGFloat(8), to: bounds.width, by: 12) {
                    for dotY in stride(from: CGFloat(8), to: bounds.height, by: 12) {
                        context.fillEllipse(in: CGRect(x: x, y: dotY, width: 1.2, height: 1.2))
                    }
                }
            case .diagonal:
                for x in stride(from: -bounds.height, to: bounds.width, by: 12) {
                    context.move(to: CGPoint(x: x, y: 0))
                    context.addLine(to: CGPoint(x: x + bounds.height, y: bounds.height))
                }
                context.strokePath()
            case .grid:
                for x in stride(from: CGFloat(0), to: bounds.width, by: 16) {
                    context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: bounds.height))
                }
                for lineY in stride(from: CGFloat(0), to: bounds.height, by: 16) {
                    context.move(to: CGPoint(x: 0, y: lineY)); context.addLine(to: CGPoint(x: bounds.width, y: lineY))
                }
                context.strokePath()
            case .contours:
                for offset in stride(from: CGFloat(-80), to: bounds.height + 80, by: 12) {
                    context.move(to: CGPoint(x: 0, y: offset))
                    context.addCurve(to: CGPoint(x: bounds.width, y: offset + 24),
                        control1: CGPoint(x: bounds.width * 0.35, y: offset + 70),
                        control2: CGPoint(x: bounds.width * 0.6, y: offset - 50))
                }
                context.strokePath()
            }
            context.restoreGState()
        }
    }
}
