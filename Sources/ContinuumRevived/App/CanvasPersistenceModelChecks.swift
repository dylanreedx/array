import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.0 (`.plans/46`) — a project's canvas file must only ever receive that
/// project's tiles.
///
/// The canvas has two models. At boot the flat `canvasState.tiles` owns the
/// active project; once `setZones` has run, a `ZoneLayer` does. A workspace
/// switch moves ownership but **never updates the flat model**:
/// `retireFlatCompatibilityScene` (`CanvasNSView.swift:5051-5066`) clears
/// `tileViews`, `tileZoneMembership` and `lastActiveTileId`, and deliberately
/// leaves `canvasState.tiles` alone — so it goes on holding the DEPARTED
/// project's tiles for the rest of the session. The repo already half-knows:
/// `ContinuumApp.swift:15146` carries
/// `// NEEDS-HUMAN: canvasState.tiles is NOT populated by setZones (shape-B gap)`.
///
/// Persistence never got the memo. `canvasDidChange`
/// (`ContinuumApp.swift:13698-13699`) schedules a save on the *newly active*
/// controller, and `flushCanvasSave` / `flushCanvasSaveOffMain`
/// (`ZoneRuntimeController.swift:664-676` and `:619-630`) write
/// `canvasView.canvasState` verbatim into **their own** `projectStore`. So the
/// first canvas change after a switch persists project A's tile list into
/// project B's `canvas.json`.
///
/// That is unrecoverable in a way the placeholder defect (M1.1/M1.2) is not: a
/// dead tile comes back on relaunch, an overwritten `canvas.json` does not. It
/// is the in-process form of hazard 10 — the failure that took a real canvas
/// from nine tiles to one.
///
/// **This leg drives the production entry point**, `AppDelegate.canvasDidChange`,
/// not a hand-rolled save. A witness that called `saveCanvas` itself would prove
/// only that `saveCanvas` writes what it is handed.
///
/// RED before the fix: `pb-leak` fails, naming the foreign tile it found. The
/// `pa-baseline` and `pb-precondition` assertions before it must PASS — they are
/// what prove the leg failed for the real reason and not a broken fixture.
@MainActor
enum CanvasPersistenceModelChecks {
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

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000C0001")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-0000000C0002")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000C0003")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000C0004")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000C0005")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000C0006")!

        // Pa is deliberately the bigger canvas: a leak then shows up as B's file
        // GAINING tiles, which is unambiguous.
        let paTiles = [
            UUID(uuidString: "00000000-0000-0000-0000-0000000C0A01")!,
            UUID(uuidString: "00000000-0000-0000-0000-0000000C0A02")!,
            UUID(uuidString: "00000000-0000-0000-0000-0000000C0A03")!
        ]
        let pbTile = UUID(uuidString: "00000000-0000-0000-0000-0000000C0B01")!
        // Pa also owns two tiles in a zone this fixture NEVER installs -- the shape
        // of a project that appears in a second workspace, or in a zone held below
        // the live hydration tier. Persisting Pa must not disturb them.
        let zoneOther = UUID(uuidString: "00000000-0000-0000-0000-0000000C0007")!
        let paOtherTiles = [
            UUID(uuidString: "00000000-0000-0000-0000-0000000C0A04")!,
            UUID(uuidString: "00000000-0000-0000-0000-0000000C0A05")!
        ]

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-canvas-persistence-\(UUID().uuidString)", isDirectory: true)
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
        func makeCanvas(_ specs: [(id: UUID, zoneId: UUID?)]) -> CanvasState {
            CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: specs.enumerated().map { index, spec in
                    var tile = Tile(
                        id: spec.id, kind: .note, title: "note-\(index)",
                        frame: TileFrame(x: Double(10 + index * 40), y: 10, width: 220, height: 140),
                        zPosition: .fromLegacyRank(index + 1), runtimeRef: nil,
                        metadata: TileMetadata(noteId: spec.id)
                    )
                    tile.zoneId = spec.zoneId
                    return tile
                },
                groups: [],
                lastActiveTileId: specs.first?.id
            )
        }
        let paCanvas = makeCanvas(
            paTiles.map { (id: $0, zoneId: Optional(zoneA)) }
                + paOtherTiles.map { (id: $0, zoneId: Optional(zoneOther)) }
        )
        let paAllTiles = paTiles + paOtherTiles

        let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
        let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)
        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(paCanvas)
        try storePb.saveProject(projectPbObj)
        try storePb.saveCanvas(makeCanvas([(id: pbTile, zoneId: zoneB)]))

        func makeDocument(zoneId: UUID, projectId: UUID, color: String) -> WorkspaceDocument {
            WorkspaceDocument(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                zones: [ZonePlacement(
                    zoneId: zoneId, projectId: projectId,
                    origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 640, height: 480),
                    color: color, collapsed: false, hydrationPolicy: .automatic
                )],
                zoneZOrder: [zoneId],
                lastActiveZoneId: zoneId
            )
        }
        let docA = makeDocument(zoneId: zoneA, projectId: projectPa, color: "blue")
        let docB = makeDocument(zoneId: zoneB, projectId: projectPb, color: "red")
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
            canvasState: paCanvas,
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
            ghostty: nil,
            browserEngine: browserEngine
        )
        delegate.qaPrepareForOfflineSceneCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime
        )

        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()

        // Baseline: the fixture is what we think it is BEFORE anything moves.
        let paBefore = ((try? storePa.tryLoadCanvas()) ?? nil)?.tiles.map(\.id) ?? []
        try expect(Set(paBefore) == Set(paAllTiles),
                   "pa-baseline: Pa's canvas must start with its own 5 tiles (3 in zoneA, 2 in the "
                   + "never-installed zone); got \(paBefore.count)")

        // === Switch to WB. Pb is now the active project. ===
        try runtime.switchWorkspace(to: workspaceWB)
        canvas.layoutSubtreeIfNeeded()

        try expect(runtime.activeController?.project.id == projectPb,
                   "pb-precondition: Pb must be the active controller after the switch; got "
                   + "\(String(describing: runtime.activeController?.project.name))")

        // === The gesture: any canvas change at all. A pan is enough. ===
        // This is the REAL delegate method the canvas calls; it is what routes a
        // change to `activeController.scheduleCanvasSave()`.
        delegate.canvasDidChange(canvas)
        // Force the 200 ms debounce to land now, through the production flush.
        runtime.activeController?.flushCanvasSave()

        // === Pb's file must still be Pb's. ===
        let pbAfter = ((try? storePb.tryLoadCanvas()) ?? nil)?.tiles ?? []
        let pbAfterIds = Set(pbAfter.map(\.id))
        let leaked = pbAfterIds.intersection(Set(paAllTiles))
        try expect(leaked.isEmpty,
                   "pb-leak: Pb's canvas.json must never contain Pa's tiles, but a canvas change "
                   + "after the switch wrote \(leaked.count) of them into it "
                   + "(\(leaked.sorted(by: { $0.uuidString < $1.uuidString }).map(\.uuidString).joined(separator: ", "))). "
                   + "The flat canvasState still holds the departed project's tiles and "
                   + "flushCanvasSave persists it into whichever project is now active.")
        try expect(pbAfterIds == Set([pbTile]),
                   "pb-identity: Pb's canvas must still be exactly its own 1 tile; got "
                   + "\(pbAfterIds.count) tiles")

        // And the departed project must not have been emptied on the way out.
        let paAfter = ((try? storePa.tryLoadCanvas()) ?? nil)?.tiles.map(\.id) ?? []
        try expect(Set(paAfter) == Set(paAllTiles),
                   "pa-survives: Pa's canvas must still hold all 5 of its tiles after switching away; "
                   + "got \(paAfter.count)")

        // === ACT 3: back to WA, then persist Pa. The never-installed zone's tiles
        // must survive. This is the merged M1.5: `tiles(forProjectId:)` reads
        // INSTALLED layers only, so replacing the file with it erased every tile in
        // a zone below the live tier. Only a zone that is installed may delete. ===
        try runtime.switchWorkspace(to: workspaceWA)
        canvas.layoutSubtreeIfNeeded()

        try expect(runtime.activeController?.project.id == projectPa,
                   "act3-precondition: Pa must be active again after switching back")
        let installedForPa = canvas.installedZoneIds(forProjectId: projectPa)
        try expect(installedForPa == Set([zoneA]),
                   "act3-precondition: exactly zoneA must be installed for Pa, so zoneOther is the "
                   + "un-installed zone under test; got \(installedForPa.count) zone(s)")

        delegate.canvasDidChange(canvas)
        runtime.activeController?.flushCanvasSave()

        let paFinal = ((try? storePa.tryLoadCanvas()) ?? nil)?.tiles ?? []
        let paFinalIds = Set(paFinal.map(\.id))
        let truncated = Set(paOtherTiles).subtracting(paFinalIds)
        try expect(truncated.isEmpty,
                   "pa-truncation: persisting Pa dropped \(truncated.count) tile(s) that live in a zone "
                   + "no layer has installed "
                   + "(\(truncated.sorted(by: { $0.uuidString < $1.uuidString }).map(\.uuidString).joined(separator: ", "))). "
                   + "Persistence read installed layers only and replaced the file with them.")
        try expect(paFinalIds == Set(paAllTiles),
                   "pa-final: Pa's canvas must still be exactly its own 5 tiles; got \(paFinalIds.count)")

        print("CanvasPersistenceModelChecks: a switch persisted only the active project's tiles, and a "
              + "project's un-installed zone survived the write")
    }
}
