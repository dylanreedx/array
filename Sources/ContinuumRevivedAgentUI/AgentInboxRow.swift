import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.1-inbox-row-model.md
//
// ONE PURE VALUE PER ROW, so the list view is dumb.
//
// Locked decision (_RUNBOOK.md): the sidebar IS the inbox by default. That makes
// this the desktop's row vocabulary, and it lives in ContinuumRevivedAgentUI —
// Foundation only, no AppKit/UIKit — so iOS can share it later without a second
// implementation drifting away from this one.
//
// PLACEMENT, and the one thing this file may NOT do: this module is forbidden
// from depending on Core (P1.1 — the direction is compiler-enforced; a Core
// import here is a circular-dependency build error, not a lint). `AgentsBoardRow`
// and `AgentRowContext` are Core types, so the JOIN that builds these rows out of
// an `ActivityLogSnapshot` cannot live here. It lives in Core, next to the
// projection that owns status: `ContinuumRevivedCore/Agents/AgentInboxRowBuilder.swift`.
// This file owns the vocabulary and the pure (AgentStatus → InboxState) mapping;
// that file owns the join. The packet named only this file, and the split is
// forced by the module boundary — same call P1.1 made when it moved `AgentStatus`
// here for exactly this reason.

/// What the agent is doing. FIVE STATES, and only three of them are coloured —
/// P3.2 attaches the accents and refines the mapping with pending-approval /
/// pending-input facts, which are not visible from `AgentStatus` alone.
///
/// `ready` is the resting state: the agent stopped and is waiting on you,
/// whatever the reason (finished, asked, proposed a plan). It is NOT an error,
/// and it is deliberately unlabelled and uncoloured.
public enum InboxState: String, CaseIterable, Equatable, Sendable {
    case working
    case approval
    case input
    case failed
    case ready
}

/// Whether the row is YOURS to look at — a separate axis from `InboxState`,
/// because a finished-but-unseen agent and one you already reviewed report the
/// same state and are not the same thing. P3.3 populates it; until then every row
/// reports `.none`.
public enum InboxAttention: String, CaseIterable, Equatable, Sendable {
    case none
    case unread
    case woke
}

/// Settle / snooze / archive (locked decision). P4.1 owns the persisted facts and
/// P4.2 the derivation; this ticket only names the vocabulary the row carries, and
/// every row it builds today is `.active`.
public enum InboxLifecycle: Equatable, Sendable {
    case active
    case snoozed(until: Date)
    case settled
    case archived
}

/// How much room the row gets. Settled and snoozed collapse; everything else is a
/// full card (P3.7 paints them — this is the fact it keys on).
public enum RowVariant: String, CaseIterable, Equatable, Sendable {
    case card
    case slim

    /// Derived, never chosen by a caller: the density rule is "parked work
    /// collapses", so it is a function of lifecycle and nothing else. `ready` and
    /// `failed` are full cards no matter how quiet the list gets.
    public static func forLifecycle(_ lifecycle: InboxLifecycle) -> RowVariant {
        switch lifecycle {
        case .snoozed, .settled:
            return .slim
        case .active, .archived:
            return .card
        }
    }
}

public struct AgentInboxRow: Equatable, Sendable, Identifiable {
    /// AGGREGATE agent identity — the same `UUID` keyspace as
    /// `AgentsBoardRow.id`, `ActivityLogSnapshot.byAgent`, `AgentContextIndex`
    /// and `AgentsBoardChangeSet` (`AgentRecord.id.rawValue` for a managed agent,
    /// a terminal session's `tileId` for one that has no record).
    ///
    /// Deliberately a bare `UUID` and not `AgentID`, which the packet sketched:
    /// `AgentID` is `AgentRecord`'s identity, so it cannot name the terminal
    /// sessions that are half this list, and it lives in Core, which this module
    /// may not import. Using the board's own key is also what makes P2B.7's
    /// incremental refresh usable directly — its change set is `Set<UUID>` over
    /// this same identity, and list diffing depends on the two agreeing.
    public let id: UUID
    /// The agent's name, never an identifier. `role` is the identifier.
    public let title: String
    /// A chip. Project is METADATA on the row — never a group header, because
    /// the list order is frozen (P3.4) and grouping would reorder it.
    public let projectName: String?
    public let state: InboxState
    public let attention: InboxAttention
    public let lifecycle: InboxLifecycle
    public let model: String?
    /// A `.pi/agents/<role>.md` id (P2D.3), never shown as a title.
    public let role: String?
    /// The branch this agent's work lands on (P2C.4).
    public let branch: String?
    /// The agent has a checkout of its own (P2C.2).
    public let isIsolated: Bool
    /// Seconds since the current turn began, MEANINGFUL ONLY WHILE `.working`.
    ///
    /// A row is a snapshot taken at render time and thrown away, so this is
    /// computed from a start timestamp against the caller's `now` every time the
    /// row is built (`AgentInboxRowBuilder`). Nothing stores it — a stored elapsed
    /// is stale the instant after it is written.
    public let elapsed: TimeInterval?
    /// 0 for a top-level agent, 1 for a child of one (P2D.4).
    public let depth: Int
    public let variant: RowVariant

    public init(
        id: UUID,
        title: String,
        projectName: String? = nil,
        state: InboxState,
        attention: InboxAttention = .none,
        lifecycle: InboxLifecycle = .active,
        model: String? = nil,
        role: String? = nil,
        branch: String? = nil,
        isIsolated: Bool = false,
        elapsed: TimeInterval? = nil,
        depth: Int = 0,
        variant: RowVariant = .card
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.state = state
        self.attention = attention
        self.lifecycle = lifecycle
        self.model = model
        self.role = role
        self.branch = branch
        self.isIsolated = isIsolated
        self.elapsed = elapsed
        self.depth = depth
        self.variant = variant
    }

    /// Shown when neither a display name nor a tile title is known — a terminal
    /// session whose tile the sidebar tree does not place, or a caller that built
    /// rows with no context index at all. A row with an empty title would render
    /// as a blank line, which reads as a broken list rather than an unnamed agent.
    public static let untitled = "Agent"

    /// TOTAL by construction — every `AgentStatus` resolves to exactly one state,
    /// with no `default:` (adding a status is then a compile error here, which is
    /// the point).
    ///
    /// Status is READ, never re-derived: `AgentsBoardProjection` owns the fold
    /// that produces it and `StatusChipPresenter` owns how it is painted. This is
    /// only the status → inbox-vocabulary translation.
    ///
    /// `configuring` is in motion, so it maps to `.working`. `idle`, `done` and
    /// `stale` all mean the agent stopped and is waiting on you, which is exactly
    /// what `ready` covers — and none of them is an error, so none may be
    /// coloured. `needsAttention` is the one status that asks for something; P3.2
    /// splits it into `.approval` vs `.input` using the pending request itself,
    /// which the status cannot distinguish, and answers to `.approval` until then
    /// because a pending `approvalRequestId` is what raises the status today
    /// (`AgentsBoardProjection.respondableRequest`). Nothing maps to `.failed`
    /// yet: no `AgentStatus` records failure — Phase 4 does.
    public static func state(for status: AgentStatus) -> InboxState {
        switch status {
        case .working, .configuring:
            return .working
        case .needsAttention:
            return .approval
        case .idle, .done, .stale:
            return .ready
        }
    }
}
