import AppKit
import ContinuumRevivedAgentContent

/// Reusable AppKit boundary for one semantic block. A stable block keeps its
/// renderer view while revisions are applied in place; crossing an ID or kind
/// boundary creates a clean renderer view so per-block interaction state cannot
/// leak between collection-view reuse assignments.
@MainActor
final class AgentBlockHostView: NSView {
    private let registry: AgentBlockRendererRegistry
    let measurementCache: AgentBlockMeasurementCache

    private var renderer: (any AgentBlockRendering)?
    private var actionGeneration: UInt64 = 0
    private(set) var rendererView: NSView?
    private(set) var representedID: AgentNodeID?
    private(set) var representedKind: AgentBlockKind?
    private(set) var representedRevision: UInt64?
    private(set) var reuseGeneration: UInt64 = 0

    private(set) var isBlockHovered = false
    private(set) var isBlockSelected = false
    private(set) var isDisclosureExpanded = false

    init(
        registry: AgentBlockRendererRegistry = .production,
        measurementCache: AgentBlockMeasurementCache = AgentBlockMeasurementCache()
    ) {
        self.registry = registry
        self.measurementCache = measurementCache
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(block: AgentBlock, context: AgentRenderContext) throws {
        let needsCleanView = rendererView == nil
            || representedID != block.id
            || representedKind != block.kind

        if needsCleanView {
            resetRenderedState(incrementGeneration: representedID != nil)
            let resolved = try registry.renderer(for: block.kind)
            let view = resolved.makeView()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            renderer = resolved
            rendererView = view
        }

        guard let renderer, let rendererView else { return }
        representedID = block.id
        representedKind = block.kind
        representedRevision = block.revision

        // A renderer may retain its action closure in controls or custom views.
        // Invalidate every earlier closure before updating, so detached views and
        // superseded revisions cannot act on a block the host no longer represents.
        actionGeneration &+= 1
        let generation = actionGeneration
        var gatedContext = context
        gatedContext.actions = AgentRenderActions { [weak self] action in
            guard self?.actionGeneration == generation else { return }
            context.actions.perform(action)
        }
        renderer.update(view: rendererView, block: block, context: gatedContext)
        renderer.updateAccessibility(view: rendererView, block: block, context: gatedContext)
    }

    func measuredHeight(
        for block: AgentBlock,
        width: CGFloat,
        context: AgentRenderContext,
        contentSizePolicy: AgentContentSizePolicy = .standard
    ) throws -> CGFloat {
        let renderer = try registry.renderer(for: block.kind)
        return measurementCache.height(
            for: block,
            width: width,
            context: context,
            contentSizePolicy: contentSizePolicy,
            renderer: renderer
        )
    }

    /// Explicit host reuse hook. This deliberately drops the renderer view:
    /// disclosure controls, text selection, tracking areas, accessibility values,
    /// and action closures then have no path into the next represented block.
    func resetForReuse() {
        resetRenderedState(incrementGeneration: true)
    }

    func setInteractionState(hovered: Bool, selected: Bool, disclosureExpanded: Bool) {
        isBlockHovered = hovered
        isBlockSelected = selected
        isDisclosureExpanded = disclosureExpanded
    }

    private func resetRenderedState(incrementGeneration: Bool) {
        actionGeneration &+= 1
        if incrementGeneration { reuseGeneration &+= 1 }
        if let rendererView {
            clearAccessibility(in: rendererView)
            rendererView.removeFromSuperview()
        }
        renderer = nil
        rendererView = nil
        representedID = nil
        representedKind = nil
        representedRevision = nil
        isBlockHovered = false
        isBlockSelected = false
        isDisclosureExpanded = false
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
    }

    private func clearAccessibility(in view: NSView) {
        view.setAccessibilityLabel(nil)
        view.setAccessibilityValue(nil)
        view.setAccessibilityHelp(nil)
        view.setAccessibilitySelected(false)
        for child in view.subviews { clearAccessibility(in: child) }
    }
}
