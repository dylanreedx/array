import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Exercises live input, an attached tile and deletion while a released
/// transcript is drained in bounded chunks.
@MainActor
enum TranscriptReloadChunkChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private actor Gate {
        private(set) var entered = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        try await check(root: root, archive: false)
        try await check(root: root, archive: true)
    }

    private static func check(root: URL, archive: Bool) async throws {
        let label = archive ? "archive" : "tile"
        let fixture = root.appendingPathComponent("reload-chunks-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let store = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Reload chunks", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        prior.appendUserPrompt("RELOAD_CHUNK_PRIOR_END")
        try await store.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: store)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "\(label): agent not restored") }
        defer {
            supervisor.qaBeforeResumedTranscriptConstruction = nil
            supervisor.qaAfterTranscriptReloadChunk = nil
            supervisor.qaQuarantineFinished = nil
            supervisor.stopAll()
        }
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        deliver("RELOAD_CHUNK_SETUP_END")
        await supervisor.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id), let original = try await store.load(agentID: id, sessionID: session) else {
            throw Failure(description: "\(label): prior transcript not released")
        }
        guard let evidence = supervisor.transcriptDocumentProjection(for: id) else {
            throw Failure(description: "\(label): released agent has no workspace evidence")
        }
        let gate = Gate()
        supervisor.qaBeforeResumedTranscriptConstruction = { agent, preflight in
            if agent == id && !preflight { await gate.wait() }
        }
        defer { Task { await gate.open() } }
        let tile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Reload chunks",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 620), zPosition: .first, runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent")))
        tile.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        tile.attach(agentID: id, supervisor: supervisor)
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered, let reload = supervisor.qaTranscriptReloadTask(for: id) else {
            throw Failure(description: "\(label): reload did not reach construction gate")
        }
        let markers = (0..<100).map { String(format: "RELOAD_CHUNK_%04d_END", $0) }
        for marker in markers { deliver(marker) }
        let quarantined = Signal()
        supervisor.qaQuarantineFinished = { quarantined.set() }
        var scheduled = false, interleaved = false, partialHidden = false, sharedHidden = false, evidenceStable = false, deleted = false
        supervisor.qaAfterTranscriptReloadChunk = { agent, _ in
            guard agent == id, !scheduled else { return }
            scheduled = true
            Task { @MainActor in
                interleaved = supervisor.qaTranscriptReloadTask(for: id) != nil
                guard interleaved else { return }
                let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "mid-drain-reader")
                partialHidden = supervisor.transcriptDocument(for: id) == nil && attachment.snapshot == nil
                sharedHidden = supervisor.sharedTranscriptDocument(for: id) == nil
                evidenceStable = supervisor.transcriptDocumentProjection(for: id) == evidence
                if archive { deleted = supervisor.archive(id).recordDeleted }
                else { deliver("RELOAD_CHUNK_LATE_END") }
            }
        }
        await gate.open()
        await reload.value
        guard scheduled, interleaved else { throw Failure(description: "\(label): main actor did not interleave during chunk drain") }
        guard partialHidden else { throw Failure(description: "\(label): a reader saw a partial transcript during chunk drain") }
        guard sharedHidden else { throw Failure(description: "\(label): shared publisher saw a partial transcript during chunk drain") }
        guard evidenceStable else { throw Failure(description: "\(label): workspace evidence changed during chunk drain") }
        if archive {
            let end = ContinuousClock.now + .seconds(20)
            while !quarantined.read(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
            let source = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
            guard deleted, quarantined.read(), supervisor.records[id] == nil,
                  supervisor.qaHeldTranscripts.projections == 0, !FileManager.default.fileExists(atPath: source.path) else {
                throw Failure(description: "archive: stale reload recreated a deleted agent or transcript")
            }
            return
        }
        guard let shared = supervisor.sharedTranscriptDocument(for: id),
              Array(shared.entries.prefix(original.entries.count)) == original.entries else {
            throw Failure(description: "tile: shared publisher did not receive complete prior history after reload")
        }
        let sharedText = shared.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard (markers + ["RELOAD_CHUNK_LATE_END"]).allSatisfy({ sharedText.components(separatedBy: $0).count - 1 == 1 }) else {
            throw Failure(description: "tile: shared publisher did not receive all queued turns exactly once")
        }
        await supervisor.qaSaveTranscript(for: id)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id),
              let saved = try await store.load(agentID: id, sessionID: session),
              Array(saved.entries.prefix(original.entries.count)) == original.entries else {
            throw Failure(description: "tile: reload lost prior disk history")
        }
        let text = saved.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        var previous: String.Index?
        for marker in markers + ["RELOAD_CHUNK_LATE_END"] {
            guard text.components(separatedBy: marker).count - 1 == 1, let range = text.range(of: marker),
                  previous.map({ $0 < range.lowerBound }) ?? true else {
                throw Failure(description: "tile: disk lost, duplicated or reordered \(marker)")
            }
            previous = range.lowerBound
        }
        let tileDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < tileDeadline {
            let text = tile.qaTranscriptText
            if text.contains("RELOAD_CHUNK_PRIOR_END"), text.contains("RELOAD_CHUNK_LATE_END") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let tileText = tile.qaTranscriptText
        for marker in ["RELOAD_CHUNK_PRIOR_END"] + markers + ["RELOAD_CHUNK_LATE_END"] {
            guard tileText.components(separatedBy: marker).count - 1 == 1 else {
                throw Failure(description: "tile: visible history lost or duplicated \(marker)")
            }
        }
    }
}
