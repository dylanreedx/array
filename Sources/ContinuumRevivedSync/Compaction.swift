import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/06-oplog-apply-compaction.md
//
// `compact` folds a long log down to a snapshot plus the tail of ops above a
// globally-acknowledged Lamport low-water mark, so the log never grows
// without bound. Re-materializing (snapshot + tail) must produce the same
// canonical output as materializing the full log — that equivalence is what
// makes compaction transparent to every downstream consumer of `materialize`.

/// A snapshot of `materialize`'s output taken at a specific point in the log,
/// plus the marker `OpId` (the highest folded in) a replica needs to know
/// which of its own ops are already represented in `state`.
public struct CompactedSnapshot: Codable, Equatable, Sendable {
    /// The highest `OpId` folded into `state` — every op at or below this
    /// mark (by the `OpId` total order, not just by Lamport) is represented.
    public var compactionOpId: OpId
    public var state: MaterializedState
    /// The tombstone ledger (ticket 05's `CompactionLedger`) carried forward
    /// through this compaction. `state` has already dropped every tombstoned
    /// tile/zone entirely (per `resolve()`'s delete-wins policy) — `ledger`
    /// is what lets `materialize(onto:baseOpId:ledger:tail:)` recognize a
    /// stale/re-delivered create for one of those ids in the tail and refuse
    /// to resurrect it. Without carrying this forward, a compacted snapshot
    /// has no way to reject a reused create for a deleted id.
    public var ledger: CompactionLedger

    public init(compactionOpId: OpId, state: MaterializedState, ledger: CompactionLedger) {
        self.compactionOpId = compactionOpId
        self.state = state
        self.ledger = ledger
    }
}

public struct CompactionResult: Codable, Equatable, Sendable {
    public var snapshot: CompactedSnapshot
    public var tail: [LoggedOp]

    public init(snapshot: CompactedSnapshot, tail: [LoggedOp]) {
        self.snapshot = snapshot
        self.tail = tail
    }
}

/// A fixed, deterministic marker for the empty-log edge case — never a
/// randomly generated `UUID()`, which would make `compact([], through: _)`
/// non-deterministic across replicas.
private let zeroReplica = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

/// Folds every op at or below `lowWaterMark` (by Lamport) into a snapshot via
/// `materialize`, returning that snapshot alongside the tail of ops above it.
public func compact(log: [LoggedOp], through lowWaterMark: UInt64) -> CompactionResult {
    let below = log.filter { $0.opId.lamport <= lowWaterMark }
    let tail = log.filter { $0.opId.lamport > lowWaterMark }

    // The highest OpId among the folded ops is the compaction marker — ties
    // at `lamport == lowWaterMark` from different replicas are broken by the
    // same (lamport, replica) order `materialize` sorts by.
    let topOpId = below.map(\.opId).max() ?? OpId(lamport: 0, replica: zeroReplica)

    // Carry every delete folded into this snapshot forward as a
    // `TombstoneRecord` (ticket 05) so `materialize(onto:baseOpId:ledger:tail:)`
    // can refuse to resurrect these ids from a stale create in the tail —
    // `resolve()` drops them from `state` entirely, so `state` alone cannot
    // answer "was this id ever deleted?" once compacted.
    var records: [TombstoneRecord] = []
    for logged in below {
        switch logged.op {
        case .deleteTile(let id):
            records.append(TombstoneRecord(entityId: id, deleteOpId: logged.opId, entityKind: .tile))
        case .deleteZone(let id):
            records.append(TombstoneRecord(entityId: id, deleteOpId: logged.opId, entityKind: .zone))
        default:
            break
        }
    }
    // Sort deterministically (I4): `below` carries whatever order the caller
    // passed `log` in, which `materialize` itself never assumes is sorted —
    // the ledger's wire bytes must not depend on that incidental order.
    records.sort { lhs, rhs in
        lhs.entityId.uuidString == rhs.entityId.uuidString
            ? lhs.deleteOpId < rhs.deleteOpId
            : lhs.entityId.uuidString < rhs.entityId.uuidString
    }
    let ledger = CompactionLedger(records: records, compactedThrough: topOpId)

    let snapshot = CompactedSnapshot(compactionOpId: topOpId, state: materialize(ops: below), ledger: ledger)
    return CompactionResult(snapshot: snapshot, tail: tail)
}

/// Merges a received snapshot into a replica's local log: drops any local op
/// already folded into `snapshot` (at or below `snapshot.compactionOpId`,
/// compared by the FULL `OpId` order, not just Lamport — see ticket "Watch
/// out" on the off-by-one risk) and returns only the surviving tail. The
/// caller's new effective state is "replay `state` from `snapshot`, then fold
/// the returned tail on top" — equivalent to replaying the full log because
/// `materialize` is a pure fold over the same total order.
public func applySnapshot(
    _ snapshot: CompactedSnapshot,
    ontop localLog: [LoggedOp]
) -> [LoggedOp] {
    localLog.filter { $0.opId > snapshot.compactionOpId }
}
