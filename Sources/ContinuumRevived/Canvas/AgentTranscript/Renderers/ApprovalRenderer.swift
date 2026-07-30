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
        return AgentRequestView.measuredHeight(payload: payload, width: width)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentRequestView, case let .approval(payload) = block.payload else { return }
        view.applyAccessibility(payload: payload)
    }
}

@MainActor
final class AgentRequestView: NSView {
    enum Mode { case approval, question }

    static let headerHeight = CGFloat(Space.xxl + Space.l)
    static let horizontalInset = CGFloat(Space.l)
    static let actionHeight = CGFloat(Space.xxl + Space.xs)
    static let bottomInset = CGFloat(Space.l)
    static let maximumChoices = 4

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
    private(set) var choiceButtons: [NSButton] = []
    private(set) var requestID: String?

    private var generation: UInt64 = 0
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var status: AgentItemStatus = .pending

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        titleLabel.font = NSFont.token(.title)
        statusLabel.font = NSFont.token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail
        promptLabel.font = NSFont.token(.body)
        promptLabel.maximumNumberOfLines = 4
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.isSelectable = true
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(promptLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
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
        let inset = Self.horizontalInset
        let statusWidth = min(statusLabel.intrinsicContentSize.width, max(0, bounds.width * 0.34))
        statusLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - statusWidth),
            y: (Self.headerHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset, y: (Self.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - inset - CGFloat(Space.m)),
            height: titleLabel.intrinsicContentSize.height
        )
        let promptHeight = Self.promptHeight(promptLabel.stringValue, width: bounds.width)
        promptLabel.frame = NSRect(
            x: inset, y: Self.headerHeight,
            width: max(1, bounds.width - inset * 2), height: promptHeight
        )
        guard !choiceButtons.isEmpty else { return }
        let y = promptLabel.frame.maxY + CGFloat(Space.m)
        let gap = CGFloat(Space.s)
        let width = max(1, (bounds.width - inset * 2 - gap * CGFloat(choiceButtons.count - 1)) / CGFloat(choiceButtons.count))
        for (index, button) in choiceButtons.enumerated() {
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
        promptLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = status == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        choiceButtons.forEach { $0.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme) }
    }

    static func measuredHeight(payload: AgentRequestPayload, width: CGFloat) -> CGFloat {
        let actionable = payload.requestID != nil
            && [.pending, .inProgress].contains(payload.status)
            && !payload.choices.isEmpty
        return headerHeight
            + promptHeight(agentPlainText(payload.prompt), width: width)
            + (actionable ? CGFloat(Space.m) + actionHeight : 0)
            + bottomInset
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

    private static func promptHeight(_ value: String, width: CGFloat) -> CGFloat {
        let rect = (value as NSString).boundingRect(
            with: NSSize(width: max(1, width - horizontalInset * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.body)]
        )
        return max(CGFloat(Metrics.lineHeight(for: .body)), min(ceil(rect.height), CGFloat(Metrics.lineHeight(for: .body) * 4)))
    }
}

@MainActor
final class AgentRequestChoiceButton: NSButton {
    var actionToken: AnyObject?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.label)
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        identifier = NSUserInterfaceItemIdentifier("agent.request.choice")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
