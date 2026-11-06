import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

// Plan 110 › found themes: Settings › Agent characters, "Found on
// this Mac".
//
// `--found-character-themes-check`: a fixture home's plugins point at seven theme
// files: two distinct titled sets, a byte-identical copy of one under another
// plugin, a set already imported byte for byte, a set whose id is imported with
// other content, and an invalid file. Through the REAL Settings rows, rendered
// offscreen in light and dark, each row must carry its title, its characters and
// plugin, its state (Import / Imported disabled / Update / none) and either its
// own at-rest preview or the validator's reason; the copy must not add a row; a
// click on Imported must do nothing, and clicks on Import and Update must turn
// both rows into Imported. Rows are read from the real Settings modal: the words
// each element rendered (`SettingsModel.renderedTexts`), the preview NSViews, and
// clicks through `NSWindow.sendEvent`. Stills go to `qa-runs/found-themes/` (or
// `CONTINUUM_FOUND_THEMES_STILLS_DIR`).
@MainActor
enum FoundCharacterThemesChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    /// One rendered row, as the view shows it.
    struct Row: Equatable {
        var title: String?
        var detail: String?
        var action: String?
        var problem: String?
        var previewSprites: Int?
    }

    static func run() throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-found-themes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let imports = root.appendingPathComponent("support/characters", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let shelf = root.appendingPathComponent("shelf", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../ContinuumRevivedCoreChecks/Fixtures/agent-character-themes").standardized
        let pondText = try String(contentsOf: corpus.appendingPathComponent("good-pond.theme.json"), encoding: .utf8)
        let marker = #""id":"pond","title":"Theme pond""#
        try expect(pondText.contains(marker), "good-pond fixture changed shape")
        func pond(id: String, title: String) -> Data { Data(pondText.replacingOccurrences(of: marker, with: #""id":"\#(id)","title":"\#(title)""#).utf8) }
        let broken = try Data(contentsOf: corpus.appendingPathComponent("bad-short-row.theme.json"))

        for folder in [imports, shelf, home.appendingPathComponent(".claude/plugins", isDirectory: true)] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // A themes folder a plugin's settings name: imported, invalid, and an update.
        try pond(id: "already", title: "Already Here").write(to: shelf.appendingPathComponent("already.theme.json"))
        try broken.write(to: shelf.appendingPathComponent("broken.theme.json"))
        try pond(id: "stale", title: "Stale v2").write(to: shelf.appendingPathComponent("stale.theme.json"))
        // Installed plugins with a theme at their root: two sets and a byte-identical copy.
        func plugin(_ name: String, manifest: String?, theme: Data) throws -> URL {
            let folder = plugins.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
            if let manifest { try Data(manifest.utf8).write(to: folder.appendingPathComponent(".claude-plugin/plugin.json")) }
            try theme.write(to: folder.appendingPathComponent(AgentCharacterImports.folderThemeName))
            return folder
        }
        let garden = pond(id: "garden", title: "Garden Party")
        let pals = try plugin("pond-pals", manifest: #"{"name": "pond-pals", "version": "1.2.0"}"#,
                              theme: Data(AgentCharacterDuckherdFixture.text().utf8))
        let gardenSet = try plugin("garden-set", manifest: #"{"name": "garden-set", "version": "0.3.0"}"#, theme: garden)
        let mirror = try plugin("garden-mirror", manifest: nil, theme: garden)
        // Optional, local stills only: a real shared set as one more plugin, sorted last.
        var real = ""
        if let path = ProcessInfo.processInfo.environment["CONTINUUM_DUCKHERD_THEME_FILE"], !path.isEmpty {
            let folder = try plugin("zz-local-real", manifest: #"{"name": "local-real", "version": "0.0.1"}"#,
                                    theme: try Data(contentsOf: URL(fileURLWithPath: path)))
            real = #", "zz-local-real@fixture": [{"installPath": "\#(folder.path)"}]"#
        }
        try Data(#"{"pluginConfigs": {"theme-shelf@fixture": {"themesDir": "\#(shelf.path)"}}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        try Data("""
        {"version": 2, "plugins": {
          "pond-pals@fixture": [{"installPath": "\(pals.path)", "version": "9.9.9"}],
          "garden-set@fixture": [{"installPath": "\(gardenSet.path)"}],
          "garden-mirror@other": [{"installPath": "\(mirror.path)", "version": "0.1.0"}]\(real)}}
        """.utf8).write(to: home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        // Already imported: the same bytes, and the same id with other bytes.
        for (data, name) in [(pond(id: "already", title: "Already Here"), "already"), (pond(id: "stale", title: "Stale v1"), "stale")] {
            let file = root.appendingPathComponent("\(name).theme.json")
            try data.write(to: file)
            guard case .imported = AgentCharacterImports.importTheme(from: file, into: imports) else {
                throw Failure(description: "could not pre-import \(name)")
            }
        }

        let suite = "ArrayFoundThemesChecks-\(UUID().uuidString)"
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
        let out = ProcessInfo.processInfo.environment["CONTINUUM_FOUND_THEMES_STILLS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("qa-runs/found-themes", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let expected: [Row] = [
            Row(title: "Already Here", detail: "Lead + 2 helpers · from theme-shelf", action: "Imported", previewSprites: 3),
            Row(title: "Theme x", detail: "from theme-shelf", problem: "helpers[0].loops.run[0]: rows are 20 wide"),
            Row(title: "Stale v2", detail: "Lead + 2 helpers · from theme-shelf", action: "Update", previewSprites: 3),
            Row(title: "Garden Party", detail: "Lead + 2 helpers · from garden-mirror 0.1.0", action: "Import", previewSprites: 3),
            Row(title: "Duckherd-shaped set", detail: "Lead + 16 helpers · from pond-pals 1.2.0", action: "Import", previewSprites: 4),
        ]
        var rendered = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fixture = try open(defaults: defaults, appearance: appearance)
            defer { fixture.tearDown() }
            var rows = try readRows(fixture)
            if !real.isEmpty, rows.count == expected.count + 1, let extra = rows.popLast() {
                try expect(extra.action == "Import" && (extra.previewSprites ?? 0) > 0 && extra.detail?.hasSuffix("from local-real 0.0.1") == true,
                           "the real set's row: \(extra)")
            }
            try expect(rows.count == expected.count, "\(appearance.rawValue): \(expected.count) rows, one per distinct file, got \(rows.count): \(rows)")
            for (n, pair) in zip(rows, expected).enumerated() {
                try expect(pair.0 == pair.1, "\(appearance.rawValue) row \(n): got \(pair.0), want \(pair.1)")
            }
            try expectPreviewsDrawn(fixture, appearance: appearance)
            let gridTitle = fixture.model.renderedTexts["ArrayAgentCharacterGridTitle"]
            try expect(gridTitle == "\(AgentCharacterBundled.theme()?.title ?? "") in every state",
                       "\(appearance.rawValue): the grid names the set it shows: \(gridTitle ?? "nil")")
            try SidebarCharacterChecks.capture(fixture.window, to: out.appendingPathComponent(
                "found-themes-\(appearance == .aqua ? "light" : "dark").png"))
            // The card is shorter than the list: a second still at its end.
            let last = rows.count + (real.isEmpty ? 0 : 1) - 1
            try scroll("ArrayFoundTheme.\(last).title", toY: 320, in: fixture)
            try SidebarCharacterChecks.capture(fixture.window, to: out.appendingPathComponent(
                "found-themes-\(appearance == .aqua ? "light" : "dark")-end.png"))
            rendered += 1
        }

        // Real clicks: Imported does nothing; Import and Update import, and both rows turn Imported.
        let fixture = try open(defaults: defaults, appearance: .aqua)
        defer { fixture.tearDown() }
        let importedBefore = try fm.contentsOfDirectory(atPath: imports.path).sorted()
        try click("ArrayFoundTheme.0.action", in: fixture)
        try expect(try fm.contentsOfDirectory(atPath: imports.path).sorted() == importedBefore
                   && defaults.string(forKey: AgentCharacterConfig.themeKey) == nil,
                   "Imported is disabled: clicking it imports and selects nothing")
        try click("ArrayFoundTheme.3.action", in: fixture)
        try expect(defaults.string(forKey: AgentCharacterConfig.themeKey) == "garden", "Import imported and selected Garden Party")
        try click("ArrayFoundTheme.2.action", in: fixture)
        try expect(AgentCharacterImports.load(id: "stale", in: imports)?.title == "Stale v2", "Update replaced the imported copy")
        fixture.settle(0.3)
        let after = try readRows(fixture)
        try expect(after.prefix(5).map(\.action) == ["Imported", nil, "Imported", "Imported", "Import"],
                   "after Import and Update both rows read Imported: \(after.map { $0.action ?? "-" })")
        try expect(fixture.model.renderedTexts["ArrayAgentCharacterGridTitle"] == "Stale v2 in every state",
                   "the grid follows the newly chosen set")
        try expect(fm.fileExists(atPath: shelf.appendingPathComponent("stale.theme.json").path)
                   && fm.fileExists(atPath: mirror.appendingPathComponent(AgentCharacterImports.folderThemeName).path),
                   "found files are never moved or removed")
        return "Found character themes checks passed: 7 files from 4 plugins render as 5 rows in the Settings modal (a byte-identical copy folded), each with its title, characters and plugin, Import / Imported / Update by content, the invalid file's reason in place of a preview, the lead and first helpers at rest, in \(rendered) appearances; clicking Imported does nothing, clicking Import and Update imports and both rows turn Imported. Stills: \(out.path)"
    }

    // MARK: The real Settings modal

    /// Settings on Agent characters, tall enough that the
    /// found list sits inside the pane's viewport.
    static func open(defaults: UserDefaults, appearance: NSAppearance.Name) throws -> SettingsFixtureWindow {
        let settings = SettingsModel(defaults: defaults, navKeymap: .default)
        let fixture = SettingsFixtureWindow(model: settings, size: NSSize(width: 1_100, height: 1_500),
                                            appearance: NSAppearance(named: appearance))
        fixture.show(paneID: "agentCharacters")
        guard let entry = settings.entries().first(where: { $0.anchor == "custom.agentCharacters" }) else {
            throw Failure(description: "Settings has no Agent characters entry")
        }
        settings.reveal(entry)
        // Past the reveal's 1.6 s highlight, so stills show the resting rows.
        fixture.settle(2.0)
        // The found list sits below the set picker: bring its first row near the top.
        try scroll("ArrayFoundTheme.0.title", toY: 60, in: fixture)
        return fixture
    }

    /// The pane's scroll view: the one the size of the pane's viewport.
    static func pane(_ fixture: SettingsFixtureWindow) throws -> NSScrollView {
        let viewport = fixture.model.viewportSize
        guard let pane = fixture.descendants(NSScrollView.self).first(where: {
            abs($0.frame.width - viewport.width) < 1 && abs($0.frame.height - viewport.height) < 1
        }) else {
            throw Failure(description: "no scroll view matches the pane viewport \(viewport)")
        }
        return pane
    }

    /// Scroll the pane so `identifier`'s rendered frame starts `y` points below the viewport's top.
    static func scroll(_ identifier: String, toY y: CGFloat, in fixture: SettingsFixtureWindow) throws {
        guard let frame = fixture.model.anchorFrames[identifier] else {
            throw Failure(description: "\(identifier) has no rendered frame")
        }
        let pane = try pane(fixture)
        let clip = pane.contentView
        let delta = frame.minY - y
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? delta : -delta
        clip.scroll(to: origin)
        pane.reflectScrolledClipView(clip)
        fixture.settle(0.5)
    }

    static func readRows(_ fixture: SettingsFixtureWindow) throws -> [Row] {
        let texts = fixture.model.renderedTexts
        let strips = Dictionary(fixture.descendants(NSView.self).compactMap { view -> (String, NSView)? in
            view.accessibilityIdentifier().hasSuffix(".preview") ? (view.accessibilityIdentifier(), view) : nil
        }, uniquingKeysWith: { first, _ in first })
        var rows: [Row] = []
        for n in 0..<32 {
            let id = "ArrayFoundTheme.\(n)"
            guard texts[id + ".title"] != nil else { break }
            rows.append(Row(title: texts[id + ".title"], detail: texts[id + ".detail"], action: texts[id + ".action"],
                            problem: texts[id + ".problem"], previewSprites: strips[id + ".preview"]?.layer?.sublayers?.count))
        }
        if rows.isEmpty {
            throw Failure(description: "no Found on this Mac row rendered a title, a state or a preview")
        }
        return rows
    }

    /// Each strip's sprites hold an image, at a positive size, inside the strip.
    static func expectPreviewsDrawn(_ fixture: SettingsFixtureWindow, appearance: NSAppearance.Name) throws {
        for strip in fixture.descendants(NSView.self) where strip.accessibilityIdentifier().hasSuffix(".preview") {
            let id = strip.accessibilityIdentifier()
            try expect(strip.frame.width > 0 && strip.frame.height > 0, "\(appearance.rawValue) \(id): the strip has a size: \(strip.frame)")
            for sprite in strip.layer?.sublayers ?? [] {
                try expect(sprite.contents != nil, "\(appearance.rawValue) \(id): every character draws")
                try expect(sprite.frame.width > 0 && strip.bounds.contains(sprite.frame),
                           "\(appearance.rawValue) \(id): \(sprite.frame) inside \(strip.bounds)")
            }
        }
    }

    /// A real left click on a rendered element, as `AgentCLIUpdateSettingsChecks`
    /// clicks: its frame from the pane's frame census, delivered through
    /// `NSWindow.sendEvent`.
    static func click(_ identifier: String, in fixture: SettingsFixtureWindow) throws {
        guard let frame = fixture.model.anchorFrames[identifier] else {
            throw Failure(description: "\(identifier) has no rendered frame")
        }
        let viewport = fixture.model.viewportSize
        let pane = try pane(fixture)
        try expect(frame.minY >= 0 && frame.maxY <= viewport.height, "\(identifier) is outside the pane viewport: \(frame)")
        let local = NSPoint(x: frame.midX, y: pane.isFlipped ? frame.midY : pane.bounds.height - frame.midY)
        let point = pane.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure(description: "could not synthesize a click")
            }
            fixture.window.sendEvent(event)
        }
        fixture.settle(0.3)
    }
}
