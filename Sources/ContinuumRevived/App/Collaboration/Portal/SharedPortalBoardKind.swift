import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

// A board (Kanban) tile inside a portal (`PORTAL-CONTRACT.md`). The host
// publishes the ONE board the tile showed when sharing started, as
// `board.json` plus small card pictures; the guest draws it with the host's
// own `KanbanTileNSView`, read only. Guest edits are not in this release:
// they need a guest-to-host route the relay does not have yet
// (`~/array-scratch/shared-boards/REPORT.md`).

@MainActor
struct SharedPortalBoardKind: SharedPortalKind {
    var itemKind: SharedPortal.ItemKind { .board }
    func shareRow(for tile: Tile) -> SharedPortalShareRow { .init(included: true, badge: "Live · read only") }

    /// The project's board authority for a host tile.
    static func runtime(tile id: UUID, host: SharedPortalHostContext) -> BoardRuntime? {
        guard let app = host.app, let tile = host.tile(id), let zone = tile.zoneId,
              let project = app.canvasView?.projectId(forZone: zone),
              let controller = app.sharedAreaRuntime?.controller(for: project) else { return nil }
        return app.configuredBoardRuntime(controller)
    }

    /// Reads the pinned board and builds its draft. Pictures are made once per
    /// attachment (originals never change) and kept in `pictures`.
    @MainActor final class Publisher {
        let tile: UUID
        let boardID: UUID
        let host: SharedPortalHostContext
        private var pictures: [UUID: Data] = [:]
        private var refused: Set<UUID> = []
        init(tile: UUID, boardID: UUID, host: SharedPortalHostContext) { self.tile = tile; self.boardID = boardID; self.host = host }

        func draft() async -> SharedArtifactProducer.Draft? {
            guard let runtime = SharedPortalBoardKind.runtime(tile: tile, host: host), let board = runtime.board(id: boardID) else { return nil }
            let app = host.app
            var payload = SharedPortal.BoardPayload.make(board: board) { app?.agentSupervisor.displayName(forAgent: $0) }
            // An assignee whose agent tile is in this same portal opens there.
            let shared = app?.hostedPortalIndex?.entry(area: host.area)?.tiles.filter { $0.kind == .agent } ?? []
            payload.agents = payload.agents.map { agent in
                var agent = agent
                if let tile = app?.agentSupervisor.records[agent.id]?.tileId, let item = shared.first(where: { $0.tile == tile }) {
                    agent.object = item.object
                }
                return agent
            }
            var extra: [String: Data] = [:]
            if let root = host.projectRoot(forTile: tile) {
                let store = BoardAttachmentStore(projectRoot: root)
                for attachment in Self.pictureOrder(board).prefix(SharedPortal.BoardPayload.thumbnailCount) {
                    guard let data = await picture(attachment, store: store) else { continue }
                    extra[SharedPortal.BoardPayload.thumbnailEntry(attachment)] = data.base64EncodedData()
                }
            }
            return try? SharedPortal.jsonDraft(payload, name: SharedPortal.BoardPayload.name, extra: extra)
        }
        /// Each card's first picture first, in board order, then the rest.
        static func pictureOrder(_ board: Board) -> [UUID] {
            let cards = board.orderedColumns.flatMap { board.orderedCards(in: $0.id) }
            var order = cards.compactMap { $0.attachments.first?.id }
            for card in cards { for attachment in card.attachments.dropFirst() where !order.contains(attachment.id) { order.append(attachment.id) } }
            return order
        }
        private static let pipeline = ComposerImageIOThumbnailPipeline()
        private func picture(_ attachment: UUID, store: BoardAttachmentStore) async -> Data? {
            if let cached = pictures[attachment] { return cached }
            guard !refused.contains(attachment) else { return nil }
            let url = store.fileURL(boardID: boardID, attachmentID: attachment)
            guard let made = try? await Self.pipeline.thumbnail(for: url, maxPixelSize: SharedPortal.BoardPayload.thumbnailPixels),
                  made.pngData.count <= SharedPortal.BoardPayload.thumbnailBytes else { refused.insert(attachment); return nil }
            pictures[attachment] = made.pngData
            return made.pngData
        }
    }

    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? {
        guard let boardID = tile.metadata.boardId else { return nil }
        return await Publisher(tile: tile.id, boardID: boardID, host: host).draft()
    }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? {
        // Pinned: if the host switches this tile to another board, the shared
        // one keeps going out and the other stays private.
        guard let boardID = host.tile(tile)?.metadata.boardId else { return nil }
        let publisher = Publisher(tile: tile, boardID: boardID, host: host)
        return SharedPortalPollObservation(every: .milliseconds(500), draft: { await publisher.draft() }, publish: publish)
    }
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        SharedPortalBoardItemView(entry: entry, guest: guest)
    }
}

