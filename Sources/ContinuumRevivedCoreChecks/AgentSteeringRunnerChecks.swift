import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Darwin
import Foundation

// T5 (`.plans/69`) — the runner half of steering, interrupt-not-kill, and the
// persistent Claude process, driven through the PRODUCTION runners with the
// reactive fakes in `AgentSteeringQAFakes` standing in for each CLI on PATH. The
// fakes record the exact argv and every stdin frame, so these assert what Array
// actually wrote, not what it meant to write. The supervisor half (held steers,
// queue ops, force send) is `--agent-compaction-ui-check`'s steering section.
func runAgentSteeringRunnerChecks() {
    #if os(macOS)
    runClaudeSessionRunnerChecks()
    runClaudeBackgroundSubagentChecks()
    runPiSteeringRunnerChecks()
    runCodexSteeringRunnerChecks()
    print("Agent steering runner checks passed: claude is one stream-json process for many turns with the exact argv and stdin frames, steers land at the tool boundary and are confirmed by replay, interrupt keeps the process, a background job survives the result frame, a promoted steer is an adoptable unsolicited turn, the session-mode retry and crash paths hold, /compact rides stdin; pi steers and confirms through queue_update and returns unread steers on abort; codex steers with expectedTurnId and interrupts without killing; an interrupt cancels a claude steer handed over but not consumed and hands it back, and an unapplied codex steer dies with its app-server")
    #endif
}

#if os(macOS)

