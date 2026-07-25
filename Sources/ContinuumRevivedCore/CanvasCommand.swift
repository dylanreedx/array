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
    public static func all() -> [CanvasCommand] {
        [
            CanvasCommand(id: "agent.newManaged", action: .newManagedAgent),
            // A tile-less agent (P2A.6). `agent.newManaged` is spawn + attach a
            // tile; this one is the spawn alone, so an agent can exist and run
            // without any canvas layout.
            CanvasCommand(id: "agent.newHeadless", action: .newHeadlessAgent),
            CanvasCommand(id: "tile.newNote", action: .newNote),
            CanvasCommand(id: "tile.newBrowser", action: .newBrowser),
            CanvasCommand(id: "tile.openFile", action: .openFile),
            CanvasCommand(id: "tile.openFileTree", action: .openFileTree),
            CanvasCommand(id: "tile.newDiffReview", action: .newDiffReview),
            CanvasCommand(id: "view.fitCanvasToAll", action: .fitCanvasToAll),
            CanvasCommand(id: "view.previousView", action: .previousView),
            CanvasCommand(id: "view.previousTile", action: .previousTile),
            CanvasCommand(id: "view.previousZone", action: .previousZone),
            CanvasCommand(id: "view.toggleWorkspaceSidebar", action: .toggleWorkspaceSidebar),
            CanvasCommand(id: "workspace.new", action: .newWorkspace),
        ]
    }

    /// Palette-visible commands' actions, in declared order — the static action
    /// rows the launch palette shows before its dynamic rows.
    public static func paletteActions() -> [LaunchPaletteAction] {
        all().filter(\.paletteVisible).map(\.action)
    }
}