/// The guest's board: a header like every portal item, over the host's own
/// `KanbanTileNSView` in read-only mode. The tile's own title bar (close,
/// share, ⋯) is clipped away: a guest cannot close or share the owner's tile.
@MainActor
final class SharedPortalBoardItemView: SharedPortalItemView {
    let board: KanbanTileNSView
    private let clip = SharedPortalBoardClipView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "Read only")
    private let waiting = NSTextField(labelWithString: "")
    private let notice = SharedPortalBoardNotice()
    private var payload: SharedPortal.BoardPayload?
    private(set) var latest: CollaborationArtifactContents?
    /// Card pictures, written where the board's own picture code reads them.
    private let pictureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-shared-boards", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var written: Set<String> = []
    static let headerHeight: CGFloat = 33

    override init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) {
        let placeholder = Board(id: UUID(), title: entry.title, columns: [], cards: [])
        board = KanbanTileNSView(tile: Tile(id: UUID(), kind: .kanban, title: entry.title, frame: .init(x: 0, y: 0, width: 600, height: 400),
                                            zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: .init()), board: placeholder)
        super.init(entry: entry, guest: guest)
        board.readOnlyOwner = guest.hostName
        board.taskAttachmentStore = BoardAttachmentStore(projectRoot: pictureRoot)
        board.agentDisplayName = { [weak self] id in self?.payload?.agents.first { $0.id == id }?.name }
        board.onReadOnlyAssignee = { [weak self] card in self?.assigneePressed(card: card) }
        board.isHidden = true
        clip.addSubview(board)
        title.font = .token(.label); title.lineBreakMode = .byTruncatingTail; title.stringValue = entry.title
        badge.font = .token(.caption); badge.alignment = .right
        waiting.font = .token(.body); waiting.alignment = .center
        waiting.stringValue = "Waiting for \(guest.hostName)'s board…"
        for view in [clip, title, badge, waiting, notice] as [NSView] { addSubview(view) }
        notice.isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(entry.title), \(guest.hostName)'s board, read only")
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { try? FileManager.default.removeItem(at: pictureRoot) }

    override func apply(contents: CollaborationArtifactContents?) {
        guard let contents, let next = SharedPortal.decode(SharedPortal.BoardPayload.self, name: SharedPortal.BoardPayload.name, from: contents.bytes) else { return }
        latest = contents
        writePictures(SharedPortal.payload(contents.bytes), board: next.board.id)
        payload = next
        board.render(next.board)
        board.setTitleBarIdentity(title: next.board.title)
        title.stringValue = next.board.title
        board.isHidden = false
        waiting.isHidden = true
    }
    private func writePictures(_ entries: [String: Data], board boardID: UUID) {
        guard let store = board.taskAttachmentStore else { return }
        for (name, encoded) in entries where name.hasPrefix("thumb-") && name.hasSuffix(".png.b64") && !written.contains(name) {
            let raw = name.dropFirst("thumb-".count).dropLast(".png.b64".count)
            guard let id = UUID(uuidString: String(raw)), let data = Data(base64Encoded: encoded), NSImage(data: data) != nil else { continue }
            let url = store.fileURL(boardID: boardID, attachmentID: id)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: url, options: .atomic)) != nil { written.insert(name) }
        }
    }

    /// The assignee chip: a shared agent opens beside the portal; any other
    /// agent stays on the host's Mac, and the board says so.
    func assigneePressed(card id: UUID) {
        guard let card = payload?.board.card(id), let assignee = card.assignee,
              let agent = payload?.agents.first(where: { $0.id == assignee }), let guest else { return }
        if let object = agent.object {
            guest.openBeside(.init(object))
            return
        }
        notice.show("\(agent.name) is \(guest.hostName)'s agent", detail: "It runs on \(guest.hostName)'s Mac and is not shared here.")
        needsLayout = true
    }

    func qaDismissNotice() { notice.isHidden = true }

    override func apply(state: SharedPortalItemState) {
        super.apply(state: state)
        switch state {
        case .live: badge.stringValue = "Read only"
        case .offline: badge.stringValue = "Offline · read only"
        case .stopped: badge.stringValue = "Stopped"
        }
    }

    override var qaFacts: [String: String] {
        guard let shown = payload?.board else { return ["editable": "false", "text": waiting.stringValue, "revision": "0"] }
        let columns = shown.orderedColumns.map { column in
            column.name + ": " + shown.orderedCards(in: column.id).map(\.title).joined(separator: ", ")
        }
        return ["editable": "false", "text": columns.joined(separator: " | "), "revision": String(latest?.record.sequence ?? 0),
                "notice": notice.isHidden ? "" : notice.text, "hint": board.qaGestureHint]
    }

    override func layout() {
        super.layout()
        let header = Self.headerHeight
        title.frame = NSRect(x: 14, y: 10, width: max(0, bounds.width - 140), height: 18)
        badge.frame = NSRect(x: bounds.width - 124, y: 11, width: 110, height: 16)
        clip.frame = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        // The tile's own title bar sits above the clip, out of sight and reach.
        let bar = TileNSView.titleBarHeight
        let frame = NSRect(x: 0, y: -bar, width: clip.bounds.width, height: clip.bounds.height + bar)
        if board.frame != frame { board.frame = frame }
        waiting.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
        let noticeSize = NSSize(width: min(bounds.width - 40, 360), height: 52)
        notice.frame = NSRect(x: (bounds.width - noticeSize.width) / 2, y: bounds.height - noticeSize.height - 44,
                              width: noticeSize.width, height: noticeSize.height)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        title.textColor = TextToken.textPrimary.color.nsColor(in: self)
        badge.textColor = TextToken.textSecondary.color.nsColor(in: self)
        waiting.textColor = TextToken.textSecondary.color.nsColor(in: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        SurfaceToken.tileBody.color.nsColor(in: self).setFill(); card.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); card.lineWidth = 1; card.stroke()
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()
    }
}

