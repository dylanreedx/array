import CryptoKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Desktop publisher for negotiated transcript snapshots. The provider closure
/// returns semantic content only; encryption occurs before `demux.send`.
public actor TranscriptProjectionSender {
    public typealias DocumentProvider = @Sendable (UUID) async -> (sessionID: String, document: AgentDocument)?

    private let demux: SyncMessageDemux
    private let authorizedScope: Scope
    private let channelKey: SymmetricKey
    private let keyID: UUID
    private let documentProvider: DocumentProvider
    private var receiveTask: Task<Void, Never>?

    public init(
        demux: SyncMessageDemux,
        authorizedScope: Scope,
        channelKey: SymmetricKey,
        keyID: UUID,
        documentProvider: @escaping DocumentProvider
    ) {
        self.demux = demux
        self.authorizedScope = authorizedScope
        self.channelKey = channelKey
        self.keyID = keyID
        self.documentProvider = documentProvider
    }

    public func start() async {
        guard receiveTask == nil else { return }
        let stream = await demux.subscribe()
        receiveTask = Task { [weak self] in await self?.receiveLoop(stream) }
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func receiveLoop(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            switch message {
            case .transcriptSubscribe(let request):
                guard authorizedScope.contains(.transcriptRead),
                      request.supportedProtocolVersions.contains(TranscriptSyncProtocol.version),
                      request.supportedKeyIDs?.contains(keyID) != false else { continue }
                for agentID in request.agentIDs {
                    guard let source = await documentProvider(agentID),
                          request.knownDocumentVersions[agentID] != source.document.version,
                          let envelope = try? makeEnvelope(agentID: agentID, source: source) else { continue }
                    try? await demux.send(.transcriptEnvelope(envelope))
                }
            case .transcriptHistoryRequest(let request):
                guard authorizedScope.contains(.transcriptRead),
                      request.supportedKeyIDs?.contains(keyID) != false,
                      let source = await documentProvider(request.agentID),
                      let envelope = try? makeEnvelope(agentID: request.agentID, source: source) else {
                    try? await demux.send(.transcriptHistoryResponse(TranscriptHistoryResponse(
                        requestID: request.requestID,
                        envelope: nil,
                        unavailableReason: "Transcript is unavailable on the host.")))
                    continue
                }
                try? await demux.send(.transcriptHistoryResponse(TranscriptHistoryResponse(
                    requestID: request.requestID, envelope: envelope)))
            default:
                continue
            }
        }
    }

    private func makeEnvelope(
        agentID: UUID,
        source: (sessionID: String, document: AgentDocument)
    ) throws -> EncryptedTranscriptEnvelope {
        try TranscriptSyncCrypto.encrypt(
            TranscriptPlainEnvelope(
                agentID: agentID,
                sessionID: source.sessionID,
                documentVersion: source.document.version,
                content: .snapshot(source.document)),
            key: channelKey,
            keyID: keyID)
    }
}

public actor AgentStopResponder {
    public typealias StopHandler = @Sendable (UUID) async -> AgentStopOutcome

    private let demux: SyncMessageDemux
    private let authorizedScope: Scope
    private let stopHandler: StopHandler
    private var receiveTask: Task<Void, Never>?

    public init(
        demux: SyncMessageDemux,
        authorizedScope: Scope,
        stopHandler: @escaping StopHandler
    ) {
        self.demux = demux
        self.authorizedScope = authorizedScope
        self.stopHandler = stopHandler
    }

    public func start() async {
        guard receiveTask == nil else { return }
        let stream = await demux.subscribe()
        receiveTask = Task { [weak self] in
            for await message in stream {
                guard case .agentStopRequest(let request) = message else { continue }
                let outcome = await self?.resolve(request) ?? .notFound
                try? await self?.demux.send(.agentStopAck(AgentStopAck(
                    requestID: request.requestID,
                    agentID: request.agentID,
                    outcome: outcome)))
            }
        }
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func resolve(_ request: AgentStopRequest) async -> AgentStopOutcome {
        guard authorizedScope.contains(.agentStop) else { return .unauthorized }
        return await stopHandler(request.agentID)
    }
}
