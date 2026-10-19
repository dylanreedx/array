import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Deterministic geometry witness for the agent tile's custom selects
/// (`--choice-geometry-check`).
///
/// Every earlier truncation gate measured the closed TRIGGER. Nothing compared a
/// popped-open ROW's label frame against the string that row has to draw, which
/// is where the reported defect lived: the panel sizes itself from the glyph run
/// (`NSString.size`) while each row insets its label by the row chrome AND the
/// label cell's own horizontal padding, so every row elided at every panel width.
///
/// The fixtures use realistic LIVE display names ("Claude Sonnet 4.5"), not the
/// bare ids the other QA fixtures carry: an id with no display name is short
/// enough to hide the deficit behind `minimumWidth`, which is exactly why the
/// shipped gates stayed green.
@MainActor
enum ChoiceGeometryChecks {
    enum CheckError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            if case let .message(text) = self { return text }
            return "choice geometry check failed"
        }
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw CheckError.message(message()) }
    }

    /// The width below which a real label ELIDES, measured from a real
    /// `NSTextField` and from nothing the production controls compute.
    ///
    /// This must not route through `ChoiceLabelMetrics`: a gate that re-derives
    /// its expectation from the same expression the control sizes itself with
    /// agrees with the control by construction and cannot fail.
    private static func requiredLabelWidth(_ title: String, font: NSFont) -> CGFloat {
        let field = NSTextField(labelWithString: title)
        field.font = font
        // `intrinsicContentSize` is itself the under-reporting quantity — it omits
        // the cell's horizontal inset, so a gate built on it declared a label that
        // elides at four points too narrow to be "wide enough". Ask the cell.
        let unbounded = NSRect(
            x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return ceil(max(field.intrinsicContentSize.width,
                        field.cell?.cellSize(forBounds: unbounded).width ?? 0))
    }

    /// Titles of the length the live catalogue actually produces.
    private static let longTitles = [
        "Claude Fable 5.1",
        "Claude Sonnet 4.5",
        "GPT-5.6 Luna",
        "openai-codex/gpt-5.3-codex-spark",
    ]

    private static let zooms: [AgentPageZoom] = [
        AgentPageZoom(percent: 80),
        AgentPageZoom(percent: 100),
        AgentPageZoom(percent: 125),
        AgentPageZoom(percent: 150),
    ]

    static func run() throws {
        // FIRST, before anything writes: the owner's agent keys must come out of
        // this leg exactly as they went in, never rewritten even for a moment.
        let standardGuard = QAStandardDefaultsGuard(keys: QAStandardDefaultsGuard.agentSelectionKeys)
        // Hermetic against ambient harness state, in-process only: deleting the key
        // here deleted the owner's real harness choice inside the prod bundle.
        let unpinAmbientSelection = AgentCatalogQAFixture.pinAmbientSelection(
            harness: .claudeCode,
            model: AgentModelCatalog.shared.snapshot(for: .claudeCode).seedModel ?? "")
        defer { unpinAmbientSelection() }

        try checkMeasuredCellInset()
        try checkPopoverRowsDrawTheirTitles()
        try checkTriggerKeepsItsTitleAtIntrinsicWidth()
        try checkFooterDoesNotCondenseWithSurplusWidth()
        try checkCatalogRefreshRerunsTheFitDecision()
        try checkShortRowShortensOneTriggerAndNoMenu()
        try checkSubPointRoundingKeepsTheTitle()
        let touched = standardGuard.finish()
        guard touched.isEmpty else {
            throw CheckError.message("the leg wrote the owner's agent keys in the standard defaults domain: \(touched)")
        }
    }

    // MARK: - 1. The cell inset is a measurement, not a guess

    private static func checkMeasuredCellInset() throws {
        for zoom in zooms {
            let font = NSFont.token(.label, zoom: zoom)
            let inset = ChoiceLabelMetrics.cellInset(for: font)
            try expect(inset > 0,
                       "a label cell's horizontal inset must measure above zero at \(zoom.percent)%, got \(inset)")
            for title in longTitles {
                let measured = ChoiceLabelMetrics.labelWidth(for: title, font: font)
                let needed = requiredLabelWidth(title, font: font)
                try expect(measured >= needed,
                           "measured label width \(measured) is under what a real label needs "
                           + "(\(needed)) for \"\(title)\" at \(zoom.percent)%")
            }
        }
    }

    // MARK: - 2. THE GAP: a popped-open row must be able to draw its own title

    private static func checkPopoverRowsDrawTheirTitles() throws {
        let cases: [(name: String, presentation: ChoiceListPresentation, icons: Bool, details: Bool)] = [
            ("choices", .choices, false, false),
            ("choices+detail", .choices, false, true),
            ("commands", .commands, false, false),
            ("commands+icon", .commands, true, false),
            ("slashCommands", .slashCommands, false, true),
            ("slashCommands-no-icon", .slashCommands, false, false),
            ("completions", .completions, false, true),
        ]
        for testCase in cases {
            for zoom in zooms {
                let items = longTitles.enumerated().map { index, title in
                    ChoiceItem(
                        id: "id-\(index)",
                        title: title,
                        detail: testCase.details ? "\(title) — the id tail it demotes" : nil,
                        icon: testCase.icons ? .system("gearshape") : nil)
                }
                let list = ChoiceListView(
                    items: items, selectedID: items.first?.id,
                    presentation: testCase.presentation)
                list.applyPageZoom(zoom)
                // The panel adopts exactly this size (ChoicePopoverController), so
                // this is the width production gives the list, not a chosen one.
                list.frame = NSRect(origin: .zero, size: list.intrinsicContentSize)
                list.layoutSubtreeIfNeeded()

                let titleFont = NSFont.token(.body, zoom: zoom)
                let detailFont = NSFont.token(.caption, zoom: zoom)
                let frames = list.qaRowTextFrames
                try expect(frames.count == items.count,
                           "every row must be laid out, got \(frames.count) of \(items.count)")
                for (item, frame) in zip(items, frames) {
                    let needed = requiredLabelWidth(item.title, font: titleFont)
                    try expect(frame.title.width + 0.5 >= needed,
                               "[\(testCase.name) @\(zoom.percent)%] row \"\(item.title)\" draws in "
                               + "\(frame.title.width)pt but needs \(needed)pt "
                               + "(panel width \(list.bounds.width)pt, short by "
                               + "\(needed - frame.title.width)pt) — the row truncates at the panel's own width")
                    if let detail = item.detail, let detailFrame = frame.detail {
                        let detailNeeded = requiredLabelWidth(detail, font: detailFont)
                        try expect(detailFrame.width + 0.5 >= detailNeeded,
                                   "[\(testCase.name) @\(zoom.percent)%] detail \"\(detail)\" draws in "
                                   + "\(detailFrame.width)pt but needs \(detailNeeded)pt")
                    }
                }
            }
        }
    }

    // MARK: - 3. The closed trigger keeps its title at its own intrinsic width

    private static func checkTriggerKeepsItsTitleAtIntrinsicWidth() throws {
        for zoom in zooms {
            for title in longTitles {
                let button = ChoiceButton(title: "Model")
                button.applyPageZoom(zoom)
                button.items = [ChoiceItem(id: "only", title: title)]
                button.selectedID = "only"
                button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
                button.layoutSubtreeIfNeeded()
                let needed = requiredLabelWidth(title, font: NSFont.token(.label, zoom: zoom))
                try expect(button.qaTitleFrameWidth + 0.5 >= needed,
                           "[trigger @\(zoom.percent)%] \"\(title)\" draws in \(button.qaTitleFrameWidth)pt "
                           + "but needs \(needed)pt at the button's own intrinsic width "
                           + "(\(button.intrinsicContentSize.width)pt)")
                try expect(button.qaTitleDrawsWithoutTruncation,
                           "[trigger @\(zoom.percent)%] \"\(title)\" reports truncation at intrinsic width")
            }
        }
    }

    // MARK: - 4. Surplus width must never produce a condensed or elided footer

    private static func checkFooterDoesNotCondenseWithSurplusWidth() throws {
        AgentModelCatalog.shared.resetForQA(
            options: ["anthropic/claude-sonnet-4-5", "openai-codex/gpt-5.3-codex-spark"],
            displayNames: [
                "anthropic/claude-sonnet-4-5": "Claude Sonnet 4.5",
                "openai-codex/gpt-5.3-codex-spark": "GPT-5.3 Codex Spark",
            ])
        defer { AgentModelCatalog.shared.resetForQA() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let footer = AgentComposerFooterView(
            frame: NSRect(x: 0, y: 40, width: 640, height: AgentComposerFooterView.height))
        window.contentView?.addSubview(footer)
        window.orderFrontOffscreenForChecks()
        footer.apply(AgentLaunchSelection(
            harness: .pi, model: "anthropic/claude-sonnet-4-5", thinking: "medium"))
        footer.frame = NSRect(x: 0, y: 40, width: 640, height: AgentComposerFooterView.height)
        window.contentView?.layoutSubtreeIfNeeded()
        footer.layoutSubtreeIfNeeded()

        try expect(footer.qaFitsCurrentTitles,
                   "640pt is plenty of room for three triggers, yet the footer reports no fit")
        try expect(!footer.effortButton.isHidden,
                   "effort must stay visible when the row has surplus width")
        try expect(footer.modelButton.qaRenderedTitle == "Claude Sonnet 4.5",
                   "the model trigger must show the live display name with room to spare, got "
                   + "\"\(footer.modelButton.qaRenderedTitle)\"")
        for (name, button) in [("harness", footer.harnessButton),
                               ("model", footer.modelButton),
                               ("effort", footer.effortButton)] {
            let needed = requiredLabelWidth(
                button.qaRenderedTitle, font: NSFont.token(.label, zoom: .default))
            try expect(button.qaTitleFrameWidth + 0.5 >= needed && button.qaTitleDrawsWithoutTruncation,
                       "[footer @640pt] the \(name) trigger truncates \"\(button.qaRenderedTitle)\" "
                       + "in \(button.qaTitleFrameWidth)pt (needs \(needed)pt) "
                       + "while the row has surplus width")
        }
    }

    // MARK: - 5. An async catalogue refresh re-runs the fit decision

    private static func checkCatalogRefreshRerunsTheFitDecision() throws {
        // Before the refresh the catalogue has bare ids; after it, the long live
        // names arrive. The host width is chosen BETWEEN the two fitting widths,
        // so the refresh genuinely changes the answer the fit decision owes.
        let model = "pi/m1"
        let longName = "Claude Sonnet 4.5 Extended Thinking"
        AgentModelCatalog.shared.resetForQA(options: [model], displayNames: [:])
        defer { AgentModelCatalog.shared.resetForQA() }

        let gap = CGFloat(Space.m)
        let fixedWidth = ChoiceButton.fittingWidth(forTitle: AgentHarness.pi.rawValue)
            + gap + ChoiceButton.fittingWidth(forTitle: "Medium") + gap
        let beforeWidth = fixedWidth + ChoiceButton.fittingWidth(forTitle: model)
        let afterWidth = fixedWidth + ChoiceButton.fittingWidth(forTitle: longName)
        try expect(afterWidth > beforeWidth + 8,
                   "fixture is inert: the live name must need more room than the id "
                   + "(\(afterWidth) vs \(beforeWidth))")
        let hostWidth = ceil((beforeWidth + afterWidth) / 2)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let footer = AgentComposerFooterView(
            frame: NSRect(x: 0, y: 40, width: hostWidth, height: AgentComposerFooterView.height))
        window.contentView?.addSubview(footer)
        window.orderFrontOffscreenForChecks()
        footer.apply(AgentLaunchSelection(harness: .pi, model: model, thinking: "medium"))
        footer.frame = NSRect(x: 0, y: 40, width: hostWidth, height: AgentComposerFooterView.height)
        window.contentView?.layoutSubtreeIfNeeded()
        footer.layoutSubtreeIfNeeded()
        try expect(footer.modelButton.qaRenderedTitle == model,
                   "before the refresh the trigger shows the bare id, got "
                   + "\"\(footer.modelButton.qaRenderedTitle)\"")

        AgentModelCatalog.shared.resetForQA(
            options: [model], displayNames: [model: longName])
        NotificationCenter.default.post(
            name: AgentModelCatalog.didRefreshNotification, object: AgentModelCatalog.shared)
        // Two passes: the fit decision runs in `layout()` and re-installs titles,
        // which the stack then re-solves — production gets both across run-loop
        // turns, and a check that took only one would be measuring a half-applied
        // layout rather than the footer's settled answer.
        window.contentView?.layoutSubtreeIfNeeded()
        footer.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        footer.layoutSubtreeIfNeeded()

        try expect(footer.modelButton.qaRenderedTitle != model,
                   "the refresh must install the live display name on the trigger")
        try expect(footer.modelButton.qaTitleFrameWidth + 0.5 >= requiredLabelWidth(
                       footer.modelButton.qaRenderedTitle, font: NSFont.token(.label, zoom: .default))
                   && footer.modelButton.qaTitleDrawsWithoutTruncation,
                   "after an async catalogue refresh the model trigger draws \""
                   + "\(footer.modelButton.qaRenderedTitle)\" in \(footer.modelButton.qaTitleFrameWidth)pt "
                   + "but needs \(footer.modelButton.qaMeasuredTitleWidth)pt — the fit decision did not "
                   + "re-run when the longer title arrived")
    }

    // MARK: - 6. A row a point short shortens ONE trigger, and never a menu

    private static func checkShortRowShortensOneTriggerAndNoMenu() throws {
        // All-or-nothing compaction turned "Claude Code / Claude Sonnet 4.5 /
        // Medium" into "Claude / claude-sonnet-4-5 / Med" a point below the full
        // fit, menu rows included, though each menu sizes to its own content.
        let model = "anthropic/claude-sonnet-4-5"
        AgentModelCatalog.shared.resetForQA(options: [model], displayNames: [:])
        defer { AgentModelCatalog.shared.resetForQA() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let footer = AgentComposerFooterView(
            frame: NSRect(x: 0, y: 40, width: 640, height: AgentComposerFooterView.height))
        window.contentView?.addSubview(footer)
        window.orderFrontOffscreenForChecks()
        footer.apply(AgentLaunchSelection(harness: .claudeCode, model: model, thinking: "medium"))
        // The footer's own measure of the full titles, one point short of it.
        let hostWidth = floor(footer.qaRequiredWidth(for: .full)) - 1
        try expect(footer.qaRequiredWidth(for: .shortHarness) <= hostWidth,
                   "fixture is inert: shortening the harness alone does not fit \(hostWidth)pt; \(footer.qaFitTiersDescription)")
        let fullModelTitle = footer.modelButton.items.first(where: { $0.id == model })?.title ?? ""
        footer.frame = NSRect(x: 0, y: 40, width: hostWidth, height: AgentComposerFooterView.height)
        for _ in 0..<2 {
            window.contentView?.layoutSubtreeIfNeeded()
            footer.layoutSubtreeIfNeeded()
        }

        let rendered = [footer.harnessButton, footer.modelButton, footer.effortButton].map(\.qaRenderedTitle)
        try expect(rendered == ["Claude", fullModelTitle, "Medium"],
                   "[footer @\(hostWidth)pt, 1pt under the full fit] expected only the harness to shorten "
                   + "(Claude / \(fullModelTitle) / Medium), got \(rendered); \(footer.qaFitTiersDescription)")
        for (label, button) in [("harness", footer.harnessButton), ("model", footer.modelButton),
                                ("effort", footer.effortButton)] {
            try expect(button.qaTitleDrawsWithoutTruncation,
                       "[footer @\(hostWidth)pt] the \(label) trigger ellipsizes \"\(button.qaRenderedTitle)\"")
        }
        try expect(footer.harnessButton.items.map(\.title) == AgentHarness.allCases.map(\.rawValue)
                       && fullModelTitle == model
                       && footer.modelButton.items.allSatisfy {
                           !$0.id.contains("/") || $0.title != AgentComposerFooterView.abbreviatedModel($0.id)
                       }
                       && footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(\.capitalized),
                   "a shortened trigger shortened its menu rows too: harness \(footer.harnessButton.items.map(\.title)), "
                   + "model \(footer.qaModelTitles), effort \(footer.qaEffortTitles)")
        for (label, button) in [("harness", footer.harnessButton), ("effort", footer.effortButton)] {
            button.presentPopover()
            defer { button.dismissPopoverForQA() }
            try expect(button.qaTruncatedPresentedRowTitles == [],
                       "the \(label) menu ellipsizes \(button.qaTruncatedPresentedRowTitles ?? ["<not presented>"])")
        }
    }

    // MARK: - 7. Sub-point layout rounding never ellipsizes a title

    private static func checkSubPointRoundingKeepsTheTitle() throws {
        // A canvas zoom snaps view frames to device pixels, so the footer's stack
        // can hand a trigger a fraction of a point under its intrinsic width with
        // the row full of surplus. Measured in the dictation film (r10), a working
        // Codex tile at canvas zoom 3.13: harness frame 103.888pt, intrinsic 104pt,
        // label 37.888pt for "Codex", which needs 38pt. AppKit drew "Cod…".
        // `qaTitleDrawsWithoutTruncation` allows 0.5pt and passed it, so this
        // compares strictly against what the label's own cell needs.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let button = ChoiceButton(title: "Codex")
        button.selectedIcon = .provider("openai/")
        window.contentView?.addSubview(button)
        window.orderFrontOffscreenForChecks()
        let intrinsic = button.intrinsicContentSize.width
        for deficit in [0.112, 0.25, 0.5, 0.9] as [CGFloat] {
            button.frame = NSRect(x: 0, y: 40, width: intrinsic - deficit, height: ChoiceButton.controlHeight)
            button.layoutSubtreeIfNeeded()
            try expect(button.qaTitleFrameWidth >= button.qaTitleDrawingWidth - 0.001,
                       "[\"Codex\" trigger \(deficit)pt under its intrinsic \(intrinsic)pt] the label gets "
                       + "\(button.qaTitleFrameWidth)pt but its cell needs \(button.qaTitleDrawingWidth)pt, "
                       + "so it ellipsizes a title the row has room for")
        }
        // Negative control: a trigger genuinely too narrow still ellipsizes. The
        // tolerance absorbs rounding, never a real shortfall.
        button.frame = NSRect(x: 0, y: 40, width: intrinsic - 12, height: ChoiceButton.controlHeight)
        button.layoutSubtreeIfNeeded()
        try expect(button.qaTitleFrameWidth < button.qaTitleDrawingWidth - 8,
                   "a trigger 12pt short must still shorten its label (got \(button.qaTitleFrameWidth)pt for "
                   + "\(button.qaTitleDrawingWidth)pt)")
    }
}
