import AppKit
import ContinuumRevivedCore

@MainActor
enum HelperCompletionChecks {
    static func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper completion check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-completion")
        defer { bench.tearDown() }
        let script = WorkspaceAgentReportChecks.fakePi.replacingOccurrences(
            of: "if \"HOLD\" in json.dumps(text):",
            with: "if \"HOLD\" in json.dumps(text) and not any(line == \"Helper turn updates\" for line in str(text).splitlines()):")
        try script.write(to: bench.binDir.appendingPathComponent("pi"), atomically: true, encoding: .utf8)
        let s = bench.supervisor, parent = bench.f.agentId
        var now = Date()
        s.helperCompletionNow = { now }
        s.helperCompletionEnabled = { _ in true }
        func finish(_ child: AgentID, _ turn: String, _ outcome: TurnOutcome = .completed) {
            s.qaDeliver(.turnCompleted(threadId: "fixture", turnId: turn, outcome: outcome, errorMessage: outcome == .failed ? "work failed" : nil), to: child)
        }
        let child = try bench.delegate("HOLD-first")
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) { s.isRunning(child) }
        try HelperGuardChecks.expect(started, "helper did not start")
        _ = s.fileReport(.init(summary: "WAKE-REPORT"), for: child)
        finish(child, "first")
        now.addTimeInterval(7)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(!s.isRunning(parent), "completion fired before eight seconds")
        now.addTimeInterval(2)
        await s.flushHelperCompletions()
        let cwd = URL(fileURLWithPath: s.records[parent]!.cwd)
        func log() -> String { (try? String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        func wakeCount() -> Int {
            log().split(separator: "\n").compactMap { line -> String? in
                try? JSONDecoder().decode(String.self, from: Data(line.utf8))
            }.filter { $0.components(separatedBy: "\n").contains("Helper turn updates") }.count
        }
        let received = await waitUntil(timeout: 15, pollInterval: 0.02) { log().contains("WAKE-REPORT") && !s.isRunning(parent) }
        try HelperGuardChecks.expect(received, "idle lead did not receive helper report")
        finish(child, "first")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(log().components(separatedBy: "WAKE-REPORT").count - 1 == 1, "duplicate completion delivered")
        try HelperGuardChecks.expect(s.send("HOLD-parent", to: parent), "parent did not start")
        let children = try (0..<3).map { try bench.delegate("HOLD-group-\($0)") }
        for (i, c) in children.enumerated() { finish(c, "group-\(i)", i == 0 ? .failed : .interrupted) }
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let updates = s.queuedMessages(for: parent).filter { $0.text.contains("Helper turn updates") }
        try HelperGuardChecks.expect(updates.count == 1 && children.allSatisfy { updates[0].text.contains($0.rawValue.uuidString) }, "busy lead did not queue one grouped update")
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(s.queuedMessages(for: parent).filter { $0.text.contains("Helper turn updates") }.count == 1, "queued update repeated")
        let end = Date().addingTimeInterval(20)
        while Date() < end && (s.isRunning(parent) || !s.queuedMessages(for: parent).isEmpty) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try HelperGuardChecks.expect(wakeCount() == 2, "group did not deliver once after busy turn; queued=\(s.queuedMessages(for: parent).count), running=\(s.isRunning(parent)), log=\(log())")
        let stopped = try bench.delegate("HOLD-stop")
        s.stop(stopped)
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let stopDelivered = await waitUntil(timeout: 15, pollInterval: 0.02) { wakeCount() == 3 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(stopDelivered, "stopped helper did not wake lead")
        s.helperCompletionEnabled = { _ in false }
        finish(child, "off")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(wakeCount() == 3, "disabled lead was woken")
    }
}
