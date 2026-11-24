import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts an editable plain-text NSTextView for note content.
@MainActor
final class NoteTileNSView: TileNSView, NSTextViewDelegate {
    typealias Mode = MarkdownDocumentMode
    enum SaveState: Equatable {
        case saved
        case saving
        case failed(String)
    }
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    let noteId: UUID
    private(set) var mode: Mode = .edit
    private var markdownSurface: MarkdownDocumentSurface!
    private var modeControl: ModeSegmentedControl?
    private let saveStateLabel = NSTextField(labelWithString: "Saved")
    private var activeBody: NSView?
    private(set) var saveState: SaveState = .saved

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

        markdownSurface = MarkdownDocumentSurface(
            textView: tv,
            sourceScrollView: sv,
            initialDraft: initialBody,
            mode: tile.metadata.markdownDocumentMode ?? (tile.frame.width >= 520 ? .split : .edit),
            theme: { [weak self] in self?.effectiveTokenTheme ?? .dark }
        )
        mode = markdownSurface.mode
        let body = markdownSurface.activeBody
        setContentView(body)
        activeBody = body
        tv.delegate = self
        tv.menu = MarkdownEditingCommands.makeContextMenu(
            target: self,
            action: #selector(applyMarkdownCommand(_:))
        )
        installModeControl()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
        markdownSurface?.applyTheme()
        setSaveState(saveState)
    }

    override func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] { [makeRevealInFinderMenuItem()] }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        // While surfaced, `textView` is parked; focusing it there would send every
        // keystroke into a view clipped out of every draw.
        promoteForIncomingFocus()
        window?.makeFirstResponder(mode == .preview ? (markdownSurface.previewView ?? textView) : textView)
        return true
    }

    func textDidChange(_ notification: Notification) {
        markdownSurface.draftDidChange(textView.string)
        setSaveState(.saving)
        surfaceEpoch &+= 1
        onTextChange?()
    }

    func markSaved() { setSaveState(.saved) }
    func markSaveFailed(_ message: String) { setSaveState(.failed(message)) }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        promoteForIncomingFocus()
        mode = newMode
        modeControl?.selectedSegment = newMode.segmentIndex
        markdownSurface.setMode(newMode)
        let body = markdownSurface.activeBody
        setContentView(body)
        activeBody = body
        markdownSurface.restorePresentationState()
        window?.makeFirstResponder(newMode == .preview ? (markdownSurface.previewView ?? textView) : textView)
        tile.metadata.markdownDocumentMode = newMode
        canvas?.updateTile(tile)
        surfaceEpoch &+= 1
    }

    @objc private func modeChanged(_ sender: ModeSegmentedControl) {
        setMode(Mode(segmentIndex: sender.selectedSegment) ?? .edit)
    }

    private func installModeControl() {
        let control = ModeSegmentedControl(labels: ["Preview", "Split", "Edit"], totalWidth: 160)
        control.target = self
        control.action = #selector(modeChanged(_:))
        control.selectedSegment = mode.segmentIndex
        control.setAccessibilityLabel("Note Markdown display mode")
        modeControl = control
        let formatControl = MarkdownEditingCommands.makeToolbarPopUp(
            target: self,
            action: #selector(applyMarkdownCommand(_:))
        )
        saveStateLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        saveStateLabel.alignment = .right
        saveStateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [saveStateLabel, formatControl, control])
        stack.orientation = .horizontal
        stack.spacing = 5
        setTitleBarAccessory(stack)
        setSaveState(.saved)
    }

    private func setSaveState(_ state: SaveState) {
        saveState = state
        switch state {
        case .saved:
            saveStateLabel.stringValue = "Saved"
            saveStateLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
            saveStateLabel.toolTip = nil
            saveStateLabel.setAccessibilityLabel("Note saved")
        case .saving:
            saveStateLabel.stringValue = "Saving…"
            saveStateLabel.textColor = AccentToken.accentWorking.color.nsColor(in: self)
            saveStateLabel.toolTip = nil
            saveStateLabel.setAccessibilityLabel("Saving note")
        case let .failed(message):
            saveStateLabel.stringValue = "Save failed"
            saveStateLabel.textColor = AccentToken.accentFailed.color.nsColor(in: self)
            saveStateLabel.toolTip = message
            saveStateLabel.setAccessibilityLabel("Note save failed: \(message)")
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command, .option],
           let key = event.charactersIgnoringModifiers,
           let selectedMode = ["1": Mode.preview, "2": .split, "3": .edit][key] {
            setMode(selectedMode)
            return true
        }
        if mode != .preview, MarkdownEditingCommands.handleKeyEquivalent(event, in: textView) {
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            saveAsMarkdown()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        MarkdownEditingCommands.handleCommand(commandSelector, in: textView)
    }

    @objc private func applyMarkdownCommand(_ sender: NSMenuItem) {
        guard let command = MarkdownEditingCommands.Command(rawValue: sender.tag) else { return }
        MarkdownEditingCommands.apply(command, in: textView)
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
    override var surfaceScrollOffsets: [CGPoint] { markdownSurface?.visibleScrollOrigins ?? [] }

    /// QA access to the real title-bar control.
    var qaModeControl: ModeSegmentedControl? { modeControl }

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

    /// Edit → Split → Edit on a real note, with the production mode switch clicked
    /// through the window and the note typed with real key events. The outcome
    /// asserted is the text the note would save, not a view-tree shape.
    static func runNoteSplitEditSelfCheck() throws {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: message) }
        }
        let tile = Tile(id: UUID(), kind: .note, title: "NOTE_SPLIT_EDIT", frame: TileFrame(x: 40, y: 40, width: 600, height: 300),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(noteId: UUID(), markdownDocumentMode: .edit))
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        let note = NoteTileNSView(tile: tile, noteId: tile.metadata.noteId ?? UUID(), initialBody: "")
        var saved = ""
        note.onTextChange = { saved = note.textView.string }
        canvas.install(tileView: note, for: tile)
        func settle() { window.contentView?.layoutSubtreeIfNeeded(); canvas.layoutSubtreeIfNeeded(); note.layoutSubtreeIfNeeded() }
        settle()
        try expect(note.mode == .edit, "the note starts in Edit")

        func click(_ control: ModeSegmentedControl, at fraction: CGFloat) throws {
            let point = control.convert(NSPoint(x: control.bounds.width * fraction, y: control.bounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                else { throw Failure(description: "could not create a mouse event") }
                return event
            }
            NSApplication.shared.postEvent(try mouse(.leftMouseUp), atStart: false)
            window.sendEvent(try mouse(.leftMouseDown))
            settle()
        }
        func type(_ text: String) throws {
            for character in text {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                                                   isARepeat: false, keyCode: 0)
                else { throw Failure(description: "could not create a key event") }
                guard let responder = window.firstResponder as? NSTextView else {
                    throw Failure(description: "typing after the switch has no text view to receive it; first responder \(String(describing: window.firstResponder))")
                }
                responder.keyDown(with: event)
            }
        }
        guard let control = note.qaModeControl else { throw Failure(description: "the note has no mode control") }

        _ = window.makeFirstResponder(note.textView)
        try type("ab")
        try expect(saved == "ab", "typing in Edit saves the text; saved \(saved.debugDescription)")

        try click(control, at: 0.5)
        try expect(note.mode == .split, "clicking Split installs Split")
        try expect(note.textView.window != nil && note.textView.isDescendant(of: note) && note.textView.enclosingScrollView?.frame.width ?? 0 > 40,
                   "Split shows the editor beside the preview; editor window \(String(describing: note.textView.window)), in tile \(note.textView.isDescendant(of: note)), width \(note.textView.enclosingScrollView?.frame.width ?? 0)")
        try type("cd")
        try expect(saved == "abcd" && note.textView.string == "abcd", "typing in Split reaches the saved text; saved \(saved.debugDescription)")

        try click(control, at: 5.0 / 6.0)
        try expect(note.mode == .edit, "clicking Edit installs Edit")
        try type("e")
        try expect(saved == "abcde", "typing after Split → Edit reaches the saved text; saved \(saved.debugDescription)")

        // Preview and back puts the caret where it was.
        note.textView.setSelectedRange(NSRange(location: 2, length: 0))
        try click(control, at: 1.0 / 6.0)
        try expect(note.mode == .preview, "clicking Preview installs Preview")
        try click(control, at: 5.0 / 6.0)
        try expect(note.mode == .edit && note.textView.selectedRange() == NSRange(location: 2, length: 0),
                   "Preview then Edit restores the caret; selection \(note.textView.selectedRange())")

        // The caret follows the user through Split, where the preview re-renders
        // a moment after every keystroke: that re-render must not move it.
        func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.35)) }
        note.textView.string = ""
        try click(control, at: 0.5)
        _ = window.makeFirstResponder(note.textView)
        try type("abc")
        spin()
        try expect(note.textView.selectedRange() == NSRange(location: 3, length: 0),
                   "typing in Split leaves the caret after the text once the preview re-renders; selection \(note.textView.selectedRange())")
        try click(control, at: 5.0 / 6.0)
        try type("X")
        try expect(saved == "abcX", "Split then Edit types at the caret, not the start; saved \(saved.debugDescription)")
        try click(control, at: 0.5)
        note.textView.setSelectedRange(NSRange(location: note.textView.string.utf16.count, length: 0))
        try type("END")
        spin()
        try click(control, at: 1.0 / 6.0)
        try click(control, at: 5.0 / 6.0)
        try type("Z")
        try expect(saved == "abcXENDZ", "Split, Preview then Edit types after the caret Split left; saved \(saved.debugDescription)")

        // The title-bar Share button never sits over the mode control.
        note.setTitleBarShareAction(true)
        var shownAtSomeWidth = false
        for width in [900, 760, 640, 560, 480] as [CGFloat] {
            note.frame = NSRect(x: 40, y: 40, width: width, height: 300)
            settle()
            note.layoutSubtreeIfNeeded()
            guard let share = note.qaTitleBarShareControl else { continue }
            shownAtSomeWidth = true
            let shareRect = note.convert(share.bounds, from: share)
            let modeRect = note.convert(control.bounds, from: control)
            try expect(!shareRect.intersects(modeRect), "at width \(width) the Share button \(shareRect) overlaps the mode control \(modeRect)")
        }
        try expect(shownAtSomeWidth, "the Share button must be visible at the widest width, or this proves nothing")
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
        try expect(focusBroker.activeSurface == .tile(tileId), "body click production focus router should keep note tile active; activeSurface=\(String(describing: focusBroker.activeSurface)) point=\(windowPoint) canvasPoint=\(canvasPoint) tileAtPoint=\(String(describing: canvas.tileId(at: canvasPoint))) firstResponder=\(String(describing: window.firstResponder)) hit=\(String(describing: hitView))")

        let firstResponderDescription = String(describing: window.firstResponder)
        let textViewHasFocus = window.firstResponder === noteView.textView
        let fieldEditorHasFocus = (window.firstResponder as? NSTextView)?.delegate === noteView.textView.delegate
        try expect(textViewHasFocus || fieldEditorHasFocus, "note body click should focus text view; firstResponder=\(firstResponderDescription), hitView=\(String(describing: hitView))")

        let sentinel = "x"
        try dispatchKey(sentinel, in: window)
        try expect(noteView.textView.string.contains(sentinel), "keyDown should edit note text; got \(noteView.textView.string.debugDescription)")

        guard let modeControl = noteView.qaModeControl else {
            throw CheckError.failed("note must install a Preview/Split/Edit control")
        }
        let splitPoint = modeControl.convert(
            NSPoint(x: modeControl.bounds.width * 0.5, y: modeControl.bounds.midY),
            to: nil
        )
        let splitWorldHit = canvas.worldPlane.hitTest(canvas.worldPlane.convert(splitPoint, from: nil))
        try expect(splitWorldHit === modeControl || splitWorldHit?.isDescendant(of: modeControl) == true,
                   "title-bar Split hit must route to its native control; hit=\(String(describing: splitWorldHit))")
        try dispatchClick(at: splitPoint, in: window)
        noteView.layoutSubtreeIfNeeded()
        try expect(noteView.mode == .split && modeControl.selectedSegment == 1,
                   "a real title-bar click must install Split")
        try expect(noteView.textView.string.contains(sentinel),
                   "mode switching must retain the canonical note draft")

        let editPoint = modeControl.convert(
            NSPoint(x: modeControl.bounds.width * (5.0 / 6.0), y: modeControl.bounds.midY),
            to: nil
        )
        let editWorldHit = canvas.worldPlane.hitTest(canvas.worldPlane.convert(editPoint, from: nil))
        try expect(editWorldHit === modeControl || editWorldHit?.isDescendant(of: modeControl) == true,
                   "title-bar Edit hit must route to its native control; hit=\(String(describing: editWorldHit))")
        try dispatchClick(at: editPoint, in: window)
        let sourceHasFocus = window.firstResponder === noteView.textView
            || (window.firstResponder as? NSTextView)?.delegate === noteView.textView.delegate
        try expect(noteView.mode == .edit && sourceHasFocus,
                   "Edit must restore the source editor and first responder")
        try expect(noteView.tile.metadata.markdownDocumentMode == .edit,
                   "the selected note mode must be stored in tile metadata")

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
