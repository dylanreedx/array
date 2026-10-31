import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// One shared area open on this person's canvas, in its zone
/// (`.plans/105-collaboration/IN-CANVAS.md`, option A). It replaces the shared
/// window: the area's subscription, the scene mounted as the zone's body,
/// presence, follow, and the shared moves of tiles lent to the area. It owns no
/// runner, and nothing it does is written to a project's `canvas.json`.
@MainActor
final class SharedAreaZoneSession {
    let controller: SharedAreaController
    let scene: SharedAreaSceneView
    let presencePublisher: SharedAreaPresencePublisher
    let zoneId: UUID
    let areaId: UUID
    /// The account the area was opened through, for capture and invites.
    weak var account: CollaborationAccountController?
    var onRequestInvite: (() -> Void)? { didSet { scene.onRequestInvite = onRequestInvite } }
    var onClose: (() -> Void)?
    /// The area host's handoff controller: what a teammate's prompt goes through.
    var prompter: SharedAgentHandoffController? { didSet { scene.zonePrompter = prompter } }
    private weak var canvas: CanvasNSView?
    private var openTask: Task<Void, Never>?
    private var escMonitor: Any?
    private var lentMoveTask: Task<Void, Never>?
    private(set) var isClosed = false

    init(controller: SharedAreaController, person: SharedArea.ID<SharedArea.Person>, zoneId: UUID, areaId: UUID,
         canvas: CanvasNSView) {
        self.controller = controller; self.zoneId = zoneId; self.areaId = areaId; self.canvas = canvas
        scene = SharedAreaSceneView(controller: controller, person: person, presentation: .zone)
        presencePublisher = SharedAreaPresencePublisher(scene: scene)
        scene.outerViewportSize = canvas.bounds.size
        canvas.installSharedAreaLayer(zoneId: zoneId, body: scene)
        scene.mount()
        scene.onDriveCanvasCamera = { [weak self] value in self?.driveCamera(value) }
        scene.onHostOfflineChange = { [weak canvas] offline in canvas?.setSharedAreaHostOffline(offline, zoneId: zoneId) }
        scene.onPositionsChanged = { [weak self] positions in self?.placeLentTiles(positions) }
        presencePublisher.onFollowChange = { [weak self] device, name in self?.followChanged(device: device, name: name) }
        presencePublisher.overlay.cursorColour = { [weak self] peer in
            guard let self else { return nil }
            let host = SharedAreaPersonColour.host(of: controller.document, me: scene.person, role: controller.scope?.role)
            return SharedAreaPersonColour.color(for: peer.identity.person, host: host)
        }
        refreshLentTiles()
        canvasCameraApplied(canvas.viewport, user: false)
    }

    func show() {
        guard !isClosed else { return }
        presencePublisher.start()
        guard openTask == nil else { return }
        openTask = Task { [weak self] in
            guard let self, !isClosed else { return }
            await controller.open()
        }
    }
    func waitUntilOpen() async { await openTask?.value }

