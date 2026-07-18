import Foundation
import Darwin
import ContinuumRevivedCore

// Ticket: docs/38-tickets/86-relay-sync-transport.md (slice 2, milestone A)
//
// HTTP long-poll adapter over `RelayHub` — raw BSD sockets on a
// DispatchSource accept loop, the same idioms `LocalPairingEndpointListener`
// (ticket 81) proves on this codebase. One request per connection
// (`Connection: close`); a long-poll holds its connection for up to the
// bounded wait. Thread/connection counts are a non-issue at this hub's
// scale (a desktop and a phone).
//
// Surface (bearer token rides the Authorization header, never a body):
//   GET  /v1/health                          → RelayHealthResponse
//   POST /v1/hello    RelayHelloRequestBody  → RelayHelloResponse
//   GET  /v1/poll?after=N&max=M&waitMs=W     → RelayPollResponse
//   POST /v1/publish  SyncMessage            → RelayPublishResponse
//   POST /v1/tokens   RelayRegisterToken…    → 204 (operator only)
// Refusals are RelayErrorBody with a machine-readable `code` mirroring the
// hub's thrown case: 401 unauthorized, 403 scopeForbidsPublish,
// 409 cursorUnrecoverable, 422 taintViolation, 426 unsupportedProtocolVersion.

/// Token → grant store the hub's validator closes over. Seeded at boot
/// (dev tokens / the Mac's operator token) and extended at runtime via
/// `POST /v1/tokens` when the Mac registers a phone's pairing token.
/// In-memory only today; persistence is a slice-3 (VPS) concern.
public actor RelayTokenRegistry {
    private var grants: [String: RelayGrant]

    public init(seed: [String: RelayGrant] = [:]) {
        self.grants = seed
    }

    public func grant(for token: String) -> RelayGrant? {
        grants[token]
    }

    public func register(token: String, grant: RelayGrant) {
        grants[token] = grant
    }

    public var count: Int { grants.count }
}

public enum RelayHTTPServerError: Error, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case getsocknameFailed(Int32)
    case invalidIPv4Host(String)
    case alreadyStarted
}

