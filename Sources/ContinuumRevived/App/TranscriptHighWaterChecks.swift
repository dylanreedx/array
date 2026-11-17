import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Darwin
import Foundation

/// A long command stream must resume after its saved run sequence rather than
/// exhaust the bounded collision search and discard the next output chunk.
@MainActor
enum TranscriptHighWaterChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-high-water", isDirectory: true)
        let store = AgentTranscriptStore(root: fixture)
        let agent = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: agent)
        let thread = AgentSupervisor.threadId(for: agent)
        let turn = "same-turn-with-long-output"
        let count = 1_026
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        prior.ingest(.turnStarted(threadId: thread, turnId: turn))
        for index in 1...count {
            prior.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .commandOutput,
                                       delta: "OLD_OUTPUT_\(index)_END"))
        }
        prior.ingest(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        guard prior.rejectedMutationCount == 0, prior.document.entries.count == count else {
            throw Failure(description: "long output fixture did not produce \(count) distinct settled runs")
        }
        try await store.saveSnapshot(agentID: agent, sessionID: session, document: prior.document)
        guard let saved = try await store.load(agentID: agent, sessionID: session),
              saved.entries.count == count, saved.entries.allSatisfy({ $0.lifecycle == .finished }) else {
            throw Failure(description: "long output fixture did not round-trip its settled archive")
        }
        // This measures the production initializer on the main thread, including
        // reducer reindexing and run high-water recovery, not disk decoding or
        // tile rendering. No existing timing budget covers this operation.
        let resumeCPUBefore = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var resumed = ManagedAgentTranscriptModel(threadId: thread, resuming: saved, status: .idle, finalAssistantSource: nil)
        let resumeCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - resumeCPUBefore
        let resumeMilliseconds = Double(resumeCPU) / 1_000_000
        print(String(format: "METRIC transcript-high-water entries=%d production resume main CPU %.3fms",
                     saved.entries.count, resumeMilliseconds))
        let cpuBefore = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        resumed.ingest(.contentDelta(threadId: thread, turnId: turn, streamKind: .commandOutput,
                                     delta: "NEW_AFTER_LONG_OUTPUT_END"))
        let cpuElapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuBefore
        let result = resumed.document
        guard resumed.rejectedMutationCount == 0, result.entries.count == saved.entries.count + 1,
              Array(result.entries.prefix(saved.entries.count)) == saved.entries else {
            throw Failure(description: "resumed long output rejected the next run or changed its saved prefix")
        }
        let body = result.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        for marker in ["OLD_OUTPUT_1_END", "OLD_OUTPUT_1026_END", "NEW_AFTER_LONG_OUTPUT_END"] {
            guard body.components(separatedBy: marker).count - 1 == 1 else {
                throw Failure(description: "long output lost or duplicated marker \(marker)")
            }
        }
        // This is a guard against an unbounded search, not a UI-frame budget.
        guard cpuElapsed < 5_000_000_000 else {
            throw Failure(description: "resuming one output run took over five CPU seconds")
        }
    }
}
