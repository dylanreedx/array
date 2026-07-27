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
final class AgentInboxView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                            NSTextFieldDelegate, TokenThemed {
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

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The `Snoozed (N)` heading's height: the same one line a parked row gets, so
    /// the shelf costs exactly what one of the rows it is holding would have. Derived
    /// from `slimRowHeight` rather than restated, so a P1.4 type move moves both.
    static var shelfHeaderHeight: Double { slimRowHeight }

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

    // Ticket: docs/38-tickets/90-agent-ux/P3.16-inbox-lists-agents-only.md
    /// Shown when this list holds nothing because every agent on this desktop is
    /// running inside a terminal tile, which the inbox does not manage and therefore
    /// does not list. The THIRD message, not a reuse of either other one: "No agents
    /// yet" would be a lie in front of a working `claude` session, and blaming the
    /// scope would be a different lie — the row source excluded them, at every scope.
    static let terminalHostedEmptyMessage = "No managed agents · terminal agents aren't listed"

    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// The three workspace actions that used to be buttons in the sidebar header.
    /// They live in the scope popup's menu because the scope is already the control
    /// that names a workspace — acting on the one you have scoped to is the only
    /// place a workspace verb can sit without a header full of buttons.
    enum WorkspaceManagementAction: CaseIterable {
        case create
        case rename
        case delete

        var title: String {
            switch self {
            case .create: return "New Workspace…"
            case .rename: return "Rename Workspace…"
            case .delete: return "Delete Workspace…"
            }
        }
    }

    private let scopePopUp: NSPopUpButton
    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let column: NSTableColumn
    private let emptyLabel: NSTextField
    // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
    private let bulkBar = InboxBulkActionBar()
    // Ticket: docs/38-tickets/90-agent-ux/P3.12-row-context-menu.md
    /// The right-click menu, ONE instance rebuilt per click rather than a fresh menu
    /// per event: it is the table's `menu`, so AppKit owns showing it and this view
    /// only owns what is in it when `menuNeedsUpdate` is called.
    private let rowMenu = NSMenu()
    /// The actions in `rowMenu`, parallel to the items' tags — the shape
    /// `scopeEntries` and `InboxBulkActionBar.actions` already use, so an item's
    /// position in the menu is not what identifies it.
    private var rowMenuActions: [InboxRowAction] = []
    /// The agents the open menu is about, BY ID rather than by index: a push can
    /// arrive while the menu is up, and an index would then name a different agent.
    private var rowMenuTargetIds: [UUID] = []

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
    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// The management items in the menu as BUILT — rebuilt with the menu, because an
    /// `NSMenuItem` may only belong to one `NSMenu` and `updateScopeMenu` replaces
    /// the whole menu whenever the scope set changes.
    private var managementItems: [WorkspaceManagementAction: NSMenuItem] = [:]
    /// Enablement, told by the host: whether there is a workspace to act on at all,
    /// and whether it may be deleted (the last workspace may not). `create` is
    /// always available, which is the guard the header buttons had too.
    private var canRenameWorkspace = false
    private var canDeleteWorkspace = false
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
    // Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
    /// What is under each parent, measured on the same pre-fold list as
    /// `parentsWithChildren` and for exactly the same reason: a folded parent's
    /// children are off screen, so a rollup counted after the fold would report
    /// nothing at the one moment it is the only thing left to report. DERIVED each
    /// push, never stored on a row.
    private var rollupsByParent: [UUID: ChildRollup] = [:]
    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// What the table draws, row for row — the agent rows AND the one `Snoozed (N)`
    /// header between the active block and the settled tail. `rows` is the agent
    /// half of it, so "row N on screen" is still `rows[N]` for every accessor that
    /// works in agent terms; the two index spaces meet at `tableRow(forRowIndex:)`
    /// and `rowIndex(forTableRow:)` and nowhere else.
    private var items: [InboxListItem] = []
    /// Whether the shelf is open. VIEW-LOCAL and COLLAPSED BY DEFAULT, exactly like
    /// `collapsedParents` and for the same reason the packet gives ("local UI state,
    /// not persisted per-agent"): whether you have the shelf open on this Mac right
    /// now is not a fact about an agent, and a persisted one would restore a fold
    /// over work that woke up while the app was closed.
    private var shelfExpanded = false
    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// How many settled rows the tail is showing. VIEW-LOCAL and back at the first
    /// page on every launch, for the reason `shelfExpanded` is: how far you have
    /// paged into history right now is not a fact about an agent, and a persisted
    /// limit would restore a wall of finished work over the list you opened the app
    /// to read. Grows by `settledPageStep` per press and never shrinks on its own —
    /// a page that folded itself back up under a push would take the row you were
    /// reading with it.
    private var settledLimit = InboxSort.settledPageSize
    /// The two index maps, built once per push by `setItems` rather than walked per
    /// lookup: `viewFor` asks for one on every cell it builds, and `apply` asks for
    /// one per changed row.
    private var rowIndexByTableRow: [Int?] = []
    private var tableRowByRowIndex: [Int] = []
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
    /// reports the NEW selection only, so the rows that just lost it — the ones that
    /// have to start receding again — have to be remembered.
    ///
    /// P3.11 made this a SET rather than one index: with a range selected, the rows
    /// that changed are the symmetric difference of the two selections, and an
    /// `Int` could only ever repaint one of them.
    private var selectedRowsForEmphasis = IndexSet()
    private var trackingArea: NSTrackingArea?

    // Ticket: docs/38-tickets/90-agent-ux/P3.13-inline-rename.md
    /// The field a rename is being typed into, and the AGENT it is about — by id
    /// rather than by row index, for the reason `rowMenuTargetIds` records: a push
    /// can arrive while the field is open, and an index would then name a different
    /// agent.
    ///
    /// A subview of THIS view and not of the cell, which is the difference that
    /// matters: cells are rebuilt on every incremental apply (P2B.7), so a field
    /// hosted in one would be torn out from under the typing by the next streamed
    /// event.
    private var renameField: NSTextField?
    private var renamingRowId: UUID?
    /// True only while `beginRename` is installing + selecting the field.
    /// `selectText(_:)` ends current editing via `-[NSWindow endEditingFor:]`, which
    /// posts a synchronous end-editing notification for the field editor just
    /// attached; without this gate the delegate reads that as a blur and commits +
    /// tears the rename down inside its own opening gesture. The same gate
    /// `CanvasNSView.isOpeningZoneRename` exists for, and for the same measured
    /// reason.
    private var isOpeningRename = false

    /// The cell currently drawn for each row index, and how many cells this view
    /// has built in total. Together they are the witness for "do not full-reload on
    /// every event" (P2B.7): an incremental apply must build the cells of the
    /// touched rows and no others.
    ///
    /// The QA accessors read this map rather than asking the table for a view with
    /// `makeIfNecessary: true`, which would BUILD one and inflate the very count
    /// the witness is measuring.
    private var cellsByRow: [Int: AgentInboxRowCell] = [:]
    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The shelf header's view. Kept out of `cellsByRow` on purpose: that map is
    /// what every per-row QA accessor reads (`cells()`), and a heading in it would
    /// shift every one of those arrays out of step with `rows`. At most one exists,
    /// so it is a field and not a map.
    private var shelfHeaderCell: AgentInboxShelfHeaderView?
    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// The settled tail's footer, kept out of `cellsByRow` for the same reason the
    /// heading is. At most one exists — the tail is one section.
    private var settledMoreCell: AgentInboxSettledMoreView?
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
    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// A workspace verb was picked from the scope menu. WHICH workspace it lands on
    /// is not this view's business — it holds a scope, not a workspace id — so the
    /// host resolves the target exactly as it did for the header buttons.
    var onWorkspaceManagementAction: ((WorkspaceManagementAction) -> Void)?
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
    // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
    /// A bulk action was chosen for these agents, in the order they are on screen.
    ///
    /// The list DOES NOT perform them: settle, snooze and archive are persisted
    /// lifecycle facts that do not exist yet (P4.1 owns them, P4.10 owns what the
    /// selection does afterwards), and read-state lives on `AgentSupervisor` (P3.3).
    /// What this ticket owns is which actions a selection may take at all — so the
    /// view resolves that and hands the host the set, which is the same shape
    /// `onRevealRow` uses for the one-row case.
    var onBulkAction: ((InboxBulkAction, [UUID]) -> Void)?
    // Ticket: docs/38-tickets/90-agent-ux/P3.12-row-context-menu.md
    /// An action was chosen from a row's context menu, for the agents it was about
    /// (one row, or the whole selection when the click was inside it) in screen order.
    ///
    /// ONE CALLBACK FOR THE WHOLE MENU, and `openInTile` is the one item that does not
    /// come through it: revealing an agent already has a path (`onRevealRow`, P3.9) and
    /// a second one would be a second definition of what a reveal does. Everything else
    /// is a lifecycle fact Phase 4 owns, a rename P3.13 owns, or the explicit stop —
    /// none of which this view may perform.
    ///
    /// While it is nil every item but `Open in Tile` is DRAWN AND DISABLED, with the
    /// reason in its tooltip: the packet's watch-out allows either hiding or a disabled
    /// item with a tooltip, and unlike the 320pt bulk bar (P3.11, which hides) a context
    /// menu has the room to say why. It also keeps the menu's shape stable, so the day a
    /// host wires this nothing about the menu moves except which items answer.
    var onRowAction: ((InboxRowAction, [UUID]) -> Void)?
    // Ticket: docs/38-tickets/90-agent-ux/P3.15-wire-destructive-row-actions.md
    //
    // WHICH ACTIONS THE HOST ACTUALLY PERFORMS, action by action. `onRowAction` used to
    // be the whole gate: assigning it un-greyed all nine items at once, including
    // `snooze` and `wake`, which nothing writes yet (P4.6 owns the write, P4.7 the
    // shelf). So the callback could not be assigned at all without shipping two menu
    // items that answer a click with nothing — which is why, for eleven tickets, the
    // shipped sidebar assigned neither callback and the owner could not delete an agent.
    //
    // A capability SET rather than a boolean: an item is live when there is something
    // to run, and adding a destination later is one element here rather than a new
    // gate. Empty by default, so a host that assigns the callback and forgets this
    // greys everything rather than offering silent no-ops.
    var wiredRowActions: Set<InboxRowAction> = []
    /// The same, for the bar. P3.11's rule is unchanged underneath it: an action must
    /// be BOTH available for every selected row (which hides it when it is not) and
    /// wired here.
    var wiredBulkActions: Set<InboxBulkAction> = []
    // Ticket: docs/38-tickets/90-agent-ux/P3.13-inline-rename.md
    /// A new name was COMMITTED for this agent — trimmed, non-empty and different
    /// from the one on screen, so a host never has to re-decide any of those.
    ///
    /// The list does not perform it: the name lives on `AgentRecord` and only
    /// `AgentSupervisor` may write one (it also sanitises the text, which is the
    /// half a view must not be trusted with — the name crosses to the phone). The
    /// row's title changes when the host pushes rows back, exactly like every other
    /// fact this list draws.
    var onRenameRow: ((UUID, String) -> Void)?
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

