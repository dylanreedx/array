import AppKit
import ContinuumRevivedCore
import Foundation

/// `--leader-snap-check`, mounted arm: ⌥+arrow docks the current tile in the
/// scene the app actually runs.
///
/// The flat arm in `runLeaderSnapSelfCheck` installs tiles with
/// `canvas.install`, a checks-only path that keeps `canvasState.tiles` full.
/// Production mounts through `mountWorkspaceSceneAtBoot`, whose
/// `retireFlatCompatibilityScene` empties that list, and the dock looked the tile
/// up there — so ⌥+arrow silently did nothing while the flat arm stayed green.
///
/// This arm mounts the invariants fixture, hosts it in a key window with the
/// production monitors, makes a Preview-mode note current by the click route,
/// holds ⌥ past the production dwell and sends ⌥→ through `NSApp.sendEvent`. It
/// asserts the tile's WORLD frame in the mounted model, then that releasing ⌥
/// commits that same world frame to the project's canvas file.
extension AppDelegate {
    @MainActor
    static func runLeaderSnapMountedArm() throws -> [String: Any] {
        typealias Fixture = WorkspaceInvariantsFixture
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: "leader snap (mounted): " + message) }
        }
        final class KeyableFixtureWindow: NSWindow {
            override var canBecomeKey: Bool { true }
        }
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
            throw Failure(description: "leader snap (mounted): refusing to run without CONTINUUM_APP_SUPPORT")
        }

        let fixture = try Fixture(label: "leader-snap")
        defer { fixture.dispose() }
        let mover = Fixture.noteA1a
        // Preview mode: the note is current but no editable text has the keyboard,
        // so ⌥→ is the leader's (in an editing note it is a word move).
        let store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        var seeded = try store.loadCanvas()
        if let index = seeded.tiles.firstIndex(where: { $0.id == mover }) {
            seeded.tiles[index].metadata.markdownDocumentMode = .preview
        }
        try store.saveCanvas(seeded)

        try fixture.mount()
        let m = try fixture.requireMounted("leader snap")
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

        func spin(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func send(_ type: NSEvent.EventType, _ mods: NSEvent.ModifierFlags, keyCode: UInt16, characters: String = "") throws {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
            else { throw Failure(description: "leader snap (mounted): could not synthesize an event") }
            NSApp.sendEvent(event)
        }

        try expect(!m.canvas.isFlatCompatibilitySceneActive && m.canvas.canvasState.tiles.isEmpty,
                   "precondition: the mounted scene must have retired the flat tile list")
        guard let view = m.canvas.tileView(for: mover) else {
            throw Failure(description: "leader snap (mounted): the note has no view in the mounted scene")
        }
        let click = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        AppDelegate.routeTileClickFocus(at: click, in: m.canvas, focusBroker: m.delegate.qaFocusBroker)
        try expect(m.canvas.canvasState.lastActiveTileId == mover, "precondition: clicking the note must make it current")
        try expect((window.firstResponder as? NSTextView)?.isEditable != true,
                   "precondition: a Preview note must not put editable text in front of the keyboard")

        let before = try fixture.modelView().tileWorldFrames
        guard let original = before[mover] else { throw Failure(description: "leader snap (mounted): no world frame for the note") }
        let others = before.filter { $0.key != mover }.map(\.value)
        let candidates = TileArrangement.dockCandidates(ahead: original, direction: .right, among: others)
        guard let nearest = candidates.first else {
            throw Failure(description: "leader snap (mounted): the seed has no tile to the right of the note")
        }
        let expected = TileArrangement.dockDestination(original, direction: .right, against: nearest, gap: TileGapResolver.resolvedGap())
        try expect(expected != original, "precondition: docking right must move the note")

        try send(.flagsChanged, .option, keyCode: 58)
        spin(TimeInterval(NavKeymap.default.effectiveLeaderDwellMs) / 1000 + 0.25)
        try expect(m.delegate.qaFocusBroker.activeSurface == .modal(.leader), "holding ⌥ must open the leader")
        try send(.keyDown, [.option, .function, .numericPad], keyCode: 124,
                 characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        let docked = try fixture.modelView().tileWorldFrames[mover]
        try expect(docked == expected,
                   "⌥→ must dock the note's WORLD frame to its right neighbour; got \(String(describing: docked)) want \(expected) (was \(original))")

        try send(.flagsChanged, [], keyCode: 58)
        fixture.drain()
        let disk = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles.first { $0.id == mover }?.frame
        try expect(disk == expected,
                   "releasing ⌥ must commit the dock to disk in WORLD frames; disk \(String(describing: disk)) want \(expected)")
        return ["original": "\(original)", "docked": "\(expected)", "disk": "\(String(describing: disk))"]
    }
}
