import ContinuumRevivedCore
import Foundation

/// Opt-in, spends a little real claude usage (Haiku by default). The real
/// installed claude runs through the production `ClaudeAgentRunner`, so the
/// argv is production's. `scripts/fixtures/array-workspace-live-stub.py`
/// stands in for `array-workspace-mcp` as both the MCP server and the hook
/// command, replying with production's brief and push-back text.
///
/// Case 1, Managed lead with Duckherd loaded (`--plugin-dir`): no duck agent
/// types, no Duckherd tools, no `ui_*` events, no sound or banner, `/duckherd`
/// says it is off, and the lead delegates with `array_delegate`. RED at
/// 991681b9: the same lead used `duckherd:Pip` and made no `array_delegate`
/// call (`~/array-scratch/duckherd-coexistence/captures/c-managed-duck`).
///
/// Case 2, the report push-back: a native helper's long findings report comes
/// back at most `pushBackWordLimit` words, and the path it gives holds the
/// details. RED with the old reason: 1,517 → 304 words, "the full text is in
/// my previous message", no file (`managed-fix/captures/p1-findings`).
///
/// Needs CONTINUUM_DUCKHERD_PLUGIN_DIR (a Duckherd checkout). Removes what
/// claude writes for its own throwaway sessions: `~/.claude/projects/<cwd>`
/// and `~/.claude/session-env/<session>`. Never touches anything else.
func runManagedDuckherdLiveChecks() {
    #if os(macOS)
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment
    guard let plugin = env["CONTINUUM_DUCKHERD_PLUGIN_DIR"],
          fm.fileExists(atPath: plugin + "/.claude-plugin") else {
        expect(false, "managed duckherd live: set CONTINUUM_DUCKHERD_PLUGIN_DIR to a Duckherd checkout")
        return
    }
    let model = env["CONTINUUM_LIVE_CLAUDE_MODEL"] ?? "haiku"
    let installed = ClaudeAgentRunner.liveResolvedCommand()
    guard installed.prefixArgs.isEmpty else {
        expect(false, "managed duckherd live: no installed claude")
        return
    }
    // realpath, not resolvingSymlinksInPath: that strips /private, and claude
    // names a session folder after the real /private/var path.
    let made = fm.temporaryDirectory.appendingPathComponent("managed-duckherd-live-\(UUID().uuidString)")
    try! fm.createDirectory(at: made, withIntermediateDirectories: true)
    guard let real = realpath(made.path, nil) else { expect(false, "managed duckherd live: no temp dir"); return }
    let root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    free(real)
    let claudeHome = ClaudeDuckherd.configDirectory(env["CLAUDE_CONFIG_DIR"])
    let storeDir = claudeHome.appendingPathComponent("plugins/store")
    func storeSnapshot() -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: storeDir.path)) ?? [] where name.hasPrefix("duckherd_") {
            snapshot[name] = try? Data(contentsOf: storeDir.appendingPathComponent(name))
        }
        return snapshot
    }
    let storeBefore = storeSnapshot()
    var sessions: [String] = []
    var cwds: [URL] = []
    // Only what claude wrote for these sessions, by exact name. The final
    // pass verifies it, so a missed removal turns the leg red.
    func cleanUp(verify: Bool) {
        var left: [String] = []
        for cwd in cwds {
            let encoded = cwd.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            let folder = claudeHome.appendingPathComponent("projects/" + encoded)
            try? fm.removeItem(at: folder)
            if fm.fileExists(atPath: folder.path) { left.append(folder.path) }
        }
        for session in sessions {
            let folder = claudeHome.appendingPathComponent("session-env/" + session)
            try? fm.removeItem(at: folder)
            if fm.fileExists(atPath: folder.path) { left.append(folder.path) }
        }
        let projects = (try? fm.contentsOfDirectory(atPath: claudeHome.appendingPathComponent("projects").path)) ?? []
        let rootName = root.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        left += projects.filter { $0.hasPrefix(rootName) }
        try? fm.removeItem(at: root)
        if verify { expect(left.isEmpty, "managed duckherd live: claude session files were left behind: \(left)") }
    }
    defer { cleanUp(verify: false) }

    // The shim passes claude's stdout through unchanged and keeps a copy.
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    try! fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try! fm.createDirectory(at: logs, withIntermediateDirectories: true)
    let shim = """
    #!/usr/bin/python3 -I
    import json, os, subprocess, sys
    logs = \(String(reflecting: logs.path))
    name = os.path.basename(os.getcwd())
    with open(os.path.join(logs, name + '.argv.jsonl'), 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
    child = subprocess.Popen([\(String(reflecting: installed.executable))] + sys.argv[1:], stdout=subprocess.PIPE)
    with open(os.path.join(logs, name + '.stream.jsonl'), 'ab') as copy:
        for line in child.stdout:
            sys.stdout.buffer.write(line); sys.stdout.buffer.flush(); copy.write(line); copy.flush()
    sys.exit(child.wait())
    """
    func executable(_ name: String, _ text: String) {
        let url = bin.appendingPathComponent(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    executable("claude", shim)
    // Duckherd plays quack.wav and posts banners through these; none may run.
    for tool in ["afplay", "osascript"] {
        executable(tool, "#!/bin/sh\necho \"\(tool) $*\" >> '\(logs.path)/sounds.log'\n")
    }
    let stubDir = root.appendingPathComponent("stub", isDirectory: true)
    try! fm.createDirectory(at: stubDir, withIntermediateDirectories: true)
    let stub = stubDir.appendingPathComponent("array-workspace-mcp")
    try! fm.copyItem(at: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/fixtures/array-workspace-live-stub.py"), to: stub)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let previousPath = env["PATH"] ?? ""
    setenv("PATH", bin.path + ":" + previousPath, 1)
    defer { setenv("PATH", previousPath, 1) }
    guard ClaudeAgentRunner.liveResolvedCommand().executable == bin.appendingPathComponent("claude").path else {
        expect(false, "managed duckherd live: the shim must be the claude the runner resolves")
        return
    }

    func jsonLines(_ url: URL) -> [[String: Any]] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    struct Case { var stream: [[String: Any]]; var argv: [String]; var hooks: [[String: Any]]; var mcp: [[String: Any]]; var answers: [String] }
    final class Text: @unchecked Sendable {
        private let lock = NSLock(); private var parts: [String] = []
        func add(_ event: AgentRuntimeEvent) {
            if case let .contentDelta(_, _, .assistant, delta) = event { lock.lock(); parts.append(delta); lock.unlock() }
        }
        func take() -> String { lock.lock(); defer { parts = []; lock.unlock() }; return parts.joined() }
    }
    func run(_ name: String, mode: AgentMode, extraArgs: [String], pushBack: Bool, prompts: [String],
             until done: (([[String: Any]]) -> Bool)? = nil) -> Case {
        let project = root.appendingPathComponent(name, isDirectory: true)
        try! fm.createDirectory(at: project, withIntermediateDirectories: true)
        try! "one\ntwo\nthree\n".write(to: project.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try! """
        Release review notes for a small CLI tool:
        1. The config loader silently ignores unknown keys.
        2. Retries on network errors have no backoff.
        3. The log file grows without rotation.
        4. Exit codes are 0 even when a sub-command fails.
        5. The --verbose flag prints secrets from the environment.
        6. Temporary files are created in the current directory.
        7. Signal handling leaves child processes running.
        8. The progress bar breaks when stdout is not a TTY.
        9. Time stamps are local time without a zone.
        10. Large inputs are read fully into memory.
        11. The update check runs on every start and blocks for 2 s.
        12. Help text lists two flags that no longer exist.

        """.write(to: project.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        cwds.append(project)
        for file in ["hooks.jsonl", "mcp.jsonl"] { try? fm.removeItem(at: stubDir.appendingPathComponent(file)) }
        let replies: [String: Any] = [
            "mode": mode == .managed ? "managed" : "free", "brief": ManagedLeadHookState.brief, "pushBack": pushBack,
            "limit": AgentShortReportConfig.pushBackWordLimit,
            "pushBackTemplate": WorkspaceAgentHook.pushBackReason(words: 987654321, offersReportTool: false),
        ]
        try! JSONSerialization.data(withJSONObject: replies).write(to: stubDir.appendingPathComponent("replies.json"))
        let session = UUID().uuidString.lowercased()
        sessions.append(session)
        let mcp = WorkspaceMCPConfiguration(serverExecutable: stub.path, endpoint: "http://127.0.0.1:9/workspace-mcp",
            agentID: UUID().uuidString, token: "live-stub-token", directory: root.appendingPathComponent(name + "-mcp", isDirectory: true))
        try? fm.createDirectory(atPath: root.appendingPathComponent(name + "-mcp").path, withIntermediateDirectories: true)
        let runner = ClaudeAgentRunner(config: .init(model: model, mode: mode, cwd: project, sessionId: session,
            extraArgs: extraArgs, conversationMayExist: false, workspaceMCP: mcp))
        defer { runner.stop() }
        let text = Text()
        var answers: [String] = []
        for prompt in prompts {
            do { try runner.run(prompt: prompt) { text.add($0) } } catch { expect(false, "managed duckherd live \(name): turn failed: \(error)") }
            answers.append(text.take())
        }
        // A helper Claude runs in the background reports in a turn of its own.
        let deadline = Date().addingTimeInterval(240)
        while let done, !done(jsonLines(stubDir.appendingPathComponent("hooks.jsonl"))), Date() < deadline {
            if runner.hasUnsolicitedTurn { try? runner.continueUnsolicitedTurn { text.add($0) } }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if runner.hasUnsolicitedTurn { try? runner.continueUnsolicitedTurn { text.add($0) } }
        answers.append(text.take())
        let argv = ((try? String(contentsOf: logs.appendingPathComponent(name + ".argv.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String] }
            .last { $0.contains(session) } ?? []
        return Case(stream: jsonLines(logs.appendingPathComponent(name + ".stream.jsonl")), argv: argv,
                    hooks: jsonLines(stubDir.appendingPathComponent("hooks.jsonl")),
                    mcp: jsonLines(stubDir.appendingPathComponent("mcp.jsonl")), answers: answers)
    }

    // Case 1: a Managed lead with Duckherd loaded.
    let lead = run("managed-lead", mode: .managed, extraArgs: ["--plugin-dir", plugin], pushBack: false,
                   prompts: ["Use one helper to count the lines in hello.txt, then reply with just the number.", "/duckherd"])
    let inits = lead.stream.filter { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }
    expect(!inits.isEmpty, "managed duckherd live: no init event was captured")
    for event in inits {
        let agents = (event["agents"] as? [Any] ?? []).map { String(describing: $0) }
        let tools = event["tools"] as? [String] ?? []
        expect(!agents.contains { $0.hasPrefix("duckherd:") }, "managed duckherd live: duck agent types offered: \(agents)")
        expect(!tools.contains { $0.hasPrefix("mcp__duckherd__") }, "managed duckherd live: Duckherd tools offered: \(tools)")
        let plugins = (event["plugins"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        expect(plugins.contains("duckherd"), "managed duckherd live: Duckherd was not loaded, so this proves nothing: \(plugins)")
    }
    let ui = lead.stream.filter { ($0["subtype"] as? String)?.hasPrefix("ui_") == true }
    expect(ui.isEmpty, "managed duckherd live: Duckherd drew \(ui.count) ui_* events")
    expect(lead.mcp.contains { $0["tool"] as? String == "array_delegate" },
           "managed duckherd live: the Managed lead must delegate with array_delegate: \(lead.mcp)")
    expect(!lead.stream.contains { line in
        ((line["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).contains {
            $0["type"] as? String == "tool_use" && (($0["input"] as? [String: Any])?["subagent_type"] as? String ?? "").hasPrefix("duckherd")
            || ($0["name"] as? String ?? "").hasPrefix("mcp__duckherd__")
        }
    }, "managed duckherd live: the lead used a Duckherd helper or tool")
    // claude answers a plugin's command with a synthetic result and no deltas.
    let results = lead.stream.filter { $0["type"] as? String == "result" }.compactMap { $0["result"] as? String }
    expect(results.contains { $0.localizedCaseInsensitiveContains("Duckherd is off for this session") },
           "managed duckherd live: /duckherd must answer that it is off: \(results)")
    let leadSettings = lead.argv.firstIndex(of: "--settings").flatMap { i in
        (try? JSONSerialization.jsonObject(with: Data(lead.argv[i + 1].utf8))) as? [String: Any] }
    expect(((leadSettings?["pluginConfigs"] as? [String: Any])?["duckherd"] as? [String: Any]) != nil,
           "managed duckherd live: the production argv lacks the off switch: \(lead.argv)")
    expect(storeSnapshot() == storeBefore, "managed duckherd live: an off Duckherd still wrote its store")

    // Case 2: the push-back on a long findings report (Free, no plugin).
    let brief = "Use one helper (the Agent tool, general-purpose) and give it exactly this brief: "
        + "'Read notes.txt. For each of its 12 items, write a full paragraph: what it means, why it matters, and how to fix it. "
        + "Your final message is your report.' When it reports, reply with just: done."
    let report = run("pushback", mode: .free, extraArgs: [], pushBack: true, prompts: [brief]) { hooks in
        hooks.contains { $0["event"] as? String == "SubagentStop" && $0["stop_hook_active"] as? Bool == true }
    }
    let stops = report.hooks.filter { $0["event"] as? String == "SubagentStop" }
    let limit = AgentShortReportConfig.pushBackWordLimit
    if stops.count == 2, let long = stops.first?["words"] as? Int, let short = stops.last?["words"] as? Int,
       let message = stops.last?["message"] as? String {
        expect(long > limit && stops.first?["reply"] is [String: Any], "managed duckherd live: the first hand-back must be long and pushed back: \(long)")
        expect(short <= limit && short < long, "managed duckherd live: the push-back must shorten the report: \(long) → \(short)")
        let paths = message.split(whereSeparator: { " `'\"()\n".contains($0) }).map(String.init)
            .filter { $0.hasPrefix("/") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;*")) }
        let saved = paths.first { path in
            !path.hasPrefix(root.path) && (try? String(contentsOfFile: path, encoding: .utf8)).map { AgentReport.wordCount($0) > short } == true
        }
        expect(saved != nil, "managed duckherd live: the short report must give the path of a file holding the details: \(message)")
        print("managed duckherd live: push-back \(long) → \(short) words, details in \(saved ?? "nothing")")
        // The helper's own details file is this run's artifact.
        if let saved, saved.hasPrefix("/tmp/") || saved.hasPrefix("/private/tmp/") || saved.hasPrefix(fm.temporaryDirectory.path) {
            try? fm.removeItem(atPath: saved)
        }
    } else {
        expect(false, "managed duckherd live: expected one push-back and one continuation: \(stops.map { $0["words"] ?? 0 })")
    }
    let sounds = (try? String(contentsOf: logs.appendingPathComponent("sounds.log"), encoding: .utf8)) ?? ""
    expect(sounds.isEmpty, "managed duckherd live: a sound or banner ran: \(sounds)")
    cleanUp(verify: true)
    #endif
    print("Managed Duckherd live checks passed: a Managed lead with Duckherd loaded offered no duck agents, tools or ui events, played nothing, delegated with array_delegate and heard /duckherd answer off; a native helper's long report came back short with its details in a file")
}
