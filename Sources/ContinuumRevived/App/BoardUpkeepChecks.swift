import AppKit
import ContinuumRevivedCore

/// `--board-upkeep-check`: boards stay current without anyone remembering.
/// Driven through the real `array-workspace-mcp` helper, the production
/// `agent.delegate`, supervisor spawn and Claude runner, into a disposable CLI.
/// The helper's board calls go through the server its own launch configured,
/// so the tool list it was given is the one being tested. No model or network.
@MainActor
enum BoardUpkeepChecks {
    typealias Checks = HelperRetryWorktreeChecks
    typealias Launched = ManagedModeChecks.LaunchedServer

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(condition(), "board-upkeep: " + message)
        print("board-upkeep: PASS \(message)")
    }

    /// One `tools/call` through a server exactly as the CLI started it.
    static func call(_ server: Launched, _ tool: String, _ arguments: [String: Any]) async throws -> (isError: Bool, reply: [String: Any], raw: String) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: server.command)
        process.arguments = server.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(server.environment) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let lines: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:] as [String: Any]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]],
        ]
        for line in lines { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: line) + Data([10])) }
        try input.fileHandleForWriting.close()
        // The host answers on this (main) actor: read off it.
        let text = try await awaitOutput(output, process)
        for line in text.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == 2 else { continue }
            if let result = object["result"] as? [String: Any] {
                return (result["isError"] as? Bool ?? false, result["structuredContent"] as? [String: Any] ?? [:], String(decoding: line, as: UTF8.self))
            }
            return (true, object["error"] as? [String: Any] ?? [:], String(decoding: line, as: UTF8.self))
        }
        return (true, [:], String(decoding: text, as: UTF8.self))
    }

    private static func awaitOutput(_ pipe: Pipe, _ process: Process) async throws -> Data {
        final class Box: @unchecked Sendable { var data = Data(); var done = false; let lock = NSLock() }
        let box = Box()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            box.lock.withLock { box.data = data; box.done = true }
        }
        guard await waitUntil(timeout: 60, pollInterval: 0.01, { box.lock.withLock { box.done } }) else {
            process.terminate()
            throw WorkspaceAgentReportChecks.Failure(description: "board-upkeep: the MCP server did not answer within 60 s")
        }
        return box.lock.withLock { box.data }
    }

    static func errorCode(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    static func firstPrompt(_ b: Checks.Bench, _ id: AgentID) async throws -> String {
        let capture = try await Checks.capture(b, id)
        return String(decoding: try JSONSerialization.data(withJSONObject: capture["prompt"] ?? ""), as: UTF8.self)
    }

    static func release(_ b: Checks.Bench, _ id: AgentID) throws {
        guard let record = b.supervisor.records[id] else { return }
        let sid = AgentSupervisor.claudeRunnerConfig(for: record).sessionId
        try Data().write(to: URL(fileURLWithPath: record.cwd).appendingPathComponent("managed-release-" + sid))
    }

    static func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }

    static func run() async throws {
        let b = try Checks.bench("board-upkeep"); defer { b.tearDown() }
        let f = b.f, supervisor = b.supervisor, lead = f.agentId
        try expect(supervisor.rename(agentID: lead, to: "Lead"), "lead rename accepted")
        guard let projectId = supervisor.records[lead]?.projectId, let runtime = f.api.boardRuntimeProvider(projectId) else {
            throw WorkspaceAgentReportChecks.Failure(description: "board-upkeep: the lead's project has no production board runtime")
        }
        try expect(f.runtime.mountedProjectIds.contains(projectId), "the lead's project is mounted, so the production sweep reads its boards")
        let boardID = UUID()
        guard let initial = runtime.createBoard(id: boardID, title: "Release board") else {
            throw WorkspaceAgentReportChecks.Failure(description: "board-upkeep: could not create the board")
        }
        let columns = initial.orderedColumns
        let (todo, doing, done) = (columns[0].id, columns[1].id, columns[2].id)
        func addCard(_ title: String) throws -> UUID {
            let id = UUID()
            guard case .applied = runtime.apply(.createTask(id: id, columnId: todo, title: title, body: "", links: [], assignee: nil, after: nil, before: nil), to: boardID) else {
                throw WorkspaceAgentReportChecks.Failure(description: "board-upkeep: could not create task \(title)")
            }
            return id
        }
        let cardA = try addCard("Ship the settings pane")
        let cardB = try addCard("Tidy the release notes")
        let other = try addCard("Someone else's task")
        func card(_ id: UUID) -> BoardCard? { runtime.board(id: boardID)?.card(id) }
        var metadata = TileMetadata(); metadata.boardId = boardID
        let view = KanbanTileNSView(tile: Tile(id: UUID(), kind: .kanban, title: "Release board",
            frame: TileFrame(x: 0, y: 0, width: 760, height: 460), zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: metadata),
            board: runtime.board(id: boardID)!)
        runtime.attach(view, to: boardID)

        // 1. array_delegate with cardId: assigned, moved to Doing, named in the prompt.
        let leadMCP = try b.configuration(for: lead)
        let missing = try await WorkspaceAgentReportChecks.call(leadMCP, "array_delegate", ["task": "x", "idempotencyKey": UUID().uuidString,
            "harness": "Claude Code", "model": ManagedModeChecks.model, "cardId": UUID().uuidString])
        try expect(missing.isError && WorkspaceAgentReportChecks.errorCode(missing) == "not_found", "an unknown cardId delegates nothing (\(WorkspaceAgentReportChecks.errorCode(missing) ?? "ok"))")
        let delegated = try await WorkspaceAgentReportChecks.call(leadMCP, "array_delegate", ["task": "HOLD build the pane", "title": "pane",
            "harness": "Claude Code", "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString, "cardId": cardA.uuidString])
        let helper = try Checks.child(delegated)
        try expect(card(cardA)?.assignees == [helper], "the delegated helper is assigned to the card")
        try expect(card(cardA)?.columnId == doing, "the card moved to Doing when the delegation committed")
        let prompt = try await firstPrompt(b, helper)
        try expect(prompt.contains(cardA.uuidString) && prompt.contains(boardID.uuidString) && prompt.contains("Ship the settings pane"),
                   "the helper's first prompt names the card, its board and its title")

        // 2. The helper's own launch serves the board pair, still lean.
        let server = try ManagedModeChecks.claudeServer(b, helper)
        let names = ManagedModeChecks.names(try ManagedModeChecks.listedTools(server))
        try expect(names == Set(HelperLeanStart.tools) && names.contains("array_board_query") && names.contains("array_board_apply"),
                   "the helper's launched MCP server lists array_board_query and array_board_apply among its lean tools: \(names.sorted())")
        let query = try await call(server, "array_board_query", ["boardId": boardID.uuidString, "cardId": cardA.uuidString])
        let queried = ((query.reply["result"] as? [String: Any])?["board"] as? [String: Any])?["cards"] as? [[String: Any]]
        try expect(!query.isError && queried?.first?["cardId"] as? String == cardA.uuidString,
                   "the helper reads its own card through its own server: \(query.raw.prefix(600))")
        let revision = runtime.board(id: boardID)!.revision
        let comment = try await call(server, "array_board_apply", ["op": "comment", "boardId": boardID.uuidString, "cardId": cardA.uuidString,
            "body": "Halfway: pane layout done.", "expectedRevision": revision, "idempotencyKey": UUID().uuidString])
        try expect(!comment.isError && card(cardA)?.comments.last?.authorID == helper.rawValue.uuidString.lowercased(),
                   "the helper comments on its own card, under its own name: \(comment.raw.prefix(300))")
        let move = try await call(server, "array_board_apply", ["op": "move", "boardId": boardID.uuidString, "cardId": cardA.uuidString,
            "columnId": done.uuidString, "expectedRevision": runtime.board(id: boardID)!.revision, "idempotencyKey": UUID().uuidString])
        try expect(move.isError && errorCode(move.reply) == "permission_denied" && card(cardA)?.columnId == doing,
                   "the helper may not move its card; the lead keeps that right")
        let foreign = try await call(server, "array_board_apply", ["op": "comment", "boardId": boardID.uuidString, "cardId": other.uuidString,
            "body": "not mine", "expectedRevision": runtime.board(id: boardID)!.revision, "idempotencyKey": UUID().uuidString])
        try expect(foreign.isError && errorCode(foreign.reply) == "permission_denied" && card(other)?.comments.isEmpty == true,
                   "the helper may not comment on a card it is not assigned to")
        let leadMove = try await WorkspaceAgentReportChecks.call(leadMCP, "array_board_apply", ["op": "move", "boardId": boardID.uuidString,
            "cardId": other.uuidString, "columnId": doing.uuidString, "expectedRevision": runtime.board(id: boardID)!.revision,
            "idempotencyKey": UUID().uuidString])
        try expect(!leadMove.isError && card(other)?.columnId == doing, "the lead's broader board rights are unchanged")
        _ = runtime.apply(.moveCard(id: other, toColumn: todo, after: nil, before: nil), to: boardID)

        // 3. The report lands on the card once, across a retry and the run's end.
        let report: [String: Any] = ["summary": "Settings pane built; one leg left.", "checks": [["what": "--settings-check", "result": "fail"]]]
        for attempt in 1...2 {
            let filed = try await call(server, "array_report", report)
            try expect(!filed.isError, "array_report attempt \(attempt) is recorded")
        }
        func reportComments(_ id: UUID) -> [BoardComment] { card(id)?.comments.filter { $0.body.hasPrefix("Report: ") } ?? [] }
        try expect(reportComments(cardA).count == 1 && reportComments(cardA)[0].body.contains("Check fail: --settings-check"),
                   "the report summary is posted once on the card, failed check included, though it was filed twice")
        try release(b, helper)
        try await AgentPresenceChecks.eventually("the helper's run did not end", timeout: 15) { !supervisor.isRunning(helper) && supervisor.records[helper]?.latestTerminalEvent != nil }
        await settle()
        try expect(reportComments(cardA).count == 1 && card(cardA)?.comments.contains { $0.body.hasPrefix("Run ") } == false,
                   "the run ending after its report posts nothing more")
        try expect(card(cardA)?.columnId == doing, "Array never moves the card to Done")

        // 4. A run that ends without a report says so once.
        let quiet = try Checks.child(try await WorkspaceAgentReportChecks.call(leadMCP, "array_delegate", ["task": "tidy notes", "title": "notes",
            "harness": "Claude Code", "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString, "cardId": cardB.uuidString]))
        try await AgentPresenceChecks.eventually("the quiet helper did not finish", timeout: 15) {
            !supervisor.isRunning(quiet) && supervisor.records[quiet]?.latestTerminalEvent != nil
        }
        await settle()
        f.api.helperRunEnded(quiet) // a second delivery of the same end
        try expect(card(cardB)?.comments.filter { $0.body.hasPrefix("Run ended") }.count == 1 && card(cardB)?.columnId == doing,
                   "a run that ends without a report posts one line, once, and leaves the card in Doing")

        // 5. Stale: quiet after the grace, one nudge, shown on the tile.
        let base = Date()
        f.api.boardUpkeepNow = { base.addingTimeInterval(5 * 60) }
        try expect(f.api.sweepBoardUpkeep().isEmpty, "inside the grace period nothing is stale")
        f.api.boardUpkeepNow = { base.addingTimeInterval(BoardUpkeep.finishedGrace + 60) }
        let nudgesBefore = f.api.boardUpkeepNudgeCount
        let stale = f.api.sweepBoardUpkeep()
        try expect(stale == [cardA, cardB], "both cards whose helpers finished are stale; the unassigned one is not: \(stale.count)")
        try expect(f.api.boardUpkeepNudgeCount == nudgesBefore + 2, "each stale card's lead got one nudge")
        _ = f.api.sweepBoardUpkeep()
        try expect(f.api.boardUpkeepNudgeCount == nudgesBefore + 2, "a second sweep nudges nobody again")
        view.layoutSubtreeIfNeeded()
        try expect(view.cardView(for: cardA)?.qaMetaText.hasPrefix("Stale") == true && view.cardView(for: other)?.qaMetaText.contains("Stale") != true,
                   "the board tile marks the stale card, and only it: \(view.cardView(for: cardA)?.qaMetaText ?? "nil")")

        if let directory = ProcessInfo.processInfo.environment["ARRAY_BOARD_UPKEEP_STILLS"] {
            try writeStills(view, to: URL(fileURLWithPath: directory, isDirectory: true), runtime: runtime)
        }
        print("Board upkeep checks passed: a helper's own launch serves the board pair and may comment, edit and assign only on its own card; array_delegate with cardId assigns, moves to Doing and names the card; a report lands once across a retry and the run's end; a quiet run says so once; stale cards show on the tile and nudge their lead once; nothing moves to Done")
    }

    static func writeStills(_ view: KanbanTileNSView, to directory: URL, runtime: BoardRuntime) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 460)
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let stale = view.staleCardIDs
        for (name, ids) in [("board-tile-before", Set<UUID>()), ("board-tile-stale", stale)] {
            view.staleCardIDs = ids
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded()
                view.display()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-\(label).png"))
            }
        }
        view.staleCardIDs = stale
    }
}
