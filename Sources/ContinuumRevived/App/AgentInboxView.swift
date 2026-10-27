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
// in the row: which parents you have folded. That is local UI state, never
// synced, because which groups you collapsed on this Mac is not a fact about the
// agents (the packet says so in as many words).
//
// Launch polish, item Q: a group starts FOLDED — the parent's card, its rollup
// line and the cards tucked behind it say what it holds — and each parent keeps
// the choice you last made for it, which the host persists. One rule opens a
// group you never touched: a child that needs you or failed. Your own choice
// always wins over it — a group you folded stays folded when a child reports in
// (P3.6's frozen-order argument: the list moves when you act).

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
    /// Whether the live cell resolved its semantic interaction fill through the
    /// Increase Contrast environment branch. The ordinary surface checks pin this
    /// false; the accessibility sweep drives both branches through the same seam.
    let increasedContrast: Bool
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

/// Internal, not private: program 96's card (`AgentInbox96CellView`) reports its
/// label geometry through the same helper, so the two cells cannot describe
/// themselves to a gate in two different ways.
@MainActor
func inboxLabelGeometryForQA(
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
private final class AgentInboxStatusAnnouncementOwner: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Status")
    }

    required init?(coder: NSCoder) { return nil }

    func apply(summary: String) {
        setAccessibilityLabel("Status: \(summary)")
        setAccessibilityValue(summary)
        setAccessibilityEnabled(true)
    }
}

@MainActor
private final class AgentInboxTableView: NSTableView {
    weak var contextHandler: AgentInboxView?

    override func keyDown(with event: NSEvent) {
        // Keep ordinary traversal in NSTableView so its native type-select,
        // range-selection and modifier semantics remain intact. The inbox only
        // owns the two activation keys and the post-traversal visibility guarantee.
        if contextHandler?.handleTableActivationKey(event) == true { return }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "z", contextHandler?.undoFromKeyboard() == true { return }
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

    /// Every cursor rect this table registered on its last `resetCursorRects`,
    /// recorded at the AppKit seam so a check reads what the pointer will see.
    private(set) var registeredCursorsForQA: [NSCursor] = []

    override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
        registeredCursorsForQA.append(object)
        super.addCursorRect(rect, cursor: object)
    }

    // No row cursor. A pointing hand over every whole row is a web idiom;
    // native sidebars (Finder, Mail, Xcode) keep the arrow, and with the hand
    // everywhere the row's real buttons gave no distinct feedback.
    override func resetCursorRects() {
        registeredCursorsForQA = []
        super.resetCursorRects()
    }
}

@MainActor
/// An alternative CARD presentation for the inbox, injected from outside.
///
/// Program 96 redesigns the row. It needs to be operated — scrolled, hovered,
/// selected, right-clicked — long before the S0 pitch ruling lets it become the
/// default, and reimplementing this list to do that would mean a second sidebar
/// with its own bugs. So the list stays exactly as queue 94 built it and the two
/// things that differ are handed in: how a card row is built, and how tall it is.
///
/// Program 96 is now the production default. Keeping this optional seam for the
/// moment lets the Component Lab compare the retired queue-94 cell without
/// maintaining a second list implementation; nil explicitly requests that legacy
/// comparison.
struct AgentInboxCardStyleOverride {
    let makeCell: () -> AgentInboxRowCell
    /// A 96 card's height is fixed by its pitch rather than derived from which
    /// bands have content, because every band always has content.
    let cardHeight: (AgentInboxRow) -> Double

    static var production: Self {
        let proposal = SidebarDensityProposal.production
        let anatomy = SidebarRowAnatomy(
            id: "production", label: "production",
            border: .none, iconPlacement: .leading, showsModelText: false)
        return Self(
            makeCell: {
                AgentInbox96CellView(
                    proposal: proposal, anatomy: anatomy,
                    prefersReducedMotion: {
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    })
            },
            cardHeight: { _ in AgentInbox96CellView.rowHeight(for: proposal) })
    }
}

/// An alternative HEADER presentation, injected the same way and for the same
/// reason as `AgentInboxCardStyleOverride`.
///
/// The scope control and the search field are shipped chrome — unlike the row,
/// they are not behind any seam, so a redesign of them would move the committed
/// `chrome.agentInbox` baselines and change what every user sees, while the design
/// is still being argued about. This is that seam.
///
/// The stacked, boxless search treatment is now the production default. nil is
/// retained only for the Component Lab's explicit legacy comparison.
struct AgentInboxHeaderStyleOverride {
    /// T3 nightly's ONE header row (confidence pass, sidebar stream): search
    /// (flexible), then the scope control, then a 28pt New agent button. Wins over
    /// `stacked` when both are set.
    var oneRow = true
    /// Search takes a full-width row of its own, above the scope control, rather
    /// than sharing one row with it.
    var stacked = true
    /// Search paints a recessed field with a leading magnifier, so it reads as
    /// something you can type into. Bare placeholder text over the panel reads as
    /// a label — which is exactly what it looked like.
    var fieldChrome = true
}

/// An `NSTextFieldCell` that reserves room on its leading edge.
///
/// The search field paints its own background and carries the magnifier inside
/// it, so the string has to start after the glyph. `NSTextField` has no text
/// inset of its own — the cell decides where the string draws, and it has to be
/// told the same number in three places. Miss `edit` or `select` and the
/// placeholder sits in one position while the caret and the selection land in
/// another, which looks like the field jumping when you click it.
@MainActor
final class InsetTextFieldCell: NSTextFieldCell {
    var leadingInset: CGFloat = 0
    /// Room for the clear button, reserved whether or not it is showing. Reserving
    /// it only while visible would shift every character sideways the moment you
    /// typed the first one.
    var trailingInset: CGFloat = 0

    /// Leading, not left: in an RTL layout the glyph is on the other side, so
    /// insetting `origin.x` would reserve the space away from the icon.
    private func inset(_ rect: NSRect) -> NSRect {
        guard leadingInset > 0 || trailingInset > 0 else { return rect }
        var result = rect
        result.size.width -= leadingInset + trailingInset
        if userInterfaceLayoutDirection != .rightToLeft {
            result.origin.x += leadingInset
        } else {
            result.origin.x += trailingInset
        }
        return result
    }

    /// Borderless AppKit text cells return the control's entire bounds as their
    /// drawing rect. In a 28pt search row that leaves a 14pt line sitting on the
    /// default baseline rather than optically centred. Use the cell's measured
    /// single-line height for drawing AND editing so the placeholder, caret and
    /// selection all occupy the same centred rect.
    private func textRect(forBounds rect: NSRect) -> NSRect {
        var result = inset(super.drawingRect(forBounds: rect))
        let lineHeight = min(result.height, ceil(cellSize(forBounds: rect).height))
        result.origin.y += floor((result.height - lineHeight) / 2)
        result.size.height = lineHeight
        return result
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        textRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor: NSText,
        delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: textRect(forBounds: rect), in: controlView, editor: editor,
            delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor: NSText,
        delegate: Any?, start: Int, length: Int
    ) {
        super.select(
            withFrame: textRect(forBounds: rect), in: controlView, editor: editor,
            delegate: delegate, start: start, length: length)
    }
}

final class AgentInboxView: NSView, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate, TokenThemed {
    /// Set to preview a redesigned card row in this real list. See
    /// `AgentInboxCardStyleOverride`; nil everywhere but the Component Lab.
    var cardStyleOverride: AgentInboxCardStyleOverride? = .production {
        didSet {
            rebuildRowsForQA()
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        }
    }

    /// Set to preview a redesigned header in this real sidebar. See
    /// `AgentInboxHeaderStyleOverride`; nil everywhere but the Component Lab.
    var headerStyleOverride: AgentInboxHeaderStyleOverride? = AgentInboxHeaderStyleOverride() {
        didSet { applyHeaderStyle() }
    }

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
    /// 36 pt — T3 nightly's `h-9` slim row (confidence pass, sidebar stream). It
    /// was the title's line height plus the row insets (~35 pt).
    static let slimRowHeight: Double = 36

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The `Snoozed (N)` heading's height: the same one line a parked row gets, so
    /// the shelf costs exactly what one of the rows it is holding would have. Derived
    /// from `slimRowHeight` rather than restated, so a P1.4 type move moves both.
    static var shelfHeaderHeight: Double { slimRowHeight }

    /// Whether the row's rollup summary is actually drawn in this disclosure
    /// state. A collapsed group shows the complete descendant summary; an
    /// expanded but capped group shows only attention from the omitted portion,
    /// so a blocked hidden child can still raise its visible parent without
    /// borrowing the parent's `attention` watermark.
    fileprivate static func drawsRollup(
        disclosure: RowDisclosure, rollup: ChildRollup?
    ) -> Bool {
        guard let rollup else { return false }
        return disclosure == .collapsed || rollup.cappedAttentionSummary != nil
    }

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
            let drawsRollup = Self.drawsRollup(disclosure: disclosure, rollup: rollup)
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

    // Ticket: .plans/0721-subagents-handoff.md
    /// The table's own vertical intercell spacing — room between two rows that
    /// belongs to NEITHER cell. Named because the tree connector has to cross it:
    /// a lane drawn only inside the cells is a dashed line with a \(Space.s)pt break
    /// at every row, and the whole point of the lane is that you can follow it.
    static let rowSpacing = Space.s

    /// The identity colour dot beside an agent's name (`AgentInboxRow.identityColor`),
    /// in both the card and the slim row. Small enough to sit inside the name's
    /// x-height; the name's own words stay the identity, the dot only pairs it with
    /// the tile.
    static let identityDotSide: CGFloat = 6
    /// The dot's alpha. A zone tint at full strength is louder than anything else
    /// in a resting row; this keeps the hue and drops the shout.
    static let identityDotAlpha: CGFloat = 0.8

    /// A palette name resolved the way a zone's is, then muted.
    static func identityDotColour(named name: String) -> NSColor {
        ZoneChromeNSView.color(named: name).withAlphaComponent(identityDotAlpha)
    }

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
    /// The leading magnifier, drawn only when a header override asks for field
    /// chrome. An `NSImageView` rather than another `TokenThemed` view: its tint
    /// is set from this view's `applyTokens`, which already owns the field's text
    /// colour, so the header adds no new owner to the token census.
    private let searchIcon = NSImageView(frame: .zero)
    /// Shown only while the field holds text, the way T3's does. A search you can
    /// see is a search you can get out of.
    private let searchClearButton = NSButton(frame: .zero)
    private var isSearchFieldHovered = false
    /// The one-row header queue 94 ships, and the stacked one program 96 is
    /// trying. Exactly one set is active at a time; `defaultHeader` is what
    /// production and every existing gate see.
    private var defaultHeaderConstraints: [NSLayoutConstraint] = []
    private var stackedHeaderConstraints: [NSLayoutConstraint] = []
    private var oneRowHeaderConstraints: [NSLayoutConstraint] = []
    /// The header's New agent button (one-row header only). The host wires it to
    /// the same spawn ⌘K's New Agent makes.
    private let newAgentButton = ChromeIconButton(symbolName: "square.and.pencil", accessibilityLabel: "New Agent")
    var onNewAgent: (() -> Void)?
    /// The square the New agent button occupies: T3's `size-7`.
    static let headerIconButtonSide: CGFloat = 28
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
    /// One cadence for the whole list. Cells never own timers; the single oldest
    /// eligible visible row borrows this phase when it is materialized.
    /// Re-reads the close nudge's five-minute threshold as time passes. It never
    /// hides the nudge: an on/off blink made it visible half the time.
    private var settleNudgeTimer: Timer?
    private static let settleNudgePeriod: TimeInterval = 30
    /// One clock for every materialized live duration and relative completion age.
    /// It ticks each second while work is running and only once a minute for a list
    /// of seen completions; cells never schedule work.
    private var elapsedTickTimer: Timer?
    private var elapsedTickInterval: TimeInterval?
    // P6.3: wake is derived from the stored date. This single timer only asks the
    // list/host to re-render when the earliest shelf entry may have expired; it
    // never writes the record or schedules a daemon wake.
    typealias WakeRerenderScheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private var wakeRerenderTimer: Timer?
    private var wakeRerenderCancellation: (() -> Void)?
    private var wakeScheduleGeneration = 0
    private var scheduledWakeDelay: TimeInterval?
    private(set) var qaWakeRerenderCount = 0
    private static let wakeTimerMinimumDelay: TimeInterval = 0.05
    private static let wakeTimerMaximumDelay: TimeInterval = 24 * 60 * 60
    /// Production uses `Timer` when this is nil. The injected scheduler is a
    /// bounded QA seam for the same callback, so timer expiry and clamping can be
    /// checked without sleeping or running a parallel timer implementation.
    var wakeRerenderScheduler: WakeRerenderScheduler?
    // Ticket: P5.1-custom-row-context-menu.md
    /// The tile's choice-family surface replaces stock AppKit row menus. Targets are
    /// retained by stable id while the panel is open so a push cannot retarget an action.
    private let rowChoiceController = ChoicePopoverController()
    private var rowChoiceTargetIds: [UUID] = []
    private var snoozeTargetIds: [UUID] = []
    // Headless checks retain the same ChoiceListView when no AppKit window exists.
    private var qaChoiceListForQA: ChoiceListView?
    private var qaSnoozeChoiceListForQA: ChoiceListView?
    private var qaIdentityColorChoiceListForQA: ChoiceListView?
    private var identityColorTargetIds: [UUID] = []
    private let projectFaviconResolver = ProjectFaviconResolver()
    /// Whether Generate Name is offered. Read once at init from the live-titling
    /// gate; building a menu never performs a lookup itself.
    private var nameGenerationCapabilityAvailable = false

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
    /// One agent's row as last handed over, whatever the scope or search hides —
    /// for a surface that has to say what the row says (the ⌥ jump badges).
    func row(forAgentId id: UUID) -> AgentInboxRow? { allRows.first { $0.id == id } }
    /// The entries in the popup, parallel to the menu items' tags.
    // Plan: .plans/86-workspace-filter/README.md
    /// The checklist as last built — what each row is, what its box shows, and what
    /// clicking it does (`InboxScopeMenu`).
    private var scopeMenuEntries: [InboxScopeMenuEntry] = []
    /// The workspace whose colour the popover is choosing, while it shows the
    /// palette instead of the scopes.
    private var colourEditingWorkspace: UUID?
    /// The workspace whose cards stay lit while its popover row is hovered.
    private(set) var peekWorkspace: UUID?
    /// Whether the list on screen spans more than one workspace, which is when its
    /// cards carry their workspace's edge mark.
    private var marksWorkspaces = false
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
    /// Why Delete is greyed, shown in the item's own title (see `setWorkspaceManagement`).
    private var workspaceDeleteDisabledReason: String?
    // Ticket: docs/38-tickets/90-agent-ux/P2D.4-parent-child-nesting.md
    /// The parents drawn folded right now, derived from `foldChoices` and the
    /// rollups on every display (`isFolded`). Never written anywhere else.
    private var collapsedParents: Set<UUID> = []
    /// What you last chose for each parent: true open, false folded. Nothing in
    /// the change set, nothing on the row; the host persists it on this Mac only
    /// (`onParentFoldChange`), because a synced fold would hide an agent on a
    /// device you were not looking at.
    ///
    /// Ids are kept even when their agent leaves the list (a scope change, a settle)
    /// so that coming back re-folds the group the way you left it.
    private var foldChoices: [UUID: Bool] = [:]
    private let foldMotion = InboxFoldMotion()
    var foldMotionForQA: InboxFoldMotion { foldMotion }
    /// Reports a fold or unfold by the person, with every choice made so far, so
    /// the host can remember them across launches. Not called by `restoreParentFolds`.
    var onParentFoldChange: (([UUID: Bool]) -> Void)?

    /// Put back the fold choices the host persisted.
    func restoreParentFolds(_ choices: [UUID: Bool]) {
        guard choices != foldChoices else { return }
        foldChoices = choices
        render(display(from: allRows))
    }

    /// Whether a parent is drawn folded: your own choice when you made one;
    /// otherwise folded, unless a child needs you or failed — a group you never
    /// touched must not bury an approval behind a default.
    private func isFolded(_ parentId: UUID) -> Bool {
        if let open = foldChoices[parentId] { return !open }
        guard foldsUntouchedGroups else { return false }
        guard let rollup = rollupsByParent[parentId] else { return true }
        return rollup.needsYou == 0 && rollup.failed == 0
    }
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P6.5-child-fanout-attention-rollup.md
    /// Parents whose remainder affordance has been opened. This is view-local
    /// presentation state: it changes how many children are inline, never the
    /// underlying rows or any resource bookkeeping.
    private var expandedFanoutParents: Set<UUID> = []
    /// The current deferred groups, derived from the full sorted row list. The
    /// remainder cell is a non-agent affordance, so it never enters `rows`,
    /// selection, jump indexes or lifecycle actions.
    private var fanoutRemaindersByParent: [UUID: FanoutRemainder] = [:]
    /// More than one nested remainder can follow the same final visible agent:
    /// the child owns one and its parent owns another. The value is therefore an
    /// ordered list, not a unique-key dictionary that traps during materialization.
    private var fanoutRemaindersByAfterRow: [UUID: [FanoutRemainder]] = [:]
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
    // Ticket: .plans/0721-subagents-handoff.md
    /// One `InboxNesting` per table row, in step with `items`. See `nestings(for:)`.
    private var nestingByTableRow: [InboxNesting] = []
    /// Whether the shelf is open. VIEW-LOCAL and COLLAPSED BY DEFAULT, exactly like
    /// `collapsedParents` and for the same reason the packet gives ("local UI state,
    /// not persisted per-agent"): whether you have the shelf open on this Mac right
    /// now is not a fact about an agent, and a persisted one would restore a fold
    /// over work that woke up while the app was closed.
    private var shelfExpanded = false
    // Ticket: .plans/05-close-to-history.md
    /// Whether History is open. VIEW-LOCAL and COLLAPSED BY DEFAULT for the same
    /// reasons as the shelf, and one more: History is the only section you go
    /// LOOKING for. Closed agents are the ones you have already decided you are
    /// done watching, so restoring an open History would hand every launch a list
    /// of everything you ever closed, above nothing you asked for.
    private var historyExpanded = false
    /// Reports a shelf being opened or closed by the person, so the host can
    /// remember it across launches. Not called by `restoreShelfExpansion`.
    var onShelfExpansionChange: ((WorkspaceSidebarConfig.Shelf, Bool) -> Void)?

    /// Put the shelves back the way they were left (the host's persisted state).
    func restoreShelfExpansion(snoozed: Bool, history: Bool) {
        guard (shelfExpanded, historyExpanded) != (snoozed, history) else { return }
        shelfExpanded = snoozed
        historyExpanded = history
        render(display(from: allRows))
    }

    /// Whether a group nobody has folded or opened starts FOLDED (launch polish,
    /// item Q). The app's sidebar turns it on (`AppDelegate.configureWorkspaceSidebar`);
    /// a bare view keeps P2D.4's open default, which the older fixture legs are
    /// written against — the same split, and the same open follow-up, as
    /// `foldsHistoryIntoShelf` below.
    var foldsUntouchedGroups = false {
        didSet {
            guard foldsUntouchedGroups != oldValue else { return }
            render(display(from: allRows))
        }
    }

    /// Whether History is a folded shelf and the shelves sink to the bottom (the
    /// confidence-pass layout). The app's sidebar turns it on
    /// (`AppDelegate.configureWorkspaceSidebar`); a bare view keeps the P4.8 inline
    /// tail, which the older fixture legs are written against. Migrating those
    /// legs and removing this switch is an open follow-up.
    var foldsHistoryIntoShelf = false {
        didSet {
            guard foldsHistoryIntoShelf != oldValue else { return }
            render(display(from: allRows))
        }
    }
    /// The flexible row that pushes the shelves to the bottom of the sidebar, so
    /// live work owns the top (T3's `mt-auto`). Recomputed after every render.
    private var shelfSpacerHeight: CGFloat = 0
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
    /// The History heading's cell (.plans/05-close-to-history.md). Cached
    /// separately from the shelf's: both headings can be on screen at once.
    private var historyHeaderCell: AgentInboxShelfHeaderView?
    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// The settled tail's footer, kept out of `cellsByRow` for the same reason the
    /// heading is. At most one exists — the tail is one section.
    private var settledMoreCell: AgentInboxSettledMoreView?
    /// The viewport height the spacer was last sized against; a resize re-sizes it.
    private var lastSpacerViewportHeight: CGFloat?
    private var fanoutRemainderCellsByParent: [UUID: AgentInboxRemainderView] = [:]
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
    var clock: () -> Date = { AgentElapsedClock.now() }

    // Ticket: docs/38-tickets/90-agent-ux/P4.12-crossfade-in-place.md
    /// Whether the person has asked for less movement. A closure for the reason
    /// `clock` is one: the answer is a live system setting, and a check has to be
    /// able to drive BOTH branches — a crossfade is exactly the kind of thing
    /// Reduce Motion turns off, and a fallback nothing can exercise is a fallback
    /// nobody knows is broken.
    var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P6.6-accessibility-motion-sweep.md
    /// Increase Contrast is read at the production decision point, not copied into
    /// a check as a second rendering mode. The geometry probe replaces this closure
    /// to drive both settings deterministically while the shipped view reads the
    /// user's actual display preference.
    var prefersIncreasedContrast: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    // The status owner is the only live announcement source in this subtree. A
    // test may observe the same production dispatch without relying on the global
    // accessibility server; nil uses the real NSAccessibility notification path.
    var accessibilityAnnouncementSink: ((NSView, String) -> Void)?
    /// QA-only recording of announcements into `qaStatusAnnouncements`. OFF in
    /// production: an inbox lives as long as the app, a busy workspace
    /// transitions status constantly, and each recorded entry retains an NSView —
    /// unbounded history that nothing outside a probe ever reads. A probe that
    /// wants the recording turns this on next to installing its sink.
    var qaRecordsStatusAnnouncements = false
    private var accessibilityStatusByAgent: [UUID: String] = [:]
    /// Offscreen rows have no materialized status label to post from. These
    /// dedicated announcement targets carry no row facts and are never inserted
    /// into the AX tree; they only keep a boundary-level transition from waiting
    /// for a recycled cell to appear.
    private var accessibilityStatusAnnouncementOwners: [UUID: AgentInboxStatusAnnouncementOwner] = [:]
    private(set) var qaStatusAnnouncements: [(owner: NSView, message: String)] = []

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
    // Plan: .plans/79-session-handoff/README.md
    /// A session from another app: a click watches it, its hover buttons move or
    /// copy it. The id is the row's.
    var onExternalSessionAction: ((InboxExternalSessionAction, UUID) -> Void)?
    /// The host lists sessions from other apps, so the scope menu offers
    /// "This Mac" (`InboxScope.thisMac`).
    var offersThisMacScope = false {
        didSet { if offersThisMacScope != oldValue { updateScopeMenu() } }
    }
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
    /// Snooze owns a second choice: the preset dates are resolved when this
    /// submenu opens, then the selected absolute wake reaches the host. Keeping
    /// it separate from `onRowAction` prevents a row action from silently
    /// defaulting to a stale or recomputed preset.
    var onSnoozeSelection: (([UUID], Date) -> Void)?
    /// The row menu's Color pick: the agents, and the zone-palette name (nil for
    /// None). The host writes it to each record.
    var onIdentityColorSelection: (([UUID], String?) -> Void)?
    /// Called when the derived wake timer expires so the host can rebuild rows
    /// from raw records. A headless view with no host callback falls back to its
    /// own render, which keeps the timer seam observable without inventing a
    /// second production data source.
    var onWakeRerender: (() -> Void)?
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
    /// Each workspace's colour (`WorkspaceEntry.resolvedColour`), from the host's
    /// registry. A change repaints the dots and the cards' edge marks.
    var workspaceColourNames: [UUID: String] = [:] {
        didSet {
            guard workspaceColourNames != oldValue else { return }
            updateScopeMenu()
            if marksWorkspaces { reload(rows: allRows) }
        }
    }
    /// A colour was chosen for a workspace from its `…`. The registry is the
    /// host's; the new colour arrives back through `workspaceColourNames`.
    var onWorkspaceColourChange: ((UUID, String) -> Void)?
    /// The workspace on screen, from the host — what `.currentWorkspace` (the
    /// default scope) resolves to. A change re-filters: a workspace switch moves
    /// the list with it.
    var currentWorkspaceName: String? {
        didSet {
            // The host sets ID then name. Once an ID is available, only the ID
            // drives filtering; the name is menu presentation and must not make
            // a workspace switch rebuild the list twice.
            guard currentWorkspaceId == nil, currentWorkspaceName != oldValue else { return }
            reload(rows: allRows)
        }
    }
    var currentWorkspaceId: UUID? {
        didSet {
            guard currentWorkspaceId != oldValue else { return }
            reload(rows: allRows)
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
        scopeButton.setAccessibilityLabel("Agent scope")
        searchField = NSTextField(frame: .zero)
        // Before any other configuration: the field forwards isEditable, the font
        // and the placeholder to its cell, so a cell swapped in afterwards would
        // arrive blank.
        searchField.cell = InsetTextFieldCell()
        // A programmatically created cell arrives carrying AppKit's default title,
        // and for a text cell that title is the literal string `Field`. It shipped
        // to the preview looking like a deliberate placeholder: it never filters,
        // because `controlTextDidChange` fires on edits and not on a value the
        // field was born with, and the real placeholder stays hidden the whole time
        // because a non-empty `stringValue` outranks it.
        searchField.stringValue = ""
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .token(.label)
        searchField.placeholderString = Self.searchPlaceholder
        searchField.setAccessibilityElement(true)
        searchField.setAccessibilityRole(.textField)
        searchField.setAccessibilityLabel("Search agents")
        searchField.setAccessibilityHelp("Filters agents by name, project, workspace, model, or branch")

        scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // The scroll container is navigation chrome, not a second list in the
        // accessibility tree. The table below owns the agent hierarchy.
        scrollView.setAccessibilityElement(false)

        tableView = AgentInboxTableView(frame: .zero)
        tableView.headerView = nil
        // `.plain`, not the sidebar's `.sourceList`: a source list draws its own
        // rounded selection capsule and its own row insets, which would sit
        // underneath the card this view paints and give every selected row two
        // overlapping shapes. Selection is drawn by `AgentInboxRowView` instead,
        // from tokens.
        tableView.style = .plain
        tableView.rowHeight = AgentInboxView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: AgentInboxView.rowSpacing)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.list)
        tableView.setAccessibilityLabel("Agents")
        tableView.setAccessibilityHelp("Agent inbox rows")
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
        emptyLabel.setAccessibilityElement(true)
        emptyLabel.setAccessibilityRole(.staticText)
        emptyLabel.setAccessibilityLabel("Agent inbox status")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent inbox")
        setAccessibilityHelp("Managed agent activity and actions")

        // Process-free: titling resolves per agent from file stats, so the only
        // app-wide fact is whether live titling is on.
        nameGenerationCapabilityAvailable = AgentSupervisor.nameGenerationCapabilityAvailable

