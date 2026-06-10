import ContinuumRevivedCore
import CoreGraphics
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func approximatelyEqual(_ a: CGPoint, _ b: CGPoint, tolerance: Double = 0.001) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

do {
    let resolver = ShellLaunchResolver(environment: ["SHELL": "/bin/zsh"])
    let profile = try resolver.resolveShell(cwd: "/tmp/continuum")
    expect(profile.command == "/bin/zsh", "resolver should prefer SHELL")
    expect(profile.arguments == [], "shell profile should not add arguments")
    expect(profile.cwd == "/tmp/continuum", "shell profile should preserve cwd")
    expect(profile.title == "Shell", "shell profile title should be Shell")
}

do {
    let resolver = ShellLaunchResolver(environment: [:])
    let profile = try resolver.resolveShell(cwd: "/tmp/continuum")
    expect(profile.command == "/bin/zsh", "resolver should fall back to /bin/zsh")
}

do {
    var state = TerminalRuntimeState(status: .configuring)
    state.markRunning()
    expect(state.status == .running, "state should mark running")
    state.markExited(exitCode: 0)
    expect(state.status == .exited(exitCode: 0), "state should mark exited")
    state.markError("spawn failed")
    expect(state.status == .error(message: "spawn failed"), "state should mark errors")
}

// MARK: - JSONCodec

do {
    let encoder = JSONCodec.makeEncoder()
    let decoder = JSONCodec.makeDecoder()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    struct Sample: Codable, Equatable { let when: Date }
    let data = try encoder.encode(Sample(when: date))
    let json = String(data: data, encoding: .utf8) ?? ""
    expect(json.contains("2023-11-14T22:13:20Z"), "JSONCodec should encode dates as ISO8601 UTC, got: \(json)")
    let decoded = try decoder.decode(Sample.self, from: data)
    expect(decoded.when == date, "JSONCodec date round trip")
}

// MARK: - Project round trip

do {
    let project = Project(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "continuum-revived",
        rootPath: "/tmp/continuum-revived",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
        defaultLaunchProfileId: "shell",
        editorPreference: .auto,
        settings: ProjectSettings(
            restorePolicy: .restoreDescriptors,
            browserStoragePolicy: .perProject,
            terminalClosePolicy: .askWhenRunning
        )
    )
    let data = try JSONCodec.makeEncoder().encode(project)
    let decoded = try JSONCodec.makeDecoder().decode(Project.self, from: data)
    expect(decoded == project, "Project round trip")
    expect(decoded.schemaVersion == Project.currentSchemaVersion, "Project schema version preserved")
    let json = String(data: data, encoding: .utf8) ?? ""
    expect(json.contains("\"schemaVersion\":1"), "Project encodes schemaVersion as 1")
    expect(json.contains("\"rootPath\":\"/tmp/continuum-revived\""), "Project encodes rootPath verbatim")
}

// MARK: - CanvasState round trip

do {
    let tileId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let groupId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let canvas = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1.0),
        tiles: [
            Tile(
                id: tileId,
                kind: .terminal,
                title: "Claude Code",
                frame: TileFrame(x: 80, y: 80, width: 900, height: 620),
                zIndex: 10,
                runtimeRef: RuntimeRef(kind: .terminalSession, id: sessionId),
                metadata: TileMetadata(
                    launchProfileId: "claude",
                    projectRelativeCwd: "."
                )
            )
        ],
        groups: [
            TileGroup(
                id: groupId,
                title: "Feature Build",
                tileIds: [tileId],
                color: "blue",
                collapsed: false
            )
        ],
        lastActiveTileId: tileId
    )
    let data = try JSONCodec.makeEncoder().encode(canvas)
    let decoded = try JSONCodec.makeDecoder().decode(CanvasState.self, from: data)
    expect(decoded == canvas, "CanvasState round trip")
    expect(decoded.schemaVersion == CanvasState.currentSchemaVersion, "Canvas schema version preserved")
    let json = String(data: data, encoding: .utf8) ?? ""
    expect(json.contains("\"kind\":\"terminal\""), "Tile kind encoded as string")
    expect(json.contains("\"launchProfileId\":\"claude\""), "Tile metadata encodes launchProfileId")
    // Empty optional metadata fields should not appear in JSON.
    expect(!json.contains("\"url\""), "Tile metadata omits unset optional fields")
}

// MARK: - TerminalSessionDescriptor round trip

do {
    let descriptor = TerminalSessionDescriptor(
        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        tileId: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
        launchProfileId: "claude",
        command: "claude",
        args: [],
        cwd: "/tmp/x",
        env: [:],
        title: "Claude Code",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastStartedAt: Date(timeIntervalSince1970: 1_700_000_500),
        lastExit: nil
    )
    let data = try JSONCodec.makeEncoder().encode(descriptor)
    let decoded = try JSONCodec.makeDecoder().decode(TerminalSessionDescriptor.self, from: data)
    expect(decoded == descriptor, "TerminalSessionDescriptor round trip")
    let withExit = TerminalSessionDescriptor(
        id: descriptor.id,
        tileId: descriptor.tileId,
        launchProfileId: descriptor.launchProfileId,
        command: descriptor.command,
        args: descriptor.args,
        cwd: descriptor.cwd,
        env: descriptor.env,
        title: descriptor.title,
        createdAt: descriptor.createdAt,
        lastStartedAt: descriptor.lastStartedAt,
        lastExit: TerminalLastExit(exitCode: 0, signal: nil, at: Date(timeIntervalSince1970: 1_700_000_900))
    )
    let exitedData = try JSONCodec.makeEncoder().encode(withExit)
    let exitedDecoded = try JSONCodec.makeDecoder().decode(TerminalSessionDescriptor.self, from: exitedData)
    expect(exitedDecoded == withExit, "TerminalSessionDescriptor with exit round trip")
}

// MARK: - BrowserState round trip

