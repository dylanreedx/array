import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// What one `.sharedPortal` tile reads from: the area's controller (document,
/// positions, artifact heads, host liveness, names), the manifest, and each
/// item's latest content. It draws through `SharedPortalBodyView` and the
/// kinds in `SharedPortalKinds`; cursors ride the shared presence publisher.
@MainActor
final class SharedPortalTileSession {
    typealias Object = SharedArea.ID<SharedArea.Object>
    typealias Revision = SharedArea.ID<Collaboration.Artifact.RevisionTag>

    let tileId: UUID
    let reference: SharedPortalTileReference
    let controller: SharedAreaController
    let guest: SharedPortalGuestContext
    let body: SharedPortalBodyView
    private(set) var presence: SharedAreaPresencePublisher?
    private weak var view: SharedPortalTileNSView?
    private var observer: UUID?
    private var openTask: Task<Void, Never>?
    private(set) var isClosed = false
    private var hadDocument = false

    private(set) var manifest: SharedPortal.Manifest?
    private(set) var entries: [Object: SharedPortal.Entry] = [:]
    /// The revision each item's view shows, and reads under way.
    private var applied: [Object: Revision] = [:]
    private var reading: Set<Object> = []
    private(set) var contents: [Object: CollaborationArtifactContents] = [:]
    private(set) var reads = 0

    private struct Key: Equatable {
        let status: SharedAreaController.Status
        let revision: UInt64?
        let heads: [Collaboration.Artifact.Head]
        let hosts: [Collaboration.HostLiveness]
        let names: Int
    }
    private var lastKey: Key?
    private var lastState: SharedPortalTileNSView.State?
    private struct Applied: Equatable { let state: SharedPortalTileNSView.State; let hostName: String; let colour: NSColor }
    private var lastApplied: Applied?

    init(view: SharedPortalTileNSView, reference: SharedPortalTileReference, controller: SharedAreaController) {
        tileId = view.tile.id; self.view = view; self.reference = reference; self.controller = controller
        guest = SharedPortalGuestContext(controller: controller, hostName: reference.hostName, hostColour: .systemOrange)
        body = SharedPortalBodyView(controller: controller, camera: reference.camera)
        body.onCameraChange = { [weak view] camera in view?.persistCamera(camera) }
        view.install(body: body)
        view.session = self
    }

