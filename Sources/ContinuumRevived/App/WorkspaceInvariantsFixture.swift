import AppKit
import ContinuumRevivedCore
import Foundation

/// The shared harness for the stability program (`.plans/67-target-architecture`,
/// slice 0). Every later workspace witness builds on it.
///
/// Two seeded workspaces on a temp app-support directory and temp project roots,
/// mounted through `AppDelegate.mountWorkspaceSceneAtBoot` — never
/// `install(into:)`, the checks-only entry hazard 9 records — and driven only
/// through the entry points a user reaches: the sidebar switch, the canvas's
/// click-arming callback, the canvas's rename mutation, the real quit sequence.
///
/// It exposes three readable views of state, and the invariants are asserted
/// over them rather than over any one model:
///
///  - `modelView()`: what the mounted runtime and canvas hold (document, layers,
///    chrome, every tile's WORLD frame);
///  - `diskView()`: the raw bytes of every workspace and project canvas file,
///    decoded directly (never through `AtomicWriter.read`, which would fall back
///    to a backup and hide a bad primary);
///  - `chromeView()`: the strings each zone header actually draws.
///
/// Faults go through `StoreFileWriter`, scoped to this fixture's temp root. A
/// crash-style remount freezes the disk at the current write, lets the dead
/// world's teardown and timers write into the void, then mounts a fresh runtime
/// on the same directories.
@MainActor
final class WorkspaceInvariantsFixture {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    // MARK: - Seed identities

    static let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-0000000067A0")!
    static let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-0000000067B0")!
    static let projectA1 = UUID(uuidString: "00000000-0000-0000-0000-0000000067A1")!
    static let projectA2 = UUID(uuidString: "00000000-0000-0000-0000-0000000067A2")!
    static let projectB1 = UUID(uuidString: "00000000-0000-0000-0000-0000000067B1")!
    static let projectB2 = UUID(uuidString: "00000000-0000-0000-0000-0000000067B2")!
    static let zoneA1 = UUID(uuidString: "00000000-0000-0000-0000-000000067A11")!
    static let zoneA2 = UUID(uuidString: "00000000-0000-0000-0000-000000067A21")!
    /// A second zone of project A1: a project's canvas file spans its zones.
    static let zoneA3 = UUID(uuidString: "00000000-0000-0000-0000-000000067A31")!
    static let zoneB1 = UUID(uuidString: "00000000-0000-0000-0000-000000067B11")!
    static let zoneB2 = UUID(uuidString: "00000000-0000-0000-0000-000000067B21")!
    static let noteA1a = UUID(uuidString: "00000000-0000-0000-0000-0000067A1A01")!
    static let noteA1b = UUID(uuidString: "00000000-0000-0000-0000-0000067A1B01")!
    static let noteA2a = UUID(uuidString: "00000000-0000-0000-0000-0000067A2A01")!
    static let noteA3a = UUID(uuidString: "00000000-0000-0000-0000-0000067A3A01")!
    /// An open file tile in zone A1, for `fileA1Name` at project A1's root.
    static let fileA1 = UUID(uuidString: "00000000-0000-0000-0000-0000067A1F01")!
    static let fileA1Name = "field-notes.md"
    static let noteB1a = UUID(uuidString: "00000000-0000-0000-0000-0000067B1A01")!
    static let noteB2a = UUID(uuidString: "00000000-0000-0000-0000-0000067B2A01")!

    static let projectNames: [UUID: String] = [
        projectA1: "Alder", projectA2: "Birch", projectB1: "Cedar", projectB2: "Dogwood"]
    static let projectOwners: [UUID: UUID] = [
        projectA1: workspaceA, projectA2: workspaceA, projectB1: workspaceB, projectB2: workspaceB]

    /// The seeded scene. Every zone sits at a NON-ZERO origin, so a frame that
    /// crossed a frame space is arithmetically visible, never accidentally right.
    struct SeedScene {
        var zones: [UUID: ZonePlacement]
        var tiles: [UUID: TileFrame]
        var tileProject: [UUID: UUID]
        var tileZone: [UUID: UUID]
        var zonesByWorkspace: [UUID: [UUID]]
    }

