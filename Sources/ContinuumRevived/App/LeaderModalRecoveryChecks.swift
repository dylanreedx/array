import AppKit
import ContinuumRevivedCore
import Foundation

/// `--leader-modal-recovery-check`: closing a modal never leaves the focus
/// broker parked on that modal.
///
/// The hold-⌥ leader refuses to arm while the broker's surface is ANY modal
/// (`scheduleLeaderActivation`). A modal restores the surface it snapshotted on
/// open — so if there was none to snapshot, or the snapshotted surface left the
/// broker while the modal was up, the close restored nothing and the broker
/// stayed modal. Quick Jump was then dead until something else took focus,
/// while ⌃Space (which does not check) still opened.
///
/// Mounted through `mountWorkspaceSceneAtBoot`, real key monitors, real events:
///
///  - no scope: a tile is focused, then the canvas removes its view (the path
///    a focused Web Inspector takes when its browser closes). From there the
///    leader is opened and closed by Esc, by releasing ⌥, and by a label jump.
///    The sidebar switch and a pan away are traced too: both recover by
///    themselves today.
///  - vanished snapshot: a tile is focused, ⌘K opens, Switch Workspace is chosen
///    from it; the palette closes after its snapshot's tile has left.
///
/// After every close: the broker's surface is not a modal, and a second ⌥ hold
/// opens Quick Jump again.
@MainActor
enum LeaderModalRecoveryChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private final class KeyableFixtureWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
            throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT: mounting restores agents from the channel's store")
        }
        let fixture = try Fixture(label: "leader-modal-recovery")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("leader modal recovery")
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
        let broker = m.delegate.qaFocusBroker
        let canvas = m.canvas
        let pastDwell = TimeInterval(NavKeymap.default.effectiveLeaderDwellMs) / 1000 + 0.25
        var failures: [String] = []
        var log: [String] = []

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
            else { throw Failure(message: "could not synthesize an event") }
            NSApp.sendEvent(event)
        }
        var leaderOpen: Bool { broker.activeSurface == .modal(.leader) }
        var surface: String { String(describing: broker.activeSurface) }
        func isModal(_ id: FocusSurfaceID?) -> Bool {
            if case .modal = id { return true }
            return false
        }
        func clickFocus(_ tileId: UUID) throws {
            guard let view = canvas.tileView(for: tileId) else {
                throw Failure(message: "setup: tile \(tileId) has no view")
            }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            AppDelegate.routeTileClickFocus(at: point, in: canvas, focusBroker: broker)
            guard broker.activeSurface == .tile(tileId) else {
                throw Failure(message: "setup: clicking tile \(tileId) left the broker on \(surface)")
            }
        }
        /// Ways a user loses the focused surface without anything taking a new
        /// one. Each is tried and logged; the first that leaves the broker on no
        /// scope is the one the arms use.
        let seededViewport = Fixture.seededViewports[Fixture.workspaceA]!
        func routeSwitch() throws {
            if m.runtime.workspaceId != Fixture.workspaceA { try fixture.switchTo(Fixture.workspaceA) }
            try clickFocus(Fixture.noteA1a)
            // The sidebar switch parks the focused tile's view out of the broker.
            try fixture.switchTo(Fixture.workspaceB)
        }
        func routeCameraAway() throws {
            if m.runtime.workspaceId != Fixture.workspaceA { try fixture.switchTo(Fixture.workspaceA) }
            canvas.setViewport(seededViewport)
            m.runtime.flushPendingHydrationReconcile()
            spin(0.2)
            canvas.layoutSubtreeIfNeeded()
            try clickFocus(Fixture.noteA1a)
            // Panning far away: the focused tile's zone drops out of the live tier.
            canvas.setViewport(CanvasViewport(x: 200_000, y: 200_000, zoom: 1))
            m.runtime.flushPendingHydrationReconcile()
            spin(0.2)
            canvas.layoutSubtreeIfNeeded()
        }
        // The two everyday routes recover the scope themselves (logged, so a
        // regression in either shows up in the trace). What does not is the
        // canvas's own removal of the focused view — the primitive under every
        // path that retires a view without `deleteTile`'s focus recovery, e.g. a
        // focused Web Inspector removed with the browser it inspects
        // (`deleteBrowserInspectors`). Each arm removes its own tile.
        for (name, route) in [("sidebar switch", routeSwitch), ("camera away", routeCameraAway)] {
            do { try route() } catch { log.append("\(name) → setup failed: \(error)"); continue }
            log.append("\(name) → \(surface)")
        }
        if m.runtime.workspaceId != Fixture.workspaceA { try fixture.switchTo(Fixture.workspaceA) }
        canvas.setViewport(seededViewport)
        m.runtime.flushPendingHydrationReconcile()
        spin(0.2)
        canvas.layoutSubtreeIfNeeded()
        var doomed = [Fixture.noteA1a, Fixture.noteA1b, Fixture.fileA1]
        func reachNoScope(_ step: String) throws {
            guard !doomed.isEmpty else { throw Failure(message: "\(step): no tile left to remove") }
            let tileId = doomed.removeFirst()
            try clickFocus(tileId)
            canvas.removeTile(id: tileId)
            log.append("\(step): focused tile removed → \(surface)")
            guard broker.activeSurface == nil else {
                throw Failure(message: "\(step): removing the focused tile left the broker on \(surface), not on no scope")
            }
        }
        /// After a close: not modal, and the next hold opens again.
        func expectRecovered(_ step: String) throws {
            if isModal(broker.activeSurface) {
                failures.append("\(step): after the leader closed, the broker is still on \(surface)")
            }
            try send(.flagsChanged, .option, keyCode: 58)
            spin(pastDwell)
            if !leaderOpen {
                failures.append("\(step): a second ⌥ hold did not open Quick Jump (broker on \(surface))")
            }
            try send(.flagsChanged, [], keyCode: 58)
            spin(0.05)
        }
        func openLeader(_ step: String) throws {
            try send(.flagsChanged, .option, keyCode: 58)
            spin(pastDwell)
            guard leaderOpen else {
                throw Failure(message: "\(step): holding ⌥ with no scope did not open the leader (broker on \(surface))")
            }
        }

        // 1. No scope, closed by Esc.
        try reachNoScope("esc")
        try openLeader("esc")
        try send(.keyDown, .option, keyCode: 53, characters: "\u{1B}")
        try send(.flagsChanged, [], keyCode: 58)
        spin(0.05)
        try expectRecovered("no scope, closed by Esc")

        // 2. No scope, closed by releasing ⌥.
        try reachNoScope("release")
        try openLeader("release")
        try send(.flagsChanged, [], keyCode: 58)
        spin(0.05)
        try expectRecovered("no scope, closed by releasing ⌥")

        // 3. No scope, closed by a label jump.
        try reachNoScope("jump")
        try openLeader("jump")
        guard let label = canvas.leaderJumpAssignments().first?.label else {
            throw Failure(message: "jump: Quick Jump opened over workspace B with no labels")
        }
        let keyCodes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "j": 38, "k": 40, "l": 37]
        try send(.keyDown, .option, keyCode: keyCodes[label] ?? 0, characters: label)
        try send(.flagsChanged, [], keyCode: 58)
        spin(0.05)
        try expectRecovered("no scope, closed by a label jump")

        // 4. ⌘K opened over a focused tile, Switch Workspace chosen from it: the
        //    palette closes after the tile it would restore has left the broker.
        if m.runtime.workspaceId != Fixture.workspaceA { try fixture.switchTo(Fixture.workspaceA) }
        try clickFocus(Fixture.noteA2a)
        try send(.keyDown, .command, keyCode: 40, characters: "k")
        guard m.delegate.qaProfilePalette?.isVisible == true else {
            throw Failure(message: "palette: ⌘K did not open the Command Center")
        }
        for character in "Forest" {
            try send(.keyDown, [], keyCode: 0, characters: String(character))
        }
        try send(.keyDown, [], keyCode: 36, characters: "\r")
        spin(0.1)
        log.append("palette: after Switch Workspace the runtime is on \(m.runtime.workspaceId), palette visible \(m.delegate.qaProfilePalette?.isVisible == true), broker on \(surface)")
        guard m.runtime.workspaceId == Fixture.workspaceB, m.delegate.qaProfilePalette?.isVisible != true else {
            throw Failure(message: "palette: choosing Switch Workspace from ⌘K did not switch to B and close (\(log.last ?? ""))")
        }
        try expectRecovered("⌘K Switch Workspace away from the focused tile")

        guard failures.isEmpty else {
            throw Failure(message: "leader modal recovery: \(failures.count) failure(s):\n  - "
                + failures.joined(separator: "\n  - ") + "\n  trace: " + log.joined(separator: "; "))
        }
        return "with no focused surface, Esc, releasing ⌥ and a label jump each close the leader to a non-modal surface and the next hold opens it; ⌘K Switch Workspace away from a focused tile does the same. Trace: " + log.joined(separator: "; ")
    }
}
