import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Plan: .plans/110-agent-characters/README.md (per-agent character).
//
// `--workspace-api-agent-character-check`: `agent.update` with `character`
// through the production boot mount and dispatch, with the real supervisor
// saving the record. The pick reaches the tile header and the sidebar row, a
// fresh store reads it back, an unknown name is refused with the allowed names,
// null returns the hashed pick, and the tile's own Character menu writes the
// same record through `performActionForItem`.
@MainActor
enum WorkspaceAPIAgentCharacterChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private static func result(_ reply: WorkspaceAPIService.Reply) throws -> [String: AnyHashableJSON] {
        guard case let .result(value) = reply else { throw Failure(description: "expected result, got \(reply)") }
        return value
    }
    private static func error(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code) throws -> String {
        guard case let .error(value) = reply, value.code == code else {
            throw Failure(description: "expected \(code), got \(reply)")
        }
        return value.message
    }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "agent-character API check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        let suiteName = "array.check.apiCharacter.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let controller = AgentCharacterController.shared
        controller.windowIsVisible = { _ in true }
        controller.reduceMotion = { false }
        suite.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: suite)
        guard let theme = controller.theme else { throw Failure(description: "the built-in set did not load") }
        let id = f.agentId.rawValue
        let hashed = controller.characterIndex(for: id)!
        let pickIndex = (hashed + 3) % theme.characters.count
        let pick = theme.characters[pickIndex].name

        var serial = 0
        func update(_ value: Any, key: String? = nil) -> WorkspaceAPIService.Reply {
            serial += 1
            var payload: [String: Any] = ["agentId": f.agentId.rawValue.uuidString, "character": value]
            if let key { payload["idempotencyKey"] = key }
            return f.api.dispatch(agentId: f.agentId, requestId: "character-\(serial)", op: "agent.update", payload: payload)
        }

        let tile = ManagedAgentTileNSView(tile: Tile(
            id: f.agentTileB, kind: .managedAgent, title: "Character witness",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .first,
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        tile.attach(agentID: f.agentId, supervisor: supervisor)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        tile.layoutSubtreeIfNeeded()
        func atlas(_ index: Int) -> CGImage? { controller.atlas(theme: theme, character: index, appearance: .dark)?.image }
        func tileShows(_ index: Int) -> Bool { (tile.qaCharacterLayer?.contents as AnyObject?) === atlas(index) }
        try expect(tileShows(hashed), "before any pick, the header shows the hashed character")

        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.appearance = NSAppearance(named: .darkAqua)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }
        func rowShows(_ index: Int) -> Bool {
            let now = Date()
            inbox.reload(rows: [AgentInboxRowBuilder.row(
                from: AgentsBoardRow(agentId: id, status: .idle, lastSummary: "", recent: [], updatedAt: now),
                record: supervisor.records[f.agentId], now: now)])
            inbox.layoutForQA()
            return (inbox.cellForQA(id: id)?.characterLayerForQA.contents as AnyObject?) === atlas(index)
        }
        try expect(rowShows(hashed), "before any pick, the row shows the hashed character")

        // A pick, spelled loosely: the set's own spelling is stored and returned.
        let first = try result(update(pick.uppercased(), key: "first"))
        try expect(first["durability"]?.string == "committed" && first["character"]?.string == pick,
                   "the update commits the set's spelling: \(first)")
        try expect(supervisor.records[f.agentId]?.characterName == pick, "the record holds the pick")
        try expect(try AgentStore().load(id: f.agentId)?.characterName == pick, "a fresh store reads the pick back")
        try expect(try result(update(pick.uppercased(), key: "first")) == first, "a same-key replay returns the original outcome")
        try expect(try result(update(pick))["durability"]?.string == "unchanged", "the same pick is unchanged")
        tile.layoutSubtreeIfNeeded()
        try expect(tileShows(pickIndex), "the header shows the picked character")
        try expect(rowShows(pickIndex), "the sidebar row shows the picked character")

        // Refusals change nothing and name what is allowed.
        let message = try error(update("Nobody"), .invalidRequest)
        try expect(message.contains(theme.characters[0].name), "the refusal lists the allowed names: \(message)")
        _ = try error(update(42), .invalidRequest)
        try expect(supervisor.records[f.agentId]?.characterName == pick, "a refused update changes nothing")

        // null returns the hashed pick.
        let cleared = try result(update(NSNull()))
        try expect(cleared["durability"]?.string == "committed" && cleared["character"]?.value is NSNull, "null clears: \(cleared)")
        try expect(try AgentStore().load(id: f.agentId)?.characterName == nil, "the clear persists")
        try expect(tileShows(hashed) && rowShows(hashed), "cleared, both surfaces return to the hashed character")

        // The tile's own menu writes the same record.
        guard let root = tile.makeAdditionalTitleBarMenuItems().first(where: { $0.title == "Character" }),
              let menu = root.submenu,
              let index = menu.items.firstIndex(where: { $0.title == pick }) else {
            throw Failure(description: "the tile menu offers no Character submenu with \(pick)")
        }
        try expect(menu.items.first?.title == "Automatic" && menu.items.first?.state == .on,
                   "Automatic is ticked while the hash chooses")
        menu.performActionForItem(at: index)
        try expect(supervisor.records[f.agentId]?.characterName == pick && tileShows(pickIndex),
                   "picking from the tile menu saves and shows the character")
        let automatic = tile.makeAdditionalTitleBarMenuItems().first(where: { $0.title == "Character" })!.submenu!
        automatic.performActionForItem(at: 0)
        try expect(supervisor.records[f.agentId]?.characterName == nil && tileShows(hashed), "Automatic clears the pick")

        // Off: no menu, the pick still stored.
        _ = try result(update(pick))
        suite.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        try expect(!tile.makeAdditionalTitleBarMenuItems().contains(where: { $0.title == "Character" }),
                   "with characters off the tile offers no Character menu")
        try expect(supervisor.records[f.agentId]?.characterName == pick, "turning characters off keeps the pick")
        return "Workspace API agent character checks passed: agent.update saves the set's spelling, the header and the row show it, a fresh store reads it, replay and unchanged, unknown names refused with the allowed list, null clears, and the tile's Character menu writes the same record"
    }
}
