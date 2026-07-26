import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.4-frozen-sort.md
//
// THE LOAD-BEARING PROPERTY: take a row list, push a stream of status changes
// through it in random orders, and the sequence of ids must be identical every
// time and equal to creation order (newest first). Activity does not reorder the
// desktop inbox — the screen only moves when you act.
//
// The property is written as a FUNCTION over a sort, not as a straight-line
// assertion, so the regression witness the packet asks for is executable rather
// than argued: `frozenSequenceHolds` is asserted TRUE for `InboxSort.sortForInbox`
// and FALSE for a sort keyed on status, in the same run. A comparator that reads
// activity cannot pass this file.
//
// Six properties:
//   1. FROZEN UNDER ACTIVITY — the above, over 200 seeded trials, plus the
//      status-sorted witness that fails it.
//   2. NESTING — a child sits immediately after its parent, depth-first, and a
//      child whose parent is not in the list is a root rather than a lost row.
//   3. LIFECYCLE MOVES A ROW — settle and snooze both relocate one, and neither
//      disturbs the relative order of everything else. This is the deliberate
//      exception to "frozen": frozen is about ACTIVITY.
//   4. HISTORY IS ORDERED BY WHEN WORK ENDED — not by spawn time, pinned with a
//      fixture whose two orders are opposites.
//   5. TIES AND PERMUTATION — equal spawn times resolve by id, and the output is
//      always a permutation of the input whatever order it arrived in.
//   6. A PARENT CYCLE TERMINATES — corrupted `parentId` pairs do not hang or drop
//      rows.
//
// Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
//   7. DEPTH IS ASSIGNED BY THE SORT — a root is 0, a child is one deeper than its
//      parent, an ORPHAN is promoted back to 0 whatever depth it arrived carrying,
//      and the chain stops indenting at `AgentInboxRow.maxDepth`. Nesting and the
//      frozen order are checked TOGETHER (the packet's watch-out): a child's
//      activity moves neither its parent nor itself.
//   8. A FOLDED GROUP HIDES ITS WHOLE SUBTREE — `visibleRows` drops descendants at
//      any depth, leaves the other groups alone, and is a no-op for an id that is
//      nobody's parent here.
//
// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
//   9. A PARENT'S ROLLUP COUNTS ITS WHOLE SUBTREE, ONCE — `rollups(in:)` agrees
//      with `parentIds(in:)` about which rows have a group at all, counts a
//      grandchild in its grandparent's tally, counts nobody twice, and is derived
//      fresh from the list rather than stored on a row.

func runInboxSortChecks() {
    runInboxFrozenUnderActivityCheck()
    runInboxNestingCheck()
    runInboxLifecycleMovesRowCheck()
    runInboxHistoryOrderCheck()
    runInboxTiebreakAndPermutationCheck()
    runInboxCycleCheck()
    runInboxDepthCheck()
    runInboxCollapseCheck()
    runInboxRollupCheck()
    print("InboxSort checks: frozen under activity (200 trials, status-sorted witness fails), parent/child nesting, lifecycle relocation, history by end time, tie determinism, cycle termination, depth assignment (orphan promoted, chain capped at \(AgentInboxRow.maxDepth)), subtree collapse and transitive child rollup passed")
}

// MARK: - Fixture

private let sortEpoch = Date(timeIntervalSinceReferenceDate: 806_800_000)

/// Ids deliberately NOT in creation order, and not in the order the rows are
/// listed: if the expected sequence coincided with either, a sort that reads only
/// the tiebreak — or one that returns its input untouched — would pass.
private func sortId(_ suffix: String) -> UUID {
    UUID(uuidString: "3B400000-0000-4000-8000-0000000000\(suffix)")!
}

private let rowOne = sortId("E5")   // newest
private let rowTwo = sortId("A1")
private let rowThree = sortId("D4")
private let rowFour = sortId("B2")
private let rowFive = sortId("C3")  // oldest

/// Newest first — what `sortForInbox` must return for the fixture, forever,
/// whatever any of these agents is doing.
private let creationOrder = [rowOne, rowTwo, rowThree, rowFour, rowFive]

private func sortRow(
    _ id: UUID,
    spawnedAfter: TimeInterval,
    state: InboxState = .ready,
    attention: InboxAttention = .none,
    lifecycle: InboxLifecycle = .active,
    elapsed: TimeInterval? = nil,
    depth: Int = 0,
    parentId: UUID? = nil
) -> AgentInboxRow {
    AgentInboxRow(
        id: id,
        title: id.uuidString,
        state: state,
        attention: attention,
        lifecycle: lifecycle,
        elapsed: elapsed,
        depth: depth,
        variant: RowVariant.forLifecycle(lifecycle),
        createdAt: sortEpoch.addingTimeInterval(spawnedAfter),
        parentId: parentId
    )
}

