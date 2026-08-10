import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.1-inbox-row-model.md
//
// The row VOCABULARY, checked where it lives — in the module that has no AppKit
// and no Core, so these properties hold on iOS too. The JOIN that builds rows out
// of a snapshot is Core's and is checked in
// ContinuumRevivedCoreChecks/AgentInboxRowBuilderChecks.swift; nothing here needs
// a snapshot.
//
// Four properties:
//   1. TOTALITY — every `AgentStatus` resolves to exactly one `InboxState`, and
//      the specific mapping is pinned, not just "some state came back". The
//      compiler already forbids a missing case (no `default:`); what it cannot
//      catch is a status quietly re-pointed at the wrong state.
//   2. WHICH STATES A STATUS CANNOT REACH — `.input` and `.failed` are not
//      derivable from a status and must stay unreachable until P3.2 supplies the
//      pending-request fact. Pinned so that "everything maps to ready" cannot
//      creep in.
//   3. IDENTITY — `Identifiable.id` is the agent id it was built with, unchanged
//      by anything else on the row. List diffing is keyed on it.
//   4. VARIANT FOLLOWS LIFECYCLE — parked work collapses, nothing else does.
//
// Ticket: docs/38-tickets/90-agent-ux/P3.2-five-states-three-colours.md
//   5. COLOUR IS RESERVED FOR MEANING — `ready` has NO accent and NO label, the
//      other four have a distinct P1.3 token each, and no state invents a hue.
//      The nil is the assertion: giving `ready` a colour turns this red.
//   6. PENDING OUTRANKS STATUS — a pending approval beats `working`, and the
//      approval/input split that `AgentStatus` cannot express.
//   7. AGREEMENT WITH THE ONE STATUS PRESENTER — where the inbox vocabulary and
//      P1.8's chip say the same thing they use the same token, and the two places
//      they deliberately diverge are pinned so neither can drift silently.
//
// Ticket: docs/38-tickets/90-agent-ux/P3.5-in-flight-fade.md
//   9. IN-MOTION RECEDES, YOURS DOES NOT — the full state x attention matrix
//      against a table, an approval that recedes is red (the packet's named
//      regression witness), hover/selection clears recession, and the faded text
//      STILL clears 4.5:1 on every documented pair in both themes. The last one
//      is the rule that makes the opacity a measurement instead of a taste: the
//      token is the smallest hundredth that clears AA, and one hundredth deeper
//      is asserted to fail.
//
// Ticket: docs/38-tickets/90-agent-ux/P3.3-attention-axis.md
//   8. ATTENTION IS A SEPARATE AXIS — `resolve` is total over both facts, `woke`
//      outranks `unread`, and the axis is INDEPENDENT of state: every
//      (state, attention) pair is constructible, because a finished-but-unseen
//      agent and one you already reviewed report the same state. The row's label
//      priority puts the four coloured states above `(woke)`, and `unread`
//      contributes no word at all.

func runAgentInboxRowChecks() {
    runInboxStateTotalityCheck()
    runInboxRowIdentityCheck()
    runRowVariantCheck()
    runInboxStateAccentCheck()
    runInboxStatePrecedenceCheck()
    runInboxAccentAgreesWithStatusChipCheck()
    runInboxAttentionAxisCheck()
    runRowEmphasisChecks()
    print("AgentInboxRow checks: status totality, unreachable states, stable identity, lifecycle-driven variant, "
        + "uncoloured resting state, pending-over-status precedence, status-presenter agreement, "
        + "the attention axis and in-flight recession passed")
}

// MARK: - 1 & 2 · totality

