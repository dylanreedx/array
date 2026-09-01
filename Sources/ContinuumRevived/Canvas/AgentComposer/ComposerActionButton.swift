import AppKit
import ContinuumRevivedAgentUI

/// Custom composer action control. `NSControl` retains target/action, keyboard
/// focus and accessibility semantics without exposing an Aqua button bezel.
@MainActor
final class ComposerActionButton: NSControl, TokenThemed, AgentPageZoomScalable {
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private var isPressed = false
    /// WS5: the tile's page zoom. Every metric below derives from it, so 100%
    /// reproduces the shipped numbers exactly.
    private(set) var pageZoom: AgentPageZoom = .default

    var presentation: AgentComposerPresentation {
        didSet { applyPresentation() }
    }

    static let controlHeight: CGFloat = 32
    static let horizontalPadding = CGFloat(Space.m)
    static let itemSpacing = CGFloat(Space.s)

    /// WS5: the control height at a tile's page zoom. The `static let` above is
    /// kept so callers outside the zoomed tile keep compiling; this is the same
    /// value scaled, and an exact identity at 100%.
    static func controlHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(32)) }

    private var scaledControlHeight: CGFloat { Self.controlHeight(zoom: pageZoom) }
    private var scaledHorizontalPadding: CGFloat { CGFloat(pageZoom.scaled(Space.m)) }
    private var scaledItemSpacing: CGFloat { CGFloat(pageZoom.scaled(Space.s)) }
    private var scaledIconSide: CGFloat { CGFloat(pageZoom.scaled(14)) }
    private var scaledTitleHeight: CGFloat { CGFloat(pageZoom.scaled(18)) }

    init(presentation: AgentComposerPresentation, target: AnyObject? = nil, action: Selector? = nil) {
        self.presentation = presentation
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.card))
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .token(.label, zoom: pageZoom)
        titleLabel.alignment = .center
        addSubview(iconView)
        addSubview(titleLabel)
        setAccessibilityRole(.button)
        applyPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { isEnabled }

    /// The raw string width plus the label cell's own horizontal padding, which
    /// `NSString.size` does not include — without it the cell truncates the title.
    private var measuredTitleWidth: CGFloat {
        ceil((presentation.title as NSString).size(withAttributes: [.font: NSFont.token(.label, zoom: pageZoom)]).width)
            + CGFloat(pageZoom.scaled(4))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: scaledHorizontalPadding * 2 + scaledIconSide + scaledItemSpacing + measuredTitleWidth,
            height: scaledControlHeight
        )
    }

    override func layout() {
        super.layout()
        let iconSize = scaledIconSide
        let titleWidth = measuredTitleWidth
        let contentWidth = iconSize + scaledItemSpacing + titleWidth
        let start = floor((bounds.width - contentWidth) / 2)
        iconView.frame = NSRect(x: start, y: floor((bounds.height - iconSize) / 2), width: iconSize, height: iconSize)
        let titleHeight = scaledTitleHeight
        titleLabel.frame = NSRect(x: iconView.frame.maxX + scaledItemSpacing, y: floor((bounds.height - titleHeight) / 2), width: titleWidth, height: titleHeight)
    }

    override func becomeFirstResponder() -> Bool {
        guard isEnabled else { return false }
        let accepted = super.becomeFirstResponder()
        applyTokens()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        applyTokens()
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyTokens()
        defer {
            isPressed = false
            applyTokens()
        }
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                let point = convert(next.locationInWindow, from: nil)
                if bounds.contains(point) { _ = sendAction(action, to: target) }
                return
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 36 || event.keyCode == 49 {
            _ = sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        let active = isEnabled && presentation.primaryAction != .unavailable
        let accent: AccentToken = presentation.primaryAction == .stop ? .accentFailed : .accentInput
        // Loading is deliberately distinct from ordinary disabled: the resolver
        // supplies an hourglass and progressive title, while this quiet accent fill
        // preserves which operation is completing without implying it can be fired.
        let showsOperation = active || (presentation.isLoading && presentation.primaryAction != .unavailable)
        layer?.backgroundColor = (showsOperation ? accent.color : AgentSurfaceRole.composer.color).cgColor(for: theme)
        layer?.borderWidth = window?.firstResponder === self ? 2 : 1
        layer?.borderColor = (window?.firstResponder === self ? AgentLineRole.focusRing : .controlBoundary).color.cgColor(for: theme)
        let foreground = showsOperation ? TextToken.textOnAccent.color : TextToken.textSecondary.color
        titleLabel.textColor = foreground.nsColor(for: theme)
        iconView.contentTintColor = foreground.nsColor(for: theme)
        alphaValue = isPressed ? 0.78 : 1
    }

    /// WS5: re-derive every zoom-owned metric from scratch. Idempotent, and safe
    /// on a button already showing a presentation — same contract as `applyTokens`.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.card))
        titleLabel.font = .token(.label, zoom: pageZoom)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyPresentation() {
        titleLabel.stringValue = presentation.title
        iconView.image = CanvasSymbolImage.image(named: presentation.symbolName)
        isEnabled = presentation.isEnabled
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityEnabled(presentation.isEnabled)
        setAccessibilityValue(presentation.isLoading ? "In progress" : nil)
        toolTip = presentation.accessibilityLabel
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTokens()
    }
}
