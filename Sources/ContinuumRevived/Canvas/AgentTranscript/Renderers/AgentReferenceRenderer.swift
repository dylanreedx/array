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
@MainActor
final class AgentReferenceRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .agentReference

    func makeView() -> NSView { AgentReferenceChipRowView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentReferenceChipRowView,
              case let .agentReference(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        AgentReferenceChipView.height
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentReferenceChipRowView,
              case .agentReference = block.payload else { return }
        view.refreshAccessibilityLabel()
    }
}

/// The transcript row participates in normal full-width layout, but only its
/// intrinsic-width capsule is interactive. Keeping those two rectangles
/// separate prevents the old "click anywhere on this empty row" affordance.
@MainActor
final class AgentReferenceChipRowView: NSView {
    let chip = AgentReferenceChipView(frame: .zero)

    /// Put the chip's LABEL on the same reading column as a tool action title.
    /// This is derived from both renderers' real geometry: the chip itself begins
    /// far enough left to keep its outline and glyph, while its text lands at
    /// `ToolCallView.detailIndent` for every provider.
    static var leadingInset: CGFloat {
        max(0, ToolCallView.detailIndent - AgentReferenceChipView.titleOffset)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chip)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let intrinsic = chip.intrinsicContentSize
        let x = min(Self.leadingInset, max(0, bounds.width - intrinsic.width))
        chip.frame = NSRect(
            x: x,
            y: floor((bounds.height - intrinsic.height) / 2),
            width: min(max(0, bounds.width - x), intrinsic.width),
            height: intrinsic.height
        )
        chip.needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let chipPoint = chip.convert(point, from: self)
        guard chip.bounds.contains(chipPoint) else { return nil }
        return chip.hitTest(chipPoint)
    }

    func apply(blockID: AgentNodeID, payload: AgentReferencePayload, context: AgentRenderContext) {
        chip.apply(blockID: blockID, payload: payload, context: context)
        needsLayout = true
    }

    func refreshAccessibilityLabel() { chip.refreshAccessibilityLabel() }
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
        glyphView.image = CanvasSymbolImage.image(named: "person.2.fill", pointSize: 11, weight: .semibold)
            ?? CanvasSymbolImage.image(named: "person.2", pointSize: 11, weight: .semibold)
        glyphView.imageScaling = .scaleProportionallyDown
        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        glyphView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        addSubview(glyphView)
        addSubview(titleLabel)
        font = NSFont.token(.label)
        focusRingType = .exterior
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = Self.cornerRadius
        setAccessibilityRole(.button)
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
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        ).fill()
    }

    override func layout() {
        super.layout()
        let titleSize = titleLabel.intrinsicContentSize
        let contentWidth = Self.glyphSide + Self.contentGap + ceil(titleSize.width)
        let contentX = floor((bounds.width - contentWidth) / 2)
        glyphView.frame = NSRect(
            x: contentX,
            y: floor((bounds.height - Self.glyphSide) / 2),
            width: Self.glyphSide,
            height: Self.glyphSide
        )
        titleLabel.frame = NSRect(
            x: glyphView.frame.maxX + Self.contentGap,
            y: floor((bounds.height - titleSize.height) / 2),
            width: min(ceil(titleSize.width), max(0, bounds.maxX - Self.horizontalPadding - glyphView.frame.maxX - Self.contentGap)),
            height: titleSize.height
        )
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
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderColor = statusColor?.withAlphaComponent(0.42).cgColor
            ?? renderContext.tokens.decorativeLine.color.cgColor(for: theme)
        glyphView.contentTintColor = statusColor
            ?? renderContext.tokens.secondaryText.color.nsColor(for: theme)
        titleLabel.attributedStringValue = composedTitle(theme: theme)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(titleLabel.attributedStringValue.size().width)
        return NSSize(
            width: max(58, titleWidth + Self.glyphSide + Self.contentGap + Self.horizontalPadding * 2),
            height: Self.controlHeight
        )
    }

    var qaHasAgentGlyph: Bool { glyphView.image != nil }
    var qaCellContentIsEmpty: Bool {
        title.isEmpty && attributedTitle.length == 0 && image == nil
    }
    var qaContentGap: CGFloat { titleLabel.frame.minX - glyphView.frame.maxX }
    var qaContentMidX: CGFloat { (glyphView.frame.minX + titleLabel.frame.maxX) / 2 }
    var qaTitleMinX: CGFloat { titleLabel.frame.minX }

    /// `Name · Working` — the name in primary text, the live state trailing it in
    /// secondary. Status is COMPOSED here rather than stored, so it still never
    /// touches the document; and it is rendered as TEXT rather than only as a
    /// tint, because a colour alone told the reader nothing about what the child
    /// was doing.
    private func composedTitle(theme: TokenTheme) -> NSAttributedString {
        let name = Self.safeName(payload?.displayNameAtSpawn ?? "")
        let composed = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.token(.label),
                .foregroundColor: renderContext.tokens.primaryText.color.nsColor(for: theme)
            ])
        guard let label = currentInboxState?.label, !label.isEmpty else { return composed }
        composed.append(NSAttributedString(
            string: "  ·  \(label)",
            attributes: [
                .font: NSFont.token(.label),
                .foregroundColor: renderContext.tokens.secondaryText.color.nsColor(for: theme)
            ]))
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
