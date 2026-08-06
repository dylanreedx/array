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
//
// Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
//  10. THE LIST HAS THREE SECTIONS — `partition(rows:now:)` is exhaustive and
//      disjoint, keeps each section's order, counts the shelf by its own contents,
//      and puts a woken agent back in `active` where a collapsed header cannot
//      hide it.
//
// Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
//  11. HISTORY IS PAGED, NOT DUMPED — `pageSettled` shows the ten most recently
//      ended, says how many it is holding, adds 25 per press, and always includes
//      the agent you have open however deep in history it is.
//
// Ticket: docs/38-tickets/94-sidebar-native-ux/P6.5-child-fanout-attention-rollup.md
//  12. BOUNDED FAN-OUT — direct children use a deterministic need/last-activity
//      priority, the remainder names every hidden subtree id, and expansion emits
//      the complete depth-first list without changing global root/block order.

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
    runInboxPartitionCheck()
    runInboxSettledPagingCheck()
    runInboxFanoutCheck()
    print("InboxSort checks: frozen under activity (200 trials, status-sorted witness fails), parent/child nesting, lifecycle relocation, history by end time, tie determinism, cycle termination, depth assignment (orphan promoted, chain capped at \(AgentInboxRow.maxDepth)), subtree collapse, transitive child rollup, the three-section partition (exhaustive, disjoint, woken rejoins active), settled tail paging (\(InboxSort.settledPageSize) then \(InboxSort.settledPageStep) more, open agent always in the page), and P6.5 bounded fan-out (need priority, complete remainder accounting, and live expansion model) passed")
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
    lastActiveAt: Date? = nil,
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
        lastActiveAt: lastActiveAt,
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
        lastActiveAt: row.lastActiveAt,
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
        lastActiveAt: row.lastActiveAt,
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
    expect(nested.last?.parentId == rowThree && nested.last?.depth == AgentInboxRow.maxDepth,
           "the real depth-3 descendant is still present but clamped rather than drawn as depth 2 by accident")
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

