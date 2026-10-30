import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Drives personal and shared windows in the same delegate. The source scene
/// comes from the shipping boot mount; no provider, Keychain or tmux is used.
/// The platform's foreground-window lookup is injected because an inactive
/// self-check process must never activate itself or take the user's keyboard.
@MainActor
enum CollaborationWindowCommandChecks {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private final class FixtureWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        func read(service: String, account: String) throws -> Data? { nil }
        func write(_ data: Data, service: String, account: String) throws { }
        func remove(service: String, account: String) throws { }
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: message) }
        print("PASS collaboration window commands: \(message)")
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func files(under roots: [URL]) throws -> [String: Data] {
        var values: [String: Data] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw Failure(description: "source file census could not enumerate \(root.lastPathComponent)")
            }
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    values[url.path] = try Data(contentsOf: url)
                }
            }
        }
        return values
    }
    private static func event(in window: NSWindow, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                              characters: String = "", type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        guard let result = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else {
            throw Failure(description: "could not construct window-scoped input")
        }
        try expect(result.window === window, "synthetic input retains its actual owning window")
        return result
    }
    private static func flags(_ value: UInt) -> NSEvent.ModifierFlags {
        let modifiers = FocusKeyModifiers(rawValue: value)
        var result: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
    private static func scene(in view: NSView) -> SharedAreaSceneView? {
        if let result = view as? SharedAreaSceneView { return result }
        return view.subviews.lazy.compactMap { scene(in: $0) }.first
    }

    static func run() async throws {
        guard let isolatedSupport = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"],
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "mixed-window witness requires an isolated dev self-check")
        }
        var executorConstructions = 0
        let fixture = try WorkspaceAPIChecks.makeFixture(beforeMount: { delegate, root in
            // The API fixture first creates an idle source record. Retain its
            // exact identity while making even a broken UI guard unable to call
            // a real provider through this witness's mounted supervisor.
            let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("scripted-agents"))
            for record in delegate.qaAgentSupervisor.records.values { try store.upsert(record) }
            delegate.agentSupervisor = AgentSupervisor(store: store, makeRunner: { _ in
                executorConstructions += 1
                return ScriptedAgentRunner(script: [])
            })
            _ = delegate.agentSupervisor.restore()
            delegate.agentSupervisor.workspaceToolsPermission = { .off }
        })
        defer { fixture.runtime.closeAll(); fixture.tearDown() }
        let delegate = fixture.delegate
        let supervisor = delegate.qaAgentSupervisor
        var focusedWindow: NSWindow?
        let originalWindowProvider = delegate.userCommandWindowProvider
        delegate.userCommandWindowProvider = { focusedWindow }
        defer { delegate.userCommandWindowProvider = originalWindowProvider }
        try expect(supervisor.records[fixture.agentId] != nil, "mounted source keeps its genuine API agent identity with a scripted executor factory")
        let personal = FixtureWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        personal.isReleasedWhenClosed = false; personal.contentView = fixture.canvas
        delegate.qaAttachWindowForOfflineCheck(personal)
        personal.orderFrontOffscreenForChecks(); focusedWindow = personal
        defer { personal.orderOut(nil) }
        try expect(delegate.userCommandWindowProvider() === personal && !CollaborationWindow.owns(personal),
            "injected platform lookup supplies the actual personal window without activating the self-check app")
        try fixture.runtime.flushMountedWorkspaceState()

        let appearanceHost = try SharedAreaSceneChecks.makeAppearanceFixture()
        guard let cachedScene = scene(in: appearanceHost), let person = cachedScene.controller.document?.posts.first?.author else {
            throw Failure(description: "shared fixture has no cached controller or owning identity")
        }
        cachedScene.unmount()
        let shared = SharedAreaWindowController(controller: cachedScene.controller, person: person, delegate: delegate)
        shared.window.orderFrontOffscreenForChecks(); focusedWindow = shared.window
        await shared.controller.open()
        defer { shared.scene.unmount(); shared.window.orderOut(nil) }
        try expect(shared.controller.status == .connected && shared.scene.isMounted,
            "actual shared window mounts and admits scripted portable state beside the personal source")

        let hubRoot = URL(fileURLWithPath: isolatedSupport).appendingPathComponent("mixed-window-hub-\(UUID())")
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let model = try CollaborationAccountController(
            store: CollaborationAccountStore(applicationSupportRoot: hubRoot, bundleIdentifier: nil),
            credentialStore: CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil),
            bundleIdentifier: nil, transportFactory: { _, _ in throw Failure(description: "inert hub unexpectedly requested transport") })
        let hub = CollaborationHubWindowController(model: model)
        defer { _ = hub.content.stop(); hub.window.orderOut(nil) }

        let originalFiles = try files(under: [fixture.tempRoot])
        let originalTiles = try encoded(fixture.canvas.allTilesInWorldFrames())
        let originalDocument = try encoded(fixture.runtime.document)
        let originalViewport = fixture.canvas.viewport
        let originalFocus = fixture.focusBroker.activeSurface
        let originalRecords = supervisor.records
        let originalGeneration = fixture.runtime.interactionGeneration
        let originalRunning = Set(supervisor.records.keys.filter { supervisor.isRunning($0) })
        let creationSelectors: [Selector] = [
            #selector(AppDelegate.createZoneFromMenu(_:)), #selector(AppDelegate.createAgentFromMenu(_:)),
            #selector(AppDelegate.createTerminalFromMenu(_:)), #selector(AppDelegate.createNoteFromMenu(_:)),
            #selector(AppDelegate.createBoardFromMenu(_:)), #selector(AppDelegate.createBrowserFromMenu(_:)),
            #selector(AppDelegate.createFileTreeFromMenu(_:)), #selector(AppDelegate.openCommandCenterFromMenu(_:))
        ]
        let registry = try CommandRegistry.productRegistry()
        let bindings = ShortcutBindingStore()
        let creationCommandIDs: [CommandID] = ["agent.newManaged", "tile.newTerminal", "tile.newNote",
            "tile.quickSpawn.1", "tile.quickSpawn.2", "tile.quickSpawn.3", "tile.quickSpawn.4", "app.commandCenter"]

        func assertSourcePreserved(_ label: String) throws {
            try expect(try files(under: [fixture.tempRoot]) == originalFiles,
                "\(label) preserves source project, workspace and agent file bytes and membership")
            try expect(try encoded(fixture.canvas.allTilesInWorldFrames()) == originalTiles
                && encoded(fixture.runtime.document) == originalDocument && fixture.canvas.viewport == originalViewport,
                "\(label) leaves source WORLD geometry, workspace document and camera unchanged")
            try expect(fixture.focusBroker.activeSurface == originalFocus
                && fixture.runtime.interactionGeneration == originalGeneration,
                "\(label) leaves personal focus, armed zone and interaction generation unchanged")
            try expect(supervisor.records == originalRecords && executorConstructions == 0
                && Set(supervisor.records.keys.filter { supervisor.isRunning($0) }) == originalRunning,
                "\(label) creates no agent record or executor and leaves existing execution unchanged")
        }
        func exerciseForeignWindow(_ window: NSWindow, label: String) throws {
            window.orderFrontOffscreenForChecks(); focusedWindow = window
            try expect(delegate.userCommandWindowProvider() === window && CollaborationWindow.owns(window),
                "injected platform lookup supplies the actual \(label) window and its collaboration hierarchy")
            for selector in creationSelectors {
                let item = NSMenuItem(title: "Witness", action: selector, keyEquivalent: "")
                try expect(!delegate.validateMenuItem(item), "\(label) disables personal menu action \(NSStringFromSelector(selector))")
                // Invoke despite validation to prove action-side refusal too.
                try expect(NSApp.sendAction(selector, to: delegate, from: item), "shipping menu selector is wired")
            }
            for id in creationCommandIDs {
                try expect(!delegate.qaPerformRegisteredGlobalCommand(id), "\(label) refuses registered command \(id.rawValue)")
                for definition in registry.shortcuts where definition.commandID == id {
                    for gesture in bindings.gestures(for: definition) {
                        try expect(!delegate.handleHotkey(try event(in: window, keyCode: gesture.keyCode,
                            modifiers: flags(gesture.modifiersRawValue), characters: "n")),
                            "\(label) passes its own registered shortcut to its responder instead of the personal canvas")
                    }
                }
            }
            try expect(!delegate.qaPerformPaletteAction(.newNote) && !delegate.qaPerformPaletteAction(.createZone)
                && !delegate.qaPerformPaletteAction(.tidyCanvas), "\(label) refuses stale personal palette callbacks")
            delegate.handleFloatingToolbarSelection(.palette(.newNote))
            delegate.leaderDwell = 0
            delegate.handleFlagsChanged(try event(in: window, keyCode: 58, modifiers: [.option], type: .flagsChanged))
            try expect(fixture.focusBroker.activeSurface == originalFocus, "\(label) modifier input cannot activate the personal hold leader")
            try expect(!delegate.handleHotkey(try event(in: window, keyCode: 51, modifiers: [.command])),
                "\(label) command-delete cannot delete the personal selected tile")
            try assertSourcePreserved(label)
        }
        try exerciseForeignWindow(shared.window, label: "shared workspace")
        try exerciseForeignWindow(hub.window, label: "collaboration hub")

        // ChoicePopoverController uses addChildWindow, rather than a sheet.
        // Reproduce that actual AppKit relationship without showing a menu on
        // the user's screen from an inactive self-check process.
        let choiceChild = FixtureWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        shared.window.addChildWindow(choiceChild, ordered: .above)
        try expect(choiceChild.parent === shared.window && choiceChild.sheetParent == nil,
            "choice-style child uses a distinct actual AppKit parent relationship")
        try exerciseForeignWindow(choiceChild, label: "collaboration choice child")
        shared.window.removeChildWindow(choiceChild); choiceChild.orderOut(nil)

        focusedWindow = shared.window
        let sheet = FixtureWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        print("STAGE collaboration window commands: attach nonwaiting sheet")
        shared.window.beginSheet(sheet, completionHandler: nil)
        print("STAGE collaboration window commands: sheet attached")
        focusedWindow = sheet
        try expect(sheet.sheetParent === shared.window && CollaborationWindow.owns(sheet), "collaboration sheets inherit their actual parent's UI scope")
        try expect(!delegate.handleHotkey(try event(in: sheet, keyCode: 45, modifiers: [.command, .shift], characters: "n")),
            "shared sheet keyboard input cannot create a personal note")
        shared.window.endSheet(sheet); sheet.orderOut(nil); focusedWindow = shared.window
        try assertSourcePreserved("shared sheet")

        // A dwell started in the personal window must not open its overlay after
        // the platform lookup reports a shared window before the timer fires.
        focusedWindow = personal; delegate.leaderDwell = 0.02
        delegate.handleFlagsChanged(try event(in: personal, keyCode: 58, modifiers: [.option], type: .flagsChanged))
        focusedWindow = shared.window
        try await Task.sleep(for: .milliseconds(80))
        try expect(fixture.focusBroker.activeSurface == originalFocus, "pending personal hold-leader activation rechecks collaboration window ownership")
        try assertSourcePreserved("pending personal dwell")

        // Explicit project authority remains independent of the foreground UI.
        supervisor.setWorkspaceToolsEnabled(agentID: fixture.agentId, true)
        let context = fixture.api.dispatch(agentId: fixture.agentId, requestId: "mixed-window-context", op: "workspace.context", payload: [:])
        guard case .result = context else { throw Failure(description: "authorized source API context became unavailable under shared focus") }
        let reply = fixture.api.dispatch(agentId: fixture.agentId, requestId: "mixed-window-open", op: "artifact.open", payload: [
            "relativePath": "notes.md", "presentation": ["camera": "preserve"], "idempotencyKey": "mixed-window-open"
        ])
        guard case let .result(result) = reply else { throw Failure(description: "explicit source API open was blocked by shared UI focus: \(reply)") }
        try expect(result["tileId"]?.string?.lowercased() == fixture.fileTileB.uuidString.lowercased()
            && result["checkoutHandle"]?.string == fixture.pbHandle.rawValue,
            "authorized explicit API open still resolves the source agent's checkout and existing file tile")
        try expect(delegate.userCommandWindowProvider() === shared.window && fixture.canvas.viewport == originalViewport
            && fixture.runtime.document.lastActiveZoneId == fixture.zoneA,
            "explicit source API open preserves supplied shared window context, personal camera and armed zone")

        focusedWindow = personal
        try expect(delegate.userCommandWindowProvider() === personal, "returning the platform lookup to the personal window restores its input scope")
        let noteItem = NSMenuItem(title: "Note", action: #selector(AppDelegate.createNoteFromMenu(_:)), keyEquivalent: "")
        try expect(delegate.validateMenuItem(noteItem), "personal File New Note is enabled again")
        let beforeNotes = fixture.canvas.allTilesInWorldFrames().filter { $0.kind == .note }.count
        try expect(NSApp.sendAction(noteItem.action!, to: delegate, from: noteItem), "personal note menu still reaches its production action")
        try expect(fixture.canvas.allTilesInWorldFrames().filter { $0.kind == .note }.count == beforeNotes + 1,
            "personal source creation still adds exactly one note after visiting shared windows")
        try expect(executorConstructions == 0, "all mixed-window verification used zero provider executor constructions")
        shared.scene.unmount(); await shared.controller.close()
        print("Collaboration mixed-window command checks passed: real source mount and shared/hub/sheet window contexts, injected platform focus lookup, shipping menu and event outcomes, delayed leader and explicit API independence; no app activation or native key-window ownership claim.")
    }
}
