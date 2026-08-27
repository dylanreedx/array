import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

public struct RelayServerConfiguration: Sendable {
    public var host: String; public var publicPort: Int; public var adminPort: Int
    public init(host: String = "0.0.0.0", publicPort: Int = 8080, adminPort: Int = 9090) {
        self.host = host; self.publicPort = publicPort; self.adminPort = adminPort
    }
}

public final class RelayServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let store: RelayStore
    private let configuration: RelayServerConfiguration
    private let liveHub = RelayLiveHub()
    private let pushDelivery: (any RelayEventPushDelivering)?
    private var channels: [Channel] = []

    public init(store: RelayStore, configuration: RelayServerConfiguration = .init(), pushDelivery: (any RelayEventPushDelivering)? = nil) {
        self.store = store; self.configuration = configuration
        self.pushDelivery = pushDelivery
        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() async throws {
        let publicChannel = try await bootstrap(admin: false, port: configuration.publicPort).get()
        do {
            let adminChannel = try await bootstrap(admin: true, port: configuration.adminPort).get()
            channels = [publicChannel, adminChannel]
        } catch {
            try? await publicChannel.close().get(); throw error
        }
    }

    public func stop() async throws {
        for channel in channels { try? await channel.close().get() }
        channels.removeAll()
        try await group.shutdownGracefully()
    }

    public func wait() async throws {
        guard let first = channels.first else { return }
        try await first.closeFuture.get()
    }

    private func bootstrap(admin: Bool, port: Int) -> EventLoopFuture<Channel> {
        let store = store
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                if admin {
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(RelayHTTPHandler(store: store, liveHub: self.liveHub, pushDelivery: self.pushDelivery, admin: true), name: "relay-admin-http")
                    }
                }
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        guard head.uri == "/v2/socket" else { return channel.eventLoop.makeSucceededFuture(nil) }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.removeHandler(name: "relay-public-http").flatMap {
                            channel.pipeline.addHandler(RelayWebSocketHandler(store: store, liveHub: self.liveHub, pushDelivery: self.pushDelivery))
                        }
                    }
                )
                let config = NIOHTTPServerUpgradeConfiguration(upgraders: [upgrader]) { _ in }
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(RelayHTTPHandler(store: store, liveHub: self.liveHub, pushDelivery: self.pushDelivery, admin: false), name: "relay-public-http")
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: configuration.host, port: port)
    }
}

