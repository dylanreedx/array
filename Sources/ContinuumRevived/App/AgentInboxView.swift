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

// Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
/// The four STORED lifecycle facts an undo puts back — `AgentRecord`'s
/// `settledOverride`, `settledAt`, `snoozedUntil` and `snoozedAt`, named the same
/// way so the mapping is by eye and cannot be got backwards (the call
/// `SnoozedAgentFacts` already made in AgentUI).
///
/// A CAPTURE, NOT A RECONSTRUCTION, and that is the whole ticket. "Undo a settle"
/// looks like "set the override back to `.neutral`" until the agent was
/// `.active`-PINNED before the settle: reconstructing then discards the pin, the
/// next inactivity sweep buries the row, and the person who pressed Undo has lost
/// a decision they made rather than got one back. So the values are read BEFORE
/// the action runs and handed back verbatim; nothing here computes what a prior
/// state "should" have been.
///
/// The list cannot read these itself — they live on `AgentRecord` in Core and only
/// `AgentSupervisor` may write one — so the host supplies the reader
/// (`AgentInboxView.lifecycleFacts`) and performs the restore
/// (`AgentInboxView.onUndoLifecycle`), exactly as it does for every other fact
/// this view draws.
struct InboxLifecycleSnapshot: Equatable {
    var settledOverride: SettledOverride
    var settledAt: Date?
    var snoozedUntil: Date?
    var snoozedAt: Date?

    init(
        settledOverride: SettledOverride = .neutral,
        settledAt: Date? = nil,
        snoozedUntil: Date? = nil,
        snoozedAt: Date? = nil
    ) {
        self.settledOverride = settledOverride
        self.settledAt = settledAt
        self.snoozedUntil = snoozedUntil
        self.snoozedAt = snoozedAt
    }
}

/// A label's measured drawing lane, read from the live row cell rather than from
/// the row model. `neededWidth` includes the `Metrics.cellTextInset` NSTextField
/// cell inset: the raw NSString measurement is not the width AppKit needs before
/// it elides at draw time. Hidden labels report their live alignment width, so
/// AppKit's four-point NSTextField frame padding cannot masquerade as reserved
/// content space.
struct AgentInboxLabelGeometryForQA {
    let element: String
    let text: String
    let frame: NSRect
    let drawableWidth: Double
    let neededWidth: Double
    let font: NSFont?
    let isHidden: Bool
    /// Accessibility/help metadata is read from the live label so the provider
    /// glyph cannot satisfy a visual-only check while making the model unreachable.
    let accessibilityLabel: String?
    let toolTip: String?
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.1-title-line-ownership.md
    /// The LIVE horizontal compression resistance of this label, so the recorded
    /// sacrifice order can be asserted as a ladder rather than described in a
    /// comment. Read off the view, never off a table of what the view was
    /// supposed to be set to.
    let compressionResistance: Double
}

/// The geometry and paint facts a materialized row cell exposes to deterministic
/// checks. Optional paint/identity fields deliberately make an un-applied or
/// detached cell fail the probe instead of supplying a default answer.
struct AgentInboxRowGeometryForQA {
    let agentID: UUID?
    let state: InboxState?
    let variant: RowVariant?
    let elementFrames: [String: NSRect]
    let labels: [AgentInboxLabelGeometryForQA]
    let paintedBorderWidth: Double?
    let resolvedFill: CGColor?
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// Which step of the interaction ladder this row RESOLVED to, read off the
    /// card. Reported next to `resolvedFill` so a check can hold the two to each
    /// other: a role that resolves without its fill being painted, or a fill
    /// painted for a role the row is not on, is the defect either half alone
    /// would miss.
    let surfaceRole: SidebarSurfaceRole?
    /// Every line and shadow the row paints, keyed by what paints it. P1.1
    /// requires the card's perimeter to be zero in every state, P1.2 requires no
    /// state to be carried by a border or a shadow, and P1.3 requires no sidebar
    /// line to exceed `LineWidth.hairline` — all three are measurements over
    /// this dictionary rather than three separate accessors that could disagree.
    let paintedLines: [String: Double]
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.4-focus-ring-and-floors.md
    /// Whether the row's focus ring is on screen right now.
    let isFocusRingVisible: Bool
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.2-measured-fit-tiers.md
    /// What the cell says to VoiceOver. Reported next to `fitTier` because the two
    /// are one obligation: a tier that DROPS a column must relocate the fact here,
    /// and a gate that could only see the tier could not tell a relocation from a
    /// deletion.
    let accessibilityLabel: String?
    /// Which measured-fit tier this row RESOLVED to, read off the cell that laid
    /// itself out. Reported so a gate can hold the tier and the hidden flags to
    /// each other: a tier that claims to have dropped the elapsed column while
    /// the column is still drawn, or a hidden column on a row that claims the
    /// full tier, is the defect either half alone would miss. `nil` on a variant
    /// that has no tiers (the slim row is one line and drops nothing).
    let fitTier: RowFitTier?
    /// The slim row's measured tier. Keeping it separate from the card ladder
    /// makes the two sacrifice vocabularies explicit while exposing both from
    /// the same live geometry seam.
    let slimFitTier: SlimRowFitTier?
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P2.2-measured-fit-tiers.md
/// How much of a row's decoration fits, chosen by comparing MEASURED need against
/// the width the row actually has — never by comparing the width against a
/// threshold. `_DESIGN.md`: "Adaptive behaviour compares measured need against
/// the width actually available and steps through named tiers."
///
/// A THRESHOLD IS THE BUG THIS REPLACES. "Narrow means under 250pt" is a claim
/// about a font, a string and an inset that the number cannot see: it is wrong
/// the day the type scale moves (P1.4), wrong for a row whose project is one
/// character, and wrong for a row whose project is sixty. Every boundary below is
/// the answer to "does what this row wants to draw fit in the room this row has".
///
/// THREE TIERS, and each one names its own sacrifice, in the order P2.1 recorded
/// (caption → branch → metrics → role/rollup → NAME). Three and not four: a
/// fourth tier would be a way of avoiding a decision, and there are exactly two
/// things on this row that can be dropped whole rather than elided.
///
/// `titleLabel` and `stateLabel` are NEVER a tier's sacrifice, at any width. The
/// name is the row's subject and the state is the question the list answers; a
/// tier that hid either would be answering a width problem by deleting the
/// content.
enum RowFitTier: String, CaseIterable {
    /// Everything the row has to say is drawn.
    case full
    /// The elapsed column is dropped. It goes first of the two because a duration
    /// is the most re-derivable thing on the row — the tile header states it, and
    /// it is the only label here that changes on its own.
    case abbreviated
    /// The elapsed column AND the project chip are dropped. The tightest tier: a
    /// row this narrow spends its width on the name and the state and nothing
    /// else.
    case captionHidden

    /// Whether this tier draws the elapsed column.
    var drawsElapsed: Bool { self == .full }
    /// Whether this tier draws the project chip.
    var drawsProject: Bool { self != .captionHidden }
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P2.6-slim-variant-parity.md
/// The slim row has one line rather than the card's three bands, so its measured
/// sacrifice is the same decision in a smaller vocabulary: branch first, then
/// the re-derivable relative-time metric, and the name last. The glyph and the
/// name remain in every tier.
enum SlimRowFitTier: String, CaseIterable {
    /// Glyph, name, branch and relative time all fit in the line.
    case full
    /// The branch gives way before the time and the name.
    case branchHidden
    /// Only the glyph and name remain. A name may still elide here when its own
    /// measured need is wider than the complete line — no tier can manufacture
    /// room for a name that does not fit.
    case timeHidden

    var drawsBranch: Bool { self == .full }
    var drawsTime: Bool { self != .timeHidden }
}

@MainActor
private func inboxLabelGeometryForQA(
    _ element: String, label: NSTextField, in cell: NSView
) -> AgentInboxLabelGeometryForQA {
    let font = label.font
    let neededWidth = font.map {
        Double(ceil((label.stringValue as NSString).size(withAttributes: [.font: $0]).width))
            + Metrics.cellTextInset
    } ?? 0
    let drawableWidth = label.isHidden
        ? max(0, Double(label.alignmentRect(forFrame: label.frame).width))
        : Double(label.frame.width)
    return AgentInboxLabelGeometryForQA(
        element: element,
        text: label.stringValue,
        frame: label.convert(label.bounds, to: cell),
        drawableWidth: drawableWidth,
        neededWidth: neededWidth,
        font: font,
        isHidden: label.isHidden,
        accessibilityLabel: label.accessibilityLabel(),
        toolTip: label.toolTip,
        compressionResistance: Double(
            label.contentCompressionResistancePriority(for: .horizontal).rawValue)
    )
}

@MainActor
private final class AgentInboxTableView: NSTableView {
    weak var contextHandler: AgentInboxView?

