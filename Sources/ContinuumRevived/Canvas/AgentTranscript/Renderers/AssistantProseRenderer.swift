import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Native semantic prose renderer. Container traversal stays here while each
/// inline row is delegated to TextKit without reparsing Markdown or provider
/// text.
@MainActor
final class AssistantProseRenderer: AgentBlockRendering {
    static let supportedKinds: Set<AgentBlockKind> = [.paragraph, .heading, .list, .listItem, .quote]

    let kind: AgentBlockKind

    init(kind: AgentBlockKind) {
        precondition(Self.supportedKinds.contains(kind), "unsupported assistant prose kind: \(kind.rawValue)")
        self.kind = kind
    }

    func makeView() -> NSView {
        AssistantProseView(frame: .zero)
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AssistantProseView else { return }
        view.apply(block: block, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        AssistantProseView.measuredHeight(for: block, width: width, context: context)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AssistantProseView else { return }
        view.applyContainerAccessibility(for: block)
    }
}

/// A borderless, fill-less reading surface. Each semantic row gets one native
/// selectable TextKit view while list/quote order and accessibility remain owned
/// by the semantic container traversal.
@MainActor
final class AssistantProseView: NSView {
    /// `.plans/45` T6. Zero, deliberately.
    ///
    /// The layout already insets every row by `contentInsets.left` (12), which is
    /// where an artifact's FILL begins. Prose used to add a second 12 on top, so
    /// prose text sat at 24 while card edges sat at 12 and nothing on the page
    /// shared a left edge. Text inside an artifact keeps its own 12pt inset, so
    /// the result is prose and card edges aligned, with card text indented within
    /// its own fill — which is what containment should look like.
    static let horizontalReadingInset: CGFloat = 0
    /// WS5 companion. The zero-argument `static let` above is referenced from
    /// `UIProbeGeometry` and `TranscriptRhythmChecks`, so it stays exactly as it
    /// is; production reads this instead. Zero scales to zero at every rung —
    /// the companion exists so the reading inset cannot silently become a
    /// hardcoded metric if the value ever stops being 0.
    static func horizontalReadingInset(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(0))
    }
    private static func blockSpacing(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }

    private(set) var textFields: [RichInlineTextView] = []
    /// Pre-built marker glyphs by row index, and the frames to draw them beside.
    private var markerRuns: [(Int, NSAttributedString)] = []
    private var markerFrames: [Int: NSRect] = [:]
    private var rows: [Row] = []
    private var renderContext = AgentRenderContext(
        actions: .disabled,
        tokens: .transcript,
        appearance: .dark
    )

    private static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")
    private static let listItemRole = NSAccessibility.Role(rawValue: "AXListItem")

    private struct Row {
        let blockID: AgentNodeID
        let runs: [AgentInline]
        let role: NSAccessibility.Role
        let headingLevel: Int?
        let textRole: TextRole
        var style: AgentProseTextStyle = .plain
        /// Extra air ABOVE this row, on top of `blockSpacing`.
        ///
        /// A heading belongs to what follows it, so it needs more space above
        /// than below — without that, a section title floats midway between two
        /// paragraphs and reads as belonging to the one it just ended.
        var spacingAbove: CGFloat = 0
        /// The marker ("• ", "3. ", "› ") drawn in the gutter, outside the text
        /// run. `.plans/45` T4: it used to be concatenated onto `runs`, so a
        /// wrapped line aligned under the marker instead of under the text.
        var marker: String = ""
    }

