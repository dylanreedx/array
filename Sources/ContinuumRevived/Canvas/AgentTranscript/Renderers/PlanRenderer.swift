import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Read-only presentation of explicit provider-owned plan progress. This
/// renderer never derives steps from prose, tool activity, or elapsed time.
@MainActor
final class PlanRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .plan

    func makeView() -> NSView { AgentPlanView() }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentPlanView, case let .plan(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .plan(payload) = block.payload else { return 0 }
        return AgentPlanView.measuredHeight(payload: payload, width: width)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentPlanView, case let .plan(payload) = block.payload else { return }
        view.applyAccessibility(payload: payload)
    }
}

@MainActor
final class AgentPlanView: NSView {
    struct Row {
        var ordinal: String
        var depth: Int
        var step: AgentPlanStep
    }

    static let headerHeight = CGFloat(Space.xxl + Space.l)
    static let rowBaseHeight = CGFloat(Space.xxl + Space.s)
    static let horizontalInset = CGFloat(Space.l)
    static let bottomInset = CGFloat(Space.l)
    static let maximumRows = 100

    private(set) var titleLabel = NSTextField(labelWithString: "Plan")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var rows: [Row] = []
    private(set) var rowViews: [NSView] = []
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var payloadStatus: AgentItemStatus = .pending

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        titleLabel.font = NSFont.token(.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(statusLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentPlanPayload, context: AgentRenderContext) {
        self.context = context
        payloadStatus = payload.status
        titleLabel.stringValue = Self.safeSingleLine(payload.title, fallback: "Plan")
        let status = payload.status.agentToolStatusPresentation
        statusLabel.stringValue = "\(status.glyph) \(status.label)"
        rows = Self.flatten(payload.steps)
        rebuildRows()
        identifier = NSUserInterfaceItemIdentifier("agent.plan.\(blockID.rawValue)")
        applyAccessibility(payload: payload)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(payload: AgentPlanPayload) {
        let status = payload.status.agentToolStatusPresentation.label
        setAccessibilityLabel("Plan, \(Self.safeSingleLine(payload.title, fallback: "Plan")), \(status)")
        setAccessibilityChildren([titleLabel, statusLabel] + rowViews)
    }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let statusWidth = min(statusLabel.intrinsicContentSize.width, max(0, bounds.width * 0.34))
        statusLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - statusWidth),
            y: (Self.headerHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth,
            height: statusLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: (Self.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - inset - CGFloat(Space.m)),
            height: titleLabel.intrinsicContentSize.height
        )
        var y = Self.headerHeight
        for (index, rowView) in rowViews.enumerated() {
            let height = Self.rowHeight(for: rows[index], width: bounds.width)
            rowView.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: height)
            layoutRow(rowView, row: rows[index])
            y += height
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: theme)
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = payloadStatus == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        for rowView in rowViews {
            guard let title = rowView.subviews.first as? NSTextField else { continue }
            title.textColor = context.tokens.primaryText.color.nsColor(for: theme)
            (rowView.subviews.dropFirst().first as? NSTextField)?.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        }
    }

    static func measuredHeight(payload: AgentPlanPayload, width: CGFloat) -> CGFloat {
        headerHeight + flatten(payload.steps).reduce(0) { $0 + rowHeight(for: $1, width: width) } + bottomInset
    }

    static func flatten(_ steps: [AgentPlanStep]) -> [Row] {
        var result: [Row] = []
        var pending: [(AgentPlanStep, String, Int)] = []
        for (index, step) in steps.enumerated().reversed() {
            pending.append((step, String(index + 1), 0))
        }
        while let (step, ordinal, depth) = pending.popLast(), result.count < maximumRows {
            result.append(Row(ordinal: ordinal, depth: depth, step: step))
            for (index, child) in step.children.enumerated().reversed() {
                pending.append((child, "\(ordinal).\(index + 1)", depth + 1))
            }
        }
        return result
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.map { row in
            let container = NSView(frame: .zero)
            let status = row.step.status.agentToolStatusPresentation
            let title = NSTextField(labelWithString: "\(row.ordinal)  \(status.glyph) \(Self.safeSingleLine(row.step.title, fallback: "Step"))")
            title.font = NSFont.token(.label)
            title.lineBreakMode = .byTruncatingTail
            title.setAccessibilityLabel("Step \(row.ordinal), \(Self.safeSingleLine(row.step.title, fallback: "Step")), \(status.label)")
            container.addSubview(title)
            if row.step.status != .completed,
               let detail = Self.safeDetail(row.step.detail), !detail.isEmpty {
                let detailLabel = NSTextField(wrappingLabelWithString: detail)
                detailLabel.font = NSFont.token(.caption)
                detailLabel.maximumNumberOfLines = 2
                detailLabel.lineBreakMode = .byTruncatingTail
                detailLabel.isSelectable = true
                container.addSubview(detailLabel)
            }
            container.setAccessibilityElement(true)
            container.setAccessibilityRole(.group)
            container.setAccessibilityChildren(container.subviews)
            addSubview(container)
            return container
        }
    }

    private func layoutRow(_ rowView: NSView, row: Row) {
        let indent = min(CGFloat(row.depth), 5) * CGFloat(Space.l)
        let width = max(1, rowView.bounds.width - indent)
        guard let title = rowView.subviews.first as? NSTextField else { return }
        title.frame = NSRect(x: indent, y: CGFloat(Space.xs), width: width, height: title.intrinsicContentSize.height)
        if rowView.subviews.count > 1, let detail = rowView.subviews[1] as? NSTextField {
            detail.frame = NSRect(
                x: indent + CGFloat(Space.xxl), y: title.frame.maxY + CGFloat(Space.xs),
                width: max(1, width - CGFloat(Space.xxl)),
                height: max(0, rowView.bounds.height - title.frame.maxY - CGFloat(Space.s))
            )
        }
    }

    private static func rowHeight(for row: Row, width: CGFloat) -> CGFloat {
        guard row.step.status != .completed,
              let detail = safeDetail(row.step.detail), !detail.isEmpty else { return rowBaseHeight }
        let indent = min(CGFloat(row.depth), 5) * CGFloat(Space.l)
        let available = max(1, width - horizontalInset * 2 - indent - CGFloat(Space.xxl))
        let rect = (detail as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.caption)]
        )
        return rowBaseHeight + min(ceil(rect.height), CGFloat(Metrics.lineHeight(for: .caption) * 2))
    }

    private static func safeSingleLine(_ value: String?, fallback: String) -> String {
        let line = value?
            .split(whereSeparator: { $0.isNewline }).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? fallback : line
    }

    private static func safeDetail(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