    // Ticket: docs/38-tickets/90-agent-ux/P3.16-inbox-lists-agents-only.md
    /// Agents the host's row-source policy left out because they are running inside
    /// terminal tiles. It changes only the WORDS of the empty state, so it re-renders
    /// nothing and cannot cost the incremental refresh (P2B.7) its "one cell rebuilt".
    var excludedTerminalAgentCount: Int = 0 {
        didSet {
            guard excludedTerminalAgentCount != oldValue else { return }
            updateEmptyState()
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
        // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
        //
        // THE GESTURES ARE APPKIT'S, DELIBERATELY. Click, shift-click for a range and
        // ⌘-click to toggle are what `NSTableView` does once this is true, and it keeps
        // the selection ANCHOR the packet asks to be stable: a range extends from the
        // row you last plain-clicked, so a second shift-click re-extends from that same
        // anchor instead of growing off the previous shift. Reimplementing the three
        // gestures over `mouseDown` would mean owning that anchor, the autoscroll and
        // the drag-select — and would take `clickedRow` (and with it P3.9's reveal,
        // which is asserted through the table's own target/action) out of the path.
        // What this ticket owns is what a SELECTION SET may do, below.
        tableView.allowsMultipleSelection = true
        tableView.translatesAutoresizingMaskIntoConstraints = false

        column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent-inbox-row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyLabel = NSTextField(labelWithString: AgentInboxView.emptyMessage)
        emptyLabel.font = .token(.label)
        emptyLabel.alignment = .center
        // P3.16: the third message is a sentence, not two words, and a 320pt sidebar
        // clips one. Wrapping rather than shortening — the words have to say WHY the
        // list is empty, and a clipped explanation explains nothing. Two lines is the
        // measured need at this width; `runAgentInboxChecks` asserts the label stays
        // inside the view's bounds so a longer string cannot silently spill.
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 2
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
        // P3.11: added LAST, so it draws over the bottom of the list.
        addSubview(bulkBar)

        tableView.dataSource = self
        tableView.delegate = self
        // P3.9: the table's own single-click action. `clickedRow` is -1 for a click
        // in the empty space below the rows, which `reveal(rowAt:)` drops.
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        // P3.13: the second click of a double-click on the row's NAME opens the
        // inline rename. Set explicitly, because `NSTableView` otherwise reports the
        // plain `action` as its `doubleAction` and the second click would only reveal
        // again (measured — see `isClickWiredForQA`). The first click still reveals;
        // that is the same idempotent reveal a second single click makes.
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        scopePopUp.target = self
        scopePopUp.action = #selector(scopePicked(_:))
        updateScopeMenu()
        // P3.11: the bar reports the action; resolving WHICH agents it lands on is the
        // list's, because only the list knows the selection.
        bulkBar.onAction = { [weak self] action in self?.performBulkAction(action) }
        bulkBar.setAccessibilityIdentifier("ContinuumAgentInboxBulkBar")
        // P3.12: the TABLE's menu, not this view's — `NSTableView` sets `clickedRow`
        // before it asks its menu to update, which is the only way the menu knows which
        // row the mouse was over. A menu on the container would have to hit-test the
        // event itself.
        //
        // `autoenablesItems = false` IS LOAD-BEARING: left at AppKit's default, every
        // item's enablement is recomputed from whether its target responds to its action
        // — which this view does, for all ten — so a deliberately disabled item comes back
        // up enabled in `NSMenu.update()`, which runs just before the menu is drawn.
        // (Measured: Open in Tile live again over a two-row selection. That pass is why
        // `openRowMenuForQA` calls `update()` — a check that only reads the `isEnabled`
        // this code sets never sees the one AppKit would show.)
        rowMenu.autoenablesItems = false
        rowMenu.delegate = self
        tableView.menu = rowMenu

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

            // P3.11: AN OVERLAY ON THE LIST, not a row in a vertical stack with it —
            // the same call `InboxJumpHintView` records for the hint pill, for a
            // different reason. A bar that took height off the scroll view would move
            // every row in the list the moment you selected a second one, so the four
            // committed `chrome.agentInbox…` baselines would be describing a list whose
            // geometry depends on the selection. Floating it leaves the rows where they
            // are and leaves those PNGs alone (it is hidden until 2 rows are selected,
            // so nothing paints in any of them).
            bulkBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s),
            bulkBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s),
            bulkBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.s),
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
        // P4.10: read BEFORE the render, which empties the table's selection — the
        // advance is validated against the selection the person had when this push
        // arrived, and by the time `render` returns nobody can tell what that was.
        let selectionOnEntry = selectedRows.map(\.id)
        allRows = newRows
        updateScopeMenu()
        render(display(from: newRows))
        completePendingAdvance(selectionOnEntry: selectionOnEntry)
    }

    /// Draw this list whole. Takes rows that are ALREADY filtered and sorted, which
    /// is why it is private: `reload(rows:)` is the entry point for a fresh push and
    /// takes the unfiltered set, and handing it an already-filtered list would make
    /// the scope narrow itself with every call.
    private func render(_ visible: [InboxListItem]) {
        // P3.13: a full reload moves every row, so a field left floating would be over
        // a different agent. Committing is the same answer clicking away gives — the
        // rename is finished, not thrown away, and this is also the path the host's
        // own re-push takes right after a commit (where it is already a no-op).
        endRename(commit: true)
        setItems(visible)
        cellsByRow.removeAll()
        shelfHeaderCell = nil
        settledMoreCell = nil
        tableView.reloadData()
        updateEmptyState()
        // P3.11: `reloadData` empties the table's selection, so the bar has to come
        // down with it — a bar left up over an empty selection offers actions with
        // nothing to apply them to.
        selectedRowsForEmphasis = IndexSet()
        updateBulkBar()
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
        // P4.10: the same read `reload(rows:)` makes, and for the same reason — this
        // path keeps the selection when the list's identities did not move, and drops
        // it through `render` when they did, so only a value taken here survives both.
        let selectionOnEntry = selectedRows.map(\.id)
        applyRows(newRows, changed: changed)
        completePendingAdvance(selectionOnEntry: selectionOnEntry)
    }

    private func applyRows(_ newRows: [AgentInboxRow], changed: AgentsBoardChangeSet) {
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
        let next = display(from: newRows)
        // P4.7: the identity sequence is compared over the DRAWN items, not over the
        // agent rows — the shelf header is a row in this table, and a snooze that
        // changed the count in it (or brought the header into existence at all) has
        // changed the list even when every agent row is where it was.
        guard next.map(\.identity) == items.map(\.identity) else {
            render(next)
            return
        }
        let disclosureMoved = previousParents.symmetricDifference(parentsWithChildren)
        let previous = rows
        setItems(next)
        let indexes = IndexSet(rows.indices.filter {
            changed.touched.contains(rows[$0].id) || rows[$0] != previous[$0]
                || disclosureMoved.contains(rows[$0].id)
        }.compactMap(tableRow(forRowIndex:)))
        guard !indexes.isEmpty else { return }
        // P3.7: a lifecycle move changes the row's VARIANT, and a variant is a
        // different height. `reloadData(forRowIndexes:)` re-asks for the row's VIEW
        // and not for its height, so without this a row that just settled would
        // draw its one collapsed line into a card-sized slot — and keep the slot.
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        // P3.11: an incremental apply keeps the selection (the rows are the same agents
        // in the same order), so what a selected row may DO can change under a bar that
        // is already up — an agent that just started working must lose Archive.
        updateBulkBar()
        // P3.13: the rows are the same agents, so an open rename survives an
        // incremental push — but the cell under it was just rebuilt.
        repositionRenameField()
    }

    // MARK: - Scope (P3.8)

    /// The rows this scope leaves on screen, in the frozen order. Filter FIRST, then
    /// sort: the two commute (filtering a permutation and permuting a subset give the
    /// same list), and this way `InboxSort` only ever nests the children it can see.
    /// What the table draws for this push: filtered, sorted, folded, then split into
    /// the three sections with the shelf header between the second and the third.
    ///
    /// THE SECTIONS ARE COMPUTED LAST, on the rows that survived the group folds
    /// (P2D.4). A shelf count taken before them would report a snoozed child that is
    /// already hidden under its parent, and the header would say it is holding a row
    /// that unfolding it does not produce.
    private func display(from newRows: [AgentInboxRow]) -> [InboxListItem] {
        let sorted = InboxSort.sortForInbox(
            rows: InboxScope.filter(rows: newRows, scope: scope, openAgentId: openAgentId))
        // P2D.4: measured on the SORTED list, before the fold — a collapsed parent
        // has no children on screen, and a triangle derived from what is on screen
        // would vanish the moment you used it.
        parentsWithChildren = InboxSort.parentIds(in: sorted)
        // P2D.5: same list, same moment, same reason.
        rollupsByParent = InboxSort.rollups(in: sorted)
        let visible = InboxSort.visibleRows(sorted, collapsed: collapsedParents)
        // P4.7. `clock()` and not `Date()`: the same injection point a parked row's
        // "in 25m" is read from, so a card whose snooze expires between two renders
        // cannot make a committed baseline flap.
        let parts = InboxSort.partition(rows: visible, now: clock())
        var built = parts.active.map(InboxListItem.agent)
        // NO HEADER FOR AN EMPTY SHELF: "Snoozed (0)" is a line of chrome about
        // nothing, and it would take a row's worth of a 320pt sidebar to say it.
        if parts.shelfCount > 0 {
            built.append(.shelfHeader(count: parts.shelfCount, isExpanded: shelfExpanded))
            if shelfExpanded {
                built.append(contentsOf: parts.snoozed.map(InboxListItem.agent))
            }
        }
        // P4.8: history is PAGED, and the page is taken last — on the rows that
        // survived the scope, the folds and the section split, so the footer's count
        // is of rows that pressing it really does produce.
        let page = InboxSort.pageSettled(
            parts.settled, limit: settledLimit, openAgentId: openAgentId)
        built.append(contentsOf: page.shown.map(InboxListItem.agent))
        if page.hasMore {
            built.append(.settledMore(hidden: page.hidden))
        }
        return built
    }

    // MARK: - The settled tail (P4.8)

    /// Show the next page of history.
    ///
    /// A FULL RE-RENDER with the selection and hover dropped, exactly like
    /// `toggleShelf` and for the same reason: rows appear, so the identity sequence
    /// changed and every index the old list handed out now names a different agent.
    func expandSettledTail() {
        settledLimit += InboxSort.settledPageStep
        tableView.deselectAll(nil)
        selectedRowsForEmphasis = IndexSet()
        hoveredRow = -1
        render(display(from: allRows))
    }

    // MARK: - The shelf (P4.7)

    /// Open or close the shelf.
    ///
    /// A FULL RE-RENDER for the reason `toggleCollapse` records: opening the shelf
    /// adds rows, so the identity sequence changed and a partial reload against a
    /// shifted array would repaint one agent's row with another's. Selection and
    /// hover go with it, because their indexes belong to the list that just went
    /// away and a bulk action must never reach a row you cannot see.
    func toggleShelf() {
        shelfExpanded.toggle()
        tableView.deselectAll(nil)
        selectedRowsForEmphasis = IndexSet()
        hoveredRow = -1
        render(display(from: allRows))
    }

    // MARK: - The two index spaces (P4.7)

    /// Take a new drawn model, and build the two index maps WITH it — one
    /// assignment, so `rows`, `items` and the mapping between them cannot be left
    /// disagreeing by a path that updated only some of them.
    private func setItems(_ next: [InboxListItem]) {
        items = next
        rows = next.compactMap(\.agentRow)
        rowIndexByTableRow = []
        tableRowByRowIndex = []
        rowIndexByTableRow.reserveCapacity(next.count)
        for (tableRow, item) in next.enumerated() {
            guard item.agentRow != nil else {
                rowIndexByTableRow.append(nil)
                continue
            }
            rowIndexByTableRow.append(tableRowByRowIndex.count)
            tableRowByRowIndex.append(tableRow)
        }
    }

    /// Where agent row `index` sits in the table, or nil if it is not on screen.
    private func tableRow(forRowIndex index: Int) -> Int? {
        tableRowByRowIndex.indices.contains(index) ? tableRowByRowIndex[index] : nil
    }

    /// Which agent row table row `tableRow` is, or nil for the shelf header, for a
    /// click below the last row (`clickedRow` is -1) and for anything out of range.
    private func rowIndex(forTableRow tableRow: Int) -> Int? {
        rowIndexByTableRow.indices.contains(tableRow) ? rowIndexByTableRow[tableRow] : nil
    }

    /// The header's table row, or nil when the shelf is empty and draws nothing.
    ///
    /// Matched on the CASE and not on "the first row that is not an agent" (P4.8
    /// puts a second such row at the bottom of the list): a list with a paged tail
    /// and no shelf would otherwise report the footer's row as the heading's.
    private var shelfHeaderTableRow: Int? {
        items.firstIndex { if case .shelfHeader = $0 { return true } else { return false } }
    }

    /// The settled tail's footer row, or nil when nothing is being held back.
    private var settledMoreTableRow: Int? {
        items.firstIndex { if case .settledMore = $0 { return true } else { return false } }
    }

    /// What the table draws at this row, or nil for an index outside the list —
    /// including the -1 AppKit reports for a click below the last row.
    private func item(at tableRow: Int) -> InboxListItem? {
        items.indices.contains(tableRow) ? items[tableRow] : nil
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
        selectedRowsForEmphasis = IndexSet()
        hoveredRow = -1
        render(display(from: allRows))
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
        selectedRowsForEmphasis = IndexSet()
        hoveredRow = -1
        updateScopeMenu()
        render(display(from: allRows))
        if notify { onScopeChange?(next) }
    }

    @objc private func scopePicked(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        // P3.14: the management block shares the popup's action rather than carrying
        // its own. A popup sends BOTH its own action and a selected item's action, so
        // an item-level selector would have to be reconciled with this one; a tag
        // range is the same dispatch `scopeEntries` already uses.
        if let action = AgentInboxView.managementAction(forTag: tag) {
            // The scope did not change, so the button must not read as if it had:
            // `pullsDown: false` titles the popup with whatever was last selected.
            restoreScopeSelection()
            onWorkspaceManagementAction?(action)
            return
        }
        guard scopeEntries.indices.contains(tag) else { return }
        setScope(scopeEntries[tag], notify: true)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// Which workspace verbs are available. Told by the host on every reload, since
    /// both answers come off the registry (`rename` needs a target at all; `delete`
    /// additionally needs a second workspace to fall back to).
    func setWorkspaceManagement(canRename: Bool, canDelete: Bool) {
        guard canRename != canRenameWorkspace || canDelete != canDeleteWorkspace else { return }
        canRenameWorkspace = canRename
        canDeleteWorkspace = canDelete
        applyManagementEnablement()
    }

    private static let managementTagBase = 1_000_000

    private static func tag(for action: WorkspaceManagementAction) -> Int {
        managementTagBase + (WorkspaceManagementAction.allCases.firstIndex(of: action) ?? 0)
    }

    private static func managementAction(forTag tag: Int) -> WorkspaceManagementAction? {
        let index = tag - managementTagBase
        guard index >= 0, WorkspaceManagementAction.allCases.indices.contains(index) else { return nil }
        return WorkspaceManagementAction.allCases[index]
    }

    private func applyManagementEnablement() {
        managementItems[.create]?.isEnabled = true
        managementItems[.rename]?.isEnabled = canRenameWorkspace
        managementItems[.delete]?.isEnabled = canDeleteWorkspace
    }

    private func restoreScopeSelection() {
        guard let index = scopeEntries.firstIndex(of: scope) else { return }
        scopePopUp.selectItem(withTag: index)
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
                // Explicit, because `autoenablesItems` is turned off below.
                item.isEnabled = true
                menu.addItem(item)
            }
            // P3.14: the workspace verbs, below a separator, so the menu reads as
            // "which agents" first and "this workspace" second.
            //
            // `autoenablesItems = false` IS LOAD-BEARING, for the reason P3.12 wrote
            // down for `rowMenu`: left at AppKit's default, `NSMenu.update()` re-derives
            // every item's enablement from whether a target responds to its action just
            // before the menu is drawn, so the disabled Delete on a one-workspace
            // registry would come back up live. The scope items are enabled explicitly
            // here because turning the flag off means nothing enables them for us.
            menu.autoenablesItems = false
            menu.addItem(.separator())
            managementItems.removeAll()
            for action in WorkspaceManagementAction.allCases {
                let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                item.tag = AgentInboxView.tag(for: action)
                menu.addItem(item)
                managementItems[action] = item
            }
            applyManagementEnablement()
            scopePopUp.menu = menu
        }
        restoreScopeSelection()
    }

    /// The empty state, and WHICH empty state. An inbox with agents in it that are
    /// all filtered out is not empty, and saying "No agents yet" there would be the
    /// list lying about the thing the user just did.
    ///
    /// P3.16 adds the third reading, and the precedence is not arbitrary: `allRows` is
    /// what the host's row source produced, so if THAT is empty the scope cannot be
    /// the cause and the honest question is whether anything was excluded — an inbox
    /// with no managed agents in front of a running terminal agent says so.
    private func updateEmptyState() {
        if !allRows.isEmpty {
            emptyLabel.stringValue = AgentInboxView.scopedEmptyMessage
        } else if excludedTerminalAgentCount > 0 {
            emptyLabel.stringValue = AgentInboxView.terminalHostedEmptyMessage
        } else {
            emptyLabel.stringValue = AgentInboxView.emptyMessage
        }
        // P4.7: `items`, not `rows` — a list holding nothing but a collapsed shelf
        // still draws its heading, and "No agents in this scope" underneath a
        // `Snoozed (2)` line would be the list contradicting itself.
        emptyLabel.isHidden = !items.isEmpty
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// P3.7: settled and snoozed collapse, everything else is a full card. The
    /// height is asked of the ROW's variant and of nothing else — the list may not
    /// decide a `ready` or `failed` agent has earned less room, which is the
    /// density mistake the rule exists to forbid.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let model = item(at: row)?.agentRow else { return AgentInboxView.shelfHeaderHeight }
        return AgentInboxView.height(for: model.variant)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The shelf header is a HEADING, not a row you can act on. Unselectable, so it
    /// cannot end up in a multi-selection (P3.11) that a bulk action then tries to
    /// apply to a section, and so arrow-keying past it does not clear the bar.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        item(at: row)?.agentRow != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = item(at: row) else { return nil }
        guard let model = item.agentRow else {
            switch item {
            case .shelfHeader(let count, let isExpanded):
                let header = shelfHeaderCell ?? AgentInboxShelfHeaderView()
                header.onToggle = { [weak self] in self?.toggleShelf() }
                header.apply(count: count, isExpanded: isExpanded)
                shelfHeaderCell = header
                return header
            // P4.8
            case .settledMore(let hidden):
                let footer = settledMoreCell ?? AgentInboxSettledMoreView()
                footer.onPress = { [weak self] in self?.expandSettledTail() }
                footer.apply(hidden: hidden)
                settledMoreCell = footer
                return footer
            case .agent:
                return nil
            }
        }
        // P4.7: the ROW's index, not the table's — the jump chord on this cell is
        // "the Nth agent", and a heading is not one of them. NO `?? 0` FALLBACK: the
        // conversion is total for an `.agent` item because `setItems` builds both
        // maps in one pass, so a nil here means the maps disagree with `items` — and
        // an empty row is a thing the blankness floor can see, where a hint pill
        // quietly drawn on the wrong row is not. (Raised in cross-review.)
        guard let index = rowIndex(forTableRow: row) else { return nil }
        cellBuildCountForQA += 1
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
            // P2D.5: handed over for every parent; the cell shows it only while the
            // group is folded, which is the one moment the children are not on
            // screen to speak for themselves.
            rollup: rollupsByParent[model.id],
            // P3.11: EVERY selected row is outlined, not just the last one clicked —
            // `selectedRow` is one index and a range is a set.
            isSelected: tableView.selectedRowIndexes.contains(row),
            isInteracting: interacting,
            now: clock()
        )
        // P3.10: the hint is set AFTER `apply` and through its own call, because it
        // is an overlay and not part of the row's content — `apply` paints what the
        // agent IS, and a pill is a thing about the keyboard.
        cell.showJumpHint(jumpHintsVisible ? AgentInboxView.jumpHintText(forRowIndex: index) : nil)
        cellsByRow[row] = cell
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection clears recession on the row you moved onto and restores it on
        // the one you left, so exactly those two are redrawn — the emphasis is
        // computed when the cell is built. Reloading the whole table here would
        // undo the incremental refresh `apply(rows:changed:)` exists for.
        // P3.11: the rows that MOVED are the symmetric difference of the two
        // selections — with a range selected, a single index cannot name them.
        let previous = selectedRowsForEmphasis
        selectedRowsForEmphasis = tableView.selectedRowIndexes
        redraw(tableRows: Array(previous.symmetricDifference(tableView.selectedRowIndexes)))
        updateBulkBar()
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.9-reveal-on-click.md
    @objc private func rowClicked(_ sender: Any?) {
        // P3.11: a shift- or ⌘-click is a SELECTION gesture, not navigation. Without
        // this, building a range would reveal — and revealing switches workspace and
        // focuses a tile (P3.9), so triaging six agents would drag the canvas through
        // all six on the way to acting on them.
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        guard AgentInboxView.revealsOnClick(modifiers: modifiers) else { return }
        // P4.7: `clickedRow` is a TABLE row, and the shelf header is one of those —
        // `rowIndex(forTableRow:)` answers nil for it, so clicking the heading folds
        // the shelf (its own button) and never reveals an agent.
        guard let index = rowIndex(forTableRow: tableView.clickedRow) else { return }
        reveal(rowAt: index)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
    /// Whether a click carrying these modifiers means "take me to this agent".
    ///
    /// The two that don't are exactly the two the multi-selection is built with. It is
    /// a test on the SET rather than on `isEmpty` so ⌥-click and ⌃-click — neither of
    /// which selects anything — still reveal, the same as a bare click.
    static func revealsOnClick(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.shift, .command]).isEmpty
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
        guard let tableRow = tableRow(forRowIndex: index) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
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
        // The jumpable rows are the first N AGENT rows, mapped into the table — a
        // shelf header between them is not a row you can jump to.
        redraw(tableRows: (0..<InboxJump.maximumRows).compactMap(tableRow(forRowIndex:)))
    }

    // MARK: - Inline rename (P3.13)

    /// The second click of a plain double-click. Only the NAME opens a rename: a
    /// double-click anywhere else on the row is left alone, so the meta line, the
    /// branch line and the empty space keep meaning "reveal" (the zone header /
    /// zone body split `--zone-rename-inline-check` already draws).
    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        // Any modifier means something else: ⇧/⌘ are the selection gestures
        // (`revealsOnClick`), and a modified double-click must not start editing a
        // name in the middle of building a range.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
        guard let index = rowIndex(forTableRow: tableView.clickedRow),
              let cell = cellForRow(index) else { return }
        doubleClick(rowAt: index, pointInCell: cell.convert(event.locationInWindow, from: nil))
    }

    /// The routing half of the gesture, taking the point in the CELL's coordinates
    /// rather than an `NSEvent` — a headless check can call this, and it is the same
    /// code the real double-click runs (`rowDoubleClicked` only unpacks the event).
    @discardableResult
    func doubleClick(rowAt index: Int, pointInCell point: NSPoint) -> Bool {
        guard rows.indices.contains(index), let cell = cellForRow(index),
              cell.titleFrame.contains(point) else { return false }
        return beginRename(rowAt: index)
    }

    /// Open the inline rename for this agent. Returns false for an agent that is not
    /// on screen, or whose row has no cell to sit over.
    @discardableResult
    func beginRename(agentId: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == agentId }) else { return false }
        return beginRename(rowAt: index)
    }

    @discardableResult
    private func beginRename(rowAt index: Int) -> Bool {
        // A rename already open on another row commits, the way clicking away from it
        // would — there is one field, so opening a second is leaving the first.
        endRename(commit: true)
        guard let field = installRenameField(rowAt: index) else { return false }
        isOpeningRename = true
        window?.makeFirstResponder(field)
        field.selectText(nil)
        isOpeningRename = false
        return true
    }

    /// Build + place the field over the row's title label and record what is being
    /// renamed. Extracted so the geometry, the styling and the state have one source
    /// of truth (`CanvasNSView.installZoneRenameField`'s precedent).
    private func installRenameField(rowAt index: Int) -> NSTextField? {
        guard rows.indices.contains(index), let cell = cellForRow(index) else { return nil }
        let frame = cell.convert(cell.titleFrame, to: self)
        guard frame.width > 1, frame.height > 1 else { return nil }
        let field = NSTextField(frame: frame.insetBy(dx: -Space.xs, dy: -Space.xs))
        field.stringValue = rows[index].title
        field.font = .token(.title)
        // The same pair the zone's field uses, and a documented one (P1.3): a field
        // floating over the list is an `overlay` surface carrying `textPrimary`.
        field.textColor = TextToken.textPrimary.color.nsColor(in: self)
        field.backgroundColor = SurfaceToken.overlay.color.nsColor(in: self)
        field.drawsBackground = true
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.wantsLayer = true
        field.layer?.cornerRadius = Radius.card
        field.layer?.masksToBounds = true
        field.layer?.borderWidth = 1
        // `borderStrong`, the focus/selection line — an open editor is the one thing
        // on this list with the keyboard, and `border` is what every row already draws.
        field.layer?.borderColor = LineToken.borderStrong.color.cgColor(in: self)
        field.delegate = self
        field.setAccessibilityIdentifier("ContinuumAgentInboxRenameField")
        addSubview(field, positioned: .above, relativeTo: nil)
        renameField = field
        renamingRowId = rows[index].id
        return field
    }

    /// Close an open rename. `commit: true` is Enter and focus-loss, `false` is Esc.
    ///
    /// The field is torn down BEFORE the callback fires: the host answers a rename by
    /// pushing rows back, which reloads this list, and a field still on screen at that
    /// point would be floating over whatever row landed underneath it.
    ///
    /// An empty or whitespace-only name KEEPS THE PREVIOUS ONE — the same rule
    /// `applyZoneRename` holds, and the reason nothing here needs a "delete the name"
    /// case: an agent with no name is a row you cannot find again.
    private func endRename(commit: Bool) {
        guard let rowId = renamingRowId, let field = renameField else { return }
        let typed = field.stringValue
        // STATE FIRST, THEN THE VIEW: removing a field that holds the field editor
        // posts `controlTextDidEndEditing` SYNCHRONOUSLY, so with the state still set
        // the delegate re-enters here and commits the same name a second time
        // (measured: `Enter commits the typed name once — got ["Migration reviewer",
        // "Migration reviewer"]`). Cleared first, that re-entrant notification finds no
        // rename to end.
        renameField = nil
        renamingRowId = nil
        field.removeFromSuperview()
        guard commit else { return }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != rows.first(where: { $0.id == rowId })?.title else { return }
        onRenameRow?(rowId, trimmed)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endRename(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Ignore the transient end `selectText(_:)` posts while the field is still
        // being installed (see `isOpeningRename`).
        guard !isOpeningRename, (obj.object as? NSTextField) === renameField else { return }
        endRename(commit: true)
    }

    /// Follow the row an open rename is on. An incremental apply rebuilds the cell
    /// under the field and can change its height (P3.7's variants), and the field is
    /// a subview of the LIST, not of that cell — so it has to be told. Reads the
    /// realised cells only: a row that scrolled out has no frame to follow.
    private func repositionRenameField() {
        guard let field = renameField, let rowId = renamingRowId,
              let index = rows.firstIndex(where: { $0.id == rowId }),
              let tableRow = tableRow(forRowIndex: index),
              let cell = cellsByRow[tableRow] else { return }
        field.frame = cell.convert(cell.titleFrame, to: self).insetBy(dx: -Space.xs, dy: -Space.xs)
    }

    /// The cell drawn for a row, building it if the table has not laid it out yet —
    /// a rename needs the label's real frame, and an unrealised row has none.
    private func cellForRow(_ index: Int) -> AgentInboxRowCell? {
        guard let tableRow = tableRow(forRowIndex: index) else { return nil }
        if let cell = cellsByRow[tableRow] { return cell }
        return tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: true) as? AgentInboxRowCell
    }

    // MARK: - Bulk actions (P3.11)

    /// How many rows have to be selected before the bar appears. TWO, because one
    /// selected row is not a bulk anything — a single row's actions belong on its own
    /// context menu (P3.12), and a bar that appeared on every arrow-key press would
    /// sit over the list for the whole of ordinary keyboard navigation.
    static let minimumBulkSelection = 2

    /// The selected rows, IN SCREEN ORDER (the frozen one, P3.4) rather than in the
    /// order they were clicked: the actions apply to a set, and the ids handed to the
    /// host must not depend on which end of a range you started from.
    private var selectedRows: [AgentInboxRow] {
        tableView.selectedRowIndexes.sorted().compactMap { item(at: $0)?.agentRow }
    }

    /// Show, hide and re-populate the bar for the current selection.
    private func updateBulkBar() {
        let selected = selectedRows
        guard selected.count >= AgentInboxView.minimumBulkSelection else {
            bulkBar.hide()
            return
        }
        // NO HANDLER, NO MENU — and, since P3.15, no handler FOR THIS ACTION, no item.
        // A control that answers a click with nothing is worse than no control (found
        // in cross-review of P3.11, which pointed out the shipped sidebar would
        // otherwise offer five silent no-ops). With the handler unset the bar still
        // reports the selection and what a destructive action would leave; with it set,
        // the bar offers exactly the intersection of "every selected row can take it"
        // (P3.11's AND, untouched) and "the host performs it".
        bulkBar.show(
            offeredBulkActions(for: selected),
            selectionCount: selected.count,
            keptBranches: InboxBulkAction.keptBranches(in: selected))
    }

    /// Hand the host an action and the agents it lands on.
    ///
    /// The availability is RE-RESOLVED here rather than trusted from the menu: the bar
    /// is rebuilt on every selection change, but a push can change a row's state
    /// (`apply(rows:changed:)` repaints in place without touching the selection) while
    /// the menu is open — and an action that became unavailable under an open menu must
    /// not fire.
    private func performBulkAction(_ action: InboxBulkAction) {
        let selected = selectedRows
        guard selected.count >= AgentInboxView.minimumBulkSelection,
              offeredBulkActions(for: selected).contains(action)
        else { return }
        // P4.10: armed BEFORE the host runs, because a synchronous host pushes the new
        // rows from inside this call — by the time it returns the affected rows have
        // already left the places the advance is measured from.
        if AgentInboxView.advancesSelection(action) { armAdvance(targetIds: selected.map(\.id)) }
        onBulkAction?(action, selected.map(\.id))
        // THE ACTION IS OVER. Whatever it did, it did inside that call — the host
        // performs and re-pushes synchronously — so an advance still armed here is one
        // whose filing never happened (a cancelled Delete, a refusal, a partial run) and
        // it must not be left to fire on some later, unrelated push.
        pendingAdvance = nil
    }

    /// What the bar may offer this selection: P3.11's availability intersection, then
    /// P3.15's capability gate. One function so the bar it draws and the action it
    /// performs cannot come apart.
    private func offeredBulkActions(for selected: [AgentInboxRow]) -> [InboxBulkAction] {
        guard onBulkAction != nil else { return [] }
        return InboxBulkAction.available(for: selected, rollups: rollupsByParent)
            .filter { wiredBulkActions.contains($0) }
    }

    // MARK: - Row context menu (P3.12)

    /// The agents a right-click acts on.
    ///
    /// THE PACKET'S RULE: a click INSIDE a multiple selection acts on the selection —
    /// that is the gesture you have already made, and a menu that quietly dropped it
    /// back to one row would undo it. A click anywhere else acts on the one row under
    /// the mouse, whatever is selected elsewhere in the list.
    ///
    /// Empty for a click below the last row (`clickedRow` is -1 there), which is what
    /// leaves the menu with no items — AppKit shows nothing for an empty menu, so
    /// right-clicking the background is a no-op rather than a menu about nobody.
    private func targetRows(forClickedRow clicked: Int) -> [AgentInboxRow] {
        guard rows.indices.contains(clicked), let tableRow = tableRow(forRowIndex: clicked) else {
            return []
        }
        let selection = tableView.selectedRowIndexes
        guard selection.count > 1, selection.contains(tableRow) else { return [rows[clicked]] }
        return selectedRows
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildRowMenu(for: targetRows(forClickedRow: rowIndex(forTableRow: tableView.clickedRow) ?? -1))
    }

    /// Fill `rowMenu` in for these agents: which items belong at all
    /// (`InboxRowAction.menuItems`), what each is called (counted for a selection) and
    /// whether it is live — with the reason in the tooltip when it is not.
    private func rebuildRowMenu(for targets: [AgentInboxRow]) {
        rowMenuTargetIds = targets.map(\.id)
        rowMenuActions = InboxRowAction.menuItems(for: targets)
        rowMenu.removeAllItems()
        for (index, action) in rowMenuActions.enumerated() {
            let item = NSMenuItem(
                title: action.title(forCount: targets.count),
                action: #selector(rowMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            let reason = action.disabledReason(
                for: targets, isWired: isWired(action), rollups: rollupsByParent)
            item.isEnabled = reason == nil
            item.toolTip = reason
            rowMenu.addItem(item)
        }
    }

    @objc private func rowMenuPicked(_ sender: NSMenuItem) {
        guard rowMenuActions.indices.contains(sender.tag) else { return }
        performRowAction(rowMenuActions[sender.tag])
    }

    /// Hand the host an action and the agents it lands on.
    ///
    /// The targets are RE-READ from the current rows and the enablement RE-RESOLVED, for
    /// the reason `performBulkAction` records: a push repaints rows in place without
    /// touching the selection (`apply(rows:changed:)`), so an agent can start working —
    /// losing Delete — while the menu is open in front of you. An agent that left the
    /// list entirely drops out of the targets, and an action that then has no agents left
    /// does nothing.
    private func performRowAction(_ action: InboxRowAction) {
        let targets = rowMenuTargetIds.compactMap { id in rows.first { $0.id == id } }
        guard action.disabledReason(
            for: targets, isWired: isWired(action), rollups: rollupsByParent) == nil else { return }
        switch action {
        case .openInTile:
            guard let first = targets.first else { return }
            onRevealRow?(first.id)
        case .settle, .unsettle, .snooze, .wake, .markUnread, .rename, .stopAgent,
             .archive, .delete:
            // P4.10: armed before the host runs, for the reason `performBulkAction`
            // records — a synchronous host has already re-pushed by the time it returns.
            if AgentInboxView.advancesSelection(action) { armAdvance(targetIds: targets.map(\.id)) }
            onRowAction?(action, targets.map(\.id))
            // Retired here for the reason `performBulkAction` records: an advance the
            // action did not land is an advance that never happens.
            pendingAdvance = nil
        }
    }

    /// Whether the host can perform this action at all. `openInTile` rides P3.9's
    /// existing callback; everything else needs `onRowAction` AND a host that named
    /// this action in `wiredRowActions` (P3.15) — one gate for all nine is what made
    /// wiring Delete mean also offering a Snooze that goes nowhere.
    private func isWired(_ action: InboxRowAction) -> Bool {
        switch action {
        case .openInTile: return onRevealRow != nil
        case .settle, .unsettle, .snooze, .wake, .markUnread, .rename, .stopAgent,
             .archive, .delete:
            return onRowAction != nil && wiredRowActions.contains(action)
        }
    }

    /// P3.15, for the checks: the shipped list's own answer, so "Snooze is still
    /// greyed" is asserted against the gate the menu uses rather than a copy of it.
    func isRowActionWiredForQA(_ action: InboxRowAction) -> Bool { isWired(action) }
    func isBulkActionWiredForQA(_ action: InboxBulkAction) -> Bool {
        onBulkAction != nil && wiredBulkActions.contains(action)
    }

    // MARK: - Post-action advance (P4.10)

    /// Which verbs move you on.
    ///
    /// Settle, snooze and archive FILE the row: the agent leaves the block you are
    /// working through, so standing still would leave the cursor on something that is
    /// no longer where you left it. `delete` is in with archive because on this app it
    /// IS archive — both verbs run `archiveAgentsFromInbox`, and they differ in what
    /// the person is told, not in what happens to the row.
    ///
    /// The rest do not: `unsettle` and `wake` bring a row BACK to where you are,
    /// `markUnread`, `rename` and `stopAgent` leave it exactly where it was, and
    /// `openInTile` is a navigation you just made by hand.
    static func advancesSelection(_ action: InboxRowAction) -> Bool {
        switch action {
        case .settle, .snooze, .archive, .delete: return true
        case .openInTile, .unsettle, .wake, .markUnread, .rename, .stopAgent: return false
        }
    }

    /// The bar's half of the same rule, over its own five.
    static func advancesSelection(_ action: InboxBulkAction) -> Bool {
        switch action {
        case .settle, .snooze, .archive, .delete: return true
        case .markUnread: return false
        }
    }

    /// Where a dispatched action will leave the cursor, captured at DISPATCH because
    /// that is the only moment the affected rows still have their places in the list.
    private struct PendingAdvance {
        /// The affected rows AS THEY WERE — which is also the selection, since nothing
        /// arms unless the two are the same (`armAdvance`). Their lifecycles at dispatch
        /// are what completion compares against.
        let targets: [AgentInboxRow]
        /// Candidate landings in preference order: the rows AFTER the whole affected
        /// set, nearest first, then the rows before it, nearest first.
        let candidateIds: [UUID]
    }

    private var pendingAdvance: PendingAdvance?

    /// Work out where this action should leave the cursor, and hold it until the push
    /// that carries the action's effect arrives.
    ///
    /// ONLY WHAT YOU ARE ON MOVES YOU. The advance arms only when the action's targets
    /// ARE the selection: a right-click on a row outside the selection acts on that row
    /// (P3.12's rule) while you are still reading another one, and moving the cursor off
    /// what you are reading because you filed something else is exactly the yank the goal
    /// forbids. (Raised in cross-review.) A consequence worth stating: with nothing
    /// selected, nothing advances — there is no cursor to move.
    ///
    /// PAST THE WHOLE AFFECTED SET (the packet's watch-out): the candidates start after
    /// the LAST selected row, not after the first, so settling three rows does not land
    /// you on the second of them. Rows between the first and the last that were not
    /// affected are inside the block and skipped with it.
    private func armAdvance(targetIds: [UUID]) {
        pendingAdvance = nil
        guard !targetIds.isEmpty, targetIds == selectedRows.map(\.id) else { return }
        let positions = targetIds.compactMap { id in rows.firstIndex { $0.id == id } }.sorted()
        guard let first = positions.first, let last = positions.last else { return }
        pendingAdvance = PendingAdvance(
            targets: positions.map { rows[$0] },
            candidateIds: rows[(last + 1)...].map(\.id) + rows[..<first].map(\.id).reversed())
    }

    /// Land the advance armed at dispatch, on the push that carries the filing.
    ///
    /// NOT NECESSARILY THE FIRST PUSH. The stream runs under everything: a token
    /// arriving for some other agent — or, around a Delete, arriving while the
    /// confirmation sheet is still up — is a push that says nothing about the action,
    /// and spending the advance on it would mean the real one lands with nothing armed.
    /// So an unrelated push leaves the advance where it is, and `performRowAction` /
    /// `performBulkAction` retire it when the action itself is over. (Raised in
    /// cross-review.)
    private func completePendingAdvance(selectionOnEntry: [UUID]) {
        guard let pending = pendingAdvance else { return }
        // VALIDATED AT COMPLETION, not at dispatch — the packet's one hard rule. If the
        // selection moved while the action was in flight, the person is somewhere they
        // chose to be and this may not take them anywhere else. That is a decision, not
        // a wait: the advance is dropped rather than left armed for the next push.
        //
        // THE ROUTE IS COVERED BY THIS SAME LINE, and measured rather than assumed
        // (cross-review asked for a second check on `openAgentId`): the route only ever
        // changes through that property, whose `didSet` re-renders the list — and a
        // render empties the table's selection. So a person who leaves for another
        // agent's tile mid-action arrives here with a selection that no longer matches,
        // and is dropped by the guard below. A separate route comparison would be a
        // second rule nothing could witness.
        guard selectionOnEntry == pending.targets.map(\.id) else {
            pendingAdvance = nil
            return
        }
        // …and only if the action REALLY FILED THEM, all of them.
        //
        // Filed is tested on the LIFECYCLE and on presence, not on the whole row's
        // value: every verb that advances (settle / snooze / archive / delete) either
        // takes the row off the list or moves it to another section, while a streamed
        // token arriving in the same push changes a row's elapsed time and nothing else.
        // A value comparison would read that churn as "the action completed" and advance
        // off a Delete the person had just cancelled. (Raised in cross-review.)
        //
        // ALL of them, not any: a partial archive leaves the rows it could not take
        // where they are, and advancing past the whole set would move the cursor off a
        // row that is still sitting there unfiled.
        guard pending.targets.allSatisfy({ target in
            guard let current = rows.first(where: { $0.id == target.id }) else { return true }
            return current.lifecycle != target.lifecycle
        }) else { return }
        pendingAdvance = nil
        guard let landing = pending.candidateIds.lazy.compactMap({ id in
            self.rows.firstIndex { $0.id == id }.flatMap(self.tableRow(forRowIndex:))
        }).first else {
            // Nothing before it and nothing after it: the list has run out, and no
            // selection is the honest answer rather than holding a row that is gone.
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: landing), byExtendingSelection: false)
        tableView.scrollRowToVisible(landing)
    }

    /// P4.10, for the checks: whether an advance is waiting on its push.
    var isAdvanceArmedForQA: Bool { pendingAdvance != nil }

    /// P3.5's `isInteracting`: hover, selection, or keyboard-active. The last two
    /// are one test rather than two, because arrow-key navigation in an
    /// `NSTableView` IS a selection move — a keyboard-active row and the selected
    /// row are the same row by construction.
    private func isInteracting(row: Int) -> Bool {
        row == hoveredRow || tableView.selectedRowIndexes.contains(row)
    }

    /// Rebuild the cells of just these rows, ignoring any that are not on screen.
    private func redraw(tableRows indexes: [Int]) {
        let touched = IndexSet(indexes.filter { items.indices.contains($0) })
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
        redraw(tableRows: [previous, row])
    }

    // MARK: - QA

    /// How many AGENT rows the table is drawing. Measured off the table (P4.7 and
    /// P4.8 each add a row to it that is not an agent) rather than reported from
    /// `rows`, so it still witnesses that the model reached the screen.
    var rowCountForQA: Int {
        tableView.numberOfRows - items.filter { $0.agentRow == nil }.count
    }
    var rowIdsForQA: [UUID] { rows.map(\.id) }
    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The heading as RENDERED — its words and which way its triangle points — and
    /// nil when the shelf is holding nothing and draws no heading at all.
    var shelfHeaderTitleForQA: String? { shelfHeaderCell?.qaTitle }
    var shelfHeaderDisclosureForQA: String? { shelfHeaderCell?.qaDisclosureGlyph }
    var isShelfExpandedForQA: Bool { shelfExpanded }
    /// Where the heading sits in the table, so a check can assert it is BETWEEN the
    /// active block and the settled tail rather than merely present.
    var shelfHeaderTableRowForQA: Int? { shelfHeaderTableRow }
    /// The answer the shipped delegate gives AppKit for each table row. Asked
    /// directly, because `selectRowIndexes(_:byExtendingSelection:)` is programmatic
    /// and does NOT consult the delegate — the same limitation `isClickWiredForQA`
    /// records for `clickedRow`, so this is the only place the heading's
    /// unselectability can be witnessed headlessly.
    var selectableTableRowsForQA: [Bool] {
        (0..<tableView.numberOfRows).map { self.tableView(tableView, shouldSelectRow: $0) }
    }
    /// Open or close the shelf the way the user does — through the heading's own
    /// button, so the check exercises the wiring and not just `toggleShelf`.
    @discardableResult
    func clickShelfDisclosureForQA() -> Bool {
        shelfHeaderCell?.clickDisclosureForQA() ?? false
    }
    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// The footer as RENDERED, where it sits, and how far the tail has been paged —
    /// nil when history fits and no footer is drawn.
    var settledMoreTitleForQA: String? { settledMoreCell?.qaTitle }
    var settledMoreTableRowForQA: Int? { settledMoreTableRow }
    var settledLimitForQA: Int { settledLimit }
    /// Press it the way the user does — through the footer's own button, so the
    /// check exercises the wiring and not just `expandSettledTail`.
    @discardableResult
    func clickSettledMoreForQA() -> Bool {
        settledMoreCell?.clickForQA() ?? false
    }
    /// The footer's laid-out height, on the same terms as the heading's.
    var settledMoreHeightForQA: Double? {
        guard let tableRow = settledMoreTableRow else { return nil }
        return Double(tableView.rect(ofRow: tableRow).height - tableView.intercellSpacing.height)
    }
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
    /// The empty label as LAID OUT, so a message too long for the sidebar is a number
    /// that fails rather than a clipped sentence nobody measured (P3.16).
    var emptyMessageFrameForQA: NSRect { emptyLabel.frame }
    /// The height the message's words need at the width it was given. Compared with
    /// the frame's height, this is what catches a `maximumNumberOfLines` that
    /// truncates — AppKit reports no error for that, it just draws an ellipsis.
    /// How many lines the empty message NEEDS at `width`, against how many the label
    /// will draw. The pair is what catches silent truncation: AppKit reports nothing
    /// when `maximumNumberOfLines` is too low, it just draws an ellipsis.
    ///
    /// Measured off the STRING rather than by laying the view out at that width — a
    /// cell's own `cellSize` is capped by the same limit under test, so it would agree
    /// with any limit at all, and a 220pt `NSWindow` does not stay 220pt.
    func emptyMessageLineFitForQA(width: Double) -> (needed: Int, allowed: Int) {
        let attributed = NSAttributedString(
            string: emptyLabel.stringValue,
            attributes: [.font: emptyLabel.font ?? .token(.label)])
        func height(_ available: Double) -> Double {
            Double(attributed.boundingRect(
                with: NSSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let oneLine = height(.greatestFiniteMagnitude)
        guard oneLine > 0 else { return (0, 0) }
        let needed = Int((height(width) / oneLine).rounded(.up))
        let allowed = emptyLabel.maximumNumberOfLines == 0
            ? Int.max
            : emptyLabel.maximumNumberOfLines
        return (needed, allowed)
    }
    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// The popup as RENDERED — the titles AppKit is really showing and the one it
    /// has ticked — rather than `scopeEntries`, which would assert about the array
    /// the menu was built from and not about the menu.
    /// P3.14 put a second block in the same menu, so this is the SCOPE block only —
    /// the verbs have `workspaceManagementTitlesForQA`. Filtered by tag rather than
    /// by position, for the same reason the tags exist at all: a workspace and a
    /// project may share a title.
    var scopeTitlesForQA: [String] {
        (scopePopUp.menu?.items ?? [])
            .filter { !$0.isSeparatorItem && AgentInboxView.managementAction(forTag: $0.tag) == nil }
            .map(\.title)
            .filter { !$0.isEmpty }
    }
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
    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// The management block as RENDERED: the titles in the menu below the separator,
    /// in menu order, and the enablement AppKit would show — read after
    /// `NSMenu.update()`, because a check that only reads back the `isEnabled` this
    /// file set never sees the pass that used to re-enable a disabled item.
    var workspaceManagementTitlesForQA: [String] {
        guard let menu = scopePopUp.menu else { return [] }
        menu.update()
        return menu.items
            .filter { AgentInboxView.managementAction(forTag: $0.tag) != nil }
            .map(\.title)
    }

    func isWorkspaceManagementEnabledForQA(_ action: WorkspaceManagementAction) -> Bool {
        scopePopUp.menu?.update()
        return managementItems[action]?.isEnabled ?? false
    }

    /// Whether the separator really sits between the scopes and the verbs — the
    /// packet's "separated section", asserted on the menu rather than by eye.
    var isWorkspaceManagementSeparatedForQA: Bool {
        guard let items = scopePopUp.menu?.items,
              let firstManagement = items.firstIndex(where: { AgentInboxView.managementAction(forTag: $0.tag) != nil }),
              firstManagement > 0 else { return false }
        return items[firstManagement - 1].isSeparatorItem
    }

    /// Pick a workspace verb the way the user does — through the popup's own action,
    /// and only if the item is one AppKit would let them hit.
    @discardableResult
    func pickWorkspaceManagementForQA(_ action: WorkspaceManagementAction) -> Bool {
        guard isWorkspaceManagementEnabledForQA(action),
              scopePopUp.selectItem(withTag: AgentInboxView.tag(for: action)) else { return false }
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
        (0..<tableView.numberOfRows)
            .filter { rowIndex(forTableRow: $0) != nil }
            .map { Double(tableView.rect(ofRow: $0).height - tableView.intercellSpacing.height) }
    }
    /// The heading's laid-out height, on the same terms — P4.7's own row.
    var shelfHeaderHeightForQA: Double? {
        guard let tableRow = shelfHeaderTableRow else { return nil }
        return Double(tableView.rect(ofRow: tableRow).height - tableView.intercellSpacing.height)
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
              let tableRow = tableRow(forRowIndex: index),
              let cell = cellsByRow[tableRow] else { return false }
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
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
        // P4.7: through the table row and back, which is exactly what `rowClicked`
        // does with `clickedRow` — so a row sitting below the shelf's heading is
        // revealed through the same conversion the mouse goes through, rather than
        // by an agent index this accessor happened to already hold.
        guard let clicked = rowIndex(forTableRow: tableRow) else { return false }
        reveal(rowAt: clicked)
        return true
    }

    /// The table sends its single-click action to this view — the half of the click
    /// path `clickRowForQA` cannot execute.
    ///
    /// Measured: `NSTableView` reports the plain `action` as its `doubleAction` when
    /// none was set separately, so before P3.13 a double click called `rowClicked` a
    /// second time. It now has one of its own (`isDoubleClickWiredForQA`), and the
    /// FIRST click of a double click still reveals — revealing an agent you are
    /// already on is idempotent, so that is left alone rather than papered over.
    var isClickWiredForQA: Bool {
        (tableView.target as? AgentInboxView) === self
            && tableView.action == #selector(rowClicked(_:))
    }

    @discardableResult
    func selectRowForQA(id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
        return true
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
    /// Select a SET of rows, through the same `selectRowIndexes(byExtendingSelection:)`
    /// AppKit's own shift- and ⌘-click handling calls — the first id replaces the
    /// selection and the rest extend it, which is the sequence a range or a run of
    /// toggles leaves behind. What it cannot reproduce is the mouse tracking itself
    /// (`NSTableView.mouseDown` runs a modal loop until mouse-up, which has no place in
    /// a headless check), so the gestures stay AppKit's and everything downstream of the
    /// selection — emphasis, outline, the bar and its enablement — is the shipped path.
    @discardableResult
    func selectRowsForQA(ids: [UUID]) -> Bool {
        var extending = false
        for id in ids {
            guard let index = rows.firstIndex(where: { $0.id == id }),
                  let tableRow = tableRow(forRowIndex: index) else { return false }
            tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: extending)
            extending = true
        }
        return true
    }

    var selectedRowIdsForQA: [UUID] { selectedRows.map(\.id) }
    var isMultipleSelectionAllowedForQA: Bool { tableView.allowsMultipleSelection }
    /// Whether the bar is on screen, and what it is OFFERING — read off the rendered
    /// menu rather than recomputed from `InboxBulkAction.available`, which would assert
    /// the predicate against itself.
    var isBulkBarVisibleForQA: Bool { !bulkBar.isHidden }
    var bulkActionTitlesForQA: [String] { bulkBar.qaActionTitles }
    var bulkSelectionTextForQA: String { bulkBar.qaSelectionText }
    var bulkKeptBranchesTextForQA: String { bulkBar.qaKeptText }

    /// Choose a bulk action the way the user does — through the pull-down's own
    /// target/action, so the check exercises the wiring and not just
    /// `performBulkAction`.
    @discardableResult
    func pickBulkActionForQA(_ action: InboxBulkAction) -> Bool {
        bulkBar.pickForQA(action)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.12-row-context-menu.md
    /// The table really is the thing that shows the menu, and this view really is what
    /// fills it in — the half of the path a headless check cannot execute, since
    /// `NSTableView.clickedRow` is only set while AppKit dispatches a real right-click
    /// (the same limitation `isClickWiredForQA` records for the left one).
    var isRowMenuWiredForQA: Bool {
        tableView.menu === rowMenu && rowMenu.delegate === self && !rowMenu.autoenablesItems
    }
    /// Right-click a row: `nil` for the background below the last row, which goes
    /// through the shipped `menuNeedsUpdate` unchanged (`clickedRow` is -1 headlessly,
    /// which IS the background case). For a row, the index stands in for `clickedRow`
    /// and everything after it — the selection rule, the item set, the titles, the
    /// enablement — is the shipped path.
    @discardableResult
    func openRowMenuForQA(clickedRowId: UUID?) -> Bool {
        guard let clickedRowId else {
            menuNeedsUpdate(rowMenu)
            rowMenu.update()
            return true
        }
        guard let index = rows.firstIndex(where: { $0.id == clickedRowId }),
              let tableRow = tableRow(forRowIndex: index),
              let clicked = rowIndex(forTableRow: tableRow) else { return false }
        rebuildRowMenu(for: targetRows(forClickedRow: clicked))
        // WHAT APPKIT DOES JUST BEFORE IT DRAWS, and the reason it is here rather than in
        // `rebuildRowMenu`: `NSMenu.update()` is the auto-enabling pass, so without it a
        // check reads the `isEnabled` this code set and never the one AppKit would show.
        // Measured — with `autoenablesItems` left at its default, every enablement
        // assertion below stays green until this line runs.
        rowMenu.update()
        return true
    }
    /// Read off the MENU AppKit would show rather than from `rowMenuActions`, which
    /// would assert the array the menu was built from and not the menu.
    var rowMenuTitlesForQA: [String] { rowMenu.items.map(\.title) }
    var rowMenuEnabledForQA: [Bool] { rowMenu.items.map(\.isEnabled) }
    var rowMenuTooltipsForQA: [String] { rowMenu.items.map { $0.toolTip ?? "" } }
    /// Choose an item the way the user does — through the item's own target/action, and
    /// refusing a disabled one exactly as AppKit does (a disabled item's action is never
    /// sent), so a check cannot fire something the menu is greying out.
    @discardableResult
    func pickRowMenuItemForQA(_ action: InboxRowAction) -> Bool {
        guard let index = rowMenuActions.firstIndex(of: action),
              let item = rowMenu.items.first(where: { $0.tag == index }), item.isEnabled else {
            return false
        }
        rowMenuPicked(item)
        return true
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.13-inline-rename.md
    /// The table really is the thing that reports a double-click, and this view really
    /// is what answers it — the half of the gesture a headless check cannot execute,
    /// since `NSTableView.clickedRow` and `NSApp.currentEvent` are only set while
    /// AppKit dispatches a real click (the same limitation `isClickWiredForQA` records).
    var isDoubleClickWiredForQA: Bool {
        (tableView.target as? AgentInboxView) === self
            && tableView.doubleAction == #selector(rowDoubleClicked(_:))
            && tableView.doubleAction != tableView.action
    }
    /// Double-click a row ON ITS NAME (`onTitle: true`) or on the row's bottom-left
    /// corner, which is the meta line on a card and empty space on a parked row.
    /// Everything downstream — the hit test, the field, its delegate — is the shipped
    /// path; only the `NSEvent` is stood in for.
    @discardableResult
    func doubleClickRowForQA(id: UUID, onTitle: Bool) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index),
              // P4.7: the same table-row round trip `rowDoubleClicked` makes.
              let clicked = rowIndex(forTableRow: tableRow),
              let cell = cellForRow(clicked) else {
            return false
        }
        let point = onTitle
            ? NSPoint(x: cell.titleFrame.midX, y: cell.titleFrame.midY)
            : NSPoint(x: cell.bounds.minX + 1, y: cell.bounds.minY + 1)
        return doubleClick(rowAt: clicked, pointInCell: point)
    }
    var renamingRowIdForQA: UUID? { renamingRowId }
    /// The field really does report to this view. Asserted separately because the two
    /// key helpers below CALL the delegate methods — AppKit's own delivery needs a live
    /// field editor in a key window, which a headless check has no way to drive — so
    /// without this a rename with no delegate at all would still pass them.
    /// (Cross-review found exactly that hole.)
    var isRenameDelegateWiredForQA: Bool { renameField?.delegate === self }
    var renameFieldTextForQA: String? { renameField?.stringValue }
    /// Type into the open field. Sets the text the way the field editor would leave
    /// it; what the check is about is what Enter, Esc and blur then do with it.
    @discardableResult
    func typeRenameForQA(_ text: String) -> Bool {
        guard let renameField else { return false }
        renameField.stringValue = text
        return true
    }
    /// Enter / Esc through the field's own delegate call — the selector AppKit sends,
    /// dispatched at the same method, so a check cannot pass by calling a commit the
    /// keyboard never reaches.
    @discardableResult
    func pressKeyInRenameForQA(_ commandSelector: Selector) -> Bool {
        guard let renameField else { return false }
        return control(renameField, textView: NSTextView(), doCommandBy: commandSelector)
    }
    /// Focus loss, through the notification AppKit posts.
    @discardableResult
    func blurRenameForQA() -> Bool {
        guard let renameField else { return false }
        controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification, object: renameField))
        return true
    }

    @discardableResult
    func hoverRowForQA(id: UUID?) -> Bool {
        guard let id else { setHovered(row: -1); return true }
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index) else { return false }
        setHovered(row: tableRow)
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

// Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
/// What the table draws at one row: an agent, or the shelf's heading.
///
/// A SECOND KIND OF ROW IS THE WHOLE COST OF THIS TICKET, and it is spent here
/// rather than by faking an agent: P3.16 has just finished making the inbox list
/// agents and nothing else, and a heading dressed as an `AgentInboxRow` would put a
/// non-agent back into `rows` — into the selection, the bulk actions, the context
/// menu and the jump chords. Keeping it a separate case means the heading cannot be
/// selected, renamed, snoozed or counted by accident; the price is the one index
/// conversion `tableRow(forRowIndex:)` / `rowIndex(forTableRow:)` performs at the
/// AppKit boundary.
enum InboxListItem {
    case agent(AgentInboxRow)
    case shelfHeader(count: Int, isExpanded: Bool)
    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// The footer under a paged settled tail. A third KIND of row rather than a
    /// second use of the heading, for the reason the heading is not an agent: it
    /// carries a different number (what is hidden, not what a section holds) and it
    /// does a different thing when you press it.
    case settledMore(hidden: Int)

    /// The agent this row draws, or nil for the heading. The one test the rest of
    /// the view asks, so "is this an agent row" has a single spelling.
    var agentRow: AgentInboxRow? {
        guard case let .agent(row) = self else { return nil }
        return row
    }

    /// What makes this row THE SAME ROW as the one drawn last push, for
    /// `apply(rows:changed:)`'s identity comparison.
    ///
    /// The count is part of the heading's identity: "Snoozed (2)" becoming
    /// "Snoozed (3)" is not the same heading, and the incremental path repaints only
    /// the agent rows it was told about — so a changed count has to fall through to
    /// a full render or the shelf would go on advertising a number that is wrong.
    var identity: String {
        switch self {
        case .agent(let row): return "agent:\(row.id.uuidString)"
        case .shelfHeader(let count, let isExpanded): return "shelf:\(count):\(isExpanded)"
        // P4.8: the hidden count is part of the footer's identity for the same
        // reason the shelf's is part of the heading's — an agent settling while the
        // tail is paged changes that number and nothing else, and the incremental
        // path repaints only the agent rows it was told about.
        case .settledMore(let hidden): return "more:\(hidden)"
        }
    }
}

/// The `Snoozed (N)` heading.
///
/// ONE LINE, TWO THINGS: the triangle you open it with and what it is holding.
/// Deliberately NOT a card — `AgentInboxCardView` is what says "this is an agent",
/// and a heading that took the card's fill would read as a row you can act on and
/// would take the selection outline it can never have. The words sit straight on the
/// list, in `textSecondary` at `.label`, which is the same weight the row metadata
/// this heading sits between is drawn at.
///
/// The triangle is `InboxDisclosureButton`, the control P2D.4 already built for
/// folding a group: the gesture is the same gesture, so it is the same control and
/// the same token, rather than a second chevron this view could theme differently.
/// The whole line is clickable for the same reason a group header usually is — a
/// 9pt triangle is a small target in a 320pt sidebar — through a second borderless
/// button behind the text rather than a `mouseDown` override, so the heading answers
/// the accessibility system as the control it is.
@MainActor
final class AgentInboxShelfHeaderView: NSTableCellView, TokenThemed {
    private let disclosureButton = InboxDisclosureButton()
    private let label = NSTextField(labelWithString: "")
    private let hitButton = NSButton(frame: .zero)
    private var count = 0
    var onToggle: (() -> Void)?

    /// What the heading says. `(N)` and not "N snoozed": the word is the section and
    /// the number is what it is holding, which is the order a scanning eye wants them
    /// in — and it stays one short line at sidebar width however large N gets.
    static func title(count: Int) -> String { "Snoozed (\(count))" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleClicked)

        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail

        hitButton.isBordered = false
        hitButton.title = ""
        hitButton.target = self
        hitButton.action = #selector(toggleClicked)
        hitButton.setAccessibilityRole(.button)
        hitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hitButton)

        let line = NSStackView(views: [disclosureButton, label])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = Space.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            hitButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            hitButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            hitButton.topAnchor.constraint(equalTo: topAnchor),
            hitButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Inset.row.right),
            // Centred rather than pinned top-and-bottom, for the reason
            // `AgentInboxSlimCellView` records: one line in a fixed-height row, and a
            // centre constraint cannot leave the height ambiguous.
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func apply(count: Int, isExpanded: Bool) {
        self.count = count
        label.stringValue = AgentInboxShelfHeaderView.title(count: count)
        disclosureButton.show(isExpanded ? .expanded : .collapsed)
        hitButton.setAccessibilityLabel(
            "\(isExpanded ? "Collapse" : "Expand") \(label.stringValue)")
        applyTokens()
    }

    /// `textSecondary`: a heading is chrome, and P3.2 holds this list to three
    /// colours that all mean status. A snoozed section is not a status.
    func applyTokens() {
        label.textColor = TextToken.textSecondary.color.nsColor(in: self)
        disclosureButton.applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    @objc private func toggleClicked() { onToggle?() }

    /// Through the triangle's own target/action, so a check drives the wiring.
    @discardableResult
    func clickDisclosureForQA() -> Bool {
        disclosureButton.performClick(nil)
        return true
    }

    var qaTitle: String { label.stringValue }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
}

// Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
/// The `Show 25 more (N settled hidden)` footer under a paged settled tail.
///
/// The heading's twin, and deliberately built the same way — one line of
/// `textSecondary` at `.label`, straight on the list rather than in a card, behind a
/// borderless button that covers the row so the whole line is the target. It has no
/// triangle: a disclosure says "this section is folded", and history is not folded,
/// it is PAGED — pressing this reveals a fixed number more and leaves the rest
/// hidden, and there is no gesture that puts them back.
@MainActor
final class AgentInboxSettledMoreView: NSTableCellView, TokenThemed {
    private let label = NSTextField(labelWithString: "")
    private let hitButton = NSButton(frame: .zero)
    var onPress: (() -> Void)?

    /// What the footer says. Both numbers, because they answer different questions:
    /// how far one press pages, and how much history is behind it.
    ///
    /// THE PACKET'S LITERAL WORDING, including the case where fewer than a step
    /// remain: `Show 25 more (20 settled hidden)`. Clamping the first number to what
    /// is left reads better and was written that way first — but the packet spells
    /// this string out, so the clamp is a product change nobody asked for, and it
    /// belongs to the owner rather than to this ticket. The second number already
    /// says exactly how many rows a press produces when it is the smaller one.
    static func title(hidden: Int) -> String {
        "Show \(InboxSort.settledPageStep) more (\(hidden) settled hidden)"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        hitButton.isBordered = false
        hitButton.title = ""
        hitButton.target = self
        hitButton.action = #selector(pressed)
        hitButton.setAccessibilityRole(.button)
        hitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hitButton)
        addSubview(label)

