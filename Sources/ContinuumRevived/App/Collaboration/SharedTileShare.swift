import AppKit
import WebKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

// Every other tile kind, shared the way one agent is
// (`.plans/105-collaboration/SHARE-KINDS.md`): the header's Share publishes the
// tile into an area that is only a permission container, and this Mac hosts it
// live. Nothing on the sharer's canvas moves. The person who opens the link
// gets one `.sharedTile` in the zone they are looking at.

/// What one `.sharedTile` reads from: the area's controller (document, host
/// liveness, member names) and the lane its body reads and writes.
@MainActor
final class SharedTileSession {
    let tileId: UUID
    let reference: SharedAgentTileReference
    let controller: SharedAreaController
    private weak var view: SharedTileNSView?
    private var observer: UUID?
    private var openTask: Task<Void, Never>?
    private var hadItem = false
    private(set) var isClosed = false
    private struct Applied: Equatable { let state: SharedAgentTileNSView.State; let hostName: String; let colour: NSColor }
    private var lastApplied: Applied?

    init(view: SharedTileNSView, reference: SharedAgentTileReference, controller: SharedAreaController) {
        tileId = view.tile.id; self.view = view; self.reference = reference; self.controller = controller
        view.session = self
    }

    func start() {
        guard !isClosed, observer == nil else { return }
        observer = controller.addChangeObserver { [weak self] in self?.refresh() }
        refresh()
        openTask = Task { [weak self] in
            guard let self else { return }
            await controller.open()
            refresh()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        openTask?.cancel(); openTask = nil
        view?.body?.stop()
        if let observer { controller.removeChangeObserver(observer) }; observer = nil
        if view?.session === self { view?.session = nil }
        let controller = controller
        Task { await controller.close() }
    }

    var item: SharedArea.Item? {
        controller.document?.items.first { $0.id.rawValue == reference.objectId && $0.kind == .liveTile }
    }
    var hostName: String {
        let host = item?.source?.owner ?? reference.hostPerson.map(SharedArea.ID<SharedArea.Person>.init)
        return host.flatMap { controller.memberNames[$0] }.map { String($0.prefix(28)) } ?? reference.hostName
    }

    func refresh() {
        guard !isClosed, let view else { return }
        let item = self.item
        if item != nil { hadItem = true }
        let host = item?.source?.owner ?? reference.hostPerson.map(SharedArea.ID<SharedArea.Person>.init)
        let colour = host.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemOrange
        let liveness = item.flatMap { SharedAreaHostLivenessCopy.liveness(for: $0, in: controller.hostLiveness) }
        let next: SharedAgentTileNSView.State
        switch controller.status {
        case .unavailable(.accessDenied): next = .stopped("\(hostName) stopped sharing")
        case .unavailable: next = .stopped("\(hostName)'s \(view.ownedNoun) can't be reached")
        default:
            if hadItem, item == nil, controller.document != nil { next = .stopped("\(hostName) stopped sharing") }
            else if liveness?.state == .offline { next = .offline(lastSeen: liveness?.lastSeen) }
            else if controller.document == nil { next = .connecting }
            else { next = .live }
        }
        if case .stopped = next {
            view.body?.stop()
        } else if let item, controller.status == .connected {
            view.body?.attach(controller: controller, object: item.id)
        }
        let applied = Applied(state: next, hostName: hostName, colour: colour)
        guard applied != lastApplied else { return }
        lastApplied = applied
        view.apply(next, hostName: hostName, colour: colour)
    }
}

extension AppDelegate {
    // MARK: - Host

    /// The area a note, file, diff, browser or terminal is already shared through.
    func hostedLiveTileArea(forTile tile: UUID) -> UUID? { hostedAgentArea(forTile: tile) }

