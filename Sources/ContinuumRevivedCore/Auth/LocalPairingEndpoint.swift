import Foundation

public struct LocalPairingExchangeRequest: Codable, Equatable, Sendable {
    public var token: String
    public var deviceLabel: String
    public var requestedScope: Int

    public init(token: String, deviceLabel: String, requestedScope: Int) {
        self.token = token
        self.deviceLabel = deviceLabel
        self.requestedScope = requestedScope
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case deviceLabel
        case deviceName
        case requestedScope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        if let label = try container.decodeIfPresent(String.self, forKey: .deviceLabel) {
            deviceLabel = label
        } else {
            deviceLabel = try container.decode(String.self, forKey: .deviceName)
        }
        requestedScope = try container.decode(Int.self, forKey: .requestedScope)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(deviceLabel, forKey: .deviceLabel)
        try container.encode(requestedScope, forKey: .requestedScope)
    }
}

public struct LocalPairingSessionResponse: Codable, Equatable, Sendable {
    public var instanceId: UUID
    public var userId: UUID
    public var deviceId: UUID
    public var sessionId: UUID
    public var token: String
    public var scopes: Scope
    public var scopeRawValue: Int
    public var issuedAt: Date
    public var expiresAt: Date

    public init(
        instanceId: UUID,
        userId: UUID,
        deviceId: UUID,
        sessionId: UUID,
        token: String,
        scopes: Scope,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.instanceId = instanceId
        self.userId = userId
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.token = token
        self.scopes = scopes
        self.scopeRawValue = scopes.rawValue
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public init(exchange: CompanionPairingExchange) {
        self.init(
            instanceId: exchange.instanceId,
            userId: exchange.userId,
            deviceId: exchange.device.id,
            sessionId: exchange.session.id,
            token: exchange.session.token,
            scopes: exchange.session.scopes,
            issuedAt: exchange.session.issuedAt,
            expiresAt: exchange.session.expiresAt
        )
    }

    public var pairedSession: PairedCompanionSession {
        PairedCompanionSession(
            instanceId: instanceId,
            userId: userId,
            deviceId: deviceId,
            sessionId: sessionId,
            token: token,
            scopes: scopes,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }
}

public struct LocalPairingEndpointStatus: Equatable, Sendable {
    public var isActive: Bool
    public var expiresAt: Date
    public var now: Date

    public init(isActive: Bool, expiresAt: Date, now: Date) {
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.now = now
    }

    public var isExpired: Bool { now >= expiresAt }
    public var acceptsRequests: Bool { isActive && !isExpired }
}

public struct LocalPairingHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public actor LocalPairingEndpoint {
    public typealias PairingExchangeHandler = @Sendable (CompanionPairingExchange) async -> Void

    private let authService: CompanionAuthService
    private let clock: any Clock
    private let expiresAt: Date
    private let acceptedCredential: String?
    private let maxBodyBytes: Int
    private let onExchangeSuccess: PairingExchangeHandler?
    private var stopped = false

    public init(
        authService: CompanionAuthService,
        expiresAt: Date,
        acceptedCredential: String? = nil,
        clock: any Clock = SystemClock(),
        maxBodyBytes: Int = 8_192,
        onExchangeSuccess: PairingExchangeHandler? = nil
    ) {
        self.authService = authService
        self.expiresAt = expiresAt
        self.acceptedCredential = acceptedCredential
        self.clock = clock
        self.maxBodyBytes = max(1, maxBodyBytes)
        self.onExchangeSuccess = onExchangeSuccess
    }

    public func status() -> LocalPairingEndpointStatus {
        LocalPairingEndpointStatus(isActive: !stopped, expiresAt: expiresAt, now: clock.now())
    }

    public func stop() {
        stopped = true
    }

    public func handle(method: String, path: String, body: Data) async -> LocalPairingHTTPResponse {
        guard !stopped else {
            return Self.jsonError(statusCode: 410, error: "pairingWindowStopped")
        }
        guard clock.now() < expiresAt else {
            stopped = true
            return Self.jsonError(statusCode: 410, error: "pairingWindowExpired")
        }
        if method == "GET", path == "/open-continuum-pairing" || path.hasPrefix("/open-continuum-pairing?") {
            return Self.openContinuumPairingResponse(path: path)
        }
        guard method == "POST" else {
            return Self.jsonError(statusCode: 405, error: "invalidMethod")
        }
        guard path == "/pair" else {
            return Self.jsonError(statusCode: 404, error: "invalidPath")
        }
        guard body.count <= maxBodyBytes else {
            return Self.jsonError(statusCode: 413, error: "bodyTooLarge")
        }

        let request: LocalPairingExchangeRequest
        do {
            request = try JSONDecoder().decode(LocalPairingExchangeRequest.self, from: body)
        } catch {
            return Self.jsonError(statusCode: 400, error: "invalidBody")
        }

        let trimmedToken = request.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return Self.jsonError(statusCode: 400, error: "invalidBody")
        }
        if let acceptedCredential,
           !authConstantTimeEqual(Data(trimmedToken.utf8), Data(acceptedCredential.utf8)) {
            return Self.jsonError(statusCode: 401, error: "invalidToken")
        }

        let trimmedLabel = request.deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidDeviceLabel(trimmedLabel) else {
            return Self.jsonError(statusCode: 400, error: "invalidDeviceLabel")
        }

        guard Self.isValidRequestedScopeRawValue(request.requestedScope) else {
            return Self.jsonError(statusCode: 400, error: "invalidScope")
        }

        do {
            let exchange = try await authService.exchangePairingCredential(
                trimmedToken,
                requested: Scope(rawValue: request.requestedScope),
                deviceLabel: trimmedLabel
            )
            let data = try JSONEncoder().encode(LocalPairingSessionResponse(exchange: exchange))
            if let onExchangeSuccess {
                Task { await onExchangeSuccess(exchange) }
            }
            return LocalPairingHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        } catch let error as AuthError {
            return Self.authErrorResponse(error)
        } catch {
            return Self.jsonError(statusCode: 500, error: "exchangeFailed")
        }
    }

    private static func isValidRequestedScopeRawValue(_ rawValue: Int) -> Bool {
        rawValue > 0 && (rawValue & ~Scope.admin.rawValue) == 0
    }

    private static func isValidDeviceLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 80 else { return false }
        return !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func authErrorResponse(_ error: AuthError) -> LocalPairingHTTPResponse {
        switch error {
        case .alreadyUsed:
            return jsonError(statusCode: 409, error: "alreadyUsed")
        case .scopeNotGranted, .missingScope, .unscopedMessage:
            return jsonError(statusCode: 403, error: "scopeNotGranted")
        case .expired:
            return jsonError(statusCode: 401, error: "expired")
        case .revoked:
            return jsonError(statusCode: 401, error: "revoked")
        case .invalidToken, .unknown:
            return jsonError(statusCode: 401, error: "invalidToken")
        }
    }

    private static func openContinuumPairingResponse(path: String) -> LocalPairingHTTPResponse {
        guard let components = URLComponents(string: "http://continuum.local\(path)"),
              let linkValue = components.queryItems?.first(where: { $0.name == "link" })?.value,
              let link = URL(string: linkValue),
              PairingURL.parsePayload(link) != nil else {
            return jsonError(statusCode: 400, error: "invalidPairingLink")
        }
        let escapedLink = htmlEscaped(link.absoluteString)
        let body = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="refresh" content="0;url=\(escapedLink)">
          <title>Open Continuum</title>
          <style>
            body { font: -apple-system-body; margin: 2rem; line-height: 1.4; }
            a { display: inline-block; padding: 0.9rem 1rem; border-radius: 12px; background: #ff8a00; color: white; text-decoration: none; font-weight: 700; }
            code { word-break: break-all; }
          </style>
        </head>
        <body>
          <h1>Open Continuum</h1>
          <p>If Continuum does not open automatically, tap the button below.</p>
          <p><a href="\(escapedLink)">Open Continuum to Pair</a></p>
          <p><small>This local page expires with the pairing window.</small></p>
        </body>
        </html>
        """
        return LocalPairingHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store"
            ],
            body: Data(body.utf8)
        )
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    fileprivate static func jsonError(statusCode: Int, error: String) -> LocalPairingHTTPResponse {
        let body = (try? JSONEncoder().encode(["error": error])) ?? Data("{\"error\":\"unknown\"}".utf8)
        return LocalPairingHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }
}

#if os(macOS)
import Darwin
import Dispatch

public struct LocalPairingListenerStatus: Equatable, Sendable {
    public var endpointURL: URL
    public var expiresAt: Date
    public var isListening: Bool

    public init(endpointURL: URL, expiresAt: Date, isListening: Bool) {
        self.endpointURL = endpointURL
        self.expiresAt = expiresAt
        self.isListening = isListening
    }
}

public enum LocalPairingListenerError: Error, Equatable, CustomStringConvertible {
    case invalidIPv4Host(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case getsocknameFailed(Int32)
    case endpointURLFailed(String)

    public var description: String {
        switch self {
        case .invalidIPv4Host(let host): return "invalid IPv4 host \(host)"
        case .socketFailed(let code): return "socket failed errno=\(code)"
        case .bindFailed(let code): return "bind failed errno=\(code)"
        case .listenFailed(let code): return "listen failed errno=\(code)"
        case .getsocknameFailed(let code): return "getsockname failed errno=\(code)"
        case .endpointURLFailed(let value): return "endpoint URL failed for \(value)"
        }
    }
}

public final class LocalPairingEndpointListener: @unchecked Sendable {
    public let endpoint: LocalPairingEndpoint
    public let endpointURL: URL
    public let expiresAt: Date

    private let socketFD: Int32
    private let source: DispatchSourceRead
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stopped = false
    private var expiryTimer: DispatchSourceTimer?

    public static func start(
        authService: CompanionAuthService,
        bindHost: String = "0.0.0.0",
        advertisedHost: String? = nil,
        port: UInt16 = 0,
        expiresAt: Date,
        acceptedCredential: String? = nil,
        clock: any Clock = SystemClock(),
        onExchangeSuccess: LocalPairingEndpoint.PairingExchangeHandler? = nil
    ) throws -> LocalPairingEndpointListener {
        try LocalPairingEndpointListener(
            authService: authService,
            bindHost: bindHost,
            advertisedHost: advertisedHost,
            port: port,
            expiresAt: expiresAt,
            acceptedCredential: acceptedCredential,
            clock: clock,
            onExchangeSuccess: onExchangeSuccess
        )
    }

    public static func preferredAdvertisedHost() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let host = hostBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            if !host.isEmpty, !host.hasPrefix("169.254."), host != "0.0.0.0" {
                return host
            }
        }
        return "127.0.0.1"
    }

    private init(
        authService: CompanionAuthService,
        bindHost: String,
        advertisedHost: String?,
        port: UInt16,
        expiresAt: Date,
        acceptedCredential: String?,
        clock: any Clock,
        onExchangeSuccess: LocalPairingEndpoint.PairingExchangeHandler?
    ) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalPairingListenerError.socketFailed(errno) }
        var shouldCloseFD = true
        defer {
            if shouldCloseFD { close(fd) }
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindHost, &bindAddress.sin_addr) == 1 else {
            throw LocalPairingListenerError.invalidIPv4Host(bindHost)
        }

        let bindStatus = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else { throw LocalPairingListenerError.bindFailed(errno) }
        guard listen(fd, SOMAXCONN) == 0 else { throw LocalPairingListenerError.listenFailed(errno) }

        var actualAddress = sockaddr_in()
        var actualAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &actualAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &actualAddressLength)
            }
        }
        guard nameStatus == 0 else { throw LocalPairingListenerError.getsocknameFailed(errno) }

        let actualPort = UInt16(bigEndian: actualAddress.sin_port)
        let publicHost = advertisedHost ?? Self.preferredAdvertisedHost()
        let endpointString = "http://\(publicHost):\(actualPort)/pair"
        guard let endpointURL = URL(string: endpointString) else {
            throw LocalPairingListenerError.endpointURLFailed(endpointString)
        }

        let queue = DispatchQueue(label: "continuum.local-pairing-listener")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.socketFD = fd
        self.queue = queue
        self.source = source
        self.endpointURL = endpointURL
        self.expiresAt = expiresAt
        self.endpoint = LocalPairingEndpoint(
            authService: authService,
            expiresAt: expiresAt,
            acceptedCredential: acceptedCredential,
            clock: clock,
            onExchangeSuccess: onExchangeSuccess
        )

        source.setEventHandler { [weak self] in
            self?.acceptOneConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        shouldCloseFD = false
        source.resume()
        scheduleExpiryTimer()
    }

    deinit {
        stop()
    }

    public func status() -> LocalPairingListenerStatus {
        lock.lock()
        let isListening = !stopped
        lock.unlock()
        return LocalPairingListenerStatus(endpointURL: endpointURL, expiresAt: expiresAt, isListening: isListening)
    }

    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let timer = expiryTimer
        expiryTimer = nil
        lock.unlock()

        timer?.cancel()
        source.cancel()
        Task { await endpoint.stop() }
    }

    private func scheduleExpiryTimer() {
        let interval = max(0, expiresAt.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            self?.stop()
        }
        lock.lock()
        expiryTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func acceptOneConnection() {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return }

        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                accept(socketFD, sockaddrPointer, &length)
            }
        }
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        DispatchQueue.global(qos: .userInitiated).async { [endpoint] in
            Task {
                let response: LocalPairingHTTPResponse
                do {
                    let request = try Self.readHTTPRequest(from: clientFD)
                    response = await endpoint.handle(method: request.method, path: request.path, body: request.body)
                } catch {
                    response = LocalPairingEndpoint.jsonError(statusCode: 400, error: "invalidRequest")
                }
                Self.writeHTTPResponse(response, to: clientFD)
                close(clientFD)
            }
        }
    }

    private struct ParsedHTTPRequest {
        var method: String
        var path: String
        var body: Data
    }

    private static func readHTTPRequest(from fd: Int32) throws -> ParsedHTTPRequest {
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
        guard let headerRange else { throw LocalPairingListenerError.endpointURLFailed("malformed-http") }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw LocalPairingListenerError.endpointURLFailed("malformed-headers")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw LocalPairingListenerError.endpointURLFailed("missing-request-line")
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            throw LocalPairingListenerError.endpointURLFailed("bad-request-line")
        }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
            }
        }
        guard contentLength >= 0, contentLength <= 64 * 1024 else {
            throw LocalPairingListenerError.endpointURLFailed("bad-content-length")
        }

        let bodyStart = headerRange.upperBound
        var body = Data(data[bodyStart...])
        while body.count < contentLength {
            let count = recv(fd, &buffer, min(buffer.count, contentLength - body.count), 0)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        guard body.count >= contentLength else {
            throw LocalPairingListenerError.endpointURLFailed("short-body")
        }
        if body.count > contentLength {
            body = Data(body.prefix(contentLength))
        }
        return ParsedHTTPRequest(method: requestParts[0], path: requestParts[1], body: body)
    }

    private static func writeHTTPResponse(_ response: LocalPairingHTTPResponse, to fd: Int32) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let reason = reasonPhrase(for: response.statusCode)
        var headerText = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            headerText += "\(name): \(value)\r\n"
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
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        default: return "Internal Server Error"
        }
    }
}
#endif
