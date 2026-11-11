import AppKit
import ContinuumRevivedCore
import Foundation

/// `--standards-resolution-check` (`.plans/116` part 16, step 2;
/// `docs/internals/project-standards-on-demand.md`).
///
/// A temporary non-Array git repository whose standards this check writes,
/// beside a checkout with none. Drives the production launch configuration of
/// all three harnesses (`AppDelegate.workspaceMCPConfiguration`, the Claude and
/// Codex runner configs, `AgentSupervisor.runnerConfig` and the Pi child
/// environment), the real `array-workspace-mcp` binary against the mounted
/// app's listener, the bundled Pi extension under node, and `standards.read`
/// through the production dispatch. RED before the operation: no harness was
/// offered `array_standards` and the host had no `standards.read`.
@MainActor
enum StandardsResolutionChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static let ruleOne = "1. Agents MUST run `make lint` before committing.\nWhy: the CI lint gate rejects the push otherwise.\nEnforced by: CI."
    static let ruleTwo = "2. Agents MUST NOT edit `vendor/`.\nWhy: it is regenerated."
    static let secret = "OUTSIDE-CHECKOUT-SECRET"

    static func run() throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "standards resolution check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let fm = FileManager.default
        let supervisor = f.delegate.qaAgentSupervisor

        // The repository: Pa, made a git repository, with standards written here.
        let repo = f.paRoot
        try git(["init", "-q"], in: repo)
        func write(_ relative: String, _ text: String, under root: URL) throws {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let builds = "# Builds\n\nStatus: Accepted\nLayer: Project\nApplies when: Before you commit or touch `vendor/`.\n\n## Rules\n\n\(ruleOne)\n\n\(ruleTwo)\n"
        try write("docs/standards/project/builds.md", builds, under: repo)
        try write("docs/standards/broken.md", "# Broken\n\nStatus: Draft\n\n## Rules\n\n1. Lost.\n", under: repo)
        try write("leak.md", "# Leak\n\nApplies when: always.\n\n## Rules\n\n1. \(secret)\n", under: f.tempRoot.appendingPathComponent("outside"))
        try fm.createSymbolicLink(at: repo.appendingPathComponent("docs/standards/project/escape.md"),
                                  withDestinationURL: f.tempRoot.appendingPathComponent("outside/leak.md"))
        let role = "---\nname: reviewer\nmodel: openai-codex/gpt-5.6-sol\nreasoning: high\ntools: read\n---\nBody.\n"
        try write(".pi/agents/reviewer.md", role, under: repo)
        // Pb has no standards: everything there must be exactly as before.
        try write(".pi/agents/reviewer.md", role, under: f.pbRoot)

        func spawn(_ harness: AgentHarness, _ root: URL, project: UUID, role: String? = nil) -> AgentID {
            let id = supervisor.spawn(role: role, prompt: nil, cwd: root, harness: harness,
                                      model: harness == .pi ? "openai-codex/gpt-5.6-sol" : "anthropic/claude-sonnet-5-5",
                                      thinking: "high", projectId: project, projectRoot: root)
            supervisor.setWorkspaceToolsEnabled(agentID: id, true)
            return id
        }
        let claudeA = spawn(.claudeCode, repo, project: f.projectPa)
        let codexA = spawn(.codex, repo, project: f.projectPa)
        let piA = spawn(.pi, repo, project: f.projectPa, role: "reviewer")
        let claudeB = spawn(.claudeCode, f.pbRoot, project: f.projectPb)
        let piB = spawn(.pi, f.pbRoot, project: f.projectPb, role: "reviewer")
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        func record(_ id: AgentID) throws -> AgentRecord {
            guard let value = supervisor.records[id] else { throw Failure(description: "no record for \(id)") }
            return value
        }

        let key = ProjectStandards.environmentKey
        let everyTool = WorkspaceMCPToolCatalog.tools.map(\.name)
        let withoutStandards = everyTool.filter { $0 != "array_standards" }
        try expect(everyTool.contains("array_standards") && withoutStandards.count == everyTool.count - 1,
                   "the catalog publishes array_standards once")

        // MARK: Claude and Codex launch configuration

        // The supervisor's own launch builder: the one presence decision, and
        // the MCP configuration the production provider makes from it.
        func launch(_ id: AgentID) throws -> AgentRunnerLaunch { supervisor.runnerLaunch(for: id, record: try record(id)) }
        let launchA = try launch(claudeA), launchCodex = try launch(codexA), launchB = try launch(claudeB)
        try expect(launchA.projectStandards && launchCodex.projectStandards && !launchB.projectStandards,
                   "the launch decides presence from the agent's own checkout")
        guard let claudeConfig = launchA.workspaceMCP, let codexConfig = launchCodex.workspaceMCP,
              let claudeBConfig = launchB.workspaceMCP else {
            throw Failure(description: "production MCP configuration unavailable (build array-workspace-mcp first)")
        }
        defer {
            for config in [claudeConfig, codexConfig, claudeBConfig] {
                try? fm.removeItem(atPath: config.tokenFilePath)
                try? fm.removeItem(atPath: config.claudeMCPConfigPath)
            }
        }
        let claudeRunner = AgentSupervisor.claudeRunnerConfig(for: try record(claudeA), workspaceMCP: claudeConfig)
        try expect(claudeRunner.workspaceMCP?.environment[key] == "1" && claudeConfig.claudeMCPConfigJSON.contains("\"\(key)\":\"1\""),
                   "Claude in a checkout with standards launches its MCP server with \(key)=1")
        let codexRunner = AgentSupervisor.codexRunnerConfig(for: try record(codexA), workspaceMCP: codexConfig)
        try expect(codexRunner.workspaceMCP?.codexConfigOverrides.contains("mcp_servers.array_workspace.env.\(key)=\"1\"") == true,
                   "Codex in a checkout with standards gets \(key)=1 in its MCP overrides")
        try expect(Set(claudeBConfig.environment.keys) == ["ARRAY_WORKSPACE_MCP_ENDPOINT", "ARRAY_WORKSPACE_AGENT_ID",
                                                         "ARRAY_WORKSPACE_MCP_TOKEN_FILE", WorkspaceResultDelivery.environmentKey]
                   && !claudeBConfig.claudeMCPConfigJSON.contains(key),
                   "a checkout without standards launches with exactly the four keys it had before: \(claudeBConfig.environment.keys.sorted())")

        // MARK: The real MCP server against the mounted app

        let claudeReplies = try mcp(claudeConfig, calls: [[:], ["rules": ["project/builds#2"]],
                                                         ["standards": ["../../outside/leak", "/etc/passwd", "project/escape", "broken"]]])
        try expect(claudeReplies.tools == everyTool,
                   "Claude's server lists the whole catalog, array_standards included: \(claudeReplies.tools)")
        let bReplies = try mcp(claudeBConfig, calls: [[:]])
        try expect(bReplies.tools == withoutStandards,
                   "without standards the server lists exactly the catalog it listed before: \(bReplies.tools)")
        try expect(bReplies.calls.first?["error"] != nil && bReplies.calls.first?["result"] == nil,
                   "without standards array_standards is an unknown tool: \(String(describing: bReplies.calls.first))")
        let codexReplies = try mcp(codexConfig, calls: [["standards": ["project/builds"]]])
        try expect(codexReplies.tools == everyTool, "Codex's server lists array_standards")

        // The index, through MCP.
        let index = try structured(claudeReplies.calls[0], "index")
        let indexStandards = index["standards"] as? [[String: Any]] ?? []
        try expect(index["root"] as? String == "docs/standards" && indexStandards.map { $0["id"] as? String } == ["project/builds"],
                   "the index holds this checkout's one valid standard and nothing of any other repository: \(index)")
        try expect(indexStandards.first?["ruleIds"] as? [String] == ["project/builds#1", "project/builds#2"]
                   && indexStandards.first?["rules"] == nil
                   && indexStandards.first?["appliesWhen"] as? String == "Before you commit or touch `vendor/`."
                   && indexStandards.first?["path"] as? String == "docs/standards/project/builds.md",
                   "the index carries trigger, path and rule ids, no rule text: \(indexStandards)")
        let version = ProjectStandards.version(of: Data(builds.utf8))
        try expect(indexStandards.first?["version"] as? String == version, "version is the file's content hash")
        let issues = (index["issues"] as? [[String: Any]] ?? []).map { "\($0["path"] as? String ?? "") \($0["code"] as? String ?? "")" }
        try expect(issues.sorted() == ["docs/standards/broken.md missing_trigger", "docs/standards/project/escape.md outside_checkout"],
                   "a broken standard and a link out are explicit issues: \(issues)")
        // One rule, verbatim.
        let one = try structured(claudeReplies.calls[1], "rule")
        let oneRules = (one["standards"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]] ?? []
        try expect(oneRules.count == 1 && oneRules.first?["id"] as? String == "project/builds#2" && oneRules.first?["text"] as? String == ruleTwo,
                   "a rule id returns that rule verbatim: \(oneRules)")
        // Traversal and broken ids resolve to nothing; nothing outside is read.
        let traversal = try structured(claudeReplies.calls[2], "traversal")
        try expect((traversal["standards"] as? [Any])?.isEmpty == true
                   && traversal["unresolved"] as? [String] == ["../../outside/leak", "/etc/passwd", "project/escape", "broken"],
                   "traversal, absolute and broken ids are unresolved, never read: \(traversal)")
        try expect(!claudeReplies.raw.contains(secret) && !codexReplies.raw.contains(secret), "nothing outside the checkout reaches an agent")
        // Codex: a whole standard.
        let whole = try structured(codexReplies.calls[0], "whole")
        let wholeRules = (whole["standards"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]] ?? []
        try expect(wholeRules.compactMap { $0["text"] as? String } == [ruleOne, ruleTwo], "a standard id returns all its rules verbatim: \(wholeRules)")

        // MARK: Pi launch configuration, argv and extension

        let piLaunch = try launch(piA), piBLaunch = try launch(piB)
        let piConfig = AgentSupervisor.runnerConfig(for: piLaunch.record, spawnDepth: 0, projectStandards: piLaunch.projectStandards)
        let piBConfig = AgentSupervisor.runnerConfig(for: piBLaunch.record, spawnDepth: 0, projectStandards: piBLaunch.projectStandards)
        try expect(piConfig.projectStandards && !piBConfig.projectStandards, "Pi's runner config follows its own checkout")
        let toolsA = piConfig.extraArgs.last?.components(separatedBy: ", ") ?? []
        try expect(toolsA.contains("array_standards"), "a roled Pi agent with standards is allowed array_standards: \(toolsA)")
        try expect(piBConfig.extraArgs == ["--tools", (["read"] + RoleRegistry.spawnToolNames(for: .pi) + withoutStandards).joined(separator: ", ")],
                   "a roled Pi agent without standards gets exactly the argv it got before: \(piBConfig.extraArgs)")
        let inherited = ["PATH": "/usr/bin:/bin", key: "1"]
        let envA = PiAgentRunner.childEnvironment(base: inherited, extraDirs: [], processOwner: "a", projectStandards: piConfig.projectStandards)
        let envB = PiAgentRunner.childEnvironment(base: inherited, extraDirs: [], processOwner: "b", projectStandards: piBConfig.projectStandards)
        try expect(envA[key] == "1" && envB[key] == nil, "Pi's environment is set from its checkout, never inherited from Array's")
        if let registered = try piExtensionTools(environment: envA), let registeredB = try piExtensionTools(environment: envB) {
            try expect(registered == everyTool, "the bundled Pi extension registers array_standards with standards: \(registered)")
            try expect(registeredB == withoutStandards, "and exactly the old tool set without: \(registeredB)")
        } else {
            print("standards resolution: Pi extension leg skipped, node is not installed")
        }

        // MARK: Production dispatch (the Pi bridge's entry) and capabilities

        let piIndex = f.api.dispatch(agentId: piA, requestId: "standards-pi", op: "standards.read", payload: [:])
        guard case .result(let piObject) = piIndex,
              piObject["standards"]?.array?.compactMap({ $0.object?["id"]?.string }) == ["project/builds"] else {
            throw Failure(description: "Pi's dispatch reads the same index: \(piIndex)")
        }
        guard case .error(let missing) = f.api.dispatch(agentId: f.agentId, requestId: "standards-missing", op: "standards.read", payload: [:]),
              missing.code == .notFound, missing.message.contains("docs/standards"), !missing.message.contains(f.pbRoot.path) else {
            throw Failure(description: "a checkout without standards is not_found, naming no absolute path")
        }
        guard case .error(let bad) = f.api.dispatch(agentId: piA, requestId: "standards-bad", op: "standards.read", payload: ["path": "../x"]),
              bad.code == .invalidRequest else {
            throw Failure(description: "a path field is refused, not followed")
        }
        func capabilities(_ id: AgentID) throws -> [String] {
            guard case .result(let ctx) = f.api.dispatch(agentId: id, requestId: "ctx-\(id)", op: "workspace.context", payload: [:]) else {
                throw Failure(description: "workspace.context failed")
            }
            return ctx["capabilities"]?.array?.compactMap(\.string) ?? []
        }
        try expect(try capabilities(claudeA).contains("standards.read") && !(try capabilities(claudeB)).contains("standards.read"),
                   "workspace.context advertises standards.read only where the checkout has standards")
        supervisor.setWorkspaceToolsEnabled(agentID: claudeA, false)
        guard case .error(let off) = f.api.dispatch(agentId: claudeA, requestId: "standards-off", op: "standards.read", payload: [:]),
              off.code == .permissionDenied else {
            throw Failure(description: "with workspace tools off, standards.read is denied like every operation")
        }
    }

    // MARK: - Helpers

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.withLock { bytes.append(data) } }
        func snapshot() -> Data { lock.withLock { bytes } }
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private static func structured(_ response: [String: Any], _ what: String) throws -> [String: Any] {
        guard let result = response["result"] as? [String: Any],
              let reply = result["structuredContent"] as? [String: Any],
              reply["status"] as? String == "ok",
              let body = reply["result"] as? [String: Any] else {
            throw Failure(description: "\(what): expected an ok reply, got \(response)")
        }
        return body
    }

    /// Runs the real `array-workspace-mcp` with a production configuration:
    /// initialize, tools/list, then one `array_standards` call per argument
    /// set. Spins the main run loop so the mounted app's listener can answer.
    private static func mcp(_ config: WorkspaceMCPConfiguration, calls: [[String: Any]]) throws
        -> (tools: [String], calls: [[String: Any]], raw: String) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: config.serverExecutable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Only what the provider would pass: the config's own environment.
        process.environment = config.environment.merging(["PATH": "/usr/bin:/bin"]) { value, _ in value }
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        try process.run()
        var requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
        ]
        for (offset, arguments) in calls.enumerated() {
            requests.append(["jsonrpc": "2.0", "id": 10 + offset, "method": "tools/call",
                             "params": ["name": "array_standards", "arguments": arguments]])
        }
        for request in requests {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        }
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if process.isRunning { process.terminate(); throw Failure(description: "array-workspace-mcp did not finish") }
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        let data = collected.snapshot()
        var byId: [Int: [String: Any]] = [:]
        for line in data.split(separator: 10) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = object["id"] as? Int { byId[id] = object }
        }
        let tools = ((byId[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return (tools, calls.indices.map { byId[10 + $0] ?? [:] }, String(decoding: data, as: UTF8.self))
    }

    /// Loads the bundled Pi extension under node with `environment` and lists
    /// the tools it registers. nil when node is absent.
    private static func piExtensionTools(environment: [String: String]) throws -> [String]? {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        guard let extensionURL = PiExtensionInstaller.bundledExtensionURL(fileName: PiExtensionInstaller.workspaceToolsExtensionFileName) else {
            throw Failure(description: "the bundled workspace tools extension is missing")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("standards-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { pathToFileURL } from "node:url";
        const ext = (await import(pathToFileURL(process.argv[2]).href)).default;
        const names = [];
        const noop = () => {};
        ext({ registerTool: (t) => names.push(t.name), on: noop, registerCommand: noop, registerShortcut: noop, registerFlag: noop });
        console.log(JSON.stringify(names));
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
        guard process.terminationStatus == 0, let names = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw Failure(description: "the Pi extension harness failed: \(String(decoding: data, as: UTF8.self))")
        }
        return names
    }
}
