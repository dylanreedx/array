import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// Retention contract (docs/internals/collaboration.md, "Retention"). Only the
/// operation log is bounded. Membership epochs, device revocation, deleted IDs,
/// operation receipts and each operation ID's actor live as long as the area.
public struct CollaborationRetention: Sendable, Equatable {
    /// Newest committed operations always kept for cursor replay.
    public var operationTail: Int
    /// Operations younger than this are never compacted, whatever the count.
    public var operationAge: TimeInterval
    /// Compaction waits until this many operations are eligible at once.
    public var compactionBatch: Int
    /// An executable request not admitted by its host within this window is
    /// refused. The requester reconfirms under current authority with a new ID.
    public var dispatchAuthorityWindow: TimeInterval
    /// An artifact blob that no published revision names is discarded after
    /// this long, so abandoned uploads stop counting against the area quota.
    public var artifactStagingLifetime: TimeInterval
    public init(operationTail: Int = 4096, operationAge: TimeInterval = 7 * 86_400,
                compactionBatch: Int = 512, dispatchAuthorityWindow: TimeInterval = 900,
                artifactStagingLifetime: TimeInterval = 3600) {
        self.operationTail = max(0, operationTail); self.operationAge = max(0, operationAge)
        self.compactionBatch = max(1, compactionBatch); self.dispatchAuthorityWindow = max(0, dispatchAuthorityWindow)
        self.artifactStagingLifetime = max(0, artifactStagingLifetime)
    }
}

public struct CollaborationIntegrityReport: Sendable, Equatable {
    public let areas: Int
    public let retainedOperations: Int
    public let receipts: Int
    /// Area -> highest revision folded into its horizon snapshot.
    public let horizons: [UUID: UInt64]
}

