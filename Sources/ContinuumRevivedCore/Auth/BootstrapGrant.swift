import Foundation
import Security

public struct BootstrapGrant: Equatable, Sendable {
    public var credential: String
    public var scopes: Scope
    public var expiresAt: Date?

    public init(credential: String, scopes: Scope = .admin, expiresAt: Date? = nil) {
        self.credential = credential
        self.scopes = scopes
        self.expiresAt = expiresAt
    }

    public static func seed(scopes: Scope = .admin, ttl: TimeInterval? = 86_400, now: Date = Date()) throws -> BootstrapGrant {
        BootstrapGrant(
            credential: try AuthRandom.hex(byteCount: 32),
            scopes: scopes,
            expiresAt: ttl.map { now.addingTimeInterval($0) }
        )
    }
}

enum AuthRandom {
    static func bytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AuthError.unknown }
        return bytes
    }

    static func hex(byteCount: Int) throws -> String {
        try bytes(count: byteCount).map { String(format: "%02x", $0) }.joined()
    }

    static func pairingCredential(length: Int = 12) throws -> String {
        try PairingAlphabet.credential(length: length)
    }
}
