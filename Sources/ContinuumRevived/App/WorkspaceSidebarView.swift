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

    private let scrollView: NSScrollView
    private let outlineView: NSOutlineView
    private let column: NSTableColumn
    private let titleLabel: NSTextField
    private let actionStack: NSStackView
    private let createButton: NSButton
    private let renameButton: NSButton
    private let deleteButton: NSButton
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
        titleLabel = NSTextField(labelWithString: "Workspaces")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        createButton = NSButton(title: "New", target: nil, action: nil)
        createButton.bezelStyle = .rounded
        createButton.toolTip = "Create workspace"

        renameButton = NSButton(title: "Rename", target: nil, action: nil)
        renameButton.bezelStyle = .rounded
        renameButton.toolTip = "Rename selected workspace"

        deleteButton = NSButton(title: "Delete", target: nil, action: nil)
        deleteButton.bezelStyle = .rounded
        deleteButton.toolTip = "Delete selected workspace"

        actionStack = NSStackView(views: [createButton, renameButton, deleteButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 6
        actionStack.translatesAutoresizingMaskIntoConstraints = false

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

        super.init(frame: frameRect)

        wantsLayer = true
        applyTokens()
        setAccessibilityIdentifier("ContinuumWorkspaceSidebarRoot")
        createButton.setAccessibilityIdentifier("ContinuumWorkspaceSidebarCreate")
        renameButton.setAccessibilityIdentifier("ContinuumWorkspaceSidebarRename")
        deleteButton.setAccessibilityIdentifier("ContinuumWorkspaceSidebarDelete")
        managementMessageLabel.setAccessibilityIdentifier("ContinuumWorkspaceSidebarManagementMessage")

        addSubview(titleLabel)
        addSubview(actionStack)
        addSubview(managementMessageLabel)
        addSubview(scrollView)

        createButton.target = self
        createButton.action = #selector(createWorkspaceClicked(_:))
        renameButton.target = self
        renameButton.action = #selector(renameWorkspaceClicked(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteWorkspaceClicked(_:))

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked(_:))

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            actionStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            actionStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            actionStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            managementMessageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            managementMessageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            managementMessageLabel.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: managementMessageLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    var deleteEnabledForQA: Bool { deleteButton.isEnabled }
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

    @discardableResult
    func clickCreateForQA() -> Bool {
        guard createButton.isEnabled else { return false }
        createButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickRenameForQA() -> Bool {
        guard renameButton.isEnabled else { return false }
        renameButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickDeleteForQA() -> Bool {
        guard deleteButton.isEnabled else { return false }
        deleteButton.performClick(nil)
        return true
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

    @objc private func createWorkspaceClicked(_ sender: NSButton) {
        onCreateWorkspace?()
    }

    @objc private func renameWorkspaceClicked(_ sender: NSButton) {
        guard let workspaceId = workspaceIdForManagementAction() else { return }
        onRenameWorkspace?(workspaceId)
    }

    @objc private func deleteWorkspaceClicked(_ sender: NSButton) {
        guard let workspaceId = workspaceIdForManagementAction() else { return }
        onDeleteWorkspace?(workspaceId)
    }

    private func workspaceIdForManagementAction() -> UUID? {
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
        createButton.isEnabled = true
        renameButton.isEnabled = workspaceId != nil
        deleteButton.isEnabled = workspaceId != nil && tree.workspaces.count > 1
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
