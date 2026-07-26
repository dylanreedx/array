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

/// What the agent is doing. FIVE STATES, and only three MEANINGS get colour:
/// **in motion** (`working`), **act now** (`approval`, `input`) and **broken**
/// (`failed`). The resting state is deliberately unlabelled and uncoloured.
///
/// `ready` is that resting state: the agent stopped and is waiting on you,
/// whatever the reason (finished, asked, proposed a plan). It is NOT an error,
/// so it gets no accent — see `accent`, where the nil is the whole point.
public enum InboxState: String, CaseIterable, Equatable, Sendable {
    case working
    case approval
    case input
    case failed
    case ready

    /// The row's accent, or **nil for `ready`** — colour is reserved for meaning
    /// (P3.2), and the resting state has none to carry.
    ///
    /// Tokens, never hues: every value here is a P1.3 `AccentToken`, so the
    /// colours are appearance-aware and already gated on all eleven surfaces in
    /// both themes by `runDesignTokenChecks`. Nothing in the inbox may pick a
    /// colour of its own.
    ///
    /// AGREEMENT WITH `StatusChipPresenter` (P1.8, the single status presenter):
    /// where the two vocabularies say the same thing they use the same token —
    /// `working`/`accentWorking` and `approval`/`accentApproval`. They diverge in
    /// exactly two places, both deliberate and both pinned in
    /// `runAgentInboxRowChecks` rather than left to drift:
    ///
    ///   * `configuring` is `accentInput` violet as a chip but folds into
    ///     `.working` here — "getting ready" is in motion, and a sixth state is
    ///     what this ticket exists to forbid;
    ///   * `idle`/`stale`/`done` are painted by the chip (muted, or green) but
    ///     resolve to the uncoloured resting state here. A chip always paints
    ///     something; a row does not have to, and this is where colour is saved.
    public var accent: AccentToken? {
        switch self {
        case .working: return .accentWorking
        case .approval: return .accentApproval
        case .input: return .accentInput
        case .failed: return .accentFailed
        case .ready: return nil
        }
    }

    /// The state's own label, or **nil for `ready`** — same reason as `accent`.
    ///
    /// This is the head of the packet's label priority
    /// (`working → approval → input → failed → (woke) → (done) → relative
    /// timestamp`): a state that carries a label wins the row's one label slot.
    /// The tail belongs to its owners and is not invented here — `(woke)` is
    /// `InboxAttention` (P3.3) and `(done)`/settled is `InboxLifecycle` (P4.1),
    /// with the relative timestamp as the last resort when nothing above speaks.
    public var label: String? {
        switch self {
        case .working: return "Working"
        case .approval: return "Approval"
        case .input: return "Input"
        case .failed: return "Failed"
        case .ready: return nil
        }
    }
}

/// What the agent is blocked on, when it is blocked on you. The fact
/// `AgentStatus` cannot carry: `needsAttention` says *something* is wanted, not
/// which of the two things it is.
///
/// It lives here rather than in Core so the mapping below stays pure and shared
/// (this module may not import Core — P1.1). Core derives it from the event ring
/// in `AgentsBoardProjection.pendingRequest(in:)`.
public enum PendingRequest: String, CaseIterable, Equatable, Sendable {
    /// An approval the adapter is holding open — it has a request id to answer.
    case approval
    /// The agent asked you something with no request to approve.
    case input
}

/// Whether the row is YOURS to look at — a separate axis from `InboxState`,
/// because a finished-but-unseen agent and one you already reviewed report the
/// same state and are not the same thing.
///
/// The two facts behind it are unrelated and can hold at once, which is what
/// `resolve(unread:raisedHand:)` exists for: a snoozed agent that raised its hand
/// while you were elsewhere is BOTH woke and unread, and the row has one slot.
/// Read-state itself is desktop-local (`AgentSupervisor`, P3.3) and never synced —
/// it is per-human and per-device, so a phone marking a row read is not this Mac
/// having looked at it.
public enum InboxAttention: String, CaseIterable, Equatable, Sendable {
    case none
    case unread
    case woke

    /// The rung this axis contributes to the row's label priority, below the four
    /// coloured states (P3.2) and above `(done)` / the relative timestamp.
    ///
    /// **nil for `unread`, deliberately.** Unread is a MARK, not a word: every
    /// resting row in a busy inbox would otherwise read "Unread", which says
    /// nothing the absence of a mark does not. `woke` gets a word because it is the
    /// one thing that put the row back in front of you.
    public var label: String? {
        switch self {
        case .none, .unread: return nil
        case .woke: return "Woke"
        }
    }

    /// True when the row is asking for your eyes at all — the axis reduced to the
    /// one bit a mark renders.
    public var isYours: Bool { self != .none }

