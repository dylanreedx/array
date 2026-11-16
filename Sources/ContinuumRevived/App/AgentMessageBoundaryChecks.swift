import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Boundary cases for the production projection, run by the placement witness.
@MainActor
enum AgentMessageBoundaryChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_000

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return Date(timeIntervalSince1970: seconds)
        }

        func advance() {
            lock.lock()
            defer { lock.unlock() }
            seconds += 1
        }
    }

    private static let sender = UUID(uuidString: "A3000000-0000-4000-8000-000000000001")!

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func node(_ text: String) -> AgentNodeID { AgentNodeID(rawValue: text)! }

    private static func prompt(_ text: String) -> AgentPrompt {
        AgentPrompt(AgentMessageEnvelope.wrap(text, senderID: sender, senderName: "Scout"))
    }

    private static func messages(_ document: AgentDocument) -> [AgentMessagePayload] {
        document.entries.flatMap(\.blocks).compactMap { block in
            guard case let .agentMessage(message) = block.payload else { return nil }
            return message
        }
    }

    static func run() throws {
        try checkToolBoundaryAndHeldIdentity()
        try checkTurnEndings()
        print("agent message boundaries: FIFO, held ID dedupe/withdrawal, tool boundaries, interrupted/error/stop release, arrival timestamps and document round trip")
    }

    private static func checkToolBoundaryAndHeldIdentity() throws {
        let thread = "message-boundaries"
        let clock = Clock()
        var projection = AgentTranscriptProjection(threadId: thread, monotonicNow: { 0 }, wallClockNow: { clock.now() })
        projection.ingest(.turnStarted(threadId: thread, turnId: "turn"))
        projection.ingest(.contentDelta(threadId: thread, turnId: "turn", streamKind: .assistant, delta: "An uninterrupted re"))
        let first = node("held-first")
        let second = node("held-second")
        let withdrawn = node("held-withdrawn")
        let notice = node("held-notice")
        let versionBeforeHolding = projection.document.version

        clock.advance()
        let firstArrival = clock.now()
        let heldPatches = try projection.appendUserPrompt(id: first, prompt: prompt("First message."))
        let duplicatePatches = try projection.appendUserPrompt(id: first, prompt: prompt("DUPLICATE BODY"))
        _ = try projection.appendNotice(id: notice, title: "Side sessions", body: "One session settled.")
        clock.advance()
        let secondArrival = clock.now()
        _ = try projection.appendUserPrompt(id: second, prompt: prompt("Second message."))
        _ = try projection.appendUserPrompt(id: withdrawn, prompt: prompt("Never sent."))
        let withdrawalPatches = try projection.withdrawLocalPrompt(id: withdrawn)
        try expect(heldPatches.isEmpty && duplicatePatches.isEmpty && withdrawalPatches.isEmpty,
                   "held messages, duplicate retries and withdrawal must not patch the running reply")
        try expect(projection.document.version == versionBeforeHolding && projection.document.entries.count == 1,
                   "holding incoming entries must leave the current assistant document unchanged")

        // A new tile copies the open stream and pending insertions together.
        let reboundThread = "message-boundaries-rebound"
        var rebound = projection.rebound(to: reboundThread)
        clock.advance()
        projection.ingest(.contentDelta(threadId: thread, turnId: "turn", streamKind: .assistant, delta: "ply."))
        rebound.ingest(.contentDelta(threadId: reboundThread, turnId: "turn", streamKind: .assistant, delta: "ply."))
        projection.ingest(.itemStarted(threadId: thread, itemId: "tool", kind: .commandExecution, title: "Verify"))
        rebound.ingest(.itemStarted(threadId: reboundThread, itemId: "tool", kind: .commandExecution, title: "Verify"))

        let document = projection.document
        let ids = document.entries.map(\.id)
        try expect(ids.count == 5 && Array(ids[1...3]) == [first, notice, second],
                   "the tool boundary must release messages and notices once in arrival order, omitting withdrawn entries: \(ids)")
        try expect(document.entries.first?.blocks.first?.payload == .paragraph([.text("An uninterrupted reply.")]),
                   "the pending suffix must finish the same assistant paragraph before held entries are released")
        try expect(document.entries.last?.blocks.first?.kind == .toolCall,
                   "held entries must appear before the next tool entry")
        let cards = messages(document)
        try expect(cards.map(\.text) == ["First message.", "Second message."],
                   "duplicate held IDs must retain the original body and withdrawn messages must stay absent")
        try expect(cards.map(\.receivedAt) == [firstArrival, secondArrival],
                   "held cards must retain their distinct actual arrival times")
        try expect(document.entries[1].createdAt == clock.now() && document.entries[3].createdAt == clock.now(),
                   "held entry creation times must represent placement, after arrival")
        try expect(rebound.document == document,
                   "reattaching during a stream must preserve held messages, ordering and the complete reply")
        let releasedVersion = document.version
        let retryPatches = try projection.appendUserPrompt(id: first, prompt: prompt("DUPLICATE AFTER RELEASE"))
        try expect(retryPatches.isEmpty && projection.document.version == releasedVersion,
                   "retrying a released held ID must remain a no-op")

        projection.ingest(.itemCompleted(threadId: thread, itemId: "tool", kind: .commandExecution, status: .completed))
        projection.ingest(.contentDelta(threadId: thread, turnId: "turn", streamKind: .assistant, delta: "After the tool."))
        projection.ingest(.turnCompleted(threadId: thread, turnId: "turn", outcome: .completed, errorMessage: nil))
        try expect(messages(projection.document).count == 2 && projection.document.entries.last?.role == .assistant,
                   "a later assistant block must follow the tool without moving or duplicating the released cards")
        try expect(projection.rejectedMutationCount == 0, "boundary insertion must produce no rejected document mutations")
        let decoded = try JSONDecoder().decode(AgentDocument.self, from: JSONEncoder().encode(projection.document))
        try expect(decoded == projection.document, "released messages and arrival timestamps must survive document persistence")
    }

    private static func checkTurnEndings() throws {
        for outcome in [TurnOutcome.completed, .interrupted, .cancelled, .failed] {
            let thread = "message-ending-\(outcome.rawValue)"
            var projection = AgentTranscriptProjection(threadId: thread, monotonicNow: { 0 })
            projection.ingest(.turnStarted(threadId: thread, turnId: "turn"))
            projection.ingest(.contentDelta(threadId: thread, turnId: "turn", streamKind: .assistant, delta: "Reply before the boundary."))
            _ = try projection.appendUserPrompt(id: node("ending-card"), prompt: prompt("Arrived during the reply."))
            projection.ingest(.turnCompleted(threadId: thread, turnId: "turn", outcome: outcome,
                                            errorMessage: outcome == .failed ? "The provider failed." : nil))
            let entries = projection.document.entries
            try expect(entries.first?.role == .assistant && entries.first?.lifecycle == .finished,
                       "\(outcome): terminal completion must finish the assistant entry")
            try expect(entries.last?.id == node("ending-card") && messages(projection.document).count == 1,
                       "\(outcome): terminal completion must release the held card exactly once, after the reply and any error")
            try expect(entries.last?.turnTiming == nil && entries.dropLast().last?.turnTiming != nil,
                       "\(outcome): the interrupted reply's footer must stay before the held card")
            try expect(projection.rejectedMutationCount == 0, "\(outcome): terminal release must produce no rejected mutations")
        }

        for state in [AgentSessionState.stopped, .error] {
            let thread = "message-session-\(state.rawValue)"
            var projection = AgentTranscriptProjection(threadId: thread, monotonicNow: { 0 })
            projection.ingest(.turnStarted(threadId: thread, turnId: "turn"))
            projection.ingest(.contentDelta(threadId: thread, turnId: "turn", streamKind: .assistant, delta: "Stopped reply."))
            _ = try projection.appendUserPrompt(id: node("stopped-card"), prompt: prompt("Waiting message."))
            projection.ingest(.sessionStateChanged(state))
            try expect(projection.document.entries.count == 2 && projection.document.entries.first?.lifecycle == .finished
                       && projection.document.entries.last?.id == node("stopped-card"),
                       "\(state): session termination without turnCompleted must still release a held card after the reply")
            try expect(projection.rejectedMutationCount == 0, "\(state): session release must produce no rejected mutations")
        }

        let thread = "message-runtime-error"
        var projection = AgentTranscriptProjection(threadId: thread, monotonicNow: { 0 })
        projection.ingest(.turnStarted(threadId: thread, turnId: "turn"))
        projection.ingest(.contentDelta(threadId: thread, turnId: "turn", streamKind: .assistant, delta: "Reply before runtime error."))
        _ = try projection.appendUserPrompt(id: node("runtime-error-card"), prompt: prompt("Waiting message."))
        projection.ingest(.runtimeError(threadId: thread, message: "Connection ended."))
        projection.ingest(.turnCompleted(threadId: thread, turnId: "turn", outcome: .failed, errorMessage: "Connection ended."))
        try expect(projection.document.entries.map(\.role) == [.assistant, .user, .system]
                   && messages(projection.document).count == 1 && projection.rejectedMutationCount == 0,
                   "runtime error followed by failed completion must release the card once, preserving the reply and one error")
    }
}
