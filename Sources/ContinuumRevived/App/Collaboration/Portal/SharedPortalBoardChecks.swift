import AppKit
import WebKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// `--portal-board-check [dir]`: a board tile through the portal contract. On a
/// mounted production canvas it fills a real board through the host's own
/// reducer (`BoardRuntime.apply`), runs the board kind's real `snapshot` and
/// `observe`, carries every revision through the wire's JSON encoding (ISO 8601
/// dates, blobs as base64, as `CollaborationAPI` sends them), and hands it to
/// the kind's real guest view. The guest must draw the host's own
/// `KanbanTileNSView`: the same columns, cards, assignees, links and pictures,
/// a card body as Markdown in the task editor, live host moves, and no route
/// for a guest edit. Light and dark stills, off screen.
@MainActor
enum SharedPortalBoardChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        print("PASS portal board: \(label)")
    }
    @MainActor final class DraftBox { var draft: SharedArtifactProducer.Draft? }

    static func run(directory: URL) async throws {
        let scene = try ShareEntryChecks.mountScene("portal-board")
        defer { scene.close() }
        let app = scene.app, canvas = scene.canvas
        guard let root = scene.fixture.projectRoots[WorkspaceInvariantsFixture.projectA1],
              let spawner = app.spawnerForFilesystemCreation() else { throw Failure(description: "no project to spawn into") }
        guard case .spawned(let boardID, let tileID) = spawner.spawnBoard(title: "Checkout launch"),
              case .spawned(let privateID, _) = spawner.spawnBoard(title: "Private salary notes") else {
            throw Failure(description: "the production spawner made no board")
        }
        canvas.layoutSubtreeIfNeeded()
        guard let hostView = canvas.tileView(for: tileID) as? KanbanTileNSView, let runtime = hostView.boardRuntime,
              let board = runtime.board(id: boardID) else { throw Failure(description: "no host board view or runtime") }
        let columns = board.orderedColumns.map(\.id)
        try require(columns.count == 3, "the host board has three columns")
        let (shared, kept) = (scene.agents[0], scene.agents[1])

        // The host fills it through its own reducer, as a pointer or the API would.
        let wallet = UUID(), receipts = UUID(), polish = UUID()
        func apply(_ command: BoardCommand, _ label: String) throws {
            switch runtime.apply(command, to: boardID) {
            case .applied, .rebased: break
            default: throw Failure(description: "the host reducer refused: \(label)")
            }
        }
        try apply(.createTask(id: wallet, columnId: columns[0], title: "Wallets first", body: "## Plan\n\n- **Apple Pay** before cards\n- then `saved cards`",
                              links: [.url("https://user:pw@example.com/pr/12?token=abc#review"), .agent(shared),
                                      .document(.init(path: root.appendingPathComponent("PLAN.md").path,
                                                      scope: .checkout(projectId: WorkspaceInvariantsFixture.projectA1, rootPath: root.path, relativePath: "PLAN.md"))),
                                      .document(.init(path: "/Users/someone/Private/taxes.pdf", scope: .standalone))],
                              assignee: shared, after: nil, before: nil), "create Wallets first")
        try apply(.createTask(id: receipts, columnId: columns[1], title: "Receipt email", body: "Check the *template*.", links: [],
                              assignee: kept, after: nil, before: nil), "create Receipt email")
        try apply(.createCard(id: polish, columnId: columns[2], title: "Polish the toggle", after: nil, before: nil), "create Polish")
        // A picture on a card, in the project's own attachment store.
        let picture = BoardAttachment(filename: "mock.png", contentType: "image/png", pixelWidth: 64, pixelHeight: 40, byteCount: 0)
        let store = BoardAttachmentStore(projectRoot: root)
        let pictureURL = store.fileURL(boardID: boardID, attachmentID: picture.id)
        try FileManager.default.createDirectory(at: pictureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(NSSize(width: 64, height: 40)).write(to: pictureURL)
        guard let receiptCard = runtime.board(id: boardID)?.card(receipts) else { throw Failure(description: "no receipt card") }
        var content = BoardTaskContent(card: receiptCard); content.attachments = [picture]
        try apply(.editTask(id: receipts, expected: BoardTaskContent(card: receiptCard), content: content), "attach a picture")

        // The host's portal: the shared agent is in it, the other is not.
        let area = UUID(), agentObject = UUID()
        guard let sharedTile = app.agentSupervisor.records[shared]?.tileId else { throw Failure(description: "the shared agent has no tile") }
        try app.hostedPortalIndex?.put(.init(account: "check", area: area, name: "Launch", origin: .init(x: 0, y: 0),
                                             tiles: [.init(tile: sharedTile, object: agentObject, kind: .agent),
                                                     .init(tile: tileID, object: UUID(), kind: .board)]))
        defer { try? app.hostedPortalIndex?.remove(area: area) }
        let host = SharedPortalHostContext(app: app, area: area)

        guard let itemKind = SharedPortal.ItemKind.forTile(.kanban) else {
            throw Failure(description: "a board tile is not admitted to portals (it stays out of the share)")
        }
        let kind = SharedPortalKinds.kind(for: itemKind)
        guard let record = host.tile(tileID) else { throw Failure(description: "the board tile has no record") }
        try require(kind.shareRow(for: record).included && kind.publishedTitle(for: record) == "Checkout launch",
                    "the share popover lists the board as going, under its title")

        // The guest: the portal's real context over a check rig controller.
        let me = Collaboration.Identity(person: .init(), device: UUID()), owner = Collaboration.Identity(person: .init(), device: UUID())
        let document = SharedArea.Document()
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (owner, .owner)])
        let rigRoot = FileManager.default.temporaryDirectory.appendingPathComponent("array-portal-board-\(UUID())")
        defer { try? FileManager.default.removeItem(at: rigRoot) }
        let controller = try SharedAreaCheckRig.controller(root: rigRoot, identity: me, label: "Sam", authority: authority, seed: (document, .editor))
        let guest = SharedPortalGuestContext(controller: controller, hostName: "Dylan", hostColour: .systemPurple)
        var opened: [UUID] = []
        guest.openBeside = { opened.append($0.rawValue) }

        var sequence: UInt64 = 0
        var bytesSent = 0
        /// Host draft → capture → JSON on the wire → the guest's verified contents.
        func wire(_ draft: SharedArtifactProducer.Draft, object: SharedArea.ID<SharedArea.Object>) throws -> CollaborationArtifactContents {
            sequence += 1
            let capture = try draft.capture(object: object, parent: nil)
            let record = Collaboration.Artifact.Record(manifest: capture.manifest, sequence: sequence, publisher: owner.person,
                                                       host: .init(), publishedAt: Date(), contentDigest: draft.contentDigest)
            var bytes: [String: Data] = [:]
            for entry in capture.manifest.entries where entry.coverage == .included {
                if let digest = entry.blob, let data = capture.blobs[digest] { bytes[entry.path] = data }
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let recordData = try encoder.encode(record), bytesData = try encoder.encode(bytes)
            bytesSent += bytesData.count
            try require(bytes.values.allSatisfy { $0.count <= Collaboration.Artifact.Limits.blobBytes }
                        && bytes.values.reduce(0) { $0 + $1.count } <= 8 * 1024 * 1024, "revision \(sequence) is inside the relay's entry and revision limits")
            return .init(record: try decoder.decode(Collaboration.Artifact.Record.self, from: recordData),
                         bytes: try decoder.decode([String: Data].self, from: bytesData))
        }

        guard let first = try await kind.snapshot(tile: record, host: host) else { throw Failure(description: "the board kind published no snapshot") }
        let object = SharedArea.ID<SharedArea.Object>()
        let item = kind.makeView(entry: .init(object: object, kind: itemKind, title: kind.publishedTitle(for: record)), guest: guest)
        guard let guestItem = item as? SharedPortalBoardItemView else {
            throw Failure(description: "the guest draws \(type(of: item)) instead of the host's board")
        }
        let firstContents = try wire(first, object: object)
        guestItem.apply(contents: firstContents)
        let guestView = guestItem.board

        // Privacy: one board, project paths only, URL secrets home.
        let sentText = firstContents.bytes.values.compactMap { String(data: $0, encoding: .utf8) }.joined()
            .replacingOccurrences(of: "\\/", with: "/")
        try require(!sentText.contains("Private salary notes") && !sentText.contains(privateID.uuidString),
                    "only the shared board travels; the library's other boards stay home")
        try require(!sentText.contains(root.path) && !sentText.contains("taxes.pdf") && !sentText.contains("/Users/"),
                    "no path outside the project, and no absolute path, leaves the Mac")
        try require(!sentText.contains("token=abc") && !sentText.contains("pw@") && sentText.contains("example.com/pr/12"),
                    "a link keeps its page and loses its sign-in and secret query")

        // Same renderer, same content.
        func wait(_ done: () -> Bool) async throws -> Bool {
            for _ in 0..<60 { if done() { return true }; try await Task.sleep(for: .milliseconds(50)) }
            return done()
        }
        try require(type(of: guestView) == type(of: hostView), "the guest draws the host's own board view (\(type(of: guestView)))")
        func lanes(_ view: KanbanTileNSView) -> [String] {
            view.board.orderedColumns.map { column in
                column.name + ": " + view.board.orderedCards(in: column.id).map(\.title).joined(separator: ", ")
            }
        }
        try require(lanes(guestView) == lanes(hostView), "the guest's columns and cards match the host's: \(lanes(guestView))")
        func chip(_ view: KanbanTileNSView, _ card: UUID) -> String {
            (view.cardView(for: card)?.qaAssigneeTitle ?? "").replacingOccurrences(of: "  ▾", with: "")
        }
        for card in [wallet, receipts, polish] {
            try require(chip(guestView, card) == chip(hostView, card) || (chip(hostView, card) == "Assign agent" && chip(guestView, card) == "Unassigned"),
                        "card \(guestView.board.card(card)?.title ?? "") shows the host's assignee: \(chip(guestView, card))")
        }
        try require(guestView.cardView(for: receipts)?.qaMetaText == hostView.cardView(for: receipts)?.qaMetaText,
                    "a card's notes and picture markers match: \(guestView.cardView(for: receipts)?.qaMetaText ?? "")")
        try require(guestView.cardView(for: wallet)?.qaMetaText == "Notes  3 linked" && hostView.cardView(for: wallet)?.qaMetaText == "Notes  4 linked",
                    "the guest's links are the host's minus the file outside the project")
        guard let shownURL = guestView.board.card(wallet)?.links.first, case .url(let address) = shownURL else { throw Failure(description: "no URL link on the guest") }
        try require(address == "https://example.com/pr/12", "the guest's URL link is the scrubbed page: \(address)")

        // Read only, said plainly; no edit route.
        try require(guestView.isReadOnly && guestView.qaTitleBarActionsHidden && guestView.qaGestureHint.hasPrefix("Read only · Dylan's board"),
                    "the guest board says read only and offers no add or board switcher: \(guestView.qaGestureHint)")
        try require(guestView.onCommand == nil && guestView.boardRuntime == nil, "the guest board has no route into any reducer")
        let revision = runtime.board(id: boardID)?.revision
        guestView.moveTaskFromMenu(polish, to: columns[0]); guestView.createCard(in: columns[0]); guestView.deleteTaskFromMenu(polish)
        try require(runtime.board(id: boardID)?.revision == revision && lanes(guestView) == lanes(hostView),
                    "a guest move, add or delete changes nothing on either side")
        try require(guestView.cardView(for: polish)?.qaContextItems.map(\.id) == ["open"], "a guest's card menu offers only Open Details")

        // Off screen: pictures and the Markdown body.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = NSView(frame: window.contentLayoutRect)
        window.contentView = stage
        guestItem.frame = NSRect(x: 760, y: 20, width: 720, height: 460)
        stage.addSubview(guestItem)
        window.orderFrontOffscreenForChecks()
        stage.layoutSubtreeIfNeeded()
        try require(try await wait { guestView.cardView(for: receipts)?.qaHasThumbnail == true },
                    "the card's picture arrives and draws on the guest's card")
        guestView.openTask(wallet)
        guard let editor = guestView.qaTaskDetail?.qaEditor else { throw Failure(description: "the guest's task did not open") }
        var heading: String?
        for _ in 0..<200 {
            heading = try? await editor.evaluateJavaScript("document.querySelector('.tiptap h2')?.textContent") as? String
            if heading == "Plan" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let strong = try? await editor.evaluateJavaScript("document.querySelector('.tiptap strong')?.textContent") as? String
        let editable = try? await editor.evaluateJavaScript("document.querySelector('.tiptap').getAttribute('contenteditable')") as? String
        let status = try? await editor.evaluateJavaScript("document.getElementById('save-status').textContent") as? String
        let note = try? await editor.evaluateJavaScript("document.getElementById('assignment-note').textContent") as? String
        try require(heading == "Plan" && strong == "Apple Pay", "the guest reads the card body as Markdown in the host's task editor")
        try require(editable == "false" && status == "Read only · Dylan's board", "the task editor is read only on the guest: \(status ?? "-")")
        try require(note?.hasPrefix("Map the checkout state machine is Dylan's agent") == true, "the task says whose agent the assignee is: \(note ?? "-")")
        // The task editor as the guest sees it, light and dark (WebKit paints
        // out of process, so its own snapshot is the picture).
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            let colours = appearance == .aqua
                ? "{bg:'#ffffff',card:'#f5f6f8',text:'#202329',muted:'#6b7079',line:'#e2e5ea',accent:'#4262dc',mode:'light'}"
                : "{bg:'#14171c',card:'#1c212a',text:'#e9ebef',muted:'#a3aab5',line:'#414751',accent:'#9db7ff',mode:'dark'}"
            _ = try? await editor.evaluateJavaScript("window.taskEditor.theme(\(colours))")
            try await Task.sleep(for: .milliseconds(200))
            let image = try await editor.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { throw Failure(description: "no task picture") }
            let url = directory.appendingPathComponent("portal-board-task-\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("WROTE \(url.path)")
        }
        BoardTaskDetailController.dismissPresented(in: window)
        try require(try await wait { !BoardTaskDetailController.isPresented(in: window) }, "closing the read-only task leaves nothing to save")

        // Assignees: a shared agent opens beside; any other stays the host's.
        guestItem.assigneePressed(card: wallet)
        try require(opened == [agentObject], "the shared agent's chip opens that shared agent")
        guestItem.assigneePressed(card: receipts)
        try require(guestItem.qaFacts["notice"]?.hasPrefix("Audit the receipt email path is Dylan's agent") == true,
                    "an agent outside the share shows a styled 'Dylan's agent' note: \(guestItem.qaFacts["notice"] ?? "")")

        // Live: host create, move, edit and delete all reach the guest.
        let latest = DraftBox()
        let observation = kind.observe(tile: tileID, host: host) { latest.draft = $0 }
        defer { observation?.cancel() }
        func follow(_ label: String, until done: () -> Bool) async throws {
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(100))
                if let draft = latest.draft { guestItem.apply(contents: try wire(draft, object: object)); latest.draft = nil }
                if done() { try require(lanes(guestView) == lanes(hostView), "\(label) shows on the guest: \(lanes(guestView))"); return }
            }
            throw Failure(description: "\(label) never reached the guest: \(lanes(guestView)) vs \(lanes(hostView))")
        }
        try apply(.moveCard(id: wallet, toColumn: columns[1], after: receipts, before: nil), "move Wallets")
        try await follow("a host move") { guestView.board.card(wallet)?.columnId == columns[1] }
        let fresh = UUID()
        try apply(.createCard(id: fresh, columnId: columns[0], title: "New from the host", after: nil, before: nil), "create")
        try await follow("a host create") { guestView.board.card(fresh) != nil }
        try apply(.editTaskFields(id: polish, title: "Polish the saved-card toggle", body: nil, links: nil), "edit")
        try await follow("a host edit") { guestView.board.card(polish)?.title == "Polish the saved-card toggle" }
        try apply(.deleteCard(id: fresh), "delete")
        try await follow("a host delete") { guestView.board.card(fresh) == nil }

        // The pinned board: switching the host tile elsewhere never sends the other board.
        guard var switched = canvas.tileRecord(for: tileID) else { throw Failure(description: "no tile record") }
        switched.metadata.boardId = privateID
        _ = canvas.materializeProjectTile(tileView: hostView, for: switched)
        try await Task.sleep(for: .milliseconds(700))
        let after = latest.draft.flatMap { try? wire($0, object: object) }
        let afterText = after?.bytes.values.compactMap { String(data: $0, encoding: .utf8) }.joined() ?? ""
        try require(!afterText.contains("Private salary notes"), "a board the host switches to after sharing stays private")

        try require(bytesSent < 512 * 1024, "the whole run sent \(bytesSent) bytes, pictures included")
        guestItem.qaDismissNotice()
        try await stills(host: hostView, guest: guestItem, stage: stage, window: window, directory: directory, label: "board")
        window.orderOut(nil)
        print("PASS portal board: a host board reaches the guest live through the wire, drawn by the host's board view, read only")
    }

    static func pngData(_ size: NSSize) throws -> Data {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.white.setFill(); NSRect(x: 8, y: 8, width: rect.width - 16, height: 10).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no PNG") }
        return png
    }

    /// Host tile and guest item side by side, light and dark.
    static func stills(host: KanbanTileNSView, guest: SharedPortalBoardItemView, stage: NSView, window: NSWindow,
                       directory: URL, label: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostParent = host.superview, hostFrame = host.frame
        host.removeFromSuperview()
        host.frame = NSRect(x: 20, y: 20, width: 720, height: 460)
        stage.addSubview(host)
        defer { host.removeFromSuperview(); host.frame = hostFrame; hostParent?.addSubview(host) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(label == "open" ? 400 : 150))
            CATransaction.flush()
            guard let rep = stage.bitmapImageRepForCachingDisplay(in: stage.bounds) else { throw Failure(description: "no bitmap") }
            stage.cacheDisplay(in: stage.bounds, to: rep)
            let url = directory.appendingPathComponent("portal-board-\(label)-\(appearance == .aqua ? "light" : "dark").png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("WROTE \(url.path)")
        }
    }
}
