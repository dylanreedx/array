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
public struct FanoutRemainder: Equatable, Sendable {
    /// The parent whose inline children were capped.
    public let parentId: UUID
    /// Direct children omitted from the inline list. The visible `N more` count
    /// is this count, not a count derived from whatever happened to materialize.
    public let hiddenChildIDs: [UUID]
    /// Every row omitted below those children, including grandchildren. Keeping
    /// this separate makes the accounting proof fail if a hidden child owns a
    /// subtree that the remainder forgets to count.
    public let hiddenDescendantIDs: [UUID]
    /// The last visible agent row in this parent's inline subtree. The AppKit
    /// list inserts the remainder after this id without making the remainder an
    /// agent row or a selection target.
    public let afterRowID: UUID
    public let hiddenWorking: Int
    public let hiddenNeedsYou: Int
    public let hiddenFailed: Int

    public init(
        parentId: UUID,
        hiddenChildIDs: [UUID],
        hiddenDescendantIDs: [UUID],
        afterRowID: UUID,
        hiddenWorking: Int,
        hiddenNeedsYou: Int,
        hiddenFailed: Int
    ) {
        self.parentId = parentId
        self.hiddenChildIDs = hiddenChildIDs
        self.hiddenDescendantIDs = hiddenDescendantIDs
        self.afterRowID = afterRowID
        self.hiddenWorking = hiddenWorking
        self.hiddenNeedsYou = hiddenNeedsYou
        self.hiddenFailed = hiddenFailed
    }

    public var hiddenChildCount: Int { hiddenChildIDs.count }
    public var hiddenDescendantCount: Int { hiddenDescendantIDs.count }
    public var title: String { "\(hiddenChildCount) more" }
    public var hasAttention: Bool { hiddenNeedsYou > 0 || hiddenFailed > 0 }

    /// The accessibility string keeps the visible affordance short while
    /// exposing the hidden attention axis to VoiceOver as well.
    public var accessibilityTitle: String {
        var parts = ["\(hiddenChildCount) more \(hiddenChildCount == 1 ? "agent" : "agents")"]
        if hiddenNeedsYou > 0 { parts.append("\(hiddenNeedsYou) needs you") }
        if hiddenFailed > 0 { parts.append("\(hiddenFailed) failed") }
        return parts.joined(separator: " · ")
    }

    /// A stable identity for the list's incremental-render decision. Attention
    /// counts are included because a non-agent remainder cell has no row diff of
    /// its own to trigger a repaint. The anchor is included too: expanding a
    /// nested visible child can move its parent's remainder to a later agent row
    /// without changing the parent's hidden-child count.
    public var identity: String {
        let ids = hiddenChildIDs.map(\.uuidString).joined(separator: ",")
        return "\(parentId.uuidString):\(afterRowID.uuidString):\(ids):\(hiddenWorking):\(hiddenNeedsYou):\(hiddenFailed)"
    }
}

public struct BoundedInbox: Equatable, Sendable {
    /// The agent rows that remain inline after every parent cap is applied.
    public let rows: [AgentInboxRow]
    /// One remainder for each capped parent. A dictionary view is convenient for
    /// the AppKit list, while the ordered array keeps deterministic equality and
    /// lets checks prove every deferred group was rendered.
    public let remainders: [FanoutRemainder]

    public init(rows: [AgentInboxRow], remainders: [FanoutRemainder]) {
        self.rows = rows
        self.remainders = remainders
    }

    public var remainderByParent: [UUID: FanoutRemainder] {
        Dictionary(uniqueKeysWithValues: remainders.map { ($0.parentId, $0) })
    }

    /// A visible child can be the final visible child of its parent while also
    /// owning a capped subtree. Both remainder affordances then belong after the
    /// same agent row. Keep the ordered values rather than forcing a one-to-one
    /// anchor dictionary; the nested remainder is emitted before its parent's
    /// remainder, matching the depth-first materialization order.
    public var remaindersByAfterRow: [UUID: [FanoutRemainder]] {
        Dictionary(grouping: remainders, by: \.afterRowID)
    }

    /// Every input id is either inline or named by exactly one deferred subtree.
    /// The view check uses this independently of cell materialization.
    public func accountedIDs(for input: [AgentInboxRow]) -> Set<UUID> {
        Set(rows.map(\.id)).union(remainders.flatMap(\.hiddenDescendantIDs))
    }
}

