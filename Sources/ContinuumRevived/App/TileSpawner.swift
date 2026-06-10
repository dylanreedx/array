import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class TileSpawner {
    enum Outcome {
        case spawned(GhosttyTerminalRuntime)
        case unknownProfile(id: String)
        case missingCommand(executable: String)
        case notConfigured(profileId: String)
        case failure(Error)
    }

    enum SpawnError: Error {
        case canvasUnavailable
    }

    struct AnnotatedProfile {
        let spec: LaunchProfileSpec
        let resolution: LaunchProfileResolution
    }

    weak var canvasView: CanvasNSView?
    private let ghostty: GhosttyRuntimeContext?
    private let browserEngine: BrowserEngineContext
    private let projectStore: ProjectStore
    private let project: Project
    private let registry: LaunchProfileRegistry
    private let detector: ToolDetector

    /// Called after every browser-tile state change (URL, title, loading, error)
    /// so the AppDelegate can schedule a debounced BrowserState save.
    var browserPersistenceHandler: (() -> Void)?

    init(
        canvasView: CanvasNSView,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext,
        projectStore: ProjectStore,
        project: Project,
        registry: LaunchProfileRegistry = LaunchProfileRegistry(),
        detector: ToolDetector = .live
    ) {
        self.canvasView = canvasView
        self.ghostty = ghostty
        self.browserEngine = browserEngine
        self.projectStore = projectStore
        self.project = project
        self.registry = registry
        self.detector = detector
    }

    func annotatedProfiles() -> [AnnotatedProfile] {
        registry.all().map { spec in
            AnnotatedProfile(
                spec: spec,
                resolution: registry.resolve(
                    spec,
                    in: project.rootPath,
                    environment: ProcessInfo.processInfo.environment,
                    detector: detector
                )
            )
        }
    }

    func spawnTerminal(profileId: String, at worldPoint: CGPoint? = nil) -> Outcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let ghostty else { return .failure(SpawnError.canvasUnavailable) }
        guard let spec = registry.spec(for: profileId) else {
            return .unknownProfile(id: profileId)
        }
        let resolution = registry.resolve(
            spec,
            in: project.rootPath,
            environment: ProcessInfo.processInfo.environment,
            detector: detector
        )
        let profile: LaunchProfile
        switch resolution {
        case let .found(p): profile = p
        case let .missing(name): return .missingCommand(executable: name)
        case let .notConfigured(id): return .notConfigured(profileId: id)
        }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .terminal),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        var tile = Tile(
            id: UUID(),
            kind: .terminal,
            title: profile.title,
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: spec.id, projectRelativeCwd: ".")
        )
        let runtime = GhosttyTerminalRuntime(
            id: UUID(),
            tileId: tile.id,
            title: profile.title,
            launchProfile: profile,
            ghostty: ghostty
        )
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)

        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        canvasView.install(tileView: view, for: tile)

        let now = Date()
        let descriptor = TerminalSessionDescriptor(
            id: runtime.id,
            tileId: tile.id,
            launchProfileId: spec.id,
            command: profile.command,
            args: profile.arguments,
            cwd: profile.cwd,
            env: [:],
            title: profile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil
        )
        do {
            try projectStore.saveSession(descriptor)
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(runtime)
    }

    enum RestartOutcome {
        case restarted(GhosttyTerminalRuntime)
        case unknownProfile(id: String)
        case missingCommand(executable: String)
        case notConfigured(profileId: String)
        case tileNotFound
        case failure(Error)
    }

    /// Re-resolve the existing tile's profile and replace its view with a fresh
    /// terminal runtime. Reuses tile id, frame, and z-index so the canvas slot
    /// doesn't shift; updates `runtimeRef`, title, and the persisted descriptor.
    func restartTerminalTile(tileId: UUID) -> RestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let ghostty else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        let profileId = existing.metadata.launchProfileId ?? "shell"
        guard let spec = registry.spec(for: profileId) else {
            return .unknownProfile(id: profileId)
        }
        let resolution = registry.resolve(
            spec,
            in: project.rootPath,
            environment: ProcessInfo.processInfo.environment,
            detector: detector
        )
        let profile: LaunchProfile
        switch resolution {
        case let .found(p): profile = p
        case let .missing(name): return .missingCommand(executable: name)
        case let .notConfigured(id): return .notConfigured(profileId: id)
        }

        let runtime = GhosttyTerminalRuntime(
            id: UUID(),
            tileId: existing.id,
            title: profile.title,
            launchProfile: profile,
            ghostty: ghostty
        )
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)
        tile.title = profile.title
        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        canvasView.install(tileView: view, for: tile)

        let now = Date()
        let descriptor = TerminalSessionDescriptor(
            id: runtime.id,
            tileId: tile.id,
            launchProfileId: spec.id,
            command: profile.command,
            args: profile.arguments,
            cwd: profile.cwd,
            env: [:],
            title: profile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil
        )
        do {
            try projectStore.saveSession(descriptor)
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .restarted(runtime)
    }

    enum BrowserOutcome {
        case spawned(WKWebViewBrowserRuntime)
        case invalidURL(String)
        case failure(Error)
    }

    enum BrowserRestartOutcome {
        case restarted(WKWebViewBrowserRuntime)
        case invalidURL(String)
        case tileNotFound
        case failure(Error)
    }

    private static let defaultBrowserURL = "http://localhost:3000"

    /// Spawns a live `WKWebView` browser tile. Defaults to localhost:3000 if
    /// `url` is nil. Persists a BrowserTile entry into BrowserState alongside
    /// the canvas state. Returns the runtime so the caller can track it for
    /// shutdown.
    func spawnBrowser(url: String? = nil, at worldPoint: CGPoint? = nil) -> BrowserOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let urlString = url ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else {
            return .invalidURL(urlString)
        }
        let browserState: BrowserState
        do {
            browserState = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        } catch {
            return .failure(error)
        }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .browser),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        var tile = Tile(
            id: UUID(),
            kind: .browser,
            title: "Browser",
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(url: urlString)
        )

        let storageGroupId = BrowserState.storageGroupIdentifier(for: project)
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: tile.id,
            webView: webView,
            initialURL: urlString
        )
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserPersistenceHandler?() }
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: "",
                storageGroupId: storageGroupId,
                in: browserState
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        runtime.loadURL(urlString)
        return .spawned(runtime)
    }

    /// Re-resolve an existing browser tile's URL and replace its view with a
    /// fresh runtime. Reuses tile id, frame, and z-index.
    func restartBrowserTile(tileId: UUID) -> BrowserRestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        let browserState: BrowserState?
        let persistedBrowserTile: BrowserTile?
        do {
            browserState = try loadBrowserStateIfAvailable()
            persistedBrowserTile = browserState?.tiles.first(where: { $0.tileId == tileId })
        } catch {
            return .failure(error)
        }
        let urlString = persistedBrowserTile?.url ?? existing.metadata.url ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else {
            return .invalidURL(urlString)
        }

        let storageGroupId = persistedBrowserTile?.storageGroupId ?? BrowserState.storageGroupIdentifier(for: project)
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: existing.id,
            webView: webView,
            initialURL: urlString
        )
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)
        if let persistedTitle = persistedBrowserTile?.title, !persistedTitle.isEmpty {
            tile.title = persistedTitle
        }

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserPersistenceHandler?() }
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: persistedBrowserTile?.title ?? tile.title,
                storageGroupId: storageGroupId,
                in: browserState ?? BrowserState(tiles: [])
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        runtime.loadURL(urlString)
        return .restarted(runtime)
    }

    /// Upserts a BrowserTile entry into BrowserState by tileId so multiple
    /// browser tiles in the same project don't clobber each other.
    private func upsertBrowserTile(
        runtimeId: UUID,
        tileId: UUID,
        url: String,
        title: String,
        storageGroupId: String,
        in browserState: BrowserState? = nil
    ) throws {
        var state: BrowserState
        if let browserState {
            state = browserState
        } else {
            state = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        }
        let now = Date()
        if let idx = state.tiles.firstIndex(where: { $0.tileId == tileId }) {
            state.tiles[idx].url = url
            state.tiles[idx].title = title
            state.tiles[idx].storageGroupId = storageGroupId
            state.tiles[idx].updatedAt = now
        } else {
            state.tiles.append(BrowserTile(
                id: runtimeId,
                tileId: tileId,
                url: url,
                title: title,
                storageGroupId: storageGroupId,
                createdAt: now,
                updatedAt: now
            ))
        }
        try projectStore.saveBrowserState(state)
    }

    /// Loads BrowserState when present. A missing file is the only condition
    /// treated as empty; corrupt/unreadable/future-schema state must surface so
    /// callers do not overwrite it from stale canvas metadata.
    private func loadBrowserStateIfAvailable() throws -> BrowserState? {
        do {
            return try projectStore.loadBrowserState()
        } catch AtomicWriterError.noValidBackup where !FileManager.default.fileExists(atPath: projectStore.layout.browserFile.path) {
            return nil
        }
    }

    /// Persist the current url/title for a runtime's tile. Called by the
    /// AppDelegate's debounced flush in response to runtime state changes.
    func writeBrowserTileSnapshot(for runtime: WKWebViewBrowserRuntime) {
        guard let canvasView,
              let tile = canvasView.canvasState.tiles.first(where: { $0.id == runtime.tileId })
        else { return }
        let storageGroupId = BrowserState.storageGroupIdentifier(for: project)
        try? upsertBrowserTile(
            runtimeId: runtime.id,
            tileId: tile.id,
            url: runtime.url,
            title: runtime.title,
            storageGroupId: storageGroupId
        )
    }

    static func runBrowserRestoreStateSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-restore-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let now = Date()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let runtimeIdA = UUID(uuidString: "00000000-0000-0000-0000-0000000005A1")!
        let runtimeIdB = UUID(uuidString: "00000000-0000-0000-0000-0000000005B1")!
        let canvasURL = "data:text/html;charset=utf-8,<html><head><title>canvas-A</title></head><body>A</body></html>"
        let browserStateURL = "data:text/html;charset=utf-8,<html><head><title>browser-B</title></head><body>B</body></html>"
        let canvasTitle = "Canvas title A"
        let browserStateTitle = "Browser title B"

        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000005FF")!,
            name: "browser-restore-state-check",
            rootPath: tempRoot.path,
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
        let expectedStorageGroupId = BrowserState.storageGroupIdentifier(for: project)
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [Tile(
                id: tileId,
                kind: .browser,
                title: canvasTitle,
                frame: TileFrame(x: 20, y: 20, width: 640, height: 420),
                zIndex: 1,
                runtimeRef: RuntimeRef(kind: .browserTile, id: runtimeIdA),
                metadata: TileMetadata(url: canvasURL)
            )],
            groups: [],
            lastActiveTileId: tileId
        ))
        try store.saveBrowserState(BrowserState(tiles: [BrowserTile(
            id: runtimeIdB,
            tileId: tileId,
            url: browserStateURL,
            title: browserStateTitle,
            storageGroupId: expectedStorageGroupId,
            createdAt: now,
            updatedAt: now
        )]))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        let runtime: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(created):
            runtime = created
        case let .invalidURL(url):
            throw CheckError.failed("restartBrowserTile rejected seeded URL: \(url)")
        case .tileNotFound:
            throw CheckError.failed("restartBrowserTile did not find seeded tile")
        case let .failure(error):
            throw CheckError.failed("restartBrowserTile failed: \(error)")
        }
        defer {
            runtime.terminate(policy: .requestClose)
            browserEngine.shutdown()
        }

        let browserTileView = canvas.tileView(for: tileId) as? BrowserTileNSView
        let runtimeURL = runtime.url
        let chromeURL = browserTileView?.chromeURLStringForQA
        let tileTitle = browserTileView?.tile.title
        let canvasTileAfterBoot = try store.loadCanvas().tiles.first(where: { $0.id == tileId })
        let postBootState = try store.loadBrowserState()
        let postBootEntry = postBootState.tiles.first(where: { $0.tileId == tileId })
        let postBootURL = postBootEntry?.url
        let postBootTitle = postBootEntry?.title
        let postBootStorageGroupId = postBootEntry?.storageGroupId

        let corruptRoot = tempRoot.appendingPathComponent("corrupt-browser-state", isDirectory: true)
        try fileManager.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000006FF")!,
            name: "browser-corrupt-state-check",
            rootPath: corruptRoot.path,
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
        let corruptStore = ProjectStore(projectRoot: corruptRoot)
        try corruptStore.saveProject(corruptProject)
        try corruptStore.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [Tile(
                id: tileId,
                kind: .browser,
                title: canvasTitle,
                frame: TileFrame(x: 20, y: 20, width: 640, height: 420),
                zIndex: 1,
                runtimeRef: RuntimeRef(kind: .browserTile, id: runtimeIdA),
                metadata: TileMetadata(url: canvasURL)
            )],
            groups: [],
            lastActiveTileId: tileId
        ))
        try fileManager.createDirectory(at: corruptStore.layout.browserDirectory, withIntermediateDirectories: true)
        let corruptSeed = Data("{ this is not valid BrowserState JSON".utf8)
        try corruptSeed.write(to: corruptStore.layout.browserFile, options: .atomic)
        let corruptCanvas = CanvasNSView(canvasState: try corruptStore.loadCanvas())
        let corruptSpawner = TileSpawner(
            canvasView: corruptCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: corruptStore,
            project: corruptProject
        )
        let corruptRestartFailedSafely: Bool
        let corruptRestartFailureDescription: String
        switch corruptSpawner.restartBrowserTile(tileId: tileId) {
        case .restarted:
            corruptRestartFailedSafely = false
            corruptRestartFailureDescription = "unexpected restart"
        case let .invalidURL(url):
            corruptRestartFailedSafely = false
            corruptRestartFailureDescription = "unexpected invalidURL(\(url))"
        case .tileNotFound:
            corruptRestartFailedSafely = false
            corruptRestartFailureDescription = "unexpected tileNotFound"
        case let .failure(error):
            corruptRestartFailedSafely = true
            corruptRestartFailureDescription = String(describing: error)
        }
        let corruptBrowserBytesAfterRestart = try Data(contentsOf: corruptStore.layout.browserFile)
        let corruptBrowserStateUnchanged = corruptBrowserBytesAfterRestart == corruptSeed
        let corruptBrowserStateTextAfterRestart = String(decoding: corruptBrowserBytesAfterRestart, as: UTF8.self)
        let corruptCanvasURLAfterRestart = try corruptStore.loadCanvas().tiles.first(where: { $0.id == tileId })?.metadata.url
        let corruptDidNotOverwriteWithCanvasURL = !corruptBrowserStateTextAfterRestart.contains(canvasURL)

        let corruptSpawnRoot = tempRoot.appendingPathComponent("corrupt-browser-state-spawn", isDirectory: true)
        try fileManager.createDirectory(at: corruptSpawnRoot, withIntermediateDirectories: true)
        let corruptSpawnProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000007FF")!,
            name: "browser-corrupt-state-spawn-check",
            rootPath: corruptSpawnRoot.path,
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
        let corruptSpawnStore = ProjectStore(projectRoot: corruptSpawnRoot)
        try corruptSpawnStore.saveProject(corruptSpawnProject)
        try corruptSpawnStore.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil
        ))
        try fileManager.createDirectory(at: corruptSpawnStore.layout.browserDirectory, withIntermediateDirectories: true)
        let corruptSpawnSeed = Data("{ this corrupt BrowserState must survive spawnBrowser".utf8)
        try corruptSpawnSeed.write(to: corruptSpawnStore.layout.browserFile, options: .atomic)
        let corruptSpawnCanvas = CanvasNSView(canvasState: try corruptSpawnStore.loadCanvas())
        let corruptSpawnSpawner = TileSpawner(
            canvasView: corruptSpawnCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: corruptSpawnStore,
            project: corruptSpawnProject
        )
        let webViewCreationsBeforeCorruptSpawn = browserEngine.webViewCreationCountForQA
        let corruptSpawnSubviewCountBefore = corruptSpawnCanvas.subviews.count
        let corruptSpawnFailedSafely: Bool
        let corruptSpawnFailureDescription: String
        switch corruptSpawnSpawner.spawnBrowser(url: canvasURL) {
        case .spawned:
            corruptSpawnFailedSafely = false
            corruptSpawnFailureDescription = "unexpected spawn"
        case let .invalidURL(url):
            corruptSpawnFailedSafely = false
            corruptSpawnFailureDescription = "unexpected invalidURL(\(url))"
        case let .failure(error):
            corruptSpawnFailedSafely = true
            corruptSpawnFailureDescription = String(describing: error)
        }
        let corruptSpawnBrowserBytesAfter = try Data(contentsOf: corruptSpawnStore.layout.browserFile)
        let corruptSpawnBrowserStateUnchanged = corruptSpawnBrowserBytesAfter == corruptSpawnSeed
        let corruptSpawnBrowserStateTextAfter = String(decoding: corruptSpawnBrowserBytesAfter, as: UTF8.self)
        let corruptSpawnCanvasAfter = try corruptSpawnStore.loadCanvas()
        let corruptSpawnCanvasTileCountAfter = corruptSpawnCanvas.canvasState.tiles.count
        let corruptSpawnPersistedCanvasTileCountAfter = corruptSpawnCanvasAfter.tiles.count
        let corruptSpawnSubviewCountAfter = corruptSpawnCanvas.subviews.count
        let corruptSpawnWebViewCreationsAfter = browserEngine.webViewCreationCountForQA
        let corruptSpawnInstalledNoTileOrRuntime = corruptSpawnCanvasTileCountAfter == 0
            && corruptSpawnPersistedCanvasTileCountAfter == 0
            && corruptSpawnSubviewCountAfter == corruptSpawnSubviewCountBefore
            && corruptSpawnWebViewCreationsAfter == webViewCreationsBeforeCorruptSpawn

        let manifest: [String: Any] = [
            "check": "browser-restore-state",
            "seedCanvasUrl": canvasURL,
            "seedCanvasTitle": canvasTitle,
            "seedBrowserStateUrl": browserStateURL,
            "seedBrowserStateTitle": browserStateTitle,
            "runtimeUrl": runtimeURL,
            "chromeUrl": chromeURL as Any,
            "tileTitle": tileTitle as Any,
            "canvasMetadataUrlAfterBoot": canvasTileAfterBoot?.metadata.url as Any,
            "postBootBrowserStateUrl": postBootURL as Any,
            "postBootBrowserStateTitle": postBootTitle as Any,
            "postBootStorageGroupId": postBootStorageGroupId as Any,
            "browserStateTileCount": postBootState.tiles.count,
            "corruptRestartFailedSafely": corruptRestartFailedSafely,
            "corruptRestartFailureDescription": corruptRestartFailureDescription,
            "corruptBrowserStateUnchanged": corruptBrowserStateUnchanged,
            "corruptBrowserStateTextAfterRestart": corruptBrowserStateTextAfterRestart,
            "corruptCanvasMetadataUrlAfterRestart": corruptCanvasURLAfterRestart as Any,
            "corruptDidNotOverwriteWithCanvasUrl": corruptDidNotOverwriteWithCanvasURL,
            "corruptProjectRoot": corruptRoot.path,
            "corruptSpawnFailedSafely": corruptSpawnFailedSafely,
            "corruptSpawnFailureDescription": corruptSpawnFailureDescription,
            "corruptSpawnBrowserStateUnchanged": corruptSpawnBrowserStateUnchanged,
            "corruptSpawnBrowserStateTextAfter": corruptSpawnBrowserStateTextAfter,
            "corruptSpawnCanvasTileCountAfter": corruptSpawnCanvasTileCountAfter,
            "corruptSpawnPersistedCanvasTileCountAfter": corruptSpawnPersistedCanvasTileCountAfter,
            "corruptSpawnSubviewCountBefore": corruptSpawnSubviewCountBefore,
            "corruptSpawnSubviewCountAfter": corruptSpawnSubviewCountAfter,
            "corruptSpawnWebViewCreationsBefore": webViewCreationsBeforeCorruptSpawn,
            "corruptSpawnWebViewCreationsAfter": corruptSpawnWebViewCreationsAfter,
            "corruptSpawnInstalledNoTileOrRuntime": corruptSpawnInstalledNoTileOrRuntime,
            "corruptSpawnProjectRoot": corruptSpawnRoot.path,
            "tileId": tileId.uuidString,
            "runtimeTileId": runtime.tileId.uuidString,
            "usedProductionSpawnerPath": true,
            "tempProjectRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("browser-restore-state", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)

        try expect(runtime.tileId == tileId, "runtime should reuse seeded tileId")
        try expect(runtimeURL == browserStateURL, "runtime URL should prefer BrowserState URL B over canvas URL A")
        try expect(chromeURL == browserStateURL, "browser chrome URL field should show BrowserState URL B")
        try expect(tileTitle == browserStateTitle, "tile title should use BrowserState title B")
        try expect(postBootURL == browserStateURL, "boot should not overwrite BrowserState URL B with canvas URL A")
        try expect(postBootTitle == browserStateTitle, "boot should preserve BrowserState title B")
        try expect(postBootStorageGroupId == expectedStorageGroupId, "boot should preserve expected storage group id")
        try expect(postBootState.tiles.count == 1, "boot should not create an extra BrowserState entry")
        try expect(runtimeURL != canvasURL && chromeURL != canvasURL && postBootURL != canvasURL, "URL A must not be used for runtime, chrome, or post-boot BrowserState")
        try expect(runtimeURL != Self.defaultBrowserURL && chromeURL != Self.defaultBrowserURL && postBootURL != Self.defaultBrowserURL, "default URL must not mask restore source")
        try expect(corruptRestartFailedSafely, "corrupt BrowserState should fail safely instead of restarting from canvas metadata")
        try expect(corruptBrowserStateUnchanged, "corrupt BrowserState file should remain byte-for-byte unchanged")
        try expect(corruptDidNotOverwriteWithCanvasURL, "corrupt BrowserState must not be overwritten with canvas URL A")
        try expect(corruptCanvasURLAfterRestart == canvasURL, "corrupt scenario should keep seeded canvas metadata available but unused for BrowserState rewrite")
        try expect(corruptSpawnFailedSafely, "spawnBrowser should fail safely when existing BrowserState is corrupt")
        try expect(corruptSpawnBrowserStateUnchanged, "spawnBrowser must leave corrupt BrowserState byte-for-byte unchanged")
        try expect(!corruptSpawnBrowserStateTextAfter.contains(canvasURL), "spawnBrowser must not overwrite corrupt BrowserState with requested URL")
        try expect(corruptSpawnInstalledNoTileOrRuntime, "spawnBrowser corrupt preflight failure must install no canvas tile, NSView, WKWebView, or runtime")

        return artifact
    }

    private func makePlacement(worldPoint: CGPoint?, size: CGSize, in canvasView: CanvasNSView) -> TileFrame {
        let cascadeStep: Double = 32
        let world: CGPoint
        if let worldPoint {
            world = worldPoint
        } else {
            let centerScreen = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
            world = CanvasEngine.screenToWorld(centerScreen, viewport: canvasView.viewport)
        }
        // Cascade per existing tile so freshly spawned tiles do not stack.
        let count = Double(canvasView.canvasState.tiles.count)
        let offset = count * cascadeStep
        return TileFrame(
            x: Double(world.x) - Double(size.width) / 2 + offset,
            y: Double(world.y) - Double(size.height) / 2 + offset,
            width: Double(size.width),
            height: Double(size.height)
        )
    }
}
