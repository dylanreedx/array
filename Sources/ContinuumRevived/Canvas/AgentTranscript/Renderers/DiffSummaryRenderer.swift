import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Bounded semantic summary of provider-supplied change metadata. Raw unified
/// diff text is deliberately neither parsed nor displayed here.
@MainActor
final class DiffSummaryRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .diff

    func makeView() -> NSView { AgentDiffSummaryView() }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentDiffSummaryView, case let .diff(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .diff(payload) = block.payload else { return 0 }
        return AgentDiffSummaryView.measuredHeight(payload: payload, width: width)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentDiffSummaryView, case let .diff(payload) = block.payload else { return }
        view.applyAccessibility(payload: payload)
    }
}

@MainActor
final class AgentDiffSummaryView: NSView {
    static let headerHeight = CGFloat(Space.xxl + Space.l)
    static let fileRowHeight = CGFloat(Space.xxl + Space.xs)
    static let actionHeight = CGFloat(Space.xxl)
    static let horizontalInset = CGFloat(Space.l)
    static let bottomInset = CGFloat(Space.l)
    static let maximumVisibleFiles = 8

    private(set) var titleLabel = NSTextField(labelWithString: "Changes")
    private(set) var countsLabel = NSTextField(labelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var fileLabels: [NSTextField] = []
    private(set) var overflowLabel = NSTextField(labelWithString: "")
    private(set) var openReviewButton = AgentOpenReviewButton(frame: .zero)
    private(set) var displayedFiles: [AgentDiffFileSummary] = []

    private var blockID: AgentNodeID?
    private var payload = AgentDiffPayload(text: "")
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true

        titleLabel.font = NSFont.token(.title)
        countsLabel.font = NSFont.token(.caption)
        countsLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = NSFont.token(.body)
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isSelectable = true
        overflowLabel.font = NSFont.token(.caption)
        openReviewButton.target = self
        openReviewButton.action = #selector(openReview(_:))

        addSubview(titleLabel)
        addSubview(countsLabel)
        addSubview(summaryLabel)
        addSubview(overflowLabel)
        addSubview(openReviewButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentDiffPayload, context: AgentRenderContext) {
        self.blockID = blockID
        self.payload = payload
        self.context = context
        displayedFiles = Array(payload.files.prefix(Self.maximumVisibleFiles))
        titleLabel.stringValue = "Changes"
        countsLabel.stringValue = Self.countsText(payload.files)
        summaryLabel.stringValue = Self.safeSummary(payload.summary)
        summaryLabel.isHidden = summaryLabel.stringValue.isEmpty
        rebuildFileLabels()
        let overflow = payload.files.count - displayedFiles.count
        overflowLabel.stringValue = overflow > 0 ? "+\(overflow) more files" : ""
        overflowLabel.isHidden = overflow == 0
        openReviewButton.isHidden = !payload.canOpenReview
        identifier = NSUserInterfaceItemIdentifier("agent.diff.\(blockID.rawValue)")
        applyAccessibility(payload: payload)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(payload: AgentDiffPayload) {
        setAccessibilityLabel("File changes, \(Self.countsText(payload.files))")
        var children: [NSView] = [titleLabel, countsLabel]
        if !summaryLabel.isHidden { children.append(summaryLabel) }
        children.append(contentsOf: fileLabels)
        if !overflowLabel.isHidden { children.append(overflowLabel) }
        if !openReviewButton.isHidden { children.append(openReviewButton) }
        setAccessibilityChildren(children)
    }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let countsWidth = min(countsLabel.intrinsicContentSize.width, max(0, bounds.width * 0.46))
        countsLabel.frame = NSRect(
            x: max(inset, bounds.width - inset - countsWidth),
            y: (Self.headerHeight - countsLabel.intrinsicContentSize.height) / 2,
            width: countsWidth,
            height: countsLabel.intrinsicContentSize.height
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: (Self.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, countsLabel.frame.minX - inset - CGFloat(Space.m)),
            height: titleLabel.intrinsicContentSize.height
        )
        var y = Self.headerHeight
        if !summaryLabel.isHidden {
            let height = Self.summaryHeight(payload.summary, width: bounds.width)
            summaryLabel.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: height)
            y += height + CGFloat(Space.s)
        }
        for label in fileLabels {
            label.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: Self.fileRowHeight)
            y += Self.fileRowHeight
        }
        if !overflowLabel.isHidden {
            overflowLabel.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: Self.fileRowHeight)
            y += Self.fileRowHeight
        }
        if !openReviewButton.isHidden {
            openReviewButton.frame = NSRect(
                x: inset, y: y + CGFloat(Space.s),
                width: min(132, max(1, bounds.width - inset * 2)), height: Self.actionHeight
            )
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
        summaryLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        countsLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        overflowLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        fileLabels.forEach { $0.textColor = context.tokens.primaryText.color.nsColor(for: theme) }
        openReviewButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
    }

    static func measuredHeight(payload: AgentDiffPayload, width: CGFloat) -> CGFloat {
        var result = headerHeight
        let summary = safeSummary(payload.summary)
        if !summary.isEmpty { result += summaryHeight(summary, width: width) + CGFloat(Space.s) }
        result += CGFloat(min(payload.files.count, maximumVisibleFiles)) * fileRowHeight
        if payload.files.count > maximumVisibleFiles { result += fileRowHeight }
        if payload.canOpenReview { result += CGFloat(Space.s) + actionHeight }
        return result + bottomInset
    }

    static func countsText(_ files: [AgentDiffFileSummary]) -> String {
        var additions: UInt = 0
        var removals: UInt = 0
        for file in files {
            let add = additions.addingReportingOverflow(file.addedLineCount)
            let remove = removals.addingReportingOverflow(file.removedLineCount)
            additions = add.overflow ? .max : add.partialValue
            removals = remove.overflow ? .max : remove.partialValue
        }
        let noun = files.count == 1 ? "file" : "files"
        return "\(files.count) \(noun) · +\(additions) −\(removals)"
    }

    private func rebuildFileLabels() {
        fileLabels.forEach { $0.removeFromSuperview() }
        fileLabels = displayedFiles.map { file in
            let name = Self.safeSingleLine(file.displayName, fallback: "Changed file")
            let label = NSTextField(labelWithString: "\(name)   +\(file.addedLineCount) −\(file.removedLineCount)")
            label.font = NSFont.token(.label)
            label.lineBreakMode = .byTruncatingMiddle
            label.isSelectable = true
            label.setAccessibilityLabel("\(name), \(file.addedLineCount) additions, \(file.removedLineCount) removals")
            addSubview(label)
            return label
        }
    }

    @objc private func openReview(_ sender: Any?) {
        guard payload.canOpenReview, let blockID else { return }
        context.actions.perform(.openDiff(blockID: blockID))
    }

    private static func summaryHeight(_ summary: String?, width: CGFloat) -> CGFloat {
        let value = safeSummary(summary)
        guard !value.isEmpty else { return 0 }
        let available = max(1, width - horizontalInset * 2)
        let rect = (value as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.body)]
        )
        return min(ceil(rect.height), CGFloat(Metrics.lineHeight(for: .body) * 2))
    }

    private static func safeSummary(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func safeSingleLine(_ value: String, fallback: String) -> String {
        let line = value.split(whereSeparator: { $0.isNewline }).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? fallback : line
    }
}

@MainActor
final class AgentOpenReviewButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Open Review →"
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.label)
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open diff review")
        identifier = NSUserInterfaceItemIdentifier("agent.diff.openReview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
