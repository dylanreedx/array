import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/102` P2a: short reports and declared status, through the production
/// listener (`mountWorkspaceSceneAtBoot` wires `workspaceMCPHost` to
/// `WorkspaceAPIService.handleMCPRequest`), the real `array-workspace-mcp`
/// binary in both of its modes, a real `AgentSupervisor` and a real delegated
/// child whose runner is a fake `pi` (no model, no network).
///
/// `--workspace-agent-report-check`:
/// - `array_report` / `array_status` over the child's own MCP registration:
///   every bound refused with nothing recorded; a valid call recorded on the
///   child and nowhere else; the parent's token cannot write the child's; the
///   status comes back and is stored labelled `declared`, and the observed
///   status does not move.
/// - `wait_agents` over the parent's registration: setting off, today's entry
///   plus `report`; setting on, the report in the final text's place; a later
///   turn that filed nothing carries no report.
///
/// `--workspace-hook-pushback-check`: the hook command with the setting off
/// prints nothing for a 600-word hand-back; on, it prints the block JSON once
/// for a delegated child's `Stop` and any `SubagentStop`, and nothing for a
/// continuation (`stop_hook_active`), a 200-word message, a top-level `Stop`,
/// or an app that is down or silent.
@MainActor
enum WorkspaceAgentReportChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static let childFinalText = "CHILD-FINAL-7f3a: the ledger balances, and here is the whole long answer."
    static let model = "openai-codex/gpt-5.6-sol"

    /// A fake `pi --mode rpc`. It logs each prompt, streams `childFinalText`,
    /// and settles at once, except for a prompt containing HOLD: that turn
    /// stays open until `release.flag` appears in its cwd, so a check can act
    /// DURING the child's turn.
    static let fakePi = """
    #!/usr/bin/env python3
    import json, os, sys, threading, time

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    def handle(cmd):
        kind = cmd.get("type")
        if kind == "prompt":
            text = cmd.get("message") or cmd.get("prompt") or ""
            with open(os.path.join(os.getcwd(), "prompts.log"), "a") as log:
                log.write(json.dumps(text) + "\\n")
            emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
            emit({"type": "agent_start"})
            emit({"type": "turn_start"})
            emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": \(String(reflecting: childFinalText))}})
            if "HOLD" in json.dumps(text):
                flag = os.path.join(os.getcwd(), "release.flag")
                deadline = time.time() + 60
                while not os.path.exists(flag) and time.time() < deadline:
                    time.sleep(0.02)
                try:
                    os.remove(flag)
                except OSError:
                    pass
            emit({"type": "turn_end", "message": {"role": "assistant"}})
            emit({"type": "agent_end", "willRetry": False})
            emit({"type": "agent_settled"})
        else:
            emit({"type": "response", "id": cmd.get("id"), "command": kind, "success": True, "data": {}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        threading.Thread(target=handle, args=(obj,), daemon=True).start()

    time.sleep(0.3)
    """

    /// The isolated pieces every leg shares. `tearDown` puts PATH back and
    /// removes the settings suite and the temp dirs.
    @MainActor
    struct Bench {
        let f: WorkspaceAPIChecks.Fixture
        let settings: QAIsolatedDefaults
        let helper: String
        let binDir: URL
        let originalPath: String
        var supervisor: AgentSupervisor { f.delegate.qaAgentSupervisor }

        func tearDown() {
            supervisor.stopAll()
            setenv("PATH", originalPath, 1)
            settings.removePersistentDomain(forName: settings.suiteDomainName)
            try? FileManager.default.removeItem(at: binDir)
            f.tearDown()
        }

        func configuration(for agent: AgentID) throws -> WorkspaceMCPConfiguration {
            guard let config = f.delegate.workspaceMCPHost.configuration(for: agent, serverExecutable: helper) else {
                throw Failure(description: "the production MCP host issued no registration for \(agent)")
            }
            try config.materialize()
            return config
        }

        /// A child the fixture's agent creates through the production
        /// `agent.delegate` (Agent permissions Free: no prompt).
        func delegate(_ marker: String) throws -> AgentID {
            let reply = f.api.dispatch(agentId: f.agentId, requestId: "report-\(marker)", op: "agent.delegate",
                                       payload: ["task": "\(marker): check the ledger", "title": marker,
                                                 "idempotencyKey": "report-key-\(marker)"])
            guard case let .result(result) = reply,
                  let id = result["childAgentId"]?.string.flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:)) else {
                throw Failure(description: "the delegation failed: \(reply)")
            }
            try expect(supervisor.records[id]?.parentAgentID == f.agentId, "the delegated child must name its parent")
            return id
        }
    }

    static func makeBench(label: String) throws -> Bench {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "\(label) requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let fileManager = FileManager.default
        let binDir = fileManager.temporaryDirectory.appendingPathComponent("continuum-\(label)-bin-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        let executable = binDir.appendingPathComponent("pi")
        try fakePi.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(binDir.path):\(originalPath)", 1)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(
            harness: .pi, readiness: .ready, models: [model],
            displayNames: [model: "Fixture"], contextWindows: [model: 200_000]))
        guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.\(label).\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        guard let helper = AppDelegate.workspaceMCPExecutablePath() else {
            throw Failure(description: "array-workspace-mcp is not beside the app binary — build the package, not just the Array product")
        }
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings)
        f.api.approvalHandler = { _ in .deny }
        return Bench(f: f, settings: settings, helper: helper, binDir: binDir, originalPath: originalPath)
    }

    // MARK: - MCP over the real binary

    struct ToolReply { let isError: Bool; let reply: [String: Any] }

    /// One `array-workspace-mcp` process: initialize, then each request in
    /// order. `tokenFile` swaps in another file, as a confused or hostile
    /// caller would.
    static func mcp(_ config: WorkspaceMCPConfiguration, tokenFile: String? = nil,
                    _ requests: [(method: String, params: [String: Any])]) async throws -> [[String: Any]] {
        final class Output: @unchecked Sendable {
            let lock = NSLock(); var bytes = Data()
            func append(_ data: Data) { lock.withLock { bytes.append(data) } }
        }
        let process = Process(), input = Pipe(), output = Pipe(), collected = Output()
        process.executableURL = URL(fileURLWithPath: config.serverExecutable)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.merging(config.environment) { _, new in new }
        if let tokenFile { environment["ARRAY_WORKSPACE_MCP_TOKEN_FILE"] = tokenFile }
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        try process.run()
        defer { if process.isRunning { process.terminate() }; output.fileHandleForReading.readabilityHandler = nil }
        var lines: [[String: Any]] = [["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:] as [String: Any]]]
        for (index, request) in requests.enumerated() {
            lines.append(["jsonrpc": "2.0", "id": index + 2, "method": request.method, "params": request.params])
        }
        for line in lines { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: line) + Data([10])) }
        try input.fileHandleForWriting.close()
        let exited = await waitUntil(timeout: 60, pollInterval: 0.01) { !process.isRunning }
        try expect(exited, "array-workspace-mcp did not finish within 60 s")
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        var byID: [Int: [String: Any]] = [:]
        for line in collected.lock.withLock({ collected.bytes }).split(separator: 10) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = object["id"] as? Int {
                byID[id] = object
            }
        }
        return try (0..<requests.count).map { index in
            guard let response = byID[index + 2] else { throw Failure(description: "no answer to \(requests[index].method)") }
            return response
        }
    }

    static func call(_ config: WorkspaceMCPConfiguration, tokenFile: String? = nil,
                     _ tool: String, _ arguments: [String: Any]) async throws -> ToolReply {
        let response = try await mcp(config, tokenFile: tokenFile, [("tools/call", ["name": tool, "arguments": arguments])])[0]
        guard let result = response["result"] as? [String: Any], let reply = result["structuredContent"] as? [String: Any] else {
            throw Failure(description: "\(tool): no structured result: \(response)")
        }
        return ToolReply(isError: result["isError"] as? Bool ?? false, reply: reply)
    }

    static func errorCode(_ reply: ToolReply) -> String? {
        (reply.reply["error"] as? [String: Any])?["code"] as? String
    }

    static func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    // MARK: - --workspace-agent-report-check

    static func runReports() async throws {
        let bench = try makeBench(label: "agent-report")
        defer { bench.tearDown() }
        let f = bench.f, supervisor = bench.supervisor, settings = bench.settings
        let parent = f.agentId
        try expect(!AgentShortReportConfig.enabled(defaults: settings) && !f.api.shortReportsEnabled(),
                   "with nothing set, short reports must be off (D1)")

        // A child mid-turn: its runner has the task and holds the turn open.
        let child = try bench.delegate("REPORT-CHILD-HOLD")
        let childCwd = URL(fileURLWithPath: supervisor.records[child]?.cwd ?? f.pbRoot.path, isDirectory: true)
        func promptLog() -> String { (try? String(contentsOf: childCwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        let holding = await waitUntil(timeout: 30, pollInterval: 0.05) { promptLog().contains("REPORT-CHILD-HOLD") && supervisor.isRunning(child) }
        try expect(holding, "the child's runner must receive its task and still be running")
        let childConfig = try bench.configuration(for: child)
        let parentConfig = try bench.configuration(for: parent)

        // Both tools are listed, and their descriptions stay short: they cost
        // context in every session.
        let listed = try await mcp(childConfig, [("tools/list", [:])])[0]
        let tools = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        for name in ["array_report", "array_status"] {
            guard let tool = tools.first(where: { $0["name"] as? String == name }), let description = tool["description"] as? String else {
                throw Failure(description: "tools/list does not carry \(name): \(tools.compactMap { $0["name"] as? String })")
            }
            try expect(description.count <= 400, "\(name)'s description is \(description.count) characters; keep it short")
        }

        // (a) Bounds: each refused as invalid_request, isError, nothing kept.
        let summary60 = (1...60).map { "w\($0)" }.joined(separator: " ")
        let invalidReports: [(String, [String: Any])] = [
            ("no summary", ["checks": [] as [Any]]),
            ("an empty summary", ["summary": "   "]),
            ("a 61-word summary", ["summary": summary60 + " extra"]),
            ("nine checks", ["summary": "ok", "checks": Array(repeating: ["what": "build", "result": "pass"], count: 9)]),
            ("a check result outside pass/fail/info", ["summary": "ok", "checks": [["what": "build", "result": "green"]]]),
            ("a check with no what", ["summary": "ok", "checks": [["result": "pass"]]]),
            ("seven findings", ["summary": "ok", "findings": Array(repeating: ["level": "note", "text": "x"], count: 7)]),
            ("a finding level outside the four", ["summary": "ok", "findings": [["level": "critical", "text": "x"]]]),
            ("a 401-character finding", ["summary": "ok", "findings": [["level": "issue", "text": String(repeating: "x", count: 401)]]]),
            ("a 201-character next", ["summary": "ok", "next": String(repeating: "n", count: 201)]),
            ("a detailsPath with a newline", ["summary": "ok", "detailsPath": "/tmp/a\nb"]),
            ("a summary of the wrong type", ["summary": 42]),
        ]
        for (label, arguments) in invalidReports {
            let reply = try await call(childConfig, "array_report", arguments)
            try expect(reply.isError && errorCode(reply) == "invalid_request", "\(label) must be refused as invalid_request: \(reply.reply)")
        }
        let invalidStatuses: [(String, [String: Any])] = [
            ("no now", ["next": "x"]),
            ("an empty now", ["now": " \n "]),
            ("a 141-character now", ["now": String(repeating: "n", count: 141)]),
            ("a 141-character needsYou", ["now": "ok", "needsYou": String(repeating: "y", count: 141)]),
            ("a now of the wrong type", ["now": ["x"]]),
        ]
        for (label, arguments) in invalidStatuses {
            let reply = try await call(childConfig, "array_status", arguments)
            try expect(reply.isError && errorCode(reply) == "invalid_request", "status with \(label) must be refused as invalid_request: \(reply.reply)")
        }
        try expect(supervisor.agentReports.isEmpty && supervisor.declaredStatuses.isEmpty,
                   "a refused call recorded something: \(supervisor.agentReports.keys) \(supervisor.declaredStatuses.keys)")

        // (b) Another agent's token cannot write the child's.
        let forgedReport = try await call(childConfig, tokenFile: parentConfig.tokenFilePath, "array_report", ["summary": "forged"])
        let forgedStatus = try await call(childConfig, tokenFile: parentConfig.tokenFilePath, "array_status", ["now": "forged"])
        try expect(forgedReport.isError && forgedStatus.isError, "the parent's token must not pass as the child: \(forgedReport.reply) \(forgedStatus.reply)")
        try expect(supervisor.agentReports.isEmpty && supervisor.declaredStatuses.isEmpty, "a forged call was recorded")

        // (c) Valid: recorded on the child, nowhere else. Bounds hold exactly
        // at the limit, and one-line fields fold their whitespace.
        let observedBefore = (supervisor.derivedStreamStatus(for: child), supervisor.presenceRowStatus(for: child),
                              supervisor.isRunning(child), supervisor.records)
        let reportArguments: [String: Any] = [
            "summary": summary60,
            "checks": [["what": "swift build\n  --product Array", "result": "pass"], ["what": "matrix leg", "result": "fail"],
                       ["what": "read the ledger", "result": "info"]] + Array(repeating: ["what": "x", "result": "info"], count: 5),
            "findings": [["level": "blocker", "text": "the total is off by a cent", "where": "Ledger.swift:42"],
                         ["level": "note", "text": "rounding happens per line"]] + Array(repeating: ["level": "minor", "text": "y"], count: 4),
            "next": "round once, at the total",
            "detailsPath": "/tmp/report-details.md",
        ]
        let filed = try await call(childConfig, "array_report", reportArguments)
        try expect(!filed.isError && (filed.reply["result"] as? [String: Any])?["recorded"] as? Bool == true,
                   "a valid report must be recorded: \(filed.reply)")
        guard let stored = supervisor.agentReports[child]?.report else { throw Failure(description: "the report is not on the child") }
        try expect(Set(supervisor.agentReports.keys) == [child], "the report landed on the wrong agent: \(supervisor.agentReports.keys)")
        try expect(stored.summary == summary60 && stored.checks.count == 8 && stored.checks[0].what == "swift build --product Array"
                   && stored.checks[1].result == .fail && stored.findings.count == 6 && stored.findings[0].location == "Ledger.swift:42"
                   && stored.findings[0].level == .blocker && stored.next == "round once, at the total"
                   && stored.detailsPath == "/tmp/report-details.md", "the stored report is not the one filed: \(stored)")

        let declared = try await call(childConfig, "array_status", ["now": "checking the\nledger", "next": "fix rounding", "needsYou": ""])
        let declaredResult = declared.reply["result"] as? [String: Any] ?? [:]
        try expect(!declared.isError && declaredResult["provenance"] as? String == "declared" && declaredResult["now"] as? String == "checking the ledger"
                   && declaredResult["next"] as? String == "fix rounding" && declaredResult["needsYou"] == nil && declaredResult["declaredAt"] != nil,
                   "the status must come back labelled declared, timestamped and folded: \(declared.reply)")
        try expect(supervisor.declaredStatuses[child]?.provenance == AgentDeclaredStatus.provenance
                   && supervisor.declaredStatuses[child]?.now == "checking the ledger" && Set(supervisor.declaredStatuses.keys) == [child],
                   "the declared status is not stored on the child, labelled declared: \(supervisor.declaredStatuses)")
        // Declared is never merged with observed.
        try expect(supervisor.derivedStreamStatus(for: child) == observedBefore.0 && supervisor.presenceRowStatus(for: child) == observedBefore.1
                   && supervisor.isRunning(child) == observedBefore.2 && supervisor.records == observedBefore.3,
                   "filing a report or a status changed the observed status or a record")
        // The parent's own status lands on the parent.
        _ = try await call(parentConfig, "array_status", ["now": "waiting on the child"])
        try expect(supervisor.declaredStatuses[parent]?.now == "waiting on the child" && supervisor.declaredStatuses[child]?.now == "checking the ledger",
                   "each agent's status must be its own: \(supervisor.declaredStatuses)")

        // (d) The child's turn ends; the report rides its courier.
        try Data().write(to: childCwd.appendingPathComponent("release.flag"))
        let released = await waitUntil(timeout: 30, pollInterval: 0.05) { !supervisor.isRunning(child) }
        try expect(released, "the child must settle once released")
        guard let operation = supervisor.records[child]?.spawnResultHandle,
              let courier = SpawnResultFile.read(parentCwd: supervisor.records[parent]?.cwd ?? "", handle: operation) else {
            throw Failure(description: "the child left no spawn-result courier")
        }
        try expect(courier.report == stored && courier.finalText == childFinalText, "the courier must carry this turn's report and final text: \(courier)")

        // (e) wait_agents, setting OFF: today's entry, plus `report`.
        func waitEntry() async throws -> (whole: [String: Any], entry: [String: Any]) {
            let waited = try await call(parentConfig, WorkspaceMCPToolCatalog.waitAgentsName, ["handles": [operation], "timeoutSeconds": 10])
            let result = waited.reply["result"] as? [String: Any] ?? [:]
            guard !waited.isError, let agents = result["agents"] as? [[String: Any]], agents.count == 1 else {
                throw Failure(description: "wait_agents failed: \(waited.reply)")
            }
            return (waited.reply, agents[0])
        }
        let todaysKeys: Set<String> = ["handle", "childAgentId", "status", "finalText", "endedAt"]
        let off = try await waitEntry()
        try expect(Set(off.whole.keys) == ["schema", "status", "result"]
                   && Set((off.whole["result"] as? [String: Any] ?? [:]).keys) == ["agents", "timedOut"],
                   "the wait_agents reply's shape changed: \(off.whole)")
        var offWithoutReport = off.entry
        let offReport = offWithoutReport.removeValue(forKey: "report")
        try expect(Set(offWithoutReport.keys) == todaysKeys && offWithoutReport["finalText"] as? String == childFinalText
                   && offWithoutReport["status"] as? String == "completed" && offWithoutReport["handle"] as? String == operation
                   && offWithoutReport["childAgentId"] as? String == child.rawValue.uuidString,
                   "setting off, the entry minus report must be today's entry: \(off.entry)")
        let storedJSON = try encoded(stored)
        try expect(jsonEqual(offReport, storedJSON), "setting off, wait_agents must add the filed report: \(off.entry)")

        // (f) Setting ON: the report takes the final text's place.
        settings.set(true, forKey: AgentShortReportConfig.enabledKey)
        try expect(f.api.shortReportsEnabled(), "the mount must read the setting live")
        let on = try await waitEntry()
        var offWithoutText = off.entry
        offWithoutText.removeValue(forKey: "finalText")
        try expect(on.entry["finalText"] == nil && on.entry["finalTextTruncated"] == nil && jsonEqual(on.entry["report"], offReport),
                   "setting on, the report must replace finalText: \(on.entry)")
        try expect(jsonEqual(on.entry, offWithoutText), "setting on, nothing but finalText may change: \(on.entry) vs \(off.entry)")

        // (g) A later turn that files nothing: no report, and the final text
        // comes back, setting on or not. The earlier turn's report is stale.
        let messaged = f.api.dispatch(agentId: parent, requestId: "report-msg", op: "agent.message",
                                      payload: ["agentId": child.rawValue.uuidString, "text": "SECOND-TURN: one more look",
                                                "idempotencyKey": "report-msg-1"])
        guard case .result = messaged else { throw Failure(description: "the second turn was not delivered: \(messaged)") }
        let secondSettled = await waitUntil(timeout: 30, pollInterval: 0.05) { promptLog().contains("SECOND-TURN") && !supervisor.isRunning(child) }
        try expect(secondSettled, "the child must run and settle its second turn")
        let second = try await waitEntry()
        try expect(second.entry["report"] == nil && second.entry["finalText"] as? String == childFinalText
                   && Set(second.entry.keys) == todaysKeys, "a turn that filed no report must carry none: \(second.entry)")
        settings.removeObject(forKey: AgentShortReportConfig.enabledKey)
        let secondOff = try await waitEntry()
        try expect(jsonEqual(secondOff.entry, second.entry), "with no report, the setting must change nothing: \(secondOff.entry)")
    }

    // MARK: - --workspace-hook-pushback-check

    static func words(_ count: Int) -> String { (1...count).map { "word\($0)" }.joined(separator: " ") }

    /// The fields claude 2.1.312 sends on `Stop` / `SubagentStop`
    /// (`p0-claude.md`, stdin fields), with a chosen hand-back.
    static func stopBody(_ event: String, message: String, stopHookActive: Bool = false) throws -> String {
        var body: [String: Any] = [
            "session_id": "37e85ba0-1530-440d-8017-867d34b452b4",
            "transcript_path": "/Users/qa/.claude/projects/-private-tmp-array-p2a/37e85ba0-1530-440d-8017-867d34b452b4.jsonl",
            "cwd": "/private/tmp/array-p2a", "prompt_id": "24ca0f59-014f-4423-b736-cbe44673d9ea",
            "permission_mode": "bypassPermissions", "effort": ["level": "medium"], "hook_event_name": event,
            "stop_hook_active": stopHookActive, "last_assistant_message": message,
            "background_tasks": [] as [Any], "session_crons": [] as [Any],
        ]
        if event == "SubagentStop" {
            body["agent_id"] = "a8b6a5e972481a99f"
            body["agent_type"] = "general-purpose"
            body["agent_transcript_path"] = "/Users/qa/.claude/projects/-private-tmp-array-p2a/subagents/agent-a8b6a5e972481a99f.jsonl"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    static func runPushBack() throws {
        let bench = try makeBench(label: "hook-pushback")
        defer { bench.tearDown() }
        let f = bench.f, supervisor = bench.supervisor, settings = bench.settings
        let child = try bench.delegate("PUSHBACK-CHILD")
        let childConfig = try bench.configuration(for: child)
        let parentConfig = try bench.configuration(for: f.agentId)
        let long = try stopBody("Stop", message: words(600))
        func hook(_ config: WorkspaceMCPConfiguration, _ body: String, endpoint: String? = nil, tokenFile: String? = nil) throws -> WorkspaceHookBridgeChecks.HookRun {
            try WorkspaceHookBridgeChecks.runHook(bench.helper, endpoint: endpoint ?? config.endpoint, agentID: config.agentID,
                                                  tokenFile: tokenFile ?? config.tokenFilePath, body: body, marker: true)
        }
        func silent(_ run: WorkspaceHookBridgeChecks.HookRun, _ what: String) throws {
            try expect(run.status == 0 && run.stdout.isEmpty, "\(what): the hook must exit 0 and print nothing, got \(run.status) \(String(decoding: run.stdout, as: UTF8.self))")
        }
        /// Exactly one JSON object on one line: a block with a reason.
        func block(_ run: WorkspaceHookBridgeChecks.HookRun, _ what: String) throws -> String {
            let text = String(decoding: run.stdout, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard run.status == 0, lines.count == 1,
                  let object = try? JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
                  Set(object.keys) == ["decision", "reason"], object["decision"] as? String == "block",
                  let reason = object["reason"] as? String else {
                throw Failure(description: "\(what): the hook must print one block decision, got \(run.status) \(text)")
            }
            try expect(run.seconds < WorkspaceAgentHook.postTimeoutSeconds, "\(what): the push-back took \(run.seconds) s")
            return reason
        }

        // Off (the default): P1 exactly. Observed, and silent.
        try expect(!f.api.shortReportsEnabled(), "with nothing set, short reports must be off (D1)")
        try silent(try hook(childConfig, long), "setting off, a 600-word Stop")
        try silent(try hook(childConfig, try stopBody("SubagentStop", message: words(600))), "setting off, a 600-word SubagentStop")
        WorkspaceHookBridgeChecks.drainMain()
        try expect((supervisor.hookReceipts[child] ?? []).map(\.event) == ["Stop", "SubagentStop"],
                   "setting off, the events must still be observed: \(supervisor.hookReceipts[child] ?? [])")

        // On.
        settings.set(true, forKey: AgentShortReportConfig.enabledKey)
        let stopReason = try block(try hook(childConfig, long), "setting on, a delegated child's 600-word Stop")
        try expect(stopReason.contains("about 600 words") && stopReason.contains("about \(AgentShortReportConfig.targetWords) words")
                   && stopReason.contains("file") && stopReason.contains("array_report")
                   && stopReason.contains("If your task says not to write files"),
                   "the Stop reason must ask for ~300 words, a file or array_report, and defer to the brief: \(stopReason)")
        try silent(try hook(childConfig, try stopBody("Stop", message: words(600), stopHookActive: true)),
                   "setting on, the continuation after a push-back (stop_hook_active)")
        try silent(try hook(childConfig, try stopBody("Stop", message: words(200))), "setting on, a 200-word Stop")
        try silent(try hook(childConfig, try stopBody("Stop", message: words(AgentShortReportConfig.pushBackWordLimit))),
                   "setting on, a Stop at exactly the limit")
        try silent(try hook(parentConfig, long), "setting on, a top-level agent's own Stop")
        let subagentReason = try block(try hook(parentConfig, try stopBody("SubagentStop", message: words(600))),
                                       "setting on, a Claude subagent's 600-word SubagentStop")
        try expect(!subagentReason.contains("array_report") && subagentReason.contains("file"),
                   "a subagent shares its parent's token, so its reason must not offer array_report: \(subagentReason)")
        try silent(try hook(parentConfig, try stopBody("SubagentStop", message: words(600), stopHookActive: true)),
                   "setting on, a subagent's continuation")
        // A body over the post limit is sent without its message; the count
        // still arrives.
        let huge = try stopBody("Stop", message: words(600) + String(repeating: " x", count: 300_000))
        try expect(huge.utf8.count > WorkspaceAgentHook.maxPostedPayloadBytes, "the huge body must exceed the post limit")
        _ = try block(try hook(childConfig, huge), "setting on, a trimmed body")

        // Fails open, still on: down, silent, refused.
        let down = try hook(childConfig, long, endpoint: "http://127.0.0.1:\(try WorkspaceHookBridgeChecks.unusedLoopbackPort())/workspace-mcp")
        try silent(down, "setting on, Array down")
        try expect(down.seconds < WorkspaceAgentHook.postTimeoutSeconds + 1, "with Array down the hook took \(down.seconds) s")
        let listener = try WorkspaceHookBridgeChecks.SilentListener()
        defer { listener.close() }
        let slow = try hook(childConfig, long, endpoint: "http://127.0.0.1:\(listener.port)/workspace-mcp")
        try silent(slow, "setting on, Array silent")
        try expect(slow.seconds < WorkspaceAgentHook.postTimeoutSeconds + 1, "with Array silent the hook took \(slow.seconds) s")
        try silent(try hook(childConfig, long, tokenFile: parentConfig.tokenFilePath), "setting on, another agent's token")

        // Off again: silent again.
        settings.removeObject(forKey: AgentShortReportConfig.enabledKey)
        try silent(try hook(childConfig, long), "setting off again, a 600-word Stop")
    }
}
