import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A failed released-transcript read keeps writes in FIFO order through a
/// later, chunked reload, including writes arriving during construction/replay.
@MainActor
enum TranscriptReloadChunkRetryChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor ConstructionGate {
        private(set) var entered = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("released-reload-chunk-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts", isDirectory: true)
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Reload chunk retry", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        prior.appendUserPrompt("CHUNK_RETRY_PRIOR_HISTORY")
        try await transcripts.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "retry fixture did not restore its agent") }
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer {
            supervisor.qaBeforeResumedTranscriptConstruction = nil
            supervisor.qaAfterTranscriptReloadChunk = nil
            AgentSupervisor.transcriptReleaseDelay = previousDelay
            supervisor.stopAll()
        }
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        func text(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        func hasAllInOrder(_ markers: [String], text: String) -> Bool {
            var previous: String.Index?
            for marker in markers {
                guard text.components(separatedBy: marker).count - 1 == 1, let range = text.range(of: marker),
                      previous.map({ $0 < range.lowerBound }) ?? true else { return false }
                previous = range.lowerBound
            }
            return true
        }

        // Establish a saved, released transcript containing both a prior
        // archive and a turn from this supervisor's launch.
        deliver("CHUNK_RETRY_BEFORE_RELEASE")
        await supervisor.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id), let before = try await transcripts.load(agentID: id, sessionID: session),
              hasAllInOrder(["CHUNK_RETRY_PRIOR_HISTORY", "CHUNK_RETRY_BEFORE_RELEASE"], text: text(before)) else {
            throw Failure(description: "retry fixture did not save and release its prior history")
        }

        // An attached tile triggers the actual released reload. Moving this
        // fixture directory simulates a read failure without altering its bytes.
        let source = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        let aside = fixture.appendingPathComponent("held-transcript", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: aside)
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Reload chunk retry",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        tile.attach(agentID: id, supervisor: supervisor)
        defer { tile.detach() }
        guard let failed = supervisor.qaTranscriptReloadTask(for: id) else {
            throw Failure(description: "attaching did not start the released reload")
        }
        await failed.value
        guard supervisor.isTranscriptReleased(id), !warnings.isEmpty else {
            throw Failure(description: "unreadable released archive was accepted")
        }

        // Queue enough turns for several bounded chunks while the archive is
        // unavailable. New retries share the same in-flight task until it fails.
        let unavailable = (0..<48).map { String(format: "CHUNK_RETRY_UNAVAILABLE_%03d", $0) }
        unavailable.forEach(deliver)
        if let failedAgain = supervisor.qaTranscriptReloadTask(for: id) { await failedAgain.value }
        guard supervisor.isTranscriptReleased(id), !FileManager.default.fileExists(atPath: source.path) else {
            throw Failure(description: "writes during failed reads replaced the missing archive")
        }
        try FileManager.default.moveItem(at: aside, to: source)

        // Hold the real background constructor after the repaired strict read.
        // Further writes must remain ordered behind the earlier failed-read FIFO.
        let gate = ConstructionGate()
        supervisor.qaBeforeResumedTranscriptConstruction = { agent, isPreflight in
            if agent == id && !isPreflight { await gate.wait() }
        }
        defer { Task { await gate.open() } }
        let retry = supervisor.transcriptAttachment(for: id, reboundTo: "chunk-retry-probe")
        let retryView = Task { for await _ in retry.tail {} }
        defer { retryView.cancel() }
        guard let reload = retry.reload else { throw Failure(description: "repaired archive did not start a reload") }
        let gateDeadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < gateDeadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else { throw Failure(description: "repaired reload did not reach construction gate") }
        let constructing = (0..<16).map { String(format: "CHUNK_RETRY_CONSTRUCTING_%03d", $0) }
        constructing.forEach(deliver)

        // Schedule a later MainActor turn at the first replay chunk boundary.
        // It must run while the reload task is still registered; removing the
        // production yield leaves it until after replay and fails this check.
        var scheduled = false, injectedDuringReload = false
        let late = "CHUNK_RETRY_DURING_REPLAY"
        supervisor.qaAfterTranscriptReloadChunk = { agent, _ in
            guard agent == id, !scheduled else { return }
            scheduled = true
            Task { @MainActor in
                injectedDuringReload = supervisor.qaTranscriptReloadTask(for: id) != nil
                if injectedDuringReload { deliver(late) }
            }
        }
        await gate.open()
        await reload.value
        await supervisor.qaSaveTranscript(for: id)
        guard scheduled, injectedDuringReload, !supervisor.isTranscriptReleased(id),
              !supervisor.qaTranscriptPersistenceIsBlocked(id),
              let saved = try await transcripts.load(agentID: id, sessionID: session),
              Array(saved.entries.prefix(before.entries.count)) == before.entries else {
            throw Failure(description: "repaired chunked reload did not interleave or preserve its saved prefix")
        }
        let expected = ["CHUNK_RETRY_PRIOR_HISTORY", "CHUNK_RETRY_BEFORE_RELEASE"] + unavailable + constructing + [late]
        guard hasAllInOrder(expected, text: text(saved)) else {
            throw Failure(description: "repaired chunked reload lost, duplicated, or reordered queued writes")
        }
        let local = supervisor.transcriptDocument(for: id)
        guard hasAllInOrder(expected, text: text(local)) else {
            throw Failure(description: "supervisor presentation lost queued reload history")
        }
        let tileDeadline = ContinuousClock.now + .seconds(20)
        while !hasAllInOrder(expected, text: tile.qaTranscriptText), ContinuousClock.now < tileDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard hasAllInOrder(expected, text: tile.qaTranscriptText) else {
            throw Failure(description: "attached tile lost, duplicated, or reordered repaired reload history")
        }
    }
}
