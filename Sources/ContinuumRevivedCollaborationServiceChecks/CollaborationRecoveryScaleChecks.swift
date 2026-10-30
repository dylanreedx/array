import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService

private struct ScaleFailure: Error { let message: String }
private func scaleExpect(_ value: Bool, _ message: String) throws {
    guard value else { throw ScaleFailure(message: message) }
    print("PASS recovery/scale: \(message)")
}
private func eventually(_ label: String, seconds: Double = 30, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw ScaleFailure(message: "timeout: \(label)") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Every status a session reports, in order. The stream buffers only the newest
/// value, so the session status itself is also sampled after each emission.
private actor StatusLog {
    enum Kind: Equatable { case connected, reconnecting, unavailable, stopped }
    struct Entry { let kind: Kind; let revision: UInt64? }
    private(set) var entries: [Entry] = []
    func record(_ status: CollaborationSession.Status) {
        switch status {
        case .connected(let replica): entries.append(.init(kind: .connected, revision: replica.document.revision))
        case .reconnecting(let replica): entries.append(.init(kind: .reconnecting, revision: replica?.document.revision))
        case .unavailable: entries.append(.init(kind: .unavailable, revision: nil))
        case .stopped: entries.append(.init(kind: .stopped, revision: nil))
        }
    }
    func reset() { entries = [] }
}

/// The real operator binary, killed with SIGKILL and relaunched on its port.
private final class RelayProcess {
    let port: Int
    let environment: [String: String]
    let log: URL
    private var process: Process?
    init(root: URL, collaborationPath: String, key: Data) throws {
        port = try Self.freePort()
        log = root.appendingPathComponent("relay.log")
        // Explicit environment only: no proxy, APNs or production configuration.
        environment = [
            "RELAY_HOST": "127.0.0.1", "PORT": String(port), "RELAY_ADMIN_PORT": "0",
            "RELAY_DATABASE_PATH": root.appendingPathComponent("companion.sqlite").path,
            "RELAY_MASTER_KEY": key.base64EncodedString(),
            "RELAY_COLLABORATION_DATABASE_PATH": collaborationPath,
            "RELAY_COLLABORATION_MASTER_KEY": key.base64EncodedString(),
            "PATH": "/usr/bin:/bin",
        ]
        FileManager.default.createFile(atPath: log.path, contents: nil)
    }
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func start() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("continuum-relay")
        process.environment = environment
        let handle = try FileHandle(forWritingTo: log); handle.seekToEndOfFile()
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        self.process = process
        let probe = base.appendingPathComponent("collaboration/v1/self")
        try await eventually("relay ready on \(port)", seconds: 15) {
            guard process.isRunning else { throw ScaleFailure(message: "relay exited during startup") }
            var request = URLRequest(url: probe); request.timeoutInterval = 1
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 401
        }
    }
    /// No graceful shutdown: in-flight requests and held reads are cut.
    func kill() {
        guard let process, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        self.process = nil
    }
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScaleFailure(message: "socket") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { throw ScaleFailure(message: "bind") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private func post(_ area: SharedArea.ID<SharedArea.Area>, _ object: SharedArea.ID<SharedArea.Object>, _ author: SharedArea.ID<SharedArea.Person>,
                  after revision: UInt64, _ text: String) -> SharedArea.Command {
    .init(area: area, expectedRevision: revision, edits: [.post(.init(id: .init(), object: object, author: author, text: text))])
}

/// (b) relay kill/restart mid-change, (c) bootstrap plus paged tail beyond 500
/// events and (d) bounded, reported subscription overload. Real HTTP throughout.
func runCollaborationRecoveryScaleChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-scale-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 61, count: 32)
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let relay = try RelayProcess(root: root, collaborationPath: path, key: key)
    // The operator seam provisions people; the relay process owns serving.
    let operatorStore = try CollaborationStore(path: path, masterKey: key)
    try await relay.start()
    var sessions: [CollaborationSession] = []
    var observers: [Task<Void, Never>] = []
    do {
        func person(_ label: String) async throws -> (Collaboration.Credential, CollaborationAPI) {
            let enrollment = try await operatorStore.provisionPerson(label: label)
            let anonymous = try CollaborationAPI(baseURL: relay.base, allowsInsecureLoopback: true)
            let credential = try await anonymous.redeem(code: enrollment.code, deviceLabel: label)
            return (credential, try CollaborationAPI(baseURL: relay.base, credential: credential.token, allowsInsecureLoopback: true))
        }
        let (a, apiA) = try await person("Scale A"), (b, apiB) = try await person("Scale B")
        let created = try await apiA.createArea(), area = created.scope.area
        _ = try await apiB.accept(code: try await apiA.invite(area: area.rawValue, request: .init(person: b.identity.person)).code)
        let thread = SharedArea.Item(id: .init(), kind: .discussion)
        _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: 0,
            edits: [.admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 640, height: 520)))])))
        let bootstrapA = try await apiA.state(area: area.rawValue), bootstrapB = try await apiB.state(area: area.rawValue)

        func observe(_ api: CollaborationAPI, _ initial: Collaboration.State) async throws -> (CollaborationSession, StatusLog) {
            let session = try CollaborationSession(api: api, area: area.rawValue, initial: initial)
            let log = StatusLog(), stream = await session.start()
            observers.append(Task { for await status in stream { await log.record(status) } })
            sessions.append(session)
            return (session, log)
        }
        func connected(_ session: CollaborationSession, at revision: UInt64) async -> Bool {
            if case let .connected(replica) = await session.status { return replica.document.revision == revision }
            return false
        }
        func replica(_ session: CollaborationSession) async throws -> CollaborationReplica {
            guard case let .connected(replica) = await session.status else { throw ScaleFailure(message: "session not connected") }
            return replica
        }

        // (c) A watches live while 1,500 events commit; B bootstrapped before
        // them and replays the whole tail cold through bounded pages.
        let (liveA, logA) = try await observe(apiA, bootstrapA)
        try await eventually("A live") { await connected(liveA, at: 1) }
        let total: UInt64 = 1_500
        for index in 1...total {
            _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1,
                command: post(area, thread.id, a.identity.person, after: index, "Replay \(index)")))
        }
        let head = 1 + total
        let firstPage = try await apiB.updates(area: area.rawValue, request: .init(after: bootstrapB.document.revision, waitMilliseconds: 0))
        try scaleExpect(firstPage.hasMore && firstPage.events.count == CollaborationStore.updatePageLimit && firstPage.through == head,
            "a \(total)-event tail is served in bounded \(CollaborationStore.updatePageLimit)-event pages against one high-water mark")
        let (coldB, logB) = try await observe(apiB, bootstrapB)
        try await eventually("B replay complete") { await connected(coldB, at: head) }
        try await eventually("A live complete") { await connected(liveA, at: head) }
        let server = try await apiA.state(area: area.rawValue).document.canonicalData()
        let replicaA = try await replica(liveA), replicaB = try await replica(coldB)
        try scaleExpect(replicaB.document.posts.count == Int(total) && Set(replicaB.document.posts.map(\.text)).count == Int(total),
            "cold replay through bootstrap plus paged tail holds all \(total) events once")
        try scaleExpect(try replicaA.document.canonicalData() == server && replicaB.document.canonicalData() == server,
            "live and cold replicas are byte-identical to the authoritative document")
        let entriesB = await logB.entries
        let partial = entriesB.filter { $0.kind == .connected && $0.revision != head }
        let catchingUp = entriesB.filter { $0.kind == .reconnecting }
        try scaleExpect(partial.isEmpty && !catchingUp.isEmpty && catchingUp.allSatisfy { ($0.revision ?? 0) < head },
            "a bounded tail reports catching up and never presents a partial prefix as connected shared state")
        try scaleExpect(zip(entriesB, entriesB.dropFirst()).allSatisfy { ($0.revision ?? 0) <= ($1.revision ?? 0) },
            "cold replay advances monotonically without a gap or rewind")

        // (b) Kill the relay with a commit in flight, relaunch it on the same
        // port and resume both sessions from their cursors.
        await logA.reset(); await logB.reset()
        var issued: [SharedArea.Command] = []
        var revision = head
        for index in 1...20 {
            let command = post(area, thread.id, a.identity.person, after: revision, "Before kill \(index)")
            _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: command))
            issued.append(command); revision += 1
        }
        let inFlight = post(area, thread.id, b.identity.person, after: revision, "In flight at kill")
        let racing = Task { try await apiB.apply(area: area.rawValue, mutation: .init(epoch: 1, command: inFlight)) }
        relay.kill()
        let raced: Collaboration.Receipt? = try? await racing.value
        try await eventually("both sessions observe the outage") {
            for session in [liveA, coldB] {
                guard case .reconnecting(let value) = await session.status, value != nil else { return false }
            }
            return true
        }
        try await relay.start()
        // With nothing new to deliver, both sessions still confirm the restarted
        // relay promptly instead of idling "reconnecting" inside a held read.
        let idleHead = try await apiA.state(area: area.rawValue).document.revision
        try await eventually("idle sessions reconnect", seconds: 5) {
            let a = await connected(liveA, at: idleHead), b = await connected(coldB, at: idleHead)
            return a && b
        }
        print("PASS recovery/scale: idle sessions report connected to the relaunched relay without waiting out a held read")
        // The uncertain request is resent with its original identity only.
        let resent = try await apiB.apply(area: area.rawValue, mutation: .init(epoch: 1, command: inFlight))
        try scaleExpect(resent.revision == revision + 1 && (raced == nil || resent.duplicate),
            "uncertain in-flight commit resolves to one revision whether or not it landed before the kill")
        issued.append(inFlight); revision += 1
        for index in 1...300 {
            let command = post(area, thread.id, a.identity.person, after: revision, "After restart \(index)")
            _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: command))
            issued.append(command); revision += 1
        }
        try await eventually("sessions resume after relay restart") {
            let a = await connected(liveA, at: revision), b = await connected(coldB, at: revision)
            return a && b
        }
        let restarted = try await apiB.state(area: area.rawValue).document
        let texts = restarted.posts.map(\.text)
        try scaleExpect(issued.allSatisfy { command in
            guard case let .post(value) = command.edits[0] else { return false }
            return texts.filter { $0 == value.text }.count == 1
        } && restarted.revision == revision, "after SIGKILL and relaunch every issued change is present exactly once")
        let afterA = try await replica(liveA), afterB = try await replica(coldB)
        try scaleExpect(try afterA.document.canonicalData() == restarted.canonicalData()
            && afterB.document.canonicalData() == restarted.canonicalData(),
            "both clients resume from their cursors to the relaunched relay's exact document")
        for log in [logA, logB] {
            let entries = await log.entries
            try scaleExpect(!entries.contains { $0.kind == .unavailable || ($0.kind == .reconnecting && $0.revision == nil) }
                && zip(entries, entries.dropFirst()).allSatisfy { ($0.revision ?? 0) <= ($1.revision ?? 0) },
                "outage keeps the validated replica: no access loss, no re-bootstrap and no rewind")
        }
        for session in sessions { await session.stop() }
        for observer in observers { _ = await observer.value }
        sessions = []; observers = []
        relay.kill()
    } catch {
        for session in sessions { await session.stop() }
        relay.kill()
        print("relay log: \((try? String(contentsOf: relay.log, encoding: .utf8)) ?? "")")
        throw error
    }
    try await runCollaborationOverloadBoundChecks(root: root, key: key)
    print("Collaboration recovery/scale checks passed: real relay SIGKILL/relaunch, 1,500-event bootstrap+paged replay and bounded overload.")
}

