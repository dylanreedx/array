import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Same compact rounded shape and typography as the branch chip.
@MainActor
final class AgentManagedBadgeView: NSView, TokenThemed, AgentPageZoomScalable {
    private let label = NSTextField(labelWithString: "Managed")
    private var zoom: AgentPageZoom = .default
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        label.lineBreakMode = .byClipping
        addSubview(label)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Managed mode")
        toolTip = "Managed mode · change in Settings ▸ Agents"
        applyPageZoom(.default)
        applyTokens()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    private var horizontalPadding: CGFloat { zoom.scaled(Space.m) }

    override var intrinsicContentSize: NSSize {
        // Round the text allocation outward: a fractional cell width can clip
        // the final glyph when AppKit draws into its integral text backing.
        NSSize(width: ceil(label.intrinsicContentSize.width) + 2 * horizontalPadding,
               height: BranchChipNSView.preferredHeight(zoom: zoom))
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: horizontalPadding, y: (bounds.height - label.intrinsicContentSize.height) / 2,
                             width: max(0, bounds.width - 2 * horizontalPadding), height: label.intrinsicContentSize.height)
    }
    func applyTokens() {
        let maroon = ManagedModeToken.maroon.nsColor(for: effectiveTokenTheme)
        layer?.backgroundColor = maroon.withAlphaComponent(ManagedModeToken.fillOpacity).cgColor
        layer?.borderColor = maroon.withAlphaComponent(ManagedModeToken.borderOpacity).cgColor
        label.textColor = TextToken.textPrimary.color.nsColor(for: effectiveTokenTheme)
    }
    func applyPageZoom(_ zoom: AgentPageZoom) {
        self.zoom = zoom
        label.font = .token(.label, zoom: zoom)
        layer?.cornerRadius = zoom.scaled(Radius.card)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}
