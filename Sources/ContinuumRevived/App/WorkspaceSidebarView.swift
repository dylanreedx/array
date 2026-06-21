import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
enum WorkspaceSidebarSelection: Equatable {
    case workspace(UUID)
    case zone(workspaceId: UUID, zoneId: UUID)
    case tile(workspaceId: UUID, zoneId: UUID, tileId: UUID)
}

@MainActor
final class WorkspaceSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
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

    private let scrollView: NSScrollView
    private let outlineView: NSOutlineView
    private let column: NSTableColumn
    private let titleLabel: NSTextField

    private var tree = SidebarTree(workspaces: [])
    private var currentWorkspaceId: UUID?
    private var rootItems: [SidebarItem] = []
    private var workspaceItemsById: [UUID: SidebarItem] = [:]
    private var zoneItemsByKey: [ZoneItemKey: SidebarItem] = [:]
    private var tileItemsByKey: [TileItemKey: SidebarItem] = [:]

    var onSelection: ((WorkspaceSidebarSelection) -> Void)?

    override init(frame frameRect: NSRect) {
        titleLabel = NSTextField(labelWithString: "Workspaces")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

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
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        setAccessibilityIdentifier("ContinuumWorkspaceSidebarRoot")

        addSubview(titleLabel)
        addSubview(scrollView)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineRowClicked(_:))

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func reload(tree: SidebarTree, currentWorkspaceId: UUID?, selectedZoneId: UUID? = nil, selectedTileId: UUID? = nil) {
        self.tree = tree
        self.currentWorkspaceId = currentWorkspaceId
        rebuildItems()
        outlineView.reloadData()
        applyDefaultExpansion(selectedZoneId: selectedZoneId, selectedTileId: selectedTileId)
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
            statusField.textColor = status.color.withAlphaComponent(0.82)
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

    @objc private func outlineRowClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard row >= 0,
              let item = sender.item(atRow: row) as? SidebarItem else { return }
        performSelection(for: item)
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

    private func textColor(for item: SidebarItem) -> NSColor {
        switch item.kind {
        case let .workspace(workspace) where workspace.workspaceId == currentWorkspaceId:
            return .labelColor
        case .workspace:
            return .secondaryLabelColor
        case .zone:
            return .labelColor
        case .tile:
            return .tertiaryLabelColor
        }
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

    private func glyph(for kind: SidebarAgentStatusKind) -> String {
        switch kind {
        case .working: return "●"
        case .needsAttention: return "◆"
        case .done: return "✓"
        case .stale: return "◌"
        case .unknown: return "○"
        }
    }

    private func color(for kind: SidebarAgentStatusKind) -> NSColor {
        switch kind {
        case .working: return .systemBlue
        case .needsAttention: return .systemOrange
        case .done: return .systemGreen
        case .stale: return .systemGray
        case .unknown: return .tertiaryLabelColor
        }
    }

    private func accessibilityIdentifier(for item: SidebarItem) -> String {
        switch item.kind {
        case let .workspace(workspace): return "workspace-sidebar-workspace-\(workspace.workspaceId.uuidString)"
        case let .zone(zone, _): return "workspace-sidebar-zone-\(zone.zoneId.uuidString)"
        case let .tile(tile, _, _): return "workspace-sidebar-tile-\(tile.tileId.uuidString)"
        }
    }
}