    /// The single value for a row whose two facts are known independently.
    ///
    /// TOTAL and order-independent, so no caller has to remember the precedence:
    /// `raisedHand` is P4.6's (a snoozed agent's hand), `unread` is P3.3's
    /// read-state.
    public static func resolve(unread: Bool, raisedHand: Bool) -> InboxAttention {
        if raisedHand { return .woke }
        return unread ? .unread : .none
    }
}

/// Settle / snooze / archive (locked decision). P4.1 owns the persisted facts and
/// P4.2 the derivation; this ticket only names the vocabulary the row carries, and
/// every row it builds today is `.active`.
public enum InboxLifecycle: Equatable, Sendable {
    case active
    case snoozed(until: Date)
    /// P3.4: settled rows are HISTORY, and history is ordered by when the work
    /// ended — so the date is carried by the case rather than sitting beside it as
    /// an optional. A settled row without an end time cannot be constructed, which
    /// is why `InboxSort` needs no fallback for one. Same shape as
    /// `snoozed(until:)`.
    case settled(at: Date)
    case archived

    /// The moment the work ended, for the one lifecycle that has one.
    ///
    /// `snoozed` deliberately does not answer: its date is in the FUTURE (when the
    /// row comes back), and treating it as an end time would sort a snoozed row
    /// into history ahead of everything that really finished.
    public var endedAt: Date? {
        switch self {
        case .settled(let at): return at
        case .active, .snoozed, .archived: return nil
        }
    }
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

// Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
/// How loud the row is drawn. Counter-intuitive and deliberate: **the rows that
/// recede are the ones still in motion**, because prominence belongs to what
/// needs a human — a working thread is not your problem yet, and a finished
/// turn you have not read is.
///
/// Two values, not a scale: an emphasis ladder invites a third rung, and the
/// only distinction the list can make legibly at row height is "yours" vs "not
/// yet".
///
/// NOTHING PAINTS THIS YET, and that is not an omission: the packet's second
/// file is "the list view (P3.6)", which does not exist — this module is
/// Foundation-only and there is no inbox list to fade. What lands here is the
/// derivation and its gate. When P3.6 paints a row it must apply `textOpacity`
/// to the row's TEXT LAYER, never to a container the status accent is inside
/// (a container alpha would fade the accent with it, which is exactly what
/// `accentOpacity` exists to forbid), and pass hover/selection/keyboard-active
/// into `emphasis(for:attention:isInteracting:)`. Those are rendered facts, so
/// their witness is a P3.6 pixel/contrast probe over the real row, not an
/// assertion this module can make.
public enum RowEmphasis: String, CaseIterable, Equatable, Sendable {
    case full
    case receded

    /// The alpha the row's TEXT is painted at — a P1.3 token, never a literal
    /// at the call site, and bounded by the AA floor (see `Opacity`).
    public var textOpacity: Double {
        switch self {
        case .full: return Opacity.full
        case .receded: return Opacity.receded
        }
    }

    /// The alpha the row's STATUS ACCENT is painted at — always full, even when
    /// the row recedes. Fading the one coloured thing on a waiting row is how a
    /// waiting row becomes unfindable, so the accent is exempt by construction
    /// rather than by the list view remembering to skip it. It is a property and
    /// not a constant so P3.6 reads the rule off the emphasis it already has.
    public var accentOpacity: Double { Opacity.full }
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
    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// The workspace the agent's tile is in (`AgentRowContext.workspaceName`), and
    /// NOT DRAWN ANYWHERE: the row shows the project chip and no second one.
    ///
    /// It is on the row because `InboxScope` offers "one per workspace" and a pure
    /// filter can only read what the row carries — the alternative is the view
    /// reaching back into Core for a join it was handed. nil for an agent with no
    /// tile (a headless agent lives in no workspace) and for any caller that built
    /// rows with no context, exactly like `projectName` beside it.
    public let workspaceName: String?
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
    /// When the agent was SPAWNED — the row's frozen position in the desktop list
    /// (P3.4), and the one timestamp this type may sort on.
    ///
    /// It is the agent's own creation date (`AgentRecord.createdAt`, or a terminal
    /// session's `TerminalSessionDescriptor.createdAt`), never a last-activity or
    /// last-updated time: an activity timestamp is exactly what makes a list jump
    /// while you read it, which is the thing the locked frozen order forbids.
    ///
    /// Required, with no default: a row that does not know when its agent started
    /// has no position, and a defaulted "now" would put every such row at the top
    /// of the list — the loudest possible way to be wrong.
    public let createdAt: Date
    /// The agent that spawned this one (P2D.4), in the same aggregate keyspace as
    /// `id`. nil for a top-level agent.
    ///
    /// `depth` says how deep the row is drawn; this says WHOSE child it is, which
    /// is what `InboxSort` needs to place a child immediately after its parent —
    /// a depth alone cannot tell two orchestrators' children apart.
    public let parentId: UUID?

