import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// Execution-host liveness per area. Beats are persisted so a relay restart
/// keeps both the last-seen time and the retired-generation fence; a restarted
/// relay cannot let a superseded run claim to be online again.
extension CollaborationStore {
    static func registerHostLivenessMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-host-liveness-v1") { db in
            try db.execute(sql: """
                CREATE TABLE host_liveness(area TEXT NOT NULL REFERENCES areas(id), host TEXT NOT NULL REFERENCES hosts(id),
                  generation TEXT NOT NULL, sequence INTEGER NOT NULL, last_seen DOUBLE NOT NULL, ended INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(area,host));
                CREATE TABLE host_liveness_retired(area TEXT NOT NULL REFERENCES areas(id), host TEXT NOT NULL REFERENCES hosts(id),
                  generation TEXT NOT NULL, retired DOUBLE NOT NULL, PRIMARY KEY(area,host,generation));
                """)
        }
    }

    /// Only the device that registered `host`, while it is a current member of
    /// `area`, can speak for it. A beat from a retired run is a conflict; a
    /// repeated or reordered beat of the current run changes nothing.
    public func hostHeartbeat(token: String, area: UUID, host: SharedArea.ID<SharedArea.Host>,
                              beat: Collaboration.HostHeartbeat) throws -> Collaboration.HostLiveness {
        guard beat.valid else { throw CollaborationStoreError.invalidRequest }
        let now = clock()
        let result = try database.write { db -> [Collaboration.HostLiveness] in
            try requireOwnHost(db, token: token, area: area, host: host)
            let hostID = host.rawValue.uuidString, generation = beat.generation.uuidString
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM host_liveness_retired WHERE area=? AND host=? AND generation=?",
                                   arguments: [area.uuidString, hostID, generation]) == 0 else { throw SharedArea.Failure.conflict }
            if let row = try Row.fetchOne(db, sql: "SELECT generation,sequence,ended FROM host_liveness WHERE area=? AND host=?",
                                          arguments: [area.uuidString, hostID]) {
                if row["generation"] as String == generation {
                    // An ended run stays ended; a new run must mint a new generation.
                    guard row["ended"] as Int == 0 else { throw SharedArea.Failure.conflict }
                    if UInt64(row["sequence"] as Int64) < beat.sequence {
                        try db.execute(sql: "UPDATE host_liveness SET sequence=?,last_seen=? WHERE area=? AND host=?",
                            arguments: [Int64(beat.sequence), now.timeIntervalSince1970, area.uuidString, hostID])
                    }
                } else {
                    try db.execute(sql: "INSERT OR IGNORE INTO host_liveness_retired(area,host,generation,retired) VALUES (?,?,?,?)",
                        arguments: [area.uuidString, hostID, row["generation"] as String, now.timeIntervalSince1970])
                    try db.execute(sql: """
                        DELETE FROM host_liveness_retired WHERE area=? AND host=? AND rowid NOT IN
                          (SELECT rowid FROM host_liveness_retired WHERE area=? AND host=? ORDER BY retired DESC, rowid DESC LIMIT ?)
                        """, arguments: [area.uuidString, hostID, area.uuidString, hostID, Collaboration.HostLivenessPolicy.retiredGenerationLimit])
                    try db.execute(sql: "UPDATE host_liveness SET generation=?,sequence=?,last_seen=?,ended=0 WHERE area=? AND host=?",
                        arguments: [generation, Int64(beat.sequence), now.timeIntervalSince1970, area.uuidString, hostID])
                }
            } else {
                try db.execute(sql: "INSERT INTO host_liveness(area,host,generation,sequence,last_seen) VALUES (?,?,?,?,?)",
                    arguments: [area.uuidString, hostID, generation, Int64(beat.sequence), now.timeIntervalSince1970])
            }
            return try hostLiveness(db, area: area)
        }
        return result.first { $0.host == host }!
    }

    /// A clean shutdown ends exactly its own run. Ending a run that has already
    /// been superseded leaves the newer run alone.
    public func endHost(token: String, area: UUID, host: SharedArea.ID<SharedArea.Host>, generation: UUID) throws {
        try database.write { db in
            try requireOwnHost(db, token: token, area: area, host: host)
            try db.execute(sql: "UPDATE host_liveness SET ended=1 WHERE area=? AND host=? AND generation=?",
                arguments: [area.uuidString, host.rawValue.uuidString, generation.uuidString])
            _ = try hostLiveness(db, area: area)
        }
    }

    private func requireOwnHost(_ db: Database, token: String, area: UUID, host: SharedArea.ID<SharedArea.Host>) throws {
        let caller = try authenticate(db, token)
        _ = try scope(db, caller, area)
        guard try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [host.rawValue.uuidString])
                == caller.device.uuidString else { throw CollaborationStoreError.forbidden }
    }

    /// The area's projection at the store clock. Any change of run or state
    /// since the last projection bumps the area's presence version and wakes
    /// held readers; time-driven transitions are caught when a held read wakes
    /// at `nextHostTransition`.
    func hostLiveness(_ db: Database, area: UUID) throws -> [Collaboration.HostLiveness] {
        let now = clock()
        let rows = try Row.fetchAll(db, sql: """
            SELECT l.host,l.generation,l.last_seen,l.ended,d.revoked,
              (SELECT m.active FROM members m WHERE m.area=l.area AND m.person=d.person) AS active
            FROM host_liveness l JOIN hosts h ON h.id=l.host JOIN devices d ON d.id=h.device
            WHERE l.area=? ORDER BY l.host
            """, arguments: [area.uuidString])
        let projection = rows.map { row in
            Collaboration.HostLiveness.evaluate(host: .init(UUID(uuidString: row["host"])!),
                generation: UUID(uuidString: row["generation"])!, lastSeen: Date(timeIntervalSince1970: row["last_seen"]),
                ended: row["ended"] as Int != 0, accessRemoved: row["revoked"] as Int != 0 || (row["active"] as Int?) != 1, now: now)
        }
        let observed = Dictionary(uniqueKeysWithValues: projection.map { ($0.host.rawValue, "\($0.generation)/\($0.state.rawValue)") })
        if hostLivenessStates[area] != observed {
            hostLivenessStates[area] = observed
            presenceChanged(area)
        }
        return projection
    }

    static func nextHostTransition(_ hosts: [Collaboration.HostLiveness]?, after now: Date) -> Date? {
        hosts?.compactMap { $0.nextTransition(after: now) }.min()
    }
}
