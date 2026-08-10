import AppKit
import ContinuumRevivedCore
import Foundation

/// The generic, type-driven settings surface (docs/24 S4). A floating dark/
/// monospaced `NSPanel` — a sidebar of `SettingsSchema.sections()` titles plus a
/// detail pane that renders each section's fields *by their kind*: toggle →
/// checkbox, text → text field, choice → popup, info → copy, shortcuts → read-only
/// `ShortcutCatalog` guide. Adding a section/field changes nothing here — that is
/// the extensibility contract. Field edits write LIVE through the bound
/// `SettingsField.setValue` to UserDefaults (chord capture is A7, not here).
@MainActor
final class SettingsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    /// Live-apply hook: after a leader/nav rebind the panel persists the override
    /// and hands the re-resolved `NavKeymap` back so the app can refresh its live
    /// keymaps (no relaunch). The app should also update `navKeymap` here.
    var onKeymapChanged: ((NavKeymap) -> Void)?

    static let rootAccessibilityIdentifier = "ContinuumSettingsPanelRoot"

    private let sections: [SettingsSection]
    private let defaults: UserDefaults
    /// The current keymap, used to display nav/leader chords and as the base for
    /// edits + collision classification. Persisted edits re-resolve into this.
    private var navKeymap: NavKeymap

    private var panel: NSPanel?
    private var sidebar: NSTableView?
    private var detailStack: NSStackView?
    private var selectedSectionIndex = 0
    private weak var previousKeyWindow: NSWindow?

    init(sections: [SettingsSection] = SettingsSchema.sections(), defaults: UserDefaults = .standard, navKeymap: NavKeymap = .resolve()) {
        self.sections = sections
        self.defaults = defaults
        self.navKeymap = navKeymap
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 470),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSApp?.effectiveAppearance
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = nil

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 760, height: 470))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.appResolvedCGColor
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
        case .info:
            return infoRow(for: field)
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
        // The default-model field uses the same provider>model picker as the
        // tile composer: one component, one data source (the live catalogue),
        // instead of a flat popup repeating provider/model per row.
        if field.key == AgentModelConfig.modelKey {
            return modelPickerRow(for: field, options: options)
        }
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

    private func modelPickerRow(for field: SettingsField, options: [String]) -> NSView {
        let labelView = label(field.label, size: 12, weight: .regular, color: .secondaryLabelColor)
        let button = ProviderModelButton(title: field.label)
        button.items = options.map {
            ChoiceItem(id: $0, title: AgentModelCatalog.shared.displayName(for: $0) ?? $0)
        }
        if case .string(let value) = field.currentValue(in: defaults), options.contains(value) {
            button.selectedID = value
        }
        button.onSelection = { [weak self] item in
            guard let self else { return }
            field.setValue(.string(item.id), in: self.defaults)
            self.notifySettingsChanged()
        }
        modelPickerButtonForQA = button
        return vGroup([labelView, button])
    }

    private func infoRow(for field: SettingsField) -> NSView {
        let labelView = label(field.label, size: 11, weight: .regular, color: .secondaryLabelColor)
        labelView.maximumNumberOfLines = 0
        labelView.lineBreakMode = .byWordWrapping
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        return labelView
    }

    private func shortcutsRow(for field: SettingsField) -> NSView {
        shortcutRowsById.removeAll()
        editButtonToEntryId.removeAll()
        resetButtonToEntryId.removeAll()
        shortcutGroupButtonTitles.removeAll()

        let grouped = groupedShortcutEntries()
        if selectedShortcutGroup == nil || !grouped.contains(where: { $0.title == selectedShortcutGroup }) {
            selectedShortcutGroup = grouped.first?.title
        }

        // Left rail — jump between shortcut groups; selecting one filters the pane.
        let rail = NSStackView()
        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 2
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.widthAnchor.constraint(equalToConstant: 120).isActive = true
        for group_ in grouped {
            let selected = group_.title == selectedShortcutGroup
            let button = NSButton(title: group_.title, target: self, action: #selector(selectShortcutGroup(_:)))
            button.isBordered = false
            button.alignment = .left
            button.attributedTitle = NSAttributedString(string: group_.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            ])
            shortcutGroupButtonTitles[ObjectIdentifier(button)] = group_.title
            rail.addArrangedSubview(button)
        }

        // Right content — the selected group's shortcut rows.
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        if let selected = grouped.first(where: { $0.title == selectedShortcutGroup }) {
            content.addArrangedSubview(label(selected.title, size: 12, weight: .semibold, color: .labelColor))
            for entry in selected.entries {
                content.addArrangedSubview(shortcutEntryRow(for: entry))
            }
        }

        let row = NSStackView(views: [rail, content])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 18
        return row
    }

    @objc private func selectShortcutGroup(_ sender: NSButton) {
        guard let title = shortcutGroupButtonTitles[ObjectIdentifier(sender)] else { return }
        selectedShortcutGroup = title
        renderSelectedSection()
    }

    /// QA/edit helper: ensure the group containing `entryId` is the one rendered,
    /// so its row exists in `shortcutRowsById` before capture/reset/inspection.
    private func ensureShortcutEntryRendered(_ entryId: String) {
        if shortcutRowsById[entryId] != nil { return }
        for group_ in groupedShortcutEntries() where group_.entries.contains(where: { $0.id == entryId }) {
            selectedShortcutGroup = group_.title
            renderSelectedSection()
            return
        }
    }

    /// One catalog-entry row. Non-configurable rows are static text. Configurable
    /// rows add an Edit button (→ chord capture) and a Reset button (→ clear the
    /// override). The current chord is rendered from the panel's live keymap.
    private func shortcutEntryRow(for entry: ShortcutCatalogEntry) -> NSView {
        // Fixed-width name + chord columns so every row's chord lines up in a
        // vertical column (variable-width names otherwise let the chords drift).
        let nameLabel = label(entry.label, size: 11, weight: .regular, color: .labelColor)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let chordLabel = label(entry.chordDisplay, size: 11, weight: .regular, color: .secondaryLabelColor)
        chordLabel.translatesAutoresizingMaskIntoConstraints = false
        chordLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(chordLabel)

        guard entry.configurable, let target = entry.editTarget else {
            return row
        }

        let editButton = NSButton(title: "Edit", target: self, action: #selector(beginEditingShortcut(_:)))
        editButton.bezelStyle = .rounded
        editButton.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetShortcut(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        row.addArrangedSubview(editButton)
        row.addArrangedSubview(resetButton)

        let context = ShortcutRowContext(entry: entry, target: target, row: row, chordLabel: chordLabel,
                                          editButton: editButton, resetButton: resetButton)
        shortcutRowsById[entry.id] = context
        editButtonToEntryId[ObjectIdentifier(editButton)] = entry.id
        resetButtonToEntryId[ObjectIdentifier(resetButton)] = entry.id
        return row
    }

    /// `ShortcutCatalog.entries(navKeymap:)` grouped by layer (Global / Nav Mode /
    /// per tile kind), preserving catalog order. Threads the panel's live keymap
    /// so nav/leader rows show their current (possibly edited) chord.
    private func groupedShortcutEntries() -> [(title: String, entries: [ShortcutCatalogEntry])] {
        var order: [String] = []
        var buckets: [String: [ShortcutCatalogEntry]] = [:]
        for entry in ShortcutCatalog.entries(navKeymap: navKeymap, defaults: defaults) {
            let title = layerTitle(entry.layer)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(entry)
        }
        return order.map { (title: $0, entries: buckets[$0] ?? []) }
    }

    // MARK: - Keybind editing (live)

    /// Per-row live state needed to swap in the capture view and re-render the
    /// chord after an edit.
    private final class ShortcutRowContext {
        let entry: ShortcutCatalogEntry
        let target: KeybindEditTarget
        let row: NSStackView
        let chordLabel: NSTextField
        let editButton: NSButton
        let resetButton: NSButton
        var captureView: ChordCaptureView?

        init(entry: ShortcutCatalogEntry, target: KeybindEditTarget, row: NSStackView, chordLabel: NSTextField, editButton: NSButton, resetButton: NSButton) {
            self.entry = entry
            self.target = target
            self.row = row
            self.chordLabel = chordLabel
            self.editButton = editButton
            self.resetButton = resetButton
        }
    }

    private var shortcutRowsById: [String: ShortcutRowContext] = [:]
    private var editButtonToEntryId: [ObjectIdentifier: String] = [:]
    private var resetButtonToEntryId: [ObjectIdentifier: String] = [:]
    private var selectedShortcutGroup: String?
    private var shortcutGroupButtonTitles: [ObjectIdentifier: String] = [:]

    @objc private func beginEditingShortcut(_ sender: NSButton) {
        guard let id = editButtonToEntryId[ObjectIdentifier(sender)], let context = shortcutRowsById[id] else { return }
        beginCapture(in: context)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let id = resetButtonToEntryId[ObjectIdentifier(sender)], let context = shortcutRowsById[id] else { return }
        if let resolved = KeybindEditor.reset(target: context.target, defaults: defaults) {
            applyResolvedKeymap(resolved)
        }
        renderSelectedSection()
    }

    private func beginCapture(in context: ShortcutRowContext) {
        let capture = ChordCaptureView()
        context.captureView = capture
        // Replace the chord label with the capture field while editing.
        let row = context.row
        let labelIndex = row.arrangedSubviews.firstIndex(of: context.chordLabel) ?? 1
        context.chordLabel.isHidden = true
        row.insertArrangedSubview(capture, at: labelIndex)
        capture.onCapture = { [weak self] keyCode, modifiers, character in
            self?.finishCapture(context, keyCode: keyCode, modifiers: modifiers, character: character)
        }
        capture.onCancel = { [weak self] in
            self?.cancelCapture(context)
        }
        capture.beginCapture()
    }

    @discardableResult
    private func finishCapture(_ context: ShortcutRowContext, keyCode: UInt16, modifiers: FocusKeyModifiers, character: String?) -> KeybindEditor.Result {
        let result = KeybindEditor.apply(
            target: context.target,
            keyCode: keyCode,
            modifiers: modifiers,
            character: character,
            currentNavKeymap: navKeymap,
            defaults: defaults
        )
        switch result {
        case .applied(let resolved):
            if let resolved { applyResolvedKeymap(resolved) }
            renderSelectedSection()
        case .rejected:
            // Surface gracefully: beep and leave the binding as it was, then
            // restore the static row.
            NSSound.beep()
            cancelCapture(context)
        }
        return result
    }

    private func cancelCapture(_ context: ShortcutRowContext) {
        if let capture = context.captureView {
            context.row.removeArrangedSubview(capture)
            capture.removeFromSuperview()
            context.captureView = nil
        }
        context.chordLabel.isHidden = false
        panel?.makeFirstResponder(nil)
    }

    /// Updates the panel's keymap and notifies the app to live-apply it.
    private func applyResolvedKeymap(_ resolved: NavKeymap) {
        navKeymap = resolved
        onKeymapChanged?(resolved)
    }

    private func layerTitle(_ layer: ShortcutLayer) -> String {
        switch layer {
        case .global: return "Global"
        case .navMode: return "Nav Mode"
        case .inbox: return "Agent Inbox"
        case .tile(let kind): return "Tile — \(kind.rawValue)"
        }
    }

    // MARK: - Field write-back (live)

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let field = bindings[ObjectIdentifier(sender)] else { return }
        field.setValue(.bool(sender.state == .on), in: defaults)
        notifySettingsChanged()
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let field = bindings[ObjectIdentifier(sender)], let title = sender.titleOfSelectedItem else { return }
        field.setValue(.string(title), in: defaults)
        notifySettingsChanged()
    }

    @objc private func textCommitted(_ sender: NSTextField) {
        guard let field = bindings[ObjectIdentifier(sender)] else { return }
        field.setValue(.string(sender.stringValue), in: defaults)
        notifySettingsChanged()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, let field = bindings[ObjectIdentifier(textField)] else { return }
        field.setValue(.string(textField.stringValue), in: defaults)
        notifySettingsChanged()
    }

    /// Notify live consumers (e.g. the focus-border overlay) that a preference
    /// changed, so they can re-resolve their config without an app restart.
    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: .continuumSettingsChanged, object: nil)
    }

    private var bindings: [ObjectIdentifier: SettingsField] = [:]
    /// The default-model picker trigger, kept for the self-check: it must be
    /// the SAME component the tile composer uses, fed by the same catalogue.
    private(set) var modelPickerButtonForQA: ProviderModelButton?

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
        let section = sections[row]
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        if let symbol = section.iconSystemName {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: section.title)
        }
        cell.addSubview(icon)
        cell.imageView = icon

        let text = NSTextField(labelWithString: section.title)
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
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

    /// The chord text currently rendered for a catalog entry's row, or nil if the
    /// row isn't rendered. Reads the live label (reflects post-edit re-render).
    func renderedChordDisplayForQA(entryId: String) -> String? {
        ensureShortcutEntryRendered(entryId)
        return shortcutRowsById[entryId]?.chordLabel.stringValue
    }

    /// Drives the real edit path for an entry: opens capture, then feeds a
    /// captured chord through `finishCapture` (the same closure the live capture
    /// view fires). Requires the Keybindings section to be rendered. Returns the
    /// `KeybindEditor.Result` so the check can assert applied vs. rejected.
    @discardableResult
    func simulateCaptureForQA(entryId: String, keyCode: UInt16, modifiers: FocusKeyModifiers, character: String?) -> KeybindEditor.Result? {
        ensureShortcutEntryRendered(entryId)
        guard let context = shortcutRowsById[entryId] else { return nil }
        beginCapture(in: context)
        return finishCapture(context, keyCode: keyCode, modifiers: modifiers, character: character)
    }

    /// Drives the real reset path for an entry's row.
    func resetForQA(entryId: String) {
        ensureShortcutEntryRendered(entryId)
        guard let context = shortcutRowsById[entryId] else { return }
        if let resolved = KeybindEditor.reset(target: context.target, defaults: defaults) {
            applyResolvedKeymap(resolved)
        }
        renderSelectedSection()
    }

    var navKeymapForQA: NavKeymap { navKeymap }

    /// True when every field in the selected section produced at least one
    /// editable/displayable control of the kind its type demands (toggle →
    /// NSButton, text → NSTextField, choice → NSPopUpButton, info → static
    /// NSTextField, shortcuts → a non-empty guide list).
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
                // The default-model field renders the provider>model picker
                // trigger; every other choice stays a stock popup.
                if firstDescendant(of: row, ofType: NSPopUpButton.self) == nil,
                   firstDescendant(of: row, ofType: ChoiceButton.self) == nil { return false }
            case .info:
                if firstDescendant(of: row, ofType: NSTextField.self, where: { !$0.stringValue.isEmpty && !$0.isEditable }) == nil { return false }
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
        case missingTerminalTmuxFields

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
            case .missingTerminalTmuxFields:
                return "SettingsSchema missing Terminal section with tmux enabled/path fields"
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
        guard let terminalSection = sections.first(where: { $0.id == "terminal" }),
              terminalSection.fields.contains(where: { field in
                  if case .toggle(TmuxPersistenceConfig.enabledKey, "Keep Shells Alive (tmux)", TmuxPersistenceConfig.defaultEnabled) = field { return true }
                  return false
              }),
              terminalSection.fields.contains(where: { field in
                  if case .text(TmuxPersistenceConfig.pathKey, "tmux Path", TmuxPersistenceConfig.defaultPath) = field { return true }
                  return false
              }) else {
            throw SettingsPanelSelfCheckError.missingTerminalTmuxFields
        }

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
        let toggleSectionIndex = sections.firstIndex { section in
            section.fields.contains { if case .toggle = $0 { return true }; return false }
        } ?? 0
        panel.selectSectionForQA(toggleSectionIndex)
        guard let toggle = panel.firstToggleControlForQA(),
              let toggleField = sections[toggleSectionIndex].fields.first(where: { if case .toggle = $0 { return true }; return false }),
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

        // 3b. Consolidation witness: the agents section's default-model field
        // renders the SAME provider>model picker the tile composer uses, its
        // items are the live catalogue (one data source), and a pick writes
        // the exact key the spawn resolver reads.
        if let agentsIndex = sections.firstIndex(where: { $0.id == "agents" }) {
            panel.selectSectionForQA(agentsIndex)
            guard let picker = panel.modelPickerButtonForQA else {
                throw SettingsPanelSelfCheckError.sectionFieldsNotRendered("agents: default-model picker missing")
            }
            guard picker.items.map(\.id) == AgentModelConfig.modelOptions else {
                throw SettingsPanelSelfCheckError.sectionFieldsNotRendered("agents: picker items diverge from the catalogue")
            }
            if let target = AgentModelConfig.modelOptions.last {
                _ = picker.chooseForQA(id: target)
                guard defaults.string(forKey: AgentModelConfig.modelKey) == target else {
                    throw SettingsPanelSelfCheckError.sectionFieldsNotRendered("agents: picker choice did not write \(AgentModelConfig.modelKey)")
                }
            }
        }

        // 3c. Backend filtering (Plan 02 §4.4): the resolved backend narrows the
        // SAME `AgentModelConfig.modelOptions` both the settings picker and the
        // composer read. Fixture a two-provider catalogue and flip the global
        // backend (in `.standard`, which `resolved()` reads); restore both.
        do {
            let priorBackend = UserDefaults.standard.string(forKey: AgentBackendConfig.key)
            AgentModelCatalog.shared.resetForQA(options: ["openai-codex/gpt-x", "anthropic/claude-y"])
            AgentBackendConfig.store(.codex)
            guard AgentModelConfig.modelOptions == ["openai-codex/gpt-x"] else {
                throw SettingsPanelSelfCheckError.sectionFieldsNotRendered("agents: Codex backend must narrow modelOptions to openai-codex/*, got \(AgentModelConfig.modelOptions)")
            }
            AgentBackendConfig.store(.claudeCode)
            guard AgentModelConfig.modelOptions == ["anthropic/claude-y"] else {
                throw SettingsPanelSelfCheckError.sectionFieldsNotRendered("agents: Claude Code backend must narrow modelOptions to anthropic/*, got \(AgentModelConfig.modelOptions)")
            }
            AgentBackendConfig.store(.pi)
            guard AgentModelConfig.modelOptions == ["openai-codex/gpt-x", "anthropic/claude-y"] else {
                throw SettingsPanelSelfCheckError.sectionFieldsNotRendered("agents: pi backend must show every provider, got \(AgentModelConfig.modelOptions)")
            }
            if let priorBackend {
                UserDefaults.standard.set(priorBackend, forKey: AgentBackendConfig.key)
            } else {
                UserDefaults.standard.removeObject(forKey: AgentBackendConfig.key)
            }
            AgentModelCatalog.shared.resetForQA()
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

        // Artifacts: render the reorganized sections so the change is reviewable.
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let artifactDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(timestamp)/settings-panel", isDirectory: true)
        try? FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        for id in ["keybindings", "navigation", "general"] {
            guard let idx = sections.firstIndex(where: { $0.id == id }) else { continue }
            panel.selectSectionForQA(idx)
            if let content = panel.contentViewForQA, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: artifactDir.appendingPathComponent("\(id).png"))
            }
        }

        // 5. Clean teardown — no leaked window.
        let panelWindowNumber = panel.panelWindowNumberForQA
        panel.close()
        if let panelWindowNumber, NSApp.windows.contains(where: { $0.windowNumber == panelWindowNumber && $0.isVisible }) {
            throw SettingsPanelSelfCheckError.leakedPanel
        }
    }

    // MARK: - Self-check (docs/24 S5 — `--keybind-edit-check`)

    enum KeybindEditSelfCheckError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let m): return m }
        }
    }

    /// Drives the real keybind-edit path: capture → persist → re-resolve →
    /// live-apply hook → row re-render. Uses an isolated suite and scrubs/
    /// restores the global-domain `continuum.keymap.*`/`continuum.tileKeymap.*`
    /// keys so a developer machine's overrides cannot leak into the suite's
    /// search list.
    static func runKeybindEditSelfCheck() throws {
        func fail(_ m: String) -> KeybindEditSelfCheckError { .message(m) }

        let suite = "continuum.keybindEdit.selfcheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw fail("could not create isolated UserDefaults suite")
        }

        // Scrub keymap overrides out of the global domain (which the suite
        // inherits) and restore them on exit.
        let globalDomainName = UserDefaults.globalDomain
        let originalGlobalDomain = defaults.persistentDomain(forName: globalDomainName) ?? [:]
        var scrubbed = originalGlobalDomain
        for key in scrubbed.keys where key.hasPrefix("continuum.keymap.") || key.hasPrefix("continuum.tileKeymap.") {
            scrubbed.removeValue(forKey: key)
        }
        defaults.setPersistentDomain(scrubbed, forName: globalDomainName)
        defer {
            defaults.setPersistentDomain(originalGlobalDomain, forName: globalDomainName)
            defaults.removePersistentDomain(forName: suite)
        }

        let sections = SettingsSchema.sections()
        let baseKeymap = NavKeymap.resolve(defaults: defaults, warn: { _ in })
        let panel = SettingsPanel(sections: sections, defaults: defaults, navKeymap: baseKeymap)
        var liveKeymap = baseKeymap
        panel.onKeymapChanged = { liveKeymap = $0 }
        panel.show(near: nil)

        let keybindIndex = sections.firstIndex { $0.id == "keybindings" } ?? 0
        panel.selectSectionForQA(keybindIndex)

        // --- 1. Nav binding rebind: navMode.up "k" -> "i". ---
        let originalUp = baseKeymap.up
        guard panel.renderedChordDisplayForQA(entryId: "navMode.up") == originalUp else {
            throw fail("nav row did not render the default chord (\(originalUp))")
        }
        // keyCode 34 is "i" on US layouts; the bare key carries character "i".
        let navResult = panel.simulateCaptureForQA(entryId: "navMode.up", keyCode: 34, modifiers: [], character: "i")
        guard case .applied? = navResult else {
            throw fail("nav rebind was not applied: \(String(describing: navResult))")
        }
        // UserDefaults reflects the override.
        guard NavKeymap.resolve(defaults: defaults, warn: { _ in }).up == "i" else {
            throw fail("NavKeymap.resolve did not reflect the rebound up='i'")
        }
        // The live-apply hook produced the updated keymap.
        guard liveKeymap.up == "i" else {
            throw fail("live keymap hook did not reflect up='i' (was '\(liveKeymap.up)')")
        }
        // The row re-rendered the new chord display.
        guard panel.renderedChordDisplayForQA(entryId: "navMode.up") == "i" else {
            throw fail("nav row did not re-render the new chord display 'i'")
        }

        // --- 2. Reset restores the default. ---
        panel.resetForQA(entryId: "navMode.up")
        guard NavKeymap.resolve(defaults: defaults, warn: { _ in }).up == originalUp,
              liveKeymap.up == originalUp,
              panel.renderedChordDisplayForQA(entryId: "navMode.up") == originalUp else {
            throw fail("reset did not restore nav up to default '\(originalUp)'")
        }

        // --- 3. Leader rebind is live + reflected, then reset. ---
        let originalLeader = baseKeymap.leader
        // Rebind leader to Ctrl+G (keyCode 5) — a non-inviolable chord.
        let leaderResult = panel.simulateCaptureForQA(entryId: "global.navModeLeader", keyCode: 5, modifiers: [.control], character: "g")
        guard case .applied? = leaderResult else {
            throw fail("leader rebind was not applied: \(String(describing: leaderResult))")
        }
        let rebound = NavKeymap.resolve(defaults: defaults, warn: { _ in }).leader
        guard rebound == KeyChord(keyCode: 5, modifiers: .control), liveKeymap.leader == rebound else {
            throw fail("leader rebind not reflected/live (got \(rebound.displayString))")
        }
        guard panel.renderedChordDisplayForQA(entryId: "global.navModeLeader") == rebound.displayString else {
            throw fail("leader row did not re-render the new chord display")
        }
        panel.resetForQA(entryId: "global.navModeLeader")
        guard NavKeymap.resolve(defaults: defaults, warn: { _ in }).leader == originalLeader, liveKeymap.leader == originalLeader else {
            throw fail("reset did not restore the leader to default")
        }

        // --- 4. Tile action rebind: browser find Cmd-F -> Cmd-Ctrl-F. ---
        let cmdF = TileChord(keyCode: 3, modifiers: .command)
        let cmdCtrlF = TileChord(keyCode: 3, modifiers: [.command, .control])
        guard TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF] == .browserFind else {
            throw fail("browser find did not default to Cmd-F before edit")
        }
        let tileResult = panel.simulateCaptureForQA(entryId: "tile.browser.browserFind", keyCode: 3, modifiers: [.command, .control], character: "f")
        guard case .applied? = tileResult else {
            throw fail("tile rebind was not applied: \(String(describing: tileResult))")
        }
        let browserMap = TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })
        guard browserMap[cmdCtrlF] == .browserFind, browserMap[cmdF] == nil else {
            throw fail("TileActionCatalog did not reflect the browser find rebind to Cmd-Ctrl-F")
        }
        guard panel.renderedChordDisplayForQA(entryId: "tile.browser.browserFind") == cmdCtrlF.displayString else {
            throw fail("tile row did not re-render the new chord display \(cmdCtrlF.displayString)")
        }
        // Reset restores Cmd-F.
        panel.resetForQA(entryId: "tile.browser.browserFind")
        guard TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF] == .browserFind else {
            throw fail("reset did not restore browser find to Cmd-F")
        }

        // --- 5. Inviolable collision (Cmd-K) is rejected; binding unchanged. ---
        let beforeFind = TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF]
        let rejectResult = panel.simulateCaptureForQA(entryId: "tile.browser.browserFind", keyCode: 40, modifiers: [.command], character: "k")
        guard case .rejected(.collidesWithInviolableGlobal(.palette))? = rejectResult else {
            throw fail("Cmd-K bind should be rejected as an inviolable-global collision, got \(String(describing: rejectResult))")
        }
        let afterFind = TileActionCatalog.actions(for: .browser, defaults: defaults, warn: { _ in })[cmdF]
        guard afterFind == beforeFind, afterFind == .browserFind else {
            throw fail("rejected Cmd-K bind changed the browser find binding")
        }

        // Clean teardown.
        let panelWindowNumber = panel.panelWindowNumberForQA
        panel.close()
        if let panelWindowNumber, NSApp.windows.contains(where: { $0.windowNumber == panelWindowNumber && $0.isVisible }) {
            throw fail("settings panel window leaked after close")
        }
    }
}
