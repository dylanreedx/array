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
    static let horizontalReadingInset: CGFloat = CGFloat(Inset.card.left)
    private static let blockSpacing = CGFloat(Space.m)

    private(set) var textFields: [RichInlineTextView] = []
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
        rows = Self.rows(for: block)
        textFields = rows.map { row in
            let view = RichInlineTextView(frame: .zero)
            view.apply(runs: row.runs, blockID: row.blockID, context: context, textRole: row.textRole)
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(row.role)
            view.setAccessibilityLabel(view.string)
            if let level = row.headingLevel { view.setAccessibilityValue(level) }
            addSubview(view)
            return view
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

    private func invalidateRowHeights() {
        cachedRowHeights = []
        cachedWidth = -1
    }

    override func layout() {
        super.layout()
        let availableWidth = max(1, bounds.width - Self.horizontalReadingInset * 2)
        if abs(cachedWidth - availableWidth) > 0.5 || cachedRowHeights.count != rows.count {
            cachedRowHeights = rows.map { row in
                Self.qaMeasurementCount += 1
                return RichInlineTextView.measuredHeight(
                    for: row.runs,
                    width: availableWidth,
                    context: renderContext,
                    textRole: row.textRole
                )
            }
            cachedWidth = availableWidth
        }
        var y = bounds.minY
        for (index, pair) in zip(rows, textFields).enumerated() {
            let height = cachedRowHeights[index]
            let frame = NSRect(x: Self.horizontalReadingInset, y: y, width: availableWidth, height: height)
            // An unchanged frame still costs a TextKit glyph-bounds pass, and it
            // re-dirties the view — which is what kept the display cycle spinning.
            if pair.1.frame != frame { pair.1.frame = frame }
            y += height
            if index + 1 < rows.count { y += Self.blockSpacing }
        }
    }

    static func measuredHeight(
        for block: AgentBlock,
        width: CGFloat,
        context: AgentRenderContext
    ) -> CGFloat {
        let rows = rows(for: block)
        guard !rows.isEmpty else { return 0 }
        let availableWidth = max(1, width - horizontalReadingInset * 2)
        let text = rows.reduce(CGFloat.zero) {
            $0 + RichInlineTextView.measuredHeight(
                for: $1.runs,
                width: availableWidth,
                context: context,
                textRole: $1.textRole
            )
        }
        return ceil(text + CGFloat(max(0, rows.count - 1)) * blockSpacing)
    }

    private static func rows(for block: AgentBlock, listDepth: Int = 0, itemNumber: Int? = nil) -> [Row] {
        switch block.payload {
        case let .paragraph(content):
            let prefix = itemPrefix(depth: listDepth, number: itemNumber)
            let runs = prefix.isEmpty ? content : [.text(prefix)] + content
            return [Row(
                blockID: block.id,
                runs: runs,
                role: itemNumber == nil ? .staticText : listItemRole,
                headingLevel: nil,
                textRole: .body
            )] + block.children.flatMap { rows(for: $0, listDepth: listDepth) }
        case let .heading(level, content):
            let clampedLevel = max(1, min(6, Int(level)))
            return [Row(
                blockID: block.id,
                runs: content,
                role: headingRole,
                headingLevel: clampedLevel,
                textRole: .title
            )] + block.children.flatMap { rows(for: $0, listDepth: listDepth) }
        case let .list(payload):
            let start = payload.start ?? 1
            return block.children.enumerated().flatMap { index, child in
                rows(for: child, listDepth: listDepth + 1, itemNumber: payload.ordered ? start + index : 0)
            }
        case .listItem:
            let prefix = itemPrefix(depth: listDepth, number: itemNumber)
            if block.children.isEmpty {
                return [Row(
                    blockID: block.id,
                    runs: [.text(prefix)],
                    role: listItemRole,
                    headingLevel: nil,
                    textRole: .body
                )]
            }
            return block.children.enumerated().flatMap { index, child in
                let childNumber = index == 0 ? itemNumber : nil
                return rows(for: child, listDepth: listDepth, itemNumber: childNumber)
            }
        case .quote:
            return block.children.flatMap { rows(for: $0, listDepth: listDepth) }.map { row in
                Row(
                    blockID: row.blockID,
                    runs: [.text("› ")] + row.runs,
                    role: row.role,
                    headingLevel: row.headingLevel,
                    textRole: row.textRole
                )
            }
        default:
            return block.children.flatMap { rows(for: $0, listDepth: listDepth) }
        }
    }

    private static func itemPrefix(depth: Int, number: Int?) -> String {
        guard let number else { return "" }
        let indentation = String(repeating: "  ", count: max(0, depth - 1))
        return indentation + (number == 0 ? "• " : "\(number). ")
    }
}