    public init(
        id: UUID,
        title: String,
        projectName: String? = nil,
        workspaceName: String? = nil,
        state: InboxState,
        attention: InboxAttention = .none,
        lifecycle: InboxLifecycle = .active,
        model: String? = nil,
        role: String? = nil,
        branch: String? = nil,
        isIsolated: Bool = false,
        elapsed: TimeInterval? = nil,
        depth: Int = 0,
        variant: RowVariant = .card,
        createdAt: Date,
        parentId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.workspaceName = workspaceName
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
        self.createdAt = createdAt
        self.parentId = parentId
    }

    /// The row's ONE label, resolved down the packet's priority:
    /// `working → approval → input → failed → (woke) → (done) → relative timestamp`.
    ///
    /// The head is `InboxState.label` (P3.2, which is why state wins outright); this
    /// ticket adds the `(woke)` rung under it, so a woke agent that is also working
    /// still reads "Working" — what it is doing outranks how it got back here. The
    /// tail is not invented: `(done)` is P4.1's `InboxLifecycle` and the relative
    /// timestamp is the list view's, so a row with nothing above them says nothing
    /// rather than guessing at a word.
    public var label: String? { state.label ?? attention.label }

    // Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
    /// How loud to draw this row. Pure, and a function of the two axes only —
    /// never of elapsed time, lifecycle or position, so the fade cannot become a
    /// second sort key.
    ///
    /// THE RULE, and why each half of it is the way round it is:
    ///
    ///   * `working` recedes. It is the one state where the agent, not you, has
    ///     the next move.
    ///   * `ready` recedes ONLY when it is already read. A finished turn you
    ///     have not looked at is the single most important row in the list; the
    ///     same row after you have read it is history that has not been settled
    ///     yet.
    ///   * `approval` and `input` NEVER recede, however busy the agent looks.
    ///     They are the act-now states — dimming one is the exact inversion of
    ///     the goal, and it is the packet's named regression witness.
    ///   * `failed` never recedes: broken is not background.
    ///   * `woke` never recedes, in ANY state. A raised hand is the thing that
    ///     put the row back in front of you, so it outranks in-motion here —
    ///     the opposite of the label priority, where `working` outranks `(woke)`
    ///     because there the question is "what is it doing", not "is this mine".
    ///
    /// `isInteracting` is hover / selection / keyboard-active, which clears
    /// recession outright: the row you are pointing at is yours by definition
    /// while you point at it. It is view state, so it is a parameter here rather
    /// than a field on the row — a row is a snapshot and does not know about a
    /// mouse. P3.6 passes it; the default is the un-pointed-at row.
    public static func emphasis(
        for state: InboxState,
        attention: InboxAttention,
        isInteracting: Bool = false
    ) -> RowEmphasis {
        if isInteracting { return .full }
        if attention == .woke { return .full }
        switch state {
        case .working:
            return .receded
        case .ready:
            return attention == .none ? .receded : .full
        case .approval, .input, .failed:
            return .full
        }
    }

    /// This row's emphasis at rest. The interacting case has no field to read
    /// from, so the list view calls `emphasis(for:attention:isInteracting:)`
    /// directly for a hovered or selected row.
    public var emphasis: RowEmphasis { AgentInboxRow.emphasis(for: state, attention: attention) }

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
    /// splits it into `.approval` vs `.input` using `pending`, which the status
    /// cannot distinguish, and answers to `.approval` when the caller has no such
    /// fact because a pending `approvalRequestId` is what raises the status today
    /// (`AgentsBoardProjection.respondableRequest`). Nothing maps to `.failed`
    /// yet: no `AgentStatus` records failure — Phase 4 does. The case stays,
    /// coloured and reachable by a caller, so Phase 4 wires a fact and not a state.
    ///
    /// PRECEDENCE — **`pending` outranks the status**, which is the one ordering
    /// the packet's verification pins ("a pending approval outranks `working`").
    /// An agent blocked on you is not in motion however busy its last event
    /// looked, and "act now" is the stronger of the three meanings colour is
    /// allowed to carry. Between the two pending kinds the packet's own order
    /// holds, `approval` before `input`; they are mutually exclusive by
    /// construction (`pendingRequest` returns one event's classification), so that
    /// tiebreak is a statement about this function, not a choice made per row.
    ///
    /// WHERE THAT ORDERING BITES, honestly: Core's `pendingRequest(in:)` reads the
    /// same ring element the fold derives the status from, so today it cannot hand
    /// this function a pending request alongside a `working` status — the two
    /// agree by construction. The precedence is a property of the mapping, checked
    /// as one, and it is what makes a caller holding a request the adapter is
    /// still blocking on — a live approval out-of-band of the ring, which P5.9
    /// introduces — correct without editing this function.
    ///
    /// `pending` defaults to nil so a caller that has only a status — the phone,
    /// a fixture — gets exactly the mapping P3.1 shipped.
    public static func state(for status: AgentStatus, pending: PendingRequest? = nil) -> InboxState {
        switch pending {
        case .approval:
            return .approval
        case .input:
            return .input
        case nil:
            break
        }
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
