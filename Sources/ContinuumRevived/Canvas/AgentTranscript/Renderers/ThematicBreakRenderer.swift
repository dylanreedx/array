import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// `.plans/45` T9 — `---` draws a rule.
///
/// `.thematicBreak` has been parsed and listed in `builtInKinds` since the
/// semantic model landed, but it matched no branch of the registry bootstrap and
/// fell through to `AgentDeferredBlockRenderer`: a bare `NSView` that measures
/// 24pt and paints nothing. With row spacing either side, an author's section
/// break rendered as a 48pt hole — reading as an accident rather than as
/// structure.
@MainActor
final class ThematicBreakRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .thematicBreak

    /// The rule sits in the middle of this box; the air around it is what makes a
    /// break read as a break. Kept below the 24pt the deferred renderer used, so
    /// adopting a real rule tightens the document rather than loosening it.
    static let boxHeight = CGFloat(Space.xl)

    func makeView() -> NSView { ThematicBreakView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? ThematicBreakView else { return }
        view.apply(blockID: block.id, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        Self.boxHeight
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Section break")
    }
}

/// A decorative hairline.
///
/// `_DESIGN.md` §11 splits meaning from decoration: a soft hairline is for
/// "decorative containment and section separation", and is explicitly exempt
/// from the 3:1 non-text floor, while a strong semantic line is reserved for
/// selection, focus, approval, error or warning. A section break is decoration,
/// so it takes `AgentLineRole.decorativeHairline` and must not be promoted to
/// something that pulls the eye.
@MainActor
final class ThematicBreakView: NSView, TokenThemed {
    private let rule = CALayer()
    private var theme: TokenTheme = .dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The HOST paints no fill: a resting surface owns no colour slot, and a
        // painted transparent would be an unregistered literal to the appearance
        // census (CLAUDE.md hazard 8). Only the child rule carries a colour.
        layer?.backgroundColor = nil
        rule.masksToBounds = true
        layer?.addSublayer(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, context: AgentRenderContext) {
        theme = context.appearance
        identifier = NSUserInterfaceItemIdentifier("agent.thematicBreak.\(blockID.rawValue)")
        applyTokens()
        needsLayout = true
    }

    func applyTokens() {
        rule.backgroundColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let height = max(CGFloat(LineWidth.hairline), 1.0 / (window?.backingScaleFactor ?? 2))
        let frame = NSRect(
            x: 0, y: (bounds.height - height) / 2,
            width: bounds.width, height: height
        )
        // Unconditional frame writes are `performance.md` trap 3, and this view
        // lays out on every display cycle its row does.
        if rule.frame != frame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rule.frame = frame
            CATransaction.commit()
        }
    }
}
