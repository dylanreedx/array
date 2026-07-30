import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Mandatory payload-blind fallback for unknown and unregistered semantic kinds.
@MainActor
final class AgentUnknownBlockRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .unknown

    func makeView() -> NSView { AgentUnknownBlockView() }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        (view as? AgentUnknownBlockView)?.apply(block: block, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        AgentUnknownBlockView.height
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        view.setAccessibilityLabel(block.safeFallbackAccessibilityLabel)
    }
}

@MainActor
final class AgentUnknownBlockView: NSView {
    static let height = CGFloat(Space.xxl + Space.l)
    private(set) var summaryLabel = NSTextField(labelWithString: "Unsupported content")
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        summaryLabel.font = NSFont.token(.label)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isSelectable = true
        addSubview(summaryLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(block: AgentBlock, context: AgentRenderContext) {
        self.context = context
        summaryLabel.stringValue = block.safeFallbackSummary
        setAccessibilityLabel(block.safeFallbackAccessibilityLabel)
        setAccessibilityChildren([summaryLabel])
        identifier = NSUserInterfaceItemIdentifier("agent.unknown.\(block.id.rawValue)")
        applyTokens()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = CGFloat(Space.l)
        summaryLabel.frame = NSRect(
            x: inset,
            y: (bounds.height - summaryLabel.intrinsicContentSize.height) / 2,
            width: max(1, bounds.width - inset * 2),
            height: summaryLabel.intrinsicContentSize.height
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
        summaryLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
    }
}
