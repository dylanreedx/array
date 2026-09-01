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
        return AgentPlanView.measuredHeight(payload: payload, width: width, zoom: context.pageZoom)
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

    // Tightened 2026-08-24 alongside the diffstat: a three-step plan cost 40pt
    // of header, 32pt per row and 16pt of bottom inset. A checklist should read
    // as a list, not as a panel.
    static let headerHeight = CGFloat(Space.xxl + Space.xs)
    static let rowBaseHeight = CGFloat(Space.xl + Space.s)
    static let horizontalInset = CGFloat(Space.l)
    static let bottomInset = CGFloat(Space.s)
    static let maximumRows = 100

    // WS5: the same four metrics at a tile's page zoom. The zero-argument
    // properties above keep their shipped 100% values so nothing outside this
    // renderer has to change; every path in here reads the companions.
    static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.xs)) }
    static func rowBaseHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xl + Space.s)) }
    static func horizontalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    static func bottomInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.s)) }

    /// The page zoom of the last `apply`. Every metric below reads it, so a
    /// recycled plan re-derives rather than keeping the zoom it was built at.
    private var zoom: AgentPageZoom { context.pageZoom }

    private(set) var titleLabel = NSTextField(labelWithString: "Plan")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var rows: [Row] = []
    private(set) var rowViews: [NSView] = []
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var payloadStatus: AgentItemStatus = .pending

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // These three are the 100% values a freshly built view starts with;
        // `applyZoomedMetrics()` re-assigns all of them on every `apply`,
        // because this view is RECYCLED and may be handed a row at another rung.
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true
        // Same call as the diffstat: the steps are the subject, the word
        // "Plan" is a label.
        titleLabel.font = NSFont.token(.label)
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
        applyZoomedMetrics()
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

    /// Every metric this view assigns at construction time, re-derived from the
    /// context's page zoom. Called from `apply`, never from `init`, so a reused
    /// view can never keep the rung it was born with.
    private func applyZoomedMetrics() {
        let zoom = self.zoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        titleLabel.font = NSFont.token(.label, zoom: zoom)
        statusLabel.font = NSFont.token(.caption, zoom: zoom)
    }

    func applyAccessibility(payload: AgentPlanPayload) {
        let status = payload.status.agentToolStatusPresentation.label
        setAccessibilityLabel("Plan, \(Self.safeSingleLine(payload.title, fallback: "Plan")), \(status)")
        setAccessibilityChildren([titleLabel, statusLabel] + rowViews)
    }

    override func layout() {
        super.layout()
        let zoom = self.zoom
        let inset = Self.horizontalInset(zoom: zoom)
        let headerHeight = Self.headerHeight(zoom: zoom)
        let statusWidth = min(ceil(statusLabel.intrinsicContentSize.width) + CGFloat(zoom.scaled(Space.s)), max(0, bounds.width * 0.40))
        statusLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - statusWidth),
            y: (headerHeight - statusLabel.intrinsicContentSize.height) / 2,
            width: statusWidth,
            height: statusLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: (headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, statusLabel.frame.minX - inset - CGFloat(zoom.scaled(Space.m))),
            height: titleLabel.intrinsicContentSize.height
        )
        var y = headerHeight
        for (index, rowView) in rowViews.enumerated() {
            let height = Self.rowHeight(for: rows[index], width: bounds.width, zoom: zoom)
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

    static func measuredHeight(
        payload: AgentPlanPayload, width: CGFloat, zoom: AgentPageZoom = .default
    ) -> CGFloat {
        headerHeight(zoom: zoom)
            + flatten(payload.steps).reduce(0) { $0 + rowHeight(for: $1, width: width, zoom: zoom) }
            + bottomInset(zoom: zoom)
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
            let container = AgentPlanRowView(frame: .zero)
            let status = row.step.status.agentToolStatusPresentation
            let title = NSTextField(labelWithString: "\(row.ordinal)  \(status.glyph) \(Self.safeSingleLine(row.step.title, fallback: "Step"))")
            title.font = NSFont.token(.label, zoom: zoom)
            title.lineBreakMode = .byTruncatingTail
            title.setAccessibilityLabel("Step \(row.ordinal), \(Self.safeSingleLine(row.step.title, fallback: "Step")), \(status.label)")
            container.addSubview(title)
            if row.step.status != .completed,
               let detail = Self.safeDetail(row.step.detail), !detail.isEmpty {
                let detailLabel = NSTextField(wrappingLabelWithString: detail)
                detailLabel.font = NSFont.token(.caption, zoom: zoom)
                detailLabel.maximumNumberOfLines = 2
                detailLabel.lineBreakMode = .byWordWrapping
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
        let zoom = self.zoom
        let indent = min(CGFloat(row.depth), 5) * CGFloat(zoom.scaled(Space.l))
        let width = max(1, rowView.bounds.width - indent)
        guard let title = rowView.subviews.first as? NSTextField else { return }
        title.frame = NSRect(x: indent, y: CGFloat(zoom.scaled(Space.xs)), width: width, height: title.intrinsicContentSize.height)
        if rowView.subviews.count > 1, let detail = rowView.subviews[1] as? NSTextField {
            detail.frame = NSRect(
                x: indent + CGFloat(zoom.scaled(Space.xxl)), y: title.frame.maxY + CGFloat(zoom.scaled(Space.xs)),
                width: max(1, width - CGFloat(zoom.scaled(Space.xxl))),
                height: max(0, rowView.bounds.height - title.frame.maxY - CGFloat(zoom.scaled(Space.s)))
            )
        }
    }

    private static func rowHeight(
        for row: Row, width: CGFloat, zoom: AgentPageZoom = .default
    ) -> CGFloat {
        guard row.step.status != .completed,
              let detail = safeDetail(row.step.detail), !detail.isEmpty else { return rowBaseHeight(zoom: zoom) }
        let indent = min(CGFloat(row.depth), 5) * CGFloat(zoom.scaled(Space.l))
        let available = max(1, width - horizontalInset(zoom: zoom) * 2 - indent - CGFloat(zoom.scaled(Space.xxl)))
        let rect = (detail as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.caption, zoom: zoom)]
        )
        return rowBaseHeight(zoom: zoom) + min(ceil(rect.height), CGFloat(zoom.lineHeight(for: .caption) * 2))
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

@MainActor
private final class AgentPlanRowView: NSView {
    override var isFlipped: Bool { true }
}
