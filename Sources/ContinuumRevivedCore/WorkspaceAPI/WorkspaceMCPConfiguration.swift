import Foundation

public struct WorkspaceMCPConfiguration: Equatable, Sendable {
    public let serverExecutable: String
    public let endpoint: String
    public let agentID: String
    public let token: String

    public init(serverExecutable: String, endpoint: String, agentID: String, token: String) {
        self.serverExecutable = serverExecutable
        self.endpoint = endpoint
        self.agentID = agentID
        self.token = token
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
