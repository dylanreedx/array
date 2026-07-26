import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
//
// "I'm done with this" as a real, persisted, reversible fact — the thing that
// turns a status list into an inbox. **Locked: full settle / snooze / archive.**
//
// This file holds the STORED vocabulary only. Two things it deliberately does
// not do:
//
//   · It does not compute the lifecycle. `InboxLifecycle` (the derived,
//     four-case answer a row is drawn from) is P4.2's pure function over these
//     facts. This ticket only stores them.
//   · It does not re-declare `InboxLifecycle`. That type already exists in this
//     module — `AgentInboxRow.swift`, landed by P3.1 — and in a STRICTLY RICHER
//     form than this packet's sketch: `settled(at: Date)` and
//     `snoozed(until: Date)` carry their dates in the case, which is what lets
//     `InboxSort` order history by when work ENDED with no fallback for a
//     settled row that has no end time. Declaring a second one here would be a
//     redeclaration, and the weaker spelling would be a regression. The packet's
//     sketch is satisfied by the type that is already there.
//
// AgentUI is Foundation-only and has no dependencies (Package.swift: the
// direction is Core → AgentUI, never the reverse), so this enum is safe for
// `AgentRecord` in Core AND for iOS to consume.

/// What the HUMAN said about whether an agent still wants attention — three
/// states, not a boolean.
///
/// The tri-state is the whole point: `.settled` is "I said done", `.active` is
/// an explicit **keep-active pin** that suppresses the auto-settle rules
/// (P4.3), and `.neutral` lets those rules decide. A two-state boolean cannot
/// express the pin — it collapses "I want this to stay up" into the same value
/// as "I have not said anything", and the first auto-settle sweep then buries a
/// row the human deliberately kept.
///
/// `String`-backed and `Codable` so it persists as a readable word rather than
/// an ordinal a reordering of the cases would silently repoint.
public enum SettledOverride: String, Codable, CaseIterable, Sendable {
    /// "I said done." Outranked by a real blocker — P4.2 rules that.
    case settled
    /// A keep-active pin: the auto rules may not settle this row.
    case active
    /// Nothing said; the auto rules decide. The default for every new agent.
    case neutral

    /// What a record carries when nobody has said anything about it — including
    /// every record written before this ticket existed, which decodes with the
    /// key absent.
    public static let `default`: SettledOverride = .neutral

    /// Decode-forward: a value written by a NEWER build (a fourth case, say)
    /// reads as `.neutral` rather than throwing and taking the whole record —
    /// and with it the agent — down with it. Losing one human decision on a
    /// downgrade is recoverable; losing the agent record is not.
    ///
    /// This is not hypothetical: `AgentRecordChecks`'s decode-forward fixture
    /// has carried an unknown `"settledOverride": "snoozed"` since P2A.1, from
    /// back when the key was unknown to this build entirely. It still decodes.
    public init(persistedRawValue: String?) {
        guard let persistedRawValue,
              let known = SettledOverride(rawValue: persistedRawValue)
        else {
            self = .default
            return
        }
        self = known
    }

