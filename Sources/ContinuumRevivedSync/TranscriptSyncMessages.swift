import ContinuumRevivedCore
import Foundation

public struct TranscriptSubscribeRequest: Codable, Sendable, Equatable {
    public var supportedProtocolVersions: [Int]
    public var supportedKeyIDs: [UUID]?
    public var agentIDs: [UUID]
    public var knownDocumentVersions: [UUID: UInt64]

    public init(
        supportedProtocolVersions: [Int] = [TranscriptSyncProtocol.version],
        supportedKeyIDs: [UUID]? = nil,
        agentIDs: [UUID],
        knownDocumentVersions: [UUID: UInt64] = [:]
    ) {
        self.supportedProtocolVersions = supportedProtocolVersions
        self.supportedKeyIDs = supportedKeyIDs
        self.agentIDs = agentIDs
        self.knownDocumentVersions = knownDocumentVersions
    }
}

public struct TranscriptHistoryRequest: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var agentID: UUID
    public var knownDocumentVersion: UInt64?
    public var supportedKeyIDs: [UUID]?

    public init(requestID: UUID = UUID(), agentID: UUID, knownDocumentVersion: UInt64? = nil, supportedKeyIDs: [UUID]? = nil) {
        self.requestID = requestID
        self.agentID = agentID
        self.knownDocumentVersion = knownDocumentVersion
        self.supportedKeyIDs = supportedKeyIDs
    }
}

public struct TranscriptHistoryResponse: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var envelope: EncryptedTranscriptEnvelope?
    public var unavailableReason: String?

    public init(requestID: UUID, envelope: EncryptedTranscriptEnvelope?, unavailableReason: String? = nil) {
        self.requestID = requestID
        self.envelope = envelope
        self.unavailableReason = unavailableReason
    }
}

public enum TranscriptDetailKind: String, Codable, Sendable, Equatable {
    case managedMedia
    case sanitizedToolDetail
}

public struct TranscriptDetailRequest: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var agentID: UUID
    public var detailID: String
    public var kind: TranscriptDetailKind

    public init(requestID: UUID = UUID(), agentID: UUID, detailID: String, kind: TranscriptDetailKind) {
        self.requestID = requestID
        self.agentID = agentID
        self.detailID = detailID
        self.kind = kind
    }
}

/// Detail bytes are already encrypted by the transcript channel before this
/// value reaches a transport. The host-local source URL/path never crosses.
public struct TranscriptDetailResponse: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var agentID: UUID
    public var kind: TranscriptDetailKind
    public var keyID: UUID
    public var combinedCiphertext: Data?
    public var unavailableReason: String?

    public init(
        requestID: UUID,
        agentID: UUID,
        kind: TranscriptDetailKind,
        keyID: UUID,
        combinedCiphertext: Data?,
        unavailableReason: String? = nil
    ) {
        self.requestID = requestID
        self.agentID = agentID
        self.kind = kind
        self.keyID = keyID
        self.combinedCiphertext = combinedCiphertext
        self.unavailableReason = unavailableReason
    }
}

public enum ChildLifecycleStatus: String, Codable, Sendable, Equatable {
    case starting, working, waiting, completed, failed, stopped, unavailable
}

public struct ChildLifecycleUpdate: Codable, Sendable, Equatable {
    public var agentID: UUID
    public var parentAgentID: UUID
    public var status: ChildLifecycleStatus
    public var transcript: AgentTranscriptAvailability
    public var canStop: Bool
    public var providerObserved: Bool
    public var updatedAt: Date

    public init(
        agentID: UUID,
        parentAgentID: UUID,
        status: ChildLifecycleStatus,
        transcript: AgentTranscriptAvailability,
        canStop: Bool,
        providerObserved: Bool,
        updatedAt: Date = Date()
    ) {
        self.agentID = agentID
        self.parentAgentID = parentAgentID
        self.status = status
        self.transcript = transcript
        self.canStop = canStop
        self.providerObserved = providerObserved
        self.updatedAt = updatedAt
    }
}

public struct AgentStopRequest: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var agentID: UUID

    public init(requestID: UUID = UUID(), agentID: UUID) {
        self.requestID = requestID
        self.agentID = agentID
    }
}

public enum AgentStopOutcome: String, Codable, Sendable, Equatable {
    case stopped, unsupported, unauthorized, notFound, stale
}

public struct AgentStopAck: Codable, Sendable, Equatable {
    public var requestID: UUID
    public var agentID: UUID
    public var outcome: AgentStopOutcome

    public init(requestID: UUID, agentID: UUID, outcome: AgentStopOutcome) {
        self.requestID = requestID
        self.agentID = agentID
        self.outcome = outcome
    }
}
