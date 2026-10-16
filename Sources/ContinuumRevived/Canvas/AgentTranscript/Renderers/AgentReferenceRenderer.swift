import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// C10: `AgentReferencePayload` deliberately carries no status — a status tick
/// must never rewrite the semantic document. This is the render-time seam a
/// chip uses instead, entirely outside the document: `current` resolves the
/// agent's status right now, and `subscribe`/`unsubscribe` let exactly the
/// chips currently on screen hear about a change. At 16 fanned-out children an
/// unconditional subscription per chip would be a leak the transcript's own
/// virtualization (6 live hosts for 10,000 rows) exists to avoid, so a chip
/// subscribes only while it is actually representing an agent and tears the
/// subscription down the moment it stops (reused for a different block, or
/// deallocated).
struct AgentReferenceStatusSource: @unchecked Sendable {
    let current: (UUID) -> InboxState?
    let subscribe: (UUID, @escaping (InboxState?) -> Void) -> UUID?
    let unsubscribe: (UUID) -> Void

    static let unavailable = AgentReferenceStatusSource(
        current: { _ in nil },
        subscribe: { _, _ in nil },
        unsubscribe: { _ in }
    )
}

/// A transcript milestone for one real child agent. The block owns only stable
/// identity; the host resolves current status and tile placement when activated.
///
/// T4 (0.7.26): a run of CONSECUTIVE chips is one transcript row. The list's
/// display projection folds the followers out of the display and hands their
/// blocks to the run's first chip as presented `children` (the document never
/// changes), and this renderer flows every chip of the run left to right,
/// wrapping when the tile is narrow. One delegation of five children used to
/// be five stacked full-width rows.
@MainActor
final class AgentReferenceRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .agentReference

    func makeView() -> NSView { AgentReferenceChipRowView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentReferenceChipRowView else { return }
        let references = Self.references(in: block)
        guard !references.isEmpty else { return }
        view.apply(leaderID: block.id, references: references, context: context)
    }

    /// The wrapped height, from the same composition and the same flow the row
    /// lays out with — status included, because a status word widens a chip.
    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        let zoom = context.pageZoom
        let widths = Self.references(in: block).map { reference in
            AgentReferenceChipView.preferredWidth(
                name: reference.payload.displayNameAtSpawn,
                label: context.agentStatus.current(reference.payload.agentID)?.label,
                zoom: zoom
            )
        }
        return AgentReferenceChipRowView.flow(widths: widths, width: width, zoom: zoom).height
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentReferenceChipRowView,
              case .agentReference = block.payload else { return }
        view.refreshAccessibilityLabel()
    }

    /// The run this row presents: the block itself, then the presented
    /// followers, in transcript order.
    static func references(in block: AgentBlock) -> [AgentReferenceChipRowView.Reference] {
        ([block] + block.children).compactMap { member in
            guard case let .agentReference(payload) = member.payload else { return nil }
            return AgentReferenceChipRowView.Reference(blockID: member.id, payload: payload)
        }
    }
}

/// The transcript row participates in normal full-width layout, but only its
/// intrinsic-width capsules are interactive. Keeping those rectangles separate
/// prevents the old "click anywhere on this empty row" affordance.
@MainActor
final class AgentReferenceChipRowView: NSView {
    struct Reference {
        let blockID: AgentNodeID
        let payload: AgentReferencePayload
    }

    /// One capsule per chip in the run. Bounded by the run, not the document:
    /// the transcript still virtualizes rows, and a run is one delegation's
    /// children.
    private(set) var chips: [AgentReferenceChipView] = []

    /// Put the first chip's LABEL on the same reading column as a tool action
    /// title. This is derived from both renderers' real geometry: the chip itself
    /// begins far enough left to keep its outline and glyph, while its text lands
    /// at `ToolCallView.detailIndent` for every provider.
    static var leadingInset: CGFloat {
        max(0, ToolCallView.detailIndent - AgentReferenceChipView.titleOffset)
    }

    /// WS5: the same derivation at a tile's page zoom. Both halves move with the
    /// zoom, so the chip's label stays on the tool title's reading column.
    static func leadingInset(zoom: AgentPageZoom) -> CGFloat {
        max(0, ToolCallView.detailIndent(zoom: zoom) - AgentReferenceChipView.titleOffset(zoom: zoom))
    }

