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
        "You are running in a tile on the user's Array canvas. Use the array_* tools of the array_workspace MCP server (in Claude Code, mcp__array_workspace__*; load them with tool search if they are deferred) to see and manage the canvas. To run work in a visible tile, use array_delegate: your built-in subagent tool runs inside this tile and never creates one. Use array_message_agent to start a turn on another agent in your project, and collect delegated children's results with wait_agents."

    public init(
        serverExecutable: String,
        endpoint: String,
        agentID: String,
        token: String,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.serverExecutable = serverExecutable
        self.endpoint = endpoint
        self.agentID = agentID
        self.token = token
        let filenameID = agentID.map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined()
        self.tokenFilePath = directory.appendingPathComponent("array-workspace-mcp-\(filenameID).token").path
        self.claudeMCPConfigPath = directory.appendingPathComponent("array-workspace-mcp-\(filenameID).json").path
        // Best effort here; a launch calls `materialize()` again and fails
        // loudly if the files cannot be written.
        try? materialize()
    }

    public struct MaterializeError: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let reason: String
        public var description: String {
            "Array could not write its workspace tools config (\(reason)) at \(path)"
        }
    }

    /// Write the private token file and Claude's `--mcp-config` file. A provider
    /// launched against a missing file starts without Array's tools (or refuses
    /// its strict config) and says nothing about why, so the launch path calls
    /// this and surfaces the error instead.
    public func materialize() throws {
        guard FileManager.default.createFile(atPath: tokenFilePath, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw MaterializeError(path: tokenFilePath, reason: String(cString: strerror(errno)))
        }
        do {
            try Data(claudeMCPConfigJSON.utf8).write(to: URL(fileURLWithPath: claudeMCPConfigPath), options: [.atomic])
        } catch {
            throw MaterializeError(path: claudeMCPConfigPath, reason: error.localizedDescription)
        }
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
         "mcp_servers.array_workspace.tool_timeout_sec=\(Self.toolCallTimeoutSeconds)",
         // Measured on codex 0.159.3: under `approval_policy=never` an MCP call
         // to a server without this fails "requires approval, but approval
         // policy is never" — every Array tool, unreached. Array's own grant
         // and approval UI gate its operations, as `--allowedTools` leaves them
         // the only gate for Claude.
         "mcp_servers.array_workspace.default_tools_approval_mode=\"approve\""]
            + environment.keys.sorted().map { key in
                "mcp_servers.array_workspace.env.\(key)=\(Self.tomlString(environment[key] ?? ""))"
            }
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
