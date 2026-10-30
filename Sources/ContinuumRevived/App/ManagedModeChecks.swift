import AppKit
import ContinuumRevivedCore
import Foundation

/// Real agent.delegate -> supervisor -> production Claude runner -> disposable
/// CLI, plus the real hook executable, listener and mounted workspace service.
@MainActor
enum ManagedModeChecks {
    typealias Failure = WorkspaceAgentReportChecks.Failure
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: "managed-mode: " + message) }
    }
    static let model = "anthropic/claude-haiku-5-5"
    static let fakeClaude = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    args = sys.argv[1:]
    if '--tools' in args: sys.exit(0)  # no titler/probe effects
    sid = args[args.index('--resume')+1] if '--resume' in args else args[args.index('--session-id')+1]
    with open('managed-argv.jsonl', 'a') as f:
        f.write(json.dumps({'pid':os.getpid(), 'argv':args})+'\n')
    def emit(o):
        print(json.dumps(o), flush=True)
    for line in sys.stdin:
        o = json.loads(line)
        if o.get('type') != 'user': continue
        emit({'type':'system','subtype':'init','session_id':sid,'model':'claude-haiku-5-5','tools':[]})
        if 'HOLD' in json.dumps(o):
            while not os.path.exists('managed-release'): time.sleep(.02)
            os.unlink('managed-release')
        emit({'type':'result','subtype':'success','is_error':False,'session_id':sid,'result':'done','duration_ms':1,'num_turns':1})
    """#

    static func bench(_ label: String) throws -> WorkspaceAgentReportChecks.Bench {
        let b = try WorkspaceAgentReportChecks.makeBench(label: label)
        let executable = b.binDir.appendingPathComponent("claude")
        try fakeClaude.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready,
            models: [model], displayNames: [model: "Fixture"], contextWindows: [model: 200_000]))
        return b
    }

    static func delegate(_ b: WorkspaceAgentReportChecks.Bench, mode: String?, label: String) async throws -> AgentID {
        var payload: [String: Any] = ["task": label, "title": label, "harness": "Claude Code",
            "model": model, "idempotencyKey": UUID().uuidString]
        if let mode { payload["mode"] = mode }
        let config = try b.configuration(for: b.f.agentId)
        let reply = try await WorkspaceAgentReportChecks.call(config, "array_delegate", payload)
        guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
              let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw Failure(description: "managed delegation failed: \(reply.reply)")
        }
        return AgentID(rawValue: uuid)
    }

    static func settled(_ b: WorkspaceAgentReportChecks.Bench, _ id: AgentID) async throws {
        try await AgentPresenceChecks.eventually("managed child did not settle", timeout: 15) {
            b.supervisor.records[id]?.latestTurnAt != nil && !b.supervisor.isRunning(id)
        }
        try expect(b.supervisor.derivedStreamStatus(for: id) == .done, "child did not complete")
    }

    static func launches(_ b: WorkspaceAgentReportChecks.Bench, _ id: AgentID) -> [[String: Any]] {
        guard let cwd = b.supervisor.records[id]?.cwd,
              let data = try? Data(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("managed-argv.jsonl")) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    static func argv(_ b: WorkspaceAgentReportChecks.Bench, _ id: AgentID) throws -> [String] {
        let session = AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[id]!).sessionId
        guard let args = launches(b, id).compactMap({ $0["argv"] as? [String] }).last(where: { $0.contains(session) }) else {
            throw Failure(description: "no real argv for \(id)")
        }
        return args
    }

    static func launch() async throws {
        let b = try bench("managed-launch"); defer { b.tearDown() }
        let managed = try await delegate(b, mode: "managed", label: "managed")
        try await settled(b, managed)
        let section = ProcessInfo.processInfo.environment["CONTINUUM_MANAGED_CHECK_SECTION"]
        let args = try argv(b, managed)
        if section != "switch" && section != "free-argv" {
            try expect(args.contains("--disallowed-tools") && args.contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"), "managed real argv lacks native edit exclusion: \(args)")
        }
        let free = try await delegate(b, mode: nil, label: "free")
        try await settled(b, free)
        let freeArgs = try argv(b, free)
        let config = try b.configuration(for: free)
        let sid = AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[free]!).sessionId
        // Frozen pre-P3 argv, including the exact unchanged hook settings value.
        let expected = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--include-hook-events", "--forward-subagent-text",
            "--model", "claude-haiku-5-5", "--effort", "high", "--permission-mode", "bypassPermissions", "--session-id", sid,
            "--append-system-prompt", WorkspaceMCPConfiguration.agentGuidance, "--allowedTools", "mcp__array_workspace",
            "--disallowedTools", "ListAgents", "--settings", config.claudeHookSettingsJSON,
            "--strict-mcp-config", "--mcp-config", config.claudeMCPConfigPath]
        // Cross-harness delegation uses the catalogue's default thinking.
        var before = expected
        if let i = before.firstIndex(of: "--effort") { before[i + 1] = AgentModelConfig.defaultThinking }
        if section != "switch" {
            try expect(freeArgs == before, "free argv changed: \(freeArgs) expected \(before)")
        }
        try expect(b.supervisor.modeSwitchStartsColdCache(for: free, to: .managed), "missing cold-cache flag")
        let count = launches(b, free).count
        try expect(b.supervisor.setMode(.managed, for: free), "mode switch refused")
        try expect(launches(b, free).count == count, "switch launched before next turn")
        try expect(b.supervisor.send("next", to: free), "next turn refused")
        try await settled(b, free)
        let resumed = try argv(b, free)
        try expect(launches(b, free).count == count + 1, "switch reused the old process")
        try expect(resumed.contains("--resume") && resumed.contains(sid)
            && resumed.contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"), "switch did not restart with resume and managed argv: \(resumed)")

        // A switch during a turn must leave that process/policy intact until
        // the following submitted turn, then remove the native restrictions.
        try expect(b.supervisor.send("HOLD", to: free), "held turn refused")
        try await AgentPresenceChecks.eventually("held turn not running") { b.supervisor.isRunning(free) }
        let heldCount = launches(b, free).count
        try expect(b.supervisor.setMode(.free, for: free) && b.supervisor.isRunning(free), "switch interrupted work")
        let cwd = URL(fileURLWithPath: b.supervisor.records[free]!.cwd)
        try Data().write(to: cwd.appendingPathComponent("managed-release"))
        try await settled(b, free)
        try expect(launches(b, free).count == heldCount, "switch restarted during current turn")
        try expect(b.supervisor.send("free again", to: free), "free turn refused")
        try await settled(b, free)
        let again = try argv(b, free)
        try expect(launches(b, free).count == heldCount + 1 && again.contains("--resume") && !again.contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"), "switch back did not resume free")
        print("Managed mode launch checks passed: real delegated argv, free byte equality, deferred switches both directions and resume, cold-cache flag")
    }

    static func hook(_ b: WorkspaceAgentReportChecks.Bench, _ id: AgentID, _ payload: [String: Any]) async throws -> [String: Any] {
        let c = try b.configuration(for: id)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: b.helper)
        process.arguments = ["hook", "--endpoint", c.endpoint, "--agent-id", c.agentID, "--token-file", c.tokenFilePath]
        var environment = ProcessInfo.processInfo.environment
        environment[PiAgentRunner.arrayHostedEnvironmentKey] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf: Data(body.utf8))
        try input.fileHandleForWriting.close()
        // Yield the actor: a nested RunLoop inside an async main-queue job
        // cannot service the endpoint's queued main-actor request.
        try await AgentPresenceChecks.eventually("hook command did not finish", timeout: 5) { !process.isRunning }
        try expect(process.terminationStatus == 0, "hook failed")
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        if stdout.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw Failure(description: "hook output not JSON")
        }
        return obj["hookSpecificOutput"] as? [String: Any] ?? obj
    }

    static func hooks() async throws {
        let b = try bench("managed-hooks"); defer { b.tearDown() }
        let managed = try await delegate(b, mode: "managed", label: "managed")
        let free = try await delegate(b, mode: "free", label: "free")
        try await settled(b, managed); try await settled(b, free)
        let start: [String: Any] = ["hook_event_name": "SessionStart", "source": "startup", "session_id": "s"]
        if ProcessInfo.processInfo.environment["CONTINUUM_MANAGED_CHECK_SECTION"] != "budget" {
            let first = try await hook(b, managed, start)
            try expect(first["additionalContext"] as? String == ManagedLeadHookState.brief && AgentReport.wordCount(ManagedLeadHookState.brief) <= 200, "managed startup brief absent or too long")
            try expect(try await hook(b, managed, start).isEmpty, "brief repeated on duplicate startup")
            for source in ["resume", "compact", "clear"] {
                try expect(try await hook(b, managed, ["hook_event_name": "SessionStart", "source": source, "session_id": "s2"]).isEmpty, "brief repeated on \(source)")
            }
            try expect(try await hook(b, free, start).isEmpty, "free got lead brief")
        }
        func look(_ id: AgentID, _ tool: String, _ command: String = "") async throws -> [String: Any] {
            try await hook(b, id, ["hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": ["command": command]])
        }
        _ = try await hook(b, managed, ["hook_event_name": "UserPromptSubmit"])
        for command in ["git status", "git diff --stat", "git log -5 --oneline"] {
            for _ in 0..<4 { try expect(try await look(managed, "Bash", command).isEmpty, "git inspection spent budget") }
        }
        for _ in 0..<4 { try expect(try await look(managed, "mcp__array_workspace__array_delegate").isEmpty, "Array tool spent budget") }
        for tool in ["Read", "Grep", "Glob"] { try expect(try await look(managed, tool).isEmpty, "one of first three denied") }
        for tool in ["Bash", "WebFetch", "WebSearch", "mcp__other__search"] {
            let denied = try await look(managed, tool, "ls")
            try expect(denied["permissionDecision"] as? String == "deny" && denied["permissionDecisionReason"] as? String == ManagedLeadHookState.denial, "fourth/later look not denied: \(denied)")
        }
        try expect(try await look(managed, "Bash", "git diff").isEmpty, "git denied after budget")
        try expect(try await look(managed, "mcp__array_workspace__wait_agents").isEmpty, "Array denied after budget")
        for _ in 0..<6 { try expect(try await look(free, "Read").isEmpty, "free agent denied") }
        _ = try await hook(b, managed, ["hook_event_name": "UserPromptSubmit"])
        // Invalid input and native helper tools neither deny nor consume.
        try expect(try await hook(b, managed, ["hook_event_name": "PreToolUse", "tool_name": "Read"]).isEmpty, "malformed event did not fail open")
        for _ in 0..<4 {
            try expect(try await hook(b, managed, ["hook_event_name": "PreToolUse", "agent_id": "native-helper", "tool_name": "Read", "tool_input": [:]]).isEmpty, "native helper inherited lead budget")
        }
        for command in ["git status; cat secret", "git diff > out", "git log $(cat secret)"] {
            try expect(try await look(managed, "Bash", command).isEmpty, "reset did not restore three looks")
        }
        try expect(try await look(managed, "Read")["permissionDecision"] as? String == "deny", "compound git commands bypassed budget")
        print("Managed mode hook checks passed: startup brief once, no resume/compact/free injection, three looks then deny, git/Array exemptions, reset, free and malformed/native-child fail open")
    }

    static func persistence() async throws {
        let b = try bench("managed-persistence"); defer { b.tearDown() }
        let id = try await delegate(b, mode: "managed", label: "managed")
        try await settled(b, id)
        b.supervisor.stopAll()
        let restored = AgentSupervisor(store: AgentStore(smokeTest: false))
        restored.restore()
        defer { restored.stopAll() }
        try expect(restored.records[id]?.mode == .managed, "managed mode lost on relaunch")
        let directory = b.binDir.appendingPathComponent("legacy", isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: directory)
        let original = b.supervisor.records[id]!
        for raw in [nil, "future-mode", 42] as [Any?] {
            var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            obj["mode"] = raw
            let record = try JSONDecoder().decode(AgentRecord.self, from: JSONSerialization.data(withJSONObject: obj))
            try store.upsert(record)
            let legacy = AgentSupervisor(store: store); legacy.restore()
            try expect(legacy.records[id]?.mode == .free, "old/unknown/malformed mode did not load free")
            legacy.stopAll()
        }
        print("Managed mode persistence checks passed: delegated mode survives fresh supervisor restore, absent/unknown/malformed mode loads free")
    }
}