extension CollaborationStore {
    static func registerRetentionMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-v6-retention") { db in
            // Dispatches queued before this schema have no admission clock and
            // are refused on first sight rather than trusted as fresh.
            try db.execute(sql: """
                ALTER TABLE operations ADD COLUMN committed DOUBLE NOT NULL DEFAULT 0;
                ALTER TABLE areas ADD COLUMN horizon INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE areas ADD COLUMN horizon_snapshot BLOB;
                CREATE TABLE operation_receipts(area TEXT NOT NULL REFERENCES areas(id), operation_id TEXT NOT NULL,
                  revision INTEGER NOT NULL, actor TEXT NOT NULL REFERENCES devices(id),
                  PRIMARY KEY(area,operation_id), UNIQUE(area,revision));
                INSERT INTO operation_receipts(area,operation_id,revision,actor) SELECT area,operation_id,revision,actor FROM operations;
                ALTER TABLE agent_dispatches ADD COLUMN created DOUBLE NOT NULL DEFAULT 0;
                """)
        }
    }

    /// Operator seam; `apply` runs the same step after each committed command.
    @discardableResult
    public func compact(area: UUID) throws -> UInt64 {
        try database.write { db in try compactIfDue(db, area: area) }
    }

    /// One transaction: the folded snapshot and its horizon commit before any
    /// covered operation is retired. Returns the horizon after the step.
    func compactIfDue(_ db: Database, area: UUID) throws -> UInt64 {
        guard let row = try Row.fetchOne(db, sql: "SELECT revision,horizon,horizon_snapshot FROM areas WHERE id=?", arguments: [area.uuidString]) else { throw CollaborationStoreError.unavailable }
        let head: Int64 = row["revision"], horizon: Int64 = row["horizon"]
        let cutoff = clock().timeIntervalSince1970 - retention.operationAge
        var through = head - Int64(retention.operationTail)
        // Age bounds the whole prefix: stop below the first young operation.
        if let young = try Int64.fetchOne(db, sql: "SELECT MIN(revision) FROM operations WHERE area=? AND revision>? AND committed>?",
                                          arguments: [area.uuidString, horizon, cutoff]) { through = min(through, young - 1) }
        guard through - horizon >= Int64(retention.compactionBatch) else { return UInt64(horizon) }
        var folded = try horizonDocument(db, area: area, horizon: horizon, sealed: row["horizon_snapshot"] as Data?)
        try replay(db, area: area, after: horizon, through: through, into: &folded)
        try db.execute(sql: "UPDATE areas SET horizon=?,horizon_snapshot=? WHERE id=?",
            arguments: [through, try seal(folded), area.uuidString])
        try db.execute(sql: "DELETE FROM operations WHERE area=? AND revision<=?", arguments: [area.uuidString, through])
        return UInt64(through)
    }

    /// Every area's horizon snapshot plus its retained tail must reproduce the
    /// stored head exactly, with one receipt per revision and no gap.
    public func verifyIntegrity() throws -> CollaborationIntegrityReport {
        try database.read { db in
            var horizons: [UUID: UInt64] = [:], operations = 0, receipts = 0
            let rows = try Row.fetchAll(db, sql: "SELECT id,revision,horizon,snapshot,horizon_snapshot FROM areas")
            for row in rows {
                guard let area = UUID(uuidString: row["id"]) else { throw CollaborationStoreError.integrityFailure }
                let head: Int64 = row["revision"], horizon: Int64 = row["horizon"]
                let stored = try unseal(SharedArea.Document.self, row["snapshot"])
                guard stored.id.rawValue == area, stored.revision == UInt64(head), horizon <= head else { throw CollaborationStoreError.integrityFailure }
                var rebuilt = try horizonDocument(db, area: area, horizon: horizon, sealed: row["horizon_snapshot"] as Data?)
                try replay(db, area: area, after: horizon, through: head, into: &rebuilt)
                guard try rebuilt.canonicalData() == stored.canonicalData() else { throw CollaborationStoreError.integrityFailure }
                let below = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operations WHERE area=? AND revision<=?", arguments: [area.uuidString, horizon])!
                let tail = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operations WHERE area=?", arguments: [area.uuidString])!
                let bound = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n,MIN(revision) AS low,MAX(revision) AS high FROM operation_receipts WHERE area=?", arguments: [area.uuidString])!
                let count: Int64 = bound["n"]
                guard below == 0, count == head, head == 0 || (bound["low"] as Int64? == 1 && bound["high"] as Int64? == head) else { throw CollaborationStoreError.integrityFailure }
                horizons[area] = UInt64(horizon); operations += tail; receipts += Int(count)
            }
            return .init(areas: rows.count, retainedOperations: operations, receipts: receipts, horizons: horizons)
        }
    }

    /// An executable request that has not crossed host admission within the
    /// authority window is refused. `dispatching` and later phases belong to
    /// the host's recorded attempt and are never rewritten here.
    func expireDispatches(_ db: Database, area: UUID) throws {
        try db.execute(sql: "UPDATE agent_dispatches SET phase='refused' WHERE area=? AND phase IN ('queued','claimed') AND created<=?",
            arguments: [area.uuidString, clock().timeIntervalSince1970 - retention.dispatchAuthorityWindow])
    }

    private func horizonDocument(_ db: Database, area: UUID, horizon: Int64, sealed: Data?) throws -> SharedArea.Document {
        guard let sealed else {
            guard horizon == 0 else { throw CollaborationStoreError.integrityFailure }
            return SharedArea.Document(id: .init(area))
        }
        let document = try unseal(SharedArea.Document.self, sealed)
        guard document.id.rawValue == area, document.revision == UInt64(horizon) else { throw CollaborationStoreError.integrityFailure }
        return document
    }
    private func replay(_ db: Database, area: UUID, after: Int64, through: Int64, into document: inout SharedArea.Document) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT revision,command FROM operations WHERE area=? AND revision>? AND revision<=? ORDER BY revision",
            arguments: [area.uuidString, after, through])
        for row in rows {
            let revision: Int64 = row["revision"]
            let command = try unseal(SharedArea.Command.self, row["command"])
            guard Int64(document.revision) + 1 == revision,
                  try document.apply(command) == .applied(UInt64(revision)) else { throw CollaborationStoreError.integrityFailure }
        }
        guard document.revision == UInt64(through) else { throw CollaborationStoreError.integrityFailure }
    }
}
