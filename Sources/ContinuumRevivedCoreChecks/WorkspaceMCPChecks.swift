import ContinuumRevivedCore
import Foundation

/// Pi tools Claude and Codex deliberately do NOT get over MCP, and why. Every
/// other pi host/delegation tool must exist over MCP under the same name.
private let piOnlyToolNames: [String: String] = [
    // Fire-and-forget spawn through pi's own event stream (P2D.2); Claude and
    // Codex delegate visibly through array_delegate, the same host operation.
    "spawn_agent": "pi event-stream spawn; MCP callers use array_delegate",
    // A third-party pi extension, not Array's.
    "delegate_agent": "user-installed pi extension, not Array's",
]

func runWorkspaceMCPChecks() {
    // MARK: Catalog parity — one definition, read by both transports

    let tools = WorkspaceMCPToolCatalog.tools
    expect(!tools.isEmpty, "the shared workspace tool catalog did not load from the Core resource bundle")
    // The catalog file sits beside the pi extension that reads it (`new URL("./array-workspace-tools.json",
    // import.meta.url)`), so pi and the MCP server read the SAME bytes.
    let extensionPath = PiExtensionInstaller.bundledWorkspaceToolsExtensionPath()
    let catalogURL = PiExtensionInstaller.bundledExtensionURL(fileName: WorkspaceMCPToolCatalog.fileName)
    expect(extensionPath != nil && catalogURL?.deletingLastPathComponent().path
           == extensionPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
           "the MCP catalog is not the file beside continuum-workspace-tools.ts: \(String(describing: catalogURL)) vs \(String(describing: extensionPath))")
    // That pi really reads it is the REAL pi's to witness: `--pi-extension-load-check`
    // loads the extension without its catalog and requires pi to reject it.

    let mcpNames = Set(tools.map(\.name) + [WorkspaceMCPToolCatalog.waitAgentsName])
    let piNames = Set(RoleRegistry.hostToolNames(for: .pi) + RoleRegistry.spawnToolNames(for: .pi))
    let expected = piNames.subtracting(piOnlyToolNames.keys)
    // RED before T3: the MCP catalog held six tools and no wait.
    expect(mcpNames == expected,
           "Claude/Codex MCP tools must equal pi's minus the written pi-only list: missing \(expected.subtracting(mcpNames).sorted()), extra \(mcpNames.subtracting(expected).sorted())")
    expect(tools.map(\.name) == RoleRegistry.hostToolNames(for: .pi),
           "the catalog's host tools must be exactly pi's --tools host allowlist, in order: \(tools.map(\.name))")
    expect(Set(tools.map(\.operation)) == Set(WorkspaceAPIOp.allCases) && Set(tools.map(\.operation)).count == tools.count,
           "every host operation needs exactly one tool, or context() would advertise an op no tool reaches")
    for tool in tools {
        expect(!tool.description.isEmpty && !tool.promptGuidelines.isEmpty,
               "\(tool.name) lost its description or guidelines")
        // MCP has no system-prompt slot, so the guidelines ride in the description.
        expect(tool.mcpDescription.hasPrefix(tool.description)
               && tool.promptGuidelines.allSatisfy(tool.mcpDescription.contains),
               "\(tool.name)'s MCP description dropped pi's guidance")
        expect(tool.inputSchema["type"] == .string("object"), "\(tool.name) schema is not an object schema")
    }
    func required(_ name: String) -> Set<String> {
        guard case .array(let values)? = WorkspaceMCPToolCatalog.tool(named: name)?.inputSchema["required"] else { return [] }
        return Set(values.compactMap { if case .string(let key) = $0 { return key } else { return nil } })
    }
    expect(required("array_delegate") == ["task", "idempotencyKey"]
           && required("array_message_agent") == ["agentId", "text", "idempotencyKey"]
           && required("array_canvas_apply") == ["op", "tileId", "expectedRevision"],
           "required fields drifted from pi's TypeBox definitions")
    func requiredAlternatives(_ value: WorkspaceMCPJSON?) -> Set<Set<String>> {
        guard case .array(let clauses)? = value else { return [] }
        return Set(clauses.compactMap { clause -> Set<String>? in
            guard case .object(let fields) = clause,
                  case .array(let values)? = fields["required"] else { return nil }
            return Set(values.compactMap { if case .string(let key) = $0 { return key } else { return nil } })
        })
    }
    func operationCondition(_ value: WorkspaceMCPJSON?, _ op: String, field: String = "op") -> WorkspaceMCPJSON? {
        guard case .array(let clauses)? = value else { return nil }
        for clause in clauses {
            guard case .object(let condition) = clause,
                  case .object(let ifSchema)? = condition["if"],
                  case .object(let properties)? = ifSchema["properties"],
                  case .object(let operation)? = properties[field],
                  operation["const"] == .string(op),
                  case .object(let thenSchema)? = condition["then"] else { continue }
            return thenSchema["anyOf"]
        }
        return nil
    }
    let openSchema = WorkspaceMCPToolCatalog.tool(named: "array_open_document")?.inputSchema
    let operationSchema = WorkspaceMCPToolCatalog.tool(named: "array_get_operation")?.inputSchema
    let canvasSchema = WorkspaceMCPToolCatalog.tool(named: "array_canvas_apply")?.inputSchema
    let deviceSchema = WorkspaceMCPToolCatalog.tool(named: "array_device_open")?.inputSchema
    expect(requiredAlternatives(deviceSchema?["anyOf"]) == [["tileId"], ["zoneId", "templateId", "allowBoot"], ["zoneId", "deviceId"]],
           "device.open must distinguish reconnect, fresh-template creation and receipt-owned restoration")
    expect(required("array_device_observe") == ["checkoutHandle", "sessionId"] &&
           required("array_device_act") == ["checkoutHandle", "sessionId", "observationId", "kind", "idempotencyKey"],
           "visual device actions must require explicit scope, a host observation and retry identity")
    let actionSchema = WorkspaceMCPToolCatalog.tool(named: "array_device_act")?.inputSchema
    for (kind, fields) in [("tap", ["x", "y"]), ("swipe", ["x", "y", "endX", "endY", "milliseconds"]),
                            ("text", ["text"]), ("key", ["key"]), ("rotate", ["orientation"])] {
        expect(requiredAlternatives(operationCondition(actionSchema?["allOf"], kind, field: "kind")) == [Set(fields)],
               "bounded device \(kind) must require its typed fields in every provider schema")
    }
    let buildSchema = WorkspaceMCPToolCatalog.tool(named: "array_device_build_run")?.inputSchema
    expect(required("array_device_build_run") == ["checkoutHandle", "kind"] &&
           requiredAlternatives(operationCondition(buildSchema?["allOf"], "start", field: "kind")) == [["sessionId", "projectFile", "scheme", "idempotencyKey"]] &&
           requiredAlternatives(operationCondition(buildSchema?["allOf"], "cancel", field: "kind")) == [["operationId"]],
           "build schema must require explicit start identity/scope and permit scoped cancellation without a preview session")
    expect(requiredAlternatives(openSchema?["anyOf"]) == [["relativePath"], ["artifactHandle"]],
           "artifact.open must require a path or artifactHandle in its shared schema")
    expect(requiredAlternatives(operationSchema?["anyOf"]) == [["operationId"], ["idempotencyKey"]],
           "operation.get must reject a lookup with neither operationId nor idempotencyKey")
    expect(requiredAlternatives(operationCondition(canvasSchema?["allOf"], "move")) == [["origin"], ["worldFrame"]]
           && requiredAlternatives(operationCondition(canvasSchema?["allOf"], "resize")) == [["size"], ["worldFrame"]],
           "canvas.apply must require move geometry or resize geometry according to op")
    expect(WorkspaceMCPToolCatalog.tool(named: "array_delegate")?.operation == .agentDelegate
           && WorkspaceMCPToolCatalog.tool(named: "array_message_agent")?.operation == .agentMessage
           && WorkspaceMCPToolCatalog.tool(named: "array_get_operation")?.operation == .operationGet,
           "delegation tools did not map to their host operations")
    expect(!WorkspaceMCPToolCatalog.serverInstructions.isEmpty
           && WorkspaceMCPToolCatalog.serverInstructions.contains("array_workspace_context")
           && WorkspaceMCPToolCatalog.serverInstructions.contains("array_delegate")
           && WorkspaceMCPToolCatalog.serverInstructions.contains(WorkspaceMCPToolCatalog.waitAgentsName)
           && WorkspaceMCPToolCatalog.serverInstructions.contains("first delegation"),
           "MCP initialize instructions must carry Array tile, delegation, approval, and wait guidance")
    for (surface, text) in [("MCP initialize instructions", WorkspaceMCPToolCatalog.serverInstructions),
                            ("Claude's appended prompt", WorkspaceMCPConfiguration.agentGuidance)] {
        expect(text.contains("array_update_agent") && text.contains("nameIntent proactive")
               && text.contains("nameIntent requested") && text.contains("never replace a name the user typed"),
               "\(surface) must tell agents to retitle themselves and when not to")
    }

    // MARK: Provider launch projections

    let config = WorkspaceMCPConfiguration(
        serverExecutable: "/tmp/array-workspace-mcp",
        endpoint: "http://127.0.0.1:43123/workspace-mcp",
        agentID: "00000000-0000-4000-8000-000000000001",
        token: "secret")
    expect(config.claudeMCPConfigJSON.contains("array-workspace-mcp"), "Claude MCP config omitted the server")
    expect(!config.claudeMCPConfigJSON.contains("secret"), "Claude MCP config leaked the capability token")
    expect(FileManager.default.fileExists(atPath: config.claudeMCPConfigPath),
           "Claude MCP config file was not materialized before launch")
    if let data = FileManager.default.contents(atPath: config.claudeMCPConfigPath) {
        let text = String(decoding: data, as: UTF8.self)
        expect(text == config.claudeMCPConfigJSON, "Claude MCP config file contents drifted from its JSON projection")
        let server = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["mcpServers"] as? [String: Any] }.flatMap { $0["array_workspace"] as? [String: Any] }
        expect((server?["env"] as? [String: String]) == config.environment,
               "the MCP server's endpoint/identity/token file must travel in Claude's server env block")
        expect((server?["timeout"] as? Int) == WorkspaceMCPConfiguration.toolCallTimeoutSeconds * 1000,
               "Claude must wait for a tool call at least as long as an approval can take")
    }
    let tokenAttributes = try? FileManager.default.attributesOfItem(atPath: config.tokenFilePath)
    expect(FileManager.default.contents(atPath: config.tokenFilePath) == Data("secret".utf8)
           && (tokenAttributes?[.posixPermissions] as? Int) == 0o600,
           "the token file must hold the token, readable by its owner only")
    expect(config.environment["ARRAY_WORKSPACE_MCP_TOKEN_FILE"] == config.tokenFilePath
           && !config.environment.values.contains("secret"),
           "the MCP server environment names the token FILE, never the token")
    expect(WorkspaceMCPConfiguration.toolCallTimeoutSeconds >= WorkspaceMCPToolCatalog.waitAgentsTimeoutRange.upperBound,
           "a client must outwait the longest wait_agents call")
    let codexOverrides = config.codexConfigOverrides
    expect(!codexOverrides.contains { $0.contains("secret") }, "Codex MCP config leaked the capability token")
    expect(codexOverrides.contains("mcp_servers.array_workspace.tool_timeout_sec=\(WorkspaceMCPConfiguration.toolCallTimeoutSeconds)"),
           "Codex's 60 s default MCP tool timeout would abandon a pending approval")
    // RED before T4b: codex 0.159.3 refused every Array tool call under
    // approval_policy=never without it (measured against a stand-in server).
    expect(codexOverrides.contains("mcp_servers.array_workspace.default_tools_approval_mode=\"approve\""),
           "Codex refuses an unapproved MCP call under approval_policy=never; Array's own approval must be the only gate")
    expect(config.environment.keys.allSatisfy { key in codexOverrides.contains { $0.hasPrefix("mcp_servers.array_workspace.env.\(key)=") } },
           "Codex's MCP server config must carry the server env block: \(codexOverrides)")

    let claudeArgs = ClaudeAgentRunner.processArguments(
        model: "opus", effort: Optional<String>.none, sessionMode: ClaudeSessionMode.start,
        sessionId: "00000000-0000-4000-8000-000000000001", extraArgs: [],
        workspaceMCP: config)
    expect(claudeArgs.contains("--strict-mcp-config") && claudeArgs.contains(config.claudeMCPConfigPath),
           "Claude launch argv did not include the isolated MCP configuration file path")
    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    expect(value(after: "--append-system-prompt", in: claudeArgs) == WorkspaceMCPConfiguration.agentGuidance,
           "Claude must be told it runs in an Array tile and how to delegate visibly")
    // Measured on claude 2.1.291: outside bypass mode -p denies every MCP call
    // until the server is allowed; ListAgents listed tmux peers as tiles.
    expect(value(after: "--allowedTools", in: claudeArgs) == "mcp__array_workspace",
           "Claude must pre-allow Array's own MCP server so Array's approval is the only gate")
    expect(value(after: "--disallowedTools", in: claudeArgs) == "ListAgents",
           "Claude's ListAgents must be withheld in an Array tile")
    // T5: the prompt travels on stdin (stream-json), so nothing positional
    // follows the variadic `--mcp-config` list for it to swallow.
    expect(!claudeArgs.contains("--") && claudeArgs.last == config.claudeMCPConfigPath,
           "Claude's MCP config path must end the argv with no positional prompt after it: \(claudeArgs)")
    let plainClaudeArgs = ClaudeAgentRunner.processArguments(
        model: "opus", effort: Optional<String>.none, sessionMode: ClaudeSessionMode.start,
        sessionId: "00000000-0000-4000-8000-000000000001", extraArgs: [])
    expect(!plainClaudeArgs.contains("--append-system-prompt") && !plainClaudeArgs.contains("--allowedTools"),
           "an agent without workspace tools gets no Array guidance or allowance")
    let codexArgs = CodexCLIBackend.processArguments(
        model: "gpt", effort: Optional<String>.none, sessionMode: CodexCLIBackend.SessionMode.fresh, threadId: nil,
        cwdPath: "/tmp/project", extraArgs: [], prompt: AgentPrompt("hello"), workspaceMCP: config)
    expect(codexArgs.contains("mcp_servers.array_workspace.command=\"/tmp/array-workspace-mcp\""),
           "Codex exec argv did not include the MCP command override")
    let appServerArgs = CodexCLIBackend.appServerArguments(extraArgs: [], workspaceMCP: config)
    expect(codexOverrides.allSatisfy(appServerArgs.contains), "Codex app-server argv must carry every MCP override")
    func hasDeveloperInstructionsCLIOverride(_ args: [String]) -> Bool {
        zip(args, args.dropFirst()).contains { flag, value in
            flag == "-c" && value.hasPrefix("developer_instructions=")
        }
    }
    expect(!hasDeveloperInstructionsCLIOverride(codexArgs)
           && !hasDeveloperInstructionsCLIOverride(appServerArgs),
           "Neither Codex exec nor app-server launch may override the user's developer_instructions")
    expect(!claudeArgs.contains { $0.contains("secret") } && !codexArgs.contains { $0.contains("secret") }
           && !appServerArgs.contains { $0.contains("secret") }, "provider argv leaked the MCP token")

    // MARK: The token stays out of the agent's own environment

    // RED before T3: both runners merged the MCP environment — token included —
    // into the agent process, so every shell command inherited it.
    for (name, environment) in [("claude", ClaudeAgentRunner.childEnvironment(workspaceMCP: config)),
                                ("codex", CodexAgentRunner.childEnvironment(workspaceMCP: config))] {
        expect(!environment.values.contains { $0.contains("secret") } && !environment.keys.contains { $0.hasPrefix("ARRAY_WORKSPACE_") },
               "\(name)'s process environment carries the MCP capability: \(environment.keys.filter { $0.hasPrefix("ARRAY_WORKSPACE_") })")
    }
    runMCPConfigMaterializeFailureCheck()
    runToolResultImageChecks()
    print("Workspace MCP checks passed: \(tools.count) shared tools + \(WorkspaceMCPToolCatalog.waitAgentsName) match pi minus \(piOnlyToolNames.keys.sorted()), Claude/Codex guidance, allowances and timeouts, and the token out of argv, config and agent env")
}

