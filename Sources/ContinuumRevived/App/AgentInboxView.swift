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
// The inbox is FLAT: `depth` is a drawing indent for a spawned child (P2D.4),
// not a disclosure — a child row is never hidden behind its parent, because a
// child asking for approval is exactly the row you must not have to expand to
// find. `InboxSort` already places a child immediately after its parent, so the
// order an outline would give is the order the array already has.

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

    /// How far one nesting level indents a child row (P2D.4 draws the nesting;
    /// this is only the step). `Space.xl`, so an indented card is still visibly a
    /// card rather than a hairline shift.
    static let indentPerLevel = Space.xl

    /// Shown when there is nothing to show. A list that renders as an empty
    /// rectangle reads as broken; it also renders as a uniform fill, which the
    /// phase-0 blankness floor is right to call a failure.
    static let emptyMessage = "No agents yet"

    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let column: NSTableColumn
    private let emptyLabel: NSTextField

    /// The rows as they are drawn — already through `InboxSort.sortForInbox`, so
    /// index N here is row N on screen and every accessor below can be an index.
    private(set) var rows: [AgentInboxRow] = []
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
    private var cellsByRow: [Int: AgentInboxCellView] = [:]
    private(set) var cellBuildCountForQA = 0

    override init(frame frameRect: NSRect) {
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

        addSubview(scrollView)
        addSubview(emptyLabel)

        tableView.dataSource = self
        tableView.delegate = self

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.l),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.l),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: Space.xl),
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
        rows = InboxSort.sortForInbox(rows: newRows)
        cellsByRow.removeAll()
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
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
        let sorted = InboxSort.sortForInbox(rows: newRows)
        guard sorted.map(\.id) == rows.map(\.id) else {
            reload(rows: sorted)
            return
        }
        let previous = rows
        rows = sorted
        let indexes = IndexSet(rows.indices.filter {
            changed.touched.contains(rows[$0].id) || rows[$0] != previous[$0]
        })
        guard !indexes.isEmpty else { return }
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        cellBuildCountForQA += 1
        let model = rows[row]
        let cell = AgentInboxCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(AgentInboxView.accessibilityIdentifier(for: model))
        cell.setAccessibilityIdentifier(AgentInboxView.accessibilityIdentifier(for: model))
        cell.apply(
            model,
            emphasis: AgentInboxRow.emphasis(
                for: model.state, attention: model.attention, isInteracting: isInteracting(row: row)
            ),
            indent: Double(max(0, model.depth)) * AgentInboxView.indentPerLevel,
            isSelected: tableView.selectedRow == row
        )
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

    static func accessibilityIdentifier(for row: AgentInboxRow) -> String {
        "agent-inbox-row-\(row.id.uuidString)"
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

    private func cells() -> [AgentInboxCellView] {
        (0..<tableView.numberOfRows).compactMap { cellsByRow[$0] }
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
final class AgentInboxCellView: NSTableCellView {
    private let card = AgentInboxCardView()

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
    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis)?

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

        let headline = NSStackView(views: [projectLabel, titleLabel, NSView(), stateLabel, elapsedLabel])
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
    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double, isSelected: Bool) {
        shown = (row, emphasis)
        card.isSelected = isSelected
        leadingInset?.constant = indent

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
              indent: Double(leadingInset?.constant ?? 0), isSelected: card.isSelected)
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

    var qaTitle: String { titleLabel.stringValue }
    var qaStateLabel: String { stateLabel.isHidden ? "" : stateLabel.stringValue }
    var qaMeta: String { metaLabel.stringValue }
    var qaBranch: String { branchLabel.stringValue }
    var qaElapsed: String { elapsedLabel.stringValue }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    var qaAccentAlpha: Double { Double(stateLabel.alphaValue) }
}
