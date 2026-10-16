import AppKit
import ContinuumRevivedCore
import Foundation

/// `--reveal-in-finder-check`: a note or file tile can show its backing file in
/// Finder from its tile menu, from ⌘K, and with ⌥⌘R.
///
/// Mounted through `mountWorkspaceSceneAtBoot` (the invariants fixture), real key
/// monitors, real events. The canvas's `revealInFinder` is replaced by a
/// recorder, so Finder is never opened. Asserted:
///
///  - tile menu: present and enabled on a saved note and a saved file, and it
///    reveals exactly that file; present but disabled on a note whose body file
///    is gone and on a file tile whose document was never written; absent on a
///    terminal;
///  - ⌘K: "Reveal in Finder" is offered with the note focused and reveals its
///    file; it is not offered with the terminal focused;
///  - ⌥⌘R: reveals the focused file tile's document, and is conflict-free in
///    the product registry.
@MainActor
enum RevealInFinderChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private final class KeyableFixtureWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static let missingNote = UUID(uuidString: "00000000-0000-0000-0000-0000067A1F11")!
    static let unsavedFile = UUID(uuidString: "00000000-0000-0000-0000-0000067A1F12")!
    static let terminal = UUID(uuidString: "00000000-0000-0000-0000-0000067A1F13")!
    static let unsavedName = "never-written.md"

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
            throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT: mounting restores agents from the channel's store")
        }
        let fixture = try Fixture(label: "reveal-in-finder")
        defer { fixture.dispose() }
        let projectRoot = fixture.projectRoots[Fixture.projectA1]!
        try seed(fixture, projectRoot: projectRoot)
        try fixture.mount()
        let m = try fixture.requireMounted("reveal in finder")
        let window = KeyableFixtureWindow(
            contentRect: NSRect(origin: .zero, size: m.canvas.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = m.canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        m.delegate.qaAttachWindowInstallingHotkeyMonitor(window)
        m.canvas.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        let canvas = m.canvas
        let broker = m.delegate.qaFocusBroker

        var revealed: [URL] = []
        canvas.revealInFinder = { revealed.append($0) }
        var failures: [String] = []

        let layout = ProjectStoreLayout(projectRoot: projectRoot)
        let noteURL = layout.noteFile(id: Fixture.noteA1a)
        let fileURL = projectRoot.appendingPathComponent(Fixture.fileA1Name)
        // The note's body is removed after mount, as an external delete would.
        let missingNoteURL = layout.noteFile(id: missingNote)
        if FileManager.default.fileExists(atPath: missingNoteURL.path) {
            try FileManager.default.removeItem(at: missingNoteURL)
        }
        guard FileManager.default.fileExists(atPath: noteURL.path),
              FileManager.default.fileExists(atPath: fileURL.path),
              !FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(unsavedName).path) else {
            throw Failure(message: "setup: the saved note and file must exist and the unsaved document must not")
        }
        func same(_ a: URL?, _ b: URL) -> Bool {
            a?.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
        }

        // MARK: tile menu

        func revealItem(_ tileId: UUID) throws -> NSMenuItem? {
            guard let view = canvas.tileView(for: tileId) else { throw Failure(message: "setup: tile \(tileId) has no view") }
            let menu = view.titleBarContextMenuForQA()
            menu.update()
            return menu.items.first { $0.title == "Reveal in Finder" }
        }
        for (name, tileId, expected) in [("saved note", Fixture.noteA1a, noteURL), ("saved file", Fixture.fileA1, fileURL)] {
            guard let item = try revealItem(tileId) else {
                failures.append("menu: the \(name)'s tile menu has no Reveal in Finder"); continue
            }
            guard item.isEnabled, let action = item.action else {
                failures.append("menu: Reveal in Finder is disabled on the \(name)"); continue
            }
            revealed.removeAll()
            NSApp.sendAction(action, to: item.target, from: item)
            if revealed.count != 1 || !same(revealed.first, expected) {
                failures.append("menu: the \(name)'s Reveal in Finder revealed \(revealed.map(\.path)), want \(expected.path)")
            }
        }
        for (name, tileId) in [("note with no file", missingNote), ("never-written document", unsavedFile)] {
            guard let item = try revealItem(tileId) else {
                failures.append("menu: the \(name)'s tile menu must still list Reveal in Finder, disabled"); continue
            }
            if item.isEnabled || item.action != nil {
                failures.append("menu: Reveal in Finder must be disabled on the \(name)")
            }
        }
        if try revealItem(terminal) != nil {
            failures.append("menu: a terminal tile must not offer Reveal in Finder")
        }

        // MARK: ⌘K

        func key(_ characters: String, keyCode: UInt16, mods: NSEvent.ModifierFlags = [], ignoring: String? = nil) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                isARepeat: false, keyCode: keyCode)
            else { throw Failure(message: "could not synthesize \(characters)") }
            NSApp.sendEvent(event)
        }
        func focus(_ tileId: UUID) throws {
            guard let view = canvas.tileView(for: tileId) else { throw Failure(message: "setup: tile \(tileId) has no view") }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            AppDelegate.routeTileClickFocus(at: point, in: canvas, focusBroker: broker)
            guard broker.activeSurface == .tile(tileId) else {
                throw Failure(message: "setup: clicking tile \(tileId) left the broker on \(String(describing: broker.activeSurface))")
            }
        }
        func paletteOffersReveal(over tileId: UUID) throws -> Bool {
            try focus(tileId)
            try key("k", keyCode: 40, mods: .command)
            guard let palette = m.delegate.qaProfilePalette, palette.isVisible else {
                throw Failure(message: "setup: ⌘K did not open the Command Center")
            }
            for character in "reveal" { try key(String(character), keyCode: 0) }
            return palette.filteredDisplayNamesForQA.contains("Reveal in Finder")
        }
        revealed.removeAll()
        if try paletteOffersReveal(over: Fixture.noteA1a) {
            if m.delegate.qaProfilePalette?.selectedDisplayNameForQA != "Reveal in Finder" {
                failures.append("⌘K: 'reveal' must select Reveal in Finder, selected \(m.delegate.qaProfilePalette?.selectedDisplayNameForQA ?? "nil")")
            }
            try key("\r", keyCode: 36)
            if revealed.count != 1 || !same(revealed.first, noteURL) {
                failures.append("⌘K: Reveal in Finder over the note revealed \(revealed.map(\.path)), want \(noteURL.path)")
            }
        } else {
            failures.append("⌘K: Reveal in Finder is not offered with a saved note focused")
        }
        m.delegate.qaProfilePalette?.close()
        if try paletteOffersReveal(over: terminal) {
            failures.append("⌘K: Reveal in Finder must not be offered with a terminal focused")
        }
        m.delegate.qaProfilePalette?.close()

        // MARK: ⌥⌘R

        let registry = try CommandRegistry.productRegistry()
        let chord = registry.shortcuts.first { $0.commandID == "tile.revealInFinder" }
        if chord?.defaultGestures != [ShortcutGesture(keyCode: 15, modifiers: [.command, .option])] {
            failures.append("⌥⌘R: the registry has no ⌥⌘R binding for tile.revealInFinder: \(String(describing: chord))")
        }
        revealed.removeAll()
        try focus(Fixture.fileA1)
        try key("\u{AE}", keyCode: 15, mods: [.command, .option], ignoring: "r")
        if revealed.count != 1 || !same(revealed.first, fileURL) {
            failures.append("⌥⌘R with the file focused revealed \(revealed.map(\.path)), want \(fileURL.path)")
        }

        guard failures.isEmpty else {
            throw Failure(message: "reveal in finder: \(failures.count) failure(s):\n  - " + failures.joined(separator: "\n  - "))
        }
        return "tile menu reveals a saved note's .array/notes file and a file tile's document, is disabled for a missing note body and a never-written document, absent on a terminal; ⌘K offers it over the note and not the terminal; ⌥⌘R reveals the focused file"
    }

    private static func seed(_ fixture: Fixture, projectRoot: URL) throws {
        let store = ProjectStore(projectRoot: projectRoot)
        var canvas = try store.loadCanvas()
        var note = Tile(
            id: missingNote, kind: .note, title: "no file", frame: TileFrame(x: 640, y: 520, width: 240, height: 160),
            zPosition: .fromLegacyRank(30), runtimeRef: nil, metadata: TileMetadata(noteId: missingNote))
        note.zoneId = Fixture.zoneA1
        let unsavedLocation = DocumentLocationResolver.resolve(
            fileURL: projectRoot.appendingPathComponent(unsavedName),
            knownRoots: [DocumentLocationRoot(rootURL: projectRoot, projectId: Fixture.projectA1)])
        var file = Tile(
            id: unsavedFile, kind: .file, title: unsavedName, frame: TileFrame(x: 1200, y: 560, width: 240, height: 200),
            zPosition: .fromLegacyRank(31), runtimeRef: nil,
            metadata: TileMetadata(filePath: unsavedLocation.path, documentLocation: unsavedLocation))
        file.zoneId = Fixture.zoneA1
        var shell = Tile(
            id: terminal, kind: .terminal, title: "shell", frame: TileFrame(x: 920, y: 700, width: 240, height: 160),
            zPosition: .fromLegacyRank(32), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "shell", projectRelativeCwd: "."))
        shell.zoneId = Fixture.zoneA1
        canvas.tiles += [note, file, shell]
        try store.saveCanvas(canvas)
    }
}