    func start() {
        guard !isClosed, observer == nil else { return }
        observer = controller.addChangeObserver { [weak self] in self?.refresh() }
        let publisher = SharedAreaPresencePublisher(scene: body)
        presence = publisher
        publisher.start()
        refresh()
        openTask = Task { [weak self] in
            guard let self else { return }
            await controller.open()
            refresh()
        }
    }
    func waitUntilOpen() async { await openTask?.value }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        openTask?.cancel(); openTask = nil
        presence?.stop(); presence = nil
        for view in body.items.values { (view as? SharedPortalAgentItemView)?.stop() }
        if let observer { controller.removeChangeObserver(observer) }; observer = nil
        if view?.session === self { view?.session = nil }
        let controller = controller
        Task { await controller.close() }
    }

    // MARK: Who and whether

    var hostPerson: SharedArea.ID<SharedArea.Person>? {
        let document = controller.document
        let manifestObject = document.map { SharedPortal.manifestObject(in: $0.id) }
        return document?.items.first(where: { $0.id == manifestObject })?.source?.owner
            ?? document?.items.compactMap(\.source?.owner).first
            ?? reference.hostPerson.map(SharedArea.ID<SharedArea.Person>.init)
    }
    var hostName: String {
        guard let host = hostPerson else { return reference.hostName }
        return controller.memberNames[host].map { String($0.prefix(28)) } ?? reference.hostName
    }
    /// The host's liveness: any source-bound item names the host.
    private var hostLiveness: Collaboration.HostLiveness? {
        guard let document = controller.document else { return nil }
        for item in document.items where item.source != nil {
            if let liveness = SharedAreaHostLivenessCopy.liveness(for: item, in: controller.hostLiveness) { return liveness }
        }
        return nil
    }

    private func state() -> SharedPortalTileNSView.State {
        switch controller.status {
        case .unavailable(.accessDenied):
            return .stopped("\(hostName) stopped sharing")
        case .unavailable:
            return .stopped("\(hostName)'s canvas can't be reached")
        default:
            if hadDocument, controller.document?.items.isEmpty == true { return .stopped("\(hostName) stopped sharing") }
            if let liveness = hostLiveness, liveness.state == .offline { return .offline(lastSeen: liveness.lastSeen) }
            return controller.document == nil ? .connecting : .live
        }
    }

    // MARK: Refresh

    /// Only a change does work: the controller reports every presence frame.
    func refresh() {
        guard !isClosed, let view else { return }
        let key = Key(status: controller.status, revision: controller.document?.revision, heads: controller.artifactHeads,
                      hosts: controller.hostLiveness, names: controller.memberNames.count)
        if key == lastKey { return }
        lastKey = key
        if controller.document != nil { hadDocument = true }
        let next = state()
        let host = hostPerson
        let colour = host.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemOrange
        guest.update(hostName: hostName, hostColour: colour)
        if case .stopped = next {
            // Nothing new arrives and nothing more is read: what was already
            // delivered stays on screen until the tile is closed.
            for item in body.items.values { item.apply(state: next.itemState) }
        } else {
            if let document = controller.document { reconcile(document) }
            for item in body.items.values where item.itemState != next.itemState { item.apply(state: next.itemState) }
        }
        let applied = Applied(state: next, hostName: hostName, colour: colour)
        guard applied != lastApplied else { return }
        lastApplied = applied
        lastState = next
        view.apply(next, hostName: hostName, colour: colour)
    }

    private func reconcile(_ document: SharedArea.Document) {
        let manifestObject = SharedPortal.manifestObject(in: document.id)
        let heads = Dictionary(controller.artifactHeads.map { ($0.object, $0.revision) }, uniquingKeysWith: { $1 })
        // The manifest first: it names the kinds and titles.
        if let head = heads[manifestObject], applied[manifestObject] != head { read(manifestObject, revision: head) }
        // A portal's items wait for the manifest that names their kinds, so
        // nothing ever shows as the wrong kind; an area shared before mode B
        // has no manifest and is read by item kind instead.
        let isPortal = SharedPortal.isPortal(document)
        var next: [Object: SharedPortal.Entry] = [:]
        for item in document.items where item.id != manifestObject {
            if let entry = manifest?.entry(for: item.id) { next[item.id] = entry }
            else if !isPortal { next[item.id] = Self.legacyEntry(for: item) }
        }
        // A changed kind or title rebuilds that item's view.
        let changed = Set(next.compactMap { object, entry in entries[object].map { $0 != entry ? object : nil } ?? nil })
        entries = next
        let ordered = document.positions.filter { $0.object != manifestObject && next[$0.object] != nil }
            .sorted { ($0.z, $0.object.rawValue.uuidString) < ($1.z, $1.object.rawValue.uuidString) }
        if !changed.isEmpty { body.setItems(ordered.filter { !changed.contains($0.object) }.map { ($0.object, $0.rect) }, make: { _ in nil }) }
        body.setItems(ordered.map { ($0.object, $0.rect) }) { [weak self] object in
            guard let self, let entry = next[object] else { return nil }
            let view = SharedPortalKinds.kind(for: entry.kind).makeView(entry: entry, guest: guest)
            view.apply(state: lastState?.itemState ?? .live)
            applied.removeValue(forKey: object)
            if let contents = contents[object] { view.apply(contents: contents) }
            return view
        }
        for item in document.items where item.id != manifestObject && next[item.id] != nil {
            switch item.kind {
            case .agentObservation:
                (body.item(item.id) as? SharedPortalAgentItemView)?.show(in: document)
            case .artifact:
                if let head = heads[item.id], applied[item.id] != head { read(item.id, revision: head) }
            case .discussion, .agreement:
                // 0.7.37 notes: their text is in the document itself.
                if let text = Self.legacyText(of: item, in: document), applied[item.id] == nil {
                    let contents = Self.legacyContents(object: item.id, text: text)
                    self.contents[item.id] = contents
                    applied[item.id] = contents.record.manifest.id
                    body.item(item.id)?.apply(contents: contents)
                }
            }
        }
    }

    /// Reads and verifies one artifact revision, then hands it to its view.
    private func read(_ object: Object, revision: Revision) {
        guard !reading.contains(object), let transport = controller.artifactTransport else { return }
        reading.insert(object)
        Task { [weak self] in
            let result: CollaborationArtifactContents?
            do { result = try await transport.readArtifact(object: object.rawValue, revision: revision.rawValue) }
            catch { fputs("portal: reading \(object.rawValue) failed: \(error)\n", stderr); result = nil }
            guard let self, !isClosed else { return }
            reading.remove(object)
            guard let result else {
                // A read that failed (a blip on the relay) is tried again.
                try? await Task.sleep(for: .seconds(2))
                guard !isClosed else { return }
                lastKey = nil
                refresh()
                return
            }
            reads += 1
            applied[object] = revision
            contents[object] = result
            if object == controller.document.map({ SharedPortal.manifestObject(in: $0.id) }) {
                if let manifest = SharedPortal.decodeManifest(result.bytes), manifest != self.manifest {
                    self.manifest = manifest
                    lastKey = nil
                    refresh()
                }
            } else {
                body.item(object)?.apply(contents: result)
            }
            // A newer head may have arrived during the read.
            if let head = controller.artifactHeads.first(where: { $0.object == object })?.revision, head != revision {
                read(object, revision: head)
            }
        }
    }

    // MARK: 0.7.37 areas, with no manifest

    static func legacyEntry(for item: SharedArea.Item) -> SharedPortal.Entry {
        switch item.kind {
        case .agentObservation: return .init(object: item.id, kind: .agent, title: "Agent")
        case .discussion, .agreement: return .init(object: item.id, kind: .note, title: "Note")
        case .artifact: return .init(object: item.id, kind: .file, title: "File")
        }
    }
    static func legacyText(of item: SharedArea.Item, in document: SharedArea.Document) -> String? {
        switch item.kind {
        case .discussion: return document.posts.last { $0.object == item.id }?.text
        case .agreement: return document.currentRevision(of: item.id)?.text
        default: return nil
        }
    }
    /// A note's text as the note kind's payload, so one renderer draws both.
    static func legacyContents(object: Object, text: String) -> CollaborationArtifactContents {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(SharedPortal.NotePayload(text: text))) ?? Data()
        let path = SharedPortal.entryPrefix + SharedPortal.NotePayload.name + ".json"
        let manifest = Collaboration.Artifact.Manifest(object: object, parent: nil, kind: .files, base: .init(head: nil),
            declaration: .init(range: .files, includesCommitted: false, includesStaged: false, includesUnstaged: false,
                               includesUntracked: false, omittedChangedPaths: 0, omittedUntrackedPaths: 0),
            entries: [.init(path: path, change: .unchanged, coverage: .included, blob: Collaboration.Artifact.digest(data),
                            length: data.count, mediaType: "text/plain", sourceDigest: "")], capturedAt: 0)
        let record = Collaboration.Artifact.Record(manifest: manifest, sequence: 1, publisher: .init(), host: .init(),
                                                   publishedAt: Date(timeIntervalSince1970: 0), contentDigest: manifest.contentDigest)
        return .init(record: record, bytes: [path: data])
    }
}

