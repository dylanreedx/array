import Foundation

public struct WorkspaceMCPConfiguration: Equatable, Sendable {
    public let serverExecutable: String
    public let endpoint: String
    public let agentID: String
    public let token: String
    /// Claude's `--mcp-config` flag takes a filesystem path, unlike Codex's
    /// inline `-c` overrides. Materialize the private per-agent file before
    /// Claude validates its strict configuration.
    public let claudeMCPConfigPath: String
    /// The capability token, in a private per-agent file the MCP server reads.
    /// The token itself never enters the agent's environment (every shell
    /// command it runs would inherit it, and `env` printed it into a
    /// transcript), Claude's config file, or Codex's argv (`ps` shows argv).
    public let tokenFilePath: String

    /// How long a client waits for one workspace tool call. An approval alert
    /// has no deadline of its own, and `wait_agents` blocks for up to an hour:
    /// a client that gave up first would report failure while the operation
    /// went on. Applied to the MCP server's own HTTP requests, Claude's
    /// per-server `timeout` and Codex's `tool_timeout_sec`.
    public static let toolCallTimeoutSeconds = 86_400

    /// One line for the provider's own system/developer prompt, beside the MCP
    /// server's `initialize` instructions: Claude defers MCP tools behind tool
    /// search, so without it the model never learns Array's tools exist.
    public static let agentGuidance =
        "You are running in a tile on the user's Array canvas. Use the array_* tools of the array_workspace MCP server (in Claude Code, mcp__array_workspace__*; load them with tool search if they are deferred) to see and manage the canvas. To run work in a visible tile, use array_delegate: your built-in subagent tool runs inside this tile and never creates one. You can message only agents you created (array_message_agent); collect their results with wait_agents."

    public init(serverExecutable: String, endpoint: String, agentID: String, token: String) {
        self.serverExecutable = serverExecutable
        self.endpoint = endpoint
        self.agentID = agentID
        self.token = token
        let filenameID = agentID.map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined()
        let directory = FileManager.default.temporaryDirectory
        self.tokenFilePath = directory.appendingPathComponent("array-workspace-mcp-\(filenameID).token").path
        FileManager.default.createFile(atPath: tokenFilePath, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        let path = directory.appendingPathComponent("array-workspace-mcp-\(filenameID).json")
        self.claudeMCPConfigPath = path.path
        try? Data(claudeMCPConfigJSON.utf8).write(to: path, options: [.atomic])
    }

    /// The MCP SERVER's environment, delivered only through each provider's
    /// server config (`env`), never merged into the agent process.
    public var environment: [String: String] {
        ["ARRAY_WORKSPACE_MCP_ENDPOINT": endpoint,
         "ARRAY_WORKSPACE_AGENT_ID": agentID,
         "ARRAY_WORKSPACE_MCP_TOKEN_FILE": tokenFilePath]
    }

    public var claudeMCPConfigJSON: String {
        let server: [String: Any] = ["command": serverExecutable, "env": environment,
                                     "timeout": Self.toolCallTimeoutSeconds * 1000]
        let object: [String: Any] = ["mcpServers": ["array_workspace": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public var codexConfigOverrides: [String] {
        ["mcp_servers.array_workspace.command=\(Self.tomlString(serverExecutable))",
         "mcp_servers.array_workspace.args=[]",
         "mcp_servers.array_workspace.tool_timeout_sec=\(Self.toolCallTimeoutSeconds)"]
            + environment.keys.sorted().map { key in
                "mcp_servers.array_workspace.env.\(key)=\(Self.tomlString(environment[key] ?? ""))"
            }
            + ["developer_instructions=\(Self.tomlString(Self.agentGuidance))"]
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
