import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct LivenessFailure: Error { let message: String }
private func livenessCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw LivenessFailure(message: label) }
    print("PASS host liveness: \(label)")
}
private func livenessRefuses(_ expected: Int, _ label: String, _ action: () async throws -> Void) async throws {
    do { try await action(); throw LivenessFailure(message: "\(label) unexpectedly succeeded") }
    catch let error as CollaborationClientError {
        guard case .server(let status, _) = error, status == expected else { throw LivenessFailure(message: "\(label): \(error)") }
        print("PASS host liveness: \(label)")
    }
}
/// JSON dates are ISO 8601 without fractional seconds.
private func sameSecond(_ value: Date?, _ expected: Date) -> Bool {
    guard let value else { return false }
    return abs(value.timeIntervalSince(expected)) < 1
}
private final class LivenessClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// Real localhost HTTP over the production routes, an injected store clock and
/// a relay restart on the same database. A host is lost, goes stale, goes
/// offline, rejoins with a new run generation, and its retired run stays fenced.
/// Pointer TTL and host liveness are driven against each other in both orders.
func runCollaborationHostLivenessChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-host-liveness-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = LivenessClock(), key = Data(repeating: 71, count: 32)
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    func serve(_ store: CollaborationStore) async throws -> (RelayServer, URL) {
        let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
        try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!)
    }
    var store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
    var (server, endpoint) = try await serve(store)
    do {
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: enrollment.code, deviceLabel: label)
        }
        let a = try await person("Host owner A"), b = try await person("Teammate B"), c = try await person("Excluded C")
        func client(_ credential: Collaboration.Credential) throws -> CollaborationAPI {
            try CollaborationAPI(baseURL: endpoint, credential: credential.token, allowsInsecureLoopback: true)
        }
        var aa = try client(a), bb = try client(b), cc = try client(c)
        let state = try await aa.createArea(), area = state.document.id.rawValue
        _ = try await bb.accept(code: try await aa.invite(area: area, request: .init(person: b.identity.person)).code)
        let host = try await aa.registerHost().id
        let observation = SharedArea.Item(id: .init(), kind: .agentObservation,
            source: .init(owner: a.identity.person, host: host, binding: .init()))
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: state.document.id, expectedRevision: 0, edits: [
            .admit(observation, .init(id: .init(), object: observation.id, rect: .init(x: 0, y: 0, width: 400, height: 240)))
        ])))
        func view(_ api: CollaborationAPI) async throws -> Collaboration.Updates {
            let head = try await api.state(area: area).document.revision
            return try await api.updates(area: area, request: .init(after: head, waitMilliseconds: 0))
        }
        func seen(_ api: CollaborationAPI, _ id: SharedArea.ID<SharedArea.Host> = host) async throws -> Collaboration.HostLiveness? {
            try await view(api).hosts?.first { $0.host == id }
        }

        try await livenessCheck(try await view(bb).hosts == [], "a host that never beat is absent, not online")
        // Names come from the relay's records, so a teammate with no presence
        // (their Mac offline) is still named.
        let members = try await view(bb).members ?? []
        try await livenessCheck(Set(members.map { "\($0.person.rawValue) \($0.label)" })
            == ["\(a.identity.person.rawValue) Host owner A", "\(b.identity.person.rawValue) Teammate B"],
            "every update page names the area's members by their recorded labels, with no presence, and nobody outside it")

        // Authentication and scope.
        let g1 = UUID()
        try await livenessRefuses(403, "a teammate cannot beat for another device's host") {
            _ = try await bb.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 1))
        }
        try await livenessRefuses(404, "a non-member cannot beat into the area") {
            _ = try await cc.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 1))
        }
        try await livenessRefuses(401, "an unauthenticated beat is refused") {
            _ = try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true)
                .hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 1))
        }
        try await livenessRefuses(400, "sequence zero is not a beat") {
            _ = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 0))
        }
        try await livenessCheck(try await view(bb).hosts == [], "refused beats leave no liveness behind")

        let started = clock.now()
        var beat = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 1))
        try await livenessCheck(beat.state == .online && beat.generation == g1 && sameSecond(beat.lastSeen, started), "the owning device's beat is online")
        try await livenessCheck(try await seen(bb)?.state == .online, "a teammate sees the host online")
        try await livenessRefuses(404, "an excluded person sees no liveness") { _ = try await view(cc) }

        // Pointer TTL expires while the host stays alive.
        let presence = try await aa.beginPresence(area: area)
        try await aa.publishPresence(area: area, value: .init(session: presence.id, sequence: 1, cursor: .init(x: 1, y: 1)))
        try await livenessCheck(try await view(bb).presence.count == 1, "pointer published")
        clock.advance(10); beat = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 2))
        clock.advance(10); beat = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 3))
        var page = try await view(bb)
        try await livenessCheck(page.presence.isEmpty && page.hosts?.first?.state == .online,
            "after 20 s the pointer has expired and the beating host is still online")

        // Host lost while its owner's pointer keeps moving.
        let lastBeat = clock.now()
        for sequence in 2...4 {
            clock.advance(10)
            try await aa.publishPresence(area: area, value: .init(session: presence.id, sequence: UInt64(sequence), cursor: .init(x: 2, y: Double(sequence))))
        }
        page = try await view(bb)
        try await livenessCheck(page.presence.count == 1 && page.hosts?.first?.state == .stale && sameSecond(page.hosts?.first?.lastSeen, lastBeat),
            "after 30 s without a beat the host is stale while the pointer is live")
        try await livenessCheck(page.hosts?.first?.reason == nil && sameSecond(page.hosts?.first?.offlineAt, lastBeat.addingTimeInterval(90)),
            "stale carries no offline reason and names when it will go offline")

        // A held reader wakes on the time-driven transition with no new traffic.
        clock.advance(59.7)
        let before = try await view(bb)
        try await livenessCheck(before.hosts?.first?.state == .stale, "89.7 s without a beat is still stale")
        let reader = bb, cursor = before.through, version = before.presenceVersion
        let held = Task { [reader] in
            try await reader.updates(area: area, request: .init(after: cursor, presenceVersion: version, waitMilliseconds: 25_000))
        }
        try await Task.sleep(for: .milliseconds(80))
        clock.advance(1)
        let wakeStarted = ContinuousClock.now
        let woken = try await held.value
        try await livenessCheck(ContinuousClock.now - wakeStarted < .seconds(5) && woken.presenceVersion != before.presenceVersion
            && woken.hosts?.first?.state == .offline && woken.hosts?.first?.reason == .expired,
            "a held reader is woken at the offline transition, not after its 25 s hold")

        // The lost host rejoins as a new run; its old run is fenced.
        let g2 = UUID()
        beat = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g2, sequence: 1))
        try await livenessCheck(beat.state == .online && beat.generation == g2 && sameSecond(beat.lastSeen, clock.now()), "the relaunched run rejoins online")
        try await livenessCheck(try await seen(bb)?.generation == g2, "a teammate sees the new run generation")
        try await livenessRefuses(409, "a late beat from the retired run is refused") {
            _ = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 99))
        }
        try await livenessCheck(try await seen(bb)?.generation == g2, "the retired run did not take the host back")

        // Reordered beats do not refresh the run.
        let g2Seen = clock.now()
        clock.advance(20)
        _ = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g2, sequence: 1))
        try await livenessCheck(sameSecond(try await seen(bb)?.lastSeen, g2Seen), "a replayed sequence does not refresh last-seen")
        beat = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g2, sequence: 2))
        try await livenessCheck(sameSecond(beat.lastSeen, clock.now()), "the next sequence does")

        // Relay restart: liveness and the fence survive on disk.
        try await server.stop()
        store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
        (server, endpoint) = try await serve(store)
        aa = try client(a); bb = try client(b); cc = try client(c)
        let restarted = try await seen(bb)
        try livenessCheck(restarted?.generation == g2 && restarted?.state == .online,
            "after a relay restart the current run is still online at its persisted last-seen")
        try await livenessRefuses(409, "after a relay restart the retired run is still fenced") {
            _ = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g1, sequence: 100))
        }
        clock.advance(31)
        try await livenessCheck(try await seen(bb)?.state == .stale, "a restarted relay ages the persisted run on its own clock")

        // Clean shutdown is offline at once and cannot be revived.
        try await aa.endHost(area: area, host: host, generation: UUID())
        try await livenessCheck(try await seen(bb)?.state == .stale, "ending some other run leaves the current one alone")
        try await aa.endHost(area: area, host: host, generation: g2)
        let ended = try await seen(bb)
        try await livenessCheck(ended?.state == .offline && ended?.reason == .ended, "an explicit end is offline immediately")
        try await livenessRefuses(409, "an ended run cannot beat itself back online") {
            _ = try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g2, sequence: 3))
        }
        let g3 = UUID()
        try await livenessCheck(try await aa.hostHeartbeat(area: area, host: host, beat: .init(generation: g3, sequence: 1)).state == .online,
            "a new run after a clean end is online")

        // Access removal: a teammate's host goes offline the moment they lose access.
        let hostB = try await bb.registerHost().id
        _ = try await bb.hostHeartbeat(area: area, host: hostB, beat: .init(generation: UUID(), sequence: 1))
        try await livenessCheck(try await seen(aa, hostB)?.state == .online, "an editor's own host is online")
        try await aa.removeMember(area: area, person: b.identity.person.rawValue, epoch: 1)
        let removed = try await seen(aa, hostB)
        try await livenessCheck(removed?.state == .offline && removed?.reason == .accessRemoved,
            "a removed member's host is offline without waiting for expiry")
        try await livenessRefuses(404, "a removed member cannot beat") {
            _ = try await bb.hostHeartbeat(area: area, host: hostB, beat: .init(generation: UUID(), sequence: 1))
        }
    } catch { try? await server.stop(); throw error }
    try await server.stop()
}
