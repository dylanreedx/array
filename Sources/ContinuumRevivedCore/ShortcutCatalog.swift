import Foundation

/// The layer a binding lives in, used to group the settings Guide.
public enum ShortcutLayer: Equatable, Sendable {
    case global
    case navMode
    case tile(TileKind)
    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// Bindings that apply only while the agent inbox holds first responder. Its
    /// OWN layer because ⌘1–⌘4 are `spawnProfile` globals: two readings of one
    /// chord are legal exactly when they live in different scopes, and putting
    /// these in `.global` would (rightly) go red in the intra-scope uniqueness
    /// check. See `InboxJump`.
    case inbox
}

/// Routes an edited row to the correct persist/live-apply path. A non-
/// configurable global has no target (`nil`); configurable rows carry the write
/// path their edit must take (docs/24 S5).
public enum KeybindEditTarget: Equatable, Sendable {
    /// A feature-registered application command. This is the migration path for
    /// former hardcoded globals and is also what future features use directly.
    case registered(shortcutID: ShortcutID)
    /// The nav-mode leader chord (a `NavKeymap.leader` rebind).
    case leader
    /// A single-key nav-mode binding, by its `NavKeymap` field name (e.g. "up").
    case navBinding(field: String)
    /// A tile-local action's chord, by kind + action (a `TileActionCatalog` rebind).
    case tileAction(kind: TileKind, action: TileAction)
}

/// One human-readable binding row for the settings Guide: a stable `id`, a
/// concise `label`, the display chord, its `layer`, whether a rebind path
/// exists today (`configurable`), and — for configurable rows — the
/// `editTarget` that routes an edit to the correct write path.
public struct ShortcutCatalogEntry: Equatable, Sendable {
    public let id: String
    public let label: String
    public let chordDisplay: String
    public let layer: ShortcutLayer
    public let configurable: Bool
    public let editTarget: KeybindEditTarget?

    public init(id: String, label: String, chordDisplay: String, layer: ShortcutLayer, configurable: Bool, editTarget: KeybindEditTarget? = nil) {
        self.id = id
        self.label = label
        self.chordDisplay = chordDisplay
        self.layer = layer
        self.configurable = configurable
        self.editTarget = editTarget
    }
}

/// Declarative, read-only catalog enumerating every binding (globals + nav-mode
/// + per-kind tile actions). Single source for the docs/24 settings Guide.
/// `configurable` reflects whether a persistence path exists today: globals are
/// hardcoded in `ReservedShortcut.classify` (false) except the nav leader, whose
/// chord comes from `NavKeymap.leader` and persists via `NavKeymap.persist`
/// (true); nav-mode (NavKeymap) and tile actions (TileActionCatalog) both have
/// write paths (true).
public enum ShortcutCatalog {
    /// `defaults` (when supplied) lets tile rows reflect persisted
    /// `continuum.tileKeymap.*` overrides, so an edited row re-renders its new
    /// chord. With `nil`, tile rows show the in-code default chords (the Guide /
    /// exhaustiveness baseline).
    public static func entries(navKeymap: NavKeymap = .default, defaults: UserDefaults? = nil) -> [ShortcutCatalogEntry] {
        let effectiveDefaults: UserDefaults
        if let defaults {
            effectiveDefaults = defaults
        } else {
            let isolated = UserDefaults(suiteName: "continuum.shortcutCatalog.defaults")!
            isolated.removePersistentDomain(forName: "continuum.shortcutCatalog.defaults")
            effectiveDefaults = isolated
        }
        return globalEntries(navKeymap: navKeymap, defaults: effectiveDefaults)
            + navModeEntries(navKeymap: navKeymap) + inboxEntries()
            + tileEntries(defaults: effectiveDefaults)
    }

    // MARK: Agent inbox — ⌘1–⌘9 row jumps (P3.10).

    /// One entry per jumpable row, so Settings can SHOW the chords instead of the
    /// user having to discover them. `configurable: false` for the same reason the
    /// hardcoded globals are: the chords live in `InboxJump`, and there is no
    /// persistence path for them in this phase.
    static func inboxEntries() -> [ShortcutCatalogEntry] {
        (1...InboxJump.maximumRows).compactMap { number in
            guard let chord = InboxJump.chord(forRowNumber: number) else { return nil }
            return ShortcutCatalogEntry(
                id: "inbox.jumpToRow.\(number)",
                label: "Jump to row \(number)",
                chordDisplay: chord.displayString,
                layer: .inbox,
                configurable: false
            )
        }
    }

