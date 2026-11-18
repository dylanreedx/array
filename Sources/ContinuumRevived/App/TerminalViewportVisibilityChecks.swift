import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit
import IOSurface

/// `--terminal-viewport-visibility-check`: terminals far outside the viewport
/// must stop drawing, and a revealed one must show current output.
///
/// Draws are counted from the layer Ghostty presents into: each frame it
/// renders lands in an IOSurface whose seed moves, so a sampled seed that
/// changes is a rendered frame. Hidden surfaces still receive output (the
/// shell prints continuously) — only the renderer is asleep.
@MainActor
enum TerminalViewportVisibilityChecks {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }

    private struct DrawProbe {
        var lastSeed: UInt32?
        var lastContents: UInt?
        var draws = 0
        mutating func sample(_ view: GhosttyTerminalView) {
            guard let contents = view.layer?.contents else { return }
            let key = UInt(bitPattern: Unmanaged.passUnretained(contents as AnyObject).toOpaque())
            // swiftlint:disable:next force_cast
            let seed = IOSurfaceGetSeed(contents as! IOSurfaceRef)
            if lastSeed != nil, (seed != lastSeed || key != lastContents) { draws += 1 }
            lastSeed = seed; lastContents = key
        }
    }

    static func run() throws -> String {
        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }

        let hiddenCount = 5
        var tiles: [Tile] = []
        for index in 0...hiddenCount {
            // Tile 0 is on screen; the rest are several viewports away.
            let x = index == 0 ? 20.0 : 6000.0 + Double(index) * 900
            tiles.append(Tile(
                id: UUID(), kind: .terminal, title: "VIS_\(index)",
                frame: TileFrame(x: x, y: 20, width: 700, height: 420),
                zPosition: .fromLegacyRank(index + 1), runtimeRef: nil, metadata: TileMetadata()))
        }
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 820)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.close() }

        let script = "i=0; while :; do i=$((i+1)); echo TICK$i; sleep 0.01; done"
        var runtimes: [GhosttyTerminalRuntime] = []
        var views: [TerminalTileNSView] = []
        for tile in tiles {
            let runtime = GhosttyTerminalRuntime(
                tileId: tile.id, title: tile.title,
                launchProfile: LaunchProfile(command: "/bin/sh", arguments: ["-c", script],
                                             cwd: NSTemporaryDirectory(), title: tile.title),
                ghostty: context)
            let view = TerminalTileNSView(tile: tile, runtime: runtime)
            canvas.install(tileView: view, for: tile)
            view.layoutSubtreeIfNeeded()
            runtimes.append(runtime); views.append(view)
        }
        defer {
            for (runtime, view) in zip(runtimes, views) {
                runtime.terminate(policy: .force)
                view.hostView.detachRuntime()
            }
        }

        func pump(_ seconds: TimeInterval, probes: inout [DrawProbe]) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
                for (index, runtime) in runtimes.enumerated() {
                    if let view = runtime.qaTerminalView { probes[index].sample(view) }
                }
            }
        }

        var probes = Array(repeating: DrawProbe(), count: runtimes.count)
        try pump(1.0, probes: &probes)
        // The production signal: the canvas settle pass.
        canvas.updateRendererViewportVisibility(full: true)
        try pump(0.5, probes: &probes)

        probes = Array(repeating: DrawProbe(), count: runtimes.count)
        let window1: TimeInterval = 3
        try pump(window1, probes: &probes)
        let visibleRate = Double(probes[0].draws) / window1
        let hiddenRates = probes.dropFirst().map { Double($0.draws) / window1 }
        let hiddenMax = hiddenRates.max() ?? 0
        let summary = String(format: "visible %.1f draws/s; hidden max %.1f draws/s over %d hidden",
                             visibleRate, hiddenMax, hiddenCount)

        guard visibleRate >= 10 else { throw CheckError(description: "visible terminal barely draws: \(summary)") }
        guard hiddenMax <= 1 else { throw CheckError(description: "hidden terminals still draw: \(summary)") }
        for (index, runtime) in runtimes.enumerated().dropFirst() {
            guard runtime.qaTerminalView?.qaLastAppliedGhosttyVisibility == false else {
                throw CheckError(description: "hidden terminal \(index) was not told it is hidden: \(summary)")
            }
        }

        // Reveal tile 1: pan the camera onto it.
        let target = tiles[1].frame
        canvas.setViewport(CanvasViewport(x: target.x - 20, y: target.y - 20, zoom: 1))
        canvas.updateRendererViewportVisibility(full: true)
        var reveal = Array(repeating: DrawProbe(), count: runtimes.count)
        try pump(1.0, probes: &reveal)
        let revealed = runtimes[1]
        guard revealed.qaTerminalView?.qaLastAppliedGhosttyVisibility == true else {
            throw CheckError(description: "revealed terminal was not woken: \(summary)")
        }
        guard reveal[1].draws >= 5 else {
            throw CheckError(description: "revealed terminal did not resume drawing (\(reveal[1].draws) draws): \(summary)")
        }
        // Content current: the screen shows a tick far past what a 0 s start would.
        let text = revealed.visibleText()
        let ticks = text.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            line.hasPrefix("TICK") ? Int(line.dropFirst(4)) : nil
        }
        guard let newest = ticks.max(), newest > 200 else {
            throw CheckError(description: "revealed terminal shows stale content (newest tick \(ticks.max() ?? -1)): \(summary)")
        }
        return summary + String(format: "; revealed %d draws/s, newest tick %d", reveal[1].draws, newest)
    }
}
