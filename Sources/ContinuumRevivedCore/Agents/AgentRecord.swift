import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2A.1-agent-record.md
//
// THE AGENT IS THE ENTITY; A TILE IS ONE VIEW OF IT (locked decision, _RUNBOOK.md).
//
// Today an agent's identity *is* its `tileId`, which already costs three real
// failures in this codebase:
//   · `ZoneHydrationBudgetConfig` (max 4 live zones) is a CANVAS LAYOUT budget,
//     so an agent past it silently freezes;
//   · `ZoneRuntimeBudgetConfig.closeOnZero` tears observers down for
//     non-current workspaces;
//   · relaunch rebuilds an empty tile, because the tile is the agent's only home.
// `AgentRecord` is the home that outlives the view. `tileId` moves from being
// identity to being a nullable VIEW BINDING (`nil` == headless).
//
// I5 (sync-boundary purity, locked-decisions D3): this record is HOST-BOUND and
// MUST NOT cross the sync boundary. `cwd` and `worktreeBranch` are host paths /
// host git state. It is the sibling of `ManagedAgentSessionRecord`, which the I5
// comment in `AgentActivityEvent.swift` names as the correct home for
// host-bound fields. `AgentRecordChecks` proves the taint scanner flags an
// encoded record for every host-path prefix the scanner knows. Stated precisely,
// because the weaker version of this claim is a trap: the scanner recognises a
// host path by PREFIX, so it is a BACKSTOP for the common case, not a proof that
// no `AgentRecord` can ever cross. The guarantee is that nothing publishes this
// type — P2A.2 owns the store that must keep it that way.