    override func keyDown(with event: NSEvent) {
        // Keep ordinary traversal in NSTableView so its native type-select,
        // range-selection and modifier semantics remain intact. The inbox only
        // owns the two activation keys and the post-traversal visibility guarantee.
        if contextHandler?.handleTableActivationKey(event) == true { return }
        super.keyDown(with: event)
        contextHandler?.didTraverseWithKeyboard(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        contextHandler?.presentContextMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            contextHandler?.presentContextMenu(for: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class AgentInboxView: NSView, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate, TokenThemed {
    /// The tallest card height: three lines (metadata, name, detail), the two
    /// inter-band gaps, and the card's own padding. It remains a useful ceiling
    /// for offscreen probes, while individual cards use `height(for:)` below so
    /// empty bands do not reserve this space.
    static var rowHeight: Double {
        Metrics.rowHeight(for: [.label, .title, .label], insets: Inset.card, spacing: Space.s)
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

    /// The height of a row's rendered content. Card rows ask the shared metrics
    /// helper for the roles their live cell will draw; the name is always present,
    /// while the two label bands are included only when their content slots are
    /// non-empty. A collapsed rollup counts as detail content because it is drawn
    /// on that band. The variant branch selects the already-rendered one-line
    /// parked cell; it does not classify a row by importance.
    static func height(
        for row: AgentInboxRow,
        availableWidth: Double? = nil,
        disclosure: RowDisclosure = .none,
        rollup: ChildRollup? = nil
    ) -> Double {
        switch row.variant {
        case .slim:
            return slimRowHeight
        case .card:
            let drawsRollup = disclosure == .collapsed && rollup != nil
            let tier = availableWidth.map {
                AgentInboxCellView.fitTier(
                    for: row,
                    available: $0,
                    disclosure: disclosure)
            }
            let lineCount = row.drawnLineCount(
                drawingProject: tier?.drawsProject ?? true,
                drawingElapsed: tier?.drawsElapsed ?? true,
                includingAdditionalDetail: drawsRollup)
            var roles: [TextRole] = []
            if lineCount > 0 {
                if row.drawsMetaLine(
                    drawingProject: tier?.drawsProject ?? true,
                    drawingElapsed: tier?.drawsElapsed ?? true) {
                    roles.append(.label)
                }
                roles.append(.title)
                if lineCount > roles.count { roles.append(.label) }
            }
            return Metrics.rowHeight(for: roles, insets: Inset.card, spacing: Space.s)
        }
    }

    /// Variant-only compatibility for callers that need the density ceiling but
    /// do not have a row's content. Rendering uses `height(for:disclosure:rollup:)`.
    static func height(for variant: RowVariant) -> Double {
        switch variant {
        case .card: return rowHeight
        case .slim: return slimRowHeight
        }
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.12-crossfade-in-place.md
    /// How long a variant swap crossfades. Short enough that a settle reads as the
    /// row CHANGING rather than as an animation you sit through — the packet's
    /// 150–200ms, taken at the middle.
    static let crossfadeDuration: TimeInterval = 0.18

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
        (2 * Space.s + Double(ChoiceButton.controlHeight)).rounded(.up)
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

    private let scopeButton: ChoiceButton
    private let searchField: NSTextField
    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let column: NSTableColumn
    private let emptyLabel: NSTextField
    // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
    private let bulkBar = InboxBulkActionBar()
    // Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
    private let undoToast = InboxUndoToast()
    /// What the toast on screen would put back, keyed by agent. Nil when no toast is
    /// up — and cleared the instant Undo is pressed, so a second press cannot apply a
    /// restore twice over facts the first one already changed.
    private var pendingUndo: [UUID: InboxLifecycleSnapshot]?
    private var undoToastTimer: Timer?
    // Ticket: P5.1-custom-row-context-menu.md
    /// The tile's choice-family surface replaces stock AppKit row menus. Targets are
    /// retained by stable id while the panel is open so a push cannot retarget an action.
    private let rowChoiceController = ChoicePopoverController()
    private var rowChoiceTargetIds: [UUID] = []
    // Headless checks retain the same ChoiceListView when no AppKit window exists.
    private var qaChoiceListForQA: ChoiceListView?
    /// Capability state starts unknown/hidden. It is filled by the detached,
    /// bounded resolver and then repaints an already-open menu on the main actor;
    /// building a menu never performs the capability lookup itself.
    private var nameGenerationCapabilityAvailable = false
    private var nameGenerationCapabilityTask: Task<Void, Never>?

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
    /// Search is view-local filter state. It never participates in ordering or persistence.
    private var searchQuery = ""
    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// Management actions remain in the same choice vocabulary as scopes.
    private var managementItems: [WorkspaceManagementAction: ChoiceItem] = [:]
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
    /// The AGENT the mouse is over. Hover is one of P3.5's three interaction
    /// facts and it is tracked HERE, on the table, rather than per cell: cell
    /// views are recycled, so a tracking area installed on one would follow it
    /// onto a different row.
    ///
    /// P1.2 made it an AGENT ID rather than the table row index it was. An index
    /// is a fact about the list that handed it out, and this list re-renders
    /// under the pointer for four reasons that do not move the mouse — a fold, a
    /// scope flip, the shelf, a page of history — plus every scroll. Keyed by
    /// index, all of those left the previous row's index lit on whichever agent
    /// had moved into it; keyed by agent, the fill follows the agent, and
    /// `refreshHoverFromPointer()` re-derives from where the pointer actually is
    /// whenever the list or the viewport moves under it.
    private var hoveredAgentId: UUID?
    /// The table row `hoveredAgentId` currently occupies, or -1. DERIVED, so it
    /// cannot drift out of step with the id the way a second stored index could.
    private var hoveredRow: Int {
        guard let hoveredAgentId,
              let index = rows.firstIndex(where: { $0.id == hoveredAgentId }) else { return -1 }
        return tableRow(forRowIndex: index) ?? -1
    }
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.4-focus-ring-and-floors.md
    /// The agent the KEYBOARD is on — the row Return will act on — or nil when
    /// the last thing that moved the selection was the mouse.
    ///
    /// Distinct from the selection on purpose. In an `NSTableView` arrow-key
    /// navigation IS a selection move, so the two are the same row by
    /// construction and P3.5 was right to treat them as one fact for recession.
    /// They are NOT the same for VISIBILITY: a keyboard user needs to see which
    /// row Return will act on, and a mouse user who clicked a row already knows.
    /// So the ring is armed only by a key event and disarmed by a mouse one, and
    /// it never outlives the selection it marks or the window's key state.
    ///
    /// STORED AS AN INTENT AND RESOLVED AGAINST THE SELECTION. "A ring never
    /// outlives the selection it marks" is then a derivation rather than
    /// something a notification handler has to remember — and it has to be,
    /// because `NSTableView` does not guarantee delivering
    /// `tableViewSelectionDidChange` synchronously for a programmatic selection
    /// change. Measured: with the rule living in that handler,
    /// `--sidebar-ux-check` reported `the focus ring survived the selection
    /// moving off its row` with the selection already narrowed correctly.
    private var keyboardFocusIntent: UUID?
    private var keyboardFocusAgentId: UUID? {
        guard let id = keyboardFocusIntent, let row = tableRow(forAgentId: id),
              tableView.selectedRowIndexes.contains(row) else { return nil }
        return id
    }
    /// The selection as the cells were last painted for it. `selectionDidChange`
    /// reports the NEW selection only, so the rows that just lost it — the ones that
    /// have to start receding again — have to be remembered.
    ///
    /// P3.11 made this a SET rather than one index: with a range selected, the rows
    /// that changed are the symmetric difference of the two selections, and an
    /// `Int` could only ever repaint one of them.
    private var selectedRowsForEmphasis = IndexSet()
    private var trackingArea: NSTrackingArea?
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// The scroll and window-deactivation subscriptions hover depends on, held as
    /// TOKENS so `viewDidMoveToWindow` can drop exactly this view's own before
    /// taking the next window's — see the note there for why the blanket
    /// `removeObserver(self)` is not an option. Every block captures `self`
    /// weakly, so nothing here retains the view.
    private var interactionObservers: [NSObjectProtocol] = []

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
    /// A field can post end-editing more than once: Return ends the command and
    /// AppKit may then report the field editor's blur. This flag is set before
    /// teardown so the second notification cannot dispatch the same rename.
    private var didCommitRename = false
    /// The last torn-down field is retained only as a deterministic witness for
    /// the blur-after-Return notification. Production delivery simply ignores
    /// that stale field because it is no longer the active editor.
    private var lastEndedRenameFieldForQA: NSTextField?
    /// The table can still send its ordinary action for the second click after a
    /// double-action. Keep the row id so that trailing activation is consumed,
    /// not routed to the host after the editor opens.
    private var suppressedTrailingActivationAgentId: UUID?
    /// Counts the actual callback dispatches from the live field editor. These
    /// are QA observability, not a second rename path.
    private(set) var qaRenameCommitCount = 0
    private(set) var qaRenameCancelCount = 0
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

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.3-content-derived-row-height.md
    /// `NSTableView` caches delegate heights independently of the cell's layout.
    /// A divider drag can change a row's measured-fit tier without changing its
    /// identity or content, so the width used for the last height invalidation is
    /// kept here and compared after this view lays out its table.
    private var lastTableWidthForHeightCache: CGFloat?
    /// The width used by the most recent delegate query. During an initial host
    /// layout AppKit can ask heights before the scroll view finishes resizing the
    /// column; the mismatch must schedule one more invalidation after `super.layout`.
    private var lastHeightQueryColumnWidth: CGFloat?
    /// A cell can materialize during `super.layout` after the table has already
    /// chosen a row height. One follow-up table pass re-asks that height against
    /// the cell's now-live content and then clears this flag.
    private var needsHeightRevalidation = true
    private var isInvalidatingHeightsForWidth = false
    /// A fractional width override used only by the offscreen content-height
    /// witness. The normal view always reads the scroll viewport; the witness
    /// keeps the host-frame resize on the same production invalidation path even
    /// when a 1x clip view rounds its viewport before `layout()` can see it.
    private var qaViewportWidthOverride: CGFloat?

    // Ticket: docs/38-tickets/90-agent-ux/P4.12-crossfade-in-place.md
    /// The OUTGOING cell of a row whose variant just moved, still on screen and
    /// fading out where it stood, keyed by the AGENT it belongs to.
    ///
    /// Keyed by agent and not by table row, which is what makes rapid successive
    /// settles safe: a row's index is a fact about the list it was in, and the list
    /// changed. Keyed this way a second move on the same agent REPLACES the first
    /// ghost instead of stacking a second card over it, so however fast the pushes
    /// arrive there is at most one outgoing view per row.
    private var crossfadingCells: [UUID: NSView] = [:]

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

    // Ticket: docs/38-tickets/90-agent-ux/P4.12-crossfade-in-place.md
    /// Whether the person has asked for less movement. A closure for the reason
    /// `clock` is one: the answer is a live system setting, and a check has to be
    /// able to drive BOTH branches — a crossfade is exactly the kind of thing
    /// Reduce Motion turns off, and a fallback nothing can exercise is a fallback
    /// nobody knows is broken.
    var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

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
    /// Space previews the focused row without changing the active canvas tile.
    /// The host owns what preview means; the list only supplies the on-screen id.
    var onPreviewRow: ((UUID) -> Void)?
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
    /// P5.1 derives the choice list from this capability set and hides actions that
    /// cannot be honoured; it never presents a dead row in the custom menu.
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
    // Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
    /// This agent's STORED lifecycle facts right now, or nil for an agent the host has
    /// no record of. Read twice around every lifecycle action — once before it runs, to
    /// capture what an Undo has to put back, and once after, to find out what the action
    /// actually did.
    ///
    /// A READER, not a copy the view keeps: the four facts live on `AgentRecord` and are
    /// written by `AgentSupervisor` from paths this list never sees (P4.3's inactivity
    /// sweep, P4.4's auto-unsettle). A cached snapshot would be an undo that restores
    /// what was true when the rows were last pushed.
    var lifecycleFacts: ((UUID) -> InboxLifecycleSnapshot?)?
    /// Put these agents' captured facts back, exactly as they were. ONE CALL for the
    /// whole set, because a bulk action undoes as one unit (the packet's rule) and a
    /// per-agent callback would let half a restore succeed.
    ///
    /// The toast is offered only when BOTH this and `lifecycleFacts` are set: an Undo
    /// button nothing performs is worse than no toast, which is the call P3.15 already
    /// made for the menu's greyed items.
    var onUndoLifecycle: (([UUID: InboxLifecycleSnapshot]) -> Void)?
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
    ///
    /// Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// THIS IS ALSO THE ROUTE-ACTIVE INPUT — the loudest step of the fill ladder,
    /// and deliberately not a second property beside it. Route-active means "the
    /// agent whose tile is open", `AppDelegate.focusedInboxAgentId()` already
    /// resolves exactly that from `CanvasState.lastActiveTileId`, and it already
    /// arrives here through `setInboxOpenAgent` on every sidebar reload. A new
    /// `routeActiveAgentID` would have been a second projection of one fact, which
    /// is the shape `_DESIGN.md` rules out ("one owner answers what an agent is
    /// doing"), and it would have needed a host edit to feed something the host is
    /// already feeding. Nil-safe throughout: no open tile, no route-active row,
    /// and the ladder simply has three steps instead of four.
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
        // The scope is a fixed-width ChoiceButton: project names can never resize the band.
        scopeButton = ChoiceButton(title: InboxScope.allTitle)
        scopeButton.translatesAutoresizingMaskIntoConstraints = false
        scopeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        scopeButton.preferredPopoverWidth = 124
        scopeButton.setAccessibilityLabel("Agent scope")
        searchField = NSTextField(frame: .zero)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .token(.label)
        searchField.placeholderString = "Search agents"
        searchField.setAccessibilityRole(.textField)
        searchField.setAccessibilityLabel("Search agents")

        scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = AgentInboxTableView(frame: .zero)
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
        // The table is the scroll view's document view. Keep its horizontal
        // document width following the clip viewport so a divider drag changes
        // the cell's actual fit lane in both directions, not only on the first
        // shrink.
        tableView.autoresizingMask = [.width]

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

        // A cached answer may be available from an earlier view, but the first
        // frame must still be safe when the answer is unknown. Starting the task
        // is non-blocking; its shell/auth work happens off the main actor.
        nameGenerationCapabilityAvailable = AgentSupervisor.nameGenerationCapabilityAvailable
        nameGenerationCapabilityTask = Task { [weak self] in
            let capability = await AgentSupervisor.resolveNameGenerationCapability()
            guard !Task.isCancelled else { return }
            self?.applyNameGenerationCapability(capability)
        }

        wantsLayer = true
        applyTokens()
        setAccessibilityIdentifier("ContinuumAgentInboxRoot")
        tableView.setAccessibilityIdentifier("ContinuumAgentInboxList")
        emptyLabel.setAccessibilityIdentifier("ContinuumAgentInboxEmpty")
        scopeButton.setAccessibilityIdentifier("ContinuumAgentInboxScope")
        searchField.setAccessibilityIdentifier("ContinuumAgentInboxSearch")

        addSubview(scopeButton)
        addSubview(searchField)
        addSubview(scrollView)
        addSubview(emptyLabel)
        // P3.11: added LAST, so it draws over the bottom of the list.
        addSubview(bulkBar)
        // P4.11: and the toast over the bar, which is the order they arrive in — a
        // bulk action puts the bar up first and the toast second.
        addSubview(undoToast)

        (tableView as? AgentInboxTableView)?.contextHandler = self
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
        searchField.delegate = self
        scopeButton.keepsSelectionForItem = { $0.id.hasPrefix("management:") }
        scopeButton.onSelection = { [weak self] item in self?.choicePicked(item) }
        updateScopeMenu()
        // P3.11: the bar reports the action; resolving WHICH agents it lands on is the
        // list's, because only the list knows the selection.
        bulkBar.onAction = { [weak self] action in self?.performBulkAction(action) }
        bulkBar.setAccessibilityIdentifier("ContinuumAgentInboxBulkBar")
        // P4.11: the toast reports the press; what it puts back is the list's, because
        // only the list holds what was captured at dispatch.
        undoToast.onUndo = { [weak self] in self?.performUndo() }
        undoToast.setAccessibilityIdentifier("ContinuumAgentInboxUndoToast")

        NSLayoutConstraint.activate([
            scopeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.m),
            scopeButton.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),
            scopeButton.widthAnchor.constraint(equalToConstant: 124),
            scopeButton.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            searchField.leadingAnchor.constraint(equalTo: scopeButton.trailingAnchor, constant: Space.s),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.m),
            searchField.centerYAnchor.constraint(equalTo: scopeButton.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: scopeButton.bottomAnchor, constant: Space.s),
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

            // P4.11: ABOVE THE BAR, not beside it and not under it. Both float over
            // the bottom of the same list and both can be up at once — a bulk settle
            // that the advance did not clear the selection for leaves the bar behind
            // the toast. Anchoring to the bar's top rather than to the view's bottom
            // makes non-overlap a fact of the layout instead of a timing coincidence,
            // and the bar is laid out at its full height even while hidden, so the
            // toast sits in one place whether the bar is showing or not.
            undoToast.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.s),
            undoToast.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.s),
            undoToast.bottomAnchor.constraint(equalTo: bulkBar.topAnchor, constant: -Space.xs),
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
        searchField.textColor = TextToken.textPrimary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// Re-ask every table row for its height when the sidebar divider changes the
    /// width available to the cell. `AgentInboxCellView.layout()` re-tiers the
    /// labels, but AppKit's row-height cache does not observe that cell-local
    /// change; without this invalidation a row can keep the old one-/two-line
    /// height until its content changes for an unrelated reason.
    override func layout() {
        let columnWidthAtLayoutEntry = column.width
        super.layout()
        // `NSScrollView` owns the document view's frame, but does not grow a
        // previously narrowed table back to the new clip width by itself. The
        // sidebar has no horizontal scrolling, so the table's document lane is
        // always exactly the viewport lane before heights are re-asked.
        let viewportWidth = qaViewportWidthOverride ?? scrollView.contentView.bounds.width
        if viewportWidth > 0,
           tableView.frame.width != viewportWidth || column.width != viewportWidth {
            var frame = tableView.frame
            frame.size.width = viewportWidth
            tableView.frame = frame
            // Column autoresizing is not retroactive for a document view that
            // was already narrowed, so keep the one row column in the same lane
            // as the table before its cells lay themselves out.
            column.width = viewportWidth
        }
        // `tableView.bounds.width` includes the scroll view's document lane,
        // while the vertical scroller can make the actual row column narrower.
        // Height derivation must use the same column width the live cell receives.
        let width = column.width
        guard width > 0 else { return }
        // Tier boundaries are measured values, and a fractional divider move can
        // cross one. Do not hide any width change behind a point-sized tolerance:
        // AppKit's widths are fractional and the height cache must follow the
        // actual lane, not a rounded approximation of it.
        let widthChanged = columnWidthAtLayoutEntry != width
            || (lastTableWidthForHeightCache.map { $0 != width } ?? true)
            || (lastHeightQueryColumnWidth.map { $0 != width } ?? false)
        lastTableWidthForHeightCache = width
        guard (widthChanged || needsHeightRevalidation), tableView.numberOfRows > 0,
              !isInvalidatingHeightsForWidth else { return }
        needsHeightRevalidation = false
        isInvalidatingHeightsForWidth = true
        let indexes = IndexSet(0..<tableView.numberOfRows)
        let selectedIDs = selectedRows.map(\.id)
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        // Rebuild the live cells as well as their cached heights. The cell owns
        // the measured-fit tier, and a document view can otherwise retain a
        // narrow cell frame after its column has widened. A full reload is used
        // on this resize-only path because AppKit may be in the middle of a
        // virtual row pass; restore the selection by identity immediately after.
        cellsByRow.removeAll()
        tableView.reloadData()
        // The width change can happen during the parent's layout pass. Drive the
        // table's own pass now so its row views receive the same height the
        // delegate just returned before a host-level clipping probe inspects them.
        tableView.layoutSubtreeIfNeeded()
        let restoredSelection = IndexSet(selectedIDs.compactMap(tableRow(forAgentId:)))
        tableView.selectRowIndexes(restoredSelection, byExtendingSelection: false)
        selectedRowsForEmphasis = restoredSelection
        // The full reload built cells while the table selection was empty. Rebuild
        // selected rows once more so their interaction fill is painted from the
        // restored selection rather than only remembered in the table model.
        if !restoredSelection.isEmpty {
            tableView.reloadData(
                forRowIndexes: restoredSelection, columnIndexes: IndexSet(integer: 0))
            tableView.layoutSubtreeIfNeeded()
        }
        // The rename editor lives above the table, so rebuilding cells does not
        // move it with the title it is editing. Resize is a real geometry change
        // even when the row identity and content stay put: a fit-tier transition
        // can change both the title's Y and the row's document position. Follow
        // the rebuilt live cell here, not only from applyRows.
        repositionRenameField()
        needsHeightRevalidation = false
        isInvalidatingHeightsForWidth = false
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
        // P4.12: a ghost is a view held at a rect in the list it was lifted from, and
        // that list is being replaced. Any still fading are dropped here rather than
        // left to their timers — the row under them is a different agent now.
        cancelCrossfades()
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
        // P1.2: the list under the pointer just changed, so hover is re-derived
        // from the pointer rather than carried over or dropped. This is the row
        // REUSE half of "no row is left lit": `reloadData` rebuilt every cell,
        // and the agent under the mouse may now be a different one.
        refreshHoverFromPointer()
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
        // P4.12: lifted BEFORE anything is told to the table, and started after —
        // whichever of the two branches inside `applyRows` ran. Which reload strategy
        // the list needed is a fact about the LIST; whether a row changed shape is a
        // fact about the AGENT, and only the second one is what crossfades.
        // `newRows` RAW and not the drawn list: the diff reads nothing but id and
        // variant, both of which survive the scope, the sort and the folds untouched
        // — and `display(from:)` assigns `parentsWithChildren`, so calling it a second
        // time here would hand `applyRows` its own answer as the previous one and
        // P2D.4's disclosure-moved rows would go unredrawn.
        let lifted = liftCrossfadeGhosts(from: rows, to: newRows)
        applyRows(newRows, changed: changed)
        startCrossfades(lifted)
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
        let valueChanged = Set(zip(previous, next.compactMap(\.agentRow))
            .filter { $0.0 != $0.1 }
            .map { $0.1.id })
        // Hold an unaffected visible row as the user's visual anchor. A numeric
        // clip origin is not enough when a preceding row grows: AppKit must keep
        // the content the user was reading in the same viewport position.
        let scrollAnchor = visibleScrollAnchor(
            excluding: changed.touched.union(valueChanged))
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
        layoutSubtreeIfNeeded()
        restoreScrollAnchor(scrollAnchor)
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
        let scoped = InboxScope.filter(rows: newRows, scope: scope, openAgentId: openAgentId)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let searched = query.isEmpty ? scoped : scoped.filter { row in
            [row.title, row.projectName, row.workspaceName, row.model, row.branch]
                .compactMap { $0?.localizedLowercase }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let sorted = InboxSort.sortForInbox(rows: searched)
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
        // P1.2: hover and the focus ring are dropped and then RE-DERIVED from
        // where the pointer actually is once the new list is on screen
        // (`render` ends in `refreshHoverFromPointer()`), so a fold or a scope
        // flip cannot leave a row lit that the pointer is no longer over — and
        // cannot un-light the row it still is over either.
        hoveredAgentId = nil
        keyboardFocusIntent = nil
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
        // P1.2: hover and the focus ring are dropped and then RE-DERIVED from
        // where the pointer actually is once the new list is on screen
        // (`render` ends in `refreshHoverFromPointer()`), so a fold or a scope
        // flip cannot leave a row lit that the pointer is no longer over — and
        // cannot un-light the row it still is over either.
        hoveredAgentId = nil
        keyboardFocusIntent = nil
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
        // P1.2: hover and the focus ring are dropped and then RE-DERIVED from
        // where the pointer actually is once the new list is on screen
        // (`render` ends in `refreshHoverFromPointer()`), so a fold or a scope
        // flip cannot leave a row lit that the pointer is no longer over — and
        // cannot un-light the row it still is over either.
        hoveredAgentId = nil
        keyboardFocusIntent = nil
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
        // P1.2: hover and the focus ring are dropped and then RE-DERIVED from
        // where the pointer actually is once the new list is on screen
        // (`render` ends in `refreshHoverFromPointer()`), so a fold or a scope
        // flip cannot leave a row lit that the pointer is no longer over — and
        // cannot un-light the row it still is over either.
        hoveredAgentId = nil
        keyboardFocusIntent = nil
        updateScopeMenu()
        render(display(from: allRows))
        if notify { onScopeChange?(next) }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        let next = searchField.stringValue
        guard next != searchQuery else { return }
        searchQuery = next
        tableView.deselectAll(nil)
        selectedRowsForEmphasis = IndexSet()
        hoveredAgentId = nil
        keyboardFocusIntent = nil
        render(display(from: allRows))
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
        updateScopeMenu()
    }

    private func restoreScopeSelection() {
        let id = scope.storageValue
        scopeButton.selectedID = id
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
        scopeEntries = entries
        var items = entries.map { ChoiceItem(id: $0.storageValue, title: $0.title) }
        managementItems.removeAll()
        // Keep every management affordance visible. Unsupported actions are
        // disabled in place, rather than disappearing and making the menu's
        // contract depend on the current workspace count.
        items.append(ChoiceItem(id: "management-separator", title: "────────", enabled: false))
        for action in WorkspaceManagementAction.allCases {
            let item = ChoiceItem(id: "management:\(action.title)", title: action.title,
                                  enabled: action == .create || (action == .rename ? canRenameWorkspace : canDeleteWorkspace))
            managementItems[action] = item
            items.append(item)
        }
        scopeButton.items = items
        restoreScopeSelection()
    }

    private func choicePicked(_ item: ChoiceItem) {
        if let entry = scopeEntries.first(where: { $0.storageValue == item.id }) {
            setScope(entry, notify: true)
            return
        }
        guard let action = WorkspaceManagementAction.allCases.first(where: { item.id == "management:\($0.title)" }) else { return }
        restoreScopeSelection()
        onWorkspaceManagementAction?(action)
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
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyLabel.stringValue = "No agents matching \"\(searchQuery)\" in \(scope.title)"
            } else {
                emptyLabel.stringValue = AgentInboxView.scopedEmptyMessage
            }
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

    /// P3.7: parked rows still use their one-line variant. Card rows, however,
    /// ask the content-derived height path for the bands this row actually draws;
    /// the list never branches on state, attention, or lifecycle importance.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        lastHeightQueryColumnWidth = column.width
        guard let model = item(at: row)?.agentRow else { return AgentInboxView.shelfHeaderHeight }
        let indent = Double(max(0, model.depth)) * AgentInboxView.indentPerLevel
        let available = max(
            0,
            Double(column.width) - indent - Inset.card.horizontal)
        return AgentInboxView.height(
            for: model,
            availableWidth: available,
            disclosure: disclosure(for: model),
            rollup: rollupsByParent[model.id])
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The shelf header is a HEADING, not a row you can act on. Unselectable, so it
    /// cannot end up in a multi-selection (P3.11) that a bulk action then tries to
    /// apply to a section, and so arrow-keying past it does not clear the bar.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        item(at: row)?.agentRow != nil
    }

    /// Native NSTableView type-select asks its delegate for the row's searchable
    /// text. Headings return nil so typing can never focus a non-agent section row.
    func tableView(
        _ tableView: NSTableView,
        typeSelectStringFor tableColumn: NSTableColumn?,
        row: Int
    ) -> String? {
        item(at: row)?.agentRow?.displayTitle
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
        needsHeightRevalidation = true
        // AppKit may ask for a cell before it has assigned the row frame. Give
        // the cell the live column width before `apply` measures its fit tier;
        // otherwise an empty initial frame leaves a hidden band visible while
        // the table has already cached the shorter content-derived height.
        cell.setLayoutWidth(Double(column.width))
        var cellFrame = cell.frame
        cellFrame.size.width = column.width
        cell.frame = cellFrame
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
        // P1.2/P1.4: the interaction ladder is set through its own call for the
        // reason the pill below is — `apply` paints what the agent IS, and where
        // the pointer and the keyboard are is not that.
        cell.applyInteraction(interaction(forTableRow: row))
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
        // P1.4: which INPUT moved the selection decides whether the focus ring is
        // armed, and it is resolved before the rows are redrawn so the ring and
        // the fill are painted by the SAME rebuild — see `setKeyboardFocus`.
        let focusTouched = updateKeyboardFocusForSelection()
        redraw(tableRows: Array(previous.symmetricDifference(tableView.selectedRowIndexes))
            + focusTouched)
        updateBulkBar()
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.9-reveal-on-click.md
    @objc private func rowClicked(_ sender: Any?) {
        _ = activateRow(
            atTableRow: tableView.clickedRow,
            event: NSApp.currentEvent)
    }

    /// The one activation path for the table's ordinary click action. Keeping the
    /// trailing-double-click guard here, next to the host callback, is what makes
    /// the event proof non-vacuous: a field may open and the table may still send
    /// an action, but that action cannot reveal the row.
    @discardableResult
    private func activateRow(atTableRow tableRow: Int, event: NSEvent?) -> Bool {
        guard let index = rowIndex(forTableRow: tableRow), rows.indices.contains(index) else {
            return false
        }
        let agentId = rows[index].id
        if let event, event.clickCount > 1 {
            // AppKit may deliver the table action for the second click as well as
            // the doubleAction. It is the trailing click, never a new navigation.
            suppressedTrailingActivationAgentId = nil
            return false
        }
        if let suppressed = suppressedTrailingActivationAgentId {
            suppressedTrailingActivationAgentId = nil
            guard suppressed != agentId else { return false }
        }
        // P3.11: a shift- or ⌘-click is a SELECTION gesture, not navigation.
        let modifiers = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        guard AgentInboxView.revealsOnClick(modifiers: modifiers) else { return false }
        reveal(rowAt: index)
        return true
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

    // MARK: - Keyboard traversal

    /// Handle keys whose meaning belongs to the inbox rather than NSTableView.
    /// Return opens the focused row and Space previews it; both are deliberately
    /// no-ops for headings and an empty selection. Native table navigation keeps
    /// ownership of arrows, Home/End, page keys, type-select, and modifier range
    /// selection.
    @discardableResult
    func handleTableActivationKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 115 where modifiers.isEmpty: // Home
            return moveKeyboardSelection(toAgentPosition: 0)
        case 119 where modifiers.isEmpty: // End
            return moveKeyboardSelection(toAgentPosition: rows.count - 1)
        case 116 where modifiers.isEmpty: // Page Up
            return moveKeyboardSelectionByPage(-1)
        case 121 where modifiers.isEmpty: // Page Down
            return moveKeyboardSelectionByPage(1)
        default:
            break
        }
        guard modifiers.isEmpty,
              let id = agentIdForTableRow(tableView.selectedRow) else { return false }
        switch event.keyCode {
        case 36: // Return
            reveal(rowAt: rows.firstIndex(where: { $0.id == id }) ?? -1)
            return true
        case 49: // Space
            onPreviewRow?(id)
            return true
        default:
            return false
        }
    }

    private func moveKeyboardSelection(toAgentPosition position: Int) -> Bool {
        guard rows.indices.contains(position), let tableRow = tableRow(forRowIndex: position) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(tableRow)
        return true
    }

    private func moveKeyboardSelectionByPage(_ direction: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let stride = max(1, visibleRows.length - 1)
        let currentPosition = rowIndex(forTableRow: tableView.selectedRow)
            ?? (direction > 0 ? 0 : rows.count - 1)
        let target = min(max(0, currentPosition + direction * stride), rows.count - 1)
        return moveKeyboardSelection(toAgentPosition: target)
    }

    /// Make every native traversal key a visibility operation as well. AppKit
    /// changes the selection during `super.keyDown`; scrolling afterwards avoids
    /// a one-event lag where Return could act on a row that is still off-screen.
    func didTraverseWithKeyboard(_ event: NSEvent) {
        let traversalKeys: Set<UInt16> = [115, 116, 121, 119, 126, 125]
        let row = tableView.selectedRow
        guard traversalKeys.contains(event.keyCode), row >= 0 else { return }
        tableView.scrollRowToVisible(row)
    }

    /// Global shortcuts must yield to text entry. The search field and inline
    /// rename editor are descendants of the inbox, but typing in either must not
    /// make ⌘1–⌘9 (or another reserved shortcut) act on the list.
    func allowsGlobalShortcuts(for responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return true }
        if view === searchField || view.isDescendant(of: searchField)
            || searchField.currentEditor() === view { return false }
        if let renameField,
           view === renameField || view.isDescendant(of: renameField)
            || renameField.currentEditor() === view { return false }
        return true
    }

    /// The responder is a live text editor, not merely a descendant of the
    /// sidebar. AppDelegate uses this before reserved dispatch so a rejected
    /// inbox jump cannot turn into a global launch shortcut.
    var isTextEditorFocusedForGlobalShortcutGate: Bool {
        guard let responder = window?.firstResponder else { return false }
        return !allowsGlobalShortcuts(for: responder)
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

    /// The second click of a plain double-click. The entire row BODY is a rename
    /// target, but a nested control keeps its own gesture. The event guard is kept
    /// here and in `doubleClick(rowAt:pointInCell:modifiers:)` so neither AppKit nor
    /// a headless probe can bypass the modifier/active-editor rules.
    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        guard let index = rowIndex(forTableRow: tableView.clickedRow),
              let cell = cellForRow(index) else { return }
        _ = doubleClick(
            rowAt: index,
            pointInCell: cell.convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags)
    }

    /// The routing half of the gesture, taking the point in the CELL's coordinates
    /// rather than an `NSEvent` — a headless check can call this, and it is the same
    /// code the real double-click runs (`rowDoubleClicked` only unpacks the event).
    /// The row body is deliberately broader than the title label: name, metadata
    /// and empty body are all the row's surface; only a nested control is excluded.
    @discardableResult
    func doubleClick(
        rowAt index: Int,
        pointInCell point: NSPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        let deviceModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard deviceModifiers.isEmpty,
              rows.indices.contains(index),
              let cell = cellForRow(index),
              cell.acceptsRenameDoubleClick(at: point),
              renameField == nil,
              renamingRowId == nil else { return false }
        guard beginRename(rowAt: index) else { return false }
        // NSTableView can still deliver its normal action for this same second
        // click. Consume that trailing action in `activateRow` so opening an editor
        // never also reveals the row.
        suppressedTrailingActivationAgentId = rows[index].id
        return true
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
        // A second double-click while an editor is open is still part of the
        // current edit, not an implicit commit-and-switch. Returning here is what
        // lets the active field keep the text the human is typing.
        guard renameField == nil, renamingRowId == nil else { return false }
        guard let field = installRenameField(rowAt: index) else { return false }
        isOpeningRename = true
        defer { isOpeningRename = false }
        window?.makeFirstResponder(field)
        field.selectText(nil)
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
        // P1.3: the shared hairline, not a 1pt literal. `_DESIGN.md` caps every
        // boundary the sidebar keeps at 0.5pt and this is one of the four this
        // program had left.
        field.layer?.borderWidth = LineWidth.hairline
        // `focusRing`, the ROLE for focus and selection (it resolves to the same
        // `borderStrong` this line used to name directly — the role carries the
        // contrast reasoning, a raw `LineToken` carries only a value). An open
        // editor is the one thing on this list holding the keyboard, and after
        // P1.1 no row draws a perimeter for it to be confused with.
        field.layer?.borderColor = AgentLineRole.focusRing.color.cgColor(in: self)
        field.delegate = self
        field.setAccessibilityIdentifier("ContinuumAgentInboxRenameField")
        addSubview(field, positioned: .above, relativeTo: nil)
        didCommitRename = false
        lastEndedRenameFieldForQA = nil
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
        // Return and blur can describe the same end of editing. The first path
        // owns the commit; every later notification is an acknowledgement only.
        guard !didCommitRename else { return }
        didCommitRename = true
        let typed = field.stringValue
        // STATE FIRST, THEN THE VIEW: removing a field that holds the field editor
        // posts `controlTextDidEndEditing` SYNCHRONOUSLY. Clearing the active field
        // before removal makes that re-entrant notification harmless; the explicit
        // did-commit flag also covers a later blur notification for the same field.
        renameField = nil
        renamingRowId = nil
        lastEndedRenameFieldForQA = field
        field.removeFromSuperview()
        // If AppKit did not send the trailing table action, do not carry its
        // suppression into the next ordinary click after editing ends. A real
        // second-click event is independently rejected by clickCount above.
        suppressedTrailingActivationAgentId = nil
        guard commit else {
            qaRenameCancelCount += 1
            return
        }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != rows.first(where: { $0.id == rowId })?.title else { return }
        qaRenameCommitCount += 1
        onRenameRow?(rowId, trimmed)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renameField, !didCommitRename else { return false }
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
        // being installed (see `isOpeningRename`), and ignore any stale field after
        // Return/Escape has already finished the edit.
        guard !isOpeningRename,
              !didCommitRename,
              (obj.object as? NSTextField) === renameField else { return }
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
    /// Only coalesce a callback that re-enters while the same activation is still
    /// executing. The host owns confirmation and may cancel it; a permanent key
    /// would consume that canceled action and also suppress a later legitimate
    /// activation after the rows changed.
    private var activeBulkActions: Set<String> = []

    private func performBulkAction(_ action: InboxBulkAction) {
        let selected = selectedRows
        guard selected.count >= AgentInboxView.minimumBulkSelection,
              offeredBulkActions(for: selected).contains(action)
        else { return }
        // A duplicate callback is suppressed only while this activation is in flight.
        // This is intentionally cleared on return so host cancellation and a later
        // action on the same IDs remain eligible.
        let key = action.rawValue + ":" + selected.map(\.id.uuidString).joined(separator: ",")
        guard activeBulkActions.insert(key).inserted else { return }
        defer { activeBulkActions.remove(key) }
        // P4.10: armed BEFORE the host runs, because a synchronous host pushes the new
        // rows from inside this call — by the time it returns the affected rows have
        // already left the places the advance is measured from.
        if AgentInboxView.advancesSelection(action) { armAdvance(targetIds: selected.map(\.id)) }
        // P4.11: captured BEFORE the host runs, for the same reason the advance is
        // armed here — the action performs inside that call, and afterwards nothing can
        // say what these agents were.
        let captured = captureLifecycle(selected.map(\.id))
        onBulkAction?(action, selected.map(\.id))
        offerUndo(action.undoVerb, capturedInOrder: captured)
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

    /// Present the choice-family menu for a real right-click or Control-click.
    /// Selection changes only when the pointer is outside an existing multi-selection.
    fileprivate func presentContextMenu(for event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        presentContextMenu(atTableRow: tableView.row(at: point), anchor: NSRect(origin: point, size: .zero))
    }

    @discardableResult
    private func presentContextMenu(atTableRow tableRow: Int, anchor: NSRect) -> Bool {
        guard let index = rowIndex(forTableRow: tableRow), rows.indices.contains(index) else {
            rowChoiceController.dismiss()
            qaChoiceListForQA = nil
            rowChoiceTargetIds.removeAll()
            return false
        }
        // A context click inside a multi-selection acts on the selection; outside it
        // retargets to exactly the clicked row before the menu is built.
        if tableView.selectedRowIndexes.count <= 1 || !tableView.selectedRowIndexes.contains(tableRow) {
            tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
        }
        let targets = targetRows(forClickedRow: index)
        let actions = InboxRowAction.menuItems(
            for: targets,
            includeGeneratedName: wiredRowActions.contains(.generateName)
                && nameGenerationCapabilityAvailable
        ).filter { action in
            // Context menus are capability surfaces: unsupported, unwired, plural-open,
            // and multi-row rename actions are absent rather than dead rows.
            isWired(action) && targets.count == 1 &&
                targets.allSatisfy { action.isAvailable(for: $0, rollups: rollupsByParent) } ||
                action != .openInTile && action != .rename && isWired(action) &&
                targets.allSatisfy { action.isAvailable(for: $0, rollups: rollupsByParent) }
        }
        rowChoiceTargetIds = targets.map(\.id)
        guard !actions.isEmpty else { rowChoiceController.dismiss(); qaChoiceListForQA = nil; return false }
        let items = actions.map { action in
            ChoiceItem(
                id: action.rawValue,
                title: action.title(forCount: targets.count),
                detail: action == .delete || action == .archive ? "This cannot be undone." : nil,
                destructive: action == .delete || action == .archive
            )
        }
        let onSelection: (ChoiceItem) -> Void = { [weak self] item in
            guard let self, let action = InboxRowAction(rawValue: item.id) else { return }
            self.performRowAction(action)
        }
        if tableView.window == nil {
            // Headless checks retain the same ChoiceListView the controller presents;
            // only the AppKit panel is unavailable without a window.
            let list = ChoiceListView(items: items, selectedID: nil)
            list.onSelection = onSelection
            qaChoiceListForQA = list
            return true
        }
        qaChoiceListForQA = nil
        rowChoiceController.present(
            items: items, selectedID: nil, anchor: anchor,
            relativeTo: tableView,
            onSelection: onSelection, focusReturnView: tableView
        )
        // The controller owns the production list even when AppKit cannot make the
        // transient panel visible in a headless probe (for example, before the app
        // activates its window). QA reads that same list, not a parallel menu model.
        if rowChoiceController.listView == nil {
            let list = ChoiceListView(items: items, selectedID: nil)
            list.onSelection = onSelection
            qaChoiceListForQA = list
        }
        return rowChoiceController.listView != nil || qaChoiceListForQA != nil
    }

    /// Capability resolution invalidates an open panel; the next gesture derives a
    /// fresh action set, so an unsupported affordance cannot remain visible.
    private func applyNameGenerationCapability(_ capability: AgentNameGenerationCapability?) {
        let available = capability != nil
        guard nameGenerationCapabilityAvailable != available else { return }
        nameGenerationCapabilityAvailable = available
        rowChoiceController.dismiss()
        rowChoiceTargetIds.removeAll()
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
        let targets = rowChoiceTargetIds.compactMap { id in rows.first { $0.id == id } }
        guard action.disabledReason(
            for: targets, isWired: isWired(action), rollups: rollupsByParent) == nil else { return }
        switch action {
        case .openInTile:
            guard let first = targets.first else { return }
            onRevealRow?(first.id)
        case .rename:
            guard targets.count == 1, let target = targets.first else { return }
            _ = beginRename(agentId: target.id)
        case .settle, .unsettle, .snooze, .wake, .markUnread, .generateName, .stopAgent,
             .archive, .delete:
            // P4.10: armed before the host runs, for the reason `performBulkAction`
            // records — a synchronous host has already re-pushed by the time it returns.
            if AgentInboxView.advancesSelection(action) { armAdvance(targetIds: targets.map(\.id)) }
            // P4.11: captured before the host runs, for the reason `performBulkAction`
            // records.
            let captured = captureLifecycle(targets.map(\.id))
            onRowAction?(action, targets.map(\.id))
            offerUndo(action.undoVerb, capturedInOrder: captured)
            // Retired here for the reason `performBulkAction` records: an advance the
            // action did not land is an advance that never happens.
            pendingAdvance = nil
        }
    }

    /// Whether the host can perform this action at all. `openInTile` rides P3.9's
    /// existing callback; everything else needs `onRowAction` AND a host that named
    /// this action in `wiredRowActions` (P3.15) — one gate for every row action is what made
    /// wiring Delete mean also offering a Snooze that goes nowhere.
    private func isWired(_ action: InboxRowAction) -> Bool {
        switch action {
        case .openInTile: return onRevealRow != nil
        case .rename:
            // Inline rename is a row-local production path; it does not require the
            // lifecycle callback used by the remaining host-owned actions.
            return true
        case .settle, .unsettle, .snooze, .wake, .markUnread, .generateName, .stopAgent,
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
        case .openInTile, .unsettle, .wake, .markUnread, .rename, .generateName, .stopAgent: return false
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

    // MARK: - Undo toast (P4.11)

    /// How long the toast stays up. ~6s is the packet's number: long enough to notice a
    /// mis-aimed snooze on a list you were moving through quickly, short enough that it
    /// is gone before it becomes furniture. A `var` only so a check can drive the real
    /// timer instead of waiting six seconds for it.
    var undoToastDuration: TimeInterval = 6

    /// What these agents are RIGHT NOW, before the action touches them.
    ///
    /// Empty when the host cannot both read and restore — with no restore path the
    /// capture would only pay for a toast whose Undo does nothing, which is the "not an
    /// undo affordance" failure the packet's watch-out names from the other side.
    private func captureLifecycle(_ ids: [UUID]) -> [(id: UUID, facts: InboxLifecycleSnapshot)] {
        guard onUndoLifecycle != nil, let reader = lifecycleFacts else { return [] }
        return ids.compactMap { id in reader(id).map { (id: id, facts: $0) } }
    }

    /// Put the toast up for what the action actually did — or leave it down.
    ///
    /// REVERSIBILITY IS MEASURED, NOT ASSUMED FROM THE VERB. A target counts only when
    /// the host can still read it back AND its facts moved:
    ///
    ///   * an agent whose facts did not move was refused (a cancelled Delete, an action
    ///     the host declined) and there is nothing to undo;
    ///   * an agent the reader no longer knows is GONE, which on this app is what
    ///     Archive and Delete both do — `AgentSupervisor.archive` removes the record
    ///     from disk, and four lifecycle fields cannot put a deleted record back. So
    ///     archiving raises no toast rather than an Undo that would silently half-work.
    ///
    /// With nothing reversible left, no toast: the packet's watch-out is that this is an
    /// undo affordance and not a notification channel, so a toast with nothing behind it
    /// is exactly what it must not be.
    private func offerUndo(
        _ verb: String?, capturedInOrder captured: [(id: UUID, facts: InboxLifecycleSnapshot)]
    ) {
        // A NON-LIFECYCLE ACTION LEAVES WHAT IS UP ALONE: marking a row unread or
        // renaming it moves none of the four fields, so a toast from a moment ago is
        // still telling the truth and is still safe to press.
        guard let verb else { return }
        // ONE TOAST AT A TIME (the packet's rule), and it is retired HERE rather than at
        // the point a replacement is built. A lifecycle action has just run, so whatever
        // the previous card was holding is stale whether or not this one earns a card of
        // its own — and the case that matters is the one that does not: snoozing a row
        // and then archiving it would otherwise leave the snooze's Undo on screen,
        // offering to restore four fields onto a record that is gone. (Raised in
        // cross-review.)
        dismissUndoToast()
        guard let reader = lifecycleFacts, !captured.isEmpty else { return }
        let reversible = captured.compactMap { target -> (id: UUID, facts: InboxLifecycleSnapshot, now: InboxLifecycleSnapshot)? in
            guard let now = reader(target.id), now != target.facts else { return nil }
            return (id: target.id, facts: target.facts, now: now)
        }
        guard !reversible.isEmpty else { return }
        pendingUndo = Dictionary(uniqueKeysWithValues: reversible.map { ($0.id, $0.facts) })
        undoToast.show(InboxUndoToast.message(
            verb: verb, count: reversible.count,
            // The wake time is read off what the action LEFT, in screen order — the view
            // is never told which preset was picked (the menu's `Snooze ›` hands the host
            // the verb and the host resolves the date, P4.5), so the only place the hour
            // exists is the record the action wrote.
            snoozedUntil: reversible.first?.now.snoozedUntil))
        restartUndoToastTimer()
    }

    private func restartUndoToastTimer() {
        undoToastTimer?.invalidate()
        undoToastTimer = Timer.scheduledTimer(
            withTimeInterval: undoToastDuration, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUndoToast() }
        }
    }

    private func dismissUndoToast() {
        undoToastTimer?.invalidate()
        undoToastTimer = nil
        pendingUndo = nil
        undoToast.hide()
    }

    /// Hand the host back exactly what was captured.
    ///
    /// THE WHOLE SET IN ONE CALL, and cleared before the call rather than after: the
    /// host restores and re-pushes synchronously (the path every other action here
    /// takes), so a `pendingUndo` still set during that push is one a second press
    /// arriving from the re-render could spend on facts this restore has already put
    /// back.
    private func performUndo() {
        guard let restoring = pendingUndo else { return }
        dismissUndoToast()
        onUndoLifecycle?(restoring)
    }

    /// P3.5's `isInteracting`: hover, selection, or keyboard-active. The last two
    /// are one test rather than two, because arrow-key navigation in an
    /// `NSTableView` IS a selection move — a keyboard-active row and the selected
    /// row are the same row by construction.
    ///
    /// P1.2 LEFT THIS ALONE, deliberately, and split the FILL out beside it
    /// instead. This one test still answers the question P3.5 asked it —
    /// "is this row's recession cleared?" — and the answer is genuinely the same
    /// for all three inputs, because recession is about whether you are engaged
    /// with the row at all. The fills are a different question with three
    /// different answers (`interaction(forTableRow:)`), so they get three tests.
    private func isInteracting(row: Int) -> Bool {
        row == hoveredRow || tableView.selectedRowIndexes.contains(row)
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// The three fill/ring facts for one table row, each answered separately.
    private func interaction(forTableRow row: Int) -> RowInteraction {
        guard let id = agentIdForTableRow(row) else { return .none }
        return RowInteraction(
            isHovered: id == hoveredAgentId,
            isRouteActive: id == openAgentId,
            hasKeyboardFocus: id == keyboardFocusAgentId
        )
    }

    /// Rebuild the cells of just these rows, ignoring any that are not on screen.
    private func redraw(tableRows indexes: [Int]) {
        let touched = IndexSet(indexes.filter { items.indices.contains($0) })
        guard !touched.isEmpty else { return }
        tableView.reloadData(forRowIndexes: touched, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Crossfading a lifecycle move (P4.12)

    /// The outgoing cell of every row whose variant is about to change, lifted out
    /// of the table and held at the frame it is drawn at RIGHT NOW.
    ///
    /// Taken BEFORE the table is told anything, which is the whole of the timing:
    /// once the rows are replaced the old view is gone from the hierarchy and its
    /// rect is somebody else's. `makeIfNecessary: false` throughout — a row that is
    /// scrolled out of view has no view to fade and must not be given one.
    private func liftCrossfadeGhosts(from previous: [AgentInboxRow], to next: [AgentInboxRow])
        -> [(id: UUID, view: NSView, frame: NSRect)]
    {
        guard !prefersReducedMotion() else { return [] }
        var variantByPrevious: [UUID: RowVariant] = [:]
        for row in previous { variantByPrevious[row.id] = row.variant }
        var lifted: [(id: UUID, view: NSView, frame: NSRect)] = []
        for row in next {
            // An agent that was not on screen has no previous variant, so a fresh
            // push that brings in a whole list crossfades nothing — which is the
            // packet's "do not animate during a full reload", enforced by the diff
            // rather than by guessing which reload path is about to run.
            guard let was = variantByPrevious[row.id], was != row.variant,
                  let tableRow = tableRowByAgentId[row.id],
                  let view = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
            else { continue }
            lifted.append((row.id, view, tableView.rect(ofRow: tableRow)))
        }
        return lifted
    }

    /// Fade the old view out where it stood, and the new one in where the row now
    /// is.
    ///
    /// NOTHING TRAVELS, and that is the point: these rows are translucent, so a
    /// card animating down the list to its settled position paints its text over
    /// every row it crosses. The outgoing card is left at its old frame and fades;
    /// the slim row appears at its settled position and fades up. The rows between
    /// them are already where they belong — the list re-laid out instantly, and
    /// only the two views that swapped are animated.
    ///
    /// The ghost is parented to the TABLE and not to this view, so it scrolls with
    /// the content it belongs to instead of hanging in the sidebar; the clip view
    /// bounds it, so a ghost lifted from a row you then scroll away from is clipped
    /// exactly like the row would have been.
    private func startCrossfades(_ lifted: [(id: UUID, view: NSView, frame: NSRect)]) {
        guard !lifted.isEmpty else { return }
        tableView.layoutSubtreeIfNeeded()
        let drawn = tableRowByAgentId
        for (id, view, frame) in lifted {
            // A CROSSFADE NEEDS TWO VIEWS. The diff above reads the raw push, where a
            // row's id and variant are exact but its VISIBILITY is not: `display` can
            // take the new row off screen entirely — a snooze into a collapsed shelf,
            // a settle past the end of the paged tail, a child under a folded parent.
            // That is a departure, not a transition, and holding a card at an old rect
            // with nothing arriving to replace it is the stranded ghost this whole
            // section is about. (Raised in cross-review.)
            guard let arriving = drawn[id].flatMap({
                tableView.view(atColumn: 0, row: $0, makeIfNecessary: false)
            }) else { continue }
            view.removeFromSuperview()
            view.frame = frame
            view.autoresizingMask = []
            crossfadingCells[id]?.removeFromSuperview()
            crossfadingCells[id] = view
            tableView.addSubview(view)
            // The incoming view fades UP from nothing rather than being cut in over
            // the ghost: two views at full strength for a frame is the doubled text
            // the crossfade exists to avoid.
            arriving.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AgentInboxView.crossfadeDuration
                view.animator().alphaValue = 0
                arriving.animator().alphaValue = 1
            }
            // TEARDOWN IS SCHEDULED, not hung off the animation's completion
            // handler. A completion handler is a promise made by whichever animator
            // ends up driving the layer, and a ghost left behind because one never
            // fired is a card painted over the list forever. This fires off the main
            // queue on its own, and `endCrossfade` is idempotent and identity-checked
            // so a superseded ghost's timer cannot take a live one down with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentInboxView.crossfadeDuration) {
                [weak self] in
                // The arriving view is put back to full strength here for the same
                // reason: it was dimmed to 0 by THIS code, so the only thing that may
                // be trusted to undo that is this code. If the animator never ran, the
                // row appears at the end of the duration instead of never.
                //
                // …UNLESS IT HAS SINCE BECOME A GHOST ITSELF. In a fast card → slim →
                // card sequence the view this fade was bringing in is the view the next
                // one is taking out, and a stale timer restoring it to full strength
                // would pop the outgoing card back into view on its way out. Only a
                // view nobody is currently fading may be restored. (Raised in
                // cross-review.)
                self?.finishArrival(arriving)
                self?.endCrossfade(id: id, view: view)
            }
        }
    }

    /// Put an incoming view back to full strength, unless it is now on its own way
    /// out — a view that is currently somebody's ghost belongs to that fade.
    private func finishArrival(_ view: NSView) {
        guard !crossfadingCells.values.contains(where: { $0 === view }) else { return }
        view.alphaValue = 1
    }

    /// Retire one ghost, if it is still the one that agent owns.
    private func endCrossfade(id: UUID, view: NSView) {
        guard crossfadingCells[id] === view else { return }
        crossfadingCells.removeValue(forKey: id)
        view.removeFromSuperview()
    }

    /// Drop every ghost immediately. The list they were lifted out of is gone, so
    /// there is nothing left for them to be fading away from.
    private func cancelCrossfades() {
        for view in crossfadingCells.values { view.removeFromSuperview() }
        crossfadingCells.removeAll()
    }

    /// Where each agent is drawn right now, by id — the lookup the crossfade needs
    /// on both sides of a push, and the one thing `rowIndexByTableRow` cannot
    /// answer without a linear walk per row.
    private var tableRowByAgentId: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let tableRow = tableRow(forRowIndex: index) { map[row.id] = tableRow }
        }
        return map
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
        setHovered(agentId: agentId(atWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(agentId: nil)
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// Subscribe to the two events that move a row out from under the pointer
    /// without the pointer moving: the list SCROLLING, and the window losing key.
    ///
    /// `.mouseMoved` cannot cover either. A scroll fires no mouse-moved event, so
    /// without the first the row the pointer is now over stays unlit and the one
    /// it left stays lit — the classic stuck-hover bug, one step removed from the
    /// row-reuse version of it. And a window that stops being key stops delivering
    /// tracking events at all (`.activeInKeyWindow`), so without the second the
    /// last hovered row stays lit behind an app you switched away from.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        // TOKENS, and never `removeObserver(self)`. The blanket form is one call
        // and it is wrong here: `NSView` and `NSTableView` register the view
        // itself as an observer of AppKit's own notifications, and removing those
        // took the table's deferred incremental reload with it — measured,
        // `--agent-inbox-check`: `selecting a row must clear its recession — text
        // alpha 0.88, wanted 1.0`, on a selection that had really moved.
        for token in interactionObservers { center.removeObserver(token) }
        interactionObservers = []
        guard let window else {
            setHovered(agentId: nil)
            setKeyboardFocus(agentId: nil)
            return
        }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        interactionObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHoverFromPointer() }
        })
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification] {
            interactionObservers.append(center.addObserver(
                forName: name, object: window, queue: nil
            ) { [weak self] _ in
                // Both transient treatments go: a lit row and a focus ring are
                // each a statement about what the pointer and the keyboard are
                // doing HERE, and neither is true of a window you switched away
                // from.
                MainActor.assumeIsolated {
                    self?.setHovered(agentId: nil)
                    self?.setKeyboardFocus(agentId: nil)
                }
            })
        }
    }

    /// The first visible agent not being changed by an incremental apply. The
    /// anchor is stored in viewport coordinates, not as a document-space Y: AppKit
    /// may already move the clip origin while it remeasures the table.
    private func visibleScrollAnchor(excluding excluded: Set<UUID>)
        -> (id: UUID, viewportMinY: CGFloat)?
    {
        let visibleRect = scrollView.contentView.convert(
            scrollView.contentView.bounds, to: tableView)
        var fallback: (id: UUID, viewportMinY: CGFloat)?
        for tableRow in items.indices {
            guard let id = item(at: tableRow)?.agentRow?.id else { continue }
            let frame = tableView.rect(ofRow: tableRow)
            guard frame.intersects(visibleRect) else { continue }
            let viewportMinY = frame.minY - visibleRect.minY
            if fallback == nil { fallback = (id, viewportMinY) }
            if !excluded.contains(id) { return (id, viewportMinY) }
        }
        return fallback
    }

    /// Put the unaffected anchor back at its pre-update visual position. This is
    /// deliberately a content adjustment rather than a row-index adjustment:
    /// activity never reorders the list, but a variable-height row can move every
    /// later document rect. The target is derived from the CURRENT document rect
    /// and the saved viewport position, so an origin AppKit already constrained is
    /// not given the same delta a second time (notably when a row shrinks at bottom).
    private func restoreScrollAnchor(_ anchor: (id: UUID, viewportMinY: CGFloat)?) {
        guard let anchor, let tableRow = tableRow(forAgentId: anchor.id) else { return }
        let currentY = tableView.rect(ofRow: tableRow).minY
        let visibleRect = scrollView.contentView.convert(
            scrollView.contentView.bounds, to: tableView)
        let desiredVisibleMinY = currentY - anchor.viewportMinY
        let currentOrigin = scrollView.contentView.bounds.origin
        let delta = desiredVisibleMinY - visibleRect.minY
        // Use the current origin plus the difference between the desired and
        // current viewport positions. If AppKit already constrained the origin to
        // the bottom during re-layout, `delta` is zero and nothing is double-applied.
        guard abs(delta) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: currentOrigin.x, y: currentOrigin.y + delta))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Which agent is under a point in window coordinates, or nil — off the end
    /// of the list, on the shelf heading or the paging footer (neither is an
    /// agent), or outside the list's own viewport.
    private func agentId(atWindowPoint point: NSPoint) -> UUID? {
        let local = tableView.convert(point, from: nil)
        let viewport = scrollView.contentView.convert(scrollView.contentView.bounds, to: tableView)
        guard viewport.contains(local) else { return nil }
        let row = tableView.row(at: local)
        guard row >= 0 else { return nil }
        return item(at: row)?.agentRow?.id
    }

    /// Re-derive hover from where the pointer actually is. Called after every
    /// re-render and on every scroll, so hover is a function of the pointer and
    /// the current list rather than a memory of an older one.
    private func refreshHoverFromPointer() {
        guard let window, window.isKeyWindow else {
            setHovered(agentId: nil)
            return
        }
        setHovered(agentId: agentId(atWindowPoint: window.mouseLocationOutsideOfEventStream))
    }

    private func setHovered(agentId: UUID?) {
        guard agentId != hoveredAgentId else { return }
        let previous = hoveredAgentId
        hoveredAgentId = agentId
        redraw(tableRows: [tableRow(forAgentId: previous), tableRow(forAgentId: agentId)]
            .compactMap { $0 })
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.4-focus-ring-and-floors.md
    /// Move the ring, and answer which table rows have to be repainted for it.
    ///
    /// `redrawing: false` exists for one caller and one measured reason: inside
    /// `tableViewSelectionDidChange`, AppKit is still mid-selection-update, and a
    /// `reloadData(forRowIndexes:)` delivered there takes the selection back out
    /// from under it — the cell is then rebuilt with `isInteracting` false and the
    /// row it just selected recedes (`--agent-inbox-check`: `selecting a row must
    /// clear its recession — text alpha 0.88, wanted 1.0`). So that path collects
    /// the rows and makes ONE redraw call after the notification's own work.
    @discardableResult
    private func setKeyboardFocus(agentId: UUID?, redrawing: Bool = true) -> [Int] {
        guard agentId != keyboardFocusIntent else { return [] }
        // What was PAINTED before and after — the resolved value, not the intent,
        // so a row whose ring was already suppressed is not repainted for nothing.
        let previous = keyboardFocusAgentId
        keyboardFocusIntent = agentId
        let touched = [tableRow(forAgentId: previous), tableRow(forAgentId: keyboardFocusAgentId)]
            .compactMap { $0 }
        if redrawing { redraw(tableRows: touched) }
        return touched
    }

    /// Arm or disarm the focus ring from the event that moved the selection.
    ///
    /// The EVENT is what tells the two inputs apart — a `.keyDown` reached the
    /// table's own `keyDown:`/`moveUp:`/`moveDown:` and a mouse click reached its
    /// `mouseDown:`. A programmatic selection (`selectRowForQA`, the ⌘-digit jump's
    /// landing, the post-action advance) carries no event of its own and therefore
    /// changes nothing here, except that a ring can never survive on a row that is
    /// no longer selected.
    private func updateKeyboardFocusForSelection() -> [Int] {
        var touched: [Int] = []
        switch NSApp.currentEvent?.type {
        case .keyDown:
            touched += setKeyboardFocus(
                agentId: agentIdForTableRow(tableView.selectedRow), redrawing: false)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            touched += setKeyboardFocus(agentId: nil, redrawing: false)
        default:
            break
        }
        // The rows that LOST the ring because the selection moved off them are
        // repainted by the caller's own symmetric-difference redraw; the ring
        // itself is already gone by derivation (see `keyboardFocusAgentId`).
        return touched
    }

    /// The table row an agent occupies, or nil for an agent that is not on
    /// screen. Nil-in, nil-out, so a caller can hand it a `nil` id.
    private func tableRow(forAgentId id: UUID?) -> Int? {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return tableRow(forRowIndex: index)
    }

    /// The agent on a table row, or nil for a heading, a footer, or -1.
    private func agentIdForTableRow(_ tableRow: Int) -> UUID? {
        guard tableRow >= 0 else { return nil }
        return item(at: tableRow)?.agentRow?.id
    }

    // MARK: - QA

    /// Pin the list's scroller style for a measurement probe.
    ///
    /// A legacy scroller reserves a permanent lane and narrows the content width every
    /// measurement is taken against, so a machine whose "Show scroll bars" preference
    /// is Always measures a different sidebar than one set to When scrolling. The probe
    /// pins it; PRODUCTION MUST NOT. An earlier attempt set `.overlay` on the shipped
    /// scroll view for this reason, which silently overrode the user's own preference
    /// to make a check deterministic — the determinism was real, the place was wrong.
    func pinScrollerStyleForQA() {
        scrollView.scrollerStyle = .overlay
    }


    /// How many AGENT rows the table is drawing. Measured off the table (P4.7 and
    /// P4.8 each add a row to it that is not an agent) rather than reported from
    /// `rows`, so it still witnesses that the model reached the screen.
    var rowCountForQA: Int {
        tableView.numberOfRows - items.filter { $0.agentRow == nil }.count
    }

    /// Materialized agent cells found by walking the live table subtree. This is
    /// intentionally not `cellsByRow`: a stale registry can say a row exists after
    /// AppKit has removed it, while a probe must fail on what is actually painted.
    var qaMaterializedRowCells: [AgentInboxRowCell] {
        var cells: [AgentInboxRowCell] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ view: NSView) {
            if let cell = view as? AgentInboxRowCell,
               seen.insert(ObjectIdentifier(cell)).inserted {
                cells.append(cell)
            }
            view.subviews.forEach(visit)
        }
        visit(tableView)
        return cells
    }

    var qaMaterializedRowCellCount: Int { qaMaterializedRowCells.count }

    /// Per-cell geometry and paint, in live-tree order. Every entry comes from a
    /// materialized row cell; no row model or expected token is substituted here.
    var qaRowGeometriesForQA: [AgentInboxRowGeometryForQA] {
        qaMaterializedRowCells.map(\.qaGeometry)
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
    var elapsedLabelsForQA: [String] { cells().map(\.qaElapsed) }
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
    var scopeTitlesForQA: [String] { scopeEntries.map(\.title) }
    var selectedScopeTitleForQA: String { scope.title }
    var searchQueryForQA: String { searchQuery }
    var searchResultCountForQA: Int { rows.count }
    var scopeControlWidthForQA: CGFloat { scopeButton.bounds.width }
    var scopeButtonForQA: ChoiceButton { scopeButton }
    var searchFieldViewForQA: NSTextField { searchField }
    var searchFieldFrameForQA: NSRect { searchField.frame }
    var scopePopoverItemsForQA: [ChoiceItem] { scopeButton.qaPresentedItems }
    var scopePopoverWidthForQA: CGFloat? { scopeButton.qaPopoverWidth }
    var isScopePopoverPresentedForQA: Bool { scopeButton.qaIsPopoverPresented }
    func dismissScopePopoverForQA() { scopeButton.dismissPopoverForQA() }
    @discardableResult
    func pickPresentedScopeItemForQA(id: String) -> Bool {
        scopeButton.choosePresentedItemForQA(id: id)
    }

    /// Drive the live field/delegate path in deterministic probes.
    func setSearchForQA(_ text: String) {
        searchField.stringValue = text
        controlTextDidChange(Notification(name: NSSearchField.textDidChangeNotification, object: searchField))
    }
    var selectedRowCountForQA: Int { tableView.selectedRowIndexes.count }

    /// Pick a scope the way the user does — through the popup's own action, so the
    /// check exercises the target/action wiring and not just `setScope`.
    @discardableResult
    func pickScopeForQA(_ scope: InboxScope) -> Bool {
        guard scopeEntries.contains(scope) else { return false }
        return scopeButton.chooseForQA(id: scope.storageValue)
    }
    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// The management block as RENDERED: the titles in the menu below the separator,
    /// in menu order, and the enablement AppKit would show — read after
    /// `NSMenu.update()`, because a check that only reads back the `isEnabled` this
    /// file set never sees the pass that used to re-enable a disabled item.
    var workspaceManagementTitlesForQA: [String] {
        WorkspaceManagementAction.allCases.map(\.title)
    }

    func isWorkspaceManagementEnabledForQA(_ action: WorkspaceManagementAction) -> Bool {
        managementItems[action]?.enabled ?? false
    }

    /// Whether the separator really sits between the scopes and the verbs — the
    /// packet's "separated section", asserted on the menu rather than by eye.
    var isWorkspaceManagementSeparatedForQA: Bool {
        scopeButton.items.contains(where: { $0.id == "management-separator" && !$0.enabled })
    }

    /// Pick a workspace verb through the same ChoiceButton selection path as production.
    @discardableResult
    func pickWorkspaceManagementForQA(_ action: WorkspaceManagementAction) -> Bool {
        guard isWorkspaceManagementEnabledForQA(action) else { return false }
        return scopeButton.chooseForQA(id: "management:\(action.title)")
    }
    /// P3.7, read off the RENDERED table rather than recomputed: the variant of
    /// the cell class AppKit actually built, the height it actually laid the row
    /// out at, and the parked row's glyph with the alpha it is painted at.
    var rowVariantsForQA: [RowVariant] { cells().compactMap(\.qaVariant) }
    /// The height each row was actually LAID OUT at, less the intercell spacing
    /// `NSTableView.rect(ofRow:)` folds into it — so this is the number
    /// `height(for:)` returned, measured off the table rather than re-derived from
    /// it (which would witness nothing).
    var rowHeightsForQA: [Double] {
        (0..<tableView.numberOfRows)
            .filter { rowIndex(forTableRow: $0) != nil }
            .map { Double(tableView.rect(ofRow: $0).height - tableView.intercellSpacing.height) }
    }

    /// The actual width AppKit handed the row column, not the requested host
    /// frame. Fractional divider checks use this value to prove the live resize
    /// crossed a fit tier by a real, bounded amount.
    var columnWidthForQA: Double { Double(column.width) }

    /// The fractional content-height witness keeps its live child-host resize
    /// on the production `layout()` invalidation path. AppKit rounds the clip
    /// viewport at 1x before that path can see the sub-point width, so the seam
    /// supplies the host's measured width without reimplementing row invalidation.
    func setViewportWidthForQA(_ width: Double) {
        qaViewportWidthOverride = CGFloat(width)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The live height for one agent, read from the table row rather than from
    /// `AgentInboxView.height(for:)`. Incremental-height probes use this before
    /// and after content arrives so a stale height cache cannot satisfy them.
    func rowHeightForQA(id: UUID) -> Double? {
        guard let tableRow = tableRow(forAgentId: id) else { return nil }
        return Double(tableView.rect(ofRow: tableRow).height - tableView.intercellSpacing.height)
    }

    /// The agent ids whose live table rect intersects the clip viewport. This is
    /// intentionally a visibility seam rather than a raw clip offset: an
    /// incremental height change must preserve the content anchor the person was
    /// looking at, not merely leave the scroll view's numeric origin untouched.
    var visibleAgentIdsForQA: [UUID] {
        let visibleRect = scrollView.contentView.convert(
            scrollView.contentView.bounds, to: tableView)
        return items.indices
            .filter { tableView.rect(ofRow: $0).intersects(visibleRect) }
            .compactMap { item(at: $0)?.agentRow?.id }
    }

    /// One row's live position in the clip view's coordinates. Comparing this
    /// before and after an update tests the visible anchor even when AppKit
    /// legitimately changes the document-space clip origin to preserve it.
    func rowFrameInViewportForQA(id: UUID) -> NSRect? {
        guard let tableRow = tableRow(forAgentId: id) else { return nil }
        let frame = tableView.rect(ofRow: tableRow)
        let origin = scrollView.contentView.bounds.origin
        return frame.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// The heading's laid-out height, on the same terms — P4.7's own row.
    var shelfHeaderHeightForQA: Double? {
        guard let tableRow = shelfHeaderTableRow else { return nil }
        return Double(tableView.rect(ofRow: tableRow).height - tableView.intercellSpacing.height)
    }
    // Ticket: docs/38-tickets/90-agent-ux/P4.12-crossfade-in-place.md
    /// EVERY row view this list currently has in the table — the cells it is
    /// drawing plus any outgoing cell still fading — by its `id:variant` identifier.
    ///
    /// Read off the view hierarchy and not off `cellsByRow`, deliberately: an
    /// orphaned card is precisely a view the bookkeeping has forgotten and the
    /// window is still showing, so a registry that could only see what it remembers
    /// could not witness one.
    var rowViewIdentitiesForQA: [String] {
        tableView.subviews
            .flatMap { [$0] + $0.subviews }
            .compactMap { $0.identifier?.rawValue }
            .filter { $0.hasPrefix("agent-inbox-row-") }
    }
    /// How many rows are mid-crossfade right now.
    var crossfadingRowCountForQA: Int { crossfadingCells.count }
    /// The strength the INCOMING view of `id` is painted at — 0 while it is fading
    /// up, 1 once it has arrived, and 1 immediately when the crossfade is off.
    func rowViewAlphaForQA(id: UUID) -> Double? {
        tableRowByAgentId[id]
            .flatMap { tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) }
            .map { Double($0.alphaValue) }
    }
    /// The frame the outgoing view of `id` is held at — the packet's "in place",
    /// which is only checkable against the rect the row occupied BEFORE the move.
    func crossfadeGhostFrameForQA(id: UUID) -> NSRect? { crossfadingCells[id]?.frame }
    /// Where agent `id` is drawn in the table, and the rect it occupies — the
    /// after-side of the same comparison.
    func tableRowFrameForQA(id: UUID) -> NSRect? {
        tableRowByAgentId[id].map { tableView.rect(ofRow: $0) }
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
    var jumpHintHitTestPassesThroughForQA: Bool {
        cells().allSatisfy(\.qaJumpHintHitTestPassesThrough)
    }
    /// Where each row's status label actually sits, in its own cell's coordinates.
    /// The T3 regression this ticket names — holding ⌘ blanked out "Working" — is a
    /// LAYOUT fact, so it is caught by comparing this before and after the pills
    /// appear and by nothing else.
    var statusFramesForQA: [NSRect] { cells().map(\.qaStatusFrame) }
    /// Every non-hint descendant frame in each rendered agent cell, in stable
    /// tree order. The overlay itself may materialize a pill; no subject, status,
    /// metadata, control, container, or other existing element may move for it.
    var allRowElementFramesForQA: [[NSRect]] {
        cells().map { cell in
            var frames: [NSRect] = []
            func visit(_ view: NSView) {
                guard !(view is InboxJumpHintView) else { return }
                frames.append(view.convert(view.bounds, to: cell))
                view.subviews.forEach(visit)
            }
            visit(cell)
            return frames
        }
    }
    /// Make the list itself first responder, which is the scope the jump is confined
    /// to — so a check can put the app in the state a click on a row leaves it in.
    @discardableResult
    func focusListForQA() -> Bool {
        window?.makeFirstResponder(tableView) ?? false
    }
    @discardableResult
    func sendTableKeyForQA(
        keyCode: UInt16,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let table = tableView as? AgentInboxTableView else { return false }
        let defaultCharacters: String
        switch keyCode {
        case 126: defaultCharacters = "\u{F700}" // Up
        case 125: defaultCharacters = "\u{F701}" // Down
        case 115: defaultCharacters = "\u{F729}" // Home
        case 119: defaultCharacters = "\u{F72B}" // End
        case 116: defaultCharacters = "\u{F72C}" // Page Up
        case 121: defaultCharacters = "\u{F72D}" // Page Down
        case 36: defaultCharacters = "\r"
        case 49: defaultCharacters = " "
        default: defaultCharacters = ""
        }
        let text = characters ?? defaultCharacters
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: tableView.window?.windowNumber ?? 0, context: nil,
            characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: keyCode
        ) else { return false }
        table.keyDown(with: event)
        return true
    }
    var selectedRowIsVisibleForQA: Bool {
        let row = tableView.selectedRow
        return row >= 0 && tableView.visibleRect.intersects(tableView.rect(ofRow: row))
    }
    var selectedRowAccessibilityLabelForQA: String? {
        let row = tableView.selectedRow
        guard row >= 0 else { return nil }
        return cellsByRow[row]?.accessibilityLabel()
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
    // Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
    /// The toast as RENDERED — empty when it is down.
    var undoToastTextForQA: String { undoToast.qaText }
    /// Where it is, so a check can assert it clears the bulk bar rather than assuming
    /// the constraint does.
    var undoToastFrameForQA: NSRect { undoToast.frame }
    var bulkBarFrameForQA: NSRect { bulkBar.frame }
    /// What an Undo would put back. The captured values themselves, so a check can
    /// compare them against what was read before the action rather than against what
    /// the host happened to be handed.
    var pendingUndoForQA: [UUID: InboxLifecycleSnapshot]? { pendingUndo }
    /// Press Undo the way the user does, through the toast's own button.
    @discardableResult
    func clickUndoForQA() -> Bool { undoToast.clickUndoForQA() }
    var bulkActionTitlesForQA: [String] { bulkBar.qaActionTitles }
    var bulkSelectionTextForQA: String { bulkBar.qaSelectionText }
    var bulkKeptBranchesTextForQA: String { bulkBar.qaKeptText }
    var bulkCountFrameForQA: NSRect { bulkBar.convert(bulkBar.qaCountFrame, to: self) }
    var bulkActionTriggerFrameForQA: NSRect { bulkBar.convert(bulkBar.qaActionFrame, to: self) }
    var bulkCountDrawsWithoutTruncationForQA: Bool { bulkBar.qaCountDrawsWithoutTruncation }
    var bulkActionTitleDrawsWithoutTruncationForQA: Bool { bulkBar.qaActionTitleDrawsWithoutTruncation }
    var bulkActionTriggerTitleForQA: String { bulkBar.qaActionTriggerTitle }
    var bulkActionTriggerAccessibilityValueForQA: String? { bulkBar.qaActionAccessibilityValue }

    /// Choose a bulk action the way the user does — through the pull-down's own
    /// target/action, so the check exercises the wiring and not just
    /// `performBulkAction`.
    @discardableResult
    func pickBulkActionForQA(_ action: InboxBulkAction) -> Bool {
        bulkBar.pickForQA(action)
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P5.1-custom-row-context-menu.md
    /// The sidebar has no stock row menu: context gestures route to the choice-family
    /// controller and the live panel is a child of the originating window.
    var isRowMenuWiredForQA: Bool {
        tableView.menu == nil && tableView is AgentInboxTableView
    }
    /// Deliver the gesture through AgentInboxTableView's production overrides. The
    /// synthesized event supplies only AppKit's input; hit-testing, selection
    /// retargeting and presentation remain the shipped path.
    private func dispatchContextGestureForQA(clickedRowId: UUID, controlClick: Bool) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == clickedRowId }),
              let tableRow = tableRow(forRowIndex: index),
              let contextTable = tableView as? AgentInboxTableView else { return false }
        let rowRect = tableView.rect(ofRow: tableRow)
        let pointInTable = NSPoint(x: rowRect.midX, y: rowRect.midY)
        let pointInWindow = tableView.convert(pointInTable, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: controlClick ? .leftMouseDown : .rightMouseDown,
            location: pointInWindow,
            modifierFlags: controlClick ? [.control] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: tableView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return false }
        if controlClick {
            contextTable.mouseDown(with: event)
        } else {
            contextTable.rightMouseDown(with: event)
        }
        return activeChoiceListForQA != nil
    }

    @discardableResult
    func openRowMenuForQA(clickedRowId: UUID?) -> Bool {
        guard let clickedRowId else {
            rowChoiceController.dismiss(); qaChoiceListForQA = nil; rowChoiceTargetIds.removeAll()
            return true
        }
        return dispatchContextGestureForQA(clickedRowId: clickedRowId, controlClick: false)
    }

    @discardableResult
    func controlClickRowMenuForQA(clickedRowId: UUID) -> Bool {
        dispatchContextGestureForQA(clickedRowId: clickedRowId, controlClick: true)
    }

    private var activeChoiceListForQA: ChoiceListView? { rowChoiceController.listView ?? qaChoiceListForQA }
    var rowMenuTitlesForQA: [String] { activeChoiceListForQA?.qaItems.map(\.title) ?? [] }
    var rowMenuEnabledForQA: [Bool] { activeChoiceListForQA?.qaItems.map(\.enabled) ?? [] }
    var rowMenuTooltipsForQA: [String] { activeChoiceListForQA?.qaItems.map { $0.detail ?? "" } ?? [] }
    var rowMenuFocusedTitleForQA: String? {
        guard let list = activeChoiceListForQA, let id = list.focusedID else { return nil }
        return list.qaItems.first(where: { $0.id == id })?.title
    }
    var rowMenuPresentationAnnouncementForQA: String? {
        rowChoiceController.lastAccessibilityAnnouncementForQA
    }
    var rowMenuFocusAnnouncementForQA: String? {
        activeChoiceListForQA?.lastAccessibilityAnnouncementForQA
    }
    var isTableFirstResponderForQA: Bool { tableView.window?.firstResponder === tableView }

    @discardableResult
    func performRowMenuCommandForQA(_ command: ChoiceListCommand) -> Bool {
        guard let list = activeChoiceListForQA else { return false }
        list.perform(command)
        return true
    }

    @discardableResult
    func pickRowMenuItemForQA(_ action: InboxRowAction) -> Bool {
        guard let list = activeChoiceListForQA,
              list.qaItems.contains(where: { $0.id == action.rawValue && $0.enabled }) else { return false }
        list.choose(id: action.rawValue)
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
    /// Double-click a row ON ITS NAME (`onTitle: true`) or on the row body
    /// (`onTitle: false`). Both use the production hit test; only the NSEvent is
    /// stood in for. `modifiers` is explicit so a selection-modified double-click
    /// cannot accidentally pass through this QA seam.
    @discardableResult
    func doubleClickRowForQA(
        id: UUID,
        onTitle: Bool,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
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
        return doubleClick(rowAt: clicked, pointInCell: point, modifiers: modifiers)
    }

    /// The live nested-control frame used by the event witness, or nil when this
    /// row has no nested control. Keeping this separate makes the negative test
    /// fail closed instead of passing because there was no control to hit.
    func renameNestedControlFrameForQA(id: UUID) -> NSRect? {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index),
              let clicked = rowIndex(forTableRow: tableRow),
              let cell = cellForRow(clicked) else { return nil }
        return cell.renameNestedControlFrameForQA
    }

    /// Send the double-click through a real nested control's live frame. A row
    /// without a control has no fabricated point and therefore returns false.
    @discardableResult
    func doubleClickNestedControlForQA(id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index),
              let clicked = rowIndex(forTableRow: tableRow),
              let cell = cellForRow(clicked),
              let controlFrame = cell.renameNestedControlFrameForQA else {
            return false
        }
        return doubleClick(
            rowAt: clicked,
            pointInCell: NSPoint(x: controlFrame.midX, y: controlFrame.midY))
    }

    /// Exercise the table's ordinary action after a successful double-action.
    /// This stands in for AppKit's trailing click while keeping the production
    /// `activateRow` path and its host callback intact.
    @discardableResult
    func trailingClickForQA(id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index) else { return false }
        return activateRow(atTableRow: tableRow, event: nil)
    }

