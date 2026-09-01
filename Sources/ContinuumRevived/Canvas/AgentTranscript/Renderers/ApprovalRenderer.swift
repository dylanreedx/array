import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

@MainActor
final class ApprovalRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .approval

    func makeView() -> NSView { AgentRequestView(mode: .approval) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentRequestView, case let .approval(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .approval(payload) = block.payload else { return 0 }
        return AgentRequestView.measuredHeight(payload: payload, width: width, zoom: context.pageZoom)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentRequestView, case let .approval(payload) = block.payload else { return }
        view.applyAccessibility(payload: payload)
    }
}

/// A6 (`.plans/45`) — the approval/question dock always fills itself with
/// `AgentSurfaceRole.artifact` in `applyTokens()` (no resting-nil branch: an
/// open request is always an artifact surface), so it is a real conformer,
/// not a decoration exemption. Swept on `appearance.managedAgentTile` via
/// the fixture's default `includeApproval: true`.
@MainActor
final class AgentRequestView: NSView, TokenThemed {
    enum Mode { case approval, question }

    static let headerHeight = CGFloat(Space.xxl + Space.l)
    static let horizontalInset = CGFloat(Space.l)
    static let actionHeight = CGFloat(Space.xxl + Space.xs)
    static let bottomInset = CGFloat(Space.l)
    static let maximumChoices = 4

