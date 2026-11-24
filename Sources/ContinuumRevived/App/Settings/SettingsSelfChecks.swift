import AppKit
import ContinuumRevivedAgentUI
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

    /// Evidence, not a witness: the cleaned panes (and the states that hide rows),
    /// rendered offscreen in light and dark. Runs only when
    /// `CONTINUUM_SETTINGS_STILLS_DIR` names a directory.
    static func renderStills(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let panes = ["general", "appearance", "sidebar", "agentCharacters", "canvasAndZones", "keybindings"]
        let variants: [(name: String, pane: String, set: [(String, Any)], reveal: String?)] = panes.map { ($0, $0, [], nil) } + [
            ("sidebar-off", "sidebar", [(WorkspaceSidebarConfig.visibleKey, false)], nil),
            ("appearance-outline-off", "appearance", [(FocusBorderConfig.enabledKey, false)], nil),
            ("agentCharacters-on", "agentCharacters", [(AgentCharacterConfig.enabledKey, true), (AgentCharacterConfig.bubbleStyleKey, "orb")], nil),
            ("agentCharacters-off", "agentCharacters", [(AgentCharacterConfig.enabledKey, false)], nil),
            ("canvasAndZones-off", "canvasAndZones", [(CanvasAutoLayoutConfig.enabledKey, false), (FloatingToolbarConfig.visibleKey, false)], nil),
            ("general-no-confirm", "general", [(DeleteConfirmPolicy.userDefaultsKey, "never")], nil),
            ("canvasAndZones-bottom", "canvasAndZones", [], "end"),
            ("appearance-bottom", "appearance", [], "end"),
            ("appearance-outline-off-bottom", "appearance", [(FocusBorderConfig.enabledKey, false)], "end"),
        ]
        for (look, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for variant in variants {
                let suite = "continuum.settingsStills.\(UUID().uuidString)"
                guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else {
                    throw Failure(message: "could not create the isolated defaults suite")
                }
                defer { defaults.removePersistentDomain(forName: suite) }
                for (key, value) in variant.set { defaults.set(value, forKey: key) }
                let model = SettingsModel(sections: SettingsSchema.sections(), defaults: defaults,
                                          navKeymap: .resolve(defaults: defaults, warn: { _ in }))
                let fixture = SettingsFixtureWindow(model: model, size: NSSize(width: 1_100, height: 1_500),
                                                    appearance: NSAppearance(named: appearanceName))
                defer { fixture.tearDown() }
                fixture.show(paneID: variant.pane)
                fixture.settle(0.4)
                if variant.reveal != nil {
                    // Scroll the pane (the tallest scroll view) to its end.
                    let scroller = fixture.descendants(NSScrollView.self)
                        .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
                    if let scroller, let document = scroller.documentView {
                        let y = document.isFlipped ? max(0, document.frame.height - scroller.contentView.bounds.height) : 0
                        document.scroll(NSPoint(x: 0, y: y))
                        scroller.reflectScrolledClipView(scroller.contentView)
                    }
                    fixture.settle(0.4)
                }
                guard let png = fixture.snapshot()?.representation(using: .png, properties: [:]) else {
                    throw Failure(message: "still \(variant.name)-\(look): no render")
                }
                try png.write(to: directory.appendingPathComponent("\(variant.name)-\(look).png"))
            }
        }
    }

    // MARK: - `--settings-panel-check`

    /// Every pane renders a row for every registry entry, rows write through the
    /// model's one write path, conditional rows appear and disappear, the model
    /// picker follows the live catalogue, and the modal renders and tears down
    /// without creating a window.
    static func runPanelCheck() throws {
        if let directory = ProcessInfo.processInfo.environment["CONTINUUM_SETTINGS_STILLS_DIR"] {
            try renderStills(to: URL(fileURLWithPath: directory, isDirectory: true))
        }
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
        let model = SettingsModel(sections: sections, defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }))
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

        // 1. The sidebar is the schema, the iPhone pane always included (decisions
        // pass) — it used to be hidden on prod without a relay identity.
        try expect(model.visiblePanes.map(\.id) == sections.map(\.id)
                   && model.visiblePanes.contains { $0.id == "companion" },
                   "sidebar panes \(model.visiblePanes.map(\.id)) must mirror the schema, iPhone included")

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
        // Sidebar pane draws, and the bound key and its exact event follow.
        fixture.select("sidebar")
        let dockField = SettingsField.toggle(key: WorkspaceSidebarConfig.visibleKey, label: "", default: WorkspaceSidebarConfig.defaultVisible)
        let switches = fixture.descendants(NSSwitch.self)
        // Sidebar draws only the sidebar switch.
        try expect(switches.count == 1, "Sidebar must draw one switch (Show the sidebar), drew \(switches.count)")
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
                   "clicking the sidebar switch must write \(WorkspaceSidebarConfig.visibleKey)")
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

        // 4b. Hide-when-off: each dependant row is gone (not dimmed) while its parent
        // is off, and back when it is on. Stored keys are the existing ones.
        func field(_ key: String) -> SettingsField { sections.flatMap(\.fields).first { $0.key == key }! }
        let hideCases: [(pane: String, key: String, off: SettingsValue, on: SettingsValue, hidden: [String])] = [
            ("sidebar", WorkspaceSidebarConfig.visibleKey, .bool(false), .bool(true),
             [WorkspaceSidebarConfig.widthKey, SidebarLayout.defaultsKey, SidebarActiveIndicatorScope.defaultsKey,
              SidebarActiveIndicatorStyle.defaultsKey, SidebarHeaderBackground.defaultsKey].map { "field.\($0)" }),
            ("appearance", FocusBorderConfig.enabledKey, .bool(false), .bool(true),
             [FocusBorderConfig.colorKey, FocusBorderConfig.gapKey].map { "field.\($0)" }),
            ("agentCharacters", AgentCharacterConfig.enabledKey, .bool(false), .bool(true),
             [AgentCharacterConfig.motionKey, AgentCharacterConfig.sizeKey].map { "field.\($0)" } + ["custom.agentCharacters"]),
            ("agentCharacters", AgentCharacterConfig.bubbleStyleKey, .string("inline"), .string("orb"),
             ["field.\(AgentCharacterConfig.iconScaleKey)"]),
            ("canvasAndZones", CanvasAutoLayoutConfig.enabledKey, .bool(false), .bool(true),
             [CanvasAutoLayoutConfig.activationKey, CanvasAutoLayoutConfig.growthKey].map { "field.\($0)" }),
            ("canvasAndZones", FloatingToolbarConfig.visibleKey, .bool(false), .bool(true),
             ["custom.toolbarButtons", "action.resetToolbarPosition"]),
        ]
        for item in hideCases {
            fixture.select(item.pane)
            model.write(item.on, to: field(item.key)); fixture.settle()
            for anchor in item.hidden {
                try expect(model.renderedAnchors[anchor] != nil, "\(item.pane): \(anchor) must show while \(item.key) is on")
            }
            model.write(item.off, to: field(item.key)); fixture.settle()
            for anchor in item.hidden {
                try expect(model.renderedAnchors[anchor] == nil, "\(item.pane): \(anchor) must be hidden while \(item.key) is off")
            }
            try expect(model.renderedAnchors["field.\(item.key)"] != nil, "\(item.pane): the parent \(item.key) must stay visible")
            model.write(item.on, to: field(item.key)); fixture.settle()
            model.reset(field(item.key))
        }
        // The new controls drive the existing keys and values.
        fixture.select("general")
        let closeKey = DeleteConfirmPolicy.userDefaultsKey
        model.write(.string(DeleteConfirmPolicy.never.rawValue), to: field(closeKey)); fixture.settle()
        try expect(!fixture.descendants(NSSegmentedControl.self).contains { $0.accessibilityIdentifier() == CloseConfirmRow.scopeIdentifier },
                   "the close-prompt scope must be hidden while the prompt is off")
        model.write(.string(DeleteConfirmPolicy.runtimes.rawValue), to: field(closeKey)); fixture.settle()
        guard let scope = fixture.descendants(NSSegmentedControl.self).first(where: { $0.accessibilityIdentifier() == CloseConfirmRow.scopeIdentifier }) else {
            throw Failure(message: "the close-prompt scope must show while the prompt is on")
        }
        scope.selectedSegment = 1
        scope.sendAction(scope.action, to: scope.target)
        try expect(defaults.string(forKey: closeKey) == DeleteConfirmPolicy.always.rawValue, "the scope's second segment must store the old `always`")
        model.reset(field(closeKey))
        guard let channel = fixture.descendants(NSSegmentedControl.self).first(where: { $0.accessibilityIdentifier() == SegmentedChoiceRow.identifier(forKey: "array.updateChannel") }) else {
            throw Failure(message: "General must draw the update channel as a segmented choice")
        }
        try expect((0..<channel.segmentCount).map { channel.label(forSegment: $0) } == ["Stable", "Early access"], "the channel offers Stable / Early access")
        channel.selectedSegment = 1
        channel.sendAction(channel.action, to: channel.target)
        try expect(defaults.string(forKey: "array.updateChannel") == "Tip", "Early access must store the old value Tip")
        model.reset(field("array.updateChannel"))
        // Hold for: a stored 2000 ms still loads and shows, and drawing it rewrites nothing.
        fixture.select("keybindings")
        defaults.set(2000, forKey: NavKeymap.leaderDwellDefaultsKey); fixture.settle()
        try expect(model.value(of: field(NavKeymap.leaderDwellDefaultsKey)) == .double(2000), "a stored Hold for of 2000 ms must still load")
        try expect(defaults.integer(forKey: NavKeymap.leaderDwellDefaultsKey) == 2000, "drawing the slider must not rewrite a stored 2000 ms")
        model.reset(field(NavKeymap.leaderDwellDefaultsKey))
        // Toolbar buttons: one checklist whose picks write each button's own key.
        fixture.select("canvasAndZones")
        guard let checklist = fixture.descendants(ChoiceButton.self).first(where: { $0.accessibilityIdentifier() == ToolbarButtonsRow.identifier }),
              let first = checklist.items.first, let entry = ToolbarButtonsRow.buttons().first(where: { $0.id == first.id }) else {
            throw Failure(message: "Canvas must draw the toolbar buttons checklist")
        }
        try expect(checklist.items.count == ToolbarButtonsRow.buttons().count && checklist.items.allSatisfy { $0.keepsOpen && $0.check != nil },
                   "the checklist must list every toolbar button with a box")
        let wasOn = model.binding(for: entry.field).bool
        checklist.onSelection?(first)
        try expect(defaults.object(forKey: entry.field.key!) as? Bool == !wasOn, "picking a checklist row must write that button's own key")
        model.reset(entry.field)

        // 5. The model picker: ids verbatim from the live catalogue of the selected
        // CLI; a CLI switch keeps an incompatible saved model as an explicit invalid
        // item; a pick under the new CLI is stored.
        fixture.select("agents")
        for key in [AgentManagedModeConfig.enabledKey, AgentManagedModeConfig.showIndicatorKey] {
            let field = sections.flatMap(\.fields).first { $0.key == key }!
            try expect(model.value(of: field) == .bool(true), "Managed settings must default on")
            model.write(.bool(false), to: field)
            try expect(defaults.bool(forKey: key) == false, "Managed settings row failed to persist")
            model.reset(field)
            try expect(model.value(of: field) == .bool(true), "Managed settings reset must restore on")
        }
        // Managed mode leads the Agents pane and its steering rows are gated by it.
        let agentsPane = sections.first { $0.id == "agents" }!
        try expect(agentsPane.groups.first?.id == "agents.managedMode", "Managed mode must be the first group in Agents")
        let steering = agentsPane.groups.flatMap(\.rows).filter { $0.showsWhen?.key == AgentManagedModeConfig.enabledKey }
        try expect(steering.count == 5 && steering.allSatisfy { $0.showsWhen?.key == AgentManagedModeConfig.enabledKey },
                   "the five Managed steering rows must be shown only under the Managed switch")
        // Managed off HIDES its steering rows (not dims them); permissions stay for every agent.
        let managedField = sections.flatMap(\.fields).first { $0.key == AgentManagedModeConfig.enabledKey }!
        let steeringKeys = steering.compactMap(\.field.key)
        let permissionKey = WorkspaceToolsConfig.permissionKey
        model.write(.bool(false), to: managedField)
        fixture.settle()
        for key in steeringKeys {
            try expect(model.renderedAnchors["field.\(key)"] == nil, "\(key) must be hidden while Managed mode is off")
        }
        try expect(model.renderedAnchors["field.\(permissionKey)"] != nil, "Agent permissions must stay while Managed mode is off")
        try expect(SettingsRegistry.entries(sections: sections, defaults: defaults).allSatisfy { entry in
                       guard let key = entry.field?.key else { return true }
                       return !steeringKeys.contains(key)
                   }, "search must not offer hidden Managed rows")
        model.write(.bool(true), to: managedField)
        fixture.settle()
        for key in steeringKeys {
            try expect(model.renderedAnchors["field.\(key)"] != nil, "\(key) must show while Managed mode is on")
        }
        // New agents: Agent CLI, Model and Reasoning effort are one control, the
        // shared ChoiceButton, with one title font and one trailing edge.
        fixture.settle()
        let newAgentIDs = ["settings.agentCLI", "settings.agentModel", "settings.agentEffort"]
        let newAgentButtons = newAgentIDs.compactMap { id in
            fixture.descendants(ChoiceButton.self).first { $0.accessibilityIdentifier() == id }
        }
        try expect(newAgentButtons.count == 3,
                   "Agent CLI, Model and Reasoning effort must all be ChoiceButtons; found \(newAgentButtons.count) of 3")
        let titleFonts = newAgentButtons.map { $0.qaTitleFont }
        try expect(titleFonts.allSatisfy { $0 != nil && $0 == titleFonts[0] }
                   && titleFonts[0]?.pointSize == 13,
                   "the New agents buttons must share one 13 pt title font, got \(titleFonts.map { $0.map { "\($0.fontName) \($0.pointSize)" } ?? "nil" })")
        let trailingEdges = newAgentButtons.map { $0.convert($0.bounds, to: nil).maxX }
        try expect(trailingEdges.allSatisfy { abs($0 - trailingEdges[0]) < 0.5 },
                   "the New agents buttons must share one trailing x, got \(trailingEdges)")
        // The rules file exists only under its switch.
        let personalField = sections.flatMap(\.fields).first { $0.key == PersonalRulesConfig.enabledKey }!
        let rulesPathKey = "field.\(PersonalRulesConfig.pathKey)"
        model.write(.bool(false), to: personalField); fixture.settle()
        try expect(model.renderedAnchors[rulesPathKey] == nil, "the rules file must be hidden while my rules is off")
        model.write(.bool(true), to: personalField); fixture.settle()
        try expect(model.renderedAnchors[rulesPathKey] != nil, "the rules file must show while my rules is on")
        model.reset(personalField); fixture.settle()
        // Optional numbers: switch off is the stored 0 / "Off" the resolvers already read.
        func optional(_ key: String) -> (SettingsRow, SettingsOptionalNumber) {
            let row = sections.flatMap(\.rows).first { $0.field.key == key }!
            return (row, row.optionalNumber!)
        }
        let (limitRow, limit) = optional(AgentSpawnLimitConfig.maximumActiveChildrenKey)
        try expect(limit.isOn(.double(0)) == false && limit.isOn(.double(6)) && AgentSpawnLimitConfig.maximumActiveChildren(defaults: defaults) == nil,
                   "helper limit: 0 must read as the switch off, and the default as no limit")
        model.write(limit.onValue, to: limitRow.field)
        try expect(AgentSpawnLimitConfig.maximumActiveChildren(defaults: defaults) == 4, "helper limit: the switch on must write 4")
        model.write(limit.storedValue(forNumber: 9), to: limitRow.field)
        try expect(AgentSpawnLimitConfig.maximumActiveChildren(defaults: defaults) == 9, "helper limit: the slider must write the number")
        model.write(limit.off!, to: limitRow.field)
        try expect(defaults.integer(forKey: AgentSpawnLimitConfig.maximumActiveChildrenKey) == 0
                   && AgentSpawnLimitConfig.maximumActiveChildren(defaults: defaults) == nil, "helper limit: the switch off must store 0")
        model.reset(limitRow.field)
        let (settleRow, settle) = optional(AgentAutoSettleConfig.afterDaysKey)
        model.write(settle.off!, to: settleRow.field)
        try expect(settle.isOn(model.value(of: settleRow.field)!) == false && AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == nil,
                   "archive: the switch off must store Off")
        model.write(settle.onValue, to: settleRow.field)
        try expect(AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == AgentAutoSettleConfig.defaultDays, "archive: the switch on must restore the default days")
        model.write(settle.storedValue(forNumber: 13), to: settleRow.field)
        try expect(AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == 14, "archive: the slider must snap to a stored day count")
        model.reset(settleRow.field)
        let (fontRow, font) = optional(TerminalDisplayConfig.fontSizeKey)
        model.write(font.off!, to: fontRow.field)
        try expect(font.isOn(model.value(of: fontRow.field)!) == false && TerminalDisplayConfig.fontSize(defaults: defaults) == nil,
                   "terminal font: the switch off must store 0, which inherits Ghostty's size")
        model.write(font.onValue, to: fontRow.field)
        try expect(TerminalDisplayConfig.fontSize(defaults: defaults) == TerminalDisplayConfig.defaultFontSize, "terminal font: the switch on must write the default size")
        model.reset(fontRow.field)
        let (idleRow, idle) = optional(AgentIdleSessionConfig.minutesKey)
        try expect(idle.off == nil, "idle sessions have no off: a slider only")
        model.write(idle.storedValue(forNumber: 45), to: idleRow.field)
        try expect(AgentIdleSessionConfig.timeout(defaults: defaults) == 45 * 60, "idle sessions: the slider must write minutes")
        model.reset(idleRow.field)
        // Stuck alerts are the same bool, drawn Patient / Quick.
        let stall = steering.first { $0.field.key == AgentManagedModeConfig.stallAlertsKey }!
        try expect(stall.toggleTitles == SettingsToggleTitles(off: "Patient", on: "Quick"), "stuck alerts must be a Patient / Quick choice")
        model.write(.bool(true), to: stall.field)
        try expect(AgentManagedModeConfig.stallAlerts(defaults: defaults), "Quick must store true")
        model.reset(stall.field)
        // Terminal: dependent rows hide with their switch.
        fixture.select("terminal")
        let keepField = sections.flatMap(\.fields).first { $0.key == TmuxPersistenceConfig.enabledKey }!
        let scrollField = sections.flatMap(\.fields).first { $0.key == SessionResumeConfig.scrollbackEnabledKey }!
        let shareAnchor = "field.\(TmuxPersistenceConfig.ambientPerWorkspaceKey)"
        let linesAnchor = "field.\(SessionResumeConfig.scrollbackMaxLinesKey)"
        model.write(.bool(true), to: keepField); model.write(.bool(true), to: scrollField); fixture.settle()
        try expect(model.renderedAnchors[shareAnchor] != nil && model.renderedAnchors[linesAnchor] != nil, "terminal dependents must show while their switches are on")
        model.write(.bool(false), to: keepField); model.write(.bool(false), to: scrollField); fixture.settle()
        try expect(model.renderedAnchors[shareAnchor] == nil, "Share one session must hide when keep-running is off")
        try expect(model.renderedAnchors[linesAnchor] == nil, "Lines to restore must hide when scrollback is off")
        model.reset(keepField); model.reset(scrollField); fixture.select("agents"); fixture.settle()
        // Two compaction rows (mode and size), no old on/off or percent rows, and the rows drive the policy.
        let compactionKeys = sections.flatMap(\.fields).compactMap(\.key).filter { $0.hasPrefix("continuum.agentContext.") }
        try expect(compactionKeys == [AgentContextAutoCompactionPolicy.modeKey, AgentContextAutoCompactionPolicy.compactAtKey],
                   "exactly the mode and size compaction rows must exist in Settings, found \(compactionKeys)")
        let modeField = sections.flatMap(\.fields).first { $0.key == AgentContextAutoCompactionPolicy.modeKey }!
        let compactField = sections.flatMap(\.fields).first { $0.key == AgentContextAutoCompactionPolicy.compactAtKey }!
        try expect(AgentContextAutoCompactionPolicy.mode(defaults: defaults) == .ask, "compaction must default to Ask me")
        model.write(.string("automatic"), to: modeField)
        model.write(.string("150000"), to: compactField)
        try expect(AgentContextAutoCompactionPolicy.effectiveMode(isHelper: false, defaults: defaults) == .automatic
                   && AgentContextAutoCompactionPolicy.limitTokens(defaults: defaults) == 150_000,
                   "the Settings rows must drive the real compaction policy")
        // The switch remembers the mode it leaves: Automatically, off, on is Automatically again.
        model.write(.string("automatic"), to: modeField)
        model.write(.string(AgentContextAutoCompactionPolicy.modeAfterSwitch(on: false, defaults: defaults).rawValue), to: modeField)
        try expect(AgentContextAutoCompactionPolicy.mode(defaults: defaults) == .never, "switching compaction off must store never")
        model.write(.string(AgentContextAutoCompactionPolicy.modeAfterSwitch(on: true, defaults: defaults).rawValue), to: modeField)
        try expect(AgentContextAutoCompactionPolicy.mode(defaults: defaults) == .automatic, "switching compaction back on must restore Automatically")
        // Off then on again with Ask me restores Ask me, and a fresh install turns on to Ask me.
        model.write(.string("ask"), to: modeField)
        model.write(.string(AgentContextAutoCompactionPolicy.modeAfterSwitch(on: false, defaults: defaults).rawValue), to: modeField)
        model.write(.string(AgentContextAutoCompactionPolicy.modeAfterSwitch(on: true, defaults: defaults).rawValue), to: modeField)
        try expect(AgentContextAutoCompactionPolicy.mode(defaults: defaults) == .ask, "switching back on must restore Ask me")
        defaults.removeObject(forKey: AgentContextAutoCompactionPolicy.lastOnModeKey)
        model.write(.string("never"), to: modeField)
        try expect(AgentContextAutoCompactionPolicy.modeAfterSwitch(on: true, defaults: defaults) == .ask, "with nothing remembered the switch turns on to Ask me")
        model.reset(modeField); model.reset(compactField)
        // A value saved under the old two settings carries over when Settings opens.
        let legacySuite = "array.settings-compaction-legacy.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(80, forKey: AgentContextAutoCompactionPolicy.percentKey)
        legacyDefaults.set(false, forKey: AgentContextAutoCompactionPolicy.enabledKey)
        let legacyModel = SettingsModel(sections: sections, defaults: legacyDefaults, navKeymap: .resolve(defaults: legacyDefaults, warn: { _ in }))
        try expect(legacyModel.value(of: compactField) == .string("150000"), "an old 80% setting must show as 150k tokens")
        try expect(legacyModel.value(of: modeField) == .string("never"), "an old Off must show as Never")
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

        // 6b. A switch's dependants are HIDDEN, not dimmed: with sounds off only the
        // switch is drawn (and search stops pointing at the rest); the iPhone
        // notification switches wait for a paired phone; each recording / inspector
        // switch has exactly one home.
        fixture.select("activityAndNotifications")
        fixture.settle()
        let soundDependants = ["sounds.volume", "sounds.kind.completed", "sounds.kind.failed", "sounds.kind.actionRequired",
                               "sounds.kind.gitPushSucceeded", "sounds.kind.gitMergeSucceeded", "sounds.characters", "sounds.library"]
        try expect(model.renderedAnchors["sounds.master"] != nil && soundDependants.allSatisfy { model.renderedAnchors[$0] != nil },
                   "with sounds on, the volume, every event row, icon sounds and custom sounds must be drawn")
        model.soundsEnabled = false
        fixture.settle()
        try expect(model.renderedAnchors["sounds.master"] != nil && soundDependants.allSatisfy { model.renderedAnchors[$0] == nil },
                   "with sounds off, everything under the switch must be hidden, not dimmed — still drawn: \(soundDependants.filter { model.renderedAnchors[$0] != nil })")
        try expect(!model.entries().contains { $0.anchor.map(soundDependants.contains) == true },
                   "search must not list sound rows that are hidden")
        model.soundsEnabled = true
        fixture.settle()

        // 6c. Mac alerts: a calm row while banners are off or never decided,
        // gone once allowed. It re-reads when Array becomes active again (back
        // from System Settings), with no relaunch.
        var bannerStatus: MacNotificationAuthorization = .denied
        var openedSettings: [URL] = []
        var requestedAuthorization = 0
        MacNotificationPermission.qaStatus = { bannerStatus }
        MacNotificationPermission.qaOpenURL = { openedSettings.append($0) }
        MacNotificationPermission.qaRequest = { requestedAuthorization += 1 }
        defer {
            MacNotificationPermission.qaStatus = nil
            MacNotificationPermission.qaOpenURL = nil
            MacNotificationPermission.qaRequest = nil
        }
        func becomeActive() {
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            fixture.settle()
        }
        let bannerRow = SettingsNotificationPermissionSection.textID
        becomeActive()
        try expect(model.renderedTexts[bannerRow] == "denied", "with banners denied, Notifications & Sounds must show the Mac alerts row")
        model.openNotificationSettings()
        try expect(openedSettings.count == 1
                   && openedSettings[0].absoluteString.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="),
                   "Open Notification Settings must deep-link to Notifications › Array, got \(openedSettings)")
        try expect(requestedAuthorization == 0, "a denied row must not ask again: macOS never re-prompts")
        let settingsHandler = NSWorkspace.shared.urlForApplication(toOpen: MacNotificationPermission.settingsURL)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        try expect(settingsHandler == "com.apple.systempreferences",
                   "the deep link must open System Settings, resolved to \(settingsHandler ?? "nothing")")
        bannerStatus = .allowed
        becomeActive()
        try expect(model.renderedTexts[bannerRow] == nil, "once banners are allowed the row must go on its own")
        bannerStatus = .notDetermined
        becomeActive()
        try expect(model.renderedTexts[bannerRow] == "notDetermined", "before macOS has asked, the row must offer to allow banners")
        model.requestNotifications()
        try expect(requestedAuthorization == 1 && openedSettings.count == 1, "not set up must ask macOS, not open an empty pane")
        bannerStatus = .denied
        fixture.select("general")
        fixture.settle()
        try expect(model.renderedTexts[bannerRow] == nil, "the Mac alerts row belongs only to Notifications & Sounds")
        MacNotificationPermission.qaStatus = nil
        becomeActive()
        try expect(model.macNotifications == .unavailable, "a bare binary must never read the real notification center")

        fixture.select("companion")
        fixture.settle()
        let phoneAnchors = sections.first { $0.id == "companion" }!.fields.compactMap(\.key).map { "field.\($0)" }
        try expect(phoneAnchors.allSatisfy { model.renderedAnchors[$0] == nil },
                   "before a phone is paired, no notification switch may be drawn")
        try expect(!model.entries().contains { $0.anchor.map(phoneAnchors.contains) == true },
                   "search must not list phone notification switches before a phone is paired")
        model.pairedPhoneCount = 1
        fixture.settle()
        try expect(phoneAnchors.allSatisfy { model.renderedAnchors[$0] != nil },
                   "with a phone paired, every notification switch must be drawn")
        model.pairedPhoneCount = 0
        fixture.settle()
        for (key, pane) in [(AgentTokenTelemetryConfig.enabledKey, "usage"), (BrowserWebInspectorConfig.userDefaultsKey, "advanced")] {
            fixture.select(pane)
            fixture.settle()
            try expect(model.renderedAnchors["field.\(key)"] != nil, "\(pane) must draw the \(key) switch")
            let homes = model.entries().filter { $0.anchor == "field.\(key)" }.map(\.paneID)
            try expect(homes == [pane], "\(key) must have one search home, \(pane) — found \(homes)")
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

        try SettingsPaneStills.renderIfRequested()

        // 8. Teardown: the overlay leaves, and Settings never made a window.
        fixture.modal.close()
        try expect(fixture.modal.overlay == nil && fixture.window.contentView?.subviews.isEmpty == true,
                   "closing must remove the Settings overlay")
        let stray = NSApp.windows.filter {
            !windowsBefore.contains(ObjectIdentifier($0)) && $0 !== fixture.window
                && !String(describing: type(of: $0)).hasPrefix("TUI")
        }
        try expect(stray.isEmpty, "Settings created windows: \(stray.map { "\(type(of: $0))" })")
        if let dir = ProcessInfo.processInfo.environment["CONTINUUM_SETTINGS_STILLS_DIR"] {
            try renderNotificationPaneStills(to: URL(fileURLWithPath: dir))
        }
    }

    /// Offscreen stills of the notifications-to-advanced panes in both
    /// appearances, for review. Only when `CONTINUUM_SETTINGS_STILLS_DIR` is set.
    private static func renderNotificationPaneStills(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(name: String, pane: String, paired: Int, soundsOff: Bool)] = [
            ("sounds-on", "activityAndNotifications", 0, false), ("sounds-off", "activityAndNotifications", 0, true),
            ("iphone-not-paired", "companion", 0, false), ("iphone-paired", "companion", 1, false),
            ("keyboard", "keybindings", 0, false), ("usage", "usage", 0, false), ("advanced", "advanced", 0, false),
        ]
        for (look, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for state in states {
                let suite = "continuum.settingsStills.\(UUID().uuidString)"
                guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else {
                    throw Failure(message: "could not create the isolated defaults suite")
                }
                defer { defaults.removePersistentDomain(forName: suite) }
                if state.soundsOff { defaults.set(false, forKey: AgentSoundConfig.masterEnabledKey) }
                let model = SettingsModel(sections: SettingsSchema.sections(), defaults: defaults,
                                          navKeymap: .resolve(defaults: defaults, warn: { _ in }))
                model.pairedPhoneCount = state.paired
                let fixture = SettingsFixtureWindow(model: model, appearance: NSAppearance(named: appearanceName))
                defer { fixture.tearDown() }
                fixture.show(paneID: state.pane)
                fixture.settle(0.5)
                guard let rep = fixture.snapshot(),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw Failure(message: "could not render \(state.name) (\(look))")
                }
                try png.write(to: directory.appendingPathComponent("\(state.name)-\(look).png"))
            }
        }
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
        let model = SettingsModel(defaults: defaults, navKeymap: baseKeymap)
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
