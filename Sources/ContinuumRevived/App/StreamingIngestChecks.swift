import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `--streaming-ingest-check` (`.plans/84`, motion benchmark): with eight agents
/// streaming, the per-chunk work filled the main thread, and pans and zoom
/// frames went late every 50 ms. Two of its biggest pieces, witnessed here.
@MainActor
enum StreamingIngestChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run() throws {
        try runSupervisorParsesAnOpenStreamAtItsOwnRate()
        try runChunksRefreshTheStatusRowAtMostEveryInterval()
        try runCameraMotionSlowsAVisibleStreamsParse()
    }

    /// A pan re-parsed every visible open message at the 30 Hz view rate on the
    /// pan's own frame. While the camera moves it parses at the motion rate; the
    /// view rate returns with the gesture, and the text still ends complete.
    private static func runCameraMotionSlowsAVisibleStreamsParse() throws {
        func parses(moving: Bool, thread: String) -> (count: Int, tile: ManagedAgentTileNSView) {
            let governor = FrameGovernor.shared
            governor.qaReset()
            governor.qaSetInteraction { moving }
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "motion-parse",
                            frame: TileFrame(x: 0, y: 0, width: 420, height: 300),
                            zPosition: .fromLegacyRank(1), zoneId: nil, runtimeRef: nil, metadata: TileMetadata())
            let view = ManagedAgentTileNSView(tile: tile, threadId: thread)
            view.ingest(.turnStarted(threadId: thread, turnId: "t"))
            let before = view.qaStreamingMarkupParseCount
            let end = Date().addingTimeInterval(1.0)
            var index = 0
            while Date() < end {
                view.ingest(.contentDelta(threadId: thread, turnId: "t", streamKind: .assistant, delta: "word\(index) "))
                index += 1
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            let count = view.qaStreamingMarkupParseCount - before
            view.ingest(.turnCompleted(threadId: thread, turnId: "t", outcome: .completed, errorMessage: nil))
            governor.qaSetInteraction(nil)
            return (count, view)
        }
        let still = parses(moving: false, thread: "still").count
        let moving = parses(moving: true, thread: "moving").count
        try expect(moving <= Int(ManagedAgentTileNSView.cameraMotionParsesPerSecond) + 3,
                   "a visible stream parsed \(moving) times in 1 s while the camera moved; at most \(Int(ManagedAgentTileNSView.cameraMotionParsesPerSecond) + 3)")
        try expect(still >= moving * 2, "at rest it must parse at the view rate: \(still) at rest vs \(moving) in motion")
        print("streaming ingest: a visible stream parsed \(still)x/s at rest and \(moving)x/s while the camera moved")
    }

    /// The supervisor's transcript is persisted and previewed, never drawn, yet it
    /// re-parsed the whole open message up to 30 times a second per agent: the
    /// largest single streaming cost in the profile. It parses at most
    /// `transcriptStreamingParsesPerSecond`, still ends with every chunk, and a view
    /// rebuilt from it parses at the view rate.
    private static func runSupervisorParsesAnOpenStreamAtItsOwnRate() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)], holdUntilStopped: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: { _ in runner },
            claudeSessionTitle: { _, _ in nil },
            transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(
            harness: .codex, readiness: .ready, models: ["fixture/streaming-ingest"],
            displayNames: ["fixture/streaming-ingest": "Offline streaming fixture"],
            contextWindows: ["fixture/streaming-ingest": 200_000]))
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: support, harness: .codex,
                                  model: "fixture/streaming-ingest", thinking: "low",
                                  projectId: UUID(), projectRoot: support, tileId: UUID(),
                                  displayName: "Streaming ingest")
        try expect(supervisor.send("Stream a long answer.", to: id), "the fixture agent refused its prompt")
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        pump(0.1)
        let thread = "streaming-ingest", turn = "live"
        try expect(runner.emit(.turnStarted(threadId: thread, turnId: turn)), "runner did not start the turn")
        let chunks = 40
        let started = Date()
        for index in 0..<chunks {
            _ = runner.emit(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant,
                                          delta: "Paragraph \(index) of the answer, chunk-\(index).\n\n"))
            pump(0.025)
        }
        let elapsed = Date().timeIntervalSince(started)
        let parses = supervisor.qaTranscriptParseCount(for: id)
        let allowed = Int((elapsed * AgentSupervisor.transcriptStreamingParsesPerSecond).rounded(.up)) + 2
        try expect(parses <= allowed,
                   "the supervisor parsed the open message \(parses) times in \(String(format: "%.2f", elapsed)) s; at most \(allowed)")
        _ = runner.emit(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        pump(0.2)
        let text = supervisor.transcriptDocumentProjection(for: id)?.entries
            .last(where: { $0.role == .assistant })
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) } ?? ""
        try expect(text.contains("chunk-\(chunks - 1)") && text.contains("chunk-0"),
                   "the finished turn must hold every chunk; it ends with \(text.suffix(60))")
        var model = ManagedAgentTranscriptModel(threadId: "rebound")
        model.streamingParsesPerSecond = AgentSupervisor.transcriptStreamingParsesPerSecond
        try expect(model.rebound(to: "view").streamingParsesPerSecond == 30,
                   "a view rebuilt from the supervisor's copy must parse at the view rate")
        print("streaming ingest: the supervisor parsed \(chunks) chunks \(parses) times in \(String(format: "%.2f", elapsed)) s and kept every chunk")
    }

    /// The status row was rebuilt on every streamed chunk though a chunk changes no
    /// status fact. Chunks now refresh it at most every `chunkStatusInterval`; any
    /// other event refreshes it at once.
    private static func runChunksRefreshTheStatusRowAtMostEveryInterval() throws {
        let tile = Tile(id: UUID(), kind: .managedAgent, title: "streaming-ingest",
                        frame: TileFrame(x: 0, y: 0, width: 420, height: 300),
                        zPosition: .fromLegacyRank(1), zoneId: nil, runtimeRef: nil, metadata: TileMetadata())
        let view = ManagedAgentTileNSView(tile: tile, threadId: "status")
        view.ingest(.turnStarted(threadId: "status", turnId: "t"))
        let before = view.qaLocationRefreshCount
        let snapshotsBefore = view.qaTurnSnapshotRefreshCount
        for index in 0..<20 {
            view.ingest(.contentDelta(threadId: "status", turnId: "t", streamKind: .assistant, delta: "chunk \(index) "))
        }
        try expect(view.qaLocationRefreshCount == before,
                   "20 chunks refreshed the status row \(view.qaLocationRefreshCount - before) times at once")
        try expect(view.qaTurnSnapshotRefreshCount == snapshotsBefore,
                   "20 chunks re-read the turn snapshot \(view.qaTurnSnapshotRefreshCount - snapshotsBefore) times at once")
        RunLoop.main.run(until: Date().addingTimeInterval(ManagedAgentTileNSView.chunkStatusInterval + 0.1))
        try expect(view.qaTurnSnapshotRefreshCount == snapshotsBefore + 1,
                   "the chunks must re-read the snapshot once after the interval; \(view.qaTurnSnapshotRefreshCount - snapshotsBefore)")
        try expect(view.qaLocationRefreshCount == before + 1,
                   "the chunks must refresh the row once after the interval; \(view.qaLocationRefreshCount - before)")
        view.ingest(.turnCompleted(threadId: "status", turnId: "t", outcome: .completed, errorMessage: nil))
        try expect(view.qaLocationRefreshCount == before + 2, "a turn boundary must refresh the row at once")
        try expect(view.qaTurnSnapshotRefreshCount == snapshotsBefore + 2, "a turn boundary must re-read the snapshot at once")
        print("streaming ingest: 20 chunks refreshed the status row once; a turn boundary refreshed it at once")
    }
}