extension SharedAgentTileNSView.State {
    var itemState: SharedPortalItemState {
        switch self {
        case .placeholder, .connecting, .live: return .live
        case .offline(let lastSeen): return .offline(lastSeen: lastSeen)
        case .stopped(let text): return .stopped(text)
        }
    }
}

extension AppDelegate {
    // MARK: - Guest: one portal tile in the armed zone

    /// A link to a portal (or to a 0.7.37 area, which opens as one): one
    /// `.sharedPortal` tile lands in the zone this person is looking at, in
    /// view. Opening it again reveals the same tile and reconnects it.
    @discardableResult
    func openSharedPortalLink(model: CollaborationAccountController, area: UUID, document: SharedArea.Document) async throws -> UUID {
        guard let canvas = canvasView else { throw ShareLinkFailure.noWorkspace }
        // The sharer opening their own link: show what they share, here.
        if let mine = hostedPortalSession(area: area)?.entry.tiles.first?.tile
            ?? hostedAgentShares?.entries.first(where: { $0.area == area })?.tile, canvas.tileRecord(for: mine) != nil {
            canvas.centerOnTile(mine)
            focusSpawnedTile(mine)
            return mine
        }
        if let existing = canvas.allWorkspaceTiles().first(where: { $0.kind == .sharedPortal && $0.metadata.sharedPortal?.areaId == area }) {
            if let view = canvas.tileView(for: existing.id) as? SharedPortalTileNSView, let reference = view.reference {
                startSharedPortalSession(view, reference: reference, controller: try model.makeSharedAreaController(area: area))
            }
            canvas.centerOnTile(existing.id)
            focusSpawnedTile(existing.id)
            return existing.id
        }
        guard let spawner = spawnerForFilesystemCreation() else { throw ShareLinkFailure.noWorkspace }
        let controller = try model.makeSharedAreaController(area: area)
        await controller.open()
        let owner = SharedPortal.isPortal(document)
            ? document.items.first(where: { $0.id == SharedPortal.manifestObject(in: document.id) })?.source?.owner
            : document.items.compactMap(\.source?.owner).first
        // Member names come with the first authority frame, a moment after open.
        for _ in 0..<50 where owner.map({ controller.memberNames[$0] == nil }) ?? false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let hostName = owner.flatMap { controller.memberNames[$0] }.map { String($0.prefix(28)) } ?? "A teammate"
        let label = model.activeAccount?.knownAreas.first(where: { $0.id == area })?.label ?? "Shared canvas"
        let reference = SharedPortalTileReference(areaId: area, hostName: hostName, hostPerson: owner?.rawValue,
                                                  accountId: model.activeAccount?.id, name: label)
        let view: SharedPortalTileNSView
        switch spawner.spawnSharedPortal(reference, title: label) {
        case .success(let spawned): view = spawned
        case .failure(let error): await controller.close(); throw error
        }
        attachSharedPortalTile(view, controller: controller)
        canvas.centerOnTile(view.tile.id)
        focusSpawnedTile(view.tile.id)
        presentSharedPortalArrival(hostName: hostName, tile: view.tile.id,
                                   colour: owner.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemPurple)
        return view.tile.id
    }

