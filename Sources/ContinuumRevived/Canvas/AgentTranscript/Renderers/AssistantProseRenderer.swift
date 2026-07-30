import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Temporary plain-text renderer for the semantic prose families. Rich inline
/// styling is deliberately deferred: this view consumes the owned semantic tree
/// and never parses Markdown or provider text itself.
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
        AssistantProseView.measuredHeight(for: block, width: width)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AssistantProseView else { return }
        view.applyContainerAccessibility(for: block)
    }
}

/// A borderless, fill-less reading surface. Each semantic block gets a native
/// selectable text field; the temporary flattening is replaced by the rich
/// inline renderer without changing the registry or host contract.
@MainActor
final class AssistantProseView: NSView {
    static let horizontalReadingInset: CGFloat = CGFloat(Inset.card.left)
    private static let blockSpacing = CGFloat(Space.m)

    private(set) var textFields: [NSTextField] = []
    private var rows: [Row] = []

    private static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")
    private static let listItemRole = NSAccessibility.Role(rawValue: "AXListItem")

    private struct Row {
        let text: String
        let role: NSAccessibility.Role
        let headingLevel: Int?
        let font: NSFont
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
        textFields.forEach { $0.removeFromSuperview() }
        rows = Self.rows(for: block)
        textFields = rows.map { row in
            let field = NSTextField(wrappingLabelWithString: row.text)
            field.font = row.font
            field.textColor = context.tokens.primaryText.color.nsColor(for: context.appearance)
            field.isSelectable = true
            field.isBordered = false
            field.drawsBackground = false
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.setAccessibilityElement(true)
            field.setAccessibilityRole(row.role)
            field.setAccessibilityLabel(row.text)
            if let level = row.headingLevel { field.setAccessibilityValue(level) }
            addSubview(field)
            return field
        }
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

    override func layout() {
        super.layout()
        let availableWidth = max(1, bounds.width - Self.horizontalReadingInset * 2)
        var y = bounds.minY
        for (index, pair) in zip(rows, textFields).enumerated() {
            let height = Self.textHeight(pair.0.text, font: pair.0.font, width: availableWidth)
            pair.1.preferredMaxLayoutWidth = availableWidth
            pair.1.frame = NSRect(x: Self.horizontalReadingInset, y: y, width: availableWidth, height: height)
            y += height
            if index + 1 < rows.count { y += Self.blockSpacing }
        }
    }

    static func measuredHeight(for block: AgentBlock, width: CGFloat) -> CGFloat {
        let rows = rows(for: block)
        guard !rows.isEmpty else { return 0 }
        let availableWidth = max(1, width - horizontalReadingInset * 2)
        let text = rows.reduce(CGFloat.zero) { $0 + textHeight($1.text, font: $1.font, width: availableWidth) }
        return ceil(text + CGFloat(max(0, rows.count - 1)) * blockSpacing)
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let value = text.isEmpty ? " " : text
        let rect = (value as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(ceil(rect.height), ceil(font.ascender - font.descender + font.leading))
    }

    private static func rows(for block: AgentBlock, listDepth: Int = 0, itemNumber: Int? = nil) -> [Row] {
        let body = NSFont.token(.body)
        switch block.payload {
        case let .paragraph(content):
            let prefix = itemPrefix(depth: listDepth, number: itemNumber)
            return [Row(text: prefix + plainText(content), role: itemNumber == nil ? .staticText : listItemRole,
                        headingLevel: nil, font: body)] + block.children.flatMap { rows(for: $0, listDepth: listDepth) }
        case let .heading(level, content):
            let clampedLevel = max(1, min(6, Int(level)))
            return [Row(text: plainText(content), role: headingRole, headingLevel: clampedLevel, font: .token(.title))]
                + block.children.flatMap { rows(for: $0, listDepth: listDepth) }
        case let .list(payload):
            let start = payload.start ?? 1
            return block.children.enumerated().flatMap { index, child in
                rows(for: child, listDepth: listDepth + 1, itemNumber: payload.ordered ? start + index : 0)
            }
        case .listItem:
            let prefix = itemPrefix(depth: listDepth, number: itemNumber)
            if block.children.isEmpty {
                return [Row(text: prefix, role: listItemRole, headingLevel: nil, font: body)]
            }
            return block.children.enumerated().flatMap { index, child in
                let childNumber = index == 0 ? itemNumber : nil
                return rows(for: child, listDepth: listDepth, itemNumber: childNumber)
            }
        case .quote:
            let children = block.children.flatMap { rows(for: $0, listDepth: listDepth) }
            return children.map { Row(text: "› " + $0.text, role: $0.role, headingLevel: $0.headingLevel, font: $0.font) }
        default:
            return block.children.flatMap { rows(for: $0, listDepth: listDepth) }
        }
    }

    private static func itemPrefix(depth: Int, number: Int?) -> String {
        guard let number else { return "" }
        let indentation = String(repeating: "  ", count: max(0, depth - 1))
        return indentation + (number == 0 ? "• " : "\(number). ")
    }

    private static func plainText(_ content: [AgentInline]) -> String {
        content.map { inline in
            switch inline {
            case let .text(text), let .code(text): return text
            case let .emphasis(children), let .strong(children): return plainText(children)
            case let .link(_, _, children): return plainText(children)
            case .softBreak: return " "
            case .hardBreak: return "\n"
            }
        }.joined()
    }
}