private func runInboxStateTotalityCheck() {
    // Written as a table rather than a switch: a switch here would be the same
    // code under test, so it could only ever agree with itself.
    let expected: [AgentStatus: InboxState] = [
        .configuring: .working,
        .working: .working,
        .needsAttention: .approval,
        .idle: .ready,
        .done: .ready,
        .stale: .ready,
    ]
    expect(expected.count == AgentStatus.allCases.count,
           "the expectation table covers every AgentStatus — \(expected.count) of \(AgentStatus.allCases.count)")

    var mapped: Set<InboxState> = []
    for status in AgentStatus.allCases {
        guard let want = expected[status] else {
            fputs("FAIL: AgentInboxRow state totality — no expectation for \(status.rawValue)\n", stderr)
            Foundation.exit(1)
        }
        let got = AgentInboxRow.state(for: status)
        expect(got == want,
               "AgentStatus.\(status.rawValue) maps to \(want.rawValue), got \(got.rawValue)")
        mapped.insert(got)
    }

    // 2 · the two states a status cannot reach. `ready` is the resting state and
    // must NOT swallow `needsAttention`, which is the mistake this pins.
    expect(!mapped.contains(.input) && !mapped.contains(.failed),
           "no AgentStatus may resolve to .input or .failed — those need P3.2's pending-request fact, got \(mapped.map(\.rawValue).sorted())")
    expect(mapped == [.working, .approval, .ready],
           "the reachable-from-status states are exactly working/approval/ready, got \(mapped.map(\.rawValue).sorted())")

    // Deterministic: rows are rebuilt on every refresh.
    // (Spelled with a closure rather than an unapplied `AgentInboxRow.state(for:)`
    // since P3.2 gave the function a defaulted second parameter.)
    expect(AgentStatus.allCases.map { AgentInboxRow.state(for: $0) } == AgentStatus.allCases.map { AgentInboxRow.state(for: $0) },
           "AgentInboxRow.state(for:) must be a pure function of its status")

    print("AgentInboxRow state totality measured \(AgentStatus.allCases.map { "\($0.rawValue)->\(AgentInboxRow.state(for: $0).rawValue)" }.joined(separator: " "))")
}

// MARK: - 3 · identity

/// A fixed spawn time for the vocabulary fixtures. P3.4 made `createdAt` a
/// required fact on every row (it is the frozen list's only sort key); none of the
/// properties here depend on its value, so one canned date serves them all.
private let inboxRowSpawnedAt = Date(timeIntervalSinceReferenceDate: 806_700_000)

private func runInboxRowIdentityCheck() {
    let agentId = UUID(uuidString: "3B100000-0000-4000-8000-000000000001")!
    let other = UUID(uuidString: "3B100000-0000-4000-8000-000000000002")!

    let row = AgentInboxRow(id: agentId, title: "Reviewer", state: .ready, createdAt: inboxRowSpawnedAt)
    expect(row.id == agentId, "Identifiable.id is the agent id it was built with, got \(row.id)")

    // Everything else moving must NOT move the id: the list diffs on it, and a
    // row that changes identity when its status changes is a row that loses its
    // scroll position, its selection and its animation.
    let moved = AgentInboxRow(
        id: agentId,
        title: "Reviewer (renamed)",
        projectName: "Continuum",
        state: .working,
        attention: .unread,
        lifecycle: .settled(at: inboxRowSpawnedAt.addingTimeInterval(60)),
        model: "anthropic/claude-opus-5",
        role: "reviewer",
        branch: "agent/reviewer-1a2b3c4d",
        isIsolated: true,
        elapsed: 42,
        depth: 1,
        variant: .slim,
        createdAt: inboxRowSpawnedAt,
        parentId: other
    )
    expect(moved.id == row.id, "no field but the id changes the id, got \(moved.id) vs \(row.id)")
    expect(moved != row, "two rows that differ in every other field are not equal")
    expect(AgentInboxRow(id: other, title: "Reviewer", state: .ready, createdAt: inboxRowSpawnedAt) != row,
           "two rows with different ids are not equal")

    // Defaults are the "nothing is known yet" row Phase 3/4 fills in.
    expect(row.attention == .none && row.lifecycle == .active && row.depth == 0 && row.variant == .card,
           "a row defaults to active/unattended/top-level/card, got \(row)")
    // P3.4: a row is top-level unless it says otherwise, and `createdAt` has no
    // default at all — the compiler will not let a row exist without a position.
    expect(row.parentId == nil && row.createdAt == inboxRowSpawnedAt,
           "a row defaults to top-level and keeps the spawn time it was built with, got \(String(describing: row.parentId))")
    expect(row.elapsed == nil && row.branch == nil && !row.isIsolated,
           "a row defaults to no duration and no branch, got \(row)")
}