/// The fixture in ID order, which is neither creation order nor the expected
/// output.
private func sortFixture() -> [AgentInboxRow] {
    [
        sortRow(rowTwo, spawnedAfter: 300),
        sortRow(rowFour, spawnedAfter: 100),
        sortRow(rowFive, spawnedAfter: 0),
        sortRow(rowThree, spawnedAfter: 200),
        sortRow(rowOne, spawnedAfter: 400),
    ]
}

/// The same row with new ACTIVITY. Everything this touches is a thing the
/// comparator must ignore.
private func withActivity(
    _ row: AgentInboxRow,
    state: InboxState,
    attention: InboxAttention,
    elapsed: TimeInterval?
) -> AgentInboxRow {
    AgentInboxRow(
        id: row.id,
        title: row.title,
        projectName: row.projectName,
        state: state,
        attention: attention,
        lifecycle: row.lifecycle,
        model: row.model,
        role: row.role,
        branch: row.branch,
        isIsolated: row.isIsolated,
        elapsed: elapsed,
        depth: row.depth,
        variant: row.variant,
        createdAt: row.createdAt,
        parentId: row.parentId
    )
}

private func withLifecycle(_ row: AgentInboxRow, _ lifecycle: InboxLifecycle) -> AgentInboxRow {
    AgentInboxRow(
        id: row.id,
        title: row.title,
        projectName: row.projectName,
        state: row.state,
        attention: row.attention,
        lifecycle: lifecycle,
        model: row.model,
        role: row.role,
        branch: row.branch,
        isIsolated: row.isIsolated,
        elapsed: row.elapsed,
        depth: row.depth,
        variant: RowVariant.forLifecycle(lifecycle),
        createdAt: row.createdAt,
        parentId: row.parentId
    )
}

/// SplitMix64 — seeded, so "random orders" is reproducible. A flaky ordering check
/// is worse than none: it would be blessed away the first time it flapped.
private struct SortPRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func index(below count: Int) -> Int { Int(next() % UInt64(count)) }
}

// MARK: - 1 · frozen under activity

/// Does `sort` hold the id sequence still while activity churns underneath it?
///
/// Each trial pushes a stream of status/attention/elapsed changes through the rows
/// in a different order AND hands them to the sort in a different input order,
/// then compares the ids to `expected`. Returns false on the first trial that
/// moves anything — which is what makes it usable as the regression witness.
private func frozenSequenceHolds(
    _ sort: ([AgentInboxRow]) -> [AgentInboxRow],
    expected: [UUID],
    trials: Int
) -> Bool {
    let churn: [InboxState] = [.working, .approval, .input, .failed, .ready]
    let marks: [InboxAttention] = [.none, .unread, .woke]
    for trial in 0..<trials {
        var prng = SortPRNG(seed: UInt64(trial) &+ 1)
        var rows = sortFixture()
        for _ in 0..<20 {
            let target = prng.index(below: rows.count)
            rows[target] = withActivity(
                rows[target],
                state: churn[prng.index(below: churn.count)],
                attention: marks[prng.index(below: marks.count)],
                elapsed: TimeInterval(prng.index(below: 3_600))
            )
        }
        // The input order must not matter either: a real refresh hands rows over
        // in whatever order the projection produced them, which is
        // attention-first.
        for position in stride(from: rows.count - 1, to: 0, by: -1) {
            rows.swapAt(position, prng.index(below: position + 1))
        }
        if sort(rows).map(\.id) != expected { return false }
    }
    return true
}

/// The witness: rank by status, spawn time only as a tiebreak. This is the sort
/// the locked decision forbids — the one that makes the list jump while you read
/// it — and it must FAIL the property above.
private func sortByStatus(_ rows: [AgentInboxRow]) -> [AgentInboxRow] {
    func rank(_ state: InboxState) -> Int {
        switch state {
        case .approval: return 0
        case .input: return 1
        case .failed: return 2
        case .working: return 3
        case .ready: return 4
        }
    }
    return rows.sorted {
        rank($0.state) != rank($1.state)
            ? rank($0.state) < rank($1.state)
            : InboxSort.newestSpawnedFirst($0, $1)
    }
}

