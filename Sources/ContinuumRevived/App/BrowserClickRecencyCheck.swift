import AppKit
import ContinuumRevivedCore
import Foundation

extension AppDelegate {
    /// `--browser-click-recency-check`: clicking a browser that lives in a zone
    /// layer counts as use. The click path used to look the tile up in the flat
    /// `canvasState.tiles`, which (hazard 9) holds the DEPARTED project's tiles
    /// once zones are installed — so the browser being used kept its oldest slot
    /// and was the first one frozen when another browser opened.
    @MainActor
    static func runBrowserClickRecencySelfCheck() throws -> URL {
        struct CheckError: Error, CustomStringConvertible { let description: String }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-browser-click-recency-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let project = Project(
            id: UUID(), name: "browser-click-recency", rootPath: root.path,
            createdAt: Date(), updatedAt: Date(), defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: root)
        try store.saveProject(project)

        let ids = (0..<3).map { _ in UUID() }
        let tiles = ids.enumerated().map { index, id in
            Tile(id: id, kind: .browser, title: "browser \(index)",
                 frame: TileFrame(x: Double(index) * 660, y: 0, width: 640, height: 420),
                 zPosition: .fromLegacyRank(index), runtimeRef: nil,
                 metadata: TileMetadata(url: "about:blank"))
        }
        // The flat model holds nothing of this project: the tiles live in a layer.
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let placement = ZonePlacement(zoneId: UUID(), projectId: project.id, origin: ZonePoint(x: 0, y: 0),
                                      size: ZoneSize(width: 2_000, height: 600), color: "blue", collapsed: false,
                                      hydrationPolicy: .automatic)
        canvas.upsertZoneLayer(CanvasNSView.ZoneLayer(
            placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Z"),
            tiles: tiles))

        let delegate = AppDelegate()
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        delegate.canvasView = canvas
        let controller = ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        let registry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { _ in
            throw NSError(domain: "WorkspaceRuntime", code: 1, userInfo: nil)
        })
        let runtime = WorkspaceRuntime(
            boot: controller, registry: registry, focusBroker: delegate.focusBroker,
            registryStore: RegistryStore(applicationSupportDirectory: root),
            ghostty: nil, browserEngine: browserEngine)
        delegate.qaAdoptWorkspaceRuntime(runtime)
        runtime.qaSetBrowserRuntimeMaxLive(2)

        // Opened in order 0, 1, 2; the user then clicks browser 0.
        ids.forEach { runtime.registerLiveBrowser(tileId: $0) }
        delegate.noteBrowserUse(ids[0])
        let evicted = runtime.qaBrowserEvictionCandidates(liveTileIds: ids)
        guard evicted == [ids[1]] else {
            throw CheckError(description: "a third browser must evict the least recently USED one (browser 1); evicted \(evicted.map { ids.firstIndex(of: $0) ?? -1 }) — the clicked browser 0 kept its oldest slot")
        }

        let artifact = root.deletingLastPathComponent().appendingPathComponent("browser-click-recency-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["check": "browser-click-recency", "evicted": "browser 1"])
            .write(to: artifact, options: .atomic)
        return artifact
    }
}
