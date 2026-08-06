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

public enum AgentDisplayNameSource: String, Codable, Sendable {
    /// The shared sentinel is the only title the supervisor may replace
    /// automatically.
    case sentinel
    /// A person chose or renamed the title.
    case manual
    /// The title came from a user's prompt and is therefore tainted at sync
    /// boundaries even after it has been shortened for the sidebar.
    case prompt
    /// The title came from a ticket/queue source. Keep this provenance separate
    /// from prompt text so the companion projection can scrub either automatic
    /// source without guessing from the rendered words.
    case sourceItem
    /// The title was derived from the parent's human-facing name and a stable
    /// child ordinal. It is still automatic text at the sync boundary: a parent
    /// name may itself have come from a prompt or source item.
    case parent
}

/// The result of the one precedence ladder used by every derived spawn path.
/// Keeping the source beside the rendered value is what lets local presentation
/// be useful without allowing prompt/source/parent text into the companion payload.
public struct AgentDisplayNameProposal: Equatable, Sendable {
    public let name: String
    public let source: AgentDisplayNameSource

    public init(name: String, source: AgentDisplayNameSource) {
        self.name = name
        self.source = source
    }
}

/// The compare-and-swap token for one automatic name proposal.
///
/// `expectedName` is captured when the proposal starts, not when it finishes.
/// The request id prevents an older completion from winning after a newer request
/// superseded it; the expected name prevents any other name mutation from being
/// overwritten even if that mutation did not come through the supervisor's
/// request path. It is persisted with the host-bound record so a restored record
/// never loses the ownership marker that a completion must prove.
public struct NamingRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let expectedName: String

    public init(id: UUID = UUID(), expectedName: String) {
        self.id = id
        self.expectedName = expectedName
    }
}

/// The non-persisted activity facts needed to classify one record at read time.
/// Lifecycle itself is intentionally absent: callers carry raw record fields plus
/// these observations into `AgentRecord.lifecycle` for each read.
public struct AgentLifecycleFacts: Equatable, Sendable {
    public var attentionIsYours: Bool
    public var hasLiveRunner: Bool
    /// Blockers projected from descendants. This is observation input, not a
    /// persisted lifecycle value; the builder supplies it before deriving the
    /// parent's lifecycle so the child rollup cannot disagree with settlement.
    public var descendantBlockers: LifecycleBlockers
    /// A prompt accepted by the runtime but not yet adopted by a turn. This is
    /// bounded on both sides of `now` so a peer clock cannot pin a row forever.
    public var unadoptedPromptAt: Date?
    public var graceWindow: TimeInterval

    public init(
        attentionIsYours: Bool = false,
        hasLiveRunner: Bool = false,
        descendantBlockers: LifecycleBlockers = .unblocked,
        unadoptedPromptAt: Date? = nil,
        graceWindow: TimeInterval = 30
    ) {
        self.attentionIsYours = attentionIsYours
        self.hasLiveRunner = hasLiveRunner
        self.descendantBlockers = descendantBlockers
        self.unadoptedPromptAt = unadoptedPromptAt
        self.graceWindow = max(0, graceWindow)
    }

    public func hasUnadoptedPrompt(now: Date) -> Bool {
        guard let unadoptedPromptAt else { return false }
        let distance = now.timeIntervalSince(unadoptedPromptAt)
        return distance >= -graceWindow && distance <= graceWindow
    }

    /// The one blocker set consumed by both lifecycle classification and the
    /// settle action guard. The bool named `attentionIsYours` is deliberately a
    /// pending-human-request fact here, never the inbox's unread mark. Descendant
    /// blockers join through the same union as own blockers before either
    /// consumer sees the set.
    public func lifecycleBlockers(now: Date) -> LifecycleBlockers {
        var blockers = LifecycleBlockers.unblocked
        if attentionIsYours { blockers.insert(.pendingInput) }
        if hasLiveRunner { blockers.insert(.sessionRunning) }
        if hasUnadoptedPrompt(now: now) { blockers.insert(.queuedTurn) }
        return blockers.includingDescendants([descendantBlockers])
    }

