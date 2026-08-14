import AppKit
import ContinuumRevivedCore

/// Witnesses for the unified camera driver (`CanvasCameraDriver`).
///
/// Two legs, one file:
///
/// - `--canvas-camera-coalesce-check` — the Slice 2 contract from
///   .plans/22: N input events inside one display interval cause a BOUNDED
///   number of camera commits and preserve the final desired viewport. Before
///   the driver, every event was its own synchronous `setViewport`; the
///   control condition below reproduces that shape so the bound is measured
///   against a live counter, not assumed (the probe-check idiom: the
///   difference between two real paths IS the measurement).
///
/// - `--canvas-zoom-momentum-check` — the glide's mechanics, driven through
///   deterministic QA seams with an injected clock: a flick glides and
///   terminates, a deliberate stop does not glide, a new pinch or an external
///   viewport write (navigation snap, pointer drag) kills the glide, the zoom
///   clamp stops it early, and pan input COMPOSES with a live glide in one
///   commit instead of fighting it — the property whose absence was the
///   zoom→pan transition lag.
enum CanvasCameraDriverChecks {

    enum Failure: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self {
            case let .failed(message): return message
            }
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure.failed(message()) }
    }

    @MainActor
    private struct Harness {
        let canvas: CanvasNSView
        let window: NSWindow
    }

    @MainActor
    private static func makeHarness() -> Harness {
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

        for index in 0..<4 {
            let tile = Tile(
                id: UUID(), kind: .note, title: "driver-probe-\(index)",
                frame: TileFrame(x: Double(index % 2) * 340 + 20,
                                 y: Double(index / 2) * 260 + 20,
                                 width: 320, height: 240),
                zPosition: .fromLegacyRank(index + 1),
                runtimeRef: nil, metadata: TileMetadata()
            )
            let view = TileNSView(tile: tile)
            view.setContentView(NSView(frame: .zero))
            canvas.install(tileView: view, for: tile)
        }
        canvas.layoutSubtreeIfNeeded()
        return Harness(canvas: canvas, window: window)
    }

    @MainActor
    private static func teardown(_ harness: Harness) {
        harness.window.orderOut(nil)
        harness.window.contentView = nil
    }

    /// A precise (trackpad-shaped) scroll event through the REAL handler.
    /// `.pixel` units make `hasPreciseScrollingDeltas` true, so the canvas
    /// takes the same branch a trackpad drives.
    private static func preciseScrollEvent(dy: Int32) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: dy, wheel2: 0, wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cgEvent)
    }

    // MARK: - Leg 1: N inputs, bounded commits

    @MainActor
    static func runCoalesce() throws {
        let harness = makeHarness()
        defer { teardown(harness) }
        let canvas = harness.canvas
        let driver = canvas.cameraDriver

        // Deterministic time: every event below lands "inside one display
        // interval" because the clock does not move between them.
        var fakeNow: TimeInterval = 1_000
        driver.nowProvider = { fakeNow }

        // Control — the pre-driver shape: N externally-driven setViewport calls
        // are N applies. Proves the counter counts every apply, so the bound
        // below cannot be met by a counter that stopped counting.
        let controlBefore = canvas.qaViewportApplyCount
        for step in 1...6 {
            canvas.setViewport(CanvasViewport(x: Double(step), y: 0, zoom: 1))
        }
        let controlApplies = canvas.qaViewportApplyCount - controlBefore
        try expect(controlApplies == 6, "control: 6 direct setViewport calls must count 6 applies; got \(controlApplies)")

        // Driven — 6 precise scroll-pan events through the real scrollWheel
        // handler inside one interval: the first applies immediately (latency
        // is preserved for sparse input), the rest accumulate, and the next
        // display tick applies the composed remainder once.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        let yBefore = canvas.viewport.y
        let appliesBefore = canvas.qaViewportApplyCount
        var deltaSum = 0.0
        for _ in 1...6 {
            guard let event = preciseScrollEvent(dy: 10) else {
                throw Failure.failed("could not synthesize a precise scroll event")
            }
            deltaSum += Double(event.scrollingDeltaY)
            canvas.scrollWheel(with: event)
        }
        fakeNow += 0.02
        driver.qaFlushPending()
        let drivenApplies = canvas.qaViewportApplyCount - appliesBefore

        try expect(drivenApplies >= 1, "teeth: the events must move the camera at all; got 0 applies")
        try expect(drivenApplies <= 2, "6 events in one display interval must cost at most 2 applies (leading edge + one coalesced flush); got \(drivenApplies)")
        try expect(!driver.qaHasPendingInput, "nothing may strand in the accumulator after the flush")
        // Final-viewport preservation: coalescing must compose deltas, not drop
        // them — the end state equals what 6 per-event applies would have built.
        let expectedY = yBefore - deltaSum / canvas.viewport.zoom
        try expect(abs(canvas.viewport.y - expectedY) < 0.001,
                   "final viewport must equal the composition of all 6 deltas: expected y \(expectedY), got \(canvas.viewport.y)")

        print("canvas camera coalesce — control \(controlApplies) applies for 6 direct calls; driven \(drivenApplies) applies for 6 events in one interval, final viewport preserved")
    }

    // MARK: - Leg 2: glide mechanics

    @MainActor
    static func runMomentum() throws {
        let harness = makeHarness()
        defer { teardown(harness) }
        let canvas = harness.canvas
        let driver = canvas.cameraDriver

        var fakeNow: TimeInterval = 2_000
        driver.nowProvider = { fakeNow }

        /// A brisk pinch: 10 changed events of +2% magnification 8 ms apart.
        /// Log velocity ≈ log(1.02)/0.008 ≈ 2.5 — far above the engage
        /// threshold, like a real flick.
        func flick(at start: TimeInterval) {
            driver.notePinch(magnification: 0, phase: .began, location: CGPoint(x: 700, y: 450), timestamp: start)
            for step in 1...10 {
                driver.notePinch(magnification: 0.02, phase: .changed,
                                 location: CGPoint(x: 700, y: 450),
                                 timestamp: start + Double(step) * 0.008)
            }
            driver.notePinch(magnification: 0, phase: .ended, location: CGPoint(x: 700, y: 450), timestamp: start + 0.088)
        }

        // 1. A flick glides, advances the zoom without further input, and terminates.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        flick(at: fakeNow)
        try expect(driver.qaGlideActive, "a flick above the engage threshold must start a glide")
        driver.qaFlushPending()
        let zoomAtRelease = canvas.viewport.zoom
        try expect(zoomAtRelease > 1, "teeth: the pinch itself must have zoomed the camera; still at \(canvas.viewport.zoom)")
        var glideSteps = 0
        while driver.qaGlideActive, glideSteps < 500 {
            fakeNow += 1.0 / 120.0
            driver.qaStepGlide(dt: 1.0 / 120.0)
            glideSteps += 1
        }
        try expect(!driver.qaGlideActive, "the glide must terminate on its own; still active after \(glideSteps) steps")
        try expect(canvas.viewport.zoom > zoomAtRelease,
                   "the glide must carry the zoom past the release point: released at \(zoomAtRelease), ended at \(canvas.viewport.zoom)")

        // 2. A deliberate stop does not glide: slow final movement, velocity
        // below the engage threshold.
        driver.notePinch(magnification: 0, phase: .began, location: .zero, timestamp: fakeNow)
        for step in 1...5 {
            driver.notePinch(magnification: 0.001, phase: .changed, location: .zero,
                             timestamp: fakeNow + Double(step) * 0.05)
        }
        driver.notePinch(magnification: 0, phase: .ended, location: .zero, timestamp: fakeNow + 0.3)
        try expect(!driver.qaGlideActive, "a deliberate stop (velocity below threshold) must not glide")
        driver.qaFlushPending()

        // 3. A new pinch takes the camera: the old glide dies at .began.
        flick(at: fakeNow + 1)
        try expect(driver.qaGlideActive, "setup: glide running")
        driver.notePinch(magnification: 0, phase: .began, location: .zero, timestamp: fakeNow + 2)
        try expect(!driver.qaGlideActive, "a new pinch .began must cancel the running glide")
        driver.notePinch(magnification: 0, phase: .cancelled, location: .zero, timestamp: fakeNow + 2.01)
        driver.qaFlushPending()

        // 4. An external viewport write (navigation snap, pointer drag, restore)
        // owns the camera: the glide must not keep steering it.
        flick(at: fakeNow + 3)
        try expect(driver.qaGlideActive, "setup: glide running")
        canvas.setViewport(CanvasViewport(x: 40, y: 40, zoom: 1))
        try expect(!driver.qaGlideActive, "an external setViewport must cancel the glide")
        try expect(!driver.qaHasPendingInput, "an external setViewport must drop accumulated gesture input")

        // 5. Pan input COMPOSES with a live glide — one commit moves both axes.
        // This is the unification property itself: before the driver, the glide
        // zoomed around a frozen anchor while the pan fought it write for write.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        flick(at: fakeNow + 4)
        try expect(driver.qaGlideActive, "setup: glide running")
        driver.qaFlushPending()
        let composeXBefore = canvas.viewport.x
        let composeZoomBefore = canvas.viewport.zoom
        driver.noteScrollPan(dx: 30, dy: 0, location: CGPoint(x: 700, y: 450))
        try expect(driver.qaGlideActive, "pan input must compose with the glide, not cancel it")
        let composeApplies = canvas.qaViewportApplyCount
        fakeNow += 1.0 / 120.0
        driver.qaStepGlide(dt: 1.0 / 120.0)
        try expect(canvas.qaViewportApplyCount - composeApplies == 1,
                   "pan and glide must land in ONE commit; got \(canvas.qaViewportApplyCount - composeApplies)")
        try expect(canvas.viewport.x != composeXBefore, "the composed commit must include the pan")
        try expect(canvas.viewport.zoom > composeZoomBefore, "the composed commit must include the glide's zoom")
        driver.qaMarkSettledNow()

        // 6. The zoom clamp stops the glide early instead of ticking a pinned
        // camera down to the velocity floor (decay alone needs ~45 steps here).
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 3.95))
        flick(at: fakeNow + 5)
        try expect(driver.qaGlideActive, "setup: glide running toward the clamp")
        var clampSteps = 0
        while driver.qaGlideActive, clampSteps < 60 {
            fakeNow += 1.0 / 120.0
            driver.qaStepGlide(dt: 1.0 / 120.0)
            clampSteps += 1
        }
        try expect(!driver.qaGlideActive, "the glide must stop at the clamp; still active after \(clampSteps) steps")
        try expect(clampSteps < 10, "the clamp must stop the glide early, not the velocity floor (decay alone takes ~45 steps); took \(clampSteps)")
        try expect(abs(canvas.viewport.zoom - CanvasEngine.defaultZoomRange.upperBound) < 0.001,
                   "the camera must rest at the clamp; got \(canvas.viewport.zoom)")

        // 7. Session stickiness: zoom input holds the camera session open so a
        // pinch→pan handoff over tile content keeps steering the camera; it
        // expires so a later deliberate tile scroll is the tile's again.
        try expect(driver.isCameraSessionActive, "just after zoom input the camera session must be active")
        fakeNow += driver.tuning.stickiness + 0.01
        try expect(!driver.isCameraSessionActive, "the session must expire \(driver.tuning.stickiness)s after the last zoom input")

        print("canvas zoom momentum — flick glided \(glideSteps) steps and terminated; deliberate stop stayed dead; pinch/.began and external writes cancel; pan composed in one commit; clamp stopped the glide in \(clampSteps) steps; stickiness expires")
    }
}
