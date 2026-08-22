import Foundation

/// One canvas command — the single declared source for what the `⌘K` palette
/// offers and (as the registry grows in later phases) what the leader HUD and
/// Settings bind. A command is identified by a stable `id`; its `action` carries
/// both dispatch and display (the action's `displayName` + search tokens), and
/// `paletteVisible` controls whether it appears in `⌘K`.
///
/// Dynamic rows (terminal profiles, projects, workspaces, harness roles, and —
/// later — jump-to-tile targets) are generated per context and appended by the
/// palette, not listed in the registry.
public struct CanvasCommand: Equatable, Sendable {
    public let id: String
    public let action: LaunchPaletteAction
    public let paletteVisible: Bool

    public init(id: String, action: LaunchPaletteAction, paletteVisible: Bool = true) {
        self.id = id
        self.action = action
        self.paletteVisible = paletteVisible
    }
}

/// Registry of the static canvas commands. The launch palette builds its static
/// action rows from here (in declared order) instead of a hardcoded list, so the
/// palette, and later the keybind/settings surfaces, can't drift from one source.
public enum CommandRegistry {
    /// Built-in command metadata is registered once here. The legacy
    /// `CanvasCommand` adapter below keeps current dispatch source-compatible
    /// while Command Center, menus, shortcuts, Settings and Help migrate onto
    /// the same stable identities.
    public static func definitions() -> [CommandDefinition] {
        [
            definition("agent.newManaged", .newManagedAgent, aliases: ["create agent", "assistant"]),
            // A tile-less agent (P2A.6). `agent.newManaged` is spawn + attach a
            // tile; this one is the spawn alone, so an agent can exist and run
            // without any canvas layout.
            definition("agent.newHeadless", .newHeadlessAgent, aliases: ["headless", "tileless"]),
            // N selected queue rows, N isolated agents (P2D.6). The multi-row
            // sibling of the ticket tile's own one-row dispatch.
            definition("agent.fanOut", .fanOutQueueSelection, aliases: ["batch agents", "tickets"]),
            definition("tile.newNote", .newNote, aliases: ["note"]),
            definition("tile.newBrowser", .newBrowser, aliases: ["web"]),
            definition("tile.openFile", .openFile, aliases: ["document"]),
            definition("tile.openFileTree", .openFileTree, aliases: ["directory", "folder"]),
            definition("tile.newDiffReview", .newDiffReview, aliases: ["git diff", "review"]),
            definition("view.fitCanvasToAll", .fitCanvasToAll, aliases: ["zoom all"]),
            definition("view.tidyCanvas", .tidyCanvas, aliases: ["auto layout", "arrange"]),
            // The searchable path to hold-⌥ Return: reveal the already-current
            // tile for work. Same AppDelegate helper, never a second behavior.
            definition("view.focusCurrentTile", .focusCurrentTile, aliases: ["reveal"]),
            definition("view.previousView", .previousView, aliases: ["back"]),
            definition("view.previousTile", .previousTile, aliases: ["back tile"]),
            definition("view.previousZone", .previousZone, aliases: ["back zone"]),
            CommandDefinition(
                id: "view.toggleWorkspaceSidebar",
                title: LaunchPaletteAction.toggleWorkspaceSidebar.displayName,
                aliases: ["activity dock", "sidebar"],
                paletteAction: .toggleWorkspaceSidebar,
                shortcuts: [globalShortcut("global.toggleWorkspaceSidebar", command: "view.toggleWorkspaceSidebar", keyCode: 1, modifiers: [.command, .shift])]
            ),
            definition("help.replayGettingStarted", .replayGettingStarted, aliases: ["onboarding", "learn Array"]),
            definition("workspace.new", .newWorkspace, aliases: ["canvas"]),
            CommandDefinition(
                id: "app.commandCenter",
                title: "Command Center",
                subtitle: "Add tiles, jump, and run any Array command",
                aliases: ["command k", "palette", "add or jump"],
                paletteAction: nil,
                paletteVisible: false,
                menuPlacement: .application,
                shortcuts: [
                    ShortcutDefinition(
                        id: "global.commandCenter",
                        commandID: "app.commandCenter",
                        contexts: [.global],
                        defaultGestures: [ShortcutGesture(keyCode: 40, modifiers: .command)],
                        conflictDomain: .global,
                        presentationPriority: .canvasRail
                    )
                ],
                helpKeywords: ["commands", "search", "keyboard"]
            ),
            CommandDefinition(
                id: "app.openKeybindings",
                title: "All Shortcuts…",
                subtitle: "Open Settings to Keybindings",
                aliases: ["keybindings", "keyboard shortcuts", "hotkeys"],
                paletteAction: nil,
                paletteVisible: false,
                menuPlacement: .help,
                shortcuts: [
                    ShortcutDefinition(
                        id: "global.openKeybindings",
                        commandID: "app.openKeybindings",
                        contexts: [.global],
                        defaultGestures: [ShortcutGesture(keyCode: 44, modifiers: [.command, .shift])],
                        conflictDomain: .global,
                        presentationPriority: .settings
                    )
                ],
                helpKeywords: ["shortcut", "binding", "keyboard"]
            ),
            CommandDefinition(
                id: "app.focusMode",
                title: "Focus Mode",
                aliases: ["focus tile", "zen"],
                paletteVisible: false,
                shortcuts: [globalShortcut("global.focusMode", command: "app.focusMode", keyCode: 3, modifiers: .command)]
            ),
            CommandDefinition(
                id: "app.settings",
                title: "Settings",
                aliases: ["preferences", "configuration"],
                paletteVisible: false,
                menuPlacement: .application,
                shortcuts: [globalShortcut("global.settings", command: "app.settings", keyCode: 43, modifiers: .command)]
            ),
            quickSpawnDefinition(number: 1, title: "New Claude Shell", profile: "Claude"),
            quickSpawnDefinition(number: 2, title: "New Shell", profile: "Shell"),
            quickSpawnDefinition(number: 3, title: "New Browser", profile: "Browser"),
            quickSpawnDefinition(number: 4, title: "New Neovim Shell", profile: "Neovim"),
        ]
    }