public enum InboxSort {
    /// The maximum number of direct children shown inline for one parent. This is
    /// a presentation cap, deliberately separate from the supervisor's spawn cap:
    /// old stores and fixture corpora can contain more children than a new spawn
    /// policy permits, and none of those agents may vanish from accounting.
    public static let maxVisibleChildren = 8

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
    ///   4. **CLOSED** — archived rows, most recently CLOSED first (.plans/05-close-to-history.md).
    ///      P4.1 put `.archived` in the live block because archiving deleted the
    ///      record, so no archived row could ever reach a sort. Closing a tile now
    ///      parks the agent instead of deleting it, so archived rows are real and
    ///      need a block of their own — below history, because a closed agent is
    ///      further from your attention than a finished one, and ordered by close
    ///      time for the same reason history is ordered by end time: it is the
    ///      question you are asking when you open the section.
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
        var closed: [AgentInboxRow] = []
        for row in rows {
            switch row.lifecycle {
            case .active: live.append(row)
            case .snoozed: shelf.append(row)
            case .settled: history.append(row)
            case .archived: closed.append(row)
            }
        }
        return nest(live, by: newestSpawnedFirst)
            + nest(shelf, by: newestSpawnedFirst)
            + nest(history, by: mostRecentlyEndedFirst)
            + nest(closed, by: mostRecentlyEndedFirst)
    }

    /// Bound direct children without changing the global frozen root order. A
    /// parent may opt into the expanded set, in which case every child and every
    /// nested subtree is emitted. Otherwise the eight survivors are chosen by the
    /// inline need policy: human-blocked first, failed next, then most recently
    /// active, with a stable id tie-break.
    ///
    /// `rows` must already be the result of `sortForInbox`, because the depth and
    /// cross-section promotion decisions belong to that function. The result is
    /// still a depth-first agent sequence; remainder rows are metadata for the
    /// AppKit boundary and never enter `AgentInboxRow` or resource bookkeeping.
    public static func boundedForInbox(
        rows: [AgentInboxRow], expandedParents: Set<UUID> = []
    ) -> BoundedInbox {
        guard !rows.isEmpty else { return BoundedInbox(rows: [], remainders: []) }

        let present = Set(rows.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var childrenOf: [UUID: [AgentInboxRow]] = [:]
        var roots: [AgentInboxRow] = []
        for row in rows {
            if row.depth > 0, let parentId = row.parentId,
               parentId != row.id, present.contains(parentId) {
                childrenOf[parentId, default: []].append(row)
            } else {
                roots.append(row)
            }
        }

        func needRank(_ row: AgentInboxRow) -> Int {
            switch row.state {
            case .approval, .input: return 0
            case .failed: return 1
            case .working, .ready: return 2
            }
        }

        func needFirst(_ lhs: AgentInboxRow, _ rhs: AgentInboxRow) -> Bool {
            let leftRank = needRank(lhs)
            let rightRank = needRank(rhs)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftActive = lhs.lastActiveAt ?? lhs.createdAt
            let rightActive = rhs.lastActiveAt ?? rhs.createdAt
            if leftActive != rightActive { return leftActive > rightActive }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var emitted: [AgentInboxRow] = []
        emitted.reserveCapacity(rows.count)
        var remainders: [FanoutRemainder] = []
        var visited: Set<UUID> = []

        func subtreeIDs(start: AgentInboxRow) -> [UUID] {
            var result: [UUID] = []
            var seen: Set<UUID> = []
            func visit(_ row: AgentInboxRow) {
                guard seen.insert(row.id).inserted else { return }
                result.append(row.id)
                for child in childrenOf[row.id] ?? [] { visit(child) }
            }
            visit(start)
            return result
        }

        func counts(for ids: [UUID]) -> (working: Int, needsYou: Int, failed: Int) {
            ids.reduce(into: (working: 0, needsYou: 0, failed: 0)) { result, id in
                guard let row = byID[id] else { return }
                switch row.state {
                case .working: result.working += 1
                case .approval, .input: result.needsYou += 1
                case .failed: result.failed += 1
                case .ready: break
                }
            }
        }

        func emit(_ row: AgentInboxRow) {
            guard visited.insert(row.id).inserted else { return }
            emitted.append(row)
            let frozenChildren = childrenOf[row.id] ?? []
            guard !frozenChildren.isEmpty else { return }

            let selected: ArraySlice<AgentInboxRow>
            let hidden: ArraySlice<AgentInboxRow>
            if expandedParents.contains(row.id) || frozenChildren.count <= maxVisibleChildren {
                // Need-order is the bounded-survivor exception, not a second
                // inbox sort. An uncapped or explicitly expanded group keeps the
                // frozen depth-first order supplied by `sortForInbox`, so activity
                // cannot shuffle a list whose complete contents are visible.
                selected = frozenChildren[...]
                hidden = frozenChildren[frozenChildren.endIndex...]
            } else {
                let needOrdered = frozenChildren.sorted(by: needFirst)
                selected = needOrdered[..<maxVisibleChildren]
                hidden = needOrdered[maxVisibleChildren...]
            }
            for child in selected { emit(child) }
            guard !hidden.isEmpty else { return }

            let hiddenChildIDs = hidden.map(\.id)
            let hiddenDescendantIDs = hidden.flatMap { subtreeIDs(start: $0) }
            // Deferred rows are accounted, but deliberately not emitted. Marking
            // their complete subtrees visited keeps the permutation fallback from
            // appending them after the visible roots.
            visited.formUnion(hiddenDescendantIDs)
            let tally = counts(for: hiddenDescendantIDs)
            remainders.append(FanoutRemainder(
                parentId: row.id,
                hiddenChildIDs: hiddenChildIDs,
                hiddenDescendantIDs: hiddenDescendantIDs,
                afterRowID: emitted.last?.id ?? row.id,
                hiddenWorking: tally.working,
                hiddenNeedsYou: tally.needsYou,
                hiddenFailed: tally.failed
            ))
        }

        // Root order is already the frozen live/shelf/history order. Only the
        // sibling selection/order inside a parent uses the fan-out need policy.
        for root in roots { emit(root) }
        // A malformed cycle has no root. Preserve the same permutation guarantee
        // as `sortForInbox`; any cycle survivor is a root for this presentation
        // pass and its descendants are still accounted once.
        if emitted.count != rows.count {
            for row in rows where !visited.contains(row.id) { emit(row) }
        }
        return BoundedInbox(rows: emitted, remainders: remainders)
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

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md

    /// Which of the list's three sections a row belongs to — the same three blocks
    /// `sortForInbox` already orders by, named so a view can draw a header between
    /// them.
    ///
    /// READ OFF `lifecycle` AND NOTHING ELSE. That is the packet's watch-out
    /// discharged structurally: a snoozed agent holding a pending approval has
    /// already been resolved `.active` by `InboxLifecycle.resolve`'s step 1 (a
    /// blocker outranks the shelf), and P4.6's raised hand withholds the wake-up date
    /// so the same rung answers. If this looked at `state` or at a pending request it
    /// would be a SECOND precedence order, free to disagree with the one that is
    /// proved.
    public enum InboxSection: String, CaseIterable, Sendable {
        /// Everything you have not parked — the block the list opens with.
        case active
        /// The shelf: parked, coming back, and collapsed behind a counted header.
        case snoozed
        /// The tail: work that is over.
        case settled
        /// Closed agents, behind a counted header of their own — the tile is gone
        /// but the record, the transcript and the worktree are not, so opening one
        /// brings the agent back (.plans/05-close-to-history.md).
        case history
    }

    /// The section this lifecycle draws in at `now`.
    ///
    /// `now` is here for ONE case, and it is the packet's "a woken agent must not
    /// stay hidden behind a collapsed header": a row whose `snoozedUntil` has passed
    /// since it was built is not on the shelf any more, and returning it to the
    /// shelf until the next push would hide an agent whose snooze is over. The
    /// boundary is `>`, the same one `InboxLifecycle.resolve` and
    /// `raisedHandWhileSnoozed` use, so "snoozed" means one thing across the app.
    ///
    /// The other wake — a hand raised while the snooze still holds — never reaches
    /// here as `.snoozed` at all: `snoozeHonoured` withholds the date, `resolve`
    /// answers `.active`, and the row arrives in this function already active.
    ///
    /// `.archived` has its own section now (.plans/05-close-to-history.md). P4.1
    /// answered `.active` because archiving deleted the record, so no archived row
    /// could reach this function; closing a tile parks the agent instead, so the
    /// honest answer is the section it is actually drawn in.
    public static func section(for lifecycle: InboxLifecycle, now: Date) -> InboxSection {
        switch lifecycle {
        case .snoozed(let until): return until > now ? .snoozed : .active
        case .settled: return .settled
        case .archived: return .history
        case .active: return .active
        }
    }

    /// The list split into its three sections, IN ORDER within each — active, then
    /// the shelf, then the settled tail.
    ///
    /// EXHAUSTIVE AND DISJOINT by construction: every row is appended to exactly one
    /// of the three, so `active + snoozed + settled` is a permutation of `rows` and
    /// the view can concatenate the parts it is showing without a second sort.
    /// Concatenation is also what makes the sections CONTIGUOUS even when `now` has
    /// moved a row out of the shelf — `sortForInbox` would still have that row in the
    /// middle block, and a view that partitioned in place would draw it below the
    /// header it no longer belongs under.
    ///
    /// Order-preserving, so the caller supplies the order: hand it a list from
    /// `sortForInbox` and each section keeps the frozen order (P3.4) and the nesting
    /// (P2D.4) it arrived with.
    ///
    /// Pure and in this module, so the phone can reuse the split and so "which
    /// section is this row in" has one answer.
    public static func partition(rows: [AgentInboxRow], now: Date) -> InboxPartition {
        var parts = InboxPartition()
        for row in rows {
            switch section(for: row.lifecycle, now: now) {
            case .active: parts.active.append(row)
            case .snoozed: parts.snoozed.append(row)
            case .settled: parts.settled.append(row)
            case .history: parts.history.append(row)
            }
        }
        return parts
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md

    /// How many settled rows the tail opens with.
    public static let settledPageSize = 10
    /// How many more one press of the footer reveals.
    public static let settledPageStep = 25

    /// The settled tail as it is drawn: the first `limit` rows of it, plus however
    /// many are being held back.
    ///
    /// Paging is a TAIL rule and only a tail rule. The active block and the shelf
    /// are what you are working on and what is coming back — both are bounded by
    /// how many agents you have running — while history only grows, so it is the
    /// one section that can push the list off the screen. Nothing here reads a
    /// lifecycle: the caller hands over the section `partition` already decided, so
    /// this cannot become a second opinion about what "settled" means.
    ///
    /// ORDER IS THE CALLER'S, as everywhere else in this file. Hand it
    /// `InboxPartition.settled` and the page is the most recently ENDED rows
    /// (`mostRecentlyEndedFirst`), which is the order `sortForInbox` put history in
    /// and the only order in which "the first ten" means "the ten you just
    /// finished".
    ///
    /// THE OPEN AGENT IS ALWAYS IN THE PAGE, wherever it falls. Navigating to a
    /// settled agent and finding no row for it is the list contradicting the canvas,
    /// and it is the same force-include `InboxScope.filter` already performs for the
    /// scope. It is included IN PLACE rather than pulled to the top — its position in
    /// history is a fact, and moving it would be the tail re-sorting itself around
    /// what you happen to have open — and it does NOT consume one of the `limit`
    /// slots, so opening an old agent never pushes a recent one off the list.
    public static func pageSettled(
        _ settled: [AgentInboxRow], limit: Int, openAgentId: UUID? = nil
    ) -> SettledPage {
        var page = SettledPage()
        page.shown.reserveCapacity(min(settled.count, max(0, limit)))
        for (index, row) in settled.enumerated() {
            if index < limit || row.id == openAgentId {
                page.shown.append(row)
            } else {
                page.hidden += 1
            }
        }
        return page
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md

/// One page of the settled tail: what is on screen, and how much of history is not.
///
/// The count is carried rather than left to be `settled.count - shown.count` at each
/// call site, because the force-included open agent makes those two subtractions
/// differ — and the footer's number has to be the one that says how many rows
/// pressing it will actually produce.
public struct SettledPage: Equatable, Sendable {
    public var shown: [AgentInboxRow]
    public var hidden: Int

    public init(shown: [AgentInboxRow] = [], hidden: Int = 0) {
        self.shown = shown
        self.hidden = hidden
    }

    /// Whether the tail is holding anything back — the one test for "draw the
    /// footer", so an exhausted list cannot be left with a control that reveals
    /// nothing.
    public var hasMore: Bool { hidden > 0 }
}

// Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md

/// The three sections of the inbox, as values — the split `AgentInboxView` draws a
/// `Snoozed (N)` header into, and the shape a pure check can assert exhaustiveness
/// and disjointness on without a view.
public struct InboxPartition: Equatable, Sendable {
    public var active: [AgentInboxRow]
    public var snoozed: [AgentInboxRow]
    public var settled: [AgentInboxRow]
    /// Closed agents (.plans/05-close-to-history.md), behind their own counted
    /// header. Last, because it is the only section you go looking for.
    public var history: [AgentInboxRow]

    public init(
        active: [AgentInboxRow] = [],
        snoozed: [AgentInboxRow] = [],
        settled: [AgentInboxRow] = [],
        history: [AgentInboxRow] = []
    ) {
        self.active = active
        self.snoozed = snoozed
        self.settled = settled
        self.history = history
    }

    /// Everything, in the order the list draws it with both counted sections OPEN.
    /// The headers themselves are the view's, not this type's — a count is a fact
    /// about a section, a header is a row on a screen.
    public var all: [AgentInboxRow] { active + snoozed + settled + history }

    /// The rows on screen with each counted section in the given state — the one
    /// place "collapsed hides that section and nothing else" is written down.
    public func visible(shelfExpanded: Bool, historyExpanded: Bool = false) -> [AgentInboxRow] {
        (shelfExpanded ? active + snoozed : active)
            + settled
            + (historyExpanded ? history : [])
    }

    /// What the header says it is holding. The count is of the SHELF, never of what
    /// is on screen, which is the whole point of a collapsed section: "deferred work
    /// is visible as a count without occupying the list".
    public var shelfCount: Int { snoozed.count }

    /// The same fact for the History header. Separate property rather than a
    /// parameterised one so a call site cannot ask the shelf for history's count.
    public var historyCount: Int { history.count }
}