    /// Takes the area off the canvas: presence ends, the scene unmounts, the
    /// body leaves the zone. The zone itself is the runtime's to keep or close.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        openTask?.cancel(); openTask = nil
        lentMoveTask?.cancel(); lentMoveTask = nil
        presencePublisher.stop()
        try? scene.prepareToClose()
        scene.unmount()
        if let canvas, canvas.sharedAreaLayer(for: zoneId)?.body === scene {
            canvas.installSharedAreaLayer(zoneId: zoneId, body: nil)
        }
        let controller = controller
        Task { await controller.close() }
        onClose?()
    }

    /// Brings the zone into view, fitted, without arming it.
    func reveal() {
        guard let canvas, let zone = canvas.sharedAreaZonePlacement(zoneId) else { return }
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let zoom = min(1, (size.width - 80) / zone.size.width, (size.height - 80) / zone.size.height)
        canvas.setViewport(CanvasViewport(x: zone.origin.x + zone.size.width / 2 - size.width / zoom / 2,
                                          y: zone.origin.y + zone.size.height / 2 - size.height / zoom / 2, zoom: max(0.1, zoom)))
    }

    // MARK: Camera

    /// The canvas camera moved: the scene publishes what of the area is in view.
    func canvasCameraApplied(_ viewport: CanvasViewport, user: Bool) {
        guard !isClosed, let canvas, let zone = canvas.sharedAreaZonePlacement(zoneId) else { return }
        scene.outerViewportSize = canvas.bounds.size
        scene.canvasCameraChanged(.init(x: viewport.x - zone.origin.x, y: viewport.y - zone.origin.y, zoom: viewport.zoom), user: user)
    }
    /// Follow (and keyboard panning in the area) moves the canvas camera. This
    /// is a programmatic camera write: it is not the user's interaction.
    private func driveCamera(_ value: SharedAreaLocalView) {
        guard let canvas, let zone = canvas.sharedAreaZonePlacement(zoneId) else { return }
        canvas.setViewport(CanvasViewport(x: zone.origin.x + value.x, y: zone.origin.y + value.y, zoom: value.zoom))
    }

    private func followChanged(device: UUID?, name: String) {
        scene.zoneHeader.followedDevice = device
        guard let canvas else { return }
        if let device, let peer = controller.presence.first(where: { $0.identity.device == device }) {
            let host = SharedAreaPersonColour.host(of: controller.document, me: scene.person, role: controller.scope?.role)
            canvas.showFollowIndicator(name: name, color: SharedAreaPersonColour.color(for: peer.identity.person, host: host))
            canvas.onFollowStopRequested = { [weak self] in self?.presencePublisher.stopFollowing(notice: nil) }
            if escMonitor == nil {
                escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak canvas] event in
                    guard let self, event.keyCode == 53, event.window === canvas?.window,
                          presencePublisher.followedDevice != nil else { return event }
                    presencePublisher.stopFollowing(notice: nil)
                    return nil
                }
            }
        } else {
            canvas.hideFollowIndicator()
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
            escMonitor = nil
        }
    }

    // MARK: Lent tiles

    /// The lent tiles bound to an item show the item; the scene draws no
    /// second view of them, and the area's positions place them.
    func refreshLentTiles() {
        let lent = canvas?.sharedAreaLayer(for: zoneId)?.lent ?? []
        scene.locallyShownObjects = Set(lent.compactMap { $0.object.map(SharedArea.ID<SharedArea.Object>.init) })
        if let positions = controller.document?.positions { placeLentTiles(positions) }
    }
    private func placeLentTiles(_ positions: [SharedArea.Position]) {
        guard let canvas, let layer = canvas.sharedAreaLayer(for: zoneId) else { return }
        for lent in layer.lent {
            guard let object = lent.object, let position = positions.last(where: { $0.object.rawValue == object }) else { continue }
            canvas.setLentTileAreaFrame(lent.home.id, TileFrame(x: position.rect.x, y: position.rect.y,
                width: position.rect.width, height: position.rect.height), zoneId: zoneId)
        }
    }
    /// A lent tile was dragged in the area: the drop is a shared `.place`
    /// through the scene's geometry ledger, with its undo and delivery rules.
    func lentTileMoved(_ tileId: UUID, to frame: TileFrame, committed: Bool) {
        guard committed, let canvas, let lent = canvas.lentTile(tileId)?.tile, let object = lent.object,
              let position = controller.document?.positions.last(where: { $0.object.rawValue == object }) else { return }
        guard scene.beginGeometry(placements: [position.id], kind: .move),
              scene.updateGeometry(frames: [position.id: .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)]) else {
            scene.cancelGeometry()
            if let positions = controller.document?.positions { placeLentTiles(positions) }
            return
        }
        lentMoveTask = Task { [weak self] in
            guard let self else { return }
            await scene.finishGeometry()
            if let positions = controller.document?.positions { placeLentTiles(positions) }
        }
    }
    func waitForLentMove() async { await lentMoveTask?.value }

    /// Lays published objects out at their tiles' area frames, in one command.
    func place(_ objects: [UUID: SharedArea.ID<SharedArea.Object>], at frames: [UUID: SharedArea.Rect]) async {
        guard let document = controller.document else { return }
        let edits: [SharedArea.Edit] = objects.sorted(by: { $0.key.uuidString < $1.key.uuidString }).compactMap { tile, object in
            guard let frame = frames[tile], let position = document.positions.last(where: { $0.object == object }) else { return nil }
            return .place(.init(id: position.id, object: object, rect: frame, z: position.z))
        }
        guard !edits.isEmpty else { return }
        _ = await controller.submit(.init(area: document.id, expectedRevision: document.revision, edits: edits))
        refreshLentTiles()
    }
    /// Takes published objects back out of the area (undo of a share).
    func removePublished(_ objects: [SharedArea.ID<SharedArea.Object>]) async {
        guard let document = controller.document else { return }
        let present = objects.filter { object in document.items.contains { $0.id == object } }
        guard !present.isEmpty else { return }
        _ = await controller.submit(.init(area: document.id, expectedRevision: document.revision, edits: present.map { .remove($0) }))
    }
}

