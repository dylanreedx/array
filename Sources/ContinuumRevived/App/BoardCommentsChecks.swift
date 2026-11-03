import AppKit
import WebKit
import ContinuumRevivedCore

@MainActor
enum BoardCommentsChecks {
    struct Failure: Error { let message: String }
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else { throw Failure(message: "requires isolated support and dev binary") }
        func require(_ yes: Bool, _ message: String) throws {
            guard yes else { throw Failure(message: message) }
            print("board-comments: PASS \(message)")
        }
        let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready), .turnStarted(threadId: "comment-thread", turnId: "comment-turn")], holdUntilStopped: true)
        var fixtureSupervisor: AgentSupervisor?
        let f = try WorkspaceAPIChecks.makeFixture(configureDelegate: { delegate in
            let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]!)
            let attachments = AgentComposerAttachmentStore(applicationSupportDirectory: support)
            let queue = AgentComposerDraftStore(applicationSupportDirectory: support, attachmentStore: attachments)
            let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: support), makeRunner: { _ in runner }, attachmentStore: attachments, submissionRecoveryStore: queue)
            delegate.agentSupervisor = supervisor
            fixtureSupervisor = supervisor
        })
        defer { f.tearDown() }
        let suiteName = "array.check.comments.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: AgentCharacterConfig.enabledKey)
        AgentCharacterController.shared.adopt(defaults: suite)
        _ = f.delegate.qaAgentSupervisor.setIdentityColor(agentID: f.agentId, "purple")
        guard let owner = f.runtime.controller(for: f.projectPb) else { throw Failure(message: "production mount has no project controller") }
        let runtime = f.delegate.configuredBoardRuntime(owner)
        try require(runtime.commentDeliveryForQA != nil, "production mount configures comment delivery")
        _ = f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        let boardID = UUID(), cardID = UUID()
        guard let board = runtime.createBoard(id: boardID, title: "Comment review") else { throw Failure(message: "could not persist the board fixture") }
        _ = runtime.apply(.createCard(id: cardID, columnId: board.orderedColumns[0].id, title: "Discuss the next iteration", after: nil, before: nil), to: boardID)
        let user = BoardComment(authorID: "local", authorName: "You", createdAt: Date(timeIntervalSince1970: 1_793_620_800), body: "Can you share an **update**?")
        _ = runtime.apply(.addComment(cardID: cardID, comment: user), to: boardID)
        try require(try f.storePb.loadBoard(id: boardID).card(cardID)?.comments == [user], "production reducer persists comments")
        runtime.history(for: boardID).undoManager.undo()
        try require(runtime.board(id: boardID)?.card(cardID)?.comments.isEmpty == true, "board Undo removes the comment")
        runtime.history(for: boardID).undoManager.redo()
        let payload: [String: Any] = ["op": "comment", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
            "expectedRevision": runtime.board(id: boardID)!.revision, "idempotencyKey": "comment-reply", "body": "The **first pass** is ready."]
        guard case .result = f.api.dispatch(agentId: f.agentId, requestId: "comment-reply", op: "board.apply", payload: payload) else { throw Failure(message: "workspace API comment failed") }
        guard case .result = f.api.dispatch(agentId: f.agentId, requestId: "comment-replay", op: "board.apply", payload: payload) else { throw Failure(message: "idempotent replay failed") }
        try require(runtime.board(id: boardID)!.card(cardID)!.comments.count == 2, "API comment and idempotent retry yield exactly one new comment")
        let forbidden: [String: Any] = ["op": "editComment", "boardId": boardID.uuidString, "cardId": cardID.uuidString, "commentId": user.id.uuidString,
            "expectedRevision": runtime.board(id: boardID)!.revision, "idempotencyKey": "forbidden-edit", "body": "Forged edit"]
        guard case .error = f.api.dispatch(agentId: f.agentId, requestId: "forbidden-edit", op: "board.apply", payload: forbidden) else { throw Failure(message: "agent edited the user's comment") }
        try require(runtime.board(id: boardID)!.card(cardID)!.comments.first == user, "API rejects editing another author's comment")
        let card = runtime.board(id: boardID)!.card(cardID)!
        try require(card.comments.count == 2 && card.comments.last?.authorID == f.agentId.rawValue.uuidString.lowercased(), "API supplies agent identity and persists reply")
        guard case .result(let query) = f.api.dispatch(agentId: f.agentId, requestId: "comment-read", op: "board.query", payload: ["boardId": boardID.uuidString, "cardId": cardID.uuidString]) else { throw Failure(message: "query failed") }
        try require(query["board"]?.object?["cards"]?.array?.first?.object?["comments"]?.array?.count == 2, "workspace card read includes the thread")
        let model = Tile(id: UUID(), kind: .kanban, title: board.title, frame: TileFrame(x: 0, y: 0, width: 800, height: 700), zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: TileMetadata())
        let view = KanbanTileNSView(tile: model, board: runtime.board(id: boardID)!)
        runtime.attach(view, to: boardID)
        let detail = BoardTaskDetailController(tile: view, card: card)
        let web = detail.qaEditor
        web.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        for _ in 0..<400 {
            if (try? await web.evaluateJavaScript("typeof window.taskEditor")) as? String == "object" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Production snapshot/renderer, without mounting or ordering a window.
        await detail.qaLoadComments()
        let count = try await web.evaluateJavaScript("document.querySelectorAll('.comment').length") as? Int
        try require(count == 2, "native task editor renders the API reply")
        try require((try await web.evaluateJavaScript("document.querySelectorAll('.comment-author img').length")) as? Int == 1, "agent reply renders its character from host attribution")
        try require((try await web.evaluateJavaScript("document.querySelector('.comment strong')?.textContent")) as? String == "update", "thread renders Markdown")
        let colour = ZoneChromeNSView.color(named: "purple").usingColorSpace(.deviceRGB)!
        let expectedColour = "rgb(\(Int(colour.redComponent * 255)), \(Int(colour.greenComponent * 255)), \(Int(colour.blueComponent * 255)))"
        try require((try await web.evaluateJavaScript("getComputedStyle(document.querySelectorAll('.comment-author b')[1]).color")) as? String == expectedColour, "agent reply uses its identity colour")
        _ = try await web.evaluateJavaScript("document.getElementById('comment-body').value='A comment from the task editor'; document.getElementById('post-comment').click(); document.getElementById('post-comment').click();")
        for _ in 0..<100 where runtime.board(id: boardID)!.card(cardID)!.comments.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
        try require(runtime.board(id: boardID)!.card(cardID)!.comments.count == 3, "composer bridge adds exactly one durable comment on a double click")
        runtime.history(for: boardID).undoManager.undo()
        try require(runtime.board(id: boardID)!.card(cardID)!.comments.count == 2, "composer comment uses the board Undo stack")
        runtime.history(for: boardID).undoManager.redo()
        await detail.qaLoadComments()
        _ = try await web.evaluateJavaScript("[...document.querySelectorAll('.comment')].at(-1).querySelector('.comment-edit').click(); document.getElementById('comment-body').value='Edited from the task editor'; document.getElementById('post-comment').click();")
        for _ in 0..<100 where runtime.board(id: boardID)!.card(cardID)!.comments.last?.body != "Edited from the task editor" { try await Task.sleep(for: .milliseconds(10)) }
        try require(runtime.board(id: boardID)!.card(cardID)!.comments.last?.body == "Edited from the task editor", "own comment edits pass through the native bridge")
        _ = try await web.evaluateJavaScript("[...document.querySelectorAll('.comment')].at(-1).querySelectorAll('button')[1].click()")
        for _ in 0..<100 where runtime.board(id: boardID)!.card(cardID)!.comments.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        try require(runtime.board(id: boardID)!.card(cardID)!.comments.count == 2, "own comment deletion passes through the native bridge")
        runtime.history(for: boardID).undoManager.undo()
        await detail.qaLoadComments()
        let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("array-scratch/card-comments")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [true, false] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = appearance
            view.appearance = appearance
            await detail.qaLoadComments()
            _ = try await web.evaluateJavaScript("window.taskEditor.theme(\(dark ? "{bg:'#14171c',card:'#1c212a',text:'#e9ebef',muted:'#a3aab5',line:'#414751',accent:'#9db7ff',mode:'dark'}" : "{bg:'#ffffff',card:'#f5f6f8',text:'#202329',muted:'#6b7079',line:'#e2e5ea',accent:'#4262dc',mode:'light'}"))")
            try await Task.sleep(for: .milliseconds(150))
            // Offscreen WebKit can suspend the CSS transition clock. Capture
            // the settled appearance, with the same final-colour assertion.
            _ = try await web.evaluateJavaScript("document.getAnimations().forEach(animation => animation.finish())")
            let background = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('status')).backgroundColor") as? String
            try require(background == (dark ? "rgb(28, 33, 42)" : "rgb(245, 246, 248)"), "choice surfaces follow the \(dark ? "dark" : "light") appearance (\(background ?? "nil"))")
            let image = try await web.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw Failure(message: "could not render comment still") }
            try png.write(to: output.appendingPathComponent(dark ? "dark.png" : "light.png"))
            _ = try await web.evaluateJavaScript("(() => { const pane=document.querySelector('.document'); pane.scrollTop += document.querySelector('.comment-thread').getBoundingClientRect().top-pane.getBoundingClientRect().top-24; window.scrollTo(0,0); })()")
            try await Task.sleep(for: .milliseconds(200))
            let threadImage = try await web.takeSnapshot(configuration: nil)
            guard let threadTIFF = threadImage.tiffRepresentation, let threadRep = NSBitmapImageRep(data: threadTIFF), let threadPNG = threadRep.representation(using: .png, properties: [:]) else { throw Failure(message: "could not render thread still") }
            try threadPNG.write(to: output.appendingPathComponent(dark ? "dark-thread.png" : "light-thread.png"))
            _ = try await web.evaluateJavaScript("document.querySelector('.document').scrollTop=0")
        }
        view.readOnlyOwner = "Collaborator"
        await detail.qaLoadComments()
        try require((try await web.evaluateJavaScript("document.getElementById('comment-compose').hidden")) as? Bool == true, "portal read-only snapshot hides posting")
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: ["fixture-model"], displayNames: ["fixture-model": "Fixture"], contextWindows: ["fixture-model": 10000]))
        guard let supervisor = fixtureSupervisor else { throw Failure(message: "missing fixture supervisor") }
        let recipient = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: "fixture-model", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot, displayName: "Comment recipient")
        let sender = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: "fixture-model", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot, displayName: "Comment sender")
        defer { supervisor.stop(recipient); supervisor.stop(sender) }
        _ = supervisor.setWorkspaceToolsEnabled(agentID: recipient, true)
        _ = supervisor.setWorkspaceToolsEnabled(agentID: sender, true)
        func agentComment(_ agent: AgentID, _ body: String, _ key: String) throws {
            let payload: [String: Any] = ["op": "comment", "boardId": boardID.uuidString, "cardId": cardID.uuidString,
                "body": body, "expectedRevision": runtime.board(id: boardID)!.revision, "idempotencyKey": key]
            guard case .result = f.api.dispatch(agentId: agent, requestId: key, op: "board.apply", payload: payload) else { throw Failure(message: "agent progress API rejected \(key)") }
        }
        var outcomes: [String] = []
        runtime.commentDeliveryForQA?.onOutcome = { _, outcome in outcomes.append(outcome) }
        _ = runtime.apply(.editCard(id: cardID, title: "Discuss the next iteration " + String(repeating: "context ", count: 2000), body: nil), to: boardID)
        _ = runtime.apply(.assignCard(id: cardID, to: recipient), to: boardID)
        _ = runtime.apply(.addComment(cardID: cardID, comment: BoardComment(authorID: "local", authorName: "You", createdAt: Date(), body: "Please review the iteration")), to: boardID)
        for _ in 0..<500 where !outcomes.contains("delivered") || runner.prompts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try require(outcomes.contains("delivered") && runner.prompts.contains(where: { $0.contains("Please review the iteration") && $0.contains("Discuss the next iteration") }), "assigned comment reaches the real supervisor runner as a turn")
        try require(runner.prompts.first.map { $0.utf8.count < 4096 && $0.contains("…") } == true, "delivery bounds oversized titles and thread context")
        _ = runtime.apply(.addComment(cardID: cardID, comment: BoardComment(authorID: "local", authorName: "You", createdAt: Date(), body: "Follow up while busy")), to: boardID)
        for _ in 0..<500 where !outcomes.contains("queued") { try await Task.sleep(for: .milliseconds(10)) }
        try require(outcomes.contains("queued") && runner.prompts.count == 1 && supervisor.queuedMessages(for: recipient).contains(where: { $0.text.contains("Follow up while busy") }), "busy agent queues without interrupting its turn")
        try agentComment(recipient, "Progress update", "own-progress")
        try require(outcomes.contains("quiet_self"), "own progress comment never retriggers its author")
        for i in 0..<8 {
            let from = i.isMultiple(of: 2) ? recipient : sender
            let to = i.isMultiple(of: 2) ? sender : recipient
            try agentComment(from, "@\(to.rawValue.uuidString) next", "mention-chain-\(i)")
        }
        try require(outcomes.contains("quiet_chain_limit"), "agent mention chains stop at the host hop cap")
        await runtime.commentDeliveryForQA?.waitForPendingDeliveriesForQA()
        try require(!outcomes.contains(where: { $0.hasPrefix("failed_") }), "accepted comment deliveries have no hidden admission failures")
        let missing = AgentID(rawValue: UUID())
        _ = runtime.apply(.assignCard(id: cardID, to: missing), to: boardID)
        _ = runtime.apply(.addComment(cardID: cardID, comment: BoardComment(authorID: "local", authorName: "You", createdAt: Date(), body: "Keep this even if the assignee was removed")), to: boardID)
        try require(outcomes.contains("unavailable") && runtime.board(id: boardID)!.card(cardID)!.comments.last?.body.contains("assignee was removed") == true, "missing recipients leave the durable comment intact and report unavailable")
        print("board-comments: persistence, Undo, API, Markdown, guest thread, delivery, queue and loop guard passed")
    }
}
