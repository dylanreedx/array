import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A released transcript never takes provider history. No production read can
/// start for a released agent or finish while its reload drains
/// (`.plans/transcript-retention-reattach.md`); a direct seed mid-drain is
/// refused and leaves the archive and the queued live writes exactly once, in
/// order, on disk and in an attached and a reattached tile.
@MainActor
enum TranscriptLateRestoreReloadChecks {
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
        let fixture = root.appendingPathComponent("late-restore-reload", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Late restore reload", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        let old = "LATE_RESTORE_OLD_CANONICAL"
        prior.appendUserPrompt(old)
        try await transcripts.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer {
            supervisor.qaBeforeResumedTranscriptConstruction = nil
            supervisor.qaAfterTranscriptReloadChunk = nil
            AgentSupervisor.transcriptReleaseDelay = previousDelay
            supervisor.stopAll()
        }
        guard supervisor.records[id] != nil else { throw Failure(description: "late-restore fixture did not restore its agent") }
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        func exactlyOnce(_ markers: [String], in text: String) -> Bool {
            markers.allSatisfy { text.components(separatedBy: $0).count - 1 == 1 }
        }
        func inOrder(_ markers: [String], in text: String) -> Bool {
            var remainder = text.startIndex..<text.endIndex
            for marker in markers {
                guard let match = text.range(of: marker, range: remainder) else { return false }
                remainder = match.upperBound..<text.endIndex
            }
            return true
        }
        let initial = "LATE_RESTORE_BEFORE_RELEASE"
        deliver(initial)
        await supervisor.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id),
              let before = try await transcripts.load(agentID: id, sessionID: session) else {
            throw Failure(description: "late-restore fixture did not save and release its archive")
        }

        // The production restore and Copy pins refuse a released agent, and the
        // restore wiring does not ask for a previous-session read for one.
        if let pin = supervisor.beginProviderHistoryRead(for: id) {
            supervisor.endProviderHistoryRead(pin, for: id)
            throw Failure(description: "a provider read pinned a released transcript")
        }
        guard !supervisor.needsPreviousSessionNotice(id) else {
            throw Failure(description: "restore wiring would read provider history for a released transcript")
        }

        let gate = ConstructionGate()
        supervisor.qaBeforeResumedTranscriptConstruction = { agent, isPreflight in
            if agent == id && !isPreflight { await gate.wait() }
        }
        defer { Task { await gate.open() } }
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Late restore reload",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        tile.attach(agentID: id, supervisor: supervisor)
        defer { tile.detach() }
        guard let reload = supervisor.qaTranscriptReloadTask(for: id) else {
            throw Failure(description: "late-restore tile did not start reload")
        }
        let gateDeadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < gateDeadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else { throw Failure(description: "late-restore reload did not reach constructor gate") }
        let queued = (0..<48).map { String(format: "LATE_RESTORE_QUEUED_%03d", $0) }
        queued.forEach(deliver)
        let provider = "LATE_RESTORE_PROVIDER_ONLY"
        var scheduled = false, seededDuringReload = false
        supervisor.qaAfterTranscriptReloadChunk = { agent, _ in
            guard agent == id, !scheduled else { return }
            scheduled = true
            Task { @MainActor in
                seededDuringReload = supervisor.qaTranscriptReloadTask(for: id) != nil
                if seededDuringReload {
                    supervisor.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt(provider)],
                                                                            restoredMessageCount: 1, omittedEarlier: true), for: id)
                }
            }
        }
        await gate.open()
        await reload.value
        await supervisor.qaSaveTranscript(for: id)
        guard scheduled, seededDuringReload, !supervisor.isTranscriptReleased(id),
              !supervisor.qaTranscriptPersistenceIsBlocked(id),
              let saved = try await transcripts.load(agentID: id, sessionID: session),
              Array(saved.entries.prefix(before.entries.count)) == before.entries else {
            throw Failure(description: "late provider restore did not interleave with a successful released reload")
        }
        let canonicalText = saved.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        let canonicalMarkers = [old, initial] + queued
        guard exactlyOnce(canonicalMarkers, in: canonicalText), inOrder(canonicalMarkers, in: canonicalText),
              !canonicalText.contains(provider) else {
            throw Failure(description: "late provider restore lost or reordered canonical history or crossed the companion boundary")
        }
        guard supervisor.rehydratedTranscript(for: id) == nil else {
            throw Failure(description: "a released transcript accepted provider history mid-drain")
        }
        let expected = [old, initial] + queued
        func shows(_ text: String) -> Bool {
            exactlyOnce(expected, in: text) && inOrder(expected, in: text) && !text.contains(provider)
        }
        let tileDeadline = ContinuousClock.now + .seconds(20)
        while !shows(tile.qaTranscriptText), ContinuousClock.now < tileDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard shows(tile.qaTranscriptText) else {
            throw Failure(description: "attached tile lost, duplicated or reordered history, or showed a refused provider seed")
        }
        tile.detach()
        tile.attach(agentID: id, supervisor: supervisor)
        let reattachDeadline = ContinuousClock.now + .seconds(20)
        while !shows(tile.qaTranscriptText), ContinuousClock.now < reattachDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard shows(tile.qaTranscriptText) else {
            throw Failure(description: "reattached tile lost, duplicated or reordered history, or showed a refused provider seed")
        }
    }
}
