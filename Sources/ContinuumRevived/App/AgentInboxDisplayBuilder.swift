import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Plan: the sidebar's per-push display work, off the main thread.
//
// `AgentInboxView.display(from:)` used to read the view's state and write a dozen
// fields as it went, so it could only run on main, and at 2,000+ agents it was the
// largest single cost of a push. This is the same derivation as a pure function:
// a value snapshot of everything it reads (`InboxDisplayInputs`) in, an immutable
// answer holding everything it used to write (`InboxDisplayModel`) out. The view
// builds the inputs, runs this (on main for a short list, on a serial queue for a
// long one) and applies the model in one step.

/// The last Quiet History projection and what it was built from.
struct InboxQuietHistoryProjection: Sendable {
    let historyIDs: Set<UUID>
    /// Every agent whose facts went into it: History's rows and each family's members.
    let members: Set<UUID>
    let searching: Bool
    let openAgentId: UUID?
    let openFamilyId: UUID?
    let families: [AgentInboxRow]
    let helpers: [UUID: Int]
    let dates: [UUID: Date]
}

/// What the scope menu's entries are derived from, besides the rows.
struct InboxScopeMenuInputs: Equatable, Sendable {
    var scope: InboxScope
    var workspaces: [InboxScopeMenu.Workspace]
    var projects: [String]
    var legacyWorkspaces: [String]
    var current: UUID?
    var offersCurrent: Bool
    var offersThisMac: Bool
}

/// Everything `InboxDisplayBuilder.build` reads, by value.
struct InboxDisplayInputs: Sendable {
    var rows: [AgentInboxRow]
    var clearMarks: [UUID: SidebarClearMark]
    var standingLeadIDs: Set<UUID>
    var hiddenKeys: Set<String>
    var searchQuery: String
    var openAgentId: UUID?
    var hiddenSources: Set<String>
    var scope: InboxScope
    var currentWorkspaceName: String?
    var currentWorkspaceId: UUID?
    var hiddenRevealed: Bool
    /// The ids drawn now, in order, when the sort is held under the pointer;
    /// nil when it is not held.
    var heldOrder: [UUID]?
    var sortMode: InboxSortMode
    var expandedFanoutParents: Set<UUID>
    var now: Date
    var foldChoices: [UUID: Bool]
    var foldsUntouchedGroups: Bool
    var sidebarLayout: SidebarLayout
    var dismissedIncidents: [String: String]
    var shelfExpanded: Bool
    var foldsHistoryIntoShelf: Bool
    var settledLimit: Int
    var historyExpanded: Bool
    var quietHistoryCache: InboxQuietHistoryProjection?
    var historyReuseHint: Set<UUID>?
    var quietHistoryNote: String
    /// Set when the scope menu's entries are wanted with this build.
    var scopeMenu: InboxScopeMenuInputs?
}

/// Everything `display(from:)` used to write, by value.
struct InboxDisplayModel: Sendable {
    var items: [InboxListItem] = []
    /// Clear marks that new activity released; the view drops and saves them.
    var releasedClearMarks: [UUID] = []
    var hiddenInScopeCount = 0
    var hiddenRevealed = false
    var revealedHiddenIds: Set<UUID> = []
    /// The sort was held under the pointer for this build.
    var sortHoldPending = false
    var marksWorkspaces = false
    var parentsWithChildren: Set<UUID> = []
    var ownershipAskByLead: [UUID: String] = [:]
    var fanoutRemaindersByParent: [UUID: FanoutRemainder] = [:]
    var fanoutRemaindersByAfterRow: [UUID: [FanoutRemainder]] = [:]
    var rollupsByParent: [UUID: ChildRollup] = [:]
    var collapsedParents: Set<UUID> = []
    var sidebarClearIDs: [UUID] = []
    var sidebarIncidents: [SidebarIncident] = []
    var sidebarTallies: [UUID: SidebarLeadTally] = [:]
    var sidebarFamilyChips: [SidebarQuietInbox.FamilyChip] = []
    var historyEntryHelpers: [UUID: Int] = [:]
    var historyEntryDates: [UUID: Date] = [:]
    var quietHistoryCache: InboxQuietHistoryProjection?
    var historyProjectionBuilds = 0
    /// The spoken status of every incoming row (`statusAccessibilitySummary`).
    var statusSummaries: [UUID: String] = [:]
    /// The earliest moment a row's state wants a re-render (snooze end, a finished
    /// subagent folding away), measured at `input.now`.
    var wakeEarliest: Date?
    /// The scope menu's entries for `rows` and these inputs.
    var scopeMenu: (inputs: InboxScopeMenuInputs, entries: [InboxScopeMenuEntry])?
}