private func runInboxFrozenUnderActivityCheck() {
    let sorted = InboxSort.sortForInbox(rows: sortFixture())
    expect(sorted.map(\.id) == creationOrder,
           "the resting fixture sorts newest-spawned first, got \(sorted.map(\.title))")
    // Guard against a vacuous fixture: if the input already arrived in the
    // expected order, a sort that did nothing at all would pass every trial.
    expect(sortFixture().map(\.id) != creationOrder,
           "the fixture must arrive in a DIFFERENT order than it leaves, or this file proves nothing")
    expect(sortFixture().map(\.id).sorted { $0.uuidString < $1.uuidString } != creationOrder,
           "the expected order must not coincide with id order, or the tiebreak alone would pass")

    expect(frozenSequenceHolds(InboxSort.sortForInbox(rows:), expected: creationOrder, trials: 200),
           "200 trials of status/attention/elapsed churn in random orders must not move a single row")

    // THE REGRESSION WITNESS, executed rather than described.
    expect(!frozenSequenceHolds(sortByStatus, expected: creationOrder, trials: 200),
           "a status-keyed sort must FAIL the frozen-order property — if it passes, the property is not testing anything")

    // And concretely, on one row, so the witness is legible: raising a hand moves
    // it to the top of the status sort and nowhere at all in the frozen one.
    var raised = sortFixture()
    let last = raised.firstIndex { $0.id == rowFive }!
    raised[last] = withActivity(raised[last], state: .approval, attention: .unread, elapsed: nil)
    expect(sortByStatus(raised).map(\.id).first == rowFive,
           "the witness sort really does promote a pending approval, got \(String(describing: sortByStatus(raised).map(\.id).first))")
    expect(InboxSort.sortForInbox(rows: raised).map(\.id) == creationOrder,
           "the oldest agent asking for approval stays exactly where it was, got \(InboxSort.sortForInbox(rows: raised).map(\.title))")
}

// MARK: - 2 · nesting

private func runInboxNestingCheck() {
    // rowTwo is rowOne's child, rowFour is rowTwo's child (a grandchild), and
    // rowFive is a child of rowThree. Spawn times are deliberately hostile: the
    // grandchild is the OLDEST row in the list, so a flat creation sort would put
    // it last.
    let rows = [
        sortRow(rowOne, spawnedAfter: 400),
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200),
        sortRow(rowFour, spawnedAfter: 0, parentId: rowTwo),
        sortRow(rowFive, spawnedAfter: 100, parentId: rowThree),
    ]
    let sorted = InboxSort.sortForInbox(rows: rows).map(\.id)
    expect(sorted == [rowOne, rowTwo, rowFour, rowThree, rowFive],
           "a child follows its parent immediately, depth-first, got \(sorted)")

    // Two children of one parent are ordered against each OTHER by the same rule.
    let siblings = [
        sortRow(rowOne, spawnedAfter: 400),
        sortRow(rowTwo, spawnedAfter: 100, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 300, parentId: rowOne),
    ]
    expect(InboxSort.sortForInbox(rows: siblings).map(\.id) == [rowOne, rowThree, rowTwo],
           "siblings are newest-spawned first among themselves, got \(InboxSort.sortForInbox(rows: siblings).map(\.id))")

    // An orphan — the parent was archived, or settled into the other block. It is
    // a root here, not a dropped row.
    let orphan = [
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200),
    ]
    expect(InboxSort.sortForInbox(rows: orphan).map(\.id) == [rowTwo, rowThree],
           "a child whose parent is absent sorts as a root, got \(InboxSort.sortForInbox(rows: orphan).map(\.id))")

    // Nesting does not survive a block boundary: a settled parent is history and
    // its live child stays in the live block, where it is a root.
    let split = [
        sortRow(rowOne, spawnedAfter: 400, lifecycle: .settled(at: sortEpoch)),
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200),
    ]
    expect(InboxSort.sortForInbox(rows: split).map(\.id) == [rowTwo, rowThree, rowOne],
           "a live child of a settled parent stays live, got \(InboxSort.sortForInbox(rows: split).map(\.id))")
}

// MARK: - 3 · a lifecycle transition DOES move a row

