import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.4 (`.plans/46`) — a tile leaving the scene must be told, so it can let go.
///
/// `CanvasNSView.setZones` unregistered focus, released surface residency and
/// removed the view — and never called `detach()`. There were exactly TWO
/// production callers of `ManagedAgentTileNSView.detach()`: the self-detach
/// inside `attach` and the deliberate tile close. So every workspace switch
/// orphaned an agent tile's event-subscription `Task`, its three supervisor
/// observer tokens and its `locationStaleTimer`, and `deinit`'s belt-and-braces
/// could not run while the supervisor still held those closures.
///
/// **The four leaks are not equal, and the assertions say which is which.**
/// `turnCapabilityObservers` is a **flat, un-keyed** dictionary whose fan-out
/// calls every entry for *every* agent's capability change; the tile filters
/// afterwards by comparing `changed == attachedAgentID`. One leaked entry from
/// one dead tile therefore keeps running on every agent in the app, forever. The
/// two per-agent dictionaries prune their inner map on removal, which makes their
/// assertion crisp: after the sweep the outer key must be gone. Only the event
/// subscription was observable before this ticket — `subscriberCount(for:)`;
/// the other three counts are new `qa` accessors added with it.
///
/// **It polls rather than asserts immediately.** `onTermination` hops through a
/// `Task { @MainActor }`, which is why `checkTileIsASubscriber` in
/// `--agent-supervisor-check` polls with `waitUntil` at nine call sites. Copying
/// that is what stops this leg from being flaky in the direction that hides the
/// defect.
@MainActor
enum ZoneTileDetachSweepChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    static func run() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1401")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1402")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000A1403")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000A1404")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1405")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1406")!
        let agentTileA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1407")!
        let noteTileB = UUID(uuidString: "00000000-0000-0000-0000-0000000A1408")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-detach-sweep-\(UUID().uuidString)", isDirectory: true)
        let paRoot = tempRoot.appendingPathComponent("Pa", isDirectory: true)
        let pbRoot = tempRoot.appendingPathComponent("Pb", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [paRoot, pbRoot, appSupport] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        func makeProject(id: UUID, name: String, root: URL) -> Project {
            Project(
                id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
        }
        let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
        let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)

        var agentTile = Tile(
            id: agentTileA, kind: .managedAgent, title: "agent",
            frame: TileFrame(x: 10, y: 10, width: 420, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata()
        )
        agentTile.zoneId = zoneA
        var noteTile = Tile(
            id: noteTileB, kind: .note, title: "note",
            frame: TileFrame(x: 10, y: 10, width: 220, height: 140),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: noteTileB)
        )
        noteTile.zoneId = zoneB

        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [agentTile], groups: [], lastActiveTileId: agentTileA))
        try storePb.saveProject(projectPbObj)
        try storePb.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [noteTile], groups: [], lastActiveTileId: noteTileB))

        func document(zone: UUID, project: UUID, color: String) -> WorkspaceDocument {
            WorkspaceDocument(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                zones: [ZonePlacement(
                    zoneId: zone, projectId: project,
                    origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 640, height: 480),
                    color: color, collapsed: false, hydrationPolicy: .automatic
                )],
                zoneZOrder: [zone],
                lastActiveZoneId: zone
            )
        }
        let docA = document(zone: zoneA, project: projectPa, color: "blue")
        let docB = document(zone: zoneB, project: projectPb, color: "red")
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceWB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWB,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa {
                return ZoneRuntimeController(projectRoot: paRoot, projectStore: storePa, project: projectPaObj)
            }
            if projectId == projectPb {
                return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storePb, project: projectPbObj)
            }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let supervisor = delegate.qaAgentSupervisor

        // A real record, bound to the tile, with NO prompt — so nothing spawns a
        // process and the tile still has a genuine agent to attach to. Hydration
        // wires a managed-agent tile only when `agent(forTile:)` already resolves
        // (M1.2b), which is exactly what this record provides.
        let agentID = supervisor.spawn(
            role: nil,
            prompt: nil,
            cwd: paRoot,
            model: "anthropic/claude-sonnet-4-5",
            thinking: "off",
            projectId: projectPa,
            projectRoot: paRoot,
            tileId: agentTileA
        )
        try expect(supervisor.agent(forTile: agentTileA) == agentID,
                   "precondition: the record must be bound to the tile")

        let runtime = WorkspaceRuntime(
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        delegate.qaPrepareForOfflineSceneCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime
        )

        // Baseline BEFORE anything attaches. `turnCapabilityObservers` is app-wide,
        // so the only meaningful claim about it is a delta, not an absolute.
        let capabilityBaseline = supervisor.qaTurnCapabilityObserverCount

        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()

        let attached = canvas.tileView(for: agentTileA)
        try expect(attached is ManagedAgentTileNSView,
                   "precondition: the agent tile must hydrate to a live view; got "
                   + "\(String(describing: attached.map { type(of: $0) }))")

        // Precondition: it really did attach. Without these the sweep assertions
        // below would pass on a tile that never subscribed to anything — the
        // vacuous-green shape this program keeps finding.
        try expect(waitUntil { supervisor.subscriberCount(for: agentID) == 1 },
                   "precondition: the attached tile must be an event subscriber; count is "
                   + "\(supervisor.subscriberCount(for: agentID))")
        try expect(supervisor.qaTurnCapabilityObserverCount == capabilityBaseline + 1,
                   "precondition: attaching must add one turn-capability observer; went from "
                   + "\(capabilityBaseline) to \(supervisor.qaTurnCapabilityObserverCount)")
        try expect(supervisor.qaRuntimeObservationObserverCount(for: agentID) == 1,
                   "precondition: attaching must add one runtime-observation observer; got "
                   + "\(supervisor.qaRuntimeObservationObserverCount(for: agentID))")
        try expect(supervisor.qaDisplayNameObserverCount(for: agentID) == 1,
                   "precondition: attaching must add one display-name observer; got "
                   + "\(supervisor.qaDisplayNameObserverCount(for: agentID))")

        // === Switch away. The view is dropped; everything it holds must go with it. ===
        try runtime.switchWorkspace(to: workspaceWB)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.tileView(for: agentTileA) == nil,
                   "the departed workspace's agent tile must not still resolve")

        try expect(waitUntil { supervisor.subscriberCount(for: agentID) == 0 },
                   "a workspace switch must cancel the agent tile's event subscription; "
                   + "\(supervisor.subscriberCount(for: agentID)) subscriber(s) remain")
        try expect(supervisor.qaTurnCapabilityObserverCount == capabilityBaseline,
                   "a workspace switch must remove the tile's turn-capability observer. This is the "
                   + "worst of the four: the dictionary is FLAT and un-keyed, so a leaked entry runs "
                   + "for every agent in the app, not just its own. Count is "
                   + "\(supervisor.qaTurnCapabilityObserverCount), baseline \(capabilityBaseline)")
        try expect(supervisor.qaRuntimeObservationObserverCount(for: agentID) == 0,
                   "a workspace switch must remove the runtime-observation observer; "
                   + "\(supervisor.qaRuntimeObservationObserverCount(for: agentID)) remain")
        try expect(supervisor.qaDisplayNameObserverCount(for: agentID) == 0,
                   "a workspace switch must remove the display-name observer; "
                   + "\(supervisor.qaDisplayNameObserverCount(for: agentID)) remain")

        // === And back. Re-attaching must restore exactly one of each, never two:
        // a sweep that detached without letting the tile re-attach would read as
        // "fixed" above and leave the agent tile deaf. ===
        try runtime.switchWorkspace(to: workspaceWA)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.tileView(for: agentTileA) is ManagedAgentTileNSView,
                   "returning must hydrate the agent tile again; got "
                   + "\(String(describing: canvas.tileView(for: agentTileA).map { type(of: $0) }))")
        try expect(waitUntil { supervisor.subscriberCount(for: agentID) == 1 },
                   "returning must re-subscribe exactly once; count is "
                   + "\(supervisor.subscriberCount(for: agentID))")
        try expect(supervisor.qaTurnCapabilityObserverCount == capabilityBaseline + 1,
                   "returning must leave exactly one turn-capability observer, not two; count is "
                   + "\(supervisor.qaTurnCapabilityObserverCount), baseline \(capabilityBaseline)")
        try expect(supervisor.qaRuntimeObservationObserverCount(for: agentID) == 1,
                   "returning must leave exactly one runtime-observation observer; got "
                   + "\(supervisor.qaRuntimeObservationObserverCount(for: agentID))")
        try expect(supervisor.qaDisplayNameObserverCount(for: agentID) == 1,
                   "returning must leave exactly one display-name observer; got "
                   + "\(supervisor.qaDisplayNameObserverCount(for: agentID))")

        print("ZoneTileDetachSweepChecks: a workspace switch released the agent tile's subscription "
              + "and all three observer tokens, and returning restored exactly one of each")
    }
}
