import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md › "Lead" (0.7.40).
//
// `--lead-character-check`: one lead per pack. A real supervisor spawns a lead
// and three helpers (real `parentAgentID` + delegation ordinals), one helper
// delegates further, and a lone agent stands apart. Through the production tile
// header and sidebar rows: the lead draws the set's lead art (28 x 16), the three
// helpers draw three distinct characters in delegation order, a nested helper
// never draws lead art, a fresh supervisor restoring the same store draws the
// same characters, a manual pick wins (on a helper and on the lead), the lone
// agent keeps its hashed pick, and a set with no lead art falls back: the lead
// keeps a helper character and its helpers start just after it.
@MainActor
enum LeadCharacterChecks {
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

    /// Light and dark stills of the pack's sidebar rows and the lead's header,
    /// into `qa-runs/agent-characters/lead-*.png`. For review, not asserted.
    static func captureStills(ids: [AgentID], supervisor: AgentSupervisor, inbox: AgentInboxView,
                              tileView: ManagedAgentTileNSView) throws {
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let now = Date()
        // The production nesting fact: each row carries its record's parent.
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
        for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            inbox.window?.appearance = NSAppearance(named: appearance)
            inbox.reload(rows: rows)
            inbox.layoutForQA()
            try SidebarCharacterChecks.capture(inbox.window!, to: out.appendingPathComponent("lead-sidebar-\(tone).png"))
        }
        try TileCharacterChecks.captureHeaders(view: tileView, window: tileView.window!, label: "lead-header")
        inbox.window?.appearance = NSAppearance(named: .aqua)
    }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-lead-character-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let imports = root.appendingPathComponent("characters", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayLeadCharacterChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        controller.importsDirectory = imports
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        guard let ducks = controller.theme, ducks.hasLead, ducks.characters.count >= 6 else {
            throw Failure(description: "the built-in set did not load with lead art")
        }
        let count = ducks.characters.count

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support", isDirectory: true)
        func makeSupervisor() -> AgentSupervisor {
            AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: support),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
                transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        }
        var supervisor = makeSupervisor()
        func spawn(_ name: String, parent: AgentID? = nil) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                             model: "anthropic/claude-haiku-4-5-20251001", thinking: "low",
                             parentAgentID: parent, displayName: name)
        }
        let lead = spawn("Lead the release")
        let helpers = [spawn("Fix the sidebar", parent: lead), spawn("Fix the header", parent: lead),
                       spawn("Write the notes", parent: lead)]
        let nested = spawn("Check one file", parent: helpers[0])
        let lone = spawn("Unrelated work")

        // The production surfaces: the lead's tile header and every agent's sidebar row.
        let tileView = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Lead the release",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 360), zPosition: .first,
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tileView.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        let window = NSWindow(contentRect: tileView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tileView
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }

        func atlas(_ id: AgentID) -> AgentCharacterSpriteAtlas? {
            let now = Date()
            inbox.reload(rows: [AgentInboxRowBuilder.row(
                from: AgentsBoardRow(agentId: id.rawValue, status: .idle, lastSummary: "", recent: [], updatedAt: now),
                record: supervisor.records[id], now: now)])
            inbox.layoutForQA()
            return inbox.cellForQA(id: id.rawValue)?.characterLayerForQA.sprite
        }
        func helperImage(_ index: Int) -> CGImage? {
            controller.atlas(theme: controller.theme!, character: index, appearance: .light)?.image
        }
        func rowShows(_ id: AgentID, _ index: Int) -> Bool {
            guard let shown = atlas(id) else { return false }
            return shown.atlas.frameWidth == controller.theme!.frameWidth && shown.image === helperImage(index)
        }
        func isLeadArt(_ sprite: AgentCharacterSpriteAtlas?) -> Bool { sprite?.atlas.frameWidth == 28 && sprite?.atlas.frameHeight == 16 }
        inboxWindow.appearance = NSAppearance(named: .aqua)

        func assertPack(_ label: String) throws {
            try expect(pump(until: { isLeadArt(atlas(lead)) }),
                       "\(label): the lead's row draws the set's 28 x 16 lead art (got \(String(describing: atlas(lead)?.atlas.frameWidth)))")
            tileView.attach(agentID: lead, supervisor: supervisor)
            tileView.layoutSubtreeIfNeeded()
            try expect(pump(until: { isLeadArt(tileView.qaCharacterLayer?.sprite) }),
                       "\(label): the lead's tile header draws lead art")
            if let rect = tileView.qaCharacterRect {
                try expect(abs(rect.width / rect.height - 28.0 / 16.0) < 0.01, "\(label): the header slot keeps the lead's 28 x 16 shape, \(rect)")
            }
            for (slot, helper) in helpers.enumerated() {
                try expect(controller.characterIndex(for: helper.rawValue) == slot,
                           "\(label): helper \(slot + 1) takes character \(slot) in delegation order (got \(String(describing: controller.characterIndex(for: helper.rawValue))))")
                try expect(rowShows(helper, slot), "\(label): helper \(slot + 1)'s row draws character \(slot)")
            }
            try expect(!isLeadArt(atlas(helpers[0])) && !isLeadArt(atlas(nested)),
                       "\(label): one lead per pack: a helper that delegates, and its helper, never draw lead art")
            let loneIndex = AgentCharacterConfig.characterIndex(for: lone.rawValue, count: count)
            try expect(controller.characterIndex(for: lone.rawValue) == loneIndex && rowShows(lone, loneIndex),
                       "\(label): an agent with no lead keeps its hashed pick")
        }
        try assertPack("first run")
        try captureStills(ids: [lead] + helpers + [nested, lone], supervisor: supervisor, inbox: inbox, tileView: tileView)

        // A relaunch: a fresh supervisor restores the same store.
        tileView.detach()
        supervisor.stopAll()
        supervisor = makeSupervisor()
        _ = supervisor.restore()
        try assertPack("after a reload")

        // A manual pick wins, on a helper and on the lead.
        let pick = (0..<count).first { !(0..<3).contains($0) }!
        try expect(supervisor.setCharacterName(agentID: helpers[1], ducks.characters[pick].name), "the helper's pick saves")
        try expect(pump(until: { rowShows(helpers[1], pick) }), "a helper's manual pick wins over its pack place")
        try expect(controller.characterIndex(for: helpers[0].rawValue) == 0 && controller.characterIndex(for: helpers[2].rawValue) == 2,
                   "one helper's pick moves no other helper")
        try expect(supervisor.setCharacterName(agentID: lead, ducks.characters[pick].name), "the lead's pick saves")
        try expect(pump(until: { rowShows(lead, pick) }), "a lead's manual pick wins over lead art")
        _ = supervisor.setCharacterName(agentID: lead, nil)
        _ = supervisor.setCharacterName(agentID: helpers[1], nil)
        try expect(pump(until: { isLeadArt(atlas(lead)) && rowShows(helpers[1], 1) }), "clearing the picks restores the pack")

        // A set with no lead art: the lead keeps a helper character; its helpers start after it.
        guard let url = AgentCharacterBundled.themeURL, var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any] else { throw Failure(description: "no bundled theme file") }
        json["id"] = "no-lead-check"
        json["title"] = "No lead"
        json["lead"] = nil
        json["leadSize"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: imports.appendingPathComponent("no-lead.theme.json"))
        controller.rescanUserThemes()
        defaults.set("no-lead-check", forKey: AgentCharacterConfig.themeKey)
        controller.reload()
        try expect(controller.theme?.id == "no-lead-check" && controller.theme?.hasLead == false, "the set with no lead art is shown")
        let leadIndex = AgentCharacterConfig.characterIndex(for: lead.rawValue, count: count)
        try expect(pump(until: { rowShows(lead, leadIndex) }), "with no lead art the lead keeps its hashed helper character")
        let fallback = helpers.map { controller.characterIndex(for: $0.rawValue) }
        try expect(fallback == (1...3).map { (leadIndex + $0) % count },
                   "with no lead art the helpers start just after the lead: \(fallback) vs lead \(leadIndex)")
        try expect(Set(fallback.compactMap { $0 } + [leadIndex]).count == 4, "the lead and its three helpers are four characters")
        for (slot, helper) in helpers.enumerated() {
            try expect(rowShows(helper, (leadIndex + 1 + slot) % count), "no lead art: helper \(slot + 1)'s row draws it")
        }

        tileView.detach()
        supervisor.stopAll()
        return "Lead character checks passed: the lead draws 28 x 16 lead art in its row and header, its 3 helpers draw characters 0, 1, 2 in delegation order, a helper that delegates and its helper never draw lead art, a restored store draws the same, a manual pick wins on a helper and on the lead, a lone agent keeps its hash, and a set with no lead art keeps the lead's helper character with its helpers after it"
    }
}
