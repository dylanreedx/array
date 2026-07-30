import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Compact structured-tool presentation. The renderer intentionally consumes
/// only the safe name/summary fields; opaque arguments never enter the view.
@MainActor
final class ToolCallRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .toolCall

    func makeView() -> NSView {
        ToolCallView()
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? ToolCallView,
              case let .toolCall(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .toolCall(payload) = block.payload else { return 0 }
        let expanded = context.actions.isExpanded(
            blockID: block.id,
            default: payload.status.agentToolDefaultExpanded
        )
        return ToolCallView.measuredHeight(summary: payload.summary, width: width, expanded: expanded)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? ToolCallView,
              case let .toolCall(payload) = block.payload else { return }
        view.applyAccessibility(name: payload.name, status: payload.status)
    }
}

@MainActor
final class ToolCallView: NSView {
    static let rowHeight = CGFloat(Space.xxl + Space.m)
    static let horizontalInset = CGFloat(Space.l)
    static let detailBottomInset = CGFloat(Space.m)

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: "Tool")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var isExpanded = false

    private var blockID: AgentNodeID?
    private var status: AgentItemStatus = .pending
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        iconView.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = NSFont.token(.body)
        summaryLabel.maximumNumberOfLines = 4
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isSelectable = true

        addSubview(disclosureButton)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(summaryLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentToolCallPayload, context: AgentRenderContext) {
        self.blockID = blockID
        self.status = payload.status
        self.context = context

        isExpanded = context.actions.isExpanded(
            blockID: blockID,
            default: payload.status.agentToolDefaultExpanded
        )
        titleLabel.stringValue = Self.safeSingleLine(payload.name, fallback: "Tool")
        let presentation = payload.status.agentToolStatusPresentation
        statusLabel.stringValue = "\(presentation.glyph) \(presentation.label)"
        summaryLabel.stringValue = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        summaryLabel.isHidden = !isExpanded || summaryLabel.stringValue.isEmpty
        disclosureButton.apply(expanded: isExpanded, title: titleLabel.stringValue)
        identifier = NSUserInterfaceItemIdentifier("agent.toolCall.\(blockID.rawValue)")
        applyAccessibility(name: titleLabel.stringValue, status: payload.status)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(name: String, status: AgentItemStatus) {
        let presentation = status.agentToolStatusPresentation
        setAccessibilityLabel("Tool, \(Self.safeSingleLine(name, fallback: "Tool")), \(presentation.label)")
        setAccessibilityChildren(summaryLabel.isHidden
            ? [disclosureButton, titleLabel, statusLabel]
            : [disclosureButton, titleLabel, statusLabel, summaryLabel])
    }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let buttonSide = CGFloat(Space.xxl)
        disclosureButton.frame = NSRect(
            x: inset, y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        iconView.frame = NSRect(
            x: disclosureButton.frame.maxX + CGFloat(Space.s),
            y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        let statusWidth = min(statusLabel.intrinsicContentSize.width, max(0, bounds.width * 0.34))
        statusLabel.frame = NSRect(
            x: max(iconView.frame.maxX, bounds.maxX - inset - statusWidth),
            y: (Self.rowHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth, height: statusLabel.intrinsicContentSize.height
        )
        let titleX = iconView.frame.maxX + CGFloat(Space.m)
        titleLabel.frame = NSRect(
            x: titleX,
            y: (Self.rowHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - titleX - CGFloat(Space.m)),
            height: titleLabel.intrinsicContentSize.height
        )
        let detailY = Self.rowHeight
        summaryLabel.frame = NSRect(
            x: inset, y: detailY,
            width: max(1, bounds.width - inset * 2),
            height: max(0, bounds.height - detailY - Self.detailBottomInset)
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        summaryLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = status == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        disclosureButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        iconView.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
    }

    static func measuredHeight(summary: String?, width: CGFloat, expanded: Bool) -> CGFloat {
        guard expanded,
              let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return rowHeight }
        let available = max(1, width - horizontalInset * 2)
        let rect = (summary as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.body)]
        )
        let lineHeight = CGFloat(Metrics.lineHeight(for: .body))
        return rowHeight + min(ceil(rect.height), lineHeight * 4) + detailBottomInset
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        guard let blockID else { return }
        isExpanded.toggle()
        context.actions.setExpanded(isExpanded, blockID: blockID)
        summaryLabel.isHidden = !isExpanded || summaryLabel.stringValue.isEmpty
        disclosureButton.apply(expanded: isExpanded, title: titleLabel.stringValue)
        applyAccessibility(name: titleLabel.stringValue, status: status)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func safeSingleLine(_ value: String, fallback: String) -> String {
        let line = value
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? fallback : line
    }
}

/// A native button supplies hit testing and keyboard activation; all visible
/// disclosure chrome is Continuum-owned and borderless.
@MainActor
final class AgentDisclosureButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.label)
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        identifier = NSUserInterfaceItemIdentifier("agent.disclosure")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(expanded: Bool, title itemTitle: String) {
        title = expanded ? "▾" : "▸"
        toolTip = expanded ? "Collapse \(itemTitle)" : "Expand \(itemTitle)"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}
