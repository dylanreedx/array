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
    static let rowHeight = CGFloat(Space.xxl + Space.m)
    static let horizontalInset = CGFloat(Space.l)
    static let detailBottomInset = CGFloat(Space.m)

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
        iconView.image = CanvasSymbolImage.image(named: Self.symbolName(forToolNamed: nil))
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.token(.caption)
        statusLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = NSFont.token(.body)
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.isSelectable = true

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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, payload: AgentToolCallPayload, context: AgentRenderContext) {
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
        iconView.image = CanvasSymbolImage.image(
            named: Self.symbolName(forToolNamed: toolName))
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
        let candidateSummary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        disclosureText = candidateSummary.caseInsensitiveCompare(presentation.label) == .orderedSame
            ? "" : candidateSummary
        var lines = disclosureText.split(whereSeparator: { $0.isNewline }).map(String.init)
        // `.plans/45` S3 — when the title already IS the action sentence, the
        // disclosure's first line repeats it; show the additional facts only.
        if lines.first == titleLabel.stringValue {
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
        let inset = Self.horizontalInset
        let buttonSide = CGFloat(Space.xxl)
        // Read once each, reused below.
        let statusIntrinsic = statusLabel.intrinsicContentSize
        let titleIntrinsic = titleLabel.intrinsicContentSize

        place(disclosureButton, disclosureButton.isHidden ? .zero : NSRect(
            x: inset, y: (Self.rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide))
        place(iconView, NSRect(
            x: disclosureButton.isHidden ? inset : disclosureButton.frame.maxX + CGFloat(Space.s),
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
            x: inset, y: detailY,
            width: max(1, bounds.width - inset * 2),
            height: summaryHeight
        ))
        if outputVisible {
            var y = summaryLabel.frame.maxY + CGFloat(Space.xs)
            let copyWidth = outputCopyButton.intrinsicContentSize.width
            place(outputCopyButton, NSRect(
                x: max(inset, bounds.maxX - inset - copyWidth), y: y,
                width: copyWidth, height: CGFloat(Space.xxl)
            ))
            if !outputNoteLabel.isHidden {
                let noteSize = outputNoteLabel.intrinsicContentSize
                place(outputNoteLabel, NSRect(
                    x: inset, y: y + (CGFloat(Space.xxl) - noteSize.height) / 2,
                    width: max(1, outputCopyButton.frame.minX - inset - CGFloat(Space.s)),
                    height: noteSize.height
                ))
            }
            y = outputCopyButton.frame.maxY + CGFloat(Space.xs)
            place(outputScrollView, NSRect(
                x: inset, y: y,
                width: max(1, bounds.width - inset * 2),
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
        outputNoteLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        outputCopyButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        outputTextView.applyTheme(theme)
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
    static func symbolName(forToolNamed name: String?) -> String {
        let fallback = "wrench.and.screwdriver"
        guard let name = name?.lowercased(), !name.isEmpty else { return fallback }
        func any(_ needles: [String]) -> Bool { needles.contains { name.contains($0) } }
        if any(["bash", "shell", "terminal", "command", "run ", "exec"]) { return "terminal" }
        if any(["edit", "write", "patch", "apply_patch", "create", "replace"]) { return "square.and.pencil" }
        if any(["read", "view", "cat ", "open"]) { return "eye" }
        if any(["search", "grep", "glob", "find"]) { return "magnifyingglass" }
        if any(["fetch", "web", "http", "url", "browse"]) { return "globe" }
        if any(["task", "agent", "spawn", "delegate"]) { return "bubble.left" }
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
            height += CGFloat(Space.xs) + CGFloat(Space.xxl) + CGFloat(Space.xs) + outputHeight
        }
        return height
    }

    static func measuredSummaryHeight(_ summary: String, width: CGFloat, expanded: Bool) -> CGFloat {
        let lines = summary.split(whereSeparator: { $0.isNewline }).map(String.init)
        let measuredText = expanded && lines.count > 1 ? summary : (lines.first ?? "")
        let available = max(1, width - horizontalInset * 2)
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
        outputScrollView.isHidden = !visible
        outputCopyButton.isHidden = !visible
        outputNoteLabel.isHidden = !visible || (outputNote ?? "").isEmpty
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
