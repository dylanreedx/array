import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One area membership as the operator sees it: no content.
public struct CollaborationMembershipSummary: Codable, Equatable, Sendable {
    public let area: UUID
    public let role: String
    public let active: Bool
}

/// One person and every area they are, or were, a member of.
public struct CollaborationPersonDetail: Codable, Equatable, Sendable {
    public let person: UUID
    public let label: String
    public let activeDevices: Int
    public let memberships: [CollaborationMembershipSummary]
}

/// What an operator deletion removed, counted, never listed.
public struct CollaborationDeletionReport: Codable, Equatable, Sendable {
    public let id: UUID
    public let rows: Int
}

public enum CollaborationDeletionError: Error, Equatable {
    /// The person still has history, or is the only owner, in these areas.
    /// Delete the areas first; a person never takes a teammate's work with them.
    case personHasAreas([UUID])
}

/// Operator deletion of throwaway people and areas, and a member leaving an
/// area on their own. Rows that hang off an area or a person go in the same
/// transaction as the row itself, so nothing is left behind half-deleted.
extension CollaborationStore {
    /// Tables whose rows belong to one area, children before parents. The
    /// share-link tables hang off `share_links`, so they go first.
    /// `--deletion-only` checks that this list covers every table that
    /// references `areas`, so a new area table cannot be missed silently.
    public static let areaOwnedTables = [
        "collaboration_agent_projection", "host_liveness_retired", "host_liveness",
        "collaboration_artifact_reviews", "collaboration_artifact_revisions", "collaboration_artifact_blobs",
        "collaboration_usage", "agent_dispatches", "agent_control_operations", "agent_control",
        "operation_receipts", "operations", "invitations", "members",
    ]
    /// Area-scoped tables that record a device or host's work. A row here in an
    /// area that stays is the person's history in a teammate's area.
    public static let deviceHistoryColumns: [(table: String, column: String, references: String)] = [
        ("operations", "actor", "devices"), ("operation_receipts", "actor", "devices"),
        ("agent_control_operations", "actor", "devices"), ("agent_dispatches", "actor", "devices"),
        ("agent_dispatches", "host", "hosts"), ("collaboration_usage", "device", "devices"),
        ("collaboration_usage", "host", "hosts"), ("collaboration_artifact_blobs", "uploader", "devices"),
        ("collaboration_agent_projection", "device", "devices"), ("collaboration_agent_projection", "host", "hosts"),
        ("host_liveness", "host", "hosts"), ("host_liveness_retired", "host", "hosts"),
        ("share_links", "issuer", "devices"),
    ]