private final class RelayHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let store: RelayStore; private let admin: Bool
    private let pushDelivery: (any RelayEventPushDelivering)?
    private let liveHub: RelayLiveHub
    private var head: HTTPRequestHead?; private var body = ByteBuffer()
    init(store: RelayStore, liveHub: RelayLiveHub, pushDelivery: (any RelayEventPushDelivering)?, admin: Bool) { self.store = store; self.liveHub = liveHub; self.pushDelivery = pushDelivery; self.admin = admin }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value): head = value; body.clear()
        case .body(var chunk): body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let bytes = body.readData(length: body.readableBytes) ?? Data()
            let contextBox = SendableContext(context)
            Task { [store, liveHub, pushDelivery, admin] in
                let response = await Self.route(head: head, body: bytes, store: store, liveHub: liveHub, pushDelivery: pushDelivery, admin: admin)
                contextBox.context.eventLoop.execute { self.write(response, context: contextBox.context) }
            }
        }
    }

    private static func route(head: HTTPRequestHead, body: Data, store: RelayStore, liveHub: RelayLiveHub, pushDelivery: (any RelayEventPushDelivering)?, admin: Bool) async -> Response {
        do {
            if admin { return try await adminRoute(head: head, body: body, store: store) }
            if head.method == .GET, head.uri == "/health" { return .json(.ok, try await store.health()) }
            if head.method == .POST, head.uri == "/v2/invites/redeem" {
                return .json(.ok, try await store.redeemAlphaInvite(JSONDecoder.relay.decode(RelayInviteRedemption.self, from: body)))
            }
            if head.method == .POST, head.uri == "/v2/pairing/exchange" {
                return .json(.ok, try await store.exchangePairingGrant(JSONDecoder.relay.decode(RelayPairingExchange.self, from: body)))
            }
            guard let token = bearer(head), let auth = try? await store.authenticate(token) else { return .error(.unauthorized, "unauthorized") }
            if head.method == .POST, head.uri == "/v2/pairing-grants" {
                let value = try JSONDecoder.relay.decode(RelayPairingGrantRequest.self, from: body)
                return .json(.created, try await store.createPairingGrant(auth: auth, deviceLabel: value.deviceLabel))
            }
            if head.method == .DELETE, head.uri.hasPrefix("/v2/pairing-grants/"), let id = UUID(uuidString: String(head.uri.dropFirst("/v2/pairing-grants/".count))) {
                try await store.cancelPairingGrant(auth: auth, id: id)
                return .json(.ok, RelayPairingCancellationResponse(id: id, cancelled: true))
            }
            if head.method == .GET, head.uri == "/v2/devices" { return .json(.ok, try await store.devices(auth: auth)) }
            if head.method == .DELETE, head.uri.hasPrefix("/v2/devices/"), let id = UUID(uuidString: String(head.uri.dropFirst("/v2/devices/".count))) {
                try await store.revokeCredential(auth: auth, credentialID: id); await liveHub.disconnect(credentialID: id); return .json(.ok, RelayErrorResponse(code: "revoked"))
            }
            if head.method == .POST, head.uri == "/v2/events" {
                let event = try await store.publish(auth: auth, request: JSONDecoder.relay.decode(RelayPublishRequest.self, from: body)); await liveHub.publish(event, instanceID: auth.instanceID); if let pushDelivery { Task { await pushDelivery.deliver(event: event, instanceID: auth.instanceID) } }; return .json(.created, event)
            }
            if head.method == .GET, head.uri.hasPrefix("/v2/events") {
                let cursor = URLComponents(string: "http://relay\(head.uri)")?.queryItems?.first(where: { $0.name == "cursor" })?.value.flatMap(Int64.init) ?? 0
                return .json(.ok, try await store.events(auth: auth, after: cursor))
            }
            if head.method == .POST, head.uri == "/v2/commands" {
                return .json(.ok, try await store.acceptCommand(auth: auth, request: JSONDecoder.relay.decode(RelayCommandRequest.self, from: body)))
            }
            if head.method == .POST, head.uri == "/v2/push-registrations" {
                let registration = try JSONDecoder.relay.decode(RelayPushRegistrationRequest.self, from: body)
                try await store.savePushToken(auth: auth, kind: registration.kind, token: registration.token)
                return .json(.ok, RelayPushRegistrationResponse(kind: registration.kind, registered: true))
            }
            if head.method == .DELETE, head.uri.hasPrefix("/v2/push-registrations/"), let kind = RelayPushRegistrationKind(rawValue: String(head.uri.dropFirst("/v2/push-registrations/".count))) {
                try await store.removePushToken(auth: auth, kind: kind)
                return .json(.ok, RelayPushRegistrationResponse(kind: kind, registered: false))
            }
            return .error(.notFound, "notFound")
        } catch RelayStoreError.forbidden { return .error(.forbidden, "forbidden") }
        catch RelayStoreError.invalidOrExpiredCode { return .error(.gone, "invalidOrExpiredCode") }
        catch RelayStoreError.payloadTooLarge { return .error(.payloadTooLarge, "payloadTooLarge") }
        catch {
            // Error values may contain SQL or request data; log only their static type.
            let line = "{\"event\":\"request_failed\",\"error_type\":\"\(String(describing: type(of: error)))\"}\n"
            FileHandle.standardError.write(Data(line.utf8))
            return .error(.badRequest, "invalidRequest")
        }
    }

    private static func adminRoute(head: HTTPRequestHead, body: Data, store: RelayStore) async throws -> Response {
        if head.method == .GET, head.uri == "/health" { return .json(.ok, try await store.health()) }
        if head.method == .GET, head.uri == "/" {
            let csrf = UUID().uuidString
            let instances = try await store.adminOverview()
            let rows: String = instances.map { instance -> String in
                let deviceRows: String = instance.devices.map { device -> String in "<li>\(escape(device.label)) — last seen \(escape(device.lastSeenAt.map(String.init(describing:)) ?? "never")) <form method=post action=/devices/\(device.id)/revoke><input type=hidden name=csrf value=\"\(csrf)\"><button>Revoke device</button></form></li>" }.joined()
                return "<section><h2>\(escape(instance.label))</h2><code>\(instance.id)</code><p>\(instance.revokedAt == nil ? "active" : "revoked")</p><ul>\(deviceRows)</ul><form method=post action=/instances/\(instance.id)/revoke><input type=hidden name=csrf value=\"\(csrf)\"><button>Revoke instance</button></form></section>"
            }.joined()
            let base: String = #"<!doctype html><meta charset=utf-8><title>Array Relay Admin</title><h1>Array Relay Admin</h1><form method=post action=/invites><input type=hidden name=csrf value="\#(csrf)"><label>Lifetime hours <input name=hours value=24></label><button>Create invite</button></form>"#
            let html = base + rows
            return Response(status: .ok, contentType: "text/html; charset=utf-8", body: Data(html.utf8), headers: ["set-cookie": "relay_csrf=\(csrf); Path=/; HttpOnly; SameSite=Strict"])
        }
        if head.method == .POST, head.uri == "/invites" {
            let form = String(decoding: body, as: UTF8.self)
            let fields = formFields(form); guard validCSRF(head, fields) else { return .error(.forbidden, "csrf") }
            let hours = min(max(Double(fields["hours"] ?? "24") ?? 24, 1), 168)
            let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(hours * 3600))
            return Response(status: .created, contentType: "text/plain; charset=utf-8", body: Data("Invite (shown once): \(invite.code)\nExpires: \(invite.expiresAt)\n".utf8))
        }
        if head.method == .POST, head.uri.hasSuffix("/revoke") {
            let fields = formFields(String(decoding: body, as: UTF8.self)); guard validCSRF(head, fields) else { return .error(.forbidden, "csrf") }
            let components = head.uri.split(separator: "/")
            guard components.count == 3, let id = UUID(uuidString: String(components[1])) else { return .error(.badRequest, "invalidID") }
            if components[0] == "instances" { try await store.adminRevokeInstance(id) }
            else if components[0] == "devices" { try await store.adminRevokeCredential(id) }
            else { return .error(.notFound, "notFound") }
            return Response(status: .ok, contentType: "text/plain; charset=utf-8", body: Data("revoked\n".utf8))
        }
        return .error(.notFound, "notFound")
    }

    private static func formFields(_ form: String) -> [String:String] { Dictionary(uniqueKeysWithValues: form.split(separator: "&").compactMap { pair -> (String,String)? in let parts = pair.split(separator: "=", maxSplits: 1).map(String.init); guard parts.count == 2 else { return nil }; return (parts[0], parts[1].removingPercentEncoding ?? parts[1]) }) }
    private static func validCSRF(_ head: HTTPRequestHead, _ fields: [String:String]) -> Bool { let cookie = head.headers["cookie"].first?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0.hasPrefix("relay_csrf=") })?.split(separator: "=", maxSplits: 1).last.map(String.init); return fields["csrf"] == cookie }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }

    private static func bearer(_ head: HTTPRequestHead) -> String? {
        head.headers["authorization"].first.flatMap { value in
            value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : nil
        }
    }

    private func write(_ response: Response, context: ChannelHandlerContext) {
        var headers = HTTPHeaders(); headers.add(name: "content-type", value: response.contentType); headers.add(name: "content-length", value: "\(response.body.count)"); headers.add(name: "connection", value: "close")
        for (name,value) in response.headers { headers.replaceOrAdd(name: name, value: value) }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: response.status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count); buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let contextBox = SendableContext(context)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in contextBox.context.close(promise: nil) }
    }
}

