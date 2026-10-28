import AppKit
import ContinuumRevivedAgentUI

/// Borderless trigger for `ChoicePopoverController`. The button paints every
/// visible state; AppKit is retained only for control, focus, and accessibility.
/// Subclassable at exactly one seam — the presented surface
/// (`presentPopover` / `presentedPopoverIsVisible` / `dismissPresentedPopover`)
/// — so `ProviderModelButton` can swap the flat list for the provider>model
/// picker while trigger paint, items, selection, and QA seams stay shared.
@MainActor
class ChoiceButton: NSControl, TokenThemed, AgentPageZoomScalable {
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView(frame: .zero)
    private let leadingIcon = NSImageView(frame: .zero)
    var selectedIcon: ChoiceIcon? {
        didSet { leadingIcon.image = selectedIcon?.image(); leadingIcon.isHidden = selectedIcon == nil; invalidateIntrinsicContentSize(); needsLayout = true }
    }
    // Plan: .plans/86-workspace-filter/README.md
    /// Overlapping colour dots in the leading slot — the workspaces a sidebar set
    /// shows. Empty hides them; they take the icon's place when both are set.
    var leadingSwatches: [NSColor] = [] {
        didSet {
            guard leadingSwatches != oldValue else { return }
            swatchStack.colours = leadingSwatches
            swatchStack.isHidden = leadingSwatches.isEmpty
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    private let swatchStack = ChoiceDotStackView()
    private var iconWidth: CGFloat {
        if !leadingSwatches.isEmpty {
            return ChoiceDotStackView.width(count: leadingSwatches.count, zoom: pageZoom) + CGFloat(pageZoom.scaled(6))
        }
        return selectedIcon == nil ? 0 : CGFloat(pageZoom.scaled(22))
    }
    private let popoverController = ChoicePopoverController()
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    /// WS5: the tile's page zoom. Every metric below derives from it, so 100%
    /// reproduces the shipped numbers exactly.
    private(set) var pageZoom: AgentPageZoom = .default

    var items: [ChoiceItem] = [] {
        didSet {
            if !items.contains(where: { $0.id == selectedID && $0.enabled }) {
                selectedID = items.first(where: \.enabled)?.id
            } else {
                updatePresentation()
            }
            // An open checklist shows the new boxes and counts in place.
            if popoverPresentation == .checklist, items != oldValue {
                popoverController.update(items: items)
            }
        }
    }
    var selectedID: String? {
        didSet { updatePresentation() }
    }
    /// Optional compact trigger copy. The menu rows and accessibility value keep
    /// the selected item's exact title; only the closed button is shortened.
    var selectedTitleOverride: String? {
        didSet { updatePresentation() }
    }
    var onSelection: ((ChoiceItem) -> Void)?
    /// A checklist row's accessory (`Only`, `…`) was pressed.
    var onAccessory: ((ChoiceItem, String) -> Void)?
    /// The focused row of the open list changed; nil when the pointer leaves it.
    var onFocusChange: ((String?) -> Void)?
    /// The open list closed without a choice: Escape, a click outside, focus lost.
    var onPopoverDismiss: (() -> Void)?
    /// Restore the trigger's neutral label after a transient action/confirmation.
    /// This keeps the visible control title owned by the custom button rather than
    /// leaking a stock menu's selected-item state into the sidebar.
    func setPresentationTitle(_ title: String) {
        selectedID = nil
        fadeTitle(to: title)
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
    /// Callers offering actions opt into compact command anatomy and optional
    /// leading icons; value pickers retain checkmark rows by default.
    var popoverPresentation: ChoiceListPresentation = .choices

    static let controlHeight: CGFloat = 32
    static let horizontalPadding = CGFloat(Space.l)

    /// WS5: the same two metrics at a tile's page zoom. The `static let`s above
    /// are kept so callers outside a zoomed tile keep compiling; these are the
    /// same values scaled, and exact identities at 100%.
    static func controlHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(32)) }
    static func horizontalPadding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    /// Owner correction (P4.10): idle is a quiet fill with no outline; keyboard
    /// focus and the open state use a 0.5 pt accent line plus a soft accent glow
    /// rather than a thick permanent border.
    static let focusBorderWidth: CGFloat = 0.5
    static let focusGlowRadius: CGFloat = 3
    static let focusGlowOpacity: Float = 0.55

    init(title: String = "Choose") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.applyCorner(.card, zoom: pageZoom)
        titleLabel.stringValue = title
        titleLabel.font = .token(.label, zoom: pageZoom)
        titleLabel.lineBreakMode = .byTruncatingTail
        chevronView.image = CanvasSymbolImage.image(named: "chevron.up.chevron.down")
        chevronView.imageScaling = .scaleProportionallyDown
        leadingIcon.imageScaling = .scaleProportionallyDown
        leadingIcon.isHidden = true
        addSubview(leadingIcon)
        swatchStack.isHidden = true
        addSubview(swatchStack)
        titleLabel.wantsLayer = true
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
    private static func chevronSize(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(12)) }