/// A config file Array cannot write must stop the launch with the real reason.
/// Before, the write was `try?`: claude was started with `--strict-mcp-config
/// --mcp-config <missing file>` and the user saw a failure (or an agent with no
/// Array tools) with nothing saying why.
private func runMCPConfigMaterializeFailureCheck() {
    #if os(macOS)
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("array-mcp-materialize-\(UUID().uuidString)", isDirectory: true)
    let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    do {
        try AgentSteeringQAFakes.install(.claude, in: fakeBin)
    } catch {
        expect(false, "mcp materialize: could not install the fake claude: \(error)")
        return
    }
    // A regular file where the config directory should be: nothing can be
    // created beneath it.
    let blocker = root.appendingPathComponent("not-a-directory")
    fm.createFile(atPath: blocker.path, contents: Data("x".utf8))
    let config = WorkspaceMCPConfiguration(
        serverExecutable: "/tmp/array-workspace-mcp",
        endpoint: "http://127.0.0.1:43123/workspace-mcp",
        agentID: "00000000-0000-4000-8000-0000000000aa",
        token: "secret",
        directory: blocker.appendingPathComponent("mcp", isDirectory: true))
    expect(!fm.fileExists(atPath: config.claudeMCPConfigPath), "mcp materialize: fixture must leave the config unwritable")

    let previousPath = ProcessInfo.processInfo.environment["PATH"]
    setenv("PATH", "\(fakeBin.path):\(previousPath ?? "/usr/bin:/bin")", 1)
    defer {
        if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") }
    }
    let runner = ClaudeAgentRunner(config: .init(
        model: "fake-model", cwd: root, sessionId: "00000000-0000-4000-8000-0000000000ab",
        conversationMayExist: false, workspaceMCP: config))
    var thrown: Error?
    do {
        try runner.run(prompt: AgentPrompt("hello")) { _ in }
    } catch {
        thrown = error
    }
    runner.stop()
    // What the supervisor shows: the error text after local-path redaction.
    let message = thrown.map { SecretRedactor.redactLocalDiagnostics(String(describing: $0)) } ?? ""
    expect(AgentSteeringQAFakes.spawnCount(in: fakeBin) == 0,
           "mcp materialize: claude was launched against a config file Array failed to write")
    expect(message.contains("workspace tools config") && message.contains(String(cString: strerror(ENOTDIR))),
           "mcp materialize: the launch must fail with the real write error, got \(message.isEmpty ? "no error" : message)")
    #endif
}