do {
    let browser = BrowserState(
        tiles: [
            BrowserTile(
                id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                tileId: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                url: "http://localhost:3000",
                title: "Local App",
                storageGroupId: "project-default",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        ]
    )
    let data = try JSONCodec.makeEncoder().encode(browser)
    let decoded = try JSONCodec.makeDecoder().decode(BrowserState.self, from: data)
    expect(decoded == browser, "BrowserState round trip")
}

// MARK: - FilePreview

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-file-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let textFile = scratch.appendingPathComponent("hello.txt")
    try Data("hello file tile".utf8).write(to: textFile)
    expect(FilePreview.load(path: textFile.path) == .text("hello file tile"), "FilePreview loads UTF-8 text")

    let missingPreview = FilePreview.load(path: scratch.appendingPathComponent("missing.txt").path)
    expect(missingPreview == .unavailable("File not found"), "FilePreview reports missing files")

    let directoryPreview = FilePreview.load(path: scratch.path)
    expect(directoryPreview == .unavailable("File not found"), "FilePreview rejects directories")

    let devNullPreview = FilePreview.load(path: "/dev/null")
    expect(devNullPreview == .unavailable("File not found"), "FilePreview rejects non-regular files")

    let utf8BOMFile = scratch.appendingPathComponent("utf8-bom.txt")
    try Data([0xEF, 0xBB, 0xBF, 0x68, 0x69]).write(to: utf8BOMFile)
    expect(FilePreview.load(path: utf8BOMFile.path) == .text("hi"), "FilePreview accepts UTF-8 BOM files")

    let binaryFile = scratch.appendingPathComponent("binary.bin")
    try Data([0x41, 0x00, 0x42]).write(to: binaryFile)
    expect(FilePreview.load(path: binaryFile.path) == .unavailable("Binary file -- open in preferred editor"), "FilePreview rejects null-byte binary files")

    let utf16File = scratch.appendingPathComponent("utf16.txt")
    try Data([0xFF, 0xFE, 0x41, 0x00]).write(to: utf16File)
    expect(FilePreview.load(path: utf16File.path) == .unavailable("Binary file -- open in preferred editor"), "FilePreview rejects non-UTF-8 BOM files")

    let largeFile = scratch.appendingPathComponent("large.txt")
    let largeBytes = Data(repeating: 0x61, count: FilePreview.maxReadBytes + 1)
    try largeBytes.write(to: largeFile)
    expect(FilePreview.load(path: largeFile.path) == .unavailable("File too large to preview (> 1 MB)"), "FilePreview rejects oversized files")

    let sparseHugeFile = scratch.appendingPathComponent("sparse-3gb.txt")
    FileManager.default.createFile(atPath: sparseHugeFile.path, contents: nil)
    let sparseHandle = try FileHandle(forWritingTo: sparseHugeFile)
    try sparseHandle.truncate(atOffset: 3 * 1_024 * 1_024 * 1_024)
    try sparseHandle.close()
    var attemptedHugeRead = false
    let sparseHugePreview = FilePreview.load(path: sparseHugeFile.path) { _ in
        attemptedHugeRead = true
        return Data()
    }
    expect(sparseHugePreview == .unavailable("File too large to preview (> 1 MB)"), "FilePreview rejects sparse >2GB files using 64-bit size")
    expect(!attemptedHugeRead, "FilePreview returns too-large for sparse >2GB files before attempting Data read")
}

// MARK: - AtomicWriter

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let url = scratch.appendingPathComponent("project.json")
    let backupsDir = scratch.appendingPathComponent("backups")
    let writer = AtomicWriter(backupsDirectory: backupsDir, retainedBackups: 2)

    func makeProject(name: String) -> Project {
        Project(
            name: name,
            rootPath: scratch.path,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
    }

    // First write: no backup possible, just establishes the file.
    try writer.write(makeProject(name: "v1"), to: url)
    expect(FileManager.default.fileExists(atPath: url.path), "AtomicWriter creates target file")
    let v1Read: Project = try writer.read(at: url)
    expect(v1Read.name == "v1", "AtomicWriter reads what it just wrote")

    // Second write: previous content backed up.
    try writer.write(makeProject(name: "v2"), to: url)
    let v2Read: Project = try writer.read(at: url)
    expect(v2Read.name == "v2", "AtomicWriter advances to v2")
    let backupsAfter2 = (try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)).filter { $0.hasPrefix("project.") }
    expect(backupsAfter2.count == 1, "After 2 writes there is 1 backup, got \(backupsAfter2)")

    // Third and fourth writes: backup count capped at retainedBackups (2).
    try writer.write(makeProject(name: "v3"), to: url)
    try writer.write(makeProject(name: "v4"), to: url)
    let backupsAfter4 = (try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)).filter { $0.hasPrefix("project.") }
    expect(backupsAfter4.count == 2, "Backup retention caps at 2, got \(backupsAfter4)")

    // Corrupt the main file; reader must fall back to the most recent backup.
    try Data("not json".utf8).write(to: url)
    let recovered: Project = try writer.read(at: url)
    // Most recent backup contains v3 (the value before v4 overwrote it).
    expect(recovered.name == "v3", "AtomicWriter recovers from corruption via newest backup, got \(recovered.name)")
}