    /// Decoding an override DIRECTLY is tolerant too, not just the hand-written
    /// path `AgentRecord` takes through `init(persistedRawValue:)`.
    ///
    /// From cross-review (codex, gpt-5.5): with the synthesised raw-value
    /// `Codable`, `JSONDecoder().decode(SettledOverride.self, …)` would throw on
    /// a word from a newer build while `AgentRecord` — which decodes a `String`
    /// by hand — would not. Two decode-forward behaviours for one type is the
    /// kind of split that is fine until the second consumer arrives (iOS, or a
    /// settings blob) and inherits the strict one by accident. One rule, in the
    /// type.
    ///
    /// `encode(to:)` stays synthesised: writing is never lossy.
    public init(from decoder: Decoder) throws {
        self.init(persistedRawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P4.2-effective-settled.md
//
// THE LOAD-BEARING RULE OF THE INBOX: work that needs a human stays visible even
// when the human said "done". Without it an agent can be settled and then
// silently start waiting on an approval nobody ever sees — the failure mode the
// whole inbox exists to prevent.

/// What an agent is blocked ON, when something about its own execution makes it
/// un-settleable. Four facts, any combination of which can hold at once, which is
/// why this is a set and not an enum.
///
/// SEPARATE FROM `InboxState` on purpose, though they overlap. `InboxState` is
/// what a row SAYS (five states, three colours — P3.2); this is what a row may
/// not be HIDDEN for. The two are not the same list: `.queuedTurn` and
/// `.sessionStarting` are invisible in the state vocabulary (both read as
/// `.working` at most, or as nothing at all before the first event lands) and yet
/// each means a turn is about to produce something, so settling through one buries
/// output that has not happened yet. Deriving blockers from `InboxState` would
/// therefore lose two of the four.
///
/// `Hashable` so the ~30-case precedence matrix can enumerate combinations as
/// set elements, and `Sendable`/Foundation-only like everything else in this
/// module.
public struct LifecycleBlockers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// An approval the adapter is holding open. The named regression case: a
    /// `.settled` agent with one of these MUST resolve `.active`.
    public static let pendingApproval = LifecycleBlockers(rawValue: 1 << 0)
    /// The agent asked a question with no request to approve (`PendingRequest.input`).
    public static let pendingInput = LifecycleBlockers(rawValue: 1 << 1)
    /// A session that is starting or running — a turn is in flight.
    public static let sessionRunning = LifecycleBlockers(rawValue: 1 << 2)
    /// A turn is queued behind the current one, so more output is coming.
    public static let queuedTurn = LifecycleBlockers(rawValue: 1 << 3)

    /// Nothing is blocking. Spelled `unblocked` rather than `none`, because
    /// `Optional.none` makes a `.none` member of an `OptionSet` ambiguous at
    /// call sites that pass it to an optional parameter.
    public static let unblocked: LifecycleBlockers = []

    /// Every blocker there is — the `.settled`-cannot-hide witness enumerates
    /// this rather than a hand-written list, so a fifth blocker is covered the
    /// moment it is declared.
    public static let all: [LifecycleBlockers] = [
        .pendingApproval, .pendingInput, .sessionRunning, .queuedTurn,
    ]

    /// True when ANY blocker holds. One bit, so the precedence step below reads as
    /// the rule it implements.
    public var isBlocking: Bool { !isEmpty }

    /// The blockers implied by a `PendingRequest` — the fact P3.1 already derives
    /// from the event ring, mapped rather than re-derived here.
    public static func forPending(_ pending: PendingRequest?) -> LifecycleBlockers {
        switch pending {
        case .approval: return .pendingApproval
        case .input: return .pendingInput
        case nil: return .unblocked
        }
    }

    // Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md

    /// This agent's blockers TOGETHER WITH ITS DESCENDANTS' — the rule that makes a
    /// parent un-settleable while anything under it is blocked or running.
    ///
    /// It is deliberately a fold into the EXISTING blocker set rather than a new rung
    /// in `resolve`: "a child is blocked" is not a different kind of fact from "I am
    /// blocked", it is the same fact seen from one row up, so it earns the same
    /// precedence — step 1, above an explicit `.settled` — with no second ordering to
    /// keep in sync. `resolve` is untouched, and everything already proved about it
    /// (the 31-case table, the 1,728-case sweep) covers the parent case unchanged.
    ///
    /// DESCENDANTS, not direct children, matching `ChildRollup`: a collapsed root
    /// hides its grandchildren too, and settling through a blocked grandchild buries
    /// it just as completely. Union is associative and idempotent, so composing it
    /// one level at a time up a chain gives the same answer as one flat call — which
    /// is what lets a caller reuse a child's already-rolled-up set.
    ///
    /// Blockers are NOT derivable from a row's `InboxState` (the reason this takes
    /// values rather than rows): `.sessionRunning` and `.queuedTurn` are invisible in
    /// the five-state vocabulary, and they are two of the four things "running" means
    /// here. Whoever supplies the parent's own blockers supplies its descendants'.
    public func includingDescendants(_ descendants: [LifecycleBlockers]) -> LifecycleBlockers {
        descendants.reduce(self) { $0.union($1) }
    }
}

extension InboxLifecycle {
    /// The one pure function that turns P4.1's stored facts into the lifecycle a
    /// row is drawn from. TOTAL — every combination of inputs resolves to exactly
    /// one case — and pure: `now` is a parameter, never `Date()`, or the checks
    /// could not pin behaviour.
    ///
    /// PRECEDENCE, in the order it is evaluated, and why each rung sits where it
    /// does:
    ///
    ///   0. **`archivedAt` → `.archived`.** Archiving is not a stronger settle, it
    ///      is leaving the list (`_RUNBOOK.md`: archived ≠ settled), and by the
    ///      time it is set `AgentSupervisor.archive` has already stopped the runner
    ///      and deleted the record — so there is no live blocker left for step 1 to
    ///      find, and answering `.active` for an agent that is gone would resurrect
    ///      a row pointing at nothing. This is the one rung above blockers.
    ///   1. **Any blocker → `.active`.** This beats EVERYTHING below it, including
    ///      an explicit `settledOverride == .settled`. It is the packet's whole
    ///      point and both named witnesses live here.
    ///   2. **An unexpired snooze → `.snoozed(until:)`.** Above the override rungs
    ///      because a snooze is the only instruction here that carries a future
    ///      date: resolving a snoozed-and-settled agent as `.settled` would strand
    ///      the wake-up in history and the row would never come back, whereas
    ///      deferring the override loses nothing — it is still stored, and it
    ///      re-resolves the instant the snooze expires. The overlay reading holds
    ///      either way (P4.6's raised hand arrives as a blocker, which is step 1,
    ///      so a hand still pulls a snoozed row back).
    ///   3. `settledOverride == .settled` → `.settled`. "I said done."
    ///   4. `settledOverride == .active` → `.active`. The keep-active pin, which is
    ///      ABOVE the inactivity rung and therefore suppresses auto-settle — the
    ///      reason the override is a tri-state at all (P4.1).
    ///   5. **Inactivity past `autoSettleAfter` → `.settled`.** Reachable only on a
    ///      `.neutral` override. In SECONDS, so this file needs no calendar; the
    ///      window is supplied by `AgentAutoSettleConfig` in Core (P4.3:
    ///      `autoSettleAfterDays`, default 3, clamped to 1–90, `"Off"` = nil), which
    ///      does the days→seconds conversion. nil means no auto-settle is
    ///      configured, and the comparison is against `lastActivityAt` — the
    ///      AGENT's last activity, never when the human last read the row, or
    ///      looking at a row would keep it alive forever.
    ///   6. Otherwise `.active`.
    ///
    /// WHERE THE SETTLED DATE COMES FROM, since `.settled(at:)` carries one (P3.4
    /// orders history by when work ENDED and deliberately has no fallback for a
    /// settled row without a date): `settledAt` when the human's decision was
    /// recorded, else `lastActivityAt`, else `now`. The auto-settle rung uses
    /// `lastActivityAt` outright — the work ended when it went quiet, not when the
    /// sweep noticed.
    ///
    /// NOTHING CALLS THIS YET. The packet's `## Files` name this file and its
    /// checks; the writers of these facts are P4.3–P4.6 and the reader is the
    /// row builder once one of them wires a fact. Same shape as P3.4's
    /// `sortForInbox`, which landed a run before its list view.
    public static func resolve(
        override: SettledOverride,
        blockers: LifecycleBlockers = .unblocked,
        settledAt: Date? = nil,
        snoozedUntil: Date? = nil,
        archivedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        autoSettleAfter: TimeInterval? = nil,
        now: Date
    ) -> InboxLifecycle {
        // 0 · Out of the list entirely.
        if archivedAt != nil { return .archived }

        // 1 · A blocker outranks user intent. THE rule.
        if blockers.isBlocking { return .active }

        // 2 · The snooze shelf, while the snooze is still in the future. `>` and
        // not `>=`: a snooze whose moment has arrived is over.
        if let snoozedUntil, snoozedUntil > now { return .snoozed(until: snoozedUntil) }

        switch override {
        case .settled:
            // 3 · "I said done."
            return .settled(at: settledAt ?? lastActivityAt ?? now)
        case .active:
            // 4 · The keep-active pin, ahead of the inactivity rung.
            return .active
        case .neutral:
            // 5 · Auto-settle on inactivity (P4.3 supplies the window).
            if let autoSettleAfter, let lastActivityAt,
               now.timeIntervalSince(lastActivityAt) >= autoSettleAfter {
                return .settled(at: lastActivityAt)
            }
            // 6 · Nothing said, nothing stale, nothing blocking.
            return .active
        }
    }
}
