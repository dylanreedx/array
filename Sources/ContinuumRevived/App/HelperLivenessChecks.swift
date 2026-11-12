import AppKit
import ContinuumRevivedCore

/// `.plans/116` part 20, liveness step — `--helper-liveness-check`.
///
/// Drives the production supervisor (the boot-mounted bench: a fake pi runner
/// for the lead and one helper, the production Claude runner against a
/// scripted CLI for the others) and the app's own `AgentProcessTracker`
/// scanning the real process table. A helper's "build" is a real process tree
/// started under a stand-in CLI tagged with the helper's id. The clock is the
/// watchdog's injected clock; the sweep is the watchdog's own sweep. The
/// stall-alert switch is the real Settings key in the bench's isolated suite.
///
/// Every section reports; the check fails once, with all of them.
@MainActor
enum HelperLivenessChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(condition(), message)
    }

    static func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "helper liveness check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-liveness")
        defer { bench.tearDown() }
        let claudeCLI = bench.binDir.appendingPathComponent("claude")
        try ManagedModeChecks.fakeClaude.write(to: claudeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeCLI.path)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready,
            models: [ManagedModeChecks.model], displayNames: [ManagedModeChecks.model: "Fixture"],
            contextWindows: [ManagedModeChecks.model: 200_000]))
        let supervisor = bench.supervisor, lead = bench.f.agentId
        let tracker = bench.f.delegate.agentProcessTracker
        try expect(supervisor.processTracker === tracker, "the boot mount must hand the supervisor the app's tracker")
        bench.f.delegate.wireCanvasCallbacks(bench.f.canvas)
        try bench.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: bench.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        bench.f.api.approvalHandler = { _ in .allowForSession }
        var now = Date()
        supervisor.helperWatchdogNow = { now }
        let settings = bench.settings
        func setSwitch(_ on: Bool) { settings.set(on, forKey: AgentManagedModeConfig.stallAlertsKey) }

        func delegate(from parent: AgentID, _ marker: String, harness: AgentHarness) throws -> AgentID {
            var payload: [String: Any] = ["task": "\(marker): check the ledger", "title": marker, "idempotencyKey": "liveness-\(marker)"]
            if harness == .claudeCode { payload["harness"] = harness.rawValue; payload["model"] = ManagedModeChecks.model }
            let reply = bench.f.api.dispatch(agentId: parent, requestId: "liveness-\(marker)", op: "agent.delegate", payload: payload)
            guard case let .result(result) = reply,
                  let id = result["childAgentId"]?.string.flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:)) else {
                throw WorkspaceAgentReportChecks.Failure(description: "\(marker): the delegation failed: \(reply)")
            }
            try expect(supervisor.records[id]?.parentAgentID == parent, "\(marker): the delegated child must name its parent")
            return id
        }
        // `pi` holds on HOLD until release.flag; the scripted claude until managed-release.
        let helper = try delegate(from: lead, "HOLD-liveness", harness: .pi)
        let finished = try delegate(from: lead, "finished-control", harness: .pi)
        let claude = try delegate(from: lead, "HOLD-claude", harness: .claudeCode)
        try expect(supervisor.records[claude]?.harness == .claudeCode, "the Claude helper runs \(String(describing: supervisor.records[claude]?.harness))")
        try expect(supervisor.send("HOLD-lead", to: lead), "the lead did not start")
        let started = await waitUntil(timeout: 20, pollInterval: 0.02) {
            supervisor.isRunning(helper) && supervisor.isRunning(claude) && supervisor.isRunning(lead) && !supervisor.isRunning(finished)
                && supervisor.records[finished]?.latestTerminalEvent != nil
        }
        try expect(started, "the working helpers and the finished control were not established")
        try await Task.sleep(nanoseconds: 200_000_000)
        let settled = await waitUntil(timeout: 10, pollInterval: 0.02) {
            supervisor.queuedMessages(for: lead).contains { $0.text.contains("finished-control") }
        }
        try expect(settled, "the finished control's completion never reached the lead's queue")
        tracker.start()
        defer { tracker.stop() }

        let cwd = URL(fileURLWithPath: supervisor.records[lead]!.cwd)
        func prompts() -> String { (try? String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        func state(_ id: AgentID) -> HelperLiveness? { supervisor.helperLiveness[id]?.state }
        func fact(_ id: AgentID) -> String { String(describing: supervisor.helperLiveness[id]) }
        func queue(_ id: AgentID) -> [String] { supervisor.queuedMessages(for: id).map(\.text) }
        func progress(_ id: AgentID) {
            supervisor.qaDeliver(.contentDelta(threadId: "liveness", turnId: "turn", streamKind: .assistant, delta: "progress"), to: id)
        }
        /// The helper's alerts in a queue, any wording.
        func alerts(about id: AgentID, in target: AgentID = lead) -> [String] {
            queue(target).filter { $0.lowercased().contains(id.rawValue.uuidString.lowercased())
                && ($0.contains("has shown no progress") || $0.contains("is stalled:") || $0.contains("is still waiting on")) }
        }
        var sweepNanos: [UInt64] = []
        func sweep() async throws {
            let t0 = DispatchTime.now().uptimeNanoseconds
            await supervisor.sweepHelperWatchdog()
            sweepNanos.append(DispatchTime.now().uptimeNanoseconds - t0)
            for id in [lead, helper, claude] { await supervisor.qaQueueWritesSettled(for: id) }
            try expect(state(finished) == .finished, "a finished helper read \(String(describing: state(finished)))")
            try expect(state(lead) == nil, "the lead, no one's helper, got a liveness fact")
        }
        func inspected(_ id: AgentID) throws -> String? {
            let reply = bench.f.api.dispatch(agentId: lead, requestId: UUID().uuidString, op: "agent.inspect",
                                             payload: ["agentId": id.rawValue.uuidString])
            guard case let .result(object) = reply else { throw WorkspaceAgentReportChecks.Failure(description: "agent.inspect failed: \(reply)") }
            return object["liveness"]?.object?["state"]?.string
        }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

        var builds = 0
        /// A stand-in build: a tool shell under a CLI tagged as `owner`,
        /// listed by the tracker once it is old enough.
        func startBuild(_ owner: AgentID, _ label: String) async throws -> ProcessGroupChild {
            builds += 1
            let directory = bench.f.tempRoot.appendingPathComponent("build-\(builds)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let before = Set(tracker.jobs(for: owner).map(\.id))
            let cli = try ProcessGroupChild.spawn(
                executable: me, arguments: [ProcessTrackingQAHelper.flag, "portless-agent", directory.path],
                environment: PiAgentRunner.childEnvironment(processOwner: AgentProcessAttribution.ownerTag(for: owner)),
                currentDirectory: nil, standardInput: .nullDevice)
            let listed = await waitUntil(timeout: 15, pollInterval: 0.02) { tracker.jobs(for: owner).contains { !before.contains($0.id) } }
            try expect(listed, "\(label): the tracker never listed the build")
            return cli
        }
        /// Every build of `owner` ends. The tool shell runs in a process group
        /// of its own, so its listed tree ends directly, then the stand-in CLI.
        func endBuilds(_ owner: AgentID, _ clis: [ProcessGroupChild], _ label: String) async throws {
            for pid in tracker.jobs(for: owner).flatMap(\.pids) { kill(pid, SIGKILL) }
            for cli in clis { cli.terminateGroup(graceSeconds: 0.2) }
            let gone = await waitUntil(timeout: 10, pollInterval: 0.02) { tracker.jobs(for: owner).isEmpty }
            try expect(gone, "\(label): the tracker kept the ended build: \(tracker.jobs(for: owner).map(\.label))")
        }
        func claudeRelease(_ id: AgentID) throws {
            let dir = URL(fileURLWithPath: supervisor.records[id]!.cwd)
            try Data().write(to: dir.appendingPathComponent("managed-release"))
        }
        /// The Claude helper's turn ends and a new one begins.
        func nextClaudeTurn(_ label: String) async throws {
            try claudeRelease(claude)
            let ended = await waitUntil(timeout: 15, pollInterval: 0.02) { !supervisor.isRunning(claude) }
            try expect(ended, "\(label): the Claude helper's turn did not end")
            try await Task.sleep(nanoseconds: 200_000_000)
            try expect(supervisor.send("HOLD-claude-\(label)", to: claude), "\(label): the Claude helper did not take a new turn")
            let back = await waitUntil(timeout: 15, pollInterval: 0.02) { supervisor.isRunning(claude) && supervisor.presenceRowStatus(for: claude) == .working }
            try expect(back, "\(label): the Claude helper's new turn never ran")
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        func section(_ name: String, _ body: () async throws -> Void) async {
            do { try await body() } catch { failures.append("\(name): \(error)") }
        }
        let todayAlertSuffix = "has shown no progress for 10 min (last: transcript grew). Check it, message it, or stop it."

        // 0. The evidence for `HelperLiveness.reasoningStreams`: the recorded
        // provider streams through their real translators.
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures", isDirectory: true)
        func lines(_ name: String) throws -> [String] {
            try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func reasoningDeltas(_ events: [AgentRuntimeEvent]) -> Int {
            events.filter { if case let .contentDelta(_, _, kind, delta) = $0 { return kind == .reasoning && !delta.isEmpty }; return false }.count
        }
        await section("reasoning evidence") {
            var claudeT = ClaudeEventTranslator(workingDirectory: cwd)
            let claudeEvents = claudeT.translate(stream: try lines("claude-websearch-turn.jsonl"))
            check(reasoningDeltas(claudeEvents) > 0, "claude: the recorded thinking produced no reasoning progress")
            var codexReasoningSteps = 0, codexDeltas = 0
            for name in ["codex-appserver-single-agent.jsonl", "codex-appserver-delegating-turn.jsonl",
                         "codex-appserver-delegating-websearch.jsonl", "codex-appserver-mcp-delegate.jsonl"] {
                let raw = try lines(name)
                codexReasoningSteps += raw.filter { line in
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          object["method"] as? String == "item/started",
                          let item = (object["params"] as? [String: Any])?["item"] as? [String: Any] else { return false }
                    return item["type"] as? String == "reasoning"
                }.count
                var codexT = CodexAppServerEventTranslator(workingDirectory: cwd)
                codexDeltas += reasoningDeltas(codexT.translate(stream: raw))
            }
            check(codexReasoningSteps > 0 && codexDeltas == 0,
                  "codex: \(codexReasoningSteps) recorded reasoning steps produced \(codexDeltas) progress events")
            var piThinking = 0, piDeltas = 0
            for name in ["pi-delegate-agent-turn.jsonl", "pi-delegate-run-events-live.jsonl", "pi-delegate-run-events.jsonl"] {
                let raw = try lines(name)
                piThinking += raw.filter { $0.contains("thinking_delta") }.count
                var piT = PiEventTranslator(workingDirectory: cwd)
                piDeltas += reasoningDeltas(piT.translate(stream: raw))
            }
            check(piThinking == 0 && piDeltas == 0, "pi: the recorded streams hold \(piThinking) thinking frames, \(piDeltas) progress events")
            check(HelperLiveness.reasoningStreams(for: .claudeCode) && !HelperLiveness.reasoningStreams(for: .codex)
                  && !HelperLiveness.reasoningStreams(for: .pi), "the reasoning table disagrees with the recorded streams")
        }

        // 1. Switch off, the real key: the lead's stream is today's. The same
        // timeline also runs with classification inert (an infinite quiet
        // threshold, as before the liveness step); the two must match.
        func offTimeline(classify: Bool) async throws -> [String] {
            let label = classify ? "off" : "off-inert"
            setSwitch(false)
            supervisor.helperLivenessQuietAfter = classify ? HelperLiveness.defaultQuietAfter : .infinity
            defer { supervisor.helperLivenessQuietAfter = HelperLiveness.defaultQuietAfter }
            progress(helper)
            progress(claude)
            let queueBefore = queue(lead), promptsBefore = prompts(), alertsBefore = alerts(about: claude).count
            await supervisor.sweepHelperWatchdog()
            now.addTimeInterval(60)
            progress(claude)
            let lastEvent = now
            now.addTimeInterval(90)
            try await sweep()
            let build = try await startBuild(claude, label)
            now = lastEvent.addingTimeInterval(150)
            try await sweep()
            if classify { check(state(claude) == .waitingOnChild, "\(label): silent with a live build: \(fact(claude))") }
            now = lastEvent.addingTimeInterval(300)
            try await sweep()
            try await endBuilds(claude, [build], label)
            now = lastEvent.addingTimeInterval(330)
            try await sweep()
            if classify {
                check(state(claude) == .stalled && supervisor.helperLiveness[claude]?.lastProgressAt == lastEvent,
                      "\(label): silent with nothing running: \(fact(claude))")
                check(try inspected(claude) == HelperLiveness.stalled.rawValue, "\(label): agent.inspect disagreed")
            }
            now = lastEvent.addingTimeInterval(599)
            try await sweep()
            check(alerts(about: claude).count == alertsBefore, "\(label): the lead heard before ten minutes")
            now = lastEvent.addingTimeInterval(601)
            try await sweep()
            now = lastEvent.addingTimeInterval(1800)
            try await sweep()
            check(supervisor.isRunning(claude) && supervisor.queuedMessages(for: claude).isEmpty && prompts() == promptsBefore,
                  "\(label): the helper was stopped or messaged")
            var gained = queue(lead)
            for text in queueBefore { if let i = gained.firstIndex(of: text) { gained.remove(at: i) } }
            progress(helper)
            progress(claude)
            return gained
        }
        await section("switch off") {
            let inert = try await offTimeline(classify: false)
            let off = try await offTimeline(classify: true)
            check(off.count == 2 && off.contains { $0.contains("Helper HOLD-claude: check the \(todayAlertSuffix)") }
                  && off.contains { $0.contains("Helper HOLD-liveness: check the \(todayAlertSuffix)") },
                  "switch off: expected today's one alert, got \(off)")
            check(off == inert, "switch off: the lead's stream differs from the inert run:\ninert \(inert)\noff   \(off)")
        }

        setSwitch(true)
        // 2. Tool calls, per harness: a real tool call from each provider's
        // recorded stream, through its real translator, delivered as the
        // helper's bound runner delivers its own events.
        func toolPair(_ events: [AgentRuntimeEvent], _ harness: String) throws -> (start: AgentRuntimeEvent, end: AgentRuntimeEvent, name: String) {
            for start in events {
                guard case let .itemStarted(_, item, kind, title) = start,
                      ![ItemKind.assistantMessage, .reasoning, .plan, .error, .compaction, .subagent].contains(kind) else { continue }
                if let end = events.first(where: { if case let .itemCompleted(_, id, _, _) = $0 { return id == item }; return false }) {
                    return (start, end, title?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
                }
            }
            throw WorkspaceAgentReportChecks.Failure(description: "\(harness): the fixture holds no closed tool call")
        }
        var claudeTranslator = ClaudeEventTranslator(workingDirectory: cwd)
        var codexTranslator = CodexAppServerEventTranslator(workingDirectory: cwd)
        let claudeCall = try toolPair(claudeTranslator.translate(stream: lines("claude-websearch-turn.jsonl")), "claude")
        let codexCall = try toolPair(codexTranslator.translate(stream: lines("codex-appserver-mcp-delegate.jsonl")), "codex")
        func restartClaude(_ label: String) async throws {
            guard !supervisor.isRunning(claude) else { return }
            try expect(supervisor.send("HOLD-claude-\(label)", to: claude), "\(label): the helper did not restart")
            let back = await waitUntil(timeout: 15, pollInterval: 0.02) { supervisor.isRunning(claude) }
            try expect(back, "\(label): the restarted helper never ran")
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        for (harness, call) in [("claude", claudeCall), ("codex", codexCall)] {
            await section("tool call \(harness)") {
                do {
                    progress(claude)
                    let t = now
                    try expect(supervisor.qaDeliverFromBoundRunner(call.start, to: claude), "no bound runner")
                    now = t.addingTimeInterval(150)
                    try await sweep()
                    check(state(claude) == .waitingOnToolCall && supervisor.helperLiveness[claude]?.openToolCalls == 1
                          && supervisor.helperLiveness[claude]?.detail == call.name,
                          "quiet with an open tool call \(call.name): \(fact(claude))")
                    try expect(supervisor.qaDeliverFromBoundRunner(call.end, to: claude), "the end found no runner")
                    check(state(claude) == .working, "the tool call's end left \(fact(claude))")
                    now = now.addingTimeInterval(150)
                    try await sweep()
                    check(state(claude) == .stalled, "quiet after the tool returned: \(fact(claude))")
                    // A call that never closes because the process died is
                    // closed by the process ending, not carried into the next turn.
                    progress(claude)
                    try expect(supervisor.qaDeliverFromBoundRunner(call.start, to: claude), "no runner for the second call")
                    now = now.addingTimeInterval(150)
                    try await sweep()
                    check(state(claude) == .waitingOnToolCall, "second open call: \(fact(claude))")
                    let host = getpid(), tag = AgentProcessAttribution.ownerTag(for: claude)
                    let runnerPids = ProcessTableReader().sample().filter { $0.ownerTag == tag && $0.parentPid == host }.map(\.pid)
                    try expect(!runnerPids.isEmpty, "the helper's runner process was not found")
                    for pid in runnerPids { kill(pid, SIGKILL) }
                    let died = await waitUntil(timeout: 15, pollInterval: 0.02) { !supervisor.isRunning(claude) }
                    try expect(died, "the helper outlived its killed process")
                    try await sweep()
                    check(state(claude) == .finished, "a helper whose process died: \(fact(claude))")
                    try await restartClaude(harness)
                    progress(claude)
                    now = now.addingTimeInterval(150)
                    try await sweep()
                    check(state(claude) == .stalled && supervisor.helperLiveness[claude]?.openToolCalls == 0,
                          "the dead process's tool call stayed open into the next turn: \(fact(claude))")
                } catch {
                    _ = supervisor.qaDeliverFromBoundRunner(call.end, to: claude)
                    try await restartClaude("\(harness)-recovery")
                    throw error
                }
            }
        }

        // 3. A long live build: switch on, no alert at ten minutes or twenty;
        // off, today's alert.
        await section("long build") {
            setSwitch(true)
            progress(claude)
            let t = now, before = alerts(about: claude).count
            let build = try await startBuild(claude, "long build")
            for offset in [150.0, 601.0, 1200.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            check(state(claude) == .waitingOnChild, "long build: \(fact(claude))")
            check(alerts(about: claude).count == before, "long build, switch on: the lead was alerted during a live build: \(alerts(about: claude).dropFirst(before))")
            setSwitch(false)
            now = t.addingTimeInterval(1201)
            try await sweep()
            let offAlerts = Array(alerts(about: claude).dropFirst(before))
            check(offAlerts.count == 1 && offAlerts[0].contains(todayAlertSuffix), "long build, switch off: today's alert did not arrive: \(offAlerts)")
            setSwitch(true)
            try await endBuilds(claude, [build], "long build")
            progress(claude)
        }

        // 4. Waiting has a ceiling that informs once: a forgotten process.
        await section("waiting ceiling, process") {
            progress(claude)
            let t = now, before = alerts(about: claude).count
            let build = try await startBuild(claude, "ceiling")
            let word = tracker.jobs(for: claude).first.flatMap { $0.label.split(whereSeparator: \.isWhitespace).first }
                .map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "?"
            now = t.addingTimeInterval(1799)
            try await sweep()
            check(alerts(about: claude).count == before, "ceiling: alerted before thirty minutes")
            now = t.addingTimeInterval(1800)
            try await sweep()
            for offset in [2400.0, 3600.0, 7200.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            let fired = Array(alerts(about: claude).dropFirst(before))
            check(fired.count == 1 && fired[0].contains("is still waiting on a process it started (\(word)) for 30 min"),
                  "ceiling: expected one 'still waiting on a process it started (\(word)) for 30 min', got \(fired)")
            check(supervisor.records[claude]?.helperWatchdogNeedsYou == "still waiting on a process for 30 min",
                  "ceiling: the helper's needs-you read \(String(describing: supervisor.records[claude]?.helperWatchdogNeedsYou))")
            try await endBuilds(claude, [build], "ceiling")
            progress(claude)
        }

        // 5. A lost tool end: the call stays open, the ceiling still informs once.
        await section("waiting ceiling, lost tool end") {
            progress(claude)
            let t = now, before = alerts(about: claude).count
            try expect(supervisor.qaDeliverFromBoundRunner(claudeCall.start, to: claude), "no bound runner")
            for offset in [150.0, 1799.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            check(state(claude) == .waitingOnToolCall, "lost end: \(fact(claude))")
            check(alerts(about: claude).count == before, "lost end: alerted before thirty minutes")
            for offset in [1800.0, 3600.0, 7200.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            let fired = Array(alerts(about: claude).dropFirst(before))
            check(fired.count == 1 && fired[0].contains("is still waiting on a tool call (\(claudeCall.name)) for 30 min"),
                  "lost end: expected one 'still waiting on a tool call (\(claudeCall.name)) for 30 min', got \(fired)")
            _ = supervisor.qaDeliverFromBoundRunner(claudeCall.end, to: claude)
            progress(claude)
        }

        // 6. Busy is never stalled: compaction and a provider retry wait.
        await section("busy") {
            progress(claude)
            var t = now, before = alerts(about: claude).count
            let running = AgentCompactionLifecycleEvent(phase: .running, trigger: .providerAutomatic, provider: "claude")
            try expect(supervisor.qaDeliverFromBoundRunner(.compactionChanged(threadId: "liveness", event: running), to: claude), "no bound runner")
            for offset in [150.0, 400.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            check(state(claude) == .busy && supervisor.helperLiveness[claude]?.detail == "compacting", "compacting: \(fact(claude))")
            check(alerts(about: claude).count == before, "compacting: the lead was told a compacting helper is stuck")
            var done = running
            done.phase = .succeeded
            _ = supervisor.qaDeliverFromBoundRunner(.compactionChanged(threadId: "liveness", event: done), to: claude)
            progress(claude)
            t = now; before = alerts(about: claude).count
            supervisor.qaObserveSharedTranscript(.providerRetry(.init(attempt: 2, maxAttempts: 5, delay: 30, observedAt: Date())), for: claude)
            for offset in [150.0, 400.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            check(state(claude) == .busy && supervisor.helperLiveness[claude]?.detail == "retrying", "retry wait: \(fact(claude))")
            check(alerts(about: claude).count == before, "retry wait: the lead was told a retrying helper is stuck")
            supervisor.qaObserveSharedTranscript(.providerRetry(nil), for: claude)
            progress(claude)
        }

        // 7. A model that reasons silently (Pi, Codex): not a stall; today's ten minutes.
        await section("silent model") {
            progress(helper)
            let t = now, before = alerts(about: helper).count
            for offset in [150.0, 400.0, 599.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            check(state(helper) == .waitingOnModel, "pi, quiet in an open turn: \(fact(helper))")
            check(alerts(about: helper).count == before, "pi: a silent model turn alerted before ten minutes: before \(before), now \(alerts(about: helper)), \(fact(helper)), needs-you \(String(describing: supervisor.records[helper]?.helperWatchdogNeedsYou))")
            now = t.addingTimeInterval(601)
            try await sweep()
            let fired = Array(alerts(about: helper).dropFirst(before))
            check(fired.count == 1 && fired[0].contains(todayAlertSuffix), "pi: expected today's ten-minute alert, got \(fired)")
            progress(helper)
        }

        // 8. A stall: quiet is measured from the last progress, and a flap
        // between stalled and waiting does not restart it. One alert per stall.
        await section("stall") {
            progress(claude)
            let t = now, before = alerts(about: claude).count
            now = t.addingTimeInterval(150)
            try await sweep()
            check(state(claude) == .stalled, "stall: \(fact(claude))")
            let build = try await startBuild(claude, "flap")
            now = t.addingTimeInterval(160)
            try await sweep()
            check(state(claude) == .waitingOnChild, "flap: a live build read \(fact(claude))")
            try await endBuilds(claude, [build], "flap")
            now = t.addingTimeInterval(170)
            try await sweep()
            check(state(claude) == .stalled, "flap: back to stalled read \(fact(claude))")
            now = t.addingTimeInterval(179)
            try await sweep()
            check(alerts(about: claude).count == before, "stall: alerted before three minutes of quiet")
            now = t.addingTimeInterval(180)
            try await sweep()
            let fired = Array(alerts(about: claude).dropFirst(before))
            let since = AgentSupervisor.stallClockText(t)
            check(fired.count == 1 && fired[0].contains("is stalled: no progress since \(since) (3 min)"),
                  "stall: expected one alert at three minutes of quiet since \(since), got \(fired)")
            check(supervisor.records[claude]?.helperWatchdogNeedsYou == "stalled, no progress for 3 min",
                  "stall: needs-you read \(String(describing: supervisor.records[claude]?.helperWatchdogNeedsYou))")
            for offset in [360.0, 601.0, 1200.0, 2400.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            check(alerts(about: claude).count == before + 1, "stall: one stall alerted \(alerts(about: claude).count - before) times")
            check(supervisor.isRunning(claude) && supervisor.queuedMessages(for: claude).isEmpty, "stall: the alert stopped or messaged the helper")

            // Recovery before the threshold: no alert.
            progress(claude)
            let r = now, recovered = alerts(about: claude).count
            check(recovered == before, "progress: the stale stall alert stayed in the lead's queue")
            now = r.addingTimeInterval(150)
            try await sweep()
            check(state(claude) == .stalled, "recovery: did not stall first: \(fact(claude))")
            now = r.addingTimeInterval(170)
            progress(claude)
            for offset in [200.0, 300.0, 330.0] as [TimeInterval] {
                now = r.addingTimeInterval(offset)
                try await sweep()
            }
            check(alerts(about: claude).count == recovered, "recovery: a helper that recovered before three minutes alerted its lead")
            progress(claude)
        }

        // 9. A dev server from an earlier turn does not hold the next one waiting.
        await section("earlier turn's process") {
            let server = try await startBuild(claude, "dev server")
            try await Task.sleep(nanoseconds: 2_200_000_000)
            try await nextClaudeTurn("next")
            check(!tracker.jobs(for: claude).isEmpty, "dev server: the tracker dropped the earlier turn's process")
            progress(claude)
            now = now.addingTimeInterval(150)
            try await sweep()
            check(state(claude) == .stalled && supervisor.helperLiveness[claude]?.liveChildren == 0,
                  "dev server: an earlier turn's process held the helper: \(fact(claude))")
            try await endBuilds(claude, [server], "dev server")
            progress(claude)
        }

        // 10a. A withdraw never comes back: not when another message joins the
        //      lead's queue before the withdraw reaches the store, and not when
        //      it lands while the alert itself is still being queued.
        await section("withdraw races") {
            progress(claude)
            let before = alerts(about: claude).count
            var t = now
            now = t.addingTimeInterval(180)
            try await sweep()
            check(alerts(about: claude).count == before + 1, "race: the stall alert was not queued")
            let gate = RemovalGate()
            supervisor.qaBeforeQueueRemoval = { await gate.wait() }
            progress(claude)
            supervisor.qaBeforeQueueRemoval = nil
            check(alerts(about: claude).count == before, "race: progress left the alert in the lead's queue")
            let other = await supervisor.accept(.queue(AgentPrompt("PLAIN another note for the lead")), for: lead)
            check(other == .accepted, "race: the other message was refused: \(other)")
            check(alerts(about: claude).count == before, "race: a message queued before the withdraw reached the store brought the alert back")
            await gate.release()
            await supervisor.qaQueueWritesSettled(for: lead)
            check(alerts(about: claude).count == before, "race: the alert came back once its removal landed")
            for note in supervisor.queuedMessages(for: lead) where note.text.contains("another note") {
                supervisor.cancelQueuedMessage(note.id, for: lead)
            }
            await supervisor.qaQueueWritesSettled(for: lead)

            progress(claude)
            t = now
            var withdrewInFlight = false
            supervisor.qaAfterQueueAdmission = {
                guard !withdrewInFlight else { return }
                withdrewInFlight = true
                progress(claude)
            }
            now = t.addingTimeInterval(180)
            try await sweep()
            supervisor.qaAfterQueueAdmission = nil
            check(withdrewInFlight, "in flight: the alert was never queued")
            check(alerts(about: claude).count == before, "in flight: an alert withdrawn while it was being queued stayed in the lead's queue")
            progress(claude)
        }

        // 10. A queued alert leaves the lead's queue when the helper finishes.
        await section("withdraw on finish") {
            progress(claude)
            let t = now, before = alerts(about: claude).count
            now = t.addingTimeInterval(180)
            try await sweep()
            check(alerts(about: claude).count == before + 1, "finish: the stall alert was not queued")
            try claudeRelease(claude)
            let ended = await waitUntil(timeout: 15, pollInterval: 0.02) { !supervisor.isRunning(claude) }
            try expect(ended, "finish: the Claude helper did not finish")
            try await sweep()
            check(alerts(about: claude).count == before, "finish: a finished helper's stall alert stayed queued for the lead")
        }

        // 11. A stalled sub-helper alerts the top lead once, not its waiting parent.
        await section("sub-helper chain") {
            let sub = try delegate(from: helper, "HOLD-sub", harness: .claudeCode)
            let up = await waitUntil(timeout: 15, pollInterval: 0.02) { supervisor.isRunning(sub) }
            try expect(up, "chain: the sub-helper never ran")
            try await Task.sleep(nanoseconds: 300_000_000)
            progress(helper)
            progress(sub)
            let t = now, before = alerts(about: sub).count, beforeMid = alerts(about: helper).count
            now = t.addingTimeInterval(150)
            try await sweep()
            check(state(helper) == .waitingOnHelper && state(sub) == .stalled, "chain: parent \(fact(helper)), sub \(fact(sub))")
            for offset in [180.0, 601.0, 1200.0, 2400.0] as [TimeInterval] {
                now = t.addingTimeInterval(offset)
                try await sweep()
            }
            let fired = Array(alerts(about: sub).dropFirst(before))
            check(fired.count == 1 && fired[0].contains("(a helper of HOLD-liveness: check") && fired[0].contains("is stalled:"),
                  "chain: the top lead expected one alert for the chain, got \(fired)")
            check(alerts(about: sub, in: helper).isEmpty, "chain: the alert queued behind the waiting parent's turn: \(alerts(about: sub, in: helper))")
            check(alerts(about: helper).count == beforeMid, "chain: the waiting parent alerted too: \(alerts(about: helper).dropFirst(beforeMid))")
        }
        setSwitch(false)

        // 12. Finished: release the scripted turns; a finished helper is never stalled.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && supervisor.records.keys.contains(where: { supervisor.isRunning($0) }) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            for id in supervisor.records.keys where supervisor.records[id]?.harness == .claudeCode && supervisor.isRunning(id) {
                try? claudeRelease(id)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(!supervisor.isRunning(helper) && !supervisor.isRunning(claude), "the scripted turns did not finish")
        try await sweep()
        now.addTimeInterval(3600)
        try await sweep()
        check(state(helper) == .finished && state(claude) == .finished, "finished helpers read \(fact(helper)) and \(fact(claude))")
        check(try inspected(helper) == HelperLiveness.finished.rawValue, "agent.inspect disagreed for a finished helper")
        try expect(failures.isEmpty, failures.joined(separator: "\n"))

        // Cost, printed and not asserted.
        let iterations = 200_000
        var tally = 0
        let base = Date()
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations {
            let state = HelperLiveness.classify(inTurn: i % 7 != 0, blocked: i % 11 == 0, busy: i % 13 == 0, lastProgressAt: base,
                                                subHelpers: i % 17 == 0 ? 1 : 0, liveChildren: i % 3, openToolCalls: i % 5 == 0 ? 1 : 0,
                                                modelSilent: i % 2 == 0, now: base.addingTimeInterval(Double(i % 300)), quietAfter: 120)
            tally &+= state == .stalled ? 1 : 0
        }
        let classifyNs = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(iterations)
        let sorted = sweepNanos.sorted()
        print(String(format: "helper-liveness timing: classify %.1f ns/call (%d calls, %d stalled); watchdog sweep median %.1f µs, max %.1f µs over %d sweeps",
                     classifyNs, iterations, tally, Double(sorted[sorted.count / 2]) / 1000, Double(sorted.last ?? 0) / 1000, sorted.count))
    }
}

/// Holds a queue removal until the check lets it go.
private actor RemovalGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
