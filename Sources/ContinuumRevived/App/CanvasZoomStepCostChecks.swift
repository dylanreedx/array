import AppKit
import ContinuumRevivedCore
import Foundation
import ObjectiveC

/// What does ONE zoom step make AppKit and Core Animation redo?
///
/// The zoom profile (`.plans/110-native-refresh-inventory/rescued-profiling/zoom-profile.md`)
/// puts 78% of the main thread inside the CA commit after each camera step:
/// layers repainting, views laying out, scroll views retiling, tracking areas
/// rebuilt. Array's own camera code is cheap; AppKit's reaction to a world-plane
/// bounds-size change is not.
///
/// This check builds the motion probe's real scene (`CanvasMotionWorkload`, the
/// production boot mount, 24 Markdown + 8 agents) in an OFF-SCREEN window that is
/// never activated, drives zoom through the production camera driver entry
/// (`noteScrollZoom`, what `CanvasNSView.scrollWheel` calls for Cmd-scroll), and
/// lets the ordinary main run loop run the display cycle and the CA commit. A
/// sample of this process during the zoom has the same shape as the release
/// profile of the visible probe (commit 73% vs 78%, repaint 32% vs 43%,
/// `setBoundsSize` 14% vs 18%, backing cascade 10% vs 11%).
///
/// It counts per camera step, by class: layer repaints (`-[CALayer display]`),
/// view layouts (`-[NSView layout]`), scroll view retiles (`-[NSScrollView tile]`)
/// and clip-view geometry writes. Counting needs the ObjC runtime: the counted
/// methods are AppKit's and CA's, and a hook on them is the only way to see work
/// AppKit does on its own. The hooks are installed only inside this process.
///
/// Witnesses (the default run):
///
/// 1. **No pixel-grid retile while the camera moves.** A zoom step moves the
///    device-pixel grid, and AppKit retiles every scroll view to re-snap its clip
///    view to it: a fraction-of-a-point nudge that reflows the document and the
///    scrollers. Before the fix, 128 code-block retiles per step in four visible
///    Markdown tiles. `CodeBlockScrollView.tile` now defers those to the settle.
/// 2. **No sub-pixel clip re-snap while the camera moves.** The backing cascade
///    also re-snaps each clip view's bounds origin by under a device pixel per step
///    (128 per step before the fix); `CodeBlockClipView` defers those to the settle.
/// 3. **Everything deferred is released at the settle.** Nothing may stay waiting
///    once the camera rests. (Retiling or re-applying clip bounds at rest then moves
///    nothing; those clauses are guards only: both also held with the whole settle
///    flush removed, so they are not what proves the settle runs.)
///
/// Gated on `--canvas-zoom-step-cost-check`. Diagnosis, never in the matrix:
/// `CANVAS_ZOOM_STEP_COST_REPORT=1` prints the per-class table and the
/// throughput (camera states per second at 120 Hz input);
/// `CANVAS_ZOOM_STEP_COST_NO_HOOKS=1` times without the hooks.
@MainActor
enum CanvasZoomStepCostChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Per-class tallies, written by the hooked methods while `counting`.
    nonisolated(unsafe) static var counting = false
    nonisolated(unsafe) static var displays: [String: Int] = [:]
    nonisolated(unsafe) static var layouts: [String: Int] = [:]
    nonisolated(unsafe) static var tileRequests: [String: Int] = [:]
    nonisolated(unsafe) static var tiles: [String: Int] = [:]
    /// The witnessed code blocks' tile inputs at their previous real retile during
    /// the gesture (nil until one is seen: the view's last retile before the gesture
    /// is unknown here). A retile with its inputs unchanged since then only
    /// re-snaps to the moving pixel grid.
    nonisolated(unsafe) static var gestureStartGeometry: [ObjectIdentifier: [CGFloat]?] = [:]
    nonisolated(unsafe) static var gridOnlyRetiles = 0
    nonisolated(unsafe) static var subPixelClipResnaps = 0
    nonisolated(unsafe) static var clipOriginRequests = 0

    static func geometry(_ scroll: NSScrollView) -> [CGFloat] {
        let document = scroll.documentView?.frame.size ?? .zero
        let insets = scroll.contentInsets
        return [scroll.bounds.width, scroll.bounds.height, document.width, document.height,
                insets.top, insets.left, insets.bottom, insets.right,
                CGFloat(scroll.scrollerStyle.rawValue), scroll.hasHorizontalScroller ? 1 : 0,
                scroll.hasVerticalScroller ? 1 : 0, scroll.autohidesScrollers ? 1 : 0]
    }
    nonisolated(unsafe) static var clipOriginWrites = 0
    nonisolated(unsafe) static var clipSizeWrites = 0

    static func reset() {
        displays = [:]; layouts = [:]; tileRequests = [:]; tiles = [:]; gridOnlyRetiles = 0; subPixelClipResnaps = 0; clipOriginRequests = 0
        clipOriginWrites = 0; clipSizeWrites = 0
    }

    static func name(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: type(of: object))
    }

    /// Replace `selector` on `cls` itself; an inherited method gets an override on
    /// `cls` that calls the inherited implementation.
    private static func hook(_ cls: AnyClass, _ selector: Selector, _ block: (IMP) -> Any) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let original = method_getImplementation(method)
        let replacement = imp_implementationWithBlock(block(original))
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }

    private static var installed = false
    static func installHooks() {
        guard !installed else { return }
        installed = true
        typealias VoidIMP = @convention(c) (AnyObject, Selector) -> Void
        typealias PointIMP = @convention(c) (AnyObject, Selector, NSPoint) -> Void
        typealias SizeIMP = @convention(c) (AnyObject, Selector, NSSize) -> Void

        // A layer subclass is hooked only where it has its OWN `display`, so an
        // inherited implementation is never counted twice. Subclasses first: their
        // inherited-implementation test must see CALayer's original.
        let displaySel = #selector(CALayer.display)
        let ownDisplay: [AnyClass] = ["_NSViewBackingLayer", "NSViewBackingLayer"]
            .compactMap { NSClassFromString($0) }
            .filter { cls in
                guard let superclass = class_getSuperclass(cls),
                      let mine = class_getInstanceMethod(cls, displaySel),
                      let theirs = class_getInstanceMethod(superclass, displaySel) else { return false }
                return method_getImplementation(mine) != method_getImplementation(theirs)
            }
        for cls in ownDisplay + [CALayer.self] {
            hook(cls, displaySel) { original in
                let block: @convention(block) (CALayer) -> Void = { layer in
                    if counting { displays[layer.delegate.map { name($0) } ?? "layer:" + name(layer), default: 0] += 1 }
                    unsafeBitCast(original, to: VoidIMP.self)(layer, displaySel)
                }
                return block
            }
        }
        let layoutSel = #selector(NSView.layout)
        hook(NSView.self, layoutSel) { original in
            let block: @convention(block) (NSView) -> Void = { view in
                if counting { layouts[name(view), default: 0] += 1 }
                unsafeBitCast(original, to: VoidIMP.self)(view, layoutSel)
            }
            return block
        }
        // Requests reach the subclass's own override; real retiles reach
        // NSScrollView's implementation.
        let tileSel = #selector(NSScrollView.tile)
        hook(CodeBlockScrollView.self, tileSel) { original in
            let block: @convention(block) (NSScrollView) -> Void = { scroll in
                if counting { tileRequests[name(scroll), default: 0] += 1 }
                unsafeBitCast(original, to: VoidIMP.self)(scroll, tileSel)
            }
            return block
        }
        hook(NSScrollView.self, tileSel) { original in
            let block: @convention(block) (NSScrollView) -> Void = { scroll in
                if counting {
                    tiles[name(scroll), default: 0] += 1
                    let id = ObjectIdentifier(scroll)
                    if let previous = gestureStartGeometry[id] {
                        let now = geometry(scroll)
                        if let previous, now == previous,
                           CanvasNSView.enclosing(scroll)?.defersPixelGridRetile == true {
                            gridOnlyRetiles += 1
                        }
                        gestureStartGeometry[id] = .some(now)
                    }
                }
                unsafeBitCast(original, to: VoidIMP.self)(scroll, tileSel)
            }
            return block
        }
        let sizeSel = #selector(NSView.setFrameSize(_:))
        hook(NSClipView.self, sizeSel) { original in
            let block: @convention(block) (NSClipView, NSSize) -> Void = { clip, size in
                if counting { clipSizeWrites += 1 }
                unsafeBitCast(original, to: SizeIMP.self)(clip, sizeSel, size)
            }
            return block
        }
        let originSel = #selector(NSView.setBoundsOrigin(_:))
        hook(CodeBlockClipView.self, originSel) { original in
            let block: @convention(block) (NSClipView, NSPoint) -> Void = { clip, point in
                if counting { clipOriginRequests += 1 }
                unsafeBitCast(original, to: PointIMP.self)(clip, originSel, point)
            }
            return block
        }
        hook(NSClipView.self, originSel) { original in
            let block: @convention(block) (NSClipView, NSPoint) -> Void = { clip, point in
                if counting {
                    clipOriginWrites += 1
                    if let scroll = clip.superview as? NSScrollView,
                       gestureStartGeometry[ObjectIdentifier(scroll)] != nil, point != clip.bounds.origin,
                       CanvasNSView.enclosing(clip)?.defersPixelGridRetile == true {
                        let pixel = clip.convertFromBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).size
                        if abs(point.x - clip.bounds.origin.x) < abs(pixel.width),
                           abs(point.y - clip.bounds.origin.y) < abs(pixel.height) {
                            subPixelClipResnaps += 1
                        }
                    }
                }
                unsafeBitCast(original, to: PointIMP.self)(clip, originSel, point)
            }
            return block
        }
    }

    struct Tally {
        var steps = 0
        var milliseconds = 0.0
        var displays: [String: Int] = [:]
        var layouts: [String: Int] = [:]
        var tileRequests: [String: Int] = [:]
        var tiles: [String: Int] = [:]
        var clipOriginWrites = 0
        var clipSizeWrites = 0

        func perStep(_ value: Int) -> Double { Double(value) / Double(max(1, steps)) }
        static func total(_ table: [String: Int]) -> Int { table.values.reduce(0, +) }
    }

    /// Yield to the ordinary main run loop. A nested `RunLoop.run` would not drain
    /// the main dispatch queue from inside this main-actor job, so deferred work
    /// (the settle, far-parking passes) would silently never run.
    static func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    /// Zoom input at 120 Hz, as the motion probe posts it. The driver paces its
    /// commits from completion, so `steps` is camera states actually applied.
    static func measure(_ canvas: CanvasNSView, posts: Int, factor: (Int) -> Double) async -> Tally {
        let before = canvas.qaViewportApplyCount
        let anchor = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        reset()
        let start = ProcessInfo.processInfo.systemUptime
        counting = true
        for index in 0..<posts {
            canvas.cameraDriver.noteScrollZoom(
                deltaY: log(factor(index)) / canvas.cameraDriver.tuning.scrollZoomGain, location: anchor)
            await spin(1.0 / 120)
        }
        counting = false
        return Tally(steps: canvas.qaViewportApplyCount - before,
                     milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                     displays: displays, layouts: layouts, tileRequests: tileRequests, tiles: tiles,
                     clipOriginWrites: clipOriginWrites, clipSizeWrites: clipSizeWrites)
    }

    static func report(_ tally: Tally) {
        let f = { (value: Double) in String(format: "%.1f", value) }
        print("[zoom-step-cost] steps=\(tally.steps) statesPerSecond=\(f(Double(tally.steps) / (tally.milliseconds / 1_000))) "
              + "msPerState=\(f(tally.milliseconds / Double(max(1, tally.steps)))) "
              + "displays/step=\(f(tally.perStep(Tally.total(tally.displays)))) "
              + "layouts/step=\(f(tally.perStep(Tally.total(tally.layouts)))) "
              + "scrollTiles/step=\(f(tally.perStep(Tally.total(tally.tiles)))) "
              + "clipSizeWrites/step=\(f(tally.perStep(tally.clipSizeWrites))) "
              + "clipOriginWrites/step=\(f(tally.perStep(tally.clipOriginWrites)))")
        guard ProcessInfo.processInfo.environment["CANVAS_ZOOM_STEP_COST_REPORT"] == "1" else { return }
        for (title, table) in [("tile", tally.tiles), ("display", tally.displays), ("layout", tally.layouts)] {
            for (key, count) in table.sorted(by: { $0.value > $1.value }).prefix(30) {
                print(String(format: "  %@ %8.2f/step  %@", title, tally.perStep(count), key))
            }
        }
    }

    static func codeBlockScrollViews(in canvas: CanvasNSView) -> [CodeBlockScrollView] {
        var found: [CodeBlockScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? CodeBlockScrollView { found.append(scroll) }
            for child in view.subviews { walk(child) }
        }
        for tile in canvas.visibleTileViews { walk(tile) }
        return found
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["CONTINUUM_PROJECT_ROOT"], let supportPath = env["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "requires isolated CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT")
        }
        let fixture = try CanvasMotionWorkload(root: URL(fileURLWithPath: rootPath),
            support: URL(fileURLWithPath: supportPath), markdownCount: 24, agentCount: 8, offscreen: true)
        defer { fixture.close() }
        let canvas = fixture.canvas
        let hooks = env["CANVAS_ZOOM_STEP_COST_NO_HOOKS"] != "1"
        if hooks { installHooks() }
        // The boot mount's far-parking passes park the 24 off-view tiles' bodies,
        // as in the probe after its warmup and in any settled app.
        await spin(Double(env["CANVAS_ZOOM_STEP_COST_WARMUP"] ?? "") ?? 3)
        var parked = -1
        let parkDeadline = ProcessInfo.processInfo.systemUptime + 30
        while canvas.qaFarParkedTileCount != parked, ProcessInfo.processInfo.systemUptime < parkDeadline {
            parked = canvas.qaFarParkedTileCount
            await spin(1)
        }
        print("[zoom-step-cost] scene: tiles=\(canvas.tileViewsInVisualOrder.count) "
              + "visible=\(canvas.visibleTileViews.count) farParked=\(canvas.qaFarParkedTileCount) zoom=\(canvas.viewport.zoom)")

        if env["CANVAS_ZOOM_STEP_COST_REPORT"] == "1" || !hooks {
            // Diagnosis: the probe's shape, in and out around the start zoom.
            let posts = Int(env["CANVAS_ZOOM_STEP_COST_STEPS"] ?? "") ?? 240
            // A profiler attaches here, after warmup and parking.
            print("[zoom-step-cost] zoom phase starts pid=\(getpid())"); fflush(stdout)
            report(await measure(canvas, posts: posts) { ($0 / 8) % 2 == 0 ? 1.03 : 1 / 1.03 })
            return
        }

        let codeBlocks = codeBlockScrollViews(in: canvas)
        guard codeBlocks.count >= 32 else {
            throw Failure(description: "positive control: expected the visible Markdown tiles' code blocks, found \(codeBlocks.count)")
        }
        gestureStartGeometry = Dictionary(uniqueKeysWithValues: codeBlocks.map { (ObjectIdentifier($0), nil) })
        let startZoom = canvas.viewport.zoom
        // Zoom IN only, so the gesture ends on a different pixel grid than it began.
        let motion = await measure(canvas, posts: 24) { _ in 1.03 }
        report(motion)
        guard motion.steps >= 6, canvas.viewport.zoom > startZoom * 1.1 else {
            throw Failure(description: "the camera did not zoom: \(motion.steps) states, zoom \(startZoom) -> \(canvas.viewport.zoom)")
        }
        let requests = motion.tileRequests["CodeBlockScrollView", default: 0]
        guard requests >= motion.steps * 32 else {
            throw Failure(description: "positive control: AppKit asked code blocks to retile \(requests) times in \(motion.steps) steps; the scenario no longer moves the pixel grid")
        }
        // A code block mounted or resized mid-gesture tiles, as it must (its text
        // view's document also drifts by fractions of a point with the zoom), and
        // so does any after a settle; the defect is a retile whose own geometry
        // did not change since its previous retile while the gesture was moving.
        let resnaps = gridOnlyRetiles
        guard resnaps == 0 else {
            throw Failure(description: "code blocks re-snapped to the moving pixel grid \(resnaps) times in \(motion.steps) zoom steps (\(String(format: "%.1f", motion.perStep(resnaps)))/step) with their own geometry unchanged; they must wait for the settle")
        }

        guard clipOriginRequests >= motion.steps * 32 else {
            throw Failure(description: "positive control: AppKit re-snapped code-block clips \(clipOriginRequests) times in \(motion.steps) steps; the scenario no longer moves the pixel grid")
        }
        guard subPixelClipResnaps == 0 else {
            throw Failure(description: "code-block clip views re-snapped their origin by under a device pixel \(subPixelClipResnaps) times in \(motion.steps) zoom steps (\(String(format: "%.1f", motion.perStep(subPixelClipResnaps)))/step); they must wait for the settle")
        }

        // Settle, then the resting witness.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while canvas.isCameraInMotion, ProcessInfo.processInfo.systemUptime < deadline { await spin(0.05) }
        await spin(0.3)
        guard !canvas.isCameraInMotion else { throw Failure(description: "the camera never settled") }
        guard canvas.qaDeferredPixelGridRetileCount == 0 else {
            throw Failure(description: "\(canvas.qaDeferredPixelGridRetileCount) deferred retiles survived the settle")
        }
        // Guard: re-applying a clip's bounds at rest (the call the backing cascade
        // makes, which snaps to device pixels) moves nothing.
        let offGrid = codeBlockScrollViews(in: canvas).filter { scroll in
            let clip = scroll.contentView
            let before = clip.bounds.origin
            clip.bounds = clip.bounds
            return abs(before.x - clip.bounds.origin.x) > 1e-6 || abs(before.y - clip.bounds.origin.y) > 1e-6
        }.count
        guard offGrid == 0 else {
            throw Failure(description: "\(offGrid) code-block clips were off the resting pixel grid after the settle")
        }
        var moved = 0
        for scroll in codeBlockScrollViews(in: canvas) {
            let clip = scroll.contentView
            let before = (clip.frame, clip.bounds)
            scroll.tile()
            let after = (clip.frame, clip.bounds)
            func same(_ a: CGRect, _ b: CGRect) -> Bool {
                abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6
                    && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
            }
            if !same(before.0, after.0) || !same(before.1, after.1) { moved += 1 }
        }
        guard moved == 0 else {
            throw Failure(description: "\(moved) code blocks changed geometry when retiled at rest")
        }
        print("[zoom-step-cost] \(motion.steps) zoom steps: \(requests) code-block retile requests deferred, 0 grid-only re-snaps; \(clipOriginRequests) sub-pixel clip re-snaps deferred, 0 reached AppKit; "
              + "every deferred retile ran at settle")
    }
}
