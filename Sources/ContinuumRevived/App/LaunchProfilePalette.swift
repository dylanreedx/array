import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class LaunchProfilePalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onSelectProfile: ((String) -> Void)?
    var onSelectAction: ((LaunchPaletteAction) -> Void)?
    var onClose: (() -> Void)?

    static let rootAccessibilityIdentifier = "ContinuumLaunchProfilePaletteRoot"

    private var paletteView: NSView?
    private var tableView: NSTableView?
    private var searchField: NSTextField?

    private var rows: [LaunchPaletteRow] = []
    private var filtered: [LaunchPaletteRow] = []
    private weak var previousFirstResponder: NSResponder?
    private weak var previousFirstResponderWindow: NSWindow?

    func show(near host: NSWindow, profiles: [TileSpawner.AnnotatedProfile], projects: [ProjectPickerRow] = [], workspaces: [WorkspaceEntry] = [], contextualActions: [LaunchPaletteAction] = [], harnessRoles: [HarnessRole] = [], jumpTiles: [JumpTileRow] = [], jumpZones: [JumpZoneRow] = [], initialQuery: String = "") {
        self.rows = LaunchPaletteModel.makeRows(profiles: profiles.map(Self.profileRow(for:)), projects: projects, workspaces: workspaces, contextualActions: contextualActions, harnessRoles: harnessRoles, jumpTiles: jumpTiles, jumpZones: jumpZones)
        self.filtered = initialQuery.isEmpty ? rows : LaunchPaletteModel.filterRows(rows, query: initialQuery)
        guard let hostView = host.contentView else { return }
        let wasVisible = isVisible
        let paletteView = ensurePaletteView()
        if !wasVisible {
            capturePreviousFirstResponder(in: host)
        }
        if paletteView.superview !== hostView {
            paletteView.removeFromSuperview()
            hostView.addSubview(paletteView)
        }
        searchField?.stringValue = initialQuery
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
        close(restoreFocus: true)
    }

    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter.
            commitSelection()
            return true
        case 53: // Escape.
            close(restoreFocus: true)
            return true
        case 125: // Down arrow.
            moveSelection(by: 1)
            return true
        case 126: // Up arrow.
            moveSelection(by: -1)
            return true
        case 51: // Delete / Backspace.
            guard let searchField else { return true }
            if !searchField.stringValue.isEmpty {
                searchField.stringValue.removeLast()
                applyFilter(query: searchField.stringValue)
            }
            return true
        default:
            guard let characters = event.characters, !characters.isEmpty else { return false }
            guard characters.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { return false }
            guard let searchField else { return true }
            searchField.stringValue += characters
            applyFilter(query: searchField.stringValue)
            return true
        }
    }

    private func close(restoreFocus: Bool) {
        let window = previousFirstResponderWindow ?? paletteView?.window
        let currentWasPaletteResponder = isPaletteResponder(window?.firstResponder)
        let shouldRestore = restoreFocus && shouldRestorePreviousFirstResponder(in: window)
        searchField?.delegate = nil
        tableView?.dataSource = nil
        tableView?.delegate = nil
        tableView?.target = nil
        paletteView?.removeFromSuperview()
        if shouldRestore,
           let window,
           let responder = previousFirstResponder,
           isRestorable(responder, in: window) {
            window.makeFirstResponder(responder)
        } else if restoreFocus, currentWasPaletteResponder {
            window?.makeFirstResponder(nil)
        }
        previousFirstResponder = nil
        previousFirstResponderWindow = nil
        paletteView = nil
        tableView = nil
        searchField = nil
        rows.removeAll()
        filtered.removeAll()
        onClose?()
    }

    var isVisible: Bool { paletteView?.superview != nil }

    var searchTextForQA: String { searchField?.stringValue ?? "" }
    var filteredDisplayNamesForQA: [String] { filtered.map(\.displayName) }

    var selectedDisplayNameForQA: String? {
        guard let tableView, tableView.selectedRow >= 0, tableView.selectedRow < filtered.count else { return nil }
        switch filtered[tableView.selectedRow] {
        case let .action(action): return action.displayName
        case let .profile(profile): return profile.displayName
        case let .project(project): return "Switch to \(project.name)"
        case let .workspace(workspace): return "Switch to \(workspace.name) Workspace"
        case let .workspaceAction(action, workspace):
            switch action {
            case .renameWorkspace: return "Rename \(workspace.name) Workspace…"
            case .deleteWorkspace: return "Delete \(workspace.name) Workspace…"
            default: return action.displayName
            }
        case let .jumpToTile(tile): return "Jump to \(tile.title)"
        case let .jumpToZone(zone): return "Jump to \(zone.title)"
        }
    }

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

    static func runFirstResponderRestoreSelfCheck() throws {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let hostView = NSView(frame: host.contentRect(forFrameRect: host.frame))
        host.contentView = hostView
        let probe = SemanticTypingProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 40))
        hostView.addSubview(probe)
        let palette = LaunchProfilePalette()
        let profiles: [TileSpawner.AnnotatedProfile] = []

        try runRestoreSelfCheckScenario(
            name: "escape",
            host: host,
            hostView: hostView,
            probe: probe,
            palette: palette,
            profiles: profiles,
            sentinel: "escape-sentinel"
        ) {
            guard let searchField = palette.searchField else {
                throw PaletteSelfCheckError.missingSearchField
            }
            _ = palette.control(searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }

        try runRestoreSelfCheckScenario(
            name: "direct-close",
            host: host,
            hostView: hostView,
            probe: probe,
            palette: palette,
            profiles: profiles,
            sentinel: "direct-sentinel"
        ) {
            palette.close()
        }

        let foundProfiles = [TileSpawner.AnnotatedProfile(
            spec: LaunchProfileSpec(id: "qa", displayName: "QA", kind: .shell, title: "QA"),
            resolution: .found(LaunchProfile(command: "/bin/zsh", arguments: [], cwd: "/tmp", title: "QA"))
        )]
        try runRestoreSelfCheckScenario(
            name: "selection-without-new-focus",
            host: host,
            hostView: hostView,
            probe: probe,
            palette: palette,
            profiles: foundProfiles,
            sentinel: "selection-sentinel"
        ) {
            _ = palette.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }

        let selectionFocusTarget = SemanticTypingProbeView(frame: NSRect(x: 300, y: 20, width: 120, height: 40))
        hostView.addSubview(selectionFocusTarget)
        palette.onSelectProfile = { _ in
            host.makeFirstResponder(selectionFocusTarget)
        }
        try runSelectionDoesNotStealNewFocusScenario(
            host: host,
            hostView: hostView,
            previousProbe: probe,
            newFocusProbe: selectionFocusTarget,
            palette: palette,
            profiles: foundProfiles
        )
        palette.onSelectProfile = nil

        // Stale/removed responder safety: closing must not attempt to restore a
        // view that has been detached while the palette is open.
        let staleProbe = SemanticTypingProbeView(frame: NSRect(x: 160, y: 20, width: 120, height: 40))
        hostView.addSubview(staleProbe)
        guard host.makeFirstResponder(staleProbe), host.firstResponder === staleProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "stale probe precondition")
        }
        palette.show(near: host, profiles: profiles)
        staleProbe.removeFromSuperview()
        palette.close()
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        guard host.firstResponder !== staleProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder("detached stale probe", expected: "non-stale responder")
        }
    }

    enum PaletteSelfCheckError: Error, CustomStringConvertible {
        case unexpectedRootCount(Int, expected: Int)
        case missingSearchField
        case paletteDidNotTakeFocus(String)
        case unexpectedFirstResponder(String, expected: String)
        case typingProbeMissedSentinel(String, got: String)
        case failed(String)

        var description: String {
            switch self {
            case let .unexpectedRootCount(actual, expected):
                return "expected palette root count \(expected), got \(actual)"
            case .missingSearchField:
                return "palette search field was not created"
            case let .paletteDidNotTakeFocus(actual):
                return "palette/search did not take focus; got \(actual)"
            case let .unexpectedFirstResponder(actual, expected):
                return "restored \(actual), expected \(expected)"
            case let .typingProbeMissedSentinel(sentinel, got):
                return "typing sentinel \(sentinel) did not land in probe; got \(got)"
            case let .failed(message):
                return message
            }
        }
    }

    private static func runRestoreSelfCheckScenario(
        name: String,
        host: NSWindow,
        hostView: NSView,
        probe: SemanticTypingProbeView,
        palette: LaunchProfilePalette,
        profiles: [TileSpawner.AnnotatedProfile],
        sentinel: String,
        closePalette: () throws -> Void
    ) throws {
        probe.typed = ""
        guard host.makeFirstResponder(probe), host.firstResponder === probe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "probe before \(name)")
        }
        palette.show(near: host, profiles: profiles)
        guard paletteRootCount(in: hostView) == 1 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
        }
        guard palette.isPaletteResponder(host.firstResponder) else {
            throw PaletteSelfCheckError.paletteDidNotTakeFocus(String(describing: host.firstResponder))
        }

        // Re-show while visible must not overwrite the saved responder with the
        // palette's own search responder.
        palette.show(near: host, profiles: profiles)
        guard paletteRootCount(in: hostView) == 1 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
        }
        try closePalette()
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        guard host.firstResponder === probe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "probe after \(name)")
        }
        probe.keyDown(with: NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: host.windowNumber,
            context: nil,
            characters: sentinel,
            charactersIgnoringModifiers: sentinel,
            isARepeat: false,
            keyCode: 0
        )!)
        guard probe.typed == sentinel else {
            throw PaletteSelfCheckError.typingProbeMissedSentinel(sentinel, got: probe.typed)
        }
    }

    private static func runSelectionDoesNotStealNewFocusScenario(
        host: NSWindow,
        hostView: NSView,
        previousProbe: SemanticTypingProbeView,
        newFocusProbe: SemanticTypingProbeView,
        palette: LaunchProfilePalette,
        profiles: [TileSpawner.AnnotatedProfile]
    ) throws {
        guard host.makeFirstResponder(previousProbe), host.firstResponder === previousProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "previous probe before selection")
        }
        palette.show(near: host, profiles: profiles)
        guard paletteRootCount(in: hostView) == 1 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
        }
        _ = palette.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        guard host.firstResponder === newFocusProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "new selection focus")
        }
    }

    private final class SemanticTypingProbeView: NSView {
        var typed = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            typed += event.charactersIgnoringModifiers ?? ""
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

        let search = NSTextField()
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

    private func capturePreviousFirstResponder(in host: NSWindow) {
        guard let responder = semanticRestorableResponder(for: host.firstResponder),
              !isPaletteResponder(responder),
              isRestorable(responder, in: host) else {
            previousFirstResponder = nil
            previousFirstResponderWindow = nil
            return
        }
        previousFirstResponder = responder
        previousFirstResponderWindow = host
    }

    private func semanticRestorableResponder(for responder: NSResponder?) -> NSResponder? {
        guard let responder else { return nil }
        if let fieldEditor = responder as? NSTextView,
           let owner = fieldEditor.delegate as? NSResponder,
           owner !== searchField {
            return owner
        }
        return responder
    }

    private func shouldRestorePreviousFirstResponder(in window: NSWindow?) -> Bool {
        guard let window,
              let responder = previousFirstResponder,
              isRestorable(responder, in: window) else { return false }

        // Do not steal focus back if a successful selection or another app path
        // already moved focus to a non-palette responder. Restore only when the
        // palette still owns focus, or AppKit has cleared it during teardown.
        guard let current = window.firstResponder else { return true }
        return isPaletteResponder(current) || current === responder
    }

    private func isRestorable(_ responder: NSResponder, in window: NSWindow) -> Bool {
        if let view = responder as? NSView {
            return view.window === window && !isDescendantOfPalette(view)
        }
        return responder !== window
    }

    private func isPaletteResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === searchField || responder === tableView || responder === paletteView {
            return true
        }
        if let fieldEditor = responder as? NSTextView,
           searchField?.currentEditor() === fieldEditor {
            return true
        }
        if let view = responder as? NSView {
            return isDescendantOfPalette(view)
        }
        return false
    }

    private func isDescendantOfPalette(_ view: NSView) -> Bool {
        guard let paletteView else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate === paletteView { return true }
            current = candidate.superview
        }
        return false
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
            text.stringValue = "\(profile.displayName) — \(profile.detail)"
            text.textColor = profile.isSelectable ? .labelColor : .secondaryLabelColor
        case let .action(action):
            text.stringValue = action.displayName
            text.textColor = .labelColor
        case let .project(project):
            text.stringValue = "Switch to \(project.name) — \(project.rootPath)"
            text.textColor = project.isSelectable ? .labelColor : .secondaryLabelColor
        case let .workspace(workspace):
            text.stringValue = "Switch to \(workspace.name) Workspace — \(workspace.projectIds.count) project(s)"
            text.textColor = workspace.projectIds.isEmpty ? .secondaryLabelColor : .labelColor
        case let .workspaceAction(action, workspace):
            text.stringValue = "\(action.displayName) \(workspace.name)"
            text.textColor = .labelColor
        case let .jumpToTile(tile):
            text.stringValue = "Jump to \(tile.title)"
            text.textColor = .labelColor
        case let .jumpToZone(zone):
            text.stringValue = "Jump to \(zone.title)"
            text.textColor = .labelColor
        }
        return cell
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyFilter(query: field.stringValue)
    }

    private func applyFilter(query: String) {
        filtered = LaunchPaletteModel.filterRows(rows, query: query)
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
            close(restoreFocus: true)
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
            close(restoreFocus: true)
        case let .action(action):
            onSelectAction?(action)
            close(restoreFocus: true)
        case let .project(project):
            guard project.isSelectable else {
                NSSound.beep()
                return
            }
            onSelectAction?(.addProjectToCanvas(project.id))
            close(restoreFocus: true)
        case let .workspace(workspace):
            guard !workspace.projectIds.isEmpty else {
                NSSound.beep()
                return
            }
            onSelectAction?(.switchWorkspace(workspace.id))
            close(restoreFocus: true)
        case let .workspaceAction(action, _):
            onSelectAction?(action)
            close(restoreFocus: true)
        case let .jumpToTile(tile):
            onSelectAction?(.jumpToTile(tile.id))
            close(restoreFocus: true)
        case let .jumpToZone(zone):
            onSelectAction?(.jumpToZone(zone.id))
            close(restoreFocus: true)
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