private func runInboxLifecycleMovesRowCheck() {
    let base = sortFixture()
    let baseline = InboxSort.sortForInbox(rows: base).map(\.id)
    expect(baseline == creationOrder, "baseline is creation order, got \(baseline)")

    // Settle the NEWEST row — the one at the very top — so "it moved" cannot be
    // confused with "it was already near the bottom".
    var settledList = base
    let newest = settledList.firstIndex { $0.id == rowOne }!
    settledList[newest] = withLifecycle(settledList[newest], .settled(at: sortEpoch.addingTimeInterval(900)))
    let afterSettle = InboxSort.sortForInbox(rows: settledList).map(\.id)
    expect(afterSettle == [rowTwo, rowThree, rowFour, rowFive, rowOne],
           "settling moves the row into history at the end of the list, got \(afterSettle)")
    expect(afterSettle != baseline, "a lifecycle transition MUST move a row — that is the exception to frozen")
    expect(afterSettle.filter { $0 != rowOne } == baseline.filter { $0 != rowOne },
           "settling one row leaves every other row's relative order untouched, got \(afterSettle)")

    // Snoozing moves it to the shelf — below the live rows, above history.
    var snoozedList = settledList
    let second = snoozedList.firstIndex { $0.id == rowTwo }!
    snoozedList[second] = withLifecycle(snoozedList[second], .snoozed(until: sortEpoch.addingTimeInterval(3_600)))
    let afterSnooze = InboxSort.sortForInbox(rows: snoozedList).map(\.id)
    expect(afterSnooze == [rowThree, rowFour, rowFive, rowTwo, rowOne],
           "snoozing shelves the row between the live rows and history, got \(afterSnooze)")

    // Archived is NOT parked: it has left the list by the time anything draws it,
    // so it keeps its place rather than being demoted to a block of its own.
    var archivedList = base
    let middle = archivedList.firstIndex { $0.id == rowThree }!
    archivedList[middle] = withLifecycle(archivedList[middle], .archived)
    expect(InboxSort.sortForInbox(rows: archivedList).map(\.id) == baseline,
           "archiving does not reorder, got \(InboxSort.sortForInbox(rows: archivedList).map(\.id))")
}

// MARK: - 4 · history is ordered by when work ENDED

private func runInboxHistoryOrderCheck() {
    // End times are the exact OPPOSITE of spawn times, so a history block that
    // fell back to creation order would come out reversed and be caught.
    let rows = [
        sortRow(rowOne, spawnedAfter: 400, lifecycle: .settled(at: sortEpoch.addingTimeInterval(1_000))),
        sortRow(rowTwo, spawnedAfter: 300, lifecycle: .settled(at: sortEpoch.addingTimeInterval(2_000))),
        sortRow(rowThree, spawnedAfter: 200, lifecycle: .settled(at: sortEpoch.addingTimeInterval(3_000))),
    ]
    let sorted = InboxSort.sortForInbox(rows: rows).map(\.id)
    expect(sorted == [rowThree, rowTwo, rowOne],
           "history is most-recently-ended first, not newest-spawned first, got \(sorted)")
    expect(sorted != [rowOne, rowTwo, rowThree],
           "if history came out in spawn order the end time is being ignored")

    // A snoozed row's date is in the FUTURE and must not read as an end time.
    expect(InboxLifecycle.snoozed(until: sortEpoch.addingTimeInterval(9_000)).endedAt == nil,
           "a wake-up time is not an end time")
    expect(InboxLifecycle.settled(at: sortEpoch).endedAt == sortEpoch,
           "a settled row's end time is the one it was settled with")
    expect(InboxLifecycle.active.endedAt == nil && InboxLifecycle.archived.endedAt == nil,
           "only a settled row has ended")
}

// MARK: - 5 · ties and permutation

private func runInboxTiebreakAndPermutationCheck() {
    // Three rows spawned in the same instant — a restore from disk, where several
    // records carry the same timestamp.
    let tied = [
        sortRow(rowThree, spawnedAfter: 100),
        sortRow(rowOne, spawnedAfter: 100),
        sortRow(rowTwo, spawnedAfter: 100),
    ]
    let expectedTie = [rowOne, rowTwo, rowThree].sorted { $0.uuidString < $1.uuidString }
    let sortedTie = InboxSort.sortForInbox(rows: tied).map(\.id)
    expect(sortedTie == expectedTie,
           "equal spawn times resolve by id, the same tiebreak AgentStore.isOrderedBefore uses — got \(sortedTie)")
    // Determinism under a different arrival order is the whole point of having a
    // tiebreak at all.
    expect(InboxSort.sortForInbox(rows: tied.reversed()).map(\.id) == sortedTie,
           "a tie must resolve the same way whatever order the rows arrived in")

    // Permutation: nothing is dropped and nothing is duplicated, for every
    // arrangement of the fixture and for the empty and single-row lists.
    expect(InboxSort.sortForInbox(rows: []).isEmpty, "an empty inbox sorts to an empty inbox")
    let single = [sortRow(rowOne, spawnedAfter: 0, parentId: rowTwo)]
    expect(InboxSort.sortForInbox(rows: single).map(\.id) == [rowOne],
           "a single orphaned row survives its own sort")

    var prng = SortPRNG(seed: 99)
    let input = sortFixture()
    for _ in 0..<50 {
        var shuffled = input
        for position in stride(from: shuffled.count - 1, to: 0, by: -1) {
            shuffled.swapAt(position, prng.index(below: position + 1))
        }
        let out = InboxSort.sortForInbox(rows: shuffled)
        expect(out.count == shuffled.count && Set(out.map(\.id)) == Set(shuffled.map(\.id)),
               "the sort is a permutation of its input, got \(out.count) of \(shuffled.count)")
    }
}

