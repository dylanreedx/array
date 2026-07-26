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

func runAgentInboxRowChecks() {
    runInboxStateTotalityCheck()
    runInboxRowIdentityCheck()
    runRowVariantCheck()
    print("AgentInboxRow checks: status totality, unreachable states, stable identity and lifecycle-driven variant passed")
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
    expect(AgentStatus.allCases.map(AgentInboxRow.state(for:)) == AgentStatus.allCases.map(AgentInboxRow.state(for:)),
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
