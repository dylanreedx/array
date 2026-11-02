import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md (agent-made sets, live reload).
//
// `--character-themes-live-check`: an agent's work in the themes folder reaches
// the screen with no relaunch. Real files are written into a temp themes folder
// and the real FSEvents stream reports them: a new set appears in the sidebar row
// and the tile header; an edit repaints them; a half-written file keeps the last
// good set showing and lists its problems in Settings; deleting the file falls
// back to the built-in ducks. A quiet folder costs nothing (no rescans). The
// validator agents call is run as the real binary on a good and a bad file.
@MainActor
enum CharacterThemesLiveChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    static func pump(until condition: () -> Bool, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func run() throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-character-live-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("characters", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../ContinuumRevivedCoreChecks/Fixtures/agent-character-themes").standardized
        let pond = try String(contentsOf: corpus.appendingPathComponent("good-pond.theme.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"id\":\"pond\"", with: "\"id\":\"pond-live\"")
        try expect(pond.contains("pond-live"), "fixture id rewritten")

        let suite = "ArrayCharacterLive-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.importsDirectory = folder
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        defaults.set("pond-live", forKey: AgentCharacterConfig.themeKey)
        controller.adopt(defaults: defaults)
        try expect(controller.theme?.id == AgentCharacterBundled.themeID, "with the set not written yet, the ducks show")

        // A sidebar row and an agent tile header, the two surfaces.
        let agent = UUID()
        let now = Date()
        let row = AgentInboxRow(id: agent, title: "Draw the pond set", projectName: "Array", state: .working,
                                model: "claude-opus-5-5", createdAt: now,
                                characterActivity: AgentCharacterActivity(action: .type, lastOutputAt: now))
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }
        inbox.reload(rows: [row])
        inbox.layoutForQA()
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Draw the pond set",
            frame: TileFrame(x: 0, y: 0, width: 420, height: 300), zPosition: .first,
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        let tileWindow = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        tileWindow.contentView = tile
        tileWindow.orderFrontOffscreenForChecks()
        defer { tileWindow.orderOut(nil) }
        // What the agent tile hands its header on every refresh.
        tile.setAgentCharacter(agentID: agent, snapshot: AgentCharacterSnapshot(
            state: .working, activity: AgentCharacterActivity(action: .type, lastOutputAt: now)))
        tile.layoutSubtreeIfNeeded()
        func showing() -> (row: AnyObject?, tile: AnyObject?) {
            (inbox.cellForQA(id: agent)?.characterLayerForQA.contents as AnyObject?,
             tile.qaCharacterLayer?.contents as AnyObject?)
        }
        func expected() -> AnyObject? {
            controller.atlas(for: agent, appearance: AgentCharacterController.appearance(of: inbox))?.image
        }

        // 1. An agent writes a new set into the folder.
        let file = folder.appendingPathComponent("pond-live.theme.json")
        try Data(pond.utf8).write(to: file, options: .atomic)
        try expect(pump(until: { controller.theme?.id == "pond-live" }), "the new set is picked up live (theme \(controller.theme?.id ?? "nil"))")
        inbox.layoutForQA()
        let first = expected()
        try expect(first != nil && showing().row === first, "the sidebar row redraws in the new set")
        try expect(tile.qaCharacterLayer.map { ($0.contents as AnyObject?) === controller.atlas(for: agent, appearance: AgentCharacterController.appearance(of: tile))?.image } == true,
                   "the tile header redraws in the new set")

        // 2. The agent improves it: an edited colour repaints both surfaces.
        try Data(pond.replacingOccurrences(of: "#112233", with: "#ff3366").utf8).write(to: file, options: .atomic)
        try expect(pump(until: { controller.theme?.palette.values.contains(AgentCharacterColour(hex: "#ff3366")!) == true }),
                   "an edit is picked up live")
        inbox.layoutForQA()
        let second = expected()
        try expect(second != nil && second !== first && showing().row === second, "the row shows the edited set")

        // 3. A half-written file: the last good set keeps showing, the problem is listed.
        let rescansBefore = controller.userThemeRescans
        try Data("{\"duckherdTheme\": 1, \"id\": \"pond-live\", \"palette\": ".utf8).write(to: file, options: .atomic)
        try expect(pump(until: { controller.userThemeRescans > rescansBefore && !controller.userThemeProblems.isEmpty }),
                   "the broken file is noticed")
        try expect(controller.theme?.id == "pond-live" && showing().row === second, "the last good set keeps showing")
        let settings = AgentCharacterSettingsModel(defaults: defaults, importsDirectory: folder, home: root)
        try expect(settings.folderProblems.first?.problems == ["not valid JSON"], "Settings lists the problem: \(settings.folderProblems)")

        // 4. Quiet folder, no work.
        let quiet = controller.userThemeRescans
        _ = pump(until: { false }, timeout: 1.5)
        try expect(controller.userThemeRescans == quiet, "a quiet folder is never rescanned (\(controller.userThemeRescans - quiet))")

        // 5. The file is removed: back to the ducks.
        try fm.removeItem(at: file)
        try expect(pump(until: { controller.theme?.id == AgentCharacterBundled.themeID }), "removing the set falls back to the ducks")

        // 6. The validator, as the real binary an agent runs.
        let bad = folder.appendingPathComponent("broken.theme.json")
        try Data(try Data(contentsOf: corpus.appendingPathComponent("bad-short-row.theme.json"))).write(to: bad)
        let good = root.appendingPathComponent("good.theme.json")
        try Data(pond.utf8).write(to: good)
        func validate(_ url: URL) throws -> (status: Int32, report: [String: Any]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = [AgentCharacterValidator.flag, url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (process.terminationStatus, report)
        }
        let ok = try validate(good)
        try expect(ok.status == 0 && ok.report["valid"] as? Bool == true, "the validator accepts a good set: \(ok)")
        let refused = try validate(bad)
        let problems = ((refused.report["files"] as? [[String: Any]])?.first?["problems"] as? [String]) ?? []
        try expect(refused.status == 1 && problems == ["helpers[0].loops.run[0]: rows are 20 wide"],
                   "the validator refuses a bad set with the exact problem: \(refused)")
        return "Character themes live checks passed: a set written into the folder appears on the row and the tile header, an edit repaints them, a half-written file keeps the last good set and lists its problem in Settings, a quiet folder is never rescanned, deleting falls back to the ducks, and the validator binary returns 0 / 1 with exact problems"
    }
}
