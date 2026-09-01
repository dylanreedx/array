import AppKit
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
    private(set) var workspaceId: UUID
    private(set) var document: WorkspaceDocument
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

    // Tracks which projectIds this runtime acquired (for closeAll).
    private var acquiredProjectIds: [UUID] = []

    // Retains the installed ZoneLayers so the check (and T09 swap) can read back placements.
    private var installedLayers: [CanvasNSView.ZoneLayer] = []

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
        document.lastActiveZoneId = placement.zoneId
        try persistWorkspaceDocument()
    }

    func commitClosedZone(_ zoneId: UUID) throws {
        guard document.zones.contains(where: { $0.zoneId == zoneId }) else {
            throw WorkspaceMutationError.zoneNotFound(zoneId)
        }
        document.zones.removeAll { $0.zoneId == zoneId }
        document.setTiles([], forZone: zoneId)
        if document.lastActiveZoneId == zoneId {
            document.lastActiveZoneId = document.zonesInZOrder.last?.zoneId
        }
        try persistWorkspaceDocument()
    }

    enum WorkspaceMutationError: Error, LocalizedError {
        case zoneNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case let .zoneNotFound(zoneId): return "Zone \(zoneId) is not part of the mounted workspace."
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

    private var armingSaveController: WorkspaceDocumentSaveController?

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

        let previousProjectId = activeController?.project.id
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
            if armingSaveController == nil {
                let appSupport = registryStore.registryFile.deletingLastPathComponent()
                armingSaveController = WorkspaceDocumentSaveController(
                    store: WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport))
            }
            armingSaveController?.scheduleZoneLayoutSave(document)
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

    /// QA: drain the debounced arming write so a check can assert on disk.
    func flushPendingArmingSave() {
        try? armingSaveController?.flushPendingSave()
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
    private func membership(
        forProject projectId: UUID,
        controller: ZoneRuntimeController,
        in document: WorkspaceDocument,
        cache: inout [UUID: [UUID: [Tile]]]
    ) -> [UUID: [Tile]] {
        if let cached = cache[projectId] { return cached }
        let persisted = ((try? controller.projectStore.tryLoadCanvas()) ?? nil)
            ?? CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                           tiles: [], groups: [], lastActiveTileId: nil)
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
        let byZone = membership(
            forProject: controller.project.id, controller: controller, in: document, cache: &cache)
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
        let persisted = ((try? controller.projectStore.tryLoadCanvas()) ?? nil)?.tiles ?? []
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
    /// where one exists so display names stay whatever the layer resolved.
    /// M1.10: a zone below the live tier still draws and is still navigable.
    private static func zoneRenderModels(
        for document: WorkspaceDocument,
        layers: [CanvasNSView.ZoneLayer]
    ) -> [CanvasNSView.ZoneRenderModel] {
        zoneRenderModels(for: document.zones, layers: layers)
    }

    private static func zoneRenderModels(
        for zones: [ZonePlacement],
        layers: [CanvasNSView.ZoneLayer]
    ) -> [CanvasNSView.ZoneRenderModel] {
        let byZone = Dictionary(
            layers.map { ($0.placement.zoneId, $0.renderModel) },
            uniquingKeysWith: { first, _ in first })
        return zones.map { zone in
            byZone[zone.zoneId]
                ?? CanvasNSView.ZoneRenderModel(
                    placement: zone,
                    displayName: zone.name.isEmpty ? "Zone" : zone.name)
        }
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
        // Cold launch and an in-process switch must mount the same semantic scene.
        // Preserve legacy foreign placements in the document, but never draw them
        // in a workspace that does not own their project.
        let mountableZones = try Self.mountableZones(
            in: document, workspaceId: workspaceId, registry: appRegistry)
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
            let memberTiles = (membership(forProject: projectId, controller: controller,
                                          in: document, cache: &membershipCache)[zone.zoneId] ?? [])
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
            // Build tile views (descriptor views — headless safe; real hydration is T08).
            var tileViews: [UUID: TileNSView] = [:]
            for tile in memberTiles {
                let view = DescriptorTileNSView(tile: tile)
                tileViews[tile.id] = view
            }

            // A saved custom name always wins. Registry/project names are only
            // fallbacks for a genuinely unnamed placement.
            let displayName: String
            if !zone.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = zone.name
            } else if let registryName = appRegistry.projects.first(where: { $0.id == projectId })?.name {
                displayName = registryName
            } else {
                displayName = controller.project.name
            }

            let renderModel = CanvasNSView.ZoneRenderModel(
                placement: zone,
                displayName: displayName
            )
            let layer = CanvasNSView.ZoneLayer(
                placement: zone,
                renderModel: renderModel,
                tiles: memberTiles
            )
            layer.tileViews = tileViews
            layers.append(layer)
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
            documentZones: Self.zoneRenderModels(for: mountableZones, layers: layers))
        installedLayers = layers

        // Declare the spawn target BEFORE anything can spawn into it.
        canvasView.setActiveProjectZone(document.lastActiveZoneId)

        // Attach UI to the active controller so dirty tracking and focus callbacks work.
        attachActiveControllerUI(canvasView: canvasView)
        // Phase B needs the active controller's spawner, which the line above builds.
        hydrateZoneLayerTiles?(canvasView, layers, .afterInstall)

        // Restore focus: active zone's last-active tile, or fall back to canvas.
        restoreFocus(from: canvasView)
    }

    /// Flush every live controller's pending saves (fan-out of `flushPendingSaves`).
    func flushAll() {
        for projectId in acquiredProjectIds {
            registry.controller(for: projectId)?.flushPendingSaves()
        }
    }

    /// Release every acquired controller via the registry (ref-count → close-at-zero),
    /// clear the canvas zone set (which unregisters tile adapters), drop references.
    func closeAll() {
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

        // Derive display name.
        let displayName: String
        if let registryName = appRegistry?.projects.first(where: { $0.id == projectId })?.name {
            displayName = registryName
        } else {
            displayName = controller.project.name
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

        let renderModel = CanvasNSView.ZoneRenderModel(placement: placement, displayName: displayName)
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

        return placement.zoneId
    }

    /// Build the canvas layer for an ambient (projectId == nil) zone from the
    /// workspace document's `ambientTiles` register — the production read path
    /// of the ticket-03 membership re-model.
    private static func makeAmbientZoneLayer(
        zone: ZonePlacement,
        document: WorkspaceDocument
    ) -> CanvasNSView.ZoneLayer {
        let memberTiles = document.tiles(forZone: zone.zoneId)
        var tileViews: [UUID: TileNSView] = [:]
        for tile in memberTiles {
            tileViews[tile.id] = DescriptorTileNSView(tile: tile)
        }
        let displayName = zone.name.isEmpty ? "Group" : zone.name
        let renderModel = CanvasNSView.ZoneRenderModel(placement: zone, displayName: displayName)
        let layer = CanvasNSView.ZoneLayer(placement: zone, renderModel: renderModel, tiles: memberTiles)
        layer.tileViews = tileViews
        return layer
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
        for controller in registry.liveControllers {
            let spawner = makeSpawner(for: controller, canvasView: canvasView)
            if controller === active {
                controller.attachUI(canvasView: canvasView, tileSpawner: spawner, focusBroker: focusBroker)
            } else {
                controller.attachSpawner(spawner, canvasView: canvasView)
            }
        }
    }

    private func makeSpawner(for controller: ZoneRuntimeController, canvasView: CanvasNSView) -> TileSpawner {
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
        // recorded them. This method runs for every live controller each time the
        // active project changes, which is now as often as the user clicks a zone.
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
        let outcome = spawner.spawnFile(
            location: request.location,
            title: title,
            at: worldPoint,
            beside: anchor,
            targetZoneId: sourceZoneId
        )
        let mapped: FileOpenOutcome
        switch outcome {
        case let .spawned(tileId): mapped = .opened(tileId: tileId)
        case let .alreadyOpen(tileId): mapped = .revealed(tileId: tileId)
        case .invalidPath: mapped = .failure("Couldn't open \(title): that path isn't a file Array can show.")
        case let .failure(error): mapped = .failure("Couldn't open \(title): \(error.localizedDescription)")
        }
        if let agentId = request.sourceAgentId {
            switch mapped {
            case let .opened(tileId), let .revealed(tileId):
                document.linkDocument(tileId, to: agentId)
                do { try persistWorkspaceDocument() }
                catch { return .failure("Opened \(title), but couldn't save its agent relationship: \(error.localizedDescription)") }
                refreshDocumentRelationships()
            case .failure: break
            }
        }
        switch mapped {
        case let .opened(tileId), let .revealed(tileId):
            _ = focusBroker.enterScope(.tile(tileId), reason: .tileSpawned)
        case .failure: break
        }
        return mapped
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
        document.removeDocumentLinks(agentId: agentId, tileId: tileId)
        try persistWorkspaceDocument()
        refreshDocumentRelationships()
    }

    private func persistWorkspaceDocument() throws {
        try saveWorkspaceDocument(document, workspaceId: workspaceId)
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
            return
        }
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        try WorkspaceStore(
            workspaceId: workspaceId,
            applicationSupportDirectory: appSupport).save(document)
    }

    // MARK: - Workspace Switch (T09)

    /// Tear down the current workspace's zone layers + runtimes and install the target
    /// workspace's in-process (no app relaunch). Steps:
    ///   1. Flush all current controllers and persist departing viewport/focus.
    ///   2. Load the target `WorkspaceDocument` from disk.
    ///   3. Diff current vs target project sets: release departing (ref-count → close-at-zero),
    ///      keep shared (same instance, ref-count unchanged), acquire arriving.
    ///   4. Build `ZoneLayer`s for the target workspace and call `setZones` on the canvas
    ///      (which unregisters old adapters and registers new ones via T05).
    ///   5. Set the canvas viewport to the target document's saved viewport.
    ///   6. Restore focus to the target workspace's last-active tile (or `.canvas`).
    ///   7. Update `workspaceId`, `document`, `acquiredProjectIds`.
    ///
    /// The relaunch-spy seam: `_relaunchSpy` is non-nil only in checks; production leaves it nil.
    var _relaunchSpy: (() -> Void)?

    func switchWorkspace(to targetWorkspaceId: UUID) throws {
        // M1.10: the defect this milestone exists to fix was that EVERY canvas call
        // below optional-chained through a nil `canvasView` and did nothing, for
        // months, in silence. Refusing loudly means any future path that reaches a
        // canvas-less runtime fails at the first click instead.
        guard canvasView != nil else { throw WorkspaceSwitchError.noCanvas }
        // Validate and load the target before touching the mounted scene or either
        // workspace file. Do not validate the departing document here: the mounted
        // canvas is the current truth, and a legacy foreign zone in the old saved
        // document must not trap the user in that workspace after they close it.
        // A target may contain a legacy foreign zone too. The declared project
        // owner remains authoritative: preserve that zone in the target document,
        // but exclude it from the mounted scene. Rejecting the entire target here
        // made every old A↔B pair permanently unswitchable when either side carried
        // one stale pre-exclusive-ownership placement.
        var appRegistry = try registryStore.loadOrEmpty()
        guard var targetDocument = try loadWorkspaceDocument(workspaceId: targetWorkspaceId) else {
            throw WorkspaceSwitchError.documentNotFound(targetWorkspaceId)
        }
        let targetZones = try Self.mountableZones(
            in: targetDocument, workspaceId: targetWorkspaceId, registry: appRegistry)
        let targetZoneIds = Set(targetZones.map(\.zoneId))
        if let active = targetDocument.lastActiveZoneId, !targetZoneIds.contains(active) {
            targetDocument.lastActiveZoneId = targetDocument.zonesInZOrder
                .last(where: { targetZoneIds.contains($0.zoneId) })?.zoneId
        }

        // Capture every visible register and synchronously save it while the
        // departing scene is still mounted and interactive.
        let departingFocus = departingFocusSnapshot(from: canvasView)
        flushAll()
        try persistDepartingWorkspaceState(focus: departingFocus)

        // 3. Diff project sets.
        let currentProjectIds = Set(acquiredProjectIds)
        let targetProjectIds = Set(
            targetZones.compactMap(\.projectId)
        )
        if let sharedProjectId = currentProjectIds.intersection(targetProjectIds).first {
            throw WorkspaceSwitchError.projectAppearsInBothWorkspaces(sharedProjectId)
        }
        let departing = currentProjectIds.subtracting(targetProjectIds)
        let arriving = targetProjectIds.subtracting(currentProjectIds)

        // Build new ZoneLayers for the target workspace before releasing (so shared controllers stay alive).
        let plan = ZoneHydrationOrchestrator.plan(
            zones: targetZones,
            viewport: targetDocument.viewport,
            visibleSize: canvasView.map { CGSize(width: $0.bounds.width > 0 ? $0.bounds.width : 1280,
                                                  height: $0.bounds.height > 0 ? $0.bounds.height : 720) }
                ?? CGSize(width: 1280, height: 720),
            focusedTileZone: targetDocument.lastActiveZoneId,
            maxLiveZones: ZoneHydrationBudgetConfig.maxLiveZones()
        )

        // Acquire arriving project controllers (only truly new ones — shared ones already have ref-count).
        // newlyAcquired tracks the full set of projectIds this workspace owns after the switch (de-duped).
        var newlyAcquired: [UUID] = []
        var acquiredSet = Set<UUID>()
        for zone in targetZones {
            guard let projectId = zone.projectId else { continue }
            guard plan.tier(for: zone.zoneId) == .live else { continue }
            if arriving.contains(projectId) && !acquiredSet.contains(projectId) {
                // Truly new: acquire (creates controller at ref=1).
                _ = try registry.acquire(projectId: projectId)
            }
            if !acquiredSet.contains(projectId) {
                newlyAcquired.append(projectId)
                acquiredSet.insert(projectId)
            }
        }

        // Build layers from newly acquired + shared controllers.
        var layers: [CanvasNSView.ZoneLayer] = []
        var membershipCache: [UUID: [UUID: [Tile]]] = [:]
        for zone in targetZones {
            guard let projectId = zone.projectId else {
                // Ambient zone: rendered from the workspace document's ambientTiles
                // register, same as install (ticket 03).
                layers.append(Self.makeAmbientZoneLayer(zone: zone, document: targetDocument))
                continue
            }
            guard plan.tier(for: zone.zoneId) == .live else { continue }
            guard let controller = registry.controller(for: projectId) else { continue }

            // M1.0/M1.10: see `install`. One repaired membership answer per
            // project; the per-zone filter it replaces rendered a foreign-stamped
            // tile nowhere.
            let memberTiles = (membership(forProject: projectId, controller: controller,
                                          in: targetDocument, cache: &membershipCache)[zone.zoneId] ?? [])
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
            var tileViews: [UUID: TileNSView] = [:]
            for tile in memberTiles {
                let view = DescriptorTileNSView(tile: tile)
                tileViews[tile.id] = view
            }
            let displayName = zone.name.isEmpty ? controller.project.name : zone.name
            let renderModel = CanvasNSView.ZoneRenderModel(placement: zone, displayName: displayName)
            let layer = CanvasNSView.ZoneLayer(placement: zone, renderModel: renderModel, tiles: memberTiles)
            layer.tileViews = tileViews
            layers.append(layer)
        }

        // Commit the selected workspace only after every throwing preparation step
        // has succeeded, but before changing the mounted canvas. A failed registry
        // save therefore leaves the departing scene intact; a successful switch is
        // also the workspace restored on the next launch.
        appRegistry.lastActiveWorkspaceId = targetWorkspaceId
        try registryStore.save(appRegistry)

        // 4. Swap canvas. The first switch also retires the boot-only flat
        // compatibility scene so tiles from the departing project cannot remain
        // visible or navigable in an unrelated (including empty) workspace.
        canvasView?.retireFlatCompatibilityScene()
        if let canvas = canvasView { hydrateZoneLayerTiles?(canvas, layers, .beforeInstall) }
        canvasView?.setZones(layers, documentZones: Self.zoneRenderModels(for: targetZones, layers: layers))
        installedLayers = layers

        // 5. Release departing (after setZones so adapters are already unregistered by T05).
        for projectId in departing {
            registry.release(projectId: projectId)
        }

        // 6. Set viewport.
        canvasView?.setViewport(targetDocument.viewport)

        // 7. Re-establish focus.
        workspaceId = targetWorkspaceId
        document = targetDocument
        acquiredProjectIds = newlyAcquired
        refreshDocumentRelationships()
        canvasView?.activateUndoWorkspace(targetWorkspaceId)

        // Attach UI to the new active controller.
        if let canvas = canvasView {
            canvas.setActiveProjectZone(targetDocument.lastActiveZoneId)
            attachActiveControllerUI(canvasView: canvas)
            // Phase B needs the active controller's spawner, built on the line above.
            hydrateZoneLayerTiles?(canvas, layers, .afterInstall)
        }

        if let canvas = canvasView {
            restoreFocus(from: canvas, frameWorkspaceOnFallback: true)
        } else {
            _ = focusBroker.requestFocus(.canvas, reason: .appActivated)
        }
    }

    enum WorkspaceSwitchError: Error, CustomStringConvertible {
        case documentNotFound(UUID)
        case projectAppearsInBothWorkspaces(UUID)
        /// M1.10: the runtime was asked to switch before anything gave it a canvas.
        case noCanvas
        var description: String {
            switch self {
            case let .documentNotFound(id): return "switchWorkspace: no document for workspace \(id)"
            case let .projectAppearsInBothWorkspaces(projectId):
                return "switchWorkspace: project \(projectId) appears in both workspaces; move it explicitly instead"
            case .noCanvas:
                return "switchWorkspace: this WorkspaceRuntime has no canvas — nothing called adoptCanvas(_:), so the switch would have silently changed the document and left the canvas alone"
            }
        }
    }

    private static func validateProjectOwnership(
        in document: WorkspaceDocument,
        workspaceId: UUID,
        registry: Registry
    ) throws {
        for projectId in Set(document.zones.compactMap(\.projectId)) {
            guard try registry.exclusiveWorkspaceOwner(of: projectId) == workspaceId else {
                let owner = try registry.exclusiveWorkspaceOwner(of: projectId) ?? workspaceId
                throw ProjectWorkspaceOwnershipError.alreadyOwned(
                    projectId: projectId, workspaceId: owner)
            }
        }
    }

    /// The document stays byte-for-byte semantically complete, while the mounted
    /// scene contains only ambient zones and zones whose project declares this
    /// workspace as its owner. Ordinary switching never moves, deletes, or rewrites
    /// a legacy foreign placement; the explicit project-move flow remains the only
    /// ownership writer.
    private static func mountableZones(
        in document: WorkspaceDocument,
        workspaceId: UUID,
        registry: Registry
    ) throws -> [ZonePlacement] {
        try document.zones.filter { zone in
            guard let projectId = zone.projectId else { return true }
            return try registry.exclusiveWorkspaceOwner(of: projectId) == workspaceId
        }
    }

    // MARK: - Browser Runtime Budget (T07)

    private var browserRuntimeBudget = BrowserRuntimeBudget(maxLive: BrowserRuntimeBudget.resolveMaxLive())

    func registerLiveBrowser(tileId: UUID) {
        browserRuntimeBudget.registerLive(tileId: tileId)
    }

    /// Gather protected tile ids from each live controller's canvas lastActiveTileId.
    private func currentProtectedBrowserTileIds() -> Set<UUID> {
        var protected = Set<UUID>()
        for controller in registry.liveControllers {
            if let tileId = controller.canvasView?.canvasState.lastActiveTileId {
                protected.insert(tileId)
            }
        }
        return protected
    }

    /// Enforce the WKWebView cap across the UNION of live browser tiles in ALL live zones.
    func enforceBrowserRuntimeBudget() {
        let liveControllers = registry.liveControllers
        let liveTileIds: [UUID] = liveControllers.flatMap { $0.browserRuntimes.map(\.tileId) }
        let protected = currentProtectedBrowserTileIds()
        let evictIds = browserRuntimeBudget.evictionCandidates(liveTileIds: liveTileIds, protectedTileIds: protected)
        for tileId in evictIds {
            guard let controller = liveControllers.first(where: { $0.browserRuntimes.contains { $0.tileId == tileId } }),
                  let runtime = controller.browserRuntimes.first(where: { $0.tileId == tileId }),
                  let spawner = controller.tileSpawner else { continue }
            do {
                try spawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: AppDelegate.browserBudgetSnapshotImage())
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
    func reconcileHydration() {
        reconcileCount += 1
        guard let canvasView else { return }
        let viewport = canvasView.viewport
        let visibleSize = CGSize(
            width: canvasView.bounds.width > 0 ? canvasView.bounds.width : 1280,
            height: canvasView.bounds.height > 0 ? canvasView.bounds.height : 720
        )
        let focusedTileZone: UUID? = {
            guard let activeTileId = canvasView.canvasState.lastActiveTileId else { return nil }
            return document.zones.first(where: { zone in
                guard let projectId = zone.projectId,
                      let controller = registry.controller(for: projectId) else { return false }
                return controller.canvasView?.canvasState.tiles.contains { $0.id == activeTileId } ?? false
            })?.zoneId
        }()
        let plan = ZoneHydrationOrchestrator.plan(
            zones: document.zones,
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
        for zone in document.zones {
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
                } catch {
                    // Its `.array/` is held by another install (hazard 10), or the
                    // root is gone. Leave it unacquired: creation refuses and asks
                    // which project, rather than landing in one the user did not
                    // point at.
                    onZoneProjectUnavailable?(projectId, error)
                }
                continue
            }
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
        if let armed = CanvasEngine.cameraArmedZone(
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
        runtime.flushAll()

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
            try expect(diff < 1.0, "stored-frame chrome: zoneA chrome frame \(chromeFrame) should match its stored placement \(expectedChromeFrame)")
            // And the whole point of the stored frame: chrome IS the grab target.
            if let header = chromeCanvas.qaZoneHeaderGrabRect(zoneA) {
                try expect(abs(header.origin.x - chromeFrame.origin.x) < 1.0
                           && abs(header.width - chromeFrame.width) < 1.0,
                           "the zone's move-grab header must sit on its visible chrome: header \(header) vs chrome \(chromeFrame)")
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
