import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

// Plan: .plans/110-agent-characters/README.md, slice 6.
//
// `--character-settings-check`: importing a folder copies one theme file into the
// (temp) app-support folder and lists its characters; a bad file shows its
// problems and imports nothing; discovery finds theme files through a fixture
// home's settings.json pluginConfigs and installed_plugins.json, never the real
// ~/.claude; the real Settings rows render in both appearances with the preview
// grid animating, and still under Reduce Motion.
@MainActor
enum CharacterSettingsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-character-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let imports = root.appendingPathComponent("support/characters", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../ContinuumRevivedCoreChecks/Fixtures/agent-character-themes").standardized
        guard fm.fileExists(atPath: corpus.appendingPathComponent("good-pond.theme.json").path) else {
            throw Failure(description: "fixture corpus missing at \(corpus.path)")
        }
        // Fixtures: a themes folder named by a plugin's settings, and a plugin with a theme at its root.
        let themesDir = root.appendingPathComponent("themes", isDirectory: true)
        let plugin = root.appendingPathComponent("plugins/other-plugin", isDirectory: true)
        for folder in [themesDir, plugin, home.appendingPathComponent(".claude/plugins", isDirectory: true), imports] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try fm.copyItem(at: corpus.appendingPathComponent("good-pond.theme.json"), to: themesDir.appendingPathComponent("pond.theme.json"))
        try fm.copyItem(at: corpus.appendingPathComponent("good-minimal.theme.json"),
                        to: plugin.appendingPathComponent(AgentCharacterImports.folderThemeName))
        try Data(#"{"pluginConfigs": {"characters@market": {"options": {"themesDir": "\#(themesDir.path)"}}}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        try Data(#"{"version": 2, "plugins": {"other@market": [{"installPath": "\#(plugin.path)"}]}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))

        let suite = "ArrayCharacterSettingsChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.importsDirectory = imports
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        AgentCharacterSettingsModel.homeOverrideForChecks = home
        defer { AgentCharacterSettingsModel.homeOverrideForChecks = nil }

        let model = AgentCharacterSettingsModel(defaults: defaults, importsDirectory: imports, home: home)
        try expect(model.found.map(\.url.lastPathComponent).sorted() == [AgentCharacterImports.folderThemeName, "pond.theme.json"].sorted(),
                   "discovery finds the pluginConfigs themes folder and the installed plugin's theme: \(model.found)")
        try expect(fm.contentsOfDirectory(atPath: imports.path).isEmpty, "discovery imports nothing by itself")
        try expect(model.found.map(\.title).allSatisfy { !$0.lowercased().contains("duckherd") },
                   "the list never shows the format's third-party file name")

        // A folder import copies exactly the theme file.
        model.importTheme(from: themesDir)
        let copied = try fm.contentsOfDirectory(atPath: imports.appendingPathComponent("pond").path)
        try expect(copied == [AgentCharacterImports.fileName], "one file copied into app support: \(copied)")
        try expect(model.imported.map(\.id) == ["pond"] && model.imported[0].characters.count == 2,
                   "the imported set lists its characters")
        try expect(model.selectedID == "pond" && defaults.string(forKey: AgentCharacterConfig.themeKey) == "pond",
                   "importing selects the new set")
        try expect(controller.theme?.id == "pond", "the app now draws the imported set (\(controller.theme?.id ?? "nil"))")
        try expect(model.choiceItems.map(\.id) == [AgentCharacterBundled.themeID, "pond", AgentCharacterSettingsModel.importItemID],
                   "the picker offers the built-in set, the import, and Import…")

        // A bad file: its problems, word for word, and nothing new on disk.
        let before = try fm.contentsOfDirectory(atPath: imports.path).sorted()
        model.importTheme(from: corpus.appendingPathComponent("bad-short-row.theme.json"))
        try expect(model.problems == ["helpers[0].loops.run[0]: rows are 20 wide"], "the problem is shown: \(model.problems)")
        try expect(try fm.contentsOfDirectory(atPath: imports.path).sorted() == before, "a bad file imports nothing")
        try expect(controller.theme?.id == "pond", "a bad import changes nothing")

        // Back to the built-in set for the render.
        model.select(id: AgentCharacterBundled.themeID)
        try expect(controller.theme?.id == AgentCharacterBundled.themeID, "choosing the built-in set switches back")

        // The real Settings rows of this group, in both appearances.
        let settings = SettingsModel(defaults: defaults, navKeymap: .default)
        guard let group = settings.sections.first(where: { $0.id == "appearance" })?.groups
            .first(where: { $0.id == "appearance.agentCharacters" }) else {
            throw Failure(description: "Settings › Appearance has no Agent characters group")
        }
        let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        var grids = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: Form {
                Section(group.title ?? "") {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        SettingsFieldRow(model: settings, row: row)
                    }
                }
            }.formStyle(.grouped))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 980)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let grid = find(AgentCharacterPreviewGridView.self, in: host) else {
                throw Failure(description: "\(appearance.rawValue): the preview grid did not render")
            }
            try expect(grid.sprites.count == 8 * AgentCharacterPreviewGridView.columns.count, "8 characters x every state")
            try expect(grid.sprites.filter(\.isAnimating).count == 8 * 7, "the moving states animate in the preview")
            try SidebarCharacterChecks.capture(window, to: out.appendingPathComponent(
                "settings-\(appearance == .aqua ? "light" : "dark").png"))
            controller.reduceMotion = { true }
            grid.apply()
            try expect(grid.sprites.allSatisfy { !$0.isAnimating }, "Reduce Motion: the preview is still")
            controller.reduceMotion = { false }
            grids += 1
        }
        return "Character settings checks passed: discovery through a fixture home (2 files, nothing read), folder import copies one file and selects it, a bad file shows its problems and imports nothing, \(grids) appearances rendered with the 8 x 9 preview grid animating and still under Reduce Motion"
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }
}
