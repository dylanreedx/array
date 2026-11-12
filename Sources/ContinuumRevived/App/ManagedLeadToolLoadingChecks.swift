import AppKit
import ContinuumRevivedCore
import Foundation

/// `--managed-lead-tool-loading-check`
/// (`docs/internals/managed-lead-tool-loading.md`).
///
/// Claude Code defers MCP tools behind ToolSearch unless the server lists a
/// tool with `_meta["anthropic/alwaysLoad"] == true`. A Claude Managed lead
/// must start with the tools its brief tells it to use first; every other
/// agent keeps today's fully deferred list.
///
/// Driven through production: agents are launched by the real supervisor and
/// Claude or Codex runner against the mounted app's MCP host. For each launch
/// the check takes the server configuration the CLI was given AT LAUNCH (the
/// fake Claude copies its `--mcp-config` file as it starts; Codex carries the
/// server's environment in argv), starts that server with that environment,
/// exactly as the CLI does, and reads `tools/list`.
@MainActor
extension ManagedModeChecks {
    /// What a Managed lead's brief names first. Held here as the expected
    /// outcome, not read back from the production constant.
    static let expectedLeadPinnedTools: Set<String> = ["array_delegate", "array_message_agent", "array_status"]
    static let alwaysLoadKey = "anthropic/alwaysLoad"

    static func leadToolLoading() async throws {
        try await claudeLeadToolLoading()
        try await codexLeadToolLoading()
        print("Managed lead tool loading checks passed: a Claude Managed lead's launch lists \(expectedLeadPinnedTools.sorted().joined(separator: ", ")) always-loaded and the rest deferred; its helper, a solo agent and a Codex Managed lead list every tool deferred; Managed to Free drops the pins and Free to Managed gains them at the next launch")
    }

    static func claudeLeadToolLoading() async throws {
        let b = try bench("managed-lead-tool-loading"); defer { b.tearDown() }

        let lead = try await delegate(b, mode: "managed", label: "lead")
        try await settled(b, lead)
        let leadTools = try listedTools(claudeServer(b, lead))
        try expectPinned(leadTools, "a Claude Managed lead's launch")

        // A helper the lead delegates: Free, parented, same supervisor path.
        guard let helper = b.supervisor.handleSpawnRequest(SpawnRequest(role: nil, prompt: "helper", isolated: false),
                                                           from: lead, mode: .free) else {
            throw Failure(description: "managed-mode: the lead's helper was not created")
        }
        try await settled(b, helper)
        try expect(b.supervisor.records[helper]?.parentAgentID == lead, "the helper must name the lead as parent")
        let helperTools = try listedTools(claudeServer(b, helper))
        try expectAllDeferred(helperTools, "a helper's launch")
        try expect(names(helperTools) == names(leadTools), "a lead and its helper must be offered the same tools")

        let solo = try await delegate(b, mode: nil, label: "solo")
        try await settled(b, solo)
        try expectAllDeferred(try listedTools(claudeServer(b, solo)), "a solo Free agent's launch")

        // Mode switches apply at the next launch, in both directions.
        let launchesBefore = launches(b, lead).count
        try expect(b.supervisor.setMode(.free, for: lead), "Managed to Free refused")
        try expect(b.supervisor.send("as free", to: lead), "the switched lead's turn was refused")
        try await settled(b, lead)
        try expect(launches(b, lead).count == launchesBefore + 1, "Managed to Free did not relaunch")
        try expectAllDeferred(try listedTools(claudeServer(b, lead)), "the next launch after Managed to Free")

        try expect(b.supervisor.setMode(.managed, for: solo), "Free to Managed refused")
        try expect(b.supervisor.send("as lead", to: solo), "the switched solo agent's turn was refused")
        try await settled(b, solo)
        try expectPinned(try listedTools(claudeServer(b, solo)), "the next launch after Free to Managed")
    }