    static let seed: SeedScene = {
        func zone(_ id: UUID, project: UUID, x: Double, y: Double, name: String, color: String,
                  height: Double = 700) -> ZonePlacement {
            ZonePlacement(
                zoneId: id, projectId: project,
                origin: ZonePoint(x: x, y: y), size: ZoneSize(width: 900, height: height),
                color: color, collapsed: false, hydrationPolicy: .automatic, name: name)
        }
        let zones = [
            zoneA1: zone(zoneA1, project: projectA1, x: 600, y: 200, name: "Roots", color: "blue"),
            // Empty name: the header derives it from the project.
            zoneA2: zone(zoneA2, project: projectA2, x: 1700, y: 260, name: "", color: "green"),
            zoneA3: zone(zoneA3, project: projectA1, x: 600, y: 1000, name: "Annex", color: "teal", height: 280),
            zoneB1: zone(zoneB1, project: projectB1, x: 400, y: 300, name: "Canopy", color: "purple"),
            zoneB2: zone(zoneB2, project: projectB2, x: 1500, y: 340, name: "", color: "orange")
        ]
        let tiles: [UUID: TileFrame] = [
            noteA1a: TileFrame(x: 640, y: 280, width: 240, height: 160),
            noteA1b: TileFrame(x: 920, y: 480, width: 240, height: 160),
            noteA2a: TileFrame(x: 1760, y: 340, width: 240, height: 160),
            noteA3a: TileFrame(x: 640, y: 1060, width: 240, height: 160),
            fileA1: TileFrame(x: 1200, y: 280, width: 240, height: 200),   // a file tile's minimum height
            noteB1a: TileFrame(x: 450, y: 380, width: 240, height: 160),
            noteB2a: TileFrame(x: 1560, y: 420, width: 240, height: 160)
        ]
        return SeedScene(
            zones: zones,
            tiles: tiles,
            tileProject: [noteA1a: projectA1, noteA1b: projectA1, noteA2a: projectA2, noteB1a: projectB1,
                          noteB2a: projectB2, noteA3a: projectA1, fileA1: projectA1],
            tileZone: [noteA1a: zoneA1, noteA1b: zoneA1, noteA2a: zoneA2, noteB1a: zoneB1, noteB2a: zoneB2,
                       noteA3a: zoneA3, fileA1: zoneA1],
            zonesByWorkspace: [workspaceA: [zoneA1, zoneA2, zoneA3], workspaceB: [zoneB1, zoneB2]]
        )
    }()

    /// Each workspace's seeded camera: both of its zones fully in view (so both
    /// hydrate live on the fixture's 2600x1400 canvas), centred in the gap
    /// between them, so camera arming — which arms the zone under the centre —
    /// never fires on its own.
    static let seededViewports: [UUID: CanvasViewport] = [
        workspaceA: CanvasViewport(x: 300, y: -100, zoom: 1),   // centre (1600, 600): between A1 and A2
        workspaceB: CanvasViewport(x: 100, y: -100, zoom: 1)    // centre (1400, 600): between B1 and B2
    ]

    // MARK: - Directories

    let root: URL
    let appSupport: URL
    let projectRoots: [UUID: URL]
    let registryStore: RegistryStore

    struct Mounted {
        let delegate: AppDelegate
        let canvas: CanvasNSView
        let runtime: WorkspaceRuntime
        let spawner: TileSpawner
        let browserEngine: BrowserEngineContext
    }

    private(set) var mounted: Mounted?
    private(set) var receipts: [Receipt] = []
    private(set) var actionLog: [String] = []

