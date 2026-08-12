import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts a read-only preview of a single file: the monospaced
/// source viewer for text and code, and — for `.md`/`.markdown` — a native
/// rendered document with a tile-local Preview/Source switch.
@MainActor
final class FileTileNSView: TileNSView {
    enum Mode: Equatable {
        case preview
        case source
    }

    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let filePath: String?
    /// Markdown files only. Deliberately view-local: reopening or restoring a
    /// Markdown tile returns to Preview, so this slice adds nothing to
    /// `TileMetadata` or sync before dogfooding says it is worth it.
    private(set) var mode: Mode = .preview
    private(set) var presentation: FilePreview.Presentation = .sourceText
    /// One immutable loaded-text snapshot shared by both modes, so switching is
    /// instant and Preview can never drift from Source inside one tile.
    private(set) var loadedText: String?
    private var markdownView: FileMarkdownDocumentView?
    private var modeControl: NSSegmentedControl?
    private var pendingReveal: (line: Int, column: Int?)?
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
        markdownView?.applyTheme(effectiveTokenTheme)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(mode == .preview ? (markdownView ?? textView) : textView)
        return true
    }

    // MARK: - Markdown mode

    /// Switches the body in place. The tile keeps its identity, its persisted
    /// metadata, and its already-loaded text.
    func setMode(_ newMode: Mode) {
        guard presentation == .markdown, newMode != mode else { return }
        mode = newMode
        modeControl?.selectedSegment = newMode == .preview ? 0 : 1
        showBody()
    }

    @objc private func modeControlChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 0 ? .preview : .source)
    }

    private func installModeControl() {
        guard modeControl == nil else { return }
        let control = NSSegmentedControl(labels: ["Preview", "Source"], trackingMode: .selectOne, target: self, action: #selector(modeControlChanged(_:)))
        control.controlSize = .small
        control.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        control.selectedSegment = mode == .preview ? 0 : 1
        control.setAccessibilityLabel("Markdown display mode")
        modeControl = control
        setTitleBarAccessory(control)
    }

    /// Installs the body for the current mode from the loaded snapshot.
    private func showBody() {
        guard let loadedText else { return }
        switch (presentation, mode) {
        case (.markdown, .preview):
            let view = markdownView ?? FileMarkdownDocumentView(frame: bounds)
            markdownView = view
            view.apply(markdown: loadedText, theme: effectiveTokenTheme)
            setContentView(view)
        default:
            textView.string = loadedText
            setContentView(scrollView)
            applyPendingReveal()
        }
    }

    /// Scrolls the source view to a one-based line (and optional column) without
    /// persisting anything. Called when an agent link named `file.swift:42`.
    /// Markdown tiles switch to Source first: a coordinate refers to the text.
    func reveal(line: Int, column: Int? = nil) {
        guard line > 0 else { return }
        pendingReveal = (line, column)
        if presentation == .markdown, mode != .source {
            setMode(.source)
        } else {
            applyPendingReveal()
        }
    }

    private func applyPendingReveal() {
        guard let pendingReveal, !textView.string.isEmpty else { return }
        self.pendingReveal = nil
        let text = textView.string as NSString
        var lineStart = 0
        var currentLine = 1
        while currentLine < pendingReveal.line {
            let searchRange = NSRange(location: lineStart, length: text.length - lineStart)
            let newline = text.range(of: "\n", options: [], range: searchRange)
            guard newline.location != NSNotFound else { break }
            lineStart = newline.location + newline.length
            currentLine += 1
        }
        let lineEnd = text.range(
            of: "\n",
            options: [],
            range: NSRange(location: lineStart, length: text.length - lineStart)
        )
        let lineLength = (lineEnd.location == NSNotFound ? text.length : lineEnd.location) - lineStart
        var location = lineStart
        if let column = pendingReveal.column, column > 1 {
            location = min(lineStart + column - 1, lineStart + max(lineLength, 0))
        }
        let range = NSRange(location: min(location, text.length), length: 0)
        textView.scrollRangeToVisible(range)
        // Select from the coordinate to the end of that line — a subtle "here",
        // never a selection that runs past the line.
        let selectionLength = max(0, min(lineStart + lineLength, text.length) - range.location)
        textView.setSelectedRange(NSRange(location: range.location, length: selectionLength))
        // The QA reveal assertion reads the clip origin, which only moves once
        // AppKit has laid the document out.
        scrollView.layoutSubtreeIfNeeded()
        textView.scrollRangeToVisible(range)
    }

    /// QA: the one-based line currently at the top of the visible source rect.
    func qaFirstVisibleSourceLine() -> Int? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphRange.location != NSNotFound else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let text = textView.string as NSString
        guard charIndex <= text.length else { return nil }
        var line = 1
        var index = 0
        while index < charIndex {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: index, length: charIndex - index))
            guard newline.location != NSNotFound else { break }
            index = newline.location + newline.length
            line += 1
        }
        return line
    }

    /// QA: the rendered Markdown document, when one is installed.
    var qaMarkdownDocument: FileMarkdownDocumentView? { markdownView }
    /// QA: the mode control, which must exist for Markdown and never otherwise.
    var qaModeControl: NSSegmentedControl? { modeControl }

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
            loadedText = content
            presentation = filePath.map { FilePreview.presentation(forPath: $0) } ?? .sourceText
            if presentation == .markdown {
                installModeControl()
            }
            showBody()
        case let .unavailable(message):
            loadedText = nil
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
