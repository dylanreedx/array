import AppKit
import ContinuumRevivedCore
import Foundation

/// `--idle-frames-check`: what does the main thread do while the camera rests
/// and agents stream? The motion probe's real scene (`CanvasMotionWorkload`, the
/// production boot mount, N agents through the real runner -> supervisor -> tile
/// path) in an OFF-SCREEN window, no input at all. A 120 Hz heartbeat on the
/// main queue counts missed slots, and the per-cause counters read at every
/// beat name what ran inside each long gap.
///
/// Knobs: IDLE_FRAMES_AGENTS (24), IDLE_FRAMES_STREAMING (12), IDLE_FRAMES_SECONDS
/// (12), IDLE_FRAMES_OUTPUT (JSON path).
@MainActor
enum IdleFramesChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func counters() -> [String: Double] {
        ["statusTicks": Double(ManagedAgentTileNSView.qaStatusTickRuns),
         "parkedStatusTicks": Double(ManagedAgentTileNSView.qaParkedStatusTickRuns),
         "statusTickMs": ManagedAgentTileNSView.qaStatusTickSeconds * 1_000,
         "transcriptApplies": Double(AgentTranscriptUpdateScheduler.qaTotalVisualApplies),
         "tailEvents": Double(ManagedAgentTileNSView.qaTailEventsApplied),
         "statusRefreshes": Double(ManagedAgentTileNSView.qaStatusRefreshes),
         "parkedStatusRefreshes": Double(ManagedAgentTileNSView.qaParkedStatusRefreshes),
         "statusRefreshMs": ManagedAgentTileNSView.qaStatusRefreshSeconds * 1_000,
         "parkedStatusHolds": Double(ManagedAgentTileNSView.qaParkedStatusHolds),
         "parkedTailEvents": Double(ManagedAgentTileNSView.qaParkedTailEventsApplied),
         "tailEventMs": ManagedAgentTileNSView.qaTailEventSeconds * 1_000]
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["CONTINUUM_PROJECT_ROOT"], let supportPath = env["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "requires isolated CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT")
        }
        let agents = max(4, Int(env["IDLE_FRAMES_AGENTS"] ?? "") ?? 24)
        let seconds = Double(env["IDLE_FRAMES_SECONDS"] ?? "") ?? 12
        let fixture = try CanvasMotionWorkload(root: URL(fileURLWithPath: rootPath),
            support: URL(fileURLWithPath: supportPath), markdownCount: 0, agentCount: agents, offscreen: true)
        defer { fixture.close() }
        await spin(Double(env["IDLE_FRAMES_WARMUP"] ?? "") ?? 4)

        let deltaMs = max(5, Int(env["CANVAS_MOTION_DELTA_MS"] ?? "") ?? 50)
        fixture.startStreaming(delay: 0, tickLimit: Int((seconds + 3) * 1_000 / Double(deltaMs)))
        await spin(1.5)

        // Heartbeat: one record per beat, so a long gap carries the counter deltas
        // of exactly the work that ran inside it.
        let slot = 1.0 / 120
        var beats: [(t: Double, c: [String: Double])] = []
        let start = counters()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: slot, leeway: .microseconds(100))
        timer.setEventHandler {
            MainActor.assumeIsolated { beats.append((ProcessInfo.processInfo.systemUptime, counters())) }
        }
        timer.resume()
        await spin(seconds)
        timer.cancel()
        let end = counters()

        // Return path: a parked, streaming tile comes back through the production
        // promote and must refresh its held row at once.
        var returnWitness: [String: Any] = ["checked": false]
        if let tile = fixture.agentTileIDs.compactMap({ fixture.canvas.tileView(for: $0) as? ManagedAgentTileNSView })
            .first(where: { $0.isFarParked && $0.qaStatusHeldWhileParked }) {
            let before = tile.qaLocationRefreshCount
            tile.promoteBodyToNative()
            returnWitness = ["checked": true, "refreshedOnReturn": tile.qaLocationRefreshCount > before,
                             "heldAfterReturn": tile.qaStatusHeldWhileParked, "parkedAfterReturn": tile.isFarParked]
        }
        fixture.stopStreaming()

        var missed = 0
        var longGaps: [[String: Any]] = []
        var causeMisses: [String: Int] = [:]
        for (a, b) in zip(beats, beats.dropFirst()) {
            let gap = b.t - a.t
            let slots = Int((gap / slot).rounded())
            guard slots > 1 else { continue }
            missed += slots - 1
            var ran: [String: Double] = [:]
            for (key, value) in b.c where value != a.c[key] { ran[key] = value - (a.c[key] ?? 0) }
            let cause = ran.keys.filter { !$0.hasSuffix("Ms") }.sorted().joined(separator: "+")
            causeMisses[cause.isEmpty ? "none" : cause, default: 0] += slots - 1
            longGaps.append(["atSeconds": a.t - beats[0].t, "gapMs": gap * 1_000, "ran": ran])
        }
        let total = beats.count + missed
        var delta: [String: Double] = [:]
        for (key, value) in end { delta[key] = value - (start[key] ?? 0) }
        let result: [String: Any] = [
            "agents": agents, "seconds": seconds,
            "farParkedTiles": fixture.canvas.qaFarParkedTileCount,
            "statusTickDeferEnabled": ManagedAgentTileNSView.qaStatusTickDeferEnabled,
            "parkedStatusHoldEnabled": ManagedAgentTileNSView.qaParkedStatusHoldEnabled,
            "beats": beats.count, "missedSlots": missed,
            "missedPercent": total > 0 ? 100 * Double(missed) / Double(total) : 0,
            "returnWitness": returnWitness, "work": delta, "missedSlotsByWorkInGap": causeMisses, "longGaps": longGaps,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let out = env["IDLE_FRAMES_OUTPUT"] { try data.write(to: URL(fileURLWithPath: out)) }
        var brief = result
        brief["longGaps"] = longGaps.count
        let briefData = try JSONSerialization.data(withJSONObject: brief, options: [.sortedKeys])
        print("[idle-frames] " + String(data: briefData, encoding: .utf8)!)
        guard beats.count > Int(seconds * 20) else {
            throw Failure(description: "positive control: only \(beats.count) heartbeats in \(seconds)s")
        }
        guard (delta["transcriptApplies"] ?? 0) > 0 else {
            throw Failure(description: "positive control: no transcript applied while agents streamed")
        }
        // The parked status hold: legacy (PARKED_STATUS_HOLD=off) rebuilds parked
        // rows (RED); the hold rebuilds none and refreshes a returning tile (GREEN).
        let parkedRefreshes = delta["parkedStatusRefreshes"] ?? 0
        if ManagedAgentTileNSView.qaParkedStatusHoldEnabled {
            guard parkedRefreshes == 0 else {
                throw Failure(description: "far-parked tiles rebuilt their status row \(Int(parkedRefreshes)) times in \(seconds)s")
            }
            guard (delta["statusRefreshes"] ?? 0) > 0 else {
                throw Failure(description: "positive control: visible tiles never refreshed their status row")
            }
            guard returnWitness["checked"] as? Bool == true, returnWitness["refreshedOnReturn"] as? Bool == true,
                  returnWitness["heldAfterReturn"] as? Bool == false else {
                throw Failure(description: "return: a parked tile did not refresh its held row on return: \(returnWitness)")
            }
        } else {
            guard parkedRefreshes > 0 else {
                throw Failure(description: "anti-teeth: the legacy arm rebuilt no parked status row")
            }
        }
    }
}
