import Foundation

public struct ReadinessProbeResult: Equatable, Sendable {
    public let rawOutput: String
    public let snapshot: SessionTopologySnapshot
    public let negotiatedScope: Scope

    public init(rawOutput: String, snapshot: SessionTopologySnapshot, negotiatedScope: Scope) {
        self.rawOutput = rawOutput
        self.snapshot = snapshot
        self.negotiatedScope = negotiatedScope
    }
}

public protocol RemoteSocket: Sendable {
    var closed: AsyncStream<Void> { get async }
    func readinessProbe() async throws -> ReadinessProbeResult
    func activityStream() async -> AsyncStream<ActivityStreamItem>
    func close() async
}

public protocol ConnectionDriver: Sendable {
    func openSocket() async throws -> any RemoteSocket
}

public protocol RemoteSession: Sendable {
    var readinessProbe: ReadinessProbeResult { get }
    var scope: Scope { get }
    var generation: Int { get }
    func activityStream() async -> AsyncStream<ActivityStreamItem>
}

public struct ConnectionRemoteSession: RemoteSession {
    public let socket: any RemoteSocket
    public let readinessProbe: ReadinessProbeResult
    public let scope: Scope
    public let generation: Int

    public init(
        socket: any RemoteSocket,
        readinessProbe: ReadinessProbeResult,
        scope: Scope,
        generation: Int
    ) {
        self.socket = socket
        self.readinessProbe = readinessProbe
        self.scope = scope
        self.generation = generation
    }

    public func activityStream() async -> AsyncStream<ActivityStreamItem> {
        await socket.activityStream()
    }
}

public func durableActivityStream(
    sessions: AsyncStream<(any RemoteSession)?>
) -> AsyncStream<ActivityStreamItem> {
    AsyncStream { continuation in
        let pump = Task {
            var inner: Task<Void, Never>?
            for await session in sessions {
                inner?.cancel()
                guard let session else { continue }
                inner = Task {
                    let events = await session.activityStream()
                    for await event in events {
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                }
            }
            inner?.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
    }
}

#if os(macOS)

public actor LocalTmuxConnectionDriver: ConnectionDriver {
    public init() {}

    public func openSocket() async throws -> any RemoteSocket {
        LocalTmuxRemoteSocket()
    }
}

private actor LocalTmuxRemoteSocket: RemoteSocket {
    private let closedStream: AsyncStream<Void>
    private let closedContinuation: AsyncStream<Void>.Continuation

    init() {
        (closedStream, closedContinuation) = AsyncStream<Void>.makeStream()
    }

    var closed: AsyncStream<Void> { closedStream }

    func readinessProbe() async throws -> ReadinessProbeResult {
        let output = try Self.runTmuxListWindows()
        let snapshot = try SessionTopologySnapshot.parse(tmuxOutput: output)
        return ReadinessProbeResult(rawOutput: output, snapshot: snapshot, negotiatedScope: .observer)
    }

    func activityStream() async -> AsyncStream<ActivityStreamItem> {
        AsyncStream { $0.finish() }
    }

    func close() async {
        closedContinuation.yield(())
    }

    private static func runTmuxListWindows() throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "list-windows", "-a", "-F", SessionTopologySnapshot.tmuxFormatString]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return String(decoding: out, as: UTF8.self)
        }

        let errorText = String(decoding: err, as: UTF8.self)
        // tmux says "no server" two different ways: "no server running on <socket>"
        // when the socket directory exists, and "error connecting to <socket> (No
        // such file or directory)" when it does not — which is what a machine that
        // has never started tmux, or a run inside a fresh TMUX_TMPDIR namespace,
        // actually gets. Both mean the same thing: an empty topology, not a probe
        // failure.
        if errorText.localizedCaseInsensitiveContains("no server running")
            || errorText.localizedCaseInsensitiveContains("error connecting to") {
            return ""
        }
        throw ConnectionError.probeFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

#endif
