import AppKit
import ContinuumRevivedCore
import Foundation

// Confidence pass S6 — the hold-⌥ leader against the keys it does not own.
//
// The leader's key monitor runs ahead of every responder. With a 0 ms dwell it
// opened the instant ⌥ went down, took Return as "activate tile" and swallowed
// everything else, so ⌥↩ (queue, D1) never reached the composer, and ⌥-arrow
// word movement and ⌥-characters (# on a UK layout) died in every text field.
// The composer's own key checks drive `ComposerTextView.keyDown` directly and so
// never met the monitor; they stayed green while the feature was broken.
//
// Every key here goes through `NSApp.sendEvent` — the production order: the
// app's local monitors (installed by the production `installHotkeyMonitor`),
// then the window, then the first responder — with the production default
// dwell, never an override.
extension AppDelegate {
    @MainActor
    static func runComposerKeyRoutingSelfCheck() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: "composer key routing: " + message) }
        }
        /// Off every display, but key: the field editor and key routing need one.
        final class KeyableFixtureWindow: NSWindow {
            override var canBecomeKey: Bool { true }
        }
        final class RecordingSink: AgentTileActionSink {
            var intents: [AgentComposerIntent] = []
            func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
                intents.append(intent)
                return .accepted
            }
        }

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-0000000005E6")!
        let tile = Tile(
            id: tileId, kind: .managedAgent, title: "KEYS",
            frame: TileFrame(x: 40, y: 40, width: 440, height: 340),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed"))
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: tileId))
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = KeyableFixtureWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        let app = AppDelegate()
        app.canvasView = canvas
        canvas.focusBroker = app.focusBroker
        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        guard let composer = tileView.qaComposerForChecks else { throw Failure(description: "composer key routing: no v2 composer") }
        canvas.layoutSubtreeIfNeeded()
        tileView.layoutSubtreeIfNeeded()
        composer.layoutSubtreeIfNeeded()
        let sink = RecordingSink()
        composer.bindActionSink(sink, agentID: AgentID(rawValue: UUID()), snapshot: AgentTileTurnSnapshot(
            state: .working,
            capabilities: AgentTurnCapabilities(canSend: false, canStop: true, canSteer: true, canQueue: true),
            turnStartedAt: Date()))
        app.qaAttachWindowInstallingHotkeyMonitor(window)

        func spin(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func flags(_ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 58) throws {
            guard let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "composer key routing: could not make flagsChanged") }
            NSApp.sendEvent(event)
        }
        func key(_ characters: String, ignoring: String? = nil, keyCode: UInt16, mods: NSEvent.ModifierFlags) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "composer key routing: could not make keyDown") }
            NSApp.sendEvent(event)
        }
        func setDraft(_ text: String, caret: Int) {
            composer.apply(.init(text: text, selection: NSRange(location: caret, length: 0), revision: 1))
        }
        var leaderOpen: Bool { app.focusBroker.activeSurface == .modal(.leader) }
        // Past the production dwell, with margin, so a dwell that WOULD fire does.
        let pastDwell = max(0.05, TimeInterval(NavKeymap.default.effectiveLeaderDwellMs) / 1000) + 0.25

        // 1. Composer focused, a turn working: ⌥ held past the dwell never opens
        //    the leader over a text input, and ⌥↩ queues.
        try expect(window.makeFirstResponder(composer.textView), "the composer must take first responder")
        setDraft("after this", caret: 10)
        try flags(.option)
        spin(pastDwell)
        try expect(!leaderOpen, "holding ⌥ in the composer must not open the leader")
        try key("\r", keyCode: 36, mods: .option)
        let deadline = Date().addingTimeInterval(2)
        while sink.intents.isEmpty, Date() < deadline { spin(0.02) }
        try expect(sink.intents == [.queue(AgentPrompt("after this"))],
                   "⌥↩ in a working composer must queue through the real key path, got \(sink.intents)")
        try flags([])
        spin(0.1)

        // 2. ⌥→ is word movement in the composer.
        setDraft("alpha beta", caret: 0)
        try flags(.option)
        try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, mods: [.option, .function, .numericPad])
        try flags([])
        try expect(composer.textView.selectedRange().location == 5,
                   "⌥→ must move the caret one word in the composer, caret at \(composer.textView.selectedRange().location)")
        try expect(!leaderOpen, "⌥→ in the composer must not open the leader")

        // 3. An ⌥-character (UK layout ⌥3 = #) is typed, not swallowed.
        setDraft("issue ", caret: 6)
        try flags(.option)
        try key("#", ignoring: "3", keyCode: 20, mods: .option)
        try flags([])
        try expect(composer.textView.string == "issue #",
                   "⌥3 (#) must reach the composer, text is \(composer.textView.string.debugDescription)")

        // 4. Off any text input, ⌥ followed by another key before the dwell is a
        //    chord, not a hold: the leader never opens, even once the dwell
        //    would have elapsed, and the key reaches the responder.
        try expect(window.makeFirstResponder(canvas), "the canvas must take first responder")
        _ = app.focusBroker.requestFocus(.canvas, reason: .userClick)
        try flags(.option)
        try key("z", keyCode: 6, mods: .option)
        spin(pastDwell)
        try expect(!leaderOpen, "⌥ then a key before the dwell must not open the leader")
        try flags([])
        spin(0.05)

        // 5. The feature itself: ⌥ held alone past the dwell opens the leader;
        //    a key it does not own passes through and closes it.
        try flags(.option)
        spin(pastDwell)
        try expect(leaderOpen, "⌥ held alone past the dwell must still open the leader")
        let passed = !app.handleHotkey(try {
            guard let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{3A9}",
                charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)
            else { throw Failure(description: "composer key routing: could not make keyDown") }
            return e
        }())
        try expect(passed, "a key the leader does not own must pass through to content")
        try expect(!leaderOpen, "a key the leader does not own must close it")
        try flags([])

        return "⌥↩ queues from a real key event with the leader's monitor installed; ⌥→ moves a word and ⌥3 types # in the composer; a quick ⌥-chord never opens the leader; a held ⌥ still does, and passes through keys it does not own"
    }
}
