import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A completed guarded save must remain the starting point of every later save.
@MainActor
enum TranscriptGuardMonotonicityChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-guard-monotonicity", isDirectory: true)
        let store = AgentTranscriptStore(root: fixture)
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        let instant = Date(timeIntervalSince1970: 1_700_000_000.625)

        func primaryBytes(_ agent: AgentID) throws -> [String: Data] {
            let directory = fixture.appendingPathComponent(agent.rawValue.uuidString)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                throw Failure(description: "guard fixture archive missing")
            }
            let urls = enumerator.allObjects.compactMap { $0 as? URL }
                .filter { $0.lastPathComponent == "snapshot.json" || $0.lastPathComponent == "journal.json" }
            guard urls.count == 2 else { throw Failure(description: "guard fixture primary pair missing") }
            return try Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        func roundTrip(_ doc: AgentDocument) throws -> AgentDocument {
            try JSONCodec.makeDecoder().decode(AgentDocument.self, from: JSONCodec.makeEncoder().encode(doc))
        }

        var initial = ManagedAgentTranscriptModel(threadId: thread, monotonicNow: { 1 }, wallClockNow: { instant })
        initial.appendUserPrompt("FROZEN_PRIOR_P")
        try await store.saveSnapshot(agentID: id, sessionID: session, document: initial.document)
        guard case let .present(prior, proof) = try await store.preflightGuardedArchive(agentID: id, sessionID: session),
              prior.entries.count == 1 else { throw Failure(description: "guard fixture preflight failed") }
        var live = ManagedAgentTranscriptModel(threadId: thread, resuming: prior, status: .idle, finalAssistantSource: nil)
        live.appendUserPrompt("LATER_SAVED_Q")
        let pq = live.document
        let generation = try await store.saveGuardedSnapshot(agentID: id, sessionID: session, document: pq,
                                                            expectedVersion: nil, expectedGeneration: nil,
                                                            expectedArchiveProof: proof, protectedPrefixCount: prior.entries.count)
        let originalBytes = try primaryBytes(id)
        // A generation match authorizes extending P+Q, not replacing it with P.
        do {
            _ = try await store.saveGuardedSnapshot(agentID: id, sessionID: session, document: prior,
                                                     expectedVersion: pq.version, expectedGeneration: generation,
                                                     protectedPrefixCount: prior.entries.count)
            throw Failure(description: "later generation accepted a replacement that dropped Q")
        } catch AgentTranscriptStoreError.unownedArchive { }
        guard try primaryBytes(id) == originalBytes else { throw Failure(description: "dropping Q changed archive bytes") }

        var replacement = ManagedAgentTranscriptModel(threadId: thread, resuming: prior, status: .idle, finalAssistantSource: nil)
        replacement.appendUserPrompt("UNRELATED_R")
        do {
            _ = try await store.saveGuardedSnapshot(agentID: id, sessionID: session, document: replacement.document,
                                                     expectedVersion: pq.version, expectedGeneration: generation,
                                                     protectedPrefixCount: prior.entries.count)
            throw Failure(description: "later generation accepted P+R in place of P+Q")
        } catch AgentTranscriptStoreError.unownedArchive { }
        guard try primaryBytes(id) == originalBytes else { throw Failure(description: "replacing Q changed archive bytes") }

        // The live model keeps fractional timestamps; the archive's ISO-8601
        // coding rounds them to whole seconds. This ordinary append must work.
        live.appendUserPrompt("VALID_LATER_S")
        _ = try await store.saveGuardedSnapshot(agentID: id, sessionID: session, document: live.document,
                                                expectedVersion: pq.version, expectedGeneration: generation,
                                                protectedPrefixCount: prior.entries.count)
        guard try await store.load(agentID: id, sessionID: session) == roundTrip(live.document) else {
            throw Failure(description: "legitimate later append did not persist the whole document")
        }

        // A previously saved open entry may gain content, then close.
        let openID = AgentID(rawValue: UUID())
        let openSession = AgentTranscriptStore.canonicalSessionID(for: openID)
        let openThread = AgentSupervisor.threadId(for: openID)
        var streaming = ManagedAgentTranscriptModel(threadId: openThread, monotonicNow: { 1 }, wallClockNow: { instant })
        streaming.ingest(.turnStarted(threadId: openThread, turnId: "stream"))
        streaming.ingest(.contentDelta(threadId: openThread, turnId: "stream", streamKind: .assistant, delta: "OPEN_PREFIX"))
        _ = streaming.flushPendingStreamingMarkup()
        let firstOpen = streaming.document
        guard firstOpen.entries.contains(where: { $0.lifecycle != .finished }) else {
            throw Failure(description: "stream fixture did not leave an open entry")
        }
        let openGeneration = try await store.saveGuardedSnapshot(agentID: openID, sessionID: openSession, document: firstOpen,
                                                                 expectedVersion: nil, expectedGeneration: nil)
        streaming.ingest(.contentDelta(threadId: openThread, turnId: "stream", streamKind: .assistant, delta: "_ADVANCED"))
        _ = streaming.flushPendingStreamingMarkup()
        let advancedOpen = streaming.document
        let advancedGeneration = try await store.saveGuardedSnapshot(agentID: openID, sessionID: openSession, document: advancedOpen,
                                                                     expectedVersion: firstOpen.version, expectedGeneration: openGeneration)
        streaming.ingest(.turnCompleted(threadId: openThread, turnId: "stream", outcome: .completed, errorMessage: nil))
        _ = streaming.flushPendingStreamingMarkup()
        _ = try await store.saveGuardedSnapshot(agentID: openID, sessionID: openSession, document: streaming.document,
                                                expectedVersion: advancedOpen.version, expectedGeneration: advancedGeneration)
        guard let finished = try await store.load(agentID: openID, sessionID: openSession),
              finished == (try roundTrip(streaming.document)), finished.entries.allSatisfy({ $0.lifecycle == .finished }) else {
            throw Failure(description: "legitimate open-entry advancement or completion was not persisted")
        }

        // A finished item can gain its enclosing turn's timing after it was
        // saved, without changing any of its content.
        let timingID = AgentID(rawValue: UUID())
        let timingSession = AgentTranscriptStore.canonicalSessionID(for: timingID)
        var timed = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: timingID),
                                               monotonicNow: { 1 }, wallClockNow: { instant })
        timed.appendUserPrompt("TIMING_ENRICHMENT")
        guard let entry = timed.document.entries.first, entry.lifecycle == .finished, entry.turnTiming == nil else {
            throw Failure(description: "timing fixture was not finished and untimed")
        }
        let beforeTiming = timed.document
        let timingGeneration = try await store.saveGuardedSnapshot(agentID: timingID, sessionID: timingSession, document: beforeTiming,
                                                                   expectedVersion: nil, expectedGeneration: nil)
        var reducer = AgentDocumentReducer(document: beforeTiming, createdAtProvider: { instant })
        try reducer.apply(.completeTurn(entryID: entry.id, startedAt: instant.addingTimeInterval(-1)))
        _ = try await store.saveGuardedSnapshot(agentID: timingID, sessionID: timingSession, document: reducer.document,
                                                expectedVersion: beforeTiming.version, expectedGeneration: timingGeneration)
        guard let enriched = try await store.load(agentID: timingID, sessionID: timingSession),
              enriched == (try roundTrip(reducer.document)), enriched.entries.first?.turnTiming != nil else {
            throw Failure(description: "legitimate completed-entry timing was not persisted")
        }
    }
}
