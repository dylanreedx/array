import Foundation
import ContinuumRevivedCore
import ContinuumRevivedSync
import ContinuumRevivedRelayProtocol

private struct TaskPublishFailure: Error { let message: String }
private actor TaskPublisherFixture: CompanionTaskPublishingTransport {
    let inbound: AsyncStream<SyncMessage> = AsyncStream { _ in }
    let connectionState: AsyncStream<ContinuumRevivedSync.ConnectionState> = AsyncStream { _ in }
    var supported = true
    var owner: RelayNotificationOwnership?
    var events: [String] = []
    var snapshots: [CompanionTaskSnapshotBatch] = []
    var held = false
    var waiter: CheckedContinuation<Void, Never>?
    func send(_ message: SyncMessage) async throws { events.append("legacy") }
    func taskNotificationContext() async throws -> CompanionTaskNotificationContext { .init(supported: supported, owner: owner) }
    func publishTaskNotifications(_ snapshot: CompanionTaskSnapshotBatch) async throws {
        events.append("task.begin")
        if held { await withCheckedContinuation { waiter = $0 } }
        snapshots.append(snapshot); owner = .init(publisherID: snapshot.publisherID, revision: snapshot.revision)
        events.append("task.end")
    }
    func configure(supported: Bool = true, owner: RelayNotificationOwnership? = nil, held: Bool = false) {
        self.supported = supported; self.owner = owner; self.held = held
    }
    func isWaiting() -> Bool { waiter != nil }
    func release() { held = false; waiter?.resume(); waiter = nil }
    func results() -> ([String], [CompanionTaskSnapshotBatch]) { (events, snapshots) }
}
private actor TaskFreshnessFixture: CompanionLifecycleHintPublishing {
    func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws {}
    func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws {}
}

