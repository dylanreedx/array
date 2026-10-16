import AppKit
import ContinuumRevivedCore
import Foundation

/// An offscreen borderless window hosting the Settings modal, for checks that
/// need Settings but not a mounted workspace. Parked off every display.
@MainActor
final class SettingsFixtureWindow {
    let window: NSWindow
    let modal: SettingsModal
    var model: SettingsModel { modal.model }

    /// Dark by default, as the app pins it at launch (`applicationDidFinishLaunching`).
    init(model: SettingsModel, size: NSSize = NSSize(width: 1_100, height: 760),
         appearance: NSAppearance? = NSAppearance(named: .darkAqua)) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        if let appearance { window.appearance = appearance }
        window.orderFrontOffscreenForChecks()
        modal = SettingsModal(model: model)
    }

    func show(paneID: String? = nil) {
        modal.show(in: window, paneID: paneID)
        settle()
    }

    func select(_ paneID: String) {
        model.selectPane(paneID)
        settle()
    }

    /// Layout plus enough run-loop turns for SwiftUI to commit and `onAppear` /
    /// `onDisappear` to fire.
    func settle(_ seconds: TimeInterval = 0.06) {
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        modal.close()
        window.orderOut(nil)
    }

    /// The anchors the registry says the selected pane must render.
    func expectedAnchors() -> Set<String> {
        Set(model.entries().filter { $0.paneID == model.selectedPaneID }.compactMap(\.anchor))
    }

    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        guard let root = modal.overlay else { return [] }
        func walk(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
        return walk(root)
    }

    func snapshot() -> NSBitmapImageRep? {
        guard let card = modal.overlay?.card else { return nil }
        return Self.capture(card)
    }

    /// A card render in the card's OWN appearance (layer colours resolve against
    /// the current drawing appearance, not the view's).
    static func capture(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        return rep
    }

    /// Mean luminance (0…1) of a render, sampled on a grid: dark chrome reads low.
    static func meanLuminance(_ rep: NSBitmapImageRep) -> Double {
        var total = 0.0, count = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }
}

