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
}
