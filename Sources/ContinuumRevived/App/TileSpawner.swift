import AppKit
import ContinuumRevivedCore
import ContinuumRevivedFileTree
import Foundation
import WebKit

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
    private var browserProfiles: [BrowserProfile]

    /// Dynamic source used by browser tile profile menus after registry edits.
    var browserProfileMenuProvider: (() -> [BrowserProfile])?
    var browserProfileSwitchHandler: ((UUID, UUID) -> Void)?
    var browserProfileCreateHandler: ((UUID) -> Void)?
    var browserProfileRenameHandler: ((UUID, UUID) -> Void)?
    var browserProfileDeleteHandler: ((UUID, UUID) -> Void)?

    /// Called after every browser-tile state change (URL, title, loading, error)
    /// so the AppDelegate can schedule a debounced BrowserState save.
    var browserPersistenceHandler: (() -> Void)?

    /// Called after every note text change so the AppDelegate can schedule a
    /// debounced note body + index save.
    var notePersistenceHandler: (() -> Void)?

    /// Called after file-tree expansion, selection, or search changes so the
    /// AppDelegate can schedule a debounced FileTreeState save.
    var fileTreePersistenceHandler: (() -> Void)?

    /// Lets runtime-owned key paths route reserved shortcuts through the app's
    /// FocusBroker instead of consuming them inside terminal/browser content.
    var reservedShortcutHandler: ((NSEvent) -> Bool)?

    init(
        canvasView: CanvasNSView,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext,
        projectStore: ProjectStore,
        project: Project,
        registry: LaunchProfileRegistry = LaunchProfileRegistry(),
        detector: ToolDetector = .live,
        browserProfiles: [BrowserProfile] = [BrowserProfile.builtInDefault()]
    ) {
        self.canvasView = canvasView
        self.ghostty = ghostty
        self.browserEngine = browserEngine
        self.projectStore = projectStore
        self.project = project
        self.registry = registry
        self.detector = detector
        self.browserProfiles = browserProfiles
        canvasView.onFileURLDrop = { [weak self] path, worldPoint in
            _ = self?.spawnFile(path: path, at: worldPoint)
        }
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
        runtime.reservedShortcutHandler = reservedShortcutHandler
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)

        let now = Date()
        let agentDescriptor = agentDescriptor(for: spec, at: now)
        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        view.agentStatus = agentDescriptor?.status
        canvasView.install(tileView: view, for: tile)

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
            lastExit: nil,
            agentDescriptor: agentDescriptor
        )
        do {
            try projectStore.saveSession(descriptor)
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(runtime)
    }

    private func agentDescriptor(for spec: LaunchProfileSpec, at now: Date) -> AgentDescriptor? {
        guard let agentKind = spec.agentKind else { return nil }
        return AgentDescriptor(
            agentKind: agentKind,
            worktreePath: project.rootPath,
            status: .configuring,
            statusUpdatedAt: now
        )
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
        runtime.reservedShortcutHandler = reservedShortcutHandler
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)
        tile.title = profile.title
        let now = Date()
        let agentDescriptor = agentDescriptor(for: spec, at: now)
        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        view.agentStatus = agentDescriptor?.status
        canvasView.install(tileView: view, for: tile)

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
            lastExit: nil,
            agentDescriptor: agentDescriptor
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

    enum FileOutcome {
        case spawned(tileId: UUID)
        case invalidPath
        case failure(Error)
    }

    enum FileTreeOutcome {
        case spawned(tileId: UUID, viewModel: FileTreeViewModel)
        case invalidPath
        case failure(Error)
    }

    enum FileTreeRestartOutcome {
        case restarted(FileTreeViewModel)
        case tileNotFound
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

    enum BrowserProfileSwitchOutcome {
        case switched(oldRuntimeId: UUID?, newRuntime: WKWebViewBrowserRuntime)
        case unknownProfile(UUID)
        case invalidURL(String)
        case tileNotFound
        case failure(Error)
    }

    private static var defaultBrowserURL: String { DefaultBrowserURL.current }

    func updateBrowserProfiles(_ profiles: [BrowserProfile]) {
        browserProfiles = RegistrySettings.normalizedBrowserProfilesForApp(profiles)
    }

    private func availableBrowserProfiles() -> [BrowserProfile] {
        RegistrySettings.normalizedBrowserProfilesForApp(browserProfileMenuProvider?() ?? browserProfiles)
    }

    private func browserProfile(for id: UUID?) -> BrowserProfile {
        let requested = id ?? project.settings.defaultBrowserProfileId
        return availableBrowserProfiles().first(where: { $0.id == requested }) ?? BrowserProfile.builtInDefault()
    }

    private func activeBrowserProfileId(for tileId: UUID) -> UUID {
        if let persisted = try? loadBrowserStateIfAvailable()?.tiles.first(where: { $0.tileId == tileId }) {
            return browserProfile(for: persisted.profileId).id
        }
        return browserProfile(for: canvasView?.canvasState.tiles.first(where: { $0.id == tileId })?.metadata.browserProfileId).id
    }

    private func configureBrowserProfileMenu(_ view: BrowserTileNSView, tileId: UUID) {
        view.browserProfilesProvider = { [weak self] in self?.availableBrowserProfiles() ?? [BrowserProfile.builtInDefault()] }
        view.activeBrowserProfileProvider = { [weak self] in self?.activeBrowserProfileId(for: tileId) ?? BrowserProfile.defaultProfileId }
        view.onSwitchBrowserProfile = { [weak self] profileId in self?.browserProfileSwitchHandler?(tileId, profileId) }
        view.onCreateBrowserProfile = { [weak self] in self?.browserProfileCreateHandler?(tileId) }
        view.onRenameBrowserProfile = { [weak self] profileId in self?.browserProfileRenameHandler?(tileId, profileId) }
        view.onDeleteBrowserProfile = { [weak self] profileId in self?.browserProfileDeleteHandler?(tileId, profileId) }
    }

    /// Spawns a live `WKWebView` browser tile. Defaults to the configured
    /// browser URL (`about:blank` unless overridden) if `url` is nil. Persists a BrowserTile entry into BrowserState alongside
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
            metadata: TileMetadata(url: urlString, browserProfileId: browserProfile(for: nil).id)
        )

        let profile = browserProfile(for: tile.metadata.browserProfileId)
        let storageGroupId = profile.dataStoreIdentifier
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: tile.id,
            webView: webView,
            initialURL: urlString
        )
        runtime.reservedShortcutHandler = reservedShortcutHandler
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserPersistenceHandler?() }
        configureBrowserProfileMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: "",
                storageGroupId: storageGroupId,
                profileId: profile.id,
                in: browserState
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        runtime.loadURL(urlString)
        return .spawned(runtime)
    }

    func installBrowserSnapshotTile(runtime: WKWebViewBrowserRuntime, snapshotImage: NSImage) throws {
        guard let canvasView,
              let existing = canvasView.canvasState.tiles.first(where: { $0.id == runtime.tileId })
        else { throw SpawnError.canvasUnavailable }
        try writeBrowserTileSnapshotOrThrow(for: runtime)
        var tile = existing
        tile.runtimeRef = nil
        if !runtime.title.isEmpty {
            tile.title = runtime.title
        }
        let view = BrowserSnapshotTileNSView(
            tile: tile,
            snapshotImage: snapshotImage,
            urlString: runtime.url
        )
        canvasView.install(tileView: view, for: tile)
        try projectStore.saveCanvas(canvasView.canvasState)
        runtime.terminate(policy: .force)
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

        let profile = browserProfile(for: persistedBrowserTile?.profileId ?? existing.metadata.browserProfileId)
        let storageGroupId = persistedBrowserTile?.storageGroupId ?? profile.dataStoreIdentifier
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: existing.id,
            webView: webView,
            initialURL: urlString
        )
        runtime.reservedShortcutHandler = reservedShortcutHandler
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)
        if let persistedTitle = persistedBrowserTile?.title, !persistedTitle.isEmpty {
            tile.title = persistedTitle
        }

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserPersistenceHandler?() }
        configureBrowserProfileMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: persistedBrowserTile?.title ?? tile.title,
                storageGroupId: storageGroupId,
                profileId: profile.id,
                in: browserState ?? BrowserState(tiles: [])
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        runtime.loadURL(urlString)
        return .restarted(runtime)
    }

    /// Switches one browser tile to a different persisted profile by replacing
    /// its WKWebView/runtime. WebKit data stores are construction-time state,
    /// so profile changes cannot be applied in place.
    func switchBrowserTileProfile(tileId: UUID, profileId: UUID) -> BrowserProfileSwitchOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        guard let selectedProfile = availableBrowserProfiles().first(where: { $0.id == profileId }) else {
            return .unknownProfile(profileId)
        }

        let oldBrowserView = canvasView.tileView(for: tileId) as? BrowserTileNSView
        let oldRuntime = oldBrowserView?.runtime
        let browserState: BrowserState?
        let persistedBrowserTile: BrowserTile?
        do {
            browserState = try loadBrowserStateIfAvailable()
            persistedBrowserTile = browserState?.tiles.first(where: { $0.tileId == tileId })
        } catch {
            return .failure(error)
        }
        let urlString = oldRuntime?.url ?? persistedBrowserTile?.url ?? existing.metadata.url ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else { return .invalidURL(urlString) }
        let title = oldRuntime?.title.isEmpty == false ? (oldRuntime?.title ?? existing.title) : (persistedBrowserTile?.title ?? existing.title)

        let webView = browserEngine.makeWebView(storageGroupId: selectedProfile.dataStoreIdentifier)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: existing.id,
            webView: webView,
            initialURL: urlString
        )
        runtime.reservedShortcutHandler = reservedShortcutHandler

        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)
        tile.title = title.isEmpty ? existing.title : title
        tile.metadata.url = urlString
        tile.metadata.browserProfileId = selectedProfile.id

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserPersistenceHandler?() }
        configureBrowserProfileMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: title,
                storageGroupId: selectedProfile.dataStoreIdentifier,
                profileId: selectedProfile.id,
                in: browserState ?? BrowserState(tiles: [])
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        oldRuntime?.onStateChange = nil
        oldRuntime?.terminate(policy: .requestClose)
        runtime.loadURL(urlString)
        return .switched(oldRuntimeId: oldRuntime?.id, newRuntime: runtime)
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

    /// Installs a note tile view for an existing `Tile` (e.g. canvas restore).
    /// If old canvas data lacks a note id, a note id is generated and persisted.
    func installNoteTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let noteId: UUID
        var activeTile = tile
        if let existingNoteId = tile.metadata.noteId {
            noteId = existingNoteId
        } else {
            noteId = UUID()
            activeTile.metadata = TileMetadata(
                launchProfileId: tile.metadata.launchProfileId,
                projectRelativeCwd: tile.metadata.projectRelativeCwd,
                url: tile.metadata.url,
                noteId: noteId,
                filePath: tile.metadata.filePath
            )
            canvasView.updateTile(activeTile)
            try? upsertNoteTile(noteId: noteId, tileId: tile.id, title: tile.title)
            try? projectStore.saveCanvas(canvasView.canvasState)
        }
        let initialBody = projectStore.tryLoadNoteBody(id: noteId) ?? ""
        let view = NoteTileNSView(tile: activeTile, noteId: noteId, initialBody: initialBody)
        view.onTextChange = { [weak self] in self?.notePersistenceHandler?() }
        canvasView.install(tileView: view, for: activeTile)
    }

    /// Writes the current text body and updates the note's `updatedAt` timestamp.
    func writeNoteSnapshot(noteId: UUID, tileId: UUID, text: String) {
        try? projectStore.saveNoteBody(id: noteId, text: text)
        guard var state = try? projectStore.loadNoteState(),
              let idx = state.tiles.firstIndex(where: { $0.id == noteId && $0.tileId == tileId })
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

    // MARK: - File tiles

    /// Spawns a read-only file preview tile and persists the canvas state.
    func spawnFile(path: String, title: String? = nil, at worldPoint: CGPoint? = nil) -> FileOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .invalidPath }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .file),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        let tile = Tile(
            id: UUID(),
            kind: .file,
            title: title ?? URL(fileURLWithPath: trimmedPath).lastPathComponent,
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(filePath: trimmedPath)
        )
        let view = FileTileNSView(tile: tile)
        canvasView.install(tileView: view, for: tile)

        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(tileId: tile.id)
    }

    /// Installs a file tile view for an existing `Tile` during canvas restore.
    func installFileTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let view = FileTileNSView(tile: tile)
        canvasView.install(tileView: view, for: tile)
    }

    /// Upserts a BrowserTile entry into BrowserState by tileId so multiple
    /// browser tiles in the same project don't clobber each other.
    private func upsertBrowserTile(
        runtimeId: UUID,
        tileId: UUID,
        url: String,
        title: String,
        storageGroupId: String,
        profileId: UUID,
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
            state.tiles[idx].profileId = profileId
            state.tiles[idx].updatedAt = now
        } else {
            state.tiles.append(BrowserTile(
                id: runtimeId,
                tileId: tileId,
                url: url,
                title: title,
                storageGroupId: storageGroupId,
                profileId: profileId,
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
        try? writeBrowserTileSnapshotOrThrow(for: runtime)
    }

    func writeBrowserTileSnapshotOrThrow(for runtime: WKWebViewBrowserRuntime) throws {
        guard let canvasView,
              let tile = canvasView.canvasState.tiles.first(where: { $0.id == runtime.tileId })
        else { return }
        let persistedTile = try loadBrowserStateIfAvailable()?.tiles.first(where: { $0.tileId == tile.id })
        let profile = browserProfile(for: persistedTile?.profileId ?? tile.metadata.browserProfileId)
        let storageGroupId = persistedTile?.storageGroupId ?? profile.dataStoreIdentifier
        let persistedTitle = persistedTile?.title
        let title = runtime.title.isEmpty ? (persistedTitle ?? runtime.title) : runtime.title
        try upsertBrowserTile(
            runtimeId: runtime.id,
            tileId: tile.id,
            url: runtime.url,
            title: title,
            storageGroupId: storageGroupId,
            profileId: profile.id
        )
    }

    static func runBrowserProfilePersistenceSelfCheck() throws -> URL {
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

        let profileA = BrowserProfile(
            id: UUID(),
            name: "QA Profile A",
            dataStoreIdentifier: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let profileB = BrowserProfile(
            id: UUID(),
            name: "QA Profile B",
            dataStoreIdentifier: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let tileA = UUID()
        let tileB = UUID()
        let state = BrowserState(tiles: [
            BrowserTile(id: UUID(), tileId: tileA, url: "https://example.test/a", title: "A", storageGroupId: profileA.dataStoreIdentifier, profileId: profileA.id, createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 3)),
            BrowserTile(id: UUID(), tileId: tileB, url: "https://example.test/b", title: "B", storageGroupId: profileB.dataStoreIdentifier, profileId: profileB.id, createdAt: Date(timeIntervalSince1970: 4), updatedAt: Date(timeIntervalSince1970: 5))
        ])
        let data = try JSONCodec.makeEncoder().encode(state)
        let decoded = try JSONCodec.makeDecoder().decode(BrowserState.self, from: data)
        try expect(decoded.tiles.first(where: { $0.tileId == tileA })?.profileId == profileA.id, "profile A id round-trips")
        try expect(decoded.tiles.first(where: { $0.tileId == tileB })?.profileId == profileB.id, "profile B id round-trips")
        try expect(decoded.tiles.first(where: { $0.tileId == tileA })?.storageGroupId != decoded.tiles.first(where: { $0.tileId == tileB })?.storageGroupId, "profiles retain isolated WK data-store identifiers")

        let legacy = """
        {"id":"\(UUID().uuidString)","tileId":"\(UUID().uuidString)","url":"https://legacy.test","title":"Legacy","storageGroupId":"\(profileA.dataStoreIdentifier)","createdAt":"1970-01-01T00:00:00Z","updatedAt":"1970-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let legacyTile = try JSONCodec.makeDecoder().decode(BrowserTile.self, from: legacy)
        try expect(legacyTile.profileId == BrowserProfile.defaultProfileId, "legacy BrowserTile without profileId decodes to Default")

        let registryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-browser-profile-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: registryRoot) }
        let registryStore = RegistryStore(applicationSupportDirectory: registryRoot, retainedBackups: 1)
        var registry = Registry.empty()
        guard let createdProfile = BrowserProfilePersistenceActions.createProfile(
            named: "QA Created",
            in: &registry,
            now: Date(timeIntervalSince1970: 20)
        ) else {
            throw CheckError.failed("profile create helper accepts custom profile")
        }
        try registryStore.save(registry)
        var persistedRegistry = try registryStore.loadOrEmpty()
        try expect(persistedRegistry.settings.browserProfiles.contains(where: { $0.id == createdProfile.id && $0.name == "QA Created" }), "created profile persists to registry store")
        try expect(BrowserProfilePersistenceActions.renameProfile(id: createdProfile.id, to: "QA Created Renamed", in: &persistedRegistry), "profile rename helper accepts custom profile")
        try registryStore.save(persistedRegistry)
        persistedRegistry = try registryStore.loadOrEmpty()
        try expect(persistedRegistry.settings.browserProfiles.first(where: { $0.id == createdProfile.id })?.name == "QA Created Renamed", "renamed profile persists to registry store")

        let deletedProfile = BrowserProfilePersistenceActions.makeProfile(
            name: "QA Deleted",
            id: UUID(),
            dataStoreIdentifier: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 21)
        )
        try expect(persistedRegistry.settings.upsertBrowserProfile(deletedProfile), "delete fixture profile is present before delete")
        let rewriteTileId = UUID()
        let rewriteCanvasOnlyTileId = UUID()
        let deleteRewriteURLString = "https://profile-delete-rewrite.test/"
        var rewriteBrowserState: BrowserState? = BrowserState(tiles: [
            BrowserTile(id: UUID(), tileId: rewriteTileId, url: deleteRewriteURLString, title: "Deleted Profile Tile", storageGroupId: deletedProfile.dataStoreIdentifier, profileId: deletedProfile.id, createdAt: Date(timeIntervalSince1970: 22), updatedAt: Date(timeIntervalSince1970: 22))
        ])
        var rewriteCanvasState: CanvasState? = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [
            Tile(id: rewriteTileId, kind: .browser, title: "Deleted Profile Tile", frame: TileFrame(x: 0, y: 0, width: 800, height: 600), zIndex: 0, runtimeRef: nil, metadata: TileMetadata(url: deleteRewriteURLString, browserProfileId: deletedProfile.id)),
            Tile(id: rewriteCanvasOnlyTileId, kind: .browser, title: "Canvas Only", frame: TileFrame(x: 10, y: 10, width: 800, height: 600), zIndex: 1, runtimeRef: nil, metadata: TileMetadata(url: deleteRewriteURLString, browserProfileId: deletedProfile.id))
        ], groups: [], lastActiveTileId: rewriteTileId)
        let deleteRewrite = BrowserProfilePersistenceActions.deleteProfile(
            id: deletedProfile.id,
            in: &persistedRegistry,
            browserState: &rewriteBrowserState,
            canvasState: &rewriteCanvasState,
            now: Date(timeIntervalSince1970: 23)
        )
        try expect(deleteRewrite.registryDeleted, "profile delete helper removes custom profile")
        try registryStore.save(persistedRegistry)
        persistedRegistry = try registryStore.loadOrEmpty()
        try expect(!persistedRegistry.settings.browserProfiles.contains(where: { $0.id == deletedProfile.id }), "deleted profile is absent after registry store reload")
        try expect(rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.profileId == BrowserProfile.defaultProfileId, "delete rewrite falls persisted browser tile back to Default profile")
        try expect(rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.storageGroupId == BrowserProfile.defaultDataStoreIdentifier, "delete rewrite falls persisted browser tile storage group back to Default")
        try expect(rewriteCanvasState?.tiles.first(where: { $0.id == rewriteTileId })?.metadata.browserProfileId == BrowserProfile.defaultProfileId, "delete rewrite falls canvas browser tile back to Default profile")
        try expect(rewriteCanvasState?.tiles.first(where: { $0.id == rewriteCanvasOnlyTileId })?.metadata.browserProfileId == BrowserProfile.defaultProfileId, "delete rewrite covers canvas-only existing browser tile")
        var defaultDeleteBrowserState: BrowserState? = nil
        var defaultDeleteCanvasState: CanvasState? = nil
        let defaultDelete = BrowserProfilePersistenceActions.deleteProfile(id: BrowserProfile.defaultProfileId, in: &persistedRegistry, browserState: &defaultDeleteBrowserState, canvasState: &defaultDeleteCanvasState)
        try expect(!defaultDelete.registryDeleted, "profile delete refuses Default")

        func runLoopUntil(_ done: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return done()
        }
        let fixtureBaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("continuum-profile-check-origin", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureBaseURL, withIntermediateDirectories: true)
        let fixtureURL = fixtureBaseURL.appendingPathComponent("index.html")
        try "<html><body>profile fixture</body></html>".data(using: .utf8)!.write(to: fixtureURL, options: .atomic)
        func loadFixture(_ webView: WKWebView) throws {
            webView.loadFileURL(fixtureURL, allowingReadAccessTo: fixtureBaseURL)
            try expect(runLoopUntil(!webView.isLoading), "fixture page loads")
        }
        func eval(_ js: String, in webView: WKWebView) throws -> Any? {
            var done = false
            var value: Any?
            var evalError: Error?
            webView.evaluateJavaScript(js) { result, error in
                value = result
                evalError = error
                done = true
            }
            try expect(runLoopUntil(done), "JS evaluation completes for \(js)")
            if let evalError { throw evalError }
            return value
        }

        let dataStoreA = WKWebsiteDataStore(forIdentifier: UUID(uuidString: profileA.dataStoreIdentifier)!)
        let dataStoreB = WKWebsiteDataStore(forIdentifier: UUID(uuidString: profileB.dataStoreIdentifier)!)
        let configA1 = WKWebViewConfiguration()
        configA1.websiteDataStore = dataStoreA
        var webView: WKWebView? = WKWebView(frame: .zero, configuration: configA1)
        try loadFixture(webView!)
        _ = try eval("localStorage.setItem('continuumProfileCheck','profile-a'); localStorage.getItem('continuumProfileCheck')", in: webView!)
        webView = nil

        let configA2 = WKWebViewConfiguration()
        configA2.websiteDataStore = dataStoreA
        let restoredA = WKWebView(frame: .zero, configuration: configA2)
        try loadFixture(restoredA)
        let restoredValue = try eval("localStorage.getItem('continuumProfileCheck')", in: restoredA) as? String
        try expect(restoredValue == "profile-a", "profile A localStorage persists across web view recreation")

        let configB = WKWebViewConfiguration()
        configB.websiteDataStore = dataStoreB
        let isolatedB = WKWebView(frame: .zero, configuration: configB)
        try loadFixture(isolatedB)
        let isolatedValue = try eval("localStorage.getItem('continuumProfileCheck')", in: isolatedB) as? String
        try expect(isolatedValue == nil, "profile B localStorage is isolated from profile A")

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-browser-profile-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let now = Date(timeIntervalSince1970: 10)
        let project = Project(
            id: UUID(),
            name: "browser-profile-switch-check",
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
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        let switchTileId = UUID()
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [
            Tile(
                id: switchTileId,
                kind: .browser,
                title: "Browser",
                frame: TileFrame(x: 0, y: 0, width: 800, height: 600),
                zIndex: 0,
                runtimeRef: nil,
                metadata: TileMetadata(url: fixtureURL.absoluteString, browserProfileId: profileA.id)
            )
        ], groups: [], lastActiveTileId: switchTileId))
        try store.saveBrowserState(BrowserState(tiles: [
            BrowserTile(id: UUID(), tileId: switchTileId, url: fixtureURL.absoluteString, title: "Browser", storageGroupId: profileA.dataStoreIdentifier, profileId: profileA.id, createdAt: now, updatedAt: now)
        ]))
        let switchCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let switchEngine = BrowserEngineContext()
        defer { switchEngine.shutdown() }
        let spawner = TileSpawner(
            canvasView: switchCanvas,
            ghostty: nil,
            browserEngine: switchEngine,
            projectStore: store,
            project: project,
            browserProfiles: [profileA, profileB]
        )
        let restarted: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: switchTileId) {
        case let .restarted(runtime): restarted = runtime
        case let .invalidURL(url): throw CheckError.failed("app seam rejected fixture URL: \(url)")
        case .tileNotFound: throw CheckError.failed("app seam tile missing before switch")
        case let .failure(error): throw error
        }
        let oldRuntimeId = restarted.id
        var switchRuntimeReplaced = false
        switch spawner.switchBrowserTileProfile(tileId: switchTileId, profileId: profileB.id) {
        case let .switched(oldRuntimeId: oldId, newRuntime):
            try expect(oldId == oldRuntimeId, "profile switch reports replaced runtime id")
            switchRuntimeReplaced = newRuntime.id != oldRuntimeId
            try expect(switchRuntimeReplaced, "profile switch creates a new runtime")
            newRuntime.terminate(policy: .requestClose)
        case let .unknownProfile(id): throw CheckError.failed("app seam unknown profile: \(id)")
        case let .invalidURL(url): throw CheckError.failed("app seam rejected switch URL: \(url)")
        case .tileNotFound: throw CheckError.failed("app seam tile missing during switch")
        case let .failure(error): throw error
        }
        let switchedTile = try store.loadBrowserState().tiles.first(where: { $0.tileId == switchTileId })
        try expect(switchedTile?.profileId == profileB.id, "app seam persists selected profile id")
        try expect(switchedTile?.storageGroupId == profileB.dataStoreIdentifier, "app seam persists selected storage group")
        try expect(switchCanvas.canvasState.tiles.first(where: { $0.id == switchTileId })?.metadata.browserProfileId == profileB.id, "app seam updates canvas metadata profile id")

        let manifest: [String: Any] = [
            "check": "browser-profile-persistence",
            "profileAId": profileA.id.uuidString,
            "profileADataStoreIdentifier": profileA.dataStoreIdentifier,
            "profileBId": profileB.id.uuidString,
            "profileBDataStoreIdentifier": profileB.dataStoreIdentifier,
            "profileIdsRoundTrip": true,
            "dataStoresDistinct": true,
            "legacyDefaultProfileFallback": true,
            "profileCreatePersistedId": createdProfile.id.uuidString,
            "profileRenamePersistedName": persistedRegistry.settings.browserProfiles.first(where: { $0.id == createdProfile.id })?.name as Any,
            "profileDeleteRegistryAbsent": !persistedRegistry.settings.browserProfiles.contains(where: { $0.id == deletedProfile.id }),
            "profileDeleteBrowserTilesRewritten": deleteRewrite.browserTileIdsRewritten.map(\.uuidString),
            "profileDeleteCanvasTilesRewritten": deleteRewrite.canvasTileIdsRewritten.map(\.uuidString),
            "profileDeleteBrowserFallbackProfileId": rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.profileId.uuidString as Any,
            "profileDeleteBrowserFallbackStorageGroupId": rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.storageGroupId as Any,
            "profileDeleteCanvasOnlyFallbackProfileId": rewriteCanvasState?.tiles.first(where: { $0.id == rewriteCanvasOnlyTileId })?.metadata.browserProfileId?.uuidString as Any,
            "profileALocalStorageAfterRecreate": restoredValue as Any,
            "profileBLocalStorageValue": isolatedValue as Any,
            "localStorageIsolationMeasured": isolatedValue == nil && restoredValue == "profile-a",
            "appProfileSwitchRuntimeReplaced": switchRuntimeReplaced,
            "appProfileSwitchPersistedProfileId": switchedTile?.profileId.uuidString as Any,
            "appProfileSwitchPersistedStorageGroupId": switchedTile?.storageGroupId as Any
        ]
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("browser-profile-persistence", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
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
        var runtimeToClose: WKWebViewBrowserRuntime?
        defer {
            runtimeToClose?.terminate(policy: .requestClose)
            browserEngine.shutdown()
        }

        let browserTileView = canvas.tileView(for: tileId) as? BrowserTileNSView
        let snapshotImage = NSImage(size: NSSize(width: 80, height: 60))
        snapshotImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 60).fill()
        snapshotImage.unlockFocus()
        do {
            try spawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: snapshotImage)
        } catch {
            throw CheckError.failed("installBrowserSnapshotTile failed: \(error)")
        }
        let installedSnapshot = true
        let snapshotTileView = canvas.tileView(for: tileId) as? BrowserSnapshotTileNSView
        let snapshotCanvasTile = canvas.canvasState.tiles.first(where: { $0.id == tileId })
        let snapshotContainsWKWebView = snapshotTileView?.subviews.contains { subview in
            String(describing: type(of: subview)).contains("WKWebView")
        } ?? false
        let postSnapshotState = try store.loadBrowserState()
        let postSnapshotEntry = postSnapshotState.tiles.first(where: { $0.tileId == tileId })
        let rehydratedRuntime: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(created):
            rehydratedRuntime = created
            runtimeToClose = created
        case let .invalidURL(url):
            throw CheckError.failed("rehydrate rejected snapshot URL: \(url)")
        case .tileNotFound:
            throw CheckError.failed("rehydrate did not find snapshotted tile")
        case let .failure(error):
            throw CheckError.failed("rehydrate failed: \(error)")
        }
        let rehydratedTileView = canvas.tileView(for: tileId) as? BrowserTileNSView
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
            "snapshotInstalled": installedSnapshot,
            "snapshotViewPresent": snapshotTileView != nil,
            "snapshotCanvasRuntimeRefCleared": snapshotCanvasTile?.runtimeRef == nil,
            "snapshotContainsWKWebView": snapshotContainsWKWebView,
            "postSnapshotBrowserStateUrl": postSnapshotEntry?.url as Any,
            "postSnapshotBrowserStateTitle": postSnapshotEntry?.title as Any,
            "rehydratedViewPresent": rehydratedTileView != nil,
            "rehydratedRuntimeUrl": rehydratedRuntime.url,
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
        try expect(installedSnapshot, "dehydrate should install a browser snapshot tile")
        try expect(snapshotTileView != nil, "dehydrate should replace live browser view with BrowserSnapshotTileNSView")
        try expect(snapshotCanvasTile?.runtimeRef == nil, "snapshot canvas tile should not reference a live runtime")
        try expect(!snapshotContainsWKWebView, "snapshot tile should not retain a WKWebView descendant")
        try expect(postSnapshotEntry?.url == browserStateURL, "dehydrate should persist BrowserState URL before terminating runtime")
        try expect(rehydratedTileView != nil, "rehydrate should reinstall live BrowserTileNSView")
        try expect(rehydratedRuntime.url == browserStateURL, "rehydrate should restore URL from BrowserState")
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

    static func runNoteFileTileSpawnSelfCheck() throws -> URL {
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
            .appendingPathComponent("continuum-note-file-spawn-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let sampleFile = tempRoot.appendingPathComponent("sample.txt")
        try Data("file tile ok".utf8).write(to: sampleFile)

        let now = Date()
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000008FF")!,
            name: "note-file-spawn-check",
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
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil
        ))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )

        let noteId: UUID
        let noteTileId: UUID
        switch spawner.spawnNote(title: "QA Note") {
        case let .spawned(createdNoteId, createdTileId):
            noteId = createdNoteId
            noteTileId = createdTileId
        case let .failure(error):
            throw CheckError.failed("spawnNote failed: \(error)")
        }
        guard let noteView = canvas.tileView(for: noteTileId) as? NoteTileNSView else {
            throw CheckError.failed("spawnNote did not install NoteTileNSView")
        }
        noteView.textView.string = "note body ok"
        spawner.writeNoteSnapshot(noteId: noteId, tileId: noteTileId, text: noteView.textView.string)

        let fileTileId: UUID
        switch spawner.spawnFile(path: sampleFile.path, title: nil) {
        case let .spawned(createdTileId):
            fileTileId = createdTileId
        case .invalidPath:
            throw CheckError.failed("spawnFile rejected valid path")
        case let .failure(error):
            throw CheckError.failed("spawnFile failed: \(error)")
        }
        guard let fileView = canvas.tileView(for: fileTileId) as? FileTileNSView else {
            throw CheckError.failed("spawnFile did not install FileTileNSView")
        }

        let canvasOnDisk = try store.loadCanvas()
        let noteState = try store.loadNoteState()
        let noteBody = store.tryLoadNoteBody(id: noteId)
        let noteTile = canvasOnDisk.tiles.first(where: { $0.id == noteTileId })
        let fileTile = canvasOnDisk.tiles.first(where: { $0.id == fileTileId })
        let noteIndex = noteState.tiles.first(where: { $0.id == noteId })

        let manifest: [String: Any] = [
            "check": "note-file-tile-spawn",
            "tempProjectRoot": tempRoot.path,
            "noteId": noteId.uuidString,
            "noteTileId": noteTileId.uuidString,
            "fileTileId": fileTileId.uuidString,
            "noteViewInstalled": true,
            "fileViewInstalled": true,
            "fileViewText": fileView.textView.string,
            "noteBody": noteBody as Any,
            "canvasTileKinds": canvasOnDisk.tiles.map { $0.kind.rawValue }
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("note-file-tile-spawn", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)

        try expect(noteView.noteId == noteId, "NoteTileNSView should expose spawned noteId")
        try expect(noteTile?.kind == .note, "canvas should persist note tile")
        try expect(noteTile?.metadata.noteId == noteId, "canvas note metadata should persist noteId")
        try expect(noteIndex?.tileId == noteTileId, "note index should point at spawned tile")
        try expect(noteBody == "note body ok", "writeNoteSnapshot should persist note body")
        try expect(fileTile?.kind == .file, "canvas should persist file tile")
        try expect(fileTile?.metadata.filePath == sampleFile.path, "file tile metadata should persist selected path")
        try expect(fileView.textView.string == "file tile ok", "FileTileNSView should load UTF-8 preview text")

        return artifact
    }

    static func runSpawnPlacementSelfCheck() throws -> URL {
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
            .appendingPathComponent("continuum-spawn-placement-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let project = Project(
            id: UUID(),
            name: "spawn-placement-check",
            rootPath: tempRoot.path,
            createdAt: Date(),
            updatedAt: Date(),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        let activeZone = ZonePlacement(
            zoneId: UUID(),
            projectId: project.id,
            origin: ZonePoint(x: 1000, y: 500),
            size: ZoneSize(width: 1800, height: 900),
            color: "#6E8BFF",
            collapsed: false,
            hydrationPolicy: .automatic
        )
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 900, y: 400, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas(), activeZone: activeZone)
        canvas.setFrameSize(CGSize(width: 1800, height: 900))
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: project)

        var spawnedIds: [UUID] = []
        for index in 1...4 {
            switch spawner.spawnNote(title: "Placed \(index)") {
            case let .spawned(_, tileId): spawnedIds.append(tileId)
            case let .failure(error): throw CheckError.failed("spawnNote \(index) failed: \(error)")
            }
        }
        let tiles = canvas.canvasState.tiles.filter { spawnedIds.contains($0.id) }
        try expect(tiles.count == 4, "spawn-placement check should find all 4 spawned tiles in canvas state, got \(tiles.count)")
        let rects = tiles.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
        for rect in rects {
            try expect(rect.minX >= 0 && rect.minY >= 0, "spawned tile frame should be zone-local, not world-offset: \(rect)")
            try expect(rect.maxX <= activeZone.size.width && rect.maxY <= activeZone.size.height, "spawned tile frame should fit inside active zone bounds: \(rect)")
            let worldRect = rect.offsetBy(dx: activeZone.origin.x, dy: activeZone.origin.y)
            try expect(worldRect.minX >= activeZone.origin.x && worldRect.minY >= activeZone.origin.y, "rendered world frame should land inside active zone: \(worldRect)")
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                try expect(!rects[i].intersects(rects[j]), "spawned tile frames should not intersect: \(rects[i]) vs \(rects[j])")
            }
        }

        let manifest: [String: Any] = [
            "check": "spawn-placement",
            "tempProjectRoot": tempRoot.path,
            "activeZone": ["originX": activeZone.origin.x, "originY": activeZone.origin.y, "width": activeZone.size.width, "height": activeZone.size.height],
            "frames": tiles.map { ["id": $0.id.uuidString, "x": $0.frame.x, "y": $0.frame.y, "width": $0.frame.width, "height": $0.frame.height] }
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("spawn-placement", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - File tree tiles

    func spawnFileTree(rootPath: String, at worldPoint: CGPoint? = nil) -> FileTreeOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRootPath.isEmpty else { return .invalidPath }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedRootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .invalidPath
        }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .fileTree),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        let tile = Tile(
            id: UUID(),
            kind: .fileTree,
            title: URL(fileURLWithPath: trimmedRootPath, isDirectory: true).lastPathComponent,
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(filePath: URL(fileURLWithPath: trimmedRootPath, isDirectory: true).standardizedFileURL.path)
        )
        let fileTreeTile = defaultFileTreeTile(tileId: tile.id, rootPath: trimmedRootPath)
        do {
            try upsertFileTreeTile(fileTreeTile)
        } catch {
            return .failure(error)
        }

        let viewModel = installFileTreeView(tile, fileTreeTile: fileTreeTile, in: canvasView)
        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(tileId: tile.id, viewModel: viewModel)
    }

    func restartFileTreeTile(tileId: UUID) -> FileTreeRestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard var existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }

        switch validatedFileTreeTile(for: existing) {
        case let .valid(fileTreeTile, backfilledDescriptorRoot):
            if let backfilledDescriptorRoot {
                existing.metadata.filePath = backfilledDescriptorRoot
                canvasView.updateTile(existing)
            }
            do {
                try upsertFileTreeTile(fileTreeTile)
                try projectStore.saveCanvas(canvasView.canvasState)
            } catch {
                return .failure(error)
            }
            let viewModel = installFileTreeView(existing, fileTreeTile: fileTreeTile, in: canvasView)
            return .restarted(viewModel)
        case let .recoverableError(fileTreeTile, message):
            let viewModel = installFileTreeErrorView(existing, fileTreeTile: fileTreeTile, message: message, in: canvasView)
            return .restarted(viewModel)
        }
    }

    func writeFileTreeTileSnapshot(for view: FileTreeTileNSView) {
        guard !view.isRecoverableError else { return }
        try? upsertFileTreeTile(view.currentFileTreeTile)
    }

    private func installFileTreeView(
        _ tile: Tile,
        fileTreeTile: FileTreeTile,
        in canvasView: CanvasNSView
    ) -> FileTreeViewModel {
        let viewModel = FileTreeViewModel()
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, viewModel: viewModel)
        view.onPersist = { [weak self] _ in
            self?.fileTreePersistenceHandler?()
        }
        view.onSpawnFile = { [weak self] path in
            _ = self?.spawnFile(path: path, title: URL(fileURLWithPath: path).lastPathComponent)
        }
        view.onOpenFile = { [weak self] path in
            self?.openFileInPreferredEditor(path: path)
        }
        canvasView.install(tileView: view, for: tile)
        return viewModel
    }

    private func installFileTreeErrorView(
        _ tile: Tile,
        fileTreeTile: FileTreeTile,
        message: String,
        in canvasView: CanvasNSView
    ) -> FileTreeViewModel {
        let viewModel = FileTreeViewModel()
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, recoverableErrorMessage: message)
        canvasView.install(tileView: view, for: tile)
        return viewModel
    }

    private func defaultFileTreeTile(tileId: UUID, rootPath: String) -> FileTreeTile {
        FileTreeTile(
            tileId: tileId,
            rootPath: rootPath,
            expandedPaths: [],
            selectedPath: nil,
            searchQuery: "",
            ignoredNames: Array(FileTreeScanner.defaultIgnoredNames).sorted(),
            gitBadges: .off
        )
    }

    func openFileInPreferredEditor(path: String) {
        if launchPreferredEditor(path: path) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: false))
    }

    private enum FileTreeValidationOutcome {
        case valid(FileTreeTile, backfilledDescriptorRoot: String?)
        case recoverableError(FileTreeTile, message: String)
    }

    private func validatedFileTreeTile(for tile: Tile) -> FileTreeValidationOutcome {
        let descriptorRoot = tile.metadata.filePath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        do {
            guard let state = try projectStore.tryLoadFileTreeState() else {
                let kind = FileManager.default.fileExists(atPath: projectStore.layout.fileTreeIndexFile.path)
                    ? "corrupt"
                    : "missing"
                return .recoverableError(
                    defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot ?? project.rootPath),
                    message: fileTreeValidationMessage(kind: kind, expectedRoot: descriptorRoot)
                )
            }
            guard let fileTreeTile = state.tiles.first(where: { $0.tileId == tile.id }) else {
                return .recoverableError(
                    defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot ?? project.rootPath),
                    message: fileTreeValidationMessage(kind: "missing tile entry", expectedRoot: descriptorRoot)
                )
            }
            let sidecarRoot = URL(fileURLWithPath: fileTreeTile.rootPath, isDirectory: true).standardizedFileURL.path
            if let descriptorRoot, sidecarRoot != descriptorRoot {
                return .recoverableError(
                    defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot),
                    message: fileTreeValidationMessage(kind: "root mismatch", expectedRoot: descriptorRoot, actualRoot: sidecarRoot)
                )
            }
            return .valid(fileTreeTile, backfilledDescriptorRoot: descriptorRoot == nil ? sidecarRoot : nil)
        } catch {
            return .recoverableError(
                defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot ?? project.rootPath),
                message: fileTreeValidationMessage(kind: "corrupt", expectedRoot: descriptorRoot, detail: error.localizedDescription)
            )
        }
    }

    private func fileTreeValidationMessage(
        kind: String,
        expectedRoot: String?,
        actualRoot: String? = nil,
        detail: String? = nil
    ) -> String {
        var message = "File tree state \(kind)."
        if let expectedRoot {
            message += " Expected root: \(expectedRoot)."
        }
        if let actualRoot {
            message += " Sidecar root: \(actualRoot)."
        }
        if let detail {
            message += " \(detail)"
        }
        message += " This is recoverable: remove/recreate the file-tree tile or repair .continuum-revived/file-tree/index.json."
        return message
    }

    private func existingFileTreeTile(for tileId: UUID) -> FileTreeTile? {
        guard let state = try? projectStore.tryLoadFileTreeState() else {
            return nil
        }
        return state.tiles.first { $0.tileId == tileId }
    }

    private func upsertFileTreeTile(_ fileTreeTile: FileTreeTile) throws {
        var state = (try? projectStore.tryLoadFileTreeState()) ?? FileTreeState(tiles: [])
        if let index = state.tiles.firstIndex(where: { $0.tileId == fileTreeTile.tileId }) {
            state.tiles[index] = fileTreeTile
        } else {
            state.tiles.append(fileTreeTile)
        }
        try projectStore.saveFileTreeState(state)
    }

    static func runFileTreeBootPersistenceSelfCheck() throws -> URL {
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
            .appendingPathComponent("continuum-file-tree-boot-persistence-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot.appendingPathComponent("Sources/Deep", isDirectory: true), withIntermediateDirectories: true)
        try Data("needle\n".utf8).write(to: projectRoot.appendingPathComponent("Sources/Deep/Needle.swift"), options: .atomic)

        let now = Date()
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000F02")!,
            name: "file-tree-boot-persistence-check",
            rootPath: projectRoot.path,
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
        let store = ProjectStore(projectRoot: projectRoot)
        try store.saveProject(project)

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000F03")!
        let tile = Tile(
            id: tileId,
            kind: .fileTree,
            title: "project",
            frame: TileFrame(x: 20, y: 20, width: 420, height: 360),
            zIndex: 7,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 13, y: 21, zoom: 1.25),
            tiles: [tile],
            groups: [],
            lastActiveTileId: tileId
        ))
        try store.saveFileTreeState(FileTreeState(tiles: [FileTreeTile(
            tileId: tileId,
            rootPath: projectRoot.path,
            expandedPaths: ["Sources"],
            selectedPath: "Sources/Deep/Needle.swift",
            searchQuery: "Needle.swift",
            ignoredNames: [".git", "node_modules"],
            gitBadges: .off
        )]))

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let firstCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let firstSpawner = TileSpawner(
            canvasView: firstCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        switch firstSpawner.restartFileTreeTile(tileId: tileId) {
        case .restarted:
            break
        case .tileNotFound:
            throw CheckError.failed("first boot did not find file-tree tile")
        case let .failure(error):
            throw CheckError.failed("first boot failed: \(error)")
        }
        guard let firstView = firstCanvas.tileView(for: tileId) as? FileTreeTileNSView else {
            throw CheckError.failed("first boot did not install FileTreeTileNSView")
        }
        firstView.currentFileTreeTile.expandedPaths.forEach { _ in }
        firstSpawner.writeFileTreeTileSnapshot(for: firstView)
        try store.saveCanvas(firstCanvas.canvasState)

        let secondCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let secondSpawner = TileSpawner(
            canvasView: secondCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        switch secondSpawner.restartFileTreeTile(tileId: tileId) {
        case .restarted:
            break
        case .tileNotFound:
            throw CheckError.failed("relaunch did not find file-tree tile")
        case let .failure(error):
            throw CheckError.failed("relaunch failed: \(error)")
        }
        guard let secondView = secondCanvas.tileView(for: tileId) as? FileTreeTileNSView else {
            throw CheckError.failed("relaunch did not install FileTreeTileNSView")
        }
        let persisted = try store.loadFileTreeState().tiles.first { $0.tileId == tileId }
        try expect(secondCanvas.canvasState.tiles.first?.kind == .fileTree, "relaunch canvas should retain file-tree tile kind")
        try expect(secondCanvas.canvasState.tiles.first?.runtimeRef == nil, "file-tree tile should not gain a runtimeRef")
        try expect(persisted?.rootPath == projectRoot.path, "file-tree state should retain root path")
        try expect(persisted?.expandedPaths == ["Sources"], "file-tree state should retain expanded paths")
        try expect(persisted?.selectedPath == "Sources/Deep/Needle.swift", "file-tree state should retain selected path")
        try expect(persisted?.searchQuery == "Needle.swift", "file-tree state should retain search query")
        try expect(secondView.currentFileTreeTile == persisted, "relaunch view should use persisted file-tree tile state")

        let searchManifest = try FileTreeTileNSView.runSearchVisibilitySelfCheck()
        let debounceManifest = try FileTreeTileNSView.runDebounceFlushSelfCheck()
        let manifest: [String: Any] = [
            "check": "file-tree-boot-persistence",
            "tempProjectRoot": projectRoot.path,
            "tileId": tileId.uuidString,
            "firstBootInstalled": true,
            "relaunchInstalled": true,
            "persistedRootPath": persisted?.rootPath as Any,
            "persistedExpandedPaths": persisted?.expandedPaths ?? [],
            "persistedSelectedPath": persisted?.selectedPath as Any,
            "persistedSearchQuery": persisted?.searchQuery as Any,
            "searchVisibility": searchManifest,
            "debounceFlush": debounceManifest
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("file-tree-boot-persistence", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runFileTreeHardeningSelfCheck() throws -> URL {
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
            .appendingPathComponent("continuum-file-tree-hardening-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let now = Date()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000001121")!
        let descriptorRoot = tempRoot.appendingPathComponent("descriptor-root", isDirectory: true)
        let wrongRoot = tempRoot.appendingPathComponent("wrong-root", isDirectory: true)
        try fileManager.createDirectory(at: descriptorRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrongRoot, withIntermediateDirectories: true)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        func makeProjectStore(named name: String) throws -> (Project, ProjectStore, CanvasNSView, TileSpawner) {
            let projectRoot = tempRoot.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let project = Project(
                id: UUID(),
                name: name,
                rootPath: projectRoot.path,
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
            let store = ProjectStore(projectRoot: projectRoot)
            try store.saveProject(project)
            let tile = Tile(
                id: tileId,
                kind: .fileTree,
                title: "descriptor-root",
                frame: TileFrame(x: 20, y: 20, width: 420, height: 360),
                zIndex: 1,
                runtimeRef: nil,
                metadata: TileMetadata(filePath: descriptorRoot.path)
            )
            try store.saveCanvas(CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [tile],
                groups: [],
                lastActiveTileId: tileId
            ))
            let canvas = CanvasNSView(canvasState: try store.loadCanvas())
            let spawner = TileSpawner(
                canvasView: canvas,
                ghostty: nil,
                browserEngine: browserEngine,
                projectStore: store,
                project: project
            )
            return (project, store, canvas, spawner)
        }

        func runScenario(_ name: String, seed: (ProjectStore) throws -> Void) throws -> [String: Any] {
            let (project, store, canvas, spawner) = try makeProjectStore(named: name)
            try seed(store)
            let sidecarBefore = try? Data(contentsOf: store.layout.fileTreeIndexFile)
            switch spawner.restartFileTreeTile(tileId: tileId) {
            case .restarted:
                break
            case .tileNotFound:
                throw CheckError.failed("\(name): tile not found")
            case let .failure(error):
                throw CheckError.failed("\(name): restart failed: \(error)")
            }
            guard let view = canvas.tileView(for: tileId) as? FileTreeTileNSView else {
                throw CheckError.failed("\(name): did not install file-tree view")
            }
            spawner.writeFileTreeTileSnapshot(for: view)
            let sidecarAfter = try? Data(contentsOf: store.layout.fileTreeIndexFile)
            let persisted = try? store.tryLoadFileTreeState()?.tiles.first(where: { $0.tileId == tileId })
            let didFallbackToProjectRoot = persisted?.rootPath == project.rootPath
            let didStartScannerForWrongRoot = view.currentSnapshot?.root.path == wrongRoot.path || view.currentSnapshot?.root.path == project.rootPath
            try expect(view.isRecoverableError, "\(name): should install recoverable error tile")
            try expect(view.currentSnapshot == nil, "\(name): should not scan while sidecar is invalid")
            try expect(!didFallbackToProjectRoot, "\(name): should not fall back to project root")
            try expect(!didStartScannerForWrongRoot, "\(name): should not start scanner for wrong root")
            if let sidecarBefore {
                try expect(sidecarAfter == sidecarBefore, "\(name): should not overwrite invalid sidecar")
            } else {
                try expect(sidecarAfter == nil, "\(name): should not create sidecar from missing invalid state")
            }
            return [
                "scenario": name,
                "errorKind": view.recoverableErrorMessage ?? "",
                "didInstallRecoverableTile": view.isRecoverableError,
                "didFallbackToProjectRoot": didFallbackToProjectRoot,
                "didStartScannerForWrongRoot": didStartScannerForWrongRoot,
                "sidecarUnchanged": sidecarAfter == sidecarBefore
            ]
        }

        let scenarios: [[String: Any]] = try [
            runScenario("missing-sidecar") { _ in },
            runScenario("corrupt-sidecar") { store in
                try fileManager.createDirectory(at: store.layout.fileTreeDirectory, withIntermediateDirectories: true)
                try Data("{ not-json".utf8).write(to: store.layout.fileTreeIndexFile, options: .atomic)
            },
            runScenario("missing-tile-entry") { store in
                try store.saveFileTreeState(FileTreeState(tiles: []))
            },
            runScenario("mismatched-root") { store in
                try store.saveFileTreeState(FileTreeState(tiles: [FileTreeTile(
                    tileId: tileId,
                    rootPath: wrongRoot.path,
                    expandedPaths: [],
                    selectedPath: nil,
                    searchQuery: "",
                    ignoredNames: [],
                    gitBadges: .off
                )]))
            }
        ]

        let manifest: [String: Any] = [
            "check": "file-tree-hardening",
            "debounceFlush": try FileTreeTileNSView.runDebounceFlushSelfCheck(),
            "truncatedOutline": try FileTreeTileNSView.runTruncatedOutlineSelfCheck(),
            "sidecarValidation": scenarios
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("file-tree-hardening", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    private func launchPreferredEditor(path: String) -> Bool {
        guard let spec = registry.spec(for: "nvim") else {
            return false
        }
        let resolution = registry.resolve(
            spec,
            in: project.rootPath,
            environment: ProcessInfo.processInfo.environment,
            detector: detector
        )
        guard case let .found(profile) = resolution else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: profile.command, isDirectory: false)
        process.currentDirectoryURL = URL(fileURLWithPath: profile.cwd, isDirectory: true)
        process.arguments = editorArguments(from: profile.arguments, path: path)
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func editorArguments(from arguments: [String], path: String) -> [String] {
        if let index = arguments.firstIndex(of: ".") {
            var patched = arguments
            patched[index] = path
            return patched
        }
        return arguments + [path]
    }

    private func makePlacement(worldPoint: CGPoint?, size: CGSize, in canvasView: CanvasNSView) -> TileFrame {
        if let worldPoint {
            return TileFrame(
                x: Double(worldPoint.x) - Double(size.width) / 2,
                y: Double(worldPoint.y) - Double(size.height) / 2,
                width: Double(size.width),
                height: Double(size.height)
            )
        }
        var placementViewport = canvasView.viewport
        var placementVisibleSize = canvasView.bounds.size
        if let activeZone = canvasView.activeZone {
            let zoom = canvasView.viewport.zoom.isFinite && canvasView.viewport.zoom > 0 ? canvasView.viewport.zoom : 1
            let localX = canvasView.viewport.x - activeZone.origin.x
            let localY = canvasView.viewport.y - activeZone.origin.y
            let maxOriginX = max(0, activeZone.size.width - Double(size.width))
            let maxOriginY = max(0, activeZone.size.height - Double(size.height))
            let clampedX = min(max(localX, 0), maxOriginX)
            let clampedY = min(max(localY, 0), maxOriginY)
            let visibleWidth = max(Double(canvasView.bounds.width) / zoom, Double(size.width))
            let visibleHeight = max(Double(canvasView.bounds.height) / zoom, Double(size.height))
            let boundedVisibleWidth = min(visibleWidth, max(Double(size.width), activeZone.size.width - clampedX))
            let boundedVisibleHeight = min(visibleHeight, max(Double(size.height), activeZone.size.height - clampedY))
            placementViewport = CanvasViewport(x: clampedX, y: clampedY, zoom: zoom)
            placementVisibleSize = CGSize(width: boundedVisibleWidth * zoom, height: boundedVisibleHeight * zoom)
        }
        return CanvasEngine.placementFrame(
            size: size,
            viewport: placementViewport,
            visibleSize: placementVisibleSize,
            existing: canvasView.canvasState.tiles.map(\.frame)
        )
    }
}