// MARK: - ProjectStore

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let store = ProjectStore(projectRoot: scratch, retainedBackups: 2)

    let project = Project(
        name: "test-project",
        rootPath: scratch.path,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        defaultLaunchProfileId: "shell",
        editorPreference: .auto,
        settings: ProjectSettings(
            restorePolicy: .restoreDescriptors,
            browserStoragePolicy: .perProject,
            terminalClosePolicy: .askWhenRunning
        )
    )
    try store.saveProject(project)
    let loadedProject = try store.loadProject()
    expect(loadedProject == project, "ProjectStore.loadProject returns saved value")
    expect(
        FileManager.default.fileExists(atPath: store.layout.projectFile.path),
        "project.json lands inside .continuum-revived/"
    )
    expect(
        FileManager.default.fileExists(atPath: store.layout.stateRoot.appendingPathComponent("project.json").path),
        "stateRoot equals projectRoot/.continuum-revived"
    )

    let canvas = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [],
        groups: [],
        lastActiveTileId: nil
    )
    try store.saveCanvas(canvas)
    let loadedCanvas = try store.loadCanvas()
    expect(loadedCanvas == canvas, "ProjectStore.loadCanvas returns saved value")

    let s1 = TerminalSessionDescriptor(
        id: UUID(),
        tileId: UUID(),
        launchProfileId: "shell",
        command: "/bin/zsh",
        args: [],
        cwd: scratch.path,
        env: [:],
        title: "Shell",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastExit: nil
    )
    let s2 = TerminalSessionDescriptor(
        id: UUID(),
        tileId: UUID(),
        launchProfileId: "claude",
        command: "claude",
        args: [],
        cwd: scratch.path,
        env: [:],
        title: "Claude",
        createdAt: Date(timeIntervalSince1970: 1_700_000_500),
        lastStartedAt: Date(timeIntervalSince1970: 1_700_000_500),
        lastExit: nil
    )
    try store.saveSession(s1)
    try store.saveSession(s2)
    let sessions = try store.listSessions()
    expect(sessions.count == 2, "listSessions returns saved sessions, got \(sessions.count)")
    let sessionIds = Set(sessions.map(\.id))
    expect(sessionIds == [s1.id, s2.id], "listSessions returns correct ids")

    try store.deleteSession(id: s1.id)
    let afterDelete = try store.listSessions()
    expect(afterDelete.count == 1 && afterDelete.first?.id == s2.id, "deleteSession removes only the named session")

    let browser = BrowserState(tiles: [
        BrowserTile(
            id: UUID(),
            tileId: UUID(),
            url: "http://localhost:3000",
            title: "Local",
            storageGroupId: "default",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ])
    try store.saveBrowserState(browser)
    let loadedBrowser = try store.loadBrowserState()
    expect(loadedBrowser == browser, "BrowserState round trip")

    // Resaving project should produce a backup under .continuum-revived/backups/
    let updated = Project(
        id: project.id,
        name: "test-project",
        rootPath: project.rootPath,
        createdAt: project.createdAt,
        updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
        defaultLaunchProfileId: project.defaultLaunchProfileId,
        editorPreference: project.editorPreference,
        settings: project.settings
    )
    try store.saveProject(updated)
    let backupContents = try FileManager.default.contentsOfDirectory(atPath: store.layout.backupsDirectory.path)
    let projectBackups = backupContents.filter { $0.hasPrefix("project.") }
    expect(!projectBackups.isEmpty, "Resaving project leaves a backup in backups/, got \(backupContents)")

    // loadProject when nothing is on disk returns nil via tryLoad.
    try FileManager.default.removeItem(at: store.layout.projectFile)
    // Wipe the backup too so recovery cannot kick in.
    for name in projectBackups {
        try? FileManager.default.removeItem(at: store.layout.backupsDirectory.appendingPathComponent(name))
    }
    let missing = try store.tryLoadProject()
    expect(missing == nil, "tryLoadProject returns nil when no file or backup is present")
}

// MARK: - Registry round trip

do {
    let workspaceId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let registry = Registry(
        lastActiveWorkspaceId: workspaceId,
        lastActiveProjectId: projectId,
        workspaces: [
            WorkspaceEntry(
                id: workspaceId,
                name: "Personal",
                projectIds: [projectId],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )
        ],
        projects: [
            ProjectEntry(
                id: projectId,
                name: "continuum-revived",
                rootPath: "/tmp/continuum-revived",
                workspaceId: workspaceId,
                lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_500),
                pinned: true
            )
        ],
        settings: RegistrySettings(
            preferredEditor: .auto,
            zoomModifier: .command,
            openLastProjectOnLaunch: true
        )
    )
    let data = try JSONCodec.makeEncoder().encode(registry)
    let decoded = try JSONCodec.makeDecoder().decode(Registry.self, from: data)
    expect(decoded == registry, "Registry round trip")
}

// MARK: - Future-version safety

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-future-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let store = ProjectStore(projectRoot: scratch, retainedBackups: 1)

    let futureProject = Project(
        schemaVersion: Project.currentSchemaVersion + 99,
        name: "future",
        rootPath: scratch.path,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        defaultLaunchProfileId: "shell",
        editorPreference: .auto,
        settings: ProjectSettings(
            restorePolicy: .restoreDescriptors,
            browserStoragePolicy: .perProject,
            terminalClosePolicy: .askWhenRunning
        )
    )
    try store.saveProject(futureProject)

    // Loading must refuse: we'd silently downgrade unknown fields otherwise.
    do {
        _ = try store.loadProject()
        expect(false, "Future schema version should refuse load")
    } catch let ProjectStoreError.unknownFutureSchema(_, version, supported) {
        expect(version > supported, "Unknown future schema reports version > supported")
    } catch {
        expect(false, "Future schema should throw unknownFutureSchema, threw \(error)")
    }

    // The on-disk file is untouched by the failed load — important for the
    // "do not overwrite without user confirmation" policy.
    let raw = try Data(contentsOf: store.layout.projectFile)
    let json = String(data: raw, encoding: .utf8) ?? ""
    let normalized = json.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
    expect(normalized.contains("\"schemaVersion\":\(Project.currentSchemaVersion + 99)"), "Future-version file remains intact on disk")

    // Same gate for the registry.
    let registryScratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-registry-future-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: registryScratch) }
    let registryStore = RegistryStore(applicationSupportDirectory: registryScratch, retainedBackups: 1)
    let futureRegistry = Registry(
        schemaVersion: Registry.currentSchemaVersion + 99,
        lastActiveWorkspaceId: nil,
        lastActiveProjectId: nil,
        workspaces: [],
        projects: [],
        settings: RegistrySettings(
            preferredEditor: .auto,
            zoomModifier: .command,
            openLastProjectOnLaunch: true
        )
    )
    try registryStore.save(futureRegistry)
    do {
        _ = try registryStore.load()
        expect(false, "Future registry schema should refuse load")
    } catch RegistryStoreError.unknownFutureSchema {
        // Expected.
    } catch {
        expect(false, "Future registry schema should throw unknownFutureSchema, threw \(error)")
    }
}

