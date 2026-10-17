import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The composer's microphone, beside Send: a 32 pt circle, so the footer's
/// measured fit only loses one control's width, never a reflow per state.
/// While a session is live the tile's pill grows out of it and covers it.
///
/// It never takes first responder: a click must leave the editor focused, or
/// the focus loss would finish the very session the click is starting.
@MainActor
final class ComposerDictationButton: NSControl, TokenThemed, AgentPageZoomScalable {
    private let iconView = NSImageView(frame: .zero)
    private var isPressed = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private(set) var pageZoom: AgentPageZoom = .default
    private(set) var dictationState: DictationState = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The mic glyph is taller than it is wide; never let it overhang its box.
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply(.idle)
        applyPageZoom(.default)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize {
        let side = ComposerActionButton.controlHeight(zoom: pageZoom)
        return NSSize(width: side, height: side)
    }

    override func layout() {
        super.layout()
        layer?.applyCapsule()
        let side = CGFloat(pageZoom.scaled(16))
        iconView.frame = NSRect(
            x: floor((bounds.width - side) / 2), y: floor((bounds.height - side) / 2), width: side, height: side)
    }

    /// The glyph is an `NSImageView`, itself a control: left to the default
    /// hit test it takes the click and the button never fires.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; applyTokens() }
    override func mouseExited(with event: NSEvent) { isHovered = false; applyTokens() }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyTokens()
        defer {
            isPressed = false
            applyTokens()
        }
        _ = sendAction(action, to: target)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func apply(_ state: DictationState) {
        dictationState = state
        let label: String
        switch state {
        case .idle:
            label = "Dictate (⇧⌘D)"
        case .preparing:
            label = "Getting dictation ready — click to cancel"
        case .listening:
            label = "Finish dictation (⇧⌘D or ↩) — Esc discards"
        case .finalizing:
            label = "Finishing dictation"
        case .error(let failure):
            label = failure.composerMessage
        }
        toolTip = label
        setAccessibilityLabel(label)
        updateIcon()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = (isHovered ? AgentSurfaceRole.rowHover : AgentSurfaceRole.composer).color.cgColor(for: theme)
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        // Live is the one state that wears the input accent, on the outline and
        // the glyph, so a hot microphone reads at a glance across the canvas.
        let live = dictationState == .listening || dictationState == .preparing
        layer?.borderColor = (live ? AccentToken.accentInput.color : AgentLineRole.controlBoundary.color).cgColor(for: theme)
        iconView.contentTintColor = (live ? AccentToken.accentInput.color : TextToken.textSecondary.color).nsColor(for: theme)
        alphaValue = isPressed ? 0.78 : 1
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        updateIcon()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateIcon() {
        let symbol: String
        switch dictationState {
        case .idle, .preparing: symbol = "mic"
        case .listening, .finalizing: symbol = "mic.fill"
        case .error: symbol = "mic.slash"
        }
        iconView.image = CanvasSymbolImage.image(named: symbol, pointSize: CGFloat(pageZoom.scaled(12)), weight: .regular)
    }

    var qaSymbolState: DictationState { dictationState }
    var qaIsHovered: Bool { isHovered }
}
