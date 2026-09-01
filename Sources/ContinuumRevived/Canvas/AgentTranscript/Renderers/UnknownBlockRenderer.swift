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
        AgentUnknownBlockView.height(zoom: context.pageZoom)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        view.setAccessibilityLabel(block.safeFallbackAccessibilityLabel)
    }
}

@MainActor
final class AgentUnknownBlockView: NSView {
    static let height = CGFloat(Space.xxl + Space.l)
    /// WS5: the same box at a page zoom. The zero-arg `height` above is kept
    /// because two files outside this one pin it as the 100% value.
    static func height(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(Space.xxl + Space.l))
    }
    private(set) var summaryLabel = NSTextField(labelWithString: "Unsupported content")
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // WS5: the radius and the font are re-derived in `apply` from the
        // context's rung — this view is recycled, so whatever it was born with
        // is only a starting point.
        applyPageZoomMetrics(context.pageZoom)
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
        applyPageZoomMetrics(context.pageZoom)
        summaryLabel.stringValue = block.safeFallbackSummary
        setAccessibilityLabel(block.safeFallbackAccessibilityLabel)
        setAccessibilityChildren([summaryLabel])
        identifier = NSUserInterfaceItemIdentifier("agent.unknown.\(block.id.rawValue)")
        applyTokens()
        needsLayout = true
    }

    /// Every zoom-derived metric this view owns, assigned from scratch. Called
    /// from `init` and again from every `apply`, because a view built at 100%
    /// is reused for a row at 150%.
    private func applyPageZoomMetrics(_ zoom: AgentPageZoom) {
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        summaryLabel.font = NSFont.token(.label, zoom: zoom)
    }

    override func layout() {
        super.layout()
        let inset = CGFloat(context.pageZoom.scaled(Space.l))
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