/// (d) The global held-read budget is a hard bound. The excess caller is refused
/// at once with a reported error, not parked, and capacity recovers on wake.
private func runCollaborationOverloadBoundChecks(root: URL, key: Data) async throws {
    let store = try CollaborationStore(path: root.appendingPathComponent("overload.sqlite").path, masterKey: key)
    let enrollment = try await store.provisionPerson(label: "Many devices")
    let first = try await store.redeem(.init(code: enrollment.code, deviceLabel: "Device 0"))
    var tokens = [first.token]
    let perDevice = CollaborationStore.updateDeviceLimit, global = CollaborationStore.updateGlobalLimit
    for index in 1...(global / perDevice) {
        let next = try await store.enrollDevice(token: first.token, lifetime: 600)
        tokens.append(try await store.redeem(.init(code: next.code, deviceLabel: "Device \(index)")).token)
    }
    let area = try await store.createArea(token: first.token).scope.area
    let thread = SharedArea.Item(id: .init(), kind: .discussion)
    _ = try await store.apply(token: first.token, area: area.rawValue, request: .init(epoch: 1, command: .init(area: area, expectedRevision: 0,
        edits: [.admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 300, height: 200)))])))
    let version = try await store.updates(token: first.token, area: area.rawValue, request: .init(after: 1, waitMilliseconds: 0)).presenceVersion
    var held: [Task<Collaboration.Updates, any Error>] = []
    for token in tokens.prefix(global / perDevice) {
        for _ in 0..<perDevice {
            held.append(Task { try await store.updates(token: token, area: area.rawValue, request: .init(after: 1, presenceVersion: version)) })
        }
    }
    try await eventually("\(global) held reads") { await store.activeUpdateRequests() == global }
    let excess = Task { try await store.updates(token: tokens.last!, area: area.rawValue, request: .init(after: 1, presenceVersion: version)) }
    let refused = Task { () -> Bool in
        do { _ = try await excess.value; return false } catch CollaborationStoreError.tooManySubscriptions { return true } catch { return false }
    }
    let timer = Task { try await Task.sleep(for: .seconds(2)); excess.cancel() }
    let wasRefused = await refused.value
    timer.cancel()
    try scaleExpect(wasRefused, "the read beyond the \(global)-request global budget is refused immediately as subscriptionLimit")
    let active = await store.activeUpdateRequests()
    try scaleExpect(active == global, "held reads never exceed the global budget")
    _ = try await store.apply(token: first.token, area: area.rawValue, request: .init(epoch: 1,
        command: post(area, thread.id, enrollment.person, after: 1, "Wakes every held reader")))
    var delivered = 0
    for task in held { if (try? await task.value)?.events.count == 1 { delivered += 1 } }
    let remaining = await store.activeUpdateRequests()
    try scaleExpect(delivered == global && remaining == 0,
        "one commit wakes and delivers to every admitted reader, releasing all capacity")
    let recovered = try await store.updates(token: tokens.last!, area: area.rawValue, request: .init(after: 1, waitMilliseconds: 0))
    try scaleExpect(recovered.events.count == 1, "the refused device recovers once capacity is released")
}
