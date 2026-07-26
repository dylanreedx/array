import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.4-frozen-sort.md
//
// THE DESKTOP'S ORDER IS FROZEN: a row holds the position it was spawned into
// until a LIFECYCLE transition moves it. Activity never reorders anything, so the
// screen only moves when you act — which matters doubly in a canvas app, where
// position is the user's index into their own work.
//
// This is deliberately NOT what `AgentsBoardProjection.rows(from:)` does. That
// fold is attention-first and stays that way: the phone is a glance surface where
// the loudest thing should be at the top, and it is looked at for seconds. The two
// sorts coexist on purpose, and the divergence is asserted rather than left to
// drift (`runInboxSortDivergesFromBoardOrderCheck`, in CoreChecks — it is the one
// place both orders are visible, since this module may not import Core).
public enum InboxSort {
    /// The desktop inbox's order.
    ///
    /// Three blocks, in this order:
    ///
    ///   1. **LIVE** — everything you have not parked, newest-spawned first. This
    ///      is the frozen part: no status, elapsed time, attention mark or event
    ///      can move a row within it, because none of them is an input to the
    ///      comparator.
    ///   2. **SHELF** — snoozed rows (P4.7), still in frozen spawn order. Snoozing
    ///      is a lifecycle transition, so it MOVES the row — down here — but the
    ///      shelf is not history: a snoozed agent is coming back, and ordering it
    ///      by a wake-up time would make the shelf shuffle itself as the clock runs.
    ///   3. **HISTORY** — settled rows, most recently ENDED first. They are a
    ///      record of finished work, so recency of the ending is the useful order;
    ///      and an end time stops changing the moment the row settles, so this
    ///      block is just as still as the other two.
    ///
    /// `.archived` stays in the live block, because an archived row has left the
    /// list entirely by the time anything draws it (P4.1) — the same call
    /// `RowVariant.forLifecycle` already makes by leaving it a card.
    ///
    /// Within each block, a CHILD is placed immediately after its parent (P2D.4),
    /// depth-first, with siblings ordered by the same comparator as roots, and every
    /// row's `depth` is ASSIGNED here — 0 for a root, one more than its parent for a
    /// child, capped at `AgentInboxRow.maxDepth`.
    ///
    /// TOTAL and deterministic: equal timestamps are broken by the id's string
    /// form, the same tiebreak `AgentStore.isOrderedBefore` already uses for the
    /// records these rows are built from, so two surfaces cannot disagree about
    /// which of two rows spawned in the same millisecond comes first. The result is
    /// a permutation of the input — every row goes somewhere exactly once, including
    /// rows caught in a parent cycle (see `nest`).
    public static func sortForInbox(rows: [AgentInboxRow]) -> [AgentInboxRow] {
        var live: [AgentInboxRow] = []
        var shelf: [AgentInboxRow] = []
        var history: [AgentInboxRow] = []
        for row in rows {
            switch row.lifecycle {
            case .active, .archived: live.append(row)
            case .snoozed: shelf.append(row)
            case .settled: history.append(row)
            }
        }
        return nest(live, by: newestSpawnedFirst)
            + nest(shelf, by: newestSpawnedFirst)
            + nest(history, by: mostRecentlyEndedFirst)
    }

