import AppKit
import ContinuumRevivedCore
import Foundation

/// `--zone-rename-hotkey-check`: a zone rename that is still being typed
/// survives an app hotkey, a workspace switch and quit.
///
/// Every arm mounts the invariants fixture's two workspaces through
/// `mountWorkspaceSceneAtBoot`, hosts the canvas in an off-display key window,
/// installs the keyDown monitor launch installs, opens the real inline rename
/// field over zone "Roots", and types into it through `NSApp.sendEvent` — the
/// route every keystroke takes, monitor first. What is asserted is always the
/// outcome a user would see: the field's state, the mounted document's zone
/// name, and the zone name decoded from the workspace file's raw bytes.
///
///  - control: Return commits. Proves typing reaches the field and the commit
///    reaches disk, so the RED arms below cannot be a broken harness.
///  - palette switch: ⌘K, then the Command Center's Switch Workspace, then quit.
///  - consumed hotkey: ⌘F (focus mode, a no-op with no tile selected) is
///    swallowed by the monitor and moves no focus; then quit.
///  - quit: the field is still open when the app quits.
///  - close button: the window's close flush runs with the field still open
///    (a titlebar button takes no focus, so nothing blurs the field first).
///  - zone not found: the mounted document has lost the zone the canvas still
///    shows, and the rename must still reach the workspace file.
@MainActor
enum ZoneRenameHotkeyChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The field editor needs a key window; `.borderless` keeps the window off
    /// every display (`orderFrontOffscreenForChecks`), so allow it to be key.
    private final class KeyableFixtureWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static let seededName = "Roots"
    static let typedName = "Harbour"

    static func run() throws -> URL {
        var failures: [String] = []
        var manifest: [String: Any] = [:]
        manifest["control"] = try runArm("control", failures: &failures, controlArm)
        manifest["paletteSwitch"] = try runArm("palette switch", failures: &failures, paletteSwitchArm)
        manifest["consumedHotkey"] = try runArm("consumed hotkey", failures: &failures, consumedHotkeyArm)
        manifest["quit"] = try runArm("quit", failures: &failures, quitArm)
        manifest["closeButton"] = try runArm("close button", failures: &failures, closeButtonArm)
        manifest["zoneNotFound"] = try runArm("zone not found", failures: &failures, zoneNotFoundArm)

        guard failures.isEmpty else {
            throw Failure(message: "zone rename hotkey: \(failures.count) assertion(s) failed:\n  - "
                + failures.joined(separator: "\n  - "))
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/zone-rename-hotkey", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - Harness

    /// One arm on its own fixture. Setup problems throw (the arm cannot say
    /// anything); assertion failures are collected so a RED run names every arm.
    private static func runArm(
        _ name: String,
        failures: inout [String],
        _ body: (Fixture, inout [String]) throws -> [String: Any]
    ) throws -> [String: Any] {
        let fixture = try Fixture(label: "rename-hotkey")
        defer { fixture.dispose() }
        var armFailures: [String] = []
        let result = try body(fixture, &armFailures)
        failures += armFailures.map { "\(name): \($0)" }
        return result.merging(["failures": armFailures]) { current, _ in current }
    }

    private static func key(
        _ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)
        else { throw Failure(message: "could not synthesize key \(characters)") }
        return event
    }

    private struct Session {
        let mounted: Fixture.Mounted
        let window: NSWindow
    }

    /// Mount, host the canvas in a key window with the production monitor,
    /// open the rename field over zone A1 and type `typedName` into it.
    private static func openRenameAndType(_ fixture: Fixture) throws -> Session {
        try fixture.mount()
        let m = try fixture.requireMounted("open rename")
        let window = KeyableFixtureWindow(
            contentRect: NSRect(origin: .zero, size: m.canvas.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = m.canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        m.delegate.qaAttachWindowInstallingHotkeyMonitor(window)
        m.canvas.layoutSubtreeIfNeeded()

        m.canvas.beginZoneRename(zoneId: Fixture.zoneA1)
        guard m.canvas.qaZoneRenameActiveZoneId == Fixture.zoneA1 else {
            throw Failure(message: "setup: the inline rename field did not open over zone A1")
        }
        guard m.canvas.qaZoneRenameFieldText == seededName else {
            throw Failure(message: "setup: the field must open seeded with '\(seededName)', holds '\(m.canvas.qaZoneRenameFieldText ?? "nil")'")
        }
        // The seed is selected, so the first keystroke replaces it.
        for character in typedName {
            NSApp.sendEvent(try key(String(character), keyCode: 0, in: window))
        }
        guard m.canvas.qaZoneRenameFieldText == typedName else {
            throw Failure(message: "setup: typing through NSApp.sendEvent must reach the rename field; it holds '\(m.canvas.qaZoneRenameFieldText ?? "nil")'")
        }
        return Session(mounted: m, window: window)
    }

    private static func close(_ session: Session) {
        session.window.orderOut(nil)
        session.window.contentView = nil
    }

    private static func memoryName(_ m: Fixture.Mounted, workspace: UUID = Fixture.workspaceA) -> String? {
        guard m.runtime.workspaceId == workspace else { return nil }
        return m.runtime.document.zones.first { $0.zoneId == Fixture.zoneA1 }?.name
    }

    private static func diskName(_ fixture: Fixture) throws -> String? {
        try fixture.readWorkspaceFile(Fixture.workspaceA).document?.zones
            .first { $0.zoneId == Fixture.zoneA1 }?.name
    }

    // MARK: - Arms

    private static func controlArm(_ fixture: Fixture, _ failures: inout [String]) throws -> [String: Any] {
        let session = try openRenameAndType(fixture)
        defer { close(session) }
        let m = session.mounted
        NSApp.sendEvent(try key("\r", keyCode: 36, in: session.window))
        let open = m.canvas.qaZoneRenameActiveZoneId != nil
        let memory = memoryName(m)
        let disk = try diskName(fixture)
        if open || memory != typedName || disk != typedName {
            failures.append("Return must commit the typed name to memory and disk; field open \(open), memory '\(memory ?? "nil")', disk '\(disk ?? "nil")'")
        }
        try fixture.quit()
        return ["memory": memory ?? NSNull(), "disk": disk ?? NSNull()]
    }

    private static func paletteSwitchArm(_ fixture: Fixture, _ failures: inout [String]) throws -> [String: Any] {
        let session = try openRenameAndType(fixture)
        defer { close(session) }
        let m = session.mounted
        NSApp.sendEvent(try key("k", keyCode: 40, flags: .command, in: session.window))
        let paletteOpen = m.delegate.qaProfilePalette?.isVisible == true
        let openAfterHotkey = m.canvas.qaZoneRenameActiveZoneId != nil
        let memoryAtHotkey = memoryName(m)
        if !paletteOpen {
            failures.append("positive control: ⌘K through the production monitor must open the Command Center")
        }
        if openAfterHotkey || memoryAtHotkey != typedName {
            failures.append("⌘K acted before the rename committed; field open \(openAfterHotkey), memory '\(memoryAtHotkey ?? "nil")'")
        }
        let switched = m.delegate.qaPerformPaletteAction(.switchWorkspace(Fixture.workspaceB))
        if !switched || m.runtime.workspaceId != Fixture.workspaceB {
            failures.append("the Command Center's Switch Workspace must mount B; now on \(m.runtime.workspaceId)")
        }
        try fixture.quit()
        let disk = try diskName(fixture)
        if disk != typedName {
            failures.append("after ⌘K, a switch and quit, A's file must hold '\(typedName)', holds '\(disk ?? "nil")'")
        }
        return ["paletteOpened": paletteOpen, "memoryAtHotkey": memoryAtHotkey ?? NSNull(), "disk": disk ?? NSNull()]
    }

    private static func consumedHotkeyArm(_ fixture: Fixture, _ failures: inout [String]) throws -> [String: Any] {
        let session = try openRenameAndType(fixture)
        defer { close(session) }
        let m = session.mounted
        guard m.canvas.canvasState.lastActiveTileId == nil else {
            throw Failure(message: "setup: ⌘F is only a no-op with no tile selected")
        }
        NSApp.sendEvent(try key("f", keyCode: 3, flags: .command, in: session.window))
        let openAfterHotkey = m.canvas.qaZoneRenameActiveZoneId != nil
        let memoryAtHotkey = memoryName(m)
        if openAfterHotkey || memoryAtHotkey != typedName {
            failures.append("⌘F was consumed with the rename uncommitted; field open \(openAfterHotkey), holds '\(m.canvas.qaZoneRenameFieldText ?? "nil")', memory '\(memoryAtHotkey ?? "nil")'")
        }
        try fixture.quit()
        let memory = memoryName(m)
        let disk = try diskName(fixture)
        if disk != typedName || disk != memory {
            failures.append("after ⌘F and quit, disk must equal memory and hold '\(typedName)'; memory '\(memory ?? "nil")', disk '\(disk ?? "nil")'")
        }
        return ["memoryAtHotkey": memoryAtHotkey ?? NSNull(), "memory": memory ?? NSNull(), "disk": disk ?? NSNull()]
    }

    private static func quitArm(_ fixture: Fixture, _ failures: inout [String]) throws -> [String: Any] {
        let session = try openRenameAndType(fixture)
        defer { close(session) }
        let m = session.mounted
        try fixture.quit()
        let memory = memoryName(m)
        let disk = try diskName(fixture)
        if memory != typedName || disk != memory {
            failures.append("quitting with the field open must commit it; memory '\(memory ?? "nil")', disk '\(disk ?? "nil")'")
        }
        return ["memory": memory ?? NSNull(), "disk": disk ?? NSNull()]
    }

    private static func closeButtonArm(_ fixture: Fixture, _ failures: inout [String]) throws -> [String: Any] {
        let session = try openRenameAndType(fixture)
        defer { close(session) }
        let m = session.mounted
        let allowed = m.delegate.windowShouldClose(session.window)
        let memory = memoryName(m)
        let disk = try diskName(fixture)
        if !allowed || memory != typedName || disk != memory {
            failures.append("the close flush must commit the open field first; close allowed \(allowed), memory '\(memory ?? "nil")', disk '\(disk ?? "nil")'")
        }
        try fixture.quit()
        return ["memory": memory ?? NSNull(), "disk": disk ?? NSNull()]
    }

    private static func zoneNotFoundArm(_ fixture: Fixture, _ failures: inout [String]) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("zone not found")
        var diverged = m.runtime.document
        diverged.zones.removeAll { $0.zoneId == Fixture.zoneA1 }
        m.runtime.replaceDocument(diverged, for: Fixture.workspaceA)
        m.canvas.qaRenameZone(Fixture.zoneA1, to: typedName)
        let memory = memoryName(m)
        let disk = try diskName(fixture)
        if disk != typedName || memory != typedName {
            failures.append("a rename the mounted document cannot place must still reach the workspace file; memory '\(memory ?? "nil")', disk '\(disk ?? "nil")'")
        }
        try fixture.quit()
        return ["memory": memory ?? NSNull(), "disk": disk ?? NSNull()]
    }
}
