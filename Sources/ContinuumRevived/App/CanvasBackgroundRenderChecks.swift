import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// WS7 — the RENDERER witness, in pixels.
///
/// `runCanvasBackgroundChecks` (CoreChecks) proves the arithmetic. This proves
/// the canvas actually draws with it: the renderer's position in the real view
/// tree, the screen-fixed/world-aligned split read off sampled pixels before and
/// after a pan, the camera-step counters, image Fill/Fit and opacity, the
/// missing/corrupt fallback, and Aqua/Dark for all three patterns.
///
/// Everything runs in an OFFSCREEN fixture window (`orderFrontOffscreenForChecks`):
/// real layout, real backing store, real `draw(_:)`, nothing on Dylan's display.
@MainActor
enum CanvasBackgroundRenderChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let canvasSize = CGSize(width: 800, height: 600)
    /// Pinned rather than read from the display, so a pixel witness gives the
    /// same answer on a Retina laptop and an external 1x monitor.
    static let backingScale: Double = 2

    // Exact, deliberately unmistakable colours: no two share a channel value, so
    // a probe that reads the wrong one cannot look "close enough".
    static let baseColor = CanvasBackgroundRGBA(red: 0.10, green: 0.20, blue: 0.80, alpha: 1)!
    static let gridColor = CanvasBackgroundRGBA(red: 0.95, green: 0.65, blue: 0.05, alpha: 1)!

    static func run() throws {
        let world = try World()
        try checkHierarchy(world)
        try checkPatternPixelsInBothAppearances(world)
        try checkScreenFixedVersusWorldAligned(world)
        try checkCameraStepCosts(world)
        try checkImageGeometryAndOpacity(world)
        try checkMissingAndCorruptAsset(world)
        try writeContactSheet(world)
        print("canvas-background-render: hierarchy, 6 appearance/pattern probes, screen-fixed/world-aligned pan, camera counters, image fill/fit + opacity 0/.35/1, missing + corrupt fallback")
    }

    // MARK: - Fixture

    @MainActor
    final class World {
        let window: NSWindow
        let canvas: CanvasNSView
        let assetRoot: URL
        let store: CanvasBackgroundAssetStore
        var renderer: CanvasBackgroundRendererView { canvas.backgroundRenderer }

        init() throws {
            // The canvas builds its own `CanvasBackgroundAssetStore()` from the
            // resolved application-support directory, which is production's own
            // wiring and must stay that way — so the fixture moves that directory
            // rather than injecting a different store. `CONTINUUM_APP_SUPPORT` is
            // the seam the whole QA harness already uses; setting it here (only
            // when the caller has not) keeps this check from touching the dev or
            // prod store even when run bare.
            assetRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws7-render-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
            let existing = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] ?? ""
            if existing.isEmpty {
                setenv("CONTINUUM_APP_SUPPORT", assetRoot.path, 1)
            }
            // Exactly the store the renderer's cache resolves, so an asset the
            // check imports is one the canvas can actually find.
            store = CanvasBackgroundAssetStore()

            canvas = CanvasNSView(
                canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
            canvas.frame = CGRect(origin: .zero, size: canvasSize)

            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: canvasSize),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            canvas.layoutSubtreeIfNeeded()
            canvas.backgroundRenderer.backingScaleOverride = backingScale
        }

        deinit { try? FileManager.default.removeItem(at: assetRoot) }

        func apply(_ configuration: CanvasBackgroundConfiguration, viewport: CanvasViewport) {
            canvas.setCanvasBackground(configuration)
            canvas.setViewport(viewport)
            renderer.imageCache.qaDrainPendingDecodes()
            canvas.layoutSubtreeIfNeeded()
            // Force the draw so `qaLastRecord` always describes the configuration
            // and camera just applied. Without this, a caller that reads the
            // record without capturing first silently asserts against the
            // PREVIOUS scene — which is a false green, not a failure.
            renderer.display()
        }

        /// Render the BACKGROUND as the canvas would, in `appearance`, into a
        /// bitmap whose colour space this check OWNS.
        ///
        /// Not `cacheDisplay(in:to:)`: that renders into a bitmap matching the
        /// window's display, so the numbers a probe reads back depend on which
        /// monitor the machine happens to have — a wide-gamut display turned an
        /// exact sRGB `rgba(26,51,204)` into `rgba(34,77,214)`, and a check whose
        /// expected values move with the hardware is not a check. Drawing into an
        /// explicit sRGB context makes the sampled bytes the SAME bytes the
        /// configuration stores. `displayIgnoringOpacity(_:in:)` is still the real
        /// AppKit display path, so `draw(_:)` runs exactly as it does on screen.
        ///
        /// The context is pre-flipped (`translate` + `scale(1, -1)`), so user
        /// y = 0 lands on bitmap row 0 and a probe's point coordinates are the
        /// renderer's own — no mirrored sampling.
        func capture(appearance: NSAppearance.Name = .darkAqua) throws -> Capture {
            window.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            let view = renderer
            let scale = CGFloat(backingScale)
            let pixelWidth = Int(view.bounds.width * scale)
            let pixelHeight = Int(view.bounds.height * scale)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                    bytesPerRow: pixelWidth * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "could not create the sRGB capture context")
            }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            var captured = false
            (NSAppearance(named: appearance) ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                view.displayIgnoringOpacity(view.bounds, in: graphics)
                NSGraphicsContext.restoreGraphicsState()
                captured = true
            }
            guard captured else { throw Failure(description: "the appearance block never ran") }
            guard let image = context.makeImage(), let raw = context.data else {
                throw Failure(description: "the capture context produced no image")
            }
            // The RAW buffer, read as bytes. Going through `NSBitmapImageRep` /
            // `colorAt` reintroduces exactly the colour-space guesswork this
            // capture exists to remove: an untagged rep resolves against the
            // device profile, which is what produced the wide-gamut drift above.
            return Capture(
                width: pixelWidth, height: pixelHeight,
                bytesPerRow: context.bytesPerRow,
                pixels: Data(bytes: raw, count: context.bytesPerRow * pixelHeight),
                image: image)
        }
    }

    // MARK: - Pixel helpers

    /// One rendered frame, as premultiplied-last 8-bit sRGB bytes. Owning the
    /// buffer is what makes an expected value a constant instead of a property of
    /// whichever display the machine has.
    struct Capture {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: Data
        let image: CGImage
    }

    struct RGBA8: Equatable, CustomStringConvertible {
        var r = 0, g = 0, b = 0, a = 255
        var description: String { "rgba(\(r),\(g),\(b),\(a))" }
        func isNear(_ other: RGBA8, tolerance: Int = 6) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
                && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
        }
    }

    /// Sample at a POINT position (the renderer's own coordinates, y down),
    /// converting to the bitmap's device pixels.
    static func sample(_ capture: Capture, at point: CGPoint) throws -> RGBA8 {
        let scaleX = Double(capture.width) / Double(canvasSize.width)
        let scaleY = Double(capture.height) / Double(canvasSize.height)
        return try pixel(capture,
                         x: Int((Double(point.x) * scaleX).rounded(.down)),
                         y: Int((Double(point.y) * scaleY).rounded(.down)))
    }

    static func pixel(_ capture: Capture, x: Int, y: Int) throws -> RGBA8 {
        guard x >= 0, y >= 0, x < capture.width, y < capture.height else {
            throw Failure(description: "pixel (\(x), \(y)) is outside the \(capture.width)x\(capture.height) capture")
        }
        let offset = y * capture.bytesPerRow + x * 4
        let alpha = Int(capture.pixels[offset + 3])
        // Premultiplied-last: undo the premultiply so the value compares against
        // the configuration's own straight-alpha components.
        func straight(_ raw: UInt8) -> Int {
            guard alpha > 0, alpha < 255 else { return Int(raw) }
            return Int((Double(raw) * 255 / Double(alpha)).rounded())
        }
        return RGBA8(
            r: straight(capture.pixels[offset]),
            g: straight(capture.pixels[offset + 1]),
            b: straight(capture.pixels[offset + 2]),
            a: alpha)
    }

    static func expected(_ rgba: CanvasBackgroundRGBA) -> RGBA8 {
        let c = rgba.rgba8
        return RGBA8(r: c.r, g: c.g, b: c.b, a: c.a)
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    // MARK: - 1. Hierarchy

    static func checkHierarchy(_ world: World) throws {
        let subviews = world.canvas.subviews
        let backgroundIndex = subviews.firstIndex { $0 === world.renderer }
        let planeIndex = subviews.firstIndex { $0 === world.canvas.worldPlane }
        try expect(backgroundIndex != nil, "the background renderer is not a child of the canvas")
        try expect(planeIndex != nil, "the world plane is not a child of the canvas")
        try expect(backgroundIndex! < planeIndex!,
                   "the background is at index \(backgroundIndex!) and the world plane at \(planeIndex!) — it must be BELOW the plane")
        // It must be a SIBLING of the plane, not a descendant: anything inside the
        // plane inherits the camera, and the base/image must not.
        try expect(!world.renderer.isDescendant(of: world.canvas.worldPlane),
                   "the background renderer is inside the world plane — the base fill would move with the camera")
        try expect(world.canvas.subviews.filter { $0 is CanvasBackgroundRendererView }.count == 1,
                   "there is more than one background renderer on the canvas")

        // Hit-transparent everywhere, including dead centre.
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 400, y: 300), CGPoint(x: 799, y: 599)] {
            try expect(world.renderer.hitTest(point) == nil,
                       "the background claimed the click at \(point)")
        }
        try expect(!world.renderer.isAccessibilityElement(),
                   "the background renderer is an accessibility element — it is decoration")

        // No per-line/per-dot views or layers, at the densest configuration.
        world.apply(CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .dots,
            patternColor: .custom(gridColor), spacing: 8),
            viewport: CanvasViewport(x: 0, y: 0, zoom: 4))
        _ = try world.capture()
        try expect(world.renderer.qaSubviewCount == 0,
                   "the background grew \(world.renderer.qaSubviewCount) subview(s) — one view per primitive is the defect this forbids")
        let denseSublayers = world.renderer.qaSublayerCount
        try expect(world.renderer.qaLastRecord.pathCount == 1,
                   "a dot grid emitted \(world.renderer.qaLastRecord.pathCount) paths, must be exactly 1")
        try expect(world.renderer.qaLastRecord.dotCount > 100,
                   "the dense fixture only drew \(world.renderer.qaLastRecord.dotCount) dots — it is not dense, so the census proves nothing")

        // AppKit gives a layer-backed `draw(_:)` view exactly one content layer.
        // What must never happen is a layer PER PRIMITIVE, so the assertion is
        // that the count is small AND identical between the dense grid above and
        // an empty one — a bare count would pass a renderer that made a layer per
        // dot if it happened to be read while the grid was empty.
        world.apply(CanvasBackgroundConfiguration(base: .custom(baseColor), pattern: .solid),
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        _ = try world.capture()
        try expect(denseSublayers <= 1,
                   "the dense dot grid carried \(denseSublayers) sublayer(s)")
        try expect(world.renderer.qaSublayerCount == denseSublayers,
                   "sublayer count is \(world.renderer.qaSublayerCount) with no grid and \(denseSublayers) with \(world.renderer.qaLastRecord.dotCount) dots — a layer per primitive")
    }

    // MARK: - 2. Pattern pixels, both appearances

    static func checkPatternPixelsInBothAppearances(_ world: World) throws {
        let spacing = 100.0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for pattern in CanvasBackgroundPattern.allCases {
                let config = CanvasBackgroundConfiguration(
                    base: .custom(baseColor), pattern: pattern,
                    patternColor: .custom(gridColor), spacing: spacing)
                // Origin at zero: grid lines land exactly on multiples of 100.
                world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
                let rep = try world.capture(appearance: appearance)

                // The base is EXACT in both appearances. A token remap, a contrast
                // pass or an appearance rewrite would move it in one of them.
                let awayFromGrid = CGPoint(x: 150, y: 250)
                let sampled = try sample(rep, at: awayFromGrid)
                try expect(sampled.isNear(expected(baseColor)),
                           "\(appearance.rawValue)/\(pattern.rawValue): base pixel at \(awayFromGrid) is \(sampled), expected \(expected(baseColor)) — a custom colour must be exact in every appearance")

                let record = world.renderer.qaLastRecord
                switch pattern {
                case .solid:
                    try expect(record.pathCount == 0, "solid drew \(record.pathCount) pattern path(s)")
                    // Everything is the base, including where a grid would be.
                    for probe in [CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 200)] {
                        let value = try sample(rep, at: probe)
                        try expect(value.isNear(expected(baseColor)),
                                   "\(appearance.rawValue)/solid: \(probe) is \(value), a solid background must be uniform")
                    }
                case .lines, .dots:
                    try expect(record.pathCount == 1,
                               "\(pattern.rawValue) drew \(record.pathCount) pattern paths, must be exactly 1")
                    try expect(abs(record.strideScreen - spacing) < 1e-6,
                               "\(pattern.rawValue) stride is \(record.strideScreen), expected \(spacing)")
                    // The grid is where the pure maths says it is.
                    let gx = record.phaseX + record.strideScreen
                    let gy = record.phaseY + record.strideScreen
                    let onGrid = try sample(rep, at: CGPoint(x: gx, y: gy))
                    try expect(!onGrid.isNear(expected(baseColor), tolerance: 2),
                               "\(appearance.rawValue)/\(pattern.rawValue): the predicted grid point (\(gx), \(gy)) is \(onGrid) — the base colour. Nothing was drawn there.")
                    // Half a stride away is untouched base.
                    let offGrid = CGPoint(x: gx + record.strideScreen / 2, y: gy + record.strideScreen / 2)
                    let offValue = try sample(rep, at: offGrid)
                    try expect(offValue.isNear(expected(baseColor)),
                               "\(appearance.rawValue)/\(pattern.rawValue): \(offGrid) is \(offValue), expected untouched base between grid marks")
                }
            }
        }

        // The SYSTEM default really does differ between appearances — the control
        // that keeps "a custom colour is identical in both" meaningful.
        let systemConfig = CanvasBackgroundConfiguration(base: .systemDefault, pattern: .solid)
        world.apply(systemConfig, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        let light = try sample(try world.capture(appearance: .aqua), at: CGPoint(x: 400, y: 300))
        let dark = try sample(try world.capture(appearance: .darkAqua), at: CGPoint(x: 400, y: 300))
        try expect(!light.isNear(dark, tolerance: 20),
                   "the system-default base is \(light) in Aqua and \(dark) in Dark — it did not adapt, so the exactness assertions above are vacuous")
    }

    // MARK: - 3. Screen-fixed base/image vs world-aligned grid

    static func checkScreenFixedVersusWorldAligned(_ world: World) throws {
        let assetID = try world.store.importImage(data: try fixtureImageData(), fileExtension: "png")
        let config = CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .lines,
            patternColor: .custom(gridColor), spacing: 100,
            image: CanvasBackgroundImageSpec(assetID: assetID, opacity: .full, mode: .fit))
        world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        let before = try world.capture()
        let beforeRecord = world.renderer.qaLastRecord
        try expect(beforeRecord.imageDrawn,
                   "the fixture image never drew, so this comparison would be between two blank halves")

        // Sample INSIDE the fixture's distinctly coloured centre block, but
        // deliberately off the grid: the grid draws over the image, and probing a
        // point that a grid line happens to cross measures the grid, not the
        // image. The offset is asserted below rather than assumed.
        let imageCentre = CGPoint(x: beforeRecord.imageRect.midX - 45,
                                  y: beforeRecord.imageRect.midY - 45)
        let imageBefore = try sample(before, at: imageCentre)

        // A grid line that is genuinely on screen before the pan.
        let lineBefore = beforeRecord.phaseX + beforeRecord.strideScreen
        let onLineBefore = try sample(before, at: CGPoint(x: lineBefore, y: 300))
        try expect(!onLineBefore.isNear(expected(baseColor), tolerance: 2),
                   "no grid line at x=\(lineBefore) before the pan — the fixture is wrong")

        // Pan by a NON-multiple of the stride, and into NEGATIVE world space, so
        // both the phase change and the negative-coordinate path are exercised.
        let panned = CanvasViewport(x: -37, y: -23, zoom: 1)
        world.apply(config, viewport: panned)
        let after = try world.capture()
        let afterRecord = world.renderer.qaLastRecord

        try expect(clearOfGrid(beforeRecord, imageCentre) && clearOfGrid(afterRecord, imageCentre),
                   "the image probe at \(imageCentre) sits on a grid line in one of the two frames — it would measure the grid, not the image")
        try expect(afterRecord.imageRect == beforeRecord.imageRect,
                   "the image rect moved with the camera: \(beforeRecord.imageRect) -> \(afterRecord.imageRect). The image is SCREEN-FIXED.")
        let imageAfter = try sample(after, at: imageCentre)
        try expect(imageAfter.isNear(imageBefore, tolerance: 2),
                   "the image pixel at \(imageCentre) changed from \(imageBefore) to \(imageAfter) across a pan — it is not screen-fixed")
        let baseAfter = try sample(after, at: CGPoint(x: 4, y: 4))
        try expect(baseAfter.isNear(expected(baseColor)) || afterRecord.imageRect.contains(CGPoint(x: 4, y: 4)),
                   "the base fill at the corner changed across a pan: \(baseAfter)")

        // The GRID moved, by exactly the pan, and the old line position is now
        // background again. This is the positive control for the assertions above:
        // if the whole background were frozen they would pass and this would fail.
        try expect(afterRecord.phaseX != beforeRecord.phaseX,
                   "the grid phase did not change across a 37-unit pan — nothing moved, so 'the image did not move' proves nothing")
        let expectedPhaseX = CanvasBackgroundGeometry.positiveMod(37, afterRecord.strideScreen)
        try expect(abs(afterRecord.phaseX - expectedPhaseX) < 1e-6,
                   "phaseX after panning to world -37 is \(afterRecord.phaseX), the pure maths says \(expectedPhaseX)")
        try expect(afterRecord.firstWorldX <= 0,
                   "at world origin -37 the first visible grid line should be at or before 0, got \(afterRecord.firstWorldX)")

        let onLineAfter = try sample(after, at: CGPoint(x: lineBefore, y: 300))
        try expect(onLineAfter.isNear(expected(baseColor)) || !onLineBefore.isNear(onLineAfter, tolerance: 2),
                   "the grid line at x=\(lineBefore) is still there after the pan — the grid is screen-fixed, not world-aligned")

        // Returning to the original camera reproduces the original pixels exactly.
        world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        let returned = try world.capture()
        try expect(world.renderer.qaLastRecord.phaseX == beforeRecord.phaseX
                   && world.renderer.qaLastRecord.phaseY == beforeRecord.phaseY,
                   "returning to the original camera did not reproduce the original phase")
        for probe in [CGPoint(x: lineBefore, y: 300), imageCentre, CGPoint(x: 4, y: 4), CGPoint(x: 650, y: 550)] {
            let a = try sample(before, at: probe)
            let b = try sample(returned, at: probe)
            try expect(a.isNear(b, tolerance: 2), "returning the camera changed the pixel at \(probe): \(a) -> \(b)")
        }

        // ZOOM: the stride scales with the camera; the image rect does not.
        world.apply(config, viewport: CanvasViewport(x: -37, y: -23, zoom: 2))
        let zoomed = world.renderer.qaLastRecord
        try expect(abs(zoomed.strideScreen - beforeRecord.strideScreen * 2) < 1e-6
                   || zoomed.strideMultiplier != beforeRecord.strideMultiplier,
                   "zooming to 2x did not scale the screen stride: \(beforeRecord.strideScreen) -> \(zoomed.strideScreen)")
        try expect(zoomed.imageRect == beforeRecord.imageRect,
                   "the image rect changed with ZOOM: \(zoomed.imageRect)")
    }

    /// Is `point` far enough from every grid mark that a probe there reads the
    /// layer BELOW the grid?
    static func clearOfGrid(_ record: CanvasBackgroundRendererView.RenderRecord, _ point: CGPoint) -> Bool {
        guard record.strideScreen > 0 else { return true }
        func distance(_ value: Double, phase: Double) -> Double {
            let offset = CanvasBackgroundGeometry.positiveMod(value - phase, record.strideScreen)
            return min(offset, record.strideScreen - offset)
        }
        return distance(Double(point.x), phase: record.phaseX) > 5
            && distance(Double(point.y), phase: record.phaseY) > 5
    }

    // MARK: - 4. What a camera step costs

    static func checkCameraStepCosts(_ world: World) throws {
        let assetID = try world.store.importImage(data: try fixtureImageData(), fileExtension: "png")
        let config = CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .lines,
            patternColor: .custom(gridColor), spacing: 64,
            image: CanvasBackgroundImageSpec(assetID: assetID, opacity: .full, mode: .fill))
        world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        _ = try world.capture()
        try expect(world.renderer.qaLastRecord.imageDrawn,
                   "the image must be resident before the camera sweep, or 'zero decodes' just means 'nothing was ever needed'")

        // REAL TILES. Without them `tilesLaidOut == 0` is true of a canvas that
        // lays out everything it has — which is nothing — and the whole
        // "a background camera step costs no tile layout" claim is vacuous.
        for index in 0..<4 {
            let tile = Tile(
                id: UUID(), kind: .note, title: "ws7-\(index)",
                frame: TileFrame(x: Double(index) * 220, y: 120, width: 200, height: 160),
                zPosition: .fromLegacyRank(index), runtimeRef: nil, metadata: TileMetadata())
            world.canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }
        world.canvas.layoutSubtreeIfNeeded()
        try expect(world.canvas.qaTotalInstalledTileCount == 4,
                   "the fixture installed \(world.canvas.qaTotalInstalledTileCount) tiles, expected 4 — the layout counters below would measure an empty canvas")

        world.canvas.qaResetCameraLayoutStats()
        world.renderer.qaResetStats()
        world.renderer.imageCache.resetStats()
        let cacheEntriesBefore = world.renderer.imageCache.qaEntryCount
        let sublayersBefore = world.renderer.qaSublayerCount

        // 40 camera steps: a pan sweep that crosses the world origin and a zoom
        // sweep, i.e. everything a real gesture does.
        var steps: [CanvasViewport] = []
        for i in 0..<20 { steps.append(CanvasViewport(x: Double(i) * 13 - 130, y: Double(i) * -7 + 40, zoom: 1)) }
        for i in 0..<20 { steps.append(CanvasViewport(x: -55.5, y: 12.25, zoom: 0.4 + Double(i) * 0.12)) }
        for step in steps { world.canvas.setViewport(step) }
        world.canvas.layoutSubtreeIfNeeded()

        let stats = world.renderer.qaStats
        let cache = world.renderer.imageCache.stats
        let camera = world.canvas.qaCameraLayoutStats

        // POSITIVE CONTROL first: the sweep really did move the background.
        try expect(stats.cameraUpdates == steps.count,
                   "the canvas made \(stats.cameraUpdates) background camera updates for \(steps.count) viewport commits")
        try expect(stats.cameraInvalidations > 20,
                   "only \(stats.cameraInvalidations) of \(steps.count) camera steps invalidated the background — the zero-cost assertions below would be vacuous")

        // ...and cost nothing it must not cost.
        try expect(stats.imageRequests == 0,
                   "\(stats.imageRequests) image request(s) were issued during a camera sweep")
        try expect(cache.decodeRequests == 0, "\(cache.decodeRequests) decode(s) during a camera sweep")
        try expect(cache.cacheMisses == 0, "\(cache.cacheMisses) cache miss(es) during a camera sweep")
        try expect(cache.staleCompletionDrops == 0, "unexpected stale completions during a camera sweep")
        try expect(world.renderer.imageCache.qaEntryCount == cacheEntriesBefore,
                   "the image cache grew during a camera sweep: \(cacheEntriesBefore) -> \(world.renderer.imageCache.qaEntryCount)")
        try expect(camera.tilesLaidOut == 0, "\(camera.tilesLaidOut) tile layout(s) attributable to a background camera update")
        try expect(camera.frameWrites == 0, "\(camera.frameWrites) tile frame write(s) during a background camera sweep")
        try expect(camera.modelWrites == 0, "\(camera.modelWrites) model write(s) during a background camera sweep")
        try expect(world.canvas.qaDocumentRelationshipStats.frameWrites == 0,
                   "the relationship overlay was re-framed by a background camera update")
        try expect(world.renderer.qaSubviewCount == 0,
                   "the camera sweep created \(world.renderer.qaSubviewCount) subview(s) under the background")
        try expect(world.renderer.qaSublayerCount == sublayersBefore,
                   "the camera sweep changed the sublayer count from \(sublayersBefore) to \(world.renderer.qaSublayerCount)")

        // Primitives stay viewport-bounded at every step, including deep in
        // negative world space.
        for step in [CanvasViewport(x: -1e6, y: -1e6, zoom: 1), CanvasViewport(x: 1e6, y: 1e6, zoom: 0.05)] {
            world.canvas.setViewport(step)
            _ = try world.capture()
            let record = world.renderer.qaLastRecord
            let ceiling = CanvasBackgroundGeometry.maximumPrimitiveCount(
                viewportSize: canvasSize, strideScreen: record.strideScreen)
            try expect(record.lineCount <= ceiling,
                       "at world \(step.x) the renderer drew \(record.lineCount) lines, ceiling \(ceiling)")
            try expect(record.pathCount <= 1, "more than one pattern path at world \(step.x)")
        }

        // A RESIZE is allowed to decode (the target pixel size is part of the
        // key) — the counterpart that proves the zero above is not simply a dead
        // code path.
        world.renderer.imageCache.resetStats()
        world.renderer.qaResetStats()
        world.canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        world.canvas.layoutSubtreeIfNeeded()
        world.renderer.imageCache.qaDrainPendingDecodes()
        try expect(world.renderer.qaStats.imageRequests >= 1,
                   "a canvas resize issued no image request — the decode path is dead, so 'no decode on a camera step' means nothing")
        world.canvas.frame = CGRect(origin: .zero, size: canvasSize)
        world.canvas.layoutSubtreeIfNeeded()
        world.renderer.imageCache.qaDrainPendingDecodes()
    }

    // MARK: - 5. Image geometry and opacity

    static func checkImageGeometryAndOpacity(_ world: World) throws {
        let assetID = try world.store.importImage(data: try fixtureImageData(), fileExtension: "png")

        var fillRect = CGRect.zero
        var fitRect = CGRect.zero
        for mode in CanvasBackgroundImageMode.allCases {
            let config = CanvasBackgroundConfiguration(
                base: .custom(baseColor), pattern: .solid,
                spacing: 64,
                image: CanvasBackgroundImageSpec(assetID: assetID, opacity: .full, mode: mode))
            world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
            _ = try world.capture()
            let record = world.renderer.qaLastRecord
            try expect(record.imageDrawn, "\(mode.rawValue): the image did not draw")
            if mode == .fill { fillRect = record.imageRect } else { fitRect = record.imageRect }
        }
        try expect(fillRect.width >= canvasSize.width - 0.5 && fillRect.height >= canvasSize.height - 0.5,
                   "fill did not cover the canvas: \(fillRect)")
        try expect(fitRect.width <= canvasSize.width + 0.5 && fitRect.height <= canvasSize.height + 0.5,
                   "fit overflowed the canvas: \(fitRect)")
        try expect(fillRect != fitRect,
                   "fill and fit produced the same rect (\(fillRect)) — the fixture's aspect ratio matches the canvas, so this comparison is vacuous")

        // Fit letterboxes: the canvas corner is the BASE colour, not the image.
        let fitConfig = CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .solid, spacing: 64,
            image: CanvasBackgroundImageSpec(assetID: assetID, opacity: .full, mode: .fit))
        world.apply(fitConfig, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        let fitCapture = try world.capture()
        if fitRect.minY > 2 {
            let letterbox = try sample(fitCapture, at: CGPoint(x: 400, y: 1))
            try expect(letterbox.isNear(expected(baseColor)),
                       "the fit letterbox at the top is \(letterbox), expected the base colour")
        }

        // ORIENTATION. The four corner blocks are four different colours on
        // purpose: a vertically flipped draw (the default when a y-down view
        // hands a CGImage to a y-up `draw(_:in:)`) swaps top for bottom and the
        // centre-block probes below cannot see it, because the centre is
        // symmetric.
        let orientationConfig = CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .solid, spacing: 64,
            image: CanvasBackgroundImageSpec(assetID: assetID, opacity: .full, mode: .fit))
        world.apply(orientationConfig, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        let orientation = try world.capture()
        let rect = world.renderer.qaLastRecord.imageRect
        try expect(rect.width > 0, "the orientation scene drew no image")
        // Fractions of the fixture, top-down as a viewer sees it.
        let corners: [(String, Double, Double, RGBA8)] = [
            ("top-left", 0.05, 0.0889, RGBA8(r: 0, g: 0, b: 255, a: 255)),
            ("top-right", 0.95, 0.0889, RGBA8(r: 255, g: 255, b: 0, a: 255)),
            ("bottom-left", 0.05, 0.9111, RGBA8(r: 255, g: 0, b: 0, a: 255)),
            ("bottom-right", 0.95, 0.9111, RGBA8(r: 0, g: 255, b: 0, a: 255)),
        ]
        for (label, fx, fy, want) in corners {
            let probe = CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
            let got = try sample(orientation, at: probe)
            try expect(got.isNear(want, tolerance: 12),
                       "image orientation: the \(label) corner at \(probe) is \(got), expected \(want) — the image is mirrored or rotated")
        }

        // OPACITY. The fixture's centre is a known colour; at 0 it must be pure
        // base, at 1 pure image, and at .35 strictly between the two.
        var centreByOpacity: [CanvasBackgroundImageOpacity: RGBA8] = [:]
        for opacity in CanvasBackgroundImageOpacity.allCases {
            let config = CanvasBackgroundConfiguration(
                base: .custom(baseColor), pattern: .solid, spacing: 64,
                image: CanvasBackgroundImageSpec(assetID: assetID, opacity: opacity, mode: .fill))
            world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
            let rep = try world.capture()
            centreByOpacity[opacity] = try sample(rep, at: CGPoint(x: 400, y: 300))
            try expect(world.renderer.qaLastRecord.imageOpacity == opacity.value,
                       "the record says opacity \(world.renderer.qaLastRecord.imageOpacity) for \(opacity)")
            if opacity == .hidden {
                try expect(!world.renderer.qaLastRecord.imageDrawn,
                           "opacity 0 still drew the image — it must not even be composited")
            }
        }
        let hidden = centreByOpacity[.hidden]!
        let muted = centreByOpacity[.muted]!
        let full = centreByOpacity[.full]!
        try expect(hidden.isNear(expected(baseColor)),
                   "opacity 0 centre is \(hidden), expected the pure base colour \(expected(baseColor))")
        try expect(!full.isNear(hidden, tolerance: 8),
                   "opacity 1 centre is \(full), the same as with no image at all — the image never composited")
        // Strictly between, on the channel with the largest separation.
        let channelSpread = [abs(full.r - hidden.r), abs(full.g - hidden.g), abs(full.b - hidden.b)]
        let widest = channelSpread.firstIndex(of: channelSpread.max()!)!
        func channel(_ value: RGBA8) -> Int { [value.r, value.g, value.b][widest] }
        let low = min(channel(hidden), channel(full)), high = max(channel(hidden), channel(full))
        try expect(channel(muted) > low + 2 && channel(muted) < high - 2,
                   "opacity .35 centre channel \(channel(muted)) is not strictly between \(low) and \(high) — it is one of the endpoints, not a blend")
    }

    // MARK: - 6. Missing and corrupt assets

    static func checkMissingAndCorruptAsset(_ world: World) throws {
        // MISSING: a valid id whose managed file was never written.
        let missingID = CanvasBackgroundAssetID(digest: String(repeating: "e", count: 64), fileExtension: "png")!
        let config = CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .lines,
            patternColor: .custom(gridColor), spacing: 100,
            image: CanvasBackgroundImageSpec(assetID: missingID, opacity: .full, mode: .fill))
        world.apply(config, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        let missingCapture = try world.capture()
        var record = world.renderer.qaLastRecord
        try expect(!record.imageDrawn, "a missing asset drew something")
        try expect(record.fellBackToPattern, "a missing asset did not record the fallback")
        try expect(record.pathCount == 1, "the fallback lost the pattern: \(record.pathCount) path(s)")
        let missingBase = try sample(missingCapture, at: CGPoint(x: 150, y: 250))
        try expect(missingBase.isNear(expected(baseColor)),
                   "with a missing asset the base is \(missingBase), expected \(expected(baseColor))")
        let missingGrid = try sample(missingCapture, at: CGPoint(x: record.phaseX + record.strideScreen, y: 300))
        try expect(!missingGrid.isNear(expected(baseColor), tolerance: 2),
                   "with a missing asset the grid did not draw at the predicted position")
        try expect(world.renderer.qaStats.missingAssetWarnings >= 1, "no warning was raised for a missing asset")
        let warning = world.renderer.missingAssetWarning ?? ""
        try expect(!warning.isEmpty, "the missing-asset warning text is empty")
        try expect(!warning.contains("/") && !warning.contains(world.assetRoot.path),
                   "the missing-asset warning leaks a path: \(warning)")
        try expect(warning.contains(missingID.shortDescription),
                   "the warning does not identify which asset is missing: \(warning)")
        // The CONFIGURATION is untouched: a broken asset is not a reason to lose
        // the user's settings.
        try expect(world.renderer.currentConfiguration == config,
                   "a missing asset mutated the stored configuration")

        // CORRUPT: a managed file that exists but is not a decodable image.
        let corruptID = try world.store.importImage(data: Data(repeating: 0x5A, count: 4096), fileExtension: "png")
        let corruptConfig = CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .dots,
            patternColor: .custom(gridColor), spacing: 100,
            image: CanvasBackgroundImageSpec(assetID: corruptID, opacity: .full, mode: .fit))
        world.apply(corruptConfig, viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        world.renderer.imageCache.qaDrainPendingDecodes()
        let corruptCapture = try world.capture()
        record = world.renderer.qaLastRecord
        try expect(!record.imageDrawn, "a corrupt asset produced an image")
        try expect(record.pathCount == 1, "the corrupt fallback lost the dot pattern")
        let corruptBase = try sample(corruptCapture, at: CGPoint(x: 150, y: 250))
        try expect(corruptBase.isNear(expected(baseColor)),
                   "with a corrupt asset the base is \(corruptBase), expected \(expected(baseColor))")
        try expect(world.renderer.currentConfiguration == corruptConfig,
                   "a corrupt asset mutated the stored configuration")

        // RECOVERY: replacing the file with a real image brings the picture back,
        // which proves the fallback is a state and not a permanent latch.
        try Data(try fixtureImageData()).write(to: world.store.url(for: corruptID))
        world.renderer.imageCache.invalidateAll()
        world.renderer.requestImageIfNeeded()
        world.renderer.imageCache.qaDrainPendingDecodes()
        _ = try world.capture()
        try expect(world.renderer.qaLastRecord.imageDrawn,
                   "a repaired asset did not come back — the fallback latched")

        // STALE COMPLETIONS lose. Issue a request, then immediately supersede it.
        let secondID = try world.store.importImage(data: try fixtureImageData(alternate: true), fileExtension: "png")
        world.renderer.imageCache.invalidateAll()
        world.renderer.imageCache.resetStats()
        world.renderer.setConfiguration(CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .solid, spacing: 64,
            image: CanvasBackgroundImageSpec(assetID: corruptID, opacity: .full, mode: .fill)))
        world.renderer.setConfiguration(CanvasBackgroundConfiguration(
            base: .custom(baseColor), pattern: .solid, spacing: 64,
            image: CanvasBackgroundImageSpec(assetID: secondID, opacity: .full, mode: .fill)))
        world.renderer.imageCache.qaDrainPendingDecodes()
        _ = try world.capture()
        try expect(world.renderer.imageCache.stats.decodeRequests == 2,
                   "expected two decode requests, got \(world.renderer.imageCache.stats.decodeRequests)")
        try expect(world.renderer.imageCache.stats.staleCompletionDrops == 1,
                   "the superseded decode was not dropped: \(world.renderer.imageCache.stats.staleCompletionDrops) drop(s)")
        try expect(world.renderer.currentConfiguration.image?.assetID == secondID,
                   "the NEWEST asset is not the one in effect")
    }

    // MARK: - Deterministic fixture image

    /// The raw-pixel digests the fixture is pinned to. Regenerating one is a
    /// deliberate, committed change to what every pixel probe below samples.
    static let fixturePixelDigest = "a56083d5f306b50b445537b704adf44e43224be85e4fb2ce0e996760e9ed3c15"
    static let alternateFixturePixelDigest = "cd9653f1093ffebeb23410c49188b4074e441658c4ba7755727ce6b6c9206234"

    /// A 320x180 opaque sRGB PNG with four distinct corner blocks, a black
    /// border and a bright centre block. Generated rather than checked in so the
    /// witness has no binary dependency, and pinned by digest so it cannot drift.
    static func fixtureImageData(alternate: Bool = false) throws -> Data {
        // 16:9 ON PURPOSE, inside a 4:3 canvas: with a matching aspect ratio Fill
        // and Fit are the same rect and the geometry witness proves nothing.
        let width = 320, height = 180
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "could not create the fixture bitmap context")
        }
        func fill(_ rect: CGRect, _ components: [CGFloat]) {
            context.setFillColor(CGColor(colorSpace: space, components: components)!)
            context.fill(rect)
        }
        fill(CGRect(x: 0, y: 0, width: width, height: height), [0, 0, 0, 1])
        fill(CGRect(x: 2, y: 2, width: 316, height: 176), [1, 1, 1, 1])
        // FOUR DIFFERENT colours, so a mirrored or rotated draw is detectable.
        // This context is y-UP, so `y: 4` is the image's BOTTOM edge as a viewer
        // sees it: red bottom-left, green bottom-right, blue top-left, yellow
        // top-right. The orientation witness names them in viewer terms.
        fill(CGRect(x: 4, y: 4, width: 24, height: 24), [1, 0, 0, 1])
        fill(CGRect(x: 292, y: 4, width: 24, height: 24), [0, 1, 0, 1])
        fill(CGRect(x: 4, y: 152, width: 24, height: 24), [0, 0, 1, 1])
        fill(CGRect(x: 292, y: 152, width: 24, height: 24), [1, 1, 0, 1])
        // The centre block is what the opacity and screen-fixed probes sample.
        fill(CGRect(x: 128, y: 58, width: 64, height: 64), alternate ? [0, 0.9, 0.9, 1] : [0.9, 0, 0.9, 1])

        guard let image = context.makeImage() else {
            throw Failure(description: "could not render the fixture image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "could not encode the fixture PNG")
        }
        // The fixture is pinned by the RAW pixels, not by the encoded file: PNG
        // encoders are free to differ, the pixels this witness samples are not.
        let raw = context.data.map { Data(bytes: $0, count: width * height * 4) } ?? Data()
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        try expect(image.width == width && image.height == height,
                   "the fixture is \(image.width)x\(image.height), expected \(width)x\(height)")
        try expect(digest == (alternate ? alternateFixturePixelDigest : fixturePixelDigest),
                   "the fixture image drifted: raw-pixel SHA-256 is \(digest)")
        return data as Data
    }

    // MARK: - Contact sheet

    /// One PNG per scene, each drawn inside an explicit margin so a clipped or
    /// blank capture is visible AND asserted: the margin must be the margin
    /// colour on all four sides and the interior must contain more than one
    /// distinct colour.
    static func writeContactSheet(_ world: World) throws {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("canvas-background", isDirectory: true)
        } else {
            root = world.assetRoot.appendingPathComponent("captures", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let assetID = try world.store.importImage(data: try fixtureImageData(), fileExtension: "png")
        struct Scene { let name: String; let config: CanvasBackgroundConfiguration; let viewport: CanvasViewport }
        var scenes: [Scene] = []
        for pattern in CanvasBackgroundPattern.allCases {
            scenes.append(Scene(
                name: "custom-\(pattern.rawValue)",
                config: CanvasBackgroundConfiguration(
                    base: .custom(baseColor), pattern: pattern,
                    patternColor: .custom(gridColor), spacing: 100),
                viewport: CanvasViewport(x: -37, y: -23, zoom: 1)))
        }
        for mode in CanvasBackgroundImageMode.allCases {
            for opacity in CanvasBackgroundImageOpacity.allCases {
                scenes.append(Scene(
                    name: "image-\(mode.rawValue)-\(opacity.rawValue)",
                    config: CanvasBackgroundConfiguration(
                        base: .custom(baseColor), pattern: .lines,
                        patternColor: .custom(gridColor), spacing: 100,
                        image: CanvasBackgroundImageSpec(assetID: assetID, opacity: opacity, mode: mode)),
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1)))
            }
        }

        let margin: CGFloat = 24
        var written = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scene in scenes {
                world.apply(scene.config, viewport: scene.viewport)
                let rep = try world.capture(appearance: appearance)
                let framed = try frame(rep, margin: margin)
                let url = root.appendingPathComponent("\(scene.name).\(appearance.rawValue).png")
                try writePNG(framed, to: url)
                try assertFramedAndNonBlank(framed, margin: margin, name: url.lastPathComponent)
                written += 1
            }
        }
        try expect(written == scenes.count * 2,
                   "wrote \(written) captures, expected \(scenes.count * 2)")
        print("canvas-background-render: \(written) framed captures in \(root.path)")
    }

    /// Compose the capture into a larger canvas with a solid margin, so the
    /// image is provably complete rather than cropped at the edge.
    static let marginColor = RGBA8(r: 255, g: 0, b: 255, a: 255)

    static func frame(_ capture: Capture, margin: CGFloat) throws -> Capture {
        let scale = CGFloat(capture.width) / canvasSize.width
        let outWidth = Int(CGFloat(capture.width) + margin * 2 * scale)
        let outHeight = Int(CGFloat(capture.height) + margin * 2 * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                bytesPerRow: outWidth * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "could not create the framing context")
        }
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        context.draw(capture.image, in: CGRect(
            x: margin * scale, y: margin * scale,
            width: CGFloat(capture.width), height: CGFloat(capture.height)))
        guard let composed = context.makeImage(), let raw = context.data else {
            throw Failure(description: "could not compose the framed capture")
        }
        return Capture(width: outWidth, height: outHeight, bytesPerRow: context.bytesPerRow,
                       pixels: Data(bytes: raw, count: context.bytesPerRow * outHeight),
                       image: composed)
    }

    static func writePNG(_ capture: Capture, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "could not create a PNG destination for \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, capture.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "could not encode \(url.lastPathComponent)")
        }
        try (data as Data).write(to: url)
    }

    /// A written image is only evidence if it is COMPLETE. All four margins must
    /// still be the margin colour (nothing was cropped or offset), the margin
    /// colour must not appear inside (the render is not smaller than the canvas),
    /// and the interior must carry more than one colour (it is not blank).
    static func assertFramedAndNonBlank(_ capture: Capture, margin: CGFloat, name: String) throws {
        let scale = Double(capture.width) / Double(canvasSize.width + margin * 2)
        let inset = Int(Double(margin) * scale / 2)
        for (x, y) in [(inset, capture.height / 2), (capture.width - inset - 1, capture.height / 2),
                       (capture.width / 2, inset), (capture.width / 2, capture.height - inset - 1)] {
            let value = try pixel(capture, x: x, y: y)
            try expect(value.isNear(marginColor, tolerance: 4),
                       "\(name): the margin at (\(x), \(y)) is \(value), expected \(marginColor) — the capture is cropped or offset")
        }
        let interiorOrigin = Int(Double(margin) * scale)
        let interiorWidth = capture.width - interiorOrigin * 2
        let interiorHeight = capture.height - interiorOrigin * 2
        try expect(interiorWidth > 0 && interiorHeight > 0, "\(name): the framed capture has no interior")

        // The margin colour must not appear anywhere inside, i.e. the rendered
        // content really fills the frame.
        for i in 0..<12 {
            for j in 0..<12 {
                let x = interiorOrigin + interiorWidth * i / 12 + interiorWidth / 24
                let y = interiorOrigin + interiorHeight * j / 12 + interiorHeight / 24
                let value = try pixel(capture, x: x, y: y)
                try expect(!value.isNear(marginColor, tolerance: 4),
                           "\(name): the margin colour appears inside at (\(x), \(y)) — the render is smaller than the canvas")
            }
        }

        // Blankness is measured by SCANNING the interior, not by a sparse
        // lattice: a 12x12 lattice over a 100 pt grid can miss every line and
        // call a perfectly good render blank — which is a witness that fails for
        // the wrong reason and then gets weakened.
        var seen = Set<Int>()
        var scanned = 0
        var y = interiorOrigin
        while y < interiorOrigin + interiorHeight {
            var x = interiorOrigin
            while x < interiorOrigin + interiorWidth {
                let value = try pixel(capture, x: x, y: y)
                seen.insert(value.r << 16 | value.g << 8 | value.b)
                scanned += 1
                x += 3
            }
            y += 3
        }
        try expect(scanned > 10_000, "\(name): the blankness scan only read \(scanned) pixels")
        try expect(seen.count >= 2 || name.hasPrefix("custom-solid"),
                   "\(name): the interior is one flat colour across \(scanned) pixels — the capture is blank")
    }
}
