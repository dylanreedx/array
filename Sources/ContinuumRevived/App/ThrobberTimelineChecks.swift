import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation
import QuartzCore

/// The agent throbber's timeline: it must not restart, and two agents must not
/// beat in unison.
///
/// **The reported defect.** In the sidebar the gyro "resets the spinning loop",
/// including on plain hover. The cause was that `layout()` dropped every
/// compositor animation and rebuilt it from phase 0, and the sidebar lays a
/// working row out constantly — once a second to re-tick its duration word, and
/// again whenever the card's hover state changes. Phase lived in the keyframe
/// TABLE (samples started at `currentSnapshotPhase`), so "rebuild" and "restart"
/// were the same operation.
///
/// Phase now lives in `beginTime`, derived from the wall clock, so a rebuild
/// lands on the phase the old animation was already showing. That also makes a
/// per-instance stagger free: an offset is just a constant added to the clock.
///
/// **What this witness is careful about.** Asserting "the animation is still
/// installed" after a layout pass is satisfied by a restart — the old code would
/// have passed it. This reads the phase back off the `CAAnimation` the layer is
/// actually holding, sampled at a FIXED media time, so a restart moves it and is
/// caught. The rebuild counter is the second half: it separates "layout left the
/// motion alone" from "layout rebuilt it and the rebuild was seamless", which are
/// different costs and different bugs.
@MainActor
enum ThrobberTimelineChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    /// Distance between two phases on a circle — 0.99 and 0.01 are close.
    private static func phaseDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let raw = abs(a - b)
        return min(raw, 1 - raw)
    }

    /// Where the shared wall clock says an indicator with `offset` should be at
    /// `time`. This is the contract the fix rests on — phase is a function of the
    /// clock and the offset, never of when the animation happened to be installed —
    /// and asserting it is what makes the witness independent of how fast the check
    /// itself runs. Comparing two readings to each other is not enough: a restart
    /// moves the phase by only the elapsed time, and a check that starts and
    /// relayouts within a millisecond barely moves at all.
    private static func wallClockPhase(_ time: CFTimeInterval, offset: CGFloat,
                                       duration: CFTimeInterval) -> CGFloat {
        var phase = (CGFloat(time / duration) + offset).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        return phase
    }

    private struct Fixture {
        let window: NSWindow
        let host: NSView
        let indicator: DualPlaneGyroTiltedThinkingIndicatorView
    }

    /// A real window, because `canAnimate` requires one; parked off every display,
    /// because a check is not a show (`CheckFixtureWindow`).
    private static func makeFixture(phaseOffset: CGFloat) -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        let indicator = DualPlaneGyroTiltedThinkingIndicatorView(reducedMotion: false)
        indicator.translatesAutoresizingMaskIntoConstraints = true
        indicator.frame = NSRect(x: 10, y: 10, width: 18, height: 18)
        host.addSubview(indicator)
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        window.layoutIfNeeded()
        indicator.setPhaseOffset(phaseOffset)
        return Fixture(window: window, host: host, indicator: indicator)
    }

    static func run() throws {
        try checkLayoutDoesNotRestartTheMotion()
        try checkStaggeredAgentsShowDifferentPhases()
        try checkTheSidebarOffsetIsStableAndSpread()
        try checkTheSidebarCellHandsItsRowsOffsetToTheGyro()
        print("ThrobberTimelineChecks: a layout pass neither resampled nor restarted the gyro, "
              + "a geometry change resampled it seamlessly, and each agent rides its own phase in "
              + "both its sidebar row and its own tile")
    }

    /// The reported defect, plus the resample that is genuinely necessary.
    private static func checkLayoutDoesNotRestartTheMotion() throws {
        let fixture = makeFixture(phaseOffset: 0.25)
        defer { fixture.window.orderOut(nil) }
        let indicator = fixture.indicator

        indicator.startAnimating()
        indicator.layoutSubtreeIfNeeded()

        // CONTROL. Everything below is vacuous unless motion is genuinely installed:
        // three nodes x four keyframe animations.
        try expect(indicator.qaActiveAnimationCount == 12,
                   "control: the fixture must be animating, got "
                   + "\(indicator.qaActiveAnimationCount) of 12 animations")
        let rebuildsAtStart = indicator.qaAnimationRebuilds
        try expect(rebuildsAtStart == 1,
                   "control: starting must install exactly one keyframe table, got \(rebuildsAtStart)")

        // A fixed point in the future. Sampling the SAME media time before and
        // after is what makes a restart visible: a restart moves the animation's
        // `beginTime`, so the phase it will show at that instant changes.
        let sample = CACurrentMediaTime() + 1_000
        guard let before = indicator.qaPresentedPhase(at: sample) else {
            throw Failure(message: "control: no installed animation to read a phase from")
        }
        func expectOnTheClock(_ phase: CGFloat, _ when: String) throws {
            let expected = wallClockPhase(sample, offset: indicator.qaPhaseOffset,
                                          duration: indicator.qaMasterDuration)
            try expect(phaseDistance(phase, expected) < 1e-4,
                       "\(when): the installed animation must present the wall-clock phase "
                       + "\(expected) at the sample instant, not \(phase) — a phase that depends "
                       + "on WHEN the animation was installed is a restart waiting to happen")
        }
        try expectOnTheClock(before, "at start")

        for _ in 0..<6 {
            indicator.needsLayout = true
            indicator.layoutSubtreeIfNeeded()
        }

        try expect(indicator.qaAnimationRebuilds == rebuildsAtStart,
                   "a layout pass that did not change the geometry must not resample the "
                   + "keyframes; rebuilds went \(rebuildsAtStart) -> \(indicator.qaAnimationRebuilds)")
        guard let afterLayout = indicator.qaPresentedPhase(at: sample) else {
            throw Failure(message: "the layout pass dropped the animation entirely")
        }
        try expect(phaseDistance(before, afterLayout) < 1e-6,
                   "THE reported defect: a layout pass restarted the cycle — phase at the sample "
                   + "instant moved \(before) -> \(afterLayout)")
        try expectOnTheClock(afterLayout, "after six layout passes")

        // Now change the geometry. This MUST resample (the keyframe values are
        // absolute positions, so they are only valid for the bounds they were
        // sampled from) — and it is also the positive control for the assertion
        // above, proving `layoutSubtreeIfNeeded` genuinely reaches `layout()`
        // rather than quietly doing nothing.
        indicator.setFrameSize(NSSize(width: 24, height: 24))
        indicator.layoutSubtreeIfNeeded()
        try expect(indicator.qaAnimationRebuilds == rebuildsAtStart + 1,
                   "control: a geometry change must resample exactly once — without this the "
                   + "no-resample assertion above is satisfied by layout() never running; "
                   + "rebuilds are \(indicator.qaAnimationRebuilds)")
        guard let afterResize = indicator.qaPresentedPhase(at: sample) else {
            throw Failure(message: "the resize dropped the animation entirely")
        }
        try expectOnTheClock(afterResize, "after a geometry-driven resample")
    }

    /// Two working agents must not show the same pose.
    private static func checkStaggeredAgentsShowDifferentPhases() throws {
        let a = makeFixture(phaseOffset: 0)
        let b = makeFixture(phaseOffset: 0.5)
        let c = makeFixture(phaseOffset: 0.5)
        defer {
            a.window.orderOut(nil)
            b.window.orderOut(nil)
            c.window.orderOut(nil)
        }
        for fixture in [a, b, c] {
            fixture.indicator.startAnimating()
            fixture.indicator.layoutSubtreeIfNeeded()
        }

        let sample = CACurrentMediaTime() + 1_000
        guard let phaseA = a.indicator.qaPresentedPhase(at: sample),
              let phaseB = b.indicator.qaPresentedPhase(at: sample),
              let phaseC = c.indicator.qaPresentedPhase(at: sample) else {
            throw Failure(message: "control: all three fixtures must be animating")
        }

        try expect(phaseDistance(phaseA, phaseB) > 0.45,
                   "a half-cycle offset must put two agents on opposite sides of the cycle; "
                   + "phases \(phaseA) and \(phaseB) are \(phaseDistance(phaseA, phaseB)) apart")
        // The difference must come from the OFFSET and nothing else: two indicators
        // given the same offset stay together, however far apart they were created.
        try expect(phaseDistance(phaseB, phaseC) < 1e-4,
                   "two indicators with the same offset must ride the same phase; "
                   + "\(phaseB) vs \(phaseC)")
    }

    /// The sidebar's offset source. Stable across recycling, and spread.
    private static func checkTheSidebarOffsetIsStableAndSpread() throws {
        func id(_ index: Int) -> UUID {
            var bytes = [UInt8](repeating: 0, count: 16)
            bytes[0] = UInt8(index & 0xFF)
            bytes[1] = UInt8((index >> 8) & 0xFF)
            bytes[15] = 0x5A
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                               bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        }

        let sample = (0..<64).map { DualPlaneGyroTiltedThinkingIndicatorView.phaseOffset(for: id($0)) }
        try expect(sample.allSatisfy { $0 >= 0 && $0 < 1 },
                   "every offset must be a phase in [0, 1)")
        // Stability is the whole reason this is a hash and not a counter: a row
        // that scrolls away and comes back must land where it left.
        try expect(sample == (0..<64).map { DualPlaneGyroTiltedThinkingIndicatorView.phaseOffset(for: id($0)) },
                   "the offset must be a pure function of the agent id")
        try expect(Set(sample).count >= 60,
                   "64 agents must not collide onto a handful of phases; got "
                   + "\(Set(sample).count) distinct offsets")
        let deciles = Set(sample.map { Int(($0 * 10).rounded(.down)) })
        try expect(deciles.count >= 8,
                   "the offsets must spread over the cycle rather than cluster; \(deciles.count) "
                   + "of 10 deciles occupied")
    }

    /// The wiring. Two working rows in the real cell must end up on two phases.
    private static func checkTheSidebarCellHandsItsRowsOffsetToTheGyro() throws {
        func makeCell() -> AgentInbox96CellView {
            AgentInbox96CellView(
                proposal: .a,
                anatomy: SidebarRowAnatomy(
                    id: "live", label: "live", border: .none,
                    iconPlacement: .leading, showsModelText: false),
                prefersReducedMotion: { false })
        }
        func apply(_ cell: AgentInbox96CellView, id: UUID, state: InboxState) {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            cell.apply(
                AgentInboxRow(id: id, title: "row", state: state, lifecycle: .active,
                              createdAt: now.addingTimeInterval(-30)),
                emphasis: .full, indent: 0, disclosure: .none, rollup: nil,
                isSelected: false, isInteracting: false, now: now)
        }

        let idA = UUID(uuidString: "7A000000-0000-4000-8000-000000000001")!
        let idB = UUID(uuidString: "7A000000-0000-4000-8000-000000000002")!
        let cellA = makeCell()
        let cellB = makeCell()
        apply(cellA, id: idA, state: .working)
        apply(cellB, id: idB, state: .working)

        // CONTROL. A row that is not working has no gyro at all, so the assertions
        // below would be vacuously nil-free only if the working rows really made one.
        let resting = makeCell()
        apply(resting, id: idA, state: .ready)
        try expect(resting.qaThrobberPhaseOffset == nil,
                   "control: a resting row must not carry a throbber")

        guard let offsetA = cellA.qaThrobberPhaseOffset,
              let offsetB = cellB.qaThrobberPhaseOffset else {
            throw Failure(message: "control: a working row must carry a throbber")
        }
        try expect(offsetA == DualPlaneGyroTiltedThinkingIndicatorView.phaseOffset(for: idA),
                   "the cell must hand the gyro ITS ROW's offset; got \(offsetA), expected "
                   + "\(DualPlaneGyroTiltedThinkingIndicatorView.phaseOffset(for: idA))")
        try expect(offsetA != offsetB,
                   "two working rows must not share a phase; both are \(offsetA)")

        // Recycling the cell onto a different agent has to move it, and back onto
        // the first has to return it — the cell is reused, the offset is not.
        apply(cellA, id: idB, state: .working)
        try expect(cellA.qaThrobberPhaseOffset == offsetB,
                   "a recycled cell must take on the offset of the agent it now shows")
        apply(cellA, id: idA, state: .working)
        try expect(cellA.qaThrobberPhaseOffset == offsetA,
                   "returning to an agent must return to its phase")

        // The agent's OWN tile has to agree with its sidebar row: one mapping, one
        // phase per agent, wherever that agent is drawn.
        let transcript = AgentTranscriptListView()
        try expect(transcript.qaTailThrobberPhaseOffset == 0,
                   "control: an unbound transcript tail must start at the default phase")
        transcript.bindToolDetailAgent(AgentID(rawValue: idA))
        try expect(transcript.qaTailThrobberPhaseOffset == offsetA,
                   "an agent tile's tail gyro must ride the same phase as that agent's sidebar "
                   + "row; got \(transcript.qaTailThrobberPhaseOffset), expected \(offsetA)")
    }
}