    /// Newest-spawned first. **`createdAt` is the only timestamp read here** — the
    /// row carries no `updatedAt` and this comparator must never gain one; a
    /// last-activity key is precisely how a list starts jumping under a working
    /// agent.
    public static func newestSpawnedFirst(_ lhs: AgentInboxRow, _ rhs: AgentInboxRow) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Most recently ended first, for the history block.
    ///
    /// Only reachable for settled rows (`endedAt` is non-nil for exactly those),
    /// but total anyway: a row with no end time sorts as though it ended at
    /// `distantPast`, i.e. at the bottom, rather than trapping the comparator in an
    /// inconsistent order.
    public static func mostRecentlyEndedFirst(_ lhs: AgentInboxRow, _ rhs: AgentInboxRow) -> Bool {
        let left = lhs.lifecycle.endedAt ?? .distantPast
        let right = rhs.lifecycle.endedAt ?? .distantPast
        if left != right {
            return left > right
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Order `rows` by `areInIncreasingOrder`, then pull every child up to sit
    /// immediately after its parent, depth-first, and stamp each row's `depth`.
    ///
    /// A row whose `parentId` names an agent that is not in `rows` is a ROOT here —
    /// that is the honest answer for a child whose parent was archived, or whose
    /// parent settled into the other block, and it keeps the function a permutation
    /// instead of silently dropping the row. It is also PROMOTED TO DEPTH 0: an
    /// orphan indented under nothing reads as a rendering bug, and the row it would
    /// look nested beneath is whatever happens to precede it.
    ///
    /// The `visited` set is a cycle guard, not decoration: `parentId` comes from
    /// stored records, and a corrupted pair pointing at each other would otherwise
    /// recurse forever. Rows unreachable from any root (i.e. inside a cycle) are
    /// appended in comparator order at the end, so the output length always equals
    /// the input length.
    private static func nest(
        _ rows: [AgentInboxRow],
        by areInIncreasingOrder: (AgentInboxRow, AgentInboxRow) -> Bool
    ) -> [AgentInboxRow] {
        // No `count > 1` shortcut: a single row can still be an orphan carrying a
        // stale depth from whoever built it, and returning it untouched would draw
        // one lone row indented under nothing.
        let present = Set(rows.map(\.id))
        var childrenOf: [UUID: [AgentInboxRow]] = [:]
        var roots: [AgentInboxRow] = []
        for row in rows {
            if let parentId = row.parentId, parentId != row.id, present.contains(parentId) {
                childrenOf[parentId, default: []].append(row)
            } else {
                roots.append(row)
            }
        }
        // Sorted once per sibling group rather than once over the whole list: the
        // comparator is only meaningful between rows that compete for the same
        // slot, and a child never competes with its parent's peers.
        roots.sort(by: areInIncreasingOrder)
        for key in childrenOf.keys {
            childrenOf[key]?.sort(by: areInIncreasingOrder)
        }

        var ordered: [AgentInboxRow] = []
        ordered.reserveCapacity(rows.count)
        var visited: Set<UUID> = []
        // The cap is applied to the DRAWN depth only, never to the ordering: a
        // great-grandchild still follows its parent, it just stops indenting. The
        // spawn cap (P2D.2) means a well-formed list cannot reach here — this is for
        // records that came off disk before the cap, or under a raised one.
        func emit(_ row: AgentInboxRow, depth: Int) {
            guard visited.insert(row.id).inserted else { return }
            var placed = row
            placed.depth = min(depth, AgentInboxRow.maxDepth)
            ordered.append(placed)
            for child in childrenOf[row.id] ?? [] {
                emit(child, depth: depth + 1)
            }
        }
        for root in roots {
            emit(root, depth: 0)
        }
        // Cycle survivors. Never reached by a well-formed list; asserted rather
        // than assumed by `runInboxSortCycleCheck`. The first row of a cycle is
        // taken as a root — a cycle has no root to measure a depth from — and
        // `emit` walks and marks the rest of it from there, which is also what
        // stops the walk going round.
        if ordered.count != rows.count {
            for row in rows.sorted(by: areInIncreasingOrder) where !visited.contains(row.id) {
                emit(row, depth: 0)
            }
        }
        return ordered
    }

    // Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md

    /// The rows a list with these parents collapsed actually shows: every row whose
    /// PARENT CHAIN passes through a collapsed row is dropped, at any depth.
    ///
    /// Takes rows already through `sortForInbox`, which is what makes one pass
    /// enough — a parent always precedes its children there, so a hidden row's
    /// children are seen after it and inherit the hiding. Handing it an unsorted list
    /// would hide a child whose parent happens to come first and keep its sibling.
    ///
    /// WHAT IS HIDEABLE IS WHAT THE SORT ACTUALLY NESTED — a row at depth 0 is a
    /// root and is never hidden, however its `parentId` reads. That is not a detail:
    /// a child whose parent SETTLED is promoted to a root in the live block while the
    /// parent sits in history, still on screen and still foldable, and folding
    /// history there would delete an active agent from the list. (Found in
    /// cross-review; keying on `parentId` alone did exactly that.)
    ///
    /// A collapsed id that names no parent in `rows` (its agent settled, or is in
    /// another scope) hides nothing: the set is remembered rather than pruned, so
    /// widening the scope back re-collapses the group it was collapsed in.
    ///
    /// Pure and in this module, not in the list view, so the phone can reuse it —
    /// and so the "is this row on screen" question has one answer. Collapsed state
    /// itself is LOCAL UI state (the packet: "not synced"): which groups you folded
    /// on this Mac is not a fact about the agents.
    public static func visibleRows(_ rows: [AgentInboxRow], collapsed: Set<UUID>) -> [AgentInboxRow] {
        guard !collapsed.isEmpty else { return rows }
        var hidden: Set<UUID> = []
        return rows.filter { row in
            // `depth > 0` is the test for "the sort nested this row under something
            // here": an orphan and a cross-block promotion are both roots, and a
            // fold on the parent they name must not remove them.
            guard row.depth > 0, let parentId = row.parentId,
                  collapsed.contains(parentId) || hidden.contains(parentId) else { return true }
            hidden.insert(row.id)
            return false
        }
    }

    /// The rows in this list that HAVE a child in it — the only rows a disclosure
    /// control belongs on.
    ///
    /// Read off the same list the view draws, and BEFORE collapsing it — a folded
    /// group has to keep the triangle you unfold it with.
    ///
    /// Counted from the rows the sort actually NESTED (`depth > 0`), for the same
    /// reason `visibleRows` hides only those: a child whose parent settled into the
    /// other block names a row that is on screen and is not its parent here, and a
    /// triangle on that settled row would fold nothing.
    public static func parentIds(in rows: [AgentInboxRow]) -> Set<UUID> {
        Set(rows.filter { $0.depth > 0 }.compactMap(\.parentId))
    }

    // Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md

    /// What is under each parent in this list, for the parents that have anything
    /// under them — the line a COLLAPSED parent keeps so that folding a group does
    /// not hide the one row that needs a human.
    ///
    /// Read off the same list the view draws and BEFORE collapsing it, exactly like
    /// `parentIds(in:)`, and nested by the same test (`depth > 0` plus a `parentId`
    /// that is present): a rollup must count what a fold on this row would HIDE, and
    /// `visibleRows` hides precisely those rows. A child promoted to a root because
    /// its parent settled into the other block is on screen in its own right, so it
    /// is nobody's rollup here — the same call the disclosure triangle already makes,
    /// and the reason the two can never disagree about whether a group exists.
    ///
    /// TRANSITIVE, each descendant counted once (see `ChildRollup`): a row's tally
    /// includes its grandchildren, and a grandchild appears in its parent's rollup
    /// AND its grandparent's — that is not double-counting, it is two different
    /// folds hiding the same row. Within one rollup the `visited` walk guarantees
    /// each descendant is added a single time, so a corrupted `parentId` cycle
    /// cannot inflate a count or hang the walk (`sortForInbox` already emits every
    /// row exactly once, and this walks the same edges).
    ///
    /// Pure and in this module, so the phone can reuse it and so "what is under this
    /// row" has one answer.
    public static func rollups(in rows: [AgentInboxRow]) -> [UUID: ChildRollup] {
        var childrenOf: [UUID: [AgentInboxRow]] = [:]
        for row in rows where row.depth > 0 {
            guard let parentId = row.parentId else { continue }
            childrenOf[parentId, default: []].append(row)
        }
        guard !childrenOf.isEmpty else { return [:] }

        var rollups: [UUID: ChildRollup] = [:]
        for row in rows where childrenOf[row.id] != nil {
            var children = 0, working = 0, needsYou = 0, failed = 0
            var visited: Set<UUID> = [row.id]
            var queue = childrenOf[row.id] ?? []
            while let descendant = queue.popLast() {
                guard visited.insert(descendant.id).inserted else { continue }
                children += 1
                switch descendant.state {
                case .working: working += 1
                case .approval, .input: needsYou += 1
                case .failed: failed += 1
                case .ready: break
                }
                queue.append(contentsOf: childrenOf[descendant.id] ?? [])
            }
            rollups[row.id] = ChildRollup(
                children: children, working: working, needsYou: needsYou, failed: failed)
        }
        return rollups
    }
}
