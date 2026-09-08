import AppKit
import ContinuumRevivedCore
import Foundation

/// CX-01 Phase 2b (`.plans/59`, §10) — visible delegation with safe retry, driven
/// through the PRODUCTION mount (`mountWorkspaceSceneAtBoot`, never
/// `install(into:)`) and the PRODUCTION dispatch entry
/// (`AppDelegate.qaWorkspaceAPI.dispatch`, the call the pi bridge makes), over a
/// REAL `AgentSupervisor` whose runner starts a FAKE `pi` on PATH.
///
/// Fixture: two projects in one workspace — Pa's zone armed and on camera, the
/// PARENT agent's project Pb in a pinned-live zone that is NOT armed and sits at
/// a non-zero origin. Every delegation therefore has to reach the parent's zone
/// rather than the armed one, and the child's WORLD frame has to land inside that
/// zone's world rect (AGENTS.md hazard 9 / `.plans/47` T4).
///
/// What each act would say when it goes red is written beside it.
@MainActor
func runWorkspaceAPIDelegationChecks() async throws {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    guard let appSupportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
        throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT — this leg mints durable agent records and must never write a real store")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(message: "refusing to run from the PROD bundle — dev channel only")
    }

    let fileManager = FileManager.default
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let tempRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-workspace-api-delegation-\(UUID().uuidString)", isDirectory: true)
    let paRoot = tempRoot.appendingPathComponent("Pa", isDirectory: true)
    let pbRoot = tempRoot.appendingPathComponent("Pb", isDirectory: true)
    let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
    let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
    for dir in [paRoot, pbRoot, appSupport, binDir] {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? fileManager.removeItem(at: tempRoot) }

    // A fake `pi --mode rpc`: it answers a prompt and settles. Enough for the
    // supervisor's real runner to start, accept the child's task and finish it —
    // no model, no auth, no network. Never a real provider.
    let fakePi = """
    #!/usr/bin/env python3
    import json, os, sys, threading, time

    cwd = os.getcwd()

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    def log(name, line):
        with open(os.path.join(cwd, name), "a") as handle:
            handle.write(line + "\\n")

    def handle(cmd):
        kind = cmd.get("type")
        log("received.log", str(kind))
        if kind == "prompt":
            log("prompts.log", json.dumps(cmd.get("message") or cmd.get("prompt") or ""))
            emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
            emit({"type": "agent_start"})
            emit({"type": "turn_start"})
            emit({"type": "turn_end"})
            emit({"type": "agent_end", "willRetry": False})
            emit({"type": "agent_settled"})
        elif kind == "abort":
            emit({"type": "response", "id": cmd.get("id"), "command": "abort", "success": True})
        else:
            emit({"type": "response", "id": cmd.get("id"), "command": kind, "success": True, "data": {}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        threading.Thread(target=handle, args=(obj,), daemon=True).start()

    time.sleep(0.3)
    """
    let executable = binDir.appendingPathComponent("pi")
    try fakePi.write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(binDir.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }

    // `send` validates the persisted harness and model against the catalogue; QA
    // never probes, so the snapshot says what the fake stands for.
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: ["fixture-model"],
        displayNames: ["fixture-model": "Fixture"], contextWindows: ["fixture-model": 1]))

    // MARK: Fixture

    let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000CB201")!
    let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000CB202")!
    let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000CB203")!
    let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000CB204")!
    let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000CB205")!
    let noteA = UUID(uuidString: "00000000-0000-0000-0000-0000000CB206")!
    let parentTile = UUID(uuidString: "00000000-0000-0000-0000-0000000CB207")!

    func makeProject(id: UUID, name: String, root: URL) -> Project {
        Project(
            id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors,
                                      browserStoragePolicy: .perProject,
                                      terminalClosePolicy: .askWhenRunning))
    }
    func note(_ id: UUID, zone: UUID, x: Double, y: Double) -> Tile {
        var tile = Tile(id: id, kind: .note, title: "note",
                        frame: TileFrame(x: x, y: y, width: 220, height: 140),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(noteId: id))
        tile.zoneId = zone
        return tile
    }

    let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
    let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
    let storePa = ProjectStore(projectRoot: paRoot)
    let storePb = ProjectStore(projectRoot: pbRoot)
    try storePa.saveProject(projectPaObj)
    try storePa.saveCanvas(CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [note(noteA, zone: zoneA, x: 640, y: 240)], groups: [], lastActiveTileId: noteA))
    try storePb.saveProject(projectPbObj)
    // WORLD frames, inside zoneB's world rect (origin 3000,400).
    try storePb.saveCanvas(CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [note(parentTile, zone: zoneB, x: 3040, y: 440)], groups: [], lastActiveTileId: parentTile))

    func placement(_ zone: UUID, project: UUID, x: Double, y: Double, w: Double, h: Double, color: String, policy: ZoneHydrationPolicy) -> ZonePlacement {
        ZonePlacement(zoneId: zone, projectId: project, origin: ZonePoint(x: x, y: y),
                      size: ZoneSize(width: w, height: h), color: color, collapsed: false, hydrationPolicy: policy)
    }
    let docA = WorkspaceDocument(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        zones: [placement(zoneA, project: projectPa, x: 600, y: 200, w: 900, h: 700, color: "blue", policy: .automatic),
                placement(zoneB, project: projectPb, x: 3000, y: 400, w: 2400, h: 1800, color: "red", policy: .pinnedLive)],
        zoneZOrder: [zoneA, zoneB],
        lastActiveZoneId: zoneA)
    try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)

    var appRegistry = Registry.empty()
    appRegistry.lastActiveWorkspaceId = workspaceWA
    appRegistry.workspaces = [
        WorkspaceEntry(id: workspaceWA, name: "A", projectIds: [projectPa, projectPb], createdAt: now, updatedAt: now),
    ]
    appRegistry.projects = [
        ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA, lastOpenedAt: now, pinned: false, missing: false),
        ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWA, lastOpenedAt: now, pinned: false, missing: false),
    ]
    let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
    try registryStore.save(appRegistry)

    let browserEngine = BrowserEngineContext()
    defer { browserEngine.shutdown() }
    let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
        if projectId == projectPa { return ZoneRuntimeController(projectRoot: paRoot, projectStore: storePa, project: projectPaObj) }
        if projectId == projectPb { return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storePb, project: projectPbObj) }
        throw Failure(message: "unexpected projectId in factory: \(projectId)")
    })

    let bootCanvasState = try storePa.loadCanvas()
    let canvas = CanvasNSView(
        canvasState: bootCanvasState,
        activeZone: docA.zones.first(where: { $0.projectId == projectPa }),
        zoneRenderModels: docA.zones.map {
            CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
        })
    canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    let delegate = AppDelegate()
    // BEFORE anything touches `workspaceAPI` (lazy, and it binds this supervisor
    // for the life of the service): a real supervisor over an isolated store.
    let supervisor = AgentSupervisor(store: AgentStore(
        applicationSupportDirectory: URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent("workspace-api-delegation-check", isDirectory: true)))
    delegate.agentSupervisor = supervisor

    let runtime = WorkspaceRuntime(
        boot: try zoneRegistry.acquire(projectId: projectPa),
        workspaceId: workspaceWA, document: docA, registry: zoneRegistry,
        focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
        ghostty: nil, browserEngine: browserEngine)
    delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
    let bootSpawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: storePa, project: projectPaObj)

    // The PARENT: a real pi record in Pb, bound to the tile in the unarmed zone.
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: pbRoot, harness: .pi,
        model: "fixture-model", thinking: "low",
        projectId: projectPb, projectRoot: pbRoot, tileId: parentTile)
    try expect(supervisor.setWorkspaceToolsEnabled(agentID: parentId, true), "enabling workspace tools must change the parent record")

    // === The production seam. NOT `install(into:)`. ===
    try delegate.mountWorkspaceSceneAtBoot(
        canvasView: canvas, spawner: bootSpawner, projectStore: storePa,
        canvasState: bootCanvasState, installsGlobalEventMonitors: false)
    canvas.layoutSubtreeIfNeeded()
    defer { supervisor.stopAll() }

    let api = delegate.qaWorkspaceAPI
    var requestCounter = 0
    func nextRequestId() -> String { requestCounter += 1; return "del-req-\(requestCounter)" }
    func dispatch(_ op: String, _ payload: [String: Any], requestId: String? = nil,
                  isCancelled: @escaping () -> Bool = { false }) -> WorkspaceAPIService.Reply {
        api.dispatch(agentId: parentId, requestId: requestId ?? nextRequestId(), op: op, payload: payload, isCancelled: isCancelled)
    }
    func result(_ reply: WorkspaceAPIService.Reply, _ what: String) throws -> [String: AnyHashableJSON] {
        guard case let .result(object) = reply else { throw Failure(message: "\(what): expected a result, got \(reply)") }
        return object
    }
    func failure(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code, _ what: String) throws -> WorkspaceAPIError {
        guard case let .error(error) = reply else { throw Failure(message: "\(what): expected \(code.rawValue), got \(reply)") }
        try expect(error.code == code, "\(what): expected \(code.rawValue), got \(error.code.rawValue) (\(error.message))")
        return error
    }
    func agentTileCount() -> Int { canvas.allWorkspaceTiles().filter { $0.kind == .managedAgent }.count }
    func zoneWorldRect(_ zoneId: UUID) throws -> CGRect {
        guard let zone = canvas.installedZonePlacement(for: zoneId) else {
            throw Failure(message: "zone \(zoneId) has no installed layer")
        }
        return CGRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
    }
    struct Baselines {
        let armed: UUID?
        let focus: FocusSurfaceID?
        let selection: UUID?
        let viewportApplies: Int
        let generation: UInt64
    }
    func baselines() -> Baselines {
        Baselines(armed: canvas.armedZoneId, focus: delegate.qaFocusBroker.activeSurface,
                  selection: canvas.canvasState.lastActiveTileId, viewportApplies: canvas.qaViewportApplyCount,
                  generation: runtime.interactionGeneration)
    }
    func expectPreserved(_ before: Baselines, _ what: String) throws {
        try expect(canvas.armedZoneId == before.armed, "\(what): the armed zone must not change (\(String(describing: canvas.armedZoneId)) vs \(String(describing: before.armed)))")
        try expect(delegate.qaFocusBroker.activeSurface == before.focus, "\(what): keyboard focus must not change")
        try expect(canvas.canvasState.lastActiveTileId == before.selection, "\(what): the selection must not change")
        try expect(runtime.interactionGeneration == before.generation, "\(what): a programmatic operation is not a user interaction")
    }

    // Fixture sanity — the whole leg is meaningless without these.
    try expect(runtime.qaHasCanvas, "the production mount must give the runtime its canvas")
    try expect(canvas.armedZoneId == zoneA, "zoneA must be armed at boot, got \(String(describing: canvas.armedZoneId))")
    try expect(canvas.installedZonePlacement(for: zoneB) != nil, "zoneB (pinnedLive) must have an installed layer")
    try expect(canvas.zoneId(containing: parentTile) == zoneB, "the parent's tile must live in the unarmed zoneB")
    try expect(agentTileCount() == 0, "no managed-agent tile exists before the first delegation")
    let recordsAtStart = supervisor.records.count

    // MARK: A — the first delegation asks the user, and a denial creates nothing

    var prompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
    api.approvalHandler = { prompt in prompts.append(prompt); return .deny }
    let beforeDenied = baselines()
    let deniedError = try failure(
        dispatch("agent.delegate", ["task": "audit the parser", "idempotencyKey": "k1"]),
        .permissionDenied, "denied delegation")
    // Red when `agent.delegate` is left in the Phase 1 preset: no prompt is shown
    // at all and the child is created without the user ever being asked.
    try expect(prompts.count == 1 && prompts[0].op == .agentDelegate,
               "the first delegation must reach the trusted approval UI as an agent.delegate prompt, got \(prompts.map(\.op))")
    try expect(deniedError.approvalRequestId == prompts[0].requestId,
               "the refusal names the host-minted approval request it showed")
    try expect(supervisor.records.count == recordsAtStart && supervisor.children(of: parentId).isEmpty && agentTileCount() == 0,
               "a denied delegation creates NOTHING: \(supervisor.records.count) records, \(supervisor.children(of: parentId).count) children, \(agentTileCount()) tiles")
    try expectPreserved(beforeDenied, "denied delegation")

    // MARK: B — provider/model overrides are refused, never silently applied

    api.approvalHandler = { prompt in prompts.append(prompt); return .allowForSession }
    let wrongProvider = try failure(
        dispatch("agent.delegate", ["task": "audit the parser", "idempotencyKey": "k-prov", "provider": "Claude Code"]),
        .unsupported, "provider override")
    try expect(wrongProvider.message.contains("Pi"), "the refusal says which provider the child would have inherited: \(wrongProvider.message)")
    _ = try failure(
        dispatch("agent.delegate", ["task": "audit the parser", "idempotencyKey": "k-model", "model": "some-other/model"]),
        .unsupported, "model override")
    // Red when the service passes an override through to the spawn: a child
    // record would exist on a provider or model the user never chose.
    try expect(supervisor.children(of: parentId).isEmpty && agentTileCount() == 0,
               "a refused override creates nothing")
    // A missing task or key is a schema error, not a default.
    _ = try failure(dispatch("agent.delegate", ["idempotencyKey": "k-noop"]), .invalidRequest, "no task")
    _ = try failure(dispatch("agent.delegate", ["task": "no key"]), .invalidRequest, "no idempotencyKey")

    // MARK: C — approved: exactly one child, visible in the PARENT's zone

    let beforeCreate = baselines()
    let promptsBeforeCreate = prompts.count
    let created = try result(
        dispatch("agent.delegate", ["task": "audit the parser", "idempotencyKey": "k1",
                                    "presentation": ["camera": "preserve"]], requestId: "op-create"),
        "approved delegation")
    // The same key the DENIAL used: a denial that burned the key would make the
    // user's approval unusable.
    try expect(prompts.count == promptsBeforeCreate + 1, "the approved delegation prompted exactly once more")
    guard let childIdString = created["childAgentId"]?.string, let childUUID = UUID(uuidString: childIdString) else {
        throw Failure(message: "the result must carry the real childAgentId: \(created)")
    }
    let childId = AgentID(rawValue: childUUID)
    try expect(supervisor.children(of: parentId) == [childId],
               "the supervisor's own record tree must name exactly this child: \(supervisor.children(of: parentId))")
    guard let child = supervisor.records[childId] else { throw Failure(message: "the child has no record") }
    // §10.1 inheritance, and §10.2's provenance in the field that already exists.
    try expect(child.parentAgentID == parentId, "the child's record must carry parentAgentID — that is the persisted provenance")
    try expect(child.harness == .pi && child.model == "fixture-model" && child.projectId == projectPb,
               "the child inherits the parent's harness, model and project: \(String(describing: child.harness)) / \(child.model) / \(String(describing: child.projectId))")
    try expect(child.worktreeId == nil && child.checkoutRoot == pbRoot.path,
               "delegation must NOT create a worktree or move the checkout: \(String(describing: child.worktreeId)) / \(child.checkoutRoot)")
    try expect(created["provider"]?.string == AgentHarness.pi.rawValue && created["model"]?.string == "fixture-model",
               "the result reports what the child actually runs")
    guard let tileIdString = created["tileId"]?.string, let childTileId = UUID(uuidString: tileIdString) else {
        throw Failure(message: "the result must carry the child's tileId: \(created)")
    }
    try expect(supervisor.records[childId]?.tileId == childTileId, "the child record is bound to its tile")
    try expect(agentTileCount() == 1, "exactly one managed-agent tile exists, got \(agentTileCount())")
    try expect(canvas.tileView(for: childTileId) is ManagedAgentTileNSView, "the child's tile is a managed-agent tile")

    // HAZARD 9 / T4: the tile is framed against the zone it was installed into.
    // Asserting the zone STAMP alone stays green through exactly the bug this
    // guards, so assert the WORLD frame against the zone's world rect.
    try expect(canvas.zoneId(containing: childTileId) == zoneB,
               "the child's tile must land in the PARENT's zone, not the armed one: \(String(describing: canvas.zoneId(containing: childTileId)))")
    guard let snapshot = canvas.navigationTileSnapshot(for: childTileId) else {
        throw Failure(message: "the child's tile has no navigation snapshot, so its world frame cannot be checked")
    }
    let childWorldRect = CGRect(x: snapshot.worldFrame.x, y: snapshot.worldFrame.y,
                                width: snapshot.worldFrame.width, height: snapshot.worldFrame.height)
    let zoneBRect = try zoneWorldRect(zoneB)
    try expect(zoneBRect.contains(childWorldRect),
               "the child's WORLD frame \(childWorldRect) must sit inside zoneB's world rect \(zoneBRect) — a frame computed against the armed zone lands here by the difference of the two origins")
    try expect(created["actualZoneId"]?.string == zoneB.uuidString, "the result reports the zone the tile actually landed in")
    try expect(created["status"]?.string == "committed" && created["partial"]?.bool == false,
               "an approved delegation whose every step succeeded is committed: \(created["status"] as Any)")
    let steps = created["steps"]?.object
    try expect(steps?["creation"]?.string == "succeeded" && steps?["attachment"]?.string == "succeeded"
               && steps?["durability"]?.string == "succeeded" && steps?["presentation"]?.string == "succeeded",
               "every step is reported separately and succeeded: \(String(describing: steps))")
    try expect(created["childRunning"] != nil, "childRunning must be reported, not omitted, when the host knows")
    // §10.1: the child is visible, and the user's keyboard is where it was.
    try expectPreserved(beforeCreate, "approved delegation")

    // The child is really DOING the work: the fake pi received its task.
    let childRecord = supervisor.records[childId]
    let childCwd = URL(fileURLWithPath: childRecord?.cwd ?? pbRoot.path, isDirectory: true)
    let taskArrived = await waitUntil(timeout: 30, pollInterval: 0.1) {
        (try? String(contentsOf: childCwd.appendingPathComponent("prompts.log"), encoding: .utf8))?
            .contains("audit the parser") == true
    }
    try expect(taskArrived, "the child's runner must actually receive the delegated task (prompts.log under \(childCwd.lastPathComponent))")

    // MARK: D — retry safety

    let retried = try result(
        dispatch("agent.delegate", ["task": "audit the parser", "idempotencyKey": "k1",
                                    "presentation": ["camera": "preserve"]], requestId: "op-create-retry"),
        "identical retry")
    // Red when the reservation happens after creation, or not at all: a second
    // child record and a second tile appear for one delegation.
    try expect(supervisor.children(of: parentId) == [childId],
               "an identical retry must NOT create a second child: \(supervisor.children(of: parentId))")
    try expect(agentTileCount() == 1, "an identical retry must not add a tile, got \(agentTileCount())")
    try expect(retried["childAgentId"]?.string == childIdString && retried["tileId"]?.string == tileIdString,
               "the retry replays the FIRST operation's identity: \(retried)")
    try expect(retried["operationId"]?.string == "op-create",
               "the replay reports the original operationId, not the retry's")

    // Same key, different payload: a new intent hiding behind an old key.
    _ = try failure(
        dispatch("agent.delegate", ["task": "rewrite the parser", "idempotencyKey": "k1"]),
        .idempotencyConflict, "same key, different payload")
    try expect(supervisor.children(of: parentId) == [childId] && agentTileCount() == 1,
               "a conflict creates nothing")

    // MARK: E — creation committed, presentation failed → child id + agent.reveal

    var injectedTile: UUID?
    api._injectPresentationFailure = { tileId in
        injectedTile = tileId
        return "the tile could not be presented (injected)"
    }
    let partial = try result(
        dispatch("agent.delegate", ["task": "check the appcast", "idempotencyKey": "k2",
                                    "presentation": ["camera": "revealResult"]], requestId: "op-partial"),
        "delegation with a failing presentation")
    api._injectPresentationFailure = nil
    guard let secondChildString = partial["childAgentId"]?.string, let secondChildUUID = UUID(uuidString: secondChildString),
          let secondTileString = partial["tileId"]?.string, let secondTileId = UUID(uuidString: secondTileString) else {
        throw Failure(message: "a presentation failure must still return the ACTUAL child and tile identity: \(partial)")
    }
    let secondChild = AgentID(rawValue: secondChildUUID)
    try expect(injectedTile == secondTileId, "the injection saw the child's own tile")
    try expect(partial["status"]?.string == "partial" && partial["partial"]?.bool == true,
               "creation committed and presentation failed is PARTIAL, not failed: \(partial["status"] as Any)")
    try expect(partial["retryOp"]?.string == "agent.reveal",
               "the retryable step is agent.reveal — never agent.delegate, which would create a second child: \(partial["retryOp"] as Any)")
    let partialSteps = partial["steps"]?.object
    try expect(partialSteps?["creation"]?.string == "succeeded" && partialSteps?["attachment"]?.string == "succeeded"
               && partialSteps?["presentation"]?.string == "failed",
               "the failed step is named and the committed ones stand: \(String(describing: partialSteps))")
    try expect(supervisor.records[secondChild] != nil && supervisor.isRunning(secondChild),
               "a presentation failure must NOT undo the spawn or kill the child (§14.3)")
    try expect(agentTileCount() == 2, "the second child has its own tile, got \(agentTileCount())")

    // The repair: `agent.reveal`, in the preset, creates nothing and presents the
    // tile that already exists. The user clicks into zoneB first — a camera
    // reveal into an UNARMED zone is unavailable (targeting is not arming, §16).
    try expect(runtime.setActiveZone(zoneB, reason: .click), "arming the parent's zone as a user click must succeed")
    let beforeReveal = baselines()
    let revealed = try result(
        dispatch("agent.reveal", ["agentId": secondChildString, "presentation": ["camera": "revealResult"]]),
        "reveal the partially presented child")
    try expect(revealed["tileId"]?.string == secondTileString && revealed["agentId"]?.string == secondChildString,
               "reveal answers with the SAME tile the delegation created: \(revealed)")
    try expect(revealed["presentation"]?.string == "navigated"
               && revealed["presentationEffects"]?.object?["camera"]?.string == "changed",
               "the reveal actually moved the camera: \(revealed)")
    try expect(canvas.qaViewportApplyCount == beforeReveal.viewportApplies + 1, "exactly one camera apply")
    try expect(supervisor.children(of: parentId).count == 2 && agentTileCount() == 2,
               "reveal creates NOTHING: \(supervisor.children(of: parentId).count) children, \(agentTileCount()) tiles")
    try expect(canvas.armedZoneId == beforeReveal.armed && delegate.qaFocusBroker.activeSurface == beforeReveal.focus
               && canvas.canvasState.lastActiveTileId == beforeReveal.selection,
               "a camera reveal touches nothing else")

    // Reveal refuses what it cannot present, and never reaches another agent.
    let strangerId = supervisor.spawn(role: nil, prompt: nil, cwd: paRoot, harness: .pi,
                                      model: "fixture-model", thinking: "low", projectId: projectPa)
    _ = try failure(dispatch("agent.reveal", ["agentId": strangerId.rawValue.uuidString]), .permissionDenied, "reveal a stranger")
    let tilelessId = supervisor.spawn(role: nil, prompt: nil, cwd: pbRoot, harness: .pi,
                                      model: "fixture-model", thinking: "low", projectId: projectPb,
                                      projectRoot: pbRoot, parentAgentID: parentId)
    _ = try failure(dispatch("agent.reveal", ["agentId": tilelessId.rawValue.uuidString]), .notFound, "reveal a child with no tile")

    // MARK: F — operation.get reflects each step

    let committedOp = try result(dispatch("operation.get", ["operationId": "op-create"]), "operation.get committed")
    try expect(committedOp["status"]?.string == "committed" && committedOp["childAgentId"]?.string == childIdString
               && committedOp["tileId"]?.string == tileIdString && committedOp["op"]?.string == "agent.delegate",
               "operation.get recovers the committed outcome and its identities: \(committedOp)")
    try expect(committedOp["steps"]?.object?["presentation"]?.string == "succeeded", "committed steps: \(committedOp["steps"] as Any)")
    let partialOp = try result(dispatch("operation.get", ["idempotencyKey": "k2"]), "operation.get by key")
    try expect(partialOp["operationId"]?.string == "op-partial" && partialOp["status"]?.string == "partial"
               && partialOp["steps"]?.object?["presentation"]?.string == "failed"
               && partialOp["failureCode"]?.string == "presentation_failed",
               "operation.get by idempotencyKey recovers the partial outcome and names the failed step: \(partialOp)")
    try expect(partialOp["childRunning"]?.bool == supervisor.isRunning(secondChild),
               "operation.get reports liveness truthfully: \(partialOp["childRunning"] as Any)")
    supervisor.stop(secondChild)
    let stoppedOp = try result(dispatch("operation.get", ["idempotencyKey": "k2"]), "operation.get after stop")
    try expect(stoppedOp["childRunning"]?.bool == false,
               "a stopped child is reported as not running: \(stoppedOp["childRunning"] as Any)")
    _ = try failure(dispatch("operation.get", ["operationId": "op-nonexistent"]), .notFound, "operation.get unknown")
    _ = try failure(dispatch("operation.get", [:]), .invalidRequest, "operation.get with no selector")

    // MARK: G — cancellation after creation reports the child truthfully

    var cancelled = false
    api._beforeCommitHook = { cancelled = true }
    let beforeCancel = baselines()
    let cancelReply = dispatch(
        "agent.delegate", ["task": "read the ledger", "idempotencyKey": "k3"],
        requestId: "op-cancel", isCancelled: { cancelled })
    api._beforeCommitHook = nil
    guard case let .cancelled(cancelResult) = cancelReply else {
        throw Failure(message: "a cancellation after the commit boundary must answer .cancelled, got \(cancelReply)")
    }
    guard let cancelObject = cancelResult else {
        throw Failure(message: "a cancellation AFTER creation must carry the committed identity, not nil")
    }
    guard let thirdChildString = cancelObject["childAgentId"]?.string, let thirdUUID = UUID(uuidString: thirdChildString) else {
        throw Failure(message: "the cancelled result must name the child that was created: \(cancelObject)")
    }
    let thirdChild = AgentID(rawValue: thirdUUID)
    try expect(supervisor.records[thirdChild] != nil, "the child created before the cancellation still exists")
    try expect(cancelObject["childRunning"]?.bool == supervisor.isRunning(thirdChild),
               "cancellation reports whether the child is still running, truthfully: \(cancelObject["childRunning"] as Any) vs \(supervisor.isRunning(thirdChild))")
    try expect(cancelObject["steps"]?.object?["presentation"]?.string == "skipped"
               && cancelObject["presentation"]?.string == "deferred",
               "a cancellation presents nothing: \(cancelObject)")
    try expect(canvas.qaViewportApplyCount == beforeCancel.viewportApplies, "a cancelled delegation moves no camera")
    let cancelledOp = try result(dispatch("operation.get", ["operationId": "op-cancel"]), "operation.get after cancel")
    try expect(cancelledOp["childAgentId"]?.string == thirdChildString,
               "the cancelled operation's identity is recoverable: \(cancelledOp)")
    let history = api.qaRecentOperations(for: parentId)
    try expect(history.contains(where: { $0.requestId == "op-cancel" && $0.outcome == "committedAfterCancel" }),
               "workspace.context history says the effect committed after the cancellation: \(history.map { "\($0.requestId):\($0.outcome)" })")

    // MARK: H — revocation stops delegation before any effect

    let childrenBeforeRevocation = supervisor.children(of: parentId).count
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, false)
    _ = try failure(dispatch("agent.delegate", ["task": "anything", "idempotencyKey": "k4"]), .permissionDenied, "policy off")
    _ = try failure(dispatch("agent.reveal", ["agentId": childIdString]), .permissionDenied, "reveal with policy off")
    try expect(supervisor.children(of: parentId).count == childrenBeforeRevocation,
               "a revoked agent creates nothing")
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, true)
    // Revocation bumped the generation, so the session grant is dead and the user
    // is asked again rather than riding an old approval.
    api.approvalHandler = { _ in .deny }
    _ = try failure(dispatch("agent.delegate", ["task": "anything", "idempotencyKey": "k5"]), .permissionDenied, "re-approval required")
    try expect(supervisor.children(of: parentId).count == childrenBeforeRevocation,
               "a re-denied delegation still creates nothing")

    // MARK: I — agent.message: the caller messages the child IT created

    // CX-01 Phase 2c. Evidence is the CHILD's own pi process: `prompts.log` in
    // its cwd is written by the fake pi when the runner delivers a prompt, so a
    // service that answered `delivered` without reaching the child leaves the
    // log short and every count below goes red.
    let msgChildCwd = URL(fileURLWithPath: supervisor.records[childId]?.cwd ?? pbRoot.path, isDirectory: true)
    func childPromptLog() -> String {
        (try? String(contentsOf: msgChildCwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
    }
    func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
    func childReceived(_ needle: String) async -> Int {
        _ = await waitUntil(timeout: 30, pollInterval: 0.1) { occurrences(needle, in: childPromptLog()) > 0 }
        return occurrences(needle, in: childPromptLog())
    }
    /// The send path refuses a child that is mid-turn, so every act waits for the
    /// previous turn to settle rather than racing it.
    func waitChildIdle() async throws {
        let idle = await waitUntil(timeout: 30, pollInterval: 0.1) { !supervisor.isRunning(childId) }
        try expect(idle, "the child must settle between messages; the fake pi answers and settles immediately")
    }

    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, true)
    // Enabled ONCE, here, before the parent's grant is minted: disabling any
    // agent's workspace tools bumps the host's single revocation generation and
    // would kill the parent's session grant mid-act.
    _ = supervisor.setWorkspaceToolsEnabled(agentID: childId, true)
    try await waitChildIdle()
    let marker1 = "MSG-ONE-8be21c"
    var messagePrompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
    api.approvalHandler = { prompt in
        prompts.append(prompt)
        messagePrompts.append(prompt)
        return .allowForSession
    }
    let beforeMessage = baselines()
    let logLinesBefore = childPromptLog().split(separator: "\n").count
    let delivered = try result(
        dispatch("agent.message", ["agentId": childIdString, "text": "\(marker1): rerun the failing leg and report the diff",
                                   "idempotencyKey": "m1"], requestId: "op-msg-1"),
        "message the caller's own child")
    // Red when `agent.message` is left in the Phase 1 preset: the user is never
    // asked before one agent writes into another agent's run.
    try expect(messagePrompts.count == 1 && messagePrompts[0].op == .agentMessage,
               "the first message must reach the trusted approval UI as an agent.message prompt, got \(messagePrompts.map(\.op))")
    try expect(messagePrompts[0].targetAgentId == childId,
               "the approval prompt names the CHILD that would be messaged, so the alert can say who: \(String(describing: messagePrompts[0].targetAgentId))")
    try expect(delivered["delivery"]?.string == "delivered",
               "the result reports delivery, and only delivery: \(delivered)")
    try expect(delivered["childAgentId"]?.string == childIdString && delivered["parentAgentId"]?.string == parentId.rawValue.uuidString,
               "the result names both ends of the delivery: \(delivered)")
    try expect(delivered["childRunning"] != nil, "childRunning must be reported, not omitted, when the host knows")
    try expect(delivered["operationId"]?.string == "op-msg-1", "the result carries this request's operation id")
    // The RESULT never carries the child's answer — this op is not a wait.
    try expect(delivered["reply"] == nil && delivered["response"] == nil && delivered["text"] == nil,
               "a delivery result must never carry the child's answer: \(delivered)")
    // THE EVIDENCE: the child's own pi process wrote the text.
    let firstDelivery = await childReceived(marker1)
    try expect(firstDelivery == 1,
               "the child's OWN runner must receive the text exactly once (prompts.log under \(msgChildCwd.lastPathComponent) held \(firstDelivery))")
    try expect(childPromptLog().split(separator: "\n").count == logLinesBefore + 1,
               "exactly one new prompt reached the child")
    // §16: a message must not steal the user's view. All five dimensions stand.
    try expectPreserved(beforeMessage, "delivered message")
    try expect(canvas.qaViewportApplyCount == beforeMessage.viewportApplies,
               "a delivered message moves no camera by default")

    // MARK: J — exactly one delivery per key

    try await waitChildIdle()
    let replayedMessage = try result(
        dispatch("agent.message", ["agentId": childIdString, "text": "\(marker1): rerun the failing leg and report the diff",
                                   "idempotencyKey": "m1"], requestId: "op-msg-1-retry"),
        "the same key replayed")
    // Red when the reservation happens after the send, or not at all: the child
    // is prompted a second time for one message — the failure this rule exists
    // to prevent. A second delivery starts a turn, so the child would be running;
    // and the log write is asynchronous, so the count is watched for a while
    // rather than sampled once (sampling passes through exactly this bug).
    try expect(!supervisor.isRunning(childId),
               "a replay must start no turn on the child")
    let doubled = await waitUntil(timeout: 5, pollInterval: 0.1) { occurrences(marker1, in: childPromptLog()) > 1 }
    try expect(!doubled,
               "a replay must deliver NOTHING a second time; the child's log holds \(occurrences(marker1, in: childPromptLog())) copies")
    try expect(replayedMessage["operationId"]?.string == "op-msg-1" && replayedMessage["delivery"]?.string == "delivered",
               "the replay returns the FIRST delivery's outcome, not a new one: \(replayedMessage)")
    let conflictMessage = try failure(
        dispatch("agent.message", ["agentId": childIdString, "text": "something else entirely", "idempotencyKey": "m1"]),
        .idempotencyConflict, "same key, different text")
    try expect(!conflictMessage.message.contains("/"), "a conflict names no path")
    try expect(occurrences("something else entirely", in: childPromptLog()) == 0,
               "a conflict delivers nothing")

    // MARK: K — scope: children only, and a refusal discloses nothing

    // A peer of the caller in the SAME checkout (a sibling), an unrelated agent
    // in ANOTHER checkout, the caller's own child's child, and the caller's own
    // parent are all out of scope. `strangerId` (project Pa) is the unrelated one.
    let siblingId = supervisor.spawn(role: nil, prompt: nil, cwd: pbRoot, harness: .pi,
                                     model: "fixture-model", thinking: "low", projectId: projectPb, projectRoot: pbRoot)
    let grandchildId = supervisor.spawn(role: nil, prompt: nil, cwd: pbRoot, harness: .pi,
                                        model: "fixture-model", thinking: "low", projectId: projectPb,
                                        projectRoot: pbRoot, parentAgentID: childId)
    for (label, target) in [("a sibling", siblingId), ("an unrelated agent in another checkout", strangerId),
                            ("the caller's own child's child", grandchildId)] {
        let denial = try failure(
            dispatch("agent.message", ["agentId": target.rawValue.uuidString, "text": "reach \(label)", "idempotencyKey": "m-\(target.rawValue.uuidString)"]),
            .permissionDenied, "message \(label)")
        try expect(!denial.message.contains("/"), "the refusal for \(label) names no path: \(denial.message)")
        try expect(denial.message.range(of: "[0-9A-Fa-f]{8}-", options: .regularExpression) == nil,
                   "the refusal for \(label) names no id: \(denial.message)")
        try expect(occurrences("reach \(label)", in: childPromptLog()) == 0, "an out-of-scope message delivers nothing")
    }
    // Upward is out of scope too: the CHILD may not message its own parent.
    _ = try failure(
        api.dispatch(agentId: childId, requestId: "op-msg-upward",
                     op: "agent.message",
                     payload: ["agentId": parentId.rawValue.uuidString, "text": "reach my parent", "idempotencyKey": "m-up"]),
        .permissionDenied, "a child messaging its own parent")
    // Messaging SELF is a different mistake, and says so.
    let selfError = try failure(
        dispatch("agent.message", ["agentId": parentId.rawValue.uuidString, "text": "note to self", "idempotencyKey": "m-self"]),
        .invalidRequest, "message self")
    try expect(selfError.message.lowercased().contains("itself"),
               "messaging yourself explains why: an agent continues its own turn instead: \(selfError.message)")

    // MARK: L — bounds, and nothing delivered past them

    let oversize = String(repeating: "x", count: AgentMessageRequest.textByteCeiling + 1)
    _ = try failure(dispatch("agent.message", ["agentId": childIdString, "text": oversize, "idempotencyKey": "m-big"]),
                    .invalidRequest, "text over the ceiling")
    _ = try failure(dispatch("agent.message", ["agentId": childIdString, "text": "   ", "idempotencyKey": "m-blank"]),
                    .invalidRequest, "whitespace-only text")
    _ = try failure(dispatch("agent.message", ["agentId": childIdString, "text": "no key here"]),
                    .invalidRequest, "no idempotencyKey")
    try expect(occurrences("xxxxxxxxxx", in: childPromptLog()) == 0 && occurrences("no key here", in: childPromptLog()) == 0,
               "a request refused at the bounds delivers nothing")

    // MARK: M — one prompt per agent session, and a denial delivers nothing

    try await waitChildIdle()
    let marker2 = "MSG-TWO-4d19af"
    let promptsBeforeSecond = messagePrompts.count
    let second = try result(
        dispatch("agent.message", ["agentId": childIdString, "text": "\(marker2): and check the appcast",
                                   "idempotencyKey": "m2"], requestId: "op-msg-2"),
        "a second message under the session grant")
    // Red when the grant is minted single-use, or not minted at all: the user is
    // asked again for every message they already approved for this session.
    try expect(messagePrompts.count == promptsBeforeSecond,
               "\"allow for session\" must cover later messages: \(messagePrompts.count - promptsBeforeSecond) extra prompt(s)")
    try expect(second["delivery"]?.string == "delivered", "the second message is delivered: \(second)")
    let secondDelivery = await childReceived(marker2)
    try expect(secondDelivery == 1, "the second message reaches the child exactly once, got \(secondDelivery)")

    // A denial. Revocation first, so the session grant is dead and the user is
    // asked again rather than riding the old approval.
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, false)
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, true)
    try await waitChildIdle()
    api.approvalHandler = { prompt in prompts.append(prompt); messagePrompts.append(prompt); return .deny }
    let deniedMessage = try failure(
        dispatch("agent.message", ["agentId": childIdString, "text": "MSG-DENIED-0f10: do not do this",
                                   "idempotencyKey": "m3"]),
        .permissionDenied, "a denied message")
    try expect(deniedMessage.approvalRequestId != nil, "the refusal names the approval request it showed")
    try expect(occurrences("MSG-DENIED-0f10", in: childPromptLog()) == 0, "a denied message delivers nothing")
    try expect(!deniedMessage.message.contains("/"), "a denial names no path")

    // MARK: N — policy off, and the catalogue seam

    api.approvalHandler = { prompt in prompts.append(prompt); messagePrompts.append(prompt); return .allowForSession }
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, false)
    _ = try failure(
        dispatch("agent.message", ["agentId": childIdString, "text": "MSG-REVOKED-77: after the switch", "idempotencyKey": "m4"]),
        .permissionDenied, "message with workspace tools off")
    try expect(occurrences("MSG-REVOKED-77", in: childPromptLog()) == 0, "a revoked agent delivers nothing")
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, true)

    // The known seam: `AgentSupervisor.send` refuses unless the catalogue reports
    // the harness ready AND lists the record's model. That is a structured
    // `unsupported` with the reason — never a crash, and never a silent success.
    try await waitChildIdle()
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .loggedOut, models: []))
    let notReady = try failure(
        dispatch("agent.message", ["agentId": childIdString, "text": "MSG-NOTREADY-91: while the catalogue is out",
                                   "idempotencyKey": "m5"]),
        .unsupported, "message while the catalogue is not ready")
    try expect(notReady.message.lowercased().contains("logged out"),
               "the unsupported answer carries the send path's own reason: \(notReady.message)")
    try expect(occurrences("MSG-NOTREADY-91", in: childPromptLog()) == 0,
               "a catalogue refusal delivers nothing")
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: ["fixture-model"],
        displayNames: ["fixture-model": "Fixture"], contextWindows: ["fixture-model": 1]))
    // The same key is usable again once the cause is gone: nothing was delivered
    // under it, so it never burned.
    try await waitChildIdle()
    let afterRecovery = try result(
        dispatch("agent.message", ["agentId": childIdString, "text": "MSG-NOTREADY-91: while the catalogue is out",
                                   "idempotencyKey": "m5"], requestId: "op-msg-5-retry"),
        "the same key after the cause is gone")
    try expect(afterRecovery["delivery"]?.string == "delivered", "a retry after a no-op failure delivers: \(afterRecovery)")
    let recoveredDelivery = await childReceived("MSG-NOTREADY-91")
    try expect(recoveredDelivery == 1, "and delivers exactly once, got \(recoveredDelivery)")

    supervisor.stopAll()
}
