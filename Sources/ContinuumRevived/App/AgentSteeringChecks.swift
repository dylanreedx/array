import ContinuumRevivedCore
import Darwin
import Foundation

// T5 (`.plans/69`) — the supervisor half of steering. Every scenario drives
// `AgentSupervisor.accept(...)` / `stop` / the queue API with the PRODUCTION
// runner factory (`AgentSupervisor.productionRunner`), so the Claude, Codex and
// Pi runners bound here are the ones the app binds; `AgentSteeringQAFakes`
// stands in for each CLI on PATH and records exactly what reached it. Runs as
// part of `--agent-compaction-ui-check`.
@MainActor
func runAgentSteeringChecks(waitInputOnly: Bool = false, helperCompletionOnly: Bool = false) async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: "steering: " + message) }
    }
    func eventually(_ message: String, timeout: TimeInterval = 8, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "steering: " + message)
    }

    final class Harness {
        let root: URL
        let bin: URL
        let supervisor: AgentSupervisor
        let id: AgentID
        var echoes: [String] = []
        var events: [AgentRuntimeEvent] = []
        var eventTask: Task<Void, Never>?

        @MainActor
        init(_ kind: AgentSteeringQAFakes.Harness, idleTimeout: TimeInterval = AgentSupervisor.defaultIdleRunnerTimeout) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("array-steering-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            try AgentSteeringQAFakes.install(kind, in: bin)
            let work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0),
                idleRunnerTimeout: idleTimeout)
            supervisor.interruptGrace = 3
            let (harness, model): (AgentHarness, String) = switch kind {
            case .claude: (.claudeCode, "anthropic/claude-haiku-4-5-20251001")
            case .codex: (.codex, "openai-codex/gpt-5.6-sol")
            case .pi: (.pi, "openai-codex/gpt-5.6-sol")
            }
            id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: model, thinking: "low")
            supervisor.addPromptEchoObserver(for: id) { [weak self] prompt in self?.echoes.append(prompt.text) }
            let stream = supervisor.events(for: id)
            eventTask = Task { @MainActor [weak self] in
                for await event in stream { self?.events.append(event) }
            }
        }

        var frames: [[String: Any]] { AgentSteeringQAFakes.receivedFrames(in: bin) }
        var spawns: Int { AgentSteeringQAFakes.spawnCount(in: bin) }
        /// The prompts the provider was asked to run, in order, whatever the wire.
        var promptTexts: [String] {
            frames.compactMap { frame in
                if frame["type"] as? String == "prompt" { return frame["message"] as? String }
                if frame["method"] as? String == "turn/start" {
                    return ((frame["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String
                }
                if frame["type"] as? String == "user", let message = frame["message"] as? [String: Any] {
                    return message["content"] as? String
                }
                return nil
            }
        }
        var completedTurns: [TurnOutcome] {
            events.compactMap { if case let .turnCompleted(_, _, outcome, _) = $0 { return outcome } else { return nil } }
        }

        @MainActor
        func tearDown() {
            supervisor.stopAll()
            eventTask?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
    }

    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let originalCodexTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
    setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
    defer {
        setenv("PATH", originalPath, 1)
        if let originalCodexTransport { setenv("CONTINUUM_CODEX_TRANSPORT", originalCodexTransport, 1) }
        else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
    }
    func onPath(_ harness: Harness) { setenv("PATH", "\(harness.bin.path):\(originalPath)", 1) }

    // Card7: use production runners, offline CLIs and the production helper
    // journal/flush. A boundary must consume the attributed result in this turn.
    if helperCompletionOnly {
        var failures: [String] = []
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let h = try Harness(kind)
            defer { h.tearDown() }
            onPath(h)
            h.supervisor.helperCompletionEnabled = { _ in true }
            _ = h.supervisor.setWorkspaceToolsEnabled(agentID: h.id, true)
            try expect(h.supervisor.send("TOOL text", to: h.id), "helper seed refused")
            try await eventually("helper lead must reach tool boundary") {
                h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true
                    && h.events.contains { if case .itemStarted(_, _, .commandExecution, _) = $0 { return true }; return false }
            }
            let helper = UUID(), wake = UUID()
            let cwd = h.supervisor.records[h.id]!.cwd
            let text = "Fixture helper finished: succeeded\nCard7 plain helper result"
            let delivery = SpawnResultFile.Delivery(helper: helper, turn: "card7-fixture",
                recipient: h.id.rawValue, wakeID: wake, text: text, now: Date())
            try SpawnResultFile.saveDelivery(delivery, parentCwd: cwd)
            await h.supervisor.flushHelperCompletions()
            try await Task.sleep(for: .milliseconds(250))
            let sameTurn = h.frames.contains { frame in
                if kind == .codex {
                    guard frame["method"] as? String == "turn/steer",
                          let params = frame["params"] as? [String: Any] else { return false }
                    return ((params["input"] as? [[String: Any]])?.first?["text"] as? String)?.contains(text) == true
                }
                if kind == .pi { return frame["type"] as? String == "steer" && (frame["message"] as? String)?.contains(text) == true }
                return frame["type"] as? String == "user"
                    && ((frame["message"] as? [String: Any])?["content"] as? String)?.contains(text) == true
            }
            let passed = sameTurn && h.promptTexts.count == (kind == .claude ? 2 : 1) && h.completedTurns.count <= 1
            print("card7 busy \(kind): same-turn steer=\(sameTurn), completed=\(h.completedTurns.count), prompts=\(h.promptTexts.count), queued=\(h.supervisor.queuedMessages(for: h.id).count)")
            if !passed { failures.append("\(kind): helper result did not enter current turn") }
            if passed {
                try await eventually("\(kind): helper result applied in current turn") {
                    h.echoes.contains { $0.contains(text) } && !h.supervisor.isRunning(h.id)
                }
                try expect(h.completedTurns == [.completed] && h.promptTexts.count == (kind == .claude ? 2 : 1),
                    "\(kind): helper result created an extra turn")
                switch AgentMessageEnvelope.classify(h.echoes.first { $0.contains(text) }!) {
                case .agentMessage(let m): try expect(m.senderAgentID == helper && m.text == text, "helper attribution/plain text changed")
                case .agentMessages(let ms): try expect(ms.count == 1 && ms[0].senderAgentID == helper && ms[0].text == text, "helper attribution/plain text changed")
                default: throw Failure(description: "helper result envelope missing")
                }
            }
        }
        // The fake CLIs separate acknowledgment from sampling at a boundary.
        // HOLD keeps the command open; Stop arrives before sampling the steer.
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let h = try Harness(kind)
            defer { h.tearDown() }
            onPath(h)
            try expect(h.supervisor.send(kind == .pi ? "SLOW text" : "HOLD text", to: h.id), "receipt seed refused")
            try await eventually("receipt lead must reach command") {
                h.events.contains { if case .itemStarted = $0 { return true }; return false }
            }
            try expect(await h.supervisor.accept(.steer(AgentPrompt("Card7 unsampled helper result")), for: h.id) == .accepted,
                "receipt steer refused")
            try await eventually("receipt reaches native handoff") {
                h.frames.contains { frame in
                    kind == .codex ? frame["method"] as? String == "turn/steer"
                        : kind == .pi ? frame["type"] as? String == "steer"
                        : frame["type"] as? String == "user" && ((frame["message"] as? [String: Any])?["content"] as? String) == "Card7 unsampled helper result"
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            let premature = !h.echoes.isEmpty
            h.supervisor.stop(h.id)
            try await eventually("receipt Stop must settle") { !h.supervisor.isRunning(h.id) }
            try await Task.sleep(for: .milliseconds(250))
            let retained = h.supervisor.pendingSteers(for: h.id).contains { $0.text == "Card7 unsampled helper result" }
            print("card7 receipt \(kind): premature-consumed=\(premature), retained-after-stop=\(retained)")
            if premature || !retained { failures.append("\(kind): acknowledged but unsampled input was marked consumed/lost after Stop") }
        }
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let h = try Harness(kind)
            defer { h.tearDown() }
            onPath(h)
            h.supervisor.helperCompletionEnabled = { _ in true }
            _ = h.supervisor.setWorkspaceToolsEnabled(agentID: h.id, true)
            try expect(h.supervisor.send("PLAIN text", to: h.id), "fallback seed refused")
            try await eventually("fallback turn bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
            let helper = UUID(), wake = UUID(), text = "Fallback helper finished: succeeded\nplain result"
            let cwd = h.supervisor.records[h.id]!.cwd
            try SpawnResultFile.saveDelivery(.init(helper: helper, turn: "fallback-turn", recipient: h.id.rawValue,
                wakeID: wake, text: text, now: Date()), parentCwd: cwd)
            await h.supervisor.flushHelperCompletions()
            await h.supervisor.flushHelperCompletions()
            try await eventually("\(kind): one next-turn fallback", timeout: 10) {
                h.completedTurns.count == 2 && !h.supervisor.isRunning(h.id)
                    && h.supervisor.pendingSteers(for: h.id).isEmpty && h.supervisor.queuedMessages(for: h.id).isEmpty
            }
            try expect(h.promptTexts.count == 2 && h.promptTexts[1].contains(text), "fallback lost or duplicated result")
            let state = try SpawnResultFile.delivery(parentCwd: cwd, helper: helper, turn: "fallback-turn", recipient: h.id.rawValue)
            try expect(state?.wakeID == wake && state?.phase == .delivered, "fallback changed durable identity")
            print("card7 fallback \(kind): two total turns, one result, stable wake ID PASS")
        }
        // Missing acknowledgment with an application item settles once;
        // missing application evidence is visibly held instead of auto-replayed.
        for missingReceipt in [false, true] {
            let h = try Harness(.codex)
            defer { h.tearDown() }
            onPath(h)
            try Data().write(to: h.bin.appendingPathComponent(missingReceipt ? "suppress-steer-receipts" : "drop-steer-ack"))
            try expect(h.supervisor.send("TOOL text", to: h.id), "lost receipt seed refused")
            try await eventually("lost receipt bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
            try expect(await h.supervisor.accept(.steer(AgentPrompt("receipt probe")), for: h.id) == .accepted, "receipt probe refused")
            // A consumed steer is shown at its receipt, before the durable write
            // that retires its custody; wait for both before asserting either.
            try await eventually("lost receipt settles", timeout: 12) {
                !h.supervisor.isRunning(h.id) && (missingReceipt ? h.supervisor.pendingSteers(for: h.id).map(\.state) == [.held]
                    : h.echoes == ["receipt probe"] && h.supervisor.pendingSteers(for: h.id).isEmpty)
            }
            try expect(h.completedTurns.count == 1 && h.promptTexts.count == 1, "lost receipt silently replayed work")
            if missingReceipt {
                try expect(h.echoes.isEmpty && h.supervisor.queueRailState(for: h.id).pause != nil, "unknown application was reported consumed")
            } else { try expect(h.supervisor.pendingSteers(for: h.id).isEmpty, "applied receipt did not release custody") }
            print("card7 Codex \(missingReceipt ? "missing application held" : "lost acknowledgment correlated") PASS")
        }
        for collectionFirst in [true, false] {
            let h = try Harness(.codex)
            defer { h.tearDown() }
            onPath(h)
            h.supervisor.helperCompletionEnabled = { _ in true }
            _ = h.supervisor.setWorkspaceToolsEnabled(agentID: h.id, true)
            try expect(h.supervisor.send("SLOW text", to: h.id), "race seed refused")
            try await eventually("race boundary") { h.events.contains { if case .itemStarted = $0 { return true }; return false } }
            let helper = UUID(), wake = UUID(), cwd = h.supervisor.records[h.id]!.cwd
            let courier = SpawnResultFile(toolCallId: "card7-race", status: .completed, agentId: helper,
                finalText: "race result", turnIdentity: "race-turn", recipientId: h.id.rawValue)
            var state = SpawnResultFile.Delivery(helper: helper, turn: "race-turn", recipient: h.id.rawValue,
                wakeID: wake, text: "Race helper finished: succeeded\nrace result", now: Date())
            state.result = courier
            try SpawnResultFile.saveDelivery(state, parentCwd: cwd)
            if collectionFirst {
                let offered = try SpawnResultFile.collect(parentCwd: cwd, handle: "card7-race", recipient: h.id.rawValue,
                    requestId: "race-offer", snapshot: courier)!
                await h.supervisor.flushHelperCompletions()
                try expect(!h.frames.contains { $0["method"] as? String == "turn/steer" }, "offered collection also steered")
                _ = try SpawnResultFile.collect(parentCwd: cwd, handle: "card7-race", recipient: h.id.rawValue,
                    requestId: "race-ack", receipt: offered.deliveryReceipt, acknowledge: true, snapshot: courier)
                await h.supervisor.flushHelperCompletions()
                try expect(h.supervisor.pendingSteers(for: h.id).isEmpty && h.supervisor.queuedMessages(for: h.id).isEmpty,
                    "acknowledged collection was queued again")
            } else {
                var duringAdmission: SpawnResultFile.Status?
                h.supervisor.qaBeforeHelperWakeAdmission = {
                    duringAdmission = try SpawnResultFile.collect(parentCwd: cwd, handle: "card7-race", recipient: h.id.rawValue,
                        requestId: "race-during-stage", snapshot: courier)?.status
                }
                await h.supervisor.flushHelperCompletions()
                h.supervisor.qaBeforeHelperWakeAdmission = nil
                let after = try SpawnResultFile.collect(parentCwd: cwd, handle: "card7-race", recipient: h.id.rawValue,
                    requestId: "race-after-admission", snapshot: courier)
                try expect(duringAdmission == .deliveryPending && after?.status == .alreadyDelivered,
                    "collection raced steer custody admission")
                try await eventually("race steer handed") { h.frames.contains { $0["method"] as? String == "turn/steer" } }
            }
            h.supervisor.stop(h.id)
            try await eventually("race Stop releases runtime custody") {
                !h.supervisor.isRunning(h.id) && !h.supervisor.pendingSteers(for: h.id).contains { $0.state == .delivering }
            }
            print("card7 collection/steer arbitration \(collectionFirst ? "collection-first" : "stage-first") PASS")
        }
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "; ")) }
        return
    }

    if waitInputOnly {
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let h = try Harness(kind)
            defer { h.tearDown() }
            onPath(h)
            try expect(h.supervisor.helperWaitPendingInput(for: h.id) == nil, "empty queue wakes no wait")
            try expect(h.supervisor.send("PLAIN text", to: h.id), "seed refused")
            try await eventually("runner bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
            try expect(await h.supervisor.accept(.queue(AgentPrompt("inbox")), for: h.id) == .accepted, "queue refused")
            try expect(h.supervisor.helperWaitPendingInput(for: h.id) == "inbox", "\(kind): inbox must wake wait")
            try expect(await h.supervisor.accept(.steer(AgentPrompt("steer")), for: h.id) == .accepted, "steer refused")
            try expect(h.supervisor.helperWaitPendingInput(for: h.id) == "user_steer", "\(kind): held steer must wake wait")
            try expect(!h.supervisor.pendingSteers(for: h.id).isEmpty, "query must not consume steer")
        }
        for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let h = try Harness(kind)
            defer { h.tearDown() }
            onPath(h)
            try expect(h.supervisor.send(kind == .pi ? "SLOW job" : "HOLD job", to: h.id), "handoff seed refused")
            try await eventually("handoff runner bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
            try expect(await h.supervisor.accept(.steer(AgentPrompt("handed steer")), for: h.id) == .accepted, "handoff steer refused")
            try await eventually("handoff reaches provider") {
                h.supervisor.pendingSteers(for: h.id).map(\.state) == [.delivering]
            }
            try expect(h.supervisor.helperWaitPendingInput(for: h.id) == "user_steer",
                       "\(kind): accepted but unsampled steer must still wake a blocking tool")
        }
        print("Helper wait input checks passed: production Claude, Codex and Pi runners with offline CLI fixtures")
        return
    }

    // 1. Enter-to-steer reaches every harness: accept(.steer) on a bound
    //    production runner is accepted, held to the tool boundary, written in
    //    the harness's own wire form, and confirmed before it is shown.
    for kind in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
        let h = try Harness(kind)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("TOOL work", to: h.id), "\(kind): the seed turn was refused")
        try await eventually("\(kind): a bound runner must advertise steering") {
            h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true
        }
        let acceptance = await h.supervisor.accept(.steer(AgentPrompt("change course")), for: h.id)
        try expect(acceptance == .accepted, "\(kind): accept(.steer) must be accepted, got \(acceptance)")
        try await eventually("\(kind): the turn must finish") { !h.supervisor.isRunning(h.id) }
        let wire: Bool
        switch kind {
        case .claude:
            wire = h.frames.compactMap { ($0["message"] as? [String: Any])?["content"] as? String } == ["TOOL work", "change course"]
        case .codex:
            let steer = h.frames.first { $0["method"] as? String == "turn/steer" }?["params"] as? [String: Any]
            wire = steer?["expectedTurnId"] as? String == "turn-1"
                && ((steer?["input"] as? [[String: Any]])?.first?["text"] as? String) == "change course"
        case .pi:
            wire = h.frames.filter { $0["type"] as? String == "steer" }.compactMap { $0["message"] as? String } == ["change course"]
        }
        try expect(wire, "\(kind): the steer must reach the provider as its native steer, frames \(h.frames)")
        try expect(h.promptTexts == ["TOOL work"] || kind == .claude,
                   "\(kind): a steer must not be replayed as a new prompt, prompts \(h.promptTexts)")
        try await eventually("\(kind): a delivered steer must be echoed once the provider confirms it") {
            h.echoes == ["change course"] && h.supervisor.pendingSteers(for: h.id).isEmpty
        }
        try await eventually("\(kind): steering must not end the turn, got \(h.completedTurns)") {
            h.completedTurns == [.completed]
        }
    }

    // 2. A held steer whose turn ends before any tool boundary runs NEXT,
    //    ahead of the queue, as an ordinary prompt; then the queue, one per turn.
    do {
        let h = try Harness(.pi)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("PLAIN text", to: h.id), "held: seed refused")
        try await eventually("held: runner bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
        try expect(await h.supervisor.accept(.queue(AgentPrompt("queued one")), for: h.id) == .accepted, "held: queue refused")
        try expect(await h.supervisor.accept(.steer(AgentPrompt("held steer")), for: h.id) == .accepted, "held: steer refused")
        try expect(h.supervisor.pendingSteers(for: h.id).map(\.state) == [.held],
                   "held: before a boundary the steer is held and editable, got \(h.supervisor.pendingSteers(for: h.id))")
        try await eventually("held: the held steer, then the queue, must each run as their own turn", timeout: 10) {
            h.promptTexts == ["PLAIN text", "held steer", "queued one"] && !h.supervisor.isRunning(h.id)
        }
        try expect(!h.frames.contains { $0["type"] as? String == "steer" },
                   "held: a steer that never met a boundary must not be written as a steer")
    }

    // 3. Force send interrupts WITHOUT killing, runs now, and leaves the queue
    //    held behind it (not paused, not lost) — on a claude session and a pi one.
    for kind in [AgentSteeringQAFakes.Harness.claude, .pi] {
        let h = try Harness(kind)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("SLOW job", to: h.id), "\(kind) force: seed refused")
        try await eventually("\(kind) force: bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
        try await Task.sleep(for: .milliseconds(300))
        try expect(await h.supervisor.accept(.queue(AgentPrompt("later")), for: h.id) == .accepted, "\(kind) force: queue refused")
        let forced = await h.supervisor.accept(.forceSend(AgentPrompt("NOW")), for: h.id)
        try expect(forced == .accepted, "\(kind) force: accept(.forceSend) must be accepted, got \(forced)")
        try await eventually("\(kind) force: the forced prompt, then the held queue, must run", timeout: 10) {
            h.promptTexts == ["SLOW job", "NOW", "later"] && !h.supervisor.isRunning(h.id)
        }
        try expect(h.spawns == 1, "\(kind) force: the process must survive the interrupt, spawned \(h.spawns)")
        let interrupted = h.frames.contains {
            ($0["type"] as? String) == "abort"
                || (($0["request"] as? [String: Any])?["subtype"] as? String) == "interrupt"
        }
        try expect(interrupted, "\(kind) force: the running turn must be interrupted over the wire")
        try expect(h.completedTurns.first == .interrupted && !h.supervisor.isQueuePaused(for: h.id),
                   "\(kind) force: the interrupted turn must not pause the queue, turns \(h.completedTurns)")
    }

    // 4. Stop interrupts: the claude process lives, the turn closes
    //    .interrupted, the queue pauses, and Resume drains it.
    do {
        let h = try Harness(.claude)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("SLOW job", to: h.id), "stop: seed refused")
        try await eventually("stop: bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
        try await Task.sleep(for: .milliseconds(300))
        try expect(await h.supervisor.accept(.queue(AgentPrompt("after stop")), for: h.id) == .accepted, "stop: queue refused")
        try expect(await h.supervisor.accept(.stop, for: h.id) == .accepted, "stop: accept(.stop) refused")
        try await eventually("stop: the turn must end as interrupted") {
            !h.supervisor.isRunning(h.id) && h.completedTurns == [.interrupted]
        }
        let pid = AgentSteeringQAFakes.latestPid(in: h.bin)
        try expect(pid.map { kill($0, 0) == 0 } == true, "stop: Stop must not kill the claude process")
        try expect(h.supervisor.isQueuePaused(for: h.id) && h.promptTexts == ["SLOW job"],
                   "stop: an interrupted turn must pause the queue, prompts \(h.promptTexts)")
        h.supervisor.resumeQueue(for: h.id)
        try await eventually("stop: Resume must drain the paused queue on the same process") {
            h.promptTexts == ["SLOW job", "after stop"] && !h.supervisor.isRunning(h.id)
        }
        try expect(h.spawns == 1, "stop: the resumed turn must reuse the session, spawned \(h.spawns)")
    }

    // 5. A claude background job outlives its turn, and an idle session with
    //    background work is not reaped; one without is, after the timeout.
    do {
        let h = try Harness(.claude, idleTimeout: 1)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("BACKGROUND job", to: h.id), "background: seed refused")
        try await eventually("background: turn done") { !h.supervisor.isRunning(h.id) && h.completedTurns == [.completed] }
        try await Task.sleep(for: .milliseconds(1500))
        let job = AgentSteeringQAFakes.backgroundPid(in: h.bin)
        let session = AgentSteeringQAFakes.latestPid(in: h.bin)
        try expect(job.map { kill($0, 0) == 0 } == true && session.map { kill($0, 0) == 0 } == true,
                   "background: the job and its session must outlive the result frame and the idle timeout")
    }
    do {
        let h = try Harness(.claude, idleTimeout: 1)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("hello", to: h.id), "reap: seed refused")
        try await eventually("reap: turn done") { !h.supervisor.isRunning(h.id) && h.completedTurns == [.completed] }
        let session = AgentSteeringQAFakes.latestPid(in: h.bin)
        try expect(session.map { kill($0, 0) == 0 } == true, "reap: the idle session lives until its timeout")
        try await eventually("reap: an idle session with no background work must be reaped after the timeout", timeout: 5) {
            session.map { kill($0, 0) != 0 } ?? false
        }
    }

    // 6. A claude crash closes the turn; the next send respawns with --resume.
    do {
        let h = try Harness(.claude)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("CRASH now", to: h.id), "crash: seed refused")
        try await eventually("crash: the failed turn must close") { !h.supervisor.isRunning(h.id) && h.completedTurns == [.failed] }
        try expect(h.supervisor.send("after crash", to: h.id), "crash: the next send was refused")
        try await eventually("crash: the next send must run on a resumed session") {
            !h.supervisor.isRunning(h.id) && h.completedTurns == [.failed, .completed]
        }
        try expect(h.spawns == 2 && AgentSteeringQAFakes.argv(in: h.bin).contains("--resume"),
                   "crash: respawn must --resume, argv \(AgentSteeringQAFakes.argv(in: h.bin))")
    }

    // 7. A steer handed to claude after its last boundary comes back as a turn
    //    claude starts itself; the supervisor binds it and confirms the steer.
    do {
        let h = try Harness(.claude)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("PLAIN text", to: h.id), "promote: seed refused")
        try await eventually("promote: bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
        try await Task.sleep(for: .milliseconds(200))
        try expect(await h.supervisor.accept(.steer(AgentPrompt("late steer")), for: h.id) == .accepted, "promote: steer refused")
        guard let held = h.supervisor.pendingSteers(for: h.id).first else { throw Failure(description: "steering: promote: no held steer") }
        try expect(await h.supervisor.sendQueuedItemNow(held.id, for: h.id), "promote: send-now on a held steer refused")
        try await eventually("promote: claude's own next turn must be bound and the steer confirmed", timeout: 10) {
            h.completedTurns == [.completed, .completed] && h.echoes == ["late steer"] && !h.supervisor.isRunning(h.id)
        }
        try expect(h.promptTexts == ["PLAIN text", "late steer"] && h.spawns == 1,
                   "promote: one process, the steer written once, prompts \(h.promptTexts)")
    }

    // 8. Queue operations: reorder, delete, send-now (a force send), resume.
    do {
        let h = try Harness(.pi)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("SLOW job", to: h.id), "ops: seed refused")
        try await eventually("ops: bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canQueue == true }
        for text in ["A", "B", "C"] {
            try expect(await h.supervisor.accept(.queue(AgentPrompt(text)), for: h.id) == .accepted, "ops: queue \(text) refused")
        }
        let ids = Dictionary(uniqueKeysWithValues: h.supervisor.queuedMessages(for: h.id).map { ($0.text, $0.id) })
        h.supervisor.moveQueuedItem(ids["C"]!, toFollowUpIndex: 0, for: h.id)
        try await eventually("ops: reorder must move C to the front") {
            h.supervisor.queuedMessages(for: h.id).map(\.text) == ["C", "A", "B"]
        }
        h.supervisor.cancelQueuedMessage(ids["A"]!, for: h.id)
        try await eventually("ops: delete must remove A") { h.supervisor.queuedMessages(for: h.id).map(\.text) == ["C", "B"] }
        try expect(await h.supervisor.sendQueuedItemNow(ids["B"]!, for: h.id), "ops: send-now refused")
        try await eventually("ops: send-now must interrupt and run B, then C drains", timeout: 10) {
            h.promptTexts == ["SLOW job", "B", "C"] && !h.supervisor.isRunning(h.id)
        }
        try expect(h.echoes == ["B", "C"], "ops: rail-started prompts must be echoed, got \(h.echoes)")
        try expect(h.spawns == 1, "ops: send-now must not kill pi, spawned \(h.spawns), frames \(h.frames.compactMap { $0["type"] as? String }), turns \(h.completedTurns)")
    }

    // 9. T5c — Stop while a steer is HANDED to the provider but not consumed.
    //    After Stop nothing further runs until the user acts: claude and pi give
    //    the steer back, so it is held and editable at the front of the rail;
    //    Codex acknowledgment alone is not an application receipt.
    //    The queue behind it shows "Paused after Stop".
    for kind in [AgentSteeringQAFakes.Harness.claude, .pi, .codex] {
        let h = try Harness(kind)
        defer { h.tearDown() }
        onPath(h)
        let seed = kind == .pi ? "SLOW job" : "HOLD job"
        try expect(h.supervisor.send(seed, to: h.id), "\(kind) stop-handed: seed refused")
        try await eventually("\(kind) stop-handed: bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
        try expect(await h.supervisor.accept(.queue(AgentPrompt("queued one")), for: h.id) == .accepted, "\(kind) stop-handed: queue refused")
        try expect(await h.supervisor.accept(.steer(AgentPrompt("handed steer")), for: h.id) == .accepted, "\(kind) stop-handed: steer refused")
        try await eventually("\(kind) stop-handed: the steer must be handed to the provider at the tool boundary") {
            h.supervisor.pendingSteers(for: h.id).map(\.state) == [.delivering]
        }
        try await Task.sleep(for: .milliseconds(200))
        try expect(await h.supervisor.accept(.stop, for: h.id) == .accepted, "\(kind) stop-handed: accept(.stop) refused")
        try await eventually("\(kind) stop-handed: the turn must end as interrupted") {
            !h.supervisor.isRunning(h.id) && h.completedTurns == [.interrupted]
        }
        // The fakes promote a surviving message to their next turn within
        // milliseconds; give that every chance to show.
        try await Task.sleep(for: .milliseconds(1500))
        try expect(h.completedTurns == [.interrupted] && !h.supervisor.isRunning(h.id),
                   "\(kind) stop-handed: nothing may run after Stop, turns \(h.completedTurns), prompts \(h.promptTexts)")
        let rail = h.supervisor.queueRailState(for: h.id)
        try expect(rail.pause == (kind == .codex ? .unconfirmed : .afterStop) && rail.queued.map(\.text) == ["queued one"],
                   "\(kind) stop-handed: the queue must stay held, Paused after Stop, got \(rail)")
        do {
            try expect(rail.steers.map(\.text) == ["handed steer"] && rail.steers.map(\.kind) == [.heldSteer],
                       "\(kind) stop-handed: the unconsumed steer must come back held and editable at the front, got \(rail.steers)")
            try expect(h.echoes.isEmpty, "\(kind) stop-handed: a returned steer must not be shown as sent, echoes \(h.echoes)")
            try expect(h.spawns == 1, "\(kind) stop-handed: Stop must interrupt, not kill, spawned \(h.spawns)")
        }
    }

    // 10. T5c — force send while a steer is handed over: the forced message
    //     runs, the unconsumed steer returns to the rail ahead of the queue,
    //     and both wait (paused) until the user resumes — steer first.
    for kind in [AgentSteeringQAFakes.Harness.claude, .pi] {
        let h = try Harness(kind)
        defer { h.tearDown() }
        onPath(h)
        let seed = kind == .pi ? "SLOW job" : "HOLD job"
        try expect(h.supervisor.send(seed, to: h.id), "\(kind) force-handed: seed refused")
        try await eventually("\(kind) force-handed: bound") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
        try expect(await h.supervisor.accept(.queue(AgentPrompt("later")), for: h.id) == .accepted, "\(kind) force-handed: queue refused")
        try expect(await h.supervisor.accept(.steer(AgentPrompt("handed steer")), for: h.id) == .accepted, "\(kind) force-handed: steer refused")
        try await eventually("\(kind) force-handed: the steer must be handed over") {
            h.supervisor.pendingSteers(for: h.id).map(\.state) == [.delivering]
        }
        try await Task.sleep(for: .milliseconds(200))
        try expect(await h.supervisor.accept(.forceSend(AgentPrompt("NOW")), for: h.id) == .accepted, "\(kind) force-handed: force send refused")
        do {
            try await eventually("\(kind) force-handed: the forced message must run after the interrupt", timeout: 10) {
                h.completedTurns == [.interrupted, .completed] && !h.supervisor.isRunning(h.id)
            }
        } catch {
            throw Failure(description: "steering: \(kind) force-handed: the forced message must run after the interrupt, turns \(h.completedTurns), prompts \(h.promptTexts), rail \(h.supervisor.queueRailState(for: h.id)), wire \(h.frames.compactMap { $0["type"] as? String })")
        }
        try await Task.sleep(for: .milliseconds(1500))
        let rail = h.supervisor.queueRailState(for: h.id)
        try expect(h.completedTurns == [.interrupted, .completed]
                   && rail.steers.map(\.text) == ["handed steer"] && rail.steers.map(\.kind) == [.heldSteer]
                   && rail.queued.map(\.text) == ["later"] && rail.pause != nil,
                   "\(kind) force-handed: after the forced turn the returned steer and the queue must wait, paused; turns \(h.completedTurns), rail \(rail), prompts \(h.promptTexts)")
        let beforeResume = h.promptTexts
        try expect(beforeResume.last == "NOW", "\(kind) force-handed: the forced message must be the last prompt run, got \(beforeResume)")
        h.supervisor.resumeQueue(for: h.id)
        try await eventually("\(kind) force-handed: Resume must run the returned steer first, then the queue", timeout: 10) {
            h.promptTexts == beforeResume + ["handed steer", "later"] && !h.supervisor.isRunning(h.id)
        }
        try expect(h.spawns == 1, "\(kind) force-handed: the process must survive, spawned \(h.spawns)")
    }

    print("AgentSteeringChecks passed: accept(.steer) reaches claude stdin, codex turn/steer (expectedTurnId) and pi steer and is echoed only once confirmed; a held steer runs next ahead of the queue; force send interrupts without killing and keeps the queue; Stop interrupts, pauses, and Resume drains on the same process; a claude background job outlives its turn and blocks reaping while an idle session is reaped; a crash respawns with --resume; a promoted steer becomes a bound turn; reorder, delete and send-now work on the durable queue; Stop with a steer handed but unconsumed runs nothing further, returns the claude/pi steer held at the front and pauses the queue on all three harnesses; force send with a handed steer runs the forced message and holds the returned steer ahead of the paused queue")
}
