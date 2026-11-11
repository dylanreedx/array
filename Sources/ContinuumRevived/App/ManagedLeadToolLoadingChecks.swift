import AppKit
import ContinuumRevivedCore
import Foundation

/// `--managed-lead-tool-loading-check`
/// (`docs/internals/managed-lead-tool-loading.md`).
///
/// Claude Code defers MCP tools behind ToolSearch unless the server lists a
/// tool with `_meta["anthropic/alwaysLoad"] == true`. A Managed lead must start
/// with the tools its brief tells it to use first; every other agent keeps
/// today's fully deferred list.
///
/// Driven through production: the lead and the solo agent are launched by the
/// real supervisor and Claude runner, the helper by the supervisor's spawn
/// path, all from the mounted app's MCP host. For each, the check reads the
/// `--mcp-config` file from the argv the CLI was really given, starts the
/// server that file names with the environment it names (exactly what Claude
/// does), and reads `tools/list`.
@MainActor
extension ManagedModeChecks {
    /// What a Managed lead's brief names first. Held here as the expected
    /// outcome, not read back from the production constant.
    static let expectedLeadPinnedTools: Set<String> = ["array_delegate", "array_message_agent", "array_status"]
    static let alwaysLoadKey = "anthropic/alwaysLoad"

    static func leadToolLoading() async throws {
        let b = try bench("managed-lead-tool-loading"); defer { b.tearDown() }

        let lead = try await delegate(b, mode: "managed", label: "lead")
        try await settled(b, lead)
        let leadTools = try listedTools(argv(b, lead))
        let pinned = Set(leadTools.filter { alwaysLoads($0) }.compactMap { $0["name"] as? String })
        try expect(pinned == expectedLeadPinnedTools,
                   "a Managed lead's launch must list exactly \(expectedLeadPinnedTools.sorted()) with _meta \(alwaysLoadKey)=true; it listed \(pinned.sorted()) of \(leadTools.count) tools")
        try expect(leadTools.filter { !alwaysLoads($0) }.allSatisfy { $0["_meta"] == nil },
                   "a Managed lead's other tools must stay deferred, with no _meta")

        // A helper the lead delegates: Free, parented, same supervisor path.
        guard let helper = b.supervisor.handleSpawnRequest(SpawnRequest(role: nil, prompt: "helper", isolated: false),
                                                           from: lead, mode: .free) else {
            throw Failure(description: "managed-mode: the lead's helper was not created")
        }
        try await settled(b, helper)
        try expect(b.supervisor.records[helper]?.parentAgentID == lead, "the helper must name the lead as parent")
        let helperTools = try listedTools(argv(b, helper))
        try expect(!helperTools.isEmpty && helperTools.allSatisfy { $0["_meta"] == nil },
                   "a helper's tool list must be unchanged: no tool may carry _meta")

        let solo = try await delegate(b, mode: nil, label: "solo")
        try await settled(b, solo)
        let soloTools = try listedTools(argv(b, solo))
        try expect(!soloTools.isEmpty && soloTools.allSatisfy { $0["_meta"] == nil },
                   "a solo Free agent's tool list must be unchanged: no tool may carry _meta")
        try expect(Set(helperTools.compactMap { $0["name"] as? String }) == Set(leadTools.compactMap { $0["name"] as? String }),
                   "a lead and its helper must be offered the same tools")
        print("Managed lead tool loading checks passed: a Managed lead's real launch lists \(expectedLeadPinnedTools.sorted().joined(separator: ", ")) always-loaded and \(leadTools.count - pinned.count) deferred; its helper and a solo agent list all \(soloTools.count) deferred")
    }

    static func alwaysLoads(_ tool: [String: Any]) -> Bool {
        (tool["_meta"] as? [String: Any])?[alwaysLoadKey] as? Bool == true
    }

    /// The server named by the argv's `--mcp-config`, started as Claude starts
    /// it, answering `tools/list`.
    static func listedTools(_ args: [String]) throws -> [[String: Any]] {
        guard let flag = args.lastIndex(of: "--mcp-config"), flag + 1 < args.count,
              let data = FileManager.default.contents(atPath: args[flag + 1]),
              let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = (file["mcpServers"] as? [String: Any])?["array_workspace"] as? [String: Any],
              let command = server["command"] as? String else {
            throw Failure(description: "managed-mode: the launch has no readable array_workspace --mcp-config: \(args)")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = server["args"] as? [String] ?? []
        var environment = ProcessInfo.processInfo.environment
        environment.merge(server["env"] as? [String: String] ?? [:]) { _, new in new }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n"
            + "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n").utf8))
        try input.fileHandleForWriting.close()
        let text = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in text.split(separator: 10) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               object["id"] as? Int == 2,
               let tools = (object["result"] as? [String: Any])?["tools"] as? [[String: Any]] {
                return tools
            }
        }
        throw Failure(description: "managed-mode: the workspace server answered no tools/list: \(String(decoding: text, as: UTF8.self))")
    }
}