/// `.plans/87` Step 3 — a background Claude child's real lifetime, through the
/// production runner and translator. `Fixtures/claude-async-subagent.jsonl` is
/// the committed 2.1.241 capture (`claude-subagent-turn.jsonl`) re-ordered the
/// way a background launch arrives: the Agent call is answered at once by the
/// `async_launched` acknowledgement (shape copied from a real 2.1.310 session
/// log), the parent's result follows, and the child's frames, progress and
/// `task_notification` arrive after it, inside claude's own next turn (a fresh
/// `init`, so a fresh per-turn translator).
private func runClaudeBackgroundSubagentChecks() {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-async-subagent.jsonl")
    let toolUseID = "toolu_0164hvbb7oKHD8HqnBRJVh8E"
    func isChildClose(_ pair: (String, AgentRuntimeEvent)) -> TurnOutcome? {
        if pair.0 == toolUseID, case let .turnCompleted(_, _, outcome, _) = pair.1 { return outcome }
        return nil
    }

    // 1. The runner: open on launch, alive past the parent's result and past a
    //    new init, closed by its own notification.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("replay.jsonl"))
        withFakeOnPath(root) {
            let runner = ClaudeAgentRunner(config: .init(
                model: "fake-model", effort: "high", cwd: root,
                sessionId: "00000000-0000-4000-8000-000000000001", conversationMayExist: false))
            let child = SteeringBox<[(String, AgentRuntimeEvent)]>([])
            let progress = SteeringBox<[String]>([])
            runner.observeSubagentEvents { id, event in child.value.append((id, event)) }
            runner.observeSubagentProgress { progress.value.append($0) }
            let parent = SteeringBox<[AgentRuntimeEvent]>([])
            do { try runner.run(prompt: AgentPrompt("REPLAY")) { parent.value.append($0) } } catch {
                expect(false, "claude async child: the launching turn must not throw: \(error)")
            }
            expect(outcomes(parent.value) == [.completed],
                   "claude async child: the launching turn must close on its own result, got \(outcomes(parent.value))")
            expect(child.value.compactMap(isChildClose).isEmpty,
                   "claude async child: the async_launched acknowledgement closed the child at launch: \(child.value.compactMap(isChildClose))")
            expect(runner.hasRunningSubagents,
                   "claude async child: a launched background child must hold the session open after the parent's result")
            expect(waitUntil(5) { !child.value.compactMap(isChildClose).isEmpty },
                   "claude async child: the child never closed — its frames after the next init were lost")
            expect(child.value.compactMap(isChildClose) == [.completed],
                   "claude async child: task_notification(completed) must close the child exactly once, got \(child.value.compactMap(isChildClose))")
            expect(child.value.contains { $0.0 == toolUseID && { if case .contentDelta = $0 { return true }; return false }($0.1) },
                   "claude async child: the child's own answer, sent after the parent's result, must reach the child channel")
            expect(progress.value.contains(toolUseID),
                   "claude async child: task_progress must report the child's activity")
            expect(!runner.hasRunningSubagents,
                   "claude async child: a closed child must stop holding the session open")
            runner.stop()
        }
    }

    // 2. The translator alone: a roster that empties BEFORE the notification
    //    releases the session, and the notification still decides the outcome.
    //    A shell job in the roster never holds a child open.
    do {
        let lines = ((try? String(contentsOf: fixture, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        expect(lines.count > 30, "claude async child: the fixture looks truncated at \(lines.count) lines")
        let child = SteeringBox<[(String, AgentRuntimeEvent)]>([])
        var translator = ClaudeEventTranslator(runToken: "r")
        translator.onSubagentEvent = { id, event in child.value.append((id, event)) }
        let launchEnd = lines.firstIndex { $0.contains("\"type\": \"result\"") } ?? 0
        _ = translator.translate(stream: Array(lines[...launchEnd]))
        expect(translator.subagents.hasRunningChildren, "claude roster: the launched child must be running")
        _ = translator.translate(line: #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"shell-1","description":"npm run dev"}]}"#)
        expect(!translator.subagents.hasRunningChildren,
               "claude roster: once claude's roster drops the child, only a shell job is left and it must not count as a running child")
        expect(child.value.compactMap(isChildClose).isEmpty,
               "claude roster: the roster alone must not invent an outcome")
        _ = translator.translate(line: #"{"type":"system","subtype":"task_notification","task_id":"a9e8aa2b2ab55ecf5","tool_use_id":"toolu_0164hvbb7oKHD8HqnBRJVh8E","status":"failed"}"#)
        expect(child.value.compactMap(isChildClose) == [.failed],
               "claude roster: a failed notification after the roster emptied must close the child failed, got \(child.value.compactMap(isChildClose))")
        _ = translator.translate(line: #"{"type":"system","subtype":"task_notification","task_id":"shell-1","status":"completed"}"#)
        expect(child.value.compactMap(isChildClose) == [.failed],
               "claude roster: a shell job's notification must not touch any child")
    }
}

private final class SteeringBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private func steeringFakeRoot(_ harness: AgentSteeringQAFakes.Harness) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-steering-\(harness.rawValue)-\(UUID().uuidString)", isDirectory: true)
    try? AgentSteeringQAFakes.install(harness, in: root)
    return root
}

private func withFakeOnPath(_ root: URL, extra: [String: String] = [:], _ body: () -> Void) {
    var overrides = extra
    overrides["PATH"] = "\(root.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
    var previous: [String: String?] = [:]
    for (key, value) in overrides {
        previous[key] = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
    }
    defer {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    body()
}

/// Runs `body` on a background thread and returns a waiter for it.
private func inBackground(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        body()
        done.signal()
    }
    return done
}

private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func isToolStart(_ event: AgentRuntimeEvent) -> Bool {
    guard case let .itemStarted(_, _, kind, _) = event else { return false }
    return ![.assistantMessage, .reasoning, .plan, .error, .compaction].contains(kind)
}

private func outcomes(_ events: [AgentRuntimeEvent]) -> [TurnOutcome] {
    events.compactMap { if case let .turnCompleted(_, _, outcome, _) = $0 { return outcome } else { return nil } }
}

private func userTexts(_ frames: [[String: Any]]) -> [String] {
    frames.compactMap { frame in
        guard frame["type"] as? String == "user",
              let message = frame["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

// MARK: - Claude

private func runClaudeSessionRunnerChecks() {
    let sessionID = "00000000-0000-4000-8000-00000000c1a1"
    func makeRunner(_ root: URL, mayExist: Bool = false) -> ClaudeAgentRunner {
        ClaudeAgentRunner(config: .init(
            model: "fake-model", effort: "high", cwd: root, sessionId: sessionID,
            conversationMayExist: mayExist))
    }

    // 1. Exact argv, exact stdin frames, ONE process for two turns.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            do {
                try runner.run(prompt: AgentPrompt("first")) { events.value.append($0) }
                try runner.run(prompt: AgentPrompt("second")) { events.value.append($0) }
            } catch {
                expect(false, "claude session: two plain turns must not throw: \(error)")
            }
            expect(AgentSteeringQAFakes.argv(in: root) == ClaudeAgentRunner.processArguments(
                model: "fake-model", effort: "high", sessionMode: .start, sessionId: sessionID, extraArgs: []),
                "claude session: the spawned argv must be processArguments(.start) exactly, got \(AgentSteeringQAFakes.argv(in: root))")
            let frames = AgentSteeringQAFakes.receivedFrames(in: root)
            expect(frames.map { $0["type"] as? String } == ["user", "user"] && userTexts(frames) == ["first", "second"],
                   "claude session: each prompt must be one stream-json user message on stdin, got \(frames)")
            expect(AgentSteeringQAFakes.spawnCount(in: root) == 1,
                   "claude session: ONE process must serve both turns; spawned \(AgentSteeringQAFakes.spawnCount(in: root))")
            expect(outcomes(events.value) == [.completed, .completed],
                   "claude session: each turn must close on its result frame, got \(outcomes(events.value))")
            expect(runner.isSessionRunning, "claude session: the process must still be alive between turns")
            runner.stop()
        }
    }

    // 1b. Every launch the runner spawns runs in bypass permissions mode: a
    //     headless -p session has nobody to answer a prompt, so on the CLI's
    //     default mode the agent's shell, Xcode, git and network calls are
    //     denied. Read from the fake's recorded argv, not re-derived.
    for (label, mayExist, fork, sessionFlags) in [
        ("start", false, false, ["--session-id", sessionID]),
        ("resume", true, false, ["--resume", sessionID]),
        ("fork", true, true, ["--resume", sessionID, "--fork-session"]),
    ] {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = ClaudeAgentRunner(config: .init(
                model: "fake-model", effort: "high", cwd: root, sessionId: sessionID,
                conversationMayExist: mayExist, forkSession: fork))
            do {
                try runner.run(prompt: AgentPrompt("first")) { _ in }
            } catch {
                expect(false, "claude permissions (\(label)): a plain turn must not throw: \(error)")
            }
            runner.stop()
            let argv = AgentSteeringQAFakes.argv(in: root)
            func contains(_ run: [String]) -> Bool {
                argv.indices.contains { argv[$0...].starts(with: run) }
            }
            expect(contains(sessionFlags),
                   "claude permissions (\(label)): expected session flags \(sessionFlags), got \(argv)")
            expect(contains(["--permission-mode", "bypassPermissions"]),
                   "claude permissions (\(label)): spawned claude must run in bypassPermissions mode, got \(argv)")
        }
    }
    print("Claude bypassPermissions launch witnessed: start, resume, fork")

    // 2. A steer written during a tool call is consumed at the boundary and
    //    confirmed by its replay.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let consumed = SteeringBox<[UUID]>([])
            runner.observeSteerDispositions { id, disposition in
                if disposition == .consumed { consumed.value.append(id) }
            }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("TOOL please")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains(where: isToolStart) && runner.acceptsSteerNow },
                   "claude steer: the tool call must start and the turn must accept a steer")
            let steerID = UUID()
            do { try runner.steer(AgentPrompt("change course"), id: steerID) } catch {
                expect(false, "claude steer: steer() mid-tool must succeed: \(error)")
            }
            _ = done.wait(timeout: .now() + 5)
            expect(userTexts(AgentSteeringQAFakes.receivedFrames(in: root)) == ["TOOL please", "change course"],
                   "claude steer: the steer must be the next stdin user message")
            expect(consumed.value == [steerID], "claude steer: the replay must confirm consumption, got \(consumed.value)")
            expect(outcomes(events.value) == [.completed], "claude steer: one result, one turn, got \(outcomes(events.value))")
            runner.stop()
        }
    }

    // 3. Interrupt ends the turn and keeps the process for the next message.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let thrown = SteeringBox<Error?>(nil)
            let done = inBackground {
                do { try runner.run(prompt: AgentPrompt("SLOW job")) { events.value.append($0) } } catch { thrown.value = error }
            }
            expect(waitUntil { events.value.contains(where: isToolStart) }, "claude interrupt: the slow tool must start")
            do { try runner.interrupt() } catch { expect(false, "claude interrupt: interrupt() must be acknowledged: \(error)") }
            expect(done.wait(timeout: .now() + 3) == .success, "claude interrupt: the turn must end promptly after the interrupt")
            expect(thrown.value == nil, "claude interrupt: an interrupted turn is not an error: \(String(describing: thrown.value))")
            expect(outcomes(events.value) == [.interrupted], "claude interrupt: the turn must close .interrupted, got \(outcomes(events.value))")
            let frames = AgentSteeringQAFakes.receivedFrames(in: root)
            expect(frames.contains { ($0["type"] as? String) == "control_request" && (($0["request"] as? [String: Any])?["subtype"] as? String) == "interrupt" },
                   "claude interrupt: the interrupt must be a control_request on stdin")
            let after = SteeringBox<[AgentRuntimeEvent]>([])
            do { try runner.run(prompt: AgentPrompt("after")) { after.value.append($0) } } catch {
                expect(false, "claude interrupt: the same process must accept the next message: \(error)")
            }
            expect(outcomes(after.value) == [.completed] && AgentSteeringQAFakes.spawnCount(in: root) == 1,
                   "claude interrupt: the next turn must run on the SAME process (spawned \(AgentSteeringQAFakes.spawnCount(in: root)))")
            runner.stop()
        }
    }

    // 4. A background job started in turn 1 is alive after the result frame;
    //    stop() is what ends it.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            try? runner.run(prompt: AgentPrompt("BACKGROUND job")) { _ in }
            Thread.sleep(forTimeInterval: 0.3)
            let pid = AgentSteeringQAFakes.backgroundPid(in: root)
            expect(pid.map { kill($0, 0) == 0 } == true,
                   "claude background: the job started in turn 1 must still be alive after its result frame (pid \(String(describing: pid)))")
            expect(runner.hasBackgroundWork, "claude background: background_tasks_changed must report live work")
            runner.stop()
            expect(waitUntil(3) { pid.map { kill($0, 0) != 0 } ?? true },
                   "claude background: stop() kills the group, background job included")
        }
    }

    // 5. A steer claude promotes to its own next turn arrives as an
    //    unsolicited turn the caller can adopt, with the steer confirmed.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let consumed = SteeringBox<[UUID]>([])
            runner.observeSteerDispositions { id, _ in consumed.value.append(id) }
            let announced = DispatchSemaphore(value: 0)
            runner.observeUnsolicitedTurns { announced.signal() }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("PLAIN text")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains { if case .turnStarted = $0 { return true }; return false } },
                   "claude promote: the plain turn must start")
            let steerID = UUID()
            try? runner.steer(AgentPrompt("late steer"), id: steerID)
            _ = done.wait(timeout: .now() + 5)
            expect(announced.wait(timeout: .now() + 5) == .success,
                   "claude promote: a steer with no boundary left must surface as an unsolicited turn")
            let adopted = SteeringBox<[AgentRuntimeEvent]>([])
            try? runner.continueUnsolicitedTurn { adopted.value.append($0) }
            expect(outcomes(adopted.value) == [.completed]
                   && adopted.value.contains { if case .turnStarted = $0 { return true }; return false },
                   "claude promote: the adopted turn must replay its start and close on its own result, got \(adopted.value)")
            expect(consumed.value == [steerID], "claude promote: the promoted steer must be confirmed by its replay")
            runner.stop()
        }
    }

    // 6. The first-turn session-mode retry: a resume of a conversation that
    //    does not exist dies before init and is retried as --session-id with
    //    the same prompt.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("reject-resume").path, contents: Data())
        withFakeOnPath(root) {
            let runner = makeRunner(root, mayExist: true)
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            do { try runner.run(prompt: AgentPrompt("hello")) { events.value.append($0) } } catch {
                expect(false, "claude retry: a rejected resume must self-heal: \(error)")
            }
            expect(AgentSteeringQAFakes.spawnCount(in: root) == 2
                   && AgentSteeringQAFakes.argv(in: root).contains("--session-id"),
                   "claude retry: the retry must spawn --session-id, argv \(AgentSteeringQAFakes.argv(in: root))")
            expect(outcomes(events.value) == [.completed], "claude retry: the retried turn must complete")
            runner.stop()
        }
    }

    // 7. A crash mid-turn fails the turn and retires the session.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            var failed = false
            do { try runner.run(prompt: AgentPrompt("CRASH now")) { _ in } } catch {
                if case ClaudeAgentRunner.RunError.claudeFailed(let code, _) = error, code == 3 { failed = true }
            }
            expect(failed, "claude crash: a mid-turn exit 3 must throw claudeFailed(3)")
            expect(waitUntil { !runner.isSessionRunning },
                   "claude crash: a dead session must not be offered another turn")
        }
    }

    // 8. /compact rides the same stdin, and an image is a native image block.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("shot.png")
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let prompt = AgentPrompt(
                text: "look",
                imageAttachments: [AgentPromptImageAttachment(
                    metadata: AgentImageAttachmentMetadata(
                        id: AgentImageAttachmentID(rawValue: "img-1")!,
                        displayName: "shot.png", contentType: "image/png",
                        byteCount: 4, pixelWidth: 1, pixelHeight: 1),
                    fileURL: image)],
                fileReferences: [])
            try? runner.run(prompt: prompt) { _ in }
            let compacted = SteeringBox<[AgentRuntimeEvent]>([])
            do {
                try runner.compact(AgentCompactionRequest(focus: "keep decisions")) { compacted.value.append($0) }
            } catch {
                expect(false, "claude compact: /compact over stdin must succeed: \(error)")
            }
            let frames = AgentSteeringQAFakes.receivedFrames(in: root)
            let firstContent = (frames.first?["message"] as? [String: Any])?["content"] as? [[String: Any]]
            let imageBlock = firstContent?.first { $0["type"] as? String == "image" }
            let source = imageBlock?["source"] as? [String: Any]
            expect(source?["type"] as? String == "base64" && source?["media_type"] as? String == "image/png"
                   && source?["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
                   "claude images: an image must travel as a base64 image block, got \(String(describing: firstContent))")
            expect(userTexts(frames).last == "/compact keep decisions" && AgentSteeringQAFakes.spawnCount(in: root) == 1,
                   "claude compact: /compact must be a stdin message on the SAME process, got \(userTexts(frames))")
            expect(compacted.value.contains { if case .compactionChanged = $0 { return true }; return false }
                   && !compacted.value.contains { if case .turnCompleted = $0 { return true }; return false },
                   "claude compact: only the compaction lifecycle crosses the compact seam")
            runner.stop()
        }
    }

    // 9. T5c — an interrupt while a steer is handed over but not consumed
    //    (claude holds it until the tool ends). Live claude 2.1.291 lists such a
    //    message under `still_queued` and runs it as its NEXT turn after a plain
    //    interrupt; the interrupt must cancel it and hand it back, and nothing
    //    may run afterwards.
    do {
        let root = steeringFakeRoot(.claude)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let dispositions = SteeringBox<[(UUID, AgentSteerDisposition)]>([])
            runner.observeSteerDispositions { id, d in dispositions.value.append((id, d)) }
            let unsolicited = SteeringBox<Int>(0)
            runner.observeUnsolicitedTurns { unsolicited.value += 1 }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("HOLD job")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains(where: isToolStart) && runner.acceptsSteerNow },
                   "claude stop-handed: the held tool must start")
            let steerID = UUID()
            do { try runner.steer(AgentPrompt("handed steer"), id: steerID) } catch {
                expect(false, "claude stop-handed: steer() mid-tool must succeed: \(error)")
            }
            Thread.sleep(forTimeInterval: 0.2)
            do { try runner.interrupt() } catch { expect(false, "claude stop-handed: interrupt() must be acknowledged: \(error)") }
            expect(done.wait(timeout: .now() + 3) == .success, "claude stop-handed: the turn must end after the interrupt")
            expect(outcomes(events.value) == [.interrupted],
                   "claude stop-handed: the turn must close .interrupted, got \(outcomes(events.value))")
            Thread.sleep(forTimeInterval: 0.8)
            expect(unsolicited.value == 0 && !runner.hasUnsolicitedTurn,
                   "claude stop-handed: nothing may run after the interrupt, yet claude started \(unsolicited.value) turn(s) of its own")
            expect(dispositions.value.map(\.0) == [steerID] && dispositions.value.map(\.1) == [.returned],
                   "claude stop-handed: the cancelled steer must come back returned, got \(dispositions.value)")
            let frames = AgentSteeringQAFakes.receivedFrames(in: root)
            let steerFrame = frames.first { userTexts([$0]) == ["handed steer"] }
            expect((steerFrame?["uuid"] as? String)?.lowercased() == steerID.uuidString.lowercased(),
                   "claude stop-handed: the steer must carry its id as the message uuid, got \(String(describing: steerFrame))")
            let interrupt = frames.first { (($0["request"] as? [String: Any])?["subtype"] as? String) == "interrupt" }
            expect((interrupt?["request"] as? [String: Any])?["cancel_queued"] as? Bool == true,
                   "claude stop-handed: the interrupt must ask claude to cancel what it holds, got \(String(describing: interrupt))")
            let after = SteeringBox<[AgentRuntimeEvent]>([])
            do { try runner.run(prompt: AgentPrompt("after")) { after.value.append($0) } } catch {
                expect(false, "claude stop-handed: the same process must take the next message: \(error)")
            }
            expect(outcomes(after.value) == [.completed] && AgentSteeringQAFakes.spawnCount(in: root) == 1,
                   "claude stop-handed: the next turn must be the user's, on the same process, got \(outcomes(after.value))")
            runner.stop()
        }
    }
}

