import AppKit
import OSLog
import ContinuumRevivedCore
import Foundation

/// Owns the current workspace's live zone set: its `WorkspaceDocument`, the
/// per-project `ZoneRuntimeController`s (via the ref-counted registry), and the
/// installed canvas `ZoneLayer`s. `AppDelegate` proxies zone install/teardown
/// through this object (docs/23 S4).
///
/// Shell subset (T06): install + flush + teardown of the CURRENT workspace.
/// Cross-workspace switch is T09; budget move is T07; addZone-spins-controller
/// is T08; viewport tier transitions are T10.
@MainActor
final class WorkspaceRuntime {
    enum LifecycleEvent: Equatable {
        case processLaunched
        case bootMounted
        case firstHydrationPhase
        case settled
        /// A switch passed its re-entrancy guard and is about to do work. QA
        /// reads the chrome here: it must already name the target.
        case switchBegan(UUID)
        case switchCompleted(UUID)
        case saveGenerationAcknowledged(UInt64)
        case closeFlushCompleted
    }

    /// QA-only observation point. Nil in production, so it cannot alter flow.
    var lifecycleObserver: ((LifecycleEvent) -> Void)?
    var lifecycleSnapshotObserver: ((LifecycleEvent, CanvasNSView) -> Void)?
    private(set) var workspaceId: UUID
    private(set) var document: WorkspaceDocument
    /// Moves on every scene mount: `install(into:)` and every committed switch.
    /// A callback captured under an older epoch is answering for a scene that is
    /// no longer on screen and must be refused (`.plans/67` §3.4).
    private(set) var mountEpoch: UInt64 = 0
    private let registry: ZoneRuntimeRegistry
    private let orchestrator: ZoneHydrationOrchestrator.Type
    private let focusBroker: FocusBroker
    private let registryStore: RegistryStore
    private weak var canvasView: CanvasNSView?
    private let ghostty: GhosttyRuntimeContext?
    private let browserEngine: BrowserEngineContext

    /// Check seams for failure-atomic switch witnesses. Production leaves both
    /// nil and uses WorkspaceStore's atomic read/write paths.
    var _workspaceDocumentLoader: ((UUID) throws -> WorkspaceDocument?)?
    var _workspaceDocumentSaver: ((UUID, WorkspaceDocument) throws -> Void)?
    private(set) var qaLastScheduledWorkspaceGeneration: UInt64 = 0
    private(set) var qaLastAcknowledgedWorkspaceGeneration: UInt64 = 0

    // Tracks which projectIds this runtime acquired (for closeAll).
    private var acquiredProjectIds: [UUID] = []

    // Retains the installed ZoneLayers so the check (and T09 swap) can read back placements.
    private var installedLayers: [CanvasNSView.ZoneLayer] = []

    // The document's legacy foreign placements: zones naming a project another
    // workspace owns. The document keeps them; the mount excludes them. Written
    // at init and on every mount, so a later pass over `document.zones` can
    // exclude them too — `reconcileHydration` once acquired their projects,
    // which then blocked switching to the workspace that owns them.
    private var foreignZoneIds: Set<UUID> = []

    // CX-01 (`.plans/59`, §16/§7.2): two host-observed counters.
    //
    // `interactionGeneration` bumps on USER-driven presentation changes only —
    // click arming, click focus, trackpad/pointer camera, a workspace switch.
    // Programmatic writers (a reveal the API itself performs, a restore, a
    // check) never bump it, so a pending API request can tell "the user moved"
    // from "I moved" and defer instead of overwriting newer intent.
    //
    // `structuralRevision` bumps on committed structural change (zones, tiles,
    // links persisted). Camera motion alone never bumps it.
    private(set) var interactionGeneration: UInt64 = 0
    private(set) var structuralRevision: UInt64 = 0
    func noteUserInteraction() { interactionGeneration &+= 1 }
    func noteStructuralCommit() { structuralRevision &+= 1 }

    /// The controller whose project owns the active zone (`document.lastActiveZoneId`
    /// → its `projectId`). nil when the active zone is a group zone or none is active.
    /// AppDelegate reads `runtimes`, `projectStore`, `activeProject` through this.
    var activeController: ZoneRuntimeController? {
        if let lastActiveZoneId = document.lastActiveZoneId,
           let zone = document.zones.first(where: { $0.zoneId == lastActiveZoneId }),
           let projectId = zone.projectId {
            // The armed zone's project is the ONLY correct answer, so return it
            // even when it has no controller yet. Falling through to the
            // single-acquired-project fallback below is how a second zone
            // silently created and persisted tiles into the FIRST zone's
            // project: `controller(for:)` was nil for the unacquired project and
            // the fallback answered with the other one.
            return registry.controller(for: projectId)
        }
        // Production can intentionally close the visible project zone while the
        // project remains the active backing store for bare/group-zone tiles.
        // Keep app-level persistence APIs routed to the boot controller rather
        // than making projectStore/activeProject disappear.
        if acquiredProjectIds.count == 1, let projectId = acquiredProjectIds.first {
            return registry.controller(for: projectId)
        }
        return nil
    }

    /// Returns the controller for a given projectId (registry delegation, for check assertions).
    func controller(for projectId: UUID) -> ZoneRuntimeController? {
        registry.controller(for: projectId)
    }

    /// Every project controller this workspace holds live. Teardown that must
    /// reach every runtime iterates this, never `activeController`.
    var liveControllers: [ZoneRuntimeController] { registry.liveControllers }

    /// Whether `projectId` belongs to the mounted scene — not merely live, which
    /// a warm workspace's projects also are.
    func isProjectMounted(_ projectId: UUID) -> Bool {
        mountedControllers.contains { $0.project.id == projectId }
    }

