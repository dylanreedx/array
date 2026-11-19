import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

/// `--terminal-wheel-scroll-check`: what reaches Ghostty when a terminal view
/// gets precise (trackpad) and line (wheel) scroll events through the real
/// `scrollWheel(with:)`. Ghostty reads precise deltas as pixels and plain ones
/// as wheel ticks, so a precise event must carry the precision bit.
@MainActor
enum TerminalWheelScrollChecks {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws -> String {
        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }
        let tile = Tile(
            id: UUID(), kind: .terminal, title: "WHEEL",
            frame: TileFrame(x: 20, y: 20, width: 700, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 820)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.close() }
        let runtime = GhosttyTerminalRuntime(
            tileId: tile.id, title: tile.title,
            launchProfile: LaunchProfile(command: "/bin/sh", arguments: ["-c", "sleep 30"],
                                         cwd: NSTemporaryDirectory(), title: tile.title),
            ghostty: context)
        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        canvas.install(tileView: view, for: tile)
        view.layoutSubtreeIfNeeded()
        defer { runtime.terminate(policy: .force); view.hostView.detachRuntime() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        guard let terminal = runtime.qaTerminalView else { throw CheckError(description: "no terminal view") }

        func scroll(pixels: Bool, dy: Int32) throws -> (deltaY: Double, mods: Int32) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line,
                                   wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { throw CheckError(description: "cannot build scroll event") }
            guard event.hasPreciseScrollingDeltas == pixels else {
                throw CheckError(description: "synthetic event precision \(event.hasPreciseScrollingDeltas) != \(pixels)")
            }
            let before = terminal.qaGhosttyScrollCallCount
            terminal.scrollWheel(with: event)
            guard terminal.qaGhosttyScrollCallCount == before + 1, let sent = terminal.qaLastGhosttyScroll else {
                throw CheckError(description: "scroll did not reach ghostty_surface_mouse_scroll")
            }
            return (sent.deltaY, sent.mods)
        }

        let precise = try scroll(pixels: true, dy: -12)
        guard precise.mods & 1 == 1 else {
            throw CheckError(description: "precise trackpad event reached Ghostty without the precision bit (mods \(precise.mods), deltaY \(precise.deltaY)); Ghostty would read it as wheel ticks")
        }
        let line = try scroll(pixels: false, dy: -3)
        guard line.mods & 1 == 0 else {
            throw CheckError(description: "line wheel event carried the precision bit (mods \(line.mods))")
        }
        guard precise.deltaY < 0, line.deltaY < 0 else {
            throw CheckError(description: "scroll direction lost (precise \(precise.deltaY), line \(line.deltaY))")
        }
        return "precise dy \(precise.deltaY) mods \(precise.mods); line dy \(line.deltaY) mods \(line.mods)"
    }
}
