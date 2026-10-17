import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--settle-closes-tile-check` — launch polish, item R.
///
/// Dylan: "the All set button doesn't work all the way: it removes the agent
/// from the sidebar but the tile remains on the canvas." Settle wrote the
/// record's lifecycle and nothing else, so the agent left the live list while
/// its tile stayed on the canvas.
///
/// Every entry point a person can settle from — the "All set?" nudge, the
/// hover Settle, the row menu and the bulk bar — is driven on the SHIPPED
/// sidebar over a scene mounted through `mountWorkspaceSceneAtBoot`
/// (`SidebarTruthChecks.makeWorld`). Each must take the tile off its zone
/// layer and out of the persisted canvas, leave the record settled (not
/// archived) on disk, put the tile back at the same world frame and zone on
/// Undo, and give it a tile again when the row is opened.
@MainActor
enum SettleClosesTileChecks {
    typealias World = SidebarTruthChecks.World
    struct Failure: Error, CustomStringConvertible { let description: String }

    enum EntryPoint: String, CaseIterable {
        case nudge = "All set? nudge"
        case hover = "hover Settle"
        case menu = "row menu Settle"
        case bulk = "bulk Settle"
    }

    static func run() async throws {
        var failures: [String] = []
        var lines: [String] = []
        for entry in EntryPoint.allCases {
            do { lines.append(try check(entry)) } catch { failures.append("\(entry.rawValue): \(error)") }
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\n")) }
        for line in lines { print("  \(line)") }
        print("SettleClosesTileChecks passed: the nudge, the hover Settle, the row menu and the bulk bar each closed the settled agent's tile from its zone layer and its project's canvas file, kept the record settled and on disk, drew the row in the one History shelf under a 'Moved to History' toast, put the tile back at its world frame and zone on Undo, and opened a tile again from the row")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    /// The tile as the scene holds it: its WORLD frame and zone, or nil when no
    /// layer holds it.
    private static func liveTile(_ world: World, _ tileId: UUID) -> Tile? {
        world.canvas.tilesInWorldFrames(forProjectId: world.projectA).first { $0.id == tileId }
    }

    private static func persistedTile(_ world: World, _ tileId: UUID) throws -> Tile? {
        try ProjectStore(projectRoot: world.rootA).loadCanvas().tiles.first { $0.id == tileId }
    }

    private static func storedRecord(_ world: World, _ id: AgentID) throws -> AgentRecord? {
        try AgentStore(applicationSupportDirectory: world.root.appendingPathComponent("Agents", isDirectory: true)).load(id: id)
    }

    private static func check(_ entry: EntryPoint) throws -> String {
        // Off the world origin, so a tile put back in zone-local space instead
        // of world space lands somewhere visibly different.
        let world = try SidebarTruthChecks.makeWorld(
            zoneOriginA: ZonePoint(x: 260, y: 140), idleAgentsFinishedATurn: true)
        defer { SidebarTruthChecks.tearDown(world) }
        try expect(!DeleteConfirmPolicy.current.requiresConfirmation(for: .managedAgent),
                   "setup: this machine's delete-confirm policy would put a modal in front of the close")
        let inbox = world.inbox
        inbox.prefersReducedMotion = { false }
        inbox.layoutForQA()

        // The bulk bar acts on a selection of two; every other entry on one.
        // The oldest idle agent carries the one "All set?" nudge, and a card
        // showing the nudge shows it instead of the hover actions, so the
        // hover entry settles the second idle agent.
        let idle = (agent: SidebarTruthChecks.idleAgent, tile: SidebarTruthChecks.idleTile)
        let secondIdle = (agent: SidebarTruthChecks.secondIdleAgent, tile: SidebarTruthChecks.secondIdleTile)
        let targets: [(agent: AgentID, tile: UUID)]
        switch entry {
        case .bulk: targets = [idle, secondIdle]
        case .hover: targets = [secondIdle]
        case .nudge, .menu: targets = [idle]
        }
        var before: [UUID: Tile] = [:]
        var beforeLifecycle: [AgentID: SettledOverride] = [:]
        for target in targets {
            guard let tile = liveTile(world, target.tile) else {
                throw Failure(description: "setup: \(target.tile) is not on its zone layer")
            }
            let persisted = try persistedTile(world, target.tile)
            try expect(persisted != nil, "setup: \(target.tile) is not in the canvas file")
            before[target.tile] = tile
            beforeLifecycle[target.agent] = world.supervisor.records[target.agent]?.settledOverride
        }

        // Every tile of the project as it stood: closing a tile settles an
        // auto-layout zone shut over the gap (529c3300), and the Undo must open
        // it again — every member back at its world frame, not just the tile.
        let zoneBefore = Dictionary(uniqueKeysWithValues: world.canvas
            .tilesInWorldFrames(forProjectId: world.projectA).map { ($0.id, $0.frame) })

        // SETTLE, through the entry point under test.
        let first = targets[0].agent.rawValue
        switch entry {
        case .nudge:
            try expect(inbox.settleNudgeForQA(id: first) != nil,
                       "the idle agent's card offers no \"All set?\" nudge")
            try expect(inbox.clickSettleNudgeForQA(id: first), "the nudge could not be pressed")
        case .hover:
            try expect(inbox.hoverRowForQA(id: first), "the idle agent's row cannot be hovered")
            try expect(inbox.clickHoverSettleForQA(id: first), "the hover Settle could not be pressed")
            _ = inbox.hoverRowForQA(id: nil)
        case .menu:
            try expect(inbox.openRowMenuForQA(clickedRowId: first), "the row menu did not open")
            try expect(inbox.pickRowMenuItemForQA(.settle), "the row menu offers no enabled Settle — \(inbox.rowMenuTitlesForQA)")
        case .bulk:
            try expect(inbox.selectRowsForQA(ids: targets.map(\.agent.rawValue)), "the two rows could not be selected")
            inbox.layoutForQA()
            try expect(inbox.pickBulkActionForQA(.settle), "the bulk bar offers no Settle — \(inbox.bulkActionTitlesForQA)")
        }
        world.canvas.layoutSubtreeIfNeeded()

        for target in targets {
            let record = world.supervisor.records[target.agent]
            try expect(record?.settledOverride == .settled,
                       "\(target.agent.rawValue): Settle did not settle — \(String(describing: record?.settledOverride))")
            try expect(record?.archivedAt == nil,
                       "\(target.agent.rawValue): Settle is not Archive; the record must stay settled, not archived")
            let stored = try storedRecord(world, target.agent)
            try expect(stored?.settledOverride == .settled,
                       "\(target.agent.rawValue): the settled record is not on disk — \(String(describing: stored?.settledOverride))")
            try expect(liveTile(world, target.tile) == nil && world.canvas.tileView(for: target.tile) == nil,
                       "\(target.agent.rawValue): the tile is still on the canvas after Settle")
            let persistedAfter = try persistedTile(world, target.tile)
            try expect(persistedAfter == nil,
                       "\(target.agent.rawValue): the tile is still in the project's canvas file after Settle")
            try expect(record?.tileId == nil,
                       "\(target.agent.rawValue): the record still names the closed tile")
        }

        let closedIds = Set(targets.map(\.tile))
        let slidIntoGap = world.canvas.tilesInWorldFrames(forProjectId: world.projectA)
            .filter { !closedIds.contains($0.id) && zoneBefore[$0.id] != nil && zoneBefore[$0.id] != $0.frame }
            .count

        // ONE History shelf: the settled row is drawn in History, and the toast
        // names that place.
        inbox.expandHistoryShelfForQA()
        inbox.layoutForQA()
        for target in targets {
            let drawn = inbox.drawnBlockForQA(id: target.agent.rawValue)
            try expect(drawn == "history",
                       "\(target.agent.rawValue): a settled agent is drawn in History — drawn in \(String(describing: drawn)), headings \(inbox.shelfHeadingTitlesForQA)")
        }
        try expect(!inbox.shelfHeadingTitlesForQA.contains { $0.hasPrefix("Settled") },
                   "no Settled heading is drawn — got \(inbox.shelfHeadingTitlesForQA)")

        // UNDO puts the lifecycle AND the tile back, where it was.
        try expect(!inbox.undoToastTextForQA.isEmpty, "Settle raised no Undo toast")
        let toast = inbox.undoToastTextForQA
        let expectedToast = (targets.count > 1 ? "Moved \(targets.count) to History" : "Moved to History")
            + " \(InboxUndoToast.separator) \(InboxUndoToast.undoTitle)"
        try expect(toast == expectedToast,
                   "the Settle toast names the place the agent went — got '\(toast)', want '\(expectedToast)'")
        try expect(inbox.clickUndoForQA(), "the Undo button could not be pressed")
        world.canvas.layoutSubtreeIfNeeded()
        for target in targets {
            let record = world.supervisor.records[target.agent]
            try expect(record?.settledOverride == beforeLifecycle[target.agent],
                       "\(target.agent.rawValue): Undo did not restore the lifecycle — \(String(describing: record?.settledOverride))")
            guard let restored = liveTile(world, target.tile), let original = before[target.tile] else {
                throw Failure(description: "\(target.agent.rawValue): Undo did not put the tile back on its zone layer")
            }
            try expect(restored.frame == original.frame && restored.zoneId == original.zoneId,
                       "\(target.agent.rawValue): Undo put the tile at \(restored.frame) in \(String(describing: restored.zoneId)), it was at \(original.frame) in \(String(describing: original.zoneId))")
            try expect(world.canvas.tileView(for: target.tile) is ManagedAgentTileNSView,
                       "\(target.agent.rawValue): the restored tile has no agent view")
            try expect(world.supervisor.agent(forTile: target.tile) == target.agent,
                       "\(target.agent.rawValue): the restored tile is not bound to its agent")
            let persisted = try persistedTile(world, target.tile)
            try expect(persisted?.frame == original.frame,
                       "\(target.agent.rawValue): the restored tile is not back in the canvas file at its world frame — \(String(describing: persisted?.frame))")
        }

        for tile in world.canvas.tilesInWorldFrames(forProjectId: world.projectA) {
            guard let was = zoneBefore[tile.id] else { continue }
            try expect(tile.frame == was,
                       "Undo left \(tile.id) at \(tile.frame); before the settle it was at \(was) — the gap the close shut was not opened again")
        }

        // RE-OPEN: settle again, then open the row — it gets a tile again.
        let agent = targets[0].agent
        try expect(inbox.openRowMenuForQA(clickedRowId: agent.rawValue) && inbox.pickRowMenuItemForQA(.settle),
                   "could not settle a second time")
        try expect(world.supervisor.records[agent]?.tileId == nil, "the second Settle left the tile bound")
        if inbox.drawnBlockForQA(id: agent.rawValue) == nil { inbox.expandHistoryShelfForQA() }
        inbox.layoutForQA()
        try expect(inbox.clickRowForQA(id: agent.rawValue), "the settled row cannot be clicked open")
        world.canvas.layoutSubtreeIfNeeded()
        guard let reopenedTile = world.supervisor.records[agent]?.tileId else {
            throw Failure(description: "opening the settled row gave the agent no tile")
        }
        try expect(world.canvas.tileView(for: reopenedTile) is ManagedAgentTileNSView,
                   "opening the settled row bound a tile no canvas holds")
        return "\(entry.rawValue): closed \(targets.count) tile(s), undo '\(toast)' restored them at \(targets.compactMap { before[$0.tile]?.frame }), \(slidIntoGap) member(s) slid into the gap and back, reopen gave a tile"
    }
}
