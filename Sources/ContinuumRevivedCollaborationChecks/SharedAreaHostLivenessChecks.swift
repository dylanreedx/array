import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private final class LivenessVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private final class LivenessStoreClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private func hostLivenessCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw CheckFailure(label: label) }
    print("PASS host liveness client: \(label)")
}
@MainActor
private func waitFor(_ label: String, _ predicate: () throws -> Bool) async throws {
    for _ in 0..<250 {
        if try predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CheckFailure(label: "timeout: \(label)")
}

/// The production account factories, heartbeat and teammate controller over the
/// actual relay routes. The relay's clock is injected so a lost host ages
/// deterministically; heartbeats beyond the first are driven explicitly.
@MainActor
func runSharedAreaHostLivenessChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-host-liveness-client-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = LivenessStoreClock(), key = Data(repeating: 73, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key, clock: { clock.now() })
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    var controllers: [SharedAreaController] = []
    var heartbeats: [SharedAreaHostHeartbeat] = []
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let endpoint = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
        let credentials = CollaborationCredentialStore(vault: LivenessVault(), bundleIdentifier: AppChannel.devBundleIdentifier)
        func account(_ label: String) async throws -> (CollaborationAccountController, Collaboration.Credential) {
            let code = try await store.provisionPerson(label: label)
            let accountStore = try CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("support-\(label)"),
                bundleIdentifier: AppChannel.devBundleIdentifier)
            let model = try CollaborationAccountController(store: accountStore, credentialStore: credentials, bundleIdentifier: AppChannel.devBundleIdentifier)
            let enrolled = try await model.enroll(endpoint: endpoint, code: code.code, deviceLabel: label, accountLabel: label)
            return (model, try credentials.load(for: .init(endpoint: endpoint, identity: enrolled.identity))!)
        }
        let (accountA, a) = try await account("host-owner"), (accountB, _) = try await account("teammate")
        let area = try await accountA.createArea(label: "Liveness").document.id
        _ = try await accountB.acceptInvitation(code: try await accountA.invite(area: area.rawValue, person: accountB.activeAccount!.identity.person).code)
        let host = try await accountA.registerHost()
        let apiA = try CollaborationAPI(baseURL: url, credential: a.token, allowsInsecureLoopback: true)
        let observation = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host, binding: .init()))
        _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: 0, edits: [
            .admit(observation, .init(id: .init(), object: observation.id, rect: .init(x: 0, y: 0, width: 400, height: 240)))
        ])))
        // A presence publish is ordinary unrelated traffic that wakes the
        // teammate's held read after the injected relay clock moved.
        let pointer = try await apiA.beginPresence(area: area.rawValue)
        var pointerSequence: UInt64 = 0
        func nudge() async throws {
            pointerSequence += 1
            try await apiA.publishPresence(area: area.rawValue, value: .init(session: pointer.id, sequence: pointerSequence, cursor: .init(x: 1, y: Double(pointerSequence))))
        }

        let teammate = try accountB.makeSharedAreaController(area: area.rawValue)
        controllers.append(teammate)
        await teammate.open()
        try await waitFor("teammate connected") { teammate.status == .connected && teammate.document?.items.count == 1 }
        func seen() -> Collaboration.HostLiveness? { SharedAreaHostLivenessCopy.liveness(for: observation, in: teammate.hostLiveness) }
        try hostLivenessCheck(seen() == nil && SharedAreaHostLivenessCopy.cardLine(seen()) == "Host has not checked in.",
            "before any beat the teammate's card says the host has not checked in")

        // The handoff factory's production transport is the heartbeat transport.
        func launchHost() throws -> SharedAreaHostHeartbeat {
            let model = try accountA.makeAgentHandoffController(area: area.rawValue)
            guard let transport = model.transport as? any SharedAreaHostHeartbeatTransport else {
                throw CheckFailure(label: "production handoff transport cannot carry host heartbeats")
            }
            let beat = SharedAreaHostHeartbeat(transport: transport, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
            heartbeats.append(beat)
            return beat
        }
        let first = try launchHost()
        first.track(host: host)
        try await waitFor("first run online for the teammate") { seen()?.state == .online && seen()?.generation == first.generation }
        try hostLivenessCheck(SharedAreaHostLivenessCopy.cardLine(seen()) == "Host online.", "the teammate sees the tracked host online")
        let firstGeneration = first.generation!

        // The host is lost: no beats while the relay clock moves on.
        clock.advance(31); try await nudge()
        try await waitFor("stale after 31 s") { seen()?.state == .stale }
        try hostLivenessCheck(SharedAreaHostLivenessCopy.cardLine(seen()) == "Host not responding. Its agents may still be running.",
            "a lost host reads as not responding, not as stopped")
        try hostLivenessCheck(teammate.presence.count == 1, "the owner's live pointer does not keep the lost host online")
        clock.advance(60); try await nudge()
        try await waitFor("offline after 91 s") { seen()?.state == .offline }
        try hostLivenessCheck(seen()?.reason == .expired && SharedAreaHostLivenessCopy.cardLine(seen()) == "Host offline. Execution is unavailable.",
            "an expired host reads as offline with execution unavailable")
        try hostLivenessCheck(teammate.status == .connected && teammate.document?.items.first?.id == observation.id,
            "the teammate keeps the shared workspace readable while the host is offline")

        // The host app relaunches: a fresh heartbeat mints a new run.
        let second = try launchHost()
        second.track(host: host)
        try await waitFor("relaunched run online") { seen()?.state == .online && seen()?.generation == second.generation }
        try hostLivenessCheck(second.generation != firstGeneration, "the relaunched host rejoins under a new run generation")
        await first.beatOnce()
        try hostLivenessCheck(first.phase == .superseded, "the retired run is told it was superseded and stops")
        first.track(host: host)
        try hostLivenessCheck(first.phase == .superseded && first.generation == firstGeneration,
            "a superseded run does not mint a replacement to take the host back")
        try await nudge()
        try await Task.sleep(for: .milliseconds(200))
        try hostLivenessCheck(seen()?.generation == second.generation && seen()?.state == .online, "the teammate still sees the relaunched run")

        // Clean shutdown.
        second.end()
        try await waitFor("ended") { seen()?.state == .offline && seen()?.reason == .ended }
        try hostLivenessCheck(SharedAreaHostLivenessCopy.cardLine(seen()) == "Host offline. Its owner closed the shared workspace.",
            "a clean shutdown is offline at once, without waiting for expiry")
    } catch {
        for beat in heartbeats { beat.end() }
        for controller in controllers { await controller.close() }
        try? await server.stop(); throw error
    }
    for controller in controllers { await controller.close() }
    try await server.stop()
}
