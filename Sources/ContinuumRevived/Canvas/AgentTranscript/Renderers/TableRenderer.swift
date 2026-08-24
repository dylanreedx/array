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
/// **One text view, with tab stops — not a view per cell, and not hand-drawn.**
/// The first implementation drew every cell into the host's `draw(_:)`. That
/// avoided `performance.md` trap 1 (a 3×20 table would otherwise be 60 TextKit
/// stacks in one row) but broke `_DESIGN.md` §2.5, which is a locked ruling:
/// *"NSTextView, text layout, IME, undo, selection, accessibility, and
/// pasteboard behavior are retained."* Drawn cells cannot be selected, are
/// invisible to VoiceOver, and vanished from the Markdown tile's rendered text —
/// caught by `--file-markdown-preview-check`, which asserts that even an
/// unsupported construct still shows its content as readable text.
///
/// `NSTextTab` is what reconciles the two: column alignment is a paragraph
/// feature TextKit already has, so one native text view gives columns, real
/// selection, real accessibility and one view.
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
    /// A cell never claims more than this in the column solve; beyond it the
    /// column stops growing. This is what keeps a wide table from becoming the
    /// single enormous unbounded measurement `performance.md` names as a
    /// known-slow case.
    static let maximumNaturalColumnWidth: CGFloat = 220
    static let minimumColumnWidth: CGFloat = 40
    private static let columnGap = CGFloat(Space.l)
    private static let headerRuleInset = CGFloat(Space.s)

    private let textView = RichInlineTextView(frame: .zero)
    private let headerRule = CALayer()
    private var payload = AgentTablePayload()
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var headerLineHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // No fill: a table is prose structure, not an artifact card. Resting
        // paints nil, never .clear (CLAUDE.md hazard 8).
        layer?.backgroundColor = nil
        textView.stringPasteboardStyle = .plainText
        addSubview(textView)
        layer?.addSublayer(headerRule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentTablePayload, context: AgentRenderContext) {
        self.payload = payload
        self.context = context
        let composed = Self.compose(payload, context: context, width: bounds.width)
        headerLineHeight = composed.headerHeight
        textView.applyAttributed(composed.string, blockID: blockID, context: context)
        identifier = NSUserInterfaceItemIdentifier("agent.table.\(blockID.rawValue)")
        applyTokens()
        needsLayout = true
    }

    func applyTokens() {
        headerRule.backgroundColor = payload.header.isEmpty
            ? nil
            : AgentLineRole.decorativeHairline.color.cgColor(for: context.appearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    // MARK: - Composition

    /// Solves column widths from bounded content and emits one tab-stopped
    /// attributed string. Pure, so `measure(...)` and `layout()` cannot disagree.
    private static func compose(
        _ payload: AgentTablePayload, context: AgentRenderContext, width: CGFloat
    ) -> (string: NSAttributedString, headerHeight: CGFloat) {
        let columnCount = payload.columnCount
        guard columnCount > 0 else { return (NSAttributedString(string: ""), 0) }

        func cell(_ inlines: [AgentInline], bold: Bool) -> NSAttributedString {
            AgentTextStyleResolver.attributedString(
                for: inlines, theme: context.appearance, tokens: context.tokens,
                textRole: .body, style: AgentProseTextStyle(bold: bold))
        }
        let header = payload.header.map { cell($0, bold: true) }
        let rows = payload.rows.map { row in row.map { cell($0, bold: false) } }

        // Natural widths, each cell capped so one long cell cannot drag the solve
        // out to an unbounded measurement.
        var natural = [CGFloat](repeating: minimumColumnWidth, count: columnCount)
        func consider(_ row: [NSAttributedString]) {
            for (index, text) in row.enumerated() where index < columnCount {
                natural[index] = max(
                    natural[index],
                    min(ceil(text.size().width), maximumNaturalColumnWidth))
            }
        }
        consider(header)
        rows.forEach(consider)

        // Fit: shrink proportionally rather than dropping columns, so nothing is
        // silently truncated.
        let available = max(minimumColumnWidth, width)
        let total = natural.reduce(0, +) + columnGap * CGFloat(max(0, columnCount - 1))
        var widths = natural
        if total > available, total > 0 {
            let scale = max(0.2, (available - columnGap * CGFloat(max(0, columnCount - 1))) / natural.reduce(0, +))
            widths = natural.map { max(minimumColumnWidth, floor($0 * scale)) }
        }

        // One tab stop per column boundary. Numeric columns get a RIGHT stop, so
        // "84" and "9" line up on their units digit exactly the way the source
        // Markdown's `---:` asked for.
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for index in 0..<columnCount {
            x += widths[index]
            let alignment: NSTextAlignment
            switch payload.alignment(forColumn: index) {
            case .leading: alignment = .left
            case .center: alignment = .center
            case .trailing: alignment = .right
            }
            // A left-aligned column's stop marks where the NEXT column starts; a
            // right/centre stop marks this column's own edge.
            let location = alignment == .left ? x + columnGap : x
            stops.append(NSTextTab(textAlignment: alignment, location: location))
            if alignment != .left { x += columnGap }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = stops
        paragraph.defaultTabInterval = widths.first ?? minimumColumnWidth
        paragraph.lineBreakMode = .byTruncatingTail

        let output = NSMutableAttributedString()
        func append(_ row: [NSAttributedString], last: Bool) {
            for index in 0..<columnCount {
                if index > 0 { output.append(NSAttributedString(string: "\t")) }
                if index < row.count { output.append(row[index]) }
            }
            if !last { output.append(NSAttributedString(string: "\n")) }
        }
        var headerHeight: CGFloat = 0
        if !header.isEmpty {
            append(header, last: rows.isEmpty)
            headerHeight = ceil(header.map { $0.size().height }.max() ?? 0)
        }
        for (index, row) in rows.enumerated() {
            append(row, last: index == rows.count - 1)
        }
        output.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: output.length))
        return (output, headerHeight)
    }

    static func measuredHeight(
        for payload: AgentTablePayload, width: CGFloat, context: AgentRenderContext
    ) -> CGFloat {
        let composed = compose(payload, context: context, width: width)
        return RichInlineTextView.measuredHeight(for: composed.string, width: width)
            + (payload.header.isEmpty ? 0 : headerRuleInset * 2)
    }

    override func layout() {
        super.layout()
        // No measurement here: the composed string is built in `apply`, and the
        // height came from `measure(...)`. `performance.md` traps 2 and 3.
        let frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        if textView.frame != frame { textView.frame = frame }
        let ruleFrame = NSRect(
            x: 0, y: headerLineHeight + Self.headerRuleInset,
            width: bounds.width,
            height: max(CGFloat(LineWidth.hairline), 1.0 / (window?.backingScaleFactor ?? 2)))
        if headerRule.frame != ruleFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            headerRule.frame = ruleFrame
            CATransaction.commit()
        }
    }
}