// MARK: - 10 · the three sections and the shelf
//
// Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
//
// THE PACKET'S THREE VERIFICATIONS, in order: the partition is exhaustive and
// disjoint; a woken agent lands in `active` and not on the shelf (the named
// witness); and the count the header shows is the shelf's own contents.
//
// Plus the watch-out, which is the one that could hide an approval: a snoozed
// agent with a pending request must not be shelved. It is asserted THROUGH
// `InboxLifecycle.resolve` rather than by handing this function a `.snoozed` row
// and hoping — the packet says the partition must RESPECT P4.2's precedence
// rather than re-decide it, so the check drives the real precedence and then
// partitions what it produced.
private func runInboxPartitionCheck() {
    let now = sortEpoch.addingTimeInterval(10_000)
    let shelfDate = now.addingTimeInterval(3_600)
    let rows = InboxSort.sortForInbox(rows: [
        sortRow(rowOne, spawnedAfter: 500, state: .working),
        sortRow(rowTwo, spawnedAfter: 400, lifecycle: .snoozed(until: shelfDate)),
        sortRow(rowThree, spawnedAfter: 300, lifecycle: .settled(at: now.addingTimeInterval(-600))),
        sortRow(rowFour, spawnedAfter: 200, state: .approval),
        // Deliberately a much later wake-up than `rowTwo`'s: the expiry case below
        // moves the clock past one snooze and not the other, so "the shelf emptied"
        // and "this row woke" are two different failures.
        sortRow(rowFive, spawnedAfter: 100, lifecycle: .snoozed(until: shelfDate.addingTimeInterval(7_200))),
    ])
    let parts = InboxSort.partition(rows: rows, now: now)

    // 1 · EXHAUSTIVE AND DISJOINT, asserted as the two halves they are: every row
    // is somewhere, and no row is in two places. `all` being a permutation is the
    // conjunction, and it is checked as a SEQUENCE so the section order is pinned
    // too — active, then the shelf, then the tail.
    let sectioned = parts.active + parts.snoozed + parts.settled
    expect(Set(sectioned.map(\.id)) == Set(rows.map(\.id)),
           "every row lands in a section — \(sectioned.count) of \(rows.count)")
    expect(sectioned.count == rows.count && Set(sectioned.map(\.id)).count == sectioned.count,
           "no row lands in two sections — \(sectioned.count) placements for \(Set(sectioned.map(\.id)).count) rows")
    expect(parts.all.map(\.id) == [rowOne, rowFour, rowTwo, rowFive, rowThree],
           "the sections draw active, then the shelf, then the tail — got \(parts.all.map { $0.title.suffix(2) })")
    // …and each section keeps the order it was handed, so the frozen order (P3.4)
    // survives the split rather than being re-sorted by it.
    expect(parts.active.map(\.id) == rows.filter { parts.active.contains($0) }.map(\.id)
           && parts.snoozed.map(\.id) == [rowTwo, rowFive],
           "a section preserves the order it arrived in — got \(parts.snoozed.map { $0.title.suffix(2) })")

    // 2 · THE COUNT IS THE SHELF'S CONTENTS, and it is what the header would show
    // whether or not the shelf is open — a collapsed section reports what it is
    // holding, not what is on screen.
    expect(parts.shelfCount == 2 && parts.shelfCount == parts.snoozed.count,
           "the shelf count is its own contents — \(parts.shelfCount) against \(parts.snoozed.count)")
    expect(parts.visible(shelfExpanded: false).map(\.id) == [rowOne, rowFour, rowThree],
           "a collapsed shelf takes its rows off the list and nothing else — got \(parts.visible(shelfExpanded: false).map { $0.title.suffix(2) })")
    expect(parts.visible(shelfExpanded: true).map(\.id) == parts.all.map(\.id),
           "…and an open one shows every row, in the same order")
    expect(parts.visible(shelfExpanded: false).count + parts.shelfCount == rows.count,
           "what is hidden plus what is shown is the whole list")

    // 3 · A WOKEN AGENT IS IN `active`, NOT ON THE SHELF. Two wakes, because there
    // are two: the snooze that ran out, and P4.6's raised hand while it had not.
    let expired = InboxSort.partition(
        rows: rows, now: shelfDate.addingTimeInterval(120))
    expect(expired.snoozed.map(\.id) == [rowFive],
           "a snooze whose moment has passed leaves the shelf — got \(expired.snoozed.map { $0.title.suffix(2) })")
    expect(expired.active.map(\.id).contains(rowTwo),
           "…and rejoins the active block, where a collapsed header cannot hide it")
    expect(!expired.visible(shelfExpanded: false).isEmpty
           && expired.visible(shelfExpanded: false).map(\.id).contains(rowTwo),
           "THE PACKET'S WITNESS: a woken agent is on screen with the shelf still folded")

    // The raised hand, driven through the real precedence rather than asserted
    // here: `snoozeHonoured` withholds the date, `resolve` answers `.active`, and
    // the row reaches the partition already out of the shelf.
    let handFacts = SnoozedAgentFacts(
        snoozedUntil: shelfDate, snoozedAt: now.addingTimeInterval(-60), pending: .approval)
    let handLifecycle = InboxLifecycle.resolve(
        override: .neutral,
        blockers: LifecycleBlockers.forPending(handFacts.pending),
        snoozedUntil: InboxLifecycle.snoozeHonoured(record: handFacts, now: now),
        now: now)
    expect(handLifecycle == .active,
           "P4.6's raised hand resolves active before the partition sees it — got \(handLifecycle)")
    expect(InboxSort.section(for: handLifecycle, now: now) == .active,
           "…so the shelf never gets the chance to hide an agent that is waiting on you")
    // The negative half, which is what makes the line above mean something: the
    // SAME snooze with nothing pending really does shelve.
    let quietLifecycle = InboxLifecycle.resolve(
        override: .neutral,
        snoozedUntil: InboxLifecycle.snoozeHonoured(
            record: SnoozedAgentFacts(snoozedUntil: shelfDate, snoozedAt: now.addingTimeInterval(-60)),
            now: now),
        now: now)
    expect(quietLifecycle == .snoozed(until: shelfDate)
           && InboxSort.section(for: quietLifecycle, now: now) == .snoozed,
           "a snooze with nothing waiting on you does shelve — got \(quietLifecycle)")

    // TOTAL over the vocabulary: every lifecycle answers exactly one section, so a
    // fifth case cannot fall through the view's `switch` into the wrong block.
    expect(InboxSort.section(for: .archived, now: now) == .active,
           "an archived row is not a section of its own — it has left the list")
    expect(InboxSort.section(for: .snoozed(until: now), now: now) == .active,
           "the shelf boundary is `>`, the same one `resolve` uses")
    expect(InboxSort.partition(rows: [], now: now) == InboxPartition(),
           "no rows, no sections")
}

// Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
//
// THE PACKET'S THREE VERIFICATIONS: 30 settled rows show 10 with the right hidden
// count; expanding adds 25; and the OPEN agent is in the page even when it would be
// row 27 — the named witness, because a list that hides the agent you just navigated
// to is contradicting the canvas.
//
// Plus the watch-out, which is an ordering one: the tail is paged in
// most-recently-ended order (P3.4's frozen spawn order is for the live block and
// must not reach history), and the page is a PREFIX of that order rather than a
// re-sort of it.
private func runInboxSettledPagingCheck() {
    let now = sortEpoch.addingTimeInterval(50_000)
    // Ids in an order that is neither the expected output nor the array order: the
    // low byte counts UP while the end times count DOWN, so a page taken in id
    // order — or one that returned its input untouched — comes out reversed.
    func settledId(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "3B408000-0000-4000-8000-%012X", index))!
    }
    /// Row `index` ended `index` minutes ago, so index 0 is the newest and the
    /// expected page is exactly `0..<limit`.
    func settledRow(_ index: Int) -> AgentInboxRow {
        let ended = now.addingTimeInterval(-60 * Double(index + 1))
        return AgentInboxRow(
            id: settledId(index),
            title: "S\(index)",
            state: .ready,
            lifecycle: .settled(at: ended),
            variant: RowVariant.forLifecycle(.settled(at: ended)),
            // Spawn order is the REVERSE of end order, so a page keyed on
            // `createdAt` would return the oldest ten and fail every line below.
            createdAt: sortEpoch.addingTimeInterval(Double(index))
        )
    }

    // 1 · THIRTY SETTLED ROWS SHOW TEN, and the footer's number is the rest.
    let thirty = InboxSort.partition(
        rows: InboxSort.sortForInbox(rows: (0..<30).map(settledRow)), now: now).settled
    expect(thirty.count == 30 && thirty.map(\.title) == (0..<30).map { "S\($0)" },
           "setup: the tail arrives most-recently-ended first — got \(thirty.prefix(3).map(\.title))")
    let first = InboxSort.pageSettled(thirty, limit: InboxSort.settledPageSize)
    expect(InboxSort.settledPageSize == 10 && InboxSort.settledPageStep == 25,
           "the packet's two numbers — \(InboxSort.settledPageSize) then \(InboxSort.settledPageStep) more")
    expect(first.shown.map(\.title) == (0..<10).map { "S\($0)" },
           "the tail opens with the ten most recently ended — got \(first.shown.map(\.title))")
    expect(first.hidden == 20 && first.hasMore,
           "…and says how many it is holding back — \(first.hidden) hidden")
    expect(first.shown.count + first.hidden == thirty.count,
           "what is shown plus what is hidden is the whole tail")

    // 2 · EXPANDING ADDS 25. Sixty rows, not thirty: with thirty the step and "the
    // rest of the list" are the same list, so a page that revealed EVERYTHING on the
    // first press would pass. Here it must reveal exactly 25 more and keep 25 back.
    let sixty = InboxSort.partition(
        rows: InboxSort.sortForInbox(rows: (0..<60).map(settledRow)), now: now).settled
    let opened = InboxSort.pageSettled(
        sixty, limit: InboxSort.settledPageSize + InboxSort.settledPageStep)
    expect(opened.shown.count == 35 && opened.shown.map(\.title) == (0..<35).map { "S\($0)" },
           "one press adds 25 — \(opened.shown.count) shown, from \(InboxSort.pageSettled(sixty, limit: InboxSort.settledPageSize).shown.count)")
    expect(opened.hidden == 25,
           "…and the rest stays behind the footer — \(opened.hidden) hidden")
    let twice = InboxSort.pageSettled(
        sixty, limit: InboxSort.settledPageSize + 2 * InboxSort.settledPageStep)
    expect(twice.shown.count == 60 && twice.hidden == 0 && !twice.hasMore,
           "…until history runs out, and then there is no footer — \(twice.shown.count) shown, \(twice.hidden) hidden")

    // 3 · THE PACKET'S WITNESS: the open agent is row 27 and is on screen anyway,
    // in its own place in history, and it costs nobody else their slot.
    let openId = thirty[26].id
    let withOpen = InboxSort.pageSettled(
        thirty, limit: InboxSort.settledPageSize, openAgentId: openId)
    expect(!first.shown.contains { $0.id == openId },
           "setup: row 27 must be outside the first page, or this witnesses nothing")
    expect(withOpen.shown.map(\.title) == (0..<10).map { "S\($0)" } + ["S26"],
           "THE PACKET'S WITNESS: the agent you have open is in the page wherever it falls — got \(withOpen.shown.map(\.title))")
    expect(withOpen.hidden == 19,
           "…and the count is of what is really hidden, one fewer — \(withOpen.hidden)")
    expect(withOpen.shown.count == first.shown.count + 1,
           "…and it does not push a recent row out to make room — \(withOpen.shown.count) against \(first.shown.count)")
    // An open agent already IN the page is not a duplicate, and an open agent that
    // is not in this tail at all (it is active, or in another scope) changes nothing.
    let openInPage = InboxSort.pageSettled(
        thirty, limit: InboxSort.settledPageSize, openAgentId: thirty[3].id)
    expect(openInPage == first,
           "an open agent already on the page changes nothing — \(openInPage.shown.count) shown")
    expect(InboxSort.pageSettled(thirty, limit: InboxSort.settledPageSize, openAgentId: rowOne) == first,
           "…and an open agent that is not in this tail changes nothing either")

    // 4 · THE WATCH-OUT, both ways. The page is a PREFIX of the order it was handed,
    // so it cannot re-sort history; and it is only ever handed the tail, so the
    // frozen order of the live block and the shelf cannot be paged at all.
    expect(zip(first.shown, thirty).allSatisfy { $0.id == $1.id },
           "the page is the head of the order it was given, not a re-sort of it")
    let mixed = InboxSort.sortForInbox(rows: (0..<12).map(settledRow) + [
        sortRow(rowOne, spawnedAfter: 500, state: .working),
        sortRow(rowTwo, spawnedAfter: 400, lifecycle: .snoozed(until: now.addingTimeInterval(3_600))),
    ])
    let parts = InboxSort.partition(rows: mixed, now: now)
    let page = InboxSort.pageSettled(parts.settled, limit: InboxSort.settledPageSize)
    expect(parts.active.map(\.id) == [rowOne] && parts.snoozed.map(\.id) == [rowTwo],
           "paging the tail leaves the active block and the shelf whole — \(parts.active.count) active, \(parts.snoozed.count) shelved")
    expect(page.shown.count == 10 && page.hidden == 2,
           "…and pages only the settled rows of a mixed list — \(page.shown.count) shown of \(parts.settled.count)")

    // Totality at the edges: a tail that fits has no footer, and a limit of nothing
    // still holds a page's worth of nothing rather than trapping the caller.
    expect(!InboxSort.pageSettled(Array(thirty.prefix(10)), limit: InboxSort.settledPageSize).hasMore,
           "a tail that fits draws no footer")
    expect(InboxSort.pageSettled([], limit: InboxSort.settledPageSize) == SettledPage(),
           "no history, no page")
    let none = InboxSort.pageSettled(thirty, limit: 0, openAgentId: openId)
    expect(none.shown.map(\.title) == ["S26"] && none.hidden == 29,
           "even at a limit of nothing the open agent is on screen — got \(none.shown.map(\.title))")
}

