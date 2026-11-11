import AppKit
import ContinuumRevivedAgentUI
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
func runWorkspaceAPIDelegationChecks(crossHarness: Bool = false, inspectLaunch: ((AgentRunnerLaunch) -> Void)? = nil) async throws {
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
            if "BUSY-HOLD" in (cmd.get("message") or cmd.get("prompt") or ""):
                while not os.path.exists(os.path.join(cwd, "release-busy")):
                    time.sleep(0.01)
            prompt_text = cmd.get("message") or cmd.get("prompt") or ""
            for marker, flag in [("QCALL-A", "release-q-a"), ("QCALL-B", "release-q-b")]:
                if marker in prompt_text:
                    while not os.path.exists(os.path.join(cwd, flag)):
                        time.sleep(0.01)
            emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "ANSWER: " + prompt_text}})
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
    var fixtureRunners: [AgentID: ScriptedAgentRunner] = [:]
    // Every runner each agent was given, across turns: a one-shot runner is
    // replaced per turn, and delivery is counted over all of them.
    var fixtureRunnerHistory: [AgentID: [ScriptedAgentRunner]] = [:]
    // Delegate effort: every Claude/Codex launch's config, read off the runner
    // production builds for it, and the leads whose helpers run on a fake that
    // can also compact.
    var effortLaunches: [AgentID: [EffortLaunch]] = [:]
    var effortLeads: Set<AgentID> = []
    let effortCompactions = EffortCompactionCounter()
    let supervisor = AgentSupervisor(store: AgentStore(
        applicationSupportDirectory: URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent("workspace-api-delegation-check", isDirectory: true)), makeRunner: { launch -> AgentRunning in
            inspectLaunch?(launch)
            if !crossHarness { return AgentSupervisor.productionRunner(for: launch) }
            if launch.record.harness == .claudeCode || launch.record.harness == .codex {
                switch AgentSupervisor.productionRunner(for: launch) {
                case let claude as ClaudeAgentRunner: effortLaunches[launch.record.id, default: []].append(.claude(claude.config))
                case let codex as CodexAgentRunner: effortLaunches[launch.record.id, default: []].append(.codex(codex.config))
                default: break
                }
            }
            if let lead = launch.record.parentAgentID, effortLeads.contains(lead) {
                return EffortFixtureRunner(
                    codexThread: launch.record.harness == .codex ? "effort-thread-\(launch.record.id.rawValue.uuidString)" : nil,
                    compactions: effortCompactions)
            }
            let runner = ScriptedAgentRunner(script: [.turnStarted(threadId: "fixture", turnId: "done"),
                                                      .turnCompleted(threadId: "fixture", turnId: "done", outcome: .completed, errorMessage: nil)])
            fixtureRunners[launch.record.id] = runner
            fixtureRunnerHistory[launch.record.id, default: []].append(runner)
            return runner
        }, submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: URL(fileURLWithPath: appSupportPath)),
        transcriptStore: AgentTranscriptStore(root: appSupport.appendingPathComponent("transcripts")))
    delegate.agentSupervisor = supervisor
    // Agent permissions Off: new agents start without workspace tools and every
    // gated request asks — the world this leg was written against. The user's
    // own setting must not decide it.
    supervisor.workspaceToolsPermission = { .off }

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
    supervisor.workspaceToolsPermission = { .off }
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

    if crossHarness {
        supervisor.workspaceToolsPermission = { .free }
        // Free delegation attaches immediately; Managed delegation stays in the
        // sidebar until popped out. Exercise the same cross-harness contract in
        // both modes. Ignore ambient argument/global defaults as well as the
        // user's app preferences, and remove the private suite after the run.
        // The suite is a per-user cfprefsd domain shared by every process, so
        // its name is unique per run: a fixed name let a concurrent run of this
        // fixture flip the policy mid-assertion.
        let modeSuite = "array.qa.cross-harness-mode.\(UUID().uuidString)"
        let modePolicy = QAIsolatedDefaults(isolatedSuiteName: modeSuite)!
        modePolicy.removePersistentDomain(forName: modeSuite)
        defer { modePolicy.removePersistentDomain(forName: modeSuite) }
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        api.approvalHandler = { _ in .allowForSession }
        for managed in [false, true] {
            modePolicy.set(managed, forKey: AgentManagedModeConfig.enabledKey)
            supervisor.configureManagedMode(defaults: modePolicy)
            for (source, target) in [(AgentHarness.claudeCode, AgentHarness.codex), (.claudeCode, .pi), (.codex, .claudeCode), (.claudeCode, .claudeCode)] {
                let model = AgentModelCatalog.shared.snapshot(for: source).seedModel!
                let parent = supervisor.spawn(role: nil, prompt: nil, cwd: pbRoot, harness: source, model: model, thinking: "low", projectId: projectPb, projectRoot: pbRoot)
                try expect(supervisor.effectiveMode(for: parent) == (managed ? .managed : .free), "cross parent must use the selected app-wide policy")
                _ = supervisor.setWorkspaceToolsEnabled(agentID: parent, true)
                let spawner = try runtime.ensureSpawner(forProjectId: projectPb)
                let scope = CreationScope(projectId: projectPb, projectRoot: pbRoot.path,
                    homeRelativePath: nil, source: .zone, zoneId: zoneB)
                guard case let .spawned(leadTile) = spawner.spawnManagedAgentForExistingAgent(parent, supervisor: supervisor, creationScope: scope) else {
                    throw Failure(message: "cross lead must have a tile for helper pop-out")
                }
                supervisor.attach(agentID: parent, to: leadTile)
                delegate.wireManagedAgentTile(leadTile, agentID: parent)
                let handle = "cross-\(source.rawValue)-\(target.rawValue)".replacingOccurrences(of: " ", with: "-")
                var payload: [String: Any] = ["task": "cross harness task", "idempotencyKey": handle, "presentation": ["camera": "preserve"]]
                if target != source { payload["harness"] = target.rawValue }
                let expectedModel = source == .codex ? AgentCatalogQAFixture.claude.models.last! : (target == source ? model : AgentModelCatalog.shared.snapshot(for: target).seedModel!)
                if source == .codex { payload["model"] = expectedModel }
                let tilesBefore = agentTileCount()
                let created = try result(api.dispatch(agentId: parent, requestId: handle, op: "agent.delegate", payload: payload), "cross harness delegation")
                let replay = try result(api.dispatch(agentId: parent, requestId: handle + "-retry", op: "agent.delegate", payload: payload), "cross retry")
                try expect(replay["childAgentId"] == created["childAgentId"], "cross retry creates no duplicate")
                let childId = AgentID(rawValue: UUID(uuidString: created["childAgentId"]!.string!)!)
                var child = supervisor.records[childId]!
                try expect(child.harness == target && child.model == expectedModel, "child owns selected harness and catalogue model")
                try expect(child.mode == .free, "cross helper must remain able to edit in both lead modes")
                if managed {
                    try expect(child.tileId == nil && created["tileId"] == nil && agentTileCount() == tilesBefore,
                               "managed cross helper must start without a tile")
                    let tile = try supervisor.popOut(childId)
                    child = supervisor.records[childId]!
                    try expect(child.tileId == tile, "managed cross helper pop-out must attach its own tile")
                }
                try expect(child.parentAgentID == parent && child.workspaceToolsEnabled && child.tileId != nil, "cross child retains parent, tools and visible tile")
                try expect(agentTileCount() == tilesBefore + 1, "cross delegation/pop-out must attach exactly one tile")
                guard let frame = canvas.navigationTileSnapshot(for: child.tileId!)?.worldFrame else {
                    throw Failure(message: "cross helper has no world frame")
                }
                let world = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                let parentZoneWorld = try zoneWorldRect(zoneB)
                try expect(canvas.zoneId(containing: child.tileId!) == zoneB && parentZoneWorld.contains(world),
                           "cross helper's world frame must stay in its lead's zone")
                try expect(created["provider"]?.string == target.rawValue, "result reports actual child provider")
                delegate.wireManagedAgentTile(child.tileId!, agentID: childId)
                guard let childView = canvas.tileView(for: child.tileId!) as? ManagedAgentTileNSView,
                      let composer = childView.qaComposerForChecks else { throw Failure(message: "missing child composer") }
                await composer.qaAwaitDraftRestore()
                let reference = AgentPromptReference(agentID: parent, displayName: source.rawValue)
                try expect(childView.handleAgentReference(reference, commit: true), "cross child accepts parent reference")
                await childView.qaAwaitReferenceDrop()
                try expect(composer.draft.agentReferences.contains(where: { $0.agentID == parent }), "cross reference reaches child's draft")
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    var windows: [NSWindow] = []
                    let inbox = InboxParentFoldChecks.makeInbox([
                        AgentInboxRow(id: parent.rawValue, title: source.rawValue, state: .ready, createdAt: InboxParentFoldChecks.epoch),
                        AgentInboxRow(id: childId.rawValue, title: target.rawValue, state: .ready, depth: 1, createdAt: InboxParentFoldChecks.epoch, parentId: child.parentAgentID?.rawValue)
                    ], appearance: appearance, windows: &windows)
                    try expect(inbox.collapsedParentsForQA.contains(parent.rawValue) && !inbox.rowIdsForQA.contains(childId.rawValue), "cross child folds under actual parent in \(appearance.rawValue)")
                    windows.forEach { $0.orderOut(nil) }
                }
                let stream = supervisor.events(for: parent)
                var chipMatches: Bool?
                let chip = Task { @MainActor in
                    for await event in stream {
                        if case let .childAgentSpawned(_, id, parentID, _, sourceID, provider, _) = event, id == childId.rawValue {
                            chipMatches = parentID == parent.rawValue && sourceID == handle && provider == target.rawValue
                            return
                        }
                    }
                }
                _ = await waitUntil(timeout: 5, pollInterval: 0.02) { chipMatches != nil }
                chip.cancel()
                try expect(chipMatches == true, "parent transcript chip names child's actual provider and source")
                let settled = await waitUntil(timeout: 5, pollInterval: 0.02) { !supervisor.isRunning(childId) }
                try expect(settled && fixtureRunners[childId] != nil, "selected child runs and settles")
                // One channel: this lead is Array-run (any harness), so the
                // child's result is DELIVERED to it, exactly once, and it has no
                // second way to read it.
                func deliveredToLead() -> Int {
                    (fixtureRunnerHistory[parent] ?? []).flatMap(\.prompts).filter { text in
                        switch AgentMessageEnvelope.classify(text) {
                        case .agentMessage(let payload): return payload.senderAgentID == childId.rawValue
                        case .agentMessages(let batch): return batch.contains { $0.senderAgentID == childId.rawValue }
                        default: return false
                        }
                    }.count
                }
                let arrived = await waitUntil(timeout: 15, pollInterval: 0.05) { deliveredToLead() == 1 && !supervisor.isRunning(parent) }
                try await Task.sleep(nanoseconds: 300_000_000)
                await supervisor.flushHelperCompletions()
                try await Task.sleep(nanoseconds: 300_000_000)
                try expect(arrived && deliveredToLead() == 1, "cross child's result reaches its \(source.rawValue) lead exactly once by delivery, got \(deliveredToLead())")
                let looked = try result(api.dispatch(agentId: parent, requestId: handle + "-lookup", op: "operation.get", payload: ["operationId": handle]), "cross lookup")
                let lookedChild = looked["childResult"]?.object
                try expect(lookedChild?["status"]?.string == "already_delivered" && lookedChild?["finalText"] == nil,
                           "a lookup after delivery gives the lead a pointer, never the result again: \(looked)")
                guard let helper = AppDelegate.workspaceMCPExecutablePath(),
                      let config = delegate.workspaceMCPHost.configuration(for: parent, serverExecutable: helper,
                                                                           resultDelivery: supervisor.resultDelivery(for: parent)) else {
                    throw Failure(message: "missing MCP helper")
                }
                let client = try WorkspaceMCPCheckClient(executable: helper, environment: config.environment)
                defer { client.close() }
                let listed = try await client.request("tools/list", [:])
                let names = (((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                let waited = try await client.request("tools/call", ["name": "wait_agents", "arguments": ["handles": [handle], "timeoutSeconds": 5]])
                try expect(supervisor.resultDelivery(for: parent) == .push && names.contains("array_delegate")
                           && !names.contains("wait_agents") && waited["error"] != nil,
                           "an Array-run \(source.rawValue) lead is offered no wait_agents: \(names), \(waited)")
                _ = try result(api.dispatch(agentId: parent, requestId: handle + "-message", op: "agent.message", payload: ["agentId": childId.rawValue.uuidString, "text": "follow up", "idempotencyKey": handle + "-message"]), "cross child message")
                let delivered = await waitUntil(timeout: 5, pollInterval: 0.02) { fixtureRunners[childId]?.prompts.contains(where: { $0.contains("follow up") }) == true }
                try expect(delivered, "cross child's runner receives the message")
                _ = try failure(api.dispatch(agentId: parent, requestId: handle + "-bad", op: "agent.delegate", payload: ["task": "bad", "idempotencyKey": handle + "-bad", "model": "unknown/model"]), .unsupported, "unknown model")
                // Live 2026-11-02: a Managed lead sent bare ids ("claude-haiku-5-5")
                // three times and could not find the exact ones. The refusal must
                // name every id the selected catalogue offers, verbatim.
                let offered = AgentModelCatalog.shared.snapshot(for: source).models
                let bare = String(offered.last!.split(separator: "/").last!)
                let refusedBare = try failure(api.dispatch(agentId: parent, requestId: handle + "-bare", op: "agent.delegate", payload: ["task": "bare", "idempotencyKey": handle + "-bare", "model": bare]), .unsupported, "bare model id")
                try expect(offered.allSatisfy { refusedBare.message.contains($0) }, "model refusal must list the exact catalogue ids \(offered): \(refusedBare.message)")
            }
        }
        // MARK: Delegate effort (.plans/116 part 6)
        // Production dispatch, spawn and runner configs; only the CLI process is
        // a fake. What reaches the CLI is read off the runner production built for
        // each launch, through the runners' own argv builders (Claude `--effort`,
        // Codex exec `model_reasoning_effort`); Codex's app-server `turn/start`
        // sends the same config field as `effort`. Failures are collected so one
        // run names every broken behaviour.
        modePolicy.set(false, forKey: AgentManagedModeConfig.enabledKey)
        supervisor.configureManagedMode(defaults: modePolicy)
        var effortFailures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { effortFailures.append(message) } }
        func childId(_ reply: WorkspaceAPIService.Reply, _ what: String) -> AgentID? {
            guard case let .result(object) = reply, let raw = object["childAgentId"]?.string, let uuid = UUID(uuidString: raw) else {
                check(false, "\(what): expected a helper, got \(reply)")
                return nil
            }
            return AgentID(rawValue: uuid)
        }
        func refusal(_ reply: WorkspaceAPIService.Reply, _ what: String) -> String? {
            guard case let .error(error) = reply, error.code == .unsupported else {
                check(false, "\(what): expected an unsupported refusal, got \(reply)")
                return nil
            }
            return error.message
        }
        func settle(_ id: AgentID, launch: Int, _ what: String) async -> EffortLaunch? {
            let ok = await waitUntil(timeout: 10, pollInterval: 0.02) {
                (effortLaunches[id]?.count ?? 0) >= launch && !supervisor.isRunning(id)
            }
            check(ok, "\(what): launch \(launch) must run and settle; saw \(effortLaunches[id]?.count ?? 0)")
            return ok ? effortLaunches[id]?[launch - 1] : nil
        }
        func expectEffort(_ launch: EffortLaunch?, _ effort: String, resumed: Bool, _ what: String) {
            guard let launch else { return }
            check(launch.resumed == resumed, "\(what): expected a \(resumed ? "resumed" : "first") launch")
            check(launch.effort == effort && launch.carries(effort),
                  "\(what): \(effort) must reach the CLI; launch effort \(String(describing: launch.effort)), argv effort \(launch.effortArguments)")
        }
        var effortKey = 0
        func delegateEffort(_ lead: AgentID, _ fields: [String: Any]) -> WorkspaceAPIService.Reply {
            effortKey += 1
            var payload: [String: Any] = ["task": "effort task", "idempotencyKey": "effort-\(effortKey)", "presentation": ["camera": "preserve"]]
            payload.merge(fields) { $1 }
            return api.dispatch(agentId: lead, requestId: "effort-\(effortKey)", op: "agent.delegate", payload: payload)
        }
        func message(_ lead: AgentID, _ child: AgentID, _ text: String) {
            effortKey += 1
            let reply = api.dispatch(agentId: lead, requestId: "effort-message-\(effortKey)", op: "agent.message",
                                     payload: ["agentId": child.rawValue.uuidString, "text": text, "idempotencyKey": "effort-message-\(effortKey)"])
            if case .error = reply { check(false, "message to helper refused: \(reply)") }
        }
        func effortLead(_ harness: AgentHarness) throws -> AgentID {
            let lead = supervisor.spawn(role: nil, prompt: nil, cwd: pbRoot, harness: harness,
                                        model: AgentModelCatalog.shared.snapshot(for: harness).seedModel!, thinking: "low",
                                        projectId: projectPb, projectRoot: pbRoot)
            _ = supervisor.setWorkspaceToolsEnabled(agentID: lead, true)
            let scope = CreationScope(projectId: projectPb, projectRoot: pbRoot.path, homeRelativePath: nil, source: .zone, zoneId: zoneB)
            guard case let .spawned(tile) = try runtime.ensureSpawner(forProjectId: projectPb)
                .spawnManagedAgentForExistingAgent(lead, supervisor: supervisor, creationScope: scope) else {
                throw Failure(message: "effort lead must have a tile")
            }
            supervisor.attach(agentID: lead, to: tile)
            delegate.wireManagedAgentTile(tile, agentID: lead)
            effortLeads.insert(lead)
            return lead
        }
        let effortLeadIds: [AgentHarness: AgentID] = [.claudeCode: try effortLead(.claudeCode), .codex: try effortLead(.codex)]
        for (source, target) in [(AgentHarness.claudeCode, AgentHarness.claudeCode), (.codex, .codex), (.claudeCode, .codex), (.codex, .claudeCode)] {
            let lead = effortLeadIds[source]!
            let pair = "\(source.rawValue) → \(target.rawValue)"
            let harness: [String: Any] = source == target ? [:] : ["harness": target.rawValue]
            func with(_ extra: [String: Any]) -> [String: Any] { harness.merging(extra) { $1 } }
            let model = source == target ? supervisor.records[lead]!.model : AgentModelCatalog.shared.snapshot(for: target).seedModel!
            let accepted = AgentModelCatalog.shared.efforts(for: model, harness: target) ?? []
            check(accepted.contains("high"), "\(pair): the fixture catalogue must list high for \(model)")

            // Listed: the first turn, a resumed turn, the compaction, the turn after it.
            if let child = childId(delegateEffort(lead, with(["effort": "high"])), "\(pair) listed effort") {
                check(supervisor.records[child]?.thinking == "high", "\(pair): the helper record must hold the delegated effort")
                expectEffort(await settle(child, launch: 1, "\(pair) first turn"), "high", resumed: false, "\(pair) first turn")
                message(lead, child, "effort follow up")
                expectEffort(await settle(child, launch: 2, "\(pair) resumed turn"), "high", resumed: true, "\(pair) resumed turn")
                let compactionsBefore = effortCompactions.count
                let compacted = await supervisor.accept(.compact(AgentCompactionRequest()), for: child)
                check(compacted == .accepted, "\(pair): compaction must be accepted, got \(compacted)")
                expectEffort(await settle(child, launch: 3, "\(pair) compaction"), "high", resumed: true, "\(pair) compaction launch")
                check(effortCompactions.count == compactionsBefore + 1, "\(pair): the provider must have been asked to compact")
                message(lead, child, "after compaction")
                expectEffort(await settle(child, launch: 4, "\(pair) after compaction"), "high", resumed: true, "\(pair) turn after compaction")
            }

            // retryOf continues the same work: the retry inherits the failed
            // helper's stored effort, and an effort the call names wins.
            func failedHelper(_ effort: String, _ what: String) async -> AgentID? {
                guard let failed = childId(delegateEffort(lead, with(["effort": effort, "task": "EFFORT-FAIL"])), what) else { return nil }
                _ = await settle(failed, launch: 1, what)
                let retryable = await waitUntil(timeout: 5, pollInterval: 0.02) { supervisor.mayRetry(failed, from: lead) }
                check(retryable, "\(what): the failed helper must be retryable")
                return failed
            }
            for (override, expected) in [(String?.none, "high"), ("xhigh", "xhigh")] {
                let what = "\(pair) retryOf \(override == nil ? "inherited" : "overridden")"
                guard let failed = await failedHelper("high", what) else { continue }
                var fields: [String: Any] = ["task": "effort retry", "retryOf": failed.rawValue.uuidString]
                if let override { fields["effort"] = override }
                if let retried = childId(delegateEffort(lead, with(fields)), what) {
                    check(supervisor.records[retried]?.delegationContext?.retryOf == failed, "\(what): the retry must carry retryOf")
                    check(supervisor.records[retried]?.thinking == expected, "\(what): the retried helper must hold \(expected), got \(String(describing: supervisor.records[retried]?.thinking))")
                    expectEffort(await settle(retried, launch: 1, what), expected, resumed: false, what)
                }
            }

            // Omitted: the thinking and argv a helper got before the field existed.
            if let child = childId(delegateEffort(lead, harness), "\(pair) omitted effort") {
                let expected = source == target ? supervisor.records[lead]!.thinking : AgentModelConfig.defaultThinking
                check(supervisor.records[child]?.thinking == expected, "\(pair): omitted effort must keep \(expected), got \(String(describing: supervisor.records[child]?.thinking))")
                if let launch = await settle(child, launch: 1, "\(pair) omitted effort") {
                    let legacy = target == .codex ? CodexCLIBackend.effortArgument(forThinking: expected) : ClaudeCLIBackend.effortArgument(forThinking: expected)
                    let today = launch.argv(effort: legacy), now = launch.argv(effort: launch.effort)
                    check(launch.effort == legacy && today.count == now.count && zip(today, now).allSatisfy { $0 == $1 },
                          "\(pair): omitted effort argv must equal today's element by element; differing \(zip(today, now).filter { $0 != $1 }), lengths \(today.count)/\(now.count)")
                }
            }

            // Unlisted, and a model the catalogue gives no effort data: refused, nothing created.
            let recordsBefore = supervisor.records.count, tilesBefore = agentTileCount()
            if let message = refusal(delegateEffort(lead, with(["effort": "unlisted-effort"])), "\(pair) unlisted effort") {
                check(message.contains("unlisted-effort") && accepted.allSatisfy { message.contains($0) },
                      "\(pair): the refusal must name the value and every accepted one \(accepted): \(message)")
            }
            if let bare = AgentModelCatalog.shared.snapshot(for: target).models.first(where: { AgentModelCatalog.shared.efforts(for: $0, harness: target) == nil }) {
                if let message = refusal(delegateEffort(lead, with(["effort": "high", "model": bare])), "\(pair) no effort data") {
                    check(message.contains("no effort data") && message.contains(bare), "\(pair): a model without effort data must be refused clearly: \(message)")
                }
            } else {
                check(false, "\(pair): the fixture catalogue must hold a model without effort data")
            }
            check(supervisor.records.count == recordsBefore && agentTileCount() == tilesBefore,
                  "\(pair): refused efforts must create no helper record or tile")
        }

        // Stale: the CLI stops listing a helper's stored effort after delegation.
        for target in [AgentHarness.claudeCode, .codex] {
            let lead = effortLeadIds[target]!
            let model = supervisor.records[lead]!.model
            let fixture = target == .codex ? AgentCatalogQAFixture.codex : AgentCatalogQAFixture.claude
            guard let child = childId(delegateEffort(lead, ["effort": "xhigh"]), "\(target.rawValue) stale setup") else { continue }
            _ = await settle(child, launch: 1, "\(target.rawValue) stale setup")
            let staleFailed = childId(delegateEffort(lead, ["effort": "xhigh", "task": "EFFORT-FAIL"]), "\(target.rawValue) stale retry setup")
            if let staleFailed { _ = await settle(staleFailed, launch: 1, "\(target.rawValue) stale retry setup") }
            var levels = fixture.effortLevels
            levels[model] = levels[model]?.filter { $0 != "xhigh" }
            AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
                harness: target, readiness: .ready, models: fixture.models, displayNames: fixture.displayNames,
                contextWindows: fixture.contextWindows, effortLevels: levels, defaultModel: fixture.defaultModel))
            message(lead, child, "after the catalogue changed")
            if let launch = await settle(child, launch: 2, "\(target.rawValue) stale effort") {
                check(launch.effort == nil && !launch.argv(effort: launch.effort).contains { $0.contains("xhigh") },
                      "\(target.rawValue): a stale effort must not reach the CLI; launch effort \(String(describing: launch.effort)), argv effort \(launch.effortArguments)")
                check(supervisor.records[child]?.thinking == "xhigh", "\(target.rawValue): nothing rewrites the stored effort")
                check(supervisor.records[child]?.latestTerminalEvent?.outcome == .succeeded, "\(target.rawValue): the stale helper's turn must still run")
            }
            // A retry inherits the now-stale effort: not refused, kept on the
            // record, left off the launch.
            let retryable = await waitUntil(timeout: 5, pollInterval: 0.02) { staleFailed.map { supervisor.mayRetry($0, from: lead) } ?? false }
            check(retryable, "\(target.rawValue): the stale helper must be retryable")
            if let staleFailed, let retried = childId(delegateEffort(lead, ["task": "stale retry", "retryOf": staleFailed.rawValue.uuidString]), "\(target.rawValue) stale inherited retry") {
                check(supervisor.records[retried]?.thinking == "xhigh", "\(target.rawValue): the retry must inherit the stale effort, got \(String(describing: supervisor.records[retried]?.thinking))")
                if let launch = await settle(retried, launch: 1, "\(target.rawValue) stale inherited retry") {
                    check(launch.effort == nil && launch.effortArguments.isEmpty,
                          "\(target.rawValue): an inherited stale effort must not reach the CLI; launch effort \(String(describing: launch.effort)), argv effort \(launch.effortArguments)")
                }
            }
            AgentModelCatalog.shared.resetForQA(snapshot: fixture)
        }
        try expect(effortFailures.isEmpty, "delegate effort:\n" + effortFailures.joined(separator: "\n"))
        print("delegate effort: a listed effort reaches Claude and Codex on the first, resumed, compaction, post-compaction and retryOf launches; a retry inherits the failed helper's effort unless it names one, and a stale inherited effort is left off; omitted effort keeps today's argv; unlisted and no-data efforts are refused with nothing created; a stale effort is left off the launch")

        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .loggedOut, models: []))
        _ = try failure(dispatch("agent.delegate", ["task": "unready", "idempotencyKey": "unready", "harness": "Codex"]), .unsupported, "signed out harness")
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .missing, models: []))
        _ = try failure(dispatch("agent.delegate", ["task": "missing", "idempotencyKey": "missing", "harness": "Codex"]), .unsupported, "missing CLI")
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        supervisor.qaDeliverAccountQuota(.init(harness: .codex, windows: [.init(kind: .fiveHour, utilization: 1, resetsAt: Date().addingTimeInterval(600))], observedAt: Date(), source: .unknown("fixture")))
        _ = try failure(dispatch("agent.delegate", ["task": "exhausted", "idempotencyKey": "exhausted", "harness": "Codex"]), .unsupported, "exhausted usage")
        print("cross-harness delegation: Free and Managed Claude → Codex/Pi, Codex → Claude, immediate attachment/pop-out, inheritance, unknown model, signed out, MCP wait and message passed")
        return
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

    // MARK: B — unready harnesses and unknown models are refused

    api.approvalHandler = { prompt in prompts.append(prompt); return .allowForSession }
    AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .loggedOut, models: []))
    let wrongProvider = try failure(
        dispatch("agent.delegate", ["task": "audit the parser", "idempotencyKey": "k-prov", "provider": "Claude Code"]),
        .unsupported, "provider override")
    try expect(wrongProvider.message.contains("Claude Code"), "the refusal names the unavailable selected harness: \(wrongProvider.message)")
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

    let pendingInput = try result(dispatch("operation.get", ["pendingInputOnly": true]), "pending input query")
    try expect(pendingInput["pendingInput"]?.value is NSNull,
               "an empty caller inbox returns null without requiring an operation selector")
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
    // The lead shares this cwd, and an Array-run lead now receives its
    // child's results as messages FROM the child: those lines are the lead's
    // deliveries, not prompts the child received.
    func childPromptLog() -> String {
        let log = (try? String(contentsOf: msgChildCwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { line in
            guard let text = try? JSONDecoder().decode(String.self, from: Data(line.utf8)) else { return true }
            switch AgentMessageEnvelope.classify(text) {
            case .agentMessage(let payload): return payload.senderAgentID != childId.rawValue
            case .agentMessages(let batch): return !batch.contains { $0.senderAgentID == childId.rawValue }
            default: return true
            }
        }.joined(separator: "\n")
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

    // MARK: K — scope while asking first: children and parent, and a refusal discloses nothing

    // A peer of the caller in the SAME checkout (a sibling), an unrelated agent
    // in ANOTHER checkout and the caller's own child's child are all out of
    // scope; the caller's own parent asks first (below). `strangerId` (project Pa) is the unrelated one.
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
    // Upward is IN scope while asking first (Ask first or Off): a child may report to the agent that
    // created it, but only through the trusted prompt, which names the parent.
    // Declined here, so nothing reaches the parent's run. The child needs its
    // own policy on to be a caller at all; flipping one agent's policy leaves
    // every other agent's live grants alone (§14.1), so this belongs here,
    // where the child first acts, rather than hoisted out of the way.
    _ = supervisor.setWorkspaceToolsEnabled(agentID: childId, true)
    var upwardPrompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
    let handlerBeforeUpward = api.approvalHandler
    api.approvalHandler = { prompt in upwardPrompts.append(prompt); return .deny }
    _ = try failure(
        api.dispatch(agentId: childId, requestId: "op-msg-upward",
                     op: "agent.message",
                     payload: ["agentId": parentId.rawValue.uuidString, "text": "reach my parent", "idempotencyKey": "m-up"]),
        .permissionDenied, "a child messaging its own parent, declined")
    api.approvalHandler = handlerBeforeUpward
    try expect(upwardPrompts.count == 1 && upwardPrompts[0].op == .agentMessage && upwardPrompts[0].targetAgentId == parentId,
               "a child messaging its parent must reach the trusted prompt naming the parent while asking first, got \(upwardPrompts.map { ($0.op, $0.targetAgentId) })")
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
    try expect(notReady.message.lowercased().contains("signed out"),
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

    // Busy delivery: hold the current provider turn until the API has admitted
    // and replayed its queued message. No timing race decides whether it is busy.
    try await waitChildIdle()
    try expect(supervisor.send("BUSY-HOLD", to: childId), "start held current turn")
    _ = await childReceived("BUSY-HOLD")
    api.recordMessageChain(target: parentId, hops: WorkspaceAPIService.messageHopLimit - 1)
    let queuedPayload: [String: Any] = ["agentId": childIdString, "text": "BUSY-QUEUED-ONCE", "idempotencyKey": "busy-queue"]
    let queued = try result(dispatch("agent.message", queuedPayload, requestId: "busy-queue-op"), "busy message")
    try expect(queued["delivery"]?.string == "queued" && queued["queuePosition"]?.int == 1, "busy target queues at position 1: \(queued)")
    let replayQueued = try result(dispatch("agent.message", queuedPayload, requestId: "busy-queue-replay"), "queued replay")
    try expect(replayQueued["delivery"]?.string == "queued" && replayQueued["queuePosition"]?.int == 1, "same key replays queued admission and original position")
    try expect(occurrences("BUSY-QUEUED-ONCE", in: childPromptLog()) == 0, "queued message cannot enter current turn")
    let railReady = await waitUntil(timeout: 5, pollInterval: 0.02) { supervisor.queuedMessages(for: childId).count == 1 }
    try expect(railReady && supervisor.queuedMessages(for: childId)[0].text.contains(parentId.rawValue.uuidString.lowercased()), "composer rail retains sender envelope")
    try Data().write(to: msgChildCwd.appendingPathComponent("release-busy"))
    _ = await childReceived("BUSY-QUEUED-ONCE")
    try await waitChildIdle()
    try expect(occurrences("BUSY-QUEUED-ONCE", in: childPromptLog()) == 1, "queued message delivered once after current turn")
    try expect(childPromptLog().split(separator: "\n").contains { $0.contains("BUSY-QUEUED-ONCE") && $0.contains(parentId.rawValue.uuidString.lowercased()) }, "delivered prompt retains sender identity")
    try expect(supervisor.queuedMessages(for: childId).isEmpty, "drained rail is empty")
    try expect(api.messageChainHops(for: childId) == WorkspaceAPIService.messageHopLimit, "queue drain retains chain depth")
    api.recordMessageChain(target: parentId, hops: WorkspaceAPIService.messageHopLimit)
    _ = try failure(dispatch("agent.message", ["agentId": childIdString, "text": "BUSY-OVER-LIMIT", "idempotencyKey": "busy-limit"]), .unsupported, "hop limit after queued delivery")
    try expect(occurrences("BUSY-OVER-LIMIT", in: childPromptLog()) == 0, "hop refusal delivers nothing")
    api.messageChains.removeAll()


    // Integration witness: authenticated callers share a busy recipient, while
    // subscriptions and durable replay remain scoped to the item that starts.
    supervisor.workspaceToolsPermission = { .free }
    let caller2 = supervisor.spawn(role: nil, prompt: nil, cwd: pbRoot, harness: .pi,
        model: "fixture-model", thinking: "low", projectId: projectPb, projectRoot: pbRoot)
    _ = supervisor.setWorkspaceToolsEnabled(agentID: caller2, true)
    var deliveryClock = Date()
    supervisor.helperCompletionNow = { deliveryClock }
    // One channel per recipient: caller A stands in for an agent Array does
    // not run (it collects, with a leased offer and an acknowledgment); caller
    // B is Array-run and is pushed its answer by wake. Never both for one.
    supervisor.helperCompletionEnabled = { $0 == caller2 }
    var routingWakesA: [String] = [], routingWakesB: [String] = []
    let routingObserverA = supervisor.addPromptEchoObserver(for: parentId) { routingWakesA.append($0.text) }
    let routingObserverB = supervisor.addPromptEchoObserver(for: caller2) { routingWakesB.append($0.text) }
    try? FileManager.default.removeItem(at: msgChildCwd.appendingPathComponent("release-busy"))
    try expect(supervisor.send("BUSY-HOLD-routing", to: childId), "start routing hold")
    _ = await childReceived("BUSY-HOLD-routing")
    let payloadA: [String: Any] = ["agentId": childIdString, "text": "QCALL-A", "idempotencyKey": "route-a"]
    let payloadB: [String: Any] = ["agentId": childIdString, "text": "QCALL-B", "idempotencyKey": "route-b"]
    let admissionA = try result(dispatch("agent.message", payloadA, requestId: "route-op-a"), "queue A")
    let admissionB = try result(api.dispatch(agentId: caller2, requestId: "route-op-b", op: "agent.message", payload: payloadB), "queue B")
    try expect(admissionA["delivery"]?.string == "queued" && admissionB["delivery"]?.string == "queued", "both callers queue")
    let beforeStart = try result(dispatch("operation.get", ["operationId": "route-op-a"]), "queued result")
    try expect(beforeStart["childResult"] == nil, "old active turn cannot settle queued request")
    let persisted = try AgentMessageOutbox(applicationSupportDirectory: URL(fileURLWithPath: appSupportPath)
        .appendingPathComponent("workspace-api-delegation-check")).entries()
    try expect(persisted.contains { $0.context.caller == caller2 && $0.context.operationId == "route-op-b"
        && $0.message.agentMessageContext == $0.context && $0.phase == .queued }, "caller/operation/key/hash persist on queue admission")
    try Data().write(to: msgChildCwd.appendingPathComponent("release-busy"))
    _ = await childReceived("QCALL-A")
    let waitingB = try result(api.dispatch(agentId: caller2, requestId: "read-b-waiting", op: "operation.get",
        payload: ["operationId": "route-op-b"]), "B waiting while A runs")
    try expect(waitingB["childResult"] == nil, "B cannot settle with previous hold or A")
    try Data().write(to: msgChildCwd.appendingPathComponent("release-q-a"))
    _ = await childReceived("QCALL-B")
    let resultA = try result(dispatch("operation.get", ["operationId": "route-op-a"]), "A settled while B runs")
    let bodyA = (resultA["childResult"]?.value as? [String: Any])?["finalText"] as? String ?? ""
    try expect(bodyA.contains("QCALL-A") && !bodyA.contains("QCALL-B"), "A's handle owns A's answer: \(bodyA); result=\(resultA); projection=\(String(describing: supervisor.qaFinalAssistantText(for: childId)))")
    guard let receiptA = resultA["childResult"]?.object?["deliveryReceipt"]?.string else { throw Failure(message: "queued A has no leased offer receipt") }
    _ = try result(dispatch("operation.get", ["operationId": "route-op-a", "deliveryReceipt": receiptA, "acknowledgeDelivery": true]), "ack A custody")

    try Data().write(to: msgChildCwd.appendingPathComponent("release-q-b"))
    try await waitChildIdle()
    deliveryClock.addTimeInterval(12)
    await supervisor.flushHelperCompletions()
    let routingWakesDrained = await waitUntil(timeout: 15, pollInterval: 0.02) {
        !supervisor.isRunning(parentId) && !supervisor.isRunning(caller2)
            && !routingWakesB.isEmpty
    }
    try expect(routingWakesDrained, "queued B wake reaches its caller")
    try expect(!routingWakesA.contains { $0.contains("QCALL-A") }, "collect-channel caller A is never woken with its queued answer")
    try expect(routingWakesB.filter { $0.contains("QCALL-B") }.count == 1, "wake-first queued B reaches its caller once")
    let compactA = try result(dispatch("operation.get", ["operationId": "route-op-a"]), "queued A duplicate read")
    try expect(compactA["childResult"]?.object?["status"]?.string == "already_delivered"
        && compactA["childResult"]?.object?["finalText"] == nil, "journal path suppresses collection-first duplicate")
    let compactB = try result(api.dispatch(agentId: caller2, requestId: "read-b-done", op: "operation.get",
        payload: ["operationId": "route-op-b"]), "B wake-first read")
    try expect(compactB["childResult"]?.object?["status"]?.string == "already_delivered"
        && compactB["childResult"]?.object?["finalText"] == nil, "journal path cannot bypass wake delivery")
    guard let receiptB = compactB["childResult"]?.object?["deliveryReceipt"]?.string else { throw Failure(message: "queued B has no recovery receipt") }
    let resultB = try result(api.dispatch(agentId: caller2, requestId: "read-b-recovery", op: "operation.get",
        payload: ["operationId": "route-op-b", "deliveryReceipt": receiptB]), "B explicit receipt recovery")
    let bodyB = (resultB["childResult"]?.value as? [String: Any])?["finalText"] as? String ?? ""
    try expect(bodyB.contains("QCALL-B") && !bodyB.contains("QCALL-A"), "B's handle owns B's answer: \(bodyB)")
    _ = try failure(dispatch("operation.get", ["operationId": "route-op-b"]), .notFound, "foreign caller cannot read B")
    let routingCount = routingWakesA.count + routingWakesB.count
    deliveryClock.addTimeInterval(12)
    await supervisor.flushHelperCompletions()
    try expect(routingWakesA.count + routingWakesB.count == routingCount, "repeated flush never repeats queued results")
    supervisor.removePromptEchoObserver(routingObserverA, for: parentId)
    supervisor.removePromptEchoObserver(routingObserverB, for: caller2)
    supervisor.helperCompletionEnabled = { _ in false }
    supervisor.helperCompletionNow = Date.init
    print("Transport queued collection-first/wake-first and receipt recovery checks passed")


    try? FileManager.default.removeItem(at: msgChildCwd.appendingPathComponent("release-busy"))
    try expect(supervisor.send("BUSY-HOLD-cancel", to: childId), "start cancellation hold")
    _ = await childReceived("BUSY-HOLD-cancel")
    _ = try result(dispatch("agent.message", ["agentId": childIdString, "text": "CANCEL-BEFORE-START", "idempotencyKey": "cancel-queued"],
        requestId: "cancel-queued-op"), "queue cancellation candidate")
    guard let cancelItem = supervisor.queuedMessages(for: childId).first(where: { $0.agentMessageContext?.operationId == "cancel-queued-op" }) else {
        throw Failure(message: "missing queued cancellation item")
    }
    supervisor.cancelQueuedMessage(cancelItem.id, for: childId)
    let cancelledResult = try result(dispatch("operation.get", ["operationId": "cancel-queued-op"]), "cancelled queue result")
    try expect(cancelledResult["childResult"]?.object?["status"]?.string == "interrupted", "cancellation settles the pending operation")
    try Data().write(to: msgChildCwd.appendingPathComponent("release-busy"))
    try await waitChildIdle()
    try expect(!childPromptLog().contains("CANCEL-BEFORE-START"), "cancelled item never starts")

    try? FileManager.default.removeItem(at: msgChildCwd.appendingPathComponent("release-busy"))
    try expect(supervisor.send("BUSY-HOLD-force-cancel", to: childId), "start force-cancel hold")
    _ = await childReceived("BUSY-HOLD-force-cancel")
    _ = try result(dispatch("agent.message", ["agentId": childIdString, "text": "FORCE-CANCEL-METADATA", "idempotencyKey": "force-cancel"],
        requestId: "force-cancel-op"), "queue force-cancel candidate")
    guard let forcedItem = supervisor.queuedMessages(for: childId).first(where: { $0.agentMessageContext?.operationId == "force-cancel-op" }) else {
        throw Failure(message: "missing force-cancel item")
    }
    let forceMirrorDeadline = Date().addingTimeInterval(5)
    while !(await supervisor.hasQueuedWakeup(forcedItem.id, for: childId)) && Date() < forceMirrorDeadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let forceAccepted = await supervisor.sendQueuedItemNow(forcedItem.id, for: childId)
    try expect(forceAccepted, "queued force-send admission")
    // Stop recovery must retain admission metadata even while journal reads fail.
    let forceJournal = supervisor.agentMessageOutbox.directory
    let forceJournalSaved = forceJournal.appendingPathExtension("force-saved")
    try FileManager.default.moveItem(at: forceJournal, to: forceJournalSaved)
    try Data("blocked".utf8).write(to: forceJournal)
    supervisor.stop(childId)
    try FileManager.default.removeItem(at: forceJournal)
    try FileManager.default.moveItem(at: forceJournalSaved, to: forceJournal)
    try await waitChildIdle()
    let forceRestored = await waitUntil(timeout: 10, pollInterval: 0.02) {
        supervisor.queuedMessages(for: childId).contains { $0.id == forcedItem.id }
    }
    let forceRecovered = supervisor.queuedMessages(for: childId).first { $0.id == forcedItem.id }
    try expect(forceRestored && forceRecovered?.agentMessageContext == forcedItem.agentMessageContext
        && forceRecovered?.agentMessageHops == forcedItem.agentMessageHops,
        "Stop must preserve caller/operation/key/hops when it restores an unsent forced message")
    supervisor.cancelQueuedMessage(forcedItem.id, for: childId)
    let forceCancelled = try result(dispatch("operation.get", ["operationId": "force-cancel-op"]), "force cancellation result")
    try expect(forceCancelled["childResult"]?.object?["status"]?.string == "interrupted", "recovered force cancellation settles its own operation")
    supervisor.resumeQueue(for: childId)
    try expect(!childPromptLog().contains("FORCE-CANCEL-METADATA"), "stopped force-send never reaches the provider")
    print("Transport force/Stop preserves queued metadata through unavailable journal PASS")

    // Failure is observable before queued acknowledgement; the same key is retryable.
    try? FileManager.default.removeItem(at: msgChildCwd.appendingPathComponent("release-busy"))
    try expect(supervisor.send("BUSY-HOLD-storage", to: childId), "start storage hold")
    _ = await childReceived("BUSY-HOLD-storage")
    let journal = supervisor.agentMessageOutbox.directory
    let savedJournal = journal.appendingPathExtension("saved")
    try FileManager.default.moveItem(at: journal, to: savedJournal)
    try Data("blocked".utf8).write(to: journal)
    let retryPayload: [String: Any] = ["agentId": childIdString, "text": "AFTER-RESTART", "idempotencyKey": "restart-key"]
    let storageReply = dispatch("agent.message", retryPayload, requestId: "storage-failed")
    try FileManager.default.removeItem(at: journal)
    try FileManager.default.moveItem(at: savedJournal, to: journal)
    _ = try failure(storageReply, .durabilityFailed, "storage failure cannot acknowledge queued success")
    try expect(!supervisor.queuedMessages(for: childId).contains { $0.text.contains("AFTER-RESTART") }, "failed admission changes no rail")
    let retryAdmission = try result(dispatch("agent.message", retryPayload, requestId: "restart-op"), "retry after storage recovery")
    try expect(retryAdmission["delivery"]?.string == "queued", "same failed key can be admitted after storage recovery")
    supervisor.stop(childId)
    try await waitChildIdle()

    // Recreate supervisor AND API: no in-memory operation/replay map can help.
    let restarted = AgentSupervisor(store: AgentStore(applicationSupportDirectory: URL(fileURLWithPath: appSupportPath)
        .appendingPathComponent("workspace-api-delegation-check")),
        submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: URL(fileURLWithPath: appSupportPath)),
        transcriptStore: AgentTranscriptStore(root: appSupport.appendingPathComponent("transcripts")))
    defer { restarted.stopAll() }
    restarted.workspaceToolsPermission = { .free }
    _ = restarted.restore()
    let restartAPI = WorkspaceAPIService(runtime: { runtime }, canvas: { canvas }, focusBroker: { delegate.qaFocusBroker },
        supervisor: restarted, registryStore: { registryStore }, epoch: "restart-fixture", approvalHandler: { _ in .allowForSession })
    let restoredQueueReady = await waitUntil(timeout: 10, pollInterval: 0.02) {
        restarted.queuedMessages(for: childId).contains { $0.agentMessageContext?.operationId == "restart-op" }
    }
    try expect(restoredQueueReady && restarted.isQueuePaused(for: childId), "restart restores durable admission paused")
    let replayAfterRestart = try result(restartAPI.dispatch(agentId: parentId, requestId: "restart-replay", op: "agent.message",
        payload: retryPayload), "restart replay")
    try expect(replayAfterRestart["operationId"]?.string == "restart-op" && replayAfterRestart["queuePosition"]?.int == retryAdmission["queuePosition"]?.int, "restart reuses durable key and original position rather than adding another message")
    try expect(restarted.queuedMessages(for: childId).filter { $0.text.contains("AFTER-RESTART") }.count == 1, "one item after restart retry")
    restarted.resumeQueue(for: childId)
    let restartedDelivered = await waitUntil(timeout: 20, pollInterval: 0.02) {
        occurrences("AFTER-RESTART", in: childPromptLog()) == 1 && !restarted.isRunning(childId)
    }
    try expect(restartedDelivered, "restored queue delivers once after explicit resume")
    let restartResult = try result(restartAPI.dispatch(agentId: parentId, requestId: "restart-result", op: "operation.get",
        payload: ["operationId": "restart-op"]), "restart result association")
    // The restored item settles under its own durable operation. This lead is
    // Array-run (no stand-in on the restarted supervisor), so its lookup is a
    // pointer and the answer itself is delivered, never collected.
    let restartChild = restartResult["childResult"]?.value as? [String: Any]
    try expect((try? restarted.queuedAgentMessage(caller: parentId, operationId: "restart-op"))??.result?.status == .completed
               && ["delivery_pending", "already_delivered"].contains(restartChild?["status"] as? String ?? "")
               && restartChild?["finalText"] == nil, "restored operation settles: \(restartResult)")
    // Return the shared fake session to the original supervisor's later fixture steps.
    restarted.stopAll()
    supervisor.workspaceToolsPermission = { .off }
    print("Transport integration queue checks passed: two callers, turn association, storage failure and restart")

    // MARK: O — the same host over MCP (T3): the real `array-workspace-mcp`
    // binary, through the production listener `mountWorkspaceSceneAtBoot` wired

    // Claude and Codex reach Array only this way. Red before T3: the binary
    // listed six tools, so `array_delegate`, `array_message_agent` and a wait
    // did not exist for them at all, and refusals came back without isError.
    guard let helper = AppDelegate.workspaceMCPExecutablePath() else {
        throw Failure(message: "array-workspace-mcp is not beside the app binary — build the package, not just the Array product")
    }
    // The real capability again: this lead is Array-run, so the host and its
    // MCP server agree it is on the push channel (one channel per recipient).
    supervisor.helperCompletionEnabled = nil
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
    // An agent Array runs is on the push channel: exactly pi's catalog, and
    // no wait_agents (that is the collect channel's alone).
    try expect(listedTools.compactMap { $0["name"] as? String }
               == rawTools.compactMap { $0["name"] as? String },
               "MCP tools/list must be exactly the pi catalog, with no wait_agents: \(listedTools.compactMap { $0["name"] as? String })")
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
    // Read the zone AFTER the spawn: under auto layout a new tile docks where the
    // camera looks and the zone grows around it in any direction (`962ccd07`), so
    // the rect taken before this delegation no longer bounds the parent's zone.
    let zoneBAfterMCP = try zoneWorldRect(zoneB)
    try expect(canvas.zoneId(containing: mcpTile) == zoneB && zoneBAfterMCP.contains(mcpWorld),
               "the MCP child's WORLD frame \(mcpWorld) must sit inside the parent's zone \(zoneBAfterMCP)")
    let mcpChildCwd = URL(fileURLWithPath: supervisor.records[mcpChild]?.cwd ?? pbRoot.path, isDirectory: true)
    func mcpChildLog() -> String {
        (try? String(contentsOf: mcpChildCwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
    }
    let mcpTaskArrived = await waitUntil(timeout: 30, pollInterval: 0.1) { mcpChildLog().contains(mcpMarker) }
    try expect(mcpTaskArrived, "the MCP child's own runner must receive the delegated task")

    // One channel: this lead is Array-run, so the result is delivered to it
    // and never collected. wait_agents is not served, and a lookup gives the
    // settled status without the body.
    let waitResponse = try await client.request("tools/call", ["name": WorkspaceMCPToolCatalog.waitAgentsName,
                                                               "arguments": ["handles": [mcpOperation], "timeoutSeconds": 5]])
    try expect(waitResponse["error"] != nil && waitResponse["result"] == nil,
               "an Array-run lead's MCP server must not serve wait_agents: \(waitResponse)")
    let mcpSettled = await waitUntil(timeout: 30, pollInterval: 0.1) { !supervisor.isRunning(mcpChild) }
    try expect(mcpSettled, "the MCP child must settle its delegated turn")
    let looked = try await toolCall("array_get_operation", ["operationId": mcpOperation])
    let lookedChild = (looked.reply["result"] as? [String: Any])?["childResult"] as? [String: Any]
    try expect(!looked.isError && ["delivery_pending", "already_delivered"].contains(lookedChild?["status"] as? String ?? "")
               && lookedChild?["finalText"] == nil && lookedChild?["report"] == nil,
               "a lookup must give an Array-run lead the status and no result body: \(looked.reply)")

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

/// One launch of a delegate-effort helper: the config production built for it.
private enum EffortLaunch {
    case claude(ClaudeAgentRunner.Config)
    case codex(CodexAgentRunner.Config)

    var effort: String? {
        switch self {
        case .claude(let config): return config.effort
        case .codex(let config): return config.effort
        }
    }
    var resumed: Bool {
        switch self {
        case .claude(let config): return config.conversationMayExist
        case .codex(let config): return config.threadId != nil
        }
    }
    /// The argv the runner's own builder makes for this launch, with `effort`.
    func argv(effort: String?) -> [String] {
        switch self {
        case .claude(let c):
            return ClaudeAgentRunner.processArguments(
                model: c.model, effort: effort,
                sessionMode: c.forkSession ? .fork : (c.conversationMayExist ? .resume : .start),
                sessionId: c.sessionId, extraArgs: c.extraArgs, workspaceMCP: c.workspaceMCP, mode: c.mode)
        case .codex(let c):
            return CodexCLIBackend.processArguments(
                model: c.model, effort: effort, sessionMode: c.threadId == nil ? .fresh : .resume,
                threadId: c.threadId, cwdPath: c.cwd.path, extraArgs: c.extraArgs,
                prompt: AgentPrompt(text: "fixture"), workspaceMCP: c.workspaceMCP)
        }
    }
    /// The effort elements of this launch's argv.
    var effortArguments: [String] {
        let args = argv(effort: effort)
        return zip(args, args.dropFirst()).compactMap { $0 == "--effort" ? "--effort \($1)" : nil }
            + args.filter { $0.hasPrefix("model_reasoning_effort=") }
    }
    func carries(_ level: String) -> Bool {
        let args = argv(effort: effort)
        switch self {
        case .claude: return zip(args, args.dropFirst()).contains { $0 == "--effort" && $1 == level }
        case .codex: return args.contains("model_reasoning_effort=\(level)")
        }
    }
}

final class EffortCompactionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// A delegate-effort helper's CLI: completes each turn (fails one whose prompt
/// says EFFORT-FAIL, so it can be retried), reports a Codex thread so the next
/// turn resumes it, and completes a manual compaction.
private final class EffortFixtureRunner: AgentRunning, AgentCompactionRunning, @unchecked Sendable {
    private let codexThread: String?
    private let compactions: EffortCompactionCounter
    private let lock = NSLock()
    private var observer: (@Sendable (AgentRuntimeObservation) -> Void)?

    init(codexThread: String?, compactions: EffortCompactionCounter) {
        self.codexThread = codexThread
        self.compactions = compactions
    }

    var compactionCapabilities: AgentCompactionCapabilities {
        AgentCompactionCapabilities(supportsManual: true, supportsFocus: false)
    }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        if let codexThread { lock.withLock { observer }?(.threadId(codexThread)) }
        let turn = UUID().uuidString
        let failed = prompt.text.contains("EFFORT-FAIL")
        onEvent(.turnStarted(threadId: "fixture", turnId: turn))
        onEvent(.turnCompleted(threadId: "fixture", turnId: turn, outcome: failed ? .failed : .completed,
                               errorMessage: failed ? "fixture failure" : nil))
    }

    func compact(_ request: AgentCompactionRequest, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        compactions.add()
        for phase in [AgentCompactionPhase.running, .succeeded] {
            onEvent(.compactionChanged(threadId: "fixture", event: AgentCompactionLifecycleEvent(
                operationID: request.operationID, phase: phase, trigger: .manual, provider: "fixture")))
        }
    }

    func stop() {}
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
        lock.withLock { observer = handler }
    }
}
