import Foundation

/// Single-drain fan-out for a `SyncTransport`.
///
/// `SyncTransport.inbound` is one AsyncStream. If a spatial consumer and an
/// activity consumer each drain it directly, they race for individual messages.
/// One demux owns the raw drain and gives every subscriber an independent copy.
public actor SyncMessageDemux {
    private let transport: any SyncTransport
    private var subscribers: [UUID: AsyncStream<SyncMessage>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?

    public init(transport: any SyncTransport) {
        self.transport = transport
    }

    public func send(_ message: SyncMessage) async throws {
        try await transport.send(message)
    }

    public var connectionState: AsyncStream<ConnectionState> {
        transport.connectionState
    }

    /// Registers the subscriber before the pump is started. This ordering is
    /// load-bearing for ticket 58: a caller may subscribe and then immediately
    /// send a request, and no already-buffered response may be drained before
    /// this continuation exists.
    public func subscribe() -> AsyncStream<SyncMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncMessage>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        startPumpIfNeeded()
        return stream
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        let inbound = transport.inbound
        pumpTask = Task { [weak self] in
            for await message in inbound {
                await self?.broadcast(message)
            }
        }
    }

    private func broadcast(_ message: SyncMessage) {
        for continuation in subscribers.values {
            continuation.yield(message)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
