import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

extension MarkdownDocumentMode {
    var segmentIndex: Int { switch self { case .preview: 0; case .split: 1; case .edit: 2 } }
    init?(segmentIndex: Int) {
        switch segmentIndex { case 0: self = .preview; case 1: self = .split; case 2: self = .edit; default: return nil }
    }
}

/// Shared native source/preview coordinator for Array-owned notes and disk-backed
/// Markdown files. Ownership and saving stay with the tile; this owns only the
/// one draft's presentation, focus-safe body swaps, and split layout.
@MainActor
final class MarkdownDocumentSurface: NSObject, NSSplitViewDelegate {
    let textView: NSTextView
    let sourceScrollView: NSScrollView
    private(set) var previewView: FileMarkdownDocumentView?
    private let splitView = NSSplitView()
    private(set) var mode: MarkdownDocumentMode
    private var draft: String
    private var previewWork: DispatchWorkItem?
    private let theme: () -> TokenTheme

    init(textView: NSTextView, sourceScrollView: NSScrollView, initialDraft: String,
         mode: MarkdownDocumentMode, theme: @escaping () -> TokenTheme) {
        self.textView = textView
        self.sourceScrollView = sourceScrollView
        self.draft = initialDraft
        self.mode = mode
        self.theme = theme
        super.init()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
    }

    var activeBody: NSView { body(for: mode) }

    func setMode(_ mode: MarkdownDocumentMode) {
        self.mode = mode
        draft = textView.string
        if mode != .edit { renderDraft() }
    }

    /// Loader-owned replacement, unlike a user edit: the first Preview must never
    /// briefly show an empty/stale body while its debounce is pending.
    func replaceDraft(_ value: String) {
        draft = value
        previewWork?.cancel()
        if mode != .edit { renderDraft() }
    }

    /// A text mutation has one canonical source. Debouncing only the expensive
    /// renderer keeps typing responsive without ever letting Preview use disk text.
    func draftDidChange(_ value: String) {
        draft = value
        previewWork?.cancel()
        guard mode != .edit else { return }
        let work = DispatchWorkItem { [weak self] in self?.renderDraft() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func applyTheme() { previewView?.applyTheme(theme()) }

    private func body(for mode: MarkdownDocumentMode) -> NSView {
        switch mode {
        case .edit: return sourceScrollView
        case .preview:
            let preview = preview()
            renderDraft()
            return preview
        case .split:
            let preview = preview()
            if sourceScrollView.superview !== splitView {
                sourceScrollView.removeFromSuperview()
                preview.removeFromSuperview()
                splitView.addSubview(sourceScrollView)
                splitView.addSubview(preview)
                splitView.setPosition(0.5 * max(splitView.bounds.width, 480), ofDividerAt: 0)
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

    private func renderDraft() { previewView?.apply(markdown: draft, theme: theme()) }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(180, splitView.bounds.width - 180) }
}
