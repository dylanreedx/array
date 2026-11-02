import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

// Mode B, the sharer's side. Copy on the Share tool makes an area that holds
// the chosen tiles, and nothing on this canvas moves. While it is shared this
// Mac keeps it live: positions follow the tiles, each kind publishes its
// content, agents stream as in mode A, and cursors travel over shared tiles.

/// The portals this Mac shares, by account, so their hosts restart at launch.
/// App state, channel-split: it sits beside the collaboration account list,
/// never in a project's `.array/`.
@MainActor
final class HostedPortalIndex {
    struct Shared: Codable, Equatable {
        let tile: UUID
        let object: UUID
        let kind: SharedPortal.ItemKind
    }
    struct Entry: Codable, Equatable {
        let account: String
        let area: UUID
        var name: String
        let origin: SharedPortal.Origin
        var tiles: [Shared]
    }
    private struct File: Codable { var schema = 1; var entries: [Entry] }

    let url: URL
    private(set) var entries: [Entry]
    /// Tiles this Mac currently marks as shared through a portal (not saved).
    var markedTiles: Set<UUID> = []

    init(directory: URL) {
        url = directory.appendingPathComponent("hosted-portals.json")
        entries = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)))?.entries ?? []
    }
    func entries(account: String) -> [Entry] { entries.filter { $0.account == account } }
    func entry(area: UUID) -> Entry? { entries.first { $0.area == area } }
    func portal(forTile tile: UUID, account: String) -> Entry? {
        entries.last { $0.account == account && $0.tiles.contains { $0.tile == tile } }
    }
    func put(_ entry: Entry) throws {
        entries.removeAll { $0.area == entry.area }
        entries.append(entry)
        try save()
    }
    func remove(area: UUID) throws {
        guard entries.contains(where: { $0.area == area }) else { return }
        entries.removeAll { $0.area == area }
        try save()
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(File(entries: entries)).write(to: url, options: .atomic)
    }
}

/// One portal this Mac shares. It rides the area's `SharedAreaHostSession`
/// (agents, prompts, liveness) and adds what a portal needs: the manifest,
/// geometry, each kind's content, and cursors on this canvas.
@MainActor
final class SharedPortalHostSession {
    typealias Object = SharedArea.ID<SharedArea.Object>
    typealias Revision = SharedArea.ID<Collaboration.Artifact.RevisionTag>

    let area: UUID
    private(set) var entry: HostedPortalIndex.Entry
    let host: SharedAreaHostSession
    var controller: SharedAreaController { host.controller }
    let context: SharedPortalHostContext
    private weak var app: AppDelegate?
    private var observations: [UUID: any SharedPortalObservation] = [:]
    private struct Outbox {
        var parent: Revision?
        var lastKey: [String]?
        var pending: SharedArtifactProducer.Draft?
        var sending = false
        var lastSent: ContinuousClock.Instant?
        var timer: Task<Void, Never>?
    }
    private var outboxes: [Object: Outbox] = [:]
    private var seeded = false
    private var placing = false
    private var geometryTimer: Timer?
    private var changeObserver: UUID?
    private var startTask: Task<Void, Never>?
    private(set) var surface: SharedPortalHostCanvasSurface?
    private(set) var presence: SharedAreaPresencePublisher?
    private(set) var isStopped = true
    /// Revisions published, and moves sent, for the witnesses.
    private(set) var publishedRevisions = 0
    private(set) var placedCommands = 0

    init(entry: HostedPortalIndex.Entry, host: SharedAreaHostSession, app: AppDelegate) {
        area = entry.area; self.entry = entry; self.host = host; self.app = app
        context = SharedPortalHostContext(app: app, area: entry.area)
    }

    func object(forTile tile: UUID) -> Object? { entry.tiles.first { $0.tile == tile }.map { Object($0.object) } }
    var manifestObject: Object { .init(area) }

    // MARK: Lifecycle