// MARK: - 4 · variant

private func runRowVariantCheck() {
    let until = Date(timeIntervalSinceReferenceDate: 806_600_000)
    let expected: [(InboxLifecycle, RowVariant)] = [
        (.active, .card),
        (.snoozed(until: until), .slim),
        (.settled(at: until), .slim),
        // Archived is drawn now (.plans/05-close-to-history.md: closing a tile
        // parks the agent in History instead of deleting it), and it is the most
        // parked thing in the list — so it collapses, like the other two parked
        // lifecycles. P4.1 left it a card only because nothing ever rendered one.
        (.archived(at: until), .slim),
    ]
    for (lifecycle, want) in expected {
        let got = RowVariant.forLifecycle(lifecycle)
        expect(got == want, "lifecycle \(lifecycle) renders \(want.rawValue), got \(got.rawValue)")
    }
    // The rule this exists to enforce: an active row is never slim, whatever its
    // state. Collapsing `ready` or `failed` is the density mistake P3.7 forbids.
    for state in InboxState.allCases {
        let row = AgentInboxRow(
            id: UUID(uuidString: "3B100000-0000-4000-8000-000000000003")!,
            title: "Agent",
            state: state,
            lifecycle: .active,
            variant: RowVariant.forLifecycle(.active),
            createdAt: inboxRowSpawnedAt
        )
        expect(row.variant == .card, "an active \(state.rawValue) row is a full card, got \(row.variant.rawValue)")
    }
}

// MARK: - 5 · colour is reserved for meaning

private func runInboxStateAccentCheck() {
    // A table again, not a switch: a switch would be the code under test.
    let expected: [InboxState: AccentToken?] = [
        .working: .accentWorking,
        .approval: .accentApproval,
        .input: .accentInput,
        .failed: .accentFailed,
        .ready: AccentToken?.none,
    ]
    expect(expected.count == InboxState.allCases.count,
           "the accent table covers every InboxState — \(expected.count) of \(InboxState.allCases.count)")

    for state in InboxState.allCases {
        guard let want = expected[state] else {
            fputs("FAIL: InboxState accents — no expectation for \(state.rawValue)\n", stderr)
            Foundation.exit(1)
        }
        expect(state.accent == want,
               "InboxState.\(state.rawValue) accent is \(want?.rawValue ?? "none"), got \(state.accent?.rawValue ?? "none")")
    }

    // THE REGRESSION WITNESS the packet names: the resting state carries no
    // colour and no label. Anything but nil here — including a "subtle" muted
    // token — is the mistake, so it is asserted on its own rather than only as a
    // table row.
    expect(InboxState.ready.accent == nil,
           "the resting state must have NO accent — colour marks act-now/in-motion/broken only, got \(InboxState.ready.accent?.rawValue ?? "none")")
    expect(InboxState.ready.label == nil,
           "the resting state is deliberately unlabelled, got \(InboxState.ready.label ?? "nil")")

    // Exactly one state is uncoloured, and no two coloured states share a hue —
    // otherwise "five states" could quietly collapse into four on screen.
    let coloured = InboxState.allCases.filter { $0.accent != nil }
    expect(coloured.map(\.rawValue).sorted() == ["approval", "failed", "input", "working"],
           "exactly working/approval/input/failed are coloured, got \(coloured.map(\.rawValue).sorted())")
    expect(Set(coloured.compactMap { $0.accent?.rawValue }).count == coloured.count,
           "each coloured state has an accent of its own, got \(coloured.compactMap { $0.accent?.rawValue }.sorted())")

    // Every accent is an existing P1.3 token, so the inbox cannot become a
    // private palette that escapes `runDesignTokenChecks`' contrast gate.
    for state in coloured {
        expect(AccentToken.allCases.contains(state.accent!),
               "InboxState.\(state.rawValue) uses a token from the gated palette, got \(state.accent!.rawValue)")
    }

    // A coloured state labels itself; that is the head of the label priority.
    for state in coloured {
        expect(state.label?.isEmpty == false,
               "InboxState.\(state.rawValue) carries a label, got \(state.label ?? "nil")")
    }

    print("InboxState accents measured \(InboxState.allCases.map { "\($0.rawValue)->\($0.accent?.rawValue ?? "none")" }.joined(separator: " "))")
}

