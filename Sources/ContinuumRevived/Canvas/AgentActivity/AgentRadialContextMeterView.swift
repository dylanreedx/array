import AppKit
import ContinuumRevivedAgentUI

/// 20pt drawing-based context-window occupancy meter.
///
/// Unknown occupancy is represented as absence (`fraction == nil`), never as a
/// zero-length progress arc. Warning and critical states carry text/glyph markers
/// as well as colour so the state does not depend on hue alone.
@MainActor
final class AgentRadialContextMeterView: NSView, TokenThemed {
    /// The meter's fixed drawn size. Not private: the compact row pins the view
    /// to it so priority arbitration can never collapse the glyph.
    static let side: CGFloat = 20
    private static let lineWidth: CGFloat = 2.2

    private var presentation = AgentRadialContextMeterPresenter.present(nil)

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        apply(presentation)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ next: AgentRadialContextMeterPresentation) {
        presentation = next
        toolTip = next.detailText
        setAccessibilityLabel(next.accessibilityLabel)
        setAccessibilityHelp(next.detailText)
        setAccessibilityValue(next.label)
        needsDisplay = true
    }

    func applyTokens() {
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let theme = effectiveTokenTheme
        let diameter = min(bounds.width, bounds.height) - Self.lineWidth
        guard diameter > 2 else { return }
        let rect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter)

        drawTrack(in: rect, theme: theme)
        if let fraction = presentation.fraction {
            drawArc(in: rect, fraction: fraction, color: accentColor(for: presentation.state, theme: theme))
        }
        drawStateOverlay(in: rect, theme: theme)
    }

    private func drawTrack(in rect: NSRect, theme: TokenTheme) {
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = Self.lineWidth
        if presentation.state == .unknown || presentation.state == .stale {
            track.setLineDash([1.6, 2.2], count: 2, phase: 0)
        }
        LineToken.separator.color.nsColor(for: theme).setStroke()
        track.stroke()
    }

    private func drawArc(in rect: NSRect, fraction: Double, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = Self.lineWidth
        path.lineCapStyle = .round
        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return }
        path.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: 90,
            endAngle: 90 - CGFloat(clamped * 360),
            clockwise: true)
        color.setStroke()
        path.stroke()
    }

    private func drawStateOverlay(in rect: NSRect, theme: TokenTheme) {
        let marker: String?
        switch presentation.state {
        case .known:
            marker = nil
        case .warning:
            marker = "!"
        case .critical:
            marker = "!"
        case .unknown:
            marker = "?"
        case .stale:
            marker = "•"
        }
        guard let marker else { return }
        let font = NSFont.systemFont(ofSize: presentation.state == .unknown ? 9 : 8, weight: .bold)
        let color = markerColor(for: presentation.state, theme: theme)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let size = (marker as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (marker as NSString).draw(at: point, withAttributes: attributes)
    }

    private func accentColor(for state: AgentRadialContextMeterState, theme: TokenTheme) -> NSColor {
        switch state {
        case .known:
            return AccentToken.accentDone.color.nsColor(for: theme)
        case .warning:
            return AccentToken.accentApproval.color.nsColor(for: theme)
        case .critical:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .unknown, .stale:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }

    private func markerColor(for state: AgentRadialContextMeterState, theme: TokenTheme) -> NSColor {
        switch state {
        case .known:
            return TextToken.textPrimary.color.nsColor(for: theme)
        case .warning:
            return AccentToken.accentApproval.color.nsColor(for: theme)
        case .critical:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .unknown, .stale:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }

    var qaState: AgentRadialContextMeterState { presentation.state }
    var qaFraction: Double? { presentation.fraction }
    var qaLabel: String { presentation.label }
    var qaDetail: String { presentation.detailText }
    var qaIntrinsicSide: CGFloat { intrinsicContentSize.width }
}
