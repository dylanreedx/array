import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Exercises real transcript mutation paths after a canonical archive restart.
@MainActor
enum TranscriptArchiveMutationChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("archive-mutation-witness", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agentStore = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptsRoot = fixture.appendingPathComponent("transcripts")
        let store = AgentTranscriptStore(root: transcriptsRoot)
        let normal = AgentID(rawValue: UUID())
        let reused = AgentID(rawValue: UUID())
        let active = AgentID(rawValue: UUID())
        let activeCollision = AgentID(rawValue: UUID())
        for id in [normal, reused, active, activeCollision] {
            try agentStore.upsert(AgentRecord(id: id, displayName: "Archive mutation witness", harness: .pi,
                                             model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                             createdAt: Date(), lastActivityAt: Date()))
        }
        func session(_ id: AgentID) -> String { AgentTranscriptStore.canonicalSessionID(for: id) }
        func text(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        func imageMatches(_ document: AgentDocument?, _ image: AgentImageAttachmentMetadata) -> Int {
            (document?.entries ?? []).flatMap(\.blocks).filter { block in
                guard case let .image(payload) = block.payload else { return false }
                return payload.attachment == image
            }.count
        }
        func archiveBytes(_ id: AgentID) throws -> [String: Data] {
            let directory = transcriptsRoot.appendingPathComponent(id.rawValue.uuidString)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                throw Failure(description: "cannot enumerate the archive fixture")
            }
            let urls = enumerator.allObjects.compactMap { $0 as? URL }
                .filter { $0.lastPathComponent == "snapshot.json" || $0.lastPathComponent == "journal.json" }
            guard urls.count == 2 else { throw Failure(description: "expected primary snapshot and journal") }
            return try Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }

        let normalThread = AgentSupervisor.threadId(for: normal)
        var prior = ManagedAgentTranscriptModel(threadId: normalThread)
        prior.appendUserPrompt("CANONICAL_BEFORE_MUTATIONS")
        // Old builds restarted the counter; seed both historical key spellings.
        prior.appendNotice(id: "array-command-status#1", title: "old status", text: "OLD_STATUS_ONE")
        prior.appendNotice(id: "array-command-array:status#1", title: "old status", text: "OLD_STATUS_TWO")
        try await store.saveSnapshot(agentID: normal, sessionID: session(normal), document: prior.document)
        let normalPrior = try await store.load(agentID: normal, sessionID: session(normal))!

        let reusedThread = AgentSupervisor.threadId(for: reused)
        var priorItem = ManagedAgentTranscriptModel(threadId: reusedThread)
        priorItem.ingest(.turnStarted(threadId: reusedThread, turnId: "old-turn"))
        priorItem.ingest(.itemStarted(threadId: reusedThread, itemId: "reused-item", kind: .commandExecution, title: "OLD_COMMAND"))
        priorItem.ingest(.itemCompleted(threadId: reusedThread, itemId: "reused-item", kind: .commandExecution, status: .completed))
        priorItem.ingest(.turnCompleted(threadId: reusedThread, turnId: "old-turn", outcome: .completed, errorMessage: nil))
        guard !priorItem.document.entries.isEmpty, priorItem.document.entries.allSatisfy({ $0.lifecycle == .finished }) else {
            throw Failure(description: "reused-ID fixture did not produce settled prior entries")
        }
        try await store.saveSnapshot(agentID: reused, sessionID: session(reused), document: priorItem.document)
        let reusedBytes = try archiveBytes(reused)

        let activeThread = AgentSupervisor.threadId(for: active)
        var priorOpen = ManagedAgentTranscriptModel(threadId: activeThread)
        priorOpen.ingest(.turnStarted(threadId: activeThread, turnId: "prior-open"))
        priorOpen.ingest(.contentDelta(threadId: activeThread, turnId: "prior-open", streamKind: .assistant, delta: "OLD_OPEN_HISTORY"))
        _ = priorOpen.flushPendingStreamingMarkup()
        guard priorOpen.document.entries.contains(where: { $0.lifecycle != .finished }) else {
            throw Failure(description: "unfinished-archive fixture had no open entry")
        }
        try await store.saveSnapshot(agentID: active, sessionID: session(active), document: priorOpen.document)
        guard let activePrior = try await store.load(agentID: active, sessionID: session(active)),
              activePrior.entries.contains(where: { $0.lifecycle != .finished }) else {
            throw Failure(description: "unfinished-archive fixture did not survive its disk round trip")
        }
        let collisionThread = AgentSupervisor.threadId(for: activeCollision)
        var priorCollision = ManagedAgentTranscriptModel(threadId: collisionThread)
        priorCollision.ingest(.turnStarted(threadId: collisionThread, turnId: "reused-open-turn"))
        priorCollision.ingest(.contentDelta(threadId: collisionThread, turnId: "reused-open-turn", streamKind: .assistant,
                                            delta: "OLD_OPEN_COLLISION_HISTORY"))
        _ = priorCollision.flushPendingStreamingMarkup()
        guard priorCollision.document.entries.contains(where: { $0.lifecycle != .finished }) else {
            throw Failure(description: "open-entry collision fixture had no open entry")
        }
        try await store.saveSnapshot(agentID: activeCollision, sessionID: session(activeCollision), document: priorCollision.document)
        guard let collisionPrior = try await store.load(agentID: activeCollision, sessionID: session(activeCollision)),
              collisionPrior.entries.contains(where: { $0.lifecycle != .finished }) else {
            throw Failure(description: "open-entry collision fixture did not survive its disk round trip")
        }

        var warnings: [String] = []
        let attachments = AgentComposerAttachmentStore(applicationSupportDirectory: fixture)
        let supervisor = AgentSupervisor(store: agentStore, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         attachmentStore: attachments, transcriptStore: store)
        _ = supervisor.restore()
        guard [normal, reused, active, activeCollision].allSatisfy({ supervisor.records[$0] != nil }) else {
            throw Failure(description: "archive fixture records did not restore")
        }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; supervisor.stopAll() }
        supervisor.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt("PROVIDER_LOCAL_MUTATION_FIXTURE")],
                                                                restoredMessageCount: 1, omittedEarlier: true), for: normal)
        var notices: [AgentLocalNotice] = []
        let token = supervisor.addLocalNoticeObserver(for: normal) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(token, for: normal) }
        let image = try await supervisor.stageBrowserScreenshot(SharedTileParityChecks.screenshotPNG(), for: normal)
        await supervisor.commitBrowserScreenshot(image.manifest.metadata.id, for: normal)
        let status = AgentCommandInvocation(descriptorID: "array:status", name: "status", surface: .array)
        guard case .accepted = await supervisor.accept(.providerCommand(status), for: normal) else {
            throw Failure(description: "the real /status command was refused")
        }
        guard let freshNotice = notices.first(where: { $0.screenshot == nil }) else {
            throw Failure(description: "the real /status command published no notice")
        }
        supervisor.qaDeliver(.turnStarted(threadId: normalThread, turnId: "new-turn"), to: normal)
        supervisor.qaDeliver(.contentDelta(threadId: normalThread, turnId: "new-turn", streamKind: .assistant,
                                           delta: "LIVE_BEFORE_SCREENSHOT"), to: normal)
        try supervisor.publishBrowserScreenshot(image.manifest.metadata, for: normal)
        supervisor.qaDeliver(.turnCompleted(threadId: normalThread, turnId: "new-turn", outcome: .completed, errorMessage: nil), to: normal)
        let outside = RehydratedTranscript(steps: [.userPrompt("OUTSIDE_TURN_AFTER_RESTART")], restoredMessageCount: 1, omittedEarlier: false)
        supervisor.appendOutsideTurns(outside, boundaryText: "Outside terminal boundary", symbolName: nil, for: normal)
        await supervisor.qaSaveTranscript(for: normal)
        var disk: AgentDocument?
        let normalDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < normalDeadline {
            disk = try await store.load(agentID: normal, sessionID: session(normal))
            if text(disk).contains("OUTSIDE_TURN_AFTER_RESTART"), imageMatches(disk, image.manifest.metadata) == 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let disk, Array(disk.entries.prefix(normalPrior.entries.count)) == normalPrior.entries,
              text(disk).contains("OLD_STATUS_ONE"), text(disk).contains("OLD_STATUS_TWO"),
              text(disk).contains("LIVE_BEFORE_SCREENSHOT"), text(disk).contains("OUTSIDE_TURN_AFTER_RESTART"),
              !text(disk).contains("PROVIDER_LOCAL_MUTATION_FIXTURE"), imageMatches(disk, image.manifest.metadata) == 1,
              !supervisor.qaTranscriptPersistenceIsBlocked(normal) else {
            throw Failure(description: "normal canonical archive lost prior/new content, outside history, or screenshot; or saved local provider restore")
        }
        let newNotices = disk.entries.filter { entry in
            entry.blocks.contains { block in
                guard case .notice = block.payload else { return false }
                // Copying a notice yields its message only; the title is the
                // semantic heading child, not part of that copied text.
                return AgentTranscriptCopyController.plainText(for: [block]) == freshNotice.body
                    && AgentTranscriptCopyController.plainText(for: block.children) == freshNotice.title
            }
        }
        guard newNotices.count == 1, !normalPrior.entries.contains(where: { $0.id == newNotices[0].id }) else {
            throw Failure(description: "the new /status notice was lost or reused an old archive identity")
        }
        let local = supervisor.transcriptDocument(for: normal)
        guard text(local).contains("PROVIDER_LOCAL_MUTATION_FIXTURE"), imageMatches(local, image.manifest.metadata) == 1 else {
            throw Failure(description: "local display lost provider history or screenshot")
        }
        try await CompanionTranscriptBoundaryChecks.verify(store: store, agentID: normal,
            expected: ["CANONICAL_BEFORE_MUTATIONS", "LIVE_BEFORE_SCREENSHOT", "OUTSIDE_TURN_AFTER_RESTART"],
            excluded: ["PROVIDER_LOCAL_MUTATION_FIXTURE"])

        // A repeated provider item ID must not silently mutate or replace its
        // prior entry. The new conflicting write is refused and disk retained.
        supervisor.qaDeliver(.turnStarted(threadId: reusedThread, turnId: "new-reused-turn"), to: reused)
        supervisor.qaDeliver(.itemStarted(threadId: reusedThread, itemId: "reused-item", kind: .commandExecution, title: "NEW_CONFLICTING_COMMAND"), to: reused)
        supervisor.qaDeliver(.itemCompleted(threadId: reusedThread, itemId: "reused-item", kind: .commandExecution, status: .completed), to: reused)
        supervisor.qaDeliver(.turnCompleted(threadId: reusedThread, turnId: "new-reused-turn", outcome: .completed, errorMessage: nil), to: reused)
        await supervisor.qaSaveTranscript(for: reused)
        let reusedDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.qaTranscriptPersistenceIsBlocked(reused), ContinuousClock.now < reusedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.qaTranscriptPersistenceIsBlocked(reused), try archiveBytes(reused) == reusedBytes else {
            throw Failure(description: "reused provider item identity did not fail closed with archive unchanged")
        }

        // An old open entry remains an immutable historical prefix: its active
        // streaming state is not reconstructed, but a distinct new turn can
        // still be saved without changing or truncating that prior entry.
        var activeNotices: [AgentLocalNotice] = []
        let activeToken = supervisor.addLocalNoticeObserver(for: active) { activeNotices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(activeToken, for: active) }
        let warningCount = warnings.count
        supervisor.qaDeliver(.turnStarted(threadId: activeThread, turnId: "after-open"), to: active)
        supervisor.qaDeliver(.contentDelta(threadId: activeThread, turnId: "after-open", streamKind: .assistant,
                                           delta: "NEW_DISTINCT_TURN_AFTER_OPEN"), to: active)
        supervisor.qaDeliver(.turnCompleted(threadId: activeThread, turnId: "after-open", outcome: .completed, errorMessage: nil), to: active)
        await supervisor.qaSaveTranscript(for: active)
        let activeDeadline = ContinuousClock.now + .seconds(20)
        var activeSaved: AgentDocument?
        while ContinuousClock.now < activeDeadline {
            activeSaved = try await store.load(agentID: active, sessionID: session(active))
            if text(activeSaved).contains("NEW_DISTINCT_TURN_AFTER_OPEN") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let activeSaved, activeSaved.entries.count > activePrior.entries.count,
              Array(activeSaved.entries.prefix(activePrior.entries.count)) == activePrior.entries,
              text(activeSaved).contains("OLD_OPEN_HISTORY"),
              text(activeSaved).components(separatedBy: "NEW_DISTINCT_TURN_AFTER_OPEN").count - 1 == 1,
              !supervisor.qaTranscriptPersistenceIsBlocked(active),
              !activeNotices.contains(where: { $0.title == "Transcript not saved" }), warnings.count == warningCount else {
            throw Failure(description: "old open entry changed or distinct new turn was not safely persisted: \(text(activeSaved))")
        }

        // A later provider event can reuse an old turn ID. It must receive a
        // fresh run identity while the old unfinished entry remains untouched.
        var collisionNotices: [AgentLocalNotice] = []
        let collisionToken = supervisor.addLocalNoticeObserver(for: activeCollision) { collisionNotices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(collisionToken, for: activeCollision) }
        let collisionWarningCount = warnings.count
        supervisor.qaDeliver(.turnStarted(threadId: collisionThread, turnId: "reused-open-turn"), to: activeCollision)
        supervisor.qaDeliver(.contentDelta(threadId: collisionThread, turnId: "reused-open-turn", streamKind: .assistant,
                                           delta: "NEW_CONFLICTING_OPEN_CONTENT"), to: activeCollision)
        supervisor.qaDeliver(.turnCompleted(threadId: collisionThread, turnId: "reused-open-turn", outcome: .completed, errorMessage: nil), to: activeCollision)
        await supervisor.qaSaveTranscript(for: activeCollision)
        let collisionDeadline = ContinuousClock.now + .seconds(20)
        var collisionSaved: AgentDocument?
        while ContinuousClock.now < collisionDeadline {
            collisionSaved = try await store.load(agentID: activeCollision, sessionID: session(activeCollision))
            if text(collisionSaved).contains("NEW_CONFLICTING_OPEN_CONTENT") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let collisionSaved, collisionSaved.entries.count > collisionPrior.entries.count,
              Array(collisionSaved.entries.prefix(collisionPrior.entries.count)) == collisionPrior.entries,
              text(collisionSaved).components(separatedBy: "OLD_OPEN_COLLISION_HISTORY").count - 1 == 1,
              text(collisionSaved).components(separatedBy: "NEW_CONFLICTING_OPEN_CONTENT").count - 1 == 1,
              Set(collisionSaved.entries.map(\.id)).count == collisionSaved.entries.count,
              !supervisor.qaTranscriptPersistenceIsBlocked(activeCollision),
              !collisionNotices.contains(where: { $0.title == "Transcript not saved" }),
              warnings.count == collisionWarningCount else {
            throw Failure(description: "reused turn ID lost old or new content or changed the frozen prefix: \(text(collisionSaved))")
        }
    }
}
