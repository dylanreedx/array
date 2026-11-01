import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct LaneFailure: Error { let message: String }
private func laneCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw LaneFailure(message: label) }
    print("PASS cursor lane: \(label)")
}
private func laneRefuses(_ label: String, _ expected: CollaborationStoreError, _ action: () async throws -> Void) async throws {
    do { try await action(); throw LaneFailure(message: "\(label) unexpectedly succeeded") }
    catch let error as CollaborationStoreError where error == expected { print("PASS cursor lane: \(label)") }
}
private final class LaneClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
/// Everything a lane delivered, and whether it has finished.
private actor Inbox {
    private(set) var messages: [Collaboration.CursorLaneMessage] = []
    private(set) var finished = false
    func add(_ value: Collaboration.CursorLaneMessage) { messages.append(value) }
    func finish() { finished = true }
    var frames: [Collaboration.CursorFrame] { messages.compactMap(\.frame) }
    var rejections: [UUID] { messages.compactMap(\.rejectedSession) }
}
private func collect(_ stream: AsyncStream<Collaboration.CursorLaneMessage>) -> Inbox {
    let inbox = Inbox()
    Task { for await message in stream { await inbox.add(message) }; await inbox.finish() }
    return inbox
}
private func eventually(_ label: String, _ value: () async -> Bool) async throws {
    for _ in 0..<400 { if await value() { return }; try await Task.sleep(for: .milliseconds(5)) }
    throw LaneFailure(message: "timed out: \(label)")
}

/// The cursor lane in the store, then over the wire through the real relay
/// server. Store: admission, fan-out to teammates only, page agreement, stale
/// and unknown frames, the per-lane token bucket with its trailing flush, the
/// device limit and revocation. Wire (where URLSession has WebSockets): the
/// upgrade is refused to a non-member and a frame crosses between two members.
func runCollaborationCursorLaneChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-cursor-lane-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = LaneClock(), key = Data(repeating: 83, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key, clock: { clock.now() })
    func person(_ label: String) async throws -> Collaboration.Credential {
        try await store.redeem(.init(code: try await store.provisionPerson(label: label).code, deviceLabel: label))
    }
    let a = try await person("Lane A"), b = try await person("Lane B"), c = try await person("Lane C")
    let state = try await store.createArea(token: a.token), area = state.scope.area.rawValue
    _ = try await store.accept(token: b.token, code: try await store.invite(token: a.token, area: area, request: .init(person: b.identity.person)).code)

    // Admission.
    try await store.admitCursorLane(token: b.token, area: area)
    try await laneRefuses("a non-member is refused the lane", .unavailable) { try await store.admitCursorLane(token: c.token, area: area) }
    try await laneRefuses("an unknown bearer is refused the lane", .unauthorized) { try await store.admitCursorLane(token: "not-a-token", area: area) }
    try await laneRefuses("a non-member cannot open a lane", .unavailable) { _ = try await store.openCursorLane(token: c.token, area: area) }

    let laneA = try await store.openCursorLane(token: a.token, area: area), laneB = try await store.openCursorLane(token: b.token, area: area)
    let inboxA = collect(laneA.messages), inboxB = collect(laneB.messages)
    let session = try await store.beginPresence(token: a.token, area: area).id

    // Fan-out: the teammate gets the frame as sent; the sender gets nothing.
    try await store.streamCursor(laneA.id, input: .init(session: session, sequence: 1, cursor: .init(x: 10, y: 20), sentAt: 1234.5))
    try await eventually("B receives A's first frame") { await inboxB.frames.count == 1 }
    let first = await inboxB.frames[0]
    try laneCheck(first.identity == a.identity && first.cursor == .init(x: 10, y: 20) && first.sequence == 1 && first.session == session && first.sentAt == 1234.5,
        "a frame reaches the teammate's lane with its identity, position, sequence and sample time")
    try await Task.sleep(for: .milliseconds(30))
    try laneCheck(await inboxA.messages.isEmpty, "the sender's own lane does not echo its frame")

    // The same entry the update pages read, with its order.
    let head = state.document.revision
    let page = try await store.updates(token: b.token, area: area, request: .init(after: head, waitMilliseconds: 0))
    let seen = page.presence.first { $0.identity.device == a.identity.device }
    try laneCheck(seen?.cursor == .init(x: 10, y: 20) && seen?.session == session && seen?.sequence == 1,
        "an update page carries the lane's position with its session and sequence, for viewers without a lane")

    // Stale and unknown.
    try await store.streamCursor(laneA.id, input: .init(session: session, sequence: 1, cursor: .init(x: 99, y: 99)))
    let stranger = UUID()
    try await store.streamCursor(laneA.id, input: .init(session: stranger, sequence: 2, cursor: .init(x: 1, y: 1)))
    try await eventually("A is told its unknown session was refused") { await inboxA.rejections == [stranger] }
    try laneCheck(await inboxB.frames.count == 1, "a stale sequence and an unknown session are not relayed")
    try await laneRefuses("a non-finite position is refused", .invalidRequest) {
        try await store.streamCursor(laneA.id, input: .init(session: session, sequence: 3, cursor: .init(x: .infinity, y: 0)))
    }

    // Rate: a burst over the bucket relays the bucket, then the newest frame.
    clock.advance(10)
    let burst = Int(CollaborationStore.cursorLaneBurst)
    for sequence in 10..<(10 + burst + 20) {
        try await store.streamCursor(laneA.id, input: .init(session: session, sequence: UInt64(sequence), cursor: .init(x: Double(sequence), y: 0)))
    }
    let last = UInt64(10 + burst + 20 - 1)
    try await eventually("the trailing frame is relayed") { await inboxB.frames.last?.sequence == last }
    let relayed = await inboxB.frames.count - 1
    try laneCheck(relayed == burst + 1,
        "\(burst + 20) frames at once relay the \(burst)-frame bucket and then only the newest (\(relayed) relayed)")
    let atRate = Int(CollaborationStore.cursorLaneRate)
    try laneCheck(atRate >= 60 && CollaborationStore.cursorLaneBurst >= 2,
        "the lane allows a full 60 Hz sender (\(atRate) frames/s sustained), unlike the pages' 20 Hz")

    // Limits and revocation.
    // Held: a lane whose message stream is dropped closes itself.
    var extra: [(id: UUID, messages: AsyncStream<Collaboration.CursorLaneMessage>)] = []
    for _ in 0..<(CollaborationStore.cursorLaneDeviceLimit - 1) { extra.append(try await store.openCursorLane(token: b.token, area: area)) }
    try await laneRefuses("a device past its lane limit is refused", .tooManySubscriptions) { _ = try await store.openCursorLane(token: b.token, area: area) }
    for lane in extra { await store.closeCursorLane(lane.id) }
    extra = []
    let dropped = try await store.openCursorLane(token: b.token, area: area).id
    try await eventually("a lane nobody reads closes") { await store.openCursorLanes() == 2 }
    try laneCheck(true, "a lane whose reader is gone closes itself (\(dropped))")
    let epoch = try await store.state(token: a.token, area: area).scope.epoch
    try await store.removeMember(token: a.token, area: area, person: b.identity.person.rawValue, expectedEpoch: epoch)
    try await eventually("a removed member's lane ends") { await inboxB.finished }
    try await store.revokeDevice(token: a.token, device: a.identity.device)
    try await eventually("a revoked device's lane ends") { await inboxA.finished }
    try await eventually("no lane stays open") { await store.openCursorLanes() == 0 }
    try laneCheck(true, "removal and device revocation close their lanes")

    #if !canImport(FoundationNetworking)
    try await runCursorLaneWireChecks(root: root, key: key)
    #endif
}

