import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts an editable plain-text NSTextView for note content.
@MainActor
final class NoteTileNSView: TileNSView, NSTextViewDelegate {
    enum Mode { case preview, edit }
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    let noteId: UUID
    private(set) var mode: Mode = .edit
    private var markdownView: FileMarkdownDocumentView?
    private var modeControl: NSSegmentedControl?
    private var activeBody: NSView?

    /// Fires whenever text changes; the app wires this to debounced persistence.
    var onTextChange: (() -> Void)?
    var onSaveAsMarkdownRequested: ((URL) -> Void)?

    init(tile: Tile, noteId: UUID, initialBody: String) {
        self.noteId = noteId

        let tv = NSTextView()
        tv.isEditable = true
        tv.allowsUndo = true
        tv.isRichText = false
        tv.font = NSFont.token(.bodyMono)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = initialBody
        // NSClipView drives the document view's frame via autoresizing — mixing
        // in constraints leaves the text view at zero height (invisible body).
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv

        super.init(tile: tile)

        setContentView(sv)
        activeBody = sv
        tv.delegate = self
        installModeControl()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
        markdownView?.applyTheme(effectiveTokenTheme)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        // While surfaced, `textView` is parked; focusing it there would send every
        // keystroke into a view clipped out of every draw.
        promoteForIncomingFocus()
        window?.makeFirstResponder(mode == .preview ? (markdownView ?? textView) : textView)
        return true
    }

