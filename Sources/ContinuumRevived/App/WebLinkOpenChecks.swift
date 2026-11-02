import AppKit
import ContinuumRevivedCore
import Foundation

/// `--web-link-open-check`. With Array chosen as the default browser, a link
/// from another app arrives as a `GURL` Apple Event that AppKit hands to
/// `NSApp.delegate`'s `application(_:open:)`. This leg makes that call and
/// expects a new browser tile in the armed zone carrying the exact URL:
/// once during boot (queued until the scene is mounted) and once while
/// running (beside the existing tiles, which stay as they were).
@MainActor
enum WebLinkOpenChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    private static func pump(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// What AppKit does with the `GURL` event LaunchServices sends when a link
    /// opens in the default browser: hand the URL to the app delegate. (AppKit
    /// installs its GURL handler only for a bundle that declares URL types, so
    /// an unbundled check binary cannot receive the raw event itself.)
    private static func deliverLink(_ link: String) throws {
        guard let url = URL(string: link), let delegate = NSApp.delegate else { throw Failure(description: "no delegate for \(link)") }
        delegate.application?(NSApp, open: [url])
    }

    static func run(outputDir: URL) throws -> [String: Any] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000C101")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000C102")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000C103")!
        let noteId = UUID(uuidString: "00000000-0000-0000-0000-00000000C104")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-web-link-\(UUID().uuidString)", isDirectory: true)
        let root = tempRoot.appendingPathComponent("Alpha", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [root, appSupport] { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? fileManager.removeItem(at: tempRoot) }

        let project = Project(
            id: projectId, name: "Alpha", rootPath: root.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                      terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        var note = Tile(id: noteId, kind: .note, title: "note",
                        frame: TileFrame(x: 20, y: 20, width: 220, height: 140),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(noteId: noteId))
        note.zoneId = zoneId
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                         tiles: [note], groups: [], lastActiveTileId: noteId))
        let zone = ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 300, y: 200),
                                 size: ZoneSize(width: 1600, height: 1100), color: "blue", collapsed: false,
                                 hydrationPolicy: .automatic)
        let document = WorkspaceDocument(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), zones: [zone],
                                         zoneZOrder: [zoneId], lastActiveZoneId: zoneId)
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceId
        registry.projects = [ProjectEntry(id: projectId, name: "Alpha", rootPath: root.path, workspaceId: workspaceId,
                                          lastOpenedAt: now, pinned: false, missing: false)]
        registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "Alpha Workspace", projectIds: [projectId],
                                              createdAt: now, updatedAt: now)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(registry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
            guard id == projectId else { throw Failure(description: "unexpected project \(id)") }
            return ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        })
        let bootCanvas = try store.loadCanvas()
        let canvas = CanvasNSView(canvasState: bootCanvas, activeZone: zone,
                                  zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: zone, displayName: "Alpha")])
        canvas.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(boot: try zoneRegistry.acquire(projectId: projectId), workspaceId: workspaceId,
                                       document: document, registry: zoneRegistry, focusBroker: delegate.qaFocusBroker,
                                       registryStore: registryStore, ghostty: nil, browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime,
                                            registryStore: registryStore)
        let previousDelegate = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = previousDelegate }

        // === Cold launch: the link arrives before the scene exists. ===
        let coldLink = "http://links.example.test/inbox/thread?id=42&ref=mail#reply"
        try deliverLink(coldLink)
        try expect(delegate.pendingWebLinksForQA.map(\.absoluteString) == [coldLink],
                   "a link during boot must reach application(_:open:) and wait for the scene; pending \(delegate.pendingWebLinksForQA)")

        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
                                  projectStore: store, project: project)
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: store,
                                               canvasState: bootCanvas, installsGlobalEventMonitors: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = canvas
        delegate.qaAttachWindowForOfflineCheck(window)

        func browserTiles() -> [Tile] {
            (canvas.tilesInWorldFrames(forZoneId: zoneId) ?? []).filter { $0.kind == .browser }
        }
        try expect(pump(5) { browserTiles().count == 1 }, "the boot link must open one browser tile; got \(browserTiles().count); pending \(delegate.pendingWebLinksForQA.count), spawner \(delegate.spawnerForFilesystemCreation() != nil), all \(canvas.allTilesInWorldFrames().map { "\($0.kind)@\($0.zoneId?.uuidString.suffix(4) ?? "-")" }), zone layer \(canvas.tilesInWorldFrames(forZoneId: zoneId) == nil ? "none" : "ok")")
        try expect(delegate.pendingWebLinksForQA.isEmpty, "the boot link must leave the queue")
        let coldTile = browserTiles()[0]
        guard let installedZone = canvas.installedZonePlacement(for: zoneId) else { throw Failure(description: "the armed zone has no installed layer") }
        let zoneRect = CGRect(x: installedZone.origin.x, y: installedZone.origin.y, width: installedZone.size.width, height: installedZone.size.height)
        let coldFrame = CGRect(x: coldTile.frame.x, y: coldTile.frame.y, width: coldTile.frame.width, height: coldTile.frame.height)
        try expect(coldTile.metadata.url == coldLink, "tile URL must be the link exactly; got \(coldTile.metadata.url ?? "nil")")
        try expect(zoneRect.contains(coldFrame), "the tile must land inside the armed zone \(zoneRect); world frame \(coldFrame)")
        guard let coldView = canvas.tileView(for: coldTile.id) as? BrowserTileNSView else {
            throw Failure(description: "the link tile has no browser view")
        }
        try expect(coldView.runtime.url == coldLink, "the browser must load the link exactly; got \(coldView.runtime.url)")

        // === Running: a second link opens beside, and touches nothing else. ===
        let noteBefore = canvas.allTilesInWorldFrames().first { $0.id == noteId }
        let runningLink = "https://links.example.test/docs/Guide%20One.html?lang=en#install"
        try deliverLink(runningLink)
        try expect(pump(5) { browserTiles().count == 2 }, "a link while running must open a second tile; got \(browserTiles().count)")
        let runningTile = try browserTiles().first { $0.id != coldTile.id } ?? { throw Failure(description: "no second tile") }()
        try expect(runningTile.metadata.url == runningLink, "running link must be exact; got \(runningTile.metadata.url ?? "nil")")
        try expect(browserTiles().first { $0.id == coldTile.id }?.metadata.url == coldLink, "the first link tile must not be taken over")
        try expect(canvas.allTilesInWorldFrames().first { $0.id == noteId }?.frame == noteBefore?.frame, "an unrelated tile must not move")
        let persisted = try store.loadCanvas().tiles.filter { $0.kind == .browser }.compactMap(\.metadata.url).sorted()
        try expect(persisted == [coldLink, runningLink].sorted(), "both link tiles must persist; got \(persisted)")

        // What a plain-http page gets in a tile (DNS failure here; not ATS).
        _ = pump(5) { if case .failed = coldView.runtime.loadingState { return true }; return false }
        var coldLoad = "\(coldView.runtime.loadingState)"
        if case let .failed(message) = coldView.runtime.loadingState { coldLoad = message }

        // Stills: the canvas, light and dark (web content is not captured).
        var stills: [String] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let url = outputDir.appendingPathComponent("web-link-canvas-\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            stills.append(url.path)
        }
        for tile in browserTiles() { (canvas.tileView(for: tile.id) as? BrowserTileNSView)?.runtime.terminate(policy: .force) }
        return ["coldLink": coldLink, "runningLink": runningLink, "coldTileWorldFrame": NSStringFromRect(coldFrame),
                "zone": NSStringFromRect(zoneRect), "coldLoad": coldLoad, "stills": stills]
    }
}