    /// Copy, for one live tile: create the area, publish the tile into it as a
    /// `.liveTile`, and host it. The tile keeps its zone, frame and runtime.
    func shareLiveTile(tile tileId: UUID, name: String) async throws -> UUID {
        guard let canvas = canvasView else { throw WorkspaceRuntime.SharedZoneError.noCanvas }
        guard let tile = canvas.tileRecord(for: tileId), SharedAreaPublication.liveKind(for: tile.kind) != nil,
              let zone = tile.zoneId, let project = canvas.projectId(forZone: zone) else {
            throw WorkspaceRuntime.SharedZoneError.tileNotInstalled(tileId)
        }
        let model = try await shareLinks.readyAccount()
        guard let account = model.activeAccount?.id else { throw ShareLinkFailure.notSignedIn }
        if hostedAgentShares?.area(forTile: tileId, account: account) != nil {
            throw WorkspaceRuntime.SharedZoneError.alreadyShared(tileId)
        }
        let area = try await ShareLinkCoordinator.waitingOutBusy { try await model.createArea(label: name).scope.area.rawValue }
        let objects = try await ShareLinkCoordinator.waitingOutBusy {
            try await self.shareLinks.publish(selection: .tiles([.init(projectID: project, tileID: tileId)]), intoArea: area, live: true)
        }
        guard let object = objects[tileId] else { throw ShareLinkFailure.nothingToShare }
        try hostedAgentShares?.add(.init(account: account, area: area, tile: tileId, object: object.rawValue))
        startHostingSharedAgent(area: area, model: model)
        // The first picture goes before the link does, so whoever opens it
        // sees the tile at once.
        if let host = sharedAreaHostSessions[account + "/" + area.uuidString] {
            for _ in 0..<100 where host.liveTileHosts[object]?.publishedCount ?? 0 == 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        refreshHostedAgentMarks()
        return area
    }

    /// What a hosted live tile reads its tile through, by kind. Nil when the
    /// tile is not on this canvas (closed since): nothing is published for it.
    func makeLiveTileSource(_ binding: SharedAreaLocalSourceBinding, storage: URL) -> LiveTileSource? {
        guard let canvas = canvasView, let tileID = binding.tileID, let tile = canvas.tileRecord(for: tileID),
              let runtime = sharedAreaRuntime, let controller = runtime.controller(for: binding.projectID) else { return nil }
        let title: @MainActor () -> String = { [weak canvas] in canvas?.tileRecord(for: tileID)?.title ?? tile.title }
        switch tile.kind {
        case .note:
            guard let noteID = tile.metadata.noteId else { return nil }
            // The view on the canvas first: a note spawned this session is not
            // always in its controller's `noteViews`, and its file lags typing.
            let noteView: @MainActor () -> NoteTileNSView? = { [weak canvas, weak controller] in
                (canvas?.tileView(for: tileID) as? NoteTileNSView) ?? controller?.noteViews[noteID]
            }
            let read: @MainActor () -> String? = { [weak controller] in
                if let view = noteView() { return view.textView.string }
                return try? controller?.projectStore.loadNoteBody(id: noteID)
            }
            let write: @MainActor (String) -> Void = { [weak controller] text in
                guard let controller else { return }
                if let view = noteView() {
                    LiveTileTextSplice.replace(in: view.textView, with: text)
                    // The note's own save path, as a keystroke would take it.
                    view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.textView))
                } else {
                    try? controller.projectStore.saveNoteBody(id: noteID, text: text)
                }
            }
            let identity = (try? collaborationAccountModel())?.activeAccount?.identity.device.uuidString ?? "host"
            return NoteLiveSource(read: read, write: write, title: title,
                                  textView: { noteView()?.textView },
                                  stateURL: storage.appendingPathComponent("live-notes/\(binding.object.rawValue.uuidString).json"),
                                  replicaID: "h-" + identity.prefix(8) + "-" + UUID().uuidString.prefix(8))
        case .file:
            guard let path = tile.metadata.documentLocation?.path ?? tile.metadata.filePath else { return nil }
            return FileLiveSource(url: URL(fileURLWithPath: path))
        case .diffReview:
            return DiffLiveSource(root: URL(fileURLWithPath: controller.project.rootPath, isDirectory: true),
                                  source: DiffReviewSource(metadata: tile.metadata), title: tile.title.isEmpty ? "Changes" : tile.title)
        case .terminal:
            return TerminalLiveSource(text: { [weak canvas] in (canvas?.tileView(for: tileID) as? TerminalTileNSView)?.runtime.visibleText() },
                                      title: title)
        case .browser:
            let view: @MainActor () -> BrowserTileNSView? = { [weak canvas] in canvas?.tileView(for: tileID) as? BrowserTileNSView }
            return BrowserLiveSource(webView: { (view()?.runtime as? WKWebViewBrowserRuntime)?.webView },
                                     address: { (view()?.runtime.url).flatMap { $0.isEmpty ? nil : $0 } ?? tile.metadata.url ?? "" },
                                     title: { view()?.runtime.title ?? tile.title })
        default:
            return nil
        }
    }

