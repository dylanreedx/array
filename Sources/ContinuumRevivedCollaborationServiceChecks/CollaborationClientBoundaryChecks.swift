import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

private struct BoundaryFailure: Error { let message: String }
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private final class FixtureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let counter: RequestCounter
    let status: Int
    let bytes: Data
    let location: String?
    init(counter: RequestCounter, status: Int, bytes: Data, location: String?) {
        self.counter = counter; self.status = status; self.bytes = bytes; self.location = location
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: counter.increment()
        case .end:
            var headers = HTTPHeaders([("content-type", "application/json"), ("content-length", String(bytes.count)), ("connection", "close")])
            if let location { headers.add(name: "location", value: location) }
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .init(statusCode: status), headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        default: break
        }
    }
}
private final class BoundaryServer: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let counter = RequestCounter()
    var channel: Channel?
    func start(status: Int = 200, bytes: Data, location: String? = nil) async throws -> URL {
        let counter = counter
        channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixtureHandler(counter: counter, status: status, bytes: bytes, location: location))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        return URL(string: "http://127.0.0.1:\(channel!.localAddress!.port!)")!
    }
    func stop() async { try? await channel?.close().get(); try? await group.shutdownGracefully() }
}
private func unavailableSession(api: CollaborationAPI, area: UUID, initial: Collaboration.State? = nil) async throws {
    let session = try CollaborationSession(api: api, area: area, initial: initial)
    let stream = await session.start()
    let observer = Task { for await _ in stream {} }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while true {
        if case .unavailable = await session.status { break }
        guard ContinuousClock.now < deadline else {
            await session.stop(); _ = await observer.value
            throw BoundaryFailure(message: "incompatible data was retried as a network failure")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    _ = await observer.value
    await session.stop()
}
func runCollaborationClientBoundaryChecks() async throws {
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    let target = BoundaryServer()
    let targetURL = try await target.start(bytes: JSONEncoder().encode(identity))
    let origin = BoundaryServer()
    let originURL = try await origin.start(status: 302, bytes: Data(), location: targetURL.appendingPathComponent("captured").absoluteString)
    do {
        let api = try CollaborationAPI(baseURL: originURL, credential: "fixture-credential-sentinel", allowsInsecureLoopback: true)
        do { _ = try await api.identity(); throw BoundaryFailure(message: "redirect escaped the configured service endpoint") }
        catch CollaborationClientError.server(status: 302, code: _) {}
        guard target.counter.count == 0 else { throw BoundaryFailure(message: "redirect target received a request") }
        print("PASS client boundary: service redirects deliver zero requests/credentials to the target")
        await origin.stop(); await target.stop()
    } catch { await origin.stop(); await target.stop(); throw error }

    let document = SharedArea.Document()
    let state = Collaboration.State(scope: .init(area: document.id, epoch: 1, role: .editor), document: document)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
    var futureDocument = json["document"] as! [String: Any]; futureDocument["schema"] = 2; json["document"] = futureDocument
    let future = BoundaryServer()
    let futureURL = try await future.start(bytes: JSONSerialization.data(withJSONObject: json))
    do {
        let api = try CollaborationAPI(baseURL: futureURL, credential: "fixture", allowsInsecureLoopback: true)
        try await unavailableSession(api: api, area: document.id.rawValue)
        guard future.counter.count == 1 else { throw BoundaryFailure(message: "future schema was repeatedly requested") }
        print("PASS client boundary: future-schema snapshot terminates without a retry loop")
        await future.stop()
    } catch { await future.stop(); throw error }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let page = Collaboration.Updates(scope: state.scope, after: 0, through: 1,
        events: [.init(revision: 1, actor: identity, command: .init(schema: 2, area: document.id, expectedRevision: 0, edits: []))],
        nextCursor: 1, presenceVersion: UUID(), presence: [], serverTime: Date())
    let incompatible = BoundaryServer()
    let incompatibleURL = try await incompatible.start(bytes: encoder.encode(page))
    do {
        let api = try CollaborationAPI(baseURL: incompatibleURL, credential: "fixture", allowsInsecureLoopback: true)
        try await unavailableSession(api: api, area: document.id.rawValue, initial: state)
        guard incompatible.counter.count == 1 else { throw BoundaryFailure(message: "incompatible command was repeatedly requested") }
        print("PASS client boundary: incompatible accepted command terminates without retaining stale authority")
        await incompatible.stop()
    } catch { await incompatible.stop(); throw error }
}