private final class RelayWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame; typealias OutboundOut = WebSocketFrame
    let store: RelayStore; let liveHub: RelayLiveHub; let pushDelivery: (any RelayEventPushDelivering)?; var auth: RelayCredentialContext?
    init(store: RelayStore, liveHub: RelayLiveHub, pushDelivery: (any RelayEventPushDelivering)?) { self.store = store; self.liveHub = liveHub; self.pushDelivery = pushDelivery }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else { return }
        var bytes = frame.unmaskedData
        guard let data = bytes.readData(length: bytes.readableBytes), let message = try? JSONDecoder.relay.decode(RelaySocketFrame.self, from: data) else { send(.error(code: "invalidFrame"), context); return }
        let contextBox = SendableContext(context)
        Task {
            do {
                switch message {
                case .authenticate(let token, let cursor):
                    let authenticated = try await store.authenticate(token); auth = authenticated
                    // Subscribe before reading replay so a publish racing the welcome
                    // frame is buffered rather than lost between replay and fanout.
                    let stream = await liveHub.subscribe(instanceID: authenticated.instanceID, credentialID: authenticated.credentialID)
                    let page = try await store.events(auth: authenticated, after: cursor ?? 0)
                    send(.welcome(instanceID: authenticated.instanceID, latestSequence: page.latestSequence, capabilities: authenticated.capabilities), contextBox.context)
                    if let snapshot = page.snapshot { send(.event(snapshot), contextBox.context) }; for event in page.events { send(.event(event), contextBox.context) }
                    Task { for await event in stream where event.sequence > page.latestSequence { self.send(.event(event), contextBox.context) } }
                case .publish(let request): guard let auth else { throw RelayStoreError.unauthorized }; let event = try await store.publish(auth: auth, request: request); await liveHub.publish(event, instanceID: auth.instanceID); if let pushDelivery { Task { await pushDelivery.deliver(event: event, instanceID: auth.instanceID) } }
                case .command(let request): guard let auth else { throw RelayStoreError.unauthorized }; send(.receipt(try await store.acceptCommand(auth: auth, request: request)), contextBox.context)
                case .ping: send(.pong, contextBox.context)
                default: break
                }
            } catch { send(.error(code: "unauthorizedOrInvalid"), contextBox.context) }
        }
    }
    private func send(_ value: RelaySocketFrame, _ context: ChannelHandlerContext) {
        guard let data = try? JSONEncoder.relay.encode(value) else { return }
        let contextBox = SendableContext(context)
        context.eventLoop.execute { var buffer = contextBox.context.channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data); contextBox.context.writeAndFlush(self.wrapOutboundOut(.init(fin: true, opcode: .text, data: buffer)), promise: nil) }
    }
}

