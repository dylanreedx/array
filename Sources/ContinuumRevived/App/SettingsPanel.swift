import AppKit
import ContinuumRevivedCore
import Foundation

/// The generic, type-driven settings surface (docs/24 S4). A floating dark/
/// monospaced `NSPanel` — a sidebar of `SettingsSchema.sections()` titles plus a
/// detail pane that renders each section's fields *by their kind*: toggle →
/// checkbox, text → text field, choice → popup, shortcuts → read-only
/// `ShortcutCatalog` guide. Adding a section/field changes nothing here — that is
/// the extensibility contract. Field edits write LIVE through the bound
/// `SettingsField.setValue` to UserDefaults (chord capture is A7, not here).
@MainActor
final class SettingsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?

    static let rootAccessibilityIdentifier = "ContinuumSettingsPanelRoot"

    private let sections: [SettingsSection]
    private let defaults: UserDefaults

    private var panel: NSPanel?
    private var sidebar: NSTableView?
    private var detailStack: NSStackView?
    private var selectedSectionIndex = 0
    private weak var previousKeyWindow: NSWindow?

    init(sections: [SettingsSection] = SettingsSchema.sections(), defaults: UserDefaults = .standard) {
        self.sections = sections
        self.defaults = defaults
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Lifecycle

    func show(near host: NSWindow?) {
        let panel = ensurePanel()
        previousKeyWindow = host ?? NSApp.keyWindow
        if let host, host.screen != nil {
            let hostFrame = host.frame
            let size = panel.frame.size
            let origin = NSPoint(x: hostFrame.midX - size.width / 2, y: hostFrame.midY - size.height / 2)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        renderSelectedSection()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        let restoreTarget = previousKeyWindow
        sidebar?.dataSource = nil
        sidebar?.delegate = nil
        panel = nil
        sidebar = nil
        detailStack = nil
        previousKeyWindow = nil
        restoreTarget?.makeKeyAndOrderFront(nil)
        onClose?()
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = nil

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 440))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = root

        // Sidebar — section titles.
        let sidebarScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: root.bounds.height))
        sidebarScroll.autoresizingMask = [.height]
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        let sidebar = NSTableView(frame: sidebarScroll.bounds)
        sidebar.headerView = nil
        sidebar.rowHeight = 32
        sidebar.allowsMultipleSelection = false
        sidebar.backgroundColor = .clear
        let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        sidebarColumn.width = 178
        sidebar.addTableColumn(sidebarColumn)
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebarScroll.documentView = sidebar
        root.addSubview(sidebarScroll)
        self.sidebar = sidebar

        // Detail — vertical stack of field controls inside a scroll view.
        let detailScroll = NSScrollView(frame: NSRect(x: 192, y: 0, width: root.bounds.width - 192, height: root.bounds.height))
        detailScroll.autoresizingMask = [.width, .height]
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let documentClip = FlippedDocumentView()
        documentClip.translatesAutoresizingMaskIntoConstraints = false
        documentClip.addSubview(stack)
        detailScroll.documentView = documentClip
        NSLayoutConstraint.activate([
            documentClip.widthAnchor.constraint(equalTo: detailScroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentClip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentClip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentClip.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentClip.bottomAnchor),
        ])
        root.addSubview(detailScroll)
        self.detailStack = stack

        if !sections.isEmpty {
            sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        self.panel = panel
        return panel
    }

    /// A flipped document view so the field stack lays out top-down inside the
    /// scroll view (AppKit's default coordinate origin is bottom-left).
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    // MARK: - Detail rendering (type-driven)

    private func renderSelectedSection() {
        guard let stack = detailStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard sections.indices.contains(selectedSectionIndex) else { return }
        let section = sections[selectedSectionIndex]

        let header = label(section.title, size: 16, weight: .semibold, color: .labelColor)
        stack.addArrangedSubview(header)

        for field in section.fields {
            stack.addArrangedSubview(controlRow(for: field))
        }
    }

    /// Builds the control row for a field, dispatched purely on its kind. New
    /// kinds would extend this switch; new fields/sections need no change.
    private func controlRow(for field: SettingsField) -> NSView {
        switch field {
        case .toggle:
            return toggleRow(for: field)
        case .text:
            return textRow(for: field)
        case .choice(_, _, let options, _):
            return choiceRow(for: field, options: options)
        case .shortcuts:
            return shortcutsRow(for: field)
        }
    }

    private func toggleRow(for field: SettingsField) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: field.label, target: self, action: #selector(toggleChanged(_:)))
        checkbox.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        if case .bool(let on) = field.currentValue(in: defaults) {
            checkbox.state = on ? .on : .off
        }
        bindings[ObjectIdentifier(checkbox)] = field
        return checkbox
    }

    private func textRow(for field: SettingsField) -> NSView {
        let labelView = label(field.label, size: 12, weight: .regular, color: .secondaryLabelColor)
        let textField = NSTextField()
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.delegate = self
        textField.target = self
        textField.action = #selector(textCommitted(_:))
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        if case .string(let value) = field.currentValue(in: defaults) {
            textField.stringValue = value
        }
        bindings[ObjectIdentifier(textField)] = field
        return vGroup([labelView, textField])
    }

    private func choiceRow(for field: SettingsField, options: [String]) -> NSView {
        let labelView = label(field.label, size: 12, weight: .regular, color: .secondaryLabelColor)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        popup.addItems(withTitles: options)
        popup.target = self
        popup.action = #selector(choiceChanged(_:))
        if case .string(let value) = field.currentValue(in: defaults), options.contains(value) {
            popup.selectItem(withTitle: value)
        }
        bindings[ObjectIdentifier(popup)] = field
        return vGroup([labelView, popup])
    }

    private func shortcutsRow(for field: SettingsField) -> NSView {
        let labelView = label(field.label, size: 12, weight: .semibold, color: .secondaryLabelColor)
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        group.addArrangedSubview(labelView)

        let grouped = groupedShortcutEntries()
        for group_ in grouped {
            let groupTitle = label(group_.title, size: 11, weight: .semibold, color: .tertiaryLabelColor)
            group.addArrangedSubview(groupTitle)
            for entry in group_.entries {
                let row = label("\(entry.label) … \(entry.chordDisplay)", size: 11, weight: .regular, color: .labelColor)
                group.addArrangedSubview(row)
            }
        }
        return group
    }

    /// `ShortcutCatalog.entries()` grouped by layer (Global / Nav Mode / per tile
    /// kind), preserving catalog order.
    private func groupedShortcutEntries() -> [(title: String, entries: [ShortcutCatalogEntry])] {
        var order: [String] = []
        var buckets: [String: [ShortcutCatalogEntry]] = [:]
        for entry in ShortcutCatalog.entries() {
            let title = layerTitle(entry.layer)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(entry)
        }
        return order.map { (title: $0, entries: buckets[$0] ?? []) }
    }

    private func layerTitle(_ layer: ShortcutLayer) -> String {
        switch layer {
        case .global: return "Global"
        case .navMode: return "Nav Mode"
        case .tile(let kind): return "Tile — \(kind.rawValue)"
        }
    }

    // MARK: - Field write-back (live)

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let field = bindings[ObjectIdentifier(sender)] else { return }
        field.setValue(.bool(sender.state == .on), in: defaults)
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let field = bindings[ObjectIdentifier(sender)], let title = sender.titleOfSelectedItem else { return }
        field.setValue(.string(title), in: defaults)
    }

    @objc private func textCommitted(_ sender: NSTextField) {
        guard let field = bindings[ObjectIdentifier(sender)] else { return }
        field.setValue(.string(sender.stringValue), in: defaults)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, let field = bindings[ObjectIdentifier(textField)] else { return }
        field.setValue(.string(textField.stringValue), in: defaults)
    }

    private var bindings: [ObjectIdentifier: SettingsField] = [:]

    // MARK: - Helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func vGroup(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    // MARK: - NSTableViewDataSource / Delegate (sidebar)

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: sections[row].title)
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let sidebar, sidebar.selectedRow >= 0 else { return }
        selectedSectionIndex = sidebar.selectedRow
        renderSelectedSection()
    }

    // MARK: - QA accessors

    var sidebarRowCountForQA: Int { sections.count }
    var contentViewForQA: NSView? { panel?.contentView }
    var panelWindowNumberForQA: Int? { panel?.windowNumber }
    func selectSectionForQA(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        sidebar?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selectedSectionIndex = index
        renderSelectedSection()
    }
    var detailControlCountForQA: Int {
        // Header label + one row per field.
        (detailStack?.arrangedSubviews.count ?? 0)
    }
    func firstToggleControlForQA() -> NSButton? {
        detailStack?.arrangedSubviews.compactMap { $0 as? NSButton }.first
    }

    /// True when every field in the selected section produced at least one
    /// editable/displayable control of the kind its type demands (toggle →
    /// NSButton, text → NSTextField, choice → NSPopUpButton, shortcuts → a
    /// non-empty guide list).
    func selectedSectionFieldsAllRenderedForQA() -> Bool {
        guard sections.indices.contains(selectedSectionIndex) else { return false }
        guard let stack = detailStack else { return false }
        // Arranged subviews: [header] + [one row per field], in field order.
        let rows = Array(stack.arrangedSubviews.dropFirst())
        let fields = sections[selectedSectionIndex].fields
        guard rows.count == fields.count else { return false }
        for (field, row) in zip(fields, rows) {
            switch field {
            case .toggle:
                if firstDescendant(of: row, ofType: NSButton.self) == nil { return false }
            case .text:
                if firstDescendant(of: row, ofType: NSTextField.self, where: { $0.isEditable }) == nil { return false }
            case .choice:
                if firstDescendant(of: row, ofType: NSPopUpButton.self) == nil { return false }
            case .shortcuts:
                // Guide must list at least one catalog entry beyond the header.
                if !ShortcutCatalog.entries().isEmpty, descendantCount(of: row, ofType: NSTextField.self) < 2 { return false }
            }
        }
        return true
    }

    private func firstDescendant<T: NSView>(of view: NSView, ofType type: T.Type, where predicate: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, predicate(match) { return match }
        for subview in view.subviews {
            if let found = firstDescendant(of: subview, ofType: type, where: predicate) { return found }
        }
        return nil
    }

    private func descendantCount<T: NSView>(of view: NSView, ofType type: T.Type) -> Int {
        var count = (view is T) ? 1 : 0
        for subview in view.subviews { count += descendantCount(of: subview, ofType: type) }
        return count
    }

    // MARK: - Self-check (docs/24 S4 — `--settings-panel-check`)

    enum SettingsPanelSelfCheckError: Error, CustomStringConvertible {
        case wrongSidebarCount(Int, expected: Int)
        case sectionFieldsNotRendered(String)
        case toggleDidNotRoundTrip(stored: Bool?, expected: Bool)
        case noGeneralToggle
        case blankRender(colors: Int, width: Int, height: Int)
        case leakedPanel

        var description: String {
            switch self {
            case let .wrongSidebarCount(actual, expected):
                return "sidebar row count \(actual), expected \(expected)"
            case let .sectionFieldsNotRendered(title):
                return "section \(title) did not render a control for every field"
            case let .toggleDidNotRoundTrip(stored, expected):
                return "toggle round-trip: stored \(String(describing: stored)), expected \(expected)"
            case .noGeneralToggle:
                return "could not find a toggle in the General section to round-trip"
            case let .blankRender(colors, width, height):
                return "panel render is blank/uniform (grey-screen guard): \(colors) sampled colors at \(width)x\(height)"
            case .leakedPanel:
                return "settings panel window leaked after close"
            }
        }
    }

    static func runSelfCheck() throws {
        let suite = "continuum.settingsPanel.selfcheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw SettingsPanelSelfCheckError.blankRender(colors: 0, width: 0, height: 0)
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let sections = SettingsSchema.sections()
        let panel = SettingsPanel(sections: sections, defaults: defaults)
        panel.show(near: nil)

        // 1. Sidebar mirrors the schema exactly.
        guard panel.sidebarRowCountForQA == sections.count else {
            throw SettingsPanelSelfCheckError.wrongSidebarCount(panel.sidebarRowCountForQA, expected: sections.count)
        }

        // 2. Every section's fields each produce a control of the right kind.
        for (index, section) in sections.enumerated() {
            panel.selectSectionForQA(index)
            guard panel.selectedSectionFieldsAllRenderedForQA() else {
                throw SettingsPanelSelfCheckError.sectionFieldsNotRendered(section.title)
            }
        }

        // 3. A General toggle round-trips: flip the checkbox → bound setValue
        // wrote UserDefaults → currentValue reflects it.
        let generalIndex = sections.firstIndex { $0.id == "general" } ?? 0
        panel.selectSectionForQA(generalIndex)
        guard let toggle = panel.firstToggleControlForQA(),
              let toggleField = sections[generalIndex].fields.first(where: { if case .toggle = $0 { return true }; return false }),
              let key = toggleField.key else {
            throw SettingsPanelSelfCheckError.noGeneralToggle
        }
        let initial: Bool
        if case .bool(let value) = toggleField.currentValue(in: defaults) { initial = value } else { initial = false }
        let target = !initial
        // The checkbox renders reflecting `initial`; one click flips it to
        // `target` and fires the bound action (which writes UserDefaults).
        toggle.performClick(nil)
        let storedAfter = defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : nil
        guard case .bool(let reflected) = toggleField.currentValue(in: defaults), reflected == target, storedAfter == target else {
            throw SettingsPanelSelfCheckError.toggleDidNotRoundTrip(stored: storedAfter, expected: target)
        }

        // 4. Visual gate (docs/26): the rendered content must not be blank/uniform.
        guard let content = panel.contentViewForQA,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw SettingsPanelSelfCheckError.blankRender(colors: 0, width: 0, height: 0)
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let metrics = VisualSnapshot.metrics(of: rep)
        guard !metrics.isBlank else {
            throw SettingsPanelSelfCheckError.blankRender(colors: metrics.distinctSampledColors, width: metrics.width, height: metrics.height)
        }

        // 5. Clean teardown — no leaked window.
        let panelWindowNumber = panel.panelWindowNumberForQA
        panel.close()
        if let panelWindowNumber, NSApp.windows.contains(where: { $0.windowNumber == panelWindowNumber && $0.isVisible }) {
            throw SettingsPanelSelfCheckError.leakedPanel
        }
    }
}
