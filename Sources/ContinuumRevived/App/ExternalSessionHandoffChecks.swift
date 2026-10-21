import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `.plans/79` phase 2 — what Array does with a session another app holds.
///
/// Three legs, each on the production boot mount (`WorkspaceAPIChecks.makeFixture`)
/// with the production sidebar installed the way boot installs it, and a
/// made-up Mac published through the app's own `ExternalSessionMonitor` — the
/// last step of discovery, so no real process table or session file is read.
/// Session files are synthetic and live in the fixture's temp root. Any claude
/// that runs is `AgentSteeringQAFakes`' stand-in on PATH; no tmux is touched.
///
/// - `--external-session-watch-check [dir]`: clicking a row watches.
/// - `--external-session-move-check [dir]`: Move here waits, then continues.
/// - `--agent-paused-elsewhere-check [dir]`: an Array agent's session opened
///   in another app pauses it; its own processes never do.
///
/// With a directory argument each leg writes PNGs of its tile states there.
@MainActor
enum ExternalSessionHandoffChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    /// The fixture every leg shares: the boot mount, the sidebar, the canvas in
    /// an offscreen window, and a Claude catalogue.
    @MainActor
    private struct World {
        let fixture: WorkspaceAPIChecks.Fixture
        let window: NSWindow
        let canvasWindow: NSWindow
        let sidebar: WorkspaceSidebarView
        let transcripts: URL
        /// The stand-in claude's folder, first on PATH for the whole leg: a
        /// send that should have been refused can never reach a real claude.
        let bin: URL
        let restorePath: () -> Void
        let unpin: () -> Void
        let pngDirectory: URL?
        var delegate: AppDelegate { fixture.delegate }
        var supervisor: AgentSupervisor { fixture.delegate.qaAgentSupervisor }
        var inbox: AgentInboxView { sidebar.inboxForQA }
        var monitor: ExternalSessionMonitor { fixture.delegate.externalSessionMonitor }

        func tearDown() {
            restorePath()
            unpin()
            window.orderOut(nil)
            canvasWindow.orderOut(nil)
            fixture.tearDown()
        }

        func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        func pump(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func publish(_ sessions: [ExternalAgentSession]) {
            monitor.publish(ExternalSessionSnapshot(sessions: sessions))
            delegate.qaRefreshAgentSurfaces()
            inbox.layoutForQA()
        }

        func tileView(_ agentId: AgentID) -> ManagedAgentTileNSView? {
            supervisor.records[agentId]?.tileId.flatMap { fixture.canvas.tileView(for: $0) as? ManagedAgentTileNSView }
        }

        func texts(_ view: ManagedAgentTileNSView) -> [String] {
            view.qaDocumentForChecks.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }
        }

        func count(_ needle: String, in view: ManagedAgentTileNSView) -> Int {
            texts(view).filter { $0.contains(needle) }.count
        }

        func press(_ action: AgentSessionHandoffAction, on view: ManagedAgentTileNSView) throws {
            guard let button = view.qaSessionHandoffBanner?.buttons.first(where: { $0.0 == action })?.1 else {
                throw Failure(message: "the banner shows no \(action.rawValue) button; it shows \(view.qaSessionHandoffBanner?.buttons.map(\.0.rawValue) ?? [])")
            }
            button.performClick(nil)
        }

        func snapshot(_ view: ManagedAgentTileNSView, _ name: String) {
            guard let pngDirectory else { return }
            pump(1.0)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: pngDirectory.appendingPathComponent("\(name).png"))
        }

        /// A synthetic Claude session file, written as claude writes one: one
        /// JSON object per line.
        func writeSession(_ id: String, _ lines: [String]) throws -> URL {
            let url = transcripts.appendingPathComponent("\(id).jsonl")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            return url
        }

        func append(_ text: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
    }

    private static func makeWorld(
        pngDirectory: String?, beforeMount: ((AppDelegate, URL) throws -> Void)? = nil
    ) throws -> World {
        let fixture = try WorkspaceAPIChecks.makeFixture(beforeMount: beforeMount)
        let delegate = fixture.delegate
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        guard let claudeModel = AgentCatalogQAFixture.claude.seedModel else { throw Failure(message: "no claude fixture model") }
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .claudeCode, model: claudeModel)
        try expect(!delegate.externalSessionMonitor.isStarted, "the monitor must be inert in a check (hazard 6)")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        // The canvas in a window of its own, so tiles lay out and draw.
        let canvasWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2000, height: 1200),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        canvasWindow.appearance = NSAppearance(named: .darkAqua)
        canvasWindow.contentView = fixture.canvas
        canvasWindow.orderFrontOffscreenForChecks()
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        delegate.qaRefreshAgentSurfaces()
        sidebar.inboxForQA.pinScrollerStyleForQA()
        sidebar.inboxForQA.setScope(.thisMac)
        sidebar.inboxForQA.layoutForQA()
        let transcripts = fixture.tempRoot.appendingPathComponent("claude-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let png = pngDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let png { try FileManager.default.createDirectory(at: png, withIntermediateDirectories: true) }
        // The follower asks for the file's length every 1.5 s in production;
        // a check need not wait that long.
        ManagedAgentTileNSView.sessionFollowInterval = 0.1
        let bin = fixture.tempRoot.appendingPathComponent("bin", isDirectory: true)
        try AgentSteeringQAFakes.install(.claude, in: bin)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(bin.path):\(originalPath)", 1)
        try expect(ClaudeAgentRunner.liveResolvedCommand().executable.hasPrefix(bin.path),
                   "the stand-in claude must be the one production resolves")
        return World(fixture: fixture, window: window, canvasWindow: canvasWindow, sidebar: sidebar,
                     transcripts: transcripts, bin: bin, restorePath: { setenv("PATH", originalPath, 1) },
                     unpin: unpin, pngDirectory: png)
    }

    private static func userLine(_ uuid: String, _ text: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private static func assistantLine(_ uuid: String, _ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","message":{"id":"m-\#(uuid)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private static func session(
        _ id: String, pid: Int32?, cwd: URL, title: String, status: ExternalSessionStatus = .busy,
        host: ExternalSessionHost, transcript: URL?
    ) -> ExternalAgentSession {
        let now = Date()
        return ExternalAgentSession(
            provider: .claude, sessionId: id, pid: pid, cwd: cwd.path, title: title, status: status,
            startedAt: now.addingTimeInterval(-900), statusSince: now.addingTimeInterval(-60),
            lastActivity: now.addingTimeInterval(-30), host: host, transcriptURL: transcript)
    }

    private static func rowId(_ session: ExternalAgentSession) -> UUID {
        ExternalSessionRows.rowId(forSessionKey: session.id)
    }

    /// A real process standing in for another app's claude: alive until the
    /// leg ends it, so "the holder is still running" is a fact, not a number.
    private static func liveHolder() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        try process.run()
        return process
    }

    /// Ends a `liveHolder()` and waits until it is gone.
    private static func end(_ holder: Process) {
        guard holder.isRunning else { return }
        holder.terminate()
        holder.waitUntilExit()
    }

    /// A pid that WAS a process and is not one now: a holder that has exited.
    /// Spawned after whatever the leg started before it, so it is higher.
    private static func exitedPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// `ps -o lstart`'s shape, in UTC — what claude writes as `procStart`.
    private static func procStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    /// One pass of the production discovery over a made-up Mac: `claude`
    /// session files under `home`, and the process table that goes with them.
    /// Each holder is (pid, session id, entrypoint, ancestry, owner tag).
    private static func discover(
        home: URL, cwd: URL,
        holders: [(pid: Int32, sessionId: String, entrypoint: String, parent: Int32, tag: String?)],
        apps: [ProcessSample]
    ) throws -> ExternalSessionSnapshot {
        let folder = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date().addingTimeInterval(-120)
        var processes = apps + [ProcessSample(pid: getpid(), parentPid: 1, startedAt: started,
                                              executablePath: "/Applications/Array.app/Contents/MacOS/Array",
                                              arguments: [], ownerTag: nil, ownerFace: nil)]
        for holder in holders {
            let object: [String: Any] = [
                "pid": Int(holder.pid), "sessionId": holder.sessionId, "cwd": cwd.path, "status": "idle",
                "kind": "interactive", "entrypoint": holder.entrypoint, "procStart": procStart(started),
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("\(holder.pid).json"))
            processes.append(ProcessSample(pid: holder.pid, parentPid: holder.parent, startedAt: started,
                                           executablePath: "/Users/me/.local/bin/claude", arguments: ["claude"],
                                           ownerTag: holder.tag, ownerFace: nil))
        }
        return ExternalSessionDiscovery().discover(.init(homeURL: home, processes: processes, hostPid: getpid(), now: Date()))
    }

    // MARK: - --external-session-watch-check

    static func runWatch(pngDirectory: String?) throws -> String {
        let world = try makeWorld(pngDirectory: pngDirectory)
        defer { world.tearDown() }
        let supervisor = world.supervisor
        let sessionId = "6f1d3c1e-0a8b-4d6e-9b1a-1c2d3e4f5a60"
        let file = try world.writeSession(sessionId, [
            userLine("u1", "Why is the upload test flaky?"),
            assistantLine("a1", "The upload test races the temp-dir cleanup."),
        ])
        let cmuxProcess = try liveHolder()
        defer { end(cmuxProcess) }
        let cmux = session(sessionId, pid: cmuxProcess.processIdentifier, cwd: world.fixture.pbRoot, title: "Fix flaky upload test",
                           host: .app("cmux"), transcript: file)
        world.publish([cmux])
        try expect(world.inbox.rowIdsForQA.contains(rowId(cmux)), "precondition: the cmux session is a row")

        // 1. A click watches: a tile in the session's project, the banner, no runner.
        let before = Set(supervisor.records.keys)
        try expect(world.inbox.clickRowForQA(id: rowId(cmux)), "the cmux row must be clickable")
        let created = Set(supervisor.records.keys).subtracting(before)
        guard created.count == 1, let agentId = created.first, let record = supervisor.records[agentId] else {
            throw Failure(message: "a click must make exactly one watch agent; made \(created.count)")
        }
        try expect(record.externalSession?.mode == .watching && record.externalSession?.sessionId == sessionId,
                   "the agent is linked to the session as a watch; got \(String(describing: record.externalSession))")
        try expect(record.providerSessionId == nil && record.harness == .claudeCode && record.projectId == world.fixture.projectPb,
                   "a watch does not take the session: no providerSessionId; it is a Claude agent in the session's project")
        guard let tileId = record.tileId, let view = world.tileView(agentId) else {
            throw Failure(message: "the watch agent has no tile")
        }
        try expect(world.fixture.canvas.zoneId(containing: tileId) == world.fixture.zoneB,
                   "the watch tile lands in the session's project's zone")
        try expect(world.pump(until: { world.count("Why is the upload test flaky?", in: view) == 1 }),
                   "the watch tile renders the session from its file; got \(world.texts(view))")
        // On screen, not just in the document: a render that lands before the
        // new tile's first layout used to place the last row nowhere.
        try expect(world.pump(until: {
            (view.qaTranscriptForChecks?.qaVisibleAccessibilityText.count ?? 0) == 3
        }), "all three rows are on screen; visible \(view.qaTranscriptForChecks?.qaVisibleAccessibilityText ?? [])")
        try expect(view.sessionHandoffState == .watching(app: "cmux", canCopy: true, canMove: true),
                   "the banner says Watching in cmux; got \(String(describing: view.sessionHandoffState))")
        try expect(view.qaSessionHandoffBanner?.titleLabel.stringValue == "Watching \u{00B7} running in cmux"
                   && view.qaSessionHandoffBanner?.detailLabel.stringValue == "Read-only. The session stays in cmux.",
                   "the banner's words are the mock's")
        try expect(view.qaSessionHandoffBanner?.buttons.map(\.0) == [.moveHere, .copyHere], "the banner offers Move here and Copy here")
        try expect(view.qaComposerHidden, "the banner replaces the composer")
        try expect(view.qaTitleBarWhereMarker == "cmux \u{00B7} read-only", "the band says where; got \(String(describing: view.qaTitleBarWhereMarker))")
        try expect(view.agentStatusOverride == .working, "the band shows the session's own status (busy in cmux)")
        try expect(!supervisor.isRunning(agentId) && !supervisor.qaHasIdleSession(agentId), "a watch starts no runner")
        try expect(!supervisor.send("write to it", to: agentId) && supervisor.sendRefusal(for: agentId) != nil,
                   "a watch refuses every send")
        try expect(supervisor.turnSnapshot(for: agentId)?.capabilities.canSend == false, "the composer cannot send")
        try expect(!supervisor.isRunning(agentId) && AgentSteeringQAFakes.spawnCount(in: world.bin) == 0,
                   "the refused send started nothing")
        let ids = world.inbox.rowIdsForQA
        try expect(ids.contains(rowId(cmux)) && !ids.contains(agentId.rawValue),
                   "the session keeps ONE row, the other app's; the watch agent has none of its own; got \(world.inbox.titlesForQA)")
        world.snapshot(view, "watch")

        // 2. Follow: lines the other app appends render once each. A line
        //    caught mid-write is read whole on a later pass, never half.
        let original = try Data(contentsOf: file)
        try world.append(userLine("u2", "Now run it 50 times.") + "\n" + String(assistantLine("a2", "Done: 50 of 50 green.").prefix(40)), to: file)
        try expect(world.pump(until: { world.count("Now run it 50 times.", in: view) == 1 }),
                   "an appended prompt renders; got \(world.texts(view))")
        let offsetMidWrite = view.qaSessionFollowOffset ?? 0
        let sizeMidWrite = SessionFileTail.length(file)
        try world.append(String(assistantLine("a2", "Done: 50 of 50 green.").dropFirst(40)) + "\n", to: file)
        try expect(world.pump(until: { world.count("Done: 50 of 50 green.", in: view) == 1 }),
                   "the line finished after a pass renders whole; got \(world.texts(view))")
        try expect(offsetMidWrite == sizeMidWrite - 40 && view.qaSessionFollowOffset == SessionFileTail.length(file),
                   "the follower's offset stopped at the last whole line (\(offsetMidWrite) of \(sizeMidWrite)), then reached the end")
        world.pump(0.5)
        for needle in ["Why is the upload test flaky?", "The upload test races", "Now run it 50 times.", "Done: 50 of 50 green."] {
            try expect(world.count(needle, in: view) == 1, "'\(needle)' renders exactly once; got \(world.count(needle, in: view)) in \(world.texts(view))")
        }
        try expect(view.qaSessionFollowTimerRunning, "the follower keeps running while the tile is resident")
        let written = try Data(contentsOf: file)
        try expect(written.starts(with: original) && !supervisor.isRunning(agentId),
                   "Array never wrote the session file (it grew only by what the fixture appended)")

        // 3. The row again: the same tile, never a second.
        try expect(world.inbox.clickRowForQA(id: rowId(cmux)), "the row is clickable again")
        let linked = supervisor.records.values.filter { $0.externalSession?.sessionKey == cmux.id }
        try expect(linked.count == 1 && linked.first?.id == agentId && supervisor.records[agentId]?.tileId == tileId,
                   "clicking the row again shows the same watch tile; got \(linked.count) watch agents")

        // 4. Review finding 6: one pass without the session while its process
        //    still runs (a status file caught mid-rewrite) is not an end.
        world.publish([])
        try expect(view.sessionHandoffState == .watching(app: "cmux", canCopy: true, canMove: true),
                   "a pass that misses a session whose process still runs must not end the watch; got \(String(describing: view.sessionHandoffState))")
        world.publish([cmux])
        // The session ends in cmux: Ended, then Continue here takes it.
        end(cmuxProcess)
        world.publish([])
        try expect(view.sessionHandoffState == .ended(app: "cmux"),
                   "a watched session that ends says so; got \(String(describing: view.sessionHandoffState))")
        try expect(view.qaSessionHandoffBanner?.buttons.map(\.0) == [.continueHere], "Ended offers Continue here")
        try expect(world.inbox.rowIdsForQA.contains(agentId.rawValue),
                   "with the other app's row gone, the tile's agent has a row of its own")
        world.snapshot(view, "ended")
        try world.press(.continueHere, on: view)
        guard let continued = supervisor.records[agentId] else { throw Failure(message: "Continue here lost the agent") }
        try expect(continued.externalSession == nil && continued.providerSessionId == sessionId,
                   "Continue here makes the session the agent's own: providerSessionId == \(sessionId); got \(String(describing: continued.providerSessionId))")
        let config = AgentSupervisor.claudeRunnerConfig(for: continued)
        try expect(config.sessionId == sessionId && config.conversationMayExist && !config.forkSession
                   && config.cwd.standardizedFileURL.path == world.fixture.pbRoot.standardizedFileURL.path,
                   "its next prompt runs `claude --resume \(sessionId)` in the session's folder; got \(config.sessionId) resume=\(config.conversationMayExist)")
        try expect(view.sessionHandoffState == nil && !view.qaComposerHidden && view.qaTitleBarWhereMarker == nil,
                   "the banner goes and the composer comes back")
        try expect(supervisor.sendRefusal(for: agentId) == nil, "the agent sends now")
        try expect(world.count("Done: 50 of 50 green.", in: view) == 1, "the transcript is still whole, once")
        let after = try Data(contentsOf: file)
        try expect(after == written, "Array never wrote the session file")

        return "ExternalSessionHandoffChecks.watch: a click watches the session read-only in its project with no runner; "
            + "appended lines render once each, a half-written one whole; the row again shows the same tile; "
            + "an ended session continues here on its own id"
            + (pngDirectory.map { " (png: \($0))" } ?? "")
    }

    // MARK: - --external-session-move-check

    static func runMove(pngDirectory: String?) throws -> String {
        let world = try makeWorld(pngDirectory: pngDirectory)
        defer { world.tearDown() }
        let supervisor = world.supervisor
        let bin = world.bin

        let sessionId = "0c5e2a71-6b3f-4b0e-8f4d-2a9c7e1b3d40"
        let file = try world.writeSession(sessionId, [
            userLine("u1", "Why is the upload test flaky?"),
            assistantLine("a1", "The upload test races the temp-dir cleanup."),
        ])
        let cmuxProcess = try liveHolder()
        defer { end(cmuxProcess) }
        let cmux = session(sessionId, pid: cmuxProcess.processIdentifier, cwd: world.fixture.pbRoot, title: "Fix flaky upload test",
                           host: .app("cmux"), transcript: file)
        let desktopId = "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a"
        let desktop = session(desktopId, pid: 41_102, cwd: world.fixture.pbRoot, title: "LinkedIn post",
                              status: .idle, host: .app("Claude app"),
                              transcript: try world.writeSession(desktopId, [userLine("d1", "Draft the launch post.")]))
        let copyId = "4b3a2918-7766-4554-8332-21100ffeeddc"
        let copySource = session(copyId, pid: 41_103, cwd: world.fixture.pbRoot, title: "Port scanner spike",
                                 status: .idle, host: .app("Ghostty"),
                                 transcript: try world.writeSession(copyId, [userLine("c1", "Spike a port scanner.")]))
        world.publish([cmux, desktop, copySource])

        // 1. Move here through the row's own button: the tile waits.
        try expect(world.inbox.hoverRowForQA(id: rowId(cmux)), "the cmux row must be hoverable")
        world.inbox.layoutForQA()
        let before = Set(supervisor.records.keys)
        try expect(world.inbox.clickExternalActionForQA(id: rowId(cmux), .moveHere), "Move here must be pressable")
        guard let agentId = Set(supervisor.records.keys).subtracting(before).first,
              let view = world.tileView(agentId) else { throw Failure(message: "Move here made no tile") }
        try expect(supervisor.records[agentId]?.externalSession?.mode == .movingHere, "the tile is a Move here")
        try expect(view.sessionHandoffState == .waitingToMove(app: "cmux", closesInApp: false, canCopy: true),
                   "it waits for cmux; got \(String(describing: view.sessionHandoffState))")
        try expect(view.qaSessionHandoffBanner?.titleLabel.stringValue == "Still open in cmux"
                   && view.qaSessionHandoffBanner?.detailLabel.stringValue == "Type /exit there and it continues here.",
                   "the banner's words are the mock's")
        try expect(view.qaSessionHandoffBanner?.buttons.map(\.0) == [.copyInstead, .cancel], "it offers Copy instead and Cancel")
        try expect(world.pump(until: { world.count("Why is the upload test flaky?", in: view) == 1 }),
                   "the waiting tile shows the session so far")
        try expect(!supervisor.isRunning(agentId) && !supervisor.send("now", to: agentId), "waiting starts nothing and refuses sends")
        try expect(AgentSteeringQAFakes.spawnCount(in: bin) == 0, "no claude has run")
        world.snapshot(view, "waiting")

        // 2. Review finding 6: a pass that misses the session while cmux's
        //    process still runs must not hand it over — that is two writers.
        world.publish([desktop, copySource])
        try expect(supervisor.records[agentId]?.externalSession?.mode == .movingHere && supervisor.isSessionHeld(agentId)
                   && view.sessionHandoffState == .waitingToMove(app: "cmux", closesInApp: false, canCopy: true),
                   "the session must stay cmux's while its process runs; link \(String(describing: supervisor.records[agentId]?.externalSession))")
        world.publish([cmux, desktop, copySource])
        // cmux writes its last turn and exits: the tile goes live at once.
        try world.append(userLine("u2", "One last thing in cmux.") + "\n" + assistantLine("a2", "Handled in cmux.") + "\n", to: file)
        end(cmuxProcess)
        world.publish([desktop, copySource])
        guard let live = supervisor.records[agentId] else { throw Failure(message: "the agent went away") }
        try expect(live.externalSession == nil && live.providerSessionId == sessionId,
                   "the process gone, the tile is the session's: providerSessionId == \(sessionId); got \(String(describing: live.providerSessionId))")
        try expect(view.sessionHandoffState == nil && !view.qaComposerHidden, "the banner goes and the composer comes back")
        for needle in ["Why is the upload test flaky?", "The upload test races", "One last thing in cmux.", "Handled in cmux."] {
            try expect(world.count(needle, in: view) == 1,
                       "'\(needle)' is in the transcript exactly once; got \(world.count(needle, in: view)) in \(world.texts(view))")
        }
        let sizeAtLive = SessionFileTail.length(file)
        world.pump(0.4)
        try expect(!view.qaSessionFollowTimerRunning, "a live agent follows no file")
        try expect(world.count("Handled in cmux.", in: view) == 1, "nothing replays twice after going live")
        // Its first own turn resumes the session, through the production runner.
        try expect(ClaudeAgentRunner.liveResolvedCommand().executable.hasPrefix(bin.path), "the fake claude must be the one production resolves")
        try expect(supervisor.send("PLAIN carry on", to: agentId), "the moved session sends from Array now")
        try expect(world.pump(until: { AgentSteeringQAFakes.spawnCount(in: bin) == 1 && !supervisor.isRunning(agentId) }, timeout: 15),
                   "the first own turn runs and ends")
        let argv = AgentSteeringQAFakes.argv(in: bin)
        if let flag = argv.firstIndex(of: "--resume") {
            try expect(argv.indices.contains(flag + 1) && argv[flag + 1] == sessionId, "the turn resumes \(sessionId); argv \(argv)")
        } else {
            throw Failure(message: "the first turn must run `claude --resume \(sessionId)`; argv \(argv)")
        }
        try expect(!argv.contains("--fork-session"), "a move continues the session, never forks it")
        try expect(SessionFileTail.length(file) == sizeAtLive, "Array's own code never wrote the moved session's file")

        // 3. Claude app session, then Cancel: the tile and its agent go.
        try expect(world.inbox.hoverRowForQA(id: rowId(desktop)), "the Claude app row must be hoverable")
        world.inbox.layoutForQA()
        let beforeDesktop = Set(supervisor.records.keys)
        try expect(world.inbox.clickExternalActionForQA(id: rowId(desktop), .moveHere), "Move here on the Claude app row")
        guard let desktopAgent = Set(supervisor.records.keys).subtracting(beforeDesktop).first,
              let desktopView = world.tileView(desktopAgent),
              let desktopTile = supervisor.records[desktopAgent]?.tileId else { throw Failure(message: "no Claude app tile") }
        try expect(desktopView.sessionHandoffState == .waitingToMove(app: "Claude app", closesInApp: true, canCopy: true)
                   && desktopView.qaSessionHandoffBanner?.detailLabel.stringValue == "Close it in the Claude app and it continues here.",
                   "a Claude app session is closed in the Claude app (edge 13); got \(String(describing: desktopView.qaSessionHandoffBanner?.detailLabel.stringValue))")
        try world.press(.cancel, on: desktopView)
        try expect(supervisor.records[desktopAgent] == nil, "Cancel drops the waiting agent")
        try expect(world.fixture.canvas.tileView(for: desktopTile) == nil
                   && !world.fixture.canvas.allWorkspaceTiles().contains { $0.id == desktopTile },
                   "Cancel removes the waiting tile")
        world.delegate.qaRefreshAgentSurfaces()
        world.inbox.layoutForQA()
        try expect(world.inbox.rowIdsForQA.contains(rowId(desktop)), "the session keeps its row in the Claude app")

        // 4. Copy instead: the waiting tile becomes a copy that forks.
        try expect(world.inbox.hoverRowForQA(id: rowId(copySource)), "the Ghostty row must be hoverable")
        world.inbox.layoutForQA()
        let beforeCopy = Set(supervisor.records.keys)
        try expect(world.inbox.clickExternalActionForQA(id: rowId(copySource), .moveHere), "Move here on the Ghostty row")
        guard let copyAgent = Set(supervisor.records.keys).subtracting(beforeCopy).first,
              let copyView = world.tileView(copyAgent) else { throw Failure(message: "no Ghostty tile") }
        let copyTile = supervisor.records[copyAgent]?.tileId
        try expect(world.pump(until: { world.count("Spike a port scanner.", in: copyView) == 1 }), "the waiting tile shows the session")
        try world.press(.copyInstead, on: copyView)
        guard let copy = supervisor.records[copyAgent] else { throw Failure(message: "Copy instead lost the agent") }
        try expect(copy.externalSession == nil && copy.pendingSessionForkFrom == copyId && copy.providerSessionId == nil
                   && copy.tileId == copyTile,
                   "Copy instead turns the same tile into a copy: pendingSessionForkFrom == \(copyId); got \(String(describing: copy.pendingSessionForkFrom))")
        let forkConfig = AgentSupervisor.claudeRunnerConfig(for: copy)
        try expect(forkConfig.sessionId == copyId && forkConfig.forkSession, "its first turn forks the session")
        try expect(copyView.sessionHandoffState == nil && world.count("Spike a port scanner.", in: copyView) == 1,
                   "the copy keeps the history once, with its composer back")

        return "ExternalSessionHandoffChecks.move: Move here waits with no runner while the session is open, goes live on the "
            + "same id the moment its process is gone (transcript once, first turn `--resume`), Cancel removes the tile, "
            + "Copy instead turns it into a fork"
            + (pngDirectory.map { " (png: \($0))" } ?? "")
    }

    // MARK: - --agent-paused-elsewhere-check

    static func runPaused(pngDirectory: String?) throws -> String {
        // Review finding 3, as a relaunch leaves it: a Claude agent whose tile
        // was saved in its Terminal face, in ANOTHER workspace's project, so no
        // tile of it is built — and the claude that face runs is still alive in
        // tmux. Nothing has been sent and discovery has not looked yet.
        var faceAgent: AgentID?
        let faceTile = UUID()
        let world = try makeWorld(pngDirectory: pngDirectory) { delegate, tempRoot in
            guard let model = AgentCatalogQAFixture.claude.seedModel else { throw Failure(message: "no claude fixture model") }
            let pcRoot = tempRoot.appendingPathComponent("Pc", isDirectory: true)
            let projects = try RegistryStore(applicationSupportDirectory: tempRoot.appendingPathComponent("AppSupport", isDirectory: true))
                .loadOrEmpty().projects
            guard let pc = projects.first(where: { $0.name == "Pc" }) else { throw Failure(message: "no project Pc") }
            let id = delegate.qaAgentSupervisor.spawn(
                role: nil, prompt: nil, cwd: pcRoot, harness: .claudeCode, model: model, thinking: "",
                projectId: pc.id, projectRoot: pcRoot, tileId: faceTile, displayName: "Face in workspace B")
            faceAgent = id
            let store = ProjectStore(projectRoot: pcRoot)
            var canvas = try store.loadCanvas()
            var tile = Tile(id: faceTile, kind: .managedAgent, title: "Face in workspace B",
                            frame: TileFrame(x: 300, y: 40, width: 560, height: 520),
                            zPosition: .fromLegacyRank(2), runtimeRef: nil,
                            metadata: TileMetadata(agentTerminalFace: AgentTerminalFaceState(
                                sessionId: AgentSupervisor.claudeSessionId(for: id), cwd: pcRoot.path, sessionFileOffset: 0)))
            tile.zoneId = canvas.tiles.first?.zoneId
            canvas.tiles.append(tile)
            try store.saveCanvas(canvas)
        }
        defer { world.tearDown() }
        let supervisor = world.supervisor
        let delegate = world.delegate
        let bin = world.bin
        var activated: [(Int32?, String)] = []
        delegate.activateExternalSessionHostForQA = { activated.append(($0, $1)) }

        guard let faceAgent else { throw Failure(message: "no Terminal-face agent") }
        try expect(world.fixture.canvas.tileView(for: faceTile) == nil, "precondition: the face agent's tile is not built")
        // The saved face holds the session from the moment the scene mounts:
        // the production send path refuses, and no claude starts.
        try expect(supervisor.isSessionHeld(faceAgent) && !supervisor.send("PLAIN from Array", to: faceAgent)
                   && supervisor.sendRefusal(for: faceAgent)?.contains("Terminal face") == true,
                   "an agent saved in its Terminal face must be held at boot, tile or no tile; refusal \(String(describing: supervisor.sendRefusal(for: faceAgent)))")
        try expect(AgentSteeringQAFakes.spawnCount(in: bin) == 0, "no claude ran for the held face agent")
        // Discovery finds its claude still running in the Terminal face: held.
        let faceProcess = try liveHolder()
        defer { end(faceProcess) }
        let faceSession = session(AgentSupervisor.claudeSessionId(for: faceAgent), pid: faceProcess.processIdentifier,
                                  cwd: world.fixture.pcRoot, title: "Face in workspace B", status: .idle,
                                  host: .arrayTerminalFace(agentId: AgentProcessAttribution.ownerTag(for: faceAgent)),
                                  transcript: nil)
        world.publish([faceSession])
        try expect(supervisor.isSessionHeld(faceAgent) && !supervisor.send("PLAIN from Array", to: faceAgent),
                   "a face claude discovery still sees keeps the agent held")
        // One pass without it while it still runs is not its exit (finding 6).
        world.publish([])
        try expect(supervisor.isSessionHeld(faceAgent), "a pass that misses a running face claude must not release it")
        // That claude exits: the agent is Array's again.
        end(faceProcess)
        world.publish([])
        try expect(!supervisor.isSessionHeld(faceAgent) && supervisor.sendRefusal(for: faceAgent) == nil,
                   "once its face claude is gone the agent sends from Array again; refusal \(String(describing: supervisor.sendRefusal(for: faceAgent)))")
        try expect(AgentSteeringQAFakes.spawnCount(in: bin) == 0, "no claude ran while the face held the session")

        // An Array Claude agent with a tile, its claude pooled after a turn.
        guard let model = AgentCatalogQAFixture.claude.seedModel else { throw Failure(message: "no claude fixture model") }
        let agentId = supervisor.spawn(
            role: nil, prompt: nil, cwd: world.fixture.pbRoot, harness: .claudeCode, model: model, thinking: "",
            projectId: world.fixture.projectPb, projectRoot: world.fixture.pbRoot, displayName: "Fix flaky upload test")
        try expect(delegate.revealAgentFromInbox(agentId.rawValue), "the agent gets a tile through the inbox's attach")
        guard let view = world.tileView(agentId) else { throw Failure(message: "the agent has no tile") }
        try expect(supervisor.send("PLAIN first question", to: agentId), "the agent's own turn was refused")
        try expect(world.pump(until: { !supervisor.isRunning(agentId) && supervisor.qaHasIdleSession(agentId) }, timeout: 15),
                   "the turn must end with its claude pooled")
        guard let pooledPid = AgentSteeringQAFakes.latestPid(in: bin), kill(pooledPid, 0) == 0 else {
            throw Failure(message: "the pooled claude must be alive")
        }
        let sessionId = AgentSupervisor.claudeSessionId(for: agentId)
        let file = try world.writeSession(sessionId, [
            userLine("u1", "PLAIN first question"), assistantLine("a1", "ok"),
        ])
        let tag = AgentProcessAttribution.ownerTag(for: agentId)
        func holder(_ host: ExternalSessionHost, pid: Int32?) -> ExternalAgentSession {
            session(sessionId, pid: pid, cwd: world.fixture.pbRoot, title: "Fix flaky upload test", host: host, transcript: file)
        }
        func assertNotPaused(_ why: String) throws {
            try expect(delegate.externalSessionPauses[agentId] == nil && supervisor.externalHold(for: agentId) == nil,
                       "\(why) must never pause the agent")
            try expect(view.sessionHandoffState == nil && !view.qaComposerHidden, "\(why): no banner")
            try expect(supervisor.qaHasIdleSession(agentId) && kill(pooledPid, 0) == 0, "\(why): its claude stays pooled")
            try expect(supervisor.sendRefusal(for: agentId) == nil, "\(why): it still sends")
        }

        // 1. The agent's OWN processes: its tagged runner, its Terminal face,
        //    an untagged runner from an older Array. None of them pauses it.
        world.publish([holder(.arrayManaged(agentId: tag), pid: pooledPid)])
        try assertNotPaused("its own tagged runner")
        // A face claude that has exited (a running one holds the agent: finding 3).
        world.publish([holder(.arrayTerminalFace(agentId: tag), pid: try exitedPid())])
        try assertNotPaused("its own Terminal face")
        world.publish([holder(.arrayManaged(agentId: nil), pid: 42_002)])
        try assertNotPaused("an untagged runner under Array")
        // A Codex app thread is listed by recency, not because it is open.
        world.publish([holder(.app("Claude app"), pid: nil)])
        try assertNotPaused("a listed session with no process")

        // The sidebar's face marker reads the tile's real face: persisted
        // Terminal face, no process evidence at all.
        world.publish([])
        guard let tileId = supervisor.records[agentId]?.tileId,
              var tile = world.fixture.canvas.allWorkspaceTiles().first(where: { $0.id == tileId }) else {
            throw Failure(message: "the agent's tile is not on the canvas")
        }
        tile.metadata.agentTerminalFace = AgentTerminalFaceState(sessionId: sessionId, cwd: world.fixture.pbRoot.path, sessionFileOffset: 0)
        world.fixture.canvas.updateTile(tile, recalculateZoneBounds: false)
        world.delegate.qaRefreshAgentSurfaces()
        world.inbox.layoutForQA()
        try expect(world.inbox.row(forAgentId: agentId.rawValue)?.whereMarker?.text == "Terminal",
                   "a tile persisted in its Terminal face marks its row Terminal from the tile itself; got \(String(describing: world.inbox.row(forAgentId: agentId.rawValue)?.whereMarker))")
        tile.metadata.agentTerminalFace = nil
        world.fixture.canvas.updateTile(tile, recalculateZoneBounds: false)
        world.delegate.qaRefreshAgentSurfaces()
        world.inbox.layoutForQA()
        try expect(world.inbox.row(forAgentId: agentId.rawValue)?.whereMarker == nil, "…and no marker in its Array face")

        // 1b. Review finding 1, through the production discovery: the agent's
        //     pooled runner holds the session with the LOWER pid, and a Ghostty
        //     `claude --resume` of it the higher. One row per session must not
        //     cost the foreign holder its report: the agent pauses.
        let ghosttyPid = try exitedPid()
        try expect(ghosttyPid > pooledPid, "the Ghostty stand-in must have the higher pid")
        let ghosttyApp = ProcessSample(pid: 9_100_001, parentPid: 1, startedAt: Date().addingTimeInterval(-600),
                                       executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                                       arguments: [], ownerTag: nil, ownerFace: nil)
        let discovered = try discover(
            home: world.fixture.tempRoot.appendingPathComponent("discovery-home", isDirectory: true),
            cwd: world.fixture.pbRoot,
            holders: [(pooledPid, sessionId, "sdk-cli", getpid(), tag),
                      (ghosttyPid, sessionId, "cli", ghosttyApp.pid, nil)],
            apps: [ghosttyApp])
        world.monitor.publish(discovered)
        delegate.qaRefreshAgentSurfaces()
        try expect(delegate.externalSessionPauses[agentId]?.hostName == "Ghostty" && supervisor.externalHold(for: agentId) == "Ghostty",
                   "Array's pooled runner on the lower pid must not hide the Ghostty claude holding the same session; discovery reported \(discovered.sessions.map { "\($0.pid.map(String.init) ?? "-") \($0.host)" })")
        world.publish([])
        try expect(delegate.externalSessionPauses[agentId] == nil && supervisor.externalHold(for: agentId) == nil,
                   "the Ghostty holder gone, the pause ends")

        // 2. Someone resumes it in Ghostty: paused.
        let ghosttyProcess = try liveHolder()
        defer { end(ghosttyProcess) }
        let ghostty = ghosttyProcess.processIdentifier
        world.publish([holder(.app("Ghostty"), pid: ghostty)])
        try expect(delegate.externalSessionPauses[agentId]?.hostName == "Ghostty" && supervisor.externalHold(for: agentId) == "Ghostty",
                   "a session opened in Ghostty pauses the agent")
        try expect(view.sessionHandoffState == .paused(app: "Ghostty"), "the tile says so; got \(String(describing: view.sessionHandoffState))")
        try expect(view.qaSessionHandoffBanner?.titleLabel.stringValue == "Paused \u{00B7} also open in Ghostty"
                   && view.qaSessionHandoffBanner?.buttons.map(\.0) == [.showApp]
                   && view.qaSessionHandoffBanner?.buttons.first?.1.title == "Show Ghostty",
                   "the banner's words are the mock's")
        try expect(view.qaComposerHidden && view.agentStatusOverride == .needsAttention, "the composer gives way; the band says Needs attention")
        try expect(!supervisor.qaHasIdleSession(agentId), "the pooled claude is stopped")
        try expect(world.pump(until: { kill(pooledPid, 0) != 0 }, timeout: 5), "the pooled claude process is gone")
        try expect(!supervisor.send("PLAIN from Array", to: agentId) && supervisor.sendRefusal(for: agentId)?.contains("Ghostty") == true,
                   "sends are refused while paused, saying why")
        try expect(supervisor.turnSnapshot(for: agentId)?.capabilities.canSend == false, "the composer cannot send")
        let spawnsWhilePaused = AgentSteeringQAFakes.spawnCount(in: bin)
        try expect(world.inbox.row(forAgentId: agentId.rawValue)?.state == .input
                   && world.inbox.row(forAgentId: agentId.rawValue)?.state.label == AgentStatusVocabulary.label(for: .needsAttention),
                   "the sidebar row says Needs attention; got \(String(describing: world.inbox.row(forAgentId: agentId.rawValue)?.state))")
        try world.press(.showApp, on: view)
        try expect(activated.last.map { $0.0 == ghostty && $0.1 == "Ghostty" } == true, "Show Ghostty brings Ghostty's process forward")
        world.snapshot(view, "paused")

        // 3. Ghostty writes a turn and exits: appended once, the agent resumes.
        try world.append(userLine("u2", "From Ghostty, rename the test.") + "\n" + assistantLine("a2", "Renamed it in Ghostty.") + "\n", to: file)
        let onScreen = world.texts(view)
        // Review finding 6: one pass without it while Ghostty's process still
        // runs (its status file mid-rewrite) is not the other app letting go.
        world.publish([])
        try expect(delegate.externalSessionPauses[agentId] != nil && supervisor.externalHold(for: agentId) == "Ghostty"
                   && world.texts(view) == onScreen && supervisor.sendRefusal(for: agentId) != nil,
                   "the pause must hold while the Ghostty process still runs, appending nothing")
        end(ghosttyProcess)
        world.publish([])
        try expect(delegate.externalSessionPauses[agentId] == nil && supervisor.externalHold(for: agentId) == nil,
                   "the other process gone, the pause ends")
        try expect(view.sessionHandoffState == nil && !view.qaComposerHidden && view.agentStatusOverride == nil, "the banner goes")
        for needle in ["From Ghostty, rename the test.", "Renamed it in Ghostty."] {
            try expect(world.count(needle, in: view) == 1, "'\(needle)' is appended exactly once; got \(world.texts(view))")
        }
        let afterResume = world.texts(view)
        try expect(Array(afterResume.prefix(onScreen.count)) == onScreen && afterResume.count == onScreen.count + 3,
                   "only what Ghostty wrote after the pause began is appended, under one divider; before \(onScreen), after \(afterResume)")
        try expect(world.texts(view).contains { $0.contains("In Ghostty \u{00B7} 1 turn") }, "a divider says where the turn was taken")
        try expect(AgentSteeringQAFakes.spawnCount(in: bin) == spawnsWhilePaused, "nothing ran while paused")
        try expect(supervisor.send("PLAIN carry on", to: agentId), "the agent sends again")
        try expect(world.pump(until: { !supervisor.isRunning(agentId) && AgentSteeringQAFakes.spawnCount(in: bin) == spawnsWhilePaused + 1 }, timeout: 15),
                   "its next turn runs")

        return "ExternalSessionHandoffChecks.paused: the agent's own runner, Terminal face and untagged runners never pause it; "
            + "its session opened in Ghostty stops its claude, refuses sends and says Needs attention; when Ghostty lets go "
            + "its turn is appended once and the agent runs again; the row's Terminal marker reads the tile's real face"
            + (pngDirectory.map { " (png: \($0))" } ?? "")
    }
}
