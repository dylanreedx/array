import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.3 (`.plans/46`) — hydrating a zone must never mint a SECOND runtime for a
/// tile whose controller already owns one.
///
/// `TileSpawner.restartTerminalTile` (`:562`) never inspects `existing.runtimeRef`
/// and never consults `controller.runtimes` — a plain `[GhosttyTerminalRuntime]`
/// array (`ZoneRuntimeController.swift:17`) with no uniqueness invariant. It
/// always mints `GhosttyTerminalRuntime(id: UUID(), …)` and re-binds to the
/// persisted tmux pane when one is still alive (`tmuxWrappedProfileIfAvailable`),
/// so calling it twice for a live tile puts **two Ghostty surfaces on one pty**.
/// `restartBrowserTile` (`:1036`) is the same shape for `WKWebViewBrowserRuntime`,
/// and a leaked web view is a whole content process.
///
/// **This leg guards new code, not an old defect — and that is worth stating
/// plainly rather than dressing up.** Before M1.2 a workspace switch rebuilt every
/// tile as a `DescriptorTileNSView` and therefore created *zero* runtimes: there
/// was nothing to duplicate. M1.2's Phase B is what creates the hazard, so this
/// witness could not be RED first. It is a regression guard, which is a weaker
/// thing than the RED-first witnesses elsewhere in this milestone. Its teeth were
/// confirmed the only way available: by temporarily removing the two skips in
/// `AppDelegate.hydrateRuntimeBackedTiles` and watching it fail.
///
/// **The fixture's shape is the production case, not a contrivance.** A controller
/// only survives a switch when its project is *shared* between the two workspaces,
/// and `switchWorkspace` is explicitly written for that — "Build new ZoneLayers for
/// the target workspace before releasing (so shared controllers stay alive)"
/// (`WorkspaceRuntime.swift:668`), with `arriving` deliberately excluding projects
/// that already hold a ref-count. So: one project, one zone per workspace, and a
/// round trip. On the way back the controller still holds the first zone's
/// runtimes while the layer is rebuilt from scratch.
///
/// **Naming.** The flag must NOT start with `--terminal-tmux-`: `run-matrix.sh`
/// injects `-continuum.terminal.tmux.enabled NO` into the argument domain for
/// every flag *except* that prefix, and this leg drives the real
/// `attachActiveControllerUI`, whose spawner takes `UserDefaults.standard` and a
/// real `ProcessTmuxControl` (threading those is M1.3b). The argument-domain
/// default is the only in-process guard until then; the matrix's own
/// `TMUX_TMPDIR` isolation is the backstop, not the plan.
@MainActor
enum ZoneRuntimeDuplicationChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1301")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1302")!
        let projectPs = UUID(uuidString: "00000000-0000-0000-0000-0000000A1303")!
        let zoneZ1 = UUID(uuidString: "00000000-0000-0000-0000-0000000A1304")!
        let zoneZ2 = UUID(uuidString: "00000000-0000-0000-0000-0000000A1305")!
        let terminalT1 = UUID(uuidString: "00000000-0000-0000-0000-0000000A1306")!
        let browserB1 = UUID(uuidString: "00000000-0000-0000-0000-0000000A1307")!
        let terminalT2 = UUID(uuidString: "00000000-0000-0000-0000-0000000A1308")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-runtime-dup-\(UUID().uuidString)", isDirectory: true)
        let psRoot = tempRoot.appendingPathComponent("Ps", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: psRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let project = Project(
            id: projectPs, name: "Ps", rootPath: psRoot.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )

        // Tiles carry EXPLICIT zone ids. Sharing one project across two workspaces
        // means each zone owns its own tiles; leaving zoneId nil would make
        // membership depend on `firstZoneByProject`, which flips with the document
        // being loaded and would silently change what the fixture is testing.
        func terminalTile(_ id: UUID, zone: UUID, x: CGFloat) -> Tile {
            var tile = Tile(
                id: id, kind: .terminal, title: "term",
                frame: TileFrame(x: Double(x), y: 10, width: 320, height: 220),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "shell")
            )
            tile.zoneId = zone
            return tile
        }
        var browserTile = Tile(
            id: browserB1, kind: .browser, title: "browser",
            frame: TileFrame(x: 360, y: 10, width: 320, height: 220),
            zPosition: .fromLegacyRank(2), runtimeRef: nil,
            metadata: TileMetadata(url: "about:blank")
        )
        browserTile.zoneId = zoneZ1

        let store = ProjectStore(projectRoot: psRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [terminalTile(terminalT1, zone: zoneZ1, x: 10),
                    browserTile,
                    terminalTile(terminalT2, zone: zoneZ2, x: 700)],
            groups: [],
            lastActiveTileId: terminalT1
        ))


        func document(zone: UUID, color: String) -> WorkspaceDocument {
            WorkspaceDocument(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                zones: [ZonePlacement(
                    zoneId: zone, projectId: projectPs,
                    origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 900, height: 600),
                    color: color, collapsed: false, hydrationPolicy: .automatic
                )],
                zoneZOrder: [zone],
                lastActiveZoneId: zone
            )
        }
        let docA = document(zone: zoneZ1, color: "blue")
        let docB = document(zone: zoneZ2, color: "red")
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceWB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.projects = [
            ProjectEntry(id: projectPs, name: "Ps", rootPath: psRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        // A real Ghostty context. `GhosttyRuntimeContext()` needs no display and
        // `GhosttyTerminalRuntime.init` spawns no process — only `attach(to:)`
        // does — so a headless leg can build real runtimes and count them. This
        // corrects the claim in `ZoneTileHydrationChecks` that a terminal tile
        // cannot hydrate headlessly: that was a property of that fixture's
        // `ghostty: nil`, not of the platform.
        let ghostty = try GhosttyRuntimeContext()

        let controllerBox = ControllerBox()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            guard projectId == projectPs else {
                throw Failure(message: "unexpected projectId in factory: \(projectId)")
            }
            controllerBox.creations += 1
            return ZoneRuntimeController(projectRoot: psRoot, projectStore: store, project: project)
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
        delegate.qaPrepareForOfflineSceneCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime
        )

        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()

        guard let controller = runtime.controller(for: projectPs) else {
            throw Failure(message: "precondition: project Ps must have a live controller after install")
        }

        func terminalRuntimeCount(_ tileId: UUID) -> Int {
            controller.runtimes.filter { $0.tileId == tileId }.count
        }
        func browserRuntimeCount(_ tileId: UUID) -> Int {
            controller.browserRuntimes.filter { $0.tileId == tileId }.count
        }

        // Precondition. If Phase B did not build these, the leg would pass
        // vacuously — the exact way a duplication guard can look green while
        // guarding nothing.
        try expect(terminalRuntimeCount(terminalT1) == 1,
                   "precondition: hydrating zone Z1 must give terminal T1 exactly one runtime; "
                   + "got \(terminalRuntimeCount(terminalT1)). A count of 0 means Phase B never ran, "
                   + "so the duplication assertions below would be vacuous.")
        try expect(browserRuntimeCount(browserB1) == 1,
                   "precondition: hydrating zone Z1 must give browser B1 exactly one runtime; "
                   + "got \(browserRuntimeCount(browserB1))")
        let webViewsBeforeRejectedSwitch = browserEngine.webViewCreationCountForQA
        let bytesABefore = try Data(contentsOf: WorkspaceStore(
            workspaceId: workspaceWA, applicationSupportDirectory: appSupport).layout.canvasFile)
        let bytesBBefore = try Data(contentsOf: WorkspaceStore(
            workspaceId: workspaceWB, applicationSupportDirectory: appSupport).layout.canvasFile)

        // A project is now exclusively workspace-owned. The legacy shared-project
        // shape must stop before scene teardown, controller duplication, or file
        // repair; an explicit project move is the only transfer operation.
        do {
            try runtime.switchWorkspace(to: workspaceWB)
            throw Failure(message: "a project-owned-by-A document was silently mounted as workspace B")
        } catch is ProjectWorkspaceOwnershipError {
            // expected
        }
        try expect(runtime.workspaceId == workspaceWA,
                   "ownership rejection changed the runtime's mounted workspace")
        try expect(canvas.installedZoneLayerIds == [zoneZ1],
                   "ownership rejection tore down or replaced the A scene")
        try expect(runtime.controller(for: projectPs) === controller,
                   "ownership rejection replaced the live project controller")
        try expect(terminalRuntimeCount(terminalT1) == 1 && browserRuntimeCount(browserB1) == 1,
                   "ownership rejection duplicated or removed a live runtime")
        try expect(browserEngine.webViewCreationCountForQA == webViewsBeforeRejectedSwitch,
                   "ownership rejection created a replacement browser runtime")
        let bytesAAfter = try Data(contentsOf: WorkspaceStore(
            workspaceId: workspaceWA, applicationSupportDirectory: appSupport).layout.canvasFile)
        let bytesBAfter = try Data(contentsOf: WorkspaceStore(
            workspaceId: workspaceWB, applicationSupportDirectory: appSupport).layout.canvasFile)
        try expect(bytesAAfter == bytesABefore && bytesBAfter == bytesBBefore,
                   "ownership rejection modified a workspace document")

        print("ZoneRuntimeDuplicationChecks: legacy shared-project membership was rejected before "
              + "scene teardown, file writes, or runtime duplication")
    }

    /// Counts controller constructions so the leg can prove its own premise: if
    /// the controller were released and rebuilt, `runtimes` would start empty and
    /// every duplication assertion below would pass for the wrong reason.
    private final class ControllerBox {
        var creations = 0
    }
}