// MARK: - 6 · a parent cycle terminates

private func runInboxCycleCheck() {
    // `parentId` comes off disk. Two records pointing at each other must not hang
    // the sidebar or lose their rows.
    let cycle = [
        sortRow(rowOne, spawnedAfter: 400, parentId: rowTwo),
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200),
    ]
    let sorted = InboxSort.sortForInbox(rows: cycle)
    expect(sorted.count == 3 && Set(sorted.map(\.id)) == Set(cycle.map(\.id)),
           "a parent cycle still yields every row exactly once, got \(sorted.map(\.id))")
    expect(sorted.map(\.id) == [rowThree, rowOne, rowTwo],
           "cycle survivors are appended after the well-formed rows, in comparator order, got \(sorted.map(\.id))")

    // A row that is its own parent is a root, not a one-element cycle.
    let selfParent = [sortRow(rowOne, spawnedAfter: 400, parentId: rowOne)]
    expect(InboxSort.sortForInbox(rows: selfParent).map(\.id) == [rowOne],
           "a self-parenting row is a root")
}

// MARK: - 7 · depth is assigned by the sort (P2D.4)

private func runInboxDepthCheck() {
    // THE PACKET'S FIRST CASE: an orchestrator and three workers are four rows, the
    // parent first and the children after it, and the children are the only indented
    // ones. Spawn times are hostile again — the children are all OLDER than the
    // parent, so a flat sort would put the parent last.
    let orchestrated = [
        sortRow(rowThree, spawnedAfter: 200, parentId: rowOne),
        sortRow(rowFive, spawnedAfter: 0),
        sortRow(rowOne, spawnedAfter: 400),
        sortRow(rowFour, spawnedAfter: 100, parentId: rowOne),
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
    ]
    let group = InboxSort.sortForInbox(rows: orchestrated)
    expect(group.map(\.id) == [rowOne, rowTwo, rowThree, rowFour, rowFive],
           "a parent and its three children are one group in creation order, got \(group.map(\.id))")
    expect(group.map(\.depth) == [0, 1, 1, 1, 0],
           "the three children are drawn one level in and nothing else is, got \(group.map(\.depth))")

    // FROZEN AND NESTED AT ONCE (the packet's watch-out): a child working, failing
    // and raising a hand moves neither itself nor its parent, and the depths hold.
    for state in InboxState.allCases {
        let churned = orchestrated.map { row -> AgentInboxRow in
            guard row.id == rowThree else { return row }
            return withActivity(row, state: state, attention: .unread, elapsed: 42)
        }
        let after = InboxSort.sortForInbox(rows: churned)
        expect(after.map(\.id) == group.map(\.id),
               "a child going \(state.rawValue) must not move a row, got \(after.map(\.id))")
        expect(after.map(\.depth) == group.map(\.depth),
               "…and must not change a depth, got \(after.map(\.depth))")
    }

    // AN ORPHAN PROMOTES. It arrives carrying depth 1 — which is what it was drawn
    // at while its parent was still in the list — and must come back flat rather
    // than indented under whatever now precedes it.
    let orphaned = [
        sortRow(rowThree, spawnedAfter: 200),
        sortRow(rowTwo, spawnedAfter: 300, depth: 1, parentId: rowOne),
    ]
    let promoted = InboxSort.sortForInbox(rows: orphaned)
    expect(promoted.map(\.id) == [rowTwo, rowThree] && promoted.map(\.depth) == [0, 0],
           "a child whose parent left the list is a root at depth 0, got \(promoted.map { ($0.id, $0.depth) })")
    // Including when it is the only row there is — the case a `count > 1` shortcut
    // would return untouched.
    expect(InboxSort.sortForInbox(rows: [orphaned[1]]).map(\.depth) == [0],
           "a lone orphan is flat too")
    // …and a settled parent is a different BLOCK, which orphans its live child by
    // the same rule. Section 2 pins the order; this pins the depth.
    let split = [
        sortRow(rowOne, spawnedAfter: 400, lifecycle: .settled(at: sortEpoch)),
        sortRow(rowTwo, spawnedAfter: 300, depth: 1, parentId: rowOne),
    ]
    expect(InboxSort.sortForInbox(rows: split).map(\.depth) == [0, 0],
           "a live child of a settled parent is not indented under history, got \(InboxSort.sortForInbox(rows: split).map(\.depth))")

    // THE CAP (P2D.2's `AgentSupervisor.maxSpawnDepth`, pinned to it in
    // `runAgentInboxChecks`): a grandchild indents, and a great-grandchild — which
    // the spawn cap refuses, so it can only come off disk — stops indenting instead
    // of marching off the edge of a 320pt sidebar.
    let chain = [
        sortRow(rowOne, spawnedAfter: 400),
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200, parentId: rowTwo),
        sortRow(rowFour, spawnedAfter: 100, parentId: rowThree),
    ]
    let nested = InboxSort.sortForInbox(rows: chain)
    expect(nested.map(\.id) == [rowOne, rowTwo, rowThree, rowFour],
           "a chain stays in chain order, got \(nested.map(\.id))")
    expect(nested.map(\.depth) == [0, 1, 2, AgentInboxRow.maxDepth],
           "depth counts to the cap and stops, got \(nested.map(\.depth))")
    expect(AgentInboxRow.maxDepth == 2,
           "the cap is a root, its worker and that worker's worker — got \(AgentInboxRow.maxDepth)")
}

