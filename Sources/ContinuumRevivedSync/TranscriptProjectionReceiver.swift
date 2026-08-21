import CryptoKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

public enum TranscriptProjectionReceiverError: Error, Equatable, Sendable {
    case unknownKey(UUID)
    case missingBase(agentID: UUID, expectedVersion: UInt64)
    case versionMismatch(agentID: UUID, expected: UInt64, actual: UInt64)
}

/// Phone-side semantic projection. It consumes only authenticated encrypted
/// envelopes and applies the same `AgentDocumentReducer` used on macOS.
public actor TranscriptProjectionReceiver {
    private let demux: SyncMessageDemux
    private let scope: Scope
    private var channelKeys: [UUID: SymmetricKey]
    private var documents: [UUID: AgentDocument] = [:]
    private var observers: [UUID: AsyncStream<(UUID, AgentDocument)>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var subscribedAgentIDs: Set<UUID> = []
    private var lastError: TranscriptProjectionReceiverError?

    public init(demux: SyncMessageDemux, scope: Scope, channelKeys: [UUID: SymmetricKey]) {
        precondition(scope.contains(.transcriptRead),
                     "TranscriptProjectionReceiver requires explicit transcriptRead scope")
        self.demux = demux
        self.scope = scope
        self.channelKeys = channelKeys
    }

    public func connect(agentIDs: [UUID]) async {
        subscribedAgentIDs.formUnion(agentIDs)
        if receiveTask == nil {
            let stream = await demux.subscribe()
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(stream)
            }
        }
        let versions = documents.mapValues(\.version)
        try? await demux.send(.transcriptSubscribe(TranscriptSubscribeRequest(
            supportedKeyIDs: channelKeys.keys.sorted { $0.uuidString < $1.uuidString },
            agentIDs: Array(subscribedAgentIDs).sorted { $0.uuidString < $1.uuidString },
            knownDocumentVersions: versions)))
    }

    public func installChannelKey(_ key: SymmetricKey, keyID: UUID) {
        channelKeys[keyID] = key
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    public func currentDocument(agentID: UUID) -> AgentDocument? { documents[agentID] }
    public func currentError() -> TranscriptProjectionReceiverError? { lastError }

    public func subscribe() -> AsyncStream<(UUID, AgentDocument)> {
        let current = documents.sorted { $0.key.uuidString < $1.key.uuidString }
        let (stream, continuation) = AsyncStream<(UUID, AgentDocument)>.makeStream()
        current.forEach { continuation.yield(($0.key, $0.value)) }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func receiveLoop(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            switch message {
            case .transcriptEnvelope(let envelope):
                await accept(envelope)
            case .transcriptHistoryResponse(let response):
                if let envelope = response.envelope { await accept(envelope) }
            default:
                continue
            }
        }
    }

    private func accept(_ envelope: EncryptedTranscriptEnvelope) async {
        guard subscribedAgentIDs.contains(envelope.agentID) else { return }
        guard let key = channelKeys[envelope.keyID] else {
            lastError = .unknownKey(envelope.keyID)
            return
        }
        do {
            let plaintext = try TranscriptSyncCrypto.decrypt(envelope, key: key)
            let document: AgentDocument
            switch plaintext.content {
            case .snapshot(let incoming):
                guard incoming.version == plaintext.documentVersion else {
                    throw TranscriptProjectionReceiverError.versionMismatch(
                        agentID: plaintext.agentID,
                        expected: plaintext.documentVersion,
                        actual: incoming.version)
                }
                document = incoming
            case .mutations(let baseVersion, let values):
                guard let current = documents[plaintext.agentID], current.version == baseVersion else {
                    throw TranscriptProjectionReceiverError.missingBase(
                        agentID: plaintext.agentID, expectedVersion: baseVersion)
                }
                var reducer = AgentDocumentReducer(document: current)
                for mutation in values { try reducer.apply(mutation) }
                guard reducer.document.version == plaintext.documentVersion else {
                    throw TranscriptProjectionReceiverError.versionMismatch(
                        agentID: plaintext.agentID,
                        expected: plaintext.documentVersion,
                        actual: reducer.document.version)
                }
                document = reducer.document
            }
            documents[plaintext.agentID] = document
            lastError = nil
            observers.values.forEach { $0.yield((plaintext.agentID, document)) }
        } catch let error as TranscriptProjectionReceiverError {
            lastError = error
        } catch {
            // Authentication failures deliberately disclose no more detail.
            lastError = .versionMismatch(
                agentID: envelope.agentID,
                expected: envelope.documentVersion,
                actual: documents[envelope.agentID]?.version ?? 0)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
