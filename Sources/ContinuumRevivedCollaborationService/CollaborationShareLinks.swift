import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// Bearer share links. Unlike a person-targeted invitation, a link admits
/// whoever holds its token, as an editor. The slug is unique among live links
/// on this relay; only the token's hash is stored.
/// Newcomer joins through share links, per rolling window. Only joins that
/// would succeed count; one over either limit creates nothing.
public struct CollaborationJoinLimits: Sendable, Equatable {
    public var perLink: Int
    public var perAddress: Int
    /// Self-enrollments (first use with no account) per client address.
    public var enrollPerAddress: Int
    public var window: TimeInterval
    public init(perLink: Int = 10, perAddress: Int = 30, enrollPerAddress: Int = 10, window: TimeInterval = 3600) {
        self.perLink = perLink; self.perAddress = perAddress; self.enrollPerAddress = enrollPerAddress; self.window = window
    }
}

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

    static func registerShareLinkJoinLimitMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-share-link-joins-v1") { db in
            // The address is kept only as a hash, and only for the window.
            try db.execute(sql: """
                CREATE TABLE share_link_joins(link TEXT NOT NULL REFERENCES share_links(id), address_hash BLOB NOT NULL, joined DOUBLE NOT NULL);
                CREATE INDEX share_link_joins_link ON share_link_joins(link,joined);
                CREATE INDEX share_link_joins_address ON share_link_joins(address_hash,joined);
                """)
        }
    }

    static func registerSelfEnrollMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("collaboration-self-enroll-v1") { db in
            // The address is kept only as a hash, and only for the window.
            try db.execute(sql: """
                CREATE TABLE self_enrollments(address_hash BLOB NOT NULL, enrolled DOUBLE NOT NULL);
                CREATE INDEX self_enrollments_address ON self_enrollments(address_hash,enrolled);
                """)
        }
    }

    /// A person with no account signs themselves up: a new person and their
    /// first device, nothing else. No operator code and no area grant; the
    /// only gate is the per-address limit, checked before anything is created.
    public func selfEnroll(_ request: Collaboration.SelfEnroll, from address: String) throws -> Collaboration.Credential {
        for label in [request.displayName, request.deviceLabel] {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 120 else { throw CollaborationStoreError.invalidRequest }
        }
        let secret = Self.secret(), device = UUID(), person = SharedArea.ID<SharedArea.Person>()
        let now = clock().timeIntervalSince1970, addressHash = Self.hash(address)
        return try database.write { db in
            let since = now - joinLimits.window
            try db.execute(sql: "DELETE FROM self_enrollments WHERE enrolled<=?", arguments: [since])
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_enrollments WHERE address_hash=? AND enrolled>?",
                                   arguments: [addressHash, since])! < joinLimits.enrollPerAddress else { throw CollaborationStoreError.rateLimited }
            try db.execute(sql: "INSERT INTO self_enrollments(address_hash,enrolled) VALUES (?,?)", arguments: [addressHash, now])
            try db.execute(sql: "INSERT INTO people(id,label) VALUES (?,?)", arguments: [person.rawValue.uuidString, request.displayName])
            try db.execute(sql: "INSERT INTO devices(id,person,label,token_hash) VALUES (?,?,?,?)",
                arguments: [device.uuidString, person.rawValue.uuidString, request.deviceLabel, Self.hash(secret)])
            return .init(identity: .init(person: person, device: device), token: secret)
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
    public func acceptShareLink(token: String, request: Collaboration.AcceptShareLink,
                                readsLiveTiles: Bool = true) throws -> Collaboration.Scope {
        guard ShareLinkURL.isValidSlug(request.slug), ShareLinkURL.isValidToken(request.token) else { throw CollaborationStoreError.invalidInvitation }
        return try database.write { db in
            let caller = try authenticate(db, token), person = caller.person.rawValue.uuidString
            let link = try liveLink(db, slug: request.slug, token: request.token)
            try requireReadable(db, area: link.area, readsLiveTiles: readsLiveTiles)
            if let removed = try Int.fetchOne(db, sql: "SELECT removed FROM share_link_admissions WHERE link=? AND person=?", arguments: [link.id, person]) {
                guard removed == 0, let current = try? scope(db, caller, link.area) else { throw CollaborationStoreError.invalidInvitation }
                return current
            }
            // Already in the area another way: nothing to grant, nothing spent.
            if let current = try? scope(db, caller, link.area) { return current }
            try admit(db, link: link, person: person)
            return try scope(db, caller, link.area)
        }
    }

    /// The link's token doubles as an enrollment for someone with no account
    /// on this relay: it creates the person and their first device, admitted
    /// to this one area. Nothing else on the relay is granted.
    public func joinShareLink(_ request: Collaboration.JoinShareLink, from address: String,
                              readsLiveTiles: Bool = true) throws -> Collaboration.ShareLinkJoin {
        guard ShareLinkURL.isValidSlug(request.slug), ShareLinkURL.isValidToken(request.token) else { throw CollaborationStoreError.invalidInvitation }
        for label in [request.displayName, request.deviceLabel] {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 120 else { throw CollaborationStoreError.invalidRequest }
        }
        let secret = Self.secret(), device = UUID(), person = SharedArea.ID<SharedArea.Person>()
        let now = clock().timeIntervalSince1970, addressHash = Self.hash(address)
        return try database.write { db in
            let link = try liveLink(db, slug: request.slug, token: request.token)
            guard !link.spent else { throw CollaborationStoreError.invalidInvitation }
            try requireReadable(db, area: link.area, readsLiveTiles: readsLiveTiles)
            let since = now - joinLimits.window
            try db.execute(sql: "DELETE FROM share_link_joins WHERE joined<=?", arguments: [since])
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM share_link_joins WHERE link=? AND joined>?", arguments: [link.id, since])! < joinLimits.perLink,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM share_link_joins WHERE address_hash=? AND joined>?", arguments: [addressHash, since])! < joinLimits.perAddress
            else { throw CollaborationStoreError.rateLimited }
            try db.execute(sql: "INSERT INTO share_link_joins(link,address_hash,joined) VALUES (?,?,?)", arguments: [link.id, addressHash, now])
            try db.execute(sql: "INSERT INTO people(id,label) VALUES (?,?)", arguments: [person.rawValue.uuidString, request.displayName])
            try db.execute(sql: "INSERT INTO devices(id,person,label,token_hash) VALUES (?,?,?,?)",
                arguments: [device.uuidString, person.rawValue.uuidString, request.deviceLabel, Self.hash(secret)])
            try admit(db, link: link, person: person.rawValue.uuidString)
            let identity = Collaboration.Identity(person: person, device: device)
            return .init(credential: .init(identity: identity, token: secret), scope: try scope(db, identity, link.area))
        }
    }

    /// A client from before live tiles cannot decode an area holding one: it
    /// would be admitted, spend a "Works once" link, and then fail to load.
    /// Refused first, so nothing is created, admitted or spent.
    private func requireReadable(_ db: Database, area: UUID, readsLiveTiles: Bool) throws {
        guard !readsLiveTiles else { return }
        guard let state = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString]) else { return }
        let document = try unseal(SharedArea.Document.self, state)
        if document.items.contains(where: { $0.kind == .liveTile }) { throw CollaborationStoreError.clientTooOld }
    }

    private struct LiveLink { let id: String; let area: UUID; let role: String; let lifetime: String; let spent: Bool }
    /// A link that exists with this exact token, is not revoked, and still
    /// speaks for a creator who may share the area.
    private func liveLink(_ db: Database, slug: String, token: String) throws -> LiveLink {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM share_links WHERE slug=? AND token_hash=?",
                                         arguments: [slug, Self.hash(token)]),
              row["revoked"] as Int == 0 else { throw CollaborationStoreError.invalidInvitation }
        let area = UUID(uuidString: row["area"])!, issuer: String = row["issuer"]
        guard let issuerRow = try Row.fetchOne(db, sql: "SELECT person FROM devices WHERE id=? AND revoked=0", arguments: [issuer]),
              let authority = try? scope(db, .init(person: SharedArea.ID(UUID(uuidString: issuerRow["person"])!), device: UUID(uuidString: issuer)!), area),
              authority.allows(.manageSharing) else { throw CollaborationStoreError.invalidInvitation }
        return .init(id: row["id"], area: area, role: row["role"], lifetime: row["lifetime"], spent: row["spent"] as Int == 1)
    }
    private func admit(_ db: Database, link: LiveLink, person: String) throws {
        guard !link.spent else { throw CollaborationStoreError.invalidInvitation }
        try db.execute(sql: "INSERT INTO members(area,person,role,active) VALUES (?,?,?,1) ON CONFLICT(area,person) DO UPDATE SET role=excluded.role,active=1",
            arguments: [link.area.uuidString, person, link.role])
        try db.execute(sql: "INSERT INTO share_link_admissions(link,person,admitted) VALUES (?,?,?)",
            arguments: [link.id, person, clock().timeIntervalSince1970])
        if link.lifetime == Collaboration.ShareLinkLifetime.once.rawValue {
            try db.execute(sql: "UPDATE share_links SET spent=1 WHERE id=?", arguments: [link.id])
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
