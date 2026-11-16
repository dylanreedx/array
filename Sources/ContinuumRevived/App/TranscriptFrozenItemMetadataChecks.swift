import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A reused provider item ID must not mutate an older resumed card's kind or
/// status, including the legacy compatibility metadata outside the document.
@MainActor
enum TranscriptFrozenItemMetadataChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        try checkCrossScopeCollision()
        try checkDuplicateStartAfterCompletion()
        let fixture = root.appendingPathComponent("transcript-frozen-item-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let itemID = "frozen-item-metadata"
        let oldTitle = "HISTORICAL_COMMAND"
        let newTitle = "COLLIDING_FILE_CHANGE"
        try agents.upsert(AgentRecord(id: id, displayName: "Frozen metadata", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))

        var original = ManagedAgentTranscriptModel(threadId: thread)
        original.ingest(.turnStarted(threadId: thread, turnId: "old-turn"))
        original.ingest(.itemStarted(threadId: thread, itemId: itemID, kind: .commandExecution, title: oldTitle))
        original.ingest(.itemCompleted(threadId: thread, itemId: itemID, kind: .commandExecution, status: .completed))
        original.ingest(.turnCompleted(threadId: thread, turnId: "old-turn", outcome: .completed, errorMessage: nil))
        let encoded = try JSONCodec.makeEncoder().encode(original.document)
        let saved = try JSONCodec.makeDecoder().decode(AgentDocument.self, from: encoded)
        guard saved.entries.count == 1, saved.entries[0].lifecycle == .finished else {
            throw Failure(description: "fixture did not build one finished command entry")
        }
        let collidingStart = AgentRuntimeEvent.itemStarted(threadId: thread, itemId: itemID, kind: .fileChange, title: newTitle)
        let collidingEnd = AgentRuntimeEvent.itemCompleted(threadId: thread, itemId: itemID, kind: .fileChange, status: .failed)

        var resumed = ManagedAgentTranscriptModel(threadId: thread, resuming: saved, status: .idle, finalAssistantSource: nil)
        guard let baseline = resumed.cards.first(where: { $0.id == itemID }),
              baseline.kind == .toolCall, baseline.title == oldTitle, baseline.status == .completed,
              let baselineRow = resumed.compatibilityRows.first(where: { $0.id == itemID }) else {
            throw Failure(description: "resumed model did not show the completed historical command")
        }
        for (phase, event) in [("start", collidingStart), ("completion", collidingEnd)] {
            resumed.ingest(event)
            guard resumed.document == saved,
                  resumed.cards.first(where: { $0.id == itemID }) == baseline,
                  resumed.compatibilityRows.first(where: { $0.id == itemID }) == baselineRow else {
                throw Failure(description: "\(phase) of a colliding item changed the frozen historical card's kind, status or document")
            }
        }

        // AgentTranscriptProjection has a separate compatibility status map.
        // Check it directly as well as the managed model's card adapter.
        var semantic = AgentTranscriptProjection(threadId: thread, resuming: saved, status: .idle, finalAssistantSource: nil)
        let semanticID = saved.entries[0].id.rawValue
        guard let semanticBaseline = semantic.compatibilityRows.first(where: { $0.id == semanticID }) else {
            throw Failure(description: "resumed semantic projection had no historical compatibility row")
        }
        for (phase, event) in [("start", collidingStart), ("completion", collidingEnd)] {
            semantic.ingest(event)
            guard semantic.document == saved,
                  semantic.compatibilityRows.first(where: { $0.id == semanticID }) == semanticBaseline else {
                throw Failure(description: "\(phase) of a colliding item changed the frozen semantic compatibility row")
            }
        }

        // Drive the same collision through a released supervisor, where the
        // user must see the save refusal and the existing archive must survive.
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: transcripts)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "supervisor did not restore the fixture") }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; supervisor.stopAll() }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "old-turn"), to: id)
        supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: itemID, kind: .commandExecution, title: oldTitle), to: id)
        supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: itemID, kind: .commandExecution, status: .completed), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "old-turn", outcome: .completed, errorMessage: nil), to: id)
        await supervisor.qaSaveTranscript(for: id)
        let deadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < deadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id), let diskBefore = try await transcripts.load(agentID: id, sessionID: session) else {
            throw Failure(description: "supervisor did not save and release the fixture")
        }
        let first = supervisor.transcriptAttachment(for: id, reboundTo: "metadata-reload")
        let firstView = Task { for await _ in first.tail {} }
        defer { firstView.cancel() }
        guard let reload = first.reload else { throw Failure(description: "fixture did not begin reloading") }
        await reload.value
        let before = supervisor.transcriptAttachment(for: id, reboundTo: "metadata-before")
        let beforeView = Task { for await _ in before.tail {} }
        defer { beforeView.cancel() }
        guard let beforeModel = before.snapshot,
              let beforeCard = beforeModel.cards.first(where: { $0.id == itemID }),
              let beforeRow = beforeModel.compatibilityRows.first(where: { $0.id == itemID }),
              beforeCard.title == oldTitle, beforeCard.status == .completed else {
            throw Failure(description: "reloaded supervisor did not preserve its historical command card")
        }
        var notices: [AgentLocalNotice] = []
        let observer = supervisor.addLocalNoticeObserver(for: id) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(observer, for: id) }
        supervisor.qaDeliver(collidingStart, to: id)
        supervisor.qaDeliver(collidingEnd, to: id)
        await supervisor.qaSaveTranscript(for: id)
        let after = supervisor.transcriptAttachment(for: id, reboundTo: "metadata-after")
        let afterView = Task { for await _ in after.tail {} }
        defer { afterView.cancel() }
        guard let afterModel = after.snapshot,
              afterModel.cards.first(where: { $0.id == itemID }) == beforeCard,
              afterModel.compatibilityRows.first(where: { $0.id == itemID }) == beforeRow,
              Array(afterModel.document.entries.prefix(diskBefore.entries.count)) == diskBefore.entries,
              supervisor.qaTranscriptPersistenceIsBlocked(id), !warnings.isEmpty,
              notices.contains(where: { $0.title == "Transcript not saved" }),
              try await transcripts.load(agentID: id, sessionID: session) == diskBefore else {
            throw Failure(description: "supervisor collision changed the historical card, overwrote the archive, or failed to warn")
        }
    }

    /// A provider's turn ID and item ID can be the same raw string, while
    /// their semantic entry IDs are deliberately in different scopes. Legacy
    /// metadata for the live item must not leak onto the older assistant row.
    private static func checkCrossScopeCollision() throws {
        let thread = "cross-scope-\(UUID().uuidString)"
        let sharedID = "same-provider-turn-and-item"
        var initial = ManagedAgentTranscriptModel(threadId: thread)
        initial.ingest(.turnStarted(threadId: thread, turnId: sharedID))
        initial.ingest(.contentDelta(threadId: thread, turnId: sharedID, streamKind: .assistant,
                                     delta: "HISTORICAL_ASSISTANT_OUTPUT"))
        initial.ingest(.turnCompleted(threadId: thread, turnId: sharedID, outcome: .completed, errorMessage: nil))
        let saved = try JSONCodec.makeDecoder().decode(AgentDocument.self, from: JSONCodec.makeEncoder().encode(initial.document))
        guard saved.entries.count == 1, saved.entries[0].role == .assistant,
              case let .providerItem(_, priorID?) = saved.entries[0].provenance, priorID == sharedID else {
            throw Failure(description: "cross-scope fixture did not create the historical assistant row")
        }
        var resumed = ManagedAgentTranscriptModel(threadId: thread, resuming: saved, status: .idle, finalAssistantSource: nil)
        guard let priorCard = resumed.cards.first, priorCard.kind == .message,
              let priorRow = resumed.compatibilityRows.first else {
            throw Failure(description: "cross-scope fixture did not show its historical assistant card")
        }
        var semantic = AgentTranscriptProjection(threadId: thread, resuming: saved, status: .idle, finalAssistantSource: nil)
        guard let priorSemantic = semantic.compatibilityRows.first else {
            throw Failure(description: "cross-scope fixture had no semantic compatibility row")
        }
        let events: [(String, AgentRuntimeEvent)] = [
            ("start", .itemStarted(threadId: thread, itemId: sharedID, kind: .fileChange, title: "NEW_DISTINCT_ITEM")),
            ("completion", .itemCompleted(threadId: thread, itemId: sharedID, kind: .fileChange, status: .failed))
        ]
        for (phase, event) in events {
            resumed.ingest(event)
            semantic.ingest(event)
            guard resumed.document.entries.first == saved.entries.first,
                  resumed.cards.first == priorCard,
                  resumed.compatibilityRows.first == priorRow,
                  semantic.document.entries.first == saved.entries.first,
                  semantic.compatibilityRows.first == priorSemantic else {
                throw Failure(description: "cross-scope item \(phase) changed the historical assistant card or status")
            }
        }
        guard resumed.document.entries.count == 2,
              resumed.document.entries[1].id != saved.entries[0].id else {
            throw Failure(description: "cross-scope fixture did not accept the distinct live item")
        }
    }

    /// An ordinary duplicate start after a completed current item is not an
    /// accepted new identity and must not reset its metadata to in-progress.
    private static func checkDuplicateStartAfterCompletion() throws {
        let thread = "duplicate-item-\(UUID().uuidString)"
        let itemID = "completed-current-item"
        var live = ManagedAgentTranscriptModel(threadId: thread)
        live.ingest(.itemStarted(threadId: thread, itemId: itemID, kind: .commandExecution, title: "COMPLETED_COMMAND"))
        live.ingest(.itemCompleted(threadId: thread, itemId: itemID, kind: .commandExecution, status: .completed))
        guard let prior = live.cards.first(where: { $0.id == itemID }),
              prior.status == .completed, prior.itemKind == .commandExecution,
              let priorRow = live.compatibilityRows.first(where: { $0.id == itemID }) else {
            throw Failure(description: "duplicate-start fixture did not create a completed command")
        }
        let before = live.document
        live.ingest(.itemStarted(threadId: thread, itemId: itemID, kind: .fileChange, title: "DUPLICATE_START"))
        guard live.document == before, live.cards.first(where: { $0.id == itemID }) == prior,
              live.compatibilityRows.first(where: { $0.id == itemID }) == priorRow else {
            throw Failure(description: "duplicate start changed the completed card's kind or status")
        }
    }
}
