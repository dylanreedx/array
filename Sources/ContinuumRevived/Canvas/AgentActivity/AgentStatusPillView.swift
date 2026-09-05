import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// One metric in the compact status row: a small icon, a label, a value, inside
/// a pill.
///
/// The pill is not decoration. Without a boundary the row rendered
/// `3%  5h 49% 7d 15% spend —` — six values and three labels in one
/// undifferentiated run, where `49%` sat next to `7d` and nothing said which
/// number belonged to which window. Grouping is the whole job: each pill makes
/// one label-value pair a single object, so the eye parses four things instead
/// of nine.
///
/// Every element also gets its OWN glyph. All three account chips previously
/// shared `person.crop.circle`, which is the other half of why they read as one
/// string — a repeated icon is worse than none, because it implies sameness.
/// Account scope still needs saying, but the tooltip and the accessibility
/// label say it in words, where there is room to be unambiguous.
///
/// `Radius.pill` (999) is used as documented: large enough that the layer
/// clamps it to half the height, so this stays a capsule at every page zoom.
@MainActor
final class AgentStatusPillView: NSView, TokenThemed, AgentPageZoomScalable {
    /// 18pt inside a 28pt row: it clears the row's 4pt insets with 2pt of air
    /// top and bottom, which is what keeps a bordered chip from looking wedged
    /// into the row.
    static let preferredHeight: CGFloat = 18
    static func preferredHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(18)) }

    private(set) var pageZoom: AgentPageZoom = .default

    private let icon = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let stack: NSStackView

    /// The tint the value carries. Held rather than read back off the label so
    /// `applyTokens` can re-resolve it for a new appearance.
    private var state: AgentQuotaElementState?
    /// Whether this pill is showing a real reading. A pill with nothing to say
    /// draws no fill at all — see `applyTokens`.
    private var hasReading = false

    private var heightConstraint: NSLayoutConstraint?
    private var iconSize: [NSLayoutConstraint] = []

    /// `leadingView` replaces the glyph when a metric already owns a richer
    /// mark of its own — the context ring is the obvious case, and putting it in
    /// the same capsule is what keeps the row from mixing one bare number in
    /// with three pills.
    private let leadingView: NSView?

    init(leadingView: NSView? = nil) {
        self.leadingView = leadingView
        stack = NSStackView(views: [leadingView ?? icon, labelField, valueField])
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        // Only OUR glyph is pinned. A supplied leading view owns its own size —
        // pinning the context ring to 10pt here would silently shrink a meter
        // that has its own zoom-scaled side.
        if leadingView == nil {
            iconSize = [
                icon.widthAnchor.constraint(equalToConstant: CGFloat(pageZoom.scaled(10))),
                icon.heightAnchor.constraint(equalToConstant: CGFloat(pageZoom.scaled(10))),
            ]
            NSLayoutConstraint.activate(iconSize)
        }

        // The label is prose-weight metadata; the value must not reflow as its
        // digits change, which is exactly what `captionMono` is for.
        labelField.font = .token(.caption, zoom: pageZoom)
        valueField.font = .token(.captionMono, zoom: pageZoom)
        for field in [labelField, valueField] {
            field.lineBreakMode = .byClipping
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = CGFloat(pageZoom.scaled(Space.s))
        stack.edgeInsets = Self.insets(zoom: pageZoom)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // A MINIMUM, not a fixed height. The context ring is 20pt and its size
        // is pinned by a witness at 18-20pt, so a hard 18pt pill made its own
        // inner stack spill by 1pt top and bottom — which `--ui-geometry-check`
        // caught. Content drives the height upward; the row's 28pt with 4pt
        // insets leaves exactly 20pt for it.
        let height = heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.preferredHeight(zoom: pageZoom))
        height.isActive = true
        heightConstraint = height
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        // The pill is one object to a screen reader; its parts are not
        // separately reachable, and the row aggregates the sentence anyway.
        setAccessibilityElement(false)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func insets(zoom: AgentPageZoom) -> NSEdgeInsets {
        NSEdgeInsets(
            top: 0,
            left: CGFloat(zoom.scaled(Space.m)),
            bottom: 0,
            right: CGFloat(zoom.scaled(Space.m)))
    }

    func apply(_ presentation: AgentQuotaElementPresentation) {
        state = presentation.state
        hasReading = true
        applySymbol(presentation.symbolName)
        labelField.stringValue = presentation.shortLabel
        valueField.stringValue = presentation.valueText
        toolTip = presentation.detailText
        applyTokens()
    }

    /// For a metric whose mark is its `leadingView` (the context ring): set the
    /// value and the state, leave the glyph alone.
    func apply(valueText: String, state: AgentQuotaElementState, detailText: String) {
        self.state = state
        hasReading = true
        labelField.stringValue = ""
        labelField.isHidden = true
        valueField.stringValue = valueText
        toolTip = detailText
        applyTokens()
    }

    /// Cost has no window name to label, so the pill shows glyph + amount.
    func apply(cost: AgentCostElementPresentation) {
        state = .known
        hasReading = true
        applySymbol("dollarsign.circle")
        labelField.stringValue = ""
        labelField.isHidden = true
        valueField.stringValue = cost.text
        toolTip = cost.detailText
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        // A pill with no reading paints NOTHING — `nil`, never `.clear`. A
        // painted transparent is an unregistered literal to the appearance
        // census, and a filled capsule around an em dash also reads as a
        // deliberate value when it is the absence of one.
        layer?.backgroundColor = hasReading ? SurfaceToken.cardMessage.color.cgColor(for: theme) : nil
        layer?.cornerRadius = capsuleRadius
        icon.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        labelField.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        valueField.textColor = Self.valueColor(for: state, theme: theme)
    }

    /// Half the height it actually has, not half the height it prefers: a pill
    /// hosting the 20pt context ring is 20pt, and `Radius.pill`'s 999 would be
    /// clamped by CA anyway — doing the arithmetic here keeps the QA accessor
    /// honest about what is drawn.
    private var capsuleRadius: CGFloat {
        let height = bounds.height > 0 ? bounds.height : Self.preferredHeight(zoom: pageZoom)
        return min(CGFloat(pageZoom.scaled(Radius.pill)), height / 2)
    }

    override func layout() {
        super.layout()
        // Arithmetic on a known bounds, not a measurement pass: the radius has
        // to follow a height that content can change.
        layer?.cornerRadius = capsuleRadius
    }

    /// The value carries the state, and only the two states worth acting on
    /// carry a hue. A row where every pill is coloured teaches nothing; amber
    /// and red mean something precisely because the resting case is quiet.
    private static func valueColor(for state: AgentQuotaElementState?, theme: TokenTheme) -> NSColor {
        switch state {
        case .known:
            return TextToken.textPrimary.color.nsColor(for: theme)
        case .warning:
            return AccentToken.accentApproval.color.nsColor(for: theme)
        case .critical:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .unknown, .expired, .none:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        labelField.font = .token(.caption, zoom: zoom)
        valueField.font = .token(.captionMono, zoom: zoom)
        stack.spacing = CGFloat(zoom.scaled(Space.s))
        stack.edgeInsets = Self.insets(zoom: zoom)
        heightConstraint?.constant = Self.preferredHeight(zoom: zoom)
        for constraint in iconSize { constraint.constant = CGFloat(zoom.scaled(10)) }
        // Symbols are rasterized at a point size, so re-make rather than re-pin.
        if leadingView == nil { applySymbol(currentSymbolName) }
        applyTokens()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var currentSymbolName = ""

    private func applySymbol(_ name: String) {
        currentSymbolName = name
        guard !name.isEmpty else {
            icon.image = nil
            icon.isHidden = true
            return
        }
        icon.isHidden = false
        let configuration = NSImage.SymbolConfiguration(
            pointSize: CGFloat(pageZoom.scaled(10)), weight: .medium)
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    // MARK: - QA

    var qaLabelText: String { labelField.isHidden ? "" : labelField.stringValue }
    var qaValueText: String { valueField.stringValue }
    var qaSymbolName: String { currentSymbolName }
    var qaIconHasImage: Bool { icon.image != nil }
    var qaHasFill: Bool { layer?.backgroundColor != nil }
    /// The pill must stay a capsule: the radius is half the height, never the
    /// literal 999 the token carries.
    var qaCornerRadius: CGFloat { layer?.cornerRadius ?? 0 }
    /// The value field's frame in a caller's coordinate space, so the row's
    /// drawable-width invariants still measure real glyphs.
    func qaValueFrame(in view: NSView) -> NSRect? {
        valueField.superview.map { $0.convert(valueField.frame, to: view) }
    }
}
