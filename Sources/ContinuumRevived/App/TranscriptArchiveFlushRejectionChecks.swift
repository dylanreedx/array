import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A deferred canonical markdown parse may fail after event ingestion already
/// returned. That failure must prevent release and any replacement save.
@MainActor
enum TranscriptArchiveFlushRejectionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-flush-rejection", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let store = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: id, displayName: "Deferred parse collision", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let thread = AgentSupervisor.threadId(for: id)
        let turn = "deferred-flush-collision"
        let encoded = Data(turn.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let futureEntry = AgentNodeID(rawValue: "turn:\(encoded):assistant:1"),
              let priorEntry = AgentNodeID(rawValue: "prior-flush-owner") else {
            throw Failure(description: "could not construct stable fixture IDs")
        }
        // The old row owns the ID that a *second* paragraph of the new stream
        // will receive. The first parse can succeed; the later parse cannot.
        let parsed = MarkdownAgentMarkupParser().parse("alpha\n\nbeta", entryID: futureEntry, previous: [])
        guard parsed.blocks.count == 2 else { throw Failure(description: "fixture did not parse two paragraphs") }
        let conflict = parsed.blocks[1].id
        let prior = AgentDocument(version: 1, entries: [AgentEntry(
            id: priorEntry, role: .user, provenance: .localPrompt(promptID: "prior"),
            lifecycle: .finished, blocks: [AgentBlock(id: conflict, kind: .paragraph,
                                                     payload: .paragraph([.text("PRIOR_ARCHIVE_CONTENT")]))])])
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try await store.saveSnapshot(agentID: id, sessionID: session, document: prior)
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil }, transcriptStore: store)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "fixture record did not restore") }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: id)
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: "alpha"), to: id)
        let firstParseCount = supervisor.qaTranscriptParseCount(for: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: "\n\nbeta"), to: id)
        guard firstParseCount > 0, supervisor.qaTranscriptParseCount(for: id) == firstParseCount else {
            throw Failure(description: "fixture's second parse was not deferred by the scheduler")
        }
        // This save is deliberately before the pending parse. It gives the
        // release decision an actual archive that the failed flush must keep.
        await supervisor.qaSaveTranscript(for: id)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id) else {
            throw Failure(description: "fixture blocked before the deferred flush")
        }
        let agentRoot = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: agentRoot, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture snapshot is missing")
        }
        // The event's 200ms debounce must end before the production dormant
        // path can run. The scheduler never parses solely because time passes.
        try? await Task.sleep(for: .milliseconds(350))
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        let before = try Data(contentsOf: snapshot)
        let deadline = ContinuousClock.now + .seconds(10)
        while !supervisor.qaTranscriptPersistenceIsBlocked(id), !supervisor.isTranscriptReleased(id),
              ContinuousClock.now < deadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        let localText = (supervisor.transcriptDocument(for: id)?.entries ?? [])
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard supervisor.qaTranscriptPersistenceIsBlocked(id), !supervisor.isTranscriptReleased(id),
              !warnings.isEmpty, try Data(contentsOf: snapshot) == before,
              localText.contains("new transcript content may be lost") else {
            throw Failure(description: "a rejected deferred canonical flush did not block persistence and retain the prior archive")
        }
    }
}