// MARK: - RegistryStore

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-registry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let store = RegistryStore(applicationSupportDirectory: scratch, retainedBackups: 2)

    // Empty state when nothing is on disk.
    let initial = try store.loadOrEmpty()
    expect(initial.workspaces.isEmpty, "RegistryStore.loadOrEmpty starts empty")
    expect(initial.projects.isEmpty, "RegistryStore.loadOrEmpty has no projects initially")

    // Round-trip a populated registry.
    let workspaceId = UUID()
    let projectId = UUID()
    let registry = Registry(
        lastActiveWorkspaceId: workspaceId,
        lastActiveProjectId: projectId,
        workspaces: [
            WorkspaceEntry(
                id: workspaceId,
                name: "Personal",
                projectIds: [projectId],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ],
        projects: [
            ProjectEntry(
                id: projectId,
                name: "continuum-revived",
                rootPath: "/tmp/continuum-revived",
                workspaceId: workspaceId,
                lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_500),
                pinned: true
            )
        ],
        settings: RegistrySettings(
            preferredEditor: .auto,
            zoomModifier: .command,
            openLastProjectOnLaunch: true
        )
    )
    try store.save(registry)
    let reloaded = try store.load()
    expect(reloaded == registry, "RegistryStore round trip")

    // The default Application Support path should at least include the app name.
    let defaultDir = RegistryStore.defaultApplicationSupportDirectory()
    expect(
        defaultDir.path.hasSuffix("/continuum-revived") || defaultDir.path.contains("continuum-revived/"),
        "Default registry directory ends with /continuum-revived, got \(defaultDir.path)"
    )
}

// MARK: - CanvasEngine: coordinate conversion

do {
    let identity = CanvasViewport(x: 0, y: 0, zoom: 1)
    let world = CGPoint(x: 100, y: 200)
    let screen = CanvasEngine.worldToScreen(world, viewport: identity)
    expect(screen == world, "Identity viewport: world == screen, got \(screen)")
    let backToWorld = CanvasEngine.screenToWorld(screen, viewport: identity)
    expect(backToWorld == world, "screen→world is inverse of world→screen")
}

do {
    let panned = CanvasViewport(x: 50, y: 30, zoom: 1)
    let world = CGPoint(x: 100, y: 100)
    let screen = CanvasEngine.worldToScreen(world, viewport: panned)
    expect(screen == CGPoint(x: 50, y: 70), "Pan moves world points relative to screen, got \(screen)")
}

do {
    let zoomed = CanvasViewport(x: 0, y: 0, zoom: 2)
    let screen = CanvasEngine.worldToScreen(CGPoint(x: 100, y: 100), viewport: zoomed)
    expect(screen == CGPoint(x: 200, y: 200), "Zoom scales screen size proportionally, got \(screen)")
}

// MARK: - CanvasEngine: cursor-anchored zoom keeps world point fixed

do {
    let initial = CanvasViewport(x: 0, y: 0, zoom: 1)
    let cursor = CGPoint(x: 400, y: 300)
    let worldBefore = CanvasEngine.screenToWorld(cursor, viewport: initial)

    let zoomedIn = CanvasEngine.zoom(initial, by: 2.0, anchorScreen: cursor)
    let worldAfter = CanvasEngine.screenToWorld(cursor, viewport: zoomedIn)
    expect(zoomedIn.zoom == 2.0, "Zoom factor applied")
    expect(approximatelyEqual(worldBefore, worldAfter), "Zoom preserves world point under cursor (1→2)")

    let zoomedOut = CanvasEngine.zoom(zoomedIn, by: 0.25, anchorScreen: cursor)
    let worldAgain = CanvasEngine.screenToWorld(cursor, viewport: zoomedOut)
    expect(zoomedOut.zoom == 0.5, "Zoom factor compounds (2 * 0.25)")
    expect(approximatelyEqual(worldBefore, worldAgain), "Zoom preserves world point through compound zooms")
}

// MARK: - CanvasEngine: zoom clamps to range

do {
    let v = CanvasViewport(x: 0, y: 0, zoom: 1)
    let zoomedTooFar = CanvasEngine.zoom(v, by: 100, anchorScreen: .zero, range: 0.1 ... 4.0)
    expect(zoomedTooFar.zoom == 4.0, "Zoom clamps at upper bound, got \(zoomedTooFar.zoom)")
    let zoomedTooSmall = CanvasEngine.zoom(v, by: 0.001, anchorScreen: .zero, range: 0.1 ... 4.0)
    expect(zoomedTooSmall.zoom == 0.1, "Zoom clamps at lower bound, got \(zoomedTooSmall.zoom)")
}

// MARK: - CanvasEngine: hit test respects z-order

do {
    let v = CanvasViewport(x: 0, y: 0, zoom: 1)
    let lower = Tile(
        id: UUID(),
        kind: .terminal,
        title: "lower",
        frame: TileFrame(x: 0, y: 0, width: 200, height: 200),
        zIndex: 1,
        runtimeRef: nil,
        metadata: TileMetadata()
    )
    let upper = Tile(
        id: UUID(),
        kind: .terminal,
        title: "upper",
        frame: TileFrame(x: 100, y: 100, width: 200, height: 200),
        zIndex: 2,
        runtimeRef: nil,
        metadata: TileMetadata()
    )

    expect(CanvasEngine.hitTest(screenPoint: CGPoint(x: 50, y: 50), viewport: v, tiles: [lower, upper])?.id == lower.id, "Hit only-in-lower returns lower")
    expect(CanvasEngine.hitTest(screenPoint: CGPoint(x: 250, y: 250), viewport: v, tiles: [lower, upper])?.id == upper.id, "Hit only-in-upper returns upper")
    expect(CanvasEngine.hitTest(screenPoint: CGPoint(x: 150, y: 150), viewport: v, tiles: [lower, upper])?.id == upper.id, "Overlap returns higher zIndex")
    expect(CanvasEngine.hitTest(screenPoint: CGPoint(x: 500, y: 500), viewport: v, tiles: [lower, upper]) == nil, "Outside all tiles returns nil")
}

// MARK: - CanvasEngine: drag updates frame in world space

do {
    let v = CanvasViewport(x: 0, y: 0, zoom: 2.0)
    let tile = Tile(
        id: UUID(),
        kind: .terminal,
        title: "t",
        frame: TileFrame(x: 100, y: 100, width: 300, height: 200),
        zIndex: 1,
        runtimeRef: nil,
        metadata: TileMetadata()
    )
    // Drag 40 screen pixels right at zoom=2 → 20 world units.
    let dragged = CanvasEngine.tile(tile, draggedByScreenDelta: CGSize(width: 40, height: 0), viewport: v)
    expect(dragged.frame.x == 120 && dragged.frame.y == 100, "Drag moves tile in world units, got \(dragged.frame)")
    // Width/height are unchanged by drag.
    expect(dragged.frame.width == 300 && dragged.frame.height == 200, "Drag preserves tile size")
}