    /// Gutter width per list nesting level, and the width reserved for the marker
    /// itself. Both are grid values so the reading column stays on the 2pt grid.
    private static func listIndentPerLevel(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(Space.l))
    }
    private static func markerGutter(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(Space.l))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Intentionally do not request a layer. Assistant prose inherits the
        // tile-body surface; it owns no fill, border, radius, or shadow.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Manual row frames advance from the visual top in semantic document order.
    override var isFlipped: Bool { true }

    func apply(block: AgentBlock, context: AgentRenderContext) {
        renderContext = context
        textFields.forEach { $0.removeFromSuperview() }
        // WS5: the row set carries the ZOOMED indents and leading, so a recycled
        // view rebuilt at another rung re-derives every metric here rather than
        // keeping the ones it was born with.
        rows = Self.rows(for: block, zoom: context.pageZoom)
        textFields = rows.map { row in
            let view = RichInlineTextView(frame: .zero)
            view.apply(
                runs: row.runs, blockID: row.blockID, context: context,
                textRole: row.textRole, style: row.style)
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(row.role)
            view.setAccessibilityLabel(view.string)
            if let level = row.headingLevel { view.setAccessibilityValue(level) }
            addSubview(view)
            return view
        }
        markerFrames.removeAll(keepingCapacity: true)
        markerRuns = rows.enumerated().compactMap { index, row in
            guard !row.marker.isEmpty else { return nil }
            let font = NSFont.token(row.textRole, zoom: context.pageZoom)
            return (index, NSAttributedString(string: row.marker, attributes: [
                .font: font,
                .foregroundColor: context.tokens.secondaryText.color.nsColor(for: context.appearance),
            ]))
        }
        invalidateRowHeights()
        identifier = NSUserInterfaceItemIdentifier("agent.assistantProse.\(block.id.rawValue)")
        applyContainerAccessibility(for: block)
        needsLayout = true
    }

    func applyContainerAccessibility(for block: AgentBlock) {
        if block.kind == .list {
            setAccessibilityElement(true)
            setAccessibilityRole(.list)
            setAccessibilityLabel("Assistant list")
        } else {
            setAccessibilityElement(false)
            setAccessibilityLabel(nil)
        }
    }

    /// Row heights for `cachedWidth`. `layout()` runs on every display cycle, and
    /// both halves of the old body were expensive: measuring rebuilds an attributed
    /// string per row (with five `replacingOccurrences` passes inside the Markdown
    /// escape), and assigning a frame to an `NSTextView` makes TextKit recompute
    /// glyph bounds. A 0.4.16 CPU report on a Markdown file tile spent 90 seconds
    /// at 96% CPU with 20 of 34 samples inside this method.
    private var cachedRowHeights: [CGFloat] = []
    private var cachedWidth: CGFloat = -1

    /// QA: total row measurements across all instances, for the layout-settle
    /// witness. Not used by production.
    static private(set) var qaMeasurementCount = 0

    /// The width transition that caused the most recent re-measure, kept so a
    /// gesture log can NAME the trigger. A cache keyed on width can only miss when
    /// the width moved (or the row count did), and 30,000 CoreText samples during a
    /// camera gesture came through here without anything saying what moved.
    static private(set) var qaLastMeasureTrigger = "-"


    private func invalidateRowHeights() {
        cachedRowHeights = []
        cachedWidth = -1
    }

    /// Re-measure only when the width has REALLY moved. During a camera zoom,
    /// pixel snapping at the effective scale (which includes the zoom) re-rounds
    /// interior widths by up to one device pixel — ±1.3 pt at zoom 0.4, measured in
    /// a live gesture log — and a 0.5 pt guard re-shaped every row for it: 4,310
    /// measurements in one 8-step gesture, 569 ms per frame. Two points is wider
    /// than a device pixel at any zoom the canvas allows and invisibly small for a
    /// ragged text edge; rows are laid out at the MEASURED width, so wrap geometry
    /// always matches what was measured and nothing can clip.
    static let measureWidthHysteresis: CGFloat = 2.0

    override func layout() {
        super.layout()
        let zoom = renderContext.pageZoom
        let readingInset = Self.horizontalReadingInset(zoom: zoom)
        let availableWidth = max(1, bounds.width - readingInset * 2)
        if abs(cachedWidth - availableWidth) > Self.measureWidthHysteresis
            || cachedRowHeights.count != rows.count {
            Self.qaLastMeasureTrigger = String(
                format: "prose %.1f->%.1f rows %d->%d", cachedWidth, availableWidth,
                cachedRowHeights.count, rows.count
            )
            cachedRowHeights = rows.map { row in
                Self.qaMeasurementCount += 1
                return RichInlineTextView.measuredHeight(
                    for: row.runs,
                    width: availableWidth,
                    context: renderContext,
                    textRole: row.textRole,
                    style: row.style
                )
            }
            cachedWidth = availableWidth
        }
        var y = bounds.minY
        // `cachedWidth`, not `availableWidth`: the frames must be the width the
        // heights were measured at, or a width inside the hysteresis band could
        // wrap one line more than was measured and clip it.
        let rowWidth = cachedWidth > 0 ? cachedWidth : availableWidth
        for (index, pair) in zip(rows, textFields).enumerated() {
            let height = cachedRowHeights[index]
            let frame = NSRect(x: readingInset, y: y, width: rowWidth, height: height)
            // An unchanged frame still costs a TextKit glyph-bounds pass, and it
            // re-dirties the view — which is what kept the display cycle spinning.
            if pair.1.frame != frame { pair.1.frame = frame }
            markerFrames[index] = frame
            y += height
            if index + 1 < rows.count {
                y += Self.blockSpacing(zoom: zoom) + rows[index + 1].spacingAbove
            }
        }
        if !markerRuns.isEmpty { needsDisplay = true }
    }

    /// List and quote markers are DRAWN, not sub-viewed.
    ///
    /// `.plans/45` T4 + `performance.md` trap 1. A marker label per list item is
    /// one more AppKit view per content item on the surface whose view count
    /// already froze the app in 0.4.16. The attributed strings are built once in
    /// `apply` and only stroked here, so a display cycle costs a draw and no
    /// allocation, measurement or layout.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !markerRuns.isEmpty else { return }
        for (index, marker) in markerRuns {
            guard let frame = markerFrames[index] else { continue }
            let indent = rows[index].style.firstLineHeadIndent
            let size = marker.size()
            let x = frame.minX + indent - Self.markerGutter(zoom: renderContext.pageZoom)
            // Baseline-align the marker with the first line of its row rather than
            // centring it in the row: a two-line item would otherwise float its
            // bullet into the middle of the text.
            let origin = NSPoint(x: max(frame.minX, x), y: frame.minY)
            guard dirtyRect.intersects(NSRect(origin: origin, size: size)) else { continue }
            marker.draw(at: origin)
        }
    }

    static func measuredHeight(
        for block: AgentBlock,
        width: CGFloat,
        context: AgentRenderContext
    ) -> CGFloat {
        // Exactly the metrics `apply`/`layout` paint with, from the same zoom.
        let zoom = context.pageZoom
        let rows = rows(for: block, zoom: zoom)
        guard !rows.isEmpty else { return 0 }
        let availableWidth = max(1, width - horizontalReadingInset(zoom: zoom) * 2)
        let text = rows.reduce(CGFloat.zero) {
            $0 + RichInlineTextView.measuredHeight(
                for: $1.runs,
                width: availableWidth,
                context: context,
                textRole: $1.textRole,
                style: $1.style
            )
        }
        // The leading space of every row after the first is part of the measured
        // height, or a heading's extra air would be laid out and never measured —
        // which clips the last row of the block.
        let leading = rows.dropFirst().reduce(CGFloat.zero) { $0 + $1.spacingAbove }
        return ceil(text + CGFloat(max(0, rows.count - 1)) * blockSpacing(zoom: zoom) + leading)
    }

    private static func rows(
        for block: AgentBlock,
        zoom: AgentPageZoom,
        listDepth: Int = 0,
        itemNumber: Int? = nil
    ) -> [Row] {
        switch block.payload {
        case let .paragraph(content):
            let marker = itemMarker(number: itemNumber)
            return [Row(
                blockID: block.id,
                runs: content,
                role: itemNumber == nil ? .staticText : listItemRole,
                headingLevel: nil,
                textRole: .body,
                style: listStyle(depth: listDepth, hasMarker: !marker.isEmpty, zoom: zoom),
                marker: marker
            )] + block.children.flatMap { rows(for: $0, zoom: zoom, listDepth: listDepth) }
        case let .heading(level, content):
            let clampedLevel = max(1, min(6, Int(level)))
            let ladder = headingLadder(level: clampedLevel, zoom: zoom)
            return [Row(
                blockID: block.id,
                runs: content,
                role: headingRole,
                headingLevel: clampedLevel,
                textRole: ladder.role,
                style: ladder.style,
                spacingAbove: ladder.spaceAbove
            )] + block.children.flatMap { rows(for: $0, zoom: zoom, listDepth: listDepth) }
        case let .list(payload):
            let start = payload.start ?? 1
            return block.children.enumerated().flatMap { index, child in
                rows(for: child, zoom: zoom, listDepth: listDepth + 1, itemNumber: payload.ordered ? start + index : 0)
            }
        case .listItem:
            let marker = itemMarker(number: itemNumber)
            if block.children.isEmpty {
                return [Row(
                    blockID: block.id,
                    runs: [],
                    role: listItemRole,
                    headingLevel: nil,
                    textRole: .body,
                    style: listStyle(depth: listDepth, hasMarker: !marker.isEmpty, zoom: zoom),
                    marker: marker
                )]
            }
            return block.children.enumerated().flatMap { index, child in
                let childNumber = index == 0 ? itemNumber : nil
                return rows(for: child, zoom: zoom, listDepth: listDepth, itemNumber: childNumber)
            }
        case .quote:
            return block.children.flatMap { rows(for: $0, zoom: zoom, listDepth: listDepth) }.map { row in
                var style = row.style
                style.firstLineHeadIndent += markerGutter(zoom: zoom)
                style.headIndent += markerGutter(zoom: zoom)
                style.secondary = true
                return Row(
                    blockID: row.blockID,
                    runs: row.runs,
                    role: row.role,
                    headingLevel: row.headingLevel,
                    textRole: row.textRole,
                    style: style,
                    marker: row.marker.isEmpty ? "\u{203A}" : row.marker
                )
            }
        default:
            return block.children.flatMap { rows(for: $0, zoom: zoom, listDepth: listDepth) }
        }
    }

    /// The marker text alone. Nesting is expressed as an indent, never as literal
    /// spaces inside the run — two spaces per level in a proportional font is not
    /// a column, and it cannot be aligned against.
    private static func itemMarker(number: Int?) -> String {
        guard let number else { return "" }
        return number == 0 ? "\u{2022}" : "\(number)."
    }

    /// Indents for a list row. `firstLineHeadIndent` and `headIndent` are equal
    /// because the marker is drawn in the gutter to the LEFT of both, so the
    /// first line and every wrapped line share one left edge.
    private static func listStyle(depth: Int, hasMarker: Bool, zoom: AgentPageZoom) -> AgentProseTextStyle {
        guard depth > 0 else { return .plain }
        // `AgentProseTextStyle`'s indents are CGFloats this caller computes, so
        // the zoomed value has to be baked in HERE or the text column stays at
        // its 100% gutter while the glyphs grow.
        let indent = CGFloat(max(0, depth - 1)) * listIndentPerLevel(zoom: zoom)
            + (hasMarker ? markerGutter(zoom: zoom) : 0)
        return AgentProseTextStyle(headIndent: indent, firstLineHeadIndent: indent)
    }

    /// Six visually distinct rungs out of three usable type sizes.
    ///
    /// `Typography` has `titleL` 18, `title` 15 and `body` 13 above `label`, and
    /// `Typography.minimumLadderStep` is gated, so 14 and 16 cannot be slotted in
    /// between. The remaining hierarchy therefore comes from weight and colour —
    /// which is also what `_DESIGN.md` §11 asks for ("soft hierarchy, not
    /// perimeter borders everywhere").
    private static func headingLadder(
        level: Int,
        zoom: AgentPageZoom
    ) -> (role: TextRole, style: AgentProseTextStyle, spaceAbove: CGFloat) {
        // The rung's SIZE follows the zoom through `TextRole` (every paint and
        // measure resolves the font with `zoom:`); only the air above it is a
        // length this ladder owns, so only that is scaled here.
        switch level {
        case 1: return (.titleL, AgentProseTextStyle(bold: true), CGFloat(zoom.scaled(Space.l)))
        case 2: return (.title, AgentProseTextStyle(), CGFloat(zoom.scaled(Space.l)))
        case 3: return (.title, AgentProseTextStyle(secondary: true), CGFloat(zoom.scaled(Space.m)))
        case 4: return (.body, AgentProseTextStyle(bold: true), CGFloat(zoom.scaled(Space.m)))
        case 5: return (.body, AgentProseTextStyle(bold: true, secondary: true), CGFloat(zoom.scaled(Space.s)))
        default: return (.label, AgentProseTextStyle(bold: true, secondary: true), CGFloat(zoom.scaled(Space.s)))
        }
    }
}