    func start() {
        guard isStopped else { return }
        isStopped = false
        host.start()
        changeObserver = controller.addChangeObserver { [weak self] in self?.controllerChanged() }
        startTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<300 where controller.status != .connected && !isStopped { try? await Task.sleep(for: .milliseconds(50)) }
            guard !isStopped, controller.status == .connected else { return }
            if let document = controller.document,
               let source = document.items.first(where: { $0.id == manifestObject })?.source ?? document.items.compactMap(\.source).first {
                host.fallbackHost = source.host
            }
            await admitManifestIfMissing()
            await seed()
            guard !isStopped else { return }
            publishManifest()
            for shared in entry.tiles where shared.kind != .agent { await publishSnapshot(of: shared) }
            for shared in entry.tiles where shared.kind != .agent { observe(shared) }
            startGeometry()
            installSurface()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        startTask?.cancel(); startTask = nil
        for observation in observations.values { observation.cancel() }
        observations = [:]
        for box in outboxes.values { box.timer?.cancel() }
        outboxes = [:]; seeded = false
        geometryTimer?.invalidate(); geometryTimer = nil
        presence?.stop(); presence = nil
        surface?.removeFromSuperview(); surface = nil
        if let changeObserver { controller.removeChangeObserver(changeObserver) }; changeObserver = nil
        host.stop()
    }

    private func controllerChanged() {
        surface?.controllerChanged()
    }

    // MARK: Content

