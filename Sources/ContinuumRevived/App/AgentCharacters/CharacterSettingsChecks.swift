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
        try expect(model.cards.map(\.id) == AgentCharacterBundled.builtInIDs + ["pond"],
                   "the picker offers the built-in sets, then the import: \(model.cards.map(\.id))")
        try expect(model.cards.map(\.detail) == ["8 characters", "12 characters", "12 characters", "14 characters",
                                                 "12 characters", "2 characters · imported"],
                   "each card says how many characters, with no set parsed: \(model.cards.map(\.detail))")

        // A bad file: its problems, word for word, and nothing new on disk.
        let before = try fm.contentsOfDirectory(atPath: imports.path).sorted()
        model.importTheme(from: corpus.appendingPathComponent("bad-short-row.theme.json"))
        try expect(model.problems == ["helpers[0].loops.run[0]: rows are 20 wide"], "the problem is shown: \(model.problems)")
        try expect(try fm.contentsOfDirectory(atPath: imports.path).sorted() == before, "a bad file imports nothing")
        try expect(controller.theme?.id == "pond", "a bad import changes nothing")

        // The real page, in the real modal, on the real event path.
        var stills = 0
        var moving = 0
        let parsesBefore = AgentCharacterBundled.parseCount
        let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let label = appearance == .aqua ? "light" : "dark"
            let settings = SettingsModel(defaults: defaults, navKeymap: .default)
            let fixture = SettingsFixtureWindow(model: settings, size: NSSize(width: 1_100, height: 1_100),
                                                appearance: NSAppearance(named: appearance))
            defer { fixture.tearDown() }
            fixture.show(paneID: "agentCharacters")
            let arts = try awaitCards(count: 6, in: fixture)
            let parses = AgentCharacterBundled.parseCount
            try expect(parses == parsesBefore, "\(label): opening the page and drawing every card parsed a whole pack: \(parsesBefore) -> \(parses)")
            for (id, art) in arts {
                try expect(art.sprites.count == 3 && art.sprites.allSatisfy { $0.contents != nil },
                           "\(label) \(id): the card draws a lead and two helpers, got \(art.sprites.count)")
                try expect(art.sprites.allSatisfy(\.isAnimating), "\(label) \(id): a card in view moves")
            }
            let pane = try FoundCharacterThemesChecks.pane(fixture)
            try SidebarCharacterChecks.capture(fixture.window, to: out.appendingPathComponent("page-\(label).png"))
            stills += 1

            // Scrolled out of view, a card holds still and costs the render server
            // nothing; back in view, it moves again.
            let clip = pane.contentView
            let top = clip.bounds.origin
            let end = (pane.documentView?.bounds.height ?? 0) - clip.bounds.height
            try expect(end > 0, "\(label): the page scrolls")
            clip.scroll(to: NSPoint(x: top.x, y: end))
            pane.reflectScrolledClipView(clip)
            fixture.settle(0.3)
            let hidden = fixture.descendants(AgentCharacterCardArtView.self).filter { $0.visibleRect.isEmpty }
            try expect(!hidden.isEmpty, "\(label): scrolling to the end takes cards out of view")
            try expect(hidden.flatMap(\.sprites).allSatisfy { !$0.isAnimating },
                       "\(label): a card out of view must not animate")
            guard let grid = fixture.descendants(AgentCharacterPreviewGridView.self).first else {
                throw Failure(description: "\(label): the every-state grid did not render")
            }
            try awaitAnimating(grid, "\(label): the every-state grid in view moves", in: fixture)
            try expect(grid.sprites.count == 2 * AgentCharacterPreviewGridView.columns.count, "\(label): the set's characters x every state")
            try SidebarCharacterChecks.capture(fixture.window, to: out.appendingPathComponent("page-end-\(label).png"))
            clip.scroll(to: top)
            pane.reflectScrolledClipView(clip)
            fixture.settle(0.3)
            try expect(grid.sprites.allSatisfy { !$0.isAnimating }, "\(label): the grid out of view holds still")
            try expect(arts.values.flatMap(\.sprites).allSatisfy(\.isAnimating), "\(label): cards moved back into view move again")
            moving += 1

            // Reduce Motion stills what is on screen, and the Motion row does too.
            controller.reduceMotion = { true }
            controller.reload(force: true)
            fixture.settle(0.1)
            try expect(arts.values.flatMap(\.sprites).allSatisfy { !$0.isAnimating }, "\(label): Reduce Motion stills the cards")
            controller.reduceMotion = { false }
            controller.reload(force: true)
            fixture.settle(0.1)
            try expect(arts.values.flatMap(\.sprites).allSatisfy(\.isAnimating), "\(label): cards move again after Reduce Motion")
        }

        // Clicking each pack's card: the mark moves, the app draws the set, it
        // speaks from its folder, and the parse never lands on the main thread.
        let settings = SettingsModel(defaults: defaults, navKeymap: .default)
        let fixture = SettingsFixtureWindow(model: settings, size: NSSize(width: 1_100, height: 1_100),
                                            appearance: NSAppearance(named: .darkAqua))
        defer { fixture.tearDown() }
        fixture.show(paneID: "agentCharacters")
        _ = try awaitCards(count: 6, in: fixture)
        let page = settings.agentCharacters
        for id in AgentCharacterBundled.packIDs {
            try FoundCharacterThemesChecks.click("ArrayAgentCharacterSet.\(id)", in: fixture)
            try expect(page.selectedID == id, "clicking the \(id) card selects it at once")
            try waitUntil(fixture, "choosing \(id) draws it (\(controller.theme?.id ?? "nil"))") { controller.theme?.id == id }
            try waitUntil(fixture, "the preview shows \(id)") { page.previewTheme?.id == id }
            try expect(defaults.string(forKey: AgentCharacterConfig.themeKey) == id, "\(id) is saved")
            let speaker = AgentCharacterSoundCenter.productionSpeaker(records: { _ in nil })(UUID())
            try expect(speaker?.themeFolder != nil && speaker?.themeFolder == AgentCharacterBundled.packFolderURL(id: id),
                       "\(id) speaks from its folder in the app: \(String(describing: speaker))")
            try expect(speaker?.characterName.map { name in controller.theme?.characters.contains { $0.name == name } == true } == true,
                       "\(id): the speaker is one of its characters")
            let theme = try require(AgentCharacterBundled.cachedTheme(id: id), "\(id) is parsed")
            try waitUntil(fixture, "\(id): its whole grid renders") {
                fixture.descendants(AgentCharacterPreviewGridView.self).first?.sprites.count
                    == theme.characters.count * AgentCharacterPreviewGridView.columns.count
            }
        }
        let parses = AgentCharacterBundled.parseCount
        try expect(parses.onMain == parsesBefore.onMain && parses.all == parsesBefore.all + AgentCharacterBundled.packIDs.count,
                   "each pack parsed once, off the main thread: \(parsesBefore) -> \(parses)")
        page.reload()
        fixture.settle(0.3)
        try expect(page.selectedID == AgentCharacterBundled.packIDs.last, "a selected built-in pack survives a reload")
        try SidebarCharacterChecks.capture(fixture.window, to: out.appendingPathComponent("page-pack-selected-dark.png"))

        // Back to the built-in set, which is parsed, so it takes effect at once.
        page.select(id: AgentCharacterBundled.themeID)
        try expect(controller.theme?.id == AgentCharacterBundled.themeID, "choosing the built-in set switches back")
        return "Character settings checks passed: discovery through a fixture home (2 files, nothing read), folder import copies one file and selects it, a bad file shows its problems and imports nothing, the page opened in \(stills) appearances with 6 cards drawn and no whole pack parsed, cards and grid move only in view and still under Reduce Motion in \(moving) appearances, \(AgentCharacterBundled.packIDs.count) pack cards clicked: drawn, saved, speaking from their folders, each parsed once off the main thread"
    }

    /// Every card's art, by set id, once `count` have their pictures.
    private static func awaitCards(count: Int, in fixture: SettingsFixtureWindow) throws -> [String: AgentCharacterCardArtView] {
        var arts: [String: AgentCharacterCardArtView] = [:]
        try waitUntil(fixture, "\(count) cards draw") {
            let views = fixture.descendants(AgentCharacterCardArtView.self).filter { $0.art != nil }
            arts = Dictionary(views.map { ($0.accessibilityIdentifier(), $0) }, uniquingKeysWith: { first, _ in first })
            return arts.count == count
        }
        return arts
    }

    private static func awaitAnimating(_ grid: AgentCharacterPreviewGridView, _ what: String, in fixture: SettingsFixtureWindow) throws {
        try waitUntil(fixture, what) { grid.sprites.filter(\.isAnimating).count == grid.sprites.count / AgentCharacterPreviewGridView.columns.count * 7 }
    }

    private static func waitUntil(_ fixture: SettingsFixtureWindow, _ what: @autoclosure () -> String, until done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !done() {
            guard Date() < deadline else { throw Failure(description: what()) }
            fixture.settle(0.05)
        }
    }

    private static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Failure(description: what) }
        return value
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }
}
