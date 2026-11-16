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

        // Resume a readable, richer archive after restart. A bounded provider
        // restore stays local while the canonical archive retains its prefix
        // and gains the new turn exactly once.
        try originalBytes.write(to: snapshot)
        var restoredWarnings: [String] = []
        let third = supervisor { restoredWarnings.append($0) }
        third.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt("BOUNDED_RESTORE")],
                                                           restoredMessageCount: 1, omittedEarlier: true), for: id)
        turn(third, "NEW_TURN_AFTER_RESTART")
        await third.qaSaveTranscript(for: id)
        guard let saved = try await transcripts.load(agentID: id, sessionID: session) else {
            throw Failure(description: "bounded restore plus new turn did not save a canonical archive")
        }
        func plain(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        let savedText = plain(saved)
        let localText = plain(third.transcriptDocument(for: id))
        guard !third.qaTranscriptPersistenceIsBlocked(id), restoredWarnings.isEmpty,
              Array(saved.entries.prefix(original.entries.count)).map(\.id) == original.entries.map(\.id),
              savedText.contains("ORIGINAL_DISK_HISTORY"),
              savedText.components(separatedBy: "NEW_TURN_AFTER_RESTART").count - 1 == 1,
              !savedText.contains("BOUNDED_RESTORE"),
              localText.contains("BOUNDED_RESTORE"),
              localText.components(separatedBy: "NEW_TURN_AFTER_RESTART").count - 1 == 1 else {
            throw Failure(description: "restart failed to preserve canonical history, save the new turn, or keep the bounded restore local")
        }

        // A true older archive has no lifecycle field. Decoding it defaults to
        // an open entry; that historical prefix must remain frozen while an
        // unrelated new turn is appended after a restart.
        let oldID = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: oldID, displayName: "Old archive", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let oldSession = AgentTranscriptStore.canonicalSessionID(for: oldID)
        var oldModel = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: oldID))
        oldModel.appendUserPrompt("MISSING_LIFECYCLE_OLD_HISTORY")
        try await transcripts.saveSnapshot(agentID: oldID, sessionID: oldSession, document: oldModel.document)
        let oldRoot = transcriptRoot.appendingPathComponent(oldID.rawValue.uuidString)
        guard let oldEnumerator = FileManager.default.enumerator(at: oldRoot, includingPropertiesForKeys: nil),
              let oldSnapshot = oldEnumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "old archive fixture has no snapshot")
        }
        guard var oldJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: oldSnapshot)) as? [String: Any],
              var oldDocumentJSON = oldJSON["document"] as? [String: Any],
              var oldEntriesJSON = oldDocumentJSON["entries"] as? [[String: Any]], !oldEntriesJSON.isEmpty else {
            throw Failure(description: "old archive fixture has no document entries")
        }
        for index in oldEntriesJSON.indices { oldEntriesJSON[index].removeValue(forKey: "lifecycle") }
        oldDocumentJSON["entries"] = oldEntriesJSON
        oldJSON["document"] = oldDocumentJSON
        oldJSON.removeValue(forKey: "saveGeneration")
        let oldBytes = try JSONSerialization.data(withJSONObject: oldJSON, options: [.sortedKeys])
        try oldBytes.write(to: oldSnapshot)
        let oldArchive = try JSONCodec.makeDecoder().decode(AgentTranscriptArchive.self, from: oldBytes)
        guard let oldEntry = oldArchive.document.entries.first, case .open = oldEntry.lifecycle else {
            throw Failure(description: "missing-lifecycle fixture did not decode with an open entry")
        }
        let oldSupervisor = supervisor()
        turn(oldSupervisor, "MISSING_LIFECYCLE_NEW_TURN", agent: oldID)
        await oldSupervisor.qaSaveTranscript(for: oldID)
        guard let oldSaved = try await transcripts.load(agentID: oldID, sessionID: oldSession),
              !oldSupervisor.qaTranscriptPersistenceIsBlocked(oldID),
              Array(oldSaved.entries.prefix(oldArchive.document.entries.count)) == oldArchive.document.entries,
              plain(oldSaved).contains("MISSING_LIFECYCLE_OLD_HISTORY"),
              plain(oldSaved).components(separatedBy: "MISSING_LIFECYCLE_NEW_TURN").count - 1 == 1 else {
            throw Failure(description: "missing-lifecycle archive did not retain its exact old entries and append the new turn")
        }

        // A complete-looking snapshot whose journal names another base version
        // is ambiguous. Do not treat its readable snapshot as proof that an
        // attempted new turn may replace either primary file.
        let mismatchID = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: mismatchID, displayName: "Mismatch", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let mismatchSession = AgentTranscriptStore.canonicalSessionID(for: mismatchID)
        var mismatchModel = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: mismatchID))
        mismatchModel.appendUserPrompt("MISMATCH_OLD_HISTORY")
        try await transcripts.saveSnapshot(agentID: mismatchID, sessionID: mismatchSession, document: mismatchModel.document)
        let mismatchRoot = transcriptRoot.appendingPathComponent(mismatchID.rawValue.uuidString)
        guard let mismatchEnumerator = FileManager.default.enumerator(at: mismatchRoot, includingPropertiesForKeys: nil) else {
            throw Failure(description: "mismatched archive fixture is missing")
        }
        let mismatchFiles = mismatchEnumerator.allObjects.compactMap { $0 as? URL }
        guard let mismatchSnapshot = mismatchFiles.first(where: { $0.lastPathComponent == "snapshot.json" }),
              let mismatchJournal = mismatchFiles.first(where: { $0.lastPathComponent == "journal.json" }) else {
            throw Failure(description: "mismatched archive fixture has no primary files")
        }
        var journal = try JSONCodec.makeDecoder().decode(AgentTranscriptJournal.self, from: Data(contentsOf: mismatchJournal))
        journal.baseVersion += 1
        try JSONCodec.makeEncoder().encode(journal).write(to: mismatchJournal)
        let mismatchSnapshotBytes = try Data(contentsOf: mismatchSnapshot)
        let mismatchJournalBytes = try Data(contentsOf: mismatchJournal)
        var mismatchWarnings: [String] = []
        let mismatchSupervisor = supervisor { mismatchWarnings.append($0) }
        turn(mismatchSupervisor, "MISMATCH_NEW_TURN", agent: mismatchID)
        await mismatchSupervisor.qaSaveTranscript(for: mismatchID)
        guard mismatchSupervisor.qaTranscriptPersistenceIsBlocked(mismatchID), !mismatchWarnings.isEmpty,
              try Data(contentsOf: mismatchSnapshot) == mismatchSnapshotBytes,
              try Data(contentsOf: mismatchJournal) == mismatchJournalBytes else {
            throw Failure(description: "mismatched snapshot and journal were overwritten or did not warn")
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
