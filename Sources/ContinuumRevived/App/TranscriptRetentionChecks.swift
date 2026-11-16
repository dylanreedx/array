import AppKit
import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--transcript-retention-check`: an agent that has finished and that no view
/// follows does not keep its decoded transcript in memory, and opening it again
/// still shows the whole of it.
///
/// Scaled like a long-running workspace: 2,300 agent records, 2,200 of which
/// finish a turn with a tool call (a transcript, a replay buffer and a
/// tool-detail capture each). A session then opens 200 of them, runs another
/// turn on 50 while open, and closes all but three. Asserted once idle:
///
/// - At most the three open agents hold a decoded transcript or tool-detail
///   capture, and the events held are about one summary event per agent.
/// - Opening a released agent reloads the same document it had, and its last
///   reply is still known.
/// - A turn delivered to a released agent with no view open lands after the
///   saved history rather than replacing it.
/// - A released agent whose saved file cannot be read is never overwritten
///   with its summary; its turn lands once the file reads again.
@MainActor
enum TranscriptRetentionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static let agentCount = 2_300
    static let transcriptCount = 2_200
    static let openedCount = 200
    static let keptOpen = 3

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func deliverTurn(_ supervisor: AgentSupervisor, _ id: AgentID, _ turn: Int) {
        let thread = AgentSupervisor.threadId(for: id), t = "r\(turn)"
        func at(_ step: Int) -> Date { base.addingTimeInterval(Double(turn * 10 + step)) }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: id, now: at(0))
        supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n retention Sources/Agents"), to: id, now: at(1))
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .commandOutput, delta: String(repeating: "Sources/Agents/Store.swift:12: let retained = true\n", count: 20)), to: id, now: at(2))
        supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: .completed), to: id, now: at(3))
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: "Turn \(turn) of \(id.rawValue.uuidString) is done. " + String(repeating: "The ledger settles. ", count: 40)), to: id, now: at(4))
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: id, now: at(5))
    }

    private static func heapInUse() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576
    }

    private static func describe(_ held: (projections: Int, rehydrated: Int, toolDetails: Int, events: Int, released: Int)) -> String {
        "transcripts=\(held.projections) restores=\(held.rehydrated) tool-details=\(held.toolDetails) events=\(held.events) released=\(held.released)"
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID()
        var ids: [AgentID] = []
        for index in 0..<agentCount {
            let id = AgentID(rawValue: UUID())
            ids.append(id)
            try store.upsert(AgentRecord(id: id, displayName: "Helper \(index)", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                         thinking: "none", cwd: root.path, projectId: project,
                                         createdAt: Date(), lastActivityAt: Date()))
        }
        let transcriptStore = AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true))
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcriptStore)
        _ = supervisor.restore()
        guard supervisor.records.count == agentCount else {
            throw Failure(description: "the fixture restored \(supervisor.records.count) of \(agentCount) agents")
        }
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }

        let heapBefore = heapInUse()
        let ran = Array(ids.prefix(transcriptCount))
        for id in ran { autoreleasepool { deliverTurn(supervisor, id, 1) } }
        print(String(format: "METRIC transcript-retention after %d finished agents: %@ heap-in-use=%.1fMB (+%.1fMB)",
                     ran.count, describe(supervisor.qaHeldTranscripts), heapInUse(), heapInUse() - heapBefore))

        // What a reopen and a later write must reproduce.
        let reopened = ran[1_000], written = ran[1_001]
        // As the store keeps them: dates are saved to the whole second, which a
        // restart has always shown, so compare against that round trip.
        let reopenedEntries = try JSONCodec.makeDecoder().decode(
            [AgentEntry].self, from: JSONCodec.makeEncoder().encode(supervisor.transcriptDocument(for: reopened)?.entries ?? []))
        let reopenedReply = supervisor.finalAssistantText(for: reopened)
        let writtenEntries = supervisor.transcriptDocument(for: written)?.entries ?? []

        // A session: open 200, run a turn on 50 while open, close all but three.
        var views: [AgentID: Task<Void, Never>] = [:]
        for id in ran.suffix(openedCount) {
            let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "view-\(id.rawValue.uuidString)")
            views[id] = Task { for await _ in attachment.tail {} }
        }
        for id in ran.suffix(50) { autoreleasepool { deliverTurn(supervisor, id, 2) } }
        let stillOpen = Set(ran.suffix(keptOpen))
        for (id, view) in views where !stillOpen.contains(id) { view.cancel() }

        var failures: [String] = []
        func settle(_ done: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(60)
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await settle { supervisor.qaHeldTranscripts.projections <= keptOpen }
        let held = supervisor.qaHeldTranscripts
        print(String(format: "METRIC transcript-retention idle with %d open: %@ heap-in-use=%.1fMB (+%.1fMB)",
                     keptOpen, describe(held), heapInUse(), heapInUse() - heapBefore))
        if held.projections > keptOpen || held.toolDetails > keptOpen || held.rehydrated > 0 {
            failures.append("idle agents with no view still hold decoded transcripts: \(describe(held)); at most \(keptOpen) open agents may")
        }
        let eventBudget = transcriptCount + 100
        if held.events > eventBudget {
            failures.append("idle agents still hold \(held.events) events, over \(eventBudget) (about one summary event per agent)")
        }

        // Positive control: opening a released agent shows the transcript it had.
        let attachment = supervisor.transcriptAttachment(for: reopened, reboundTo: "view-reopen")
        let reopenView = Task { for await _ in attachment.tail {} }
        if let reload = attachment.reload { await reload.value }
        let reloaded = attachment.snapshot ?? supervisor.transcriptAttachment(for: reopened, reboundTo: "view-reopen-2").snapshot
        if reopenedEntries.isEmpty || reloaded?.document.entries != reopenedEntries {
            failures.append("reopening a released agent showed \(reloaded?.document.entries.count ?? 0) entries, not the \(reopenedEntries.count) it had")
        }
        if supervisor.finalAssistantText(for: reopened) != reopenedReply || reopenedReply == nil {
            failures.append("a released agent's last reply was lost")
        }
        reopenView.cancel()

        // A turn delivered with no view open lands after the saved history.
        deliverTurn(supervisor, written, 3)
        let sessionID = AgentTranscriptStore.canonicalSessionID(for: written)
        var saved: AgentDocument?
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            saved = try await transcriptStore.load(agentID: written, sessionID: sessionID)
            if let saved, saved.entries.count > writtenEntries.count { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let savedEntries = saved?.entries ?? []
        if writtenEntries.isEmpty || Array(savedEntries.prefix(writtenEntries.count)).map(\.id) != writtenEntries.map(\.id)
            || savedEntries.count <= writtenEntries.count {
            failures.append("a turn after release saved \(savedEntries.count) entries; expected the \(writtenEntries.count) before it and the new turn after")
        }

        // A saved transcript that cannot be read back is never overwritten with
        // the summary kept at release: the agent stays released, its new turn
        // waits, and once the file reads again the turn lands after all of it.
        let faulted = ran[1_002]
        let faultedSession = AgentTranscriptStore.canonicalSessionID(for: faulted)
        let faultedBefore = try await transcriptStore.load(agentID: faulted, sessionID: faultedSession)?.entries ?? []
        let faultedDir = root.appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent(faulted.rawValue.uuidString, isDirectory: true)
        let aside = root.appendingPathComponent("aside-\(faulted.rawValue.uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: faultedDir, to: aside)
        let faultedTile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "faulted-reload",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        faultedTile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        faultedTile.attach(agentID: faulted, supervisor: supervisor)
        // This shares the tile's in-flight reload: neither call has yielded the
        // main actor yet. Wait for failure before triggering any other retry.
        let failedReload = supervisor.transcriptAttachment(for: faulted, reboundTo: "fault-probe")
        let probeView = Task { for await _ in failedReload.tail {} }
        if let reload = failedReload.reload { await reload.value }
        if !supervisor.isTranscriptReleased(faulted) {
            failures.append("the tile's unreadable transcript unexpectedly loaded")
        }
        probeView.cancel()
        deliverTurn(supervisor, faulted, 3)
        let failedWriteReload = supervisor.transcriptAttachment(for: faulted, reboundTo: "fault-write-probe")
        let writeProbeView = Task { for await _ in failedWriteReload.tail {} }
        if let reload = failedWriteReload.reload { await reload.value }
        writeProbeView.cancel()
        if !supervisor.isTranscriptReleased(faulted) {
            // The RED control resumes from the summary and saves asynchronously.
            let saveDeadline = ContinuousClock.now + .seconds(10)
            while !FileManager.default.fileExists(atPath: faultedDir.path), ContinuousClock.now < saveDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if !supervisor.isTranscriptReleased(faulted) {
            failures.append("an unreadable saved transcript did not stay released")
        }
        if FileManager.default.fileExists(atPath: faultedDir.path) {
            let overwritten = try await transcriptStore.load(agentID: faulted, sessionID: faultedSession)?.entries.count ?? 0
            failures.append("an unreadable saved transcript was replaced by \(overwritten) entries; it had \(faultedBefore.count)")
            try? FileManager.default.removeItem(at: faultedDir)
        }
        try FileManager.default.moveItem(at: aside, to: faultedDir)
        // Retry from a write, keeping the same tile attached. It must install
        // the recovered snapshot as well as the queued and subsequent turns.
        deliverTurn(supervisor, faulted, 4)
        let oldMarker = "Turn 1 of \(faulted.rawValue.uuidString) is done."
        let queuedMarker = "Turn 3 of \(faulted.rawValue.uuidString) is done."
        let newMarker = "Turn 4 of \(faulted.rawValue.uuidString) is done."
        await settle {
            let text = faultedTile.qaTranscriptText
            return text.contains(oldMarker) && text.contains(queuedMarker) && text.contains(newMarker)
        }
        let tileText = faultedTile.qaTranscriptText
        for marker in [oldMarker, queuedMarker, newMarker] {
            let count = tileText.components(separatedBy: marker).count - 1
            if count != 1 { failures.append("the faulted tile showed marker \(marker) \(count) times after the retry") }
        }
        let recovered = supervisor.transcriptDocument(for: faulted)?.entries ?? []
        let recoveredText = recovered.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        for marker in [oldMarker, queuedMarker, newMarker] {
            let count = recoveredText.components(separatedBy: marker).count - 1
            if count != 1 { failures.append("the recovered supervisor transcript showed marker \(marker) \(count) times") }
        }
        if faultedBefore.count < 3 || recovered.count <= faultedBefore.count
            || Array(recovered.prefix(faultedBefore.count)).map(\.id) != faultedBefore.map(\.id) {
            failures.append("after its file read again, a faulted agent showed \(recovered.count) entries; expected the \(faultedBefore.count) saved and the turn held meanwhile")
        }
        faultedTile.detach()

        for view in views.values { view.cancel() }

        do {
            try await RestoreOnlyTranscriptRetentionChecks.run(
                supervisor: supervisor, id: ids[transcriptCount], transcriptStore: transcriptStore)
        } catch {
            failures.append("restore-only retention: \(error)")
        }
        do {
            try await RestoreOnlyTranscriptRetentionChecks.runPreservingExisting(root: root)
        } catch {
            failures.append("restore-only existing archive: \(error)")
        }
        do {
            try await ReleasedTranscriptRecoveryChecks.run(root: root)
        } catch {
            failures.append("released transcript recovery: \(error)")
        }
        do {
            try await TranscriptSaveGuardChecks.run(root: root)
        } catch {
            failures.append("transcript save guard: \(error)")
        }

        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\nFAIL: ")) }
        print("PASS: idle agents with no view release their transcripts, reopen with the same transcript, and keep their history across a later turn")
    }
}