/// Clips the board's title bar away and keeps the tile frame itself (its
/// resize ring and move strip) from taking a press: a guest's board never
/// moves or resizes. Cards, lanes and scrolling still get theirs.
@MainActor
final class SharedPortalBoardClipView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is TileNSView ? self : hit
    }
    override func mouseDown(with event: NSEvent) {}
}

/// A short styled note over the board ("Scout is Dylan's agent"), gone after
/// a few seconds or on a click.
@MainActor
final class SharedPortalBoardNotice: NSView {
    private let line = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var hide: Task<Void, Never>?
    var text: String { line.stringValue + " · " + detail.stringValue }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.font = .token(.label); detail.font = .token(.caption)
        for field in [line, detail] { field.lineBreakMode = .byTruncatingTail; addSubview(field) }
        applyTokens()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ text: String, detail more: String) {
        line.stringValue = text; detail.stringValue = more
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text + ". " + more)
        isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text + ". " + more])
        hide?.cancel()
        hide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isHidden = true
        }
    }
    override func mouseDown(with event: NSEvent) { isHidden = true }
    override func layout() {
        super.layout()
        line.frame = NSRect(x: 14, y: 9, width: bounds.width - 28, height: 18)
        detail.frame = NSRect(x: 14, y: 28, width: bounds.width - 28, height: 16)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    private func applyTokens() {
        layer?.cornerRadius = CGFloat(CornerRole.radius(base: 8))
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        layer?.borderColor = LineToken.borderStrong.color.cgColor(in: self)
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: 3)
        line.textColor = TextToken.textPrimary.color.nsColor(in: self)
        detail.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
}