        wantsLayer = true
        applyTokens()
        setAccessibilityIdentifier("ContinuumAgentInboxRoot")
        tableView.setAccessibilityIdentifier("ContinuumAgentInboxList")
        emptyLabel.setAccessibilityIdentifier("ContinuumAgentInboxEmpty")
        scopeButton.setAccessibilityIdentifier("ContinuumAgentInboxScope")
        searchField.setAccessibilityIdentifier("ContinuumAgentInboxSearch")
        scopeButton.setAccessibilityHelp("Opens the agent scope choices")

        addSubview(scopeButton)
        addSubview(searchField)
        newAgentButton.translatesAutoresizingMaskIntoConstraints = false
        newAgentButton.target = self
        newAgentButton.action = #selector(newAgentPressed)
        newAgentButton.toolTip = "New Agent"
        newAgentButton.setAccessibilityIdentifier("ContinuumAgentInboxNewAgent")
        addSubview(newAgentButton)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.isHidden = true
        // Decoration: the click belongs to the field behind it, or the caret would
        // refuse to land whenever you aimed at the icon.
        searchIcon.setAccessibilityElement(false)
        addSubview(searchIcon)
        searchClearButton.translatesAutoresizingMaskIntoConstraints = false
        searchClearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        searchClearButton.imagePosition = .imageOnly
        searchClearButton.isBordered = false
        searchClearButton.bezelStyle = .inline
        searchClearButton.isHidden = true
        searchClearButton.target = self
        searchClearButton.action = #selector(clearSearch)
        searchClearButton.setAccessibilityLabel("Clear search")
        addSubview(searchClearButton)
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
        // The trigger's label is always the scope's own title (`applyScopeTrigger`),
        // so no row the checklist reports may replace it.
        scopeButton.keepsSelectionForItem = { _ in true }
        scopeButton.popoverPresentation = .checklist
        scopeButton.onSelection = { [weak self] item in self?.choicePicked(item) }
        scopeButton.onAccessory = { [weak self] item, accessory in self?.scopeAccessoryPressed(item, accessory) }
        scopeButton.onFocusChange = { [weak self] id in self?.scopeFocusChanged(id) }
        scopeButton.onPopoverDismiss = { [weak self] in
            self?.colourEditingWorkspace = nil
            self?.hiddenListShown = false
            self?.focusedScopeItemID = nil
            self?.setPeek(nil)
        }
        updateScopeMenu()
        // P3.11: the bar reports the action; resolving WHICH agents it lands on is the
        // list's, because only the list knows the selection.
        bulkBar.onAction = { [weak self] action in self?.performBulkAction(action) }
        bulkBar.setAccessibilityIdentifier("ContinuumAgentInboxBulkBar")
        // P4.11: the toast reports the press; what it puts back is the list's, because
        // only the list holds what was captured at dispatch.
        undoToast.onUndo = { [weak self] in self?.performUndo() }
        undoToast.setAccessibilityIdentifier("ContinuumAgentInboxUndoToast")