// MARK: - 8 · a folded group hides its whole subtree (P2D.4)

private func runInboxCollapseCheck() {
    // Two groups: rowOne over rowTwo over rowThree (a chain), and rowFour over
    // rowFive. Folding one must not touch the other.
    let rows = InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 400),
        sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200, parentId: rowTwo),
        sortRow(rowFour, spawnedAfter: 100),
        sortRow(rowFive, spawnedAfter: 0, parentId: rowFour),
    ])
    expect(rows.map(\.id) == [rowOne, rowTwo, rowThree, rowFour, rowFive],
           "the collapse fixture must nest as expected first, got \(rows.map(\.id))")
    expect(InboxSort.parentIds(in: rows) == [rowOne, rowTwo, rowFour],
           "a disclosure belongs on exactly the rows with a child here, got \(InboxSort.parentIds(in: rows))")

    expect(InboxSort.visibleRows(rows, collapsed: []).map(\.id) == rows.map(\.id),
           "nothing folded shows everything")
    // A GRANDCHILD GOES WITH ITS GRANDPARENT: folding the top of a chain hides the
    // whole subtree, not just the row directly under it.
    expect(InboxSort.visibleRows(rows, collapsed: [rowOne]).map(\.id) == [rowOne, rowFour, rowFive],
           "folding a parent hides its children AND their children, got \(InboxSort.visibleRows(rows, collapsed: [rowOne]).map(\.id))")
    expect(InboxSort.visibleRows(rows, collapsed: [rowTwo]).map(\.id) == [rowOne, rowTwo, rowFour, rowFive],
           "folding the middle of a chain hides only below it, got \(InboxSort.visibleRows(rows, collapsed: [rowTwo]).map(\.id))")
    expect(InboxSort.visibleRows(rows, collapsed: [rowFour]).map(\.id) == [rowOne, rowTwo, rowThree, rowFour],
           "folding one group leaves the other alone, got \(InboxSort.visibleRows(rows, collapsed: [rowFour]).map(\.id))")
    expect(InboxSort.visibleRows(rows, collapsed: [rowOne, rowFour]).map(\.id) == [rowOne, rowFour],
           "folding both leaves the two roots, got \(InboxSort.visibleRows(rows, collapsed: [rowOne, rowFour]).map(\.id))")
    // A PARENT IS NEVER HIDDEN BY ITS OWN FOLD, and folding a leaf or an id that is
    // not here at all does nothing — the set is remembered, not pruned, so a scope
    // change and back restores the fold you left.
    expect(InboxSort.visibleRows(rows, collapsed: [rowThree]).map(\.id) == rows.map(\.id),
           "folding a childless row hides nothing, got \(InboxSort.visibleRows(rows, collapsed: [rowThree]).map(\.id))")
    expect(InboxSort.visibleRows(rows, collapsed: [sortId("FF")]).map(\.id) == rows.map(\.id),
           "an id no row here carries hides nothing")
    // An orphan is nobody's child on screen, so a stale fold on its absent parent
    // must not make it disappear.
    let orphan = InboxSort.sortForInbox(rows: [sortRow(rowTwo, spawnedAfter: 300, parentId: rowOne)])
    expect(InboxSort.visibleRows(orphan, collapsed: [rowOne]).map(\.id) == [rowTwo],
           "a fold on a parent that is not in the list must not hide the orphan")

    // THE PARENT IS HERE AND IS STILL NOT THIS ROW'S PARENT (from cross-review): a
    // settled parent sits in history, foldable, while its live child was promoted to
    // a root in the live block. Folding history must not delete an active agent.
    let crossBlock = InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 400, lifecycle: .settled(at: sortEpoch)),
        sortRow(rowTwo, spawnedAfter: 300, depth: 1, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 200),
    ])
    expect(crossBlock.map(\.id) == [rowTwo, rowThree, rowOne] && crossBlock.map(\.depth) == [0, 0, 0],
           "the cross-block fixture must promote the child first, got \(crossBlock.map { ($0.id, $0.depth) })")
    expect(InboxSort.parentIds(in: crossBlock).isEmpty,
           "a settled parent whose child was promoted has no children HERE, so it draws no triangle")
    expect(InboxSort.visibleRows(crossBlock, collapsed: [rowOne]).map(\.id) == crossBlock.map(\.id),
           "folding a settled parent must not hide the live child that was promoted out of its group, got \(InboxSort.visibleRows(crossBlock, collapsed: [rowOne]).map(\.id))")
}

