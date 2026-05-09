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
    private let ghostty: GhosttyRuntimeContext
    private let browserEngine: BrowserEngineContext
    private let projectStore: ProjectStore
    private let project: Project
    private let registry: LaunchProfileRegistry
    private let detector: ToolDetector

    /// Called after every browser-tile state change (URL, title, loading, error)
    /// so the AppDelegate can schedule a debounced BrowserState save.
    var browserPersistenceHandler: (() -> Void)?

    /// Called after every note text change so the AppDelegate can schedule a
    /// debounced note body + index save.
    var notePersistenceHandler: (() -> Void)?

    init(
        canvasView: CanvasNSView,
        ghostty: GhosttyRuntimeContext,
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

    enum NoteOutcome {
        case spawned(noteId: UUID, tileId: UUID)
        case failure(Error)
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
                storageGroupId: storageGroupId
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
        let urlString = existing.metadata.url ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else {
            return .invalidURL(urlString)
        }

        let storageGroupId = BrowserState.storageGroupIdentifier(for: project)
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: existing.id,
            webView: webView,
            initialURL: urlString
        )
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserPersistenceHandler?() }
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: tile.title,
                storageGroupId: storageGroupId
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
        storageGroupId: String
    ) throws {
        var state = (try? projectStore.tryLoadBrowserState()) ?? BrowserState(tiles: [])
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

    // MARK: - Note tiles

    /// Spawns a new blank note tile. Creates the note body file and index entry,
    /// installs the tile view, and persists the canvas state.
    func spawnNote(title: String, at worldPoint: CGPoint? = nil) -> NoteOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let noteId = UUID()
        let tileId = UUID()
        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .note),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        let tile = Tile(
            id: tileId,
            kind: .note,
            title: title,
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(noteId: noteId)
        )
        do {
            try projectStore.saveNoteBody(id: noteId, text: "")
            try upsertNoteTile(noteId: noteId, tileId: tileId, title: title)
        } catch {
            return .failure(error)
        }
        let view = NoteTileNSView(tile: tile, noteId: noteId, initialBody: "")
        view.onTextChange = { [weak self] in self?.notePersistenceHandler?() }
        canvasView.install(tileView: view, for: tile)
        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(noteId: noteId, tileId: tileId)
    }

    /// Installs a note tile view for an existing `Tile` (e.g. when restoring
    /// canvas state on boot). Generates a fresh noteId if the tile has none.
    func installNoteTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let noteId: UUID
        var activeTile = tile
        if let existingNoteId = tile.metadata.noteId {
            noteId = existingNoteId
        } else {
            noteId = UUID()
            var patched = tile
            patched.metadata = TileMetadata(
                launchProfileId: tile.metadata.launchProfileId,
                projectRelativeCwd: tile.metadata.projectRelativeCwd,
                url: tile.metadata.url,
                noteId: noteId,
                filePath: tile.metadata.filePath
            )
            activeTile = patched
            canvasView.updateTile(activeTile)
            try? upsertNoteTile(noteId: noteId, tileId: tile.id, title: tile.title)
            try? projectStore.saveCanvas(canvasView.canvasState)
        }
        let initialBody = projectStore.tryLoadNoteBody(id: noteId) ?? ""
        let view = NoteTileNSView(tile: activeTile, noteId: noteId, initialBody: initialBody)
        view.onTextChange = { [weak self] in self?.notePersistenceHandler?() }
        canvasView.install(tileView: view, for: activeTile)
    }

    /// Writes the current text body and updates the note's `updatedAt` timestamp
    /// in the index. Called by the AppDelegate's debounced flush.
    func writeNoteSnapshot(noteId: UUID, tileId: UUID, text: String) {
        try? projectStore.saveNoteBody(id: noteId, text: text)
        guard var state = try? projectStore.loadNoteState(),
              let idx = state.tiles.firstIndex(where: { $0.id == noteId })
        else { return }
        state.tiles[idx].updatedAt = Date()
        try? projectStore.saveNoteState(state)
    }

    private func upsertNoteTile(noteId: UUID, tileId: UUID, title: String) throws {
        var state = (try? projectStore.tryLoadNoteState()) ?? NoteState(tiles: [])
        let now = Date()
        if let idx = state.tiles.firstIndex(where: { $0.id == noteId }) {
            state.tiles[idx].title = title
            state.tiles[idx].updatedAt = now
        } else {
            state.tiles.append(NoteTile(
                id: noteId,
                tileId: tileId,
                filename: "\(noteId.uuidString).md",
                title: title,
                createdAt: now,
                updatedAt: now
            ))
        }
        try projectStore.saveNoteState(state)
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