    /// An area shared before mode B (a migrated zone) has no manifest item.
    /// The owner admits one, under this Mac's host, before publishing it.
    private func admitManifestIfMissing() async {
        guard let app, let model = try? app.collaborationAccountModel(), let person = model.activeAccount?.identity.person else { return }
        for _ in 0..<3 {
            guard let document = controller.document, !document.items.contains(where: { $0.id == manifestObject }) else { return }
            guard controller.canSubmit, let hostID = try? await model.registerHost() else { try? await Task.sleep(for: .milliseconds(300)); continue }
            host.fallbackHost = host.fallbackHost ?? hostID
            let result = await controller.submit(.init(area: document.id, expectedRevision: document.revision, edits: [
                .admit(.init(id: manifestObject, kind: .artifact, source: .init(owner: person, host: hostID, binding: .init())),
                       .init(id: .init(), object: manifestObject, rect: SharedPortal.manifestRect, z: 0))]))
            if case .accepted = result { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The latest revision each artifact already has on the relay, so new
    /// revisions chain onto it and an unchanged one is not sent again.
    private func seed() async {
        guard !seeded, let transport = controller.artifactTransport else { return }
        let objects = [manifestObject] + entry.tiles.filter { $0.kind != .agent }.map { Object($0.object) }
        for object in objects {
            guard let state = try? await transport.artifactState(object: object.rawValue), let latest = state.latest else { continue }
            var box = outboxes[object] ?? .init()
            box.parent = latest.manifest.id
            box.lastKey = Self.key(latest.manifest.entries)
            outboxes[object] = box
        }
        seeded = true
    }

    private static func key(_ entries: [Collaboration.Artifact.Entry]) -> [String] {
        entries.map { "\($0.path)\u{0}\($0.blob ?? "-")" }.sorted()
    }

    func manifest() -> SharedPortal.Manifest {
        let entries: [SharedPortal.Entry] = entry.tiles.map { shared in
            let title = context.tile(shared.tile).map { tile in
                shared.kind == .agent ? (app?.portalAgentTitle(tile) ?? tile.title) : SharedPortalKinds.kind(for: shared.kind).publishedTitle(for: tile)
            } ?? (shared.kind == .terminal ? "Terminal" : shared.kind.rawValue.capitalized)
            return .init(object: .init(shared.object), kind: shared.kind, title: title)
        }
        return .init(name: entry.name, entries: entries)
    }
    func publishManifest() {
        guard let draft = try? SharedPortal.manifestDraft(manifest()) else { return }
        enqueue(draft, for: manifestObject)
    }
    private func publishSnapshot(of shared: HostedPortalIndex.Shared) async {
        guard let tile = context.tile(shared.tile) else { return }
        let kind = SharedPortalKinds.kind(for: shared.kind)
        do {
            if let draft = try await kind.snapshot(tile: tile, host: context) { enqueue(draft, for: .init(shared.object)) }
        } catch {
            fputs("portal snapshot failed for \(shared.kind.rawValue): \(error)\n", stderr)
        }
    }
    private func observe(_ shared: HostedPortalIndex.Shared) {
        guard observations[shared.tile] == nil else { return }
        let object = Object(shared.object)
        let kind = SharedPortalKinds.kind(for: shared.kind)
        observations[shared.tile] = kind.observe(tile: shared.tile, host: context) { [weak self] draft in
            self?.enqueue(draft, for: object)
        }
    }

    /// The newest draft for an object goes out once any send in flight lands,
    /// at most one every `minimumInterval`, and never twice when unchanged.
    func enqueue(_ draft: SharedArtifactProducer.Draft, for object: Object) {
        guard !isStopped else { return }
        var box = outboxes[object] ?? .init()
        let key = Self.key(draft.entries)
        if box.lastKey == key, box.pending == nil, !box.sending { return }
        box.pending = draft
        outboxes[object] = box
        pump(object)
    }
    private func pump(_ object: Object) {
        guard !isStopped, seeded, var box = outboxes[object], !box.sending, box.timer == nil, let draft = box.pending else { return }
        if Self.key(draft.entries) == box.lastKey { box.pending = nil; outboxes[object] = box; return }
        if let last = box.lastSent {
            let next = last.advanced(by: SharedPortalHost.minimumInterval)
            if ContinuousClock.now < next {
                box.timer = Task { [weak self] in
                    try? await Task.sleep(until: next, clock: .continuous)
                    guard let self else { return }
                    outboxes[object]?.timer = nil
                    pump(object)
                }
                outboxes[object] = box
                return
            }
        }
        box.pending = nil; box.sending = true
        outboxes[object] = box
        let parent = box.parent
        Task { [weak self] in
            guard let self else { return }
            var outcome: Revision?
            var conflicted = false
            if let transport = controller.artifactTransport, let epoch = controller.scope?.epoch,
               let capture = try? draft.capture(object: object, parent: parent) {
                do {
                    outcome = try await transport.publishArtifact(epoch: epoch, capture: capture).revision
                } catch {
                    conflicted = true
                    // Someone (this Mac, before a relaunch) moved the head on:
                    // chain onto it next time.
                    if let latest = try? await transport.artifactState(object: object.rawValue).latest {
                        outboxes[object]?.parent = latest.manifest.id
                    }
                }
            }
            guard var box = outboxes[object] else { return }
            box.sending = false
            box.lastSent = .now
            if let outcome {
                box.parent = outcome; box.lastKey = Self.key(draft.entries); publishedRevisions += 1
            } else if conflicted, box.pending == nil {
                box.pending = draft
            }
            outboxes[object] = box
            if box.pending != nil { pump(object) }
        }
    }

    // MARK: Geometry

    private func startGeometry() {
        geometryTimer?.invalidate()
        let interval = Double(SharedPortalHost.placeInterval.components.attoseconds) / 1e18 + Double(SharedPortalHost.placeInterval.components.seconds)
        geometryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncGeometry() }
        }
        syncGeometry()
    }

    /// Where each shared tile sits now, in area coordinates.
    func currentRects() -> [Object: SharedArea.Rect] {
        var rects: [Object: SharedArea.Rect] = [:]
        for shared in entry.tiles {
            guard let tile = context.tile(shared.tile) else { continue }
            rects[.init(shared.object)] = SharedPortal.areaRect(world: tile.frame, origin: entry.origin)
        }
        return rects
    }

    /// One `.place` per moved tile, in one command. A conflict tries again on
    /// the next tick; positions only ever follow this Mac's own canvas.
    func syncGeometry() {
        guard !isStopped, !placing, controller.canSubmit, let document = controller.document else { return }
        let rects = currentRects()
        let edits: [SharedArea.Edit] = rects.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }).compactMap { object, rect in
            guard rect.valid, let position = document.positions.last(where: { $0.object == object }), position.rect != rect else { return nil }
            return .place(.init(id: position.id, object: object, rect: rect, z: position.z))
        }
        guard !edits.isEmpty else { return }
        placing = true
        Task { [weak self] in
            guard let self else { return }
            let result = await controller.submit(.init(area: document.id, expectedRevision: document.revision, edits: edits))
            placing = false
            if case .accepted = result { placedCommands += 1 }
        }
    }

    /// The union of the shared tiles' world frames: where "Add to share" is offered.
    func worldRegion() -> CGRect? {
        let frames = entry.tiles.compactMap { context.tile($0.tile)?.frame }
        guard !frames.isEmpty else { return nil }
        return frames.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }.reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: Adding tiles

    /// "Add to share": the tiles join this portal at their own positions. Its
    /// origin never moves, so nothing already shared moves on the guest.
    func add(tiles ids: [UUID], model: CollaborationAccountController) async throws {
        guard let app, let canvas = app.canvasView else { throw SharedPortalError.notHosted }
        let fresh = ids.filter { id in !entry.tiles.contains { $0.tile == id } }
        guard !fresh.isEmpty else { return }
        let added = try await app.admitPortalTiles(fresh, area: area, origin: entry.origin, model: model, canvas: canvas,
                                                   controller: controller)
        entry.tiles += added
        try app.hostedPortalIndex?.put(entry)
        publishManifest()
        for shared in added where shared.kind != .agent {
            await publishSnapshot(of: shared)
            observe(shared)
        }
        app.refreshHostedPortalMarks()
    }

    // MARK: Cursors on this canvas

    private func installSurface() {
        guard surface == nil, let canvas = app?.canvasView else { return }
        let surface = SharedPortalHostCanvasSurface(session: self, canvas: canvas)
        self.surface = surface
        surface.frame = canvas.bounds
        surface.autoresizingMask = [.width, .height]
        canvas.addSubview(surface, positioned: .above, relativeTo: nil)
        let publisher = SharedAreaPresencePublisher(scene: surface)
        presence = publisher
        publisher.start()
    }
    func cameraApplied(user: Bool) {
        surface?.cameraApplied(user: user)
    }
}

