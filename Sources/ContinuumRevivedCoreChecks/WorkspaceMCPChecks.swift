import ContinuumRevivedCore
import Foundation

/// Pi tools Claude and Codex deliberately do NOT get over MCP, and why. Every
/// other pi host/delegation tool must exist over MCP under the same name.
private let piOnlyToolNames: [String: String] = [
    // Fire-and-forget spawn through pi's own event stream (P2D.2); Claude and
    // Codex delegate visibly through array_delegate, the same host operation.
    "spawn_agent": "pi event-stream spawn; MCP callers use array_delegate",
    // A third-party pi extension, not Array's.
    "delegate_agent": "user-installed pi extension, not Array's",
]

func runWorkspaceMCPChecks() {
    // MARK: Catalog parity — one definition, read by both transports

    let tools = WorkspaceMCPToolCatalog.tools
    expect(!tools.isEmpty, "the shared workspace tool catalog did not load from the Core resource bundle")
    // The catalog file sits beside the pi extension that reads it (`new URL("./array-workspace-tools.json",
    // import.meta.url)`), so pi and the MCP server read the SAME bytes.
    let extensionPath = PiExtensionInstaller.bundledWorkspaceToolsExtensionPath()
    let catalogURL = PiExtensionInstaller.bundledExtensionURL(fileName: WorkspaceMCPToolCatalog.fileName)
    expect(extensionPath != nil && catalogURL?.deletingLastPathComponent().path
           == extensionPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
           "the MCP catalog is not the file beside continuum-workspace-tools.ts: \(String(describing: catalogURL)) vs \(String(describing: extensionPath))")
    // That pi really reads it is the REAL pi's to witness: `--pi-extension-load-check`
    // loads the extension without its catalog and requires pi to reject it.

    let mcpNames = Set(tools.map(\.name) + [WorkspaceMCPToolCatalog.waitAgentsName])
    let piNames = Set(RoleRegistry.hostToolNames(for: .pi) + RoleRegistry.spawnToolNames(for: .pi))
    let expected = piNames.subtracting(piOnlyToolNames.keys)
    // RED before T3: the MCP catalog held six tools and no wait.
    expect(mcpNames == expected,
           "Claude/Codex MCP tools must equal pi's minus the written pi-only list: missing \(expected.subtracting(mcpNames).sorted()), extra \(mcpNames.subtracting(expected).sorted())")
    expect(tools.map(\.name) == RoleRegistry.hostToolNames(for: .pi),
           "the catalog's host tools must be exactly pi's --tools host allowlist, in order: \(tools.map(\.name))")
    expect(Set(tools.map(\.operation)) == Set(WorkspaceAPIOp.allCases) && Set(tools.map(\.operation)).count == tools.count,
           "every host operation needs exactly one tool, or context() would advertise an op no tool reaches")
    for tool in tools {
        expect(!tool.description.isEmpty && !tool.promptGuidelines.isEmpty,
               "\(tool.name) lost its description or guidelines")
        // MCP has no system-prompt slot, so the guidelines ride in the description.
        expect(tool.mcpDescription.hasPrefix(tool.description)
               && tool.promptGuidelines.allSatisfy(tool.mcpDescription.contains),
               "\(tool.name)'s MCP description dropped pi's guidance")
        expect(tool.inputSchema["type"] == .string("object"), "\(tool.name) schema is not an object schema")
    }
    func required(_ name: String) -> Set<String> {
        guard case .array(let values)? = WorkspaceMCPToolCatalog.tool(named: name)?.inputSchema["required"] else { return [] }
        return Set(values.compactMap { if case .string(let key) = $0 { return key } else { return nil } })
    }
    expect(required("array_delegate") == ["task", "idempotencyKey"]
           && required("array_message_agent") == ["agentId", "text", "idempotencyKey"]
           && required("array_canvas_apply") == ["op", "tileId", "expectedRevision"],
           "required fields drifted from pi's TypeBox definitions")
    expect(WorkspaceMCPToolCatalog.tool(named: "array_delegate")?.operation == .agentDelegate
           && WorkspaceMCPToolCatalog.tool(named: "array_message_agent")?.operation == .agentMessage
           && WorkspaceMCPToolCatalog.tool(named: "array_get_operation")?.operation == .operationGet,
           "delegation tools did not map to their host operations")
    expect(!WorkspaceMCPToolCatalog.serverInstructions.isEmpty
           && WorkspaceMCPToolCatalog.serverInstructions.contains("array_delegate")
           && WorkspaceMCPToolCatalog.serverInstructions.contains(WorkspaceMCPToolCatalog.waitAgentsName),
           "MCP initialize instructions must name delegation and the wait tool")

    // MARK: Provider launch projections

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
        let server = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["mcpServers"] as? [String: Any] }.flatMap { $0["array_workspace"] as? [String: Any] }
        expect((server?["env"] as? [String: String]) == config.environment,
               "the MCP server's endpoint/identity/token file must travel in Claude's server env block")
        expect((server?["timeout"] as? Int) == WorkspaceMCPConfiguration.toolCallTimeoutSeconds * 1000,
               "Claude must wait for a tool call at least as long as an approval can take")
    }
    let tokenAttributes = try? FileManager.default.attributesOfItem(atPath: config.tokenFilePath)
    expect(FileManager.default.contents(atPath: config.tokenFilePath) == Data("secret".utf8)
           && (tokenAttributes?[.posixPermissions] as? Int) == 0o600,
           "the token file must hold the token, readable by its owner only")
    expect(config.environment["ARRAY_WORKSPACE_MCP_TOKEN_FILE"] == config.tokenFilePath
           && !config.environment.values.contains("secret"),
           "the MCP server environment names the token FILE, never the token")
    expect(WorkspaceMCPConfiguration.toolCallTimeoutSeconds >= WorkspaceMCPToolCatalog.waitAgentsTimeoutRange.upperBound,
           "a client must outwait the longest wait_agents call")
    let codexOverrides = config.codexConfigOverrides
    expect(!codexOverrides.contains { $0.contains("secret") }, "Codex MCP config leaked the capability token")
    expect(codexOverrides.contains("mcp_servers.array_workspace.tool_timeout_sec=\(WorkspaceMCPConfiguration.toolCallTimeoutSeconds)"),
           "Codex's 60 s default MCP tool timeout would abandon a pending approval")
    // RED before T4b: codex 0.159.3 refused every Array tool call under
    // approval_policy=never without it (measured against a stand-in server).
    expect(codexOverrides.contains("mcp_servers.array_workspace.default_tools_approval_mode=\"approve\""),
           "Codex refuses an unapproved MCP call under approval_policy=never; Array's own approval must be the only gate")
    expect(config.environment.keys.allSatisfy { key in codexOverrides.contains { $0.hasPrefix("mcp_servers.array_workspace.env.\(key)=") } },
           "Codex's MCP server config must carry the server env block: \(codexOverrides)")
    expect(codexOverrides.contains { $0.hasPrefix("developer_instructions=") && $0.contains("array_delegate") },
           "Codex needs the Array guidance as developer instructions")

    let claudeArgs = ClaudeAgentRunner.processArguments(
        model: "opus", effort: Optional<String>.none, sessionMode: ClaudeSessionMode.start,
        sessionId: "00000000-0000-4000-8000-000000000001", extraArgs: [],
        workspaceMCP: config)
    expect(claudeArgs.contains("--strict-mcp-config") && claudeArgs.contains(config.claudeMCPConfigPath),
           "Claude launch argv did not include the isolated MCP configuration file path")
    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    expect(value(after: "--append-system-prompt", in: claudeArgs) == WorkspaceMCPConfiguration.agentGuidance,
           "Claude must be told it runs in an Array tile and how to delegate visibly")
    // Measured on claude 2.1.291: outside bypass mode -p denies every MCP call
    // until the server is allowed; ListAgents listed tmux peers as tiles.
    expect(value(after: "--allowedTools", in: claudeArgs) == "mcp__array_workspace",
           "Claude must pre-allow Array's own MCP server so Array's approval is the only gate")
    expect(value(after: "--disallowedTools", in: claudeArgs) == "ListAgents",
           "Claude's ListAgents must be withheld in an Array tile")
    // T5: the prompt travels on stdin (stream-json), so nothing positional
    // follows the variadic `--mcp-config` list for it to swallow.
    expect(!claudeArgs.contains("--") && claudeArgs.last == config.claudeMCPConfigPath,
           "Claude's MCP config path must end the argv with no positional prompt after it: \(claudeArgs)")
    let plainClaudeArgs = ClaudeAgentRunner.processArguments(
        model: "opus", effort: Optional<String>.none, sessionMode: ClaudeSessionMode.start,
        sessionId: "00000000-0000-4000-8000-000000000001", extraArgs: [])
    expect(!plainClaudeArgs.contains("--append-system-prompt") && !plainClaudeArgs.contains("--allowedTools"),
           "an agent without workspace tools gets no Array guidance or allowance")
    let codexArgs = CodexCLIBackend.processArguments(
        model: "gpt", effort: Optional<String>.none, sessionMode: CodexCLIBackend.SessionMode.fresh, threadId: nil,
        cwdPath: "/tmp/project", extraArgs: [], prompt: AgentPrompt("hello"), workspaceMCP: config)
    expect(codexArgs.contains("mcp_servers.array_workspace.command=\"/tmp/array-workspace-mcp\""),
           "Codex exec argv did not include the MCP command override")
    let appServerArgs = CodexCLIBackend.appServerArguments(extraArgs: [], workspaceMCP: config)
    expect(codexOverrides.allSatisfy(appServerArgs.contains), "Codex app-server argv must carry every MCP override")
    expect(!claudeArgs.contains { $0.contains("secret") } && !codexArgs.contains { $0.contains("secret") }
           && !appServerArgs.contains { $0.contains("secret") }, "provider argv leaked the MCP token")

    // MARK: The token stays out of the agent's own environment

    // RED before T3: both runners merged the MCP environment — token included —
    // into the agent process, so every shell command inherited it.
    for (name, environment) in [("claude", ClaudeAgentRunner.childEnvironment(workspaceMCP: config)),
                                ("codex", CodexAgentRunner.childEnvironment(workspaceMCP: config))] {
        expect(!environment.values.contains { $0.contains("secret") } && !environment.keys.contains { $0.hasPrefix("ARRAY_WORKSPACE_") },
               "\(name)'s process environment carries the MCP capability: \(environment.keys.filter { $0.hasPrefix("ARRAY_WORKSPACE_") })")
    }
    print("Workspace MCP checks passed: \(tools.count) shared tools + \(WorkspaceMCPToolCatalog.waitAgentsName) match pi minus \(piOnlyToolNames.keys.sorted()), Claude/Codex guidance, allowances and timeouts, and the token out of argv, config and agent env")
}
