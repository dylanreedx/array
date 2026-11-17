import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A successful reload freezes everything read from disk, including turns
/// written since startup. A failed read cannot turn that disk history into a
/// shorter later save.
@MainActor
enum TranscriptReloadPrefixChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        try await checkQueuedTurn(root: root)
        try await checkOpenTurnCollision(root: root)
        try await checkCommandOutputCollision(root: root)
    }

    private static func text(_ document: AgentDocument?) -> String {
        (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
    }

    private static func once(_ marker: String, in text: String) -> Bool {
        text.components(separatedBy: marker).count - 1 == 1
    }

    private static func release(_ id: AgentID, supervisor: AgentSupervisor) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < deadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id) else {
            throw Failure(description: "fixture transcript did not become idle and release")
        }
    }

    private static func failedReload(_ id: AgentID, supervisor: AgentSupervisor, thread: String) async throws {
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: thread)
        let view = Task { for await _ in attachment.tail {} }
        defer { view.cancel() }
        guard let reload = attachment.reload else { throw Failure(description: "released fixture did not start a reload") }
        await reload.value
        guard supervisor.isTranscriptReleased(id) else { throw Failure(description: "missing archive was accepted during reload") }
    }

    private static func checkQueuedTurn(root: URL) async throws {
        let fixture = root.appendingPathComponent("reload-prefix-later-turn", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Reload prefix", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        prior.appendUserPrompt("PREFIX_P_BEFORE_LAUNCH")
        try await transcripts.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "later-turn agent did not restore") }
        func deliver(_ turn: String, _ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: id)
        }
        deliver("prefix-q", "PREFIX_Q_SAVED_LATER")
        await supervisor.qaSaveTranscript(for: id)
        guard let before = try await transcripts.load(agentID: id, sessionID: session),
              once("PREFIX_P_BEFORE_LAUNCH", in: text(before)), once("PREFIX_Q_SAVED_LATER", in: text(before)),
              !supervisor.qaTranscriptPersistenceIsBlocked(id) else {
            throw Failure(description: "fixture failed to save P and Q before release")
        }
        try await release(id, supervisor: supervisor)
        let agentDir = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        let aside = fixture.appendingPathComponent("held-prior-archive")
        try FileManager.default.moveItem(at: agentDir, to: aside)
        try await failedReload(id, supervisor: supervisor, thread: "prefix-failed")
        // These are real live events, held until the missing archive is readable.
        deliver("prefix-r", "PREFIX_R_AFTER_FAILED_RELOAD")
        try await failedReload(id, supervisor: supervisor, thread: "prefix-failed-write")
        guard !FileManager.default.fileExists(atPath: agentDir.path) else {
            throw Failure(description: "queued turn created an archive while reload was failing")
        }
        try FileManager.default.moveItem(at: aside, to: agentDir)
        let repaired = supervisor.transcriptAttachment(for: id, reboundTo: "prefix-repaired")
        let view = Task { for await _ in repaired.tail {} }
        defer { view.cancel() }
        guard let reload = repaired.reload else { throw Failure(description: "repaired archive did not retry") }
        await reload.value
        await supervisor.qaSaveTranscript(for: id)
        guard let after = try await transcripts.load(agentID: id, sessionID: session),
              !supervisor.isTranscriptReleased(id), !supervisor.qaTranscriptPersistenceIsBlocked(id),
              after.entries.count > before.entries.count,
              Array(after.entries.prefix(before.entries.count)) == before.entries else {
            throw Failure(description: "after failed reload the later save did not retain the entire P+Q prefix")
        }
        let content = text(after)
        guard once("PREFIX_P_BEFORE_LAUNCH", in: content), once("PREFIX_Q_SAVED_LATER", in: content),
              once("PREFIX_R_AFTER_FAILED_RELOAD", in: content),
              let p = content.range(of: "PREFIX_P_BEFORE_LAUNCH"),
              let q = content.range(of: "PREFIX_Q_SAVED_LATER"),
              let r = content.range(of: "PREFIX_R_AFTER_FAILED_RELOAD"),
              p.lowerBound < q.lowerBound, q.lowerBound < r.lowerBound else {
            throw Failure(description: "after failed reload P, Q and queued R were lost, duplicated or reordered: \(content)")
        }
    }

    private static func checkOpenTurnCollision(root: URL) async throws {
        let fixture = root.appendingPathComponent("reload-prefix-open-turn", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Open reload prefix", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "open-turn agent did not restore") }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "same-open-turn"), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "same-open-turn", streamKind: .assistant,
                                           delta: "FROZEN_OPEN_ORIGINAL"), to: id)
        _ = supervisor.transcriptDocument(for: id) // production read flushes pending markup
        await supervisor.qaSaveTranscript(for: id)
        try await release(id, supervisor: supervisor)
        guard let before = try await transcripts.load(agentID: id, sessionID: session),
              before.entries.contains(where: { $0.lifecycle != .finished }),
              once("FROZEN_OPEN_ORIGINAL", in: text(before)) else {
            throw Failure(description: "fixture did not persist and release an open assistant entry")
        }
        var notices: [AgentLocalNotice] = []
        let token = supervisor.addLocalNoticeObserver(for: id) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(token, for: id) }
        let agentDir = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        let aside = fixture.appendingPathComponent("held-open-archive")
        try FileManager.default.moveItem(at: agentDir, to: aside)
        try await failedReload(id, supervisor: supervisor, thread: "open-failed")
        try FileManager.default.moveItem(at: aside, to: agentDir)
        let repaired = supervisor.transcriptAttachment(for: id, reboundTo: "open-repaired")
        let view = Task { for await _ in repaired.tail {} }
        defer { view.cancel() }
        guard let reload = repaired.reload else { throw Failure(description: "open archive did not retry after repair") }
        await reload.value
        guard !supervisor.isTranscriptReleased(id) else { throw Failure(description: "open archive did not reload after repair") }

        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Open reload collision",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        var deliveredMarkers: Set<String> = []
        var sawCompletion = false
        tile.onIngestedEvent = { event in
            if case let .contentDelta(_, _, _, delta) = event { deliveredMarkers.insert(delta) }
            if case .turnCompleted(_, "same-open-turn", _, _) = event { sawCompletion = true }
        }
        tile.attach(agentID: id, supervisor: supervisor)
        defer { tile.onIngestedEvent = nil; tile.detach() }
        guard once("FROZEN_OPEN_ORIGINAL", in: tile.qaTranscriptText) else {
            throw Failure(description: "attached tile did not display the saved open entry")
        }

        // Resuming does not reconstruct an old open stream's parser state. A
        // same-turn delta must use a fresh run and preserve both the saved
        // entry and the new output in the supervisor, tile, and archive.
        let firstDelta = "FROZEN_OPEN_COLLIDING_DELTA"
        let secondDelta = "FROZEN_OPEN_SECOND_DELTA"
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "same-open-turn", streamKind: .assistant,
                                           delta: firstDelta), to: id)
        let firstDeadline = ContinuousClock.now + .seconds(10)
        while !deliveredMarkers.contains(firstDelta), ContinuousClock.now < firstDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let firstLocal = supervisor.transcriptDocument(for: id)
        guard deliveredMarkers.contains(firstDelta), once("FROZEN_OPEN_ORIGINAL", in: text(firstLocal)),
              once("FROZEN_OPEN_ORIGINAL", in: tile.qaTranscriptText),
              Array((firstLocal?.entries ?? []).prefix(before.entries.count)) == before.entries,
              once(firstDelta, in: text(firstLocal)), once(firstDelta, in: tile.qaTranscriptText),
              (supervisor.finalAssistantText(for: id) ?? "").contains(firstDelta) else {
            throw Failure(description: "first same-turn delta did not preserve the saved open entry and appear once as new output")
        }
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "same-open-turn", streamKind: .assistant,
                                           delta: secondDelta), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "same-open-turn", outcome: .completed, errorMessage: nil), to: id)
        let secondDeadline = ContinuousClock.now + .seconds(10)
        while (!deliveredMarkers.contains(secondDelta) || !sawCompletion), ContinuousClock.now < secondDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let secondLocal = supervisor.transcriptDocument(for: id)
        guard deliveredMarkers.contains(secondDelta), sawCompletion, once("FROZEN_OPEN_ORIGINAL", in: text(secondLocal)),
              once("FROZEN_OPEN_ORIGINAL", in: tile.qaTranscriptText),
              Array((secondLocal?.entries ?? []).prefix(before.entries.count)) == before.entries,
              once(firstDelta, in: text(secondLocal)), once(secondDelta, in: text(secondLocal)),
              once(firstDelta, in: tile.qaTranscriptText), once(secondDelta, in: tile.qaTranscriptText) else {
            throw Failure(description: "same-turn deltas did not preserve the saved open entry and appear once in the supervisor and tile")
        }
        _ = supervisor.transcriptDocument(for: id)
        await supervisor.qaSaveTranscript(for: id)
        let after = try await transcripts.load(agentID: id, sessionID: session)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id),
              !notices.contains(where: { $0.title == "Transcript not saved" }),
              let after, Array(after.entries.prefix(before.entries.count)) == before.entries,
              once("FROZEN_OPEN_ORIGINAL", in: text(after)),
              once(firstDelta, in: text(after)), once(secondDelta, in: text(after)) else {
            throw Failure(description: "same-turn deltas were blocked, lost, duplicated, or changed the saved open history")
        }
    }

    private static func checkCommandOutputCollision(root: URL) async throws {
        let fixture = root.appendingPathComponent("reload-prefix-command-output", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Command output collision", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "command-output agent did not restore") }
        let turn = "same-command-turn"
        let old = "FROZEN_COMMAND_ORIGINAL"
        let first = "COMMAND_AFTER_RELOAD_ONE"
        let second = "COMMAND_AFTER_RELOAD_TWO"
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .commandOutput, delta: old), to: id)
        await supervisor.qaSaveTranscript(for: id)
        try await release(id, supervisor: supervisor)
        guard let before = try await transcripts.load(agentID: id, sessionID: session), once(old, in: text(before)) else {
            throw Failure(description: "command-output fixture did not save its prior output")
        }
        let agentDir = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        let aside = fixture.appendingPathComponent("held-command-archive")
        try FileManager.default.moveItem(at: agentDir, to: aside)
        try await failedReload(id, supervisor: supervisor, thread: "command-failed")
        try FileManager.default.moveItem(at: aside, to: agentDir)
        let repaired = supervisor.transcriptAttachment(for: id, reboundTo: "command-repaired")
        let view = Task { for await _ in repaired.tail {} }
        defer { view.cancel() }
        guard let reload = repaired.reload else { throw Failure(description: "command archive did not retry after repair") }
        await reload.value
        guard !supervisor.isTranscriptReleased(id) else { throw Failure(description: "command archive did not reload") }

        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Command collision",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        var delivered: Set<String> = []
        var sawCompletion = false
        tile.onIngestedEvent = { event in
            if case let .contentDelta(_, _, _, delta) = event { delivered.insert(delta) }
            if case let .turnCompleted(_, turnID, _, _) = event, turnID == turn { sawCompletion = true }
        }
        tile.attach(agentID: id, supervisor: supervisor)
        defer { tile.onIngestedEvent = nil; tile.detach() }
        guard once(old, in: tile.qaTranscriptText) else { throw Failure(description: "tile did not display the saved command output") }
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .commandOutput, delta: first), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .commandOutput, delta: second), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: id)
        let deadline = ContinuousClock.now + .seconds(10)
        while (!delivered.contains(first) || !delivered.contains(second) || !sawCompletion), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let local = supervisor.transcriptDocument(for: id)
        guard delivered.contains(first), delivered.contains(second), sawCompletion,
              Array((local?.entries ?? []).prefix(before.entries.count)) == before.entries,
              [old, first, second].allSatisfy({ once($0, in: text(local)) && once($0, in: tile.qaTranscriptText) }) else {
            throw Failure(description: "same-turn command output was lost, duplicated, or changed prior history in the supervisor or tile")
        }
        await supervisor.qaSaveTranscript(for: id)
        let after = try await transcripts.load(agentID: id, sessionID: session)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id), let after,
              Array(after.entries.prefix(before.entries.count)) == before.entries,
              [old, first, second].allSatisfy({ once($0, in: text(after)) }) else {
            throw Failure(description: "same-turn command output was blocked or failed to preserve the canonical prefix")
        }
    }
}
