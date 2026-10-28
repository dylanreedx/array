import AppKit
import ContinuumRevivedAgentUI

/// 20pt drawing-based context-window occupancy meter.
///
/// Unknown occupancy is represented as absence (`fraction == nil`), never as a
/// zero-length progress arc. Warning and critical states carry text/glyph markers
/// as well as colour so the state does not depend on hue alone.
@MainActor
final class AgentRadialContextMeterView: NSView, TokenThemed, AgentPageZoomScalable, NativeVectorDrawnContent {
    /// The meter's fixed drawn size. Not private: the compact row pins the view
    /// to it so priority arbitration can never collapse the glyph.
    static let side: CGFloat = 20

    /// The same fixed drawn size at one rung of the tile's page zoom. Exact
    /// identity with `side` at 100%.
    static func side(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(20)) }

    private static let lineWidth: CGFloat = 2.2

    private static func lineWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(2.2)) }

    /// This meter's rung of the tile's page zoom, delivered by the tile's
    /// subtree walk. Identity at 100%.
    private(set) var pageZoom: AgentPageZoom = .default

    private var presentation = AgentRadialContextMeterPresenter.present(nil)

    override var intrinsicContentSize: NSSize {
        let side = Self.side(zoom: pageZoom)
        return NSSize(width: side, height: side)
    }

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
        // A streaming tile re-applies the meter on every chunk; only a change to
        // what is drawn is worth a redraw.
        let changed = next.state != presentation.state || next.fraction != presentation.fraction
            || next.providerThresholdFraction != presentation.providerThresholdFraction
        presentation = next
        toolTip = next.detailText
        setAccessibilityLabel(next.accessibilityLabel)
        setAccessibilityHelp(next.detailText)
        setAccessibilityValue(next.label)
        if changed { needsDisplay = true }
    }

    /// What `draw(_:)` reads — not the tooltip or accessibility text, which change
    /// as tokens stream and are never drawn — for the resting chrome's fingerprint.
    /// Colours come from the appearance, whose change forces a resting redraw.
    var drawnContentFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(presentation.state)
        hasher.combine(presentation.fraction)
        hasher.combine(presentation.providerThresholdFraction)
        hasher.combine(pageZoom)
        return hasher.finalize()
    }

    func applyTokens() {
        needsDisplay = true
    }

    /// Every metric this meter owns is derived inside `draw(_:)` and
    /// `intrinsicContentSize`, so re-deriving them is a matter of invalidating
    /// both. Idempotent, and it touches no presentation state.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let theme = effectiveTokenTheme
        let diameter = min(bounds.width, bounds.height) - Self.lineWidth(zoom: pageZoom)
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
        if let threshold = presentation.providerThresholdFraction {
            drawProviderThreshold(in: rect, fraction: threshold, theme: theme)
        }
        drawStateOverlay(in: rect, theme: theme)
    }

    private func drawTrack(in rect: NSRect, theme: TokenTheme) {
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = Self.lineWidth(zoom: pageZoom)
        if trackIsDashed {
            track.setLineDash([CGFloat(pageZoom.scaled(1.6)), CGFloat(pageZoom.scaled(2.2))], count: 2, phase: 0)
        }
        LineToken.separator.color.nsColor(for: theme).setStroke()
        track.stroke()
    }

    private func drawArc(in rect: NSRect, fraction: Double, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = Self.lineWidth(zoom: pageZoom)
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

    private func drawProviderThreshold(in rect: NSRect, fraction: Double, theme: TokenTheme) {
        guard fraction >= 0, fraction <= 1 else { return }
        let angle = CGFloat(90 - fraction * 360) * .pi / 180
        let radius = rect.width / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let inner = NSPoint(
            x: center.x + cos(angle) * (radius - CGFloat(pageZoom.scaled(3))),
            y: center.y + sin(angle) * (radius - CGFloat(pageZoom.scaled(3))))
        let outer = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        let tick = NSBezierPath()
        tick.move(to: inner)
        tick.line(to: outer)
        tick.lineWidth = max(1, CGFloat(pageZoom.scaled(1)))
        TextToken.textPrimary.color.nsColor(for: theme).setStroke()
        tick.stroke()
    }

    /// Dashed means "this ring is not a whole measurement": no window, or a
    /// reading that has gone stale. An agent that has sent nothing yet is a
    /// solid, empty track — there is nothing to doubt.
    private var trackIsDashed: Bool {
        presentation.state == .unknown || presentation.state == .stale
    }

    /// The glyph drawn in the ring's centre, or nil for none.
    private var overlayMarker: String? {
        switch presentation.state {
        case .known, .empty:
            return nil
        case .warning:
            return "!"
        case .critical:
            return "!"
        case .unknown:
            return "?"
        case .stale:
            return "•"
        }
    }

    private func drawStateOverlay(in rect: NSRect, theme: TokenTheme) {
        guard let marker = overlayMarker else { return }
        let font = NSFont.systemFont(
            ofSize: CGFloat(pageZoom.scaled(presentation.state == .unknown ? 9 : 8)), weight: .bold)
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
        case .unknown, .stale, .empty:
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
        case .unknown, .stale, .empty:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }

    var qaState: AgentRadialContextMeterState { presentation.state }
    var qaFraction: Double? { presentation.fraction }
    var qaLabel: String { presentation.label }
    var qaDetail: String { presentation.detailText }
    var qaThresholdFraction: Double? { presentation.providerThresholdFraction }
    /// What `draw(_:)` puts in the ring's centre and whether its track is dashed.
    var qaOverlayMarker: String? { overlayMarker }
    var qaTrackIsDashed: Bool { trackIsDashed }
    var qaIntrinsicSide: CGFloat { intrinsicContentSize.width }
}
