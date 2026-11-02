import AppKit
import ContinuumRevivedCore
import Foundation

/// `board.manage` through the PRODUCTION mount and dispatch (the call the pi
/// bridge and the MCP server make), with the app's own board runtime, spawner
/// and tile close. Runs inside `--workspace-api-board-check`.
///
/// The fixture's agent sits in zone B, which is live but NOT armed and has a
/// non-zero origin; the armed zone A belongs to another project. A create that
/// framed or installed against the armed zone instead of the caller's lands in
/// the wrong project — the `.plans/47` defect the zone assertions catch.
@MainActor
enum WorkspaceAPIBoardManageChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(message: message) }
        print("workspace-api-board-manage: PASS \(message)")
    }

    private static func result(_ reply: WorkspaceAPIService.Reply, _ label: String) throws -> [String: AnyHashableJSON] {
        guard case .result(let object) = reply else { throw Failure(message: "\(label): expected result, got \(reply)") }
        return object
    }

    @discardableResult
    private static func error(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code, _ label: String) throws -> WorkspaceAPIError {
        guard case .error(let value) = reply, value.code == code else {
            throw Failure(message: "\(label): expected \(code.rawValue), got \(reply)")
        }
        print("workspace-api-board-manage: PASS \(label) refused with \(code.rawValue)")
        return value
    }

    private static func id(_ value: AnyHashableJSON?) -> UUID? {
        value?.string.flatMap(UUID.init(uuidString:))
    }

    /// What the user sees in Edit ▸ Undo with nothing focused.
    private static func undoTitle(_ canvas: CanvasNSView) -> String? {
        let item = NSMenuItem(title: "Undo", action: #selector(CanvasNSView.undo(_:)), keyEquivalent: "")
        return canvas.validateMenuItem(item) ? item.title : nil
    }

    private struct Presentation: Equatable {
        let viewport: CanvasViewport
        let viewportApplies: Int
        let armed: UUID?
        let focus: FocusSurfaceID?
        let selection: Set<UUID>
        let generation: UInt64
    }

    private static func presentation(_ fixture: WorkspaceAPIChecks.Fixture) -> Presentation {
        Presentation(
            viewport: fixture.canvas.viewport, viewportApplies: fixture.canvas.qaViewportApplyCount,
            armed: fixture.canvas.armedZoneId, focus: fixture.focusBroker.activeSurface,
            selection: fixture.canvas.tileSelection.ids, generation: fixture.runtime.interactionGeneration)
    }

    static func run() throws {
        try runAskFirst()
        try runFree()
        print("workspace-api-board-manage: all passed")
    }

    // MARK: - Ask first

    private static func runAskFirst() throws {
        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.delegate.qaAgentSupervisor
        supervisor.workspaceToolsPermission = { .askFirst }
        var prompts: [WorkspaceAPIOp] = []
        var decision: WorkspaceAPIService.ScopeApprovalDecision = .deny
        fixture.api.approvalHandler = { prompt in prompts.append(prompt.op); return decision }
        func manage(_ payload: [String: Any], _ requestId: String) -> WorkspaceAPIService.Reply {
            fixture.api.dispatch(agentId: fixture.agentId, requestId: requestId, op: "board.manage", payload: payload)
        }
        // The app's own board authority for the agent's project — the one the
        // Boards sidebar, the spawner and the API all reach.
        guard let boards = fixture.api.boardRuntimeProvider(fixture.projectPb) else {
            throw Failure(message: "no production board runtime for the agent's project")
        }

        try error(manage(["op": "create", "title": "Release QA", "idempotencyKey": "off-1"], "tools-off"),
                  .permissionDenied, "create with Workspace Tools off")
        try expect(supervisor.setWorkspaceToolsEnabled(agentID: fixture.agentId, true), "Workspace Tools enabled")

        // Rename rides board.apply's preset grant: it never asks.
        let seedId = UUID()
        guard let seed = boards.createBoard(id: seedId, title: "Seed") else { throw Failure(message: "could not create the seed board") }
        try error(manage(["op": "rename", "boardId": seedId.uuidString, "expectedRevision": seed.revision + 1,
                          "title": "Seed renamed", "idempotencyKey": "rename-stale"], "rename-stale"),
                  .revisionConflict, "rename with a stale revision")
        try expect(boards.board(id: seedId)?.title == "Seed", "a stale rename changes nothing")
        let renamedSeed = try result(manage(["op": "rename", "boardId": seedId.uuidString, "expectedRevision": seed.revision,
                                             "title": "Seed renamed", "idempotencyKey": "rename-seed"], "rename-seed"), "rename closed board")
        try expect(renamedSeed["title"]?.string == "Seed renamed" && renamedSeed["revision"]?.int == Int(seed.revision) + 1
                   && renamedSeed["undoRegistered"]?.bool == true && prompts.isEmpty,
                   "rename of a closed board commits one revision, registers Undo and asks nothing under Ask first")
        try expect(boards.boardIndexEntries().first(where: { $0.id == seedId })?.title == "Seed renamed",
                   "the durable index the Boards sidebar lists carries the new name")

        // Create asks the first time; a denial changes nothing.
        let before = presentation(fixture)
        let boardsBefore = boards.boardIndexEntries().count
        let tilesBefore = fixture.canvas.allWorkspaceTiles().count
        try error(manage(["op": "create", "title": "Release QA", "idempotencyKey": "create-denied"], "create-denied"),
                  .scopeApprovalRequired, "create the user denied")
        try expect(prompts == [.boardManage] && boards.boardIndexEntries().count == boardsBefore
                   && fixture.canvas.allWorkspaceTiles().count == tilesBefore,
                   "under Ask first the first create asks, and a denied create makes no board and no tile")

        decision = .allowForSession
        let createPayload: [String: Any] = ["op": "create", "title": "Release QA", "idempotencyKey": "create-a"]
        let created = try result(manage(createPayload, "create-a"), "create")
        guard let boardA = id(created["boardId"]), let tileA = id(created["tileId"]) else {
            throw Failure(message: "create returned no boardId/tileId: \(created)")
        }
        let columnNames = created["columns"]?.array?.compactMap { $0.object?["name"]?.string }
        let columnIds = created["columns"]?.array?.compactMap { id($0.object?["columnId"]) } ?? []
        try expect(prompts == [.boardManage, .boardManage] && created["undoRegistered"]?.bool == true
                   && created["durability"]?.string == "committed",
                   "an approved create commits and registers Undo")
        try expect(columnNames == ["To Do", "Doing", "Done"] && columnIds.count == 3
                   && boards.board(id: boardA)?.orderedColumns.map(\.id) == columnIds,
                   "create returns the default columns' real ids")
        try expect(id(created["zoneId"]) == fixture.zoneB && fixture.canvas.zoneId(containing: tileA) == fixture.zoneB
                   && fixture.canvas.projectId(forZone: fixture.zoneB) == fixture.projectPb,
                   "the board tile is installed in the agent's own (unarmed) zone, not the armed one")
        guard let worldA = fixture.canvas.tilesInWorldFrames(forZoneId: fixture.zoneB)?.first(where: { $0.id == tileA })?.frame,
              let zoneRect = fixture.runtime.document.zones.first(where: { $0.zoneId == fixture.zoneB }) else {
            throw Failure(message: "the created tile has no world frame in zone B")
        }
        try expect(worldA.x >= zoneRect.origin.x && worldA.y >= zoneRect.origin.y,
                   "the tile's WORLD frame lies inside zone B's world rect (x \(worldA.x) ≥ \(zoneRect.origin.x), y \(worldA.y) ≥ \(zoneRect.origin.y))")
        guard let viewA = fixture.canvas.tileView(for: tileA) as? KanbanTileNSView else {
            throw Failure(message: "the created tile is not a live board view")
        }
        try expect(viewA.board.id == boardA && viewA.chromeSnapshot?.title.contains("Release QA") == true
                   && fixture.canvas.tileRecord(for: tileA)?.title == "Release QA",
                   "the new tile shows the board and its title in the header")
        try expect(presentation(fixture) == before,
                   "create moves no camera, armed zone, focus, selection or interaction generation")
        let persistedCanvas = try fixture.storePb.loadCanvas()
        try expect(persistedCanvas.tiles.first(where: { $0.id == tileA })?.metadata.boardId == boardA
                   && boards.boardIndexEntries().first(where: { $0.id == boardA })?.tileId == tileA,
                   "the tile and its board binding are on disk")

        let replay = try result(manage(createPayload, "create-a-retry"), "idempotent create")
        try expect(id(replay["boardId"]) == boardA && id(replay["tileId"]) == tileA
                   && boards.boardIndexEntries().count == boardsBefore + 1
                   && fixture.canvas.allWorkspaceTiles().count == tilesBefore + 1,
                   "retrying the same key returns the same board and makes no second one")
        var changed = createPayload
        changed["title"] = "Other"
        try error(manage(changed, "create-a-conflict"), .idempotencyConflict, "same key, different create")

        let createdB = try result(manage(["op": "create", "idempotencyKey": "create-b"], "create-b"), "second create")
        guard let boardB = id(createdB["boardId"]), let tileB = id(createdB["tileId"]) else {
            throw Failure(message: "second create returned no ids")
        }
        let uiDefault = AppDelegate.boardTitle(forZoneTitle: fixture.canvas.zonePresentation(for: fixture.zoneB)?.title ?? "")
        try expect(prompts.count == 2 && createdB["title"]?.string == uiDefault,
                   "the session grant covers the next create, and an untitled board takes the UI's default name (\(uiDefault))")

        // Rename an OPEN board: tile header, tile record and Boards sidebar follow.
        let revA = boards.board(id: boardA)!.revision
        _ = try result(manage(["op": "rename", "boardId": boardA.uuidString, "expectedRevision": revA,
                               "title": "Release QA v2", "idempotencyKey": "rename-a"], "rename-a"), "rename open board")
        try expect(viewA.board.title == "Release QA v2" && viewA.chromeSnapshot?.title.contains("Release QA v2") == true
                   && fixture.canvas.tileRecord(for: tileA)?.title == "Release QA v2",
                   "a rename shows in the open tile's header and its tile record")
        try expect(viewA.boardLibraryProvider?().first(where: { $0.id == boardA })?.title == "Release QA v2",
                   "a rename shows in the Boards sidebar")
        try expect((try? fixture.storePb.loadBoard(id: boardA).title) == "Release QA v2", "the rename is on disk")
        viewA.boardUndoManager?.undo()
        try expect(viewA.board.title == "Release QA" && boards.boardIndexEntries().first(where: { $0.id == boardA })?.title == "Release QA",
                   "the board tile's Undo restores the old name")
        viewA.boardUndoManager?.redo()
        try expect(viewA.board.title == "Release QA v2", "Redo renames it again")

        // Delete: stale, non-empty, then the real one.
        let revB = boards.board(id: boardB)!.revision
        try error(manage(["op": "delete", "boardId": boardB.uuidString, "expectedRevision": revB + 1,
                          "idempotencyKey": "delete-stale"], "delete-stale"), .revisionConflict, "delete with a stale revision")
        _ = try result(fixture.api.dispatch(agentId: fixture.agentId, requestId: "task", op: "board.apply", payload: [
            "op": "create", "boardId": boardA.uuidString, "columnId": columnIds[0].uuidString,
            "title": "Keep me", "expectedRevision": boards.board(id: boardA)!.revision, "idempotencyKey": "task-1"]), "task on A")
        let notEmpty = try error(manage(["op": "delete", "boardId": boardA.uuidString,
                                         "expectedRevision": boards.board(id: boardA)!.revision,
                                         "idempotencyKey": "delete-a"], "delete-a"), .targetConflict, "delete a board with tasks")
        try expect(notEmpty.message.hasPrefix("board_not_empty") && boards.board(id: boardA)?.cards.count == 1
                   && fixture.canvas.tileRecord(for: tileA) != nil,
                   "a board with tasks is refused and keeps its task and tile")

        let beforeDelete = presentation(fixture)
        let deleted = try result(manage(["op": "delete", "boardId": boardB.uuidString, "expectedRevision": revB,
                                         "idempotencyKey": "delete-b"], "delete-b"), "delete")
        try expect(deleted["undoRegistered"]?.bool == true && deleted["tileId"] == nil
                   && fixture.canvas.tileRecord(for: tileB) == nil && boards.board(id: boardB) == nil
                   && !boards.boardIndexEntries().contains(where: { $0.id == boardB }),
                   "delete closes the tile and removes the board from the index")
        let canvasAfterDelete = try fixture.storePb.loadCanvas()
        try expect(!canvasAfterDelete.tiles.contains(where: { $0.id == tileB })
                   && (try? fixture.storePb.tryLoadBoard(id: boardB)) ?? nil == nil,
                   "the tile and the board document are gone from disk")
        try expect(presentation(fixture) == beforeDelete && prompts.count == 2,
                   "delete moves nothing and the session grant covers it")
        try error(manage(["op": "delete", "boardId": boardB.uuidString, "expectedRevision": revB,
                          "idempotencyKey": "delete-b-again"], "delete-b-again"), .notFound, "delete of a deleted board")
        let deleteReplay = try result(manage(["op": "delete", "boardId": boardB.uuidString, "expectedRevision": revB,
                                              "idempotencyKey": "delete-b"], "delete-b-retry"), "idempotent delete")
        try expect(id(deleteReplay["boardId"]) == boardB, "retrying the delete's key returns its original result")

        // Undo, from the canvas — the Edit menu with no board or text focused.
        try expect(undoTitle(fixture.canvas) == "Undo Delete Board", "Edit ▸ Undo names the delete (got \(undoTitle(fixture.canvas) ?? "nil"))")
        fixture.canvas.undo(nil)
        guard let restoredView = fixture.canvas.tileView(for: tileB) as? KanbanTileNSView,
              let restoredFrame = fixture.canvas.tilesInWorldFrames(forZoneId: fixture.zoneB)?.first(where: { $0.id == tileB })?.frame else {
            throw Failure(message: "Undo Delete Board did not bring the tile back to zone B")
        }
        let canvasAfterUndo = try fixture.storePb.loadCanvas()
        try expect(restoredView.board.id == boardB && boards.board(id: boardB)?.revision == revB
                   && boards.boardIndexEntries().first(where: { $0.id == boardB })?.tileId == tileB
                   && canvasAfterUndo.tiles.contains(where: { $0.id == tileB }),
                   "Undo restores the document, its index entry and its tile, durably")
        try expect(abs(restoredFrame.width - CanvasEngine.defaultFrame(for: .kanban).width) < 0.5,
                   "the restored tile comes back at its own size in its zone")
        try expect(undoTitle(fixture.canvas) == "Undo New Board", "the next Undo is the second create")
        fixture.canvas.undo(nil)
        try expect(fixture.canvas.tileRecord(for: tileB) == nil && boards.board(id: boardB) == nil,
                   "Undo New Board removes the board an agent created")
        fixture.canvas.redo(nil)
        try expect(fixture.canvas.tileView(for: tileB) is KanbanTileNSView && boards.board(id: boardB) != nil,
                   "Redo brings it back")
        fixture.canvas.undo(nil)
        try expect(undoTitle(fixture.canvas) == "Undo New Board", "board A’s create is next on the stack (got \(undoTitle(fixture.canvas) ?? "nil"))")
        fixture.canvas.undo(nil)
        try expect(boards.board(id: boardA)?.cards.count == 1 && fixture.canvas.tileRecord(for: tileA) != nil,
                   "Undo New Board refuses to destroy a board that has gained a task since")

        // Reload: a fresh board runtime and store read only what is on disk.
        let reloaded = BoardRuntime(projectStore: ProjectStore(projectRoot: fixture.pbRoot))
        let reloadedCanvas = try ProjectStore(projectRoot: fixture.pbRoot).loadCanvas()
        try expect(reloaded.board(id: boardA)?.title == "Release QA v2" && reloaded.board(id: seedId)?.title == "Seed renamed"
                   && reloaded.board(id: boardB) == nil
                   && reloadedCanvas.tiles.first(where: { $0.id == tileA })?.zoneId == fixture.zoneB
                   && !reloadedCanvas.tiles.contains(where: { $0.id == tileB }),
                   "after a reload the renames, the open board's tile in zone B, and the undone board's absence all hold")

        // Allow once is spent by the request it authorized.
        let other = try WorkspaceAPIChecks.makeFixture()
        defer { other.tearDown() }
        other.delegate.qaAgentSupervisor.workspaceToolsPermission = { .askFirst }
        _ = other.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: other.agentId, true)
        var oncePrompts = 0
        other.api.approvalHandler = { _ in oncePrompts += 1; return .allowOnce }
        _ = try result(other.api.dispatch(agentId: other.agentId, requestId: "once-1", op: "board.manage",
                                          payload: ["op": "create", "idempotencyKey": "once-1"]), "allow-once create")
        _ = try result(other.api.dispatch(agentId: other.agentId, requestId: "once-2", op: "board.manage",
                                          payload: ["op": "create", "idempotencyKey": "once-2"]), "second allow-once create")
        try expect(oncePrompts == 2, "Allow Once covers one create; the next one asks again")
    }

    // MARK: - Free

    private static func runFree() throws {
        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { fixture.tearDown() }
        fixture.delegate.qaAgentSupervisor.workspaceToolsPermission = { .free }
        _ = fixture.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: fixture.agentId, true)
        var prompts = 0
        fixture.api.approvalHandler = { _ in prompts += 1; return .deny }
        let created = try result(fixture.api.dispatch(agentId: fixture.agentId, requestId: "free-create", op: "board.manage",
                                                      payload: ["op": "create", "title": "Free board", "idempotencyKey": "free-1"]), "create under Free")
        guard let boardId = id(created["boardId"]), let tileId = id(created["tileId"]) else {
            throw Failure(message: "create under Free returned no ids")
        }
        try expect(fixture.canvas.zoneId(containing: tileId) == fixture.zoneB, "under Free the board lands in the agent's zone")
        _ = try result(fixture.api.dispatch(agentId: fixture.agentId, requestId: "free-delete", op: "board.manage",
                                            payload: ["op": "delete", "boardId": boardId.uuidString,
                                                      "expectedRevision": Int(created["revision"]?.int ?? 0),
                                                      "idempotencyKey": "free-2"]), "delete under Free")
        try expect(prompts == 0 && fixture.api.policyApprovalCount >= 1 && fixture.canvas.tileRecord(for: tileId) == nil,
                   "under Free, create and delete inside the project never ask")
        let foreign = try error(fixture.api.dispatch(agentId: fixture.agentId, requestId: "free-foreign", op: "board.manage",
                                                     payload: ["op": "create", "checkoutHandle": fixture.paHandle.rawValue,
                                                               "idempotencyKey": "free-3"]),
                                .permissionDenied, "create in another project's checkout")
        try expect(!foreign.message.contains(fixture.paRoot.path), "the refusal names no path")
        try error(fixture.api.dispatch(agentId: fixture.agentId, requestId: "free-anchor", op: "board.manage",
                                       payload: ["op": "create", "nextToTileId": fixture.hiddenB.uuidString,
                                                 "idempotencyKey": "free-4"]),
                  .invalidRequest, "create beside a tile outside the agent's zone")
    }
}