    /// A hydrated `.sharedPortal` tile: reconnects through the signed-in
    /// account when it is the one that joined, else shows the placeholder.
    func attachSharedPortalTile(_ view: SharedPortalTileNSView, controller opened: SharedAreaController? = nil) {
        view.onWindowChange = { [weak self] view, inWindow in
            guard let self else { return }
            if inWindow { if view.session == nil { attachSharedPortalTile(view) } }
            else { sharedPortalTileSessions.removeValue(forKey: view.tile.id)?.close() }
        }
        guard let reference = view.reference else { return }
        if let opened {
            startSharedPortalSession(view, reference: reference, controller: opened)
            return
        }
        guard !view.attaching else { return }
        view.attaching = true
        Task { [weak self, weak view] in
            defer { view?.attaching = false }
            guard let self, let view, view.session == nil else { return }
            guard let model = try? collaborationAccountModel() else { return }
            if model.status != .ready, let remembered = model.selectedAccountID ?? (model.accounts.count == 1 ? model.accounts.first?.id : nil) {
                _ = try? await model.select(accountID: remembered)
            }
            guard view.session == nil, model.status == .ready, let account = model.activeAccount,
                  reference.accountId == nil || reference.accountId == account.id,
                  account.knownAreas.contains(where: { $0.id == reference.areaId }),
                  let controller = try? model.makeSharedAreaController(area: reference.areaId) else { return }
            startSharedPortalSession(view, reference: reference, controller: controller)
        }
    }