// MARK: - 6 · a pending request outranks the folded status

private func runInboxStatePrecedenceCheck() {
    // The packet's named case: an agent whose fold still says `working` but that
    // is holding an unanswered approval is NOT in motion.
    expect(AgentInboxRow.state(for: .working, pending: .approval) == .approval,
           "a pending approval outranks working, got \(AgentInboxRow.state(for: .working, pending: .approval).rawValue)")
    expect(AgentInboxRow.state(for: .working, pending: .input) == .input,
           "a pending question outranks working, got \(AgentInboxRow.state(for: .working, pending: .input).rawValue)")

    // It outranks EVERY status, not just working — including the resting ones,
    // which is what stops an agent that asked something from sitting silently in
    // the list with no accent at all.
    for status in AgentStatus.allCases {
        for pending in PendingRequest.allCases {
            let got = AgentInboxRow.state(for: status, pending: pending)
            let want: InboxState = pending == .approval ? .approval : .input
            expect(got == want,
                   "\(status.rawValue) + pending \(pending.rawValue) is \(want.rawValue), got \(got.rawValue)")
            expect(got.accent != nil,
                   "an agent waiting on you is always coloured — \(status.rawValue) + \(pending.rawValue) got no accent")
        }
    }

    // THE SPLIT `AgentStatus` cannot express: one status, two states.
    expect(AgentInboxRow.state(for: .needsAttention, pending: .approval)
            != AgentInboxRow.state(for: .needsAttention, pending: .input),
           "needsAttention resolves to two different states depending on what is pending")

    // No fact means the P3.1 mapping, unchanged — the phone and every fixture
    // call the one-argument form and must get exactly what they got before.
    for status in AgentStatus.allCases {
        expect(AgentInboxRow.state(for: status) == AgentInboxRow.state(for: status, pending: nil),
               "the defaulted argument is the same call — \(status.rawValue)")
    }
    expect(AgentInboxRow.state(for: .needsAttention, pending: nil) == .approval,
           "needsAttention with no fact answers to approval (a request id is what raises it today), got \(AgentInboxRow.state(for: .needsAttention, pending: nil).rawValue)")

    // Nothing reaches `.failed` yet — Phase 4 supplies that fact. Pinned so a
    // stray mapping cannot start colouring rows red before it does.
    var reachable: Set<InboxState> = []
    for status in AgentStatus.allCases {
        reachable.insert(AgentInboxRow.state(for: status))
        for pending in PendingRequest.allCases {
            reachable.insert(AgentInboxRow.state(for: status, pending: pending))
        }
    }
    expect(reachable == [.working, .approval, .input, .ready],
           "status + pending reaches working/approval/input/ready and never failed, got \(reachable.map(\.rawValue).sorted())")
}

// MARK: - 7 · agreement with the one status presenter

