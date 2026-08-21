import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/61b-canvas-editor.md
//
// The first spatial-op wire path. `SpatialOpSender` is the desktop-role peer
// (serves snapshot-then-tail, ingests authorized inbound ops); `SpatialOpReceiver`
// is the phone-role peer (folds snapshot+tail, emits optimistic local ops). Both
// mirror `ActivityProjectionSender`/`ActivityProjectionReceiver`'s shape — see
// ActivityProjectionSender.swift/ActivityProjectionReceiver.swift.
//
// Verified fact (ticket banner): the desktop app's live canvas is NOT wired to a
// store tonight — desktop canvas mutations don't flow through the op-log in
// production at all. That bidirectional bridge is a separate follow-up ticket.

/// Backing store for spatial ops the desktop-role `SpatialOpSender` publishes
/// from and ingests into. `MemorySpatialOpLogStore` is the in-memory reference
/// implementation the checks (and, later, a persistence-backed conformance)
/// exercise.
public protocol SpatialOpLogStore: Actor {
    /// Appends one op to the log and fans it (as `.op`) to every current
    /// `subscribe()` stream — mirrors `ActivityStore.append`'s "fold, then fan"
    /// discipline.
    func append(_ op: LoggedOp) async

    /// Standalone snapshot access — compacted through the log's current
    /// highest Lamport, independent of any subscription (mirrors
    /// `ActivityStoreProtocol.currentSnapshot()`'s role alongside `subscribe()`).
    func currentSnapshot() async -> CompactedSnapshot

    /// snapshot-then-tail: yields a `.snapshot(CompactedSnapshot)` (compacted
    /// through the log's current highest Lamport via the existing
    /// `compact(log:through:)`) immediately, then every subsequently appended
    /// `.op` — the exact `ActivityStore.subscribe()` shape, reusing the
    /// wire-shaped `SyncMessage` cases directly (`.op`/`.snapshot` need no
    /// projection before hitting the transport).
    func subscribe() -> AsyncStream<SyncMessage>
}

