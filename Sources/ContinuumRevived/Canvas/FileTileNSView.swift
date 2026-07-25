import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts a read-only plain-text preview of a single file.
@MainActor
final class FileTileNSView: TileNSView {
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let filePath: String?
    /// The "file unavailable" placeholder, built lazily by `showMessage`. Held so
    /// `applyTokens()` can re-paint it — it is a content view like any other, and
    /// a placeholder that stays dark under Aqua is the same bug as a tile that does.
    private var messageLabel: NSTextField?
    private var messageContainer: NSView?

    override init(tile: Tile) {
        self.filePath = tile.metadata.filePath

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.token(.bodyMono)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        // Match NoteTileNSView's NSScrollView document-view layout. The
        // NSClipView owns its document view frame via autoresizing; adding
        // Auto Layout constraints to the NSTextView can leave loaded file text
        // present in `string` but invisible due to a zero-height document view.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        // File tiles preserve code-file usability: long source lines should be
        // horizontally scrollable instead of wrapped like notes. The document
        // view still avoids Auto Layout; AppKit owns the NSClipView/document
        // relationship while the text container lays out against an effectively
        // unbounded width.
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.textContainer?.lineBreakMode = .byClipping

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = true
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv

        super.init(tile: tile)

        setContentView(sv)
        loadFile()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
        messageContainer?.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        messageLabel?.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(textView)
        return true
    }

    struct TextVisibilityEvidence: CustomStringConvertible {
        var containsExpectedText = false
        var documentViewMatches = false
        var clipBounds: NSRect = .zero
        var textFrame: NSRect = .zero
        var usedRect: NSRect = .zero
        var textVisibleRect: NSRect = .zero
        var visibleGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphRect: NSRect = .zero
        var expectedGlyphIntersectsVisibleRect = false
        var tileWindowRect: NSRect = .zero
        var textVisibleWindowRect: NSRect = .zero
        var windowContentRect: NSRect = .zero
        var textIntersectsWindow = false
        var verticalScrollable = false
        var verticalScrollAdvanced = false
        var horizontalScrollable = false
        var documentWidthExceedsClipWidth = false
        var horizontalScrollAdvanced = false
        var horizontalScrollOriginBefore: CGFloat = 0
        var horizontalScrollOriginAfter: CGFloat = 0
        var hasHorizontalScroller = false

        var visibleLayoutOK: Bool {
            containsExpectedText
                && documentViewMatches
                && clipBounds.width > 0
                && clipBounds.height > 0
                && textFrame.width > 0
                && textFrame.height > 0
                && usedRect.width > 0
                && usedRect.height > 0
                && textVisibleRect.width > 0
                && textVisibleRect.height > 0
                && visibleGlyphRange.location != NSNotFound
                && visibleGlyphRange.length > 0
                && expectedGlyphRange.location != NSNotFound
                && expectedGlyphIntersectsVisibleRect
                && textIntersectsWindow
        }

        var longFileBehaviorOK: Bool {
            verticalScrollable
                && verticalScrollAdvanced
                && horizontalScrollable
                && documentWidthExceedsClipWidth
                && horizontalScrollAdvanced
                && hasHorizontalScroller
        }

        var description: String {
            "containsExpectedText=\(containsExpectedText) documentViewMatches=\(documentViewMatches) clipBounds=\(clipBounds) textFrame=\(textFrame) usedRect=\(usedRect) textVisibleRect=\(textVisibleRect) visibleGlyphRange=\(visibleGlyphRange) expectedGlyphRange=\(expectedGlyphRange) expectedGlyphRect=\(expectedGlyphRect) expectedGlyphIntersectsVisibleRect=\(expectedGlyphIntersectsVisibleRect) tileWindowRect=\(tileWindowRect) textVisibleWindowRect=\(textVisibleWindowRect) windowContentRect=\(windowContentRect) textIntersectsWindow=\(textIntersectsWindow) verticalScrollable=\(verticalScrollable) verticalScrollAdvanced=\(verticalScrollAdvanced) horizontalScrollable=\(horizontalScrollable) documentWidthExceedsClipWidth=\(documentWidthExceedsClipWidth) horizontalScrollAdvanced=\(horizontalScrollAdvanced) horizontalScrollOriginBefore=\(horizontalScrollOriginBefore) horizontalScrollOriginAfter=\(horizontalScrollOriginAfter) hasHorizontalScroller=\(hasHorizontalScroller)"
        }
    }

