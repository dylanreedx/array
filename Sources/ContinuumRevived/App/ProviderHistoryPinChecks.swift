import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Exercises retention pins across overlapping provider reads and ordinary writes.
@MainActor
enum ProviderHistoryPinChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .milliseconds(150)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        let fixture = root.appendingPathComponent("provider-history-pin", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let adopting = AgentID(rawValue: UUID())
        let deleted = AgentID(rawValue: UUID())
        let overlap = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Provider pin", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        for (agent, name) in [(adopting, "Adoption pin"), (deleted, "Deleted adoption pin"), (overlap, "Overlapping adoption")] {
            try agents.upsert(AgentRecord(id: agent, displayName: name, harness: .pi,
                                         model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                         createdAt: Date(), lastActivityAt: Date()))
        }
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        defer { supervisor.stopAll() }
        guard supervisor.beginProviderHistoryRead(for: AgentID(rawValue: UUID())) == nil,
              let nilRead = supervisor.beginProviderHistoryRead(for: id),
              let failedRead = supervisor.beginProviderHistoryRead(for: id), nilRead != failedRead else {
            throw Failure(description: "could not establish independent provider read pins")
        }
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        deliver("PROVIDER_PIN_FIRST_END")
        await supervisor.qaSaveTranscript(for: id)
        supervisor.qaReleaseTranscriptIfDormant(id)
        try? await Task.sleep(for: .milliseconds(250))
        let residentText = (supervisor.transcriptDocumentProjection(for: id)?.entries ?? [])
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard !supervisor.isTranscriptReleased(id), residentText.contains("PROVIDER_PIN_FIRST_END") else {
            throw Failure(description: "two pending provider reads did not retain live history")
        }
        // The first completion may return nil. A repeated completion must not
        // remove the still-running independent read's token.
        supervisor.endProviderHistoryRead(nilRead, for: id)
        supervisor.endProviderHistoryRead(nilRead, for: id)
        deliver("PROVIDER_PIN_SECOND_END")
        await supervisor.qaSaveTranscript(for: id)
        supervisor.qaReleaseTranscriptIfDormant(id)
        try? await Task.sleep(for: .milliseconds(250))
        guard !supervisor.isTranscriptReleased(id) else {
            throw Failure(description: "a second pending read was unpinned by the first completion")
        }
        // The other read can fail. Its completion must schedule normal release
        // without requiring a later read, write, tile detach, or manual release.
        supervisor.endProviderHistoryRead(failedRead, for: id)
        let deadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id),
              supervisor.beginProviderHistoryRead(for: id) == nil,
              let document = try await transcripts.load(agentID: id, sessionID: session) else {
            throw Failure(description: "history did not release after the final provider read or accepted an already-released read")
        }
        let text = document.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard text.components(separatedBy: "PROVIDER_PIN_FIRST_END").count - 1 == 1,
              text.components(separatedBy: "PROVIDER_PIN_SECOND_END").count - 1 == 1,
              let first = text.range(of: "PROVIDER_PIN_FIRST_END"), let second = text.range(of: "PROVIDER_PIN_SECOND_END"),
              first.lowerBound < second.lowerBound else {
            throw Failure(description: "normal writes during provider reads did not persist once in order")
        }
        try await checkAdoption(supervisor, id: adopting, deleted: deleted, fixture: fixture)
        try checkOverlappingAdoption(supervisor, id: overlap, fixture: fixture)
    }

    private static func checkOverlappingAdoption(_ supervisor: AgentSupervisor, id: AgentID, fixture: URL) throws {
        let url = fixture.appendingPathComponent("overlapping-adoption.jsonl")
        let firstLine = #"{"type":"user","uuid":"first-id","message":{"role":"user","content":"ADOPTION_FIRST_IMPORTED"}}"#
        let laterLine = #"{"type":"user","uuid":"later-id","message":{"role":"user","content":"ADOPTION_LATER_NOT_SKIPPED"}}"#
        let firstData = Data((firstLine + "\n").utf8)
        let allData = Data((firstLine + "\n" + laterLine + "\n").utf8)
        try allData.write(to: url)
        let thread = AgentSupervisor.threadId(for: id)
        let firstRead = ClaudeSessionTranscriptReader.parse(lines: [firstLine], threadId: thread)
        let laterRead = ClaudeSessionTranscriptReader.parse(lines: [firstLine, laterLine], threadId: thread)
        guard firstRead.steps.contains(.userPrompt("ADOPTION_FIRST_IMPORTED")),
              laterRead.steps.contains(.userPrompt("ADOPTION_LATER_NOT_SKIPPED")) else {
            throw Failure(description: "overlapping adoption fixture did not parse both provider turns")
        }
        let slow = supervisor.beginAdoptingSessionHistory(for: id)
        let fast = supervisor.beginAdoptingSessionHistory(for: id)
        guard supervisor.finishAdoptingSessionHistory(firstRead, for: id, token: fast, url: url, offset: UInt64(firstData.count)),
              supervisor.isProviderHistoryReadActive(slow, for: id),
              !supervisor.finishAdoptingSessionHistory(laterRead, for: id, token: slow, url: url, offset: UInt64(allData.count)),
              !supervisor.isProviderHistoryReadActive(slow, for: id),
              supervisor.rehydratedTranscript(for: id)?.steps == firstRead.steps,
              supervisor.sessionFileMark(for: id, url: url) == UInt64(firstData.count) else {
            throw Failure(description: "later completion advanced the mark beyond the adoption history actually imported")
        }
        let catchUp = AgentSupervisor.readOutsideTurns(segments: [(url, UInt64(firstData.count))], prefixBefore: nil,
                                                        provider: .claude, threadId: thread)
        guard catchUp.turns.steps.contains(.userPrompt("ADOPTION_LATER_NOT_SKIPPED")) else {
            throw Failure(description: "the ignored adoption read's later history was not available to catch up")
        }
    }

    private static func checkAdoption(_ supervisor: AgentSupervisor, id: AgentID, deleted: AgentID, fixture: URL) async throws {
        let first = supervisor.beginAdoptingSessionHistory(for: id)
        let second = supervisor.beginAdoptingSessionHistory(for: id)
        guard first != second else { throw Failure(description: "adoption reads did not receive independent tokens") }
        let thread = AgentSupervisor.threadId(for: id)
        let marker = "ADOPTION_PIN_WRITE_END"
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        await supervisor.qaSaveTranscript(for: id)
        supervisor.qaReleaseTranscriptIfDormant(id)
        try? await Task.sleep(for: .milliseconds(250))
        guard !supervisor.isTranscriptReleased(id) else { throw Failure(description: "active adoption reads did not pin transcript") }
        let empty = RehydratedTranscript(steps: [], restoredMessageCount: 0, omittedEarlier: false)
        let url = fixture.appendingPathComponent("adoption-session.jsonl")
        guard supervisor.finishAdoptingSessionHistory(empty, for: id, token: first, url: url, offset: 1),
              !supervisor.finishAdoptingSessionHistory(empty, for: id, token: first, url: url, offset: 999) else {
            throw Failure(description: "adoption completion did not reject a repeated token")
        }
        supervisor.qaReleaseTranscriptIfDormant(id)
        try? await Task.sleep(for: .milliseconds(250))
        guard !supervisor.isTranscriptReleased(id), supervisor.sessionFileMark(for: id, url: url) == 1 else {
            throw Failure(description: "early empty or repeated adoption completion unpinned a later read or moved its mark")
        }
        guard supervisor.isProviderHistoryReadActive(second, for: id),
              !supervisor.finishAdoptingSessionHistory(empty, for: id, token: second, url: url, offset: 2),
              !supervisor.isProviderHistoryReadActive(second, for: id) else {
            throw Failure(description: "later adoption completion did not retire its independent pin")
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id), supervisor.sessionFileMark(for: id, url: url) == 1 else {
            throw Failure(description: "final adoption completion did not schedule release")
        }
        let stale = supervisor.beginAdoptingSessionHistory(for: deleted)
        guard supervisor.archive(deleted).recordDeleted else { throw Failure(description: "adoption stale-token fixture could not archive") }
        let nonempty = RehydratedTranscript(steps: [.userPrompt("STALE_ADOPTION_MUST_NOT_APPEAR")], restoredMessageCount: 1, omittedEarlier: false)
        let accepted = supervisor.finishAdoptingSessionHistory(nonempty, for: deleted, token: stale, url: url, offset: 7)
        guard !accepted, supervisor.records[deleted] == nil, supervisor.rehydratedTranscript(for: deleted) == nil,
              supervisor.sessionFileMark(for: deleted, url: url) == nil else {
            throw Failure(description: "a deleted agent accepted a stale adoption completion")
        }
    }
}