// MARK: - CanvasEngine: resize clamps to minimum

do {
    let v = CanvasViewport(x: 0, y: 0, zoom: 1.0)
    let tile = Tile(
        id: UUID(),
        kind: .terminal,
        title: "t",
        frame: TileFrame(x: 100, y: 100, width: 400, height: 300),
        zIndex: 1,
        runtimeRef: nil,
        metadata: TileMetadata()
    )

    let bigger = CanvasEngine.tile(tile, resizedByScreenDelta: CGSize(width: 50, height: 30), edge: .bottomRight, viewport: v)
    expect(bigger.frame.width == 450 && bigger.frame.height == 330, "Bottom-right drag enlarges, got \(bigger.frame)")
    expect(bigger.frame.x == 100 && bigger.frame.y == 100, "Bottom-right drag does not move origin")

    // Try to shrink way past the minimum; result should be exactly the minimum.
    let min = CanvasEngine.minimumFrame(for: .terminal)
    let shrunk = CanvasEngine.tile(tile, resizedByScreenDelta: CGSize(width: -10000, height: -10000), edge: .bottomRight, viewport: v)
    expect(shrunk.frame.width == min.width && shrunk.frame.height == min.height, "Resize clamps to minimum (\(min) vs \(shrunk.frame))")

    // Top-left edge moves origin AND adjusts size.
    let topLeft = CanvasEngine.tile(tile, resizedByScreenDelta: CGSize(width: 20, height: 30), edge: .topLeft, viewport: v)
    expect(topLeft.frame.x == 120 && topLeft.frame.y == 130, "Top-left drag moves origin, got \(topLeft.frame)")
    expect(topLeft.frame.width == 380 && topLeft.frame.height == 270, "Top-left drag shrinks size, got \(topLeft.frame)")
}

// MARK: - CanvasEngine: bring-to-front + z-order renormalization

