import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

// Confidence pass S6 — what happens to the user's words when a turn ends in a
// way the happy path does not: a Stop while a force send's interrupt is in
// flight, two force sends inside one interrupt, a steer the provider still
// held when its process was killed, a follow-up typed as the turn ended, and a
// late steer receipt racing an older grace timer. Every scenario drives
// `AgentSupervisor.accept` with the production runner factory against the
// reactive fakes (`AgentSteeringQAFakes`) on PATH, and asserts what reached the
// provider, what the rail shows, and what the transcript was told.
@MainActor
func runAgentSteeringRecoveryChecks() async throws -> String {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: "steering recovery: " + message) }
    }
    func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "steering recovery: " + message())
    }

    @MainActor
    final class Harness {
        let root: URL
        let bin: URL
        let supervisor: AgentSupervisor
        let id: AgentID
        var echoes: [String] = []
        var notices: [AgentLocalNotice] = []

        @MainActor
        init(_ kind: AgentSteeringQAFakes.Harness, grace: TimeInterval = 3) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("array-steering-recovery-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            try AgentSteeringQAFakes.install(kind, in: bin)
            let work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
            supervisor.interruptGrace = grace
            let (harness, model): (AgentHarness, String) = switch kind {
            case .claude: (.claudeCode, "anthropic/claude-haiku-4-5-20251001")
            case .codex: (.codex, "openai-codex/gpt-5.6-sol")
            case .pi: (.pi, "openai-codex/gpt-5.6-sol")
            }
            id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: model, thinking: "low")
            supervisor.addPromptEchoObserver(for: id) { [weak self] prompt in self?.echoes.append(prompt.text) }
            _ = supervisor.addLocalNoticeObserver(for: id) { [weak self] notice in self?.notices.append(notice) }
        }

        var frames: [[String: Any]] { AgentSteeringQAFakes.receivedFrames(in: bin) }
        var spawns: Int { AgentSteeringQAFakes.spawnCount(in: bin) }
        var promptTexts: [String] {
            frames.compactMap { frame in
                if frame["type"] as? String == "prompt" { return frame["message"] as? String }
                if frame["type"] as? String == "user", let message = frame["message"] as? [String: Any] {
                    return message["content"] as? String
                }
                return nil
            }
        }
        var piSteers: [String] {
            frames.filter { $0["type"] as? String == "steer" }.compactMap { $0["message"] as? String }
        }
        var rail: ComposerQueueRailState { supervisor.queueRailState(for: id) }

        @MainActor
        func tearDown() {
            supervisor.stopAll()
            try? FileManager.default.removeItem(at: root)
        }
    }

    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    defer { setenv("PATH", originalPath, 1) }
    func onPath(_ harness: Harness) { setenv("PATH", "\(harness.bin.path):\(originalPath)", 1) }
    // Every scenario runs, so one RED run names every failure.
    var failures: [String] = []
    func scenario(_ body: () async throws -> Void) async {
        do { try await body() } catch { failures.append(String(describing: error)) }
    }
    func bound(_ h: Harness) async throws {
        try await eventually("a runner must bind") { h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true }
    }

    // 1. ⌘↩ then Stop (B1). The second Stop lands while the force send's
    //    interrupt is in flight, which kills. The forced message must not run
    //    then, nor as a surprise after the next turn: it is the user's again,
    //    first in a paused queue, and the transcript says it was not sent. The
    //    next turn must still take a steer.
    await scenario {
        let h = try Harness(.pi)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("SLOW job", to: h.id), "B1: seed refused")
        try await bound(h)
        try await Task.sleep(for: .milliseconds(300))
        try expect(await h.supervisor.accept(.forceSend(AgentPrompt("FORCED message")), for: h.id) == .accepted, "B1: force send refused")
        try expect(await h.supervisor.accept(.stop, for: h.id) == .accepted, "B1: Stop refused")
        try await eventually("B1: Stop must end the turn") { !h.supervisor.isRunning(h.id) }
        try await Task.sleep(for: .milliseconds(1500))
        try expect(h.promptTexts == ["SLOW job"], "B1: the forced message must not run after Stop, prompts \(h.promptTexts)")
        try await eventually("B1: the forced message must be first in the queue, paused after Stop, got \(h.rail)") {
            h.rail.queued.map(\.text) == ["FORCED message"] && h.rail.pause == .afterStop
        }
        try expect(h.notices.contains { $0.title == "Not sent" },
                   "B1: the transcript must say the forced message was not sent, notices \(h.notices.map(\.title))")
        try expect(await h.supervisor.accept(.send("TOOL next"), for: h.id) == .accepted, "B1: the next send was refused")
        try await bound(h)
        try expect(await h.supervisor.accept(.steer(AgentPrompt("mid steer")), for: h.id) == .accepted, "B1: steer refused")
        try await eventually("B1: a steer during the next turn must be handed to pi, steers \(h.piSteers), rail \(h.rail)") {
            h.piSteers == ["mid steer"]
        }
        try await eventually("B1: the turns must run in the order the user sees them, prompts \(h.promptTexts)") {
            h.promptTexts == ["SLOW job", "TOOL next", "FORCED message"] && !h.supervisor.isRunning(h.id)
        }
    }

    // 2. Two ⌘↩ inside one interrupt (B2): both reach the provider, in order,
    //    on the same process.
    await scenario {
        let h = try Harness(.pi)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("SLOW job", to: h.id), "B2: seed refused")
        try await bound(h)
        try await Task.sleep(for: .milliseconds(300))
        try expect(await h.supervisor.accept(.forceSend(AgentPrompt("first force")), for: h.id) == .accepted, "B2: first force refused")
        try expect(await h.supervisor.accept(.forceSend(AgentPrompt("second force")), for: h.id) == .accepted, "B2: second force refused")
        try await eventually("B2: both forced messages must run, in order, prompts \(h.promptTexts)") {
            h.promptTexts == ["SLOW job", "first force", "second force"] && !h.supervisor.isRunning(h.id)
        }
        try expect(h.spawns == 1, "B2: force sends must not kill pi, spawned \(h.spawns)")
    }

    // 3. The deferred force send's timer token (c05dbe2f). A force send that
    //    ends a turn with steers still in delivery waits for their receipts,
    //    bounded by a grace timer. A timer armed for an EARLIER force send must
    //    not release a later one before its receipts: that would start the
    //    forced turn first and settle the unread steers as consumed.
    await scenario {
        let h = try Harness(.pi, grace: 4)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("SLOW job", to: h.id), "token: seed refused")
        try await bound(h)
        try expect(await h.supervisor.accept(.steer(AgentPrompt("steer one")), for: h.id) == .accepted, "token: steer one refused")
        try await eventually("token: steer one must be handed over") {
            h.supervisor.pendingSteers(for: h.id).map(\.state) == [.delivering]
        }
        try expect(await h.supervisor.accept(.forceSend(AgentPrompt("SLOW forced one")), for: h.id) == .accepted, "token: force one refused")
        try await eventually("token: the first forced message must start, prompts \(h.promptTexts)") {
            h.promptTexts == ["SLOW job", "SLOW forced one"] && h.supervisor.turnSnapshot(for: h.id)?.capabilities.canSteer == true
        }
        // The first force send's grace timer fires about 4 s after this point.
        let firstStarted = Date()
        try "3.0".write(to: h.bin.appendingPathComponent("clear-queue-delay"), atomically: true, encoding: .utf8)
        try expect(await h.supervisor.accept(.steer(AgentPrompt("steer two")), for: h.id) == .accepted, "token: steer two refused")
        try await eventually("token: both steers must be handed over in the forced turn, got \(h.supervisor.pendingSteers(for: h.id))") {
            h.supervisor.pendingSteers(for: h.id).map(\.state) == [.delivering, .delivering]
        }
        let wait = firstStarted.addingTimeInterval(1.5).timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        // Receipts for both steers now arrive ~3 s after this interrupt — after
        // the first timer, before this force send's own.
        try expect(await h.supervisor.accept(.forceSend(AgentPrompt("forced two")), for: h.id) == .accepted, "token: force two refused")
        try await eventually("token: the second forced message must run, prompts \(h.promptTexts)", timeout: 12) {
            h.promptTexts.last == "forced two" && !h.supervisor.isRunning(h.id)
        }
        try expect(!h.echoes.contains("steer one") && !h.echoes.contains("steer two"),
                   "token: steers pi never read must not be shown as sent, echoes \(h.echoes)")
        try await eventually("token: the unread steers must come back held, got \(h.rail)") {
            h.rail.steers.map(\.text) == ["steer one", "steer two"] && h.rail.steers.allSatisfy { $0.kind == .heldSteer }
        }
    }

    // 4. A kill while a steer is in delivery (B3): the dead process never read
    //    it, so it comes back held at the front of a paused queue, and the next
    //    send must not write it into the transcript as delivered.
    await scenario {
        let h = try Harness(.claude)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("HOLD job", to: h.id), "B3: seed refused")
        try await bound(h)
        try expect(await h.supervisor.accept(.steer(AgentPrompt("handed steer")), for: h.id) == .accepted, "B3: steer refused")
        try await eventually("B3: the steer must be handed to claude") {
            h.supervisor.pendingSteers(for: h.id).map(\.state) == [.delivering]
        }
        h.supervisor.stop(h.id)
        try await eventually("B3: the killed session's steer must come back held and the queue paused, got \(h.rail)") {
            h.rail.steers.map(\.text) == ["handed steer"] && h.rail.steers.map(\.kind) == [.heldSteer]
                && h.rail.pause == .afterStop
        }
        try expect(await h.supervisor.accept(.send("PLAIN after"), for: h.id) == .accepted, "B3: the next send was refused")
        try await eventually("B3: the next turn must start, prompts \(h.promptTexts)") { h.promptTexts.contains("PLAIN after") }
        try expect(!h.echoes.contains("handed steer"),
                   "B3: a steer the dead process never read must not be shown as sent, echoes \(h.echoes)")
    }

    // 5. A follow-up typed as the turn ends (B4): the turn closes between the
    //    queue's admission and its store write. The message must still run;
    //    nothing else is going to drain it.
    for (label, intent) in [("queue", AgentComposerIntent.queue(AgentPrompt("late follow-up"))),
                            ("steer", AgentComposerIntent.steer(AgentPrompt("late follow-up")))] { await scenario {
        let h = try Harness(.pi)
        defer { h.tearDown() }
        onPath(h)
        try expect(h.supervisor.send("PLAIN text", to: h.id), "B4 \(label): seed refused")
        try await bound(h)
        h.supervisor.qaAfterQueueAdmission = { [weak h] in
            guard let h else { return }
            while h.supervisor.isRunning(h.id) { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try expect(await h.supervisor.accept(intent, for: h.id) == .accepted, "B4 \(label): refused")
        h.supervisor.qaAfterQueueAdmission = nil
        try await eventually("B4 \(label): a message accepted as the turn ended must run, prompts \(h.promptTexts), rail \(h.rail)") {
            h.promptTexts == ["PLAIN text", "late follow-up"] && !h.supervisor.isRunning(h.id)
        }
    } }

    // 6. A paused rail holding only steers still offers Resume (B4/B9): a
    //    killed turn's returned steer must not leave a pause with no way out.
    await scenario {
        let rail = ComposerQueuedMessageRailView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var resumed = 0
        rail.onResume = { resumed += 1 }
        rail.setState(ComposerQueueRailState(
            steers: [.init(id: UUID(), text: "returned steer", attachmentCount: 0, kind: .heldSteer)],
            queued: [], pause: .afterStop))
        try expect(rail.qaResumeIsOffered, "rail: a paused rail with only steers must offer Resume, sections \(rail.qaSectionTitles)")
        try expect(rail.qaPressResume() && resumed == 1, "rail: Resume must reach the supervisor")
    }

    if !failures.isEmpty {
        throw Failure(description: "\(failures.count) scenario(s) failed:\n  - " + failures.joined(separator: "\n  - "))
    }
    return "⌘↩ then Stop returns the forced message to a paused queue with a Not sent notice and the next turn still steers; two force sends both run in order; an older grace timer cannot release a later force send before its steer receipts; a kill returns a delivering steer held and paused and never shows it as sent; a follow-up or steer accepted as the turn ends still runs; a steers-only pause offers Resume"
}
