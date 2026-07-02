import CryptoKit
import Darwin
import Foundation

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
    private struct SessionRow: Sendable {
        var session: AuthSession
        var revokedAt: Date?
    }

    private struct Claims: Codable {
        var sid: UUID
        var sub: String
        var scopes: Int
        var iat: TimeInterval
        var exp: TimeInterval
    }

    private let clock: any Clock
    private let signingKey: SymmetricKey
    private var rows: [UUID: SessionRow] = [:]

    public init(signingKey: Data, clock: any Clock = SystemClock()) {
        self.signingKey = SymmetricKey(data: signingKey)
        self.clock = clock
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
        rows[id] = SessionRow(session: session, revokedAt: nil)
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
        guard let row = rows[claims.sid] else { throw AuthError.revoked }
        guard row.revokedAt == nil else { throw AuthError.revoked }
        return row.session
    }

    public func revoke(id: UUID) {
        rows[id]?.revokedAt = clock.now()
    }

    public func revokeAll(except kept: UUID? = nil) {
        let now = clock.now()
        for id in rows.keys where id != kept {
            rows[id]?.revokedAt = now
        }
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
