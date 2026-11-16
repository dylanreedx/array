import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A transient preflight fault keeps canonical mutations in order until the
/// same supervisor can strictly prove the repaired archive and save them.
@MainActor
enum TranscriptPreflightRetryChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor SaveGate {
        private(set) var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func pause() async {
            started = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-preflight-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let store = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Preflight retry", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var initial = ManagedAgentTranscriptModel(threadId: thread)
        initial.appendUserPrompt("RETRY_ORIGINAL_HISTORY")
        try await store.saveSnapshot(agentID: id, sessionID: session, document: initial.document)
        guard let before = try await store.load(agentID: id, sessionID: session), !before.entries.isEmpty else {
            throw Failure(description: "retry fixture did not create original history")
        }
        let agentDir = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: agentDir, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "retry fixture snapshot missing")
        }
        let journal = snapshot.deletingLastPathComponent().appendingPathComponent("journal.json")
        let originalSnapshot = try Data(contentsOf: snapshot)
        let originalJournal = try Data(contentsOf: journal)
        let corrupt = Data("UNREADABLE_PREFLIGHT_PRIMARY".utf8)
        try corrupt.write(to: snapshot)
        var warnings: [String] = []
        var attempts = 0
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: store, transcriptMigrationTaskProvider: { attempts += 1; return nil })
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "retry fixture agent did not restore") }
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; supervisor.stopAll() }
        supervisor.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt("RETRY_PROVIDER_LOCAL")],
                                                                restoredMessageCount: 1, omittedEarlier: true), for: id)
        var notices: [AgentLocalNotice] = []
        let noticeToken = supervisor.addLocalNoticeObserver(for: id) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(noticeToken, for: id) }
        func turn(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        turn("RETRY_QUEUED_A")
        await supervisor.qaSaveTranscript(for: id)
        guard supervisor.qaTranscriptPersistenceIsBlocked(id), !warnings.isEmpty,
              notices.filter({ $0.title == "Transcript not saved" }).count == 1,
              try Data(contentsOf: snapshot) == corrupt, try Data(contentsOf: journal) == originalJournal else {
            throw Failure(description: "corrupt preflight was not visibly blocked with archive unchanged")
        }
        turn("RETRY_QUEUED_B")
        await supervisor.qaSaveTranscript(for: id)
        guard supervisor.qaTranscriptPersistenceIsBlocked(id), try Data(contentsOf: snapshot) == corrupt else {
            throw Failure(description: "a write while blocked replaced the corrupt primary")
        }
        // No failed preflight automatically reschedules itself. Let any
        // ordinary trailing debounce settle before measuring the quiet interval.
        try? await Task.sleep(for: .milliseconds(350))
        let quietAttempts = attempts
        try? await Task.sleep(for: .milliseconds(350))
        guard attempts == quietAttempts, notices.filter({ $0.title == "Transcript not saved" }).count == 1 else {
            throw Failure(description: "failed preflight retried without another action or repeated its warning")
        }
        // A missing archive is not evidence that the failed archive was empty.
        let aside = fixture.appendingPathComponent("held-unreadable-archive")
        try FileManager.default.moveItem(at: agentDir, to: aside)
        await supervisor.qaSaveTranscript(for: id)
        guard supervisor.qaTranscriptPersistenceIsBlocked(id), !FileManager.default.fileExists(atPath: agentDir.path) else {
            throw Failure(description: "retry accepted absence after an earlier read failure")
        }
        let heldSnapshot = aside.appendingPathComponent(snapshot.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent("snapshot.json")
        try originalSnapshot.write(to: heldSnapshot)
        try FileManager.default.moveItem(at: aside, to: agentDir)

        let gate = SaveGate()
        supervisor.qaBeforeTranscriptSave = { await gate.pause() }
        // Attaching starts the retry without needing a new turn. New turns
        // arrive synchronously before that retry can replay its pending FIFO.
        let attemptsBeforeAttach = attempts
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "retry-view")
        guard attempts == attemptsBeforeAttach + 1 else {
            await gate.release()
            throw Failure(description: "attaching did not start the repaired archive retry")
        }
        let view = Task { for await _ in attachment.tail {} }
        defer { view.cancel(); supervisor.qaBeforeTranscriptSave = nil }
        turn("RETRY_QUEUED_C")
        turn("RETRY_QUEUED_D")
        let status = AgentCommandInvocation(descriptorID: "array:status", name: "status", surface: .array)
        let beforeStatus = notices.count
        guard case .accepted = await supervisor.accept(.providerCommand(status), for: id), notices.count == beforeStatus + 1 else {
            await gate.release()
            throw Failure(description: "queued real status notice was not delivered exactly once")
        }
        let statusNotice = notices.last!
        let gateDeadline = ContinuousClock.now + .seconds(20)
        while !(await gate.started), ContinuousClock.now < gateDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard await gate.started else {
            await gate.release()
            throw Failure(description: "repaired preflight did not start a guarded save")
        }
        guard !notices.contains(where: { $0.title == "Transcript saving resumed" }),
              try Data(contentsOf: snapshot) == originalSnapshot else {
            await gate.release()
            throw Failure(description: "recovery was announced before guarded persistence completed")
        }
        await gate.release()
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        guard let after = try await store.load(agentID: id, sessionID: session),
              !supervisor.qaTranscriptPersistenceIsBlocked(id),
              Array(after.entries.prefix(before.entries.count)) == before.entries else {
            throw Failure(description: "repair did not retain the exact original archive and complete its save")
        }
        let text = after.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        let markers = ["RETRY_ORIGINAL_HISTORY", "RETRY_QUEUED_A", "RETRY_QUEUED_B", "RETRY_QUEUED_C", "RETRY_QUEUED_D"]
        var last: String.Index?
        for marker in markers {
            guard text.components(separatedBy: marker).count - 1 == 1, let range = text.range(of: marker),
                  last.map({ $0 < range.lowerBound }) ?? true else {
                throw Failure(description: "retry lost, duplicated or reordered \(marker): \(text)")
            }
            last = range.lowerBound
        }
        let savedStatus = after.entries.filter { entry in
            entry.blocks.contains { block in
                guard case .notice = block.payload else { return false }
                return AgentTranscriptCopyController.plainText(for: [block]) == statusNotice.body
                    && AgentTranscriptCopyController.plainText(for: block.children) == statusNotice.title
            }
        }
        guard !text.contains("RETRY_PROVIDER_LOCAL"), savedStatus.count == 1,
              notices.filter({ $0.id == statusNotice.id }).count == 1,
              notices.filter({ $0.title == "Transcript saving resumed" }).count == 1 else {
            throw Failure(description: "retry leaked provider history, duplicated a notice, or did not signal saved recovery")
        }
    }
}
