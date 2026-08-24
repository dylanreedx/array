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
    // Tightened 2026-08-24: the card was 40pt of header + 28pt per file row +
    // 16pt of bottom inset, so two changed files cost ~120pt of transcript for
    // four facts. A diffstat is a dense format; this reads as one.
    static let headerHeight = CGFloat(Space.xxl + Space.xs)
    static let fileRowHeight = CGFloat(Space.xl + Space.xs)
    static let actionHeight = CGFloat(Space.xl + Space.xs)
    static let horizontalInset = CGFloat(Space.l)
    static let bottomInset = CGFloat(Space.s)
    static let maximumVisibleFiles = 8
    /// The proportional add/remove bar, git `--stat` style.
    static let statBarWidth = CGFloat(Space.xxl * 2)

    private(set) var titleLabel = NSTextField(labelWithString: "Changes")
    private(set) var countsLabel = NSTextField(labelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    /// The file NAME labels, one per displayed file (the lab witness counts
    /// these). Stats and bars are separate, parallel arrays.
    private(set) var fileLabels: [NSTextField] = []
    private(set) var fileStatLabels: [NSTextField] = []
    private(set) var fileStatBars: [AgentDiffStatBar] = []
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

        // A diffstat's subject is its numbers; the word "Changes" is an
        // EYEBROW, not a headline — uppercase with tracking, secondary colour,
        // so the summary sentence below it is the thing being read.
        titleLabel.font = NSFont.token(.caption)
        countsLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.token(.caption).pointSize, weight: .regular)
        countsLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = NSFont.token(.body)
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.lineBreakMode = .byWordWrapping
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
        titleLabel.attributedStringValue = NSAttributedString(
            string: "CHANGES",
            attributes: [
                .font: NSFont.token(.caption),
                .kern: 0.8,
            ])
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
        for (index, label) in fileLabels.enumerated() {
            children.append(label)
            if fileStatLabels.indices.contains(index) { children.append(fileStatLabels[index]) }
        }
        if !overflowLabel.isHidden { children.append(overflowLabel) }
        if !openReviewButton.isHidden { children.append(openReviewButton) }
        setAccessibilityChildren(children)
    }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let countsWidth = min(ceil(countsLabel.intrinsicContentSize.width) + CGFloat(Space.s), max(0, bounds.width * 0.50))
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
        for (index, label) in fileLabels.enumerated() {
            let barWidth = min(Self.statBarWidth, max(0, bounds.width * 0.22))
            let statLabel = fileStatLabels.indices.contains(index) ? fileStatLabels[index] : nil
            // Measured from the attributed string itself: an NSTextField created
            // from an EMPTY string does not reliably re-derive its intrinsic
            // width when `attributedStringValue` is assigned later, and the
            // clipped result silently dropped the removal count.
            let statWidth = statLabel.map {
                min(ceil($0.attributedStringValue.size().width) + CGFloat(Space.s),
                    max(0, bounds.width * 0.34))
            } ?? 0
            let barX = bounds.width - inset - barWidth
            if fileStatBars.indices.contains(index) {
                let bar = fileStatBars[index]
                let barHeight = CGFloat(Space.s)
                bar.frame = NSRect(
                    x: barX, y: y + (Self.fileRowHeight - barHeight) / 2,
                    width: barWidth, height: barHeight)
            }
            if let statLabel {
                statLabel.frame = NSRect(
                    x: max(inset, barX - CGFloat(Space.s) - statWidth),
                    y: y + (Self.fileRowHeight - statLabel.intrinsicContentSize.height) / 2,
                    width: statWidth, height: statLabel.intrinsicContentSize.height)
            }
            let nameLimit = statLabel?.frame.minX ?? barX
            label.frame = NSRect(
                x: inset,
                y: y + (Self.fileRowHeight - label.intrinsicContentSize.height) / 2,
                width: max(1, nameLimit - inset - CGFloat(Space.s)),
                height: label.intrinsicContentSize.height)
            y += Self.fileRowHeight
        }
        if !overflowLabel.isHidden {
            overflowLabel.frame = NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: Self.fileRowHeight)
            y += Self.fileRowHeight
        }
        if !openReviewButton.isHidden {
            openReviewButton.frame = NSRect(
                x: inset, y: y + CGFloat(Space.xs),
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
        titleLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        summaryLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        countsLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        overflowLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        fileLabels.forEach { $0.textColor = context.tokens.primaryText.color.nsColor(for: theme) }
        let added = AccentToken.accentDone.color.nsColor(for: theme)
        let removed = AccentToken.accentFailed.color.nsColor(for: theme)
        for (index, label) in fileStatLabels.enumerated() {
            guard displayedFiles.indices.contains(index) else { continue }
            let file = displayedFiles[index]
            label.attributedStringValue = Self.statText(file, added: added, removed: removed)
        }
        for bar in fileStatBars { bar.applyColors(added: added, removed: removed) }
        openReviewButton.contentTintColor = context.tokens.primaryText.color.nsColor(for: theme)
    }

    static func measuredHeight(payload: AgentDiffPayload, width: CGFloat) -> CGFloat {
        var result = headerHeight
        let summary = safeSummary(payload.summary)
        if !summary.isEmpty { result += summaryHeight(summary, width: width) + CGFloat(Space.s) }
        result += CGFloat(min(payload.files.count, maximumVisibleFiles)) * fileRowHeight
        if payload.files.count > maximumVisibleFiles { result += fileRowHeight }
        if payload.canOpenReview { result += CGFloat(Space.xs) + actionHeight }
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

    /// One row per changed file: the path (monospaced, middle-truncated, so a
    /// long path loses its middle and keeps its filename), the counts in their
    /// own colours, and a proportional add/remove bar. This is the shape a
    /// diffstat has everywhere else; the old row concatenated all three into
    /// one string, which is why the numbers were unreadable.
    private func rebuildFileLabels() {
        fileLabels.forEach { $0.removeFromSuperview() }
        fileStatLabels.forEach { $0.removeFromSuperview() }
        fileStatBars.forEach { $0.removeFromSuperview() }
        let theme = effectiveTokenTheme
        let added = AccentToken.accentDone.color.nsColor(for: theme)
        let removed = AccentToken.accentFailed.color.nsColor(for: theme)
        let monoSize = NSFont.token(.label).pointSize
        var names: [NSTextField] = []
        var stats: [NSTextField] = []
        var bars: [AgentDiffStatBar] = []
        for file in displayedFiles {
            let name = Self.safeSingleLine(file.displayName, fallback: "Changed file")
            let label = NSTextField(labelWithString: name)
            label.font = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            label.isSelectable = true
            label.setAccessibilityLabel("\(name), \(file.addedLineCount) additions, \(file.removedLineCount) removals")
            addSubview(label)
            names.append(label)

            let stat = NSTextField(labelWithString: "")
            stat.attributedStringValue = Self.statText(file, added: added, removed: removed)
            stat.alignment = .right
            stat.lineBreakMode = .byClipping
            stat.setAccessibilityElement(false)
            addSubview(stat)
            stats.append(stat)

            let bar = AgentDiffStatBar(frame: .zero)
            bar.apply(added: file.addedLineCount, removed: file.removedLineCount)
            bar.applyColors(added: added, removed: removed)
            addSubview(bar)
            bars.append(bar)
        }
        fileLabels = names
        fileStatLabels = stats
        fileStatBars = bars
    }

    /// "+42 −3" with each number in its own accent. Monospaced digits so the
    /// columns line up down the card.
    static func statText(_ file: AgentDiffFileSummary, added: NSColor, removed: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.token(.label).pointSize, weight: .medium)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "+\(file.addedLineCount)",
            attributes: [.font: font, .foregroundColor: added]))
        result.append(NSAttributedString(
            string: " \u{2212}\(file.removedLineCount)",
            attributes: [.font: font, .foregroundColor: removed]))
        return result
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