do {
    let a = Tile(id: UUID(), kind: .terminal, title: "a", frame: TileFrame(x: 0, y: 0, width: 100, height: 100), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
    let b = Tile(id: UUID(), kind: .terminal, title: "b", frame: TileFrame(x: 0, y: 0, width: 100, height: 100), zIndex: 5, runtimeRef: nil, metadata: TileMetadata())
    let c = Tile(id: UUID(), kind: .terminal, title: "c", frame: TileFrame(x: 0, y: 0, width: 100, height: 100), zIndex: 2, runtimeRef: nil, metadata: TileMetadata())

    let promoted = CanvasEngine.bringToFront(tileId: a.id, in: [a, b, c])
    let promotedA = promoted.first { $0.id == a.id }!
    let promotedB = promoted.first { $0.id == b.id }!
    expect(promotedA.zIndex > promotedB.zIndex, "bringToFront makes target highest, got \(promoted.map(\.zIndex))")

    // Renormalize compresses to 0..n-1 keeping order.
    let inflated = [a, b, c].map { Tile(id: $0.id, kind: $0.kind, title: $0.title, frame: $0.frame, zIndex: $0.zIndex * 1000, runtimeRef: nil, metadata: $0.metadata) }
    let normalized = CanvasEngine.renormalizeZOrder(inflated)
    let zs = normalized.map(\.zIndex).sorted()
    expect(zs == [0, 1, 2], "Renormalize produces 0..n-1, got \(zs)")
    // Order preserved
    let originalOrder = inflated.sorted { $0.zIndex < $1.zIndex }.map(\.id)
    let normalizedOrder = normalized.sorted { $0.zIndex < $1.zIndex }.map(\.id)
    expect(originalOrder == normalizedOrder, "Renormalize preserves relative order")
}

// MARK: - CanvasEngine: group bounds + fit-to-bounds

do {
    let t1 = Tile(id: UUID(), kind: .terminal, title: "1", frame: TileFrame(x: 100, y: 100, width: 200, height: 200), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
    let t2 = Tile(id: UUID(), kind: .terminal, title: "2", frame: TileFrame(x: 400, y: 50, width: 100, height: 300), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
    let group = TileGroup(id: UUID(), title: "g", tileIds: [t1.id, t2.id], color: "blue", collapsed: false)

    let bounds = CanvasEngine.groupBounds(group, in: [t1, t2])
    expect(bounds == CGRect(x: 100, y: 50, width: 400, height: 300), "Group bounds = union of frames, got \(String(describing: bounds))")

    // Fit a 400x300 world rect into a 800x600 viewport with 40 padding.
    let viewport = CanvasEngine.fit(worldRect: CGRect(x: 100, y: 50, width: 400, height: 300), viewportSize: CGSize(width: 800, height: 600), padding: 40)
    // zoom = min((800-80)/400, (600-80)/300) = min(1.8, 1.733...) = ~1.733
    expect(abs(viewport.zoom - (520.0 / 300.0)) < 0.001, "Fit zoom matches the tighter axis, got \(viewport.zoom)")

    // The worldRect, after applying the new viewport, should be visible inside the viewport bounds (with padding).
    let topLeft = CanvasEngine.worldToScreen(CGPoint(x: 100, y: 50), viewport: viewport)
    let bottomRight = CanvasEngine.worldToScreen(CGPoint(x: 500, y: 350), viewport: viewport)
    expect(topLeft.x >= 0 && topLeft.y >= 0, "Fit places top-left inside viewport, got \(topLeft)")
    expect(bottomRight.x <= 800 && bottomRight.y <= 600, "Fit places bottom-right inside viewport, got \(bottomRight)")
}

// MARK: - CanvasEngine: defaults per kind

do {
    let term = CanvasEngine.defaultFrame(for: .terminal)
    expect(term.width == 900 && term.height == 620, "Terminal default 900x620, got \(term)")
    let browser = CanvasEngine.defaultFrame(for: .browser)
    expect(browser.width == 1000 && browser.height == 700, "Browser default 1000x700, got \(browser)")
}

// MARK: - LaunchProfileRegistry: built-ins

do {
    let registry = LaunchProfileRegistry()
    let ids = registry.all().map(\.id)
    expect(ids == ["shell", "claude", "codex", "nvim", "custom"], "Registry returns 5 built-ins in stable order, got \(ids)")
    expect(registry.spec(for: "shell")?.title == "Shell", "shell spec has title Shell")
    expect(registry.spec(for: "claude")?.displayName == "Claude Code", "claude spec has displayName Claude Code")
    expect(registry.spec(for: "nope") == nil, "Unknown id returns nil")
}

// MARK: - ToolDetector: pure which

do {
    let detector = ToolDetector { _ in false }
    expect(detector.locate("claude", in: ["/usr/bin", "/opt/bin"]) == nil, "Detector returns nil when nothing matches")
}

do {
    let target = "/opt/homebrew/bin/claude"
    let detector = ToolDetector { path in path == target }
    expect(detector.locate("claude", in: ["/usr/bin", "/opt/homebrew/bin", "/opt/bin"]) == target, "Detector returns first matching dir")
}

do {
    let detector = ToolDetector { _ in true }
    expect(detector.locate("nvim", in: []) == nil, "Empty path list returns nil")
    expect(detector.locate("nvim", in: [""]) == nil, "Empty path segment is skipped")
}

do {
    // Trailing slash on PATH dir should not produce a double slash candidate.
    let detector = ToolDetector { path in path == "/opt/homebrew/bin/codex" }
    expect(detector.locate("codex", in: ["/opt/homebrew/bin/"]) == "/opt/homebrew/bin/codex", "Trailing slash is normalized")
    // Negative form: the unnormalized double-slash path must not match.
    let strict = ToolDetector { path in path == "/opt/homebrew/bin//codex" }
    expect(strict.locate("codex", in: ["/opt/homebrew/bin/"]) == nil, "Detector does not produce double-slash candidates")
}

// MARK: - LaunchProfileRegistry: resolve shell

do {
    let registry = LaunchProfileRegistry()
    let shellSpec = registry.spec(for: "shell")!
    let resolution = registry.resolve(
        shellSpec,
        in: "/tmp/x",
        environment: ["SHELL": "/bin/zsh"],
        detector: ToolDetector { _ in true }
    )
    if case let .found(profile) = resolution {
        expect(profile.command == "/bin/zsh", "Shell resolves to $SHELL")
        expect(profile.cwd == "/tmp/x", "Shell resolution preserves cwd")
        expect(profile.title == "Shell", "Shell resolution uses spec title")
        expect(profile.arguments == [], "Shell resolution carries no extra args")
    } else {
        expect(false, "Shell should resolve to .found, got \(resolution)")
    }
}

// MARK: - LaunchProfileRegistry: resolve tool found

do {
    let registry = LaunchProfileRegistry()
    let claude = registry.spec(for: "claude")!
    let resolution = registry.resolve(
        claude,
        in: "/tmp/proj",
        environment: ["PATH": "/usr/bin:/opt/homebrew/bin"],
        detector: ToolDetector { path in path == "/opt/homebrew/bin/claude" }
    )
    if case let .found(profile) = resolution {
        expect(profile.command == "/opt/homebrew/bin/claude", "Tool resolution uses detected path")
        expect(profile.cwd == "/tmp/proj", "Tool resolution preserves cwd")
        expect(profile.title == "Claude", "Tool resolution uses spec title")
    } else {
        expect(false, "Claude should resolve to .found when detector matches, got \(resolution)")
    }
}

// MARK: - LaunchProfileRegistry: resolve tool missing

do {
    let registry = LaunchProfileRegistry()
    let nvim = registry.spec(for: "nvim")!
    let resolution = registry.resolve(
        nvim,
        in: "/tmp/proj",
        environment: ["PATH": "/usr/bin"],
        detector: ToolDetector { _ in false }
    )
    if case let .missing(executableName) = resolution {
        expect(executableName == "nvim", "Missing nvim reports executable name")
    } else {
        expect(false, "nvim should resolve to .missing when detector returns nil, got \(resolution)")
    }
}

// MARK: - LaunchProfileRegistry: nvim args carry through

do {
    let registry = LaunchProfileRegistry()
    let nvim = registry.spec(for: "nvim")!
    let resolution = registry.resolve(
        nvim,
        in: "/tmp/proj",
        environment: ["PATH": "/opt/bin"],
        detector: ToolDetector { path in path == "/opt/bin/nvim" }
    )
    if case let .found(profile) = resolution {
        expect(profile.arguments == ["."], "nvim spec passes [\".\"] so the editor opens cwd")
    } else {
        expect(false, "nvim should resolve to .found when detector matches, got \(resolution)")
    }
}

// MARK: - CanvasState: multi-terminal launchProfileId round trip

do {
    let shellTile = Tile(
        id: UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111")!,
        kind: .terminal,
        title: "Shell",
        frame: TileFrame(x: 0, y: 0, width: 600, height: 400),
        zIndex: 1,
        runtimeRef: RuntimeRef(kind: .terminalSession, id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!),
        metadata: TileMetadata(launchProfileId: "shell", projectRelativeCwd: ".")
    )
    let claudeTile = Tile(
        id: UUID(uuidString: "AAAAAAAA-2222-2222-2222-222222222222")!,
        kind: .terminal,
        title: "Claude",
        frame: TileFrame(x: 700, y: 0, width: 600, height: 400),
        zIndex: 2,
        runtimeRef: RuntimeRef(kind: .terminalSession, id: UUID(uuidString: "BBBBBBBB-2222-2222-2222-222222222222")!),
        metadata: TileMetadata(launchProfileId: "claude", projectRelativeCwd: ".")
    )
    let canvas = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1.0),
        tiles: [shellTile, claudeTile],
        groups: [],
        lastActiveTileId: claudeTile.id
    )
    let data = try JSONCodec.makeEncoder().encode(canvas)
    let decoded = try JSONCodec.makeDecoder().decode(CanvasState.self, from: data)
    expect(decoded == canvas, "Multi-terminal canvas round trip")
    let decodedShell = decoded.tiles.first { $0.id == shellTile.id }!
    let decodedClaude = decoded.tiles.first { $0.id == claudeTile.id }!
    expect(decodedShell.metadata.launchProfileId == "shell", "shell tile preserves launchProfileId")
    expect(decodedClaude.metadata.launchProfileId == "claude", "claude tile preserves launchProfileId")
    expect(decodedShell.id != decodedClaude.id, "tile ids stay distinct")
}

// MARK: - BrowserState.storageGroupIdentifier

do {
    func project(id: UUID, policy: BrowserStoragePolicy) -> Project {
        Project(
            id: id,
            name: "scratch",
            rootPath: "/tmp/scratch",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: policy,
                terminalClosePolicy: .askWhenRunning
            )
        )
    }

    let aId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let bId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    // Determinism: same project resolves to the same identifier across calls.
    let perA = BrowserState.storageGroupIdentifier(for: project(id: aId, policy: .perProject))
    let perAAgain = BrowserState.storageGroupIdentifier(for: project(id: aId, policy: .perProject))
    expect(perA == perAAgain, "storageGroupIdentifier is deterministic per project")
    expect(perA == aId.uuidString, "perProject storageGroupId == project.id.uuidString, got \(perA)")

    // Distinctness: two projects with different ids resolve to different ids.
    let perB = BrowserState.storageGroupIdentifier(for: project(id: bId, policy: .perProject))
    expect(perA != perB, "different projects produce different perProject storageGroupIds")

    // Shared invariance: every shared project resolves to the same sentinel.
    let sharedA = BrowserState.storageGroupIdentifier(for: project(id: aId, policy: .shared))
    let sharedB = BrowserState.storageGroupIdentifier(for: project(id: bId, policy: .shared))
    expect(sharedA == BrowserState.sharedStorageGroupId, "shared policy returns sharedStorageGroupId")
    expect(sharedA == sharedB, "shared storage id is identical across projects")
    expect(sharedA != perA, "shared sentinel does not collide with any perProject id")
}

