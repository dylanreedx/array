import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.6-inbox-list-view.md
//
// THE INBOX, PAINTED. Everything above this file is a pure value: P3.1's row,
// P3.2's five states and three colours, P3.3's attention axis, P3.4's frozen
// order, P3.5's emphasis. Nothing rendered any of it — `RowEmphasis` says so in
// its own doc comment ("NOTHING PAINTS THIS YET … the packet's second file is
// the list view (P3.6), which does not exist"). This is that view, and it is
// deliberately DUMB: it takes `[AgentInboxRow]` and paints it. It derives no
// status, sorts by nothing of its own, and holds no model beyond the rows it was
// last handed.
//
// The one thing it does compute is the elapsed STRING, because "4m" is a
// rendering of `TimeInterval` and not a fact about an agent.
//
// P3.5's THREE OBLIGATIONS, discharged here and named so a reviewer can find
// them: `textOpacity` is applied to the TEXT FIELDS and never to a container the
// accent is inside (see `AgentInboxCellView.apply`), `accentOpacity` paints the
// state label at full strength however far the row recedes, and hover /
// selection / keyboard-active are passed into
// `AgentInboxRow.emphasis(for:attention:isInteracting:)` rather than guessed
// (see `isInteracting(row:)`).
//
// WHY `NSTableView` AND NOT `NSOutlineView`. The sidebar tree is an outline
// because workspace ▸ zone ▸ tile is a real hierarchy you expand and collapse.
// The inbox is a FLAT ARRAY that draws a hierarchy: `InboxSort` already places a
// child immediately after its parent and stamps its depth, so the order and the
// indent an outline would compute are things the array already carries — an
// `NSOutlineView` would want to own that tree, and it owns row height and
// selection differently too (P3.7's two variants and P3.5's emphasis are wired
// against a table).
//
// P2D.4 ADDS THE DISCLOSURE, and it is the one thing this file holds that is not
// in the row: which parents you have folded. That is local UI state — not
// persisted and never synced, because which groups you collapsed on this Mac is
// not a fact about the agents (the packet says so in as many words). Folding a
// group DOES hide a child that is asking for approval; the earlier note here
// claimed a child is never hidden, and this ticket overrules it — a fold is
// something you did, and P3.6's own frozen-order argument applies: the list moves
// when you act. Nothing folds a group on your behalf.

