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
        let webViewsAfterInstall = browserEngine.webViewCreationCountForQA

        // === ACT 1: switch to WB. Same project, different zone. ===
        try runtime.switchWorkspace(to: workspaceWB)
        canvas.layoutSubtreeIfNeeded()

        try expect(controllerBox.creations == 1,
                   "act1: the shared project's controller must SURVIVE the switch — the whole "
                   + "hazard depends on it. The factory ran \(controllerBox.creations) time(s), so "
                   + "the controller was released and rebuilt and this fixture proves nothing.")
        try expect(runtime.controller(for: projectPs) === controller,
                   "act1: the surviving controller must be the same instance")
        try expect(terminalRuntimeCount(terminalT2) == 1,
                   "act1: zone Z2's terminal T2 must hydrate to exactly one runtime; "
                   + "got \(terminalRuntimeCount(terminalT2))")

        // === ACT 2: switch back to WA. Z1's layer is rebuilt from scratch while
        // the controller still holds T1's and B1's runtimes. ===
        try runtime.switchWorkspace(to: workspaceWA)
        canvas.layoutSubtreeIfNeeded()

        try expect(controllerBox.creations == 1,
                   "act2: the controller must still be the original; the factory ran "
                   + "\(controllerBox.creations) time(s)")

        try expect(terminalRuntimeCount(terminalT1) == 1,
                   "act2: terminal T1 must still have exactly ONE runtime after a round trip; got "
                   + "\(terminalRuntimeCount(terminalT1)). A second GhosttyTerminalRuntime re-binds "
                   + "to the same persisted tmux pane, which is two Ghostty surfaces on one pty.")
        try expect(browserRuntimeCount(browserB1) == 1,
                   "act2: browser B1 must still have exactly ONE runtime after a round trip; got "
                   + "\(browserRuntimeCount(browserB1)). A duplicate is a leaked WKWebView content "
                   + "process.")

        // Independent of the controller's own bookkeeping: the engine counts every
        // web view it has ever built. One round trip through B1's zone may build
        // ONE replacement, never two.
        try expect(browserEngine.webViewCreationCountForQA == webViewsAfterInstall + 1,
                   "act2: re-entering B1's zone must build exactly one replacement web view; the "
                   + "engine went from \(webViewsAfterInstall) to "
                   + "\(browserEngine.webViewCreationCountForQA)")

        // Retiring must not degrade into skipping: the tile has to come back LIVE.
        // A guard that keeps the count at one by leaving a placeholder would trade
        // this defect for the one M1.2 just fixed, and would pass every assertion
        // above.
        try expect(!(canvas.tileView(for: terminalT1) is DescriptorTileNSView),
                   "act2: T1 must come back as a live terminal tile, not a placeholder; got "
                   + "\(String(describing: canvas.tileView(for: terminalT1).map { type(of: $0) }))")
        try expect(canvas.tileView(for: browserB1) is BrowserTileNSView,
                   "act2: B1 must come back as a live browser tile; got "
                   + "\(String(describing: canvas.tileView(for: browserB1).map { type(of: $0) }))")

        // === ACT 3: do it again. The per-tile counts above are satisfied by any
        // fixed number of runtimes; only repetition distinguishes "one each" from
        // "leaking one per switch". Totals, not per-tile filters, so a runtime
        // accumulating under ANY tile id shows up.
        //
        // Note what this deliberately does NOT assert. The controller still holds
        // T2's runtime, whose zone is no longer installed and whose host view
        // `setZones` destroyed — an orphan. That is the same class of leak as the
        // missing `ManagedAgentTileNSView.detach()` sweep and belongs to M1.4, so
        // this leg pins the count as STABLE rather than pretending it is already
        // cleaned up. If M1.4 sweeps it, these two numbers drop and this assertion
        // is the thing that will say so.
        let terminalsAfterFirstTrip = controller.runtimes.count
        let browsersAfterFirstTrip = controller.browserRuntimes.count
        let webViewsAfterFirstTrip = browserEngine.webViewCreationCountForQA

        try runtime.switchWorkspace(to: workspaceWB)
        canvas.layoutSubtreeIfNeeded()
        try runtime.switchWorkspace(to: workspaceWA)
        canvas.layoutSubtreeIfNeeded()

        try expect(controllerBox.creations == 1,
                   "act3: the controller must still be the original; the factory ran "
                   + "\(controllerBox.creations) time(s)")
        try expect(terminalRuntimeCount(terminalT1) == 1,
                   "act3: T1 must still have exactly one runtime after a second round trip; got "
                   + "\(terminalRuntimeCount(terminalT1))")
        try expect(browserRuntimeCount(browserB1) == 1,
                   "act3: B1 must still have exactly one runtime after a second round trip; got "
                   + "\(browserRuntimeCount(browserB1))")
        try expect(controller.runtimes.count == terminalsAfterFirstTrip,
                   "act3: terminal runtimes must not accumulate across round trips — "
                   + "\(terminalsAfterFirstTrip) after the first, "
                   + "\(controller.runtimes.count) after the second: "
                   + "\(controller.runtimes.map { String($0.tileId.uuidString.suffix(4)) })")
        try expect(controller.browserRuntimes.count == browsersAfterFirstTrip,
                   "act3: browser runtimes must not accumulate across round trips — "
                   + "\(browsersAfterFirstTrip) after the first, "
                   + "\(controller.browserRuntimes.count) after the second")
        try expect(browserEngine.webViewCreationCountForQA == webViewsAfterFirstTrip + 1,
                   "act3: a second round trip must build exactly one more web view; the engine "
                   + "went from \(webViewsAfterFirstTrip) to "
                   + "\(browserEngine.webViewCreationCountForQA)")

        print("ZoneRuntimeDuplicationChecks: a shared project survived two workspace round trips "
              + "with exactly one terminal runtime and one browser runtime per tile, live views "
              + "for both, and no accumulation")
    }

    /// Counts controller constructions so the leg can prove its own premise: if
    /// the controller were released and rebuilt, `runtimes` would start empty and
    /// every duplication assertion below would pass for the wrong reason.
    private final class ControllerBox {
        var creations = 0
    }
}
