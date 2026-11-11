import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Dev-channel switch for mounting only the Markdown rows a tile can show.
///
/// Every rendered row is a real AppKit view, and a camera zoom makes AppKit
/// repaint, re-back and re-track every row in every visible tile, including the
/// rows scrolled far out of the tile's clip. With the switch on, the body keeps
/// all row views built but attaches only those intersecting the scroll clip plus
/// an overscan. OFF by default, and never read on the prod channel:
/// `defaults write dev.arrayapp.macos.dev markdownVisibleRows -bool YES`.
@MainActor
enum MarkdownVisibleRowsConfig {
    static let enabledKey = "markdownVisibleRows"
    /// Checks set this instead of touching a defaults domain.
    static var qaOverride: Bool?

    static var isEnabled: Bool {
        if let qaOverride { return qaOverride }
        guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else { return false }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }
}

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
final class FileMarkdownDocumentView: NSView, RichInlineTextSelectionContainer {
    /// Preview renders at most this many semantic blocks; see `BodyView`.
    static var maximumRenderedBlocks: Int { BodyView.maximumRenderedBlocks }

    private let scrollView = OverlayScrollerView()
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
        body.visibleDocumentRect = { [weak self] in self?.scrollView.contentView.documentVisibleRect }
        body.virtualizesRows = MarkdownVisibleRowsConfig.isEnabled
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