    /// Codex has no always-load pin, so a Codex Managed lead's server is
    /// launched exactly as before.
    static func codexLeadToolLoading() async throws {
        let b = try ManagedCodexChecks.bench(); let restore = ManagedCodexChecks.runEnvironment(b)
        defer { b.tearDown(); restore() }
        let lead = try await ManagedCodexChecks.delegate(b, mode: "managed")
        try await settled(b, lead)
        try expect(b.supervisor.records[lead]?.mode == .managed && b.supervisor.records[lead]?.parentAgentID == nil,
                   "the Codex agent must be a Managed lead")
        let session = try ManagedCodexChecks.thread(b, lead)
        guard let argv = ManagedCodexChecks.rows(b, kind: "launch", session: session).last?["argv"] as? [String] else {
            throw Failure(description: "managed-mode: no recorded Codex launch for the lead")
        }
        let server = try codexServer(argv)
        try expect(server.environment[WorkspaceMCPConfiguration.alwaysLoadedToolsEnvironmentKey] == nil,
                   "a Codex Managed lead's server environment must not name always-loaded tools")
        try expectAllDeferred(try listedTools(server), "a Codex Managed lead's launch")
    }

    // MARK: - Helpers

    struct LaunchedServer {
        let command: String
        let arguments: [String]
        let environment: [String: String]
    }

    static func names(_ tools: [[String: Any]]) -> Set<String> { Set(tools.compactMap { $0["name"] as? String }) }

    static func alwaysLoads(_ tool: [String: Any]) -> Bool {
        (tool["_meta"] as? [String: Any])?[alwaysLoadKey] as? Bool == true
    }

    static func expectPinned(_ tools: [[String: Any]], _ what: String) throws {
        let pinned = names(tools.filter { alwaysLoads($0) })
        try expect(pinned == expectedLeadPinnedTools,
                   "\(what) must list exactly \(expectedLeadPinnedTools.sorted()) with _meta \(alwaysLoadKey)=true; it listed \(pinned.sorted()) of \(tools.count) tools")
        try expect(tools.filter { !alwaysLoads($0) }.allSatisfy { $0["_meta"] == nil },
                   "\(what): every other tool must stay deferred, with no _meta")
    }

    static func expectAllDeferred(_ tools: [[String: Any]], _ what: String) throws {
        let carrying = names(tools.filter { $0["_meta"] != nil })
        try expect(!tools.isEmpty && carrying.isEmpty,
                   "\(what) must list every tool deferred, with no _meta; \(carrying.sorted()) carried one")
    }

    /// The server in the `--mcp-config` file the fake Claude copied as it
    /// started this agent's latest launch.
    static func claudeServer(_ b: WorkspaceAgentReportChecks.Bench, _ id: AgentID) throws -> LaunchedServer {
        let session = AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[id]!).sessionId
        guard let launch = launches(b, id).last(where: { ($0["argv"] as? [String])?.contains(session) == true }),
              let text = launch["mcpConfig"] as? String,
              let file = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let server = (file["mcpServers"] as? [String: Any])?["array_workspace"] as? [String: Any],
              let command = server["command"] as? String else {
            throw Failure(description: "managed-mode: no array_workspace --mcp-config recorded at launch for \(id)")
        }
        return LaunchedServer(command: command, arguments: server["args"] as? [String] ?? [],
                              environment: server["env"] as? [String: String] ?? [:])
    }

    /// The server Codex's `-c mcp_servers.array_workspace.*` overrides name.
    static func codexServer(_ argv: [String]) throws -> LaunchedServer {
        let prefix = "mcp_servers.array_workspace."
        var command: String?
        var environment: [String: String] = [:]
        func tomlString(_ value: Substring) -> String {
            String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        for item in argv where item.hasPrefix(prefix) {
            let parts = item.dropFirst(prefix.count).split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0] == "command" { command = tomlString(parts[1]) }
            if parts[0].hasPrefix("env.") { environment[String(parts[0].dropFirst(4))] = tomlString(parts[1]) }
        }
        guard let command else { throw Failure(description: "managed-mode: the Codex launch names no array_workspace server: \(argv)") }
        return LaunchedServer(command: command, arguments: [], environment: environment)
    }

    /// The server started as the CLI starts it, answering `tools/list`.
    static func listedTools(_ server: LaunchedServer) throws -> [[String: Any]] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: server.command)
        process.arguments = server.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(server.environment) { _, new in new }
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
