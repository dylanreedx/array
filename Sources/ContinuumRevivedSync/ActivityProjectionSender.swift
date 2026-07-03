import ContinuumRevivedCore
import Foundation

/// Cursor reported by a receiver when it needs replay after reconnect or gap
/// detection.
public struct ActivityCursor: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let replicaId: UUID

    public init(sequence: UInt64, replicaId: UUID) {
        self.sequence = sequence
        self.replicaId = replicaId
    }
}

/// Activity subscription control message. Authorization is deliberately not a
/// field on the wire; the sender receives trusted scope from the authenticated
/// session that created the transport.
public struct ActivitySubscribeRequest: Codable, Sendable, Equatable {
    public let cursor: ActivityCursor?

    public init(cursor: ActivityCursor?) {
        self.cursor = cursor
    }
}

/// Sends an `ActivityStore` snapshot-then-tail projection over a shared sync
/// transport demux.
public actor ActivityProjectionSender {
    private let store: any ActivityStoreProtocol
    private let demux: SyncMessageDemux
    private let authorizedScope: Scope
    private var requestLoopTask: Task<Void, Never>?
    private var activeServeTask: Task<Void, Never>?

    public init(store: any ActivityStoreProtocol, demux: SyncMessageDemux, authorizedScope: Scope) {
        self.store = store
        self.demux = demux
        self.authorizedScope = authorizedScope
    }

    /// Call once. The subscription stream is registered synchronously before
    /// `start()` returns, so a receiver may send `.activitySubscribe`
    /// immediately after this call without racing the sender's registration.
    public func start() async {
        guard requestLoopTask == nil else { return }
        let stream = await demux.subscribe()
        requestLoopTask = Task { [weak self] in
            await self?.handleSubscriptionRequests(stream)
        }
    }

    public func stop() {
        requestLoopTask?.cancel()
        requestLoopTask = nil
        activeServeTask?.cancel()
        activeServeTask = nil
    }

    private func handleSubscriptionRequests(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            guard case .activitySubscribe(let request) = message else { continue }
            guard (try? authorize(.subscribeActivity, grantedScopes: authorizedScope)) != nil else {
                continue
            }
            activeServeTask?.cancel()
            activeServeTask = Task { [weak self] in
                await self?.serve(request)
            }
        }
    }

    private func serve(_ request: ActivitySubscribeRequest) async {
        if let cursor = request.cursor {
            let missed = await store.replay(fromSequenceExclusive: cursor.sequence, replicaId: cursor.replicaId)
            for event in missed {
                if Task.isCancelled { return }
                try? await demux.send(.activity(.event(event)))
            }
        }
        if Task.isCancelled { return }
        let stream = await store.subscribe()
        for await item in stream {
            if Task.isCancelled { return }
            try? await demux.send(.activity(item))
        }
    }
}
