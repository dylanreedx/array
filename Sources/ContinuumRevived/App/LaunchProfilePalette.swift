import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class LaunchProfilePalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var searchField: NSSearchField?

    private var profiles: [TileSpawner.AnnotatedProfile] = []
    private var filtered: [TileSpawner.AnnotatedProfile] = []

    func show(near host: NSWindow, profiles: [TileSpawner.AnnotatedProfile]) {
        self.profiles = profiles
        self.filtered = profiles
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
        switch item.resolution {
        case let .found(profile):
            text.stringValue = "\(item.spec.displayName) — \(profile.command)"
            text.textColor = .labelColor
        case let .missing(executable):
            text.stringValue = "\(item.spec.displayName) — \(executable) not found"
            text.textColor = .secondaryLabelColor
        case let .notConfigured(profileId):
            text.stringValue = "\(item.spec.displayName) — \(profileId) not configured"
            text.textColor = .secondaryLabelColor
        }
        return cell
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let q = field.stringValue.lowercased()
        if q.isEmpty {
            filtered = profiles
        } else {
            filtered = profiles.filter { item in
                item.spec.displayName.lowercased().contains(q) || item.spec.id.contains(q)
            }
        }
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
        let item = filtered[row]
        switch item.resolution {
        case .found:
            onSelect?(item.spec.id)
            close()
        case .missing, .notConfigured:
            NSSound.beep()
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
