import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-transcript-publisher-perf-check`: what one streaming tick of
/// the host's transcript publisher costs the main thread on a long transcript,
/// and that moving its work off the main thread changed nothing it sends.
///
/// A production supervisor holds ~1,100 entries (~500 KB encoded) per agent;
/// one, then three, shared agents stream an assistant reply while their real
/// publishers tick. The sink is a counter, so the time is the publisher's own.
/// Time is the main thread's own CPU time across the tick, not elapsed time:
/// work moved to another thread no longer counts, work left on main does.
///
/// Budget: a streaming patch costs under 4 ms of main-thread time at p95, and a
/// checkpoint under one 60 Hz frame. Before the move a patch cost ~7 ms and a
/// checkpoint ~160 ms.
///
/// Parity: the same supervisor feeds a reference publisher that plans on the
/// main actor with the supervisor's synchronous tool-detail walk, the path every
/// publish took before. Both are ticked at the same document states; every
/// checkpoint and frame must be byte-identical and in sequence. Then the
/// document keeps changing while the off-main publisher is mid-tick, and once
/// streaming stops its guest mirror must hold what the reference's does.
@MainActor
enum SharedAgentTranscriptPublisherPerfChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    static let patchBudgetMilliseconds = 4.0
    static let checkpointBudgetMilliseconds = 16.7

    final class CountingSink: SharedAgentTranscriptSink {
        var checkpoints = 0, frames = 0, bytes = 0
        func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                     frames: [Collaboration.AgentTranscript.Frame]) async throws {
            if let checkpoint { checkpoints += 1; bytes += checkpoint.body.count }
            self.frames += frames.count; bytes += frames.reduce(0) { $0 + $1.body.count }
        }
    }

    /// Records what reached the "relay", enforces its sequencing, and applies
    /// it to a guest mirror the way the guest view does.
    final class RecordingSink: SharedAgentTranscriptSink {
        enum Published: Equatable { case checkpoint(through: UInt64, body: Data), frame(sequence: UInt64, body: Data) }
        var log: [Published] = []
        var mirror = SharedAgentTranscriptWire.Mirror()
        var head: UInt64 = 0
        var failure: String?
        func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                     frames: [Collaboration.AgentTranscript.Frame]) async throws {
            do {
                if let checkpoint {
                    if checkpoint.through != head + 1 { fail("checkpoint through \(checkpoint.through) after \(head)") }
                    head = checkpoint.through; log.append(.checkpoint(through: checkpoint.through, body: checkpoint.body))
                    _ = try mirror.install(SharedAgentTranscriptWire.decode(SharedAgentTranscriptWire.Checkpoint.self, from: checkpoint.body))
                }
                for frame in frames {
                    if frame.sequence != head + 1 { fail("frame \(frame.sequence) after \(head)") }
                    head = frame.sequence; log.append(.frame(sequence: frame.sequence, body: frame.body))
                    _ = try mirror.apply(SharedAgentTranscriptWire.decode(SharedAgentTranscriptWire.Patch.self, from: frame.body))
                }
            } catch { fail("the guest mirror refused what was published: \(error)") }
        }
        private func fail(_ message: String) { if failure == nil { failure = message } }
    }

    static func run() async throws {
        var failures: [String] = []
        for agents in [1, 3] {
            do { try await measure(agents: agents) } catch { failures.append("\(error)") }
        }
        do { try await parity() } catch { failures.append("\(error)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\nFAIL: ")) }
        print("PASS: shared agent transcript publisher stays inside its main-thread budget and publishes what it did on main")
    }

    /// The calling thread's CPU time. Every caller here is on the main thread.
    private static func mainThreadCPU() -> Duration {
        precondition(Thread.isMainThread)
        return .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    private static func percentile(_ xs: [Duration], _ p: Int) -> Double {
        let sorted = xs.map(ms).sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * p / 100)]
    }
    private static func stats(_ xs: [Duration]) -> String {
        guard !xs.isEmpty else { return "n=0" }
        return String(format: "n=%d median=%.3fms p95=%.3fms max=%.3fms", xs.count, percentile(xs, 50), percentile(xs, 95),
                      xs.map(ms).max()!)
    }

    private struct Fixture {
        let root: URL
        let supervisor: AgentSupervisor
        let ids: [AgentID]
    }

    /// History: finished turns of reasoning, a command and a reply, to `entries` per agent.
    private static func fixture(agents count: Int, entries: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-perf-\(UUID().uuidString)")
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID()
        let ids = (0..<count).map { _ in AgentID(rawValue: UUID()) }
        for id in ids {
            try store.upsert(AgentRecord(id: id, displayName: "Long", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                         thinking: "none", cwd: root.path, projectId: project, createdAt: Date(), lastActivityAt: Date()))
        }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        let prose = "Checkout state validates. "
        for id in ids {
            let thread = AgentSupervisor.threadId(for: id)
            var turn = 0
            while (supervisor.transcriptDocument(for: id)?.entries.count ?? 0) < entries {
                turn += 1
                let t = "h\(turn)"
                supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: id)
                supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .reasoning, delta: prose), to: id)
                supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n state Sources/Checkout"), to: id)
                supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: .completed), to: id)
                supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: prose + prose), to: id)
                supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: id)
            }
        }
        let fixture = Fixture(root: root, supervisor: supervisor, ids: ids)
        try await settle(fixture)
        return fixture
    }

    private static func measure(agents count: Int) async throws {
        let fixture = try await fixture(agents: count, entries: 1_100)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (supervisor, ids) = (fixture.supervisor, fixture.ids)
        guard let sample = supervisor.transcriptDocument(for: ids[0]) else { throw Failure(description: "no document") }
        let docBytes = try SharedAgentTranscriptWire.encode(sample.entries).count

        let sink = CountingSink()
        let publishers = ids.map { SharedAgentTranscriptPublisher(supervisor: supervisor, agent: $0, generation: 1, sink: sink) }
        var checkpointTimes: [Duration] = []
        for publisher in publishers {
            let before = mainThreadCPU()
            await publisher.tick()
            checkpointTimes.append(mainThreadCPU() - before)
        }

        // Stream: one assistant delta per agent per tick, as a 250 ms tick sees.
        for (n, id) in ids.enumerated() {
            supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "live\(n)"), to: id)
        }
        var patchTicks: [Duration] = [], recheckpointTicks: [Duration] = [], perRound: [Duration] = []
        for round in 0..<120 {
            for (n, id) in ids.enumerated() {
                supervisor.qaDeliver(.contentDelta(threadId: AgentSupervisor.threadId(for: id), turnId: "live\(n)", streamKind: .assistant,
                                                   delta: "Round \(round): the next state is authorising, then paid or declined. "), to: id)
            }
            var roundTotal: Duration = .zero
            for publisher in publishers {
                let checkpointsBefore = publisher.checkpoints
                let before = mainThreadCPU()
                await publisher.tick()
                let spent = mainThreadCPU() - before
                roundTotal += spent
                if publisher.checkpoints == checkpointsBefore { patchTicks.append(spent) } else { recheckpointTicks.append(spent) }
            }
            perRound.append(roundTotal)
        }
        try expect(publishers.allSatisfy({ $0.lastError == nil }), "a publish failed: \(String(describing: publishers.first?.lastError))")
        try expect(sink.frames >= 100 * count, "only \(sink.frames) frames for \(count) agent(s) over 120 streaming ticks")

        print("METRIC publisher-perf agents=\(count) entries=\(sample.entries.count) documentBytes=\(docBytes) window=\(publishers[0].published.count)")
        print("METRIC publisher-perf agents=\(count) main-thread first-checkpoint \(stats(checkpointTimes))")
        print("METRIC publisher-perf agents=\(count) main-thread patch-tick \(stats(patchTicks))")
        print("METRIC publisher-perf agents=\(count) main-thread re-checkpoint-tick \(stats(recheckpointTicks))")
        print("METRIC publisher-perf agents=\(count) main-thread all-agents-per-250ms \(stats(perRound)) frames=\(sink.frames) checkpoints=\(sink.checkpoints) bytes=\(sink.bytes)")
        let patchP95 = percentile(patchTicks, 95)
        try expect(patchP95 < patchBudgetMilliseconds, String(format:
            "agents=%d: a streaming patch costs %.3f ms of main-thread time at p95, over the %.1f ms budget", count, patchP95, patchBudgetMilliseconds))
        let checkpointMax = (checkpointTimes + recheckpointTicks).map(ms).max() ?? 0
        try expect(checkpointMax < checkpointBudgetMilliseconds, String(format:
            "agents=%d: a checkpoint costs %.3f ms of main-thread time, over one %.1f ms frame", count, checkpointMax, checkpointBudgetMilliseconds))
    }

    /// What differs between two published items, for a failure message.
    private static func difference(_ a: RecordingSink.Published?, _ b: RecordingSink.Published?) -> String {
        typealias Wire = SharedAgentTranscriptWire
        switch (a, b) {
        case let (.checkpoint(t1, b1)?, .checkpoint(t2, b2)?):
            guard let c1 = try? Wire.decode(Wire.Checkpoint.self, from: b1), let c2 = try? Wire.decode(Wire.Checkpoint.self, from: b2) else { return "undecodable" }
            let firstEntry = Array(zip(c1.entries, c2.entries)).firstIndex { $0.0 != $0.1 }
            return "checkpoint through \(t1)/\(t2) entries \(c1.entries.count)/\(c2.entries.count) omitted \(c1.omittedEntries)/\(c2.omittedEntries) "
                + "details \(c1.toolDetails.count)/\(c2.toolDetails.count) equal=\(c1.toolDetails == c2.toolDetails) helpers equal=\(c1.helpers == c2.helpers) firstEntryDiff=\(String(describing: firstEntry))"
        case let (.frame(s1, b1)?, .frame(s2, b2)?):
            guard let p1 = try? Wire.decode(Wire.Patch.self, from: b1), let p2 = try? Wire.decode(Wire.Patch.self, from: b2) else { return "undecodable" }
            return "frame \(s1)/\(s2) ops \(p1.ops.count)/\(p2.ops.count) firstOpDiff=\(String(describing: Array(zip(p1.ops, p2.ops)).firstIndex { $0.0 != $0.1 }))"
        default: return "kinds \(String(describing: a)) / \(String(describing: b))"
        }
    }

    /// Detail records land on tasks after each tool event, and a burst of 1,100
    /// entries leaves seconds of them (each refresh, cancelled or not, frees a
    /// detail snapshot on main). Wait until the main thread is idle, so the
    /// fixture's leftovers are not billed to a tick.
    private static func settle(_ fixture: Fixture) async throws {
        var quiet = 0, residue = 0.0
        for _ in 0..<600 where quiet < 3 {
            let before = mainThreadCPU()
            try await Task.sleep(for: .milliseconds(50))
            residue = ms(mainThreadCPU() - before)
            quiet = residue < 0.25 ? quiet + 1 : 0
        }
        try expect(quiet >= 3, String(format: "the fixture never settled: %.3f ms of main-thread work per idle 50 ms", residue))
    }

    private static func parity() async throws {
        let fixture = try await fixture(agents: 1, entries: 300)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let supervisor = fixture.supervisor, agent = fixture.ids[0], thread = AgentSupervisor.threadId(for: agent)
        let offMainSink = RecordingSink(), referenceSink = RecordingSink()
        let offMain = SharedAgentTranscriptPublisher(supervisor: supervisor, agent: agent, generation: 1, sink: offMainSink)
        // The pre-move publish: the synchronous walk, planned on the main actor.
        // Everything else as `init(supervisor:)` wires it.
        let reference = SharedAgentTranscriptPublisher(agent: agent, generation: 1, sink: referenceSink,
            helpers: { [weak supervisor] in supervisor.map { SharedAgentHelpers.roster($0, lead: agent) } ?? [] },
            details: { [weak supervisor] _ in
                (supervisor?.sharedTranscriptToolBlocks(for: agent) ?? [:]).compactMapValues { SharedAgentToolPresentation(presented: $0) }
            }, detailRevision: { [weak supervisor] in supervisor?.sharedTranscriptDetailRevision(for: agent) },
            imageData: { [weak supervisor] document in await supervisor?.sharedTranscriptImages(for: agent, document: document) ?? [:] },
            document: { [weak supervisor] in supervisor?.transcriptDocument(for: agent) })
        reference.qaPlansOnMainActor = true

        // Lock-step: both publishers see each document state, tool runs and
        // their details landing between ticks included.
        var turn = 0
        for round in 0..<60 {
            if round % 6 == 0 {
                turn += 1
                supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "p\(turn)"), to: agent)
                supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "pc\(turn)", kind: .commandExecution, title: "swift build --product Array"), to: agent)
            }
            if round % 6 == 2 {
                supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "pc\(turn)", kind: .commandExecution, status: round % 12 == 2 ? .failed : .completed), to: agent)
            }
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "p\(turn)", streamKind: .assistant, delta: "Step \(round) settles the ledger. "), to: agent)
            if round % 6 == 5 {
                supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "p\(turn)", outcome: .completed, errorMessage: nil), to: agent)
            }
            for _ in 0..<5 { await Task.yield() }
            await reference.tick()
            await offMain.tick()
            try expect(offMainSink.log == referenceSink.log, "round \(round): off-main publish differs from the on-main reference "
                       + "(\(offMainSink.log.count) vs \(referenceSink.log.count) items): \(difference(offMainSink.log.last, referenceSink.log.last))")
        }
        try expect(offMainSink.failure == nil && referenceSink.failure == nil,
                   "lock-step sequencing: \(offMainSink.failure ?? referenceSink.failure ?? "")")
        let detailOps = try offMainSink.log.reduce(0) { count, item in
            guard case let .frame(_, body) = item else { return count }
            return count + (try SharedAgentTranscriptWire.decode(SharedAgentTranscriptWire.Patch.self, from: body).ops
                .filter { if case .toolDetail = $0 { return true }; return false }.count)
        }
        try expect(detailOps > 0, "the lock-step run published no tool detail, so it compared none")
        print("METRIC publisher-parity lock-step items=\(offMainSink.log.count) toolDetailOps=\(detailOps) identical=true")

        // Drift: the document moves while the off-main tick is away.
        turn += 1
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "p\(turn)"), to: agent)
        for round in 0..<40 {
            let tick = Task { @MainActor in await offMain.tick() }
            for step in 0..<3 {
                await Task.yield()
                supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "p\(turn)", streamKind: .assistant, delta: "Drift \(round).\(step). "), to: agent)
            }
            await tick.value
            await reference.tick()
        }
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "p\(turn)", outcome: .completed, errorMessage: nil), to: agent)
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<3 { await reference.tick(); await offMain.tick() }
        try expect(offMainSink.failure == nil, "drift sequencing: \(offMainSink.failure ?? "")")
        try expect(offMain.lastError == nil && reference.lastError == nil, "a drift publish failed")
        let guest = offMainSink.mirror, truth = referenceSink.mirror
        let shared = min(guest.document.entries.count, truth.document.entries.count) - 1
        try expect(shared > 50, "the mirrors share only \(shared) entries")
        let guestTail = Array(guest.document.entries.suffix(shared)), truthTail = Array(truth.document.entries.suffix(shared))
        try expect(guestTail == truthTail, "after drift the guest's transcript differs from the reference's")
        let tailBlocks = SharedAgentTranscriptWire.blockIDs(in: truthTail)
        try expect(guest.toolDetails.filter { tailBlocks.contains($0.key) } == truth.toolDetails.filter { tailBlocks.contains($0.key) },
                   "after drift the guest's tool details differ from the reference's")
        print("METRIC publisher-parity drift entries=\(shared) offMainItems=\(offMainSink.log.count) referenceItems=\(referenceSink.log.count) converged=true")
    }
}
