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

    public init(serverExecutable: String, endpoint: String, agentID: String, token: String) {
        self.serverExecutable = serverExecutable
        self.endpoint = endpoint
        self.agentID = agentID
        self.token = token
        let filenameID = agentID.map { character in
            character.isLetter || character.isNumber ? String(character) : "_"
        }.joined()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-workspace-mcp-\(filenameID).json")
        self.claudeMCPConfigPath = path.path
        let object: [String: Any] = ["mcpServers": ["array_workspace": ["command": serverExecutable]]]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: path, options: [.atomic])
        }
    }

    public var environment: [String: String] {
        ["ARRAY_WORKSPACE_MCP_ENDPOINT": endpoint,
         "ARRAY_WORKSPACE_AGENT_ID": agentID,
         "ARRAY_WORKSPACE_MCP_TOKEN": token]
    }

    public var claudeMCPConfigJSON: String {
        let object: [String: Any] = ["mcpServers": ["array_workspace": ["command": serverExecutable]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public var codexConfigOverrides: [String] {
        ["mcp_servers.array_workspace.command=\(Self.tomlString(serverExecutable))",
         "mcp_servers.array_workspace.args=[]"]
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
