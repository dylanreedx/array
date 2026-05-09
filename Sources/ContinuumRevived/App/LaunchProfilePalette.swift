import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class LaunchProfilePalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelectProfile: ((String) -> Void)?
    var onSelectAction: ((LaunchPaletteAction) -> Void)?

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var searchField: NSSearchField?

    private var rows: [LaunchPaletteRow] = []
    private var filtered: [LaunchPaletteRow] = []

    func show(near host: NSWindow, profiles: [TileSpawner.AnnotatedProfile]) {
        self.rows = LaunchPaletteModel.makeRows(profiles: profiles.map(Self.profileRow(for:)))
        self.filtered = rows
        let panel = ensurePanel()
        searchField?.stringValue = ""
        tableView?.reloadData()

        let frame = panel.frame
        let hostFrame = host.frame
        let x = hostFrame.midX - frame.width / 2
        let y = hostFrame.midY - frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        panel.makeFirstResponder(searchField)
    }

    func close() {
        panel?.close()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open Tile"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.titlebarAppearsTransparent = true

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search profiles…"
        search.focusRingType = .none

        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(tableDidDoubleClick(_:))
        table.rowHeight = 30
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.title = "Profile"
        column.width = 460
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        content.addSubview(search)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])

        panel.contentView = content
        // Pin contentView's autoresizing constraints
        content.translatesAutoresizingMaskIntoConstraints = false
        if let parent = content.superview {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                content.topAnchor.constraint(equalTo: parent.topAnchor),
                content.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            ])
        }

        self.panel = panel
        self.tableView = table
        self.searchField = search
        return panel
    }

    private static func profileRow(for item: TileSpawner.AnnotatedProfile) -> LaunchPaletteProfileRow {
        let detail: String
        let isSelectable: Bool
        switch item.resolution {
        case let .found(profile):
            detail = profile.command
            isSelectable = true
        case let .missing(executable):
            detail = "\(executable) not found"
            isSelectable = false
        case let .notConfigured(profileId):
            detail = "\(profileId) not configured"
            isSelectable = false
        }
        return LaunchPaletteProfileRow(
            id: item.spec.id,
            displayName: item.spec.displayName,
            detail: detail,
            isSelectable: isSelectable
        )
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        let item = filtered[row]
        switch item {
        case let .profile(profile):
            text.stringValue = "\(profile.displayName) - \(profile.detail)"
            text.textColor = profile.isSelectable ? .labelColor : .secondaryLabelColor
        case let .action(action):
            text.stringValue = action.displayName
            text.textColor = .labelColor
        }
        return cell
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        filtered = LaunchPaletteModel.filterRows(rows, query: field.stringValue)
        tableView?.reloadData()
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    @objc private func tableDidDoubleClick(_ sender: Any?) {
        commitSelection()
    }

    private func commitSelection() {
        guard let table = tableView else { return }
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        switch filtered[row] {
        case let .profile(profile):
            guard profile.isSelectable else {
                NSSound.beep()
                return
            }
            onSelectProfile?(profile.id)
            close()
        case let .action(action):
            close()
            onSelectAction?(action)
        }
    }

    private func moveSelection(by delta: Int) {
        guard let table = tableView else { return }
        let row = table.selectedRow
        let next = max(0, min(filtered.count - 1, row + delta))
        if next != row {
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }
    }
}