    /// Space between two chips on one line. Lines sit one transcript row-rhythm
    /// apart (`AgentReferenceChipView.height`), so one line of chips is exactly
    /// the height a single chip always had.
    static func chipGap(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }

    /// Flex-wrap, as one pure function shared by `measure` and `layout()`: chips
    /// flow left to right from the leading inset with a constant gap and wrap to
    /// a new line when the next one would cross the trailing edge. A chip wider
    /// than the row keeps a line to itself and is clipped to the row, as a
    /// lone chip always was.
    static func flow(widths: [CGFloat], width: CGFloat, zoom: AgentPageZoom) -> (frames: [NSRect], height: CGFloat) {
        let lineHeight = AgentReferenceChipView.height(zoom: zoom)
        let controlHeight = AgentReferenceChipView.controlHeight(zoom: zoom)
        let inset = leadingInset(zoom: zoom)
        let gap = chipGap(zoom: zoom)
        var frames: [NSRect] = []
        frames.reserveCapacity(widths.count)
        var line = 0
        var nextX: CGFloat?
        for chipWidth in widths {
            if let x = nextX, x + chipWidth > width {
                line += 1
                nextX = nil
            }
            let x = nextX ?? min(inset, max(0, width - chipWidth))
            let frame = NSRect(
                x: x,
                y: CGFloat(line) * lineHeight + floor((lineHeight - controlHeight) / 2),
                width: min(max(0, width - x), chipWidth),
                height: controlHeight
            )
            frames.append(frame)
            nextX = frame.maxX + gap
        }
        return (frames, CGFloat(line + 1) * lineHeight)
    }

    /// The page zoom of the last `apply`; `layout()` reads it, so a recycled row
    /// re-derives rather than keeping the zoom it was built at.
    private var pageZoom: AgentPageZoom = .default
    private var leaderID: AgentNodeID?
    private var actions: AgentRenderActions = .disabled
    private var remeasureRequested = false
    private var requestedHeight: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Lines run top-down.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Arithmetic only: each chip's width was measured when its title was
        // composed, never here.
        let flow = Self.flow(
            widths: chips.map(\.intrinsicContentSize.width), width: bounds.width, zoom: pageZoom)
        for (chip, frame) in zip(chips, flow.frames) where chip.frame != frame {
            chip.frame = frame
            chip.needsLayout = true
        }
        // A live status tick can widen or narrow a chip after this row was
        // measured — on screen, or while the row was scrolled away and its
        // height sat in the measurement cache. When the wrap no longer fits the
        // measured height, ask the host to re-measure this row. Deferred: the
        // re-measure re-enters transcript layout, which must not happen from
        // inside a layout pass.
        if bounds.width > 0, bounds.height > 0, abs(flow.height - bounds.height) > 0.5 {
            requestRemeasure(for: flow.height)
        }
    }

    /// One request per height the wrap asks for: if a re-measure still lands on
    /// a different height, asking again would only repeat it, every pass.
    private func requestRemeasure(for height: CGFloat) {
        guard !remeasureRequested, height != requestedHeight, let leaderID else { return }
        remeasureRequested = true
        requestedHeight = height
        let actions = self.actions
        DispatchQueue.main.async { [weak self] in
            self?.remeasureRequested = false
            // The host's gated actions: a row recycled for another block since
            // this was queued cannot invalidate the wrong one.
            actions.invalidatePresentation(blockID: leaderID)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for chip in chips {
            let chipPoint = chip.convert(point, from: self)
            if chip.bounds.contains(chipPoint) { return chip.hitTest(chipPoint) }
        }
        return nil
    }

    func apply(leaderID: AgentNodeID, references: [Reference], context: AgentRenderContext) {
        pageZoom = context.pageZoom
        self.leaderID = leaderID
        actions = context.actions
        requestedHeight = nil
        // Reuse capsules by position; each one re-subscribes when the agent it
        // represents changes, exactly as a recycled single chip did.
        while chips.count > references.count {
            chips.removeLast().removeFromSuperview()
        }
        while chips.count < references.count {
            let chip = AgentReferenceChipView(frame: .zero)
            addSubview(chip)
            chips.append(chip)
        }
        for (chip, reference) in zip(chips, references) {
            chip.apply(blockID: reference.blockID, payload: reference.payload, context: context)
        }
        needsLayout = true
    }

    func refreshAccessibilityLabel() { chips.forEach { $0.refreshAccessibilityLabel() } }
}

