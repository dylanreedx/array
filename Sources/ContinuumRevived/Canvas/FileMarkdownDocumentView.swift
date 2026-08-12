import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Read-only native Markdown document for a file tile.
///
/// It reuses Array's existing semantic pipeline — `MarkdownAgentMarkupParser` for
/// meaning, the registered block renderers for AppKit — and nothing else from the
/// agent transcript: no streaming identity reconciliation, no disclosure state, no
/// agent actions, no card chrome. `actions` is `.disabled`, so a link in a file is
/// visible, copyable, and accessible but activates nothing; the link policy still
/// classifies it. Unknown constructs (tables, raw HTML) fall through to the
/// registry's readable-source fallback rather than disappearing.
@MainActor
final class FileMarkdownDocumentView: NSView {
    /// Preview renders at most this many semantic blocks; see `BodyView`.
    static var maximumRenderedBlocks: Int { BodyView.maximumRenderedBlocks }

    private let scrollView = NSScrollView()
    private let body = BodyView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Overlay scrollers float above the content. A legacy scroller STEALS clip
        // width when it appears, which changes the document's width, which changes
        // its height, which can hide the scroller again — an oscillation that never
        // settles and re-measures every block each time round.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = body
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        // The document's height comes from `intrinsicContentSize`, never from
        // `setFrameSize` inside `layout()`. Sizing a view during its own layout
        // makes AppKit re-enter layout for that subtree: Dylan's 75-second hang was
        // 53 nested `_layoutSubtreeWithOldSize:` frames with the main thread inside
        // this view's `layout()` re-measuring prose every time round.
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            body.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Parses and renders a complete Markdown document. Cheap to call again: the
    /// tile keeps one loaded-text snapshot and only re-renders on a theme change.
    func apply(markdown: String, theme: TokenTheme) {
        body.apply(markdown: markdown, theme: theme)
    }

    func applyTheme(_ theme: TokenTheme) {
        body.applyTheme(theme)
    }

    // MARK: - QA introspection

    /// The laid-out block views, in document order.
    var qaBlockViews: [NSView] { body.blockViews }

    /// Every string the rendered document actually shows, walked out of the live
    /// view tree — not the parsed model. A block that parsed but never laid out
    /// contributes nothing here.
    func qaVisibleText() -> String {
        body.layoutSubtreeIfNeeded()
        var collected: [String] = []
        func walk(_ view: NSView) {
            if view.frame.width > 0, view.frame.height > 0 {
                if let text = view as? NSTextView, !text.string.isEmpty {
                    collected.append(text.string)
                } else if let field = view as? NSTextField, !field.stringValue.isEmpty {
                    collected.append(field.stringValue)
                }
            }
            view.subviews.forEach(walk)
        }
        walk(body)
        return collected.joined(separator: "\n")
    }

    /// Total laid-out document height; > clip height for a document that scrolls.
    var qaDocumentHeight: CGFloat {
        body.layoutSubtreeIfNeeded()
        return body.frame.height
    }

    var qaClipHeight: CGFloat { scrollView.contentView.bounds.height }

    /// How many times a block has been measured since this view was built.
    var qaMeasurementCount: Int { body.measurementCount }

    /// Forces the document body through a real layout pass, the way a canvas
    /// relayout does. Used to prove a pan costs no measurement.
    func qaRelayout() {
        body.needsLayout = true
        body.layoutSubtreeIfNeeded()
    }

    /// How many times the document body has laid out. A document that settles runs
    /// this a handful of times; a re-entrant one runs it until the watchdog fires.
    var qaLayoutCount: Int { body.layoutCount }

    /// Blocks the Preview deliberately did not render (0 for an ordinary document).
    var qaTruncatedBlockCount: Int { body.truncatedBlockCount }

    /// Every `RichInlineTextView` in the document, for link and selection assertions.
    func qaInlineTextViews() -> [RichInlineTextView] {
        var found: [RichInlineTextView] = []
        func walk(_ view: NSView) {
            if let inline = view as? RichInlineTextView { found.append(inline) }
            view.subviews.forEach(walk)
        }
        walk(body)
        return found
    }

    /// One vertical stack of semantic blocks. Flipped so rows advance from the
    /// visual top in document order.
    @MainActor
    private final class BodyView: NSView {
        private static let blockSpacing = CGFloat(Space.m)
        private static let documentInset = CGFloat(Space.m)

        /// Each semantic block becomes one AppKit view with its own TextKit stack.
        /// That is affordable for a document, ruinous for a dump: a 546 KB Markdown
        /// file parses to 12,000 blocks, which cost 5.1s to build, 5.1s to lay out
        /// and 1.39 GB resident — and the loader admits files up to 1 MB, so the
        /// next one along is a jetsam kill, not a slow render. Preview renders up to
        /// this many blocks and then says so out loud; Source always holds the whole
        /// file in one text view, which TextKit is built for.
        static let maximumRenderedBlocks = 400

        private struct Row {
            let block: AgentBlock
            let renderer: any AgentBlockRendering
            let view: NSView
            /// Height for the last width it was measured at. Layout runs on every
            /// canvas pass; re-measuring is not free (prose rebuilds an attributed
            /// string per row, and a fenced block — where a GFM table lands —
            /// measures its whole source at unbounded width).
            var measuredHeight: CGFloat = 0
        }