/// The sharer's canvas as a presence surface: a pass-through layer over the
/// canvas, in area coordinates (world minus the portal's origin). The sharer's
/// cursor is sent only while it is over a shared tile, and a guest's cursor
/// is drawn over the same tile here.
@MainActor
final class SharedPortalHostCanvasSurface: NSView, SharedAreaPresenceSurface {
    private weak var session: SharedPortalHostSession?
    private weak var canvas: CanvasNSView?
    let controller: SharedAreaController
    let origin: SharedPortal.Origin
    var onCanvasTransformChange: (() -> Void)?
    var onLocalCameraNavigation: (() -> Void)?
    var onFollowTeammate: ((UUID?) -> Void)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    override var isFlipped: Bool { true }

    init(session: SharedPortalHostSession, canvas: CanvasNSView) {
        self.session = session; self.canvas = canvas
        controller = session.controller; origin = session.entry.origin
        super.init(frame: canvas.bounds)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Clicks always reach the canvas; only the overlay's own Follow card takes one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    func controllerChanged() {}
    func cameraApplied(user: Bool) {
        if user { onLocalCameraNavigation?() }
        onCanvasTransformChange?()
    }

    private var viewport: CanvasViewport { canvas?.viewport ?? CanvasViewport(x: 0, y: 0, zoom: 1) }
    var areaCanvasView: NSView { self }
    var isZone: Bool { true }
    var localViewCamera: SharedAreaLocalView {
        let v = viewport
        return .init(x: v.x - origin.x, y: v.y - origin.y, zoom: v.zoom)
    }
    var cameraViewportSize: CGSize { bounds.size }
    func areaPoint(forScreenPoint point: CGPoint) -> CGPoint {
        let world = CanvasEngine.screenToWorld(point, viewport: viewport)
        return CGPoint(x: Double(world.x) - origin.x, y: Double(world.y) - origin.y)
    }
    func screenPoint(forAreaPoint point: CGPoint) -> CGPoint {
        CanvasEngine.worldToScreen(CGPoint(x: Double(point.x) + origin.x, y: Double(point.y) + origin.y), viewport: viewport)
    }
    func setFollowTargets(_ targets: [SharedAreaSceneView.FollowTarget], followed: UUID?) {}
    /// The sharer following a guest: this canvas's camera moves to the guest's
    /// view of the shared tiles. Never written to the guest.
    func applyFollowedCamera(_ value: SharedAreaLocalView) -> Bool {
        guard let canvas else { return false }
        let next = CanvasViewport(x: value.x + origin.x, y: value.y + origin.y, zoom: value.zoom)
        guard next != canvas.viewport else { return false }
        canvas.setViewport(next)
        return true
    }
    func persistFollowedCamera() throws {}
    func publishesCursor(at area: CGPoint) -> Bool {
        guard let session else { return false }
        return session.currentRects().values.contains { r in
            area.x >= r.x && area.x <= r.x + r.width && area.y >= r.y && area.y <= r.y + r.height
        }
    }
}

extension AppDelegate {
    // MARK: - Host: share part of the canvas

