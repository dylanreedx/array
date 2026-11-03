import ContinuumRevivedCore
import Foundation

/// Duckherd stays off inside a Managed Claude agent and untouched in a Free
/// one (`ClaudeDuckherd`). Driven through the production argv builder and the
/// real `ClaudeAgentRunner` against `scripts/fixtures/claude-duckherd-cli.py`.
/// RED before the fix: the Managed `--settings` carried hooks only, and a
/// resumed session Duckherd had saved as on got no `/duckherd off`.
func runManagedDuckherdChecks() {
    #if os(macOS)
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("managed-duckherd-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func settings(_ args: [String]) -> [String: Any]? {
        let indices = args.indices.filter { args[$0] == "--settings" }
        guard indices.count == 1, indices[0] + 1 < args.count else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(args[indices[0] + 1].utf8))) as? [String: Any]
    }
    func startsOff(_ value: Any?) -> Bool {
        ((value as? [String: Any])?["options"] as? [String: Any])?["startOn"] as? Bool == false
    }

    // 1. The production argv builder: Managed carries the switch, Free doesn't.
    let mcp = WorkspaceMCPConfiguration(
        serverExecutable: "/Applications/Array Dev.app/Contents/MacOS/array-workspace-mcp",
        endpoint: "http://127.0.0.1:4321/workspace-mcp",
        agentID: "00000000-0000-4000-8000-0000000000AB", token: "duck-secret", directory: root)
    let sid = "00000000-0000-4000-8000-000000000002"
    func argv(_ mode: AgentMode, mcp: WorkspaceMCPConfiguration?, hooks: Bool = true, keys: [String] = []) -> [String] {
        ClaudeAgentRunner.processArguments(model: "claude-haiku-5-5", effort: nil, sessionMode: .start, sessionId: sid,
            extraArgs: [], workspaceMCP: mcp, mode: mode, hookSurfaceAvailable: hooks, duckherdPluginKeys: keys)
    }
    let managed = argv(.managed, mcp: mcp, keys: ["duckherd@ducks-market"])
    if let value = settings(managed) {
        let configs = value["pluginConfigs"] as? [String: Any] ?? [:]
        expect(Set(configs.keys) == ["duckherd", "duckherd@ducks-market"] && configs.values.allSatisfy(startsOff),
               "managed duckherd: --settings must start Duckherd off under the bare and the installed key: \(configs)")
        expect(value["hooks"] as? [String: Any] != nil
               && WorkspaceAgentHook.claudeSettingsJSON(command: mcp.claudeHookCommand) == mcp.claudeHookSettingsJSON,
               "managed duckherd: the Managed settings lost Array's hooks")
    } else {
        expect(false, "managed duckherd: a Managed lead needs exactly one parseable --settings: \(managed)")
    }
    let free = argv(.free, mcp: mcp, keys: ["duckherd@ducks-market"])
    expect(free.contains(mcp.claudeHookSettingsJSON) && settings(free)?["pluginConfigs"] == nil
           && !free.contains { $0.contains("startOn") },
           "managed duckherd: a Free agent's settings must be exactly the hook settings, with no Duckherd switch: \(free)")
    expect(argv(.free, mcp: nil).contains("--settings") == false,
           "managed duckherd: a Free agent without workspace tools gets no settings at all")
    for (label, args) in [("no workspace tools", argv(.managed, mcp: nil)), ("no hook surface", argv(.managed, mcp: mcp, hooks: false))] {
        let value = settings(args)
        expect(value.map { Set($0.keys) == ["pluginConfigs"] && startsOff(($0["pluginConfigs"] as? [String: Any])?["duckherd"]) } == true,
               "managed duckherd: a Managed lead with \(label) still needs the off switch alone: \(args)")
    }
    if let mcpIndex = managed.firstIndex(of: "--mcp-config") {
        expect(mcpIndex == managed.count - 2, "managed duckherd: the MCP config path must still end the argv")
    }

    // 2. Read-only discovery of the user's own keys and saved choice.
    let config = root.appendingPathComponent("claude-config", isDirectory: true)
    let store = config.appendingPathComponent("plugins/store", isDirectory: true)
    try! fm.createDirectory(at: store, withIntermediateDirectories: true)
    func write(_ object: Any, _ path: String) {
        try! JSONSerialization.data(withJSONObject: object).write(to: config.appendingPathComponent(path))
    }
    write(["version": 2, "plugins": ["duckherd@ducks-market": [[:]], "superpowers@claude-plugins-official": [[:]]]],
          "plugins/installed_plugins.json")
    write(["enabledPlugins": ["duckherd@other-market": true, "typesafe@typesafe-ai": true]], "settings.json")
    expect(ClaudeDuckherd.installedPluginKeys(configDirectory: config) == ["duckherd@ducks-market", "duckherd@other-market"],
           "managed duckherd: installed and enabled duckherd@ keys must be found, and nothing else: \(ClaudeDuckherd.installedPluginKeys(configDirectory: config))")
    let onSession = UUID().uuidString.lowercased(), offSession = UUID().uuidString.lowercased()
    write(["leadOn:" + onSession: ["on": true, "at": 1], "leadOn:" + offSession: ["on": false, "at": 1], "welcomed": true],
          "plugins/store/duckherd_ducks-market-0123abcd.json")
    expect(ClaudeDuckherd.sessionSwitchedOn(sessionId: onSession, configDirectory: config)
           && !ClaudeDuckherd.sessionSwitchedOn(sessionId: offSession, configDirectory: config)
           && !ClaudeDuckherd.sessionSwitchedOn(sessionId: UUID().uuidString, configDirectory: config),
           "managed duckherd: only a session saved as on reads as on")
    expect(ClaudeDuckherd.isSwitchOnCommand(" /Duckherd  ON\n") && !ClaudeDuckherd.isSwitchOnCommand("/duckherd off")
           && !ClaudeDuckherd.isSwitchOnCommand("/duckherd on the plan") && !ClaudeDuckherd.isSwitchOnCommand("turn /duckherd on"),
           "managed duckherd: only the bare /duckherd on command is refused")

    // 3. The real runner against the fixture CLI.
    let fixture = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/fixtures/claude-duckherd-cli.py")
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try! fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try! fm.copyItem(at: fixture, to: bin.appendingPathComponent("claude"))
    let log = root.appendingPathComponent("fixture.jsonl")
    let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    setenv("PATH", bin.path + ":" + previousPath, 1)
    setenv("ARRAY_DUCKHERD_FIXTURE_LOG", log.path, 1)
    defer { setenv("PATH", previousPath, 1); unsetenv("ARRAY_DUCKHERD_FIXTURE_LOG") }
    // Never the real CLI: these runs resume made-up sessions.
    let resolved = ClaudeAgentRunner.liveResolvedCommand()
    guard resolved.executable == bin.appendingPathComponent("claude").path, resolved.prefixArgs.isEmpty else {
        expect(false, "managed duckherd: the fixture must be the claude the runner resolves, got \(resolved.executable)")
        return
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ event: AgentRuntimeEvent) { lock.lock(); items.append(String(describing: event)); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
    struct Run { var stdin: [String]; var argv: [String]; var events: [String]; var error: Error? }
    func run(_ mode: AgentMode, session: String, prompts: [String]) -> Run {
        try? fm.removeItem(at: log)
        let runner = ClaudeAgentRunner(config: .init(model: "fixture", mode: mode, cwd: root, sessionId: session,
                                                     conversationMayExist: true, configDirectory: config.path))
        defer { runner.stop() }
        let events = Events()
        var failure: Error?
        for prompt in prompts {
            do { try runner.run(prompt: prompt) { events.add($0) } } catch { failure = error }
        }
        let entries = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        return Run(stdin: entries.compactMap { $0["stdin"] as? String },
                   argv: entries.compactMap { $0["argv"] as? [String] }.first ?? [],
                   events: events.all, error: failure)
    }

    let resumedOn = run(.managed, session: onSession, prompts: ["hello", "again"])
    expect(resumedOn.error == nil, "managed duckherd: the resumed Managed run failed: \(String(describing: resumedOn.error))")
    expect(resumedOn.stdin == ["/duckherd off", "hello", "again"],
           "managed duckherd: a Managed resume Duckherd saved as on must send /duckherd off once, before the first prompt: \(resumedOn.stdin)")
    expect(resumedOn.events.contains { $0.contains("echo: hello") } && resumedOn.events.contains { $0.contains("echo: again") }
           && !resumedOn.events.contains { $0.contains("Duckherd off") },
           "managed duckherd: the prompts' answers must be published and the switch-off turn must not: \(resumedOn.events)")
    let configs = settings(resumedOn.argv)?["pluginConfigs"] as? [String: Any] ?? [:]
    expect(Set(configs.keys) == ["duckherd", "duckherd@ducks-market", "duckherd@other-market"] && configs.values.allSatisfy(startsOff),
           "managed duckherd: the real Managed launch must start Duckherd off under every key it found: \(resumedOn.argv)")

    let resumedOff = run(.managed, session: offSession, prompts: ["hello"])
    expect(resumedOff.stdin == ["hello"], "managed duckherd: a session not saved as on gets no extra command: \(resumedOff.stdin)")

    let freeOn = run(.free, session: onSession, prompts: ["hello"])
    expect(freeOn.stdin == ["hello"] && settings(freeOn.argv) == nil && !freeOn.argv.contains { $0.contains("duckherd") },
           "managed duckherd: a Free agent's Duckherd is the user's: no command, no settings: \(freeOn.stdin) \(freeOn.argv)")

    let refused = run(.managed, session: offSession, prompts: ["/duckherd on"])
    if case ClaudeAgentRunner.RunError.declined(let reason)? = refused.error {
        expect(reason.contains("Free"), "managed duckherd: the refusal must say how to get Duckherd: \(reason)")
    } else {
        expect(false, "managed duckherd: a Managed agent must decline /duckherd on: \(String(describing: refused.error))")
    }
    expect(refused.stdin.isEmpty, "managed duckherd: a declined /duckherd on must never reach claude: \(refused.stdin)")
    let freeCommand = run(.free, session: offSession, prompts: ["/duckherd on"])
    expect(freeCommand.error == nil && freeCommand.stdin == ["/duckherd on"],
           "managed duckherd: a Free agent forwards /duckherd on as before: \(freeCommand.stdin)")
    #endif
    print("Managed Duckherd checks passed: the Managed --settings starts Duckherd off under the bare and installed keys, Free settings untouched, a resumed session saved as on gets one unpublished /duckherd off, and /duckherd on is declined only in Managed agents")
}
