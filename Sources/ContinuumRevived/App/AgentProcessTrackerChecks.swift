import AppKit
import ContinuumRevivedCore
import Foundation

/// 0.7.30 — `--agent-process-tracker-check`. What an agent left running shows
/// on its tile, opens beside it, and stops, through the production wiring.
///
/// Drives the boot mount (`WorkspaceAPIChecks.makeFixture`, which calls
/// `mountWorkspaceSceneAtBoot`), so the tracker is the one the mount wired into
/// the supervisor. The agent is a real supervisor record; its "CLI" is a real
/// process launched with the environment the production runner config builds,
/// and it leaves a real listener running. Nothing is faked between the process
/// table and the chip.
@MainActor
enum AgentProcessTrackerChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run() throws -> String {
        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempRoot) }
        let delegate = fixture.delegate
        let supervisor = delegate.qaAgentSupervisor
        let tracker = delegate.agentProcessTracker
        try expect(supervisor.processTracker === tracker,
                   "the boot mount must hand the supervisor the app's tracker")
        guard let record = supervisor.records[fixture.agentId] else { throw Failure(message: "fixture agent has no record") }
        let tag = AgentProcessAttribution.ownerTag(for: fixture.agentId)

        // 1. Every production runner config names the agent.
        let owners = [
            AgentSupervisor.runnerConfig(for: record, spawnDepth: 0).processOwner,
            AgentSupervisor.claudeRunnerConfig(for: record).processOwner,
            AgentSupervisor.codexRunnerConfig(for: record).processOwner,
        ]
        try expect(owners.allSatisfy { $0 == tag },
                   "pi, claude and codex runner configs must all carry the agent id; got \(owners)")
        try expect(ClaudeAgentRunner.childEnvironment(workspaceMCP: nil, processOwner: owners[1])[AgentProcessAttribution.ownerEnvironmentKey] == tag
                   && CodexAgentRunner.childEnvironment(workspaceMCP: nil, processOwner: owners[2])[AgentProcessAttribution.ownerEnvironmentKey] == tag,
                   "the claude and codex child environments must carry the agent id")

        // 2. A stand-in CLI, launched with that environment, leaves listeners.
        let directory = fixture.tempRoot.appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let cli = try ProcessGroupChild.spawn(
            executable: me,
            arguments: [ProcessTrackingQAHelper.flag, "agent", directory.path, "spare"],
            environment: PiAgentRunner.childEnvironment(processOwner: owners[0]),
            currentDirectory: nil,
            standardInput: .nullDevice)
        defer { cli.terminateGroup(graceSeconds: 0.2) }

        // A tile attached to the agent, as the canvas would hold it.
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "process-tracker-check",
            frame: TileFrame(x: 0, y: 0, width: 760, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        tile.attach(agentID: fixture.agentId, supervisor: supervisor)
        try expect(tile.qaBackgroundJobsChipValue == nil, "before any job runs the chip must not be on screen")
        let topBar = WorkspaceTopBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 44))
        delegate.qaAttachWorkspaceTopBar(topBar)
        tracker.publish([:])
        try expect(!topBar.qaProcessesVisible, "before any job runs the top bar must not show the processes icon")

        func pump(until done: () -> Bool, seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !done() {
                tracker.refreshNow()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
        }
        // 2a. Arrival is scheduled, not polled: with no one asking, each job
        // is listed within a second of being old enough to list. The check's
        // app is not frontmost, so polling alone would take up to
        // `inactiveInterval` (5s).
        tracker.publish([:])
        tracker.start()
        func wait(until done: () -> Bool, seconds: TimeInterval) -> Date? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return Date() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return done() ? Date() : nil
        }
        guard let listedAt = wait(until: { tracker.jobs(for: fixture.agentId).count == 4 }, seconds: 15) else {
            throw Failure(message: "the tracker must find the agent's four jobs on its own; got \(tracker.jobs(for: fixture.agentId).map { ($0.label, $0.ports) })")
        }
        let youngest = tracker.jobs(for: fixture.agentId).map(\.startedAt).max() ?? listedAt
        let arrivalLag = listedAt.timeIntervalSince(youngest) - AgentProcessAttribution.minimumJobAge
        try expect(arrivalLag < 1.0,
                   "a new job must be listed as soon as it is old enough; it took \(String(format: "%.2f", arrivalLag))s more")

        // 2b. Exit is an event: something else kills a job (an agent running
        // `kill`, the server crashing) and it leaves the list within a second,
        // even though its unreaped process lingers as a zombie.
        guard let spare = tracker.jobs(for: fixture.agentId).first(where: { $0.commandLine.hasSuffix("spare.port") }) else {
            throw Failure(message: "the spare job must be listed")
        }
        try expect(tracker.watchedPidCount >= 4, "every listed process must be watched for its exit; watching \(tracker.watchedPidCount)")
        let killedAt = Date()
        kill(spare.rootPid, SIGTERM)
        guard let goneAt = wait(until: { !tracker.jobs(for: fixture.agentId).contains { $0.id == spare.id } }, seconds: 8) else {
            throw Failure(message: "a job killed from outside must leave the list; still \(tracker.jobs(for: fixture.agentId).map(\.label))")
        }
        let exitLag = goneAt.timeIntervalSince(killedAt)
        try expect(exitLag < 1.0, "a killed job must leave the list at once; it took \(String(format: "%.2f", exitLag))s")
        let jobs = tracker.jobs(for: fixture.agentId)
        try expect(jobs.count == 3, "the tracker must keep the agent's other three jobs; got \(jobs.map { ($0.label, $0.ports) })")
        let ports = jobs.flatMap(\.ports).sorted()
        try expect(ports.count == 3, "each job must report its listening port; got \(ports)")

        // 3. The chip says so, from the tracker's notification alone.
        tile.layoutSubtreeIfNeeded()
        let expectedChip = AgentBackgroundJobText.chipValue(jobs)
        try expect(tile.qaBackgroundJobsChipValue == expectedChip && expectedChip?.hasPrefix(":") == true,
                   "the tile chip must show the ports; got \(String(describing: tile.qaBackgroundJobsChipValue)), want \(String(describing: expectedChip))")

        // An agent this app does not own (another install's tag) is not shown.
        let stranger = UUID().uuidString
        tracker.publish([tag: jobs, stranger: jobs])
        try expect(tracker.jobsByAgent.count == 1 && tracker.jobsByAgent[fixture.agentId] != nil,
                   "a tag naming no agent of this app must be ignored; got \(tracker.jobsByAgent.keys)")

        // 4. The top bar's icon opens the live panel: the agent as a header,
        // one row per job in full, and the rest of the Mac closed at the bottom.
        try expect(topBar.qaProcessesVisible, "with jobs running the top bar must show the processes icon")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(topBar)
        topBar.frame = NSRect(x: 0, y: 556, width: 900, height: 44)
        topBar.layoutSubtreeIfNeeded()
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        ProcessesPanelController.reduceMotion = { true }
        defer { ProcessesPanelController.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        topBar.qaProcessesButton.performClick(nil)
        guard let content = tracker.panel.content, tracker.panel.isPresented else {
            throw Failure(message: "the top bar's icon must open the processes panel")
        }
        try expect(tracker.liveDemand == 1, "an open panel must put the tracker on its one-second scan")
        try expect(topBar.qaProcessesButton.isActive, "the icon must read as pressed while its panel is open")
        try expect(content.qaAgentRows.count == 1 && content.qaJobRows.count == 3,
                   "the panel must head the agent's three jobs with one agent row; got \(content.qaRowOrder)")
        try expect(content.qaRowOrder.last == "other-header" && content.qaOtherAppRows.isEmpty,
                   "other ports must start closed, at the bottom; got \(content.qaRowOrder)")
        try expect(content.qaJobRows.allSatisfy { row in jobs.contains { $0.id == row.job.id } },
                   "every row must be one of the agent's jobs")

        // The rest of the Mac opens in place, from a live scan.
        content.qaDisclosure?.onToggle?()
        pump(until: { !content.qaRowOrder.contains("other-loading") }, seconds: 5)
        try expect(content.otherPortsExpanded && content.qaRowOrder.contains("other-header")
                   && !content.qaRowOrder.contains("other-loading"),
                   "opening other ports must fill them from a scan; got \(content.qaRowOrder)")
        let agentPorts = Set(jobs.flatMap(\.ports))
        try expect(content.qaOtherAppRows.allSatisfy { Set($0.app.ports).isDisjoint(with: agentPorts) },
                   "an agent's own ports must not be listed again under other ports")

        // 5. A port pill opens the port BESIDE the agent: a browser tile in the
        // agent's own zone, framed inside that zone's world rect. The panel
        // closes, since you are going to the tile.
        guard let row = content.qaJobRows.first(where: { !$0.job.ports.isEmpty }), let port = row.job.ports.first,
              let pill = row.subviews.compactMap({ $0 as? ProcessesPortButton }).first(where: { $0.port == port }) else {
            throw Failure(message: "a job with a port must show it as a button")
        }
        let browsersBefore = fixture.canvas.allWorkspaceTiles().filter { $0.kind == .browser }.count
        pill.performClick(nil)
        let browsers = fixture.canvas.allWorkspaceTiles().filter { $0.kind == .browser }
        guard browsers.count == browsersBefore + 1,
              let browser = browsers.first(where: { $0.metadata.url == "http://localhost:\(port)" }) else {
            throw Failure(message: "the port button must spawn one browser tile on http://localhost:\(port); got \(browsers.map(\.metadata.url))")
        }
        try expect(browser.zoneId == fixture.zoneB, "the browser must land in the agent's zone, not the armed one")
        let world = fixture.canvas.tilesInWorldFrames(forProjectId: fixture.projectPb).first { $0.id == browser.id }?.frame
        guard let zone = fixture.canvas.installedZonePlacement(for: fixture.zoneB) else {
            throw Failure(message: "the agent's zone must be installed")
        }
        let zoneRect = CGRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
        if let world {
            try expect(zoneRect.contains(CGRect(x: world.x, y: world.y, width: world.width, height: world.height)),
                       "the browser's world frame \(world) must sit inside the agent's zone \(zoneRect)")
        } else {
            throw Failure(message: "the browser tile must be persisted in the agent's project")
        }
        try expect(!tracker.panel.isPresented && tracker.liveDemand == 0 && !topBar.qaProcessesButton.isActive,
                   "opening a port must close the panel and end the fast scan")

        // 6. The tile's chip opens the same panel for its own agent, and a
        // row's own Stop ends that job and only that one, live.
        tile.showBackgroundProcesses(from: topBar.qaProcessesButton)
        guard let scoped = tracker.panel.content, scoped.scope == fixture.agentId else {
            throw Failure(message: "the chip must open the panel scoped to its agent")
        }
        try expect(!scoped.qaRowOrder.contains("other-header") && scoped.qaJobRows.count == 3,
                   "a tile's panel shows its agent's jobs and not the rest of the Mac; got \(scoped.qaRowOrder)")
        guard let victim = scoped.qaJobRows.first else { throw Failure(message: "no job row") }
        let stoppedPids = victim.job.pids
        victim.stopButton.performClick(nil)
        try expect(victim.isStopping, "Stop must show the row as stopping at once")
        _ = wait(until: { tracker.jobs(for: fixture.agentId).count == 2 && scoped.qaJobRows.count == 2 }, seconds: 10)
        try expect(tracker.jobs(for: fixture.agentId).count == 2 && stoppedPids.allSatisfy { kill($0, 0) != 0 },
                   "the row's Stop must end exactly its own job; left \(tracker.jobs(for: fixture.agentId).map(\.label))")
        try expect(scoped.qaJobRows.count == 2 && !scoped.qaJobRows.contains { $0.job.id == victim.job.id },
                   "the open panel must drop the stopped job by itself; rows \(scoped.qaRowOrder)")

        // 7. Stop All, from the agent row, ends the rest; the chip and the
        // icon go away.
        guard let agentRow = scoped.qaAgentRows.first, !agentRow.stopAllButton.isHidden else {
            throw Failure(message: "two jobs must offer Stop All")
        }
        let pids = jobs.flatMap(\.pids)
        agentRow.stopAllButton.performClick(nil)
        _ = wait(until: { tracker.jobs(for: fixture.agentId).isEmpty && tile.qaBackgroundJobsChipValue == nil }, seconds: 10)
        try expect(tracker.jobs(for: fixture.agentId).isEmpty, "Stop All must leave nothing running")
        try expect(tile.qaBackgroundJobsChipValue == nil, "with nothing running the chip must leave the row")
        // The bug this pass fixed: the icon stayed until its panel was toggled.
        try expect(tracker.totalJobCount > 0 || !topBar.qaProcessesVisible,
                   "when the last job ends the top bar icon must leave by itself, without the panel being toggled")
        tracker.panel.dismiss(animated: false)
        // Other agents of this store may have jobs of their own; the icon
        // follows whether ANY agent has one.
        tracker.publish([:])
        try expect(!topBar.qaProcessesVisible, "with nothing running the top bar icon must go away")
        let alive = pids.filter { kill($0, 0) == 0 }
        try expect(alive.isEmpty, "every stopped pid must be gone; still alive \(alive)")

        // 8. The same UI must expose a portless tool script after its reply
        // and CLI have both finished, keeping the shell's original clock.
        let scriptDirectory = fixture.tempRoot.appendingPathComponent("portless", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        let scriptCLI = try ProcessGroupChild.spawn(
            executable: me,
            arguments: [ProcessTrackingQAHelper.flag, "portless-agent", scriptDirectory.path],
            environment: PiAgentRunner.childEnvironment(processOwner: tag),
            currentDirectory: nil, standardInput: .nullDevice)
        defer { scriptCLI.terminateGroup(graceSeconds: 0.2) }
        let thread = AgentSupervisor.threadId(for: fixture.agentId)
        supervisor.qaDeliver(.sessionStateChanged(.running), to: fixture.agentId)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "portless-tool"), to: fixture.agentId)
        try expect(supervisor.turnSnapshot(for: fixture.agentId)?.state == .working,
                   "the script witness must begin in a real working turn")
        pump(until: { tracker.jobs(for: fixture.agentId).contains { $0.ports.isEmpty && $0.pids.count == 2 } }, seconds: 15)
        guard let script = tracker.jobs(for: fixture.agentId).first(where: { $0.ports.isEmpty && $0.pids.count == 2 }) else {
            throw Failure(message: "a shell script with no port must appear while the agent works")
        }
        defer { _ = AgentProcessControl.terminate(script, grace: 0.2) }
        try expect(!script.detached && script.commandLine.contains("sleep 60"),
                   "the portless job must show the shell's running command; got \(script)")
        tile.layoutSubtreeIfNeeded()
        try expect(tile.qaBackgroundJobsChipValue == "1 running", "a portless script must show 1 running on the tile")
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "portless-tool", outcome: .completed, errorMessage: nil), to: fixture.agentId)
        supervisor.qaDeliver(.sessionStateChanged(.ready), to: fixture.agentId)
        _ = wait(until: { tile.qaTailStatusText.hasPrefix("Worked for") }, seconds: 3)
        let completedTail = tile.qaTailStatusText
        try expect(completedTail.hasPrefix("Worked for") && supervisor.turnPresence(for: fixture.agentId)?.phase.isTerminal == true,
                   "the reply must be completed while its script is still running; got \(completedTail)")
        try Data().write(to: scriptDirectory.appendingPathComponent("finish-agent"))
        try expect(scriptCLI.wait() == 0, "the completed reply's CLI must exit normally while its script keeps running")
        pump(until: { tracker.jobs(for: fixture.agentId).contains { $0.id == script.id && $0.detached } }, seconds: 8)
        guard let orphan = tracker.jobs(for: fixture.agentId).first(where: { $0.id == script.id && $0.detached }) else {
            throw Failure(message: "after reply and CLI completion the shell job must retain its identity and remain visible")
        }
        try expect(orphan.startedAt == script.startedAt && orphan.pids == script.pids,
                   "CLI completion must keep the shell, child and original elapsed-time origin")
        try expect(tile.qaBackgroundJobsChipValue == "1 running" && topBar.qaProcessesVisible,
                   "the completed agent's remaining script must stay visible on its tile and top bar")
        tile.showBackgroundProcesses(from: topBar.qaProcessesButton)
        guard let scriptPanel = tracker.panel.content, let scriptRow = scriptPanel.qaJobRows.first,
              scriptPanel.qaJobRows.count == 1, scriptRow.job.id == script.id else {
            throw Failure(message: "the completed agent's chip must expose its portless script in the details panel")
        }
        func rowMetadata() -> String? {
            scriptRow.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("pid ") }?.stringValue
        }
        guard let initialMetadata = rowMetadata() else { throw Failure(message: "the script row must display its PID and elapsed time") }
        try expect(initialMetadata.contains("pid \(script.rootPid)") && initialMetadata.contains("outlives the agent"),
                   "details must expose the script's PID and detached lifetime; got \(initialMetadata)")
        _ = wait(until: { rowMetadata() != initialMetadata }, seconds: 3)
        try expect(rowMetadata() != initialMetadata && scriptRow.job.startedAt == script.startedAt,
                   "the open panel's elapsed time must advance after the reply ends; stayed at \(initialMetadata)")
        try expect(tile.qaTailStatusText == completedTail,
                   "a background script's growing uptime must not rewrite the finished reply's work duration")
        guard let expandClick = NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: scriptRow.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0) else {
            throw Failure(message: "could not create the script row's expansion click")
        }
        scriptRow.mouseUp(with: expandClick)
        scriptRow.layoutSubtreeIfNeeded()
        try expect(scriptRow.isExpanded && scriptRow.subviews.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == script.commandLine && !$0.isHidden && $0.isSelectable
        }, "expanding a portless script must reveal its selectable command")
        scriptRow.stopButton.performClick(nil)
        _ = wait(until: { tracker.jobs(for: fixture.agentId).isEmpty && scriptPanel.qaJobRows.isEmpty }, seconds: 10)
        try expect(tracker.jobs(for: fixture.agentId).isEmpty && script.pids.allSatisfy {
            guard let start = script.startTimes[$0] else { return false }
            return !AgentProcessControl.isSameProcess($0, startedAt: start)
        }, "Stop must end the completed agent's shell script and its child")
        try expect(tile.qaBackgroundJobsChipValue == nil && !topBar.qaProcessesVisible,
                   "stopping the last portless script must clear the tile and top-bar indicators")
        tracker.panel.dismiss(animated: false)

        tile.detach()
        return "agent process tracker check passed: listed \(String(format: "%.2f", arrivalLag))s after eligible, dropped a killed job in \(String(format: "%.2f", exitLag))s, 3 jobs on ports \(ports), panel live, opened :\(port) beside the agent, Stop and Stop All ended \(pids.count) processes; portless shell survived reply and CLI completion, retained its clock, exposed command/PID/advancing uptime, and Stop ended shell and child"
    }
}
