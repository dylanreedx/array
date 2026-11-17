import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A failed startup migration must not poison unrelated canonical archives or
/// prevent this supervisor from recovering a repaired archive later.
@MainActor
enum TranscriptMigrationFailureRecoveryChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private struct InjectedMigrationFailure: Error {}

    private actor MigrationCounter {
        private(set) var count = 0
        func didRun() { count += 1 }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-migration-failure-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts", isDirectory: true)
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let healthy = AgentID(rawValue: UUID()), repaired = AgentID(rawValue: UUID())
        let absent = AgentID(rawValue: UUID()), legacyOnly = AgentID(rawValue: UUID())
        for id in [healthy, repaired, absent, legacyOnly] {
            try agents.upsert(AgentRecord(id: id, displayName: "Migration failure recovery", harness: .pi,
                                         model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                         createdAt: Date(), lastActivityAt: Date()))
        }
        func session(_ id: AgentID) -> String { AgentTranscriptStore.canonicalSessionID(for: id) }
        func seed(_ id: AgentID, _ marker: String) async throws -> AgentDocument {
            var model = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: id))
            model.appendUserPrompt(marker)
            try await transcripts.saveSnapshot(agentID: id, sessionID: session(id), document: model.document)
            guard let saved = try await transcripts.load(agentID: id, sessionID: session(id)), !saved.entries.isEmpty else {
                throw Failure(description: "fixture failed to persist prior canonical history")
            }
            return saved
        }
        func text(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        func once(_ marker: String, in value: String) -> Bool {
            value.components(separatedBy: marker).count - 1 == 1
        }
        let healthyPrior = try await seed(healthy, "MIGRATION_FAILED_HEALTHY_PRIOR")
        let repairedPrior = try await seed(repaired, "MIGRATION_FAILED_REPAIRED_PRIOR")
        let legacySession = "managed-\(UUID().uuidString)"
        var legacyModel = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: legacyOnly))
        legacyModel.appendUserPrompt("MIGRATION_FAILED_LEGACY_HISTORY")
        try await transcripts.saveSnapshot(agentID: legacyOnly, sessionID: legacySession, document: legacyModel.document)
        let legacyRoot = transcriptRoot.appendingPathComponent(legacyOnly.rawValue.uuidString)
        guard let legacyEnumerator = FileManager.default.enumerator(at: legacyRoot, includingPropertiesForKeys: nil),
              let legacySnapshot = legacyEnumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture could not find the legacy snapshot")
        }
        let legacySnapshotBytes = try Data(contentsOf: legacySnapshot)
        let legacyJournal = legacySnapshot.deletingLastPathComponent().appendingPathComponent("journal.json")
        let legacyJournalBytes = try Data(contentsOf: legacyJournal)
        let repairedRoot = transcriptRoot.appendingPathComponent(repaired.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: repairedRoot, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture could not find the repair snapshot")
        }
        let snapshotBytes = try Data(contentsOf: snapshot)
        let journal = snapshot.deletingLastPathComponent().appendingPathComponent("journal.json")
        let journalBytes = try Data(contentsOf: journal)
        let corruptBytes = Data("TEMPORARILY_UNREADABLE_PRIMARY".utf8)
        try corruptBytes.write(to: snapshot)

        let counter = MigrationCounter()
        let failedTask: Task<AgentTranscriptStore.MigrationReport, Error> = Task.detached {
            await counter.didRun()
            throw InjectedMigrationFailure()
        }
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: transcripts, transcriptMigrationTaskProvider: { failedTask })
        _ = supervisor.restore()
        guard [healthy, repaired, absent, legacyOnly].allSatisfy({ supervisor.records[$0] != nil }) else {
            throw Failure(description: "fixture agents did not restore")
        }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; supervisor.stopAll() }
        var healthyNotices: [AgentLocalNotice] = []
        var repairedNotices: [AgentLocalNotice] = []
        var absentNotices: [AgentLocalNotice] = []
        var legacyNotices: [AgentLocalNotice] = []
        let healthyToken = supervisor.addLocalNoticeObserver(for: healthy) { healthyNotices.append($0) }
        let repairedToken = supervisor.addLocalNoticeObserver(for: repaired) { repairedNotices.append($0) }
        let absentToken = supervisor.addLocalNoticeObserver(for: absent) { absentNotices.append($0) }
        let legacyToken = supervisor.addLocalNoticeObserver(for: legacyOnly) { legacyNotices.append($0) }
        defer {
            supervisor.removeLocalNoticeObserver(healthyToken, for: healthy)
            supervisor.removeLocalNoticeObserver(repairedToken, for: repaired)
            supervisor.removeLocalNoticeObserver(absentToken, for: absent)
            supervisor.removeLocalNoticeObserver(legacyToken, for: legacyOnly)
        }
        func turn(_ id: AgentID, _ marker: String) {
            let thread = AgentSupervisor.threadId(for: id)
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }

        // The retained task already failed, but an unrelated strictly readable
        // canonical archive must remain usable without another broad migration.
        turn(healthy, "MIGRATION_FAILED_HEALTHY_NEW")
        await supervisor.qaSaveTranscript(for: healthy)
        guard let healthySaved = try await transcripts.load(agentID: healthy, sessionID: session(healthy)),
              !supervisor.qaTranscriptPersistenceIsBlocked(healthy),
              Array(healthySaved.entries.prefix(healthyPrior.entries.count)) == healthyPrior.entries,
              once("MIGRATION_FAILED_HEALTHY_PRIOR", in: text(healthySaved)),
              once("MIGRATION_FAILED_HEALTHY_NEW", in: text(healthySaved)),
              !healthyNotices.contains(where: { $0.title == "Transcript not saved" }) else {
            throw Failure(description: "failed migration blocked an unaffected readable canonical archive")
        }

        // An unreadable archive must still fail closed even though the failed
        // task is no longer allowed to block every agent globally.
        turn(repaired, "MIGRATION_FAILED_QUEUED_A")
        await supervisor.qaSaveTranscript(for: repaired)
        guard supervisor.qaTranscriptPersistenceIsBlocked(repaired),
              repairedNotices.filter({ $0.title == "Transcript not saved" }).count == 1,
              try Data(contentsOf: snapshot) == corruptBytes,
              try Data(contentsOf: journal) == journalBytes else {
            throw Failure(description: "unreadable archive did not remain blocked and unchanged after failed migration")
        }
        try snapshotBytes.write(to: snapshot)
        turn(repaired, "MIGRATION_FAILED_QUEUED_B")
        await supervisor.qaSaveTranscript(for: repaired)
        guard let repairedSaved = try await transcripts.load(agentID: repaired, sessionID: session(repaired)),
              !supervisor.qaTranscriptPersistenceIsBlocked(repaired),
              Array(repairedSaved.entries.prefix(repairedPrior.entries.count)) == repairedPrior.entries else {
            throw Failure(description: "same supervisor did not save the repaired archive's exact prior prefix")
        }
        let value = text(repairedSaved)
        let markers = ["MIGRATION_FAILED_REPAIRED_PRIOR", "MIGRATION_FAILED_QUEUED_A", "MIGRATION_FAILED_QUEUED_B"]
        var previous: String.Index?
        for marker in markers {
            guard once(marker, in: value), let range = value.range(of: marker),
                  previous.map({ $0 < range.lowerBound }) ?? true else {
                throw Failure(description: "same-supervisor retry lost, duplicated or reordered \(marker): \(value)")
            }
            previous = range.lowerBound
        }
        guard repairedNotices.filter({ $0.title == "Transcript saving resumed" }).count == 1,
              await counter.count == 1 else {
            throw Failure(description: "recovery notice was missing or broad migration ran more than once")
        }

        // A failed migration is not evidence that an absent canonical path is
        // truly empty or that a legacy-only archive may be overwritten.
        turn(absent, "MIGRATION_FAILED_ABSENT_NEW")
        await supervisor.qaSaveTranscript(for: absent)
        guard supervisor.qaTranscriptPersistenceIsBlocked(absent),
              absentNotices.contains(where: { $0.title == "Transcript not saved" }),
              !FileManager.default.fileExists(atPath: transcriptRoot.appendingPathComponent(absent.rawValue.uuidString).path) else {
            throw Failure(description: "absent canonical archive was accepted after migration failed")
        }
        turn(legacyOnly, "MIGRATION_FAILED_LEGACY_NEW")
        await supervisor.qaSaveTranscript(for: legacyOnly)
        guard supervisor.qaTranscriptPersistenceIsBlocked(legacyOnly),
              legacyNotices.contains(where: { $0.title == "Transcript not saved" }),
              try Data(contentsOf: legacySnapshot) == legacySnapshotBytes,
              try Data(contentsOf: legacyJournal) == legacyJournalBytes,
              try await transcripts.load(agentID: legacyOnly, sessionID: session(legacyOnly)) == nil,
              await counter.count == 1 else {
            throw Failure(description: "legacy-only archive was changed or broadly migrated after failure")
        }
    }
}