    // MARK: - Guest

    /// A link's area that is one shared note, file, diff, browser or terminal
    /// owned by someone else.
    static func sharedLiveTileItem(in document: SharedArea.Document, me: SharedArea.ID<SharedArea.Person>?) -> SharedArea.Item? {
        guard document.items.count == 1, let item = document.items.first, item.kind == .liveTile,
              let owner = item.source?.owner, owner != me else { return nil }
        return item
    }

    /// One `.sharedTile` lands in the zone this person is looking at, in view.
    /// Opening it again reveals the same tile.
    @discardableResult
    func openSharedTileLink(model: CollaborationAccountController, area: UUID, item: SharedArea.Item) async throws -> UUID {
        guard let canvas = canvasView else { throw ShareLinkFailure.noWorkspace }
        if let existing = canvas.allWorkspaceTiles().first(where: {
            $0.kind == .sharedTile && $0.metadata.sharedTile?.areaId == area && $0.metadata.sharedTile?.objectId == item.id.rawValue
        }) {
            if let view = canvas.tileView(for: existing.id) as? SharedTileNSView, let reference = view.reference {
                startSharedTileSession(view, reference: reference, controller: try model.makeSharedAreaController(area: area))
            }
            canvas.centerOnTile(existing.id)
            focusSpawnedTile(existing.id)
            return existing.id
        }
        guard let spawner = spawnerForFilesystemCreation() else { throw ShareLinkFailure.noWorkspace }
        let controller = try model.makeSharedAreaController(area: area)
        await controller.open()
        let owner = item.source?.owner
        for _ in 0..<50 where owner.map({ controller.memberNames[$0] == nil }) ?? false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // What kind it is comes with the owner's first state.
        var kind: Collaboration.LiveTile.Kind?
        for _ in 0..<100 where kind == nil {
            kind = (try? await controller.readLiveTile(object: item.id, request: .init(generation: nil, revision: nil, eventsAfter: nil,
                                                                                        waitMilliseconds: 2_000)))?.state?.kind
            if kind == nil { try? await Task.sleep(for: .milliseconds(200)) }
        }
        guard let kind else { await controller.close(); throw ShareLinkFailure.unavailableArea }
        let hostName = owner.flatMap { controller.memberNames[$0] }.map { String($0.prefix(28)) } ?? "A teammate"
        let label = model.activeAccount?.knownAreas.first(where: { $0.id == area })?.label ?? "Shared \(LiveTileBodyView.noun(kind))"
        let reference = SharedAgentTileReference(areaId: area, objectId: item.id.rawValue, hostName: hostName,
                                                 hostPerson: owner?.rawValue, accountId: model.activeAccount?.id, liveKind: kind.rawValue)
        let view: SharedTileNSView
        switch spawner.spawnSharedTile(reference, title: label) {
        case .success(let spawned): view = spawned
        case .failure(let error): await controller.close(); throw error
        }
        attachSharedTile(view, controller: controller)
        canvas.centerOnTile(view.tile.id)
        focusSpawnedTile(view.tile.id)
        presentSharedTileArrival(hostName: hostName, noun: LiveTileBodyView.noun(kind), tile: view.tile.id,
                                 colour: owner.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemPurple)
        return view.tile.id
    }

