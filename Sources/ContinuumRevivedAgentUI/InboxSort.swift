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
    /// depth-first, with siblings ordered by the same comparator as roots.
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
    /// immediately after its parent, depth-first.
    ///
    /// A row whose `parentId` names an agent that is not in `rows` is a ROOT here —
    /// that is the honest answer for a child whose parent was archived, or whose
    /// parent settled into the other block, and it keeps the function a permutation
    /// instead of silently dropping the row.
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
        guard rows.count > 1 else { return rows }
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
        func emit(_ row: AgentInboxRow) {
            guard visited.insert(row.id).inserted else { return }
            ordered.append(row)
            for child in childrenOf[row.id] ?? [] {
                emit(child)
            }
        }
        for root in roots {
            emit(root)
        }
        // Cycle survivors. Never reached by a well-formed list; asserted rather
        // than assumed by `runInboxSortCycleCheck`.
        if ordered.count != rows.count {
            for row in rows.sorted(by: areInIncreasingOrder) where !visited.contains(row.id) {
                visited.insert(row.id)
                ordered.append(row)
            }
        }
        return ordered
    }
}
