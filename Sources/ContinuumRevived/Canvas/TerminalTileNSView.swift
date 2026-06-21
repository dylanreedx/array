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
        setContentView(hostView)
        hostView.attach(runtime: runtime)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var contentTopInsetWorldHeight: CGFloat { TileNSView.titleBarHeight }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        runtime.focus()
        return true
    }

    override func releaseFocus(reason: FocusRequest) {
        runtime.blur()
    }
}