// MARK: - 9 · The rollup on a collapsed parent
//
// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
//
// THE DECISION THE PACKET ASKS TO BE MADE AND ASSERTED: the rollup is TRANSITIVE
// (a grandchild counts in its grandparent's tally) and each descendant is counted
// EXACTLY ONCE. The fixture below is built so those are two different failures
// with two different numbers — a direct-children-only rollup reports 1 where this
// asserts 2, and a walk that re-visits or includes the parent itself reports 3.
private func runInboxRollupCheck() {
    // A three-deep chain (root → child → grandchild) beside a two-deep group, with
    // every counted state represented and one `ready` descendant that must land in
    // `children` and in none of the three tallies.
    let rows = InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 500),
        sortRow(rowTwo, spawnedAfter: 400, state: .working, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 300, state: .approval, parentId: rowTwo),
        sortRow(rowFour, spawnedAfter: 200),
        sortRow(rowFive, spawnedAfter: 100, state: .failed, parentId: rowFour),
    ])
    // Vacuity: the chain has to actually be three deep, or "transitive" is a claim
    // about a list that has no grandchild in it.
    expect(rows.map(\.id) == [rowOne, rowTwo, rowThree, rowFour, rowFive]
           && rows.map(\.depth) == [0, 1, 2, 0, 1],
           "the rollup fixture must nest three deep beside a two-deep group — got \(rows.map { ($0.title.suffix(2), $0.depth) })")

    let rollups = InboxSort.rollups(in: rows)

    // A ROLLUP EXISTS FOR EXACTLY THE ROWS THAT DRAW A TRIANGLE. The disclosure and
    // the rollup answer the same question ("is there a group here"), so they are
    // pinned to each other rather than left to two derivations agreeing by luck.
    expect(Set(rollups.keys) == InboxSort.parentIds(in: rows),
           "a rollup exists for exactly the rows with children here — rollups \(rollups.keys.count), parents \(InboxSort.parentIds(in: rows).count)")
    expect(rollups[rowThree] == nil && rollups[rowFive] == nil,
           "a leaf has no rollup at all, rather than a rollup of zero")

    // TRANSITIVE, AND ONCE EACH. `rowOne` has one child and one grandchild.
    expect(rollups[rowOne] == ChildRollup(children: 2, working: 1, needsYou: 1, failed: 0),
           "a root counts its grandchild too, once — got \(String(describing: rollups[rowOne]))")
    expect(rollups[rowTwo] == ChildRollup(children: 1, working: 0, needsYou: 1, failed: 0),
           "the middle of the chain counts only what is below IT — got \(String(describing: rollups[rowTwo]))")
    expect(rollups[rowFour] == ChildRollup(children: 1, working: 0, needsYou: 0, failed: 1),
           "the other group is counted on its own — got \(String(describing: rollups[rowFour]))")
    // The two folds that hide the grandchild are two different folds, so it is in
    // both tallies — that is the shape of the thing, not a double count.
    expect(rollups[rowOne]!.children == rollups[rowTwo]!.children + 1,
           "the root's tally is its child plus everything the child's tally holds")

    // `needsAnyone` is the one bit a collapsed row is really being asked for, and
    // `failed` counts toward it: broken work under a fold is the loudest thing a
    // fold can hide.
    expect(rollups[rowOne]!.needsAnyone && rollups[rowFour]!.needsAnyone,
           "a group holding an approval, or a failure, is asking for someone")
    let quiet = InboxSort.rollups(in: InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 500),
        sortRow(rowTwo, spawnedAfter: 400, state: .working, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 300, state: .ready, parentId: rowOne),
    ]))
    expect(quiet[rowOne] == ChildRollup(children: 2, working: 1, needsYou: 0, failed: 0),
           "a `ready` descendant is a child and nothing else — got \(String(describing: quiet[rowOne]))")
    expect(!quiet[rowOne]!.needsAnyone,
           "a group of working and finished agents is not asking for anyone")

    // THE LINE, including the plural and the order. Counts first (it is what says
    // the fold is hiding anything), then only the non-zero tallies, loudest first.
    expect(rollups[rowOne]!.summary == "2 children · 1 needs you · 1 working",
           "the rollup line leads with the count and then the loudest tally — got '\(rollups[rowOne]!.summary)'")
    expect(rollups[rowTwo]!.summary == "1 child · 1 needs you",
           "one child is a child — got '\(rollups[rowTwo]!.summary)'")
    expect(rollups[rowFour]!.summary == "1 child · 1 failed",
           "a broken descendant is named — got '\(rollups[rowFour]!.summary)'")
    expect(quiet[rowOne]!.summary == "2 children · 1 working",
           "a group with nothing to answer says only what it has — got '\(quiet[rowOne]!.summary)'")
    expect(ChildRollup(children: 3, working: 0, needsYou: 0, failed: 0).summary == "3 children",
           "a resting group says its size and stops")

    // DERIVED, NEVER STORED. Move one grandchild's state and the ROOT's tally moves
    // with it, from the same rows — nothing on the row remembers a stale count.
    let answered = InboxSort.rollups(in: InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 500),
        sortRow(rowTwo, spawnedAfter: 400, state: .working, parentId: rowOne),
        sortRow(rowThree, spawnedAfter: 300, state: .ready, parentId: rowTwo),
        sortRow(rowFour, spawnedAfter: 200),
        sortRow(rowFive, spawnedAfter: 100, state: .failed, parentId: rowFour),
    ]))
    expect(answered[rowOne] == ChildRollup(children: 2, working: 1, needsYou: 0, failed: 0),
           "answering the grandchild empties the root's `needs you` — got \(String(describing: answered[rowOne]))")

    // A CHILD PROMOTED OUT OF ITS GROUP IS NOBODY'S ROLLUP, the same call
    // `visibleRows` and `parentIds` make: its parent settled into history, so the
    // child is a root on screen and counting it under a row it no longer sits with
    // would report a group that is not there to fold.
    let crossBlock = InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 400, lifecycle: .settled(at: sortEpoch)),
        sortRow(rowTwo, spawnedAfter: 300, state: .approval, parentId: rowOne),
    ])
    expect(crossBlock.map(\.depth) == [0, 0],
           "the cross-block fixture must promote the child, got \(crossBlock.map(\.depth))")
    expect(InboxSort.rollups(in: crossBlock).isEmpty,
           "a settled parent whose child was promoted has no group here — got \(InboxSort.rollups(in: crossBlock))")

    // AN EMPTY LIST AND A FLAT ONE PRODUCE NOTHING, rather than a map of zeroes the
    // view would have to filter.
    expect(InboxSort.rollups(in: []).isEmpty, "no rows, no rollups")
    expect(InboxSort.rollups(in: InboxSort.sortForInbox(rows: sortFixture())).isEmpty,
           "a flat list has no groups in it")

    // A CORRUPTED CYCLE TERMINATES AND DOES NOT INFLATE A COUNT. `sortForInbox`
    // takes the first row of a cycle as a root and nests the rest under it, so a
    // rollup does exist here — what must not happen is a hang or a row counted twice.
    let cycle = InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 400, state: .working, parentId: rowTwo),
        sortRow(rowTwo, spawnedAfter: 300, state: .working, parentId: rowOne),
    ])
    let cycleRollups = InboxSort.rollups(in: cycle)
    expect(cycleRollups.values.allSatisfy { $0.children < cycle.count },
           "no rollup may count more descendants than there are other rows — got \(cycleRollups)")
    expect(cycleRollups.values.allSatisfy { $0.children == $0.working + $0.needsYou + $0.failed },
           "every descendant of a cycle is accounted for exactly once — got \(cycleRollups)")
}
