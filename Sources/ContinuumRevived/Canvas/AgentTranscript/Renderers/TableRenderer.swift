import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// `.plans/45` T8 — a Markdown table laid out as columns.
///
/// Until this landed, `MarkdownAgentMarkupParser` mapped every GFM table to
/// `.fencedCode` and stored the raw pipe source, so the most common piece of
/// structure in an assistant reply arrived as a monospace blob. The parser now
/// keeps the cells; this lays them out.
///
/// **One text view, laid out as an `NSTextTable` — not a view per cell, not
/// hand-drawn, and no longer tab stops.**
/// The first implementation drew every cell into the host's `draw(_:)`. That
/// avoided `performance.md` trap 1 (a 3×20 table would otherwise be 60 TextKit
/// stacks in one row) but broke `_DESIGN.md` §2.5, which is a locked ruling:
/// *"NSTextView, text layout, IME, undo, selection, accessibility, and
/// pasteboard behavior are retained."* Drawn cells cannot be selected, are
/// invisible to VoiceOver, and vanished from the Markdown tile's rendered text —
/// caught by `--file-markdown-preview-check`, which asserts that even an
/// unsupported construct still shows its content as readable text.
///
/// The first reconciliation was `NSTextTab`, and it is why tables drifted: a
/// tab stop is a position on a LINE, not a column, so any cell wider than its
/// slot pushed the rest of its row to the next stop ("part 1" + "15" read as
/// "part 115"), an empty cell's tab landed wherever the previous text ended,
/// nothing could wrap inside a cell, and the stops were solved against a width
/// of zero whenever `apply` ran before the first layout. `NSTextTable` is a real
/// grid inside the same single text view: every cell is a paragraph pinned to
/// its row and column, with its own width, padding, alignment and borders, and
/// it wraps inside its column. Witness: `--transcript-rhythm-check` (grid).
@MainActor
final class TableRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .table

    func makeView() -> NSView { AgentTableView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentTableView,
              case let .table(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .table(payload) = block.payload else { return 0 }
        return AgentTableView.measuredHeight(for: payload, width: width, context: context)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard case let .table(payload) = block.payload else { return }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.table)
        view.setAccessibilityLabel(
            "Table, \(payload.columnCount) column(s), \(payload.rows.count) row(s)")
    }
}