    var hostedPortalIndex: HostedPortalIndex? {
        if let hostedPortalIndexStorage { return hostedPortalIndexStorage }
        guard let model = try? collaborationAccountModel() else { return nil }
        let index = HostedPortalIndex(directory: model.storeDirectory)
        hostedPortalIndexStorage = index
        return index
    }

    /// The portal a tile is already shared through, for the signed-in account.
    func hostedPortalArea(forTile tile: UUID) -> UUID? {
        guard let model = try? collaborationAccountModel(), let account = model.activeAccount?.id ?? model.selectedAccountID else { return nil }
        return hostedPortalIndex?.portal(forTile: tile, account: account)?.area
    }

    /// An agent's title as its owner sees it: the agent's name, else the tile's.
    func portalAgentTitle(_ tile: Tile) -> String {
        if let agent = agentSupervisor.agent(forTile: tile.id), let name = agentSupervisor.records[agent]?.displayName, !name.isEmpty { return name }
        return tile.title.isEmpty ? tile.kind.displayName : tile.title
    }

    /// Copy, for the Share tool: one area holding the chosen tiles, published
    /// where they sit. Nothing on this canvas moves and no zone is made.
    func sharePortal(tiles tileIds: [UUID], name: String) async throws -> UUID {
        guard let canvas = canvasView else { throw WorkspaceRuntime.SharedZoneError.noCanvas }
        let frames = tileIds.compactMap { id in canvas.tileRecord(for: id).map { canvas.worldFrame(forTileFrame: $0.frame, tileId: id) } }
        guard !frames.isEmpty else { throw SharedPortalError.nothingToShare }
        let model = try await shareLinks.readyAccount()
        guard let account = model.activeAccount?.id else { throw ShareLinkFailure.notSignedIn }
        let origin = SharedPortal.Origin.enclosing(frames)
        let area = try await ShareLinkCoordinator.waitingOutBusy { try await model.createArea(label: name).scope.area.rawValue }
        let shared: [HostedPortalIndex.Shared]
        do {
            shared = try await admitPortalTiles(tileIds, area: area, origin: origin, model: model, canvas: canvas, withManifest: true)
        } catch {
            throw error
        }
        let entry = HostedPortalIndex.Entry(account: account, area: area, name: name, origin: origin, tiles: shared)
        try hostedPortalIndex?.put(entry)
        startHostingPortal(entry, model: model)
        refreshHostedPortalMarks()
        return area
    }

