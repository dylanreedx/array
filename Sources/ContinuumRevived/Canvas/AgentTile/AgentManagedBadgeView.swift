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
    /// The pill's text point size, and whether its text fits inside it to within
    /// one device pixel at the zoom it is shown at (Auto Layout snaps the pill to
    /// that grid, which inside a scaled under-bar at 25% is 1.7 pt).
    var qaTextPointSize: CGFloat { label.font?.pointSize ?? 0 }
    var qaTextFits: Bool {
        let pixel = 1 / max(0.01, abs(convertToBacking(NSSize(width: 1, height: 1)).width))
        return label.intrinsicContentSize.width <= label.frame.width + pixel && label.frame.maxX <= bounds.width + pixel
    }
    var qaTextFitDescription: String {
        "text needs \(label.intrinsicContentSize.width), label \(label.frame), badge \(bounds.size), intrinsic \(intrinsicContentSize.width)"
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
