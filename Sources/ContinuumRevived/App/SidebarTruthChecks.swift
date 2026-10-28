import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--sidebar-truth-check` — confidence pass, sidebar stream (`.plans/70`, S4).
///
/// Dylan: "even though I delete a tile on the canvas, it doesn't delete on the
/// sidebar often." Every section here drives a PRODUCTION entry point — the scene
/// is mounted through `mountWorkspaceSceneAtBoot`, tiles are closed through the
/// canvas's own `onTileCloseRequested` (what the × button, ⌘⌫ and nav-mode delete
/// all reach), and agent turns run on a supervisor — and reads the answer off
/// the SHIPPED `AgentInboxView`: which block each agent is drawn in, never what
/// the row builder returned.
@MainActor
enum SidebarTruthChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    /// Turns that start and then wait, until the check finishes them.
    final class Runners {
        var byAgent: [AgentID: ScriptedAgentRunner] = [:]
    }

    struct World {
        let root: URL
        let appSupport: URL
        let rootA: URL
        let rootB: URL
        let workspaceA: UUID
        let workspaceB: UUID
        let projectA: UUID
        let projectB: UUID
        let app: AppDelegate
        let canvas: CanvasNSView
        let sidebar: WorkspaceSidebarView
        let window: NSWindow
        let supervisor: AgentSupervisor
        let runners: Runners
        let runtime: WorkspaceRuntime
        let browserEngine: BrowserEngineContext
        @MainActor var inbox: AgentInboxView { sidebar.inboxForQA }
        let restoreDefaults: () -> Void
    }

    // Fixed ids so a failure names the same agent every run.
    static let idleAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A1")!)
    static let busyAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A2")!)
    static let parentAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A3")!)
    static let childOne = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A4")!)
    static let childTwo = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A5")!)
    static let lostAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A6")!)
    static let secondIdleAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A7")!)
    static let settledAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A8")!)
    static let backgroundStopAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000A9")!)
    static let otherAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000B1")!)
    /// Closed to History either side of `settledAgent` in time, so one shelf
    /// holding both kinds has to interleave them by recency.
    static let archivedRecentAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000AC")!)
    static let archivedOldAgent = AgentID(rawValue: UUID(uuidString: "5D000000-0000-4000-8000-0000000000AD")!)

    static let idleTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000E1")!
    static let busyTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000E2")!
    static let parentTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000E3")!
    /// Named by `lostAgent`'s record and held by NO canvas: the tile a persistence
    /// bug, a second install or a crash before the save took away.
    static let lostTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000E6")!
    static let secondIdleTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000E7")!
    static let backgroundStopTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000E9")!
    static let otherTile = UUID(uuidString: "5D000000-0000-4000-8000-0000000000F1")!

    static func run() async throws {
        let world = try makeWorld()
        defer { tearDown(world) }
        try defaultScopeIsTheWorkspace(world)
        try historyIsOneShelf(world)
        try await switchCostsOneReload(world)
        try await closeLifecycle(world)
        try eventPushOpensNoFile(world)
        try unreadableRootIsolation(world)
        try oneRowHeaderMakesAnAgent(world)
        print("sidebar-truth: an idle agent's closed tile left the live list at once; a WORKING "
              + "agent's closed tile drew slim as Background, kept running, offered Bring back "
              + "to canvas and Stop, restored through the live reveal path, and left for History "
              + "by itself when its turn ended; a closed parent took its subagents with it; a "
              + "record naming a tile no canvas holds was never drawn live; with another "
              + "project's agent listing unreadable, a close still reached the list; an agent-"
              + "event push opened no file; the default scope was the workspace on screen, "
              + "across a switch; a switch restoring \(switchLoadTileCount) runtime-backed tiles "
              + "reloaded the sidebar once; settled and closed agents shared ONE folded History "
              + "heading, most recent first, at the bottom of the list; the header is one row whose New "
              + "agent button made an agent; hovering it offered Snooze and Settle, and "
              + "Settle settled it")
    }

    // MARK: - World

    /// `zoneOriginA` moves workspace A's zone (and its tiles with it) off the
    /// world origin, so a witness can tell a WORLD frame from a ZONE-LOCAL one.
    /// `idleAgentsFinishedATurn`: the two idle agents carry a finished, read turn,
    /// which the "All set?" nudge requires — an agent that was made and never
    /// prompted has nothing to be done with, so it is never asked about (0235a44e).
    static func makeWorld(
        zoneOriginA: ZonePoint = ZonePoint(x: 0, y: 0),
        idleAgentsFinishedATurn: Bool = false
    ) throws -> World {
        let fm = FileManager.default
        let now = Date()
        let root = fm.temporaryDirectory
            .appendingPathComponent("sidebar-truth-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let agentsSupport = root.appendingPathComponent("Agents", isDirectory: true)
        let rootA = root.appendingPathComponent("ProjectA", isDirectory: true)
        let rootB = root.appendingPathComponent("ProjectB", isDirectory: true)
        for dir in [appSupport, agentsSupport, rootA, rootB] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let workspaceA = UUID(uuidString: "5D000000-0000-4000-8000-0000000000C1")!
        let workspaceB = UUID(uuidString: "5D000000-0000-4000-8000-0000000000C2")!
        let projectA = UUID(uuidString: "5D000000-0000-4000-8000-0000000000D1")!
        let projectB = UUID(uuidString: "5D000000-0000-4000-8000-0000000000D2")!
        let zoneA = UUID(uuidString: "5D000000-0000-4000-8000-00000000C0A1")!
        let zoneB = UUID(uuidString: "5D000000-0000-4000-8000-00000000C0B1")!

        func project(_ id: UUID, _ name: String, _ url: URL) -> Project {
            Project(
                id: id, name: name, rootPath: url.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning))
        }
        let storeA = ProjectStore(projectRoot: rootA)
        let storeB = ProjectStore(projectRoot: rootB)
        let projectValueA = project(projectA, "Alpha", rootA)
        let projectValueB = project(projectB, "Beta", rootB)
        try storeA.saveProject(projectValueA)
        try storeB.saveProject(projectValueB)

        func agentTile(_ id: UUID, _ title: String, x: Double, zone: UUID) -> Tile {
            let origin = zone == zoneA ? zoneOriginA : ZonePoint(x: 0, y: 0)
            var tile = Tile(
                id: id, kind: .managedAgent, title: title,
                frame: TileFrame(x: origin.x + x, y: origin.y + 40, width: 320, height: 240),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
            tile.zoneId = zone
            return tile
        }
        try storeA.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [
                agentTile(idleTile, "idle", x: 40, zone: zoneA),
                agentTile(busyTile, "busy", x: 400, zone: zoneA),
                agentTile(parentTile, "parent", x: 760, zone: zoneA),
                agentTile(secondIdleTile, "second idle", x: 1_120, zone: zoneA),
                agentTile(backgroundStopTile, "background stop", x: 1_480, zone: zoneA),
            ],
            groups: [], lastActiveTileId: nil))
        try storeB.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [agentTile(otherTile, "other", x: 40, zone: zoneB)] + switchLoadTiles(root: rootB, zone: zoneB),
            groups: [], lastActiveTileId: nil))

        func zone(_ id: UUID, _ projectId: UUID, _ name: String) -> ZonePlacement {
            ZonePlacement(
                zoneId: id, projectId: projectId, origin: id == zoneA ? zoneOriginA : ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 1_600, height: 800), color: "blue", collapsed: false,
                hydrationPolicy: .automatic, name: name, navKey: "1")
        }
        let documentA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [zone(zoneA, projectA, "Alpha")], zoneZOrder: [zoneA], lastActiveZoneId: zoneA)
        let documentB = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [zone(zoneB, projectB, "Beta")], zoneZOrder: [zoneB], lastActiveZoneId: zoneB)
        try WorkspaceStore(workspaceId: workspaceA, applicationSupportDirectory: appSupport).save(documentA)
        try WorkspaceStore(workspaceId: workspaceB, applicationSupportDirectory: appSupport).save(documentB)

        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceA
        registry.lastActiveProjectId = projectA
        registry.workspaces = [
            WorkspaceEntry(id: workspaceA, name: "Workspace Alpha", projectIds: [projectA], createdAt: now, updatedAt: now),
            WorkspaceEntry(id: workspaceB, name: "Workspace Beta", projectIds: [projectB], createdAt: now, updatedAt: now),
        ]
        registry.projects = [
            ProjectEntry(id: projectA, name: "Alpha", rootPath: rootA.path, workspaceId: workspaceA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectB, name: "Beta", rootPath: rootB.path, workspaceId: workspaceB,
                         lastOpenedAt: now, pinned: false, missing: false),
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(registry)

        let agentStore = AgentStore(applicationSupportDirectory: agentsSupport)
        func record(_ id: AgentID, _ name: String, project: UUID, root: URL, tile: UUID?,
                    parent: AgentID? = nil, age: TimeInterval) -> AgentRecord {
            AgentRecord(
                id: id, displayName: name, role: "reviewer",
                model: "openai-codex/gpt-5.6-sol", thinking: "medium", cwd: root.path,
                projectId: project, parentAgentID: parent,
                createdAt: now.addingTimeInterval(-age), lastActivityAt: now.addingTimeInterval(-age),
                tileId: tile)
        }
        func idle(_ id: AgentID, _ name: String, tile: UUID, age: TimeInterval) -> AgentRecord {
            var value = record(id, name, project: projectA, root: rootA, tile: tile, age: age)
            if idleAgentsFinishedATurn {
                value.latestTerminalEvent = AgentTerminalEvent(
                    sequence: 1, turnID: "t1", outcome: .succeeded, endedAt: now.addingTimeInterval(-age))
                value.acknowledgedTerminalSequence = 1
            }
            return value
        }
        for value in [
            idle(idleAgent, "idle agent", tile: idleTile, age: 600),
            record(busyAgent, "busy agent", project: projectA, root: rootA, tile: busyTile, age: 500),
            record(parentAgent, "parent agent", project: projectA, root: rootA, tile: parentTile, age: 400),
            record(childOne, "child one", project: projectA, root: rootA, tile: nil, parent: parentAgent, age: 300),
            record(childTwo, "child two", project: projectA, root: rootA, tile: nil, parent: parentAgent, age: 290),
            record(lostAgent, "lost agent", project: projectA, root: rootA, tile: lostTile, age: 200),
            idle(secondIdleAgent, "second idle agent", tile: secondIdleTile, age: 150),
            record(backgroundStopAgent, "background stop agent", project: projectA, root: rootA, tile: backgroundStopTile, age: 140),
            record(otherAgent, "other agent", project: projectB, root: rootB, tile: otherTile, age: 100),
        ] {
            try agentStore.upsert(value)
        }
        // Finished work the human already said "done" to, and two agents whose
        // tiles were closed: all three are History rows.
        var settled = record(settledAgent, "settled agent", project: projectA, root: rootA, tile: nil, age: 900)
        settled.settledOverride = .settled
        settled.settledAt = now.addingTimeInterval(-120)
        try agentStore.upsert(settled)
        var archivedRecent = record(archivedRecentAgent, "recently closed agent", project: projectA, root: rootA, tile: nil, age: 950)
        archivedRecent.archivedAt = now.addingTimeInterval(-60)
        try agentStore.upsert(archivedRecent)
        var archivedOld = record(archivedOldAgent, "long closed agent", project: projectA, root: rootA, tile: nil, age: 980)
        archivedOld.archivedAt = now.addingTimeInterval(-300)
        try agentStore.upsert(archivedOld)

        let app = AppDelegate()
        // Fold choices (launch polish, item Q) persist through the app's settings
        // defaults: a private suite here, never `.standard`.
        let settingsSuite = "array.qa.sidebar-truth.\(UUID().uuidString)"
        app.qaSettingsDefaults = QAIsolatedDefaults(isolatedSuiteName: settingsSuite)
        app.registryStore = registryStore
        try app.reconciledManagedSessionSource.reconcile(registry: registry, reason: .continuumRestarted, now: now)
        let runners = Runners()
        let supervisor = AgentSupervisor(store: agentStore, makeRunner: { launch in
            let runner = ScriptedAgentRunner(
                script: [.turnStarted(threadId: "truth", turnId: "t1")],
                holdUntilStopped: true)
            runners.byAgent[launch.record.id] = runner
            return runner
        })
        app.agentSupervisor = supervisor
        supervisor.restore()

        let browserEngine = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
            if id == projectA {
                return ZoneRuntimeController(projectRoot: rootA, projectStore: storeA, project: projectValueA)
            }
            if id == projectB {
                return ZoneRuntimeController(projectRoot: rootB, projectStore: storeB, project: projectValueB)
            }
            throw Failure(message: "unexpected project \(id)")
        })
        let bootCanvasState = try storeA.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: documentA.zones.first,
            zoneRenderModels: documentA.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name)
            })
        canvas.frame = CGRect(x: 0, y: 0, width: 1_400, height: 900)
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectA),
            workspaceId: workspaceA, document: documentA, registry: zoneRegistry,
            focusBroker: app.qaFocusBroker, registryStore: registryStore,
            ghostty: nil, browserEngine: browserEngine)
        app.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        let spawner = TileSpawner(
            canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
            projectStore: storeA, project: projectValueA)
        try app.mountWorkspaceSceneAtBoot(
            canvasView: canvas, spawner: spawner, projectStore: storeA,
            canvasState: bootCanvasState, installsGlobalEventMonitors: false)
        // The × button, ⌘⌫ and nav-mode delete all reach `deleteTile` through this.
        app.wireCanvasCallbacks(canvas)
        canvas.layoutSubtreeIfNeeded()

        // The stored scope is the user's; put it back afterwards, as the inbox and
        // corpus checks do. REMOVED for the run, not set: what is under test is
        // the scope a person gets without ever touching the popup.
        let defaults = UserDefaults.standard
        let storedScope = defaults.object(forKey: WorkspaceSidebarConfig.scopeKey)
        defaults.removeObject(forKey: WorkspaceSidebarConfig.scopeKey)
        // The header's New agent spawns from the ambient Settings selection. Pin it
        // to what a fresh install resolves (Claude Code, the catalogue's own seed),
        // in-process, so a model another leg left in the shared domain cannot refuse it.
        let unpinAmbientSelection = AgentCatalogQAFixture.pinAmbientSelection(
            harness: .claudeCode,
            model: AgentModelCatalog.shared.snapshot(for: .claudeCode).seedModel ?? "")
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 1_000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = sidebar
        app.qaInstallWorkspaceSidebar(sidebar)
        app.qaRefreshAgentSurfaces()
        sidebar.inboxForQA.layoutForQA()

        return World(
            root: root, appSupport: appSupport, rootA: rootA, rootB: rootB,
            workspaceA: workspaceA, workspaceB: workspaceB, projectA: projectA, projectB: projectB,
            app: app, canvas: canvas, sidebar: sidebar, window: window,
            supervisor: supervisor, runners: runners, runtime: runtime,
            browserEngine: browserEngine,
            restoreDefaults: {
                unpinAmbientSelection()
                UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
                if let storedScope {
                    defaults.set(storedScope, forKey: WorkspaceSidebarConfig.scopeKey)
                } else {
                    defaults.removeObject(forKey: WorkspaceSidebarConfig.scopeKey)
                }
            })
    }

    /// Runtime-backed tiles for the switch-cost witness: each one restored on a
    /// switch used to trigger its own full sidebar reload.
    static let switchLoadTileCount = 6
    static func switchLoadTiles(root: URL, zone: UUID) -> [Tile] {
        (0..<switchLoadTileCount).map { index in
            var tile = Tile(
                id: UUID(), kind: .fileTree, title: "tree \(index)",
                frame: TileFrame(x: 400 + Double(index % 3) * 300, y: 300 + Double(index / 3) * 260,
                                 width: 260, height: 220),
                zPosition: .fromLegacyRank(10 + index), runtimeRef: nil,
                metadata: TileMetadata(filePath: root.path))
            tile.zoneId = zone
            return tile
        }
    }

    static func tearDown(_ world: World) {
        for runner in world.runners.byAgent.values { runner.releaseRunAfterStop() }
        world.restoreDefaults()
        world.browserEngine.shutdown()
        let unreadable = ProjectStoreLayout(projectRoot: world.rootB).managedSessionsDirectory
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
        try? FileManager.default.removeItem(at: world.root)
    }

    static func block(_ world: World, _ id: AgentID) -> String? {
        world.inbox.layoutForQA()
        return world.inbox.drawnBlockForQA(id: id.rawValue)
    }

    // MARK: - W1 · W2 · W4 · W5: closing a tile, idle and busy, parent and lost

    static func closeLifecycle(_ world: World) async throws {
        let inbox = world.inbox
        // Motion is under test below; the host's own setting must not decide it.
        inbox.prefersReducedMotion = { false }
        try expect(!DeleteConfirmPolicy.current.requiresConfirmation(for: .managedAgent),
                   "setup: this machine's delete-confirm policy would put a modal in front of deleteTile")
        try expect(world.canvas.tileView(for: idleTile) is ManagedAgentTileNSView,
                   "setup: the mounted scene must hydrate the idle agent's tile")
        for id in [idleAgent, busyAgent, parentAgent] {
            try expect(block(world, id) == "live",
                       "setup: \(id.rawValue) must be drawn live before anything is closed — got \(String(describing: block(world, id)))")
        }

        // W5 · a record naming a tile NO canvas holds. It was never closed through
        // `deleteTile` — the tile was simply lost — and it is not live work.
        try expect(block(world, lostAgent) != "live",
                   "W5: an agent bound to a tile no workspace holds is drawn as a LIVE row — the sidebar keeps a row for a tile that is gone")

        // The sidebar's tiles come from the LIVE zone layers, not from the flat
        // boot snapshot (A-history #4): the mounted tiles are placed, and a
        // closed one leaves the tree on the same reload.
        try expect(world.sidebar.treeTileIdsForQA.isSuperset(of: [idleTile, busyTile, parentTile]),
                   "setup: the sidebar tree must place the mounted tiles — got \(world.sidebar.treeTileIdsForQA.count)")

        // W1 · the control: an idle agent's tile, closed through the canvas.
        let historyBefore = inbox.historyHeaderTitleForQA
        world.canvas.onTileCloseRequested?(idleTile)
        // The row LEAVES visibly: a 150ms fade from where it was.
        try expect(inbox.qaLastRowMotion.exiting.contains(idleAgent.rawValue) && inbox.qaLiveExitGhostCount > 0,
                   "W1: the closed tile's row must fade out from its place — motion \(inbox.qaLastRowMotion), ghosts \(inbox.qaLiveExitGhostCount)")
        let ghostsGone = await waitUntil(timeout: 2, pollInterval: 0.05, { inbox.qaLiveExitGhostCount == 0 })
        try expect(ghostsGone, "W1: the exit ghost is gone once its 150ms fade ends")
        try expect(!world.sidebar.treeTileIdsForQA.contains(idleTile),
                   "a closed tile must leave the sidebar's tree — the active project's tiles came from a snapshot frozen at boot")
        try expect(block(world, idleAgent) == nil || block(world, idleAgent) == "history",
                   "W1: closing an idle agent's tile must take its row out of the live list — drawn in \(String(describing: block(world, idleAgent)))")
        try expect(inbox.historyHeaderTitleForQA != historyBefore,
                   "W1: the History heading must count the closed agent — still \(String(describing: inbox.historyHeaderTitleForQA))")

        // W2 · a WORKING agent's tile.
        try expect(world.supervisor.send("keep going", to: busyAgent),
                   "setup: the busy agent must accept a prompt")
        guard await waitUntil(timeout: 10, pollInterval: 0.02, {
            world.supervisor.isRunning(busyAgent) && world.runners.byAgent[busyAgent] != nil
        }) else { throw Failure(message: "setup: the busy agent's turn never started") }
        world.app.qaRefreshAgentSurfaces()
        try expect(block(world, busyAgent) == "live"
                   && inbox.drawnRowForQA(id: busyAgent.rawValue)?.variant == .card,
                   "setup: a working agent with a tile is a live card")

        world.canvas.onTileCloseRequested?(busyTile)
        try expect(world.canvas.tileRecord(for: busyTile) == nil, "W2: the busy agent's tile must be gone from the canvas")
        try expect(world.supervisor.isRunning(busyAgent),
                   "W2: closing the tile must NOT stop the agent's turn (P2A.5)")
        try expect(world.supervisor.records[busyAgent]?.closeRequestedAt != nil,
                   "W2: closing a busy agent's tile must record the close at once — closeRequestedAt is nil")
        let backgroundRow = inbox.drawnRowForQA(id: busyAgent.rawValue)
        try expect(block(world, busyAgent) == "live" && backgroundRow?.variant == .slim,
                   "W2: a closed tile whose agent is still working must draw SLIM (not a full card) while it runs in the background — block \(String(describing: block(world, busyAgent))), variant \(String(describing: backgroundRow?.variant))")
        try expect(backgroundRow?.presentationLabel == AgentStatusVocabulary.background,
                   "W2: the source row retains its Background label — got \(String(describing: backgroundRow?.presentationLabel))")
        try expect(backgroundRow?.hasLiveRunner == true,
                   "W2: the Background row carries the supervisor's live-runner fact even if its last status sample is stale")
        try expect(inbox.elapsedLabelsForQA.contains { $0.hasPrefix("Background · ") },
                   "W2: the drawn slim row must paint 'Background · <time>' — got \(inbox.elapsedLabelsForQA)")
        try expect(inbox.hoverRowForQA(id: busyAgent.rawValue),
                   "W2: the background row must expose its hover actions")
        let backgroundActions = inbox.hoverActionsForQA(id: busyAgent.rawValue)
        try expect(backgroundActions?.shown == true
                   && backgroundActions?.titles == ["Bring back to canvas", "Stop"],
                   "W2: the running background row offers Bring back to canvas and Stop — got \(String(describing: backgroundActions))")
        for width in [CGFloat(220), 280, 320] {
            world.window.setContentSize(NSSize(width: width, height: 1_000))
            world.window.contentView?.layoutSubtreeIfNeeded()
            inbox.layoutForQA()
            guard let geometry = inbox.rowGeometryForQA(id: busyAgent.rawValue),
                  let cell = geometry.elementFrames["cell"],
                  let title = geometry.elementFrames["title"],
                  let restore = geometry.elementFrames["bringBackAction"],
                  let stop = geometry.elementFrames["stopAction"] else {
                throw Failure(message: "W2: Background and both actions must materialize at \(width)pt")
            }
            // AppKit can include a fractional alignment outset in converted
            // button bounds even though both controls have 20pt width constraints.
            try expect(restore.width >= 20 && restore.width <= 22
                       && stop.width >= 20 && stop.width <= 22
                       && cell.contains(restore) && cell.contains(stop)
                       && title.maxX <= stop.minX && stop.maxX <= restore.minX,
                       "W2: at \(width)pt the title and two 20pt actions keep distinct hit lanes — title \(title), stop \(stop), restore \(restore), cell \(cell)")
        }
        world.window.setContentSize(NSSize(width: 300, height: 1_000))
        world.window.contentView?.layoutSubtreeIfNeeded()
        inbox.layoutForQA()
        let originalLayoutCommit = world.canvas.onLayoutCommitted
        var restoreLayoutCommitCount = 0
        var restoreLayoutCommitAccepted = 0
        var restoreLayoutCommitFailures = 0
        world.canvas.onLayoutCommitted = { transaction in
            restoreLayoutCommitCount += 1
            let accepted = originalLayoutCommit?(transaction) ?? false
            if accepted { restoreLayoutCommitAccepted += 1 }
            else { restoreLayoutCommitFailures += 1 }
            return accepted
        }
        try expect(inbox.hoverRowForQA(id: busyAgent.rawValue)
                   && inbox.clickBackgroundBringBackForQA(id: busyAgent.rawValue),
                   "W2: Bring back to canvas must use the live row action")
        world.canvas.onLayoutCommitted = originalLayoutCommit
        // Closing detached the agent from its view, so Bring back creates and
        // binds a fresh tile id; the old canvas id is not the identity contract.
        guard let restoredBusyTile = world.supervisor.records[busyAgent]?.tileId else {
            throw Failure(message: "W2: Bring back must bind the running agent to a restored tile")
        }
        try expect(restoredBusyTile != busyTile
                   && world.canvas.tileRecord(for: busyTile) == nil
                   && world.canvas.tileRecord(for: restoredBusyTile)?.kind == .managedAgent
                   && world.supervisor.agent(forTile: restoredBusyTile) == busyAgent
                   && world.supervisor.records[busyAgent]?.closeRequestedAt == nil
                   && world.supervisor.isRunning(busyAgent),
                   "W2: restoring must re-create the canvas tile, clear closeRequestedAt, and keep the turn running")
        let liveRestoredTiles = world.canvas.tilesInWorldFrames(forProjectId: world.projectA)
        let persistedRestoredTiles = try ProjectStore(projectRoot: world.rootA).loadCanvas().tiles
        let liveGeometry = Dictionary(uniqueKeysWithValues: liveRestoredTiles.map { ($0.id, $0.frame) })
        let persistedGeometry = Dictionary(uniqueKeysWithValues: persistedRestoredTiles.map { ($0.id, $0.frame) })
        // Contained placement can already be settled, so no layout transaction is
        // needed. The observable contract is that EVERY post-layout tile frame,
        // including the restored tile, matches the durable project canvas.
        try expect(restoreLayoutCommitFailures == 0 && liveGeometry[restoredBusyTile] != nil
                   && liveGeometry == persistedGeometry,
                   "W2: Bring back must persist every post-layout tile frame — attempts \(restoreLayoutCommitCount), accepted \(restoreLayoutCommitAccepted), rejected \(restoreLayoutCommitFailures), live \(liveGeometry), saved \(persistedGeometry)")
        world.canvas.onTileCloseRequested?(restoredBusyTile)
        try expect(world.canvas.tileRecord(for: restoredBusyTile) == nil
                   && world.supervisor.records[busyAgent]?.closeRequestedAt != nil
                   && world.supervisor.isRunning(busyAgent),
                   "W2: closing the restored tile starts Background again without stopping the turn")
        inbox.layoutForQA()
        try expect(inbox.hoverRowForQA(id: busyAgent.rawValue)
                   && inbox.isRowActionWiredForQA(.stopAgent),
                   "W2: Stop must remain wired on the re-backgrounded row")

        // The turn ends. NOTHING here refreshes the sidebar: the row must leave by
        // itself, pushed by the supervisor's own turn seam.
        guard let runner = world.runners.byAgent[busyAgent] else {
            throw Failure(message: "setup: no runner for the busy agent")
        }
        _ = runner.emit(.turnCompleted(threadId: "truth", turnId: "t1", outcome: .completed, errorMessage: nil))
        runner.releaseRunAfterStop()
        let left = await waitUntil(timeout: 5, pollInterval: 0.05, {
            !world.supervisor.isRunning(busyAgent)
                && world.supervisor.records[busyAgent]?.closeRequestedAt != nil
                && block(world, busyAgent) != "live"
        })
        try expect(left,
                   "W2: when the turn ended the Background row must leave the live list by itself — still drawn \(String(describing: block(world, busyAgent))), running \(world.supervisor.isRunning(busyAgent))")
        if !inbox.isHistoryExpandedForQA { _ = inbox.clickHistoryDisclosureForQA() }
        try expect(block(world, busyAgent) == "history",
                   "W2: …and be found in History — drawn \(String(describing: block(world, busyAgent)))")
        guard let historyActions = inbox.hoverActionsForQA(id: busyAgent.rawValue) else {
            throw Failure(message: "W2: the History row must materialize for its Stop-action check")
        }
        try expect(!historyActions.titles.contains("Stop"),
                   "W2: after the runner ends, its History row must not offer Stop")

        // W3 · Stop is a live action too, with no test-only supervisor shortcut.
        try expect(world.supervisor.send("stop from background", to: backgroundStopAgent),
                   "setup: the second agent must accept a turn for the Stop action")
        guard await waitUntil(timeout: 10, pollInterval: 0.02, {
            world.supervisor.isRunning(backgroundStopAgent) && world.runners.byAgent[backgroundStopAgent] != nil
        }) else { throw Failure(message: "setup: the second agent's turn never started") }
        world.app.qaRefreshAgentSurfaces()
        world.canvas.onTileCloseRequested?(backgroundStopTile)
        world.app.qaRefreshAgentSurfaces()
        try expect(inbox.hoverRowForQA(id: backgroundStopAgent.rawValue)
                   && inbox.clickBackgroundStopForQA(id: backgroundStopAgent.rawValue),
                   "W3: Stop must dispatch from the visible Background action")
        world.runners.byAgent[backgroundStopAgent]?.releaseRunAfterStop()
        let stopped = await waitUntil(timeout: 5, pollInterval: 0.05, {
            !world.supervisor.isRunning(backgroundStopAgent)
                && block(world, backgroundStopAgent) == "history"
        })
        try expect(stopped && world.supervisor.records[backgroundStopAgent]?.closeRequestedAt != nil
                   && block(world, backgroundStopAgent) != "live",
                   "W3: Stop ends the running background turn and lets the closed row leave the live list")
        try expect(block(world, backgroundStopAgent) == "history",
                   "W3: the stopped agent moves to History")
        guard let stoppedActions = inbox.hoverActionsForQA(id: backgroundStopAgent.rawValue) else {
            throw Failure(message: "W3: the History row must materialize for its Stop-action check")
        }
        try expect(!stoppedActions.titles.contains("Stop"),
                   "W3: the stopped agent's History row must not offer Stop")

        // W4 · a parent with two observed children. Closing the parent's tile
        // takes the group: no child may be left behind as a top-level row.
        // Launch polish, item Q: the shipped sidebar starts the group folded; open
        // it the way a person does, so its children are rows this leg can follow.
        try expect(inbox.collapsedParentsForQA.contains(parentAgent.rawValue)
                   && inbox.clickDisclosureForQA(id: parentAgent.rawValue),
                   "setup: the shipped sidebar must start the parent's group folded, and open it on a click")
        for child in [childOne, childTwo] {
            try expect(block(world, child) == "live",
                       "setup: a live parent's child is drawn under it — got \(String(describing: block(world, child)))")
        }
        // Under Reduce Motion the same departure does not animate at all. (Earlier
        // fades are allowed to finish first, so a count of zero is this close's.)
        _ = await waitUntil(timeout: 2, pollInterval: 0.05, { inbox.qaLiveExitGhostCount == 0 })
        inbox.prefersReducedMotion = { true }
        let motionBefore = inbox.qaLastRowMotion
        world.canvas.onTileCloseRequested?(parentTile)
        try expect(inbox.qaLiveExitGhostCount == 0
                   && inbox.qaLastRowMotion.exiting == motionBefore.exiting,
                   "Reduce Motion: a row leaves without a fade — ghosts \(inbox.qaLiveExitGhostCount)")
        inbox.prefersReducedMotion = { false }
        for child in [childOne, childTwo] {
            let drawn = block(world, child)
            try expect(drawn == "history",
                       "W4: a closed parent's subagent must travel with it into History, never stay behind as a stray row — drawn \(String(describing: drawn))")
            try expect((inbox.drawnRowForQA(id: child.rawValue)?.depth ?? 0) > 0,
                       "W4: …nested under its parent there, not promoted to a root")
        }
        try expect(block(world, parentAgent) == "history", "W4: the parent itself is in History")
        try expect(inbox.disclosureTitleForQA(id: parentAgent.rawValue)?.contains("2") == true,
                   "W4: the nested parent disclosure must show its child count — got \(inbox.disclosureTitleForQA(id: parentAgent.rawValue) ?? "<missing>")")
        guard let parentGroup = inbox.groupBackgroundForQA(id: parentAgent.rawValue) else {
            throw Failure(message: "W4: parent and child must materialize their shared group background")
        }
        let childGroups = [childOne, childTwo].compactMap {
            inbox.groupBackgroundForQA(id: $0.rawValue)
        }
        try expect(parentGroup.visible && parentGroup.roundsTop
                   && childGroups.contains(where: { $0.visible && $0.roundsBottom }),
                   "W4: the shared group surface must begin at the parent and round below its last child — parent \(parentGroup), children \(childGroups)")
    }

    // MARK: - W6: one unreadable root must not freeze the list

    static func unreadableRootIsolation(_ world: World) throws {
        // Project B's managed-session listing becomes unreadable: a TCC-denied
        // folder, a lock held by the other install, a permissions slip.
        let dir = ProjectStoreLayout(projectRoot: world.rootB).managedSessionsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ManagedAgentSessionStore(projectRoot: world.rootB).upsert(ManagedAgentSessionRecord(
            tileId: UUID(), agentKind: .claude, status: .stopped, lastSeenAt: Date()))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == nil,
                   "setup: project B's managed-session directory must actually be unreadable")
        try expect(block(world, secondIdleAgent) == "live",
                   "setup: the second idle agent is drawn live before its tile closes")

        // Close an idle agent's tile in project A. Project B has nothing to do
        // with it, and the row must still move.
        world.canvas.onTileCloseRequested?(secondIdleTile)
        try expect(world.supervisor.records[secondIdleAgent]?.archivedAt != nil,
                   "setup: the idle close must have parked the agent")
        try expect(block(world, secondIdleAgent) != "live",
                   "W6: with ANOTHER project's agent listing unreadable, closing a tile left its row live — one bad root froze the whole list")
        try expect(block(world, otherAgent) == "live" || world.inbox.drawnBlockForQA(id: otherAgent.rawValue) == nil,
                   "W6: the unreadable project's own agent keeps its last good row")
    }

    // MARK: - W11: an agent event's push opens no file

    static func eventPushOpensNoFile(_ world: World) throws {
        // Positive control first: a STRUCTURAL refresh does read the disk, so a
        // zero below is the push's cost and not a probe that counts nothing.
        let structuralBefore = StoreReadProbe.shared.count
        world.app.qaRefreshAgentSurfaces()
        try expect(StoreReadProbe.shared.count > structuralBefore,
                   "control: a structural refresh must read the registry and canvases — the probe counted nothing")
        let before = StoreReadProbe.shared.count
        world.app.qaPushAgentSurfacesForEvent()
        let reads = StoreReadProbe.shared.count - before
        try expect(reads == 0,
                   "W11: one agent-event push opened \(reads) registry/workspace/canvas/session file(s) on the main thread — it must derive from memory")
        try expect(block(world, otherAgent) != nil || world.inbox.rowIdsForQA.contains(otherAgent.rawValue) == false,
                   "control: the push still drew the list")
    }

    // MARK: - W7: the default scope is the workspace on screen

    static func defaultScopeIsTheWorkspace(_ world: World) throws {
        let inbox = world.inbox
        try expect(block(world, busyAgent) == "live",
                   "setup: this workspace's agent is drawn")
        try expect(block(world, otherAgent) == nil,
                   "W7: out of the box the list must show THIS workspace's agents — the other workspace's agent is drawn (\(String(describing: block(world, otherAgent)))), whose tile is not on this canvas")
        // "All" is one click away and shows both.
        try expect(inbox.pickScopeForQA(.all), "All agents must be pickable")
        try expect(block(world, otherAgent) == "live" && block(world, busyAgent) == "live",
                   "W7: 'All agents' shows every workspace's agents")
        try expect(inbox.pickScopeForQA(.currentWorkspace), "This workspace must be pickable")
        // Switch workspaces through the production reveal path: the scope follows.
        try expect(world.app.revealAgentFromInbox(otherAgent.rawValue),
                   "setup: revealing the other workspace's agent must switch to it")
        try expect(world.runtime.workspaceId == world.workspaceB, "setup: now in workspace Beta")
        // A-history #4: the active project's tiles came from the flat BOOT model,
        // which after a switch still holds the departed project's tiles — so the
        // arriving workspace listed Alpha's tiles as its own.
        let betaTiles = world.sidebar.treeTileIdsForQA(workspaceId: world.workspaceB)
        try expect(betaTiles.contains(otherTile) && betaTiles.isDisjoint(with: [idleTile, busyTile, parentTile]),
                   "after switching to Beta its tree must list Beta's tiles only — it lists \(betaTiles.count) tile(s), Alpha's among them: \(!betaTiles.isDisjoint(with: [idleTile, busyTile, parentTile]))")
        try expect(block(world, otherAgent) == "live" && block(world, busyAgent) == nil,
                   "W7: after a switch the list shows the NEW workspace's agents only — other \(String(describing: block(world, otherAgent))), busy \(String(describing: block(world, busyAgent)))")
        // …and back, for the sections below.
        try expect(inbox.pickScopeForQA(.all), "All agents must be pickable")
        try expect(world.app.revealAgentFromInbox(busyAgent.rawValue),
                   "setup: revealing this workspace's agent must switch back")
        try expect(world.runtime.workspaceId == world.workspaceA, "setup: back in workspace Alpha")
        try expect(inbox.pickScopeForQA(.currentWorkspace), "This workspace must be pickable")
        try expect(block(world, busyAgent) == "live" && block(world, otherAgent) == nil,
                   "W7: back home, the home workspace's agents again")
    }

    // MARK: - Switch cost: one sidebar reload, however many tiles restore

    static func switchCostsOneReload(_ world: World) async throws {
        // What ONE structural reload reads, as the yardstick.
        let yardstickBefore = StoreReadProbe.shared.count
        world.app.qaRefreshAgentSurfaces()
        let oneReload = StoreReadProbe.shared.count - yardstickBefore

        func switchViaSidebar(to workspace: UUID) async -> (reloads: Int, reads: Int) {
            let reloadsBefore = world.app.qaStructuralSidebarReloadCount
            let readsBefore = StoreReadProbe.shared.count
            // The sidebar's own workspace row: the production switch entry.
            world.sidebar.onSelection?(.workspace(workspace))
            // Coalesced reloads land on the NEXT run-loop turn; count them too.
            _ = await waitUntil(timeout: 0.3, pollInterval: 0.05, { false })
            return (world.app.qaStructuralSidebarReloadCount - reloadsBefore,
                    StoreReadProbe.shared.count - readsBefore)
        }
        let there = await switchViaSidebar(to: world.workspaceB)
        try expect(world.runtime.workspaceId == world.workspaceB, "setup: the sidebar switched to Beta")
        try expect(there.reloads == 1,
                   "switch: restoring \(switchLoadTileCount) runtime-backed tiles ran \(there.reloads) structural sidebar reloads — one per restored tile; it must be one")
        // The switch reads its own target (document, registry, canvases) once; the
        // sidebar may add ONE reload's worth on top. Per-tile reloads put this at
        // N+1 reloads' worth (79 reads for 6 tiles on this fixture before).
        try expect(there.reads <= oneReload * 3,
                   "switch: \(there.reads) registry/workspace/canvas/session reads for one switch, against \(oneReload) for one structural reload — the sidebar's share must not grow with the tiles it restores")
        let back = await switchViaSidebar(to: world.workspaceA)
        try expect(world.runtime.workspaceId == world.workspaceA, "setup: the sidebar switched back to Alpha")
        try expect(back.reloads == 1, "switch back: \(back.reloads) structural sidebar reloads, wanted 1")
        print("sidebar-truth: switch cost reloads=\(there.reloads)/\(back.reloads) reads=\(there.reads)/\(back.reads) (one structural reload reads \(oneReload))")
    }

    // MARK: - Shelves: ONE History shelf, folded, at the bottom

    /// Dylan: "one history shelf". Settled agents and agents closed to History
    /// are one section: one heading, one count, one fold, most recent first.
    static func historyIsOneShelf(_ world: World) throws {
        let inbox = world.inbox
        guard let settings = world.app.qaSettingsDefaults else {
            throw Failure(message: "setup: the app must persist through its private settings suite")
        }
        try expect(world.supervisor.records[settledAgent]?.settledOverride == .settled
                   && world.supervisor.records[settledAgent]?.archivedAt == nil,
                   "setup: the settled agent was adopted settled, not archived")
        try expect(world.supervisor.records[archivedRecentAgent]?.archivedAt != nil
                   && world.supervisor.records[archivedOldAgent]?.archivedAt != nil,
                   "setup: the two closed agents were adopted archived")
        let history = [archivedRecentAgent, settledAgent, archivedOldAgent]
        inbox.layoutForQA()
        let headings = inbox.shelfHeadingTitlesForQA
        try expect(headings.count == 1 && headings[0].hasPrefix("History ("),
                   "exactly ONE heading, History, for settled and closed agents together — got \(headings)")
        for agent in history {
            try expect(block(world, agent) == nil,
                       "History opens COLLAPSED: \(agent.rawValue) must not be drawn until asked for — drawn \(String(describing: block(world, agent)))")
        }
        // The live list owns the top; the heading meets the bottom of the viewport.
        let viewport = inbox.tableViewportHeightForQA
        guard let heading = inbox.tableRowFrameOfShelfHeadingForQA(),
              let bottom = inbox.lastTableRowMaxYForQA else {
            throw Failure(message: "the list draws a shelf heading")
        }
        try expect(heading.minY > viewport / 2 && abs(bottom - viewport) <= 2,
                   "the History heading must sit at the BOTTOM of the sidebar — heading at y \(heading.minY), last row ends at \(bottom), viewport \(viewport)")
        try expect(inbox.clickHistoryDisclosureForQA(), "the History heading's triangle must be wired")
        inbox.layoutForQA()
        for agent in history {
            try expect(block(world, agent) == "history",
                       "opening History draws \(agent.rawValue) inside it — drawn \(String(describing: block(world, agent)))")
            try expect(inbox.drawnRowForQA(id: agent.rawValue)?.variant == .slim,
                       "every History row is drawn the same slim way — \(agent.rawValue) is \(String(describing: inbox.drawnRowForQA(id: agent.rawValue)?.variant))")
        }
        let inHistory = inbox.rowIdsForQA.filter { inbox.drawnBlockForQA(id: $0) == "history" }
        try expect(headings[0] == "History (\(inHistory.count))",
                   "the heading counts exactly the rows it opens onto — '\(headings[0])' over \(inHistory.count) rows")
        let drawnOrder = inbox.rowIdsForQA.filter { id in history.contains { $0.rawValue == id } }
        try expect(drawnOrder == history.map(\.rawValue),
                   "History is most recent first across both kinds (closed 1m, settled 2m, closed 5m ago) — got \(drawnOrder)")
        // Remembered across a relaunch: a freshly configured sidebar opens it.
        try expect(WorkspaceSidebarConfig.isShelfExpanded(.history, defaults: settings),
                   "opening History must be persisted in the app's settings")
        let relaunched = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
        world.app.qaInstallWorkspaceSidebar(relaunched)
        try expect(relaunched.inboxForQA.isHistoryExpandedForQA,
                   "a relaunched sidebar opens History as it was left")
        world.app.qaInstallWorkspaceSidebar(world.sidebar)
        world.app.qaRefreshAgentSurfaces()
        try expect(inbox.clickHistoryDisclosureForQA(), "and closes again")
        try expect(!WorkspaceSidebarConfig.isShelfExpanded(.history, defaults: settings), "…which is persisted too")
    }

    // MARK: - Header: one row — search, scope, New agent (T3 nightly)

    static func oneRowHeaderMakesAnAgent(_ world: World) throws {
        let inbox = world.inbox
        inbox.layoutForQA()
        let header = inbox.headerFramesForQA
        guard let newAgent = header.newAgent else {
            throw Failure(message: "the header must carry a New agent button")
        }
        try expect(abs(header.search.midY - header.scope.midY) <= 2
                   && abs(header.search.midY - newAgent.midY) <= 2,
                   "search, scope and New agent share ONE row — mid-Ys \(header.search.midY), \(header.scope.midY), \(newAgent.midY)")
        try expect(header.search.minX < header.scope.minX && header.scope.maxX <= newAgent.minX,
                   "in T3's order: search, then scope, then New agent")
        try expect(newAgent.width == AgentInboxView.headerIconButtonSide
                   && newAgent.height == AgentInboxView.headerIconButtonSide,
                   "New agent is a \(AgentInboxView.headerIconButtonSide)pt square — got \(newAgent.size)")
        try expect(header.listTop <= header.search.minY,
                   "the list starts under the header row")
        let before = Set(world.supervisor.records.keys)
        try expect(inbox.clickNewAgentForQA(), "the New agent button must be clickable")
        let made = Set(world.supervisor.records.keys).subtracting(before)
        try expect(made.count == 1,
                   "New agent makes exactly one agent — made \(made.count)")
        guard let id = made.first else { return }
        world.app.qaRefreshAgentSurfaces()
        try expect(block(world, id) == "live",
                   "…and it is drawn live at once — drawn \(String(describing: block(world, id)))")
        try hoverActionsSettle(world, id)
    }

    // MARK: - Hover: the status slot becomes [Settle], beside the × that snoozes

    static func hoverActionsSettle(_ world: World, _ agent: AgentID) throws {
        let inbox = world.inbox
        inbox.layoutForQA()
        try expect(inbox.hoverActionsForQA(id: agent.rawValue)?.shown == false,
                   "control: a row nobody is pointing at shows its status, not its actions")
        try expect(inbox.hoverRowForQA(id: agent.rawValue), "the new agent's row must be hoverable")
        let hovered = inbox.hoverActionsForQA(id: agent.rawValue)
        // .plans/87: the × snoozes an Array agent (three hours, or until it needs
        // you), so it takes the Snooze pill's place (--sidebar-hide-any-row-check).
        try expect(hovered?.shown == true && hovered?.titles == ["Settle", "Hide"],
                   "hovering an idle card cross-fades its status slot to [Settle] and shows the × — got \(String(describing: hovered))")
        try expect(inbox.clickHoverSettleForQA(id: agent.rawValue), "the hover Settle must be clickable")
        try expect(world.supervisor.records[agent]?.settledOverride == .settled,
                   "the hover Settle settles the agent — got \(String(describing: world.supervisor.records[agent]?.settledOverride))")
        try expect(block(world, agent) != "live",
                   "…and its row leaves the live list — drawn \(String(describing: block(world, agent)))")
        _ = inbox.hoverRowForQA(id: nil)
    }
}

extension WorkspaceSidebarConfig {
    /// For a check that configures the app's sidebar: start from collapsed
    /// shelves (the default), and hand back what restores the person's own.
    static func qaIsolateShelves(defaults: UserDefaults = .standard) -> () -> Void {
        let stored = Shelf.allCases.map { ($0, defaults.object(forKey: shelfKey($0))) }
        for shelf in Shelf.allCases { defaults.removeObject(forKey: shelfKey(shelf)) }
        return {
            for (shelf, value) in stored {
                if let value { defaults.set(value, forKey: shelfKey(shelf)) }
                else { defaults.removeObject(forKey: shelfKey(shelf)) }
            }
        }
    }
}
