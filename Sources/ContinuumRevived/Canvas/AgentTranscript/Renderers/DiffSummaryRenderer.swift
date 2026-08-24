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
    /// The stat label's measured width, one per pooled row, kept alongside the
    /// pool instead of re-typeset from `layout()`. Populated only when the row's
    /// file summary actually changed (`syncFileRows`).
    private var statLabelWidths: [CGFloat] = []

    private var blockID: AgentNodeID?
    private var payload = AgentDiffPayload(text: "")
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    /// QA (A2, `performance.md` traps 1-3): counts the WORK a `--transcript-rhythm-check`
    /// witness asserts against, never the wall clock. `qaFileViewsCreatedForChecks`
    /// is every row view actually allocated across N applies (a bounded pool must
    /// stop creating once it has enough rows); `qaStatMeasurementsForChecks` is
    /// every real stat-label typesetting pass; `qaFrameWritesForChecks` is every
    /// frame actually assigned. All three must be flat when nothing changed.
    private(set) var qaFileViewsCreatedForChecks = 0
    private(set) var qaStatMeasurementsForChecks = 0
    private(set) var qaFrameWritesForChecks = 0

    func qaResetCountersForChecks() {
        qaFileViewsCreatedForChecks = 0
        qaStatMeasurementsForChecks = 0
        qaFrameWritesForChecks = 0
    }

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
        let previousFiles = displayedFiles
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
        syncFileRows(previousFiles: previousFiles)
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
        for index in 0..<displayedFiles.count {
            children.append(fileLabels[index])
            if fileStatLabels.indices.contains(index) { children.append(fileStatLabels[index]) }
        }
        if !overflowLabel.isHidden { children.append(overflowLabel) }
        if !openReviewButton.isHidden { children.append(openReviewButton) }
        setAccessibilityChildren(children)
    }

    /// A2 (`performance.md` traps 2 and 3). This used to measure every stat
    /// label's `attributedStringValue.size()` here — a full typesetting pass,
    /// per file row, on every display cycle a pan/zoom/neighbour resize
    /// dirties this view — and assign every frame unconditionally. The stat
    /// widths are now measured once in `syncFileRows`, at apply time, and kept
    /// alongside the pool; every frame write here is gated on an actual change.
    override func layout() {
        super.layout()
        func place(_ view: NSView, _ frame: NSRect) {
            if view.frame != frame {
                view.frame = frame
                qaFrameWritesForChecks += 1
            }
        }
        let inset = Self.horizontalInset
        let countsIntrinsic = countsLabel.intrinsicContentSize
        let countsWidth = min(ceil(countsIntrinsic.width) + CGFloat(Space.s), max(0, bounds.width * 0.50))
        place(countsLabel, NSRect(
            x: max(inset, bounds.width - inset - countsWidth),
            y: (Self.headerHeight - countsIntrinsic.height) / 2,
            width: countsWidth,
            height: countsIntrinsic.height
        ))
        let titleIntrinsic = titleLabel.intrinsicContentSize
        place(titleLabel, NSRect(
            x: inset,
            y: (Self.headerHeight - titleIntrinsic.height) / 2,
            width: max(1, countsLabel.frame.minX - inset - CGFloat(Space.m)),
            height: titleIntrinsic.height
        ))
        var y = Self.headerHeight
        if !summaryLabel.isHidden {
            let height = Self.summaryHeight(payload.summary, width: bounds.width)
            place(summaryLabel, NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: height))
            y += height + CGFloat(Space.s)
        }
        for index in 0..<displayedFiles.count {
            let label = fileLabels[index]
            let barWidth = min(Self.statBarWidth, max(0, bounds.width * 0.22))
            let statLabel = fileStatLabels.indices.contains(index) ? fileStatLabels[index] : nil
            // The width was measured once, when this row's text was last set
            // (`syncFileRows`) — never re-typeset here.
            let measuredWidth = statLabelWidths.indices.contains(index) ? statLabelWidths[index] : 0
            let statWidth = statLabel != nil ? min(measuredWidth, max(0, bounds.width * 0.34)) : 0
            let barX = bounds.width - inset - barWidth
            if fileStatBars.indices.contains(index) {
                let bar = fileStatBars[index]
                let barHeight = CGFloat(Space.s)
                place(bar, NSRect(
                    x: barX, y: y + (Self.fileRowHeight - barHeight) / 2,
                    width: barWidth, height: barHeight))
            }
            if let statLabel {
                let statIntrinsicHeight = statLabel.intrinsicContentSize.height
                place(statLabel, NSRect(
                    x: max(inset, barX - CGFloat(Space.s) - statWidth),
                    y: y + (Self.fileRowHeight - statIntrinsicHeight) / 2,
                    width: statWidth, height: statIntrinsicHeight))
            }
            let nameLimit = statLabel?.frame.minX ?? barX
            let labelIntrinsic = label.intrinsicContentSize
            place(label, NSRect(
                x: inset,
                y: y + (Self.fileRowHeight - labelIntrinsic.height) / 2,
                width: max(1, nameLimit - inset - CGFloat(Space.s)),
                height: labelIntrinsic.height))
            y += Self.fileRowHeight
        }
        if !overflowLabel.isHidden {
            place(overflowLabel, NSRect(x: inset, y: y, width: max(1, bounds.width - inset * 2), height: Self.fileRowHeight))
            y += Self.fileRowHeight
        }
        if !openReviewButton.isHidden {
            place(openReviewButton, NSRect(
                x: inset, y: y + CGFloat(Space.xs),
                width: min(132, max(1, bounds.width - inset * 2)), height: Self.actionHeight
            ))
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
    ///
    /// A2: this used to tear down and rebuild all three views for EVERY file on
    /// EVERY apply (`rebuildFileLabels`), even when nothing changed. The pool
    /// now only grows — never shrinks — to the largest file count this view has
    /// ever shown; a smaller apply hides the surplus rather than destroying it,
    /// and a row whose file summary is unchanged skips its (attributed-string,
    /// measurement) work entirely.
    private func syncFileRows(previousFiles: [AgentDiffFileSummary]) {
        let theme = effectiveTokenTheme
        let added = AccentToken.accentDone.color.nsColor(for: theme)
        let removed = AccentToken.accentFailed.color.nsColor(for: theme)
        let monoSize = NSFont.token(.label).pointSize
        while fileLabels.count < displayedFiles.count {
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            label.isSelectable = true
            addSubview(label)
            fileLabels.append(label)

            let stat = NSTextField(labelWithString: "")
            stat.alignment = .right
            stat.lineBreakMode = .byClipping
            stat.setAccessibilityElement(false)
            addSubview(stat)
            fileStatLabels.append(stat)

            let bar = AgentDiffStatBar(frame: .zero)
            addSubview(bar)
            fileStatBars.append(bar)

            statLabelWidths.append(0)
            qaFileViewsCreatedForChecks += 1
        }
        for index in 0..<displayedFiles.count {
            let file = displayedFiles[index]
            let label = fileLabels[index]
            let stat = fileStatLabels[index]
            let bar = fileStatBars[index]
            label.isHidden = false
            stat.isHidden = false
            bar.isHidden = false
            guard !(previousFiles.indices.contains(index) && previousFiles[index] == file) else { continue }
            let name = Self.safeSingleLine(file.displayName, fallback: "Changed file")
            if label.stringValue != name { label.stringValue = name }
            label.setAccessibilityLabel("\(name), \(file.addedLineCount) additions, \(file.removedLineCount) removals")
            let statString = Self.statText(file, added: added, removed: removed)
            stat.attributedStringValue = statString
            qaStatMeasurementsForChecks += 1
            statLabelWidths[index] = ceil(statString.size().width) + CGFloat(Space.s)
            bar.apply(added: file.addedLineCount, removed: file.removedLineCount)
            bar.applyColors(added: added, removed: removed)
        }
        for index in displayedFiles.count..<fileLabels.count {
            fileLabels[index].isHidden = true
            fileStatLabels[index].isHidden = true
            fileStatBars[index].isHidden = true
        }
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
