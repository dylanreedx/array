import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One open stream lane on a shared terminal: its owner's host sending, or a
/// member watching (`.plans/114-terminal-sharing`).
struct CollaborationTileStreamLane {
    let area: UUID
    let key: String
    let identity: Collaboration.Identity
    /// The item's owner, on the device that hosts it: the one lane that sends.
    let sends: Bool
    let continuation: AsyncStream<Collaboration.LiveTile.StreamMessage>.Continuation
    var tokens: Double
    var refilled: Date
}
/// What a member who opens the lane late is sent first: the newest screen and
/// the output after it, while that output stays small.
struct CollaborationTileStreamReplay {
    var base: Collaboration.LiveTile.TerminalFrame?
    var output: [Collaboration.LiveTile.TerminalFrame] = []
    var bytes = 0
}
struct CollaborationTileStreamTable {
    var lanes: [UUID: CollaborationTileStreamLane] = [:]
    var keys: [String: Set<UUID>] = [:]
    var replays: [String: CollaborationTileStreamReplay] = [:]
    /// Lanes per device per tile, and per relay.
    static let deviceLimit = 4
    static let globalLimit = 4096
    /// Frames a watcher may fall behind by before the newest are dropped; it
    /// then sees the gap and takes the state lane's screen.
    static let watcherBuffer = 128
}

/// A shared terminal's output at its own rate. The state lane carries one
/// whole state per round trip, which at 100 ms is ten a second however often
/// the screen changes; a frame on this lane is relayed to every watcher the
/// moment it arrives. Memory only, like the state lane: a relay restart drops
/// it, and both ends reopen it.
extension CollaborationStore {
    /// Admission without opening, before the WebSocket upgrade: a member who
    /// may view the area, and a live tile that the area still holds.
    public func admitTileStream(token: String, area: UUID, object: UUID) throws {
        _ = try tileStreamAccess(token: token, area: area, object: object)
    }

    private func tileStreamAccess(token: String, area: UUID, object: UUID) throws -> (identity: Collaboration.Identity, sends: Bool) {
        try database.read { db in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.allows(.view) else { throw CollaborationStoreError.forbidden }
            let item = try liveTileItem(db, area: area, object: object)
            guard let source = item.source else { throw CollaborationStoreError.unavailable }
            let device = try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [source.host.rawValue.uuidString])
            return (identity, source.owner == identity.person && device == identity.device.uuidString)
        }
    }

    /// Opens a lane. A watcher is sent the replay first, then every frame as
    /// it arrives; the owner's host is sent only requests to resync. The
    /// stream finishes when membership, the device or the item goes.
    public func openTileStream(token: String, area: UUID, object: UUID) throws
        -> (id: UUID, sends: Bool, messages: AsyncStream<Collaboration.LiveTile.StreamMessage>) {
        let (identity, sends) = try tileStreamAccess(token: token, area: area, object: object)
        let key = CollaborationLiveTileTable.key(area, object)
        guard tileStreams.lanes.count < CollaborationTileStreamTable.globalLimit,
              (tileStreams.keys[key] ?? []).filter({ tileStreams.lanes[$0]?.identity.device == identity.device }).count
                < CollaborationTileStreamTable.deviceLimit
        else { throw CollaborationStoreError.tooManySubscriptions }
        let id = UUID()
        let (messages, continuation) = AsyncStream<Collaboration.LiveTile.StreamMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(CollaborationTileStreamTable.watcherBuffer))
        continuation.onTermination = { [weak self] _ in Task { await self?.closeTileStream(id) } }
        tileStreams.lanes[id] = .init(area: area, key: key, identity: identity, sends: sends, continuation: continuation,
                                      tokens: Collaboration.LiveTile.TerminalStream.burst, refilled: clock())
        tileStreams.keys[key, default: []].insert(id)
        if !sends, let replay = tileStreams.replays[key], let base = replay.base {
            continuation.yield(.init(frame: base))
            for frame in replay.output { continuation.yield(.init(frame: frame)) }
        }
        return (id, sends, messages)
    }

    /// One frame from the owner's host. Over the rate, the frame is dropped
    /// and the host is asked for a keyframe, so a watcher is never left on a
    /// broken chain for longer than one round trip.
    public func streamTileFrame(_ id: UUID, frame: Collaboration.LiveTile.TerminalFrame) throws {
        guard var lane = tileStreams.lanes[id] else { throw CollaborationStoreError.unavailable }
        guard lane.sends else { throw CollaborationStoreError.forbidden }
        guard frame.columns > 0, frame.rows > 0, frame.columns <= 2048, frame.rows <= 2048,
              frame.bytes.count <= Collaboration.LiveTile.TerminalStream.maxFrameBytes else { throw CollaborationStoreError.invalidRequest }
        let stream = Collaboration.LiveTile.TerminalStream.self
        let now = clock()
        lane.tokens = min(stream.burst, lane.tokens + max(0, now.timeIntervalSince(lane.refilled)) * stream.rate)
        lane.refilled = now
        guard lane.tokens >= 1 else {
            tileStreams.lanes[id] = lane
            tileStreams.replays[lane.key] = nil
            lane.continuation.yield(.init(resync: true))
            return
        }
        lane.tokens -= 1
        tileStreams.lanes[id] = lane
        var replay = tileStreams.replays[lane.key] ?? .init()
        if frame.isScreen {
            replay = .init(base: frame)
        } else if let base = replay.base, base.stream == frame.stream,
                  (replay.output.last?.sequence ?? base.sequence) + 1 == frame.sequence {
            replay.output.append(frame); replay.bytes += frame.bytes.count
            if replay.bytes > stream.maxReplayBytes {
                // Too much to replay: the next screen restarts it.
                replay = .init()
                lane.continuation.yield(.init(resync: true))
            }
        } else {
            replay = .init()
        }
        tileStreams.replays[lane.key] = replay
        for other in tileStreams.keys[lane.key] ?? [] where other != id {
            tileStreams.lanes[other]?.continuation.yield(.init(frame: frame))
        }
    }

    public func closeTileStream(_ id: UUID) {
        guard let lane = tileStreams.lanes.removeValue(forKey: id) else { return }
        tileStreams.keys[lane.key]?.remove(id)
        if tileStreams.keys[lane.key]?.isEmpty == true { tileStreams.keys[lane.key] = nil; tileStreams.replays[lane.key] = nil }
        lane.continuation.finish()
    }

    /// Count-only diagnostics for the lane checks.
    public func openTileStreams() -> Int { tileStreams.lanes.count }

    func closeTileStreams(where match: (CollaborationTileStreamLane) -> Bool) {
        for (id, lane) in tileStreams.lanes where match(lane) { closeTileStream(id) }
    }
}
