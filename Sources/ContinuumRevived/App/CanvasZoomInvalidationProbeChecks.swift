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
        window.orderFrontOffscreenForChecks()

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

    private static func runFileTileZoom() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-file-zoom-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Review.md")
        try "# Performance review\n\nDrag these tiles across the grid.\n\n```swift\nlet gap = 8\n```\n".write(to: file, atomically: true, encoding: .utf8)
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.3), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil); window.contentView = nil }
        try expect(!canvas.qaResidencyTimerRunning, "an empty canvas must not poll for file previews")
        let placement = ZonePlacement(zoneId: UUID(), projectId: UUID(),
            origin: ZonePoint(x: 100, y: 100), size: ZoneSize(width: 5_400, height: 2_100),
            color: "blue", collapsed: false, hydrationPolicy: .automatic)
        var views: [FileTileNSView] = []
        for index in 0..<128 {
            var tile = Tile(id: UUID(), kind: .file, title: "Tile \(index)",
                frame: TileFrame(x: Double(index % 16) * 328 + 24, y: Double(index / 16) * 228 + 58,
                                 width: 320, height: 220),
                zPosition: .fromLegacyRank(index + 1), zoneId: placement.zoneId, runtimeRef: nil, metadata: TileMetadata())
            tile.metadata.filePath = file.path
            let view = FileTileNSView(tile: tile)
            if CommandLine.arguments.contains("--without-accessories") { view.setTitleBarAccessory(nil) }
            canvas.install(tileView: view, for: tile)
            views.append(view)
        }
        let zone = CanvasNSView.ZoneLayer(placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Zoom review"),
            tiles: views.map(\.tile))
        for view in views { zone.tileViews[view.tile.id] = view }
        canvas.setZones([zone])
        try expect(canvas.worldPlane.fileTileViewCount == 128 && canvas.qaResidencyTimerRunning,
                   "installing file previews must start their quiet residency heartbeat")
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        func capture(_ view: NSView?) throws -> CGImage {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(message: "missing view for zoom fidelity check")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { throw Failure(message: "empty zoom fidelity image") }
            return image
        }
        let nativeHeader = try capture(views[0].qaDisplayedTitleAccessory)
        let initialHeaderHeight = views[0].qaTitleBarFrame.height
        let controlPoint = views[0].qaModeControl!.convert(
            NSPoint(x: views[0].qaModeControl!.bounds.midX, y: views[0].qaModeControl!.bounds.midY), to: views[0])
        let nativeOnly = CommandLine.arguments.contains("--native-bodies")
        if nativeOnly {
            canvas.surfaceResidencyEnabled = false
            canvas.filePreviewResidencyEnabled = false
        }
        canvas.residencyPointerProvider = { nil }
        canvas.occlusionVisibilityProvider = { true }
        var residencyTime: TimeInterval = 1_000
        canvas.residencyNowProvider = { residencyTime }
        canvas.evaluateTileResidency()
        // The normal quiet heartbeat, outside the measured gesture. No cache
        // population is allowed to hide inside a camera event.
        residencyTime += 5
        for _ in 0..<40 {
            canvas.evaluateTileResidency()
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        if !nativeOnly {
            try expect(canvas.qaSurfacedTileViews.count == 128, "all quiet file previews should surface")
            if !CommandLine.arguments.contains("--without-accessories") {
                let missing = views.filter { !$0.qaAccessoryIsSurfaced }
                try expect(missing.isEmpty, "quiet previews must retain title controls too: \(missing.count) missing; "
                    + missing.prefix(3).map { "\(String(describing: $0.qaTitleAccessory?.frame)) window=\($0.qaTitleAccessory?.window != nil)" }.joined(separator: ", "))
            }
        }
        if !nativeOnly, !CommandLine.arguments.contains("--without-accessories") {
            let cachedHeader = try capture(views[0].qaDisplayedTitleAccessory)
            let difference = TileSurfaceResidencyChecks.meanChannelDifference(nativeHeader, cachedHeader)
            print("Off-screen title compositor: mean channel difference \(difference) / 255")
            for (name, image) in [("native", nativeHeader), ("cached", cachedHeader)] {
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try data?.write(to: URL(fileURLWithPath: "/tmp/array-zoom-\(name)-header.png"))
            }
            // Off-display glass controls can contribute only their shadows.
            // This guards placement drift; live labels/buttons are reviewed in Dev.
            try expect(difference <= 2, "title compositor drift; difference \(difference)")
            try expect(canvas.qaTotalSurfaceBytes > canvas.tileSurfaceStore.totalBytes,
                       "the image budget must count retained title controls")
            try expect(canvas.qaTotalSurfaceBytes <= canvas.residencySurfaceByteBudget,
                       "preview bodies and controls must stay within the image budget")
        }
        let bakeCount = canvas.tileSurfaceStore.qaBakeCount
        var gestureTime: TimeInterval = 2_000
        canvas.cameraDriver.nowProvider = { gestureTime }
        let originalFrames = canvas.worldPlane.subviews.compactMap { $0 as? TileNSView }.map(\.frame)
        var failures: [String] = []
        for input in ["Command-scroll", "pinch"] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 0.3))
            canvas.layoutSubtreeIfNeeded()
            var samples: [Double] = []
            let before = canvas.qaTotalTileLayoutPassCount
            if input == "pinch" {
                canvas.cameraDriver.notePinch(magnification: 0, phase: .began,
                                             location: .zero, timestamp: gestureTime)
            }
            for step in 0..<32 {
                let start = ProcessInfo.processInfo.systemUptime
                let drawsBefore = views.reduce(0) { $0 + $1.qaTitleBarDrawCount }
                let zoom = 0.3 + Double(step < 16 ? step : 31 - step) * 0.015
                gestureTime += 0.02
                let ratio = zoom / canvas.viewport.zoom
                if input == "pinch" {
                    let magnification = exp(log(ratio) / canvas.cameraDriver.tuning.pinchZoomGain) - 1
                    canvas.cameraDriver.notePinch(magnification: magnification, phase: .changed,
                                                 location: .zero, timestamp: gestureTime)
                } else {
                    let delta = log(ratio) / canvas.cameraDriver.tuning.scrollZoomGain
                    canvas.cameraDriver.noteScrollZoom(deltaY: delta, location: .zero)
                }
                let appliedAt = ProcessInfo.processInfo.systemUptime
                canvas.layoutSubtreeIfNeeded()
                let laidOutAt = ProcessInfo.processInfo.systemUptime
                window.displayIfNeeded()
                let displayedAt = ProcessInfo.processInfo.systemUptime
                CATransaction.flush()
                let endedAt = ProcessInfo.processInfo.systemUptime
                samples.append((endedAt - start) * 1000)
                if CommandLine.arguments.contains("--trace-zoom") {
                    print("ZOOM \(input) step=\(step) zoom=\(zoom) apply=\((appliedAt-start)*1000) layout=\((laidOutAt-appliedAt)*1000) display=\((displayedAt-laidOutAt)*1000) commit=\((endedAt-displayedAt)*1000) draws=\(views.reduce(0) { $0 + $1.qaTitleBarDrawCount } - drawsBefore)")
                }
                try expect(abs(canvas.viewport.zoom - zoom) < 0.000_001,
                           "\(input) must apply the requested zoom, not skip expensive steps")
            }
            canvas.cameraDriver.cancelGlide()
            samples.sort()
            print("File zoom (\(input)): 128 tiles, 32 steps, p50 \(samples[16]) ms, "
                  + "p95 \(samples[30]) ms, max \(samples[31]) ms; "
                  + "tile layouts \(canvas.qaTotalTileLayoutPassCount - before)")
            // A generous regression ceiling, not a claim of 60 Hz interaction.
            // Include synchronous layout/display: timing setViewport alone misses
            // the work AppKit performs later in the same frame.
            if samples[30] > 33 {
                failures.append("\(input) p95 \(samples[30]) ms exceeds the 33 ms frame ceiling")
            }
        }
        try expect(canvas.worldPlane.subviews.compactMap { $0 as? TileNSView }.map(\.frame) == originalFrames,
                   "zoom must preserve every tile's world frame")
        try expect(canvas.tileSurfaceStore.qaBakeCount == bakeCount,
                   "zoom must not synchronously recapture preview bodies")
        if !nativeOnly, let first = views.first, let control = first.qaModeControl {
            // A single hit must put the same real control back in the hierarchy.
            // Use the tile's title region; pointer conversion/hit testing runs
            // through the production TileNSView entry point.
            gestureTime += 0.02
            canvas.cameraDriver.noteScrollZoom(
                deltaY: log(0.75 / canvas.viewport.zoom) / canvas.cameraDriver.tuning.scrollZoomGain,
                location: .zero)
            let point = NSPoint(x: first.frame.minX + controlPoint.x,
                y: first.frame.minY + controlPoint.y + (first.qaTitleBarFrame.height - initialHeaderHeight) / 2)
            let hit = first.hitTest(point)
            try expect(hit === control, "the very first click after zoom must hit the restored mode control")
            try expect(first.surfaceResidency == .native && !first.qaAccessoryIsSurfaced,
                       "first incoming hit must restore body and controls together")
            try expect(control.window === window && control.isDescendant(of: first),
                       "restored mode control must belong to the live tile")
            control.selectedSegment = MarkdownDocumentMode.split.segmentIndex
            control.sendAction(control.action, to: control.target)
            try expect(first.mode == .split, "restored native mode control must deliver its action")
            first.setMode(.preview)
            canvas.layoutSubtreeIfNeeded()
            canvas.cameraDriver.qaMarkSettledNow()
            try expect(first.surfaceResidency == .native, "a focused preview must remain native")
            window.makeFirstResponder(nil)
            residencyTime += 5
            for _ in 0..<3 { canvas.evaluateTileResidency(); canvas.layoutSubtreeIfNeeded() }
            residencyTime += 5
            canvas.evaluateTileResidency()
            try expect(first.surfaceResidency == .surfaced && first.qaAccessoryIsSurfaced,
                       "a subsequent quiet preview must be able to cache again; \(String(describing: canvas.qaLastResidencyDecision(first.tile.id)))")
            let priorRevision = first.currentSurfaceRevision
            first.setReferencedAgentTiles([UUID()])
            try expect(first.currentSurfaceRevision != priorRevision, "changed title controls must invalidate the cached presentation")
            try expect(first.surfaceResidency == .native, "changed title controls must restore a fresh native presentation")
            canvas.evaluateTileResidency()
            residencyTime += 5
            canvas.evaluateTileResidency()
            try expect(first.surfaceResidency == .surfaced, "updated preview should cache again after becoming quiet")
            let originalSize = first.frame.size
            first.setFrameSize(NSSize(width: originalSize.width + 20, height: originalSize.height))
            first.layoutSubtreeIfNeeded()
            try expect(first.surfaceResidency == .native && !first.qaAccessoryIsSurfaced,
                       "resizing a cached tile must restore its real content")
            first.setFrameSize(originalSize)
        }
        if !nativeOnly, let first = views.first {
            let duplicatePlacement = ZonePlacement(zoneId: UUID(), projectId: UUID(),
                origin: ZonePoint(x: 10_000, y: 5_000), size: ZoneSize(width: 600, height: 400),
                color: "blue", collapsed: false, hydrationPolicy: .automatic)
            var duplicate = first.tile
            duplicate.zoneId = duplicatePlacement.zoneId
            duplicate.frame = TileFrame(x: 24, y: 58, width: 320, height: 220)
            let duplicateView = FileTileNSView(tile: duplicate)
            let duplicateZone = CanvasNSView.ZoneLayer(placement: duplicatePlacement,
                renderModel: CanvasNSView.ZoneRenderModel(placement: duplicatePlacement, displayName: "Duplicate occurrence"),
                tiles: [duplicate])
            duplicateZone.tileViews[duplicate.id] = duplicateView
            canvas.setZones([zone, duplicateZone])
            canvas.layoutSubtreeIfNeeded()
            canvas.evaluateTileResidency()
            residencyTime += 5
            canvas.evaluateTileResidency()
            try expect(first.surfaceResidency == .native && duplicateView.surfaceResidency == .native,
                       "duplicate mounted IDs must retain independent native presentations")
            try expect(canvas.tileSurfaceStore.surface(for: first.tile.id) == nil,
                       "duplicate mounted IDs must not share one cached image")
        }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 0.3))
        canvas.layoutSubtreeIfNeeded()
        if let first = views.first {
            let rect = first.qaCloseButtonFrame
            let point = NSPoint(x: first.frame.minX + rect.midX, y: first.frame.minY + rect.midY)
            guard let close = first.hitTest(point) as? NSControl else {
                throw Failure(message: "zoomed close control must remain hittable: rect=\(rect) tile=\(first.frame) bounds=\(first.bounds) hit=\(String(describing: first.hitTest(point)))")
            }
            var closes = 0
            first.onClose = { closes += 1 }
            try expect(close.accessibilityRole() == .button, "close must keep button accessibility")
            try expect(close.accessibilityPerformPress() && closes == 1, "accessible close must dispatch once")
            close.isEnabled = false
            try expect(!close.accessibilityPerformPress() && closes == 1, "disabled close must not dispatch")
            close.isEnabled = true
            func mouse(_ type: NSEvent.EventType, at local: NSPoint) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with: type,
                    location: close.convert(local, to: nil), modifierFlags: [], timestamp: gestureTime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 0) else { throw Failure(message: "close mouse fixture") }
                return event
            }
            let center = NSPoint(x: close.bounds.midX, y: close.bounds.midY)
            NSApp.postEvent(try mouse(.leftMouseUp, at: NSPoint(x: -20, y: -20)), atStart: true)
            close.mouseDown(with: try mouse(.leftMouseDown, at: center))
            try expect(closes == 1, "releasing outside close must cancel")
            NSApp.postEvent(try mouse(.leftMouseUp, at: center), atStart: true)
            close.mouseDown(with: try mouse(.leftMouseDown, at: center))
            try expect(closes == 2, "releasing inside close must dispatch once")
            guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: gestureTime, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49) else { throw Failure(message: "close keyboard fixture") }
            close.keyDown(with: space)
            try expect(closes == 3, "keyboard close must dispatch once")
        }
        canvas.setZones([])
        try expect(canvas.worldPlane.fileTileViewCount == 0 && !canvas.qaResidencyTimerRunning,
                   "removing the last file preview must stop its residency heartbeat")
        try expect(failures.isEmpty, failures.joined(separator: "; "))
    }

    static func run() throws {
        if CommandLine.arguments.contains("--file-tiles") || CommandLine.arguments.contains("--file-tile-zoom-check") {
            try runFileTileZoom()
            return
        }
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