    func startSharedPortalSession(_ view: SharedPortalTileNSView, reference: SharedPortalTileReference, controller: SharedAreaController) {
        sharedPortalTileSessions.removeValue(forKey: view.tile.id)?.close()
        let session = SharedPortalTileSession(view: view, reference: reference, controller: controller)
        let portal = view.tile.id
        session.guest.openBeside = { [weak self] object in
            Task { @MainActor [weak self] in _ = try? await self?.openPortalAgentBeside(portal: portal, object: object) }
        }
        sharedPortalTileSessions[view.tile.id] = session
        session.start()
    }

    func sharedPortalTileClosed(_ tileId: UUID) {
        sharedPortalTileSessions.removeValue(forKey: tileId)?.close()
    }

    /// "Open beside": the agent lands as the mode A tile, to the right of the
    /// portal in the portal's own zone, with prompts and names as in mode A.
    /// Asked again, it reveals the tile already open.
    @discardableResult
    func openPortalAgentBeside(portal: UUID, object: SharedArea.ID<SharedArea.Object>) async throws -> UUID {
        guard let canvas = canvasView, let session = sharedPortalTileSessions[portal],
              let portalTile = canvas.tileRecord(for: portal) else { throw ShareLinkFailure.noWorkspace }
        let area = session.reference.areaId
        if let existing = canvas.allWorkspaceTiles().first(where: {
            $0.kind == .sharedAgent && $0.metadata.sharedAgent?.areaId == area && $0.metadata.sharedAgent?.objectId == object.rawValue
        }) {
            if let view = canvas.tileView(for: existing.id) as? SharedAgentTileNSView, view.session?.isClosed != false {
                attachSharedAgentTile(view)
            }
            canvas.centerOnTile(existing.id)
            focusSpawnedTile(existing.id)
            return existing.id
        }
        guard let model = try? collaborationAccountModel(), model.status == .ready,
              let zone = portalTile.zoneId, let project = canvas.projectId(forZone: zone),
              let spawner = sharedAreaRuntime?.controller(for: project)?.tileSpawner else { throw ShareLinkFailure.noWorkspace }
        let world = canvas.worldFrame(forTileFrame: portalTile.frame, tileId: portal)
        let size = CanvasEngine.defaultFrame(for: .sharedAgent)
        let centre = CGPoint(x: world.x + world.width + 32 + Double(size.width) / 2, y: world.y + Double(size.height) / 2)
        let title = session.entries[object]?.title ?? "Shared agent"
        let reference = SharedAgentTileReference(areaId: area, objectId: object.rawValue, hostName: session.hostName,
                                                 hostPerson: session.hostPerson?.rawValue, accountId: model.activeAccount?.id)
        guard case .success(let view) = spawner.spawnSharedAgent(reference, title: title, targetZoneId: zone, worldPoint: centre) else {
            throw ShareLinkFailure.noWorkspace
        }
        attachSharedAgentTile(view, model: model, controller: try model.makeSharedAreaController(area: area))
        canvas.centerOnTile(view.tile.id)
        focusSpawnedTile(view.tile.id)
        return view.tile.id
    }

    /// "Dylan shared part of their canvas with you." with Show.
    func presentSharedPortalArrival(hostName: String, tile: UUID, colour: NSColor) {
        guard let canvas = canvasView else { return }
        canvas.subviews.filter { $0 is SharedAgentArrivalBanner }.forEach { $0.removeFromSuperview() }
        let banner = SharedAgentArrivalBanner(text: "\(hostName) shared part of their canvas with you. Everything in it runs on \(hostName)'s Mac.",
                                              colour: colour)
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
