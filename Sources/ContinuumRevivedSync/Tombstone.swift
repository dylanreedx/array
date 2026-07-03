import Foundation
import ContinuumRevivedCore

// ContinuumRevivedSync — stood up by ticket 05 (delete tombstone) per ticket 06's
// "Where it lives" layout: depends only on ContinuumRevivedCore, zero external
// deps, pure Swift. Ticket 06 (op-log apply + compaction) adds OpLog.swift /
// Compaction.swift here; this file deliberately contains NO materialize and NO
// compactor — vocabulary and policy only.
//
// The `Op.deleteTile` / `Op.deleteZone` cases live on the frozen `Op` enum in
// ContinuumRevivedCore/SpatialOp.swift (a Swift enum cannot be split across
// targets); this target owns the tombstone semantics built on top of them.

/// The delete-wins policy (ticket 05), stated once and pinned by
/// ContinuumRevivedSyncChecks so ticket 06's `materialize` has an unambiguous
/// target:
///
///   Tombstones are collected in a single pre-pass over the sorted log BEFORE
///   any field-setting op is applied, and every field-set (frame, title,
///   zIndex/zPosition, membership, zone geometry) targeting a tombstoned id is
///   dropped — REGARDLESS of its Lamport timestamp. Once a delete op exists
///   for an entity, no concurrent or later field-set resurrects it. A
///   `setTileFrame` at Lamport 100 loses to a `deleteTile` at Lamport 5.
///
/// `TombstoneSet` is derived in one pass, never authored directly: ticket 06's
/// `materialize` builds one from the sorted log and consults it in its resolve
/// step.
public struct TombstoneSet: Equatable, Sendable {
    public var tileIds: Set<UUID>
    public var zoneIds: Set<UUID>

    public init(tileIds: Set<UUID> = [], zoneIds: Set<UUID> = []) {
        self.tileIds = tileIds
        self.zoneIds = zoneIds
    }

    /// Fold one logged op in: inserts the id ONLY for the delete cases; every
    /// other op is ignored. Set insertion makes duplicate delivery of the same
    /// delete idempotent by construction.
    public mutating func absorb(_ logged: LoggedOp) {
        switch logged.op {
        case .deleteTile(let id): tileIds.insert(id)
        case .deleteZone(let id): zoneIds.insert(id)
        default: break
        }
    }

    public func isTombstoned(tileId id: UUID) -> Bool { tileIds.contains(id) }
    public func isTombstoned(zoneId id: UUID) -> Bool { zoneIds.contains(id) }
}

public enum EntityKind: String, Codable, Equatable, Sendable {
    case tile
    case zone
}

/// One tombstone a compactor must carry forward: enough for a peer that
/// reconnects with pre-compaction log entries to learn the entity is gone
/// rather than treating the missing entity as a gap. DATA TYPE ONLY in ticket
/// 05 — populated and consulted by ticket 06's compactor.
public struct TombstoneRecord: Codable, Equatable, Sendable {
    public var entityId: UUID
    public var deleteOpId: OpId
    public var entityKind: EntityKind

    public init(entityId: UUID, deleteOpId: OpId, entityKind: EntityKind) {
        self.entityId = entityId
        self.deleteOpId = deleteOpId
        self.entityKind = entityKind
    }
}

/// The ledger a compacted snapshot retains so tombstones survive compaction.
/// DATA TYPE ONLY in ticket 05 — the ticket-06 compactor writes `records` and
/// the `compactedThrough` low-water mark.
public struct CompactionLedger: Codable, Equatable, Sendable {
    public var records: [TombstoneRecord]
    /// The Lamport low-water mark of the compaction that wrote this ledger.
    public var compactedThrough: OpId

    public init(records: [TombstoneRecord], compactedThrough: OpId) {
        self.records = records
        self.compactedThrough = compactedThrough
    }
}
