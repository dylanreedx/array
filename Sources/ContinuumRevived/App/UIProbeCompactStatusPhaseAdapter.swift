import ContinuumRevivedCore
import Foundation

/// Deterministic production-like checks for the live status-phase adapter.
/// These exercise the compiled Canvas seam without composing or animating a
/// tile. They are intentionally separate from the broader geometry assertions.
extension UIProbeGeometry {
    @MainActor
    static func runCompactStatusPhaseAdapterChecks() throws -> Int {
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw GeometryError(message: "compact-status-phase-adapter: \(message())")
            }
            assertions += 1
        }

        let t0 = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let t1 = t0.addingTimeInterval(10)
        let t2 = t1.addingTimeInterval(10)
        let t3 = t2.addingTimeInterval(10)
        let location = URL(fileURLWithPath: "/tmp/continuum-status-phase/src/Agent.swift")

        // Missing facts are unknown, not a fabricated Thinking phase/anchor.
        var adapter = AgentCompactStatusPhaseAdapter()
        let unknown = adapter.update(.init(), now: t0)
        try require(unknown.phase == nil && unknown.phaseStartedAt == nil,
                    "no runtime facts must remain unknown")
        try require(unknown.activityInput == nil,
                    "unknown phase must not create a precise activity input")

        // Every supported explicit phase has a deterministic source fact. The
        // table deliberately excludes session-running alone, which remains
        // unknown because it does not distinguish thinking/responding/tools.
        let phaseCases: [(AgentCompactActivityPhase, AgentCompactStatusPhaseFacts)] = [
            (.thinking, .init(turn: .active(startedAt: t0, stream: .reasoning, streamStartedAt: t0))),
            (.searching, .init(currentActivity: AgentObservedActivity(
                operation: .searching, targetPath: nil, startedAt: t0, updatedAt: t0, evidenceSource: .toolEvent))),
            (.running, .init(turn: .active(startedAt: t0, stream: .commandOutput, streamStartedAt: t0))),
            (.waiting, .init(interaction: .pending(startedAt: t0))),
            (.ready, .init(session: .init(state: .ready))),
        ]
        for (expected, facts) in phaseCases {
            var phaseAdapter = AgentCompactStatusPhaseAdapter()
            let result = phaseAdapter.update(facts, now: t1)
            try require(result.phase == expected,
                        "explicit \(expected.rawValue) fact must map to \(expected.rawValue)")
        }
        var coarseRunningAdapter = AgentCompactStatusPhaseAdapter()
        let coarseRunning = coarseRunningAdapter.update(
            .init(session: .init(state: .running)), now: t1)
        try require(coarseRunning.phase == nil && coarseRunning.phaseStartedAt == nil,
                    "session running without turn/tool facts must remain unknown")
        // An active turn is the agent working even before (or without) any
        // content stream: codex never streams, and pi/claude have a pre-stream
        // gap. It must present as the generic Working (Thinking) phase anchored
        // at the turn start — NOT a degraded unknown that renders as a stuck
        // "Waiting" (the codex "Waiting 0s / unknown" regression).
        var activeWithoutStreamAdapter = AgentCompactStatusPhaseAdapter()
        let activeWithoutStream = activeWithoutStreamAdapter.update(
            .init(turn: .active(startedAt: t0, stream: nil, streamStartedAt: nil)), now: t1)
        try require(activeWithoutStream.phase == .thinking && activeWithoutStream.phaseStartedAt == t0,
                    "active turn without a stream must present as Working (Thinking) anchored at the turn start, not unknown")
        try require(activeWithoutStream.activityInput != nil,
                    "active turn without a stream must produce a Working activity input, not nil")
        // A later precise stream still overrides the coarse Working phase.
        let streamOverrides = activeWithoutStreamAdapter.update(
            .init(turn: .active(startedAt: t0, stream: .assistant, streamStartedAt: t1)), now: t1)
        try require(streamOverrides.phase == .responding,
                    "an arriving assistant stream must override the coarse active-turn Working phase")

        // Same-state updates never reset an authoritative phase anchor.
        let starting = adapter.update(
            .init(session: .init(state: .starting, startedAt: t0)), now: t1)
        try require(starting.phase == .starting && starting.phaseStartedAt == t0,
                    "session starting uses its supplied anchor")
        let startingAgain = adapter.update(
            .init(session: .init(state: .starting, startedAt: t2)), now: t3)
        try require(startingAgain.phase == .starting && startingAgain.phaseStartedAt == t0,
                    "same starting phase keeps its original anchor")

        let respondingStart = t3.addingTimeInterval(1)
        let responding = adapter.update(
            .init(turn: .active(startedAt: t3, stream: .assistant, streamStartedAt: respondingStart)), now: t3)
        try require(responding.phase == .responding && responding.phaseStartedAt == respondingStart,
                    "assistant stream maps to Responding with its stream anchor")
        let respondingAgain = adapter.update(
            .init(turn: .active(startedAt: t3, stream: .assistant, streamStartedAt: t3.addingTimeInterval(8))), now: t3.addingTimeInterval(9))
        try require(respondingAgain.phase == .responding && respondingAgain.phaseStartedAt == respondingStart,
                    "same Responding phase does not churn its anchor")

        // Tool evidence wins over a generic active turn and retains its real
        // observed start. The label is still the existing sanitized adapter
        // contract, not raw arguments.
        let readingStart = t3.addingTimeInterval(2)
        let reading = AgentObservedActivity(
            operation: .reading,
            targetPath: location,
            startedAt: readingStart,
            updatedAt: readingStart,
            evidenceSource: .toolEvent)
        let tool = adapter.update(
            .init(turn: .active(startedAt: t3, stream: nil, streamStartedAt: nil),
                  currentActivity: reading,
                  currentActivityExpiresAt: t3.addingTimeInterval(30)), now: t3.addingTimeInterval(3))
        try require(tool.phase == .reading && tool.phaseStartedAt == readingStart,
                    "current tool evidence maps to Reading with its observed anchor")
        try require(tool.activityInput?.visibleLabel == "Reading Agent.swift",
                    "tool label is bounded and safe for later composition")

        // An explicit inspection tool fact is still tool evidence. It must
        // outrank a concurrent provider stream while it is fresh, but expiry
        // must reveal the more specific live stream again.
        let inspectingStart = t3.addingTimeInterval(3)
        let inspecting = AgentObservedActivity(
            operation: .inspecting,
            targetPath: location,
            startedAt: inspectingStart,
            updatedAt: inspectingStart,
            evidenceSource: .toolEvent)
        var inspectingAdapter = AgentCompactStatusPhaseAdapter()
        let freshInspecting = inspectingAdapter.update(
            .init(
                turn: .active(startedAt: t3, stream: .assistant, streamStartedAt: t3),
                currentActivity: inspecting,
                currentActivityExpiresAt: t3.addingTimeInterval(30)),
            now: t3.addingTimeInterval(4))
        try require(freshInspecting.phase == .reading && freshInspecting.phaseStartedAt == inspectingStart,
                    "fresh inspecting tool activity must outrank an active assistant stream and map to Reading")
        let freshInspectingReasoning = inspectingAdapter.update(
            .init(
                turn: .active(startedAt: t3, stream: .reasoning, streamStartedAt: t3.addingTimeInterval(5)),
                currentActivity: inspecting,
                currentActivityExpiresAt: t3.addingTimeInterval(30)),
            now: t3.addingTimeInterval(6))
        try require(freshInspectingReasoning.phase == .reading && freshInspectingReasoning.phaseStartedAt == inspectingStart,
                    "fresh inspecting tool activity must also outrank an active reasoning stream")
        let staleInspecting = inspectingAdapter.update(
            .init(
                turn: .active(startedAt: t3, stream: .reasoning, streamStartedAt: t3.addingTimeInterval(5)),
                currentActivity: inspecting,
                currentActivityExpiresAt: t1),
            now: t2)
        try require(staleInspecting.phase == .thinking && staleInspecting.phaseStartedAt == t3.addingTimeInterval(5),
                    "stale inspecting activity must not override the current reasoning stream")

        // Completed and cancelled tool activity has terminal presentation
        // semantics when it is the current fresh fact.
        let completedActivity = AgentObservedActivity(
            operation: .completed,
            targetPath: location,
            startedAt: inspectingStart,
            updatedAt: inspectingStart,
            evidenceSource: .toolEvent)
        let cancelledStart = t3.addingTimeInterval(6)
        let cancelledActivity = AgentObservedActivity(
            operation: .interrupted,
            targetPath: location,
            startedAt: cancelledStart,
            updatedAt: cancelledStart,
            evidenceSource: .toolEvent)
        var completedActivityAdapter = AgentCompactStatusPhaseAdapter()
        let completedActivityResult = completedActivityAdapter.update(
            .init(currentActivity: completedActivity, currentActivityExpiresAt: t3.addingTimeInterval(30)),
            now: t3.addingTimeInterval(7))
        try require(completedActivityResult.phase == .ready && completedActivityResult.phaseStartedAt == nil,
                    "completed activity must map to Ready without an elapsed anchor")
        let cancelledActivityResult = completedActivityAdapter.update(
            .init(currentActivity: cancelledActivity, currentActivityExpiresAt: t3.addingTimeInterval(30)),
            now: t3.addingTimeInterval(8))
        try require(cancelledActivityResult.phase == .interrupted && cancelledActivityResult.phaseStartedAt == cancelledStart,
                    "cancelled activity must map to Interrupted with its observed anchor")

        // A fresh terminal failure/interruption still wins over contradictory
        // active assistant/reasoning streams.
        let activityFailedStart = t3.addingTimeInterval(9)
        let activityInterruptedStart = t3.addingTimeInterval(10)
        let failedActivity = AgentObservedActivity(
            operation: .failed,
            targetPath: location,
            startedAt: activityFailedStart,
            updatedAt: activityFailedStart,
            evidenceSource: .toolEvent)
        let interruptedActivity = AgentObservedActivity(
            operation: .interrupted,
            targetPath: location,
            startedAt: activityInterruptedStart,
            updatedAt: activityInterruptedStart,
            evidenceSource: .toolEvent)
        let failedWithActiveStream = completedActivityAdapter.update(
            .init(
                turn: .active(startedAt: t3, stream: .assistant, streamStartedAt: t3),
                currentActivity: failedActivity,
                currentActivityExpiresAt: t3.addingTimeInterval(30)),
            now: t3.addingTimeInterval(11))
        try require(failedWithActiveStream.phase == .failed && failedWithActiveStream.phaseStartedAt == activityFailedStart,
                    "fresh failed activity must outrank a contradictory assistant stream")
        let interruptedWithActiveStream = completedActivityAdapter.update(
            .init(
                turn: .active(startedAt: t3, stream: .reasoning, streamStartedAt: t3),
                currentActivity: interruptedActivity,
                currentActivityExpiresAt: t3.addingTimeInterval(30)),
            now: t3.addingTimeInterval(12))
        try require(interruptedWithActiveStream.phase == .interrupted && interruptedWithActiveStream.phaseStartedAt == activityInterruptedStart,
                    "fresh interrupted activity must outrank a contradictory reasoning stream")

        // A real phase change replaces the anchor, even when both phases are
        // active. No old elapsed time leaks across the transition.
        let editStart = t3.addingTimeInterval(4)
        let editing = AgentObservedActivity(
            operation: .editing,
            targetPath: location,
            startedAt: editStart,
            updatedAt: editStart,
            evidenceSource: .toolEvent)
        let changed = adapter.update(
            .init(currentActivity: editing, currentActivityExpiresAt: t3.addingTimeInterval(30)), now: t3.addingTimeInterval(5))
        try require(changed.phase == .editing && changed.phaseStartedAt == editStart,
                    "phase change replaces the phase anchor")

        // Terminal failures and interruptions are explicit and deterministic.
        let failedStart = t3.addingTimeInterval(6)
        let failed = adapter.update(
            .init(turn: .completed(outcome: .failed, phaseStartedAt: failedStart)), now: t3.addingTimeInterval(7))
        try require(failed.phase == .failed && failed.phaseStartedAt == failedStart,
                    "failed turn maps to Failed")
        let interruptedStart = t3.addingTimeInterval(8)
        let interrupted = adapter.update(
            .init(session: .init(state: .stopped, startedAt: interruptedStart)), now: t3.addingTimeInterval(9))
        try require(interrupted.phase == .interrupted && interrupted.phaseStartedAt == interruptedStart,
                    "stopped session maps to Interrupted")

        // Explicit terminal facts outrank contradictory stale tool evidence;
        // expiration must not weaken failure/interruption precedence.
        let contradictoryStaleTool = AgentObservedActivity(
            operation: .running,
            targetPath: location,
            startedAt: t0,
            updatedAt: t0,
            evidenceSource: .toolEvent)
        let failedWithStaleTool = adapter.update(
            .init(
                turn: .completed(outcome: .failed, phaseStartedAt: failedStart),
                currentActivity: contradictoryStaleTool,
                currentActivityExpiresAt: t1),
            now: t2)
        try require(failedWithStaleTool.phase == .failed && failedWithStaleTool.phaseStartedAt == failedStart,
                    "failed terminal fact must outrank stale tool activity")
        let interruptedWithStaleTool = adapter.update(
            .init(
                session: .init(state: .stopped, startedAt: interruptedStart),
                currentActivity: contradictoryStaleTool,
                currentActivityExpiresAt: t1),
            now: t2)
        try require(interruptedWithStaleTool.phase == .interrupted && interruptedWithStaleTool.phaseStartedAt == interruptedStart,
                    "interrupted terminal fact must outrank stale tool activity")

        // Receipt time is never an elapsed anchor when the runtime omitted one.
        let noTimestamp = adapter.update(
            .init(turn: .active(startedAt: nil, stream: .assistant, streamStartedAt: nil)), now: t2)
        try require(noTimestamp.phase == .responding && noTimestamp.phaseStartedAt == nil,
                    "missing stream/turn timestamps remain anchor-unknown")
        let noTimestampAgain = adapter.update(
            .init(turn: .active(startedAt: nil, stream: .assistant, streamStartedAt: nil)), now: t3)
        try require(noTimestampAgain.phaseStartedAt == nil,
                    "missing timestamps never become the caller clock")

        // Expired What is not current activity. This prevents stale location
        // context from masquerading as a live tool phase.
        let staleTool = AgentObservedActivity(
            operation: .running,
            targetPath: location,
            startedAt: t0,
            updatedAt: t0,
            evidenceSource: .toolEvent)
        let stale = adapter.update(
            .init(currentActivity: staleTool, currentActivityExpiresAt: t1), now: t2)
        try require(stale.phase == nil && stale.phaseStartedAt == nil,
                    "expired current activity must pass through as unknown")

        // Context is an independent telemetry contract: stale authoritative
        // arithmetic is retained and marked stale; it is never converted to a
        // fresh value or disabled by phase derivation.
        let staleContext = AgentContextWindowSnapshot(
            usedTokens: 50,
            maxTokens: 100,
            observedAt: t1,
            source: .providerSessionStats,
            freshness: .stale)
        let context = AgentRadialContextMeterPresenter.present(staleContext)
        // A restored reading keeps its arithmetic AND its number. Staleness is a
        // qualifier carried by the meter state and the tooltip, not a word that
        // replaces the measurement — leading the row with "stale" made a good
        // last-known value read as a failure.
        try require(context.state == .stale && context.fraction == 0.5 && context.label == "50%",
                    "stale context arithmetic must pass through unchanged and still read as a number, got \(context.label)")
        try require(context.detailText.contains("Freshness: stale"),
                    "staleness must still be disclosed in the meter tooltip, got \(context.detailText)")

        // An over-capacity reading keeps its RAW number by contract (the
        // over-capacity assertions in `--ui-geometry-check`). 237% was not a
        // display bug — the display faithfully reported a wrong denominator, and
        // that is what made it findable. The fix belongs in
        // `AgentContextOccupancy`, which no longer derives occupancy from
        // codex's cumulative session totals.
        // 90 of 100 is exactly the shipped critical line, and production now
        // promotes it. This assertion used to demand `.known` — it pinned the
        // silence that let a 348% ring render calm and green.
        try require(AgentRadialContextMeterPresenter.present(
            AgentContextWindowSnapshot(
                usedTokens: 90,
                maxTokens: 100,
                observedAt: t1,
                source: .providerSessionStats,
                freshness: .live)).state == .critical,
                    "production must promote a 90% occupancy to critical")

        // A ready session with no active turn is IDLE, and idle outranks a tool
        // observation that has not yet expired. This is the stale-status defect:
        // after a turn finished, an unexpired `what` used to win here and the row
        // kept asserting Running/Reading/Waiting for a stopped agent.
        var idleAdapter = AgentCompactStatusPhaseAdapter()
        let unexpiredTool = AgentObservedActivity(
            operation: .running,
            targetPath: location,
            startedAt: t0,
            updatedAt: t0,
            evidenceSource: .toolEvent)
        let idleOverStaleTool = idleAdapter.update(
            .init(
                session: .init(state: .ready, startedAt: t0),
                turn: nil,
                currentActivity: unexpiredTool,
                currentActivityExpiresAt: t3),
            now: t1)
        try require(idleOverStaleTool.phase == .ready && idleOverStaleTool.phaseStartedAt == nil,
                    "a ready session with no active turn must resolve idle even while a tool observation is unexpired, got \(String(describing: idleOverStaleTool.phase))")

        // The same unexpired observation still wins while the session is running,
        // so idle authority did not blind the live case.
        var runningAdapter = AgentCompactStatusPhaseAdapter()
        let liveTool = runningAdapter.update(
            .init(
                session: .init(state: .running, startedAt: t0),
                turn: .active(startedAt: t0, stream: nil, streamStartedAt: nil),
                currentActivity: unexpiredTool,
                currentActivityExpiresAt: t3),
            now: t1)
        try require(liveTool.phase == .running,
                    "a live turn must still surface its current tool observation, got \(String(describing: liveTool.phase))")

        let fixtureRoot = URL(fileURLWithPath: "/tmp/continuum-status-phase", isDirectory: true)
        let idleLocationFixture = AgentLocationSnapshot(
            home: AgentHome(projectId: nil, projectRoot: fixtureRoot, checkoutRoot: fixtureRoot),
            whereDirectory: fixtureRoot)

        // Idle renders as SILENCE, not a "Ready" chip: no label, no elapsed, no
        // icon, nothing spoken.
        let idleActivity = AgentCompactStatusPresentation.present(
            location: idleLocationFixture,
            activity: AgentCompactActivityInput(phase: .ready, phaseStartedAt: nil),
            now: t1,
            contextWindow: nil).activity
        try require(idleActivity.isSilent
                    && idleActivity.text.isEmpty
                    && idleActivity.elapsedText == nil
                    && idleActivity.symbolName.isEmpty
                    && idleActivity.accessibilityLabel.isEmpty
                    && !idleActivity.showsThinkingIndicator,
                    "an idle phase must render silent, got text \"\(idleActivity.text)\" symbol \"\(idleActivity.symbolName)\"")

        // A live phase is the opposite: it speaks, and its elapsed reading is a
        // function of `now`, so a repaint at a later instant advances it. This is
        // what the tile's tick exists to drive.
        let liveInput = AgentCompactActivityInput(phase: .thinking, phaseStartedAt: t0)
        func liveElapsed(at instant: Date) -> String? {
            AgentCompactStatusPresentation.present(
                location: idleLocationFixture,
                activity: liveInput,
                now: instant,
                contextWindow: nil).activity.elapsedText
        }
        let earlyElapsed = liveElapsed(at: t1)
        let laterElapsed = liveElapsed(at: t3)
        try require(earlyElapsed != nil && laterElapsed != nil && earlyElapsed != laterElapsed,
                    "a live phase's elapsed reading must advance with the clock, got \(String(describing: earlyElapsed)) then \(String(describing: laterElapsed))")

        return assertions
    }
}
