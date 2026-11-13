import Foundation
import ContinuumRevivedCore

/// Real helper protocol, not source-string or token-estimate assertions.
func runWorkspaceToolContextChecks() throws {
    final class Output: @unchecked Sendable {
        let lock = NSLock(); var bytes = Data()
        func put(_ data: Data) { lock.withLock { bytes = data } }
        func get() -> Data { lock.withLock { bytes } }
    }
    func object(_ value: WorkspaceMCPJSON?) -> [String: WorkspaceMCPJSON] {
        if case .object(let fields)? = value { return fields }; return [:]
    }
    func text(_ value: WorkspaceMCPJSON?) -> String {
        if case .string(let value)? = value { return value }; return ""
    }
    func words(_ value: String) -> Int { value.split(whereSeparator: \.isWhitespace).count }
    func schemaWords(_ value: WorkspaceMCPJSON) -> Int {
        switch value {
        case .object(let fields): return fields.reduce(0) { $0 + ($1.key == "description" ? words(text($1.value)) : schemaWords($1.value)) }
        case .array(let values): return values.reduce(0) { $0 + schemaWords($1) }
        default: return 0
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-tool-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = root.appendingPathComponent("token")
    try "offline-fixture-token".write(to: token, atomically: true, encoding: .utf8)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("array-workspace-mcp")
    func run(_ diagnostic: String?, delivery: WorkspaceResultDelivery, standards: Bool, chooser: Bool) throws -> [Int: WorkspaceMCPJSON] {
        let p = Process(), input = Pipe(), output = Pipe(), collected = Output(), done = DispatchSemaphore(value: 0)
        p.executableURL = executable; p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["ARRAY_WORKSPACE_MCP_ENDPOINT"] = "http://127.0.0.1:1"
        env["ARRAY_WORKSPACE_AGENT_ID"] = "offline-agent"
        env["ARRAY_WORKSPACE_MCP_TOKEN_FILE"] = token.path
        env[WorkspaceResultDelivery.environmentKey] = delivery.rawValue
        env[ProjectStandards.environmentKey] = standards ? "1" : "0"
        env[ManagedChooser.serverEnvironmentKey] = chooser ? "1" : "0"
        env[WorkspaceMCPConfiguration.alwaysLoadedToolsEnvironmentKey] = "array_delegate"
        env["ARRAY_WORKSPACE_TOOL_CONTEXT_FACTS"] = diagnostic
        p.environment = env
        try p.run()
        DispatchQueue(label: "tool-context-protocol-output").async {
            collected.put(output.fileHandleForReading.readDataToEndOfFile()); done.signal()
        }
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "__unknown_offline_tool__", "arguments": [:] as [String: Any]]]
        ]
        for request in requests { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10])) }
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if p.isRunning { p.terminate(); expect(false, "tool context helper protocol timed out") }
        expect(done.wait(timeout: .now() + 2) == .success && p.terminationStatus == 0, "tool context helper failed")
        var responses: [Int: WorkspaceMCPJSON] = [:]
        for line in collected.get().split(separator: 10) {
            let value = try JSONDecoder().decode(WorkspaceMCPJSON.self, from: Data(line))
            if case .int(let id)? = object(value)["id"] { responses[id] = value }
        }
        expect(responses.count == 3, "helper omitted a protocol response")
        return responses
    }
    for delivery in [WorkspaceResultDelivery.push, .collect] {
        for standards in [false, true] {
            for chooser in [false, true] {
                let full = try run(nil, delivery: delivery, standards: standards, chooser: chooser)
                let off = try run("0", delivery: delivery, standards: standards, chooser: chooser)
                let measured = try run("1", delivery: delivery, standards: standards, chooser: chooser)
                expect(full == off, "default/off protocol changed")
                expect(full[2] == measured[2] && full[3] == measured[3], "diagnostics changed tool text/schema/order/meta or unknown-tool outcome")
                let original = WorkspaceMCPToolCatalog.tools(projectStandards: standards, chooser: chooser)
                var expectedTools = original.map { tool -> WorkspaceMCPJSON in
                    var fields: [String: WorkspaceMCPJSON] = ["name": .string(tool.name), "description": .string(WorkspaceMCPToolCatalog.mcpDescription(tool, for: delivery)), "inputSchema": .object(tool.inputSchema)]
                    if tool.name == "array_delegate" { fields["_meta"] = .object(["anthropic/alwaysLoad": .bool(true)]) }
                    return .object(fields)
                }
                if delivery == .collect {
                    expectedTools.append(.object(["name": .string(WorkspaceMCPToolCatalog.waitAgentsName), "description": .string(WorkspaceMCPToolCatalog.waitAgentsDescription), "inputSchema": .object(WorkspaceMCPToolCatalog.waitAgentsInputSchema)]))
                }
                expect(object(object(full[2])["result"])["tools"] == .array(expectedTools), "wire text/schema/metadata differ from unchanged full catalog contract")
                let before = object(object(full[1])["result"])
                var after = object(object(measured[1])["result"])
                let facts = object(object(after.removeValue(forKey: "_meta"))["array/toolContext"])
                expect(!facts.isEmpty, "initialize lacks host-owned tool-context facts")
                expect(before == after, "diagnostics changed initialize instructions/capabilities")
                let listed = object(object(measured[2])["result"])
                guard case .array(let tools)? = listed["tools"] else { expect(false, "missing actual tools/list"); return }
                let descriptions = tools.map { text(object($0)["description"]) }
                let schemas = tools.map { object($0)["inputSchema"] ?? .null }
                let instructions = text(before["instructions"])
                expect(facts["toolCount"] == .int(tools.count), "tool count differs from wire")
                expect(facts["toolTextWords"] == .int(descriptions.reduce(0) { $0 + words($1) }), "tool words differ from wire")
                expect(facts["toolTextUTF8Bytes"] == .int(descriptions.reduce(0) { $0 + $1.utf8.count }), "tool bytes differ from wire")
                expect(facts["inputSchemaJSONUTF8Bytes"] == .int(schemas.reduce(0) { $0 + $1.jsonString.utf8.count }), "schema bytes differ from wire")
                expect(facts["schemaDescriptionWords"] == .int(schemas.reduce(0) { $0 + schemaWords($1) }), "parameter description words differ from wire")
                expect(facts["initializeInstructionsWords"] == .int(words(instructions)) && facts["initializeInstructionsUTF8Bytes"] == .int(instructions.utf8.count), "initialize accounting differs from wire")
                expect(facts["toolsListResultJSONUTF8Bytes"] == .int(WorkspaceMCPJSON.object(listed).jsonString.utf8.count), "tools/list result bytes differ from wire")
                expect(facts["tokenCount"] == .null && facts["compactVariant"] == .bool(false), "diagnostic invents token counts or compaction")
                print("tool-context \(delivery.rawValue) standards=\(standards) chooser=\(chooser): \(WorkspaceMCPJSON.object(facts).jsonString)")
            }
        }
    }
    print("PASS tool context: actual initialize/tools-list accounting; default/off identical; all names/schemas/text/order preserved across 8 configurations; no token or quality claim")
}
