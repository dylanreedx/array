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
        proseRenderer.measure(block: block, width: width, context: context)
            + UserPromptView.verticalInset * 2
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? UserPromptView else { return }
        view.applyAccessibility(block: block, context: context)
    }
}

/// A quiet, full-measure user surface. “You” exists only in the accessibility
/// tree; no title, outline, status word, or permanent speaker caption is drawn.
@MainActor
final class UserPromptView: NSView {
    static let verticalInset = CGFloat(Space.m)
    static let fillToken = SurfaceToken.cardUserMessage
    static let cornerRadius = CGFloat(AgentTileRadius.artifact)

    private let proseRenderer: AssistantProseRenderer
    private(set) var proseView: AssistantProseView

    init(proseRenderer: AssistantProseRenderer) {
        self.proseRenderer = proseRenderer
        guard let proseView = proseRenderer.makeView() as? AssistantProseView else {
            preconditionFailure("AssistantProseRenderer must vend AssistantProseView")
        }
        self.proseView = proseView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("You")
        addSubview(proseView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(block: AgentBlock, context: AgentRenderContext) {
        layer?.backgroundColor = Self.fillToken.color.cgColor(for: context.appearance)
        proseRenderer.update(view: proseView, block: block, context: context)
        proseView.textFields.forEach { $0.stringPasteboardStyle = .plainText }
        identifier = NSUserInterfaceItemIdentifier("agent.userPrompt.\(block.id.rawValue)")
        applyAccessibility(block: block, context: context)
        needsLayout = true
    }

    func applyAccessibility(block: AgentBlock, context: AgentRenderContext) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("You")
        proseRenderer.updateAccessibility(view: proseView, block: block, context: context)
    }

    override func layout() {
        super.layout()
        proseView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY + Self.verticalInset,
            width: bounds.width,
            height: max(0, bounds.height - Self.verticalInset * 2)
        )
        proseView.layoutSubtreeIfNeeded()
    }
}
