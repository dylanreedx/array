import AppKit
import ContinuumRevivedCore
import Foundation
import ObjectiveC

// Canvas navigation focus — three witnesses, every key and click through
// `NSApp.sendEvent` with the production monitors installed.
//
// (a) `--leader-composer-hold-check`: the hold-⌥ leader opened over a focused
//     composer NAVIGATES. Its arrows used to be handed to the text (they moved
//     the caret a word and closed the leader), so holding ⌥ over an agent
//     looked dead. ⌥-characters still type.
// (b) `--leader-return-focus-check`: ⌥↩ with the leader open focuses the
//     current tile, fitting as much of it as fits, and leaves its composer
//     first responder. Over an EMPTY composer that ⌥↩ used to reach the text and
//     insert a newline; a composer holding a draft still queues it.
// (c) `--header-click-focus-check`: a header click focuses the tile the same
//     way, with "Click a header to focus its tile" on; off, the camera stays;
//     either way a header drag still moves the tile.
@MainActor
enum CanvasNavFocusChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Off every display, a window never becomes key by itself; the header-click
    /// leg needs AppKit to deliver the press as it would to the key window.
    private final class AlwaysKeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private final class RecordingSink: AgentTileActionSink {
        var intents: [AgentComposerIntent] = []
        func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
            intents.append(intent)
            return .accepted
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    /// Past the production dwell, with margin, so a dwell that would fire does.
    private static var pastDwell: TimeInterval {
        max(0.05, TimeInterval(NavKeymap.default.effectiveLeaderDwellMs) / 1000) + 0.25
    }

    /// An agent tile plus a note to its right, in an off-screen key window with
    /// the production hotkey monitor installed.
    @MainActor private struct ComposerFixture {
        let app: AppDelegate
        let canvas: CanvasNSView
        let window: NSWindow
        let agents: [UUID: ManagedAgentTileNSView]
        let sink: RecordingSink

        func composer(_ id: UUID) -> AgentComposerView { agents[id]!.qaComposerForChecks! }
        var leaderOpen: Bool { app.focusBroker.activeSurface == .modal(.leader) }

        func flags(_ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 58) throws {
            guard let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "could not make flagsChanged") }
            NSApp.sendEvent(event)
        }

        func key(_ characters: String, ignoring: String? = nil, keyCode: UInt16, mods: NSEvent.ModifierFlags) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "could not make keyDown") }
            NSApp.sendEvent(event)
        }

        func setDraft(_ id: UUID, _ text: String) {
            composer(id).apply(.init(text: text, selection: NSRange(location: (text as NSString).length, length: 0), revision: 1))
        }

        func worldFrame(_ id: UUID) -> CGRect? {
            canvas.navigationTileSnapshot(for: id).map {
                CGRect(x: $0.worldFrame.x, y: $0.worldFrame.y, width: $0.worldFrame.width, height: $0.worldFrame.height)
            }
        }
    }

    private static func makeComposerFixture(
        agents specs: [(UUID, TileFrame)], note: (UUID, TileFrame), viewport: CanvasViewport, size: NSSize
    ) throws -> ComposerFixture {
        var tiles = specs.enumerated().map { rank, spec in
            Tile(id: spec.0, kind: .managedAgent, title: "AGENT \(rank)", frame: spec.1,
                 zPosition: .fromLegacyRank(rank + 1), runtimeRef: nil,
                 metadata: TileMetadata(launchProfileId: "managed"))
        }
        tiles.append(Tile(id: note.0, kind: .note, title: "NOTE", frame: note.1,
                          zPosition: .fromLegacyRank(specs.count + 1), runtimeRef: nil, metadata: TileMetadata()))
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: viewport, tiles: tiles, groups: [], lastActiveTileId: specs.first?.0))
        canvas.frame = NSRect(origin: .zero, size: size)
        let window = KeyableWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        let app = AppDelegate()
        app.canvasView = canvas
        canvas.focusBroker = app.focusBroker
        app.focusBroker.onAcceptedTileFocus = { [weak canvas] id in canvas?.markActive(tileId: id) }
        let sink = RecordingSink()
        var views: [UUID: ManagedAgentTileNSView] = [:]
        for tile in tiles where tile.kind == .managedAgent {
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            guard let composer = view.qaComposerForChecks else { throw Failure(description: "no v2 composer") }
            view.layoutSubtreeIfNeeded()
            composer.layoutSubtreeIfNeeded()
            composer.bindActionSink(sink, agentID: AgentID(rawValue: UUID()), snapshot: AgentTileTurnSnapshot(
                state: .working,
                capabilities: AgentTurnCapabilities(canSend: false, canStop: true, canSteer: true, canQueue: true),
                turnStartedAt: Date()))
            views[tile.id] = view
        }
        if let noteTile = tiles.last { canvas.install(tileView: TileNSView(tile: noteTile), for: noteTile) }
        canvas.layoutSubtreeIfNeeded()
        app.qaAttachWindowInstallingHotkeyMonitor(window)
        return ComposerFixture(app: app, canvas: canvas, window: window, agents: views, sink: sink)
    }

    // MARK: - (a) hold ⌥ over a focused composer

    static func runLeaderComposerHold() throws -> String {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: "leader over composer: " + message) }
        }
        let agentId = UUID(uuidString: "00000000-0000-0000-0000-00000000CF0A")!
        let noteId = UUID(uuidString: "00000000-0000-0000-0000-00000000CF0B")!
        let f = try makeComposerFixture(
            agents: [(agentId, TileFrame(x: 40, y: 40, width: 440, height: 340))],
            note: (noteId, TileFrame(x: 620, y: 40, width: 240, height: 200)),
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), size: NSSize(width: 1000, height: 700))
        defer { f.window.orderOut(nil) }
        let composer = f.composer(agentId)
        _ = f.app.focusBroker.requestFocus(.tile(agentId), reason: .userClick)
        try expect(f.window.firstResponder === composer.textView, "selecting the agent must focus its composer")

        // 1. ⌥ held past the dwell opens Quick Jump over the composer.
        f.setDraft(agentId, "alpha beta")
        composer.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try f.flags(.option)
        spin(pastDwell)
        try expect(f.leaderOpen, "holding ⌥ in the composer must open the leader")
        try expect(f.canvas.navModeOverlayQASnapshot().isInstalled, "the Quick Jump overlay must be up over the composer")

        // 2. With it open, ⌥→ is the leader's: it docks the tile beside its
        //    neighbour, and the caret stays where it was. Esc puts it back.
        let before = f.worldFrame(agentId)
        try f.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, mods: [.option, .function, .numericPad])
        let docked = f.worldFrame(agentId)
        try expect(docked != nil && docked != before,
                   "⌥→ with the leader open over a composer must dock the tile; it stayed at \(String(describing: before))")
        try expect(composer.textView.selectedRange().location == 0,
                   "⌥→ taken by the leader must not also move the caret, caret at \(composer.textView.selectedRange().location)")
        try expect(f.leaderOpen, "the leader must stay open while docking")
        try f.key("\u{1B}", keyCode: 53, mods: .option)
        try expect(f.worldFrame(agentId) == before, "Esc must restore the docked tile")
        try f.flags([])
        spin(0.05)

        // 3. ⌥ held, then an ⌥-letter the leader has no label for: the leader
        //    closes and the character reaches the composer.
        f.setDraft(agentId, "")
        try f.flags(.option)
        spin(pastDwell)
        try expect(f.leaderOpen, "precondition: ⌥ held opens the leader")
        try f.key("\u{153}", ignoring: "q", keyCode: 12, mods: .option)
        try expect(!f.leaderOpen, "a key the leader does not own must close it")
        try expect(composer.textView.string == "\u{153}",
                   "⌥q with the leader open must type œ, text is \(composer.textView.string.debugDescription)")
        try f.flags([])

        // 4. A quick ⌥-chord (before the dwell) types, as it always has.
        try f.flags(.option)
        try f.key("#", ignoring: "3", keyCode: 20, mods: .option)
        try f.flags([])
        try expect(composer.textView.string == "\u{153}#",
                   "a quick ⌥3 must type #, text is \(composer.textView.string.debugDescription)")
        try expect(f.window.firstResponder === composer.textView, "the composer must keep the keyboard")

        // 5. A quick ⌥→ (before the dwell) moves the caret a word, and the
        //    leader never opens under it, even once the dwell would have ended.
        let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        f.setDraft(agentId, "alpha beta")
        composer.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try f.flags(.option)
        try f.key(arrow, keyCode: 124, mods: [.option, .function, .numericPad])
        spin(pastDwell)
        try expect(!f.leaderOpen && !f.canvas.navModeOverlayQASnapshot().isInstalled,
                   "a quick ⌥→ in the composer must not open the leader")
        try expect(composer.textView.selectedRange().location == 5,
                   "a quick ⌥→ must move the caret a word, caret at \(composer.textView.selectedRange().location)")
        try f.flags([])
        spin(0.05)

        // 6. Outside a composer (a note's text), ⌥ held past the dwell still
        //    opens the leader, but ⌥→ stays a word jump and closes it.
        let editableNoteId = UUID(uuidString: "00000000-0000-0000-0000-00000000CF0C")!
        let editableTile = Tile(id: editableNoteId, kind: .note, title: "EDIT NOTE",
                                frame: TileFrame(x: 620, y: 300, width: 240, height: 200),
                                zPosition: .fromLegacyRank(3), runtimeRef: nil, metadata: TileMetadata())
        let noteView = NoteTileNSView(tile: editableTile, noteId: UUID(), initialBody: "gamma delta")
        f.canvas.install(tileView: noteView, for: editableTile)
        noteView.layoutSubtreeIfNeeded()
        let noteText = noteView.textView
        _ = f.app.focusBroker.requestFocus(.tile(editableNoteId), reason: .userClick)
        if f.window.firstResponder !== noteText { _ = f.window.makeFirstResponder(noteText) }
        try expect(f.window.firstResponder === noteText && noteText.isEditable, "the note text must take the keyboard")
        noteText.setSelectedRange(NSRange(location: 0, length: 0))
        try f.flags(.option)
        spin(pastDwell)
        try expect(f.leaderOpen, "holding ⌥ over note text must still open the leader")
        try f.key(arrow, keyCode: 124, mods: [.option, .function, .numericPad])
        try expect(!f.leaderOpen, "⌥→ over note text must close the leader")
        try expect(noteText.selectedRange().location == 5,
                   "⌥→ over note text must move the caret a word, caret at \(noteText.selectedRange().location), responder \(String(describing: f.window.firstResponder))")
        try f.flags([])
        return "a quick ⌥→ in the composer jumps a word with no leader, ⌥→ over note text stays a word jump; "
            + "⌥ held over a focused composer opens Quick Jump, ⌥→ docks the tile (caret untouched, Esc restores), a held ⌥q types œ and a quick ⌥3 types #"
    }

    // MARK: - (b) ⌥↩ focuses the current tile

    static func runLeaderReturnFocus() throws -> String {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: "leader ⌥↩ focus: " + message) }
        }
        let fitsId = UUID(uuidString: "00000000-0000-0000-0000-00000000CF1A")!
        let tallId = UUID(uuidString: "00000000-0000-0000-0000-00000000CF1B")!
        let noteId = UUID(uuidString: "00000000-0000-0000-0000-00000000CF1C")!
        let size = NSSize(width: 1000, height: 700)
        // 600×800 does not fit at working zoom (720 pt tall on a 700 pt screen)
        // but does at 0.715, above the readable floor: the whole tile can show.
        let fits = TileFrame(x: 0, y: 0, width: 600, height: 800)
        // 600×1600 cannot fit readably: the composer end must show.
        let tall = TileFrame(x: 2000, y: 0, width: 600, height: 1600)
        let f = try makeComposerFixture(
            agents: [(fitsId, fits), (tallId, tall)],
            note: (noteId, TileFrame(x: 700, y: 0, width: 240, height: 200)),
            viewport: CanvasViewport(x: 300, y: 0, zoom: 1), size: size)
        defer { f.window.orderOut(nil) }

        // 1. Empty composer focused, leader open: ⌥↩ frames the whole tile and
        //    leaves the composer first responder, with no newline typed.
        _ = f.app.focusBroker.requestFocus(.tile(fitsId), reason: .userClick)
        try expect(f.window.firstResponder === f.composer(fitsId).textView, "precondition: the composer has the keyboard")
        f.canvas.setViewport(CanvasViewport(x: 300, y: 0, zoom: 1))
        try expect(!f.canvas.isInUsableView(f.worldFrame(fitsId)!), "precondition: the tile starts partly off screen")
        f.setDraft(fitsId, "")
        try f.flags(.option)
        spin(pastDwell)
        try expect(f.leaderOpen, "precondition: ⌥ held opens the leader")
        try f.key("\r", keyCode: 36, mods: .option)
        spin(0.05)
        try f.flags([])
        try expect(!f.leaderOpen, "⌥↩ must close the leader")
        try expect(f.composer(fitsId).textView.string.isEmpty,
                   "⌥↩ must not reach an empty composer, text is \(f.composer(fitsId).textView.string.debugDescription)")
        try expect(f.canvas.isInUsableView(f.worldFrame(fitsId)!),
                   "⌥↩ must fit the whole tile on screen; viewport \(f.canvas.viewport), tile \(fits)")
        try expect(f.canvas.viewport.zoom >= CameraFraming.minimumReadableZoom(for: .managedAgent) - 0.0001,
                   "the fitted zoom must stay readable, got \(f.canvas.viewport.zoom)")
        try expect(f.app.focusBroker.activeSurface == .tile(fitsId), "the tile must hold input scope, got \(String(describing: f.app.focusBroker.activeSurface))")
        try expect(f.window.firstResponder === f.composer(fitsId).textView, "the composer must be first responder")
        let framed = f.canvas.viewport

        // 2. Again, already framed: the camera stays put.
        try f.flags(.option)
        spin(pastDwell)
        try f.key("\r", keyCode: 36, mods: .option)
        try f.flags([])
        try expect(f.canvas.viewport == framed, "re-focusing a framed tile must not move the camera, got \(f.canvas.viewport)")

        // 3. A composer holding a draft keeps its ⌥↩: it queues, the camera stays.
        f.setDraft(fitsId, "after this")
        try f.flags(.option)
        spin(pastDwell)
        try expect(f.leaderOpen, "precondition: ⌥ held opens the leader")
        try f.key("\r", keyCode: 36, mods: .option)
        let deadline = Date().addingTimeInterval(2)
        while f.sink.intents.isEmpty, Date() < deadline { spin(0.02) }
        try f.flags([])
        try expect(f.sink.intents == [.queue(AgentPrompt("after this"))],
                   "⌥↩ over a working composer with a draft must queue it, got \(f.sink.intents)")
        try expect(!f.leaderOpen, "the queue must close the leader")

        // 4. Too tall to fit readably: readable zoom, the composer end in view.
        _ = f.app.focusBroker.requestFocus(.tile(tallId), reason: .userClick)
        f.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        f.setDraft(tallId, "")
        try f.flags(.option)
        spin(pastDwell)
        try f.key("\r", keyCode: 36, mods: .option)
        try f.flags([])
        let readable = CameraFraming.minimumReadableZoom(for: .managedAgent)
        let vp = f.canvas.viewport
        try expect(abs(vp.zoom - readable) < 0.0001, "a tile too tall to fit must land at the readable zoom \(readable), got \(vp.zoom)")
        let bottomOnScreen = (tall.y + tall.height - vp.y) * vp.zoom
        try expect(bottomOnScreen > 0 && bottomOnScreen <= Double(size.height),
                   "the tall tile's composer end must be on screen; its bottom sits at \(bottomOnScreen) of \(size.height)")
        let leftOnScreen = (tall.x - vp.x) * vp.zoom, rightOnScreen = (tall.x + tall.width - vp.x) * vp.zoom
        try expect(leftOnScreen >= 0 && rightOnScreen <= Double(size.width), "the tall tile's width must fit, got \(leftOnScreen)…\(rightOnScreen)")
        try expect(f.window.firstResponder === f.composer(tallId).textView, "the tall tile's composer must be first responder")
        return "⌥↩ with Quick Jump open over an empty composer fits the whole 600×800 agent at zoom \(String(format: "%.3f", framed.zoom)) and keeps its composer focused (no newline); a repeat keeps the camera; a draft still queues; a 600×1600 agent lands at readable zoom with its composer end on screen"
    }

    // MARK: - (c) header click

    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    static func runHeaderClickFocus() throws -> String {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: "header click focus: " + message) }
        }
        acceptFirstMouseEverywhere()
        let fixture = try TileInsertSlideChecks.makeFixture("header-click-focus")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("header click focus")
        let canvas = m.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        let suite = "header-click-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.headerClickDefaults = defaults
        let window = AlwaysKeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        m.delegate.qaInstallTileFocusMonitor()
        defer { m.delegate.qaRemoveTileFocusMonitor() }

        let target = TileInsertSlideChecks.tileD
        func world(_ id: UUID) -> CGRect? {
            canvas.navigationTileSnapshot(for: id).map {
                CGRect(x: $0.worldFrame.x, y: $0.worldFrame.y, width: $0.worldFrame.width, height: $0.worldFrame.height)
            }
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(description: "could not make \(type)") }
            NSApp.sendEvent(event)
        }
        /// A visible window point on the target's header that the window's own
        /// hit test gives to the tile — bare header, not its title or controls.
        func headerPoint() throws -> NSPoint {
            guard let view = canvas.tileView(for: target) else { throw Failure(description: "tile D has no view") }
            let visible = view.visibleRect
            let title = view.titleRectInTileSpaceForQA
            var x = visible.minX + 24
            while x < visible.maxX - 24 {
                let local = NSPoint(x: x, y: TileNSView.titleBarHeight / 2)
                let point = view.convert(local, to: nil)
                if !title.contains(local), window.contentView?.superview?.hitTest(point) === view { return point }
                x += 4
            }
            throw Failure(description: "tile D shows no bare header to click")
        }
        func click() throws {
            let point = try headerPoint()
            try mouse(.leftMouseDown, point)
            try mouse(.leftMouseUp, point)
            spin(NSEvent.doubleClickInterval + 0.15)
            canvas.layoutSubtreeIfNeeded()
        }
        // D sits at x 1264…1584 in world space; a camera at x 1300 cuts its left.
        let start = CanvasViewport(x: 1300, y: 250, zoom: 1)

        // 1. Setting on (the default): a header click fits D and focuses it.
        try expect(TileHeaderClickConfig.clickFocuses(defaults: defaults), "the setting must default to on")
        canvas.setViewport(start)
        canvas.layoutSubtreeIfNeeded()
        try expect(!canvas.isInUsableView(world(target)!), "precondition: D starts partly off screen")
        try click()
        try expect(canvas.isInUsableView(world(target)!),
                   "with the setting on, a header click must bring the whole tile on screen; viewport \(canvas.viewport), tile \(String(describing: world(target)))")
        try expect(m.delegate.qaFocusBroker.activeSurface == .tile(target),
                   "the clicked tile must hold input scope, got \(String(describing: m.delegate.qaFocusBroker.activeSurface))")
        let framed = canvas.viewport
        try click()
        try expect(canvas.viewport == framed, "clicking a framed tile's header again must not move the camera")

        // 2. Setting off: the click selects as before and the camera stays.
        defaults.set(false, forKey: TileHeaderClickConfig.focusKey)
        canvas.setViewport(start)
        canvas.layoutSubtreeIfNeeded()
        try click()
        try expect(canvas.viewport == start, "with the setting off, a header click must not move the camera, got \(canvas.viewport)")
        try expect(m.delegate.qaFocusBroker.activeSurface == .tile(target), "a header click must still select the tile")

        // 3. Setting on, a header DRAG moves the tile and never frames it.
        defaults.set(true, forKey: TileHeaderClickConfig.focusKey)
        canvas.setViewport(start)
        canvas.layoutSubtreeIfNeeded()
        let before = world(target)!
        let grab = try headerPoint()
        try mouse(.leftMouseDown, grab)
        for step in 1...12 {
            try mouse(.leftMouseDragged, NSPoint(x: grab.x + Double(step) * 20, y: grab.y - Double(step) * 20))
        }
        try mouse(.leftMouseUp, NSPoint(x: grab.x + 240, y: grab.y - 240))
        spin(NSEvent.doubleClickInterval + 0.15)
        canvas.layoutSubtreeIfNeeded()
        let after = world(target)!
        try expect(after.origin != before.origin, "a header drag must still move the tile, it stayed at \(before.origin)")
        try expect(canvas.viewport == start, "a header drag must not frame the tile, camera moved to \(canvas.viewport)")
        return "with the setting on a header click fits the tile on screen and takes its scope (a repeat keeps the camera); off, the camera stays; a header drag moved the tile \(before.origin) → \(after.origin) without framing"
    }
}