// MARK: - Pi

private func runPiSteeringRunnerChecks() {
    func makeRunner(_ root: URL) -> PiRpcAgentRunner {
        PiRpcAgentRunner(config: .init(model: "fake-model", thinking: "low", cwd: root, sessionId: "fake-session"))
    }

    // Steer during a tool, confirmed by pi's queue_update draining.
    do {
        let root = steeringFakeRoot(.pi)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let dispositions = SteeringBox<[(UUID, AgentSteerDisposition)]>([])
            runner.observeSteerDispositions { id, d in dispositions.value.append((id, d)) }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("TOOL please")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains(where: isToolStart) && runner.acceptsSteerNow },
                   "pi steer: the tool must start")
            let steerID = UUID()
            do { try runner.steer(AgentPrompt("change course"), id: steerID) } catch {
                expect(false, "pi steer: steer() mid-tool must succeed: \(error)")
            }
            _ = done.wait(timeout: .now() + 5)
            let steers = AgentSteeringQAFakes.receivedFrames(in: root).filter { $0["type"] as? String == "steer" }
            expect(steers.count == 1 && steers.first?["message"] as? String == "change course",
                   "pi steer: one rpc steer command carrying the message, got \(steers)")
            expect(dispositions.value.map(\.0) == [steerID] && dispositions.value.map(\.1) == [.consumed],
                   "pi steer: queue_update draining must confirm consumption, got \(dispositions.value)")
            expect(outcomes(events.value) == [.completed], "pi steer: one turn, completed")
            runner.stop()
        }
    }

    // Abort keeps the process; a steer pi never read comes back `returned`.
    do {
        let root = steeringFakeRoot(.pi)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root) {
            let runner = makeRunner(root)
            let dispositions = SteeringBox<[(UUID, AgentSteerDisposition)]>([])
            runner.observeSteerDispositions { id, d in dispositions.value.append((id, d)) }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("SLOW job")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains(where: isToolStart) }, "pi abort: the slow tool must start")
            let steerID = UUID()
            try? runner.steer(AgentPrompt("held in pi"), id: steerID)
            do { try runner.interrupt() } catch { expect(false, "pi abort: interrupt() must succeed: \(error)") }
            expect(done.wait(timeout: .now() + 5) == .success, "pi abort: the turn must end")
            expect(outcomes(events.value) == [.interrupted], "pi abort: the turn must close .interrupted, got \(outcomes(events.value))")
            let types = AgentSteeringQAFakes.receivedFrames(in: root).compactMap { $0["type"] as? String }
            expect(types.contains("abort") && types.contains("clear_queue"),
                   "pi abort: abort then clear_queue must reach pi, got \(types)")
            expect(dispositions.value.map(\.0) == [steerID] && dispositions.value.map(\.1) == [.returned],
                   "pi abort: the unread steer must come back returned, got \(dispositions.value)")
            do { try runner.run(prompt: AgentPrompt("after")) { _ in } } catch {
                expect(false, "pi abort: the same process must take the next prompt: \(error)")
            }
            expect(AgentSteeringQAFakes.spawnCount(in: root) == 1, "pi abort: abort must not respawn pi")
            runner.stop()
        }
    }
    expect(PiRpcCommand.knownTypes.contains("clear_queue"), "pi: clear_queue must be in the rpc vocabulary")
}

