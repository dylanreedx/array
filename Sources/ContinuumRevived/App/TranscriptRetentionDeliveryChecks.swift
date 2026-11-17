import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A helper turn's completion is delivered with its own identity and content,
/// whatever happens to the released transcript it ends behind. Driven through
/// the production send, runner, settlement, hold, flush and wake paths: the
/// lead's runner records every prompt and steer it is actually given, and each
/// message handle's result file is read as the lead would read it.
///
/// Cases: an ordinary turn, a reload that arrives late, a timeout followed by
/// a late successful reload, a background hold that a deferred completion
/// would create under the next turn, and an archive that can never be read.
@MainActor
enum TranscriptRetentionDeliveryChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            guard !opened else { return }
            opened = true
            let queued = waiters
            waiters.removeAll()
            queued.forEach { $0.resume() }
        }
    }

    private typealias Runner = HelperCompletionChecks.HeldWakeRunner

    @MainActor private final class Fixture {
        let root: URL
        let s: AgentSupervisor
        let lead: AgentID
        let helper: AgentID
        let leadRunner: Runner
        let helperRunner: Runner
        let transcriptRoot: URL
        var now = Date()
        private var operations = 0

        init(_ root: URL) throws {
            self.root = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = AgentCatalogQAFixture.pi[0]
            let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
            lead = AgentID(rawValue: UUID()); helper = AgentID(rawValue: UUID())
            var leadRecord = AgentRecord(id: lead, displayName: "Delivery lead", harness: .pi, model: model, thinking: "medium",
                cwd: root.path, createdAt: Date(), lastActivityAt: Date())
            leadRecord.workspaceToolsEnabled = true
            try store.upsert(leadRecord)
            var helperRecord = AgentRecord(id: helper, displayName: "Courier", harness: .pi, model: model, thinking: "medium",
                cwd: root.path, parentAgentID: lead, createdAt: Date(), lastActivityAt: Date())
            helperRecord.spawnResultHandle = "spawn-courier"
            try store.upsert(helperRecord)
            SpawnResultFile.write(.init(toolCallId: "spawn-courier", status: .spawned, agentId: helper.rawValue,
                recipientId: lead.rawValue), parentCwd: root.path, warn: { _ in })
            leadRunner = Runner(autoEnd: true); helperRunner = Runner(autoEnd: false)
            let pool: [AgentID: Runner] = [lead: leadRunner, helper: helperRunner]
            transcriptRoot = root.appendingPathComponent("transcripts", isDirectory: true)
            s = AgentSupervisor(store: store, makeRunner: { pool[$0.record.id]! }, warn: { _ in },
                nameTitlerCommand: { _ in nil },
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root.appendingPathComponent("drafts")),
                transcriptStore: AgentTranscriptStore(root: transcriptRoot), maximumActiveManagedChildren: { nil })
            _ = s.restore()
            s.helperCompletionNow = { [unowned self] in self.now }
        }

        /// Every result the lead's model was handed from the helper.
        func results() -> [String] {
            (leadRunner.prompts + leadRunner.steers).flatMap { text -> [AgentMessagePayload] in
                switch AgentMessageEnvelope.classify(text) {
                case .agentMessage(let payload): return [payload]
                case .agentMessages(let batch): return batch
                default: return []
                }
            }.filter { $0.senderAgentID == helper.rawValue && $0.text.split(separator: "\n").first?.contains(" finished: ") == true }
            .map(\.text)
        }
        func result(_ handle: String) -> SpawnResultFile? { SpawnResultFile.read(parentCwd: root.path, handle: handle) }

        func settleLead() async {
            for _ in 0..<2 {
                _ = await waitUntil(timeout: 5, pollInterval: 0.02) {
                    !self.s.isRunning(self.lead) && self.s.queuedMessages(for: self.lead).allSatisfy(\.helperNote)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        /// Past the eight-second batch hold, then until the idle lead drains.
        func flushToLead() async {
            now.addTimeInterval(9)
            await s.flushHelperCompletions()
            await settleLead()
        }

        /// The lead messages the helper through the production send; the
        /// operation id is the handle its result is written under.
        @discardableResult
        func message(_ text: String, waitForStart: Bool = true) async throws -> String {
            operations += 1
            let handle = "op-\(operations)"
            let context = AgentMessageQueueContext(caller: lead, recipient: helper, operationId: handle,
                idempotencyKey: "key-\(operations)", payloadHash: "hash-\(operations)")
            let delivery = s.deliverAgentMessage(text, from: lead, to: helper, hops: 1, context: context).delivery
            guard delivery == .delivered else { throw Failure(description: "the helper did not take \(handle) directly: \(delivery)") }
            if waitForStart, !(await waitUntil(timeout: 5, pollInterval: 0.02, { self.helperRunner.openTurns == 1 })) {
                throw Failure(description: "the helper's turn for \(handle) did not start")
            }
            return handle
        }
        func fail(_ error: String) async throws {
            helperRunner.fail(error)
            guard await waitUntil(timeout: 5, pollInterval: 0.02, { !self.s.isRunning(self.helper) && self.helperRunner.openTurns == 0 }) else {
                throw Failure(description: "the helper's failed turn did not end")
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        func end(_ text: String) async throws {
            helperRunner.end(saying: text)
            guard await waitUntil(timeout: 5, pollInterval: 0.02, { !self.s.isRunning(self.helper) && self.helperRunner.openTurns == 0 }) else {
                throw Failure(description: "the helper's turn did not end")
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        /// Turn A answers FIRST_ANSWER and is delivered; then the helper's
        /// transcript is released, so A's reply is what the released summary holds.
        func firstTurnThenRelease() async throws {
            guard s.send("Do the first task.", to: helper) else { throw Failure(description: "the helper refused its first task") }
            guard await waitUntil(timeout: 5, pollInterval: 0.02, { self.helperRunner.openTurns == 1 }) else {
                throw Failure(description: "the first turn did not start")
            }
            let previousDelay = AgentSupervisor.transcriptReleaseDelay
            AgentSupervisor.transcriptReleaseDelay = .zero
            defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }
            try await end("FIRST_ANSWER")
            await flushToLead()
            guard results().count == 1, results()[0].contains("FIRST_ANSWER") else {
                throw Failure(description: "turn A was not delivered once: \(results())")
            }
            guard await waitUntil(timeout: 10, pollInterval: 0.02, { self.s.isTranscriptReleased(self.helper) }) else {
                throw Failure(description: "the helper's transcript did not release after turn A")
            }
        }

        func damageArchive() throws {
            let agentRoot = transcriptRoot.appendingPathComponent(helper.rawValue.uuidString)
            guard let snapshot = FileManager.default.enumerator(at: agentRoot, includingPropertiesForKeys: nil)?
                .allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
                throw Failure(description: "no archive to damage")
            }
            try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent().appendingPathComponent("backups"))
            try Data("unreadable".utf8).write(to: snapshot)
        }
    }

    private static func fixture(_ root: URL, _ name: String) throws -> Fixture {
        try Fixture(root.appendingPathComponent("delivery-\(name)", isDirectory: true))
    }

    /// A pushed result must be this turn's: its own answer, never turn A's.
    private static func check(_ results: [String], index: Int, has answer: String?, _ label: String) -> String? {
        guard results.indices.contains(index) else { return "\(label): no result \(index + 1) was pushed (\(results.count) pushed)" }
        let text = results[index]
        if text.contains("FIRST_ANSWER") { return "\(label): the pushed result carried turn A's FIRST_ANSWER: \(text)" }
        if let answer, !text.contains(answer) { return "\(label): the pushed result lacked \(answer): \(text)" }
        return nil
    }

    // MARK: Cases

    static func runNormal(root: URL) async throws {
        let f = try fixture(root, "normal")
        defer { f.s.stopAll() }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        try await f.firstTurnThenRelease()
        let handle = try await f.message("Do task B.")
        try await f.end("ANSWER_B")
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { f.result(handle)?.status == .completed })
        await f.flushToLead()
        var failures: [String] = []
        if f.result(handle)?.finalText?.contains("ANSWER_B") != true { failures.append("handle B: \(String(describing: f.result(handle)?.finalText))") }
        if f.results().count != 2 { failures.append("\(f.results().count) results pushed, not 2") }
        if let issue = check(f.results(), index: 1, has: "ANSWER_B", "turn B") { failures.append(issue) }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    static func runLateReload(root: URL) async throws {
        let f = try fixture(root, "late-reload")
        let gate = Gate()
        defer { f.s.qaBeforeResumedTranscriptConstruction = nil; f.s.stopAll() }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        try await f.firstTurnThenRelease()
        f.s.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() }
        let handle = try await f.message("Do task B.")
        try await f.end("ANSWER_B")
        await f.flushToLead()
        var failures: [String] = []
        if let early = f.result(handle), early.status != .spawned { failures.append("handle B settled before its events were applied: \(early.finalText ?? "no text")") }
        if f.results().count != 1 { failures.append("a result was pushed while B's events were held: \(f.results())") }
        await gate.open()
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { f.result(handle)?.status == .completed })
        await f.flushToLead()
        if f.result(handle)?.finalText?.contains("ANSWER_B") != true { failures.append("handle B: \(String(describing: f.result(handle)?.finalText))") }
        if f.results().count != 2 { failures.append("\(f.results().count) results pushed, not 2") }
        if let issue = check(f.results(), index: 1, has: "ANSWER_B", "turn B") { failures.append(issue) }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    /// The bound expires while the reload is blocked; then the reload succeeds.
    /// One failure is delivered, with no reply, and nothing arrives again.
    static func runTimeoutThenLateReload(root: URL) async throws {
        try await runUnavailable(root: root, name: "timeout", damage: false)
    }

    /// The archive can never be read: the bound delivers one failure, no reply.
    static func runUnreadableArchive(root: URL) async throws {
        try await runUnavailable(root: root, name: "unreadable", damage: true)
    }

    private static func runUnavailable(root: URL, name: String, damage: Bool) async throws {
        let f = try fixture(root, name)
        let gate = Gate()
        let previousBound = AgentSupervisor.transcriptCompletionBound
        AgentSupervisor.transcriptCompletionBound = .seconds(2)
        defer {
            AgentSupervisor.transcriptCompletionBound = previousBound
            f.s.qaBeforeResumedTranscriptConstruction = nil
            f.s.stopAll()
        }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        try await f.firstTurnThenRelease()
        if damage { try f.damageArchive() } else { f.s.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() } }
        let handle = try await f.message("Do task B.")
        try await f.end("ANSWER_B")
        var failures: [String] = []
        guard await waitUntil(timeout: 10, pollInterval: 0.05, { (f.result(handle)?.status ?? .spawned) != .spawned }) else {
            throw Failure(description: "\(name): handle B never settled within the bound")
        }
        await f.flushToLead()
        let settled = f.result(handle)
        if settled?.status != .failed || settled?.finalText != nil || (settled?.reason ?? "").isEmpty {
            failures.append("\(name): handle B settled as \(settled?.status.rawValue ?? "?") / \(settled?.finalText ?? "no text") / \(settled?.reason ?? "no reason"), not a textless failure naming the cause")
        }
        if f.results().count != 2 { failures.append("\(name): \(f.results().count) results pushed after the bound, not 2") }
        if let issue = check(f.results(), index: 1, has: nil, "\(name) turn B") { failures.append(issue) }
        if f.results().count > 1, !f.results()[1].contains(" finished: failed") { failures.append("\(name): the pushed result is not a failure: \(f.results()[1])") }
        // The reload now succeeds (or keeps failing); nothing is delivered again.
        await gate.open()
        if !damage {
            _ = await waitUntil(timeout: 10, pollInterval: 0.02, { !f.s.isTranscriptReleased(f.helper) })
            if f.s.isTranscriptReleased(f.helper) { failures.append("\(name): the late reload never finished") }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await f.flushToLead()
        await f.flushToLead()
        if f.results().count != 2 { failures.append("\(name): after the late reload \(f.results().count) results were pushed, not 2: \(f.results())") }
        if let issue = check(f.results(), index: 1, has: nil, "\(name) turn B after reload") { failures.append(issue) }
        if f.result(handle)?.status != .failed || f.result(handle)?.finalText != nil {
            failures.append("\(name): handle B was rewritten after the late reload: \(String(describing: f.result(handle)?.finalText))")
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    /// B ends while its reload is blocked; C is accepted and starts with
    /// background work; B's deferred completion runs under C; C's background
    /// ends while C is still running, past the grace; then C ends.
    static func runHoldUnderLaterTurn(root: URL) async throws {
        let f = try fixture(root, "hold")
        let gate = Gate()
        defer { f.s.qaBeforeResumedTranscriptConstruction = nil; f.s.stopAll() }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        try await f.firstTurnThenRelease()
        f.s.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() }
        let handleB = try await f.message("Do task B.")
        try await f.end("ANSWER_B")
        let handleC = try await f.message("Do task C.")
        f.helperRunner.background = true
        await gate.open()
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { !f.s.isTranscriptReleased(f.helper) })
        try? await Task.sleep(nanoseconds: 200_000_000)
        // C's background job ends while C's own turn keeps running.
        f.helperRunner.background = false
        f.s.sweepHeldHelperCompletions()
        f.now.addTimeInterval(f.s.heldBackgroundGrace + 1)
        f.s.sweepHeldHelperCompletions()
        try? await Task.sleep(nanoseconds: 100_000_000)
        var failures: [String] = []
        if f.result(handleC).map({ $0.status != .spawned }) == true {
            failures.append("handle C settled while C was still running: \(f.result(handleC)?.finalText ?? "no text")")
        }
        try await f.end("ANSWER_C")
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { f.result(handleC)?.status == .completed })
        await f.flushToLead()
        await f.flushToLead()
        let b = f.result(handleB)?.finalText ?? "nothing", c = f.result(handleC)?.finalText ?? "nothing"
        if !b.contains("ANSWER_B") || b.contains("ANSWER_C") { failures.append("handle B settled with \(b)") }
        if !c.contains("ANSWER_C") { failures.append("handle C settled with \(c)") }
        let pushed = f.results()
        if pushed.count != 3 { failures.append("\(pushed.count) results pushed, not 3 (A, B, C): \(pushed)") }
        if pushed.filter({ $0.contains("ANSWER_B") }).count != 1 { failures.append("turn B was not pushed exactly once with its answer: \(pushed)") }
        if pushed.filter({ $0.contains("ANSWER_C") }).count != 1 { failures.append("turn C was not pushed exactly once with its answer: \(pushed)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    /// C files its report while B's completion still waits on the reload: B's
    /// result and wake carry no report of C's, and C's carry its own.
    static func runLaterReport(root: URL) async throws {
        let f = try fixture(root, "later-report")
        let gate = Gate()
        defer { f.s.qaBeforeResumedTranscriptConstruction = nil; f.s.stopAll() }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        try await f.firstTurnThenRelease()
        f.s.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() }
        let handleB = try await f.message("Do task B.")
        guard f.s.fileReport(.init(summary: "REPORT_B"), for: f.helper) else { throw Failure(description: "B's report was refused") }
        try await f.end("ANSWER_B")
        let handleC = try await f.message("Do task C.")
        guard f.s.fileReport(.init(summary: "REPORT_C"), for: f.helper) else { throw Failure(description: "C's report was refused") }
        await gate.open()
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { (f.result(handleB)?.status ?? .spawned) != .spawned })
        try await f.end("ANSWER_C")
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { f.result(handleC)?.status == .completed })
        await f.flushToLead()
        await f.flushToLead()
        var failures: [String] = []
        if f.result(handleB)?.report?.summary != "REPORT_B" { failures.append("handle B carried \(f.result(handleB)?.report?.summary ?? "no report"), not its own REPORT_B") }
        if f.result(handleC)?.report?.summary != "REPORT_C" { failures.append("handle C carried \(f.result(handleC)?.report?.summary ?? "no report"), not its own REPORT_C") }
        let pushed = f.results()
        if pushed.filter({ $0.contains("REPORT_B") && !$0.contains("REPORT_C") }).count != 1 {
            failures.append("turn B's own report was not pushed exactly once: \(pushed)")
        }
        if pushed.filter({ $0.contains("REPORT_C") }).count != 1 { failures.append("C's report was not pushed exactly once: \(pushed)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    /// A turn after A fails before saying anything (a quota or no-result exit):
    /// its result and wake say it has no reply and never carry A's. Resident,
    /// and released with a reload that succeeds.
    static func runNoOutputTurn(root: URL) async throws {
        var failures: [String] = []
        for released in [false, true] {
            let name = released ? "released" : "resident"
            let f = try fixture(root, "no-output-\(name)")
            defer { f.s.stopAll() }
            AgentSupervisor.transcriptReleaseDelay = .seconds(60)
            if released { try await f.firstTurnThenRelease() }
            else {
                _ = try await f.message("Do task A.")
                try await f.end("FIRST_ANSWER")
                await f.flushToLead()
            }
            let handle = try await f.message("Do task B.")
            try await f.fail("quota exceeded")
            _ = await waitUntil(timeout: 10, pollInterval: 0.02, { (f.result(handle)?.status ?? .spawned) != .spawned })
            await f.flushToLead()
            let result = f.result(handle)
            if result?.status != .failed || result?.finalText != nil {
                failures.append("\(name): handle B settled as \(result?.status.rawValue ?? "nothing") with \(result?.finalText ?? "no text")")
            }
            let pushed = f.results()
            if pushed.count != 2 { failures.append("\(name): \(pushed.count) results pushed, not 2: \(pushed)") }
            else if pushed[1].contains("FIRST_ANSWER") || !pushed[1].contains("quota exceeded")
                        || !pushed[1].contains("(no reply this turn)") {
                failures.append("\(name): turn B pushed \(pushed[1])")
            }
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    /// B is held (background work, no report). Its background ends; C is
    /// accepted but its provider has not started; the grace passes. B's hold
    /// must not consume C's handle; C settles with its own answer, pushed once.
    static func runHoldBeforeNextStart(root: URL) async throws {
        let f = try fixture(root, "hold-before-start")
        defer { f.helperRunner.releaseStart(); f.s.stopAll() }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        let handleB = try await f.message("Do task B.")
        f.helperRunner.background = true
        try await f.end("ANSWER_B")
        await f.flushToLead()
        guard f.s.isHelperCompletionHeld(f.helper) else { throw Failure(description: "B was not held") }
        f.helperRunner.background = false
        f.s.sweepHeldHelperCompletions()
        f.helperRunner.holdNextStart()
        let handleC = try await f.message("Do task C.", waitForStart: false)
        f.now.addTimeInterval(f.s.heldBackgroundGrace + 1)
        f.s.sweepHeldHelperCompletions()
        f.now.addTimeInterval(f.s.heldHelperCompletionCap + 1)
        f.s.sweepHeldHelperCompletions()
        try? await Task.sleep(nanoseconds: 150_000_000)
        var failures: [String] = []
        if let early = f.result(handleC), early.status != .spawned {
            failures.append("handle C settled before C started, with \(early.finalText ?? "no text")")
        }
        f.helperRunner.releaseStart()
        guard await waitUntil(timeout: 5, pollInterval: 0.02, { f.helperRunner.openTurns == 1 }) else {
            throw Failure(description: "C's turn never started")
        }
        try await f.end("ANSWER_C")
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { f.result(handleC)?.status == .completed })
        await f.flushToLead()
        await f.flushToLead()
        if f.result(handleC)?.finalText?.contains("ANSWER_C") != true { failures.append("handle C settled with \(f.result(handleC)?.finalText ?? "nothing")") }
        if (f.result(handleB)?.status ?? .spawned) == .spawned { failures.append("handle B never settled") }
        let pushed = f.results()
        if pushed.filter({ $0.contains("ANSWER_C") }).count != 1 { failures.append("C was not pushed exactly once: \(pushed)") }
        if pushed.filter({ $0.contains("ANSWER_B") }).count > 1 { failures.append("B was pushed more than once: \(pushed)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    /// B ends behind a reload, replays into a real hold, then files a report
    /// between turns: the release carries that report on both channels.
    static func runDeferredHoldReport(root: URL) async throws {
        let f = try fixture(root, "deferred-hold-report")
        let gate = Gate()
        defer { f.s.qaBeforeResumedTranscriptConstruction = nil; f.s.stopAll() }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        try await f.firstTurnThenRelease()
        f.s.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() }
        let handleB = try await f.message("Do task B.")
        f.helperRunner.background = true
        try await f.end("ANSWER_B")
        await gate.open()
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { f.s.isHelperCompletionHeld(f.helper) })
        guard f.s.isHelperCompletionHeld(f.helper) else { throw Failure(description: "B was not held after its reload") }
        f.helperRunner.background = false
        guard f.s.fileReport(.init(summary: "REPORT_LATE"), for: f.helper) else { throw Failure(description: "the late report was refused") }
        _ = await waitUntil(timeout: 10, pollInterval: 0.02, { (f.result(handleB)?.status ?? .spawned) != .spawned })
        await f.flushToLead()
        var failures: [String] = []
        if f.result(handleB)?.report?.summary != "REPORT_LATE" { failures.append("handle B carried \(f.result(handleB)?.report?.summary ?? "no report")") }
        if f.results().filter({ $0.contains("REPORT_LATE") }).count != 1 { failures.append("the late report was not pushed once: \(f.results())") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    static func run(root: URL) async throws {
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }
        let model = AgentCatalogQAFixture.pi[0]
        let previousCatalog = AgentModelCatalog.shared.snapshot(for: .pi)
        defer { AgentModelCatalog.shared.resetForQA(snapshot: previousCatalog) }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready,
            models: [model], displayNames: [:], refreshedAt: Date()))
        var failures: [String] = []
        let cases: [(String, (URL) async throws -> Void)] = [
            ("normal turn", runNormal), ("late reload", runLateReload),
            ("timeout then late reload", runTimeoutThenLateReload),
            ("hold under a later turn", runHoldUnderLaterTurn), ("unreadable archive", runUnreadableArchive),
            ("later report", runLaterReport), ("no-output turn", runNoOutputTurn),
            ("hold before the next start", runHoldBeforeNextStart), ("deferred hold report", runDeferredHoldReport),
        ]
        for (label, body) in cases {
            do { try await body(root); print("retention delivery: \(label) PASS") }
            catch { print("retention delivery: \(label) FAIL: \(error)"); failures.append("\(label): \(error)") }
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }
}
