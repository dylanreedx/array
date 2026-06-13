import ContinuumRevivedCore
import Foundation

@MainActor
final class ZoneRuntimeController {
    let projectRoot: URL
    let projectStore: ProjectStore
    private(set) var project: Project

    var runtimes: [GhosttyTerminalRuntime] = []
    var browserRuntimes: [WKWebViewBrowserRuntime] = []
    var noteViews: [UUID: NoteTileNSView] = [:]
    var fileTreeViews: [UUID: FileTreeTileNSView] = [:]

    weak var canvasView: CanvasNSView?
    weak var tileSpawner: TileSpawner?

    private var saveTimer: Timer?
    private var browserSaveTimer: Timer?
    private var noteSaveTimer: Timer?
    private var fileTreeSaveTimer: Timer?

    private let projectLock: ProjectLock?
    private var isClosed = false

    init(root projectRoot: URL) throws {
        self.projectRoot = projectRoot
        let projectLock = ProjectLock(root: projectRoot)
        try projectLock.acquire()
        self.projectLock = projectLock

        let projectStore = ProjectStore(projectRoot: projectRoot)
        self.projectStore = projectStore

        pruneExitedSessions(in: projectStore)
        self.project = try Self.loadOrCreateProject(in: projectStore, projectRoot: projectRoot)
    }

    init(projectRoot: URL, projectStore: ProjectStore, project: Project) {
        self.projectRoot = projectRoot
        self.projectStore = projectStore
        self.project = project
        self.projectLock = nil
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

        flushPendingSaves()

        let now = Date()
        for runtime in runtimes {
            if var descriptor = try? projectStore.loadSession(id: runtime.id) {
                descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: now)
                try? projectStore.saveSession(descriptor)
            }
        }

        projectLock?.release()
    }

    func scheduleCanvasSave() {
        // Coalesce drag-rate writes: schedule a save after the last change.
        // flushPendingSaves() runs immediately for project switch and close.
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushCanvasSave() }
        }
    }

    func scheduleBrowserSave() {
        // Browser url/title changes coalesce identically to canvas drags.
        browserSaveTimer?.invalidate()
        browserSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushBrowserSave() }
        }
    }

    func scheduleNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushNoteSave() }
        }
    }

    func scheduleFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushFileTreeSave() }
        }
    }

    func flushPendingSaves() {
        flushCanvasSave()
        flushBrowserSave()
        flushNoteSave()
        flushFileTreeSave()
    }

    func flushCanvasSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let canvasView else { return }
        try? projectStore.saveCanvas(canvasView.canvasState)
    }

    func flushBrowserSave() {
        browserSaveTimer?.invalidate()
        browserSaveTimer = nil
        guard let tileSpawner else { return }
        for runtime in browserRuntimes {
            tileSpawner.writeBrowserTileSnapshot(for: runtime)
        }
    }

    func flushNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        guard let tileSpawner else { return }
        for view in noteViews.values {
            tileSpawner.writeNoteSnapshot(noteId: view.noteId, tileId: view.tile.id, text: view.textView.string)
        }
    }

    func flushFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = nil
        guard let tileSpawner else { return }
        for view in fileTreeViews.values {
            tileSpawner.writeFileTreeTileSnapshot(for: view)
        }
    }

    private static func loadOrCreateProject(in store: ProjectStore, projectRoot: URL) throws -> Project {
        if let existing = try store.tryLoadProject() {
            return existing
        }
        let now = Date()
        let project = Project(
            name: projectRoot.lastPathComponent,
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
        try store.saveProject(project)
        return project
    }
}