// MARK: - Codex

private func runCodexSteeringRunnerChecks() {
    func makeRunner(_ root: URL) -> CodexAgentRunner {
        CodexAgentRunner(config: .init(model: "fake-model", cwd: root, threadId: nil))
    }

    // turn/steer carries the active turn as expectedTurnId; the response is
    // the receipt.
    do {
        let root = steeringFakeRoot(.codex)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root, extra: ["CONTINUUM_CODEX_TRANSPORT": "app-server"]) {
            let runner = makeRunner(root)
            let dispositions = SteeringBox<[(UUID, AgentSteerDisposition)]>([])
            runner.observeSteerDispositions { id, d in dispositions.value.append((id, d)) }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("TOOL please")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains(where: isToolStart) && runner.acceptsSteerNow },
                   "codex steer: the command must start")
            let steerID = UUID()
            do { try runner.steer(AgentPrompt("change course"), id: steerID) } catch {
                expect(false, "codex steer: turn/steer into the active turn must succeed: \(error)")
            }
            _ = done.wait(timeout: .now() + 5)
            let steer = AgentSteeringQAFakes.receivedFrames(in: root).first { $0["method"] as? String == "turn/steer" }
            let params = steer?["params"] as? [String: Any]
            expect(params?["expectedTurnId"] as? String == "turn-1" && params?["threadId"] as? String == "codex-fake-thread"
                   && params?["clientUserMessageId"] as? String == steerID.uuidString
                   && ((params?["input"] as? [[String: Any]])?.first?["text"] as? String) == "change course",
                   "codex steer: turn/steer must pin expectedTurnId to the active turn, got \(String(describing: params))")
            expect(dispositions.value.map(\.0) == [steerID], "codex steer: the response confirms the steer")
            expect(outcomes(events.value) == [.completed], "codex steer: one turn, completed")
            // The turn has ended: a late steer is refused, never sent blind.
            var refused = false
            do { try runner.steer(AgentPrompt("too late"), id: UUID()) } catch { refused = error is AgentSteerNotAccepted }
            expect(refused, "codex steer: with no active turn a steer must be refused so the supervisor keeps it")
        }
    }

    // turn/interrupt ends the turn `.interrupted` and kills nothing.
    do {
        let root = steeringFakeRoot(.codex)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root, extra: ["CONTINUUM_CODEX_TRANSPORT": "app-server"]) {
            let runner = makeRunner(root)
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let thrown = SteeringBox<Error?>(nil)
            let done = inBackground {
                do { try runner.run(prompt: AgentPrompt("SLOW job")) { events.value.append($0) } } catch { thrown.value = error }
            }
            expect(waitUntil { events.value.contains(where: isToolStart) }, "codex interrupt: the command must start")
            do { try runner.interrupt() } catch { expect(false, "codex interrupt: turn/interrupt must succeed: \(error)") }
            expect(done.wait(timeout: .now() + 5) == .success, "codex interrupt: the turn must end")
            expect(thrown.value == nil && outcomes(events.value) == [.interrupted],
                   "codex interrupt: an interrupted turn closes .interrupted without an error, got \(outcomes(events.value)) \(String(describing: thrown.value))")
            let methods = AgentSteeringQAFakes.receivedFrames(in: root).compactMap { $0["method"] as? String }
            expect(methods.contains("turn/interrupt"), "codex interrupt: turn/interrupt must reach the app-server, got \(methods)")
        }
    }

    // T5c — a steer codex accepted (turn/steer answered) but had not applied
    // when the turn was interrupted. turn/steer's response is the only receipt
    // codex gives and turn/interrupt has no cancel or receipt, so the steer
    // stays confirmed; what makes Stop final is that the app-server lives only
    // as long as its turn, so nothing it held can start another.
    do {
        let root = steeringFakeRoot(.codex)
        defer { try? FileManager.default.removeItem(at: root) }
        withFakeOnPath(root, extra: ["CONTINUUM_CODEX_TRANSPORT": "app-server"]) {
            let runner = makeRunner(root)
            let dispositions = SteeringBox<[(UUID, AgentSteerDisposition)]>([])
            runner.observeSteerDispositions { id, d in dispositions.value.append((id, d)) }
            let events = SteeringBox<[AgentRuntimeEvent]>([])
            let done = inBackground { try? runner.run(prompt: AgentPrompt("HOLD job")) { events.value.append($0) } }
            expect(waitUntil { events.value.contains(where: isToolStart) && runner.acceptsSteerNow },
                   "codex stop-handed: the command must start")
            let steerID = UUID()
            do { try runner.steer(AgentPrompt("handed steer"), id: steerID) } catch {
                expect(false, "codex stop-handed: turn/steer must be accepted: \(error)")
            }
            do { try runner.interrupt() } catch { expect(false, "codex stop-handed: turn/interrupt must succeed: \(error)") }
            expect(done.wait(timeout: .now() + 5) == .success, "codex stop-handed: the turn must end")
            expect(outcomes(events.value) == [.interrupted] && dispositions.value.map(\.1) == [.consumed],
                   "codex stop-handed: the turn closes .interrupted with the steer confirmed by turn/steer, got \(outcomes(events.value)) \(dispositions.value)")
            let pid = AgentSteeringQAFakes.latestPid(in: root)
            expect(waitUntil(3) { pid.map { kill($0, 0) != 0 } ?? false },
                   "codex stop-handed: the app-server must end with its interrupted turn, so the unapplied steer cannot start another")
            expect(!runner.acceptsSteerNow, "codex stop-handed: no turn may remain live after the interrupt")
        }
    }
}

#endif
