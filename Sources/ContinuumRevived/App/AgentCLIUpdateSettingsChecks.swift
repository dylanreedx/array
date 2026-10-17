import AppKit
import ContinuumRevivedCore
import Foundation

/// `--cli-update-settings-check` — agent CLI updates as a person meets them:
/// Settings › Agents mounted offscreen, a center built on the PRODUCTION
/// classifier, version reader and update runner pointed at fake CLIs (shell
/// scripts in a temp dir), an injected latest-version fetcher, and a real
/// `AgentSupervisor` holding one idle and one running Claude agent.
///
/// Asserts: nothing is live in QA without injection; each row shows its version
/// and, when newer, "→ newer" with an Update button (or guidance when Array may
/// not run it); pressing Update streams output into the row and ends with the
/// verified result; idle sessions of that CLI stop while the running one is left
/// to finish and then retires; the opt-out switch suppresses checks; ⌘K offers
/// "Update <CLI>" only while an update is available; the version-change notice
/// fires once per change; and a finished sign-in terminal re-probes readiness.
@MainActor
enum AgentCLIUpdateSettingsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    final class FakeFetcher: AgentCLILatestVersionFetching, @unchecked Sendable {
        let lock = NSLock()
        var answers: [AgentCLILatestSource: String] = [:]
        var calls = 0
        func lookup(_ source: AgentCLILatestSource) async -> AgentCLILatestLookup {
            lock.withLock {
                calls += 1
                return answers[source].map(AgentCLILatestLookup.found) ?? .notFound
            }
        }
        var callCount: Int { lock.withLock { calls } }
    }

    static func run() throws {
        let standardGuard = QAStandardDefaultsGuard(keys: Set([AgentCLIUpdateConfig.checksEnabledKey]
            + AgentHarness.allCases.map { AgentCLIUpdateCenter.lastSeenVersionKeyPrefix + $0.rawValue }))
        // 1. Inert without injection. The shared center is what the app ships,
        // and in any check it must neither spawn nor fetch, whatever is called.
        let shared = AgentCLIUpdateCenter.shared
        shared.enableLive()
        try expect(!shared.isActive, "the shared center went live inside a check")
        let inertDone = Box(false)
        Task { await shared.refresh(force: true); inertDone.value = true }
        shared.update(.claudeCode)
        let inertDeadline = Date().addingTimeInterval(2)
        while !inertDone.value && Date() < inertDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try expect(shared.statuses.isEmpty, "the inert center recorded state: \(shared.statuses)")
        try expect(AppDelegate().cliUpdatePaletteActions().isEmpty, "⌘K must offer no CLI rows while the center is inert")
        let app = URL(fileURLWithPath: "/Applications/Array.app")
        try expect(AgentCLIUpdateCenter.livePermitted(environment: [:], arguments: ["Array"], bundleURL: app),
                   "a plain launch of the real bundle may go live")
        try expect(!AgentCLIUpdateCenter.livePermitted(environment: [:], arguments: ["Array"], bundleURL: URL(fileURLWithPath: "/tmp/.build/debug")),
                   "a bare binary must stay inert")
        for key in ["CONTINUUM_APP_SUPPORT", "CONTINUUM_SMOKE_TEST", "CONTINUUM_QA_FLOW", "CONTINUUM_COMPONENT_SNAPSHOT"] {
            try expect(!AgentCLIUpdateCenter.livePermitted(environment: [key: "1"], arguments: ["Array"], bundleURL: app),
                       "\(key) must keep the center inert")
        }
        try expect(!AgentCLIUpdateCenter.livePermitted(environment: [:], arguments: ["Array", "--settings-panel-check"], bundleURL: app),
                   "a --*-check launch must keep the center inert")

        // 2. Fake CLIs laid out like real installs.
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("cli-settings-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let root = AgentCLIFileSystem.live.realPath(scratch.path)
        let suite = "continuum.cliUpdates.check.\(UUID().uuidString)"
        guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else { throw Failure(description: "no isolated defaults") }
        var teardown: [() -> Void] = [{ defaults.removePersistentDomain(forName: suite) },
                                      { try? fileManager.removeItem(at: scratch) }]
        defer { teardown.reversed().forEach { $0() } }

        func write(_ path: String, _ text: String, executable: Bool = false) throws {
            try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fileManager.createFile(atPath: path, contents: Data(text.utf8))
            if executable { chmod(path, 0o755) }
        }
        // Claude: native installer. `update` streams, pauses so the row can be
        // seen running, then moves the version.
        let claudeState = root + "/claude-state"
        try write(claudeState + "/version", "2.1.302\n")
        let claudeBinary = root + "/home/.local/share/claude/versions/2.1.302"
        try write(claudeBinary, """
            #!/bin/sh
            S='\(claudeState)'
            case "$1" in
              --version) printf '%s (Claude Code)\\n' "$(cat "$S/version")" ;;
              update)
                echo 'Checking for updates...'
                echo 'Downloading Claude Code 2.1.305'
                sleep 0.8
                echo '2.1.305' > "$S/version"
                echo 'Successfully updated to 2.1.305'
                ;;
            esac
            """, executable: true)
        let claudeLink = root + "/home/.local/bin/claude"
        try fileManager.createDirectory(atPath: root + "/home/.local/bin", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: claudeLink, withDestinationPath: claudeBinary)
        // Codex: nvm npm, already current.
        let prefix = root + "/nvm/versions/node/v22.22.2"
        try write(prefix + "/lib/node_modules/@openai/codex/bin/codex.js", "#!/bin/sh\necho 'codex-cli 0.159.3'\n", executable: true)
        try write(prefix + "/bin/npm", "#!/bin/sh\nexit 0\n", executable: true)
        try fileManager.createSymbolicLink(atPath: prefix + "/bin/codex", withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        // Pi: a hand-placed binary Array cannot attribute — newer exists, no button.
        let piBinary = root + "/custom/bin/pi"
        try write(piBinary, "#!/bin/sh\necho '0.85.0'\n", executable: true)

        let paths: [AgentHarness: String] = [.claudeCode: claudeLink, .codex: prefix + "/bin/codex", .pi: piBinary]
        let fetcher = FakeFetcher()
        fetcher.answers = [.npm(package: "@anthropic-ai/claude-code"): "2.1.305",
                           .npm(package: "@openai/codex"): "0.159.3",
                           .piRelease: "0.86.0"]
        var notices: [String] = []
        var readinessRefreshes = 0
        let center = AgentCLIUpdateCenter(
            dependencies: .init(
                resolvedPath: { paths[$0] },
                fileSystem: .live,
                readVersion: { AgentCLIProcess.readVersion(executable: $0.resolvedPath) },
                fetcher: fetcher,
                makeRunner: { AgentCLIUpdateRunner(resolvePlan: $0) },
                environment: [:],
                testedVersions: [.claudeCode: "2.1.300", .codex: "0.159.3", .pi: "0.85.0"],
                deliverNotice: { notices.append($0) },
                refreshReadiness: { readinessRefreshes += 1 }),
            defaults: defaults)
        // Claude was last seen at 2.1.300: this probe finds it self-updated.
        defaults.set("2.1.300", forKey: AgentCLIUpdateCenter.lastSeenVersionKeyPrefix + AgentHarness.claudeCode.rawValue)

        // 3. A real supervisor: one IDLE claude agent (a persistent session whose
        // turn finished) and one RUNNING claude agent (a turn held open).
        let catalogBefore = AgentModelCatalog.shared.snapshot(for: .claudeCode)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        teardown.append { AgentModelCatalog.shared.resetForQA(snapshot: catalogBefore) }
        guard let model = AgentCatalogQAFixture.claude.seedModel else { throw Failure(description: "no claude fixture model") }
        let idleRunner = ScriptedAgentRunner(script: [
            .turnStarted(threadId: "idle", turnId: "t1"),
            .turnCompleted(threadId: "idle", turnId: "t1", outcome: .completed, errorMessage: nil),
        ], persistentBetweenTurns: true)
        let busyRunner = ScriptedAgentRunner(script: [.turnStarted(threadId: "busy", turnId: "t1")],
                                             holdUntilStopped: true, releaseOnStop: false, persistentBetweenTurns: true)
        final class Queue: @unchecked Sendable { var runners: [ScriptedAgentRunner] = [] }
        let queue = Queue()
        queue.runners = [idleRunner, busyRunner]
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: scratch.appendingPathComponent("agents", isDirectory: true)),
            makeRunner: { _ in queue.runners.isEmpty ? ScriptedAgentRunner(script: []) : queue.runners.removeFirst() })
        teardown.append { busyRunner.releaseRunAfterStop(); supervisor.stopAll() }
        let idleAgent = supervisor.spawn(role: "idle", prompt: nil, cwd: scratch, harness: .claudeCode, model: model, thinking: "medium")
        let busyAgent = supervisor.spawn(role: "busy", prompt: nil, cwd: scratch, harness: .claudeCode, model: model, thinking: "medium")
        try expect(supervisor.send("first", to: idleAgent), "the idle agent's prompt was refused: \(supervisor.sendRefusal(for: idleAgent) ?? "?")")

        let delegate = AppDelegate()
        delegate.qaSettingsDefaults = defaults
        delegate.agentSupervisor = supervisor
        delegate.cliUpdateCenter = center

        let settings = SettingsModel(defaults: defaults, navKeymap: .default)
        settings.cliUpdates = center
        let fixture = SettingsFixtureWindow(model: settings, size: NSSize(width: 1_100, height: 1_200))
        teardown.append { fixture.tearDown() }
        fixture.show(paneID: "agents")

        func waitFor(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { throw Failure(description: "timed out waiting for \(what)") }
                fixture.settle(0.03)
            }
        }
        try waitFor("the idle agent to pool its session") { idleRunner.completedRuns == 1 && supervisor.qaHasIdleSession(idleAgent) }
        try expect(supervisor.send("work", to: busyAgent), "the busy agent's prompt was refused: \(supervisor.sendRefusal(for: busyAgent) ?? "?")")
        try waitFor("the busy agent to be mid-turn") { busyRunner.runCount == 1 && supervisor.isRunning(busyAgent) }

        func refresh(force: Bool = false) throws {
            let done = Box(false)
            Task { await center.refresh(force: force); done.value = true }
            try waitFor("a refresh") { done.value }
            fixture.settle(0.1)
        }
        try expect(rendered("cliUpdate.version.Claude Code", in: fixture) == nil, "no version may show before a probe")
        try refresh()

        // 4. The version-change notice: once, with the tested version.
        try expect(notices == ["Claude Code updated to 2.1.302 · tested with 2.1.300"], "version notice: \(notices)")
        try refresh()
        try expect(notices.count == 1, "the same version must not be announced twice: \(notices)")

        // 5. The rows, as rendered.
        try expect(rendered("cliUpdate.version.Claude Code", in: fixture) == "2.1.302 → 2.1.305",
                   "claude row must read '2.1.302 → 2.1.305'; reads \(rendered("cliUpdate.version.Claude Code", in: fixture) ?? "nothing"); status \(center.status(.claudeCode))")
        try expect(rendered("cliUpdate.button.Claude Code", in: fixture) != nil, "claude row must offer Update")
        try expect(rendered("cliUpdate.version.Codex", in: fixture) == "0.159.3" && rendered("cliUpdate.button.Codex", in: fixture) == nil,
                   "codex is current: its version and no button; reads \(rendered("cliUpdate.version.Codex", in: fixture) ?? "nothing")")
        try expect(rendered("cliUpdate.version.Pi", in: fixture) == "0.85.0 → 0.86.0" && rendered("cliUpdate.button.Pi", in: fixture) == nil,
                   "pi has a newer release but no command Array may run: no button")
        try expect(rendered("cliUpdate.guidance.Pi", in: fixture) != nil, "pi's row must say what to do instead")

        // 6. ⌘K offers exactly what is updatable, through the app's own row builder.
        try expect(delegate.cliUpdatePaletteActions() == [.updateAgentCLI(.claudeCode), .checkAgentCLIUpdates],
                   "⌘K CLI rows: \(delegate.cliUpdatePaletteActions())")
        let rows = LaunchPaletteModel.makeRows(profiles: [], contextualActions: delegate.cliUpdatePaletteActions())
        try expect(LaunchPaletteModel.filterRows(rows, query: "update claude").contains { $0.displayName == "Update Claude Code" },
                   "⌘K 'update claude' must find Update Claude Code")

        // 7. Press Update in the row: output streams in, then the verified result.
        if let row = settings.entries().first(where: { $0.anchor == "harness.Claude Code" }) { settings.reveal(row) }
        fixture.settle(0.3)
        try click("cliUpdate.button.Claude Code", in: fixture)
        try waitFor("streamed output in the row") {
            (rendered("cliUpdate.log.Claude Code", in: fixture) ?? "").contains("Downloading Claude Code 2.1.305")
        }
        try expect(rendered("cliUpdate.spinner.Claude Code", in: fixture) == "Updating…" && rendered("cliUpdate.button.Claude Code", in: fixture) == nil,
                   "while it runs the row shows the spinner, not the button")
        try expect(center.status(.claudeCode).isRunning && delegate.cliUpdatePaletteActions() == [.checkAgentCLIUpdates],
                   "while it runs the row is busy and ⌘K stops offering it")
        try waitFor("the result line") { rendered("cliUpdate.result.Claude Code", in: fixture) != nil }
        try expect(rendered("cliUpdate.result.Claude Code", in: fixture) == "Updated to 2.1.305",
                   "result line: \(rendered("cliUpdate.result.Claude Code", in: fixture) ?? "nothing")")
        try expect(readinessRefreshes >= 1, "a finished update must re-probe readiness")
        // Sessions: the idle one stopped exactly as the reaper would; the running
        // turn untouched, told, and retired when it ends.
        try expect(idleRunner.stopCount == 1 && !supervisor.qaHasIdleSession(idleAgent),
                   "the idle claude session must be stopped; stops \(idleRunner.stopCount)")
        try expect(busyRunner.stopCount == 0 && supervisor.isRunning(busyAgent), "the running claude turn must be left alone")
        try expect(supervisor.qaArrayOwnedNoticeCount(for: busyAgent) == 1, "the running agent must be told a restart picks up 2.1.305")
        busyRunner.releaseRunAfterStop()
        try waitFor("the busy turn to end") { busyRunner.completedRuns == 1 && !supervisor.isRunning(busyAgent) }
        fixture.settle(0.1)
        try expect(busyRunner.stopCount == 1 && !supervisor.qaHasIdleSession(busyAgent),
                   "when its turn ends, the old-binary session must retire instead of pooling")
        try expect(delegate.cliUpdatePaletteActions() == [.checkAgentCLIUpdates], "nothing left to update: ⌘K offers only the check")
        // Array made this change: no notice for it.
        try refresh()
        try expect(notices.count == 1 && rendered("cliUpdate.version.Claude Code", in: fixture) == "2.1.305",
                   "after the update: notices \(notices), version \(rendered("cliUpdate.version.Claude Code", in: fixture) ?? "nothing")")

        // 8. The opt-out switch, written through the Settings row's own binding.
        guard let toggle = settings.sections.flatMap({ $0.groups.flatMap(\.rows) })
            .first(where: { $0.field.key == AgentCLIUpdateConfig.checksEnabledKey }) else {
            throw Failure(description: "Settings has no 'Check for agent CLI updates' row")
        }
        try expect(settings.renderedAnchors[SettingsRegistry.anchor(for: toggle.field) ?? ""] != nil, "the opt-out switch must render in Agents")
        settings.binding(for: toggle.field).set(.bool(false))
        let callsBefore = fetcher.callCount
        try refresh()
        try expect(fetcher.callCount == callsBefore, "with checks off, a refresh must not look up latest versions (\(fetcher.callCount - callsBefore) lookups)")
        try refresh(force: true)
        try expect(fetcher.callCount > callsBefore, "⌘K 'Check for CLI Updates' still checks when asked")
        settings.binding(for: toggle.field).set(.bool(true))

        // 9. A sign-in terminal that exits re-probes readiness, chained after the
        // exit handling the install already wired.
        let ghostty = try GhosttyRuntimeContext()
        let runtime = GhosttyTerminalRuntime(
            tileId: UUID(), title: "sign-in",
            launchProfile: LaunchProfile(command: "/usr/bin/true", arguments: [], cwd: root, title: "sign-in"),
            ghostty: ghostty)
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        fixture.window.contentView?.addSubview(host, positioned: .below, relativeTo: nil)
        teardown.append { runtime.terminate(policy: .force); host.detachRuntime(); host.removeFromSuperview() }
        let installHandler = Box(false)
        runtime.onRuntimeExited = { _, _ in installHandler.value = true }
        let refreshesBefore = readinessRefreshes
        delegate.wireAgentCLISignInCompletion(runtime, harness: .codex)
        host.attach(runtime: runtime)
        try waitFor("the sign-in process to exit", timeout: 10) { readinessRefreshes > refreshesBefore }
        try expect(installHandler.value, "the install's own exit handler must still run")

        let touched = standardGuard.finish()
        try expect(touched.isEmpty, "CLI updates wrote the standard defaults domain: \(touched)")
        print("cli-update-settings: version rows, Update streams and verifies, sessions handled, opt-out, ⌘K, notice once, sign-in re-probe; inert without injection")
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - The rendered rows, through the Settings census

    /// The words a row element rendered (`SettingsModel.renderedTexts`), or nil
    /// when that element is not on screen.
    private static func rendered(_ identifier: String, in fixture: SettingsFixtureWindow) -> String? {
        fixture.model.renderedTexts[identifier]
    }

    /// A real left click on a rendered element: its frame from the pane's own
    /// frame census, converted from the pane's viewport (the Form's scroll view)
    /// into the window, delivered through `NSWindow.sendEvent`.
    private static func click(_ identifier: String, in fixture: SettingsFixtureWindow) throws {
        guard let frame = fixture.model.anchorFrames[identifier] else {
            throw Failure(description: "\(identifier) has no rendered frame")
        }
        let viewport = fixture.model.viewportSize
        guard let pane = fixture.descendants(NSScrollView.self).first(where: {
            abs($0.frame.width - viewport.width) < 1 && abs($0.frame.height - viewport.height) < 1
        }) else {
            throw Failure(description: "no scroll view matches the pane viewport \(viewport)")
        }
        try expect(frame.minY >= 0 && frame.maxY <= viewport.height, "\(identifier) is outside the pane viewport: \(frame)")
        let local = NSPoint(x: frame.midX, y: pane.isFlipped ? frame.midY : pane.bounds.height - frame.midY)
        let point = pane.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure(description: "could not synthesize a click")
            }
            fixture.window.sendEvent(event)
        }
        fixture.settle(0.05)
    }
}
