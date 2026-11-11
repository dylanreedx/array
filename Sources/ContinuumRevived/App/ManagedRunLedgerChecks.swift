import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/116-agent-standards` part 12 step 1: the host-kept run ledger.
/// Drives the composer's own `accept`, the production MCP binary's
/// `array_delegate` and `array_report`, and the production Claude runner over a
/// disposable CLI, then reads the ledger file the host wrote. A crash is a copy
/// of Application Support taken while a task is open, restored by a new
/// supervisor exactly as a relaunch would.
@MainActor
enum ManagedRunLedgerChecks {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "run-ledger: " + message) }
    }

    /// The managed fixture CLI, with each hold named so the lead and its helper
    /// (which share a checkout) are released independently: `HOLD-x` waits for
    /// `release-x` in the working directory.
    static let script = ManagedModeChecks.fakeClaude
        .replacingOccurrences(of: "import json, os, sys, time", with: "import json, os, re, sys, time")
        .replacingOccurrences(of: "if 'HOLD' in json.dumps(o):", with: "m = re.search(r'HOLD-([a-z0-9]+)', json.dumps(o))\n    if m:")
        .replacingOccurrences(of: "while not os.path.exists('managed-release'): time.sleep(.02)",
                              with: "while not os.path.exists('release-' + m.group(1)): time.sleep(.02)")
        .replacingOccurrences(of: "os.unlink('managed-release')", with: "pass # leave the named release available to the result wake")

    /// Every key a row may carry. None of them holds free text.
    static let allowedKeys: Set<String> = ["v", "at", "kind", "task", "agent", "part", "source", "previousTask",
        "project", "intent", "origin", "outcome", "harness", "model", "retryOf", "checks", "findings", "openParts"]
    static let secrets = ["SECRET-PROMPT", "SECRET-BRIEF", "SECRET-REPORT", "SECRET-CHECK", "SECRET-FINDING", "HOLD-"]

    static func rows(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    static func rows(_ url: URL, _ kind: String, task: String? = nil, agent: AgentID? = nil) -> [[String: Any]] {
        rows(url).filter { row in
            row["kind"] as? String == kind && (task == nil || row["task"] as? String == task)
                && (agent == nil || row["agent"] as? String == agent!.rawValue.uuidString)
        }
    }

    static func run() async throws {
        let mode = ProcessInfo.processInfo.environment["CONTINUUM_LEDGER_REVIEW_CASE"]
        if mode == "isolation" { try isolation(); return }
        try await scenario(noWake: mode == "closure")
        if mode == nil { try await scenario(noWake: true); try isolation() }
    }

    static func isolation() throws {
        let old = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]
        let unsafe = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ledger-isolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        defer {
            if let old { setenv("CONTINUUM_APP_SUPPORT", old, 1) } else { unsetenv("CONTINUUM_APP_SUPPORT") }
            try? FileManager.default.removeItem(at: unsafe)
        }
        setenv("CONTINUUM_APP_SUPPORT", unsafe.path, 1)
        var refused = false
        do { let b = try ManagedModeChecks.bench("ledger-unsafe"); b.tearDown() }
        catch { refused = true }
        try expect(refused, "check accepted a non-temporary support directory")
        try expect(try FileManager.default.contentsOfDirectory(atPath: unsafe.path).isEmpty, "unsafe support was touched")
        print("Ledger isolation refusal passed")
    }

    static func scenario(noWake: Bool) async throws {
        let b = try ManagedModeChecks.bench("run-ledger")
        defer { b.tearDown() }
        let cli = b.binDir.appendingPathComponent("claude")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let supervisor = b.supervisor, lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model),
                   "could not select lead harness")
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)
        try expect(supervisor.effectiveMode(for: lead) == .managed, "Settings did not make the top-level agent a Managed lead")
        _ = supervisor.rename(agentID: lead, to: "Ledger lead")

        // The supervisor's own channel-scoped Application Support, beside its agent records.
        let support = AgentStore(smokeTest: false).layout.applicationSupportDirectory
        try expect(FileManager.default.fileExists(atPath: AgentStoreLayout(applicationSupportDirectory: support).agentFile(id: lead).path),
                   "the lead's record is not in the resolved Application Support")
        let ledger = support.appendingPathComponent("run-ledger/ledger.jsonl")
        try expect(ledger.resolvingSymlinksInPath().path.hasPrefix(b.binDir.resolvingSymlinksInPath().path + "/"),
                   "ledger is outside the check-owned temporary directory")
        let cwd = URL(fileURLWithPath: supervisor.records[lead]!.cwd)
        func release(_ tag: String) throws { try Data().write(to: cwd.appendingPathComponent("release-\(tag)")) }
        func wait(_ message: @autoclosure () -> String, timeout: TimeInterval = 15, _ condition: @escaping @MainActor () -> Bool) async throws {
            try await AgentPresenceChecks.eventually("run-ledger: " + message(), timeout: timeout, condition)
        }

        // 1. One human submission, through the composer's production entry, opens one task.
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-leadone SECRET-PROMPT-ALPHA")), for: lead) == .accepted,
                   "first submission refused")
        try await wait("first submission opened no task") { !rows(ledger, "taskOpened").isEmpty }
        let opened = rows(ledger, "taskOpened")
        try expect(opened.count == 1 && opened[0]["agent"] as? String == lead.rawValue.uuidString
                   && opened[0]["previousTask"] == nil, "expected one task for the lead: \(opened)")
        let t1 = opened[0]["task"] as! String
        try expect(rows(ledger, "submission", task: t1).count == 1, "first submission not recorded under its task")
        try await wait("lead did not start") { supervisor.isRunning(lead) }

        // 2. A delegation through the production MCP binary appends a part under that task.
        let k1 = UUID().uuidString
        let h1 = try await delegate(b, task: "HOLD-helperone SECRET-BRIEF-BETA", key: k1)
        try await wait("delegation not recorded under the task") { !rows(ledger, "delegated", task: t1, agent: h1).isEmpty }
        let p1 = rows(ledger, "delegated", task: t1, agent: h1)[0]["part"] as! String
        try await wait("helper working not recorded") { !rows(ledger, "working", task: t1, agent: h1).isEmpty }
        // The same idempotency key replays: no second child, no second row.
        try expect(try await delegate(b, task: "HOLD-helperone SECRET-BRIEF-BETA", key: k1) == h1, "replay created a new child")
        try expect(rows(ledger, "delegated").count == 1, "a replayed delegation was recorded twice")

        // 3. The lead's turn ends while its part is open: the task stays open.
        try release("leadone")
        try await wait("lead turn end not recorded") { rows(ledger, "turnEnded", task: t1, agent: lead).count == 1 }
        try expect(rows(ledger, "taskClosed").isEmpty, "task closed while a helper was still working")

        // 4. A second submission while a part is open joins the same task.
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("SECRET-PROMPT-DELTA")), for: lead) == .accepted,
                   "second submission refused")
        try await wait("second submission did not join the task") { rows(ledger, "submission", task: t1).count == 2 }
        try expect(rows(ledger, "taskOpened").count == 1, "second submission opened a task")
        try await wait("second lead turn not recorded") { rows(ledger, "turnEnded", task: t1, agent: lead).count == 2 }
        try expect(rows(ledger, "taskClosed").isEmpty, "task closed while a helper was still working")

        if noWake { supervisor.helperCompletionEnabled = { _ in false } }
        // 5. The helper's report, filed through the production MCP binary, appends under its part.
        let report = try await WorkspaceAgentReportChecks.call(b.configuration(for: h1), "array_report", [
            "summary": "SECRET-REPORT-GAMMA",
            "checks": [["what": "SECRET-CHECK-ONE", "result": "pass"], ["what": "SECRET-CHECK-TWO", "result": "fail"]],
            "findings": [["level": "issue", "text": "SECRET-FINDING-ONE"]]])
        try expect(!report.isError, "report refused: \(report.reply)")
        try await wait("report not recorded under the part") { !rows(ledger, "reported", task: t1, agent: h1).isEmpty }
        let reported = rows(ledger, "reported", task: t1, agent: h1)[0]
        try expect(reported["part"] as? String == p1 && (reported["checks"] as? [String: Int]) == ["pass": 1, "fail": 1]
                   && (reported["findings"] as? [String: Int]) == ["issue": 1], "report row wrong: \(reported)")

        if noWake {
            try await wait("last helper report did not close task without a wake", timeout: 3) { !rows(ledger, "taskClosed", task: t1).isEmpty }
            try expect(rows(ledger, "turnEnded", task: t1, agent: lead).count == 2, "closure required another lead turn")
        }
        // 6. The helper finishes; its result wakes the lead. The wake runs inside
        //    the task and opens none; the task closes once no work remains.
        try release("helperone")
        try await wait("task did not close after the helper's result", timeout: 40) { !rows(ledger, "taskClosed", task: t1).isEmpty }
        try await wait("helper end missing") { rows(ledger, "turnEnded", task: t1, agent: h1).count == 1 }
        if !noWake { try await wait("wake end missing") { rows(ledger, "turnEnded", task: t1, agent: lead).count >= 3 } }
        let ended = rows(ledger, "turnEnded", task: t1, agent: h1)
        try expect(ended.count == 1 && ended[0]["part"] as? String == p1 && ended[0]["outcome"] as? String == "completed",
                   "helper turn end wrong: \(ended)")
        if !noWake { try expect(rows(ledger, "turnEnded", task: t1, agent: lead).count >= 3, "the helper wake did not run inside the task") }
        try expect(rows(ledger, "taskOpened").count == 1, "a helper wake opened a task")


        // 7. After the task closed, a submission opens a new linked task.
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-leadtwo SECRET-PROMPT-EPSILON")), for: lead) == .accepted,
                   "third submission refused")
        try await wait("third submission opened no task") { rows(ledger, "taskOpened").count == 2 }
        let second = rows(ledger, "taskOpened")[1]
        let t2 = second["task"] as! String
        try expect(t2 != t1 && second["previousTask"] as? String == t1, "new task not linked to the closed one: \(second)")
        let h2 = try await delegate(b, task: "HOLD-helpertwo SECRET-BRIEF-ZETA", key: UUID().uuidString)
        try await wait("second delegation not recorded") { !rows(ledger, "working", task: t2, agent: h2).isEmpty }
        let p2 = rows(ledger, "delegated", task: t2, agent: h2)[0]["part"] as! String

        // 8. Crash with the task open: Application Support as it stood, relaunched.
        let crash = b.binDir.appendingPathComponent("crash-image", isDirectory: true)
        try FileManager.default.copyItem(at: support, to: crash)
        let crashLedger = crash.appendingPathComponent("run-ledger/ledger.jsonl")
        let tail = try FileHandle(forWritingTo: crashLedger)
        try tail.seekToEnd(); try tail.write(contentsOf: Data("{torn".utf8)); try tail.close()
        let beforeRecovery = try Data(contentsOf: crashLedger)
        let relaunched = AgentSupervisor(store: AgentStore(applicationSupportDirectory: crash))
        relaunched.configureManagedMode(defaults: b.settings); relaunched.restore()
        try await wait("relaunch did not mark the open task incomplete") { !rows(crashLedger, "taskInterrupted", task: t2).isEmpty }
        let recoveredBytes = try Data(contentsOf: crashLedger)
        try expect(recoveredBytes.starts(with: beforeRecovery), "restart changed earlier bytes")
        try expect(recoveredBytes.dropFirst(beforeRecovery.count).split(separator: 10).count == 1, "restart did not append exactly one fact")
        let interrupted = rows(crashLedger, "taskInterrupted", task: t2)[0]
        try expect(interrupted["openParts"] as? [String] == [p2], "interrupted task does not name its open part: \(interrupted)")
        try expect(rows(crashLedger, "taskClosed", task: t2).isEmpty && rows(crashLedger, "turnEnded", task: t2, agent: h2).isEmpty,
                   "relaunch invented an outcome for the interrupted task")
        try expect(rows(crashLedger, "taskClosed", task: t1).count == 1 && rows(crashLedger, "reported", task: t1).count == 1,
                   "closed task's facts did not survive the restart")
        relaunched.stopAll()
        // A second relaunch neither repeats the recovery nor loses the lead's history.
        let again = AgentSupervisor(store: AgentStore(applicationSupportDirectory: crash))
        again.configureManagedMode(defaults: b.settings); again.restore()
        defer { again.stopAll() }
        try expect(await again.accept(.sendPrompt(AgentPrompt("SECRET-PROMPT-ETA")), for: lead) == .accepted,
                   "submission after relaunch refused")
        try await wait("submission after relaunch opened no task") { rows(crashLedger, "taskOpened").count == 3 }
        try expect(rows(crashLedger, "taskOpened")[2]["previousTask"] as? String == t2, "relaunched lead lost its task history")
        try expect(rows(crashLedger, "taskInterrupted").count == 1, "a second relaunch repeated the recovery")

        // 9. Nothing stored is prompt text, a brief, a report or a check's words.
        for url in [ledger, crashLedger] {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for secret in secrets { try expect(!text.contains(secret), "\(url.lastPathComponent) stores \(secret)") }
            for row in rows(url) {
                try expect(Set(row.keys).isSubset(of: allowedKeys) && row["v"] as? Int == 1, "unexpected row shape: \(row)")
            }
        }
        try release("leadtwo"); try release("helpertwo")
        if noWake { try await timing(b, lead: lead, helper: h2) }
        print("Managed run ledger passed: one task per human submission, delegation/report/turn facts under its id, join while a part is open, wake opens none, linked next task, crash marks incomplete once, no prompt or report text stored")
    }

    static func timing(_ b: WorkspaceAgentReportChecks.Bench, lead: AgentID, helper: AgentID) async throws {
        let supervisor = b.supervisor
        var sendsOn: [Double] = [], sendsOff: [Double] = []
        var reportsOn: [Double] = [], reportsOff: [Double] = []
        let report = AgentReport(summary: "timing", checks: [.init(what: "timing", result: .pass)], findings: [])
        defer { supervisor.qaRunLedgerRecording = true }
        // Paired, alternating order; readiness waits and queue draining are
        // outside the measured production calls. Discard eight warm-up pairs.
        for iteration in 0..<108 {
            let order = iteration % 2 == 0 ? [false, true] : [true, false]
            for enabled in order {
                try await AgentPresenceChecks.eventually("timing lead idle", timeout: 15) {
                    !supervisor.isRunning(lead) && supervisor.turnSnapshot(for: lead)?.capabilities.canSend == true
                }
                supervisor.qaRunLedgerRecording = enabled
                let start = DispatchTime.now().uptimeNanoseconds
                let accepted = await supervisor.accept(.sendPrompt(AgentPrompt("timing")), for: lead)
                let send = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
                try expect(accepted == .accepted, "timing submission refused")
                let reportStart = DispatchTime.now().uptimeNanoseconds
                let filed = supervisor.fileReport(report, for: helper)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - reportStart) / 1000
                try expect(filed, "timing report refused")
                if iteration >= 8 {
                    if enabled { sendsOn.append(send); reportsOn.append(elapsed) }
                    else { sendsOff.append(send); reportsOff.append(elapsed) }
                }
            }
        }
        func describe(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            print(String(format: "ledger timing %@ n=%d median=%.2f p95=%.2f us", name, sorted.count,
                         sorted[sorted.count / 2], sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]))
        }
        describe("submission off", sendsOff); describe("submission on", sendsOn)
        describe("helper-report off", reportsOff); describe("helper-report on", reportsOn)
    }

    private static func delegate(_ b: WorkspaceAgentReportChecks.Bench, task: String, key: String) async throws -> AgentID {
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate", [
            "task": task, "title": "Ledger part", "harness": "Claude Code",
            "model": ManagedModeChecks.model, "idempotencyKey": key])
        guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
              let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger: delegation failed: \(reply.reply)")
        }
        return AgentID(rawValue: uuid)
    }
}
