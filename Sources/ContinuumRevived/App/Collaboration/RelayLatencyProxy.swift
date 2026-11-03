import Foundation

/// Checks only: a loopback HTTP/1.1 proxy between the app and the local relay
/// (`ShareEntryRelayChecks.Relay`). It records every request line with when it
/// arrived and when its response began, can add a fixed delay before each
/// request (a wide-area round trip), and can hold requests matching a
/// predicate until released (a slow relay, deterministically). A WebSocket
/// upgrade becomes a raw pipe.
final class RelayLatencyProxy: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Request: Sendable {
        let line: String
        let sent: Date
        var responded: Date?
        var seconds: Double? { responded.map { $0.timeIntervalSince(sent) } }
    }

    let port: Int
    private let upstreamPort: Int
    private let listener: Int32
    private let lock = NSCondition()
    private var log: [Request] = []
    private var delay: TimeInterval = 0
    private var holding: (@Sendable (String) -> Bool)?
    private var heldCount = 0
    private var closed = false

    init(upstreamPort: Int) throws {
        self.upstreamPort = upstreamPort
        port = try ShareEntryRelayChecks.Relay.freePort()
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.loopback(port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 64) == 0 else { throw Failure(description: "proxy could not listen") }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() { lock.lock(); closed = true; holding = nil; lock.broadcast(); lock.unlock(); close(listener) }

    /// Seconds added before every request is forwarded.
    func setDelay(_ seconds: TimeInterval) { lock.lock(); delay = seconds; lock.unlock() }
    /// Requests whose line matches wait until `release()`.
    func hold(_ predicate: @escaping @Sendable (String) -> Bool) { lock.lock(); holding = predicate; lock.unlock() }
    func release() { lock.lock(); holding = nil; lock.broadcast(); lock.unlock() }
    /// Requests currently waiting at the hold.
    var held: Int { lock.lock(); defer { lock.unlock() }; return heldCount }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }
    var count: Int { lock.lock(); defer { lock.unlock() }; return log.count }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            let upstream = socket(AF_INET, SOCK_STREAM, 0)
            var address = Self.loopback(upstreamPort)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { close(client); close(upstream); continue }
            let pending = PendingResponses()
            Thread.detachNewThread { [self] in forwardRequests(from: client, to: upstream, pending: pending) }
            Thread.detachNewThread { [self] in forwardResponses(from: upstream, to: client, pending: pending) }
        }
    }

    /// Indices of forwarded requests awaiting their first response byte, in order.
    private final class PendingResponses: @unchecked Sendable {
        let lock = NSLock()
        var queue: [Int] = []
    }

    private func forwardRequests(from client: Int32, to upstream: Int32, pending: PendingResponses) {
        defer { shutdown(client, SHUT_RDWR); shutdown(upstream, SHUT_RDWR) }
        var buffer = Data()
        var raw = false
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { return }
            if raw { guard writeAll(upstream, Data(chunk[0..<n])) else { return }; continue }
            buffer.append(contentsOf: chunk[0..<n])
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.lazy.compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
                let total = buffer.distance(from: buffer.startIndex, to: end.upperBound) + length
                guard buffer.count >= total else { break }
                let message = buffer.prefix(total)
                buffer.removeFirst(total)
                let line = lines.first ?? ""
                let upgrade = lines.contains { $0.lowercased().hasPrefix("upgrade:") }
                lock.lock()
                let arrived = Date()
                let wait = delay
                while let holding, holding(line), !closed { heldCount += 1; lock.wait(); heldCount -= 1 }
                lock.unlock()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                lock.lock()
                let index = log.count
                log.append(Request(line: line, sent: arrived))
                lock.unlock()
                pending.lock.lock(); pending.queue.append(index); pending.lock.unlock()
                guard writeAll(upstream, Data(message)) else { return }
                if upgrade {
                    raw = true
                    if !buffer.isEmpty { guard writeAll(upstream, buffer) else { return }; buffer.removeAll() }
                    break
                }
            }
        }
    }

    private func forwardResponses(from upstream: Int32, to client: Int32, pending: PendingResponses) {
        defer { shutdown(client, SHUT_RDWR); shutdown(upstream, SHUT_RDWR) }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(upstream, &chunk, chunk.count)
            guard n > 0 else { return }
            // HTTP/1.1 without pipelining: a read after a forwarded request is
            // that request's response beginning.
            pending.lock.lock()
            let index = pending.queue.isEmpty ? nil : pending.queue.removeFirst()
            pending.lock.unlock()
            if let index {
                lock.lock()
                if log[index].responded == nil { log[index].responded = Date() }
                lock.unlock()
            }
            guard writeAll(client, Data(chunk[0..<n])) else { return }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }
}
