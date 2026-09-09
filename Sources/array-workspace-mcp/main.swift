import Foundation
import ContinuumRevivedCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: WorkspaceMCPJSON?
    let method: String
    let params: WorkspaceMCPJSON?
}

private enum MCPError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRequest
    case unavailable(String)

    var description: String {
        switch self {
        case .usage(let message), .unavailable(let message): return message
        case .invalidRequest: return "invalid MCP request"
        }
    }
}

@main
struct ArrayWorkspaceMCP {
    static func main() async {
        do {
            let server = try Server(arguments: CommandLine.arguments)
            try await server.run()
        } catch {
            fputs("array-workspace-mcp: (error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private struct Server {
        let endpoint: URL
        let agentID: String
        let token: String

        init(arguments: [String]) throws {
            let environment = ProcessInfo.processInfo.environment
            guard let endpointText = environment["ARRAY_WORKSPACE_MCP_ENDPOINT"],
                  let endpoint = URL(string: endpointText), !endpointText.isEmpty else {
                throw MCPError.usage("ARRAY_WORKSPACE_MCP_ENDPOINT is required")
            }
            guard let agentID = environment["ARRAY_WORKSPACE_AGENT_ID"], !agentID.isEmpty,
                  let token = environment["ARRAY_WORKSPACE_MCP_TOKEN"], !token.isEmpty else {
                throw MCPError.usage("ARRAY_WORKSPACE_AGENT_ID and ARRAY_WORKSPACE_MCP_TOKEN are required")
            }
            self.endpoint = endpoint; self.agentID = agentID; self.token = token
        }

        func run() async throws {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8) else { continue }
                let response = await handle(data)
                try write(response)
            }
        }

        func handle(_ data: Data) async -> Data {
            let decoder = JSONDecoder()
            guard let request = try? decoder.decode(JSONRPCRequest.self, from: data), request.jsonrpc == "2.0" else {
                return encode(.object(["jsonrpc": .string("2.0"), "id": .null,
                                      "error": .object(["code": .int(-32600), "message": .string("Invalid Request")])]))
            }
            switch request.method {
            case "initialize":
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null, "result": .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("array-workspace"), "version": .string("0.1")])
                ])]))
            case "notifications/initialized":
                return Data()
            case "tools/list":
                let tools = WorkspaceMCPToolCatalog.tools.map { tool in
                    WorkspaceMCPJSON.object(["name": .string(tool.name), "description": .string(tool.description), "inputSchema": .object(tool.inputSchema)])
                }
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "result": .object(["tools": .array(tools)])]))
            case "tools/call":
                return await call(request)
            case "ping":
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null, "result": .object([:])]))
            default:
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "error": .object(["code": .int(-32601), "message": .string("Method not found")])]))
            }
        }

        func call(_ request: JSONRPCRequest) async -> Data {
            guard case .object(let params) = request.params,
                  case .string(let name)? = params["name"],
                  let tool = WorkspaceMCPToolCatalog.tool(named: name) else {
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "error": .object(["code": .int(-32602), "message": .string("Unknown workspace tool")])]))
            }
            let arguments: WorkspaceMCPJSON
            if case .object(let value)? = params["arguments"] { arguments = .object(value) } else { arguments = .object([:]) }
            let payload: [String: WorkspaceMCPJSON] = [
                "schema": .string(WorkspaceAPISchema.v1),
                "kind": .string("request"),
                "requestId": .string(UUID().uuidString),
                "agentId": .string(agentID),
                "token": .string(token),
                "op": .string(tool.operation.rawValue),
                "payload": arguments
            ]
            do {
                let reply = try await post(.object(payload))
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "result": .object([
                                           "content": .array([.object(["type": .string("text"), "text": .string(reply.jsonString)])]),
                                           "structuredContent": reply
                                       ])]))
            } catch {
                let message = String(describing: error)
                return encode(.object(["jsonrpc": .string("2.0"), "id": request.id ?? .null,
                                       "result": .object([
                                           "isError": .bool(true),
                                           "content": .array([.object(["type": .string("text"), "text": .string(message)])])
                                       ])]))
            }
        }

        func post(_ body: WorkspaceMCPJSON) async throws -> WorkspaceMCPJSON {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.jsonString.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MCPError.unavailable("Array workspace bridge unavailable") }
            return try JSONDecoder().decode(WorkspaceMCPJSON.self, from: data)
        }

        func encode(_ object: WorkspaceMCPJSON) -> Data {
            Data(object.jsonString.utf8)
        }

        func write(_ data: Data) throws {
            guard !data.isEmpty else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