    /// One blocker list, shared by classification and the settle action guard.
    public func blocksSettlement(now: Date) -> Bool {
        lifecycleBlockers(now: now).isBlocking
    }
}

public struct AgentRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Compatibility spelling for callers that need the sentinel beside the
    /// record. The literal itself lives in `AgentName`, once, in AgentUI.
    public static let defaultAgentName = AgentName.defaultName

    /// Decode-forward version marker, per `TerminalSessionDescriptor`'s precedent.
    public let schemaVersion: Int
    public let id: AgentID
    /// User-facing and renameable. NOT an identifier — see `role`.
    public var displayName: String
    /// Provenance is local bookkeeping: prompt/source/parent-derived names are
    /// replaced by the sentinel before `AgentInventory` constructs a companion
    /// snapshot.
    public var displayNameSource: AgentDisplayNameSource
    /// One in-flight automatic proposal, or nil when a human rename (or a
    /// completed proposal) owns the title again.
    public var namingRequest: NamingRequest?
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
    /// The durable slot this child owns in its parent's name space. It is
    /// assigned at spawn, including for children whose final name uses a higher
    /// precedence rung, so a later ordinal fallback can never reuse a learned
    /// sibling number after deletion.
    public var parentRelativeOrdinal: Int?
    /// The next unused child slot for this parent. It is persisted on the parent
    /// rather than recomputed from current siblings, because archiving a sibling
    /// must not renumber the names a human has already seen.
    public var nextChildOrdinal: Int
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

    /// Derive lifecycle from persisted facts and current observations. No result
    /// is stored on `AgentRecord`; every reader gets a fresh answer.
    public func lifecycle(
        facts: AgentLifecycleFacts = AgentLifecycleFacts(),
        autoSettleAfter: TimeInterval? = nil,
        now: Date
    ) -> InboxLifecycle {
        InboxLifecycle.resolve(
            override: settledOverride,
            blockers: facts.lifecycleBlockers(now: now),
            settledAt: settledAt,
            snoozedUntil: snoozedUntil,
            archivedAt: archivedAt,
            lastActivityAt: lastActivityAt,
            autoSettleAfter: autoSettleAfter,
            now: now
        )
    }

    /// The settle action uses the exact same blocker predicate and shared
    /// lifecycle/action decision as the classifier. The builder folds the
    /// descendant hold into `facts` before calling this; the view's rollup is a
    /// structural witness for the same row-level action predicate.
    public func canSettle(
        facts: AgentLifecycleFacts = AgentLifecycleFacts(),
        autoSettleAfter: TimeInterval? = nil,
        now: Date
    ) -> Bool {
        let blocked = facts.blocksSettlement(now: now)
        return InboxSettlement.canSettle(
            lifecycle: lifecycle(facts: facts, autoSettleAfter: autoSettleAfter, now: now),
            blocked: blocked
        )
    }

    /// Resolve the display title for a derived spawn. This is the only precedence
    /// ladder: explicit name, first prompt, source item, then parent-relative
    /// ordinal. Identifier-shaped automatic candidates are skipped rather than
    /// promoted into the subject line; model, role, and UUID remain metadata.
    public static func resolveDerivedDisplayName(
        explicitName: String? = nil,
        firstPrompt: String? = nil,
        sourceItemId: String? = nil,
        parentName: String? = nil,
        parentRelativeOrdinal: Int? = nil,
        model: String? = nil,
        role: String? = nil,
        id: UUID? = nil
    ) -> AgentDisplayNameProposal? {
        if let explicitName,
           let name = AgentName.fromExplicitName(explicitName),
           !AgentName.isIdentifier(name, model: model, role: role, id: id) {
            return AgentDisplayNameProposal(name: name, source: .manual)
        }
        if let firstPrompt,
           let name = AgentName.fromPrompt(firstPrompt),
           !AgentName.isIdentifier(name, model: model, role: role, id: id) {
            return AgentDisplayNameProposal(name: name, source: .prompt)
        }
        if let sourceItemId,
           let name = AgentName.fromSourceItem(sourceItemId),
           !AgentName.isIdentifier(name, model: model, role: role, id: id) {
            return AgentDisplayNameProposal(name: name, source: .sourceItem)
        }
        if let parentRelativeOrdinal,
           let name = AgentName.fromParent(parentName, ordinal: parentRelativeOrdinal) {
            return AgentDisplayNameProposal(name: name, source: .parent)
        }
        return nil
    }

    public init(
        schemaVersion: Int = AgentRecord.currentSchemaVersion,
        id: AgentID,
        displayName: String,
        displayNameSource: AgentDisplayNameSource = .manual,
        namingRequest: NamingRequest? = nil,
        role: String? = nil,
        model: String,
        thinking: String,
        cwd: String,
        worktreeBranch: String? = nil,
        projectId: UUID? = nil,
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
        parentRelativeOrdinal: Int? = nil,
        nextChildOrdinal: Int = 1,
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
        self.displayNameSource = displayNameSource
        self.namingRequest = namingRequest
        self.role = role
        self.model = model
        self.thinking = thinking
        self.cwd = cwd
        self.worktreeBranch = worktreeBranch
        self.projectId = projectId
        self.parentAgentID = parentAgentID
        self.sourceItemId = sourceItemId
        self.parentRelativeOrdinal = parentRelativeOrdinal
        self.nextChildOrdinal = max(1, nextChildOrdinal)
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.tileId = tileId
        self.settledOverride = settledOverride
        self.settledAt = settledAt
        self.snoozedUntil = snoozedUntil
        self.snoozedAt = snoozedAt
        self.archivedAt = archivedAt
    }

    /// Defensive read for legacy records that used a model id, role id, UUID, or
    /// blank value as the title. The raw value remains available for migration
    /// diagnostics, but every presentation path has a safe human projection.
    public var displayNameIsIdentifier: Bool {
        AgentName.isIdentifier(displayName, model: model, role: role, id: id.rawValue)
    }

    /// The local, human-facing title. Prompt provenance is intentionally retained
    /// here for the desktop row; `syncDisplayName` is the boundary-safe twin.
    public var humanDisplayName: String {
        guard let label = AgentName.normalizedLabel(displayName),
              displayNameSource == .manual || !displayNameIsIdentifier else {
            return Self.defaultAgentName
        }
        return label
    }

    /// The only name projection allowed into an activity/sync snapshot. Prompt,
    /// source-item, and parent-derived names are useful locally but remain
    /// automatic/tainted text at the boundary; the payload gets the sentinel.
    public var syncDisplayName: String {
        switch displayNameSource {
        case .prompt, .sourceItem, .parent, .sentinel:
            // `.sentinel` means the provenance is not permissioned for a human
            // title. Keep even a malformed sentinel record redacted at the
            // boundary; a decoded unknown source is normalized to this case.
            return Self.defaultAgentName
        case .manual:
            return humanDisplayName
        }
    }

    /// Normalize one record read from disk and report whether its bytes should be
    /// rewritten. Identifier-shaped and blank legacy names become the sentinel;
    /// ordinary names receive the same cap/whitespace policy as new names.
    @discardableResult
    public mutating func migrateDisplayNameIfNeeded() -> Bool {
        let normalized = AgentName.normalizedLabel(displayName)
        // A source marked `.manual` is provenance-confirmed, not a legacy guess.
        // Identifier-shaped text is migrated only when it still carries an
        // automatic source; an exact human choice such as `operator`, the model
        // id/suffix, or a UUID is left intact.
        let invalid = normalized == nil
            || (displayNameIsIdentifier && displayNameSource != .manual)
        let desiredName = invalid ? Self.defaultAgentName : (normalized ?? Self.defaultAgentName)
        let desiredSource = invalid ? AgentDisplayNameSource.sentinel : displayNameSource
        guard displayName != desiredName || displayNameSource != desiredSource else { return false }
        displayName = desiredName
        displayNameSource = desiredSource
        return true
    }

    /// Arm one automatic name proposal and capture the exact title it is allowed
    /// to replace. A later call supersedes the earlier request by id.
    @discardableResult
    public mutating func beginNamingRequest(id: UUID = UUID()) -> NamingRequest {
        let request = NamingRequest(id: id, expectedName: displayName)
        namingRequest = request
        return request
    }

    /// Complete an automatic proposal only through the request's compare-and-swap.
    /// The marker and the expected title are checked together on the way out; a
    /// check made only before starting the work leaves a human rename vulnerable
    /// to a late completion. Generated names are automatic/prompt-derived for the
    /// sync boundary even though they were authored by a provider.
    @discardableResult
    public mutating func applyGeneratedName(_ generatedName: String, for request: NamingRequest) -> Bool {
        guard namingRequest?.id == request.id,
              displayName == request.expectedName else { return false }
        guard let normalized = AgentName.normalizedLabel(generatedName),
              !AgentName.isIdentifier(normalized, model: model, role: role, id: id.rawValue) else {
            namingRequest = nil
            return false
        }
        displayName = normalized
        displayNameSource = .prompt
        namingRequest = nil
        return true
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
        case schemaVersion, id, displayName, displayNameSource, namingRequest, role, model, thinking, cwd
        case worktreeBranch, projectId, parentAgentID, sourceItemId
        case parentRelativeOrdinal, nextChildOrdinal
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
        // A pre-provenance record has no source field. Identifier-shaped and
        // blank legacy seeds were automatic, while every other old title is
        // treated as a human name. A record that carries `.manual` is explicit
        // provenance and must win even when its text happens to equal metadata.
        // A PRESENT but unknown source is different: its text has no trusted
        // provenance, so both the source and the rendered value fail closed.
        if let rawSource = try container.decodeIfPresent(String.self, forKey: .displayNameSource) {
            if let decodedSource = AgentDisplayNameSource(rawValue: rawSource) {
                displayNameSource = decodedSource
            } else {
                displayName = Self.defaultAgentName
                displayNameSource = .sentinel
            }
        } else {
            displayNameSource = AgentName.normalizedLabel(displayName) == nil
                || AgentName.isIdentifier(displayName, model: model, role: role, id: id.rawValue)
                ? .sentinel
                : .manual
        }
        namingRequest = try container.decodeIfPresent(NamingRequest.self, forKey: .namingRequest)
        thinking = try container.decode(String.self, forKey: .thinking)
        cwd = try container.decode(String.self, forKey: .cwd)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        parentAgentID = try container.decodeIfPresent(AgentID.self, forKey: .parentAgentID)
        sourceItemId = try container.decodeIfPresent(String.self, forKey: .sourceItemId)
        parentRelativeOrdinal = try container.decodeIfPresent(Int.self, forKey: .parentRelativeOrdinal)
        nextChildOrdinal = max(1, try container.decodeIfPresent(Int.self, forKey: .nextChildOrdinal) ?? 1)
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
        try container.encode(displayNameSource, forKey: .displayNameSource)
        try container.encodeIfPresent(namingRequest, forKey: .namingRequest)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(model, forKey: .model)
        try container.encode(thinking, forKey: .thinking)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try container.encodeIfPresent(projectId, forKey: .projectId)
        try container.encodeIfPresent(parentAgentID, forKey: .parentAgentID)
        try container.encodeIfPresent(sourceItemId, forKey: .sourceItemId)
        try container.encodeIfPresent(parentRelativeOrdinal, forKey: .parentRelativeOrdinal)
        if nextChildOrdinal != 1 {
            try container.encode(nextChildOrdinal, forKey: .nextChildOrdinal)
        }
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
