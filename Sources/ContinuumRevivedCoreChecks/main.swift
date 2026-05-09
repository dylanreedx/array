import ContinuumRevivedCore
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
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

print("ContinuumRevivedCoreChecks passed")
