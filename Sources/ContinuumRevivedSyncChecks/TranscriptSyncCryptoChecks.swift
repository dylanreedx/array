import CryptoKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

func runTranscriptSyncCryptoChecks() throws {
    let pairingID = UUID(uuidString: "71000000-0000-4000-8000-000000000001")!
    let keyID = UUID(uuidString: "71000000-0000-4000-8000-000000000002")!
    let agentID = UUID(uuidString: "71000000-0000-4000-8000-000000000003")!
    let otherAgentID = UUID(uuidString: "71000000-0000-4000-8000-000000000004")!
    let parentID = UUID(uuidString: "71000000-0000-4000-8000-000000000005")!
    let privateA = TranscriptSyncCrypto.generatePrivateKey()
    let privateB = TranscriptSyncCrypto.generatePrivateKey()
    let publicA = try TranscriptSyncCrypto.publicKey(for: privateA)
    let publicB = try TranscriptSyncCrypto.publicKey(for: privateB)
    let keyA = try TranscriptSyncCrypto.deriveChannelKey(
        localPrivateKey: privateA, remotePublicKey: publicB, pairingID: pairingID)
    let keyB = try TranscriptSyncCrypto.deriveChannelKey(
        localPrivateKey: privateB, remotePublicKey: publicA, pairingID: pairingID)

    let sentinel = "PLAINTEXT-TRANSCRIPT-SENTINEL-" + String(repeating: "x", count: 768)
    let entryID = AgentNodeID(rawValue: "sync.entry")!
    let document = AgentDocument(version: 7, entries: [AgentEntry(
        id: entryID,
        role: .assistant,
        provenance: .providerItem(provider: "codex", itemID: "provider-item-7"),
        lifecycle: .finished,
        blocks: [
            AgentBlock(
                id: AgentNodeID(rawValue: "sync.entry.prose")!,
                kind: .paragraph,
                payload: .paragraph([.text(sentinel)])),
            AgentBlock(
                id: AgentNodeID(rawValue: "sync.entry.child")!,
                kind: .agentReference,
                payload: .agentReference(AgentReferencePayload(
                    agentID: agentID,
                    parentAgentID: parentID,
                    displayNameAtSpawn: "Review agent",
                    spawnedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    sourceItemID: "spawn-7",
                    provider: "codex")))
        ]
    )])
    let plaintext = TranscriptPlainEnvelope(
        agentID: agentID,
        sessionID: "provider/private/session",
        documentVersion: document.version,
        createdAt: Date(timeIntervalSince1970: 1_700_000_001),
        content: .snapshot(document))
    let encrypted = try TranscriptSyncCrypto.encrypt(plaintext, key: keyA, keyID: keyID)
    let wire = try JSONEncoder().encode(encrypted)
    let wireText = String(decoding: wire, as: UTF8.self)
    expect(!wireText.contains(sentinel), "encrypted transcript wire must not expose transcript text")
    expect(!wireText.contains("provider/private/session"), "encrypted transcript wire must not expose provider session IDs")
    let decrypted = try TranscriptSyncCrypto.decrypt(encrypted, key: keyB)
    expect(decrypted == plaintext,
           "paired devices must derive interoperable transcript keys")

    let wrongPrivate = TranscriptSyncCrypto.generatePrivateKey()
    let wrongKey = try TranscriptSyncCrypto.deriveChannelKey(
        localPrivateKey: wrongPrivate, remotePublicKey: publicA, pairingID: pairingID)
    expectDecryptFailure(encrypted, key: wrongKey, "wrong devices must not decrypt transcripts")

    var rebound = encrypted
    rebound.agentID = otherAgentID
    expectDecryptFailure(rebound, key: keyB, "agent identity is authenticated associated data")

    var tampered = encrypted
    tampered.combinedCiphertext[tampered.combinedCiphertext.startIndex] ^= 0x01
    expectDecryptFailure(tampered, key: keyB, "ciphertext tampering must be rejected")

    expect(!Scope.operator.contains(.transcriptRead) && !Scope.operator.contains(.agentStop),
           "existing operator access must not implicitly grant transcript or Stop scopes")
    expect(Scope.admin.contains(.transcriptRead) && Scope.admin.contains(.agentStop),
           "admin capability may explicitly include transcript and Stop scopes")
    print("Transcript sync crypto checks passed: E2EE round-trip, long text, semantic child reference, tamper/wrong-device/AAD rejection, explicit scopes")
}

private func expectDecryptFailure(
    _ envelope: EncryptedTranscriptEnvelope,
    key: SymmetricKey,
    _ message: String
) {
    do {
        _ = try TranscriptSyncCrypto.decrypt(envelope, key: key)
        expect(false, message)
    } catch {
        // Expected authentication failure.
    }
}
