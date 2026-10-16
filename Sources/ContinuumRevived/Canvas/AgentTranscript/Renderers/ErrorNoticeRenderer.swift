import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

@MainActor
final class ErrorNoticeRenderer: AgentBlockRendering {
    let kind: AgentBlockKind

    init(kind: AgentBlockKind) {
        precondition(kind == .error || kind == .notice)
        self.kind = kind
    }

    func makeView() -> NSView { AgentErrorNoticeView(kind: kind) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentErrorNoticeView else { return }
        switch block.payload {
        case .error(let payload) where kind == .error:
            view.applyError(blockID: block.id, payload: payload, context: context)
        case .notice(let payload) where kind == .notice:
            view.applyNotice(blockID: block.id, payload: payload, context: context)
        default:
            return
        }
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        switch block.payload {
        case .error(let payload) where kind == .error:
            let contextFullRecovery = payload.message == AgentContextFullRecovery.canonicalErrorMessage
            return AgentErrorNoticeView.measuredHeight(
                message: contextFullRecovery ? AgentErrorNoticeView.contextFullRecoveryMessage : payload.message, metadata: payload.code,
                actionCount: contextFullRecovery ? 3 : (payload.isRecoverable ? 2 : 1),
                width: width,
                contextFullRecovery: contextFullRecovery,
                zoom: context.pageZoom
            )
        case .notice(let payload) where kind == .notice:
            return AgentErrorNoticeView.measuredHeight(
                message: agentPlainText(payload.message), metadata: nil,
                actionCount: 0, width: width, zoom: context.pageZoom
            )
        default:
            return 0
        }
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        (view as? AgentErrorNoticeView)?.updateAccessibility()
    }
}

@MainActor
final class AgentErrorNoticeView: NSView {
    static let contextFullRecoveryMessage = "This session filled its context window. Compact and retry, start a new session with a summary, or copy the transcript."
    static let headerHeight = CGFloat(Space.xxl + Space.l)
    static let horizontalInset = CGFloat(Space.l)
    static let actionHeight = CGFloat(Space.xxl + Space.xs)
    static let bottomInset = CGFloat(Space.l)

