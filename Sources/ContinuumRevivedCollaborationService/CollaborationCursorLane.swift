import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One open cursor lane: a member's device streaming its pointer into an area
/// and receiving its teammates' pointers, frame by frame.
struct CollaborationCursorLane {
    let area: UUID
    let identity: Collaboration.Identity
    let label: String?
    let continuation: AsyncStream<Collaboration.CursorLaneMessage>.Continuation
    /// Token bucket: `cursorLaneRate` frames a second, `cursorLaneBurst` deep.
    var tokens: Double
    var refilled: Date
    /// The newest frame that arrived with no token. It is relayed when one
    /// refills, so a sender over the limit is slowed, never left stale.
    var pending: Collaboration.PresenceInput?
    var flush: Task<Void, Never>?
}

/// The cursor lane carries pointers at the sender's own rate instead of the
/// update pages' one-per-round-trip. A held update read brings one page per
/// network round trip — 7-10 positions a second at 100 ms — however often the
/// sender publishes. A lane frame is relayed to the area's other lanes the
/// moment it arrives. It still updates the same presence entry, so a viewer
/// without a lane (an older build, a proxy that refuses WebSockets) sees the
/// pointer through its pages exactly as before.
extension CollaborationStore {
    /// Sustained frames a second per lane. Senders publish at most 60; the
    /// headroom absorbs network bunching without delaying a real 60 Hz stream.
    public static let cursorLaneRate: Double = 90
    public static let cursorLaneBurst: Double = 30
    /// Lanes per device per area (one per open view, plus a reconnect overlap).
    public static let cursorLaneDeviceLimit = 4
    public static let cursorLaneGlobalLimit = 4096

    /// Admission without opening: the relay refuses the WebSocket upgrade for
    /// anyone who is not an active member, before any frame is exchanged.
    public func admitCursorLane(token: String, area: UUID) throws {
        try database.read { db in _ = try scope(db, authenticate(db, token), area) }
    }

    /// Opens a lane. The stream yields teammates' frames and refusals of this
    /// device's own frames; it finishes when the device or membership is
    /// revoked. Ending the stream (the connection closed) closes the lane.
    public func openCursorLane(token: String, area: UUID) throws -> (id: UUID, messages: AsyncStream<Collaboration.CursorLaneMessage>) {
        let (identity, label) = try database.read { db in
            let identity = try authenticate(db, token)
            _ = try scope(db, identity, area)
            return (identity, try String.fetchOne(db, sql: "SELECT label FROM people WHERE id=?", arguments: [identity.person.rawValue.uuidString]))
        }
        guard cursorLanes.count < Self.cursorLaneGlobalLimit,
              (cursorLaneAreas[area] ?? []).filter({ cursorLanes[$0]?.identity.device == identity.device }).count < Self.cursorLaneDeviceLimit
        else { throw CollaborationStoreError.tooManySubscriptions }
        let id = UUID()
        // A lane that falls behind keeps the newest frames; an older position
        // is superseded by the next one anyway.
        let (messages, continuation) = AsyncStream<Collaboration.CursorLaneMessage>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in Task { await self?.closeCursorLane(id) } }
        cursorLanes[id] = .init(area: area, identity: identity, label: label, continuation: continuation,
            tokens: Self.cursorLaneBurst, refilled: clock())
        cursorLaneAreas[area, default: []].insert(id)
        return (id, messages)
    }

    /// One frame from a lane's own device. A frame for an unknown presence
    /// session is refused back down the lane so the sender begins a new one.
    public func streamCursor(_ id: UUID, input: Collaboration.PresenceInput) throws {
        guard var lane = cursorLanes[id] else { throw CollaborationStoreError.unavailable }
        guard input.cursor?.valid != false, input.viewport?.valid != false, input.sentAt?.isFinite != false else { throw CollaborationStoreError.invalidRequest }
        let now = clock()
        lane.tokens = min(Self.cursorLaneBurst, lane.tokens + max(0, now.timeIntervalSince(lane.refilled)) * Self.cursorLaneRate)
        lane.refilled = now
        guard lane.tokens >= 1 else {
            // Over the limit: hold only the newest, and relay it when a token
            // refills. Each extra frame costs this one assignment.
            lane.pending = input
            if lane.flush == nil {
                let wait = max(1, Int(ceil((1 - lane.tokens) / Self.cursorLaneRate * 1000)))
                lane.flush = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(wait)) } catch { return }
                    await self?.flushCursorLane(id)
                }
            }
            cursorLanes[id] = lane
            return
        }
        lane.tokens -= 1
        lane.pending = nil
        lane.flush?.cancel(); lane.flush = nil
        cursorLanes[id] = lane
        relay(input, from: lane)
    }

    public func closeCursorLane(_ id: UUID) {
        guard let lane = cursorLanes.removeValue(forKey: id) else { return }
        lane.flush?.cancel()
        cursorLaneAreas[lane.area]?.remove(id)
        if cursorLaneAreas[lane.area]?.isEmpty == true { cursorLaneAreas[lane.area] = nil }
        lane.continuation.finish()
    }

    /// Count-only diagnostics for the lane checks.
    public func openCursorLanes() -> Int { cursorLanes.count }

    func closeCursorLanes(where match: (CollaborationCursorLane) -> Bool) {
        for (id, lane) in cursorLanes where match(lane) { closeCursorLane(id) }
    }

    private func flushCursorLane(_ id: UUID) {
        guard var lane = cursorLanes[id] else { return }
        lane.flush = nil
        let now = clock()
        lane.tokens = min(Self.cursorLaneBurst, lane.tokens + max(0, now.timeIntervalSince(lane.refilled)) * Self.cursorLaneRate)
        lane.refilled = now
        guard let input = lane.pending else { cursorLanes[id] = lane; return }
        lane.pending = nil
        lane.tokens = max(0, lane.tokens - 1)
        cursorLanes[id] = lane
        relay(input, from: lane)
    }

    private func relay(_ input: Collaboration.PresenceInput, from lane: CollaborationCursorLane) {
        do {
            guard try recordPresence(area: lane.area, identity: lane.identity, label: lane.label, input: input) else { return }
        } catch {
            // The input was validated on arrival, so this is a presence session
            // the relay does not know (ended, or lost in a restart).
            lane.continuation.yield(.init(rejectedSession: input.session))
            return
        }
        let frame = Collaboration.CursorFrame(identity: lane.identity, session: input.session, sequence: input.sequence,
            cursor: input.cursor, viewport: input.viewport, sentAt: input.sentAt)
        for other in cursorLaneAreas[lane.area] ?? [] {
            guard let target = cursorLanes[other], target.identity.device != lane.identity.device else { continue }
            target.continuation.yield(.init(frame: frame))
        }
    }
}