    // MARK: Globals — one entry per ReservedShortcut.

    static func globalEntries(navKeymap: NavKeymap, defaults: UserDefaults = .standard) -> [ShortcutCatalogEntry] {
        var entries: [ShortcutCatalogEntry] = [
            ShortcutCatalogEntry(
                id: "global.palette",
                label: "Command Center",
                chordDisplay: registeredChordDisplay(id: "global.commandCenter", fallback: KeyChord(keyCode: 40, modifiers: .command), defaults: defaults),
                layer: .global,
                configurable: true,
                editTarget: .registered(shortcutID: "global.commandCenter")
            ),
            registeredEntry(
                id: "global.focusMode",
                label: "Focus Mode",
                fallback: KeyChord(keyCode: 3, modifiers: .command),
                defaults: defaults
            ),
            registeredEntry(
                id: "global.settings",
                label: "Settings",
                fallback: KeyChord(keyCode: 43, modifiers: .command),
                defaults: defaults
            ),
        ]
        for profile in 1...4 {
            entries.append(registeredEntry(
                id: ShortcutID(rawValue: "global.spawnProfile.\(profile)"),
                label: "Quick Spawn \(profile)",
                fallback: KeyChord(keyCode: UInt16(17 + profile), modifiers: .command),
                defaults: defaults
            ))
        }
        // Leader's chord is editable via NavKeymap; the rest are hardcoded.
        entries.append(ShortcutCatalogEntry(
            id: "global.navModeLeader",
            label: "Nav Mode",
            chordDisplay: navKeymap.leader.displayString,
            layer: .global,
            configurable: true,
            editTarget: .leader
        ))
        entries.append(ShortcutCatalogEntry(
            id: "global.openKeybindings",
            label: "All Shortcuts",
            chordDisplay: registeredChordDisplay(id: "global.openKeybindings", fallback: KeyChord(keyCode: 44, modifiers: [.command, .shift]), defaults: defaults),
            layer: .global,
            configurable: true,
            editTarget: .registered(shortcutID: "global.openKeybindings")
        ))
        entries.append(registeredEntry(
            id: "global.toggleWorkspaceSidebar",
            label: "Show Activity Dock",
            fallback: KeyChord(keyCode: 1, modifiers: [.command, .shift]),
            defaults: defaults
        ))
        return entries
    }

    private static func registeredChordDisplay(id: ShortcutID, fallback: KeyChord, defaults: UserDefaults) -> String {
        guard let registry = try? CommandRegistry.productRegistry(),
              let definition = registry.shortcuts.first(where: { $0.id == id }) else {
            return fallback.displayString
        }
        let gestures = ShortcutBindingStore(defaults: defaults).gestures(for: definition)
        return gestures.isEmpty ? "Unassigned" : gestures.map(\.displayString).joined(separator: " / ")
    }

    private static func registeredEntry(
        id: ShortcutID,
        label: String,
        fallback: KeyChord,
        defaults: UserDefaults
    ) -> ShortcutCatalogEntry {
        ShortcutCatalogEntry(
            id: id.rawValue,
            label: label,
            chordDisplay: registeredChordDisplay(id: id, fallback: fallback, defaults: defaults),
            layer: .global,
            configurable: true,
            editTarget: .registered(shortcutID: id)
        )
    }

    private static func entry(_ shortcut: ReservedShortcut) -> ShortcutCatalogEntry {
        ShortcutCatalogEntry(
            id: globalId(for: shortcut),
            label: globalLabel(for: shortcut),
            chordDisplay: globalChord(for: shortcut).displayString,
            layer: .global,
            configurable: false
        )
    }

    private static func globalId(for shortcut: ReservedShortcut) -> String {
        switch shortcut {
        case .palette: return "global.palette"
        case .focusMode: return "global.focusMode"
        case .settings: return "global.settings"
        case .spawnProfile(let n): return "global.spawnProfile.\(n)"
        case .navModeLeader: return "global.navModeLeader"
        }
    }

    private static func globalLabel(for shortcut: ReservedShortcut) -> String {
        switch shortcut {
        case .palette: return "Launch palette"
        case .focusMode: return "Focus mode"
        case .settings: return "Settings"
        case .spawnProfile(let n): return "Spawn profile \(n)"
        case .navModeLeader: return "Nav Mode"
        }
    }

