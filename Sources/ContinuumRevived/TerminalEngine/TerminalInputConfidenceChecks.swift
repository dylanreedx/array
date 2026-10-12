import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

/// Confidence-pass witnesses for the terminal tile's input seams: clipboard
/// (`--terminal-clipboard-check`), focus on install (`--terminal-focus-grab-check`)
/// and ⌘W (`--terminal-cmd-w-check`). Each drives a real Ghostty surface hosted by
/// the production `TerminalTileNSView` in an off-screen fixture window, and none
/// touches the user's real pasteboard: the clipboard is a pair of private named
/// pasteboards injected through `TerminalClipboard`.
@MainActor
enum TerminalInputConfidenceChecks {
    struct CheckError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError(message: message) }
    }

    /// One real terminal tile in a canvas in an off-screen window.
    @MainActor
    private final class Fixture {
        let context: GhosttyRuntimeContext
        let canvas: CanvasNSView
        let window: NSWindow
        let tile: Tile
        let runtime: GhosttyTerminalRuntime
        private(set) var tileView: TerminalTileNSView?
        private var tornDown = false

        init(command: String, arguments: [String], clipboard: TerminalClipboard, install: Bool = true) throws {
            context = try GhosttyRuntimeContext()
            tile = Tile(
                id: UUID(),
                kind: .terminal,
                title: "INPUT_PROBE",
                frame: TileFrame(x: 0, y: 0, width: 760, height: 420),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata()
            )
            canvas = CanvasNSView(canvasState: CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [],
                groups: [],
                lastActiveTileId: nil
            ))
            canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            runtime = GhosttyTerminalRuntime(
                tileId: tile.id,
                title: "input-probe",
                launchProfile: LaunchProfile(
                    command: command,
                    arguments: arguments,
                    cwd: FileManager.default.temporaryDirectory.path,
                    title: "input-probe"
                ),
                ghostty: context,
                clipboard: clipboard
            )
            if install { installTile() }
        }

        func installTile() {
            let view = TerminalTileNSView(tile: tile, runtime: runtime)
            canvas.install(tileView: view, for: tile)
            view.layoutSubtreeIfNeeded()
            tileView = view
        }

        var terminalView: GhosttyTerminalView? { runtime.qaTerminalView }

        func pump(_ seconds: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        @discardableResult
        func pump(until timeout: TimeInterval, _ condition: () -> Bool) throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        /// The surface must be gone before `ghostty_app_free`, or it traps.
        func tearDown() {
            guard !tornDown else { return }
            tornDown = true
            runtime.terminate(policy: .force)
            tileView?.hostView.detachRuntime()
            window.orderOut(nil)
            context.shutdown()
        }
    }

    private static func privateClipboard(
        confirm: @escaping TerminalClipboard.Confirm
    ) -> (TerminalClipboard, NSPasteboard, NSPasteboard) {
        let standard = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.qa.terminal-clipboard.\(UUID().uuidString)"))
        let selection = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.qa.terminal-selection.\(UUID().uuidString)"))
        return (TerminalClipboard(standard: standard, selection: selection, confirm: confirm), standard, selection)
    }

    private static func artifact(_ name: String, _ manifest: [String: Any]) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Clipboard

    static func runClipboardCheck() throws -> URL {
        // Scripted confirmation, answered on a later runloop turn like the real
        // sheet. `nextAnswer` is consumed per request.
        var nextAnswer = false
        var asked: [TerminalClipboard.Request] = []
        let (clipboard, standard, _) = privateClipboard { _, request, _, decide in
            asked.append(request)
            let answer = nextAnswer
            DispatchQueue.main.async { decide(answer) }
        }
        defer { standard.releaseGlobally() }

        var manifest: [String: Any] = ["check": "terminal-clipboard"]

        // 1. Paste: Edit > Paste on the focused terminal delivers the pasteboard
        //    text to the program (cat echoes it through the tty).
        do {
            let fixture = try Fixture(command: "/bin/cat", arguments: [], clipboard: clipboard)
            defer { fixture.tearDown() }
            try fixture.pump(0.6)
            guard let view = fixture.terminalView, view.surface != nil else {
                throw CheckError(message: "paste: terminal surface missing")
            }
            fixture.window.makeFirstResponder(view)
            standard.clearContents()
            standard.setString("PASTE_MARKER_K7", forType: .string)
            let handled = view.tryToPerform(#selector(NSText.paste(_:)), with: nil)
            try expect(handled, "paste: Edit > Paste found no responder on the focused terminal (the menu item is disabled there)")
            let landed = try fixture.pump(until: 3) { view.visibleText().contains("PASTE_MARKER_K7") }
            manifest["pasteLanded"] = landed
            try expect(landed, "paste: pasteboard text never reached the terminal; visible=\(view.visibleText().prefix(200))")
            try expect(asked.isEmpty, "paste: a plain one-line paste must not ask for confirmation, asked \(asked)")

            // 2. Unsafe paste (a newline into a program without bracketed paste):
            //    Ghostty asks; a refusal sends nothing, an approval sends it.
            standard.clearContents()
            standard.setString("UNSAFE_DENIED_Q1\nsecond", forType: .string)
            nextAnswer = false
            _ = view.tryToPerform(#selector(NSText.paste(_:)), with: nil)
            try fixture.pump(0.5)
            try expect(asked == [.paste], "unsafe paste: Ghostty's paste protection must route through the confirmation, asked \(asked)")
            try expect(!view.visibleText().contains("UNSAFE_DENIED_Q1"), "unsafe paste: a refused paste must not reach the program")

            standard.clearContents()
            standard.setString("UNSAFE_ALLOWED_Q2\nsecond", forType: .string)
            nextAnswer = true
            _ = view.tryToPerform(#selector(NSText.paste(_:)), with: nil)
            let allowedLanded = try fixture.pump(until: 3) { view.visibleText().contains("UNSAFE_ALLOWED_Q2") }
            try expect(asked == [.paste, .paste], "unsafe paste: second paste must ask again, asked \(asked)")
            try expect(allowedLanded, "unsafe paste: an approved paste must reach the program")
            manifest["unsafePasteConfirmations"] = asked.count
        }

        // 3. Copy: select the screen, Edit > Copy, and the pasteboard holds it.
        do {
            let fixture = try Fixture(
                command: "/bin/sh",
                arguments: ["-c", "printf 'COPY_MARKER_Z3\\n'; exec /bin/cat"],
                clipboard: clipboard
            )
            defer { fixture.tearDown() }
            guard let view = fixture.terminalView else { throw CheckError(message: "copy: terminal view missing") }
            let printed = try fixture.pump(until: 3) { view.visibleText().contains("COPY_MARKER_Z3") }
            try expect(printed, "copy: fixture output never appeared")
            fixture.window.makeFirstResponder(view)
            standard.clearContents()
            try expect(view.performGhosttyBinding("select_all"), "copy: select_all binding failed")
            let handled = view.tryToPerform(#selector(NSText.copy(_:)), with: nil)
            try expect(handled, "copy: Edit > Copy found no responder on the focused terminal")
            _ = try fixture.pump(until: 2) { standard.string(forType: .string) != nil }
            let copied = standard.string(forType: .string) ?? ""
            manifest["copiedContainsMarker"] = copied.contains("COPY_MARKER_Z3")
            try expect(copied.contains("COPY_MARKER_Z3"), "copy: the pasteboard does not hold the selection, got \(copied.prefix(200))")
        }

        // 4. OSC 52 read: a program asking for the clipboard goes through the
        //    confirmation, and a refusal leaks nothing.
        do {
            asked.removeAll()
            nextAnswer = false
            let secret = "OSC52_SECRET_V9"
            standard.clearContents()
            standard.setString(secret, forType: .string)
            let fixture = try Fixture(
                command: "/bin/sh",
                arguments: ["-c", "sleep 0.4; printf '\\033]52;c;?\\007'; exec /bin/cat"],
                clipboard: clipboard
            )
            defer { fixture.tearDown() }
            guard let view = fixture.terminalView else { throw CheckError(message: "osc52: terminal view missing") }
            let requested = try fixture.pump(until: 3) { !asked.isEmpty }
            try fixture.pump(0.4)
            let encoded = Data(secret.utf8).base64EncodedString()
            manifest["osc52ReadConfirmations"] = asked.map { "\($0)" }
            try expect(requested && asked.contains(.osc52Read), "osc52: a program's clipboard read must ask first, asked \(asked)")
            try expect(!view.visibleText().contains(encoded), "osc52: a refused read must not hand the clipboard to the program")
        }

        return try artifact("terminal-clipboard", manifest)
    }

    // MARK: - Focus grab

    static func runFocusGrabCheck() throws -> URL {
        let (clipboard, standard, _) = privateClipboard { _, _, _, decide in decide(false) }
        defer { standard.releaseGlobally() }
        let fixture = try Fixture(command: "/bin/cat", arguments: [], clipboard: clipboard, install: false)
        defer { fixture.tearDown() }

        // The user is typing somewhere else (a composer stands in).
        let composer = NSTextView(frame: NSRect(x: 0, y: 600, width: 300, height: 40))
        fixture.canvas.addSubview(composer)
        try expect(fixture.window.makeFirstResponder(composer), "fixture: composer could not take first responder")

        // Hydration / zone install / workspace switch: a terminal enters the window.
        fixture.installTile()
        try fixture.pump(0.4)
        guard let terminal = fixture.terminalView, terminal.surface != nil else {
            throw CheckError(message: "focus: terminal surface missing")
        }
        let afterInstall = fixture.window.firstResponder
        try expect(afterInstall === composer,
                   "focus: installing a terminal stole first responder from the composer (now \(String(describing: afterInstall)))")

        // A deliberate focus (the broker's acquireFocus for a click/open) DOES move it.
        guard let tileView = fixture.tileView else { throw CheckError(message: "focus: tile view missing") }
        _ = tileView.acquireFocus(reason: .userClick)
        try expect(fixture.window.firstResponder === terminal, "focus: acquireFocus must make the terminal first responder")

        // And a click on the terminal itself takes it back from the composer.
        fixture.window.makeFirstResponder(composer)
        let point = terminal.convert(NSPoint(x: 20, y: 20), to: nil)
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: fixture.window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1) {
            terminal.mouseDown(with: down)
        }
        try expect(fixture.window.firstResponder === terminal, "focus: clicking the terminal must make it first responder")

        return try artifact("terminal-focus-grab", ["check": "terminal-focus-grab", "composerKeptFocusOnInstall": true])
    }

    // MARK: - ⌘W

    static func runCmdWCheck() throws -> URL {
        let (clipboard, standard, _) = privateClipboard { _, _, _, decide in decide(false) }
        defer { standard.releaseGlobally() }
        let fixture = try Fixture(command: "/bin/cat", arguments: [], clipboard: clipboard)
        defer { fixture.tearDown() }
        try fixture.pump(0.6)
        guard let view = fixture.terminalView, let surface = view.surface else {
            throw CheckError(message: "cmd-w: terminal surface missing")
        }
        fixture.window.makeFirstResponder(view)

        // Evidence about THIS Ghostty build: is ⌘W one of its bindings?
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 13
        key.mods = GHOSTTY_MODS_SUPER
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = UInt32(("w" as UnicodeScalar).value)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = "w".withCString { pointer -> Bool in
            key.text = pointer
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        print("terminal-cmd-w-check: ghostty binds cmd+w = \(isBinding)")

        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ) else { throw CheckError(message: "cmd-w: could not synthesize ⌘W") }
        view.keyDown(with: event)
        try fixture.pump(0.8)

        let statusAfter = fixture.runtime.status
        try expect(view.surface != nil && statusAfter == .running,
                   "cmd-w: ⌘W in a terminal closed the surface and killed the shell outside the tile's close path (status \(statusAfter))")

        // The shell is genuinely alive: input still echoes.
        view.sendText("ALIVE_AFTER_CMD_W")
        let alive = try fixture.pump(until: 3) { view.visibleText().contains("ALIVE_AFTER_CMD_W") }
        try expect(alive, "cmd-w: the terminal stopped echoing input after ⌘W")

        // The tile's own close path (requestClose) must still close it.
        fixture.runtime.terminate(policy: .requestClose)
        let closed = try fixture.pump(until: 3) { fixture.runtime.status != .running }
        try expect(closed, "cmd-w: the normal requestClose path no longer closes the terminal (status \(fixture.runtime.status))")

        return try artifact("terminal-cmd-w", [
            "check": "terminal-cmd-w",
            "ghosttyBindsCmdW": isBinding,
            "statusAfterCmdW": "\(statusAfter)",
        ])
    }
}
