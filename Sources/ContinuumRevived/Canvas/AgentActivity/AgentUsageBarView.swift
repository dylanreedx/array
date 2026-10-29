import AppKit
import ContinuumRevivedAgentUI

/// A remaining-allowance bar: a track, and a fill as long as what is LEFT.
///
/// Drawn, not layered. The colours resolve from tokens at draw time against
/// the view's own appearance, so an appearance flip redraws it correctly with
/// no stored CGColor to go stale — the failure the ui-probe census exists to
/// catch in layer-painting views.
@MainActor
final class AgentUsageBarView: NSView {
    /// 0...1 left. Nil draws the track alone: unknown is not empty.
    var remaining: Double? { didSet { if oldValue != remaining { needsDisplay = true } } }
    var state: AgentQuotaElementState = .known { didSet { if oldValue != state { needsDisplay = true } } }

    private let preferredSize: NSSize

    init(preferredSize: NSSize) {
        self.preferredSize = preferredSize
        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredSize.width == 0 ? NSView.noIntrinsicMetric : preferredSize.width,
               height: preferredSize.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The fill's hue: primary text at rest, so it reads as the number it is;
    /// amber and red only when the state is worth acting on, matching the value.
    static func fillToken(for state: AgentQuotaElementState) -> TokenColor {
        switch state {
        case .known: return TextToken.textPrimary.color
        case .warning: return AccentToken.accentApproval.color
        case .critical: return AccentToken.accentFailed.color
        case .unknown, .expired: return TextToken.textSecondary.color
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(bounds.height, preferredSize.height)
        let track = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        let radius = height / 2
        AgentLineRole.controlBoundary.color.nsColor(in: self).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard let remaining, remaining > 0 else { return }
        // A sliver is still drawn for 1% left: an empty-looking bar beside a
        // non-zero number would contradict it.
        let width = max(height, track.width * CGFloat(min(1, remaining)))
        Self.fillToken(for: state).nsColor(in: self).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: height),
                     xRadius: radius, yRadius: radius).fill()
    }

    var qaFillWidth: CGFloat {
        guard let remaining, remaining > 0 else { return 0 }
        return max(min(bounds.height, preferredSize.height), bounds.width * CGFloat(min(1, remaining)))
    }
}
