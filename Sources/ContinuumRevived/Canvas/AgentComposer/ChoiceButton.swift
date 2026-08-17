import AppKit
import ContinuumRevivedAgentUI

/// Borderless trigger for `ChoicePopoverController`. The button paints every
/// visible state; AppKit is retained only for control, focus, and accessibility.
/// Subclassable at exactly one seam — the presented surface
/// (`presentPopover` / `presentedPopoverIsVisible` / `dismissPresentedPopover`)
/// — so `ProviderModelButton` can swap the flat list for the provider>model
/// picker while trigger paint, items, selection, and QA seams stay shared.
@MainActor
class ChoiceButton: NSControl, TokenThemed {
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
    /// Restore the trigger's neutral label after a transient action/confirmation.
    /// This keeps the visible control title owned by the custom button rather than
    /// leaking a stock menu's selected-item state into the sidebar.
    func setPresentationTitle(_ title: String) {
        selectedID = nil
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
        setAccessibilityValue(title)
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTokens()
    }
    /// Some clients include visible management commands that must not replace
    /// the selected value shown by the trigger.
    var keepsSelectionForItem: ((ChoiceItem) -> Bool)?
    /// Optional per-client width for anchored menus. Nil preserves the intrinsic
    /// sizing used by composer pickers; fixed-width clients can pin the panel.
    var preferredPopoverWidth: CGFloat?
    /// Callers offering actions opt into compact command anatomy and optional
    /// leading icons; value pickers retain checkmark rows by default.
    var popoverPresentation: ChoiceListPresentation = .choices

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
        chevronView.image = CanvasSymbolImage.image(named: "chevron.up.chevron.down")
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

    private static let chevronSize: CGFloat = 12

    /// The raw string width plus the label cell's own horizontal padding, which
    /// `NSString.size` does not include — without it the cell truncates the title
    /// at EVERY width (`ComposerActionButton.measuredTitleWidth` precedent;
    /// P5.5 live finding, `plan-P5.5-review-corrections.md` defect 4). One
    /// expression for both `intrinsicContentSize` and `layout()`, so the two
    /// cannot disagree by a chevron metric again.
    private var measuredTitleWidth: CGFloat {
        ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: NSFont.token(.label)]).width) + 4
    }

    /// What a button showing `title` needs, measured the way the button measures
    /// itself — for callers (the footer's fit decision) that must reason about a
    /// title BEFORE installing it.
    static func fittingWidth(forTitle title: String) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: NSFont.token(.label)]).width) + 4
        return horizontalPadding * 2 + titleWidth + CGFloat(Space.m) + chevronSize
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.horizontalPadding * 2 + measuredTitleWidth + CGFloat(Space.m) + Self.chevronSize,
            height: Self.controlHeight
        )
    }

    override func layout() {
        super.layout()
        let chevronSize = Self.chevronSize
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
        case 53 where presentedPopoverIsVisible: dismissPresentedPopover()
        default: super.keyDown(with: event)
        }
    }

    /// The presentation seam a subclass overrides together with
    /// `presentPopover()` so toggle/escape/token accents track ITS surface.
    var presentedPopoverIsVisible: Bool { popoverController.isPresented }
    func dismissPresentedPopover() { popoverController.dismiss() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, items.contains(where: \.enabled) else { return false }
        togglePopover()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissPresentedPopover() }
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
        let accented = focused || presentedPopoverIsVisible
        let background: TokenColor = (isHovered || presentedPopoverIsVisible)
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
        if presentedPopoverIsVisible {
            dismissPresentedPopover()
            applyTokens()
            return
        }
        presentPopover()
        applyTokens()
    }

    /// Deterministic probe entry point for the live popover path. It presents the
    /// same controller/list used by a click, then accepts through ChoiceListView;
    /// it is intentionally not a selectedID setter.
    @discardableResult
    func chooseForQA(id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id && $0.enabled }) else { return false }
        guard window != nil else {
            handleSelection(item)
            _ = sendAction(action, to: target)
            return true
        }
        presentPopover()
        popoverController.listView?.choose(id: item.id)
        return true
    }

    /// One presentation seam for mouse, keyboard, VoiceOver, and deterministic
    /// selection. Client-specific width is applied here, never in a QA-only branch.
    func presentPopover() {
        popoverController.present(
            items: items, selectedID: selectedID,
            presentation: popoverPresentation,
            anchor: bounds, relativeTo: self
        ) { [weak self] item in
            guard let self else { return }
            self.handleSelection(item)
            _ = self.sendAction(self.action, to: self.target)
        }
        pinPopoverWidthIfNeeded()
    }

    private func pinPopoverWidthIfNeeded() {
        guard let preferredPopoverWidth,
              let panel = popoverController.panel,
              let list = popoverController.listView else { return }
        var frame = panel.frame
        frame.size.width = preferredPopoverWidth
        panel.setFrame(frame, display: false)
        list.frame = NSRect(origin: .zero, size: frame.size)
        list.needsLayout = true
        list.layoutSubtreeIfNeeded()
    }

    func handleSelection(_ item: ChoiceItem) {
        if keepsSelectionForItem?(item) != true {
            selectedID = item.id
        }
        onSelection?(item)
        applyTokens()
    }

    // Deterministic probes. `stringValue` never changes when the cell elides at
    // draw time, so a truncation gate must MEASURE the label's drawable width
    // against what the string plus the cell's own padding need — comparing
    // strings is vacuous by construction.
    var qaRenderedTitle: String { titleLabel.stringValue }
    var qaSelectedTitle: String? { items.first(where: { $0.id == selectedID })?.title }
    var qaPresentedItems: [ChoiceItem] { popoverController.listView?.qaItems ?? [] }
    var qaPopoverWidth: CGFloat? { popoverController.panel?.frame.width }
    var qaIsPopoverPresented: Bool { popoverController.isPresented }
    func dismissPopoverForQA() { popoverController.dismiss(); applyTokens() }
    @discardableResult
    func choosePresentedItemForQA(id: String) -> Bool {
        guard popoverController.isPresented,
              popoverController.listView?.qaItems.contains(where: { $0.id == id && $0.enabled }) == true else {
            return false
        }
        popoverController.listView?.choose(id: id)
        return true
    }
    var qaTitleFrameWidth: CGFloat { titleLabel.frame.width }
    var qaMeasuredTitleWidth: CGFloat {
        ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: NSFont.token(.label)]).width) + 4
    }
    var qaTitleDrawsWithoutTruncation: Bool {
        titleLabel.frame.width + 0.5 >= qaMeasuredTitleWidth
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