    init(label: String) throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-invariants-\(label)-\(UUID().uuidString)", isDirectory: true)
        appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        var roots: [UUID: URL] = [:]
        for (projectId, name) in Self.projectNames {
            roots[projectId] = root.appendingPathComponent(name, isDirectory: true)
        }
        projectRoots = roots
        for dir in [appSupport] + Array(roots.values) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try seedStores()
    }

    /// Remove the temp directories. Any plan still installed is uninstalled.
    func dispose() {
        StoreFileWriter.uninstall()
        if mounted != nil { _ = try? quit() }
        try? FileManager.default.removeItem(at: root)
    }

    private func seedStores() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let seed = Self.seed
        for (projectId, name) in Self.projectNames {
            let projectRoot = projectRoots[projectId]!
            let store = ProjectStore(projectRoot: projectRoot)
            try store.saveProject(Project(
                id: projectId, name: name, rootPath: projectRoot.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning)))
            let tiles: [Tile] = seed.tileProject.filter { $0.value == projectId }.keys.sorted { $0.uuidString < $1.uuidString }
                .enumerated().map { index, tileId in
                    var tile: Tile
                    if tileId == Self.fileA1 {
                        let url = projectRoot.appendingPathComponent(Self.fileA1Name)
                        let location = DocumentLocationResolver.resolve(
                            fileURL: url, knownRoots: [DocumentLocationRoot(rootURL: projectRoot, projectId: projectId)])
                        tile = Tile(
                            id: tileId, kind: .file, title: Self.fileA1Name,
                            frame: seed.tiles[tileId]!, zPosition: .fromLegacyRank(index + 1),
                            runtimeRef: nil, metadata: TileMetadata(filePath: location.path, documentLocation: location))
                    } else {
                        tile = Tile(
                            id: tileId, kind: .note, title: "note \(index)",
                            frame: seed.tiles[tileId]!, zPosition: .fromLegacyRank(index + 1),
                            runtimeRef: nil, metadata: TileMetadata(noteId: tileId))
                    }
                    tile.zoneId = seed.tileZone[tileId]
                    return tile
                }
            for tile in tiles where tile.kind == .note {
                try store.saveNoteBody(id: tile.id, text: "seed \(tile.id.uuidString.suffix(4))")
            }
            if projectId == Self.projectA1 {
                try "# Field notes\n".write(
                    to: projectRoot.appendingPathComponent(Self.fileA1Name), atomically: true, encoding: .utf8)
            }
            try store.saveCanvas(CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: tiles, groups: [], lastActiveTileId: nil))
        }
        for (workspaceId, zoneIds) in seed.zonesByWorkspace {
            let zones = zoneIds.map { seed.zones[$0]! }
            // The first viewport change after a mount arms whatever zone the
            // camera centre is over (`.camera`); a scenario that did not ask for
            // that must not have its arming moved. See `seededViewports`.
            let document = WorkspaceDocument(
                viewport: Self.seededViewports[workspaceId]!,
                zones: zones, zoneZOrder: zoneIds, lastActiveZoneId: zoneIds.first)
            try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
        }
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = Self.workspaceA
        registry.workspaces = [
            WorkspaceEntry(id: Self.workspaceA, name: "Grove", projectIds: [Self.projectA1, Self.projectA2],
                           createdAt: now, updatedAt: now),
            WorkspaceEntry(id: Self.workspaceB, name: "Forest", projectIds: [Self.projectB1, Self.projectB2],
                           createdAt: now, updatedAt: now)
        ]
        registry.projects = Self.projectNames.keys.sorted { $0.uuidString < $1.uuidString }.map { projectId in
            ProjectEntry(id: projectId, name: Self.projectNames[projectId]!, rootPath: projectRoots[projectId]!.path,
                         workspaceId: Self.projectOwners[projectId], lastOpenedAt: now, pinned: false, missing: false)
        }
        try registryStore.save(registry)
    }

    // MARK: - Mount (the production seam)

    /// Mount the registry's last-active workspace the way launch does: the boot
    /// controller takes the project lock, the runtime is built over the
    /// persisted document, the canvas gets launch's callbacks, and the scene is
    /// installed by `mountWorkspaceSceneAtBoot`.
    func mount() throws {
        guard mounted == nil else { throw Failure(message: "mount: already mounted") }
        let registry = try registryStore.loadOrEmpty()
        guard let active = try AppDelegate.loadActiveWorkspaceDocument(from: registryStore) else {
            throw Failure(message: "mount: the registry names no active workspace")
        }
        // Launch boots the resolved project root; for a persisted workspace that
        // is the project of the zone it last had armed.
        let bootZone = active.document.zones.first { $0.zoneId == active.document.lastActiveZoneId }
            ?? active.document.zones.first
        guard let bootProjectId = bootZone?.projectId, let bootRoot = projectRoots[bootProjectId] else {
            throw Failure(message: "mount: the active workspace has no project zone to boot")
        }
        let bootController = try ZoneRuntimeController(root: bootRoot)
        let registryStore = self.registryStore
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            // Launch's factory, minus the lock-contention alert.
            let live = try registryStore.loadOrEmpty()
            guard let entry = live.projects.first(where: { $0.id == projectId && !$0.missing }) else {
                throw Failure(message: "factory: project \(projectId) is not registered")
            }
            return try ZoneRuntimeController(root: URL(fileURLWithPath: entry.rootPath, isDirectory: true))
        })

        let zoneRenderModels = AppDelegate.zoneRenderModels(from: active.document, registry: registry)
        let activeZone = zoneRenderModels.first(where: { $0.placement.projectId == bootProjectId })?.placement
        let bootCanvas = AppDelegate.isolatedBootCanvasState(
            projectCanvas: try bootController.projectStore.tryLoadCanvas()
                ?? CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            bootProjectId: bootProjectId,
            selectedWorkspaceId: active.workspaceId,
            selectedViewport: active.document.viewport,
            registry: registry)

        let delegate = AppDelegate()
        let canvas = CanvasNSView(canvasState: bootCanvas, activeZone: activeZone, zoneRenderModels: zoneRenderModels)
        canvas.frame = CGRect(x: 0, y: 0, width: 2600, height: 1400)
        delegate.wireCanvasCallbacks(canvas)

        let browserEngine = BrowserEngineContext()
        let runtime = WorkspaceRuntime(
            boot: bootController,
            workspaceId: active.workspaceId,
            document: active.document,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine)
        runtime.lifecycleObserver = { [weak self, weak runtime] event in
            guard let self, let runtime, case let .saveGenerationAcknowledged(generation) = event else { return }
            self.recordReceipt(workspaceId: runtime.workspaceId, document: runtime.document, generation: generation)
        }
        delegate.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        let spawner = TileSpawner(
            canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
            projectStore: bootController.projectStore, project: bootController.project)

        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas, spawner: spawner, projectStore: bootController.projectStore,
            canvasState: bootCanvas, installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()
        mounted = Mounted(delegate: delegate, canvas: canvas, runtime: runtime, spawner: spawner,
                          browserEngine: browserEngine)
        log("mount \(active.workspaceId)")
    }

    func requireMounted(_ step: String) throws -> Mounted {
        guard let mounted else { throw Failure(message: "\(step): nothing is mounted") }
        return mounted
    }

    // MARK: - Actions (real entry points only)

    /// The sidebar row click.
    func switchTo(_ workspaceId: UUID) throws {
        let m = try requireMounted("switch")
        guard m.delegate.qaSwitchWorkspaceFromSidebar(workspaceId) else {
            throw Failure(message: "switch to \(workspaceId) did not mount it; runtime is on \(m.runtime.workspaceId)")
        }
        m.canvas.layoutSubtreeIfNeeded()
        log("switch \(workspaceId)")
    }

    /// The canvas's click-arming callback, as a click on the zone fires it.
    func armByClick(_ zoneId: UUID) throws {
        let m = try requireMounted("arm")
        m.delegate.qaActivateZoneByClick(zoneId)
        log("arm \(zoneId)")
    }

    /// The canvas's rename mutation — the one the inline field commits — which
    /// fires `onZoneRenamed` into launch's `persistRenamedZone`.
    func rename(_ zoneId: UUID, to name: String) throws {
        let m = try requireMounted("rename")
        m.canvas.qaRenameZone(zoneId, to: name)
        log("rename \(zoneId) \(name)")
    }

    /// Run the main run loop so debounce timers and queued saves fire.
    func drain(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Quit the way the user does. Throws if the quit flush was refused.
    func quit() throws {
        let m = try requireMounted("quit")
        let reply = m.delegate.qaQuitForRemount()
        m.browserEngine.shutdown()
        mounted = nil
        drain(0.3)
        log("quit")
        guard reply == .terminateNow else { throw Failure(message: "quit: termination was cancelled") }
    }

    /// Die after the writes already made (or after `writes` more): freeze the
    /// disk, let the dead world's teardown and timers write into the void, and
    /// leave the directories exactly as a killed process would.
    func crash(afterFurtherWrites writes: Int = 0) {
        let landed = StoreFileWriter.trace.filter { $0.outcome == .landed }.count
        StoreFileWriter.install(.init(fault: .abortAfter(writes), scope: root))
        if let m = mounted {
            _ = m.delegate.qaQuitForRemount()
            m.browserEngine.shutdown()
        }
        mounted = nil
        drain(0.8)
        StoreFileWriter.uninstall()
        log("crash after \(landed)+\(writes)")
    }

    /// The mounted scene was torn down by the leg itself (e.g. a quit it drove).
    func forgetMounted() {
        mounted = nil
        log("teardown by the leg")
    }

    func remount(crash crashStyle: Bool) throws {
        if crashStyle { crash() } else { try quit() }
        try mount()
    }

    private func log(_ entry: String) { actionLog.append(entry) }

    // MARK: - Receipts oracle

    /// A success acknowledgement the app issued, checked against disk at the
    /// moment it was issued. A later legitimate write therefore cannot make an
    /// honest receipt look stale, and nothing written later can launder a lie.
    struct Receipt {
        let workspaceId: UUID
        let generation: UInt64
        let claimed: WorkspaceDocument
        let onDisk: WorkspaceDocument?
        var truthful: Bool { onDisk == claimed }
    }

    private func recordReceipt(workspaceId: UUID, document: WorkspaceDocument, generation: UInt64) {
        let onDisk = try? readWorkspaceFile(workspaceId).document
        receipts.append(Receipt(workspaceId: workspaceId, generation: generation, claimed: document, onDisk: onDisk))
    }

    func resetReceipts() { receipts = [] }

    // MARK: - Views

    struct ModelView {
        let workspaceId: UUID
        let document: WorkspaceDocument
        let layerZoneIds: [UUID]
        let chromeZoneIds: Set<UUID>
        let liveZoneIds: [UUID]
        /// Every tile of every project with a zone in the mounted document, WORLD.
        let tileWorldFrames: [UUID: TileFrame]
    }

    func modelView() throws -> ModelView {
        let m = try requireMounted("modelView")
        m.canvas.layoutSubtreeIfNeeded()
        var frames: [UUID: TileFrame] = [:]
        for projectId in Set(m.runtime.document.zones.compactMap(\.projectId)) {
            for tile in m.canvas.tilesInWorldFrames(forProjectId: projectId) { frames[tile.id] = tile.frame }
        }
        return ModelView(
            workspaceId: m.runtime.workspaceId,
            document: m.runtime.document,
            layerZoneIds: m.canvas.qaInstalledLayerZoneIds,
            chromeZoneIds: m.canvas.qaZoneChromeIds,
            liveZoneIds: m.canvas.qaLiveZoneIds,
            tileWorldFrames: frames)
    }

    struct WorkspaceFile {
        let bytes: Data?
        let document: WorkspaceDocument?
    }

    struct ProjectFile {
        let bytes: Data?
        let canvas: CanvasState?
    }

    struct DiskView {
        let registry: Registry
        let workspaces: [UUID: WorkspaceFile]
        let projects: [UUID: ProjectFile]
    }

    func readWorkspaceFile(_ workspaceId: UUID) throws -> WorkspaceFile {
        let url = WorkspaceStoreLayout(applicationSupportDirectory: appSupport, workspaceId: workspaceId).canvasFile
        guard let bytes = try? Data(contentsOf: url) else { return WorkspaceFile(bytes: nil, document: nil) }
        return WorkspaceFile(bytes: bytes, document: try? JSONCodec.makeDecoder().decode(WorkspaceDocument.self, from: bytes))
    }

    func readProjectFile(_ projectId: UUID) -> ProjectFile {
        let url = ProjectStoreLayout(projectRoot: projectRoots[projectId]!).canvasFile
        guard let bytes = try? Data(contentsOf: url) else { return ProjectFile(bytes: nil, canvas: nil) }
        return ProjectFile(bytes: bytes, canvas: try? JSONCodec.makeCanvasDecoder().decode(CanvasState.self, from: bytes))
    }

    func diskView() throws -> DiskView {
        var workspaces: [UUID: WorkspaceFile] = [:]
        for workspaceId in [Self.workspaceA, Self.workspaceB] { workspaces[workspaceId] = try readWorkspaceFile(workspaceId) }
        var projects: [UUID: ProjectFile] = [:]
        for projectId in Self.projectNames.keys { projects[projectId] = readProjectFile(projectId) }
        return DiskView(registry: try registryStore.loadOrEmpty(), workspaces: workspaces, projects: projects)
    }

    /// Zone id → the strings its header drew, rendered offscreen now.
    func chromeView() throws -> [UUID: [String]] {
        let m = try requireMounted("chromeView")
        m.canvas.layoutSubtreeIfNeeded()
        var texts: [UUID: [String]] = [:]
        for zoneId in m.canvas.qaZoneChromeIds {
            texts[zoneId] = m.canvas.qaRenderedZoneHeaderText(for: zoneId) ?? ["<not drawable>"]
        }
        return texts
    }

    // MARK: - Invariants

    enum Invariant: String, CaseIterable {
        /// A workspace file holds a zone another workspace owns, or the
        /// registry's two ownership records disagree.
        case isolation
        /// A mounted layer or chrome with no zone, or a zone with neither.
        case wholeness
        /// A tile's or zone's WORLD geometry differs from the expected scene.
        case geometry
        /// A tile vanished or appeared.
        case conservation
        /// A header draws something its canonical inputs do not say.
        case projection
        /// A success acknowledgement that disk does not back.
        case durability
    }

    struct Violation: CustomStringConvertible, Equatable {
        let invariant: Invariant
        let subject: String
        let detail: String
        var description: String { "[\(invariant.rawValue)] \(subject): \(detail)" }
    }

    /// Every workspace file on disk holds only zones whose project its own
    /// workspace owns; the registry records each project's owner consistently.
    static func isolationViolations(_ disk: DiskView) -> [Violation] {
        var violations: [Violation] = []
        let owner = Dictionary(uniqueKeysWithValues: disk.registry.projects.map { ($0.id, $0.workspaceId) })
        for project in disk.registry.projects {
            let listedBy = disk.registry.workspaces.filter { $0.projectIds.contains(project.id) }.map(\.id)
            if listedBy != [project.workspaceId].compactMap({ $0 }) {
                violations.append(Violation(
                    invariant: .isolation, subject: "project \(project.id)",
                    detail: "entry says owner \(String(describing: project.workspaceId)); workspaces listing it: \(listedBy)"))
            }
        }
        for (workspaceId, file) in disk.workspaces {
            guard let document = file.document else { continue }
            for zone in document.zones {
                guard let projectId = zone.projectId else { continue }
                if owner[projectId] != workspaceId {
                    violations.append(Violation(
                        invariant: .isolation, subject: "workspace \(workspaceId) zone \(zone.zoneId)",
                        detail: "project \(projectId) is owned by \(String(describing: owner[projectId] ?? nil))"))
                }
            }
        }
        return violations
    }

    /// Every installed layer and every chrome view belongs to a zone of the
    /// mounted document, and every document zone has chrome and a layer.
    static func wholenessViolations(_ model: ModelView) -> [Violation] {
        var violations: [Violation] = []
        let documentZoneIds = Set(model.document.zones.map(\.zoneId))
        for zoneId in model.layerZoneIds where !documentZoneIds.contains(zoneId) {
            violations.append(Violation(invariant: .wholeness, subject: "layer \(zoneId)",
                                        detail: "installed, but the mounted document has no such zone"))
        }
        if Set(model.layerZoneIds).count != model.layerZoneIds.count {
            violations.append(Violation(invariant: .wholeness, subject: "layers",
                                        detail: "a zone has two layers: \(model.layerZoneIds)"))
        }
        for zoneId in model.chromeZoneIds where !documentZoneIds.contains(zoneId) {
            violations.append(Violation(invariant: .wholeness, subject: "chrome \(zoneId)",
                                        detail: "drawn, but the mounted document has no such zone"))
        }
        for zone in model.document.zones {
            if !model.chromeZoneIds.contains(zone.zoneId) {
                violations.append(Violation(invariant: .wholeness, subject: "zone \(zone.zoneId)", detail: "has no chrome"))
            }
            if zone.projectId != nil, !model.layerZoneIds.contains(zone.zoneId) {
                violations.append(Violation(invariant: .wholeness, subject: "zone \(zone.zoneId)", detail: "has no layer"))
            }
        }
        return violations
    }

    /// WORLD frames and zone rects equal `expected` exactly — no tolerance, so
    /// a 1pt drift is a violation — and no tile of the mounted workspace is
    /// missing or extra.
    static func geometryViolations(_ model: ModelView, expected: SeedScene) -> [Violation] {
        var violations: [Violation] = []
        let zoneIds = Set(expected.zonesByWorkspace[model.workspaceId] ?? [])
        for zoneId in zoneIds {
            guard let want = expected.zones[zoneId] else { continue }
            guard let got = model.document.zones.first(where: { $0.zoneId == zoneId }) else {
                violations.append(Violation(invariant: .conservation, subject: "zone \(zoneId)", detail: "missing from the mounted document"))
                continue
            }
            if got.origin != want.origin || got.size != want.size {
                violations.append(Violation(
                    invariant: .geometry, subject: "zone \(zoneId)",
                    detail: "rect \(got.origin)/\(got.size), expected \(want.origin)/\(want.size)"))
            }
        }
        let tileIds = Set(expected.tileZone.filter { zoneIds.contains($0.value) }.keys)
        for tileId in tileIds {
            guard let got = model.tileWorldFrames[tileId] else {
                violations.append(Violation(invariant: .conservation, subject: "tile \(tileId)", detail: "missing from the mounted scene"))
                continue
            }
            if got != expected.tiles[tileId] {
                violations.append(Violation(
                    invariant: .geometry, subject: "tile \(tileId)",
                    detail: "WORLD \(got), expected \(expected.tiles[tileId]!)"))
            }
        }
        for tileId in model.tileWorldFrames.keys where !tileIds.contains(tileId) {
            violations.append(Violation(invariant: .conservation, subject: "tile \(tileId)", detail: "appeared in the mounted scene"))
        }
        return violations
    }

    /// Each header draws exactly its zone's title and Home label, derived from
    /// the canonical fields: the zone's name (or its project's when empty) and
    /// `<project> / <home or Project Root>`.
    static func projectionViolations(_ model: ModelView, chrome: [UUID: [String]], registry: Registry) -> [Violation] {
        var violations: [Violation] = []
        for zone in model.document.zones {
            let project = registry.projects.first { $0.id == zone.projectId }
            let title = zone.name.isEmpty ? (project?.name ?? "Zone") : zone.name
            let scope = project.map { "\($0.name) / \(zone.homeRelativePath ?? "Project Root")" } ?? "Needs Project"
            let want = [zone.collapsed ? "▸ \(title)" : title, scope]
            let got = chrome[zone.zoneId]
            if got != want {
                violations.append(Violation(
                    invariant: .projection, subject: "zone \(zone.zoneId)",
                    detail: "header drew \(got.map { "\($0)" } ?? "nothing"), canonical \(want)"))
            }
        }
        return violations
    }

    /// Every acknowledgement issued was backed by disk when it was issued.
    func durabilityViolations() -> [Violation] {
        receipts.filter { !$0.truthful }.map { receipt in
            Violation(
                invariant: .durability, subject: "workspace \(receipt.workspaceId) generation \(receipt.generation)",
                detail: receipt.onDisk == nil
                    ? "acknowledged, but disk holds no readable document"
                    : "acknowledged, but disk holds a different document")
        }
    }

    /// The invariants in `invariants` over all three views, against `expected`.
    func allViolations(
        expected: SeedScene = WorkspaceInvariantsFixture.seed,
        invariants: Set<Invariant> = Set(Invariant.allCases)
    ) throws -> [Violation] {
        let model = try modelView()
        let disk = try diskView()
        let chrome = try chromeView()
        let all = Self.isolationViolations(disk)
            + Self.wholenessViolations(model)
            + Self.geometryViolations(model, expected: expected)
            + Self.projectionViolations(model, chrome: chrome, registry: disk.registry)
            + durabilityViolations()
        return all.filter { invariants.contains($0.invariant) }
    }
}