/// In-memory reference `SpatialOpLogStore`. No persistence, no compaction
/// low-water-mark tracking beyond "compact through everything on every
/// subscribe" — sufficient for the checks and for a future desktop-canvas
/// wiring ticket to swap in a durable conformance behind the same protocol.
public actor MemorySpatialOpLogStore: SpatialOpLogStore {
    private var ops: [LoggedOp] = []
    private var observers: [UUID: AsyncStream<SyncMessage>.Continuation] = [:]

    public init(seeding initialOps: [LoggedOp] = []) {
        ops = initialOps
    }

    public func append(_ op: LoggedOp) async {
        ops.append(op)
        for continuation in observers.values {
            continuation.yield(.op(op))
        }
    }

    /// Test/measurement introspection — every op appended so far, in append
    /// order (mirrors `FakeSyncTransport.delivered(to:)`'s role).
    public func allOps() -> [LoggedOp] { ops }

    public func currentSnapshot() async -> CompactedSnapshot {
        Self.compactedSnapshot(of: ops)
    }

    public func subscribe() -> AsyncStream<SyncMessage> {
        let current = ops
        return AsyncStream { continuation in
            continuation.yield(.snapshot(Self.compactedSnapshot(of: current)))
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private static func compactedSnapshot(of ops: [LoggedOp]) -> CompactedSnapshot {
        let maxLamport = ops.map(\.opId.lamport).max() ?? 0
        return compact(log: ops, through: maxLamport).snapshot
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

/// Maps an inbound spatial `Op` to the `ControlMessage` whose scope
/// requirement authorizes it. `.moveTile` and `.resizeTile` both require
/// exactly `.orchestrationOperate` (ScopeAuthorization.swift) — every
/// mutation in the closed `Op` set lands in that one class, so this mapping's
/// only job is picking a representative case for `authorize(_:grantedScopes:)`
/// to check against; which of the two identically-scoped control messages is
/// used has no behavioral effect.
public func capability(for op: Op) -> ControlMessage {
    switch op {
    case .setTileFrame:
        return .resizeTile
    case .createTile, .deleteTile, .setTileZIndex, .setTileTitle, .setTileKind, .setTileCollapsed,
         .createZone, .deleteZone, .setZoneOrigin, .setZoneSize, .setZoneName, .setZoneColor,
         .setZoneCollapsed, .setZoneProjectId, .setZoneAutoLayoutMode, .setZonePosition, .setTileZone,
         .setLastActiveTile, .setLastActiveZone:
        return .moveTile
    }
}

/// Sends a `SpatialOpLogStore` snapshot-then-tail projection over a shared
/// sync transport demux, and ingests authorized inbound ops (phone edits).
/// The desktop-role peer — mirrors `ActivityProjectionSender`'s shape.
public actor SpatialOpSender {
    private let store: any SpatialOpLogStore
    private let demux: SyncMessageDemux
    private let authorizedScope: Scope
    private var requestLoopTask: Task<Void, Never>?
    private var activeServeTask: Task<Void, Never>?

    public init(store: any SpatialOpLogStore, demux: SyncMessageDemux, authorizedScope: Scope) {
        self.store = store
        self.demux = demux
        self.authorizedScope = authorizedScope
    }

    /// Call once. The subscription stream is registered synchronously before
    /// `start()` returns, so a receiver may send `.spatialSubscribe`/`.op`
    /// immediately after this call without racing the sender's registration.
    public func start() async {
        guard requestLoopTask == nil else { return }
        let stream = await demux.subscribe()
        requestLoopTask = Task { [weak self] in
            await self?.handleInbound(stream)
        }
    }

    public func stop() {
        requestLoopTask?.cancel()
        requestLoopTask = nil
        activeServeTask?.cancel()
        activeServeTask = nil
    }

    private func handleInbound(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            switch message {
            case .spatialSubscribe:
                guard (try? authorize(.subscribeSpatial, grantedScopes: authorizedScope)) != nil else { continue }
                activeServeTask?.cancel()
                activeServeTask = Task { [weak self] in
                    await self?.serve()
                }
            case .op(let logged):
                // Authorize the phone edit against the session scope. An
                // unauthorized op is dropped, never appended — there is no
                // error channel in `SyncMessage` v1 (the phone UI
                // independently disables editing below operator scope,
                // defense in depth, both layers checked).
                guard (try? authorize(capability(for: logged.op), grantedScopes: authorizedScope)) != nil else { continue }
                // `store.append` fans the op to every active `subscribe()`
                // stream — including `serve()`'s below — which forwards it
                // to the demux. That IS the rebroadcast; sending it again
                // here would double-deliver.
                await store.append(logged)
            default:
                continue
            }
        }
    }

    private func serve() async {
        for await message in await store.subscribe() {
            if Task.isCancelled { return }
            try? await demux.send(message)
        }
    }
}

/// Receives a `SpatialOpLogStore` snapshot-then-tail projection over a shared
/// sync transport demux and exposes the folded `MaterializedState`. A fresh
/// receiver deliberately does not emit its local empty bootstrap canvas until a
/// remote desktop snapshot/op arrives, keeping phone freshness remote-backed.
/// The phone-role peer mirrors `ActivityProjectionReceiver`'s shape, but folds
/// via the EXISTING `materialize(onto:baseOpId:ledger:tail:)` (base snapshot +
/// re-folded tail list) rather than a bespoke incremental apply.
public actor SpatialOpReceiver {
    private var baseState: MaterializedState
    private var baseOpId: OpId
    private var baseLedger: CompactionLedger
    private var tail: [LoggedOp] = []
    private var maxSeenLamport: UInt64
    private let phoneReplicaId: UUID
    private let demux: SyncMessageDemux
    private var observers: [UUID: AsyncStream<MaterializedState>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var remoteSpatialSeen = false

    public init(demux: SyncMessageDemux, phoneReplicaId: UUID = UUID()) {
        self.demux = demux
        self.phoneReplicaId = phoneReplicaId
        // The canonical empty snapshot (same zero-log path `compact([], through:
        // 0)` already defines) — deterministic across replicas, reusing the
        // production compactor rather than hand-rolling a second zero state.
        let empty = compact(log: [], through: 0).snapshot
        baseState = empty.state
        baseOpId = empty.compactionOpId
        baseLedger = empty.ledger
        maxSeenLamport = empty.compactionOpId.lamport
    }

    /// Registers the receive stream before sending the subscription request —
    /// same load-bearing ordering as `ActivityProjectionReceiver.connect`.
    public func connect() async {
        if receiveTask == nil {
            let stream = await demux.subscribe()
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(stream)
            }
        }
        try? await demux.send(.spatialSubscribe(SpatialSubscribeRequest()))
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func receiveLoop(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            switch message {
            case .snapshot(let incoming):
                // A stale or concurrent snapshot must not silently erase local
                // ops (e.g. this replica's own optimistic emits) that aren't
                // yet folded into it — `applySnapshot` keeps exactly the tail
                // ops the incoming snapshot hasn't absorbed (by full `OpId`
                // order, not just Lamport), matching the receiver's existing
                // "base snapshot + re-folded tail" fold.
                baseState = incoming.state
                baseOpId = incoming.compactionOpId
                baseLedger = incoming.ledger
                tail = applySnapshot(incoming, ontop: tail)
                maxSeenLamport = max(maxSeenLamport, incoming.compactionOpId.lamport)
                remoteSpatialSeen = true
                fan(currentMaterialized())
            case .op(let logged):
                // Idempotent under re-delivery (including the sender's own
                // rebroadcast echo of an op this replica just emitted):
                // `materialize`'s per-field LWW only advances on a strictly
                // greater `OpId`, so folding the same op twice is a no-op.
                tail.append(logged)
                maxSeenLamport = max(maxSeenLamport, logged.opId.lamport)
                remoteSpatialSeen = true
                fan(currentMaterialized())
            default:
                continue
            }
        }
    }

    private func currentMaterialized() -> MaterializedState {
        materialize(onto: baseState, baseOpId: baseOpId, ledger: baseLedger, tail: tail)
    }

    public func subscribe() -> AsyncStream<MaterializedState> {
        let current = currentMaterialized()
        let shouldYieldCurrent = remoteSpatialSeen
        return AsyncStream { continuation in
            if shouldYieldCurrent {
                continuation.yield(current)
            }
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    public func hasReceivedRemoteSpatial() -> Bool { remoteSpatialSeen }

    public func currentState() -> MaterializedState { currentMaterialized() }

    /// Allocates `OpId(lamport: maxSeen+1, replica: phoneReplicaId)`, applies
    /// it locally (optimistic re-fold), and sends it. On send failure, reverts
    /// the local append and rethrows so the caller (the gesture handler) can
    /// snap back + surface a non-blocking error — NO mid-drag ops, exactly one
    /// op per gesture end.
    public func emit(_ op: Op) async throws {
        let opId = OpId(lamport: maxSeenLamport + 1, replica: phoneReplicaId)
        let logged = LoggedOp(opId: opId, op: op)
        tail.append(logged)
        maxSeenLamport = opId.lamport
        fan(currentMaterialized())
        do {
            try await demux.send(.op(logged))
        } catch {
            tail.removeAll { $0.opId == logged.opId }
            fan(currentMaterialized())
            throw error
        }
    }

    /// Sequential emit for an ordered op list produced by a single gesture end
    /// (e.g. `CanvasEditIntent.moveDropOps`): sends each op via `emit` in
    /// order, STOPPING at the first failure — the failed op's optimistic apply
    /// reverts exactly as `emit` does, ops after it are never sent, and
    /// earlier successes stand (a completed move without its membership
    /// change is a valid state; a membership change after a failed move is
    /// not).
    public func emitAll(_ ops: [Op]) async throws {
        for op in ops {
            try await emit(op)
        }
    }

    private func fan(_ state: MaterializedState) {
        for continuation in observers.values {
            continuation.yield(state)
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
