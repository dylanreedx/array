import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// TR-06 · the AppKit witness for responding to a provider-held request.
///
/// **What went wrong here, and what this file is for.** `onProviderResponse` was
/// declared on `ManagedAgentTileNSView` and never bound by production. The one
/// check that exercised it — `checkLiveV2TileMigration` — assigned the closure
/// ITSELF, so it proved the tile's dispatch guards and nothing whatsoever about
/// the app. Meanwhile `AgentRequestView` rendered its choice buttons whenever the
/// payload was pending, with no reference to whether anything could carry a
/// response. Had a provider ever opened a request, the user would have been shown
/// live-looking buttons that pressed into nil.
///
/// So this leg **drives `AppDelegate.wireManagedAgentTile`** and asserts the
/// binding exists, rather than creating one. A witness that binds the seam it is
/// testing is the failure mode, not the test.
///
/// The runners are fakes, but the SEAM is real: `AgentRequestResponding` is the
/// production protocol, `AgentSupervisor.respondToRequest` is the production
/// method, and the events arrive through `AgentSupervisor.qaDeliver` into the
/// real projection. Nothing here spawns a provider or touches a socket.
@MainActor
enum ProviderRequestResponseChecks {
    struct CheckError: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError(description: message) }
    }

    /// A runner that CAN carry a response. Records every delivered decision so a
    /// witness can assert exactly-once, and can be told to fail delivery.
    final class RespondingRunner: AgentRunning, AgentRequestResponding, @unchecked Sendable {
        struct TransportRefused: Error, CustomStringConvertible {
            var description: String { "app-server refused the response" }
        }

        private let lock = NSLock()
        private var deliveredStorage: [(String, ApprovalDecision)] = []
        private let held = DispatchSemaphore(value: 0)
        /// Flipped by a witness to model a transport that accepts the call and
        /// then fails, which is the case the UI has to survive.
        var failDelivery = false
        var canRespondToRequests = true

        var delivered: [(String, ApprovalDecision)] {
            lock.lock(); defer { lock.unlock() }
            return deliveredStorage
        }

        func respond(requestID: String, decision: ApprovalDecision) throws {
            if failDelivery { throw TransportRefused() }
            lock.lock()
            deliveredStorage.append((requestID, decision))
            lock.unlock()
        }

        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            held.wait()
        }
        func stop() { held.signal() }
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
        func observeRuntimeObservations(
            _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
        var keepsSessionAliveBetweenTurns: Bool { true }
        var canAcceptAnotherTurn: Bool { true }
    }

    /// Builds a real delegate + canvas + tile and runs the PRODUCTION wiring,
    /// exactly as `CompletionAwarenessChecks` does.
    private struct Fixture {
        let delegate: AppDelegate
        let supervisor: AgentSupervisor
        let tileView: ManagedAgentTileNSView
        let agentId: AgentID
        let temporary: URL
    }

    private static func makeFixture(
        makeRunner: @escaping (AgentRunnerLaunch) -> AgentRunning
    ) throws -> Fixture {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("array-tr06-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("project", isDirectory: true)
        for dir in [appSupport, agentsSupport, projectRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let now = Date()
        let tileId = UUID()
        let agentId = AgentID(rawValue: UUID())
        let agentStore = AgentStore(applicationSupportDirectory: agentsSupport)
        try agentStore.upsert(AgentRecord(
            id: agentId, displayName: "tr06 agent", role: "reviewer",
            model: "openai-codex/gpt-5.6-sol", thinking: "medium", cwd: projectRoot.path,
            projectId: UUID(), createdAt: now, lastActivityAt: now, tileId: tileId))

        let tile = Tile(
            id: tileId, kind: .managedAgent, title: "tr06 agent",
            frame: TileFrame(x: 40, y: 40, width: 520, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [],
            lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 640)

        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        canvas.occlusionVisibilityProvider = { true }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        // Parked off every display: a check must never take the screen.
        window.orderFrontOffscreenForChecks()

        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        canvas.layoutSubtreeIfNeeded()

        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(store: agentStore, makeRunner: makeRunner)
        let supervisor = delegate.agentSupervisor
        supervisor.restore()
        delegate.installAcceptedTileFocusHook()
        // THE production entry point. Everything asserted below is a consequence
        // of this call, never of this file reaching into the tile.
        delegate.wireManagedAgentTile(tileId, agentID: agentId)

        return Fixture(
            delegate: delegate, supervisor: supervisor, tileView: tileView,
            agentId: agentId, temporary: temporary)
    }

    static func run() async throws {
        try await checkProductionBindsTheTransport()
        try await checkNoTransportOffersNoControls()
        try await checkDispatchIsExactlyOnceAndResolvesNothing()
        try await checkDeliveryFailureKeepsTheRequestOpen()
        print(
            "ProviderRequestResponseChecks passed: production binds the response transport, a "
            + "runner without one offers no controls at all, a press dispatches exactly once and "
            + "resolves nothing until the provider says so, a resolved request refuses a stale "
            + "press, and a failed delivery leaves the request open and answerable"
        )
    }

    // MARK: - W1 · production binds the seam

    /// The assertion that would have caught the whole defect: after the real
    /// wiring runs, the transport is bound. This check must never assign
    /// `onProviderResponse` itself.
    private static func checkProductionBindsTheTransport() async throws {
        let fixture = try makeFixture { _ in RespondingRunner() }
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }

        try expect(
            fixture.tileView.qaHasProviderResponseBinding,
            "TR-06 W1: wireManagedAgentTile left onProviderResponse unbound — every choice "
            + "button in a request block would press into nil, exactly as it did before this "
            + "ticket. (If this check ever binds the seam itself, delete the check: it proves "
            + "nothing.)"
        )
    }

    // MARK: - W2 · no transport, no controls

    private static func checkNoTransportOffersNoControls() async throws {
        // A one-shot scripted runner is the honest stand-in for claude/codex-exec:
        // it does not conform to AgentRequestResponding at all.
        let fixture = try makeFixture { _ in
            ScriptedAgentRunner(script: [], holdUntilStopped: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let tile = fixture.tileView

        _ = fixture.supervisor.send("open a request", to: fixture.agentId)
        let thread = try requireThread(fixture)
        fixture.supervisor.qaDeliver(.requestOpened(
            threadId: thread, requestId: "req-no-transport", kind: .commandExecutionApproval
        ), to: fixture.agentId)
        try await settle(tile) { $0.qaV2RequestIDs.contains("req-no-transport") }

        let snapshot = fixture.supervisor.turnSnapshot(for: fixture.agentId)
        try expect(
            snapshot?.capabilities.canRespondToRequests == false,
            "TR-06 W2: a runner that cannot conform to AgentRequestResponding advertised the "
            + "response capability anyway"
        )
        // The tile still shows the request — readable history is the point.
        try expect(
            tile.qaV2RequestStatus("req-no-transport") != nil,
            "TR-06 W2: a request with no transport vanished instead of remaining readable"
        )
        // And a press cannot dispatch, because the tile's own seam refuses.
        tile.layoutSubtreeIfNeeded()
        _ = tile.qaClickV2RequestChoice(
            requestID: "req-no-transport", value: ApprovalDecision.accept.rawValue)
        try expect(
            tile.qaV2RequestResponseState("req-no-transport") == .failed,
            "TR-06 W2: a press with no transport did not report failure — the user is left "
            + "believing they answered"
        )
        try expect(
            tile.qaV2RequestStatus("req-no-transport") == .inProgress,
            "TR-06 W2: a refused press changed the PROVIDER's status; only a resolution event may"
        )
    }

    // MARK: - W3 · exactly once, and it resolves nothing

    private static func checkDispatchIsExactlyOnceAndResolvesNothing() async throws {
        let runner = RespondingRunner()
        let fixture = try makeFixture { _ in runner }
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let tile = fixture.tileView

        _ = fixture.supervisor.send("open a request", to: fixture.agentId)
        let thread = try requireThread(fixture)
        fixture.supervisor.qaDeliver(.requestOpened(
            threadId: thread, requestId: "req-live", kind: .applyPatchApproval
        ), to: fixture.agentId)
        try await settle(tile) { $0.qaV2RequestIDs.contains("req-live") }

        try expect(
            fixture.supervisor.turnSnapshot(for: fixture.agentId)?
                .capabilities.canRespondToRequests == true,
            "TR-06 W3: a runner conforming to AgentRequestResponding did not advertise the "
            + "capability, so its buttons would never appear"
        )

        tile.layoutSubtreeIfNeeded()
        _ = tile.qaClickV2RequestChoice(
            requestID: "req-live", value: ApprovalDecision.decline.rawValue)
        try await settle(tile) { _ in runner.delivered.count == 1 }

        try expect(
            runner.delivered.count == 1
                && runner.delivered[0].0 == "req-live"
                && runner.delivered[0].1 == .decline,
            "TR-06 W3: the press did not reach the transport exactly once with its own decision "
            + "(got \(runner.delivered))"
        )
        // THE invariant: dispatching is not resolving.
        try expect(
            tile.qaV2RequestStatus("req-live") == .inProgress,
            "TR-06 W3: dispatching a response resolved the request locally — only the provider's "
            + "own requestResolved may do that"
        )
        try expect(
            tile.qaV2RequestResponseState("req-live") == .submitting,
            "TR-06 W3: an in-flight response left no visible trace, so the user cannot tell a "
            + "slow provider from a dead button"
        )

        // A second press while the first is in flight must not put a second
        // answer on the wire.
        _ = tile.qaClickV2RequestChoice(
            requestID: "req-live", value: ApprovalDecision.accept.rawValue)
        _ = await waitUntil(timeout: 0.3, pollInterval: 0.02) { false }
        try expect(
            runner.delivered.count == 1,
            "TR-06 W3: a second press while a response was in flight dispatched again (got "
            + "\(runner.delivered)) — the provider would receive two answers to one question"
        )

        // The provider resolves it. Now the block is passive.
        fixture.supervisor.qaDeliver(.requestResolved(
            threadId: thread, requestId: "req-live",
            decision: ApprovalDecision.decline.rawValue
        ), to: fixture.agentId)
        try await settle(tile) { $0.qaV2RequestStatus("req-live") == .cancelled }

        // A stale press against the settled request dispatches nothing.
        _ = tile.qaClickV2RequestChoice(
            requestID: "req-live", value: ApprovalDecision.accept.rawValue)
        _ = await waitUntil(timeout: 0.3, pollInterval: 0.02) { false }
        try expect(
            runner.delivered.count == 1,
            "TR-06 W3: a press on an already-resolved request reached the transport"
        )
    }

    // MARK: - W4 · a failed delivery is not a decision

    private static func checkDeliveryFailureKeepsTheRequestOpen() async throws {
        let runner = RespondingRunner()
        runner.failDelivery = true
        let fixture = try makeFixture { _ in runner }
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let tile = fixture.tileView

        _ = fixture.supervisor.send("open a request", to: fixture.agentId)
        let thread = try requireThread(fixture)
        fixture.supervisor.qaDeliver(.requestOpened(
            threadId: thread, requestId: "req-doomed", kind: .commandExecutionApproval
        ), to: fixture.agentId)
        try await settle(tile) { $0.qaV2RequestIDs.contains("req-doomed") }

        tile.layoutSubtreeIfNeeded()
        _ = tile.qaClickV2RequestChoice(
            requestID: "req-doomed", value: ApprovalDecision.accept.rawValue)
        // The transport accepted the call and then threw, off the main thread;
        // the failure has to travel back and repaint.
        try await settle(tile) { $0.qaV2RequestResponseState("req-doomed") == .failed }

        try expect(
            tile.qaV2RequestStatus("req-doomed") == .inProgress,
            "TR-06 W4: a transport failure resolved the request — a response that never arrived "
            + "must never look like one the provider answered"
        )
        // Positive control: the request is answerable again. Without this, a
        // latched `.failed` would pass the assertion above and still strand the
        // user with a question they cannot answer.
        runner.failDelivery = false
        _ = tile.qaClickV2RequestChoice(
            requestID: "req-doomed", value: ApprovalDecision.accept.rawValue)
        try await settle(tile) { _ in runner.delivered.count == 1 }
        try expect(
            runner.delivered.count == 1 && runner.delivered[0].1 == .accept,
            "TR-06 W4: after a failed delivery the user could not retry the answer "
            + "(got \(runner.delivered))"
        )
    }

    // MARK: - helpers

    /// The agent's derived thread id — the same derivation the supervisor uses to
    /// restamp every delivered event. Requests are thread-scoped, so delivering
    /// against any other id projects nothing and every assertion below would fail
    /// for the wrong reason.
    private static func requireThread(_ fixture: Fixture) throws -> String {
        AgentSupervisor.threadId(for: fixture.agentId)
    }

    private static func settle(
        _ tile: ManagedAgentTileNSView,
        until condition: @escaping (ManagedAgentTileNSView) -> Bool
    ) async throws {
        guard await waitUntil(timeout: 5, pollInterval: 0.02, { condition(tile) }) else {
            throw CheckError(description: "TR-06: the tile never reached the expected state")
        }
        tile.layoutSubtreeIfNeeded()
    }
}
