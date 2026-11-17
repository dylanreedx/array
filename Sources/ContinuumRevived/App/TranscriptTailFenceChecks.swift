import AppKit
import ContinuumRevivedCore
import Foundation

/// Exercise the tile's real stream consumer with an old event suspended after
/// it has left the buffer and before it is applied to the transcript.
@MainActor
enum TranscriptTailFenceChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(supervisor: AgentSupervisor, id: AgentID) async throws {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "tail fence",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        let oldMarker = "BUFFERED_OLD_TAIL_MARKER"
        let nextMarker = "CURRENT_TAIL_MARKER"
        var paused: CheckedContinuation<Void, Never>?
        defer {
            paused?.resume()
            tile.qaBeforeTailEvent = nil
            tile.detach()
        }
        tile.qaBeforeTailEvent = { event in
            guard case let .contentDelta(_, _, _, delta) = event, delta == oldMarker else { return }
            await withCheckedContinuation { paused = $0 }
        }
        tile.attach(agentID: id, supervisor: supervisor)
        guard let oldTask = tile.qaEventSubscription else {
            throw Failure(description: "tile did not subscribe to its initial tail")
        }
        let thread = AgentSupervisor.threadId(for: id)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "fence-old"), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "fence-old", streamKind: .assistant, delta: oldMarker), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "fence-old", outcome: .completed, errorMessage: nil), to: id)
        let pauseDeadline = ContinuousClock.now + .seconds(10)
        while paused == nil, ContinuousClock.now < pauseDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let resumeOld = paused else {
            throw Failure(description: "old tail did not reach the paused buffered event")
        }

        // The new snapshot includes that event. The old task already owns its
        // copy, so cancelling the stream cannot remove it from the task's frame.
        tile.detach()
        tile.attach(agentID: id, supervisor: supervisor)
        guard tile.qaTranscriptText.components(separatedBy: oldMarker).count - 1 == 1 else {
            throw Failure(description: "replacement snapshot did not contain the buffered marker exactly once")
        }
        tile.qaBeforeTailEvent = nil
        paused = nil
        resumeOld.resume()
        await oldTask.value
        let oldCount = tile.qaTranscriptText.components(separatedBy: oldMarker).count - 1
        guard oldCount == 1 else {
            throw Failure(description: "stale tail event was applied after reattachment (marker count \(oldCount))")
        }

        // A new event must still reach the replacement subscription.
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "fence-new"), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "fence-new", streamKind: .assistant, delta: nextMarker), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "fence-new", outcome: .completed, errorMessage: nil), to: id)
        let nextDeadline = ContinuousClock.now + .seconds(10)
        while !tile.qaTranscriptText.contains(nextMarker), ContinuousClock.now < nextDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard tile.qaTranscriptText.components(separatedBy: nextMarker).count - 1 == 1 else {
            throw Failure(description: "replacement tail failed to deliver its new event exactly once")
        }
    }
}