    /// A hydrated `.sharedTile`: reconnects through the account that joined,
    /// else keeps its placeholder.
    func attachSharedTile(_ view: SharedTileNSView, controller opened: SharedAreaController? = nil) {
        view.onWindowChange = { [weak self] view, inWindow in
            guard let self else { return }
            if inWindow { if view.session == nil { attachSharedTile(view) } }
            else { sharedTileSessions.removeValue(forKey: view.tile.id)?.close() }
        }
        guard let reference = view.reference, view.liveKind != nil else { return }
        if let opened { startSharedTileSession(view, reference: reference, controller: opened); return }
        guard !view.attaching else { return }
        view.attaching = true
        Task { [weak self, weak view] in
            defer { view?.attaching = false }
            guard let self, let view, view.session == nil, let model = try? collaborationAccountModel() else { return }
            if model.status != .ready, let remembered = model.selectedAccountID ?? (model.accounts.count == 1 ? model.accounts.first?.id : nil) {
                _ = try? await model.select(accountID: remembered)
            }
            guard view.session == nil, model.status == .ready, let account = model.activeAccount,
                  reference.accountId == nil || reference.accountId == account.id,
                  account.knownAreas.contains(where: { $0.id == reference.areaId }),
                  let controller = try? model.makeSharedAreaController(area: reference.areaId) else { return }
            startSharedTileSession(view, reference: reference, controller: controller)
        }
    }

    func startSharedTileSession(_ view: SharedTileNSView, reference: SharedAgentTileReference, controller: SharedAreaController) {
        sharedTileSessions.removeValue(forKey: view.tile.id)?.close()
        let session = SharedTileSession(view: view, reference: reference, controller: controller)
        sharedTileSessions[view.tile.id] = session
        session.start()
    }

    func sharedTileClosed(_ tileId: UUID) {
        sharedTileSessions.removeValue(forKey: tileId)?.close()
    }

    func presentSharedTileArrival(hostName: String, noun: String, tile: UUID, colour: NSColor) {
        guard let canvas = canvasView else { return }
        canvas.subviews.filter { $0 is SharedAgentArrivalBanner }.forEach { $0.removeFromSuperview() }
        let banner = SharedAgentArrivalBanner(text: "\(hostName) shared a \(noun) with you. It stays on \(hostName)'s Mac.", colour: colour)
        let size = banner.preferredSize
        banner.frame = NSRect(x: (canvas.bounds.width - size.width) / 2, y: canvas.isFlipped ? 14 : canvas.bounds.height - size.height - 14,
                              width: size.width, height: size.height)
        banner.autoresizingMask = canvas.isFlipped ? [.minXMargin, .maxXMargin, .maxYMargin] : [.minXMargin, .maxXMargin, .minYMargin]
        banner.onShow = { [weak self, weak banner] in
            banner?.removeFromSuperview()
            self?.canvasView?.centerOnTile(tile)
            self?.focusSpawnedTile(tile)
        }
        canvas.addSubview(banner, positioned: .above, relativeTo: nil)
        Task { @MainActor [weak banner] in
            try? await Task.sleep(for: .seconds(10))
            banner?.removeFromSuperview()
        }
    }
}

/// Replaces a text view's text with the smallest edit, keeping the caret and
/// selection where they were relative to the text around them.
@MainActor
enum LiveTileTextSplice {
    static func replace(in textView: NSTextView, with next: String) {
        let old = textView.string
        guard old != next else { return }
        let a = Array(old), b = Array(next)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let start = String(a[0..<prefix]).utf16.count
        let oldLength = String(a[prefix..<(a.count - suffix)]).utf16.count
        let replacement = String(b[prefix..<(b.count - suffix)])
        let range = NSRange(location: start, length: oldLength)
        let delta = replacement.utf16.count - oldLength
        func map(_ position: Int) -> Int {
            if position <= range.location { return position }
            if position >= NSMaxRange(range) { return position + delta }
            return range.location + replacement.utf16.count
        }
        let selection = textView.selectedRange()
        // In the view's own font and colour, as typing would have put it there.
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
        let anchor = map(selection.location), end = map(NSMaxRange(selection))
        textView.setSelectedRange(NSRange(location: anchor, length: max(0, end - anchor)))
    }
}
