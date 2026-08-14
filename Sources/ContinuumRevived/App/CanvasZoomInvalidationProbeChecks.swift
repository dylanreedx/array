import AppKit
import ContinuumRevivedCore
import Foundation

/// Why does a zoom lay out every tile when a pan lays out none?
///
/// `canvas.pan` scores 0 on `tileLayoutPasses` and `canvas.zoom` scores one per
/// tile per step. Both gestures go through the same `setViewport` funnel and move
/// the same single ancestor, so the difference has to come from WHICH property of
/// the plane they write — or from something else the zoom branch does. This probe
/// separates those, because they have completely different fixes:
///
/// - `applyCamera` with a moving ORIGIN and a fixed zoom (a pan).
/// - `applyCamera` with a moving ZOOM and a fixed origin (a zoom), called
///   directly on the plane, so nothing else in the camera path runs.
/// - The full production `setViewport` zoom, which also refreshes zoom-dependent
///   chrome on every tile.
///
/// The gap between the second and third is the chrome refresh's contribution, and
/// isolating it that way needs no test-only suppression flag in production — the
/// difference between two real paths IS the measurement.
///
/// It also times a plain-`NSView` tile body against an Auto Layout one under the
/// same bounds-size sweep. Most tile bodies use constraints
/// (`FileMarkdownDocumentView`, `BrowserTileNSView`, `FileTreeTileNSView`, …) and
/// a real-gesture profile runs through `NSConstraintBasedLayoutInternal`, so Auto
/// Layout is a plausible amplifier of each pass even if it is not what triggers
/// them.
///
/// Gated on `--canvas-zoom-invalidation-probe-check`.
@MainActor
enum CanvasZoomInvalidationProbeChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    /// A tile body wired with Auto Layout, matching how real tile bodies are built.
    private final class ConstraintBody: NSView {
        init(depth: Int) {
            super.init(frame: .zero)
            var parent: NSView = self
            for _ in 0..<depth {
                let child = NSView(frame: .zero)
                child.translatesAutoresizingMaskIntoConstraints = false
                parent.addSubview(child)
                NSLayoutConstraint.activate([
                    child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 4),
                    child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -4),
                    child.topAnchor.constraint(equalTo: parent.topAnchor, constant: 4),
                    child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -4)
                ])
                parent = child
            }
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    /// The same shape with manual frames, so the comparison isolates the layout
    /// engine rather than the view count.
    private final class ManualBody: NSView {
        init(depth: Int) {
            super.init(frame: .zero)
            var parent: NSView = self
            for _ in 0..<depth {
                let child = NSView(frame: parent.bounds.insetBy(dx: 4, dy: 4))
                child.autoresizingMask = []
                parent.addSubview(child)
                parent = child
            }
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    private struct Harness {
        let canvas: CanvasNSView
        let window: NSWindow
        let tiles: [TileNSView]
    }

    private static func makeHarness(tileCount: Int, body: (Int) -> NSView) -> Harness {
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1_400, height: 900)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        var views: [TileNSView] = []
        for index in 0..<tileCount {
            let tile = Tile(
                id: UUID(), kind: .note, title: "probe-\(index)",
                frame: TileFrame(x: Double(index % 4) * 340 + 20,
                                 y: Double(index / 4) * 260 + 20,
                                 width: 320, height: 240),
                zPosition: .fromLegacyRank(index + 1),
                runtimeRef: nil, metadata: TileMetadata()
            )
            let view = TileNSView(tile: tile)
            view.setContentView(body(4))
            canvas.install(tileView: view, for: tile)
            views.append(view)
        }
        canvas.layoutSubtreeIfNeeded()
        return Harness(canvas: canvas, window: window, tiles: views)
    }

    private static func teardown(_ harness: Harness) {
        harness.window.orderOut(nil)
        harness.window.contentView = nil
    }

    private struct Result {
        let passes: Int
        let seconds: Double
    }

    /// Runs `steps` camera writes and reports how many layout passes reached the
    /// tiles. `layoutSubtreeIfNeeded` after each step is what forces the traversal
    /// synchronously; in the live app the window's display cycle does it.
    private static func measure(
        _ harness: Harness, steps: Int, _ step: (Int) -> Void
    ) -> Result {
        let before = harness.canvas.qaTotalTileLayoutPassCount
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<steps {
            step(index)
            harness.canvas.layoutSubtreeIfNeeded()
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        return Result(passes: harness.canvas.qaTotalTileLayoutPassCount - before, seconds: seconds)
    }

    static func run() throws {
        let tileCount = 12
        let steps = 60
        let viewportSize = CGSize(width: 1_400, height: 900)

        let harness = makeHarness(tileCount: tileCount, body: { ManualBody(depth: $0) })
        defer { teardown(harness) }
        let plane = harness.canvas.worldPlane

        // A — PAN SHAPE: bounds ORIGIN moves, zoom fixed. Nothing else runs.
        let originOnly = measure(harness, steps: steps) { index in
            plane.applyCamera(viewportSize: viewportSize,
                              worldOrigin: CGPoint(x: Double(index + 1) * 7, y: Double(index + 1) * 5),
                              zoom: 1)
        }

        // B — ZOOM SHAPE: bounds SIZE moves, origin fixed. Still nothing else.
        let sizeOnly = measure(harness, steps: steps) { index in
            let zoom = 0.4 + 0.6 * (1 + sin(Double(index) / 9.0)) / 2
            plane.applyCamera(viewportSize: viewportSize, worldOrigin: .zero, zoom: zoom)
        }

        // C — the PRODUCTION zoom, which also refreshes zoom-dependent chrome.
        let production = measure(harness, steps: steps) { index in
            let zoom = 0.4 + 0.6 * (1 + sin(Double(index) / 9.0)) / 2
            harness.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
        }

        // E — the production path for a PAN: everything `setViewport` does EXCEPT
        // the zoom-dependent chrome branch (overlay repositioning, cursor-rect
        // invalidation, the delegate callback). Isolating this is what lets C - E
        // be attributed to the chrome branch specifically rather than to "the
        // production path" as a whole.
        let productionPan = measure(harness, steps: steps) { index in
            harness.canvas.setViewport(CanvasViewport(x: Double(index + 1) * 7,
                                                      y: Double(index + 1) * 5, zoom: 1))
        }

        // D — the same bounds-size sweep against an Auto Layout body, to see
        // whether constraints amplify the COST of each pass even where they do not
        // change how many passes happen.
        let constraintHarness = makeHarness(tileCount: tileCount, body: { ConstraintBody(depth: $0) })
        defer { teardown(constraintHarness) }
        let constraintPlane = constraintHarness.canvas.worldPlane
        let constrained = measure(constraintHarness, steps: steps) { index in
            let zoom = 0.4 + 0.6 * (1 + sin(Double(index) / 9.0)) / 2
            constraintPlane.applyCamera(viewportSize: viewportSize, worldOrigin: .zero, zoom: zoom)
        }

        func perStepMs(_ result: Result) -> Double { result.seconds / Double(steps) * 1_000 }

        print("canvas zoom invalidation probe — \(tileCount) tiles, \(steps) steps each")
        print(String(format: "  A origin only (pan shape)      %5d passes  %6.3f ms/step",
                     originOnly.passes, perStepMs(originOnly)))
        print(String(format: "  B size only (zoom shape)       %5d passes  %6.3f ms/step",
                     sizeOnly.passes, perStepMs(sizeOnly)))
        print(String(format: "  C production setViewport zoom  %5d passes  %6.3f ms/step",
                     production.passes, perStepMs(production)))
        print(String(format: "  E production setViewport pan   %5d passes  %6.3f ms/step",
                     productionPan.passes, perStepMs(productionPan)))
        print(String(format: "  D size only, Auto Layout body  %5d passes  %6.3f ms/step",
                     constrained.passes, perStepMs(constrained)))
        print("  bounds-size itself:            B = \(sizeOnly.passes) passes")
        print("  rest of the production path:   E = \(productionPan.passes) passes")
        print("  zoom-dependent chrome refresh: C - E = \(production.passes - productionPan.passes) passes")
        print(String(format: "  Auto Layout amplification: D/B = %.2fx per step", perStepMs(constrained) / max(perStepMs(sizeOnly), 0.0001)))

        // The property this leg exists to gate, and the one that is RED today: a
        // camera gesture may cost each tile about one settling layout, never one
        // per step. A is the proof the counter can read low — it is the same
        // ancestor, the same tiles, the same traversal opportunity, and it costs
        // nothing.
        try expect(
            originOnly.passes == 0,
            "a bounds-ORIGIN camera step must not lay out any tile; got \(originOnly.passes)"
        )
        // B and E are the ATTRIBUTION, and both are green. Changing the plane's
        // bounds SIZE costs no tile layout at all — AppKit does not propagate
        // needsLayout for it here, which was the standing hypothesis and is wrong.
        // Neither does the rest of the production camera path. So whatever C pays
        // for, it is the one thing C has that B and E do not.
        try expect(
            sizeOnly.passes == 0,
            "a bounds-SIZE camera step must not lay out any tile either; got \(sizeOnly.passes)"
        )
        try expect(
            productionPan.passes == 0,
            "the production camera path minus the zoom branch must not lay out any tile; "
            + "got \(productionPan.passes)"
        )
        try expect(
            production.passes <= tileCount,
            "the production zoom path must cost about one settling layout per tile "
            + "(<= \(tileCount)); got \(production.passes)"
        )
    }
}
