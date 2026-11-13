import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/116` part 14 step 1: tokens by type, per task, in the run ledger.
/// Each scenario drives the production supervisor: the composer's `accept`,
/// `array_delegate` and `array_report` through the production MCP binary, and
/// the production Claude and Codex runners and translators over CLI doubles that
/// replay frames copied from the committed captures. Expected figures are worked
/// by hand from those captures, beside each assertion.
///
/// Storage: `makeBench` refuses unless CONTINUUM_APP_SUPPORT is already a
/// temporary directory, then creates and owns its own; settings live in a
/// check-owned suite. Prints timings and asserts nothing about time.
@MainActor
enum RequestTelemetryChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: " + message) }
    }

    /// The evidence check's Claude double, plus: a replayed `result` frame is held
    /// until the turn's HOLD is released, in place of the double's own result
    /// (which carries no usage).
    static func claudeDouble() throws -> String {
        var script = HelperEvidenceChecks.claude
        let edits = [
            ("    if o.get('type') != 'user': continue\n", "    if o.get('type') != 'user': continue\n    deferred = []\n"),
            ("lambda frame: print(json.dumps(frame).replace('SESSION', sid), flush=True)",
             "lambda frame: deferred.append(json.dumps(frame).replace('SESSION', sid)) if frame.get('type') == 'result'"
             + " else print(json.dumps(frame).replace('SESSION', sid), flush=True)"),
            ("    emit({'type':'result','subtype':'success','is_error':False,'session_id':sid,'result':'done','duration_ms':1,'num_turns':1})",
             "    for frame in deferred: print(frame, flush=True)\n"
             + "    if not deferred: emit({'type':'result','subtype':'success','is_error':False,'session_id':sid,'result':'done','duration_ms':1,'num_turns':1})"),
        ]
        for (anchor, replacement) in edits {
            try expect(script.contains(anchor), "claude double changed shape")
            script = script.replacingOccurrences(of: anchor, with: replacement)
        }
        return script
    }

    static func installClaudeDouble(_ b: Bench) throws {
        let cli = b.binDir.appendingPathComponent("claude")
        try claudeDouble().write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    /// The evidence check's Codex double, plus: a fresh turn id per turn, as the
    /// real app-server sends (its fixed `fixture-turn` makes every later turn's
    /// end a replay of the first); `TURN` in a frame becomes that id; a frame
    /// marked `_after` is sent after the turn's `turn/completed`.
    static func installCodexDouble(_ b: Bench) throws {
        var script = try HelperEvidenceChecks.codex()
        let edits = [
            ("        result = dict(turn=dict(id='fixture-turn'))\n",
             "        turn_id = 'fixture-turn-' + str(uuid.uuid4())\n        after = []\n        result = dict(turn=dict(id=turn_id))\n"),
            ("turn=dict(id='fixture-turn'))))", "turn=dict(id=turn_id))))"),
            ("lambda frame: emit(json.loads(json.dumps(frame).replace('SESSION', session_id)))",
             "lambda frame: (lambda f: after.append(f) if f.pop('_after', False) else emit(f))("
             + "json.loads(json.dumps(frame).replace('SESSION', session_id).replace('TURN', turn_id)))"),
            ("        emit(dict(method='turn/completed', params=dict(threadId=session_id, turn=dict(id='fixture-turn',status='completed'))))",
             "        emit(dict(method='turn/completed', params=dict(threadId=session_id, turn=dict(id=turn_id,status='completed'))))\n"
             + "        for frame in after: emit(frame)"),
        ]
        for (anchor, replacement) in edits {
            try expect(script.contains(anchor), "codex double changed shape: \(anchor.prefix(60))")
            script = script.replacingOccurrences(of: anchor, with: replacement)
        }
        let cli = b.binDir.appendingPathComponent("codex")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    static func capture(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: "Sources/ContinuumRevivedCoreChecks/Fixtures/" + name, encoding: .utf8)
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    /// A recorded Claude run, every frame but its `system/init` (the double
    /// sends its own), in the capture's order.
    static func claudeRun(_ name: String) throws -> [[String: Any]] {
        try capture(name).filter { !($0["type"] as? String == "system" && $0["subtype"] as? String == "init") }
            .map { frame in var frame = frame; if frame["session_id"] != nil { frame["session_id"] = "SESSION" }; return frame }
    }
    /// The recorded `thread/tokenUsage/updated` frames of a Codex capture, on the
    /// double's thread and turn, with their provider times.
    static func codexUsage(_ name: String) throws -> [[String: Any]] {
        try capture(name).filter { $0["method"] as? String == "thread/tokenUsage/updated" }.map { frame in
            var frame = frame, params = frame["params"] as? [String: Any] ?? [:]
            (params["threadId"], params["turnId"]) = ("SESSION", "TURN"); frame["params"] = params
            return frame
        }
    }
    static func after(_ frame: [String: Any]) -> [String: Any] { var frame = frame; frame["_after"] = true; return frame }
    static func stage(_ frames: [[String: Any]], _ name: String, in root: URL) throws {
        let lines = try frames.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: root.appendingPathComponent("frames-\(name).jsonl"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("go-\(name)"))
    }

    static func ledgerURL() -> URL {
        AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
    }
    static func usage(_ agent: AgentID) -> [[String: Any]] { ManagedRunLedgerChecks.rows(ledgerURL(), "usage", agent: agent) }
    static func tokens(_ row: [String: Any]) -> [String: Int] { (row["tokens"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int } }
    static func counts(_ uncached: Int, _ read: Int, _ write: Int?, _ output: Int) -> [String: Int] {
        var value = ["uncachedInput": uncached, "cacheRead": read, "output": output]
        value["cacheWrite"] = write
        return value
    }
    /// Per-type sum of measured rows; a type any row lacks is unknown in the sum.
    static func total(_ rows: [[String: Any]]) -> [String: Int] {
        let measured = rows.filter { $0["tokens"] != nil }.map(tokens)
        guard let first = measured.first else { return [:] }
        return first.keys.reduce(into: [String: Int]()) { out, key in
            if measured.allSatisfy({ $0[key] != nil }) { out[key] = measured.reduce(0) { $0 + ($1[key] ?? 0) } }
        }
    }
    /// One on-time row: its model and where it came from, exact counters (an
    /// absent key is unknown) and flags.
    static func expectRow(_ row: [String: Any]?, _ label: String, model: String?, source: String?, _ expected: [String: Int]?,
                          incomplete: [String]? = nil) throws {
        guard let row else { throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: \(label): no usage row") }
        let got = row["tokens"] == nil ? nil : tokens(row)
        try expect(row["model"] as? String == model && row["modelSource"] as? String == source && got == expected
                   && row["incomplete"] as? [String] == incomplete && row["late"] == nil,
                   "\(label): expected \(model ?? "no model") (\(source ?? "-")) \(expected.map { "\($0)" } ?? "unknown") incomplete=\(incomplete ?? []), got \(row)")
        print("  \(label): \(model ?? "model unknown") [\(source ?? "-")] \(expected.map(describe) ?? "tokens unknown")"
              + (incomplete.map { " incomplete=\($0)" } ?? ""))
    }
    static func describe(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
    static func closures() -> Int {
        let rows = ManagedRunLedgerChecks.rows(ledgerURL())
        return rows.filter { ["taskClosed", "taskInterrupted"].contains($0["kind"] as? String ?? "") }.count
    }
    static func wait(_ message: String, timeout: TimeInterval = 30, _ condition: @escaping @MainActor () -> Bool) async throws {
        try await AgentPresenceChecks.eventually("request-telemetry: " + message, timeout: timeout, condition)
    }
    /// One submission to a lead with no helpers; returns once its task closed.
    static func soloTurn(_ b: Bench, _ lead: AgentID, _ prompt: String) async throws {
        let supervisor = b.supervisor, before = closures()
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt(prompt + " SECRET-PROMPT")), for: lead) == .accepted, "submission refused")
        try await wait("task did not close after \(prompt)") {
            supervisor.runLedger.drain(); return !supervisor.isRunning(lead) && closures() > before
        }
    }
    static func taskOf(_ rows: [[String: Any]]) -> Set<String> { Set(rows.compactMap { $0["task"] as? String }) }
    static func debugInputs(_ root: URL) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("inputs-") }
        return names.map { name in
            let lines = ((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n")
            return name + ": " + lines.map { line in
                let tags = ["HOLD-lead", "HOLD-hc", "HOLD-hx", "HOLD-hg", "FRAMES-lead", "FRAMES-hc", "FRAMES-hg", "array-agent-message"]
                    .filter { line.contains($0) }
                return "{" + tags.joined(separator: " ") + " len=\(line.count)}"
            }.joined(separator: " ")
        }.joined(separator: " | ")
    }

    static func run() async throws {
        let only = ProcessInfo.processInfo.environment["CONTINUUM_TELEMETRY_CASE"]
        let cases: [(String, () async throws -> Void)] = [
            ("lead", leadAlone), ("free", freeSolo), ("helpers", leadWithHelpers), ("codex", codexLead),
            ("codex-off", codexOffThenOn), ("codex-relaunch", codexRelaunch), ("codex-late", codexLate),
            ("codex-child", codexChild), ("empty-model", emptyModel),
        ]
        for (name, body) in cases where only == nil || only == name { try await body() }
        print("Request telemetry passed")
    }

    /// A Claude lead alone: one turn; a turn with no usage; recording off; on
    /// again; one result delivered twice.
    static func leadAlone() async throws {
        print("request-telemetry: lead alone")
        let b = try ManagedModeChecks.bench("request-telemetry-lead")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try installClaudeDouble(b)

        // claude-2.1.291-opus-turn: one request, its assistant frame sent twice
        // (same message id) and one result. modelUsage: claude-opus-5-5 2 / 10,695
        // / 11,239 / 124. The two frames sum to 4 / 21,390 / 22,478 if both count,
        // and the result's own usage is 2 / 10,695 / 11,239: counted once, they agree.
        let opus = try claudeRun("claude-2.1.291-opus-turn.jsonl")
        try stage(opus, "opus", in: root)
        try await soloTurn(b, lead, "FRAMES-opus")
        var rows = usage(lead)
        try expect(rows.count == 1, "one lead turn must give one usage row, got \(rows.count)")
        try expectRow(rows.first, "one lead turn", model: "claude-opus-5-5", source: "cli", counts(2, 10_695, 11_239, 124))
        try expect(rows[0]["harness"] as? String == "Claude Code" && rows[0]["part"] == nil && rows[0]["parent"] == nil
                   && (rows[0]["turn"] as? String)?.isEmpty == false, "lead row identity: \(rows[0])")
        let all = ManagedRunLedgerChecks.rows(ledgerURL())
        guard let usageIndex = all.firstIndex(where: { $0["kind"] as? String == "usage" }),
              let closeIndex = all.firstIndex(where: { $0["kind"] as? String == "taskClosed" }) else {
            throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: no usage or close row")
        }
        try expect(usageIndex < closeIndex && all[closeIndex]["task"] as? String == rows[0]["task"] as? String,
                   "the turn's usage must be in its task before the task closes")
        let opened = ManagedRunLedgerChecks.rows(ledgerURL(), "taskOpened")
        try expect(opened.first?["mode"] as? String == "managed", "a Managed lead's task must say so: \(opened)")

        // The double's own result carries no usage block: unknown, never zero.
        try await soloTurn(b, lead, "plain")
        rows = usage(lead)
        try expectRow(rows.last, "turn with no usage", model: ManagedModeChecks.model, source: "record", nil, incomplete: ["noUsage"])

        // Recording off: the next task's usage is not recorded and nothing is deleted.
        let before = try Data(contentsOf: ledgerURL())
        ManagedSettingChecks.write(AgentTokenTelemetryConfig.enabledKey, false, b)
        try stage(try claudeRun("claude-websearch-turn.jsonl"), "web", in: root)
        try await soloTurn(b, lead, "FRAMES-web")
        let after = try Data(contentsOf: ledgerURL())
        try expect(usage(lead).count == rows.count, "recording off still recorded usage: \(usage(lead).count - rows.count) new rows")
        try expect(after.count > before.count && after.prefix(before.count) == before, "recording off changed earlier ledger bytes")
        try expect(ManagedRunLedgerChecks.rows(ledgerURL(), "taskClosed").count == 3, "the task itself must still be recorded")
        print("  recording off: task recorded, no usage row, earlier bytes intact")

        // On again. claude-subagent-turn's modelUsage includes the subagent:
        // claude-fable-5 8 / 54,846 / 23,249 / 484 and claude-haiku-4-5-20251001
        // 933 / 0 / 0 / 16. Main-conversation frames (two ids, three and one
        // copies) sum to 4 / 42,081 / 9,586, the result's own usage.
        ManagedSettingChecks.write(AgentTokenTelemetryConfig.enabledKey, true, b)
        try stage(try claudeRun("claude-subagent-turn.jsonl"), "sub", in: root)
        try await soloTurn(b, lead, "FRAMES-sub")
        let onAgain = Array(usage(lead).dropFirst(rows.count))
        try expect(onAgain.count == 2 && taskOf(onAgain).count == 1, "on again: expected two model rows in one task, got \(onAgain)")
        try expectRow(onAgain.first { $0["model"] as? String == "claude-fable-5" }, "subagent run, main model",
                      model: "claude-fable-5", source: "cli", counts(8, 54_846, 23_249, 484))
        try expectRow(onAgain.first { $0["model"] as? String == "claude-haiku-4-5-20251001" }, "subagent run, side model",
                      model: "claude-haiku-4-5-20251001", source: "cli", counts(933, 0, 0, 16))

        // The same result delivered twice (same session and uuid): counted once.
        rows = usage(lead)
        // A fresh result id: the capture's own was counted on the first turn.
        let fresh = UUID().uuidString.lowercased()
        let renamed = opus.map { frame -> [String: Any] in
            var frame = frame; if frame["type"] as? String == "result" { frame["uuid"] = fresh }; return frame
        }
        try stage(renamed + renamed.filter { $0["type"] as? String == "result" }, "twice", in: root)
        try await soloTurn(b, lead, "FRAMES-twice")
        try await Task.sleep(nanoseconds: 500_000_000)
        b.supervisor.runLedger.drain()
        let twice = Array(usage(lead).dropFirst(rows.count))
        try expect(twice.count == 1, "a result delivered twice must give one row, got \(twice)")
        try expectRow(twice.first, "same result twice", model: "claude-opus-5-5", source: "cli", counts(2, 10_695, 11_239, 124))
        // The runner stops at the first result, so the stream above cannot show
        // the ledger's own guard. Deliver one result's usage twice inside one
        // turn through the supervisor's event fold.
        rows = usage(lead)
        let thread = AgentSupervisor.threadId(for: lead), turn = "twice-\(UUID().uuidString)"
        var repeated = TokenUsageSnapshot(inputTokens: 21_936, outputTokens: 124, totalCostUsd: nil,
                                          accountingObservationID: "claude-result|twice|\(UUID().uuidString)")
        repeated.typedCountsByModel = ["claude-opus-5-5": .init(uncachedInput: 2, cacheRead: 10_695, cacheWrite: 11_239, output: 124)]
        repeated.accountingTurn = turn
        b.supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: lead)
        b.supervisor.qaDeliver(.tokenUsageUpdated(threadId: thread, snapshot: repeated), to: lead)
        b.supervisor.qaDeliver(.tokenUsageUpdated(threadId: thread, snapshot: repeated), to: lead)
        b.supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: lead)
        b.supervisor.runLedger.drain()
        let delivered = Array(usage(lead).dropFirst(rows.count))
        try expect(delivered.count == 1, "one result's usage delivered twice must give one row, got \(delivered)")
        // No submission opened a task for this turn and the last one closed, so
        // it is in no task (`.plans/116` gap 9).
        try expectRow(delivered.first, "same usage delivered twice", model: "claude-opus-5-5", source: "cli", counts(2, 10_695, 11_239, 124),
                      incomplete: ["noTask"])
        try privacy(root: root)
        try await timing(b, lead)
    }

    /// A top-level agent that is not in Managed mode: a human submission opens
    /// its task, marked free, and its usage is recorded there.
    static func freeSolo() async throws {
        print("request-telemetry: free agent")
        let b = try ManagedModeChecks.bench("request-telemetry-free")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try installClaudeDouble(b)
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, false, b)
        try expect(b.supervisor.effectiveMode(for: lead) == .free, "agent is still Managed")
        try stage(try claudeRun("claude-2.1.291-opus-turn.jsonl"), "opus", in: root)
        try await soloTurn(b, lead, "FRAMES-opus")
        let opened = ManagedRunLedgerChecks.rows(ledgerURL(), "taskOpened", agent: lead)
        try expect(opened.count == 1 && opened[0]["mode"] as? String == "free", "a free agent's submission must open a free task: \(opened)")
        let rows = usage(lead)
        try expect(rows.count == 1 && taskOf(rows) == taskOf(opened), "free agent usage must sit in its task: \(rows)")
        try expectRow(rows.first, "free agent turn", model: "claude-opus-5-5", source: "cli", counts(2, 10_695, 11_239, 124))
        try privacy(root: root)
    }

    /// A Claude lead delegating one Claude and one Codex helper in one task; the
    /// Claude helper delegates a helper of its own.
    static func leadWithHelpers() async throws {
        print("request-telemetry: lead with two helpers and a nested helper")
        let b = try ManagedModeChecks.bench("request-telemetry-helpers")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try installClaudeDouble(b)
        try installCodexDouble(b)
        let supervisor = b.supervisor
        func leadInputs() -> Int {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.filter { $0.hasPrefix("inputs-") }
                .compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
                .map { $0.split(separator: "\n").count }.reduce(0, +)
        }
        func delegate(from parent: AgentID, _ name: String, harness: AgentHarness, model: String) async throws -> AgentID {
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: parent), "array_delegate", [
                "task": "HOLD-\(name) FRAMES-\(name) SECRET-BRIEF", "title": "Telemetry \(name)",
                "harness": harness == .codex ? "Codex" : "Claude Code", "model": model, "idempotencyKey": UUID().uuidString])
            guard !reply.isError, let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String,
                  let uuid = UUID(uuidString: raw) else {
                throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: \(name) delegation failed: \(reply.reply)")
            }
            return AgentID(rawValue: uuid)
        }

        // A delegated brief's envelope carries the lead's name; a name taken from
        // this prompt would hand the helper doubles the lead's markers first.
        try expect(supervisor.rename(agentID: lead, to: "Telemetry lead"), "could not name the lead")
        // The lead's own turn: claude-websearch-turn, held open while it delegates.
        // modelUsage: claude-haiku-4-5-20251001 11,002 / 72,550 / 9,836 / 832.
        try stage(try claudeRun("claude-websearch-turn.jsonl"), "lead", in: root)
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-lead HOLD-lead SECRET-PROMPT")), for: lead) == .accepted,
                   "lead submission refused")
        try await wait("lead did not start") { supervisor.isRunning(lead) }
        var helpers: [String: AgentID] = [:]
        helpers["hc"] = try await delegate(from: lead, "hc", harness: .claudeCode, model: ManagedModeChecks.model)
        helpers["hx"] = try await delegate(from: lead, "hx", harness: .codex, model: ManagedCodexChecks.model)
        guard let hc = helpers["hc"], let hx = helpers["hx"] else { return }
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await wait("lead turn did not end") { !supervisor.isRunning(lead) }

        // The Claude helper's own helper runs claude-2.1.291-opus-turn to the end:
        // claude-opus-5-5 2 / 10,695 / 11,239 / 124, charged to the lead's task.
        // Its envelope carries hc's name, which must not hold hc's markers.
        try expect(supervisor.rename(agentID: hc, to: "Telemetry helper"), "could not name hc")
        let nested = try await delegate(from: hc, "hg", harness: .claudeCode, model: ManagedModeChecks.model)
        let nestedRoot = URL(fileURLWithPath: supervisor.records[nested]?.checkoutRoot ?? root.path)
        try stage(try claudeRun("claude-2.1.291-opus-turn.jsonl"), "hg", in: nestedRoot)
        try Data().write(to: nestedRoot.appendingPathComponent("release-hg"))
        do {
            try await wait("nested helper did not finish") {
                supervisor.runLedger.drain()
                return !supervisor.isRunning(nested) && usage(nested).contains { $0["tokens"] != nil }
            }
        } catch {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: nestedRoot.path)) ?? []).sorted().joined(separator: ",")
            throw WorkspaceAgentReportChecks.Failure(description: "\(error) running=\(supervisor.isRunning(nested)) mode=\(supervisor.effectiveMode(for: nested)) sameRoot=\(nestedRoot == root) rows=\(usage(nested)) files=[\(files)] inputs=\(debugInputs(nestedRoot))")
        }

        // Claude helper: claude-subagent-turn (figures above). Codex helper: the
        // four cumulative totals of codex-appserver-single-agent on a thread this
        // process started: last total 64,996 in, 57,344 of it cached, 313 out →
        // 7,652 / 57,344 / unknown / 313, never the 161,820 / 826 their sum gives.
        let frames = ["hc": try claudeRun("claude-subagent-turn.jsonl"), "hx": try codexUsage("codex-appserver-single-agent.jsonl")]
        for (name, helper) in [("hc", hc), ("hx", hx)] {
            let helperRoot = URL(fileURLWithPath: supervisor.records[helper]?.checkoutRoot ?? root.path)
            try stage(frames[name] ?? [], name, in: helperRoot)
            try await wait("\(name) frames not replayed") {
                FileManager.default.fileExists(atPath: helperRoot.appendingPathComponent("replayed-\(name).jsonl").path)
            }
            let report = try await WorkspaceAgentReportChecks.call(b.configuration(for: helper), "array_report", [
                "summary": "SECRET-REPORT", "checks": [["what": "SECRET-CHECK", "result": "pass"]]])
            try expect(!report.isError, "\(name) report refused: \(report.reply)")
            let before = leadInputs()
            if name == "hx" { try Data().write(to: URL(fileURLWithPath: ManagedCodexChecks.log(b).path + ".release")) }
            else { try Data().write(to: helperRoot.appendingPathComponent("release-\(name)")) }
            // The lead's wake quotes the brief, so its double waits on the same names.
            try Data().write(to: root.appendingPathComponent("release-\(name)"))
            try Data().write(to: root.appendingPathComponent("go-\(name)"))
            do { try await wait("\(name) result did not reach the lead", timeout: 40) { leadInputs() > before } }
            catch {
                throw WorkspaceAgentReportChecks.Failure(description: "\(error) lead running=\(supervisor.isRunning(lead)) helper running=\(supervisor.isRunning(helper)) before=\(before) now=\(leadInputs()) inputs=\(debugInputs(root))")
            }
            try await wait("lead did not settle after \(name)") { !supervisor.isRunning(lead) && !supervisor.isRunning(helper) }
        }
        try await wait("helpers settled") { !supervisor.isRunning(hc) && !supervisor.isRunning(nested) && !supervisor.isRunning(lead) }
        supervisor.runLedger.drain()

        let leadRows = usage(lead), claudeRows = usage(hc), codexRows = usage(hx), nestedRows = usage(nested)
        let task = taskOf(leadRows)
        try expect(task.count == 1 && taskOf(claudeRows) == task && taskOf(codexRows) == task && taskOf(nestedRows) == task,
                   "lead and helpers at any depth must be one task: \(taskOf(leadRows)) \(taskOf(claudeRows)) \(taskOf(codexRows)) \(taskOf(nestedRows))")
        let leadMeasured = leadRows.filter { $0["tokens"] != nil }
        try expect(leadMeasured.count == 1, "lead: one measured turn expected, got \(leadMeasured)")
        try expectRow(leadMeasured.first, "lead turn", model: "claude-haiku-4-5-20251001", source: "cli", counts(11_002, 72_550, 9_836, 832))
        // Each wake turn's double result carries no usage: unknown, never zero.
        for (index, row) in leadRows.filter({ $0["tokens"] == nil }).enumerated() {
            try expectRow(row, "lead wake \(index + 1)", model: ManagedModeChecks.model, source: "record", nil, incomplete: ["noUsage"])
        }
        let claudeMeasured = claudeRows.filter { $0["tokens"] != nil }
        try expect(claudeMeasured.count == 2 && codexRows.filter({ $0["tokens"] != nil }).count == 1,
                   "helper rows: claude \(claudeRows), codex \(codexRows)")
        try expectRow(claudeMeasured.first { $0["model"] as? String == "claude-fable-5" }, "Claude helper, main model",
                      model: "claude-fable-5", source: "cli", counts(8, 54_846, 23_249, 484))
        try expectRow(claudeMeasured.first { $0["model"] as? String == "claude-haiku-4-5-20251001" }, "Claude helper, side model",
                      model: "claude-haiku-4-5-20251001", source: "cli", counts(933, 0, 0, 16))
        try expectRow(codexRows.first { $0["tokens"] != nil }, "Codex helper", model: ManagedCodexChecks.model, source: "record",
                      counts(7_652, 57_344, nil, 313))
        let nestedMeasured = nestedRows.filter { $0["tokens"] != nil }
        try expect(nestedMeasured.count == 1, "nested helper: one measured row, got \(nestedRows)")
        try expectRow(nestedMeasured.first, "nested helper", model: "claude-opus-5-5", source: "cli", counts(2, 10_695, 11_239, 124))
        for (name, helper, rows, harness) in [("hc", hc, claudeRows, "Claude Code"), ("hx", hx, codexRows, "Codex")] {
            try expect(rows.allSatisfy { $0["part"] as? String == helper.rawValue.uuidString && $0["harness"] as? String == harness
                        && $0["parent"] as? String == lead.rawValue.uuidString },
                       "\(name) rows must name the helper's part, harness and parent: \(rows)")
        }
        try expect(nestedRows.allSatisfy { $0["parent"] as? String == hc.rawValue.uuidString },
                   "the nested helper's rows must name its parent: \(nestedRows)")
        print("  nested helper: parent=hc, task=lead's")
        try privacy(root: root)
    }

    /// A Managed Codex lead over the Codex double.
    static func codexBench(_ label: String) throws -> (Bench, AgentID, URL, () -> Void) {
        let b = try ManagedModeChecks.bench("request-telemetry-\(label)")
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        do {
            let (lead, root) = try HelperEvidenceChecks.prepare(b)
            try installCodexDouble(b)
            try expect(b.supervisor.setProviderSettings(agentID: lead, harness: .codex, model: ManagedCodexChecks.model), "could not select Codex")
            try expect(b.supervisor.effectiveMode(for: lead) == .managed, "Codex lead is not Managed")
            return (b, lead, root, { restoreCodex(); b.tearDown() })
        } catch { restoreCodex(); b.tearDown(); throw error }
    }
    /// Cumulative totals (input / cached / output) of codex-appserver-single-agent:
    /// f1 16,047 / 11,008 / 91, f2 32,246 / 26,112 / 153, f3 48,531 / 41,216 / 269,
    /// f4 64,996 / 57,344 / 313.
    static func singleAgent() throws -> [[String: Any]] {
        let f = try codexUsage("codex-appserver-single-agent.jsonl")
        try expect(f.count == 4, "single-agent capture changed shape")
        return f
    }

    /// A Codex lead over three tasks on one thread: a fork, reports out of
    /// order, and a counter reset.
    static func codexLead() async throws {
        print("request-telemetry: codex lead")
        let (b, lead, root, tearDown) = try codexBench("codex")
        defer { tearDown() }
        let f = try singleAgent()
        func later(_ frame: [String: Any], by ms: Int) -> [String: Any] {
            var frame = frame; frame["emittedAtMs"] = (f[3]["emittedAtMs"] as? Int ?? 0) + ms; return frame
        }
        // The recorded thread/started shape with a parent (`forkedFromId`).
        let fork: [String: Any] = ["method": "thread/started", "params": ["thread": [
            "id": "SESSION", "forkedFromId": "00000000-0000-4000-8000-0000000000aa", "modelProvider": "openai"]]]

        // Task 1, a forked thread: f1 holds history from before the fork, so only
        // f2 - f1 counts: 16,199 / 15,104 / 62 → 1,095 / 15,104 / unknown / 62.
        try stage([fork, f[0], f[1]], "c1", in: root)
        try await soloTurn(b, lead, "FRAMES-c1")
        try expectRow(usage(lead).last, "fork", model: ManagedCodexChecks.model, source: "record", counts(1_095, 15_104, nil, 62), incomplete: ["fork"])
        // Task 2, the next turn, f4 then the older f3: f4 - f2 = 32,750 / 31,232 /
        // 160 → 1,518 / 31,232 / 160.
        try stage([f[3], f[2]], "c2", in: root)
        try await soloTurn(b, lead, "FRAMES-c2")
        try expectRow(usage(lead).last, "next turn, reports out of order", model: ManagedCodexChecks.model, source: "record",
                      counts(1_518, 31_232, nil, 160))
        // Task 3, a reset: f1's total reported after f4, then f2's. What ran
        // before the reset is unknown; f2 - f1 counts.
        try stage([later(f[0], by: 10_000), later(f[1], by: 20_000)], "c3", in: root)
        try await soloTurn(b, lead, "FRAMES-c3")
        try expectRow(usage(lead).last, "reset", model: ManagedCodexChecks.model, source: "record", counts(1_095, 15_104, nil, 62), incomplete: ["reset"])
        let rows = usage(lead)
        try expect(rows.count == 3 && taskOf(rows).count == 3, "three tasks, one row each: \(rows)")
        try expect(rows.allSatisfy { row in tokens(row).values.allSatisfy { $0 > 0 } }, "a counter was zero or negative: \(rows)")
        try privacy(root: root)
    }

    /// Recording off for one task, then on: the off task records nothing, and
    /// the next is charged only what it ran (baselines stayed current).
    static func codexOffThenOn() async throws {
        print("request-telemetry: codex recording off, then on")
        let (b, lead, root, tearDown) = try codexBench("codex-off")
        defer { tearDown() }
        let f = try singleAgent()
        ManagedSettingChecks.write(AgentTokenTelemetryConfig.enabledKey, false, b)
        try stage([f[0], f[1]], "off", in: root)
        try await soloTurn(b, lead, "FRAMES-off")
        try expect(usage(lead).isEmpty, "recording off recorded usage: \(usage(lead))")
        ManagedSettingChecks.write(AgentTokenTelemetryConfig.enabledKey, true, b)
        // f4 - f2 → 1,518 / 31,232 / 160; charging from a cold baseline would give
        // f4 in full, 7,652 / 57,344 / 313.
        try stage([f[2], f[3]], "on", in: root)
        try await soloTurn(b, lead, "FRAMES-on")
        let rows = usage(lead)
        try expect(rows.count == 1, "one row after switching on, got \(rows)")
        try expectRow(rows.first, "first task after switching on", model: ManagedCodexChecks.model, source: "record", counts(1_518, 31_232, nil, 160))
    }

    /// A relaunch: the ledger forgets its baselines and the next turn resumes the
    /// thread. Its first total carries the thread's history: it sets the
    /// baseline, charges nothing and marks the turn.
    static func codexRelaunch() async throws {
        print("request-telemetry: codex relaunch, then resume")
        let (b, lead, root, tearDown) = try codexBench("codex-relaunch")
        defer { tearDown() }
        let f = try singleAgent()
        // A thread this process started: f2 in full → 6,134 / 26,112 / 153.
        try stage([f[0], f[1]], "fresh", in: root)
        try await soloTurn(b, lead, "FRAMES-fresh")
        try expectRow(usage(lead).last, "new thread, charged in full", model: ManagedCodexChecks.model, source: "record", counts(6_134, 26_112, nil, 153))
        b.supervisor.qaReopenRunLedger()
        // f3 is the baseline; f4 - f3 = 16,465 / 16,128 / 44 → 337 / 16,128 / 44,
        // marked. Unmarked, the whole thread would read 7,652 / 57,344 / 313.
        try stage([f[2], f[3]], "resumed", in: root)
        try await soloTurn(b, lead, "FRAMES-resumed")
        let launches = ManagedCodexChecks.rows(b, kind: "launch").compactMap { ($0["request"] as? [String: Any])?["method"] as? String }
        try expect(launches.last == "thread/resume", "the second turn must resume the thread: \(launches)")
        try expectRow(usage(lead).last, "resumed thread after relaunch", model: ManagedCodexChecks.model, source: "record",
                      counts(337, 16_128, nil, 44), incomplete: ["noBaseline"])
    }

    /// Reports that arrive after their turn completed are written at once for
    /// the turn they name, never folded into the turn that is running. They
    /// arrive inside the next turn's stream here; a primary frame sent after
    /// `turn/completed` in the same process is `RunLedgerGapsChecks`'
    /// `codex-trailing` case.
    static func codexLate() async throws {
        print("request-telemetry: codex usage after its turn")
        let (b, lead, root, tearDown) = try codexBench("codex-late")
        defer { tearDown() }
        let f = try singleAgent()
        // Turn 1: f1, f2 → 6,134 / 26,112 / 153.
        try stage([f[0], f[1]], "first", in: root)
        try await soloTurn(b, lead, "FRAMES-first")
        let first = usage(lead)
        try expect(first.count == 1, "turn 1: one row, got \(first)")
        try expectRow(first.first, "turn 1", model: ManagedCodexChecks.model, source: "record", counts(6_134, 26_112, nil, 153))
        guard let turn1 = first[0]["turn"] as? String else { throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: turn 1 row names no turn") }
        // Turn 2's stream carries f3 and f4 naming turn 1: late rows for turn 1,
        // f3 - f2 (1,181 / 15,104 / 116) and f4 - f3 (337 / 16,128 / 44); turn 2
        // itself reported nothing and is unknown.
        let stale = [f[2], f[3]].map { frame -> [String: Any] in
            var frame = frame, params = frame["params"] as? [String: Any] ?? [:]
            params["turnId"] = turn1; frame["params"] = params; return frame
        }
        try stage(stale, "second", in: root)
        try await soloTurn(b, lead, "FRAMES-second")
        let rows = Array(usage(lead).dropFirst(first.count))
        let late = rows.filter { $0["late"] as? Bool == true }, onTime = rows.filter { $0["late"] == nil }
        try expect(late.count == 2 && late.allSatisfy { $0["turn"] as? String == turn1 && $0["task"] as? String == first[0]["task"] as? String },
                   "late rows must name turn 1 and its task: \(late)")
        try expect(total(late) == counts(1_518, 31_232, nil, 160), "late rows must add f4 - f2: \(total(late))")
        print("  late rows: \(describe(total(late))) on turn 1")
        try expect(onTime.count == 1 && onTime[0]["turn"] as? String != turn1, "turn 2 must get only its own row: \(onTime)")
        try expectRow(onTime.first, "turn 2", model: ManagedCodexChecks.model, source: "record", nil, incomplete: ["noUsage"])
    }

    /// A Codex lead whose provider-run child reports on its own thread, after
    /// the lead's turn ended (codex-appserver-delegating-turn): the child gets
    /// its own rows, its parent named, in the lead's task; the lead's row is the
    /// parent thread alone.
    static func codexChild() async throws {
        print("request-telemetry: codex provider-run child")
        let (b, lead, root, tearDown) = try codexBench("codex-child")
        defer { tearDown() }
        try stage(try delegatingFrames(), "child", in: root)
        try await soloTurn(b, lead, "FRAMES-child")
        var child: AgentID?
        try await wait("child usage not recorded") {
            b.supervisor.runLedger.drain()
            child = b.supervisor.records.values.first { $0.parentAgentID == lead }?.id
            return child.map { !b.supervisor.isRunning($0) && usage($0).contains { $0["tokens"] != nil } } ?? false
        }
        guard let child else { return }
        let leadRows = usage(lead), childRows = usage(child)
        // Parent thread: 16,073 / 11,008 / 76 then 32,244 / 22,016 / 92 → 10,228 /
        // 22,016 / 92. The child thread, announced and so started here: 16,179 /
        // 11,008 / 123 then 32,537 / 26,112 / 170 → 6,425 / 26,112 / 170.
        try expect(leadRows.count == 1, "lead: one row, got \(leadRows)")
        try expectRow(leadRows.first, "lead, parent thread only", model: ManagedCodexChecks.model, source: "record", counts(10_228, 22_016, nil, 92))
        try expect(total(childRows) == counts(6_425, 26_112, nil, 170), "child total: \(total(childRows)) from \(childRows)")
        try expect(childRows.allSatisfy { $0["parent"] as? String == lead.rawValue.uuidString } && taskOf(childRows) == taskOf(leadRows),
                   "child rows must name their parent and sit in its task: \(childRows)")
        print("  child: \(describe(total(childRows))) in \(childRows.count) row(s), parent=lead, same task")
    }

    /// codex-appserver-delegating-turn on the double's thread and turn: the
    /// parent's own start, turn start and completion dropped (the double sends
    /// its own), every frame after the parent's completion marked `_after`.
    static func delegatingFrames() throws -> [[String: Any]] {
        let parentThread = "00000000-0000-4000-8000-000000000001"
        var parentTurn: String?, ended = false
        var frames: [[String: Any]] = []
        for frame in try capture("codex-appserver-delegating-turn.jsonl") {
            guard let method = frame["method"] as? String else { continue }
            let params = frame["params"] as? [String: Any] ?? [:]
            let thread = (params["threadId"] as? String) ?? ((params["thread"] as? [String: Any])?["id"] as? String)
            if thread == parentThread, method == "thread/started" { continue }
            if thread == parentThread, method == "turn/started" { parentTurn = (params["turn"] as? [String: Any])?["id"] as? String; continue }
            if thread == parentThread, method == "turn/completed" { ended = true; continue }
            var text = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
                .replacingOccurrences(of: parentThread, with: "SESSION")
            if let parentTurn { text = text.replacingOccurrences(of: parentTurn, with: "TURN") }
            guard var replayed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if ended { replayed["_after"] = true }
            frames.append(replayed)
        }
        try expect(parentTurn != nil && ended, "delegating capture changed shape")
        return frames
    }

    /// The ledger seam the supervisor calls, with an empty and a blank model id
    /// (empty ids exist on records): the row says the model is unknown; nothing traps.
    static func emptyModel() async throws {
        print("request-telemetry: empty model id")
        let support = try ManagedRunLedgerChecks.ownedSupport("telemetry-empty-model")
        defer { try? FileManager.default.removeItem(at: support) }
        let ledger = ManagedRunLedger(support: support), agent = UUID()
        var snapshot = TokenUsageSnapshot(inputTokens: 16_047, outputTokens: 91, totalCostUsd: nil)
        snapshot.typedCounts = .init(uncachedInput: 5_039, cacheRead: 11_008, cacheWrite: nil, output: 91)
        snapshot.accountingSessionStarted = true
        for (turn, model) in [("turn-1", ""), ("turn-2", " ")] {
            (snapshot.accountingTurn, snapshot.accountingSession) = (turn, "thread-" + turn)
            ledger.usageTurnStarted(agent: agent, turn: turn)
            ledger.usage(agent: agent, .init(model: model), snapshot, record: true)
            ledger.usageTurnEnded(agent: agent, turn: turn, .init(model: model), record: true)
        }
        ledger.drain()
        let rows = ManagedRunLedgerChecks.rows(support.appendingPathComponent("run-ledger/ledger.jsonl"), "usage")
        try expect(rows.count == 2, "two rows expected, got \(rows)")
        try expectRow(rows.first, "empty model id", model: nil, source: nil, counts(5_039, 11_008, nil, 91), incomplete: ["noTask"])
        try expectRow(rows.last, "blank model id", model: nil, source: nil, counts(5_039, 11_008, nil, 91), incomplete: ["noTask"])
    }

    /// Ids, model ids and numbers only: no prompt, brief, report or path.
    static func privacy(root: URL) throws {
        let text = (try? String(contentsOf: ledgerURL(), encoding: .utf8)) ?? ""
        for secret in ["SECRET-", "FRAMES-", root.path, root.resolvingSymlinksInPath().path] {
            try expect(!text.contains(secret), "ledger stores \(secret)")
        }
        for row in ManagedRunLedgerChecks.rows(ledgerURL()) {
            try expect(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
        }
    }

    /// What the event path pays: the usage hand-off alone, and the whole delivery
    /// of one usage event with recording on and off. Asserts nothing about time.
    static func timing(_ b: Bench, _ lead: AgentID) async throws {
        let supervisor = b.supervisor
        func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        func snapshot(_ i: Int) -> TokenUsageSnapshot {
            var value = TokenUsageSnapshot(inputTokens: 21_936, outputTokens: 124, totalCostUsd: nil, accountingObservationID: "timing-\(i)")
            value.typedCountsByModel = ["claude-opus-5-5": .init(uncachedInput: 2, cacheRead: 10_695, cacheWrite: 11_239, output: 124)]
            value.accountingTurn = "timing-turn"
            return value
        }
        var handOff: [Double] = [], on: [Double] = [], off: [Double] = []
        defer { supervisor.qaRunLedgerRecording = true }
        supervisor.runLedger.usageTurnStarted(agent: lead.rawValue, turn: "timing-turn")
        for i in 0..<1_200 {
            let start = now()
            supervisor.runLedger.usage(agent: lead.rawValue, .init(model: "timing"), snapshot(i), record: true)
            if i >= 200 { handOff.append(Double(now() - start) / 1000) }
            usleep(2_000)
        }
        for pair in 0..<1_020 {
            for enabled in (pair % 2 == 0 ? [false, true] : [true, false]) {
                supervisor.qaRunLedgerRecording = enabled
                let start = now()
                supervisor.qaDeliver(.tokenUsageUpdated(threadId: "timing", snapshot: snapshot(10_000 + pair * 2 + (enabled ? 1 : 0))), to: lead)
                let elapsed = Double(now() - start) / 1000
                if pair >= 20 { if enabled { on.append(elapsed) } else { off.append(elapsed) } }
            }
        }
        supervisor.runLedger.drain()
        for (name, values) in [("usage hand-off", handOff), ("deliver usage, recording off", off), ("deliver usage, recording on", on)] {
            let s = values.sorted()
            print(String(format: "request-telemetry timing %@ n=%d median=%.2f p95=%.2f max=%.2f us", name, s.count,
                         ManagedRunLedgerTimingChecks.percentile(s, 0.5), ManagedRunLedgerTimingChecks.percentile(s, 0.95), s.last ?? 0))
        }
    }
}
