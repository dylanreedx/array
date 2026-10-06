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
    // Upward is out of scope too: the CHILD may not message its own parent. The
    // child needs its own policy on to be a caller at all; flipping one agent's
    // policy leaves every other agent's live grants alone (§14.1), so this
    // belongs here, where the child first acts, rather than hoisted out of the way.
    _ = supervisor.setWorkspaceToolsEnabled(agentID: childId, true)
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

    // MARK: O — the same host over MCP (T3): the real `array-workspace-mcp`
    // binary, through the production listener `mountWorkspaceSceneAtBoot` wired

    // Claude and Codex reach Array only this way. Red before T3: the binary
    // listed six tools, so `array_delegate`, `array_message_agent` and a wait
    // did not exist for them at all, and refusals came back without isError.
    guard let helper = AppDelegate.workspaceMCPExecutablePath() else {
        throw Failure(message: "array-workspace-mcp is not beside the app binary — build the package, not just the Array product")
    }
    // A fresh agent session: the delegation and message grants above are gone,
    // so the user is asked again over MCP exactly as over the pi bridge.
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, false)
    _ = supervisor.setWorkspaceToolsEnabled(agentID: parentId, true)
    guard let mcpConfig = delegate.workspaceMCPHost.configuration(for: parentId, serverExecutable: helper) else {
        throw Failure(message: "the production MCP host issued no registration")
    }
    let client = try WorkspaceMCPCheckClient(executable: helper, environment: mcpConfig.environment)
    defer { client.close() }

    let initialized = try await client.request("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:] as [String: Any]])
    try expect(((initialized["result"] as? [String: Any])?["instructions"] as? String)?.contains("array_delegate") == true,
               "MCP initialize must carry instructions that name array_delegate: \(initialized)")

    // Parity over the wire: every tool the binary lists is the catalog entry pi
    // registers — same name, same schema, pi's description and guidelines.
    let listed = try await client.request("tools/list", [:])
    let listedTools = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
    guard let catalogURL = PiExtensionInstaller.bundledExtensionURL(fileName: WorkspaceMCPToolCatalog.fileName),
          let catalogData = FileManager.default.contents(atPath: catalogURL.path),
          let catalogRoot = try JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
          let rawTools = catalogRoot["tools"] as? [[String: Any]] else {
        throw Failure(message: "the shared catalog beside the pi extension is unreadable")
    }
    try expect(listedTools.compactMap { $0["name"] as? String }
               == rawTools.compactMap { $0["name"] as? String } + [WorkspaceMCPToolCatalog.waitAgentsName],
               "MCP tools/list must be the pi catalog plus wait_agents: \(listedTools.compactMap { $0["name"] as? String })")
    for raw in rawTools {
        let name = raw["name"] as? String ?? "?"
        guard let wire = listedTools.first(where: { $0["name"] as? String == name }),
              let wireDescription = wire["description"] as? String,
              let wireSchema = wire["inputSchema"] as? NSDictionary,
              let rawSchema = raw["parameters"] as? NSDictionary else {
            throw Failure(message: "\(name) is missing from tools/list or malformed")
        }
        try expect(wireSchema.isEqual(rawSchema), "\(name)'s MCP inputSchema differs from the catalog pi registers")
        try expect(wireDescription.hasPrefix(raw["description"] as? String ?? "\u{0}")
                   && ((raw["promptGuidelines"] as? [String]) ?? []).allSatisfy(wireDescription.contains),
                   "\(name)'s MCP description must carry pi's description and every guideline")
    }

    func toolCall(_ name: String, _ arguments: [String: Any], meta: [String: Any]? = nil) async throws -> (isError: Bool, reply: [String: Any]) {
        var params: [String: Any] = ["name": name, "arguments": arguments]
        if let meta { params["_meta"] = meta }
        let response = try await client.request("tools/call", params)
        guard let result = response["result"] as? [String: Any],
              let reply = result["structuredContent"] as? [String: Any] else {
            throw Failure(message: "\(name): no structured result: \(response)")
        }
        return (result["isError"] as? Bool ?? false, reply)
    }

    // Honest context: delegation is neither a capability nor impossible.
    let mcpContext = try await toolCall("array_workspace_context", [:])
    let contextResult = mcpContext.reply["result"] as? [String: Any] ?? [:]
    let advertised = contextResult["capabilities"] as? [String] ?? []
    let needsApproval = contextResult["approvalRequired"] as? [String] ?? []
    try expect(!mcpContext.isError && !advertised.contains("agent.delegate") && needsApproval.contains("agent.delegate")
               && needsApproval.contains("agent.message") && Set(advertised).isDisjoint(with: needsApproval),
               "context must list what needs the user's approval apart from what is callable now: capabilities=\(advertised) approvalRequired=\(needsApproval)")

    // array_delegate over MCP: the user is asked, then exactly one child tile
    // lands inside the PARENT's zone.
    var mcpPrompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
    api.approvalHandler = { prompt in mcpPrompts.append(prompt); return .allowForSession }
    let childrenBeforeMCP = Set(supervisor.children(of: parentId))
    let tilesBeforeMCP = agentTileCount()
    let mcpMarker = "MCP-TASK-5e0c71"
    // claude names its call in `_meta` (measured, 2.1.291); codex's spelling is
    // asserted below. T4b: that id must become the operation AND the chip's
    // `sourceItemID`, or the chip cannot supersede the call's transcript row.
    let claudeToolUseID = "toolu_01McpDelegateWitness0001"
    let delegated = try await toolCall("array_delegate", ["task": "\(mcpMarker): summarise the ledger",
                                                          "idempotencyKey": "mcp-k1",
                                                          "presentation": ["camera": "preserve"]],
                                       meta: ["claudecode/toolUseId": claudeToolUseID])
    try expect(!delegated.isError && delegated.reply["status"] as? String == "ok",
               "an approved MCP delegation succeeds: \(delegated.reply)")
    try expect(mcpPrompts.map(\.op) == [.agentDelegate], "the MCP delegation reached the trusted approval UI once: \(mcpPrompts.map(\.op))")
    let delegatedResult = delegated.reply["result"] as? [String: Any] ?? [:]
    let newChildren = Set(supervisor.children(of: parentId)).subtracting(childrenBeforeMCP)
    guard newChildren.count == 1, let mcpChild = newChildren.first,
          delegatedResult["childAgentId"] as? String == mcpChild.rawValue.uuidString,
          let mcpTileText = delegatedResult["tileId"] as? String, let mcpTile = UUID(uuidString: mcpTileText),
          let mcpOperation = delegatedResult["operationId"] as? String else {
        throw Failure(message: "an MCP delegation must create exactly one child and report it: new children \(newChildren), result \(delegatedResult)")
    }
    try expect(agentTileCount() == tilesBeforeMCP + 1, "exactly one new managed-agent tile, got \(agentTileCount() - tilesBeforeMCP)")
    /// The `sourceItemID` the supervisor's chip for `child` carried on the
    /// parent's own stream (replayed from history to a fresh subscriber).
    func chipSource(for child: AgentID) async -> String? {
        final class Seen: @unchecked Sendable { var source: String?? }
        let seen = Seen()
        let stream = supervisor.events(for: parentId)
        let reader = Task { @MainActor in
            for await event in stream {
                if case let .childAgentSpawned(_, childID, _, _, source, _, _) = event, childID == child.rawValue {
                    seen.source = .some(source)
                    return
                }
            }
        }
        defer { reader.cancel() }
        _ = await waitUntil(timeout: 5, pollInterval: 0.02) { seen.source != nil }
        return seen.source ?? nil
    }
    try expect(mcpOperation == claudeToolUseID,
               "the MCP delegation's operationId must be claude's tool_use id from _meta, got \(mcpOperation)")
    let claudeChipSource = await chipSource(for: mcpChild)
    try expect(claudeChipSource == claudeToolUseID,
               "the chip for an MCP delegation must name claude's tool_use id, got \(String(describing: claudeChipSource)) — its tool row can never fold into it")
    guard let mcpSnapshot = canvas.navigationTileSnapshot(for: mcpTile) else {
        throw Failure(message: "the MCP child's tile has no navigation snapshot")
    }
    let mcpWorld = CGRect(x: mcpSnapshot.worldFrame.x, y: mcpSnapshot.worldFrame.y,
                          width: mcpSnapshot.worldFrame.width, height: mcpSnapshot.worldFrame.height)
    try expect(canvas.zoneId(containing: mcpTile) == zoneB && zoneBRect.contains(mcpWorld),
               "the MCP child's WORLD frame \(mcpWorld) must sit inside the parent's zone \(zoneBRect)")
    let mcpChildCwd = URL(fileURLWithPath: supervisor.records[mcpChild]?.cwd ?? pbRoot.path, isDirectory: true)
    func mcpChildLog() -> String {
        (try? String(contentsOf: mcpChildCwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
    }
    let mcpTaskArrived = await waitUntil(timeout: 30, pollInterval: 0.1) { mcpChildLog().contains(mcpMarker) }
    try expect(mcpTaskArrived, "the MCP child's own runner must receive the delegated task")

    // wait_agents runs in the helper, polling operation.get until the child is
    // idle with a settled turn — the app's main thread never blocks on it.
    let waited = try await toolCall(WorkspaceMCPToolCatalog.waitAgentsName, ["handles": [mcpOperation], "timeoutSeconds": 30])
    let waitedAgents = (waited.reply["result"] as? [String: Any])?["agents"] as? [[String: Any]] ?? []
    try expect(!waited.isError && waitedAgents.count == 1
               && waitedAgents[0]["status"] as? String == "completed"
               && waitedAgents[0]["childAgentId"] as? String == mcpChild.rawValue.uuidString
               && (waited.reply["result"] as? [String: Any])?["timedOut"] as? Bool == false,
               "wait_agents must collect the delegated child's settled turn: \(waited.reply)")

    // array_message_agent reaches the child it created …
    let mcpMessageMarker = "MCP-MSG-a4d2"
    let messaged = try await toolCall("array_message_agent", ["agentId": mcpChild.rawValue.uuidString,
                                                              "text": "\(mcpMessageMarker): and the appcast",
                                                              "idempotencyKey": "mcp-m1"])
    try expect(!messaged.isError && (messaged.reply["result"] as? [String: Any])?["delivery"] as? String == "delivered",
               "a message to the caller's own MCP child is delivered: \(messaged.reply)")
    let mcpDelivered = await waitUntil(timeout: 30, pollInterval: 0.1) { mcpChildLog().contains(mcpMessageMarker) }
    try expect(mcpDelivered && occurrences(mcpMessageMarker, in: mcpChildLog()) == 1,
               "the child's own runner receives the MCP message exactly once")
    // … and a sibling is a structured refusal the client sees as an ERROR.
    let promptsBeforeSibling = mcpPrompts.count
    let siblingMessage = try await toolCall("array_message_agent", ["agentId": siblingId.rawValue.uuidString,
                                                                    "text": "MCP-SIBLING: reach a peer",
                                                                    "idempotencyKey": "mcp-m-sibling"])
    try expect(siblingMessage.isError
               && (siblingMessage.reply["error"] as? [String: Any])?["code"] as? String == "permission_denied",
               "a sibling is permission_denied, flagged isError so the client reports it as a failure: \(siblingMessage)")
    try expect(mcpPrompts.count == promptsBeforeSibling, "nobody is asked about a target that was never messageable")

    // codex names its call `_meta.callId` — its `mcpToolCall` item id (measured,
    // 0.159.3). The same rule: that id is the operation and the chip's source.
    let codexCallID = "exec-0562414f-29fc-47c6-962d-90fe1e889886"
    let childrenBeforeCodex = Set(supervisor.children(of: parentId))
    let codexDelegated = try await toolCall("array_delegate", ["task": "MCP-TASK-codex: audit the appcast",
                                                               "idempotencyKey": "mcp-k2",
                                                               "presentation": ["camera": "preserve"]],
                                            meta: ["callId": codexCallID, "threadId": "01a1123a-f3f3-7652-bd37-5fb118f1ffc0"])
    let codexChildren = Set(supervisor.children(of: parentId)).subtracting(childrenBeforeCodex)
    try expect(!codexDelegated.isError && codexChildren.count == 1
               && (codexDelegated.reply["result"] as? [String: Any])?["operationId"] as? String == codexCallID,
               "a codex-shaped MCP delegation's operationId must be codex's callId: \(codexDelegated.reply)")
    let codexChipSource = await chipSource(for: codexChildren.first!)
    try expect(codexChipSource == codexCallID,
               "the chip for a codex MCP delegation must name its callId, got \(String(describing: codexChipSource))")
    client.close()

    supervisor.stopAll()
}

/// A minimal MCP stdio client for the delegation leg: one helper process, one
/// request at a time, replies matched by id. Reads on the pipe's own queue so
/// the main queue stays free for the host listener's `main.sync`.
private final class WorkspaceMCPCheckClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 1

    init(executable: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        try process.run()
    }

    private func consume(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int {
                responses[id] = object
            }
        }
    }

    @MainActor
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        input.fileHandleForWriting.write(line + Data("\n".utf8))
        let answered = await waitUntil(timeout: timeout, pollInterval: 0.05) { [self] in response(id) != nil }
        guard answered, let response = response(id) else {
            throw NSError(domain: "WorkspaceMCPCheckClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "array-workspace-mcp did not answer \(method) within \(Int(timeout))s"])
        }
        return response
    }

    private func response(_ id: Int) -> [String: Any]? {
        lock.withLock { responses[id] }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
