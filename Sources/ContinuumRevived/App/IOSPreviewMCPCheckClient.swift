import Foundation
import ContinuumRevivedCore

/// QA only: real native-provider MCP executable -> authenticated loopback host
/// -> production device dispatcher. Stores no credential in logs or argv.
@MainActor
final class IOSPreviewMCPCheckClient {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var exceeded = false
        func append(_ data: Data) {
            lock.withLock {
                if bytes.count + data.count > 8 * 1024 * 1024 { exceeded = true }
                else { bytes.append(data) }
            }
        }
        func snapshot() -> (Data, Bool) { lock.withLock { (bytes, exceeded) } }
    }
    private let host = WorkspaceMCPHost()
    private let configuration: WorkspaceMCPConfiguration
    init(api: WorkspaceAPIService, agent: AgentID) throws {
        let helper = ProcessInfo.processInfo.environment["CONTINUUM_WORKSPACE_MCP_BINARY"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/array-workspace-mcp").path
        host.setHandler { [weak api] request, reply in
            guard let api else { reply(["status": "error"]); return }
            api.handleMCPRequest(request, completion: reply)
        }
        guard let config = host.configuration(for: agent, serverExecutable: helper), FileManager.default.isExecutableFile(atPath: helper) else {
            throw WorkspaceAPIDeviceChecks.Failure(message: "rebuilt native MCP helper required")
        }
        configuration = config
    }
    func close() {
        try? FileManager.default.removeItem(atPath: configuration.tokenFilePath)
        try? FileManager.default.removeItem(atPath: configuration.claudeMCPConfigPath)
    }
    func call(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        let process = Process(), input = Pipe(), output = Pipe(), collected = Output()
        process.executableURL = URL(fileURLWithPath: configuration.serverExecutable)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.merge(configuration.environment) { _, value in value }
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        try process.run()
        defer { if process.isRunning { process.terminate() }; output.fileHandleForReading.readabilityHandler = nil }
        for request: [String: Any] in [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        ] {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        }
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !process.isRunning else { throw WorkspaceAPIDeviceChecks.Failure(message: "native device MCP call timed out") }
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        let (data, exceeded) = collected.snapshot()
        guard !exceeded, process.terminationStatus == 0 else { throw WorkspaceAPIDeviceChecks.Failure(message: "native MCP helper failed or exceeded its image budget") }
        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == 2,
                  let result = object["result"] as? [String: Any] else { continue }
            return result
        }
        throw WorkspaceAPIDeviceChecks.Failure(message: "native MCP child did not return a device result")
    }
}