        NSLayoutConstraint.activate([
            hitButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            hitButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            hitButton.topAnchor.constraint(equalTo: topAnchor),
            hitButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Inset.row.right),
            // Centred, for the reason the heading is: one line in a fixed-height
            // row, and a centre constraint cannot leave the height ambiguous.
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func apply(hidden: Int) {
        label.stringValue = AgentInboxSettledMoreView.title(hidden: hidden)
        hitButton.setAccessibilityLabel(label.stringValue)
        applyTokens()
    }

    /// `textSecondary`, like the heading and for the same reason: this is chrome,
    /// and P3.2 holds this list to three colours that all mean status.
    func applyTokens() {
        label.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    @objc private func pressed() { onPress?() }

    /// Through the button's own target/action, so a check drives the wiring.
    @discardableResult
    func clickForQA() -> Bool {
        hitButton.performClick(nil)
        return true
    }

    var qaTitle: String { label.stringValue }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
/// The two row views the list can build, behind one call. The list decides WHICH
/// from `AgentInboxRow.variant` and then knows nothing else about the difference —
/// so the density rule lives in `RowVariant.forLifecycle` (P3.1), which is where
/// it can be gated, and never in a condition scattered through the painting.
@MainActor
protocol AgentInboxRowCell: NSTableCellView {
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure, rollup: ChildRollup?, isSelected: Bool,
               isInteracting: Bool, now: Date)

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
    // Ticket: docs/38-tickets/90-agent-ux/P3.13-inline-rename.md
    /// The frame of the row's NAME in the cell's own coordinates. A production
    /// accessor, not a `qa` one: it is what decides whether a double-click was on the
    /// name, and where the rename field is placed.
    var titleFrame: NSRect { get }
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

// Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
/// What you can do to a SET of selected rows.
///
/// THE RULE, and it is one rule: an action is offered only when EVERY member of the
/// selection can take it. Six agents that finished together are one gesture; five that
/// finished and one still asking you for an approval are not, and the answer is to
/// offer less rather than to settle the one that was waiting. That is why
/// `available(for:)` is an AND and not a majority, a first-member test or a
/// best-effort that skips what it cannot do — a bulk action that silently applied to
/// four of six is the failure mode this shape forbids.
///
/// AN ACTION THAT IS UNAVAILABLE IS NOT SHOWN, not shown disabled. The packet says
/// "bulk actions appear only when every selected row can take the action", and a
/// greyed row of five items would put the reader in front of a puzzle ("which of my
/// six is blocking this?") that the bar has no room to answer.
///
/// NOTHING HERE PERFORMS ANYTHING. Settle, snooze and archive are persisted lifecycle
/// facts P4.1 owns and read-state lives on `AgentSupervisor` (P3.3); this ticket is
/// the enablement and the surface. `AgentInboxView.onBulkAction` is where the host
/// picks them up.
enum InboxBulkAction: String, CaseIterable, Equatable {
    case settle
    case snooze
    case markUnread
    case archive
    case delete

    /// `Snooze` keeps its `›` because it opens the preset list (P4.5) rather than
    /// acting — the one item in this menu that is a door.
    var title: String {
        switch self {
        case .settle: return "Settle"
        case .snooze: return "Snooze ›"
        case .markUnread: return "Mark Unread"
        case .archive: return "Archive"
        case .delete: return "Delete"
        }
    }

    /// Whether ONE row can take this action. Total over the cases, so adding an action
    /// is a compile error here rather than an item that is silently always available.
    ///
    /// The two rules the packet states outright:
    ///
    ///   * **A blocked row cannot be settled.** `approval` and `input` are the agent
    ///     waiting on YOU, and the locked decision is that blockers outrank an explicit
    ///     settle (`_RUNBOOK.md`) — settling one would take the row out of the
    ///     attention flow while the thing it is asking for is still unanswered. It can
    ///     still be SNOOZED: deferring a request is a decision, and P4.6 exists exactly
    ///     for the snoozed agent that raises its hand again.
    ///   * **A running agent cannot be archived or deleted.** Both are destructive of
    ///     the row's place in the list, and `working` means the agent has the next move.
    ///
    /// The rest are no-op guards, and they are guards rather than nothing because "the
    /// action is offered" has to mean "it would do something": an already-settled row
    /// has nothing to settle, an already-unread one nothing to mark, and an archived row
    /// is out of the list's lifecycle altogether — the only thing left to do with it is
    /// delete it.
    ///
    /// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
    /// `rollups` extends the FIRST of those two rules down the tree: **a parent may
    /// not be settled while a descendant is blocked or running.** It is the same rule,
    /// not a new one — settling a group takes the whole group out of the attention
    /// flow, so a child's unanswered approval is buried exactly as completely as the
    /// parent's own would be, and this is the collapsed case the rollup line exists
    /// for. Keyed by row id and DEFAULTED TO EMPTY, so a caller that has no list to
    /// roll up (a fixture, one row on its own) gets precisely the rule that shipped
    /// before this ticket.
    ///
    /// Only `.settle` consults it. Archive and delete are refused for a RUNNING row,
    /// and extending those to descendants is P2D.6's question about what a fan-out
    /// means, not this packet's; the derived lifecycle already keeps a blocked child's
    /// parent off the shelf without any action rule (`InboxLifecycle.resolve` puts
    /// blockers above the snooze rung).
    func isAvailable(for row: AgentInboxRow, rollups: [UUID: ChildRollup] = [:]) -> Bool {
        switch self {
        case .settle:
            return !InboxBulkAction.isBlocked(row) && !InboxBulkAction.isSettled(row)
                && !InboxBulkAction.isArchived(row)
                && !(rollups[row.id]?.holdsParentOpen ?? false)
        case .snooze:
            return !InboxBulkAction.isArchived(row)
        case .markUnread:
            return row.attention != .unread && !InboxBulkAction.isArchived(row)
        case .archive:
            return !InboxBulkAction.isRunning(row) && !InboxBulkAction.isArchived(row)
        case .delete:
            return !InboxBulkAction.isRunning(row)
        }
    }

    /// The actions this selection may take, in the menu's order. Empty for an empty
    /// selection — `allSatisfy` is vacuously true over nothing, which would offer every
    /// action to no agents.
    static func available(
        for rows: [AgentInboxRow], rollups: [UUID: ChildRollup] = [:]
    ) -> [InboxBulkAction] {
        guard !rows.isEmpty else { return [] }
        return allCases.filter { action in
            rows.allSatisfy { action.isAvailable(for: $0, rollups: rollups) }
        }
    }

    /// The branches a destructive action on this selection PUTS AT STAKE, in screen order
    /// and deduplicated: the ones belonging to agents with a checkout of their own.
    ///
    /// P2C.3's rule is that an agent's worktree commits are not the app's to throw away,
    /// and the packet asks for that to be SURFACED rather than merely honoured. Every
    /// isolated branch is named, not only the ones with unmerged commits, because
    /// `AgentInboxRow` carries no merge state — P3.1 flattened the row to a branch NAME.
    ///
    /// WHICH IS WHY THE CAPTION SAYS WHAT IT SAYS. `AgentSupervisor.cleanUpWorktree` does
    /// NOT keep every branch: a MERGED one is deleted (`git branch -d`, so nothing is
    /// lost) and an unmerged one is retained with a reason. So "keeps these branches"
    /// would be a promise this list cannot make about a branch it cannot inspect. What
    /// holds for all of them — and is the rule worth surfacing — is that unmerged work
    /// survives. (Found in cross-review, which caught the caption claiming the stronger
    /// thing.)
    static func keptBranches(in rows: [AgentInboxRow]) -> [String] {
        var seen: Set<String> = []
        return rows.compactMap { row -> String? in
            guard row.isIsolated, let branch = row.branch, seen.insert(branch).inserted else { return nil }
            return branch
        }
    }

    /// The agent is waiting on you — the fact `InboxState` splits into two cases
    /// (P3.2) and the one that outranks a settle.
    ///
    /// These four are `fileprivate` rather than `private` so `InboxRowAction` (P3.12,
    /// below) can ask the same questions: the context menu's enablement is specified as
    /// "the same capability rules as bulk", and sharing the predicates is the only way
    /// that holds by construction instead of by two copies agreeing today.
    fileprivate static func isBlocked(_ row: AgentInboxRow) -> Bool {
        switch row.state {
        case .approval, .input: return true
        case .working, .ready, .failed: return false
        }
    }

    fileprivate static func isRunning(_ row: AgentInboxRow) -> Bool { row.state == .working }

    fileprivate static func isSettled(_ row: AgentInboxRow) -> Bool {
        switch row.lifecycle {
        case .settled: return true
        case .active, .snoozed, .archived: return false
        }
    }

    fileprivate static func isArchived(_ row: AgentInboxRow) -> Bool {
        switch row.lifecycle {
        case .archived: return true
        case .active, .snoozed, .settled: return false
        }
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.12-row-context-menu.md
/// What one row's context menu offers — per-row actions where the hand already is.
/// The sidebar had no context menu at all before this.
///
/// TEN ITEMS AND FIVE OF THEM ARE P3.11's, by delegation and not by copy:
/// `isAvailable(for:)` asks `InboxBulkAction` for settle, snooze, mark-unread, archive
/// and delete, which is what "enabled per the same capability rules as bulk" has to mean
/// if the two surfaces are never to disagree. The five that are new here are the ones a
/// SET cannot take: opening a tile, the two un-doings (un-settle, wake) and renaming are
/// single-agent or lifecycle-inverse actions, and the explicit stop is P2A.5's rule made
/// reachable — closing a tile must never stop an agent, so there has to be somewhere that
/// deliberately does.
///
/// SETTLE/UN-SETTLE IS ONE SLOT, decided by the rows: `Un-settle` replaces `Settle` once
/// every target is settled, because both at once would be a menu asking you which
/// direction you are going. `Snooze` and `Wake` are two items and always both there — see
/// `belongsInMenu`, which records why the symmetry is only apparent.
///
/// AN UNAVAILABLE ITEM IS DISABLED WITH A REASON, the opposite call to `InboxBulkAction`'s
/// (which hides). Both follow their own packet, and the difference is the surface: the
/// bulk bar is a 320pt strip with no room to explain a greyed item, and a context menu is
/// a list with a tooltip per line. Here the reason NAMES THE AGENT that blocks it, which
/// is the question a hidden item cannot answer for a six-row selection.
///
/// NOTHING HERE PERFORMS ANYTHING, same as P3.11: the lifecycle is P4.1's, the rename is
/// P3.13's, the stop is `AgentSupervisor.stop`'s and the reveal is P3.9's.
enum InboxRowAction: String, CaseIterable, Equatable {
    case openInTile
    case settle
    case unsettle
    case snooze
    case wake
    case markUnread
    case rename
    case stopAgent
    case archive
    case delete

    /// The item's words before the count and the submenu arrow are added.
    ///
    /// The five that P3.11 also has are spelled the same on purpose, and the equality is
    /// asserted in `runAgentInboxChecks` rather than left to two literals agreeing — a row
    /// menu that said "Mark as unread" over a bar that said "Mark Unread" would be two
    /// vocabularies for one action.
    var baseTitle: String {
        switch self {
        case .openInTile: return "Open in Tile"
        case .settle: return "Settle"
        case .unsettle: return "Un-settle"
        case .snooze: return "Snooze"
        case .wake: return "Wake"
        case .markUnread: return "Mark Unread"
        case .rename: return "Rename"
        case .stopAgent: return "Stop Agent"
        case .archive: return "Archive"
        case .delete: return "Delete"
        }
    }

    /// `Snooze` alone: it opens the preset list (P4.5) rather than acting, which is the
    /// same reason `InboxBulkAction.snooze` carries the arrow.
    var opensSubmenu: Bool { self == .snooze }

    /// `Settle` for one row, `Settle (3)` for a selection — the packet's rule, so a menu
    /// raised over a multiple selection says out loud that it is not about the row you
    /// happened to right-click. The count goes BEFORE the arrow (`Snooze (3) ›`), because
    /// the arrow is the item's shape and not part of its name.
    func title(forCount count: Int) -> String {
        let counted = count > 1 ? "\(baseTitle) (\(count))" : baseTitle
        return opensSubmenu ? "\(counted) ›" : counted
    }

    /// Whether ONE row can take this action. Total over the cases, so a new action is a
    /// compile error here rather than an item that is silently always live.
    ///
    /// P2D.5: `rollups` is passed straight through to the bulk rules, because the
    /// context menu's enablement is specified as "the same capability rules as bulk" —
    /// a Settle the bar withholds from a parent must be a Settle the menu greys too.
    func isAvailable(for row: AgentInboxRow, rollups: [UUID: ChildRollup] = [:]) -> Bool {
        switch self {
        // Every row on screen names an agent, and P3.9's reveal attaches a view to one
        // that has none — so there is no row this cannot be asked of. What it cannot take
        // is a SET, which `disabledReason` handles: "open" has no plural.
        case .openInTile: return true
        case .settle: return InboxBulkAction.settle.isAvailable(for: row, rollups: rollups)
        case .unsettle: return InboxBulkAction.isSettled(row)
        case .snooze: return InboxBulkAction.snooze.isAvailable(for: row)
        case .wake: return InboxRowAction.isSnoozed(row)
        case .markUnread: return InboxBulkAction.markUnread.isAvailable(for: row)
        // The name is on the RECORD, and `AgentSupervisor.archive` deletes the record —
        // so an archived row has nothing left to rename.
        case .rename: return !InboxBulkAction.isArchived(row)
        case .stopAgent: return InboxRowAction.hasTurnInFlight(row)
        case .archive: return InboxBulkAction.archive.isAvailable(for: row)
        case .delete: return InboxBulkAction.delete.isAvailable(for: row)
        }
    }

    /// The items the menu SHOWS for these agents, in menu order. Empty for no agents,
    /// which is what a right-click on the background gets.
    static func menuItems(for rows: [AgentInboxRow]) -> [InboxRowAction] {
        guard !rows.isEmpty else { return [] }
        return allCases.filter { $0.belongsInMenu(for: rows) }
    }

    /// Which half of the ONE pair belongs in the menu. Everything else is unconditional —
    /// an item you cannot use is greyed, not absent.
    ///
    /// SETTLE/UN-SETTLE IS THE ONLY EITHER/OR, and that is the packet's own spelling: it
    /// writes "Settle / Un-settle" with a slash and "Snooze › · Wake" with the same
    /// separator as every other item. It is also the only pair where the forward action
    /// would be a no-op — a settled row has nothing left to settle, while a SNOOZED row can
    /// perfectly well be snoozed again on a different preset (P4.5), so Snooze stays live
    /// beside Wake and the menu keeps one shape. (Cross-review caught the first version
    /// swapping this pair too, which took the preset list away from exactly the rows most
    /// likely to want a different one.)
    private func belongsInMenu(for rows: [AgentInboxRow]) -> Bool {
        switch self {
        case .settle: return !rows.allSatisfy(InboxBulkAction.isSettled)
        case .unsettle: return rows.allSatisfy(InboxBulkAction.isSettled)
        case .openInTile, .snooze, .wake, .markUnread, .rename, .stopAgent, .archive,
             .delete:
            return true
        }
    }

    /// Why this item is greyed, in the words its tooltip shows — nil when it is live.
    ///
    /// The order is the order a reader needs: an action nothing can perform yet is
    /// disabled for that reason first, because "Ada is still working" would be a lie about
    /// why Delete is grey while `onRowAction` is nil (the packet's watch-out: do not wire
    /// an item to nothing silently). Then the arity, then the capability rule — named
    /// against the FIRST agent in screen order that blocks it, so a selection's greyed
    /// item answers "which of my six?" instead of posing it.
    func disabledReason(
        for rows: [AgentInboxRow], isWired: Bool, rollups: [UUID: ChildRollup] = [:]
    ) -> String? {
        guard !rows.isEmpty else { return InboxRowAction.noTargetReason }
        guard isWired else { return InboxRowAction.notWiredReason }
        if self == .openInTile, rows.count > 1 { return InboxRowAction.oneAtATimeReason }
        guard let offender = rows.first(where: { !isAvailable(for: $0, rollups: rollups) })
        else { return nil }
        return "\(offender.title) \(clauseWhenUnavailable(offender, rollups: rollups))"
    }

    static let noTargetReason = "No agent is selected."
    /// Said of settle, snooze, mark-unread, rename, stop, archive and delete for as long
    /// as no host performs them — the packet's watch-out, discharged in the tooltip.
    static let notWiredReason = "Not available yet."
    static let oneAtATimeReason = "Open one agent at a time."

    /// Why this one agent blocks this action, as the tail of a sentence starting with its
    /// name. Every clause is the rule it comes from, stated the way the rule is stated —
    /// so the tooltip is the reason and not a restatement of the greying.
    private func clauseWhenUnavailable(
        _ row: AgentInboxRow, rollups: [UUID: ChildRollup] = [:]
    ) -> String {
        switch self {
        // Unreachable: `openInTile` is available for every row, and the plural case is
        // answered above. Present because the switch is total, which is what makes a new
        // action a compile error here.
        case .openInTile: return "cannot be opened."
        case .settle:
            if InboxBulkAction.isBlocked(row) { return "is waiting on you." }
            // P2D.5: named against the GROUP, and after the row's own blocker, because
            // "Ada is waiting on you" is the truer sentence when both hold. The two
            // halves are told apart — a reader deciding whether to wait or to answer
            // something needs to know which.
            if let rollup = rollups[row.id], rollup.holdsParentOpen {
                return rollup.needsYou > 0
                    ? "has work under it waiting on you."
                    : "has work under it still running."
            }
            return InboxBulkAction.isSettled(row) ? "is already settled." : "is archived."
        case .unsettle: return "is not settled."
        case .snooze: return "is archived."
        case .wake: return "is not snoozed."
        case .markUnread:
            return row.attention == .unread ? "is already unread." : "is archived."
        case .rename: return "is archived."
        case .stopAgent: return "has no turn in flight."
        case .archive:
            return InboxBulkAction.isRunning(row) ? "is still working." : "is already archived."
        case .delete: return "is still working."
        }
    }

    private static func isSnoozed(_ row: AgentInboxRow) -> Bool {
        switch row.lifecycle {
        case .snoozed: return true
        case .active, .settled, .archived: return false
        }
    }

    /// The agent has a turn in flight — the only thing `AgentSupervisor.stop` has to
    /// terminate (`isRunning(_:)` there is `runners[id] != nil`).
    ///
    /// THREE STATES, not one: `working` is obvious, and `approval`/`input` are a turn that
    /// is still running with the adapter holding a request open — `InboxState.state(for:)`
    /// lets a pending request override a `working` status, so a blocked agent is a live
    /// one. `ready` is the resting state ("the agent stopped and is waiting on you") and
    /// `failed` has already ended; neither has a runner to stop, and an item that would do
    /// nothing must not be live. An archived agent has no record left at all.
    private static func hasTurnInFlight(_ row: AgentInboxRow) -> Bool {
        guard !InboxBulkAction.isArchived(row) else { return false }
        switch row.state {
        case .working, .approval, .input: return true
        case .ready, .failed: return false
        }
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
/// The bar that floats over the bottom of the list while two or more rows are
/// selected: how many are selected, what can be done to all of them, and what a
/// destructive action would keep.
///
/// A PULL-DOWN, not a row of five buttons. Measured against the sidebar this lives in:
/// "Settle · Snooze › · Mark Unread · Archive · Delete" does not fit 320pt at
/// `.token(.label)`, and five truncating buttons is how a control becomes a row of
/// rects with no glyphs in them — which `UIProbePixels` is right to call flat. The menu
/// also makes "an unavailable action is not shown" a single fact (the item is not in the
/// menu) rather than five hidden buttons whose layout has to stay put anyway.
///
/// A CARD, like the hint pill: `overlay` fill, `border` outline, `Radius.card`. It floats
/// rather than taking height off the list for the reason recorded at its constraints —
/// a bar that pushed the rows would make the list's geometry depend on the selection.
final class InboxBulkActionBar: NSView, TokenThemed {
    /// The pull-down's own title, which is item 0 of its menu and never an action.
    static let menuTitle = "Actions"

    private let countLabel = NSTextField(labelWithString: "")
    private let actionPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let keptLabel = NSTextField(labelWithString: "")
    /// The actions in the menu, parallel to the menu items' tags — the same shape
    /// `AgentInboxView.scopeEntries` uses, and for the same reason: a tag carries the
    /// index, so an item's position in the menu is not what identifies it.
    private var actions: [InboxBulkAction] = []
    var onAction: ((InboxBulkAction) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = Radius.card
        isHidden = true

        countLabel.font = .token(.label)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        actionPopUp.font = .token(.label)
        actionPopUp.translatesAutoresizingMaskIntoConstraints = false
        actionPopUp.target = self
        actionPopUp.action = #selector(actionPicked(_:))

        // Middle truncation, the vocabulary the row's own branch line uses: an
        // `agent/<role>-<slug>` branch is identified by both ends.
        keptLabel.font = .token(.caption)
        keptLabel.lineBreakMode = .byTruncatingMiddle
        keptLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(countLabel)
        addSubview(actionPopUp)
        addSubview(keptLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            // The POPUP owns the vertical, and the label centres on it — the control is
            // the taller of the two, so pinning the label's top and centring the popup on
            // it made the bezel stand 1pt above the bar's own top edge
            // (`--component-lab-check`: `NSPopUpButton spills vertically — frame y
            // 17.0…41.0 outside parent 0…40.0`).
            countLabel.centerYAnchor.constraint(equalTo: actionPopUp.centerYAnchor),

            actionPopUp.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: Space.m),
            actionPopUp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right),
            actionPopUp.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),

            keptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            keptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right),
            keptLabel.topAnchor.constraint(equalTo: actionPopUp.bottomAnchor, constant: Space.xs),
            keptLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.s),
        ])
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    /// Put the bar up for this selection.
    ///
    /// The menu is rebuilt every time rather than diffed: it is at most five items, and
    /// the alternative is a stale item that fires an action the selection can no longer
    /// take.
    func show(_ actions: [InboxBulkAction], selectionCount: Int, keptBranches: [String]) {
        self.actions = actions
        let menu = NSMenu()
        // Item 0 is a pull-down's TITLE and is never chosen — without it the first
        // action would be the button's label and unpickable. Its tag is -1 because
        // `NSMenuItem`'s default tag is 0, which is the FIRST ACTION's tag: left at the
        // default, `selectItem(withTag: 0)` finds this title item instead and the first
        // action in the menu becomes unreachable.
        let title = NSMenuItem(title: InboxBulkActionBar.menuTitle, action: nil, keyEquivalent: "")
        title.tag = -1
        menu.addItem(title)
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        actionPopUp.menu = menu
        // A selection whose members share nothing can take nothing — say the count and
        // offer no control, rather than an empty menu that reads as a broken one.
        actionPopUp.isHidden = actions.isEmpty
        countLabel.stringValue = InboxBulkActionBar.selectionText(count: selectionCount)
        keptLabel.stringValue = InboxBulkActionBar.keptText(branches: keptBranches)
        keptLabel.isHidden = keptLabel.stringValue.isEmpty
        isHidden = false
        applyTokens()
    }

    func hide() {
        isHidden = true
        actions = []
    }

    static func selectionText(count: Int) -> String { "\(count) selected" }

    /// `Unmerged work kept: ⎇ agent/one, ⎇ agent/two` — in `BranchChipNSView`'s glyph
    /// rather than a second vocabulary, so a branch looks the same here as on the row
    /// above it. Empty for a selection with no isolated agent in it, which hides the line.
    ///
    /// The wording is the exact guarantee `AgentSupervisor.cleanUpWorktree` gives — see
    /// `InboxBulkAction.keptBranches`, which records why the stronger "keeps these
    /// branches" would be a claim this list cannot make.
    static func keptText(branches: [String]) -> String {
        guard !branches.isEmpty else { return "" }
        return "Unmerged work kept: "
            + branches.map { "\(BranchChipNSView.branchGlyph) \($0)" }.joined(separator: ", ")
    }

    @objc private func actionPicked(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, actions.indices.contains(tag) else { return }
        onAction?(actions[tag])
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderColor = LineToken.border.color.cgColor(for: theme)
        countLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        keptLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// The items the MENU is really carrying, less its title item — rather than
    /// `actions.map(\.title)`, which would assert the array the menu was built from and
    /// not the menu.
    var qaActionTitles: [String] {
        guard !isHidden, !actionPopUp.isHidden else { return [] }
        return (actionPopUp.menu?.items ?? []).dropFirst().map(\.title)
    }
    var qaSelectionText: String { countLabel.stringValue }
    var qaKeptText: String { keptLabel.isHidden ? "" : keptLabel.stringValue }

    /// Choose an action through the control's own target/action.
    @discardableResult
    func pickForQA(_ action: InboxBulkAction) -> Bool {
        guard !isHidden, !actionPopUp.isHidden, let index = actions.firstIndex(of: action),
              actionPopUp.selectItem(withTag: index) else { return false }
        actionPicked(actionPopUp)
        return true
    }
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
    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis, disclosure: RowDisclosure,
                        rollup: ChildRollup?)?

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
    ///
    /// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
    /// `rollup` is what is under this row, and it is drawn ONLY while the group is
    /// FOLDED — an expanded parent's children are on screen saying it themselves, and
    /// a second copy of what the next three rows already show is noise on the row
    /// that has the least space to spare. It joins the META LINE rather than taking a
    /// fourth one: `AgentInboxView.rowHeight` is derived from exactly three lines of
    /// type, so a new line would clip the card rather than grow it, and every
    /// geometry gate and PNG baseline in the matrix is measured against that height.
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, rollup: ChildRollup? = nil,
               isSelected: Bool = false,
               isInteracting: Bool = false, now: Date = Date()) {
        shown = (row, emphasis, disclosure, rollup)
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
        metaLabel.stringValue = AgentInboxCellView.metaText(
            role: row.role, model: row.model,
            rollup: disclosure == .collapsed ? rollup : nil)
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
              rollup: shown.rollup, isSelected: card.isSelected)
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
    ///
    /// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
    /// A folded parent's rollup goes on the FRONT of this line, in the same ` · `
    /// vocabulary. First, not last, because `metaLabel` truncates by tail on a narrow
    /// sidebar and the thing that must survive the squeeze is what the fold is
    /// hiding — an agent's role and model are still on the row's title line's terms,
    /// but "1 needs you" exists nowhere else while the group is closed.
    static func metaText(role: String?, model: String?, rollup: ChildRollup? = nil) -> String {
        [rollup?.summary, role, model].compactMap { $0 }.joined(separator: " · ")
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
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }
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

    /// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
    /// `rollup` is ACCEPTED AND NOT DRAWN here. A parked row is one line already
    /// holding a glyph, a name, a branch and a time, and there is nowhere on it to put
    /// a tally without pushing one of those four off — but the reason it is SAFE not
    /// to is the rule this ticket adds, on both paths a row can become parked:
    ///
    ///   * BY YOU — `InboxBulkAction.settle.isAvailable(for:rollups:)` withholds Settle
    ///     from a parent while a descendant is blocked or running, so the action that
    ///     would collapse the row is not offered while there is something under it to
    ///     hide. Asserted in section A4b of `runAgentInboxChecks`.
    ///   * BY DERIVATION — `LifecycleBlockers.includingDescendants` folds a
    ///     descendant's blockers into the parent's before `InboxLifecycle.resolve` sees
    ///     them, landing them on the rung that outranks both "I said done" and a
    ///     snooze, so the resolved lifecycle is `.active` and
    ///     `RowVariant.forLifecycle(.active)` is a CARD. Asserted directly in
    ///     `runParentBlockedByDescendantCheck`.
    ///
    /// The honest limit, since a comment that overstates is worse than none: NOTHING
    /// PRODUCES A PARKED ROW YET. `AgentInboxRowBuilder` still hands every row
    /// `.active` (P4.2 recorded the same gap — the writers of the stored facts are
    /// P4.3–P4.6), so today the second path is a proof about a function rather than
    /// about a rendering. When a writer lands, that is the check to look at.
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, rollup: ChildRollup? = nil,
               isSelected: Bool = false,
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
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }
}
