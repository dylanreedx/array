import AppKit
import ContinuumRevivedCore
import Foundation

/// What a checkout WITHOUT standards launches with, on all three harnesses,
/// normalized so two builds can be compared: Claude's and Codex's MCP server
/// environment, Claude's config file, Codex's overrides, the real server's
/// tools/list, roled and roleless Pi argv and environment, the tools the
/// bundled Pi extension registers, and workspace.context capabilities.
///
/// `scripts/fixtures/standards-base-capture.json` is this capture taken on the
/// base commit (b33595b8, before `array_standards`); `--standards-resolution-check`
/// takes it again on this build and requires equality. To retake it after a
/// deliberate catalog change, run this file's `capture` on the commit the
/// change starts from — never on the change itself.
@MainActor
enum StandardsBaseCapture {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The launch inputs, from whichever build runs the capture.
    struct Launch {
        let mcp: (AgentID, AgentHarness) throws -> WorkspaceMCPConfiguration
        let piArgs: (AgentID) throws -> [String]
        let piEnvironment: (AgentID, [String: String]) throws -> [String: String]
    }

    static let fixturePath = "scripts/fixtures/standards-base-capture.json"

    static func capture(_ f: WorkspaceAPIChecks.Fixture, launch: Launch) throws -> [String: Any] {
        let supervisor = f.delegate.qaAgentSupervisor
        let root = f.pbRoot
        let role = "---\nname: reviewer\nmodel: openai-codex/gpt-5.6-sol\nreasoning: high\ntools: read\n---\nBody.\n"
        let roleURL = root.appendingPathComponent(".pi/agents/reviewer.md")
        try FileManager.default.createDirectory(at: roleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(role.utf8).write(to: roleURL)
        func spawn(_ harness: AgentHarness, role: String?) -> AgentID {
            let id = supervisor.spawn(role: role, prompt: nil, cwd: root, harness: harness,
                                      model: harness == .pi ? "openai-codex/gpt-5.6-sol" : "anthropic/claude-sonnet-5-5",
                                      thinking: "high", projectId: f.projectPb, projectRoot: root)
            supervisor.setWorkspaceToolsEnabled(agentID: id, true)
            // Free, so a Claude Managed lead's always-loaded tools
            // (`ManagedLeadHookState.alwaysLoadedTools`) stay out of a
            // capture about standards; mode changed none of it on the base.
            _ = supervisor.setMode(.free, for: id)
            return id
        }
        let claude = spawn(.claudeCode, role: nil), codex = spawn(.codex, role: nil)
        let roled = spawn(.pi, role: "reviewer"), roleless = spawn(.pi, role: nil)
        var replacements: [(String, String)] = [
            (claude.rawValue.uuidString, "<claude>"), (codex.rawValue.uuidString, "<codex>"),
            (roled.rawValue.uuidString, "<pi-roled>"), (roleless.rawValue.uuidString, "<pi>"),
        ]
        let claudeConfig = try launch.mcp(claude, .claudeCode), codexConfig = try launch.mcp(codex, .codex)
        defer {
            for config in [claudeConfig, codexConfig] {
                try? FileManager.default.removeItem(atPath: config.tokenFilePath)
                try? FileManager.default.removeItem(atPath: config.claudeMCPConfigPath)
            }
        }
        for config in [claudeConfig, codexConfig] {
            replacements += [(config.endpoint, "<endpoint>"), (config.serverExecutable, "<mcp>"),
                             (config.tokenFilePath, "<token-file>"), (config.claudeMCPConfigPath, "<config-file>")]
        }
        replacements += [(f.tempRoot.standardizedFileURL.resolvingSymlinksInPath().path, "<tmp>"), (f.tempRoot.path, "<tmp>")]
        // Claude's config file is JSON, where `/` is written `\/`.
        replacements += replacements.map { ($0.0.replacingOccurrences(of: "/", with: "\\/"), $0.1) }
        func normalized(_ value: Any) -> Any {
            if let text = value as? String {
                return replacements.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            }
            if let list = value as? [Any] { return list.map(normalized) }
            if let object = value as? [String: Any] { return object.mapValues(normalized) }
            return value
        }
        let fixedBase = ["PATH": "/usr/bin:/bin", "HOME": "/capture-home"]
        var piEnvironments: [String: Any] = [:]
        var piExtensions: [String: Any] = [:]
        for (label, id) in [("roled", roled), ("roleless", roleless)] {
            let environment = try launch.piEnvironment(id, fixedBase)
            piEnvironments[label] = environment
            if let tools = try piRegistered(environment.merging(["CONTINUUM_ARRAY_MANAGED_AGENT": "1"]) { value, _ in value }) {
                piExtensions[label] = tools
            }
        }
        func capabilities(_ id: AgentID) throws -> [String] {
            guard case .result(let context) = f.api.dispatch(agentId: id, requestId: "capture-\(id)", op: "workspace.context", payload: [:]) else {
                throw Failure(description: "workspace.context failed for \(id)")
            }
            return context["capabilities"]?.array?.compactMap(\.string) ?? []
        }
        let capture: [String: Any] = [
            "claude": ["mcpEnvironment": claudeConfig.environment, "mcpConfigFile": claudeConfig.claudeMCPConfigJSON,
                       "toolsList": try toolsList(claudeConfig), "capabilities": try capabilities(claude)],
            "codex": ["mcpEnvironment": codexConfig.environment, "overrides": codexConfig.codexConfigOverrides,
                      "toolsList": try toolsList(codexConfig), "capabilities": try capabilities(codex)],
            "pi": ["roledArgs": try launch.piArgs(roled), "rolelessArgs": try launch.piArgs(roleless),
                   "environment": piEnvironments, "extension": piExtensions,
                   "capabilities": try capabilities(roled)],
        ]
        return normalized(capture) as? [String: Any] ?? [:]
    }

    /// The real `array-workspace-mcp`'s tools/list for one configuration.
    static func toolsList(_ config: WorkspaceMCPConfiguration) throws -> [[String: Any]] {
        try config.materialize()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: config.serverExecutable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = config.environment.merging(["PATH": "/usr/bin:/bin"]) { value, _ in value }
        try process.run()
        for request: [String: Any] in [["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
                                        ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]] {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in data.split(separator: 10) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == 2,
               let tools = (object["result"] as? [String: Any])?["tools"] as? [[String: Any]] { return tools }
        }
        throw Failure(description: "array-workspace-mcp listed no tools")
    }

    /// Every tool the bundled Pi extension registers under `environment`, in
    /// full. nil when node is absent.
    static func piRegistered(_ environment: [String: String]) throws -> [[String: Any]]? {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        guard let extensionURL = PiExtensionInstaller.bundledExtensionURL(fileName: PiExtensionInstaller.workspaceToolsExtensionFileName) else {
            throw Failure(description: "the bundled workspace tools extension is missing")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("standards-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { pathToFileURL } from "node:url";
        const ext = (await import(pathToFileURL(process.argv[2]).href)).default;
        const tools = [];
        const noop = () => {};
        ext({ registerTool: (t) => tools.push({ name: t.name, label: t.label, description: t.description,
          promptSnippet: t.promptSnippet, promptGuidelines: t.promptGuidelines, parameters: t.parameters }),
          on: noop, registerCommand: noop, registerShortcut: noop, registerFlag: noop });
        console.log(JSON.stringify(tools));
        """.write(to: harness, atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [harness.path, extensionURL.path]
        process.environment = environment.merging(["NODE_NO_WARNINGS": "1"]) { value, _ in value }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure(description: "the Pi extension harness failed: \(String(decoding: data, as: UTF8.self))")
        }
        return tools
    }

    static func encoded(_ capture: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys, .prettyPrinted])
    }
}