    /// Scrolling and clip resizes are the only things that change which rows the
    /// tile can show. A camera zoom scales the whole tile and leaves the clip's
    /// document rect where it was (bar sub-pixel re-snaps the overscan absorbs),
    /// so a zoom never remounts anything.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        let clip = scrollView.contentView
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: clip)
        guard body.virtualizesRows, superview != nil else { return }
        observeClip()
    }

    private func observeClip() {
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: clip)
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipGeometryDidChange(_:)), name: name, object: clip)
        }
    }

    @objc private func clipGeometryDidChange(_ notification: Notification) {
        body.updateMountedRows()
    }

    /// Turns row mounting on or off for this document. Off mounts every row,
    /// exactly as before the switch existed.
    func setVirtualizesRows(_ enabled: Bool) {
        guard body.virtualizesRows != enabled else { return }
        body.virtualizesRows = enabled
        if enabled, superview != nil { observeClip() }
        body.updateMountedRows(force: true)
    }

    var virtualizesRows: Bool { body.virtualizesRows }

    /// Parses and renders a complete Markdown document. Cheap to call again: the
    /// tile keeps one loaded-text snapshot and only re-renders on a theme change.
    func apply(markdown: String, theme: TokenTheme) {
        let priorOffset = scrollView.contentView.bounds.origin
        body.apply(markdown: markdown, theme: theme)
        body.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: priorOffset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func applyTheme(_ theme: TokenTheme) {
        body.applyTheme(theme)
    }

    /// Where the reader is. A resting tile's picture is only current for this.
    var scrollOrigin: CGPoint { scrollView.contentView.bounds.origin }

    // MARK: - QA introspection

    /// The laid-out block views, in document order.
    var qaBlockViews: [NSView] { body.blockViews }

    /// Rows currently attached to the document view, and how often the mounted
    /// set has changed since this view was built.
    var qaMountedRowIndices: [Int] { body.mountedRowIndices }
    var qaMountChangeCount: Int { body.mountChangeCount }
    var qaRowCount: Int { body.blockViews.count }
    /// Positive control only: detach one row behind the mounting logic's back.
    func qaDetachRow(at index: Int) { body.qaDetachRow(at: index) }
    var qaDocumentVisibleRect: NSRect { scrollView.contentView.documentVisibleRect }
    var qaScrollView: NSScrollView { scrollView }

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
    var qaScrollOffsetY: CGFloat { scrollView.contentView.bounds.origin.y }
    func qaScroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// How many times a block has been measured since this view was built.
    var qaMeasurementCount: Int { body.measurementCount }
    static var qaLastMeasureTrigger: String { BodyView.qaLastMeasureTrigger }
    static var qaTotalMeasurePasses: Int { BodyView.qaTotalMeasurePasses }

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
    /// Walks every row in document order, attached or not: a selection or a copy
    /// that spans rows scrolled out of the clip still reaches them.
    func qaInlineTextViews() -> [RichInlineTextView] {
        var found: [RichInlineTextView] = []
        func walk(_ view: NSView) {
            if let inline = view as? RichInlineTextView { found.append(inline) }
            view.subviews.forEach(walk)
        }
        body.blockViews.forEach(walk)
        return found
    }

    func richInlineTextViewsInSelectionOrder() -> [RichInlineTextView] {
        qaInlineTextViews()
    }

    /// Setting `.overlay` once does not hold on a Mac with a mouse. Every WKWebView
    /// layer commit (the code editor in a split tile) makes AppKit rewrite all
    /// scroll views in the process to the system style. A legacy scroller takes
    /// 17 pt from the clip and the whole document re-measures for it: seconds on
    /// the main thread across a canvas of tiles. Overlay scrollers stay draggable.
    private final class OverlayScrollerView: NSScrollView {
        override var scrollerStyle: NSScroller.Style {
            get { super.scrollerStyle }
            set {
                super.scrollerStyle = .overlay
            }
        }
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
        /// See `MarkdownVisibleRowsConfig`. Off: every row is a subview.
        var virtualizesRows = false
        /// The scroll clip's rect in this view's coordinates.
        var visibleDocumentRect: () -> NSRect? = { nil }
        private var mounted = IndexSet()
        private(set) var mountChangeCount = 0
        var mountedRowIndices: [Int] { Array(mounted) }
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
            mounted = IndexSet()
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
                return Row(block: block, renderer: renderer, view: view)
            }
            if truncatedBlockCount > 0, let notice = makeTruncationRow(entryID: entryID, registry: registry) {
                rows.append(notice)
            }
            mountBuiltRows()
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
            return Row(block: block, renderer: renderer, view: view)
        }

        /// Off, every row is attached as soon as it is built, as it always was.
        /// On, rows attach once layout has given them frames.
        private func mountBuiltRows() {
            guard !virtualizesRows else {
                // An unattached row has no superview to name its parent.
                for row in rows { row.view.setAccessibilityParent(self) }
                return
            }
            for index in rows.indices { addSubview(rows[index].view) }
            mounted = IndexSet(integersIn: rows.indices)
        }

        /// Attach exactly the rows the clip shows plus an overscan of half a clip
        /// on each side, and any row holding the first responder (a text view
        /// that leaves the window resigns, and Copy would stop reaching it).
        /// Nothing changes while every row the clip shows is already attached,
        /// which is what keeps the set still through a zoom gesture's sub-pixel
        /// clip re-snaps and lets a scroll remount only when it must.
        /// `force` recomputes the set even when every row the clip shows is
        /// attached: switching on a live, fully attached document.
        func updateMountedRows(force: Bool = false) {
            guard virtualizesRows else {
                // Switched off on a live document: re-attach everything in
                // document order, the order the unswitched body always had.
                let all = IndexSet(integersIn: rows.indices)
                guard mounted != all else { return }
                for row in rows { row.view.removeFromSuperview() }
                for row in rows { addSubview(row.view) }
                mounted = all
                mountChangeCount += 1
                return
            }
            if !rows.isEmpty, rows[0].view.accessibilityParent() as? NSView !== self {
                for row in rows { row.view.setAccessibilityParent(self) }
            }
            guard let visible = visibleDocumentRect(), !rows.isEmpty else { return }
            // A clip with no area (a collapsed split pane) or a body not yet
            // measured shows nothing, so nothing but the focused row attaches.
            let canShow = measuredWidth > 0 && visible.width > 0 && visible.height > 0
            let pinned = firstResponderRows()
            let required = canShow ? rowIndices(intersecting: visible).union(pinned) : pinned
            guard force || !required.isSubset(of: mounted) else { return }
            let target = canShow
                ? rowIndices(intersecting: Self.attachedRegion(around: visible)).union(pinned) : pinned
            for index in mounted.subtracting(target) { rows[index].view.removeFromSuperview() }
            // Unattached rows are already laid out at their frames (see
            // `layout()`). That matters: an NSTextView given a new frame while
            // visible in a scroll view scrolls its insertion point into view,
            // which moved the reader by up to a row.
            for index in target.subtracting(mounted) { addSubview(rows[index].view) }
            mounted = target
            mountChangeCount += 1
        }

        private func rowIndices(intersecting rect: NSRect) -> IndexSet {
            guard rect.height > 0 else { return IndexSet() }
            var result = IndexSet()
            for (index, row) in rows.enumerated()
            where row.view.frame.maxY >= rect.minY && row.view.frame.minY <= rect.maxY {
                result.insert(index)
            }
            return result
        }

        private func firstResponderRows() -> IndexSet {
            guard let responder = window?.firstResponder as? NSView else { return IndexSet() }
            var result = IndexSet()
            for index in mounted where responder.isDescendant(of: rows[index].view) { result.insert(index) }
            return result
        }

        /// The clip plus half a clip above and below.
        static func attachedRegion(around visible: NSRect) -> NSRect {
            visible.insetBy(dx: 0, dy: -visible.height / 2)
        }

        /// Responsive scrolling draws AppKit's prepared overdraw ahead of the main
        /// thread. Prepare no further than the attached region, so the overdraw
        /// never holds a stretch whose rows are not attached.
        override func prepareContent(in rect: NSRect) {
            guard virtualizesRows, let visible = visibleDocumentRect(), visible.height > 0 else {
                super.prepareContent(in: rect)
                return
            }
            updateMountedRows()
            let clamped = rect.intersection(Self.attachedRegion(around: visible))
            super.prepareContent(in: clamped.isEmpty ? visible : clamped)
        }

        func qaDetachRow(at index: Int) {
            guard rows.indices.contains(index) else { return }
            rows[index].view.removeFromSuperview()
        }

        /// Accessibility reaches every row, attached or not, in document order.
        /// An unattached row has no window, so its accessibility frame is not
        /// meaningful until it is scrolled into the clip.
        override func accessibilityChildren() -> [Any]? {
            guard virtualizesRows else { return super.accessibilityChildren() }
            return NSAccessibility.unignoredChildren(from: rows.map(\.view))
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

        /// See `AssistantProseView.qaLastMeasureTrigger` — the same instrument, for
        /// the same investigation.
        static private(set) var qaLastMeasureTrigger = "-"
        static private(set) var qaTotalMeasurePasses = 0

        private func measureIfNeeded(width: CGFloat) {
            // Same hysteresis as `AssistantProseView.measureWidthHysteresis`, for
            // the same measured reason: zoom-driven pixel snapping jiggles this
            // width by up to a device pixel per step, and re-measuring a whole
            // markdown document for ±1.3 pt is what made zooming horrendous.
            guard abs(measuredWidth - width) > AssistantProseView.measureWidthHysteresis else { return }
            Self.qaLastMeasureTrigger = String(format: "markdown %.1f->%.1f", measuredWidth, width)
            Self.qaTotalMeasurePasses += 1
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
            measureIfNeeded(width: width)
            // The measured width, not today's: see `measureIfNeeded` — row frames
            // must match the width the heights came from.
            let available = max(1, (measuredWidth > 0 ? measuredWidth : width) - Self.documentInset * 2)
            var y = Self.documentInset
            var resizedUnattached: [Int] = []
            for (index, row) in rows.enumerated() {
                let frame = NSRect(x: Self.documentInset, y: y, width: available, height: row.measuredHeight)
                // Assigning an unchanged frame still marks that subview as needing
                // layout, and a prose block re-measures every row when it lays out.
                // Nothing moved, so nothing is touched.
                if row.view.frame != frame {
                    row.view.frame = frame
                    if row.view.superview == nil { resizedUnattached.append(index) }
                }
                y += row.measuredHeight
                if index + 1 < rows.count { y += Self.blockSpacing }
            }
            // Only ASK for a new height; never assign one here.
            let total = ceil(y + Self.documentInset)
            if abs(lastReportedHeight - total) > 0.5 {
                lastReportedHeight = total
                invalidateIntrinsicContentSize()
            }
            // An unattached row still lays out at its new size, as every row does
            // with the switch off: a table composes its text only in layout, and
            // copy and accessibility read rows that have never been on screen.
            for index in resizedUnattached { rows[index].view.layoutSubtreeIfNeeded() }
            if virtualizesRows { updateMountedRows() }
        }
    }
}