private func runInboxAccentAgreesWithStatusChipCheck() {
    // Where the two vocabularies say the same thing, they must resolve to the
    // same token — the inbox row and the tile chip painting one agent in two
    // hues is exactly the drift P1.8 deleted five duplicate maps to end.
    for status in [AgentStatus.working, .needsAttention] {
        let state = AgentInboxRow.state(for: status)
        let chip = StatusChipPresenter.display(for: status)
        guard let accent = state.accent else {
            fputs("FAIL: \(status.rawValue) maps to the uncoloured state \(state.rawValue)\n", stderr)
            Foundation.exit(1)
        }
        expect(accent.color == chip.accent,
               "\(status.rawValue): the inbox accent and the chip accent are one token, got \(accent.rawValue)")
    }

    // THE TWO DELIBERATE DIVERGENCES, pinned as facts (the same treatment
    // StatusChip.swift gives `idle`'s teal pill vs its neutral accent):
    //
    //  * `configuring` is violet as a chip and folds into `.working` here, so the
    //    inbox paints it blue. A sixth state is what this ticket forbids.
    expect(StatusChipPresenter.display(for: .configuring).accent == AccentToken.accentInput.color,
           "configuring's chip accent is still the violet accentInput")
    expect(AgentInboxRow.state(for: .configuring).accent == .accentWorking,
           "configuring folds into the in-motion accent in the inbox, got \(AgentInboxRow.state(for: .configuring).accent?.rawValue ?? "none")")
    //  * `idle`/`stale`/`done` are painted by the chip (muted, or green for done)
    //    but resolve to the uncoloured resting state here. A chip always paints
    //    something; a row does not have to, and this is where colour is saved.
    for status in [AgentStatus.idle, .stale, .done] {
        expect(AgentInboxRow.state(for: status) == .ready,
               "\(status.rawValue) is the resting state, got \(AgentInboxRow.state(for: status).rawValue)")
        expect(AgentInboxRow.state(for: status).accent == nil,
               "\(status.rawValue) renders with no accent even though its chip has one")
    }
    expect(StatusChipPresenter.display(for: .done).accent == AccentToken.accentDone.color,
           "the chip keeps its green done accent — only the inbox drops it")
}

// MARK: - 8 · attention is a separate axis (P3.3)

