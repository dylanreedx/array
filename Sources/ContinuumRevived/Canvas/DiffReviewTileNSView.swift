import AppKit
import ContinuumRevivedCore
import Foundation

/// Hunk/file renderer for a diff review tile, including inline review-comment blocks.
@MainActor
final class DiffReviewTileNSView: TileNSView {
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private var model: GitDiffModel?
    private var reviewState: ReviewCommentState?
    private var onReviewStateChanged: ((ReviewCommentState) -> Void)?

    init(tile: Tile, repositoryURL: URL, source: GitDiffEngine.Source = .workingTreeVsHEAD, reviewState: ReviewCommentState? = nil, onReviewStateChanged: ((ReviewCommentState) -> Void)? = nil) {
        let (tv, sv) = Self.makeTextViews()
        self.textView = tv
        self.scrollView = sv
        self.reviewState = reviewState
        self.onReviewStateChanged = onReviewStateChanged
        super.init(tile: tile)
        setContentView(sv)

        do {
            let model = try GitDiffEngine().diff(repositoryURL: repositoryURL, source: source)
            apply(model)
        } catch {
            showMessage("Unable to load diff: \(error)")
        }
    }

    init(tile: Tile, model: GitDiffModel, reviewState: ReviewCommentState? = nil, onReviewStateChanged: ((ReviewCommentState) -> Void)? = nil) {
        let (tv, sv) = Self.makeTextViews()
        self.textView = tv
        self.scrollView = sv
        self.reviewState = reviewState
        self.onReviewStateChanged = onReviewStateChanged
        super.init(tile: tile)
        setContentView(sv)
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(textView)
        return true
    }

    func apply(_ model: GitDiffModel) {
        self.model = model
        if model.files.isEmpty {
            textView.string = "No changes"
            return
        }
        if let reviewState { self.reviewState = reviewState.revalidated(against: model) }
        textView.textStorage?.setAttributedString(Self.render(model, comments: reviewState?.comments ?? []))
    }

    @discardableResult
    func addComment(anchor: ReviewCommentAnchor, body: String, id: UUID = UUID(), createdAt: Date = Date()) -> ReviewCommentState? {
        guard var state = reviewState else { return nil }
        state = state.addingComment(id: id, anchor: anchor, body: body, createdAt: createdAt)
        setReviewState(state)
        return state
    }

    @discardableResult
    func editComment(id: UUID, body: String) -> ReviewCommentState? {
        guard var state = reviewState else { return nil }
        state = state.editingComment(id: id, body: body)
        setReviewState(state)
        return state
    }

    @discardableResult
    func setCommentResolved(id: UUID, resolved: Bool) -> ReviewCommentState? {
        guard var state = reviewState else { return nil }
        state = state.settingResolved(id: id, resolved: resolved)
        setReviewState(state)
        return state
    }

    private func setReviewState(_ state: ReviewCommentState) {
        reviewState = state
        onReviewStateChanged?(state)
        if let model { textView.textStorage?.setAttributedString(Self.render(model, comments: state.comments)) }
    }

    struct VisibilityEvidence: CustomStringConvertible {
        var containsExpectedText = false
        var documentViewMatches = false
        var editable = true
        var visibleGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphIntersectsVisibleRect = false
        var clipBounds: NSRect = .zero
        var usedRect: NSRect = .zero
        var ok: Bool { containsExpectedText && documentViewMatches && !editable && visibleGlyphRange.length > 0 && expectedGlyphRange.location != NSNotFound && expectedGlyphIntersectsVisibleRect && clipBounds.width > 0 && clipBounds.height > 0 && usedRect.width > 0 && usedRect.height > 0 }
        var description: String { "containsExpectedText=\(containsExpectedText) documentViewMatches=\(documentViewMatches) editable=\(editable) visibleGlyphRange=\(visibleGlyphRange) expectedGlyphRange=\(expectedGlyphRange) expectedGlyphIntersectsVisibleRect=\(expectedGlyphIntersectsVisibleRect) clipBounds=\(clipBounds) usedRect=\(usedRect)" }
    }

    func visibilityEvidence(containing expectedText: String) -> VisibilityEvidence {
        layoutSubtreeIfNeeded(); scrollView.layoutSubtreeIfNeeded(); textView.layoutSubtreeIfNeeded()
        var evidence = VisibilityEvidence()
        evidence.containsExpectedText = textView.string.contains(expectedText)
        evidence.documentViewMatches = scrollView.documentView === textView
        evidence.editable = textView.isEditable
        evidence.clipBounds = scrollView.contentView.bounds
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return evidence }
        layoutManager.ensureLayout(for: textContainer)
        evidence.usedRect = layoutManager.usedRect(for: textContainer)
        evidence.visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        if let range = textView.string.range(of: expectedText) {
            let nsRange = NSRange(range, in: textView.string)
            evidence.expectedGlyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: evidence.expectedGlyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            evidence.expectedGlyphIntersectsVisibleRect = rect.intersects(textView.visibleRect)
        }
        return evidence
    }

    private func showMessage(_ message: String) { textView.string = message }

    private static func makeTextViews() -> (NSTextView, NSScrollView) {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = NSColor(white: 0.10, alpha: 1.0)
        tv.textColor = NSColor(white: 0.90, alpha: 1.0)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineBreakMode = .byClipping

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.documentView = tv
        return (tv, sv)
    }

    private static func render(_ model: GitDiffModel, comments: [ReviewComment] = []) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(white: 0.90, alpha: 1.0)]
        func append(_ text: String, color: NSColor, background: NSColor? = nil) {
            var attrs = base
            attrs[.foregroundColor] = color
            if let background { attrs[.backgroundColor] = background }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        let commentsByAnchor = Dictionary(grouping: comments, by: { $0.anchor })
        for file in model.files {
            let path = file.newPath ?? file.oldPath ?? "(unknown)"
            append("diff -- \(path) [\(file.change.rawValue)]\n", color: NSColor.systemBlue)
            if file.isBinary { append("Binary file changed\n\n", color: NSColor.systemOrange); continue }
            for hunk in file.hunks {
                append("\(hunk.header)\n", color: NSColor.systemPurple)
                for line in hunk.lines {
                    switch line.kind {
                    case .addition: append("+\(line.text)\n", color: NSColor.systemGreen, background: NSColor.systemGreen.withAlphaComponent(0.10))
                    case .deletion: append("-\(line.text)\n", color: NSColor.systemRed, background: NSColor.systemRed.withAlphaComponent(0.10))
                    case .metadata: append("\(line.text)\n", color: NSColor.systemOrange)
                    case .context: append(" \(line.text)\n", color: NSColor(white: 0.82, alpha: 1.0))
                    }
                    guard let anchor = ReviewCommentAnchor.make(file: file, hunk: hunk, line: line), let lineComments = commentsByAnchor[anchor] else { continue }
                    for comment in lineComments.sorted(by: { $0.createdAt < $1.createdAt }) {
                        let state = comment.resolved ? "resolved" : "open"
                        let drift = comment.status == .outdated ? " · outdated" : ""
                        append("    💬 [\(state)\(drift)] \(comment.body)\n", color: comment.resolved ? NSColor.systemGray : NSColor.controlAccentColor, background: NSColor.controlAccentColor.withAlphaComponent(0.08))
                    }
                }
            }
            append("\n", color: NSColor(white: 0.82, alpha: 1.0))
        }
        return out
    }
}
