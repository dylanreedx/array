import AppKit
import ContinuumRevivedCore
import Foundation

/// `--external-session-fsevents-check`: the production `ExternalSessionMonitor`
/// over a synthetic home. An idle Mac costs no passes; a new session file is
/// seen within ~1 s with no polling in between; a burst coalesces; and the
/// legacy polling mode, run beside it, shows the counter really counts passes.
@MainActor
enum ExternalSessionFSEventsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(_ unused: String?) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-fsevents-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let claudeSessions = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        let rolloutDay = codexHome.appendingPathComponent("sessions/2026/11/24", isDirectory: true)
        try fm.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: rolloutDay, withIntermediateDirectories: true)

        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        func expect(_ ok: Bool, _ message: String) throws { if !ok { throw Failure(description: message) } }
        func make(watching: Bool) -> ExternalSessionMonitor {
            let monitor = ExternalSessionMonitor()
            monitor.homeOverride = (home, codexHome)
            monitor.watchesFilesystem = watching
            monitor.eventMinGap = 1.5
            monitor.pollingOverride = 0.5
            return monitor
        }
        func passes(afterWriting write: () -> Void, in monitor: ExternalSessionMonitor, within seconds: TimeInterval) -> (count: Int, firstAt: TimeInterval?) {
            let before = monitor.passCount
            let start = Date()
            write()
            var first: TimeInterval?
            while Date().timeIntervalSince(start) < seconds {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
                if first == nil, monitor.passCount > before { first = Date().timeIntervalSince(start) }
            }
            return (monitor.passCount - before, first)
        }

        // The old behaviour, counted: polling passes accumulate in an idle window.
        let legacy = make(watching: false)
        legacy.start()
        pump(0.2)
        let polled = passes(afterWriting: {}, in: legacy, within: 3).count
        legacy.stop()
        try expect(polled >= 3, "polling mode must show passes in an idle window; saw \(polled)")

        let monitor = make(watching: true)
        monitor.start()
        pump(2.5)   // first pass settles, the event gap passes
        let idle = passes(afterWriting: {}, in: monitor, within: 4).count
        try expect(idle == 0, "an idle Mac must run no discovery pass in 4 s; ran \(idle)")

        let claude = passes(afterWriting: {
            try? Data("{}".utf8).write(to: claudeSessions.appendingPathComponent("4242.json"))
        }, in: monitor, within: 1.5)
        try expect((claude.firstAt ?? 9) <= 1.0 && claude.count == 1,
                   "a new Claude session file is seen within 1 s by one pass; got \(claude)")
        pump(2)
        let codex = passes(afterWriting: {
            try? Data("{}\n".utf8).write(to: rolloutDay.appendingPathComponent("rollout-x.jsonl"))
        }, in: monitor, within: 1.5)
        try expect((codex.firstAt ?? 9) <= 1.0 && codex.count == 1,
                   "a new Codex rollout is seen within 1 s by one pass; got \(codex)")
        pump(2)
        let burst = passes(afterWriting: {
            for i in 0..<30 { try? Data("{}".utf8).write(to: claudeSessions.appendingPathComponent("\(5000 + i).json")) }
        }, in: monitor, within: 3)
        try expect(burst.count <= 2, "30 writes coalesce into at most 2 passes; ran \(burst.count)")
        monitor.stop()
        return "external session fsevents checks passed (polling idle passes \(polled), watching idle 0, claude \(claude.firstAt ?? -1)s, codex \(codex.firstAt ?? -1)s, burst \(burst.count))"
    }
}
