import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation
import GhosttyKit

/// `.plans/79-session-handoff`, edge case 4 — `--shell-open-as-agent-check`.
///
/// `claude` typed into an ordinary Array shell tile, moved into an agent tile
/// through the production path. A real shell terminal tile, spawned by the
/// production spawner into the boot-mounted scene (`WorkspaceAPIChecks.makeFixture`,
/// so its window lives in the project's SHARED tmux session), in an isolated
/// tmux server, runs a stand-in claude that keeps a `~/.claude/sessions`-style
/// status file and a session transcript under a fixture home — never the
/// user's. The app's own discovery monitor maps it to that tile; the band's
/// button is clicked with real mouse events. Then:
///
/// - busy: a Move here agent tile beside the shell on the same session, its
///   history once under a "From <shell>" boundary, held — no `/exit` typed,
///   sends refused, "Still open in …" up — while the turn finishes in the
///   tile, until the person types `/exit`; then the agent continues the session;
/// - a draft in claude's input box: nothing typed, the tile waits;
/// - idle with an empty box, its window split and another pane active: Array
///   types `/exit` into claude's own pane, claude exits, the shell's prompt
///   comes back and the agent is live at once;
/// - claude on a session an Array agent already owns: the band offers Show
///   agent, never a second agent;
/// - throughout, one sidebar row per session: the shell's while it holds the
///   session, then the agent's.
@MainActor
enum ShellOpenAsAgentChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    /// The stand-in for an interactive claude in a shell. It records every line
    /// typed at it the moment it arrives, with its status then — a reader
    /// thread, so a line typed mid-turn is logged as typed mid-turn. Like the
    /// real TUI it reads keys raw and draws its input box at the bottom: the
    /// draft after `❯ `, between two rules of `─`.
    static let fakeClaude = #"""
    #!/usr/bin/env python3
    import json, os, queue, subprocess, sys, termios, threading, time, tty
    HERE = os.path.dirname(os.path.abspath(__file__))
    argv = sys.argv[1:]
    sid = argv[argv.index("--session-id") + 1]
    home = open(os.path.join(HERE, "home.txt")).read().strip()
    tmux_path = open(os.path.join(HERE, "tmux.txt")).read().strip()
    transcript = open(os.path.join(HERE, "transcript-%s.txt" % sid)).read().strip()
    log = os.path.join(HERE, "stdin-%s.jsonl" % sid)
    proc_start = subprocess.run(["ps", "-o", "lstart=", "-p", str(os.getpid())], capture_output=True, text=True,
                                env=dict(os.environ, TZ="UTC", LC_ALL="C")).stdout.strip()
    # Which session claude names is not proven: the tile's own view, or (with
    # --report-group) the project's shared base, where only the pane says
    # which tile it is.
    session = "#{session_group}" if "--report-group" in argv else "#S"
    tmux = None
    if os.environ.get("TMUX_PANE"):
        tmux = subprocess.run([tmux_path, "display-message", "-p", "-t", os.environ["TMUX_PANE"],
                               session + ":#{window_id}.#{pane_id}"], capture_output=True, text=True).stdout.strip() or None
    sessions = os.path.join(home, ".claude", "sessions")
    os.makedirs(sessions, exist_ok=True)
    me = os.path.join(sessions, "%d.json" % os.getpid())
    started = int(time.time() * 1000)
    state = {"status": "idle"}
    def status(value):
        state["status"] = value
        record = {"pid": os.getpid(), "sessionId": sid, "cwd": os.getcwd(), "status": value, "kind": "interactive",
                  "entrypoint": "cli", "procStart": proc_start, "startedAt": started,
                  "updatedAt": int(time.time() * 1000)}
        if tmux:
            record["tmux"] = tmux
        with open(me + ".tmp", "w") as f:
            json.dump(record, f)
        os.replace(me + ".tmp", me)
    def append(obj):
        with open(transcript, "a") as f:
            f.write(json.dumps(obj) + "\n")
    rule = "\u2500" * 40
    out = ["FAKE CLAUDE on %s" % sid]
    draft = [""]
    drawing = threading.Lock()
    def draw():
        with drawing:
            sys.stdout.write("\x1b[H\x1b[2J" + "\r\n".join(out[-6:]) + "\r\n" + rule + "\r\n\u276f " + draft[0]
                             + "\r\n" + rule + "\r\n")
            sys.stdout.flush()
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    lines = queue.Queue()
    def read():
        while True:
            chunk = os.read(fd, 1024)
            if not chunk:
                break
            for ch in chunk.decode("utf-8", "replace"):
                if ch in "\r\n":
                    text = draft[0].strip()
                    draft[0] = ""
                    if text:
                        with open(log, "a") as f:
                            f.write(json.dumps({"text": text, "status": state["status"]}) + "\n")
                        lines.put(text)
                elif ch in "\x7f\x08":
                    draft[0] = draft[0][:-1]
                elif ch >= " ":
                    draft[0] += ch
            draw()
        lines.put(None)
    status("idle")
    draw()
    threading.Thread(target=read, daemon=True).start()
    try:
        while True:
            text = lines.get()
            if text is None or text == "/exit":
                break
            status("busy")
            append({"type": "user", "isSidechain": False, "sessionId": sid, "message": {"role": "user", "content": text}})
            time.sleep(4 if "slow" in text else 0.4)
            append({"type": "assistant", "isSidechain": False, "sessionId": sid,
                    "message": {"role": "assistant", "model": "claude-haiku-4-5-20251001",
                                "content": [{"type": "text", "text": "fake: " + text}]}})
            status("idle")
            out.append("done: %s" % text)
            draw()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    os.remove(me)
    print("FAKE CLAUDE EXITED", flush=True)
    """#

    static func run() throws -> String {
        guard case let .ready(tmuxPath, socketDir, socketPath) = TmuxIsolation.resolve() else {
            throw Failure(description: "tmux is not isolated: run with TMUX_TMPDIR set to a fresh dir under /tmp and TMUX unset")
        }
        // A check run from inside an Array agent must not read as that agent.
        unsetenv(AgentProcessAttribution.ownerEnvironmentKey)
        unsetenv(ClaudeTerminalFace.faceEnvironmentKey)
        var log = ["tmux socket \(socketPath) (namespace \(socketDir))"]

        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }
        let suiteName = "array.qa.shell-open-as-agent.\(UUID().uuidString)"
        let tmuxDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        tmuxDefaults.set(true, forKey: TmuxPersistenceConfig.enabledKey)
        tmuxDefaults.set(tmuxPath, forKey: TmuxPersistenceConfig.pathKey)
        let fixture = try WorkspaceAPIChecks.makeFixture(ghostty: ghostty) { runtime in
            runtime.spawnerDefaults = tmuxDefaults
            runtime.spawnerTmuxPathResolver = { _ in tmuxPath }
        }
        defer { fixture.tearDown() }
        let delegate = fixture.delegate
        let supervisor = delegate.qaAgentSupervisor
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        guard let claudeModel = AgentCatalogQAFixture.claude.seedModel else { throw Failure(description: "no claude fixture model") }
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .claudeCode, model: claudeModel)
        defer { unpin() }

        // The fixture home and the stand-in claude.
        let work = fixture.tempRoot.appendingPathComponent("shell-handoff", isDirectory: true)
        let home = work.appendingPathComponent("home", isDirectory: true)
        let bin = work.appendingPathComponent("bin", isDirectory: true)
        for directory in [home, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let claude = bin.appendingPathComponent("claude")
        try fakeClaude.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        try home.path.write(to: bin.appendingPathComponent("home.txt"), atomically: true, encoding: .utf8)
        try tmuxPath.write(to: bin.appendingPathComponent("tmux.txt"), atomically: true, encoding: .utf8)
        // Claude names its project folder after the shell's real cwd.
        guard let realRoot = realpath(fixture.paRoot.path, nil) else { throw Failure(description: "no real path for Pa") }
        let shellCwd = String(cString: realRoot)
        free(realRoot)
        func transcriptURL(_ sid: String) -> URL {
            ClaudeSessionTranscriptReader.sessionFileURL(homeURL: home, cwd: shellCwd, sessionId: sid)
        }
        func writeHistory(_ sid: String, _ question: String, _ answer: String) throws {
            let url = transcriptURL(sid)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = [
                ["type": "user", "isSidechain": false, "uuid": "\(sid)-u1", "sessionId": sid,
                 "message": ["role": "user", "content": question]],
                ["type": "assistant", "isSidechain": false, "uuid": "\(sid)-a1", "sessionId": sid,
                 "message": ["role": "assistant", "model": "claude-haiku-4-5-20251001",
                             "content": [["type": "text", "text": answer]]]],
            ].map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try url.path.write(to: bin.appendingPathComponent("transcript-\(sid).txt"), atomically: true, encoding: .utf8)
        }
        func typed(_ sid: String) -> [(text: String, status: String)] {
            let text = (try? String(contentsOf: bin.appendingPathComponent("stdin-\(sid).jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                guard let object = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String],
                      let text = object["text"], let status = object["status"] else { return nil }
                return (text, status)
            }
        }
        func liveStatus(_ sid: String) -> String? {
            let folder = home.appendingPathComponent(".claude/sessions", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      object["sessionId"] as? String == sid else { continue }
                return object["status"] as? String
            }
            return nil
        }

        // The canvas in a window, so clicks are real, and the sidebar as boot
        // installs it, so the monitor's rows are the production rows.
        let window = NSWindow(contentRect: fixture.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = fixture.canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let sidebarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        sidebarWindow.contentView = sidebar
        sidebarWindow.orderFrontOffscreenForChecks()
        defer { sidebarWindow.orderOut(nil) }
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        delegate.qaRefreshAgentSurfaces()
        let inbox = sidebar.inboxForQA
        inbox.setScope(.thisMac)

        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let app = try? ghostty.app { ghostty_app_tick(app) }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        @discardableResult
        func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                if let app = try? ghostty.app { ghostty_app_tick(app) }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        // 1. A real shell tile in project Pa's zone, through the production spawner.
        guard let spawner = fixture.runtime.controller(for: fixture.projectPa)?.tileSpawner else {
            throw Failure(description: "project Pa has no spawner")
        }
        guard case let .spawned(shellRuntime) = spawner.spawnTerminal(profileId: "shell"),
              let shell = fixture.canvas.tileView(for: shellRuntime.tileId) as? TerminalTileNSView else {
            throw Failure(description: "the shell tile did not spawn")
        }
        var liveSurfaces: [TerminalTileNSView] = [shell]
        defer {
            for view in liveSurfaces {
                view.runtime.terminate(policy: .force)
                view.hostView.detachRuntime()
            }
            pump(0.3)
        }
        let pane = TmuxSession.groupedViewPaneTarget(arguments: shellRuntime.launchArguments)
        try expect(pane != nil, "the shell tile must show a window of the project's shared tmux session; argv \(shellRuntime.launchArguments)")
        fixture.canvas.layoutSubtreeIfNeeded()
        try expect(pump(until: { shellRuntime.qaTerminalView?.surface != nil && !shellRuntime.visibleText().isEmpty }, timeout: 15),
                   "the shell never drew a prompt")
        pump(1.0)
        let place = shell.tile.title
        log.append("shell tile '\(place)' on pane \(pane ?? "-")")

        // The monitor, on the fixture home, every half second.
        let monitor = delegate.externalSessionMonitor
        monitor.homeOverride = (home, home.appendingPathComponent(".codex", isDirectory: true))
        monitor.qaInterval = 0.5
        delegate.shellHandoffClaudeHome = home
        monitor.start()
        defer { monitor.stop() }

        /// A line typed and entered at the shell: the text, then a real Return
        /// key. A newline sent as text is a paste, which zsh does not run.
        func enter(_ line: String) {
            shellRuntime.sendInput(Data(line.utf8))
            shellRuntime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
        }
        func startClaude(_ sid: String, reportGroup: Bool = false) {
            enter("\(claude.path) --session-id \(sid)\(reportGroup ? " --report-group" : "")")
        }
        func reportedTmux(_ sid: String) -> String? {
            let folder = home.appendingPathComponent(".claude/sessions", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      object["sessionId"] as? String == sid else { continue }
                return object["tmux"] as? String
            }
            return nil
        }
        func rowsFor(_ sid: String) -> [UUID] {
            delegate.qaRefreshAgentSurfaces()
            inbox.layoutForQA()
            let external = ExternalSessionRows.rowId(forSessionKey: "claude:\(sid)")
            return inbox.rowIdsForQA.filter { id in
                guard let record = supervisor.records[AgentID(rawValue: id)] else { return id == external }
                return record.providerSessionId == sid || record.externalSession?.sessionId == sid
            }
        }
        func entries(_ tile: ManagedAgentTileNSView) -> String {
            tile.qaDocumentForChecks.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }
                .joined(separator: "\n")
        }
        func occurrences(_ needle: String, in haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }
        func button() -> NSPoint? {
            shell.layoutSubtreeIfNeeded()
            return shell.qaBandControlFrames.first { $0.name == "sessionAction" }
                .map { AgentFaceChecks.windowPoint(of: $0.frame, in: shell) }
        }
        let directory = try AgentFaceChecks.runDirectory("shell-open-as-agent")

        // 2. Busy: claude in the shell, discovered, and mid-turn when clicked.
        let busySid = UUID().uuidString.lowercased()
        try writeHistory(busySid, "PRIOR busy question", "PRIOR busy answer")
        startClaude(busySid)
        try expect(pump(until: { liveStatus(busySid) == "idle" }, timeout: 15), "the stand-in claude never started in the shell")
        try expect(pump(until: {
            monitor.snapshot.sessions.contains { $0.sessionId == busySid && $0.host == .arrayShellTile(tileId: shell.tile.id) }
        }, timeout: 10), "discovery must map the claude to its shell tile; got \(monitor.snapshot.sessions.map { "\($0.sessionId) \($0.host)" })")
        let discovered = monitor.snapshot.sessions.first { $0.sessionId == busySid }!
        log.append("busy claude reported tmux \(reportedTmux(busySid) ?? "-")")
        try expect(discovered.transcriptURL?.standardizedFileURL == transcriptURL(busySid).standardizedFileURL,
                   "discovery must find the session's own transcript; got \(String(describing: discovered.transcriptURL))")
        try expect(pump(until: { button() != nil && shell.claudeSessionId == busySid }, timeout: 5),
                   "the shell's band must offer Open as agent tile; controls \(shell.qaBandControlFrames.map(\.name)), mode \(shell.qaSessionActionMode)")
        try expect(shell.qaSessionActionMode == "labelled",
                   "a wide shell band shows the quiet Claude Code label and the button; mode \(shell.qaSessionActionMode)")
        try expect(shell.makeAdditionalTitleBarMenuItems().contains { $0.identifier?.rawValue == "terminalTile.openAsAgentTile" },
                   "the tile menu must offer Open as Agent Tile too")
        try expect(rowsFor(busySid).count == 1, "one sidebar row for the shell's session; got \(rowsFor(busySid).count)")
        AgentFaceChecks.saveWindowPNG(window, to: directory.appendingPathComponent("shell-band-button.png"))

        enter("slow turn")
        try expect(pump(until: { liveStatus(busySid) == "busy" }, timeout: 8), "the shell's claude never went busy")
        let before = Set(supervisor.records.keys)
        guard let point = button() else { throw Failure(description: "the button left the band") }
        try AgentFaceChecks.click(point, in: window)
        let created = Set(supervisor.records.keys).subtracting(before)
        guard created.count == 1, let busyAgent = created.first, let record = supervisor.records[busyAgent] else {
            throw Failure(description: "a click on Open as agent tile must create one agent; created \(created.count)")
        }
        try expect(record.harness == .claudeCode && record.externalSession?.mode == .movingHere
                   && record.externalSession?.sessionId == busySid && record.externalSession?.hostName == place,
                   "the agent must be a Claude agent waiting to move the shell's session here; link \(String(describing: record.externalSession))")
        // What the shell's claude actually received, as it arrived.
        pump(0.6)
        let typedWhileBusy = typed(busySid).filter { $0.text == "/exit" }
        try expect(pump(until: { delegate.qaShellHandoffTypedExit != nil }, timeout: 3)
                   && typedWhileBusy.isEmpty && delegate.qaShellHandoffTypedExit == false,
                   "a busy claude must never be sent /exit; it received \(typedWhileBusy.map { "\($0.text) while \($0.status)" })")
        guard let agentTileId = supervisor.records[busyAgent]?.tileId,
              let agentTile = fixture.canvas.tileView(for: agentTileId) as? ManagedAgentTileNSView else {
            throw Failure(description: "the agent must have a tile")
        }
        let worldTiles = fixture.canvas.allTilesInWorldFrames()
        guard let shellFrame = worldTiles.first(where: { $0.id == shell.tile.id })?.frame,
              let agentFrame = worldTiles.first(where: { $0.id == agentTileId })?.frame else {
            throw Failure(description: "both tiles must be on the canvas")
        }
        // Asked for at the shell's right, tops aligned; an auto-layout zone then
        // docks it against the shell where the zone has room. Either way it
        // touches the shell, overlaps nothing of it, and shares its zone.
        let shellRect = CGRect(x: shellFrame.x, y: shellFrame.y, width: shellFrame.width, height: shellFrame.height)
        let agentRect = CGRect(x: agentFrame.x, y: agentFrame.y, width: agentFrame.width, height: agentFrame.height)
        let sideBySide = agentRect.minX >= shellRect.maxX && agentRect.minX - shellRect.maxX < 64
            && agentRect.minY < shellRect.maxY && agentRect.maxY > shellRect.minY
        let stacked = agentRect.minY >= shellRect.maxY && agentRect.minY - shellRect.maxY < 64
            && agentRect.minX < shellRect.maxX && agentRect.maxX > shellRect.minX
        try expect((sideBySide || stacked) && !agentRect.intersects(shellRect)
                   && fixture.canvas.zoneId(containing: agentTileId) == fixture.canvas.zoneId(containing: shell.tile.id),
                   "the agent tile must sit against the shell in its zone; shell \(shellFrame), agent \(agentFrame)")
        log.append("agent tile \(sideBySide ? "right of" : "below") the shell: shell \(shellRect), agent \(agentRect)")
        try expect(pump(until: { occurrences("PRIOR busy question", in: entries(agentTile)) == 1 }, timeout: 5),
                   "the session's history must be replayed once; got \(entries(agentTile))")
        try expect(supervisor.sendRefusal(for: busyAgent) != nil && supervisor.isSessionHeld(busyAgent),
                   "while the shell's claude writes the session, the agent must not")
        try expect(agentTile.sessionHandoffState == .waitingToMove(app: place, closesInApp: false, canCopy: true)
                   && agentTile.qaSessionHandoffBanner != nil,
                   "the agent tile must say the session is still open in '\(place)'; state \(String(describing: agentTile.sessionHandoffState))")
        guard let firstEntry = agentTile.qaDocumentForChecks.entries.first else { throw Failure(description: "no history") }
        try expect(firstEntry.blocks.map(\.kind) == [.sessionBoundary]
                   && AgentTranscriptCopyController.plainText(for: firstEntry.blocks).hasPrefix("From \(place)"),
                   "the history must follow a 'From \(place)' session boundary; got \(firstEntry.blocks.map(\.kind.rawValue))")
        try expect(pump(until: { shell.claudeSessionId == nil && button() == nil }, timeout: 3),
                   "once an agent owns the session the shell stops offering it")
        let shellRow = ExternalSessionRows.rowId(forSessionKey: "claude:\(busySid)")
        let waitingRows = rowsFor(busySid)
        try expect(waitingRows == [shellRow] && inbox.row(forAgentId: shellRow)?.whereMarker?.text == place,
                   "one row for the session — the shell's, marked '\(place)', while it holds it; got \(waitingRows.count) rows, marker \(String(describing: inbox.row(forAgentId: shellRow)?.whereMarker))")
        fixture.canvas.layoutSubtreeIfNeeded()
        AgentFaceChecks.saveWindowPNG(window, to: directory.appendingPathComponent("agent-beside-shell-waiting.png"))
        AgentFaceChecks.savePNG(of: agentTile, rect: agentTile.bounds,
                                to: directory.appendingPathComponent("agent-tile-waiting.png"))
        log.append("busy: agent tile beside the shell, history once, waiting as Move here, no /exit")

        // The turn ends; the agent still waits (decision 2: Array never ends a
        // claude it found busy), until the person types /exit themselves.
        try expect(pump(until: { liveStatus(busySid) == "idle" }, timeout: 10), "the slow turn never ended")
        pump(1.0)
        try expect(!typed(busySid).contains { $0.text == "/exit" } && supervisor.isSessionHeld(busyAgent),
                   "after the busy turn the agent keeps waiting and Array types nothing; typed \(typed(busySid).map(\.text))")
        try expect(rowsFor(busySid).count == 1, "still one row")
        enter("/exit")
        try expect(pump(until: { !supervisor.isSessionHeld(busyAgent) }, timeout: 8),
                   "the agent must go live once the shell's claude exits")
        let afterExit = entries(agentTile)
        try expect(occurrences("fake: slow turn", in: afterExit) == 1 && occurrences("slow turn", in: afterExit) == 2
                   && occurrences("PRIOR busy question", in: afterExit) == 1,
                   "the shell's turn and the history each appear once; got \(afterExit)")
        let adopted = supervisor.records[busyAgent]
        try expect(adopted?.providerSessionId == busySid && adopted?.externalSession == nil
                   && adopted.map { AgentSupervisor.claudeRunnerConfig(for: $0) }.map { $0.sessionId == busySid && $0.conversationMayExist } == true,
                   "the agent now resumes the shell's session itself; record \(String(describing: adopted?.providerSessionId))")
        try expect(agentTile.sessionHandoffState == nil && supervisor.sendRefusal(for: busyAgent) == nil,
                   "a live agent shows no waiting banner and can be sent to")
        let liveRows = rowsFor(busySid)
        try expect(liveRows == [busyAgent.rawValue] && inbox.row(forAgentId: busyAgent.rawValue)?.whereMarker == nil,
                   "one row, now the agent's own; got \(liveRows.count) rows, marker \(String(describing: inbox.row(forAgentId: busyAgent.rawValue)?.whereMarker))")
        // The command line reads "shell-back 1234"; only the shell's output
        // reads "shell-back-1234".
        let busyMark = Int.random(in: 1000...9999)
        enter("printf '%s-%s\\n' shell-back \(busyMark)")
        try expect(pump(until: { shellRuntime.visibleText().contains("shell-back-\(busyMark)") }, timeout: 8),
                   "the shell must have its prompt back after /exit; screen ends \(shellRuntime.visibleText().suffix(400))")
        fixture.canvas.layoutSubtreeIfNeeded()
        agentTile.layoutSubtreeIfNeeded()
        pump(0.3)
        AgentFaceChecks.saveWindowPNG(window, to: directory.appendingPathComponent("agent-live-after-shell-exit.png"))
        AgentFaceChecks.savePNG(of: agentTile, rect: agentTile.bounds,
                                to: directory.appendingPathComponent("agent-tile-after-shell-exit.png"))
        log.append("busy: went live on the person's /exit; the shell's last turn followed in the tile")

        // 3a. Review finding 5: idle is not empty. A draft in claude's input box
        //     would be submitted with "/exit" on the end, as a turn, so Array
        //     types nothing and the tile waits as for a busy claude.
        let draftSid = UUID().uuidString.lowercased()
        try writeHistory(draftSid, "PRIOR draft question", "PRIOR draft answer")
        startClaude(draftSid)
        try expect(pump(until: { liveStatus(draftSid) == "idle" }, timeout: 15), "the draft claude never started")
        shellRuntime.sendInput(Data("fix the bu".utf8))
        try expect(pump(until: { shellRuntime.visibleText().contains("\u{276F} fix the bu") }, timeout: 5),
                   "the stand-in must draw the draft in its input box; screen \(shellRuntime.visibleText().suffix(300))")
        try expect(pump(until: { shell.claudeSessionId == draftSid && button() != nil }, timeout: 10),
                   "the band must offer the draft's session")
        let beforeDraft = Set(supervisor.records.keys)
        guard let draftPoint = button() else { throw Failure(description: "no button for the draft session") }
        try AgentFaceChecks.click(draftPoint, in: window)
        guard let draftAgent = Set(supervisor.records.keys).subtracting(beforeDraft).first else {
            throw Failure(description: "the draft click created no agent")
        }
        try expect(pump(until: { delegate.qaShellHandoffTypedExit != nil }, timeout: 3) && delegate.qaShellHandoffTypedExit == false,
                   "a claude with a draft in its input box must never be sent /exit")
        pump(0.6)
        try expect(!typed(draftSid).contains { $0.text.contains("/exit") } && supervisor.isSessionHeld(draftAgent),
                   "nothing may be typed over a draft; claude received \(typed(draftSid).map(\.text))")
        guard let draftTile = supervisor.records[draftAgent]?.tileId.flatMap({ fixture.canvas.tileView(for: $0) as? ManagedAgentTileNSView })
        else { throw Failure(description: "the draft agent must have a tile") }
        try expect(draftTile.qaSessionHandoffBanner?.titleLabel.stringValue == "Still open in \(place)"
                   && draftTile.qaSessionHandoffBanner?.detailLabel.stringValue == "Type /exit there and it continues here.",
                   "the tile waits, saying where to type /exit")
        // The person clears the draft and leaves claude themselves.
        for _ in 0..<10 { shellRuntime.dispatchKeyDown(keyCode: 0x33, characters: "\u{7F}") }
        try expect(pump(until: { shellRuntime.visibleText().contains("\u{276F} \n") || !shellRuntime.visibleText().contains("fix the bu") }, timeout: 5),
                   "the person's Delete presses must clear the draft; screen \(shellRuntime.visibleText().suffix(300))")
        enter("/exit")
        try expect(pump(until: { liveStatus(draftSid) == nil && !supervisor.isSessionHeld(draftAgent) }, timeout: 8),
                   "after the person's /exit the agent goes live")
        log.append("draft: Array typed nothing over 'fix the bu'; the tile waited for the person's /exit")

        // 3. Idle: Array types /exit itself, and the shell gets its prompt back.
        let idleSid = UUID().uuidString.lowercased()
        try writeHistory(idleSid, "PRIOR idle question", "PRIOR idle answer")
        startClaude(idleSid, reportGroup: true)
        try expect(pump(until: { liveStatus(idleSid) == "idle" }, timeout: 15), "the second claude never started")
        let groupTarget = reportedTmux(idleSid) ?? ""
        try expect(groupTarget.hasPrefix("array-proj-") && groupTarget.hasSuffix(".\(pane ?? "-")"),
                   "the second claude names the project's shared session and the shell's pane; got \(groupTarget)")
        try expect(pump(until: { shell.claudeSessionId == idleSid && button() != nil }, timeout: 10),
                   "the band must offer the new session")
        // The window split, and the new pane (a plain shell) active: keys sent to
        // "the terminal" would land there. /exit must reach claude's own pane.
        let control = ProcessTmuxControl(tmuxPath: tmuxPath, defaults: tmuxDefaults)
        let splitPane = try control.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", pane ?? ""])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try control.run(["select-pane", "-t", splitPane])
        let claudePaneActive = try control.run(["display-message", "-p", "-t", pane ?? "", "#{pane_active}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(claudePaneActive == "0", "precondition: another pane of claude's window is the active one; got \(claudePaneActive)")
        let beforeIdle = Set(supervisor.records.keys)
        guard let idlePoint = button() else { throw Failure(description: "no button for the idle session") }
        try AgentFaceChecks.click(idlePoint, in: window)
        guard let idleAgent = Set(supervisor.records.keys).subtracting(beforeIdle).first else {
            throw Failure(description: "the idle click created no agent")
        }
        try expect(pump(until: { delegate.qaShellHandoffTypedExit != nil }, timeout: 3) && delegate.qaShellHandoffTypedExit == true,
                   "an idle claude with an empty input box must be sent /exit")
        try expect(pump(until: { typed(idleSid).contains { $0.text == "/exit" } }, timeout: 5),
                   "the shell's claude must receive /exit; typed \(typed(idleSid).map(\.text))")
        try expect(typed(idleSid).allSatisfy { $0.status == "idle" }, "every line Array typed must arrive between turns; typed \(typed(idleSid))")
        try expect(pump(until: { liveStatus(idleSid) == nil && !supervisor.isSessionHeld(idleAgent) }, timeout: 8),
                   "claude must exit and the agent go live")
        _ = try control.run(["kill-pane", "-t", splitPane])
        let idleMark = Int.random(in: 1000...9999)
        enter("printf '%s-%s\\n' idle-back \(idleMark)")
        try expect(pump(until: { shellRuntime.visibleText().contains("idle-back-\(idleMark)") }, timeout: 8),
                   "the shell must have its prompt back after Array's /exit")
        guard let idleTileId = supervisor.records[idleAgent]?.tileId,
              let idleTile = fixture.canvas.tileView(for: idleTileId) as? ManagedAgentTileNSView else {
            throw Failure(description: "the idle agent must have a tile")
        }
        try expect(pump(until: { occurrences("PRIOR idle question", in: entries(idleTile)) == 1 }, timeout: 5)
                   && supervisor.records[idleAgent]?.providerSessionId == idleSid,
                   "the idle session's history once, and the agent continues it; got \(entries(idleTile))")
        try expect(rowsFor(idleSid) == [idleAgent.rawValue] && supervisor.sendRefusal(for: idleAgent) == nil,
                   "one row, the live agent's")
        log.append("idle: Array typed /exit between turns, the shell's prompt came back, the agent went live")

        // 4. Review finding 4: `claude --resume` of a session an Array agent
        //    already owns — here the id it derives, which no record names as a
        //    providerSessionId. The sidebar and the band ask one question, so
        //    the band offers that agent, never a second agent on its session.
        let owner = supervisor.spawn(
            role: nil, prompt: nil, cwd: fixture.paRoot, harness: .claudeCode, model: claudeModel, thinking: "",
            projectId: fixture.projectPa, projectRoot: fixture.paRoot, displayName: "Owns its session")
        let ownedSid = AgentSupervisor.claudeSessionId(for: owner)
        try expect(supervisor.records[owner]?.providerSessionId == nil, "precondition: the owner's session is its derived id")
        try writeHistory(ownedSid, "PRIOR owned question", "PRIOR owned answer")
        startClaude(ownedSid)
        try expect(pump(until: { liveStatus(ownedSid) == "idle" }, timeout: 15), "the third claude never started")
        try expect(pump(until: { shell.claudeSessionId == ownedSid && button() != nil }, timeout: 10),
                   "the band must name the session running in the shell")
        try expect(shell.qaSessionActionTitle == TerminalTileNSView.showAgentTitle,
                   "a session an Array agent owns is that agent's: the band offers Show agent; it offers \(String(describing: shell.qaSessionActionTitle))")
        try expect(shell.makeAdditionalTitleBarMenuItems().contains { $0.identifier?.rawValue == "terminalTile.showAgent" },
                   "the tile menu offers Show Agent too")
        let beforeOwned = Set(supervisor.records.keys)
        guard let ownedPoint = button() else { throw Failure(description: "no button for the owned session") }
        try AgentFaceChecks.click(ownedPoint, in: window)
        try expect(Set(supervisor.records.keys) == beforeOwned,
                   "Show agent must never make a second agent on a session an agent owns; made \(Set(supervisor.records.keys).subtracting(beforeOwned).count)")
        try expect(supervisor.records[owner]?.tileId.flatMap { fixture.canvas.tileView(for: $0) } is ManagedAgentTileNSView,
                   "Show agent brings up the owning agent's tile")
        pump(0.6)
        try expect(!typed(ownedSid).contains { $0.text == "/exit" }, "Show agent types nothing into the shell")
        enter("/exit")
        try expect(pump(until: { liveStatus(ownedSid) == nil }, timeout: 8), "the third claude must exit")
        log.append("owned: the band offered Show agent for an agent's own session and made no second agent")

        let manifest: [String: Any] = ["log": log, "typedBusy": typed(busySid).map(\.text), "typedIdle": typed(idleSid).map(\.text)]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"))
        return (log + ["shell open as agent: passed, artifacts \(directory.path)"]).joined(separator: "\n")
    }
}
