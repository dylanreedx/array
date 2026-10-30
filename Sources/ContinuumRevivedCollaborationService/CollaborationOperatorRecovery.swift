import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One person as the operator sees them: no tokens, codes or area content.
public struct CollaborationPersonSummary: Codable, Equatable, Sendable {
    public let person: UUID
    public let label: String
    public let activeDevices: Int
    public let areas: Int
}

/// Existing-account recovery for a person with no remaining authenticated
/// device. Creating a new person is not recovery: memberships, ownership and
/// published sources belong to the original person ID.
extension CollaborationStore {
    public func operatorPeople() throws -> [CollaborationPersonSummary] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.label,
                  (SELECT COUNT(*) FROM devices d WHERE d.person=p.id AND d.revoked=0) AS devices,
                  (SELECT COUNT(*) FROM members m WHERE m.person=p.id AND m.active<>0) AS areas
                FROM people p ORDER BY p.label, p.id
                """).map { .init(person: UUID(uuidString: $0["id"])!, label: $0["label"], activeDevices: $0["devices"], areas: $0["areas"]) }
        }
    }

    /// Revokes every device of `person` (they are presumed lost) and issues one
    /// short-lived enrollment for the same person, in one transaction.
    public func operatorRecoverPerson(_ person: UUID, lifetime: TimeInterval = 600) throws -> (enrollment: Collaboration.Enrollment, revokedDevices: [UUID]) {
        guard lifetime.isFinite, lifetime > 0, lifetime <= 86400 else { throw CollaborationStoreError.invalidRequest }
        let code = Self.secret(), expires = clock().addingTimeInterval(lifetime)
        let revoked: [UUID] = try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people WHERE id=?", arguments: [person.uuidString]) == 1 else {
                throw CollaborationStoreError.unavailable
            }
            let devices = try String.fetchAll(db, sql: "SELECT id FROM devices WHERE person=? AND revoked=0", arguments: [person.uuidString])
            try db.execute(sql: "UPDATE devices SET revoked=1 WHERE person=?", arguments: [person.uuidString])
            // Outstanding self-issued enrollments from the lost devices die too.
            try db.execute(sql: "UPDATE enrollments SET consumed=1 WHERE person=? AND consumed=0", arguments: [person.uuidString])
            try insertEnrollment(db, person: person.uuidString, code: code, expires: expires, issuer: nil)
            return devices.compactMap(UUID.init(uuidString:))
        }
        for device in revoked { invalidateDevice(device) }
        return (.init(person: .init(person), code: code, expiresAt: expires), revoked)
    }
}
