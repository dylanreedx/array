// Film harness: pre-boot disk staging. Writes exactly what `WorkspaceAPIChecks.makeFixture`
// writes (project, canvas with WORLD frames and zone stamps, workspace document, registry)
// plus the documents the hydrated tiles read (board, note body, file tree state, real files
// in a real git repo), so the production boot path hydrates the scene. Agent tiles are NOT
// staged: a restored agent shows a "previous session" notice, so the director spawns them
// fresh after boot through `TileSpawner`.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedCore
import ContinuumRevivedFileTree

enum FilmStager {
    struct Roots {
        /// project key -> absolute root.
        var projects: [String: URL]
        var appSupport: URL
    }

    static let stagedAt = Date(timeIntervalSince1970: 1_900_000_000)

    /// The film run's roots from the launch environment. `CONTINUUM_PROJECT_ROOT` is the
    /// FIRST project's root; the others are its siblings, named after each project, so
    /// the boot project is one the staged workspace owns. Refuses anything that could be
    /// real state (non-negotiable #1, hazard 10).
    static func liveRoots(for scene: FilmScene, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Roots {
        guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw FilmError("refusing: --film never runs from the prod bundle")
        }
        guard let support = environment["CONTINUUM_APP_SUPPORT"], let primary = environment["CONTINUUM_PROJECT_ROOT"] else {
            throw FilmError("refusing: --film needs CONTINUUM_APP_SUPPORT and CONTINUUM_PROJECT_ROOT")
        }
        let filmBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("array-scratch/film").path + "/"
        for path in [support, primary] {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard standardized.hasPrefix(filmBase), !standardized.contains("/Documents/") else {
                throw FilmError("refusing: \(path) is not under \(filmBase)")
            }
        }
        let primaryURL = URL(fileURLWithPath: primary, isDirectory: true).standardizedFileURL
        var projects: [String: URL] = [:]
        for (index, project) in scene.projects.enumerated() {
            projects[project.key] = index == 0
                ? primaryURL
                : primaryURL.deletingLastPathComponent().appendingPathComponent(project.name, isDirectory: true)
        }
        return Roots(projects: projects, appSupport: URL(fileURLWithPath: support, isDirectory: true))
    }

