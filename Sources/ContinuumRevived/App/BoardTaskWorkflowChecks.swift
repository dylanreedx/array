import AppKit
import WebKit
import ContinuumRevivedCore

@MainActor
enum BoardTaskWorkflowChecks {
    static func run() async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "BoardTaskWorkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("board-task-workflow: PASS " + message)
        }
        let editorURL = BoardTaskDetailController.editorURL
        try require(editorURL != nil && FileManager.default.fileExists(atPath: editorURL!.deletingLastPathComponent().appendingPathComponent("editor.js").path), "editor assets resolve beside the running application")
        if Bundle.main.bundleURL.pathExtension == "app" {
            try require(editorURL!.path.hasPrefix(Bundle.main.resourceURL!.path + "/"), "installed editor resolves only from packaged app resources")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-task-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkModal(root: root)
        let images = AgentComposerAttachmentStore(applicationSupportDirectory: root)
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: root, attachmentStore: images)
        let tasks = BoardAttachmentStore(projectRoot: root)
        let agent = AgentID(rawValue: UUID())
        let sink = TaskWorkflowSink()
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        composer.bindAttachmentStore(images, agentID: agent)
        composer.bindDraftStore(drafts, agentID: agent)
        composer.bindActionSink(sink, agentID: agent, snapshot: AgentTileTurnSnapshot(state: .ready, capabilities: AgentTurnCapabilities(canSend: true), turnStartedAt: nil))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let validation = try AgentComposerImageValidation(validatedContentType: "image/png", pixelWidth: 20, pixelHeight: 10, byteCount: UInt64(data.count))
        let boardID = UUID()
        let taskImage = try await tasks.importImage(data, filename: "Screenshot.png", validation: validation, boardID: boardID)
        let ownImage = try await images.importValidatedPastedImage(data, displayName: "My own image.png", validation: validation, forDraftOf: agent)
        var card = BoardCard(id: UUID(), columnId: UUID(), position: .fromLegacyRank(0), title: "Review layout", body: "Use this ![Screenshot](" + taskImage.imageURL + ")", attachments: [taskImage], createdAt: Date(), updatedAt: Date())
        // Await binding through the actual prepare seam, then add independent user content.
        try await composer.prepareBoardTask(boardID: boardID, card: card, revision: 1, store: tasks)
        var current = composer.draft
        current.text = "Keep keyboard access"; current.selection = NSRange(location: 20, length: 0)
        current.imageAttachments.append(ownImage.promptAttachment)
        composer.apply(current)
        card.title = "Review updated layout"
        try await composer.prepareBoardTask(boardID: boardID, card: card, revision: 2, store: tasks)
        try require(sink.prompts.isEmpty, "preparing and refreshing context never sends")
        try require(composer.draft.text == "Keep keyboard access", "refresh preserves independent instructions")
        try require(composer.draft.imageAttachments.count == 2 && composer.draft.imageAttachments.contains(ownImage.promptAttachment), "refresh deduplicates task images and preserves independent image")
        try require(composer.draft.taskContext?.title == card.title, "same-task prepare refreshes snapshot")
        let disk = AgentComposerDraftStore(applicationSupportDirectory: root)
        let restored = await disk.load(for: agent)
        try require(restored?.taskContext == composer.draft.taskContext && restored?.text == composer.draft.text, "context and independent text survive a fresh store")
        await composer.clearBoardTask(boardID: boardID, cardID: card.id)
        try require(composer.draft.taskContext == nil && composer.draft.text == "Keep keyboard access", "unassignment removes task context and preserves independent instructions")
        try require(composer.draft.imageAttachments == [ownImage.promptAttachment], "unassignment removes only task-owned images")
        let focusWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let focusHost = NSView(frame: focusWindow.contentLayoutRect)
        let focusProbe = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
        focusWindow.contentView = focusHost
        focusHost.addSubview(composer)
        focusHost.addSubview(focusProbe)
        focusWindow.makeFirstResponder(focusProbe)
        let responderBeforeAssignment = focusWindow.firstResponder
        try await composer.prepareBoardTask(
            boardID: boardID,
            card: card,
            revision: 3,
            store: tasks,
            focusComposer: false,
            confirmReplacement: false
        )
        try require(composer.draft.taskContext?.cardID == card.id && composer.draft.text == "Keep keyboard access", "assignment attaches visible task context without sending or replacing agent text")
        try require(focusWindow.firstResponder === responderBeforeAssignment, "background assignment does not steal focus into the agent composer")
        var acceptedTaskContexts: [BoardTaskContext] = []
        composer.onAcceptedBoardTask = { acceptedTaskContexts.append($0) }
        composer.composerRequestedSend(composer.textView)
        for _ in 0..<100 where sink.prompts.isEmpty || acceptedTaskContexts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try require(sink.prompts.count == 1, "explicit send reaches the existing sink exactly once")
        try require(acceptedTaskContexts.count == 1 && acceptedTaskContexts[0].cardID == card.id,
                    "accepted-send hook receives the attached task captured before the composer clears")
        try require(sink.prompts[0].text.contains(card.title) && sink.prompts[0].text.contains("Keep keyboard access") && sink.prompts[0].imageAttachments.count == 2, "explicit send contains task, instructions and both images")
        let refusedAgent = AgentID(rawValue: UUID())
        let refusedSink = TaskWorkflowSink()
        refusedSink.acceptance = .refused(.turnNotReady)
        let refusedComposer = AgentComposerView(frame: composer.frame)
        refusedComposer.bindAttachmentStore(images, agentID: refusedAgent)
        refusedComposer.bindDraftStore(drafts, agentID: refusedAgent)
        refusedComposer.bindActionSink(
            refusedSink, agentID: refusedAgent,
            snapshot: AgentTileTurnSnapshot(
                state: .ready, capabilities: AgentTurnCapabilities(canSend: true), turnStartedAt: nil))
        var refusedTaskContexts: [BoardTaskContext] = []
        refusedComposer.onAcceptedBoardTask = { refusedTaskContexts.append($0) }
        try await refusedComposer.prepareBoardTask(boardID: boardID, card: card, revision: 4, store: tasks)
        refusedComposer.composerRequestedSend(refusedComposer.textView)
        for _ in 0..<100 where refusedSink.prompts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try require(refusedTaskContexts.isEmpty,
                    "a refused send never invokes the attached-task lifecycle hook")
        let original = try await tasks.read(boardID: boardID, attachmentID: taskImage.id)
        try require(original == data, "composer preparation and send preserve the project-owned original")
    }
    private static func checkModal(root: URL) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "TaskModal", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("board-task-workflow: PASS " + message)
        }
        let store = ProjectStore(projectRoot: root)
        let column = BoardColumn(id: UUID(), name: "To do", position: .fromLegacyRank(0))
        let card = BoardCard(id: UUID(), columnId: column.id, position: .fromLegacyRank(0), title: "Modal fixture", createdAt: Date(), updatedAt: Date())
        let board = Board(id: UUID(), title: "Tasks", columns: [column], cards: [card])
        try store.saveBoard(board)
        let tile = Tile(id: UUID(), kind: .kanban, title: "Tasks", frame: TileFrame(x: 0, y: 0, width: 400, height: 400), zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: TileMetadata())
        let view = KanbanTileNSView(tile: tile, board: board)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host; host.addSubview(view)
        let runtime = BoardRuntime(projectStore: store)
        runtime.attach(view, to: board.id)
        let detail = BoardTaskDetailController(tile: view, card: card)
        detail.present()
        let editor = detail.qaEditor
        try require(!BoardTaskDetailController.isPresented(in: window) && editor.isHidden, "task modal stays completely detached until its populated document is ready")
        var loaded = false
        for _ in 0..<200 {
            if (try? await editor.evaluateJavaScript("document.getElementById('title')?.value")) as? String == card.title,
               BoardTaskDetailController.isPresented(in: window) { loaded = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(loaded, "in-app editor loads the actual saved task")
        try require(!editor.isHidden, "task editor reveals only after its populated document is ready")
        try require(detail.window === window, "task details use the existing canvas window")
        let shield = host.subviews.last!
        try require(host.hitTest(NSPoint(x: 4, y: 4)) === shield, "modal backdrop blocks clicks through to the canvas")
        host.setFrameSize(NSSize(width: 850, height: 640))
        host.layoutSubtreeIfNeeded(); shield.layoutSubtreeIfNeeded()
        try require(shield.frame == host.bounds && shield.subviews.allSatisfy { shield.bounds.contains($0.frame) }, "modal stays inside the resized host window")
        host.setFrameSize(NSSize(width: 1100, height: 800))
        // DOM is authoritative even when its last change has not crossed the bridge.
        _ = try await editor.evaluateJavaScript("document.getElementById('title').value = 'Last keystroke survives close'")
        BoardTaskDetailController.dismissPresented(in: window)
        for _ in 0..<200 where BoardTaskDetailController.isPresented(in: window) { try await Task.sleep(for: .milliseconds(25)) }
        try require(!BoardTaskDetailController.isPresented(in: window) && runtime.board(id: board.id)?.card(card.id)?.title == "Last keystroke survives close", "native dismissal saves the live editor snapshot before removing the modal")
        let latest = runtime.board(id: board.id)!.card(card.id)!
        let failed = BoardTaskDetailController(tile: view, card: latest)
        failed.present()
        let second = failed.qaEditor
        for _ in 0..<200 {
            if (try? await second.evaluateJavaScript("document.getElementById('title')?.value")) as? String == latest.title,
               BoardTaskDetailController.isPresented(in: window) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        view.boardRuntime = nil
        _ = try await second.evaluateJavaScript("document.getElementById('title').value = 'Retain unsaved edit'")
        BoardTaskDetailController.dismissPresented(in: window)
        var message = ""
        for _ in 0..<200 {
            message = (try? await second.evaluateJavaScript("document.getElementById('error').textContent")) as? String ?? ""
            if !message.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(BoardTaskDetailController.isPresented(in: window) && message.contains("no longer available"), "failed save keeps the modal and unsaved edit available")
        view.boardRuntime = runtime
        _ = failed.finishBeforeOpeningAnother()
    }
}

@MainActor
private final class TaskWorkflowSink: AgentTileActionSink {
    var prompts: [AgentPrompt] = []
    var acceptance: IntentAcceptance = .accepted
    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        if case .sendPrompt(let prompt) = intent { prompts.append(prompt) }
        return acceptance
    }
}