// MARK: - LaunchProfileRegistry: custom is .notConfigured

do {
    let registry = LaunchProfileRegistry()
    let custom = registry.spec(for: "custom")!
    let resolution = registry.resolve(
        custom,
        in: "/tmp/proj",
        environment: [:],
        detector: ToolDetector { _ in true }
    )
    if case let .notConfigured(profileId) = resolution {
        expect(profileId == "custom", "Custom resolves to .notConfigured with its id")
    } else {
        expect(false, "Custom should resolve to .notConfigured, got \(resolution)")
    }
}

// MARK: - pruneExitedSessions

do {
    let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratchRoot) }

    let store = ProjectStore(projectRoot: scratchRoot, retainedBackups: 1)

    let alive = TerminalSessionDescriptor(
        id: UUID(),
        tileId: UUID(),
        launchProfileId: "shell",
        command: "/bin/zsh",
        args: [],
        cwd: scratchRoot.path,
        env: [:],
        title: "Alive",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastExit: nil
    )
    let exitedClean = TerminalSessionDescriptor(
        id: UUID(),
        tileId: UUID(),
        launchProfileId: "shell",
        command: "/bin/zsh",
        args: [],
        cwd: scratchRoot.path,
        env: [:],
        title: "ExitedClean",
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        lastStartedAt: Date(timeIntervalSince1970: 1_700_000_100),
        lastExit: TerminalLastExit(exitCode: 0, signal: nil, at: Date(timeIntervalSince1970: 1_700_000_200))
    )
    let exitedSignal = TerminalSessionDescriptor(
        id: UUID(),
        tileId: UUID(),
        launchProfileId: "shell",
        command: "/bin/zsh",
        args: [],
        cwd: scratchRoot.path,
        env: [:],
        title: "ExitedSignal",
        createdAt: Date(timeIntervalSince1970: 1_700_000_300),
        lastStartedAt: Date(timeIntervalSince1970: 1_700_000_300),
        lastExit: TerminalLastExit(exitCode: nil, signal: 9, at: Date(timeIntervalSince1970: 1_700_000_400))
    )

    try store.saveSession(alive)
    try store.saveSession(exitedClean)
    try store.saveSession(exitedSignal)

    pruneExitedSessions(in: store)

    let surviving = try store.listSessions()
    expect(surviving.count == 1, "pruneExitedSessions leaves only the alive session, got \(surviving.count)")
    expect(surviving.first?.id == alive.id, "surviving session is the one with lastExit == nil")
    let survivingIds = Set(surviving.map(\.id))
    expect(!survivingIds.contains(exitedClean.id), "exitedClean descriptor was pruned")
    expect(!survivingIds.contains(exitedSignal.id), "exitedSignal descriptor was pruned")
}

// MARK: - Phase 6 core note/file/file-tree models