    private var scaledControlHeight: CGFloat { Self.controlHeight(zoom: pageZoom) }
    private var scaledHorizontalPadding: CGFloat { Self.horizontalPadding(zoom: pageZoom) }
    private var scaledChevronSize: CGFloat { Self.chevronSize(zoom: pageZoom) }
    /// The gap between the title and the chevron.
    private var scaledTitleGap: CGFloat { CGFloat(pageZoom.scaled(Space.m)) }
    private var scaledTitleHeight: CGFloat { CGFloat(pageZoom.scaled(18)) }

    /// The raw string width plus the label cell's own horizontal padding, which
    /// `NSString.size` does not include — without it the cell truncates the title
    /// at EVERY width (`ComposerActionButton.measuredTitleWidth` precedent;
    /// P5.5 live finding, `plan-P5.5-review-corrections.md` defect 4). One
    /// expression for both `intrinsicContentSize` and `layout()`, so the two
    /// cannot disagree by a chevron metric again.
    ///
    /// The inset used to be a hard-coded `+ 4` at the rung, which `scaled`
    /// quantizes to a half point and can therefore round BELOW what the cell
    /// needs. `ChoiceLabelMetrics` measures it from a real label instead.
    private var measuredTitleWidth: CGFloat {
        ChoiceLabelMetrics.labelWidth(
            for: titleLabel.stringValue, font: .token(.label, zoom: pageZoom))
    }

