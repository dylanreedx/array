import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// DI-01 — composer dictation, end to end through the real agent tile.
//
// The engine is the deterministic `FakeDictationEngine` (no microphone, no
// Speech); everything else is production: the tile's footer mic button, the
// composer, its draft store on disk, and every key through `NSApp.sendEvent`
// with the production hotkey monitor installed, so a shortcut the monitor or
// the window swallowed would fail here rather than only in the app.
//
// What it holds the composer to:
//  * a hypothesis is visible but never reaches the draft store, and never sends;
//  * ↩ finishes instead of sending, and the draft is written exactly once;
//  * Esc removes only what dictation inserted since the user last typed;
//  * focus loss keeps the words; unbind and tile close keep nothing;
//  * undo with a hypothesis on screen restores the pre-session text exactly;
//  * the mic button never takes the keyboard from the editor;
//  * a failure says what to fix; Settings off hides the button and the chord.
extension AppDelegate {
    @MainActor
    static func runComposerDictationSelfCheck() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw Failure(description: "composer dictation: " + message) }
        }
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

        let suiteName = "continuum.qa.composerDictation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Failure(description: "no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var engines: [FakeDictationEngine] = []
        var nextPrepare: FakeDictationEngine.PrepareOutcome = .succeeds
        var finishesOnStop = true
        ComposerDictationController.defaults = defaults
        ComposerDictationController.qaEngineFactory = {
            let engine = FakeDictationEngine()
            engine.prepareOutcome = nextPrepare
            engine.emitsFinishedOnStop = finishesOnStop
            engines.append(engine)
            return engine
        }
        defer {
            ComposerDictationController.qaEngineFactory = nil
            ComposerDictationController.defaults = .standard
        }
        var engine: FakeDictationEngine {
            get throws {
                guard let last = engines.last else { throw Failure(description: "composer dictation: no engine was built") }
                return last
            }
        }

        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-dictation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = AgentComposerDraftStore(applicationSupportDirectory: storeRoot, debounceInterval: 0)

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-0000000D1C01")!
        let tile = Tile(
            id: tileId, kind: .managedAgent, title: "DICTATE",
            frame: TileFrame(x: 40, y: 40, width: 440, height: 360),
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
        defer { window.orderOut(nil) }
        let app = AppDelegate()
        app.canvasView = canvas
        canvas.focusBroker = app.focusBroker
        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        guard let composer = tileView.qaComposerForChecks else { throw Failure(description: "composer dictation: no composer") }
        let button = tileView.qaDictationButtonForChecks
        canvas.layoutSubtreeIfNeeded()
        tileView.layoutSubtreeIfNeeded()
        app.qaAttachWindowInstallingHotkeyMonitor(window)

        let agentID = AgentID(rawValue: UUID())
        func spin(_ seconds: TimeInterval = 0.05) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func key(_ characters: String, keyCode: UInt16, mods: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "composer dictation: could not make keyDown") }
            NSApp.sendEvent(event)
        }
        func chord() throws { try key("d", keyCode: 2, mods: [.command, .shift]) }
        /// The real hit test from the window's frame view, then the press to
        /// whatever it found. Window/app delivery would spend the click on
        /// activating an app a check must never bring forward.
        func click(_ view: NSView) throws {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            guard let hit = window.contentView?.superview?.hitTest(point) else {
                throw Failure(description: "composer dictation: nothing under the click")
            }
            try expect(hit === view, "a click on \(type(of: view)) must reach it, not \(type(of: hit))")
            guard let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw Failure(description: "composer dictation: could not make a click") }
            hit.mouseDown(with: event)
        }
        func storedText() -> String? {
            var result: String??
            Task { result = .some(await store.load(for: agentID)?.text) }
            let until = Date().addingTimeInterval(2)
            while result == nil, Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return result ?? nil
        }
        var text: String { composer.textView.string }
        let pill = tileView.qaDictationPillForChecks
        /// Steps the pill's spring at 60 Hz until it rests, as its display link
        /// would; returns the widest frame it reached and how many steps it took.
        func settlePill() -> (peak: CGFloat, steps: Int) {
            var peak = pill.isHidden ? 0 : pill.frame.width
            var steps = 0
            while pill.qaIsAnimating, steps < 240 {
                pill.advanceMotion(by: 1.0 / 60.0)
                peak = max(peak, pill.frame.width)
                steps += 1
            }
            return (peak, steps)
        }

        composer.bindDraftStore(store, agentID: agentID)
        let sink = RecordingSink()
        composer.bindActionSink(sink, agentID: agentID, snapshot: AgentTileTurnSnapshot(
            state: .ready,
            capabilities: AgentTurnCapabilities(canSend: true, canStop: false, canSteer: false, canQueue: false),
            turnStartedAt: nil))
        spin(0.2)
        var publishes = 0
        let tilePublish = composer.onDraftChange
        composer.onDraftChange = { draft in
            publishes += 1
            tilePublish?(draft)
        }
        _ = app.focusBroker.requestFocus(.tile(tileId), reason: .userClick)
        try expect(window.firstResponder === composer.textView, "selecting the tile must focus its composer")
        try expect(!button.isHidden, "the mic button must show when dictation is offered")
        try expect(button.superview?.identifier?.rawValue == "agentTile.providerControls",
                   "the mic button must sit in the footer beside Send")
        composer.apply(.init(text: "fix the", selection: NSRange(location: 7, length: 0), revision: 1))
        spin()
        let baseline = publishes

        // 1. ⇧⌘D starts a session at the caret, through the real key path.
        try chord()
        spin()
        try expect(composer.dictationState == .listening, "⇧⌘D must start listening, got \(composer.dictationState)")
        try expect(button.dictationState == .listening, "the mic button must mirror the live session")
        try expect(!pill.isHidden && pill.isExpanded && pill.mode == .listening,
                   "the mic must grow into the pill while listening")
        try expect(composer.qaKeyHint == AgentComposerView.dictationKeyHint,
                   "the hint row must say how to finish and discard, got \(String(describing: composer.qaKeyHint))")
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let grown = settlePill()
        try expect(abs(pill.frame.maxX - button.frame.maxX) < 0.5 && abs(pill.frame.height - button.frame.height) < 0.5,
                   "the pill must grow out of the mic: its stop button sits where the mic was (pill \(pill.frame), mic \(button.frame))")
        try expect(pill.frame.width > button.frame.width * 4 && pill.expansion == 1,
                   "the pill must grow over the provider controls, got \(pill.frame.width)pt at expansion \(pill.expansion)")
        if !reducedMotion {
            try expect(grown.peak > pill.frame.width + 0.5 && grown.steps < 60,
                       "the pill must land with a little jelly and settle within a second (peak \(grown.peak) vs \(pill.frame.width), \(grown.steps) steps)")
        }
        try expect(tileView.qaProviderFooterAlpha == 0, "the provider controls must fade out under the grown pill")
        try expect(pill.qaTimeText == "0:00", "the pill must show elapsed time, got \(pill.qaTimeText)")
        let timerDeadline = Date().addingTimeInterval(3)
        while pill.qaTimeText == "0:00", Date() < timerDeadline { spin() }
        try expect(!pill.qaIsAnimating && pill.qaTimeText != "0:00",
                   "elapsed time must advance after the opening spring settles, including with reduced motion; got \(pill.qaTimeText)")
        try expect(pill.qaTimeUpdatesRunning, "the session clock must keep running after the spring settles")
        let strip = pill.waveform
        try expect(strip.mode == .listening, "the waveform must say it is listening")
        if !reducedMotion {
            try expect(strip.qaDisplayLinkRunning, "the waveform must animate while listening")
        }

        // 2. A hypothesis is on screen, in the secondary colour, and nowhere else.
        try engine.emitVolatile("login bug")
        try expect(text == "fix the login bug", "a hypothesis must show at the caret with a space, got \(text.debugDescription)")
        try expect(composer.qaDictationProvisionalRange == NSRange(location: 7, length: 10),
                   "the hypothesis range must be the inserted words and their space, got \(String(describing: composer.qaDictationProvisionalRange))")
        let shown = composer.textView.layoutManager?.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 10, effectiveRange: nil) as? NSColor
        try expect(shown == TextToken.textSecondary.color.nsColor(for: composer.textView.effectiveTokenTheme),
                   "a hypothesis must draw in the secondary text colour")
        try expect(composer.textView.textStorage?.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor
                   != TextToken.textSecondary.color.nsColor(for: composer.textView.effectiveTokenTheme),
                   "the hypothesis colour must be a temporary attribute, never stored text")
        try expect(publishes == baseline, "a hypothesis must never publish the draft (\(publishes - baseline) publishes)")

        // 3. Levels feed the envelope without redrawing; scrolling redraws once.
        let redraws = strip.qaRedrawCount
        for _ in 0..<12 { try engine.emitLevel(0.7) }
        try expect(strip.meter.envelope > 0.1, "levels must reach the meter, envelope \(strip.meter.envelope)")
        try expect(strip.qaRedrawCount == redraws, "a level event must never redraw")
        strip.tick(elapsed: 0.25)
        try expect(strip.qaRedrawCount == redraws + 1, "one tick that scrolls five bars must redraw once")

        // 4. A settled phrase replaces the hypothesis; still nothing persisted.
        try engine.emitFinal("login bug.")
        try expect(text == "fix the login bug.", "the settled phrase must replace the hypothesis, got \(text.debugDescription)")
        try expect(composer.qaDictationProvisionalRange == nil, "no hypothesis after a settled phrase")
        try expect(publishes == baseline, "a settled phrase must not publish before the session ends")
        try expect(storedText() != "fix the login bug.", "the draft store must not see dictation mid-session")

        // 5. ↩ finishes — it never sends — and the draft is written once.
        let sends = composer.qaSendRequestCount
        try key("\r", keyCode: 36)
        spin()
        try expect(try engine.stopCallCount == 1, "↩ must finish the session")
        try expect(composer.dictationState == .idle, "the session must end, got \(composer.dictationState)")
        try expect(composer.qaSendRequestCount == sends && sink.intents.isEmpty, "↩ while dictating must not send")
        try expect(publishes == baseline + 1, "the end of a session must publish exactly once, got \(publishes - baseline)")
        try expect(storedText() == "fix the login bug.", "the finished words must be in the draft store")
        _ = settlePill()
        try expect(pill.isHidden && !pill.isExpanded, "the pill must fold back into the mic when the session ends")
        try expect(tileView.qaProviderFooterAlpha == 1, "the provider controls must come back when the pill folds")
        try expect(!strip.qaDisplayLinkRunning, "the waveform must stop animating when hidden")
        try expect(!pill.qaTimeUpdatesRunning && pill.qaTimeText == "0:00",
                   "the session clock must stop and reset when the pill folds")
        try expect(composer.qaKeyHint == nil, "the dictation hint must leave with the session")
        let afterFinish = publishes

        // 6. Esc takes back exactly this session's words.
        try chord()
        spin()
        try expect(pill.qaTimeUpdatesRunning && pill.qaTimeText == "0:00",
                   "a new session must restart the clock at zero")
        // Results arrive asynchronously in the app, each in its own run-loop
        // pass, so each settled phrase is its own undo step. Deliver them so.
        try engine.emitFinal("delete everything")
        spin()
        try engine.emitVolatile("and more")
        spin()
        try expect(text == "fix the login bug. delete everything and more", "got \(text.debugDescription)")
        try key("\u{1b}", keyCode: 53)
        spin()
        try expect(text == "fix the login bug.", "Esc must remove the session's words only, got \(text.debugDescription)")
        try expect(composer.dictationState == .idle, "Esc must end the session")
        try expect(try !engine.isCapturing, "Esc must release the microphone")
        try expect(publishes == afterFinish + 1, "a discarded session publishes once, to the text it restored")
        try expect(storedText() == "fix the login bug.", "the store must hold the pre-session text after Esc")
        composer.textView.undoManager?.undo()
        try expect(text == "fix the login bug. delete everything", "⌘Z must bring back a discarded phrase, got \(text.debugDescription)")
        composer.textView.undoManager?.undo()
        try expect(text == "fix the login bug.", "a second ⌘Z must undo the phrase itself, got \(text.debugDescription)")

        // 7. Typing mid-session makes the words on screen the user's.
        try chord()
        spin()
        try engine.emitVolatile("hello")
        try key("x", keyCode: 7)
        try expect(text == "fix the login bug. hellox", "typing must land after the hypothesis, got \(text.debugDescription)")
        try expect(composer.qaDictationProvisionalRange == nil, "typing must adopt the hypothesis")
        try engine.emitVolatile("world")
        try expect(text == "fix the login bug. hellox world", "dictation must continue at the caret, got \(text.debugDescription)")
        try key("\u{1b}", keyCode: 53)
        spin()
        try expect(text == "fix the login bug. hellox", "Esc must keep what the user adopted, got \(text.debugDescription)")

        // 8. Undo with a hypothesis on screen takes the hypothesis out first.
        try chord()
        spin()
        try engine.emitFinal("one")
        spin()
        try engine.emitVolatile("two")
        spin()
        composer.textView.undoManager?.undo()
        try expect(text == "fix the login bug. hellox", "undo must leave exactly the pre-phrase text, got \(text.debugDescription)")
        try key("\u{1b}", keyCode: 53)
        spin()
        try expect(text == "fix the login bug. hellox", "got \(text.debugDescription)")

        // 9. Leaving the editor keeps the words the engine settles while finishing.
        finishesOnStop = false
        try chord()
        spin()
        try engine.emitVolatile("keep me")
        window.makeFirstResponder(nil)
        try expect(try engine.stopCallCount == 1, "focus loss must finish, not cancel")
        try expect(composer.dictationState == .finalizing, "got \(composer.dictationState)")
        try engine.emitFinal("keep me")
        try engine.emit(.finished)
        try expect(text == "fix the login bug. hellox keep me", "focus loss must keep the words, got \(text.debugDescription)")
        try expect(storedText() == text, "the kept words must persist")
        finishesOnStop = true
        window.makeFirstResponder(composer.textView)
        _ = settlePill()

        // 10. The mic button starts a session without taking the keyboard, and
        //     Send while live finishes instead of sending.
        try click(button)
        spin()
        try expect(composer.dictationState == .listening, "clicking the mic must start, got \(composer.dictationState)")
        try expect(window.firstResponder === composer.textView, "the mic button must leave the editor focused")
        try engine.emitVolatile("ship it")
        composer.composerRequestedSend(composer.textView)
        spin()
        try expect(composer.dictationState == .idle && sink.intents.isEmpty, "Send while live must finish, never send")
        _ = settlePill()

        //     A click on the live pill finishes too, keeping the words.
        try chord()
        spin()
        _ = settlePill()
        try engine.emitFinal("tap to stop")
        spin()
        let beforePillClick = text
        try click(pill)
        spin()
        try expect(composer.dictationState == .idle, "clicking the pill must finish, got \(composer.dictationState)")
        try expect(text == beforePillClick && sink.intents.isEmpty, "the pill must keep the words and never send")
        try expect(window.firstResponder === composer.textView, "the pill must leave the editor focused")
        _ = settlePill()

        // 11. Unbinding keeps nothing a hypothesis showed.
        let beforeUnbind = text
        try chord()
        spin()
        try engine.emitVolatile("ghost")
        composer.unbindActionSink()
        try expect(try engine.cancelCallCount == 1, "unbind must cancel the session")
        try expect(text == beforeUnbind, "unbind must withdraw the hypothesis, got \(text.debugDescription)")
        composer.bindActionSink(sink, agentID: agentID, snapshot: AgentTileTurnSnapshot(
            state: .ready,
            capabilities: AgentTurnCapabilities(canSend: true, canStop: false, canSteer: false, canQueue: false),
            turnStartedAt: nil))

        // 12. A failure names the fix, on the button and in the hint row.
        nextPrepare = .fails(.microphonePermissionDenied)
        try chord()
        spin()
        try expect(composer.dictationState == .error(.microphonePermissionDenied), "got \(composer.dictationState)")
        try expect(button.toolTip == DictationFailure.microphonePermissionDenied.composerMessage, "the button must say what to fix")
        try expect(composer.qaKeyHint == DictationFailure.microphonePermissionDenied.composerMessage, "the hint row must say what to fix")
        nextPrepare = .succeeds

        // 13. Settings off: no button, and the chord is the text system's again.
        defaults.set(false, forKey: DictationConfig.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        spin()
        try expect(button.isHidden, "turning dictation off must hide the mic button")
        let built = engines.count
        try chord()
        spin()
        try expect(engines.count == built && composer.dictationState != .listening, "⇧⌘D must do nothing when dictation is off")
        defaults.set(true, forKey: DictationConfig.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        spin()
        try expect(!button.isHidden, "turning dictation back on must show the mic button")

        // 14. At the 320 pt tile floor the mic yields to the provider controls,
        //     and the chord still dictates.
        let wide = tileView.frame
        tileView.frame.size.width = 320
        tileView.layoutSubtreeIfNeeded()
        tileView.layoutSubtreeIfNeeded()
        try expect(button.isHidden, "at the 320 pt floor the mic must yield to the provider controls")
        try chord()
        spin()
        try expect(composer.dictationState == .listening, "⇧⌘D must still dictate when the mic has yielded")
        _ = settlePill()
        let sendFrame = tileView.qaPageZoomActionButton?.frame ?? .zero
        try expect(!pill.isHidden && pill.expansion == 1 && pill.frame.width > pill.frame.height * 4
                       && pill.frame.maxX <= sendFrame.minX && sendFrame.minX - pill.frame.maxX < 16,
                   "with the mic hidden the pill must still grow, ending just before Send (pill \(pill.frame), send \(sendFrame))")
        try key("\u{1b}", keyCode: 53)
        spin()
        tileView.frame = wide
        tileView.layoutSubtreeIfNeeded()
        tileView.layoutSubtreeIfNeeded()
        try expect(!button.isHidden, "the mic must come back when the tile is wide enough")

        // 15. Closing the tile mid-session keeps nothing and frees the mic.
        try chord()
        spin()
        try engine.emitVolatile("closing")
        tileView.prepareForRemovalFromScene()
        try expect(try !engine.isCapturing, "a closing tile must release the microphone")
        try expect(!text.contains("closing"), "a closing tile must not keep a hypothesis")

        return "15 scenarios, \(engines.count) sessions, draft writes \(publishes - baseline)"
    }
}
