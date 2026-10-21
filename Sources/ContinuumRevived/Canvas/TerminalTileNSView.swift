import AppKit
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts a live Ghostty terminal runtime. The body of the tile
/// is a `TerminalHostView` so the existing TerminalEngine adapter does not
/// need to know about the canvas.
@MainActor
final class TerminalTileNSView: TileNSView {
    let hostView: TerminalHostView
    let runtime: GhosttyTerminalRuntime

    init(tile: Tile, runtime: GhosttyTerminalRuntime) {
        self.runtime = runtime
        self.hostView = TerminalHostView(frame: .zero)
        super.init(tile: tile)
        applyThemeBackground(runtime.resolvedThemeSnapshot.backgroundColor)
        setContentView(hostView)
        hostView.attach(runtime: runtime)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// P1.9: the terminal owns this tile's body colour (it comes from the Ghostty
    /// theme, not from the tile default), so it has to re-assert it after the base
    /// class re-applies — otherwise an appearance change repaints a themed terminal
    /// with the generic tile fill.
    override func applyTokens() {
        super.applyTokens()
        applyThemeBackground(runtime.resolvedThemeSnapshot.backgroundColor)
    }

    private func applyThemeBackground(_ color: NSColor?) {
        guard let color else { return }
        layer?.backgroundColor = color.cgColor
        hostView.applyTerminalBackground(color)
    }

    /// A covered window's terminal has nothing to draw for. Renderer only —
    /// focus and visibility are untouched, so a space round-trip is invisible.
    override func windowOcclusionChanged(visible: Bool) {
        runtime.setRendererOccluded(!visible)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        runtime.focus()
        return true
    }

    override func releaseFocus(reason: FocusRequest) {
        runtime.blur()
    }

    // MARK: - A claude typed into this shell (.plans/79, edge case 4)

    /// The Claude session session discovery found running in this terminal,
    /// offered in the band as "Open as agent tile". Set by the app from each
    /// discovery pass; nil when none runs here, or an agent owns it already.
    var claudeSessionId: String? {
        didSet { if claudeSessionId != oldValue { refreshSessionAction() } }
    }
    /// An Array agent owns that session already (`claude --resume` of an
    /// agent's own session, typed here): the band shows that agent instead of
    /// offering a second one on the same session.
    var claudeSessionOwnedByAgent = false {
        didSet { if claudeSessionOwnedByAgent != oldValue { refreshSessionAction() } }
    }

    private func refreshSessionAction() {
        setTitleBarSessionAction(claudeSessionId == nil ? nil : .init(
            label: "Claude Code", action: claudeSessionOwnedByAgent ? Self.showAgentTitle : Self.openAsAgentTileTitle))
    }
    /// The app's move: an agent tile beside this one on the same session.
    var onOpenAsAgentTile: ((String) -> Void)?

    static let openAsAgentTileTitle = "Open as agent tile"
    static let showAgentTitle = "Show agent"

    override func sessionActionRequested() {
        guard let claudeSessionId else { return }
        onOpenAsAgentTile?(claudeSessionId)
    }

    /// Always in the tile menu, so a band too narrow for the button still
    /// offers it.
    override func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] {
        guard claudeSessionId != nil else { return [] }
        let item = NSMenuItem(
            title: claudeSessionOwnedByAgent ? "Show Agent" : "Open as Agent Tile",
            action: #selector(openAsAgentTileFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(
            claudeSessionOwnedByAgent ? "terminalTile.showAgent" : "terminalTile.openAsAgentTile")
        return [item]
    }

    @objc private func openAsAgentTileFromMenu(_ sender: Any?) { sessionActionRequested() }
}