// MARK: 12 · bounded child fan-out and hidden attention (P6.5)

private func runInboxFanoutCheck() {
    func fanoutID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "3B410000-0000-4000-8000-%012X", value))!
    }

    let parentID = fanoutID(0)
    let childIDs = (0..<10).map { fanoutID($0 + 1) }
    let grandchildID = fanoutID(100)
    let parentDate = sortEpoch.addingTimeInterval(1_000)
    let childDate = sortEpoch.addingTimeInterval(100)
    func child(
        _ index: Int,
        state: InboxState = .ready,
        lastActiveOffset: TimeInterval
    ) -> AgentInboxRow {
        AgentInboxRow(
            id: childIDs[index], title: "Child \(index)", state: state,
            lastActiveAt: sortEpoch.addingTimeInterval(lastActiveOffset),
            createdAt: childDate.addingTimeInterval(Double(index)), parentId: parentID)
    }

    // Ten direct children make the cap bite. The first eight are not inferred
    // from collection order: explicit expected ids below exercise blocked,
    // failed, then last-active ordering independently of `boundedForInbox`.
    let inputRows = [
        child(0, state: .input, lastActiveOffset: 10),
        child(1, state: .approval, lastActiveOffset: 20),
        child(2, state: .failed, lastActiveOffset: 30),
        child(3, state: .working, lastActiveOffset: 40),
        child(4, lastActiveOffset: 0), // hidden, and owns a hidden grandchild
        child(5, lastActiveOffset: 50),
        child(6, lastActiveOffset: 60),
        child(7, lastActiveOffset: 70),
        child(8, lastActiveOffset: 80),
        child(9, lastActiveOffset: 90),
        AgentInboxRow(
            id: grandchildID, title: "Hidden grandchild", state: .working,
            lastActiveAt: sortEpoch.addingTimeInterval(91),
            createdAt: childDate.addingTimeInterval(11), parentId: childIDs[4]),
        AgentInboxRow(
            id: parentID, title: "Fan-out parent", state: .working,
            createdAt: parentDate)
    ]
    let sorted = InboxSort.sortForInbox(rows: inputRows)
    expect(sorted.map(\.id).first == parentID,
           "fan-out fixture has a real parent root before its descendants")
    expect(sorted.map(\.depth).contains(2),
           "fan-out fixture includes a real grandchild at depth 2, so descendant accounting is not flat")

    let bounded = InboxSort.boundedForInbox(rows: sorted)
    let expectedVisible = [
        parentID, childIDs[1], childIDs[0], childIDs[2],
        childIDs[9], childIDs[8], childIDs[7], childIDs[6], childIDs[5],
    ]
    expect(bounded.rows.map(\.id) == expectedVisible,
           "the independent need order keeps blocked/failed/recent children in the cap — got \(bounded.rows.map(\.id))")
    expect(bounded.rows.count == 1 + InboxSort.maxVisibleChildren,
           "a ten-child parent keeps exactly the eight-child inline budget — got \(bounded.rows.count)")
    expect(bounded.remainders.count == 1,
           "one capped parent produces one explicit remainder — got \(bounded.remainders.count)")
    guard let remainder = bounded.remainders.first else {
        fputs("FAIL: P6.5 fan-out remainder missing\n", stderr)
        Foundation.exit(1)
    }
    expect(remainder.hiddenChildIDs == [childIDs[3], childIDs[4]],
           "the remainder names the two independently hidden direct children — got \(remainder.hiddenChildIDs)")
    expect(remainder.hiddenDescendantIDs == [childIDs[3], childIDs[4], grandchildID],
           "the remainder accounts for a hidden child's whole subtree — got \(remainder.hiddenDescendantIDs)")
    expect(remainder.title == "2 more" && remainder.hiddenChildCount == 2,
           "the affordance is an N-more count of direct hidden children — got \(remainder.title)")
    expect(remainder.hiddenWorking == 2 && remainder.hiddenNeedsYou == 0 && remainder.hiddenFailed == 0,
           "hidden subtree state tallies are separate from the parent's own state — got working \(remainder.hiddenWorking), needs \(remainder.hiddenNeedsYou), failed \(remainder.hiddenFailed)")
    expect(bounded.accountedIDs(for: sorted) == Set(sorted.map(\.id)),
           "capping preserves complete agent accounting, including hidden descendants")
    expect(Set(bounded.rows.map(\.id)).intersection(Set(remainder.hiddenDescendantIDs)).isEmpty,
           "a hidden id is not also emitted inline")

    // Expansion is a model-level counterpart to the AppKit button witness: it
    // removes only the cap, preserves the frozen global root/block order, and
    // leaves no remainder metadata behind.
    let expanded = InboxSort.boundedForInbox(rows: sorted, expandedParents: [parentID])
    expect(expanded.remainders.isEmpty,
           "expanding the parent removes its remainder rather than hiding it elsewhere")
    expect(expanded.rows.map(\.id) == sorted.map(\.id),
           "expanded fan-out emits every sorted id exactly once in frozen depth-first order")
    expect(expanded.accountedIDs(for: sorted) == Set(sorted.map(\.id)),
           "expanded fan-out remains a complete accounting permutation")

    // Need-order is only the capped-survivor exception. With no cap to apply,
    // changing state/activity must not become a second inbox sort.
    let uncappedInput = [inputRows.last!] + Array(inputRows.prefix(4))
    let uncappedSorted = InboxSort.sortForInbox(rows: uncappedInput)
    let uncapped = InboxSort.boundedForInbox(rows: uncappedSorted)
    expect(uncapped.remainders.isEmpty
           && uncapped.rows.map(\.id) == uncappedSorted.map(\.id),
           "an uncapped group preserves frozen order instead of reordering by activity")

    // Equal need and equal activity have one deterministic survivor boundary.
    // Assert the direction explicitly so reversing or removing the stable id
    // tie-break changes which two agents the remainder names.
    let tiedParentID = fanoutID(300)
    let tiedChildIDs = (0..<10).map { fanoutID(301 + $0) }
    let tiedParent = AgentInboxRow(
        id: tiedParentID, title: "Tie parent", state: .ready,
        createdAt: sortEpoch.addingTimeInterval(3_000))
    let tiedChildren = tiedChildIDs.reversed().map { id in
        AgentInboxRow(
            id: id, title: "Tie child", state: .working,
            lastActiveAt: sortEpoch.addingTimeInterval(2_000),
            createdAt: sortEpoch.addingTimeInterval(1_500), parentId: tiedParentID)
    }
    let tiedSorted = InboxSort.sortForInbox(rows: [tiedParent] + tiedChildren)
    let tiedBounded = InboxSort.boundedForInbox(rows: tiedSorted)
    expect(tiedBounded.rows.map(\.id) == [tiedParentID] + Array(tiedChildIDs.prefix(8))
           && tiedBounded.remainders.first?.hiddenChildIDs == Array(tiedChildIDs.suffix(2)),
           "equal-priority/equal-activity fan-out uses the ascending stable-id tie-break")

    // A hidden blocker has its own separate rollup axis. Make enough direct
    // siblings blocked that one still falls behind the eight-row budget; the
    // parent itself remains `working` and its attention mark is not mutated.
    let blockedRows = inputRows.map { row -> AgentInboxRow in
        guard childIDs.contains(row.id) else { return row }
        return AgentInboxRow(
            id: row.id, title: row.title, state: .input,
            lastActiveAt: row.lastActiveAt, createdAt: row.createdAt, parentId: row.parentId)
    }
    let blockedSorted = InboxSort.sortForInbox(rows: blockedRows)
    let blocked = InboxSort.boundedForInbox(rows: blockedSorted)
    guard let blockedRemainder = blocked.remainders.first else {
        fputs("FAIL: P6.5 hidden-attention remainder missing\n", stderr)
        Foundation.exit(1)
    }
    expect(blockedRemainder.hiddenNeedsYou > 0 && blockedRemainder.hasAttention,
           "a blocked child that loses the cap raises the remainder's separate attention axis")
    expect(blockedSorted.first(where: { $0.id == parentID })?.attention == InboxAttention.none,
           "descendant attention does not overwrite the parent's own attention watermark")

    // Nested capped fan-out: the final visible child of the root is itself
    // capped. Its remainder and the root's remainder therefore share one
    // after-row anchor, which must remain an ordered parent/remainder pair rather
    // than a unique-key lookup that traps or retargets either button.
    let nestedRootID = fanoutID(200)
    let nestedChildIDs = (0..<9).map { fanoutID(210 + $0) }
    let nestedGrandchildIDs = (0..<9).map { fanoutID(230 + $0) }
    let nestedRoot = AgentInboxRow(
        id: nestedRootID, title: "Nested fan-out root", state: .ready,
        createdAt: sortEpoch.addingTimeInterval(2_000))
    let nestedDirect = nestedChildIDs.enumerated().map { index, id in
        AgentInboxRow(
            id: id, title: "Nested child \(index)", state: .ready,
            lastActiveAt: sortEpoch.addingTimeInterval(Double(900 - index)),
            depth: 1, createdAt: sortEpoch.addingTimeInterval(Double(1_900 - index)),
            parentId: nestedRootID)
    }
    let nestedGrandchildren = nestedGrandchildIDs.enumerated().map { index, id in
        AgentInboxRow(
            id: id, title: "Nested grandchild \(index)", state: .ready,
            lastActiveAt: sortEpoch.addingTimeInterval(Double(800 - index)),
            depth: 2, createdAt: sortEpoch.addingTimeInterval(Double(1_800 - index)),
            parentId: nestedChildIDs[7])
    }
    let nestedInput = [nestedRoot] + nestedDirect + nestedGrandchildren
    let nestedSorted = InboxSort.sortForInbox(rows: nestedInput)
    let nestedBounded = InboxSort.boundedForInbox(rows: nestedSorted)
    let nestedRemainders = nestedBounded.remainders
    guard let childRemainder = nestedRemainders.first(where: { $0.parentId == nestedChildIDs[7] }),
          let rootRemainder = nestedRemainders.first(where: { $0.parentId == nestedRootID }) else {
        fputs("FAIL: P6.5 nested fan-out remainders missing\n", stderr)
        Foundation.exit(1)
    }
    expect(nestedDirect.prefix(8).map(\.id).contains(nestedChildIDs[7]),
           "nested fixture leaves the capped child inside the root's eight visible direct-child slots")
    expect(nestedBounded.rows.last?.id == childRemainder.afterRowID,
           "the nested capped child is the root's final visible child subtree")
    expect(childRemainder.afterRowID == rootRemainder.afterRowID,
           "nested and root remainders intentionally share the final visible agent anchor")
    expect(nestedBounded.remaindersByAfterRow[childRemainder.afterRowID]?.map(\.parentId)
        == [nestedChildIDs[7], nestedRootID],
        "shared remainder anchors retain child-before-parent structure instead of a unique-key trap")
    expect(childRemainder.hiddenChildIDs == [nestedGrandchildIDs[8]]
           && rootRemainder.hiddenChildIDs == [nestedChildIDs[8]],
           "each nested remainder keeps its own direct hidden child and target")
    expect(nestedBounded.accountedIDs(for: nestedSorted) == Set(nestedSorted.map(\.id)),
           "nested capped fan-out accounts every root, child and grandchild exactly once")

    let childExpanded = InboxSort.boundedForInbox(
        rows: nestedSorted, expandedParents: [nestedChildIDs[7]])
    expect(childExpanded.remainders.count == 1
           && childExpanded.remainders.first?.parentId == nestedRootID
           && childExpanded.rows.contains(where: { $0.id == nestedGrandchildIDs[8] }),
           "expanding the visible capped child removes only its own remainder and materializes all nine grandchildren")
    let bothExpanded = InboxSort.boundedForInbox(
        rows: nestedSorted, expandedParents: [nestedRootID, nestedChildIDs[7]])
    expect(bothExpanded.remainders.isEmpty
           && bothExpanded.rows.map(\.id) == nestedSorted.map(\.id)
           && bothExpanded.accountedIDs(for: nestedSorted) == Set(nestedSorted.map(\.id)),
           "expanding the nested child and then its parent reaches every agent with no duplicate or wrong-target row")
}
