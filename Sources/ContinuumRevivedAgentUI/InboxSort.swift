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
    /// The parent's folded children are on screen; this row folds them back.
    public let isExpanded: Bool

    public init(
        parentId: UUID,
        hiddenChildIDs: [UUID],
        hiddenDescendantIDs: [UUID],
        afterRowID: UUID,
        hiddenWorking: Int,
        hiddenNeedsYou: Int,
        hiddenFailed: Int,
        isExpanded: Bool = false
    ) {
        self.parentId = parentId
        self.hiddenChildIDs = hiddenChildIDs
        self.hiddenDescendantIDs = hiddenDescendantIDs
        self.afterRowID = afterRowID
        self.hiddenWorking = hiddenWorking
        self.hiddenNeedsYou = hiddenNeedsYou
        self.hiddenFailed = hiddenFailed
        self.isExpanded = isExpanded
    }

    public var hiddenChildCount: Int { hiddenChildIDs.count }
    public var hiddenDescendantCount: Int { hiddenDescendantIDs.count }
    /// "4 more, all done" when nothing folded is live or failed; otherwise the
    /// count and what is in it, "4 more · 1 failed". "Show less" while open.
    public var title: String {
        if isExpanded { return "Show less" }
        var parts = ["\(hiddenChildCount) more"]
        if hiddenNeedsYou > 0 { parts.append("\(hiddenNeedsYou) needs you") }
        if hiddenFailed > 0 { parts.append("\(hiddenFailed) failed") }
        if hiddenWorking > 0 { parts.append("\(hiddenWorking) working") }
        return parts.count == 1 ? "\(hiddenChildCount) more, all done" : parts.joined(separator: " · ")
    }
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
    /// without changing the parent's hidden-child count. Open, the row reads
    /// "Show less" whatever its rows are doing, so the counts are left out: a
    /// helper's state change must not rebuild a 40-row open group.
    public var identity: String {
        let ids = hiddenChildIDs.map(\.uuidString).joined(separator: ",")
        if isExpanded { return "\(parentId.uuidString):\(afterRowID.uuidString):\(ids):open" }
        return "\(parentId.uuidString):\(afterRowID.uuidString):\(ids):\(hiddenWorking):\(hiddenNeedsYou):\(hiddenFailed):\(isExpanded)"
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
    ///   3. **HISTORY** — settled AND archived rows together, most recently
    ///      ENDED first (settle time or close time, whichever the row has). Dylan:
    ///      "one history shelf" (decisions pass). They are a record of work you
    ///      are done watching, so recency of the ending is the useful order; and
    ///      an end time stops changing the moment the row ends, so this block is
    ///      just as still as the other two. Settle and Archive stay distinct
    ///      lifecycles (undo restores each exactly); only the block is shared,
    ///      which is also what lets a settled child nest under an archived parent.
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
            case .active: live.append(row)
            case .snoozed: shelf.append(row)
            case .settled, .archived: history.append(row)
            }
        }
        return nest(live, by: newestSpawnedFirst)
            + nest(shelf, by: newestSpawnedFirst)
            + nest(history, by: mostRecentlyEndedFirst)
    }

    // Plan: .plans/106-sidebar-ownership (helper priority)
    /// How long a finished subagent stays in its lead's card before it folds into
    /// the "N more" row.
    public static let recentSubagentWindow: TimeInterval = 30 * 60

    /// When a finished agent stopped: its last turn's end, else its last
    /// activity, else its spawn.
    static func finishedAt(_ row: AgentInboxRow) -> Date {
        row.terminalEvent?.endedAt ?? row.lastActiveAt ?? row.createdAt
    }

    /// Whether the agent's last turn broke: the failed state, or a failed end
    /// on a row whose state has since read ready.
    static func endedInFailure(_ row: AgentInboxRow) -> Bool {
        if row.state == .failed { return true }
        switch row.terminalEvent?.outcome {
        case .failed?, .runtimeError?: return true
        default: return false
        }
    }

    /// A failed agent you have not opened yet. Opening an agent moves its read
    /// mark, so this is the one place "seen" is decided.
    static func isUnopenedFailure(_ row: AgentInboxRow) -> Bool {
        endedInFailure(row) && (row.terminalIsUnread || row.attention == .unread)
    }

    /// When this subagent leaves its lead's visible rows by age, or nil for a
    /// lead or a subagent that is still live. The list sets one timer for the
    /// earliest of these, so ageing out does not wait for the next push.
    public static func subagentFoldsAt(_ row: AgentInboxRow) -> Date? {
        guard row.parentId != nil else { return nil }
        switch row.state {
        case .approval, .input, .working: return nil
        case .ready, .failed: return finishedAt(row).addingTimeInterval(recentSubagentWindow)
        }
    }

    /// Where one row stands in its parent's card: 0 needs you, 1 working,
    /// 2 finished within the window (`at` orders these newest first), 3 folded.
    /// A failed row stands once: opened, it folds whatever its age.
    private static func ownStanding(_ row: AgentInboxRow, now: Date) -> (rank: Int, at: Date) {
        let at = finishedAt(row)
        switch row.state {
        case .approval, .input: return (0, at)
        case .working: return (1, at)
        case .ready, .failed:
            if endedInFailure(row), !isUnopenedFailure(row) { return (3, at) }
            return (now.timeIntervalSince(at) < recentSubagentWindow ? 2 : 3, at)
        }
    }

    /// What a lead's card shows. Each parent's children, in this order: those
    /// that need you, then those working (both in the frozen spawn order), then
    /// those that finished within `recentSubagentWindow`, newest first, at most
    /// `maxVisibleChildren` in all. Everything else folds into the parent's one
    /// remainder row ("N more, all done"). A child stands where the most pressing
    /// row of its subtree stands, so a finished subagent whose helper still works
    /// stays in view.
    ///
    /// An expanded parent emits its folded children too, after the visible ones
    /// and newest finished first, and keeps its remainder (`isExpanded`) so the
    /// same row folds them back.
    ///
    /// `rows` must already be the result of `sortForInbox`, because the depth and
    /// cross-section promotion decisions belong to that function. The result is
    /// still a depth-first agent sequence; remainder rows are metadata for the
    /// AppKit boundary and never enter `AgentInboxRow` or resource bookkeeping.
    public static func boundedForInbox(
        rows: [AgentInboxRow], expandedParents: Set<UUID> = [], now: Date
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

        var standings: [UUID: (rank: Int, at: Date)] = [:]
        func standing(_ row: AgentInboxRow, path: Set<UUID> = []) -> (rank: Int, at: Date) {
            if let known = standings[row.id] { return known }
            var best = ownStanding(row, now: now)
            let path = path.union([row.id])
            for child in childrenOf[row.id] ?? [] where !path.contains(child.id) {
                let below = standing(child, path: path)
                if below.rank < best.rank || (below.rank == best.rank && below.at > best.at) {
                    best = below
                }
            }
            standings[row.id] = best
            return best
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
                case .failed, .ready: if endedInFailure(row) { result.failed += 1 }
                }
            }
        }

        func emit(_ row: AgentInboxRow) {
            guard visited.insert(row.id).inserted else { return }
            emitted.append(row)
            let children = childrenOf[row.id] ?? []
            guard !children.isEmpty else { return }

            // The frozen index breaks every tie, so equal standings keep spawn order.
            let ranked = children.enumerated().map { (row: $1, index: $0, standing: standing($1)) }
            let shown = ranked.filter { $0.standing.rank < 3 }.sorted {
                if $0.standing.rank != $1.standing.rank { return $0.standing.rank < $1.standing.rank }
                if $0.standing.rank == 2, $0.standing.at != $1.standing.at {
                    return $0.standing.at > $1.standing.at
                }
                return $0.index < $1.index
            }
            let folded = ranked.filter { $0.standing.rank == 3 }.sorted {
                $0.standing.at != $1.standing.at ? $0.standing.at > $1.standing.at : $0.index < $1.index
            }
            let visible = shown.prefix(maxVisibleChildren).map(\.row)
            let hidden = shown.dropFirst(maxVisibleChildren).map(\.row) + folded.map(\.row)
            let isExpanded = expandedParents.contains(row.id)
            for child in visible { emit(child) }
            if isExpanded { for child in hidden { emit(child) } }
            guard !hidden.isEmpty else { return }

            let hiddenChildIDs = hidden.map(\.id)
            let hiddenDescendantIDs = hidden.flatMap { subtreeIDs(start: $0) }
            // Folded rows are accounted, but deliberately not emitted. Marking
            // their complete subtrees visited keeps the permutation fallback from
            // appending them after the visible roots.
            if !isExpanded { visited.formUnion(hiddenDescendantIDs) }
            let tally = counts(for: hiddenDescendantIDs)
            remainders.append(FanoutRemainder(
                parentId: row.id,
                hiddenChildIDs: hiddenChildIDs,
                hiddenDescendantIDs: hiddenDescendantIDs,
                afterRowID: emitted.last?.id ?? row.id,
                hiddenWorking: tally.working,
                hiddenNeedsYou: tally.needsYou,
                hiddenFailed: tally.failed,
                isExpanded: isExpanded
            ))
        }

        // Root order is already the frozen live/shelf/history order. Only the
        // sibling selection/order inside a parent uses the standing policy.
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
    /// Only reachable for settled and archived rows (`endedAt` is non-nil for
    /// exactly those), but total anyway: a row with no end time sorts as though it ended at
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
            var children = 0, working = 0, needsYou = 0, failed = 0, unopenedFailed = 0
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
                if isUnopenedFailure(descendant) { unopenedFailed += 1 }
                queue.append(contentsOf: childrenOf[descendant.id] ?? [])
            }
            rollups[row.id] = ChildRollup(
                children: children, working: working, needsYou: needsYou, failed: failed,
                unopenedFailed: unopenedFailed)
        }
        return rollups
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md

    /// Which of the list's sections a row belongs to — the same blocks
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
        /// Work you are done watching: settled agents and agents closed to
        /// History, in ONE section (decisions pass, "one history shelf"). The
        /// tile is gone but the record, the transcript and the worktree are not,
        /// so opening one brings the agent back (.plans/05-close-to-history.md).
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
    /// `.settled` and `.archived` share History (decisions pass). P4.1 answered
    /// `.active` for archived because archiving deleted the record; closing a tile
    /// parks the agent instead, and settling closes its tile too, so both are
    /// drawn in the one section a closed agent lives in.
    public static func section(for lifecycle: InboxLifecycle, now: Date) -> InboxSection {
        switch lifecycle {
        case .snoozed(let until): return until > now ? .snoozed : .active
        case .settled, .archived: return .history
        case .active: return .active
        }
    }

    /// The list split into its sections, IN ORDER within each — active, then the
    /// shelf, then History.
    ///
    /// EXHAUSTIVE AND DISJOINT by construction: every row is appended to exactly one
    /// of the three, so `active + snoozed + history` is a permutation of `rows` and
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
            case .history: parts.history.append(row)
            }
        }
        return parts
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md

    /// How many History rows the tail opens with. (The names say "settled" from
    /// P4.8, when the tail held only settled rows; it pages all of History now.)
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
    /// `InboxPartition.history` and the page is the most recently ENDED rows
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
    /// Settled agents and agents closed to History (.plans/05-close-to-history.md),
    /// ONE section behind one counted header (decisions pass). Last, because it
    /// is the only section you go looking for.
    public var history: [AgentInboxRow]

    public init(
        active: [AgentInboxRow] = [],
        snoozed: [AgentInboxRow] = [],
        history: [AgentInboxRow] = []
    ) {
        self.active = active
        self.snoozed = snoozed
        self.history = history
    }

    /// Everything, in the order the list draws it with both counted sections OPEN.
    /// The headers themselves are the view's, not this type's — a count is a fact
    /// about a section, a header is a row on a screen.
    public var all: [AgentInboxRow] { active + snoozed + history }

    /// The rows on screen with each counted section in the given state — the one
    /// place "collapsed hides that section and nothing else" is written down.
    public func visible(shelfExpanded: Bool, historyExpanded: Bool = false) -> [AgentInboxRow] {
        (shelfExpanded ? active + snoozed : active)
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