/// Stable identity of an agent, independent of any tile that happens to render it.
///
/// Encoded as a bare UUID (single-value container), not as `{"rawValue": …}`:
/// the wire form of an id should be the id, so an `AgentID` key is readable in
/// a persisted record and re-typing a `UUID` field as `AgentID` later is not a
/// format break.
public struct AgentID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AgentRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    /// Decode-forward version marker, per `TerminalSessionDescriptor`'s precedent.
    public let schemaVersion: Int
    public let id: AgentID
    /// User-facing and renameable. NOT an identifier — see `role`.
    public var displayName: String
    /// Id matching a `.pi/agents/<role>.md`. An id, never shown as a title.
    public var role: String?
    /// Fully-qualified model id — the exact catalogue entry, per P0.10's
    /// `AgentModelConfig` (a prefix lets Pi's fuzzy matcher choose silently).
    public var model: String
    public var thinking: String
    /// Host path. May be a per-agent worktree path (P2C). Host-bound: I5.
    public var cwd: String
    /// Branch checked out in that worktree, when the agent owns one (P2C).
    public var worktreeBranch: String?
    public var projectId: UUID?
    /// Set by the orchestrator when this agent was spawned by another (P2D).
    public var parentAgentID: AgentID?
    /// P2D.6 — the queue item this agent was fanned out FOR, if any (a Linear
    /// row's `identifier`, e.g. `ENG-214`). Stored rather than kept in a runtime
    /// map because the mapping has to survive a relaunch: without it an agent
    /// that finishes after the app restarts has nothing to check off. An
    /// identifier the source surface already shows, so it is not new exposure.
    public var sourceItemId: String?
    public var createdAt: Date
    public var lastActivityAt: Date
    /// VIEW BINDING, NOT IDENTITY. `nil` means the agent is headless — running
    /// with no tile rendering it. Closing a tile clears this; it never ends an
    /// agent. Anything that treats this as the agent's key reintroduces the
    /// three failures documented at the head of this file.
    public var tileId: UUID?

    // Ticket: docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
    //
    // The four STORED lifecycle facts. Nothing here is derived — the four-case
    // `InboxLifecycle` a row is drawn from is P4.2's pure function over these,
    // and computing it here would put the precedence rules (a blocker outranks
    // an explicit settle) in the storage type where two callers would drift.
    //
    // DESKTOP STATE. It may cross to the phone later, but it is NOT in the sync
    // payload today and must not be added to one here (packet's watch-out).
    /// What the human said: `.settled`, an explicit keep-active `.active` pin,
    /// or `.neutral` (the default) to let the auto rules decide.
    public var settledOverride: SettledOverride
    /// When it was settled — by hand or by the auto-settle sweep. Kept beside
    /// the override rather than inside it because history is ordered by when
    /// work ended, and an override that was later cleared still happened.
    public var settledAt: Date?
    /// When a snooze expires. In the FUTURE while the snooze holds.
    public var snoozedUntil: Date?
    // Ticket: docs/38-tickets/90-agent-ux/P4.6-snooze-raised-hand.md
    /// When the snooze was SET. **Schema addition**, written beside
    /// `snoozedUntil` and optional like every lifecycle date, so a record from
    /// before this ticket decodes with it absent.
    ///
    /// It exists because "wake this row early if something needs me" is only
    /// answerable against a reference point: a failure that was already on the
    /// screen when the human snoozed is precisely what they said "not now" to,
    /// and a failure that arrived afterwards is not. Without this date the two
    /// are the same fact and the snooze either hides new trouble or never
    /// holds at all. `snoozedUntil` cannot stand in — it is in the future.
    ///
    /// `currentSchemaVersion` deliberately does NOT move for this (cross-review,
    /// codex): adding an OPTIONAL field that both older and newer builds decode
    /// as absent is not a shape change — it is what `decodeIfPresent` is for, and
    /// it is the convention P4.1's three lifecycle dates and P2D.6's
    /// `sourceItemId` already set. The version marker is for a change a reader
    /// must branch on; nothing has to branch on this one.
    public var snoozedAt: Date?
    /// When it left the list. **`archived` ≠ `settled`**: settled stays in the
    /// list, slim and readable; archived is gone from it.
    public var archivedAt: Date?

    public init(
        schemaVersion: Int = AgentRecord.currentSchemaVersion,
        id: AgentID,
        displayName: String,
        role: String? = nil,
        model: String,
        thinking: String,
        cwd: String,
        worktreeBranch: String? = nil,
        projectId: UUID? = nil,
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
        createdAt: Date,
        lastActivityAt: Date,
        tileId: UUID? = nil,
        settledOverride: SettledOverride = .default,
        settledAt: Date? = nil,
        snoozedUntil: Date? = nil,
        snoozedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.role = role
        self.model = model
        self.thinking = thinking
        self.cwd = cwd
        self.worktreeBranch = worktreeBranch
        self.projectId = projectId
        self.parentAgentID = parentAgentID
        self.sourceItemId = sourceItemId
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.tileId = tileId
        self.settledOverride = settledOverride
        self.settledAt = settledAt
        self.snoozedUntil = snoozedUntil
        self.snoozedAt = snoozedAt
        self.archivedAt = archivedAt
    }

    // Dates are encoded as `timeIntervalSinceReferenceDate` Doubles, following
    // `AgentActivityEvent`'s precedent and for the same two reasons recorded
    // there: `JSONCodec.makeEncoder` uses `.iso8601` with no fractional-second
    // component, which truncates a real `Date()`; and `timeIntervalSince1970`
    // is itself lossy on round-trip (it adds then re-subtracts 978307200, and
    // that does not always invert exactly in floating point).
    // `timeIntervalSinceReferenceDate` IS Date's storage, so no arithmetic
    // conversion happens and the round-trip is exact.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, displayName, role, model, thinking, cwd
        case worktreeBranch, projectId, parentAgentID, sourceItemId
        case createdAtReferenceInterval, lastActivityAtReferenceInterval
        case tileId
        // P4.1. The three lifecycle dates take reference intervals for exactly
        // the reason above — a settled-at that drifts on reload reorders
        // history.
        case settledOverride
        case settledAtReferenceInterval, snoozedUntilReferenceInterval, archivedAtReferenceInterval
        // P4.6. A fourth lifecycle date, encoded the same way for the same
        // reason: the newness test compares against it, so drift on reload
        // would move the line between "I already saw that" and "this is new".
        case snoozedAtReferenceInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(AgentID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decode(String.self, forKey: .model)
        thinking = try container.decode(String.self, forKey: .thinking)
        cwd = try container.decode(String.self, forKey: .cwd)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        parentAgentID = try container.decodeIfPresent(AgentID.self, forKey: .parentAgentID)
        sourceItemId = try container.decodeIfPresent(String.self, forKey: .sourceItemId)
        createdAt = Date(timeIntervalSinceReferenceDate:
            try container.decode(Double.self, forKey: .createdAtReferenceInterval))
        lastActivityAt = Date(timeIntervalSinceReferenceDate:
            try container.decode(Double.self, forKey: .lastActivityAtReferenceInterval))
        tileId = try container.decodeIfPresent(UUID.self, forKey: .tileId)
        // P4.1. Decoded through `SettledOverride(persistedRawValue:)` rather
        // than as the enum directly: a record written by a newer build with a
        // case this one has never heard of must read as `.neutral`, not throw
        // and lose the agent. A record written BEFORE this ticket has no key at
        // all and takes the same path.
        settledOverride = SettledOverride(
            persistedRawValue: try container.decodeIfPresent(String.self, forKey: .settledOverride))
        settledAt = try container.decodeIfPresent(Double.self, forKey: .settledAtReferenceInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        snoozedUntil = try container.decodeIfPresent(Double.self, forKey: .snoozedUntilReferenceInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        snoozedAt = try container.decodeIfPresent(Double.self, forKey: .snoozedAtReferenceInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        archivedAt = try container.decodeIfPresent(Double.self, forKey: .archivedAtReferenceInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(model, forKey: .model)
        try container.encode(thinking, forKey: .thinking)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(parentAgentID, forKey: .parentAgentID)
        try container.encodeIfPresent(sourceItemId, forKey: .sourceItemId)
        try container.encode(createdAt.timeIntervalSinceReferenceDate, forKey: .createdAtReferenceInterval)
        try container.encode(lastActivityAt.timeIntervalSinceReferenceDate, forKey: .lastActivityAtReferenceInterval)
        try container.encodeIfPresent(tileId, forKey: .tileId)
        // P4.1. `.neutral` is written as ABSENCE, the same way a headless
        // record omits `tileId`: the default is "nobody has said anything", and
        // a stored word saying so is noise that also makes every pre-P4.1
        // record differ from a freshly written one for no reason.
        if settledOverride != .default {
            try container.encode(settledOverride, forKey: .settledOverride)
        }
        try container.encodeIfPresent(settledAt?.timeIntervalSinceReferenceDate,
                                      forKey: .settledAtReferenceInterval)
        try container.encodeIfPresent(snoozedUntil?.timeIntervalSinceReferenceDate,
                                      forKey: .snoozedUntilReferenceInterval)
        try container.encodeIfPresent(snoozedAt?.timeIntervalSinceReferenceDate,
                                      forKey: .snoozedAtReferenceInterval)
        try container.encodeIfPresent(archivedAt?.timeIntervalSinceReferenceDate,
                                      forKey: .archivedAtReferenceInterval)
    }

    // Lifecycle (settle / snooze) landed above in P4.1 as STORED FACTS ONLY.
    // Nothing runtime-shaped belongs here: a pid, a pane target, or a resume
    // cursor is `ManagedAgentSessionRecord`'s.
}
