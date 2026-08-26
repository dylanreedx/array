import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view for a single file: non-Markdown files are read-only, while
/// `.md`/`.markdown` documents have a native Preview/Edit surface.
@MainActor
final class FileTileNSView: TileNSView, NSTextViewDelegate {
    typealias Mode = MarkdownDocumentMode

    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let filePath: String?
    /// Markdown files default to Preview, while a selected mode is durable tile metadata.
    private(set) var mode: Mode = .preview
    private var markdownSurface: MarkdownDocumentSurface!
    private(set) var presentation: FilePreview.Presentation = .sourceText
    /// One immutable loaded-text snapshot shared by both modes, so switching is
    /// instant and Preview can never drift from Source inside one tile.
    private(set) var loadedText: String?
    private var modeControl: NSSegmentedControl?
    private let dirtyLabel = NSTextField(labelWithString: "")
    private let referenceLabel = NSTextField(labelWithString: "")
    private var titleAccessoryStack: NSStackView?
    var onRevealReferencedAgentTile: ((UUID) -> Void)?
    private(set) var isDirty = false
    private(set) var hasExternalConflict = false
    private var savedText: String?
    private var externalChangeTimer: Timer?
    var onSaveFailure: ((String) -> Void)?
    private var pendingReveal: (line: Int, column: Int?)?
    /// The "file unavailable" placeholder, built lazily by `showMessage`. Held so
    /// `applyTokens()` can re-paint it — it is a content view like any other, and
    /// a placeholder that stays dark under Aqua is the same bug as a tile that does.
    private var messageLabel: NSTextField?
    private var messageContainer: NSView?

