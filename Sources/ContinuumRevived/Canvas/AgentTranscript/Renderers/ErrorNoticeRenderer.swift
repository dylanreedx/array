import AppKit
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
            return AgentErrorNoticeView.measuredHeight(
                message: payload.message, metadata: payload.code,
                actionCount: payload.isRecoverable ? 2 : 1, width: width
            )
        case .notice(let payload) where kind == .notice:
            return AgentErrorNoticeView.measuredHeight(
                message: agentPlainText(payload.message), metadata: nil,
                actionCount: 0, width: width
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
    static let headerHeight = CGFloat(Space.xxl + Space.l)
    static let horizontalInset = CGFloat(Space.l)
    static let actionHeight = CGFloat(Space.xxl + Space.xs)
    static let bottomInset = CGFloat(Space.l)

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

    private var generation: UInt64 = 0
    private var blockID: AgentNodeID?
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    init(kind: AgentBlockKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        titleLabel.font = NSFont.token(.title)
        statusLabel.font = NSFont.token(.caption)
        messageLabel.font = NSFont.token(.body)
        messageLabel.maximumNumberOfLines = 5
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.isSelectable = true
        metadataLabel.font = NSFont.token(.captionMono)
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.isSelectable = true
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        copyButton.target = self
        copyButton.action = #selector(copyDetails(_:))
        [titleLabel, statusLabel, messageLabel, metadataLabel, retryButton, copyButton].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func applyError(blockID: AgentNodeID, payload: AgentErrorPayload, context: AgentRenderContext) {
        beginApply(blockID: blockID, context: context)
        titleLabel.stringValue = "Error"
        statusLabel.stringValue = "! Failed"
        statusLabel.isHidden = false
        messageLabel.stringValue = payload.message
        metadataLabel.stringValue = safeSingleLine(payload.code ?? "", fallback: "")
        metadataLabel.isHidden = metadataLabel.stringValue.isEmpty
        retryButton.isHidden = !payload.isRecoverable
        copyButton.isHidden = false
        let token = BlockToken(generation: generation, blockID: blockID)
        retryButton.actionToken = token
        copyButton.actionToken = token
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
        retryButton.actionToken = nil
        copyButton.actionToken = nil
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
        setAccessibilityChildren(children)
    }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let statusWidth = statusLabel.isHidden ? 0 : min(statusLabel.intrinsicContentSize.width, max(0, bounds.width * 0.34))
        statusLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - statusWidth),
            y: (Self.headerHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset, y: (Self.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, (statusLabel.isHidden ? bounds.width - inset : statusLabel.frame.minX) - inset - CGFloat(Space.m)),
            height: titleLabel.intrinsicContentSize.height
        )
        let messageHeight = Self.textHeight(messageLabel.stringValue, width: bounds.width, role: .body, lines: 5)
        messageLabel.frame = NSRect(x: inset, y: Self.headerHeight, width: max(1, bounds.width - inset * 2), height: messageHeight)
        var y = messageLabel.frame.maxY
        if !metadataLabel.isHidden {
            y += CGFloat(Space.s)
            metadataLabel.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: metadataLabel.intrinsicContentSize.height)
            y = metadataLabel.frame.maxY
        }
        let buttons = [retryButton, copyButton].filter { !$0.isHidden }
        guard !buttons.isEmpty else { return }
        y += CGFloat(Space.m)
        let gap = CGFloat(Space.s)
        let width = max(1, (bounds.width - inset * 2 - gap * CGFloat(buttons.count - 1)) / CGFloat(buttons.count))
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: inset + CGFloat(index) * (width + gap), y: y, width: width, height: Self.actionHeight)
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
        messageLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        metadataLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        statusLabel.textColor = kind == .error
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        retryButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
        copyButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
    }

    static func measuredHeight(
        message: String, metadata: String?, actionCount: Int, width: CGFloat
    ) -> CGFloat {
        var height = headerHeight + textHeight(message, width: width, role: .body, lines: 5)
        if let metadata, !metadata.isEmpty {
            height += CGFloat(Space.s + Metrics.lineHeight(for: .caption))
        }
        if actionCount > 0 { height += CGFloat(Space.m) + actionHeight }
        return height + bottomInset
    }

    private func beginApply(blockID: AgentNodeID, context: AgentRenderContext) {
        generation &+= 1
        self.blockID = blockID
        self.context = context
    }

    private func finishApply(blockID: AgentNodeID) {
        identifier = NSUserInterfaceItemIdentifier("agent.\(kind.rawValue).\(blockID.rawValue)")
        updateAccessibility()
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

    private func validToken(_ sender: AgentRequestChoiceButton) -> BlockToken? {
        guard let token = sender.actionToken as? BlockToken,
              token.generation == generation,
              token.blockID == blockID else { return nil }
        return token
    }

    private static func textHeight(
        _ value: String, width: CGFloat, role: TextRole, lines: Int
    ) -> CGFloat {
        let rect = (value as NSString).boundingRect(
            with: NSSize(width: max(1, width - horizontalInset * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(role)]
        )
        return max(CGFloat(Metrics.lineHeight(for: role)), min(ceil(rect.height), CGFloat(Metrics.lineHeight(for: role) * Double(lines))))
    }
}
