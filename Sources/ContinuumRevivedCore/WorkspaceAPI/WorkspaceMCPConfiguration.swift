import Foundation

/// How delegated helpers' results reach one agent. Exactly one channel per
/// recipient, chosen by capability (can Array start a turn in it?), never by
/// provider: the two must never both be live, or a lead reads every result
/// twice.
public enum WorkspaceResultDelivery: String, Equatable, Sendable {
    /// Array runs the agent and delivers each result into it: a wake when it
    /// is idle, or joining the turn it is running. It is offered no
    /// `wait_agents`, and `operation.get` hands it no result body first.
    case push
    /// Array cannot start a turn in the agent (a CLI it does not run). It
    /// collects with `wait_agents` and is never woken.
    case collect

    /// Set in the MCP server's environment by the host. Absent means `push`,
    /// the host's own default, so the two sides cannot disagree.
    public static let environmentKey = "ARRAY_WORKSPACE_RESULT_DELIVERY"

    public init(environmentValue: String?) {
        self = environmentValue == WorkspaceResultDelivery.collect.rawValue ? .collect : .push
    }
}

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
    public let resultDelivery: WorkspaceResultDelivery
    /// The agent's checkout has standards, so the server lists `array_standards`.
    public let projectStandards: Bool
    /// Tools the server lists with `_meta["anthropic/alwaysLoad"]`, so Claude
    /// Code sends their schemas up front instead of deferring them behind
    /// tool search. Empty for everyone but a Claude Managed lead
    /// (`docs/internals/managed-lead-tool-loading.md`).
    public private(set) var alwaysLoadedTools: [String] = []
    public static let alwaysLoadedToolsEnvironmentKey = "ARRAY_WORKSPACE_ALWAYS_LOADED_TOOLS"

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
        "You are running in a tile on the user's Array canvas. Use the array_* tools of the array_workspace MCP server (in Claude Code, mcp__array_workspace__*; load them with tool search if they are deferred) to see and manage the canvas. To run work in a visible tile, use array_delegate: your built-in subagent tool runs inside this tile and never creates one. array_delegate accepts optional harness (Claude Code, Codex or Pi) and exact catalogue model; omitted fields inherit, except a different harness uses its own catalogue default. Use array_message_agent to start a turn on another agent in your project, and end your turn after delegating: Array delivers each helper's result to you by itself. If your title is wrong or your task has clearly changed, retitle yourself with array_update_agent (nameIntent proactive), but never replace a name the user typed (nameSource user or requested in array_workspace_context); when the user or another agent asks for a rename, use nameIntent requested."

    public init(
        serverExecutable: String,
        endpoint: String,
        agentID: String,
        token: String,
        resultDelivery: WorkspaceResultDelivery = .push,
        projectStandards: Bool = false,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.resultDelivery = resultDelivery
        self.projectStandards = projectStandards
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

    /// This configuration with `tools` always loaded, its Claude config file
    /// rewritten to match (best effort; a launch materializes again).
    public func alwaysLoading(_ tools: [String]) -> WorkspaceMCPConfiguration {
        var copy = self
        copy.alwaysLoadedTools = tools
        try? copy.materialize()
        return copy
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
        var environment = ["ARRAY_WORKSPACE_MCP_ENDPOINT": endpoint,
                           "ARRAY_WORKSPACE_AGENT_ID": agentID,
                           "ARRAY_WORKSPACE_MCP_TOKEN_FILE": tokenFilePath,
                           WorkspaceResultDelivery.environmentKey: resultDelivery.rawValue]
        // Absent, not "0", without standards: the server's environment is
        // then byte-for-byte what it was before `array_standards` existed.
        if projectStandards { environment[ProjectStandards.environmentKey] = "1" }
        // Absent when empty, as above: every other agent's server environment,
        // config file and argv stay exactly what they were.
        if !alwaysLoadedTools.isEmpty {
            environment[Self.alwaysLoadedToolsEnvironmentKey] = alwaysLoadedTools.joined(separator: ",")
        }
        return environment
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