    /// What a button showing `title` needs, measured the way the button measures
    /// itself — for callers (the footer's fit decision) that must reason about a
    /// title BEFORE installing it.
    static func fittingWidth(forTitle title: String, zoom: AgentPageZoom = .default) -> CGFloat {
        let titleWidth = ChoiceLabelMetrics.labelWidth(for: title, font: .token(.label, zoom: zoom))
        return horizontalPadding(zoom: zoom) * 2 + titleWidth + CGFloat(zoom.scaled(Space.m))
            + chevronSize(zoom: zoom)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: iconWidth + scaledHorizontalPadding * 2 + measuredTitleWidth + scaledTitleGap + scaledChevronSize,
            height: scaledControlHeight
        )
    }

    override func layout() {
        super.layout()
        let chevronSize = scaledChevronSize
        chevronView.frame = NSRect(
            x: bounds.width - scaledHorizontalPadding - chevronSize,
            y: floor((bounds.height - chevronSize) / 2),
            width: chevronSize,
            height: chevronSize
        )
        leadingIcon.frame = NSRect(x: scaledHorizontalPadding, y: (bounds.height - CGFloat(pageZoom.scaled(14))) / 2, width: CGFloat(pageZoom.scaled(14)), height: CGFloat(pageZoom.scaled(14)))
        let dotsHeight = ChoiceDotStackView.height(zoom: pageZoom)
        swatchStack.frame = NSRect(
            x: scaledHorizontalPadding, y: floor((bounds.height - dotsHeight) / 2),
            width: ChoiceDotStackView.width(count: leadingSwatches.count, zoom: pageZoom), height: dotsHeight)
        swatchStack.zoom = pageZoom
        leadingIcon.isHidden = selectedIcon == nil || !leadingSwatches.isEmpty
        let titleHeight = scaledTitleHeight
        // A canvas zoom snaps frames to device pixels, so a stack can hand this
        // button a fraction of a point under its intrinsic width with the row full
        // of surplus, and the label then ellipsized a title it had room for ("Cod…"
        // at zoom 3.13; ChoiceGeometryChecks 7). Up to one point of that comes out
        // of the gap before the chevron; a real shortfall still shortens the label.
        let available = max(0, chevronView.frame.minX - scaledTitleGap - scaledHorizontalPadding - iconWidth)
        let needed = measuredTitleWidth
        titleLabel.frame = NSRect(
            x: scaledHorizontalPadding + iconWidth,
            y: floor((bounds.height - titleHeight) / 2),
            width: needed > available && needed - available <= 1 ? needed : available,
            height: titleHeight
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
    func dismissPresentedPopover() {
        let wasPresented = popoverController.isPresented
        popoverController.dismiss()
        // Closed from the trigger (a second click, Escape on the button): the
        // owner hears it like any other close without a choice.
        if wasPresented { onPopoverDismiss?() }
    }

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

    /// WS5: re-derive every zoom-owned metric from scratch. Idempotent, and safe
    /// on a button already showing a selection — same contract as `applyTokens`.
    /// The presented surface is a PANEL, not a subview, so the walk cannot reach
    /// it; the trigger forwards the rung to its own controller instead.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.applyCorner(.card, zoom: pageZoom)
        titleLabel.font = .token(.label, zoom: pageZoom)
        popoverController.pageZoom = pageZoom
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens() {
        layer?.applyCorner(.card, zoom: pageZoom)
        let theme = effectiveTokenTheme
        leadingIcon.contentTintColor = BrandMark96.foreground(in: self)
        let focused = window?.firstResponder === self
        let accented = focused || presentedPopoverIsVisible
        let background: TokenColor = (isHovered || presentedPopoverIsVisible)
            ? AgentSurfaceRole.rowHover.color
            : AgentSurfaceRole.composer.color
        layer?.backgroundColor = background.cgColor(for: theme)
        swatchStack.ringColour = background.nsColor(for: theme)
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
    /// selection. The menu is as wide as its own rows: a client-pinned width
    /// narrower than them ellipsized every row of the sidebar scope menu.
    func presentPopover() {
        popoverController.pageZoom = pageZoom
        popoverController.present(
            items: items, selectedID: selectedID,
            presentation: popoverPresentation,
            anchor: bounds, relativeTo: self,
            placementFrame: presentsOffscreenForQA ? window?.frame : nil,
            takesFocus: !presentsWithoutFocusForQA && !presentsOffscreenForQA,
            onSelection: { [weak self] item in
                guard let self else { return }
                self.handleSelection(item)
                _ = self.sendAction(self.action, to: self.target)
            },
            onDismiss: { [weak self] in self?.onPopoverDismiss?() },
            onAccessory: { [weak self] item, accessory in self?.onAccessory?(item, accessory) },
            onFocusChange: { [weak self] id in self?.onFocusChange?(id) }
        )
    }

    /// Press a presented row's accessory the way a click does.
    @discardableResult
    func pressPresentedAccessoryForQA(itemID: String, accessoryID: String) -> Bool {
        guard let list = popoverController.listView else { return false }
        list.pressAccessory(itemID: itemID, accessoryID: accessoryID)
        return true
    }
    var qaPresentedList: ChoiceListView? { popoverController.listView }
    var qaPresentedPanel: NSWindow? { popoverController.panel }
    /// A check that renders the open list on the user's screen must not take
    /// their keyboard: a key panel receives what they type in another app.
    var presentsWithoutFocusForQA = false
    /// A check driving the real trigger: the popover opens inside the (offscreen)
    /// check window instead of on a screen, and without the keyboard.
    var presentsOffscreenForQA = false
    var qaPresentedSurfaceFrame: NSRect? { popoverController.surfaceFrame }

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
    var qaPopoverWidth: CGFloat? { popoverController.surfaceFrame?.width }
    var qaTruncatedPresentedRowTitles: [String]? { popoverController.listView?.qaTruncatedRowTitles }
    var qaIsPopoverPresented: Bool { popoverController.isPresented }
    func dismissPopoverForQA() { dismissPresentedPopover(); applyTokens() }
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
    var qaMeasuredTitleWidth: CGFloat { measuredTitleWidth }
    /// What the installed label's OWN cell says it needs to draw its string in
    /// full. Deliberately not `measuredTitleWidth`: that is the expression the
    /// button sized the label with, so comparing the two agreed by construction
    /// and stayed green while every trigger elided ("Hi…" for "High").
    var qaTitleDrawingWidth: CGFloat { ChoiceLabelMetrics.drawingWidth(of: titleLabel) }
    var qaTitleDrawsWithoutTruncation: Bool {
        titleLabel.frame.width + 0.5 >= qaTitleDrawingWidth
    }

    /// A label that CHANGES under an on-screen trigger crossfades rather than
    /// snapping: the sidebar's checklist rewrites it on every toggle.
    private func fadeTitle(to title: String) {
        guard titleLabel.stringValue != title, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = titleLabel.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.14
        layer.add(fade, forKey: "titleFade")
    }

    private func updatePresentation() {
        if let item = items.first(where: { $0.id == selectedID }) {
            fadeTitle(to: selectedTitleOverride ?? item.title)
            titleLabel.stringValue = selectedTitleOverride ?? item.title
            setAccessibilityValue(item.title)
        }
        setAccessibilityEnabled(isEnabled && items.contains(where: \.enabled))
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTokens()
    }
}

/// Overlapping filled circles, each knocked out of the one before by a ring in
/// the trigger's own fill — the workspaces a sidebar set shows.
@MainActor
final class ChoiceDotStackView: NSView {
    var colours: [NSColor] = [] { didSet { needsDisplay = true } }
    var ringColour: NSColor? { didSet { needsDisplay = true } }
    var zoom: AgentPageZoom = .default { didSet { needsDisplay = true } }

    static func side(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(8)) }
    static func step(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(5)) }
    static func height(zoom: AgentPageZoom) -> CGFloat { side(zoom: zoom) + 3 }
    static func width(count: Int, zoom: AgentPageZoom) -> CGFloat {
        count == 0 ? 0 : side(zoom: zoom) + CGFloat(count - 1) * step(zoom: zoom) + 3
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = Self.side(zoom: zoom), step = Self.step(zoom: zoom)
        for (index, colour) in colours.enumerated() {
            let dot = NSRect(x: 1.5 + CGFloat(index) * step, y: (bounds.height - side) / 2, width: side, height: side)
            if index > 0, let ringColour {
                ringColour.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            }
            colour.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
