import AppKit
import ContinuumRevivedCore
import Foundation

/// A workspace switch is instant, certain and cheap to undo (`.plans/70` S5).
///
/// Every scenario mounts through `mountWorkspaceSceneAtBoot` with launch's own
/// project-controller factory and switches through a route a person uses (the
/// sidebar row or the titlebar popup). Costs are COUNTED across each switch —
/// tile views built, spawners built, synchronous tmux round trips on the main
/// thread, full tile layout passes, sidebar reloads, store reads — never timed;
/// the phase timings go to the manifest for reading, not gating.
///
///  - warm round trip: A (terminal, browser, note, file, unbound agent) → B
///    (terminal) → A → B. Going back re-attaches: no tile view built, the same
///    terminal runtimes and web view, no sync tmux, one sidebar reload, the
///    camera where it was left, the terminal's descriptor untouched on disk,
///    and nothing re-plans hydration after the switch returns;
///  - a released workspace keeps its terminal descriptors (no `lastExit` stamp,
///    nothing pruned on return, the restored shell opens in its own cwd);
///  - a switch started inside a switch is refused;
///  - a project held by another install fails the switch with its name, never
///    a modal, and leaves no acquisition or lock behind;
///  - a registry commit that fails leaves no acquisition or lock behind;
///  - a file editor that never answers its barrier costs a bounded wait and
///    keeps its draft, and the switch still happens;
///  - the titlebar names the target and shows progress before the work starts,
///    and a failed switch puts it back and says why.
///
/// Terminals run in an off-display window. tmux is ON for the spawners and
/// answered by an in-memory control and a stand-in client script; the real
/// tmux server is never addressed by the spawners. The volatile argument domain
/// is restored afterwards, so no defaults domain is written.
@MainActor
enum WorkspaceSwitchConfidenceChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static let terminalA1 = UUID(uuidString: "00000000-0000-0000-0000-00000C0A1701")!
    static let browserA2 = UUID(uuidString: "00000000-0000-0000-0000-00000C0A2B01")!
    static let agentA2 = UUID(uuidString: "00000000-0000-0000-0000-00000C0A2A61")!
    static let terminalB1 = UUID(uuidString: "00000000-0000-0000-0000-00000C0B1701")!

    /// One scenario's findings: every failed expectation is kept, so a RED run
    /// shows all of them, not only the first.
    final class Findings {
        var failures: [String] = []
        var facts: [String: Any] = [:]
        func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
            if !condition() { failures.append(message()) }
        }
    }

    // MARK: - Scene

    private static func seedRuntimeTiles(_ fixture: Fixture) throws {
        func add(_ projectId: UUID, _ tiles: [Tile]) throws {
            let store = ProjectStore(projectRoot: fixture.projectRoots[projectId]!)
            guard var canvas = try store.tryLoadCanvas() else { throw Failure(message: "seed: project \(projectId) has no canvas") }
            canvas.tiles.append(contentsOf: tiles)
            try store.saveCanvas(canvas)
        }
        func tile(_ id: UUID, _ kind: TileKind, _ frame: TileFrame, rank: Int, zone: UUID,
                  _ configure: (inout TileMetadata) -> Void = { _ in }) -> Tile {
            var metadata = TileMetadata()
            configure(&metadata)
            var tile = Tile(id: id, kind: kind, title: kind.rawValue, frame: frame, zPosition: .fromLegacyRank(rank),
                            runtimeRef: nil, metadata: metadata)
            tile.zoneId = zone
            return tile
        }
        try add(Fixture.projectA1, [
            tile(terminalA1, .terminal, TileFrame(x: 640, y: 660, width: 260, height: 200), rank: 20, zone: Fixture.zoneA1) {
                $0.launchProfileId = "shell"
            }
        ])
        try add(Fixture.projectA2, [
            tile(browserA2, .browser, TileFrame(x: 2060, y: 340, width: 400, height: 260), rank: 20, zone: Fixture.zoneA2) {
                $0.url = "about:blank"
            },
            tile(agentA2, .managedAgent, TileFrame(x: 1760, y: 640, width: 400, height: 260), rank: 21, zone: Fixture.zoneA2)
        ])
        try add(Fixture.projectB1, [
            tile(terminalB1, .terminal, TileFrame(x: 750, y: 380, width: 260, height: 200), rank: 20, zone: Fixture.zoneB1) {
                $0.launchProfileId = "shell"
            }
        ])
    }

    /// The fixture's seed plus the runtime-backed tiles this leg adds.
    static let expectedScene: Fixture.SeedScene = {
        var scene = Fixture.seed
        let added: [(UUID, TileFrame, UUID, UUID)] = [
            (terminalA1, TileFrame(x: 640, y: 660, width: 260, height: 200), Fixture.projectA1, Fixture.zoneA1),
            (browserA2, TileFrame(x: 2060, y: 340, width: 400, height: 260), Fixture.projectA2, Fixture.zoneA2),
            (agentA2, TileFrame(x: 1760, y: 640, width: 400, height: 260), Fixture.projectA2, Fixture.zoneA2),
            (terminalB1, TileFrame(x: 750, y: 380, width: 260, height: 200), Fixture.projectB1, Fixture.zoneB1)
        ]
        for (tileId, frame, projectId, zoneId) in added {
            scene.tiles[tileId] = frame
            scene.tileProject[tileId] = projectId
            scene.tileZone[tileId] = zoneId
        }
        return scene
    }()

    /// A tmux client stand-in for the terminal surfaces: it ignores its
    /// arguments and holds the pty open until the surface goes away.
    private static func writeClientStandIn(_ fixture: Fixture) throws -> String {
        let url = fixture.root.appendingPathComponent("tmux-client-stand-in", isDirectory: false)
        try "#!/bin/sh\nexec /bin/cat >/dev/null\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Serialises the in-memory control: restores may run off the main thread.
    actor SerialTmuxControl: TmuxControl {
        let inner = InMemoryTmuxControl()
        func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String {
            try await inner.newSession(name: name, cwd: cwd, innerCommand: innerCommand)
        }
        func newWindow(inSession: String, cwd: String, innerCommand: [String]?) async throws -> String {
            try await inner.newWindow(inSession: inSession, cwd: cwd, innerCommand: innerCommand)
        }
        func killWindow(target: String) async throws { try await inner.killWindow(target: target) }
        func killSession(name: String) async throws { try await inner.killSession(name: name) }
        func detachSession(name: String) async throws { try await inner.detachSession(name: name) }
        func sessionExists(name: String) async throws -> Bool { try await inner.sessionExists(name: name) }
        func isAlive(paneTarget: String) async throws -> Bool { try await inner.isAlive(paneTarget: paneTarget) }
        func paneCurrentPath(paneTarget: String) async throws -> String { try await inner.paneCurrentPath(paneTarget: paneTarget) }
        func paneCurrentCommand(paneTarget: String) async throws -> String { try await inner.paneCurrentCommand(paneTarget: paneTarget) }
        func listSessions() async throws -> [TmuxSessionInfo] { try await inner.listSessions() }
    }

    /// Host the canvas in a real, off-display window: Ghostty starts a
    /// terminal's surface only once its view is in one.
    private static func attachWindow(_ fixture: Fixture) throws -> NSWindow {
        let m = try fixture.requireMounted("window")
        let window = NSWindow(contentRect: m.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = m.canvas
        window.orderFrontOffscreenForChecks()
        m.canvas.layoutSubtreeIfNeeded()
        return window
    }

    private static func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func descriptor(_ fixture: Fixture, _ projectId: UUID, tile tileId: UUID) -> TerminalSessionDescriptor? {
        (try? ProjectStore(projectRoot: fixture.projectRoots[projectId]!).listSessions())?.first { $0.tileId == tileId }
    }

    /// Switch through the sidebar route and count what it cost, then let the
    /// run loop run and count anything the switch left for later.
    private static func measuredSwitch(
        _ fixture: Fixture, to workspaceId: UUID, label: String, into findings: Findings
    ) throws -> WorkspaceSwitchCounters.Snapshot {
        let m = try fixture.requireMounted(label)
        let before = WorkspaceSwitchCounters.snapshot()
        let started = Date()
        let switched = m.delegate.qaSwitchWorkspaceFromSidebar(workspaceId)
        let elapsed = Date().timeIntervalSince(started)
        m.canvas.layoutSubtreeIfNeeded()
        let cost = WorkspaceSwitchCounters.snapshot() - before
        // Anything after this is work the switch left behind: a second hitch.
        let reconcilesBefore = m.runtime.reconcileCount
        let settled = WorkspaceSwitchCounters.snapshot()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let after = WorkspaceSwitchCounters.snapshot() - settled
        findings.expect(switched && m.runtime.workspaceId == workspaceId, "\(label): the switch did not land on \(workspaceId)")
        findings.expect(m.runtime.reconcileCount == reconcilesBefore,
                        "\(label): hydration was re-planned \(m.runtime.reconcileCount - reconcilesBefore) time(s) after the switch returned — a second hitch")
        findings.expect(after.spawnersBuilt == 0,
                        "\(label): \(after.spawnersBuilt) spawner(s) were rebuilt after the switch returned — a second hitch")
        findings.facts[label] = [
            "cost": cost.dictionary, "afterSwitch": after.dictionary,
            "wallClockMs": (elapsed * 1000).rounded(),
            "report": m.runtime.lastSwitchReport?.dictionary ?? NSNull()
        ] as [String: Any]
        return cost
    }

    // MARK: - Run

    static func run() throws -> URL {
        let ghostty = try GhosttyRuntimeContext()
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

        var manifest: [String: Any] = [:]
        var failures: [String] = []
        let scenarios: [(String, (Fixture, Findings) throws -> Void)] = [
            ("warm-round-trip", warmRoundTrip),
            ("warm-browser-global-budget", warmBrowserBudget),
            ("warm-runtime-exits", warmRuntimeExits),
            ("released-workspace-keeps-terminal-descriptors", releasedWorkspaceKeepsDescriptors),
            ("switch-inside-a-switch-is-refused", switchInsideSwitchIsRefused),
            ("held-project-lock-fails-cleanly", heldProjectLockFailsCleanly),
            ("failed-commit-releases-acquisitions", failedCommitReleasesAcquisitions),
            ("unanswered-editor-is-bounded", unansweredEditorIsBounded),
            ("titlebar-feedback", titlebarFeedback)
        ]
        for (label, body) in scenarios {
            // tmux is ON (as it is by default) for the spawners only, which the
            // leg points at its own control; the matrix's argument-domain NO
            // would otherwise hide every tmux round trip a switch makes.
            var isolated = arguments
            isolated[TmuxPersistenceConfig.enabledKey] = true
            isolated[DeleteConfirmPolicy.userDefaultsKey] = DeleteConfirmPolicy.never.rawValue
            UserDefaults.standard.setVolatileDomain(isolated, forName: UserDefaults.argumentDomain)

            fputs("workspace-switch-confidence: \(label)\n", stderr)
            let findings = Findings()
            let fixture = try Fixture(label: "switch-confidence-\(label)")
            fixture.ghostty = ghostty
            do {
                try seedRuntimeTiles(fixture)
                let clientPath = try writeClientStandIn(fixture)
                let control = SerialTmuxControl()
                var lockAlerts = 0
                fixture.configureMount = { delegate, runtime in
                    runtime.spawnerTmuxPathResolver = { _ in clientPath }
                    runtime.spawnerTmuxControlFactory = { _ in control }
                    delegate.qaProjectLockAlertResponder = { _ in lockAlerts += 1; return .openAnyway }
                }
                try body(fixture, findings)
                findings.facts["lockAlertsPresented"] = lockAlerts
                if label != "held-project-lock-fails-cleanly" {
                    findings.expect(lockAlerts == 0, "a project-lock modal was presented \(lockAlerts) time(s)")
                }
            } catch {
                findings.failures.append("aborted: \(error)")
            }
            var entry = findings.facts
            entry["failures"] = findings.failures
            entry["actions"] = fixture.actionLog
            manifest[label] = entry
            failures += findings.failures.map { "\(label): \($0)" }
            fixture.dispose()
        }
        let dir = URL(fileURLWithPath: "qa-runs/\(Int(Date().timeIntervalSince1970))/workspace-switch-confidence", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) expectation(s) failed (\(artifact.path)):\n  "
                          + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    // MARK: - Scenarios

    private static func warmRuntimeExits(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("parked exit mount")
        let a1 = try requireController(fixture, Fixture.projectA1, "parked terminal owner")
        let a2 = try requireController(fixture, Fixture.projectA2, "parked browser owner")
        guard let terminal = a1.runtimes.first(where: { $0.tileId == terminalA1 }),
              let browser = a2.browserRuntimes.first(where: { $0.tileId == browserA2 }),
              let browserView = m.canvas.tileView(for: browserA2) as? BrowserTileNSView else {
            throw Failure(message: "parked exits: missing live A runtimes")
        }
        _ = try measuredSwitch(fixture, to: Fixture.workspaceB, label: "exit A→B", into: findings)
        // Mutate detached live tab state without the tab-change persistence
        // callback; only the death callback's snapshot can preserve this edit.
        browserView.onTabModelChange = nil
        browserView.createTabForQA(url: "about:blank#parked-exit", title: "Unsaved parked tab")
        let expectedBrowserState = browserView.tabModelForBrowserStatePersistence
        let bTileIdentity = m.canvas.tileView(for: terminalB1).map(ObjectIdentifier.init)
        let b1 = try requireController(fixture, Fixture.projectB1, "parked exit B owner")
        let bCanvasBefore = try b1.projectStore.loadCanvas()
        m.delegate.qaRuntimeExited(terminal.id, exitCode: 23)
        m.delegate.qaBrowserContentProcessTerminated(browser.id)
        findings.expect(!a1.runtimes.contains { $0.id == terminal.id }, "parked terminal exit must unregister runtime")
        findings.expect(!a2.browserRuntimes.contains { $0.id == browser.id }, "parked browser death must unregister runtime")
        findings.expect(m.canvas.tileView(for: terminalB1).map(ObjectIdentifier.init) == bTileIdentity,
                        "parked exits must preserve mounted B tile identity")
        let bCanvasAfter = try b1.projectStore.loadCanvas()
        findings.expect(bCanvasAfter == bCanvasBefore, "parked exits must preserve mounted B persistence")
        let lastExit = try a1.projectStore.loadSession(id: terminal.id).lastExit
        findings.expect(lastExit?.exitCode == 23, "parked terminal exit must persist its exit status")
        let savedBrowser = try a2.projectStore.loadBrowserState().tiles.first { $0.tileId == browserA2 }
        findings.expect(savedBrowser?.activeTabId == expectedBrowserState.activeTabId,
                        "parked browser death must snapshot its current active tab before retiring view")
        findings.expect(savedBrowser?.tabs.count == expectedBrowserState.tabs.count,
                        "parked browser death must snapshot all current tabs")
        _ = try measuredSwitch(fixture, to: Fixture.workspaceA, label: "exit B→A", into: findings)
        findings.expect(m.canvas.tileView(for: terminalA1) is TerminalRestartTileNSView,
                        "remount must show a restart placeholder instead of dead parked terminal")
        findings.expect(m.canvas.tileView(for: browserA2) is BrowserRestartTileNSView,
                        "remount must show a restart placeholder instead of dead parked browser")
        m.delegate.qaRestartTerminalTile(terminalA1)
        m.delegate.qaRestartBrowserTile(browserA2)
        findings.expect(pump(until: 5, { m.canvas.tileView(for: terminalA1) is TerminalTileNSView }),
                        "parked terminal placeholder must restart after remount")
        findings.expect(m.canvas.tileView(for: browserA2) is BrowserTileNSView,
                        "parked browser placeholder must restart after remount")
        let restoredBrowser = m.canvas.tileView(for: browserA2) as? BrowserTileNSView
        findings.expect(restoredBrowser?.activeTabIdForQA == expectedBrowserState.activeTabId,
                        "browser restart must restore snapshotted parked active tab")
        findings.expect(restoredBrowser?.tabCountForQA == expectedBrowserState.tabs.count,
                        "browser restart must restore snapshotted parked tabs")
    }

    private static func warmBrowserBudget(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("browser budget mount")
        let a1 = try requireController(fixture, Fixture.projectA1, "browser budget")
        let a2 = try requireController(fixture, Fixture.projectA2, "browser budget")
        guard let oldBrowser = a2.browserRuntimes.first else { throw Failure(message: "browser budget: A browser not restored") }
        let oldIdentity = ObjectIdentifier(oldBrowser)
        let terminals = a1.runtimes.map(\.id)
        m.runtime.registerLiveBrowser(tileId: oldBrowser.tileId)
        _ = try measuredSwitch(fixture, to: Fixture.workspaceB, label: "budget A→B", into: findings)
        let b1 = try requireController(fixture, Fixture.projectB1, "browser budget B")
        guard let spawner = b1.tileSpawner else { throw Failure(message: "browser budget: missing B spawner") }
        let bBrowser: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: "about:blank", targetZoneId: Fixture.zoneB1) {
        case .spawned(let runtime): bBrowser = runtime
        default: throw Failure(message: "browser budget: B browser spawn failed")
        }
        if !b1.browserRuntimes.contains(where: { $0 === bBrowser }) { b1.browserRuntimes.append(bBrowser) }
        m.runtime.registerLiveBrowser(tileId: bBrowser.tileId)
        let bView = m.canvas.tileView(for: bBrowser.tileId).map(ObjectIdentifier.init)
        let bCanvas = try b1.projectStore.loadCanvas()
        m.runtime.qaSetBrowserRuntimeMaxLive(1)
        m.runtime.enforceBrowserRuntimeBudget()
        findings.expect(a2.browserRuntimes.isEmpty, "global cap must evict the parked A browser")
        findings.expect(b1.browserRuntimes.contains { $0 === bBrowser }, "visible B browser must survive warm eviction")
        findings.expect(m.canvas.tileView(for: bBrowser.tileId).map(ObjectIdentifier.init) == bView,
                        "warm eviction must not replace a view on mounted B canvas")
        let bCanvasAfter = try b1.projectStore.loadCanvas()
        findings.expect(bCanvasAfter == bCanvas, "warm eviction must not persist changes to B canvas")
        findings.expect(a1.runtimes.map(\.id) == terminals, "warm browser eviction must preserve A terminals")
        let persistedA = try a2.projectStore.loadCanvas().tiles.first { $0.id == oldBrowser.tileId }
        findings.expect(persistedA?.runtimeRef == nil, "parked A browser descriptor must be persisted without live runtime")
        m.runtime.qaSetBrowserRuntimeMaxLive(6)
        _ = try measuredSwitch(fixture, to: Fixture.workspaceA, label: "budget B→A", into: findings)
        findings.expect(m.canvas.tileView(for: oldBrowser.tileId) is BrowserTileNSView,
                        "remount must restore the evicted parked browser")
        findings.expect(a2.browserRuntimes.first.map(ObjectIdentifier.init) != oldIdentity,
                        "remount must hydrate a fresh browser after eviction")
        findings.expect(a1.runtimes.map(\.id) == terminals, "remount must keep A terminal identity")
    }

    private static func warmRoundTrip(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("mount")
        guard pump(until: 5, { m.canvas.tileView(for: terminalA1) is TerminalTileNSView }) else {
            throw Failure(message: "precondition: A1's terminal did not restore at mount")
        }
        let a1 = try requireController(fixture, Fixture.projectA1, "precondition")
        let a2 = try requireController(fixture, Fixture.projectA2, "precondition")
        let terminalRuntimeIds = a1.runtimes.map(\.id)
        let browserIdentities = a2.browserRuntimes.map(ObjectIdentifier.init)
        let viewIdentities = [terminalA1, browserA2, agentA2, Fixture.noteA1a, Fixture.fileA1]
            .compactMap { id in m.canvas.tileView(for: id).map { (id, ObjectIdentifier($0)) } }
        let descriptorBefore = descriptor(fixture, Fixture.projectA1, tile: terminalA1)
        guard !terminalRuntimeIds.isEmpty, !browserIdentities.isEmpty, viewIdentities.count == 5,
              descriptorBefore != nil else {
            throw Failure(message: "precondition: A did not mount live (runtimes \(terminalRuntimeIds.count), browsers \(browserIdentities.count), views \(viewIdentities.count), descriptor \(descriptorBefore != nil))")
        }
        let viewportA = m.canvas.viewport
        let surfacesAtMount = GhosttyTerminalView.liveSurfaceCount

        // A → B, cold: B has never been mounted.
        let toB = try measuredSwitch(fixture, to: Fixture.workspaceB, label: "A→B cold", into: findings)
        findings.expect(toB.syncTmuxOperationsOnMain == 0,
                        "A→B cold: \(toB.syncTmuxOperationsOnMain) synchronous tmux round trip(s) blocked the main thread")
        findings.expect(toB.layoutPasses <= 2, "A→B cold: \(toB.layoutPasses) full tile layout passes")
        findings.expect(m.canvas.viewport == Fixture.seededViewports[Fixture.workspaceB],
                        "A→B cold: the camera is \(m.canvas.viewport), not B's saved \(Fixture.seededViewports[Fixture.workspaceB]!) — fit-all overwrote it")
        findings.expect(pump(until: 5, { m.canvas.tileView(for: terminalB1) is TerminalTileNSView }),
                        "A→B cold: B1's terminal never restored")
        findings.expect(m.canvas.tileView(for: terminalA1) == nil, "A→B cold: A's terminal is still in the scene")

        // B → A, warm.
        let toA = try measuredSwitch(fixture, to: Fixture.workspaceA, label: "B→A warm", into: findings)
        findings.expect(m.runtime.lastSwitchReport?.warm == true, "B→A: A was rebuilt rather than re-attached")
        findings.expect(toA.tileViewsBuilt == 0, "B→A: \(toA.tileViewsBuilt) tile view(s) were built for a workspace left a moment ago")
        findings.expect(toA.syncTmuxOperationsOnMain == 0, "B→A: \(toA.syncTmuxOperationsOnMain) synchronous tmux round trip(s) on the main thread")
        findings.expect(toA.sidebarReloads <= 1, "B→A: the sidebar reloaded \(toA.sidebarReloads) times")
        findings.expect(toA.layoutPasses <= 2, "B→A: \(toA.layoutPasses) full tile layout passes")
        findings.expect(m.canvas.viewport == viewportA, "B→A: the camera is \(m.canvas.viewport), not where A was left (\(viewportA))")
        let a1Back = m.runtime.controller(for: Fixture.projectA1)
        let a2Back = m.runtime.controller(for: Fixture.projectA2)
        findings.expect(a1Back === a1 && a1Back?.runtimes.map(\.id) == terminalRuntimeIds,
                        "B→A: A1's terminal runtimes are \(a1Back?.runtimes.map(\.id.uuidString) ?? []), not the ones it left with")
        findings.expect(a2Back === a2 && a2Back?.browserRuntimes.map(ObjectIdentifier.init) == browserIdentities,
                        "B→A: A2's web view was rebuilt (its page reloaded)")
        for (tileId, identity) in viewIdentities {
            findings.expect(m.canvas.tileView(for: tileId).map(ObjectIdentifier.init) == identity,
                            "B→A: tile \(tileId.uuidString.suffix(4)) is a different view object")
        }
        let descriptorAfter = descriptor(fixture, Fixture.projectA1, tile: terminalA1)
        findings.expect(descriptorAfter?.id == descriptorBefore?.id && descriptorAfter?.lastExit == nil,
                        "B→A: A1's terminal descriptor was \(descriptorAfter == nil ? "deleted" : (descriptorAfter?.lastExit != nil ? "stamped exited" : "replaced"))")
        // Surfaces exist only with a WindowServer session to draw into.
        findings.expect(surfacesAtMount == 0 || GhosttyTerminalView.liveSurfaceCount >= surfacesAtMount,
                        "B→A: a warm terminal surface was freed")
        findings.facts["surfacesAtMount"] = surfacesAtMount

        // A → B again: B is warm now too.
        let toBAgain = try measuredSwitch(fixture, to: Fixture.workspaceB, label: "A→B warm", into: findings)
        findings.expect(toBAgain.tileViewsBuilt == 0, "A→B warm: \(toBAgain.tileViewsBuilt) tile view(s) were built")
        findings.expect(toBAgain.syncTmuxOperationsOnMain == 0, "A→B warm: \(toBAgain.syncTmuxOperationsOnMain) synchronous tmux round trip(s)")
        let violations = try fixture.allViolations(expected: expectedScene, invariants: [.wholeness, .geometry, .conservation, .durability])
        findings.expect(violations.isEmpty, "A→B warm: \(violations.map(\.description))")
    }

    private static func requireController(_ fixture: Fixture, _ projectId: UUID, _ step: String) throws -> ZoneRuntimeController {
        let m = try fixture.requireMounted(step)
        guard let controller = m.runtime.controller(for: projectId) else {
            throw Failure(message: "\(step): project \(projectId.uuidString.suffix(4)) has no live controller")
        }
        return controller
    }

    /// Releasing a workspace is a detach (D16): with nothing kept warm, A's
    /// controller closes on the way to B, and its terminal's descriptor must
    /// come back exactly as it was — not stamped exited and pruned, which made
    /// the restored shell open at the project root with its agent status reset.
    private static func releasedWorkspaceKeepsDescriptors(_ fixture: Fixture, _ findings: Findings) throws {
        let previous = fixture.configureMount
        fixture.configureMount = { delegate, runtime in
            previous?(delegate, runtime)
            runtime.warmSceneCapacity = 0
        }
        try fixture.mount()
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("mount")
        guard pump(until: 5, { m.canvas.tileView(for: terminalA1) is TerminalTileNSView }),
              var seeded = descriptor(fixture, Fixture.projectA1, tile: terminalA1) else {
            throw Failure(message: "precondition: A1's terminal did not restore with a descriptor")
        }
        // The shell had cd'd somewhere: that is what a release must not lose.
        let sub = fixture.projectRoots[Fixture.projectA1]!.appendingPathComponent("deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        seeded.cwd = sub.path
        try ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!).saveSession(seeded)

        try fixture.switchTo(Fixture.workspaceB)
        findings.expect(m.runtime.controller(for: Fixture.projectA1) == nil, "precondition: A1's controller was kept although nothing is warm")
        let released = descriptor(fixture, Fixture.projectA1, tile: terminalA1)
        findings.expect(released != nil, "release deleted A1's terminal descriptor")
        findings.expect(released?.lastExit == nil, "release stamped A1's terminal exited: \(String(describing: released?.lastExit))")
        let record = try? ManagedAgentSessionStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!).load(tileId: terminalA1)
        findings.expect(record?.status != .stopped, "release marked A1's terminal session stopped")

        try fixture.switchTo(Fixture.workspaceA)
        findings.expect(pump(until: 5, { m.canvas.tileView(for: terminalA1) is TerminalTileNSView }), "return: A1's terminal did not restore")
        let restored = descriptor(fixture, Fixture.projectA1, tile: terminalA1)
        findings.expect(restored?.cwd == sub.path,
                        "return: A1's terminal opened in \(restored?.cwd ?? "nothing"), not the directory it was in (\(sub.path))")
        findings.facts["cwdAfterReturn"] = restored?.cwd ?? NSNull()
    }

    /// Anything the switch services while it runs — a timer, a queued
    /// callback — may ask for another switch. It must be refused, not run
    /// half-way through the first.
    private static func switchInsideSwitchIsRefused(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let m = try fixture.requireMounted("mount")
        var nested: Result<Void, Error>?
        m.runtime._workspaceDocumentLoader = { [weak runtime = m.runtime, appSupport = fixture.appSupport] workspaceId in
            if nested == nil, let runtime {
                nested = Result { try runtime.switchWorkspace(to: Fixture.workspaceB) }
            }
            return try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).tryLoad()
        }
        try fixture.switchTo(Fixture.workspaceB)
        m.runtime._workspaceDocumentLoader = nil
        if case .success = nested {
            findings.failures.append("a switch started inside a running switch was carried out")
        }
        findings.facts["nested"] = nested.map { result -> String in
            if case let .failure(error) = result { return "\(error)" }
            return "carried out"
        } ?? "never attempted"
        findings.expect(m.runtime.workspaceId == Fixture.workspaceB, "the outer switch did not land")
        let violations = try fixture.allViolations(expected: expectedScene, invariants: [.wholeness, .conservation])
        findings.expect(violations.isEmpty, "after the refused nested switch: \(violations.map(\.description))")
    }

    /// Another install holds B2's `.array/lock` (hazard 10). The switch fails,
    /// naming the project — no modal mid-switch (whose choices were to quit the
    /// app, open the project unlocked, or open a different root under B2's id) —
    /// and nothing it acquired on the way stays acquired.
    private static func heldProjectLockFailsCleanly(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let m = try fixture.requireMounted("mount")
        let otherInstall = ProjectLock(root: fixture.projectRoots[Fixture.projectB2]!)
        try otherInstall.acquire()
        defer { otherInstall.release() }
        var alerts = 0
        m.delegate.qaProjectLockAlertResponder = { _ in alerts += 1; return .openAnyway }

        let landed = m.delegate.qaSwitchWorkspaceFromSidebar(Fixture.workspaceB)
        findings.expect(alerts == 0, "a project-lock modal was presented mid-switch (\(alerts) time(s))")
        findings.expect(!landed && m.runtime.workspaceId == Fixture.workspaceA,
                        "the switch went ahead into a workspace whose project another install holds")
        let message = m.delegate.qaWorkspaceManagementMessage ?? ""
        findings.expect(message.contains("Dogwood"), "the failure does not name the held project: \"\(message)\"")
        try expectNothingAcquired(fixture, [Fixture.projectB1], findings, "held lock")
        let violations = try fixture.allViolations(expected: expectedScene, invariants: [.wholeness, .geometry, .conservation])
        findings.expect(violations.isEmpty, "A was disturbed by the failed switch: \(violations.map(\.description))")
        findings.facts["message"] = message
    }

    /// The registry write that commits the switch fails (its directory is
    /// read-only). Every controller acquired for B must be released and its
    /// lock given back; A stays mounted.
    private static func failedCommitReleasesAcquisitions(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let m = try fixture.requireMounted("mount")
        let fileManager = FileManager.default
        let original = (try? fileManager.attributesOfItem(atPath: fixture.appSupport.path)[.posixPermissions]) ?? 0o755
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.appSupport.path)
        let landed = m.delegate.qaSwitchWorkspaceFromSidebar(Fixture.workspaceB)
        try fileManager.setAttributes([.posixPermissions: original], ofItemAtPath: fixture.appSupport.path)
        findings.expect(!landed && m.runtime.workspaceId == Fixture.workspaceA, "precondition: the registry commit did not fail")
        try expectNothingAcquired(fixture, [Fixture.projectB1, Fixture.projectB2], findings, "failed commit")
        findings.expect(m.runtime.controller(for: Fixture.projectA1) != nil && m.runtime.controller(for: Fixture.projectA2) != nil,
                        "failed commit: A's own controllers were released")
        let violations = try fixture.allViolations(expected: expectedScene, invariants: [.wholeness, .geometry, .conservation])
        findings.expect(violations.isEmpty, "failed commit disturbed A: \(violations.map(\.description))")
        // And the user can still go: the failure was the disk, not the scene.
        findings.expect(m.delegate.qaSwitchWorkspaceFromSidebar(Fixture.workspaceB), "the switch failed again once the disk recovered")
    }

    private static func expectNothingAcquired(_ fixture: Fixture, _ projectIds: [UUID], _ findings: Findings, _ step: String) throws {
        let m = try fixture.requireMounted(step)
        for projectId in projectIds {
            findings.expect(m.runtime.controller(for: projectId) == nil,
                            "\(step): project \(Fixture.projectNames[projectId]!) is still acquired after the switch failed")
            let probe = ProjectLock(root: fixture.projectRoots[projectId]!)
            do { try probe.acquire(); probe.release() } catch {
                findings.failures.append("\(step): project \(Fixture.projectNames[projectId]!)'s lock is still held after the switch failed")
            }
        }
    }

    /// A file editor's web bridge never answers. The switch used to spin the
    /// run loop 5.5 s for it and then fail; it must wait a bounded moment, keep
    /// that editor's last draft, and switch.
    private static func unansweredEditorIsBounded(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let m = try fixture.requireMounted("mount")
        guard let file = m.canvas.tileView(for: Fixture.fileA1) as? FileTileNSView else {
            throw Failure(message: "precondition: the file tile is not live")
        }
        file.qaEditorBarrierNeverAnswers = true
        let started = Date()
        let landed = m.delegate.qaSwitchWorkspaceFromSidebar(Fixture.workspaceB)
        let elapsed = Date().timeIntervalSince(started)
        findings.facts["elapsedMs"] = (elapsed * 1000).rounded()
        findings.expect(landed && m.runtime.workspaceId == Fixture.workspaceB,
                        "one unanswered editor failed the whole switch: \(m.delegate.qaWorkspaceManagementMessage ?? "")")
        findings.expect(m.runtime.lastSwitchReport?.unansweredEditors == 1,
                        "the switch did not record the unanswered editor (report: \(String(describing: m.runtime.lastSwitchReport?.unansweredEditors)))")
        // The one wall-clock bound in this leg, and a loose one: the defect was
        // 5.5 s per editor.
        findings.expect(elapsed < 2.0, "the switch waited \(Int(elapsed * 1000)) ms for an editor that never answers")
    }

    /// The titlebar popup: the bar names the target and shows progress before
    /// the work starts; on success it stays on the target; a switch that fails
    /// puts the bar back on the mounted workspace and says why.
    private static func titlebarFeedback(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.mount()
        let m = try fixture.requireMounted("mount")
        let topBar = WorkspaceTopBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 36))
        m.delegate.qaAttachWorkspaceTopBar(topBar)
        var observed: [(name: String, progress: Bool)] = []
        let prior = m.runtime.lifecycleObserver
        m.runtime.lifecycleObserver = { event in
            prior?(event)
            if case .switchBegan = event {
                observed.append((topBar.workspaceNameForQA, topBar.switchProgressVisibleForQA))
            }
        }
        findings.expect(topBar.selectWorkspaceForQA(Fixture.workspaceB), "precondition: the popup does not offer B")
        findings.expect(observed.first?.name == "Forest" && observed.first?.progress == true,
                        "when the switch began, the bar said \(observed.first.map { "\"\($0.name)\", progress \($0.progress)" } ?? "nothing")")
        findings.expect(m.runtime.workspaceId == Fixture.workspaceB, "the popup switch did not land")
        findings.expect(topBar.selectedWorkspaceIdForQA == Fixture.workspaceB && !topBar.switchProgressVisibleForQA,
                        "after the switch the bar shows \(String(describing: topBar.selectedWorkspaceIdForQA)), progress \(topBar.switchProgressVisibleForQA)")

        // A's document is gone: the switch back must fail visibly and the bar
        // must go back to B.
        let layout = WorkspaceStoreLayout(applicationSupportDirectory: fixture.appSupport, workspaceId: Fixture.workspaceA)
        let parked = fixture.root.appendingPathComponent("parked-workspace-A", isDirectory: true)
        try FileManager.default.moveItem(at: layout.workspaceDirectory, to: parked)
        defer { try? FileManager.default.moveItem(at: parked, to: layout.workspaceDirectory) }
        _ = topBar.selectWorkspaceForQA(Fixture.workspaceA)
        findings.expect(m.runtime.workspaceId == Fixture.workspaceB, "precondition: the switch to a missing document did not fail")
        findings.expect(topBar.selectedWorkspaceIdForQA == Fixture.workspaceB && topBar.workspaceNameForQA == "Forest",
                        "after a failed switch the bar shows \(topBar.workspaceNameForQA) / \(String(describing: topBar.selectedWorkspaceIdForQA)), not the workspace still mounted")
        findings.expect(!topBar.switchProgressVisibleForQA, "after a failed switch the bar still shows progress")
        let message = m.delegate.qaWorkspaceManagementMessage ?? ""
        findings.expect(message.contains("Grove"), "a failed titlebar switch said nothing the user can see: \"\(message)\"")
        findings.facts["failureMessage"] = message
    }
}