do {
    let noteId = UUID(uuidString: "CCCCCCCC-1111-1111-1111-111111111111")!
    let noteTileId = UUID(uuidString: "CCCCCCCC-2222-2222-2222-222222222222")!
    let noteTile = NoteTile(
        id: noteId,
        tileId: noteTileId,
        filename: "\(noteId.uuidString).md",
        title: "My Note",
        createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
        updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_500)
    )
    let noteState = NoteState(tiles: [noteTile])
    let noteData = try JSONCodec.makeEncoder().encode(noteState)
    let decodedNoteState = try JSONCodec.makeDecoder().decode(NoteState.self, from: noteData)
    expect(decodedNoteState == noteState, "NoteState round trip")
    expect(decodedNoteState.schemaVersion == NoteState.currentSchemaVersion, "NoteState schema version preserved")

    let fileTreeTileId = UUID(uuidString: "7A7A7A7A-1111-1111-1111-111111111111")!
    let fileTreeTile = FileTreeTile(
        tileId: fileTreeTileId,
        rootPath: "/tmp/continuum-revived",
        expandedPaths: ["Sources", "Sources/ContinuumRevivedCore"],
        selectedPath: "Sources/ContinuumRevivedCore/ProjectStore.swift",
        searchQuery: "Store",
        ignoredNames: [".git", "node_modules", ".build"],
        gitBadges: .cheap
    )
    let fileTreeState = FileTreeState(tiles: [fileTreeTile])
    let fileTreeData = try JSONCodec.makeEncoder().encode(fileTreeState)
    let decodedFileTreeState = try JSONCodec.makeDecoder().decode(FileTreeState.self, from: fileTreeData)
    expect(decodedFileTreeState == fileTreeState, "FileTreeState round trip")
    expect(decodedFileTreeState.schemaVersion == FileTreeState.currentSchemaVersion, "FileTreeState schema version preserved")

    let node = FileTreeNode(
        relativePath: "Sources/ContinuumRevivedCore/FileTreeState.swift",
        displayName: "FileTreeState.swift",
        isDirectory: false,
        childCount: 0,
        isIgnored: false,
        gitStatus: .added
    )
    let nodeData = try JSONCodec.makeEncoder().encode(node)
    let decodedNode = try JSONCodec.makeDecoder().decode(FileTreeNode.self, from: nodeData)
    expect(decodedNode == node, "FileTreeNode round trip")

    let metadata = TileMetadata(noteId: noteId, filePath: "Sources/ContinuumRevivedCore/ProjectStore.swift")
    let metadataData = try JSONCodec.makeEncoder().encode(metadata)
    let metadataJSON = String(data: metadataData, encoding: .utf8) ?? ""
    expect(metadataJSON.contains("noteId"), "TileMetadata encodes noteId")
    expect(metadataJSON.contains("filePath"), "TileMetadata encodes filePath")
    let decodedMetadata = try JSONCodec.makeDecoder().decode(TileMetadata.self, from: metadataData)
    expect(decodedMetadata == metadata, "TileMetadata note/file fields round trip")

    let canvas = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [
            Tile(id: noteTileId, kind: .note, title: "Note", frame: TileFrame(x: 0, y: 0, width: 400, height: 300), zIndex: 1, runtimeRef: RuntimeRef(kind: .note, id: noteId), metadata: TileMetadata(noteId: noteId)),
            Tile(id: UUID(uuidString: "CCCCCCCC-3333-3333-3333-333333333333")!, kind: .file, title: "ProjectStore.swift", frame: TileFrame(x: 420, y: 0, width: 400, height: 300), zIndex: 2, runtimeRef: RuntimeRef(kind: .file, id: UUID()), metadata: TileMetadata(filePath: "Sources/ContinuumRevivedCore/ProjectStore.swift")),
            Tile(id: fileTreeTileId, kind: .fileTree, title: "Files", frame: TileFrame(x: 840, y: 0, width: 360, height: 520), zIndex: 3, runtimeRef: nil, metadata: TileMetadata())
        ],
        groups: [],
        lastActiveTileId: fileTreeTileId
    )
    let canvasData = try JSONCodec.makeEncoder().encode(canvas)
    let decodedCanvas = try JSONCodec.makeDecoder().decode(CanvasState.self, from: canvasData)
    expect(decodedCanvas == canvas, "CanvasState note/file/fileTree tiles round trip")
    expect(decodedCanvas.tiles.map(\.kind).contains(.fileTree), "CanvasState preserves fileTree tile kind")

    let fileTreeDefault = CanvasEngine.defaultFrame(for: .fileTree)
    expect(fileTreeDefault.width == 360 && fileTreeDefault.height == 520, "FileTree default frame is 360x520")
    let fileTreeMinimum = CanvasEngine.minimumFrame(for: .fileTree)
    expect(fileTreeMinimum.width == 220 && fileTreeMinimum.height == 240, "FileTree minimum frame is 220x240")
}

// MARK: - Phase 6 ProjectStore persistence

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-phase6-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let store = ProjectStore(projectRoot: scratch, retainedBackups: 2)
    let initialNoteState = try store.tryLoadNoteState()
    let initialFileTreeState = try store.tryLoadFileTreeState()
    expect(initialNoteState == nil, "tryLoadNoteState returns nil before save")
    expect(initialFileTreeState == nil, "tryLoadFileTreeState returns nil before save")

    let noteId = UUID()
    let noteTile = NoteTile(
        id: noteId,
        tileId: UUID(),
        filename: "\(noteId.uuidString).md",
        title: "Stored Note",
        createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
        updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_500)
    )
    let noteState = NoteState(tiles: [noteTile])
    try store.saveNoteState(noteState)
    let loadedNoteState = try store.loadNoteState()
    expect(loadedNoteState == noteState, "ProjectStore NoteState round trip")
    try store.saveNoteBody(id: noteId, text: "hello world")
    let loadedNoteBody = try store.loadNoteBody(id: noteId)
    expect(loadedNoteBody == "hello world", "ProjectStore note body round trip")
    expect(store.tryLoadNoteBody(id: UUID()) == nil, "tryLoadNoteBody returns nil for missing note")

    let fileTreeState = FileTreeState(tiles: [
        FileTreeTile(
            tileId: UUID(),
            rootPath: scratch.path,
            expandedPaths: ["Sources"],
            selectedPath: "Sources/main.swift",
            searchQuery: "main",
            ignoredNames: [".git", ".build"],
            gitBadges: .cheap
        )
    ])
    try store.saveFileTreeState(fileTreeState)
    let loadedFileTreeState = try store.loadFileTreeState()
    expect(loadedFileTreeState == fileTreeState, "ProjectStore FileTreeState round trip")
    expect(FileManager.default.fileExists(atPath: store.layout.fileTreeIndexFile.path), "fileTreeIndexFile exists after save")
}

// MARK: - Phase 6 future-version refusal

do {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-phase6-future-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let store = ProjectStore(projectRoot: scratch, retainedBackups: 1)

    try store.saveNoteState(NoteState(schemaVersion: NoteState.currentSchemaVersion + 99, tiles: []))
    do {
        _ = try store.loadNoteState()
        expect(false, "Future NoteState schema version should refuse load")
    } catch let ProjectStoreError.unknownFutureSchema(_, version, supported) {
        expect(version > supported, "Future NoteState schema reports version > supported")
    } catch {
        expect(false, "Future NoteState schema should throw unknownFutureSchema, threw \(error)")
    }

    try store.saveFileTreeState(FileTreeState(schemaVersion: FileTreeState.currentSchemaVersion + 99, tiles: []))
    do {
        _ = try store.loadFileTreeState()
        expect(false, "Future FileTreeState schema version should refuse load")
    } catch let ProjectStoreError.unknownFutureSchema(_, version, supported) {
        expect(version > supported, "Future FileTreeState schema reports version > supported")
    } catch {
        expect(false, "Future FileTreeState schema should throw unknownFutureSchema, threw \(error)")
    }
}

print("ContinuumRevivedCoreChecks passed")
