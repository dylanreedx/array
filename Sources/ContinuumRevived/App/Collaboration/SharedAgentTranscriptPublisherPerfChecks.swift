import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-transcript-publisher-perf-check`: what one streaming tick of
/// the host's transcript publisher costs the main thread on a long transcript.
///
/// A production supervisor holds ~1,100 entries (~500 KB encoded); one, then three,
/// shared agents stream an assistant reply while their real publishers tick.
/// The sink is a counter, so the time is the publisher's own: the document
/// read, the diff, and the encode.
@MainActor
enum SharedAgentTranscriptPublisherPerfChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    final class CountingSink: SharedAgentTranscriptSink {
        var checkpoints = 0, frames = 0, bytes = 0
        func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                     frames: [Collaboration.AgentTranscript.Frame]) async throws {
            if let checkpoint { checkpoints += 1; bytes += checkpoint.body.count }
            self.frames += frames.count; bytes += frames.reduce(0) { $0 + $1.body.count }
        }
    }

    static func run() async throws {
        for agents in [1, 3] { try await measure(agents: agents) }
    }

    private static func measure(agents count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
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

        // History: finished turns of reasoning, a command and a reply, to ~1,100 entries.
        let prose = "Checkout state validates. "
        for id in ids {
            let thread = AgentSupervisor.threadId(for: id)
            var turn = 0
            while (supervisor.transcriptDocument(for: id)?.entries.count ?? 0) < 1_100 {
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
        for _ in 0..<20 { await Task.yield() }
        guard let sample = supervisor.transcriptDocument(for: ids[0]) else { throw Failure(description: "no document") }
        let docBytes = try SharedAgentTranscriptWire.encode(sample.entries).count

        let sink = CountingSink()
        let publishers = ids.map { SharedAgentTranscriptPublisher(supervisor: supervisor, agent: $0, generation: 1, sink: sink) }
        let clock = ContinuousClock()
        var checkpointTimes: [Duration] = []
        for publisher in publishers {
            checkpointTimes.append(await clock.measure { await publisher.tick() })
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
                let before = publisher.checkpoints
                let spent = await clock.measure { await publisher.tick() }
                roundTotal += spent
                (publisher.checkpoints == before ? { patchTicks.append(spent) } : { recheckpointTicks.append(spent) })()
            }
            perRound.append(roundTotal)
        }
        guard publishers.allSatisfy({ $0.lastError == nil }) else { throw Failure(description: "a publish failed: \(String(describing: publishers.first?.lastError))") }

        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func stats(_ xs: [Duration]) -> String {
            guard !xs.isEmpty else { return "n=0" }
            let sorted = xs.map(ms).sorted()
            return String(format: "n=%d median=%.3fms p95=%.3fms max=%.3fms", sorted.count, sorted[sorted.count / 2],
                          sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted.last!)
        }
        print("METRIC publisher-perf agents=\(count) entries=\(sample.entries.count) documentBytes=\(docBytes) window=\(publishers[0].published.count)")
        print("METRIC publisher-perf agents=\(count) first-checkpoint \(stats(checkpointTimes))")
        print("METRIC publisher-perf agents=\(count) patch-tick \(stats(patchTicks))")
        print("METRIC publisher-perf agents=\(count) re-checkpoint-tick \(stats(recheckpointTicks))")
        print("METRIC publisher-perf agents=\(count) all-agents-per-250ms \(stats(perRound)) frames=\(sink.frames) checkpoints=\(sink.checkpoints) bytes=\(sink.bytes)")
    }
}
