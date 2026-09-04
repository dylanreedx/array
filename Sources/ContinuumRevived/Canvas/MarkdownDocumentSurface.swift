import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// AppKit tries to repair arranged-view frames whenever a split's children are
/// installed. Tile hydration legitimately assembles the document before Auto
/// Layout gives it a size, and the stock implementation manufactures a stray
/// one-point pane in that state. Deferring only that impossible resize keeps the
/// first real layout authoritative.
private final class MarkdownSplitView: NSSplitView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        super.resizeSubviews(withOldSize: oldSize)
    }
}

extension MarkdownDocumentMode {
    var segmentIndex: Int {
        switch self {
        case .preview: 0
        case .split: 1
        case .edit: 2
        }
    }

    init?(segmentIndex: Int) {
        switch segmentIndex {
        case 0: self = .preview
        case 1: self = .split
        case 2: self = .edit
        default: return nil
        }
    }
}

/// One native Markdown draft shown as source, preview, or a split document.
/// Persistence remains with the owning note/file tile; this type owns only
/// presentation, focus-safe body changes, draft rendering, and pane state.
@MainActor
final class MarkdownDocumentSurface: NSObject, NSSplitViewDelegate {
    let textView: NSTextView
    let sourceScrollView: NSScrollView
    private(set) var previewView: FileMarkdownDocumentView?
    private let splitView = MarkdownSplitView()
    private(set) var mode: MarkdownDocumentMode

    private var draft: String
    private var previewWork: DispatchWorkItem?
    private var dividerFraction: CGFloat = 0.5
    private var sourceSelection = NSRange(location: 0, length: 0)
    private var sourceScrollOrigin = CGPoint.zero
    private var previewScrollOrigins: [CGPoint] = []
    private let theme: () -> TokenTheme

    init(
        textView: NSTextView,
        sourceScrollView: NSScrollView,
        initialDraft: String,
        mode: MarkdownDocumentMode,
        theme: @escaping () -> TokenTheme
    ) {
        self.textView = textView
        self.sourceScrollView = sourceScrollView
        self.draft = initialDraft
        self.mode = mode
        self.theme = theme
        super.init()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.setAccessibilityLabel("Markdown source and preview")
    }

    var activeBody: NSView { body(for: mode) }
    var currentDraft: String { draft }

    /// A rich repository editor can provide its own source view while reusing
    /// this native preview. Notes continue to use `activeBody` unchanged.
    func previewBody() -> NSView {
        let value = preview()
        renderDraft()
        return value
    }

    func setMode(_ newMode: MarkdownDocumentMode, sourceDraft: String? = nil) {
        capturePresentationState()
        mode = newMode
        draft = sourceDraft ?? textView.string
        if newMode != .edit { renderDraft() }
    }

    /// Loader/recovery-owned replacement. Unlike a user edit, the first Preview
    /// must never briefly display an empty or stale document.
    func replaceDraft(_ value: String) {
        draft = value
        if textView.string != value { textView.string = value }
        previewWork?.cancel()
        if mode != .edit { renderDraft() }
    }

    /// A text mutation has one canonical source. Only renderer work is
    /// debounced, so the owner can persist the exact draft immediately.
    func draftDidChange(_ value: String) {
        draft = value
        previewWork?.cancel()
        guard mode != .edit else { return }
        let work = DispatchWorkItem { [weak self] in self?.renderDraft() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func flushPreview() {
        previewWork?.cancel()
        previewWork = nil
        if mode != .edit { renderDraft() }
    }

    func applyTheme() { previewView?.applyTheme(theme()) }

    func restorePresentationState() {
        let textLength = textView.string.utf16.count
        let location = min(sourceSelection.location, textLength)
        let length = min(sourceSelection.length, max(0, textLength - location))
        textView.setSelectedRange(NSRange(location: location, length: length))
        sourceScrollView.contentView.scroll(to: sourceScrollOrigin)
        sourceScrollView.reflectScrolledClipView(sourceScrollView.contentView)

        guard let previewView else { return }
        for (scroll, origin) in zip(Self.scrollViews(in: previewView), previewScrollOrigins) {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.subviews.count == 2, splitView.bounds.width > 0 else { return }
        dividerFraction = min(0.75, max(0.25, splitView.subviews[0].frame.width / splitView.bounds.width))
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(180, max(0, (splitView.bounds.width - splitView.dividerThickness) * 0.5))
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let paneMinimum = min(180, max(0, (splitView.bounds.width - splitView.dividerThickness) * 0.5))
        return max(paneMinimum, splitView.bounds.width - splitView.dividerThickness - paneMinimum)
    }

    private func body(for mode: MarkdownDocumentMode) -> NSView {
        switch mode {
        case .edit:
            return sourceScrollView

        case .preview:
            let preview = preview()
            renderDraft()
            return preview

        case .split:
            let preview = preview()
            if sourceScrollView.superview !== splitView || preview.superview !== splitView {
                sourceScrollView.removeFromSuperview()
                preview.removeFromSuperview()
                // Both panes may retain frames from their former single-pane
                // hosts while the split itself is still unsized. Zero them as
                // one transaction so NSSplitView never observes mixed geometry.
                sourceScrollView.frame = .zero
                preview.frame = .zero
                splitView.addSubview(sourceScrollView)
                splitView.addSubview(preview)
            }
            splitView.layoutSubtreeIfNeeded()
            // During hydration the split view is commonly assembled before its
            // tile has a frame. Asking AppKit to place a divider in zero-width
            // geometry produces inconsistent arranged-view frames and can leave
            // the first mounted Split unusable. Let AppKit establish the initial
            // frames, then retain the user's fraction once real width exists.
            if splitView.bounds.width > splitView.dividerThickness {
                splitView.setPosition(splitView.bounds.width * dividerFraction, ofDividerAt: 0)
            }
            renderDraft()
            return splitView
        }
    }

    private func preview() -> FileMarkdownDocumentView {
        if let previewView { return previewView }
        let view = FileMarkdownDocumentView(frame: .zero)
        previewView = view
        return view
    }

    private func renderDraft() {
        previewView?.apply(markdown: draft, theme: theme())
        restorePresentationState()
    }

    private func capturePresentationState() {
        sourceSelection = textView.selectedRange()
        sourceScrollOrigin = sourceScrollView.contentView.bounds.origin
        if let previewView {
            previewScrollOrigins = Self.scrollViews(in: previewView).map { $0.contentView.bounds.origin }
        }
    }

    private static func scrollViews(in root: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView { result.append(scroll) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }
}
