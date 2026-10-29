import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO
import ContinuumRevivedRelayProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct IntegrationFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw IntegrationFailure(description: message) }
}

// Read the early 413 directly: URLSession can discard that response when it is
// still uploading a body to a connection the server has already closed.
private func oversizedIngressResponse(port: Int, chunked: Bool) throws -> String {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let sendFlags: Int32 = 0
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
    guard fd >= 0 else { throw IntegrationFailure(description: "ingress probe socket") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try require(connected == 0, "ingress probe connect")
    func writeBytes(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, sendFlags)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }
    let framing = chunked ? "Transfer-Encoding: chunked" : "Content-Length: 25165825"
    try require(writeBytes(Data("POST /v2/events HTTP/1.1\r\nHost: localhost\r\n\(framing)\r\n\r\n".utf8)), "ingress probe header")
    if chunked {
        var chunk = Data("10000\r\n".utf8)
        chunk.append(Data(repeating: 32, count: 65536)); chunk.append(Data("\r\n".utf8))
        for _ in 0..<385 { if !writeBytes(chunk) { break } }
    }
    var bytes = [UInt8](repeating: 0, count: 4096)
    let received = recv(fd, &bytes, bytes.count, 0)
    try require(received > 0, "ingress probe must receive early response")
    return String(decoding: bytes.prefix(received), as: UTF8.self)
}

private actor RecordingAPNs: RelayAPNSTransport {
    var requests: [RelayAPNSRequest] = []
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        requests.append(request)
        return .init(statusCode: 200)
    }
    func count() -> Int { requests.count }
}

private func nextTrace(_ stream: AsyncStream<RelayNotificationTrace>) async throws -> RelayNotificationTrace {
    try await withThrowingTaskGroup(of: RelayNotificationTrace.self) { group in
        group.addTask {
            for await trace in stream { return trace }
            throw IntegrationFailure(description: "notification trace ended")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw IntegrationFailure(description: "notification pipeline timed out")
        }
        defer { group.cancelAll() }
        guard let trace = try await group.next() else { throw IntegrationFailure(description: "no notification trace") }
        return trace
    }
}

func runRelayHTTPNotificationChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-relay-integration-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RelayStore(path: directory.appendingPathComponent("db.sqlite").path, masterKey: Data(repeating: 9, count: 32))
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let desktop = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Integration Mac"))
    let auth = try await store.authenticate(desktop.credential)
    let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Integration phone")
    let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Integration phone"))
    let phoneAuth = try await store.authenticate(phone.credential)
    try await store.savePushToken(auth: phoneAuth, kind: .apns, token: Data("fixture-only-token".utf8))
    let transport = RecordingAPNs()
    let traces = AsyncStream<RelayNotificationTrace>.makeStream(bufferingPolicy: .bufferingNewest(16))
    defer { traces.continuation.finish() }
    let delivery = try RelayAPNSService(store: store,
        configuration: .init(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
        transport: transport, trace: { _ = traces.continuation.yield($0) })
    let server = RelayServer(store: store, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), pushDelivery: delivery)
    try await server.start()
    do {
        guard let port = server.listeningPublicPort else { throw IntegrationFailure(description: "no bound public port") }
        func request(_ method: String, _ route: String, body: Data? = nil) async throws -> Int {
            let url = URL(string: "http://127.0.0.1:\(port)\(route)")!
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 30
            request.setValue("Bearer \(desktop.credential)", forHTTPHeaderField: "authorization")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        func publish(_ fields: [String: Any]) async throws {
            let payload = try JSONSerialization.data(withJSONObject: ["activity": ["event": fields]])
            let body = try JSONEncoder().encode(RelayPublishRequest(kind: "sync.message", payload: payload))
            try require(try await request("POST", "/v2/events", body: body) == 201, "HTTP publish must persist event")
        }
        let event: [String: Any] = ["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded", "sequence": 1]
        try await publish(event)
        let first = try await nextTrace(traces.stream)
        try require(first.path == .completion && first.outcome == .acceptedByApple && first.eventSequence == 1,
                    "HTTP publication must reach mapped notification delivery")
        try require(await transport.count() == 1, "one pipeline event must produce one fake APNs request")
        try await publish(event)
        let duplicate = try await nextTrace(traces.stream)
        try require(duplicate.path == .completion && duplicate.outcome == .deduplicated && duplicate.eventSequence == 2,
                    "HTTP republish must deduplicate source identity despite new relay sequence")
        try require(await transport.count() == 1, "republish must not reach APNs again")
        try require(try await request("DELETE", "/v2/devices/\(phoneAuth.credentialID.uuidString)") == 200,
                    "HTTP device revoke must succeed")
        try await publish(["agentId": UUID().uuidString, "status": "done", "terminalOutcome": "succeeded", "sequence": 2])
        let revoked = try await nextTrace(traces.stream)
        try require(revoked.outcome == .noRecipients && revoked.eventSequence == 3,
                    "HTTP revocation must prevent a distinct later alert")
        try require(await transport.count() == 1, "revoked phone must receive no later requests")
        // A populated Mac exceeds the former 512 KiB ceiling. Exercise the
        // public HTTP route and the exact replay page a fresh phone consumes.
        let spatial = Data(repeating: 65, count: 1024 * 1024)
        let spatialBody = try JSONEncoder().encode(RelayPublishRequest(kind: "sync.message", payload: spatial, isSnapshot: true))
        try require(try await request("POST", "/v2/events", body: spatialBody) == 201,
                    "populated Mac spatial snapshot above 512 KiB must publish")
        let replayGrant = try await store.createPairingGrant(auth: auth, deviceLabel: "Replay phone")
        let replayPhone = try await store.exchangePairingGrant(.init(code: replayGrant.code, deviceLabel: "Replay phone"))
        var replayRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/events?cursor=0")!)
        replayRequest.setValue("Bearer \(replayPhone.credential)", forHTTPHeaderField: "authorization")
        replayRequest.timeoutInterval = 30
        let (replayData, replayResponse) = try await URLSession.shared.data(for: replayRequest)
        try require((replayResponse as? HTTPURLResponse)?.statusCode == 200, "active paired phone replay must authenticate")
        let replayDecoder = JSONDecoder(); replayDecoder.dateDecodingStrategy = .iso8601
        let bootstrap = try replayDecoder.decode(RelayEventPage.self, from: replayData)
        try require(bootstrap.snapshot?.payload == spatial,
                    "paired phone must retrieve the accepted large bootstrap through HTTP replay")
        // Slash-heavy base64 exercises Foundation's worst-case JSON escaping.
        let maximum = Data(repeating: 255, count: 8 * 1024 * 1024)
        for _ in 0..<3 {
            let body = try JSONEncoder().encode(RelayPublishRequest(kind: "fixture", payload: maximum))
            try require(try await request("POST", "/v2/events", body: body) == 201,
                        "decoded payload at 8 MiB ceiling must publish")
        }
        let page = try await store.events(auth: phoneAuth, after: 0)
        try require(page.snapshot?.payload == spatial && page.events.count == 2 &&
                    page.events.reduce(0, { $0 + $1.payload.count }) == 16 * 1024 * 1024,
                    "fresh phone retains spatial bootstrap and newest events within 16 MiB tail")
        let oversized = try JSONEncoder().encode(RelayPublishRequest(kind: "fixture", payload: Data(repeating: 67, count: maximum.count + 1)))
        try require(try await request("POST", "/v2/events", body: oversized) == 413,
                    "decoded payload above 8 MiB must be explicitly rejected")
        let unchanged = try await store.events(auth: phoneAuth, after: 0)
        try require(unchanged.latestSequence == page.latestSequence, "rejected payload must not advance replay cursor")
        for chunked in [false, true] {
            try require(try oversizedIngressResponse(port: port, chunked: chunked).hasPrefix("HTTP/1.1 413"),
                        "declared and chunked HTTP ingress above 24 MiB must reject before decoding")
        }
        try require(try await request("GET", "/health") == 200, "relay remains healthy after oversized ingress")
        try await store.savePushToken(auth: try await store.authenticate(replayPhone.credential), kind: .apns, token: Data("task-fixture-token".utf8))
        try await runHTTPTaskPolicyChecks(port: port, credential: desktop.credential, transport: transport, traces: traces.stream)
        var ownerRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/notification-owner")!)
        ownerRequest.setValue("Bearer \(desktop.credential)", forHTTPHeaderField: "authorization")
        let (ownerData, ownerResponse) = try await URLSession.shared.data(for: ownerRequest)
        let owner = try JSONDecoder().decode(RelayNotificationOwnershipResponse.self, from: ownerData)
        try require((ownerResponse as? HTTPURLResponse)?.statusCode == 200 && owner.owner?.revision == 4,
                    "desktop owner HTTP endpoint must return committed publisher revision")
        ownerRequest.setValue("Bearer \(replayPhone.credential)", forHTTPHeaderField: "authorization")
        let (_, deniedOwner) = try await URLSession.shared.data(for: ownerRequest)
        try require((deniedOwner as? HTTPURLResponse)?.statusCode == 403, "companion must not inspect/claim host ownership")
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
    print("Relay HTTP notification checks passed: delivery, dedup, revoke, large Mac bootstrap, 8 MiB decoded/24 MiB ingress bounds, 16 MiB replay tail; fake APNs only")
}

@inline(never)
private func runHTTPTaskPolicyChecks(port: Int, credential: String, transport: RecordingAPNs, traces: AsyncStream<RelayNotificationTrace>) async throws {
    func publishRequest(_ body: Data) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/events")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
    let taskID = UUID(), rootRun = UUID(), childRun = UUID(), taskRoot = UUID(), taskChild = UUID()
    let publisherID = UUID()
    var revision: UInt64 = 1
    let baseline = try JSONEncoder().encode(RelayPublishRequest(kind: "task.batch.v1", payload: JSONEncoder().encode(RelayTaskBatch(publisherID: publisherID, revision: revision, tasks: []))))
    try require(try await publishRequest(baseline) == 201, "task owner baseline must commit")
    func publishTask(child: RelayTaskState.State) async throws -> RelayNotificationTrace {
        let value = RelayTaskState(taskID: taskID, rootRunID: rootRun, membershipComplete: true, members: [
            .init(agentID: taskRoot, runID: rootRun, state: .succeeded),
            .init(agentID: taskChild, runID: childRun, parentRunID: rootRun, state: child),
        ])
        revision += 1
        let batch = RelayTaskBatch(publisherID: publisherID, revision: revision, tasks: [value])
        let body = try JSONEncoder().encode(RelayPublishRequest(kind: "task.batch.v1", payload: try JSONEncoder().encode(batch)))
        try require(try await publishRequest(body) == 201, "HTTP task publication must persist")
        // Discard bounded fixture traces from preceding payload-limit checks.
        for _ in 0..<32 {
            let trace = try await nextTrace(traces)
            if trace.path.rawValue.hasPrefix("T-") { return trace }
        }
        throw IntegrationFailure(description: "no task decision trace")
    }
    let blocked = try await publishTask(child: .running)
    let blockedCount = await transport.count()
    try require(blocked.path == .taskActive && blocked.outcome == .suppressed && blockedCount == 1,
                "HTTP parent completion while child runs must produce no alert")
    let settled = try await publishTask(child: .succeeded)
    let settledCount = await transport.count()
    try require(settled.path == .taskCompletion && settled.outcome == .acceptedByApple && settledCount == 2,
                "HTTP task settlement must send exactly one root completion")
    let replayed = try await publishTask(child: .succeeded)
    let replayedCount = await transport.count()
    try require(replayed.outcome == .deduplicated && replayedCount == 2,
                "HTTP task snapshot replay must not send another completion")
}
