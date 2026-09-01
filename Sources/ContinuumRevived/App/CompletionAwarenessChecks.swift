import AppKit
import ContinuumRevivedCore
import Foundation

/// WS4 · the AppKit witness for managed-agent completion awareness.
///
/// **This drives the production path, it does not re-derive it.** One real
/// `AppDelegate`, its own `AgentSupervisor`, a real `CanvasNSView` in a real
/// `NSWindow`, a real `ManagedAgentTileNSView` wired by the production
/// `wireManagedAgentTile`, and events pushed through `AgentSupervisor.deliver`.
/// The live half therefore arrives the way it does in the app — asynchronously,
/// off the tile's own multicast subscription into `recordManagedActivity` —
/// rather than by this file calling the app's internals in the right order.
///
/// The app's activation state is moved by delivering the REAL
/// `applicationDidBecomeActive` / `applicationDidResignActive` delegate methods,
/// because "no false read after resign" is the defect and a settable flag would
/// witness nothing. What IS injected is only what a check may not do to the
/// machine it runs on: window occlusion (the same `occlusionVisibilityProvider`
/// seam canvas residency already uses, required because a fixture window is
/// parked off every display) and the Reduce Motion answer.
///
/// Every "…and nothing happened" assertion is paired with a POSITIVE CONTROL —
/// a counter proving the path really ran — so a break that stops delivery
/// altogether reads as RED, not as a pass.
@MainActor
enum CompletionAwarenessChecks {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError(description: message) }
    }

    /// Non-autoclosure form, for asserting a value that had to be `await`ed.
    private static func expectValue(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError(description: message) }
    }

    static func run() async throws -> URL {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("array-ws4-awareness-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("project", isDirectory: true)
        for dir in [appSupport, agentsSupport, projectRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: temporary) }

        let now = Date()
        let tileId = UUID(uuidString: "W54A0000-0000-4000-8000-000000000001".replacingOccurrences(of: "W54A", with: "0540"))!
        let agentId = AgentID(rawValue: UUID(uuidString: "05400000-0000-4000-8000-0000000000A1")!)
        let projectId = UUID(uuidString: "05400000-0000-4000-8000-0000000000C1")!

        let agentStore = AgentStore(applicationSupportDirectory: agentsSupport)
        try agentStore.upsert(AgentRecord(
            id: agentId, displayName: "ws4 agent", role: "reviewer",
            model: "openai-codex/gpt-5.6-sol", thinking: "medium", cwd: projectRoot.path,
            projectId: projectId, createdAt: now, lastActivityAt: now, tileId: tileId))

        // --- the real canvas, window and tile -------------------------------
        let tile = Tile(
            id: tileId, kind: .managedAgent, title: "ws4 agent",
            frame: TileFrame(x: 40, y: 40, width: 420, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [],
            lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 640)

        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        // A fixture window is parked off every display (`orderFrontOffscreenForChecks`),
        // so its real `occlusionState` never contains `.visible`. This is the same
        // seam canvas residency injects for exactly the same reason; the OCCLUDED
        // section below drives it to `false` and proves the fact is load-bearing.
        var windowIsUnoccluded = true
        canvas.occlusionVisibilityProvider = { windowIsUnoccluded }

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()

        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        canvas.layoutSubtreeIfNeeded()

        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(
            store: agentStore,
            makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
        let supervisor = delegate.agentSupervisor
        supervisor.restore()
        var reduceMotion = false
        delegate.reduceMotionProvider = { reduceMotion }
        // Installs BOTH the accepted-focus bridge and the awareness hooks; folding
        // them together is what makes it impossible for a boot path to wire one
        // and forget the other.
        delegate.installAcceptedTileFocusHook()
        // The production wiring: attaches the agent to the tile, subscribes the
        // tile to the supervisor's stream and installs `onIngestedEvent`, which is
        // how the live half reaches `recordManagedActivity`.
        delegate.wireManagedAgentTile(tileId, agentID: agentId)

        try expect(supervisor.records[agentId]?.tileId == tileId,
                   "setup: the record must name the fixture tile")
        try expect(canvas.tileView(for: tileId) === tileView,
                   "setup: the fixture tile must be the mounted view")

        // --- helpers --------------------------------------------------------
        var turn = 0
        func nextTurn() -> String { turn += 1; return "t\(turn)" }

        /// Push one event through the REAL supervisor delivery, then wait for the
        /// tile's own subscription to carry it into `recordManagedActivity`. The
        /// wait is on the observable consequence, never on a fixed sleep.
        func deliverAndSettle(_ event: AgentRuntimeEvent, expectingSignal: Bool) async -> Bool {
            let signalsBefore = delegate.agentSignalCenter.history.count
            supervisor.qaDeliver(event, to: agentId)
            guard expectingSignal else {
                // Still drain a few main-queue turns so any consequence that WOULD
                // have happened has had the chance to.
                _ = await waitUntil(timeout: 0.35, pollInterval: 0.02) { false }
                return true
            }
            return await waitUntil(timeout: 6, pollInterval: 0.02) {
                delegate.agentSignalCenter.history.count > signalsBefore
            }
        }

        func focusTileDeliberately() throws {
            try expect(delegate.focusBroker.requestFocus(.tile(tileId), reason: .userClick),
                       "the tile must accept a deliberate click focus")
        }

        func responderIsInTile() -> Bool {
            guard let responder = window.firstResponder as? NSView else { return false }
            return responder === tileView || responder.isDescendant(of: tileView)
        }

        var rows: [[String: Any]] = []
        func record(_ label: String) {
            let facts = supervisor.qaLastArrivalFacts
            rows.append([
                "step": label,
                "appActive": delegate.applicationIsActiveForAwareness,
                "windowNotUpstaged": NSApplication.shared.keyWindow.map { $0 === window } ?? true,
                "windowUnoccluded": windowIsUnoccluded,
                "responderInTile": responderIsInTile(),
                "focusScopeIsTile": delegate.focusBroker.activeSurface == .tile(tileId),
                "arrivalFacts": facts.map { [
                    "isActivelyViewed": $0.isActivelyViewed,
                    "blocking": $0.blockingReasons,
                ] } ?? [:],
                "arrivalDecision": supervisor.qaLastArrivalDecision.map { [
                    "advancesReadWatermark": $0.advancesReadWatermark,
                    "clearsLiveSignal": $0.clearsLiveSignal,
                    "acknowledgesVisually": $0.acknowledgesVisually,
                ] } ?? [:],
                "durableUnread": supervisor.records[agentId]?.isUnread ?? false,
                "liveSignal": delegate.agentSignalCenter.currentByTile[tileId]?.kind.rawValue as Any,
                "acknowledgmentPhase": tileView.qaAcknowledgmentPhase.rawValue,
                "activeAnimations": tileView.qaAcknowledgmentAnimationCount,
                "scheduledWork": tileView.qaAcknowledgmentHasScheduledWork,
                "terminalArrivals": supervisor.qaTerminalArrivalCount,
                "watchedArrivals": supervisor.qaWatchedTerminalArrivalCount,
                "acknowledgmentsPlayed": delegate.qaCompletionAcknowledgmentCount,
                "nonDeliberateFocusRefusals": delegate.qaNonDeliberateFocusCount,
            ])
        }

        // =====================================================================
        // A · AWAY. The app has never become active, so nothing can be viewed.
        //     The completion must stay unread AND keep its live signal.
        // =====================================================================
        try expect(!delegate.applicationIsActiveForAwareness,
                   "setup: a delegate built with Array inactive must start inactive")
        var awayTurn = nextTurn()
        try expectValue(await deliverAndSettle(
            .turnStarted(threadId: "ws4", turnId: awayTurn), expectingSignal: false), "away turnStarted")
        try expectValue(await deliverAndSettle(
            .turnCompleted(threadId: "ws4", turnId: awayTurn, outcome: .completed, errorMessage: nil),
            expectingSignal: true),
                   "the away completion must still publish a live signal")
        record("A-away-completion")
        try expect(supervisor.qaTerminalArrivalCount == 1,
                   "POSITIVE CONTROL: the arrival really reached the awareness decision — count is \(supervisor.qaTerminalArrivalCount)")
        try expect(supervisor.qaWatchedTerminalArrivalCount == 0,
                   "a completion delivered while the app was never active must not be watched")
        try expect(supervisor.records[agentId]?.isUnread == true,
                   "a completion that landed while away must be UNREAD")
        try expect(delegate.agentSignalCenter.currentByTile[tileId]?.kind == .completed,
                   "the away completion must keep its live signal — got \(String(describing: delegate.agentSignalCenter.currentByTile[tileId]?.kind))")
        try expect(tileView.qaAcknowledgmentPhase == .idle && delegate.qaCompletionAcknowledgmentCount == 0,
                   "an away completion must not play the acknowledgment")

        // =====================================================================
        // B · RESTORATION IS NOT A VISIT. Coming back to Array, and dismissing a
        //     modal, both deliver an accepted-tile-focus callback. Neither may
        //     clear the unread completion earned in A.
        // =====================================================================
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared))
        // The broker's activation fallback is what re-points focus at a tile on
        // the way back in; drive it exactly as the broker would.
        _ = delegate.focusBroker.requestFocus(.tile(tileId), reason: .appActivated)
        record("B-app-reactivated")
        try expect(delegate.qaNonDeliberateFocusCount == 1,
                   "POSITIVE CONTROL: the restoration focus really reached the read-state bridge and was refused — count is \(delegate.qaNonDeliberateFocusCount)")
        try expect(supervisor.records[agentId]?.isUnread == true,
                   "returning to Array must not mark a background completion read")
        try expect(delegate.agentSignalCenter.currentByTile[tileId]?.kind == .completed,
                   "returning to Array must not clear the live completion signal")

        delegate.focusBroker.openModal(.palette)
        delegate.focusBroker.closeModal(.palette)
        record("B-modal-dismissed")
        try expect(delegate.qaNonDeliberateFocusCount == 2,
                   "POSITIVE CONTROL: modal dismissal really restored tile focus and was refused — count is \(delegate.qaNonDeliberateFocusCount)")
        try expect(supervisor.records[agentId]?.isUnread == true,
                   "dismissing a modal must not mark a background completion read")

        // Relaunch: the durable truth is on disk, so a fresh supervisor over the
        // same store must still say unread. This is the assertion a purely
        // in-memory fix would fail.
        let relaunchSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: agentsSupport),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })
        relaunchSupervisor.restore()
        try expect(relaunchSupervisor.records[agentId]?.isUnread == true,
                   "the unread completion must survive a relaunch — a fresh supervisor read \(String(describing: relaunchSupervisor.records[agentId]?.isUnread))")

        // =====================================================================
        // C · THE DELIBERATE VISIT clears what restoration could not. Durable and
        //     live are cleared by different owners, and both must move.
        // =====================================================================
        try focusTileDeliberately()
        record("C-deliberate-visit")
        try expect(supervisor.records[agentId]?.isUnread == false,
                   "a deliberate visit must clear the unread mark")
        try expect(delegate.agentSignalCenter.currentByTile[tileId] == nil,
                   "a deliberate visit must clear the live signal")

        // =====================================================================
        // D · DURABLE AND LIVE ARE SEPARATELY OBSERVABLE. Rewinding the durable
        //     watermark must not resurrect a live signal, and clearing a live
        //     signal must not touch the watermark.
        // =====================================================================
        try expect(supervisor.markUnread(agentID: agentId),
                   "setup: the watermark must be rewindable")
        record("D-durable-rewound")
        try expect(supervisor.records[agentId]?.isUnread == true,
                   "the durable watermark alone went back to unread")
        try expect(delegate.agentSignalCenter.currentByTile[tileId] == nil,
                   "…while the live signal stayed cleared — the two are not one value")
        try focusTileDeliberately()
        try expect(supervisor.records[agentId]?.isUnread == false, "re-visiting clears it again")

        // =====================================================================
        // E · WATCHED COMPLETION. Every fact holds: the app is active, the window
        //     is key and unoccluded, the responder is inside the tile and the
        //     focus scope is the tile. The completion must count as READ with no
        //     exit and re-entry, and must play the finite acknowledgment.
        // =====================================================================
        try expect(responderIsInTile(), "setup: the deliberate focus must have landed inside the tile")
        let watchedFacts = delegate.activeViewFacts(forAgent: agentId)
        try expect(watchedFacts.isActivelyViewed,
                   "setup: the fixture must actually be actively viewed — blocked by \(watchedFacts.blockingReasons)")
        let watchedTurn = nextTurn()
        try expectValue(await deliverAndSettle(
            .turnStarted(threadId: "ws4", turnId: watchedTurn), expectingSignal: false), "watched turnStarted")
        let acknowledgmentsBefore = delegate.qaCompletionAcknowledgmentCount
        try expectValue(await deliverAndSettle(
            .turnCompleted(threadId: "ws4", turnId: watchedTurn, outcome: .completed, errorMessage: nil),
            expectingSignal: true), "the watched completion must publish a signal")
        _ = await waitUntil(timeout: 3, pollInterval: 0.02) {
            delegate.qaCompletionAcknowledgmentCount > acknowledgmentsBefore
        }
        record("E-watched-completion")
        try expect(supervisor.qaWatchedTerminalArrivalCount == 1,
                   "POSITIVE CONTROL: exactly one arrival has been judged watched so far — got \(supervisor.qaWatchedTerminalArrivalCount)")
        try expect(supervisor.records[agentId]?.isUnread == false,
                   "a completion watched live counts as READ without leaving and coming back")
        try expect(delegate.agentSignalCenter.currentByTile[tileId] == nil,
                   "a watched completion retires its live signal")
        try expect(delegate.qaCompletionAcknowledgmentCount == acknowledgmentsBefore + 1,
                   "the watched completion must play exactly one acknowledgment")
        try expect(tileView.qaAcknowledgmentPhase == .acknowledging,
                   "the acknowledgment must be running immediately after the completion — phase \(tileView.qaAcknowledgmentPhase.rawValue)")
        try expect(tileView.qaAcknowledgmentAnimationCount >= 1,
                   "POSITIVE CONTROL: the pulse must actually be animating — \(tileView.qaAcknowledgmentAnimationCount) animations")
        try expect(!tileView.qaAwarenessBorderIsHidden, "the acknowledgment must be visible while it runs")
        // THE SCHEDULE, read off the live layer. A wall clock in a check process
        // is not trustworthy as an upper bound (the main queue is shared with tile
        // hydration and surface refreshes), so finiteness is asserted where it is
        // actually decided: a finite `repeatCount`, and cycles that add up to the
        // plan's duration.
        let livePlan = try { () throws -> AgentCompletionAcknowledgmentPlan in
            guard let plan = tileView.qaAcknowledgmentPlan else {
                throw CheckError(description: "the acknowledgment recorded no plan")
            }
            return plan
        }()
        try expect(livePlan.isWithinContractWindow,
                   "the production plan must sit in the 1.2–1.6s contract window — \(livePlan.duration)s")
        try expect(livePlan.pulseCount > 0, "the ordinary plan must pulse — \(livePlan.pulseCount)")
        guard let repeatCount = tileView.qaAcknowledgmentAnimationRepeatCount,
              let totalDuration = tileView.qaAcknowledgmentAnimationTotalDuration else {
            throw CheckError(description: "the pulse animation is not on the layer under its own key")
        }
        try expect(repeatCount.isFinite && repeatCount > 0,
                   "the pulse must repeat a FINITE number of times — repeatCount \(repeatCount)")
        try expect(abs(totalDuration - livePlan.duration) < 0.001,
                   "the pulse cycles must add up to the plan duration — \(totalDuration) vs \(livePlan.duration)")

        // …AND IT ENDS. Asserting the END STATE, not merely that it started, and
        // timing the real wall clock so "finite" is measured rather than assumed.
        let startedGenerations = tileView.qaAcknowledgmentsStarted
        let pulseStarted = Date()
        let ended = await waitUntil(timeout: 60, pollInterval: 0.02) {
            tileView.qaAcknowledgmentPhase == .finished
        }
        let pulseElapsed = Date().timeIntervalSince(pulseStarted)
        try expect(ended, "the pulse never terminated — phase \(tileView.qaAcknowledgmentPhase.rawValue) started=\(tileView.qaAcknowledgmentsStarted) finished=\(tileView.qaAcknowledgmentsFinished) scheduled=\(tileView.qaAcknowledgmentHasScheduledWork) gen=\(tileView.qaAcknowledgmentGeneration) elapsed=\(pulseElapsed)")
        try expect(pulseElapsed >= AgentCompletionAcknowledgmentPlan.minimumDuration - 0.35,
                   "the pulse ended far too early to be the contract's 1.2–1.6s — \(pulseElapsed)s")
        try expect(tileView.qaAcknowledgmentsStarted == startedGenerations,
                   "no new acknowledgment may begin during the wait — \(startedGenerations) -> \(tileView.qaAcknowledgmentsStarted)")
        // DELIBERATELY NO WALL-CLOCK CEILING. "The pulse terminates" is witnessed
        // by `ended` above — a bounded poll that returns false if the phase never
        // reaches `.finished` — and the DURATION contract is witnessed by the
        // schedule assertions, which read the plan and the animation the
        // production path actually installed. A wall-clock upper bound here
        // measures the machine (a loaded host stalls this main queue for
        // minutes), not the code, and a gate that fails under load is worse than
        // no gate.
        try expect(tileView.qaAcknowledgmentAnimationCount == 0,
                   "no animation may survive the acknowledgment — \(tileView.qaAcknowledgmentAnimationCount) left")
        try expect(!tileView.qaAcknowledgmentHasScheduledWork,
                   "no scheduled work may survive the acknowledgment")
        try expect(tileView.qaAwarenessBorderIsHidden,
                   "the tile must return to the ordinary read appearance")
        try expect(tileView.qaAcknowledgmentsStarted == tileView.qaAcknowledgmentsFinished,
                   "every started acknowledgment must have finished — \(tileView.qaAcknowledgmentsStarted) started, \(tileView.qaAcknowledgmentsFinished) finished")
        record("E-pulse-terminated")

        // =====================================================================
        // F · REDUCE MOTION: the same finite window, statically. No animation at
        //     any point, and no repeating timer left behind.
        // =====================================================================
        reduceMotion = true
        let staticTurn = nextTurn()
        try expectValue(await deliverAndSettle(
            .turnStarted(threadId: "ws4", turnId: staticTurn), expectingSignal: false), "reduce-motion turnStarted")
        let staticAcksBefore = delegate.qaCompletionAcknowledgmentCount
        try expectValue(await deliverAndSettle(
            .turnCompleted(threadId: "ws4", turnId: staticTurn, outcome: .completed, errorMessage: nil),
            expectingSignal: true), "the reduce-motion completion must publish a signal")
        _ = await waitUntil(timeout: 3, pollInterval: 0.02) {
            delegate.qaCompletionAcknowledgmentCount > staticAcksBefore
        }
        try expect(delegate.qaCompletionAcknowledgmentCount == staticAcksBefore + 1,
                   "POSITIVE CONTROL: Reduce Motion must still produce an acknowledgment, not skip it")
        try expect(tileView.qaAcknowledgmentPhase == .acknowledging,
                   "Reduce Motion must still acknowledge — phase \(tileView.qaAcknowledgmentPhase.rawValue)")
        try expect(!tileView.qaAwarenessBorderIsHidden,
                   "the Reduce Motion acknowledgment must be visible while it holds")
        try expect(tileView.qaAcknowledgmentAnimationCount == 0,
                   "Reduce Motion must add NO animation — \(tileView.qaAcknowledgmentAnimationCount) present")
        record("F-reduce-motion-holding")
        let staticStarted = Date()
        let staticEnded = await waitUntil(timeout: 60, pollInterval: 0.02) {
            tileView.qaAcknowledgmentPhase == .finished
        }
        let staticElapsed = Date().timeIntervalSince(staticStarted)
        try expect(staticEnded,
                   "the Reduce Motion acknowledgment must END — it may not become a persistent treatment")
        try expect(staticElapsed >= AgentCompletionAcknowledgmentPlan.minimumDuration - 0.35,
                   "the static acknowledgment ended far too early — \(staticElapsed)s")
        let staticPlan = tileView.qaAcknowledgmentPlan
        try expect(staticPlan?.isWithinContractWindow == true,
                   "Reduce Motion must keep the same finite contract window — \(String(describing: staticPlan?.duration))")
        try expect(staticPlan?.pulseCount == 0,
                   "the Reduce Motion plan must carry zero pulses — \(String(describing: staticPlan?.pulseCount))")
        try expect(tileView.qaAcknowledgmentAnimationCount == 0 && !tileView.qaAcknowledgmentHasScheduledWork,
                   "Reduce Motion must leave no animation and no scheduled work behind")
        try expect(tileView.qaAwarenessBorderIsHidden,
                   "Reduce Motion must return to the ordinary read appearance")
        record("F-reduce-motion-ended")
        reduceMotion = false

        // =====================================================================
        // G · FAILURE DOES NOT COLLAPSE INTO SUCCESS. Watched, so it is read —
        //     but it keeps its own live signal and never borrows the green
        //     acknowledgment.
        // =====================================================================
        let failTurn = nextTurn()
        try expectValue(await deliverAndSettle(
            .turnStarted(threadId: "ws4", turnId: failTurn), expectingSignal: false), "failure turnStarted")
        let acksBeforeFailure = delegate.qaCompletionAcknowledgmentCount
        let watchedBeforeFailure = supervisor.qaWatchedTerminalArrivalCount
        try expectValue(await deliverAndSettle(
            .turnCompleted(threadId: "ws4", turnId: failTurn, outcome: .failed, errorMessage: "boom"),
            expectingSignal: true), "the failure must publish a signal")
        _ = await waitUntil(timeout: 1, pollInterval: 0.02) { false }
        record("G-watched-failure")
        try expect(supervisor.qaWatchedTerminalArrivalCount == watchedBeforeFailure + 1,
                   "POSITIVE CONTROL: the failure really was judged watched — the assertions below are about what it then did")
        // The DECISION itself, as the production supervisor computed it for this
        // arrival. Asserted directly because the app is now its only consumer:
        // if the failure branch of the table ever says "clear and acknowledge",
        // that is the collapse this contract forbids, whether or not a downstream
        // guard happens to catch it.
        guard let failureDecision = supervisor.qaLastArrivalDecision else {
            throw CheckError(description: "the failure arrival recorded no decision")
        }
        try expect(failureDecision.advancesReadWatermark,
                   "a watched failure was still watched, so it is read")
        try expect(!failureDecision.clearsLiveSignal,
                   "the decision for a watched FAILURE must not clear the live signal — \(failureDecision)")
        try expect(!failureDecision.acknowledgesVisually,
                   "the decision for a watched FAILURE must not acknowledge visually — \(failureDecision)")
        try expect(delegate.agentSignalCenter.currentByTile[tileId]?.kind == .failed,
                   "a watched failure must KEEP its live signal — got \(String(describing: delegate.agentSignalCenter.currentByTile[tileId]?.kind))")
        try expect(delegate.qaCompletionAcknowledgmentCount == acksBeforeFailure,
                   "a failure must never play the success acknowledgment")
        try expect(tileView.qaAcknowledgmentPhase != .acknowledging,
                   "a failure must not leave a success glow running")
        try expect(tileView.qaAwarenessSignal?.kind == .failed,
                   "the badge must say Failed — got \(String(describing: tileView.qaAwarenessSignal?.kind))")

        // Action required outranks everything and survives the automatic
        // acknowledgment path: a later success may neither displace it nor clear it.
        let requestId = "req-\(UUID().uuidString)"
        try expectValue(await deliverAndSettle(
            .userInputRequested(threadId: "ws4", requestId: requestId,
                                questions: [.init(key: "choice", prompt: "Choose")]),
            expectingSignal: true), "the request must publish a signal")
        try expect(delegate.agentSignalCenter.currentByTile[tileId]?.kind == .actionRequired,
                   "an open request must own the tile's attention")
        let ackTurn = nextTurn()
        try expectValue(await deliverAndSettle(
            .turnStarted(threadId: "ws4", turnId: ackTurn), expectingSignal: false), "post-request turnStarted")
        let acksBeforeSupersession = delegate.qaCompletionAcknowledgmentCount
        try expectValue(await deliverAndSettle(
            .turnCompleted(threadId: "ws4", turnId: ackTurn, outcome: .completed, errorMessage: nil),
            expectingSignal: true), "the completion behind the request must publish a signal")
        _ = await waitUntil(timeout: 1, pollInterval: 0.02) { false }
        record("G-completion-behind-action-required")
        try expect(delegate.agentSignalCenter.currentByTile[tileId]?.kind == .actionRequired,
                   "a completion must not clear or displace an open action request — got \(String(describing: delegate.agentSignalCenter.currentByTile[tileId]?.kind))")
        try expect(delegate.qaCompletionAcknowledgmentCount == acksBeforeSupersession,
                   "no success acknowledgment may play over an action request")
        // Resolve it so the fixture leaves no attention behind.
        _ = await deliverAndSettle(
            .requestResolved(threadId: "ws4", requestId: requestId, decision: "ok"), expectingSignal: false)

        // =====================================================================
        // H · EVERY FACT IS LOAD-BEARING, driven through real state rather than
        //     asserted about the struct. Each of these leaves the focus scope and
        //     responder exactly where a watched completion needs them, changes
        //     ONE real thing, and requires the completion to stay unread.
        // =====================================================================
        func expectUnreadArrival(_ label: String) async throws {
            // NON-VACUITY: the agent must be READ going in, or "it stayed unread"
            // would be true for reasons that have nothing to do with the facts.
            // Every caller earns that with a deliberate visit before changing the
            // one fact it is about to test.
            try expect(supervisor.records[agentId]?.isUnread == false,
                       "setup(\(label)): the agent must start read, or the assertion below is vacuous")
            let t = nextTurn()
            _ = await deliverAndSettle(.turnStarted(threadId: "ws4", turnId: t), expectingSignal: false)
            let watchedBefore = supervisor.qaWatchedTerminalArrivalCount
            let arrivalsBefore = supervisor.qaTerminalArrivalCount
            _ = await deliverAndSettle(
                .turnCompleted(threadId: "ws4", turnId: t, outcome: .completed, errorMessage: nil),
                expectingSignal: true)
            record("H-\(label)")
            try expect(supervisor.qaTerminalArrivalCount == arrivalsBefore + 1,
                       "POSITIVE CONTROL(\(label)): the completion really was delivered")
            try expect(supervisor.qaWatchedTerminalArrivalCount == watchedBefore,
                       "\(label): the completion must NOT be judged watched — facts said \(String(describing: supervisor.qaLastArrivalFacts?.blockingReasons))")
            try expect(supervisor.records[agentId]?.isUnread == true,
                       "\(label): the completion must stay unread")
        }

        // H1 · the app resigned. THE REAL delegate method, the real notification.
        try focusTileDeliberately()
        delegate.applicationDidResignActive(
            Notification(name: NSApplication.didResignActiveNotification, object: NSApplication.shared))
        try expect(!delegate.applicationIsActiveForAwareness,
                   "setup: the real resign callback must turn awareness off")
        try await expectUnreadArrival("app-resigned")
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared))

        // H2 · the window is occluded (covered, hidden, or on another Space).
        try focusTileDeliberately()
        windowIsUnoccluded = false
        try await expectUnreadArrival("window-occluded")
        windowIsUnoccluded = true

        // H3 · a real modal window is up.
        try focusTileDeliberately()
        let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        modal.orderFrontOffscreenForChecks()
        let modalSession = NSApplication.shared.beginModalSession(for: modal)
        try expect(NSApplication.shared.modalWindow != nil, "setup: a real modal window must be up")
        try await expectUnreadArrival("modal-presented")
        NSApplication.shared.endModalSession(modalSession)
        modal.orderOut(nil)

        // H4 · the RESPONDER alone leaves the tile. The broker's scope is still the
        // tile, so this isolates the responder fact from the scope fact — without
        // it, one of the two could be dropped and the pair would still refuse.
        try focusTileDeliberately()
        window.makeFirstResponder(canvas)
        try expect(!responderIsInTile(), "setup: the responder must have left the tile")
        try expect(delegate.focusBroker.activeSurface == .tile(tileId),
                   "setup: the broker scope must still be the tile, or this is not isolating the responder")
        try await expectUnreadArrival("responder-outside-tile")

        // H4b · the SCOPE alone leaves the tile. `acceptExistingFocus` moves the
        // broker's scope without touching the responder, which is the mirror of H4.
        try focusTileDeliberately()
        delegate.focusBroker.acceptExistingFocus(.canvas, reason: .userClick)
        try expect(responderIsInTile(),
                   "setup: the responder must still be in the tile, or this is not isolating the scope")
        try expect(delegate.focusBroker.activeSurface != .tile(tileId),
                   "setup: the broker scope must have left the tile")
        try await expectUnreadArrival("focus-scope-elsewhere")

        // H4c · both, which is the ordinary "you clicked somewhere else" shape.
        try focusTileDeliberately()
        delegate.focusBroker.recoverToCanvas(reason: .userClick)
        window.makeFirstResponder(canvas)
        try await expectUnreadArrival("focus-elsewhere")

        // H5 · the window is not on screen at all.
        try focusTileDeliberately()
        window.orderOut(nil)
        try expect(!window.isVisible, "setup: the window must be off screen")
        try await expectUnreadArrival("window-not-visible")
        window.orderFrontOffscreenForChecks()

        // H6 · the tile is not mounted at all.
        try focusTileDeliberately()
        canvas.removeTile(id: tileId)
        try expect(canvas.tileView(for: tileId) == nil, "setup: the tile must be unmounted")
        try await expectUnreadArrival("tile-unmounted")
        try expect(!tileView.qaAcknowledgmentHasScheduledWork,
                   "an unmounted tile must leave no acknowledgment timer behind")

        // --- artifact --------------------------------------------------------
        let dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: ""), isDirectory: true)
            .appendingPathComponent("completion-awareness", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "completion-awareness",
            "tileId": tileId.uuidString,
            "agentId": agentId.rawValue.uuidString,
            "terminalArrivals": supervisor.qaTerminalArrivalCount,
            "watchedArrivals": supervisor.qaWatchedTerminalArrivalCount,
            "acknowledgmentsPlayed": delegate.qaCompletionAcknowledgmentCount,
            "acknowledgmentsStarted": tileView.qaAcknowledgmentsStarted,
            "acknowledgmentsFinished": tileView.qaAcknowledgmentsFinished,
            "nonDeliberateFocusRefusals": delegate.qaNonDeliberateFocusCount,
            "pulseSeconds": pulseElapsed,
            "staticSeconds": staticElapsed,
            "rows": rows,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        return artifact
    }
}
