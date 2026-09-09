import ContinuumRevivedCore
import Foundation

func runWorkspaceMCPChecks() {
    let names = WorkspaceMCPToolCatalog.tools.map(\.name)
    expect(names == [
        "array_workspace_context", "array_open_document", "array_canvas_query", "array_canvas_apply",
        "array_board_query", "array_board_apply"
    ], "native MCP catalog order changed: \(names)")
    expect(WorkspaceMCPToolCatalog.tool(named: "array_canvas_apply")?.operation == .canvasApply,
           "canvas apply did not map to the host operation")
    expect(WorkspaceMCPToolCatalog.tool(named: "array_board_apply")?.operation == .boardApply,
           "board apply did not map to the host operation")
    let config = WorkspaceMCPConfiguration(
        serverExecutable: "/tmp/array-workspace-mcp",
        endpoint: "http://127.0.0.1:43123/workspace-mcp",
        agentID: "00000000-0000-4000-8000-000000000001",
        token: "secret")
    expect(config.claudeMCPConfigJSON.contains("array-workspace-mcp"), "Claude MCP config omitted the server")
    expect(!config.claudeMCPConfigJSON.contains("secret"), "Claude MCP config leaked the capability token")
    expect(FileManager.default.fileExists(atPath: config.claudeMCPConfigPath),
           "Claude MCP config file was not materialized before launch")
    if let data = FileManager.default.contents(atPath: config.claudeMCPConfigPath) {
        let text = String(decoding: data, as: UTF8.self)
        expect(text == config.claudeMCPConfigJSON, "Claude MCP config file contents drifted from its JSON projection")
    }
    expect(config.codexConfigOverrides.count == 2 && config.codexConfigOverrides.allSatisfy { !$0.contains("secret") },
           "Codex MCP config leaked the capability token or changed shape")
    expect(config.environment["ARRAY_WORKSPACE_MCP_TOKEN"] == "secret", "MCP token was not isolated to the child environment")
    let claudeArgs = ClaudeAgentRunner.processArguments(
        model: "opus", effort: Optional<String>.none, sessionMode: ClaudeSessionMode.start,
        sessionId: "00000000-0000-4000-8000-000000000001", extraArgs: [],
        prompt: AgentPrompt("hello"), workspaceMCP: config)
    expect(claudeArgs.contains("--strict-mcp-config") && claudeArgs.contains(config.claudeMCPConfigPath),
           "Claude launch argv did not include the isolated MCP configuration file path")
    if let separator = claudeArgs.firstIndex(of: "--") {
        expect(separator + 1 < claudeArgs.count && claudeArgs[separator + 1] == "hello",
               "Claude prompt was not placed after the option terminator")
    } else {
        expect(false, "Claude launch argv omitted the option terminator before the prompt")
    }
    let codexArgs = CodexCLIBackend.processArguments(
        model: "gpt", effort: Optional<String>.none, sessionMode: CodexCLIBackend.SessionMode.fresh, threadId: nil,
        cwdPath: "/tmp/project", extraArgs: [], prompt: AgentPrompt("hello"), workspaceMCP: config)
    expect(codexArgs.contains("mcp_servers.array_workspace.command=\"/tmp/array-workspace-mcp\""),
           "Codex exec argv did not include the MCP command override")
    expect(!claudeArgs.contains("secret") && !codexArgs.contains("secret"), "provider argv leaked the MCP token")
    print("Workspace MCP checks passed: shared catalog, Claude/Codex config projections, and token isolation")
}
