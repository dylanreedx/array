import AppKit
import Foundation

/// `--hitch-log-check`: does a main-thread stall that lands in a camera gesture
/// reach the log with its label and the gesture flag, and does an idle app log
/// nothing?
///
/// It boots the motion probe's real scene off-screen (never activated), drives a
/// real pan and a real zoom through the production scroll responder at 120 Hz, and
/// forces one labelled 80 ms block on the main thread in the middle of each.
/// Witnesses:
///
/// 1. idle: with nothing slow, the watchdog logs no line (`HITCH_IDLE_SECONDS`,
///    default 5 s, not a literal minute);
/// 2. a pan with an 80 ms `qa-forced-block` logs one `stall:` line of at least 80 ms
///    naming that label with `gesture pan`; a zoom logs `gesture zoom`;
/// 3. the settled gesture report carries the same kind;
/// 4. a stall outside a gesture says `gesture no`;
/// 5. the observers cost under 1% of main-thread busy time during a zoom.
///
/// `HITCH_LOG_WATCHDOG=off` leaves the watchdog uninstalled: the base behaviour.
/// Every witness except the idle one must then fail (anti-teeth, the RED arm).
@MainActor
enum HitchLogChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Lines { var all: [String] = [] }

    private static func spin(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func forceBlock(ms: Int) {
        let tag = MainThreadActivity.begin("qa-forced-block")
        usleep(UInt32(ms * 1_000))
        tag.end()
    }

    private static func stallMs(_ line: String) -> Double {
        guard let range = line.range(of: "stall: "),
              let value = line[range.upperBound...].split(separator: " ").first else { return 0 }
        return Double(value) ?? 0
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let scratch = "/tmp/hitch-log-check-\(getpid())"
        try FileManager.default.createDirectory(atPath: scratch + "/support", withIntermediateDirectories: true)
        if env["CONTINUUM_APP_SUPPORT"] == nil { setenv("CONTINUUM_APP_SUPPORT", scratch + "/support", 1) }
        if env["CONTINUUM_PROJECT_ROOT"] == nil { setenv("CONTINUUM_PROJECT_ROOT", scratch + "/project", 1) }
        let supportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]!
        let rootPath = ProcessInfo.processInfo.environment["CONTINUUM_PROJECT_ROOT"]!
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let watchdogOn = env["HITCH_LOG_WATCHDOG"] != "off"
        let lines = Lines()
        MainThreadStallWatchdog.qaSink = { lines.all.append($0) }
        if watchdogOn { MainThreadStallWatchdog.install() } else { MainThreadStallWatchdog.uninstall() }

        let fixture = try CanvasMotionWorkload(root: URL(fileURLWithPath: rootPath),
            support: URL(fileURLWithPath: supportPath), markdownCount: 0, agentCount: 2, offscreen: true)
        defer { fixture.close() }
        let canvas = fixture.canvas
        await spin(2)

        // 1. Idle.
        lines.all.removeAll()
        let idleSeconds = Double(env["HITCH_IDLE_SECONDS"] ?? "") ?? 5
        await spin(idleSeconds)
        guard lines.all.isEmpty else {
            throw Failure(description: "an idle \(idleSeconds) s logged \(lines.all.count) stall line(s): \(lines.all)")
        }

        // 2. A labelled 80 ms block inside a driven gesture.
        func gesture(zoom: Bool, forcedAt step: Int?, steps: Int = 90) async {
            let omega = 2 * Double.pi / 3
            for index in 0..<steps {
                let t = Double(index) / 120, previous = Double(max(0, index - 1)) / 120
                if zoom {
                    fixture.postMagnify(delta: exp(0.4 * (sin(omega * t) - sin(omega * previous))) - 1)
                } else {
                    fixture.postPan(dx: 100 * (sin(omega * t) - sin(omega * previous)),
                                    dy: 60 * (cos(omega * t) - cos(omega * previous)))
                }
                if index == step { DispatchQueue.main.async { forceBlock(ms: 80) } }
                try? await Task.sleep(for: .seconds(1.0 / 120))
            }
            await spin(1.2) // the settle edge logs the gesture report
        }

        lines.all.removeAll()
        await gesture(zoom: false, forcedAt: 30)
        let panLines = lines.all.filter { $0.contains("qa-forced-block") }
        guard let pan = panLines.first, stallMs(pan) >= 80, pan.contains("gesture pan") else {
            throw Failure(description: "pan: no 80 ms qa-forced-block line with 'gesture pan' (all lines: \(lines.all))")
        }
        guard let panReport = canvas.qaLastGestureReport, panReport.kind == "pan" else {
            throw Failure(description: "pan: gesture report kind is \(canvas.qaLastGestureReport?.kind ?? "nil"), not pan")
        }

        lines.all.removeAll()
        await gesture(zoom: true, forcedAt: 30)
        guard let zoom = lines.all.first(where: { $0.contains("qa-forced-block") }), stallMs(zoom) >= 80,
              zoom.contains("gesture zoom") else {
            throw Failure(description: "zoom: no 80 ms qa-forced-block line with 'gesture zoom' (all lines: \(lines.all))")
        }
        guard let zoomReport = canvas.qaLastGestureReport, zoomReport.kind == "zoom" else {
            throw Failure(description: "zoom: gesture report kind is \(canvas.qaLastGestureReport?.kind ?? "nil"), not zoom")
        }

        // 3. A stall with no gesture open says so.
        lines.all.removeAll()
        DispatchQueue.main.async { forceBlock(ms: 80) }
        await spin(0.6)
        guard lines.all.contains(where: { $0.contains("qa-forced-block") && $0.contains("gesture no") }) else {
            throw Failure(description: "outside a gesture: expected a 'gesture no' line (all lines: \(lines.all))")
        }

        // 4. (numbered 5 above) Overhead (debug build unless run from release): observers vs main busy time.
        MainThreadStallWatchdog.qaMeasureOverhead = true
        MainThreadStallWatchdog.qaObserverNs = 0
        MainThreadStallWatchdog.qaBusyNs = 0
        await gesture(zoom: true, forcedAt: nil, steps: 240)
        MainThreadStallWatchdog.qaMeasureOverhead = false
        let observer = Double(MainThreadStallWatchdog.qaObserverNs) / 1e6
        let busy = Double(MainThreadStallWatchdog.qaBusyNs) / 1e6
        let percent = busy > 0 ? 100 * observer / busy : 0
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print(String(format: "overhead (%@ build): observers %.3f ms of %.1f ms main busy during a 2 s zoom = %.3f%%",
                     build, observer, busy, percent))
        guard percent < 1 else {
            throw Failure(description: String(format: "watchdog observers cost %.2f%% of main busy time (limit 1%%)", percent))
        }
    }
}
