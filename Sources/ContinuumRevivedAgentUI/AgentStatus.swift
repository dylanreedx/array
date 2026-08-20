import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.1-agentui-module.md
//
// Moved verbatim out of ContinuumRevivedCore/TerminalSessionDescriptor.swift.
// `StatusChipPresenter` — and every token/presenter this module gains from P1.2
// onward — is keyed on this enum, and the module is forbidden from depending on
// Core (see the ticket: Core → AgentUI is fine, AgentUI → Core is not). So the
// status vocabulary lives here and Core consumes it, not the other way round.
// Raw values are unchanged, which is what keeps the persisted/synced
// `AgentDescriptor` encoding identical across the move.

public enum AgentStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case configuring
    case working
    case idle
    case needsAttention
    case done
    case stale
}

/// The durable result of the latest completed managed-agent turn. Operational
/// phase and terminal outcome are separate axes: an idle agent may still have an
/// unread failure, and a new working turn does not rewrite what the prior turn did.
public enum AgentTerminalOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    case succeeded
    case failed
    case interrupted
    case cancelled
    case runtimeError
}

public struct AgentTerminalEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let turnID: String?
    public let outcome: AgentTerminalOutcome
    public let endedAt: Date

    public init(
        sequence: UInt64, turnID: String?, outcome: AgentTerminalOutcome, endedAt: Date
    ) {
        self.sequence = sequence
        self.turnID = turnID
        self.outcome = outcome
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, turnID, outcome, endedAtReferenceInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        outcome = try container.decode(AgentTerminalOutcome.self, forKey: .outcome)
        let interval = try container.decode(Double.self, forKey: .endedAtReferenceInterval)
        endedAt = Date(timeIntervalSinceReferenceDate: interval)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(endedAt.timeIntervalSinceReferenceDate,
                             forKey: .endedAtReferenceInterval)
    }
}
