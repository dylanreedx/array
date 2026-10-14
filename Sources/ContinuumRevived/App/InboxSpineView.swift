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

/// The quiet shared wash behind one parent and its visible descendants. Each
/// table cell paints only its own strip; matching edges bleed across the table's
/// intercell spacing, so the strips read as one grouped surface without a second
/// outline or a per-child card.
@MainActor
final class InboxGroupBackgroundView: NSView {
    private var isGroupMember = false
    private var roundsTop = false
    private var roundsBottom = false
    private var horizontalInset: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ nesting: InboxNesting, hasChildren: Bool,
              metrics: InboxSpineMetrics, rowHeight: CGFloat) {
        isGroupMember = hasChildren || nesting.depth > 0
        roundsTop = isGroupMember && nesting.depth == 0
        roundsBottom = isGroupMember && nesting.nextDepth == 0
        horizontalInset = CGFloat(metrics.gutter)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isGroupMember else { return }
        let rect = NSRect(x: horizontalInset, y: 0,
                          width: max(0, bounds.width - horizontalInset * 2),
                          height: bounds.height)
        guard rect.width > 0, rect.height > 0 else { return }
        let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
        let base = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
        let foreground = TextToken.textPrimary.color.resolved(for: theme)
        let wash = TokenColor(foreground.composited(over: base, alpha: 0.035))
        wash.nsColor(for: theme).setFill()
        roundedGroupStrip(rect, top: roundsTop ? 8 : 0, bottom: roundsBottom ? 8 : 0).fill()
    }

    private func roundedGroupStrip(_ rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let k: CGFloat = 0.5522847498
        path.move(to: NSPoint(x: rect.minX + top, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + top),
                       controlPoint1: NSPoint(x: rect.maxX - top + top * k, y: rect.minY),
                       controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + top - top * k))
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            path.curve(to: NSPoint(x: rect.maxX - bottom, y: rect.maxY),
                       controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - bottom + bottom * k),
                       controlPoint2: NSPoint(x: rect.maxX - bottom + bottom * k, y: rect.maxY))
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - bottom),
                       controlPoint1: NSPoint(x: rect.minX + bottom - bottom * k, y: rect.maxY),
                       controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - bottom + bottom * k))
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.curve(to: NSPoint(x: rect.minX + top, y: rect.minY),
                       controlPoint1: NSPoint(x: rect.minX, y: rect.minY + top - top * k),
                       controlPoint2: NSPoint(x: rect.minX + top - top * k, y: rect.minY))
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }
        path.close()
        return path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var qaIsVisibleForQA: Bool { isGroupMember }
    var qaRoundsTopForQA: Bool { roundsTop }
    var qaRoundsBottomForQA: Bool { roundsBottom }
}
