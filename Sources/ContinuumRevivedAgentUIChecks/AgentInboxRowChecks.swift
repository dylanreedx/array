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
    print("AgentInboxRow checks: status totality, unreachable states, stable identity, lifecycle-driven variant, "
        + "uncoloured resting state, pending-over-status precedence, status-presenter agreement "
        + "and the attention axis passed")
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

private func runInboxRowIdentityCheck() {
    let agentId = UUID(uuidString: "3B100000-0000-4000-8000-000000000001")!
    let other = UUID(uuidString: "3B100000-0000-4000-8000-000000000002")!

    let row = AgentInboxRow(id: agentId, title: "Reviewer", state: .ready)
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
        lifecycle: .settled,
        model: "anthropic/claude-opus-5",
        role: "reviewer",
        branch: "agent/reviewer-1a2b3c4d",
        isIsolated: true,
        elapsed: 42,
        depth: 1,
        variant: .slim
    )
    expect(moved.id == row.id, "no field but the id changes the id, got \(moved.id) vs \(row.id)")
    expect(moved != row, "two rows that differ in every other field are not equal")
    expect(AgentInboxRow(id: other, title: "Reviewer", state: .ready) != row,
           "two rows with different ids are not equal")

    // Defaults are the "nothing is known yet" row Phase 3/4 fills in.
    expect(row.attention == .none && row.lifecycle == .active && row.depth == 0 && row.variant == .card,
           "a row defaults to active/unattended/top-level/card, got \(row)")
    expect(row.elapsed == nil && row.branch == nil && !row.isIsolated,
           "a row defaults to no duration and no branch, got \(row)")
}

// MARK: - 4 · variant

private func runRowVariantCheck() {
    let until = Date(timeIntervalSinceReferenceDate: 806_600_000)
    let expected: [(InboxLifecycle, RowVariant)] = [
        (.active, .card),
        (.snoozed(until: until), .slim),
        (.settled, .slim),
        // Archived leaves the list entirely (P4.1: archived != settled), so it has
        // no density of its own to argue about; a card is the honest default for
        // anything that is still being drawn.
        (.archived, .card),
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
            variant: RowVariant.forLifecycle(.active)
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
            let row = AgentInboxRow(id: UUID(), title: "Reviewer", state: state, attention: attention)
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
    expect(AgentInboxRow(id: UUID(), title: "a", state: .working, attention: .woke).label == "Working",
           "state outranks woke in the label priority")
    expect(AgentInboxRow(id: UUID(), title: "a", state: .ready, attention: .woke).label == "Woke",
           "a resting woke row says so")
    expect(AgentInboxRow(id: UUID(), title: "a", state: .ready, attention: .unread).label == nil,
           "a resting unread row carries a mark, not a word")
    print("InboxAttention axis measured \(pairs) state/attention pairs, resolve(unread+hand)=\(InboxAttention.resolve(unread: true, raisedHand: true).rawValue)")
}
