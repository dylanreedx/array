import ContinuumRevivedCore
import Foundation

/// `.plans/102` P1: Array's observation hooks reach a Claude session through
/// `--settings`, only when the workspace MCP is configured, and never in a way
/// that drops the user's own hooks (`--setting-sources`, `disableAllHooks`).
/// RED before P1: the argv carried no `--settings` at all.
func runClaudeHookBridgeChecks() {
    #if os(macOS)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-hook-bridge-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = WorkspaceMCPConfiguration(
        serverExecutable: "/Applications/Array Dev.app/Contents/MacOS/array-workspace-mcp",
        endpoint: "http://127.0.0.1:4321/workspace-mcp",
        agentID: "00000000-0000-4000-8000-0000000000AA", token: "hook-secret", directory: directory)
    let sessionID = "00000000-0000-4000-8000-000000000001"
    let args = ClaudeAgentRunner.processArguments(
        model: "claude-haiku-5-5", effort: "low", sessionMode: .start, sessionId: sessionID,
        extraArgs: [], workspaceMCP: config)

    // Exactly one `--settings`, before the MCP pair, so the config path stays last.
    let settingsIndices = args.indices.filter { args[$0] == "--settings" }
    expect(settingsIndices.count == 1, "hook bridge: a configured Claude agent must get exactly one --settings: \(args)")
    guard let settingsIndex = settingsIndices.first, settingsIndex + 1 < args.count else { return }
    expect(args.last == config.claudeMCPConfigPath, "hook bridge: the MCP config path must still end the argv: \(args)")

    // Earlier flags unchanged: remove the pair and the argv is what it was.
    var without = args
    without.removeSubrange(settingsIndex...(settingsIndex + 1))
    expect(without == [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--replay-user-messages", "--include-hook-events", "--forward-subagent-text",
        "--model", "claude-haiku-5-5", "--effort", "low", "--permission-mode", "bypassPermissions",
        "--session-id", sessionID,
        "--append-system-prompt", WorkspaceMCPConfiguration.agentGuidance,
        "--allowedTools", "mcp__array_workspace", "--disallowedTools", "ListAgents",
        "--strict-mcp-config", "--mcp-config", config.claudeMCPConfigPath,
    ], "hook bridge: adding --settings changed another flag: \(without)")

    // Never the flags that silently drop the user's hooks (P0 p5).
    expect(!args.contains("--setting-sources"), "hook bridge: --setting-sources drops the user's own hooks: \(args)")
    expect(!args.contains { $0.contains("disableAllHooks") }, "hook bridge: a real turn must never disable hooks")
    expect(!args.contains { $0.contains("hook-secret") }, "hook bridge: the token leaked into argv")

    // The value parses, and registers exactly the observed events.
    let settingsText = args[settingsIndex + 1]
    guard let settings = (try? JSONSerialization.jsonObject(with: Data(settingsText.utf8))) as? [String: Any],
          let hooks = settings["hooks"] as? [String: Any] else {
        expect(false, "hook bridge: --settings is not a JSON object with hooks: \(settingsText)")
        return
    }
    expect(Set(settings.keys) == ["hooks"], "hook bridge: --settings may carry hooks only: \(settings.keys.sorted())")
    let expectedEvents: Set<String> = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                       "Stop", "SubagentStart", "SubagentStop"]
    expect(Set(hooks.keys) == expectedEvents, "hook bridge: registered events drifted: \(hooks.keys.sorted())")
    for event in expectedEvents {
        guard let groups = hooks[event] as? [[String: Any]], groups.count == 1,
              let entries = groups[0]["hooks"] as? [[String: Any]], entries.count == 1 else {
            expect(false, "hook bridge: \(event) must be one group with one hook: \(String(describing: hooks[event]))")
            continue
        }
        let entry = entries[0]
        expect(entry["type"] as? String == "command" && entry["command"] as? String == config.claudeHookCommand,
               "hook bridge: \(event) must run the hook command: \(entry)")
        // Claude's default hook timeout is 600 s.
        expect((entry["timeout"] as? Int).map { $0 > 0 && $0 <= 10 } == true,
               "hook bridge: \(event) needs an explicit short timeout: \(entry)")
        let matcher = groups[0]["matcher"] as? String
        if event == "PreToolUse" || event == "PostToolUse" {
            expect(matcher == "*", "hook bridge: \(event) must match every tool, got \(String(describing: matcher))")
        } else {
            expect(matcher == nil, "hook bridge: \(event) takes no tool matcher, got \(String(describing: matcher))")
        }
    }
    expect(config.claudeHookCommand.contains(config.tokenFilePath) && !config.claudeHookCommand.contains("hook-secret"),
           "hook bridge: the command names the token FILE, never the token")

    // Without the workspace MCP there is no hook and no settings change.
    let plain = ClaudeAgentRunner.processArguments(
        model: "claude-haiku-5-5", effort: "low", sessionMode: .start, sessionId: sessionID, extraArgs: [])
    expect(!plain.contains("--settings") && !plain.contains("--setting-sources"),
           "hook bridge: an agent without workspace tools must get no hook settings: \(plain)")

    // The command survives the shell Claude runs it through: a path with a
    // space (the dev bundle) and a quote arrives as the same argv.
    let odd = directory.appendingPathComponent("Array Dev's bin", isDirectory: true)
    try? FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
    let stub = odd.appendingPathComponent("array-workspace-mcp")
    let argvFile = directory.appendingPathComponent("argv.txt")
    try? "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > '\(argvFile.path)'\n"
        .write(to: stub, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let command = WorkspaceAgentHook.command(executable: stub.path, endpoint: config.endpoint,
                                             agentID: config.agentID, tokenFilePath: odd.appendingPathComponent("t k").path)
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", command]
    try? shell.run()
    shell.waitUntilExit()
    let received = (try? String(contentsOf: argvFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    expect(received == ["hook", "--endpoint", config.endpoint, "--agent-id", config.agentID,
                        "--token-file", odd.appendingPathComponent("t k").path],
           "hook bridge: the shell split the hook command wrongly: \(received)")

    // A receipt keeps the identifying fields and nothing bulky.
    let receipt = AgentHookReceipt(hookPayload: [
        "hook_event_name": "SubagentStop", "session_id": "parent-session", "agent_id": "a1",
        "agent_type": "general-purpose", "last_assistant_message": "long report",
    ], receivedAt: Date(timeIntervalSince1970: 0))
    expect(receipt == AgentHookReceipt(event: "SubagentStop", subagentID: "a1", subagentType: "general-purpose",
                                       sessionID: "parent-session", receivedAt: Date(timeIntervalSince1970: 0)),
           "hook bridge: receipt fields drifted: \(String(describing: receipt))")
    expect(AgentHookReceipt(hookPayload: ["session_id": "s"], receivedAt: Date()) == nil,
           "hook bridge: a body with no event is not a receipt")
    #endif
    print("Claude hook bridge checks passed: one --settings registering exactly the seven observed events with a short timeout, earlier flags unchanged, no --setting-sources or disableAllHooks, nothing without the workspace MCP, and a shell-safe command naming the token file")
}