    func textDidChange(_ notification: Notification) {
        surfaceEpoch &+= 1
        onTextChange?()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        promoteForIncomingFocus()
        mode = newMode
        modeControl?.selectedSegment = newMode == .preview ? 0 : 1
        if newMode == .preview {
            let view = markdownView ?? FileMarkdownDocumentView(frame: bounds)
            markdownView = view
            view.apply(markdown: textView.string, theme: effectiveTokenTheme)
            setContentView(view)
            activeBody = view
        } else {
            setContentView(scrollView)
            activeBody = scrollView
        }
        surfaceEpoch &+= 1
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 0 ? .preview : .edit)
    }

    private func installModeControl() {
        let control = NSSegmentedControl(labels: ["Preview", "Edit"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        control.controlSize = .small
        control.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        control.selectedSegment = 1
        control.setAccessibilityLabel("Note Markdown display mode")
        modeControl = control
        setTitleBarAccessory(control)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            saveAsMarkdown()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func saveAsMarkdown() {
        let panel = NSSavePanel()
        let base = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = "\(base.isEmpty ? "note" : base).md"
        panel.title = "Save Note as Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onSaveAsMarkdownRequested?(url)
    }

    // MARK: - Surface residency (Option A, `.plans/38`)

    /// A note is static text except while it is being edited — and while it is
    /// being edited it holds the first responder, which the liveness rule already
    /// keeps native. `textDidChange` bumps the epoch so a note edited moments ago
    /// re-bakes before it is next surfaced.
    private var surfaceEpoch: UInt64 = 1
    override var surfaceableBody: NSView? { activeBody }
    override var surfaceContentRevision: UInt64? { surfaceEpoch }
    override var surfaceScrollOffsets: [CGPoint] {
        if let scroll = activeBody as? NSScrollView { return [scroll.contentView.bounds.origin] }
        return activeBody?.subviews.compactMap { ($0 as? NSScrollView)?.contentView.bounds.origin } ?? []
    }

    // MARK: - Export (A4)

    /// Pure export payload: the note body plus a suggested filename derived from
    /// the tile title (sanitized, `.txt`). Testable without any save panel.
    func exportContent() -> (text: String, suggestedFilename: String) {
        let body = textView.string
        let trimmedTitle = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedTitle.isEmpty ? "note" : trimmedTitle
        let sanitized = base
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
        return (body, "\(sanitized).txt")
    }

    /// `⌘E` — present a save panel seeded from `exportContent()` and write the
    /// body on confirm. Thin AppKit shell over the pure payload; never invoked by
    /// self-checks (would block the matrix on `runModal`).
    func exportToFile() {
        let content = exportContent()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = content.suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func runNoteClickFocusSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        func makeMouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                throw CheckError.failed("could not create mouse event \(type)")
            }
            return event
        }

        func dispatchClick(at windowPoint: NSPoint, in window: NSWindow) throws {
            let down = try makeMouse(.leftMouseDown, at: windowPoint, in: window)
            let up = try makeMouse(.leftMouseUp, at: windowPoint, in: window)
            // NSTextView may enter AppKit mouse tracking during mouseDown and
            // wait for the matching mouseUp. Queue the mouseUp before sending
            // mouseDown so the production event path is exercised without a
            // self-check deadlock.
            NSApplication.shared.postEvent(up, atStart: false)
            window.sendEvent(down)
        }

        func dispatchKey(_ characters: String, in window: NSWindow) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else {
                throw CheckError.failed("could not create key event")
            }
            window.sendEvent(event)
        }

        let noteId = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        let tile = Tile(
            id: tileId,
            kind: .note,
            title: "NOTE_CLICK_FOCUS",
            frame: TileFrame(x: 80, y: 80, width: 360, height: 240),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(noteId: noteId)
        )
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        let focusBroker = FocusBroker()
        canvas.focusBroker = focusBroker
        canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let noteView = NoteTileNSView(tile: tile, noteId: noteId, initialBody: "")
        canvas.install(tileView: noteView, for: tile)

        window.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        noteView.layoutSubtreeIfNeeded()
        noteView.scrollView.layoutSubtreeIfNeeded()
        noteView.textView.layoutSubtreeIfNeeded()

        let titlePoint = noteView.convert(NSPoint(x: noteView.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        noteView.mouseDown(with: try makeMouse(.leftMouseDown, at: titlePoint, in: window))
        noteView.mouseUp(with: try makeMouse(.leftMouseUp, at: titlePoint, in: window))
        try expect(focusBroker.activeSurface == .tile(tileId), "title click should route focus through broker; activeSurface=\(String(describing: focusBroker.activeSurface))")
        try expect(canvas.canvasState.lastActiveTileId == tileId, "title click broker callback should mark tile active")

        let textLocalPoint = NSPoint(x: max(12, noteView.textView.bounds.midX), y: max(12, noteView.textView.bounds.midY))
        let windowPoint = noteView.textView.convert(textLocalPoint, to: nil)
        let canvasPoint = canvas.convert(windowPoint, from: nil)
        let hitView = window.contentView?.hitTest(canvasPoint)

        try dispatchClick(at: windowPoint, in: window)
        AppDelegate.routeTileClickFocus(at: windowPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .tile(tileId), "body click production focus router should keep note tile active; activeSurface=\(String(describing: focusBroker.activeSurface))")

        let firstResponderDescription = String(describing: window.firstResponder)
        let textViewHasFocus = window.firstResponder === noteView.textView
        let fieldEditorHasFocus = (window.firstResponder as? NSTextView)?.delegate === noteView.textView.delegate
        try expect(textViewHasFocus || fieldEditorHasFocus, "note body click should focus text view; firstResponder=\(firstResponderDescription), hitView=\(String(describing: hitView))")

        let sentinel = "x"
        try dispatchKey(sentinel, in: window)
        try expect(noteView.textView.string.contains(sentinel), "keyDown should edit note text; got \(noteView.textView.string.debugDescription)")

        let manifest: [String: Any] = [
            "check": "note-click-focus",
            "tileId": tileId.uuidString,
            "noteId": noteId.uuidString,
            "titlePoint": ["x": titlePoint.x, "y": titlePoint.y],
            "brokerActiveSurface": String(describing: focusBroker.activeSurface),
            "windowPoint": ["x": windowPoint.x, "y": windowPoint.y],
            "canvasPoint": ["x": canvasPoint.x, "y": canvasPoint.y],
            "hitView": String(describing: hitView),
            "firstResponder": firstResponderDescription,
            "text": noteView.textView.string
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("note-click-focus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }
}
