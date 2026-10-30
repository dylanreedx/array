import ContinuumRevivedCore
import Darwin
import Foundation

// Only the signal handler writes this, and the check reads it after its
// synchronous send. Catch the signal so a RED mutation cannot crash Array's
// GUI host when this check is launched from an Array-managed session.
nonisolated(unsafe) private var workspaceMCPDisconnectSignals: sig_atomic_t = 0

@MainActor
func runWorkspaceMCPDisconnectCheck() throws {
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorkspaceAPIChecks.Failure(message: message) }
    }
    func connectedPair() throws -> [Int32] {
        // Use the endpoint's actual socket family: Darwin rejects SO_NOSIGPIPE
        // on AF_UNIX socket pairs, but supports it on accepted TCP sockets.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try expect(listener >= 0, "listener socket failed")
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try expect(bound == 0 && listen(listener, 1) == 0, "loopback listen failed")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        try expect(named == 0, "loopback address unavailable")
        let client = socket(AF_INET, SOCK_STREAM, 0)
        try expect(client >= 0, "client socket failed")
        do {
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
            }
            try expect(connected == 0, "loopback connect failed")
            let accepted = accept(listener, nil, nil)
            try expect(accepted >= 0, "loopback accept failed")
            // Same initialization as production accept(), before the peer can
            // disappear while the request waits for its response.
            guard WorkspaceMCPHTTPListener.prepareResponseSocket(accepted) else {
                close(accepted)
                throw WorkspaceAPIChecks.Failure(message: "could not prepare response socket")
            }
            return [accepted, client]
        } catch {
            close(client)
            throw error
        }
    }

    workspaceMCPDisconnectSignals = 0
    var action = sigaction(), previous = sigaction()
    sigemptyset(&action.sa_mask)
    action.__sigaction_u.__sa_handler = { _ in workspaceMCPDisconnectSignals += 1 }
    try expect(sigaction(SIGPIPE, &action, &previous) == 0, "could not install SIGPIPE witness")
    defer { sigaction(SIGPIPE, &previous, nil) }

    // Close the reader with RST, then consume that reset at the accepted end
    // BEFORE invoking the production writer. No sleeps, scheduling assumptions
    // or hook deadlines: the next send deterministically encounters EPIPE.
    let disconnected = try connectedPair()
    defer { close(disconnected[0]) }
    var reset = linger(l_onoff: 1, l_linger: 0)
    try expect(setsockopt(disconnected[1], SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) == 0,
               "could not configure reader reset")
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    try expect(setsockopt(disconnected[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
               "could not bound the reset handshake")
    try expect(close(disconnected[1]) == 0, "could not close the reply reader")
    var byte: UInt8 = 0
    let read = recv(disconnected[0], &byte, 1, 0)
    try expect(read == -1 && errno == ECONNRESET, "reader reset was not observed before the write")
    let failure = WorkspaceMCPHTTPListener.writeResponse(Data("{}".utf8), to: disconnected[0])
    try expect(failure == EPIPE, "closed reader must produce EPIPE, got \(String(describing: failure))")
    try expect(workspaceMCPDisconnectSignals == 0,
               "production MCP reply raised SIGPIPE after its reader closed")

    // The guard must still deliver the complete HTTP reply to a live reader.
    let connected = try connectedPair()
    defer { close(connected[0]); close(connected[1]) }
    let body = Data("{\"status\":\"ok\"}".utf8)
    try expect(WorkspaceMCPHTTPListener.writeResponse(body, to: connected[0]) == nil,
               "live reader reply failed")
    try expect(shutdown(connected[0], SHUT_WR) == 0, "could not finish the live reply")
    let received = FileHandle(fileDescriptor: connected[1], closeOnDealloc: false).readDataToEndOfFile()
    let expected = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    try expect(received == expected, "live reader lost HTTP headers or response body")
    print("Workspace MCP disconnected reader: EPIPE without SIGPIPE; live reply intact")

    // Also drive the authenticated production host and real MCP executable,
    // including a delayed reply, after the deterministic transport failure.
    try runWorkspaceMCPHostCheck()
    try expect(workspaceMCPDisconnectSignals == 0, "production MCP host raised SIGPIPE")
}