/// What the table draws for a push: filtered, sorted, folded, then split into the
/// three sections with the shelf header between the second and the third. The
/// derivation is the one `AgentInboxView.display(from:)` always made; only where
/// its inputs and outputs live has changed.
///
/// THE SECTIONS ARE COMPUTED LAST, on the rows that survived the group folds
/// (P2D.4). A shelf count taken before them would report a snoozed child that is
/// already hidden under its parent, and the header would say it is holding a row
/// that unfolding it does not produce.
nonisolated enum InboxDisplayBuilder {
    static func build(_ input: InboxDisplayInputs) -> InboxDisplayModel {
        var model = InboxDisplayModel()
        // Scans of every incoming row that only read the row: the host applies the
        // answers instead of walking 2,000+ rows on main.
        model.statusSummaries.reserveCapacity(input.rows.count)
        var wakeEarliest: Date?
        for row in input.rows {
            model.statusSummaries[row.id] = AgentInboxView.statusAccessibilitySummary(for: row)
            let wake: Date?
            if case .snoozed(let until) = row.lifecycle, until > input.now { wake = until }
            else { wake = InboxSort.subagentFoldsAt(row).flatMap { $0 > input.now ? $0 : nil } }
            if let wake, wakeEarliest.map({ wake < $0 }) ?? true { wakeEarliest = wake }
        }
        model.wakeEarliest = wakeEarliest
        if let menu = input.scopeMenu {
            model.scopeMenu = (menu, InboxScopeMenu.entries(
                scope: menu.scope, workspaces: menu.workspaces, projects: menu.projects,
                legacyWorkspaces: menu.legacyWorkspaces, rows: input.rows, current: menu.current,
                offersCurrent: menu.offersCurrent, offersThisMac: menu.offersThisMac))
        }
        // Sidebar round: Clear's marks, then Standing, both sidebar preferences
        // stamped on the rows. A mark new activity released is dropped.
        let cleared = SidebarClearMarks.apply(input.clearMarks, to: input.rows)
        model.releasedClearMarks = Array(cleared.released)
        let newRows = SidebarStandingLeads.apply(input.standingLeadIDs, to: cleared.rows)
        let hiddenKeys = input.hiddenKeys
        func isHidden(_ row: AgentInboxRow) -> Bool {
            row.externalSession.map { hiddenKeys.contains($0.sessionKey) } ?? false
        }
        let query = input.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let openAgentId = input.openAgentId
        // Decide orphanhood against the full input, before scope/search can
        // temporarily remove a real parent. Search remains the way to find a
        // finished helper whose lead was deleted or cannot be restored.
        let historyRows = InboxSort.promotingOrphansToRoots(InboxSort.excludingQuietOrphanedHelpers(
            rows: newRows, openAgentId: openAgentId, searching: !query.isEmpty))
        let sourced = historyRows.filter {
            $0.id == openAgentId || !input.hiddenSources.contains(InboxSource.key(for: $0))
        }
        let scopedWithHidden = InboxScope.filter(
            rows: sourced, scope: input.scope, openAgentId: openAgentId,
            currentWorkspace: input.currentWorkspaceName,
            currentWorkspaceId: input.currentWorkspaceId)
        // .plans/87: `Hidden (N)` counts what opening it would bring back here; open,
        // those rows are drawn in place, dimmed, each with Show.
        let hiddenHere = hiddenKeys.isEmpty ? [] : scopedWithHidden.filter(isHidden)
        model.hiddenInScopeCount = hiddenHere.count
        let hiddenRevealed = hiddenHere.isEmpty ? false : input.hiddenRevealed
        model.hiddenRevealed = hiddenRevealed
        model.revealedHiddenIds = hiddenRevealed ? Set(hiddenHere.map(\.id)) : []
        let scoped = hiddenRevealed || hiddenHere.isEmpty ? scopedWithHidden : scopedWithHidden.filter { !isHidden($0) }
        let searched = query.isEmpty ? scoped : scoped.filter { row in
            [row.title, row.projectName, row.workspaceName, row.model, row.branch, row.whereMarker?.text]
                .compactMap { $0?.localizedLowercase }
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || row.displayTitle.localizedCaseInsensitiveContains(query)
        }
        // .plans/113: under the pointer, rows already drawn keep their places.
        if input.heldOrder != nil { model.sortHoldPending = true }
        let sorted = InboxSort.sortForInbox(
            rows: searched, mode: input.sortMode, heldOrder: input.heldOrder)
        model.marksWorkspaces = Set(sorted.compactMap(\.workspaceId)).count > 1
        // P2D.4/P2D.5 must read the FULL sorted list. Capping or folding before
        // these derivations would make a hidden child's disclosure, rollup and
        // lifecycle blocker disappear together.
        let parentsWithChildren = InboxSort.parentIds(in: sorted)
        model.parentsWithChildren = parentsWithChildren
        model.ownershipAskByLead = AgentInboxView.asksByLead(in: sorted)
        var fullRollups = InboxSort.rollups(in: sorted)
        let bounded = InboxSort.boundedForInbox(
            rows: sorted, expandedParents: input.expandedFanoutParents, now: input.now)
        model.fanoutRemaindersByParent = bounded.remainderByParent
        // The capped fields are a presentation-only overlay on the full rollup.
        // `holdsParentOpen` and the lifecycle/action policy continue to read the
        // uncapped descendant tallies above, so a remainder cannot change resource
        // or settlement bookkeeping.
        for remainder in bounded.remainders where !remainder.isExpanded {
            guard var rollup = fullRollups[remainder.parentId] else { continue }
            let hidden = remainder.hiddenDescendantCount
            rollup = ChildRollup(
                children: rollup.children,
                working: rollup.working,
                needsYou: rollup.needsYou,
                failed: rollup.failed,
                unopenedFailed: rollup.unopenedFailed,
                cappedChildren: remainder.hiddenChildCount,
                cappedDescendants: hidden,
                cappedWorking: remainder.hiddenWorking,
                cappedNeedsYou: remainder.hiddenNeedsYou,
                cappedFailed: remainder.hiddenFailed)
            fullRollups[remainder.parentId] = rollup
        }
        model.rollupsByParent = fullRollups
        // Saved choices win. Production starts open; legacy fixtures may opt into automatic folding.
        func isFolded(_ parentId: UUID) -> Bool {
            if let open = input.foldChoices[parentId] { return !open }
            guard input.foldsUntouchedGroups else { return false }
            guard let rollup = fullRollups[parentId] else { return true }
            return rollup.needsYou == 0 && rollup.unopenedFailed == 0
        }
        let collapsedParents = Set(parentsWithChildren.filter(isFolded))
        model.collapsedParents = collapsedParents
        let visible = InboxSort.visibleRows(bounded.rows, collapsed: collapsedParents)
        let visibleIDs = Set(visible.map(\.id))
        updateSidebarCore(
            &model, input: input,
            liveRows: sorted.filter { $0.lifecycle == .active }, shownIDs: visibleIDs)
        // A fold can remove the model's original after-row without removing the
        // ancestor remainder it anchored. Re-anchor each still-visible parent's
        // affordance to the last row that remains visible in that parent's bounded
        // subtree. Iterating the model's ordered remainders preserves the nested
        // child-before-parent order when two affordances share that fallback row.
        var visibleRemaindersByAfterRow: [UUID: [FanoutRemainder]] = [:]
        for remainder in bounded.remainders {
            guard !collapsedParents.contains(remainder.parentId),
                  visibleIDs.contains(remainder.parentId),
                  let parentIndex = bounded.rows.firstIndex(where: {
                      $0.id == remainder.parentId
                  }) else { continue }
            let parentDepth = bounded.rows[parentIndex].depth
            let nextIndex = bounded.rows.index(after: parentIndex)
            let subtreeEnd = bounded.rows[nextIndex...].firstIndex(where: {
                $0.depth <= parentDepth
            }) ?? bounded.rows.endIndex
            guard let anchor = bounded.rows[parentIndex..<subtreeEnd].last(where: {
                visibleIDs.contains($0.id)
            }) else { continue }
            visibleRemaindersByAfterRow[anchor.id, default: []].append(remainder)
        }
        model.fanoutRemaindersByAfterRow = visibleRemaindersByAfterRow
        // P4.7. `now` is the view's `clock()`, the same injection point a parked
        // row's "in 25m" is read from, so a card whose snooze expires between two
        // renders cannot make a committed baseline flap.
        let now = input.now
        let parts = InboxSort.partition(rows: visible, now: now)
        // Sidebar round: the layout's head (incidents), then standing leads (no heading: the list
        // is a queue) with their families, then everything else in the sort's order.
        var standingRows: [AgentInboxRow] = []
        var otherRows: [AgentInboxRow] = []
        var inStanding = false
        for row in parts.active {
            if row.depth == 0 { inStanding = row.isStanding }
            if inStanding { standingRows.append(row) } else { otherRows.append(row) }
        }
        var built = sidebarHeadItems(model: model, input: input)
        if !standingRows.isEmpty {
            built.append(contentsOf: agentItems(for: standingRows, model: model))
        }
        built.append(contentsOf: input.sortMode == .byProject
            ? projectGroupedItems(for: otherRows, model: model)
            : agentItems(for: otherRows, model: model))
        built = withFamilyCauseLines(built, model: model, input: input)
        // NO HEADER FOR AN EMPTY SHELF: "Snoozed (0)" is a line of chrome about
        // nothing, and it would take a row's worth of a 320pt sidebar to say it.
        if parts.shelfCount > 0 {
            built.append(.shelfHeader(count: parts.shelfCount, isExpanded: input.shelfExpanded))
            if input.shelfExpanded {
                built.append(contentsOf: agentItems(for: parts.snoozed, model: model))
            }
        }
        // P4.8: history is PAGED, and the page is taken last — on the rows that
        // survived the scope, the folds and the section split, so the footer's count
        // is of rows that pressing it really does produce.
        // Decisions pass, "one history shelf": settled agents and agents closed to
        // History are ONE section. In the app it is a collapsed, counted shelf at
        // the BOTTOM — a spacer row takes whatever height the live list leaves —
        // paged inside once it is open. The open agent is drawn even inside a
        // shut shelf, the rule the paged tail already kept.
        if !input.foldsHistoryIntoShelf {
            let page = InboxSort.pageSettled(
                parts.history, limit: input.settledLimit, openAgentId: openAgentId)
            built.append(contentsOf: agentItems(for: page.shown, model: model))
            if page.hasMore {
                built.append(.settledMore(hidden: page.hidden))
            }
        } else if parts.historyCount > 0 {
            // Quiet inbox: History counts families, the cards it draws, not
            // helpers, and leaves out agents opened and never used.
            let quiet = input.sidebarLayout == .quietInbox
            let projection = quiet
                ? quietHistoryProjection(
                    parts.history, all: sorted, searching: !query.isEmpty, now: now,
                    model: &model, input: input)
                : nil
            let historyCount = projection?.families.count ?? parts.historyCount
            if let projection {
                model.historyEntryHelpers = projection.helpers
                model.historyEntryDates = projection.dates
            }
            if historyCount > 0 {
                built.append(.historyHeader(count: historyCount, isExpanded: input.historyExpanded))
                if input.historyExpanded {
                    // Quiet pages the family cards and force-includes the focused
                    // agent's family using the same rule as an ordinary open row.
                    let page = InboxSort.pageSettled(
                        projection?.families ?? parts.history, limit: input.settledLimit,
                        openAgentId: projection == nil ? openAgentId : projection?.openFamilyId)
                    built.append(contentsOf: quiet
                        ? page.shown.map(InboxListItem.agent)
                        : agentItems(for: page.shown, model: model))
                    if page.hasMore {
                        built.append(.settledMore(hidden: page.hidden))
                    }
                } else if let open = parts.history.first(where: { $0.id == openAgentId }) {
                    built.append(.agent(open))
                }
            }
        }
        if input.foldsHistoryIntoShelf, let firstShelf = built.firstIndex(where: \.isShelfHeading) {
            built.insert(.shelfSpacer, at: firstShelf)
        }
        // Quiet inbox: the History footnote, under the shelf Clear fills.
        if input.sidebarLayout == .quietInbox, parts.historyCount > 0 || !model.sidebarClearIDs.isEmpty {
            built.append(.sectionLabel(SidebarSectionLabel(
                kind: .historyNote, title: input.quietHistoryNote, count: nil, clearCount: 0)))
        }
        model.items = built
        return model
    }

    /// Recompute the shared core over the rows the list is drawing.
    private static func updateSidebarCore(
        _ model: inout InboxDisplayModel, input: InboxDisplayInputs,
        liveRows: [AgentInboxRow], shownIDs: Set<UUID>
    ) {
        model.sidebarClearIDs = SidebarClear.eligibleIDs(rows: liveRows, standing: input.standingLeadIDs)
        model.sidebarIncidents = SidebarIncidentDismissals.visible(
            SidebarIncidents.build(rows: liveRows), dismissed: input.dismissedIncidents, rows: liveRows)
        var tallies: [UUID: SidebarLeadTally] = [:]
        for lead in liveRows where lead.depth == 0 && model.parentsWithChildren.contains(lead.id) {
            tallies[lead.id] = SidebarLeadTally.tally(leadId: lead.id, rows: liveRows, shownIDs: shownIDs)
        }
        model.sidebarTallies = tallies
        model.sidebarFamilyChips = input.sidebarLayout == .quietInbox
            ? SidebarQuietInbox.familyChips(rows: liveRows) : []
    }

    /// The Ledger's head: "For you" (blocking incidents, one line each) and
    /// "Other updates" grouped by cause, with Clear N on the first heading. No
    /// heading is drawn for nothing; the Quiet inbox draws its own head.
    private static func sidebarHeadItems(model: InboxDisplayModel, input: InboxDisplayInputs) -> [InboxListItem] {
        guard input.sidebarLayout == .ledger else { return quietInboxHead(model: model) }
        let blocking = model.sidebarIncidents.filter(\.isBlocking)
        let updates = model.sidebarIncidents.filter { !$0.isBlocking }
        var clear = model.sidebarClearIDs.count
        var result: [InboxListItem] = []
        if !blocking.isEmpty {
            result.append(.sectionLabel(SidebarSectionLabel(
                kind: .forYou, title: "For you", count: blocking.count, clearCount: clear)))
            clear = 0
            result.append(contentsOf: blocking.map(InboxListItem.incident))
        }
        if !updates.isEmpty || clear > 0 {
            result.append(.sectionLabel(SidebarSectionLabel(
                kind: .otherUpdates, title: updates.isEmpty ? "Updates" : "Other updates",
                count: nil, clearCount: clear)))
            result.append(contentsOf: updates.map(InboxListItem.incident))
        }
        return result
    }

    /// The Quiet inbox's head, from the core's per-render facts.
    private static func quietInboxHead(model: InboxDisplayModel) -> [InboxListItem] {
        let blocking = SidebarQuietInbox.needsYou(model.sidebarIncidents)
        let clear = model.sidebarClearIDs.count
        guard clear > 0 || !blocking.isEmpty else { return [] }
        var items: [InboxListItem] = [.sectionLabel(SidebarSectionLabel(
            kind: .inbox, title: "Inbox", count: nil, clearCount: clear))]
        // A family's cause is said inside its own card, never stacked here.
        if !blocking.isEmpty { items.append(.quietNeedsYou(blocking)) }
        return items
    }

    /// Quiet inbox: each family's one cause line, placed right after its lead's
    /// own row so it draws inside that card. Any other layout, or a lead not in
    /// the list, adds nothing.
    private static func withFamilyCauseLines(
        _ items: [InboxListItem], model: InboxDisplayModel, input: InboxDisplayInputs
    ) -> [InboxListItem] {
        guard input.sidebarLayout == .quietInbox else { return items }
        var byLead: [UUID: SidebarIncident] = [:]
        for chip in model.sidebarFamilyChips where AgentInboxView.causeLineText(chip.incident) != nil {
            byLead[chip.familyId] = chip.incident
        }
        var result: [InboxListItem] = []
        result.reserveCapacity(items.count + byLead.count + model.sidebarTallies.count)
        for item in items {
            result.append(item)
            // A folded lead is a one-row card: its count stays on line 2.
            guard case .agent(let row) = item, row.depth == 0, !model.collapsedParents.contains(row.id) else { continue }
            // A's line 3: the lead's count, its own line under the lead.
            if row.lifecycle == .active, let tally = model.sidebarTallies[row.id], tally.total > 0 {
                result.append(.leadCount(tally))
            }
            if let incident = byLead[row.id] { result.append(.familyCause(incident, leadId: row.id)) }
        }
        return result
    }

    /// The live block in `By project`: a heading over each project's run of
    /// top-level agents, which `InboxSort` already placed together. A subagent
    /// stays with its lead, whatever project it is in. The count is the leads.
    private static func projectGroupedItems(for sectionRows: [AgentInboxRow], model: InboxDisplayModel) -> [InboxListItem] {
        var runs: [(title: String, rows: [AgentInboxRow])] = []
        var currentKey: String?? = .none
        for row in sectionRows {
            if row.depth == 0 {
                let key = InboxSort.projectGroupName(for: row)
                if currentKey != .some(key) || runs.isEmpty {
                    runs.append((key ?? InboxSort.noProjectTitle, []))
                    currentKey = .some(key)
                }
            } else if runs.isEmpty {
                runs.append((InboxSort.noProjectTitle, []))
            }
            runs[runs.count - 1].rows.append(row)
        }
        var result: [InboxListItem] = []
        for run in runs {
            result.append(.projectHeading(title: run.title, count: run.rows.filter { $0.depth == 0 }.count))
            result.append(contentsOf: agentItems(for: run.rows, model: model))
        }
        return result
    }

    /// Turn a section's agent rows into table items, inserting each remainder
    /// after the visible end of its live parent's subtree.
    private static func agentItems(for sectionRows: [AgentInboxRow], model: InboxDisplayModel) -> [InboxListItem] {
        var result: [InboxListItem] = []
        for row in sectionRows {
            result.append(.agent(row))
            guard let remainders = model.fanoutRemaindersByAfterRow[row.id] else { continue }
            result.append(contentsOf: remainders.map(InboxListItem.fanoutRemainder))
        }
        return result
    }

    /// Quiet inbox History: one card per family, its lead only, newest first by
    /// the family's last real turn (the latest prompt or turn start across
    /// the lead and its helpers).
    /// Each card says how many helpers it holds and that same date
    /// ("4 helpers · Nov 10"). Paging takes this order, so a page never
    /// interleaves older families.
    private static func quietHistoryProjection(
        _ history: [AgentInboxRow], all: [AgentInboxRow], searching: Bool, now: Date,
        model: inout InboxDisplayModel, input: InboxDisplayInputs
    ) -> InboxQuietHistoryProjection {
        let openAgentId = input.openAgentId
        // Chatter outside History can reuse the last projection when the same
        // History rows still match. Check their IDs before walking the families.
        if let cache = input.quietHistoryCache, let touched = input.historyReuseHint,
           cache.searching == searching, cache.openAgentId == openAgentId,
           cache.historyIDs.count == history.count,
           touched.isDisjoint(with: cache.members),
           history.allSatisfy({ cache.historyIDs.contains($0.id) }) {
            model.quietHistoryCache = cache
            return cache
        }
        model.historyProjectionBuilds += 1
        let historyIDs = Set(history.map(\.id))
        var childrenOf: [UUID: [AgentInboxRow]] = [:]
        for row in all { if let parent = row.parentId, parent != row.id { childrenOf[parent, default: []].append(row) } }
        let roots = history.filter { $0.parentId.map { !historyIDs.contains($0) } ?? true }
        let openFamilyId: UUID? = {
            guard let openAgentId else { return nil }
            let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard var current = byId[openAgentId],
                  InboxSort.section(for: current.lifecycle, now: now) == .history else { return nil }
            let rootIDs = Set(roots.map(\.id))
            var visited: Set<UUID> = []
            // A folded or capped helper may be absent from History's visible rows.
            // Walk the full ancestry to the closest root that actually draws a card.
            while visited.insert(current.id).inserted {
                if rootIDs.contains(current.id) { return current.id }
                guard let parentId = current.parentId, let parent = byId[parentId] else { break }
                current = parent
            }
            return nil
        }()
        var dated: [(row: AgentInboxRow, at: Date, index: Int)] = []
        var members: Set<UUID> = historyIDs
        var helpers: [UUID: Int] = [:]
        var dates: [UUID: Date] = [:]
        for (index, root) in roots.enumerated() {
            var seen: Set<UUID> = [root.id]
            // The last REAL turn (a prompt or a turn start) across the family.
            // A relaunch restamps every helper's activity and run-completed time;
            // interrupts, Clear, archive and read marks move other stamps; a helper
            // opened and never used has only its creation. None of them is work, so
            // the creation date is a fallback only when no member ever had a turn.
            var latestTurn = root.lastTurnAt
            // Opened and never used (no member ever had a turn or an outcome):
            // nothing happened there, so it is not History. Search still finds
            // it, and the open agent always draws.
            var used = root.lastTurnAt != nil || root.terminalEvent != nil
            var stack = childrenOf[root.id] ?? []
            while let next = stack.popLast() {
                guard seen.insert(next.id).inserted else { continue }
                if let turn = next.lastTurnAt { latestTurn = max(latestTurn ?? turn, turn) }
                if next.lastTurnAt != nil || next.terminalEvent != nil { used = true }
                stack.append(contentsOf: childrenOf[next.id] ?? [])
            }
            members.formUnion(seen)
            guard used || searching || root.id == openFamilyId else { continue }
            let at = latestTurn ?? root.createdAt
            helpers[root.id] = seen.count - 1
            dates[root.id] = at
            dated.append((root, at, index))
        }
        let families = dated.sorted { $0.at != $1.at ? $0.at > $1.at : $0.index < $1.index }.map(\.row)
        let projection = InboxQuietHistoryProjection(
            historyIDs: historyIDs, members: members, searching: searching, openAgentId: openAgentId,
            openFamilyId: openFamilyId, families: families, helpers: helpers, dates: dates)
        model.quietHistoryCache = projection
        return projection
    }
}

/// The newest request number, readable from the queue and from main.
final class InboxDisplayLatest: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// Runs one build on the serial queue, skipping it when a newer request has
/// already been made, and hands the answer to main.
nonisolated enum InboxDisplayHandoff {
    static func run(
        _ inputs: InboxDisplayInputs, generation: Int, latest: InboxDisplayLatest, queue: DispatchQueue,
        deliver: @escaping @MainActor (InboxDisplayModel) -> Void
    ) {
        queue.async {
            guard latest.current == generation else { return }
            let model = InboxDisplayBuilder.build(inputs)
            guard latest.current == generation else { return }
            let box = UncheckedModel(model)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(box.model) } }
        }
    }
}

private struct UncheckedModel: @unchecked Sendable {
    let model: InboxDisplayModel
    init(_ model: InboxDisplayModel) { self.model = model }
}
