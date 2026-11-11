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
            ("for frame in open('frames-' + f.group(1) + '.jsonl'): print(frame.replace('SESSION', sid).strip(), flush=True)\n",
             "for frame in open('frames-' + f.group(1) + '.jsonl'):\n            frame = frame.replace('SESSION', sid).strip()\n"
             + "            if json.loads(frame).get('type') == 'result': deferred.append(frame)\n            else: print(frame, flush=True)\n"),
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

    /// The evidence check's Codex double, with a fresh turn id per turn as the
    /// real app-server sends. Its fixed `fixture-turn` makes every later turn
    /// end a replay of the first, so the ledger would never see it end.
    static func installCodexDouble(_ b: Bench) throws {
        var script = try HelperEvidenceChecks.codex()
        let edits = [
            ("        result = dict(turn=dict(id='fixture-turn'))\n",
             "        turn_id = 'fixture-turn-' + str(uuid.uuid4())\n        result = dict(turn=dict(id=turn_id))\n"),
            ("turn=dict(id='fixture-turn'))))", "turn=dict(id=turn_id))))"),
            ("turn=dict(id='fixture-turn',status='completed')", "turn=dict(id=turn_id,status='completed')"),
        ]
        for (anchor, replacement) in edits {
            try expect(script.contains(anchor), "codex double changed shape")
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
    /// double's thread, with their provider times.
    static func codexUsage(_ name: String) throws -> [[String: Any]] {
        try capture(name).filter { $0["method"] as? String == "thread/tokenUsage/updated" }.map { frame in
            var frame = frame, params = frame["params"] as! [String: Any]
            params["threadId"] = "SESSION"; frame["params"] = params
            return frame
        }
    }
    static func stage(_ frames: [[String: Any]], _ name: String, in root: URL) throws {
        let lines = try frames.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("frames-\(name).jsonl"), atomically: true, encoding: .utf8)
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
    /// One row: its model, exact counters (an absent key is unknown) and flags.
    static func expectRow(_ row: [String: Any]?, _ label: String, model: String, _ expected: [String: Int]?, incomplete: [String]? = nil) throws {
        guard let row else { throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: \(label): no usage row") }
        let got = row["tokens"] == nil ? nil : tokens(row)
        try expect(row["model"] as? String == model && got == expected && row["incomplete"] as? [String] == incomplete,
                   "\(label): expected \(model) \(expected.map { "\($0)" } ?? "unknown") incomplete=\(incomplete ?? []), got \(row)")
        print("  \(label): \(model) \(expected.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") } ?? "tokens unknown")"
              + (incomplete.map { " incomplete=\($0)" } ?? ""))
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
    static func debugInputs(_ root: URL) -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("inputs-") }
        return names.map { name in
            let lines = ((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n")
            return name + ": " + lines.map { line in
                let tags = ["HOLD-lead", "HOLD-hc", "HOLD-hx", "FRAMES-lead", "FRAMES-hc", "array-agent-message"].filter { line.contains($0) }
                return "{" + tags.joined(separator: " ") + " len=\(line.count)}"
            }.joined(separator: " ")
        }.joined(separator: " | ")
    }
    static func taskOf(_ rows: [[String: Any]]) -> Set<String> { Set(rows.compactMap { $0["task"] as? String }) }

    static func run() async throws {
        let only = ProcessInfo.processInfo.environment["CONTINUUM_TELEMETRY_CASE"]
        if only == nil || only == "lead" { try await leadAlone() }
        if only == nil || only == "helpers" { try await leadWithHelpers() }
        if only == nil || only == "codex" { try await codexLead() }
        print("Request telemetry passed")
    }

    /// A Claude lead alone: one turn; a turn with no usage; recording off; on again.
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
        try stage(try claudeRun("claude-2.1.291-opus-turn.jsonl"), "opus", in: root)
        try await soloTurn(b, lead, "FRAMES-opus")
        var rows = usage(lead)
        try expect(rows.count == 1, "one lead turn must give one usage row, got \(rows.count)")
        try expectRow(rows.first, "one lead turn", model: "claude-opus-5-5", counts(2, 10_695, 11_239, 124))
        try expect(rows[0]["harness"] as? String == "Claude Code" && rows[0]["part"] == nil, "lead row identity: \(rows[0])")
        let all = ManagedRunLedgerChecks.rows(ledgerURL())
        let usageIndex = all.firstIndex { $0["kind"] as? String == "usage" }!, closeIndex = all.firstIndex { $0["kind"] as? String == "taskClosed" }!
        try expect(usageIndex < closeIndex && all[closeIndex]["task"] as? String == rows[0]["task"] as? String,
                   "the turn's usage must be in its task before the task closes")

        // The double's own result carries no usage block: unknown, never zero.
        try await soloTurn(b, lead, "plain")
        rows = usage(lead)
        try expectRow(rows.last, "turn with no usage", model: ManagedModeChecks.model, nil, incomplete: ["noUsage"])

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
        let fresh = Array(usage(lead).dropFirst(rows.count))
        try expect(fresh.count == 2 && taskOf(fresh).count == 1, "on again: expected two model rows in one task, got \(fresh)")
        try expectRow(fresh.first { $0["model"] as? String == "claude-fable-5" }, "subagent run, main model",
                      model: "claude-fable-5", counts(8, 54_846, 23_249, 484))
        try expectRow(fresh.first { $0["model"] as? String == "claude-haiku-4-5-20251001" }, "subagent run, side model",
                      model: "claude-haiku-4-5-20251001", counts(933, 0, 0, 16))
        try privacy(root: root)
        try await timing(b, lead)
    }

    /// A Claude lead delegating one Claude and one Codex helper in one task.
    static func leadWithHelpers() async throws {
        print("request-telemetry: lead with two helpers")
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
        for (harness, name, model) in [(AgentHarness.claudeCode, "hc", ManagedModeChecks.model), (.codex, "hx", ManagedCodexChecks.model)] {
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
                "task": "HOLD-\(name) FRAMES-\(name) SECRET-BRIEF", "title": "Telemetry \(name)",
                "harness": harness == .codex ? "Codex" : "Claude Code", "model": model, "idempotencyKey": UUID().uuidString])
            guard !reply.isError, let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String,
                  let uuid = UUID(uuidString: raw) else {
                throw WorkspaceAgentReportChecks.Failure(description: "request-telemetry: \(name) delegation failed: \(reply.reply)")
            }
            helpers[name] = AgentID(rawValue: uuid)
        }
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await wait("lead turn did not end") { !supervisor.isRunning(lead) }

        // Claude helper: claude-subagent-turn (figures above). Codex helper: the
        // four cumulative totals of codex-appserver-single-agent on a thread this
        // process started: last total 64,996 in, 57,344 of it cached, 313 out →
        // 7,652 / 57,344 / unknown / 313, never the 161,820 / 826 their sum gives.
        let frames = ["hc": try claudeRun("claude-subagent-turn.jsonl"), "hx": try codexUsage("codex-appserver-single-agent.jsonl")]
        for name in ["hc", "hx"] {
            let helper = helpers[name]!
            let helperRoot = URL(fileURLWithPath: supervisor.records[helper]!.checkoutRoot)
            try stage(frames[name]!, name, in: helperRoot)
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
                let list = { (u: URL) in ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted().joined(separator: ",") }
                throw WorkspaceAgentReportChecks.Failure(description: "\(error) lead running=\(supervisor.isRunning(lead)) helper running=\(supervisor.isRunning(helper)) same root=\(helperRoot == root) before=\(before) now=\(leadInputs()) root=[\(list(root))] inputs=\(debugInputs(root))")
            }
            try await wait("lead did not settle after \(name)") { !supervisor.isRunning(lead) && !supervisor.isRunning(helper) }
        }
        supervisor.runLedger.drain()

        let leadRows = usage(lead), claudeRows = usage(helpers["hc"]!), codexRows = usage(helpers["hx"]!)
        let task = taskOf(leadRows)
        try expect(task.count == 1 && taskOf(claudeRows) == task && taskOf(codexRows) == task,
                   "lead and helpers must be one task: \(taskOf(leadRows)) \(taskOf(claudeRows)) \(taskOf(codexRows))")
        let leadMeasured = leadRows.filter { $0["tokens"] != nil }
        try expect(leadMeasured.count == 1, "lead: one measured turn expected, got \(leadMeasured)")
        try expectRow(leadMeasured.first, "lead turn", model: "claude-haiku-4-5-20251001", counts(11_002, 72_550, 9_836, 832))
        // Each wake turn's double result carries no usage: unknown, never zero.
        for (index, row) in leadRows.filter({ $0["tokens"] == nil }).enumerated() {
            try expectRow(row, "lead wake \(index + 1)", model: ManagedModeChecks.model, nil, incomplete: ["noUsage"])
        }
        try expect(claudeRows.count == 2 && codexRows.count == 1, "helper rows: claude \(claudeRows.count), codex \(codexRows.count)")
        try expectRow(claudeRows.first { $0["model"] as? String == "claude-fable-5" }, "Claude helper, main model",
                      model: "claude-fable-5", counts(8, 54_846, 23_249, 484))
        try expectRow(claudeRows.first { $0["model"] as? String == "claude-haiku-4-5-20251001" }, "Claude helper, side model",
                      model: "claude-haiku-4-5-20251001", counts(933, 0, 0, 16))
        try expectRow(codexRows.first, "Codex helper", model: ManagedCodexChecks.model, counts(7_652, 57_344, nil, 313))
        for (name, rows, harness) in [("hc", claudeRows, "Claude Code"), ("hx", codexRows, "Codex")] {
            try expect(rows.allSatisfy { $0["part"] as? String == helpers[name]!.rawValue.uuidString && $0["harness"] as? String == harness },
                       "\(name) rows must name the helper's part and harness: \(rows)")
        }
        try privacy(root: root)
    }

    /// A Codex lead over three tasks on one thread: a fork, a resumed turn whose
    /// reports arrive out of order, and a counter reset.
    static func codexLead() async throws {
        print("request-telemetry: codex lead")
        let b = try ManagedModeChecks.bench("request-telemetry-codex")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try installCodexDouble(b)
        let supervisor = b.supervisor
        try expect(supervisor.setProviderSettings(agentID: lead, harness: .codex, model: ManagedCodexChecks.model), "could not select Codex")
        try expect(supervisor.effectiveMode(for: lead) == .managed, "Codex lead is not Managed")
        let f = try codexUsage("codex-appserver-single-agent.jsonl")
        // Cumulative totals (input / cached / output): f1 16,047 / 11,008 / 91,
        // f2 32,246 / 26,112 / 153, f3 48,531 / 41,216 / 269, f4 64,996 / 57,344 / 313.
        func later(_ frame: [String: Any], by ms: Int) -> [String: Any] {
            var frame = frame; frame["emittedAtMs"] = (f[3]["emittedAtMs"] as! Int) + ms; return frame
        }
        // The recorded thread/started shape with a parent (`forkedFromId`).
        let fork: [String: Any] = ["method": "thread/started", "params": ["thread": [
            "id": "SESSION", "forkedFromId": "00000000-0000-4000-8000-0000000000aa", "modelProvider": "openai"]]]

        // Task 1, a forked thread: f1 holds history from before the fork, so only
        // f2 - f1 counts: 16,199 / 15,104 / 62 → 1,095 / 15,104 / unknown / 62.
        try stage([fork, f[0], f[1]], "c1", in: root)
        try await soloTurn(b, lead, "FRAMES-c1")
        try expectRow(usage(lead).last, "fork", model: ManagedCodexChecks.model, counts(1_095, 15_104, nil, 62), incomplete: ["fork"])
        // Task 2, the next turn (a resumed app-server, no thread/started), f4 then
        // the older f3: f4 - f2 = 32,750 / 31,232 / 160 → 1,518 / 31,232 / 160.
        try stage([f[3], f[2]], "c2", in: root)
        try await soloTurn(b, lead, "FRAMES-c2")
        try expectRow(usage(lead).last, "next turn, reports out of order", model: ManagedCodexChecks.model, counts(1_518, 31_232, nil, 160))
        // Task 3, a reset: f1's total reported after f4, then f2's. What ran
        // before the reset is unknown; f2 - f1 counts.
        try stage([later(f[0], by: 10_000), later(f[1], by: 20_000)], "c3", in: root)
        try await soloTurn(b, lead, "FRAMES-c3")
        try expectRow(usage(lead).last, "reset", model: ManagedCodexChecks.model, counts(1_095, 15_104, nil, 62), incomplete: ["reset"])
        let rows = usage(lead)
        try expect(rows.count == 3 && taskOf(rows).count == 3, "three tasks, one row each: \(rows)")
        try expect(rows.allSatisfy { row in tokens(row).values.allSatisfy { $0 > 0 } }, "a counter was zero or negative: \(rows)")
        try privacy(root: root)
    }

    /// Ids, model ids and numbers only: no prompt, brief, report or path.
    static func privacy(root: URL) throws {
        let text = (try? String(contentsOf: ledgerURL(), encoding: .utf8)) ?? ""
        for secret in ["SECRET-", "FRAMES-", root.path, root.resolvingSymlinksInPath().path] {
            try expect(!text.contains(secret), "ledger stores \(secret)")
        }
        let allowed = ManagedRunLedgerChecks.allowedKeys.union(["effort", "tokens", "incomplete"])
        for row in ManagedRunLedgerChecks.rows(ledgerURL()) {
            try expect(Set(row.keys).isSubset(of: allowed), "unexpected row keys: \(row.keys.sorted())")
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
            return value
        }
        var handOff: [Double] = [], on: [Double] = [], off: [Double] = []
        defer { supervisor.qaRunLedgerRecording = true }
        for i in 0..<1_200 {
            let start = now()
            supervisor.runLedger.usage(owner: lead.rawValue, model: "timing", snapshot(i), record: true)
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