    static func stage(_ scene: FilmScene, roots: Roots) throws {
        let fm = FileManager.default
        for project in scene.projects {
            guard let root = roots.projects[project.key] else { throw FilmError("no root for \(project.key)") }
            // A fresh root per run: an existing `.array/` means another app could own it.
            guard !fm.fileExists(atPath: root.appendingPathComponent(".array").path) else {
                throw FilmError("refusing: \(root.path) already holds .array/ — every film run needs fresh roots")
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if let files = project.files {
                try copyContents(of: scene.resolve(files), into: root)
            }
            if let git = project.git {
                try makeRepository(at: root, scene: scene, modify: git.modify ?? [:])
            }
        }
        try fm.createDirectory(at: roots.appSupport, withIntermediateDirectories: true)

        var registry = Registry.empty()
        var workspaceProjects: [UUID] = []
        for project in scene.projects {
            let root = roots.projects[project.key]!
            let id = scene.projectId(project.key)
            workspaceProjects.append(id)
            let store = ProjectStore(projectRoot: root)
            try store.saveProject(Project(
                id: id, name: project.name, rootPath: root.path, createdAt: stagedAt, updatedAt: stagedAt,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                          terminalClosePolicy: .askWhenRunning)))
            var tiles: [Tile] = []
            var boardIndex: [BoardIndexEntry] = []
            var fileTrees: [FileTreeTile] = []
            for (rank, spec) in scene.tiles.enumerated() where spec.kind != "agent" {
                guard let zone = scene.zone(spec.zone), zone.project == project.key else { continue }
                let tileId = scene.tileId(spec.key)
                var metadata = TileMetadata()
                let kind: TileKind
                switch spec.kind {
                case "terminal":
                    kind = .terminal
                    metadata.launchProfileId = "shell"
                    metadata.projectRelativeCwd = "."
                case "browser":
                    kind = .browser
                    metadata.url = spec.url ?? "about:blank"
                case "note":
                    kind = .note
                    metadata.noteId = scene.uuid("note", spec.key)
                    try store.saveNoteBody(id: metadata.noteId!, text: spec.body ?? "")
                case "file":
                    kind = .file
                    let relative = spec.path ?? ""
                    let path = root.appendingPathComponent(relative).path
                    metadata.filePath = path
                    metadata.documentLocation = DocumentLocation(
                        path: path, scope: .checkout(projectId: id, rootPath: root.path, relativePath: relative))
                    metadata.fileEditorViewState = FileEditorViewState(sidebarExpanded: false)
                    if relative.hasSuffix(".md") { metadata.markdownDocumentMode = .preview }
                case "fileTree":
                    kind = .fileTree
                    let treeRoot = root.appendingPathComponent(spec.path ?? ".").standardizedFileURL.path
                    metadata.filePath = treeRoot
                    metadata.filesystemProjectId = id
                    metadata.filesystemCheckoutRootPath = root.path
                    metadata.filesystemWherePath = treeRoot
                    fileTrees.append(FileTreeTile(
                        tileId: tileId, rootPath: treeRoot, expandedPaths: spec.expanded ?? [],
                        selectedPath: nil, searchQuery: "",
                        ignoredNames: (Array(FileTreeScanner.defaultIgnoredNames) + [".array"]).sorted(),
                        gitBadges: .cheap))
                case "kanban":
                    kind = .kanban
                    let boardId = scene.uuid("board", spec.key)
                    metadata.boardId = boardId
                    try store.saveBoard(makeBoard(spec, id: boardId, scene: scene))
                    boardIndex.append(BoardIndexEntry(id: boardId, tileId: tileId, title: spec.board?.title ?? spec.title ?? "Board",
                                                      createdAt: stagedAt, updatedAt: stagedAt))
                default:
                    continue
                }
                var tile = Tile(id: tileId, kind: kind, title: spec.title ?? defaultTitle(spec),
                                frame: scene.worldFrame(of: spec), zPosition: .fromLegacyRank(rank + 1),
                                runtimeRef: nil, metadata: metadata)
                tile.zoneId = scene.zoneId(zone.key)
                tiles.append(tile)
            }
            if !boardIndex.isEmpty { try store.saveBoardState(BoardState(boards: boardIndex)) }
            if !fileTrees.isEmpty { try store.saveFileTreeState(FileTreeState(tiles: fileTrees)) }
            try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: tiles,
                                             groups: [], lastActiveTileId: nil))
            registry.projects.append(ProjectEntry(id: id, name: project.name, rootPath: root.path,
                                                  workspaceId: scene.workspaceId, lastOpenedAt: stagedAt,
                                                  pinned: false, missing: false))
        }

        let zones = scene.zones.enumerated().map { index, zone in
            ZonePlacement(zoneId: scene.zoneId(zone.key), projectId: scene.projectId(zone.project),
                          origin: ZonePoint(x: zone.rect[0], y: zone.rect[1]),
                          size: ZoneSize(width: zone.rect[2], height: zone.rect[3]),
                          color: zone.color, collapsed: false,
                          // Every zone live: the wide shot shows all of them at once.
                          hydrationPolicy: .pinnedLive,
                          // Staged frames are the shot; nothing may reflow them — unless
                          // the scene turns auto-layout on, which a zone then inherits.
                          autoLayoutMode: scene.autoLayout == true ? .inherit : .disabled,
                          name: zone.name)
        }
        let primaryZone = scene.zones.first { $0.project == scene.projects[0].key }.map { scene.zoneId($0.key) }
        try WorkspaceStore(workspaceId: scene.workspaceId, applicationSupportDirectory: roots.appSupport)
            .save(WorkspaceDocument(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), zones: zones,
                                    zoneZOrder: zones.map(\.zoneId), lastActiveZoneId: primaryZone))
        registry.lastActiveWorkspaceId = scene.workspaceId
        registry.workspaces = [WorkspaceEntry(id: scene.workspaceId, name: scene.workspace, projectIds: workspaceProjects,
                                              createdAt: stagedAt, updatedAt: stagedAt)]
        try RegistryStore(applicationSupportDirectory: roots.appSupport).save(registry)
    }

    static func defaultTitle(_ spec: FilmScene.Tile) -> String {
        switch spec.kind {
        case "file": return URL(fileURLWithPath: spec.path ?? "").lastPathComponent
        case "fileTree": return spec.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Files"
        case "kanban": return spec.board?.title ?? "Board"
        case "browser": return "Browser"
        case "note": return "Note"
        default: return "Terminal"
        }
    }

    static func makeBoard(_ spec: FilmScene.Tile, id: UUID, scene: FilmScene) throws -> Board {
        guard let boardSpec = spec.board else { throw FilmError("kanban tile \(spec.key) has no board") }
        let positions = FracIndex.distribute(count: boardSpec.columns.count)
        let columns = zip(boardSpec.columns, positions).map { name, position in
            BoardColumn(id: scene.uuid("column", "\(spec.key)/\(name)"), name: name, position: position)
        }
        var cards: [BoardCard] = []
        for column in columns {
            let specs = boardSpec.cards.filter { $0.column == column.name }
            for (card, position) in zip(specs, FracIndex.distribute(count: specs.count)) {
                cards.append(BoardCard(id: scene.uuid("card", card.key), columnId: column.id, position: position,
                                       title: card.title, body: card.body ?? "", createdAt: stagedAt, updatedAt: stagedAt))
            }
        }
        guard cards.count == boardSpec.cards.count else { throw FilmError("board \(spec.key): a card names an unknown column") }
        return Board(id: id, title: boardSpec.title ?? "Board", columns: columns, cards: cards)
    }

    static func copyContents(of source: URL, into destination: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            try fm.copyItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
    }

    /// A real repository so the File Tree's git badges are real: commit the tree, then
    /// overwrite the `modify` files. Isolated from the user's git config and hooks.
    static func makeRepository(at root: URL, scene: FilmScene, modify: [String: String]) throws {
        let date = "2030-03-17T12:00:00Z"
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                 "-c", "init.defaultBranch=main"] + arguments
            process.currentDirectoryURL = root
            process.environment = [
                "PATH": "/usr/bin:/bin", "HOME": root.path,
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "Array Film", "GIT_AUTHOR_EMAIL": "film@arrayapp.dev",
                "GIT_COMMITTER_NAME": "Array Film", "GIT_COMMITTER_EMAIL": "film@arrayapp.dev",
                "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw FilmError("git \(arguments.joined(separator: " ")) failed in \(root.path)") }
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "Initial commit"])
        let exclude = root.appendingPathComponent(".git/info/exclude")
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(".array/\n".utf8).write(to: exclude)
        for (relative, source) in modify.sorted(by: { $0.key < $1.key }) {
            let target = root.appendingPathComponent(relative)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: scene.resolve(source), to: target)
        }
    }
}
#endif