#if !canImport(FoundationNetworking)
private func runCursorLaneWireChecks(root: URL, key: Data) async throws {
    let store = try CollaborationStore(path: root.appendingPathComponent("wire.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func person(_ label: String) async throws -> CollaborationAPI {
            let credential = try await store.redeem(.init(code: try await store.provisionPerson(label: label).code, deviceLabel: label))
            return try CollaborationAPI(baseURL: endpoint, credential: credential.token, allowsInsecureLoopback: true)
        }
        let a = try await person("Wire A"), b = try await person("Wire B"), c = try await person("Wire C")
        let area = try await a.createArea().scope.area.rawValue
        _ = try await b.accept(code: try await a.invite(area: area, request: .init(person: try await b.identity().person)).code)
        do {
            _ = try await c.openCursorLane(area: area)
            throw LaneFailure(message: "a non-member opened a lane over the wire")
        } catch CollaborationClientError.server(let status, _) {
            try laneCheck(status == 404, "the relay refuses a non-member's WebSocket upgrade with 404, before any frame (\(status))")
        }
        let laneA = try await a.openCursorLane(area: area), laneB = try await b.openCursorLane(area: area)
        let inboxB = collect(laneB.messages)
        let session = try await a.beginPresence(area: area).id
        let sent = Date()
        try await laneA.send(.init(session: session, sequence: 1, cursor: .init(x: 7, y: 8), sentAt: 42))
        try await eventually("B's WebSocket receives A's frame") { await inboxB.frames.count == 1 }
        let elapsed = Date().timeIntervalSince(sent) * 1000
        let frame = await inboxB.frames[0]
        try laneCheck(frame.cursor == .init(x: 7, y: 8) && frame.sentAt == 42,
            String(format: "a frame crosses the relay between two members' WebSockets (%.1f ms on loopback)", elapsed))
        laneA.close(); laneB.close()
        try await eventually("closing the sockets closes the lanes") { await store.openCursorLanes() == 0 }
        try laneCheck(true, "a closed WebSocket leaves no lane behind")
    } catch { try? await server.stop(); throw error }
    try await server.stop()
}
#endif
