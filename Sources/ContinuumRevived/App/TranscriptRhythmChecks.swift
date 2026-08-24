import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
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

    /// A1's vacuity floor for `checkFilledSurfacesPadTheirText`, measured
    /// across `.mixed` + `.realClaudeTurn` + `.turnBoundary` after
    /// `UserPromptView` stopped being a filled surface: `mixed=3,
    /// real-claude-turn=0, turn-boundary=0` (neither replayed state authors a
    /// code/diff/plan/approval/command block). Floored AT the measured total,
    /// the program's convention. Re-measure if a fixture's filled-artifact mix
    /// changes; a floor left stale in either direction defeats the point (too
    /// high goes red for no reason, too low stops measuring anything).
    private static let minimumFilledSurfacesExamined = 3

    static func run() throws {
        try checkUserTurnIsRuledNotFilled()
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
        try checkDiffSummaryReusesFileRows()
        try checkDiffBodyRendersInline()
        try checkReasoningExpands()
        try checkRowsShareOneTextColumn()
        try checkLiveDocumentsCarryTimestamps()
        try checkMotionIsPresentationOnly()
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
        // A1: `UserPromptView.proseView` IS an `AssistantProseView` instance (the
        // renderer is shared), so the old unqualified `AssistantProseView` sweep
        // silently included the user turn's prose too. That is why this used to
        // pass without asserting anything about the user surface: the MINIMUM
        // over both happened to still be the assistant's, and the user turn's
        // own leading edge only moved from 24 to 22 with nothing here to notice.
        // Split by owner and assert each edge on purpose.
        let assistantProseX = mixed.compactMap { $0 as? AssistantProseView }
            .filter { !($0.superview is UserPromptView) }
            .flatMap(\.textFields)
            .map { $0.convert($0.bounds, to: space).minX }
            .min()
        let userProseX = mixed.compactMap { $0 as? UserPromptView }
            .flatMap { $0.proseView.textFields }
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
        if let assistantProseX, let fillX, abs(assistantProseX - fillX) > 0.5 {
            throw fail(
                "left edges: assistant prose text starts at \(assistantProseX) but the nearest "
                + "artifact fill starts at \(fillX). AssistantProseView.horizontalReadingInset is "
                + "added ON TOP of the layout's own contentInsets.left, so card edges and prose "
                + "never share an edge."
            )
        }
        // A1: the user turn no longer shares the assistant's leading edge — it
        // sits past its own authorship rule instead, at the row's content
        // edge (the same edge an artifact fill starts at) plus
        // `UserPromptView.leadingInset`.
        if let userProseX, let fillX,
           abs(userProseX - (fillX + UserPromptView.leadingInset)) > 0.5 {
            throw fail(
                "left edges: user prose text starts at \(userProseX), expected the row's leading "
                + "edge (\(fillX)) plus UserPromptView.leadingInset (\(UserPromptView.leadingInset)) "
                + "= \(fillX + UserPromptView.leadingInset)"
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

    // MARK: - A1

    /// `.plans/45` A1 — Dylan's decision, replayed: the user turn loses its
    /// card entirely (no fill, no rounded corner) and keeps only a
    /// `LineWidth.rule`-wide `AgentLineRole.authorship` rule down the left
    /// edge. This is the check that MUST gate the redesign: `--component-lab-check`
    /// and `--ui-baseline-check` are both `MATRIX_KNOWN_RED`, so an assertion
    /// added to either of those reads as coverage and never actually runs.
    ///
    /// Exercised over three states on purpose: `.mixed` (the ordinary single
    /// turn), `.realClaudeTurn` (a real capture through the real translator,
    /// not authored prose), and `.turnBoundary` (which — S4.0 — renders two
    /// CONSECUTIVE user prompts with real `AgentTranscriptLayout.interTurnSpacing`
    /// between them, so the same assertion also proves two rules never merge
    /// into one continuous line).
    private static func checkUserTurnIsRuledNotFilled() throws {
        for state: AgentTranscriptReviewState in [.mixed, .realClaudeTurn, .turnBoundary] {
            for theme: TokenTheme in [.light, .dark] {
                let (_, views) = try render(state, theme: theme)
                let userViews = views.compactMap { $0 as? UserPromptView }
                guard !userViews.isEmpty else {
                    throw fail(
                        "\(state.rawValue)/\(theme.rawValue): no UserPromptView rendered — the "
                        + "fixture or the role-aware registry stopped producing one"
                    )
                }
                let expectedHex = AgentLineRole.authorship.color.cgColor(for: theme).hexForChecks
                for user in userViews {
                    // 1. No fill left. Comparing to `nil`, not `.clear` — a
                    //    painted transparent is an unregistered literal to the
                    //    appearance census (CLAUDE.md hazard 8).
                    guard user.layer?.backgroundColor == nil else {
                        throw fail(
                            "\(state.rawValue)/\(theme.rawValue): a user turn still paints a "
                            + "background fill — the card was supposed to be removed entirely"
                        )
                    }
                    // 2. Exactly one rule subview, at bounds.minX, LineWidth.rule
                    //    wide, full row height.
                    let ruleLayers = user.qaTokenPaintedLayers
                    guard ruleLayers.count == 1 else {
                        throw fail(
                            "\(state.rawValue)/\(theme.rawValue): expected exactly one authorship "
                            + "rule subview, found \(ruleLayers.count)"
                        )
                    }
                    let ruleFrame = ruleLayers[0].layer.frame
                    guard abs(ruleFrame.minX - user.bounds.minX) <= 0.01,
                          abs(ruleFrame.width - CGFloat(LineWidth.rule)) <= 0.01,
                          abs(ruleFrame.height - user.bounds.height) <= 0.5 else {
                        throw fail(
                            "\(state.rawValue)/\(theme.rawValue): the authorship rule is not a full "
                            + "row-height, LineWidth.rule-wide stripe at bounds.minX — got \(ruleFrame) "
                            + "against row bounds \(user.bounds)"
                        )
                    }
                    // 3. The rule's resolved colour is AgentLineRole.authorship,
                    //    in THIS appearance.
                    guard ruleLayers[0].layer.backgroundColor?.hexForChecks == expectedHex else {
                        throw fail(
                            "\(state.rawValue)/\(theme.rawValue): the rule painted "
                            + "\(ruleLayers[0].layer.backgroundColor?.hexForChecks ?? "nil"), expected "
                            + "AgentLineRole.authorship (\(expectedHex))"
                        )
                    }
                    // 4. The leftmost prose glyph sits at rule.maxX + Space.m —
                    //    `AssistantProseRenderer.horizontalReadingInset == 0`, so
                    //    the shared text column IS the row's leading edge; there
                    //    is no interior margin to hang the rule in.
                    let expectedGlyphX = ruleFrame.maxX + CGFloat(Space.m)
                    let leftmostGlyphX = user.proseView.textFields.map {
                        $0.convert($0.bounds, to: user).minX
                    }.min()
                    guard let leftmostGlyphX, abs(leftmostGlyphX - expectedGlyphX) <= 0.5 else {
                        throw fail(
                            "\(state.rawValue)/\(theme.rawValue): leftmost prose glyph is at "
                            + "\(String(describing: leftmostGlyphX)), expected rule.maxX + Space.m "
                            + "(\(expectedGlyphX))"
                        )
                    }
                }
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
        // A1: the user turn lost its fill, so it is no longer a filled content
        // surface at all — leaving it in the list below was a lie the `alpha >
        // 0.01` guard already hid (a `nil` background never reaches the type
        // check). Removed rather than left as dead coverage.
        //
        // Its removal also shrinks how many filled surfaces this loop actually
        // examines per state, which is exactly the failure mode a coverage
        // check like this one can have without anyone noticing: every clause
        // inside the loop can stay green by never running. A floor on the
        // count examined is the general cure.
        var examinedPerState: [AgentTranscriptReviewState: Int] = [:]
        for state in [AgentTranscriptReviewState.mixed, .realClaudeTurn, .turnBoundary] {
            let (surface, views) = try render(state)
            let space = surface.transcript.collectionView
            var examined = 0
            for view in views {
                guard let colour = view.layer?.backgroundColor, colour.alpha > 0.01 else { continue }
                let isFilledContentSurface = view is CodeBlockView
                    || view is AgentPlanView || view is AgentDiffSummaryView
                    || view is AgentRequestView || view is CommandOutputView
                guard isFilledContentSurface else { continue }
                let fill = view.convert(view.bounds, to: space)
                guard fill.width > 1 else { continue }
                examined += 1
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
            examinedPerState[state] = examined
        }
        // The vacuity floor: every clause above can stay green forever by
        // simply never running, which is what removing `UserPromptView`
        // (correctly) just did to `.turnBoundary` — it authors no code/diff/
        // plan/approval/command block, so it now examines ZERO filled
        // surfaces. Gate the TOTAL rather than pretend every state must
        // examine something it does not carry.
        let totalExamined = examinedPerState.values.reduce(0, +)
        guard totalExamined >= minimumFilledSurfacesExamined else {
            throw fail(
                "filled-surface padding: examined \(totalExamined) filled surface(s) across "
                + "\(examinedPerState.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ", ")), "
                + "floor is \(minimumFilledSurfacesExamined) — this check can pass by never running"
            )
        }
    }

    /// "expanding thoughts DO NOT WORK ... it has some weird ass artifacting."
    ///
    /// Clicking a completed-reasoning row's REAL control must grow the row and
    /// keep the body inside it. The body is clipped to the collection item, so
    /// a toggle that flips the view's state without remeasuring the row renders
    /// the thinking text over its neighbours — which is what the artifacting
    /// was.
    private static func checkReasoningExpands() throws {
        let (surface, _) = try render(.realClaudeTurn)
        let list = surface.transcript
        let reasoningEntries = LabFixtures.realClaudeTurn.document.entries
            .filter { $0.role == .reasoning && !$0.blocks.isEmpty }
        guard let entry = reasoningEntries.first else {
            throw fail("reasoning expand: the replayed turn carries no completed reasoning entry")
        }
        guard let heights = list.qaPerformReasoningDisclosureClick(for: entry.id) else {
            throw fail("reasoning expand: no reasoning disclosure was installed for \(entry.id.rawValue)")
        }
        guard heights.after > heights.before + 1 else {
            throw fail(
                "reasoning expand: the row measured \(heights.before)pt collapsed and "
                + "\(heights.after)pt after clicking its disclosure — the toggle changed the view's "
                + "state without remeasuring the row, so the thinking text has nowhere to draw"
            )
        }
        // The body must be laid out at the row's real width. A 1pt-wide body
        // is what produced the vertical dashed artifacts: one glyph per line,
        // an enormous measured height, and nothing readable.
        if let geometry = list.qaReasoningBodyGeometryForChecks(for: entry.id) {
            guard geometry.hostWidths.allSatisfy({ $0 > geometry.viewWidth * 0.5 }) else {
                throw fail(
                    "reasoning expand: the body was laid out at \(geometry.hostWidths) inside a "
                    + "\(geometry.viewWidth)pt row (container \(geometry.containerWidth)pt) — a "
                    + "collapsed body renders as vertical dashes, not text. "
                    + (list.qaReasoningBodyDiagnosticForChecks(for: entry.id) ?? "no diagnostic")
                )
            }
        }
        let overflow = list.qaReasoningBodyOverflowForChecks(for: entry.id) ?? 0
        guard overflow <= 0.5 else {
            throw fail(
                "reasoning expand: the expanded body overflows its row by \(overflow)pt — it is "
                + "drawing over whatever follows it"
            )
        }
    }

    /// "the spacing is still so WEIRD."
    ///
    /// Every row KIND must start its text on one x. A reasoning row reserved a
    /// disclosure column but no icon column, so thoughts sat 32pt left of the
    /// searches between them, and a tool row without a disclosure control
    /// shifted left of the ones with it. Neither is visible in a single row —
    /// only in a column of them.
    private static func checkRowsShareOneTextColumn() throws {
        let (surface, views) = try render(.realClaudeTurn)
        let space = surface.transcript.collectionView
        var columns: [String: Set<CGFloat>] = [:]
        for tool in views.compactMap({ $0 as? ToolCallView }) {
            let x = (tool.titleLabel.convert(tool.titleLabel.bounds, to: space).minX * 2).rounded() / 2
            columns["tool", default: []].insert(x)
        }
        for reasoning in views.compactMap({ $0 as? CompletedReasoningDisclosureView }) {
            let x = (reasoning.titleLabel.convert(reasoning.titleLabel.bounds, to: space).minX * 2).rounded() / 2
            columns["reasoning", default: []].insert(x)
        }
        guard !columns.isEmpty else {
            throw fail("text column: the replayed turn rendered neither a tool nor a reasoning row")
        }
        for (kind, xs) in columns where xs.count > 1 {
            throw fail("text column: \(kind) rows start their text at \(xs.sorted()) — one kind, several columns")
        }
        let distinct = Set(columns.values.flatMap { $0 })
        guard distinct.count == 1 else {
            throw fail(
                "text column: row kinds start their text at \(distinct.sorted()) — "
                + "\(columns.mapValues { $0.sorted() }). Every kind shares one text column."
            )
        }
    }

    /// A LIVE transcript must carry entry timestamps. The tile built its
    /// projection through the injected-clock initializer, whose wall clock
    /// defaults to nil, so every live entry had no `createdAt`: no "Thought for
    /// Ns" and no hover-revealed send time on anything the user had done —
    /// while every fixture, which passes its own clock, looked correct.
    private static func checkLiveDocumentsCarryTimestamps() throws {
        var model = ManagedAgentTranscriptModel(threadId: "live-clock", monotonicNow: { 0 })
        model.appendUserPrompt("does a live entry know when it happened")
        guard let entry = model.document.entries.first else {
            throw fail("live timestamps: appending a prompt produced no entry")
        }
        guard entry.createdAt != nil else {
            throw fail(
                "live timestamps: a production transcript model stamped no createdAt — the tile is "
                + "using the injected-clock initializer, so nothing in a live transcript can show "
                + "when it happened"
            )
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

    // MARK: - A2

    /// `AgentDiffSummaryView.apply` tore down and rebuilt every file-name/stat/
    /// bar row on EVERY apply (`rebuildFileLabels`) and `layout()` measured
    /// each stat label's `attributedStringValue.size()` on every display cycle
    /// -- `performance.md` traps 1, 2 and 3 together, multiplied by up to
    /// `maximumVisibleFiles` rows. This drives the real `apply`/`layout` entry
    /// points directly -- the same ones `DiffSummaryRenderer` calls -- across
    /// repeated applies and repeated no-op layout passes, and counts the WORK,
    /// never the wall clock: subviews created, stat measurements taken, frames
    /// actually written.
    private static func checkDiffSummaryReusesFileRows() throws {
        let view = AgentDiffSummaryView()
        let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        func files(_ count: Int) -> [AgentDiffFileSummary] {
            (0..<count).map {
                AgentDiffFileSummary(displayName: "file\($0).swift", addedLineCount: UInt($0 + 1), removedLineCount: UInt($0))
            }
        }
        func apply(_ count: Int) {
            view.apply(
                blockID: AgentNodeID(rawValue: "diff-1")!,
                payload: AgentDiffPayload(text: "", files: files(count), canOpenReview: false),
                context: context
            )
        }

        // First apply: five files. Building the pool for the first time is
        // allowed to create five rows.
        apply(5)
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        view.layout()
        guard view.qaFileViewsCreatedForChecks == 5 else {
            throw fail(
                "diff-summary reuse: the first apply of 5 files created "
                + "\(view.qaFileViewsCreatedForChecks) row view(s), expected 5"
            )
        }

        // Re-applying the SAME five files must create zero new views and must
        // not re-measure a stat label whose file summary did not change.
        view.qaResetCountersForChecks()
        apply(5)
        guard view.qaFileViewsCreatedForChecks == 0 else {
            throw fail(
                "diff-summary reuse: an unchanged apply created "
                + "\(view.qaFileViewsCreatedForChecks) new row view(s) -- rebuildFileLabels is "
                + "still tearing down and rebuilding every apply"
            )
        }
        guard view.qaStatMeasurementsForChecks == 0 else {
            throw fail(
                "diff-summary reuse: an unchanged apply re-measured "
                + "\(view.qaStatMeasurementsForChecks) stat label(s) that did not change"
            )
        }

        // Growing to eight files must create exactly three MORE views, not
        // eight new ones.
        view.qaResetCountersForChecks()
        apply(8)
        guard view.qaFileViewsCreatedForChecks == 3 else {
            throw fail(
                "diff-summary reuse: growing from 5 to 8 files created "
                + "\(view.qaFileViewsCreatedForChecks) row view(s), expected 3 (the pool should "
                + "grow by the difference, not rebuild)"
            )
        }

        // Shrinking back to five must create zero new views -- the pool holds
        // the surplus, hidden, rather than tearing anything down.
        view.qaResetCountersForChecks()
        apply(5)
        guard view.qaFileViewsCreatedForChecks == 0 else {
            throw fail(
                "diff-summary reuse: shrinking to 5 files created "
                + "\(view.qaFileViewsCreatedForChecks) new row view(s) instead of hiding the surplus"
            )
        }
        guard view.fileLabels.count == 8 else {
            throw fail(
                "diff-summary reuse: the pool shrank to \(view.fileLabels.count) view(s) instead "
                + "of hiding the surplus 3 (a shrink-then-regrow would recreate them)"
            )
        }

        // Ten no-op layout passes on unchanged content must write zero frames
        // and take zero further measurements -- performance.md traps 2 and 3.
        view.qaResetCountersForChecks()
        for _ in 0..<10 {
            view.needsLayout = true
            view.layout()
        }
        guard view.qaFrameWritesForChecks == 0 else {
            throw fail(
                "diff-summary reuse: \(view.qaFrameWritesForChecks) frame write(s) across 10 "
                + "unchanged layout passes -- frames are assigned unconditionally"
            )
        }
        guard view.qaStatMeasurementsForChecks == 0 else {
            throw fail(
                "diff-summary reuse: \(view.qaStatMeasurementsForChecks) stat measurement(s) "
                + "across 10 unchanged layout passes -- layout() is measuring text"
            )
        }
    }

    // MARK: - A3

    /// `AgentDiffPayload.text` carries the raw unified diff and, before this
    /// ticket, was parsed and shown nowhere -- only the safe file summary
    /// rendered. This drives `AgentDiffSummaryView.apply`/`layout` directly
    /// with a REAL unified diff (every other diff fixture in this file and in
    /// `ComponentLab` uses opaque/malformed compatibility text on purpose, to
    /// prove raw text is never dumped verbatim -- this one proves the parsed
    /// structure DOES render). Asserts: added/removed lines carry the right
    /// tokens in both appearances, the body truncates at
    /// `AgentDiffSummaryView.bodyMaxLines` with the correct "+N more lines"
    /// affordance, and re-applying the identical (blockID, revision) creates
    /// zero new body views and re-parses zero times -- extending the same
    /// work-counting shape `checkDiffSummaryReusesFileRows` (A2) established,
    /// per `performance.md` traps 1-3 one layer up: the diff body itself.
    private static func checkDiffBodyRendersInline() throws {
        // 40 added lines: bodyMaxLines (30) leaves room for the leading context
        // + deletion line and 28 of the 40 additions, so the overflow must read
        // "+12 more lines" (42 hunk lines total, 30 shown).
        let addedLines = (1...40).map { "+added line \($0)" }.joined(separator: "\n")
        let diffText = """
        diff --git a/Sample.swift b/Sample.swift
        index aaaaaaa..bbbbbbb 100644
        --- a/Sample.swift
        +++ b/Sample.swift
        @@ -1,2 +1,41 @@
         context line
        -removed line
        \(addedLines)
        """
        let blockID = AgentNodeID(rawValue: "diff-body-1")!
        AgentDiffSummaryView.qaResetDiffParseCacheForChecks()

        func makeContext(appearance: TokenTheme) -> AgentRenderContext {
            AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: appearance)
        }
        let payload = AgentDiffPayload(
            text: diffText, summary: "Sample change",
            files: [.init(displayName: "Sample.swift", addedLineCount: 40, removedLineCount: 1)],
            canOpenReview: false
        )

        let view = AgentDiffSummaryView()
        // Off-window: `effectiveTokenTheme` (which the view's colouring uses,
        // matching `applyTokens`/`syncFileRows`) reads the real AppKit
        // appearance, not `context.appearance` — force it, the same way
        // `UIProbeGeometry`/`ComponentLab` do for an offline theme sweep.
        view.appearance = NSAppearance(named: .darkAqua)
        view.apply(blockID: blockID, revision: 1, payload: payload, context: makeContext(appearance: .dark))
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 1400)
        view.layout()

        guard let body = view.bodyTextView, !body.isHidden else {
            throw fail("diff body: no inline body view appeared for a real unified diff")
        }
        guard body.string.contains("added line 28\n") || body.string.hasSuffix("added line 28"),
              !body.string.contains("added line 29") else {
            throw fail(
                "diff body: did not truncate at \(AgentDiffSummaryView.bodyMaxLines) shown lines "
                + "(expected line 28 present, 29 absent)"
            )
        }
        guard !view.bodyOverflowLabel.isHidden, view.bodyOverflowLabel.stringValue == "+12 more lines" else {
            throw fail(
                "diff body: overflow affordance wrong, got '\(view.bodyOverflowLabel.stringValue)' "
                + "hidden=\(view.bodyOverflowLabel.isHidden)"
            )
        }
        guard view.qaDiffBodyViewsCreatedForChecks == 1 else {
            throw fail("diff body: first apply should allocate exactly one body view, got \(view.qaDiffBodyViewsCreatedForChecks)")
        }

        func foregroundColor(containing needle: String) throws -> NSColor {
            guard let range = body.string.range(of: needle) else {
                throw fail("diff body: expected substring '\(needle)' not found while checking colour")
            }
            let nsRange = NSRange(range, in: body.string)
            guard let color = body.textStorage?.attribute(.foregroundColor, at: nsRange.location, effectiveRange: nil) as? NSColor else {
                throw fail("diff body: no foreground colour attribute at '\(needle)'")
            }
            return color
        }

        for theme: TokenTheme in [.dark, .light] {
            // `AgentDiffSummaryView` colours the body via `effectiveTokenTheme`
            // (the view's real AppKit appearance), matching every other colour
            // in this view (`applyTokens`, `syncFileRows`) — not
            // `context.appearance`. Off-window, that has to be forced the same
            // way `UIProbeGeometry`/`ComponentLab` force it for a theme sweep.
            view.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            view.apply(blockID: blockID, revision: 1, payload: payload, context: makeContext(appearance: theme))
            view.layoutSubtreeIfNeeded()
            let addedColor = try foregroundColor(containing: "added line 1\n")
            let removedColor = try foregroundColor(containing: "removed line\n")
            let expectedAdded = AccentToken.accentDone.color.nsColor(for: theme)
            let expectedRemoved = AccentToken.accentFailed.color.nsColor(for: theme)
            guard addedColor.usingColorSpace(.sRGB) == expectedAdded.usingColorSpace(.sRGB) else {
                throw fail("diff body (\(theme)): added line did not carry the accentDone token colour")
            }
            guard removedColor.usingColorSpace(.sRGB) == expectedRemoved.usingColorSpace(.sRGB) else {
                throw fail("diff body (\(theme)): removed line did not carry the accentFailed token colour")
            }
        }

        // Re-applying the IDENTICAL (blockID, revision, theme) must create zero
        // new body views, re-render the attributed string zero times, and
        // re-parse the diff zero times -- the count witness the ticket asked
        // for, in the same shape as A2's file-row counters.
        view.qaResetCountersForChecks()
        let parsesBeforeRepeat = AgentDiffSummaryView.qaDiffParsesForChecks
        view.apply(blockID: blockID, revision: 1, payload: payload, context: makeContext(appearance: .light))
        guard view.qaDiffBodyViewsCreatedForChecks == 0 else {
            throw fail("diff body: an unchanged re-apply created \(view.qaDiffBodyViewsCreatedForChecks) new body view(s)")
        }
        guard view.qaDiffBodyRendersForChecks == 0 else {
            throw fail("diff body: an unchanged re-apply re-rendered the body \(view.qaDiffBodyRendersForChecks) time(s)")
        }
        guard AgentDiffSummaryView.qaDiffParsesForChecks == parsesBeforeRepeat else {
            throw fail(
                "diff body: an unchanged re-apply re-parsed the diff "
                + "(\(AgentDiffSummaryView.qaDiffParsesForChecks - parsesBeforeRepeat) more parse(s)) "
                + "-- the (blockID, revision) parse cache is not being hit"
            )
        }

        // Ten no-op layout passes at the same width must not re-measure the
        // body's bounding rect -- `performance.md` trap 2, one layer up from A2.
        view.layout()
        view.qaResetCountersForChecks()
        for _ in 0..<10 {
            view.needsLayout = true
            view.layout()
        }
        guard view.qaDiffBodyHeightMeasurementsForChecks == 0 else {
            throw fail(
                "diff body: \(view.qaDiffBodyHeightMeasurementsForChecks) bounding-rect "
                + "measurement(s) across 10 unchanged layout passes -- layout() is measuring "
                + "the body text instead of reusing bodyHeightCache"
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

    /// "Codex is so smooth and chill… what can we do to smooth out some of the
    /// transitions and jumps of state in the transcript."
    ///
    /// The transcript now animates, and the whole reason it is allowed to is
    /// that the animation never becomes state. This asserts all four halves of
    /// that bargain, because each one is a way the feature could quietly rot:
    ///
    /// 1. Off by default, so every pixel baseline and tour render photographs a
    ///    settled frame. An unconditional animation would make those flap, and a
    ///    flapping fixture is a bug, not a tolerance to widen.
    /// 2. Enabled, a real disclosure toggle DOES animate — the teeth. Without
    ///    this the other three pass on a feature that does nothing.
    /// 3. The model value is already final while the animation runs, which is
    ///    what lets `--ui-geometry-check` and the appearance census keep reading
    ///    settled values synchronously.
    /// 4. The first apply does not animate: a restored transcript's history must
    ///    not dissolve into view, which would be a worse jump than the one this
    ///    milestone set out to remove.
    private static func checkMotionIsPresentationOnly() throws {
        func runningAnimations(in views: [NSView]) -> [String] {
            views.compactMap { view in
                AgentTranscriptMotion.qaRunningOpacityAnimation(view) == nil
                    ? nil : String(describing: type(of: view))
            }
        }

        // 1 + 4. The production default is off, and even with motion ON the
        // first apply of a document is history, not arrival.
        for (label, enabled) in [("disabled", false), ("enabled", true)] {
            var views: [NSView] = []
            AgentTranscriptMotion.qaWithMotion(enabled: enabled) {
                views = (try? render(.realClaudeTurn).views) ?? []
            }
            guard !views.isEmpty else {
                throw fail("motion: the replayed turn rendered nothing with motion \(label)")
            }
            let animated = runningAnimations(in: views)
            guard animated.isEmpty else {
                throw fail(
                    "motion: rendering a document for the FIRST time animated \(animated) with "
                    + "motion \(label) — history must materialize settled, and every pixel "
                    + "baseline depends on a first render being motionless"
                )
            }
        }

        guard let entry = LabFixtures.realClaudeTurn.document.entries
            .first(where: { $0.role == .reasoning && !$0.blocks.isEmpty }) else {
            throw fail("motion: the replayed turn carries no completed reasoning entry")
        }

        /// Expands a reasoning disclosure on a FRESH surface, so the two cases
        /// below both exercise a first expansion rather than the second one
        /// collapsing what the first opened.
        func expandOnce(reducedMotion: Bool) throws
            -> (animation: CABasicAnimation?, opacity: Float, alpha: CGFloat) {
            let (surface, views) = try render(.realClaudeTurn)
            guard let disclosure = views.compactMap({ $0 as? CompletedReasoningDisclosureView })
                .first(where: { !$0.isHidden }) else {
                throw fail("motion: no reasoning disclosure rendered")
            }
            var result: (CABasicAnimation?, Float, CGFloat) = (nil, -1, -1)
            AgentTranscriptMotion.qaWithMotion(enabled: true, reducedMotion: reducedMotion) {
                _ = surface.transcript.qaPerformReasoningDisclosureClick(for: entry.id)
                result = (
                    AgentTranscriptMotion.qaRunningOpacityAnimation(disclosure.bodyContainer),
                    disclosure.bodyContainer.layer?.opacity ?? -1,
                    disclosure.bodyContainer.alphaValue
                )
            }
            return result
        }

        // 3a. Reduce-motion is honoured through the injected provider, so the
        //     setting is respected without the witness touching the real one.
        guard try expandOnce(reducedMotion: true).animation == nil else {
            throw fail(
                "motion: expanding a disclosure animated while reduce-motion was set — the "
                + "accessibility preference must suppress every transcript animation"
            )
        }

        // 2. The teeth: enabled, the same real control animates.
        let expanded = try expandOnce(reducedMotion: false)
        let settledOpacity = expanded.opacity
        let settledAlpha = expanded.alpha
        guard let animation = expanded.animation else {
            throw fail(
                "motion: expanding a reasoning disclosure with motion enabled ran no animation — "
                + "the body appears in one step, which is the jump this milestone removes"
            )
        }

        // 3. Presentation only. `toValue` is the settled model value and the
        //    model itself was never touched, so a gate reading opacity or
        //    alphaValue immediately after the toggle reads the final number.
        guard settledOpacity == 1, settledAlpha == 1 else {
            throw fail(
                "motion: mid-animation the body reads opacity \(settledOpacity) / alpha "
                + "\(settledAlpha) — the animation mutated the model, so every synchronous gate "
                + "now samples a transient value"
            )
        }
        guard (animation.toValue as? Float) == 1, (animation.fromValue as? Float) == 0 else {
            throw fail(
                "motion: the fade runs \(String(describing: animation.fromValue)) -> "
                + "\(String(describing: animation.toValue)); it must end on the value the model "
                + "already holds"
            )
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