        // The shipped one-row header: scope on the left at a fixed 124pt, search
        // sharing the row to its right. Held in a stored set rather than activated
        // inline so a header override can swap it without touching production's
        // numbers — see `AgentInboxHeaderStyleOverride`.
        defaultHeaderConstraints = [
            scopeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.m),
            scopeButton.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),
            scopeButton.widthAnchor.constraint(equalToConstant: 124),
            scopeButton.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            searchField.leadingAnchor.constraint(equalTo: scopeButton.trailingAnchor, constant: Space.s),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.m),
            searchField.centerYAnchor.constraint(equalTo: scopeButton.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            scrollView.topAnchor.constraint(equalTo: scopeButton.bottomAnchor, constant: Space.s),
        ]

        // Program 96's stacked header: search owns the top row at full width, the
        // scope control sits under it at its own intrinsic width. Costs one extra
        // control height plus a gap — about a third of an agent row — which is the
        // trade the S0 density ruling has to weigh.
        stackedHeaderConstraints = [
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.m),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.m),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),
            searchField.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            scopeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.m),
            scopeButton.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Space.s),
            scopeButton.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            scrollView.topAnchor.constraint(equalTo: scopeButton.bottomAnchor, constant: Space.s),
        ]
        // T3 nightly's one row: [search ………][scope][+]. The scope control sizes
        // to its title and search takes the rest, down to the room its glyph and a
        // one-word placeholder need; only below that does the scope label yield.
        // Capping the scope instead (104pt, or 30% of the sidebar) ellipsized
        // "This workspace" beside a search field that was mostly empty.
        let searchFloor = searchField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.searchFieldFloorWidth)
        // Both stay under `defaultLow`: nothing in this row may outrank the
        // sidebar's own width, or the row widens the pane at 220pt instead of
        // yielding. The floor only has to beat the scope's compression.
        searchFloor.priority = Self.searchFloorPriority
        oneRowHeaderConstraints = [
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.m),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: Space.s),
            searchField.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            scopeButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: Space.s),
            scopeButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            scopeButton.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            searchFloor,
            newAgentButton.leadingAnchor.constraint(equalTo: scopeButton.trailingAnchor, constant: Space.xs),
            newAgentButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.m),
            newAgentButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            newAgentButton.widthAnchor.constraint(equalToConstant: Self.headerIconButtonSide),
            newAgentButton.heightAnchor.constraint(equalToConstant: Self.headerIconButtonSide),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Space.s),
        ]
        NSLayoutConstraint.activate(defaultHeaderConstraints)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: CGFloat(Space.s)),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: Self.searchIconSide),
            searchIcon.heightAnchor.constraint(equalToConstant: Self.searchIconSide),

            searchClearButton.trailingAnchor.constraint(
                equalTo: searchField.trailingAnchor, constant: -CGFloat(Space.s)),
            searchClearButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchClearButton.widthAnchor.constraint(equalToConstant: Self.searchIconSide),
            searchClearButton.heightAnchor.constraint(equalToConstant: Self.searchIconSide),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
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

        // Property observers do not run for a property's declaration-time value.
        // Production is born with the 96 header override already installed, so
        // without this call the magnifier becomes visible when tokens apply while
        // the field keeps the legacy one-row constraints and a zero text inset.
        // The result is the exact overlap this style exists to prevent.
        applyHeaderStyle()
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
        foldMotion.cancel()
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        emptyLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        searchField.textColor = TextToken.textPrimary.color.nsColor(in: self)
        applySearchFieldChrome()
    }

    /// Paint the search field: a magnifier, and NOTHING at rest.
    ///
    /// The first version of this gave the field a filled, rounded, outlined box to
    /// match `ChoiceButton`. It was wrong twice over. The outline was a bug — see
    /// `isSearchFieldEditing` — and even without it, the box was more chrome than a
    /// search field in a sidebar has earned. T3, the reference this header is
    /// modelled on, draws no border and no resting fill either: the input is
    /// `unstyled` and the row it sits in only takes a fill on hover.
    ///
    /// So: glyph plus text at rest, a hover fill to say it is a target, and the
    /// focus hairline only while a caret is actually in it.
    ///
    /// Painted from HERE rather than from a new view class. This view already owns
    /// the field's text colour, so borrowing its layer adds no owner to the token
    /// census (hazard 8) and no surface for the appearance sweep to hunt.
    private func applySearchFieldChrome() {
        guard headerStyleOverride?.fieldChrome == true else {
            searchField.layer?.backgroundColor = nil
            searchField.layer?.borderWidth = 0
            searchIcon.isHidden = true
            searchClearButton.isHidden = true
            return
        }
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = CGFloat(Radius.card)
        // Resting paints NOTHING, not a transparent colour: a painted `.clear` is an
        // unregistered literal as far as the appearance census is concerned.
        searchField.layer?.backgroundColor = isSearchFieldHovered
            ? AgentSurfaceRole.rowHover.color.cgColor(in: self)
            : nil
        let editing = isSearchFieldEditing
        searchField.layer?.borderWidth = editing ? ChoiceButton.focusBorderWidth : 0
        searchField.layer?.borderColor = AgentLineRole.focusRing.color.cgColor(in: self)
        searchIcon.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        searchIcon.isHidden = false
        searchClearButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        searchClearButton.isHidden = searchField.stringValue.isEmpty
    }

    /// Whether a caret is genuinely in the search field.
    ///
    /// NOT `window?.firstResponder === searchField.currentEditor()`. An unfocused
    /// field has no field editor, so that expression compares nil to nil — which is
    /// `true` — and during `init` there is no window either, so the border was
    /// painted at construction and never cleared. The outline in the first preview
    /// was not a focus ring; it was this.
    private var isSearchFieldEditing: Bool {
        guard let editor = searchField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// The magnifier's box. Bigger than `ChoiceButton`'s 12pt chevron because a
    /// chevron is a hint attached to a word and this glyph has to carry the field's
    /// whole identity at rest.
    private static let searchIconSide: CGFloat = 14

    /// The search field's two reserved edges (the glyph, the clear button).
    private static var searchFieldChromeWidth: CGFloat { (searchIconSide + CGFloat(Space.s) * 3) * 2 }
    static let searchPlaceholder = "Search agents"
    private static let oneRowScopeCompressionPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 10)
    private static let searchFloorPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 5)
    static let shortSearchPlaceholder = "Search"
    /// The narrowest the one-row search field gets before the scope label yields:
    /// both reserved edges and the one-word placeholder, drawn whole.
    static var searchFieldFloorWidth: CGFloat {
        searchFieldChromeWidth
            + ChoiceLabelMetrics.labelWidth(for: shortSearchPlaceholder, font: .token(.label))
    }
    private static let searchPlaceholderWidth = ChoiceLabelMetrics.labelWidth(
        for: searchPlaceholder, font: .token(.label))

    /// The placeholder the field can draw whole: the full one, or "Search" once
    /// the scope label has taken the room. The glyph already says what it is.
    private func fitSearchPlaceholder() {
        let room = searchField.bounds.width
            - ((searchField.cell as? InsetTextFieldCell).map { $0.leadingInset + $0.trailingInset } ?? 0)
        let placeholder = room + 0.5 >= Self.searchPlaceholderWidth ? Self.searchPlaceholder : Self.shortSearchPlaceholder
        if searchField.placeholderString != placeholder { searchField.placeholderString = placeholder }
    }

    private func applyHeaderStyle() {
        let oneRow = headerStyleOverride?.oneRow == true
        let stacked = !oneRow && headerStyleOverride?.stacked == true
        let chosen = oneRow ? oneRowHeaderConstraints
            : stacked ? stackedHeaderConstraints : defaultHeaderConstraints
        NSLayoutConstraint.deactivate(
            defaultHeaderConstraints + stackedHeaderConstraints + oneRowHeaderConstraints)
        NSLayoutConstraint.activate(chosen)
        newAgentButton.isHidden = !oneRow
        // In one row the scope control holds its title against everything but
        // the search field's floor: below that its label truncates, rather than
        // the row forcing the sidebar wider than it is.
        scopeButton.setContentCompressionResistancePriority(
            oneRow ? Self.oneRowScopeCompressionPriority : .required, for: .horizontal)
        scopeButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The glyph steals the field's leading edge, so the text has to start
        // after it — otherwise the placeholder sits underneath the magnifier.
        let chrome = headerStyleOverride?.fieldChrome == true
        let cell = searchField.cell as? InsetTextFieldCell
        // One `s` places the control, one spans its nominal box, and one remains
        // as breathing room before the text. Two gaps only clear the symbol's
        // FRAME by ~1.5pt because NSTextField's alignment rect adds its own inset.
        cell?.leadingInset = chrome ? Self.searchIconSide + CGFloat(Space.s) * 3 : 0
        cell?.trailingInset = chrome ? Self.searchIconSide + CGFloat(Space.s) * 3 : 0
        applyTokens()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// The root owns the fixed band/list hierarchy. Hidden overlays are omitted
    /// rather than left as disabled AX children, so a filtered or collapsed list
    /// never advertises an action the user cannot reach.
    private func updateAccessibilityHierarchy() {
        let count = rows.count
        setAccessibilityValue(count == 1 ? "1 agent" : "\(count) agents")
        tableView.setAccessibilityValue(count == 1 ? "1 agent" : "\(count) agents")
        emptyLabel.setAccessibilityValue(emptyLabel.stringValue)
        var children: [NSView] = [scopeButton, searchField, tableView]
        if !emptyLabel.isHidden { children.append(emptyLabel) }
        if !bulkBar.isHidden { children.append(bulkBar) }
        if !undoToast.isHidden { children.append(undoToast) }
        setAccessibilityChildren(children)

        // NSTableView owns its virtual accessibility children. Do not replace
        // that answer with the cells AppKit has happened to materialize: the
        // native list provider is what keeps offscreen rows reachable while a
        // person scrolls.
    }

    /// The status owner is the only announcement source. A changed elapsed value
    /// deliberately does not enter this snapshot, so re-rendering a ticking row
    /// can update its aggregate label without posting a second live-region event.
    private func statusAccessibilitySummary(for row: AgentInboxRow) -> String {
        if row.isUnconfirmed {
            let lastKnown = row.label ?? "Ready"
            return "Unconfirmed: no live agent snapshot; last known status \(lastKnown)"
        }
        return row.presentationLabel ?? "Ready"
    }

    /// Compare status at the row-model boundary, before cell materialization. The
    /// initial snapshot is silent; a removed id is pruned immediately, so a later
    /// reintroduction starts a fresh observation rather than announcing stale disk
    /// state. Elapsed is deliberately absent from this key.
    private func updateStatusSnapshots(for newRows: [AgentInboxRow]) {
        let ids = Set(newRows.map(\.id))
        accessibilityStatusByAgent = accessibilityStatusByAgent.filter { ids.contains($0.key) }
        accessibilityStatusAnnouncementOwners = accessibilityStatusAnnouncementOwners.filter {
            ids.contains($0.key)
        }

        for row in newRows {
            // Compare the spoken semantic status, not elapsed or other row facts.
            // This also catches a ready→woke attention transition without making
            // the status owner depend on the ticking duration.
            let current = statusAccessibilitySummary(for: row)
            guard let previous = accessibilityStatusByAgent[row.id] else {
                accessibilityStatusByAgent[row.id] = current
                continue
            }
            guard previous != current else { continue }

            let owner: NSView
            if let cell = cellsByRow.values.first(where: { $0.qaAgentID == row.id }) {
                owner = cell.accessibilityStatusOwner
            } else {
                let announcementOwner = accessibilityStatusAnnouncementOwners[row.id]
                    ?? AgentInboxStatusAnnouncementOwner(frame: .zero)
                announcementOwner.apply(summary: statusAccessibilitySummary(for: row))
                accessibilityStatusAnnouncementOwners[row.id] = announcementOwner
                owner = announcementOwner
            }
            let summary = statusAccessibilitySummary(for: row)
            owner.setAccessibilityRole(owner.accessibilityRole() ?? .staticText)
            owner.setAccessibilityLabel("Status: \(summary)")
            owner.setAccessibilityValue(summary)
            let message = "\(row.displayTitle): \(summary)"
            if qaRecordsStatusAnnouncements {
                qaStatusAnnouncements.append((owner: owner, message: message))
            }
            if let accessibilityAnnouncementSink {
                accessibilityAnnouncementSink(owner, message)
            } else {
                NSAccessibility.post(
                    element: owner,
                    notification: .announcementRequested,
                    userInfo: [.announcement: message])
            }
            accessibilityStatusByAgent[row.id] = current
        }
    }

    /// Re-apply the current display preferences to already materialized cells.
    /// The workspace notification calls this in production; QA uses the same seam
    /// after replacing either preference closure.
    private func reapplyDisplayPreferences() {
        foldMotion.cancel()
        let increasedContrast = prefersIncreasedContrast()
        for cell in cellsByRow.values { cell.setIncreasedContrast(increasedContrast) }
        for card in deckCells.allObjects { card.snapDeck() }
    }

    func reapplyDisplayPreferencesForQA() {
        reapplyDisplayPreferences()
    }

    /// Re-ask every table row for its height when the sidebar divider changes the
    /// width available to the cell. `AgentInboxCellView.layout()` re-tiers the
    /// labels, but AppKit's row-height cache does not observe that cell-local
    /// change; without this invalidation a row can keep the old one-/two-line
    /// height until its content changes for an unrelated reason.
    override func layout() {
        defer { syncElapsedTickTimer() }
        let columnWidthAtLayoutEntry = column.width
        super.layout()
        fitSearchPlaceholder()
        let viewportHeight = scrollView.contentView.bounds.height
        if lastSpacerViewportHeight != viewportHeight {
            lastSpacerViewportHeight = viewportHeight
            updateShelfSpacerHeight()
        }
        // `NSScrollView` owns the document view's frame, but does not grow a
        // previously narrowed table back to the new clip width by itself. The
        // sidebar has no horizontal scrolling, so the table's document lane is
        // always exactly the viewport lane before heights are re-asked.
        let viewportWidth = qaViewportWidthOverride ?? scrollView.contentView.bounds.width
        if viewportWidth > 0,
           tableView.frame.width != viewportWidth || column.width != viewportWidth {
            foldMotion.cancel()
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
        defer { syncElapsedTickTimer() }
        // P6.6: status transitions belong to this row-model boundary, not to
        // `viewFor`, so offscreen rows announce on the push that changed them.
        updateStatusSnapshots(for: newRows)
        // P4.10: read BEFORE the render, which empties the table's selection — the
        // advance is validated against the selection the person had when this push
        // arrived, and by the time `render` returns nobody can tell what that was.
        let selectionOnEntry = selectedRows.map(\.id)
        allRows = newRows
        externalSessionHiding?.noteDiscovered(Set(newRows.compactMap(\.externalSession?.sessionKey)))
        updateScopeMenu()
        render(display(from: newRows))
        completePendingAdvance(selectionOnEntry: selectionOnEntry)
    }

    /// Keep one bounded re-render timer for the earliest derived wake. The view's
    /// `clock()` remains the rendering clock; scheduling uses the real wall clock so
    /// a shelf cannot linger for the rest of an injected minute in production.
    private func scheduleWakeRerender() {
        cancelWakeRerender()
        let now = clock()
        let earliest = allRows.compactMap { row -> Date? in
            guard case .snoozed(let until) = row.lifecycle, until > now else { return nil }
            return until
        }.min()
        guard let earliest else { return }
        let delay = min(
            Self.wakeTimerMaximumDelay,
            max(Self.wakeTimerMinimumDelay, earliest.timeIntervalSince(now) + 0.01))
        let generation = wakeScheduleGeneration
        scheduledWakeDelay = delay
        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            self.wakeRerenderFired(generation: generation)
        }
        if let wakeRerenderScheduler {
            wakeRerenderCancellation = wakeRerenderScheduler(delay, fire)
        } else {
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in fire() }
            wakeRerenderTimer = timer
            wakeRerenderCancellation = { timer.invalidate() }
        }
    }

    private func cancelWakeRerender() {
        wakeScheduleGeneration &+= 1
        wakeRerenderCancellation?()
        wakeRerenderCancellation = nil
        wakeRerenderTimer?.invalidate()
        wakeRerenderTimer = nil
        scheduledWakeDelay = nil
    }

    private func wakeRerenderFired(generation: Int) {
        guard generation == wakeScheduleGeneration else { return }
        // Treat the fired registration like any other completed schedule before
        // asking the list to render. This makes the one-timer invariant explicit:
        // an injected scheduler can release its handle, and a subsequent reload
        // can cancel/reschedule the next earliest wake without retaining the old one.
        wakeRerenderCancellation?()
        wakeRerenderCancellation = nil
        wakeRerenderTimer?.invalidate()
        wakeRerenderTimer = nil
        scheduledWakeDelay = nil
        qaWakeRerenderCount += 1
        if let onWakeRerender {
            onWakeRerender()
        } else {
            // This fallback is only for a view without its host; the shipped app
            // supplies `onWakeRerender` so raw records are re-derived at expiry.
            reload(rows: allRows)
        }
    }

    /// Draw this list whole. Takes rows that are ALREADY filtered and sorted, which
    /// is why it is private: `reload(rows:)` is the entry point for a fresh push and
    /// takes the unfiltered set, and handing it an already-filtered list would make
    /// the scope narrow itself with every call.
    private func render(_ visible: [InboxListItem], animateRows: Bool = true) {
        foldMotion.cancel()
        // Row motion (confidence pass): rows that leave fade out from where they
        // were, rows that arrive fade in — 150ms, skipped above 40 rows and under
        // Reduce Motion. A closed tile's row visibly leaving IS the confirmation.
        let previousIds = Set(rows.map(\.id))
        let nextIds = Set(visible.compactMap { $0.agentRow?.id })
        let animatesRows = animateRows && !previousIds.isEmpty && previousIds != nextIds
            && visible.count <= Self.rowMotionRowLimit && !prefersReducedMotion()
        let exitGhosts = animatesRows ? liftExitGhosts(leaving: previousIds.subtracting(nextIds)) : []
        defer {
            if animatesRows { startRowMotion(exits: exitGhosts, entering: nextIds.subtracting(previousIds)) }
        }
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
        historyHeaderCell = nil
        settledMoreCell = nil
        fanoutRemainderCellsByParent.removeAll()
        updateShelfSpacerHeight()
        tableView.reloadData()
        updateEmptyState()
        // P3.11: `reloadData` empties the table's selection, so the bar has to come
        // down with it — a bar left up over an empty selection offers actions with
        // nothing to apply them to.
        selectedRowsForEmphasis = IndexSet()
        updateBulkBar()
        updateAccessibilityHierarchy()
        // P1.2: the list under the pointer just changed, so hover is re-derived
        // from the pointer rather than carried over or dropped. This is the row
        // REUSE half of "no row is left lit": `reloadData` rebuilt every cell,
        // and the agent under the mouse may now be a different one.
        refreshHoverFromPointer()
        scheduleWakeRerender()
        if peekWorkspace != nil { applyPeek(animated: false) }
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
        if foldMotion.isAnimating {
            let byId = newRows.reduce(into: [UUID: AgentInboxRow]()) { $0[$1.id] = $1 }
            let sameGeometry = rows.allSatisfy { previous in
                guard let next = byId[previous.id] else { return false }
                if previous == next { return true }
                guard previous.variant == .card, next.variant == .card,
                      let style = cardStyleOverride else { return false }
                return style.cardHeight(previous) == style.cardHeight(next)
            }
            if !sameGeometry || prefersReducedMotion() { foldMotion.cancel() }
        }
        defer { syncElapsedTickTimer() }
        // P6.6: compare/prune before the incremental/full list branch. Cell
        // materialization is a rendering detail and must not decide whether a
        // semantic transition was announced.
        updateStatusSnapshots(for: newRows)
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
        if foldMotion.isAnimating {
            let keys = Set(foldMotion.poses.keys)
            foldMotion.cover(items.indices.compactMap { index in
                guard keys.contains(items[index].identity) else { return nil }
                return tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            })
        }
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
        externalSessionHiding?.noteDiscovered(Set(newRows.compactMap(\.externalSession?.sessionKey)))
        updateScopeMenu()
        scheduleWakeRerender()
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
        updateShelfSpacerHeight()
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
        let hiddenKeys = externalSessionHiding?.hiddenKeys ?? []
        let unhidden = hiddenKeys.isEmpty ? newRows : newRows.filter { row in
            row.externalSession.map { !hiddenKeys.contains($0.sessionKey) } ?? true
        }
        let scoped = InboxScope.filter(
            rows: unhidden, scope: effectiveScope, openAgentId: openAgentId,
            currentWorkspace: currentWorkspaceName,
            currentWorkspaceId: currentWorkspaceId)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let searched = query.isEmpty ? scoped : scoped.filter { row in
            [row.title, row.projectName, row.workspaceName, row.model, row.branch, row.whereMarker?.text]
                .compactMap { $0?.localizedLowercase }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let sorted = InboxSort.sortForInbox(rows: searched)
        marksWorkspaces = Set(sorted.compactMap(\.workspaceId)).count > 1
        // P2D.4/P2D.5 must read the FULL sorted list. Capping or folding before
        // these derivations would make a hidden child's disclosure, rollup and
        // lifecycle blocker disappear together.
        parentsWithChildren = InboxSort.parentIds(in: sorted)
        var fullRollups = InboxSort.rollups(in: sorted)
        let bounded = InboxSort.boundedForInbox(
            rows: sorted, expandedParents: expandedFanoutParents)
        fanoutRemaindersByParent = bounded.remainderByParent
        // The capped fields are a presentation-only overlay on the full rollup.
        // `holdsParentOpen` and the lifecycle/action policy continue to read the
        // uncapped descendant tallies above, so a remainder cannot change resource
        // or settlement bookkeeping.
        for remainder in bounded.remainders {
            guard var rollup = fullRollups[remainder.parentId] else { continue }
            let hidden = remainder.hiddenDescendantCount
            rollup = ChildRollup(
                children: rollup.children,
                working: rollup.working,
                needsYou: rollup.needsYou,
                failed: rollup.failed,
                cappedChildren: remainder.hiddenChildCount,
                cappedDescendants: hidden,
                cappedWorking: remainder.hiddenWorking,
                cappedNeedsYou: remainder.hiddenNeedsYou,
                cappedFailed: remainder.hiddenFailed)
            fullRollups[remainder.parentId] = rollup
        }
        rollupsByParent = fullRollups
        collapsedParents = Set(parentsWithChildren.filter(isFolded))
        let visible = InboxSort.visibleRows(bounded.rows, collapsed: collapsedParents)
        let visibleIDs = Set(visible.map(\.id))
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
        fanoutRemaindersByAfterRow = visibleRemaindersByAfterRow
        // P4.7. `clock()` and not `Date()`: the same injection point a parked row's
        // "in 25m" is read from, so a card whose snooze expires between two renders
        // cannot make a committed baseline flap.
        let parts = InboxSort.partition(rows: visible, now: clock())
        var built = agentItems(for: parts.active)
        // NO HEADER FOR AN EMPTY SHELF: "Snoozed (0)" is a line of chrome about
        // nothing, and it would take a row's worth of a 320pt sidebar to say it.
        if parts.shelfCount > 0 {
            built.append(.shelfHeader(count: parts.shelfCount, isExpanded: shelfExpanded))
            if shelfExpanded {
                built.append(contentsOf: agentItems(for: parts.snoozed))
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
        if !foldsHistoryIntoShelf {
            let page = InboxSort.pageSettled(
                parts.history, limit: settledLimit, openAgentId: openAgentId)
            built.append(contentsOf: agentItems(for: page.shown))
            if page.hasMore {
                built.append(.settledMore(hidden: page.hidden))
            }
        } else if parts.historyCount > 0 {
            built.append(.historyHeader(count: parts.historyCount, isExpanded: historyExpanded))
            if historyExpanded {
                let page = InboxSort.pageSettled(
                    parts.history, limit: settledLimit, openAgentId: openAgentId)
                built.append(contentsOf: agentItems(for: page.shown))
                if page.hasMore {
                    built.append(.settledMore(hidden: page.hidden))
                }
            } else if let open = parts.history.first(where: { $0.id == openAgentId }) {
                built.append(.agent(open))
            }
        }
        if foldsHistoryIntoShelf, let firstShelf = built.firstIndex(where: \.isShelfHeading) {
            built.insert(.shelfSpacer, at: firstShelf)
        }
        return built
    }

    /// Turn a section's agent rows into table items, inserting each remainder
    /// after the visible end of its live parent's subtree. `display(from:)`
    /// already excludes a folded parent and re-anchors an ancestor's remainder
    /// when a nested fold removes the model's original anchor.
    private func agentItems(for sectionRows: [AgentInboxRow]) -> [InboxListItem] {
        var result: [InboxListItem] = []
        for row in sectionRows {
            result.append(.agent(row))
            guard let remainders = fanoutRemaindersByAfterRow[row.id] else { continue }
            result.append(contentsOf: remainders.map(InboxListItem.fanoutRemainder))
        }
        return result
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
        onShelfExpansionChange?(.snoozed, shelfExpanded)
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

    /// Size the spacer row so the shelves meet the bottom of the visible list, or
    /// collapse it to nothing once the content is taller than the viewport.
    private func updateShelfSpacerHeight() {
        guard let spacerRow = items.firstIndex(where: { if case .shelfSpacer = $0 { return true } else { return false } }) else {
            shelfSpacerHeight = 0
            return
        }
        let visible = tableView.enclosingScrollView?.contentView.bounds.height ?? bounds.height
        let gap = tableView.intercellSpacing.height
        var others: CGFloat = 0
        for row in items.indices where row != spacerRow {
            others += tableView(tableView, heightOfRow: row) + gap
        }
        let next = max(0, floor(visible - others - gap))
        guard abs(next - shelfSpacerHeight) > 0.5 else { return }
        shelfSpacerHeight = next
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: spacerRow))
    }

    // MARK: - History (.plans/05-close-to-history.md)

    /// Open or close History. A full re-render with selection and hover dropped,
    /// for the reason `toggleShelf` records: rows appear, so every index the old
    /// list handed out now names a different agent.
    func toggleHistory() {
        historyExpanded.toggle()
        onShelfExpansionChange?(.history, historyExpanded)
        tableView.deselectAll(nil)
        selectedRowsForEmphasis = IndexSet()
        hoveredAgentId = nil
        keyboardFocusIntent = nil
        render(display(from: allRows))
    }

    // MARK: - The two index spaces (P4.7)

    /// Take a new drawn model, and build the two index maps WITH it — one
    /// assignment, so `rows`, `items` and the mapping between them cannot be left
    /// disagreeing by a path that updated only some of them.
    // Ticket: .plans/0721-subagents-handoff.md
    /// Where every drawn row sits in the tree, in one pass over the list.
    ///
    /// DERIVED HERE AND NOWHERE ELSE, because two things consume it and they must
    /// not be able to disagree: `heightOfRow` (a group's last row is taller) and the
    /// cell (which draws the connector into that same extra room). Computing it
    /// twice is how the extra space ends up under a row that draws no terminator.
    ///
    /// A HEADING IS DEPTH 0 AND THAT IS THE POINT: `Snoozed (3)` between two agents
    /// ends every open group, because nothing below a section heading belongs to
    /// anything above it.
    ///
    /// A remainder is its parent's child: "3 more" lists rows that would have been
    /// drawn at `parent.depth + 1`, capped by `AgentInboxRow.maxDepth` for the same
    /// reason `InboxSort.nest` caps a real child.
    static func nestings(for items: [InboxListItem]) -> [InboxNesting] {
        var depths: [Int] = []
        depths.reserveCapacity(items.count)
        var depthByAgent: [UUID: Int] = [:]
        for item in items {
            switch item {
            case .agent(let row):
                let depth = max(0, row.depth)
                depthByAgent[row.id] = depth
                depths.append(depth)
            case .fanoutRemainder(let remainder):
                depths.append(min((depthByAgent[remainder.parentId] ?? 0) + 1,
                                  AgentInboxRow.maxDepth))
            case .shelfHeader, .historyHeader, .shelfSpacer, .settledMore:
                depths.append(0)
            }
        }
        return depths.indices.map { index in
            InboxNesting(
                depth: depths[index],
                nextDepth: index + 1 < depths.count ? depths[index + 1] : 0)
        }
    }

    /// What the row at this table index draws of the tree.
    func nesting(atTableRow row: Int) -> InboxNesting {
        nestingByTableRow.indices.contains(row) ? nestingByTableRow[row] : .none
    }

    private func setItems(_ next: [InboxListItem]) {
        items = next
        rows = next.compactMap(\.agentRow)
        nestingByTableRow = AgentInboxView.nestings(for: next)
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

    /// The History heading's table row, or nil when nothing has been closed.
    private var historyHeaderTableRow: Int? {
        items.firstIndex { if case .historyHeader = $0 { return true } else { return false } }
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

    /// Fold or unfold one parent's children. The entry point a disclosure
    /// control calls, on mouse-down; everything it needs is read from the list.
    ///
    /// The identity sequence changes, but only by one contiguous block, so the
    /// table inserts or removes exactly those rows (`applyFoldIncrementally`)
    /// rather than reloading whole; anything else falls back to a full render.
    /// Selection and hover are dropped for the same reason `setScope` drops them —
    /// their indexes belong to the list that just went away, and a bulk action
    /// (P3.11) must never reach a row you cannot see.
    func toggleCollapse(parentId: UUID) {
        let animates = window != nil && !prefersReducedMotion()
        let presentation = animates ? foldMotion.takePresentation() : [:]
        foldMotion.cancel()
        // A fold owns the cards and following rows together. Retire any generic
        // stream fade instead of laying a second 150 ms fade over the unfold.
        for ghost in exitGhostViews { ghost.removeFromSuperview() }
        exitGhostViews.removeAll()
        qaLastRowMotion = ([], [])
        // ONE photograph of what is on screen. Every cell the fold leaves alone
        // is the same view with the same pixels afterwards, so these images are
        // reused at the far end and only the rebuilt cells are taken again.
        // The fold photographs the resting deck, never a pose mid-spring.
        for card in deckCells.allObjects { card.restDeck() }
        let before = animates ? captureFoldRows() : FoldCapture()
        let expanded = collapsedParents.contains(parentId)
        let anchor = tableRow(forAgentId: parentId).map {
            (id: parentId, viewportMinY: tableView.rect(ofRow: $0).minY - tableView.visibleRect.minY)
        }
        foldChoices[parentId] = collapsedParents.contains(parentId)
        onParentFoldChange?(foldChoices)
        tableView.deselectAll(nil)
        selectedRowsForEmphasis = IndexSet()
        // P1.2: hover and the focus ring are dropped and then RE-DERIVED from
        // where the pointer actually is once the new list is on screen, so a
        // fold or a scope flip cannot leave a row lit that the pointer is no
        // longer over — and cannot un-light the row it still is over either.
        // The cell that was lit survives an incremental fold, so it is
        // repainted here, and its earlier photograph is not reused.
        let lit = tableRow(forAgentId: hoveredAgentId)
        let relit = Set([lit.flatMap { item(at: $0)?.identity }].compactMap { $0 })
        hoveredAgentId = nil
        keyboardFocusIntent = nil
        applyHoverInPlace(tableRows: [lit].compactMap { $0 })
        let next = display(from: allRows)
        if !applyFoldIncrementally(next, parentId: parentId) {
            render(next, animateRows: false)
        }
        layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        restoreScrollAnchor(anchor)
        guard animates else { return }
        let after = captureFoldRows(reusing: before, excluding: relit)
        foldMotion.start(from: before.snapshots.merging(presentation) { _, drawn in drawn },
                         to: after.snapshots,
                         parentKey: "agent:\(parentId.uuidString)", expanded: expanded,
                         container: scrollView.contentView,
                         covering: after.sources.filter { $0.key != "agent:\(parentId.uuidString)" }.map(\.value))
    }

    /// Fold by inserting or removing the parent's rows and nothing else. The
    /// surviving cells stay the same views — no rebuild, and their photographs
    /// stay valid — and only the rows whose drawing depends on the fold are
    /// rebuilt: the parent (triangle, rollup, tucked cards), any row whose place
    /// in the tree moved (connector, wash, end gap) and the settle nudge's old
    /// and new rows. Answers false, leaving everything untouched, when the
    /// change is not one contiguous block; the caller then renders whole.
    private func applyFoldIncrementally(_ next: [InboxListItem], parentId: UUID) -> Bool {
        let old = items.map(\.identity), new = next.map(\.identity)
        let shared = min(old.count, new.count)
        var prefix = 0
        while prefix < shared, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shared - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let removed = IndexSet(integersIn: prefix..<(old.count - suffix))
        let inserted = IndexSet(integersIn: prefix..<(new.count - suffix))
        guard removed.isEmpty != inserted.isEmpty else { return false }
        let oldNesting = Dictionary(zip(old, nestingByTableRow)) { first, _ in first }
        let renderNow = clock()
        let oldNudge = settleNudgeTargetID(now: renderNow)
        endRename(commit: true)
        cancelCrossfades()
        setItems(next)
        tableView.beginUpdates()
        if inserted.isEmpty {
            tableView.removeRows(at: removed, withAnimation: [])
        } else {
            tableView.insertRows(at: inserted, withAnimation: [])
        }
        tableView.endUpdates()
        // The table moved the surviving cells; key them by the rows they are on now.
        cellsByRow.removeAll()
        for row in 0..<tableView.numberOfRows {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentInboxRowCell {
                cellsByRow[row] = cell
            }
        }
        let nudges: Set<UUID> = Set([oldNudge, settleNudgeTargetID(now: renderNow)].compactMap { $0 })
        var stale = IndexSet(new.indices.filter { row in
            guard !inserted.contains(row) else { return false }
            if let id = next[row].agentRow?.id, id == parentId || nudges.contains(id) { return true }
            return oldNesting[new[row]] != nestingByTableRow[row]
        })
        // A jump chord names "the Nth agent", and the rows below the fold moved.
        if jumpHintsVisible {
            stale.formUnion(IndexSet((0..<InboxJump.maximumRows).compactMap(tableRow(forRowIndex:))))
        }
        tableView.noteHeightOfRows(withIndexesChanged: stale)
        tableView.reloadData(forRowIndexes: stale, columnIndexes: IndexSet(integer: 0))
        updateShelfSpacerHeight()
        updateEmptyState()
        updateBulkBar()
        updateAccessibilityHierarchy()
        refreshHoverFromPointer()
        scheduleWakeRerender()
        return true
    }

    // Plan: .plans/86-workspace-filter/README.md
    /// A scope change by removing the rows that left and inserting the ones that
    /// arrived, keeping every surviving cell. A filter never reorders (P3.8), so the
    /// rows both lists share appear in the same order in each; when they do not,
    /// this answers false, touches nothing, and the caller renders whole.
    ///
    /// The checklist made this matter: one pick used to change the scope, and now a
    /// person clicks three boxes in a row, each of which rebuilt every card.
    private func applyScopeIncrementally(_ next: [InboxListItem], previousRollups: [UUID: ChildRollup]) -> Bool {
        let old = items.map(\.identity), new = next.map(\.identity)
        let oldSet = Set(old), newSet = Set(new)
        guard oldSet.count == old.count, newSet.count == new.count,
              old.filter(newSet.contains) == new.filter(oldSet.contains) else { return false }
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
        let inserted = IndexSet(new.indices.filter { !oldSet.contains(new[$0]) })
        let oldNesting = Dictionary(zip(old, nestingByTableRow)) { first, _ in first }
        let renderNow = clock()
        let oldNudge = settleNudgeTargetID(now: renderNow)
        endRename(commit: true)
        cancelCrossfades()
        setItems(next)
        tableView.beginUpdates()
        if !removed.isEmpty { tableView.removeRows(at: removed, withAnimation: []) }
        if !inserted.isEmpty { tableView.insertRows(at: inserted, withAnimation: []) }
        tableView.endUpdates()
        cellsByRow.removeAll()
        for row in 0..<tableView.numberOfRows {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentInboxRowCell {
                cellsByRow[row] = cell
            }
        }
        // A survivor is redrawn when what it draws from its neighbours changed: its
        // place in the tree, its rollup (a child in another workspace left), or the
        // settle nudge moving to or from it.
        let nudges: Set<UUID> = Set([oldNudge, settleNudgeTargetID(now: renderNow)].compactMap { $0 })
        var stale = IndexSet(new.indices.filter { row in
            guard !inserted.contains(row) else { return false }
            if let id = next[row].agentRow?.id {
                if nudges.contains(id) || previousRollups[id] != rollupsByParent[id] { return true }
            }
            return oldNesting[new[row]] != nestingByTableRow[row]
        })
        if jumpHintsVisible {
            stale.formUnion(IndexSet((0..<InboxJump.maximumRows).compactMap(tableRow(forRowIndex:))))
        }
        tableView.noteHeightOfRows(withIndexesChanged: stale)
        tableView.reloadData(forRowIndexes: stale, columnIndexes: IndexSet(integer: 0))
        applyWorkspaceMarksInPlace()
        updateShelfSpacerHeight()
        updateEmptyState()
        updateBulkBar()
        updateAccessibilityHierarchy()
        refreshHoverFromPointer()
        scheduleWakeRerender()
        return true
    }

    /// The edge mark on every drawn card, for a list that just started or stopped
    /// spanning more than one workspace without rebuilding its cells.
    private func applyWorkspaceMarksInPlace() {
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentInbox96CellView,
                  let model = item(at: row)?.agentRow else { continue }
            cell.workspaceMarkColour = marksWorkspaces
                ? model.workspaceId.map { workspaceColour($0).withAlphaComponent(0.85) } : nil
        }
    }

    /// What one fold photograph holds: native geometry for every row, pixels
    /// for the visible materialized ones, and the cell each image came from.
    private struct FoldCapture {
        var snapshots: [String: InboxFoldMotion.Snapshot] = [:]
        var sources: [String: NSView] = [:]
    }

    /// Native geometry for every row, pixels only for the visible materialized
    /// ones. Geometry-only entries let a following row travel out of the viewport
    /// rather than being mistaken for a child being tucked into the parent. An
    /// image from `earlier` is reused when it was taken of this same cell at
    /// this same size, unless the row is in `excluding`.
    private func captureFoldRows(reusing earlier: FoldCapture = FoldCapture(),
                                 excluding: Set<String> = []) -> FoldCapture {
        let clip = scrollView.contentView
        var capture = FoldCapture()
        for index in items.indices {
            if case .shelfSpacer = items[index] { continue }
            let key = items[index].identity
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
            var rect = tableView.rect(ofRow: index)
            var local = cell?.bounds ?? NSRect(origin: .zero, size: rect.size)
            if items[index].agentRow?.variant == .card, cardStyleOverride != nil {
                // Keep the painted card height constant. A group's final row has
                // extra space below it; stretching that gap would squash its text.
                local.size.height -= CGFloat(AgentInbox96CellView.trailingGap(for: nesting(atTableRow: index)))
                local.size.height += CGFloat(Self.rowSpacing)
                rect.size.height = local.height
            }
            var frame = cell.map { clip.convert(local, from: $0) } ?? clip.convert(rect, from: tableView)
            frame.origin.x -= clip.bounds.minX
            frame.origin.y -= clip.bounds.minY
            let visible = frame.intersects(NSRect(origin: .zero, size: clip.bounds.size))
            var image: NSImage?
            if visible, let cell, capture.sources.count < InboxFoldMotion.snapshotLimit {
                if !excluding.contains(key), earlier.sources[key] === cell,
                   let reused = earlier.snapshots[key]?.image, reused.size == local.size {
                    image = reused
                } else {
                    image = InboxFoldMotion.image(of: cell, in: local)
                    if (cell as? AgentInbox96CellView)?.qaDeckIsPosedForQA == true { qaPosedDecksPhotographed += 1 }
                }
            }
            capture.snapshots[key] = InboxFoldMotion.Snapshot(key: key, frame: frame, image: image, order: index)
            if image != nil, let cell { capture.sources[key] = cell }
        }
        return capture
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P6.5-child-fanout-attention-rollup.md
    /// Open one parent's explicit remainder. This is the only path that removes
    /// the cap: the hidden children are never silently discarded or inferred from
    /// a row count, and the selection/focus reset follows every other list-shape
    /// change because the table's index space changes.
    func expandFanout(parentId: UUID) {
        guard fanoutRemaindersByParent[parentId] != nil else { return }
        expandedFanoutParents.insert(parentId)
        tableView.deselectAll(nil)
        selectedRowsForEmphasis = IndexSet()
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
        // Plan: .plans/86-workspace-filter/README.md — a scope change REFLOWS: the
        // rows that stay slide to their new places instead of jumping, while
        // arrivals and departures fade where they land and where they stood.
        //
        // Only the rows that LEAVE are photographed. Survivors are the same live cells
        // (`applyScopeIncrementally`) and slide from where they were; arrivals are
        // live cells fading up. A photograph of every card cost a toggle half its time.
        if window != nil, !prefersReducedMotion() {
            foldMotion.cancel()
            for card in deckCells.allObjects { card.restDeck() }
            let previousIds = Set(rows.map(\.id))
            var previousY: [UUID: CGFloat] = [:]
            for (index, row) in rows.enumerated() {
                if let tableRow = tableRow(forRowIndex: index) { previousY[row.id] = tableView.rect(ofRow: tableRow).minY }
            }
            let previousRollups = rollupsByParent
            let shown = display(from: allRows)
            let nextIds = Set(shown.compactMap { $0.agentRow?.id })
            let ghosts = shown.count <= Self.rowMotionRowLimit
                ? liftExitGhosts(leaving: previousIds.subtracting(nextIds)) : []
            if !applyScopeIncrementally(shown, previousRollups: previousRollups) {
                render(shown, animateRows: false)
            }
            layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            settlePeekForNewScope()
            if shown.count <= Self.rowMotionRowLimit {
                startRowMotion(exits: ghosts, entering: nextIds.subtracting(previousIds))
                slideSurvivors(from: previousY)
            }
        } else {
            let previousRollups = rollupsByParent
            let shown = display(from: allRows)
            if !applyScopeIncrementally(shown, previousRollups: previousRollups) { render(shown) }
            settlePeekForNewScope()
        }
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
        // The clear button exists only while there is something to clear, so its
        // visibility is a function of the text and has to be recomputed here —
        // `setSearchForQA` routes through this same notification, which keeps the
        // button honest under a check as well as under a keystroke.
        applySearchFieldChrome()
        render(display(from: allRows))
    }

    /// The focus hairline is the only thing the field paints while you are in it,
    /// so it has to be repainted when the caret arrives and when it leaves —
    /// nothing else in this view is notified of either.
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        applySearchFieldChrome()
    }

    /// Empty the search the way a person does, through the same notification a
    /// keystroke raises, so the filter, the selection reset and the button's own
    /// visibility all take one path.
    @objc private func newAgentPressed() { onNewAgent?() }

    @objc private func clearSearch() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField))
        window?.makeFirstResponder(searchField)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    /// Which workspace verbs are available. Told by the host on every reload, since
    /// both answers come off the registry (`rename` needs a target at all; `delete`
    /// additionally needs a second workspace to fall back to).
    /// 0721: `deleteDisabledReason` is why the verb is greyed. A disabled item with
    /// no explanation is the whole of "i can't delete a work space" from the user's
    /// side — the refusal may be correct and still has to be legible.
    func setWorkspaceManagement(canRename: Bool, canDelete: Bool, deleteDisabledReason: String? = nil) {
        guard canRename != canRenameWorkspace || canDelete != canDeleteWorkspace
                || deleteDisabledReason != workspaceDeleteDisabledReason else { return }
        canRenameWorkspace = canRename
        canDeleteWorkspace = canDelete
        workspaceDeleteDisabledReason = deleteDisabledReason
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
        applyScopeTrigger()
    }

    private var workspaceNamesById: [UUID: String] {
        var names: [UUID: String] = [:]
        for row in allRows { if let id = row.workspaceId, let name = row.workspaceName { names[id] = name } }
        for case .workspaceID(let id, let name) in scopeCatalog { names[id] = name }
        return names
    }

    /// The scope as the title and the match read it: a stored set ignores any
    /// workspace the catalog no longer holds (a deleted one) without forgetting it.
    /// With no catalog yet, nothing is known to be gone.
    private var effectiveScope: InboxScope {
        guard case .workspaces(let filter) = scope else { return scope }
        var known = Set<UUID>()
        for case .workspaceID(let id, _) in scopeCatalog { known.insert(id) }
        guard !known.isEmpty else { return scope }
        return InboxScope.normalized(filter.ignoringWorkspaces(notIn: known))
    }

    func workspaceColour(_ id: UUID) -> NSColor {
        ZoneChromeNSView.color(named: workspaceColourNames[id] ?? WorkspaceEntry.defaultColour(for: id))
    }

    /// The trigger shows the scope's title and, for a set of several workspaces,
    /// their dots. Its `selectedID` rests on `All agents` — a row every menu has —
    /// so a menu rebuilt under it never resets the label to its first row.
    private func applyScopeTrigger() {
        let names = workspaceNamesById
        let title = InboxScopeMenu.title(for: effectiveScope, names: names, current: currentWorkspaceId)
        scopeButton.selectedTitleOverride = title
        scopeButton.selectedID = InboxScope.all.storageValue
        scopeButton.setAccessibilityValue(title)
        var dots: [UUID] = []
        if case .workspaces(let filter) = scope {
            let known = Array(names.keys)
            dots = known.filter { filter.shows(workspace: $0, current: currentWorkspaceId) }
                .sorted { left, right in
                    if left == currentWorkspaceId { return true }
                    if right == currentWorkspaceId { return false }
                    return (names[left] ?? "").localizedCaseInsensitiveCompare(names[right] ?? "") == .orderedAscending
                }
            if dots.count < 2 { dots = [] }
        }
        scopeButton.leadingSwatches = dots.prefix(3).map(workspaceColour)
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
        var workspaces: [InboxScopeMenu.Workspace] = []
        var projects: [String] = []
        var legacyWorkspaces: [String] = []
        for entry in scopeCatalog {
            switch entry {
            case .workspaceID(let id, let name): workspaces.append(.init(id: id, name: name))
            case .project(let name): projects.append(name)
            case .workspace(let name): legacyWorkspaces.append(name)
            default: break
            }
        }
        let entries = InboxScopeMenu.entries(
            scope: scope, workspaces: workspaces, projects: projects, legacyWorkspaces: legacyWorkspaces,
            rows: allRows, current: currentWorkspaceId,
            offersCurrent: currentWorkspaceId != nil || currentWorkspaceName != nil,
            offersThisMac: offersThisMacScope)
        scopeMenuEntries = entries
        if let editing = colourEditingWorkspace,
           let workspace = entries.first(where: { $0.kind == .workspace(editing) }) {
            scopeButton.items = colourItems(for: editing, name: workspace.title)
            restoreScopeSelection()
            return
        }
        var items = entries.enumerated().map { index, entry in
            choiceItem(for: entry, separatorBefore: index > 0 && entries[index - 1].section != entry.section)
        }
        if hiddenListShown, let hiding = externalSessionHiding, !hiding.entries.isEmpty {
            scopeButton.items = hiddenListItems(hiding.entries)
            restoreScopeSelection()
            return
        }
        hiddenListShown = false
        if let count = externalSessionHiding?.entries.count, count > 0 {
            var hidden = ChoiceItem(id: Self.hiddenListItemId, title: "Hidden from elsewhere",
                                    icon: .system("eye.slash"))
            hidden.trailing = "\(count)"
            hidden.keepsOpen = true
            hidden.separatorBefore = true
            items.append(hidden)
        }
        managementItems.removeAll()
        // Keep every management affordance visible. Unsupported actions are
        // disabled in place, rather than disappearing and making the menu's
        // contract depend on the current workspace count. The checklist draws
        // the divider above them.
        for action in WorkspaceManagementAction.allCases {
            let enabled = action == .create || (action == .rename ? canRenameWorkspace : canDeleteWorkspace)
            // The id keeps the bare title, so every existing lookup still resolves.
            var title = action.title
            if action == .delete, !enabled, let reason = workspaceDeleteDisabledReason, !reason.isEmpty {
                title = "\(action.title) — \(reason)"
            }
            var item = ChoiceItem(id: "management:\(action.title)", title: title,
                                  enabled: enabled)
            item.separatorBefore = action == WorkspaceManagementAction.allCases.first
            managementItems[action] = item
            items.append(item)
        }
        scopeButton.items = items
        restoreScopeSelection()
    }

    private func choiceItem(for entry: InboxScopeMenuEntry, separatorBefore: Bool) -> ChoiceItem {
        // Checkboxes combine; picks replace, so a pick wears the old menu's
        // checkmark instead of a box. `All agents` is the set's select-all.
        let isPick: Bool
        switch entry.kind {
        case .thisMac, .project, .legacyWorkspace: isPick = true
        default: isPick = false
        }
        var item = ChoiceItem(id: entry.id, title: entry.title, detail: entry.detail,
                              icon: isPick && entry.check == .on ? .system("checkmark") : nil)
        if !isPick {
            switch entry.check {
            case .on: item.check = .on
            case .off: item.check = .off
            case .mixed: item.check = .mixed
            case .following: item.check = .following
            }
        }
        item.trailing = entry.trailing
        item.attention = entry.needsYou
        item.separatorBefore = separatorBefore
        item.keepsOpen = entry.isToggle
        let only = ChoiceAccessory(id: "only", title: "Only", symbol: nil,
                                   accessibilityLabel: "Show only \(entry.title)")
        switch entry.kind {
        case .workspace(let id):
            item.swatch = workspaceColour(id)
            // Trailing edge first: `…` outermost, `Only` beside it.
            item.accessories = [
                ChoiceAccessory(id: "colour", title: nil, symbol: "ellipsis",
                                accessibilityLabel: "Colour for \(entry.title)"),
                only,
            ]
            item.optionAccessoryID = only.id
        case .unplaced:
            item.accessories = [only]
            item.optionAccessoryID = only.id
        default:
            break
        }
        return item
    }

    /// The palette, in place of the scopes, for one workspace. Choosing a colour
    /// (or Back) returns to the scopes without closing the popover.
    private func colourItems(for workspace: UUID, name: String) -> [ChoiceItem] {
        let chosen = workspaceColourNames[workspace] ?? WorkspaceEntry.defaultColour(for: workspace)
        var back = ChoiceItem(id: "colour:back", title: name, icon: .system("chevron.left"))
        back.keepsOpen = true
        return [back] + ZoneColorConfig.palette.enumerated().map { index, colour in
            var item = ChoiceItem(id: "colour:\(colour)", title: colour.capitalized,
                                  icon: colour == chosen ? .system("checkmark") : nil)
            item.swatch = ZoneChromeNSView.color(named: colour)
            item.keepsOpen = true
            item.separatorBefore = index == 0
            return item
        }
    }

    private func scopeAccessoryPressed(_ item: ChoiceItem, _ accessory: String) {
        guard let entry = scopeMenuEntries.first(where: { $0.id == item.id }) else { return }
        switch accessory {
        case "only":
            guard let next = InboxScopeMenu.choose(entry.kind, from: scope, current: currentWorkspaceId, only: true)
            else { return }
            setScope(next, notify: true)
        case "colour":
            guard case .workspace(let id) = entry.kind else { return }
            colourEditingWorkspace = id
            setPeek(nil)
            updateScopeMenu()
        default:
            break
        }
    }

    /// Hovering a workspace that is on screen peeks it: every other workspace's
    /// cards sink. Only while the list spans several — one workspace has nothing
    /// to sink.
    private func scopeFocusChanged(_ id: String?) {
        focusedScopeItemID = id
        setPeek(peekTarget(forScopeItem: id))
    }

    /// The popover row under the pointer or the keyboard, kept so a toggle can
    /// settle the peek for the list it produces.
    private var focusedScopeItemID: String?

    private func peekTarget(forScopeItem id: String?) -> UUID? {
        guard colourEditingWorkspace == nil, marksWorkspaces, let id,
              let entry = scopeMenuEntries.first(where: { $0.id == id }),
              case .workspace(let workspace) = entry.kind,
              entry.check == .on || entry.check == .following
        else { return nil }
        return workspace
    }

    /// After a scope change, before anything photographs the new list: the row
    /// still under the pointer peeks what it now shows, or nothing.
    private func settlePeekForNewScope() {
        guard focusedScopeItemID != nil || peekWorkspace != nil else { return }
        peekWorkspace = peekTarget(forScopeItem: focusedScopeItemID)
        applyPeek(animated: false)
    }

    static let peekDimmedAlpha: CGFloat = 0.32
    static let peekDuration: TimeInterval = 0.12

    private func setPeek(_ workspace: UUID?) {
        guard workspace != peekWorkspace else { return }
        peekWorkspace = workspace
        applyPeek(animated: true)
    }

    /// The peek's alpha on every drawn agent cell. Re-applied after a render, which
    /// builds new cells at full alpha.
    private func applyPeek(animated: Bool) {
        let animates = animated && !prefersReducedMotion()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animates ? Self.peekDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for row in 0..<tableView.numberOfRows {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? AgentInbox96CellView else { continue }
                var alpha: CGFloat = 1
                if let peekWorkspace, let model = item(at: row)?.agentRow, model.workspaceId != peekWorkspace {
                    alpha = Self.peekDimmedAlpha
                }
                cell.setPeekAlpha(alpha, animated: animates)
            }
        }
    }

    private func choicePicked(_ item: ChoiceItem) {
        if handleHiddenListChoice(item) { return }
        if item.id == "colour:back" {
            colourEditingWorkspace = nil
            updateScopeMenu()
            return
        }
        if item.id.hasPrefix("colour:"), let workspace = colourEditingWorkspace {
            colourEditingWorkspace = nil
            onWorkspaceColourChange?(workspace, String(item.id.dropFirst("colour:".count)))
            updateScopeMenu()
            return
        }
        if let entry = scopeMenuEntries.first(where: { $0.id == item.id }) {
            if !entry.isToggle { setPeek(nil) }
            guard let next = InboxScopeMenu.choose(entry.kind, from: scope, current: currentWorkspaceId) else {
                // A refused uncheck or a re-picked pick: the menu still has to show
                // the boxes the scope really has.
                updateScopeMenu()
                return
            }
            setScope(next, notify: true)
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
        updateAccessibilityHierarchy()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// P3.7: parked rows still use their one-line variant. Card rows, however,
    /// ask the content-derived height path for the bands this row actually draws;
    /// the list never branches on state, attention, or lifecycle importance.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        lastHeightQueryColumnWidth = column.width
        // The room under the LAST row of a group. Added here and reserved by the
        // cell out of the same function, so the card cannot grow into it.
        let groupEndGap = CGFloat(
            AgentInbox96CellView.trailingGap(for: nesting(atTableRow: row)))
        guard let item = item(at: row) else { return AgentInboxView.shelfHeaderHeight }
        guard let model = item.agentRow else {
            switch item {
            case .fanoutRemainder: return AgentInboxView.slimRowHeight + groupEndGap
            case .shelfHeader, .historyHeader, .settledMore:
                return AgentInboxView.shelfHeaderHeight
            case .shelfSpacer:
                return max(1, shelfSpacerHeight)
            case .agent: return AgentInboxView.shelfHeaderHeight
            }
        }
        // A 96 card is a FIXED three-band pitch — every band is always drawn, which
        // is the point of the redesign — so its height cannot come from the
        // content-derived ladder below. Cards only: a slim row is queue-94's and
        // stays queue-94's.
        if let override = cardStyleOverride, model.variant == .card {
            return CGFloat(override.cardHeight(model)) + groupEndGap
        }
        let indent = Double(max(0, model.depth)) * AgentInboxView.indentPerLevel
        let available = max(
            0,
            Double(column.width) - indent - Inset.card.horizontal)
        return AgentInboxView.height(
            for: model,
            availableWidth: available,
            disclosure: disclosure(for: model),
            rollup: rollupsByParent[model.id]) + groupEndGap
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
                header.apply(section: .snoozed, count: count, isExpanded: isExpanded)
                shelfHeaderCell = header
                return header
            // .plans/05-close-to-history.md. Its own cached cell: the two headings
            // are on screen at the same time, so sharing one instance would have
            // the second draw overwrite the first.
            case .historyHeader(let count, let isExpanded):
                let header = historyHeaderCell ?? AgentInboxShelfHeaderView()
                header.onToggle = { [weak self] in self?.toggleHistory() }
                header.apply(section: .history, count: count, isExpanded: isExpanded)
                historyHeaderCell = header
                return header
            case .shelfSpacer:
                return NSView()
            // P4.8
            case .settledMore(let hidden):
                let footer = settledMoreCell ?? AgentInboxSettledMoreView()
                footer.onPress = { [weak self] in self?.expandSettledTail() }
                footer.apply(hidden: hidden)
                settledMoreCell = footer
                return footer
            case .fanoutRemainder(let remainder):
                let cell = fanoutRemainderCellsByParent[remainder.parentId] ?? AgentInboxRemainderView()
                cell.identifier = NSUserInterfaceItemIdentifier(
                    "agent-inbox-fanout-\(remainder.parentId.uuidString)")
                cell.onExpand = { [weak self] in self?.expandFanout(parentId: remainder.parentId) }
                cell.setNesting(nesting(atTableRow: row))
                cell.apply(remainder: remainder)
                fanoutRemainderCellsByParent[remainder.parentId] = cell
                return cell
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
        // Program 96's redesigned card, when something has injected one. nil is the
        // default and the only thing production or any queue-94 gate ever sees.
        case .card: cell = cardStyleOverride?.makeCell() ?? AgentInboxCellView()
        case .slim: cell = AgentInboxSlimCellView()
        }
        // A 96 card's height is its fixed pitch, never measured off its content,
        // so building one gives the height cache nothing to revalidate. Arming
        // it anyway made the next layout pass reload and rebuild EVERY cell —
        // after each fold, mid-animation, and after every hover reload.
        if cardStyleOverride == nil || model.variant != .card { needsHeightRevalidation = true }
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
        if let regular = cell as? AgentInboxCellView {
            regular.setNesting(nesting(atTableRow: row))
        }
        if let slim = cell as? AgentInboxSlimCellView {
            slim.setNesting(nesting(atTableRow: row))
        }
        let rowDisclosure = disclosure(for: model)
        let rowRollup = rollupsByParent[model.id]
        let renderNow = clock()
        cell.apply(
            model,
            emphasis: AgentInboxRow.emphasis(
                for: model.state, attention: model.attention, isInteracting: interacting
            ),
            indent: Double(max(0, model.depth)) * AgentInboxView.indentPerLevel,
            disclosure: rowDisclosure,
            // P2D.5/P6.5: a full rollup speaks while folded; a capped attention
            // rollup also speaks while expanded because its hidden child is still
            // absent from the drawn rows. Neither path mutates row.attention.
            rollup: rowRollup,
            // P3.11: EVERY selected row is outlined, not just the last one clicked —
            // `selectedRow` is one index and a range is a set.
            isSelected: tableView.selectedRowIndexes.contains(row),
            isInteracting: interacting,
            now: renderNow
        )
        configureHoverActions(on: cell, for: model)
        if let redesigned = cell as? AgentInbox96CellView {
            redesigned.reducesHoverMotion = { [weak self] in self?.prefersReducedMotion() ?? false }
            redesigned.workspaceMarkColour = marksWorkspaces
                ? model.workspaceId.map { workspaceColour($0).withAlphaComponent(0.85) } : nil
            if let peekWorkspace, model.workspaceId != peekWorkspace {
                redesigned.setPeekAlpha(Self.peekDimmedAlpha, animated: false)
            }
            // The tree connector. Set from the LIST, which is the only thing that
            // knows what is drawn above and below this row.
            redesigned.setNesting(nesting(atTableRow: row))
            // How far the drawn parent's counted triangle reaches, so this row's
            // title can clear it. Same inputs the parent's own cell is given.
            var parentTrailing: CGFloat = 0
            if model.depth > 0, let parentId = model.parentId,
               let parent = rows.first(where: { $0.id == parentId }) {
                parentTrailing = AgentInbox96CellView.disclosureTrailing(
                    for: disclosure(for: parent),
                    childCount: rollupsByParent[parentId]?.children ?? 0)
            }
            redesigned.setParentDisclosureTrailing(parentTrailing)
            // The "All set?" nudge: a finished agent you read and left asks to be
            // settled, which closes its tile into History (`.settle`, the same verb
            // as the hover ✓, the row menu and the bulk bar, undo toast included).
            redesigned.showSettleNudge(settleNudgeTargetID(now: renderNow) == model.id) { [weak self] in
                guard let self else { return }
                self.rowChoiceTargetIds = [agentId]
                self.performRowAction(.settle)
            }
            if let projectID = model.projectId {
                projectFaviconResolver.image(for: projectID) { [weak redesigned] image in
                    redesigned?.setProjectIcon(image, for: agentId)
                }
            }
        }
        // P1.2/P1.4: the interaction ladder is set through its own call for the
        // reason the pill below is — `apply` paints what the agent IS, and where
        // the pointer and the keyboard are is not that.
        cell.applyInteraction(interaction(forTableRow: row))
        cell.setIncreasedContrast(prefersIncreasedContrast())
        // P6.6: status snapshots were compared at the row-model boundary above;
        // cell materialization must not be the first observation of a transition.
        // P3.10: the hint is set AFTER `apply` and through its own call, because it
        // is an overlay and not part of the row's content — `apply` paints what the
        // agent IS, and a pill is a thing about the keyboard.
        cell.showJumpHint(jumpHintsVisible ? AgentInboxView.jumpHintText(forRowIndex: index) : nil)
        cellsByRow[row] = cell
        updateAccessibilityHierarchy()
        return cell
    }

    /// T3 nightly's hover actions (confidence pass): a card offers [Snooze] [Settle],
    /// a snoozed slim row Wake, a settled one Un-settle — each only when the row
    /// may do it and the host performs it, through the same `performRowAction` the
    /// context menu uses.
    private func configureHoverActions(on cell: AgentInboxRowCell, for model: AgentInboxRow) {
        let id = model.id
        func action(_ kind: InboxRowAction) -> (() -> Void)? {
            guard isWired(kind), kind.isAvailable(for: model, rollups: rollupsByParent) else { return nil }
            return { [weak self] in
                guard let self else { return }
                self.rowChoiceTargetIds = [id]
                self.performRowAction(kind)
            }
        }
        if let external = model.externalSession {
            func perform(_ kind: InboxExternalSessionAction) -> () -> Void {
                { [weak self] in self?.onExternalSessionAction?(kind, id) }
            }
            if let card = cell as? AgentInbox96CellView {
                card.configureHoverActions(snooze: nil, settle: nil)
                card.configureExternalActions(
                    moveHere: external.canMoveHere ? perform(.moveHere) : nil,
                    copy: external.canCopy ? perform(.copy) : nil,
                    hide: externalSessionHiding == nil ? nil : { [weak self] in self?.hideExternalRows([id]) })
            }
            return
        }
        if let card = cell as? AgentInbox96CellView {
            card.configureHoverActions(snooze: action(.snooze), settle: action(.settle))
            card.configureExternalActions(moveHere: nil, copy: nil, hide: nil)
        } else if let slim = cell as? AgentInboxSlimCellView {
            if model.closingSince != nil {
                slim.configureBackgroundActions(
                    bringBack: isWired(.openInTile) ? { [weak self] in self?.onRevealRow?(id) } : nil,
                    stop: action(.stopAgent))
            } else {
                slim.configureBackgroundActions(bringBack: nil, stop: nil)
                switch model.lifecycle {
            case .snoozed:
                slim.configureHoverAction(symbol: "alarm", label: "Wake", perform: action(.wake))
            case .settled:
                slim.configureHoverAction(
                    symbol: "arrow.uturn.backward", label: "Un-settle", perform: action(.unsettle))
            case .active, .archived:
                slim.configureHoverAction(symbol: "arrow.uturn.backward", label: "Un-settle", perform: nil)
                }
            }
        }
    }

    /// Whether row `id`'s cell is showing its hover actions, and which.
    func hoverActionsForQA(id: UUID) -> (shown: Bool, titles: [String])? {
        guard let tableRow = tableRow(forAgentId: id) else { return nil }
        let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
        if let card = cell as? AgentInbox96CellView { return (card.qaHoverActionsShown, card.qaHoverActionTitles) }
        if let slim = cell as? AgentInboxSlimCellView {
            return (slim.qaHoverActionShown, slim.qaHoverActionTitles)
        }
        return nil
    }

    /// The where marker drawn on row `id`, read off its cell.
    func whereMarkerForQA(id: UUID) -> (text: String, frame: NSRect, placementFrame: NSRect, iconInkCenterDelta: CGFloat, projectIconOpticalCenterDelta: CGFloat)? {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return nil }
        card.layoutSubtreeIfNeeded()
        return card.qaWhereMarker
    }

    /// Every visible icon on row `id` against its line's rendered x-height.
    func iconAlignmentForQA(id: UUID) -> [AgentInbox96CellView.IconInkForQA]? {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return nil }
        return card.qaIconAlignmentForQA()
    }

    func metadataInkGeometryForQA(id: UUID) -> [String: NSRect]? {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return nil }
        card.layoutSubtreeIfNeeded()
        return card.qaMetadataInkGeometry
    }

    /// Press a hovered row's × through its own button.
    func clickHoverHideForQA(id: UUID) -> Bool {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return false }
        card.layoutSubtreeIfNeeded()
        return card.clickHoverHideForQA()
    }

    /// ⌘Z delivered to the list's own table.
    func pressCommandZForQA() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) else { return }
        tableView.keyDown(with: event)
    }

    /// Pick a row of the scope popover by id, through the production selection path.
    func chooseScopeItemForQA(id: String) -> Bool { scopeButton.chooseForQA(id: id) }
    var scopeItemIdsForQA: [String] { scopeButton.items.map(\.id) }

    /// Hover row `id` the way the pointer does, then press one of its external actions.
    func clickExternalActionForQA(id: UUID, _ action: InboxExternalSessionAction) -> Bool {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return false }
        card.layoutSubtreeIfNeeded()
        return card.clickExternalActionForQA(action)
    }

    func clickHoverSettleForQA(id: UUID) -> Bool {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return false }
        return card.clickHoverSettleForQA()
    }

    func clickSettleNudgeForQA(id: UUID) -> Bool {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
        else { return false }
        card.layoutSubtreeIfNeeded()
        return card.clickSettleNudgeForQA()
    }

    func clickBackgroundBringBackForQA(id: UUID) -> Bool {
        guard let tableRow = tableRow(forAgentId: id),
              let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                as? AgentInboxSlimCellView else { return false }
        return cell.clickBackgroundBringBackForQA()
    }

    func clickBackgroundStopForQA(id: UUID) -> Bool {
        guard let tableRow = tableRow(forAgentId: id),
              let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                as? AgentInboxSlimCellView else { return false }
        return cell.clickBackgroundStopForQA()
    }

    /// At most one nudge is ever offered, and only while no row is blocked on the
    /// person (approval, input, failed). A freshly finished, unread row does NOT
    /// hide it: with several agents running one almost always is, and the nudge
    /// then never showed. The oldest eligible completion wins, so a clock edge
    /// cannot make six cards bloom together; close it and the next one asks.
    private func settleNudgeTargetID(now: Date) -> UUID? {
        let hasBlockedWork = rows.contains { row in
            row.state == .approval || row.state == .input || row.state == .failed
        }
        guard !hasBlockedWork, isWired(.settle) else { return nil }
        // Never the agent you are on: one you just opened to read is not one you left.
        return rows.filter { row in
            row.id != openAgentId
                && AgentInbox96CellView.isSettleCandidate(row, now: now)
                && row.canSettle(rollup: rollupsByParent[row.id])
                && InboxRowAction.settle.disabledReason(
                    for: [row], isWired: true, rollups: rollupsByParent) == nil
        }.min {
            ($0.terminalEvent?.endedAt ?? $0.lastActiveAt ?? .distantFuture)
                < ($1.terminalEvent?.endedAt ?? $1.lastActiveAt ?? .distantFuture)
        }?.id
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
        if rows[index].externalSession != nil {
            onExternalSessionAction?(.watch, rows[index].id)
            return
        }
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
            // A session from another app has no tile to frame.
            if rows.first(where: { $0.id == id })?.externalSession == nil { onPreviewRow?(id) }
            return true
        case 123, 124: // ← folds the selected parent, → unfolds it
            guard let row = rows.first(where: { $0.id == id }) else { return false }
            let current = disclosure(for: row)
            guard current == (event.keyCode == 123 ? .expanded : .collapsed) else { return false }
            InboxSwarmFoldControl.noteToggle(seed: id, from: current)
            toggleCollapse(parentId: id)
            // A fold drops the selection; the keyboard keeps its place.
            if let tableRow = tableRow(forAgentId: id) {
                tableView.selectRowIndexes(IndexSet(integer: tableRow), byExtendingSelection: false)
            }
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
        // Another app's session is named by that app.
        guard rows.indices.contains(index), rows[index].externalSession == nil else { return false }
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
        // The search field shares this delegate with the rename field. It only wants
        // its focus hairline cleared; everything below is the rename's commit path.
        if (obj.object as? NSTextField) === searchField {
            applySearchFieldChrome()
            return
        }
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
            updateAccessibilityHierarchy()
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
        updateAccessibilityHierarchy()
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
        if action == .snooze, onSnoozeSelection != nil {
            // Resolve the preset list now, not after a host confirmation or a
            // later callback. This matters for wall-clock presets such as evening.
            presentSnoozeOptions(
                for: selected.map(\.id),
                anchor: bulkBar.frame,
                relativeTo: self)
            return
        }
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

    /// Present the preset submenu from the same choice family as the row menu and
    /// bulk bar. The absolute dates are computed once, when this menu opens.
    private func presentSnoozeOptions(for ids: [UUID], anchor: NSRect, relativeTo view: NSView) {
        let options = SnoozePreset.offered(at: clock(), calendar: Calendar.autoupdatingCurrent)
        guard !ids.isEmpty, !options.isEmpty else { return }
        snoozeTargetIds = ids
        let items = options.map { option in
            ChoiceItem(
                id: option.preset.rawValue, title: option.title,
                icon: .system("clock"))
        }
        let onSelection: (ChoiceItem) -> Void = { [weak self] item in
            self?.commitSnoozePreset(item, options: options)
        }
        // Headless probes have no panel, but still need the same production list
        // and callback rather than a second fake preset path.
        guard view.window != nil else {
            let list = ChoiceListView(
                items: items, selectedID: nil, presentation: .commands)
            list.onSelection = onSelection
            qaSnoozeChoiceListForQA = list
            return
        }
        qaSnoozeChoiceListForQA = nil
        rowChoiceController.present(
            items: items,
            selectedID: nil,
            presentation: .commands,
            anchor: anchor,
            relativeTo: view,
            onSelection: onSelection,
            focusReturnView: self)
    }

    /// The Color palette for these agents: None, then the zone palette in the zone
    /// menu's order. A single agent's current colour is the selected item; a
    /// mixed selection has none selected.
    private func presentIdentityColorOptions(for ids: [UUID], anchor: NSRect, relativeTo view: NSView) {
        guard !ids.isEmpty else { return }
        identityColorTargetIds = ids
        let items = [ChoiceItem(id: AgentInboxView.noIdentityColorID, title: "None", icon: .system("circle.slash"))]
            + ZoneColorConfig.palette.map { ChoiceItem(id: $0, title: $0.capitalized, icon: .system("circle.fill")) }
        let colours = Set(ids.compactMap { id in rows.first(where: { $0.id == id }) }.map(\.identityColor))
        let selectedID = colours.count == 1 ? (colours.first! ?? AgentInboxView.noIdentityColorID) : nil
        let onSelection: (ChoiceItem) -> Void = { [weak self] item in
            self?.commitIdentityColor(item)
        }
        // Headless probes have no panel; they read the same production list.
        guard view.window != nil else {
            let list = ChoiceListView(items: items, selectedID: selectedID, presentation: .commands)
            list.onSelection = onSelection
            qaIdentityColorChoiceListForQA = list
            return
        }
        qaIdentityColorChoiceListForQA = nil
        rowChoiceController.present(
            items: items, selectedID: selectedID, presentation: .commands, anchor: anchor,
            relativeTo: view, onSelection: onSelection, focusReturnView: self)
        if rowChoiceController.listView == nil {
            let list = ChoiceListView(items: items, selectedID: selectedID, presentation: .commands)
            list.onSelection = onSelection
            qaIdentityColorChoiceListForQA = list
        }
    }

    static let noIdentityColorID = "none"

    private func commitIdentityColor(_ item: ChoiceItem) {
        let ids = identityColorTargetIds
        identityColorTargetIds.removeAll()
        let targets = ids.compactMap { id in rows.first(where: { $0.id == id }) }
        guard !targets.isEmpty,
              targets.allSatisfy({ InboxRowAction.color.isAvailable(for: $0, rollups: rollupsByParent) }) else { return }
        let name: String? = item.id == AgentInboxView.noIdentityColorID ? nil : item.id
        guard name == nil || ZoneColorConfig.palette.contains(name!) else { return }
        onIdentityColorSelection?(targets.map(\.id), name)
    }

    /// The Color palette as the list shows it, and a pick through its own callback.
    var identityColorChoiceTitlesForQA: [String] {
        (rowChoiceController.listView ?? qaIdentityColorChoiceListForQA)?.qaItems.map(\.title) ?? []
    }
    @discardableResult
    func chooseIdentityColorForQA(_ title: String) -> Bool {
        guard let list = rowChoiceController.listView ?? qaIdentityColorChoiceListForQA,
              let item = list.qaItems.first(where: { $0.title == title }) else { return false }
        list.choose(id: item.id)
        return true
    }

    /// The identity dot and the name's frame on the cell drawn for this agent,
    /// whichever variant it is — built if the table has not realised it yet.
    func identityDotForQA(agentId: UUID) -> (dot: (frame: NSRect, colour: NSColor)?, title: NSRect)? {
        guard let index = rows.firstIndex(where: { $0.id == agentId }),
              let cell = cellForRow(index) else { return nil }
        cell.layoutSubtreeIfNeeded()
        if let card = cell as? AgentInbox96CellView {
            return (card.qaIdentityDotForQA, card.qaTitleFrameForQA)
        }
        if let slim = cell as? AgentInboxSlimCellView {
            return (slim.qaIdentityDotForQA, slim.qaTitleFrameForQA)
        }
        return nil
    }

    private func commitSnoozePreset(_ item: ChoiceItem, options: [SnoozeOption]) {
        guard let preset = SnoozePreset(rawValue: item.id),
              let option = options.first(where: { $0.preset == preset }) else { return }
        let ids = snoozeTargetIds
        snoozeTargetIds.removeAll()
        let targets = ids.compactMap { id in rows.first(where: { $0.id == id }) }
        guard targets.count == ids.count,
              targets.allSatisfy({ InboxRowAction.snooze.isAvailable(for: $0, rollups: rollupsByParent) }) else { return }
        if AgentInboxView.advancesSelection(InboxRowAction.snooze) {
            armAdvance(targetIds: ids)
        }
        let captured = captureLifecycle(ids)
        onSnoozeSelection?(ids, option.wakeAt)
        offerUndo(InboxUndoToast.snoozedVerb, capturedInOrder: captured)
        pendingAdvance = nil
    }

    /// What the bar may offer this selection: P3.11's availability intersection, then
    /// P3.15's capability gate. One function so the bar it draws and the action it
    /// performs cannot come apart.
    private func offeredBulkActions(for selected: [AgentInboxRow]) -> [InboxBulkAction] {
        guard onBulkAction != nil, !selected.contains(where: { $0.externalSession != nil }) else { return [] }
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
        // Another app's session has none of an agent's verbs; its own are on
        // the row (click to watch) and its hover buttons.
        guard !targets.contains(where: { $0.externalSession != nil }) else {
            rowChoiceTargetIds.removeAll()
            guard externalSessionHiding != nil, targets.allSatisfy({ $0.externalSession != nil }) else {
                rowChoiceController.dismiss()
                qaChoiceListForQA = nil
                return false
            }
            // Hide is the one verb a session from elsewhere has here.
            let ids = targets.map(\.id)
            let hide = ChoiceItem(id: Self.hideItemId,
                                  title: targets.count > 1 ? "Hide \(targets.count)" : "Hide",
                                  icon: .system("eye.slash"))
            return presentRowChoices([hide], anchor: anchor) { [weak self] _ in self?.hideExternalRows(ids) }
        }
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
                icon: action.icon,
                destructive: action == .delete || action == .archive
            )
        }
        return presentRowChoices(items, anchor: anchor) { [weak self] item in
            guard let self, let action = InboxRowAction(rawValue: item.id) else { return }
            self.performRowAction(action)
        }
    }

    private func presentRowChoices(
        _ items: [ChoiceItem], anchor: NSRect, onSelection: @escaping (ChoiceItem) -> Void
    ) -> Bool {
        if tableView.window == nil {
            // Headless checks retain the same ChoiceListView the controller presents;
            // only the AppKit panel is unavailable without a window.
            let list = ChoiceListView(
                items: items, selectedID: nil, presentation: .commands)
            list.onSelection = onSelection
            qaChoiceListForQA = list
            return true
        }
        qaChoiceListForQA = nil
        rowChoiceController.present(
            items: items, selectedID: nil, presentation: .commands, anchor: anchor,
            relativeTo: tableView,
            onSelection: onSelection, focusReturnView: tableView
        )
        // The controller owns the production list even when AppKit cannot make the
        // transient panel visible in a headless probe (for example, before the app
        // activates its window). QA reads that same list, not a parallel menu model.
        if rowChoiceController.listView == nil {
            let list = ChoiceListView(
                items: items, selectedID: nil, presentation: .commands)
            list.onSelection = onSelection
            qaChoiceListForQA = list
        }
        return rowChoiceController.listView != nil || qaChoiceListForQA != nil
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
        if action == .snooze, onSnoozeSelection != nil,
           let first = targets.first,
           let tableRow = tableRow(forAgentId: first.id) {
            presentSnoozeOptions(
                for: targets.map(\.id),
                anchor: tableView.rect(ofRow: tableRow),
                relativeTo: tableView)
            return
        }
        switch action {
        case .openInTile:
            guard let first = targets.first else { return }
            onRevealRow?(first.id)
        case .rename:
            guard targets.count == 1, let target = targets.first else { return }
            _ = beginRename(agentId: target.id)
        case .color:
            // A palette, not an action: it opens the second list, as Snooze does,
            // and the pick lands through `onIdentityColorSelection`.
            guard let first = targets.first, let tableRow = tableRow(forAgentId: first.id) else { return }
            presentIdentityColorOptions(
                for: targets.map(\.id), anchor: tableView.rect(ofRow: tableRow), relativeTo: tableView)
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
        case .settle, .unsettle, .snooze, .wake, .markUnread, .generateName, .color, .stopAgent,
             .archive, .delete:
            return onRowAction != nil && wiredRowActions.contains(action)
        }
    }

    /// P3.15, for the checks: the shipped list's own answer, so "Snooze is still
    /// greyed" is asserted against the gate the menu uses rather than a copy of it.
    func isRowActionWiredForQA(_ action: InboxRowAction) -> Bool { isWired(action) }
    /// The close nudge as the row draws it.
    func isCloseNudgeShownForQA(agentId: UUID) -> Bool {
        guard let row = tableRow(forAgentId: agentId),
              let cell = cellsByRow[row] as? AgentInbox96CellView else { return false }
        return cell.isSettleNudgeShownForQA
    }
    func closeNudgeTitleForQA(agentId: UUID) -> String? {
        guard let row = tableRow(forAgentId: agentId),
              let cell = cellsByRow[row] as? AgentInbox96CellView else { return nil }
        return cell.settleNudgeTitleForQA
    }
    /// A click on the nudge's own button, through its target/action.
    func clickCloseNudgeForQA(agentId: UUID) -> Bool {
        guard let row = tableRow(forAgentId: agentId),
              let cell = cellsByRow[row] as? AgentInbox96CellView else { return false }
        return cell.clickSettleNudgeForQA()
    }
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
        case .openInTile, .unsettle, .wake, .markUnread, .rename, .generateName, .color, .stopAgent:
            return false
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

    // MARK: - Hidden sessions from elsewhere

    static let hideItemId = "external:hide"
    static let hiddenListItemId = "hidden:list"
    static let hiddenVerb = "Hidden"

    /// Where hidden sessions live; nil (checks, baselines) offers no Hide at all.
    var externalSessionHiding: ExternalSessionHiding? {
        // Re-installing the sidebar hands back the same store; a full render then
        // would rebuild every cell for nothing.
        didSet { if oldValue !== externalSessionHiding { refreshAfterHidingChange() } }
    }
    private var pendingHideUndo: Set<String>?
    private var hiddenListShown = false

    func hideExternalRows(_ ids: [UUID]) {
        guard let hiding = externalSessionHiding else { return }
        let sessions = ids.compactMap { id in allRows.first { $0.id == id } }
            .compactMap { row in row.externalSession.map { (key: $0.sessionKey, title: row.title) } }
            .filter { !hiding.isHidden($0.key) }
        guard !sessions.isEmpty else { return }
        hiding.hide(sessions)
        refreshAfterHidingChange()
        dismissUndoToast()
        pendingHideUndo = Set(sessions.map(\.key))
        undoToast.show(InboxUndoToast.message(verb: Self.hiddenVerb, count: sessions.count, snoozedUntil: nil))
        restartUndoToastTimer()
    }

    func showHiddenExternalSessions(_ keys: Set<String>) {
        externalSessionHiding?.show(keys)
        refreshAfterHidingChange()
    }

    func showAllHiddenExternalSessions() {
        externalSessionHiding?.showAll()
        hiddenListShown = false
        refreshAfterHidingChange()
    }

    private func refreshAfterHidingChange() {
        updateScopeMenu()
        render(display(from: allRows))
    }

    /// The Hidden list, in place of the scopes, the way a workspace's colours are.
    private func hiddenListItems(_ entries: [ExternalSessionHiding.Entry]) -> [ChoiceItem] {
        var back = ChoiceItem(id: "hidden:back", title: "Hidden from elsewhere", icon: .system("chevron.left"))
        back.keepsOpen = true
        var all = ChoiceItem(id: "hidden:all", title: "Show all", icon: .system("eye"))
        all.separatorBefore = true
        return [back] + entries.enumerated().map { index, entry in
            var item = ChoiceItem(id: "hidden:show:\(entry.sessionKey)", title: entry.title)
            item.trailing = "Show"
            item.keepsOpen = true
            item.separatorBefore = index == 0
            return item
        } + [all]
    }

    private func handleHiddenListChoice(_ item: ChoiceItem) -> Bool {
        switch item.id {
        case Self.hiddenListItemId:
            hiddenListShown = true
            updateScopeMenu()
        case "hidden:back":
            hiddenListShown = false
            updateScopeMenu()
        case "hidden:all":
            showAllHiddenExternalSessions()
        case let id where id.hasPrefix("hidden:show:"):
            showHiddenExternalSessions([String(id.dropFirst("hidden:show:".count))])
        default:
            return false
        }
        return true
    }

    /// ⌘Z on the list presses the toast's Undo while it is up.
    fileprivate func undoFromKeyboard() -> Bool {
        guard !undoToast.isHidden, pendingHideUndo != nil || pendingUndo != nil else { return false }
        performUndo()
        return true
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
        pendingHideUndo = nil
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
        if let keys = pendingHideUndo {
            dismissUndoToast()
            showHiddenExternalSessions(keys)
            return
        }
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

    /// Repaint hover on the cells already on screen. Rebuilding them, as a
    /// reload does, snaps every transition (the new cell has no window to
    /// animate in), replays arrival motion and would cancel a running fold.
    /// Rows not on screen read hover when they are built.
    private func applyHoverInPlace(tableRows indexes: [Int]) {
        var reload: [Int] = []
        for row in indexes where items.indices.contains(row) {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? AgentInboxRowCell,
                  let model = item(at: row)?.agentRow else { continue }
            let emphasis = AgentInboxRow.emphasis(
                for: model.state, attention: model.attention, isInteracting: isInteracting(row: row))
            guard cell.updateEmphasisInPlace(emphasis) else { reload.append(row); continue }
            cell.applyInteraction(interaction(forTableRow: row))
            if let card = cell as? AgentInbox96CellView {
                deckCells.add(card)
                if snapsDeck { card.snapDeck() }
            }
        }
        guard !reload.isEmpty else { return }
        // A variant that cannot repaint in place is rebuilt, and a fold in
        // flight keeps running over the replacement.
        tableView.reloadData(forRowIndexes: IndexSet(reload), columnIndexes: IndexSet(integer: 0))
        foldMotion.cover(reload.compactMap { tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) })
    }

    /// The cards hover has posed or is springing back: at most the hovered row
    /// and the one before it, so folding, scrolling and a Reduce Motion change
    /// touch only those and never walk the list.
    private let deckCells = NSHashTable<AgentInbox96CellView>.weakObjects()
    /// How many cards the fold photographs have caught out of their resting
    /// pose, ever. A photograph is what the presentation shows.
    private(set) var qaPosedDecksPhotographed = 0
    /// Set while the list moves under a still pointer: hover then lands its
    /// pose at once instead of springing.
    private var snapsDeck = false

    /// Rebuild the cells of just these rows, ignoring any that are not on screen.
    private func redraw(tableRows indexes: [Int]) {
        let touched = IndexSet(indexes.filter { items.indices.contains($0) })
        guard !touched.isEmpty else { return }
        foldMotion.cancel()
        tableView.reloadData(forRowIndexes: touched, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Row enter / exit motion (confidence pass, sidebar stream)

    static let rowMotionDuration: TimeInterval = 0.15
    static let rowMotionRowLimit = 40
    /// What the most recent animated render moved, for the witness.
    private(set) var qaLastRowMotion: (exiting: Set<UUID>, entering: Set<UUID>) = ([], [])
    private var exitGhostViews: [NSView] = []
    var qaLiveExitGhostCount: Int { exitGhostViews.count }

    /// Snapshots of the leaving rows' cells, at the rects they occupied, taken
    /// BEFORE the table reloads and loses them.
    private func liftExitGhosts(leaving: Set<UUID>) -> [(id: UUID, view: NSView)] {
        guard !leaving.isEmpty else { return [] }
        var ghosts: [(id: UUID, view: NSView)] = []
        for (index, row) in rows.enumerated() where leaving.contains(row.id) {
            guard let tableRow = tableRow(forRowIndex: index),
                  let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false),
                  cell.bounds.width > 0, cell.bounds.height > 0,
                  let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { continue }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            let image = NSImage(size: cell.bounds.size)
            image.addRepresentation(rep)
            let ghost = NSImageView(frame: tableView.rect(ofRow: tableRow))
            ghost.image = image
            ghost.imageScaling = .scaleNone
            ghost.setAccessibilityElement(false)
            ghosts.append((row.id, ghost))
        }
        return ghosts
    }

    private func startRowMotion(exits: [(id: UUID, view: NSView)], entering: Set<UUID>) {
        qaLastRowMotion = (Set(exits.map(\.id)), entering)
        for ghost in exits {
            tableView.addSubview(ghost.view)
            exitGhostViews.append(ghost.view)
        }
        tableView.layoutSubtreeIfNeeded()
        let arriving = entering.compactMap { id in
            tableRow(forAgentId: id).flatMap { tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) }
        }
        for view in arriving { view.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.rowMotionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for ghost in exits { ghost.view.animator().alphaValue = 0 }
            for view in arriving { view.animator().alphaValue = 1 }
        }
        // Teardown is SCHEDULED, for the reason the lifecycle crossfade records: a
        // completion handler that never fires would leave a ghost painted forever.
        let ghostViews = exits.map(\.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rowMotionDuration) { [weak self] in
            for view in arriving { view.alphaValue = 1 }
            for view in ghostViews { view.removeFromSuperview() }
            self?.exitGhostViews.removeAll { ghost in ghostViews.contains { $0 === ghost } }
            if self?.peekWorkspace != nil { self?.applyPeek(animated: false) }
        }
    }

    static let reflowDuration: TimeInterval = 0.18

    /// Each surviving card glides from the row it held to the row it holds now —
    /// a presentation-only offset on its layer, so the table's frames, hit-testing
    /// and accessibility are already final.
    private func slideSurvivors(from previousY: [UUID: CGFloat]) {
        for (index, row) in rows.enumerated() {
            guard let oldY = previousY[row.id], let tableRow = tableRow(forRowIndex: index),
                  let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false),
                  let layer = cell.layer else { continue }
            let delta = oldY - tableView.rect(ofRow: tableRow).minY
            guard abs(delta) > 0.5 else { continue }
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            // In the table's own flipped space: a cell's layer offset follows its
            // view's coordinates (filmed — the opposite sign rose into place).
            slide.fromValue = delta
            slide.toValue = 0
            slide.duration = Self.reflowDuration
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(slide, forKey: "scopeReflow")
        }
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
        setSearchFieldHovered(searchField.frame.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(agentId: nil)
        setSearchFieldHovered(false)
    }

    /// The search field's only resting affordance is that it lights up under the
    /// pointer, so this rides the tracking area the list already owns rather than
    /// adding a second one over the same pixels.
    private func setSearchFieldHovered(_ hovered: Bool) {
        guard hovered != isSearchFieldHovered else { return }
        isSearchFieldHovered = hovered
        applySearchFieldChrome()
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
        foldMotion.cancel()
        // The card is a child of the WINDOW, not of this view, so it does not
        // travel when the list is reparented or torn down — it would simply be
        // left behind, floating over a canvas describing a row that is gone.
        dismissHoverCard()
        let center = NotificationCenter.default
        // TOKENS, and never `removeObserver(self)`. The blanket form is one call
        // and it is wrong here: `NSView` and `NSTableView` register the view
        // itself as an observer of AppKit's own notifications, and removing those
        // took the table's deferred incremental reload with it — measured,
        // `--agent-inbox-check`: `selecting a row must clear its recession — text
        // alpha 0.88, wanted 1.0`, on a selection that had really moved.
        for token in interactionObservers {
            center.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        interactionObservers = []
        guard let window else {
            settleNudgeTimer?.invalidate()
            settleNudgeTimer = nil
            elapsedTickTimer?.invalidate()
            elapsedTickTimer = nil
            elapsedTickInterval = nil
            cancelWakeRerender()
            setHovered(agentId: nil)
            setKeyboardFocus(agentId: nil)
            return
        }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        interactionObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldMotion.cancel()
                // Scrolling removes the deck's springs: what moves is the list.
                for card in self.deckCells.allObjects { card.snapDeck() }
                self.snapsDeck = true
                self.refreshHoverFromPointer()
                self.snapsDeck = false
                self.syncElapsedTickTimer()
                self.window?.invalidateCursorRects(for: self.tableView)
            }
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
        // Increase Contrast can change while this view is alive. Repaint the
        // already-materialized row cards through the same production setting seam;
        // no row reload or animation is needed to preserve the semantic cue.
        interactionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.reapplyDisplayPreferences() }
        })
        reapplyDisplayPreferences()
        scheduleWakeRerender()
        settleNudgeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.settleNudgePeriod, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSettleNudge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleNudgeTimer = timer
        syncElapsedTickTimer()
    }

    /// The nudge's five-minute threshold is the only part of a card that changes
    /// with time alone (the elapsed clocks have their own tick), so a tick re-reads
    /// WHICH row carries it and repaints only a row that gains or loses it. It used
    /// to reload every row every 30 s: ~135 ms of a long session's main thread, a
    /// hitch twice a minute (.plans/81-live-performance). A row off screen is
    /// configured with the current target when it is next materialized.
    private func refreshSettleNudge() {
        let target = settleNudgeTargetID(now: clock())
        let stale = (0..<tableView.numberOfRows).filter { tableRow in
            guard let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                    as? AgentInbox96CellView,
                  let id = item(at: tableRow)?.agentRow?.id else { return false }
            return card.showsSettleNudge != (id == target)
        }
        redraw(tableRows: stale)
    }

    func fireSettleNudgeTickForQA() { refreshSettleNudge() }

    private func visibleTimedTableRows() -> [Int] {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { tableRow in
            guard items.indices.contains(tableRow),
                  let row = items[tableRow].agentRow else { return nil }
            let hasLiveClock = row.state == .working && row.elapsedStartedAt != nil
            let hasCompletionClock = AgentInbox96CellView.seenCompletionDate(row) != nil
            guard hasLiveClock || hasCompletionClock else { return nil }
            return tableRow
        }
    }

    private func visibleClockNeedsSecondCadence() -> Bool {
        visibleTimedTableRows().contains { tableRow in
            guard let row = items[tableRow].agentRow else { return false }
            return row.state == .working && row.elapsedStartedAt != nil
        }
    }

    private func syncElapsedTickTimer() {
        guard window != nil, !visibleTimedTableRows().isEmpty else {
            elapsedTickTimer?.invalidate()
            elapsedTickTimer = nil
            elapsedTickInterval = nil
            return
        }
        let interval: TimeInterval = visibleClockNeedsSecondCadence() ? 1 : 60
        if elapsedTickTimer != nil, elapsedTickInterval == interval { return }
        elapsedTickTimer?.invalidate()
        elapsedTickTimer = nil
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else {
                    self?.elapsedTickTimer?.invalidate()
                    self?.elapsedTickTimer = nil
                    self?.elapsedTickInterval = nil
                    return
                }
                let visible = self.visibleTimedTableRows()
                guard !visible.isEmpty else {
                    self.elapsedTickTimer?.invalidate()
                    self.elapsedTickTimer = nil
                    self.elapsedTickInterval = nil
                    return
                }
                self.updateVisibleElapsedClock(now: self.clock())
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        elapsedTickTimer = timer
        elapsedTickInterval = interval
    }

    private func updateVisibleElapsedClock(now: Date) {
        for tableRow in visibleTimedTableRows() {
            let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
            (cell as? AgentInbox96CellView)?.updateElapsedClock(now: now)
            // A Background row is slim and still timed (counted from the close).
            (cell as? AgentInboxSlimCellView)?.updateElapsedClock(now: now)
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
        applyHoverInPlace(tableRows: [tableRow(forAgentId: previous), tableRow(forAgentId: agentId)]
            .compactMap { $0 })
        // The card hangs off THIS, the one choke point, rather than off a tracking
        // area of its own. Everything that already nulls hover — the list
        // scrolling under a still pointer, the window resigning key, every full
        // re-render — therefore dismisses the card too, without any of it knowing
        // the card exists.
        updateHoverCard()
    }

    // MARK: - Hover card

    /// How long the pointer must rest before the card opens. T3's number, and it
    /// is the difference between a card that answers you and one that pounces.
    private static let hoverCardDwell: TimeInterval = 0.15
    /// After a card closes, the next one opens INSTANTLY for this long. Without
    /// it, running the pointer down the list re-serves the delay on every row and
    /// scanning feels like wading; with it, the first card costs 150ms and the
    /// rest are immediate.
    private static let hoverCardGrace: TimeInterval = 0.4
    private static let hoverCardGap: CGFloat = 4

    /// Nil-by-default, like the row and the header. Production hover is untouched,
    /// so `--sidebar-ux-check`'s hover ladder never sees this.
    var hoverCardEnabled = true {
        didSet { if !hoverCardEnabled { dismissHoverCard() } }
    }
    /// Injectable so a check can fire the dwell without sleeping — the shape
    /// `wakeRerenderScheduler` established.
    var hoverCardScheduler: WakeRerenderScheduler?
    /// The newest line the agent wrote, from the host (the supervisor's transcript
    /// projection). Asked only when a card opens, so hover reads no disk and runs
    /// no process; nil, or no host, draws no line.
    var latestAssistantLineProvider: ((UUID) -> String?)?
    private var hoverCard: InboxHoverCardView?
    private var hoverCardCancel: (() -> Void)?
    private var hoverCardClosedAt: Date?

    private func updateHoverCard() {
        hoverCardCancel?()
        hoverCardCancel = nil
        guard hoverCardEnabled, let id = hoveredAgentId,
              let row = rows.first(where: { $0.id == id })
        else {
            dismissHoverCard()
            return
        }
        let isOpen = hoverCard?.superview != nil
        let withinGrace = hoverCardClosedAt.map {
            clock().timeIntervalSince($0) <= Self.hoverCardGrace
        } ?? false
        guard !isOpen, !withinGrace else {
            presentHoverCard(for: row)
            return
        }
        let show: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.presentHoverCard(for: row) }
        }
        if let scheduler = hoverCardScheduler {
            hoverCardCancel = scheduler(Self.hoverCardDwell, show)
        } else {
            let work = DispatchWorkItem(block: show)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCardDwell, execute: work)
            hoverCardCancel = { work.cancel() }
        }
    }

    private func presentHoverCard(for row: AgentInboxRow) {
        guard hoverCardEnabled, hoveredAgentId == row.id,
              let contentView = window?.contentView,
              let anchor = hoverCardAnchor(for: row.id)
        else { return }

        let card = hoverCard ?? InboxHoverCardView(frame: .zero)
        hoverCard = card
        card.apply(title: row.displayTitle, lines: hoverCardLines(for: row))
        let size = card.intrinsicContentSize

        // Top-aligned with the row and just clear of the sidebar, then clamped so a
        // row near the bottom does not push the card off the window.
        var origin = NSPoint(
            x: anchor.maxX + Self.hoverCardGap,
            y: anchor.maxY - size.height)
        origin.x = min(origin.x, contentView.bounds.maxX - size.width - Self.hoverCardGap)
        origin.y = max(Self.hoverCardGap, min(origin.y, contentView.bounds.maxY - size.height))
        card.frame = NSRect(origin: origin, size: size)

        // A card still fading out is taken back rather than stacked on.
        let wasFading = hoverCardRemoval != nil
        hoverCardRemoval?.cancel()
        hoverCardRemoval = nil
        if wasFading, card.superview != nil {
            card.alphaValue = 1
            card.layer?.removeAnimation(forKey: Self.hoverCardFadeKey)
        }
        guard card.superview == nil else { return }
        contentView.addSubview(card)
        guard !prefersReducedMotion() else { return }
        card.animatePresentation(duration: Self.crossfadeDuration)
    }

    /// The card leaves over this long instead of vanishing mid-read.
    static let hoverCardFadeOut: TimeInterval = 0.12
    private static let hoverCardFadeKey = "inbox-hover-card-dismiss"
    private var hoverCardRemoval: DispatchWorkItem?

    private func dismissHoverCard() {
        hoverCardCancel?()
        hoverCardCancel = nil
        guard let card = hoverCard, card.superview != nil, hoverCardRemoval == nil else { return }
        hoverCardClosedAt = clock()
        guard !prefersReducedMotion(), window != nil, let layer = card.layer else {
            card.removeFromSuperview()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = Self.hoverCardFadeOut
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card.alphaValue = 0
        layer.add(fade, forKey: Self.hoverCardFadeKey)
        let removal = DispatchWorkItem { [weak self, weak card] in
            guard let self, let card, self.hoverCardRemoval != nil else { return }
            self.hoverCardRemoval = nil
            card.removeFromSuperview()
            card.alphaValue = 1
        }
        hoverCardRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCardFadeOut, execute: removal)
    }

    /// The hovered row's rect, in the window content view's coordinates.
    private func hoverCardAnchor(for id: UUID) -> NSRect? {
        guard let contentView = window?.contentView,
              let rect = tableRowFrameForQA(id: id) else { return nil }
        return contentView.convert(tableView.convert(rect, to: nil), from: nil)
    }

    /// Every line is optional and a missing fact draws nothing — a card padded
    /// with "Unknown" would be worse than a shorter card.
    private func hoverCardLines(for row: AgentInboxRow) -> [InboxHoverCardLine] {
        var lines: [InboxHoverCardLine] = []
        // What it is doing, then the last thing it said — the two questions a hover
        // over an agent is usually asking, ahead of where it lives.
        if let status = Self.hoverCardStatus(row, now: clock()) {
            lines.append(.init(symbol: "circle.dashed", text: status))
        }
        if let said = latestAssistantLineProvider?(row.id), !said.isEmpty {
            lines.append(.init(symbol: "text.bubble", text: said))
        }
        if let project = row.projectName, !project.isEmpty {
            lines.append(.init(symbol: "folder", text: project))
        }
        if let directory = row.directoryName, !directory.isEmpty,
           directory != row.projectName {
            lines.append(.init(symbol: "folder.badge.gearshape", text: directory))
        }
        if let zone = row.zoneName, !zone.isEmpty {
            lines.append(.init(symbol: "square.grid.2x2", text: zone))
        }
        lines.append(.init(symbol: "desktopcomputer", text: Self.hostName))
        if let branch = row.branch, !branch.isEmpty {
            lines.append(.init(symbol: "arrow.triangle.branch", text: branch))
        }
        if let checkedOut = row.checkedOutBranch {
            lines.append(.init(
                symbol: "exclamationmark.triangle.fill",
                text: "Checked out on \(checkedOut)", isWarning: true))
        }
        if let harness = row.harness, !harness.isEmpty {
            lines.append(.init(symbol: "terminal", text: harness))
        }
        if let model = row.model, !model.isEmpty {
            // The mark when we have one, the generic chip glyph when we do not —
            // never a two-character cipher.
            lines.append(.init(
                symbol: "cpu", mark: BrandMark96.mark(forModel: model), text: model))
        }
        if let last = row.lastActiveAt {
            lines.append(.init(symbol: "clock", text: Self.hoverCardTimestamp.string(from: last)))
        }
        return lines
    }

    /// The card's status line, in the row's own vocabulary (`stateWord`, and the
    /// live elapsed beside `Working`), so the card and the row cannot disagree. A
    /// finished turn you already saw drops its word on the ROW; the card still says
    /// `Done`, with when. An unconfirmed row claims no state, and neither does this.
    static func hoverCardStatus(_ row: AgentInboxRow, now: Date) -> String? {
        guard !row.isUnconfirmed else { return nil }
        let seenDone = AgentInbox96CellView.relativeCompletionText(row, now: now)
        guard let word = AgentInbox96CellView.stateWord(row, now: now) ?? seenDone.map({ _ in "Done" })
        else { return nil }
        let age = AgentInbox96CellView.stateAge(row, now: now).flatMap(AgentInboxCellView.elapsedText)
            ?? seenDone
        return [word, age].compactMap { $0 }.joined(separator: " · ")
    }

    /// The machine the agent is running on. One string for now, and honest:
    /// everything Array runs is local. It earns its place by being the line a
    /// remote environment will appear on rather than a line that has to be
    /// invented later.
    private static let hostName = Host.current().localizedName ?? "This Mac"

    /// POSIX and explicit, never `dateStyle`/`timeStyle`. The house rule is
    /// written out on `InboxUndoToast.wakeTimeFormatter`: a locale-dependent
    /// rendering makes an assertion depend on whose machine ran it.
    private static let hoverCardTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    /// Open and not on its way out: a card fading after its hover ended is
    /// already dismissed.
    var isHoverCardVisibleForQA: Bool { hoverCard?.superview != nil && hoverCardRemoval == nil }
    /// Still on screen, fading: the half of a dismissal a still image misses.
    var isHoverCardFadingOutForQA: Bool {
        hoverCard?.superview != nil && hoverCardRemoval != nil
            && hoverCard?.layer?.animation(forKey: Self.hoverCardFadeKey) != nil
    }
    var hoverCardFrameForQA: NSRect? { hoverCard?.superview == nil ? nil : hoverCard?.frame }
    var hoverCardLinesForQA: [String] { hoverCard?.qaLinesForQA ?? [] }
    var hoverCardTruncatedLinesForQA: [String] { hoverCard?.qaTruncatedLinesForQA ?? [] }
    var hoverCardBrandMarksAreTemplatesForQA: Bool {
        hoverCard?.qaBrandMarksAreTemplatesForQA ?? false
    }
    var hoverCardBrandMarkTintForQA: NSColor? { hoverCard?.qaBrandMarkTintForQA }

    /// The cursors the list's rows register, by running the table's real
    /// `resetCursorRects`. Empty means the system arrow.
    func rowCursorsForQA() -> [NSCursor] {
        guard let table = tableView as? AgentInboxTableView else { return [] }
        table.resetCursorRects()
        return table.registeredCursorsForQA
    }

    func modelToolTipsForQA(id: UUID) -> (layer: String?, markRect: NSRect?)? {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                as? AgentInbox96CellView else { return nil }
        return (card.qaDecorationsToolTipForQA, card.qaMarkToolTipRectForQA)
    }

    func settleNudgeForQA(id: UUID) -> AgentInbox96CellView.SettleNudgeForQA? {
        guard let tableRow = tableRow(forAgentId: id),
              let card = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                as? AgentInbox96CellView else { return nil }
        card.layoutSubtreeIfNeeded()
        return card.settleNudgeForQA()
    }

    func setProjectIconSources(_ roots: [UUID: URL]) {
        projectFaviconResolver.update(roots)
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
    /// The complete table row count, including explicit non-agent affordances.
    /// P6.5 uses this beside the materialized agent-cell count so a remainder
    /// cannot masquerade as a missing child.
    var tableRowCountForQA: Int { tableView.numberOfRows }
    var nonAgentTableRowCountForQA: Int {
        tableView.numberOfRows - rowCountForQA
    }
    var fanoutRemainderParentIDsForQA: Set<UUID> { Set(fanoutRemaindersByParent.keys) }
    var fanoutRemaindersByParentForQA: [UUID: FanoutRemainder] { fanoutRemaindersByParent }
    var fanoutRemainderTitlesForQA: [String] {
        items.compactMap { item in
            guard case let .fanoutRemainder(remainder) = item else { return nil }
            return remainder.title
        }
    }
    var fanoutRemainderRowsForQA: [FanoutRemainder] {
        items.compactMap { item in
            guard case let .fanoutRemainder(remainder) = item else { return nil }
            return remainder
        }
    }
    var fanoutRemainderAccessibilityLabelsForQA: [String] {
        fanoutRemainderCellsByParent.values.compactMap { $0.qaAccessibilityLabel }
    }
    var expandedFanoutParentsForQA: Set<UUID> { expandedFanoutParents }

    /// Press a real rendered remainder button, not the state mutation directly.
    @discardableResult
    func clickFanoutRemainderForQA(parentId: UUID) -> Bool {
        guard let cell = fanoutRemainderCellsByParent[parentId] else { return false }
        return cell.clickForQA()
    }

    /// Bring the real remainder row into the constrained viewport without asking
    /// the table to materialize every other row. The subsequent AX walk can inspect
    /// its button before the action removes that remainder from the list.
    @discardableResult
    func scrollToFanoutRemainderForQA(parentId: UUID) -> Bool {
        guard let tableRow = items.firstIndex(where: { item in
            guard case let .fanoutRemainder(remainder) = item else { return false }
            return remainder.parentId == parentId
        }) else { return false }
        tableView.scrollRowToVisible(tableRow)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        layoutViewportForQA()
        return fanoutRemainderCellsByParent[parentId] != nil
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
    func rowGeometryForQA(id: UUID) -> AgentInboxRowGeometryForQA? {
        qaMaterializedRowCells.first { $0.qaAgentID == id }?.qaGeometry
    }

    /// The cards tucked behind a folded parent, as its cell draws them, plus the
    /// cell itself (for hit-testing) and the row's frame in the table.
    func tuckedCardsForQA(id: UUID)
        -> (count: Int, rects: [NSRect], card: NSRect, cell: NSView, rowFrame: NSRect)? {
        guard let tableRow = tableRow(forAgentId: id),
              let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                as? AgentInbox96CellView else { return nil }
        cell.layoutSubtreeIfNeeded()
        let tucked = cell.qaTuckedCardsForQA
        return (tucked.count, tucked.rects, tucked.card, cell, tableView.rect(ofRow: tableRow))
    }
    var parentFoldChoicesForQA: [UUID: Bool] { foldChoices }
    /// Scroll the list the way a wheel does, through the clip view.
    func scrollListForQA(by dy: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + dy))
        scrollView.reflectScrolledClipView(clip)
    }
    /// The card the table is showing for row `id` right now, never one it builds.
    func onScreenCardForQA(id: UUID) -> AgentInbox96CellView? {
        guard let tableRow = tableRow(forAgentId: id) else { return nil }
        return tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false) as? AgentInbox96CellView
    }

    func groupBackgroundForQA(id: UUID) -> (visible: Bool, roundsTop: Bool, roundsBottom: Bool)? {
        guard let cell = qaMaterializedRowCells.first(where: { $0.qaAgentID == id }) else {
            return nil
        }
        if let cell = cell as? AgentInboxCellView {
            return (cell.qaGroupBackgroundVisibleForQA,
                    cell.qaGroupBackgroundCornersForQA.top,
                    cell.qaGroupBackgroundCornersForQA.bottom)
        }
        if let cell = cell as? AgentInbox96CellView {
            return (cell.qaGroupBackgroundVisibleForQA,
                    cell.qaGroupBackgroundCornersForQA.top,
                    cell.qaGroupBackgroundCornersForQA.bottom)
        }
        if let cell = cell as? AgentInboxSlimCellView {
            return (cell.qaGroupBackgroundVisibleForQA,
                    cell.qaGroupBackgroundCornersForQA.top,
                    cell.qaGroupBackgroundCornersForQA.bottom)
        }
        return nil
    }

    func disclosureTitleForQA(id: UUID) -> String? {
        qaMaterializedRowCells.first(where: { $0.qaAgentID == id })?.qaDisclosureTitle
    }

    var qaMaterializedRowCellCount: Int { qaMaterializedRowCells.count }


    /// Per-cell geometry and paint, in live-tree order. Every entry comes from a
    /// materialized row cell; no row model or expected token is substituted here.
    var qaRowGeometriesForQA: [AgentInboxRowGeometryForQA] {
        qaMaterializedRowCells.map(\.qaGeometry)
    }

    var rowIdsForQA: [UUID] { rows.map(\.id) }
    /// The block an agent is DRAWN in, read off the table's own items and the
    /// headings between them — `live`, `snoozed`, `history` — or nil
    /// when the table draws no row for it (scoped out, folded, or behind a shut
    /// heading). Confidence-pass sidebar witnesses assert on this, never on the
    /// row builder.
    func drawnBlockForQA(id: UUID) -> String? {
        var block = "live"
        for item in items {
            switch item {
            case .shelfHeader: block = "snoozed"
            case .historyHeader: block = "history"
            case .agent(let row) where row.id == id:
                // A bare view draws History inline under the other sections,
                // with no heading of its own: read the row's own section there.
                if block != "history", InboxSort.section(for: row.lifecycle, now: clock()) == .history {
                    return "history"
                }
                return block
            default: continue
            }
        }
        return nil
    }
    /// The drawn row's own value (variant, Background fact), for the same witnesses.
    func drawnRowForQA(id: UUID) -> AgentInboxRow? { rows.first { $0.id == id } }
    /// Every row the last push handed this view, before scope/search/fold shaping.
    /// Program 96/P0.1 reads these so a corpus can prove what the PRODUCTION join
    /// produced, then render those exact values in a deterministic probe host.
    var qaAllRowsForQA: [AgentInboxRow] { allRows }
    /// The live table index for an agent id, including the section rows that
    /// precede it. Native virtual AX children expose this same index even when
    /// the corresponding cell is outside the viewport.
    func tableRowIndexForQA(id: UUID) -> Int? { tableRow(forAgentId: id) }
    var accessibilityStatusAnnouncementMessagesForQA: [String] {
        qaStatusAnnouncements.map(\.message)
    }
    var accessibilityStatusAnnouncementOwnersForQA: [NSView] {
        qaStatusAnnouncements.map(\.owner)
    }
    func resetAccessibilityAnnouncementsForQA() {
        qaStatusAnnouncements.removeAll()
    }
    /// The current live accessibility hierarchy, rooted at the production inbox
    /// group. The probe walks the returned objects rather than a parallel model.
    var accessibilityChildrenForQA: [Any] { accessibilityChildren() ?? [] }
    /// The native NSTableView answer, including virtual children for rows that are
    /// outside the clipped viewport. This is deliberately read-only: the inbox
    /// never installs a materialized-cell replacement for this answer.
    var tableAccessibilityChildrenForQA: [Any] { tableView.accessibilityChildren() ?? [] }
    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The heading as RENDERED — its words and which way its triangle points — and
    /// nil when the shelf is holding nothing and draws no heading at all.
    var shelfHeaderTitleForQA: String? { shelfHeaderCell?.qaTitle }
    var shelfHeaderDisclosureForQA: String? { shelfHeaderCell?.qaDisclosureGlyph }
    var isShelfExpandedForQA: Bool { shelfExpanded }
    var shelfSpacerHeightForQA: CGFloat { shelfSpacerHeight }
    /// The table row a heading draws at, for the bottom-pinning witness.
    func tableRowFrameOfShelfHeadingForQA() -> NSRect? {
        guard let row = items.firstIndex(where: \.isShelfHeading) else { return nil }
        return tableView.rect(ofRow: row)
    }
    var tableViewportHeightForQA: CGFloat { scrollView.contentView.bounds.height }
    /// The header's three controls, in this view's coordinates.
    var headerFramesForQA: (search: NSRect, scope: NSRect, newAgent: NSRect?, listTop: CGFloat) {
        (searchField.frame, scopeButton.frame,
         // The ALIGNMENT rect: the constraints place it, and NSButton pads its
         // frame beyond it.
         newAgentButton.isHidden ? nil : newAgentButton.alignmentRect(forFrame: newAgentButton.frame),
         scrollView.frame.maxY)
    }
    func clickNewAgentForQA() -> Bool {
        guard !newAgentButton.isHidden, newAgentButton.isEnabled else { return false }
        newAgentButton.performClick(nil)
        return true
    }
    var lastTableRowMaxYForQA: CGFloat? {
        items.isEmpty ? nil : tableView.rect(ofRow: items.count - 1).maxY
    }
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
    // Ticket: .plans/05-close-to-history.md
    /// The History heading as RENDERED, where it sits, and whether it is open —
    /// nil when nothing has been closed and no heading is drawn.
    var historyHeaderTitleForQA: String? { historyHeaderCell?.qaTitle }
    var historyHeaderDisclosureForQA: String? { historyHeaderCell?.qaDisclosureGlyph }
    var isHistoryExpandedForQA: Bool { historyExpanded }
    var historyHeaderTableRowForQA: Int? { historyHeaderTableRow }
    /// Every section heading the table draws, top to bottom, in its own words.
    var shelfHeadingTitlesForQA: [String] {
        items.compactMap { item -> String? in
            switch item {
            case .shelfHeader(let count, _):
                return AgentInboxShelfHeaderView.title(section: .snoozed, count: count)
            case .historyHeader(let count, _):
                return AgentInboxShelfHeaderView.title(section: .history, count: count)
            default:
                return nil
            }
        }
    }
    /// Open History without a click, for harnesses that read every row.
    func expandHistoryShelfForQA() {
        guard !historyExpanded else { return }
        toggleHistory()
    }
    #if ARRAY_FILM
    /// Film build only: the heading cell a pointer clicks to open History.
    var filmHistoryHeaderCell: NSView? { historyHeaderCell }
    /// Film build only: the live cell drawing this agent's row, or nil when the table
    /// has not materialized it (scrolled away, filtered out).
    func filmRowCell(id: UUID) -> NSView? {
        tableRowByAgentId[id].flatMap { tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) }
    }
    /// Film build only: one tick of the shared elapsed clock, on demand (the film
    /// advances frames, not seconds, so it cannot wait for the 1 s timer).
    func filmTickElapsedClock() { updateVisibleElapsedClock(now: clock()) }
    #endif
    /// Open or close History the way the user does — through the heading's own
    /// button, so the check exercises the wiring and not just `toggleHistory`.
    @discardableResult
    func clickHistoryDisclosureForQA() -> Bool {
        historyHeaderCell?.clickDisclosureForQA() ?? false
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
    var hasElapsedTickTimerForQA: Bool { elapsedTickTimer != nil }
    var elapsedTickIntervalForQA: TimeInterval? { elapsedTickInterval }
    func updateElapsedClockForQA(now: Date) { updateVisibleElapsedClock(now: now) }
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
    var scopeTitlesForQA: [String] { scopeMenuEntries.map(\.title) }
    var scopeMenuEntriesForQA: [InboxScopeMenuEntry] { scopeMenuEntries }
    var scopeTriggerTitleForQA: String { scopeButton.qaRenderedTitle }
    var scopeTriggerSwatchCountForQA: Int { scopeButton.leadingSwatches.count }
    var marksWorkspacesForQA: Bool { marksWorkspaces }
    var selectedScopeTitleForQA: String { scope.title }
    var searchQueryForQA: String { searchQuery }
    var searchResultCountForQA: Int { rows.count }
    var scopeControlWidthForQA: CGFloat { scopeButton.bounds.width }
    var scopeButtonForQA: ChoiceButton { scopeButton }
    var searchFieldViewForQA: NSTextField { searchField }
    var searchFieldFrameForQA: NSRect { searchField.frame }
    var searchTextDrawingRectForQA: NSRect {
        searchField.cell?.drawingRect(forBounds: searchField.bounds) ?? .zero
    }
    var searchTextMeasuredHeightForQA: CGFloat {
        searchField.cell?.cellSize(forBounds: searchField.bounds).height ?? 0
    }
    var searchIconFrameInFieldForQA: NSRect {
        searchIcon.convert(searchIcon.bounds, to: searchField)
    }
    var searchLeadingInsetForQA: CGFloat {
        (searchField.cell as? InsetTextFieldCell)?.leadingInset ?? 0
    }
    var scopeControlFrameForQA: NSRect { scopeButton.frame }
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
        guard scopeMenuEntries.contains(where: { $0.id == scope.storageValue }) else { return false }
        return scopeButton.chooseForQA(id: scope.storageValue)
    }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P6.3-snooze-derived-wake.md
    /// Timer state is read from the live production scheduler seam, not from a
    /// second QA timer. The scheduler callback itself is injected only by the
    /// deterministic check; production leaves it nil and uses Foundation.Timer.
    var hasWakeRerenderTimerForQA: Bool {
        wakeRerenderCancellation != nil || wakeRerenderTimer != nil
    }
    var scheduledWakeDelayForQA: TimeInterval? { scheduledWakeDelay }
    var wakeRerenderCountForQA: Int { qaWakeRerenderCount }

    /// Open the real snooze preset path without requiring an attached window. The
    /// list and its callback are the same `presentSnoozeOptions` production builds
    /// for a row or bulk action; only the panel chrome is absent offscreen.
    @discardableResult
    func openSnoozeMenuForQA(ids: [UUID]) -> Bool {
        guard !ids.isEmpty,
              ids.allSatisfy({ id in rows.contains { row in row.id == id } }) else { return false }
        presentSnoozeOptions(for: ids, anchor: .zero, relativeTo: self)
        return !(qaSnoozeChoiceListForQA?.qaItems.isEmpty ?? true)
    }

    var snoozeOptionTitlesForQA: [String] {
        qaSnoozeChoiceListForQA?.qaItems.map(\.title)
            ?? rowChoiceController.listView?.qaItems.map(\.title)
            ?? []
    }

    @discardableResult
    func pickSnoozePresetForQA(_ preset: SnoozePreset) -> Bool {
        let list = qaSnoozeChoiceListForQA ?? rowChoiceController.listView
        guard let list, list.qaItems.contains(where: { $0.id == preset.rawValue && $0.enabled }) else {
            return false
        }
        list.choose(id: preset.rawValue)
        return true
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

    /// The title AppKit is really drawing for a verb, reason suffix and all.
    func renderedWorkspaceManagementTitleForQA(_ action: WorkspaceManagementAction) -> String {
        managementItems[action]?.title ?? ""
    }

    /// Whether the separator really sits between the scopes and the verbs — the
    /// packet's "separated section", asserted on the menu rather than by eye.
    /// The verbs follow every scope row, and the checklist draws its divider above
    /// the first of them (.plans/86).
    var isWorkspaceManagementSeparatedForQA: Bool {
        let items = scopeButton.items
        guard let first = items.firstIndex(where: { $0.id.hasPrefix("management:") }) else { return false }
        return items[first].separatorBefore
            && items[first...].allSatisfy { $0.id.hasPrefix("management:") }
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
    /// Where each agent row sits in the tree, index-aligned with `rowHeightsForQA`:
    /// a group's last row (and a root followed by a root) is laid out taller by
    /// the trailing gap its cell reserves below the content.
    var rowNestingsForQA: [InboxNesting] {
        (0..<tableView.numberOfRows)
            .filter { rowIndex(forTableRow: $0) != nil }
            .map { nesting(atTableRow: $0) }
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

    /// The live table height of a particular remainder affordance. Remainders are
    /// keyed by parent id rather than their after-row anchor, because nested
    /// remainders can share that anchor while remaining distinct controls.
    func fanoutRemainderHeightForQA(parentId: UUID) -> Double? {
        guard let tableRow = items.firstIndex(where: { item in
            guard case let .fanoutRemainder(remainder) = item else { return false }
            return remainder.parentId == parentId
        }) else { return nil }
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
    // Ticket: .plans/0721-subagents-handoff.md
    /// THE GROUPING AS DRAWN. Every connector segment the list actually painted,
    /// in the TABLE's coordinates, tagged with the row that painted it.
    ///
    /// Table coordinates and not the cell's, deliberately: the claim this ticket
    /// makes is about where a group STOPS relative to the row below it, and that is
    /// a fact about two rows. A per-cell rect cannot state it, and a witness that
    /// recomputed the geometry from `depth` would be asserting its own arithmetic.
    var spinePaintingForQA: [(tableRow: Int, segment: InboxSpineSegment, rect: NSRect)] {
        var out: [(tableRow: Int, segment: InboxSpineSegment, rect: NSRect)] = []
        for row in 0..<tableView.numberOfRows {
            guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            else { continue }
            let segments: [InboxSpineSegment]
            switch view {
            case let card as AgentInbox96CellView: segments = card.qaSpineSegmentsForQA
            case let tail as AgentInboxRemainderView: segments = tail.qaSpineSegmentsForQA
            default: segments = []
            }
            for segment in segments {
                let local = NSRect(x: segment.minX, y: segment.minY,
                                   width: segment.width, height: segment.height)
                out.append((row, segment, view.convert(local, to: tableView)))
            }
        }
        return out
    }
    /// The rect the table gave each row, so a witness can say "below this row".
    var tableRowRectsForQA: [NSRect] {
        (0..<tableView.numberOfRows).map { tableView.rect(ofRow: $0) }
    }
    /// The disclosure control and the row title of every materialized card, in the
    /// TABLE's coordinates — the two things the reported defect put side by side.
    var disclosureFramesInTableForQA: [Int: NSRect] {
        var out: [Int: NSRect] = [:]
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? AgentInbox96CellView,
                  let frame = cell.qaDisclosureFrameForQA else { continue }
            out[row] = cell.convert(frame, to: tableView)
        }
        return out
    }
    var titleFramesInTableForQA: [Int: NSRect] {
        var out: [Int: NSRect] = [:]
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? AgentInbox96CellView else { continue }
            out[row] = cell.convert(cell.qaTitleFrameForQA, to: tableView)
        }
        return out
    }
    /// Where the `N more` row put its words. The remainder is a CHILD row, and this
    /// is the accessor that can say whether it was drawn like one.
    var remainderLabelFramesForQA: [Int: NSRect] {
        var out: [Int: NSRect] = [:]
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? AgentInboxRemainderView else { continue }
            out[row] = cell.qaLabelFrameForQA
        }
        return out
    }
    /// Where each materialized card's own card view was framed, in the TABLE's
    /// coordinates — the edge the elbow has to meet.
    var cardFramesInTableForQA: [Int: NSRect] {
        var out: [Int: NSRect] = [:]
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? AgentInbox96CellView else { continue }
            out[row] = cell.convert(cell.qaCardFrameForQA, to: tableView)
        }
        return out
    }
    /// WHAT THE TABLE ACTUALLY PAINTED at these points, in the table's own
    /// coordinates. Rendered offscreen with `cacheDisplay` — never to the display,
    /// which a check may not take (`docs/38-tickets` P0.4 / the runbook).
    ///
    /// Geometry accessors cannot answer one question this ticket turns on: the
    /// connector crosses the table's intercell spacing, which belongs to no cell, by
    /// drawing out of a subview deliberately larger than the cell that owns it. A
    /// rect can say that is continuous while `clipsToBounds` quietly makes the
    /// pixels dashed.
    func tableInkForQA(at points: [NSPoint]) -> [NSColor?] {
        let rect = tableView.bounds
        guard rect.width > 0, rect.height > 0,
              let rep = tableView.bitmapImageRepForCachingDisplay(in: rect) else {
            return points.map { _ in nil }
        }
        tableView.cacheDisplay(in: rect, to: rep)
        let scaleX = Double(rep.pixelsWide) / Double(rect.width)
        let scaleY = Double(rep.pixelsHigh) / Double(rect.height)
        return points.map { point in
            let x = Int(((Double(point.x) - Double(rect.minX)) * scaleX).rounded(.down))
            let y = Int(((Double(point.y) - Double(rect.minY)) * scaleY).rounded(.down))
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
            return rep.colorAt(x: x, y: y)
        }
    }
    /// The tree the list derived, row for row.
    var nestingsForQA: [InboxNesting] {
        (0..<tableView.numberOfRows).map { nesting(atTableRow: $0) }
    }
    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// The chord each row is ADVERTISING ("" for a row with no pill), read off the
    /// rendered pill rather than recomputed from the index.
    var jumpHintsForQA: [String] { cells().map(\.qaJumpHint) }
    /// Each card's hint pill and its label, in the card's coordinates.
    var jumpHintGeometryForQA: [(pill: NSRect, label: NSRect)] {
        cells().compactMap { ($0 as? AgentInbox96CellView)?.qaJumpHintGeometry }
    }
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
                guard !(view is InboxSettleNudgeButton) else { return }
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
    var disclosureTitlesForQA: [String] { cells().map(\.qaDisclosureTitle) }
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
    var bulkActionMenuTruncatedTitlesForQA: [String]? { bulkBar.qaActionMenuTruncatedRowTitles }
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
    var rowMenuAccessibilityRoleForQA: NSAccessibility.Role? {
        activeChoiceListForQA?.accessibilityRole()
    }
    var rowMenuAccessibilityLabelForQA: String? {
        activeChoiceListForQA?.accessibilityLabel()
    }
    var rowMenuAccessibilityChildrenForQA: [Any] {
        activeChoiceListForQA?.accessibilityChildren() ?? []
    }
    var isTableFirstResponderForQA: Bool { tableView.window?.firstResponder === tableView }

    @discardableResult
    func performRowMenuCommandForQA(_ command: ChoiceListCommand) -> Bool {
        guard let list = activeChoiceListForQA else { return false }
        list.perform(command)
        return true
    }

    @discardableResult
    func pickRowMenuItemForQA(id: String) -> Bool {
        guard let list = activeChoiceListForQA,
              list.qaItems.contains(where: { $0.id == id && $0.enabled }) else { return false }
        list.choose(id: id)
        return true
    }

    /// The scope popover's list as its rows would draw it, for a review sheet.
    func scopeChoiceListForQA() -> ChoiceListView {
        ChoiceListView(items: scopeButton.items, selectedID: nil, presentation: .checklist)
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

    /// Return to the top through the real clip-view path without materializing the
    /// rest of the document. Virtual-AX checks use this to make the first rows
    /// visible while keeping a later row genuinely offscreen.
    func scrollToTopForQA() {
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        layoutViewportForQA()
    }

    /// Scroll one agent into the constrained viewport through NSTableView's real
    /// row path. Unlike `layoutForQA`, this materializes only what the destination
    /// viewport needs, so an offscreen-announcement witness can prove that later
    /// cell creation does not replay a transition.
    @discardableResult
    func scrollToAgentForQA(id: UUID) -> Bool {
        guard let tableRow = tableRow(forAgentId: id) else { return false }
        tableView.scrollRowToVisible(tableRow)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        layoutViewportForQA()
        return cellsByRow[tableRow]?.qaAgentID == id
            && visibleAgentIdsForQA.contains(id)
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

    /// Lay out only the constrained viewport. Unlike `layoutForQA`, this never
    /// asks AppKit to make an offscreen row, so a virtual-AX check can prove that
    /// the native table exposes rows it has not materialized.
    func layoutViewportForQA() {
        layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateAccessibilityHierarchy()
    }

    /// Force the table to realise a cell for every row, so the accessors above
    /// describe the whole list and not just the part AppKit felt like laying out.
    /// The second list-owned layout pass is intentional: offscreen probes may create
    /// cells only after the first `view(atColumn:row:)` request, and their frames are
    /// not painted until the table lays those new hosts out.
    func layoutForQA() {
        layoutViewportForQA()
        for row in 0..<tableView.numberOfRows where cellsByRow[row] == nil {
            _ = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        tableView.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateAccessibilityHierarchy()
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
    case fanoutRemainder(FanoutRemainder)
    case shelfHeader(count: Int, isExpanded: Bool)
    // Ticket: .plans/05-close-to-history.md
    /// The `History (N)` heading. A separate case from `shelfHeader` even though
    /// one view draws both, because the two sections collapse independently and
    /// `identity` has to be able to tell their headings apart — otherwise a push
    /// that changed only the History count would be diffed against the shelf's.
    case historyHeader(count: Int, isExpanded: Bool)
    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// The footer under a paged History tail. A third KIND of row rather than a
    /// second use of the heading, for the reason the heading is not an agent: it
    /// carries a different number (what is hidden, not what a section holds) and it
    /// does a different thing when you press it.
    case settledMore(hidden: Int)
    /// The flexible row above the first shelf heading that pushes the shelves to
    /// the bottom of the sidebar.
    case shelfSpacer

    /// One of the two counted, collapsible headings.
    var isShelfHeading: Bool {
        switch self {
        case .shelfHeader, .historyHeader: return true
        case .agent, .fanoutRemainder, .settledMore, .shelfSpacer: return false
        }
    }

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
        case .fanoutRemainder(let remainder): return "fanout:\(remainder.identity)"
        case .shelfHeader(let count, let isExpanded): return "shelf:\(count):\(isExpanded)"
        case .historyHeader(let count, let isExpanded): return "history:\(count):\(isExpanded)"
        // P4.8: the hidden count is part of the footer's identity for the same
        // reason the shelf's is part of the heading's — an agent settling while the
        // tail is paged changes that number and nothing else, and the incremental
        // path repaints only the agent rows it was told about.
        case .settledMore(let hidden): return "more:\(hidden)"
        case .shelfSpacer: return "spacer"
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
    private var section: CountedSection = .snoozed
    var onToggle: (() -> Void)?

    /// The two counted, collapsible sections this one heading draws. Kept as a
    /// parameter rather than a second `TokenThemed` subclass: the widget is
    /// identical — triangle, word, count, full-width hit target — and a new themed
    /// view owes the appearance census a sweep surface, an adopted surface and an
    /// owner entry for nothing (`UIProbeAppearance.swift`).
    enum CountedSection {
        /// P4.7's shelf: parked work that is coming back.
        case snoozed
        /// Settled agents and agents whose tile you closed — one section
        /// (.plans/05-close-to-history.md; decisions pass, "one history shelf").
        case history

        var word: String {
            switch self {
            case .snoozed: return "Snoozed"
            case .history: return "History"
            }
        }

        /// What VoiceOver reads for the count, in the same words the section uses.
        var spokenNoun: String {
            switch self {
            case .snoozed: return "snoozed"
            case .history: return "in History"
            }
        }

        var accessibilityHelp: String {
            switch self {
            case .snoozed: return "Shows or hides snoozed agents"
            case .history: return "Shows or hides agents in History"
            }
        }
    }

    /// What the heading says. `(N)` and not "N snoozed": the word is the section and
    /// the number is what it is holding, which is the order a scanning eye wants them
    /// in — and it stays one short line at sidebar width however large N gets.
    static func title(section: CountedSection = .snoozed, count: Int) -> String {
        "\(section.word) (\(count))"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleClicked)
        // The full-width hit button is the single AX control for this heading;
        // exposing the decorative triangle as a second button would duplicate the
        // same action in VoiceOver navigation.
        disclosureButton.setAccessibilityElement(false)

        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)

        hitButton.isBordered = false
        hitButton.title = ""
        hitButton.target = self
        hitButton.action = #selector(toggleClicked)
        hitButton.setAccessibilityElement(true)
        hitButton.setAccessibilityRole(.button)
        hitButton.setAccessibilityHelp("Shows or hides snoozed agents")
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

    func apply(section: CountedSection = .snoozed, count: Int, isExpanded: Bool) {
        self.count = count
        self.section = section
        label.stringValue = AgentInboxShelfHeaderView.title(section: section, count: count)
        hitButton.setAccessibilityHelp(section.accessibilityHelp)
        disclosureButton.show(isExpanded ? .expanded : .collapsed)
        let action = isExpanded ? "Collapse" : "Expand"
        hitButton.setAccessibilityLabel("\(action) \(label.stringValue)")
        hitButton.setAccessibilityValue("\(count) \(section.spokenNoun), \(isExpanded ? "expanded" : "collapsed")")
        hitButton.setAccessibilityExpanded(isExpanded)
        hitButton.setAccessibilityEnabled(true)
        setAccessibilityChildren([hitButton])
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
    var qaDisclosureTitle: String { disclosureButton.qaTitle }
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
    /// remain: `Show 25 more (20 hidden)` — less the word "settled", which stopped
    /// being true once History held closed agents too (decisions pass). Clamping the first number to what
    /// is left reads better and was written that way first — but the packet spells
    /// this string out, so the clamp is a product change nobody asked for, and it
    /// belongs to the owner rather than to this ticket. The second number already
    /// says exactly how many rows a press produces when it is the smaller one.
    static func title(hidden: Int) -> String {
        "Show \(InboxSort.settledPageStep) more (\(hidden) hidden)"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)

        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false

        hitButton.isBordered = false
        hitButton.title = ""
        hitButton.target = self
        hitButton.action = #selector(pressed)
        hitButton.setAccessibilityElement(true)
        hitButton.setAccessibilityRole(.button)
        hitButton.setAccessibilityHelp("Shows more agents from History")
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
        hitButton.setAccessibilityValue("\(hidden) agents hidden")
        hitButton.setAccessibilityEnabled(true)
        setAccessibilityChildren([hitButton])
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

// Ticket: docs/38-tickets/94-sidebar-native-ux/P6.5-child-fanout-attention-rollup.md
/// The explicit non-agent remainder under a capped parent. It is deliberately a
/// separate table item: it cannot be selected, renamed, counted as an agent or
/// handed to lifecycle/resource actions. Its button expands the parent's complete
/// child set through the same live target/action path the other inbox affordances
/// use.
@MainActor
final class AgentInboxRemainderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(frame: .zero)
    private var remainder: FanoutRemainder?
    var onExpand: (() -> Void)?
    // Ticket: .plans/0721-subagents-handoff.md
    /// The connector, and the two constraints the nesting moves.
    ///
    /// THIS ROW USED TO LIE ABOUT ITS PLACE. "N more" is the tail of a CHILD set,
    /// and it was pinned flat to `Inset.row.left` with no indent at all — so the
    /// hidden children of a nested parent advertised themselves at the leading edge,
    /// reading as one more top-level agent.
    private let spine = InboxSpineView()
    private let groupBackground = InboxGroupBackgroundView()
    private var labelLeading: NSLayoutConstraint?
    private var labelCentre: NSLayoutConstraint?
    private var nesting: InboxNesting = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)

        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        button.isBordered = false
        button.title = ""
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp("Shows the hidden child agents")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(expandClicked)
        groupBackground.translatesAutoresizingMaskIntoConstraints = false
        spine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(groupBackground)
        addSubview(button)
        addSubview(label)
        addSubview(spine)
        let leading = label.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Inset.row.left)
        let centre = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        labelLeading = leading
        labelCentre = centre
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Inset.row.right),
            centre,
        ])
        applyTokens()
    }

    required init?(coder: NSCoder) { return nil }

    func apply(remainder: FanoutRemainder) {
        self.remainder = remainder
        label.stringValue = remainder.title
        button.setAccessibilityLabel("Show \(remainder.accessibilityTitle)")
        button.setAccessibilityValue(remainder.accessibilityTitle)
        button.setAccessibilityEnabled(true)
        setAccessibilityChildren([button])
        applyTokens()
    }

    private func applyTokens() {
        label.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    @objc private func expandClicked() { onExpand?() }

    // Ticket: .plans/0721-subagents-handoff.md
    /// Where this remainder sits in the tree — it is a member of its parent's
    /// group, so it takes the group's indent and the group's connector, and it can
    /// be the row a group ENDS on.
    func setNesting(_ nesting: InboxNesting) {
        guard nesting != self.nesting else { return }
        self.nesting = nesting
        let metrics = AgentInbox96CellView.spineMetrics
        labelLeading?.constant = Inset.row.left
            + Double(nesting.depth) * metrics.indentPerLevel
        // The extra room a group's last row gets is BELOW the content, exactly as
        // it is on a card, so the words do not drift off the list's rhythm.
        labelCentre?.constant = -metrics.trailingGap(nesting) / 2
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let metrics = AgentInbox96CellView.spineMetrics
        let content = Double(bounds.height) - metrics.trailingGap(nesting)
        let bleed = CGFloat(AgentInboxView.rowSpacing) / 2
        clipsToBounds = false
        groupBackground.clipsToBounds = false
        groupBackground.frame = bounds.insetBy(dx: 0, dy: -bleed)
        groupBackground.show(
            nesting, hasChildren: false, metrics: metrics,
            rowHeight: bounds.height + bleed * 2)
        spine.clipsToBounds = false
        spine.frame = bounds.insetBy(dx: 0, dy: -bleed)
        spine.show(
            nesting, metrics: metrics, cardTop: Double(bleed), cardHeight: max(1, content),
            rowHeight: Double(bounds.height) + Double(AgentInboxView.rowSpacing))
    }

    var qaSpineSegmentsForQA: [InboxSpineSegment] { spine.qaSegmentsForQA }
    var qaLabelFrameForQA: NSRect { label.convert(label.bounds, to: self) }
    @discardableResult
    func clickForQA() -> Bool {
        guard remainder != nil else { return false }
        button.performClick(nil)
        return true
    }

    var qaParentID: UUID? { remainder?.parentId }
    var qaTitle: String { label.stringValue }
    var qaAccessibilityLabel: String? { button.accessibilityLabel() }
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

    /// Re-recede or restore the row's words without rebuilding it — the one
    /// part of `apply` that depends on hover. Answers false when the variant
    /// cannot, and the list reloads the row instead.
    func updateEmphasisInPlace(_ emphasis: RowEmphasis) -> Bool

    /// Increase Contrast changes the strength of a semantic interaction fill, not
    /// the row's state or hierarchy. It is set separately so a live accessibility
    /// preference change repaints existing cells without re-deriving row content.
    func setIncreasedContrast(_ enabled: Bool)

    /// The one view that owns status-transition announcements. Elapsed/time labels
    /// deliberately do not implement this role.
    var accessibilityStatusOwner: NSView { get }

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
    /// The PROVIDER mark as rendered, distinct from `qaGlyph` (which is the status
    /// glyph). Read off the label so a witness cannot pass by re-deriving
    /// `AgentProviderGlyph` while the row paints something else. Program 96/P0.1.
    var qaProviderGlyph: String { get }
    /// The PLACEMENT band as rendered. Distinct from `qaMeta`, which composes
    /// isolation and child rollup rather than where the agent lives. Program 96/P0.1.
    var qaProject: String { get }
    var qaTextAlpha: Double { get }
    var qaAccentAlpha: Double { get }
    var qaGlyphAlpha: Double { get }
    var qaIndent: Double { get }
    var qaDisclosureGlyph: String { get }
    var qaDisclosureTitle: String { get }
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

extension AgentInboxRowCell {
    func updateEmphasisInPlace(_ emphasis: RowEmphasis) -> Bool { false }
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

/// The identity colour dot on a slim row: one filled circle in a palette tint.
/// Not `TokenThemed` — the tint is a user-chosen zone colour outside
/// `DesignTokens`, and the row that owns it repaints it on every apply. Its
/// baseline is its bottom edge, so in the row's first-baseline stack a 6pt dot
/// sits on the name's baseline and fills its x-height.
@MainActor
final class InboxIdentityDotView: NSView {
    var colour: NSColor? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var firstBaselineOffsetFromTop: CGFloat { bounds.height }
    override var intrinsicContentSize: NSSize {
        NSSize(width: AgentInboxView.identityDotSide, height: AgentInboxView.identityDotSide)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let colour else { return }
        colour.setFill()
        NSBezierPath(ovalIn: bounds).fill()
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
    private var childCount = 0

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        font = .token(.label)
        // The glyph is the whole control, so it must not be squeezed out of a
        // narrow sidebar the way a truncating label can be.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { return nil }

    func show(_ disclosure: RowDisclosure, childCount: Int = 0) {
        isHidden = disclosure == .none
        glyph = disclosure.glyph
        self.childCount = disclosure == .none ? 0 : max(0, childCount)
        let expanded = disclosure == .expanded
        setAccessibilityElement(disclosure != .none)
        let verb = disclosure == .collapsed ? "Expand" : "Collapse"
        setAccessibilityLabel(self.childCount > 0 ? "\(verb) \(self.childCount) subagents" : verb)
        setAccessibilityValue(disclosure == .none ? nil : "\(self.childCount) subagents, \(expanded ? "expanded" : "collapsed")")
        setAccessibilityExpanded(expanded)
        setAccessibilityEnabled(disclosure != .none)
        applyTokens()
    }

    /// `textSecondary`, the same token the row's own metadata uses: the triangle is
    /// chrome, and an accent here would be a fourth colour meaning in a list P3.2
    /// holds to three.
    func applyTokens() {
        attributedTitle = NSAttributedString(
            string: childCount > 0 ? "\(glyph) \(childCount)" : glyph,
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
    var qaTitle: String { attributedTitle.string }
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
        // Corner style (Settings › Appearance): re-resolved on every repaint.
        layer?.cornerRadius = Radius.card
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
    var qaLabelFrame: NSRect { label.frame }
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

    var icon: ChoiceIcon {
        switch self {
        case .settle: return .system("checkmark.circle")
        case .snooze: return .system("clock")
        case .markUnread: return .system("envelope.badge")
        case .archive: return .system("archivebox")
        case .delete: return .system("trash")
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
    ///   * **A blocked row cannot be settled.** The row's Core-built blocker fact covers
    ///     a pending human request, a live runner and an unadopted prompt grace window;
    ///     blockers outrank an explicit settle (`_RUNBOOK.md`). Settling one would take
    ///     the row out of the attention flow while work or a request is still live. It
    ///     can still be SNOOZED: deferring a request is a decision, and P4.6 exists
    ///     exactly for the snoozed agent that raises its hand again.
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
    /// Only `.settle` consults the row's canonical settlement predicate. Archive and
    /// delete are refused for a RUNNING row, and extending those to descendants is
    /// P2D.6's question about what a fan-out means, not this packet's. The row carries
    /// the Core blocker decision; this function only adds the derived child rollup.
    func isAvailable(for row: AgentInboxRow, rollups: [UUID: ChildRollup] = [:]) -> Bool {
        switch self {
        case .settle:
            return row.canSettle(rollup: rollups[row.id])
        case .snooze:
            // P6.3: a working row is a visibility target, but a pending human
            // request is not. The descendant rollup is the parent equivalent of
            // approval/input; the host re-checks the unadopted-prompt grace case
            // against the live supervisor before writing either snooze date.
            return !InboxBulkAction.isArchived(row)
                && row.state != .approval
                && row.state != .input
                && (rollups[row.id]?.needsYou ?? 0) == 0
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
    case color
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
        case .color: return "Color"
        case .stopAgent: return "Stop Agent"
        case .archive: return "Archive"
        case .delete: return "Delete"
        }
    }

    var icon: ChoiceIcon {
        switch self {
        case .openInTile: return .system("rectangle.on.rectangle")
        case .settle: return .system("checkmark.circle")
        case .unsettle: return .system("arrow.uturn.backward.circle")
        case .snooze: return .system("clock")
        case .wake: return .system("sun.max")
        case .markUnread: return .system("envelope.badge")
        case .rename: return .system("pencil")
        case .generateName: return .system("sparkles")
        case .color: return .system("paintpalette")
        case .stopAgent: return .system("stop.circle")
        case .archive: return .system("archivebox")
        case .delete: return .system("trash")
        }
    }

    /// `Snooze` opens the preset list (P4.5) rather than acting, which is the same
    /// reason `InboxBulkAction.snooze` carries the arrow; `Color` opens the palette.
    var opensSubmenu: Bool { self == .snooze || self == .color }

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
        case .openInTile, .markUnread, .rename, .generateName, .color, .stopAgent: return nil
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
        // The colour is on the RECORD, like the name, so an archived row has none to set.
        case .color: return !InboxBulkAction.isArchived(row)
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
        case .openInTile, .snooze, .wake, .markUnread, .rename, .generateName, .color, .stopAgent,
             .archive, .delete:
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
            if row.settlementBlocked {
                switch row.state {
                case .approval, .input: return "is waiting on you."
                case .working: return "is still working."
                case .ready, .failed: return "has activity in flight."
                }
            }
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
        case .snooze:
            if row.state == .approval || row.state == .input
                || (rollups[row.id]?.needsYou ?? 0) > 0 {
                return "is waiting on you."
            }
            return "is archived."
        case .wake: return "is not snoozed."
        case .markUnread:
            return row.attention == .unread ? "is already unread." : "is archived."
        case .rename: return "is archived."
        case .generateName: return "is archived."
        case .color: return "is archived."
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
    /// The row's live-runner fact is first because it comes from that same supervisor
    /// snapshot and survives closing the tile. Otherwise THREE STATES, not one:
    /// `working` is obvious, and `approval`/`input` are a turn that
    /// is still running with the adapter holding a request open — `InboxState.state(for:)`
    /// lets a pending request override a `working` status, so a blocked agent is a live
    /// one. `ready` is the resting state ("the agent stopped and is waiting on you") and
    /// `failed` has already ended; neither has a runner to stop, and an item that would do
    /// nothing must not be live. An archived agent has no record left at all.
    private static func hasTurnInFlight(_ row: AgentInboxRow) -> Bool {
        guard !InboxBulkAction.isArchived(row) else { return false }
        // The supervisor's live-runner fact remains authoritative when a closed
        // tile's last rendered status is stale. Do not infer this from
        // `closingSince`: a child blocker can keep a parent's row Background
        // without leaving a runner on the parent itself.
        if row.hasLiveRunner { return true }
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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Bulk actions")
        setAccessibilityHelp("Actions for every selected agent")
        countLabel.font = .token(.label)
        countLabel.setAccessibilityElement(true)
        countLabel.setAccessibilityRole(.staticText)
        countLabel.setAccessibilityLabel("Selected agents")
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.popoverPresentation = .commands
        // An action is a command, not the trigger's selected value. Keeping the
        // neutral title here also keeps it stable while the host owns a modal confirm.
        actionButton.keepsSelectionForItem = { _ in true }
        actionButton.onSelection = { [weak self] item in self?.choose(item) }
        keptLabel.font = .token(.caption)
        keptLabel.lineBreakMode = .byTruncatingMiddle
        keptLabel.setAccessibilityElement(true)
        keptLabel.setAccessibilityRole(.staticText)
        keptLabel.setAccessibilityLabel("Unmerged work kept")
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
                       icon: $0.icon,
                       destructive: $0 == .delete || $0 == .archive)
        }
        // Installing items can select the first enabled item. Reset the presentation
        // afterward so the trigger title remains the stable "Actions" label.
        actionButton.setPresentationTitle(Self.menuTitle)
        actionButton.isHidden = actions.isEmpty
        countLabel.stringValue = Self.selectionText(count: selectionCount)
        keptLabel.stringValue = Self.keptText(branches: keptBranches)
        keptLabel.isHidden = keptLabel.stringValue.isEmpty
        setAccessibilityValue(Self.selectionText(count: selectionCount))
        setAccessibilityEnabled(true)
        setAccessibilityChildren(
            [countLabel, actionButton] + (keptLabel.isHidden ? [] : [keptLabel]))
        isHidden = false
        applyTokens()
    }

    func hide() {
        isHidden = true; actions = []
        setAccessibilityEnabled(false)
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
        // Corner style (Settings › Appearance): re-resolved on every repaint.
        layer?.cornerRadius = Radius.card
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
    /// Opens the real Actions menu, reads which rows ellipsize, and closes it.
    var qaActionMenuTruncatedRowTitles: [String]? {
        actionButton.presentPopover()
        defer { actionButton.dismissPopoverForQA() }
        return actionButton.qaTruncatedPresentedRowTitles
    }
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
    /// Settle's report names the place the agent went (decisions pass): one
    /// History shelf, so "Moved to History", and "Moved 3 to History" for three.
    static let settledVerb = "Moved to History"
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

    /// `Moved to History`, `Moved 3 to History`, `Snoozed until 18:00`,
    /// `Snoozed 3 until 18:00`.
    ///
    /// The count is dropped for one agent — "Snoozed 1" reads like an inventory — and
    /// the wake time is dropped when the action left none, which is every verb but
    /// snooze and a snooze whose date the host did not write.
    static func message(verb: String, count: Int, snoozedUntil: Date?) -> String {
        var text: String
        if verb == settledVerb {
            text = count > 1 ? "Moved \(count) to History" : verb
        } else {
            text = count > 1 ? "\(verb) \(count)" : verb
        }
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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Undo notification")
        setAccessibilityHelp("Reports the last reversible inbox action")

        messageLabel.font = .token(.label)
        messageLabel.setAccessibilityElement(true)
        messageLabel.setAccessibilityRole(.staticText)
        messageLabel.setAccessibilityLabel("Inbox action")
        messageLabel.setAccessibilityIdentifier("ContinuumAgentInboxUndoMessage")
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
        undoButton.setAccessibilityIdentifier("ContinuumAgentInboxUndoButton")
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
        setAccessibilityValue(message)
        setAccessibilityEnabled(true)
        setAccessibilityChildren([messageLabel, undoButton])
        isHidden = false
        applyTokens()
    }

    func hide() {
        isHidden = true
        setAccessibilityEnabled(false)
        setAccessibilityValue(nil)
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
        // Corner style (Settings › Appearance): re-resolved on every repaint.
        layer?.cornerRadius = Radius.card
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
        // Corner style (Settings › Appearance): re-resolved on every repaint.
        layer?.cornerRadius = Radius.card
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
        didSet { guard isSelected != oldValue else { return }; applyFill(fading: true) }
    }
    var isHovered = false {
        didSet { guard isHovered != oldValue else { return }; applyFill(fading: true) }
    }
    /// The fill the group's sheets already show under this card at rest.
    var underlayAlpha: CGFloat = 0 {
        didSet { guard underlayAlpha != oldValue else { return }; applyFill(fading: false) }
    }
    /// The agent whose tile is open — the loudest step, because it answers
    /// "where am I" from anywhere in the list.
    var isRouteActive = false {
        didSet { guard isRouteActive != oldValue else { return }; applyFill(fading: true) }
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
    /// Increase Contrast strengthens only the semantic interaction wash. Resting
    /// rows remain unfilled and the role ordering remains selected < hover < active.
    var usesIncreasedContrast = false {
        didSet { guard usesIncreasedContrast != oldValue else { return }; applyTokens() }
    }

    private let focusRing = InboxRowFocusRingView()
    /// The layer animation that carries an interaction fill change.
    static let fillFadeKey = "interaction-fill"

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
    static func interactionFill(
        for role: SidebarSurfaceRole, increasedContrast: Bool, theme: TokenTheme,
        underlay: CGFloat = 0
    ) -> CGColor? {
        guard role != .resting else { return nil }
        // A card over a group's sheets (a stacked parent, a child in an open
        // group) already shows `underlay` at rest. Step up from THAT, keeping
        // the ladder's order and spacing, or hover repaints the same colour.
        if underlay > 0 {
            let base = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
            let foreground = TextToken.textPrimary.color.resolved(for: theme)
            let step = role.emphasisAlpha - SidebarSurfaceRole.selected.emphasisAlpha + 0.025
                + (increasedContrast ? 0.015 : 0)
            let alpha = min(0.22, 1 - (1 - underlay) * (1 - step))
            return TokenColor(foreground.composited(over: base, alpha: alpha)).cgColor(for: theme)
        }
        guard increasedContrast else { return role.color.cgColor(for: theme) }
        // Use the existing semantic text/panel tokens and a stronger mix rather
        // than a new literal. The bounded +1.5pt step keeps every interaction
        // role louder while retaining the existing foreground floors: the light
        // active row's accentFailed pair is the limiting 4.5:1 case, so the
        // strongest fill may not exceed a 12% primary-over-panel mix.
        let base = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
        let foreground = TextToken.textPrimary.color.resolved(for: theme)
        let strengthenedAlpha = min(0.12, role.emphasisAlpha + 0.015)
        let mixed = foreground.composited(over: base, alpha: strengthenedAlpha)
        return TokenColor(mixed).cgColor(for: theme)
    }

    func applyTokens() { applyFill(fading: false) }

    /// How long an interaction change takes to cross-fade the fill. A colour
    /// change, not motion, so Reduce Motion keeps it.
    static let fillFadeDuration: CFTimeInterval = 0.12

    /// Paint the role's fill. A change of interaction on a card already on
    /// screen fades from whatever is presented now, so a quick pass over a row
    /// never jumps; a card still being built (no window) and an appearance flip
    /// paint at once.
    private func applyFill(fading: Bool) {
        guard let layer else { return }
        // Corner style (Settings › Appearance): re-resolved on every repaint.
        layer.cornerRadius = Radius.card
        let fill = Self.interactionFill(
            for: surfaceRole, increasedContrast: usesIncreasedContrast, theme: effectiveTokenTheme,
            underlay: underlayAlpha)
        let presented = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.backgroundColor = fill
        guard fading, window != nil, presented != fill else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = presented ?? fill?.copy(alpha: 0)
        fade.toValue = fill ?? presented?.copy(alpha: 0)
        fade.duration = Self.fillFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: Self.fillFadeKey)
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
    var qaUsesIncreasedContrast: Bool { usesIncreasedContrast }
}

/// One row's words, on the card that carries them.
final class AgentInboxCellView: NSTableCellView, AgentInboxRowCell {
    private let groupBackground = InboxGroupBackgroundView()
    private let spine = InboxSpineView()
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
    private var cardBottomConstraint: NSLayoutConstraint?
    private var nesting: InboxNesting = .none
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
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityHelp("Agent row")
        card.setAccessibilityElement(false)
        jumpHint.setAccessibilityElement(false)

        groupBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(groupBackground)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // Keep the connector above the card's hover/selection fill. It passes
        // hits through, so the row remains the only interaction target.
        spine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spine)

        projectLabel.font = .token(.caption)
        projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.setAccessibilityRole(.staticText)
        projectLabel.setAccessibilityLabel("Project")
        projectLabel.setAccessibilityIdentifier("ContinuumAgentInboxProjectLabel")

        titleLabel.font = .token(.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel("Agent name")
        titleLabel.setAccessibilityIdentifier("ContinuumAgentInboxTitleLabel")

        stateLabel.font = .token(.label)
        stateLabel.setAccessibilityRole(.staticText)
        stateLabel.setAccessibilityLabel("Status")
        stateLabel.setAccessibilityIdentifier("ContinuumAgentInboxStateLabel")

        elapsedLabel.font = .token(.captionMono)
        elapsedLabel.lineBreakMode = .byClipping
        // Elapsed is a changing fact, not an independent live region. The row
        // aggregate below carries it for VoiceOver without making every clock tick
        // a separate accessibility element/update.
        elapsedLabel.setAccessibilityElement(false)
        elapsedLabel.setAccessibilityIdentifier("ContinuumAgentInboxElapsedLabel")

        metaLabel.font = .token(.label)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setAccessibilityRole(.staticText)
        metaLabel.setAccessibilityLabel("Agent details")
        metaLabel.setAccessibilityIdentifier("ContinuumAgentInboxMetaLabel")

        // Middle, not tail: an `agent/<role>-<slug>` branch is identified by both
        // ends, the same reasoning `BranchChipNSView` records for its own label.
        branchLabel.font = .token(.label)
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setAccessibilityRole(.staticText)
        branchLabel.setAccessibilityLabel("Branch")
        branchLabel.setAccessibilityIdentifier("ContinuumAgentInboxBranchLabel")

        providerGlyphLabel.font = .token(.label)
        providerGlyphLabel.setAccessibilityIdentifier("ContinuumAgentInboxProviderLabel")
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
        let cardBottom = card.bottomAnchor.constraint(equalTo: bottomAnchor)
        cardBottomConstraint = cardBottom
        cardBottom.constant = -CGFloat(AgentInbox96CellView.trailingGap(for: .none))
        NSLayoutConstraint.activate([
            leading,
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            cardBottom,

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
        disclosureButton.show(disclosure, childCount: rollup?.children ?? 0)

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
        }
        // The status owner always carries the explanation, including why a disk
        // record is not confirmation. A confirmed cell restores the same explicit
        // role/value after AppKit recycles it for another row.
        stateLabel.setAccessibilityRole(.staticText)
        stateLabel.setAccessibilityLabel("Status")
        stateLabel.setAccessibilityValue(Self.statusAccessibilityValue(for: row))
        branchLabel.stringValue = AgentInboxCellView.branchText(branch: row.branch)
        branchLabel.isHidden = branchLabel.stringValue.isEmpty
        let rollupSummary: String?
        if disclosure == .collapsed {
            rollupSummary = rollup?.summary
        } else {
            rollupSummary = rollup?.cappedAttentionSummary
        }
        metaLabel.stringValue = AgentInboxCellView.metaText(
            isIsolated: row.isIsolated,
            hasBranch: !branchLabel.isHidden,
            rollup: rollup,
            rollupSummary: rollupSummary,
            showRollup: AgentInboxView.drawsRollup(disclosure: disclosure, rollup: rollup))
        metaLabel.isHidden = metaLabel.stringValue.isEmpty
        updateDetailSlotConstraints()

        let providerGlyph = AgentProviderGlyph.glyph(for: row.model) ?? ""
        let modelLabel = row.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        providerGlyphLabel.stringValue = providerGlyph
        providerGlyphLabel.isHidden = providerGlyph.isEmpty
        providerGlyphLabel.toolTip = modelLabel?.isEmpty == false ? modelLabel : nil
        providerGlyphLabel.setAccessibilityLabel(providerGlyphLabel.toolTip)
        providerGlyphLabel.setAccessibilityValue(modelLabel)
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

    /// The status wording is shared by the visible label, its AX value and the
    /// one announcement owner. In particular, an unconfirmed row never says only
    /// "Working" to assistive technology when the live snapshot is absent.
    static func statusAccessibilityValue(for row: AgentInboxRow) -> String {
        if row.isUnconfirmed {
            return "Unconfirmed: no live agent snapshot; last known status \(row.label ?? "Ready")"
        }
        return row.presentationLabel ?? "Ready"
    }

    /// The row/cell owns the name, every hidden fact, and the exact changing
    /// duration. Visible project/branch/meta/model facts stay on their one visible
    /// child owner; status stays on `stateLabel` and is never repeated here.
    private func accessibilityAggregate(for row: AgentInboxRow) -> String {
        var parts = ["Agent \(row.displayTitle)"]
        if let project = row.projectName, !project.isEmpty, projectLabel.isHidden {
            parts.append("Project \(project)")
        }
        if let branch = row.branch, !branch.isEmpty, branchLabel.isHidden {
            parts.append("Branch \(Self.branchText(branch: branch))")
        }
        if !metaLabel.stringValue.isEmpty, metaLabel.isHidden {
            parts.append("Details \(metaLabel.stringValue)")
        }
        if let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty,
           providerGlyphLabel.isHidden {
            parts.append("Model \(model)")
        }
        if let elapsed = AgentInboxCellView.elapsedText(row.elapsed) {
            parts.append(row.isUnconfirmed ? "last seen \(elapsed)" : "Elapsed \(elapsed)")
        }
        return parts.joined(separator: ", ")
    }

    private func updateAccessibilityPresentation() {
        guard let row = shown?.row else { return }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibilityAggregate(for: row))
        // The row aggregate is not a second status owner. Status is exposed only
        // by `stateLabel`; selection/expanded state use their dedicated AX flags.
        setAccessibilityValue(nil)
        setAccessibilityEnabled(true)
        setAccessibilitySelected(card.isSelected)
        setAccessibilityExpanded(shown?.disclosure == RowDisclosure.expanded)

        // The row aggregate owns the subject/name. Keeping the visible title out
        // of the child list avoids a second AX owner for the same fact.
        titleLabel.setAccessibilityElement(false)
        titleLabel.setAccessibilityValue(nil)
        projectLabel.setAccessibilityElement(!projectLabel.isHidden && !projectLabel.stringValue.isEmpty)
        projectLabel.setAccessibilityValue(projectLabel.stringValue)
        // Keep the status owner present even for the visual `ready` state, whose
        // word is intentionally omitted. Its AX value supplies the semantic state
        // without adding a fourth painted line to the parked/resting row.
        stateLabel.setAccessibilityElement(true)
        stateLabel.setAccessibilityRole(.staticText)
        let statusValue = Self.statusAccessibilityValue(for: row)
        stateLabel.setAccessibilityLabel("Status: \(statusValue)")
        stateLabel.setAccessibilityValue(statusValue)
        branchLabel.setAccessibilityElement(!branchLabel.isHidden && !branchLabel.stringValue.isEmpty)
        branchLabel.setAccessibilityValue(branchLabel.stringValue)
        metaLabel.setAccessibilityElement(!metaLabel.isHidden && !metaLabel.stringValue.isEmpty)
        metaLabel.setAccessibilityValue(metaLabel.stringValue)
        // `elapsedLabel` remains false in every state, including when it is drawn.
        elapsedLabel.setAccessibilityElement(false)
        providerGlyphLabel.setAccessibilityElement(
            !providerGlyphLabel.isHidden && !providerGlyphLabel.stringValue.isEmpty)
        disclosureButton.setAccessibilityElement(!disclosureButton.isHidden)
        var children: [NSView] = []
        for child in [projectLabel, stateLabel, metaLabel, branchLabel, providerGlyphLabel, disclosureButton]
            where child.isAccessibilityElement() && (!child.isHidden || child === stateLabel) {
            children.append(child)
        }
        setAccessibilityChildren(children)
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
        guard shown != nil else { return }
        updateAccessibilityPresentation()
    }

    override func layout() {
        super.layout()
        let metrics = AgentInbox96CellView.spineMetrics
        let bleed = CGFloat(AgentInboxView.rowSpacing) / 2
        let content = max(1, bounds.height - CGFloat(metrics.trailingGap(nesting)))
        groupBackground.clipsToBounds = false
        groupBackground.frame = bounds.insetBy(dx: 0, dy: -bleed)
        groupBackground.show(
            nesting, hasChildren: !disclosureButton.isHidden, metrics: metrics,
            rowHeight: bounds.height + bleed * 2)
        spine.clipsToBounds = false
        spine.frame = bounds.insetBy(dx: 0, dy: -bleed)
        spine.show(nesting, metrics: metrics, cardTop: Double(bleed),
                   cardHeight: Double(content),
                   rowHeight: Double(bounds.height) + Double(AgentInboxView.rowSpacing))
        applyFitTier()
    }

    func setNesting(_ nesting: InboxNesting) {
        self.nesting = nesting
        cardBottomConstraint?.constant = -CGFloat(
            AgentInbox96CellView.trailingGap(for: nesting))
        needsLayout = true
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

    func setIncreasedContrast(_ enabled: Bool) {
        card.usesIncreasedContrast = enabled
    }

    var accessibilityStatusOwner: NSView { stateLabel }

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
        rollup: ChildRollup? = nil,
        rollupSummary: String? = nil,
        showRollup: Bool = true
    ) -> String {
        let isolation = isIsolated ? "isolated" : (hasBranch ? "shared" : nil)
        let resolvedRollup = showRollup ? (rollupSummary ?? rollup?.summary) : nil
        return [resolvedRollup, isolation, remote]
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
            increasedContrast: card.qaUsesIncreasedContrast,
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
    var qaProviderGlyph: String {
        providerGlyphLabel.isHidden ? "" : providerGlyphLabel.stringValue
    }
    var qaProject: String { projectLabel.isHidden ? "" : projectLabel.stringValue }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    var qaAccentAlpha: Double { Double(stateLabel.alphaValue) }
    var qaGlyphAlpha: Double { Opacity.full }
    var qaIndent: Double { Double(leadingInset?.constant ?? 0) }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
    var qaDisclosureTitle: String { disclosureButton.qaTitle }
    var qaGroupBackgroundVisibleForQA: Bool { groupBackground.qaIsVisibleForQA }
    var qaGroupBackgroundCornersForQA: (top: Bool, bottom: Bool) {
        (groupBackground.qaRoundsTopForQA, groupBackground.qaRoundsBottomForQA)
    }
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
    private let groupBackground = InboxGroupBackgroundView()
    private let spine = InboxSpineView()
    private let jumpHint = InboxJumpHintView()
    private let disclosureButton = InboxDisclosureButton()
    var onToggleDisclosure: (() -> Void)?
    private let glyphLabel = NSTextField(labelWithString: "")
    /// The identity colour dot. An arranged view that is HIDDEN when the agent has
    /// no colour, and a hidden arranged view is detached from the stack: a row
    /// with no colour lays out exactly as it did before the dot existed.
    private let identityDot = InboxIdentityDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    /// The slim row's hover action (confidence pass): Wake on a snoozed row,
    /// Un-settle on a settled one, cross-fading over the time.
    private let hoverAction = InboxRowHoverActionButton(symbol: "arrow.uturn.backward", label: "Un-settle")
    /// Background rows expose restore and stop in the same status slot.
    private let backgroundStopAction = InboxRowHoverActionButton(symbol: "stop.fill", label: "Stop")
    private var pairedBackgroundStopTrailing: NSLayoutConstraint?
    private var soloBackgroundStopTrailing: NSLayoutConstraint?
    private var lineTrailingConstraint: NSLayoutConstraint?
    private var onHoverAction: (() -> Void)?
    private var onBackgroundStop: (() -> Void)?
    private var hoverActionShown = false
    private var layoutColumnWidth: Double?
    private var leadingInset: NSLayoutConstraint?
    private var cardBottomConstraint: NSLayoutConstraint?
    private var nesting: InboxNesting = .none
    private var branchMinimumWidth: NSLayoutConstraint?
    private var branchCollapsedWidth: NSLayoutConstraint?
    private var timeColumnWidth: NSLayoutConstraint?
    private var timeCollapsedWidth: NSLayoutConstraint?
    private var appliedTier: SlimRowFitTier?
    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis, disclosure: RowDisclosure,
                        isInteracting: Bool, now: Date)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityHelp("Agent row")
        card.setAccessibilityElement(false)
        jumpHint.setAccessibilityElement(false)

        card.translatesAutoresizingMaskIntoConstraints = false
        groupBackground.translatesAutoresizingMaskIntoConstraints = false
        spine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(groupBackground)
        addSubview(card)
        addSubview(spine)

        glyphLabel.font = .token(.label)
        glyphLabel.setAccessibilityRole(.image)
        glyphLabel.setAccessibilityLabel("Status")
        glyphLabel.setAccessibilityIdentifier("ContinuumAgentInboxStatusGlyph")
        glyphLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .token(.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel("Agent name")
        titleLabel.setAccessibilityIdentifier("ContinuumAgentInboxTitleLabel")
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
        branchLabel.setAccessibilityRole(.staticText)
        branchLabel.setAccessibilityLabel("Branch")
        branchLabel.setAccessibilityIdentifier("ContinuumAgentInboxBranchLabel")
        branchLabel.setContentCompressionResistancePriority(
            AgentInboxCellView.branchCompressionResistance, for: .horizontal)

        timeLabel.font = .token(.captionMono)
        timeLabel.lineBreakMode = .byClipping
        // The row/cell label carries the relative time; this child never becomes
        // an independent ticking accessibility element.
        timeLabel.setAccessibilityElement(false)
        timeLabel.setAccessibilityIdentifier("ContinuumAgentInboxTimeLabel")
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)

        // A parked group folds too: a snoozed parent and its snoozed children are
        // nested in the shelf the same way the live block nests. The line uses
        // measured tiers below rather than letting Auto Layout choose which
        // optional fact to squeeze.
        identityDot.isHidden = true
        let line = NSStackView(views: [disclosureButton, glyphLabel, identityDot, titleLabel, branchLabel, timeLabel])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.distribution = .fill
        line.spacing = Space.m
        line.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(line)

        let leading = card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        leadingInset = leading
        let cardTop = card.topAnchor.constraint(equalTo: topAnchor)
        let cardBottom = card.bottomAnchor.constraint(equalTo: bottomAnchor)
        cardBottomConstraint = cardBottom
        cardBottom.constant = -CGFloat(AgentInbox96CellView.trailingGap(for: .none))
        let pairedStop = backgroundStopAction.trailingAnchor.constraint(
            equalTo: hoverAction.leadingAnchor, constant: -Space.s)
        let soloStop = backgroundStopAction.trailingAnchor.constraint(
            equalTo: card.trailingAnchor, constant: -Inset.row.right)
        let lineTrailing = line.trailingAnchor.constraint(
            equalTo: card.trailingAnchor, constant: -Inset.row.right)
        pairedBackgroundStopTrailing = pairedStop
        soloBackgroundStopTrailing = soloStop
        lineTrailingConstraint = lineTrailing
        NSLayoutConstraint.activate([
            leading,
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardTop,
            cardBottom,

            line.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Inset.row.left),
            lineTrailing,
            // Centred, not pinned top-and-bottom: one line in a 35pt row, and a
            // centre constraint cannot leave the height ambiguous the way a
            // top+bottom pair on a flexible stack can.
            line.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            // The name's minimum includes the NSTextField cell inset. Optional
            // columns have matching zero-width constraints, so a dropped label
            // cannot keep reserving the room the tier just gave to the name.
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: AgentInboxCellView.minimumTextWidth(.title)),
            identityDot.widthAnchor.constraint(equalToConstant: AgentInboxView.identityDotSide),
            identityDot.heightAnchor.constraint(equalToConstant: AgentInboxView.identityDotSide),
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
        hoverAction.translatesAutoresizingMaskIntoConstraints = false
        hoverAction.target = self
        hoverAction.action = #selector(hoverActionClicked)
        hoverAction.alphaValue = 0
        hoverAction.isHidden = true
        card.addSubview(hoverAction)
        backgroundStopAction.translatesAutoresizingMaskIntoConstraints = false
        backgroundStopAction.target = self
        backgroundStopAction.action = #selector(backgroundStopClicked)
        backgroundStopAction.alphaValue = 0
        backgroundStopAction.isHidden = true
        card.addSubview(backgroundStopAction)
        NSLayoutConstraint.activate([
            hoverAction.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Inset.row.right),
            hoverAction.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            hoverAction.widthAnchor.constraint(equalToConstant: 20),
            hoverAction.heightAnchor.constraint(equalToConstant: 20),
            pairedStop,
            backgroundStopAction.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            backgroundStopAction.widthAnchor.constraint(equalToConstant: 20),
            backgroundStopAction.heightAnchor.constraint(equalToConstant: 20),
        ])

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

    func setNesting(_ nesting: InboxNesting) {
        self.nesting = nesting
        cardBottomConstraint?.constant = -CGFloat(
            AgentInbox96CellView.trailingGap(for: nesting))
        needsLayout = true
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
    ///   * BY DERIVATION — the production builder now derives the row's own lifecycle
    ///     from its record and read-time blocker facts. `settlementBlocked` keeps an
    ///     own blocked row active before the override rungs, while the child rollup
    ///     remains the explicit action guard for a parent. The resolver is deliberately
    ///     untouched in P6.1; the pure `includingDescendants` fixture still documents
    ///     the separate descendant precedence rule.
    ///
    /// Parked rows are now reachable through the shipped builder (explicit records or
    /// the auto-settle window), so this cell's slim path is no longer fixture-only.
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
        /// The identity dot's width, 0 when the agent has no colour — a hidden
        /// arranged view takes neither its width nor a stack gap.
        var identityDot: Double = 0

        func total(drawsBranch: Bool, drawsTime: Bool) -> Double {
            let widths = [glyph, identityDot, title,
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
            if row.closingSince != nil { return "present" }
            switch row.lifecycle {
            case .settled, .snoozed: return "present"
            case .active, .archived: return ""
            }
        }()
        let needs = SlimRowFitNeeds(
            glyph: measuredTextWidth(glyph(for: row.state), .label),
            title: AgentInboxCellView.measuredTextWidth(row.displayTitle, .title),
            branch: AgentInboxCellView.measuredTextWidth(branchText(branch: row.branch), .label),
            time: resolvedTime.isEmpty ? 0 : relativeTimeColumnWidth(
                unconfirmed: row.isUnconfirmed, closing: row.closingSince != nil),
            disclosure: disclosure == .none
                ? 0
                : disclosureWidth ?? measuredDisclosureWidth(disclosure),
            identityDot: row.identityColor == nil ? 0 : Double(AgentInboxView.identityDotSide))
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
            - Double(actionLayoutReservation)
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

    /// Hover actions are overlaid on the row, so the text stack must yield the
    /// same trailing lane that the actions occupy. Otherwise its title paints
    /// underneath both controls at the narrow sidebar widths used by the app.
    private var actionLayoutReservation: CGFloat {
        guard hoverActionShown else { return 0 }
        let count = (onBackgroundStop == nil ? 0 : 1) + (onHoverAction == nil ? 0 : 1)
        guard count > 0 else { return 0 }
        // The action controls keep their 12pt outer inset; this extra 2pt gives
        // the title 4pt of clearance after the stack's internal text inset.
        return CGFloat(count) * CGFloat(20 + Space.s) + CGFloat(Space.xs)
    }

    private func updateActionLayoutReservation() {
        lineTrailingConstraint?.constant = -CGFloat(Inset.row.right) - actionLayoutReservation
        appliedTier = nil
        applyFitTier()
        needsLayout = true
    }

    /// A dropped branch or relative time is relocated into the cell's spoken
    /// label. The sighted row keeps its name-first line; VoiceOver keeps every
    /// fact the measured tier had to remove.
    private func applyRelocatedFacts() {
        guard shown != nil else { return }
        updateAccessibilityPresentation()
    }

    static func statusAccessibilityValue(for row: AgentInboxRow) -> String {
        if row.isUnconfirmed {
            return "Unconfirmed: no live agent snapshot; last known status \(row.label ?? "Ready")"
        }
        if row.closingSince != nil { return "Background" }
        return row.presentationLabel ?? "Ready"
    }

    /// The slim row keeps the same aggregate ancestor contract as the card. The
    /// glyph is the status owner; the non-AX time label's exact fact remains on
    /// the row owner. Slim rows have no project/meta/model children, so those
    /// facts are relocated here instead of being silently dropped.
    private func accessibilityAggregate(for row: AgentInboxRow) -> String {
        var parts = ["Agent \(row.displayTitle)"]
        if let project = row.projectName, !project.isEmpty {
            parts.append("Project \(project)")
        }
        if let branch = row.branch, !branch.isEmpty, branchLabel.isHidden {
            parts.append("Branch \(Self.branchText(branch: branch))")
        }
        if row.isIsolated {
            parts.append("isolated")
        } else if row.branch?.isEmpty == false {
            parts.append("shared")
        }
        if let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            parts.append("Model \(model)")
        }
        let time = row.isUnconfirmed
            ? AgentInboxCellView.elapsedText(row.elapsed).map { "last seen \($0)" } ?? ""
            : Self.relativeText(for: row, now: shown?.now ?? Date())
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: ", ")
    }

    private func updateAccessibilityPresentation() {
        guard let row = shown?.row else { return }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibilityAggregate(for: row))
        // The glyph below is the only status owner for a slim row.
        setAccessibilityValue(nil)
        setAccessibilityEnabled(true)
        setAccessibilitySelected(card.isSelected)
        setAccessibilityExpanded(shown?.disclosure == RowDisclosure.expanded)

        glyphLabel.setAccessibilityElement(true)
        glyphLabel.setAccessibilityRole(.image)
        let statusValue = Self.statusAccessibilityValue(for: row)
        glyphLabel.setAccessibilityLabel("Status: \(statusValue)")
        glyphLabel.setAccessibilityValue(statusValue)
        // The row aggregate owns the subject/name; the title is not a second AX
        // fact beneath it.
        titleLabel.setAccessibilityElement(false)
        titleLabel.setAccessibilityValue(nil)
        branchLabel.setAccessibilityElement(!branchLabel.isHidden && !branchLabel.stringValue.isEmpty)
        branchLabel.setAccessibilityValue(branchLabel.stringValue)
        timeLabel.setAccessibilityElement(false)
        disclosureButton.setAccessibilityElement(!disclosureButton.isHidden)
        var children: [NSView] = [glyphLabel]
        for child in [branchLabel, disclosureButton]
            where child.isAccessibilityElement() && !child.isHidden {
            children.append(child)
        }
        for child in [hoverAction, backgroundStopAction]
            where child.isAccessibilityElement() && !child.isHidden {
            children.append(child)
        }
        setAccessibilityChildren(children)
    }

    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure = .none, rollup: ChildRollup? = nil,
               isSelected: Bool = false,
               isInteracting: Bool = false, now: Date = Date()) {
        shown = (row, emphasis, disclosure, isInteracting, now)
        card.isSelected = isSelected
        leadingInset?.constant = indent
        disclosureButton.show(disclosure, childCount: rollup?.children ?? 0)

        glyphLabel.stringValue = AgentInboxSlimCellView.glyph(for: row.isUnconfirmed ? .ready : row.state)
        glyphLabel.setAccessibilityLabel(row.isUnconfirmed ? "Unconfirmed" : (row.state.label ?? "Ready"))
        glyphLabel.setAccessibilityRole(.image)
        identityDot.colour = row.identityColor.map(AgentInboxView.identityDotColour(named:))
        identityDot.isHidden = row.identityColor == nil
        titleLabel.stringValue = row.displayTitle
        branchLabel.stringValue = AgentInboxSlimCellView.branchText(branch: row.branch)
        branchLabel.isHidden = branchLabel.stringValue.isEmpty
        let relativeText = AgentInboxSlimCellView.relativeText(for: row, now: now)
        timeColumnWidth?.constant = AgentInboxSlimCellView.relativeTimeColumnWidth(
            unconfirmed: row.isUnconfirmed, closing: row.closingSince != nil)
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
        let metrics = AgentInbox96CellView.spineMetrics
        let bleed = CGFloat(AgentInboxView.rowSpacing) / 2
        clipsToBounds = false
        groupBackground.clipsToBounds = false
        groupBackground.frame = bounds.insetBy(dx: 0, dy: -bleed)
        groupBackground.show(
            nesting, hasChildren: !disclosureButton.isHidden,
            metrics: metrics, rowHeight: bounds.height + bleed * 2)
        spine.clipsToBounds = false
        spine.frame = bounds.insetBy(dx: 0, dy: -bleed)
        spine.show(
            nesting, metrics: metrics,
            cardTop: Double(card.frame.minY + bleed),
            cardHeight: Double(card.frame.height),
            rowHeight: Double(bounds.height + bleed * 2))
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

    /// The shared inbox clock, for a Background row: only its time label moves.
    func updateElapsedClock(now: Date) {
        guard let row = shown?.row, row.closingSince != nil, !row.isUnconfirmed else { return }
        timeLabel.stringValue = AgentInboxSlimCellView.relativeText(for: row, now: now)
    }

    func showJumpHint(_ chord: String?) { jumpHint.show(chord) }

    // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.2-interaction-fill-ladder.md
    func applyInteraction(_ interaction: RowInteraction) {
        card.isHovered = interaction.isHovered
        card.isRouteActive = interaction.isRouteActive
        card.hasKeyboardFocus = interaction.hasKeyboardFocus
        let on = interaction.isHovered && (onHoverAction != nil || onBackgroundStop != nil)
        hoverActionShown = on
        let showRestore = on && onHoverAction != nil
        let showStop = on && onBackgroundStop != nil
        hoverAction.isHidden = !showRestore
        backgroundStopAction.isHidden = !showStop
        updateActionLayoutReservation()
        pairedBackgroundStopTrailing?.isActive = onHoverAction != nil
        soloBackgroundStopTrailing?.isActive = onHoverAction == nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.15
            context.allowsImplicitAnimation = !reduce
            (reduce ? hoverAction : hoverAction.animator()).alphaValue = showRestore ? 1 : 0
            (reduce ? backgroundStopAction : backgroundStopAction.animator()).alphaValue = showStop ? 1 : 0
            (reduce ? timeLabel : timeLabel.animator()).alphaValue = on ? 0 : CGFloat(shown?.emphasis.textOpacity ?? 1)
        }
        updateAccessibilityPresentation()
    }

    @objc private func hoverActionClicked() { onHoverAction?() }
    @objc private func backgroundStopClicked() { onBackgroundStop?() }

    /// The one action this slim row offers on hover, or nil for none.
    func configureHoverAction(symbol: String, label: String, perform: (() -> Void)?) {
        onBackgroundStop = nil
        backgroundStopAction.isHidden = true
        backgroundStopAction.alphaValue = 0
        onHoverAction = perform
        hoverAction.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        hoverAction.toolTip = label
        hoverAction.setAccessibilityLabel(label)
        hoverAction.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    func configureBackgroundActions(bringBack: (() -> Void)?, stop: (() -> Void)?) {
        onHoverAction = bringBack
        onBackgroundStop = stop
        hoverAction.isHidden = bringBack == nil
        hoverAction.alphaValue = 0
        backgroundStopAction.isHidden = stop == nil
        backgroundStopAction.alphaValue = 0
        pairedBackgroundStopTrailing?.isActive = bringBack != nil
        soloBackgroundStopTrailing?.isActive = bringBack == nil
        hoverAction.image = NSImage(
            systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Bring back to canvas")
        hoverAction.toolTip = "Bring back to canvas"
        hoverAction.setAccessibilityLabel("Bring back to canvas")
        hoverAction.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        backgroundStopAction.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    var qaHoverActionShown: Bool { hoverActionShown }
    var qaHoverActionTitles: [String] {
        var titles: [String] = []
        if onHoverAction != nil { titles.append(hoverAction.accessibilityLabel() ?? "Bring back to canvas") }
        if onBackgroundStop != nil { titles.append(backgroundStopAction.accessibilityLabel() ?? "Stop") }
        return titles
    }
    var qaBackgroundActionFrames: [String: NSRect] {
        var frames: [String: NSRect] = [:]
        if onHoverAction != nil { frames["bringBackAction"] = hoverAction.convert(hoverAction.bounds, to: self) }
        if onBackgroundStop != nil { frames["stopAction"] = backgroundStopAction.convert(backgroundStopAction.bounds, to: self) }
        return frames
    }
    @discardableResult
    func clickBackgroundBringBackForQA() -> Bool {
        guard onHoverAction != nil, !hoverAction.isHidden else { return false }
        hoverAction.performClick(nil)
        return true
    }
    @discardableResult
    func clickBackgroundStopForQA() -> Bool {
        guard onBackgroundStop != nil, !backgroundStopAction.isHidden else { return false }
        backgroundStopAction.performClick(nil)
        return true
    }

    func setIncreasedContrast(_ enabled: Bool) {
        card.usesIncreasedContrast = enabled
    }

    var accessibilityStatusOwner: NSView { glyphLabel }

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
    static func relativeTimeColumnWidth(unconfirmed: Bool, closing: Bool = false) -> Double {
        let font = NSFont.token(.captionMono)
        let labels = AgentElapsedFormatter.columnLabels.flatMap {
            closing ? [backgroundText($0)]
                : unconfirmed ? ["last seen \($0)"] : ["\($0) ago", "in \($0)"]
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
    /// A closed tile whose agent is still working: "Background · 2m", counted
    /// from the close. The turn remains live and can be restored or stopped from
    /// the two hover controls.
    static func backgroundText(_ elapsed: String) -> String {
        "Background · \(elapsed)"
    }

    static func relativeText(for row: AgentInboxRow, now: Date) -> String {
        guard let since = row.closingSince else { return relativeText(for: row.lifecycle, now: now) }
        return backgroundText(AgentInboxCellView.elapsedText(max(0, now.timeIntervalSince(since))) ?? "")
    }

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
        if onBackgroundStop != nil {
            frames.merge(qaBackgroundActionFrames, uniquingKeysWith: { _, newest in newest })
        }
        return AgentInboxRowGeometryForQA(
            agentID: shown?.row.id,
            state: shown?.row.state,
            variant: shown?.row.variant,
            elementFrames: frames,
            labels: labels,
            paintedBorderWidth: card.layer.map { Double($0.borderWidth) },
            resolvedFill: card.layer?.backgroundColor,
            increasedContrast: card.qaUsesIncreasedContrast,
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
    /// The identity dot as drawn, in this cell's coordinates, or nil when hidden.
    var qaIdentityDotForQA: (frame: NSRect, colour: NSColor)? {
        guard !identityDot.isHidden, let colour = identityDot.colour else { return nil }
        return (identityDot.convert(identityDot.bounds, to: self), colour)
    }
    var qaTitleFrameForQA: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }
    /// A collapsed row says its state with the glyph, so it has no word to report.
    var qaStateLabel: String { "" }
    var qaMeta: String { "" }
    var qaBranch: String { branchLabel.isHidden ? "" : branchLabel.stringValue }
    var qaElapsed: String { timeLabel.isHidden ? "" : timeLabel.stringValue }
    var qaGlyph: String { glyphLabel.stringValue }
    /// A slim row draws no provider mark — its one glyph is the status glyph above.
    var qaProviderGlyph: String { "" }
    /// A slim row has no project child at all; the fact is relocated to its
    /// accessibility aggregate (see `accessibilityAggregate(for:)`). Empty here is
    /// the fact, not a missing accessor.
    var qaProject: String { "" }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    /// The glyph IS this row's accent — the same number as `qaGlyphAlpha`, and
    /// deliberately not `Opacity.full`: see the divergence note on the class.
    var qaAccentAlpha: Double { Double(glyphLabel.alphaValue) }
    var qaGlyphAlpha: Double { Double(glyphLabel.alphaValue) }
    var qaIndent: Double { Double(leadingInset?.constant ?? 0) }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
    var qaDisclosureTitle: String { disclosureButton.qaTitle }
    var qaGroupBackgroundVisibleForQA: Bool { groupBackground.qaIsVisibleForQA }
    var qaGroupBackgroundCornersForQA: (top: Bool, bottom: Bool) {
        (groupBackground.qaRoundsTopForQA, groupBackground.qaRoundsBottomForQA)
    }
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