// MARK: - S1: a reply's picture reaches the model as an image (`.plans/80`)

/// A distinctive payload, so a leak into any text is unmistakable.
private let s1PictureBase64 = Data("ARRAY-S1-PICTURE-BYTES".utf8).base64EncodedString()

private func runToolResultImageChecks() {
    // The MCP side: the pure rule the helper applies to every tools/call.
    let reply: WorkspaceMCPJSON = .object([
        "schema": .string(WorkspaceAPISchema.v1), "status": .string("ok"),
        "result": .object(["url": .string("http://localhost:3000"),
                           "image": .object(["mimeType": .string("image/png"), "data": .string(s1PictureBase64)])])
    ])
    let made = WorkspaceMCPToolResult.make(reply: reply)
    guard case .array(let content)? = made["content"] else { expect(false, "S1: tool result has no content array"); return }
    expect(content.count == 2, "S1: a reply with a picture must yield a text item and an image item; got \(content.count)")
    expect(content.last == .object(["type": .string("image"), "data": .string(s1PictureBase64), "mimeType": .string("image/png")]),
           "S1: the picture must leave as an MCP image item, unchanged: \(String(describing: content.last))")
    let text = content.first.flatMap { item -> String? in
        if case .object(let fields) = item, case .string(let text)? = fields["text"] { return text }
        return nil
    } ?? ""
    expect(!text.contains(s1PictureBase64) && text.contains("\"attached\":true") && text.contains("localhost:3000"),
           "S1: the text item must keep the reply and drop the base64: \(text)")
    expect(!(made["structuredContent"]?.jsonString ?? "").contains(s1PictureBase64),
           "S1: structuredContent must not carry the base64")
    expect(made["isError"] == nil, "S1: an ok reply is not a tool error")

    // A malformed or unsupported picture is dropped, never forwarded as text.
    let bad = WorkspaceMCPToolResult.make(reply: .object([
        "status": .string("ok"),
        "result": .object(["image": .object(["mimeType": .string("image/gif"), "data": .string(s1PictureBase64)])])
    ]))
    if case .array(let badContent)? = bad["content"] {
        expect(badContent.count == 1 && !(bad["structuredContent"]?.jsonString ?? "").contains(s1PictureBase64),
               "S1: an unsupported picture type must be dropped, not attached or leaked")
    }
    // A reply with no picture is unchanged in shape: one text item.
    let plain = WorkspaceMCPToolResult.make(reply: .object(["status": .string("error"), "error": .object([:])]))
    if case .array(let plainContent)? = plain["content"] {
        expect(plainContent.count == 1 && plain["isError"] == .bool(true),
               "S1: a reply without a picture keeps one text item and its error flag")
    }

    runPiExtensionImageCheck()
}