/// Two negative tests observed red at exit 1 with the final code, both production
/// edits:
/// · `InboxAttention.resolve` answering `unread` first →
///   `FAIL: woke outranks unread when both hold, got unread`
/// · `AgentInboxRow.label` reading `attention.label ?? state.label` →
///   `FAIL: working/woke labels Working, got Woke`
private func runInboxAttentionAxisCheck() {
    // A table again, for the same reason the totality check uses one: a switch
    // here would be the code under test agreeing with itself.
    let expected: [String: InboxAttention] = [
        "unseen turn, no hand": .unread,
        "hand up, seen": .woke,
        "hand up AND unseen": .woke,
        "nothing": .none,
    ]
    expect(InboxAttention.resolve(unread: true, raisedHand: false) == expected["unseen turn, no hand"],
           "a completed-and-unviewed agent is unread, got \(InboxAttention.resolve(unread: true, raisedHand: false).rawValue)")
    expect(InboxAttention.resolve(unread: false, raisedHand: true) == expected["hand up, seen"],
           "a raised hand is woke, got \(InboxAttention.resolve(unread: false, raisedHand: true).rawValue)")
    // THE PRECEDENCE the packet pins: both facts hold at once — a snoozed agent
    // raised its hand while you were elsewhere — and the row has one slot.
    expect(InboxAttention.resolve(unread: true, raisedHand: true) == expected["hand up AND unseen"],
           "woke outranks unread when both hold, got \(InboxAttention.resolve(unread: true, raisedHand: true).rawValue)")
    expect(InboxAttention.resolve(unread: false, raisedHand: false) == expected["nothing"],
           "an agent you have seen with no hand up is none, got \(InboxAttention.resolve(unread: false, raisedHand: false).rawValue)")
    // Every case is reachable from the two facts: an unreachable case is a
    // vocabulary that lies about what the inbox can show.
    var reachable: Set<InboxAttention> = []
    for unread in [true, false] {
        for hand in [true, false] { reachable.insert(InboxAttention.resolve(unread: unread, raisedHand: hand)) }
    }
    expect(reachable == Set(InboxAttention.allCases),
           "resolve reaches every attention case, got \(reachable.map(\.rawValue).sorted())")

    // UNREAD IS A MARK, NOT A WORD. `woke` is the only rung this axis contributes
    // to the label.
    expect(InboxAttention.unread.label == nil,
           "unread contributes no label, got \(InboxAttention.unread.label ?? "nil")")
    expect(InboxAttention.none.label == nil,
           "none contributes no label, got \(InboxAttention.none.label ?? "nil")")
    expect(InboxAttention.woke.label == "Woke",
           "woke is labelled, got \(InboxAttention.woke.label ?? "nil")")
    expect(InboxAttention.unread.isYours && InboxAttention.woke.isYours && !InboxAttention.none.isYours,
           "isYours is exactly the not-none cases")

    // THE AXES ARE INDEPENDENT: every (state, attention) pair is constructible and
    // neither field moves the other. This is the ticket's whole premise — a
    // finished-but-unseen agent and one you already reviewed are both `ready`.
    var pairs = 0
    for state in InboxState.allCases {
        for attention in InboxAttention.allCases {
            let row = AgentInboxRow(id: UUID(), title: "Reviewer", state: state, attention: attention, createdAt: inboxRowSpawnedAt)
            expect(row.state == state && row.attention == attention,
                   "a row carries \(state.rawValue)/\(attention.rawValue) unchanged, got \(row.state.rawValue)/\(row.attention.rawValue)")
            // The label priority from P3.2, with `(woke)` under it.
            let want = state.label ?? attention.label
            expect(row.label == want,
                   "\(state.rawValue)/\(attention.rawValue) labels \(want ?? "nothing"), got \(row.label ?? "nothing")")
            pairs += 1
        }
    }
    expect(pairs == InboxState.allCases.count * InboxAttention.allCases.count,
           "every state/attention pair was measured — \(pairs) of \(InboxState.allCases.count * InboxAttention.allCases.count)")
    // Named cases, so the priority is pinned and not only derived from itself:
    // a working agent whose hand is up still reads "Working" (what it is doing
    // outranks how it got back to you), and only a RESTING woke row reads "Woke".
    expect(AgentInboxRow(id: UUID(), title: "a", state: .working, attention: .woke, createdAt: inboxRowSpawnedAt).label == "Working",
           "state outranks woke in the label priority")
    expect(AgentInboxRow(id: UUID(), title: "a", state: .ready, attention: .woke, createdAt: inboxRowSpawnedAt).label == "Woke",
           "a resting woke row says so")
    expect(AgentInboxRow(id: UUID(), title: "a", state: .ready, attention: .unread, createdAt: inboxRowSpawnedAt).label == nil,
           "a resting unread row carries a mark, not a word")
    print("InboxAttention axis measured \(pairs) state/attention pairs, resolve(unread+hand)=\(InboxAttention.resolve(unread: true, raisedHand: true).rawValue)")
}

// MARK: - 9 · in-flight fade (P3.5)

/// Negative tests observed red at exit 1 with the final code — all four are
/// production edits, quoted verbatim:
/// · `emphasis` receding an approval (`case .approval, .input, .failed` →
///   `case .approval: return .receded`) →
///   `FAIL: approval/none is full, got receded`
/// · `emphasis` receding a finished-unread row (`ready` returning `.receded`
///   unconditionally) → `FAIL: ready/unread is full, got receded`
/// · `emphasis` ignoring `isInteracting` (the early return deleted) →
///   `FAIL: working/none is full while hovered/selected, got receded`
/// · `Opacity.receded` = 0.87, one hundredth below the measured break-even →
///   `FAIL: receded textSecondary@0.87 on canvas clears 4.5 in light — 4.48:1`
private func runRowEmphasisChecks() {
    runRowEmphasisMatrixCheck()
    runRecededContrastCheck()
}