extension AppDelegate {
    /// Opens a shared area in its zone on this canvas: this workspace's zone for
    /// the area, or a new one beside everything else. The zone is revealed and
    /// never armed. Replaces the shared window.
    @discardableResult
    func openSharedAreaZone(controller: SharedAreaController, person: SharedArea.ID<SharedArea.Person>,
                            area: UUID, accountID: String, name: String) throws -> SharedAreaZoneSession {
        guard let runtime = sharedAreaRuntime, let canvas = canvasView else { throw WorkspaceRuntime.SharedZoneError.noCanvas }
        let key = accountID + "/" + area.uuidString
        if let existing = sharedAreaZoneSessions[key], !existing.isClosed, runtime.sharedAreaZone(for: area)?.zoneId == existing.zoneId {
            existing.reveal(); existing.show()
            return existing
        }
        sharedAreaZoneSessions[key]?.close()
        let zone = try runtime.ensureSharedAreaZone(areaId: area, name: name)
        wireSharedAreaZoneCallbacks(canvas: canvas, runtime: runtime)
        let session = SharedAreaZoneSession(controller: controller, person: person, zoneId: zone.zoneId, areaId: area, canvas: canvas)
        sharedAreaZoneSessions[key] = session
        session.onClose = { [weak self, weak session] in
            guard let self, let session, sharedAreaZoneSessions[key] === session else { return }
            sharedAreaZoneSessions.removeValue(forKey: key)
        }
        session.show()
        session.reveal()
        return session
    }

    /// What sharing tiles produced: the new area, its zone on this canvas, and
    /// the shared object each source-bound tile became (notes are discussion,
    /// which carries no source binding, so they are not in the map).
    struct SharedZoneShare: Equatable {
        let areaId: UUID
        let zoneId: UUID
        let objects: [UUID: SharedArea.ID<SharedArea.Object>]
    }

