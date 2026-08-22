import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.3b (`.plans/46`) — every LIVE zone's tiles hydrate, not just the active one.
///
/// `WorkspaceRuntime.attachActiveControllerUI` built exactly one `TileSpawner`,
/// for the active controller. Every other live controller had
/// `tileSpawner == nil` — which is why `enforceBrowserRuntimeBudget` still
/// `continue`s past a controller without one, and why the hydrator's Phase B
/// could only restore terminals and browsers in the zone you happened to be
/// looking at. A two-zone workspace therefore came back from a switch with a
/// live tile in the active zone and a dead `DescriptorTileNSView` in the other:
/// "scene integrity" for one zone out of N.
///
/// **What this leg pins that a structural check would not.** Asserting
/// `tileSpawner != nil` would pass on a change that hands every controller a
/// spawner and never runs Phase B for it. So the primary assertion is the view
/// class of a NON-ACTIVE zone's terminal tile, and the spawner assertion is a
/// diagnostic underneath it.
///
/// **And it pins the other half: `attachSpawner` must stay a subset.**
/// `attachUI` starts a session observer and a tmux reaper and takes the shared
/// `focusBroker` callbacks — process-wide attachments that exactly one controller
/// may hold. Widening the spawner to N controllers must not widen those to N as
/// well, so the leg asserts the non-active controller holds neither. Without that
/// assertion the cheapest way to make this leg green would be to call `attachUI`
/// on everything, which is a worse bug than the one being fixed: N tmux reapers
/// sweeping the same server.
@MainActor
enum ZoneSpawnerCoverageChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func describe(_ view: TileNSView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    static func run() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B1")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B2")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B3")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B4")!
        let projectPc = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B5")!
        let zoneZa = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B6")!
        let zoneZb = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B7")!
        let zoneZc = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B8")!
        let terminalTa = UUID(uuidString: "00000000-0000-0000-0000-0000000A13B9")!
        let terminalTb = UUID(uuidString: "00000000-0000-0000-0000-0000000A13BA")!
        let terminalTc = UUID(uuidString: "00000000-0000-0000-0000-0000000A13BB")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-spawner-coverage-\(UUID().uuidString)", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        struct Fixture {
            let project: Project
            let store: ProjectStore
            let root: URL
        }
        func makeFixture(id: UUID, name: String, zone: UUID, terminal: UUID) throws -> Fixture {
            let root = tempRoot.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let project = Project(
                id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
            var tile = Tile(
                id: terminal, kind: .terminal, title: "term",
                frame: TileFrame(x: 10, y: 10, width: 300, height: 200),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "shell")
            )
            tile.zoneId = zone
            let store = ProjectStore(projectRoot: root)
            try store.saveProject(project)
            try store.saveCanvas(CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [tile], groups: [], lastActiveTileId: terminal
            ))
            return Fixture(project: project, store: store, root: root)
        }

        let pa = try makeFixture(id: projectPa, name: "Pa", zone: zoneZa, terminal: terminalTa)
        let pb = try makeFixture(id: projectPb, name: "Pb", zone: zoneZb, terminal: terminalTb)
        let pc = try makeFixture(id: projectPc, name: "Pc", zone: zoneZc, terminal: terminalTc)

        func placement(_ zone: UUID, project: UUID, x: Double, color: String) -> ZonePlacement {
            ZonePlacement(
                zoneId: zone, projectId: project,
                origin: ZonePoint(x: x, y: 0), size: ZoneSize(width: 500, height: 400),
                color: color, collapsed: false, hydrationPolicy: .automatic
            )
        }
        // WA carries TWO project zones. Za is active; Zb is the one the old
        // single-spawner path could not reach.
        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneZa, project: projectPa, x: 0, color: "blue"),
                    placement(zoneZb, project: projectPb, x: 560, color: "green")],
            zoneZOrder: [zoneZa, zoneZb],
            lastActiveZoneId: zoneZa
        )
        let docB = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneZc, project: projectPc, x: 0, color: "red")],
            zoneZOrder: [zoneZc],
            lastActiveZoneId: zoneZc
        )
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceWB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: pa.root.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pb.root.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPc, name: "Pc", rootPath: pc.root.path, workspaceId: workspaceWB,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let ghostty = try GhosttyRuntimeContext()

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            switch projectId {
            case projectPa: return ZoneRuntimeController(projectRoot: pa.root, projectStore: pa.store, project: pa.project)
            case projectPb: return ZoneRuntimeController(projectRoot: pb.root, projectStore: pb.store, project: pb.project)
            case projectPc: return ZoneRuntimeController(projectRoot: pc.root, projectStore: pc.store, project: pc.project)
            default: throw Failure(message: "unexpected projectId in factory: \(projectId)")
            }
        })

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: ghostty,
            browserEngine: browserEngine
        )
        // The seams M1.3b added, exercised for real: with these the spawner tmux
        // path is injectable, which is what makes the switch path testable at all.
        let suiteName = "continuum.zone-spawner-coverage.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        isolatedDefaults.set(false, forKey: TmuxPersistenceConfig.enabledKey)
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        runtime.spawnerDefaults = isolatedDefaults
        runtime.spawnerTmuxPathResolver = { _ in nil }

        delegate.qaPrepareForOfflineSceneCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime
        )

        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.installedZoneLayerIds.contains(zoneZa) && canvas.installedZoneLayerIds.contains(zoneZb),
                   "precondition: both of WA's zones must be live; installed: \(canvas.installedZoneLayerIds)")

        guard let controllerA = runtime.controller(for: projectPa),
              let controllerB = runtime.controller(for: projectPb) else {
            throw Failure(message: "precondition: both of WA's projects must have live controllers")
        }
        try expect(controllerA !== controllerB, "precondition: the two zones must be different projects")

        // The active zone was never broken — assert it so a failure below is
        // unambiguously about coverage rather than about hydration as a whole.
        try expect(canvas.tileView(for: terminalTa) is TerminalTileNSView,
                   "precondition: the ACTIVE zone's terminal must hydrate; got \(describe(canvas.tileView(for: terminalTa)))")

        // The witness.
        try expect(!(canvas.tileView(for: terminalTb) is DescriptorTileNSView),
                   "install: the NON-ACTIVE zone's terminal must hydrate to a live tile, not a "
                   + "DescriptorTileNSView placeholder; got \(describe(canvas.tileView(for: terminalTb)))")
        try expect(canvas.tileView(for: terminalTb) is TerminalTileNSView,
                   "install: Zb's terminal must be a TerminalTileNSView; got \(describe(canvas.tileView(for: terminalTb)))")
        try expect(controllerB.runtimes.contains { $0.tileId == terminalTb },
                   "install: Zb's controller must own the runtime it just built")

        // The subset contract. `attachSpawner` gives a non-active controller a
        // factory and nothing else; the observer and the tmux reaper stay with the
        // active zone. Calling `attachUI` on everything would satisfy every
        // assertion above and start N tmux reapers on one server.
        try expect(controllerB.tileSpawner != nil,
                   "install: Zb's controller must have a spawner")
        try expect(controllerA.qaHoldsProcessWideAttachments,
                   "install: the ACTIVE controller must still take the session observer and reaper")
        try expect(!controllerB.qaHoldsProcessWideAttachments,
                   "install: a NON-ACTIVE controller must not start a session observer or a tmux "
                   + "reaper — those are process-wide and belong to exactly one zone")

        // === The switch path, which is where this actually bites: `openDocument`
        // calls `switchWorkspace` itself, so one cross-workspace link click lands
        // here. ===
        try runtime.switchWorkspace(to: workspaceWB)
        canvas.layoutSubtreeIfNeeded()
        try runtime.switchWorkspace(to: workspaceWA)
        canvas.layoutSubtreeIfNeeded()

        guard let controllerA2 = runtime.controller(for: projectPa),
              let controllerB2 = runtime.controller(for: projectPb) else {
            throw Failure(message: "switch: both of WA's projects must be live again after the round trip")
        }

        try expect(canvas.tileView(for: terminalTa) is TerminalTileNSView,
                   "switch: the active zone's terminal must hydrate after a round trip; got "
                   + "\(describe(canvas.tileView(for: terminalTa)))")
        try expect(canvas.tileView(for: terminalTb) is TerminalTileNSView,
                   "switch: the NON-ACTIVE zone's terminal must hydrate after a round trip, not stay "
                   + "a placeholder; got \(describe(canvas.tileView(for: terminalTb)))")
        try expect(controllerB2.runtimes.filter { $0.tileId == terminalTb }.count == 1,
                   "switch: Zb's terminal must have exactly one runtime after the round trip; got "
                   + "\(controllerB2.runtimes.filter { $0.tileId == terminalTb }.count)")
        try expect(controllerA2.qaHoldsProcessWideAttachments && !controllerB2.qaHoldsProcessWideAttachments,
                   "switch: the observer/reaper must still sit with the active zone alone "
                   + "(active=\(controllerA2.qaHoldsProcessWideAttachments), "
                   + "other=\(controllerB2.qaHoldsProcessWideAttachments))")

        print("ZoneSpawnerCoverageChecks: both zones of a two-project workspace hydrate their "
              + "terminals across install and a switch round trip, with the observer and reaper "
              + "still held by the active zone alone")
    }
}