    public func operatorPerson(_ person: UUID) throws -> CollaborationPersonDetail {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.label, (SELECT COUNT(*) FROM devices d WHERE d.person=p.id AND d.revoked=0) AS devices
                FROM people p WHERE p.id=?
                """, arguments: [person.uuidString]) else { throw CollaborationStoreError.unavailable }
            let memberships = try Row.fetchAll(db, sql: "SELECT area,role,active FROM members WHERE person=? ORDER BY area",
                                               arguments: [person.uuidString]).map {
                CollaborationMembershipSummary(area: UUID(uuidString: $0["area"])!, role: $0["role"], active: ($0["active"] as Int) != 0)
            }
            return .init(person: person, label: row["label"], activeDevices: row["devices"], memberships: memberships)
        }
    }

    /// Deletes an area and everything that belongs to it: membership, history,
    /// links, artifacts, agent state. Open lanes, presence and waiters close.
    public func operatorDeleteArea(_ area: UUID) throws -> CollaborationDeletionReport {
        let (rows, people): (Int, [UUID]) = try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM areas WHERE id=?", arguments: [area.uuidString]) == 1 else {
                throw CollaborationStoreError.unavailable
            }
            let people = try String.fetchAll(db, sql: "SELECT person FROM members WHERE area=?", arguments: [area.uuidString]).compactMap(UUID.init(uuidString:))
            var rows = 0
            for table in ["share_link_joins", "share_link_admissions"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE link IN (SELECT id FROM share_links WHERE area=?)", arguments: [area.uuidString])
                rows += db.changesCount
            }
            try db.execute(sql: "DELETE FROM share_links WHERE area=?", arguments: [area.uuidString]); rows += db.changesCount
            for table in Self.areaOwnedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE area=?", arguments: [area.uuidString]); rows += db.changesCount
            }
            try db.execute(sql: "DELETE FROM areas WHERE id=?", arguments: [area.uuidString]); rows += db.changesCount
            return (rows, people)
        }
        forgetArea(area, people: people)
        return .init(id: area, rows: rows)
    }

    /// Deletes a person: their memberships, devices, hosts, enrollments and
    /// pending invitations. Refuses, changing nothing, while an area that
    /// stays holds their history or has them as its only owner.
    public func operatorDeletePerson(_ person: UUID) throws -> CollaborationDeletionReport {
        let id = person.uuidString
        let (rows, devices, areas): (Int, [UUID], [UUID]) = try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people WHERE id=?", arguments: [id]) == 1 else {
                throw CollaborationStoreError.unavailable
            }
            let devices = "SELECT id FROM devices WHERE person=?", hosts = "SELECT id FROM hosts WHERE device IN (\(devices))"
            var blocking = Set<String>()
            for entry in Self.deviceHistoryColumns {
                let owned = entry.references == "devices" ? devices : hosts
                blocking.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT area FROM \(entry.table) WHERE \(entry.column) IN (\(owned))", arguments: [id]))
            }
            blocking.formUnion(try String.fetchAll(db, sql: """
                SELECT m.area FROM members m WHERE m.person=? AND m.active=1 AND m.role='owner'
                  AND NOT EXISTS (SELECT 1 FROM members o WHERE o.area=m.area AND o.person<>m.person AND o.active=1 AND o.role='owner')
                """, arguments: [id]))
            guard blocking.isEmpty else {
                throw CollaborationDeletionError.personHasAreas(blocking.compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString })
            }
            let deviceIDs = try String.fetchAll(db, sql: devices, arguments: [id]).compactMap(UUID.init(uuidString:))
            let activeAreas = try String.fetchAll(db, sql: "SELECT area FROM members WHERE person=? AND active=1", arguments: [id])
            var rows = 0
            // Leaving an area moves its epoch on, as removal does, so a
            // teammate's queued command cannot land against the old roster.
            try db.execute(sql: "UPDATE areas SET epoch=epoch+1 WHERE id IN (SELECT area FROM members WHERE person=? AND active=1)", arguments: [id])
            for sql in [
                "DELETE FROM share_link_admissions WHERE person=?",
                "DELETE FROM invitations WHERE person=? OR issuer IN (\(devices))",
                "DELETE FROM members WHERE person=?",
                "DELETE FROM enrollments WHERE person=? OR issuer_device IN (\(devices))",
                "DELETE FROM hosts WHERE device IN (\(devices))",
                "DELETE FROM devices WHERE person=?",
                "DELETE FROM people WHERE id=?",
            ] {
                let count = sql.components(separatedBy: "?").count - 1
                try db.execute(sql: sql, arguments: StatementArguments(Array(repeating: id, count: count)))
                rows += db.changesCount
            }
            return (rows, deviceIDs, activeAreas.compactMap(UUID.init(uuidString:)))
        }
        for device in devices { invalidateDevice(device) }
        for area in areas { invalidateMember(area: area, person: person) }
        return .init(id: person, rows: rows)
    }

    /// A member leaves an area on their own. The area's only owner cannot
    /// leave it: that would strand everyone else in an area nobody manages.
    public func leaveArea(token: String, area: UUID) throws {
        let person: UUID = try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            let person = caller.person.rawValue.uuidString
            if current.role == .owner {
                let owners = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM members WHERE area=? AND role='owner' AND active=1", arguments: [area.uuidString]) ?? 0
                guard owners > 1 else { throw CollaborationStoreError.forbidden }
            }
            try db.execute(sql: "UPDATE members SET active=0 WHERE area=? AND person=?", arguments: [area.uuidString, person])
            try closeShareLinkAdmissions(db, area: area, person: caller.person.rawValue)
            try db.execute(sql: "UPDATE areas SET epoch=epoch+1 WHERE id=?", arguments: [area.uuidString])
            return caller.person.rawValue
        }
        invalidateMember(area: area, person: person)
    }

    /// In-memory state of a deleted area: lanes and presence close, waiters
    /// wake (and then find the area gone).
    private func forgetArea(_ area: UUID, people: [UUID]) {
        for person in people { invalidateMember(area: area, person: person) }
        closeCursorLanes { $0.area == area }
        closeTileStreams { $0.area == area }
        for key in presenceEntries.keys.filter({ $0.area == area }) {
            presenceFlushes.removeValue(forKey: key)?.cancel()
            presenceEntries.removeValue(forKey: key)
        }
        hostLivenessStates[area] = nil
        presenceVersions[area] = nil
        wakeArea(area)
    }
}