@MainActor
final class AgentReferenceChipView: NSButton {
    /// The transcript's action-first row height, shared with every tool row.
    /// A subagent milestone is one line about work that happened elsewhere, so
    /// it sits in the same rhythm rather than in a taller card of its own.
    static let height = CGFloat(30)
    private static let controlHeight = CGFloat(26)
    private static let cornerRadius = CGFloat(8)
    private static let horizontalPadding = CGFloat(Space.l)
    private static let glyphSide = CGFloat(14)
    private static let contentGap = CGFloat(Space.s)
    static var titleOffset: CGFloat { horizontalPadding + glyphSide + contentGap }

    // WS5: the same chip metrics at a tile's page zoom. The zero-argument
    // properties above remain the 100% values.
    static func height(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(30)) }
    static func controlHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(26)) }
    private static func cornerRadius(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(8)) }
    private static func horizontalPadding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    private static func glyphSide(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(14)) }
    private static func contentGap(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.s)) }
    /// The glyph's own point size, which follows the chip rather than the type.
    private static func glyphPointSize(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(11)) }
    /// The chip's minimum width — a short name still reads as a capsule.
    private static func minimumWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(58)) }
    static func titleOffset(zoom: AgentPageZoom) -> CGFloat {
        horizontalPadding(zoom: zoom) + glyphSide(zoom: zoom) + contentGap(zoom: zoom)
    }

    /// The page zoom of the last `apply`. Every metric below reads it, so a
    /// recycled chip re-derives rather than keeping the zoom it was built at.
    private var zoom: AgentPageZoom { renderContext.pageZoom }
    private let glyphView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private var blockID: AgentNodeID?
    private var payload: AgentReferencePayload?
    private var renderContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var statusSource: AgentReferenceStatusSource = .unavailable
    private var statusSubscriptionToken: UUID?
    /// Never read from `AgentReferencePayload` — resolved and refreshed purely
    /// through `statusSource`, so a status tick can never touch the document.
    private var currentInboxState: InboxState?
    /// Hover/pressed affordance state. The chip is the one row in the transcript
    /// whose click opens another tile, and it shipped with no affordance at all —
    /// nothing said it was clickable, so a live delegation read as a dead label.
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // This NSButton is interaction infrastructure only. All visible content
        // belongs to the explicit subviews below; leaving even an empty-looking
        // cell title around lets AppKit paint a second text layer on short labels.
        title = ""
        attributedTitle = NSAttributedString(string: "")
        image = nil
        imagePosition = .noImage
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activate(_:))
        // Own the glyph and label as explicit subviews. `NSButtonCell` lays a
        // leading image and centred title in separate allocation regions, which
        // produced the enormous provider-dependent-looking gap in the first
        // feel builds even though every provider used this same renderer.
        glyphView.imageScaling = .scaleProportionallyDown
        titleLabel.lineBreakMode = .byTruncatingTail
        glyphView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        addSubview(glyphView)
        addSubview(titleLabel)
        focusRingType = .exterior
        wantsLayer = true
        setAccessibilityRole(.button)
        applyZoomMetrics()
    }

    /// Every construction-time metric, re-derived from the CURRENT context's
    /// zoom. A recycled chip runs this again from `apply`.
    private func applyZoomMetrics() {
        let zoom = self.zoom
        let glyphPointSize = Self.glyphPointSize(zoom: zoom)
        glyphView.image = CanvasSymbolImage.image(named: "person.2.fill", pointSize: glyphPointSize, weight: .semibold)
            ?? CanvasSymbolImage.image(named: "person.2", pointSize: glyphPointSize, weight: .semibold)
        titleLabel.font = NSFont.token(.label, zoom: zoom)
        font = NSFont.token(.label, zoom: zoom)
        // A hairline is a device property, not a metric: it does not scale
        // with the page zoom (same rule as `ChoiceListView.panelBorderWidth`).
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        layer?.cornerRadius = Self.cornerRadius(zoom: zoom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    /// Suppress `NSButtonCell` painting completely. The layer owns the capsule
    /// and the two subviews own its glyph and title; the cell owns only action,
    /// keyboard activation, and accessibility.
    override func draw(_ dirtyRect: NSRect) {}

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let cornerRadius = Self.cornerRadius(zoom: zoom)
        NSBezierPath(
            roundedRect: bounds,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
    }

    override func layout() {
        super.layout()
        let zoom = self.zoom
        let glyphSide = Self.glyphSide(zoom: zoom)
        let contentGap = Self.contentGap(zoom: zoom)
        // The title's size is measured once, when its text changes
        // (`applyTokens`), and the capsule's intrinsic width is derived from the
        // SAME figure — so the label is always granted exactly what the title
        // needs, and layout never measures text.
        let contentWidth = glyphSide + contentGap + titleSize.width
        let contentX = floor((bounds.width - contentWidth) / 2)
        let glyphFrame = NSRect(
            x: contentX,
            y: floor((bounds.height - glyphSide) / 2),
            width: glyphSide,
            height: glyphSide
        )
        if glyphView.frame != glyphFrame { glyphView.frame = glyphFrame }
        let titleFrame = NSRect(
            x: glyphFrame.maxX + contentGap,
            y: floor((bounds.height - titleSize.height) / 2),
            width: min(titleSize.width, max(0, bounds.maxX - Self.horizontalPadding(zoom: zoom) - glyphFrame.maxX - contentGap)),
            height: titleSize.height
        )
        if titleLabel.frame != titleFrame { titleLabel.frame = titleFrame }
    }

    deinit {
        if let statusSubscriptionToken {
            statusSource.unsubscribe(statusSubscriptionToken)
        }
    }

    func apply(blockID: AgentNodeID, payload: AgentReferencePayload, context: AgentRenderContext) {
        let agentChanged = self.payload?.agentID != payload.agentID
        self.blockID = blockID
        self.payload = payload
        renderContext = context
        toolTip = "Open subagent \(Self.safeName(payload.displayNameAtSpawn))"
        identifier = NSUserInterfaceItemIdentifier("agent.reference.\(payload.agentID.uuidString)")
        // A reused host (virtualization) or a rebuilt context both mean the
        // OLD subscription may be watching the wrong agent or calling back
        // through a stale closure; re-subscribing on either is what keeps
        // "6 live hosts for 10,000 rows" from also being 10,000 live
        // subscriptions.
        if agentChanged || statusSubscriptionToken == nil {
            subscribeStatus(agentID: payload.agentID, source: context.agentStatus)
        } else {
            statusSource = context.agentStatus
        }
        currentInboxState = statusSource.current(payload.agentID)
        applyZoomMetrics()
        applyTokens()
        refreshAccessibilityLabel()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    // Same tracking idiom as the approval choice buttons. `.cursorUpdate` adds
    // the pointing hand, the enter/exit pair drives the hover tint.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyTokens()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        applyTokens()
    }

    /// NSButton's own press highlight, redirected onto the same token fill so
    /// the pressed state reads on the whole row, not only the label.
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        pressed = flag
        applyTokens()
    }

    private func subscribeStatus(agentID: UUID, source: AgentReferenceStatusSource) {
        if let statusSubscriptionToken {
            statusSource.unsubscribe(statusSubscriptionToken)
        }
        statusSource = source
        statusSubscriptionToken = source.subscribe(agentID) { [weak self] state in
            guard let self, self.payload?.agentID == agentID else { return }
            self.currentInboxState = state
            self.applyTokens()
            self.refreshAccessibilityLabel()
        }
    }

    private func applyTokens() {
        let theme = effectiveTokenTheme
        let statusColor = currentInboxState?.accent?.color.nsColor(for: theme)
        // Colour belongs to the live state rather than the child name. Keep it
        // restrained: a faint wash and boundary make active/blocked/failed
        // children distinguishable without turning the transcript into tags.
        if pressed {
            layer?.backgroundColor = AgentSurfaceRole.rowSelected.color.cgColor(for: theme)
        } else if hovered {
            layer?.backgroundColor = AgentSurfaceRole.rowHover.color.cgColor(for: theme)
        } else if let statusColor {
            layer?.backgroundColor = statusColor.withAlphaComponent(0.09).cgColor
        } else {
            layer?.backgroundColor = nil
        }
        layer?.cornerRadius = Self.cornerRadius(zoom: zoom)
        layer?.borderColor = statusColor?.withAlphaComponent(0.42).cgColor
            ?? renderContext.tokens.decorativeLine.color.cgColor(for: theme)
        glyphView.contentTintColor = statusColor
            ?? renderContext.tokens.secondaryText.color.nsColor(for: theme)
        let title = Self.composedTitle(
            name: payload?.displayNameAtSpawn ?? "",
            label: currentInboxState?.label,
            zoom: zoom,
            primary: renderContext.tokens.primaryText.color.nsColor(for: theme),
            secondary: renderContext.tokens.secondaryText.color.nsColor(for: theme)
        )
        titleLabel.attributedStringValue = title
        titleSize = Self.titleSize(of: title)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    /// The composed title's size, measured where the title is composed. Kept so
    /// `layout()` and `intrinsicContentSize` read a number instead of measuring.
    private var titleSize = NSSize.zero

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(titleWidth: titleSize.width, zoom: zoom), height: Self.controlHeight(zoom: zoom))
    }

    /// Measured by a label cell, not `NSAttributedString.size()`: the cell
    /// draws its text inside a 2pt inset on each side, so a label exactly as
    /// wide as the string truncates its last characters.
    private static func titleSize(of title: NSAttributedString) -> NSSize {
        measuringCell.attributedStringValue = title
        let size = measuringCell.cellSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static let measuringCell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.isBordered = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }()

    private static func width(titleWidth: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        max(
            minimumWidth(zoom: zoom),
            titleWidth + glyphSide(zoom: zoom) + contentGap(zoom: zoom) + horizontalPadding(zoom: zoom) * 2
        )
    }

    /// The capsule width a chip naming `name` in `label`'s state will take — the
    /// renderer's measurement, computed from the same composition the view
    /// paints, so a measured row and a laid-out row can never disagree.
    static func preferredWidth(name: String, label: String?, zoom: AgentPageZoom) -> CGFloat {
        let title = composedTitle(name: name, label: label, zoom: zoom, primary: .labelColor, secondary: .secondaryLabelColor)
        return width(titleWidth: titleSize(of: title).width, zoom: zoom)
    }

    var qaHasAgentGlyph: Bool { glyphView.image != nil }
    var qaCellContentIsEmpty: Bool {
        title.isEmpty && attributedTitle.length == 0 && image == nil
    }
    var qaContentGap: CGFloat { titleLabel.frame.minX - glyphView.frame.maxX }
    var qaContentMidX: CGFloat { (glyphView.frame.minX + titleLabel.frame.maxX) / 2 }
    var qaTitleMinX: CGFloat { titleLabel.frame.minX }
    var qaTitleLabel: NSTextField { titleLabel }
    var qaTitleText: String { titleLabel.attributedStringValue.string }

    /// `Name · Working` — the name in primary text, the live state trailing it in
    /// secondary. Status is COMPOSED here rather than stored, so it still never
    /// touches the document; and it is rendered as TEXT rather than only as a
    /// tint, because a colour alone told the reader nothing about what the child
    /// was doing.
    ///
    /// The paragraph style is load-bearing. An attributed title without one
    /// carries the DEFAULT style, word wrapping, which overrides the label's own
    /// `.byTruncatingTail`; at the exact width the capsule grants, the last word
    /// then broke onto a second line the 15pt label cannot show, and every chip
    /// read "Name ·" with blank capsule after the dot.
    private static func composedTitle(
        name: String,
        label: String?,
        zoom: AgentPageZoom,
        primary: NSColor,
        secondary: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.token(.label, zoom: zoom)
        let composed = NSMutableAttributedString(
            string: safeName(name),
            attributes: [.font: font, .foregroundColor: primary, .paragraphStyle: paragraph])
        // No label, no separator: a dangling "·" reads as a state that failed to load.
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return composed
        }
        composed.append(NSAttributedString(
            string: "  ·  \(label)",
            attributes: [.font: font, .foregroundColor: secondary, .paragraphStyle: paragraph]))
        return composed
    }

    func refreshAccessibilityLabel() {
        guard let payload else { return }
        let name = Self.safeName(payload.displayNameAtSpawn)
        if let label = currentInboxState?.label {
            setAccessibilityLabel("Subagent, \(name), \(label), open agent")
        } else {
            setAccessibilityLabel("Subagent, \(name), open agent")
        }
    }

    @objc private func activate(_ sender: Any?) {
        guard let blockID, let payload else { return }
        renderContext.actions.perform(.revealAgent(
            blockID: blockID,
            agentID: payload.agentID,
            parentAgentID: payload.parentAgentID
        ))
    }

    private static func safeName(_ value: String) -> String {
        let line = value.split(whereSeparator: { $0.isNewline }).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? "Subagent" : String(line.prefix(80))
    }
}