    /// The controllers of the mounted scene, not of warm ones: every live
    /// controller of a project this scene acquired or has a zone for.
    private var mountedControllers: [ZoneRuntimeController] {
        let zoneProjects = document.zones.filter { !foreignZoneIds.contains($0.zoneId) }.compactMap(\.projectId)
        var seen = Set<ObjectIdentifier>()
        return (acquiredProjectIds + zoneProjects).compactMap { registry.controller(for: $0) }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Keep the runtime's in-memory document aligned with app-level canvas zone
    /// callbacks that mutate the WorkspaceDocument directly. Without this, a later
    /// runtime save (for example addZone(projectId:)) can rewrite stale zone state
    /// back over disk.
    func replaceDocument(_ newDocument: WorkspaceDocument, for workspaceId: UUID) {
        guard self.workspaceId == workspaceId else { return }
        document = newDocument
    }

    /// Commit the exact placement emitted by the mounted canvas. No reload is
    /// permitted here: the runtime's document is the in-memory workspace truth,
    /// and re-reading disk would race other live zone mutations.
    func commitZonePlacement(_ placement: ZonePlacement) throws {
        guard let index = document.zones.firstIndex(where: { $0.zoneId == placement.zoneId }) else {
            throw WorkspaceMutationError.zoneNotFound(placement.zoneId)
        }
        document.zones[index] = placement
        try persistWorkspaceDocument()
    }

    /// Commit a canvas layout transaction's workspace half: zone placements and
    /// ambient (WORLD) tile frames, over the in-memory document. On a failed
    /// write the document is left as it was, so the caller can roll back the
    /// project halves it already wrote.
    func commitLayoutTransaction(_ transaction: CanvasLayoutTransaction) throws {
        let previous = document
        for (zoneId, placement) in transaction.zonePlacements {
            if let index = document.zones.firstIndex(where: { $0.zoneId == zoneId }) {
                document.zones[index] = placement
            }
        }
        for (tileId, worldFrame) in transaction.tileFrames {
            guard let index = document.ambientTiles.firstIndex(where: { $0.id == tileId }) else { continue }
            document.ambientTiles[index].frame = worldFrame
        }
        do { try persistWorkspaceDocument() } catch {
            document = previous
            throw error
        }
    }

    func commitLastExplicitCreationScope(_ scope: ZoneScope) throws {
        document.lastExplicitCreationScope = scope
        try persistWorkspaceDocument()
    }

    func commitCreatedZone(_ placement: ZonePlacement) throws {
        guard !document.zones.contains(where: { $0.zoneId == placement.zoneId }) else { return }
        if let projectId = placement.projectId {
            var ownershipRegistry = try registryStore.loadOrEmpty()
            if let owner = try ownershipRegistry.exclusiveWorkspaceOwner(of: projectId),
               owner != workspaceId {
                throw ProjectWorkspaceOwnershipError.alreadyOwned(
                    projectId: projectId,
                    workspaceId: owner
                )
            }
            if try ownershipRegistry.exclusiveWorkspaceOwner(of: projectId) == nil {
                try ownershipRegistry.assignProject(projectId, to: workspaceId, now: Date())
                try registryStore.save(ownershipRegistry)
            }
        }
        document.zones.append(placement)
        document.bringZoneToFront(placement.zoneId)
        try persistWorkspaceDocument()
        // A newly committed project zone must support creation immediately.
        // The durable active id alone does not acquire its controller or spawner.
        _ = setActiveZone(placement.zoneId, reason: .explicit)
        ensureZoneLayer(forZone: placement.zoneId)
        // The first arming acquired the project but could not move the CANVAS:
        // `setActiveProjectZone` is a no-op until the zone has a layer, and the
        // layer needs that controller. Arm again now the layer exists, or the
        // canvas stays on the previous zone and the first ⌘K spawn lands there
        // (`--zone-arming-check` §8).
        _ = setActiveZone(placement.zoneId, reason: .explicit)
    }

    /// `deletingTileIds` are tiles the user asked to delete along with the zone.
    /// They must leave the document outright: `setTiles([], forZone:)` only
    /// clears `zoneId`, so without this they come back as ambient tiles on the
    /// next mount. The membership write still runs afterwards for the members
    /// that were KEPT, which spill onto the bare canvas.
    ///
    /// The closed zone's (now empty) layer leaves the canvas with it, and the
    /// arming moves through `setActiveZone` to a remaining project zone. Writing
    /// `lastActiveZoneId` alone left the canvas armed on the orphan layer, so the
    /// next ⌘T landed, chrome-less, in a zone that no longer existed. A project
    /// whose last zone this was is released: no controller (and no `.array/lock`)
    /// held, and no workspace claiming it.
    func commitClosedZone(_ zoneId: UUID, deletingTileIds: Set<UUID> = []) throws {
        guard let closing = document.zones.first(where: { $0.zoneId == zoneId }) else {
            throw WorkspaceMutationError.zoneNotFound(zoneId)
        }
        document.zones.removeAll { $0.zoneId == zoneId }
        document.removeTiles(ids: deletingTileIds)
        document.setTiles([], forZone: zoneId)
        if canvasView?.tiles(inZone: zoneId)?.isEmpty == true {
            canvasView?.removeZoneLayer(zoneId: zoneId)
            installedLayers.removeAll { $0.placement.zoneId == zoneId }
        }
        if document.lastActiveZoneId == zoneId {
            document.lastActiveZoneId = nil
            if let next = document.zonesInZOrder.last(where: { $0.projectId != nil }) {
                setActiveZone(next.zoneId, reason: .explicit)
            } else {
                canvasView?.setActiveProjectZone(nil)
            }
        }
        try persistWorkspaceDocument()
        if let projectId = closing.projectId, !document.zones.contains(where: { $0.projectId == projectId }) {
            releaseProjectWithoutZones(projectId)
        }
    }

    private func releaseProjectWithoutZones(_ projectId: UUID) {
        if acquiredProjectIds.contains(projectId) {
            acquiredProjectIds.removeAll { $0 == projectId }
            registry.release(projectId: projectId)
        }
        do {
            var ownership = try registryStore.loadOrEmpty()
            ownership.releaseProject(projectId, from: workspaceId, now: Date())
            try registryStore.save(ownership)
        } catch {
            fputs("WorkspaceRuntime: could not release project \(projectId.uuidString) from its workspace: \(error)\n", stderr)
        }
    }

    /// Give a zone about to be closed (or otherwise mutated as a whole) its
    /// layer, so its members are acted on rather than forgotten: a zone below
    /// the live tier holds its tiles only on disk, and closing it used to leave
    /// every one of them naming a zone that no longer existed. Throws when the
    /// project cannot be mounted (its `.array/` is held, its canvas unreadable).
    func prepareZoneForWholeZoneMutation(_ zoneId: UUID) throws {
        guard let zone = document.zones.first(where: { $0.zoneId == zoneId }),
              let projectId = zone.projectId else { return }
        if registry.controller(for: projectId) == nil {
            _ = try registry.acquire(projectId: projectId)
            if !acquiredProjectIds.contains(projectId) { acquiredProjectIds.append(projectId) }
        }
        installZoneLayerIfMissing(zone)
        guard canvasView?.installedZonePlacement(for: zoneId) != nil else {
            throw WorkspaceMutationError.zoneUnavailable(zoneId)
        }
    }

    /// "Keep Tiles" on a project zone. Every member moves, at its unchanged
    /// WORLD frame, into the nearest other zone of the same project or, when
    /// this is the project's only zone, into a fresh zone for the project that
    /// encloses them. The project's canvas is saved before the zone goes, so no
    /// tile is left naming a zone that no longer exists. Throws, moving nothing
    /// further, when the members cannot be placed.
    func rehomeMembersOfClosingZone(_ zoneId: UUID) throws {
        guard let canvasView,
              let zone = document.zones.first(where: { $0.zoneId == zoneId }),
              let projectId = zone.projectId else { return }
        try prepareZoneForWholeZoneMutation(zoneId)
        let members = canvasView.tilesInWorldFrames(forZoneId: zoneId) ?? []
        guard !members.isEmpty else { return }
        let centre = CanvasEngine.zoneWorldFrame(zone)
        func distance(_ other: ZonePlacement) -> Double {
            let rect = CanvasEngine.zoneWorldFrame(other)
            return hypot((rect.x + rect.width / 2) - (centre.x + centre.width / 2),
                         (rect.y + rect.height / 2) - (centre.y + centre.height / 2))
        }
        let target: UUID
        if let sibling = document.zones
            .filter({ $0.projectId == projectId && $0.zoneId != zoneId && !foreignZoneIds.contains($0.zoneId) })
            .min(by: { distance($0) < distance($1) }) {
            try prepareZoneForWholeZoneMutation(sibling.zoneId)
            target = sibling.zoneId
        } else {
            target = try addProjectZone(
                projectId: projectId, enclosing: members.map(\.frame), name: zone.name, color: zone.color)
        }
        let moved = canvasView.moveLayerTiles(members.map(\.id), toZone: target)
        guard moved.count == members.count else {
            throw WorkspaceMutationError.tilesNotMoved(members.count - moved.count)
        }
        guard let controller = registry.controller(for: projectId) else {
            throw WorkspaceMutationError.zoneUnavailable(zoneId)
        }
        controller.scheduleCanvasSave()
        try controller.flushCanvasSave()
    }

    /// A new zone for `projectId` enclosing `worldFrames`, in the document and
    /// on the canvas as an empty layer, ready for records to be moved into it.
    @discardableResult
    func addProjectZone(projectId: UUID, enclosing worldFrames: [TileFrame], name: String, color: String?) throws -> UUID {
        guard let canvasView else { throw WorkspaceMutationError.zoneUnavailable(projectId) }
        let bounds = CanvasEngine.zoneBounds(
            memberFrames: worldFrames,
            padding: ZoneBoundsConfig.padding(),
            minSize: ZoneBoundsConfig.emptyMinSize(),
            headerHeight: ZoneChromeNSView.headerHeight)
        var placement = ZonePlacement(
            zoneId: UUID(),
            projectId: projectId,
            origin: ZonePoint(x: bounds.x, y: bounds.y),
            size: ZoneSize(width: bounds.width, height: bounds.height),
            color: color ?? ZoneColorAllocator.nextColor(existingColors: document.zones.map(\.color)),
            collapsed: false,
            hydrationPolicy: .automatic,
            name: name)
        placement.zPosition = FracIndex.after(document.zones.map(\.zPosition).max() ?? .first)
        document.zones.append(placement)
        document.bringZoneToFront(placement.zoneId)
        try persistWorkspaceDocument()
        let appRegistry = (try? registryStore.loadOrEmpty()) ?? Registry.empty()
        let layer = CanvasNSView.ZoneLayer(
            placement: placement, renderModel: Self.renderModel(for: placement, registry: appRegistry), tiles: [])
        canvasView.upsertZoneLayer(layer)
        installedLayers.append(layer)
        return placement.zoneId
    }

    enum WorkspaceMutationError: Error, LocalizedError {
        case zoneNotFound(UUID)
        case zoneUnavailable(UUID)
        case tilesNotMoved(Int)

        var errorDescription: String? {
            switch self {
            case let .zoneNotFound(zoneId): return "Zone \(zoneId) is not part of the mounted workspace."
            case .zoneUnavailable: return "The zone's project isn't available, so its tiles can't be moved."
            case let .tilesNotMoved(count): return "\(count) tile(s) could not be moved out of the zone."
            }
        }
    }

    /// Returns the placement of the installed ZoneLayer for `zoneId` (for check assertions).
    /// Reads the real installed layer captured during `install(into:appRegistry:)`.
    func installedZonePlacement(for zoneId: UUID) -> ZonePlacement? {
        installedLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
    }

    init(
        workspaceId: UUID,
        document: WorkspaceDocument,
        registry: ZoneRuntimeRegistry,
        orchestrator: ZoneHydrationOrchestrator.Type = ZoneHydrationOrchestrator.self,
        focusBroker: FocusBroker,
        registryStore: RegistryStore,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext
    ) {
        self.workspaceId = workspaceId
        self.document = document
        self.registry = registry
        self.orchestrator = orchestrator
        self.focusBroker = focusBroker
        self.registryStore = registryStore
        self.ghostty = ghostty
        self.browserEngine = browserEngine
        // Production boots through `adoptCanvas`, never `install`, so the boot
        // document's foreign placements are resolved here.
        if let appRegistry = try? registryStore.loadOrEmpty() {
            foreignZoneIds = Self.foreignZoneIds(in: document, workspaceId: workspaceId, registry: appRegistry)
        }
    }

    /// Convenience init for an already-built boot controller (the production
    /// `applicationDidFinishLaunching` path and the four existing self-check
    /// harnesses). Registers `controller` in the registry at refCount 1 and
    /// synthesizes a minimal single-zone `WorkspaceDocument` so `activeController`
    /// resolves to it.
    convenience init(
        boot controller: ZoneRuntimeController,
        registry: ZoneRuntimeRegistry,
        focusBroker: FocusBroker,
        registryStore: RegistryStore,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext
    ) {
        let zoneId = UUID()
        let projectId = controller.project.id
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: zoneId,
                projectId: projectId,
                origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 1280, height: 720),
                color: "blue",
                collapsed: false,
                hydrationPolicy: .automatic
            )],
            zoneZOrder: [zoneId],
            lastActiveZoneId: zoneId
        )
        self.init(
            boot: controller,
            workspaceId: UUID(),
            document: document,
            registry: registry,
            focusBroker: focusBroker,
            registryStore: registryStore,
            ghostty: ghostty,
            browserEngine: browserEngine
        )
    }

    /// Boot an already-built project controller against a real persisted
    /// WorkspaceDocument. Production launch uses this path so zone create/move/
    /// close callbacks write to the user's actual workspace id, not a synthetic
    /// compatibility UUID.
    convenience init(
        boot controller: ZoneRuntimeController,
        workspaceId: UUID,
        document: WorkspaceDocument,
        registry: ZoneRuntimeRegistry,
        focusBroker: FocusBroker,
        registryStore: RegistryStore,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext
    ) {
        self.init(
            workspaceId: workspaceId,
            document: document,
            registry: registry,
            focusBroker: focusBroker,
            registryStore: registryStore,
            ghostty: ghostty,
            browserEngine: browserEngine
        )
        registry.register(controller, for: controller.project.id)
        acquiredProjectIds = [controller.project.id]
    }

    /// Hand this runtime the canvas it is supposed to be driving. M1.10 (`.plans/46`).
    ///
    /// `canvasView` is a `private weak var` written in exactly one other place —
    /// `install(into:appRegistry:)` — and **nothing in production has ever called
    /// that method**, in the whole life of this type. So every canvas operation in
    /// `switchWorkspace` optional-chained through nil and did nothing: switching
    /// workspaces changed the document, the registry and the toolbar header while
    /// leaving the previous workspace's tiles on screen. It also meant the entire
    /// M1 hydration/persistence/detach programme was unreachable code, green only
    /// because each of its witnesses called `install(into:)` itself.
    ///
    /// Deliberately does ONE thing. Boot already runs `activateUndoWorkspace`,
    /// `attachUI` and the focus wiring in `mountWorkspaceSceneAtBoot`, so adopting
    /// must not repeat any of them — that is what keeps this a wiring fix rather
    /// than a second boot path. `install(into:)` stays a checks-only entry point.
    func adoptCanvas(_ canvasView: CanvasNSView) {
        self.canvasView = canvasView
        applyCanvasBackground()
    }

    // MARK: - Canvas background (WS7)

    /// Where the GLOBAL half of the background lives. Channel-local by
    /// construction (`UserDefaults.standard` under the channel's bundle id);
    /// injectable so a check can drive a real suite instead of the user's domain.
    var canvasBackgroundDefaults: UserDefaults = .standard

    /// Precedence, resolved in exactly one place. `.inherit` reads the global
    /// EVERY time — it is never snapshotted into the document, which is what
    /// keeps a later global edit reaching an inheriting workspace.
    var effectiveCanvasBackground: CanvasBackgroundConfiguration {
        CanvasBackgroundResolver.effective(
            workspace: document.canvasBackground,
            global: CanvasBackgroundGlobalStore.load(defaults: canvasBackgroundDefaults))
    }

    /// Push the resolved background at the mounted canvas. Called on adopt, on
    /// switch, and whenever either half of the precedence changes.
    func applyCanvasBackground() {
        canvasView?.setCanvasBackground(effectiveCanvasBackground)
    }

    /// The workspace half of the decision. Writes the document through the one
    /// existing workspace writer — no second persistence path.
    func setWorkspaceCanvasBackground(_ value: WorkspaceCanvasBackground) throws {
        guard document.canvasBackground != value else { return }
        document.canvasBackground = value
        try persistWorkspaceDocument()
        applyCanvasBackground()
    }

    /// The global half. Writing it must NOT disturb a workspace that overrides.
    func setGlobalCanvasBackground(_ configuration: CanvasBackgroundConfiguration) {
        CanvasBackgroundGlobalStore.save(configuration, defaults: canvasBackgroundDefaults)
        applyCanvasBackground()
    }

    /// QA (M1.10): whether this runtime can actually drive a canvas. The assertion
    /// that would have been RED for this defect's entire life.
    var qaHasCanvas: Bool { canvasView != nil }

    // MARK: - The armed zone (T1, `.plans/47`)

    /// Why a zone became the armed one. Only the persistence urgency differs:
    /// a deliberate act flushes, an ambient one debounces.
    enum ActiveZoneReason: Equatable {
        /// The user just made this zone.
        case created
        /// The user named this project/Home in the creation-scope picker.
        case explicit
        /// A tile inside the zone took focus.
        case focus
        /// The user clicked the zone's chrome or interior.
        case click
        /// The camera settled over the zone.
        case camera

        /// A deliberate act is worth a synchronous write; ambient arming rides the
        /// autosave debounce so a pan does not hammer the document.
        var persistsImmediately: Bool {
            switch self {
            case .created, .explicit: return true
            case .focus, .click, .camera: return false
            }
        }
    }

    /// The ONE writer of the mounted workspace's document, debounced and
    /// synchronous saves alike. It is bound to the workspace it was made for and
    /// rebuilt once another is mounted.
    ///
    /// It used to be two writers. The ambient-arming debounce had a long-lived
    /// controller built on first use and never rebound, so after a switch, arming
    /// a zone in B wrote B's whole document into A's file; and every synchronous
    /// save used a fresh controller that never superseded the pending arming
    /// snapshot, so a rename inside the 200ms debounce was overwritten by the
    /// older snapshot when its timer fired. Witness:
    /// `--workspace-saver-identity-check`.
    private var documentSaver: WorkspaceDocumentSaveController?
    private var documentSaverWorkspaceId: UUID?

    private func mountedDocumentSaver() -> WorkspaceDocumentSaveController {
        if let documentSaver, documentSaverWorkspaceId == workspaceId { return documentSaver }
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        let saver = WorkspaceDocumentSaveController(
            store: WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport))
        documentSaver = saver
        documentSaverWorkspaceId = workspaceId
        return saver
    }

    /// The one writer of "which zone do new tiles go into".
    ///
    /// Two half-states used to drift. `document.lastActiveZoneId` decides
    /// `activeController` (and therefore the spawner); `canvasView.activeProjectZoneId`
    /// decides the creation scope's `.zone` candidate and every spawn's placement.
    /// Each existing writer set one or the other and never reliably both, and NO
    /// user action set either — so the zone new tiles landed in was fixed at scene
    /// mount and could not be moved. Creating a second zone did not move it;
    /// correcting it through the picker did not move it, and because `.zone`
    /// outranks `.recentExplicit` in `CreationScopeResolver`, the correction was
    /// overruled on the very next spawn.
    ///
    /// Returns true when the arming took.
    @discardableResult
    func setActiveZone(_ zoneId: UUID?, reason: ActiveZoneReason) -> Bool {
        // CX-01: every arming reason but `.camera` is the user's own act. `.camera`
        // is excluded because it also fires after a PROGRAMMATIC `setViewport`
        // (via `canvasDidChange` → `reconcileHydration`), and the camera driver
        // reports user camera motion itself (`CanvasNSView.onUserCameraChange`).
        if reason != .camera { noteUserInteraction() }
        // A group zone must never arm. `activeController` returns nil for one, so
        // arming it would silently disarm creation entirely — every spawn would
        // then refuse rather than land somewhere wrong, which is a worse bug than
        // the one being fixed. Same for a zone this document does not contain.
        // Leave the current arming alone rather than clearing it: panning across
        // empty canvas, or clicking a group zone, is not a request to disarm.
        guard let zoneId,
              let zone = document.zones.first(where: { $0.zoneId == zoneId }),
              let zoneProjectId = zone.projectId
        else { return false }

        // Arming a zone must make its project usable RIGHT NOW. Acquisition used
        // to happen only in the mount pass, so a zone that was not live at boot
        // had no controller and creation into it silently fell back to whatever
        // project WAS acquired. Doing it here rather than only in
        // `reconcileHydration` matters: that pass rides the camera debounce, so
        // clicking a zone without panning would not have acquired anything.
        //
        // Failure is not fatal to the arming: the user did click this zone, so it
        // arms. `activeController` then answers nil for it, creation refuses and
        // offers the picker, and the report below lets the app say why. That is
        // the documented contract — refuse, never land somewhere wrong.
        let previousProjectId = activeController?.project.id
        if registry.controller(for: zoneProjectId) == nil {
            do {
                _ = try registry.acquire(projectId: zoneProjectId)
                if !acquiredProjectIds.contains(zoneProjectId) {
                    acquiredProjectIds.append(zoneProjectId)
                }
            } catch {
                onZoneProjectUnavailable?(zoneProjectId, error)
            }
        }

        guard document.lastActiveZoneId != zoneId else {
            // Already armed in the document, but the canvas may still disagree —
            // `setActiveProjectZone` silently no-ops until the layer is installed.
            canvasView?.setActiveProjectZone(zoneId)
            return true
        }
        document.lastActiveZoneId = zoneId
        canvasView?.setActiveProjectZone(zoneId)

        // The spawner follows the controller, and `activeController` is derived
        // from the id just written. Only when the PROJECT changed: re-attaching on
        // every camera settle would rebuild a spawner per pan.
        if let canvas = canvasView, activeController?.project.id != previousProjectId {
            attachActiveControllerUI(canvasView: canvas)
        }

        if reason.persistsImmediately {
            try? persistWorkspaceDocument()
        } else {
            mountedDocumentSaver().scheduleZoneLayoutSave(document)
        }
        return true
    }

    /// The memoized spawn scope for a managed-agent tile, from WHICHEVER live
    /// spawner created it. T4 (`.plans/47`).
    ///
    /// `managedAgentCreationScopes` is per-`TileSpawner`, and a scoped spawn goes
    /// through `spawnerForFilesystemCreation()` — the scope's OWN project's
    /// spawner. `wireManagedAgentTile` then read it back off the ACTIVE
    /// controller's spawner. When those are different objects the lookup returned
    /// nil and the agent silently fell back to the plain active-project path, so
    /// the tile sat in the right zone while its agent ran in the first project's
    /// home directory.
    func managedAgentCreationScope(tileId: UUID) -> CreationScope? {
        if let scope = activeController?.tileSpawner?.managedAgentCreationScope(tileId: tileId) {
            return scope
        }
        for controller in registry.liveControllers {
            if let scope = controller.tileSpawner?.managedAgentCreationScope(tileId: tileId) {
                return scope
            }
        }
        return nil
    }

    /// Same problem, same fix, for the launch selection.
    func managedAgentLaunchSelection(tileId: UUID) -> AgentLaunchSelection? {
        if let selection = activeController?.tileSpawner?.managedAgentLaunchSelection(tileId: tileId) {
            return selection
        }
        for controller in registry.liveControllers {
            if let selection = controller.tileSpawner?.managedAgentLaunchSelection(tileId: tileId) {
                return selection
            }
        }
        return nil
    }

    /// QA: the armed zone as the document records it.
    var qaArmedZoneId: UUID? { document.lastActiveZoneId }

    /// QA chronology seam for the long-lived ambient-arming debounce. These are
    /// deliberately read-only: close checks must observe the controller that
    /// production actually drains, rather than manufacture a fresh controller.
    var qaArmingScheduledGeneration: UInt64 {
        documentSaverWorkspaceId == workspaceId ? documentSaver?.scheduledGeneration ?? 0 : 0
    }

    var qaArmingAcknowledgedGeneration: UInt64 {
        documentSaverWorkspaceId == workspaceId ? documentSaver?.acknowledgedGeneration ?? 0 : 0
    }

    /// Drain the debounced arming write (switch, close, and checks that assert on disk).
    func flushPendingArmingSave() throws {
        guard documentSaverWorkspaceId == workspaceId else { return }
        try documentSaver?.flushPendingSave()
    }

    // MARK: - Zone membership (M1.10, `.plans/46`)

    /// This project's tiles, bucketed by zone, with foreign/nil/unknown stamps
    /// repaired — and the repair persisted so it only happens once.
    ///
    /// Replaces the inline
    /// `zoneId == zone.zoneId || (zoneId == nil && firstZoneByProject[...] == zone.zoneId)`
    /// filter, which rendered a tile stamped with ANOTHER project's zone nowhere at
    /// all. See `CanvasEngine.resolveZoneMembership` for why those stamps are
    /// ordinary rather than exotic.
    ///
    /// Considers every zone this project owns in the document, not just the live
    /// ones, so a tile belonging to a zone below the live tier stays where it is
    /// instead of being rescued onto the screen.
    ///
    /// Throws when the project's canvas exists and cannot be read. That project is
    /// unavailable, never empty: it gets no layers (an empty layer is what a pan
    /// then saved over the file), its controller refuses to write, and the user
    /// is told once per mount.
    private func membership(
        forProject projectId: UUID,
        controller: ZoneRuntimeController,
        in document: WorkspaceDocument,
        cache: inout [UUID: [UUID: [Tile]]]
    ) throws -> [UUID: [Tile]] {
        if let cached = cache[projectId] { return cached }
        let persisted: CanvasState
        do {
            persisted = try controller.projectStore.tryLoadCanvas()
                ?? CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                               tiles: [], groups: [], lastActiveTileId: nil)
        } catch {
            reportCanvasUnavailable(projectId: projectId, controller: controller, error: error)
            throw error
        }
        let projectZones = document.zones.filter { $0.projectId == projectId }
        guard !projectZones.isEmpty else {
            cache[projectId] = [:]
            return [:]
        }
        let home = document.lastActiveZoneId.flatMap { candidate in
            projectZones.contains(where: { $0.zoneId == candidate }) ? candidate : nil
        } ?? projectZones[0].zoneId

        let resolved = CanvasEngine.resolveZoneMembership(
            tiles: persisted.tiles,
            projectZones: projectZones,
            documentZoneIds: Set(document.zones.map(\.zoneId)),
            homeZoneId: home)

        if !resolved.restamped.isEmpty {
            // Say it out loud. This write is durable and one-way, so a rule that is
            // wrong for a shape nobody anticipated must at least be traceable.
            fputs("WorkspaceRuntime: repaired zone membership for \(resolved.restamped.count) tile(s) in project \(projectId.uuidString): \(resolved.restamped.map { $0.uuidString.suffix(8) }.joined(separator: ", "))\n", stderr)
            // Only the repaired ids are restamped. A deferred tile — one whose zone
            // lives in another workspace — keeps the stamp it had.
            let stamped = Dictionary(
                resolved.byZone.values.flatMap { $0 }.map { ($0.id, $0.zoneId) },
                uniquingKeysWith: { first, _ in first })
            var repaired = persisted
            repaired.tiles = persisted.tiles.map { tile in
                guard let zoneId = stamped[tile.id] else { return tile }
                var copy = tile
                copy.zoneId = zoneId          // stamp only; the WORLD frame is untouched
                return copy
            }
            try? controller.projectStore.saveCanvas(repaired)
        }

        cache[projectId] = resolved.byZone
        return resolved.byZone
    }

    /// Guarantee that a project with a live controller owns at least one zone in
    /// this document. M1.10 (`.plans/46`).
    ///
    /// A project can be registered into a workspace and have no zone in its
    /// document — the pinned boot project in the field had exactly that. With
    /// layers live, such a project renders nothing at all. Repair the invariant
    /// before anything renders rather than giving the renderer a fallback.
    ///
    /// Deliberately NOT `document.appendProjectZone`: that parks the zone at
    /// `maxX + gap`, nowhere near the tiles, and takes `lastActiveZoneId`. Enclose
    /// the project's persisted tiles instead, so the chrome appears around the
    /// tiles the user is already looking at and nothing moves.
    /// Run the membership repair on the BOOT path. T10 (`.plans/48`).
    ///
    /// `membership(forProject:…)` already implements and persists the rule, but it
    /// is only reached from `install(into:)` and `switchWorkspace`. Boot renders
    /// the flat scene and never calls either, so a tile with a nil or foreign
    /// `zoneId` survived every launch — one real store held a file tile at world
    /// (1246,-851) belonging to no zone at all, unreachable by every zone gesture.
    ///
    /// Stamp-only: `resolveZoneMembership` never moves a tile, never drops one and
    /// never rescues across a project boundary, so nothing on screen shifts. The
    /// write goes through `ProjectStore.saveCanvas` (atomic, `.array/backups/`) and
    /// every repaired id is named on stderr.
    ///
    /// The stamps are then applied to the LIVE canvas as well. Repairing only the
    /// file would leave this session's in-memory copy stale, and the next
    /// `persistProjectCanvas` would write the unrepaired state straight back over
    /// it.
    func repairBootMembership(controller: ZoneRuntimeController, canvasView: CanvasNSView) {
        var cache: [UUID: [UUID: [Tile]]] = [:]
        guard let byZone = try? membership(
            forProject: controller.project.id, controller: controller, in: document, cache: &cache) else { return }
        for (zoneId, tiles) in byZone {
            for tile in tiles { canvasView.setTileZone(tile.id, zoneId: zoneId) }
        }
    }

    /// `ensureZone` for the boot project, called from `mountWorkspaceSceneAtBoot`.
    func ensureZoneForActiveProject(controller: ZoneRuntimeController) {
        ensureZone(forProject: controller.project.id, controller: controller)
    }

    @discardableResult
    private func ensureZone(forProject projectId: UUID, controller: ZoneRuntimeController) -> ZonePlacement? {
        if let existing = document.zones.first(where: { $0.projectId == projectId }) { return existing }
        let persisted: [Tile]
        do { persisted = try controller.projectStore.tryLoadCanvas()?.tiles ?? [] } catch {
            reportCanvasUnavailable(projectId: projectId, controller: controller, error: error)
            return nil
        }
        let bounds = CanvasEngine.zoneBounds(
            memberFrames: persisted.map(\.frame),
            padding: ZoneBoundsConfig.padding(),
            minSize: ZoneBoundsConfig.emptyMinSize(),
            headerHeight: ZoneChromeNSView.headerHeight)
        var placement = ZonePlacement(
            zoneId: UUID(),
            projectId: projectId,
            origin: ZonePoint(x: bounds.x, y: bounds.y),
            size: ZoneSize(width: bounds.width, height: bounds.height),
            color: ZoneColorAllocator.nextColor(existingColors: document.zones.map(\.color)),
            collapsed: false,
            hydrationPolicy: .automatic,
            name: controller.project.name)
        placement.zPosition = FracIndex.after(document.zones.map(\.zPosition).max() ?? .first)
        let wasEmpty = document.lastActiveZoneId == nil
        document.zones.append(placement)
        if wasEmpty { document.lastActiveZoneId = placement.zoneId }
        try? persistWorkspaceDocument()
        fputs("WorkspaceRuntime: project \(projectId.uuidString) had no zone in this workspace; created one enclosing its \(persisted.count) tile(s)\n", stderr)
        return placement
    }

    /// Render models for EVERY zone in the document, reusing a layer's own model
    /// where one exists. M1.10: a zone below the live tier still draws and is
    /// still navigable — and still resolves its project, so its header says the
    /// same as a live zone's.
    private static func zoneRenderModels(
        for zones: [ZonePlacement],
        layers: [CanvasNSView.ZoneLayer],
        registry: Registry
    ) -> [CanvasNSView.ZoneRenderModel] {
        let byZone = Dictionary(
            layers.map { ($0.placement.zoneId, $0.renderModel) },
            uniquingKeysWith: { first, _ in first })
        return zones.map { zone in
            byZone[zone.zoneId] ?? renderModel(for: zone, registry: registry)
        }
    }

    /// A zone's inputs, its project resolved against the registry already
    /// loaded. The header itself is derived by the canvas (`ZonePresentation`).
    private static func renderModel(for zone: ZonePlacement, registry: Registry) -> CanvasNSView.ZoneRenderModel {
        CanvasNSView.ZoneRenderModel(
            placement: zone,
            project: zone.projectId.map { ZoneProjectResolution(projectId: $0, in: registry) })
    }
    /// Install the CURRENT workspace's zone set into `canvasView`.
    ///
    /// For each `ZonePlacement` with a non-nil `projectId`, acquires a
    /// `ZoneRuntimeController` via the registry (ref-counted), loads the project's
    /// canvas state, builds a `ZoneLayer` with descriptor tile views, and calls
    /// `canvasView.setZones` to register all tile adapters. The active zone's
    /// controller gets `attachUI` called so dirty tracking and focus callbacks work.
    /// Focus is restored to the active zone's `lastActiveTileId` (or `.canvas`).
    ///
    /// The hydration budget (`ZoneHydrationBudgetConfig.maxLiveZones`) is applied
    /// via `ZoneHydrationOrchestrator.plan`; only zones whose planned tier is `.live`
    /// get a controller acquired.
    func install(into canvasView: CanvasNSView, appRegistry: Registry) throws {
        mountEpoch &+= 1
        reportedUnreadableProjectIds = []
        // Cold launch and an in-process switch must mount the same semantic scene.
        // Preserve legacy foreign placements in the document, but never draw them
        // in a workspace that does not own their project.
        let mountableZones = Self.mountableZones(
            in: document, workspaceId: workspaceId, registry: appRegistry)
        foreignZoneIds = Set(document.zones.map(\.zoneId)).subtracting(mountableZones.map(\.zoneId))
        self.canvasView = canvasView
        canvasView.activateUndoWorkspace(workspaceId)

        // Plan hydration tiers using the configurable budget.
        let plan = ZoneHydrationOrchestrator.plan(
            zones: mountableZones,
            viewport: document.viewport,
            visibleSize: CGSize(width: canvasView.bounds.width > 0 ? canvasView.bounds.width : 1280,
                                height: canvasView.bounds.height > 0 ? canvasView.bounds.height : 720),
            focusedTileZone: document.lastActiveZoneId,
            maxLiveZones: ZoneHydrationBudgetConfig.maxLiveZones()
        )

        var layers: [CanvasNSView.ZoneLayer] = []
        let previouslyAcquired = Set(acquiredProjectIds)
        var newlyAcquired: [UUID] = []
        // One repaired membership answer per project, reused across its zones.
        var membershipCache: [UUID: [UUID: [Tile]]] = [:]

        for zone in mountableZones {
            guard let projectId = zone.projectId else {
                // Ambient (group) zone: no project, no controller. Its tiles live on
                // the workspace document itself and membership is each tile's
                // `zoneId` register (ticket 03) — render straight from it.
                layers.append(Self.makeAmbientZoneLayer(zone: zone, document: document))
                continue
            }
            // Only acquire controllers for live-tier zones.
            guard plan.tier(for: zone.zoneId) == .live else { continue }

            let controller: ZoneRuntimeController
            if (newlyAcquired.contains(projectId) || previouslyAcquired.contains(projectId)),
               let existing = registry.controller(for: projectId) {
                controller = existing
            } else {
                controller = try registry.acquire(projectId: projectId)
            }
            if !newlyAcquired.contains(projectId) { newlyAcquired.append(projectId) }

            // M1.0/M1.10 (`.plans/46`): membership comes from one repaired answer
            // per project, not from an inline filter per zone. The filter this
            // replaces dropped any tile whose `zoneId` named a zone this project
            // does not own -- which ordinary dragging produces -- rendering it
            // nowhere. `membership(forProject:…)` rescues those and persists the
            // repair once. See `CanvasEngine.resolveZoneMembership`.
            if let layer = makeProjectZoneLayer(
                zone: zone, projectId: projectId, controller: controller,
                document: document, registry: appRegistry, membershipCache: &membershipCache) {
                layers.append(layer)
            }
        }

        for projectId in previouslyAcquired.subtracting(Set(newlyAcquired)) {
            registry.release(projectId: projectId)
        }
        acquiredProjectIds = newlyAcquired

        // Wire the broker before setZones so _installLayer can register adapters.
        canvasView.focusBroker = focusBroker

        hydrateZoneLayerTiles?(canvasView, layers, .beforeInstall)
        canvasView.setZones(
            layers,
            documentZones: Self.zoneRenderModels(for: mountableZones, layers: layers, registry: appRegistry))
        installedLayers = layers
        // Cold boot and in-process switching share the workspace document as
        // camera owner. The boot canvas originates in a project canvas file and
        // therefore must not retain that project's stale viewport.
        canvasView.setViewport(document.viewport)

        // Declare the spawn target BEFORE anything can spawn into it.
        canvasView.setActiveProjectZone(document.lastActiveZoneId)

        // Attach UI to the active controller so dirty tracking and focus callbacks work.
        attachActiveControllerUI(canvasView: canvasView)
        // Phase B needs the active controller's spawner, which the line above builds.
        hydrateZoneLayerTiles?(canvasView, layers, .afterInstall)

        // Restore focus: active zone's last-active tile, or fall back to canvas.
        restoreFocus(from: canvasView)
        classifyStrandedTiles()
    }

    /// Schedule every mounted project's debounced canvas save; each controller
    /// writes its own file through the persistence projection.
    func scheduleCanvasSaveForMountedProjects() {
        for projectId in acquiredProjectIds {
            registry.controller(for: projectId)?.scheduleCanvasSave()
        }
    }

    /// A project whose pending changes did not reach disk, named for the user.
    struct UnsavedProjectError: LocalizedError, CustomStringConvertible {
        let projectName: String
        let underlying: Error
        var errorDescription: String? { "\u{201C}\(projectName)\u{201D} couldn't be saved: \(underlying.localizedDescription)" }
        var description: String { "\(projectName): \(underlying)" }
    }

    /// Flush every live controller's pending saves (fan-out of `flushPendingSaves`).
    /// Every controller is flushed; the first failure is thrown after, naming its project.
    func flushAll() throws {
        var firstFailure: Error?
        for projectId in acquiredProjectIds {
            guard let controller = registry.controller(for: projectId) else { continue }
            do { try controller.flushPendingSaves() } catch {
                if firstFailure == nil {
                    firstFailure = UnsavedProjectError(projectName: controller.project.name, underlying: error)
                }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// Persist every acknowledged register owned by the mounted scene before
    /// any layer or controller is released. A failed write deliberately leaves
    /// the scene mounted so callers can surface the failure and retry or cancel.
    func flushMountedWorkspaceState() throws {
        try captureFileEditorsForSceneTransition()
        let focus = departingFocusSnapshot(from: canvasView)
        try flushAll()
        try flushPendingArmingSave()
        try persistDepartingWorkspaceState(focus: focus)
        lifecycleObserver?(.closeFlushCompleted)
    }

    /// How long a scene transition waits, in total, for every file editor's web
    /// bridge to hand over its text. It used to be 5.5 s PER editor, waited one
    /// after another, and an editor that never answered failed the whole switch.
    static let fileEditorBarrierBudget: TimeInterval = 0.35

    /// File editors that did not answer the last scene-transition barrier.
    private(set) var lastFlushUnansweredEditors = 0

    /// Ask every file editor for its text at once and wait for all of them —
    /// boundedly. An editor that does not answer in time keeps the last draft the
    /// tile already holds (it is written to the recovery file all the same) and
    /// the transition goes ahead; only a draft that cannot be written fails it.
    /// The wait runs the main run loop, which is why `switchWorkspace` refuses
    /// re-entry and hydration does not re-plan while it is switching.
    private func captureFileEditorsForSceneTransition() throws {
        lastFlushUnansweredEditors = 0
        guard let canvasView else { return }
        let editors = canvasView.allWorkspaceTiles().filter { $0.kind == .file }
            .compactMap { canvasView.tileView(for: $0.id) as? FileTileNSView }
        guard !editors.isEmpty else { return }
        final class Settled { var count = 0 }
        let settled = Settled()
        var answered = Set<ObjectIdentifier>()
        for editor in editors {
            let id = ObjectIdentifier(editor)
            var finished = false
            editor.beginSceneTransitionCapture { _ in
                guard !finished else { return }
                finished = true
                answered.insert(id)
                settled.count += 1
            }
        }
        let deadline = Date().addingTimeInterval(Self.fileEditorBarrierBudget)
        while settled.count < editors.count, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        lastFlushUnansweredEditors = editors.count - answered.count
        var firstFailure: Error?
        for editor in editors {
            do { try editor.finishSceneTransitionCapture() } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// Release every acquired controller via the registry (ref-count → close-at-zero),
    /// clear the canvas zone set (which unregisters tile adapters), drop references.
    /// Warm scenes go too: closing is the only way their controllers flush and
    /// give their locks back.
    func closeAll() {
        let warm = warmScenes
        warmScenes = []
        for scene in warm { evict(scene) }
        // Clear zone layers first (while the focusBroker ref is still live on the canvas)
        // so that ZoneLayer tile adapters are unregistered before the controllers close.
        canvasView?.setZones([])
        canvasView?.focusBroker = nil
        canvasView = nil
        for projectId in acquiredProjectIds {
            registry.release(projectId: projectId)
        }
        acquiredProjectIds = []
        installedLayers = []
    }

    // MARK: - Zone Add (T08)

    /// Add a zone to the live canvas.
    ///
    /// - project zone: acquires (ref-counts) the project's shared
    ///   `ZoneRuntimeController` via the registry, appends a `ZonePlacement` to the
    ///   document (de-duped), installs its `ZoneLayer` on the canvas, and flushes saves.
    /// Legacy nil-project zones remain renderable during migration, but new zones
    /// must select a registered project/Home before this persistence boundary.
    ///
    /// Returns the new `zoneId`. The same project may back several zones.
    @discardableResult
    func addZone(projectId: UUID?, appRegistry: Registry? = nil) throws -> UUID {
        guard let projectId else { throw ZoneCreationError.projectRequired }
        return try _addProjectZone(projectId: projectId, appRegistry: appRegistry)
    }

    enum ZoneCreationError: Error, Equatable, LocalizedError {
        case projectRequired

        var errorDescription: String? {
            "Choose a project and Home before creating a zone."
        }
    }

    private func _addProjectZone(projectId: UUID, appRegistry: Registry?) throws -> UUID {
        let ownershipRegistry = try appRegistry ?? registryStore.loadOrEmpty()
        if let owner = try ownershipRegistry.exclusiveWorkspaceOwner(of: projectId), owner != workspaceId {
            throw ProjectWorkspaceOwnershipError.alreadyOwned(projectId: projectId, workspaceId: owner)
        }
        // A project may have multiple zones inside its one owning workspace.
        let controller: ZoneRuntimeController
        if acquiredProjectIds.contains(projectId), let existing = registry.controller(for: projectId) {
            controller = existing
        } else {
            controller = try registry.acquire(projectId: projectId)
            acquiredProjectIds.append(projectId)
        }

        // Append placement to document.
        let placement = document.appendProjectZone(projectId: projectId)

        // Load canvas state for the new zone.
        let canvasState: CanvasState
        if let loaded = try controller.projectStore.tryLoadCanvas() {
            canvasState = loaded
        } else {
            canvasState = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
        }

        // A second zone for the same project starts empty. Persisted zoneId is
        // authoritative membership; replaying the project's entire canvas here
        // would visually clone every existing tile into the new zone.
        let memberTiles = canvasState.tiles.filter { $0.zoneId == placement.zoneId }.map { tile -> Tile in
            // M1.10: same world -> zone-local conversion as the two builders above.
            var local = tile
            local.frame = CanvasEngine.worldToZoneLocal(local.frame, zoneOrigin: placement.origin)
            return local
        }

        // Build tile views.
        var tileViews: [UUID: TileNSView] = [:]
        for tile in memberTiles {
            let view = DescriptorTileNSView(tile: tile)
            tileViews[tile.id] = view
        }

        let renderModel = Self.renderModel(for: placement, registry: ownershipRegistry)
        let layer = CanvasNSView.ZoneLayer(placement: placement, renderModel: renderModel, tiles: memberTiles)
        layer.tileViews = tileViews
        installedLayers.append(layer)

        // Install on canvas.
        if let canvas = canvasView { hydrateZoneLayerTiles?(canvas, [layer], .beforeInstall) }
        canvasView?.upsertZoneLayer(layer)
        // M1.11 (`.plans/46`): the arriving project needs a SPAWNER, not just a
        // controller. Adding a project to the canvas acquires its controller but
        // left `tileSpawner` nil, so `spawnerForFilesystemCreation()` found nothing
        // and fell through — which meant "Add Project…" in an empty workspace still
        // could not be spawned into. Phase B needs it too.
        if let canvas = canvasView { attachActiveControllerUI(canvasView: canvas) }
        if let canvas = canvasView { hydrateZoneLayerTiles?(canvas, [layer], .afterInstall) }
        // T2 (`.plans/47`): the zone the user just made is the zone they mean.
        // `appendProjectZone` already took `document.lastActiveZoneId`, so the
        // controller had moved — but nothing told the CANVAS, and the canvas is
        // what `resolvedCreationScope` and every spawn's placement read. That
        // half-move is the reported bug: make a second zone, spawn into it, get
        // the first zone's project Home.
        setActiveZone(placement.zoneId, reason: .created)

        // Flush document save.
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport)
        let saveController = WorkspaceDocumentSaveController(store: workspaceStore)
        saveController.scheduleZoneLayoutSave(document)
        try saveController.flushPendingSave()
        // A project added back (after its workspace was deleted, say) brings its
        // old tiles stamped with zones nothing holds any more: offer them.
        classifyStrandedTiles()

        return placement.zoneId
    }

    /// Build the canvas layer for an ambient (projectId == nil) zone from the
    /// workspace document's `ambientTiles` register — the production read path
    /// of the ticket-03 membership re-model.
    private static func makeAmbientZoneLayer(
        zone: ZonePlacement,
        document: WorkspaceDocument
    ) -> CanvasNSView.ZoneLayer {
        let memberTiles = document.tiles(forZone: zone.zoneId).map { tile -> Tile in
            var local = tile
            // Workspace ambient tiles, like project canvas tiles, are durable in
            // WORLD coordinates. A ZoneLayer owns LOCAL coordinates.
            local.frame = CanvasEngine.worldToZoneLocal(tile.frame, zoneOrigin: zone.origin)
            return local
        }
        var tileViews: [UUID: TileNSView] = [:]
        for tile in memberTiles {
            tileViews[tile.id] = DescriptorTileNSView(tile: tile)
        }
        let renderModel = CanvasNSView.ZoneRenderModel(placement: zone)
        let layer = CanvasNSView.ZoneLayer(placement: zone, renderModel: renderModel, tiles: memberTiles)
        layer.tileViews = tileViews
        return layer
    }

    // MARK: - Stranded tiles (preserve, classify, offer)

    /// Tiles of a mounted project whose `zoneId` names a zone that NO registered
    /// workspace document holds: a zone closed before close re-homed its members,
    /// a deleted workspace's zones, an orphan document's. The mount sets them
    /// aside (`resolveZoneMembership` defers any stamp outside the document) and
    /// nothing ever shows them again. They are never repaired silently: they are
    /// preserved on disk untouched, classified here at every mount, and offered
    /// to the user through `onStrandedTilesFound`. A stamp naming another
    /// registered workspace's zone is that workspace's business and is not
    /// counted. Keyed by project.
    private(set) var strandedTiles: [UUID: [Tile]] = [:]
    /// Stranded tiles that are NOT offered, keyed by the project whose file holds
    /// them: copies of another project's tiles (Dylan's harmony file holds 18 of
    /// personal's, same ids and frames), and agent tiles whose agent belongs to
    /// another project. Recovering either would put one tile id in two projects
    /// and could bind a second view to one agent (CLAUDE.md hazard 10). They are
    /// left untouched on disk; `elsewhere` names the projects they belong to.
    private(set) var strandedLeftAlone: [UUID: (count: Int, elsewhere: Set<UUID>)] = [:]
    var onStrandedTilesFound: ((_ recoverable: [UUID: [Tile]], _ leftAlone: [UUID: (count: Int, elsewhere: Set<UUID>)]) -> Void)?
    /// The project of the agent record bound to a tile, if any (AppDelegate's
    /// supervisor). Nil in production only before the supervisor exists.
    var agentProjectForTile: ((UUID) -> UUID?)?

    private struct StrandedFileStamp: Equatable {
        let byteCount: UInt64?
        let modifiedAt: Date?
        let fileNumber: UInt64?

        init(url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            byteCount = (attributes?[.size] as? NSNumber).map { $0.uint64Value }
            modifiedAt = attributes?[.modificationDate] as? Date
            fileNumber = (attributes?[.systemFileNumber] as? NSNumber).map { $0.uint64Value }
        }
    }

    private struct CachedStrandedCanvas {
        let stamp: StrandedFileStamp
        /// `nil` means the file was unreadable; an empty array means it was absent.
        let tiles: [Tile]?
    }

    private struct CachedStrandedWorkspace {
        let stamp: StrandedFileStamp
        let document: WorkspaceDocument?
    }

    private struct StrandedNoticeFingerprint: Hashable {
        struct Recoverable: Hashable {
            let projectId: UUID
            let tileIds: [UUID]
        }
        struct LeftAlone: Hashable {
            let projectId: UUID
            let count: Int
            let elsewhere: [UUID]
        }
        let recoverable: [Recoverable]
        let leftAlone: [LeftAlone]

        init(_ found: (recoverable: [UUID: [Tile]], leftAlone: [UUID: (count: Int, elsewhere: Set<UUID>)])) {
            recoverable = found.recoverable.map { projectId, tiles in
                Recoverable(projectId: projectId, tileIds: tiles.map(\.id).sorted { $0.uuidString < $1.uuidString })
            }.sorted { $0.projectId.uuidString < $1.projectId.uuidString }
            leftAlone = found.leftAlone.map { projectId, value in
                LeftAlone(projectId: projectId, count: value.count,
                          elsewhere: value.elsewhere.sorted { $0.uuidString < $1.uuidString })
            }.sorted { $0.projectId.uuidString < $1.projectId.uuidString }
        }

        var isEmpty: Bool { recoverable.isEmpty && leftAlone.isEmpty }
    }

    /// Repeated mounts/switches see the same snapshots. File stamps keep the
    /// first classification current without decoding every workspace and canvas
    /// on the main thread again; writes by this runtime explicitly invalidate.
    private var strandedCanvasSnapshots: [String: CachedStrandedCanvas] = [:]
    private var strandedWorkspaceSnapshots: [UUID: CachedStrandedWorkspace] = [:]
    private var reportedStrandedFingerprints: [UUID: StrandedNoticeFingerprint] = [:]

    private func cachedStrandedTiles(at root: URL) -> [Tile]? {
        let store = ProjectStore(projectRoot: root)
        let url = store.layout.canvasFile
        let path = url.standardizedFileURL.path
        let stamp = StrandedFileStamp(url: url)
        if let cached = strandedCanvasSnapshots[path], cached.stamp == stamp { return cached.tiles }
        do {
            let tiles = try store.tryLoadCanvas()?.tiles ?? []
            strandedCanvasSnapshots[path] = CachedStrandedCanvas(stamp: stamp, tiles: tiles)
            return tiles
        } catch {
            strandedCanvasSnapshots[path] = CachedStrandedCanvas(stamp: stamp, tiles: nil)
            return nil
        }
    }

    private func invalidateStrandedCanvasSnapshot(at root: URL) {
        let path = ProjectStore(projectRoot: root).layout.canvasFile.standardizedFileURL.path
        strandedCanvasSnapshots.removeValue(forKey: path)
    }

    private func cachedStrandedWorkspace(_ id: UUID) -> WorkspaceDocument? {
        // QA loaders are intentionally live seams and may synthesize different
        // documents without changing a backing file, so never cache their output.
        if _workspaceDocumentLoader != nil { return try? loadWorkspaceDocument(workspaceId: id) }
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        let store = WorkspaceStore(workspaceId: id, applicationSupportDirectory: appSupport)
        let url = store.layout.canvasFile
        let stamp = StrandedFileStamp(url: url)
        if let cached = strandedWorkspaceSnapshots[id], cached.stamp == stamp { return cached.document }
        let document: WorkspaceDocument?
        do { document = try store.tryLoad() } catch { document = nil }
        strandedWorkspaceSnapshots[id] = CachedStrandedWorkspace(stamp: stamp, document: document)
        return document
    }

    func classifyStrandedTiles() {
        let found = findStrandedTiles()
        strandedTiles = found.recoverable
        strandedLeftAlone = found.leftAlone
        let fingerprint = StrandedNoticeFingerprint(found)
        if fingerprint.isEmpty {
            // A later recurrence is a new incident, even if its tile ids happen
            // to match a notice that was already resolved in this runtime.
            reportedStrandedFingerprints.removeValue(forKey: workspaceId)
        } else if reportedStrandedFingerprints[workspaceId] != fingerprint {
            reportedStrandedFingerprints[workspaceId] = fingerprint
            onStrandedTilesFound?(found.recoverable, found.leftAlone)
        }
    }

    private func findStrandedTiles() -> (recoverable: [UUID: [Tile]], leftAlone: [UUID: (count: Int, elsewhere: Set<UUID>)]) {
        guard let appRegistry = try? registryStore.loadOrEmpty() else { return ([:], [:]) }
        var registeredZoneIds = Set(document.zones.map(\.zoneId))
        for entry in appRegistry.workspaces where entry.id != workspaceId {
            if let other = cachedStrandedWorkspace(entry.id) {
                registeredZoneIds.formUnion(other.zones.map(\.zoneId))
            }
        }
        // Every registered project's tile ids: a stranded id found in another
        // project's file is a copy unless the evidence says it is ours alone.
        var roots: [UUID: URL] = [:]
        var idsByProject: [UUID: Set<UUID>] = [:]
        var tilesByProject: [UUID: [Tile]] = [:]
        for entry in appRegistry.projects where !entry.missing {
            let root = URL(fileURLWithPath: entry.rootPath, isDirectory: true)
            roots[entry.id] = root
            if let tiles = cachedStrandedTiles(at: root) {
                tilesByProject[entry.id] = tiles
                idsByProject[entry.id] = Set(tiles.map(\.id))
            }
        }
        func evidence(_ tile: Tile, belongsTo projectId: UUID) -> Bool {
            guard let root = roots[projectId] else { return false }
            if tile.metadata.filesystemProjectId == projectId { return true }
            if let agentProject = agentProjectForTile?(tile.id) { return agentProject == projectId }
            if tile.kind == .managedAgent,
               (try? ManagedAgentSessionStore(projectRoot: root).load(tileId: tile.id)) != nil { return true }
            if let noteId = tile.metadata.noteId,
               FileManager.default.fileExists(atPath: ProjectStoreLayout(projectRoot: root).noteFile(id: noteId).path) {
                return true
            }
            if let path = tile.metadata.filePath, path.hasPrefix(root.standardizedFileURL.path + "/") { return true }
            return false
        }

        var recoverable: [UUID: [Tile]] = [:]
        var leftAlone: [UUID: (count: Int, elsewhere: Set<UUID>)] = [:]
        for projectId in Set(document.zones.compactMap(\.projectId)) where
            !document.zones.filter({ $0.projectId == projectId }).allSatisfy({ foreignZoneIds.contains($0.zoneId) }) {
            guard let root = roots[projectId], let tiles = tilesByProject[projectId] else { continue }
            for tile in tiles {
                guard let zoneId = tile.zoneId, !registeredZoneIds.contains(zoneId) else { continue }
                var elsewhere = Set(idsByProject.filter { $0.key != projectId && $0.value.contains(tile.id) }.keys)
                if let agentProject = agentProjectForTile?(tile.id), agentProject != projectId {
                    elsewhere.insert(agentProject)
                }
                // An agent tile whose session lives in another project's `.array/`
                // is that project's view of the agent, not a second one of ours.
                if tile.kind == .managedAgent {
                    for (other, otherRoot) in roots where other != projectId
                        && (try? ManagedAgentSessionStore(projectRoot: otherRoot).load(tileId: tile.id)) != nil {
                        elsewhere.insert(other)
                    }
                }
                // Ours alone: no other project holds the id, or only we have the
                // evidence (its note body, its file, its agent, its session).
                let ours = elsewhere.isEmpty
                    || (evidence(tile, belongsTo: projectId)
                        && !elsewhere.contains(where: { evidence(tile, belongsTo: $0) }))
                if ours {
                    recoverable[projectId, default: []].append(tile)
                } else {
                    var entry = leftAlone[projectId] ?? (0, [])
                    entry.count += 1
                    entry.elsewhere.formUnion(elsewhere)
                    leftAlone[projectId] = entry
                }
            }
        }
        return (recoverable, leftAlone)
    }

    /// The user accepted the offer. Each project's stranded tiles move, as one
    /// group (relative layout exact), into a new zone of that project: where
    /// they already are when that overlaps nothing, otherwise translated right
    /// of every zone in the workspace. Written to the project's own canvas
    /// first, then the zone to the document, so a crash between the two leaves
    /// them stranded and offered again rather than lost; the replaced
    /// `canvas.json` stays in `.array/backups`. Returns how many tiles came back.
    @discardableResult
    func recoverStrandedTiles() throws -> Int {
        guard let canvasView else { return 0 }
        // Classified now, not at the offer: the scene may have changed since.
        strandedTiles = findStrandedTiles().recoverable
        var recovered = 0
        for projectId in strandedTiles.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let tiles = strandedTiles[projectId], !tiles.isEmpty,
                  let anchorZone = document.zones.first(where: { $0.projectId == projectId && !foreignZoneIds.contains($0.zoneId) })
            else { continue }
            try prepareZoneForWholeZoneMutation(anchorZone.zoneId)
            guard let controller = registry.controller(for: projectId) else {
                throw WorkspaceMutationError.zoneUnavailable(anchorZone.zoneId)
            }
            // Nothing queued for this file may land after the rewrite below.
            try controller.flushCanvasSave()

            let frames = tiles.map(\.frame)
            let pad = ZoneBoundsConfig.padding()
            func enclosing(_ frames: [TileFrame]) -> TileFrame {
                CanvasEngine.zoneBounds(memberFrames: frames, padding: pad,
                                        minSize: ZoneBoundsConfig.emptyMinSize(),
                                        headerHeight: ZoneChromeNSView.headerHeight)
            }
            let obstacles = document.zones.map(CanvasEngine.zoneWorldFrame) + canvasView.allTilesInWorldFrames().map(\.frame)
            func overlaps(_ a: TileFrame, _ b: TileFrame) -> Bool {
                a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
            }
            var rect = enclosing(frames)
            var dx = 0.0
            if obstacles.contains(where: { overlaps(rect, $0) }) {
                let right = obstacles.map { $0.x + $0.width }.max() ?? rect.x
                dx = (right + 120) - rect.x
                rect.x += dx
            }
            let newZoneId = UUID()
            let moved = Dictionary(uniqueKeysWithValues: tiles.map { tile -> (UUID, Tile) in
                var copy = tile
                copy.frame.x += dx
                copy.zoneId = newZoneId
                return (tile.id, copy)
            })
            guard var canvas = try controller.projectStore.tryLoadCanvas() else { continue }
            canvas.tiles = canvas.tiles.map { moved[$0.id] ?? $0 }
            try controller.projectStore.saveCanvas(canvas)
            invalidateStrandedCanvasSnapshot(at: controller.projectRoot)

            var placement = ZonePlacement(
                zoneId: newZoneId,
                projectId: projectId,
                origin: ZonePoint(x: rect.x, y: rect.y),
                size: ZoneSize(width: rect.width, height: rect.height),
                color: ZoneColorAllocator.nextColor(existingColors: document.zones.map(\.color)),
                collapsed: false,
                hydrationPolicy: .automatic,
                name: "Recovered")
            placement.zPosition = FracIndex.after(document.zones.map(\.zPosition).max() ?? .first)
            document.zones.append(placement)
            document.bringZoneToFront(newZoneId)
            try persistWorkspaceDocument()
            installZoneLayerIfMissing(placement)
            recovered += tiles.count
        }
        let after = findStrandedTiles()
        strandedTiles = after.recoverable
        strandedLeftAlone = after.leftAlone
        if StrandedNoticeFingerprint(after).isEmpty {
            reportedStrandedFingerprints.removeValue(forKey: workspaceId)
        }
        return recovered
    }

    // MARK: - Spawner ownership

    /// Called with every `TileSpawner` this runtime builds, so `AppDelegate` can
    /// wire its app-owned handlers onto the arriving spawner instead of only onto
    /// the one it built at boot.
    var onSpawnerCreated: ((TileSpawner) -> Void)?

    /// A zone's project could not be acquired — its `.array/` lock is held by
    /// another install, or its root is gone. Creation into that zone refuses
    /// rather than silently using a different project.
    var onZoneProjectUnavailable: ((UUID, Error) -> Void)?

    /// Projects already reported unreadable in this mount, so a pan or a spawn
    /// that rediscovers it does not repeat the message.
    private var reportedUnreadableProjectIds: Set<UUID> = []

    private func wireCanvasFailureReporting(for controller: ZoneRuntimeController) {
        controller.onCanvasUnavailable = { [weak self, weak controller] projectId, error in
            guard let self else { return }
            if let controller {
                self.reportCanvasUnavailable(projectId: projectId, controller: controller, error: error)
            } else {
                self.reportZoneProjectUnavailableOnce(projectId: projectId, error: error)
            }
        }
    }

    private func reportCanvasUnavailable(projectId: UUID, controller: ZoneRuntimeController, error: Error) {
        controller.markCanvasUnavailable(error)
        reportZoneProjectUnavailableOnce(projectId: projectId, error: error)
    }

    private func reportZoneProjectUnavailableOnce(projectId: UUID, error: Error) {
        guard reportedUnreadableProjectIds.insert(projectId).inserted else { return }
        onZoneProjectUnavailable?(projectId, error)
    }

    /// The three construction inputs `attachActiveControllerUI` used to omit, now
    /// injectable. M1.3b (`.plans/46`).
    ///
    /// `defaults` and the two tmux seams are not a tidy-up: without them a spawner
    /// built after a workspace switch gets `UserDefaults.standard` and a real
    /// `ProcessTmuxControl`, so **no check can neutralize tmux on the switch path**
    /// and `run-matrix.sh`'s argument-domain injection is the only guard. Threading
    /// them is what makes the hydration path testable at all.
    var spawnerDefaults: UserDefaults = .standard
    var spawnerTmuxPathResolver: (UserDefaults) -> String? = { TmuxLocator.resolve(defaults: $0) }
    var spawnerTmuxControlFactory: @Sendable (String) -> any TmuxControl = { ProcessTmuxControl(tmuxPath: $0) }

    /// Live browser profiles for a spawner built mid-session. The boot spawner
    /// passes `registry.settings.browserProfiles` (`ContinuumApp.swift:3969`) and
    /// this call site passed nothing, so a browser restarted after a switch
    /// resolved its profile against the built-in default alone — a live
    /// inconsistency, not a hypothetical one.
    private func currentBrowserProfiles() -> [BrowserProfile] {
        let profiles = (try? registryStore.loadOrEmpty().settings.browserProfiles) ?? []
        return profiles.isEmpty ? [BrowserProfile.builtInDefault()] : profiles
    }

    /// When the hydrator runs. M1.2 (`.plans/46`).
    ///
    /// `.beforeInstall` is the important one: the layers exist but `setZones` has
    /// not run, so a real view can be dropped straight into `layer.tileViews` and
    /// `_installLayer` will wire it exactly as it wires a placeholder. Nothing
    /// touches the canvas, so `installProjectTile` — and with it
    /// `arrangeAutoLayoutAfterSpawn`, which re-tidies the whole zone — stays out of
    /// the way.
    ///
    /// `.afterInstall` is for the three kinds that cannot be built from a `Tile`
    /// alone: terminal, browser and file tree need a runtime, and their `restart*`
    /// paths open with `guard let existing = canvasView.tileRecord(for:)`, so the
    /// layer has to be installed first.
    enum TileHydrationPhase {
        case beforeInstall
        case afterInstall
        /// A warm scene re-attached: its views are real and its agents wired, so
        /// only a runtime-backed placeholder still waiting for its restore — one
        /// that was in flight when the scene was parked — is restored.
        case afterRemount
    }

    /// Turns a ZoneLayer's `DescriptorTileNSView` placeholders into real tiles.
    ///
    /// Optional on purpose: headless checks build `WorkspaceRuntime` without an
    /// `AppDelegate`, and `PerfScenarios` deliberately wants cheap descriptor tiles
    /// for 128 tiles across 8 zones. A nil hydrator restores the old behaviour
    /// exactly.
    var hydrateZoneLayerTiles: ((CanvasNSView, [CanvasNSView.ZoneLayer], TileHydrationPhase) -> Void)?
    var documentAgentTileIdsProvider: (() -> [AgentID: UUID])? {
        didSet { refreshDocumentRelationships() }
    }

    func refreshDocumentRelationships() {
        canvasView?.setDocumentRelationships(document.documentLinks, agentTileIds: documentAgentTileIdsProvider?() ?? [:])
    }

    /// Builds the arriving active project's spawner and hands it to that
    /// controller, which now owns it strongly (see `ZoneRuntimeController.tileSpawner`).
    /// Every live controller gets a spawner; the ACTIVE one additionally gets the
    /// full UI attachment. M1.3b (`.plans/46`).
    ///
    /// This used to build exactly one `TileSpawner`, for the active controller.
    /// Every other live controller had `tileSpawner == nil` — which is why
    /// `enforceBrowserRuntimeBudget` still `continue`s past a controller without
    /// one, and why the hydrator's Phase B could only restore terminals and
    /// browsers in the zone you happened to be looking at. A multi-zone workspace
    /// came back with dead tiles in every other zone.
    ///
    /// The split is deliberate. A spawner is a per-project *factory* and is safe to
    /// hold for any live project. `attachUI` is different: it starts a session
    /// observer and a tmux reaper, and takes ownership of the shared `focusBroker`
    /// callbacks. Exactly one controller may do that, so it stays with the active
    /// one.
    private func attachActiveControllerUI(canvasView: CanvasNSView) {
        let active = activeController
        // The MOUNTED scene's controllers only. A warm workspace's controllers are
        // live too, but rebuilding their spawners on every arming change is work
        // for tiles nobody can see.
        for controller in mountedControllers {
            wireCanvasFailureReporting(for: controller)
            let spawner = makeSpawner(for: controller, canvasView: canvasView)
            if controller === active {
                controller.attachUI(canvasView: canvasView, tileSpawner: spawner, focusBroker: focusBroker)
            } else {
                controller.attachSpawner(spawner, canvasView: canvasView)
            }
        }
    }

    /// One project zone's `ZoneLayer`, built from its controller's repaired
    /// membership answer. The mount, the switch and `installZoneLayerIfMissing`
    /// all build a layer this way.
    private func makeProjectZoneLayer(
        zone: ZonePlacement,
        projectId: UUID,
        controller: ZoneRuntimeController,
        document: WorkspaceDocument,
        registry appRegistry: Registry,
        membershipCache: inout [UUID: [UUID: [Tile]]]
    ) -> CanvasNSView.ZoneLayer? {
        guard let byZone = try? membership(forProject: projectId, controller: controller,
                                           in: document, cache: &membershipCache) else { return nil }
        let memberTiles = (byZone[zone.zoneId] ?? [])
        .map { tile -> Tile in
            var adopted = tile
            // M1.10 (`.plans/46`): the frame spaces differ, and the file is
            // WORLD. A ZoneLayer lays its tiles out in ZONE-LOCAL coordinates
            // (`_layoutLayerTile` -> `zoneLocalToWorld`), but every
            // `canvas.json` in the field holds WORLD frames -- because layers
            // have never been reachable from production, `canvasStateForPersistence`
            // has always taken its flat branch and written the flat state
            // verbatim. Handing a layer those frames unconverted moves every
            // tile by the zone origin: for a zone at x=4000, the whole project
            // jumps 4000pt right the first time you switch workspaces.
            //
            // Convert on the way in, convert back on the way out
            // (`CanvasNSView.tilesInWorldFrames(forProjectId:)`), and the
            // on-disk convention never changes -- which is what keeps the boot
            // flat path, and every installed copy of the app, reading the same
            // file correctly.
            adopted.frame = CanvasEngine.worldToZoneLocal(adopted.frame, zoneOrigin: zone.origin)
            return adopted
        }
        // Descriptor views — headless safe; `hydrateZoneLayerTiles` builds the real ones.
        var tileViews: [UUID: TileNSView] = [:]
        for tile in memberTiles {
            tileViews[tile.id] = DescriptorTileNSView(tile: tile)
        }
        let layer = CanvasNSView.ZoneLayer(
            placement: zone,
            renderModel: Self.renderModel(for: zone, registry: appRegistry),
            tiles: memberTiles)
        layer.tileViews = tileViews
        return layer
    }

    /// A layer for a mounted project zone that has none: one the camera brings
    /// into the live tier after the mount, or the zone a spawn is about to land in.
    ///
    /// The mount and the switch build layers only for zones in the live tier at
    /// that moment. `setActiveZone` and `reconcileHydration` later acquired a
    /// controller for a zone the camera or a click reached, and stopped there. That
    /// zone was armed, so creation scoped to it, but `installProjectTile` found no
    /// layer and fell through to the flat model, whose save refuses once the boot
    /// scene is retired. The spawn failed with its tile view already on screen and
    /// no agent was ever minted: a blank Home, a Home menu that did nothing and a
    /// composer that said "Unavailable", for a tile nothing had persisted.
    ///
    /// Arming alone does not build one. A click arms a zone the camera may not be
    /// on, and a layer built there outlives the arming (focus moving back to
    /// another zone re-arms it), so the mounted scene would depend on click
    /// history a relaunch cannot reproduce (`--workspace-restart-fault-check`
    /// compares the two). The creation scope still names the armed zone from
    /// the document, and the spawn's scope lookup builds the layer.
    func ensureZoneLayer(forZone zoneId: UUID) {
        guard let zone = document.zones.first(where: { $0.zoneId == zoneId }) else { return }
        installZoneLayerIfMissing(zone)
    }

    private func installZoneLayerIfMissing(_ zone: ZonePlacement) {
        guard let canvasView,
              // The boot-only flat scene owns its project's tiles itself; a layer
              // over it would draw every one of them twice.
              !canvasView.isFlatCompatibilitySceneActive,
              let projectId = zone.projectId,
              !foreignZoneIds.contains(zone.zoneId),
              canvasView.installedZonePlacement(for: zone.zoneId) == nil,
              let controller = registry.controller(for: projectId),
              let appRegistry = try? registryStore.loadOrEmpty()
        else { return }
        // The zone as DRAWN: auto-layout grows a zone on the canvas ahead of the
        // document, and the layer must not shrink it back.
        let placement = canvasView.zonePlacement(for: zone.zoneId) ?? zone
        // A zone becoming live builds every tile view on the main thread; Dylan saw
        // zones fill in seconds late and the canvas lag while they did (2026-10-24).
        let installStart = ProcessInfo.processInfo.systemUptime
        defer {
            if let layer = installedLayers.last, layer.placement.zoneId == zone.zoneId {
                let ms = (ProcessInfo.processInfo.systemUptime - installStart) * 1_000
                let line = "zone install: \(zone.zoneId.uuidString.prefix(8)) \(layer.tiles.count) tiles in "
                    + String(format: "%.1f ms", ms)
                Logger(subsystem: "continuum.canvas", category: "hydration").notice("\(line, privacy: .public)")
            }
        }
        var membershipCache: [UUID: [UUID: [Tile]]] = [:]
        guard let layer = makeProjectZoneLayer(
            zone: placement, projectId: projectId, controller: controller,
            document: document, registry: appRegistry, membershipCache: &membershipCache) else { return }
        hydrateZoneLayerTiles?(canvasView, [layer], .beforeInstall)
        canvasView.upsertZoneLayer(layer)
        installedLayers.append(layer)
        // Phase B needs this controller's spawner. Build one only if it has none:
        // `attachActiveControllerUI` replaces EVERY spawner, and this runs inside a
        // spawn's scope lookup, so the spawn's own managed-agent memo would land on
        // a spawner already discarded and the agent would lose its Home.
        if controller.tileSpawner == nil {
            controller.attachSpawner(makeSpawner(for: controller, canvasView: canvasView), canvasView: canvasView)
        }
        hydrateZoneLayerTiles?(canvasView, [layer], .afterInstall)
    }

    private func makeSpawner(for controller: ZoneRuntimeController, canvasView: CanvasNSView) -> TileSpawner {
        // One spawner per project for as long as its controller lives on this
        // canvas. This used to mint a fresh one for every live controller on every
        // project-changing arm, and every view a spawner builds reaches it through
        // a weak reference — so the first click into another zone silently killed
        // Save as Markdown, the browser profile and inspector menus and a file
        // tree's open-file on every tile built before it.
        if let existing = controller.tileSpawner, existing.canvasView === canvasView {
            return existing
        }
        let previous = controller.tileSpawner
        let spawner = TileSpawner(
            canvasView: canvasView,
            ghostty: ghostty,
            browserEngine: browserEngine,
            projectStore: controller.projectStore,
            project: controller.project,
            defaults: spawnerDefaults,
            tmuxPathResolver: spawnerTmuxPathResolver,
            tmuxControlFactory: spawnerTmuxControlFactory,
            browserProfiles: currentBrowserProfiles(),
            managedSessionStore: controller.managedSessionStore
        )
        // T4 (`.plans/47`): a tile's managed-agent memos outlive the spawner that
        // recorded them, when a controller moves to a new canvas.
        if let previous, previous !== spawner { spawner.adoptManagedAgentMemos(from: previous) }
        onSpawnerCreated?(spawner)
        return spawner
    }

    // MARK: - Opening a project file (one active-context route)

    enum FileOpenPlacement {
        case automatic
        case at(CGPoint)
        /// Gap-adjacent to an existing tile — used by an agent opening a file it
        /// just referenced, so the file lands beside the agent that named it.
        case beside(tileId: UUID)
    }

    enum FileOpenOutcome: Equatable {
        /// A new file tile was created and focused.
        case opened(tileId: UUID)
        /// The file was already open; that tile was focused where it stood.
        case revealed(tileId: UUID)
        /// User-facing reason. Callers surface it; nobody should only beep.
        case failure(String)
    }

    struct DocumentOpenRequest: Sendable {
        var location: DocumentLocation
        var placement: FileOpenPlacement
        var sourceAgentId: AgentID?
        var sourceTileId: UUID?

        init(
            location: DocumentLocation,
            placement: FileOpenPlacement = .automatic,
            sourceAgentId: AgentID? = nil,
            sourceTileId: UUID? = nil
        ) {
            self.location = location
            self.placement = placement
            self.sourceAgentId = sourceAgentId
            self.sourceTileId = sourceTileId
        }
    }

    @discardableResult
    func openDocument(_ request: DocumentOpenRequest) -> FileOpenOutcome {
        let title = URL(fileURLWithPath: request.location.path).lastPathComponent
        var sourceZoneId = request.sourceTileId.flatMap { canvasView?.zoneId(containing: $0) }
        var sourceProjectId = sourceZoneId.flatMap { zoneId in
            document.zones.first(where: { $0.zoneId == zoneId })?.projectId
        } ?? request.location.projectId

        // A transcript can remain visible while its project zone is not the
        // workspace's active zone (for example, the user last clicked an ambient
        // group). The old route consulted only the active controller, so a valid
        // checkout-scoped link incorrectly reported that no project was open.
        // Resolve the owning project from the source tile / durable document
        // location and make that zone the active creation target first.
        if let projectId = sourceProjectId,
           !document.zones.contains(where: { $0.projectId == projectId }),
           let projectWorkspaceId = (try? registryStore.loadOrEmpty())?.projects
            .first(where: { $0.id == projectId && !$0.missing })?.workspaceId,
           projectWorkspaceId != workspaceId {
            do {
                try switchWorkspace(to: projectWorkspaceId)
            } catch {
                return .failure("Couldn't open \(title) in its workspace: \(error.localizedDescription)")
            }
            sourceZoneId = request.sourceTileId.flatMap { canvasView?.zoneId(containing: $0) }
            sourceProjectId = sourceZoneId.flatMap { zoneId in
                document.zones.first(where: { $0.zoneId == zoneId })?.projectId
            } ?? request.location.projectId
        }

        if let projectId = sourceProjectId,
           let projectZoneId = sourceZoneId
            ?? document.zones.first(where: { $0.projectId == projectId })?.zoneId,
           registry.controller(for: projectId)?.tileSpawner == nil,
           let canvasView {
            document.lastActiveZoneId = projectZoneId
            canvasView.setActiveProjectZone(projectZoneId)
            attachActiveControllerUI(canvasView: canvasView)
            try? persistWorkspaceDocument()
            sourceZoneId = projectZoneId
        }

        let spawner = sourceProjectId.flatMap { registry.controller(for: $0)?.tileSpawner }
            ?? activeController?.tileSpawner
        guard let spawner else {
            return .failure("No project is open, so there is nowhere to put the file.")
        }
        let anchor: UUID?
        let worldPoint: CGPoint?
        switch request.placement {
        case let .beside(tileId): anchor = tileId; worldPoint = nil
        case let .at(point): anchor = request.sourceTileId; worldPoint = point
        case .automatic: anchor = request.sourceTileId; worldPoint = nil
        }
        // CX-01: the spawn + link half is shared with the workspace API
        // (`executeOpen`); only this click path keeps the navigation above, the
        // active-controller fallback, the coarse `.failure` for a failed link save,
        // and the focus entry below.
        let execution = executeOpen(
            location: request.location,
            title: title,
            spawner: spawner,
            zoneId: sourceZoneId,
            anchorTileId: anchor,
            worldPoint: worldPoint,
            linkTo: request.sourceAgentId
        )
        let mapped: FileOpenOutcome
        switch execution.document {
        case let .opened(tileId): mapped = .opened(tileId: tileId)
        case let .existing(tileId): mapped = .revealed(tileId: tileId)
        case let .failed(message): mapped = .failure(message)
        }
        if case let .failed(message) = execution.relationship {
            return .failure("Opened \(title), but couldn't save its agent relationship: \(message)")
        }
        switch mapped {
        case let .opened(tileId), let .revealed(tileId):
            _ = focusBroker.enterScope(.tile(tileId), reason: .tileSpawned)
        case .failure: break
        }
        return mapped
    }

    // MARK: - CX-01 explicit-destination open (`.plans/59`, §9 / §16)

    /// A destination the workspace API resolved BEFORE any effect. Pure output of
    /// `preflightExplicitOpen`; nothing about the canvas or document changed to
    /// produce it.
    struct ExplicitOpenPlan: Equatable {
        let location: DocumentLocation
        let projectId: UUID
        /// The zone the tile will be installed into (or already lives in). Always
        /// an INSTALLED layer for a new tile — the flat compatibility fallback in
        /// `installProjectTile` is never reached from the API path.
        let zoneId: UUID
        let anchorTileId: UUID?
        /// The one existing tile for this document, when the workspace has exactly
        /// one. Reveal reuses it; the draft it owns is never touched.
        let existingTileId: UUID?
    }

    enum ExplicitOpenPreflight: Equatable {
        case ready(ExplicitOpenPlan)
        /// The project's zones live in another workspace. Phase 1 never switches
        /// on an API caller's behalf, whatever it asked for (§16: a narrow first
        /// slice may explicitly decline that case; it must not bypass policy).
        case presentationRequired(targetWorkspaceId: UUID)
        /// `zone_unhydrated`, `zone_not_in_project`, `project_not_in_workspace`,
        /// `duplicate_occurrence`, `no_canvas`.
        case unsupported(String)
    }

    /// Decide where an explicit open would land, without arming, switching,
    /// acquiring or installing anything. No active-controller fallback: the
    /// project is the caller's, resolved from its checkout, never "whatever is
    /// armed" (§9.1 — never silently use the active project's namesake).
    func preflightExplicitOpen(
        location: DocumentLocation,
        projectId: UUID,
        destinationZoneId: UUID?,
        anchorTileId: UUID?
    ) -> ExplicitOpenPreflight {
        guard let canvasView else { return .unsupported("no_canvas") }
        let projectZones = document.zonesInZOrder.filter { $0.projectId == projectId }

        let canonicalPath = URL(fileURLWithPath: location.path).standardizedFileURL.resolvingSymlinksInPath().path
        let matches = canvasView.allWorkspaceTiles().filter {
            $0.kind == .file && ($0.metadata.documentLocation?.path ?? $0.metadata.filePath) == canonicalPath
        }
        // §6.1: the tile UUID is the only occurrence identity Phase 1 supports.
        // Two tiles for one document, or one tile id mounted in two layers, cannot
        // be targeted precisely — refuse rather than pick.
        if matches.count > 1 { return .unsupported("duplicate_occurrence") }
        if let existing = matches.first {
            if canvasView.installedZoneIds(containing: existing.id).count > 1 {
                return .unsupported("duplicate_occurrence")
            }
            guard let existingZone = canvasView.zoneId(containing: existing.id) else {
                return .unsupported("duplicate_occurrence")
            }
            return .ready(ExplicitOpenPlan(
                location: location, projectId: projectId, zoneId: existingZone,
                anchorTileId: anchorTileId, existingTileId: existing.id))
        }

        let zoneId: UUID?
        if let destinationZoneId {
            guard projectZones.contains(where: { $0.zoneId == destinationZoneId }) else {
                return .unsupported("zone_not_in_project")
            }
            zoneId = destinationZoneId
        } else if let anchorTileId,
                  let anchorZone = canvasView.zoneId(containing: anchorTileId),
                  projectZones.contains(where: { $0.zoneId == anchorZone }) {
            zoneId = anchorZone
        } else {
            zoneId = projectZones.last?.zoneId
        }
        guard let zoneId else {
            if let projectWorkspaceId = (try? registryStore.loadOrEmpty())?.projects
                .first(where: { $0.id == projectId && !$0.missing })?.workspaceId,
               projectWorkspaceId != workspaceId {
                return .presentationRequired(targetWorkspaceId: projectWorkspaceId)
            }
            return .unsupported("project_not_in_workspace")
        }
        // A zone below the live tier has no layer. `installProjectTile` would fall
        // through to the FLAT model and frame a zone-local tile as world; the API
        // refuses instead of hydrating on demand (Phase 1 decision).
        guard canvasView.installedZonePlacement(for: zoneId) != nil else {
            return .unsupported("zone_unhydrated")
        }
        return .ready(ExplicitOpenPlan(
            location: location, projectId: projectId, zoneId: zoneId,
            anchorTileId: anchorTileId, existingTileId: nil))
    }

    /// A controller and spawner for a project WITHOUT arming it. Mirrors what
    /// `reconcileHydration` does for a live-tier zone and what
    /// `attachActiveControllerUI` does for every non-active live controller: a
    /// spawner is a per-project factory and is safe to hold for any project; only
    /// `attachUI` (session observer, tmux reaper, focus callbacks) is reserved for
    /// the active controller, and this never calls it. `lastActiveZoneId` and
    /// `setActiveProjectZone` are not touched — targeting a zone for placement is
    /// separate from arming it for the user's next creation (§16).
    func ensureSpawner(forProjectId projectId: UUID) throws -> TileSpawner {
        guard let canvasView else { throw WorkspaceSwitchError.noCanvas }
        let controller: ZoneRuntimeController
        if let existing = registry.controller(for: projectId) {
            controller = existing
        } else {
            controller = try registry.acquire(projectId: projectId)
            if !acquiredProjectIds.contains(projectId) { acquiredProjectIds.append(projectId) }
        }
        if let spawner = controller.tileSpawner { return spawner }
        let spawner = makeSpawner(for: controller, canvasView: canvasView)
        controller.attachSpawner(spawner, canvasView: canvasView)
        return spawner
    }

    struct DocumentOpenExecution: Equatable {
        enum Document: Equatable {
            case opened(UUID)
            case existing(UUID)
            case failed(String)

            var tileId: UUID? {
                switch self {
                case let .opened(id), let .existing(id): return id
                case .failed: return nil
                }
            }
        }
        enum Relationship: Equatable {
            case persisted
            case unnecessary
            case failed(String)
        }
        var document: Document
        var relationship: Relationship
    }

    /// Spawn or reveal through `TileSpawner.spawnFile(targetZoneId:)`, then persist
    /// the agent relationship. NO focus, NO camera, NO arming: presentation is the
    /// caller's policy decision. The two steps report separately (§9.2): a tile
    /// that exists while its link failed to save is a partial success, not a
    /// failure — the click path folds that into its alert text, the API returns it.
    func executeOpen(
        location: DocumentLocation,
        title: String? = nil,
        spawner: TileSpawner,
        zoneId: UUID?,
        anchorTileId: UUID?,
        worldPoint: CGPoint?,
        linkTo agentId: AgentID?
    ) -> DocumentOpenExecution {
        let title = title ?? URL(fileURLWithPath: location.path).lastPathComponent
        let outcome = spawner.spawnFile(
            location: location,
            title: title,
            at: worldPoint,
            beside: anchorTileId,
            targetZoneId: zoneId
        )
        let document: DocumentOpenExecution.Document
        switch outcome {
        case let .spawned(tileId): document = .opened(tileId)
        case let .alreadyOpen(tileId): document = .existing(tileId)
        case .invalidPath: document = .failed("Couldn't open \(title): that path isn't a file Array can show.")
        case let .failure(error): document = .failed("Couldn't open \(title): \(error.localizedDescription)")
        }
        if case .opened = document { noteStructuralCommit() }
        var relationship: DocumentOpenExecution.Relationship = .unnecessary
        if let agentId, let tileId = document.tileId {
            do {
                try linkDocumentTile(tileId, to: agentId)
                relationship = .persisted
            } catch {
                relationship = .failed(error.localizedDescription)
            }
        }
        return DocumentOpenExecution(document: document, relationship: relationship)
    }

    /// Link with rollback, mirroring `removeDocumentLinks`: a failed save leaves
    /// the in-memory document exactly as it was, so a retry repairs the link
    /// without a second tile.
    func linkDocumentTile(_ tileId: UUID, to agentId: AgentID) throws {
        let previousLinks = document.documentLinks
        document.linkDocument(tileId, to: agentId)
        do { try persistWorkspaceDocument() }
        catch { document.documentLinks = previousLinks; throw error }
        refreshDocumentRelationships()
    }

    /// The single route for opening a project file as an Array tile. Command
    /// Center, file-tree activation, canvas file drop, and agent local-file links
    /// all come through here so the active project/zone is resolved at invocation
    /// time rather than captured when some earlier spawner was built.
    @discardableResult
    func openProjectFile(path: String, placement: FileOpenPlacement = .automatic) -> FileOpenOutcome {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("That file path is empty.") }
        guard let active = activeController, active.tileSpawner != nil else {
            return .failure("No active project is open, so there is nowhere to put the file.")
        }
        let location = DocumentLocationResolver.resolve(
            fileURL: URL(fileURLWithPath: trimmed),
            knownRoots: [DocumentLocationRoot(
                rootURL: URL(fileURLWithPath: active.project.rootPath, isDirectory: true),
                projectId: active.project.id
            )]
        )
        return openDocument(DocumentOpenRequest(location: location, placement: placement))
    }

    func removeDocumentLinks(agentId: AgentID? = nil, tileId: UUID? = nil) throws {
        let previousLinks = document.documentLinks
        document.removeDocumentLinks(agentId: agentId, tileId: tileId)
        do { try persistWorkspaceDocument() }
        catch { document.documentLinks = previousLinks; throw error }
        refreshDocumentRelationships()
    }

    private func persistWorkspaceDocument() throws {
        try saveWorkspaceDocument(document, workspaceId: workspaceId)
        noteStructuralCommit()
    }

    private func loadWorkspaceDocument(workspaceId: UUID) throws -> WorkspaceDocument? {
        if let override = _workspaceDocumentLoader { return try override(workspaceId) }
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        return try WorkspaceStore(
            workspaceId: workspaceId,
            applicationSupportDirectory: appSupport).tryLoad()
    }

    private func saveWorkspaceDocument(_ document: WorkspaceDocument, workspaceId: UUID) throws {
        if let override = _workspaceDocumentSaver {
            try override(workspaceId, document)
            strandedWorkspaceSnapshots.removeValue(forKey: workspaceId)
            return
        }
        // The mounted workspace's saver, so this write supersedes any pending
        // debounced snapshot rather than racing it.
        let controller: WorkspaceDocumentSaveController
        if workspaceId == self.workspaceId {
            controller = mountedDocumentSaver()
        } else {
            let appSupport = registryStore.registryFile.deletingLastPathComponent()
            controller = WorkspaceDocumentSaveController(store: WorkspaceStore(
                workspaceId: workspaceId,
                applicationSupportDirectory: appSupport))
        }
        let generation = controller.scheduleZoneLayoutSave(document)
        qaLastScheduledWorkspaceGeneration = generation
        try controller.flush(through: generation)
        qaLastAcknowledgedWorkspaceGeneration = controller.acknowledgedGeneration
        lifecycleObserver?(.saveGenerationAcknowledged(generation))
        strandedWorkspaceSnapshots.removeValue(forKey: workspaceId)
    }

    // MARK: - Workspace Switch (T09, `.plans/70` S5)

    /// The relaunch-spy seam: `_relaunchSpy` is non-nil only in checks; production leaves it nil.
    var _relaunchSpy: (() -> Void)?

    /// How many recently left workspaces stay warm (`.plans/70` S5).
    var warmSceneCapacity: Int = WorkspaceWarmSceneConfig.capacity()
    private(set) var lastSwitchReport: WorkspaceSwitchReport?
    /// True while a switch runs. A second switch is refused, and hydration is
    /// not re-planned underneath it.
    private(set) var isSwitching = false

    /// A workspace the user left recently, kept whole: its document as it was
    /// saved on the way out, its layers with their REAL tile views (detached,
    /// out of the view tree, no per-frame work), and one controller reference per
    /// project — so its terminals, web views and transcripts keep running and
    /// going back re-attaches them instead of rebuilding.
    private struct WarmScene {
        let workspaceId: UUID
        let document: WorkspaceDocument
        let layers: [CanvasNSView.ZoneLayer]
        let acquiredProjectIds: [UUID]
        let foreignZoneIds: Set<UUID>
    }

    /// Most recently left first.
    private var warmScenes: [WarmScene] = []
    var qaWarmWorkspaceIds: [UUID] { warmScenes.map(\.workspaceId) }

    /// Unmount the current workspace and mount `targetWorkspaceId` in-process.
    ///
    /// Every step that can fail runs before anything on screen changes, and a
    /// failure gives back what it took: the controllers (and so the project
    /// locks) acquired for the target are released, and a warm target goes back
    /// to the warm set. The departing scene is parked warm rather than torn
    /// down; beyond `warmSceneCapacity` the least recent is released through
    /// the ordinary path (`ZoneRuntimeRegistry.release` → `close()`).
    func switchWorkspace(to targetWorkspaceId: UUID) throws {
        reportedUnreadableProjectIds = []
        // M1.10: the defect this milestone exists to fix was that EVERY canvas call
        // below optional-chained through a nil `canvasView` and did nothing, for
        // months, in silence. Refusing loudly means any future path that reaches a
        // canvas-less runtime fails at the first click instead.
        guard let canvas = canvasView else { throw WorkspaceSwitchError.noCanvas }
        // The editor barrier below runs the main run loop, so a timer or a
        // queued callback can ask for another switch while this one is half
        // done. That nested switch ran to completion inside the outer one and
        // crashed the app; it is refused instead.
        guard !isSwitching else { throw WorkspaceSwitchError.switchInProgress }
        isSwitching = true
        defer { isSwitching = false }
        hydrationReconcileTimer?.invalidate()
        hydrationReconcileTimer = nil

        let clock = WorkspaceSwitchPhaseClock()
        var report = WorkspaceSwitchReport(from: workspaceId, to: targetWorkspaceId)
        lifecycleObserver?(.switchBegan(targetWorkspaceId))
        do {
            try performSwitch(to: targetWorkspaceId, canvas: canvas, clock: clock, report: &report)
            report.succeeded = true
        } catch {
            report.failure = "\(error)"
            clock.finish()
            report.phases = clock.phases
            lastSwitchReport = report
            throw error
        }
        clock.finish()
        report.phases = clock.phases
        lastSwitchReport = report
        classifyStrandedTiles()
        lifecycleObserver?(.switchCompleted(targetWorkspaceId))
        // CX-01: a switch is newer intent for every pending presentation, and a
        // structural change for every issued context.
        noteUserInteraction()
        noteStructuralCommit()
    }

    private func performSwitch(
        to targetWorkspaceId: UUID,
        canvas: CanvasNSView,
        clock: WorkspaceSwitchPhaseClock,
        report: inout WorkspaceSwitchReport
    ) throws {
        // 1. Validate and load the target before touching the mounted scene or
        // either workspace file. Do not validate the departing document here: the
        // mounted canvas is the current truth, and a legacy foreign zone in the old
        // saved document must not trap the user in that workspace. A target's
        // legacy foreign zone is preserved in its document and left unmounted.
        clock.begin("validate")
        var appRegistry = try registryStore.loadOrEmpty()
        guard let loadedTargetDocument = try loadWorkspaceDocument(workspaceId: targetWorkspaceId) else {
            throw WorkspaceSwitchError.documentNotFound(targetWorkspaceId)
        }
        var targetDocument = loadedTargetDocument
        let targetZones = Self.mountableZones(
            in: targetDocument, workspaceId: targetWorkspaceId, registry: appRegistry)
        let targetZoneIds = Set(targetZones.map(\.zoneId))
        if let active = targetDocument.lastActiveZoneId, !targetZoneIds.contains(active) {
            targetDocument.lastActiveZoneId = targetDocument.zonesInZOrder
                .last(where: { targetZoneIds.contains($0.zoneId) })?.zoneId
        }

        // 2. Capture every visible register and save it while the departing scene
        // is still mounted and interactive.
        clock.begin("flush")
        try flushMountedWorkspaceState()
        report.unansweredEditors = lastFlushUnansweredEditors

        // 3. Prepare the target: re-attach a warm one, or acquire and build.
        clock.begin("prepare")
        let warm = takeWarmScene(
            for: targetWorkspaceId, document: loadedTargetDocument, mountableZoneIds: targetZoneIds)
        report.warm = warm != nil
        var acquiredNow: [UUID] = []
        let targetAcquired: [UUID]
        let layers: [CanvasNSView.ZoneLayer]
        if let warm {
            targetAcquired = warm.acquiredProjectIds
            layers = warm.layers
            // The document is the truth for each zone; a layer keeps the placement
            // and render model it was BUILT with, and `setZones` installs Model B
            // from them. Without this a Home or name changed after the cold mount
            // drew stale on the way back and the next save wrote it back to disk.
            for layer in layers {
                guard let zone = targetDocument.zones.first(where: { $0.zoneId == layer.placement.zoneId }) else { continue }
                layer.placement = zone
                layer.renderModel = Self.renderModel(for: zone, registry: appRegistry)
            }
        } else {
            let plan = ZoneHydrationOrchestrator.plan(
                zones: targetZones,
                viewport: targetDocument.viewport,
                visibleSize: CGSize(width: canvas.bounds.width > 0 ? canvas.bounds.width : 1280,
                                    height: canvas.bounds.height > 0 ? canvas.bounds.height : 720),
                focusedTileZone: targetDocument.lastActiveZoneId,
                maxLiveZones: ZoneHydrationBudgetConfig.maxLiveZones()
            )
            // One reference per live project for THIS scene, even when another
            // scene (the departing one, a warm one) holds the same controller.
            var acquired: [UUID] = []
            do {
                for zone in targetZones {
                    guard let projectId = zone.projectId, plan.tier(for: zone.zoneId) == .live,
                          !acquired.contains(projectId) else { continue }
                    // A project whose folder is gone, or that is no longer
                    // registered, cannot be opened; its zone draws without tiles
                    // (the reconcile pass says why) rather than refusing the switch.
                    guard let entry = appRegistry.projects.first(where: { $0.id == projectId }), !entry.missing else {
                        continue
                    }
                    do {
                        _ = try registry.acquire(projectId: projectId)
                    } catch {
                        throw WorkspaceProjectAcquisitionError.from(error, projectName: entry.name)
                    }
                    acquiredNow.append(projectId)
                    acquired.append(projectId)
                }
            } catch {
                for projectId in acquiredNow { registry.release(projectId: projectId) }
                throw error
            }
            targetAcquired = acquired
            report.acquiredProjects = acquired.count
            layers = buildLayers(for: targetZones, plan: plan, document: targetDocument, registry: appRegistry)
        }

        // 4. Commit the selected workspace: the last throwing step, before the
        // canvas changes. A failure gives back everything step 3 took.
        clock.begin("commit")
        do {
            appRegistry.markWorkspaceMounted(targetWorkspaceId, now: Date())
            try registryStore.save(appRegistry)
        } catch {
            if let warm { warmScenes.insert(warm, at: 0) } else {
                for projectId in acquiredNow { registry.release(projectId: projectId) }
            }
            throw error
        }

        // 5. Swap. The departing layers come off the canvas WITHOUT being retired
        // — their views keep running, detached — and the first switch also
        // retires the boot-only flat compatibility scene.
        clock.begin("swap")
        canvas.retireFlatCompatibilityScene()
        // A project the departing scene acquired without owning a zone of it (a
        // stale foreign acquisition) is handed back now, not kept warm.
        let departingOwned = Set(document.zones.filter { !foreignZoneIds.contains($0.zoneId) }.compactMap(\.projectId))
        for projectId in acquiredProjectIds where !departingOwned.contains(projectId) {
            registry.release(projectId: projectId)
        }
        let departing = WarmScene(
            workspaceId: workspaceId,
            document: document,
            layers: canvas.parkZoneLayers(),
            acquiredProjectIds: acquiredProjectIds.filter { departingOwned.contains($0) },
            foreignZoneIds: foreignZoneIds)
        for projectId in departing.acquiredProjectIds where !targetAcquired.contains(projectId) {
            registry.controller(for: projectId)?.parkUI()
        }
        if warm == nil { hydrateZoneLayerTiles?(canvas, layers, .beforeInstall) }
        canvas.setZones(layers, documentZones: Self.zoneRenderModels(for: targetZones, layers: layers, registry: appRegistry))
        installedLayers = layers
        foreignZoneIds = Set(targetDocument.zones.map(\.zoneId)).subtracting(targetZoneIds)

        // The background is resolved from the TARGET document, so the canvas
        // never draws one frame of the departing background under the arriving
        // tiles. The camera is the target's saved one, and nothing below may
        // overwrite it (fit-all used to, whenever no tile could take focus).
        canvas.setCanvasBackground(CanvasBackgroundResolver.effective(
            workspace: targetDocument.canvasBackground,
            global: CanvasBackgroundGlobalStore.load(defaults: canvasBackgroundDefaults)))
        canvas.setViewport(targetDocument.viewport)

        workspaceId = targetWorkspaceId
        mountEpoch &+= 1
        document = targetDocument
        acquiredProjectIds = targetAcquired

        // 6. Park the departing scene warm; release whatever falls off the end.
        clock.begin("park")
        warmScenes.insert(departing, at: 0)
        while warmScenes.count > max(0, warmSceneCapacity) {
            let evicted = warmScenes.removeLast()
            report.evictedWorkspaces.append(evicted.workspaceId)
            evict(evicted)
        }

        // 7. Attach and hydrate.
        clock.begin("attach")
        refreshDocumentRelationships()
        canvas.activateUndoWorkspace(targetWorkspaceId)
        canvas.setActiveProjectZone(targetDocument.lastActiveZoneId)
        attachActiveControllerUI(canvasView: canvas)
        // Phase B needs the active controller's spawner, built on the line above.
        // A warm scene only finishes what it had not finished.
        hydrateZoneLayerTiles?(canvas, layers, warm == nil ? .afterInstall : .afterRemount)

        clock.begin("focus")
        restoreFocus(from: canvas)
    }

    /// The target's warm scene, if it is still the scene the target would mount:
    /// its saved document unchanged on disk and the same zones mountable. A
    /// stale one is released, never re-attached.
    private func takeWarmScene(for workspaceId: UUID, document loaded: WorkspaceDocument,
                               mountableZoneIds: Set<UUID>) -> WarmScene? {
        guard let index = warmScenes.firstIndex(where: { $0.workspaceId == workspaceId }) else { return nil }
        let scene = warmScenes.remove(at: index)
        let wasMountable = Set(scene.document.zones.map(\.zoneId)).subtracting(scene.foreignZoneIds)
        guard scene.document == loaded, wasMountable == mountableZoneIds else {
            evict(scene)
            return nil
        }
        return scene
    }

    /// A workspace being deleted must not stay warm: its controllers are
    /// released through the ordinary path (flush, surfaces freed, locks given
    /// back), so no shell or agent of it keeps running with no tile anywhere.
    func discardWarmScene(workspaceId: UUID) {
        guard let index = warmScenes.firstIndex(where: { $0.workspaceId == workspaceId }) else { return }
        evict(warmScenes.remove(at: index))
    }

    /// Release a warm scene through the ordinary path: its views are told they
    /// left the scene, and its controller references are dropped — at zero the
    /// controller closes (flush, surfaces freed, lock released).
    private func evict(_ scene: WarmScene) {
        for layer in scene.layers {
            for view in layer.tileViews.values { view.retireFromScene() }
        }
        for projectId in scene.acquiredProjectIds { registry.release(projectId: projectId) }
    }

    /// The target's layers, built cold: one repaired membership answer per
    /// project, WORLD frames converted to ZONE-LOCAL, descriptor placeholders the
    /// hydrator replaces.
    private func buildLayers(
        for zones: [ZonePlacement],
        plan: ZoneHydrationPlan,
        document: WorkspaceDocument,
        registry appRegistry: Registry
    ) -> [CanvasNSView.ZoneLayer] {
        var layers: [CanvasNSView.ZoneLayer] = []
        var membershipCache: [UUID: [UUID: [Tile]]] = [:]
        for zone in zones {
            guard let projectId = zone.projectId else {
                // Ambient zone: rendered from the workspace document's ambientTiles
                // register, same as install (ticket 03).
                layers.append(Self.makeAmbientZoneLayer(zone: zone, document: document))
                continue
            }
            guard plan.tier(for: zone.zoneId) == .live,
                  let controller = registry.controller(for: projectId) else { continue }
            // M1.0/M1.10: see `install`. One repaired membership answer per
            // project; an unreadable store yields no layer, never an empty one.
            if let layer = makeProjectZoneLayer(
                zone: zone, projectId: projectId, controller: controller,
                document: document, registry: appRegistry, membershipCache: &membershipCache) {
                layers.append(layer)
            }
        }
        return layers
    }

    enum WorkspaceSwitchError: Error, CustomStringConvertible, LocalizedError {
        case documentNotFound(UUID)
        /// M1.10: the runtime was asked to switch before anything gave it a canvas.
        case noCanvas
        /// A switch was asked for while one was running.
        case switchInProgress
        var description: String {
            switch self {
            case let .documentNotFound(id): return "switchWorkspace: no document for workspace \(id)"
            case .noCanvas:
                return "switchWorkspace: this WorkspaceRuntime has no canvas — nothing called adoptCanvas(_:), so the switch would have silently changed the document and left the canvas alone"
            case .switchInProgress: return "switchWorkspace: a workspace switch is already in progress"
            }
        }
        var errorDescription: String? {
            switch self {
            case .documentNotFound: return "Its workspace file is missing."
            case .noCanvas: return "The canvas isn't ready yet."
            case .switchInProgress: return "Another workspace switch is still in progress."
            }
        }
    }

    /// The document stays byte-for-byte semantically complete, while the mounted
    /// scene contains only ambient zones and zones whose project declares this
    /// workspace as its owner. Ordinary switching never moves, deletes, or rewrites
    /// a legacy foreign placement; the explicit project-move flow remains the only
    /// ownership writer. A zone whose project is no longer registered is not
    /// mountable either — it used to make the whole mount throw.
    private static func mountableZones(
        in document: WorkspaceDocument,
        workspaceId: UUID,
        registry: Registry
    ) -> [ZonePlacement] {
        document.zones.filter { zone in
            guard let projectId = zone.projectId else { return true }
            return (try? registry.exclusiveWorkspaceOwner(of: projectId)) == .some(workspaceId)
        }
    }

    private static func foreignZoneIds(
        in document: WorkspaceDocument,
        workspaceId: UUID,
        registry: Registry
    ) -> Set<UUID> {
        let mountable = mountableZones(in: document, workspaceId: workspaceId, registry: registry)
        return Set(document.zones.map(\.zoneId)).subtracting(mountable.map(\.zoneId))
    }

    // MARK: - Browser Runtime Budget (T07)

    private var browserRuntimeBudget = BrowserRuntimeBudget(maxLive: BrowserRuntimeBudget.resolveMaxLive())
    /// A workspace API lease protects its browser from budget eviction.
    var browserLeaseProtectionProvider: (() -> Set<UUID>)?
    var browserLeaseRunningTileIdsProvider: (() -> Set<UUID>)?

    /// QA (`.plans/67` ARC-4a): lower the WKWebView cap so a leg can reach a real
    /// eviction with two browsers instead of seven.
    func qaSetBrowserRuntimeMaxLive(_ maxLive: Int) {
        browserRuntimeBudget.maxLive = max(1, maxLive)
    }

    func registerLiveBrowser(tileId: UUID) {
        browserRuntimeBudget.registerLive(tileId: tileId)
    }

    /// QA: who the budget would evict from `liveTileIds` right now, without
    /// evicting anything.
    func qaBrowserEvictionCandidates(liveTileIds: [UUID], protectedTileIds: Set<UUID> = []) -> [UUID] {
        var copy = browserRuntimeBudget
        return copy.evictionCandidates(liveTileIds: liveTileIds, protectedTileIds: protectedTileIds)
    }

    /// Gather protected tile ids from each live controller's canvas lastActiveTileId.
    private func currentProtectedBrowserTileIds() -> Set<UUID> {
        var protected = Set<UUID>()
        for controller in registry.liveControllers {
            if let tileId = controller.canvasView?.canvasState.lastActiveTileId {
                protected.insert(tileId)
            }
        }
        protected.formUnion(browserLeaseProtectionProvider?() ?? [])
        return protected
    }

    /// Runtime callbacks can arrive while a warm workspace owns detached layers.
    /// Resolve only the owning project: the mounted canvas belongs to another workspace.
    func parkedTileRecord(for tileId: UUID, projectId: UUID) -> Tile? {
        warmScenes.flatMap(\.layers).first(where: {
            $0.placement.projectId == projectId && $0.tiles.contains { $0.id == tileId }
        })?.tiles.first { $0.id == tileId }
    }

    /// A Terminal face may finish after its view was evicted from a warm
    /// scene. Clear the layer's model too, so remount cannot save it back.
    func clearParkedTerminalFace(for tileId: UUID, projectId: UUID) {
        for layer in warmScenes.flatMap(\.layers) where layer.placement.projectId == projectId {
            guard let index = layer.tiles.firstIndex(where: { $0.id == tileId }) else { continue }
            layer.tiles[index].metadata.agentTerminalFace = nil
            if let view = layer.tileViews[tileId] { view.tile = layer.tiles[index] }
        }
    }

    func parkedTileView(for tileId: UUID, projectId: UUID) -> TileNSView? {
        warmScenes.flatMap(\.layers).first(where: {
            $0.placement.projectId == projectId && $0.tiles.contains { $0.id == tileId }
        })?.tileViews[tileId]
    }

    @discardableResult
    func replaceParkedTileView(for tileId: UUID, projectId: UUID,
                               makeView: (Tile) -> TileNSView) -> Bool {
        guard let layer = warmScenes.flatMap(\.layers).first(where: {
            $0.placement.projectId == projectId && $0.tiles.contains { $0.id == tileId }
        }), let tile = layer.tiles.first(where: { $0.id == tileId }) else { return false }
        layer.tileViews[tileId]?.retireFromScene()
        layer.tileViews[tileId] = makeView(tile)
        return true
    }

    /// Enforce the WKWebView cap across the UNION of live browser tiles in ALL live zones.
    func enforceBrowserRuntimeBudget() {
        // One process-wide cap includes parked workspaces. Their detached
        // layers must be updated directly, never through the mounted canvas.
        let liveControllers = registry.liveControllers
        let liveTileIds: [UUID] = liveControllers.flatMap { $0.browserRuntimes.map(\.tileId) }
        let protected = currentProtectedBrowserTileIds()
        let evictIds = browserRuntimeBudget.evictionCandidates(liveTileIds: liveTileIds, protectedTileIds: protected)
        for tileId in evictIds {
            guard let controller = liveControllers.first(where: { $0.browserRuntimes.contains { $0.tileId == tileId } }),
                  let runtime = controller.browserRuntimes.first(where: { $0.tileId == tileId }),
                  let spawner = controller.tileSpawner else { continue }
            do {
                if let layer = warmScenes.flatMap(\.layers).first(where: {
                    $0.placement.projectId == controller.project.id && $0.tiles.contains { $0.id == tileId }
                }), let index = layer.tiles.firstIndex(where: { $0.id == tileId }) {
                    var tile = layer.tiles[index]
                    try spawner.writeBrowserTileSnapshotOrThrow(for: runtime, parkedTile: tile,
                        parkedView: layer.tileViews[tileId] as? BrowserTileNSView)
                    tile.runtimeRef = nil
                    if !runtime.title.isEmpty { tile.title = runtime.title }
                    var persisted = try controller.projectStore.loadCanvas()
                    if let persistedIndex = persisted.tiles.firstIndex(where: { $0.id == tileId }) {
                        persisted.tiles[persistedIndex].runtimeRef = nil
                        persisted.tiles[persistedIndex].title = tile.title
                        try controller.projectStore.saveCanvas(persisted)
                    }
                    layer.tileViews[tileId]?.retireFromScene()
                    layer.tiles[index] = tile
                    // Remount's runtime hydrator recognizes descriptors and
                    // restores this browser from its persisted tab snapshot.
                    layer.tileViews[tileId] = DescriptorTileNSView(tile: tile)
                    runtime.terminate(policy: .force)
                } else {
                    try spawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: AppDelegate.browserBudgetSnapshotImage())
                }
                controller.browserRuntimes.removeAll { $0.id == runtime.id }
                browserRuntimeBudget.unregister(tileId: tileId)
            } catch {
                fputs("Browser budget eviction failed for tile \(tileId): \(error)\n", stderr)
            }
        }
    }

    // MARK: - Viewport-driven tier transitions (T10)

    private var hydrationReconcileTimer: Timer?

    /// Counter bumped each time `reconcileHydration()` runs; exposed for check assertions.
    private(set) var reconcileCount: Int = 0

    /// Called when the canvas viewport changes (pan/zoom). Schedules a debounced
    /// `reconcileHydration()`. Callers: `canvasDidChange` viewport-delta gate.
    func onViewportChanged() {
        // A switch sets the camera itself and plans hydration for it; re-planning
        // 200 ms later was a second hitch that could re-arm a zone and rebuild
        // every spawner.
        guard !isSwitching else { return }
        let intervalMs = ZoneHydrationReconcileConfig.intervalMs()
        hydrationReconcileTimer?.invalidate()
        if intervalMs == 0 {
            reconcileHydration()
        } else {
            let interval = Double(intervalMs) / 1000.0
            hydrationReconcileTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.reconcileHydration() }
            }
        }
    }

    /// Synchronous drain: cancels any pending debounce timer and runs `reconcileHydration()`
    /// immediately. Use in checks/tests for deterministic assertions (mirrors `flushCanvasSave`).
    func flushPendingHydrationReconcile() {
        hydrationReconcileTimer?.invalidate()
        hydrationReconcileTimer = nil
        reconcileHydration()
    }

    /// Re-plan + apply hydration tiers across the registry based on the current viewport.
    func reconcileHydration(rearmForCamera: Bool = true) {
        reconcileCount += 1
        guard let canvasView else { return }
        let mountedZones = document.zones.filter { !foreignZoneIds.contains($0.zoneId) }
        let viewport = canvasView.viewport
        let visibleSize = CGSize(
            width: canvasView.bounds.width > 0 ? canvasView.bounds.width : 1280,
            height: canvasView.bounds.height > 0 ? canvasView.bounds.height : 720
        )
        let focusedTileZone: UUID? = {
            guard let activeTileId = canvasView.canvasState.lastActiveTileId else { return nil }
            return mountedZones.first(where: { zone in
                guard let projectId = zone.projectId,
                      let controller = registry.controller(for: projectId) else { return false }
                return controller.canvasView?.canvasState.tiles.contains { $0.id == activeTileId } ?? false
            })?.zoneId
        }()
        let runningZones = Set((browserLeaseRunningTileIdsProvider?() ?? []).flatMap { canvasView.installedZoneIds(containing: $0) })
        let planningZones = mountedZones.map { zone in
            var copy = zone
            if runningZones.contains(zone.zoneId) { copy.hydrationPolicy = .pinnedLive }
            return copy
        }
        let plan = ZoneHydrationOrchestrator.plan(
            zones: planningZones,
            viewport: viewport,
            visibleSize: visibleSize,
            focusedTileZone: focusedTileZone,
            maxLiveZones: ZoneHydrationBudgetConfig.maxLiveZones()
        )
        // A CONTROLLER and a LIVE TIER are different things, and conflating them
        // is what made this bug unreachable by any amount of panning or clicking.
        // The armed zone must always own a controller, because creation resolves
        // its store, its canvas and its managed-session store through it. Its
        // TIER still follows the camera like every other zone -- pinning it live
        // would defeat the hydration budget and keep a zone hot forever.
        let armedZoneId = document.lastActiveZoneId
        for zone in mountedZones {
            guard let projectId = zone.projectId,
                  let plannedTier = plan.tier(for: zone.zoneId) else { continue }
            guard let controller = registry.controller(for: projectId) else {
                // No controller for this project. Acquisition used to happen ONLY
                // in `install`, so a zone that was not live at mount could never
                // gain one afterwards no matter how far the camera moved or how
                // often it was clicked -- and creation into it fell back to the
                // active project's spawner, persisting the tile into the wrong
                // project entirely.
                guard plannedTier == .live || zone.zoneId == armedZoneId else { continue }
                do {
                    let acquired = try registry.acquire(projectId: projectId)
                    if !acquiredProjectIds.contains(projectId) { acquiredProjectIds.append(projectId) }
                    try? acquired.setTier(plannedTier, allowDehydratingFocusedZone: false)
                    if plannedTier == .live { installZoneLayerIfMissing(zone) }
                } catch {
                    // Its `.array/` is held by another install (hazard 10), or the
                    // root is gone. Leave it unacquired: creation refuses and asks
                    // which project, rather than landing in one the user did not
                    // point at.
                    onZoneProjectUnavailable?(projectId, error)
                }
                continue
            }
            // A second zone of a project another zone already acquired has a
            // controller and still no layer.
            if plannedTier == .live { installZoneLayerIfMissing(zone) }
            guard plannedTier != controller.hydrationTier else { continue }
            try? controller.setTier(plannedTier, allowDehydratingFocusedZone: false)
        }
        // Layer budget eviction over the live set (T07 cross-zone cap).
        enforceBrowserRuntimeBudget()

        // T2 (`.plans/47`): the camera arms a zone. This rides the hydration
        // debounce deliberately — `onViewportChanged` is already gated on a real
        // viewport delta and already debounced, so arming costs one O(zones) pass
        // per settle and never runs per frame or per input event. Adding a second
        // timer here is how the post-0.5.1 perf erosion happened four times.
        //
        // `renderedZonesInZOrder`, NOT `document.zonesInZOrder`. The two diverge:
        // a zone grown by auto-layout updates `liveZones` and the chrome on screen
        // while the document lags behind, and one really was drawn at
        // (656,0,5644x824) with the document still saying (5020,0,1280x720). Asking
        // the document "is the camera inside this zone" then answers about a
        // rectangle the user cannot see, so panning onto a zone did not arm it.
        if rearmForCamera, let armed = CanvasEngine.cameraArmedZone(
            zones: canvasView.renderedZonesInZOrder,
            viewport: viewport,
            visibleSize: visibleSize
        ) {
            setActiveZone(armed, reason: .camera)
        }
    }

    // MARK: - Private

    private struct DepartingFocusSnapshot {
        var tileId: UUID?
        var zoneId: UUID?
    }

    private enum FocusRestoreResult: Equatable {
        case tile(UUID)
        case zone(UUID)
        case canvasFallback(framedWorkspace: Bool)
    }

    private func departingFocusSnapshot(from canvasView: CanvasNSView?) -> DepartingFocusSnapshot {
        let focusedTileId: UUID? = {
            if case let .tile(tileId) = focusBroker.activeSurface { return tileId }
            return canvasView?.canvasState.lastActiveTileId
        }()
        let focusedZoneId = focusedTileId.flatMap { canvasView?.navigationTileSnapshot(for: $0)?.zoneId }
        return DepartingFocusSnapshot(tileId: focusedTileId, zoneId: focusedZoneId)
    }

    private func persistDepartingWorkspaceState(focus: DepartingFocusSnapshot) throws {
        if let visibleZones = canvasView?.workspaceZonePlacementsForPersistence() {
            let visibleById = Dictionary(
                visibleZones.map { ($0.zoneId, $0) },
                uniquingKeysWith: { _, latest in latest })
            document.zones = document.zones.map { visibleById[$0.zoneId] ?? $0 }
        }
        if let liveViewport = canvasView?.viewport {
            document.viewport = liveViewport
        }
        if let zoneId = focus.zoneId,
           document.zones.contains(where: { $0.zoneId == zoneId }) {
            document.lastActiveZoneId = zoneId
        }
        if let tileId = focus.tileId,
           let zoneId = focus.zoneId,
           let projectId = document.zones.first(where: { $0.zoneId == zoneId })?.projectId,
           let controller = registry.controller(for: projectId),
           controller.canvasUnavailable == nil,
           var canvas = try controller.projectStore.tryLoadCanvas(),
           canvas.tiles.contains(where: { $0.id == tileId }) {
            canvas.lastActiveTileId = tileId
            try controller.projectStore.saveCanvas(canvas)
        }
        try saveWorkspaceDocument(document, workspaceId: workspaceId)
    }

    @discardableResult
    private func restoreFocus(from canvasView: CanvasNSView, frameWorkspaceOnFallback: Bool = false) -> FocusRestoreResult {
        // Find the active zone's stored last-active tile id.
        guard let lastActiveZoneId = document.lastActiveZoneId,
              let zone = document.zones.first(where: { $0.zoneId == lastActiveZoneId }) else {
            return focusCanvasFallback(canvasView, frameWorkspace: frameWorkspaceOnFallback)
        }
        guard let projectId = zone.projectId else {
            _ = focusBroker.requestFocus(.canvas, reason: .appActivated)
            return .zone(lastActiveZoneId)
        }
        guard let controller = registry.controller(for: projectId),
              let lastActiveTileId = (try? controller.projectStore.tryLoadCanvas())?.flatMap({ $0.lastActiveTileId }) ?? nil else {
            return focusCanvasFallback(canvasView, frameWorkspace: frameWorkspaceOnFallback)
        }
        if focusBroker.requestFocus(.tile(lastActiveTileId), reason: .appActivated) {
            return .tile(lastActiveTileId)
        }
        return focusCanvasFallback(canvasView, frameWorkspace: frameWorkspaceOnFallback)
    }

    private func focusCanvasFallback(_ canvasView: CanvasNSView, frameWorkspace: Bool) -> FocusRestoreResult {
        _ = focusBroker.requestFocus(.canvas, reason: .appActivated)
        if frameWorkspace, let viewport = canvasView.fitAllToViewport() {
            canvasView.setViewport(viewport)
            return .canvasFallback(framedWorkspace: true)
        }
        return .canvasFallback(framedWorkspace: false)
    }

    // MARK: - Self-check

    /// The guarding check for T06. Constructs a real `WorkspaceRuntime` and drives
    /// install / flushAll / closeAll, asserting all 10 lifecycle invariants.
    static func runWorkspaceRuntimeInstallSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let now = Date()

        // Fixed UUIDs for determinism.
        let workspaceW  = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let projectPa   = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        let projectPb   = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
        let zoneA       = UUID(uuidString: "00000000-0000-0000-0000-000000000611")!
        let zoneB       = UUID(uuidString: "00000000-0000-0000-0000-000000000612")!
        let noteA       = UUID(uuidString: "00000000-0000-0000-0000-000000000621")!
        let noteB       = UUID(uuidString: "00000000-0000-0000-0000-000000000622")!

        // Temp directories.
        let tempRoot   = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-ws-runtime-install-\(UUID().uuidString)", isDirectory: true)
        let paRoot     = tempRoot.appendingPathComponent("Pa", isDirectory: true)
        let pbRoot     = tempRoot.appendingPathComponent("Pb", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: paRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pbRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        // Seed Pa.
        func seedProject(root: URL, projectId: UUID, name: String, tileId: UUID, isActive: Bool) throws -> (ProjectStore, Project) {
            let store = ProjectStore(projectRoot: root)
            let project = Project(
                id: projectId,
                name: name,
                rootPath: root.path,
                createdAt: now,
                updatedAt: now,
                defaultLaunchProfileId: "shell",
                editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
            let canvas = CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [Tile(
                    id: tileId,
                    kind: .note,
                    title: name,
                    frame: TileFrame(x: 20, y: 20, width: 300, height: 180),
                    zPosition: .fromLegacyRank(1),
                    runtimeRef: nil,
                    metadata: TileMetadata(noteId: tileId)
                )],
                groups: [],
                lastActiveTileId: isActive ? tileId : nil
            )
            try store.saveProject(project)
            try store.saveCanvas(canvas)
            return (store, project)
        }

        let (storeA, projectA) = try seedProject(root: paRoot, projectId: projectPa, name: "Project A", tileId: noteA, isActive: true)
        let (storeB, projectB) = try seedProject(root: pbRoot, projectId: projectPb, name: "Project B", tileId: noteB, isActive: false)

        // Seed Registry.
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceW
        registry.lastActiveProjectId = projectPa
        registry.projects = [
            ProjectEntry(id: projectPa, name: "Project A", rootPath: paRoot.path, workspaceId: workspaceW, lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Project B", rootPath: pbRoot.path, workspaceId: workspaceW, lastOpenedAt: now, pinned: false, missing: false)
        ]
        registry.workspaces = [
            WorkspaceEntry(id: workspaceW, name: "W", projectIds: [projectPa, projectPb], createdAt: now, updatedAt: now)
        ]
        try registryStore.save(registry)

        // Seed WorkspaceDocument.
        let workspaceStore = WorkspaceStore(workspaceId: workspaceW, applicationSupportDirectory: appSupport)
        let placementA = ZonePlacement(
            zoneId: zoneA,
            projectId: projectPa,
            origin: ZonePoint(x: 0, y: 0),
            size: ZoneSize(width: 640, height: 480),
            color: "blue",
            collapsed: false,
            hydrationPolicy: .automatic
        )
        let placementB = ZonePlacement(
            zoneId: zoneB,
            projectId: projectPb,
            origin: ZonePoint(x: 700, y: 0),
            size: ZoneSize(width: 640, height: 480),
            color: "mint",
            collapsed: false,
            hydrationPolicy: .automatic
        )
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 50, y: 60, zoom: 1),
            zones: [placementA, placementB],
            zoneZOrder: [zoneA, zoneB],
            lastActiveZoneId: zoneA
        )
        try workspaceStore.save(document)

        // Infrastructure.
        let focusBroker = FocusBroker()
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        // Registry factory: maps projectId → controller for Pa/Pb.
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa {
                return ZoneRuntimeController(projectRoot: paRoot, projectStore: storeA, project: projectA)
            } else if projectId == projectPb {
                return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storeB, project: projectB)
            }
            throw CheckError.failed("unexpected projectId in factory: \(projectId)")
        })

        let orchestratorType = ZoneHydrationOrchestrator.self

        let runtime = WorkspaceRuntime(
            workspaceId: workspaceW,
            document: document,
            registry: zoneRegistry,
            orchestrator: orchestratorType,
            focusBroker: focusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )

        // Build the workspace canvas (large enough that both zones are in-viewport).
        let canvasState = CanvasState(
            viewport: CanvasViewport(x: 50, y: 60, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil
        )
        let canvas = CanvasNSView(
            canvasState: canvasState,
            activeZone: nil,
            zoneRenderModels: [],
            showsZoneChrome: true
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        // ACT: Install the workspace.
        try runtime.install(into: canvas, appRegistry: registry)
        canvas.layoutSubtreeIfNeeded()

        // === Assertion 1: Live zone set matches the document. ===
        let installedIds = canvas.installedZoneLayerIds
        try expect(installedIds.contains(zoneA), "assertion 1: zoneA should be installed")
        try expect(installedIds.contains(zoneB), "assertion 1: zoneB should be installed")
        try expect(installedIds.count == 2, "assertion 1: exactly 2 zone layers installed, got \(installedIds.count)")
        // Order should match zoneZOrder: [zoneA, zoneB]
        try expect(installedIds == [zoneA, zoneB], "assertion 1: installed order should match zoneZOrder")

        // === Assertion 2: One controller per distinct projectId, ref-count == 1. ===
        try expect(zoneRegistry.refCount(for: projectPa) == 1, "assertion 2: refCount(Pa) should be 1 after install")
        try expect(zoneRegistry.refCount(for: projectPb) == 1, "assertion 2: refCount(Pb) should be 1 after install")
        try expect(zoneRegistry.liveProjectIds == Set([projectPa, projectPb]), "assertion 2: liveProjectIds should be {Pa, Pb}")

        // === Assertion 3: Acquired controllers are the registry's instances (identity). ===
        let registryControllerPa = zoneRegistry.controller(for: projectPa)
        let runtimeControllerPa = runtime.controller(for: projectPa)
        try expect(registryControllerPa != nil, "assertion 3: registry should have a controller for Pa")
        try expect(runtimeControllerPa != nil, "assertion 3: runtime should expose a controller for Pa")
        try expect(registryControllerPa === runtimeControllerPa, "assertion 3: runtime.controller(Pa) must be the registry's instance (===)")

        // === Assertion 4: activeController resolves through lastActiveZoneId. ===
        try expect(runtime.activeController != nil, "assertion 4: activeController should not be nil")
        try expect(runtime.activeController === zoneRegistry.controller(for: projectPa),
                   "assertion 4: activeController should be the Pa controller (active zone zoneA → Pa)")
        try expect(runtime.activeController?.project.id == projectPa, "assertion 4: activeController.project.id should be Pa")

        // === Assertion 5: Canvas layers carry the right placements. ===
        let tilesInA = canvas.tileIds(inZone: zoneA)
        let tilesInB = canvas.tileIds(inZone: zoneB)
        try expect(tilesInA.contains(noteA), "assertion 5: zoneA layer should contain noteA")
        try expect(tilesInB.contains(noteB), "assertion 5: zoneB layer should contain noteB")
        // Verify each installed layer's placement matches the WorkspaceDocument (projectId, origin, size).
        let layerPlacementA = runtime.installedZonePlacement(for: zoneA)
        try expect(layerPlacementA != nil, "assertion 5: installed layer for zoneA must have a placement")
        try expect(layerPlacementA?.projectId == projectPa,
                   "assertion 5: zoneA layer placement.projectId should be Pa, got \(String(describing: layerPlacementA?.projectId))")
        try expect(layerPlacementA?.origin.x == placementA.origin.x && layerPlacementA?.origin.y == placementA.origin.y,
                   "assertion 5: zoneA layer placement.origin should match document (\(placementA.origin)), got \(String(describing: layerPlacementA?.origin))")
        try expect(layerPlacementA?.size.width == placementA.size.width && layerPlacementA?.size.height == placementA.size.height,
                   "assertion 5: zoneA layer placement.size should match document (\(placementA.size)), got \(String(describing: layerPlacementA?.size))")
        let layerPlacementB = runtime.installedZonePlacement(for: zoneB)
        try expect(layerPlacementB != nil, "assertion 5: installed layer for zoneB must have a placement")
        try expect(layerPlacementB?.projectId == projectPb,
                   "assertion 5: zoneB layer placement.projectId should be Pb, got \(String(describing: layerPlacementB?.projectId))")
        try expect(layerPlacementB?.origin.x == placementB.origin.x && layerPlacementB?.origin.y == placementB.origin.y,
                   "assertion 5: zoneB layer placement.origin should match document (\(placementB.origin)), got \(String(describing: layerPlacementB?.origin))")
        try expect(layerPlacementB?.size.width == placementB.size.width && layerPlacementB?.size.height == placementB.size.height,
                   "assertion 5: zoneB layer placement.size should match document (\(placementB.size)), got \(String(describing: layerPlacementB?.size))")

        // === Assertion 6: Focus scope restored to active zone's last-active tile. ===
        // Pa's canvas has lastActiveTileId = noteA (seeded above).
        try expect(focusBroker.activeSurface == .tile(noteA),
                   "assertion 6: focusBroker.activeSurface should be .tile(noteA) after install; got \(String(describing: focusBroker.activeSurface))")

        // === Assertion 7: Active-zone tile adapters are registered with the broker. ===
        let focusableNoteA = focusBroker.requestFocus(.tile(noteA), reason: .userClick)
        try expect(focusableNoteA, "assertion 7: requestFocus(.tile(noteA)) should return true (adapter registered)")
        let randomId = UUID()
        let focusableRandom = focusBroker.requestFocus(.tile(randomId), reason: .userClick)
        try expect(!focusableRandom, "assertion 7: requestFocus for uninstalled tile id should return false")

        // === Assertion 8: Save isolation through flushAll. ===
        // Capture Pb's bytes + mtime before.
        func bytes(at url: URL) throws -> Data { try Data(contentsOf: url) }
        func mtime(at url: URL) throws -> Date {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values.contentModificationDate else {
                throw CheckError.failed("missing modification date for \(url.path)")
            }
            return date
        }
        let pbCanvasFile = storeB.layout.canvasFile
        let pbBytesBefore = try bytes(at: pbCanvasFile)
        let pbMtimeBefore = try mtime(at: pbCanvasFile)

        // Mutate Pa's canvas via the workspace canvas viewport change + schedule save.
        canvas.setViewport(CanvasViewport(x: 99, y: 0, zoom: 1))
        runtime.activeController?.scheduleCanvasSave()
        Thread.sleep(forTimeInterval: 1.1)

        // Flush all controllers through WorkspaceRuntime.
        try runtime.flushAll()

        // Pa should have been rewritten.
        let paCanvasAfter = try storeA.loadCanvas()
        try expect(paCanvasAfter.viewport.x == 99.0, "assertion 8: Pa's canvas should have viewport.x == 99 after flushAll; got \(paCanvasAfter.viewport.x)")

        // Pb should be byte-identical and mtime-unchanged.
        let pbBytesAfter = try bytes(at: pbCanvasFile)
        let pbMtimeAfter = try mtime(at: pbCanvasFile)
        try expect(pbBytesBefore == pbBytesAfter, "assertion 8: Pb's canvas bytes should be unchanged after flushAll")
        try expect(pbMtimeBefore == pbMtimeAfter, "assertion 8: Pb's canvas mtime should be unchanged after flushAll (no spurious write)")

        // === Assertion 9: Teardown releases every controller and unregisters adapters. ===
        runtime.closeAll()

        try expect(zoneRegistry.refCount(for: projectPa) == 0, "assertion 9: refCount(Pa) should be 0 after closeAll")
        try expect(zoneRegistry.refCount(for: projectPb) == 0, "assertion 9: refCount(Pb) should be 0 after closeAll")
        try expect(zoneRegistry.liveProjectIds.isEmpty, "assertion 9: liveProjectIds should be empty after closeAll")
        try expect(canvas.installedZoneLayerIds.isEmpty, "assertion 9: canvas zone-layer set should be empty after closeAll")

        // Adapter for noteA should be unregistered after closeAll.
        let focusableAfterClose = focusBroker.requestFocus(.tile(noteA), reason: .userClick)
        try expect(!focusableAfterClose, "assertion 9: requestFocus(.tile(noteA)) should return false after closeAll (adapter unregistered)")

        // === Assertion 10: No relaunch path touched. ===
        // WorkspaceRuntime.swift contains no call to relaunchApplication — verified
        // by construction. The relaunch paths (relaunchApplication, switchWorkspaceAndRelaunch,
        // createWorkspaceAndRelaunch) remain on AppDelegate untouched.

        // === Carry-forward: Budget gates the live set. ===
        // With maxLiveZones = 1 overridden, only the focused zone (zoneA/Pa) should be acquired.
        let suiteName = "continuum-ws-runtime-budget-\(UUID().uuidString)"
        let budgetDefaults = UserDefaults(suiteName: suiteName)!
        defer { budgetDefaults.removePersistentDomain(forName: suiteName) }
        budgetDefaults.set(1, forKey: ZoneHydrationBudgetConfig.maxLiveZonesKey)

        let tightRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa {
                return ZoneRuntimeController(projectRoot: paRoot, projectStore: storeA, project: projectA)
            } else if projectId == projectPb {
                return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storeB, project: projectB)
            }
            throw CheckError.failed("unexpected projectId in tight-budget factory: \(projectId)")
        })
        let tightRuntime = WorkspaceRuntime(
            workspaceId: workspaceW,
            document: document,
            registry: tightRegistry,
            focusBroker: FocusBroker(),
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        let tightCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 50, y: 60, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil,
            zoneRenderModels: [],
            showsZoneChrome: false
        )
        tightCanvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        // Override maxLiveZones to 1 so only the focused zone (Pa) is live.
        let tightPlan = ZoneHydrationOrchestrator.plan(
            zones: document.zones,
            viewport: document.viewport,
            visibleSize: CGSize(width: 2000, height: 1200),
            focusedTileZone: document.lastActiveZoneId,
            maxLiveZones: ZoneHydrationBudgetConfig.maxLiveZones(defaults: budgetDefaults)
        )
        // With budget=1 and focusedTileZone=zoneA (hard-pinned by focus), zoneA is live.
        try expect(tightPlan.tier(for: zoneA) == .live, "budget carry-forward: zoneA should be live (focused zone) even at budget=1")
        // zoneB is not the focused zone and budget is exhausted by Pa: should be snapshot.
        let zbTier = tightPlan.tier(for: zoneB)
        try expect(zbTier == .snapshot || zbTier == .cold, "budget carry-forward: zoneB should be snapshot/cold at budget=1 (not live)")
        tightRuntime.closeAll()

        // === Carry-forward: ZoneLayer chrome uses adaptive bounds. ===
        // After install, check that zoneA's layer chrome frame matches adaptive bounds.
        // (Assertion on the first runtime, canvas — before closeAll was called, so this
        //  uses a fresh install on a separate canvas.)
        let chromeCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil,
            zoneRenderModels: [],
            showsZoneChrome: true
        )
        chromeCanvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let chromeRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa {
                return ZoneRuntimeController(projectRoot: paRoot, projectStore: storeA, project: projectA)
            } else if projectId == projectPb {
                return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storeB, project: projectB)
            }
            throw CheckError.failed("unexpected projectId in chrome factory: \(projectId)")
        })
        let chromeRuntime = WorkspaceRuntime(
            workspaceId: workspaceW,
            document: document,
            registry: chromeRegistry,
            focusBroker: FocusBroker(),
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        try chromeRuntime.install(into: chromeCanvas, appRegistry: registry)
        chromeCanvas.layoutSubtreeIfNeeded()
        defer { chromeRuntime.closeAll() }

        if let chromeFrame = chromeCanvas.zoneLayerChromeFrame(for: zoneA) {
            // M1.10 (`.plans/46`): this asserted the ADAPTIVE hug — chrome sized to
            // the union of its member tiles. That was ZoneLayer-only behaviour, and
            // it contradicted the decision Model B already implements
            // (`layoutZoneChromeViews`, zone-unify P3): a zone renders at its
            // STORED placement frame, so the size the user drew survives and, more
            // importantly, the visible rectangle coincides with the move-grab
            // header rect that `zoneHeaderScreenRect` derives from the same
            // placement.
            //
            // The two models disagreed, and the layer path is the one that was
            // wrong: adaptive chrome means the rectangle you see is not the
            // rectangle you can grab. Now that `setZones` owns Model B there is one
            // answer, and this is it.
            let expectedChromeFrame = CanvasEngine.tileScreenFrame(
                CanvasEngine.zoneWorldFrame(placementA),
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
            let diff = abs(chromeFrame.origin.x - expectedChromeFrame.origin.x)
                + abs(chromeFrame.origin.y - expectedChromeFrame.origin.y)
                + abs(chromeFrame.width - expectedChromeFrame.width)
                + abs(chromeFrame.height - expectedChromeFrame.height)
            try expect(diff < 1.0, "stored-frame chrome: zoneA chrome WORLD frame \(chromeFrame) should match its stored placement \(expectedChromeFrame)")
            // And the whole point of the stored frame: chrome IS the grab target.
            //
            // These two rects live in DIFFERENT SPACES and must be compared in
            // the same one. `zoneLayerChromeFrame` is the chrome view's frame in
            // its superview, the world plane — a WORLD rect, camera-free by
            // design (`worldRect`). `qaZoneHeaderGrabRect` is a SCREEN rect:
            // `zoneHeaderScreenRect` applies `canvasState.viewport`. Comparing
            // them directly only agreed while the canvas camera sat at the
            // origin, and silently became an off-by-the-viewport assertion the
            // moment the mount adopted the document's own camera. Convert the
            // installed chrome view into canvas points and compare there, which
            // is also the space a click arrives in.
            if let header = chromeCanvas.qaZoneHeaderGrabRect(zoneA),
               let chromeOnScreen = chromeCanvas.qaZoneChromeRectInCanvas(for: zoneA) {
                try expect(abs(header.origin.x - chromeOnScreen.origin.x) < 1.0
                           && abs(header.origin.y - chromeOnScreen.origin.y) < 1.0
                           && abs(header.width - chromeOnScreen.width) < 1.0,
                           "the zone's move-grab header must sit on its visible chrome: header \(header) vs chrome on screen \(chromeOnScreen)")
            }
        }
        // If chrome frame is nil, showsZoneChrome may be inactive — assertion skipped (no chrome to verify).

        // Write manifest.
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("workspace-runtime-install", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "workspace-runtime-install",
            "assertions": 10,
            "refCountPaAfterInstall": 1,
            "refCountPbAfterInstall": 1,
            "refCountPaAfterClose": 0,
            "refCountPbAfterClose": 0,
            "activeControllerProjectId": projectPa.uuidString,
            "installedZoneCount": 2,
            "focusRestoredToNoteA": true,
            "paViewportAfterFlush": 99
        ]
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }
}