        private var rows: [Row] = []
        private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        private var lastReportedHeight: CGFloat = -1
        private var measuredWidth: CGFloat = -1
        private(set) var measurementCount = 0
        private(set) var layoutCount = 0
        private(set) var truncatedBlockCount = 0

        var blockViews: [NSView] { rows.map(\.view) }

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // No layer, no fill: the document inherits the tile body surface, the
            // same contract `AssistantProseView` follows.
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("Markdown document")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func apply(markdown: String, theme: TokenTheme) {
            context.appearance = theme
            rows.forEach { $0.view.removeFromSuperview() }
            rows = []
            truncatedBlockCount = 0
            guard let entryID = AgentNodeID(rawValue: "file:markdown") else { return }
            let parsed = MarkdownAgentMarkupParser().parse(markdown, entryID: entryID, previous: [])
            let registry = AgentBlockRendererRegistry.production

            var blocks = parsed.blocks
            if blocks.count > Self.maximumRenderedBlocks {
                truncatedBlockCount = blocks.count - Self.maximumRenderedBlocks
                blocks = Array(blocks.prefix(Self.maximumRenderedBlocks))
            }
            rows = blocks.compactMap { block in
                guard let renderer = try? registry.renderer(for: block.kind) else { return nil }
                let view = renderer.makeView()
                renderer.update(view: view, block: block, context: context)
                renderer.updateAccessibility(view: view, block: block, context: context)
                addSubview(view)
                return Row(block: block, renderer: renderer, view: view)
            }
            if truncatedBlockCount > 0, let notice = makeTruncationRow(entryID: entryID, registry: registry) {
                rows.append(notice)
            }
            invalidateMeasurements()
        }

        func applyTheme(_ theme: TokenTheme) {
            context.appearance = theme
            for row in rows {
                row.renderer.update(view: row.view, block: row.block, context: context)
                row.renderer.updateAccessibility(view: row.view, block: row.block, context: context)
            }
            invalidateMeasurements()
        }

        /// Nothing silently disappears: the boundary is a rendered paragraph in the
        /// document, and Source still holds every byte.
        private func makeTruncationRow(
            entryID: AgentNodeID,
            registry: AgentBlockRendererRegistry
        ) -> Row? {
            guard let id = entryID.childID(stableKey: "truncation-notice"),
                  let renderer = try? registry.renderer(for: .paragraph)
            else { return nil }
            let text = "Preview stops here — \(truncatedBlockCount) more block(s) in this file. Switch to Source for the whole document."
            let block = AgentBlock(id: id, kind: .paragraph, payload: .paragraph([.emphasis([.text(text)])]))
            let view = renderer.makeView()
            renderer.update(view: view, block: block, context: context)
            renderer.updateAccessibility(view: view, block: block, context: context)
            addSubview(view)
            return Row(block: block, renderer: renderer, view: view)
        }

        private func invalidateMeasurements() {
            measuredWidth = -1
            lastReportedHeight = -1
            invalidateIntrinsicContentSize()
            needsLayout = true
        }

        /// The scroll view sizes the document from this. Computing it here — rather
        /// than assigning a frame during `layout()` — is what keeps AppKit from
        /// re-entering layout on this subtree.
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(forWidth: bounds.width))
        }

        /// Total height at `width`, measuring (and caching) only when the width the
        /// blocks were measured at actually changed. A pan, a zoom, or a repeated
        /// layout pass reuses the heights.
        private func contentHeight(forWidth width: CGFloat) -> CGFloat {
            guard width > 0 else { return 0 }
            measureIfNeeded(width: width)
            var total = Self.documentInset * 2
            for (index, row) in rows.enumerated() {
                total += row.measuredHeight
                if index + 1 < rows.count { total += Self.blockSpacing }
            }
            return ceil(total)
        }

        private func measureIfNeeded(width: CGFloat) {
            guard abs(measuredWidth - width) > 0.5 else { return }
            let available = max(1, width - Self.documentInset * 2)
            for index in rows.indices {
                measurementCount += 1
                rows[index].measuredHeight = rows[index].renderer.measure(
                    block: rows[index].block,
                    width: available,
                    context: context
                )
            }
            measuredWidth = width
        }

        override func layout() {
            layoutCount += 1
            super.layout()
            let width = bounds.width
            guard width > 0 else { return }
            let available = max(1, width - Self.documentInset * 2)
            measureIfNeeded(width: width)
            var y = Self.documentInset
            for (index, row) in rows.enumerated() {
                let frame = NSRect(x: Self.documentInset, y: y, width: available, height: row.measuredHeight)
                // Assigning an unchanged frame still marks that subview as needing
                // layout, and a prose block re-measures every row when it lays out.
                // Nothing moved, so nothing is touched.
                if row.view.frame != frame { row.view.frame = frame }
                y += row.measuredHeight
                if index + 1 < rows.count { y += Self.blockSpacing }
            }
            // Only ASK for a new height; never assign one here.
            let total = ceil(y + Self.documentInset)
            if abs(lastReportedHeight - total) > 0.5 {
                lastReportedHeight = total
                invalidateIntrinsicContentSize()
            }
        }
    }
}
