import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class ProjectPickerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row {
        case workspace(ProjectLaunchCoordinator.WorkspacePickerRow)
        case project(ProjectPickerRow)

        var id: UUID {
            switch self {
            case let .workspace(row): row.workspace.id
            case let .project(row): row.id
            }
        }

        var isSelectable: Bool {
            switch self {
            case let .workspace(row): row.isSelectable
            case let .project(row): row.isSelectable
            }
        }

        func matches(_ query: String) -> Bool {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return true }
            switch self {
            case let .workspace(row): return row.workspace.name.lowercased().contains(needle)
            case let .project(row): return row.name.lowercased().contains(needle) || row.rootPath.lowercased().contains(needle)
            }
        }
    }

    private let request: ProjectLaunchCoordinator.PickerRequest
    private var filtered: [Row]
    private var selectedURL: URL?
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var searchField: NSTextField?

    init(request: ProjectLaunchCoordinator.PickerRequest) {
        self.request = request
        self.filtered = Self.rows(for: request, query: "")
    }

    func runModal() -> URL? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.appearance = NSApp?.effectiveAppearance
        panel.title = "Choose a Continuum Project"
        panel.isReleasedWhenClosed = false
        panel.center()
        self.panel = panel
        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 420)); root.autoresizingMask = [.width, .height]; panel.contentView = root
        let title = NSTextField(labelWithString: titleText(for: request.reason)); title.font = .monospacedSystemFont(ofSize: 16, weight: .semibold); title.textColor = .labelColor; title.frame = NSRect(x: 24, y: 374, width: 572, height: 24); root.addSubview(title)
        let search = NSTextField(frame: NSRect(x: 24, y: 334, width: 572, height: 28)); search.placeholderString = "Filter projects or workspaces…"; search.delegate = self; root.addSubview(search); self.searchField = search
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 70, width: 572, height: 252)); scroll.hasVerticalScroller = true
        let table = NSTableView(frame: scroll.bounds); table.headerView = nil; table.rowHeight = 44
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project")); col.width = 572; table.addTableColumn(col); table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(commitSelection); scroll.documentView = table; root.addSubview(scroll); self.tableView = table
        let openButton = NSButton(title: "Open Folder…", target: self, action: #selector(openFolder)); openButton.frame = NSRect(x: 24, y: 22, width: 140, height: 32); root.addSubview(openButton)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.frame = NSRect(x: 490, y: 22, width: 106, height: 32); root.addSubview(cancel)
        let choose = NSButton(title: "Open", target: self, action: #selector(commitSelection)); choose.frame = NSRect(x: 376, y: 22, width: 106, height: 32); root.addSubview(choose)
        panel.makeFirstResponder(search); if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        NSApp.runModal(for: panel); panel.orderOut(nil); return selectedURL
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        let item = filtered[row]
        let label: String
        switch item {
        case let .workspace(row):
            label = "Workspace: \(row.workspace.name)\n\(row.workspace.projectIds.count) project\(row.workspace.projectIds.count == 1 ? "" : "s")\(row.isSelectable ? "" : " — empty")"
        case let .project(row):
            label = "Project: \(row.name)  \(row.isLastActive ? "• last" : "")\n\(row.rootPath)\(row.isSelectable ? "" : " — \(self.label(for: row.availability))")"
        }
        let text = NSTextField(labelWithString: label); text.font = .monospacedSystemFont(ofSize: 12, weight: item.isSelectable ? .regular : .light); text.textColor = item.isSelectable ? .labelColor : .secondaryLabelColor; text.frame = NSRect(x: 8, y: 4, width: tableView.bounds.width - 16, height: 36); text.lineBreakMode = .byTruncatingMiddle; cell.addSubview(text); return cell
    }

    func controlTextDidChange(_ obj: Notification) { filtered = Self.rows(for: request, query: searchField?.stringValue ?? ""); tableView?.reloadData(); if !filtered.isEmpty { tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) } }

    @objc private func commitSelection() {
        guard let tableView, tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else { return }
        switch filtered[tableView.selectedRow] {
        case let .project(row):
            if case let .selected(url) = ProjectPickerModel.select(id: row.id, from: request.rows) { selectedURL = url; NSApp.stopModal() } else { NSSound.beep() }
        case let .workspace(row):
            guard let projectId = ProjectLaunchCoordinator.selectWorkspaceForNextLaunch(id: row.workspace.id, from: request),
                  let url = ProjectLaunchCoordinator.selectProject(id: projectId, from: request) else { NSSound.beep(); return }
            selectedURL = url; NSApp.stopModal()
        }
    }

    @objc private func cancel() { NSApp.stopModal() }
    @objc private func openFolder() { let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false; if picker.runModal() == .OK, let url = picker.url { selectedURL = url; NSApp.stopModal() } }
    private func titleText(for reason: ProjectRootResolver.Reason) -> String { switch reason { case .noUsableProject: "Open a project"; case .openLastProjectDisabled: "Choose a project" } }
    private func label(for availability: ProjectPickerAvailability) -> String { switch availability { case .available: "available"; case .missingDirectory: "missing"; case .relativePath: "relative path"; case .unusableStateDirectory: "cannot use state directory" } }
    private static func rows(for request: ProjectLaunchCoordinator.PickerRequest, query: String) -> [Row] { (request.workspaces.map(Row.workspace) + request.rows.map(Row.project)).filter { $0.matches(query) } }
}