/// The proportional add/remove bar from a `git --stat` line. Deliberately not
/// `TokenThemed`: it owns no background and its two colours are assigned by the
/// parent card's `applyTokens` (hazard 8 — a resting state paints nothing).
@MainActor
final class AgentDiffStatBar: NSView {
    private(set) var addedShare: CGFloat = 0
    private var addedColor: NSColor = .labelColor
    private var removedColor: NSColor = .labelColor
    private var isEmpty = true

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(added: UInt, removed: UInt) {
        let total = CGFloat(added) + CGFloat(removed)
        isEmpty = total == 0
        addedShare = total == 0 ? 0 : CGFloat(added) / total
        needsDisplay = true
    }

    func applyColors(added: NSColor, removed: NSColor) {
        addedColor = added
        removedColor = removed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isEmpty, bounds.width > 0 else { return }
        let radius = bounds.height / 2
        let addedWidth = (bounds.width * addedShare).rounded()
        if addedWidth > 0 {
            addedColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: addedWidth, height: bounds.height),
                xRadius: radius, yRadius: radius
            ).fill()
        }
        let removedWidth = bounds.width - addedWidth
        if removedWidth > 0 {
            removedColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: addedWidth, y: 0, width: removedWidth, height: bounds.height),
                xRadius: radius, yRadius: radius
            ).fill()
        }
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
