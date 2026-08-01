import AppKit
import ContinuumRevivedAgentUI

/// Borderless trigger for `ChoicePopoverController`. The button paints every
/// visible state; AppKit is retained only for control, focus, and accessibility.
@MainActor
final class ChoiceButton: NSControl, TokenThemed {
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView(frame: .zero)
    private let popoverController = ChoicePopoverController()
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    var items: [ChoiceItem] = [] {
        didSet {
            if !items.contains(where: { $0.id == selectedID && $0.enabled }) {
                selectedID = items.first(where: \.enabled)?.id
            } else {
                updatePresentation()
            }
        }
    }
    var selectedID: String? {
        didSet { updatePresentation() }
    }
    var onSelection: ((ChoiceItem) -> Void)?

    static let controlHeight: CGFloat = 32
    static let horizontalPadding = CGFloat(Space.l)
    /// Owner correction (P4.10): idle is a quiet fill with no outline; keyboard
    /// focus and the open state use a 0.5 pt accent line plus a soft accent glow
    /// rather than a thick permanent border.
    static let focusBorderWidth: CGFloat = 0.5
    static let focusGlowRadius: CGFloat = 3
    static let focusGlowOpacity: Float = 0.55

    init(title: String = "Choose") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)
        titleLabel.stringValue = title
        titleLabel.font = .token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        chevronView.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(titleLabel)
        addSubview(chevronView)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(title)
        setAccessibilityHelp("Opens a list of choices")
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { isEnabled && items.contains(where: \.enabled) }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: NSFont.token(.label)]).width)
        return NSSize(width: Self.horizontalPadding * 2 + titleWidth + 14 + CGFloat(Space.m), height: Self.controlHeight)
    }

    override func layout() {
        super.layout()
        let chevronSize: CGFloat = 12
        chevronView.frame = NSRect(
            x: bounds.width - Self.horizontalPadding - chevronSize,
            y: floor((bounds.height - chevronSize) / 2),
            width: chevronSize,
            height: chevronSize
        )
        titleLabel.frame = NSRect(
            x: Self.horizontalPadding,
            y: floor((bounds.height - 18) / 2),
            width: max(0, chevronView.frame.minX - CGFloat(Space.m) - Self.horizontalPadding),
            height: 18
        )
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
        guard isEnabled else { return }
        isPressed = true
        applyTokens()
        defer { isPressed = false; applyTokens() }
        togglePopover()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 125: togglePopover()
        case 53 where popoverController.isPresented: popoverController.dismiss()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, items.contains(where: \.enabled) else { return false }
        togglePopover()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { popoverController.dismiss() }
        applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        applyTokens()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        applyTokens()
        return accepted
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        let focused = window?.firstResponder === self
        let accented = focused || popoverController.isPresented
        let background: TokenColor = (isHovered || popoverController.isPresented)
            ? AgentSurfaceRole.rowHover.color
            : AgentSurfaceRole.composer.color
        layer?.backgroundColor = background.cgColor(for: theme)
        layer?.borderWidth = accented ? Self.focusBorderWidth : 0
        layer?.borderColor = AgentLineRole.focusRing.color.cgColor(for: theme)
        layer?.masksToBounds = false
        layer?.shadowColor = AgentLineRole.focusRing.color.cgColor(for: theme)
        layer?.shadowOpacity = accented ? Self.focusGlowOpacity : 0
        layer?.shadowRadius = Self.focusGlowRadius
        layer?.shadowOffset = .zero
        titleLabel.textColor = (isEnabled ? TextToken.textPrimary : .textSecondary).color.nsColor(for: theme)
        chevronView.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        alphaValue = isPressed ? 0.78 : (isEnabled ? 1 : 0.58)
    }

    private func togglePopover() {
        guard isEnabled, items.contains(where: \.enabled) else { return }
        if popoverController.isPresented {
            popoverController.dismiss()
            applyTokens()
            return
        }
        popoverController.present(
            items: items,
            selectedID: selectedID,
            anchor: bounds,
            relativeTo: self
        ) { [weak self] item in
            guard let self else { return }
            self.selectedID = item.id
            self.onSelection?(item)
            _ = self.sendAction(self.action, to: self.target)
            self.applyTokens()
        }
        applyTokens()
    }

    private func updatePresentation() {
        if let item = items.first(where: { $0.id == selectedID }) {
            titleLabel.stringValue = item.title
            setAccessibilityValue(item.title)
        }
        setAccessibilityEnabled(isEnabled && items.contains(where: \.enabled))
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTokens()
    }
}