    /// Admits tiles into a portal's area at their area rects: agents through
    /// the agent publication (so prompts and projections work as in mode A),
    /// every other kind as an artifact item, and on first share the manifest.
    func admitPortalTiles(_ tileIds: [UUID], area: UUID, origin: SharedPortal.Origin, model: CollaborationAccountController,
                          canvas: CanvasNSView, withManifest: Bool = false,
                          controller existing: SharedAreaController? = nil) async throws -> [HostedPortalIndex.Shared] {
        guard let person = model.activeAccount?.identity.person else { throw ShareLinkFailure.notSignedIn }
        var tiles: [(tile: Tile, world: TileFrame, project: UUID, kind: SharedPortal.ItemKind)] = []
        for id in tileIds {
            guard let record = canvas.tileRecord(for: id), let kind = SharedPortal.ItemKind.forTile(record.kind),
                  let zone = record.zoneId, let project = canvas.projectId(forZone: zone) else { continue }
            if kind == .agent, agentSupervisor.agent(forTile: id) == nil { continue }
            tiles.append((record, canvas.worldFrame(forTileFrame: record.frame, tileId: id), project, kind))
        }
        guard !tiles.isEmpty else { throw SharedPortalError.nothingToShare }
        // Agents first, through the publication path that binds them.
        var objects: [UUID: SharedArea.ID<SharedArea.Object>] = [:]
        let agents = tiles.filter { $0.kind == .agent }
        if !agents.isEmpty {
            let published = try await ShareLinkCoordinator.waitingOutBusy {
                try await self.shareLinks.publish(selection: .tiles(Set(agents.map { .init(projectID: $0.project, tileID: $0.tile.id) })), intoArea: area)
            }
            for agent in agents { if let object = published[agent.tile.id] { objects[agent.tile.id] = object } }
        }
        let hostID = try await model.registerHost()
        // A portal already hosted admits through its own open controller: a
        // second one on the same area's store would trip over its writes.
        let controller = try existing ?? model.makeSharedAreaController(area: area)
        if existing == nil { await controller.open() }
        defer { if existing == nil { Task { await controller.close() } } }
        // The agents' publication just moved the area on: read it again.
        if existing != nil, !agents.isEmpty {
            for _ in 0..<50 where !agents.allSatisfy({ agent in objects[agent.tile.id].map { object in controller.document?.items.contains { $0.id == object } == true } ?? true }) {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        var shared: [HostedPortalIndex.Shared] = []
        for _ in 0..<20 {
            guard controller.canSubmit, let document = controller.document else { try await Task.sleep(for: .milliseconds(250)); continue }
            var edits: [SharedArea.Edit] = []
            var next: [HostedPortalIndex.Shared] = []
            var z = (document.positions.map(\.z).max() ?? 0) + 1
            if withManifest, !document.items.contains(where: { $0.id == SharedPortal.manifestObject(in: document.id) }) {
                let object = SharedPortal.manifestObject(in: document.id)
                edits.append(.admit(.init(id: object, kind: .artifact, source: .init(owner: person, host: hostID, binding: .init())),
                                    .init(id: .init(), object: object, rect: SharedPortal.manifestRect, z: 0)))
            }
            for entry in tiles {
                let rect = SharedPortal.areaRect(world: entry.world, origin: origin)
                if entry.kind == .agent {
                    guard let object = objects[entry.tile.id],
                          let position = document.positions.last(where: { $0.object == object }) else { continue }
                    edits.append(.place(.init(id: position.id, object: object, rect: rect, z: z)))
                    next.append(.init(tile: entry.tile.id, object: object.rawValue, kind: .agent))
                } else {
                    let object = SharedArea.ID<SharedArea.Object>()
                    edits.append(.admit(.init(id: object, kind: .artifact, source: .init(owner: person, host: hostID, binding: .init())),
                                        .init(id: .init(), object: object, rect: rect, z: z)))
                    next.append(.init(tile: entry.tile.id, object: object.rawValue, kind: entry.kind))
                }
                z += 1
            }
            guard !edits.isEmpty else { return next }
            switch await controller.submit(.init(area: document.id, expectedRevision: document.revision, edits: edits)) {
            case .accepted: shared = next
            case .rejected(.conflict), .rejected(.busy): try await Task.sleep(for: .milliseconds(250)); continue
            default: throw ShareLinkFailure.publishFailed("The shared canvas could not take these tiles.")
            }
            break
        }
        guard !shared.isEmpty else { throw ShareLinkFailure.publishFailed("The shared canvas could not take these tiles.") }
        return shared
    }

    /// Undo of `sharePortal` when no link could be minted.
    func cancelPortalShare(area: UUID) async {
        if let model = try? collaborationAccountModel(), let account = model.activeAccount?.id {
            hostedPortalSessions.removeValue(forKey: account + "/" + area.uuidString)?.stop()
            if let controller = try? model.makeSharedAreaController(area: area) {
                await controller.open()
                if let document = controller.document, !document.items.isEmpty, controller.canSubmit {
                    _ = await controller.submit(.init(area: document.id, expectedRevision: document.revision,
                                                      edits: document.items.map { .remove($0.id) }))
                }
                await controller.close()
            }
        }
        try? hostedPortalIndex?.remove(area: area)
        refreshHostedPortalMarks()
    }

    func startHostingPortal(_ entry: HostedPortalIndex.Entry, model: CollaborationAccountController) {
        guard let account = model.activeAccount?.id, Self.reachesRelay(model) else { return }
        let key = account + "/" + entry.area.uuidString
        if let existing = hostedPortalSessions[key] { existing.start(); return }
        do {
            // The portal's agents and liveness share the area's host session.
            let hostKey = account + "/" + entry.area.uuidString
            let host = try sharedAreaHostSessions[hostKey] ?? SharedAreaHostSession(account: model, area: entry.area, supervisor: agentSupervisor)
            sharedAreaHostSessions[hostKey] = host
            let session = SharedPortalHostSession(entry: entry, host: host, app: self)
            hostedPortalSessions[key] = session
            session.start()
        } catch {
            fputs("startHostingPortal failed: \(error)\n", stderr)
        }
    }

    /// At launch: every portal this Mac shares is hosted again.
    func resumeHostedPortals() {
        guard let model = try? collaborationAccountModel(),
              let remembered = model.activeAccount?.id ?? model.selectedAccountID ?? (model.accounts.count == 1 ? model.accounts.first?.id : nil),
              hostedPortalIndex?.entries(account: remembered).isEmpty == false else { return }
        Task { [weak self] in
            guard let self else { return }
            if model.status != .ready { _ = try? await model.select(accountID: remembered) }
            guard model.status == .ready, let account = model.activeAccount?.id,
                  let entries = hostedPortalIndex?.entries(account: account), !entries.isEmpty else { return }
            for entry in entries { startHostingPortal(entry, model: model) }
            refreshHostedPortalMarks()
        }
    }

    func hostedPortalSession(area: UUID) -> SharedPortalHostSession? {
        hostedPortalSessions.values.first { $0.area == area }
    }

    /// "Shared · Checkout" on every tile this Mac shares through a portal.
    func refreshHostedPortalMarks() {
        guard let canvas = canvasView, let index = hostedPortalIndex, let model = try? collaborationAccountModel(),
              let account = model.activeAccount?.id ?? model.selectedAccountID else { return }
        let me = model.activeAccount?.identity.person
        let colour = me.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemPurple
        var marked = Set<UUID>()
        for entry in index.entries(account: account) {
            let people = hostedAgentPeople[entry.area] ?? []
            let text = people.isEmpty ? "Yours · shared in \(entry.name)" : "Yours · shared with " + ListFormatter.localizedString(byJoining: people)
            for shared in entry.tiles {
                guard let view = canvas.tileView(for: shared.tile) else { continue }
                marked.insert(shared.tile)
                let mark = TileNSView.OwnershipMark(text: text, colour: colour, outlined: false)
                if view.ownershipMark != mark { view.setOwnershipMark(mark) }
            }
        }
        for tile in index.markedTiles.subtracting(marked) {
            canvas.tileView(for: tile)?.setOwnershipMark(nil)
        }
        index.markedTiles = marked
    }

    /// Camera moves reach every host surface, so cursors stay on their tiles.
    func portalCameraApplied(user: Bool) {
        for session in hostedPortalSessions.values { session.cameraApplied(user: user) }
    }

    // MARK: Add to share

    /// A tile changed. If it is not shared but now sits inside a portal's
    /// region, offer "Add to share" on it. Nothing is published until pressed.
    func portalNoticeTileChange(_ tileId: UUID) {
        guard !hostedPortalSessions.isEmpty, let canvas = canvasView, let record = canvas.tileRecord(for: tileId),
              SharedPortal.ItemKind.forTile(record.kind) != nil, hostedPortalArea(forTile: tileId) == nil,
              let view = canvas.tileView(for: tileId) else { return }
        let world = canvas.worldFrame(forTileFrame: record.frame, tileId: tileId)
        let rect = CGRect(x: world.x, y: world.y, width: world.width, height: world.height)
        guard let session = hostedPortalSessions.values.first(where: { $0.worldRegion()?.intersects(rect) == true }) else {
            view.subviews.filter { $0 is SharedPortalAddPill }.forEach { $0.removeFromSuperview() }
            return
        }
        guard !view.subviews.contains(where: { $0 is SharedPortalAddPill }) else { return }
        let pill = SharedPortalAddPill(title: "Add to share · \(session.entry.name)")
        let area = session.area
        pill.onPress = { [weak self, weak pill] in
            pill?.removeFromSuperview()
            Task { @MainActor [weak self] in
                do { try await self?.addToPortal(area: area, tiles: [tileId]) }
                catch { fputs("Add to share failed: \(error)\n", stderr) }
            }
        }
        let size = pill.preferredSize
        pill.frame = NSRect(x: max(8, view.bounds.width - size.width - 12), y: view.isFlipped ? TileNSView.titleBarHeight + 8 : view.bounds.height - TileNSView.titleBarHeight - size.height - 8,
                            width: size.width, height: size.height)
        pill.autoresizingMask = view.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        view.addSubview(pill, positioned: .above, relativeTo: nil)
        Task { @MainActor [weak pill] in
            try? await Task.sleep(for: .seconds(12))
            pill?.removeFromSuperview()
        }
    }

    /// "Add to share": the tiles join the portal, at their own positions.
    func addToPortal(area: UUID, tiles: [UUID]) async throws {
        guard let session = hostedPortalSession(area: area) else { throw SharedPortalError.notHosted }
        let model = try await shareLinks.readyAccount()
        try await session.add(tiles: tiles, model: model)
    }
}

/// "Add to share · Checkout": offered on a tile dragged into a shared region.
@MainActor
final class SharedPortalAddPill: NSView {
    let title: String
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.token(.label), .foregroundColor: AccentToken.accentWorking.color.nsColor(in: self)]
    }
    var preferredSize: NSSize { NSSize(width: ceil((title as NSString).size(withAttributes: attributes).width) + 28, height: 26) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill(); pill.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); pill.lineWidth = 1; pill.stroke()
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 14, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
