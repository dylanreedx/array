import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

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
            // Derived exactly as `apply` derives them, or the measurement
            // dedupes against a title the row does not have.
            title: ToolCallView.safeSingleLine(payload.name, fallback: "Tool"),
            statusLabel: payload.status.agentToolStatusPresentation.label,
            outputText: payload.presentedOutputText,
            outputNote: payload.presentedOutputNote,
            width: width,
            expanded: expanded,
            zoom: context.pageZoom
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
    // WS5: the same three metrics at a tile's page zoom. The zero-argument
    // statics above stay exactly as they were — they are the 100% values, and
    // out-of-module witnesses read them — so these are companions, not
    // replacements.
    static func rowHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xxl + Space.xs)) }
    static func horizontalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    static func detailBottomInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.xs)) }
    /// Where the row's own text starts: past the disclosure control and the
    /// icon. The detail line hangs from the SAME x as the title, so a row reads
    /// as one block instead of a title with an unrelated sentence beneath it.
    static var detailIndent: CGFloat { horizontalInset + CGFloat(Space.xxl) * 2 + CGFloat(Space.s) + CGFloat(Space.m) }
    static func detailIndent(zoom: AgentPageZoom) -> CGFloat {
        horizontalInset(zoom: zoom) + CGFloat(zoom.scaled(Space.xxl)) * 2
            + CGFloat(zoom.scaled(Space.s)) + CGFloat(zoom.scaled(Space.m))
    }
    /// The page zoom of the last `apply`. Every metric below reads it, so a
    /// recycled row re-derives rather than keeping the zoom it was built at.
    private var zoom: AgentPageZoom { context.pageZoom }
    private var effectiveDetailIndent: CGFloat {
        Self.detailIndent(zoom: zoom) + (isClusterMember ? Self.clusterIndent(zoom: zoom) : 0)
    }

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: "Tool")
    private(set) var statusLabel = NSTextField(labelWithString: "")
    private(set) var summaryLabel = NSTextField(wrappingLabelWithString: "")
    /// `.plans/45` S4.2 — the expanded pane's output, reusing the command
    /// output machinery (exact selection, dual-format copy) fed raw text from
    /// the host-local store — never a `.commandOutput` block (I5).
    private(set) var outputScrollView = CodeBlockScrollView(frame: .zero)
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
    static func clusterIndent(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }

    private var blockID: AgentNodeID?
    /// The SEMANTIC tool name, kept so the accessibility label cannot drift onto
    /// whatever the title happens to read. `toggleDisclosure` used to relabel
    /// from `titleLabel`, which is the ACTION SENTENCE — so expanding a row
    /// silently changed its VoiceOver identity from "Bash" to "Ran npm test".
    private var toolNameForAccessibility = "Tool"
    private var trailingDetailText: String?
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
        outputScrollView.hasHorizontalScroller = true
        // Same treatment `CodeBlockRenderer` got in `b5ff292f`, which this pane
        // never inherited. The pane's height is content-derived with ZERO slack —
        // one line is 17pt of glyphs inside an 8pt inset, i.e. exactly 33pt — so a
        // LEGACY scroller (the system default when "always show scroll bars" is
        // on) takes ~15pt out of 33 and clips the top half of the only line there
        // is. Worse, it feeds back: the horizontal bar shrinks the viewport, which
        // makes the 33pt document genuinely taller than the viewport, which brings
        // in the vertical bar, which eats the width. Overlay scrollers cost 0pt of
        // viewport, and the vertical one is now decided per layout from the
        // measured text rather than asserted once at construction.
        outputScrollView.scrollerStyle = .overlay
        outputScrollView.hasVerticalScroller = false
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

        // WS5: fonts and radii are assigned at construction too, but this view is
        // recycled — a row built at 100% and reused for a 150% tile would keep
        // the smaller type. Re-derive them here, from THIS context's zoom.
        let zoom = context.pageZoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        titleLabel.font = NSFont.token(.label, zoom: zoom)
        statusLabel.font = NSFont.token(.caption, zoom: zoom)
        summaryLabel.font = NSFont.token(.body, zoom: zoom)
        outputNoteLabel.font = NSFont.token(.caption, zoom: zoom)
        outputScrollView.layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        outputCopyButton.applyZoom(zoom)

        isExpanded = context.actions.isExpanded(
            blockID: blockID,
            default: payload.status.agentToolDefaultExpanded
        )
        titleLabel.stringValue = Self.safeSingleLine(payload.name, fallback: "Tool")
        // `.plans/45` S4 — the title is the action sentence; the tool NAME
        // lives in the icon, the tooltip and the AX label.
        let toolName = payload.presentedToolNameText ?? payload.name
        toolNameForAccessibility = Self.safeSingleLine(toolName, fallback: "Tool")
        trailingDetailText = payload.presentedTrailingDetailText
        iconView.image = Self.symbolImage(forToolNamed: toolName)
        toolTip = payload.presentedToolNameText.map { Self.safeSingleLine($0, fallback: "Tool") }
        let presentation = payload.status.agentToolStatusPresentation
        statusLabel.stringValue = Self.statusText(
            status: payload.status, duration: payload.presentedTrailingDetailText)
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
        // TR-03 — one dedupe, shared with `measuredHeight`. It used to live only
        // here, so the MEASUREMENT was made from the undeduped summary: a row
        // whose only body line repeated its title hid that line and kept the
        // height it would have needed. Every single-file `Read` row is exactly
        // that shape, so the commonest row on the surface reserved a blank line.
        let presented = Self.presentedSummary(
            title: titleLabel.stringValue,
            summary: payload.summary,
            statusLabel: presentation.label
        )
        disclosureText = presented.disclosureText
        compactSummary = presented.compactLine
        outputText = payload.presentedOutputText?.isEmpty == false ? payload.presentedOutputText : nil
        outputNote = payload.presentedOutputNote
        hasDisclosureDetail = presented.lineCount > 1 || outputText != nil
        if !hasDisclosureDetail { isExpanded = false }
        summaryLabel.stringValue = isExpanded ? disclosureText : compactSummary
        summaryLabel.maximumNumberOfLines = isExpanded ? 12 : 1
        summaryLabel.isHidden = summaryLabel.stringValue.isEmpty
        outputTextView.apply(text: outputText ?? "", context: context)
        outputNoteLabel.stringValue = outputNote ?? ""
        syncOutputPaneVisibility()
        disclosureButton.isHidden = !hasDisclosureDetail
        disclosureButton.isEnabled = hasDisclosureDetail
        disclosureButton.apply(expanded: isExpanded, title: titleLabel.stringValue, zoom: zoom)
        identifier = NSUserInterfaceItemIdentifier("agent.toolCall.\(blockID.rawValue)")
        applyAccessibility(status: payload.status)
        applyTokens()
        needsLayout = true
    }

    func applyAccessibility(name: String, status: AgentItemStatus) {
        toolNameForAccessibility = Self.safeSingleLine(name, fallback: "Tool")
        applyAccessibility(status: status)
    }

    /// TR-03 — the label carries the facts the row is showing, not just its name
    /// and state. The duration and the presence of an output pane are exactly
    /// what a sighted reader gets from the trailing column and the chevron, and
    /// they were the two things the label omitted.
    private func applyAccessibility(status: AgentItemStatus) {
        let presentation = status.agentToolStatusPresentation
        var parts = ["Tool", toolNameForAccessibility, presentation.label]
        if let trailingDetailText, !trailingDetailText.isEmpty, status.agentToolIsTerminal {
            parts.append("took \(trailingDetailText)")
        }
        if outputText != nil { parts.append("output available") }
        setAccessibilityLabel(parts.joined(separator: ", "))
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
        let zoom = self.zoom
        let rowHeight = Self.rowHeight(zoom: zoom)
        let inset = Self.horizontalInset(zoom: zoom) + (isClusterMember ? Self.clusterIndent(zoom: zoom) : 0)
        let buttonSide = CGFloat(zoom.scaled(Space.xxl))
        if isClusterMember {
            clusterRail.isHidden = false
            clusterRail.frame = CGRect(
                x: Self.horizontalInset(zoom: zoom) + CGFloat(zoom.scaled(Space.xs)), y: 0,
                width: max(1, CGFloat(LineWidth.hairline)), height: bounds.height)
        } else {
            clusterRail.isHidden = true
        }
        // Read once each, reused below.
        let statusIntrinsic = statusLabel.intrinsicContentSize
        let titleIntrinsic = titleLabel.intrinsicContentSize

        place(disclosureButton, disclosureButton.isHidden ? .zero : NSRect(
            x: inset, y: (rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide))
        // The disclosure column is reserved whether or not this row has one, so
        // titles align down the transcript and the detail line below can hang
        // from exactly the title's x.
        place(iconView, NSRect(
            x: inset + buttonSide + CGFloat(zoom.scaled(Space.s)),
            y: (rowHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        ))
        let statusWidth = min(ceil(statusIntrinsic.width) + CGFloat(zoom.scaled(Space.s)), max(0, bounds.width * 0.40))
        place(statusLabel, NSRect(
            x: max(iconView.frame.maxX, bounds.maxX - inset - statusWidth),
            y: (rowHeight - statusIntrinsic.height) / 2,
            width: statusWidth, height: statusIntrinsic.height
        ))
        let titleX = iconView.frame.maxX + CGFloat(zoom.scaled(Space.m))
        place(titleLabel, NSRect(
            x: titleX,
            y: (rowHeight - titleIntrinsic.height) / 2,
            width: max(1, statusLabel.frame.minX - titleX - CGFloat(zoom.scaled(Space.m))),
            height: titleIntrinsic.height
        ))
        let detailY = rowHeight
        let outputVisible = !outputScrollView.isHidden
        let summaryHeight: CGFloat
        if outputVisible {
            summaryHeight = summaryLabel.isHidden ? 0 : Self.measuredSummaryHeight(
                summaryLabel.stringValue, width: bounds.width, expanded: isExpanded, zoom: zoom)
        } else {
            summaryHeight = max(0, bounds.height - detailY - Self.detailBottomInset(zoom: zoom))
        }
        place(summaryLabel, NSRect(
            x: effectiveDetailIndent, y: detailY,
            width: max(1, bounds.width - effectiveDetailIndent - Self.horizontalInset(zoom: zoom)),
            height: summaryHeight
        ))
        if outputVisible {
            var y = summaryLabel.frame.maxY + CGFloat(zoom.scaled(Space.xs))
            let paneX = effectiveDetailIndent
            let copyWidth = outputCopyButton.intrinsicContentSize.width
            place(outputCopyButton, NSRect(
                x: max(paneX, bounds.maxX - inset - copyWidth), y: y,
                width: copyWidth, height: CGFloat(zoom.scaled(Space.xl))
            ))
            if !outputNoteLabel.isHidden {
                let noteSize = outputNoteLabel.intrinsicContentSize
                place(outputNoteLabel, NSRect(
                    x: paneX, y: y + (CGFloat(zoom.scaled(Space.xl)) - noteSize.height) / 2,
                    width: max(1, outputCopyButton.frame.minX - paneX - CGFloat(zoom.scaled(Space.s))),
                    height: noteSize.height
                ))
            }
            y = outputCopyButton.frame.maxY + CGFloat(zoom.scaled(Space.xs))
            place(outputScrollView, NSRect(
                x: paneX, y: y,
                width: max(1, bounds.width - paneX - inset),
                height: max(0, bounds.height - y - Self.detailBottomInset(zoom: zoom))
            ))
            outputScrollView.layoutSubtreeIfNeeded()
            let measuredOutput = CommandOutputTextView.measuredSize(outputTextView.string, zoom: zoom)
            let needsVerticalScroll = measuredOutput.height > outputScrollView.contentSize.height + 0.5
            if outputScrollView.hasVerticalScroller != needsVerticalScroll {
                outputScrollView.hasVerticalScroller = needsVerticalScroll
                outputScrollView.layoutSubtreeIfNeeded()
            }
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
        // TR-03: `.completed` alone left a cancelled or interrupted row at the
        // same visual weight as live work, so a turn the reader stopped still
        // read as running. Any settled row recedes; a FAILURE is the exception
        // handled below, where only the status colour pulls the eye.
        alphaValue = status.agentToolIsTerminal && status != .failed ? Opacity.receded : Opacity.full
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
    /// TR-03: the mapping itself now lives in `AgentToolKind`, which the action
    /// sentence and the fold noun read too. It used to be a private
    /// word-boundary matcher here, and `_` counts as a word character — so every
    /// snake_case tool name (`read_file`, `search_issues`, and every
    /// `mcp__server__tool`) fell to the wrench while the presenter, matching by
    /// raw substring, happily titled the same row "Read foo.swift". One row, two
    /// classifiers, two answers.
    ///
    /// Unknown names keep the wrench, so a new provider tool degrades to today's
    /// behaviour rather than to a blank column.
    ///
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

    static let fallbackSymbolName = AgentToolKind.unknown.symbolName

    static func symbolName(forToolNamed name: String?) -> String {
        AgentToolKind.resolve(toolName: name).symbolName
    }

    /// What a row will actually SHOW, once the lines that merely restate the
    /// title or the status word have been removed. One derivation, read by
    /// `apply` (which paints it) and `measuredHeight` (which reserves space for
    /// it) — they disagreed before, and the reader saw the difference as a blank
    /// line under most rows.
    struct PresentedSummary: Equatable {
        /// Every surviving line, joined — what an EXPANDED row shows.
        var disclosureText: String
        /// The first surviving line — what a COLLAPSED row shows.
        var compactLine: String
        /// How many lines survived; > 1 is what earns a disclosure control.
        var lineCount: Int
    }

    static func presentedSummary(
        title: String, summary: String?, statusLabel: String
    ) -> PresentedSummary {
        let candidate = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A summary that is only the status word ("Completed") says nothing the
        // trailing column has not already said.
        guard candidate.caseInsensitiveCompare(statusLabel) != .orderedSame else {
            return PresentedSummary(disclosureText: "", compactLine: "", lineCount: 0)
        }
        var lines = candidate.split(whereSeparator: { $0.isNewline }).map(String.init)
        // `.plans/45` S3 — when the title already IS the action sentence, the
        // disclosure's first line repeats it; show the additional facts only.
        // Case-INSENSITIVE: the two strings are composed in different places
        // with different fallbacks, so "Bash" over "bash" slipped through an
        // exact match every time a tool produced no action sentence.
        if lines.first?.caseInsensitiveCompare(title) == .orderedSame {
            lines.removeFirst()
        }
        return PresentedSummary(
            disclosureText: lines.joined(separator: "\n"),
            compactLine: lines.first ?? "",
            lineCount: lines.count
        )
    }

    /// The trailing column.
    ///
    /// TR-03: the duration used to be gated on `.completed`, so a row that
    /// FAILED — or was cancelled, or was swept when the turn was interrupted —
    /// threw away the one number saying how long it had burned before it died.
    /// Those are the states where the number matters most. Every terminal state
    /// that knows its duration now shows it; an unfinished row keeps the wordy
    /// label, because "In progress" is the fact and there is no span yet.
    static func statusText(status: AgentItemStatus, duration: String?) -> String {
        let presentation = status.agentToolStatusPresentation
        guard let duration, !duration.isEmpty, status.agentToolIsTerminal else {
            return "\(presentation.glyph) \(presentation.label)"
        }
        return "\(duration) \(presentation.glyph)"
    }

    static let maximumOutputHeight: CGFloat = 240
    static func maximumOutputHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(240)) }

    /// TR-03 — `title` and `statusLabel` are what the row will actually show, so
    /// the measurement can run the SAME dedupe the view runs. Passing them is
    /// not optional: measuring the raw `summary` is precisely the defect, and a
    /// defaulted parameter would let a caller reintroduce it silently.
    static func measuredHeight(
        summary: String?,
        title: String,
        statusLabel: String,
        outputText: String? = nil,
        outputNote: String? = nil,
        width: CGFloat,
        expanded: Bool,
        zoom: AgentPageZoom = .default
    ) -> CGFloat {
        _ = outputNote
        let zoomedRowHeight = rowHeight(zoom: zoom)
        let zoomedDetailBottomInset = detailBottomInset(zoom: zoom)
        let presented = presentedSummary(title: title, summary: summary, statusLabel: statusLabel)
        let visibleSummary = expanded ? presented.disclosureText : presented.compactLine
        var height: CGFloat
        if !visibleSummary.isEmpty {
            height = zoomedRowHeight
                + measuredSummaryHeight(visibleSummary, width: width, expanded: expanded, zoom: zoom)
                + zoomedDetailBottomInset
        } else {
            height = zoomedRowHeight
        }
        // `.plans/45` S4.2 — the expanded output pane: copy row + bounded text.
        if expanded, let outputText, !outputText.isEmpty {
            if height == zoomedRowHeight { height += zoomedDetailBottomInset }
            let outputHeight = min(
                maximumOutputHeight(zoom: zoom),
                max(
                    CommandOutputView.minimumOutputHeight(zoom: zoom),
                    CommandOutputTextView.measuredSize(outputText, zoom: zoom).height
                )
            )
            height += CGFloat(zoom.scaled(Space.xs)) + CGFloat(zoom.scaled(Space.xl))
                + CGFloat(zoom.scaled(Space.xs)) + outputHeight
        }
        return height
    }

    static func measuredSummaryHeight(
        _ summary: String, width: CGFloat, expanded: Bool, zoom: AgentPageZoom = .default
    ) -> CGFloat {
        // Measured against the INDENTED width the detail actually gets.
        let lines = summary.split(whereSeparator: { $0.isNewline }).map(String.init)
        let measuredText = expanded && lines.count > 1 ? summary : (lines.first ?? "")
        let available = max(1, width - detailIndent(zoom: zoom) - horizontalInset(zoom: zoom))
        let rect = (measuredText as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.token(.body, zoom: zoom)]
        )
        let lineHeight = CGFloat(zoom.lineHeight(for: .body))
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
        disclosureButton.apply(expanded: isExpanded, title: titleLabel.stringValue, zoom: zoom)
        applyAccessibility(status: status)
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

    static func safeSingleLine(_ value: String, fallback: String) -> String {
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

    func apply(expanded: Bool, title itemTitle: String, zoom: AgentPageZoom = .default) {
        // Re-derived per apply: the chevron is a glyph in `.label`, and this
        // button is recycled with its row.
        font = NSFont.token(.label, zoom: zoom)
        title = expanded ? "▾" : "▸"
        toolTip = expanded ? "Collapse \(itemTitle)" : "Expand \(itemTitle)"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}