    override init(tile: Tile) {
        self.filePath = tile.metadata.documentLocation?.path ?? tile.metadata.filePath

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

        markdownSurface = MarkdownDocumentSurface(
            textView: tv, sourceScrollView: sv, initialDraft: "",
            mode: tile.metadata.markdownDocumentMode ?? .preview,
            theme: { [weak self] in self?.effectiveTokenTheme ?? .dark }
        )
        mode = markdownSurface.mode
        setContentView(sv)
        activeBody = sv
        tv.delegate = self
        loadFile()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            externalChangeTimer?.invalidate()
            externalChangeTimer = nil
        } else if presentation == .markdown {
            startExternalChangeMonitoring()
        }
    }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
        messageContainer?.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        messageLabel?.textColor = TextToken.textSecondary.color.nsColor(in: self)
        markdownSurface?.applyTheme()
        bumpSurfaceEpoch()
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        // Before targeting a view inside the body: while surfaced, that view is
        // PARKED, and AppKit will happily focus it there.
        promoteForIncomingFocus()
        window?.makeFirstResponder(mode == .preview ? (markdownSurface.previewView ?? textView) : textView)
        return true
    }

    // MARK: - Surface residency (Option A, `.plans/38`)

    /// A markdown file tile was the HEAVIEST body in the real-gesture profile —
    /// a 183-block document re-measuring inside the camera cascade — and it is
    /// content that changes only when the file is reloaded, the mode switches, or
    /// the theme does. The ideal candidate for rendering from a surface at rest.
    ///
    /// The body handle is tracked (`activeBody`), not derived from `contentView`:
    /// this family swaps its content view between the source scroller, the
    /// markdown document and the unavailable-message placeholder, and while
    /// surfaced `contentView` is the surface host.
    private var activeBody: NSView?
    private var surfaceEpoch: UInt64 = 1

    override var surfaceableBody: NSView? { activeBody }
    override var surfaceContentRevision: UInt64? { surfaceEpoch }

    /// `activeBody` is a scroll view for some file kinds and a container holding
    /// one for others, so both shapes are covered — one level only, deliberately:
    /// this is polled per residency pass.
    override var surfaceScrollOffsets: [CGPoint] {
        guard let body = activeBody else { return [] }
        if let scrollView = body as? NSScrollView { return [scrollView.contentView.bounds.origin] }
        return body.subviews.compactMap { ($0 as? NSScrollView)?.contentView.bounds.origin }
    }

    /// Anything that changes what the body renders. Appearance is already in the
    /// revision vector; the epoch covers content and mode.
    private func bumpSurfaceEpoch() { surfaceEpoch &+= 1 }

    // MARK: - Markdown mode

    /// Switches the body in place. The tile keeps its identity, its persisted
    /// metadata, and its already-loaded text.
    func setMode(_ newMode: Mode) {
        guard presentation == .markdown, newMode != mode else { return }
        mode = newMode
        modeControl?.selectedSegment = newMode.segmentIndex
        markdownSurface.setMode(newMode)
        tile.metadata.markdownDocumentMode = newMode
        canvas?.updateTile(tile)
        showBody()
        window?.makeFirstResponder(newMode == .preview ? (markdownSurface.previewView ?? textView) : textView)
    }

    func textDidChange(_ notification: Notification) {
        guard presentation == .markdown else { return }
        loadedText = textView.string
        markdownSurface.draftDidChange(textView.string)
        setDirty(savedText != loadedText)
        bumpSurfaceEpoch()
    }

    @discardableResult
    func save(overwriteExternalChanges: Bool = false) -> Bool {
        guard presentation == .markdown, let filePath, let savedText else { return false }
        let currentDisk = FilePreview.load(path: filePath)
        if case let .text(diskText) = currentDisk, diskText != savedText, !overwriteExternalChanges {
            hasExternalConflict = true
            dirtyLabel.stringValue = "!"
            dirtyLabel.toolTip = "The file changed on disk"
            return false
        }
        do {
            try textView.string.write(to: URL(fileURLWithPath: filePath), atomically: true, encoding: .utf8)
            self.savedText = textView.string
            loadedText = textView.string
            hasExternalConflict = false
            setDirty(false)
            return true
        } catch {
            onSaveFailure?(error.localizedDescription)
            return false
        }
    }

    /// Reloads external edits only while the tile has no local draft. A dirty
    /// draft is never overwritten; it is marked conflicted for the next save.
    func refreshFromDisk() {
        guard presentation == .markdown, let filePath,
              case let .text(diskText) = FilePreview.load(path: filePath),
              diskText != savedText else { return }
        if isDirty {
            hasExternalConflict = true
            dirtyLabel.stringValue = "!"
            dirtyLabel.toolTip = "The file changed on disk"
        } else {
            savedText = diskText
            loadedText = diskText
            textView.string = diskText
            showBody()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s",
           presentation == .markdown {
            if hasExternalConflict {
                let alert = NSAlert()
                alert.messageText = "This file changed on disk"
                alert.informativeText = "Reload the disk version, overwrite it with your draft, or keep editing."
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Overwrite")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    setDirty(false)
                    hasExternalConflict = false
                    refreshFromDisk()
                case .alertSecondButtonReturn:
                    _ = save(overwriteExternalChanges: true)
                default: break
                }
            } else {
                _ = save()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func setDirty(_ dirty: Bool) {
        isDirty = dirty
        dirtyLabel.stringValue = dirty ? "•" : ""
        dirtyLabel.toolTip = dirty ? "Unsaved Markdown changes" : nil
        dirtyLabel.setAccessibilityLabel(dirty ? "Unsaved changes" : "Saved")
    }

    @objc private func modeControlChanged(_ sender: NSSegmentedControl) {
        setMode(Mode(segmentIndex: sender.selectedSegment) ?? .edit)
    }

    private func installModeControl() {
        guard modeControl == nil else { return }
        let control = NSSegmentedControl(labels: ["Preview", "Split", "Edit"], trackingMode: .selectOne, target: self, action: #selector(modeControlChanged(_:)))
        control.controlSize = .small
        control.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        // Keep all three actions equally sized; `labels:` otherwise gives the
        // longer Preview label a larger hit target and makes mode placement drift.
        for segment in 0..<control.segmentCount { control.setWidth(160 / 3, forSegment: segment) }
        control.selectedSegment = mode.segmentIndex
        control.setAccessibilityLabel("Markdown display mode")
        modeControl = control
        dirtyLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        dirtyLabel.textColor = NSColor.systemOrange
        dirtyLabel.alignment = .center
        referenceLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        referenceLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        referenceLabel.isHidden = true
        let stack = NSStackView(views: [referenceLabel, dirtyLabel, control])
        stack.orientation = .horizontal
        stack.spacing = 4
        titleAccessoryStack = stack
        setTitleBarAccessory(stack)
    }

    func setReferencedAgentTiles(_ agentTileIds: [UUID]) {
        let count = agentTileIds.count
        referenceLabel.stringValue = count == 1 ? "1 reference" : "\(count) references"
        referenceLabel.toolTip = count == 0 ? nil : "Referenced by \(count) agent\(count == 1 ? "" : "s")"
        referenceLabel.isHidden = count == 0
        guard count > 0 else {
            referenceLabel.menu = nil
            return
        }
        let menu = NSMenu(title: "Referenced by")
        for (index, tileId) in agentTileIds.enumerated() {
            let item = NSMenuItem(title: "Reveal agent \(index + 1)", action: #selector(revealReferencedAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tileId.uuidString
            menu.addItem(item)
        }
        referenceLabel.menu = menu
    }

    @objc private func revealReferencedAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tileId = UUID(uuidString: raw) else { return }
        onRevealReferencedAgentTile?(tileId)
    }

    /// Installs the body for the current mode from the loaded snapshot.
    private func showBody() {
        guard let loadedText else { return }
        // A mode switch arrives via a click, so `hitTest` has already promoted —
        // but this must hold even for a programmatic switch (`reveal(line:)`),
        // because `setContentView` below would replace the surface host and strand
        // the parked body.
        promoteForIncomingFocus()
        if presentation == .markdown {
            if textView.string != loadedText { textView.string = loadedText }
            markdownSurface.replaceDraft(loadedText)
            setContentView(markdownSurface.activeBody)
            activeBody = markdownSurface.activeBody
            if mode != .preview { applyPendingReveal() }
        } else {
            if textView.string != loadedText { textView.string = loadedText }
            setContentView(scrollView)
            activeBody = scrollView
            applyPendingReveal()
        }
        bumpSurfaceEpoch()
    }

    /// Scrolls the source view to a one-based line (and optional column) without
    /// persisting anything. Called when an agent link named `file.swift:42`.
    /// Markdown tiles switch to Source first: a coordinate refers to the text.
    func reveal(line: Int, column: Int? = nil) {
        guard line > 0 else { return }
        pendingReveal = (line, column)
        if presentation == .markdown, mode == .preview {
            setMode(.edit)
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
    var qaMarkdownDocument: FileMarkdownDocumentView? { markdownSurface.previewView }
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
            savedText = content
            presentation = filePath.map { FilePreview.presentation(forPath: $0) } ?? .sourceText
            if presentation == .markdown {
                configureMarkdownEditor()
                installModeControl()
                startExternalChangeMonitoring()
            }
            showBody()
        case let .unavailable(message):
            loadedText = nil
            showMessage(message)
        }
    }

    private func configureMarkdownEditor() {
        textView.isEditable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        scrollView.hasHorizontalScroller = false
    }

    private func startExternalChangeMonitoring() {
        guard window != nil, externalChangeTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFromDisk() }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalChangeTimer = timer
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
        promoteForIncomingFocus()
        setContentView(container)
        activeBody = container
        bumpSurfaceEpoch()
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