public final class RelayHTTPServer: @unchecked Sendable {
    // @unchecked: mutable state is confined behind `lock` (start/stop) or
    // written once in start(); hub/registry are actors.
    private let hub: RelayHub
    private let registry: RelayTokenRegistry
    private let bindHost: String
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "continuum.relay-http-listener")
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var stopped = false
    /// The bound port, valid after `start()` (differs from the requested
    /// port when 0 = ephemeral was asked for).
    public private(set) var port: UInt16 = 0

    public init(hub: RelayHub, registry: RelayTokenRegistry, bindHost: String = "127.0.0.1", port: UInt16 = 0) {
        self.hub = hub
        self.registry = registry
        self.bindHost = bindHost
        self.requestedPort = port
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil, !stopped else { throw RelayHTTPServerError.alreadyStarted }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayHTTPServerError.socketFailed(errno) }
        var shouldCloseFD = true
        defer {
            if shouldCloseFD { close(fd) }
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = requestedPort.bigEndian
        guard inet_pton(AF_INET, bindHost, &bindAddress.sin_addr) == 1 else {
            throw RelayHTTPServerError.invalidIPv4Host(bindHost)
        }
        let bindStatus = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else { throw RelayHTTPServerError.bindFailed(errno) }
        guard listen(fd, SOMAXCONN) == 0 else { throw RelayHTTPServerError.listenFailed(errno) }

        var actualAddress = sockaddr_in()
        var actualAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &actualAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &actualAddressLength)
            }
        }
        guard nameStatus == 0 else { throw RelayHTTPServerError.getsocknameFailed(errno) }
        port = UInt16(bigEndian: actualAddress.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOneConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        socketFD = fd
        self.source = source
        shouldCloseFD = false
        source.resume()
    }

    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let source = source
        lock.unlock()
        source?.cancel()
    }

    private func acceptOneConnection() {
        lock.lock()
        let isStopped = stopped
        let fd = socketFD
        lock.unlock()
        guard !isStopped else { return }

        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                accept(fd, sockaddrPointer, &length)
            }
        }
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let hub = hub
        let registry = registry
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                let response: Response
                do {
                    let request = try Self.readRequest(from: clientFD)
                    response = await Self.route(request, hub: hub, registry: registry)
                } catch {
                    response = Self.json(400, RelayErrorBody(code: "invalidRequest"))
                }
                Self.write(response, to: clientFD)
                close(clientFD)
            }
        }
    }

    // MARK: Request / response plumbing

    private struct ParsedRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private struct Response {
        var statusCode: Int
        var body: Data
        var contentType: String?
    }

    private enum RequestError: Error {
        case malformed(String)
    }

    private static func readRequest(from fd: Int32) throws -> ParsedRequest {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        var headerRange: Range<Data.Index>?
        var buffer = [UInt8](repeating: 0, count: 4096)
        while headerRange == nil, data.count <= 16_384 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            headerRange = data.range(of: delimiter)
        }
        guard let headerRange else { throw RequestError.malformed("headers") }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw RequestError.malformed("header-encoding")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw RequestError.malformed("request-line") }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { throw RequestError.malformed("request-line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0, contentLength <= 1024 * 1024 else {
            throw RequestError.malformed("content-length")
        }

        let bodyStart = headerRange.upperBound
        var body = Data(data[bodyStart...])
        while body.count < contentLength {
            let count = recv(fd, &buffer, min(buffer.count, contentLength - body.count), 0)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        guard body.count >= contentLength else { throw RequestError.malformed("short-body") }
        if body.count > contentLength {
            body = Data(body.prefix(contentLength))
        }
        return ParsedRequest(method: requestParts[0], path: requestParts[1], headers: headers, body: body)
    }

    private static func write(_ response: Response, to fd: Int32) {
        var headerText = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        headerText += "Content-Length: \(response.body.count)\r\n"
        headerText += "Connection: close\r\n"
        if let contentType = response.contentType {
            headerText += "Content-Type: \(contentType)\r\n"
        }
        headerText += "\r\n"
        writeAll(Data(headerText.utf8), to: fd)
        writeAll(response.body, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let result = send(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                if result <= 0 { break }
                sent += result
            }
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 426: return "Upgrade Required"
        default: return "Error"
        }
    }

    // MARK: Routing

    private static func route(_ request: ParsedRequest, hub: RelayHub, registry: RelayTokenRegistry) async -> Response {
        let (path, query) = splitQuery(request.path)
        switch (request.method, path) {
        case ("GET", "/v1/health"):
            let latest = await hub.latestSeq
            let subscribers = await hub.subscriberCount
            return json(200, RelayHealthResponse(latestSeq: latest, subscribers: subscribers))

        case ("POST", "/v1/hello"):
            guard let token = bearerToken(request) else { return unauthorized() }
            guard let body = try? JSONDecoder().decode(RelayHelloRequestBody.self, from: request.body) else {
                return json(400, RelayErrorBody(code: "invalidBody"))
            }
            guard body.protocolVersion == RelayProtocol.version else {
                return json(426, RelayErrorBody(code: "unsupportedProtocolVersion"))
            }
            do {
                let latest = try await hub.validateCursor(token: token, afterSeq: body.cursor ?? 0)
                return json(200, RelayHelloResponse(sessionId: UUID(), latestSeq: latest))
            } catch {
                return refusal(error)
            }

        case ("GET", "/v1/poll"):
            guard let token = bearerToken(request) else { return unauthorized() }
            let after = UInt64(query["after"] ?? "") ?? 0
            let maxCount = min(Int(query["max"] ?? "") ?? 256, 1024)
            let waitMs = min(UInt64(query["waitMs"] ?? "") ?? 25_000, 30_000)
            do {
                let envelopes = try await pollBounded(hub: hub, token: token, after: after, maxCount: maxCount, waitMs: waitMs)
                let latest = await hub.latestSeq
                return json(200, RelayPollResponse(envelopes: envelopes, latestSeq: latest))
            } catch {
                return refusal(error)
            }

        case ("POST", "/v1/publish"):
            guard let token = bearerToken(request) else { return unauthorized() }
            guard let message = try? JSONDecoder().decode(SyncMessage.self, from: request.body) else {
                return json(400, RelayErrorBody(code: "invalidBody"))
            }
            do {
                let seq = try await hub.publish(token: token, message: message)
                return json(200, RelayPublishResponse(seq: seq))
            } catch {
                return refusal(error)
            }

        case ("POST", "/v1/tokens"):
            guard let token = bearerToken(request) else { return unauthorized() }
            guard let grant = await registry.grant(for: token), grant.canPublish else {
                return json(403, RelayErrorBody(code: "scopeForbidsPublish"))
            }
            guard let body = try? JSONDecoder().decode(RelayRegisterTokenRequestBody.self, from: request.body) else {
                return json(400, RelayErrorBody(code: "invalidBody"))
            }
            await registry.register(token: body.token, grant: RelayGrant(scopes: Scope(rawValue: body.scopeRawValue)))
            return Response(statusCode: 204, body: Data(), contentType: nil)

        default:
            return json(404, RelayErrorBody(code: "notFound"))
        }
    }

    /// The lossless backlog after `after`, waiting at most `waitMs` for the
    /// first envelope. Timeout → one final non-suspending peek (closes the
    /// missed-wakeup window), then an empty batch.
    private static func pollBounded(hub: RelayHub, token: String, after: UInt64, maxCount: Int, waitMs: UInt64) async throws -> [RelayEnvelope] {
        if waitMs == 0 {
            return try await peek(hub: hub, token: token, after: after, maxCount: maxCount)
        }
        let raced: [RelayEnvelope]? = try await withThrowingTaskGroup(of: [RelayEnvelope]?.self) { group in
            group.addTask {
                try await hub.pollEnvelopes(token: token, afterSeq: after, maxCount: maxCount)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: waitMs * 1_000_000)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        if let raced {
            return raced
        }
        return try await peek(hub: hub, token: token, after: after, maxCount: maxCount)
    }

    /// Non-suspending backlog fetch: validates first, then pulls only when
    /// the hub provably has envelopes past the cursor (so `pollEnvelopes`
    /// cannot suspend).
    private static func peek(hub: RelayHub, token: String, after: UInt64, maxCount: Int) async throws -> [RelayEnvelope] {
        let latest = try await hub.validateCursor(token: token, afterSeq: after)
        guard latest > after else { return [] }
        return try await hub.pollEnvelopes(token: token, afterSeq: after, maxCount: maxCount)
    }

    // MARK: Helpers

    private static func bearerToken(_ request: ParsedRequest) -> String? {
        guard let header = request.headers["authorization"] else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    private static func splitQuery(_ rawPath: String) -> (path: String, query: [String: String]) {
        let pieces = rawPath.split(separator: "?", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return (rawPath, [:]) }
        var query: [String: String] = [:]
        for pair in pieces[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { query[kv[0]] = kv[1] }
        }
        return (pieces[0], query)
    }

    private static func unauthorized() -> Response {
        json(401, RelayErrorBody(code: "unauthorized"))
    }

    private static func refusal(_ error: Error) -> Response {
        switch error {
        case RelayHelloError.unauthorized, RelayPublishError.unauthorized:
            return json(401, RelayErrorBody(code: "unauthorized"))
        case RelayHelloError.unsupportedProtocolVersion:
            return json(426, RelayErrorBody(code: "unsupportedProtocolVersion"))
        case RelayHelloError.cursorUnrecoverable(let cursor, let ringStart):
            return json(409, RelayErrorBody(code: "cursorUnrecoverable", cursor: cursor, ringStart: ringStart))
        case RelayPublishError.scopeForbidsPublish:
            return json(403, RelayErrorBody(code: "scopeForbidsPublish"))
        case RelayPublishError.taintViolation(let patterns):
            return json(422, RelayErrorBody(code: "taintViolation", patterns: patterns))
        case RelayPublishError.encodingFailed:
            return json(400, RelayErrorBody(code: "encodingFailed"))
        default:
            return json(500, RelayErrorBody(code: "internalError"))
        }
    }

    private static func json(_ statusCode: Int, _ body: some Encodable) -> Response {
        let data = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
        return Response(statusCode: statusCode, body: data, contentType: "application/json")
    }
}
