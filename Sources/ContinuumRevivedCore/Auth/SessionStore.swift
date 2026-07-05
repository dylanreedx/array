import CryptoKit
import Darwin
import Foundation
import GRDB

public struct AuthSession: Equatable, Sendable {
    public var id: UUID
    public var subject: String
    public var scopes: Scope
    public var issuedAt: Date
    public var expiresAt: Date
    public var token: String

    public init(id: UUID, subject: String, scopes: Scope, issuedAt: Date, expiresAt: Date, token: String) {
        self.id = id
        self.subject = subject
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.token = token
    }
}

public actor SessionStore {
    private struct Claims: Codable {
        var sid: UUID
        var sub: String
        var scopes: Int
        var iat: TimeInterval
        var exp: TimeInterval
    }

    private let clock: any Clock
    private let signingKey: SymmetricKey
    private let dbQueue: DatabaseQueue

    public init(signingKey: Data, clock: any Clock = SystemClock(), databaseURL: URL? = nil) throws {
        self.signingKey = SymmetricKey(data: signingKey)
        self.clock = clock
        self.dbQueue = try AuthDatabase.queue(at: databaseURL)
        try Self.prepare(dbQueue)
    }

    public init(signingKey: Data, clock: any Clock = SystemClock()) {
        self.signingKey = SymmetricKey(data: signingKey)
        self.clock = clock
        self.dbQueue = try! AuthDatabase.queue(at: nil)
        try! Self.prepare(dbQueue)
    }

    public static func loadOrCreateSigningKey(in authDirectory: URL, fileManager: FileManager = .default) throws -> Data {
        try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let keyURL = authDirectory.appendingPathComponent("signing.key")
        if fileManager.fileExists(atPath: keyURL.path) {
            return try Data(contentsOf: keyURL)
        }

        let bytes = try AuthRandom.bytes(count: 32)
        let fd = open(keyURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AuthError.unknown }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { throw AuthError.unknown }
        chmod(keyURL.path, S_IRUSR | S_IWUSR)
        return Data(bytes)
    }

    public func issue(scopes: Scope, subject: String, ttl: TimeInterval) throws -> AuthSession {
        let now = clock.now()
        let id = UUID()
        let expiresAt = now.addingTimeInterval(ttl)
        let claims = Claims(
            sid: id,
            sub: subject,
            scopes: scopes.rawValue,
            iat: now.timeIntervalSince1970,
            exp: expiresAt.timeIntervalSince1970
        )
        let token = try token(for: claims)
        let session = AuthSession(id: id, subject: subject, scopes: scopes, issuedAt: now, expiresAt: expiresAt, token: token)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO auth_sessions
                    (id, subject, scopes, issued_at, expires_at, token, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [
                    id.uuidString,
                    subject,
                    scopes.rawValue,
                    now.timeIntervalSince1970,
                    expiresAt.timeIntervalSince1970,
                    token
                ]
            )
        }
        return session
    }

    public func exchange(
        credential: String,
        requested: Scope,
        subject: String,
        ttl: TimeInterval = 3_600,
        pairingStore: PairingStore
    ) async throws -> AuthSession {
        let grant = try await pairingStore.consume(credential)
        guard requested.isSubset(of: grant.scopes) else { throw AuthError.scopeNotGranted }
        return try issue(scopes: requested, subject: subject, ttl: ttl)
    }

    public func verify(_ token: String) throws -> AuthSession {
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let payload = Data(base64URLEncoded: parts[0]),
              let mac = Data(base64URLEncoded: parts[1]) else {
            throw AuthError.invalidToken
        }

        let expectedPayload = Data(parts[0].utf8)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: expectedPayload, using: signingKey) else {
            throw AuthError.invalidToken
        }

        let claims = try JSONDecoder().decode(Claims.self, from: payload)
        guard claims.exp > clock.now().timeIntervalSince1970 else { throw AuthError.expired }
        guard let row = try dbQueue.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM auth_sessions WHERE id = ?", arguments: [claims.sid.uuidString])
        }) else {
            throw AuthError.revoked
        }
        guard (row["revoked_at"] as Double?) == nil else { throw AuthError.revoked }
        return try Self.session(from: row)
    }

    public func revoke(id: UUID) {
        let now = clock.now()
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE auth_sessions SET revoked_at = ? WHERE id = ?",
                arguments: [now.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    public func revokeAll(except kept: UUID? = nil) {
        let now = clock.now()
        try? dbQueue.write { db in
            if let kept {
                try db.execute(
                    sql: "UPDATE auth_sessions SET revoked_at = ? WHERE id <> ?",
                    arguments: [now.timeIntervalSince1970, kept.uuidString]
                )
            } else {
                try db.execute(
                    sql: "UPDATE auth_sessions SET revoked_at = ?",
                    arguments: [now.timeIntervalSince1970]
                )
            }
        }
    }

    private static func prepare(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS auth_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                subject TEXT NOT NULL,
                scopes INTEGER NOT NULL,
                issued_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                token TEXT NOT NULL,
                revoked_at REAL
            )
            """)
        }
    }

    private static func session(from row: Row) throws -> AuthSession {
        guard let id = UUID(uuidString: row["id"] as String) else { throw AuthError.invalidToken }
        return AuthSession(
            id: id,
            subject: row["subject"] as String,
            scopes: Scope(rawValue: row["scopes"] as Int),
            issuedAt: Date(timeIntervalSince1970: row["issued_at"] as Double),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"] as Double),
            token: row["token"] as String
        )
    }

    private func token(for claims: Claims) throws -> String {
        let payloadData = try JSONEncoder().encode(claims)
        let payload = payloadData.base64URLEncodedString()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: signingKey)
        return payload + "." + Data(mac).base64URLEncodedString()
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }
}
