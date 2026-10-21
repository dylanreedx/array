import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation
import GhosttyKit

/// Session handoff (`.plans/79-session-handoff`), stream D — the witnesses for
/// one agent tile with two faces.
///
/// `--agent-face-switch-check`: the band's controls on a real agent tile in a
/// real canvas, clicked with real mouse events through the window at every
/// width, canvas zoom and page zoom the design names.
///
/// `--agent-face-flip-check`: the production flip, with a stand-in claude on
/// PATH and an isolated tmux server.
@MainActor
enum AgentFaceChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static func runDirectory(_ name: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Fixture

    /// A supervisor with one Claude Code agent and a real canvas in an
    /// off-screen window. Nothing here reads or writes `UserDefaults.standard`
    /// beyond what the canvas itself reads.
    @MainActor
    final class Fixture {
        let root: URL
        let work: URL
        let claudeHome: URL
        let bin: URL
        let supervisor: AgentSupervisor
        let agentID: AgentID
        let canvas: CanvasNSView
        let window: NSWindow
        let ghostty: GhosttyRuntimeContext
        let defaults: UserDefaults
        let suiteName: String
        var closeRequests: [UUID] = []

        init(windowSize: NSSize, ghostty: GhosttyRuntimeContext) throws {
            root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("arr-face-\(UUID().uuidString.prefix(8))", isDirectory: true)
            work = root.appendingPathComponent("work", isDirectory: true)
            claudeHome = root.appendingPathComponent("home", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            for directory in [work, claudeHome, bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            suiteName = "array.qa.agent-face.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            self.ghostty = ghostty
            AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
            supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true)),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(
                    applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
                    debounceInterval: 0))
            agentID = supervisor.spawn(
                role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                model: "anthropic/claude-haiku-4-5-20251001", thinking: "low", displayName: "Fix login redirect")
            canvas = CanvasNSView(canvasState: CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
            canvas.focusBroker = FocusBroker()
            canvas.frame = NSRect(origin: .zero, size: windowSize)
            window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            canvas.onTileCloseRequested = { [weak self] id in self?.closeRequests.append(id) }
        }

        func environment(tmuxPath: String?, command: PiAgentRunner.ResolvedCommand) -> AgentTerminalFaceEnvironment {
            var environment = AgentTerminalFaceEnvironment(
                ghostty: ghostty, tmuxPath: tmuxPath, defaults: defaults, claudeHome: claudeHome)
            environment.claudeCommand = { command }
            environment.pollInterval = 0.3
            environment.confirm = { _, _ in true }
            return environment
        }

        /// A tile installed the way the canvas installs every tile view, and
        /// attached to the agent the way `wireManagedAgentTile` attaches it.
        func makeTile(width: Double, height: Double = 520, metadata: TileMetadata = TileMetadata(launchProfileId: "managed"),
                      id: UUID = UUID(), environment: AgentTerminalFaceEnvironment?) -> ManagedAgentTileNSView {
            let tile = Tile(
                id: id, kind: .managedAgent, title: "Fix login redirect",
                frame: TileFrame(x: 40, y: 40, width: width, height: height),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: metadata)
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            view.terminalFaceEnvironment = environment
            view.attach(agentID: agentID, supervisor: supervisor)
            return view
        }

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

        func tearDown() {
            supervisor.stopAll()
            window.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A real click: down and up through the window, so `hitTest`, the band's
    /// own routing and each control's tracking loop all run.
    static func click(_ windowPoint: NSPoint, in window: NSWindow, right: Bool = false) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(description: "could not create \(type)") }
            return event
        }
        if right {
            window.sendEvent(try event(.rightMouseDown))
            window.sendEvent(try event(.rightMouseUp))
            return
        }
        // Controls track their own mouse-up with `nextEvent`: queue it first.
        NSApplication.shared.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        // A control that acts on mouse-down (⋯) leaves the up queued; deliver
        // it now, as the system would, so it cannot satisfy the next click's
        // tracking loop at the wrong place.
        while let pending = NSApplication.shared.nextEvent(
            matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    static func windowPoint(of rect: NSRect, in view: NSView) -> NSPoint {
        view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// A stand-in claude that just waits: the switch check only needs a live
    /// surface to flip into and out of.
    static func installWaitingClaude(in bin: URL) throws -> PiAgentRunner.ResolvedCommand {
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexec /bin/sleep 600\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return PiAgentRunner.ResolvedCommand(executable: script.path, prefixArgs: [])
    }

    static func savePNG(of view: NSView, rect: NSRect, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The window's own pixels, compositor included — a Ghostty surface draws
    /// through Metal, which `cacheDisplay` cannot see. Own-window capture
    /// needs no Screen Recording grant.
    static func saveWindowPNG(_ window: NSWindow, to url: URL) {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - --agent-face-switch-check

    static func runSwitch() throws -> String {
        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }
        let fixture = try Fixture(windowSize: NSSize(width: 2200, height: 1400), ghostty: ghostty)
        defer { fixture.tearDown() }
        let command = try installWaitingClaude(in: fixture.bin)
        let environment = fixture.environment(tmuxPath: nil, command: command)
        let directory = try runDirectory("agent-face-switch")
        var presented: [NSMenu] = []
        TileNSView.qaMenuPresenter = { presented.append($0) }
        defer { TileNSView.qaMenuPresenter = nil }

        var rows: [[String: Any]] = []
        var lines: [String] = []
        var liveViews: [ManagedAgentTileNSView] = []
        defer {
            // Every surface detached before the Ghostty context is freed.
            for view in liveViews where view.face == .terminal { view.prepareForRemovalFromScene() }
        }
        for width in [320.0, 480.0, 900.0] {
            for zoom in [0.1, 0.3, 1.0, 2.0] {
                for page in [80, 150] {
                    let label = "w\(Int(width)) z\(zoom) p\(page)"
                    let view = fixture.makeTile(width: width, environment: environment)
                    liveViews.append(view)
                    view.setPageZoom(AgentPageZoom(percent: page))
                    view.agentStatus = .working
                    fixture.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                    fixture.window.contentView?.layoutSubtreeIfNeeded()
                    view.layoutSubtreeIfNeeded()
                    fixture.pump(0.02)

                    let controls = view.qaBandControlFrames
                    let names = controls.map(\.name)
                    try expect(names.contains("close"), "\(label): × must always be in the band; got \(names)")
                    // No two controls overlap, and every one keeps its floor.
                    for (index, a) in controls.enumerated() {
                        for b in controls.dropFirst(index + 1) {
                            try expect(!a.frame.intersects(b.frame),
                                       "\(label): \(a.name) \(a.frame) overlaps \(b.name) \(b.frame)")
                        }
                        try expect(a.frame.minX >= -0.5 && a.frame.maxX <= width + 0.5,
                                   "\(label): \(a.name) \(a.frame) leaves the band")
                        try expect(a.frame.height * zoom >= TileNSView.minScreenCloseButtonPx - 0.5
                                   && a.frame.width * zoom >= TileNSView.minScreenCloseButtonPx - 0.5,
                                   "\(label): \(a.name) is \(a.frame.size) world = \(a.frame.width * zoom)×\(a.frame.height * zoom)px on screen, under the 22px floor")
                    }
                    let mode = view.qaFaceSwitchMode
                    var outcome: [String: String] = [:]

                    // × closes.
                    let closesBefore = fixture.closeRequests.count
                    let close = controls.first { $0.name == "close" }!.frame
                    try click(windowPoint(of: close, in: view), in: fixture.window)
                    let closePoint = windowPoint(of: close, in: view)
                    try expect(fixture.closeRequests.count == closesBefore + 1,
                               "\(label): a click on × did not close the tile; hit \(String(describing: fixture.window.contentView?.hitTest(closePoint))) at \(closePoint), × \(close), controls \(controls)")
                    outcome["close"] = "closed"

                    // ⋯ opens the tile menu, which offers the switch.
                    func switchItem(in menu: NSMenu) -> NSMenuItem? {
                        menu.items.first { $0.identifier?.rawValue == "agentTile.switchFace" }
                    }
                    let presentedBefore = presented.count
                    if let actions = controls.first(where: { $0.name == "actions" })?.frame {
                        try click(windowPoint(of: actions, in: view), in: fixture.window)
                        try expect(presented.count == presentedBefore + 1, "\(label): a click on ⋯ opened no menu")
                        outcome["actions"] = "menu"
                    } else {
                        // ⋯ left the band; the band's context menu is the same menu.
                        let bar = view.qaTitleBarFrame
                        // Left of every control: the band's own grab strip.
                        let leftmost = controls.map(\.frame.minX).min() ?? bar.width
                        let bandPoint = NSRect(x: min(bar.width * 0.3, leftmost / 2), y: bar.midY, width: 0, height: 0)
                        try click(windowPoint(of: bandPoint, in: view), in: fixture.window, right: true)
                        try expect(presented.count == presentedBefore + 1, "\(label): right-clicking the band opened no menu")
                        outcome["actions"] = "band menu"
                    }
                    try expect(presented.last.flatMap(switchItem)?.title == "Switch to Terminal",
                               "\(label): the tile menu must offer Switch to Terminal; got \(presented.last?.items.map(\.title) ?? [])")

                    if mode == "hidden" {
                        // Reachable all the same: the menu item flips the tile.
                        guard let menu = presented.last, let item = switchItem(in: menu) else { throw Failure(description: "\(label): no switch item") }
                        menu.performActionForItem(at: menu.index(of: item))
                        try expect(view.face == .terminal, "\(label): Switch to Terminal from the menu did not flip the tile")
                        let back = view.titleBarContextMenuForQA()
                        guard let backItem = switchItem(in: back), backItem.title == "Switch to Array" else {
                            throw Failure(description: "\(label): in the Terminal face the menu must offer Switch to Array")
                        }
                        back.performActionForItem(at: back.index(of: backItem))
                        try expect(fixture.pump(until: { view.face == .array }, timeout: 3),
                                   "\(label): Switch to Array from the menu did not flip back")
                        outcome["switch"] = "menu only"
                    } else {
                        let terminal = controls.first { $0.name == "face.terminal" }!.frame
                        let array = controls.first { $0.name == "face.array" }!.frame
                        try click(windowPoint(of: terminal, in: view), in: fixture.window)
                        try expect(view.face == .terminal, "\(label): a click on the Terminal segment did not flip the tile (mode \(mode))")
                        fixture.pump(0.05)
                        let terminalControls = view.qaBandControlFrames
                        try expect(terminalControls.map(\.name) == names,
                                   "\(label): the band changed shape in the Terminal face: \(terminalControls.map(\.name))")
                        try click(windowPoint(of: array, in: view), in: fixture.window)
                        try expect(fixture.pump(until: { view.face == .array }, timeout: 3),
                                   "\(label): a click on the Array segment did not flip back")
                        outcome["switch"] = "clicked both"
                    }
                    if zoom == 1, page == 80 {
                        let band = NSRect(x: 0, y: 0, width: width, height: 28)
                        savePNG(of: view, rect: band, to: directory.appendingPathComponent("band-\(Int(width)).png"))
                    }
                    rows.append(["width": width, "zoom": zoom, "page": page, "mode": mode,
                                 "pill": view.qaBandShowsStatusPill,
                                 "controls": controls.map { "\($0.name)=\(NSStringFromRect($0.frame))" },
                                 "outcome": outcome])
                    lines.append("\(label): \(mode)\(view.qaBandShowsStatusPill ? "+pill" : "") \(names.joined(separator: ",")) \(outcome.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                    fixture.canvas.removeTile(id: view.tile.id)
                }
            }
        }
        // The design's own widths, at zoom 1: labels and pill at 900, labels at
        // 480, icons at the 320 floor.
        func modeAt(_ width: Double) -> String? {
            rows.first { ($0["width"] as? Double) == width && ($0["zoom"] as? Double) == 1 }?["mode"] as? String
        }
        try expect(modeAt(900) == "labels" && modeAt(480) == "labels" && modeAt(320) == "icons",
                   "at zoom 1 the switch must show labels at 900 and 480 and icons at 320; got \(modeAt(900) ?? "-"), \(modeAt(480) ?? "-"), \(modeAt(320) ?? "-")")
        let data = try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return (lines + ["agent face switch: \(rows.count) configurations clicked, artifacts \(directory.path)"])
            .joined(separator: "\n")
    }
}

// MARK: - --agent-face-flip-check

extension AgentFaceChecks {
    /// The stand-in claude for the flip. `-p` (the managed runner's argv) runs
    /// the reactive stream fake; anything else is the interactive TUI: it
    /// records how it was launched, keeps `~/.claude/sessions/<pid>.json` the
    /// way claude does, and writes each turn typed at it into the session file.
    /// `/model X`, `/clear` and `/exit` behave as claude's do; a line holding
    /// "slow" keeps the turn busy for 3s.
    static let interactiveClaude = #"""
    #!/usr/bin/env python3
    import json, os, sys, time, uuid
    HERE = os.path.dirname(os.path.abspath(__file__))
    argv = sys.argv[1:]
    if "-p" in argv:
        stream = os.path.join(HERE, "claude-stream")
        os.execv(stream, [stream] + argv)
    def value(flag):
        return argv[argv.index(flag) + 1] if flag in argv else None
    sid = value("--resume") or value("--session-id")
    model = value("--model")
    home = open(os.path.join(HERE, "home.txt")).read().strip()
    session_dir = open(os.path.join(HERE, "session-dir.txt")).read().strip()
    stream_pid = None
    try:
        stream_pid = int(open(os.path.join(HERE, "pid.txt")).read().strip())
    except Exception:
        pass
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except Exception:
            return False
    launches = os.path.join(HERE, "terminal-launches.jsonl")
    with open(launches, "a") as f:
        f.write(json.dumps({"argv": argv, "pid": os.getpid(), "cwd": os.getcwd(),
            "ARRAY_AGENT_ID": os.environ.get("ARRAY_AGENT_ID"),
            "ARRAY_AGENT_FACE": os.environ.get("ARRAY_AGENT_FACE"),
            "CONTINUUM_ARRAY_MANAGED_AGENT": os.environ.get("CONTINUUM_ARRAY_MANAGED_AGENT"),
            "stream_pid": stream_pid, "stream_alive": alive(stream_pid) if stream_pid else False}) + "\n")
    sessions = os.path.join(home, ".claude", "sessions")
    os.makedirs(sessions, exist_ok=True)
    os.makedirs(session_dir, exist_ok=True)
    me = os.path.join(sessions, "%d.json" % os.getpid())
    def status(state):
        with open(me + ".tmp", "w") as f:
            json.dump({"pid": os.getpid(), "sessionId": sid, "cwd": os.getcwd(), "status": state,
                       "kind": "interactive", "entrypoint": "cli"}, f)
        os.replace(me + ".tmp", me)
    def append(obj):
        with open(os.path.join(session_dir, sid + ".jsonl"), "a") as f:
            f.write(json.dumps(obj) + "\n")
    status("idle")
    print("FAKE CLAUDE resumed %s on %s" % (sid, model), flush=True)
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        text = line.strip()
        if not text:
            continue
        if text == "/exit":
            break
        if text == "/clear":
            sid = str(uuid.uuid4())
            status("idle")
            print("cleared, now %s" % sid, flush=True)
            continue
        if text.startswith("/model "):
            model = text.split(" ", 1)[1]
            print("model %s" % model, flush=True)
            continue
        status("busy")
        append({"type": "user", "isSidechain": False, "uuid": str(uuid.uuid4()), "sessionId": sid,
                "message": {"role": "user", "content": text}})
        time.sleep(3 if "slow" in text else 0.6)
        append({"type": "assistant", "isSidechain": False, "uuid": str(uuid.uuid4()), "sessionId": sid,
                "message": {"role": "assistant", "model": model,
                            "content": [{"type": "text", "text": "terminal: " + text}]}})
        status("idle")
        print("done: %s" % text, flush=True)
    try:
        os.remove(me)
    except Exception:
        pass
    """#

    static func runFlip() throws -> String {
        guard case let .ready(tmuxPath, socketDir, socketPath) = TmuxIsolation.resolve() else {
            throw Failure(description: "tmux is not isolated: run with TMUX_TMPDIR set to a fresh dir under /tmp and TMUX unset")
        }
        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }
        let fixture = try Fixture(windowSize: NSSize(width: 1000, height: 760), ghostty: ghostty)
        defer { fixture.tearDown() }
        let directory = try runDirectory("agent-face-flip")
        var log: [String] = ["tmux socket \(socketPath) (namespace \(socketDir))"]

        // The fakes: the managed runner and the Terminal face both resolve
        // `claude` from PATH, exactly as production does.
        let stream = try AgentSteeringQAFakes.install(.claude, in: fixture.bin)
        try FileManager.default.moveItem(at: stream, to: fixture.bin.appendingPathComponent("claude-stream"))
        let claude = fixture.bin.appendingPathComponent("claude")
        try interactiveClaude.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(fixture.bin.path):\(originalPath)", 1)
        defer { setenv("PATH", originalPath, 1) }
        try expect(ClaudeAgentRunner.liveResolvedCommand().executable == claude.path,
                   "the fake claude must be the one production resolves; got \(ClaudeAgentRunner.liveResolvedCommand())")

        let supervisor = fixture.supervisor
        let agentID = fixture.agentID
        let sessionId = AgentSupervisor.claudeSessionId(for: agentID)
        guard let record = supervisor.records[agentID] else { throw Failure(description: "no agent record") }
        let sessionURL = ClaudeTerminalFace.sessionFileURL(
            claudeHome: fixture.claudeHome, cwd: record.lastObservedWhere, sessionId: sessionId)
        try fixture.claudeHome.path.write(to: fixture.bin.appendingPathComponent("home.txt"), atomically: true, encoding: .utf8)
        try sessionURL.deletingLastPathComponent().path.write(
            to: fixture.bin.appendingPathComponent("session-dir.txt"), atomically: true, encoding: .utf8)
        func launches() -> [[String: Any]] {
            let text = (try? String(contentsOf: fixture.bin.appendingPathComponent("terminal-launches.jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func tmuxSessionAlive(_ tileId: UUID) -> Bool {
            (try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: fixture.defaults)
                .run(["has-session", "-t", TmuxSession.sessionName(tileId: tileId)])) != nil
        }

        var environment = AgentTerminalFaceEnvironment(
            ghostty: ghostty, tmuxPath: tmuxPath, defaults: fixture.defaults, claudeHome: fixture.claudeHome)
        environment.pollInterval = 0.25
        var confirmations: [String] = []
        var confirmAnswer = false
        environment.confirm = { message, _ in confirmations.append(message); return confirmAnswer }
        let view = fixture.makeTile(width: 760, height: 560, environment: environment)
        var liveViews = [view]
        defer { for v in liveViews where v.face == .terminal { v.prepareForRemovalFromScene() } }
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        func segment(_ name: String, of tile: ManagedAgentTileNSView) throws -> NSPoint {
            guard let frame = tile.qaBandControlFrames.first(where: { $0.name == name })?.frame else {
                throw Failure(description: "the band shows no \(name); controls \(tile.qaBandControlFrames.map(\.name))")
            }
            return windowPoint(of: frame, in: tile)
        }
        func entriesText(_ tile: ManagedAgentTileNSView) -> [String] {
            tile.qaDocumentForChecks.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }
        }

        // 1. A turn in the Array face, on the managed runner. Claude wrote it
        //    to the session file, as the real CLI does.
        try expect(supervisor.send("PLAIN first question", to: agentID), "the Array-face turn was refused")
        try expect(fixture.pump(until: { !supervisor.isRunning(agentID) && supervisor.qaHasIdleSession(agentID) }, timeout: 15),
                   "the Array-face turn must finish and leave its claude pooled")
        guard let streamPid = AgentSteeringQAFakes.latestPid(in: fixture.bin), kill(streamPid, 0) == 0 else {
            throw Failure(description: "the pooled managed claude must be alive before the flip")
        }
        let prior = [
            #"{"type":"user","isSidechain":false,"uuid":"u-1","message":{"role":"user","content":"PLAIN first question"}}"#,
            #"{"type":"assistant","isSidechain":false,"uuid":"a-1","message":{"role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"ok"}]}}"#,
        ]
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (prior.joined(separator: "\n") + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)
        view.qaSetComposerDraftForChecks("a draft that stays")
        let draftBefore = view.qaComposerDraftText

        // 2. Busy: a queued message blocks the flip; then the flip waits for the
        //    turn, Cancel drops it, and Stop now ends the turn and flips.
        try expect(supervisor.send("LONG second", to: agentID), "the long turn was refused")
        try expect(fixture.pump(until: { supervisor.isRunning(agentID) }, timeout: 5), "the long turn never started")
        var queued: IntentAcceptance?
        Task { @MainActor in queued = await supervisor.accept(.queue(AgentPrompt("queued one")), for: agentID) }
        try expect(fixture.pump(until: { queued != nil }, timeout: 3) && queued == .accepted, "queueing failed: \(String(describing: queued))")
        try click(try segment("face.terminal", of: view), in: fixture.window)
        try expect(view.face == .array && !view.qaFaceFlipBannerVisible,
                   "a queued message must block the flip, not wait on it")
        supervisor.clearQueuedMessages(for: agentID)
        try click(try segment("face.terminal", of: view), in: fixture.window)
        try expect(view.pendingTerminalFlip && view.qaFaceFlipBannerVisible && view.face == .array,
                   "a flip mid-turn must wait, with the banner up")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        saveWindowPNG(fixture.window, to: directory.appendingPathComponent("face-array-flip-waiting.png"))
        fixture.pump(1.0)
        try expect(view.face == .array && launches().isEmpty && !tmuxSessionAlive(view.tile.id),
                   "while the turn runs, no terminal may start")
        let banner = view.qaFaceFlipBanner
        try click(windowPoint(of: banner.cancelButton.bounds, in: banner.cancelButton), in: fixture.window)
        try expect(!view.pendingTerminalFlip && !view.qaFaceFlipBannerVisible, "Cancel must drop the waiting flip")
        try click(try segment("face.terminal", of: view), in: fixture.window)
        try expect(view.pendingTerminalFlip, "the flip must wait again")
        try click(windowPoint(of: banner.stopButton.bounds, in: banner.stopButton), in: fixture.window)
        try expect(fixture.pump(until: { view.face == .terminal }, timeout: 15),
                   "Stop now must end the turn and flip to the Terminal face")
        log.append("busy flip: waited, cancelled, stopped, flipped")

        // 3. One writer: the managed claude was gone before the TUI started,
        //    and the TUI carries the agent's tags and the record's model.
        try expect(fixture.pump(until: { !launches().isEmpty }, timeout: 10), "the Terminal face never launched claude")
        let launch = launches()[0]
        try expect(launch["stream_alive"] as? Bool == false && kill(streamPid, 0) != 0,
                   "the managed claude (pid \(streamPid)) must be stopped before the Terminal face starts; launch \(launch)")
        try expect(!supervisor.qaHasIdleSession(agentID) && supervisor.isInTerminalFace(agentID),
                   "the supervisor must have released its runner and hold the session for the Terminal face")
        try expect(launch["ARRAY_AGENT_ID"] as? String == AgentProcessAttribution.ownerTag(for: agentID)
                   && launch["ARRAY_AGENT_FACE"] as? String == "terminal"
                   && launch["CONTINUUM_ARRAY_MANAGED_AGENT"] as? String == "1",
                   "the terminal claude must carry ARRAY_AGENT_ID, ARRAY_AGENT_FACE=terminal and the managed marker; got \(launch)")
        let argv = launch["argv"] as? [String] ?? []
        try expect(argv.starts(with: ["--resume", sessionId]) && argv.contains("claude-haiku-4-5-20251001"),
                   "the terminal claude must resume the agent's session on its model; argv \(argv)")
        try expect(supervisor.sendRefusal(for: agentID) != nil, "the supervisor must refuse sends while the Terminal face holds the session")
        try expect(fixture.canvas.tileRecord(for: view.tile.id)?.metadata.agentTerminalFace?.sessionId == sessionId,
                   "the canvas must persist the Terminal face")
        let before = entriesText(view)
        log.append("terminal launched: argv \(argv.joined(separator: " "))")

        // 4. Work in the terminal: a busy turn, /model, /clear, another turn.
        guard let session = view.terminalFaceSession else { throw Failure(description: "no terminal session") }
        func type(_ text: String) {
            _ = session.runtime.dispatchInsertedText(text)
            session.runtime.sendReturn()
        }
        try expect(fixture.pump(until: { session.claudePid != nil }, timeout: 8), "the face never found claude's pid")
        type("/model claude-sonnet-5-5")
        type("slow third")
        try expect(fixture.pump(until: { session.isBusy }, timeout: 6), "the face must read claude's busy status")
        // × on a busy terminal asks first; refusing keeps everything.
        try click(try segment("close", of: view), in: fixture.window)
        try expect(confirmations.count == 1 && view.face == .terminal && fixture.closeRequests.isEmpty,
                   "× on a busy terminal must ask, and Cancel must keep the tile and claude; asked \(confirmations)")
        try expect(fixture.pump(until: { !session.isBusy }, timeout: 8), "the slow turn never ended")
        type("/clear")
        try expect(fixture.pump(until: { session.sessionIds.count == 2 }, timeout: 8),
                   "/clear must move the face to claude's new session; ids \(session.sessionIds)")
        let clearedId = session.currentSessionId
        type("fourth")
        fixture.pump(1.5)
        saveWindowPNG(fixture.window, to: directory.appendingPathComponent("face-terminal.png"))

        // 5. /exit flips back, never closes; the terminal's turns append once.
        type("/exit")
        try expect(fixture.pump(until: { view.face == .array }, timeout: 10), "/exit must flip the tile back to the Array face")
        try expect(fixture.closeRequests.isEmpty && fixture.canvas.tileView(for: view.tile.id) === view,
                   "/exit must never close the tile")
        try expect(!tmuxSessionAlive(view.tile.id), "claude's tmux session must be gone after /exit")
        let after = entriesText(view)
        try expect(Array(after.prefix(before.count)) == before,
                   "the transcript from before the flip must be unchanged")
        let added = Array(after.dropFirst(before.count))
        let joined = added.joined(separator: "\n")
        try expect(added.first?.contains("In Terminal · 2 turns") == true,
                   "the terminal's turns must follow an 'In Terminal · 2 turns' divider; got \(added)")
        try expect(joined.components(separatedBy: "terminal: slow third").count == 2
                   && joined.components(separatedBy: "terminal: fourth").count == 2
                   && !joined.contains("PLAIN first question"),
                   "each terminal turn must appear exactly once, and nothing from before the mark; got \(added)")
        try expect(view.qaTerminalFaceAppendedTurns == 2, "two terminal turns, got \(view.qaTerminalFaceAppendedTurns)")
        let adopted = supervisor.records[agentID]
        try expect(adopted?.providerSessionId == clearedId,
                   "the Array face must continue the session /clear moved to; record has \(String(describing: adopted?.providerSessionId)), want \(clearedId)")
        try expect(adopted?.model == "anthropic/claude-sonnet-5-5" && supervisor.launchSelection(for: agentID)?.model == "anthropic/claude-sonnet-5-5",
                   "the model picker must show what the terminal ran; record has \(String(describing: adopted?.model))")
        try expect(view.qaComposerDraftText == draftBefore, "the composer draft must stay in the Array face")
        try expect(fixture.canvas.tileRecord(for: view.tile.id)?.metadata.agentTerminalFace == nil
                   && !supervisor.isInTerminalFace(agentID) && supervisor.sendRefusal(for: agentID) == nil,
                   "flipping back must clear the persisted face and release the session")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        saveWindowPNG(fixture.window, to: directory.appendingPathComponent("face-array-after-flip-back.png"))
        // The Array face carries on in the same conversation.
        try expect(supervisor.send("PLAIN fifth", to: agentID), "the Array face must send again after the flip back")
        try expect(fixture.pump(until: { !supervisor.isRunning(agentID) }, timeout: 15), "the fifth turn never ended")
        let resumed = AgentSteeringQAFakes.argv(in: fixture.bin)
        try expect(resumed.contains(clearedId), "the managed runner must resume the terminal's session; argv \(resumed)")
        log.append("flip back: 2 turns appended under the divider; record adopted \(clearedId) and claude-sonnet-5-5")

        // 6. Relaunch: the face persists and reattaches to claude in tmux...
        try click(try segment("face.terminal", of: view), in: fixture.window)
        try expect(fixture.pump(until: { view.face == .terminal && launches().count == 2 }, timeout: 10),
                   "the second flip must start claude again")
        try expect(fixture.pump(until: { tmuxSessionAlive(view.tile.id) }, timeout: 5), "claude must run in tmux")
        let persisted = try fixture.canvas.tileRecord(for: view.tile.id).unwrap("the tile record")
        try expect(persisted.metadata.agentTerminalFace != nil, "the Terminal face must be persisted")
        view.prepareForRemovalFromScene()
        fixture.canvas.removeTile(id: view.tile.id)
        fixture.pump(0.5)
        try expect(tmuxSessionAlive(persisted.id), "claude must outlive the tile's view")
        let relaunched = fixture.makeTile(width: 760, height: 560, metadata: persisted.metadata, id: persisted.id, environment: environment)
        liveViews.append(relaunched)
        try expect(relaunched.reattachTerminalFaceIfNeeded() && relaunched.face == .terminal,
                   "a relaunched tile must come back in its Terminal face")
        fixture.pump(1.0)
        try expect(launches().count == 2, "reattaching must not start a second claude; launches \(launches().count)")
        // ...and comes back in the Array face when tmux lost the session.
        relaunched.prepareForRemovalFromScene()
        fixture.canvas.removeTile(id: persisted.id)
        _ = try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: fixture.defaults)
            .run(["kill-session", "-t", TmuxSession.sessionName(tileId: persisted.id)])
        fixture.pump(0.5)
        let orphaned = fixture.makeTile(width: 760, height: 560, metadata: persisted.metadata, id: persisted.id, environment: environment)
        liveViews.append(orphaned)
        try expect(!orphaned.reattachTerminalFaceIfNeeded() && orphaned.face == .array
                   && orphaned.tile.metadata.agentTerminalFace == nil && !supervisor.isInTerminalFace(agentID),
                   "with the tmux session gone the tile must come back in the Array face and release the session")
        log.append("relaunch: reattached without a second claude; tmux gone came back in Array")

        let manifest: [String: Any] = ["log": log, "launches": launches().map { $0.mapValues { "\($0)" } }]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return (log + ["agent face flip: passed, artifacts \(directory.path)"]).joined(separator: "\n")
    }
}

private extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { throw AgentFaceChecks.Failure(description: "missing \(what)") }
        return self
    }
}
