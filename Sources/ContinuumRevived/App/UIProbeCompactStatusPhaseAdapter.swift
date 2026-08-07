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
        try require(context.state == .stale && context.fraction == 0.5 && context.label == "stale 50%",
                    "stale context arithmetic must pass through unchanged")
        try require(AgentRadialContextMeterPresenter.present(
            AgentContextWindowSnapshot(
                usedTokens: 90,
                maxTokens: 100,
                observedAt: t1,
                source: .providerSessionStats,
                freshness: .live)).state == .known,
                    "production warning thresholds remain disabled by default")

        return assertions
    }
}
