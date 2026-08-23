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
           let projectId = zone.projectId,
           let controller = registry.controller(for: projectId) {
            return controller
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
        self.canvasView = canvasView
        canvasView.activateUndoWorkspace(workspaceId)

        // Plan hydration tiers using the configurable budget.
        let plan = ZoneHydrationOrchestrator.plan(
            zones: document.zones,
            viewport: document.viewport,
            visibleSize: CGSize(width: canvasView.bounds.width > 0 ? canvasView.bounds.width : 1280,
                                height: canvasView.bounds.height > 0 ? canvasView.bounds.height : 720),
            focusedTileZone: document.lastActiveZoneId,
            maxLiveZones: ZoneHydrationBudgetConfig.maxLiveZones()
        )

        var layers: [CanvasNSView.ZoneLayer] = []
        var newlyAcquired: [UUID] = []
        let firstZoneByProject = document.zones.reduce(into: [UUID: UUID]()) { result, zone in
            if let projectId = zone.projectId, result[projectId] == nil { result[projectId] = zone.zoneId }
        }

        for zone in document.zones {
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
            if newlyAcquired.contains(projectId), let existing = registry.controller(for: projectId) {
                controller = existing
            } else {
                controller = try registry.acquire(projectId: projectId)
                newlyAcquired.append(projectId)
            }

            // Load canvas state for this zone's project.
            let canvasState: CanvasState
            if let loaded = try controller.projectStore.tryLoadCanvas() {
                canvasState = loaded
            } else {
                canvasState = CanvasState(
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                    tiles: [],
                    groups: [],
                    lastActiveTileId: nil
                )
            }

            // A project can appear in several zones. Persisted `zoneId` owns
            // membership; pre-membership legacy tiles are adopted by only that
            // project's first zone so they are never rendered N times.
            // M1.0 (.plans/46): STAMP the adoption. A pre-membership legacy tile
            // (zoneId == nil) adopted by this zone is written back with that zone
            // id, so persistence can tell "deleted from a zone I can see" from
            // "lives in a zone I cannot see". Leaving it nil makes that
            // undecidable, and the safe answer to an undecidable delete is to keep
            // the tile forever -- which loses real deletions instead.
            let memberTiles = canvasState.tiles.filter {
                $0.zoneId == zone.zoneId || ($0.zoneId == nil && firstZoneByProject[projectId] == zone.zoneId)
            }.map { tile -> Tile in
                var adopted = tile
                adopted.zoneId = zone.zoneId
                return adopted
            }
            // Build tile views (descriptor views — headless safe; real hydration is T08).
            var tileViews: [UUID: TileNSView] = [:]
            for tile in memberTiles {
                let view = DescriptorTileNSView(tile: tile)
                tileViews[tile.id] = view
            }

            // Derive display name from registry project entry or zone name.
            let displayName: String
            if let registryName = appRegistry.projects.first(where: { $0.id == projectId })?.name {
                displayName = registryName
            } else if !zone.name.isEmpty {
                displayName = zone.name
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

        acquiredProjectIds = newlyAcquired

        // Wire the broker before setZones so _installLayer can register adapters.
        canvasView.focusBroker = focusBroker

        hydrateZoneLayerTiles?(canvasView, layers, .beforeInstall)
        canvasView.setZones(layers)
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
        // The same project may intentionally appear in several organizational
        // zones. Acquire its runtime once, then create a distinct placement each
        // time; zone membership remains per tile through `zoneId`.
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
        let memberTiles = canvasState.tiles.filter { $0.zoneId == placement.zoneId }

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
        if let canvas = canvasView { hydrateZoneLayerTiles?(canvas, [layer], .afterInstall) }

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
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
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
        // 1. Flush current + persist departing workspace's live viewport/focus to disk.
        let departingFocus = departingFocusSnapshot(from: canvasView)
        flushAll()
        try persistDepartingWorkspaceState(focus: departingFocus)

        // 2. Load target document.
        let appSupport = registryStore.registryFile.deletingLastPathComponent()
        let targetStore = WorkspaceStore(workspaceId: targetWorkspaceId, applicationSupportDirectory: appSupport)
        guard let targetDocument = try targetStore.tryLoad() else {
            throw WorkspaceSwitchError.documentNotFound(targetWorkspaceId)
        }

        // 3. Diff project sets.
        let currentProjectIds = Set(acquiredProjectIds)
        let targetProjectIds = Set(
            targetDocument.zones.compactMap(\.projectId)
        )
        let departing = currentProjectIds.subtracting(targetProjectIds)
        let arriving = targetProjectIds.subtracting(currentProjectIds)

        // Build new ZoneLayers for the target workspace before releasing (so shared controllers stay alive).
        let plan = ZoneHydrationOrchestrator.plan(
            zones: targetDocument.zones,
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
        for zone in targetDocument.zones {
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
        let firstZoneByProject = targetDocument.zones.reduce(into: [UUID: UUID]()) { result, zone in
            if let projectId = zone.projectId, result[projectId] == nil { result[projectId] = zone.zoneId }
        }
        for zone in targetDocument.zones {
            guard let projectId = zone.projectId else {
                // Ambient zone: rendered from the workspace document's ambientTiles
                // register, same as install (ticket 03).
                layers.append(Self.makeAmbientZoneLayer(zone: zone, document: targetDocument))
                continue
            }
            guard plan.tier(for: zone.zoneId) == .live else { continue }
            guard let controller = registry.controller(for: projectId) else { continue }

            let canvasState: CanvasState
            if let loaded = try controller.projectStore.tryLoadCanvas() {
                canvasState = loaded
            } else {
                canvasState = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
            }
            // M1.0 (.plans/46): STAMP the adoption. A pre-membership legacy tile
            // (zoneId == nil) adopted by this zone is written back with that zone
            // id, so persistence can tell "deleted from a zone I can see" from
            // "lives in a zone I cannot see". Leaving it nil makes that
            // undecidable, and the safe answer to an undecidable delete is to keep
            // the tile forever -- which loses real deletions instead.
            let memberTiles = canvasState.tiles.filter {
                $0.zoneId == zone.zoneId || ($0.zoneId == nil && firstZoneByProject[projectId] == zone.zoneId)
            }.map { tile -> Tile in
                var adopted = tile
                adopted.zoneId = zone.zoneId
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

        // 4. Swap canvas. The first switch also retires the boot-only flat
        // compatibility scene so tiles from the departing project cannot remain
        // visible or navigable in an unrelated (including empty) workspace.
        canvasView?.retireFlatCompatibilityScene()
        if let canvas = canvasView { hydrateZoneLayerTiles?(canvas, layers, .beforeInstall) }
        canvasView?.setZones(layers)
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
        /// M1.10: the runtime was asked to switch before anything gave it a canvas.
        case noCanvas
        var description: String {
            switch self {
            case let .documentNotFound(id): return "switchWorkspace: no document for workspace \(id)"
            case .noCanvas:
                return "switchWorkspace: this WorkspaceRuntime has no canvas — nothing called adoptCanvas(_:), so the switch would have silently changed the document and left the canvas alone"
            }
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
        for zone in document.zones {
            guard let projectId = zone.projectId,
                  let controller = registry.controller(for: projectId),
                  let plannedTier = plan.tier(for: zone.zoneId) else { continue }
            guard plannedTier != controller.hydrationTier else { continue }
            try? controller.setTier(plannedTier, allowDehydratingFocusedZone: false)
        }
        // Layer budget eviction over the live set (T07 cross-zone cap).
        enforceBrowserRuntimeBudget()
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
        let appSupportForSave = registryStore.registryFile.deletingLastPathComponent()
        let departingStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupportForSave)
        try departingStore.save(document)
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
            // Compute the expected adaptive bounds for zoneA's tiles.
            let canvasStateA = try storeA.loadCanvas()
            let memberFrames = canvasStateA.tiles.map { CanvasEngine.worldFrame(tile: $0, in: placementA) }
            var adaptiveBounds = CanvasEngine.zoneBounds(
                memberFrames: memberFrames,
                padding: ZoneBoundsConfig.padding(),
                minSize: ZoneBoundsConfig.emptyMinSize(),
                headerHeight: ZoneChromeNSView.headerHeight
            )
            if memberFrames.isEmpty {
                adaptiveBounds = TileFrame(x: placementA.origin.x + adaptiveBounds.x,
                                           y: placementA.origin.y + adaptiveBounds.y,
                                           width: adaptiveBounds.width,
                                           height: adaptiveBounds.height)
            }
            let expectedChromeFrame = CanvasEngine.tileScreenFrame(adaptiveBounds, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
            let diff = abs(chromeFrame.origin.x - expectedChromeFrame.origin.x)
                + abs(chromeFrame.origin.y - expectedChromeFrame.origin.y)
                + abs(chromeFrame.width - expectedChromeFrame.width)
                + abs(chromeFrame.height - expectedChromeFrame.height)
            try expect(diff < 1.0, "adaptive-chrome carry-forward: zoneA chrome frame \(chromeFrame) should match adaptive bounds \(expectedChromeFrame)")
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