    /// The hardcoded global chord, mirroring `ReservedShortcut.classify`.
    private static func globalChord(for shortcut: ReservedShortcut) -> KeyChord {
        switch shortcut {
        case .palette: return KeyChord(keyCode: 40, modifiers: .command)
        case .focusMode: return KeyChord(keyCode: 3, modifiers: .command)
        case .settings: return KeyChord(keyCode: 43, modifiers: .command)
        case .spawnProfile(let n): return KeyChord(keyCode: UInt16(17 + n), modifiers: .command)
        case .navModeLeader: return NavKeymap.default.leader
        }
    }

    // MARK: Nav-mode — one entry per NavKeymap binding field.

    static func navModeEntries(navKeymap: NavKeymap) -> [ShortcutCatalogEntry] {
        let fields: [(field: String, label: String, chord: String)] = [
            ("up", "Move up", navKeymap.up),
            ("down", "Move down", navKeymap.down),
            ("left", "Move left", navKeymap.left),
            ("right", "Move right", navKeymap.right),
            ("nextZone", "Next zone", navKeymap.nextZone),
            ("previousZone", "Previous zone", navKeymap.previousZone),
            ("zonePicker", "Zone picker", navKeymap.zonePicker),
            ("workspacePicker", "Workspace picker", navKeymap.workspacePicker),
            ("agentCycle", "Cycle agents", navKeymap.agentCycle),
            ("agentNeedsAttention", "Agent needs attention", navKeymap.agentNeedsAttention),
            ("focusMode", "Focus mode", navKeymap.focusMode),
            ("deleteTile", "Delete tile", navKeymap.deleteTile),
        ]
        return fields.map { field in
            ShortcutCatalogEntry(
                id: "navMode.\(field.field)",
                label: field.label,
                chordDisplay: field.chord,
                layer: .navMode,
                configurable: true,
                editTarget: .navBinding(field: field.field)
            )
        }
    }

    // MARK: Tile actions — one entry per TileActionCatalog default per kind.

    static func tileEntries(defaults: UserDefaults? = nil) -> [ShortcutCatalogEntry] {
        // With no caller-supplied store, read from an empty, isolated domain so
        // the catalog reflects the in-code default chords, not any user
        // override. When a store is supplied (the live editor), reflect its
        // persisted overrides so an edited row re-renders its new chord.
        let store: UserDefaults
        if let defaults {
            store = defaults
        } else {
            let emptyDefaults = UserDefaults(suiteName: "continuum.shortcutCatalog.defaults")!
            emptyDefaults.removePersistentDomain(forName: "continuum.shortcutCatalog.defaults")
            store = emptyDefaults
        }
        var entries: [ShortcutCatalogEntry] = []
        for kind in TileKind.allCases {
            for (chord, action) in TileActionCatalog.actions(for: kind, defaults: store, warn: { _ in }) {
                entries.append(ShortcutCatalogEntry(
                    id: "tile.\(kind.rawValue).\(actionId(action))",
                    label: actionLabel(action),
                    chordDisplay: chord.displayString,
                    layer: .tile(kind),
                    configurable: true,
                    editTarget: .tileAction(kind: kind, action: action)
                ))
            }
        }
        return entries
    }

    private static func actionId(_ action: TileAction) -> String {
        switch action {
        case .resizeToPreset(let preset): return "resize.\(preset.rawValue)"
        case .browserFind: return "browserFind"
        case .browserFocusURL: return "browserFocusURL"
        case .browserReload: return "browserReload"
        case .browserBack: return "browserBack"
        case .browserForward: return "browserForward"
        case .noteExport: return "noteExport"
        }
    }

    private static func actionLabel(_ action: TileAction) -> String {
        switch action {
        case .resizeToPreset(let preset):
            switch preset {
            case .compact: return "Resize: compact"
            case .default: return "Resize: default"
            case .large: return "Resize: large"
            case .fillViewport: return "Resize: fill viewport"
            }
        case .browserFind: return "Find in page"
        case .browserFocusURL: return "Focus URL"
        case .browserReload: return "Reload"
        case .browserBack: return "Back"
        case .browserForward: return "Forward"
        case .noteExport: return "Export note"
        }
    }
}