func runCompanionTaskPublicationChecks() async throws {
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw TaskPublishFailure(message: message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-publish-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    let run = try ledger.begin(agentID: UUID())
    let instance = UUID()
    func service(_ transport: TaskPublisherFixture, canvasFails: Bool = false, metadataFails: Bool = false) -> DesktopCompanionSyncService {
        DesktopCompanionSyncService(
            configuration: .init(containerIdentifier: "offline"), transport: transport,
            pairingSnapshot: { .init(instanceId: instance, pairedDeviceCount: 1, authorizedScope: .operator) },
            canvasSnapshot: {
                if canvasFails { throw TaskPublishFailure(message: "private canvas path") }
                return (CanvasState(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil), WorkspaceDocument(viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil))
            }, activitySnapshot: { .empty },
            taskSnapshot: { floor in
                if metadataFails { throw TaskPublishFailure(message: "private metadata path") }
                return try ledger.snapshot(revisionFloor: floor)
            }, freshnessPublisher: TaskFreshnessFixture())
    }
    let old = TaskPublisherFixture(); await old.configure(supported: false)
    try await service(old).publishCurrentDesktopSnapshot(reason: .manual)
    let oldResult = await old.results()
    try require(oldResult.1.isEmpty && oldResult.0 == ["legacy", "legacy"], "old relay capability must retain legacy inventory without task handover")
    let capable = TaskPublisherFixture()
    try await service(capable).publishCurrentDesktopSnapshot(reason: .manual)
    let result = await capable.results()
    try require(result.0 == ["task.begin", "task.end", "legacy", "legacy"] && result.1.count == 1, "task ownership must commit before legacy inventory")
    let invisible = TaskPublisherFixture()
    do { try await service(invisible, canvasFails: true).publishCurrentDesktopSnapshot(reason: .manual); throw TaskPublishFailure(message: "expected missing canvas") }
    catch let error as TaskPublishFailure where error.message == "private canvas path" {}
    try require(await invisible.results().1.count == 1, "missing canvas must not block task publication")
    let broken = TaskPublisherFixture(); let brokenService = service(broken, metadataFails: true)
    try await brokenService.publishCurrentDesktopSnapshot(reason: .manual)
    try require(await broken.results().0 == ["legacy", "legacy"], "metadata failure must preserve inventory without fabricated completion")
    try require(await brokenService.diagnostics.lastError == "Task notifications unavailable", "metadata errors must be redacted")
    let wrong = TaskPublisherFixture(); await wrong.configure(owner: .init(publisherID: UUID(), revision: 9))
    let wrongService = service(wrong)
    try await wrongService.publishCurrentDesktopSnapshot(reason: .manual)
    try require(await wrong.results().1.isEmpty, "foreign publisher must not take ownership")
    let concurrent = TaskPublisherFixture(); await concurrent.configure(held: true)
    let concurrentService = service(concurrent)
    let first = Task { try await concurrentService.publishCurrentDesktopSnapshot(reason: .manual) }
    for _ in 0..<1000 { if await concurrent.isWaiting() { break }; await Task.yield() }
    try require(await concurrent.isWaiting(), "nonvacuity: first task publish must be held")
    let second = Task { try await concurrentService.publishCurrentDesktopSnapshot(reason: .statusChanged) }
    // Give the second call an actor turn to join the in-flight publication.
    for _ in 0..<100 { await Task.yield() }
    try require(await concurrent.results().0 == ["task.begin"], "legacy inventory must wait for in-flight ownership")
    try ledger.observe(.turnStarted(threadId: "private", turnId: "live"), run: run)
    await concurrent.release()
    try await first.value; try await second.value
    let joined = await concurrent.results()
    try require(joined.1.count == 2 && joined.1.last?.revision == ledger.revision, "concurrent requests must serialize and publish the latest revision")
    try require(joined.0.prefix(4) == ["task.begin", "task.end", "task.begin", "task.end"], "joined publication must finish before either legacy send")
    let wire = String(decoding: try JSONEncoder().encode(joined.1.last!.relayTaskBatch), as: UTF8.self)
    try require(!wire.contains("private") && !wire.contains(root.path), "mapped task wire excludes local provider metadata")
    // An older schema omits capabilities; decoding must fail closed into legacy.
    let oldHealth = try JSONDecoder().decode(RelayHealth.self, from: Data("{\"status\":\"ok\",\"schemaVersion\":2}".utf8))
    try require(oldHealth.notificationPolicies.isEmpty, "old health cannot accidentally activate task policy")
    try await runTaskRelayTransportChecks(ledger: ledger)
    print("Companion task publication checks passed: capability fallback, ownership-before-inventory, headless publication, redacted failure, publisher fencing, concurrent serialization and latest revision")
}

private final class TaskRelayWireFixture: @unchecked Sendable {
    static let shared = TaskRelayWireFixture()
    private let lock = NSLock()
    private var handler: ((URLRequest) throws -> (Int, Data))?
    func set(_ handler: @escaping (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
    func response(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); let callback = handler; lock.unlock()
        guard let callback else { throw TaskPublishFailure(message: "wire fixture not installed") }; return try callback(request)
    }
}
private final class TaskRelayURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "array-task-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try TaskRelayWireFixture.shared.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class TaskRelayWireRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [URLRequest] = []
    func add(_ value: URLRequest) {
        var copy = value
        // URLSession converts POST bodies into streams before URLProtocol sees
        // them. Capture the actual stream; checking httpBody alone is vacuous.
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(buffer, count: count)
            }
            copy.httpBody = data
        }
        lock.lock(); defer { lock.unlock() }; records.append(copy)
    }
    func all() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return records }
}
private func runTaskRelayTransportChecks(ledger: CompanionTaskLedger) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskRelayURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let records = TaskRelayWireRecords()
    TaskRelayWireFixture.shared.set { request in
        records.add(request)
        return (200, Data("{\"status\":\"ok\",\"schemaVersion\":2}".utf8))
    }
    let old = RelaySyncTransport(baseURL: URL(string: "https://array-task-fixture.invalid")!, bearerToken: "offline", deviceLabel: "fixture", session: session, apiVersion: .hardenedV2)
    let oldContext = try await old.taskNotificationContext()
    guard !oldContext.supported, records.all().count == 1 else { throw TaskPublishFailure(message: "real relay transport must fall back on old health capabilities") }
    let snapshot = try ledger.snapshot(revisionFloor: 42)
    let currentRecords = TaskRelayWireRecords()
    TaskRelayWireFixture.shared.set { request in
        currentRecords.add(request)
        guard request.value(forHTTPHeaderField: "authorization") == "Bearer offline" else { throw TaskPublishFailure(message: "missing transport authority") }
        switch request.url?.path {
        case "/health": return (200, try JSONEncoder().encode(RelayHealth(schemaVersion: 4, notificationPolicies: ["task.batch.v1"])))
        case "/v2/notification-owner": return (200, try JSONEncoder().encode(RelayNotificationOwnershipResponse(owner: .init(publisherID: snapshot.publisherID, revision: 42))))
        case "/v2/events": return (201, Data("{}".utf8))
        default: throw TaskPublishFailure(message: "unexpected transport route")
        }
    }
    let transport = RelaySyncTransport(baseURL: URL(string: "https://array-task-fixture.invalid")!, bearerToken: "offline", deviceLabel: "fixture", session: session, apiVersion: .hardenedV2)
    let context = try await transport.taskNotificationContext()
    guard context.owner?.revision == 42 else { throw TaskPublishFailure(message: "actual ownership response not decoded") }
    try await transport.publishTaskNotifications(snapshot)
    let requests = currentRecords.all()
    guard requests.map({ $0.url!.path }) == ["/health", "/v2/notification-owner", "/v2/events"],
          requests.last?.httpMethod == "POST", let body = requests.last?.httpBody else { throw TaskPublishFailure(message: "real transport used wrong handover wire") }
    let envelope = try JSONDecoder().decode(RelayPublishRequest.self, from: body)
    let batch = try JSONDecoder().decode(RelayTaskBatch.self, from: envelope.payload)
    guard envelope.kind == "task.batch.v1", batch.publisherID == snapshot.publisherID, batch.revision == snapshot.revision,
          try await transport.taskNotificationContext().owner?.revision == snapshot.revision else { throw TaskPublishFailure(message: "task batch wire or monotonic cached owner incorrect") }
    var foreign = snapshot; foreign.publisherID = UUID()
    do { try await transport.publishTaskNotifications(foreign); throw TaskPublishFailure(message: "wire transport accepted foreign owner") }
    catch SyncTransportError.sendFailed(reason: "notificationOwnerMismatch") {}
    guard currentRecords.all().count == 3 else { throw TaskPublishFailure(message: "foreign owner reached HTTP or context cache failed") }
    let receipt = Date(timeIntervalSince1970: 100)
    let event = RelayEvent(sequence: 50, kind: "task.batch.v1", payload: envelope.payload, createdAt: receipt)
    guard let decoded = RelaySyncTransport.taskObservation(event: event), decoded.publishedAt == receipt,
          decoded.batch.revision == snapshot.revision else { throw TaskPublishFailure(message: "task observation lost receipt time or revision") }
    var older = decoded; older.batch.revision -= 1; older.sequence += 1
    guard !older.supersedes(decoded) else { throw TaskPublishFailure(message: "newer transport cursor must not authorize stale task revision") }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let page = try encoder.encode(RelayEventPage(snapshot: nil, events: [event], latestSequence: 50))
    TaskRelayWireFixture.shared.set { _ in (200, page) }
    let phone = RelaySyncTransport(baseURL: URL(string: "https://array-task-fixture.invalid")!, bearerToken: "offline", deviceLabel: "phone", session: session, apiVersion: .hardenedV2)
    let received = Task { () -> CompanionTaskObservation? in
        for await item in phone.taskObservations { return item }
        return nil
    }
    phone.start()
    let deadline = Task { try? await Task.sleep(for: .seconds(2)); phone.stop() }
    let delivered = await received.value
    deadline.cancel()
    phone.stop()
    guard delivered == decoded else { throw TaskPublishFailure(message: "real phone poll did not deliver task batch observation") }
    print("Companion relay transport checks passed: real health capability/owner handshake, authenticated task batch wire, cached revision and foreign owner fencing; URLProtocol only")
}
