import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// The first transcript preflight waits for the actual startup migration task;
/// legacy history is not mistaken for a permanent archive error.
@MainActor
enum TranscriptMigrationRaceChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            guard !opened else { return }
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-migration-preflight", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts", isDirectory: true)
        let store = AgentTranscriptStore(root: transcriptRoot)
        let early = AgentID(rawValue: UUID())
        let migrationFirst = AgentID(rawValue: UUID())
        let malformed = AgentID(rawValue: UUID())
        for id in [early, migrationFirst, malformed] {
            try agents.upsert(AgentRecord(id: id, displayName: "Migration ordering", harness: .pi,
                                         model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                         createdAt: Date(), lastActivityAt: Date()))
        }
        func session(_ id: AgentID) -> String { AgentTranscriptStore.canonicalSessionID(for: id) }
        func body(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        func primaryFiles(_ id: AgentID) throws -> (snapshot: URL, journal: URL) {
            let directory = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
                  let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
                throw Failure(description: "legacy fixture has no snapshot")
            }
            return (snapshot, snapshot.deletingLastPathComponent().appendingPathComponent("journal.json"))
        }
        func seed(_ id: AgentID, marker: String) async throws -> (String, AgentDocument, Data, Data) {
            let legacy = "managed-\(UUID().uuidString)"
            var model = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: id))
            model.appendUserPrompt(marker)
            try await store.saveSnapshot(agentID: id, sessionID: legacy, document: model.document)
            guard let document = try await store.load(agentID: id, sessionID: legacy), !document.entries.isEmpty,
                  try await store.load(agentID: id, sessionID: session(id)) == nil else {
                throw Failure(description: "legacy fixture was not isolated from canonical storage")
            }
            let files = try primaryFiles(id)
            return (legacy, document, try Data(contentsOf: files.snapshot), try Data(contentsOf: files.journal))
        }
        func deliver(_ supervisor: AgentSupervisor, id: AgentID, marker: String) {
            let thread = AgentSupervisor.threadId(for: id)
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        func once(_ marker: String, _ text: String) -> Bool { text.components(separatedBy: marker).count - 1 == 1 }

        // Both real legacy sessions exist before the startup task begins. Hold
        // that task before it submits to the store actor, then send the first
        // turn: the preflight must wait rather than turn legacy state into a
        // permanent persistence failure.
        let (_, earlyPrior, earlySnapshot, earlyJournal) = try await seed(early, marker: "LEGACY_FIRST_HISTORY")
        let (_, migratedPrior, _, _) = try await seed(migrationFirst, marker: "GLOBAL_FIRST_HISTORY")
        let earlyFiles = try primaryFiles(early)
        let gate = Gate()
        let migrationTask: Task<AgentTranscriptStore.MigrationReport, Error> = Task.detached {
            await gate.wait()
            return try await store.migrateLegacySessionDirectories()
        }
        defer { Task { await gate.open() } }
        var providerCalls = 0
        var warnings: [String] = []
        var migrationSlot: Task<AgentTranscriptStore.MigrationReport, Error>?
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: store,
                                         transcriptMigrationTaskProvider: { providerCalls += 1; return migrationSlot })
        _ = supervisor.restore()
        guard [early, migrationFirst, malformed].allSatisfy({ supervisor.records[$0] != nil }) else {
            throw Failure(description: "migration-ordering agents did not restore")
        }
        // The supervisor can already exist when the interactive host registers
        // migration. The provider must read the later task, not capture nil.
        guard providerCalls == 0 else { throw Failure(description: "migration provider ran before any transcript preflight") }
        migrationSlot = migrationTask
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; supervisor.stopAll() }
        deliver(supervisor, id: early, marker: "FIRST_WRITE_BEFORE_MIGRATION")
        var earlySaveFinished = false
        let earlySave = Task { @MainActor in
            await supervisor.qaSaveTranscript(for: early)
            earlySaveFinished = true
        }
        let providerDeadline = ContinuousClock.now + .seconds(10)
        while providerCalls == 0, ContinuousClock.now < providerDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Give a preflight that incorrectly skipped the task time to run; the
        // positive ordering and subsequent archive checks do not rely on this
        // observation window, but the negative pending assertion is timing-based.
        try? await Task.sleep(for: .milliseconds(300))
        let canonicalBeforeMigration = try await store.load(agentID: early, sessionID: session(early))
        let untouchedWhileWaiting = (try? Data(contentsOf: earlyFiles.snapshot)) == earlySnapshot
            && (try? Data(contentsOf: earlyFiles.journal)) == earlyJournal
        let pendingCorrectly = providerCalls > 0 && !earlySaveFinished
            && !supervisor.qaTranscriptPersistenceIsBlocked(early) && warnings.isEmpty
            && canonicalBeforeMigration == nil && untouchedWhileWaiting
        await gate.open()
        let report = try await migrationTask.value
        await earlySave.value
        guard pendingCorrectly else {
            throw Failure(description: "first-write preflight did not wait for the pending startup migration")
        }
        guard report.adopted.contains(early), report.adopted.contains(migrationFirst),
              let earlySaved = try await store.load(agentID: early, sessionID: session(early)),
              !supervisor.qaTranscriptPersistenceIsBlocked(early), warnings.isEmpty,
              Array(earlySaved.entries.prefix(earlyPrior.entries.count)) == earlyPrior.entries,
              once("LEGACY_FIRST_HISTORY", body(earlySaved)), once("FIRST_WRITE_BEFORE_MIGRATION", body(earlySaved)) else {
            throw Failure(description: "first-write preflight lost migrated history or failed to persist its queued turn")
        }

        // The same real startup migration finished before this agent's first
        // write. Its later preflight must extend the adopted canonical archive.
        guard let adopted = try await store.load(agentID: migrationFirst, sessionID: session(migrationFirst)),
              adopted.entries == migratedPrior.entries else {
            throw Failure(description: "global-first migration did not adopt the complete legacy transcript")
        }
        deliver(supervisor, id: migrationFirst, marker: "WRITE_AFTER_GLOBAL_MIGRATION")
        await supervisor.qaSaveTranscript(for: migrationFirst)
        guard let migratedSaved = try await store.load(agentID: migrationFirst, sessionID: session(migrationFirst)),
              !supervisor.qaTranscriptPersistenceIsBlocked(migrationFirst), warnings.isEmpty,
              Array(migratedSaved.entries.prefix(migratedPrior.entries.count)) == migratedPrior.entries,
              once("GLOBAL_FIRST_HISTORY", body(migratedSaved)), once("WRITE_AFTER_GLOBAL_MIGRATION", body(migratedSaved)) else {
            throw Failure(description: "global-first migration lost history or the subsequent turn")
        }

        // Create the corrupt fixture after the actual startup pass has finished,
        // so the strict preflight, rather than the existing global migrator's
        // quarantine policy, owns the behavior being checked.
        _ = try await seed(malformed, marker: "UNREADABLE_PRIOR_HISTORY")
        let malformedFiles = try primaryFiles(malformed)
        let badSnapshot = Data("unreadable legacy snapshot".utf8)
        let badJournal = Data("unreadable legacy journal".utf8)
        try badSnapshot.write(to: malformedFiles.snapshot)
        try badJournal.write(to: malformedFiles.journal)
        var notices: [AgentLocalNotice] = []
        let token = supervisor.addLocalNoticeObserver(for: malformed) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(token, for: malformed) }
        deliver(supervisor, id: malformed, marker: "MALFORMED_LEGACY_NEW_TURN")
        await supervisor.qaSaveTranscript(for: malformed)
        guard supervisor.qaTranscriptPersistenceIsBlocked(malformed), !warnings.isEmpty,
              notices.contains(where: { $0.title == "Transcript not saved" }),
              try Data(contentsOf: malformedFiles.snapshot) == badSnapshot,
              try Data(contentsOf: malformedFiles.journal) == badJournal,
              try await store.load(agentID: malformed, sessionID: session(malformed)) == nil else {
            throw Failure(description: "malformed legacy archive was modified, replaced, or did not visibly fail closed")
        }
    }
}