    var renamingRowIdForQA: UUID? { renamingRowId }
    var isRenameEditingForQA: Bool { renameField != nil && renamingRowId != nil }
    var renameCommitCountForQA: Int { qaRenameCommitCount }
    var renameCancelCountForQA: Int { qaRenameCancelCount }
    /// The field really does report to this view. Asserted separately because the two
    /// key helpers below CALL the delegate methods — AppKit's own delivery needs a live
    /// field editor in a key window, which a headless check has no way to drive — so
    /// without this a rename with no delegate at all would still pass them.
    /// (Cross-review found exactly that hole.)
    var isRenameDelegateWiredForQA: Bool { renameField?.delegate === self }
    var renameFieldTextForQA: String? { renameField?.stringValue }
    /// The inline editor's frame in the inbox's coordinates. P2.3's resize
    /// witness compares it with the live title frame after the table rebuilds;
    /// a stale overlay is otherwise invisible to row geometry checks.
    var renameFieldFrameForQA: NSRect? { renameField?.frame }
    /// The current title frame in the inbox's coordinates, after any width-driven
    /// tier and row-height transition. This is deliberately read from the live
    /// cell rather than reconstructed from the row model.
    func titleFrameForQA(id: UUID) -> NSRect? {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let tableRow = tableRow(forRowIndex: index),
              let cell = cellsByRow[tableRow] else { return nil }
        return cell.convert(cell.titleFrame, to: self)
    }
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

