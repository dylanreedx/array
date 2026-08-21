import CryptoKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

public enum TranscriptSyncProtocol {
    public static let version = 1
}

public enum TranscriptSyncContent: Codable, Equatable, Sendable {
    case snapshot(AgentDocument)
    case mutations(baseVersion: UInt64, values: [AgentDocumentMutation])
}

public struct TranscriptPlainEnvelope: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var agentID: UUID
    public var sessionID: String
    public var documentVersion: UInt64
    public var createdAt: Date
    public var content: TranscriptSyncContent

    public init(
        protocolVersion: Int = TranscriptSyncProtocol.version,
        agentID: UUID,
        sessionID: String,
        documentVersion: UInt64,
        createdAt: Date = Date(),
        content: TranscriptSyncContent
    ) {
        self.protocolVersion = protocolVersion
        self.agentID = agentID
        self.sessionID = sessionID
        self.documentVersion = documentVersion
        self.createdAt = createdAt
        self.content = content
    }
}

/// Ciphertext-only wire shape. Session text stays encrypted; its SHA-256 digest
/// authenticates routing without disclosing the provider's session identifier.
public struct EncryptedTranscriptEnvelope: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var keyID: UUID
    public var agentID: UUID
    public var sessionDigest: Data
    public var documentVersion: UInt64
    public var combinedCiphertext: Data

    public init(
        protocolVersion: Int = TranscriptSyncProtocol.version,
        keyID: UUID,
        agentID: UUID,
        sessionDigest: Data,
        documentVersion: UInt64,
        combinedCiphertext: Data
    ) {
        self.protocolVersion = protocolVersion
        self.keyID = keyID
        self.agentID = agentID
        self.sessionDigest = sessionDigest
        self.documentVersion = documentVersion
        self.combinedCiphertext = combinedCiphertext
    }
}

public enum TranscriptCryptoError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidCiphertext
    case identityMismatch
    case unsupportedProtocol(Int)
}

public enum TranscriptSyncCrypto {
    public static func generatePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    public static func publicKey(for privateKey: Data) throws -> Data {
        do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation }
        catch { throw TranscriptCryptoError.invalidPrivateKey }
    }

    /// Pairing-derived per-device channel key. Pairing identity is salt and the
    /// fixed protocol label is HKDF shared info, so another Array channel cannot
    /// accidentally reuse the transcript key.
    public static func deriveChannelKey(
        localPrivateKey: Data,
        remotePublicKey: Data,
        pairingID: UUID
    ) throws -> SymmetricKey {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do { privateKey = try .init(rawRepresentation: localPrivateKey) }
        catch { throw TranscriptCryptoError.invalidPrivateKey }
        do { publicKey = try .init(rawRepresentation: remotePublicKey) }
        catch { throw TranscriptCryptoError.invalidPublicKey }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(pairingID.uuidString.utf8),
            sharedInfo: Data("array.transcript.v1".utf8),
            outputByteCount: 32
        )
    }

    public static func encrypt(
        _ plaintext: TranscriptPlainEnvelope,
        key: SymmetricKey,
        keyID: UUID
    ) throws -> EncryptedTranscriptEnvelope {
        guard plaintext.protocolVersion == TranscriptSyncProtocol.version else {
            throw TranscriptCryptoError.unsupportedProtocol(plaintext.protocolVersion)
        }
        let digest = Data(SHA256.hash(data: Data(plaintext.sessionID.utf8)))
        let aad = associatedData(
            protocolVersion: plaintext.protocolVersion,
            keyID: keyID,
            agentID: plaintext.agentID,
            sessionDigest: digest,
            documentVersion: plaintext.documentVersion
        )
        let encoded = try JSONEncoder.transcriptSync.encode(plaintext)
        let sealed = try ChaChaPoly.seal(encoded, using: key, authenticating: aad)
        return EncryptedTranscriptEnvelope(
            keyID: keyID,
            agentID: plaintext.agentID,
            sessionDigest: digest,
            documentVersion: plaintext.documentVersion,
            combinedCiphertext: sealed.combined
        )
    }

    public static func decrypt(
        _ encrypted: EncryptedTranscriptEnvelope,
        key: SymmetricKey
    ) throws -> TranscriptPlainEnvelope {
        guard encrypted.protocolVersion == TranscriptSyncProtocol.version else {
            throw TranscriptCryptoError.unsupportedProtocol(encrypted.protocolVersion)
        }
        let aad = associatedData(
            protocolVersion: encrypted.protocolVersion,
            keyID: encrypted.keyID,
            agentID: encrypted.agentID,
            sessionDigest: encrypted.sessionDigest,
            documentVersion: encrypted.documentVersion
        )
        let box: ChaChaPoly.SealedBox
        do { box = try ChaChaPoly.SealedBox(combined: encrypted.combinedCiphertext) }
        catch { throw TranscriptCryptoError.invalidCiphertext }
        let opened: Data
        do { opened = try ChaChaPoly.open(box, using: key, authenticating: aad) }
        catch { throw TranscriptCryptoError.invalidCiphertext }
        let plaintext = try JSONDecoder.transcriptSync.decode(TranscriptPlainEnvelope.self, from: opened)
        let digest = Data(SHA256.hash(data: Data(plaintext.sessionID.utf8)))
        guard plaintext.agentID == encrypted.agentID,
              plaintext.documentVersion == encrypted.documentVersion,
              digest == encrypted.sessionDigest else {
            throw TranscriptCryptoError.identityMismatch
        }
        return plaintext
    }

    private static func associatedData(
        protocolVersion: Int,
        keyID: UUID,
        agentID: UUID,
        sessionDigest: Data,
        documentVersion: UInt64
    ) -> Data {
        var parts = Data("array.transcript.envelope".utf8)
        parts.append(Data("|\(protocolVersion)|\(keyID.uuidString)|\(agentID.uuidString)|\(documentVersion)|".utf8))
        parts.append(sessionDigest)
        return parts
    }
}

private extension JSONEncoder {
    static var transcriptSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var transcriptSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
