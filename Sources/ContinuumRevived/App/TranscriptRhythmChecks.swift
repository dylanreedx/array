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
        print(
            "TranscriptRhythmChecks: heading ladder, hanging indents, thematic break, "
            + "turn separation, error/notice divergence, table structure and surface fills"
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
        guard let widest = gaps.max(), let narrowest = gaps.min(), widest >= narrowest * 1.5 else {
            throw fail(
                "turn separation: the widest gap (\(gaps.max() ?? 0)) is not meaningfully larger "
                + "than the narrowest (\(gaps.min() ?? 0)); a turn boundary must read as a break, "
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
        list.qaHoverTurnForChecks(entryID: nil)
        guard !list.qaHoverTimeVisibleForChecks else {
            throw fail("hover time: visible with nothing hovered")
        }
        list.qaHoverTurnForChecks(entryID: stamped.id)
        guard list.qaHoverTimeVisibleForChecks else {
            throw fail(
                "hover time: hovering a turn that HAS a createdAt revealed nothing — the producer "
                + "landed in T1 but the reveal is not reading it"
            )
        }
        list.qaHoverTurnForChecks(entryID: unstamped.id)
        guard !list.qaHoverTimeVisibleForChecks else {
            throw fail(
                "hover time: a turn with NO createdAt revealed a time anyway. Every transcript "
                + "persisted before T1 decodes as nil; rendering one there puts a fabricated "
                + "timestamp on real history."
            )
        }
        list.qaHoverTurnForChecks(entryID: nil)
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
