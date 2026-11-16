import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Unfinished or old-format archive entries survive a later launch unchanged.
/// The resumed model starts new turns separately; it does not pretend to resume
/// the old streaming parser or invent completion times for earlier content.
@MainActor
enum TranscriptOpenArchiveChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("open-archive-restart", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let streaming = AgentID(rawValue: UUID())
        let collision = AgentID(rawValue: UUID())
        let legacy = AgentID(rawValue: UUID())
        for id in [streaming, collision, legacy] {
            try agents.upsert(AgentRecord(id: id, displayName: "Open archive", harness: .pi,
                                          model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                          createdAt: Date(), lastActivityAt: Date()))
        }
        func session(_ id: AgentID) -> String { AgentTranscriptStore.canonicalSessionID(for: id) }
        func makeSupervisor(_ warn: @escaping (String) -> Void = { _ in }) -> AgentSupervisor {
            let value = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                        warn: warn, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
            _ = value.restore()
            return value
        }
        func text(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        func snapshotURL(_ id: AgentID) throws -> URL {
            guard let enumerator = FileManager.default.enumerator(
                at: transcriptRoot.appendingPathComponent(id.rawValue.uuidString), includingPropertiesForKeys: nil),
                  let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
                throw Failure(description: "fixture snapshot was not created")
            }
            return snapshot
        }
        func readFiles(_ id: AgentID) throws -> (Data, Data) {
            let snapshot = try snapshotURL(id)
            return (try Data(contentsOf: snapshot), try Data(contentsOf: snapshot.deletingLastPathComponent().appendingPathComponent("journal.json")))
        }
        func deliverTurn(_ owner: AgentSupervisor, _ id: AgentID, turn: String, reply: String) {
            let thread = AgentSupervisor.threadId(for: id)
            owner.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: id)
            owner.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: reply), to: id)
            owner.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: id)
        }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }

        // Exercise actual supervisor streaming persistence, rather than writing
        // a synthesized open model directly to the store.
        let first = makeSupervisor()
        guard first.records[streaming] != nil, first.records[collision] != nil else {
            throw Failure(description: "original session records did not restore")
        }
        let streamThread = AgentSupervisor.threadId(for: streaming)
        first.qaDeliver(.turnStarted(threadId: streamThread, turnId: "interrupted-turn"), to: streaming)
        first.qaDeliver(.contentDelta(threadId: streamThread, turnId: "interrupted-turn", streamKind: .assistant,
                                      delta: "PRIOR_STREAMED_OPEN_CONTENT"), to: streaming)
        let collisionThread = AgentSupervisor.threadId(for: collision)
        first.qaDeliver(.turnStarted(threadId: collisionThread, turnId: "collision-original"), to: collision)
        first.qaDeliver(.itemStarted(threadId: collisionThread, itemId: "open-reused-item", kind: .commandExecution,
                                    title: "PRIOR_OPEN_TOOL"), to: collision)
        // The production document read flushes coalesced markup; ask for the
        // pending saves while the original turn and tool are still open.
        _ = first.transcriptDocument(for: streaming)
        await first.qaSaveTranscript(for: streaming)
        await first.qaSaveTranscript(for: collision)
        let saveDeadline = ContinuousClock.now + .seconds(20)
        var savedStream: AgentDocument?, savedCollision: AgentDocument?
        while ContinuousClock.now < saveDeadline {
            savedStream = try await transcripts.load(agentID: streaming, sessionID: session(streaming))
            savedCollision = try await transcripts.load(agentID: collision, sessionID: session(collision))
            if text(savedStream).contains("PRIOR_STREAMED_OPEN_CONTENT"), text(savedCollision).contains("PRIOR_OPEN_TOOL") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let savedStream, let savedCollision,
              text(savedStream).contains("PRIOR_STREAMED_OPEN_CONTENT"),
              text(savedCollision).contains("PRIOR_OPEN_TOOL"),
              savedStream.entries.contains(where: { $0.lifecycle != .finished }),
              savedCollision.entries.contains(where: { $0.lifecycle != .finished }) else {
            throw Failure(description: "did not persist real unfinished stream and tool entries")
        }
        await first.qaWaitForTranscriptPersistence(for: streaming)
        await first.qaWaitForTranscriptPersistence(for: collision)
        let collisionBytes = try readFiles(collision)

        // Create an actual older JSON format: the lifecycle key is absent from
        // every entry, not just an archive with the generation field removed.
        var legacyModel = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: legacy))
        legacyModel.appendUserPrompt("LEGACY_MISSING_LIFECYCLE_HISTORY")
        try await transcripts.saveSnapshot(agentID: legacy, sessionID: session(legacy), document: legacyModel.document)
        let legacySnapshot = try snapshotURL(legacy)
        guard var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: legacySnapshot)) as? [String: Any],
              var document = archive["document"] as? [String: Any],
              var entries = document["entries"] as? [[String: Any]], !entries.isEmpty else {
            throw Failure(description: "cannot build legacy missing-lifecycle fixture")
        }
        for i in entries.indices { entries[i].removeValue(forKey: "lifecycle") }
        document["entries"] = entries
        archive["document"] = document
        archive.removeValue(forKey: "saveGeneration")
        try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys]).write(to: legacySnapshot)
        guard let oldLegacy = try await transcripts.load(agentID: legacy, sessionID: session(legacy)),
              oldLegacy.entries.contains(where: { $0.lifecycle != .finished }),
              text(oldLegacy).contains("LEGACY_MISSING_LIFECYCLE_HISTORY") else {
            throw Failure(description: "legacy fixture did not decode missing lifecycle as open")
        }

        // A fresh supervisor is the relaunch boundary. Its new turn cannot
        // mutate or synthesize completion for the old partial transcript.
        var warnings: [String] = []
        let restarted = makeSupervisor { warnings.append($0) }
        guard [streaming, collision, legacy].allSatisfy({ restarted.records[$0] != nil }) else {
            throw Failure(description: "relaunch did not restore the fixture agents")
        }
        deliverTurn(restarted, streaming, turn: "new-distinct-turn", reply: "NEW_AFTER_OPEN_RESTART")
        await restarted.qaSaveTranscript(for: streaming)
        guard let afterStream = try await transcripts.load(agentID: streaming, sessionID: session(streaming)),
              !restarted.qaTranscriptPersistenceIsBlocked(streaming),
              afterStream.entries.count > savedStream.entries.count,
              Array(afterStream.entries.prefix(savedStream.entries.count)) == savedStream.entries,
              text(afterStream).components(separatedBy: "PRIOR_STREAMED_OPEN_CONTENT").count - 1 == 1,
              text(afterStream).components(separatedBy: "NEW_AFTER_OPEN_RESTART").count - 1 == 1 else {
            throw Failure(description: "relaunch did not preserve the open stream as an exact prefix and append the new turn")
        }
        deliverTurn(restarted, legacy, turn: "legacy-distinct-turn", reply: "NEW_AFTER_LEGACY_RESTART")
        await restarted.qaSaveTranscript(for: legacy)
        guard let afterLegacy = try await transcripts.load(agentID: legacy, sessionID: session(legacy)),
              !restarted.qaTranscriptPersistenceIsBlocked(legacy),
              afterLegacy.entries.count > oldLegacy.entries.count,
              Array(afterLegacy.entries.prefix(oldLegacy.entries.count)) == oldLegacy.entries,
              text(afterLegacy).components(separatedBy: "LEGACY_MISSING_LIFECYCLE_HISTORY").count - 1 == 1,
              text(afterLegacy).components(separatedBy: "NEW_AFTER_LEGACY_RESTART").count - 1 == 1 else {
            throw Failure(description: "relaunch did not preserve the missing-lifecycle archive and append the new turn")
        }

        // Reusing an old provider item ID is ambiguous. It must fail closed,
        // rather than mutating the old open entry or writing a shorter archive.
        restarted.qaDeliver(.turnStarted(threadId: collisionThread, turnId: "collision-new"), to: collision)
        restarted.qaDeliver(.itemStarted(threadId: collisionThread, itemId: "open-reused-item", kind: .commandExecution,
                                        title: "CONFLICTING_NEW_TOOL"), to: collision)
        restarted.qaDeliver(.itemCompleted(threadId: collisionThread, itemId: "open-reused-item", kind: .commandExecution,
                                          status: .completed), to: collision)
        restarted.qaDeliver(.turnCompleted(threadId: collisionThread, turnId: "collision-new", outcome: .completed, errorMessage: nil), to: collision)
        await restarted.qaSaveTranscript(for: collision)
        guard restarted.qaTranscriptPersistenceIsBlocked(collision), !warnings.isEmpty,
              try readFiles(collision) == collisionBytes else {
            throw Failure(description: "reused open provider item identity did not fail closed with archive unchanged")
        }
    }
}