private struct Response {
    var status: HTTPResponseStatus; var contentType: String; var body: Data; var headers: [String:String] = [:]
    static func json<T: Encodable>(_ status: HTTPResponseStatus, _ value: T) -> Self { .init(status: status, contentType: "application/json", body: (try? JSONEncoder.relay.encode(value)) ?? Data()) }
    static func error(_ status: HTTPResponseStatus, _ code: String) -> Self { .json(status, RelayErrorResponse(code: code)) }
}
private final class SendableContext: @unchecked Sendable {
    let context: ChannelHandlerContext
    init(_ context: ChannelHandlerContext) { self.context = context }
}
private actor RelayLiveHub {
    struct Subscriber { var credentialID: UUID; var continuation: AsyncStream<RelayEvent>.Continuation }
    private var subscribers: [UUID: [UUID: Subscriber]] = [:]
    func subscribe(instanceID: UUID, credentialID: UUID) -> AsyncStream<RelayEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[instanceID, default: [:]][id] = Subscriber(credentialID: credentialID, continuation: continuation)
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(instanceID: instanceID, id: id) } }
        }
    }
    func publish(_ event: RelayEvent, instanceID: UUID) {
        for (id, subscriber) in subscribers[instanceID] ?? [:] {
            if case .dropped = subscriber.continuation.yield(event) { subscriber.continuation.finish(); subscribers[instanceID]?[id] = nil }
        }
    }
    func disconnect(credentialID: UUID) {
        for instanceID in subscribers.keys {
            for (id, subscriber) in subscribers[instanceID] ?? [:] where subscriber.credentialID == credentialID { subscriber.continuation.finish(); subscribers[instanceID]?[id] = nil }
        }
    }
    private func remove(instanceID: UUID, id: UUID) { subscribers[instanceID]?[id] = nil }
}
private extension JSONEncoder { static var relay: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
private extension JSONDecoder { static var relay: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
