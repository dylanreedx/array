import AppKit
import ContinuumRevivedAgentUI

/// One window-chrome command drawn as an SF Symbol: nothing at rest, a row-hover
/// fill under the pointer, the row-selected fill while pressed or while its menu
/// is open. The look is `ToolbarIconButton`'s; the control is an `NSButton`, so
/// target/action, `performClick`, keyboard focus and accessibility stay AppKit's.
///
/// With a `title` it is the same control leading with text and trailing its
/// symbol — the workspace title menu — so the top bar has one owner for hover,
/// press, focus ring and corners rather than two that could drift apart.
@MainActor
final class ChromeIconButton: NSButton, TokenThemed {
    /// The square an icon-only button occupies: the sidebar header's 28pt.
    static let side: CGFloat = 28
    /// The room either side of a title.
    static let titlePadding: CGFloat = 8

    let symbolName: String
    /// The text a title button leads with; nil for an icon-only button.
    var titleText: String? { didSet { applyTitle(); invalidateIntrinsicContentSize() } }
    /// Held while the button's menu is open.
    var isActive = false { didSet { if isActive != oldValue { applyTokens() } } }
    /// Under the pointer. Settable so a probe can paint the hovered state.
    var isHovered = false { didSet { if isHovered != oldValue { applyTokens() } } }
    /// A shared choice menu opens on press; its owner supplies presentation.
    var onOpenMenu: (() -> Void)?

    private var isPressed = false { didSet { if isPressed != oldValue { applyTokens() } } }
    private var tracking: NSTrackingArea?

    init(symbolName: String, accessibilityLabel label: String, title: String? = nil) {
        self.symbolName = symbolName
        self.titleText = title
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        wantsLayer = true
        focusRingType = .exterior
        let titled = title != nil
        image = CanvasSymbolImage.image(
            named: symbolName, pointSize: titled ? 9 : 15, weight: titled ? .semibold : .medium)
        imageScaling = .scaleNone
        imagePosition = titled ? .imageTrailing : .imageOnly
        imageHugsTitle = true
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        // Stated, not inherited: a borderless NSButton reports AXUnknown.
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        applyTitle()
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        guard titleText != nil else { return NSSize(width: Self.side, height: Self.side) }
        return NSSize(width: ceil(super.intrinsicContentSize.width) + Self.titlePadding * 2, height: Self.side)
    }

    override func layout() {
        super.layout()
        applyCornerShape()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let role: AgentSurfaceRole? = (isActive || isPressed) ? .rowSelected : isHovered ? .rowHover : nil
        layer?.backgroundColor = role?.color.cgColor(in: self)
        contentTintColor = TextToken.textPrimary.color.nsColor(in: self)
        applyTitle()
        applyCornerShape()
    }

    /// An icon is a circle (a capsule on its square); a title is a control.
    /// Both resolve in the current corner style, so Sharp squares them.
    private func applyCornerShape() {
        if titleText == nil {
            layer?.applyCapsule()
        } else {
            layer?.applyCorner(.control)
        }
    }

    private func applyTitle() {
        guard let titleText else {
            title = ""
            return
        }
        attributedTitle = NSAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: TextToken.textPrimary.color.nsColor(in: self),
        ])
    }

    // The ring follows the fill's shape rather than the glyph's.
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = layer?.cornerRadius ?? 0
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let onOpenMenu {
            onOpenMenu()
            return
        }
        isPressed = true
        defer { isPressed = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let onOpenMenu, isEnabled, [36, 49, 125, 126].contains(event.keyCode) {
            onOpenMenu()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onOpenMenu else { return super.accessibilityPerformPress() }
        guard isEnabled else { return false }
        onOpenMenu()
        return true
    }
}
