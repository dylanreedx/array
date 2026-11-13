import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentContent
import Foundation

extension SettingsUsageChecks {
    /// Production translators -> supervisor ingestion -> ledger -> report/words.
    /// Wire shape provenance: CodexAppServerParityChecks commandExecution,
    /// CodexAgentBackendChecks command_execution, PiEventTranslator tool_execution.
    /// No synthesized shellOutcome is supplied by this witness.
    @MainActor
    static func commandProviderTiming(_ root: URL) throws {
        final class Clock: @unchecked Sendable { var at = Date(timeIntervalSince1970: 1_000) }
        let defaults = QAIsolatedDefaults(isolatedSuiteName: "command-providers-\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteDomainName) }
        let store = AgentStore(applicationSupportDirectory: root)
        let agent = AgentID(rawValue: UUID()), serverAgent = AgentID(rawValue: UUID()), piAgent = AgentID(rawValue: UUID())
        for (id, harness) in [(agent, AgentHarness.codex), (serverAgent, .codex), (piAgent, .pi)] {
            try store.upsert(AgentRecord(id: id, displayName: "Timing", harness: harness,
                model: "fixture/timing", thinking: "medium", cwd: root.path, projectId: UUID(),
                createdAt: Date(), lastActivityAt: Date()))
        }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil })
        _ = supervisor.restore()
        defer { supervisor.stopAll() }
        supervisor.configureManagedMode(defaults: defaults)
        supervisor.qaCommandTimingEnabled = true
        let clock = Clock()
        supervisor.qaCommandReceiptTime = { clock.at }
        for id in [agent, serverAgent, piAgent] { supervisor.runLedger.submission(agent: id.rawValue, project: nil) }
        let receive: @Sendable (AgentRuntimeObservation) -> Void = { observation in
            MainActor.assumeIsolated { supervisor.qaObserveSharedTranscript(observation, for: agent) }
        }
        // Provider clocks deliberately disagree with the receipt clock.
        var exec = CodexEventTranslator(runToken: "timing", now: { Date(timeIntervalSince1970: 50) })
        exec.settingsDefaults = defaults
        exec.onRuntimeObservation = receive
        var server = CodexAppServerEventTranslator(now: { Date(timeIntervalSince1970: 90) })
        server.settingsDefaults = defaults
        server.onRuntimeObservation = { observation in MainActor.assumeIsolated { supervisor.qaObserveSharedTranscript(observation, for: serverAgent) } }
        var pi = PiEventTranslator(now: { Date(timeIntervalSince1970: 120) })
        pi.settingsDefaults = defaults
        pi.onRuntimeObservation = { observation in MainActor.assumeIsolated { supervisor.qaObserveSharedTranscript(observation, for: piAgent) } }
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func execFrame(_ phase: String, _ id: String, _ exit: Int? = nil) throws -> String {
            var item: [String: Any] = ["id": id, "type": "command_execution", "command": "swift build", "status": phase == "started" ? "in_progress" : "completed"]
            if let exit { item["exit_code"] = exit }
            return try json(["type": "item.\(phase)", "item": item])
        }
        clock.at = Date(timeIntervalSince1970: 1_000)
        _ = exec.translate(line: try execFrame("started", "exec"))
        clock.at = Date(timeIntervalSince1970: 1_012)
        _ = exec.translate(line: try execFrame("completed", "exec", 0))
        clock.at = Date(timeIntervalSince1970: 1_020)
        _ = server.translate(line: try json(["method": "item/started", "params": ["threadId": "timing", "turnId": "t", "item": ["id": "server", "type": "commandExecution", "command": "swift test", "status": "inProgress"]]]))
        clock.at = Date(timeIntervalSince1970: 1_027)
        _ = server.translate(line: try json(["method": "item/completed", "params": ["threadId": "timing", "turnId": "t", "item": ["id": "server", "type": "commandExecution", "exitCode": 1, "status": "completed"]]]))
        clock.at = Date(timeIntervalSince1970: 1_030)
        _ = pi.translate(line: try json(["type": "tool_execution_start", "toolCallId": "pi", "toolName": "bash", "args": ["command": "swift build"], "ts": "2026-01-01T00:00:00Z"]))
        clock.at = Date(timeIntervalSince1970: 1_035)
        _ = pi.translate(line: try json(["type": "tool_execution_end", "toolCallId": "pi", "toolName": "bash", "isError": false, "result": ["content": [["type": "text", "text": "done"]]], "ts": "2026-01-01T01:00:00Z"]))
        func commands() throws -> [RunLedgerUsageReader.Command] {
            supervisor.runLedger.drain()
            return RunLedgerUsageReader.read(try Data(contentsOf: supervisor.runLedgerURL)).tasks.flatMap(\.commands)
        }
        var failures: [String] = []
        let initial = try commands()
        if initial.map(\.duration) != [12, 7, 5] { failures.append("provider/supervisor intervals: \(initial.map(\.duration)), expected [12,7,5] from host receipt clock") }
        // Use the production Settings write seam, including a complete off/on
        // transition with NO intervening runtime observation.
        let settings = SettingsModel(defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }), initialPaneID: "general")
        let recording = SettingsSchema.sections().flatMap(\.groups).flatMap(\.rows).first { $0.field.key == AgentTokenTelemetryConfig.enabledKey }!.field
        clock.at = Date(timeIntervalSince1970: 1_040)
        _ = exec.translate(line: try execFrame("started", "consent"))
        settings.write(.bool(false), to: recording)
        settings.write(.bool(true), to: recording)
        clock.at = Date(timeIntervalSince1970: 1_090)
        _ = exec.translate(line: try execFrame("completed", "consent", 0))
        supervisor.runLedger.drain()
        let raw = ManagedRunLedgerChecks.rows(supervisor.runLedgerURL)
        if raw.filter({ $0["kind"] as? String == "commandEnded" }).count != 3 {
            failures.append("off/on consent transition retained correlation")
        }
        // Reusing a provider call ID must record a separate unknown span, and
        // must never attach a late end to the already completed first span.
        let beforeReuse = try commands().count
        clock.at = Date(timeIntervalSince1970: 1_100)
        _ = exec.translate(line: try execFrame("started", "exec"))
        clock.at = Date(timeIntervalSince1970: 1_112)
        _ = exec.translate(line: try execFrame("completed", "exec", 0))
        if try commands().count != beforeReuse + 1 || commands().first(where: { $0.agent == agent.rawValue && $0.duration == nil }) == nil {
            failures.append("reused provider call id did not remain a separate unknown span")
        }
        let description = SettingsSchema.sections().flatMap(\.groups).flatMap(\.rows).first { $0.field.key == AgentTokenTelemetryConfig.enabledKey }
        if !(String(describing: description).contains("command timing")) { failures.append("recording disclosure omits command timing") }
        let report = UsageReport.make(RunLedgerUsageReader.read(try Data(contentsOf: supervisor.runLedgerURL)), period: .all)
        if let line = report.tasks.first, UsageWords.commandTime(line).contains("ended") { failures.append("duration coverage mislabeled ended") }
        let timingRows = ManagedRunLedgerChecks.rows(supervisor.runLedgerURL).filter { ($0["kind"] as? String)?.hasPrefix("command") == true }
        if !timingRows.allSatisfy({ $0["commandTimingSource"] as? String == "supervisorReceipt" }) { failures.append("missing timing clock provenance") }
        if Set(timingRows.compactMap { $0["harness"] as? String }) != Set([AgentHarness.codex.rawValue, AgentHarness.pi.rawValue]) { failures.append("missing harness provenance") }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
        try withPane(ledger: supervisor.runLedgerURL) { fixture, _ in
            fixture.select("usage")
            let deadline = Date().addingTimeInterval(30)
            while !fixture.model.usage.qaRuns.contains(where: { !$0.onMain }), Date() < deadline { fixture.settle(0.05) }
            fixture.settle(0.2)
            guard case let .ready(shown, _) = fixture.model.usage.phase else { throw Failure("provider fixture not ready") }
            for task in shown.tasks { fixture.model.usage.toggle(task.task) }
            fixture.settle(0.2)
            let words = fixture.model.renderedTexts.values.joined(separator: "\n")
            try expect(words.contains("build 12 s (1/3 measured)") && words.contains("check 7 s (1/1 measured)") && words.contains("build 5 s (1/1 measured)"), "provider values missing from rendered Settings")
            try render(fixture, name: "provider-commands-light", appearance: .aqua)
            try render(fixture, name: "provider-commands-dark", appearance: .darkAqua)
        }
        try commandLifecycle(root.appendingPathComponent("lifecycle"))
    }
    @MainActor
    static func commandLifecycle(_ support: URL) throws {
        let agent = UUID()
        let writer = ManagedRunLedger(support: support)
        func send(_ ledger: ManagedRunLedger, _ call: String, _ phase: AgentToolDetailObservation.Phase,
                  _ seconds: Double, outcome: AgentShellStatus? = nil, exit: Int? = nil) {
            let detail = AgentToolDetailObservation(phase: phase, toolName: "bash",
                fields: [(AgentToolDetailObservation.shellCommandKey, "swift build")],
                exitCode: exit, shellOutcome: outcome, observedAt: Date(timeIntervalSince1970: -5_000))
            ledger.command(agent: agent, call: call, detail: detail, receivedAt: Date(timeIntervalSince1970: seconds))
        }
        func read(_ ledger: ManagedRunLedger) throws -> RunLedgerUsageReader.Ledger {
            ledger.drain()
            return RunLedgerUsageReader.read(try Data(contentsOf: RunLedgerUsageReader.ledgerURL(applicationSupport: support)))
        }
        writer.submission(agent: agent, project: nil)
        send(writer, "restart", .started, 10)
        writer.drain()
        let restarted = ManagedRunLedger(support: support)
        restarted.drain()
        send(restarted, "restart", .ended, 20, exit: 0)
        let recovered = try read(restarted)
        try expect(recovered.tasks.flatMap(\.commands).allSatisfy { $0.duration == nil }, "restart paired an old span")
        restarted.submission(agent: agent, project: nil)
        send(restarted, "restart", .started, 30)
        send(restarted, "restart", .ended, 42, exit: 0)
        send(restarted, "background", .started, 50)
        send(restarted, "background", .ended, 62, outcome: .backgrounded, exit: 0)
        send(restarted, "timeout", .started, 70)
        send(restarted, "timeout", .ended, 82, outcome: .timedOut, exit: 0)
        send(restarted, "interrupted", .started, 90)
        send(restarted, "interrupted", .ended, 102, outcome: .interrupted, exit: 0)
        send(restarted, "complete", .started, 110)
        send(restarted, "complete", .ended, 122, exit: 1)
        let before = try read(restarted)
        let commands = before.tasks.flatMap(\.commands)
        try expect(commands.count == 6 && commands.compactMap(\.duration) == [12], "restart/reused IDs or incomplete ends gained duration")
        // An old timing row without receipt provenance remains readable but
        // cannot be promoted into a host-receipt duration.
        let url = RunLedgerUsageReader.ledgerURL(applicationSupport: support)
        var legacy = Data()
        for line in try Data(contentsOf: url).split(separator: 10) {
            var row = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
            row.removeValue(forKey: "commandTimingSource")
            legacy.append(try JSONSerialization.data(withJSONObject: row)); legacy.append(10)
        }
        try expect(RunLedgerUsageReader.read(legacy).tasks.flatMap(\.commands).allSatisfy { $0.duration == nil }, "legacy clock source became trusted")
        send(restarted, "late-delete", .started, 130)
        restarted.ended(agent: agent, turn: "finish", outcome: .completed)
        let closed = try read(restarted)
        guard let task = closed.tasks.first(where: { $0.state == .closed }) else { throw Failure("lifecycle task did not close") }
        restarted.delete(.task(task.id)); restarted.drain()
        let bytes = try Data(contentsOf: url)
        send(restarted, "late-delete", .ended, 142, exit: 0)
        restarted.drain()
        let afterDelete = try Data(contentsOf: url)
        try expect(afterDelete == bytes, "late end recreated deleted task records")
    }

}