@MainActor
final class AgentInboxView: NSView, NSTableViewDataSource, NSTableViewDelegate, TokenThemed {
    /// The row card's height, DERIVED from the type it holds rather than the
    /// packet's "≈78pt": one `.title` line for the name and two `.label` lines
    /// for the metadata, the two gaps between them, and the card's own padding.
    /// Comes out at 79pt, which is what the packet was approximating — and a
    /// P1.4 size move now grows the row instead of clipping it.
    static var rowHeight: Double {
        Metrics.lineHeight(for: .title)
            + 2 * Metrics.lineHeight(for: .label)
            + 2 * Space.s
            + Inset.card.vertical
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
    /// A PARKED row's height: one `.title` line in a row inset — 35pt, which is
    /// the "~36pt" the packet approximates. Derived exactly like `rowHeight`, so
    /// a P1.4 size move moves both instead of clipping one.
    static var slimRowHeight: Double { Metrics.rowHeight(for: .title, insets: Inset.row) }

    /// The height a row of this variant gets. The two numbers are far enough apart
    /// (79 vs 35) that the collapse is the visible fact it is meant to be, and the
    /// gap is asserted rather than left to the two derivations happening to differ.
    static func height(for variant: RowVariant) -> Double {
        switch variant {
        case .card: return rowHeight
        case .slim: return slimRowHeight
        }
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// The room the scope control takes off the top of the list: the popup's own
    /// intrinsic height plus the gap above and below it.
    ///
    /// MEASURED off a popup, not typed as a number — the control's height comes from
    /// its font (`.token(.label)`), so a P1.4 size move grows this instead of
    /// clipping the control. It is public to this file's callers because the Lab
    /// cards and the appearance sweep size themselves around the LIST, and a
    /// hardcoded 32 there would cut a row in half the day the type scale moves. The
    /// laid-out height is this same intrinsic height: the popup is pinned by its top
    /// and its leading edge only, so nothing stretches it.
    static var scopeControlHeight: Double {
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.font = .token(.label)
        probe.addItem(withTitle: InboxScope.allTitle)
        return (2 * Space.s + Double(probe.fittingSize.height)).rounded(.up)
    }

    /// How far one nesting level indents a child row (P2D.4 draws the nesting;
    /// this is only the step). `Space.xl`, so an indented card is still visibly a
    /// card rather than a hairline shift.
    static let indentPerLevel = Space.xl

    /// Shown when there is nothing to show. A list that renders as an empty
    /// rectangle reads as broken; it also renders as a uniform fill, which the
    /// phase-0 blankness floor is right to call a failure.
    static let emptyMessage = "No agents yet"

    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// Shown when the list HAS agents and the scope hides all of them. A second
    /// message rather than one, because "No agents yet" in front of seven agents you
    /// filtered out is a lie the empty state would be telling — and the useful next
    /// move (widen the scope) is only obvious if the message names the cause.
    static let scopedEmptyMessage = "No agents in this scope"

    private let scopePopUp: NSPopUpButton
    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let column: NSTableColumn
    private let emptyLabel: NSTextField

    /// The rows as they are drawn — already through the scope filter (P3.8) and
    /// `InboxSort.sortForInbox`, so index N here is row N on screen and every
    /// accessor below can be an index.
    private(set) var rows: [AgentInboxRow] = []
    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// Every row the list was HANDED, unfiltered and unsorted. Held because the
    /// scope is a view-local control: flipping it must re-filter the same push
    /// rather than wait for the next agent event, and the popup's own menu is
    /// derived from the projects and workspaces the whole list mentions — not from
    /// the ones that survived the current scope, which would make every scope but
    /// `.all` a one-way door.
    private var allRows: [AgentInboxRow] = []
    /// The entries in the popup, parallel to the menu items' tags.
    private var scopeEntries: [InboxScope] = []
    // Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
    /// The parents you have folded. VIEW-LOCAL: no defaults key, nothing in the
    /// change set, nothing on the row — collapsing a group is a thing you did to
    /// this list on this Mac, and a synced fold would hide an agent on a device
    /// you were not looking at.
    ///
    /// Ids are kept even when their agent leaves the list (a scope change, a settle)
    /// so that coming back re-collapses the group the way you left it.
    private var collapsedParents: Set<UUID> = []
    /// The rows that HAVE a child on screen, from the sorted list before it was
    /// collapsed — a folded parent must keep the triangle you fold it back with.
    private var parentsWithChildren: Set<UUID> = []
    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// Whether the ⌘-hold hint pills are showing. VIEW-LOCAL and transient, like
    /// hover: it is a fact about the modifier you are holding right now.
    private var jumpHintsVisible = false
    /// The row the mouse is over, or -1. Hover is one of P3.5's three
    /// interaction facts and it is tracked HERE, on the table, rather than per
    /// cell: cell views are recycled, so a tracking area installed on one would
    /// follow it onto a different row.
    private var hoveredRow = -1
    /// The selection as the cells were last painted for it. `selectionDidChange`
    /// reports the NEW selection only, so the row that just lost it — the one that
    /// has to start receding again — has to be remembered.
    private var selectedRowForEmphasis = -1
    private var trackingArea: NSTrackingArea?

    /// The cell currently drawn for each row index, and how many cells this view
    /// has built in total. Together they are the witness for "do not full-reload on
    /// every event" (P2B.7): an incremental apply must build the cells of the
    /// touched rows and no others.
    ///
    /// The QA accessors read this map rather than asking the table for a view with
    /// `makeIfNecessary: true`, which would BUILD one and inflate the very count
    /// the witness is measuring.
    private var cellsByRow: [Int: AgentInboxRowCell] = [:]
    private(set) var cellBuildCountForQA = 0

    // Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
    /// The clock a parked row's relative time is read from ("12m ago", "in 2h").
    ///
    /// A closure so a live list ages as the app runs, and an injection point so a
    /// committed baseline cannot flap: a Lab card rendering a wall-clock relative
    /// time would match its PNG for one minute and fail for the rest of the hour.
    /// Nothing else in this view reads a clock — a card row's elapsed time is a
    /// number the ROW carries, computed against the caller's `now` by
    /// `AgentInboxRowBuilder`.
    var clock: () -> Date = Date.init

    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// Which agents the list is showing. `.all` at birth and NOT read from
    /// `UserDefaults` here: this view is rendered by three committed Lab baselines,
    /// and a view that resolved a persisted default in its initialiser would make
    /// those PNGs depend on the defaults of whoever ran the check. Persistence is
    /// wired where the sidebar's other two settings are wired (`ContinuumApp`,
    /// `WorkspaceSidebarConfig`), through `setScope` and `onScopeChange`.
    private(set) var scope: InboxScope = .all
    /// Told, never guessed: the user picked a scope from the popup. The host
    /// persists it. Not called for a programmatic `setScope` — restoring a scope at
    /// launch must not write the value back.
    var onScopeChange: ((InboxScope) -> Void)?
    // Ticket: docs/38-tickets/90-agent-ux/P3.9-reveal-on-click.md
    /// Clicking a row asks the host to take you to that agent. The list holds NO
    /// navigation of its own — it hands over the row's aggregate id and the host
    /// (which is the only thing that knows about workspaces, tiles and the
    /// supervisor) does the rest.
    ///
    /// A CLICK, not a selection change: keyboard navigation through an
    /// `NSTableView` IS a selection move (see `isInteracting`), so revealing on
    /// selection would switch workspaces under every arrow key. Arrow-key
    /// navigation is P3.10's ticket and gets its own decision.
    var onRevealRow: ((UUID) -> Void)?
    /// The agent open in the focused tile, force-included whatever the scope says
    /// (`InboxScope.filter`). Set by the host on every push; a change re-filters,
    /// and an unchanged value does no work, so this cannot cost the incremental
    /// refresh (P2B.7) its "one cell rebuilt".
    var openAgentId: UUID? {
        didSet {
            guard openAgentId != oldValue else { return }
            reload(rows: allRows)
        }
    }
    /// Every project and workspace that is OPEN, from the host's registry. The menu
    /// is the union of these and what the rows mention, so a project you have open
    /// with no agent in it is still a scope you can pick — see `InboxScope.entries`.
    /// It changes only when the registry does, so it re-menus and does not re-filter.
    var scopeCatalog: [InboxScope] = [] {
        didSet {
            guard scopeCatalog != oldValue else { return }
            updateScopeMenu()
        }
    }

    override init(frame frameRect: NSRect) {
        // A popup, not a segmented control or a row of chips: the entry count is
        // the number of projects and workspaces you have open, so anything that
        // lays its choices out side by side puts the sidebar's width back under the
        // control of your project names — which is the exact coupling this ticket
        // removes from group headers.
        scopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        scopePopUp.font = .token(.label)
        scopePopUp.translatesAutoresizingMaskIntoConstraints = false
        // Lets the popup shrink with a narrow sidebar rather than force the whole
        // view wider than the split-view divider allows.
        scopePopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView(frame: .zero)
        tableView.headerView = nil
        // `.plain`, not the sidebar's `.sourceList`: a source list draws its own
        // rounded selection capsule and its own row insets, which would sit
        // underneath the card this view paints and give every selected row two
        // overlapping shapes. Selection is drawn by `AgentInboxRowView` instead,
        // from tokens.
        tableView.style = .plain
        tableView.rowHeight = AgentInboxView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Space.s)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.translatesAutoresizingMaskIntoConstraints = false

        column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent-inbox-row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyLabel = NSTextField(labelWithString: AgentInboxView.emptyMessage)
        emptyLabel.font = .token(.label)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        wantsLayer = true
        applyTokens()
        setAccessibilityIdentifier("ContinuumAgentInboxRoot")
        tableView.setAccessibilityIdentifier("ContinuumAgentInboxList")
        emptyLabel.setAccessibilityIdentifier("ContinuumAgentInboxEmpty")
        scopePopUp.setAccessibilityIdentifier("ContinuumAgentInboxScope")

        addSubview(scopePopUp)
        addSubview(scrollView)
        addSubview(emptyLabel)

        tableView.dataSource = self
        tableView.delegate = self
        // P3.9: the table's own single-click action. `clickedRow` is -1 for a click
        // in the empty space below the rows, which `reveal(rowAt:)` drops.
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        scopePopUp.target = self
        scopePopUp.action = #selector(scopePicked(_:))
        updateScopeMenu()

        NSLayoutConstraint.activate([
            scopePopUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.m),
            scopePopUp.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Space.m),
            scopePopUp.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: scopePopUp.bottomAnchor, constant: Space.s),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.l),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.l),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Space.l),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    /// This view's own fill and the empty-state text — and DELIBERATELY NOT a
    /// `reloadData()`, which is what `WorkspaceSidebarView.applyTokens` does for
    /// its outline.
    ///
    /// Reloading here would destroy every row and cell view while the appearance
    /// is mid-flip, so `UIProbeAppearance`'s sentinel would survive on the layers
    /// of the discarded rows — and it did, on all 21 of them, the first time this
    /// view was swept. The rows re-theme themselves instead:
    /// `AgentInboxRowView.applyTokens` for the card and
    /// `AgentInboxCellView.viewDidChangeEffectiveAppearance` for the words, each
    /// on the view that owns the colour.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        emptyLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    // MARK: - Input

    /// Replace the list. Sorting is NOT the caller's to do: `InboxSort` owns the
    /// frozen desktop order (P3.4) and applying it here is what makes "row N on
    /// screen" and "rows[N]" the same thing for every accessor below.
    func reload(rows newRows: [AgentInboxRow]) {
        allRows = newRows
        updateScopeMenu()
        render(visibleRows(from: newRows))
    }

    /// Draw this list whole. Takes rows that are ALREADY filtered and sorted, which
    /// is why it is private: `reload(rows:)` is the entry point for a fresh push and
    /// takes the unfiltered set, and handing it an already-filtered list would make
    /// the scope narrow itself with every call.
    private func render(_ visible: [AgentInboxRow]) {
        rows = visible
        cellsByRow.removeAll()
        tableView.reloadData()
        updateEmptyState()
    }

    /// Apply a new set of rows knowing WHICH agents moved (P2B.7's change set).
    ///
    /// A full `reloadData()` on every streamed event is the jumpiness P2B.7
    /// removed from the surfaces it could reach; the sidebar tree was left out of
    /// it explicitly ("`WorkspaceSidebarView` still reloads whole — rewriting it
    /// is Phase 3's ticket"). This is that rewrite.
    ///
    /// The identity sequence decides: if the rows on screen are the same agents in
    /// the same order, only the ones that moved are rebuilt. If an agent appeared,
    /// vanished or moved, the LIST changed and a full reload is the honest answer —
    /// a partial reload against a shifted array would repaint row 3 with row 4's
    /// agent.
    ///
    /// "Moved" is the UNION of two facts, and the second is not optional. The change
    /// set is about ACTIVITY, and half of what a row shows is not activity: the
    /// project and zone it is joined to, its branch, its role and model, and the
    /// desktop-local read-state (P3.3) all change without any agent event, and a
    /// rename would arrive with `changed` empty. So a row is also stale when its
    /// VALUE differs from the one currently drawn — which `AgentInboxRow` being
    /// `Equatable` makes exact rather than a guess. (Found in cross-review; the
    /// change-set-only version showed a stale project name after a rename.)
    func apply(rows newRows: [AgentInboxRow], changed: AgentsBoardChangeSet) {
        // P3.8: the SCOPE decides what is on screen, so the diff is against the
        // filtered list — an agent that arrived in a project you are not scoped to
        // has not changed this list at all. `allRows` and the popup's menu are
        // updated either way, so a new project appears in the dropdown on the push
        // that first mentions it.
        allRows = newRows
        updateScopeMenu()
        // P2D.4: the disclosure is VIEW state, so it is not in `AgentInboxRow` and
        // the value comparison below cannot see it move. A first child arriving under
        // a folded parent — or the last one leaving — changes nothing visible about
        // the parent's row and everything about its triangle, so the rows whose
        // control appeared or vanished are stale too. (Found in cross-review.)
        let previousParents = parentsWithChildren
        let sorted = visibleRows(from: newRows)
        guard sorted.map(\.id) == rows.map(\.id) else {
            render(sorted)
            return
        }
        let disclosureMoved = previousParents.symmetricDifference(parentsWithChildren)
        let previous = rows
        rows = sorted
        let indexes = IndexSet(rows.indices.filter {
            changed.touched.contains(rows[$0].id) || rows[$0] != previous[$0]
                || disclosureMoved.contains(rows[$0].id)
        })
        guard !indexes.isEmpty else { return }
        // P3.7: a lifecycle move changes the row's VARIANT, and a variant is a
        // different height. `reloadData(forRowIndexes:)` re-asks for the row's VIEW
        // and not for its height, so without this a row that just settled would
        // draw its one collapsed line into a card-sized slot — and keep the slot.
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Scope (P3.8)

    /// The rows this scope leaves on screen, in the frozen order. Filter FIRST, then
    /// sort: the two commute (filtering a permutation and permuting a subset give the
    /// same list), and this way `InboxSort` only ever nests the children it can see.
    private func visibleRows(from newRows: [AgentInboxRow]) -> [AgentInboxRow] {
        let sorted = InboxSort.sortForInbox(
            rows: InboxScope.filter(rows: newRows, scope: scope, openAgentId: openAgentId))
        // P2D.4: measured on the SORTED list, before the fold — a collapsed parent
        // has no children on screen, and a triangle derived from what is on screen
        // would vanish the moment you used it.
        parentsWithChildren = InboxSort.parentIds(in: sorted)
        return InboxSort.visibleRows(sorted, collapsed: collapsedParents)
    }

    // MARK: - Nesting (P2D.4)

    /// Fold or unfold one parent's children.
    ///
    /// A FULL RE-RENDER, not an incremental apply: folding removes rows, so the
    /// identity sequence changed and `apply(rows:changed:)`'s own rule ("if an agent
    /// appeared, vanished or moved, the LIST changed and a full reload is the honest
    /// answer") applies. Selection and hover are dropped for the same reason
    /// `setScope` drops them — their indexes belong to the list that just went away,
    /// and a bulk action (P3.11) must never reach a row you cannot see.
    func toggleCollapse(parentId: UUID) {
        if collapsedParents.contains(parentId) {
            collapsedParents.remove(parentId)
        } else {
            collapsedParents.insert(parentId)
        }
        tableView.deselectAll(nil)
        selectedRowForEmphasis = -1
        hoveredRow = -1
        render(visibleRows(from: allRows))
    }

    /// Which control a row draws, if any: only a parent with children in this list
    /// gets one, and it says which way it is pointing.
    private func disclosure(for row: AgentInboxRow) -> RowDisclosure {
        guard parentsWithChildren.contains(row.id) else { return .none }
        return collapsedParents.contains(row.id) ? .collapsed : .expanded
    }

    /// Change the scope. `notify: false` for a restore at launch — the host is
    /// TELLING the view what was persisted, and calling back would write it again.
    ///
    /// THE SELECTION IS CLEARED, always, and this is the ticket's one hard rule:
    /// a bulk action (P3.11) must never reach a row you cannot see. Today the table
    /// is single-select, so "the multi-selection" is one row — clearing it here is
    /// what makes the rule structural before the multi-select lands, instead of a
    /// thing P3.11 has to remember. Hover is dropped for the mechanical reason too:
    /// the indexes it was recorded against belong to the previous list.
    ///
    /// MEASURED, so the next reader does not have to guess: `reloadData()` below
    /// already empties `selectedRowIndexes` on this table — deleting this line leaves
    /// the check green (probed over four scope flips, including one where the row
    /// count grows). It stays because the rule must not rest on that AppKit
    /// behaviour: P3.11 adds multi-select and P4.12 a crossfade, and either could
    /// reasonably start restoring selection across a reload. The assertion that has
    /// teeth is the other direction — an implementation that re-selects the agent
    /// after the flip goes red, which is the witness quoted at
    /// `runAgentInboxChecks`.
    func setScope(_ next: InboxScope, notify: Bool = false) {
        guard next != scope else { return }
        scope = next
        tableView.deselectAll(nil)
        selectedRowForEmphasis = -1
        hoveredRow = -1
        updateScopeMenu()
        render(visibleRows(from: allRows))
        if notify { onScopeChange?(next) }
    }

    @objc private func scopePicked(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, scopeEntries.indices.contains(tag) else { return }
        setScope(scopeEntries[tag], notify: true)
    }

    /// Rebuild the popup's menu when the set of scopes changed, and point it at the
    /// current one either way.
    ///
    /// AN `NSMenu` BUILT BY HAND, not `addItem(withTitle:)`: that method REMOVES an
    /// existing item with the same title, so a workspace and a project that share a
    /// name — the common case, since a one-project workspace is usually named after
    /// it — would collapse to a single entry and every index after it would point at
    /// the wrong scope. The tag carries the index instead of the position, so the
    /// separator between the two blocks costs nothing.
    private func updateScopeMenu() {
        let entries = InboxScope.entries(for: allRows, catalog: scopeCatalog, including: scope)
        if entries != scopeEntries {
            scopeEntries = entries
            let menu = NSMenu()
            for (index, entry) in entries.enumerated() {
                if index > 0, case .workspace = entry, case .project = entries[index - 1] {
                    menu.addItem(.separator())
                }
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.tag = index
                menu.addItem(item)
            }
            scopePopUp.menu = menu
        }
        if let index = scopeEntries.firstIndex(of: scope) {
            scopePopUp.selectItem(withTag: index)
        }
    }

    /// The empty state, and WHICH empty state. An inbox with agents in it that are
    /// all filtered out is not empty, and saying "No agents yet" there would be the
    /// list lying about the thing the user just did.
    private func updateEmptyState() {
        emptyLabel.stringValue = allRows.isEmpty
            ? AgentInboxView.emptyMessage
            : AgentInboxView.scopedEmptyMessage
        emptyLabel.isHidden = !rows.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// P3.7: settled and snoozed collapse, everything else is a full card. The
    /// height is asked of the ROW's variant and of nothing else — the list may not
    /// decide a `ready` or `failed` agent has earned less room, which is the
    /// density mistake the rule exists to forbid.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return AgentInboxView.rowHeight }
        return AgentInboxView.height(for: rows[row].variant)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        cellBuildCountForQA += 1
        let model = rows[row]
        let interacting = isInteracting(row: row)
        let cell: AgentInboxRowCell
        switch model.variant {
        case .card: cell = AgentInboxCellView()
        case .slim: cell = AgentInboxSlimCellView()
        }
        cell.identifier = NSUserInterfaceItemIdentifier(AgentInboxView.accessibilityIdentifier(for: model))
        cell.setAccessibilityIdentifier(AgentInboxView.accessibilityIdentifier(for: model))
        let agentId = model.id
        cell.onToggleDisclosure = { [weak self] in self?.toggleCollapse(parentId: agentId) }
        cell.apply(
            model,
            emphasis: AgentInboxRow.emphasis(
                for: model.state, attention: model.attention, isInteracting: interacting
            ),
            indent: Double(max(0, model.depth)) * AgentInboxView.indentPerLevel,
            disclosure: disclosure(for: model),
            isSelected: tableView.selectedRow == row,
            isInteracting: interacting,
            now: clock()
        )
        // P3.10: the hint is set AFTER `apply` and through its own call, because it
        // is an overlay and not part of the row's content — `apply` paints what the
        // agent IS, and a pill is a thing about the keyboard.
        cell.showJumpHint(jumpHintsVisible ? AgentInboxView.jumpHintText(forRowIndex: row) : nil)
        cellsByRow[row] = cell
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection clears recession on the row you moved onto and restores it on
        // the one you left, so exactly those two are redrawn — the emphasis is
        // computed when the cell is built. Reloading the whole table here would
        // undo the incremental refresh `apply(rows:changed:)` exists for.
        let previous = selectedRowForEmphasis
        selectedRowForEmphasis = tableView.selectedRow
        redraw(rows: [previous, tableView.selectedRow])
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.9-reveal-on-click.md
    @objc private func rowClicked(_ sender: Any?) {
        reveal(rowAt: tableView.clickedRow)
    }

    /// Hand the host the agent on this row. A click on the disclosure triangle
    /// never gets here — the button tracks that mouse itself, so the table's action
    /// is not sent and folding a group does not also jump the canvas.
    private func reveal(rowAt index: Int) {
        guard rows.indices.contains(index) else { return }
        onRevealRow?(rows[index].id)
    }

    // MARK: - Jump (P3.10)

    /// The chord written on row `index`'s hint pill, or nil past the ninth row.
    /// `InboxJump` owns which chord that is; this only renders it.
    static func jumpHintText(forRowIndex index: Int) -> String? {
        InboxJump.chord(forRowNumber: index + 1)?.displayString
    }

    /// ⌘1–⌘9: select that row and reveal its agent — the same two steps a click
    /// takes (`clickRowForQA` is the same pair), so a jump and a click cannot mean
    /// two different things.
    ///
    /// Returns false for a chord that is not a jump AND for a jump past the end of
    /// the list, so the caller can let the event continue to its other meaning —
    /// which for ⌘1–⌘4 is the launch profile that owns the chord globally.
    @discardableResult
    func jump(keyCode: UInt16, modifiers: FocusKeyModifiers) -> Bool {
        guard let index = InboxJump.rowIndex(keyCode: keyCode, modifiers: modifiers),
              rows.indices.contains(index) else { return false }
        // The pills come down with the jump rather than waiting for the release: you
        // have pressed the chord, and the ⌘ that comes up will come up over the tile
        // the reveal just focused.
        setJumpHintsVisible(false)
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        reveal(rowAt: index)
        return true
    }

    /// Show or hide the pills, rebuilding only the rows that can carry one.
    ///
    /// TOLD, NOT OBSERVED, and deliberately not a `flagsChanged` override on this
    /// view: the app already watches every modifier transition
    /// (`AppDelegate.handleFlagsChanged`, the monitor the hold-⌥ leader runs on), and
    /// that monitor is global. A responder-chain override here would only see the
    /// transitions that reach this view, so ⌘ held while focus moved away — the
    /// reveal does exactly that — would leave the pills up with nothing to press.
    /// (Cross-review found that; the fix is reuse, not a second modifier tracker.)
    func setJumpHintsVisible(_ visible: Bool) {
        guard visible != jumpHintsVisible else { return }
        jumpHintsVisible = visible
        redraw(rows: Array(0..<InboxJump.maximumRows))
    }

    /// P3.5's `isInteracting`: hover, selection, or keyboard-active. The last two
    /// are one test rather than two, because arrow-key navigation in an
    /// `NSTableView` IS a selection move — a keyboard-active row and the selected
    /// row are the same row by construction.
    private func isInteracting(row: Int) -> Bool {
        row == hoveredRow || row == tableView.selectedRow
    }

    /// Rebuild the cells of just these rows, ignoring any that are not on screen.
    private func redraw(rows indexes: [Int]) {
        let touched = IndexSet(indexes.filter { rows.indices.contains($0) })
        guard !touched.isEmpty else { return }
        tableView.reloadData(forRowIndexes: touched, columnIndexes: IndexSet(integer: 0))
    }

    /// KEYED `id:variant` (P3.7), not by id alone. The two variants are two
    /// different view trees at two different heights, so a lifecycle transition has
    /// to replace the row's view rather than re-dress it: sharing a key across the
    /// collapse is what makes a row appear to slide through its neighbours, and a
    /// translucent row sliding over another reads as text painted over text. With
    /// the variant in the key the old view goes and the new one arrives in place,
    /// which is the crossfade P4.12 animates.
    static func accessibilityIdentifier(for row: AgentInboxRow) -> String {
        "agent-inbox-row-\(row.id.uuidString)-\(row.variant.rawValue)"
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(row: tableView.row(at: tableView.convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(row: -1)
    }

    private func setHovered(row: Int) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        redraw(rows: [previous, row])
    }

    // MARK: - QA

    var rowCountForQA: Int { tableView.numberOfRows }
    var rowIdsForQA: [UUID] { rows.map(\.id) }
    var titlesForQA: [String] { cells().map(\.qaTitle) }
    var stateLabelsForQA: [String] { cells().map(\.qaStateLabel) }
    var metaLinesForQA: [String] { cells().map(\.qaMeta) }
    var branchLinesForQA: [String] { cells().map(\.qaBranch) }
    /// The alpha the row's WORDS are painted at, and the alpha its status accent
    /// is painted at — P3.5's two numbers, read off the rendered views rather than
    /// recomputed, which is the only way this can witness the paint.
    var textAlphasForQA: [Double] { cells().map(\.qaTextAlpha) }
    var accentAlphasForQA: [Double] { cells().map(\.qaAccentAlpha) }
    var isEmptyMessageVisibleForQA: Bool { !emptyLabel.isHidden }
    var emptyMessageForQA: String { emptyLabel.stringValue }
    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// The popup as RENDERED — the titles AppKit is really showing and the one it
    /// has ticked — rather than `scopeEntries`, which would assert about the array
    /// the menu was built from and not about the menu.
    var scopeTitlesForQA: [String] { scopePopUp.itemTitles.filter { !$0.isEmpty } }
    var selectedScopeTitleForQA: String { scopePopUp.titleOfSelectedItem ?? "" }
    var selectedRowCountForQA: Int { tableView.selectedRowIndexes.count }

    /// Pick a scope the way the user does — through the popup's own action, so the
    /// check exercises the target/action wiring and not just `setScope`.
    @discardableResult
    func pickScopeForQA(_ scope: InboxScope) -> Bool {
        guard let index = scopeEntries.firstIndex(of: scope),
              scopePopUp.selectItem(withTag: index) else { return false }
        scopePicked(scopePopUp)
        return true
    }
    /// P3.7, read off the RENDERED table rather than recomputed: the variant of
    /// the cell class AppKit actually built, the height it actually laid the row
    /// out at, and the parked row's glyph with the alpha it is painted at.
    var rowVariantsForQA: [RowVariant] { cells().map(\.qaVariant) }
    /// The height each row was actually LAID OUT at, less the intercell spacing
    /// `NSTableView.rect(ofRow:)` folds into it — so this is the number
    /// `height(for:)` returned, measured off the table rather than re-derived from
    /// it (which would witness nothing).
    var rowHeightsForQA: [Double] {
        (0..<tableView.numberOfRows).map { Double(tableView.rect(ofRow: $0).height - tableView.intercellSpacing.height) }
    }
    var glyphsForQA: [String] { cells().map(\.qaGlyph) }
    /// A card's elapsed turn time, a parked row's "12m ago" — one accessor,
    /// because it is one column: how long this row has been the way it is.
    var relativeTimesForQA: [String] { cells().map(\.qaElapsed) }
    var glyphAlphasForQA: [Double] { cells().map(\.qaGlyphAlpha) }
    var identifiersForQA: [String] { cells().map { $0.identifier?.rawValue ?? "" } }
    // Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
    /// The nesting as DRAWN: how far each row's card was actually inset, and the
    /// disclosure glyph on it ("" for a row with no children). Read off the laid-out
    /// cells rather than recomputed from `depth`, which would assert nothing.
    var indentsForQA: [Double] { cells().map(\.qaIndent) }
    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// The chord each row is ADVERTISING ("" for a row with no pill), read off the
    /// rendered pill rather than recomputed from the index.
    var jumpHintsForQA: [String] { cells().map(\.qaJumpHint) }
    /// Where each row's status label actually sits, in its own cell's coordinates.
    /// The T3 regression this ticket names — holding ⌘ blanked out "Working" — is a
    /// LAYOUT fact, so it is caught by comparing this before and after the pills
    /// appear and by nothing else.
    var statusFramesForQA: [NSRect] { cells().map(\.qaStatusFrame) }
    /// Make the list itself first responder, which is the scope the jump is confined
    /// to — so a check can put the app in the state a click on a row leaves it in.
    @discardableResult
    func focusListForQA() -> Bool {
        window?.makeFirstResponder(tableView) ?? false
    }
    /// Whether the pills are UP, for the app-level check that drives the real
    /// modifier monitor — the paint itself is asserted by `jumpHintsForQA`.
    var areJumpHintsVisibleForQA: Bool { jumpHintsVisible }
    var disclosureGlyphsForQA: [String] { cells().map(\.qaDisclosureGlyph) }
    var collapsedParentsForQA: Set<UUID> { collapsedParents }

    /// Fold a group the way the user does — through the button's own target/action,
    /// so the check exercises the wiring and not just `toggleCollapse`.
    @discardableResult
    func clickDisclosureForQA(id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let cell = cellsByRow[index] else { return false }
        return cell.clickDisclosureForQA()
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.9-reveal-on-click.md
    /// Click a row the way the user does — the same selection AppKit makes on
    /// mouse-down, then the same `reveal(rowAt:)` the table's action calls.
    ///
    /// The one step it cannot reproduce is `NSTableView.clickedRow`, which AppKit
    /// only sets while it is dispatching a real mouse event; that link is asserted
    /// separately by `isClickWiredForQA`, so nothing between the mouse and the host
    /// callback is left unwitnessed.
    @discardableResult
    func clickRowForQA(id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        reveal(rowAt: index)
        return true
    }

    /// The table sends its single-click action to this view — the half of the click
    /// path `clickRowForQA` cannot execute.
    ///
    /// `doubleAction` is NOT asserted nil: measured, `NSTableView` reports the plain
    /// `action` as its `doubleAction` when none was set separately, so a double click
    /// calls `rowClicked` a second time. Revealing an agent you are already on is
    /// idempotent, so that is left alone rather than papered over.
    var isClickWiredForQA: Bool {
        (tableView.target as? AgentInboxView) === self
            && tableView.action == #selector(rowClicked(_:))
    }

    @discardableResult
    func selectRowForQA(id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return true
    }

    @discardableResult
    func hoverRowForQA(id: UUID?) -> Bool {
        guard let id else { setHovered(row: -1); return true }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        setHovered(row: index)
        return true
    }

    /// Force the table to realise a cell for every row, so the accessors above
    /// describe the whole list and not just the part AppKit felt like laying out.
    func layoutForQA() {
        layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        for row in 0..<tableView.numberOfRows where cellsByRow[row] == nil {
            _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    private func cells() -> [AgentInboxRowCell] {
        (0..<tableView.numberOfRows).compactMap { cellsByRow[$0] }
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
/// The two row views the list can build, behind one call. The list decides WHICH
/// from `AgentInboxRow.variant` and then knows nothing else about the difference —
/// so the density rule lives in `RowVariant.forLifecycle` (P3.1), which is where
/// it can be gated, and never in a condition scattered through the painting.
@MainActor
protocol AgentInboxRowCell: NSTableCellView {
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure, isSelected: Bool, isInteracting: Bool, now: Date)

    /// What the row's disclosure triangle does. Set by the list, which is the only
    /// thing that knows the fold state; a cell with `RowDisclosure.none` never calls
    /// it because it has no control to click.
    var onToggleDisclosure: (() -> Void)? { get set }

    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// Show this chord as a floating pill, or nil to hide it. An OVERLAY on both
    /// variants — never an arranged subview — because a pill that joins the row's
    /// stack pushes the status label out of the line (the T3 regression: holding ⌘
    /// blanked out "Working").
    func showJumpHint(_ chord: String?)

    var qaVariant: RowVariant { get }
    var qaTitle: String { get }
    var qaStateLabel: String { get }
    var qaMeta: String { get }
    var qaBranch: String { get }
    var qaElapsed: String { get }
    var qaGlyph: String { get }
    var qaTextAlpha: Double { get }
    var qaAccentAlpha: Double { get }
    var qaGlyphAlpha: Double { get }
    var qaIndent: Double { get }
    var qaDisclosureGlyph: String { get }
    var qaJumpHint: String { get }
    /// The frame of whatever this variant paints the state with — the word on a
    /// card, the glyph on a parked row — in the cell's own coordinates.
    var qaStatusFrame: NSRect { get }
    @discardableResult
    func clickDisclosureForQA() -> Bool
}

// Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
/// Whether a row draws a disclosure triangle, and which way it points. `none` is a
/// row with no children in this list — most rows — and it draws nothing at all
/// rather than a disabled control, which would put a dead glyph on every line of a
/// list that has no orchestrator in it.
enum RowDisclosure: Equatable {
    case none
    case expanded
    case collapsed

    var glyph: String {
        switch self {
        case .none: return ""
        case .expanded: return "▾"
        case .collapsed: return "▸"
        }
    }
}

/// The triangle that folds a parent's children away.
///
/// An `NSButton` with a token-coloured attributed title rather than AppKit's
/// `.disclosure` bezel: that bezel draws a system-coloured chevron this app cannot
/// theme, and P1.7's lint plus P1.6's contrast gate hold every painted colour in
/// this view to a token. Borderless, so the only thing on screen is the glyph.
final class InboxDisclosureButton: NSButton, TokenThemed {
    private var glyph = ""

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        font = .token(.label)
        // The glyph is the whole control, so it must not be squeezed out of a
        // narrow sidebar the way a truncating label can be.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { return nil }

    func show(_ disclosure: RowDisclosure) {
        isHidden = disclosure == .none
        glyph = disclosure.glyph
        setAccessibilityLabel(disclosure == .collapsed ? "Expand" : "Collapse")
        applyTokens()
    }

    /// `textSecondary`, the same token the row's own metadata uses: the triangle is
    /// chrome, and an accent here would be a fourth colour meaning in a list P3.2
    /// holds to three.
    func applyTokens() {
        attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [
                .font: NSFont.token(.label),
                .foregroundColor: TextToken.textSecondary.color.nsColor(in: self),
            ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    var qaGlyph: String { isHidden ? "" : glyph }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
/// The floating "⌘3" pill a row shows while ⌘ is held.
///
/// `overlay` fill with a `border` outline and `textPrimary` text — all three are
/// documented pairs (`TextToken.legalBackgrounds` allows every surface;
/// `LineToken.border.legalSurfaces` likewise), so P1.6's contrast gate measures this
/// rather than exempting it. `.captionMono`, because a chord is a key you press and
/// the digit must not shift width between rows.
///
/// It is added to the CARD and constrained to the card, so it floats over the row's
/// words instead of taking a slot in their stack. Hidden by default, which is what
/// every committed baseline holds except `chrome.agentInbox.jumpHints` — that one card
/// exists so the pills are in a render at all, since a modifier cannot be held down in
/// a static one.
final class InboxJumpHintView: NSView, TokenThemed {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        // `Radius.card`, NOT `Radius.pill`, for the reason `BranchChipNSView` already
        // records at its own radius: CALayer does not clamp a radius to half the
        // view's height, so 999 on a 15pt pill is undefined-looking geometry. Measured
        // here before the note was believed — the 999 render painted a white shape
        // across every row and took the whole list's text with it.
        layer?.cornerRadius = Radius.card
        layer?.masksToBounds = true
        isHidden = true

        label.font = .token(.captionMono)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Space.xs),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.xs),
        ])
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    /// nil hides the pill. An empty string would leave a bordered box with no glyph
    /// in it, which `UIProbePixels` is right to call flat.
    func show(_ chord: String?) {
        guard let chord, !chord.isEmpty else {
            isHidden = true
            return
        }
        label.stringValue = chord
        isHidden = false
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderColor = LineToken.border.color.cgColor(for: theme)
        label.textColor = TextToken.textPrimary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    var qaChord: String { isHidden ? "" : label.stringValue }
}

/// The card one row's words sit on: a `tileBody` fill with a `border` outline,
/// or `borderStrong` while the row is selected.
///
/// A VIEW, not a layer on the cell — and not an `NSTableRowView` either. Both
/// alternatives were tried and both are wrong for a gate reason:
///
///  * a layer-backed `NSTableRowView` carries sublayers AppKit created, and
///    `UIProbeAppearance` holds a `TokenThemed` view answerable for every painted
///    layer it owns, including those (measured: 7 rows, 7 sentinels surviving the
///    flip on layers this code never touched);
///  * a `CALayer` under the cell is invisible to `UIProbeContrast`, which reads
///    fills off VIEWS as it walks down — so every label on the card was measured
///    against the panel two levels up instead of against the card it is on.
///
/// A plain `NSView` is answerable for its own layer, has no sublayers but its
/// own, and IS the background the labels inside it are measured against.
final class AgentInboxCardView: NSView, TokenThemed {
    var isSelected = false {
        didSet { applyTokens() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        layer?.borderWidth = 1
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    /// `borderStrong` is the P1.3 token for "focus and selection", so a selected
    /// card is OUTLINED rather than tinted: a fill change would move every text
    /// pair on the row onto an undocumented background, while the outline is a pair
    /// P1.6 already gates at the 3.0 line floor.
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(for: theme)
        layer?.borderColor = (isSelected ? LineToken.borderStrong : LineToken.border).color.cgColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}

/// One row's words, on the card that carries them.
final class AgentInboxCellView: NSTableCellView, AgentInboxRowCell {
    private let card = AgentInboxCardView()

    private let jumpHint = InboxJumpHintView()
    private let disclosureButton = InboxDisclosureButton()
    var onToggleDisclosure: (() -> Void)?
    private let projectLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var leadingInset: NSLayoutConstraint?
    /// What this cell is currently showing. Held so the cell can repaint its own
    /// text colours when the appearance moves — an `NSTextField.textColor` is a
    /// resolved colour, and the list above must not reload the table to fix it
    /// (see `AgentInboxView.applyTokens`).
    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis, disclosure: RowDisclosure)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        projectLabel.font = .token(.caption)
        projectLabel.lineBreakMode = .byTruncatingTail

        titleLabel.font = .token(.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        // Lower than the project chip's default 750, so a narrow sidebar truncates
        // the agent's NAME before the project it is in — the project answers "which
        // of my five checkouts is this" and half a project name answers nothing,
        // whereas half an agent name is still the agent you recognise.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateLabel.font = .token(.label)
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        elapsedLabel.font = .token(.captionMono)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        metaLabel.font = .token(.label)
        metaLabel.lineBreakMode = .byTruncatingTail

        // Middle, not tail: an `agent/<role>-<slug>` branch is identified by both
        // ends, the same reasoning `BranchChipNSView` records for its own label.
        branchLabel.font = .token(.label)
        branchLabel.lineBreakMode = .byTruncatingMiddle

        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)

        let headline = NSStackView(views: [disclosureButton, projectLabel, titleLabel, NSView(), stateLabel, elapsedLabel])
        headline.orientation = .horizontal
        headline.alignment = .firstBaseline
        headline.spacing = Space.m
        // The spacer between the name and the status is the flexible one; without
        // this the title and the state label share the slack and the status column
        // wanders row to row.
        headline.setHuggingPriority(.defaultLow, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(headline)
        stack.addArrangedSubview(metaLabel)
        stack.addArrangedSubview(branchLabel)
        card.addSubview(stack)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        leadingInset = leading
        NSLayoutConstraint.activate([
            leading,
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Inset.card.left),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Inset.card.right),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Inset.card.top),
            headline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // FLOORS, not decoration. Without them a 280pt sidebar squeezes a
            // truncating label to a few points wide, which renders as a rect with
            // no glyph in it — and `UIProbePixels` is right to call that flat:
            // `chrome.sidebar.live … text rect is flat — luminance spread 0.000
            // over 176 px`. Measured off the font rather than guessed, the
            // `BranchChipNSView.minimumTextWidth` precedent.
            projectLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.caption)),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.title)),
            metaLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            branchLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])

        // P3.10: added AFTER the stack (so it draws over it) and constrained to the
        // CARD rather than joined to any stack — that is what makes it an overlay.
        // Trailing and vertically centred: the words are left-aligned in three lines,
        // so the middle of the card's right edge is the emptiest part of the row, and
        // it is nowhere near the status word on the headline.
        jumpHint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(jumpHint)
        NSLayoutConstraint.activate([
            jumpHint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Inset.card.right),
            jumpHint.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    /// Paint one row.
    ///
    /// THE EMPHASIS RULE, and the reason it is applied field by field rather than
    /// to `self`: a view alpha on the cell would fade the status accent with the
    /// words, and a faded accent is how a waiting row becomes unfindable. P3.5
    /// states it as an obligation on this file — "apply `textOpacity` to the row's
    /// TEXT LAYER, never to a container the status accent is inside". So the five
    /// word labels take `textOpacity` and `stateLabel` takes `accentOpacity`,
    /// which is full for both emphases by construction.
    ///
    /// `isInteracting` and `now` are the slim variant's (P3.7) and are unused here:
    /// a full card dims nothing on hover beyond what `emphasis` already carries,
    /// and its elapsed time is a number the ROW holds rather than a distance from
    /// the current clock. They are on the shared call so the list can paint either
    /// variant without knowing which it has.
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, isSelected: Bool = false,
               isInteracting: Bool = false, now: Date = Date()) {
        shown = (row, emphasis, disclosure)
        card.isSelected = isSelected
        leadingInset?.constant = indent
        disclosureButton.show(disclosure)

        projectLabel.stringValue = row.projectName ?? ""
        projectLabel.isHidden = row.projectName == nil
        titleLabel.stringValue = row.title
        stateLabel.stringValue = row.label ?? ""
        stateLabel.isHidden = row.label == nil
        elapsedLabel.stringValue = AgentInboxCellView.elapsedText(row.elapsed) ?? ""
        elapsedLabel.isHidden = row.elapsed == nil
        metaLabel.stringValue = AgentInboxCellView.metaText(role: row.role, model: row.model)
        metaLabel.isHidden = metaLabel.stringValue.isEmpty
        branchLabel.stringValue = AgentInboxCellView.branchText(branch: row.branch, isIsolated: row.isIsolated)
        branchLabel.isHidden = branchLabel.stringValue.isEmpty

        projectLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        elapsedLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        metaLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        branchLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        // The accent IS the state's colour (P3.2) and `ready` has none — which is
        // why the label is hidden there rather than painted in some neutral: the
        // resting state carries no word and no colour, and that is the whole of
        // the decision.
        stateLabel.textColor = (row.state.accent?.color ?? TextToken.textSecondary.color).nsColor(in: self)

        for label in [projectLabel, titleLabel, elapsedLabel, metaLabel, branchLabel] {
            label.alphaValue = emphasis.textOpacity
        }
        stateLabel.alphaValue = emphasis.accentOpacity
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let shown else { return }
        apply(shown.row, emphasis: shown.emphasis,
              indent: Double(leadingInset?.constant ?? 0), disclosure: shown.disclosure,
              isSelected: card.isSelected)
    }

    @objc private func disclosureClicked() { onToggleDisclosure?() }

    func showJumpHint(_ chord: String?) { jumpHint.show(chord) }

    @discardableResult
    func clickDisclosureForQA() -> Bool {
        guard !disclosureButton.isHidden else { return false }
        disclosureButton.performClick(nil)
        return true
    }

    /// Four characters of `role`, so a squeezed row truncates rather than
    /// collapsing a label to an empty sliver.
    static func minimumTextWidth(_ role: TextRole) -> Double {
        ("0000" as NSString).size(withAttributes: [.font: NSFont.token(role)]).width
    }

    /// `role · model`, with the separator only where both sides exist. An agent
    /// with neither gets an empty line that is hidden, not a bare "·".
    static func metaText(role: String?, model: String?) -> String {
        [role, model].compactMap { $0 }.joined(separator: " · ")
    }

    /// The branch line, in `BranchChipNSView`'s vocabulary rather than a second
    /// one: the same `⎇` glyph and the same `· shared` suffix, so the tile chip
    /// and the inbox row cannot describe one agent two ways.
    ///
    /// The chip's third state — assigned one branch, checked out on another — is
    /// deliberately absent: `AgentInboxRow` carries one resolved branch name and
    /// no mismatch fact (P3.1 flattened it that way), and inventing a warning from
    /// a name this view cannot compare would be a guess.
    static func branchText(branch: String?, isIsolated: Bool) -> String {
        guard let branch else { return "" }
        let base = "\(BranchChipNSView.branchGlyph) \(branch)"
        return isIsolated ? base : "\(base) \(BranchChipNSView.sharedSuffix)"
    }

    /// `45s` / `4m` / `2h11m`. Whole units only: a turn's duration is glanced at,
    /// and a seconds field on an hour-long run is noise that also makes the label
    /// reflow every second — which is what `.captionMono` is holding still for.
    static func elapsedText(_ elapsed: TimeInterval?) -> String? {
        guard let elapsed, elapsed >= 0 else { return nil }
        let seconds = Int(elapsed.rounded(.down))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }

    var qaVariant: RowVariant { .card }
    var qaTitle: String { titleLabel.stringValue }
    var qaStateLabel: String { stateLabel.isHidden ? "" : stateLabel.stringValue }
    var qaMeta: String { metaLabel.stringValue }
    var qaBranch: String { branchLabel.stringValue }
    var qaElapsed: String { elapsedLabel.stringValue }
    /// A full card carries the state as a WORD (`qaStateLabel`), never as a glyph —
    /// the glyph is the collapsed row's way of saying the same thing in the room it
    /// has. Empty here is the fact, not a missing accessor.
    var qaGlyph: String { "" }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    var qaAccentAlpha: Double { Double(stateLabel.alphaValue) }
    var qaGlyphAlpha: Double { Opacity.full }
    var qaIndent: Double { Double(leadingInset?.constant ?? 0) }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
    var qaJumpHint: String { jumpHint.qaChord }
    var qaStatusFrame: NSRect { stateLabel.convert(stateLabel.bounds, to: self) }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
/// A PARKED row: settled or snoozed, and nothing else. Density comes from work
/// you are finished with, never from the list second-guessing importance — a
/// `ready` or `failed` agent stays a full card however quiet the inbox gets, and
/// `RowVariant.forLifecycle` is what makes that structural rather than a rule this
/// view could forget.
///
/// One line, four things: the state as a GLYPH, the agent's name, its branch and
/// how long ago it stopped (or how long until a snooze is up). The glyph is dimmed
/// at rest and full while you point at the row, so the settled tail stays scannable
/// when you are hunting through it without being a second column of colour when you
/// are not.
///
/// THE CARD IS REUSED, not dropped. A parked row keeps `AgentInboxCardView` so it
/// still takes the selection outline, still re-themes itself on an appearance flip,
/// and still gives `UIProbeContrast` a documented `tileBody` fill to measure its
/// words against — a bare row would put them on the panel two levels up. The
/// collapse is the height and the content; the chrome is not what makes a card.
///
/// ONE DELIBERATE DIVERGENCE FROM P3.5, recorded here rather than left to be
/// discovered: `RowEmphasis.accentOpacity` holds a status accent at full strength
/// "so a waiting row is still findable", and this glyph fades. The reason the rule
/// does not reach here is that a parked row is not waiting on anyone — settling or
/// snoozing IS the act of taking it out of the attention flow — so the accent has
/// nothing left to be findable for. The fade is `Opacity.receded`, the same token
/// the words use, so it stays inside the contrast envelope P1.6 gates rather than
/// being an alpha of this view's own choosing.
final class AgentInboxSlimCellView: NSTableCellView, AgentInboxRowCell {
    private let card = AgentInboxCardView()
    private let jumpHint = InboxJumpHintView()
    private let disclosureButton = InboxDisclosureButton()
    var onToggleDisclosure: (() -> Void)?
    private let glyphLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var leadingInset: NSLayoutConstraint?
    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis, disclosure: RowDisclosure,
                        isInteracting: Bool, now: Date)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        glyphLabel.font = .token(.label)
        glyphLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .token(.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The title takes the slack (there is no spacer view in this line — an
        // unconstrained one is what made a card's height ambiguous once already and
        // the render coin-flip that followed it), and it truncates LAST: half a
        // branch name still identifies the branch, half an agent name is the agent
        // you were looking for.
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        branchLabel.font = .token(.label)
        // Middle, for the same reason the card's branch line uses it.
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .token(.captionMono)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)

        // A parked group folds too: a snoozed parent and its snoozed children are
        // nested in the shelf the same way the live block nests.
        let line = NSStackView(views: [disclosureButton, glyphLabel, titleLabel, branchLabel, timeLabel])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = Space.m
        line.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(line)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        leadingInset = leading
        NSLayoutConstraint.activate([
            leading,
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            line.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Inset.row.left),
            line.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Inset.row.right),
            // Centred, not pinned top-and-bottom: one line in a 35pt row, and a
            // centre constraint cannot leave the height ambiguous the way a
            // top+bottom pair on a flexible stack can.
            line.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            // The same floors the card row carries, for the same reason: a
            // truncating label squeezed to a few points renders as a rect with no
            // glyph in it, which `UIProbePixels` is right to call flat.
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.title)),
            branchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.label)),
        ])

        // P3.10: an overlay here too — a parked row is one line, so a pill in the
        // stack would push the whole line sideways rather than merely displace one
        // label.
        jumpHint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(jumpHint)
        NSLayoutConstraint.activate([
            jumpHint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Inset.row.right),
            jumpHint.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, isSelected: Bool = false,
               isInteracting: Bool = false, now: Date = Date()) {
        shown = (row, emphasis, disclosure, isInteracting, now)
        card.isSelected = isSelected
        leadingInset?.constant = indent
        disclosureButton.show(disclosure)

        glyphLabel.stringValue = AgentInboxSlimCellView.glyph(for: row.state)
        titleLabel.stringValue = row.title
        branchLabel.stringValue = AgentInboxSlimCellView.branchText(branch: row.branch)
        branchLabel.isHidden = branchLabel.stringValue.isEmpty
        timeLabel.stringValue = AgentInboxSlimCellView.relativeText(for: row.lifecycle, now: now)
        timeLabel.isHidden = timeLabel.stringValue.isEmpty

        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        branchLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        timeLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        glyphLabel.textColor = (row.state.accent?.color ?? TextToken.textSecondary.color).nsColor(in: self)

        for label in [titleLabel, branchLabel, timeLabel] {
            label.alphaValue = emphasis.textOpacity
        }
        glyphLabel.alphaValue = isInteracting ? Opacity.full : Opacity.receded
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let shown else { return }
        apply(shown.row, emphasis: shown.emphasis, indent: Double(leadingInset?.constant ?? 0),
              disclosure: shown.disclosure, isSelected: card.isSelected,
              isInteracting: shown.isInteracting, now: shown.now)
    }

    @objc private func disclosureClicked() { onToggleDisclosure?() }

    func showJumpHint(_ chord: String?) { jumpHint.show(chord) }

    @discardableResult
    func clickDisclosureForQA() -> Bool {
        guard !disclosureButton.isHidden else { return false }
        disclosureButton.performClick(nil)
        return true
    }

    /// The state as one character, in `StatusChipPresenter`'s vocabulary rather
    /// than a second one — the chip and the collapsed row must not draw one agent
    /// two ways (P1.8 is the single status presenter, and this borrows from it
    /// instead of competing with it).
    ///
    /// `approval` and `input` share `needsAttention`'s glyph because that is the
    /// status both of them come from; they are already told apart by colour, which
    /// is the axis P3.2 gave them. `failed` is the one state with nothing to borrow:
    /// no `AgentStatus` records failure yet (P3.1 says so at `state(for:)`), so the
    /// chip vocabulary has no member for it and this is the one glyph chosen here.
    static let failedGlyph = "✕"

    static func glyph(for state: InboxState) -> String {
        switch state {
        case .working: return StatusChipPresenter.display(for: .working).glyph
        case .approval, .input: return StatusChipPresenter.display(for: .needsAttention).glyph
        case .ready: return StatusChipPresenter.display(for: .idle).glyph
        case .failed: return failedGlyph
        }
    }

    /// The branch badge, in `BranchChipNSView`'s glyph but WITHOUT the card's
    /// `· shared` suffix.
    ///
    /// Measured, not preferred: with the suffix the 320pt sidebar truncated the
    /// badge to `⎇ mai…hared` in the first render of this card — middle truncation
    /// is right for a branch name and useless once the same line also holds a
    /// glyph, a name and a time. A collapsed row answers "which branch"; the shared
    /// vs isolated distinction stays on the card, where there is room to say it.
    static func branchText(branch: String?) -> String {
        guard let branch else { return "" }
        return "\(BranchChipNSView.branchGlyph) \(branch)"
    }

    /// How long ago the work stopped, or how long until a snooze is up.
    ///
    /// In `AgentInboxCellView.elapsedText`'s units (`45s` / `4m` / `2h11m`), reused
    /// rather than reimplemented, so a duration means the same thing on a card and
    /// on the row it collapses into. Empty for a lifecycle with no time to show and
    /// for a distance that has gone negative — an overdue snooze is P4.6's raised
    /// hand, not a row for this view to label "in -3m".
    static func relativeText(for lifecycle: InboxLifecycle, now: Date) -> String {
        switch lifecycle {
        case .settled(let at):
            guard let text = AgentInboxCellView.elapsedText(now.timeIntervalSince(at)) else { return "" }
            return "\(text) ago"
        case .snoozed(let until):
            guard let text = AgentInboxCellView.elapsedText(until.timeIntervalSince(now)) else { return "" }
            return "in \(text)"
        case .active, .archived:
            return ""
        }
    }

    var qaVariant: RowVariant { .slim }
    var qaTitle: String { titleLabel.stringValue }
    /// A collapsed row says its state with the glyph, so it has no word to report.
    var qaStateLabel: String { "" }
    var qaMeta: String { "" }
    var qaBranch: String { branchLabel.isHidden ? "" : branchLabel.stringValue }
    var qaElapsed: String { timeLabel.isHidden ? "" : timeLabel.stringValue }
    var qaGlyph: String { glyphLabel.stringValue }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    /// The glyph IS this row's accent — the same number as `qaGlyphAlpha`, and
    /// deliberately not `Opacity.full`: see the divergence note on the class.
    var qaAccentAlpha: Double { Double(glyphLabel.alphaValue) }
    var qaGlyphAlpha: Double { Double(glyphLabel.alphaValue) }
    var qaIndent: Double { Double(leadingInset?.constant ?? 0) }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
    var qaJumpHint: String { jumpHint.qaChord }
    /// The GLYPH is this variant's status (`qaStateLabel` is empty by design), so
    /// that is the frame the pill must not move.
    var qaStatusFrame: NSRect { glyphLabel.convert(glyphLabel.bounds, to: self) }
}