    /// Deliver the blur notification from the field that Return already ended.
    /// The notification is real, but the active-editor identity and did-commit
    /// guard must make it a no-op.
    @discardableResult
    func blurAfterReturnForQA() -> Bool {
        guard let field = lastEndedRenameFieldForQA else { return false }
        controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification, object: field))
        return true
    }

    @discardableResult
    func hoverRowForQA(id: UUID?) -> Bool {
        guard let id else { setHovered(agentId: nil); return true }
        // Still resolved through the row maps rather than stored blind: a check
        // that "hovers" an agent which is not on screen must fail, not silently
        // arm a fill nobody can see.
        guard rows.contains(where: { $0.id == id }), tableRow(forAgentId: id) != nil else { return false }
        setHovered(agentId: id)
        return true
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// The agent the pointer is on, as the view believes it — so a check can
    /// assert hover CLEARED rather than infer it from a fill.
    var hoveredAgentIdForQA: UUID? { hoveredAgentId }
    /// The route-active agent under the name the ladder uses. `openAgentId` is
    /// the one owner of the fact (see its note); this reads it back so a check
    /// can name what it is asserting.
    var routeActiveAgentIdForQA: UUID? { openAgentId }
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.4-focus-ring-and-floors.md
    var keyboardFocusAgentIdForQA: UUID? { keyboardFocusAgentId }

    /// Put the KEYBOARD's cursor on a row without moving the selection — the
    /// state `⇧↓` leaves behind: a range selected, and one row of it the one
    /// Return will act on.
    ///
    /// THE RING ONLY, deliberately. Production arms it from the real event
    /// (`updateKeyboardFocusForSelection` reads `NSApp.currentEvent`), and a
    /// headless probe cannot post a `.keyDown` that `NSTableView` will route
    /// through its own `moveUp:`/`moveDown:` — so this is the seam, and what it
    /// exercises is the fact under test: the ring is a treatment of its own, it
    /// does not move or borrow the selection's fill, and a selection change that
    /// drops this row takes the ring with it.
    @discardableResult
    func focusRowByKeyboardForQA(id: UUID?) -> Bool {
        guard let id else { setKeyboardFocus(agentId: nil); return true }
        guard tableRow(forAgentId: id) != nil else { return false }
        setKeyboardFocus(agentId: id)
        return true
    }

    /// Drop both transient treatments the way losing key does, so the "nothing is
    /// left lit behind a window you switched away from" rule is assertable in a
    /// headless probe (an offscreen `NSWindow` never posts `didResignKey`).
    func resignKeyForQA() {
        setHovered(agentId: nil)
        setKeyboardFocus(agentId: nil)
    }

    /// Scroll the list by `points` and let hover re-derive, so the scroll half of
    /// "hover survives scrolling" is exercised through the real notification path.
    func scrollForQA(byPoints points: Double) {
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + points))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        layoutForQA()
    }

    /// The live clip offset, read back from the scroll view rather than inferred
    /// from row indexes. P2.3 uses it to prove an incremental height change does
    /// not reset the user's scroll position.
    var contentOffsetYForQA: Double { Double(scrollView.contentView.bounds.origin.y) }

    /// Scroll to the list's document bottom through the real scroll view path.
    /// The bottom-shrink witness needs AppKit's constrained origin, not an
    /// arbitrary clip offset that happens to be large.
    func scrollToBottomForQA() {
        let clip = scrollView.contentView
        let documentBottom = tableView.numberOfRows > 0
            ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
            : 0
        let maxY = max(0, documentBottom - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: maxY))
        scrollView.reflectScrolledClipView(clip)
        layoutForQA()
    }

    /// Whether the list's own last row bottom is aligned with the clip viewport.
    /// The bottom-shrink witness uses the actual laid-out content edge rather than
    /// a stale document-view frame that may retain old trailing slack for one pass.
    var isAtBottomForQA: Bool {
        let visibleRect = scrollView.contentView.convert(
            scrollView.contentView.bounds, to: tableView)
        let documentBottom = tableView.numberOfRows > 0
            ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
            : 0
        return abs(visibleRect.maxY - documentBottom) <= 0.5
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// Rebuild every row cell from the inputs as they stand right now.
    ///
    /// MEASURED NEED, not belt-and-braces. `redraw(tableRows:)` asks AppKit for an
    /// incremental reload, and an offscreen probe window defers that reload
    /// indefinitely — the cells the check then reads are the ones built before the
    /// input changed, so a genuinely selected pair reads back as two resting rows
    /// (`sidebar-ux-check.ladder…: a multi-selected pair resolved
    /// sidebarResting/sidebarResting` on a table whose `selectedRowIndexes` really
    /// did hold two). `reloadData(forRowIndexes:)` over every row rather than
    /// `reloadData()`, because the second one EMPTIES the selection and the
    /// selection is half of what is under test.
    func rebuildRowsForQA() {
        guard tableView.numberOfRows > 0 else { return }
        cellsByRow.removeAll()
        tableView.reloadData(
            forRowIndexes: IndexSet(0..<tableView.numberOfRows),
            columnIndexes: IndexSet(integer: 0))
        layoutForQA()
    }

    /// Force the table to realise a cell for every row, so the accessors above
    /// describe the whole list and not just the part AppKit felt like laying out.
    /// The second list-owned layout pass is intentional: offscreen probes may create
    /// cells only after the first `view(atColumn:row:)` request, and their frames are
    /// not painted until the table lays those new hosts out.
    func layoutForQA() {
        layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        for row in 0..<tableView.numberOfRows where cellsByRow[row] == nil {
            _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        tableView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
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
    /// Supply the table column before content is applied. AppKit can build a
    /// cell with a zero frame, but tiered visibility and row height must agree
    /// from the first layout pass.
    func setLayoutWidth(_ width: Double)

    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure, rollup: ChildRollup?, isSelected: Bool,
               isInteracting: Bool, now: Date)

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    /// The pointer's and the keyboard's facts about this row, set through their
    /// OWN call rather than as three more parameters on `apply`.
    ///
    /// The split is the same one `showJumpHint` already makes and for the same
    /// reason: `apply` paints what the agent IS — its words, its recession, its
    /// indent — and the cell re-runs it from its stored `shown` tuple on every
    /// appearance flip. Where the pointer is and which row Return will act on are
    /// facts about the INPUT, they live on the card so they survive that re-run,
    /// and threading them back through `apply` would make an appearance flip a
    /// place hover state could be dropped.
    func applyInteraction(_ interaction: RowInteraction)

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

    var qaAgentID: UUID? { get }
    var qaVariant: RowVariant? { get }
    var qaGeometry: AgentInboxRowGeometryForQA { get }
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
    var qaJumpHintHitTestPassesThrough: Bool { get }
    /// The frame of whatever this variant paints the state with — the word on a
    /// card, the glyph on a parked row — in the cell's own coordinates.
    var qaStatusFrame: NSRect { get }
    // Ticket: docs/38-tickets/90-agent-ux/P3.13-inline-rename.md
    /// The frame of the row's NAME in the cell's own coordinates. A production
    /// accessor, not a `qa` one: it is where the rename field is placed.
    var titleFrame: NSRect { get }
    /// A double-click may begin editing only in the row body. Nested controls
    /// (currently the disclosure button) remain owned by their own target/action.
    func acceptsRenameDoubleClick(at point: NSPoint) -> Bool
    /// A live nested-control frame for the event witness, or nil for a row with
    /// no nested control. The check uses the same point the production hit test
    /// receives rather than asserting a private button exists.
    var renameNestedControlFrameForQA: NSRect? { get }
    @discardableResult
    func clickDisclosureForQA() -> Bool
}

// Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
/// Whether a row draws a disclosure triangle, and which way it points. `none` is a
/// row with no children in this list — most rows — and it draws nothing at all
/// rather than a disabled control, which would put a dead glyph on every line of a
/// list that has no orchestrator in it.
// Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
// Ticket: docs/38-tickets/94-sidebar-native-ux/P1.4-focus-ring-and-floors.md
/// What the pointer and the keyboard are doing to one row, as one value.
///
/// Selection is deliberately NOT in here: it is an `NSTableView` fact the table
/// already owns and `apply` already carries. These three are the ones the list has
/// to track itself — where the pointer is, which agent's tile is open, and which
/// row Return will act on.
struct RowInteraction: Equatable {
    var isHovered = false
    var isRouteActive = false
    var hasKeyboardFocus = false

    static let none = RowInteraction()
}

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
        // P1.3's shared hairline (was a 1pt literal).
        layer?.borderWidth = LineWidth.hairline
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        // P1.3: the ROLE, not the raw token — an overlay card that holds
        // controls is a control boundary, and the role is what carries the 3.0
        // line floor into the contrast gate. Same resolved value as the
        // `LineToken.border` this line used to name, so no pixel moves.
        layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: theme)
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

    // Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
    /// What the toast says this action DID, or nil for an action no undo covers.
    /// `InboxRowAction.undoVerb` records why the list is what it is.
    var undoVerb: String? {
        switch self {
        case .settle: return InboxUndoToast.settledVerb
        case .snooze: return InboxUndoToast.snoozedVerb
        case .archive: return InboxUndoToast.archivedVerb
        case .delete: return InboxUndoToast.deletedVerb
        case .markUnread: return nil
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
/// P5.1 filters unavailable or unwired actions from the custom list rather than
/// presenting a disabled stock-menu row. Bulk surfaces retain their own hiding rules.
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
    case generateName
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
        case .generateName: return "Generate Name"
        case .stopAgent: return "Stop Agent"
        case .archive: return "Archive"
        case .delete: return "Delete"
        }
    }

    /// `Snooze` alone: it opens the preset list (P4.5) rather than acting, which is the
    /// same reason `InboxBulkAction.snooze` carries the arrow.
    var opensSubmenu: Bool { self == .snooze }

    // Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
    /// What the toast says this action DID — past tense, because it has already
    /// happened by the time the words are on screen — or nil for an action the toast
    /// stays down for.
    ///
    /// THE SIX THAT MOVE LIFECYCLE FACTS, which is not the same set as P4.10's four:
    /// the two un-doings are here too, because `Un-settle` and `Wake` change the same
    /// four fields and a mis-aimed one is exactly as annoying to find. `markUnread` is
    /// read-state (P3.3, not a lifecycle fact), `rename` is the name on the record,
    /// `stopAgent` ends a turn and `openInTile` is a navigation — none of the four
    /// fields moves for any of them, so a toast would be a notification, which the
    /// packet's watch-out forbids.
    ///
    /// A verb here is PERMISSION TO OFFER, not a promise: `offerUndo` still measures
    /// that the action changed something restorable, which is what keeps Archive and
    /// Delete (whose records are gone) from raising one.
    var undoVerb: String? {
        switch self {
        case .settle: return InboxUndoToast.settledVerb
        case .unsettle: return InboxUndoToast.unsettledVerb
        case .snooze: return InboxUndoToast.snoozedVerb
        case .wake: return InboxUndoToast.wokenVerb
        case .archive: return InboxUndoToast.archivedVerb
        case .delete: return InboxUndoToast.deletedVerb
        case .openInTile, .markUnread, .rename, .generateName, .stopAgent: return nil
        }
    }

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
        case .generateName: return !InboxBulkAction.isArchived(row)
        case .stopAgent: return InboxRowAction.hasTurnInFlight(row)
        case .archive: return InboxBulkAction.archive.isAvailable(for: row)
        case .delete: return InboxBulkAction.delete.isAvailable(for: row)
        }
    }

    /// The items the menu SHOWS for these agents, in menu order. Empty for no agents,
    /// which is what a right-click on the background gets.
    static func menuItems(
        for rows: [AgentInboxRow],
        includeGeneratedName: Bool = true
    ) -> [InboxRowAction] {
        guard !rows.isEmpty else { return [] }
        return allCases.filter { action in
            guard action != .generateName || includeGeneratedName else { return false }
            return action.belongsInMenu(for: rows)
        }
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
        case .openInTile, .snooze, .wake, .markUnread, .rename, .generateName, .stopAgent, .archive,
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
        case .generateName: return "is archived."
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
    static let menuTitle = "Actions"
    private let countLabel = NSTextField(labelWithString: "")
    private let actionButton = ChoiceButton(title: menuTitle)
    private let keptLabel = NSTextField(labelWithString: "")
    private var actions: [InboxBulkAction] = []
    var onAction: ((InboxBulkAction) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = LineWidth.hairline
        layer?.cornerRadius = Radius.card
        isHidden = true
        countLabel.font = .token(.label)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.preferredPopoverWidth = 150
        // An action is a command, not the trigger's selected value. Keeping the
        // neutral title here also keeps it stable while the host owns a modal confirm.
        actionButton.keepsSelectionForItem = { _ in true }
        actionButton.onSelection = { [weak self] item in self?.choose(item) }
        keptLabel.font = .token(.caption)
        keptLabel.lineBreakMode = .byTruncatingMiddle
        keptLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel); addSubview(actionButton); addSubview(keptLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            countLabel.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: Space.m),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right),
            actionButton.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),
            keptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            keptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right),
            keptLabel.topAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: Space.xs),
            keptLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.s),
        ])
        applyTokens()
    }
    required init?(coder: NSCoder) { return nil }

    func show(_ actions: [InboxBulkAction], selectionCount: Int, keptBranches: [String]) {
        self.actions = actions
        actionButton.items = actions.map {
            ChoiceItem(id: $0.rawValue, title: $0.title,
                       destructive: $0 == .delete || $0 == .archive)
        }
        // Installing items can select the first enabled item. Reset the presentation
        // afterward so the trigger title remains the stable "Actions" label.
        actionButton.setPresentationTitle(Self.menuTitle)
        actionButton.isHidden = actions.isEmpty
        countLabel.stringValue = Self.selectionText(count: selectionCount)
        keptLabel.stringValue = Self.keptText(branches: keptBranches)
        keptLabel.isHidden = keptLabel.stringValue.isEmpty
        isHidden = false
        applyTokens()
    }

    func hide() {
        isHidden = true; actions = []
        actionButton.setPresentationTitle(Self.menuTitle)
    }

    private func choose(_ item: ChoiceItem) {
        guard let action = InboxBulkAction(rawValue: item.id), actions.contains(action) else { return }
        // Destructive confirmation belongs to the host callback. Keeping one owner
        // avoids a fake intermediate confirmation surface and leaves this trigger
        // stable if the host cancels or refreshes the rows.
        onAction?(action)
        actionButton.setPresentationTitle(Self.menuTitle)
    }

    static func selectionText(count: Int) -> String { "\(count) selected" }
    static func keptText(branches: [String]) -> String {
        guard !branches.isEmpty else { return "" }
        return "Unmerged work kept: " + branches.map { "\(BranchChipNSView.branchGlyph) \($0)" }.joined(separator: ", ")
    }
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: theme)
        countLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        keptLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    var qaActionTitles: [String] {
        guard !isHidden, !actionButton.isHidden else { return [] }
        return actionButton.items.map(\.title)
    }
    var qaSelectionText: String { countLabel.stringValue }
    var qaKeptText: String { keptLabel.isHidden ? "" : keptLabel.stringValue }
    var qaCountFrame: NSRect { countLabel.frame }
    var qaActionFrame: NSRect { actionButton.frame }
    var qaCountDrawsWithoutTruncation: Bool {
        let needed = ceil((countLabel.stringValue as NSString).size(
            withAttributes: [.font: countLabel.font ?? NSFont.token(.label)]).width) + 4
        return countLabel.frame.width + 0.5 >= needed
    }
    var qaActionTitleDrawsWithoutTruncation: Bool { actionButton.qaTitleDrawsWithoutTruncation }
    var qaActionTriggerTitle: String { actionButton.qaRenderedTitle }
    var qaActionAccessibilityValue: String? { actionButton.accessibilityValue() as? String }
    @discardableResult
    func pickForQA(_ action: InboxBulkAction) -> Bool {
        guard !isHidden, !actionButton.isHidden, actions.contains(action) else { return false }
        // QA's pick means exactly one user activation. Destructive confirmation is
        // owned by the host callback, not simulated by a second fake press here.
        return actionButton.chooseForQA(id: action.rawValue)
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P4.11-undo-toast.md
/// What just happened, and the way back — `Snoozed until 18:00 · Undo`.
///
/// A CARD LIKE THE BULK BAR, and it floats over the bottom of the list for the same
/// reason: `overlay` fill, `border` outline, `Radius.card`, taking no height off the
/// scroll view. Hidden until an action raises it, so no committed baseline paints it.
///
/// The separator is the packet's own `·`, in the same middle-dot vocabulary the row's
/// metadata line already uses, and Undo is a borderless button with a token-coloured
/// attributed title rather than a bezel — `InboxDisclosureButton` records why (a system
/// bezel draws a colour this app cannot theme, and P1.7's lint plus P1.6's contrast gate
/// hold every painted colour here to a token).
final class InboxUndoToast: NSView, TokenThemed {
    static let settledVerb = "Settled"
    static let unsettledVerb = "Un-settled"
    static let snoozedVerb = "Snoozed"
    static let wokenVerb = "Woken"
    static let archivedVerb = "Archived"
    static let deletedVerb = "Deleted"
    static let undoTitle = "Undo"
    static let separator = "·"

    /// 24-hour, POSIX, in the local zone. NOT `DateFormatter.timeStyle = .short`, which
    /// would render "6:00 PM" on a US locale and "18:00" on a British one — the wording
    /// is asserted by the checks and would then depend on whose machine ran them, which
    /// is the same call `AgentInboxView.clock` records for the relative times. The
    /// packet's own example is 24-hour.
    private static let wakeTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// `Settled`, `Settled 3`, `Snoozed until 18:00`, `Snoozed 3 until 18:00`.
    ///
    /// The count is dropped for one agent — "Settled 1" reads like an inventory — and
    /// the wake time is dropped when the action left none, which is every verb but
    /// snooze and a snooze whose date the host did not write.
    static func message(verb: String, count: Int, snoozedUntil: Date?) -> String {
        var text = count > 1 ? "\(verb) \(count)" : verb
        if let snoozedUntil {
            text += " until \(wakeTimeFormatter.string(from: snoozedUntil))"
        }
        return text
    }

    private let messageLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton(frame: .zero)
    var onUndo: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // P1.3's shared hairline (was a 1pt literal).
        layer?.borderWidth = LineWidth.hairline
        layer?.cornerRadius = Radius.card
        isHidden = true

        messageLabel.font = .token(.label)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        undoButton.isBordered = false
        undoButton.bezelStyle = .inline
        undoButton.setButtonType(.momentaryChange)
        undoButton.font = .token(.label)
        undoButton.target = self
        undoButton.action = #selector(undoPressed)
        undoButton.setAccessibilityRole(.button)
        undoButton.setAccessibilityLabel(InboxUndoToast.undoTitle)
        // The way back must never be the thing a 320pt sidebar truncates away.
        undoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
        undoButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(messageLabel)
        addSubview(undoButton)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Inset.row.left),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.s),

            // The BUTTON owns the vertical and the label centres on it, the call the
            // bulk bar's own layout records: the control is the taller of the two, and
            // centring the taller one on the shorter is what put an `NSPopUpButton`'s
            // bezel a point outside its parent there.
            undoButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: Space.s),
            undoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right),
            undoButton.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
            undoButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Space.xs),
            undoButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Space.xs),
        ])
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    func show(_ message: String) {
        messageLabel.stringValue = message
        isHidden = false
        applyTokens()
    }

    func hide() {
        isHidden = true
        messageLabel.stringValue = ""
    }

    /// `textSecondary` for what happened and `textPrimary` for the way back — NOT an
    /// accent, deliberately. P3.2 holds this list to three colours and all three mean
    /// status; a fourth on a card that floats over the rows would read as a state. So
    /// the emphasis is inverted instead: the report is chrome (the same token the shelf
    /// heading and the paging footer use) and the one thing you can act on is the one
    /// thing at full strength. Both are documented pairs over `overlay`, so P1.6's
    /// contrast gate measures them rather than exempting them.
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        // P1.3: the ROLE, not the raw token — an overlay card that holds
        // controls is a control boundary, and the role is what carries the 3.0
        // line floor into the contrast gate. Same resolved value as the
        // `LineToken.border` this line used to name, so no pixel moves.
        layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: theme)
        messageLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        undoButton.attributedTitle = NSAttributedString(
            string: "\(InboxUndoToast.separator) \(InboxUndoToast.undoTitle)",
            attributes: [
                .font: NSFont.token(.label),
                .foregroundColor: TextToken.textPrimary.color.nsColor(in: self),
            ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    @objc private func undoPressed() { onUndo?() }

    /// What the card is really saying, both halves of it — read off the views rather
    /// than off the string it was handed.
    var qaText: String {
        guard !isHidden else { return "" }
        return "\(messageLabel.stringValue) \(undoButton.attributedTitle.string)"
    }

    /// Press it the way the user does, through the button's own target/action.
    @discardableResult
    func clickUndoForQA() -> Bool {
        guard !isHidden else { return false }
        undoButton.performClick(nil)
        return true
    }
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P1.4-focus-ring-and-floors.md
/// The row's keyboard focus treatment: a hairline `focusRing` ring plus a soft
/// glow of the same colour, hidden unless the row is the one Return will act on.
///
/// A SEPARATE VIEW rather than a border on the card, and that separation is the
/// whole point of the packet pair. P1.1/P1.2 make the row's own perimeter
/// permanently zero and reserve the card's surface for the interaction ladder,
/// which is asserted structurally (`paintedBorderWidth == 0` in every state) —
/// so the one line the row is still allowed to paint has to belong to something
/// else, be TEMPORARY, and be at most `LineWidth.hairline`. All three are true
/// of this view and none of them can be true of the card.
///
/// No animation, deliberately: `Reduce Motion` must suppress any focus
/// animation without removing the cue, and the cheapest way to hold that
/// promise for every reader is to have no animation to suppress. The cue is the
/// ring, which appears and disappears in one frame.
@MainActor
final class InboxRowFocusRingView: NSView, TokenThemed {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        // P1.3's shared hairline, not a literal: the sidebar's one remaining
        // line width is a value `runSidebarSurfaceChecks` pins.
        layer?.borderWidth = LineWidth.hairline
        layer?.shadowOffset = .zero
        layer?.shadowRadius = Space.s
        layer?.shadowOpacity = Float(Opacity.receded)
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    func applyTokens() {
        let theme = effectiveTokenTheme
        let ring = AgentLineRole.focusRing.color.cgColor(for: theme)
        layer?.borderColor = ring
        // The glow is the same colour as the ring, so "soft glow" adds no
        // second value to gate — and it is re-resolved HERE rather than in
        // `init`, or an appearance flip would leave a light-theme glow on a
        // dark row (the P1.9 stale-CGColor bug shape).
        layer?.shadowColor = ring
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P1.1-remove-row-borders.md
// Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
/// The surface one row's words sit on. SURFACE IS RESERVED FOR INTERACTION
/// (`_DESIGN.md`): it paints no perimeter in any state, nothing at all at rest,
/// and exactly one of `SidebarSurfaceRole`'s three fills while you are pointing
/// at it, have it selected, or have its tile open.
///
/// P1.1 took the border away and P1.2 replaced what it was saying. Before them
/// this was a `tileBody` fill with a `border` outline that became `borderStrong`
/// while selected — one fill in every state, so an OUTLINE was the only signal
/// the list had, and a grey box was painted around every idle row to carry it.
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
    /// The three interaction facts, held SEPARATELY. P3.5 collapsed hover,
    /// selection and keyboard-active into one `isInteracting` test because all
    /// three did the same one thing — clear the row's recession. P1.2 splits
    /// them because they no longer do: each resolves to a different step of the
    /// ladder, and "selected" and "hovered" and "route-active" have to be
    /// distinguishable from each other, not merely from resting.
    var isSelected = false {
        didSet { guard isSelected != oldValue else { return }; applyTokens() }
    }
    var isHovered = false {
        didSet { guard isHovered != oldValue else { return }; applyTokens() }
    }
    /// The agent whose tile is open — the loudest step, because it answers
    /// "where am I" from anywhere in the list.
    var isRouteActive = false {
        didSet { guard isRouteActive != oldValue else { return }; applyTokens() }
    }
    /// P1.4. Not part of the fill ladder at all: focus is a temporary ring, so a
    /// keyboard-focused row and a merely selected row are distinguishable
    /// WITHOUT either of them borrowing the other's fill.
    var hasKeyboardFocus = false {
        didSet {
            guard hasKeyboardFocus != oldValue else { return }
            focusRing.isHidden = !hasKeyboardFocus
        }
    }

    private let focusRing = InboxRowFocusRingView()

    /// Which step of `SidebarSurfaceRole` this row is on, loudest input first.
    ///
    /// ROUTE-ACTIVE OUTRANKS HOVER OUTRANKS SELECTION, which is the ladder's own
    /// order (`SidebarSurfaceRole.rowEmphases` is quietest-first: selected 0.07 <
    /// hover 0.08 < active 0.11). Resolving in the same order the fills are
    /// ordered in is what makes "selection is quieter than hover" true of the
    /// RENDERED row and not merely of the token table: pointing at a selected
    /// row lifts it to hover rather than leaving it at the quieter step.
    var surfaceRole: SidebarSurfaceRole {
        if isRouteActive { return .active }
        if isHovered { return .hover }
        if isSelected { return .selected }
        return .resting
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        // Rows never paint a perimeter: state is fill plus content (P1.1, and
        // `_DESIGN.md`'s "Surface is reserved for interaction"). Assigned once
        // and never again — there is no state that raises it, which is what
        // `checkSidebarProbe` asserts over the live tree in both appearances.
        layer?.borderWidth = 0

        focusRing.translatesAutoresizingMaskIntoConstraints = false
        focusRing.isHidden = true
        addSubview(focusRing)
        NSLayoutConstraint.activate([
            focusRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusRing.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusRing.topAnchor.constraint(equalTo: topAnchor),
            focusRing.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    /// One fill, resolved from the role — never a `LineToken` and never a border.
    ///
    /// `nil` at rest, not `panel`: "unfilled" has to be structurally true rather
    /// than a colour that happens to match, because `UIProbeAppearance`'s
    /// `ownedColorSlots` counts a painted fill and `UIProbeContrast` measures a
    /// row's words against the nearest ancestor that paints one. With `nil` the
    /// sidebar's own `panel` IS the row's background in both gates, which is
    /// exactly what the design decision says a resting row shows.
    func applyTokens() {
        let theme = effectiveTokenTheme
        let role = surfaceRole
        layer?.backgroundColor = role == .resting ? nil : role.color.cgColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// Every line and shadow this row paints, for the P1.1/P1.2/P1.3
    /// assertions: the card's own perimeter (which must be zero in every
    /// state), its shadow (which must be absent — a row may not communicate
    /// state with one), and the focus ring's hairline.
    var qaPaintedLines: [String: Double] {
        [
            "card.border": Double(layer?.borderWidth ?? 0),
            "card.shadowOpacity": Double(layer?.shadowOpacity ?? 0),
            "focusRing.border": Double(focusRing.layer?.borderWidth ?? 0),
        ]
    }

    var qaIsFocusRingVisible: Bool { !focusRing.isHidden }
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
    /// The lower-band subtitle carries human-readable placement facts only. The
    /// model is represented by `providerGlyphLabel`, never printed as a second
    /// identifier on the row.
    private let metaLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let providerGlyphLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var metaBand: NSStackView?
    private var detailBand: NSStackView?
    private var layoutColumnWidth: Double?
    private var leadingInset: NSLayoutConstraint?
    private var metaMinimumWidth: NSLayoutConstraint?
    private var metaCollapsedWidth: NSLayoutConstraint?
    private var branchMinimumWidth: NSLayoutConstraint?
    private var branchCollapsedWidth: NSLayoutConstraint?
    /// What this cell is currently showing. Held so the cell can repaint its own
    /// text colours when the appearance moves — an `NSTextField.textColor` is a
    /// resolved colour, and the list above must not reload the table to fix it
    /// (see `AgentInboxView.applyTokens`).
    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis, disclosure: RowDisclosure,
                        rollup: ChildRollup?)?
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.2-measured-fit-tiers.md
    /// The tier this cell is currently drawn at. Held so `layout()` can re-tier a
    /// LIVE divider drag — the strings do not change while you drag, only the room
    /// they have does — and so a pass that resolves the same tier changes nothing
    /// and cannot loop.
    private var appliedTier: RowFitTier?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        projectLabel.font = .token(.caption)
        projectLabel.lineBreakMode = .byTruncatingTail

        titleLabel.font = .token(.title)
        titleLabel.lineBreakMode = .byTruncatingTail

        stateLabel.font = .token(.label)

        elapsedLabel.font = .token(.captionMono)
        elapsedLabel.lineBreakMode = .byClipping

        metaLabel.font = .token(.label)
        metaLabel.lineBreakMode = .byTruncatingTail

        // Middle, not tail: an `agent/<role>-<slug>` branch is identified by both
        // ends, the same reasoning `BranchChipNSView` records for its own label.
        branchLabel.font = .token(.label)
        branchLabel.lineBreakMode = .byTruncatingMiddle

        providerGlyphLabel.font = .token(.label)
        providerGlyphLabel.setContentHuggingPriority(.required, for: .horizontal)
        providerGlyphLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        providerGlyphLabel.setAccessibilityRole(.image)

        AgentInboxCellView.applySacrificeOrder(
            project: projectLabel, branch: branchLabel, meta: metaLabel,
            title: titleLabel, state: stateLabel, elapsed: elapsedLabel)

        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)

        // THREE BANDS, and the band arithmetic that keeps the card at its height.
        //
        // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.1-title-line-ownership.md
        // `_DESIGN.md`: "The row's subject is its name. The agent's name gets a
        // line of its own and yields last."
        //
        //   band 1  meta    [project, spacer, state, elapsed]   lineHeight(.label) = 14
        //   band 2  name    [disclosure, title]                 lineHeight(.title) = 19
        //   band 3  detail  [branch, isolation/remote, spacer, provider glyph]
        //                                      lineHeight(.label) = 14
        //   + 2 * Space.s between the bands + Inset.card.vertical
        //   = 14 + 19 + 14 + 8 + 24 = 79 = `AgentInboxView.rowHeight` for a
        //     full-content card.
        //
        // Three bands and not four: the full-content case is exactly three lines
        // of type. The lower band gives way from left to right — branch, then the
        // isolation/remote facts, with the provider mark at the trailing edge —
        // while P2.3 collapses an empty band rather than reserving it.
        //
        // THE DISCLOSURE TRIANGLE RIDES THE NAME BAND, DELIBERATELY, and it is
        // not a matter of taste: `InboxDisclosureButton` is an `NSButton`, and its
        // `fittingSize.height` exceeds `Metrics.lineHeight(for: .label)` (14). On
        // band 1 it would inflate that band to the button's own height, the stack
        // would grow past 55pt of content, and the card would overrun the 79pt
        // ceiling `runAgentInboxChecks` asserts ("a card … never exceeds the
        // \(rowHeight)pt ceiling"). On band 2 the band is already
        // `lineHeight(.title)` = 19pt tall, which the button fits inside — so the
        // triangle costs nothing. It also belongs next to the name on the merits:
        // the triangle folds the agent's CHILDREN, and the name is what they are
        // children of.
        let metaBand = NSStackView(views: [projectLabel, NSView(), stateLabel, elapsedLabel])
        self.metaBand = metaBand
        metaBand.orientation = .horizontal
        metaBand.alignment = .firstBaseline
        metaBand.spacing = Space.m
        // The spacer between the project and the status is the flexible one; without
        // this the project chip and the state label share the slack and the status
        // column wanders row to row.
        metaBand.setHuggingPriority(.defaultLow, for: .horizontal)

        let nameBand = NSStackView(views: [disclosureButton, titleLabel])
        nameBand.orientation = .horizontal
        nameBand.alignment = .firstBaseline
        nameBand.spacing = Space.m
        // `.fill`, not the default gravity areas, and it is what makes "the name
        // owns its own line" a measurable fact rather than a description: the
        // title's TRAILING edge is pinned to the band's, so its drawing lane IS
        // the line minus the triangle. Under gravity areas the title's width and
        // the stack's trailing hug are the same priority and the solver may leave
        // the name hugging its content with the rest of the line empty — the same
        // number of points, but not a lane anything can assert against.
        nameBand.distribution = .fill
        nameBand.setHuggingPriority(.defaultLow, for: .horizontal)

        let detailBand = NSStackView(views: [branchLabel, metaLabel, NSView(), providerGlyphLabel])
        self.detailBand = detailBand
        detailBand.orientation = .horizontal
        detailBand.alignment = .firstBaseline
        detailBand.spacing = Space.m
        detailBand.setHuggingPriority(.defaultLow, for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(metaBand)
        stack.addArrangedSubview(nameBand)
        stack.addArrangedSubview(detailBand)
        card.addSubview(stack)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        let elapsedColumn = elapsedLabel.widthAnchor.constraint(
            equalToConstant: AgentInboxCellView.elapsedColumnWidth(unconfirmed: false))
        leadingInset = leading
        NSLayoutConstraint.activate([
            leading,
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Inset.card.left),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Inset.card.right),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Inset.card.top),
            // A content-derived row has no reserved lower shelf: hidden bands
            // collapse in the stack, and the stack is pinned to BOTH vertical
            // edges so the card height is exactly its drawn lines plus insets.
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Inset.card.bottom),
            // Every band spans the card's text column, so the name's line is the
            // NAME's line: nothing else can take width from it, and a childless
            // row's title reaches the trailing edge of the card's text column.
            metaBand.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameBand.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailBand.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // FLOORS, not decoration. Without them a 280pt sidebar squeezes a
            // truncating label to a few points wide, which renders as a rect with
            // no glyph in it — and `UIProbePixels` is right to call that flat:
            // `chrome.sidebar.live … text rect is flat — luminance spread 0.000
            // over 176 px`. Measured off the font rather than guessed, the
            // `BranchChipNSView.minimumTextWidth` precedent.
            //
            // P2.1 adds the band-3 floors: branch and the isolation/remote
            // subtitle may yield, while the provider mark stays a whole glyph.
            // Without a floor the recorded sacrifice would render as a flat rect
            // rather than as an elided string.
            AgentInboxCellView.yieldingMinimumWidth(projectLabel, .caption),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.title)),
            // The duration is a column, not an intrinsic-width label. Its lane is
            // measured from every widest form the shared formatter can emit and
            // includes the NSTextField cell inset, so a longer run cannot take
            // points from the status or project columns. The lane is retuned per
            // row in show(): an unconfirmed row pays for its own "last seen "
            // qualifier instead of taxing every confirmed row's name.
            elapsedColumn,
        ])
        elapsedLaneConstraint = elapsedColumn
        let metaMinimumWidth = AgentInboxCellView.yieldingMinimumWidth(metaLabel, .label)
        self.metaMinimumWidth = metaMinimumWidth
        let metaCollapsedWidth = metaLabel.widthAnchor.constraint(equalToConstant: 0)
        self.metaCollapsedWidth = metaCollapsedWidth
        let branchMinimumWidth = AgentInboxCellView.yieldingMinimumWidth(branchLabel, .label)
        self.branchMinimumWidth = branchMinimumWidth
        let branchCollapsedWidth = branchLabel.widthAnchor.constraint(equalToConstant: 0)
        self.branchCollapsedWidth = branchCollapsedWidth
        NSLayoutConstraint.activate([metaMinimumWidth, branchMinimumWidth])

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

    func setLayoutWidth(_ width: Double) {
        layoutColumnWidth = width
        applyFitTier()
    }

    private func updateDetailSlotConstraints() {
        let drawsMeta = !metaLabel.isHidden
        metaMinimumWidth?.isActive = drawsMeta
        metaCollapsedWidth?.isActive = !drawsMeta

        let drawsBranch = !branchLabel.isHidden
        branchMinimumWidth?.isActive = drawsBranch
        branchCollapsedWidth?.isActive = !drawsBranch
    }

    private func updateBandVisibility() {
        let metaDraws = [projectLabel, stateLabel, elapsedLabel].contains {
            !$0.isHidden && !$0.stringValue.isEmpty
        }
        let detailDraws = [branchLabel, metaLabel, providerGlyphLabel].contains {
            !$0.isHidden && !$0.stringValue.isEmpty
        }
        metaBand?.isHidden = !metaDraws
        detailBand?.isHidden = !detailDraws
    }

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
    /// fourth one: the content-derived height counts the rollup as the existing
    /// detail band, so it cannot create a fourth line or reserve unexplained space.
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, rollup: ChildRollup? = nil,
               isSelected: Bool = false,
               isInteracting: Bool = false, now: Date = Date()) {
        shown = (row, emphasis, disclosure, rollup)
        card.isSelected = isSelected
        leadingInset?.constant = indent
        disclosureButton.show(disclosure)

        projectLabel.stringValue = row.projectName ?? ""
        projectLabel.isHidden = row.projectName?.isEmpty != false
        titleLabel.stringValue = row.displayTitle
        stateLabel.stringValue = row.presentationLabel ?? ""
        stateLabel.isHidden = row.presentationLabel?.isEmpty != false
        let elapsedText = AgentInboxCellView.elapsedText(row.elapsed)
        // The lane is per row (see elapsedColumnWidth(unconfirmed:)): retune it
        // before the string lands so the qualifier is never clipped and a
        // confirmed row never reserves for it.
        elapsedLaneConstraint?.constant = AgentInboxCellView.elapsedColumnWidth(unconfirmed: row.isUnconfirmed)
        elapsedLabel.stringValue = row.isUnconfirmed
            ? elapsedText.map { "last seen \($0)" } ?? ""
            : elapsedText ?? ""
        elapsedLabel.isHidden = elapsedLabel.stringValue.isEmpty
        if row.isUnconfirmed {
            // Confidence is quiet content, not a new state or an accent colour.
            stateLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
            stateLabel.setAccessibilityLabel("Unconfirmed: last known status")
        } else {
            // Cells are recycled: a confirmed row must RESTORE the default so a
            // reused cell cannot show "Working" while VoiceOver still says
            // "Unconfirmed" (P3.4 review round 2, finding 2). nil hands the
            // element back its stringValue-derived description.
            stateLabel.setAccessibilityLabel(nil)
        }
        branchLabel.stringValue = AgentInboxCellView.branchText(branch: row.branch)
        branchLabel.isHidden = branchLabel.stringValue.isEmpty
        metaLabel.stringValue = AgentInboxCellView.metaText(
            isIsolated: row.isIsolated,
            hasBranch: !branchLabel.isHidden,
            rollup: disclosure == .collapsed ? rollup : nil)
        metaLabel.isHidden = metaLabel.stringValue.isEmpty
        updateDetailSlotConstraints()

        let providerGlyph = AgentProviderGlyph.glyph(for: row.model) ?? ""
        let modelLabel = row.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        providerGlyphLabel.stringValue = providerGlyph
        providerGlyphLabel.isHidden = providerGlyph.isEmpty
        providerGlyphLabel.toolTip = modelLabel?.isEmpty == false ? modelLabel : nil
        providerGlyphLabel.setAccessibilityLabel(providerGlyphLabel.toolTip)
        providerGlyphLabel.setAccessibilityRole(.image)

        // Bands are content slots, not semantic state slots. The row model and
        // the live label strings agree on which bands draw; a folded rollup is
        // the one extra detail string supplied by the list. A fit tier may hide
        // the sole project label later, so this is refreshed after tiering too.
        updateBandVisibility()

        projectLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        elapsedLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        metaLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        branchLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        providerGlyphLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        // The accent IS the state's colour (P3.2) and `ready` has none — which is
        // why the label is hidden there rather than painted in some neutral: the
        // resting state carries no word and no colour, and that is the whole of
        // the decision.
        stateLabel.textColor = (row.isUnconfirmed
            ? TextToken.textSecondary.color
            : (row.state.accent?.color ?? TextToken.textSecondary.color)).nsColor(in: self)

        for label in [projectLabel, titleLabel, elapsedLabel, metaLabel, branchLabel, providerGlyphLabel] {
            label.alphaValue = emphasis.textOpacity
        }
        stateLabel.alphaValue = emphasis.accentOpacity

        // The tier is decided AFTER the strings are set, because it is decided by
        // measuring them. Deciding it first would tier yesterday's row.
        appliedTier = nil
        applyRelocatedFacts()
        applyFitTier()
    }

    // MARK: - P2.2 — the measured-fit tier

    /// What this row would like to draw, measured. One struct so the arithmetic
    /// that chooses a tier is a pure function of measured widths, testable without
    /// a window.
    struct RowFitNeeds: Equatable {
        var project: Double
        var state: Double
        var elapsed: Double
        var title: Double
        var disclosure: Double

        /// The width band 1 needs. `Space.m` per gap, counted off the arranged
        /// views that are actually there — the flexible spacer is one of them,
        /// which is why the gap count equals the number of drawn labels.
        func metaBandNeed(elapsed drawsElapsed: Bool, project drawsProject: Bool) -> Double {
            let widths = [drawsProject ? project : 0, state, drawsElapsed ? elapsed : 0]
            let drawn = widths.filter { $0 > 0 }
            return drawn.reduce(0, +) + Space.m * Double(drawn.count)
        }

        /// The width band 2 needs: the triangle, its gap, and the whole name.
        var nameBandNeed: Double { title + (disclosure > 0 ? disclosure + Space.m : 0) }
    }

    /// The tier `needs` resolves to in `available` points of text column.
    ///
    /// A PURE FUNCTION OF TWO MEASUREMENTS, with no width literal anywhere in it.
    /// The ladder walks the recorded sacrifice order from the cheapest give to the
    /// dearest and stops at the first tier that fits.
    ///
    /// THE NAME IS PART OF THE TEST, and that is a decision worth stating: a row
    /// whose own name does not fit is at the tightest tier even when its metadata
    /// would have fitted. Hiding the caption gives the name no width back — the
    /// bands are independent, that is the point of P2.1 — so this is not width
    /// recovery. It is the row refusing to spend a single point on decoration
    /// while it is failing to say the one thing it is for. It is also what makes
    /// the recorded order checkable end to end: the name can only be found elided
    /// on a row that has already dropped everything a tier is allowed to drop.
    static func fitTier(available: Double, needs: RowFitNeeds) -> RowFitTier {
        func fits(_ tier: RowFitTier) -> Bool {
            needs.metaBandNeed(elapsed: tier.drawsElapsed, project: tier.drawsProject) <= available
                && needs.nameBandNeed <= available
        }
        if fits(.full) { return .full }
        if fits(.abbreviated) { return .abbreviated }
        return .captionHidden
    }

    /// Resolve the same measured-fit tier before AppKit builds a cell. The table
    /// delegate uses this to derive row height from the labels that will remain
    /// visible after the tier drops a project or elapsed column; the live cell
    /// passes its actual disclosure width through the overload below.
    static func fitTier(
        for row: AgentInboxRow,
        available: Double,
        disclosure: RowDisclosure,
        disclosureWidth: Double? = nil
    ) -> RowFitTier {
        let needs = RowFitNeeds(
            project: measuredTextWidth(row.projectName ?? "", .caption),
            state: measuredTextWidth(row.presentationLabel ?? "", .label),
            elapsed: measuredTextWidth(
                row.isUnconfirmed
                    ? elapsedText(row.elapsed).map { "last seen \($0)" } ?? ""
                    : elapsedText(row.elapsed) ?? "", .captionMono),
            title: measuredTextWidth(row.displayTitle, .title),
            disclosure: disclosure == .none
                ? 0
                : disclosureWidth ?? measuredDisclosureWidth(disclosure))
        return fitTier(available: available, needs: needs)
    }

    /// Match the width the live disclosure button contributes to its name band
    /// when height is asked before a cell exists.
    private static func measuredDisclosureWidth(_ disclosure: RowDisclosure) -> Double {
        guard disclosure != .none else { return 0 }
        let button = InboxDisclosureButton()
        button.show(disclosure)
        return Double(button.fittingSize.width)
    }

    /// Re-measure and re-tier. Called after `apply` sets the strings and again
    /// from `layout()`, so dragging the sidebar divider re-tiers every visible row
    /// without the list reloading anything.
    private func applyFitTier() {
        guard let shown else { return }
        // An un-laid-out cell has no room to measure against; tiering it would
        // resolve the tightest tier off a zero width and hide facts on a row that
        // is about to be given 300pt. The first real layout pass tiers it.
        let available = (layoutColumnWidth ?? Double(bounds.width))
            - Double(leadingInset?.constant ?? 0) - Inset.card.horizontal
        guard available > 0 else { return }

        let tier = AgentInboxCellView.fitTier(
            for: shown.row,
            available: available,
            disclosure: shown.disclosure,
            disclosureWidth: Double(disclosureButton.fittingSize.width))
        guard tier != appliedTier else { return }
        appliedTier = tier

        // A tier may only ever take a fact AWAY from a row that has one: the
        // row's own nil-ness still decides whether the label exists at all.
        projectLabel.isHidden = shown.row.projectName?.isEmpty != false || !tier.drawsProject
        elapsedLabel.isHidden = AgentInboxCellView.elapsedText(shown.row.elapsed) == nil
            || !tier.drawsElapsed
        updateBandVisibility()
        applyRelocatedFacts()
    }

    /// Fold whatever the tier stopped DRAWING into the cell's accessibility label,
    /// so a dropped column is relocated rather than lost. A sighted person loses
    /// the project chip at 220pt because there is no room for it; a VoiceOver user
    /// has no width problem at all, and taking the fact off the tree for them would
    /// be a bug dressed as adaptivity.
    private func applyRelocatedFacts() {
        guard let shown else { return }
        var spoken = [titleLabel.stringValue]
        if !stateLabel.isHidden, !stateLabel.stringValue.isEmpty {
            spoken.append(stateLabel.stringValue)
        }
        if projectLabel.isHidden, let project = shown.row.projectName {
            spoken.append(project)
        }
        if elapsedLabel.isHidden, let elapsed = AgentInboxCellView.elapsedText(shown.row.elapsed) {
            spoken.append(elapsed)
        }
        // The visible provider mark is intentionally terse, but VoiceOver must
        // still receive the complete model even when the child label is not the
        // element AppKit focuses first.
        if let model = providerGlyphLabel.toolTip {
            spoken.append(model)
        }
        setAccessibilityLabel(spoken.joined(separator: ", "))
    }

    override func layout() {
        super.layout()
        applyFitTier()
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

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    func applyInteraction(_ interaction: RowInteraction) {
        card.isHovered = interaction.isHovered
        card.isRouteActive = interaction.isRouteActive
        card.hasKeyboardFocus = interaction.hasKeyboardFocus
    }

    @discardableResult
    func clickDisclosureForQA() -> Bool {
        guard !disclosureButton.isHidden else { return false }
        disclosureButton.performClick(nil)
        return true
    }

    /// Four characters of `role`, so a squeezed row truncates rather than
    /// collapsing a label to an empty sliver.
    ///
    /// Ticket: docs/38-tickets/94-sidebar-native-ux/P2.2-measured-fit-tiers.md
    /// `+ Metrics.cellTextInset`, and that addend is the packet. Without it the
    /// floor was exactly the width the STRING measures, so the guaranteed minimum
    /// handed the cell no room for its own inset and AppKit elided `"0000"` at the
    /// floor — a floor that ellipsises its own content is not a floor. The same
    /// constant is what `inboxLabelGeometryForQA` reports as `neededWidth`, so the
    /// layout and the gate measure with one number and cannot disagree.
    static func minimumTextWidth(_ role: TextRole) -> Double {
        Double(ceil(("0000" as NSString).size(withAttributes: [.font: NSFont.token(role)]).width))
            + Metrics.cellTextInset
    }

    /// The guaranteed-minimum floor for a label the sacrifice order allows to
    /// yield — the project chip, the branch, the role/rollup line.
    ///
    /// PRIORITY 999, NOT `.required`, and it is the same one-point argument
    /// `nameCompressionResistance` makes from the other side. A floor at 1000
    /// inside a line whose leading and trailing edges are ALSO pinned at 1000 is
    /// not a floor: when the floors plus the incompressible labels outrun the row,
    /// Auto Layout breaks one of them at its own discretion, and what it broke was
    /// not the floor. MEASURED, adding `Metrics.cellTextInset` to
    /// `minimumTextWidth` took the parked row's minimum line from 191pt to 199pt
    /// against 196pt of room, and the gate reported
    /// `row51.glyph@min lost 4.5pt (needed 15.0, drawable 10.5)` — the row's
    /// STATE GLYPH, the whole meaning of a collapsed row, elided to nothing on a
    /// row this packet never touched. At 999 the floors give way to the row's own
    /// width, in the order the sacrifice ladder already puts them in, and the
    /// labels that may not be elided keep what they need.
    ///
    /// The NAME's floor stays `.required` on purpose: it is the last rung, so
    /// there is nothing below it left to yield.
    static func yieldingMinimumWidth(_ label: NSView, _ role: TextRole) -> NSLayoutConstraint {
        let floor = label.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumTextWidth(role))
        floor.priority = nameCompressionResistance
        return floor
    }

    /// The width `text` needs before `role`'s cell elides it — the same
    /// arithmetic the QA seam reports and the gate compares against, so a tier
    /// decided here cannot be measured differently there. Empty is zero rather
    /// than the bare inset: an empty label is hidden, and a hidden label needs
    /// nothing.
    static func measuredTextWidth(_ text: String, _ role: TextRole) -> Double {
        guard !text.isEmpty else { return 0 }
        return Double(ceil((text as NSString).size(withAttributes: [.font: NSFont.token(role)]).width))
            + Metrics.cellTextInset
    }

    // MARK: - P2.1 — the recorded sacrifice order
    //
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P2.1-title-line-ownership.md
    //
    // DECISION — the sacrifice order, written down rather than emergent:
    //
    //     caption/project chip  →  branch  →  metrics  →  role/rollup  →  NAME
    //
    // Read left to right: the project chip is the first thing a narrowing row
    // gives up and the agent's NAME is the last. It is a decision about what a
    // row is FOR, not a consequence of whichever priority happened to be lower:
    // the row's subject is its name, and a row that answers "which of my five
    // checkouts is this" while refusing to say WHICH AGENT has answered nothing.
    //
    // THE DEFECT THIS INVERTS. Until P2.1 `titleLabel` carried `.defaultLow` and
    // the project chip carried AppKit's default 750, so the NAME was the first
    // thing to yield and the chip survived. `expectedSidebarTruncations` measured
    // that as 109 title entries against 4 project entries — the yields-first
    // defect, counted.
    //
    // The order is enforced in TWO registers, because "yield" means two different
    // things to two different kinds of label:
    //
    //  · TRUNCATION, for the labels that can lose their tail and still be read:
    //    the caption, the branch and the role/rollup line. Those three carry the
    //    ladder below and give way in that order.
    //  · BEING DROPPED, for `stateLabel` and `elapsedLabel`. Both stay `.required`
    //    forever: the one word saying what the agent is doing is never half a
    //    word, and `2h1…` is not a duration. A row too tight for the metrics does
    //    not shave them, it stops drawing them — which is P2.2's tier ladder, not
    //    a priority.
    //
    // `stateLabel` is never a sacrifice in either register. It is the answer to
    // "what is this agent doing", which is the one question the list exists for.

    /// The name's compression resistance: the highest priority strictly BELOW the
    /// constraints that give the row its width.
    ///
    /// NOT `.required`, and the one point of difference is load-bearing. Every
    /// band is pinned to the card's text column at `.required`; a truncating label
    /// whose compression resistance is ALSO `.required` makes that system
    /// unsatisfiable the moment a name is longer than the row, and AppKit then
    /// breaks one of the two at its own discretion. When it breaks the band's
    /// width the name draws OUTSIDE the card and reports its full drawable width —
    /// so the truncation gate would read a clipped name as a healed one, which is
    /// the worst possible failure mode for a gate that exists to count elisions.
    /// At 999 the name loses to the row's own width and to nothing else, which is
    /// exactly what "yields last" means.
    static let nameCompressionResistance = NSLayoutConstraint.Priority(999)

    /// The three truncating labels, in sacrifice order: the project chip gives way
    /// first, then the branch, then the role/rollup line. Spaced one point apart
    /// off `.defaultLow` so the ladder is strictly ordered — equal priorities
    /// would let Auto Layout choose, and a chosen order is not a recorded one.
    static let projectCompressionResistance = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 2)
    static let branchCompressionResistance = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
    static let metaCompressionResistance = NSLayoutConstraint.Priority.defaultLow

    /// Stamp the recorded order onto the six labels. One function so the ladder
    /// exists in exactly one place, and so `--sidebar-ux-check` can assert the
    /// live priorities it produced rather than trusting six scattered calls.
    static func applySacrificeOrder(
        project: NSTextField, branch: NSTextField, meta: NSTextField,
        title: NSTextField, state: NSTextField, elapsed: NSTextField
    ) {
        project.setContentCompressionResistancePriority(projectCompressionResistance, for: .horizontal)
        branch.setContentCompressionResistancePriority(branchCompressionResistance, for: .horizontal)
        meta.setContentCompressionResistancePriority(metaCompressionResistance, for: .horizontal)
        title.setContentCompressionResistancePriority(nameCompressionResistance, for: .horizontal)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The lower-band facts after the branch. A shared checkout is meaningful only
    /// when a branch is present; an isolated checkout remains a fact even when a
    /// branch name is unavailable. A remote marker is accepted for the future row
    /// source but omitted when no remote fact exists, rather than reserving an empty
    /// slot. A folded rollup remains first because it is the only place a hidden
    /// child can speak for itself.
    ///
    /// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
    /// A folded parent's rollup goes on the FRONT of this line, in the same ` · `
    /// vocabulary. First, not last, because `metaLabel` truncates by tail on a narrow
    /// sidebar and the thing that must survive the squeeze is what the fold is
    /// hiding — "1 needs you" exists nowhere else while the group is closed.
    static func metaText(
        isIsolated: Bool,
        hasBranch: Bool,
        remote: String? = nil,
        rollup: ChildRollup? = nil
    ) -> String {
        let isolation = isIsolated ? "isolated" : (hasBranch ? "shared" : nil)
        return [rollup?.summary, isolation, remote]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The branch line, in `BranchChipNSView`'s vocabulary. Isolation is its own
    /// lower-band fact now, so the branch text does not repeat the shared marker;
    /// the tile and inbox still agree on the branch glyph itself.
    ///
    /// The chip's third state — assigned one branch, checked out on another — is
    /// deliberately absent: `AgentInboxRow` carries one resolved branch name and
    /// no mismatch fact (P3.1 flattened it that way), and inventing a warning from
    /// a name this view cannot compare would be a guess.
    static func branchText(branch: String?) -> String {
        guard let branch, !branch.isEmpty else { return "" }
        return "\(BranchChipNSView.branchGlyph) \(branch)"
    }

    /// The one shared duration vocabulary used by cards, parked rows, the tile
    /// header and future phone payloads. A negative optional is absent from a row
    /// (it is not a real elapsed fact); malformed finite/infinite values are made
    /// safe by `AgentElapsedFormatter` when a caller has a non-negative value.
    static func elapsedText(_ elapsed: TimeInterval?) -> String? {
        guard let elapsed, elapsed >= 0 else { return nil }
        return AgentElapsedFormatter.elapsedLabel(elapsed)
    }

    /// Width of the card's elapsed column, measured with the exact caption-mono
    /// font and the same 4pt NSTextField cell inset used by the drawable-width
    /// QA seam. The formatter owns the candidate labels; the AppKit layer only
    /// measures them.
    static var elapsedColumnWidth: Double { elapsedColumnWidth(unconfirmed: false) }

    /// PER ROW, not per surface: only an unconfirmed row reserves room for its
    /// "last seen " qualifier. A shared column sized for the qualifier taxed
    /// every confirmed row ~45pt of name/project room for a form it never
    /// renders — the oversized-reservation defect P0.4 quantified, reintroduced
    /// through the elapsed lane. Within one row's life the lane is still fixed
    /// across every clock tick (P2.5); confirmed→unconfirmed is a state change,
    /// not a tick, and it may move the lane.
    static func elapsedColumnWidth(unconfirmed: Bool) -> Double {
        let font = NSFont.token(.captionMono)
        let labels = unconfirmed
            ? AgentElapsedFormatter.columnLabels.map { "last seen \($0)" }
            : AgentElapsedFormatter.columnLabels
        return labels.map { label in
            Double(ceil((label as NSString).size(withAttributes: [.font: font]).width))
                + Metrics.cellTextInset
        }.max() ?? Metrics.cellTextInset
    }

    private var elapsedLaneConstraint: NSLayoutConstraint?

    var qaAgentID: UUID? { shown?.row.id }
    var qaVariant: RowVariant? { shown?.row.variant }
    var qaGeometry: AgentInboxRowGeometryForQA {
        let labels = [
            inboxLabelGeometryForQA("project", label: projectLabel, in: self),
            inboxLabelGeometryForQA("title", label: titleLabel, in: self),
            inboxLabelGeometryForQA("state", label: stateLabel, in: self),
            inboxLabelGeometryForQA("elapsed", label: elapsedLabel, in: self),
            inboxLabelGeometryForQA("meta", label: metaLabel, in: self),
            inboxLabelGeometryForQA("branch", label: branchLabel, in: self),
            inboxLabelGeometryForQA("provider", label: providerGlyphLabel, in: self),
        ]
        return AgentInboxRowGeometryForQA(
            agentID: shown?.row.id,
            state: shown?.row.state,
            variant: shown?.row.variant,
            elementFrames: [
                "cell": bounds,
                "card": card.convert(card.bounds, to: self),
                "project": labels[0].frame,
                "title": labels[1].frame,
                "state": labels[2].frame,
                "elapsed": labels[3].frame,
                "meta": labels[4].frame,
                "branch": labels[5].frame,
                "provider": labels[6].frame,
            ],
            labels: labels,
            paintedBorderWidth: card.layer.map { Double($0.borderWidth) },
            resolvedFill: card.layer?.backgroundColor,
            surfaceRole: card.surfaceRole,
            paintedLines: card.qaPaintedLines,
            isFocusRingVisible: card.qaIsFocusRingVisible,
            accessibilityLabel: accessibilityLabel(),
            fitTier: appliedTier,
            slimFitTier: nil
        )
    }
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
    var qaJumpHintHitTestPassesThrough: Bool {
        jumpHint.hitTest(NSPoint(x: jumpHint.bounds.midX, y: jumpHint.bounds.midY)) == nil
    }
    var qaStatusFrame: NSRect { stateLabel.convert(stateLabel.bounds, to: self) }
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }

    /// The row body is the rename surface. The disclosure button is the only
    /// nested interactive control in this cell, so a double-click there belongs
    /// to folding rather than naming.
    func acceptsRenameDoubleClick(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard !disclosureButton.isHidden,
              disclosureButton.isDescendant(of: self),
              disclosureButton.bounds.contains(convert(point, to: disclosureButton))
        else { return true }
        return false
    }

    var renameNestedControlFrameForQA: NSRect? {
        guard !disclosureButton.isHidden else { return nil }
        return disclosureButton.convert(disclosureButton.bounds, to: self)
    }
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
    private var layoutColumnWidth: Double?
    private var leadingInset: NSLayoutConstraint?
    private var branchMinimumWidth: NSLayoutConstraint?
    private var branchCollapsedWidth: NSLayoutConstraint?
    private var timeColumnWidth: NSLayoutConstraint?
    private var timeCollapsedWidth: NSLayoutConstraint?
    private var appliedTier: SlimRowFitTier?
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
        // The name is the subject and yields LAST. The branch is the first
        // optional fact to leave the one-line row, followed by its relative-time
        // metric; the glyph and the name remain the purpose of the row.
        titleLabel.setContentCompressionResistancePriority(
            AgentInboxCellView.nameCompressionResistance, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        branchLabel.font = .token(.label)
        // Middle, for the same reason the card's branch line uses it. Its live
        // floor is retracted when the measured tier drops the branch entirely.
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentCompressionResistancePriority(
            AgentInboxCellView.branchCompressionResistance, for: .horizontal)

        timeLabel.font = .token(.captionMono)
        timeLabel.lineBreakMode = .byClipping
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)

        // A parked group folds too: a snoozed parent and its snoozed children are
        // nested in the shelf the same way the live block nests. The line uses
        // measured tiers below rather than letting Auto Layout choose which
        // optional fact to squeeze.
        let line = NSStackView(views: [disclosureButton, glyphLabel, titleLabel, branchLabel, timeLabel])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.distribution = .fill
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

            // The name's minimum includes the NSTextField cell inset. Optional
            // columns have matching zero-width constraints, so a dropped label
            // cannot keep reserving the room the tier just gave to the name.
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.title)),
            // The branch floor and the fixed time lane are installed below as
            // switchable constraints, so a dropped column cannot retain a hidden
            // width through a second anonymous constraint.
        ])

        let branchMinimum = AgentInboxCellView.yieldingMinimumWidth(branchLabel, .label)
        branchMinimumWidth = branchMinimum
        let branchCollapsed = branchLabel.widthAnchor.constraint(equalToConstant: 0)
        branchCollapsedWidth = branchCollapsed
        // The fixed time lane is a measured requirement while present, not an
        // intrinsic width that can steal the name's line. A zero companion makes
        // hiding it structural.
        let timeColumn = timeLabel.widthAnchor.constraint(equalToConstant: AgentInboxSlimCellView.relativeTimeColumnWidth)
        timeColumnWidth = timeColumn
        let timeCollapsed = timeLabel.widthAnchor.constraint(equalToConstant: 0)
        timeCollapsedWidth = timeCollapsed
        // Start with both optional columns collapsed. `apply` switches these
        // pairs from the measured tier after their live strings are known.
        NSLayoutConstraint.deactivate([
            branchMinimum,
            timeColumn,
        ])
        NSLayoutConstraint.activate([
            branchCollapsed,
            timeCollapsed,
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

    func setLayoutWidth(_ width: Double) {
        layoutColumnWidth = width
        applyFitTier()
    }

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
    private func updateOptionalSlotConstraints() {
        let drawsBranch = !branchLabel.isHidden && !branchLabel.stringValue.isEmpty
        branchMinimumWidth?.isActive = drawsBranch
        branchCollapsedWidth?.isActive = !drawsBranch

        let drawsTime = !timeLabel.isHidden && !timeLabel.stringValue.isEmpty
        timeColumnWidth?.isActive = drawsTime
        timeCollapsedWidth?.isActive = !drawsTime
    }

    struct SlimRowFitNeeds: Equatable {
        let glyph: Double
        let title: Double
        let branch: Double
        let time: Double
        let disclosure: Double

        func total(drawsBranch: Bool, drawsTime: Bool) -> Double {
            let widths = [glyph, title,
                          drawsBranch ? branch : 0,
                          drawsTime ? time : 0,
                          disclosure]
                .filter { $0 > 0 }
            guard !widths.isEmpty else { return 0 }
            return widths.reduce(0, +) + Space.m * Double(widths.count - 1)
        }
    }

    /// Resolve the slim row's tier from measured need, not a sidebar-width
    /// threshold. The fixed time lane is measured from the shared formatter's
    /// widest relative form so a clock tick cannot take points back from the
    /// name after the tier has been chosen.
    static func fitTier(available: Double, needs: SlimRowFitNeeds) -> SlimRowFitTier {
        if needs.total(drawsBranch: true, drawsTime: true) <= available {
            return .full
        }
        if needs.branch > 0,
           needs.total(drawsBranch: false, drawsTime: true) <= available {
            return .branchHidden
        }
        return .timeHidden
    }

    static func fitTier(
        for row: AgentInboxRow,
        available: Double,
        disclosure: RowDisclosure,
        disclosureWidth: Double? = nil,
        timeText: String? = nil
    ) -> SlimRowFitTier {
        // Height is fixed for the slim variant, so the live cell supplies the
        // injected-clock string. A caller that only has the row still gets a
        // conservative lifecycle-based presence answer for deterministic math.
        let resolvedTime = timeText ?? {
            switch row.lifecycle {
            case .settled, .snoozed: return "present"
            case .active, .archived: return ""
            }
        }()
        let needs = SlimRowFitNeeds(
            glyph: measuredTextWidth(glyph(for: row.state), .label),
            title: AgentInboxCellView.measuredTextWidth(row.displayTitle, .title),
            branch: AgentInboxCellView.measuredTextWidth(branchText(branch: row.branch), .label),
            time: resolvedTime.isEmpty ? 0 : relativeTimeColumnWidth(unconfirmed: row.isUnconfirmed),
            disclosure: disclosure == .none
                ? 0
                : disclosureWidth ?? measuredDisclosureWidth(disclosure))
        return fitTier(available: available, needs: needs)
    }

    private static func measuredTextWidth(_ text: String, _ role: TextRole) -> Double {
        AgentInboxCellView.measuredTextWidth(text, role)
    }

    private static func measuredDisclosureWidth(_ disclosure: RowDisclosure) -> Double {
        guard disclosure != .none else { return 0 }
        let button = InboxDisclosureButton()
        button.show(disclosure)
        return Double(button.fittingSize.width)
    }

    private func applyFitTier() {
        guard let shown else { return }
        let available = (layoutColumnWidth ?? Double(bounds.width))
            - Double(leadingInset?.constant ?? 0) - Inset.row.horizontal
        guard available > 0 else { return }
        let tier = AgentInboxSlimCellView.fitTier(
            for: shown.row,
            available: available,
            disclosure: shown.disclosure,
            disclosureWidth: Double(disclosureButton.fittingSize.width),
            timeText: timeLabel.stringValue)
        guard tier != appliedTier else { return }
        appliedTier = tier
        branchLabel.isHidden = shown.row.branch?.isEmpty != false || !tier.drawsBranch
        timeLabel.isHidden = timeLabel.stringValue.isEmpty || !tier.drawsTime
        updateOptionalSlotConstraints()
        applyRelocatedFacts()
    }

    /// A dropped branch or relative time is relocated into the cell's spoken
    /// label. The sighted row keeps its name-first line; VoiceOver keeps every
    /// fact the measured tier had to remove.
    private func applyRelocatedFacts() {
        guard self.shown != nil else { return }
        var spoken = [titleLabel.stringValue]
        if branchLabel.isHidden, !branchLabel.stringValue.isEmpty {
            spoken.append(branchLabel.stringValue)
        }
        if timeLabel.isHidden, !timeLabel.stringValue.isEmpty {
            spoken.append(timeLabel.stringValue)
        }
        setAccessibilityLabel(spoken.joined(separator: ", "))
    }

    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, rollup: ChildRollup? = nil,
               isSelected: Bool = false,
               isInteracting: Bool = false, now: Date = Date()) {
        shown = (row, emphasis, disclosure, isInteracting, now)
        card.isSelected = isSelected
        leadingInset?.constant = indent
        disclosureButton.show(disclosure)

        glyphLabel.stringValue = AgentInboxSlimCellView.glyph(for: row.isUnconfirmed ? .ready : row.state)
        glyphLabel.setAccessibilityLabel(row.isUnconfirmed ? "Unconfirmed" : (row.state.label ?? "Ready"))
        glyphLabel.setAccessibilityRole(.image)
        titleLabel.stringValue = row.displayTitle
        branchLabel.stringValue = AgentInboxSlimCellView.branchText(branch: row.branch)
        branchLabel.isHidden = branchLabel.stringValue.isEmpty
        let relativeText = AgentInboxSlimCellView.relativeText(for: row.lifecycle, now: now)
        timeColumnWidth?.constant = AgentInboxSlimCellView.relativeTimeColumnWidth(unconfirmed: row.isUnconfirmed)
        timeLabel.stringValue = row.isUnconfirmed
            ? AgentInboxCellView.elapsedText(row.elapsed).map { "last seen \($0)" } ?? ""
            : relativeText
        timeLabel.isHidden = timeLabel.stringValue.isEmpty
        updateOptionalSlotConstraints()

        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        branchLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        timeLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        glyphLabel.textColor = (row.state.accent?.color ?? TextToken.textSecondary.color).nsColor(in: self)

        for label in [titleLabel, branchLabel, timeLabel] {
            label.alphaValue = emphasis.textOpacity
        }
        glyphLabel.alphaValue = isInteracting ? Opacity.full : Opacity.receded
        appliedTier = nil
        applyFitTier()
    }

    override func layout() {
        super.layout()
        applyFitTier()
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

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    func applyInteraction(_ interaction: RowInteraction) {
        card.isHovered = interaction.isHovered
        card.isRouteActive = interaction.isRouteActive
        card.hasKeyboardFocus = interaction.hasKeyboardFocus
    }

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

    /// Width of the parked-row time column, measured for both suffix/prefix
    /// forms from the shared formatter's own candidate labels and the exact
    /// caption-mono font. The 4pt cell inset is part of the lane.
    static var relativeTimeColumnWidth: Double { relativeTimeColumnWidth(unconfirmed: false) }

    /// Per row, mirroring the card's rule: the "last seen " qualifier is paid
    /// for only by the unconfirmed row that renders it.
    static func relativeTimeColumnWidth(unconfirmed: Bool) -> Double {
        let font = NSFont.token(.captionMono)
        let labels = AgentElapsedFormatter.columnLabels.flatMap {
            unconfirmed ? ["last seen \($0)"] : ["\($0) ago", "in \($0)"]
        }
        return labels.map { label in
            Double(ceil((label as NSString).size(withAttributes: [.font: font]).width))
                + Metrics.cellTextInset
        }.max() ?? Metrics.cellTextInset
    }

    /// How long ago the work stopped, or how long until a snooze is up.
    ///
    /// In `AgentInboxCellView.elapsedText`'s units, reused rather than
    /// reimplemented, so a duration means the same thing on a card and on the row
    /// it collapses into. Empty for a lifecycle with no time to show and for a
    /// distance that has gone negative — an overdue snooze is P4.6's raised hand,
    /// not a row for this view to label "in -3m".
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

    var qaAgentID: UUID? { shown?.row.id }
    var qaVariant: RowVariant? { shown?.row.variant }
    var qaGeometry: AgentInboxRowGeometryForQA {
        let labels = [
            inboxLabelGeometryForQA("glyph", label: glyphLabel, in: self),
            inboxLabelGeometryForQA("title", label: titleLabel, in: self),
            inboxLabelGeometryForQA("branch", label: branchLabel, in: self),
            inboxLabelGeometryForQA("time", label: timeLabel, in: self),
        ]
        var frames: [String: NSRect] = [
            "cell": bounds,
            "card": card.convert(card.bounds, to: self),
            "glyph": labels[0].frame,
            "title": labels[1].frame,
            "branch": labels[2].frame,
            "time": labels[3].frame,
        ]
        // A parent's fold triangle takes real room in the one line this variant
        // has, so the tier oracle must be able to see it. Reported only when
        // drawn: a parked parent whose cell HID the triangle to make room shows
        // up as a missing entry, which is the defect, not a formatting choice.
        if let disclosure = shown?.disclosure, disclosure != .none, !disclosureButton.isHidden {
            frames["disclosure"] = disclosureButton.convert(disclosureButton.bounds, to: self)
        }
        return AgentInboxRowGeometryForQA(
            agentID: shown?.row.id,
            state: shown?.row.state,
            variant: shown?.row.variant,
            elementFrames: frames,
            labels: labels,
            paintedBorderWidth: card.layer.map { Double($0.borderWidth) },
            resolvedFill: card.layer?.backgroundColor,
            surfaceRole: card.surfaceRole,
            paintedLines: card.qaPaintedLines,
            isFocusRingVisible: card.qaIsFocusRingVisible,
            accessibilityLabel: accessibilityLabel(),
            // The slim row reports its own measured ladder rather than pretending
            // to have resolved one of the card's three-band tiers.
            fitTier: nil,
            slimFitTier: appliedTier
        )
    }
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
    var qaJumpHintHitTestPassesThrough: Bool {
        jumpHint.hitTest(NSPoint(x: jumpHint.bounds.midX, y: jumpHint.bounds.midY)) == nil
    }
    /// The GLYPH is this variant's status (`qaStateLabel` is empty by design), so
    /// that is the frame the pill must not move.
    var qaStatusFrame: NSRect { glyphLabel.convert(glyphLabel.bounds, to: self) }
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }

    func acceptsRenameDoubleClick(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard !disclosureButton.isHidden,
              disclosureButton.isDescendant(of: self),
              disclosureButton.bounds.contains(convert(point, to: disclosureButton))
        else { return true }
        return false
    }

    var renameNestedControlFrameForQA: NSRect? {
        guard !disclosureButton.isHidden else { return nil }
        return disclosureButton.convert(disclosureButton.bounds, to: self)
    }
}
