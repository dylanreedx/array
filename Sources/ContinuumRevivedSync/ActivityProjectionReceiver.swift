import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Receives activity projection items over a sync transport demux and exposes
/// the same snapshot-then-tail shape as `ActivityStoreProtocol.subscribe()`
/// after the first remote item arrives. A fresh receiver deliberately does not
/// emit its local empty bootstrap snapshot; phone freshness must be backed by
/// Mac-published activity, not client-local initialization.
public actor ActivityProjectionReceiver {
    private var snapshot: ActivityLogSnapshot = .empty
    private var appliedSequenceByReplica: [UUID: UInt64] = [:]
    private var observers: [UUID: AsyncStream<ActivityStreamItem>.Continuation] = [:]
    private let demux: SyncMessageDemux
    private let scope: Scope
    private let gapRetryLimit: Int
    private let gapRetryBackoff: Duration
    private var receiveTask: Task<Void, Never>?
    private var remoteActivitySeen = false
    private var gapWatchdog: Task<Void, Never>?
    private var gapReplicaId: UUID?
    private var gapTargetSequence: UInt64?

    public init(
        demux: SyncMessageDemux,
        scope: Scope,
        gapRetryLimit: Int = 3,
        gapRetryBackoff: Duration = .milliseconds(500)
    ) {
        precondition(scope.contains(.orchestrationRead), "ActivityProjectionReceiver requires observer read scope")
        self.demux = demux
        self.scope = scope
        self.gapRetryLimit = gapRetryLimit
        self.gapRetryBackoff = gapRetryBackoff
    }

    /// Registers the receive stream before sending the subscription request.
    public func connect(cursor: ActivityCursor? = nil) async {
        if let cursor {
            let priorApplied = appliedSequenceByReplica[cursor.replicaId] ?? 0
            appliedSequenceByReplica[cursor.replicaId] = max(priorApplied, cursor.sequence)
        }
        if receiveTask == nil {
            let stream = await demux.subscribe()
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(stream)
            }
        }
        await requestSubscription(cursor: cursor)
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        cancelGapWatchdog()
    }

    private func requestSubscription(cursor: ActivityCursor?) async {
        _ = scope
        try? await demux.send(.activitySubscribe(ActivitySubscribeRequest(cursor: cursor)))
    }

    private func receiveLoop(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            guard case .activity(let item) = message else { continue }
            await handle(item)
        }
    }

    private func handle(_ item: ActivityStreamItem) async {
        switch item {
        case .snapshot(let incoming):
            let priorApplied = appliedSequenceByReplica[incoming.snapshotReplicaId] ?? 0
            guard incoming.snapshotSequence >= priorApplied else { return }
            snapshot = incoming
            appliedSequenceByReplica[incoming.snapshotReplicaId] = incoming.snapshotSequence
            remoteActivitySeen = true
            cancelGapWatchdog()
            fan(item)

        case .event(let event):
            let lastApplied = appliedSequenceByReplica[event.replicaId] ?? 0
            if event.sequence <= lastApplied { return }
            guard event.sequence == lastApplied + 1 else {
                if gapReplicaId == event.replicaId {
                    gapTargetSequence = max(gapTargetSequence ?? event.sequence, event.sequence)
                } else if gapWatchdog == nil {
                    gapReplicaId = event.replicaId
                    gapTargetSequence = event.sequence
                }
                if gapWatchdog == nil {
                    gapReplicaId = event.replicaId
                    gapWatchdog = Task { [weak self] in
                        await self?.runGapWatchdog(replicaId: event.replicaId)
                    }
                }
                return
            }

            snapshot = apply(snapshot, event)
            appliedSequenceByReplica[event.replicaId] = event.sequence
            remoteActivitySeen = true
            if gapReplicaId == event.replicaId {
                if let target = gapTargetSequence, event.sequence < target {
                    // Keep retrying until the widest known gap is closed.
                } else {
                    cancelGapWatchdog()
                }
            }
            fan(item)
        }
    }

    private func runGapWatchdog(replicaId: UUID) async {
        var attempt = 0
        while true {
            attempt += 1
            if attempt > gapRetryLimit {
                gapWatchdog = nil
                gapReplicaId = nil
                gapTargetSequence = nil
                await requestSubscription(cursor: nil)
                return
            }
            let cursor = ActivityCursor(sequence: appliedSequenceByReplica[replicaId] ?? 0, replicaId: replicaId)
            await requestSubscription(cursor: cursor)
            try? await Task.sleep(for: gapRetryBackoff)
            if Task.isCancelled { return }
        }
    }

    private func cancelGapWatchdog() {
        gapWatchdog?.cancel()
        gapWatchdog = nil
        gapReplicaId = nil
        gapTargetSequence = nil
    }

    public func subscribe() -> AsyncStream<ActivityStreamItem> {
        let current = snapshot
        let shouldYieldCurrent = remoteActivitySeen
        let (stream, continuation) = AsyncStream<ActivityStreamItem>.makeStream()
        if shouldYieldCurrent {
            continuation.yield(.snapshot(current))
        }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public func hasReceivedRemoteActivity() -> Bool {
        remoteActivitySeen
    }

    public func agentStatusesByTileId() -> [UUID: AgentStatus] {
        snapshot.byTile.mapValues(\.status)
    }

    public func currentSnapshot() -> ActivityLogSnapshot {
        snapshot
    }

    private func fan(_ item: ActivityStreamItem) {
        for continuation in observers.values {
            continuation.yield(item)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
