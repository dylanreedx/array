import Foundation

/// The layer a binding lives in, used to group the settings Guide.
public enum ShortcutLayer: Equatable, Sendable {
    case global
    case navMode
    case tile(TileKind)
}

/// One human-readable binding row for the settings Guide: a stable `id`, a
/// concise `label`, the display chord, its `layer`, and whether a rebind path
/// exists today (`configurable`).
public struct ShortcutCatalogEntry: Equatable, Sendable {
    public let id: String
    public let label: String
    public let chordDisplay: String
    public let layer: ShortcutLayer
    public let configurable: Bool

    public init(id: String, label: String, chordDisplay: String, layer: ShortcutLayer, configurable: Bool) {
        self.id = id
        self.label = label
        self.chordDisplay = chordDisplay
        self.layer = layer
        self.configurable = configurable
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
    public static func entries(navKeymap: NavKeymap = .default) -> [ShortcutCatalogEntry] {
        globalEntries(navKeymap: navKeymap) + navModeEntries(navKeymap: navKeymap) + tileEntries()
    }

    // MARK: Globals — one entry per ReservedShortcut.

    static func globalEntries(navKeymap: NavKeymap) -> [ShortcutCatalogEntry] {
        var entries: [ShortcutCatalogEntry] = [
            entry(.palette),
            entry(.focusMode),
            entry(.settings),
        ]
        for profile in 1...4 {
            entries.append(entry(.spawnProfile(profile)))
        }
        // Leader's chord is editable via NavKeymap; the rest are hardcoded.
        entries.append(ShortcutCatalogEntry(
            id: "global.navModeLeader",
            label: "Nav Mode",
            chordDisplay: navKeymap.leader.displayString,
            layer: .global,
            configurable: true
        ))
        return entries
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
        let fields: [(id: String, label: String, chord: String)] = [
            ("navMode.up", "Move up", navKeymap.up),
            ("navMode.down", "Move down", navKeymap.down),
            ("navMode.left", "Move left", navKeymap.left),
            ("navMode.right", "Move right", navKeymap.right),
            ("navMode.nextZone", "Next zone", navKeymap.nextZone),
            ("navMode.previousZone", "Previous zone", navKeymap.previousZone),
            ("navMode.zonePicker", "Zone picker", navKeymap.zonePicker),
            ("navMode.workspacePicker", "Workspace picker", navKeymap.workspacePicker),
            ("navMode.agentCycle", "Cycle agents", navKeymap.agentCycle),
            ("navMode.agentNeedsAttention", "Agent needs attention", navKeymap.agentNeedsAttention),
            ("navMode.focusMode", "Focus mode", navKeymap.focusMode),
            ("navMode.deleteTile", "Delete tile", navKeymap.deleteTile),
        ]
        return fields.map { field in
            ShortcutCatalogEntry(id: field.id, label: field.label, chordDisplay: field.chord, layer: .navMode, configurable: true)
        }
    }

    // MARK: Tile actions — one entry per TileActionCatalog default per kind.

    static func tileEntries() -> [ShortcutCatalogEntry] {
        // Read from an empty, isolated domain so the catalog reflects the
        // in-code default chords, not any user override.
        let emptyDefaults = UserDefaults(suiteName: "continuum.shortcutCatalog.defaults")!
        emptyDefaults.removePersistentDomain(forName: "continuum.shortcutCatalog.defaults")
        var entries: [ShortcutCatalogEntry] = []
        for kind in TileKind.allCases {
            for (chord, action) in TileActionCatalog.actions(for: kind, defaults: emptyDefaults, warn: { _ in }) {
                entries.append(ShortcutCatalogEntry(
                    id: "tile.\(kind.rawValue).\(actionId(action))",
                    label: actionLabel(action),
                    chordDisplay: chord.displayString,
                    layer: .tile(kind),
                    configurable: true
                ))
            }
        }
        return entries
    }

    private static func actionId(_ action: TileAction) -> String {
        switch action {
        case .resizeToPreset(let preset): return "resize.\(preset.rawValue)"
        case .nudge(let dir): return "nudge.\(dir.rawValue)"
        case .throwToNeighbor(let dir): return "throw.\(dir.rawValue)"
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
        case .nudge(let dir): return "Nudge \(dir.rawValue)"
        case .throwToNeighbor(let dir): return "Throw \(dir.rawValue)"
        case .browserFind: return "Find in page"
        case .browserFocusURL: return "Focus URL"
        case .browserReload: return "Reload"
        case .browserBack: return "Back"
        case .browserForward: return "Forward"
        case .noteExport: return "Export note"
        }
    }
}