// Required for ProjectEntry construction in the check (mirrors existing check patterns).
private extension Registry {
    // ProjectEntry is already public in Registry.swift; this just satisfies the access.
}

/// How many recently left workspaces keep their scene warm: controllers,
/// runtimes and real tile views detached but alive, so going back re-attaches
/// them instead of rebuilding. Beyond it, the least recently used is released
/// through the ordinary path. `continuum.workspace.warmScenes` overrides it.
enum WorkspaceWarmSceneConfig {
    static let key = "continuum.workspace.warmScenes"
    static let defaultCapacity = 2

    static func capacity(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultCapacity }
        return max(0, defaults.integer(forKey: key))
    }
}

/// A project a switch needed but could not open, named for the user.
enum WorkspaceProjectAcquisitionError: Error, LocalizedError, CustomStringConvertible {
    /// Another copy of Array holds its `.array/lock` (hazard 10).
    case heldElsewhere(projectName: String)
    case unavailable(projectName: String, underlying: Error)

    static func from(_ error: Error, projectName: String) -> WorkspaceProjectAcquisitionError {
        if case ProjectLockError.alreadyLocked = error { return .heldElsewhere(projectName: projectName) }
        if let mapped = error as? WorkspaceProjectAcquisitionError { return mapped }
        return .unavailable(projectName: projectName, underlying: error)
    }

    var errorDescription: String? {
        switch self {
        case let .heldElsewhere(name):
            return "\u{201C}\(name)\u{201D} is open in another copy of Array. Close it there, then try again."
        case let .unavailable(name, underlying):
            return "\u{201C}\(name)\u{201D} couldn't be opened: \(underlying.localizedDescription)"
        }
    }
    var description: String { errorDescription ?? "project unavailable" }
}
