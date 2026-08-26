import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Compact structured-tool presentation. The renderer intentionally consumes
/// only the safe name/summary fields; opaque arguments never enter the view.
@MainActor
final class ToolCallRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .toolCall

    func makeView() -> NSView {
        ToolCallView()
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? ToolCallView,
              case let .toolCall(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .toolCall(payload) = block.payload else { return 0 }
        let expanded = context.actions.isExpanded(
            blockID: block.id,
            default: payload.status.agentToolDefaultExpanded
        )
        return ToolCallView.measuredHeight(
            summary: payload.summary,
            outputText: payload.presentedOutputText,
            outputNote: payload.presentedOutputNote,
            width: width,
            expanded: expanded
        )
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? ToolCallView,
              case let .toolCall(payload) = block.payload else { return }
        view.applyAccessibility(name: payload.presentedToolNameText ?? payload.name, status: payload.status)
    }
}

@MainActor
final class ToolCallView: NSView {
    // Tightened 2026-08-24: 36pt for a one-line row, plus a 12pt row gap, read
    // as "spread out too much".
    static let rowHeight = CGFloat(Space.xxl + Space.xs)
    static let horizontalInset = CGFloat(Space.l)
    static let detailBottomInset = CGFloat(Space.xs)
    /// Where the row's own text starts: past the disclosure control and the
    /// icon. The detail line hangs from the SAME x as the title, so a row reads
    /// as one block instead of a title with an unrelated sentence beneath it.
    static var detailIndent: CGFloat { horizontalInset + CGFloat(Space.xxl) * 2 + CGFloat(Space.s) + CGFloat(Space.m) }
    private var effectiveDetailIndent: CGFloat {
        Self.detailIndent + (isClusterMember ? Self.clusterIndent : 0)
    }

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: "Tool")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    /// `.plans/45` S4.2 — the expanded pane's output, reusing the command
    /// output machinery (exact selection, dual-format copy) fed raw text from
    /// the host-local store — never a `.commandOutput` block (I5).
    private(set) var outputScrollView = NSScrollView(frame: .zero)
    private(set) var outputTextView = CommandOutputTextView(frame: .zero)
    private(set) var outputCopyButton = CommandOutputCopyButton(frame: .zero)
    private(set) var outputNoteLabel = NSTextField(labelWithString: "")
    private(set) var isExpanded = false
    private var outputText: String?
    private var outputNote: String?
    private var isClusterMember = false
    /// The group rail drawn down the left of an expanded cluster's members.
    private let clusterRail = CALayer()
    static let clusterIndent = CGFloat(Space.l)

    private var blockID: AgentNodeID?
    private var disclosureText = ""
    private var compactSummary = ""
    private var hasDisclosureDetail = false
    private var status: AgentItemStatus = .pending
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.masksToBounds = true

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        iconView.image = Self.symbolImage(forToolNamed: nil)
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = NSFont.token(.body)
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.isSelectable = true

        outputScrollView.wantsLayer = true
        outputScrollView.layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        outputScrollView.layer?.masksToBounds = true
        outputScrollView.drawsBackground = false
        outputScrollView.borderType = .noBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.documentView = outputTextView
        outputCopyButton.target = self
        outputCopyButton.action = #selector(copyEntireOutput(_:))
        outputNoteLabel.font = NSFont.token(.caption)
        outputNoteLabel.lineBreakMode = .byTruncatingTail

        addSubview(disclosureButton)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(summaryLabel)
        addSubview(outputScrollView)
        addSubview(outputCopyButton)
        addSubview(outputNoteLabel)
        clusterRail.isHidden = true
        clusterRail.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(clusterRail)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentToolCallPayload, context: AgentRenderContext) {
        isClusterMember = payload.presentedIsClusterMember
        let previousBlockID = self.blockID
        let previousStatus = self.status
        self.blockID = blockID
        self.status = payload.status
        self.context = context

        isExpanded = context.actions.isExpanded(
            blockID: blockID,
            default: payload.status.agentToolDefaultExpanded
        )
        titleLabel.stringValue = Self.safeSingleLine(payload.name, fallback: "Tool")
        // `.plans/45` S4 — the title is the action sentence; the tool NAME
        // lives in the icon, the tooltip and the AX label.
        let toolName = payload.presentedToolNameText ?? payload.name
        iconView.image = Self.symbolImage(forToolNamed: toolName)
        toolTip = payload.presentedToolNameText.map { Self.safeSingleLine($0, fallback: "Tool") }
        let presentation = payload.status.agentToolStatusPresentation
        // `.plans/45` S3/S4 — the trailing column reads "2.1s ✓" when the
        // host-local detail knows the duration; the wordy status label remains
        // the fallback (and the failure presentation keeps its label).
        if let duration = payload.presentedTrailingDetailText,
           payload.status == .completed {
            statusLabel.stringValue = "\(duration) \(presentation.glyph)"
        } else {
            statusLabel.stringValue = "\(presentation.glyph) \(presentation.label)"
        }
        // A row resolving under the reader — in progress becoming "2.1s ✓" —
        // settles rather than swapping. Two conditions, both learned from the
        // witness: the SAME block (a recycled view arriving with different
        // content is an arrival, animated once by the list, and settling on
        // reuse would make rows blink their way down a fast scroll — the very
        // flicker being fixed), and a real STATUS change. Keying it on the
        // trailing TEXT instead blinked every completed row a second time when
        // its duration arrived from the host-local detail store, which is not a
        // state change and read as exactly the noise this is here to remove.
        if previousBlockID == blockID, previousStatus != payload.status {
            AgentTranscriptMotion.settle(statusLabel)
        }
        let candidateSummary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        disclosureText = candidateSummary.caseInsensitiveCompare(presentation.label) == .orderedSame
            ? "" : candidateSummary
        var lines = disclosureText.split(whereSeparator: { $0.isNewline }).map(String.init)
        // `.plans/45` S3 — when the title already IS the action sentence, the
        // disclosure's first line repeats it; show the additional facts only.
        // Case-INSENSITIVE, matching the idiom three lines above. It was exact,
        // and the two strings it compares are composed in different places with
        // different fallbacks — `capitalizedPhrase(toolName)` for the title,
        // bare `safeToolName` for the body — so "Bash" over "bash" slipped
        // through every time a tool produced no action sentence. The presenter
        // no longer emits that line at all; this is the second wall, and it is
        // what makes a render-level witness for the doubling possible.
        if lines.first?.caseInsensitiveCompare(titleLabel.stringValue) == .orderedSame {
            lines.removeFirst()
            disclosureText = lines.joined(separator: "\n")
        }
        compactSummary = lines.first ?? ""
        outputText = payload.presentedOutputText?.isEmpty == false ? payload.presentedOutputText : nil
        outputNote = payload.presentedOutputNote
        hasDisclosureDetail = lines.count > 1 || outputText != nil
        if !hasDisclosureDetail { isExpanded = false }
        summaryLabel.stringValue = isExpanded ? disclosureText : compactSummary
        summaryLabel.maximumNumberOfLines = isExpanded ? 12 : 1
        summaryLabel.isHidden = summaryLabel.stringValue.isEmpty
        outputTextView.apply(text: outputText ?? "", context: context)
        outputNoteLabel.stringValue = outputNote ?? ""
        syncOutputPaneVisibility()
        disclosureButton.isHidden = !hasDisclosureDetail
        disclosureButton.isEnabled = hasDisclosureDetail
        disclosureButton.apply(expanded: isExpanded, title: titleLabel.stringValue)
        identifier = NSUserInterfaceItemIdentifier("agent.toolCall.\(blockID.rawValue)")
        applyAccessibility(name: toolName, status: payload.status)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(name: String, status: AgentItemStatus) {
        let presentation = status.agentToolStatusPresentation
        setAccessibilityLabel("Tool, \(Self.safeSingleLine(name, fallback: "Tool")), \(presentation.label)")
        var children: [NSView] = disclosureButton.isHidden
            ? [titleLabel, statusLabel] : [disclosureButton, titleLabel, statusLabel]
        if !summaryLabel.isHidden { children.append(summaryLabel) }
        setAccessibilityChildren(children)
    }

    /// `.plans/45` T10 (`performance.md` traps 2 and 3, together, on every display
    /// cycle). This used to assign all five frames unconditionally and read
    /// `intrinsicContentSize` four times per pass. An unchanged frame on an
    /// `NSTextField` still costs a TextKit glyph-bounds pass AND re-dirties the
    /// view — 20 of 34 samples in the 0.4.16 CPU report were exactly that path.
    /// A tool row is the densest thing in a transcript, so it pays that cost more
    /// often than anything else on the surface.
    override func layout() {
        super.layout()
        func place(_ view: NSView, _ frame: NSRect) {
            if view.frame != frame { view.frame = frame }
        }
        let inset = Self.horizontalInset + (isClusterMember ? Self.clusterIndent : 0)
        let buttonSide = CGFloat(Space.xxl)
        if isClusterMember {
            clusterRail.isHidden = false
            clusterRail.frame = CGRect(
                x: Self.horizontalInset + CGFloat(Space.xs), y: 0,
                width: max(1, CGFloat(LineWidth.hairline)), height: bounds.height)
        } else {
            clusterRail.isHidden = true
        }
        // Read once each, reused below.
        let statusIntrinsic = statusLabel.intrinsicContentSize
        let titleIntrinsic = titleLabel.intrinsicContentSize

        place(disclosureButton, disclosureButton.isHidden ? .zero : NSRect(
            x: inset, y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide))
        // The disclosure column is reserved whether or not this row has one, so
        // titles align down the transcript and the detail line below can hang
        // from exactly the title's x.
        place(iconView, NSRect(
            x: inset + buttonSide + CGFloat(Space.s),
            y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        ))
        let statusWidth = min(ceil(statusIntrinsic.width) + CGFloat(Space.s), max(0, bounds.width * 0.40))
        place(statusLabel, NSRect(
            x: max(iconView.frame.maxX, bounds.maxX - inset - statusWidth),
            y: (Self.rowHeight - statusIntrinsic.height) / 2,
            width: statusWidth, height: statusIntrinsic.height
        ))
        let titleX = iconView.frame.maxX + CGFloat(Space.m)
        place(titleLabel, NSRect(
            x: titleX,
            y: (Self.rowHeight - titleIntrinsic.height) / 2,
            width: max(1, statusLabel.frame.minX - titleX - CGFloat(Space.m)),
            height: titleIntrinsic.height
        ))
        let detailY = Self.rowHeight
        let outputVisible = !outputScrollView.isHidden
        let summaryHeight: CGFloat
        if outputVisible {
            summaryHeight = summaryLabel.isHidden ? 0 : Self.measuredSummaryHeight(
                summaryLabel.stringValue, width: bounds.width, expanded: isExpanded)
        } else {
            summaryHeight = max(0, bounds.height - detailY - Self.detailBottomInset)
        }
        place(summaryLabel, NSRect(
            x: effectiveDetailIndent, y: detailY,
            width: max(1, bounds.width - effectiveDetailIndent - Self.horizontalInset),
            height: summaryHeight
        ))
        if outputVisible {
            var y = summaryLabel.frame.maxY + CGFloat(Space.xs)
            let paneX = effectiveDetailIndent
            let copyWidth = outputCopyButton.intrinsicContentSize.width
            place(outputCopyButton, NSRect(
                x: max(paneX, bounds.maxX - inset - copyWidth), y: y,
                width: copyWidth, height: CGFloat(Space.xl)
            ))
            if !outputNoteLabel.isHidden {
                let noteSize = outputNoteLabel.intrinsicContentSize
                place(outputNoteLabel, NSRect(
                    x: paneX, y: y + (CGFloat(Space.xl) - noteSize.height) / 2,
                    width: max(1, outputCopyButton.frame.minX - paneX - CGFloat(Space.s)),
                    height: noteSize.height
                ))
            }
            y = outputCopyButton.frame.maxY + CGFloat(Space.xs)
            place(outputScrollView, NSRect(
                x: paneX, y: y,
                width: max(1, bounds.width - paneX - inset),
                height: max(0, bounds.height - y - Self.detailBottomInset)
            ))
            outputTextView.sizeDocument(toFit: outputScrollView.contentSize)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        // `.plans/45` T6. No fill. `_DESIGN.md` §11 keeps the surface ladder at
        // canvas -> tile -> artifact/composer and asks for "fewer nested fills";
        // a routine tool row is not an artifact, and giving every one of them a
        // filled card is what made the transcript read as a wall of cards. nil,
        // never .clear — a painted transparent is an unregistered literal to the
        // appearance census (hazard 8).
        layer?.backgroundColor = nil
        // "Completed routine work recedes" (§11). `Opacity.receded` is 0.88,
        // derived so faded secondary text still clears AA at break-even 0.8724 —
        // so it is applied to the row as a whole and never stacked with a further
        // colour reduction. A failure never recedes: only failures should pull
        // the eye.
        alphaValue = status == .completed ? Opacity.receded : Opacity.full
        titleLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        summaryLabel.textColor = context.tokens.primaryText.color.nsColor(for: theme)
        statusLabel.textColor = status == .failed
            ? AgentLineRole.attention.color.nsColor(for: theme)
            : context.tokens.secondaryText.color.nsColor(for: theme)
        disclosureButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        iconView.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        clusterRail.backgroundColor = isClusterMember
            ? AgentLineRole.decorativeHairline.color.cgColor(for: theme)
            : nil
        outputNoteLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        outputCopyButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        outputTextView.applyTheme(theme)
        outputScrollView.layer?.backgroundColor = outputScrollView.isHidden
            ? nil
            : context.tokens.codeSurface.color.cgColor(for: theme)
    }

    /// `.plans/45` T11 — one glyph per kind of work, instead of one wrench for
    /// everything.
    ///
    /// Resolved from the provider-supplied tool NAME, matched on substrings
    /// because the three harnesses disagree on casing and wording for the same
    /// operation (codex sends literal `"Shell"` and `"Edit"`, claude sends
    /// `bash`/`Bash`, pi sends its own). Unknown names keep the wrench, so a new
    /// provider tool degrades to today's behaviour rather than to a blank column.
    ///
    /// The mapping lives here as one static function rather than in `apply` so a
    /// witness can exercise it without building a view.
    /// The mapping's doc comment promises it "degrades to today's behaviour
    /// rather than to a blank column", but `CanvasSymbolImage.image(named:)`
    /// returns nil for any symbol this OS does not have and the result went
    /// straight into `iconView.image` — so an unavailable symbol WAS a blank
    /// column. Fall back to the generic tool glyph, and only then to nothing.
    static func symbolImage(forToolNamed name: String?) -> NSImage? {
        if let image = CanvasSymbolImage.image(named: symbolName(forToolNamed: name)) {
            return image
        }
        return CanvasSymbolImage.image(named: fallbackSymbolName)
    }

    static let fallbackSymbolName = "wrench.and.screwdriver"

    static func symbolName(forToolNamed name: String?) -> String {
        let fallback = fallbackSymbolName
        guard let name = name?.lowercased(), !name.isEmpty else { return fallback }
        // Word-boundary matching, not raw substring: `name.contains("cat")` also
        // matched inside "locate"/"relocate". A "word" here is a run of
        // letters/digits/underscore — underscore counts as a word character (as
        // it does for regex `\b`), so this alone is not enough for the
        // delegation category below: "task"/"agent" are common SUFFIX words in
        // namespaced tool names ("mcp__linear__create_task" is one underscore
        // away from a `\b` match) and are handled separately.
        func containsWord(_ name: String, _ needle: String) -> Bool {
            guard !needle.isEmpty else { return false }
            func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
            var searchStart = name.startIndex
            while let range = name.range(of: needle, range: searchStart..<name.endIndex) {
                let leftBoundary = range.lowerBound == name.startIndex || !isWordChar(name[name.index(before: range.lowerBound)])
                let rightBoundary = range.upperBound == name.endIndex || !isWordChar(name[range.upperBound])
                if leftBoundary && rightBoundary { return true }
                searchStart = range.upperBound
            }
            return false
        }
        func any(_ needles: [String]) -> Bool { needles.contains { containsWord(name, $0) } }
        // Delegation FIRST, and not a bubble. `bubble.left` is what
        // `CompletedReasoningDisclosureView` paints for reasoning, so a
        // `delegate_agent` row rendered as a thought — Dylan saw exactly that.
        // This rhymes with the chip the row becomes instead
        // (`AgentReferenceRenderer` paints `person.crop.circle.badge.arrow.forward`).
        // It is tested before "read"/"search" because a delegation tool name can
        // contain either.
        //
        // "task" and "agent" are the delegation NOUN, not a verb, and they are
        // common suffix words on unrelated namespaced tools (an MCP tool named
        // `mcp__linear__create_task` is not a subagent). They only count when
        // they are the tool's WHOLE name — the bare "Task"/"Agent" identifiers
        // claude/pi actually send — never as a fragment of a longer name.
        // "subagent"/"delegate_agent"/"spawn_agent" are themselves the known,
        // unambiguous compound identifiers, so plain containment is fine there
        // (word-boundary matching would reject them too: the "_" joining
        // "delegate"/"spawn" to "agent" is itself a word character, so neither
        // half alone is `\b`-bounded inside the compound).
        let delegationCompounds = ["subagent", "delegate_agent", "spawn_agent"]
        if delegationCompounds.contains(where: { name.contains($0) }) || name == "task" || name == "agent" {
            return "person.2"
        }
        // "run"/"cat" without the trailing space they used to carry: `"run "` and
        // `"cat "` could not match a bare tool name, only a sentence.
        if any(["bash", "shell", "terminal", "command", "run", "exec"]) { return "terminal" }
        if any(["edit", "write", "patch", "apply_patch", "create", "replace"]) { return "square.and.pencil" }
        if any(["read", "view", "cat", "open"]) { return "eye" }
        if any(["search", "grep", "glob", "find"]) { return "magnifyingglass" }
        if any(["fetch", "web", "http", "url", "browse"]) { return "globe" }
        if any(["todo", "plan"]) { return "checklist" }
        return fallback
    }

    static let maximumOutputHeight: CGFloat = 240

    static func measuredHeight(
        summary: String?,
        outputText: String? = nil,
        outputNote: String? = nil,
        width: CGFloat,
        expanded: Bool
    ) -> CGFloat {
        _ = outputNote
        var height: CGFloat
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            height = rowHeight + measuredSummaryHeight(summary, width: width, expanded: expanded) + detailBottomInset
        } else {
            height = rowHeight
        }
        // `.plans/45` S4.2 — the expanded output pane: copy row + bounded text.
        if expanded, let outputText, !outputText.isEmpty {
            if height == rowHeight { height += detailBottomInset }
            let outputHeight = min(
                maximumOutputHeight,
                max(CommandOutputView.minimumOutputHeight, CommandOutputTextView.measuredSize(outputText).height)
            )
            height += CGFloat(Space.xs) + CGFloat(Space.xl) + CGFloat(Space.xs) + outputHeight
        }
        return height
    }

    static func measuredSummaryHeight(_ summary: String, width: CGFloat, expanded: Bool) -> CGFloat {
        // Measured against the INDENTED width the detail actually gets.
        let lines = summary.split(whereSeparator: { $0.isNewline }).map(String.init)
        let measuredText = expanded && lines.count > 1 ? summary : (lines.first ?? "")
        let available = max(1, width - detailIndent - horizontalInset)
        let rect = (measuredText as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.body)]
        )
        let lineHeight = CGFloat(Metrics.lineHeight(for: .body))
        let lineLimit: CGFloat = expanded ? 12 : 1
        return min(ceil(rect.height), lineHeight * lineLimit)
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        guard let blockID, hasDisclosureDetail else { return }
        isExpanded.toggle()
        context.actions.setExpanded(isExpanded, blockID: blockID)
        summaryLabel.stringValue = isExpanded ? disclosureText : compactSummary
        summaryLabel.maximumNumberOfLines = isExpanded ? 12 : 1
        summaryLabel.isHidden = summaryLabel.stringValue.isEmpty
        syncOutputPaneVisibility()
        disclosureButton.apply(expanded: isExpanded, title: titleLabel.stringValue)
        applyAccessibility(name: titleLabel.stringValue, status: status)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func syncOutputPaneVisibility() {
        let visible = isExpanded && outputText != nil
        let revealed = visible && outputScrollView.isHidden
        outputScrollView.isHidden = !visible
        outputCopyButton.isHidden = !visible
        outputNoteLabel.isHidden = !visible || (outputNote ?? "").isEmpty
        // The row's HEIGHT still changes in one step — the custom transcript
        // layout owns that and the reader's anchor is preserved across it. What
        // this softens is the content: the pane fades up into the space the row
        // just made, which is what reads as "the row opened" rather than "a
        // block of text appeared".
        if revealed { AgentTranscriptMotion.fadeIn(outputScrollView, duration: AgentTranscriptMotion.emphasis) }
    }

    @objc private func copyEntireOutput(_ sender: Any?) {
        outputTextView.writeEntireOutput(to: .general)
        if let blockID { context.actions.perform(.copy(blockID: blockID)) }
    }

    private static func safeSingleLine(_ value: String, fallback: String) -> String {
        let line = value
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? fallback : line
    }
}

/// A native button supplies hit testing and keyboard activation; all visible
/// disclosure chrome is Continuum-owned and borderless.
@MainActor
final class AgentDisclosureButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.label)
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        identifier = NSUserInterfaceItemIdentifier("agent.disclosure")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityChildren() -> [Any]? { [] }

    func apply(expanded: Bool, title itemTitle: String) {
        title = expanded ? "▾" : "▸"
        toolTip = expanded ? "Collapse \(itemTitle)" : "Expand \(itemTitle)"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}
