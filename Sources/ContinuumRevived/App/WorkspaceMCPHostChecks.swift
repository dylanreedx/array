import AppKit
import ContinuumRevivedCore
import Foundation

private struct WorkspaceMCPHostCheckError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

@MainActor
func runWorkspaceMCPHostCheck() throws {
    let host = WorkspaceMCPHost()
    let agentID = AgentID(rawValue: UUID())
    var receivedAgentID: String?
    var receivedOperation: String?
    host.setHandler { request in
        receivedAgentID = request["agentId"] as? String
        receivedOperation = request["op"] as? String
        return [
            "schema": WorkspaceAPISchema.v1,
            "requestId": request["requestId"] as? String ?? "",
            "status": "ok",
            "result": ["accepted": true]
        ]
    }
    let helper = ProcessInfo.processInfo.environment["CONTINUUM_WORKSPACE_MCP_BINARY"]
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/array-workspace-mcp").path
    guard FileManager.default.isExecutableFile(atPath: helper) else {
        throw WorkspaceMCPHostCheckError("workspace MCP helper is missing at \(helper)")
    }
    guard let config = host.configuration(for: agentID, serverExecutable: helper) else {
        throw WorkspaceMCPHostCheckError("workspace MCP host did not issue a registration")
    }

    let process = Process()
    let input = Pipe(); let output = Pipe()
    process.executableURL = URL(fileURLWithPath: helper)
    process.standardInput = input; process.standardOutput = output
    var environment = ProcessInfo.processInfo.environment
    environment.merge(config.environment) { _, new in new }
    process.environment = environment
    try process.run()
    let initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n"
    let list = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n"
    let call = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"array_board_query\",\"arguments\":{}}}\n"
    input.fileHandleForWriting.write(Data((initialize + list + call).utf8))
    try input.fileHandleForWriting.close()
    // The production listener marshals requests onto the main actor. Keep the
    // actor's run loop alive while the helper is exchanging its request.
    while process.isRunning {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw WorkspaceMCPHostCheckError("workspace MCP helper exited \(process.terminationStatus): \(text)")
    }
    guard text.contains("\"protocolVersion\":\"2024-11-05\""),
          text.contains("\"name\":\"array_board_query\"") && text.contains("\"name\":\"array_board_apply\""),
          text.contains("\"status\":\"ok\""),
          receivedAgentID == agentID.rawValue.uuidString,
          receivedOperation == WorkspaceAPIOp.boardQuery.rawValue else {
        throw WorkspaceMCPHostCheckError("workspace MCP child/host exchange was incomplete: output=\(text) receivedAgentID=\(String(describing: receivedAgentID)) receivedOperation=\(String(describing: receivedOperation))")
    }
    print("Workspace MCP host check passed: provider child discovered both board tools and routed an authenticated board query with bound agent identity")
}
