import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A failed reload must not permit a later launch to replace an archive with a
/// projection made from only the new turn or a bounded provider restore.
@MainActor
enum TranscriptSaveGuardChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("guarded-save", isDirectory: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: id, displayName: "Guard", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        func supervisor(_ warn: @escaping (String) -> Void = { _ in }) -> AgentSupervisor {
            let value = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                        warn: warn, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
            _ = value.restore()
            return value
        }
        func turn(_ owner: AgentSupervisor, _ marker: String, agent: AgentID? = nil) {
            let target = agent ?? id
            let thread = AgentSupervisor.threadId(for: target)
            owner.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: target)
            owner.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: target)
            owner.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: target)
        }
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }
        let first = supervisor()
        turn(first, "ORIGINAL_DISK_HISTORY")
        await first.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !first.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            first.qaReleaseTranscriptIfDormant(id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard first.isTranscriptReleased(id) else { throw Failure(description: "fixture did not save and release") }
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        guard let original = try await transcripts.load(agentID: id, sessionID: session), !original.entries.isEmpty else {
            throw Failure(description: "fixture did not persist the original history")
        }
        let agentRoot = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: agentRoot, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture snapshot missing")
        }
        let originalBytes = try Data(contentsOf: snapshot)
        let archive = try JSONCodec.makeDecoder().decode(AgentTranscriptArchive.self, from: originalBytes)
        // Make a valid, matching backup: the general reader can fall back to it
        // when the primary is corrupt, but a guarded reload must reject it.
        let writer = AtomicWriter(backupsDirectory: snapshot.deletingLastPathComponent().appendingPathComponent("backups"),
                                  retainedBackups: 2, prettyPrint: false, legacyBackupPolicy: .targetDedicated)
        try writer.write(archive, to: snapshot)
        let corrupt = Data("BROKEN_PRIMARY_WITH_VALID_BACKUP".utf8)
        try corrupt.write(to: snapshot)
        guard let fallback = try await transcripts.load(agentID: id, sessionID: session),
              fallback.entries.map(\.id) == original.entries.map(\.id) else {
            throw Failure(description: "fixture did not establish a valid matching backup")
        }
        let bad = first.transcriptAttachment(for: id, reboundTo: "bad-primary")
        let badView = Task { for await _ in bad.tail {} }
        if let reload = bad.reload { await reload.value }
        badView.cancel()
        guard first.isTranscriptReleased(id) else {
            throw Failure(description: "released history accepted a backup while its primary was corrupt")
        }
        turn(first, "QUEUED_AFTER_FAILED_RELOAD")
        let failedRetry = first.transcriptAttachment(for: id, reboundTo: "retry-primary")
        let retryView = Task { for await _ in failedRetry.tail {} }
        if let reload = failedRetry.reload { await reload.value }
        retryView.cancel()
        guard first.isTranscriptReleased(id), try Data(contentsOf: snapshot) == corrupt else {
            throw Failure(description: "a failed reload changed its corrupt primary")
        }

        // Restart with the corrupt primary, then write. A backup that happens to
        // decode is not permission to replace the unreadable primary.
        var warnings: [String] = []
        let second = supervisor { warnings.append($0) }
        var notices: [AgentLocalNotice] = []
        let noticeToken = second.addLocalNoticeObserver(for: id) { notices.append($0) }
        defer { second.removeLocalNoticeObserver(noticeToken, for: id) }
        turn(second, "AFTER_CORRUPT_RESTART")
        await second.qaSaveTranscript(for: id)
        guard second.qaTranscriptPersistenceIsBlocked(id), !warnings.isEmpty,
              notices.contains(where: { $0.title == "Transcript not saved" }),
              try Data(contentsOf: snapshot) == corrupt else {
            throw Failure(description: "write after restart overwrote corrupt history or did not visibly warn")
        }
        // Repeated attempts and an idle-release decision must not spin or erase
        // the in-memory projection while the old archive is protected.
        let warningCount = warnings.count
        await second.qaSaveTranscript(for: id)
        second.qaReleaseTranscriptIfDormant(id)
        guard warnings.count == warningCount, !second.isTranscriptReleased(id),
              second.transcriptDocument(for: id) != nil, try Data(contentsOf: snapshot) == corrupt else {
            throw Failure(description: "blocked transcript retried or was released")
        }

        // A readable, richer archive is also unowned after restart. A bounded
        // restore and a new headless turn must not replace that archive.
        try originalBytes.write(to: snapshot)
        var restoredWarnings: [String] = []
        let third = supervisor { restoredWarnings.append($0) }
        third.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt("BOUNDED_RESTORE")],
                                                           restoredMessageCount: 1, omittedEarlier: true), for: id)
        turn(third, "NEW_TURN_AFTER_RESTART")
        await third.qaSaveTranscript(for: id)
        guard third.qaTranscriptPersistenceIsBlocked(id), !restoredWarnings.isEmpty,
              try Data(contentsOf: snapshot) == originalBytes,
              try await transcripts.load(agentID: id, sessionID: session) == original else {
            throw Failure(description: "bounded restore plus new turn replaced existing canonical history")
        }

        // Startup migration can still be pending when the first event arrives.
        // Do not create canonical history over a legacy-only agent directory.
        let legacyID = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: legacyID, displayName: "Legacy", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let legacyDir = transcriptRoot.appendingPathComponent(legacyID.rawValue.uuidString)
            .appendingPathComponent("legacy-session")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyFile = legacyDir.appendingPathComponent("snapshot.json")
        let legacyBytes = Data("LEGACY_ARCHIVE_BYTES".utf8)
        try legacyBytes.write(to: legacyFile)
        let legacySupervisor = supervisor()
        turn(legacySupervisor, "LEGACY_NEW_TURN", agent: legacyID)
        await legacySupervisor.qaSaveTranscript(for: legacyID)
        guard legacySupervisor.qaTranscriptPersistenceIsBlocked(legacyID),
              try Data(contentsOf: legacyFile) == legacyBytes,
              (try FileManager.default.contentsOfDirectory(atPath: legacyDir.deletingLastPathComponent().path)) == ["legacy-session"] else {
            throw Failure(description: "a first write replaced or bypassed pending legacy migration")
        }
    }
}
