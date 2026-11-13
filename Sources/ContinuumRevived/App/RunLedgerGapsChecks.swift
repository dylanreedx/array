import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/116` section 4 B, items 6 to 9: run-ledger and usage gaps. Each case
/// drives the production supervisor (the composer's `accept`, `array_delegate`,
/// `array_report` and `array_message_agent` through the production MCP binary)
/// and the production Claude and Codex runners and translators over the CLI
/// doubles of `RequestTelemetryChecks`, replaying committed captures. It asserts
/// the ledger rows and the usage page's numbers (`UsageReport.make` over the
/// ledger file, in `UsageWords`), never source text.
///
/// Cases (`CONTINUUM_LEDGER_GAPS_CASE`): `builtin` and `builtin-codex` (B6),
/// `nested` (B7), `active-time` (B8: the wake that reads helper results is the
/// task's, a later turn is not), `after-close` (B9: an agent message after the
/// close, and a late helper's wake rejoining), `hooks-after-close` (hook rows
/// follow the open task), `codex-trailing` and `codex-drain-bound` (B9, Codex
/// frames after the turn).
@MainActor
enum RunLedgerGapsChecks {
    typealias T = RequestTelemetryChecks
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: " + message) }
    }
    static let noTask = ManagedRunLedger.noTask.uuidString

    static func run() async throws {
        let only = ProcessInfo.processInfo.environment["CONTINUUM_LEDGER_GAPS_CASE"]
        let cases: [(String, () async throws -> Void)] = [
            ("builtin", builtinClaude), ("builtin-codex", builtinCodex), ("nested", nested),
            ("active-time", activeTime), ("after-close", afterClose), ("hooks-after-close", hooksAfterClose),
            ("codex-trailing", codexTrailing), ("codex-drain-bound", codexDrainBound),
        ]
        for (name, body) in cases where only == nil || only == name { try await body() }
        print("Run ledger gaps passed")
    }

    // MARK: Shared

    static func rows(_ kind: String? = nil) -> [[String: Any]] {
        let all = ManagedRunLedgerChecks.rows(T.ledgerURL())
        return kind.map { kind in all.filter { $0["kind"] as? String == kind } } ?? all
    }
    static func id(_ agent: AgentID) -> String { agent.rawValue.uuidString }
    /// The usage page's report over the ledger as it is on disk now.
    static func page() throws -> UsageReport {
        UsageReport.make(RunLedgerUsageReader.read(try Data(contentsOf: T.ledgerURL())), period: .all)
    }
    static func line(_ task: String) throws -> UsageReport.TaskLine {
        guard let line = try page().tasks.first(where: { $0.task.uuidString == task }) else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: the usage page lists no task \(task)")
        }
        return line
    }
    static func words(_ line: UsageReport.TaskLine, _ column: UsageReport.Column) -> String {
        UsageWords.figure(line.tokens[column]?[.total] ?? .init(), exact: true)
    }
    static func taskOpened(by lead: AgentID) throws -> String {
        guard let task = rows("taskOpened").last(where: { $0["agent"] as? String == id(lead) })?["task"] as? String else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: no task opened by the lead")
        }
        return task
    }

    static func delegate(_ b: Bench, from parent: AgentID, _ name: String, task: String) async throws -> AgentID {
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: parent), "array_delegate", [
            "task": task, "title": "Gaps \(name)", "harness": "Claude Code", "model": ManagedModeChecks.model,
            "idempotencyKey": UUID().uuidString])
        guard !reply.isError, let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String,
              let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: \(name) delegation failed: \(reply.reply)")
        }
        return AgentID(rawValue: uuid)
    }
    static func checkout(_ b: Bench, _ agent: AgentID, else fallback: URL) -> URL {
        URL(fileURLWithPath: b.supervisor.records[agent]?.checkoutRoot ?? fallback.path)
    }
    static func inputs(_ root: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("inputs-") }
            .compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .map { $0.split(separator: "\n").count }.reduce(0, +)
    }

    /// A Managed Claude lead fans out one helper and ends its turn; the helper
    /// reports and its turn goes on `tail` seconds, then ends and wakes the
    /// lead. The task closes when that wake ends. Returns once all settled.
    static func fanOutAndClose(_ b: Bench, _ lead: AgentID, _ root: URL, tail: TimeInterval) async throws -> (task: String, helper: AgentID) {
        let supervisor = b.supervisor
        try T.installClaudeDouble(b)
        try expect(supervisor.rename(agentID: lead, to: "Gaps lead"), "could not name the lead")
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-lead SECRET-PROMPT")), for: lead) == .accepted, "lead submission refused")
        try await T.wait("lead did not start") { supervisor.isRunning(lead) }
        let helper = try await delegate(b, from: lead, "ha", task: "HOLD-ha SECRET-BRIEF")
        let helperRoot = checkout(b, helper, else: root)
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await T.wait("lead turn did not end") { !supervisor.isRunning(lead) }
        try await T.wait("helper did not start") { supervisor.isRunning(helper) }
        let before = T.closures()
        let report = try await WorkspaceAgentReportChecks.call(b.configuration(for: helper), "array_report", [
            "summary": "SECRET-REPORT", "checks": [["what": "SECRET-CHECK", "result": "pass"]]])
        try expect(!report.isError, "helper report refused: \(report.reply)")
        try await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
        let woken = T.usage(lead).count
        for dir in Set([helperRoot.path, root.path]) {
            try Data().write(to: URL(fileURLWithPath: dir).appendingPathComponent("release-ha"))
        }
        try await T.wait("helper did not end") { !supervisor.isRunning(helper) }
        try await T.wait("the helper's result did not wake the lead", timeout: 40) { supervisor.runLedger.drain(); return T.usage(lead).count > woken }
        try await T.wait("lead wake did not settle") { !supervisor.isRunning(lead) }
        try await T.wait("the task did not close") { supervisor.runLedger.drain(); return T.closures() > before }
        return (try taskOpened(by: lead), helper)
    }

    // MARK: B6, a CLI's own subagent

    /// A Claude lead whose turn runs Claude's Agent tool (claude-subagent-turn).
    /// The subagent gets a delegated row naming the lead and its harness, its
    /// turn rows in the task, and a usage row saying its tokens are inside the
    /// lead's result. The page counts it as a helper and says "included in
    /// parent" for its tokens, never zero.
    static func builtinClaude() async throws {
        print("run-ledger-gaps: Claude's own subagent (B6)")
        let b = try ManagedModeChecks.bench("ledger-gaps-builtin")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try T.installClaudeDouble(b)
        try T.stage(try T.claudeRun("claude-subagent-turn.jsonl"), "sub", in: root)
        try await T.soloTurn(b, lead, "FRAMES-sub")
        let supervisor = b.supervisor
        var child: AgentID?
        try await T.wait("the subagent was not adopted, or its turn did not end") {
            supervisor.runLedger.drain()
            child = supervisor.records.values.first { $0.parentAgentID == lead && $0.capabilities == .observedReadOnly }?.id
            return child.map { !supervisor.isRunning($0) && !T.usage($0).isEmpty } ?? false
        }
        guard let child else { return }
        let task = try taskOpened(by: lead)
        let delegated = rows("delegated").filter { $0["agent"] as? String == id(child) }
        try expect(delegated.count == 1 && delegated[0]["task"] as? String == task && delegated[0]["parent"] as? String == id(lead)
                   && delegated[0]["via"] as? String == "harness",
                   "the subagent needs one delegated row in the lead's task naming the lead and its harness: \(delegated)")
        let turns = rows().filter { $0["agent"] as? String == id(child) && ["working", "turnEnded"].contains($0["kind"] as? String ?? "") }
        try expect(turns.map { $0["kind"] as? String ?? "" } == ["working", "turnEnded"] && T.taskOf(turns) == [task],
                   "the subagent's start and end must be in the lead's task: \(turns)")
        let childUsage = T.usage(child)
        try expect(childUsage.count == 1 && childUsage[0]["tokens"] == nil && childUsage[0]["incomplete"] as? [String] == ["reportedByParent"]
                   && childUsage[0]["task"] as? String == task && childUsage[0]["parent"] as? String == id(lead),
                   "the subagent's usage must say it is inside its parent's result: \(childUsage)")
        // Page: the lead's result holds both models (claude-fable-5 8 / 54,846 /
        // 23,249 / 484 and claude-haiku-4-5-20251001 933 / 0 / 0 / 16): 79,536.
        let line = try line(task)
        let cells = UsageWords.cells(line)
        try expect(line.helpers == 1 && cells.how == "1 helper", "the page must count the subagent as a helper: \(line.helpers), \(cells.how)")
        try expect(words(line, .helpers) == "included in parent", "helpers' tokens must read \"included in parent\", got \(words(line, .helpers))")
        try expect(words(line, .lead) == "79,536" && words(line, .all) == "79,536" && line.fullyCounted,
                   "lead and all must be exact 79,536, fully counted: \(words(line, .lead)) / \(words(line, .all)) \(line.fullyCounted)")
        print("  delegated via harness, parent=lead; page: \(cells.how), helpers \(words(line, .helpers)), all \(words(line, .all))")
        try T.privacy(root: root)
    }

    /// A Codex lead whose provider-run child (codex-appserver-delegating-turn)
    /// reports on its own thread: a delegated row naming the lead and its
    /// harness; on the page, one helper with its own tokens.
    static func builtinCodex() async throws {
        print("run-ledger-gaps: Codex's own subagent (B6)")
        let (b, lead, root, tearDown) = try T.codexBench("gaps-builtin-codex")
        defer { tearDown() }
        try T.stage(try T.delegatingFrames(), "child", in: root)
        try await T.soloTurn(b, lead, "FRAMES-child")
        var child: AgentID?
        try await T.wait("child usage not recorded") {
            b.supervisor.runLedger.drain()
            child = b.supervisor.records.values.first { $0.parentAgentID == lead }?.id
            return child.map { !b.supervisor.isRunning($0) && T.usage($0).contains { $0["tokens"] != nil } } ?? false
        }
        guard let child else { return }
        let task = try taskOpened(by: lead)
        let delegated = rows("delegated").filter { $0["agent"] as? String == id(child) }
        try expect(delegated.count == 1 && delegated[0]["task"] as? String == task && delegated[0]["parent"] as? String == id(lead)
                   && delegated[0]["via"] as? String == "harness",
                   "the Codex child needs one delegated row naming the lead and its harness: \(delegated)")
        // The child thread: 6,425 / 26,112 / unknown / 170 = 32,707.
        let line = try line(task)
        try expect(line.helpers == 1 && words(line, .helpers) == "32,707", "page: \(line.helpers) helpers, \(words(line, .helpers))")
        print("  delegated via harness, parent=lead; page: 1 helper, \(words(line, .helpers)) tokens")
    }

    // MARK: B7, a helper's own helper

    static func nested() async throws {
        print("run-ledger-gaps: a helper's own helper (B7)")
        let b = try ManagedModeChecks.bench("ledger-gaps-nested")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try T.installClaudeDouble(b)
        let supervisor = b.supervisor
        try expect(supervisor.rename(agentID: lead, to: "Gaps lead"), "could not name the lead")
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-lead SECRET-PROMPT")), for: lead) == .accepted, "submission refused")
        try await T.wait("lead did not start") { supervisor.isRunning(lead) }
        let hc = try await delegate(b, from: lead, "hc", task: "HOLD-hc SECRET-BRIEF")
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await T.wait("lead turn did not end") { !supervisor.isRunning(lead) }
        try expect(supervisor.rename(agentID: hc, to: "Gaps helper"), "could not name hc")
        let hg = try await delegate(b, from: hc, "hg", task: "HOLD-hg FRAMES-hg SECRET-BRIEF")
        let hgRoot = checkout(b, hg, else: root)
        try T.stage(try T.claudeRun("claude-2.1.291-opus-turn.jsonl"), "hg", in: hgRoot)
        // hc's wake on hg's result quotes hg's brief, in hc's own checkout.
        for dir in Set([hgRoot.path, checkout(b, hc, else: root).path, root.path]) {
            for name in ["release-hg", "go-hg"] { try Data().write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
        try await T.wait("nested helper did not finish") {
            supervisor.runLedger.drain(); return !supervisor.isRunning(hg) && T.usage(hg).contains { $0["tokens"] != nil }
        }
        let before = T.closures()
        let report = try await WorkspaceAgentReportChecks.call(b.configuration(for: hc), "array_report", ["summary": "SECRET-REPORT"])
        try expect(!report.isError, "hc report refused: \(report.reply)")
        for dir in Set([checkout(b, hc, else: root).path, root.path]) {
            try Data().write(to: URL(fileURLWithPath: dir).appendingPathComponent("release-hc"))
        }
        try await T.wait("task did not close", timeout: 40) { supervisor.runLedger.drain(); return T.closures() > before }
        try await T.wait("everyone settled") { !supervisor.isRunning(hc) && !supervisor.isRunning(lead) }
        supervisor.runLedger.drain()

        let task = try taskOpened(by: lead)
        let delegated = rows("delegated").filter { $0["agent"] as? String == id(hg) }
        try expect(delegated.count == 1 && delegated[0]["task"] as? String == task && delegated[0]["parent"] as? String == id(hc)
                   && delegated[0]["part"] as? String == id(hg) && delegated[0]["via"] == nil,
                   "the nested helper needs one delegated row in the lead's task, its part, naming its parent helper: \(delegated)")
        let order = rows().filter { $0["task"] as? String == task }.map { $0["kind"] as? String ?? "" }
        guard let opened = order.firstIndex(of: "delegated"), let closed = order.firstIndex(of: "taskClosed") else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: no delegated or close row: \(order)")
        }
        try expect(opened < closed && order.filter { $0 == "taskClosed" }.count == 1, "task rows out of order: \(order)")
        // Page: hc and hg are helpers; hg's turn (claude-2.1.291-opus-turn,
        // 2 / 10,695 / 11,239 / 124 = 22,060) is the only helper turn with usage.
        let line = try line(task)
        try expect(line.helpers == 2 && UsageWords.cells(line).how == "2 helpers", "page: \(line.helpers) helpers")
        try expect(words(line, .helpers) == "at least 22,060", "helpers' tokens: \(words(line, .helpers))")
        print("  nested delegated row: parent=hc, part=hg, lead's task; page: 2 helpers, \(words(line, .helpers))")
        try T.privacy(root: root)
    }

    // MARK: B8, active time stops at the close

    static func activeTime() async throws {
        print("run-ledger-gaps: the wake that reads results is the task's; active time stops at the close (B8)")
        let b = try ManagedModeChecks.bench("ledger-gaps-active")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        let tail = 1.5
        let (task, _) = try await fanOutAndClose(b, lead, root, tail: tail)
        let all = rows()
        guard let close = all.firstIndex(where: { $0["kind"] as? String == "taskClosed" && $0["task"] as? String == task }) else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: no close row")
        }
        let leadTurns = all.filter { $0["agent"] as? String == id(lead) && $0["task"] as? String == task }
            .compactMap { row -> String? in ["working", "turnEnded"].contains(row["kind"] as? String ?? "") ? row["kind"] as? String : nil }
        let lastLeadEnd = all.lastIndex { $0["kind"] as? String == "turnEnded" && $0["agent"] as? String == id(lead) && $0["task"] as? String == task }
        let before = try line(task)
        guard let answer = before.timeToAnswer, let active = before.activeTime else {
            throw WorkspaceAgentReportChecks.Failure(description: "run-ledger-gaps: time to answer \(String(describing: before.timeToAnswer)), active \(String(describing: before.activeTime))")
        }
        print(String(format: "  page: time to answer %.2f s, active %.2f s; lead turn rows in the task: %@", answer, active, leadTurns.joined(separator: ",")))
        try expect(leadTurns == ["working", "turnEnded", "working", "turnEnded"],
                   "the lead's first turn and its wake on the helper's result must both be in the task: \(leadTurns)")
        try expect(lastLeadEnd.map { $0 < close } == true, "the task must close when the wake ends, not before")
        try expect(answer >= tail && active <= answer + 0.001,
                   String(format: "time to answer %.2f s must cover the helper's %.1f s and the wake; active %.2f s must not exceed it", answer, tail, active))

        // A lead turn after the close that no helper result started: not the task's.
        let thread = AgentSupervisor.threadId(for: lead), turn = "after-close-\(UUID().uuidString)"
        b.supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: lead)
        try await Task.sleep(nanoseconds: 300_000_000)
        b.supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: lead)
        b.supervisor.runLedger.drain()
        let later = rows().filter { ($0["source"] as? String)?.contains(turn) == true || $0["turn"] as? String == turn }
        try expect(!later.isEmpty && later.allSatisfy { $0["task"] as? String == noTask },
                   "a lead turn after the close that is not a helper's wake must be in no task: \(later.map { "\($0["kind"] ?? "") \($0["task"] ?? "")" })")
        let after = try line(task)
        try expect(after.activeTime == before.activeTime && after.timeToAnswer == before.timeToAnswer && after.tokens == before.tokens,
                   "the later turn changed the closed task's figures")
        print("  a later non-wake turn: no task; the task's figures unchanged")
        try T.privacy(root: root)
    }

    // MARK: B9, agent-to-agent turn after the close

    static func afterClose() async throws {
        print("run-ledger-gaps: an agent message after the close, and the late helper's wake (B9)")
        let b = try ManagedModeChecks.bench("ledger-gaps-after-close")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        let (task, helper) = try await fanOutAndClose(b, lead, root, tail: 0)
        let supervisor = b.supervisor
        let before = try line(task), beforeUsage = T.usage(helper).count, untaskedBefore = try page().untasked.known
        let woken = T.usage(lead).count, closeRows = rows().count
        // The lead messages its helper; the helper's turn replays
        // claude-2.1.291-opus-turn: 2 / 10,695 / 11,239 / 124 = 22,060. Its result
        // then wakes the lead: a late helper result for the closed task.
        try T.stage(try T.claudeRun("claude-2.1.291-opus-turn.jsonl"), "hz", in: checkout(b, helper, else: root))
        let sent = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_message_agent", [
            "agentId": id(helper), "text": "FRAMES-hz", "idempotencyKey": UUID().uuidString])
        try expect(!sent.isError, "the message was refused: \(sent.reply)")
        try await T.wait("the helper's message turn left no usage") {
            supervisor.runLedger.drain()
            return !supervisor.isRunning(helper) && T.usage(helper).dropFirst(beforeUsage).contains { $0["tokens"] != nil }
        }
        try await T.wait("the helper's result did not wake the lead", timeout: 40) { supervisor.runLedger.drain(); return T.usage(lead).count > woken }
        try await T.wait("lead settled") { !supervisor.isRunning(lead) }
        supervisor.runLedger.drain()
        let added = Array(T.usage(helper).dropFirst(beforeUsage)).filter { $0["tokens"] != nil }
        try expect(added.count == 1 && added[0]["task"] as? String == noTask,
                   "a turn an agent message started after the close must not be charged to the closed task: \(added.map { $0["task"] ?? "-" })")
        try T.expectRow(added.first, "message turn", model: "claude-opus-5-5", source: "cli", T.counts(2, 10_695, 11_239, 124), incomplete: ["noTask"])
        let wake = rows().dropFirst(closeRows).filter { $0["kind"] as? String == "working" && $0["agent"] as? String == id(lead) }
        try expect(wake.count == 1 && wake[0]["task"] as? String == task && wake[0]["flag"] as? String == "lateHelperWake",
                   "the lead's wake on a late helper result must rejoin the task, flagged lateHelperWake: \(wake.map { "\($0["task"] ?? "-") \($0["flag"] ?? "-")" })")
        let after = try line(task)
        try expect(after.lateHelperWakes == 1 && words(after, .helpers) == words(before, .helpers),
                   "page: late wakes \(after.lateHelperWakes); helpers \(words(before, .helpers)) → \(words(after, .helpers))")
        let untasked = try page().untasked.known - untaskedBefore
        try expect(untasked >= 22_060, "the page's \"not in any task\" line must hold the message turn: +\(untasked)")
        print("  message turn: no task; late wake rejoined the task; helpers still \(words(after, .helpers))")
        try T.privacy(root: root)
    }

    // MARK: Hook rows follow the open task

    /// A hook during the lead's open task is that task's; one during a lead
    /// turn after the close that no helper result started is in no task.
    static func hooksAfterClose() async throws {
        print("run-ledger-gaps: hook rows follow the task open at the time")
        let b = try ManagedModeChecks.bench("ledger-gaps-hooks")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try T.installClaudeDouble(b)
        let supervisor = b.supervisor, before = T.closures()
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-hk SECRET-PROMPT")), for: lead) == .accepted, "submission refused")
        try await T.wait("lead did not start") { supervisor.isRunning(lead) }
        try await LeadCheckoutChecks.postHook(b, lead, ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "SECRET-HOOK"])
        try Data().write(to: root.appendingPathComponent("release-hk"))
        try await T.wait("task did not close") { supervisor.runLedger.drain(); return !supervisor.isRunning(lead) && T.closures() > before }
        let task = try taskOpened(by: lead)
        let thread = AgentSupervisor.threadId(for: lead), turn = "hooks-after-\(UUID().uuidString)"
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: lead)
        try await LeadCheckoutChecks.postHook(b, lead, ["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash",
                                                        "tool_input": ["command": "SECRET-HOOK"]])
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: lead)
        supervisor.runLedger.drain()
        let hooks = rows("hook").filter { $0["agent"] as? String == id(lead) }
        try expect(hooks.map { $0["hook"] as? String ?? "" } == ["UserPromptSubmit", "PreToolUse"], "hook rows: \(hooks)")
        try expect(hooks[0]["task"] as? String == task, "a hook during the open task must be that task's: \(hooks[0]["task"] ?? "-")")
        try expect(hooks[1]["task"] as? String == noTask,
                   "a hook in a turn after the close must be in no task, not the agent's last task: \(hooks[1]["task"] ?? "-")")
        print("  hook during the task: the task; hook after the close: no task")
        try T.privacy(root: root)
    }

    // MARK: B9, Codex frames after the main turn

    /// The telemetry Codex double, plus: an `_after` frame may carry
    /// `_delayMs`, slept before it is sent.
    static func installCodexDouble(_ b: Bench) throws {
        try T.installCodexDouble(b)
        let cli = b.binDir.appendingPathComponent("codex")
        var script = try String(contentsOf: cli, encoding: .utf8)
        let anchor = "        for frame in after: emit(frame)"
        try expect(script.contains(anchor), "codex double changed shape")
        script = script.replacingOccurrences(of: anchor, with: "        for frame in after: time.sleep(frame.pop('_delayMs', 0) / 1000.0); emit(frame)")
        try script.write(to: cli, atomically: true, encoding: .utf8)
    }
    static func delayed(_ frame: [String: Any], ms: Int) -> [String: Any] {
        var frame = T.after(frame); frame["_delayMs"] = ms; return frame
    }

    /// The main turn's last total arrives 300 ms after its `turn/completed`.
    /// Turn 1 must be charged f2 in full (6,134 / 26,112 / unknown / 153 =
    /// 32,399): f1 on time and f2 - f1 as a late row of the same turn.
    static func codexTrailing() async throws {
        print("run-ledger-gaps: Codex frames after the main turn (B9)")
        let (b, lead, root, tearDown) = try T.codexBench("gaps-codex-trailing")
        defer { tearDown() }
        try installCodexDouble(b)
        let f = try T.singleAgent()
        try T.stage([f[0], delayed(f[1], ms: 300)], "tr", in: root)
        try await T.soloTurn(b, lead, "FRAMES-tr")
        let task = try taskOpened(by: lead)
        do {
            try await T.wait("the frame sent after the turn was not recorded", timeout: 4) {
                b.supervisor.runLedger.drain(); return T.total(T.usage(lead)) == T.counts(6_134, 26_112, nil, 153)
            }
        } catch {
            throw WorkspaceAgentReportChecks.Failure(description: "\(error): turn total \(T.describe(T.total(T.usage(lead)))) from \(T.usage(lead).count) row(s)")
        }
        let rows = T.usage(lead)
        try expect(Set(rows.compactMap { $0["turn"] as? String }).count == 1 && T.taskOf(rows) == [task]
                   && rows.filter({ $0["late"] as? Bool == true }).count == 1,
                   "one on-time and one late row, one turn, one task: \(rows)")
        let line = try line(task)
        try expect(words(line, .all) == "32,399" && line.fullyCounted, "page: \(words(line, .all)), fully counted \(line.fullyCounted)")
        print("  turn 1: \(T.describe(T.total(rows))); page: \(words(line, .all)), fully counted")
    }

    /// The main turn's next total is still unsent when the drain's bound ends:
    /// the turn is marked incomplete, and the page reads "at least".
    static func codexDrainBound() async throws {
        print("run-ledger-gaps: Codex drain bound (B9)")
        let (b, lead, root, tearDown) = try T.codexBench("gaps-codex-bound")
        defer { tearDown() }
        try installCodexDouble(b)
        let f = try T.singleAgent()
        // f1 in full: 5,039 / 11,008 / unknown / 91 = 16,138.
        try T.stage([f[0], delayed(f[1], ms: 3 * Int(CodexAgentRunner.trailingFrameBound * 1000))], "bd", in: root)
        try await T.soloTurn(b, lead, "FRAMES-bd")
        let task = try taskOpened(by: lead)
        do {
            try await T.wait("the turn was not marked incomplete", timeout: CodexAgentRunner.trailingFrameBound + 4) {
                b.supervisor.runLedger.drain()
                return T.usage(lead).contains { ($0["incomplete"] as? [String])?.contains("trailingFramesCut") == true }
            }
        } catch {
            throw WorkspaceAgentReportChecks.Failure(description: "\(error): rows \(T.usage(lead))")
        }
        let marked = T.usage(lead).filter { ($0["incomplete"] as? [String])?.contains("trailingFramesCut") == true }
        try expect(marked.count == 1 && marked[0]["tokens"] == nil && marked[0]["late"] as? Bool == true
                   && marked[0]["task"] as? String == task && marked[0]["turn"] as? String == T.usage(lead).first?["turn"] as? String,
                   "one late unknown row for the turn, in its task: \(marked)")
        let line = try line(task)
        try expect(words(line, .all) == "at least 16,138" && !line.fullyCounted, "page: \(words(line, .all)), fully counted \(line.fullyCounted)")
        print("  marked trailingFramesCut; page: \(words(line, .all))")
    }
}