@MainActor
final class AgentTableView: NSView, TokenThemed {
    /// A column's NATURAL width never exceeds this; past it, the column wraps.
    /// This also keeps a wide cell from becoming the single enormous unbounded
    /// measurement `performance.md` names as a known-slow case.
    static func maximumNaturalColumnWidth(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(220))
    }
    static func minimumColumnWidth(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(40))
    }
    /// The space between two columns' text, split across their facing padding.
    static func gutter(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    private static func rowPadding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xs)) }

    private let textView = RichInlineTextView(frame: .zero)
    private var payload = AgentTablePayload()
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var blockID: AgentNodeID?
    /// The width-independent half of the table, built once per `apply`: styled
    /// cells, their natural widths and each column's alignment.
    private var prepared: Prepared?
    /// The width the current string was laid out for. A layout pass at the same
    /// width does nothing; a new width re-distributes the columns, which is
    /// arithmetic over `prepared` — no text is measured again.
    private var composedWidth: CGFloat?
    private var cellRanges: [(row: Int, column: Int, range: NSRange)] = []

    /// QA: how many times cell text was measured / a grid was composed.
    private(set) static var qaNaturalWidthSolves = 0
    private(set) var qaComposeCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // No fill: a table is prose structure, not an artifact card. Resting
        // paints nil, never .clear (CLAUDE.md hazard 8). Its separators are
        // table-cell borders drawn by TextKit, in the line-role tokens.
        layer?.backgroundColor = nil
        textView.stringPasteboardStyle = .plainText
        textView.plainTextForSelection = { [weak self] range in self?.tabSeparatedText(in: range) }
        textView.markdownForSelection = { [weak self] range in self?.markdownText(in: range) }
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentTablePayload, context: AgentRenderContext) {
        self.payload = payload
        self.context = context
        self.blockID = blockID
        prepared = Self.prepare(payload, context: context)
        composedWidth = nil
        identifier = NSUserInterfaceItemIdentifier("agent.table.\(blockID.rawValue)")
        if bounds.width > 0 { composeIfNeeded() }
        needsLayout = true
    }

    func applyTokens() {
        // Border colours are resolved into the composed string, so a theme change
        // re-composes (no text is measured).
        composedWidth = nil
        if bounds.width > 0 { composeIfNeeded() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    // MARK: - Composition

    struct Prepared {
        let columnCount: Int
        /// Row 0 is the header when there is one.
        let rows: [[NSAttributedString]]
        let hasHeader: Bool
        let natural: [CGFloat]
        let alignments: [NSTextAlignment]
    }

    /// Everything that does not depend on the width: one text measurement per
    /// cell, here and nowhere else.
    static func prepare(_ payload: AgentTablePayload, context: AgentRenderContext) -> Prepared? {
        let columnCount = payload.columnCount
        guard columnCount > 0 else { return nil }
        qaNaturalWidthSolves += 1
        let zoom = context.pageZoom
        func cell(_ inlines: [AgentInline], bold: Bool) -> NSAttributedString {
            AgentTextStyleResolver.attributedString(
                for: inlines, theme: context.appearance, tokens: context.tokens,
                textRole: .body, style: AgentProseTextStyle(bold: bold), zoom: zoom)
        }
        var rows: [[NSAttributedString]] = []
        if !payload.header.isEmpty { rows.append(payload.header.map { cell($0, bold: true) }) }
        rows += payload.rows.map { $0.map { cell($0, bold: false) } }
        let cap = maximumNaturalColumnWidth(zoom: zoom)
        var natural = [CGFloat](repeating: minimumColumnWidth(zoom: zoom), count: columnCount)
        for row in rows {
            for (index, text) in row.enumerated() where index < columnCount {
                natural[index] = max(natural[index], min(ceil(text.size().width) + 1, cap))
            }
        }
        let alignments = (0..<columnCount).map { column -> NSTextAlignment in
            switch payload.effectiveAlignment(forColumn: column) {
            case .leading: return .left
            case .center: return .center
            case .trailing: return .right
            }
        }
        return Prepared(columnCount: columnCount, rows: rows, hasHeader: !payload.header.isEmpty,
                        natural: natural, alignments: alignments)
    }

    /// Column CONTENT widths for `width`. A table that fits keeps its natural
    /// widths; one that does not gives every column its natural width up to an
    /// equal share and splits what is left among the wider ones, so narrow
    /// columns never wrap to feed a long one and the whole table always fits.
    static func columnWidths(_ prepared: Prepared, width: CGFloat, zoom: AgentPageZoom) -> [CGFloat] {
        let count = prepared.columnCount
        let gutters = gutter(zoom: zoom) * CGFloat(max(0, count - 1))
        let available = max(CGFloat(count), floor(width - gutters))
        guard prepared.natural.reduce(0, +) > available else { return prepared.natural }
        var widths = [CGFloat](repeating: 0, count: count)
        var open = Set(0..<count)
        var remaining = available
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let fitting = open.filter { prepared.natural[$0] <= share }
            if fitting.isEmpty {
                for column in open { widths[column] = floor(share) }
                break
            }
            for column in fitting {
                widths[column] = prepared.natural[column]
                remaining -= prepared.natural[column]
                open.remove(column)
            }
        }
        return widths
    }

    /// The grid as one attributed string for `width`: one `NSTextTableBlock` per
    /// cell — empty cells included, so a blank never moves its row's later
    /// columns — with the gutter as facing padding, the header bold above a
    /// separator, and a hairline between body rows.
    static func compose(
        _ prepared: Prepared, width: CGFloat, context: AgentRenderContext
    ) -> (string: NSAttributedString, cells: [(row: Int, column: Int, range: NSRange)]) {
        let zoom = context.pageZoom
        let widths = columnWidths(prepared, width: width, zoom: zoom)
        let halfGutter = gutter(zoom: zoom) / 2
        let rowPadding = rowPadding(zoom: zoom)
        let table = NSTextTable()
        table.numberOfColumns = prepared.columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let theme = context.appearance
        let headerRule = AgentLineRole.controlBoundary.color.nsColor(for: theme)
        let rowRule = AgentLineRole.decorativeHairline.color.nsColor(for: theme)
        let emptyFont = NSFont.token(.body, zoom: zoom)
        let output = NSMutableAttributedString()
        var cells: [(row: Int, column: Int, range: NSRange)] = []
        let lastRow = prepared.rows.count - 1
        for (rowIndex, row) in prepared.rows.enumerated() {
            let isHeader = prepared.hasHeader && rowIndex == 0
            for column in 0..<prepared.columnCount {
                let block = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1,
                    startingColumn: column, columnSpan: 1)
                // Content width is the column; padding is the gutter, except at
                // the table's outer edges, which sit on the prose column.
                block.setContentWidth(widths[column], type: .absoluteValueType)
                block.setWidth(column == 0 ? 0 : halfGutter, type: .absoluteValueType,
                               for: .padding, edge: .minX)
                block.setWidth(column == prepared.columnCount - 1 ? 0 : halfGutter,
                               type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(rowPadding, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(rowPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.verticalAlignment = .topAlignment
                if isHeader {
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    block.setBorderColor(headerRule, for: .maxY)
                } else if rowIndex < lastRow {
                    block.setWidth(CGFloat(LineWidth.hairline), type: .absoluteValueType,
                                   for: .border, edge: .maxY)
                    block.setBorderColor(rowRule, for: .maxY)
                }
                let start = output.length
                let text = column < row.count ? row[column] : NSAttributedString()
                let cellText = NSMutableAttributedString(attributedString: text)
                let contentLength = cellText.length
                cellText.append(NSAttributedString(
                    string: "\n",
                    attributes: contentLength > 0
                        ? cellText.attributes(at: contentLength - 1, effectiveRange: nil)
                        : [.font: emptyFont]))
                let base = (contentLength > 0
                    ? cellText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                    : nil)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                base.textBlocks = [block]
                base.alignment = prepared.alignments[column]
                base.paragraphSpacing = 0
                base.paragraphSpacingBefore = 0
                base.headIndent = 0
                base.firstLineHeadIndent = 0
                base.tailIndent = 0
                base.lineBreakMode = .byWordWrapping
                cellText.addAttribute(.paragraphStyle, value: base,
                                      range: NSRange(location: 0, length: cellText.length))
                output.append(cellText)
                cells.append((rowIndex, column, NSRange(location: start, length: contentLength)))
            }
        }
        return (output, cells)
    }

    static func measuredHeight(
        for payload: AgentTablePayload, width: CGFloat, context: AgentRenderContext
    ) -> CGFloat {
        guard let prepared = prepare(payload, context: context) else { return 0 }
        let composed = compose(prepared, width: width, context: context)
        // The same TextKit 1 stack the view paints with: a text table is a
        // layout-manager feature, and `boundingRect` does not lay one out.
        let storage = NSTextStorage(attributedString: composed.string)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.usesFontLeading = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    private func composeIfNeeded() {
        guard let prepared, let blockID, bounds.width > 0, composedWidth != bounds.width else { return }
        composedWidth = bounds.width
        qaComposeCount += 1
        let composed = Self.compose(prepared, width: bounds.width, context: context)
        cellRanges = composed.cells
        textView.applyAttributed(composed.string, blockID: blockID, context: context)
    }

    override func layout() {
        super.layout()
        // No text measurement here. Natural widths come from `apply`; the height
        // came from `measure(...)`. A width CHANGE re-distributes the columns —
        // arithmetic — and a pass at the same width does nothing at all
        // (`performance.md` traps 2 and 3).
        let frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        if textView.frame != frame { textView.frame = frame }
        composeIfNeeded()
    }

    // MARK: - Copy

    /// A selection inside the table copies as TSV: the selected part of each
    /// touched cell, tab-separated, one line per row. Pasting into a sheet keeps
    /// the columns; the grid's own paragraph breaks never leak in.
    func tabSeparatedText(in selection: NSRange) -> String {
        guard let storage = textView.textStorage else { return "" }
        let string = storage.string as NSString
        var lines: [String] = []
        var line: [String] = []
        var currentRow: Int?
        for cell in cellRanges {
            let cellSpan = NSRange(location: cell.range.location, length: cell.range.length + 1)
            guard NSIntersectionRange(cellSpan, selection).length > 0
                    || (cell.range.length == 0 && NSLocationInRange(cell.range.location, selection))
            else { continue }
            if currentRow != cell.row {
                if currentRow != nil { lines.append(line.joined(separator: "\t")) }
                line = []
                currentRow = cell.row
            }
            let clipped = NSIntersectionRange(cell.range, selection)
            line.append(clipped.length > 0 ? string.substring(with: clipped) : "")
        }
        if currentRow != nil { lines.append(line.joined(separator: "\t")) }
        return lines.joined(separator: "\n")
    }

    /// The whole table copies as its original Markdown; a part of it as TSV.
    func markdownText(in selection: NSRange) -> String {
        let length = textView.textStorage?.length ?? 0
        if selection.location == 0, selection.length >= max(0, length - 1), !payload.source.isEmpty {
            return payload.source
        }
        return tabSeparatedText(in: selection)
    }

    // MARK: - QA

    struct CellGeometryForQA {
        let row: Int
        let column: Int
        let text: String
        /// The laid-out glyphs of this cell, in this view's coordinates; nil for
        /// an empty cell.
        let frame: NSRect?
        let isBold: Bool
    }

    var qaHasHeader: Bool { !payload.header.isEmpty }
    var qaPayload: AgentTablePayload { payload }
    var qaFullTextLength: Int { textView.textStorage?.length ?? 0 }

    /// Every cell, read off the text view's REAL layout manager.
    var qaCellGeometry: [CellGeometryForQA] {
        layoutSubtreeIfNeeded()
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { return [] }
        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        return cellRanges.map { cell in
            let text = (storage.string as NSString).substring(with: cell.range)
            var frame: NSRect?
            if cell.range.length > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let glyphs = layoutManager.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                frame = textView.convert(rect.offsetBy(dx: origin.x, dy: origin.y), to: self)
            }
            let font = cell.range.length > 0
                ? storage.attribute(.font, at: cell.range.location, effectiveRange: nil) as? NSFont : nil
            return CellGeometryForQA(row: cell.row, column: cell.column, text: text, frame: frame,
                                     isBold: font.map(Self.isBold) ?? false)
        }
    }

    private static func isBold(_ font: NSFont) -> Bool {
        if NSFontManager.shared.traits(of: font).contains(.boldFontMask) { return true }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return ((traits?[.weight] as? CGFloat) ?? 0) >= NSFont.Weight.semibold.rawValue
    }

    /// Whether the header cells carry the separator border TextKit draws.
    var qaHeaderSeparatorDrawn: Bool {
        guard qaHasHeader, let storage = textView.textStorage,
              let first = cellRanges.first(where: { $0.row == 0 }) else { return false }
        let style = storage.attribute(.paragraphStyle, at: first.range.location, effectiveRange: nil)
            as? NSParagraphStyle
        guard let block = style?.textBlocks.first else { return false }
        return block.width(for: .border, edge: .maxY) > 0 && block.borderColor(for: .maxY) != nil
    }
}

