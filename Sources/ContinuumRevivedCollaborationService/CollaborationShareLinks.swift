import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// Bearer share links. Unlike a person-targeted invitation, a link admits
/// whoever holds its token, as an editor. The slug is unique among live links
/// on this relay; only the token's hash is stored.
extension CollaborationStore {
    static func registerShareLinkMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-share-links-v1") { db in
            try db.execute(sql: """
                CREATE TABLE share_links(id TEXT PRIMARY KEY NOT NULL, area TEXT NOT NULL REFERENCES areas(id),
                  slug TEXT NOT NULL, token_hash BLOB UNIQUE NOT NULL, role TEXT NOT NULL, lifetime TEXT NOT NULL,
                  issuer TEXT NOT NULL REFERENCES devices(id), created DOUBLE NOT NULL,
                  spent INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0);
                CREATE UNIQUE INDEX share_links_live_slug ON share_links(slug) WHERE revoked=0 AND spent=0;
                CREATE TABLE share_link_admissions(link TEXT NOT NULL REFERENCES share_links(id),
                  person TEXT NOT NULL REFERENCES people(id), admitted DOUBLE NOT NULL,
                  removed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(link,person));
                """)
        }
    }

    public func createShareLink(token: String, area: UUID, request: Collaboration.ShareLinkRequest) throws -> Collaboration.ShareLink {
        guard ShareLinkURL.isValidSlug(request.slug) else { throw CollaborationStoreError.invalidRequest }
        let secret = Self.linkSecret(), id = UUID(), now = clock()
        return try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.allows(.manageSharing) else { throw CollaborationStoreError.forbidden }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM share_links WHERE slug=? AND revoked=0 AND spent=0)",
                                    arguments: [request.slug]) == false else { throw CollaborationStoreError.slugTaken }
            try db.execute(sql: "INSERT INTO share_links(id,area,slug,token_hash,role,lifetime,issuer,created) VALUES (?,?,?,?,?,?,?,?)",
                arguments: [id.uuidString, area.uuidString, request.slug, Self.hash(secret), Collaboration.Role.editor.rawValue,
                            request.lifetime.rawValue, caller.device.uuidString, now.timeIntervalSince1970])
            return .init(id: id, area: .init(area), slug: request.slug, token: secret, lifetime: request.lifetime, createdAt: now)
        }
    }

    /// Admits the caller as an editor. The person a link already admitted can
    /// open it again to recover their membership; nobody can use a spent,
    /// revoked or orphaned link, and a removed person cannot return through it.
    public func acceptShareLink(token: String, request: Collaboration.AcceptShareLink) throws -> Collaboration.Scope {
        guard ShareLinkURL.isValidSlug(request.slug), ShareLinkURL.isValidToken(request.token) else { throw CollaborationStoreError.invalidInvitation }
        return try database.write { db in
            let caller = try authenticate(db, token), person = caller.person.rawValue.uuidString
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM share_links WHERE slug=? AND token_hash=?",
                                             arguments: [request.slug, Self.hash(request.token)]),
                  row["revoked"] as Int == 0 else { throw CollaborationStoreError.invalidInvitation }
            let link: String = row["id"], area = UUID(uuidString: row["area"])!, issuer: String = row["issuer"]
            // The link speaks for its creator only while they may still share.
            guard let issuerRow = try Row.fetchOne(db, sql: "SELECT person FROM devices WHERE id=? AND revoked=0", arguments: [issuer]),
                  let authority = try? scope(db, .init(person: SharedArea.ID(UUID(uuidString: issuerRow["person"])!), device: UUID(uuidString: issuer)!), area),
                  authority.allows(.manageSharing) else { throw CollaborationStoreError.invalidInvitation }
            if let removed = try Int.fetchOne(db, sql: "SELECT removed FROM share_link_admissions WHERE link=? AND person=?", arguments: [link, person]) {
                guard removed == 0, let current = try? scope(db, caller, area) else { throw CollaborationStoreError.invalidInvitation }
                return current
            }
            // Already in the area another way: nothing to grant, nothing spent.
            if let current = try? scope(db, caller, area) { return current }
            guard row["spent"] as Int == 0 else { throw CollaborationStoreError.invalidInvitation }
            try db.execute(sql: "INSERT INTO members(area,person,role,active) VALUES (?,?,?,1) ON CONFLICT(area,person) DO UPDATE SET role=excluded.role,active=1",
                arguments: [area.uuidString, person, row["role"] as String])
            try db.execute(sql: "INSERT INTO share_link_admissions(link,person,admitted) VALUES (?,?,?)",
                arguments: [link, person, clock().timeIntervalSince1970])
            if row["lifetime"] as String == Collaboration.ShareLinkLifetime.once.rawValue {
                try db.execute(sql: "UPDATE share_links SET spent=1 WHERE id=?", arguments: [link])
            }
            return try scope(db, caller, area)
        }
    }

    public func shareLinks(token: String, area: UUID) throws -> [Collaboration.ShareLinkAccess] {
        try database.read { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.allows(.manageSharing) else { throw CollaborationStoreError.forbidden }
            return try Row.fetchAll(db, sql: "SELECT id,slug,lifetime,spent,revoked,created FROM share_links WHERE area=? ORDER BY created,rowid",
                                    arguments: [area.uuidString]).map { row in
                let id: String = row["id"]
                let people = try Row.fetchAll(db, sql: """
                    SELECT s.person,p.label,s.admitted,s.removed,COALESCE(m.active,0) AS active FROM share_link_admissions s
                    JOIN people p ON p.id=s.person LEFT JOIN members m ON m.area=? AND m.person=s.person
                    WHERE s.link=? ORDER BY s.admitted,s.rowid
                    """, arguments: [area.uuidString, id]).map { person in
                    Collaboration.ShareLinkPerson(person: SharedArea.ID(UUID(uuidString: person["person"])!), label: person["label"],
                        admittedAt: Date(timeIntervalSince1970: person["admitted"]),
                        active: person["removed"] as Int == 0 && person["active"] as Int == 1)
                }
                let status: Collaboration.ShareLinkAccess.Status = row["revoked"] as Int == 1 ? .revoked : row["spent"] as Int == 1 ? .used : .active
                return .init(id: UUID(uuidString: id)!, area: .init(area), slug: row["slug"],
                             lifetime: Collaboration.ShareLinkLifetime(rawValue: row["lifetime"]) ?? .once, status: status,
                             createdAt: Date(timeIntervalSince1970: row["created"]), people: people)
            }
        }
    }

    /// Revokes the link and removes everyone it admitted.
    public func revokeShareLink(token: String, area: UUID, link: UUID) throws {
        let cut: [UUID] = try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.allows(.manageSharing) else { throw CollaborationStoreError.forbidden }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM share_links WHERE id=? AND area=?)",
                                    arguments: [link.uuidString, area.uuidString]) == true else { throw CollaborationStoreError.unavailable }
            try db.execute(sql: "UPDATE share_links SET revoked=1 WHERE id=?", arguments: [link.uuidString])
            let people = try String.fetchAll(db, sql: "SELECT person FROM share_link_admissions WHERE link=? AND removed=0 AND person<>?",
                                             arguments: [link.uuidString, caller.person.rawValue.uuidString])
            for person in people { try cutLinkAdmission(db, area: area, link: link, person: person) }
            if !people.isEmpty { try db.execute(sql: "UPDATE areas SET epoch=epoch+1 WHERE id=?", arguments: [area.uuidString]) }
            return people.compactMap(UUID.init(uuidString:))
        }
        for person in cut { invalidateMember(area: area, person: person) }
    }

    /// Removes one person admitted through the link; they cannot reopen it.
    public func removeShareLinkPerson(token: String, area: UUID, link: UUID, person: UUID) throws {
        try database.write { db in
            let caller = try authenticate(db, token), current = try scope(db, caller, area)
            guard current.allows(.manageSharing) else { throw CollaborationStoreError.forbidden }
            guard caller.person.rawValue != person else { throw CollaborationStoreError.forbidden }
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM share_link_admissions s JOIN share_links l ON l.id=s.link
                  WHERE s.link=? AND l.area=? AND s.person=? AND s.removed=0)
                """, arguments: [link.uuidString, area.uuidString, person.uuidString]) == true else { throw CollaborationStoreError.unavailable }
            try cutLinkAdmission(db, area: area, link: link, person: person.uuidString)
            try db.execute(sql: "UPDATE areas SET epoch=epoch+1 WHERE id=?", arguments: [area.uuidString])
        }
        invalidateMember(area: area, person: person)
    }

    private func cutLinkAdmission(_ db: Database, area: UUID, link: UUID, person: String) throws {
        try db.execute(sql: "UPDATE share_link_admissions SET removed=1 WHERE link=? AND person=?", arguments: [link.uuidString, person])
        try db.execute(sql: "UPDATE members SET active=0 WHERE area=? AND person=? AND role<>'owner'", arguments: [area.uuidString, person])
    }

    /// A member removed by any route cannot walk back in through a link of
    /// that area that admitted them before.
    func closeShareLinkAdmissions(_ db: Database, area: UUID, person: UUID) throws {
        try db.execute(sql: "UPDATE share_link_admissions SET removed=1 WHERE person=? AND link IN (SELECT id FROM share_links WHERE area=?)",
                       arguments: [person.uuidString, area.uuidString])
    }

    static func linkSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