    // WS5: the same four metrics at a tile's page zoom. The zero-argument
    // properties above remain the 100% values.
    static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.l)) }
    static func horizontalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    static func actionHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.xs)) }
    static func bottomInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }

    private final class BlockToken: NSObject {
        let generation: UInt64
        let blockID: AgentNodeID
        init(generation: UInt64, blockID: AgentNodeID) {
            self.generation = generation
            self.blockID = blockID
        }
    }

    let kind: AgentBlockKind
    private(set) var titleLabel = NSTextField(labelWithString: "")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var metadataLabel = NSTextField(labelWithString: "")
    private(set) var retryButton = AgentRequestChoiceButton(title: "Retry")
    private(set) var copyButton = AgentRequestChoiceButton(title: "Copy details")
    private(set) var compactRetryButton = AgentRequestChoiceButton(title: "Compact & retry")
    private(set) var forkSummaryButton = AgentRequestChoiceButton(title: "New session with summary")
    private(set) var copyTranscriptButton = AgentRequestChoiceButton(title: "Copy transcript")
    private var contextFullRecoveryVisible = false

    private var generation: UInt64 = 0
    private var blockID: AgentNodeID?
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    /// The page zoom of the last apply. Every metric below reads it, so a
    /// recycled notice re-derives rather than keeping the zoom it was built at.
    private var zoom: AgentPageZoom { context.pageZoom }

    init(kind: AgentBlockKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        messageLabel.maximumNumberOfLines = 5
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isSelectable = true
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.isSelectable = true
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        copyButton.target = self
        copyButton.action = #selector(copyDetails(_:))
        compactRetryButton.target = self
        compactRetryButton.action = #selector(contextFullRecovery(_:))
        forkSummaryButton.target = self
        forkSummaryButton.action = #selector(contextFullRecovery(_:))
        copyTranscriptButton.target = self
        copyTranscriptButton.action = #selector(contextFullRecovery(_:))
        [titleLabel, statusLabel, messageLabel, metadataLabel, retryButton, copyButton,
         compactRetryButton, forkSummaryButton, copyTranscriptButton].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyZoomMetrics()
    }

    /// Every construction-time metric, re-derived from the CURRENT context's
    /// zoom. A recycled notice runs this again from `finishApply`.
    private func applyZoomMetrics() {
        let zoom = self.zoom
        layer?.applyCorner(.artifact, zoom: zoom)
        titleLabel.font = NSFont.token(.title, zoom: zoom)
        statusLabel.font = NSFont.token(.caption, zoom: zoom)
        messageLabel.font = NSFont.token(.body, zoom: zoom)
        metadataLabel.font = NSFont.token(.captionMono, zoom: zoom)
        retryButton.applyZoom(zoom)
        copyButton.applyZoom(zoom)
        compactRetryButton.applyZoom(zoom)
        forkSummaryButton.applyZoom(zoom)
        copyTranscriptButton.applyZoom(zoom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func applyError(blockID: AgentNodeID, payload: AgentErrorPayload, context: AgentRenderContext) {
        beginApply(blockID: blockID, context: context)
        contextFullRecoveryVisible = payload.message == AgentContextFullRecovery.canonicalErrorMessage
        titleLabel.stringValue = contextFullRecoveryVisible ? "Context full" : "Error"
        statusLabel.stringValue = contextFullRecoveryVisible ? "! Recovery available" : "! Failed"
        statusLabel.isHidden = false
        messageLabel.stringValue = contextFullRecoveryVisible
            ? Self.contextFullRecoveryMessage
            : payload.message
        metadataLabel.stringValue = safeSingleLine(payload.code ?? "", fallback: "")
        metadataLabel.isHidden = metadataLabel.stringValue.isEmpty
        retryButton.isHidden = contextFullRecoveryVisible || !payload.isRecoverable
        copyButton.isHidden = contextFullRecoveryVisible
        compactRetryButton.isHidden = !contextFullRecoveryVisible
        forkSummaryButton.isHidden = !contextFullRecoveryVisible
        copyTranscriptButton.isHidden = !contextFullRecoveryVisible
        let token = BlockToken(generation: generation, blockID: blockID)
        retryButton.actionToken = token
        copyButton.actionToken = token
        compactRetryButton.actionToken = token
        forkSummaryButton.actionToken = token
        copyTranscriptButton.actionToken = token
        finishApply(blockID: blockID)
    }

    func applyNotice(blockID: AgentNodeID, payload: AgentNoticePayload, context: AgentRenderContext) {
        beginApply(blockID: blockID, context: context)
        titleLabel.stringValue = "Notice"
        if let status = payload.status {
            let presentation = status.agentToolStatusPresentation
            statusLabel.stringValue = "\(presentation.glyph) \(presentation.label)"
            statusLabel.isHidden = false
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        }
        messageLabel.stringValue = agentPlainText(payload.message)
        metadataLabel.stringValue = ""
        metadataLabel.isHidden = true
        retryButton.isHidden = true
        copyButton.isHidden = true
        compactRetryButton.isHidden = true
        forkSummaryButton.isHidden = true
        copyTranscriptButton.isHidden = true
        contextFullRecoveryVisible = false
        retryButton.actionToken = nil
        copyButton.actionToken = nil
        compactRetryButton.actionToken = nil
        forkSummaryButton.actionToken = nil
        copyTranscriptButton.actionToken = nil
        finishApply(blockID: blockID)
    }

    func updateAccessibility() {
        setAccessibilityLabel(titleLabel.stringValue)
        var children: [NSView] = [titleLabel]
        if !statusLabel.isHidden { children.append(statusLabel) }
        children.append(messageLabel)
        if !metadataLabel.isHidden { children.append(metadataLabel) }
        if !retryButton.isHidden { children.append(retryButton) }
        if !copyButton.isHidden { children.append(copyButton) }
        if !compactRetryButton.isHidden { children.append(compactRetryButton) }
        if !forkSummaryButton.isHidden { children.append(forkSummaryButton) }
        if !copyTranscriptButton.isHidden { children.append(copyTranscriptButton) }
        setAccessibilityChildren(children)
    }

    override func layout() {
        super.layout()
        let zoom = self.zoom
        let inset = Self.horizontalInset(zoom: zoom)
        let headerHeight = Self.headerHeight(zoom: zoom)
        let statusWidth = statusLabel.isHidden
            ? 0
            : min(ceil(statusLabel.intrinsicContentSize.width) + CGFloat(zoom.scaled(Space.s)), max(0, bounds.width * 0.40))
        statusLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - statusWidth),
            y: (headerHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset, y: (headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, (statusLabel.isHidden ? bounds.width - inset : statusLabel.frame.minX) - inset - CGFloat(zoom.scaled(Space.m))),
            height: titleLabel.intrinsicContentSize.height
        )
        let messageHeight = Self.textHeight(messageLabel.stringValue, width: bounds.width, role: .body, lines: 5, zoom: zoom)
        messageLabel.frame = NSRect(x: inset, y: headerHeight, width: max(1, bounds.width - inset * 2), height: messageHeight)
        var y = messageLabel.frame.maxY
        if !metadataLabel.isHidden {
            y += CGFloat(zoom.scaled(Space.s))
            metadataLabel.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: metadataLabel.intrinsicContentSize.height)
            y = metadataLabel.frame.maxY
        }
        if contextFullRecoveryVisible {
            let buttons = [compactRetryButton, forkSummaryButton, copyTranscriptButton]
            y += CGFloat(zoom.scaled(Space.m))
            let gap = CGFloat(zoom.scaled(Space.xs))
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(
                    x: inset, y: y + CGFloat(index) * (Self.actionHeight(zoom: zoom) + gap),
                    width: max(1, bounds.width - inset * 2),
                    height: Self.actionHeight(zoom: zoom))
            }
        } else {
            let buttons = [retryButton, copyButton].filter { !$0.isHidden }
            guard !buttons.isEmpty else { return }
            y += CGFloat(zoom.scaled(Space.m))
            let gap = CGFloat(zoom.scaled(Space.s))
            let width = max(1, (bounds.width - inset * 2 - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count))
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(x: inset + CGFloat(index) * (width + gap), y: y, width: width, height: Self.actionHeight(zoom: zoom))
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        // `.plans/45` T7. An error and a notice used to be one picture, differing
        // only by a title string and one status-label colour — so a compaction
        // notice read as a crash. `_DESIGN.md` §11 draws the line for us: a
        // strong semantic line is reserved for "selection, keyboard focus,
        // approval, error, or warning", and everything else recedes.
        //
        // Error keeps the artifact fill and gains that semantic outline. Notice
        // gives up both: it is ordinary history and sits on the tile body. A
        // resting surface paints nil, never .clear — a painted transparent is an
        // unregistered literal to the appearance census (hazard 8).
        if kind == .error {
            layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
            layer?.borderColor = AgentLineRole.attention.color.cgColor(for: theme)
            layer?.borderWidth = CGFloat(LineWidth.hairline)
        } else {
            layer?.backgroundColor = nil
            layer?.borderColor = nil
            layer?.borderWidth = 0
        }
        titleLabel.textColor = kind == .error
            ? context.tokens.primaryText.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        messageLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        metadataLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        statusLabel.textColor = kind == .error
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        retryButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
        copyButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
        compactRetryButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
        forkSummaryButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
        copyTranscriptButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
    }

    static func measuredHeight(
        message: String, metadata: String?, actionCount: Int, width: CGFloat,
        contextFullRecovery: Bool = false,
        zoom: AgentPageZoom = .default
    ) -> CGFloat {
        var height = headerHeight(zoom: zoom)
            + textHeight(message, width: width, role: .body, lines: 5, zoom: zoom)
        if let metadata, !metadata.isEmpty {
            height += CGFloat(zoom.scaled(Space.s) + zoom.lineHeight(for: .caption))
        }
        if actionCount > 0 {
            height += CGFloat(zoom.scaled(Space.m))
            if contextFullRecovery {
                height += CGFloat(actionCount) * actionHeight(zoom: zoom)
                    + CGFloat(max(0, actionCount - 1)) * CGFloat(zoom.scaled(Space.xs))
            } else {
                height += actionHeight(zoom: zoom)
            }
        }
        return height + bottomInset(zoom: zoom)
    }

    private func beginApply(blockID: AgentNodeID, context: AgentRenderContext) {
        generation &+= 1
        self.blockID = blockID
        self.context = context
    }

    private func finishApply(blockID: AgentNodeID) {
        identifier = NSUserInterfaceItemIdentifier("agent.\(kind.rawValue).\(blockID.rawValue)")
        updateAccessibility()
        applyZoomMetrics()
        applyTokens()
        needsLayout = true
    }

    @objc private func retry(_ sender: AgentRequestChoiceButton) {
        guard let token = validToken(sender) else { return }
        context.actions.perform(.retry(blockID: token.blockID))
    }

    @objc private func copyDetails(_ sender: AgentRequestChoiceButton) {
        guard let token = validToken(sender) else { return }
        context.actions.perform(.copy(blockID: token.blockID))
    }

    @objc private func contextFullRecovery(_ sender: AgentRequestChoiceButton) {
        guard contextFullRecoveryVisible,
              let token = validToken(sender) else { return }
        let action: AgentContextFullRecovery.Action
        if sender === compactRetryButton { action = .compactAndRetry }
        else if sender === forkSummaryButton { action = .forkWithSummary }
        else if sender === copyTranscriptButton { action = .copyTranscript }
        else { return }
        context.actions.perform(.contextFullRecovery(blockID: token.blockID, action: action))
    }

    private func validToken(_ sender: AgentRequestChoiceButton) -> BlockToken? {
        guard let token = sender.actionToken as? BlockToken,
              token.generation == generation,
              token.blockID == blockID else { return nil }
        return token
    }

    private static func textHeight(
        _ value: String, width: CGFloat, role: TextRole, lines: Int,
        zoom: AgentPageZoom = .default
    ) -> CGFloat {
        let rect = (value as NSString).boundingRect(
            with: NSSize(width: max(1, width - horizontalInset(zoom: zoom) * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(role, zoom: zoom)]
        )
        return max(CGFloat(zoom.lineHeight(for: role)), min(ceil(rect.height), CGFloat(zoom.lineHeight(for: role) * Double(lines))))
    }
}
