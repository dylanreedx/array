import AppKit
import ContinuumRevivedCore
import Foundation

#if os(macOS)
import Darwin
#endif

/// Host-side loopback transport for native-provider MCP children. The listener
/// is intentionally per-app and the capability is per-agent: the HTTP request
/// carries a random token, but the host still resolves identity from the
/// supervisor's records before dispatching WorkspaceAPIService.
@MainActor
final class WorkspaceMCPHost {
    struct Registration {
        let token: String
        let endpoint: String
    }

    private var listener: WorkspaceMCPHTTPListener?
    private var registrations: [AgentID: Registration] = [:]
    private var handler: (([String: Any]) -> [String: Any])?

    func setHandler(_ handler: @escaping ([String: Any]) -> [String: Any]) {
        self.handler = handler
    }

    func configuration(for agentID: AgentID, serverExecutable: String) -> WorkspaceMCPConfiguration? {
        if let registration = registrations[agentID] {
            return WorkspaceMCPConfiguration(serverExecutable: serverExecutable, endpoint: registration.endpoint,
                                             agentID: agentID.rawValue.uuidString, token: registration.token)
        }
        do {
            if listener == nil {
                listener = try WorkspaceMCPHTTPListener { [weak self] body in
                    guard let self else { return Self.error(code: "hostUnavailable", message: "Array host unavailable") }
                    return DispatchQueue.main.sync { self.handle(body) }
                }
            }
            let token = UUID().uuidString + UUID().uuidString
            let registration = Registration(token: token, endpoint: listener!.endpoint)
            registrations[agentID] = registration
            return WorkspaceMCPConfiguration(serverExecutable: serverExecutable, endpoint: registration.endpoint,
                                             agentID: agentID.rawValue.uuidString, token: token)
        } catch {
            fputs("Workspace MCP listener unavailable: \(error)\n", stderr)
            return nil
        }
    }

    private func handle(_ body: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let agentText = object["agentId"] as? String,
              let agentUUID = UUID(uuidString: agentText),
              let agentID = registrations.keys.first(where: { $0.rawValue == agentUUID }),
              let token = object["token"] as? String,
              registrations[agentID]?.token == token,
              let handler,
              let reply = handler(object) as? [String: Any],
              JSONSerialization.isValidJSONObject(reply),
              let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else {
            return Self.error(code: "permission_denied", message: "Invalid Array workspace capability")
        }
        return data
    }

    nonisolated private static func error(code: String, message: String) -> Data {
        let object: [String: Any] = ["schema": WorkspaceAPISchema.v1, "status": "error",
                                     "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

private final class WorkspaceMCPHTTPListener: @unchecked Sendable {
    let endpoint: String
    private let socketFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "array.workspace-mcp-listener")
    private let handler: @Sendable (Data) -> Data
    private let lock = NSLock()
    private var stopped = false

    init(handler: @escaping @Sendable (Data) -> Data) throws {
        self.handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno)!) }
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(fd, withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &length)
        let port = UInt16(bigEndian: actual.sin_port)
        self.endpoint = "http://127.0.0.1:\(port)/workspace-mcp"
        self.socketFD = fd
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { stop() }

    private func accept() {
        var address = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(socketFD, $0, &length) } }
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [handler] in
            let body = Self.readBody(client)
            let response = handler(body)
            Self.writeResponse(response, to: client)
            close(client)
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true; source.cancel()
    }

    private static func readBody(_ fd: Int32) -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_048_576 {
            let count = recv(fd, &buffer, buffer.count, 0); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            if let range = data.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: data[..<range.lowerBound], encoding: .utf8),
               let lengthLine = headers.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
               let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)),
               data.count >= range.upperBound + length {
                return Data(data[range.upperBound..<(range.upperBound + length)])
            }
        }
        return Data()
    }

    private static func writeResponse(_ body: Data, to fd: Int32) {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        head.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, 0) }
        body.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, 0) }
    }
}
