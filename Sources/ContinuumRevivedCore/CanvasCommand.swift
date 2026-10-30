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
            CommandDefinition(
                id: "zone.create",
                title: "Create Zone",
                aliases: ["new zone", "project zone"],
                paletteAction: .createZone,
                floatingToolbarItem: FloatingToolbarItem(title: "Zone", symbolName: "square.dashed", action: .createZone),
                paletteVisible: false
            ),
            definition("agent.newManaged", .newManagedAgent, aliases: ["create agent", "assistant"], shortcuts: [
                globalShortcut("global.newAgent", command: "agent.newManaged", keyCode: 45, modifiers: .command, priority: .canvasRail)
            ]),
            // A tile-less agent (P2A.6). `agent.newManaged` is spawn + attach a
            // tile; this one is the spawn alone, so an agent can exist and run
            // without any canvas layout.
            definition("agent.newHeadless", .newHeadlessAgent, aliases: ["headless", "tileless"]),
            // N selected queue rows, N isolated agents (P2D.6). The multi-row
            // sibling of the ticket tile's own one-row dispatch.
            definition("agent.fanOut", .fanOutQueueSelection, aliases: ["batch agents", "tickets"]),
            CommandDefinition(
                id: "tile.newTerminal",
                title: "New Terminal…",
                aliases: ["shell", "terminal"],
                floatingToolbarItem: FloatingToolbarItem(title: "Terminal", symbolName: "terminal", action: .terminalProfiles),
                paletteVisible: false,
                shortcuts: [globalShortcut("global.newTerminal", command: "tile.newTerminal", keyCode: 17, modifiers: .command, priority: .canvasRail)]
            ),
            definition("tile.newNote", .newNote, aliases: ["note"], shortcuts: [
                globalShortcut("global.newNote", command: "tile.newNote", keyCode: 45, modifiers: [.command, .shift], priority: .canvasRail)
            ]),
            definition("tile.newBoard", .newBoard, aliases: ["kanban", "board", "tasks"]),
            definition("board.open", .openBoard, aliases: ["saved boards", "reopen board"]),
            definition("tile.newBrowser", .newBrowser, aliases: ["web"]),
            definition("tile.newIOSPreview", .newIOSPreview, aliases: ["ios", "simulator", "iphone", "ipad"]),
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
            definition("view.showProcesses", .showProcesses, aliases: ["ports", "background processes", "dev server"]),
            definition("help.replayGettingStarted", .replayGettingStarted, aliases: ["onboarding", "learn Array"]),
            // The focused note's or file's backing file. Its ⌘K row is contextual
            // (`revealFocusedTileInFinder`), so no static row here.
            CommandDefinition(
                id: "tile.revealInFinder",
                title: "Reveal in Finder",
                aliases: ["show in finder", "finder"],
                paletteVisible: false,
                shortcuts: [globalShortcut("global.revealInFinder", command: "tile.revealInFinder", keyCode: 15, modifiers: [.command, .option])]
            ),
            definition("workspace.new", .newWorkspace, aliases: ["canvas"]),
            // M1.11: the only add route a workspace with no projects has.
            definition("project.add", .addProject, aliases: ["register project", "open folder"]),
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
        aliases: [String] = [],
        shortcuts: [ShortcutDefinition] = []
    ) -> CommandDefinition {
        CommandDefinition(
            id: id,
            title: action.displayName,
            aliases: aliases,
            paletteAction: action,
            floatingToolbarItem: toolbarItem(for: action),
            shortcuts: shortcuts
        )
    }

    /// All user-facing canvas tile creation actions flow through this mapping.
    /// The AppKit toolbar enumerates `definitions()` and consumes this metadata;
    /// adding a new tile command here makes it appear there automatically.
    private static func toolbarItem(for action: LaunchPaletteAction) -> FloatingToolbarItem? {
        switch action {
        case .newManagedAgent:
            return FloatingToolbarItem(title: "Agent", symbolName: "sparkles", action: .palette(action))
        case .newNote:
            return FloatingToolbarItem(title: "Note", symbolName: "note.text", action: .palette(action))
        case .newBoard:
            return FloatingToolbarItem(title: "Board", symbolName: "rectangle.split.3x1", action: .palette(action))
        case .newBrowser:
            return FloatingToolbarItem(title: "Browser", symbolName: "globe", action: .palette(action))
        case .newIOSPreview:
            return FloatingToolbarItem(title: "iOS Preview", symbolName: "iphone", action: .palette(action))
        case .openFile:
            return FloatingToolbarItem(title: "Editor", symbolName: "doc.text", action: .palette(action))
        case .openFileTree:
            return FloatingToolbarItem(title: "File Tree", symbolName: "folder", action: .palette(action))
        case .newDiffReview:
            return FloatingToolbarItem(title: "Diff", symbolName: "plusminus", action: .palette(action))
        default:
            return nil
        }
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
