import AppKit
import ContinuumRevivedCore
import CryptoKit
import Foundation

/// Production delegation, runner, scoped-trust probe and authenticated hook endpoint.
/// The CLI double records actual argv/RPC and executes the configured hook command.
@MainActor
enum ManagedCodexChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static let model = "openai-codex/fixture-managed"
    static func expect(_ value: Bool, _ message: String) throws {
        try ManagedModeChecks.expect(value, "Codex: " + message)
    }
    static func bench() throws -> Bench {
        let b = try WorkspaceAgentReportChecks.makeBench(label: "managed-codex")
        let executable = b.binDir.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "scripts/fixtures/codex-hook-cli.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .ready, models: [model]))
        return b
    }
    static func delegate(_ b: Bench, mode: String?, task: String = "fixture") async throws -> AgentID {
        var payload: [String: Any] = ["task": task, "title": task, "harness": "Codex", "model": model,
                                      "idempotencyKey": UUID().uuidString]
        if let mode { payload["mode"] = mode }
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate", payload)
        guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
              let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "Codex delegation failed: \(reply.reply)")
        }
        return AgentID(rawValue: uuid)
    }
    static func log(_ b: Bench) -> URL { b.binDir.appendingPathComponent("codex.jsonl") }
    static func rows(_ b: Bench, kind: String, session: String? = nil) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: log(b)) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            .filter { $0["kind"] as? String == kind && (session == nil || $0["session"] as? String == session) }
    }
    static func output(_ row: [String: Any]) -> [String: Any] {
        (row["output"] as? [String: Any])?["hookSpecificOutput"] as? [String: Any] ?? [:]
    }
    // Frozen pre-slice app-server argv recipe, independent of production builders.
    // Only runtime endpoint/path/id values and the fixture's returned hashes vary.
    static func previousArguments(_ c: WorkspaceMCPConfiguration) throws -> [String] {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func json(_ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        var overrides = ["approval_policy=never", "sandbox_mode=danger-full-access",
            "plugins.unified-computer-use@openai-bundled.enabled=false", "plugins.computer-use@openai-bundled.enabled=false",
            "plugins.browser@openai-bundled.enabled=false", "mcp_servers.node_repl={command=\"/usr/bin/true\",enabled=false}",
            "mcp_servers.array_workspace.command=\"\(c.serverExecutable)\"", "mcp_servers.array_workspace.args=[]",
            "mcp_servers.array_workspace.tool_timeout_sec=86400", "mcp_servers.array_workspace.default_tools_approval_mode=\"approve\"",
            "mcp_servers.array_workspace.env.ARRAY_WORKSPACE_AGENT_ID=\"\(c.agentID)\"",
            "mcp_servers.array_workspace.env.ARRAY_WORKSPACE_MCP_ENDPOINT=\"\(c.endpoint)\"",
            "mcp_servers.array_workspace.env.ARRAY_WORKSPACE_MCP_TOKEN_FILE=\"\(c.tokenFilePath)\""]
        let command = [c.serverExecutable, "hook", "--endpoint", c.endpoint, "--agent-id", c.agentID, "--token-file", c.tokenFilePath].map(quoted).joined(separator: " ")
        let events = [("SessionStart", "session_start"), ("UserPromptSubmit", "user_prompt_submit"),
                      ("PreToolUse", "pre_tool_use"), ("PostToolUse", "post_tool_use"), ("Stop", "stop"),
                      ("SubagentStart", "subagent_start"), ("SubagentStop", "subagent_stop")]
        var trust: [String: String] = [:]
        for (event, key) in events {
            let matcher = ["PreToolUse", "PostToolUse"].contains(event) ? "matcher=\"*\"," : ""
            let definition = "hooks.\(event)=[{\(matcher)hooks=[{type=\"command\",command=\(try json(command)),timeout=5}]}]"
            overrides.append(definition)
            trust["/<session-flags>/config.toml:\(key):0:0"] = "sha256:" + SHA256.hash(data: Data(definition.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        overrides.append("hooks.state={" + (try trust.keys.sorted().map { try json($0) + "={trusted_hash=" + json(trust[$0]!) + "}" }).joined(separator: ",") + "}")
        return overrides.flatMap { ["-c", $0] } + ["app-server"]
    }
    static func runEnvironment(_ b: Bench) -> () -> Void {
        let keys = ["ARRAY_MANAGED_CODEX_LOG", "CONTINUUM_CODEX_TRANSPORT"]
        let old = keys.map { ProcessInfo.processInfo.environment[$0] }
        setenv(keys[0], log(b).path, 1); setenv(keys[1], "app-server", 1)
        return { for (key, value) in zip(keys, old) { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
    }
    static func launch() async throws {
        let b = try bench(); let restore = runEnvironment(b)
        defer { b.tearDown(); restore() }
        let section = ProcessInfo.processInfo.environment["CONTINUUM_MANAGED_CODEX_SECTION"]
        let free = try await delegate(b, mode: nil)
        try await ManagedModeChecks.settled(b, free)
        let managed = try await delegate(b, mode: "managed")
        try await ManagedModeChecks.settled(b, managed)
        let sid = try thread(b, free), mid = try thread(b, managed)
        let freeLaunch = rows(b, kind: "launch", session: sid).last!
        try expect(freeLaunch["argv"] as? [String] == previousArguments(b.configuration(for: free)), "free argv changed")
        let managedLaunch = rows(b, kind: "launch", session: mid).last!
        try expect(managedLaunch["argv"] as? [String] == previousArguments(b.configuration(for: managed)), "managed launch lost existing scoped hook config")
        if section != "switch" {
            let hooks = rows(b, kind: "hook", session: mid)
            try expect(hooks.contains { output($0)["additionalContext"] as? String == ManagedLeadHookState.brief }, "real managed launch did not inject brief")
            try expect(hooks.contains { output($0)["permissionDecisionReason"] as? String == ManagedLeadHookState.editDenial }, "real configured hook did not deny edit")
            try expect(rows(b, kind: "hook", session: sid).allSatisfy { output($0).isEmpty }, "free launch received policy")
        }
        try expect(b.supervisor.modeSwitchStartsColdCache(for: free, to: .managed), "missing cold-cache flag for Codex thread")
        try expect(!b.supervisor.modeSwitchStartsColdCache(for: free, to: .free), "unchanged mode warned")
        var lastPID = freeLaunch["pid"] as? Int
        for nextMode in [AgentMode.managed, .free] {
            let count = rows(b, kind: "launch", session: sid).count
            try expect(b.supervisor.send("HOLD", to: free), "held turn refused")
            try await AgentPresenceChecks.eventually("Codex held turn did not reach hooks", timeout: 15) {
                rows(b, kind: "held", session: sid).count == (nextMode == .managed ? 1 : 2)
            }
            let heldPID = rows(b, kind: "launch", session: sid).last?["pid"] as? Int
            try expect(b.supervisor.setMode(nextMode, for: free) && b.supervisor.isRunning(free), "switch interrupted current turn")
            let during = try await ManagedModeChecks.hook(b, free, ["hook_event_name": "PreToolUse", "tool_name": "apply_patch", "tool_input": ["command": "patch"]])
            try expect((during["permissionDecision"] as? String == "deny") == (nextMode == .free), "switch changed in-flight hook policy")
            try Data().write(to: URL(fileURLWithPath: log(b).path + ".release"))
            try await ManagedModeChecks.settled(b, free)
            try expect(rows(b, kind: "launch", session: sid).count == count + 1, "switch launched before next turn")
            try expect(b.supervisor.send("next", to: free), "next turn refused")
            try await ManagedModeChecks.settled(b, free)
            let next = rows(b, kind: "launch", session: sid).last!
            let request = next["request"] as? [String: Any]
            try expect(rows(b, kind: "launch", session: sid).count == count + 2 && next["pid"] as? Int != heldPID
                && next["pid"] as? Int != lastPID && request?["method"] as? String == "thread/resume"
                && (request?["params"] as? [String: Any])?["threadId"] as? String == sid, "next turn did not restart and resume stored thread")
            let latest = rows(b, kind: "hook", session: sid).filter { $0["pid"] as? Int == next["pid"] as? Int }
            try expect(!latest.contains { output($0)["additionalContext"] != nil }, "switch re-injected brief on resume")
            try expect(latest.contains { output($0)["permissionDecision"] as? String == "deny" } == (nextMode == .managed), "next turn retained old hook policy")
            lastPID = next["pid"] as? Int
        }
        print("Managed Codex launch passed: production delegation, frozen free argv, scoped hooks enforce policy, deferred switches both directions, new app-server resumes same thread, cold-cache flag")
    }
    static func thread(_ b: Bench, _ id: AgentID) throws -> String {
        guard let sid = b.supervisor.records[id]?.codexThreadId else { throw WorkspaceAgentReportChecks.Failure(description: "runner failed to persist Codex thread") }
        return sid
    }
    static func hooks() async throws {
        let b = try bench(); let restore = runEnvironment(b)
        defer { b.tearDown(); restore() }
        let managed = try await delegate(b, mode: "managed"), free = try await delegate(b, mode: nil)
        try await ManagedModeChecks.settled(b, managed); try await ManagedModeChecks.settled(b, free)
        let section = ProcessInfo.processInfo.environment["CONTINUUM_MANAGED_CODEX_SECTION"]
        func hook(_ payload: [String: Any], id: AgentID? = nil) async throws -> [String: Any] {
            try await ManagedModeChecks.hook(b, id ?? managed, payload)
        }
        func look(_ tool: String, _ input: [String: Any] = [:], id: AgentID? = nil) async throws -> [String: Any] {
            try await hook(["hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input], id: id)
        }
        let start: [String: Any] = ["hook_event_name": "SessionStart", "source": "startup", "session_id": "endpoint-session"]
        if section == nil || section == "brief" {
            let first = try await hook(start)
            try expect(first["hookEventName"] as? String == "SessionStart" && first["additionalContext"] as? String == ManagedLeadHookState.brief, "startup brief missing/wrong format")
            try expect(try await hook(start).isEmpty, "duplicate startup brief")
            for source in ["resume", "compact", "clear", "fork"] {
                try expect(try await hook(["hook_event_name": "SessionStart", "source": source, "session_id": source]).isEmpty, "brief injected on \(source)")
            }
            try expect(try await hook(start, id: free).isEmpty, "free got brief")
        }
        if section == nil || section == "edit" {
            for tool in ["apply_patch", "noteswrite_file", "notesappend_to_file"] {
                let denied = try await look(tool, ["command": "patch"])
                try expect(denied["hookEventName"] as? String == "PreToolUse" && denied["permissionDecision"] as? String == "deny"
                    && denied["permissionDecisionReason"] as? String == ManagedLeadHookState.editDenial, "edit not denied: \(tool)")
                try expect(try await look(tool, id: free).isEmpty, "free edit denied")
            }
            try expect(try await hook(["hook_event_name": "PreToolUse", "tool_name": "apply_patch"])["permissionDecision"] as? String == "deny", "trimmed oversized patch escaped deny")
        }
        _ = try await hook(["hook_event_name": "UserPromptSubmit"])
        for command in ["git status", "git log -5 --oneline", "git diff --stat"] {
            for tool in ["Bash", "exec_command", "shell_command"] {
                try expect(try await look(tool, [tool == "exec_command" ? "cmd" : "command": command]).isEmpty, "git spent budget")
            }
        }
        for tool in ["mcp__array_workspace__array_delegate", "mcp__array_workspace__wait_agents", "spawn_agent", "collaborationwait_agent", "update_plan"] {
            for _ in 0..<4 { try expect(try await look(tool).isEmpty, "coordination spent budget") }
        }
        for (tool, input) in [("Bash", ["command": "ls"]), ("read_mcp_resource", [:]), ("view_image", [:])] {
            try expect(try await look(tool, input).isEmpty, "first three looks refused")
        }
        for tool in ["Bash", "exec_command", "shell", "shell_command", "write_stdin", "read_file", "grep_files", "list_dir",
                     "view_image", "read_mcp_resource", "list_mcp_resources", "list_mcp_resource_templates", "web_search", "webrun",
                     "notesread_file", "historysearch_contents", "mcp__other__search"] {
            let denied = try await look(tool, ["command": "ls", "cmd": "ls"])
            try expect(denied["permissionDecision"] as? String == "deny" && denied["permissionDecisionReason"] as? String == ManagedLeadHookState.denial, "fourth/later quick look allowed: \(tool)")
            try expect(try await look(tool, ["command": "ls", "cmd": "ls"], id: free).isEmpty, "free budget applied")
        }
        try expect(try await look("Bash", ["command": "git diff"]).isEmpty, "git refused after exhaustion")
        try expect(try await look("mcp__array_workspace__array_delegate").isEmpty, "Array refused after exhaustion")
        _ = try await hook(["hook_event_name": "UserPromptSubmit"])
        for _ in 0..<4 {
            try expect(try await hook(["hook_event_name": "PreToolUse", "agent_id": "native", "tool_name": "apply_patch", "tool_input": [:]]).isEmpty, "native child edit denied")
            try expect(try await hook(["hook_event_name": "PreToolUse", "agent_id": "native", "tool_name": "Bash", "tool_input": ["command": "ls"]]).isEmpty, "native child spent budget")
            try expect(try await hook(["hook_event_name": "PreToolUse", "tool_name": "Bash"]).isEmpty, "malformed event denied")
        }
        for command in ["git status; cat file", "git diff > file", "git log $(cat file)"] {
            try expect(try await look("exec_command", ["cmd": command]).isEmpty, "reset did not restore budget")
        }
        try expect(try await look("view_image")["permissionDecision"] as? String == "deny", "composed git escaped budget")
        print("Managed Codex hooks passed: startup-only once, exact deny shape, edit denial, three quick looks, git/Array/coordination free, prompt reset, free/native-child/malformed controls")
    }
}