    // WS5: the same four metrics at a tile's page zoom. The zero-argument
    // properties above remain the 100% values.
    static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.l)) }
    static func horizontalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    static func actionHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.xs)) }
    static func bottomInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }

    private final class ChoiceToken: NSObject {
        let generation: UInt64
        let requestID: String
        let value: String
        init(generation: UInt64, requestID: String, value: String) {
            self.generation = generation
            self.requestID = requestID
            self.value = value
        }
    }

    let mode: Mode
    private(set) var titleLabel = NSTextField(labelWithString: "")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var promptLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var choiceButtons: [AgentRequestChoiceButton] = []
    private(set) var requestID: String?

    private var generation: UInt64 = 0
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var status: AgentItemStatus = .pending

    /// The page zoom of the last `apply`. Every metric below reads it, so a
    /// recycled dock re-derives rather than keeping the zoom it was built at.
    private var zoom: AgentPageZoom { context.pageZoom }

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        statusLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 4
        promptLabel.lineBreakMode = .byWordWrapping
        promptLabel.isSelectable = true
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(promptLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyZoomMetrics()
    }

    /// Every construction-time metric, re-derived from the CURRENT context's
    /// zoom. A recycled dock runs this again from `apply`.
    private func applyZoomMetrics() {
        let zoom = self.zoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        titleLabel.font = NSFont.token(.title, zoom: zoom)
        statusLabel.font = NSFont.token(.caption, zoom: zoom)
        promptLabel.font = NSFont.token(.body, zoom: zoom)
        choiceButtons.forEach { $0.applyZoom(zoom) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentRequestPayload, context: AgentRenderContext) {
        generation &+= 1
        self.context = context
        status = payload.status
        requestID = payload.requestID
        titleLabel.stringValue = mode == .approval ? "Approval requested" : "Question"
        let presentation = payload.status.agentToolStatusPresentation
        statusLabel.stringValue = "\(presentation.glyph) \(presentation.label)"
        promptLabel.stringValue = agentPlainText(payload.prompt)
        rebuildChoices(payload: payload)
        identifier = NSUserInterfaceItemIdentifier(
            "agent.\(mode == .approval ? "approval" : "question").\(blockID.rawValue)"
        )
        applyAccessibility(payload: payload)
        applyZoomMetrics()
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(payload: AgentRequestPayload) {
        let kind = mode == .approval ? "Approval requested" : "Question"
        setAccessibilityLabel("\(kind), \(payload.status.agentToolStatusPresentation.label)")
        setAccessibilityChildren([titleLabel, statusLabel, promptLabel] + choiceButtons)
    }

    override func layout() {
        super.layout()
        let zoom = self.zoom
        let inset = Self.horizontalInset(zoom: zoom)
        let headerHeight = Self.headerHeight(zoom: zoom)
        let statusWidth = min(ceil(statusLabel.intrinsicContentSize.width) + CGFloat(zoom.scaled(Space.s)), max(0, bounds.width * 0.40))
        statusLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - statusWidth),
            y: (headerHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset, y: (headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - inset - CGFloat(zoom.scaled(Space.m))),
            height: titleLabel.intrinsicContentSize.height
        )
        let promptHeight = Self.promptHeight(promptLabel.stringValue, width: bounds.width, zoom: zoom)
        promptLabel.frame = NSRect(
            x: inset, y: headerHeight,
            width: max(1, bounds.width - inset * 2), height: promptHeight
        )
        guard !choiceButtons.isEmpty else { return }
        let y = promptLabel.frame.maxY + CGFloat(zoom.scaled(Space.m))
        let gap = CGFloat(zoom.scaled(Space.s))
        let width = max(1, (bounds.width - inset * 2 - gap * CGFloat(choiceButtons.count - 1)) / CGFloat(choiceButtons.count))
        for (index, button) in choiceButtons.enumerated() {
            button.frame = NSRect(x: inset + CGFloat(index) * (width + gap), y: y, width: width, height: Self.actionHeight(zoom: zoom))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        promptLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = status == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        choiceButtons.forEach { $0.applyTokens(theme: theme) }
    }

    static func measuredHeight(
        payload: AgentRequestPayload, width: CGFloat, zoom: AgentPageZoom = .default
    ) -> CGFloat {
        let actionable = payload.requestID != nil
            && [.pending, .inProgress].contains(payload.status)
            && !payload.choices.isEmpty
        return headerHeight(zoom: zoom)
            + promptHeight(agentPlainText(payload.prompt), width: width, zoom: zoom)
            + (actionable ? CGFloat(zoom.scaled(Space.m)) + actionHeight(zoom: zoom) : 0)
            + bottomInset(zoom: zoom)
    }

    private func rebuildChoices(payload: AgentRequestPayload) {
        choiceButtons.forEach { $0.removeFromSuperview() }
        choiceButtons = []
        guard let requestID = payload.requestID,
              [.pending, .inProgress].contains(payload.status) else { return }
        for choice in payload.choices.prefix(Self.maximumChoices) {
            let button = AgentRequestChoiceButton(title: safeSingleLine(choice, fallback: "Respond"))
            button.target = self
            button.action = #selector(submitChoice(_:))
            button.actionToken = ChoiceToken(
                generation: generation, requestID: requestID, value: choice
            )
            addSubview(button)
            choiceButtons.append(button)
        }
    }

    @objc private func submitChoice(_ sender: AgentRequestChoiceButton) {
        guard let token = sender.actionToken as? ChoiceToken,
              token.generation == generation,
              token.requestID == requestID else { return }
        context.actions.perform(.submitResponse(requestID: token.requestID, value: token.value))
    }

    private static func promptHeight(
        _ value: String, width: CGFloat, zoom: AgentPageZoom = .default
    ) -> CGFloat {
        let rect = (value as NSString).boundingRect(
            with: NSSize(width: max(1, width - horizontalInset(zoom: zoom) * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.body, zoom: zoom)]
        )
        return max(CGFloat(zoom.lineHeight(for: .body)), min(ceil(rect.height), CGFloat(zoom.lineHeight(for: .body) * 4)))
    }
}

@MainActor
final class AgentRequestChoiceButton: NSButton {
    var actionToken: AnyObject?
    private var hovered = false
    private var theme: TokenTheme = .dark
    private var tracking: NSTrackingArea?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.label)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)
        // WS5: identity at 100%; the owner re-derives both on every apply.
        // Keep the AppKit exterior keyboard focus ring outside the rounded fill.
        layer?.masksToBounds = false
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        identifier = NSUserInterfaceItemIdentifier("agent.request.choice")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyFill()
    }

    /// WS5: the font and capsule radius, re-derived from the owner's current
    /// page zoom. A choice button is rebuilt per apply, but the error/notice
    /// dock reuses two of them for the life of the view.
    func applyZoom(_ zoom: AgentPageZoom) {
        font = NSFont.token(.label, zoom: zoom)
        layer?.cornerRadius = CGFloat(zoom.scaled(Radius.card))
        invalidateIntrinsicContentSize()
    }

    func applyTokens(theme: TokenTheme) {
        self.theme = theme
        contentTintColor = TextToken.textPrimary.color.nsColor(for: theme)
        applyFill()
    }

    private func applyFill() {
        // Choice order is provider data, not recommendation semantics: every idle
        // choice receives equal emphasis and hover alone uses the selected fill.
        let surface = hovered ? AgentSurfaceRole.rowSelected.color : SurfaceToken.overlay.color
        layer?.backgroundColor = surface.cgColor(for: theme)
    }
}

func agentPlainText(_ inlines: [AgentInline]) -> String {
    inlines.map { inline in
        switch inline {
        case .text(let value), .code(let value): return value
        case .emphasis(let children), .strong(let children): return agentPlainText(children)
        case .link(_, _, let children): return agentPlainText(children)
        case .softBreak: return " "
        case .hardBreak: return "\n"
        }
    }.joined()
}

func safeSingleLine(_ value: String, fallback: String) -> String {
    let line = value.split(whereSeparator: { $0.isNewline }).first.map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return line.isEmpty ? fallback : line
}
