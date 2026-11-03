import AppKit
import ContinuumRevivedCore
import Foundation

/// KB-01's host witness: the production dispatch entry reaches the durable
/// board owner for a closed board, and every mutation remains visible,
/// undoable, revision checked, idempotent and pointer safe.
@MainActor
enum WorkspaceAPIBoardChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(message: message) }
        print("workspace-api-board: PASS \(message)")
    }

    private static func result(_ reply: WorkspaceAPIService.Reply, _ label: String) throws -> [String: AnyHashableJSON] {
        guard case .result(let object) = reply else { throw Failure(message: "\(label): expected result, got \(reply)") }
        return object
    }

    private static func error(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code, _ label: String) throws {
        guard case .error(let value) = reply, value.code == code else {
            throw Failure(message: "\(label): expected \(code.rawValue), got \(reply)")
        }
    }

    private static func id(_ value: AnyHashableJSON?) -> UUID? {
        value?.string.flatMap(UUID.init(uuidString:))
    }

    static func run() throws {
        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { fixture.tearDown() }

        let boardRuntime = BoardRuntime(projectStore: fixture.storePb)
        let boardID = UUID()
        guard let initial = boardRuntime.createBoard(id: boardID, title: "QA queue") else {
            throw Failure(message: "could not create the board fixture")
        }
        fixture.api.boardRuntimeProvider = { projectID in
            projectID == fixture.projectPb ? boardRuntime : nil
        }
        try error(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-disabled", op: "board.query", payload: [:]),
                  .permissionDenied, "Workspace Tools disabled")
        try expect(fixture.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: fixture.agentId, true), "Workspace Tools enables board operations")
        var committed: [BoardTransaction] = []
        boardRuntime.onCommittedTransaction = { transaction, _ in committed.append(transaction) }

        let list = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-list", op: "board.query", payload: [:]), "closed-board query")
        let summaries = list["boards"]?.array ?? []
        try expect(summaries.count == 1 && id(summaries[0].object?["boardId"]) == boardID
                   && summaries[0].object?["tileId"] == nil,
                   "query discovers a closed board from its durable index")

        func tile(_ title: String) -> Tile {
            var metadata = TileMetadata()
            metadata.boardId = boardID
            return Tile(
                id: UUID(), kind: .kanban, title: title,
                frame: TileFrame(x: 0, y: 0, width: 600, height: 420),
                zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: metadata)
        }
        let firstView = KanbanTileNSView(tile: tile("QA 1"), board: initial)
        let secondView = KanbanTileNSView(tile: tile("QA 2"), board: initial)
        boardRuntime.attach(firstView, to: boardID)
        boardRuntime.attach(secondView, to: boardID)

        let columns = initial.orderedColumns
        let createPayload: [String: Any] = [
            "op": "create", "boardId": boardID.uuidString,
            "columnId": columns[0].id.uuidString, "title": "QA: modal flashes",
            "body": "Opening task detail briefly flashes an empty surface.",
            "assigneeAgentId": fixture.agentId.rawValue.uuidString,
            "expectedRevision": initial.revision, "idempotencyKey": "qa-create-1"
        ]
        let created = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-create", op: "board.apply", payload: createPayload), "create")
        guard let cardID = id(created["cardId"]) else { throw Failure(message: "create did not return cardId") }
        try expect(created["revision"]?.int == 1 && created["undoRegistered"]?.bool == true
                   && created["durability"]?.string == "committed",
                   "create commits atomically with one revision and one undo")
        let persistedAfterCreate = try fixture.storePb.loadBoard(id: boardID)
        try expect(boardRuntime.board(id: boardID)?.card(cardID)?.body.contains("flashes") == true
                   && persistedAfterCreate.card(cardID)?.assignee == fixture.agentId,
                   "created task is visible in memory and persisted with its assignee")
        try expect(committed.count == 1 && boardRuntime.history(for: boardID).undoManager.canUndo,
                   "the centralized committed-transaction hook and board undo both observe the API mutation")
        try expect(firstView.board.card(cardID) != nil && secondView.board.card(cardID) != nil,
                   "an API mutation broadcasts to every open tile for the board")

        let replay = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-create-retry", op: "board.apply", payload: createPayload), "idempotent replay")
        try expect(id(replay["cardId"]) == cardID && boardRuntime.board(id: boardID)?.cards.count == 1
                   && committed.count == 1,
                   "reusing a retry key returns the original result without a second effect")
        var changedRetry = createPayload
        changedRetry["title"] = "Different payload"
        try error(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-create-conflict", op: "board.apply", payload: changedRetry),
                  .idempotencyConflict, "changed idempotent payload")

        let page = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-detail", op: "board.query",
            payload: ["boardId": boardID.uuidString, "limit": 1]), "detailed query")
        try expect(page["board"]?.object?["cards"]?.array?.first?.object?["title"]?.string == "QA: modal flashes",
                   "detailed query returns the full task snapshot")
        let oldCursor = BoardQueryPage.cursor(boardId: boardID, revision: 1, offset: 0)

        let editPayload: [String: Any] = [
            "op": "edit", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
            "title": "QA: modal no longer flashes", "expectedRevision": 1,
            "idempotencyKey": "qa-edit-1"
        ]
        _ = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "board-edit", op: "board.apply", payload: editPayload), "edit")
        try error(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "expired-cursor", op: "board.query",
            payload: ["boardId": boardID.uuidString, "cursor": oldCursor]), .cursorExpired, "expired detailed cursor")
        try error(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "stale-delete", op: "board.apply",
            payload: ["op": "delete", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                      "expectedRevision": 1, "idempotencyKey": "stale-delete-1"]),
                  .revisionConflict, "stale non-positional write")

        boardRuntime.beginPointerDrag(cardId: cardID)
        try error(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "busy-move", op: "board.apply",
            payload: ["op": "move", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                      "columnId": columns[1].id.uuidString, "expectedRevision": 2,
                      "idempotencyKey": "busy-move-1"]), .busy, "pointer-held card")
        try expect(boardRuntime.advanceAssignedTaskAfterAcceptedSend(
            boardId: boardID, cardId: cardID, agentId: fixture.agentId) == .rejectedCardHeldByPointer,
                   "accepted send refuses to move a pointer-held task")
        boardRuntime.endPointerDrag()

        try expect(boardRuntime.advanceAssignedTaskAfterAcceptedSend(
            boardId: boardID, cardId: cardID, agentId: AgentID(rawValue: UUID())) == nil,
                   "accepted send from an agent that no longer owns the task does not move it")

        let started = boardRuntime.advanceAssignedTaskAfterAcceptedSend(
            boardId: boardID, cardId: cardID, agentId: fixture.agentId)
        try expect(started != nil && boardRuntime.board(id: boardID)?.card(cardID)?.columnId == columns[1].id,
                   "accepted send advances an assigned leftmost task to the second lane")
        try expect(boardRuntime.advanceAssignedTaskAfterAcceptedSend(
            boardId: boardID, cardId: cardID, agentId: fixture.agentId) == nil,
                   "a task already beyond the first lane does not move again")
        try expect(boardRuntime.board(id: boardID)?.orderedColumns.map(\.id) == columns.map(\.id),
                   "agent task operations leave board structure user managed")

        let rebasedCreate = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "rebased-create", op: "board.apply",
            payload: ["op": "create", "boardId": boardID.uuidString,
                      "columnId": columns[1].id.uuidString, "title": "Follow-up QA",
                      "afterCardId": cardID.uuidString, "expectedRevision": 2,
                      "idempotencyKey": "rebased-create-1"]), "stale anchored create")
        guard let followUpID = id(rebasedCreate["cardId"]) else {
            throw Failure(message: "rebased create did not return cardId")
        }
        try expect(rebasedCreate["outcome"]?.string == "rebased" && rebasedCreate["revision"]?.int == 4,
                   "a stale create rebases a surviving neighbour anchor and reports it")

        _ = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "unassign", op: "board.apply",
            payload: ["op": "unassign", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                      "expectedRevision": 4, "idempotencyKey": "unassign-1"]), "unassign")
        try expect(boardRuntime.board(id: boardID)?.card(cardID)?.assignee == nil,
                   "unassign clears the task owner through the API")
        try error(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "missing-assignee", op: "board.apply",
            payload: ["op": "assign", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                      "assigneeAgentId": UUID().uuidString, "expectedRevision": 5,
                      "idempotencyKey": "missing-assignee-1"]), .notFound, "missing assignee identity")
        _ = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "assign", op: "board.apply",
            payload: ["op": "assign", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                      "assigneeAgentId": fixture.agentId.rawValue.uuidString, "expectedRevision": 5,
                      "idempotencyKey": "assign-1"]), "assign")
        _ = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "finish", op: "board.apply",
            payload: ["op": "move", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                      "columnId": columns[2].id.uuidString, "expectedRevision": 6,
                      "idempotencyKey": "finish-1"]), "explicit Done move")
        try expect(boardRuntime.board(id: boardID)?.card(cardID)?.columnId == columns[2].id,
                   "the agent can explicitly move its completed task to the final lane")
        _ = try result(fixture.api.dispatch(
            agentId: fixture.agentId, requestId: "delete", op: "board.apply",
            payload: ["op": "delete", "boardId": boardID.uuidString, "cardId": followUpID.uuidString,
                      "expectedRevision": 7, "idempotencyKey": "delete-1"]), "delete")
        try expect(boardRuntime.board(id: boardID)?.card(followUpID) == nil
                   && firstView.board == secondView.board && firstView.board.revision == 8,
                   "delete persists and both live tiles receive the same final revision")

        let oneLaneID = UUID()
        guard let oneLane = boardRuntime.createBoard(id: oneLaneID, title: "Single lane") else {
            throw Failure(message: "could not create single-lane lifecycle fixture")
        }
        let oneLaneColumns = oneLane.orderedColumns
        _ = boardRuntime.apply(.deleteColumn(id: oneLaneColumns[2].id, reassignCardsTo: oneLaneColumns[0].id), to: oneLaneID)
        _ = boardRuntime.apply(.deleteColumn(id: oneLaneColumns[1].id, reassignCardsTo: oneLaneColumns[0].id), to: oneLaneID)
        let singleCardID = UUID()
        _ = boardRuntime.apply(
            .createTask(id: singleCardID, columnId: oneLaneColumns[0].id, title: "Only lane",
                        body: "", links: [], assignee: fixture.agentId, after: nil, before: nil),
            to: oneLaneID)
        try expect(boardRuntime.advanceAssignedTaskAfterAcceptedSend(
            boardId: oneLaneID, cardId: singleCardID, agentId: fixture.agentId) == nil,
                   "accepted send leaves a one-column board unchanged")

        try runComposerHandoff()
        // Whole-board lifecycle (`board.manage`): create, rename, delete.
        try WorkspaceAPIBoardManageChecks.run()
    }

    /// The film's RST-41 shot: an agent assigns a card to ITSELF through
    /// `array_board_apply` and moves it to Doing. The composer task chip is the
    /// user's hand-off affordance, so the caller's own composer must stay empty;
    /// a hand-off to ANOTHER agent and the user's own Assign still stage it.
    /// Driven through the production board provider (`configuredBoardRuntime`),
    /// so the real post-commit sync decides, against real agent tiles.
    private static func runComposerHandoff() throws {
        var runners: [ScriptedAgentRunner] = []
        let fixture = try WorkspaceAPIChecks.makeFixture(configureDelegate: { delegate in
            let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]!)
                .appendingPathComponent("multi-handoff-supervisor")
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: support), makeRunner: { _ in
                    let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready), .turnStarted(threadId: "handoff", turnId: "send")], holdUntilStopped: true)
                    runners.append(runner)
                    return runner
                })
        })
        defer { fixture.tearDown() }
        let supervisor = fixture.delegate.qaAgentSupervisor
        let support = fixture.tempRoot.appendingPathComponent("composer-handoff", isDirectory: true)
        let attachments = AgentComposerAttachmentStore(applicationSupportDirectory: support)
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: support, attachmentStore: attachments)

        func agentTile(_ title: String, x: Double) -> (AgentID, ManagedAgentTileNSView) {
            let tileID = UUID()
            let agentID = supervisor.spawn(
                role: nil, prompt: nil, cwd: fixture.pbRoot, harness: .pi,
                model: "openai-codex/gpt-5.6-sol", thinking: "high",
                projectId: fixture.projectPb, projectRoot: fixture.pbRoot, tileId: tileID)
            let tile = Tile(
                id: tileID, kind: .managedAgent, title: title,
                frame: TileFrame(x: x, y: 40, width: 480, height: 420),
                zPosition: .fromLegacyRank(3), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed"))
            let view = ManagedAgentTileNSView(tile: tile)
            view.attach(agentID: agentID, supervisor: supervisor)
            fixture.canvas.installProjectTile(tileView: view, for: tile, targetZoneId: fixture.zoneB)
            fixture.delegate.wireManagedAgentTile(tileID, agentID: agentID)
            view.bindV2ComposerState(draftStore: drafts, promptHistory: AgentPromptHistory(), attachmentStore: attachments)
            return (agentID, view)
        }
        let (caller, callerTile) = agentTile("Dark mode", x: 40)
        let (other, otherTile) = agentTile("Checkout", x: 560)
        try expect(fixture.canvas.tileView(for: supervisor.records[caller]?.tileId ?? UUID()) === callerTile,
                   "handoff: the calling agent's record resolves to its live tile")
        func chip(_ view: ManagedAgentTileNSView) -> UUID? {
            view.qaPageZoomComposerView?.draft.taskContext?.cardID
        }
        func pump(until predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return predicate()
        }

        guard let boardRuntime = fixture.api.boardRuntimeProvider(fixture.projectPb) else {
            throw Failure(message: "handoff: the production board provider has no runtime for the agent's project")
        }
        let boardID = UUID()
        guard let board = boardRuntime.createBoard(id: boardID, title: "Roadmap") else {
            throw Failure(message: "handoff: could not create the board fixture")
        }
        let columns = board.orderedColumns
        try expect(supervisor.setWorkspaceToolsEnabled(agentID: caller, true), "handoff: Workspace Tools enabled for the caller")

        var keys = 0
        func apply(_ fields: [String: Any], _ label: String) throws -> [String: AnyHashableJSON] {
            keys += 1
            var payload = fields
            payload["boardId"] = boardID.uuidString
            payload["expectedRevision"] = boardRuntime.board(id: boardID)?.revision ?? 0
            payload["idempotencyKey"] = "handoff-\(keys)"
            return try result(fixture.api.dispatch(
                agentId: caller, requestId: "handoff-\(keys)", op: "board.apply", payload: payload), label)
        }
        func create(_ title: String) throws -> UUID {
            let created = try apply(["op": "create", "columnId": columns[0].id.uuidString, "title": title], "create \(title)")
            guard let cardID = id(created["cardId"]) else { throw Failure(message: "handoff: create \(title) returned no cardId") }
            return cardID
        }
        let ownTask = try create("RST-41 Dark mode")
        let delegated = try create("RST-42 Cart total")
        let userTask = try create("RST-43 Receipt email")

        _ = try apply(["op": "assign", "cardId": ownTask.uuidString, "assigneeAgentId": caller.rawValue.uuidString], "self-assign")
        // Positive control in the same window: a hand-off to ANOTHER agent stages
        // that agent's chip. Once it has landed, the self-assign's async prepare
        // would have landed too.
        _ = try apply(["op": "assign", "cardId": delegated.uuidString, "assigneeAgentId": other.rawValue.uuidString], "assign other")
        try expect(pump(until: { chip(otherTile) == delegated }),
                   "handoff: an agent assigning a task to ANOTHER agent stages it in that agent's composer, unsent")
        _ = try apply(["op": "move", "cardId": ownTask.uuidString, "columnId": columns[1].id.uuidString], "move own to Doing")
        _ = pump(until: { chip(callerTile) != nil }, timeout: 0.5)
        try expect(boardRuntime.board(id: boardID)?.card(ownTask)?.assignee == caller
                   && boardRuntime.board(id: boardID)?.card(ownTask)?.columnId == columns[1].id,
                   "handoff: the self-assignment and move are durable on the board")
        try expect(chip(callerTile) == nil,
                   "handoff: an agent assigning a task to ITSELF through the workspace API stages no chip in its own composer (got \(String(describing: chip(callerTile))))")

        // The user's own Assign (menu, drag onto the agent and the task editor all
        // route through `onTaskAssign`) still stages the chip in that same composer.
        let kanban = KanbanTileNSView(tile: Tile(
            id: UUID(), kind: .kanban, title: "Roadmap",
            frame: TileFrame(x: 0, y: 0, width: 600, height: 420),
            zPosition: .fromLegacyRank(0), runtimeRef: nil,
            metadata: { var metadata = TileMetadata(); metadata.boardId = boardID; return metadata }()), board: board)
        boardRuntime.attach(kanban, to: boardID)
        try expect(kanban.onTaskAssign?(userTask, caller) == nil, "handoff: the user's Assign applies")
        try expect(pump(until: { chip(callerTile) == userTask }),
                   "handoff: a user assignment still stages the task in the agent's composer")
        let (third, thirdTile) = agentTile("Third owner", x: 1080)
        defer { for agent in [caller, other, third] { supervisor.stop(agent) } }
        guard let otherComposer = otherTile.qaPageZoomComposerView,
              let thirdComposer = thirdTile.qaPageZoomComposerView else {
            throw Failure(message: "multi-handoff: missing production composers")
        }
        let multiTask = try create("Together without sending")
        _ = boardRuntime.apply(.setCardAssignees(id: multiTask, agents: [other, third, other]), to: boardID)
        try expect(pump(until: { chip(otherTile) == multiTask && chip(thirdTile) == multiTask }),
                   "multi-handoff: one user commit automatically stages every owner through the production post-commit path")
        try expect(boardRuntime.board(id: boardID)?.card(multiTask)?.assignees == [other, third]
                   && runners.allSatisfy { $0.prompts.isEmpty },
                   "multi-handoff: duplicate owners normalize and automatic handoff never sends")
        _ = try apply(["op": "unassign", "cardId": multiTask.uuidString, "assigneeAgentId": other.rawValue.uuidString], "remove first owner")
        try expect(pump(until: { chip(otherTile) == nil }) && chip(thirdTile) == multiTask,
                   "multi-handoff: API removal clears only the removed owner's chip")
        // Keep BOTH owners assigned while the SECOND sends through the wired
        // tile/composer/supervisor acceptance hook rather than calling advance directly.
        let secondOwnerTask = try create("Second owner starts the shared task")
        _ = boardRuntime.apply(.setCardAssignees(id: secondOwnerTask, agents: [other, third]), to: boardID)
        try expect(pump(until: { chip(otherTile) == secondOwnerTask && chip(thirdTile) == secondOwnerTask && !thirdComposer.qaIsPreparingBoardTask }),
                   "multi-handoff: both owners retain context before the second owner sends")
        thirdComposer.composerRequestedSend(thirdComposer.textView)
        try expect(pump(until: { boardRuntime.board(id: boardID)?.card(secondOwnerTask)?.columnId == columns[1].id })
                   && boardRuntime.board(id: boardID)?.card(secondOwnerTask)?.assignees == [other, third],
                   "multi-handoff: second owner's accepted composer send advances the task to Doing")
        try expect(runners.reduce(0) { $0 + $1.prompts.count } == 1,
                   "multi-handoff: only the explicit accepted send reaches a scripted runner")

        let missing = AgentID(rawValue: UUID())
        let staleTask = try create("Unavailable owner does not block a handoff")
        _ = boardRuntime.apply(.setCardAssignees(id: staleTask, agents: [missing, other]), to: boardID)
        try expect(pump(until: { chip(otherTile) == staleTask }),
                   "multi-handoff: an unavailable first owner does not block another owner's automatic chip")
        _ = try apply(["op": "unassign", "cardId": staleTask.uuidString, "assigneeAgentId": missing.rawValue.uuidString], "remove stale identity")
        try expect(boardRuntime.board(id: boardID)?.card(staleTask)?.assignees == [other] && chip(otherTile) == staleTask,
                   "multi-handoff: stale identity removal preserves the available owner's context")
        _ = try apply(["op": "unassign", "cardId": staleTask.uuidString], "clear remaining owners")
        try expect(pump(until: { chip(otherTile) == nil }), "multi-handoff: clear-all removes the remaining context")

        // Hold the actual image-import completion, unassign during that await,
        // then release it. The production post-commit task must clear a late chip.
        let imageTask = try create("Remove while image preparation awaits")
        let imageStore = BoardAttachmentStore(projectRoot: fixture.pbRoot)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let validation = try AgentComposerImageValidation(validatedContentType: "image/png", pixelWidth: 4, pixelHeight: 4, byteCount: UInt64(png.count))
        var image: BoardAttachment?
        Task { image = try? await imageStore.importImage(png, filename: "assignment.png", validation: validation, boardID: boardID) }
        try expect(pump(until: { image != nil }), "multi-handoff: task image uses the project attachment store")
        let original = boardRuntime.board(id: boardID)!.card(imageTask)!
        var imageContent = BoardTaskContent(card: original); imageContent.attachments = [image!]
        _ = boardRuntime.apply(.editTask(id: imageTask, expected: BoardTaskContent(card: original), content: imageContent), to: boardID)
        var resumeImport: CheckedContinuation<Void, Never>?
        var importReleased = false
        otherComposer.qaAfterBoardTaskImageImport = {
            await withCheckedContinuation { resumeImport = $0 }
            importReleased = true
        }
        defer { otherComposer.qaAfterBoardTaskImageImport = nil; resumeImport?.resume(); resumeImport = nil }
        try expect(pump(until: { !otherComposer.qaIsPreparingBoardTask }), "multi-handoff: earlier composer preparation has completed before the image race")
        _ = try apply(["op": "assign", "cardId": imageTask.uuidString, "assigneeAgentId": other.rawValue.uuidString], "assign image task")
        try expect(pump(until: { resumeImport != nil }),
                   "multi-handoff: editing one card does not busy unrelated owners; real task image import reaches its held completion")
        _ = try apply(["op": "unassign", "cardId": imageTask.uuidString, "assigneeAgentId": other.rawValue.uuidString], "remove during image import")
        try expect(pump(until: { chip(otherTile) == nil }), "multi-handoff: removal clears the in-progress context")
        let continuation = resumeImport; resumeImport = nil; continuation?.resume()
        try expect(pump(until: { importReleased && chip(otherTile) == nil && otherComposer.draft.imageAttachments.isEmpty }),
                   "multi-handoff: completion cannot resurrect removed ownership or leave task images")
        var restored: ContinuumRevivedCore.AgentComposerDraft?
        var loadedDraft = false
        Task {
            try? await drafts.flushReportingFailure(agentID: other)
            restored = await AgentComposerDraftStore(applicationSupportDirectory: support).load(for: other)
            loadedDraft = true
        }
        try expect(pump(until: { loadedDraft }) && restored?.taskContext == nil && restored?.imageAttachments.isEmpty != false,
                   "multi-handoff: removed context stays absent in the durable composer draft")
        // Prepare remains deliberately first-owner-only. Removing existing chips
        // here separates its observable effect from automatic assignment fanout.
        let prepareTask = try create("Explicit Prepare opens first owner")
        _ = boardRuntime.apply(.setCardAssignees(id: prepareTask, agents: [caller, other]), to: boardID)
        try expect(pump(until: { chip(callerTile) == prepareTask && chip(otherTile) == prepareTask }), "multi-handoff: both Prepare-fixture owners first receive automatic context")
        var prepareFinished = false
        var prepareError: String?
        Task { @MainActor in
            await callerTile.clearBoardTask(boardID: boardID, cardID: prepareTask)
            await otherTile.clearBoardTask(boardID: boardID, cardID: prepareTask)
            prepareError = await kanban.onTaskPrepare?(prepareTask)
            prepareFinished = true
        }
        try expect(pump(until: { prepareFinished }) && prepareError == nil
                   && chip(callerTile) == prepareTask && chip(otherTile) == nil,
                   "multi-handoff: explicit Prepare retains its intentional first-owner-only behavior")

    }
}
