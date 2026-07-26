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
