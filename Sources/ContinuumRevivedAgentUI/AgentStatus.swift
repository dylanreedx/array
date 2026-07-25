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