/// THE MATRIX, against a table rather than a switch: a switch here would be the
/// code under test agreeing with itself.
private func runRowEmphasisMatrixCheck() {
    let expected: [String: RowEmphasis] = [
        // In motion: the agent has the next move, so it steps back.
        "working/none": .receded,
        "working/unread": .receded,
        // …unless it raised its hand, which is what put it back in front of you.
        "working/woke": .full,
        // Act-now, whatever the attention axis says. Dimming one of these is the
        // exact inversion of the goal.
        "approval/none": .full, "approval/unread": .full, "approval/woke": .full,
        "input/none": .full, "input/unread": .full, "input/woke": .full,
        // Broken is not background.
        "failed/none": .full, "failed/unread": .full, "failed/woke": .full,
        // The one state the attention axis actually moves: a finished turn you
        // have not read is the loudest row in the list; the same row once read
        // is history that has not been settled yet.
        "ready/none": .receded,
        "ready/unread": .full,
        "ready/woke": .full,
    ]
    expect(expected.count == InboxState.allCases.count * InboxAttention.allCases.count,
           "the emphasis table covers every state/attention pair — \(expected.count) of "
            + "\(InboxState.allCases.count * InboxAttention.allCases.count)")

    var measured = 0
    var receded = 0
    for state in InboxState.allCases {
        for attention in InboxAttention.allCases {
            let key = "\(state.rawValue)/\(attention.rawValue)"
            guard let want = expected[key] else {
                fputs("FAIL: RowEmphasis — no expectation for \(key)\n", stderr)
                Foundation.exit(1)
            }
            let got = AgentInboxRow.emphasis(for: state, attention: attention)
            expect(got == want, "\(key) is \(want.rawValue), got \(got.rawValue)")
            // The row's own property is the same derivation, so a list view
            // reading `row.emphasis` cannot see a different answer.
            let row = AgentInboxRow(id: UUID(), title: "Reviewer", state: state, attention: attention,
                                    createdAt: inboxRowSpawnedAt)
            expect(row.emphasis == want, "a row carrying \(key) reports \(want.rawValue), got \(row.emphasis.rawValue)")
            // HOVER / SELECTION / ACTIVE CLEARS RECESSION, for every pair — the
            // row you are pointing at is yours while you point at it.
            let interacting = AgentInboxRow.emphasis(for: state, attention: attention, isInteracting: true)
            expect(interacting == .full, "\(key) is full while hovered/selected, got \(interacting.rawValue)")
            measured += 1
            if got == .receded { receded += 1 }
        }
    }
    expect(measured == expected.count, "every state/attention pair was measured — \(measured) of \(expected.count)")

    // THE PACKET'S NAMED REGRESSION, pinned by name and not only by the table:
    // an approval needs you, so it is never dimmed, and neither is a failure.
    for attention in InboxAttention.allCases {
        for state in [InboxState.approval, .input, .failed] {
            expect(AgentInboxRow.emphasis(for: state, attention: attention) == .full,
                   "\(state.rawValue) never recedes (attention \(attention.rawValue))")
        }
    }
    // …and recession is not vacuous: exactly the three in-motion/already-read
    // pairs recede. A rule that dims nothing would satisfy every assertion above.
    expect(receded == 3, "exactly the three receding pairs recede, got \(receded)")

    // THE FADE IS A TOKEN, and the accent is exempt from it by construction.
    expect(RowEmphasis.full.textOpacity == Opacity.full,
           "a full row paints text at Opacity.full, got \(RowEmphasis.full.textOpacity)")
    expect(RowEmphasis.receded.textOpacity == Opacity.receded,
           "a receded row paints text at Opacity.receded, got \(RowEmphasis.receded.textOpacity)")
    expect(RowEmphasis.receded.textOpacity < RowEmphasis.full.textOpacity,
           "receded is actually dimmer than full")
    for emphasis in RowEmphasis.allCases {
        expect(emphasis.accentOpacity == Opacity.full,
               "the status accent stays full strength when the row is \(emphasis.rawValue), "
                + "got \(emphasis.accentOpacity)")
    }
    print("RowEmphasis measured \(measured) state/attention pairs, \(receded) receded, "
        + "text alpha \(Opacity.receded) with the accent held at \(Opacity.full)")
}