    /// Deterministic QA hook: verifies not just that text loaded into
    /// `textView.string`, but that AppKit produced visible glyph layout inside
    /// the scroll view and that the tile's visible text rect intersects the
    /// window content rect. For long smoke files it also records scrollability
    /// and the visible glyph range before/after a programmatic scroll.
    func textVisibilityEvidence(containing expectedText: String) -> TextVisibilityEvidence {
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()

        var evidence = TextVisibilityEvidence()
        evidence.containsExpectedText = textView.string.contains(expectedText)
        evidence.documentViewMatches = scrollView.documentView === textView
        evidence.clipBounds = scrollView.contentView.bounds
        evidence.textFrame = textView.frame
        evidence.textVisibleRect = textView.visibleRect
        evidence.hasHorizontalScroller = scrollView.hasHorizontalScroller

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return evidence }
        layoutManager.ensureLayout(for: textContainer)
        evidence.usedRect = layoutManager.usedRect(for: textContainer)
        evidence.visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: evidence.textVisibleRect, in: textContainer)

        if let range = textView.string.range(of: expectedText) {
            let nsRange = NSRange(range, in: textView.string)
            evidence.expectedGlyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            evidence.expectedGlyphRect = layoutManager.boundingRect(forGlyphRange: evidence.expectedGlyphRange, in: textContainer)
            evidence.expectedGlyphRect.origin.x += textView.textContainerOrigin.x
            evidence.expectedGlyphRect.origin.y += textView.textContainerOrigin.y
            evidence.expectedGlyphIntersectsVisibleRect = evidence.expectedGlyphRect.intersects(evidence.textVisibleRect)
        }

        if let window, let contentView = window.contentView {
            evidence.tileWindowRect = convert(bounds, to: nil)
            evidence.textVisibleWindowRect = textView.convert(evidence.textVisibleRect, to: nil)
            evidence.windowContentRect = contentView.convert(contentView.bounds, to: nil)
            evidence.textIntersectsWindow = evidence.textVisibleWindowRect.intersects(evidence.windowContentRect)
                && evidence.tileWindowRect.intersects(evidence.windowContentRect)
        }

        evidence.verticalScrollable = evidence.usedRect.height > evidence.textVisibleRect.height + 1
        evidence.horizontalScrollable = evidence.usedRect.width > evidence.textVisibleRect.width + 1
        evidence.documentWidthExceedsClipWidth = textView.frame.width > scrollView.contentView.bounds.width + 1
        let originalOrigin = scrollView.contentView.bounds.origin
        if evidence.verticalScrollable {
            let before = originalOrigin.y
            textView.scrollRangeToVisible(NSRange(location: max(textView.string.utf16.count - 1, 0), length: 0))
            scrollView.layoutSubtreeIfNeeded()
            let after = scrollView.contentView.bounds.origin.y
            evidence.verticalScrollAdvanced = after > before + 1
            scrollView.contentView.scroll(to: originalOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if evidence.documentWidthExceedsClipWidth {
            let clipView = scrollView.contentView
            let maxX = max(textView.frame.width - clipView.bounds.width, 0)
            evidence.horizontalScrollOriginBefore = clipView.bounds.origin.x
            clipView.scroll(to: NSPoint(x: maxX, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            scrollView.layoutSubtreeIfNeeded()
            evidence.horizontalScrollOriginAfter = clipView.bounds.origin.x
            evidence.horizontalScrollAdvanced = evidence.horizontalScrollOriginAfter > evidence.horizontalScrollOriginBefore + 1
            clipView.scroll(to: originalOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }

        return evidence
    }

    func hasVisibleTextLayout(containing expectedText: String) -> Bool {
        textVisibilityEvidence(containing: expectedText).visibleLayoutOK
    }

    private func loadFile() {
        guard let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showMessage("File not found")
            return
        }

        if Self.shouldLoadAsynchronously(path: filePath) {
            textView.string = "Loading file..."
            Task.detached { [filePath] in
                let result = FilePreview.load(path: filePath)
                await MainActor.run { [weak self] in self?.apply(result) }
            }
        } else {
            apply(FilePreview.load(path: filePath))
        }
    }

    private func apply(_ result: FilePreview) {
        switch result {
        case let .text(content):
            setContentView(scrollView)
            textView.string = content
        case let .unavailable(message):
            showMessage(message)
        }
    }

    private func showMessage(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0

        let container = NSView()
        container.wantsLayer = true
        messageLabel = label
        messageContainer = container
        applyTokens()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        setContentView(container)
    }

    nonisolated private static func shouldLoadAsynchronously(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           values.volumeIsLocal == false {
            return true
        }
        return false
    }
}
