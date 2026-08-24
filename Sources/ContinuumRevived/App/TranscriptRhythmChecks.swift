import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import Foundation

/// `.plans/45` — the structural gate for the transcript visual overhaul.
///
/// **Why this leg exists at all.** The transcript's other structural witness,
/// `ComponentLab.runTranscriptReviewCheck`, sits inside `--component-lab-check`,
/// which is in `MATRIX_KNOWN_RED`. So does `--ui-baseline-check`. An assertion
/// added there reads as coverage and never runs. The only transcript gate that
/// currently bites is the pixel sweep in `UIProbePixels`, which asserts
/// non-blank bitmaps and contrast — not hierarchy. This leg is the missing half:
/// it renders the production review surface and asserts the RENDERED OUTCOME of
/// each rhythm decision.
///
/// **Why it asserts outcomes and not intentions.** Every defect in this
/// milestone is a value that is computed and then thrown away. The heading level
/// is parsed, clamped, and used only for an accessibility string. The bullet is
/// built into the text run. A witness phrased as "the renderer receives the
/// level" agrees with a renderer that receives it and discards it. So each
/// assertion below reads what actually reached the screen: the font on the first
/// glyph, the paragraph style on the wrapped run, the painted layer colour, the
/// measured row height.
@MainActor
enum TranscriptRhythmChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func run() throws {
        try checkHeadingLadder()
        try checkHangingIndents()
        try checkThematicBreak()
        try checkTurnSeparation()
        try checkErrorIsNotNotice()
        try checkTable()
        try checkFillsAndEdges()
        try checkRealClaudeTurn()
        try checkClustering()
        try checkFilledSurfacesPadTheirText()
        try checkDiffStatDensity()
        print(
            "TranscriptRhythmChecks: heading ladder, hanging indents, thematic break, "
            + "turn separation, error/notice divergence, table structure, surface fills, "
            + "the replayed real claude turn and tool-run clustering"
        )
    }

    private static func fail(_ message: String) -> Failure { Failure(message: message) }

    /// Renders a production review state and returns its whole view tree.
    private static func render(
        _ state: AgentTranscriptReviewState,
        width: CGFloat = 480,
        theme: TokenTheme = .dark
    ) throws -> (surface: AgentTranscriptReviewSurface, views: [NSView]) {
        let size = NSSize(width: width, height: 720)
        let surface = LabCatalog.makeTranscriptReviewSurface(state: state, size: size, theme: theme)
        let host = NSView(frame: surface.frame)
        host.addSubview(surface)
        surface.needsLayout = true
        surface.layout()
        surface.transcript.layout()
        surface.transcript.collectionView.layout()
        if let error = surface.renderError {
            throw fail("\(state.rawValue): the review surface failed to render: \(error)")
        }
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        return (surface, descendants(in: surface))
    }

    private static func textViews(_ views: [NSView]) -> [RichInlineTextView] {
        views.compactMap { $0 as? RichInlineTextView }
    }

    // MARK: - T5

    /// h1-h6 must be distinguishable. Today every level resolves to `.title`
    /// 15 semibold, so `#` and `######` are the same pixels.
    ///
    /// The type scale caps this: `Typography` has exactly `titleL` 18, `title` 15
    /// and `body` 13 available, and `minimumLadderStep = 2.0` is itself gated, so
    /// six distinct SIZES are not buildable. The ladder is therefore expressed in
    /// size, weight and colour together — and this asserts the combination,
    /// counting distinct (size, weight, colour) triples rather than sizes alone.
    private static func checkHeadingLadder() throws {
        let (_, views) = try render(.headingLadder)
        let bodyPoint = NSFont.token(.body).pointSize
        var traits: Set<String> = []
        var headingCount = 0
        for view in textViews(views) {
            guard let font = view.qaFirstFontForChecks else { continue }
            let isHeadingish = font.pointSize > bodyPoint
                || NSFontManager.shared.weight(of: font) > NSFontManager.shared.weight(of: NSFont.token(.body))
            guard isHeadingish else { continue }
            headingCount += 1
            let colour = view.qaFirstForegroundForChecks?.cgColor.hexForChecks ?? "nil"
            traits.insert("\(font.pointSize)/\(NSFontManager.shared.weight(of: font))/\(colour)")
        }
        guard headingCount >= 6 else {
            throw fail(
                "heading ladder: expected at least 6 rendered headings in the h1-h6 fixture, "
                + "found \(headingCount) — the fixture or the renderer stopped producing them"
            )
        }
        guard traits.count >= 4 else {
            throw fail(
                "heading ladder: h1-h6 render only \(traits.count) distinct "
                + "(size/weight/colour) treatment(s) — \(traits.sorted()). A ladder that does not "
                + "ladder: AssistantProseRenderer clamps `level` and then assigns every rung "
                + "textRole .title, using the level only for the accessibility value."
            )
        }
    }

    // MARK: - T4

    /// A wrapped list item must hang: the second line aligns under the text, not
    /// under the bullet. The marker is concatenated into the text run today, so
    /// nothing in the transcript sets a paragraph style at all.
    private static func checkHangingIndents() throws {
        let (_, views) = try render(.lists, width: 320)
        var indents: [CGFloat] = []
        var sawMarkerInText = false
        for view in textViews(views) {
            guard let storage = view.textStorage, storage.length > 0 else { continue }
            let text = storage.string
            if text.hasPrefix("• ") || text.hasPrefix("› ") || text.hasPrefix("1. ") {
                sawMarkerInText = true
            }
            if let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle, style.headIndent > 0 {
                indents.append(style.headIndent)
            }
        }
        guard !sawMarkerInText else {
            throw fail(
                "hanging indents: a list or quote marker is still concatenated into the text run "
                + "(\"• \" / \"› \" / \"1. \" appears as literal leading characters). A wrapped line "
                + "therefore aligns under the marker instead of under the text."
            )
        }
        // Counted, not "at least one". The fixture holds five list items and one
        // quote; an earlier version of this assertion asked only whether SOME row
        // had an indent, which the quote satisfied on its own — so it stayed green
        // with list indents entirely disabled. Teeth-verified by doing exactly
        // that.
        guard indents.count >= 4 else {
            throw fail(
                "hanging indents: only \(indents.count) rendered row(s) carry a positive "
                + "headIndent, but the fixture has five list items and a quote. A marker "
                + "concatenated into the text run leaves wrapped lines aligned under the marker; "
                + "AgentTextStyleResolver used to set no .paragraphStyle at all."
            )
        }
        // Nesting must deepen the gutter, or a sub-list sits under its parent.
        guard Set(indents.map { ($0 * 10).rounded() }).count >= 2 else {
            throw fail(
                "hanging indents: every indented row uses the identical indent "
                + "(\(Set(indents).sorted())) — a nested list is not indented past its parent"
            )
        }
    }

    // MARK: - T9

    /// A thematic break must draw. Today `.thematicBreak` is parsed, is in
    /// `builtInKinds`, and matches no branch of the registry bootstrap, so it
    /// falls to `AgentDeferredBlockRenderer` — a bare `NSView` measuring 24pt.
    /// With row spacing either side that is a 48pt hole in the document.
    private static func checkThematicBreak() throws {
        let (surface, views) = try render(.tableAndBreaks)
        _ = surface
        // Walk sublayers, not just each view's own backgroundColor. A hairline is
        // most naturally a child layer, and a witness that only inspected view
        // fills would stay red against a perfectly good rule — blind in exactly
        // the axis it exists to watch.
        func paintedRules(in layer: CALayer) -> [CALayer] {
            var found: [CALayer] = []
            if let colour = layer.backgroundColor, colour.alpha > 0,
               layer.bounds.height > 0, layer.bounds.height <= 3, layer.bounds.width >= 80 {
                found.append(layer)
            }
            for sublayer in layer.sublayers ?? [] { found += paintedRules(in: sublayer) }
            return found
        }
        let painted = views.compactMap(\.layer).flatMap(paintedRules(in:))
        guard !painted.isEmpty else {
            throw fail(
                "thematic break: no rule is painted anywhere in the fixture. `---` parses to "
                + ".thematicBreak, which has no registered renderer and falls through the registry "
                + "bootstrap's else branch to AgentDeferredBlockRenderer: a bare NSView that "
                + "measures 24pt and draws nothing."
            )
        }
    }

    // MARK: - T3

    /// Turn -> turn must be separated more than block -> block inside one turn.
    /// One flat `rowSpacing` separates every collection row today, so a new user
    /// prompt carries no more weight than the next paragraph.
    private static func checkTurnSeparation() throws {
        let (surface, _) = try render(.turnBoundary)
        let layout = surface.transcript.transcriptLayout
        let gaps = layout.qaRowGapsForChecks
        guard gaps.count >= 4 else {
            throw fail(
                "turn separation: the three-turn fixture produced only \(gaps.count) row gap(s); "
                + "expected at least 4"
            )
        }
        let distinct = Set(gaps.map { ($0 * 100).rounded() / 100 })
        guard distinct.count >= 2 else {
            throw fail(
                "turn separation: every row gap in a three-turn transcript is identical "
                + "(\(distinct.sorted())). AgentTranscriptLayout applies one flat rowSpacing "
                + "between all rows, so turn->turn is indistinguishable from paragraph->paragraph."
            )
        }
        // >= 2x, not 1.5x (`.plans/45` S4.0): 20-vs-12 passed the old floor and
        // was still visually "a slightly bigger paragraph gap" — the exact look
        // Dylan rejected. A token nudge cannot satisfy a doubling.
        guard let widest = gaps.max(), let narrowest = gaps.min(), widest >= narrowest * 2 else {
            throw fail(
                "turn separation: the widest gap (\(gaps.max() ?? 0)) is not at least twice "
                + "the narrowest (\(gaps.min() ?? 0)); a turn boundary must read as a break, "
                + "not as a slightly bigger paragraph gap"
            )
        }

        // The rule Dylan chose ("space + soft hairline"). Asserted as a painted
        // path, so a spacing change that quietly stopped drawing it is a failure
        // rather than an invisible regression.
        let list = surface.transcript
        let rules = list.qaTurnSeparatorCountForChecks
        let expected = gaps.filter { $0 > AgentTranscriptLayout.interTurnSpacing * 0.9 }.count
        guard rules >= 1, rules == expected else {
            throw fail(
                "turn separation: \(rules) hairline(s) painted for \(expected) turn boundary "
                + "gap(s). The rule and the air are one decision; a boundary with space and no "
                + "rule is not the treatment that was chosen."
            )
        }

        // The hover-revealed "sent at" time, and — the half that matters — that a
        // turn with NO timestamp reveals nothing. Every transcript persisted
        // before `createdAt` existed decodes as nil, and replayCap bounds a
        // rebuilt tile to its last 500 events, so nil is the common case on real
        // history. Showing "now" there would be a fabricated timestamp.
        let document = LabFixtures.transcriptReviewDocument(.turnBoundary)
        guard let stamped = document.entries.first(where: { $0.createdAt != nil }),
              let unstamped = document.entries.first(where: {
                  $0.createdAt == nil && $0.role == .user
              })
        else {
            throw fail("turn separation: the fixture must carry both a stamped and an unstamped turn")
        }
        // Point-based (`.plans/45` S4.0): the old entryID QA bypassed the real
        // mouseMoved hit-test and its coordinate conversion. These points come
        // from the REAL turn-start geometry and run the real hit-test body.
        _ = stamped
        guard let stampedPoint = document.entries
            .filter({ $0.createdAt != nil })
            .compactMap({ list.qaTurnStartPointForChecks(entryID: $0.id) })
            .first else {
            throw fail("hover time: no stamped entry starts a turn in the fixture")
        }
        guard let unstampedPoint = list.qaTurnStartPointForChecks(entryID: unstamped.id) else {
            throw fail("hover time: the unstamped turn produced no turn-start geometry")
        }
        list.qaHoverAtPointForChecks(NSPoint(x: -10_000, y: -10_000))
        guard !list.qaHoverTimeVisibleForChecks else {
            throw fail("hover time: visible with nothing hovered")
        }
        list.qaHoverAtPointForChecks(stampedPoint)
        guard list.qaHoverTimeVisibleForChecks else {
            throw fail(
                "hover time: hovering a turn that HAS a createdAt revealed nothing — the producer "
                + "landed in T1 but the reveal is not reading it (or the hit-test/conversion broke)"
            )
        }
        list.qaHoverAtPointForChecks(unstampedPoint)
        guard !list.qaHoverTimeVisibleForChecks else {
            throw fail(
                "hover time: a turn with NO createdAt revealed a time anyway. Every transcript "
                + "persisted before T1 decodes as nil; rendering one there puts a fabricated "
                + "timestamp on real history."
            )
        }
        list.qaHoverAtPointForChecks(NSPoint(x: -10_000, y: -10_000))

        // Consecutive user prompts (queued sends) are distinct turns: the
        // boundary between u4 and u5 exists. The first rule shipped with a
        // previous-role clause that suppressed exactly this.
        let userRowIndexes = list.qaUserRowIndexesForChecks
        guard userRowIndexes.count >= 5 else {
            throw fail("turn separation: the fixture must carry the queued consecutive prompts")
        }
        let consecutive = zip(userRowIndexes, userRowIndexes.dropFirst()).first { $1 == $0 + 1 }
        guard let pair = consecutive else {
            throw fail("turn separation: no consecutive user rows found in the queued-prompt fixture")
        }
        guard let queuedGap = layout.qaGapAboveForChecks(pair.1),
              queuedGap >= AgentTranscriptLayout.interTurnSpacing * 0.9 else {
            throw fail(
                "turn separation: two consecutive user prompts share one visual turn — the "
                + "boundary between queued sends is suppressed"
            )
        }

        // The replayed REAL turn: exactly one boundary (its single exchange has
        // one prompt), and no rule between the prompt and its own reply's tool
        // rows.
        let (realSurface, _) = try render(.realClaudeTurn)
        let realRules = realSurface.transcript.qaTurnSeparatorCountForChecks
        guard realRules == 0 else {
            throw fail(
                "turn separation: the replayed single-exchange turn painted \(realRules) rule(s); "
                + "a prompt and its own reply are ONE turn"
            )
        }
    }

    // MARK: - T7

    /// An error and a notice must not be the same picture. They share one view
    /// class, one layout and one fill; only a title string and one status colour
    /// differ. A compaction notice therefore reads as a crash.
    private static func checkErrorIsNotNotice() throws {
        let (_, views) = try render(.errorVsNotice)
        let boxes = views.compactMap { $0 as? AgentErrorNoticeView }
        guard boxes.count >= 2 else {
            throw fail(
                "error vs notice: expected both an error and a notice in the fixture, found "
                + "\(boxes.count) AgentErrorNoticeView(s)"
            )
        }
        func signature(_ view: AgentErrorNoticeView) -> String {
            let fill = view.layer?.backgroundColor.map { $0.hexForChecks } ?? "nil"
            let border = view.layer?.borderColor.map { $0.hexForChecks } ?? "nil"
            return "fill=\(fill) border=\(border) width=\(view.layer?.borderWidth ?? 0)"
        }
        let signatures = Set(boxes.map(signature))
        guard signatures.count >= 2 else {
            throw fail(
                "error vs notice: both render the identical surface treatment (\(signatures)). "
                + "They differ today only by a title string and one status-label colour, so a "
                + "compaction notice is pixel-indistinguishable from a failure."
            )
        }
    }

    // MARK: - T8

    /// A Markdown table must reach the renderer as a table. The parser maps
    /// `Table` to `.fencedCode` and stores the raw pipe source as one string, so
    /// the cell structure is destroyed before any renderer sees it.
    private static func checkTable() throws {
        let document = LabFixtures.transcriptReviewDocument(.tableAndBreaks)
        let kinds = document.entries.flatMap { $0.blocks.map(\.kind) }
        guard kinds.contains(.table) else {
            throw fail(
                "table: the parsed fixture contains no .table block (kinds: \(kinds.map(\.rawValue))). "
                + "MarkdownAgentMarkupParser maps Table -> .fencedCode and stores literalSource as "
                + "one code string, so column structure never reaches a renderer."
            )
        }
        let (_, views) = try render(.tableAndBreaks)
        let monospacePipes = textViews(views).contains { view in
            let text = view.textStorage?.string ?? ""
            // The delimiter row is the tell: a table dumped as source always
            // carries it, and no laid-out table ever does.
            return text.contains("| --- |") || text.contains("|---|")
        }
        guard !monospacePipes else {
            throw fail(
                "table: the pipe delimiter row is being rendered as text — the table is being "
                + "dumped as monospace source rather than laid out in columns"
            )
        }
        // §2.5 is a locked ruling: selection, accessibility and pasteboard
        // behaviour are RETAINED. The first table implementation drew its cells,
        // which silently gave all three up — the cells were unselectable,
        // invisible to VoiceOver, and absent from the Markdown tile's rendered
        // text. Assert the cell content reaches a real text view.
        let tableText = textViews(views).map { $0.textStorage?.string ?? "" }
        guard tableText.contains(where: { $0.contains("AgentTranscriptListView.swift") }) else {
            throw fail(
                "table: no rendered text view contains a table cell's text. Drawn cells cannot be "
                + "selected or read by VoiceOver, which _DESIGN.md §2.5 forbids."
            )
        }
    }

    // MARK: - T6

    /// Only code, diff, plan and approval keep a fill. Nine view classes paint
    /// the artifact surface today, so a routine tool row looks as heavy as an
    /// approval. `_DESIGN.md` §11: "fewer nested fills".
    ///
    /// Resting states must paint `nil`, never `.clear` — a painted transparent is
    /// an unregistered literal to the appearance census (hazard 8).
    private static func checkFillsAndEdges() throws {
        // The alignment promise, asserted where it is visible: prose text and the
        // left edge of a filled artifact must share one x. They differed by
        // exactly 12pt because the layout inset every row by 12 and prose then
        // added its own 12 on top.
        let (mixedSurface, mixed) = try render(.mixed)
        // Converted into ONE shared space. These views live at different depths
        // (prose text sits inside a prose view inside a block host inside a
        // collection item), so comparing raw frames compares different origins
        // and would report a difference that is not on screen.
        let space = mixedSurface.transcript.collectionView
        let proseX = mixed.compactMap { $0 as? AssistantProseView }
            .flatMap(\.textFields)
            .map { $0.convert($0.bounds, to: space).minX }
            .min()
        // Only the renderer views that legitimately keep a fill. A width-based
        // filter also caught the scroll and clip views, which span the whole tile
        // and reported an edge that is not an artifact's.
        let fillX = mixed.compactMap { view -> CGFloat? in
            let isArtifact = view is CodeBlockView || view is AgentPlanView
                || view is AgentDiffSummaryView || view is AgentRequestView
                || view is CommandOutputView
            guard isArtifact, let colour = view.layer?.backgroundColor, colour.alpha > 0
            else { return nil }
            return view.convert(view.bounds, to: space).minX
        }.min()
        if let proseX, let fillX, abs(proseX - fillX) > 0.5 {
            throw fail(
                "left edges: prose text starts at \(proseX) but the nearest artifact fill starts "
                + "at \(fillX). AssistantProseView.horizontalReadingInset is added ON TOP of the "
                + "layout's own contentInsets.left, so card edges and prose never share an edge."
            )
        }

        let (_, views) = try render(.recededWork)
        for tool in views.compactMap({ $0 as? ToolCallView }) {
            if let colour = tool.layer?.backgroundColor {
                guard colour.alpha > 0 else {
                    throw fail(
                        "fills: a settled ToolCallView paints a TRANSPARENT layer colour. A resting "
                        + "state must paint nil — a painted .clear is an unregistered literal to the "
                        + "appearance census (CLAUDE.md hazard 8)."
                    )
                }
                throw fail(
                    "fills: a ToolCallView still paints an artifact fill. Only code, diff, plan and "
                    + "approval keep a fill; a routine tool row must sit on the tile body."
                )
            }
        }
    }

    // MARK: - S1

    /// `.plans/45` S1 — Dylan's rejection, replayed. The `.realClaudeTurn`
    /// state runs a scrubbed REAL claude capture through the production
    /// translator → projection path; these assertions are his complaints,
    /// verbatim: the search row said "searching" and nothing else, "In
    /// progress" went stale, and nothing showed how long anything took.
    /// Each one asserts the RENDERED text, not any intermediate supply.
    private static func checkRealClaudeTurn() throws {
        let replay = LabFixtures.realClaudeTurn
        if let loadError = replay.loadError {
            throw fail("real claude turn: the capture failed to replay: \(loadError)")
        }

        // The complete stream must settle every tool row. This is the
        // regression guard for S5's sweep: a COMPLETE capture already carries
        // every tool_result, so an in-progress row here means the projection
        // lost a completion, not that the provider never sent one.
        let toolStatuses = replay.document.entries
            .flatMap(\.blocks)
            .compactMap { block -> AgentItemStatus? in
                guard case let .toolCall(payload) = block.payload else { return nil }
                return payload.status
            }
        guard !toolStatuses.isEmpty else {
            throw fail("real claude turn: the replayed document contains no tool rows at all")
        }
        if toolStatuses.contains(where: { $0 == .inProgress || $0 == .pending }) {
            throw fail(
                "real claude turn: a tool row is still \(toolStatuses) after the COMPLETE "
                + "stream replayed — the projection dropped a completion it was given."
            )
        }

        let (_, views) = try render(.realClaudeTurn)
        let toolViews = views.compactMap { $0 as? ToolCallView }
        guard toolViews.count >= 2 else {
            throw fail(
                "real claude turn: expected the ToolSearch and WebSearch rows to render, "
                + "found \(toolViews.count) tool view(s)"
            )
        }

        // 1. "WE NEED MORE DETAILS" — the WebSearch row must show its QUERY,
        //    not the operation gerund. The capture's tool_use carries
        //    input.query = "recent sports headline August 2026"; today the
        //    translator throws it away (C1) and the host then overwrites the
        //    tool name with "searching" (C2a).
        let renderedToolText = toolViews.map {
            "\($0.titleLabel.stringValue) \($0.summaryLabel.stringValue) \($0.statusLabel.stringValue)"
        }
        guard renderedToolText.contains(where: { $0.localizedCaseInsensitiveContains("recent sports headline") }) else {
            throw fail(
                "real claude turn: no tool row shows the search QUERY. Rendered rows: "
                + "\(renderedToolText). The stream carries input.query verbatim; the row must "
                + "read action-first (\"Searched for …\"), not as a bare tool label."
            )
        }

        // 2. "is the turn being tracked for the proper amount of time???" —
        //    thinking spans exist in the document (createdAt supply shipped in
        //    T1), so at least one reasoning row must say "Thought for", not the
        //    bare base title (C5b: production passes the default nil closure).
        let reasoningTitles = views
            .compactMap { $0 as? CompletedReasoningDisclosureView }
            .map(\.titleLabel.stringValue)
        guard reasoningTitles.contains(where: { $0.hasPrefix("Thought for") }) else {
            let entrySummary = replay.document.entries.map {
                "\($0.role)/\($0.lifecycle)/\($0.blocks.count)b"
            }.joined(separator: ", ")
            throw fail(
                "real claude turn: no reasoning row shows its duration — titles \(reasoningTitles). "
                + "Entries: [\(entrySummary)]. The document carries createdAt spans; "
                + "authoritativeReasoningDuration must derive from them."
            )
        }

        // 3. A settled tool row must carry a duration suffix ("2.1s ✓" column).
        let durationPattern = try NSRegularExpression(pattern: "\\d+(\\.\\d+)?s\\b")
        let showsDuration = renderedToolText.contains {
            durationPattern.firstMatch(
                in: $0, range: NSRange($0.startIndex..., in: $0)
            ) != nil
        }
        guard showsDuration else {
            throw fail(
                "real claude turn: no tool row shows a duration. Rendered rows: "
                + "\(renderedToolText). The detail store already knows how to say "
                + "\"Duration: Ns\"; nothing feeds or renders it."
            )
        }

        // 3b. A row must not repeat itself. The action sentence carries the
        //     query; an argument line underneath saying "query: <the same
        //     thing>" is noise, and it appeared under EVERY tool row of the
        //     real turn until the presenter suppressed it.
        for tool in toolViews {
            let title = tool.titleLabel.stringValue
            let detail = tool.summaryLabel.stringValue
            guard !detail.isEmpty else { continue }
            for line in detail.split(whereSeparator: { $0.isNewline }).map(String.init) {
                guard let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 4 else { continue }
                guard !title.contains(trimmed) else {
                    throw fail(
                        "real claude turn: the row says '\(title)' and then repeats the same value "
                        + "underneath as '\(line)' — the disclosure must add facts, not echo the sentence"
                    )
                }
            }
        }

        // 4. The expanded pane (`.plans/45` S4.2): expanding the WebSearch row
        //    must reveal the RESULT text through the command-output machinery
        //    (real selection + copy), fed from the store — the document itself
        //    carries no output (I5), so this can only pass through the
        //    host-local presentation path.
        let searchBinding = replay.entryBindings.first { binding in
            replay.toolDetails[binding.identity]?.arguments
                .contains { $0.value.text.localizedCaseInsensitiveContains("recent sports headline") } == true
        }
        guard let searchBinding,
              let searchEntry = replay.document.entries.first(where: { $0.id == searchBinding.entryID }),
              let searchBlockID = searchEntry.blocks.first(where: {
                  if case .toolCall = $0.payload { return true } else { return false }
              })?.id else {
            throw fail("real claude turn: the WebSearch entry/binding is missing from the replay")
        }
        let (expandSurface, _) = try render(.realClaudeTurn)
        let expandList = expandSurface.transcript
        guard expandList.qaPerformToolDisclosureClick(for: searchBlockID) else {
            throw fail("real claude turn: the WebSearch row offered no disclosure to expand")
        }
        expandList.layoutSubtreeIfNeeded()
        expandList.collectionView.layoutSubtreeIfNeeded()
        func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let expandedTool = descendants(in: expandSurface)
            .compactMap { $0 as? ToolCallView }
            .first { !$0.outputScrollView.isHidden }
        guard let expandedTool, expandedTool.outputTextView.string.count > 40 else {
            throw fail(
                "real claude turn: expanding the search row revealed no output pane — the "
                + "result preview is in the store but never reaches the expanded presentation"
            )
        }

        // The replayed turn's tools are separated by reasoning rows, so they
        // must NOT cluster — a run never crosses a non-tool row.
        guard replay.document.entries.isEmpty == false,
              expandList.qaClusterHeaderCountForChecks == 0 else {
            throw fail(
                "real claude turn: \(expandList.qaClusterHeaderCountForChecks) cluster header(s) "
                + "appeared though every tool row is separated by reasoning"
            )
        }
    }

    // MARK: - Dylan's 2026-08-24 review

    /// Every FILLED surface must inset its own text horizontally.
    ///
    /// The user bubble painted its fill from x=0 and laid its prose out from
    /// x=0 too, so the first glyph sat against the corner radius — the one
    /// thing Dylan could see in the gallery. Asserted for every filled
    /// renderer view, in one shared coordinate space, because "the bubble is
    /// padded" is a property of the class of filled surfaces and a new one
    /// would otherwise repeat the bug.
    private static func checkFilledSurfacesPadTheirText() throws {
        for state in [AgentTranscriptReviewState.mixed, .realClaudeTurn, .turnBoundary] {
            let (surface, views) = try render(state)
            let space = surface.transcript.collectionView
            for view in views {
                guard let colour = view.layer?.backgroundColor, colour.alpha > 0.01 else { continue }
                let isFilledContentSurface = view is UserPromptView || view is CodeBlockView
                    || view is AgentPlanView || view is AgentDiffSummaryView
                    || view is AgentRequestView || view is CommandOutputView
                guard isFilledContentSurface else { continue }
                let fill = view.convert(view.bounds, to: space)
                guard fill.width > 1 else { continue }
                // An NSTextView carries its own padding as textContainerInset,
                // which its BOUNDS include — measuring the frame alone reports a
                // padded code block as flush. Offset to the first glyph's origin.
                let texts = descendantTextViews(of: view).compactMap { text -> (CGFloat, String)? in
                    // A hidden or empty label keeps whatever frame it last had
                    // (often .zero) and is not on screen — it cannot be the
                    // gutter. Only VISIBLE text with content counts.
                    guard !text.isHiddenOrHasHiddenAncestor else { return nil }
                    if let field = text as? NSTextField,
                       field.stringValue.isEmpty, field.attributedStringValue.length == 0 { return nil }
                    if let textView = text as? NSTextView, textView.string.isEmpty { return nil }
                    let rect = text.convert(text.bounds, to: space)
                    guard rect.width > 1 else { return nil }
                    // An NSTextView carries its own padding as textContainerInset,
                    // which its BOUNDS include — measuring the frame alone reports
                    // a padded code block as flush.
                    if let textView = text as? NSTextView {
                        return (rect.minX + textView.textContainerInset.width
                            + (textView.textContainer?.lineFragmentPadding ?? 0),
                            "\(type(of: text))")
                    }
                    return (rect.minX, "\(type(of: text)):'\(((text as? NSTextField)?.stringValue ?? "").prefix(24))'")
                }
                guard let leftmost = texts.min(by: { $0.0 < $1.0 }) else { continue }
                let padding = leftmost.0 - fill.minX
                guard padding >= CGFloat(Space.s) else {
                    throw fail(
                        "\(state.rawValue): \(type(of: view)) paints a fill from \(fill.minX) but its "
                        + "text starts at \(leftmost.0) (\(leftmost.1)) — only \(padding)pt of gutter. "
                        + "A filled surface must inset its own text, or the first glyph sits on the "
                        + "corner radius."
                    )
                }
            }
        }
    }

    private static func descendantTextViews(of view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ candidate: NSView) {
            if candidate is NSTextField || candidate is NSTextView { found.append(candidate) }
            candidate.subviews.forEach(walk)
        }
        view.subviews.forEach(walk)
        return found
    }

    /// The change summary must read as a DIFFSTAT, not as a panel: the counts
    /// carry their own colours, the digits are monospaced so columns line up,
    /// and the whole card stays dense enough that two changed files do not cost
    /// a third of the viewport.
    private static func checkDiffStatDensity() throws {
        let (_, views) = try render(.mixed)
        guard let diff = views.compactMap({ $0 as? AgentDiffSummaryView }).first else {
            throw fail("diffstat: the mixed fixture rendered no diff summary")
        }
        guard diff.fileStatLabels.count == diff.fileLabels.count, !diff.fileLabels.isEmpty else {
            throw fail(
                "diffstat: \(diff.fileLabels.count) name label(s) but "
                + "\(diff.fileStatLabels.count) stat label(s) — every file row owns both"
            )
        }
        // Additions and removals are DIFFERENT colours in one run: a single
        // concatenated string cannot satisfy this.
        var colours: Set<String> = []
        for stat in diff.fileStatLabels {
            let attributed = stat.attributedStringValue
            guard attributed.length > 0 else {
                throw fail("diffstat: a stat label rendered empty")
            }
            attributed.enumerateAttribute(
                .foregroundColor, in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if let colour = (value as? NSColor)?.cgColor.hexForChecks { colours.insert(colour) }
            }
            guard attributed.string.contains("+"), attributed.string.contains("\u{2212}") else {
                throw fail("diffstat: a stat label lost its +/− counts: '\(attributed.string)'")
            }
        }
        guard colours.count >= 2 else {
            throw fail(
                "diffstat: additions and removals render in \(colours.count) colour(s) "
                + "(\(colours.sorted())) — a diffstat distinguishes them"
            )
        }
        // No stat may be CLIPPED. The first cut measured intrinsicContentSize on
        // a field built from an empty string, which under-reported the width and
        // silently dropped the removal count — visible only by looking at the
        // render. Assert the frame fits the string it was given.
        for stat in diff.fileStatLabels {
            let needed = ceil(stat.attributedStringValue.size().width)
            guard stat.frame.width + 0.5 >= needed else {
                throw fail(
                    "diffstat: the stat label is \(stat.frame.width)pt wide but its text "
                    + "'\(stat.attributedStringValue.string)' needs \(needed)pt — the counts are clipped"
                )
            }
        }
        // The proportional bar exists and is actually proportioned.
        guard diff.fileStatBars.count == diff.fileLabels.count,
              diff.fileStatBars.allSatisfy({ $0.addedShare > 0 && $0.addedShare <= 1 }) else {
            throw fail(
                "diffstat: expected one proportional bar per file with a real share, got "
                + "\(diff.fileStatBars.map(\.addedShare))"
            )
        }
        // Density: the card must not spend more than ~34pt per changed file
        // once its header, summary line and action row are accounted for.
        let perFile = diff.bounds.height / CGFloat(max(1, diff.fileLabels.count))
        guard perFile <= 60 else {
            throw fail(
                "diffstat: \(diff.bounds.height)pt of card for \(diff.fileLabels.count) file(s) "
                + "(\(perFile)pt each) — the summary is heavier than the change it summarizes"
            )
        }
    }

    // MARK: - S4.3

    /// Dylan's design 2: consecutive settled tool rows fold to one line;
    /// failures never fold; expanding restores the individual rows. Driven on
    /// `.recededWork`, whose fixture is three consecutive settled tools
    /// followed by a failed one.
    private static func checkClustering() throws {
        let (surface, views) = try render(.recededWork)
        let list = surface.transcript
        if let mismatch = list.qaClusterProjectionMismatch() {
            throw fail("clustering: projection/snapshot mismatch: \(mismatch)")
        }
        let headerIDs = list.qaClusterHeaderIDsForChecks
        guard headerIDs.count == 1, let headerID = headerIDs.first else {
            throw fail(
                "clustering: expected the three consecutive settled tools to fold under ONE "
                + "header, got \(headerIDs.count)"
            )
        }
        let headers = views.compactMap { $0 as? AgentToolClusterHeaderView }
        guard let header = headers.first else {
            throw fail("clustering: the header item never rendered")
        }
        let summary = header.summaryLabel.stringValue
        guard summary.range(of: #"^\d+ steps"#, options: .regularExpression) != nil,
              summary.hasSuffix("✓") else {
            throw fail(
                "clustering: the folded line must read 'N steps ... ✓', got '\(summary)'"
            )
        }

        // The failure renders as a plain row, outside any fold.
        let plainTools = views.compactMap { $0 as? ToolCallView }
        guard plainTools.contains(where: { $0.statusLabel.stringValue.contains("Failed") }) else {
            throw fail("clustering: the failed tool must stay a plain, legible row — it folded")
        }
        let collapsedSnapshotCount = list.qaSnapshotItemCountForChecks

        // Expanding restores the individual rows (and survives settling via the
        // disclosure store); collapsing folds them again.
        list.qaToggleClusterForChecks(headerID)
        list.layoutSubtreeIfNeeded()
        list.collectionView.layoutSubtreeIfNeeded()
        if let mismatch = list.qaClusterProjectionMismatch() {
            throw fail("clustering: projection/snapshot mismatch after expand: \(mismatch)")
        }
        guard list.qaSnapshotItemCountForChecks == collapsedSnapshotCount + 3 else {
            throw fail(
                "clustering: expanding must restore the 3 member rows to the snapshot, went "
                + "\(collapsedSnapshotCount) -> \(list.qaSnapshotItemCountForChecks)"
            )
        }
        list.qaToggleClusterForChecks(headerID)
        list.layoutSubtreeIfNeeded()
        guard list.qaSnapshotItemCountForChecks == collapsedSnapshotCount else {
            throw fail("clustering: collapsing did not restore the folded snapshot")
        }
        if let mismatch = list.qaClusterProjectionMismatch() {
            throw fail("clustering: projection/snapshot mismatch after collapse: \(mismatch)")
        }
        // The semantic model is untouched by all of this: rows == flatten.
        guard list.qaSemanticRowCount >= 6 else {
            throw fail("clustering: the semantic row count changed — the projection leaked into rows")
        }
    }
}

extension CGColor {
    /// Stable hex for witness messages. Witnesses compare treatments, so the
    /// exact string matters less than two different colours never colliding.
    var hexForChecks: String {
        guard let converted = converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ), let c = converted.components, c.count >= 3 else {
            return "unconvertible"
        }
        let a = converted.numberOfComponents >= 4 ? c[3] : 1
        return String(
            format: "#%02X%02X%02X%02X",
            Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()),
            Int((c[2] * 255).rounded()), Int((a * 255).rounded())
        )
    }
}
