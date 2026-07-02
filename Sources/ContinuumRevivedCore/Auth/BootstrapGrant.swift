import Foundation
import Security

public struct BootstrapGrant: Equatable, Sendable {
    public var credential: String
    public var scopes: Scope

    public init(credential: String, scopes: Scope = .admin) {
        self.credential = credential
        self.scopes = scopes
    }

    public static func seed(scopes: Scope = .admin) throws -> BootstrapGrant {
        BootstrapGrant(credential: try AuthRandom.hex(byteCount: 32), scopes: scopes)
    }
}

enum AuthRandom {
    static let pairingAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

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
        let bytes = try bytes(count: length)
        return String(bytes.map { pairingAlphabet[Int($0) % pairingAlphabet.count] })
    }
}
