import AppKit

/// Presents an existing command tree using Array's shared choice surface.
/// NSMenu is retained only as the command model: selection sends the original
/// item to its original target, including closure-backed menu items.
@MainActor
final class ChoiceMenuController {
    private struct Level {
        let menu: NSMenu
        let prefix: String
        let popover: ChoicePopoverController
        let sourceItems: [String: NSMenuItem]
        let parentID: String?
    }

    private var levels: [Level] = []
    private var group: ChoicePopoverGroup?
    private var hoverTask: Task<Void, Never>?
    private weak var sourceWindow: NSWindow?
    private weak var returnResponder: NSResponder?
    private var closeHandler: (() -> Void)?
    private var isClosing = false
    nonisolated(unsafe) private var keyMonitor: Any?

    var isPresented: Bool { levels.first?.popover.isPresented == true }
    var qaPopovers: [ChoicePopoverController] { levels.map(\.popover) }
    var qaMenus: [NSMenu] { levels.map(\.menu) }

    deinit {
        MainActor.assumeIsolated { dismiss() }
    }

    func present(
        menu: NSMenu,
        relativeTo anchor: NSView,
        anchorRect: NSRect? = nil,
        onClose: (() -> Void)? = nil
    ) {
        dismiss()
        sourceWindow = anchor.window
        returnResponder = anchor.window?.firstResponder
        closeHandler = onClose
        let group = ChoicePopoverGroup()
        group.onDismiss = { [weak self] in self?.dismiss() }
        self.group = group
        show(menu: menu, prefix: "menu", parentID: nil,
             anchor: anchor, rect: anchorRect ?? anchor.bounds)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.group?.contains(window: event.window) == true,
                  let menu = self.levels.first?.menu,
                  let item = Self.command(in: menu, matching: event) else { return event }
            self.dispatch(item)
            return nil
        }
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        hoverTask?.cancel()
        hoverTask = nil
        let closing = levels
        levels.removeAll()
        for level in closing.reversed() { level.popover.dismiss() }
        group?.onDismiss = nil
        group = nil
        let onClose = closeHandler
        closeHandler = nil
        if let window = sourceWindow, let responder = returnResponder {
            window.makeFirstResponder(responder)
        }
        sourceWindow = nil
        returnResponder = nil
        isClosing = false
        onClose?()
    }

    private func show(menu: NSMenu, prefix: String, parentID: String?, anchor: NSView, rect: NSRect) {
        // Honor menus populated lazily by their owner, without asking AppKit to
        // auto-enable items whose disabled state was explicitly calculated.
        menu.delegate?.menuNeedsUpdate?(menu)
        var sourceItems: [String: NSMenuItem] = [:]
        var items: [ChoiceItem] = []
        var separatorBefore = false
        for (index, source) in menu.items.enumerated() where !source.isHidden {
            if source.isSeparatorItem {
                separatorBefore = !items.isEmpty
                continue
            }
            let id = "\(prefix).\(index)"
            let hasSubmenu = source.submenu != nil
            var item = ChoiceItem(
                id: id, title: source.title, enabled: source.isEnabled,
                toolTip: source.toolTip)
            item.separatorBefore = separatorBefore
            item.hasSubmenu = hasSubmenu
            // The cascade owner dismisses all levels before dispatching a leaf.
            item.keepsOpen = true
            item.check = source.state == .mixed ? .mixed : source.state == .on ? .on : nil
            item.trailing = Self.shortcut(for: source)
            items.append(item)
            sourceItems[id] = source
            separatorBefore = false
        }
        guard !items.isEmpty else { return }

        let popover = ChoicePopoverController()
        popover.cascadeGroup = group
        popover.dismissesOnAnchorClick = parentID == nil
        let depth = levels.count
        levels.append(Level(menu: menu, prefix: prefix, popover: popover,
                            sourceItems: sourceItems, parentID: parentID))
        // Commands can contain a large sound library or project registry. Use
        // the same scroll container as other shared command panels; row anatomy
        // and density are supplied by the shared .menu presentation.
        popover.present(
            items: items, selectedID: nil, presentation: .menu,
            layout: .commands(CommandPopoverLayout(
                maximumVisibleRows: 18, minimumWidth: 220, maximumWidth: 440)),
            anchor: rect, relativeTo: anchor, submenu: parentID != nil,
            accessibilityLabel: menu.title.isEmpty ? "Agent actions" : menu.title,
            onSelection: { [weak self] item in self?.choose(id: item.id, depth: depth) },
            onDismiss: { [weak self] in self?.dismiss() },
            onClose: { [weak self, weak popover] in
                guard let self, !self.isClosing, let popover,
                      self.levels.contains(where: { $0.popover === popover }) else { return }
                self.dismiss()
            },
            onFocusChange: { [weak self] id in self?.scheduleHover(id: id, depth: depth) })
        popover.listView?.onOpenSubmenu = { [weak self] item in
            self?.openSubmenu(id: item.id, depth: depth)
        }
        popover.listView?.onCloseSubmenu = { [weak self] in self?.ascend(from: depth) }
    }

    private func choose(id: String, depth: Int) {
        guard levels.indices.contains(depth), let source = levels[depth].sourceItems[id],
              source.isEnabled, !source.isHidden else { return }
        if source.submenu != nil {
            openSubmenu(id: id, depth: depth)
            return
        }
        dispatch(source)
    }

    private func dispatch(_ source: NSMenuItem) {
        guard source.isEnabled, !source.isHidden, let action = source.action else { return }
        // Keep both the item and its tree alive through dismissal. Some items
        // target themselves and carry their callback as their only owned state.
        let commandTree = levels.map(\.menu)
        let target = source.target
        dismiss()
        withExtendedLifetime(commandTree) {
            _ = NSApp.sendAction(action, to: target, from: source)
        }
    }

    private static func command(in menu: NSMenu, matching event: NSEvent) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let modifiers = event.modifierFlags.intersection(relevant)
        // Unmodified text remains typeahead, and arrow/Return/Escape navigation
        // remains entirely in ChoiceListView's keyboard path.
        guard !modifiers.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers else { return nil }
        for item in menu.items where !item.isHidden && item.isEnabled {
            if let submenu = item.submenu,
               let match = command(in: submenu, matching: event) { return match }
            guard item.action != nil, !item.keyEquivalent.isEmpty else { continue }
            var actualModifiers = modifiers
            let expected = item.keyEquivalentModifierMask.intersection(relevant)
            let key = item.keyEquivalent
            // A plus key already carries its Shift in the produced character;
            // NSMenu's Command-plus convention does not redundantly store Shift.
            if !expected.contains(.shift), key == "+", characters == "+" {
                actualModifiers.remove(.shift)
            }
            let matchesKey = characters.lowercased() == key.lowercased()
                || (key == "+" && characters == "=")
            if matchesKey && actualModifiers == expected { return item }
        }
        return nil
    }

    private func scheduleHover(id: String?, depth: Int) {
        hoverTask?.cancel()
        guard let id, levels.indices.contains(depth) else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.levels.indices.contains(depth) else { return }
            // Crossing another parent row on the diagonal into an already-open
            // submenu must not tear that submenu away under the pointer.
            if self.levels.dropFirst(depth + 1).contains(where: {
                $0.popover.surfaceFrame?.contains(NSEvent.mouseLocation) == true
            }) { return }
            if self.levels[depth].sourceItems[id]?.submenu != nil {
                self.openSubmenu(id: id, depth: depth)
            } else {
                self.closeLevels(after: depth)
            }
        }
    }

    private func openSubmenu(id: String, depth: Int) {
        hoverTask?.cancel()
        guard levels.indices.contains(depth), let source = levels[depth].sourceItems[id],
              source.isEnabled, let submenu = source.submenu,
              let row = levels[depth].popover.listView?.rowView(id: id) else { return }
        if levels.indices.contains(depth + 1), levels[depth + 1].parentID == id {
            levels[depth + 1].popover.focus()
            return
        }
        closeLevels(after: depth)
        show(menu: submenu, prefix: id, parentID: id, anchor: row, rect: row.bounds)
    }

    private func ascend(from depth: Int) {
        guard depth > 0, levels.indices.contains(depth) else { return }
        hoverTask?.cancel()
        let parentID = levels[depth].parentID
        closeLevels(after: depth - 1)
        if let parentID { levels[depth - 1].popover.listView?.focus(id: parentID) }
        levels[depth - 1].popover.focus()
    }

    private func closeLevels(after depth: Int) {
        guard levels.count > depth + 1 else { return }
        let closing = Array(levels[(depth + 1)...])
        levels.removeSubrange((depth + 1)...)
        for level in closing.reversed() { level.popover.dismiss() }
    }

    private static func shortcut(for item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let modifiers = item.keyEquivalentModifierMask
        return (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
            + item.keyEquivalent.uppercased()
    }
}
