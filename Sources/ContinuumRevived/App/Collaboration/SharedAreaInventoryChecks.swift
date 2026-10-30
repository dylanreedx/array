import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
func runSharedAreaInventoryChecks() throws {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw CheckFailure(description: message) }
        print("PASS collaboration inventory: \(message)")
    }
    guard let supportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
        throw CheckFailure(description: "inventory witness requires isolated CONTINUUM_APP_SUPPORT")
    }
    let root = URL(fileURLWithPath: supportPath).appendingPathComponent("capture-inventory-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support", isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let workspaceID = UUID(), projectAID = UUID(), projectBID = UUID()
    let zoneA = UUID(), zoneLower = UUID(), zoneB = UUID()
    let tileAID = UUID(), noteAID = UUID(), tileLowerID = UUID(), noteLowerID = UUID(), tileBID = UUID(), noteBID = UUID()
    let rootA = root.appendingPathComponent("project-a"), rootB = root.appendingPathComponent("project-b")
    for directory in [rootA, rootB, support] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let storeA = ProjectStore(projectRoot: rootA), storeB = ProjectStore(projectRoot: rootB)
    func project(id: UUID, name: String, root: URL) -> Project {
        .init(id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
              defaultLaunchProfileId: "shell", editorPreference: .auto,
              settings: .init(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning))
    }
    let projectA = project(id: projectAID, name: "Capture A", root: rootA)
    let projectB = project(id: projectBID, name: "Capture B", root: rootB)
    func note(id: UUID, bodyID: UUID, zone: UUID, x: Double, y: Double, rank: Int) -> Tile {
        .init(id: id, kind: .note, title: "Private note \(rank)", frame: .init(x: x, y: y, width: 280, height: 180),
              zPosition: .fromLegacyRank(rank), zoneId: zone, runtimeRef: nil, metadata: .init(noteId: bodyID))
    }
    let tileA = note(id: tileAID, bodyID: noteAID, zone: zoneA, x: -760, y: 320, rank: 1)
    let tileLower = note(id: tileLowerID, bodyID: noteLowerID, zone: zoneLower, x: 20_040, y: 80, rank: 2)
    let tileB = note(id: tileBID, bodyID: noteBID, zone: zoneB, x: 100, y: 320, rank: 3)
    try storeA.saveProject(projectA); try storeB.saveProject(projectB)
    try storeA.saveCanvas(.init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [tileA, tileLower], groups: [], lastActiveTileId: tileAID))
    try storeB.saveCanvas(.init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [tileB], groups: [], lastActiveTileId: tileBID))
    try storeA.saveNoteBody(id: noteAID, text: "Persisted source A")
    try storeA.saveNoteBody(id: noteLowerID, text: "Persisted below-tier source")
    try storeB.saveNoteBody(id: noteBID, text: "Persisted source B")
    func zone(id: UUID, projectID: UUID, x: Double, y: Double, name: String) -> ZonePlacement {
        .init(zoneId: id, projectId: projectID, origin: .init(x: x, y: y), size: .init(width: 700, height: 600),
              color: "mint", collapsed: false, hydrationPolicy: .automatic, autoLayoutMode: .disabled, name: name)
    }
    let document = WorkspaceDocument(viewport: .init(x: -900, y: 180, zoom: 0.7),
        zones: [zone(id: zoneA, projectID: projectAID, x: -800, y: 260, name: "A visible"),
                zone(id: zoneLower, projectID: projectAID, x: 20_000, y: 0, name: "A retained"),
                zone(id: zoneB, projectID: projectBID, x: 40, y: 260, name: "B visible")], lastActiveZoneId: zoneA)
    let registryStore = RegistryStore(applicationSupportDirectory: support)
    var registry = Registry.empty()
    registry.lastActiveWorkspaceId = workspaceID; registry.lastActiveProjectId = projectAID
    registry.projects = [
        .init(id: projectAID, name: projectA.name, rootPath: rootA.path, workspaceId: workspaceID, lastOpenedAt: now, pinned: false, missing: false),
        .init(id: projectBID, name: projectB.name, rootPath: rootB.path, workspaceId: workspaceID, lastOpenedAt: now, pinned: false, missing: false)
    ]
    registry.workspaces = [.init(id: workspaceID, name: "Capture workspace", projectIds: [projectAID, projectBID], createdAt: now, updatedAt: now)]
    try registryStore.save(registry)
    try WorkspaceStore(workspaceId: workspaceID, applicationSupportDirectory: support).save(document)
    let controllerA = ZoneRuntimeController(projectRoot: rootA, projectStore: storeA, project: projectA)
    let controllerB = ZoneRuntimeController(projectRoot: rootB, projectStore: storeB, project: projectB)
    var controllerAcquisitions = 0
    let controllers = ZoneRuntimeRegistry(closeOnZero: true) { id in
        controllerAcquisitions += 1
        if id == projectAID { return controllerA }
        if id == projectBID { return controllerB }
        throw CheckFailure(description: "unexpected project acquisition")
    }
    let browser = BrowserEngineContext(); defer { browser.shutdown() }
    let delegate = AppDelegate()
    let runtime = WorkspaceRuntime(boot: try controllers.acquire(projectId: projectAID), workspaceId: workspaceID,
        document: document, registry: controllers, focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
        ghostty: nil, browserEngine: browser)
    defer { runtime.closeAll() }
    let boot = try storeA.loadCanvas()
    let canvas = CanvasNSView(canvasState: boot, activeZone: document.zones[0],
        zoneRenderModels: document.zones.map { .init(placement: $0, displayName: $0.name) }, showsZoneChrome: true)
    canvas.frame = .init(x: 0, y: 0, width: 1600, height: 1000)
    let suiteName = "dev.arrayapp.macos.qa.collaboration-inventory.\(UUID())"
    let layoutDefaults = UserDefaults(suiteName: suiteName)!
    defer { layoutDefaults.removePersistentDomain(forName: suiteName) }
    layoutDefaults.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
    canvas.autoLayoutDefaults = layoutDefaults
    delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browser, runtime: runtime, registryStore: registryStore)
    let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browser, projectStore: storeA, project: projectA)
    try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: storeA,
        canvasState: boot, installsGlobalEventMonitors: false)
    try expect(runtime.collaborationCanvas === canvas && !canvas.isFlatCompatibilitySceneActive,
               "capture reads the actual production-mounted layered scene")
    try expect(canvas.installedZonePlacement(for: zoneLower) == nil, "fixture includes a persisted source below live hydration")
    guard let liveNote = controllerA.noteViews[noteAID] else {
        throw CheckFailure(description: "production note hydration did not expose the owning live note")
    }
    liveNote.textView.string = "Unsaved live note from its true owner"
    let movedWorld = TileFrame(x: -703, y: 355, width: tileA.frame.width, height: tileA.frame.height)
    try expect(canvas.applySelectionFrames([tileAID: movedWorld]), "fixture changes the live model in WORLD coordinates")
    canvas.tileView(for: tileAID)?.frame = .init(x: 9_999, y: 8_888, width: 280, height: 180)
    let files = [storeA.layout.canvasFile, storeB.layout.canvasFile, storeA.layout.noteFile(id: noteAID),
                 storeA.layout.noteFile(id: noteLowerID), storeB.layout.noteFile(id: noteBID)]
    let beforeFiles = try files.map { try Data(contentsOf: $0) }
    let beforeAcquisitions = controllerAcquisitions, beforeRecords = delegate.qaManagedAgentCount
    let beforeActiveZone = runtime.document.lastActiveZoneId
    let snapshot = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .workspace)
    let keyA = SharedAreaPublication.SourceKey(projectID: projectAID, tileID: tileAID)
    let keyLower = SharedAreaPublication.SourceKey(projectID: projectAID, tileID: tileLowerID)
    let keyB = SharedAreaPublication.SourceKey(projectID: projectBID, tileID: tileBID)
    try expect(snapshot.inventory.sources.count == 3 && Set(snapshot.inventory.sources.map(\.key)) == [keyA, keyLower, keyB],
               "complete capture includes both owners and persisted below-tier membership")
    try expect(snapshot.inventory.sources.first(where: { $0.key == keyA })?.tile.frame == movedWorld
               && snapshot.inventory.sources.first(where: { $0.key == keyLower })?.tile.frame == tileLower.frame,
               "live and retained source frames use WORLD model geometry exactly once, excluding presentation pose")
    try expect(snapshot.noteTexts[keyA] == liveNote.textView.string && snapshot.noteTexts[keyLower] == "Persisted below-tier source",
               "live unsaved and below-tier note text come from their actual owners")
    let modes: [SharedAreaPublication.SourceKey: SharedAreaInventory.Mode] = [keyA: .agreement, keyLower: .discussion, keyB: .omit]
    let choices = try snapshot.choices(for: modes)
    let area = SharedArea.ID<SharedArea.Area>(), person = SharedArea.ID<SharedArea.Person>(), host = SharedArea.ID<SharedArea.Host>()
    let review = try SharedAreaPublication.prepare(inventory: snapshot.inventory, selection: .workspace, choices: choices,
        area: area, author: person, host: host, expectedRevision: 0)
    let fresh = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .workspace)
    _ = try SharedAreaPublication.confirm(review, expectedDigest: review.digest, inventory: fresh.inventory, choices: fresh.choices(for: modes))
    try expect(try files.map { try Data(contentsOf: $0) } == beforeFiles,
               "capture and confirmation do not rewrite source canvases or note files")
    try expect(controllerAcquisitions == beforeAcquisitions && delegate.qaManagedAgentCount == beforeRecords
               && runtime.document.lastActiveZoneId == beforeActiveZone,
               "reading capture acquires no controller, creates no agent and leaves the armed source unchanged")
    liveNote.textView.string += " changed after review"
    let changed = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .workspace)
    do {
        _ = try SharedAreaPublication.confirm(review, expectedDigest: review.digest, inventory: changed.inventory, choices: changed.choices(for: modes))
        throw CheckFailure(description: "changed live owner content reused stale confirmation")
    } catch SharedAreaPublication.Failure.reviewChanged {
        print("PASS collaboration inventory: actual owner reread invalidates stale note confirmation")
    }
    let unknownProject = UUID()
    do {
        _ = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor,
            selection: .tiles([.init(projectID: unknownProject, tileID: tileAID)]))
        throw CheckFailure(description: "foreign project identity selected a local tile")
    } catch SharedAreaInventory.Failure.incompleteCoverage(let issues) {
        try expect(issues.contains(where: { $0.projectID == unknownProject && $0.reason == .projectNotInWorkspace }),
                   "a known tile pointer does not authorize another project identity")
    }
    // A foreign stamp written after mount must be rescued in a private copy,
    // with no persistence repair as a side effect of reviewing a share.
    var foreignStamped = try storeA.loadCanvas()
    let lowerIndex = foreignStamped.tiles.firstIndex(where: { $0.id == tileLowerID })!
    foreignStamped.tiles[lowerIndex].zoneId = zoneB
    try storeA.saveCanvas(foreignStamped)
    let foreignBytes = try Data(contentsOf: storeA.layout.canvasFile)
    let rescued = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .zone(zoneLower))
    try expect(rescued.inventory.sources.contains(where: { $0.key == keyLower && $0.tile.zoneId == zoneLower && $0.tile.frame == tileLower.frame })
               && (try Data(contentsOf: storeA.layout.canvasFile)) == foreignBytes,
               "foreign membership rescues only within its owning project without writing repaired stamps")
    var unavailableDocument = runtime.document
    let missingProject = UUID(), missingZone = UUID()
    var unavailableRegistry = try registryStore.loadOrEmpty()
    unavailableRegistry.projects.append(.init(id: missingProject, name: "Unavailable source project", rootPath: root.appendingPathComponent("unavailable-project").path,
        workspaceId: workspaceID, lastOpenedAt: now, pinned: false, missing: false))
    unavailableRegistry.workspaces[0].projectIds.append(missingProject)
    try registryStore.save(unavailableRegistry)
    unavailableDocument.zones.append(zone(id: missingZone, projectID: missingProject, x: 40_000, y: 0, name: "Unavailable source project"))
    runtime.replaceDocument(unavailableDocument, for: workspaceID)
    do {
        _ = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .workspace)
        throw CheckFailure(description: "missing project controller was silently omitted from whole-workspace coverage")
    } catch SharedAreaInventory.Failure.incompleteCoverage(let issues) {
        try expect(issues.contains(where: { $0.projectID == missingProject && $0.label == "Unavailable source project" && $0.reason == .projectUnavailable }),
                   "incomplete whole-workspace coverage names the unavailable project without acquiring it")
    }
    _ = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .zone(zoneA))
    try expect(controllerAcquisitions == beforeAcquisitions, "a scoped zone capture does not acquire unrelated unavailable projects")
    runtime.replaceDocument(document, for: workspaceID)
    var ambientDocument = runtime.document
    let ambient = note(id: UUID(), bodyID: UUID(), zone: UUID(), x: 1, y: 2, rank: 4)
    ambientDocument.ambientTiles.append(ambient)
    runtime.replaceDocument(ambientDocument, for: workspaceID)
    do {
        _ = try SharedAreaInventory.capture(runtime: runtime, supervisor: delegate.qaAgentSupervisor, selection: .workspace)
        throw CheckFailure(description: "ambient owner was silently dropped from complete capture")
    } catch SharedAreaInventory.Failure.incompleteCoverage(let issues) {
        try expect(issues.contains(where: { $0.tileID == ambient.id && $0.reason == .ambientUnsupported }),
                   "unsupported projectless source is explicitly named instead of omitted")
    }
    runtime.replaceDocument(document, for: workspaceID)
    print("Collaboration inventory checks passed: production mount, current WORLD models, source ownership, below-tier notes and fresh confirmation; no live providers or default tmux.")
}
