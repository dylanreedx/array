import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
enum WorkspaceSidebarSelection: Equatable {
    case workspace(UUID)
    case zone(workspaceId: UUID, zoneId: UUID)
    case tile(workspaceId: UUID, zoneId: UUID, tileId: UUID)
}

@MainActor
final class WorkspaceSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, TokenThemed {
    private struct ZoneItemKey: Hashable {
        let workspaceId: UUID
        let zoneId: UUID
    }

    private struct TileItemKey: Hashable {
        let workspaceId: UUID
        let zoneId: UUID
        let tileId: UUID
    }

    private final class SidebarItem: NSObject {
        enum Kind {
            case workspace(SidebarWorkspaceRow)
            case zone(SidebarZoneRow, workspaceId: UUID)
            case tile(SidebarTileRow, zoneId: UUID, workspaceId: UUID)
        }

        let kind: Kind
        var children: [SidebarItem] = []

        init(kind: Kind) {
            self.kind = kind
            super.init()
        }
    }

    private final class SidebarRowView: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            super.drawSelection(in: dirtyRect)
            guard isSelected else { return }
            let stripe = NSRect(x: 2, y: bounds.minY + 3, width: 3, height: max(0, bounds.height - 6))
            NSColor.controlAccentColor.setFill()
            stripe.fill()
        }
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.6-inbox-list-view.md
    //
    // THE SIDEBAR IS THE INBOX (locked decision), so `inboxView` is this view's
    // content and the workspace ▸ zone ▸ tile outline below it is no longer shown.
    //
    // WHAT REMAINS, as the packet's "watch out" requires it be stated: the outline
    // is still built, still reloaded by `reload(tree:…)` and still answers every
    // `…ForQA` accessor, because things do still depend on it —
    // `--workspace-sidebar-shell-check`, `--workspace-sidebar-actions-check` and
    // `--workspace-sidebar-live-status-check` all read it, and the workspace / zone
    // selection callbacks (`onSelection`) are how `handleWorkspaceSidebarSelection`
    // switches workspace and focuses a zone. It is hidden rather than deleted so
    // this ticket does not have to migrate those consumers at the same time as it
    // introduces the list: the scope dropdown that replaces workspace navigation is
    // P3.8's, and preserving workspace management is P3.14's.
    private let inboxView: AgentInboxView
    private let scrollView: NSScrollView
    private let outlineView: NSOutlineView
    private let column: NSTableColumn
    private let titleLabel: NSTextField
    private let managementMessageLabel: NSTextField

    private var tree = SidebarTree(workspaces: [])
    private var currentWorkspaceId: UUID?
    private var rootItems: [SidebarItem] = []
    private var workspaceItemsById: [UUID: SidebarItem] = [:]
    private var zoneItemsByKey: [ZoneItemKey: SidebarItem] = [:]
    private var tileItemsByKey: [TileItemKey: SidebarItem] = [:]

    var onSelection: ((WorkspaceSidebarSelection) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onRenameWorkspace: ((UUID) -> Void)?
    var onDeleteWorkspace: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
        //
        // "Agents", and now nothing else in the header: the three workspace buttons
        // that used to sit under this label have moved into the scope popup's menu,
        // which is where the workspace being acted on is named. The header keeps the
        // management MESSAGE — a rejected rename or a preserved workspace has to be
        // readable somewhere, and a menu that has already closed is not that place.
        titleLabel = NSTextField(labelWithString: "Agents")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        managementMessageLabel = NSTextField(labelWithString: "")
        managementMessageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        managementMessageLabel.lineBreakMode = .byTruncatingTail
        managementMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        managementMessageLabel.isHidden = true

        scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        outlineView = NSOutlineView(frame: .zero)
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 16
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = .clear
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace-sidebar-name"))
        column.title = "Name"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        scrollView.documentView = outlineView
        scrollView.isHidden = true

        inboxView = AgentInboxView(frame: .zero)
        inboxView.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        wantsLayer = true
        applyTokens()
        setAccessibilityIdentifier("ContinuumWorkspaceSidebarRoot")
        managementMessageLabel.setAccessibilityIdentifier("ContinuumWorkspaceSidebarManagementMessage")

        addSubview(titleLabel)
        addSubview(managementMessageLabel)
        addSubview(scrollView)
        addSubview(inboxView)

        // P3.14: the header buttons' three targets, now one menu.
        inboxView.onWorkspaceManagementAction = { [weak self] action in
            self?.performWorkspaceManagement(action)
        }

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked(_:))

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            managementMessageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            managementMessageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            managementMessageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: managementMessageLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            inboxView.leadingAnchor.constraint(equalTo: leadingAnchor),
            inboxView.trailingAnchor.constraint(equalTo: trailingAnchor),
            inboxView.topAnchor.constraint(equalTo: managementMessageLabel.bottomAnchor, constant: 8),
            inboxView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// P1.11: the sidebar IS `SurfaceToken.panel` — the token declared for "the
    /// sidebar and Settings" — rather than `windowBackgroundColor` at 92%. The
    /// alpha went with the literal: a translucent panel makes whatever is behind it
    /// part of every text pair, which is not something P1.6 can gate, and `panel`
    /// is already one step off `canvas` so the separation it bought is in the token.
    ///
    /// The two label colours live here for the same reason they do in the tile
    /// chrome: `NSTextField.textColor` is a resolved `NSColor`, so nothing else
    /// re-assigns it when the appearance moves. Row cells are rebuilt by
    /// `reloadData()`, which is why the outline is reloaded too.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        titleLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        managementMessageLabel.textColor = AccentToken.accentApproval.color.nsColor(in: self)
        if outlineView.numberOfRows > 0 { outlineView.reloadData() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func reload(tree: SidebarTree, currentWorkspaceId: UUID?, selectedZoneId: UUID? = nil, selectedTileId: UUID? = nil) {
        self.tree = tree
        self.currentWorkspaceId = currentWorkspaceId
        rebuildItems()
        outlineView.reloadData()
        applyDefaultExpansion(selectedZoneId: selectedZoneId, selectedTileId: selectedTileId)
        updateManagementButtonState()
    }

    /// Replace the inbox. Kept separate from `reload(tree:…)` on purpose: the tree
    /// comes off disk (registry + documents + canvases) and the rows come out of
    /// the one agent-activity snapshot, on two different cadences — an agent event
    /// must be able to move a row without re-reading every project's store.
    func reloadInbox(rows: [AgentInboxRow]) {
        inboxView.reload(rows: rows)
    }

    /// The incremental path (P2B.7): the same rows plus which agents moved.
    func applyInbox(rows: [AgentInboxRow], changed: AgentsBoardChangeSet) {
        inboxView.apply(rows: rows, changed: changed)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// Restore the persisted scope and say where a user-picked one should be
    /// written. Both halves are the app's (`WorkspaceSidebarConfig` lives beside the
    /// sidebar's width and visibility), so the view holds the scope and knows
    /// nothing about `UserDefaults` — which is also what keeps its three committed
    /// Lab baselines independent of whose defaults ran the check.
    func configureInboxScope(_ scope: InboxScope, onChange: @escaping (InboxScope) -> Void) {
        // P3.14: the scope decides which workspace the menu's verbs act on, so a flip
        // can turn Delete on or off (scoping to a workspace names a target where the
        // canvas had none) without any reload having happened.
        inboxView.onScopeChange = { [weak self] next in
            onChange(next)
            self?.updateManagementButtonState()
        }
        inboxView.setScope(scope)
        updateManagementButtonState()
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.9-reveal-on-click.md
    /// Where a clicked row goes. Passed straight through, exactly like
    /// `onSelection` for the tree: the inbox is the sidebar's content, and the
    /// navigation belongs to the app either way.
    func configureInboxReveal(_ onReveal: @escaping (UUID) -> Void) {
        inboxView.onRevealRow = onReveal
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.15-wire-destructive-row-actions.md
    /// Where a row-menu or bulk-bar action goes, and WHICH actions the host performs.
    ///
    /// Both halves in one call because they are one fact: a callback without the
    /// capability set un-greys nothing, and a capability set without the callback is a
    /// promise nobody keeps. The shipped app assigned neither for eleven tickets, so an
    /// agent could not be deleted by any route; the source scan in
    /// `--agent-inbox-check` now asserts this call exists in `configureWorkspaceSidebar`.
    ///
    /// Passed straight through like the reveal and the rename above: the actions land
    /// on the supervisor, and only the app holds one.
    func configureInboxActions(
        rowActions: Set<InboxRowAction>,
        onRowAction: @escaping (InboxRowAction, [UUID]) -> Void,
        bulkActions: Set<InboxBulkAction>,
        onBulkAction: @escaping (InboxBulkAction, [UUID]) -> Void
    ) {
        inboxView.wiredRowActions = rowActions
        inboxView.onRowAction = onRowAction
        inboxView.wiredBulkActions = bulkActions
        inboxView.onBulkAction = onBulkAction
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.13-inline-rename.md
    /// Where a committed rename goes. Passed straight through like the reveal above:
    /// the name lives on the agent's record, and only the app holds the supervisor
    /// that may write one.
    func configureInboxRename(_ onRename: @escaping (UUID, String) -> Void) {
        inboxView.onRenameRow = onRename
    }

    /// The agent open in the focused tile — force-included in the inbox whatever the
    /// scope is, so navigating to an agent can never hide its own row.
    func setInboxOpenAgent(_ id: UUID?) {
        inboxView.openAgentId = id
    }

    /// Every project and workspace that is open, so the scope popup can offer one you
    /// have no agent in yet.
    func setInboxScopeCatalog(_ catalog: [InboxScope]) {
        inboxView.scopeCatalog = catalog
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.16-inbox-lists-agents-only.md
    /// How many agents are running in terminal tiles, which this list does not show.
    /// Only its empty state reads this — see `AgentInboxView.terminalHostedEmptyMessage`.
    func setInboxExcludedTerminalAgentCount(_ count: Int) {
        inboxView.excludedTerminalAgentCount = count
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// The list, for the app's ⌘1–⌘9 jump routing. The same view `inboxForQA`
    /// exposes; a second name because this one is a production path and the app has
    /// to ask "is the inbox focused" of the real view.
    var agentInbox: AgentInboxView { inboxView }

    var inboxForQA: AgentInboxView { inboxView }
    var isWorkspaceTreeVisibleForQA: Bool { !scrollView.isHidden }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarItem else { return rootItems.count }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? SidebarItem else { return rootItems[index] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        let cell = NSTableCellView(frame: .zero)
        let textField = NSTextField(labelWithString: displayTitle(for: item))
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = font(for: item)
        textField.textColor = textColor(for: item)
        cell.addSubview(textField)
        cell.textField = textField
        cell.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier(for: item))
        cell.setAccessibilityIdentifier(accessibilityIdentifier(for: item))

        if let status = statusPresentation(for: item) {
            let glyphField = NSTextField(labelWithString: status.glyph)
            glyphField.translatesAutoresizingMaskIntoConstraints = false
            glyphField.font = .systemFont(ofSize: 10, weight: .semibold)
            glyphField.textColor = status.color
            glyphField.alignment = .center

            let statusField = NSTextField(labelWithString: status.text)
            statusField.translatesAutoresizingMaskIntoConstraints = false
            statusField.font = .systemFont(ofSize: 10, weight: .regular)
            // Full-strength accent, not 82%: an alpha over the panel is a composite
            // no documented pair covers, and the accent-on-`panel` pair is gated.
            statusField.textColor = status.color
            statusField.lineBreakMode = .byTruncatingTail
            statusField.setContentCompressionResistancePriority(.required, for: .horizontal)

            cell.addSubview(glyphField)
            cell.addSubview(statusField)
            NSLayoutConstraint.activate([
                glyphField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                glyphField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                glyphField.widthAnchor.constraint(equalToConstant: 12),

                textField.leadingAnchor.constraint(equalTo: glyphField.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: statusField.leadingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                statusField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                statusField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                statusField.widthAnchor.constraint(lessThanOrEqualToConstant: 118),
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    var workspaceRowsRenderedForQA: Int { visibleItems().filter { if case .workspace = $0.kind { return true }; return false }.count }
    var zoneRowsRenderedForQA: Int { visibleItems().filter { if case .zone = $0.kind { return true }; return false }.count }
    var tileRowsRenderedForQA: Int { visibleItems().filter { if case .tile = $0.kind { return true }; return false }.count }
    var visibleDisplayNamesForQA: [String] { visibleItems().map(displayTitle(for:)) }
    var visibleStatusTextsForQA: [String] { visibleItems().compactMap { statusPresentation(for: $0)?.text } }
    var visibleStatusGlyphsForQA: [String] { visibleItems().compactMap { statusPresentation(for: $0)?.glyph } }
    var managementMessageForQA: String { managementMessageLabel.stringValue }
    // P3.14: the same question, asked of the menu item the buttons became.
    var deleteEnabledForQA: Bool { inboxView.isWorkspaceManagementEnabledForQA(.delete) }
    var renameEnabledForQA: Bool { inboxView.isWorkspaceManagementEnabledForQA(.rename) }
    var workspaceManagementTitlesForQA: [String] { inboxView.workspaceManagementTitlesForQA }
    var isWorkspaceManagementSeparatedForQA: Bool { inboxView.isWorkspaceManagementSeparatedForQA }
    var workspaceIdForManagementActionForQA: UUID? { workspaceIdForManagementAction() }
    var selectedTargetForQA: WorkspaceSidebarSelection? {
        guard outlineView.selectedRow >= 0,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem else { return nil }
        return selection(for: item)
    }

    func isWorkspaceExpandedForQA(_ workspaceId: UUID) -> Bool {
        guard let item = workspaceItemsById[workspaceId] else { return false }
        return outlineView.isItemExpanded(item)
    }

    func isWorkspaceSelectedForQA(_ workspaceId: UUID) -> Bool {
        guard let item = workspaceItemsById[workspaceId] else { return false }
        return outlineView.row(forItem: item) == outlineView.selectedRow
    }

    @discardableResult
    func select(workspaceId: UUID, zoneId: UUID? = nil, tileId: UUID? = nil) -> Bool {
        selectItem(workspaceId: workspaceId, zoneId: zoneId, tileId: tileId)
    }

    @discardableResult
    func selectForQA(workspaceId: UUID, zoneId: UUID? = nil, tileId: UUID? = nil) -> Bool {
        select(workspaceId: workspaceId, zoneId: zoneId, tileId: tileId)
    }

    func setManagementMessage(_ message: String?) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        managementMessageLabel.stringValue = text
        managementMessageLabel.isHidden = text.isEmpty
    }

    // P3.14: same three names, driving the scope menu instead of the removed header
    // buttons — the coverage that called them now exercises the new location.
    @discardableResult
    func clickCreateForQA() -> Bool {
        inboxView.pickWorkspaceManagementForQA(.create)
    }

    @discardableResult
    func clickRenameForQA() -> Bool {
        inboxView.pickWorkspaceManagementForQA(.rename)
    }

    @discardableResult
    func clickDeleteForQA() -> Bool {
        inboxView.pickWorkspaceManagementForQA(.delete)
    }

    @discardableResult
    func clickWorkspaceRowForQA(_ workspaceId: UUID) -> Bool {
        guard let item = workspaceItemsById[workspaceId] else { return false }
        return click(item: item)
    }

    @discardableResult
    func clickZoneRowForQA(workspaceId: UUID, zoneId: UUID) -> Bool {
        let key = ZoneItemKey(workspaceId: workspaceId, zoneId: zoneId)
        guard let item = zoneItemsByKey[key] else { return false }
        return click(item: item)
    }

    @discardableResult
    func clickTileRowForQA(workspaceId: UUID, zoneId: UUID, tileId: UUID) -> Bool {
        let key = TileItemKey(workspaceId: workspaceId, zoneId: zoneId, tileId: tileId)
        guard let item = tileItemsByKey[key] else { return false }
        return click(item: item)
    }

    func zoneStatusTextForQA(workspaceId: UUID, zoneId: UUID) -> String? {
        statusPresentation(for: zoneItemsByKey[ZoneItemKey(workspaceId: workspaceId, zoneId: zoneId)])?.text
    }

    func tileStatusTextForQA(workspaceId: UUID, zoneId: UUID, tileId: UUID) -> String? {
        statusPresentation(for: tileItemsByKey[TileItemKey(workspaceId: workspaceId, zoneId: zoneId, tileId: tileId)])?.text
    }

    func tileStatusGlyphForQA(workspaceId: UUID, zoneId: UUID, tileId: UUID) -> String? {
        statusPresentation(for: tileItemsByKey[TileItemKey(workspaceId: workspaceId, zoneId: zoneId, tileId: tileId)])?.glyph
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateManagementButtonState()
    }

    @objc private func outlineRowClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard row >= 0,
              let item = sender.item(atRow: row) as? SidebarItem else { return }
        performSelection(for: item)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.14-preserve-workspace-management.md
    private func performWorkspaceManagement(_ action: AgentInboxView.WorkspaceManagementAction) {
        switch action {
        case .create:
            onCreateWorkspace?()
        case .rename:
            guard let workspaceId = workspaceIdForManagementAction() else { return }
            onRenameWorkspace?(workspaceId)
        case .delete:
            guard let workspaceId = workspaceIdForManagementAction(), tree.workspaces.count > 1 else { return }
            onDeleteWorkspace?(workspaceId)
        }
    }

    /// Which workspace a verb lands on.
    ///
    /// THE SCOPED WORKSPACE FIRST (P3.14): the scope popup is the control the verbs
    /// now hang off, so "Rename Workspace…" under a workspace scope must mean that
    /// workspace and not whichever one the canvas happens to be showing. The scope
    /// carries a NAME (`InboxScope.workspace`), so it is resolved against the tree,
    /// and only a UNIQUE match counts — duplicate workspace names are allowed by
    /// `Registry.createWorkspace`, and guessing which of two same-named workspaces to
    /// delete is not a guess this view may make.
    ///
    /// AN AMBIGUOUS WORKSPACE SCOPE HAS NO TARGET AT ALL — it does not fall through
    /// (found in cross-review). Falling back would put the verbs back on the open
    /// workspace while the control above them names a different one, which is worse
    /// than a greyed-out Delete: the name-based scope is safe for FILTERING because a
    /// wrong match only shows extra rows, and that argument does not survive contact
    /// with a destructive verb. Same for a scope naming a workspace this tree does not
    /// have.
    ///
    /// Under any other scope, the old chain unchanged: the outline's selection, then
    /// the current workspace. Under `.all` — the default — that is exactly the
    /// behaviour the header buttons had.
    private func workspaceIdForManagementAction() -> UUID? {
        if case let .workspace(name) = inboxView.scope {
            let matches = tree.workspaces.filter { $0.name == name }
            return matches.count == 1 ? matches[0].workspaceId : nil
        }
        if let selection = selectedTargetForQA {
            switch selection {
            case let .workspace(workspaceId): return workspaceId
            case let .zone(workspaceId, _): return workspaceId
            case let .tile(workspaceId, _, _): return workspaceId
            }
        }
        return currentWorkspaceId
    }

    private func updateManagementButtonState() {
        let workspaceId = workspaceIdForManagementAction()
        inboxView.setWorkspaceManagement(
            canRename: workspaceId != nil,
            canDelete: workspaceId != nil && tree.workspaces.count > 1
        )
    }

    private func rebuildItems() {
        workspaceItemsById.removeAll()
        zoneItemsByKey.removeAll()
        tileItemsByKey.removeAll()
        rootItems = tree.workspaces.map { workspace in
            let workspaceItem = SidebarItem(kind: .workspace(workspace))
            workspaceItem.children = workspace.zones.map { zone in
                let zoneItem = SidebarItem(kind: .zone(zone, workspaceId: workspace.workspaceId))
                zoneItem.children = zone.tiles.map { tile in
                    let tileItem = SidebarItem(kind: .tile(tile, zoneId: zone.zoneId, workspaceId: workspace.workspaceId))
                    tileItemsByKey[TileItemKey(workspaceId: workspace.workspaceId, zoneId: zone.zoneId, tileId: tile.tileId)] = tileItem
                    return tileItem
                }
                zoneItemsByKey[ZoneItemKey(workspaceId: workspace.workspaceId, zoneId: zone.zoneId)] = zoneItem
                return zoneItem
            }
            workspaceItemsById[workspace.workspaceId] = workspaceItem
            return workspaceItem
        }
    }

    private func applyDefaultExpansion(selectedZoneId: UUID?, selectedTileId: UUID?) {
        for item in rootItems {
            outlineView.collapseItem(item, collapseChildren: true)
        }
        guard let currentWorkspaceId,
              let currentItem = workspaceItemsById[currentWorkspaceId] else { return }
        outlineView.expandItem(currentItem, expandChildren: false)
        for zoneItem in currentItem.children {
            outlineView.expandItem(zoneItem, expandChildren: false)
        }
        if let selectedTileId,
           selectItem(workspaceId: currentWorkspaceId, zoneId: selectedZoneId, tileId: selectedTileId) {
            return
        }
        if let selectedZoneId,
           selectItem(workspaceId: currentWorkspaceId, zoneId: selectedZoneId, tileId: nil) {
            return
        }
        _ = selectItem(workspaceId: currentWorkspaceId, zoneId: nil, tileId: nil)
    }

    @discardableResult
    private func selectItem(workspaceId: UUID, zoneId: UUID?, tileId: UUID?) -> Bool {
        let item: SidebarItem?
        if let zoneId, let tileId {
            item = tileItemsByKey[TileItemKey(workspaceId: workspaceId, zoneId: zoneId, tileId: tileId)]
        } else if let tileId {
            item = tileItemsByKey.first { entry in entry.key.workspaceId == workspaceId && entry.key.tileId == tileId }?.value
        } else if let zoneId {
            item = zoneItemsByKey[ZoneItemKey(workspaceId: workspaceId, zoneId: zoneId)]
        } else {
            item = workspaceItemsById[workspaceId]
        }
        guard let item else { return false }
        reveal(item)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        return true
    }

    @discardableResult
    private func click(item: SidebarItem) -> Bool {
        reveal(item)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        performSelection(for: item)
        return true
    }

    private func reveal(_ item: SidebarItem) {
        switch item.kind {
        case .workspace:
            break
        case let .zone(_, workspaceId):
            if let workspaceItem = workspaceItemsById[workspaceId] {
                outlineView.expandItem(workspaceItem, expandChildren: false)
            }
        case let .tile(_, zoneId, workspaceId):
            if let workspaceItem = workspaceItemsById[workspaceId] {
                outlineView.expandItem(workspaceItem, expandChildren: false)
            }
            if let zoneItem = zoneItemsByKey[ZoneItemKey(workspaceId: workspaceId, zoneId: zoneId)] {
                outlineView.expandItem(zoneItem, expandChildren: false)
            }
        }
    }

    private func performSelection(for item: SidebarItem) {
        guard let selection = selection(for: item) else { return }
        onSelection?(selection)
    }

    private func selection(for item: SidebarItem) -> WorkspaceSidebarSelection? {
        switch item.kind {
        case let .workspace(workspace):
            return .workspace(workspace.workspaceId)
        case let .zone(zone, workspaceId):
            return .zone(workspaceId: workspaceId, zoneId: zone.zoneId)
        case let .tile(tile, zoneId, workspaceId):
            return .tile(workspaceId: workspaceId, zoneId: zoneId, tileId: tile.tileId)
        }
    }

    private func visibleItems() -> [SidebarItem] {
        guard outlineView.numberOfRows > 0 else { return [] }
        return (0..<outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) as? SidebarItem }
    }

    private func displayTitle(for item: SidebarItem) -> String {
        switch item.kind {
        case let .workspace(workspace):
            return workspace.name
        case let .zone(zone, _):
            let fallback = zone.projectId == nil ? "Untitled Zone" : "Unknown Project"
            return zone.name.isEmpty ? fallback : zone.name
        case let .tile(tile, _, _):
            let title = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? tile.kind.rawValue : title
        }
    }

    private func font(for item: SidebarItem) -> NSFont {
        switch item.kind {
        case let .workspace(workspace) where workspace.workspaceId == currentWorkspaceId:
            return .systemFont(ofSize: 13, weight: .semibold)
        case .workspace:
            return .systemFont(ofSize: 13, weight: .regular)
        case .zone:
            return .systemFont(ofSize: 12, weight: .medium)
        case .tile:
            return .systemFont(ofSize: 12, weight: .regular)
        }
    }

    /// P1.11: two tokens, not four Apple semantic labels. The hierarchy the four
    /// were reaching for is preserved — the current workspace and a zone are
    /// primary, an inactive workspace and a tile row are secondary — but
    /// `tertiaryLabelColor` measured 2.07:1 on a card (P0.4 root cause 1) and could
    /// not carry a tile title at all.
    private func textColor(for item: SidebarItem) -> NSColor {
        let token: TextToken
        switch item.kind {
        case let .workspace(workspace) where workspace.workspaceId == currentWorkspaceId:
            token = .textPrimary
        case .workspace:
            token = .textSecondary
        case .zone:
            token = .textPrimary
        case .tile:
            token = .textSecondary
        }
        return token.color.nsColor(in: self)
    }

    private struct StatusPresentation {
        let glyph: String
        let text: String
        let color: NSColor
    }

    private func statusPresentation(for item: SidebarItem?) -> StatusPresentation? {
        guard let item else { return nil }
        return statusPresentation(for: item)
    }

    private func statusPresentation(for item: SidebarItem) -> StatusPresentation? {
        switch item.kind {
        case .workspace:
            return nil
        case let .zone(zone, _):
            guard let kind = zone.agentStatusRollup.dominantKind,
                  let text = zone.agentStatusRollup.displayText else {
                return StatusPresentation(glyph: glyph(for: .unknown), text: "no agent", color: color(for: .unknown))
            }
            return StatusPresentation(glyph: glyph(for: kind), text: text, color: color(for: kind))
        case let .tile(tile, _, _):
            guard let status = tile.agentStatus else {
                return StatusPresentation(glyph: glyph(for: .unknown), text: "no agent", color: color(for: .unknown))
            }
            let kind = SidebarAgentStatusKind.kind(for: status)
            return StatusPresentation(glyph: glyph(for: kind), text: text(for: kind), color: color(for: kind))
        }
    }

    private func text(for kind: SidebarAgentStatusKind) -> String {
        switch kind {
        case .working: return "working"
        case .needsAttention: return "needs you"
        case .done: return "done"
        case .stale: return "stale"
        case .unknown: return "unknown"
        }
    }

    /// `SidebarAgentStatusKind` is a domain collapse — it folds `configuring` and
    /// `idle` into `.unknown` — so it needs mapping back to the `AgentStatus`
    /// whose appearance stands for the kind before the shared presenter can be
    /// asked. `.unknown` → `.idle`, whose accent is the muted text token: the
    /// same muted read `tertiaryLabelColor` gave it. The collapse itself is NOT
    /// changed here, and `text(for:)` still says "unknown" (P1.8 "Watch out").
    private func representativeStatus(for kind: SidebarAgentStatusKind) -> AgentStatus {
        switch kind {
        case .working: return .working
        case .needsAttention: return .needsAttention
        case .done: return .done
        case .stale: return .stale
        case .unknown: return .idle
        }
    }

    // P1.8: the sidebar's private glyph and colour maps are gone — they were the
    // third disagreeing glyph set and the reason `configuring` read as
    // invisible-grey here while the tile painted it purple.
    private func glyph(for kind: SidebarAgentStatusKind) -> String {
        StatusChipPresenter.display(for: representativeStatus(for: kind)).glyph
    }

    /// The sidebar follows the system appearance, so the accent resolves in this
    /// view's own theme. (P1.11 replaced `StatusChipNSView.dynamicNSColor`, which
    /// built a dynamic `NSColor` for callers that had no view to ask.)
    private func color(for kind: SidebarAgentStatusKind) -> NSColor {
        StatusChipPresenter.display(for: representativeStatus(for: kind)).accent.nsColor(in: self)
    }

    private func accessibilityIdentifier(for item: SidebarItem) -> String {
        switch item.kind {
        case let .workspace(workspace): return "workspace-sidebar-workspace-\(workspace.workspaceId.uuidString)"
        case let .zone(zone, _): return "workspace-sidebar-zone-\(zone.zoneId.uuidString)"
        case let .tile(tile, _, _): return "workspace-sidebar-tile-\(tile.tileId.uuidString)"
        }
    }
}
