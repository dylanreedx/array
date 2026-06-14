import Foundation

/// Outcome of resolving a chord against the current focus scope.
public enum FocusDispatchResolution: Equatable, Sendable {
    case global(ReservedShortcut)
    case tileAction(TileAction)
    case passThrough
}

/// Pure decision function mapping a chord + scope to a resolution. The order
/// guarantees the user can never trap themselves: inviolable globals always
/// win, then a focused tile's claim, then remaining globals, then pass-through.
public enum FocusDispatch {
    /// Globals that always resolve to `.global` regardless of scope, so a tile's
    /// chord claim can never shadow them (docs/27 D3).
    public static func isInviolable(_ shortcut: ReservedShortcut) -> Bool {
        switch shortcut {
        case .palette, .navModeLeader, .settings:
            return true
        case .spawnProfile, .focusMode:
            return false
        }
    }

    public static func resolve(
        keyCode: UInt16,
        modifiers: FocusKeyModifiers,
        scope: FocusSurfaceID,
        focusedKind: TileKind?,
        navKeymap: NavKeymap = .default,
        defaults: UserDefaults = .standard
    ) -> FocusDispatchResolution {
        let shortcut = ReservedShortcut.classify(keyCode: keyCode, modifiers: modifiers, keymap: navKeymap)

        // 1. Inviolable globals always win.
        if let shortcut, isInviolable(shortcut) {
            return .global(shortcut)
        }

        // 2. A focused tile's catalog claim beats remaining globals.
        if case .tile = scope, let kind = focusedKind {
            let chord = TileChord(keyCode: keyCode, modifiers: modifiers)
            if let action = TileActionCatalog.actions(for: kind, defaults: defaults)[chord] {
                return .tileAction(action)
            }
        }

        // 3. Any remaining global.
        if let shortcut {
            return .global(shortcut)
        }

        // 4. Otherwise pass to the responder chain / typing.
        return .passThrough
    }
}
