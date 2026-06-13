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

    func close(flushPendingWrites: () -> Void) {
        guard !isClosed else { return }
        isClosed = true

        flushPendingWrites()

        let now = Date()
        for runtime in runtimes {
            if var descriptor = try? projectStore.loadSession(id: runtime.id) {
                descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: now)
                try? projectStore.saveSession(descriptor)
            }
        }

        projectLock?.release()
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