/// FADING IS NOT A LICENCE TO FAIL CONTRAST. Every documented text pair is
/// measured AS PAINTED on a receded row — the foreground composited over its own
/// background at `Opacity.receded` — in both themes.
private func runRecededContrastCheck() {
    let pairs = DesignTokens.recededTextPairs
    let textNames = Set(TextToken.allCases.map(\.rawValue))
    let expectedCount = DesignTokens.documentedPairs.filter { textNames.contains($0.foreground) }.count
    expect(expectedCount > 0, "there are documented text pairs to fade")
    expect(pairs.count == expectedCount,
           "every documented text pair has a faded counterpart — \(pairs.count) of \(expectedCount)")
    // …and the count is pinned to a LITERAL as well, because the line above
    // derives both sides from `documentedPairs` and would stay green if a pair
    // vanished from the palette entirely. 27 = textPrimary and textSecondary on
    // the eleven surfaces (22) + textOnAccent on the five accent fills (5).
    expect(pairs.count == 27,
           "the faded set is the whole documented text palette — 22 surface pairs + 5 accent-fill pairs, got \(pairs.count)")

    var worst = (ratio: Double.greatestFiniteMagnitude, label: "")
    var measured = 0
    for pair in pairs {
        for theme in TokenTheme.allCases {
            let ratio = pair.ratio(for: theme)
            expect(ratio >= pair.floor,
                   "receded \(pair.foreground) on \(pair.background) clears \(pair.floor) in "
                    + "\(theme.rawValue) — \(String(format: "%.2f", ratio)):1")
            if ratio < worst.ratio {
                worst = (ratio, "\(pair.foreground) on \(pair.background) (\(theme.rawValue))")
            }
            measured += 1
        }
    }
    expect(measured == pairs.count * TokenTheme.allCases.count,
           "both themes were measured for every faded pair — \(measured)")
    // PINNED, like P1.3's own worst-case table: the fade's headroom is 0.08 over
    // the floor, so a palette tweak that still clears AA at full strength but
    // eats that headroom goes red here rather than shipping unreadable.
    expect(abs(worst.ratio - 4.58) < 0.01,
           "the worst faded pair is 4.58:1 (textSecondary on canvas, light), got "
            + "\(String(format: "%.2f", worst.ratio)):1 at \(worst.label)")

    // THE TOKEN IS THE MEASURED MAXIMUM, not a number someone liked: one
    // hundredth deeper and the same pair fails. This is what makes `Opacity`'s
    // provenance note an assertion instead of a claim.
    var deeperFails = 0
    for pair in DesignTokens.documentedPairs where textNames.contains(pair.foreground) {
        for theme in TokenTheme.allCases where pair.faded(Opacity.receded - 0.01).ratio(for: theme) < pair.floor {
            deeperFails += 1
        }
    }
    expect(deeperFails > 0,
           "0.87 would fail at least one documented text pair — the 0.88 token is the break-even, "
            + "got \(deeperFails) failures")

    // The compositing itself, at both ends: full alpha is the pair's own colour
    // (so `full` rows are unchanged by this machinery) and zero alpha is the
    // background (ratio 1.0, invisible), which is the property that makes every
    // measurement above meaningful.
    guard let sample = DesignTokens.documentedPairs.first(where: { $0.foreground == TextToken.textSecondary.rawValue }) else {
        fputs("FAIL: no textSecondary pair to check compositing with\n", stderr)
        Foundation.exit(1)
    }
    expect(sample.faded(1.0).color == sample.color, "alpha 1 composites to the pair's own colour")
    expect(sample.faded(0.0).color == sample.backgroundColor, "alpha 0 composites to the background")
    for theme in TokenTheme.allCases {
        expect(abs(sample.faded(0.0).ratio(for: theme) - 1.0) < 0.0001,
               "a fully transparent foreground measures 1.0:1 in \(theme.rawValue)")
    }
    print("Receded contrast measured \(measured) faded text pair/theme combinations at alpha "
        + "\(Opacity.receded), worst \(String(format: "%.2f", worst.ratio)):1 at \(worst.label)")
}
