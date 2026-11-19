import AppKit
import Foundation
import ContinuumRevivedCore

/// `--hidden-agent-ingest-check` — what a streaming agent nobody can see costs the
/// main thread, driven through the real supervisor with fake streaming runners.
///
/// 20 agents each stream 300 tokens at ~200/s. Run once with every agent
/// presented (the control) and once with 18 of the 20 hidden. Asserts, as
/// outcomes: a hidden agent crosses to main a handful of times a second and
/// spends a fraction of the control's delivery time, a reveal flushes at once,
/// and every agent's transcript is identical to its never-hidden counterpart.
@MainActor
enum HiddenAgentIngestChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static let agents = 20
    private static let hiddenCount = 18
    private static let tokens = 300

    private struct RunResult {
        var calls: [Int] = []
        var nanos: [UInt64] = []
        var transcripts: [String] = []
        var seconds: Double = 0
    }

    static func run() async throws {
        // RED reproduction: the delivery path as it was before the coalescer.
        if ProcessInfo.processInfo.environment["HIDDEN_INGEST_PASSTHROUGH"] == "1" { AgentEventCoalescer.qaPassThrough = true }
        let control = try await stream(hidden: 0)
        let hidden = try await stream(hidden: hiddenCount)
        let hiddenRange = 0..<hiddenCount
        let controlCalls = Double(control.calls[hiddenRange].reduce(0, +)) / Double(hiddenCount)
        let hiddenCalls = Double(hidden.calls[hiddenRange].reduce(0, +)) / Double(hiddenCount)
        let controlMs = Double(control.nanos[hiddenRange].reduce(0, +)) / 1e6
        let hiddenMs = Double(hidden.nanos[hiddenRange].reduce(0, +)) / 1e6
        let perSecond = hiddenCalls / hidden.seconds
        print(String(format: "hidden-agent-ingest: per hidden agent main deliveries control %.0f (%.0f/s) vs hidden %.0f (%.1f/s); delivery time for %d agents %.1f ms vs %.1f ms",
                     controlCalls, controlCalls / control.seconds, hiddenCalls, perSecond, hiddenCount, controlMs, hiddenMs))
        guard perSecond <= 12 else {
            throw Failure(description: "a hidden agent still crossed to main \(perSecond)/s (budget 12/s)")
        }
        guard hiddenMs < controlMs else {
            throw Failure(description: "hidden agents spent \(hiddenMs) ms in delivery vs \(controlMs) ms when presented; expected less")
        }
        for i in 0..<agents where hidden.transcripts[i] != control.transcripts[i] {
            let a = Array(hidden.transcripts[i]), b = Array(control.transcripts[i])
            let at = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            func around(_ x: [Character]) -> String { String(x[max(0, at - 120)..<min(x.count, at + 120)]) }
            throw Failure(description: "agent \(i) transcript differs after being hidden at \(at) (\(a.count) vs \(b.count) chars):\nhidden:  \(around(a))\ncontrol: \(around(b))")
        }
        try await checkRevealFlushes()
        try await checkHiddenSaveDebounce()
        try await checkQuitFinishesHiddenSave()
        print("hidden-agent-ingest: PASS")
    }

    private static func makeSupervisor(root: URL, runners: Runners) -> AgentSupervisor {
        AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
                        makeRunner: { launch in runners.make(for: launch.record.id) },
                        transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts")))
    }

    private final class Runners: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [AgentID: ScriptedAgentRunner] = [:]
        func make(for id: AgentID) -> ScriptedAgentRunner {
            lock.lock(); defer { lock.unlock() }
            if let existing = made[id] { return existing }
            let runner = ScriptedAgentRunner(
                script: [.turnStarted(threadId: "t", turnId: "turn"),
                         .itemStarted(threadId: "t", itemId: "msg", kind: .assistantMessage, title: nil)],
                holdUntilStopped: true)
            made[id] = runner
            return runner
        }
    }

    private static func pump(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private static func stream(hidden: Int) async throws -> RunResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidden-ingest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runners = Runners()
        let supervisor = makeSupervisor(root: root, runners: runners)
        defer { supervisor.stopAll() }
        supervisor.qaMeasureDeliver = true
        let config = AgentModelConfig.resolvedFromDefaults()
        var ids: [AgentID] = []
        for i in 0..<agents {
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
            ids.append(id)
            supervisor.setEventsPresented(i >= hidden, for: id)
            guard supervisor.send("go \(i)", to: id) else { throw Failure(description: "send refused for agent \(i)") }
        }
        let started = Date().addingTimeInterval(5)
        while Date() < started, !ids.allSatisfy({ runners.make(for: $0).runCount > 0 }) { await pump(0.01) }
        await pump(0.1)
        for id in ids { supervisor.qaDeliverNanos[id] = 0; supervisor.qaDeliverCalls[id] = 0 }
        let begin = Date()
        let tokens = Self.tokens
        let threads = ids.enumerated().map { i, id -> Thread in
            let runner = runners.make(for: id)
            let thread = Thread {
                for n in 0..<tokens {
                    _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "a\(i)w\(n) "))
                    Thread.sleep(forTimeInterval: 0.005)
                }
                _ = runner.emit(.itemCompleted(threadId: "t", itemId: "msg", kind: .assistantMessage, status: .completed))
                _ = runner.emit(.turnCompleted(threadId: "t", turnId: "turn", outcome: .completed, errorMessage: nil))
            }
            thread.start()
            return thread
        }
        while threads.contains(where: { !$0.isFinished }) { await pump(0.02) }
        let seconds = Date().timeIntervalSince(begin)
        await pump(0.6)
        var result = RunResult()
        result.seconds = seconds
        for id in ids {
            result.calls.append(supervisor.qaDeliverCalls[id] ?? 0)
            result.nanos.append(supervisor.qaDeliverNanos[id] ?? 0)
            let snapshot = supervisor.transcriptAttachment(for: id, reboundTo: "t").snapshot
            let entries = (snapshot?.document.entries ?? []).filter { $0.role != .user }
            let blocks = try entries.map { block -> String in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return String(decoding: try encoder.encode(block.blocks), as: UTF8.self)
            }
            // Revision counters count applied mutations, which batching legitimately changes.
            let joined = blocks.joined(separator: "\n")
                .replacingOccurrences(of: #""revision":\d+"#, with: "", options: .regularExpression)
            result.transcripts.append(joined)
            if result.transcripts.last?.contains("a\(ids.firstIndex(of: id)!)w\(tokens - 1)\"") != true {
                throw Failure(description: "agent \(ids.firstIndex(of: id)!) transcript is missing its last token; snapshot=\(snapshot == nil ? "nil" : "ok") entries=\(entries.count) tail=\(String(result.transcripts.last!.suffix(200)))")
            }
        }
        return result
    }

    private static func checkRevealFlushes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidden-ingest-reveal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runners = Runners()
        let supervisor = makeSupervisor(root: root, runners: runners)
        defer { supervisor.stopAll() }
        supervisor.qaMeasureDeliver = true
        let config = AgentModelConfig.resolvedFromDefaults()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
        guard supervisor.send("go", to: id) else { throw Failure(description: "reveal: send refused") }
        let runner = runners.make(for: id)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, runner.runCount == 0 { await pump(0.01) }
        await pump(0.1)
        let before = supervisor.qaDeliverCalls[id] ?? 0
        _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "held"))
        await pump(0.08)
        guard (supervisor.qaDeliverCalls[id] ?? 0) == before else {
            throw Failure(description: "reveal: a hidden agent's delta crossed to main within 80 ms")
        }
        supervisor.setEventsPresented(true, for: id)
        await pump(0.05)
        guard (supervisor.qaDeliverCalls[id] ?? 0) == before + 1 else {
            throw Failure(description: "reveal: revealing the agent did not deliver the held delta")
        }
    }

    private final class SaveCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A hidden agent's text arrives in 250 ms flushes; the 200 ms save debounce
    /// used to fire after each (about 4 whole-transcript writes a second). Asserts
    /// writes per second, and that a turn end and a reveal still write at once.
    private static func checkHiddenSaveDebounce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidden-ingest-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runners = Runners()
        let supervisor = makeSupervisor(root: root, runners: runners)
        defer { supervisor.stopAll() }
        let saves = SaveCounter()
        supervisor.qaBeforeTranscriptSave = { saves.bump() }
        let config = AgentModelConfig.resolvedFromDefaults()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
        guard supervisor.send("go", to: id) else { throw Failure(description: "save-debounce: send refused") }
        let runner = runners.make(for: id)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, runner.runCount == 0 { await pump(0.01) }
        await pump(0.3)
        let base = saves.value
        let seconds = 6.0, tokens = 120
        let begin = Date()
        for n in 0..<tokens {
            _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "w\(n) "))
            await pump(seconds / Double(tokens))
        }
        let streamed = saves.value - base
        let elapsed = Date().timeIntervalSince(begin)
        print(String(format: "hidden-agent-ingest: hidden streaming agent wrote %d transcripts in %.1f s (%.2f/s)", streamed, elapsed, Double(streamed) / elapsed))
        guard Double(streamed) <= elapsed / 2 + 1 else {
            throw Failure(description: "a hidden streaming agent wrote its transcript \(streamed) times in \(elapsed) s (budget one per 2 s)")
        }
        // Reveal: the pending write lands at once.
        let beforeReveal = saves.value
        _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "last "))
        await pump(0.4)
        supervisor.setEventsPresented(true, for: id)
        await pump(0.3)
        guard saves.value > beforeReveal else { throw Failure(description: "save-debounce: revealing the agent did not write the pending transcript") }
        // Turn end: written at once, whatever the window.
        supervisor.setEventsPresented(false, for: id)
        _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "tail"))
        await pump(0.4)
        let beforeEnd = saves.value
        _ = runner.emit(.itemCompleted(threadId: "t", itemId: "msg", kind: .assistantMessage, status: .completed))
        _ = runner.emit(.turnCompleted(threadId: "t", turnId: "turn", outcome: .completed, errorMessage: nil))
        await pump(0.5)
        guard saves.value > beforeEnd else { throw Failure(description: "save-debounce: a turn end did not write the transcript at once") }
        let snapshot = supervisor.transcriptAttachment(for: id, reboundTo: "t").snapshot
        let text = String(decoding: (try? JSONEncoder().encode(snapshot?.document.entries.map(\.blocks))) ?? Data(), as: UTF8.self)
        guard text.contains("tail"), text.contains("w\(tokens - 1) ") else {
            throw Failure(description: "save-debounce: final transcript is missing streamed text")
        }
    }

    /// The 2 s window means up to 2 s of a hidden agent's text is only in memory.
    /// Quit used to start that save in a task and exit, so the text was lost.
    /// Drives the quit's own entry (`finishTranscriptSavesForQuit`, which
    /// `applicationShouldTerminate` awaits) and then reads the disk at once, as
    /// an exiting process would: no run-loop turn may land the write afterwards.
    /// `CONTINUUM_QA_LEGACY_QUIT_TRANSCRIPT_FLUSH=1` is the RED reproduction.
    private static func checkQuitFinishesHiddenSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidden-ingest-quit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runners = Runners()
        let supervisor = makeSupervisor(root: root, runners: runners)
        defer { supervisor.stopAll() }
        let saves = SaveCounter()
        supervisor.qaBeforeTranscriptSave = { saves.bump() }
        let config = AgentModelConfig.resolvedFromDefaults()
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking)
        guard supervisor.send("go", to: id) else { throw Failure(description: "quit-save: send refused") }
        let runner = runners.make(for: id)
        let started = Date().addingTimeInterval(5)
        while Date() < started, runner.runCount == 0 { await pump(0.01) }
        // Stream until one window's save has run, so the marker opens a fresh 2 s window.
        let before = saves.value
        var n = 0
        let windowEnd = Date().addingTimeInterval(6)
        while Date() < windowEnd, saves.value == before {
            _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "q\(n) "))
            n += 1
            await pump(0.05)
        }
        guard saves.value > before else { throw Failure(description: "quit-save: the hidden agent never saved within 6 s") }
        await pump(0.3)
        let marker = "quitmarker\(UInt32.random(in: 1_000_000...9_999_999))"
        _ = runner.emit(.contentDelta(threadId: "t", turnId: "turn", streamKind: .assistant, delta: "\(marker) "))
        await pump(0.5)
        let transcripts = root.appendingPathComponent("transcripts")
        func onDisk() -> Bool {
            let files = FileManager.default.enumerator(at: transcripts, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
            return files.contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains(marker) == true }
        }
        guard !onDisk() else { throw Failure(description: "quit-save: the marker was already on disk; the fixture did not leave a save pending") }
        let quitStart = DispatchTime.now().uptimeNanoseconds
        let landed = await supervisor.finishTranscriptSavesForQuit()
        let quitMs = Double(DispatchTime.now().uptimeNanoseconds - quitStart) / 1e6
        let saved = onDisk()
        print(String(format: "hidden-agent-ingest: quit with a pending hidden save waited %.0f ms; text on disk at exit: %@", quitMs, saved ? "yes" : "no"))
        guard saved, landed else {
            throw Failure(description: "quit-save: a hidden agent's last text was not on disk when quit returned (pending 2 s window lost)")
        }
        guard quitMs < 2_500 else { throw Failure(description: "quit-save: quit waited \(quitMs) ms (bound 2 s)") }
    }
}
