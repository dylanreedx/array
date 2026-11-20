import AppKit
import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--transcript-dormancy-check`: a far-parked agent tile no longer keeps its
/// agent's decoded transcript in memory, and coming back shows the same thing.
///
/// Prod 0.7.56 held about 47 MB of decoded transcripts for agents nobody was
/// reading, because every attached tile (far-parked ones included) kept an event
/// tail, and an agent with a subscriber is never dormant. Drives the production
/// seams: real tiles attached to a real supervisor, the real far-park and promote
/// calls. `CONTINUUM_QA_LEGACY_FAR_PARK_KEEPS_TAIL=1` is the RED arm.
///
/// 1. Bytes per agent: after the tiles far-park and the release delay passes, no
///    transcript stays decoded and the heap falls by at least `minBytesPerAgent`
///    an agent.
/// 2. Reveal: promoting a released agent's tile shows the same transcript text
///    at once (digest equal, under `maxRevealMs`), and again after its reload.
/// 3. Sync: a turn delivered to a released agent reaches the delivered-event
///    observer in full, and the agent keeps its summary event for `events(for:)`.
/// 4. Loaded history: a released, persisted agent still counts as loaded.
@MainActor
enum TranscriptDormancyChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static let agentCount = 24
    static let minBytesPerAgent = 8_000
    static let maxRevealMs = 50.0
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func deliverTurn(_ supervisor: AgentSupervisor, _ id: AgentID, _ turn: Int) {
        let thread = AgentSupervisor.threadId(for: id), t = "r\(turn)"
        func at(_ step: Int) -> Date { base.addingTimeInterval(Double(turn * 10 + step)) }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: id, now: at(0))
        supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n dormancy Sources"), to: id, now: at(1))
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .commandOutput, delta: String(repeating: "Sources/Agents/Store.swift:12: let retained = true\n", count: 60)), to: id, now: at(2))
        supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: .completed), to: id, now: at(3))
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: "Turn \(turn) is done. " + String(repeating: "The ledger settles. ", count: 120)), to: id, now: at(4))
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: id, now: at(5))
    }

    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    private static func settle(_ timeout: Double = 20, _ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-dormancy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = ManagedAgentTileNSView.qaLegacyFarParkKeepsTail
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID()
        var ids: [AgentID] = [], tiles: [Tile] = []
        for index in 0..<agentCount {
            let id = AgentID(rawValue: UUID())
            ids.append(id)
            try store.upsert(AgentRecord(id: id, displayName: "Parked \(index)", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                         thinking: "none", cwd: root.path, projectId: project,
                                         createdAt: Date(), lastActivityAt: Date()))
            tiles.append(Tile(
                id: UUID(), kind: .managedAgent, title: "agent \(index)",
                frame: TileFrame(x: Double(40 + (index % 6) * 560), y: Double(40 + (index / 6) * 460), width: 520, height: 420),
                zPosition: .fromLegacyRank(index + 1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")))
        }
        let supervisor = AgentSupervisor(
            store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) }, warn: { _ in }, nameTitlerCommand: { _ in nil },
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.2), tiles: tiles, groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        var views: [ManagedAgentTileNSView] = []
        for (index, tile) in tiles.enumerated() {
            let view = ManagedAgentTileNSView(tile: tile)
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
            canvas.install(tileView: view, for: tile)
            view.attach(agentID: ids[index], supervisor: supervisor)
            views.append(view)
        }
        canvas.layoutSubtreeIfNeeded()
        var delivered = 0
        let token = supervisor.addDeliveredEventObserver { _, _ in delivered += 1 }
        defer { supervisor.removeDeliveredEventObserver(token) }
        for id in ids { deliverTurn(supervisor, id, 1) }
        await settle(5) { supervisor.qaHeldTranscripts.projections == 0 }
        let attachedHeld = supervisor.qaHeldTranscripts.projections
        print("METRIC dormancy attached tiles: held=\(attachedHeld) blockers=\(supervisor.transcriptRetentionBlockers())")

        // What each tile shows before it parks.
        func digest(_ view: ManagedAgentTileNSView) -> Int { view.qaTranscriptText.hashValue }
        let shown = views.map(digest)
        guard views.allSatisfy({ $0.qaTranscriptText.contains("The ledger settles") }) else {
            throw Failure(description: "fixture tiles do not show their transcript before parking")
        }

        let heapBefore = heapInUse()
        let park = NSView(frame: .zero)
        for view in views where !view.parkBodyFarOffscreen(park: park) {
            throw Failure(description: "the real far-park seam refused a managed agent tile")
        }
        await settle(10) { supervisor.qaHeldTranscripts.projections == 0 }
        let held = supervisor.qaHeldTranscripts
        let blockers = supervisor.transcriptRetentionBlockers()
        let perAgent = (heapBefore - heapInUse()) / agentCount
        print("METRIC dormancy far-parked (legacy=\(legacy)): held=\(held.projections) released=\(held.released) blockers=\(blockers) heap-freed=\(perAgent) bytes/agent")

        var failures: [String] = []
        if held.projections != 0 || held.toolDetails != 0 {
            failures.append("far-parked tiles still keep \(held.projections) transcripts and \(held.toolDetails) tool-detail captures decoded; blockers \(blockers)")
        }
        if perAgent < minBytesPerAgent {
            failures.append("far parking freed \(perAgent) bytes an agent, under \(minBytesPerAgent)")
        }

        // Sync and loaded history, on agents that are now released.
        let target = ids[3]
        if !supervisor.qaHasLoadedHistory(target) { failures.append("a released, persisted agent does not count as loaded history") }
        let before = delivered
        deliverTurn(supervisor, target, 2)
        if delivered - before != 6 { failures.append("a turn on a released agent reached the delivered-event observer as \(delivered - before) of 6 events") }
        var replayed = 0
        let replay = supervisor.events(for: target)
        let replayTask = Task { for await _ in replay { replayed += 1; break } }
        await settle(2) { replayed > 0 }
        replayTask.cancel()
        if replayed == 0 { failures.append("events(for:) of a released agent replays nothing") }

        // Reveal: the same text at once, and after the reload lands.
        let reveal = views[7]
        let start = ProcessInfo.processInfo.systemUptime
        reveal.promoteBodyToNative()
        let revealMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let immediate = digest(reveal)
        if immediate != shown[7] { failures.append("a revealed tile showed different text at once than before it parked") }
        if revealMs > maxRevealMs { failures.append(String(format: "revealing a released agent's tile took %.1f ms, over %.0f", revealMs, maxRevealMs)) }
        await settle(5) { false == (reveal.qaTranscriptText.isEmpty) && supervisor.subscriberCount(for: ids[7]) == 1 }
        if digest(reveal) != shown[7] { failures.append("a revealed tile's text changed after its reload") }
        print(String(format: "METRIC dormancy reveal %.1f ms, text identical", revealMs))

        // Return in the lead rect: the camera brings a parked tile back while it is
        // still off screen, so its reload never lands on a visible frame. The
        // camera moves so tile 9 is 100 pt outside the viewport and inside the
        // lead margin; the real camera commit returns it.
        let lead = views[9], leadID = ids[9]
        let frame = lead.tile.frame
        // Each camera commit returns at most `maxFarReturnsPerStep` off-screen tiles,
        // nearest first, so a pan brings them back over several steps.
        let baseX = frame.x - 100 - 1200
        var steps = 0
        while steps < 12 {
            canvas.setViewport(CanvasViewport(x: baseX + Double(steps % 2) * 0.5, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
            steps += 1
            if !lead.isFarParked { break }
        }
        func offscreen() -> Bool { !lead.frame.intersects(canvas.worldPlane.bounds) }
        if !offscreen() { failures.append("fixture: the lead tile is already in the viewport") }
        if lead.isFarParked { failures.append("a far-parked tile in the lead rect was not returned by the camera commit") }
        await settle(5) { lead.isAttachedToAgent && supervisor.subscriberCount(for: leadID) == 1 }
        await settle(5) { digest(lead) == shown[9] }
        if !(lead.isAttachedToAgent && digest(lead) == shown[9]) {
            failures.append("the returned tile has not reloaded its transcript")
        }
        if !offscreen() { failures.append("the reload completed only after the tile entered the viewport") }
        print("METRIC dormancy lead-rect return after \(steps) camera steps: attached=\(lead.isAttachedToAgent) offscreen=\(offscreen()) text identical=\(digest(lead) == shown[9])")

        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\n")) }
        print("PASS: transcript dormancy (legacy=\(legacy))")
    }
}
