import AppKit
import ContinuumRevivedCore
import Foundation

/// `--agent-tile-file-mention-check`: typing `@` in a managed agent tile's
/// composer lists the agent's checkout files, and picking one attaches it.
///
/// Driven through production only: a real `AppDelegate` and supervisor, a real
/// `CanvasNSView` in a real window, a real `ManagedAgentTileNSView` wired by
/// `wireManagedAgentTile`, the tile's own default completion registry over the
/// real `AgentFileIndex`, and keystrokes delivered to the composer's text view
/// as AppKit delivers them. `--agent-completion-semantic-check` covers the
/// popover's contract over a probe source on a bare composer; this covers the
/// tile that ships, which that check never builds.
@MainActor
enum AgentTileFileMentionChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static func run() async throws -> String {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("array-file-mention-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("project", isDirectory: true)
        let sources = projectRoot.appendingPathComponent("Sources", isDirectory: true)
        for dir in [appSupport, agentsSupport, sources] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: temporary) }
        try "# Fixture\n".write(to: projectRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: sources.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)

        let tileId = UUID()
        let tile = Tile(
            id: tileId, kind: .managedAgent, title: "mention agent",
            frame: TileFrame(x: 40, y: 40, width: 520, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [],
            lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        canvas.layoutSubtreeIfNeeded()

        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: agentsSupport),
            makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
        let supervisor = delegate.agentSupervisor
        let agentId = supervisor.spawn(
            role: nil, prompt: nil, cwd: projectRoot, harness: .claudeCode,
            model: "fixture/file-mention", thinking: "medium", tileId: tileId,
            displayName: "Mention witness")
        delegate.wireManagedAgentTile(tileId, agentID: agentId)
        canvas.layoutSubtreeIfNeeded()

        guard let composer = tileView.qaComposerForChecks else {
            throw Failure(description: "the tile has no composer")
        }
        try expect(tileView.qaCompletionContext?.checkoutRoot.standardizedFileURL.path
                       == projectRoot.standardizedFileURL.path,
                   "the composer is bound to the agent's checkout, got \(tileView.qaCompletionContext?.checkoutRoot.path ?? "nil")")

        let textView = composer.textView
        window.makeKey()
        try expect(window.makeFirstResponder(textView), "the composer's editor takes the keyboard")
        try expect(composer.qaPreparedCompletionContext == tileView.qaCompletionContext,
                   "taking the keyboard warms the agent's file index before the first @, got \(String(describing: composer.qaPreparedCompletionContext?.checkoutRoot.path))")

        func key(_ characters: String, keyCode: UInt16) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ) else { throw Failure(description: "could not make a key event") }
            return event
        }

        // Type `@` the way a keyboard does: a key-down through the window.
        window.sendEvent(try key("@", keyCode: 19))
        try expect(textView.string == "@", "the @ key reached the editor, got \"\(textView.string)\"")
        let presented = await waitUntil(timeout: 5, pollInterval: 0.02) {
            composer.qaCompletionIsPresented
                && Set(composer.qaCompletionTitles).isSuperset(of: ["README.md", "Sources/"])
        }
        try expect(presented,
                   "typing @ lists the checkout: presented=\(composer.qaCompletionIsPresented), titles=\(composer.qaCompletionTitles), requests=\(composer.qaCompletionRequestStartCount)")

        // A working agent streams events while the menu is open, and the tile
        // rebinds the composer's completion context on every one. None of them
        // may close the menu or restart its query: they did, so on a slow index
        // the menu never stayed up long enough to show while an agent worked.
        // AppKit closes a passive menu when the app or its window loses
        // activation, on purpose and outside this check's control: a fixture
        // launched from a shell can be activated at launch and lose it to the
        // next click. A pass that saw that happen is run again, and says so; a
        // close without it is the defect.
        final class ActivationWatch { var lost = false }
        let watch = ActivationWatch()
        let activationObservers = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in watch.lost = true }
        }
        defer { activationObservers.forEach(NotificationCenter.default.removeObserver) }
        for attempt in 1...3 {
            watch.lost = false
            if !composer.qaCompletionIsPresented {
                textView.string = ""
                window.makeKey()
                window.makeFirstResponder(textView)
                window.sendEvent(try key("@", keyCode: 19))
            }
            // Let the menu settle first: the editor's first layout can move the
            // caret once, which legitimately re-anchors the panel.
            var settledCount = -1
            _ = await waitUntil(timeout: 2, pollInterval: 0.15) {
                defer { settledCount = composer.qaCompletionRequestStartCount }
                return settledCount == composer.qaCompletionRequestStartCount && composer.qaCompletionIsPresented
            }
            let openTitles = composer.qaCompletionTitles
            let requestsWhileOpen = composer.qaCompletionRequestStartCount
            let ingestedBefore = tileView.ingestedEvents.count
            let turn = "mention-turn-\(attempt)"
            supervisor.qaDeliver(.turnStarted(threadId: "thread-main", turnId: turn), to: agentId)
            for word in 0..<8 {
                supervisor.qaDeliver(.contentDelta(
                    threadId: "thread-main", turnId: turn, streamKind: .assistant, delta: "word \(word) "
                ), to: agentId)
            }
            let ingested = await waitUntil(timeout: 5, pollInterval: 0.02) {
                tileView.ingestedEvents.count >= ingestedBefore + 9
            }
            try expect(ingested,
                       "POSITIVE CONTROL: the tile ingested the streamed events, \(tileView.ingestedEvents.count - ingestedBefore) of 9")
            _ = await waitUntil(timeout: 0.3, pollInterval: 0.02) { false }
            if watch.lost, attempt < 3 {
                print("note: the fixture lost activation during the event pass (attempt \(attempt)); running it again")
                continue
            }
            try expect(composer.qaCompletionIsPresented && composer.qaCompletionTitles == openTitles,
                       "streamed agent events left the @ menu open and unchanged: presented=\(composer.qaCompletionIsPresented), titles=\(composer.qaCompletionTitles), activationLost=\(watch.lost)")
            try expect(composer.qaCompletionRequestStartCount == requestsWhileOpen,
                       "streamed agent events restarted the @ query \(composer.qaCompletionRequestStartCount - requestsWhileOpen) times")
            break
        }

        // Narrow it, then accept with Return: the file becomes a reference chip
        // and the typed query leaves the draft.
        for (character, code) in [("r", UInt16(15)), ("e", UInt16(14)), ("a", UInt16(0))] {
            window.sendEvent(try key(character, keyCode: code))
        }
        let narrowed = await waitUntil(timeout: 5, pollInterval: 0.02) {
            composer.qaCompletionTitles.first == "README.md"
        }
        try expect(narrowed, "@rea narrows to README.md, got \(composer.qaCompletionTitles), text=\"\(textView.string)\"")
        window.sendEvent(try key("\r", keyCode: 36))
        try expect(composer.qaFileReferences.map(\.displayName) == ["README.md"],
                   "Return attaches README.md, got \(composer.qaFileReferences.map(\.displayName))")
        try expect(textView.string.isEmpty, "the accepted query leaves the draft, got \"\(textView.string)\"")
        try expect(!composer.qaCompletionIsPresented, "the menu closes after accepting")

        // Backspace. At the checkout root one press deletes a fresh `@`: it used
        // to climb one parent folder per press, all the way to `/`, first.
        let backspace = try key("\u{8}", keyCode: 51)
        window.sendEvent(try key("@", keyCode: 19))
        let reopened = await waitUntil(timeout: 5, pollInterval: 0.02) {
            composer.qaCompletionTitles.contains("Sources/")
        }
        try expect(reopened, "@ reopens the root list, got \(composer.qaCompletionTitles)")
        window.sendEvent(backspace)
        _ = await waitUntil(timeout: 0.3, pollInterval: 0.02) { false }
        try expect(textView.string.isEmpty && !composer.qaCompletionIsPresented,
                   "one Backspace deletes a fresh @: text=\"\(textView.string)\", presented=\(composer.qaCompletionIsPresented), breadcrumb=\(composer.qaCompletionBreadcrumb ?? "nil")")

        // Inside a folder opened from the list, Backspace climbs back out first,
        // then deletes.
        window.sendEvent(try key("@", keyCode: 19))
        _ = await waitUntil(timeout: 5, pollInterval: 0.02) { composer.qaCompletionTitles.contains("Sources/") }
        for _ in composer.qaCompletionTitles where composer.qaCompletionFocusedTitle != "Sources/" {
            window.sendEvent(try key("", keyCode: 125))
        }
        try expect(composer.qaCompletionFocusedTitle == "Sources/",
                   "↓ focuses Sources/, got \(composer.qaCompletionFocusedTitle ?? "nil")")
        window.sendEvent(try key("", keyCode: 124))
        let nested = await waitUntil(timeout: 5, pollInterval: 0.02) {
            composer.qaCompletionTitles.contains("Main.swift")
        }
        try expect(nested && textView.string == "@",
                   "→ opens Sources/ without touching the draft: titles=\(composer.qaCompletionTitles), text=\"\(textView.string)\"")
        window.sendEvent(backspace)
        let climbed = await waitUntil(timeout: 5, pollInterval: 0.02) {
            composer.qaCompletionTitles.contains("Sources/")
        }
        try expect(climbed && textView.string == "@",
                   "Backspace inside Sources/ climbs back to the root list: titles=\(composer.qaCompletionTitles), text=\"\(textView.string)\"")
        window.sendEvent(backspace)
        _ = await waitUntil(timeout: 0.3, pollInterval: 0.02) { false }
        try expect(textView.string.isEmpty && !composer.qaCompletionIsPresented,
                   "the next Backspace at the root deletes the @: text=\"\(textView.string)\"")
        return "@ listed the checkout, stayed open through 9 agent events, narrowed, attached README.md, and Backspace deleted a fresh @ in one press"
    }
}
