import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class ProjectPickerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let request: ProjectLaunchCoordinator.PickerRequest
    private var filtered: [ProjectPickerRow]
    private var selectedURL: URL?
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var searchField: NSTextField?

    init(request: ProjectLaunchCoordinator.PickerRequest) {
        self.request = request
        self.filtered = request.rows
    }

    func runModal() -> URL? {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Choose a Continuum Project"
        panel.isReleasedWhenClosed = false
        panel.center()
        self.panel = panel

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 420))
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        let title = NSTextField(labelWithString: titleText(for: request.reason))
        title.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 24, y: 374, width: 572, height: 24)
        root.addSubview(title)

        let search = NSTextField(frame: NSRect(x: 24, y: 334, width: 572, height: 28))
        search.placeholderString = "Filter projects…"
        search.delegate = self
        root.addSubview(search)
        self.searchField = search

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 70, width: 572, height: 252))
        scroll.hasVerticalScroller = true
        let table = NSTableView(frame: scroll.bounds)
        table.headerView = nil
        table.rowHeight = 44
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        col.width = 572
        table.addTableColumn(col)
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(commitSelection)
        scroll.documentView = table
        root.addSubview(scroll)
        self.tableView = table

        let openButton = NSButton(title: "Open Folder…", target: self, action: #selector(openFolder))
        openButton.frame = NSRect(x: 24, y: 22, width: 140, height: 32)
        root.addSubview(openButton)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 490, y: 22, width: 106, height: 32)
        root.addSubview(cancel)
        let choose = NSButton(title: "Open", target: self, action: #selector(commitSelection))
        choose.frame = NSRect(x: 376, y: 22, width: 106, height: 32)
        root.addSubview(choose)

        panel.makeFirstResponder(search)
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return selectedURL
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        let item = filtered[row]
        let text = NSTextField(labelWithString: "\(item.name)  \(item.isLastActive ? "• last" : "")\n\(item.rootPath)\(item.isSelectable ? "" : " — \(label(for: item.availability))")")
        text.font = .monospacedSystemFont(ofSize: 12, weight: item.isSelectable ? .regular : .light)
        text.textColor = item.isSelectable ? .labelColor : .secondaryLabelColor
        text.frame = NSRect(x: 8, y: 4, width: tableView.bounds.width - 16, height: 36)
        text.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(text)
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        filtered = ProjectPickerModel.filterRows(request.rows, query: searchField?.stringValue ?? "")
        tableView?.reloadData()
        if !filtered.isEmpty { tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    @objc private func commitSelection() {
        guard let tableView, tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else { return }
        if case let .selected(url) = ProjectPickerModel.select(id: filtered[tableView.selectedRow].id, from: filtered) {
            selectedURL = url
            NSApp.stopModal()
        } else {
            NSSound.beep()
        }
    }

    @objc private func cancel() { NSApp.stopModal() }

    @objc private func openFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url {
            selectedURL = url
            NSApp.stopModal()
        }
    }

    private func titleText(for reason: ProjectRootResolver.Reason) -> String {
        switch reason {
        case .noUsableProject: "Open a project"
        case .openLastProjectDisabled: "Choose a project"
        }
    }

    private func label(for availability: ProjectPickerAvailability) -> String {
        switch availability {
        case .available: "available"
        case .missingDirectory: "missing"
        case .relativePath: "relative path"
        case .unusableStateDirectory: "cannot use state directory"
        }
    }
}