/// The pi side, driven for real: node loads the bundled
/// `continuum-workspace-tools.ts` (node strips the types itself), registers its
/// tools against a stand-in `pi`, and calls one whose host reply carries a
/// picture. Skips when node is absent, like `--pi-extension-load-check` does
/// for pi.
private func runPiExtensionImageCheck() {
    guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        print("S1 pi extension image check skipped: node is not installed")
        return
    }
    guard let extensionURL = PiExtensionInstaller.bundledExtensionURL(
        fileName: PiExtensionInstaller.workspaceToolsExtensionFileName) else {
        expect(false, "S1: the bundled workspace tools extension is missing"); return
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("array-s1-pi-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let harness = dir.appendingPathComponent("harness.mjs")
    try? """
    import { pathToFileURL } from "node:url";
    const ext = (await import(pathToFileURL(process.argv[2]).href)).default;
    const tools = [];
    const noop = () => {};
    ext({ registerTool: (t) => tools.push(t), on: noop, registerCommand: noop, registerShortcut: noop, registerFlag: noop });
    const reply = JSON.parse(process.argv[3]);
    const ctx = { hasUI: true, ui: { input: async (raw) => JSON.stringify({ ...reply, requestId: JSON.parse(raw).requestId }) } };
    console.log(JSON.stringify(await tools[0].execute("s1-call", {}, undefined, undefined, ctx)));
    """.write(to: harness, atomically: true, encoding: .utf8)
    let hostReply = #"{"schema":"array.workspace.v1","status":"ok","result":{"url":"http://localhost:3000","image":{"mimeType":"image/png","data":"\#(s1PictureBase64)"}}}"#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [harness.path, extensionURL.path, hostReply]
    // The extension answers only inside an Array-managed session.
    process.environment = ["PATH": "/usr/bin:/bin", "CONTINUUM_ARRAY_MANAGED_AGENT": "1",
                           "NODE_NO_WARNINGS": "1"]
    let output = Pipe(); let errors = Pipe()
    process.standardOutput = output; process.standardError = errors
    do { try process.run() } catch { expect(false, "S1: could not run node: \(error)"); return }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = result["content"] as? [[String: Any]] else {
        expect(false, "S1: the pi extension harness failed (\(process.terminationStatus)): \(String(decoding: data, as: UTF8.self)) \(errorText)")
        return
    }
    let image = content.first { $0["type"] as? String == "image" }
    expect(content.count == 2 && image?["data"] as? String == s1PictureBase64 && image?["mimeType"] as? String == "image/png",
           "S1: pi's tool result must carry the picture as an image item: \(content)")
    let text = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    let details = String(decoding: (try? JSONSerialization.data(withJSONObject: result["details"] ?? [:])) ?? Data(), as: UTF8.self)
    expect(!text.contains(s1PictureBase64) && !details.contains(s1PictureBase64) && text.contains("localhost:3000"),
           "S1: pi's text and details must keep the reply and drop the base64: text=\(text) details=\(details)")
}
