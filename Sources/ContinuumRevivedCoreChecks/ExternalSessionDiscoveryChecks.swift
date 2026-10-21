import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Plan: .plans/79-session-handoff/README.md ("Facts proven").
//
// `--external-session-discovery-check`: which Claude and Codex sessions run on
// this Mac, where, and who owns each — driven through the production
// `ExternalSessionDiscovery.discover` over a synthetic home folder and a
// synthetic process table. Nothing here reads anyone's real sessions.
func runExternalSessionDiscoveryChecks() {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("array-external-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let sessions = home.appendingPathComponent(".claude/sessions", isDirectory: true)
    try? fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_792_500_000)   // 2026-10-20 UTC
    let t1 = now.addingTimeInterval(-3_600)
    let lstart: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
    func procStart(_ date: Date) -> String { lstart.string(from: date) }

    let host: Int32 = 100
    let agentTag = "AAAAAAAA-0000-4000-8000-0000000000A1"
    let faceTag = "AAAAAAAA-0000-4000-8000-0000000000A2"
    let shellTile = UUID(uuidString: "BBBBBBBB-0000-4000-8000-0000000000B1")!
    // A shell tile whose window lives in its project's shared base session.
    let sharedShellTile = UUID(uuidString: "BBBBBBBB-0000-4000-8000-0000000000B2")!
    let projectSession = TmuxSession.projectSessionName(projectId: UUID(uuidString: "CCCCCCCC-0000-4000-8000-0000000000C1")!)
    let project = root.appendingPathComponent("proj", isDirectory: true)
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    for dir in [project, scratch] { try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }

    func p(_ pid: Int32, _ parent: Int32, _ path: String, at: Date = t1, args: [String]? = nil,
           tag: String? = nil, face: String? = nil) -> ProcessSample {
        ProcessSample(pid: pid, parentPid: parent, startedAt: at.addingTimeInterval(0.42), executablePath: path,
                      arguments: args ?? [path], ownerTag: tag, ownerFace: face)
    }
    let claudeCLI = "/Users/me/.local/bin/claude"
    var processes = [
        p(host, 1, "/Applications/Array.app/Contents/MacOS/Array"),
        p(900, 1, "/Applications/cmux.app/Contents/MacOS/cmux"),
        p(950, 900, "/bin/zsh", args: ["-zsh"]),
        p(1001, 950, claudeCLI),                                     // cmux, busy, in the project
        p(1002, 950, claudeCLI, args: [claudeCLI, "bg-spare"]),      // kind: bg
        p(1003, 1, "/Applications/Spotify.app/Contents/MacOS/Spotify", at: t1.addingTimeInterval(-86_400)),
        p(1004, 1, "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude"),
        p(1060, 1, "/opt/homebrew/bin/tmux", args: ["tmux"]),
        p(1050, 1060, "/bin/zsh", args: ["-zsh"]),
        p(1005, 1050, claudeCLI),                                    // an Array shell tile's tmux
        p(1006, 1050, claudeCLI),                                    // someone else's tmux
        p(1007, host, claudeCLI, tag: agentTag),                     // Array's managed runner
        p(1008, 1050, claudeCLI, tag: faceTag, face: "terminal"),    // an Array tile's Terminal face
        p(1009, host, claudeCLI),                                    // an older Array's untagged runner
        p(1010, 1050, claudeCLI),                                    // a shell tile in the project's shared session
        p(1011, 1050, claudeCLI),                                    // ...in a pane no tile claims
        p(1012, host, claudeCLI, tag: agentTag),                     // Array's idle pooled runner on s-dup
    ]
    func writeSession(pid: Int32, _ fields: [String: Any]) {
        var object: [String: Any] = ["pid": Int(pid), "kind": "interactive", "entrypoint": "cli",
                                     "status": "idle", "procStart": procStart(t1),
                                     "startedAt": t1.timeIntervalSince1970 * 1000]
        for (key, value) in fields { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! data.write(to: sessions.appendingPathComponent("\(pid).json"))
    }
    let turnStart = now.addingTimeInterval(-95)
    writeSession(pid: 1001, ["sessionId": "s-cmux", "cwd": project.path, "status": "busy", "name": "proj-1a",
                             "statusUpdatedAt": turnStart.timeIntervalSince1970 * 1000])
    writeSession(pid: 1002, ["sessionId": "s-bg", "cwd": project.path, "kind": "bg"])
    writeSession(pid: 1003, ["sessionId": "s-stale", "cwd": project.path,
                             "procStart": procStart(t1.addingTimeInterval(-7 * 86_400))])
    writeSession(pid: 1004, ["sessionId": "s-desktop", "cwd": project.path, "entrypoint": "claude-desktop",
                             "name": "LinkedIn post"])
    writeSession(pid: 1005, ["sessionId": "s-shell", "cwd": project.path,
                             "tmux": "\(TmuxSession.viewSessionName(tileId: shellTile)):@3.%4"])
    writeSession(pid: 1006, ["sessionId": "s-tmux", "cwd": scratch.path, "tmux": "work:@1.%1"])
    writeSession(pid: 1010, ["sessionId": "s-shared", "cwd": project.path, "tmux": "\(projectSession):@5.%9"])
    writeSession(pid: 1011, ["sessionId": "s-unclaimed", "cwd": project.path, "tmux": "\(projectSession):@6.%11"])
    writeSession(pid: 1007, ["sessionId": "s-managed", "cwd": project.path, "entrypoint": "sdk-cli"])
    writeSession(pid: 1008, ["sessionId": "s-face", "cwd": project.path])
    writeSession(pid: 1009, ["sessionId": "s-old-runner", "cwd": project.path, "entrypoint": "sdk-cli"])
    // One session, two holders: Array's pooled runner (the LOWER pid) and a
    // `claude --resume` of the same session in Ghostty (the higher one).
    writeSession(pid: 1012, ["sessionId": "s-dup", "cwd": project.path, "entrypoint": "sdk-cli"])
    writeSession(pid: 3010, ["sessionId": "s-dup", "cwd": project.path])
    // A `.key` file beside them is never opened, even one holding a session.
    let keyed = try! JSONSerialization.data(withJSONObject: [
        "pid": 1001, "sessionId": "s-key", "cwd": project.path, "procStart": procStart(t1)])
    try! keyed.write(to: sessions.appendingPathComponent("1001.4fb3927bdb31.key"))
    // The cmux session's transcript names it.
    let transcript = ClaudeSessionTranscriptReader.sessionFileURL(homeURL: home, cwd: project.path, sessionId: "s-cmux")
    try? fileManager.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(("""
    {"type":"ai-title","aiTitle":"Upload test","sessionId":"s-cmux"}
    {"type":"user","message":{"role":"user","content":"hi"}}
    {"type":"ai-title","aiTitle":"Fix flaky upload test","sessionId":"s-cmux"}

    """).utf8).write(to: transcript)

    // Codex: dated rollout folders, the thread index, and one CLI process.
    let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
    let parts = utc.dateComponents([.year, .month, .day], from: now)
    let day = codexHome.appendingPathComponent(
        String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
    try? fileManager.createDirectory(at: day, withIntermediateDirectories: true)
    func rollout(_ name: String, id: String, originator: String, cwd: String, modified: Date,
                 parent: String? = nil) -> URL {
        var payload: [String: Any] = ["id": id, "cwd": cwd, "originator": originator,
                                      "timestamp": "2026-10-20T08:00:00.000Z"]
        if let parent { payload["parent_thread_id"] = parent }
        let line = try! JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])
        let url = day.appendingPathComponent("rollout-2026-10-20T08-00-00-\(name).jsonl")
        try! (line + Data("\n".utf8)).write(to: url)
        try! fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }
    _ = rollout("app", id: "t-app", originator: "Codex Desktop", cwd: project.path, modified: now.addingTimeInterval(-240))
    _ = rollout("array", id: "t-array", originator: "array", cwd: project.path, modified: now.addingTimeInterval(-5))
    _ = rollout("sub", id: "t-sub", originator: "Codex Desktop", cwd: project.path,
                modified: now.addingTimeInterval(-60), parent: "t-app")
    _ = rollout("old", id: "t-old", originator: "Codex Desktop", cwd: project.path, modified: now.addingTimeInterval(-7_200))
    let cliRollout = rollout("cli", id: "t-cli", originator: "codex_cli_rs", cwd: scratch.path,
                             modified: now.addingTimeInterval(-3))
    try! Data("""
    {"id":"t-app","thread_name":"Old name","updated_at":"2026-10-20T08:01:00Z"}
    {"id":"t-app","thread_name":"Polish which-tab transition","updated_at":"2026-10-20T08:02:00Z"}
    {"id":"t-cli","thread_name":"Port scanner spike","updated_at":"2026-10-20T08:03:00Z"}

    """.utf8).write(to: codexHome.appendingPathComponent("session_index.jsonl"))
    processes += [
        p(3000, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        p(3001, 3000, "/bin/zsh", args: ["-zsh"]),
        p(3002, 3001, "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/bin/codex"]),
        p(3003, 3002, "/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex", args: ["codex"]),
        p(3010, 3001, claudeCLI),                                    // Ghostty, resuming s-dup
        p(3100, 1, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
          args: ["codex", "app-server"]),
    ]

    let discovery = ExternalSessionDiscovery()
    func inputs(home: URL, processes: [ProcessSample]) -> ExternalSessionDiscovery.Inputs {
        ExternalSessionDiscovery.Inputs(
            homeURL: home, processes: processes, hostPid: host, now: now, calendar: utc,
            processCwd: { pid in pid == 3003 ? scratch.path : nil },
            openFiles: { pid in pid == 3003 ? ["/dev/ttys004", cliRollout.path] : [] },
            // `%1` is the same id as someone else's pane on another session:
            // only an Array session name lets a pane id name a tile.
            arrayShellPanes: ["%9": sharedShellTile, "%1": sharedShellTile])
    }
    let snapshot = discovery.discover(inputs(home: home, processes: processes))
    func session(_ id: String) -> ExternalAgentSession? { snapshot.sessions.first { $0.sessionId == id } }
    let ids = Set(snapshot.sessions.map(\.sessionId))

    // Claude.
    expect(!snapshot.claudeUnreadable, "readable session files must not mark Claude unreadable")
    expect(session("s-cmux")?.host == .app("cmux"),
           "a claude under cmux is labelled by its first .app ancestor; got \(String(describing: session("s-cmux")?.host))")
    expect(session("s-cmux")?.status == .busy && session("s-cmux")?.statusSince == turnStart,
           "a busy session reports busy since its status change")
    expect(session("s-cmux")?.title == "Fix flaky upload test",
           "the newest ai-title in the transcript names the session; got \(String(describing: session("s-cmux")?.title))")
    expect(session("s-cmux")?.transcriptURL == transcript, "the transcript is the CLI's own session file")
    expect(!ids.contains("s-bg"), "kind: bg is Claude's own background host and is skipped")
    expect(!ids.contains("s-stale"),
           "a file whose procStart is not the start of the process at its pid (pid reuse) is dropped")
    expect(!ids.contains("s-key"), "a .key file is never read")
    expect(session("s-desktop")?.host == .app("Claude app") && session("s-desktop")?.title == "LinkedIn post",
           "entrypoint claude-desktop is the Claude app, titled by its name; got \(String(describing: session("s-desktop")))")
    expect(session("s-shell")?.host == .arrayShellTile(tileId: shellTile),
           "claude in an Array shell tile's tmux session names that tile; got \(String(describing: session("s-shell")?.host))")
    expect(session("s-tmux")?.host == .tmux, "anyone else's tmux is just tmux")
    expect(session("s-shared")?.host == .arrayShellTile(tileId: sharedShellTile),
           "claude in a project's shared tmux session names the shell tile whose pane it runs in; got \(String(describing: session("s-shared")?.host))")
    expect(session("s-unclaimed")?.host == .arrayShellTile(tileId: nil),
           "a shared-session pane no tile claims is still an Array shell, but names no tile; got \(String(describing: session("s-unclaimed")?.host))")
    expect(TmuxSession.groupedViewPaneTarget(arguments: try! TmuxSession.groupedViewProfile(
               profile: LaunchProfile(command: "/bin/zsh", arguments: [], cwd: "/", title: "Shell"),
               tileId: sharedShellTile, baseSessionName: projectSession, windowTarget: "%9", tmuxPath: "/usr/bin/tmux",
               defaults: UserDefaults(suiteName: "array.qa.discovery.\(UUID().uuidString)")!).arguments) == "%9",
           "a shell tile's grouped-view launch names the pane it shows")
    expect(session("s-managed")?.host == .arrayManaged(agentId: agentTag),
           "a claude carrying ARRAY_AGENT_ID is Array's managed runner")
    expect(session("s-face")?.host == .arrayTerminalFace(agentId: faceTag),
           "ARRAY_AGENT_ID with ARRAY_AGENT_FACE=terminal is that tile's Terminal face")
    expect(session("s-old-runner")?.host == .arrayManaged(agentId: nil),
           "an untagged sdk-cli claude directly under Array is an older Array runner, never an elsewhere row")
    // `.plans/79` review 1: one session id, one row — but never at the price of
    // hiding a foreign holder behind Array's own process. Array's pooled runner
    // has the lower pid; the Ghostty claude must still be the one reported, or
    // the agent is never paused and two processes write the session.
    let dups = snapshot.sessions.filter { $0.sessionId == "s-dup" }
    expect(dups.count == 1 && dups.first?.pid == 3010 && dups.first?.host == .app("Ghostty"),
           "a session held by Array's runner AND a foreign claude reports the foreign holder; got \(dups.map { "\($0.pid.map(String.init) ?? "-") \($0.host)" })")
    expect(ExternalSessionHandoff.pausingHolder(provider: .claude, sessionIds: ["s-dup"], in: snapshot)?.pid == 3010,
           "the foreign holder of an Array agent's session is the one that pauses it")

    // Codex.
    expect(session("t-app")?.host == .app("Codex app") && session("t-app")?.status == .unknown
           && session("t-app")?.title == "Polish which-tab transition",
           "a recent Codex Desktop thread is listed as the Codex app, unknown status, last index name; got \(String(describing: session("t-app")))")
    expect(!ids.contains("t-array"), "Array's own Codex rollouts (originator array) are never listed")
    expect(!ids.contains("t-sub"), "a sub-agent thread (parent_thread_id) is not a session of its own")
    expect(!ids.contains("t-old"), "an app thread not written in the last 30 minutes is not listed")
    expect(session("t-cli")?.pid == 3003 && session("t-cli")?.host == .app("Ghostty")
           && session("t-cli")?.status == .busy && session("t-cli")?.cwd == scratch.path,
           "a codex CLI is found by the rollout it holds open, under its terminal app; got \(String(describing: session("t-cli")))")
    expect(snapshot.sessions.filter { $0.provider == .codex }.count == 2,
           "codex app-server and the node wrapper are not sessions; got \(snapshot.sessions.filter { $0.provider == .codex }.map(\.sessionId))")

    // `.plans/79` review 6: claude rewrites its `<pid>.json` in place, so one
    // pass can catch it half-written. A file that fails to parse for a process
    // still running keeps the record the last pass read — one bad read is not
    // the holder letting go — and drops once that process is gone.
    let cmuxFile = sessions.appendingPathComponent("1001.json")
    let cmuxWhole = try! Data(contentsOf: cmuxFile)
    try! Data(cmuxWhole.prefix(cmuxWhole.count / 2)).write(to: cmuxFile)
    let midWrite = discovery.discover(inputs(home: home, processes: processes))
    expect(midWrite.sessions.first { $0.sessionId == "s-cmux" }?.host == .app("cmux") && !midWrite.claudeUnreadable,
           "a session file caught mid-rewrite keeps its last record while its process lives; got \(midWrite.sessions.map(\.sessionId))")
    let exited = discovery.discover(inputs(home: home, processes: processes.filter { $0.pid != 1001 }))
    expect(!exited.sessions.contains { $0.sessionId == "s-cmux" },
           "a kept record goes with its process")
    try! cmuxWhole.write(to: cmuxFile)

    // A schema change: files exist and none parse. No Claude rows, not wrong ones.
    let changedHome = root.appendingPathComponent("changed", isDirectory: true)
    let changedSessions = changedHome.appendingPathComponent(".claude/sessions", isDirectory: true)
    try? fileManager.createDirectory(at: changedSessions, withIntermediateDirectories: true)
    try! Data(#"{"pid":1001,"session":"s-cmux","workingDirectory":"/x","started":"yesterday"}"#.utf8)
        .write(to: changedSessions.appendingPathComponent("1001.json"))
    let changed = ExternalSessionDiscovery().discover(inputs(home: changedHome, processes: processes))
    expect(changed.claudeUnreadable && !changed.sessions.contains { $0.provider == .claude },
           "session files that no longer parse hide Claude's sessions rather than guess; got \(changed)")

    // Rows: Array-owned sessions are never rows, and location scopes retain
    // idle sessions in this workspace's projects.
    let projectId = UUID(uuidString: "CCCCCCCC-0000-4000-8000-0000000000C1")!
    let workspaceId = UUID(uuidString: "CCCCCCCC-0000-4000-8000-0000000000C2")!
    let context = ExternalSessionRows.Context(
        projects: [.init(id: projectId, name: "proj", rootPath: project.path, workspaceId: workspaceId)],
        currentWorkspaceId: workspaceId, currentWorkspaceName: "Main",
        currentWorkspaceProjectIds: [projectId], ownedSessionIds: ["s-desktop"],
        shellTileTitles: [shellTile: "Shell 2"])
    let rows = ExternalSessionRows.rows(from: snapshot, context: context, now: now)
    func row(_ id: String) -> AgentInboxRow? {
        rows.first { $0.externalSession?.sessionKey == ExternalAgentSession.keyForChecks(.claude, id)
            || $0.externalSession?.sessionKey == ExternalAgentSession.keyForChecks(.codex, id) }
    }
    expect(row("s-managed") == nil && row("s-face") == nil && row("s-old-runner") == nil,
           "a session an Array agent owns is that agent's row, never an external one")
    expect(row("s-desktop") == nil, "a session id an Array agent's record holds is never listed twice")
    expect(Set(rows.map(\.id)).count == rows.count, "rows are keyed by session, one each")
    expect(row("s-cmux")?.whereMarker?.text == "cmux" && row("s-cmux")?.state == .working
           && row("s-cmux")?.projectId == projectId && row("s-cmux")?.externalSession?.isProminent == true
           && row("s-cmux")?.elapsed == 95,
           "a busy cmux session in this workspace's project is a prominent Working row; got \(String(describing: row("s-cmux")))")
    expect(row("s-shell")?.whereMarker?.text == "Shell 2", "claude in a shell tile is marked with the tile's title")
    expect(row("s-tmux")?.projectId == nil && row("s-tmux")?.directoryName == "scratch"
           && row("s-tmux")?.externalSession?.isProminent == false,
           "a session in a folder that is not a project is labelled by the folder and is not prominent")
    expect(row("t-app")?.whereMarker?.text == "Codex app · 4m ago" && row("t-app")?.externalSession?.canCopy == false,
           "a Codex app thread reads 'Codex app · 4m ago' and offers no Copy; got \(String(describing: row("t-app")?.whereMarker))")
    expect(row("s-cmux")?.externalSession?.canCopy == true, "a Claude session can be copied")
    let defaultScope = InboxScope.filter(rows: rows, scope: .currentWorkspace, currentWorkspaceId: workspaceId)
    let workspaceSessionIds = ["s-cmux", "s-shell", "s-shared", "s-unclaimed", "s-dup", "t-app"]
    expect(defaultScope.count == workspaceSessionIds.count
           && Set(defaultScope.map(\.id)) == Set(workspaceSessionIds.compactMap { row($0)?.id }),
           "the default scope retains busy and idle sessions in this workspace's projects, excluding other folders; got \(defaultScope.map(\.title))")
    expect(InboxScope.filter(rows: rows, scope: .all).count == rows.count,
           "All agents includes every discovered row, including idle sessions and unregistered folders")
    expect(InboxScope.filter(rows: rows, scope: .thisMac).count == rows.count,
           "This Mac lists every external session, quiet and project-less ones included")
    expect(ExternalSessionRows.rowId(forSessionKey: "claude:s-cmux") == ExternalSessionRows.rowId(forSessionKey: "claude:s-cmux")
           && ExternalSessionRows.rowId(forSessionKey: "claude:s-cmux") != ExternalSessionRows.rowId(forSessionKey: "codex:s-cmux"),
           "a row id is stable for its session and distinct per provider")
    // `.plans/79` review 5: Array types `/exit` into a shell's claude only when
    // its input box is visibly empty; anything it cannot read is not empty.
    let rule = String(repeating: "\u{2500}", count: 30)
    expect(ClaudeTerminalFace.inputBoxIsEmpty(screen: ["done: hi", rule, "\u{276F} ", rule, "  ? for shortcuts", ""]),
           "an empty prompt between two rules is an empty input box")
    expect(!ClaudeTerminalFace.inputBoxIsEmpty(screen: [rule, "\u{276F} fix the bu", rule]), "a draft is not empty")
    expect(!ClaudeTerminalFace.inputBoxIsEmpty(screen: [rule, "\u{276F} first line", "  second line", rule]),
           "a multi-line draft is not empty")
    expect(!ClaudeTerminalFace.inputBoxIsEmpty(screen: [rule, "\u{276F} ", rule, "Do you trust this folder?", "\u{276F} 1. Yes"]),
           "the bottom prompt is the one that counts: a dialog's choice is not an empty box")
    expect(!ClaudeTerminalFace.inputBoxIsEmpty(screen: ["$ ", ""]) && !ClaudeTerminalFace.inputBoxIsEmpty(screen: ["\u{276F} "]),
           "a screen with no box, or a prompt without its rules, cannot be read and is not empty")
    print("external session discovery checks passed")
}

private extension ExternalAgentSession {
    static func keyForChecks(_ provider: ExternalSessionProvider, _ id: String) -> String { "\(provider.rawValue):\(id)" }
}