    public static func all() -> [CanvasCommand] {
        definitions().compactMap { definition in
            guard let action = definition.paletteAction else { return nil }
            return CanvasCommand(id: definition.id.rawValue, action: action, paletteVisible: definition.paletteVisible)
        }
    }

    /// Palette-visible commands' actions, in declared order — the static action
    /// rows the launch palette shows before its dynamic rows.
    public static func paletteActions() -> [LaunchPaletteAction] {
        all().filter(\.paletteVisible).map(\.action)
    }

    public static func productRegistry(settings: [AnySettingDefinition] = SettingsSchema.registeredDefinitions()) throws -> ProductRegistry {
        try ProductRegistry(features: [
            FeatureRegistration(id: "array.builtIn", commands: definitions(), settings: settings)
        ])
    }

    private static func definition(
        _ id: CommandID,
        _ action: LaunchPaletteAction,
        aliases: [String] = []
    ) -> CommandDefinition {
        CommandDefinition(
            id: id,
            title: action.displayName,
            aliases: aliases,
            paletteAction: action
        )
    }

    private static func globalShortcut(
        _ id: ShortcutID,
        command: CommandID,
        keyCode: UInt16,
        modifiers: FocusKeyModifiers,
        priority: ShortcutPresentationPriority = .settings
    ) -> ShortcutDefinition {
        ShortcutDefinition(
            id: id,
            commandID: command,
            contexts: [.global],
            defaultGestures: [ShortcutGesture(keyCode: keyCode, modifiers: modifiers)],
            conflictDomain: .global,
            presentationPriority: priority
        )
    }

    private static func quickSpawnDefinition(number: Int, title: String, profile: String) -> CommandDefinition {
        let commandID = CommandID(rawValue: "tile.quickSpawn.\(number)")
        return CommandDefinition(
            id: commandID,
            title: title,
            subtitle: "Create the configured \(profile) tile",
            aliases: ["quick spawn \(number)", profile.lowercased()],
            paletteVisible: false,
            shortcuts: [globalShortcut(
                ShortcutID(rawValue: "global.spawnProfile.\(number)"),
                command: commandID,
                keyCode: UInt16(17 + number),
                modifiers: .command
            )]
        )
    }
}
