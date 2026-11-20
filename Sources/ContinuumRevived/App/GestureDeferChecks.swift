import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

/// `--gesture-defer-check`: does `FrameGovernor` keep non-visual main-thread work
/// out of a camera gesture, without losing or reordering anything?
///
/// It builds the motion probe's real scene (`CanvasMotionWorkload`: the production
/// boot mount, N agents streaming through the real runner -> supervisor -> tile
/// path) in an OFF-SCREEN window that is never activated, then drives a real pan
/// through the production scroll responder at 120 Hz. A heartbeat on the main queue
/// counts the 8.33 ms slots the main thread missed.
///
/// One process is one arm: `GESTURE_DEFER=off` disables the governor (the
/// pre-governor behaviour), anything else leaves it on. `scripts/gesture-defer-ab.sh`
/// runs both arms and compares them. Witnesses of the ON arm:
///
/// 1. the camera really moved and the governor saw a gesture (positive control);
/// 2. work was deferred during motion and the supervisor ran fewer ingests than
///    the source emitted (the cost really left the gesture);
/// 3. visible agents kept streaming (tiles applied events during motion);
/// 4. the backlog drained after the settle, and every agent's streamed text holds
///    every chunk in order (`motion-stream-` markers 7, 15, 23, ... consecutive)
///    and its final marker: nothing lost, nothing reordered.
///
/// The OFF arm must defer nothing (anti-teeth: the ON assertions are not vacuous).
@MainActor
enum GestureDeferChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Grid heartbeat: a tick every 1/hz on the main queue; a gap of n slots is n-1 missed.
    @MainActor
    private final class Heartbeat {
        let slot: Double
        private var source: DispatchSourceTimer?
        private var last: Double?
        private(set) var ticks = 0
        private(set) var missed = 0
        private(set) var longestGapMs = 0.0
        private var gaps: [Double] = []
        init(hz: Double) { slot = 1 / hz }
        func start() {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: slot, leeway: .microseconds(100))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.resume()
            source = timer
        }
        private func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            defer { last = now }
            ticks += 1
            guard let last else { return }
            let gap = now - last
            gaps.append(gap * 1_000)
            longestGapMs = max(longestGapMs, gap * 1_000)
            let slots = Int((gap / slot).rounded())
            if slots > 1 { missed += slots - 1 }
        }
        func stop() { source?.cancel(); source = nil }
        var summary: [String: Any] {
            let total = ticks + missed
            let sorted = gaps.sorted()
            func p(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
            return ["ticks": ticks, "missedSlots": missed, "slots": total,
                    "missedPercent": total > 0 ? 100 * Double(missed) / Double(total) : 0,
                    "gapMsP50": p(0.5), "gapMsP95": p(0.95), "gapMsP99": p(0.99), "gapMsMax": longestGapMs]
        }
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["CONTINUUM_PROJECT_ROOT"], let supportPath = env["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "requires isolated CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT")
        }
        let on = env["GESTURE_DEFER"] != "off"
        let agents = max(4, Int(env["GESTURE_DEFER_AGENTS"] ?? "") ?? 12)
        let motionSeconds = Double(env["GESTURE_DEFER_SECONDS"] ?? "") ?? 6
        let phase = env["GESTURE_DEFER_PHASE"] ?? "pan"
        let hz = 120.0
        let governor = FrameGovernor.shared
        governor.qaReset()
        governor.isEnabled = on

        let fixture = try CanvasMotionWorkload(root: URL(fileURLWithPath: rootPath),
            support: URL(fileURLWithPath: supportPath), markdownCount: 12, agentCount: agents, offscreen: true)
        defer { fixture.close() }
        let canvas = fixture.canvas
        governor.adopt(canvas: canvas)
        governor.isEnabled = on
        ManagedAgentTileNSView.qaStatusTickDeferEnabled = env["GESTURE_QUIET_TICK"] != "off"
        await spin(Double(env["GESTURE_DEFER_WARMUP"] ?? "") ?? 4)

        // Agents stream for the whole run: a lead of 1.5 s, the motion, the settle.
        let deltaMs = max(5, Int(env["CANVAS_MOTION_DELTA_MS"] ?? "") ?? 50)
        let tickLimit = Int((motionSeconds + 2) * 1_000 / Double(deltaMs))
        fixture.startStreaming(delay: 0, tickLimit: tickLimit)
        await spin(1.5)

        let beat = Heartbeat(hz: hz)
        beat.start()
        let ingestBefore = fixture.qaSupervisorIngestCount
        let tileBefore = ManagedAgentTileNSView.qaTailEventsApplied
        let deferredBefore = governor.qaDeferredCount
        let ticksBefore = fixture.qaSourceTicks
        let statusRunsBefore = ManagedAgentTileNSView.qaStatusTickRuns
        let statusDeferredBefore = ManagedAgentTileNSView.qaStatusTickDeferred
        var motionSamples = 0, motionSeen = 0

        // The scripted gesture: 120 Hz scroll inputs on a background clock, applied
        // through the production responder on main.
        let count = Int(motionSeconds * hz)
        let omega = 2 * Double.pi / 3
        var index = 0
        let started = ProcessInfo.processInfo.systemUptime
        while index < count {
            let due = started + Double(index) / hz
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let t = Double(index) / hz, previous = Double(max(0, index - 1)) / hz
            if phase != "zoom" {
                fixture.postPan(dx: 100 * (sin(omega * t) - sin(omega * previous)),
                                dy: 60 * (cos(omega * t) - cos(omega * previous)))
            }
            if phase != "pan" { fixture.postMagnify(delta: exp(0.4 * (sin(omega * t) - sin(omega * previous))) - 1) }
            motionSamples += 1
            if canvas.isCameraInMotion { motionSeen += 1 }
            index += 1
        }
        let ingestAtEnd = fixture.qaSupervisorIngestCount
        let tileAtEnd = ManagedAgentTileNSView.qaTailEventsApplied
        let deferredAtEnd = governor.qaDeferredCount
        let ticksAtEnd = fixture.qaSourceTicks
        let statusRuns = ManagedAgentTileNSView.qaStatusTickRuns - statusRunsBefore
        let statusDeferred = ManagedAgentTileNSView.qaStatusTickDeferred - statusDeferredBefore
        let pendingAtEnd = governor.qaHasPending
        let motionBeat = beat.summary

        // The settle: the backlog must drain by itself.
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 5
        while governor.qaHasPending, ProcessInfo.processInfo.systemUptime < drainDeadline { await spin(0.05) }
        let drained = !governor.qaHasPending
        beat.stop()

        fixture.stopStreaming()
        let finalDeadline = ProcessInfo.processInfo.systemUptime + 60
        while !fixture.hasDeliveredStreamingSource, ProcessInfo.processInfo.systemUptime < finalDeadline { await spin(0.1) }
        let delivered = fixture.hasDeliveredStreamingSource

        // Ordered delivery: every agent's markers are consecutive from the first.
        var orderErrors: [String] = []
        var markerCounts: [Int] = []
        for (position, text) in fixture.streamedAssistantTexts().enumerated() {
            var markers: [Int] = []
            var rest = Substring(text)
            while let range = rest.range(of: "motion-stream-") {
                let digits = rest[range.upperBound...].prefix(while: { $0.isNumber })
                if let value = Int(digits) { markers.append(value) }
                rest = rest[range.upperBound...]
            }
            markerCounts.append(markers.count)
            for (i, marker) in markers.enumerated() where marker != 7 + 8 * i {
                orderErrors.append("agent \(position): marker \(i) is \(marker), expected \(7 + 8 * i)")
                break
            }
            if markers.isEmpty { orderErrors.append("agent \(position): no streamed markers") }
        }

        let produced = fixture.qaSourceTicks
        let result: [String: Any] = [
            "arm": on ? "on" : "off", "agents": agents, "phase": phase, "motionSeconds": motionSeconds,
            "gestureSamples": motionSamples, "gestureSeenByCanvas": motionSeen,
            "supervisorIngestsDuringMotion": ingestAtEnd - ingestBefore,
            "tileEventsAppliedDuringMotion": tileAtEnd - tileBefore,
            "sourceTicksDuringMotion": ticksAtEnd - ticksBefore, "sourceTicksTotal": produced,
            "deferredDuringMotion": deferredAtEnd - deferredBefore,
            "statusTickRunsDuringMotion": statusRuns, "statusTickDeferredDuringMotion": statusDeferred,
            "statusTickDeferEnabled": ManagedAgentTileNSView.qaStatusTickDeferEnabled,
            "pendingAtMotionEnd": pendingAtEnd, "drainedAfterSettle": drained,
            "drains": governor.qaDrainCount, "drainedItems": governor.qaDrainedCount,
            "streamDelivered": delivered, "orderErrors": orderErrors, "markersPerAgent": markerCounts,
            "motionHeartbeat": motionBeat, "wholeRunHeartbeat": beat.summary,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let out = env["GESTURE_DEFER_OUTPUT"] { try data.write(to: URL(fileURLWithPath: out)) }
        print("[gesture-defer] " + String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\n", with: " "))

        // Witnesses.
        guard motionSeen >= motionSamples / 2 else {
            throw Failure(description: "positive control: the canvas reported motion for \(motionSeen) of \(motionSamples) inputs; the gesture did not drive the camera")
        }
        guard ingestAtEnd - ingestBefore > 0 || !on else {
            throw Failure(description: "positive control: no event reached the supervisor during motion")
        }
        guard drained, delivered, orderErrors.isEmpty else {
            throw Failure(description: "delivery: drained=\(drained) delivered=\(delivered) order=\(orderErrors.prefix(3))")
        }
        if env["GESTURE_QUIET_TICK"] == "off" {
            guard statusDeferred == 0 else { throw Failure(description: "anti-teeth: legacy tick deferred \(statusDeferred)") }
        } else if on {
            // Tiles tick at 1 Hz while working; during a gesture none may run.
            guard statusRuns == 0 else {
                throw Failure(description: "status tick ran \(statusRuns) times during a \(motionSeconds)s gesture (deferred \(statusDeferred))")
            }
        }
        if on {
            guard deferredAtEnd - deferredBefore > 0 else {
                throw Failure(description: "no work was deferred during a \(motionSeconds)s gesture with \(agents) streaming agents")
            }
            guard tileAtEnd - tileBefore > 0 else {
                throw Failure(description: "visible agents did not stream during motion (0 tile events applied)")
            }
            guard (ingestAtEnd - ingestBefore) < (ticksAtEnd - ticksBefore) * agents else {
                throw Failure(description: "supervisor ingests during motion (\(ingestAtEnd - ingestBefore)) did not drop below the \((ticksAtEnd - ticksBefore) * agents) events the source emitted")
            }
        } else {
            guard deferredAtEnd - deferredBefore == 0 else {
                throw Failure(description: "anti-teeth: the OFF arm deferred \(deferredAtEnd - deferredBefore) items")
            }
        }
    }
}
