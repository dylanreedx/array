import Foundation
import CryptoKit
import GRDB

public enum PairingGrantUses: Equatable, Sendable {
    case singleUse
    case unbounded
}

public struct PairingGrant: Equatable, Sendable {
    public var id: UUID
    public var credential: String
    public var scopes: Scope
    public var label: String
    public var expiresAt: Date?
    public var remainingUses: PairingGrantUses

    public init(
        id: UUID,
        credential: String,
        scopes: Scope,
        label: String,
        expiresAt: Date?,
        remainingUses: PairingGrantUses
    ) {
        self.id = id
        self.credential = credential
        self.scopes = scopes
        self.label = label
        self.expiresAt = expiresAt
        self.remainingUses = remainingUses
    }
}

public actor PairingStore {
    private let clock: any Clock
    private let bootstrapGrant: BootstrapGrant?
    private let dbQueue: DatabaseQueue

    public init(clock: any Clock = SystemClock(), bootstrapGrant: BootstrapGrant? = nil, databaseURL: URL? = nil) throws {
        self.clock = clock
        self.bootstrapGrant = bootstrapGrant
        self.dbQueue = try AuthDatabase.queue(at: databaseURL)
        try Self.prepare(dbQueue)
    }

    public init(clock: any Clock = SystemClock(), bootstrapGrant: BootstrapGrant? = nil) {
        self.clock = clock
        self.bootstrapGrant = bootstrapGrant
        self.dbQueue = try! AuthDatabase.queue(at: nil)
        try! Self.prepare(dbQueue)
    }

    public func issue(scopes: Scope, ttl: TimeInterval, label: String) throws -> PairingGrant {
        let credential = try AuthRandom.pairingCredential()
        let grant = PairingGrant(
            id: UUID(),
            credential: credential,
            scopes: scopes,
            label: label,
            expiresAt: clock.now().addingTimeInterval(ttl),
            remainingUses: .singleUse
        )
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pairing_grants
                    (id, credential, credential_digest, scopes, label, expires_at, consumed_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL, NULL)
                """,
                arguments: [
                    grant.id.uuidString,
                    grant.credential,
                    Self.digest(credential),
                    grant.scopes.rawValue,
                    grant.label,
                    grant.expiresAt?.timeIntervalSince1970
                ]
            )
        }
        return grant
    }

    public func revoke(id: UUID) {
        let now = clock.now()
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pairing_grants SET revoked_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    public func consume(_ credential: String) throws -> PairingGrant {
        if let bootstrapGrant,
           authConstantTimeEqual(Self.digest(credential), Self.digest(bootstrapGrant.credential)) {
            return PairingGrant(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000054")!,
                credential: credential,
                scopes: bootstrapGrant.scopes,
                label: "bootstrap",
                expiresAt: nil,
                remainingUses: .unbounded
            )
        }

        let now = clock.now()
        let digest = Self.digest(credential)
        return try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pairing_grants WHERE credential_digest = ?",
                arguments: [digest]
            ) else {
                throw AuthError.unknown
            }

            guard let storedDigest: Data = row["credential_digest"],
                  authConstantTimeEqual(storedDigest, digest) else {
                throw AuthError.unknown
            }
            if (row["revoked_at"] as Double?) != nil { throw AuthError.revoked }
            if (row["consumed_at"] as Double?) != nil { throw AuthError.alreadyUsed }
            if let expiresAt = row["expires_at"] as Double?, expiresAt <= now.timeIntervalSince1970 {
                throw AuthError.expired
            }

            try db.execute(
                sql: """
                UPDATE pairing_grants
                   SET consumed_at = ?
                 WHERE id = ? AND consumed_at IS NULL AND revoked_at IS NULL
                """,
                arguments: [now.timeIntervalSince1970, row["id"] as String]
            )
            guard try Int.fetchOne(db, sql: "SELECT changes()") == 1 else {
                guard let current = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM pairing_grants WHERE credential_digest = ?",
                    arguments: [digest]
                ) else {
                    throw AuthError.unknown
                }
                if (current["revoked_at"] as Double?) != nil { throw AuthError.revoked }
                if (current["consumed_at"] as Double?) != nil { throw AuthError.alreadyUsed }
                throw AuthError.unknown
            }

            return try Self.grant(from: row)
        }
    }

    private static func prepare(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS pairing_grants (
                id TEXT PRIMARY KEY NOT NULL,
                credential TEXT NOT NULL,
                credential_digest BLOB UNIQUE NOT NULL,
                scopes INTEGER NOT NULL,
                label TEXT NOT NULL,
                expires_at REAL,
                consumed_at REAL,
                revoked_at REAL
            )
            """)
        }
    }

    private static func digest(_ credential: String) -> Data {
        Data(SHA256.hash(data: Data(credential.utf8)))
    }

    private static func grant(from row: Row) throws -> PairingGrant {
        guard let id = UUID(uuidString: row["id"] as String) else { throw AuthError.unknown }
        let expiresAtSeconds = row["expires_at"] as Double?
        return PairingGrant(
            id: id,
            credential: row["credential"] as String,
            scopes: Scope(rawValue: row["scopes"] as Int),
            label: row["label"] as String,
            expiresAt: expiresAtSeconds.map { Date(timeIntervalSince1970: $0) },
            remainingUses: .singleUse
        )
    }
}
