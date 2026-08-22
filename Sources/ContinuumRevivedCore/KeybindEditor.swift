import Foundation

/// Pure routing/validation/persist for a keybind edit captured in the settings
/// surface (docs/24 S5). Given the row's `KeybindEditTarget` and a captured
/// chord (plus, for nav bindings, the typed character), it rejects chords that
/// collide with an inviolable global — so the user can never trap themselves —
/// then writes through the correct path (`NavKeymap.persist` for leader/nav,
/// `TileActionCatalog.persist` for tile actions). Leader/nav edits return the
/// re-resolved `NavKeymap` so the app can live-apply without relaunch.
public enum KeybindEditor {
    public enum RejectionReason: Equatable, Sendable {
        /// The chord is an inviolable global (⌘K / leader / ⌘,) — binding it
        /// would trap the user, so the edit is refused.
        case collidesWithInviolableGlobal(ReservedShortcut)
        /// A nav binding needs a single typed character (letters/digits); a
        /// modifier chord or multi-char input is not a valid nav key.
        case invalidNavKey
        case registeredBinding(String)
    }

    public enum Result: Equatable, Sendable {
        /// Edit persisted. `navKeymap` is the re-resolved map for leader/nav
        /// edits (live-apply it); `nil` for tile-action edits (read fresh per
        /// dispatch, so persisting alone suffices).
        case applied(navKeymap: NavKeymap?)
        case rejected(RejectionReason)
    }

    /// Applies a captured chord to `target`, persisting to `defaults`.
    /// `character` is the event's `charactersIgnoringModifiers` (used only for
    /// `.navBinding`). `currentNavKeymap` is the live map, used both for
    /// collision classification and as the base for leader/nav rebinds.
    public static func apply(
        target: KeybindEditTarget,
        keyCode: UInt16,
        modifiers: FocusKeyModifiers,
        character: String?,
        currentNavKeymap: NavKeymap,
        defaults: UserDefaults = .standard
    ) -> Result {
        // Collision guard: reject any chord that classifies as an inviolable
        // global under the current keymap, EXCEPT the leader rebinding to its
        // own current chord (a harmless no-op).
        if let shortcut = ReservedShortcut.classify(keyCode: keyCode, modifiers: modifiers, keymap: currentNavKeymap),
           FocusDispatch.isInviolable(shortcut) {
            let isLeaderNoOp = (target == .leader && shortcut == .navModeLeader)
            let registeredOwnsGesture: Bool = {
                guard case let .registered(shortcutID) = target,
                      let registry = try? CommandRegistry.productRegistry(),
                      let definition = registry.shortcuts.first(where: { $0.id == shortcutID }) else { return false }
                return ShortcutBindingStore(defaults: defaults).matches(
                    keyCode: keyCode, modifiers: modifiers, definition: definition)
            }()
            let paletteHasMoved: Bool = {
                guard shortcut == .palette,
                      let registry = try? CommandRegistry.productRegistry(),
                      let commandCenter = registry.shortcuts.first(where: { $0.id == "global.commandCenter" }) else { return false }
                return !ShortcutBindingStore(defaults: defaults).matches(
                    keyCode: keyCode, modifiers: modifiers, definition: commandCenter)
            }()
            if !isLeaderNoOp && !registeredOwnsGesture && !paletteHasMoved {
                return .rejected(.collidesWithInviolableGlobal(shortcut))
            }
        }

        switch target {
        case .registered(let shortcutID):
            guard let registry = try? CommandRegistry.productRegistry(),
                  let definition = registry.shortcuts.first(where: { $0.id == shortcutID }) else {
                return .rejected(.registeredBinding("The registered shortcut is unavailable."))
            }
            do {
                try ShortcutBindingStore(defaults: defaults).set(
                    [ShortcutGesture(keyCode: keyCode, modifiers: modifiers)],
                    for: definition,
                    registry: registry
                )
                return .applied(navKeymap: nil)
            } catch {
                return .rejected(.registeredBinding(error.localizedDescription))
            }

        case .leader:
            var map = currentNavKeymap
            map.leader = KeyChord(keyCode: keyCode, modifiers: modifiers)
            map.persist(to: defaults)
            return .applied(navKeymap: NavKeymap.resolve(defaults: defaults, warn: { _ in }))

        case .navBinding(let field):
            guard let character, isValidNavKey(character) else {
                return .rejected(.invalidNavKey)
            }
            var map = currentNavKeymap
            guard map.setNavBinding(field: field, to: character) else {
                return .rejected(.invalidNavKey)
            }
            map.persist(to: defaults)
            return .applied(navKeymap: NavKeymap.resolve(defaults: defaults, warn: { _ in }))

        case .tileAction(let kind, let action):
            let chord = TileChord(keyCode: keyCode, modifiers: modifiers)
            TileActionCatalog.persist([chord: action], for: kind, to: defaults)
            return .applied(navKeymap: nil)
        }
    }

    /// Clears the override key(s) for `target`, restoring the in-code default.
    /// Returns the re-resolved `NavKeymap` for leader/nav targets, `nil` for
    /// tile actions.
    public static func reset(
        target: KeybindEditTarget,
        defaults: UserDefaults = .standard
    ) -> NavKeymap? {
        switch target {
        case .registered(let shortcutID):
            guard let registry = try? CommandRegistry.productRegistry(),
                  let definition = registry.shortcuts.first(where: { $0.id == shortcutID }) else { return nil }
            ShortcutBindingStore(defaults: defaults).reset(definition)
            return nil
        case .leader:
            defaults.removeObject(forKey: "continuum.keymap.leader")
            return NavKeymap.resolve(defaults: defaults, warn: { _ in })
        case .navBinding(let field):
            defaults.removeObject(forKey: "continuum.keymap.\(field)")
            return NavKeymap.resolve(defaults: defaults, warn: { _ in })
        case .tileAction(let kind, let action):
            if let name = TileActionCatalog.overrideName(for: action, kind: kind) {
                defaults.removeObject(forKey: "continuum.tileKeymap.\(name)")
            }
            return nil
        }
    }

    /// A nav-mode key must be a single character that `NavKeymap.resolve`
    /// accepts (it validates `count == 1`).
    private static func isValidNavKey(_ character: String) -> Bool {
        character.count == 1
    }
}

extension NavKeymap {
    /// Sets a single-key binding by its catalog field name. Returns false for an
    /// unknown field (leader is a chord, set directly, not via this path).
    mutating func setNavBinding(field: String, to value: String) -> Bool {
        switch field {
        case "up": up = value
        case "down": down = value
        case "left": left = value
        case "right": right = value
        case "nextZone": nextZone = value
        case "previousZone": previousZone = value
        case "zonePicker": zonePicker = value
        case "workspacePicker": workspacePicker = value
        case "agentCycle": agentCycle = value
        case "agentNeedsAttention": agentNeedsAttention = value
        case "focusMode": focusMode = value
        case "deleteTile": deleteTile = value
        default: return false
        }
        return true
    }
}
