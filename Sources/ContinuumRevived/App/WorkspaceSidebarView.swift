import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class WorkspaceSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
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

    func reload(tree: SidebarTree, currentWorkspaceId: UUID?) {
        self.tree = tree
        self.currentWorkspaceId = currentWorkspaceId
        rebuildItems()
        outlineView.reloadData()
        applyDefaultExpansion()
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
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    var workspaceRowsRenderedForQA: Int { visibleItems().filter { if case .workspace = $0.kind { return true }; return false }.count }
    var zoneRowsRenderedForQA: Int { visibleItems().filter { if case .zone = $0.kind { return true }; return false }.count }
    var tileRowsRenderedForQA: Int { visibleItems().filter { if case .tile = $0.kind { return true }; return false }.count }
    var visibleDisplayNamesForQA: [String] { visibleItems().map(displayTitle(for:)) }

    func isWorkspaceExpandedForQA(_ workspaceId: UUID) -> Bool {
        guard let item = workspaceItemsById[workspaceId] else { return false }
        return outlineView.isItemExpanded(item)
    }

    func isWorkspaceSelectedForQA(_ workspaceId: UUID) -> Bool {
        guard let item = workspaceItemsById[workspaceId] else { return false }
        return outlineView.row(forItem: item) == outlineView.selectedRow
    }

    private func rebuildItems() {
        workspaceItemsById.removeAll()
        rootItems = tree.workspaces.map { workspace in
            let workspaceItem = SidebarItem(kind: .workspace(workspace))
            workspaceItem.children = workspace.zones.map { zone in
                let zoneItem = SidebarItem(kind: .zone(zone, workspaceId: workspace.workspaceId))
                zoneItem.children = zone.tiles.map { tile in
                    SidebarItem(kind: .tile(tile, zoneId: zone.zoneId, workspaceId: workspace.workspaceId))
                }
                return zoneItem
            }
            workspaceItemsById[workspace.workspaceId] = workspaceItem
            return workspaceItem
        }
    }

    private func applyDefaultExpansion() {
        for item in rootItems {
            outlineView.collapseItem(item, collapseChildren: true)
        }
        guard let currentWorkspaceId,
              let currentItem = workspaceItemsById[currentWorkspaceId] else { return }
        outlineView.expandItem(currentItem, expandChildren: false)
        for zoneItem in currentItem.children {
            outlineView.expandItem(zoneItem, expandChildren: false)
        }
        let row = outlineView.row(forItem: currentItem)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
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

    private func accessibilityIdentifier(for item: SidebarItem) -> String {
        switch item.kind {
        case let .workspace(workspace): return "workspace-sidebar-workspace-\(workspace.workspaceId.uuidString)"
        case let .zone(zone, _): return "workspace-sidebar-zone-\(zone.zoneId.uuidString)"
        case let .tile(tile, _, _): return "workspace-sidebar-tile-\(tile.tileId.uuidString)"
        }
    }
}
