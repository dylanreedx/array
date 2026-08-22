import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.1 (`.plans/46`) — a workspace switch must leave REAL tile views behind.
///
/// `WorkspaceRuntime` builds every ZoneLayer's tile views as
/// `DescriptorTileNSView` placeholders — `switchWorkspace` (:680-684),
/// `_addProjectZone` (:361-365) and `makeAmbientZoneLayer` (:393-396), with only
/// `install` (:229-234) carrying the "real hydration is T08" comment. Real views
/// are built ONLY by the `installInitial*` boot walk
/// (`ContinuumApp.swift:4051-4076`), which runs once at
/// `applicationDidFinishLaunching`. So after the first in-process workspace
/// switch every tile is a title-label placeholder: no transcript, no composer,
/// nothing to click. `openDocument` calls `switchWorkspace` itself
/// (`WorkspaceRuntime.swift:486-500`), so following one cross-workspace link can
/// be what kills the tiles the next link lived in.
///
/// **Why this leg exists when three green ones already cover the switch.**
/// `--workspace-switch-check`, `--workspace-runtime-install-check` and
/// `--zone-hydration-lifecycle-check` all pass today. They assert zone identity,
/// ref-counts, focus and viewport — never the CLASS of the resulting view. This
/// is the program's recurring failure: a witness that drives the real path while
/// being blind on the one axis where the defect lives.
///
/// **It drives production wiring, not its own.** The harness builds a real
/// `AppDelegate` and calls `configureWorkspaceRuntimeHooks()` — the same method
/// `applicationDidFinishLaunching` calls — so a hydrator added there is exercised
/// here. Substituting a local closure is exactly how
/// `--agent-local-file-link-check` came to cover a path production never runs.
///
/// RED before M1.2: every assertion of the form "must not be a placeholder"
/// fails. The preceding resolve assertions must PASS, which is what proves it
/// fails for the real reason — a placeholder, not a nil lookup.
@MainActor
enum ZoneTileHydrationChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    /// Names the concrete class so a failure says what it actually got.
    private static func describe(_ view: TileNSView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    static func run() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1101")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1102")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000A1103")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000A1104")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1105")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1106")!
        let noteTileA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1107")!
        let noteTileB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1108")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-hydration-\(UUID().uuidString)", isDirectory: true)
        let paRoot = tempRoot.appendingPathComponent("Pa", isDirectory: true)
        let pbRoot = tempRoot.appendingPathComponent("Pb", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: paRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pbRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        func makeProject(id: UUID, name: String, root: URL) -> Project {
            Project(
                id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
        }
        func makeCanvas(tileId: UUID) -> CanvasState {
            CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [Tile(
                    id: tileId, kind: .note, title: "note",
                    frame: TileFrame(x: 10, y: 10, width: 220, height: 140),
                    zPosition: .fromLegacyRank(1), runtimeRef: nil,
                    metadata: TileMetadata(noteId: tileId)
                )],
                groups: [],
                lastActiveTileId: tileId
            )
        }

        let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
        let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)
        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(makeCanvas(tileId: noteTileA))
        try storePb.saveProject(projectPbObj)
        try storePb.saveCanvas(makeCanvas(tileId: noteTileB))

        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: zoneA, projectId: projectPa,
                origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 640, height: 480),
                color: "blue", collapsed: false, hydrationPolicy: .automatic
            )],
            zoneZOrder: [zoneA],
            lastActiveZoneId: zoneA
        )
        let docB = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: zoneB, projectId: projectPb,
                origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 640, height: 480),
                color: "red", collapsed: false, hydrationPolicy: .automatic
            )],
            zoneZOrder: [zoneB],
            lastActiveZoneId: zoneB
        )
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceWB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWB,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa {
                return ZoneRuntimeController(projectRoot: paRoot, projectStore: storePa, project: projectPaObj)
            }
            if projectId == projectPb {
                return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storePb, project: projectPbObj)
            }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        // A real AppDelegate, wired the way production wires it. `ghostty: nil`
        // is why this fixture uses note tiles: a terminal tile cannot hydrate
        // headlessly (`TileSpawner.restartTerminalTile` guards on it).
        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        // Calls the production `configureWorkspaceRuntimeHooks()`. A hydrator
        // added there is exercised by this leg without the leg knowing about it.
        delegate.qaPrepareForOfflineSceneCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime
        )

        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()

        // === ACT 1: switch A -> B. B's tiles must be real. ===
        try runtime.switchWorkspace(to: workspaceWB)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.installedZoneLayerIds.contains(zoneB),
                   "act1: zoneB must be installed after switching to WB")

        let viewB = canvas.tileView(for: noteTileB)
        // Resolve first. If THIS fails the leg is reporting a lookup problem, not
        // the hydration defect — the distinction the whole leg turns on.
        try expect(viewB != nil,
                   "act1: tileView(for: noteTileB) must resolve after the switch — got nil, "
                   + "which means this leg is failing for a lookup reason, not the hydration defect")
        try expect(!(viewB is DescriptorTileNSView),
                   "act1: noteTileB must be a live tile after switching to WB, not a "
                   + "DescriptorTileNSView placeholder; got \(describe(viewB))")
        try expect(viewB is NoteTileNSView,
                   "act1: noteTileB must be a NoteTileNSView; got \(describe(viewB))")

        // === ACT 2: switch back to A. A's tiles must be real too. ===
        try runtime.switchWorkspace(to: workspaceWA)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.installedZoneLayerIds.contains(zoneA),
                   "act2: zoneA must be installed after switching back to WA")

        let viewA = canvas.tileView(for: noteTileA)
        try expect(viewA != nil,
                   "act2: tileView(for: noteTileA) must resolve after switching back — got nil, "
                   + "which means this leg is failing for a lookup reason, not the hydration defect")
        try expect(!(viewA is DescriptorTileNSView),
                   "act2: noteTileA must be a live tile after switching back to WA, not a "
                   + "DescriptorTileNSView placeholder; got \(describe(viewA))")
        try expect(viewA is NoteTileNSView,
                   "act2: noteTileA must be a NoteTileNSView; got \(describe(viewA))")

        // The departed workspace's tile must not linger as a live view.
        try expect(canvas.tileView(for: noteTileB) == nil,
                   "act2: noteTileB must not still resolve after switching away from WB; "
                   + "got \(describe(canvas.tileView(for: noteTileB)))")

        print("ZoneTileHydrationChecks: 2 workspace switches, every installed tile hydrated to a live view")
    }
}
