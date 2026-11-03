import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md › "Duckherd themes as they ship".
//
// `--duckherd-theme-check`: a set shaped like the ones Duckherd users share
// (`AgentCharacterDuckherdFixture`: scale 4, 151 colours, 16 helpers, trimmed
// lead frames up to 111 rows, `shift`, a level by index, `voices`) imports
// through Settings › Appearance › Character set's own import into a temp app
// support folder, and is selected. Then a real supervisor's lead and three
// helpers, on the production sidebar rows and the lead's tile header, at Small,
// Medium and Large: the lead draws the set's lead art at its own box, each
// helper its own character, and every sprite is a whole number of device pixels
// per 1x pixel. Light and dark stills of every size go to
// `qa-runs/agent-characters/duckherd-*` (or `CONTINUUM_DUCKHERD_STILLS_DIR`).
//
// `CONTINUUM_DUCKHERD_THEME_FILE=<file>` also imports that file the same way
// and draws the stills from it: how a real shared set is tried locally without
// committing it.
@MainActor
enum DuckherdThemeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func run() throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-duckherd-theme-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let imports = root.appendingPathComponent("support/characters", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        for folder in [work, imports, incoming] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        let suite = "ArrayDuckherdThemeChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        controller.importsDirectory = imports
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        // Still poses, so a still shows the same frame every run.
        defaults.set(AgentCharacterConfig.Motion.never.rawValue, forKey: AgentCharacterConfig.motionKey)
        controller.adopt(defaults: defaults)
        AgentCharacterSettingsModel.homeOverrideForChecks = root
        defer { AgentCharacterSettingsModel.homeOverrideForChecks = nil }
        let model = AgentCharacterSettingsModel(defaults: defaults, importsDirectory: imports, home: root)

        // 1. The Duckherd-shaped set imports through Settings' own import.
        let fixtureURL = incoming.appendingPathComponent("\(AgentCharacterDuckherdFixture.id).theme.json")
        try Data(AgentCharacterDuckherdFixture.text().utf8).write(to: fixtureURL)
        model.importTheme(from: fixtureURL)
        try expect(model.problems.isEmpty, "the Duckherd-shaped set imports, got: \(model.problems)")
        try expect(controller.theme?.id == AgentCharacterDuckherdFixture.id, "importing selects it (\(controller.theme?.id ?? "nil"))")
        try expect(fm.fileExists(atPath: imports.appendingPathComponent("\(AgentCharacterDuckherdFixture.id)/\(AgentCharacterImports.fileName)").path),
                   "a read-only copy lands in app support")
        guard let fixture = controller.theme, let fixtureLead = fixture.lead else {
            throw Failure(description: "the imported set has no lead art")
        }
        try expect(fixture.characters.count == 16 && fixture.scale == 4, "16 helpers at scale 4")
        try expect(fixtureLead.width == 112 && fixtureLead.height == 112, "the lead box is 112 x 112, got \(fixtureLead.width) x \(fixtureLead.height)")

        // 2. A real shared set, when one is named for a local run.
        var realTitle: String?
        if let path = ProcessInfo.processInfo.environment["CONTINUUM_DUCKHERD_THEME_FILE"], !path.isEmpty {
            model.importTheme(from: URL(fileURLWithPath: path))
            try expect(model.problems.isEmpty, "\(path) imports, got: \(model.problems)")
            try expect(controller.theme?.id != AgentCharacterDuckherdFixture.id, "the real set is selected")
            realTitle = controller.theme.map { "\($0.title) (\($0.characters.count) helpers, scale \($0.scale), lead \($0.lead?.width ?? 0) x \($0.lead?.height ?? 0))" }
        }

        let sets: [AgentCharacterTheme] = [fixture] + (realTitle != nil ? [controller.theme!] : [])
        var report: [String] = []
        for theme in sets {
            defaults.set(theme.id, forKey: AgentCharacterConfig.themeKey)
            controller.reload()
            try expect(controller.theme?.id == theme.id, "\(theme.id) is shown")
            report.append(try drawPack(theme: theme, defaults: defaults, root: root, work: work))
        }
        return "Duckherd theme checks passed: the Duckherd-shaped set (16 helpers, 151 colours, trimmed lead frames, shift, a level by index, voices) imports through Settings into a temp folder; "
            + report.joined(separator: "; ")
            + (realTitle.map { "; real file imported: \($0)" } ?? "")
    }

    /// A lead with three helpers, on the sidebar and the lead's header, at every size.
    static func drawPack(theme: AgentCharacterTheme, defaults: UserDefaults, root: URL, work: URL) throws -> String {
        let controller = AgentCharacterController.shared
        guard let lead = theme.lead else { throw Failure(description: "\(theme.id): no lead art") }
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support-\(theme.id)", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        func spawn(_ name: String, parent: AgentID? = nil) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                             model: "anthropic/claude-haiku-4-5-20251001", thinking: "low",
                             parentAgentID: parent, displayName: name)
        }
        let leadID = spawn("Lead the release")
        let helpers = [spawn("Fix the sidebar", parent: leadID), spawn("Fix the header", parent: leadID),
                       spawn("Write the notes", parent: leadID)]

        let tileView = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Lead the release",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 200), zPosition: .first,
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tileView.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        let window = NSWindow(contentRect: tileView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tileView
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        tileView.attach(agentID: leadID, supervisor: supervisor)
        defer { tileView.detach() }
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }

        let ids = [leadID] + helpers
        func reload() {
            let now = Date()
            let rows = AgentInboxRowBuilder.placingChildrenWithParents(ids.map { id in
                let record = supervisor.records[id]
                let context = AgentRowContext(
                    displayName: record?.displayName, agentKind: .managed, harness: record?.harness?.rawValue,
                    model: record?.model, createdAt: record?.createdAt, parentId: record?.parentAgentID?.rawValue)
                return AgentInboxRowBuilder.row(
                    from: AgentsBoardRow(agentId: id.rawValue, status: .idle, lastSummary: "", recent: [], updatedAt: now,
                                         context: context),
                    record: record, now: now)
            })
            inbox.reload(rows: rows)
            inbox.layoutForQA()
            tileView.layoutSubtreeIfNeeded()
        }
        func sprite(_ id: AgentID) -> CharacterSpriteLayer? { inbox.cellForQA(id: id.rawValue)?.characterLayerForQA }
        func isLead(_ layer: CharacterSpriteLayer?) -> Bool {
            layer?.sprite?.atlas.frameWidth == lead.width && layer?.sprite?.atlas.frameHeight == lead.height
        }
        func hasArt(_ layer: CharacterSpriteLayer?) -> Bool {
            guard let atlas = layer?.sprite?.atlas, layer?.contents != nil else { return false }
            return stride(from: 3, to: atlas.pixels.count, by: 4).contains { atlas.pixels[$0] == 255 }
        }

        let stills = ProcessInfo.processInfo.environment["CONTINUUM_DUCKHERD_STILLS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("qa-runs/agent-characters")
        try? FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        let backing = inboxWindow.backingScaleFactor
        let scale = CGFloat(theme.scale)
        var sizes: [String] = []
        for size in AgentCharacterConfig.Size.allCases {
            defaults.set(size.rawValue, forKey: AgentCharacterConfig.sizeKey)
            SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.sizeKey))
            reload()
            let label = "\(theme.id) at \(size.title)"
            try expect(pump(until: { isLead(sprite(leadID)) }),
                       "\(label): the lead's row draws the set's \(lead.width) x \(lead.height) lead art (got \(String(describing: sprite(leadID)?.sprite?.atlas.frameWidth)))")
            try expect(pump(until: { isLead(tileView.qaCharacterLayer) }), "\(label): the lead's header draws lead art")
            try expect(hasArt(sprite(leadID)) && hasArt(tileView.qaCharacterLayer), "\(label): the lead sprite has opaque art")
            for (slot, helper) in helpers.enumerated() {
                let layer = sprite(helper)
                try expect(layer?.sprite?.atlas.frameWidth == theme.frameWidth && layer?.sprite?.atlas.frameHeight == theme.frameHeight
                           && controller.characterIndex(for: helper.rawValue) == slot && hasArt(layer),
                           "\(label): helper \(slot + 1) draws character \(slot) at \(theme.frameWidth) x \(theme.frameHeight)")
            }
            // The sidebar: the size's whole device pixels per 1x pixel, so a
            // scale-4 lead's 1x grid lands on device pixels at every size.
            let perOneX = CGFloat(size.devicePixelsPerArtPixel(backingScale: Double(backing)))
            guard let frame = sprite(leadID)?.frame else { throw Failure(description: "\(label): no lead sprite frame") }
            let expected = NSSize(width: CGFloat(lead.width) / scale * perOneX / backing,
                                  height: CGFloat(lead.height) / scale * perOneX / backing)
            try expect(abs(frame.width - expected.width) < 0.01 && abs(frame.height - expected.height) < 0.01,
                       "\(label): the lead's sidebar sprite is \(expected), got \(frame.size)")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let tone = appearance == .aqua ? "light" : "dark"
                inboxWindow.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                reload()
                _ = pump(until: { false }, timeout: 0.1)
                try SidebarCharacterChecks.capture(inboxWindow, to: stills.appendingPathComponent("duckherd-\(theme.id)-\(size.rawValue)-sidebar-\(tone).png"))
                try SidebarCharacterChecks.capture(window, to: stills.appendingPathComponent("duckherd-\(theme.id)-\(size.rawValue)-header-\(tone).png"))
            }
            inboxWindow.appearance = nil
            window.appearance = nil
            sizes.append("\(size.title) \(Int(expected.width)) x \(Int(expected.height)) pt")
        }
        defaults.removeObject(forKey: AgentCharacterConfig.sizeKey)
        SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.sizeKey))
        return "\(theme.id): lead \(lead.width) x \(lead.height) and 3 helpers drawn in the sidebar and header at \(sizes.joined(separator: ", "))"
    }
}
