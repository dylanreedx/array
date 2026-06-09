import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class LaunchProfilePalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?

    static let rootAccessibilityIdentifier = "ContinuumLaunchProfilePaletteRoot"

    private var paletteView: NSView?
    private var tableView: NSTableView?
    private var searchField: NSSearchField?

    private var profiles: [TileSpawner.AnnotatedProfile] = []
    private var filtered: [TileSpawner.AnnotatedProfile] = []

    func show(near host: NSWindow, profiles: [TileSpawner.AnnotatedProfile]) {
        self.profiles = profiles
        self.filtered = profiles
        guard let hostView = host.contentView else { return }
        let paletteView = ensurePaletteView()
        if paletteView.superview !== hostView {
            paletteView.removeFromSuperview()
            hostView.addSubview(paletteView)
        }
        searchField?.stringValue = ""
        tableView?.reloadData()

        let size = NSSize(width: 480, height: 320)
        let hostBounds = hostView.bounds
        let x = hostBounds.midX - size.width / 2
        let y = hostBounds.midY - size.height / 2
        paletteView.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        host.makeFirstResponder(searchField)
    }

    func close() {
        paletteView?.removeFromSuperview()
    }

    var isVisible: Bool { paletteView?.superview != nil }

    static func paletteRootCount(in hostView: NSView) -> Int {
        hostView.subviews.filter { $0.accessibilityIdentifier() == rootAccessibilityIdentifier }.count
    }

    static func runDuplicateRootSelfCheck() throws {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let hostView = NSView(frame: host.contentRect(forFrameRect: host.frame))
        host.contentView = hostView
        let palette = LaunchProfilePalette()
        let profiles: [TileSpawner.AnnotatedProfile] = []
        for _ in 0..<5 {
            palette.show(near: host, profiles: profiles)
            guard paletteRootCount(in: hostView) == 1 else {
                throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
            }
        }
        palette.close()
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
    }

    enum PaletteSelfCheckError: Error, CustomStringConvertible {
        case unexpectedRootCount(Int, expected: Int)

        var description: String {
            switch self {
            case let .unexpectedRootCount(actual, expected):
                return "expected palette root count \(expected), got \(actual)"
            }
        }
    }

    private func ensurePaletteView() -> NSView {
        if let paletteView { return paletteView }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        content.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.borderWidth = 1
        content.layer?.cornerRadius = 8

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

        self.paletteView = content
        self.tableView = table
        self.searchField = search
        return content
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