    /// The whole sender side in one call (coordinator decision, 31 October):
    /// creates an area named `name`, publishes the tiles by kind through the
    /// share-link coordinator, opens the area's zone here, moves the tiles into
    /// it (same views, runners kept), binds each published tile to its object
    /// and lays the objects out where the tiles now sit. Part 1 then mints the
    /// link with `shareLinks.createShareLink(area:slug:lifetime:)`.
    ///
    /// Everything that can be refused is refused before anything leaves this
    /// Mac. If the zone cannot take the tiles after publishing, the area is
    /// emptied again and nothing on the canvas moves.
    func createSharedZone(fromTiles tileIds: [UUID], name: String) async throws -> SharedZoneShare {
        guard let runtime = sharedAreaRuntime, let canvas = canvasView else { throw WorkspaceRuntime.SharedZoneError.noCanvas }
        guard !tileIds.isEmpty else { throw WorkspaceRuntime.SharedZoneError.noTiles }
        var keys = Set<SharedAreaPublication.SourceKey>()
        for id in tileIds {
            let lendable: (tile: Tile, world: TileFrame, zone: ZonePlacement)
            do { lendable = try canvas.lendableTile(id) } catch let error as CanvasNSView.SharedAreaLendError {
                switch error {
                case .terminalStaysPrivate(let tile): throw WorkspaceRuntime.SharedZoneError.terminalStaysPrivate(tile)
                case .alreadyLent(let tile): throw WorkspaceRuntime.SharedZoneError.alreadyShared(tile)
                case .tileNotInstalled(let tile), .noSharedLayer(let tile): throw WorkspaceRuntime.SharedZoneError.tileNotInstalled(tile)
                }
            }
            guard let project = lendable.zone.projectId else { throw WorkspaceRuntime.SharedZoneError.tileNotInstalled(id) }
            keys.insert(.init(projectID: project, tileID: id))
        }
        let model = try await shareLinks.readyAccount()
        guard let person = model.activeAccount?.identity.person else { throw ShareLinkFailure.notSignedIn }
        let area = try await model.createArea(label: name).scope.area.rawValue
        let objects = try await shareLinks.publish(selection: .tiles(keys), intoArea: area)
        guard let session = openSharedArea(controller: try model.makeSharedAreaController(area: area), person: person,
                                           area: area, model: model) else { throw WorkspaceRuntime.SharedZoneError.noCanvas }
        await session.waitUntilOpen()
        let conversion: WorkspaceRuntime.SharedZoneConversion
        do { conversion = try runtime.createSharedZone(fromTiles: tileIds, areaId: area, name: name) } catch {
            await session.removePublished(Array(objects.values))
            closeSharedAreaZone(session.zoneId)
            throw error
        }
        for (tile, object) in objects { runtime.bindSharedTile(tile, to: object, inZone: conversion.zoneId) }
        await session.place(objects, at: conversion.areaFrames)
        return SharedZoneShare(areaId: area, zoneId: conversion.zoneId, objects: objects)
    }

    /// Undo of `createSharedZone`: what it published leaves the area when the
    /// area can still be reached, the tiles go home with their own views at
    /// their pre-share frames, and the zone leaves this canvas.
    func cancelSharedZone(areaId: UUID) async {
        guard let runtime = sharedAreaRuntime, let zone = runtime.sharedAreaZone(for: areaId) else { return }
        let bound = canvasView?.sharedAreaLayer(for: zone.zoneId)?.lent.compactMap(\.object) ?? []
        if let session = sharedAreaZoneSessions.values.first(where: { $0.zoneId == zone.zoneId && !$0.isClosed }) {
            await session.removePublished(bound.map(SharedArea.ID<SharedArea.Object>.init))
        }
        closeSharedAreaZone(zone.zoneId)
    }

    /// The zone's ✕: the area leaves this canvas and any lent tiles go home.
    func closeSharedAreaZone(_ zoneId: UUID) {
        for session in sharedAreaZoneSessions.values where session.zoneId == zoneId { session.close() }
        do { try sharedAreaRuntime?.cancelSharedZone(zoneId) } catch {
            fputs("closeSharedAreaZone failed: \(error)\n", stderr)
        }
    }

    /// One owner for the canvas callbacks every open area shares.
    private func wireSharedAreaZoneCallbacks(canvas: CanvasNSView, runtime: WorkspaceRuntime) {
        canvas.onCameraApplied = { [weak self] viewport, user in
            for session in self?.sharedAreaZoneSessions.values.map({ $0 }) ?? [] { session.canvasCameraApplied(viewport, user: user) }
        }
        canvas.onLentTileMoved = { [weak self] zoneId, tileId, frame, committed in
            self?.sharedAreaZoneSessions.values.first(where: { $0.zoneId == zoneId && !$0.isClosed })?
                .lentTileMoved(tileId, to: frame, committed: committed)
        }
        runtime.onSharedZoneChanged = { [weak self, weak runtime] zoneId in
            guard let self else { return }
            for session in sharedAreaZoneSessions.values where session.zoneId == zoneId {
                if runtime?.document.zones.contains(where: { $0.zoneId == zoneId }) == true { session.refreshLentTiles() }
                else { session.close() }
            }
        }
    }
}

extension AppDelegate: SharedZoneCreating {}
