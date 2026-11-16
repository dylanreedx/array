import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// Streaming after restoring a large canonical archive must not copy that
/// archive's whole decoded model for every small delta.
@MainActor
enum TranscriptResumedStreamingPerfChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    private static func percentile(_ samples: [Double], _ percentile: Int) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, sorted.count * percentile / 100)]
    }
    private static func text(_ document: AgentDocument) -> String {
        document.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("resumed-stream-perf", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let records = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let store = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let small = AgentID(rawValue: UUID()), large = AgentID(rawValue: UUID())
        let counts = [(small, 16), (large, 6_000)]
        var originals: [AgentID: AgentDocument] = [:]
        for (id, count) in counts {
            try records.upsert(AgentRecord(id: id, displayName: "Streaming performance", harness: .pi,
                                           model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                           createdAt: Date(), lastActivityAt: Date()))
            var archive = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: id))
            for index in 0..<count {
                archive.appendUserPrompt("ARCHIVED_\(index)_" + String(repeating: "historical context ", count: 12))
            }
            let session = AgentTranscriptStore.canonicalSessionID(for: id)
            try await store.saveSnapshot(agentID: id, sessionID: session, document: archive.document)
            guard let roundTripped = try await store.load(agentID: id, sessionID: session),
                  roundTripped.entries.count == count else {
                throw Failure(description: "could not create the \(count)-entry archive")
            }
            originals[id] = roundTripped
        }
        let owner = AgentSupervisor(store: records, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                    warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: store)
        _ = owner.restore()
        guard counts.allSatisfy({ owner.records[$0.0] != nil }) else {
            throw Failure(description: "resumed-stream fixture agents did not restore")
        }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; owner.stopAll() }

        for (id, _) in counts {
            owner.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt("PROVIDER_LOCAL_ONLY")],
                                                               restoredMessageCount: 1, omittedEarlier: true), for: id)
            let thread = AgentSupervisor.threadId(for: id)
            owner.qaDeliver(.turnStarted(threadId: thread, turnId: "resumed-setup"), to: id)
            await owner.qaWaitForTranscriptPersistence(for: id)
            guard !owner.qaTranscriptPersistenceIsBlocked(id) else {
                throw Failure(description: "valid prior archive could not resume")
            }
            // Finish setup and await its save before measuring either agent.
            // A save still holding a legitimate snapshot would itself force a
            // copy and confound the per-event dictionary-ownership witness.
            owner.qaDeliver(.turnCompleted(threadId: thread, turnId: "resumed-setup", outcome: .completed, errorMessage: nil), to: id)
            await owner.qaSaveTranscript(for: id)
        }
        for (id, _) in counts {
            let thread = AgentSupervisor.threadId(for: id)
            owner.qaDeliver(.turnStarted(threadId: thread, turnId: "resumed-performance"), to: id)
            // The first delta creates the stream; measure subsequent updates.
            owner.qaDeliver(.contentDelta(threadId: thread, turnId: "resumed-performance", streamKind: .commandOutput,
                                          delta: "RESUMED_STREAM_START|"), to: id)
        }

        // Same actor, no sleeps between measured command-output deltas: each
        // produces a real semantic entry without mixing a separate save into
        // the measurement. This catches a full-archive copy on every update.
        let count = 240
        func sample(_ id: AgentID, observeStorage: Bool) throws -> (samples: [Double], unchangedCapacity: Int, moved: Int) {
            let thread = AgentSupervisor.threadId(for: id)
            var result: [Double] = []
            result.reserveCapacity(count)
            var unchangedCapacity = 0, moved = 0
            for _ in 0..<count {
                let storageBefore = observeStorage ? owner.qaCanonicalEntryStorage(for: id) : nil
                let before = cpu()
                autoreleasepool {
                    owner.qaDeliver(.contentDelta(threadId: thread, turnId: "resumed-performance", streamKind: .commandOutput,
                                                  delta: "x"), to: id)
                }
                result.append(Double(cpu() - before) / 1_000_000)
                if observeStorage {
                    guard let storageBefore, let storageAfter = owner.qaCanonicalEntryStorage(for: id),
                          storageAfter.count == storageBefore.count + 1 else {
                        throw Failure(description: "canonical storage observation did not follow a real appended entry")
                    }
                    if storageBefore.capacity == storageAfter.capacity {
                        unchangedCapacity += 1
                        if storageBefore.address != storageAfter.address { moved += 1 }
                    }
                }
            }
            return (result, unchangedCapacity, moved)
        }
        let smallSample = try sample(small, observeStorage: false)
        let largeSample = try sample(large, observeStorage: true)
        let smallMedian = percentile(smallSample.samples, 50), largeMedian = percentile(largeSample.samples, 50)
        let largeP95 = percentile(largeSample.samples, 95)
        print(String(format: "METRIC resumed-stream archives=16/6000 entries deltas=%d main CPU small median=%.3fms large median=%.3fms p95=%.3fms ratio=%.2fx",
                     count, smallMedian, largeMedian, largeP95, largeMedian / max(smallMedian, 0.000_001)))
        print("METRIC resumed-stream canonical storage unchanged-capacity=\(largeSample.unchangedCapacity) moved=\(largeSample.moved)")
        // Array growth may move the buffer. With capacity unchanged, an
        // in-place update must keep it; a retained dictionary copy forces COW.
        guard largeSample.unchangedCapacity > 0, largeSample.moved == 0 else {
            throw Failure(description: "canonical entries copied during \(largeSample.moved) of \(largeSample.unchangedCapacity) unchanged-capacity mutations")
        }
        guard largeP95 < TranscriptSavePerfChecks.frameBudgetMilliseconds else {
            throw Failure(description: String(format: "resumed streaming spent %.3fms p95; expected <%.1fms",
                                              largeP95, TranscriptSavePerfChecks.frameBudgetMilliseconds))
        }

        for (id, _) in counts {
            let thread = AgentSupervisor.threadId(for: id)
            owner.qaDeliver(.turnCompleted(threadId: thread, turnId: "resumed-performance", outcome: .completed, errorMessage: nil), to: id)
            await owner.qaSaveTranscript(for: id)
            let session = AgentTranscriptStore.canonicalSessionID(for: id)
            guard let original = originals[id], let saved = try await store.load(agentID: id, sessionID: session),
                  saved.entries.count > original.entries.count,
                  Array(saved.entries.prefix(original.entries.count)) == original.entries,
                  saved.entries.dropFirst(original.entries.count)
                      .filter({ AgentTranscriptCopyController.plainText(for: $0.blocks) == "RESUMED_STREAM_START|" }).count == 1,
                  saved.entries.dropFirst(original.entries.count)
                      .filter({ AgentTranscriptCopyController.plainText(for: $0.blocks) == "x" }).count == count,
                  !text(saved).contains("PROVIDER_LOCAL_ONLY"), !owner.qaTranscriptPersistenceIsBlocked(id) else {
                throw Failure(description: "streaming failed to retain the archive and the complete new turn")
            }
        }
    }
}
