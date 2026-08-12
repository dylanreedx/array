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
    private let scrollView = NSScrollView()
    private let body = BodyView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = body
        body.autoresizingMask = [.width]
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
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

        private struct Row {
            let block: AgentBlock
            let renderer: any AgentBlockRendering
            let view: NSView
        }

        private var rows: [Row] = []
        private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        private var lastLaidOutWidth: CGFloat = -1

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
            guard let entryID = AgentNodeID(rawValue: "file:markdown") else { return }
            let parsed = MarkdownAgentMarkupParser().parse(markdown, entryID: entryID, previous: [])
            let registry = AgentBlockRendererRegistry.production
            rows = parsed.blocks.compactMap { block in
                guard let renderer = try? registry.renderer(for: block.kind) else { return nil }
                let view = renderer.makeView()
                renderer.update(view: view, block: block, context: context)
                renderer.updateAccessibility(view: view, block: block, context: context)
                addSubview(view)
                return Row(block: block, renderer: renderer, view: view)
            }
            lastLaidOutWidth = -1
            needsLayout = true
        }

        func applyTheme(_ theme: TokenTheme) {
            context.appearance = theme
            for row in rows {
                row.renderer.update(view: row.view, block: row.block, context: context)
                row.renderer.updateAccessibility(view: row.view, block: row.block, context: context)
            }
            lastLaidOutWidth = -1
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let width = bounds.width
            guard width > 0 else { return }
            let available = max(1, width - Self.documentInset * 2)
            var y = Self.documentInset
            for (index, row) in rows.enumerated() {
                let height = row.renderer.measure(block: row.block, width: available, context: context)
                row.view.frame = NSRect(x: Self.documentInset, y: y, width: available, height: height)
                y += height
                if index + 1 < rows.count { y += Self.blockSpacing }
            }
            let total = ceil(y + Self.documentInset)
            // Sizing the document view inside layout() is what makes the scroll
            // view scrollable; the width guard stops it re-entering forever.
            if abs(frame.height - total) > 0.5 || abs(lastLaidOutWidth - width) > 0.5 {
                lastLaidOutWidth = width
                setFrameSize(NSSize(width: width, height: total))
            }
        }
    }
}
