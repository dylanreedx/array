import AppKit
import ContinuumRevivedCore
import Foundation

/// `--helper-tile-tidy-check`: "Tidy finished helper tiles", driven through
/// production. A lead in a live zone delegates helpers over the real workspace
/// API (`agent.delegate`); each runs and finishes on a scripted runner; the
/// supervisor's own flush delivers its result to the lead; and the app's own
/// timer closes the tile. Two mid-grace looks call the sweep directly to show
/// it holds the tile; every close is the timer's.
///
/// Positive: a finished, delivered, untouched helper's tile leaves the zone
/// layer and the saved canvas after the grace period, no other tile moves, the
/// record parks in History with its row still under the lead, and reopening
/// the row brings the tile back.
///
/// Negative controls: a failed helper, a helper looked at after finishing, one
/// with an unsent draft, one resized by the person, a user-started agent, and
/// every helper while the setting is off all keep their tiles.
@MainActor
func runHelperTileTidyChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    guard let appSupportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
        throw Failure(description: "refusing to run without CONTINUUM_APP_SUPPORT — this leg mints durable agent records")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(description: "refusing to run from the PROD bundle — dev channel only")
    }

    let fileManager = FileManager.default
    let now = Date()
    let tempRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-helper-tile-tidy-\(UUID().uuidString)", isDirectory: true)
    let root = tempRoot.appendingPathComponent("Pb", isDirectory: true)
    let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
    for dir in [root, appSupport] { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? fileManager.removeItem(at: tempRoot) }

    // Private settings: Managed mode off (helpers get their tile at delegation)
    // and the tidy setting at its default. Never the user's own defaults.
    let suiteName = "array.qa.helper-tile-tidy.\(UUID().uuidString)"
    let settings = QAIsolatedDefaults(isolatedSuiteName: suiteName)!
    settings.removePersistentDomain(forName: suiteName)
    settings.set(false, forKey: AgentManagedModeConfig.enabledKey)
    // Auto layout ON, so a close that settled the zone would slide its
    // neighbours and "no other tile moved" can fail.
    settings.set(true, forKey: CanvasAutoLayoutConfig.enabledKey)
    defer { settings.removePersistentDomain(forName: suiteName) }
    try expect(HelperTileTidyConfig.enabled(defaults: settings), "the setting is on by default")

    AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)

    let workspaceId = UUID()
    let projectId = UUID()
    let zoneId = UUID()
    let project = Project(
        id: projectId, name: "Pb", rootPath: root.path, createdAt: now, updatedAt: now,
        defaultLaunchProfileId: "shell", editorPreference: .auto,
        settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                  terminalClosePolicy: .askWhenRunning))
    let store = ProjectStore(projectRoot: root)
    try store.saveProject(project)
    try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
    let zone = ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 200, y: 200),
                             size: ZoneSize(width: 4000, height: 3000), color: "blue", collapsed: false,
                             hydrationPolicy: .pinnedLive)
    let document = WorkspaceDocument(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), zones: [zone],
                                     zoneZOrder: [zoneId], lastActiveZoneId: zoneId)
    try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
    var registry = Registry.empty()
    registry.lastActiveWorkspaceId = workspaceId
    registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "W", projectIds: [projectId], createdAt: now, updatedAt: now)]
    registry.projects = [ProjectEntry(id: projectId, name: "Pb", rootPath: root.path, workspaceId: workspaceId,
                                      lastOpenedAt: now, pinned: false, missing: false)]
    let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
    try registryStore.save(registry)

    let browserEngine = BrowserEngineContext()
    defer { browserEngine.shutdown() }
    let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
        guard id == projectId else { throw Failure(description: "unexpected project \(id)") }
        return ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
    })
    let bootCanvasState = try store.loadCanvas()
    let canvas = CanvasNSView(canvasState: bootCanvasState, activeZone: zone,
                              zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: zone, displayName: "Zone")])
    canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    canvas.autoLayoutDefaults = settings

    let delegate = AppDelegate()
    delegate.qaSettingsDefaults = settings
    // The next helper launched while this is set fails its turn; everything
    // else succeeds. (A launch is built inside `agent.delegate`, before the
    // supervisor stamps the brief on the record.)
    var nextHelperFails = false
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent("helper-tile-tidy-check", isDirectory: true)),
        makeRunner: { launch -> AgentRunning in
            let fails = launch.record.parentAgentID != nil && nextHelperFails
            if fails { nextHelperFails = false }
            let turn = UUID().uuidString
            return ScriptedAgentRunner(script: [
                .turnStarted(threadId: "fixture", turnId: turn),
                .turnCompleted(threadId: "fixture", turnId: turn, outcome: fails ? .failed : .completed,
                               errorMessage: fails ? "fixture failure" : nil),
            ])
        },
        submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: appSupport),
        transcriptStore: AgentTranscriptStore(root: appSupport.appendingPathComponent("transcripts")))
    delegate.agentSupervisor = supervisor
    let runtime = WorkspaceRuntime(
        boot: try zoneRegistry.acquire(projectId: projectId), workspaceId: workspaceId, document: document,
        registry: zoneRegistry, focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
        ghostty: nil, browserEngine: browserEngine)
    delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
    let bootSpawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: project)
    // === The production seam: wires the supervisor's delivery hook and the
    // canvas's geometry hook exactly as boot does. ===
    try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: bootSpawner, projectStore: store,
                                           canvasState: bootCanvasState, installsGlobalEventMonitors: false)
    canvas.layoutSubtreeIfNeeded()
    defer { supervisor.stopAll() }
    supervisor.workspaceToolsPermission = { .free }
    let api = delegate.qaWorkspaceAPI
    api.approvalHandler = { _ in .allowForSession }
    // Internal timing, shortened: production waits two minutes.
    delegate.helperTileTidyGrace = 1.0
    delegate.helperTileTidyRetry = 0.2
    try expect(delegate.helperTileTidyGrace == 1.0, "the grace period is settable for the witness")

    // The lead: a user-started agent with its own tile in the zone.
    let model = AgentModelCatalog.shared.snapshot(for: .claudeCode).seedModel!
    let spawner = try runtime.ensureSpawner(forProjectId: projectId)
    let scope = CreationScope(projectId: projectId, projectRoot: root.path, homeRelativePath: nil, source: .zone, zoneId: zoneId)
    func userAgent(_ name: String) throws -> (AgentID, UUID) {
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: model, thinking: "low",
                                  projectId: projectId, projectRoot: root, displayName: name)
        guard case let .spawned(tile) = spawner.spawnManagedAgentForExistingAgent(id, supervisor: supervisor, creationScope: scope) else {
            throw Failure(description: "setup: \(name) got no tile")
        }
        supervisor.attach(agentID: id, to: tile)
        delegate.wireManagedAgentTile(tile, agentID: id)
        return (id, tile)
    }
    let (lead, leadTile) = try userAgent("Tidy lead")
    try expect(supervisor.setWorkspaceToolsEnabled(agentID: lead, true) || supervisor.records[lead]?.workspaceToolsEnabled == true,
               "setup: the lead may use workspace tools")

    var keySerial = 0
    /// Delegate one helper through the real API and wait for its result to be
    /// delivered to the lead by the supervisor's own flush.
    func delegateAndDeliver(_ task: String, from caller: AgentID? = nil, expectDelivery: Bool = true) async throws -> (AgentID, UUID) {
        keySerial += 1
        let key = "tidy-\(keySerial)"
        let reply = api.dispatch(agentId: caller ?? lead, requestId: key, op: "agent.delegate",
                                 payload: ["task": task, "idempotencyKey": key, "presentation": ["camera": "preserve"]])
        guard case let .result(object) = reply, let raw = object["childAgentId"]?.string, let uuid = UUID(uuidString: raw) else {
            throw Failure(description: "agent.delegate refused '\(task)': \(reply)")
        }
        let child = AgentID(rawValue: uuid)
        guard let tile = supervisor.records[child]?.tileId, canvas.tileRecord(for: tile) != nil else {
            throw Failure(description: "'\(task)': a Free-mode helper gets its tile at delegation")
        }
        try expect(canvas.zoneId(containing: tile) == zoneId, "'\(task)': the helper's tile sits in its lead's zone")
        delegate.wireManagedAgentTile(tile, agentID: child)
        let delivered = await waitUntil(timeout: 20, pollInterval: 0.02) {
            (!expectDelivery || supervisor.helperResultDeliveredAt[child] != nil) && !supervisor.isRunning(child)
                && supervisor.records[child]?.latestTerminalEvent != nil
        }
        try expect(delivered, "'\(task)': the helper finished and its result was delivered to the lead")
        return (child, tile)
    }
    func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func worldFrames(except excluded: Set<UUID>) -> [UUID: TileFrame] {
        Dictionary(uniqueKeysWithValues: canvas.allWorkspaceTiles().filter { !excluded.contains($0.id) }.compactMap { tile in
            canvas.navigationTileSnapshot(for: tile.id).map { (tile.id, $0.worldFrame) }
        })
    }

    // 1 · THE SETTING OFF keeps every tile.
    settings.set(false, forKey: HelperTileTidyConfig.enabledKey)
    let (offHelper, offTile) = try await delegateAndDeliver("Setting off helper")
    await settle(2.0)
    try expect(canvas.tileRecord(for: offTile) != nil && supervisor.records[offHelper]?.archivedAt == nil,
               "setting off: the finished helper keeps its tile")
    print("PASS setting off: finished helper keeps its tile")
    settings.removeObject(forKey: HelperTileTidyConfig.enabledKey)

    // 2 · A FAILED helper keeps its tile.
    nextHelperFails = true
    let (failed, failedTile) = try await delegateAndDeliver("Failing helper")
    try expect(!nextHelperFails && supervisor.records[failed]?.latestTerminalEvent?.outcome == .failed,
               "failed: setup — the helper's turn failed, got \(String(describing: supervisor.records[failed]?.latestTerminalEvent?.outcome))")
    await settle(2.0)
    try expect(canvas.tileRecord(for: failedTile) != nil && supervisor.records[failed]?.archivedAt == nil,
               "failed: the helper keeps its tile — refusal \(String(describing: delegate.qaHelperTileTidyRefusals[failed]))")
    try expect(delegate.qaHelperTileTidyRefusals[failed] == "did not succeed",
               "failed: kept because it did not succeed, got \(String(describing: delegate.qaHelperTileTidyRefusals[failed]))")
    print("PASS failed helper keeps its tile (did not succeed)")

    // 3 · LOOKED AT after finishing: the tile focus bridge marks it visited.
    let (looked, lookedTile) = try await delegateAndDeliver("Looked-at helper")
    supervisor.focusTile(lookedTile)
    supervisor.focusTile(leadTile)
    await settle(2.0)
    try expect(canvas.tileRecord(for: lookedTile) != nil,
               "focused: the helper keeps its tile — refusal \(String(describing: delegate.qaHelperTileTidyRefusals[looked]))")
    try expect(delegate.qaHelperTileTidyRefusals[looked] == "looked at since finishing",
               "focused: kept because it was looked at, got \(String(describing: delegate.qaHelperTileTidyRefusals[looked]))")
    print("PASS focused helper keeps its tile (looked at since finishing)")

    // 4 · TYPED INTO, then cleared: the edit counts even with no draft left.
    let (typed, typedTile) = try await delegateAndDeliver("Typed-into helper")
    guard let typedView = canvas.tileView(for: typedTile) as? ManagedAgentTileNSView,
          let composer = typedView.qaComposerForChecks else { throw Failure(description: "typed: no composer") }
    await composer.qaAwaitDraftRestore()
    composer.textView.insertText("half a thought", replacementRange: NSRange(location: 0, length: 0))
    try expect(typedView.hasUnsentDraft, "typed: the composer holds the unsent words")
    composer.textView.insertText("", replacementRange: NSRange(location: 0, length: (composer.textView.string as NSString).length))
    try expect(!typedView.hasUnsentDraft, "typed: the draft was cleared again")
    await settle(2.0)
    try expect(canvas.tileRecord(for: typedTile) != nil,
               "typed: the helper keeps its tile — refusal \(String(describing: delegate.qaHelperTileTidyRefusals[typed]))")
    try expect(delegate.qaHelperTileTidyRefusals[typed] == "handled since finishing",
               "typed: kept because the person typed in it, got \(String(describing: delegate.qaHelperTileTidyRefusals[typed]))")
    print("PASS typed-into helper keeps its tile, draft cleared or not (handled since finishing)")

    // 5 · RESIZED by the person: the pointer resize's own geometry sequence
    //     (`TileNSView` press → drag → release).
    let (resized, resizedTile) = try await delegateAndDeliver("Resized helper")
    try expect(canvas.beginGeometryEdit(.resizeTile, tileIds: [resizedTile], includeAllZones: true), "resize: the gesture begins")
    canvas.beginAutoLayoutGesture()
    guard var grown = canvas.tileRecord(for: resizedTile) else { throw Failure(description: "resize: no tile") }
    grown.frame.width += 60
    canvas.updateTile(grown, recalculateZoneBounds: false, notifyChange: false)
    _ = canvas.finishAutoLayoutGesture()
    try expect(canvas.commitGeometryEdit() != nil, "resize: the edit commits")
    await settle(2.0)
    try expect(canvas.tileRecord(for: resizedTile) != nil,
               "resized: the helper keeps its tile — refusal \(String(describing: delegate.qaHelperTileTidyRefusals[resized]))")
    try expect(delegate.qaHelperTileTidyRefusals[resized] == "handled since finishing",
               "resized: kept because the person resized it, got \(String(describing: delegate.qaHelperTileTidyRefusals[resized]))")
    print("PASS resized helper keeps its tile (handled since finishing)")

    // 6 · A USER-STARTED agent that finishes a turn keeps its tile.
    let (userStarted, userTile) = try userAgent("User agent")
    try expect(supervisor.send("do a thing", to: userStarted), "user agent: the prompt is accepted")
    let userFinished = await waitUntil(timeout: 10, pollInterval: 0.02) {
        !supervisor.isRunning(userStarted) && supervisor.records[userStarted]?.latestTerminalEvent != nil
    }
    try expect(userFinished, "user agent: its turn finished")
    await settle(2.0)
    try expect(canvas.tileRecord(for: userTile) != nil && supervisor.records[userStarted]?.archivedAt == nil,
               "user-started: the agent keeps its tile")
    try expect(supervisor.helperTileTidyRefusal(userStarted, now: Date()) == "not a delegated helper",
               "user-started: never a candidate, got \(String(describing: supervisor.helperTileTidyRefusal(userStarted, now: Date())))")
    print("PASS user-started agent keeps its tile (not a delegated helper)")

    // 7 · A HELPER WITH A HELPER OF ITS OWN still on the canvas keeps its tile.
    //     The middle helper delivers to the lead; then it delegates a helper
    //     that fails and keeps its tile. The middle collects rather than being
    //     woken (`helperCompletionEnabled`, the supervisor's capability stand-in
    //     for a collect-mode lead), so its own delivered turn stays its latest.
    let (middle, middleTile) = try await delegateAndDeliver("Middle helper")
    supervisor.helperCompletionEnabled = { $0 != middle }
    nextHelperFails = true
    let (_, grandchildTile) = try await delegateAndDeliver("Grandchild helper", from: middle, expectDelivery: false)
    supervisor.helperCompletionEnabled = nil
    await settle(2.0)
    try expect(canvas.tileRecord(for: middleTile) != nil && canvas.tileRecord(for: grandchildTile) != nil,
               "live child: the middle helper keeps its tile while its failed helper keeps one")
    try expect(delegate.qaHelperTileTidyRefusals[middle] == "a helper still has its tile",
               "live child: kept for its helper, got \(String(describing: delegate.qaHelperTileTidyRefusals[middle]))")
    print("PASS a helper whose own helper keeps its tile keeps its tile too")
    // …and once the person closes that helper's tile, the middle one is decided
    // again. (Closing a tile hands focus to the top tile — here the middle one —
    // and that focus counts as a look, so it is then kept for that reason.)
    try expect(!DeleteConfirmPolicy.current.requiresConfirmation(for: .managedAgent),
               "setup: this machine's delete-confirm policy would put a modal alert in front of deleteTile")
    delegate.deleteTile(id: grandchildTile)
    let middleRedecided = await waitUntil(timeout: 10, pollInterval: 0.02) {
        canvas.tileRecord(for: middleTile) == nil
            || (delegate.qaHelperTileTidyRefusals[middle].map { $0 != "a helper still has its tile" } ?? false)
    }
    try expect(middleRedecided, "child closed: the middle helper is decided again, got \(String(describing: delegate.qaHelperTileTidyRefusals[middle]))")
    print("PASS closing that helper's tile re-decides the middle helper (now: \(canvas.tileRecord(for: middleTile) == nil ? "tidied" : delegate.qaHelperTileTidyRefusals[middle] ?? "?"))")

    // 8 · A RESULT THE LEAD HAS NOT RECEIVED keeps the tile. Stop pauses the
    //     lead's queue: the helper's result is admitted there and waits.
    supervisor.stop(lead)
    try expect(supervisor.isQueuePaused(for: lead), "paused: setup — Stop pauses the lead's queue")
    let (held, heldTile) = try await delegateAndDeliver("Held-result helper", expectDelivery: false)
    await settle(delegate.helperTileTidyGrace * 2.5)
    try expect(canvas.tileRecord(for: heldTile) != nil && supervisor.helperResultDeliveredAt[held] == nil,
               "paused: a result sitting in a paused queue is not received, and the tile stays")
    supervisor.resumeQueue(for: lead)
    let receivedOK = await waitUntil(timeout: 20, pollInterval: 0.02) { supervisor.helperResultDeliveredAt[held] != nil }
    try expect(receivedOK, "paused: resuming the queue hands the result to the lead")
    let received = supervisor.helperResultDeliveredAt[held]!
    await settle(delegate.helperTileTidyGrace * 0.5)
    delegate.sweepFinishedHelperTiles()
    try expect(canvas.tileRecord(for: heldTile) != nil && delegate.qaHelperTileTidyRefusals[held] == "grace",
               "paused: the grace period runs from receipt, got \(String(describing: delegate.qaHelperTileTidyRefusals[held]))")
    let heldClosed = await waitUntil(timeout: 10, pollInterval: 0.02) { canvas.tileRecord(for: heldTile) == nil }
    try expect(heldClosed && Date().timeIntervalSince(received) >= delegate.helperTileTidyGrace,
               "paused: the tile closes once the grace period after receipt has passed")
    print("PASS a result held in a stopped lead's queue keeps the tile until received, then grace runs from receipt")

    // 9 · THE POSITIVE CASE: finished, delivered, untouched.
    try expect(canvas.isAutoLayoutActive(inZone: zoneId), "setup: auto layout is active in the zone, so a settle would move tiles")
    let (done, doneTile) = try await delegateAndDeliver("Finished helper")
    await settle(delegate.helperTileTidyGrace * 0.5)
    delegate.sweepFinishedHelperTiles()
    try expect(canvas.tileRecord(for: doneTile) != nil, "done: the tile stays through the grace period")
    try expect(delegate.qaHelperTileTidyRefusals[done] == "grace",
               "done: a sweep inside the grace period holds it for grace, got \(String(describing: delegate.qaHelperTileTidyRefusals[done]))")
    let othersBefore = worldFrames(except: [doneTile])
    let closed = await waitUntil(timeout: 10, pollInterval: 0.02) { canvas.tileRecord(for: doneTile) == nil }
    try expect(closed, "done: the finished helper's tile closes by itself — refusal \(String(describing: delegate.qaHelperTileTidyRefusals[done]))")
    try expect(canvas.zoneId(containing: doneTile) == nil
               && !(canvas.tilesInWorldFrames(forZoneId: zoneId) ?? []).contains { $0.id == doneTile },
               "done: the tile left the zone layer")
    let savedTiles = try store.loadCanvas().tiles
    try expect(!savedTiles.contains { $0.id == doneTile }, "done: the tile left the saved canvas")
    try expect(worldFrames(except: [doneTile]) == othersBefore, "done: no other tile moved")
    guard let parked = supervisor.records[done] else { throw Failure(description: "done: the agent record must remain") }
    try expect(parked.archivedAt != nil && parked.tileId == nil && parked.parentAgentID == lead,
               "done: the record parks in History exactly as a closed tile does, still the lead's child")
    guard let row = delegate.agentInboxRowsForQA().first(where: { $0.id == done.rawValue }) else {
        throw Failure(description: "done: the agent keeps its sidebar row")
    }
    try expect(row.parentId == lead.rawValue, "done: the row stays under its lead, got parent \(String(describing: row.parentId))")
    print("PASS finished helper's tile closed; record parked in History, row under its lead, no other tile moved")

    // Reopen from the row restores the tile.
    try expect(delegate.revealAgentFromInbox(done.rawValue), "reopen: the row opens the agent")
    guard let reopenedTile = supervisor.records[done]?.tileId, canvas.tileRecord(for: reopenedTile) != nil else {
        throw Failure(description: "reopen: the agent has a tile on the canvas again")
    }
    try expect(supervisor.records[done]?.archivedAt == nil, "reopen: the agent is out of History")
    print("PASS reopening the row restores the helper's tile")

    // Every negative control still holds its tile at the end.
    for (name, tile) in [("setting off", offTile), ("failed", failedTile), ("looked at", lookedTile),
                         ("typed into", typedTile), ("resized", resizedTile), ("user-started", userTile), ("lead", leadTile)] {
        try expect(canvas.tileRecord(for: tile) != nil, "\(name): the tile is still on the canvas at the end")
    }
}
