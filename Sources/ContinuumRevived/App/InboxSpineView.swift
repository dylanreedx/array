import AppKit
import ContinuumRevivedAgentUI

// Ticket: .plans/0721-subagents-handoff.md
/// The tree connector for one inbox row: the lanes of the groups it is inside, the
/// elbow into its own card, and the descender to its children.
///
/// PAINTED, NOT SUB-VIEWED, and drawn with `NSBezierPath` rather than layer colours
/// — the same two decisions `Decorations` makes next door, for the same two reasons.
/// One view per row instead of one per segment keeps the recycling cost flat
/// (`docs/internals/performance.md`), and a bezier fill keeps this view out of the
/// `TokenThemed` census it would otherwise have to buy its way into (hazard 8);
/// `AgentInbox96CellView` itself is absent from `tokenAdoptedOwners` for exactly
/// this reason.
///
/// The colour is `AgentLineRole.decorativeHairline` — the sanctioned exempt line.
/// The connector contains and separates content that is already delineated; it
/// carries NO state. Nothing here may ever take an accent: a red lane would be a
/// fourth colour meaning in a list P3.2 holds to three, and it would make the
/// hierarchy a status display.
///
/// It sits ABOVE the card and never below it. A parent's descender runs through its
/// own card's leading inset, and the card paints a fill while hovered, selected or
/// route-active — a connector drawn underneath would be erased by exactly the row
/// you are pointing at.
@MainActor
final class InboxSpineView: NSView {
    private var segments: [InboxSpineSegment] = []

    override var isFlipped: Bool { true }
    /// Decoration only — every click belongs to the row beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What this row draws of the tree. Frames are in this view's own coordinates,
    /// which the cell keeps equal to the row's.
    func show(
        _ nesting: InboxNesting, metrics: InboxSpineMetrics,
        cardTop: Double, cardHeight: Double, rowHeight: Double
    ) {
        let next = InboxSpine.segments(
            nesting, metrics: metrics, cardTop: cardTop,
            cardHeight: cardHeight, rowHeight: rowHeight)
        guard next != segments else { return }
        segments = next
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else { return }
        AgentLineRole.decorativeHairline.color.nsColor(in: self).setFill()
        for segment in segments {
            NSBezierPath(rect: NSRect(
                x: segment.minX, y: segment.minY,
                width: segment.width, height: segment.height)).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The connector AS DRAWN, for the witness. Read off what `draw` will paint, not
    /// recomputed from the row's depth — a check that re-derives the geometry the
    /// production code derives proves nothing about the production code.
    var qaSegmentsForQA: [InboxSpineSegment] { segments }
}