@MainActor
enum SettingsSelfChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    // MARK: - `--settings-panel-check`

    /// Every pane renders a row for every registry entry, rows write through the
    /// model's one write path, conditional rows appear and disappear, the model
    /// picker follows the live catalogue, and the modal renders and tears down
    /// without creating a window.
    static func runPanelCheck() throws {
        let suite = "continuum.settingsPanel.selfcheck.\(UUID().uuidString)"
        guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else {
            throw Failure(message: "could not create the isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))

        let sections = SettingsSchema.sections()
        guard let terminal = sections.first(where: { $0.id == "terminal" }),
              terminal.fields.contains(where: {
                  if case .toggle(TmuxPersistenceConfig.enabledKey, _, TmuxPersistenceConfig.defaultEnabled) = $0 { return true }
                  return false
              }),
              SettingsSchema.retainedTuningFields().contains(where: {
                  if case .text(TmuxPersistenceConfig.pathKey, _, TmuxPersistenceConfig.defaultPath) = $0 { return true }
                  return false
              }) else {
            throw Failure(message: "Terminal must render the keep-shells-alive switch and keep the tmux path key")
        }

        // Custom rows mount the app's views; sentinels prove the mount.
        var mounts: [String: Int] = [:]
        var sentinels: [String: NSView] = [:]
        let model = SettingsModel(sections: sections, defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }),
                                  isCompanionEnabled: true)
        for id in ["companion"] {
            let sentinel = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
            sentinels[id] = sentinel
            model.customViews[id] = { mounts[id, default: 0] += 1; return sentinel }
        }
        var background = CanvasBackgroundConfiguration.systemDefault
        model.canvasBackground = CanvasBackgroundEditor(environment: .init(
            loadGlobal: { background }, saveGlobal: { background = $0 },
            loadWorkspace: { .inherit }, saveWorkspace: { _ in },
            importImage: { _ in throw Failure(message: "no import in this check") },
            chooseImageURL: { nil }, hasWorkspace: false))
        let fixture = SettingsFixtureWindow(model: model)
        defer { fixture.tearDown() }
        fixture.show()

        // 1. The sidebar is the schema; the iPhone pane only when the companion is on.
        try expect(model.visiblePanes.map(\.id) == sections.map(\.id),
                   "sidebar panes \(model.visiblePanes.map(\.id)) must mirror the schema")
        let noCompanion = SettingsModel(sections: sections, defaults: defaults, navKeymap: .default, isCompanionEnabled: false)
        try expect(!noCompanion.visiblePanes.contains { $0.id == "companion" } && noCompanion.visiblePanes.count == sections.count - 1,
                   "the iPhone pane must be hidden while the companion is off")

        // 2. Census: each pane renders exactly the rows its registry entries name.
        for section in sections {
            fixture.select(section.id)
            let expected = fixture.expectedAnchors()
            let rendered = Set(model.renderedAnchors.keys)
            let missing = expected.subtracting(rendered)
            try expect(missing.isEmpty, "\(section.title): registry rows not rendered: \(missing.sorted())")
            let stray = rendered.subtracting(expected)
            try expect(stray.isEmpty, "\(section.title): rendered rows the registry does not know: \(stray.sorted())")
        }
        for (id, sentinel) in sentinels {
            try expect((mounts[id] ?? 0) > 0, "custom row \(id) never asked the app for its view")
            _ = sentinel
        }
        fixture.select("appearance")
        try expect(fixture.descendants(CanvasBackgroundRendererView.self).count == 1,
                   "Appearance must draw the canvas background rows and their live preview")
        fixture.select("companion")
        try expect(sentinels["companion"]?.window === fixture.window,
                   "the iPhone pane must mount the pairing view inside the modal")

        // 3. A switch round-trips through the real control: click the NSSwitch the
        // General pane draws, and the bound key and its exact event follow.
        fixture.select("general")
        let dockField = SettingsField.toggle(key: WorkspaceSidebarConfig.visibleKey, label: "", default: WorkspaceSidebarConfig.defaultVisible)
        let switches = fixture.descendants(NSSwitch.self)
        try expect(switches.count == 1, "General must draw exactly one switch (the Activity Dock), drew \(switches.count)")
        final class Counts: @unchecked Sendable { var exact = 0; var unrelated = 0 }
        let counts = Counts()
        let exact = NotificationCenter.default.addObserver(
            forName: SettingChangeEvent.name(for: SettingID(rawValue: WorkspaceSidebarConfig.visibleKey)), object: nil, queue: nil
        ) { _ in counts.exact += 1 }
        let unrelated = NotificationCenter.default.addObserver(
            forName: SettingChangeEvent.name(for: "settings.selfcheck.unrelated"), object: nil, queue: nil
        ) { _ in counts.unrelated += 1 }
        defer {
            NotificationCenter.default.removeObserver(exact)
            NotificationCenter.default.removeObserver(unrelated)
        }
        let before = dockField.currentValue(in: defaults)
        try expect((switches[0].state == .on) == (before == .bool(true)), "the switch must render the stored value")
        switches[0].performClick(nil)
        fixture.settle()
        try expect(dockField.currentValue(in: defaults) == .bool(before != .bool(true)),
                   "clicking the Activity Dock switch must write \(WorkspaceSidebarConfig.visibleKey)")
        try expect(counts.exact == 1 && counts.unrelated == 0,
                   "a write must post its own setting event once: exact=\(counts.exact) unrelated=\(counts.unrelated)")
        try expect(fixture.descendants(NSSwitch.self).first?.state == (before == .bool(true) ? .off : .on),
                   "the switch must re-render the new value")
        model.reset(dockField)
        try expect(defaults.object(forKey: WorkspaceSidebarConfig.visibleKey) == nil, "Reset to Default must remove the override")

        // 4. Progressive disclosure: the opacity slider exists only for Custom.
        fixture.select("appearance")
        let opacityAnchor = "field.\(CommandCenterAppearanceConfig.customOpacityKey)"
        try expect(model.renderedAnchors[opacityAnchor] == nil, "custom opacity must be hidden for Frosted")
        let glassField = sections.flatMap(\.fields).first { $0.key == CommandCenterAppearanceConfig.glassinessKey }!
        model.binding(for: glassField).set(.string(CommandCenterGlassiness.custom.rawValue))
        fixture.settle()
        try expect(model.renderedAnchors[opacityAnchor] != nil, "custom opacity must appear for Custom")
        let opacityField = sections.flatMap(\.fields).first { $0.key == CommandCenterAppearanceConfig.customOpacityKey }!
        model.binding(for: opacityField).set(.double(0.70))
        try expect(abs(defaults.double(forKey: CommandCenterAppearanceConfig.customOpacityKey) - 0.70) < 0.0001,
                   "the opacity slider must persist its value")
        model.binding(for: glassField).set(.string(CommandCenterGlassiness.frosted.rawValue))
        fixture.settle()
        try expect(model.renderedAnchors[opacityAnchor] == nil, "custom opacity must hide again after leaving Custom")

        // 5. The model picker: ids verbatim from the live catalogue of the selected
        // CLI; a CLI switch keeps an incompatible saved model as an explicit invalid
        // item; a pick under the new CLI is stored.
        fixture.select("agents")
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready, models: ["anthropic/claude-y", "anthropic/claude-z"]))
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .loggedOut, models: ["openai-codex/gpt-x"]))
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .missing, models: ["google/gemini-z"]))
        defer { AgentModelCatalog.shared.resetForQA() }
        let modelField = sections.flatMap(\.fields).first { $0.key == AgentModelConfig.modelKey }!
        let harnessField = sections.flatMap(\.fields).first { $0.key == AgentBackendConfig.key }!
        model.binding(for: harnessField).set(.string(AgentHarness.claudeCode.rawValue))
        model.binding(for: modelField).set(.string("anthropic/claude-z"))
        try expect(defaults.string(forKey: AgentModelConfig.modelKey) == "anthropic/claude-z", "picking a catalogue model must store it")
        try expect(model.modelPickerItems().map(\.id) == ["anthropic/claude-y", "anthropic/claude-z"],
                   "the picker must offer exactly the catalogue, got \(model.modelPickerItems().map(\.id))")
        model.binding(for: harnessField).set(.string(AgentHarness.codex.rawValue))
        let codexItems = model.modelPickerItems()
        try expect(codexItems.map(\.id) == ["openai-codex/gpt-x", "anthropic/claude-z"] && codexItems.last?.offered == false
                   && defaults.string(forKey: AgentModelConfig.modelKey) == "anthropic/claude-z",
                   "switching to Codex must keep the saved Claude model as an explicit invalid item; items=\(codexItems.map(\.id))")
        model.binding(for: modelField).set(.string("google/gemini-z"))
        try expect(defaults.string(forKey: AgentModelConfig.modelKey) == "anthropic/claude-z",
                   "a model the selected CLI does not offer must not be stored")
        model.binding(for: harnessField).set(.string(AgentHarness.pi.rawValue))
        model.binding(for: modelField).set(.string("google/gemini-z"))
        try expect(defaults.string(forKey: AgentModelConfig.modelKey) == "google/gemini-z",
                   "picking a Pi model after switching CLI must store it")
        // Agent CLI status rows read live readiness.
        try expect(model.readiness(of: .claudeCode) == .ready && model.readiness(of: .codex) == .loggedOut
                   && model.readiness(of: .pi) == .missing, "Agent CLI rows must read live readiness")
        fixture.settle()
        for harness in AgentHarness.allCases {
            try expect(model.renderedAnchors["harness.\(harness.rawValue)"] != nil, "no status row for \(harness.rawValue)")
        }

        // 6. Every status element renders its own switch at its real default, and
        // one element's write reaches AgentStatusElementConfig without moving another.
        for element in AgentStatusElement.presentationOrder {
            try expect(model.renderedAnchors["field.\(element.settingKey)"] != nil, "no row for status element \(element.rawValue)")
        }
        let quota = SettingsField.toggle(key: AgentStatusElement.quotaFiveHour.settingKey, label: "", default: AgentStatusElement.quotaFiveHour.defaultVisible)
        model.binding(for: quota).set(.bool(false))
        try expect(!AgentStatusElementConfig.isVisible(.quotaFiveHour, defaults: defaults), "turning the 5-hour element off must reach AgentStatusElementConfig")
        model.binding(for: quota).set(.bool(true))
        try expect(AgentStatusElementConfig.isVisible(.quotaFiveHour, defaults: defaults)
                   && AgentStatusElementConfig.isVisible(.contextMeter, defaults: defaults)
                   && !AgentStatusElementConfig.isVisible(.cost, defaults: defaults),
                   "status elements must stay independent")

        // Shortcut group titles are words, never a stored tile kind.
        try expect(SettingsModel.words("browserInspector") == "Browser inspector", "tile kinds must read as words")
        for group in model.shortcutGroups {
            try expect(group.title.range(of: "[a-z][A-Z]", options: .regularExpression) == nil,
                       "shortcut group '\(group.title)' shows a stored identifier")
        }

        // 7. The modal renders (grey-screen guard), with artifacts for review.
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let artifactDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(timestamp)/settings-panel", isDirectory: true)
        try? FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        for id in ["general", "agents", "keybindings", "appearance"] {
            fixture.select(id)
            guard let rep = fixture.snapshot() else { throw Failure(message: "could not render \(id)") }
            let metrics = VisualSnapshot.metrics(of: rep)
            try expect(!metrics.isBlank, "\(id) rendered blank: \(metrics.distinctSampledColors) colours at \(metrics.width)x\(metrics.height)")
            try? rep.representation(using: .png, properties: [:])?.write(to: artifactDir.appendingPathComponent("\(id).png"))
        }

        // 8. Teardown: the overlay leaves, and Settings never made a window.
        fixture.modal.close()
        try expect(fixture.modal.overlay == nil && fixture.window.contentView?.subviews.isEmpty == true,
                   "closing must remove the Settings overlay")
        let stray = NSApp.windows.filter {
            !windowsBefore.contains(ObjectIdentifier($0)) && $0 !== fixture.window
                && !String(describing: type(of: $0)).hasPrefix("TUI")
        }
        try expect(stray.isEmpty, "Settings created windows: \(stray.map { "\(type(of: $0))" })")
    }

    // MARK: - `--keybind-edit-check`

    /// Drives the real keybind-edit path: record → persist → re-resolve →
    /// live-apply hook → row re-render. Uses a suite that answers only from
    /// itself, so global-domain overrides cannot leak in.
    static func runKeybindEditCheck() throws {
        let suite = "continuum.keybindEdit.selfcheck.\(UUID().uuidString)"
        guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else {
            throw Failure(message: "could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let baseKeymap = NavKeymap.resolve(defaults: defaults, warn: { _ in })
        let model = SettingsModel(defaults: defaults, navKeymap: baseKeymap, isCompanionEnabled: false)
        var liveKeymap = baseKeymap
        model.onKeymapChanged = { liveKeymap = $0 }
        let fixture = SettingsFixtureWindow(model: model)
        defer { fixture.tearDown() }
        fixture.show(paneID: "keybindings")

        func rendered(_ id: String) throws -> String? {
            fixture.settle()
            try expect(model.renderedAnchors["shortcut.\(id)"] != nil, "the \(id) row is not rendered in Keyboard")
            return model.chordDisplay(entryID: id)
        }
        @discardableResult
        func capture(_ id: String, keyCode: UInt16, modifiers: FocusKeyModifiers, character: String?) -> KeybindEditor.Result? {
            model.beginRecording(id)
            fixture.settle()
            return model.finishCapture(entryID: id, keyCode: keyCode, modifiers: modifiers, character: character)
        }

        // 1. Nav binding rebind: navMode.up "k" -> "i".
        let originalUp = baseKeymap.up
        let initialUp = try rendered("navMode.up")
        try expect(initialUp == originalUp, "nav row did not render the default chord (\(originalUp))")
        guard case .applied? = capture("navMode.up", keyCode: 34, modifiers: [], character: "i") else {
            throw Failure(message: "nav rebind was not applied")
        }
        try expect(model.recordingEntryID == nil, "a successful capture must stop recording")
        try expect(NavKeymap.resolve(defaults: defaults, warn: { _ in }).up == "i", "NavKeymap.resolve did not reflect up='i'")
        try expect(liveKeymap.up == "i", "live keymap hook did not reflect up='i' (was '\(liveKeymap.up)')")
        let reboundUp = try rendered("navMode.up")
        try expect(reboundUp == "i", "nav row did not re-render 'i'")

        // 2. Reset restores the default.
        model.resetShortcut("navMode.up")
        let resetUp = try rendered("navMode.up")
        try expect(NavKeymap.resolve(defaults: defaults, warn: { _ in }).up == originalUp && liveKeymap.up == originalUp
                   && resetUp == originalUp, "reset did not restore nav up to '\(originalUp)'")

        // 3. Leader rebind is live and reflected, then reset.
        let originalLeader = baseKeymap.leader
        guard case .applied? = capture("global.navModeLeader", keyCode: 5, modifiers: [.control], character: "g") else {
            throw Failure(message: "leader rebind was not applied")
        }
        let rebound = NavKeymap.resolve(defaults: defaults, warn: { _ in }).leader
        try expect(rebound == KeyChord(keyCode: 5, modifiers: .control) && liveKeymap.leader == rebound,
                   "leader rebind not reflected/live (got \(rebound.displayString))")
        let leaderShown = try rendered("global.navModeLeader")
        try expect(leaderShown == rebound.displayString, "leader row did not re-render")
        model.resetShortcut("global.navModeLeader")
        try expect(NavKeymap.resolve(defaults: defaults, warn: { _ in }).leader == originalLeader && liveKeymap.leader == originalLeader,
                   "reset did not restore the leader")

        // 4. Tile action rebind: browser find ⌘F -> ⌃⌘F.
        let cmdF = TileChord(keyCode: 3, modifiers: .command)
        let cmdCtrlF = TileChord(keyCode: 3, modifiers: [.command, .control])
        try expect(TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF] == .browserFind,
                   "browser find did not default to ⌘F")
        guard case .applied? = capture("tile.browser.browserFind", keyCode: 3, modifiers: [.command, .control], character: "f") else {
            throw Failure(message: "tile rebind was not applied")
        }
        let browserMap = TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })
        try expect(browserMap[cmdCtrlF] == .browserFind && browserMap[cmdF] == nil, "TileActionCatalog did not reflect ⌃⌘F")
        let findShown = try rendered("tile.browser.browserFind")
        try expect(findShown == cmdCtrlF.displayString, "tile row did not re-render")
        model.resetShortcut("tile.browser.browserFind")
        try expect(TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF] == .browserFind,
                   "reset did not restore ⌘F")

        // 5. An inviolable collision (⌘K) is rejected, shown, and changes nothing.
        let rejected = capture("tile.browser.browserFind", keyCode: 40, modifiers: [.command], character: "k")
        guard case .rejected(.collidesWithInviolableGlobal(.palette))? = rejected else {
            throw Failure(message: "⌘K should be rejected as an inviolable collision, got \(String(describing: rejected))")
        }
        try expect(model.captureMessages["tile.browser.browserFind"] != nil && model.recordingEntryID == "tile.browser.browserFind",
                   "a rejected chord must keep recording and show why")
        try expect(TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF] == .browserFind,
                   "the rejected ⌘K changed browser find")
        model.cancelRecording()
    }
}
