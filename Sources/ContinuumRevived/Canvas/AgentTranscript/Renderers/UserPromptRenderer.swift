import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Role-aware selection for semantic transcript entries. The kind-only registry
/// remains the source of truth for assistant/structured content; the transcript
/// list calls this overload once it owns an `AgentEntry`, so a user prose block
/// cannot accidentally take the assistant renderer merely because both share a
/// block kind.
///
/// This seam intentionally lives with the user renderer until the transcript-list
/// integration ticket: it does not put entry roles into the platform-neutral AST
/// block or duplicate the production registry's kind registrations.
@MainActor
extension AgentBlockRendererRegistry {
    func renderer(
        for kind: AgentBlockKind,
        entryRole: AgentEntryRole
    ) throws -> any AgentBlockRendering {
        if entryRole == .user, UserPromptRenderer.supportedKinds.contains(kind) {
            return UserPromptRenderer(kind: kind)
        }
        return try renderer(for: kind)
    }
}

/// The semantic user-turn surface. It deliberately shares the assistant prose
/// renderer's readable measure instead of introducing a separate Markdown parser
/// or a percentage-width chat bubble.
@MainActor
final class UserPromptRenderer: AgentBlockRendering {
    static let supportedKinds = AssistantProseRenderer.supportedKinds

    let kind: AgentBlockKind
    private let proseRenderer: AssistantProseRenderer

    init(kind: AgentBlockKind) {
        precondition(Self.supportedKinds.contains(kind), "unsupported user prompt kind: \(kind.rawValue)")
        self.kind = kind
        proseRenderer = AssistantProseRenderer(kind: kind)
    }

    func makeView() -> NSView {
        UserPromptView(proseRenderer: proseRenderer)
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? UserPromptView else { return }
        view.apply(block: block, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        // The prose measures against the INSET width, or text against the rule's
        // gutter would clip its last line.
        proseRenderer.measure(
            block: block,
            width: max(1, width - UserPromptView.leadingInset(zoom: context.pageZoom)),
            context: context
        ) + UserPromptView.verticalInset(zoom: context.pageZoom) * 2
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? UserPromptView else { return }
        view.applyAccessibility(block: block, context: context)
    }
}

/// A quiet, full-measure user surface. “You” exists only in the accessibility
/// tree; no title, outline, status word, or permanent speaker caption is drawn.
/// Ticket A1: the turn loses its card — no fill, no rounded corner — and keeps
/// only a `LineWidth.rule` authorship rule down the left edge. `AssistantProseRenderer`
/// sets `horizontalReadingInset == 0`, so the shared text column IS the row's
/// leading edge; there is no interior margin to hang the rule in, hence the
/// rule sits at `bounds.minX` and the prose is pushed in by `leadingInset`
/// instead of a symmetric padding pair.
@MainActor
final class UserPromptView: NSView, TokenThemed {
    static let verticalInset = CGFloat(Space.m)
    /// Rule width + breathing room before the first glyph. No trailing gutter:
    /// with no fill, a trailing inset is invisible and only narrows the measure.
    static let leadingInset = CGFloat(LineWidth.rule) + CGFloat(Space.m)

    // WS5 companions. The two zero-argument properties above are read by
    // `UIProbeGeometry`, `TranscriptRhythmChecks` and `AgentTranscriptListView`,
    // so they keep their shipped 100% values; this view and its renderer read
    // the zoomed ones.
    static func verticalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }
    /// The gutter is rule + air, and both halves scale, so the prose column
    /// still starts exactly one `Space.m` past the rule at every rung.
    static func leadingInset(zoom: AgentPageZoom) -> CGFloat {
        ruleWidth(zoom: zoom) + CGFloat(zoom.scaled(Space.m))
    }
    /// `LineWidth.rule` is an authorship EDGE, not the 0.5pt hairline the zoom
    /// pass leaves alone: at 150% a 2pt bar beside 150% type reads as a hairline.
    static func ruleWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(LineWidth.rule)) }

    private let proseRenderer: AssistantProseRenderer
    private(set) var proseView: AssistantProseView
    private let rule = NSView()

    init(proseRenderer: AssistantProseRenderer) {
        self.proseRenderer = proseRenderer
        guard let proseView = proseRenderer.makeView() as? AssistantProseView else {
            preconditionFailure("AssistantProseRenderer must vend AssistantProseView")
        }
        self.proseView = proseView
        super.init(frame: .zero)

        // The host paints no fill of its own (CLAUDE.md hazard 8: resting states
        // paint nil, never .clear). Only the rule subview carries a colour.
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("You")
        rule.wantsLayer = true
        addSubview(rule)
        addSubview(proseView)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var theme: TokenTheme = .dark
    /// The rung of the last `apply`, so a RECYCLED prompt lays its rule and
    /// gutter out at the zoom it is currently showing rather than the one it was
    /// constructed at. `layout()` has no context of its own to read.
    private var pageZoom: AgentPageZoom = .default

    func apply(block: AgentBlock, context: AgentRenderContext) {
        theme = context.appearance
        pageZoom = context.pageZoom
        proseRenderer.update(view: proseView, block: block, context: context)
        proseView.textFields.forEach { $0.stringPasteboardStyle = .plainText }
        identifier = NSUserInterfaceItemIdentifier("agent.userPrompt.\(block.id.rawValue)")
        applyAccessibility(block: block, context: context)
        applyTokens()
        needsLayout = true
    }

    func applyTokens() {
        rule.layer?.backgroundColor = AgentLineRole.authorship.color.cgColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyAccessibility(block: AgentBlock, context: AgentRenderContext) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("You")
        proseRenderer.updateAccessibility(view: proseView, block: block, context: context)
    }

    /// The layer colour this view paints on the subview it owns, for
    /// `UIProbeAppearance`'s sentinel sweep — the same hand-off
    /// `ManagedAgentTileNSView.qaTokenPaintedLayers` uses, because the sweep
    /// deliberately never reads a subview's layer and `rule` is a plain `NSView`
    /// that answers for nothing on its own.
    var qaTokenPaintedLayers: [(label: String, layer: CALayer)] {
        rule.layer.map { [(label: "rule", layer: $0)] } ?? []
    }

    override func layout() {
        super.layout()
        let leadingInset = Self.leadingInset(zoom: pageZoom)
        let verticalInset = Self.verticalInset(zoom: pageZoom)
        rule.frame = NSRect(
            x: bounds.minX, y: bounds.minY,
            width: Self.ruleWidth(zoom: pageZoom), height: bounds.height)
        proseView.frame = NSRect(
            x: bounds.minX + leadingInset,
            y: bounds.minY + verticalInset,
            width: max(1, bounds.width - leadingInset),
            height: max(0, bounds.height - verticalInset * 2)
        )
        proseView.layoutSubtreeIfNeeded()
    }
}
