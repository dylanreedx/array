import AppKit
import ContinuumRevivedCore
import Foundation

/// Does surface residency actually hold its promises in PRODUCTION code?
///
/// `canvas.surface-host-slope` measured the mechanism on a probe fixture: a flat
/// surface body takes a camera step from 140 ms to 0.19 ms at 50 real agent tiles,
/// and a real body parked outside the world plane keeps streaming for free. This
/// check is the production counterpart, and its subject is not the speed — it is
/// the requirement the speed has to survive: **a user must not be able to tell.**
///
/// So the gates here are mostly about indistinguishability, not cost:
///
/// - at rest, nothing is surfaced, so cursor rects, selection, IME, tooltips, the
///   accessibility tree and every consumer that walks the view hierarchy see
///   exactly what they see today;
/// - a surfaced body's pixels match the real body's;
/// - a surface less sharp than the screen needs is REFUSED rather than shown;
/// - a click during the settle window reaches the real body;
/// - streaming continues while surfaced;
/// - nothing is stranded in the park when tiles or projects leave.
///
/// Every transition runs through real production paths: `noteScrollZoom` ->
/// `noteActivity` -> `onActivityBegin`, and `qaMarkSettledNow` -> `markSettled` ->
/// `onSettle`. The harness computes no geometry and swaps no views itself.
///
/// Gated on `--tile-surface-residency-check`.
@MainActor
enum TileSurfaceResidencyChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    /// A real canvas, real agent tiles, and the real camera driver on an injected
    /// clock. Deliberately the same fixture shape as
    /// `PerfScenarios.canvasSurfaceHostSlope`, so a number measured there and a
    /// behaviour asserted here are talking about the same thing.
    @MainActor
    private final class World {
        let canvas: CanvasNSView
        let window: NSWindow
        let layer: CanvasNSView.ZoneLayer
        let tiles: [Tile]
        var agentViews: [UUID: ManagedAgentTileNSView] = [:]
        private let clock = Clock()
        private let zoomGain: Double
        private let commitGap: TimeInterval

        final class Clock { var now: TimeInterval = 1_000 }

        init(
            tileCount: Int, turns: Int = 4,
            viewportSize: CGSize = CGSize(width: 1_600, height: 1_000),
            tileSize: CGSize = CGSize(width: 420, height: 300)
        ) {
            canvas = CanvasNSView(
                canvasState: CanvasState(
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                    tiles: [], groups: [], lastActiveTileId: nil
                ),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
            )
            canvas.frame = CGRect(origin: .zero, size: viewportSize)
            window = NSWindow(
                contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = canvas
            window.orderFrontRegardless()

            let zoneId = UUID()
            let placement = ZonePlacement(
                zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 20_000, height: 20_000), color: "blue",
                collapsed: false, hydrationPolicy: .automatic
            )
            var built: [Tile] = []
            for index in 0..<tileCount {
                built.append(Tile(
                    id: UUID(), kind: .managedAgent, title: "surface-residency-\(index)",
                    frame: TileFrame(
                        x: Double(index % 3) * Double(tileSize.width + 60) + 40,
                        y: Double(index / 3) * Double(tileSize.height + 60) + 60,
                        width: Double(tileSize.width), height: Double(tileSize.height)
                    ),
                    zPosition: .fromLegacyRank(index + 1), zoneId: zoneId,
                    runtimeRef: nil, metadata: TileMetadata()
                ))
            }
            tiles = built
            layer = CanvasNSView.ZoneLayer(
                placement: placement,
                renderModel: CanvasNSView.ZoneRenderModel(
                    placement: placement, displayName: "Surface residency"
                ),
                tiles: built
            )
            for (index, tile) in built.enumerated() {
                let threadId = "surface-residency-\(index)"
                let view = ManagedAgentTileNSView(tile: tile, threadId: threadId)
                view.renderRehydratedPreviousSession(Self.transcript(threadId: threadId, turns: turns))
                agentViews[tile.id] = view
                layer.tileViews[tile.id] = view
            }
            canvas.setZones([layer])

            zoomGain = canvas.cameraDriver.tuning.scrollZoomGain
            commitGap = canvas.cameraDriver.tuning.minCommitInterval + 0.001
            canvas.cameraDriver.nowProvider = { [clock] in clock.now }
            // Residency runs on the same injected clock as the camera, so "this tile
            // has been quiet for a second" is a fact about the fixture and not about
            // how long the check took to run.
            canvas.residencyNowProvider = { [clock] in clock.now }
            // And the pointer is injected, ALWAYS. The production fallback is
            // `mouseLocationOutsideOfEventStream`, which in a check is wherever
            // Dylan's actual mouse happens to be — over the fixture's window as
            // often as not, which would make the pointer clause decide these
            // witnesses at random.
            canvas.residencyPointerProvider = { [weak self] in self?.injectedPointer }
            pump()
        }

        /// Pointer position in window coordinates, or nil for "the pointer is
        /// somewhere else entirely".
        var injectedPointer: NSPoint?

        /// Move the shared clock. Residency and the camera both read it.
        func advance(_ seconds: TimeInterval) { clock.now += seconds }

        /// Production runs `evaluateTileResidency` from a 10 Hz timer; a check calls
        /// it directly so every transition is caused rather than awaited.
        func evaluateResidency(passes: Int = 1) {
            for _ in 0..<passes {
                canvas.evaluateTileResidency()
                pump()
            }
        }

        /// The steady state Option A lives in: nothing streaming, no pointer, no
        /// focus — so every eligible tile is surfaced.
        ///
        /// Two stages, because the first pass is what LEARNS each tile's content
        /// revision. Until it has run, `lastContentChangeAt` is nil and the rule
        /// cannot tell a quiet tile from one mid-stream; after it, advancing past
        /// `contentQuietDelay` makes every tile quiet. The repeated passes are the
        /// per-pass bake budget: 4 bakes a pass means 12 tiles need three.
        func quiesceAndSurface(passes: Int = 6) {
            settle()
            window.makeFirstResponder(nil)
            injectedPointer = nil
            evaluateResidency()
            advance(canvas.residencyTuning.contentQuietDelay + 0.05)
            evaluateResidency(passes: passes)
        }

        func teardown() {
            for view in agentViews.values { view.removeFromSuperview() }
            window.orderOut(nil)
            window.contentView = nil
        }

        func pump() {
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }

        /// One real driver commit landing on `zoom`, by inverting the driver's own
        /// log-zoom gain. Goes through `noteScrollZoom`, so `onActivityBegin` fires
        /// from production code on the first step of a burst.
        @discardableResult
        func cameraStep(toZoom target: Double, anchor: CGPoint = CGPoint(x: 800, y: 500)) -> Bool {
            let current = canvas.viewport.zoom
            guard current > 0, target > 0, zoomGain > 0 else { return false }
            let deltaY = log(target / current) / zoomGain
            guard deltaY.isFinite, deltaY != 0 else { return false }
            clock.now += commitGap
            canvas.cameraDriver.noteScrollZoom(deltaY: deltaY, location: anchor)
            return true
        }

        /// The real settle edge: cancels any glide, flushes, and calls `markSettled`,
        /// which is what fires `onSettle` in a live gesture.
        func settle() {
            canvas.cameraDriver.qaMarkSettledNow()
            pump()
        }

        var transcriptLayoutPasses: Int { canvas.qaTotalTranscriptLayoutPassCount }

        /// Transcript layout passes over the FIXTURE's own bodies, wherever they
        /// currently live — plane or park. Cumulative per view, so callers take
        /// deltas.
        ///
        /// Rooted at `surfaceableBody`, which is a stable reference, and NOT at the
        /// tile view: demotion moves the body out of the tile, so a walk from the
        /// tile stops finding the transcript and the delta comes out NEGATIVE (-72
        /// for 12 tiles, on the first attempt). Walking the park instead has the
        /// mirror-image flaw — it reports each parked body's entire history as if it
        /// had just happened (84 for 12 tiles). Two bugs, one cause: a counter keyed
        /// on where a view LIVES, measuring a mechanism whose whole job is to move
        /// views between trees.
        var fixtureTranscriptLayoutPasses: Int {
            func walk(_ view: NSView) -> Int {
                var total = (view as? AgentTranscriptListView)?.qaLayoutPassCount ?? 0
                for subview in view.subviews { total += walk(subview) }
                return total
            }
            return agentViews.values.reduce(0) { $0 + ($1.surfaceableBody.map(walk) ?? 0) }
        }

        /// Layout passes inside the park, which `qaTotalTranscriptLayoutPassCount`
        /// cannot see — it walks the world plane, and a parked body is not there.
        var parkedTranscriptLayoutPasses: Int {
            func walk(_ view: NSView) -> Int {
                var total = (view as? AgentTranscriptListView)?.qaLayoutPassCount ?? 0
                for subview in view.subviews { total += walk(subview) }
                return total
            }
            return canvas.surfaceParkView.subviews.reduce(0) { $0 + walk($1) }
        }

        private static func transcript(threadId: String, turns: Int) -> RehydratedTranscript {
            var steps: [RehydratedTranscriptStep] = []
            for turn in 0..<turns {
                let turnId = "\(threadId)-turn-\(turn)"
                steps.append(.userPrompt("Explain the \(turn) path and the tradeoffs you took."))
                steps.append(.event(.turnStarted(threadId: threadId, turnId: turnId)))
                steps.append(.event(.contentDelta(
                    threadId: threadId, turnId: turnId, streamKind: .assistant,
                    delta: String(repeating: "A surfaced body must be indistinguishable from the real one. ", count: 4)
                )))
                steps.append(.event(.turnCompleted(
                    threadId: threadId, turnId: turnId, outcome: .completed, errorMessage: nil
                )))
            }
            return RehydratedTranscript(steps: steps, restoredMessageCount: turns * 2, omittedEarlier: false)
        }
    }

    // MARK: - Pixel comparison

    private static func bake(_ view: NSView) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw Failure(message: "could not allocate a comparison bake")
        }
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Mean absolute per-channel difference between two images of IDENTICAL pixel
    /// dimensions, on a 0...255 scale. `.infinity` when they are not the same
    /// shape, which is a louder failure than any difference value.
    ///
    /// Both images are redrawn into freshly created contexts of one fixed format
    /// first, so a difference in `bytesPerRow`, alpha layout or colour space cannot
    /// masquerade as a difference in content.
    private static func meanChannelDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let a = normalizedBytes(lhs), let b = normalizedBytes(rhs),
              a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for offset in 0..<a.count {
            total += abs(Int(a[offset]) - Int(b[offset]))
        }
        return Double(total) / Double(a.count)
    }

    private static func normalizedBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return Array(UnsafeRawBufferPointer(start: data, count: width * height * 4))
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        body()
        return (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    // MARK: - Run

    static func run() throws {
        try checkDefaultIsOff()
        try checkFlagOffChangesNothing()
        try checkQuietSurfacesAndLiveStaysNative()
        try checkHysteresisIgnoresAPointerSweep()
        try checkPixelEquivalence()
        try checkSharpnessNeverRegresses()
        try checkContentWhileSurfacedPromotesAndSurvives()
        try checkClickOnASurfacedTileReachesTheBody()
        try checkFocusNeverLandsOnAPicture()
        try checkNothingIsStranded()
        try checkAppearanceChangeGivesTheBodyBack()
        try checkAccessibilityFindsTheRealBody()
        try checkLeavingTheWindowRestoresEveryBody()
        try checkCost()
        try checkBakeCost()
        print("tile-surface-residency check: ok")
    }

    /// The flag ships OFF. Asserted rather than assumed: a default flipped by
    /// accident is how an experiment becomes everyone's problem.
    private static func checkDefaultIsOff() throws {
        let empty = UserDefaults(suiteName: "dev.arrayapp.tileSurfaceResidencyCheck.empty")!
        empty.removePersistentDomain(forName: "dev.arrayapp.tileSurfaceResidencyCheck.empty")
        try expect(
            TileSurfaceResidencyConfig.enabled(defaults: empty, environment: [:]) == false,
            "surface residency must default to OFF with no defaults key and no env override"
        )
        try expect(
            TileSurfaceResidencyConfig.enabled(defaults: empty, environment: ["ARRAY_TILE_SURFACE_RESIDENCY": "1"]),
            "the env override must be able to turn it on, or dogfooding needs a defaults write"
        )
    }

    /// With the flag off, a gesture must behave exactly as it does today: nothing
    /// demoted, nothing baked, an empty park — and the native backing cascade still
    /// happening, which is what proves the gesture was real.
    private static func checkFlagOffChangesNothing() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = false
        world.canvas.qaResetSurfaceResidencyCounters()
        let layoutsBefore = world.transcriptLayoutPasses
        for step in 1...8 {
            world.cameraStep(toZoom: 1.0 - 0.08 * Double(step))
            world.pump()
        }
        world.settle()

        try expect(world.canvas.qaSurfaceDemotionCount == 0,
                   "flag off must demote nothing, saw \(world.canvas.qaSurfaceDemotionCount)")
        try expect(world.canvas.tileSurfaceStore.qaBakeCount == 0,
                   "flag off must bake nothing, saw \(world.canvas.tileSurfaceStore.qaBakeCount)")
        try expect(world.canvas.qaParkedBodyCount == 0,
                   "flag off must park nothing, saw \(world.canvas.qaParkedBodyCount)")
        try expect(world.transcriptLayoutPasses > layoutsBefore,
                   "flag off must still pay the native cascade — a gesture that laid nothing out was not a gesture")
    }

    /// **Option A's rule, from production transitions only.** Quiet tiles surface,
    /// live tiles keep their real body, and a settle is no longer a promotion event.
    ///
    /// The inverse of slice 1's witness, deliberately: slice 1 asserted that
    /// settling restored every body, because residency was keyed on the camera.
    /// Under Option A a tile stays surfaced across many gestures and across rest,
    /// which is the entire point — reparenting is then paid per quiet<->live
    /// crossing rather than twice per gesture (~2.1 ms out, ~2.9 ms back, per tile).
    private static func checkQuietSurfacesAndLiveStaysNative() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true

        // Before anything is quiet, nothing may be surfaced: a tile whose content
        // just changed is live by definition, and the first pass is what learns that.
        world.settle()
        world.evaluateResidency()
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "a tile whose content just changed must stay native, saw "
                   + "\(world.canvas.qaSurfacedTileViews.count) surfaced")

        world.quiesceAndSurface()
        let surfaced = world.canvas.qaSurfacedTileViews.count
        try expect(surfaced == world.tiles.count,
                   "every quiet tile must surface: \(surfaced) of \(world.tiles.count)")
        try expect(world.canvas.qaParkedBodyCount == surfaced,
                   "every surfaced tile must have exactly one body in the park: \(surfaced) surfaced, "
                   + "\(world.canvas.qaParkedBodyCount) parked")
        for tile in world.tiles {
            try expect(world.canvas.qaLastResidencyDecision(tile.id) == .surfaced,
                       "a quiet tile's recorded decision must be .surfaced")
        }

        // The win, across a gesture — and the counter to use is the PARK walk, not
        // `qaTotalTranscriptLayoutPassCount`. That one sums over the world plane, so
        // it cannot see a parked body at all: it goes to zero when a tile is
        // surfaced, which reads like proof and is really blindness.
        let parkedBaseline = world.parkedTranscriptLayoutPasses
        let planeBaseline = world.transcriptLayoutPasses
        for step in 1...6 {
            world.cameraStep(toZoom: 0.9 - 0.05 * Double(step))
            world.pump()
        }
        try expect(world.parkedTranscriptLayoutPasses == parkedBaseline,
                   "a camera step reached a PARKED transcript: \(parkedBaseline) -> "
                   + "\(world.parkedTranscriptLayoutPasses). The park is not outside the cascade.")
        try expect(world.transcriptLayoutPasses == planeBaseline,
                   "a camera step laid out a transcript still in the world plane: \(planeBaseline) -> "
                   + "\(world.transcriptLayoutPasses)")

        // **Settling must NOT promote anything.** This is the line between the two
        // policies, and getting it wrong reintroduces slice 1's per-gesture bill.
        world.settle()
        try expect(world.canvas.qaSurfacedTileViews.count == surfaced,
                   "settling promoted \(surfaced - world.canvas.qaSurfacedTileViews.count) tiles — under "
                   + "Option A rest is a surfaced state, not a native one")

        // Content makes one tile live, and only that one.
        let liveId = world.tiles[0].id
        guard let liveView = world.agentViews[liveId] else {
            throw Failure(message: "the fixture lost its first agent view")
        }
        let thread = "surface-residency-0"
        let turn = "\(thread)-live"
        liveView.ingest(.turnStarted(threadId: thread, turnId: turn))
        liveView.ingest(.contentDelta(
            threadId: thread, turnId: turn, streamKind: .assistant, delta: "A token arrives."
        ))
        world.evaluateResidency()
        try expect(liveView.surfaceResidency == .native,
                   "a tile that received content must be promoted, not left as a picture")
        try expect(world.canvas.qaLastResidencyDecision(liveId) == .native(.streaming),
                   "the promotion reason must be .streaming, so the rule is observable: got "
                   + String(describing: world.canvas.qaLastResidencyDecision(liveId)))
        try expect(world.canvas.qaSurfacedTileViews.count == surfaced - 1,
                   "one tile going live must not disturb the others")

        // And it goes back once it is quiet again.
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 2)
        try expect(liveView.surfaceResidency == .surfaced,
                   "a tile that fell quiet must surface again")

        // Focus holds a tile native even though its content is old — and the focus
        // test has to see through the park, because a surfaced tile's body is not in
        // the tile's subtree any more.
        guard let body = liveView.surfaceableBody else {
            throw Failure(message: "the fixture's agent tile has no surfaceable body")
        }
        world.window.makeFirstResponder(body)
        world.evaluateResidency()
        try expect(liveView.surfaceResidency == .native,
                   "the tile holding the first responder must be native — otherwise the user is typing "
                   + "into a picture")
        try expect(world.canvas.qaLastResidencyDecision(liveId) == .native(.focus),
                   "the reason must be .focus: got "
                   + String(describing: world.canvas.qaLastResidencyDecision(liveId)))
        world.window.makeFirstResponder(nil)

        // The pointer, once it has RESTED. Both halves are asserted: the tile under
        // a resting pointer is native, and its neighbours are untouched.
        let pointerTarget = world.tiles[1].id
        guard let pointerView = world.agentViews[pointerTarget] else {
            throw Failure(message: "the fixture lost its second agent view")
        }
        let centre = CGPoint(x: pointerView.bounds.midX, y: pointerView.bounds.midY)
        world.injectedPointer = pointerView.convert(centre, to: nil)
        world.evaluateResidency()
        try expect(pointerView.surfaceResidency == .surfaced,
                   "the pointer must have to REST before it promotes anything — a tile it has only just "
                   + "arrived over is still surfaced")
        world.advance(world.canvas.residencyTuning.pointerRestDelay + 0.01)
        world.evaluateResidency()
        try expect(pointerView.surfaceResidency == .native,
                   "a tile under a resting pointer must be native, for cursor rects and tooltips")
        try expect(world.canvas.qaLastResidencyDecision(pointerTarget) == .native(.pointerResting),
                   "the reason must be .pointerResting: got "
                   + String(describing: world.canvas.qaLastResidencyDecision(pointerTarget)))
    }

    /// **Hysteresis: sweeping the pointer across the canvas must cost nothing.**
    ///
    /// Without a rest delay, dragging the cursor over five surfaced tiles is five
    /// promote/demote pairs — ~25 ms of AppKit subtree surgery during the sweep,
    /// exactly the cost this policy exists to avoid paying casually.
    private static func checkHysteresisIgnoresAPointerSweep() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "the sweep witness needs every tile surfaced first")
        world.canvas.qaResetSurfaceResidencyCounters()

        // One pass per tile, with the clock advancing by less than the rest delay
        // between them — a pointer moving steadily, never lingering.
        let hop = world.canvas.residencyTuning.pointerRestDelay / 3
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id] else { continue }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            world.injectedPointer = view.convert(centre, to: nil)
            world.advance(hop)
            world.evaluateResidency()
        }
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "a pointer sweep promoted \(world.canvas.qaSurfacePromotionCount) tiles — the rest "
                   + "delay is not doing its job")
        world.injectedPointer = nil
    }

    /// The gate Dylan's requirement actually names, aimed at the PRODUCER.
    ///
    /// The surface is compared against a native bake of the same body taken at the
    /// same content and the same resolution — the native bake FIRST, while the body
    /// is still in the plane, because `.plans/37` Step 0 measured that a bake of a
    /// parked body is not the body's pixels at all. That isolates what Array owns
    /// (does the producer render the right pixels?) from what Core Animation owns
    /// (drawing a sharp image smaller, which is inherent to showing any cached image
    /// and is bounded by the sharpness rule to downscaling only).
    ///
    /// An early version compared against a native bake taken at a DIFFERENT zoom.
    /// Two things were wrong and both mattered: `bitmapImageRepForCachingDisplay`
    /// sizes itself from the view's effective scale, so the reps were not even the
    /// same shape; and once that was fixed the metric was dominated by resampling,
    /// which left the half-scale negative witness indistinguishable from the green
    /// path (4.44 vs 4.62 — a gate that cannot fail).
    private static func checkPixelEquivalence() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true

        // Make everything quiet WITHOUT surfacing it yet: one pass to learn the
        // revisions, then time, then the native reference bakes, then the pass that
        // bakes and demotes. Nothing changes content in between.
        world.settle()
        world.window.makeFirstResponder(nil)
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.pump()

        var references: [UUID: CGImage] = [:]
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id], let body = view.surfaceableBody else { continue }
            let rep = try bake(body)
            guard let image = rep.cgImage else {
                throw Failure(message: "the native comparison bake produced no image")
            }
            try expect(!VisualSnapshot.metrics(of: rep).isBlank,
                       "the native body rendered blank — the fixture, not the surface, is wrong")
            references[tile.id] = image
        }
        world.evaluateResidency(passes: 2)

        var worstDifference = 0.0
        var compared = 0
        for tile in world.tiles {
            guard let reference = references[tile.id],
                  let surface = world.canvas.tileSurfaceStore.surface(for: tile.id) else { continue }
            worstDifference = max(worstDifference, meanChannelDifference(surface.image, reference))
            compared += 1
        }
        try expect(compared > 0, "no surface existed, so fidelity was never actually tested")
        print(String(format: "tile-surface-residency: worst producer-vs-native mean channel difference %.3f "
                     + "over %d tiles", worstDifference, compared))
        try expect(worstDifference <= surfaceFidelityThreshold,
                   String(format: "the producer does not reproduce the real body: mean channel difference "
                          + "%.3f > %.3f over %d tiles (TILE_SURFACE_HALF_SCALE=1 is the negative witness "
                          + "for this gate)", worstDifference, surfaceFidelityThreshold, compared))

        // And separately: what the user actually sees while surfaced must not be
        // blank. Cheap, and it is the failure mode that would matter most.
        var checkedComposite = 0
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id], view.surfaceResidency == .surfaced else { continue }
            let composite = try bake(view)
            try expect(!VisualSnapshot.metrics(of: composite).isBlank,
                       "a surfaced tile composited blank — the worst possible outcome of this design")
            checkedComposite += 1
        }
        try expect(checkedComposite > 0, "no tile surfaced, so the composite was never checked")
    }

    /// Mean per-channel difference the producer may show against the real body.
    /// Calibrated against the negative witness, not guessed — see
    /// docs/internals/performance-budgets.md for both measured numbers.
    private static let surfaceFidelityThreshold = 0.25

    /// Zooming IN past what a surface carries must refuse the surface, not show a
    /// soft one — in the same step that made it so, not at the next gesture.
    ///
    /// Under Option A the tiles are already surfaced before the zoom starts, so this
    /// exercises `enforceSurfaceSharpness`, which runs per camera step over the
    /// maintained surfaced set. It is scoped to tiles at or near the viewport: a tile
    /// nobody can see is not showing anything soft, and zooming in shrinks the
    /// visible set, which is what makes the rule affordable.
    private static func checkSharpnessNeverRegresses() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.tileSurfaceStore.count > 0, "need surfaces before testing refusal")
        let bakedScale = world.canvas.tileSurfaceStore.surface(for: world.tiles[0].id)?.bakedScale ?? 0
        try expect(bakedScale > 0, "a stored surface must know its own density")

        world.canvas.qaResetSurfaceResidencyCounters()
        let backing = world.window.backingScaleFactor
        let tooSharp = Double(bakedScale / backing) * 2
        world.cameraStep(toZoom: tooSharp)
        world.pump()

        let softAndVisible = world.canvas.visibleTileViews.filter { $0.surfaceResidency == .surfaced }
        try expect(softAndVisible.isEmpty,
                   "zooming past the baked density left \(softAndVisible.count) VISIBLE tiles surfaced at "
                   + "zoom \(tooSharp) — those are showing soft text")
        try expect(world.canvas.qaSurfaceRefusedSharpnessCount > 0,
                   "the refusal must be the SHARPNESS one, so the reason is observable and not a coincidence")
    }

    /// A parked body is quiet, not dead — and content arriving is what makes a tile
    /// live again.
    ///
    /// Both halves matter, and `.plans/37` Step 0 is why the second one is phrased
    /// as promotion rather than as pixels: a parked body keeps ingesting (its row
    /// count advances) but its PIXELS never change, because its transcript's
    /// `visibleRect` degenerates once no ancestor places it in the visible area. So
    /// the design cannot leave a streaming tile surfaced and re-bake it; it has to
    /// give the tile back.
    private static func checkContentWhileSurfacedPromotesAndSurvives() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()

        guard let view = world.agentViews[world.tiles[0].id], view.surfaceResidency == .surfaced else {
            throw Failure(message: "the streaming witness needs a surfaced tile and did not get one")
        }
        let cardsBefore = view.transcriptCardCount
        let thread = "surface-residency-0"
        let turn = "\(thread)-live"
        view.ingest(.turnStarted(threadId: thread, turnId: turn))
        view.ingest(.contentDelta(
            threadId: thread, turnId: turn, streamKind: .assistant,
            delta: "This delta arrived while the tile was rendering from a surface."
        ))
        world.pump()
        try expect(view.transcriptCardCount > cardsBefore,
                   "a surfaced tile stopped ingesting its stream — parking must not detach the subscriber")

        world.evaluateResidency()
        try expect(view.surfaceResidency == .native,
                   "a tile receiving content must be promoted within one evaluation — a parked body's "
                   + "pixels never change, so leaving it surfaced would freeze the stream on screen")
        view.qaTranscriptCollectionFixture?.flushPendingVisualUpdate()
        world.pump()
        try expect(view.qaTranscriptText.contains("while the tile was rendering from a surface"),
                   "content ingested while surfaced is missing from the restored transcript")
    }

    /// A picture swallows clicks. `hitTest` promotes first, so the event lands on
    /// the real body.
    ///
    /// This mattered in slice 1 only during the 250 ms settle window. Under Option A
    /// a surfaced tile at rest is the NORMAL state, so it is the ordinary click path
    /// for every quiet tile on the canvas.
    private static func checkClickOnASurfacedTileReachesTheBody() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()

        guard let view = world.agentViews[world.tiles[0].id], view.surfaceResidency == .surfaced else {
            throw Failure(message: "the click witness needs a surfaced tile and did not get one")
        }
        // Well inside the body, below the grab strip, in the tile's own coordinates
        // converted to its superview the way AppKit passes them to `hitTest`.
        let local = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let inSuperview = view.superview.map { view.convert(local, to: $0) } ?? local
        let hit = view.hitTest(inSuperview)
        try expect(view.surfaceResidency == .native,
                   "hit-testing a surfaced body must promote it before AppKit delivers the event")
        try expect(hit != nil, "the promoted tile must still answer the hit test")
        if let hit {
            var isInsideRealBody = false
            var walker: NSView? = hit
            while let current = walker {
                if current === view.surfaceableBody { isInsideRealBody = true; break }
                walker = current.superview
            }
            try expect(isInsideRealBody || hit === view,
                       "the hit landed outside the restored body — the click would go somewhere unexpected")
        }
        try expect(view.qaParkedBody == nil, "promotion must take the body back out of the park")
    }

    /// **Focus must never land on a picture.**
    ///
    /// `TileNSView.acquireFocus` makes `contentView` the first responder, and while a
    /// tile is surfaced `contentView` IS the surface host. Slice 1 never reached this
    /// because at rest nothing was surfaced; Option A makes surfaced-at-rest normal,
    /// so a focus request on a quiet tile is the common case, not the corner.
    private static func checkFocusNeverLandsOnAPicture() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()

        guard let view = world.agentViews[world.tiles[0].id], view.surfaceResidency == .surfaced,
              let body = view.surfaceableBody else {
            throw Failure(message: "the focus witness needs a surfaced tile and did not get one")
        }
        _ = view.acquireFocus(reason: .userClick)
        world.pump()
        try expect(view.surfaceResidency == .native,
                   "acquiring focus must promote the tile first — making a surface host the first "
                   + "responder sends every keystroke to a picture")
        guard let responder = world.window.firstResponder as? NSView else {
            throw Failure(message: "focus did not land on a view at all")
        }
        try expect(responder === body || responder.isDescendant(of: body) || responder === view,
                   "the first responder is not inside the real body: \(type(of: responder))")
        // And the policy must not undo it on the next pass.
        world.evaluateResidency()
        try expect(view.surfaceResidency == .native,
                   "the focused tile was demoted again — `containsResponder` must see through the park")
    }

    /// Nothing may be left in the park, and no surface may outlive its tile.
    private static func checkNothingIsStranded() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaParkedBodyCount > 0, "need a populated park before testing teardown")

        // Removing a tile while it is SURFACED is the case that strands a body: the
        // tile view leaves the world plane while its real body is somewhere else.
        let doomed = world.tiles[0].id
        world.canvas.removeTile(id: doomed)
        world.pump()
        try expect(world.canvas.tileSurfaceStore.surface(for: doomed) == nil,
                   "a removed tile's surface must be dropped")
        for parked in world.canvas.surfaceParkView.subviews {
            try expect(parked !== world.agentViews[doomed]?.surfaceableBody,
                       "the removed tile's body is stranded in the park")
        }

        // A project switch replaces every layer; nothing from the old one may remain.
        let survivingIds = Set(world.tiles.dropFirst().map { $0.id })
        world.canvas.setZones([])
        world.pump()
        try expect(world.canvas.qaParkedBodyCount == 0,
                   "a zone switch left \(world.canvas.qaParkedBodyCount) bodies in the park")
        try expect(world.canvas.tileSurfaceStore.count == 0,
                   "a zone switch left \(world.canvas.tileSurfaceStore.count) surfaces for tiles that are gone")
        try expect(survivingIds.allSatisfy { world.canvas.tileSurfaceStore.surface(for: $0) == nil },
                   "pruning must not keep a departed project's surfaces")
    }

    /// **An appearance change must give every body back.**
    ///
    /// `TileSurfaceRevision` carries `appearanceName`, and switching to dark mode
    /// ingests nothing, animates nothing and touches no content — so every liveness
    /// clause still says "quiet" while every surface on the canvas has just become a
    /// picture of the light-mode tile. This is the one way a surface goes stale
    /// without its tile going live, and without the stale-promotion path the canvas
    /// would sit in the wrong appearance until something unrelated happened.
    private static func checkAppearanceChangeGivesTheBodyBack() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "the appearance witness needs every tile surfaced first")
        world.canvas.qaResetSurfaceResidencyCounters()

        world.window.appearance = NSAppearance(named: .darkAqua)
        world.pump()
        world.evaluateResidency()
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "an appearance change left \(world.canvas.qaSurfacedTileViews.count) tiles showing a "
                   + "light-mode picture")
        try expect(world.canvas.qaSurfaceStalePromotionCount == world.tiles.count,
                   "the promotions must be attributed to STALENESS, not to a liveness clause: "
                   + "\(world.canvas.qaSurfaceStalePromotionCount) of \(world.tiles.count)")

        // And the canvas settles back to surfaced, with surfaces baked in the new
        // appearance — bakes taken while native, as always.
        world.evaluateResidency(passes: 4)
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "the canvas did not return to surfaced after re-baking: "
                   + "\(world.canvas.qaSurfacedTileViews.count) of \(world.tiles.count)")
        for tile in world.tiles {
            let wanted = world.agentViews[tile.id]?.currentSurfaceRevision
            try expect(world.canvas.tileSurfaceStore.surface(for: tile.id)?.revision == wanted,
                       "a re-baked surface does not match the tile's current revision")
        }
    }

    /// **A screen reader must find the real body, in the right place.**
    ///
    /// This is the one gap the pointer clause does not cover: VoiceOver walks the
    /// hierarchy with no pointer and no focus, so nothing else would have promoted
    /// the tile. Measured before it was designed — while surfaced, the transcript is
    /// still reachable, through the PARK, at `{{0, 1132}, {420, 90}}` while its tile
    /// sits at `{{40, 640}, {420, 300}}`. Wrong place, wrong size, detached from its
    /// owner. So the park is opaque to accessibility and the tile hands its body back
    /// when asked, exactly as `hitTest` does for input.
    private static func checkAccessibilityFindsTheRealBody() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        let tileId = world.tiles[0].id
        guard let view = world.agentViews[tileId], view.surfaceResidency == .surfaced else {
            throw Failure(message: "the accessibility witness needs a surfaced tile and did not get one")
        }

        func findTranscript(_ elements: [Any]) -> AgentTranscriptListView? {
            for element in elements {
                if let transcript = element as? AgentTranscriptListView { return transcript }
                if let view = element as? NSView,
                   let found = findTranscript(view.accessibilityChildren() ?? view.subviews) {
                    return found
                }
            }
            return nil
        }

        // 1. The park exposes nothing. Otherwise a parked body is reachable as an
        //    orphan at coordinates that belong to no tile.
        try expect((world.canvas.surfaceParkView.accessibilityChildren() ?? []).isEmpty,
                   "the park exposed \((world.canvas.surfaceParkView.accessibilityChildren() ?? []).count) "
                   + "accessibility children — a parked body must not be reachable except through its tile")
        try expect(world.canvas.surfaceParkView.isAccessibilityElement() == false,
                   "the park must not be an accessibility element itself")
        try expect(findTranscript(world.canvas.surfaceParkView.accessibilityChildren() ?? []) == nil,
                   "a transcript is still reachable by walking the park")

        // 2. Asking the tile promotes, and what comes back is the real body.
        let accessesBefore = view.accessibilityAccessCount
        let children = view.accessibilityChildren() ?? []
        try expect(view.accessibilityAccessCount > accessesBefore,
                   "the tile did not record the accessibility access, so the policy cannot keep it native")
        try expect(view.surfaceResidency == .native,
                   "an accessibility client read a surfaced tile without it handing the body back")
        guard let transcript = findTranscript(children) else {
            throw Failure(message: "the promoted tile's accessibility subtree has no transcript in it")
        }

        // 3. And the frames are true — the whole point. A VoiceOver cursor is drawn
        //    on the frame the element reports.
        let tileFrame = view.accessibilityFrame()
        let transcriptFrame = transcript.accessibilityFrame()
        try expect(tileFrame.insetBy(dx: -1, dy: -1).contains(transcriptFrame),
                   "the transcript reports \(NSStringFromRect(transcriptFrame)), which is not inside its "
                   + "tile at \(NSStringFromRect(tileFrame)) — a screen reader would highlight the wrong "
                   + "part of the screen")

        // 4. It STAYS native while the client keeps reading. Without this the next
        //    pass demotes it 100 ms later and the AX tree churns under the user.
        world.evaluateResidency()
        try expect(view.surfaceResidency == .native,
                   "the tile was demoted while an accessibility client was reading it")
        try expect(world.canvas.qaLastResidencyDecision(tileId) == .native(.accessibility),
                   "the reason must be .accessibility: got "
                   + String(describing: world.canvas.qaLastResidencyDecision(tileId)))

        // 5. And it goes back once nothing is reading.
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 2)
        try expect(view.surfaceResidency == .surfaced,
                   "a tile nothing is reading any more must surface again")

        // 6. The claim that makes this affordable: with NO accessibility client, this
        //    path costs nothing. AppKit asked a tile for its children zero times over
        //    a full run of settles, evaluations and camera steps.
        world.canvas.qaResetSurfaceResidencyCounters()
        for step in 1...6 {
            world.cameraStep(toZoom: 0.9 - 0.05 * Double(step))
            world.pump()
        }
        world.settle()
        world.evaluateResidency(passes: 2)
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "\(world.canvas.qaSurfacePromotionCount) tiles were promoted with no accessibility "
                   + "client asking — the AX hook must be free when nobody is reading")
    }

    /// A canvas that leaves its window must hand every body back. Nothing evaluates
    /// residency out there, so a body parked in a windowless canvas is a body no
    /// policy will ever reclaim.
    private static func checkLeavingTheWindowRestoresEveryBody() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaParkedBodyCount == world.tiles.count,
                   "this witness needs every body parked first")

        world.window.contentView = NSView(frame: world.canvas.frame)
        world.pump()
        try expect(world.canvas.qaParkedBodyCount == 0,
                   "leaving the window left \(world.canvas.qaParkedBodyCount) bodies in the park")
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "leaving the window left \(world.canvas.qaSurfacedTileViews.count) tiles surfaced")
    }

    /// **The number Option A stands on: what does a camera step cost per LIVE tile?**
    ///
    /// Slice 1 answered "surfaced vs native" — 24 ms against 0.1 ms at 12 tiles — and
    /// that is not the question any more. Under Option A the camera pays for exactly
    /// the tiles keeping their real body (streaming, focused, or under the pointer)
    /// and nothing for the rest, so what matters is **how many tiles may be live at
    /// once before a step stops fitting a frame.**
    ///
    /// The Core Animation flush is kept OUT of the Array-owned number: a returning
    /// `CATransaction.flush()` is compositor synchronisation, and folding it in once
    /// reported a 0.07 ms camera path as 119% over budget.
    private static func checkCost() throws {
        let tileCount = 12
        let frameBudgetMs = 8.3

        /// Median Array-owned cost of one camera step with `liveCount` tiles held
        /// native and the rest surfaced. `residency: false` is the reference arm:
        /// today's canvas, where every tile is native.
        func perStepMs(liveCount: Int, residency: Bool = true) throws -> Double {
            let world = World(tileCount: tileCount)
            defer { world.teardown() }
            world.canvas.surfaceResidencyEnabled = residency
            if residency {
                world.quiesceAndSurface(passes: 8)
                // A live tile is one that is streaming, so make it stream. One burst
                // is enough: demotions are suppressed for the duration of a gesture,
                // which is production behaviour, not a fixture shortcut.
                for (index, tile) in world.tiles.prefix(liveCount).enumerated() {
                    guard let view = world.agentViews[tile.id] else { continue }
                    let thread = "surface-residency-\(index)"
                    let turn = "\(thread)-cost"
                    view.ingest(.turnStarted(threadId: thread, turnId: turn))
                    view.ingest(.contentDelta(
                        threadId: thread, turnId: turn, streamKind: .assistant,
                        delta: "Streaming keeps this tile live for the whole gesture."
                    ))
                }
                world.evaluateResidency()
                let live = world.tiles.prefix(liveCount).filter {
                    world.agentViews[$0.id]?.surfaceResidency == .native
                }.count
                guard live == liveCount else {
                    throw Failure(message: "cost: wanted \(liveCount) live tiles, got \(live)")
                }
            } else {
                world.settle()
            }
            // Drain the first rasterisation and any symbol-cache population before the
            // clock: a cold first step belongs to construction.
            world.cameraStep(toZoom: 0.95)
            world.pump()
            CATransaction.flush()

            var steps: [Double] = []
            for index in 1...12 {
                steps.append(milliseconds {
                    world.cameraStep(toZoom: 0.9 - 0.03 * Double(index))
                    world.canvas.layoutSubtreeIfNeeded()
                    world.window.displayIfNeeded()
                })
                CATransaction.flush()
            }
            let sorted = steps.sorted()
            return sorted[sorted.count / 2]
        }

        let native = try perStepMs(liveCount: 0, residency: false)
        let quiet = try perStepMs(liveCount: 0)
        let oneLive = try perStepMs(liveCount: 1)
        let threeLive = try perStepMs(liveCount: 3)
        let sixLive = try perStepMs(liveCount: 6)

        let marginal = (sixLive - quiet) / 6
        let headroom = marginal > 0.01 ? (frameBudgetMs - quiet) / marginal : Double(tileCount)
        print(String(
            format: "tile-surface-residency: %d tiles | per step p50 — every tile native %.2f ms | "
            + "Option A with 0 live %.2f ms, 1 live %.2f ms, 3 live %.2f ms, 6 live %.2f ms | marginal "
            + "%.2f ms per live tile | fits %.1f live tiles in an %.1f ms frame (and %.1f at 60 Hz)",
            tileCount, native, quiet, oneLive, threeLive, sixLive, marginal, headroom, frameBudgetMs,
            marginal > 0.01 ? (16.7 - quiet) / marginal : Double(tileCount)
        ))
        try expect(quiet <= frameBudgetMs,
                   String(format: "an all-quiet canvas must cost almost nothing: %.2f ms > %.2f ms",
                          quiet, frameBudgetMs))
        try expect(quiet < native,
                   String(format: "surfacing must be cheaper than not surfacing: %.2f ms vs %.2f ms",
                          quiet, native))
        // One live tile has to fit, because every canvas has one: the tile under the
        // pointer, or the one holding focus. That is the floor Option A cannot be
        // below.
        try expect(oneLive <= frameBudgetMs,
                   String(format: "one live tile must fit a frame: %.2f ms > %.2f ms. There is always at "
                          + "least one — whatever the pointer is resting on.", oneLive, frameBudgetMs))
        // The marginal cost per live tile is the regression gate, and the headroom it
        // implies is PUBLISHED rather than gated. Measured at ~2.9 ms/tile, so an
        // 8.3 ms frame (120 Hz) holds about 2.8 live tiles and a 16.7 ms frame
        // (60 Hz) about 5.7. That number is AppKit's constraint solve over a real
        // transcript, marked dirty by the plane's bounds cascade — the same cost
        // today's canvas pays for EVERY tile. Getting below it means a live tile not
        // being an AppKit view tree in the cascade at all, which is I2/I4, not tuning.
        try expect(marginal <= 3.5,
                   String(format: "a live tile now costs %.2f ms per camera step, up from ~2.9 ms. Option "
                          + "A's headroom is proportional to this, so a regression here shrinks how many "
                          + "agents can stream while the camera moves.", marginal))

        // **The transition, published: what one quiet<->live crossing costs.** Option
        // A pays this per crossing instead of twice per gesture, which is the whole
        // reason it exists. The demote path is timed per call because "the transition
        // is slow" is not actionable, and two guesses at WHY were already wrong (a
        // fresh CALayer texture upload per gesture; an empty visibleRect in the park).
        let world = World(tileCount: tileCount)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.settle()
        world.window.makeFirstResponder(nil)
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        TileNSView.qaResetDemoteTiming()
        // The evaluation calls ONLY — no `pump()` between them. A first attempt timed
        // `evaluateResidency(passes: 8)`, whose pumps carry a layout, a display and a
        // CATransaction flush apiece, and then reported that the breakdown explained
        // 42% of "the transition". It explained 82% of the transition; the instrument
        // was measuring the fixture.
        let demotePassMs = milliseconds {
            for _ in 0..<8 { world.canvas.evaluateTileResidency() }
        }
        world.pump()
        let demoted = world.canvas.qaSurfacedTileViews.count
        try expect(demoted == tileCount, "the transition arm needs every tile surfaced, got \(demoted)")
        let promoteMs = milliseconds { world.canvas.promoteAllSurfacedTiles() }
        print(String(
            format: "tile-surface-residency: one quiet->live crossing, %d tiles | demote %.2f ms total "
            + "(host %.2f / contentSwap %.2f / park %.2f) = %.2f ms per tile | promote %.2f ms total = "
            + "%.2f ms per tile. Paid per crossing, NOT per gesture — that is the policy.",
            demoted, demotePassMs, TileNSView.qaDemoteHostMs, TileNSView.qaDemoteContentSwapMs,
            TileNSView.qaDemoteParkMs,
            (TileNSView.qaDemoteHostMs + TileNSView.qaDemoteContentSwapMs + TileNSView.qaDemoteParkMs)
                / Double(demoted),
            promoteMs, promoteMs / Double(demoted)
        ))
        // Instrument integrity, not a budget: a breakdown that stops accounting for
        // the pass it explains turns a published number into fiction. The unattributed
        // remainder is the bakes — one per tile, ~1 ms each (`checkBakeCost`).
        let attributed = TileNSView.qaDemoteHostMs + TileNSView.qaDemoteContentSwapMs
            + TileNSView.qaDemoteParkMs
        try expect(attributed >= demotePassMs * 0.5,
                   String(format: "the demote breakdown no longer explains the pass: %.2f ms attributed "
                          + "of %.2f ms measured", attributed, demotePassMs))
    }

    /// **`.plans/37` Step 0: what does ONE bake cost?**
    ///
    /// Slice 1 only ever baked at rest, where a bake is free by construction — the
    /// gesture had not started yet. Always-surfaced inverts that. A VISIBLE
    /// streaming agent is showing a picture, so it has to RE-bake to keep showing
    /// live text, at the transcript's own presentation cadence. The cost of one bake
    /// is therefore the number the whole next policy stands on, and it has never
    /// been measured — the same way the parked arm had to be measured before slice 1
    /// could be built.
    ///
    /// Four costs, because they are not the same number and the policy pays
    /// different ones in different places:
    ///
    /// - a clean bake of a body **in the plane** (what slice 1 does at rest);
    /// - a **streaming refresh** in the plane — the layout the new content forces
    ///   plus the bake, which is what a live streamer actually pays;
    /// - both again with the body **parked**, which is where always-surfaced keeps
    ///   it, and which is the number slice 2 is judged on.
    ///
    /// Two body sizes, so the result extrapolates by area rather than by hope.
    ///
    /// Published, with three gates: one bake must fit a frame (true for any policy),
    /// the alloc/draw split must still explain the bake it claims to explain, and a
    /// refresh must produce DIFFERENT PIXELS — otherwise this is timing a no-op and
    /// reporting it as a bake, which is exactly the mistake the parked arm's
    /// liveness teeth exist to stop.
    private static func checkBakeCost() throws {
        let frameBudgetMs = 8.3
        /// The transcript presents at 30 Hz (`AgentTranscriptListView.enqueue`), so
        /// that is the re-bake cadence a visible streamer imposes — not the frame rate.
        let refreshHz = 30.0
        let sizes = [CGSize(width: 420, height: 300), CGSize(width: 760, height: 900)]

        func p50(_ samples: [Double]) -> Double {
            let sorted = samples.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }

        for size in sizes {
            let world = World(
                tileCount: 6,
                viewportSize: CGSize(
                    width: max(1_600, size.width * 3 + 200), height: max(1_000, size.height * 2 + 200)
                ),
                tileSize: size
            )
            defer { world.teardown() }
            world.pump()

            let tiles = world.tiles
            let store = TileSurfaceStore()

            func agent(_ id: UUID) throws -> ManagedAgentTileNSView {
                guard let view = world.agentViews[id] else {
                    throw Failure(message: "bake cost: a fixture tile has no agent view")
                }
                return view
            }
            func body(_ id: UUID) throws -> NSView {
                guard let body = try agent(id).surfaceableBody else {
                    throw Failure(message: "bake cost: an agent tile has no surfaceable body")
                }
                return body
            }
            func revision(_ id: UUID) throws -> TileSurfaceRevision {
                guard let revision = try agent(id).currentSurfaceRevision else {
                    throw Failure(message: "bake cost: an agent tile cannot state its surface revision")
                }
                return revision
            }

            /// One streamed delta into a tile, presented and laid out, then baked.
            /// The whole thing is the unit, because a streamer cannot pay the bake
            /// without paying the layout that made it necessary.
            func refresh(_ tileId: UUID, index: Int, tag: String) throws -> Double {
                let view = try agent(tileId)
                let threadId = "surface-residency-\(index)"
                let turnId = "\(threadId)-bake-cost-\(tag)"
                view.ingest(.turnStarted(threadId: threadId, turnId: turnId))
                let target = try body(tileId)
                return milliseconds {
                    view.ingest(.contentDelta(
                        threadId: threadId, turnId: turnId, streamKind: .assistant,
                        delta: "One more streamed sentence arrives while this tile is surfaced. "
                    ))
                    view.qaTranscriptCollectionFixture?.flushPendingVisualUpdate()
                    target.layoutSubtreeIfNeeded()
                    if let revision = view.currentSurfaceRevision {
                        store.bake(tileId: tileId, body: target, revision: revision)
                    }
                }
            }

            // Warm. The first bake of a body pays for context creation, font and
            // symbol caches, and a first rasterisation of everything beneath it —
            // construction cost, not the cost of keeping a streamer fresh.
            for tile in tiles {
                store.bake(tileId: tile.id, body: try body(tile.id), revision: try revision(tile.id))
            }
            guard let warmed = store.surface(for: tiles[0].id) else {
                throw Failure(message: "bake cost: the warm-up bake produced no surface")
            }

            var planeClean: [Double] = []
            for tile in tiles {
                let target = try body(tile.id)
                let rev = try revision(tile.id)
                planeClean.append(milliseconds { store.bake(tileId: tile.id, body: target, revision: rev) })
            }

            // Split, inline rather than through the store, because "a bake costs N
            // ms" does not say whether the fix is a smaller image or a cheaper draw.
            var allocSamples: [Double] = []
            var drawSamples: [Double] = []
            for tile in tiles {
                let target = try body(tile.id)
                var rep: NSBitmapImageRep?
                allocSamples.append(milliseconds { rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) })
                guard let rep else { throw Failure(message: "bake cost: could not allocate a rep") }
                drawSamples.append(milliseconds { target.cacheDisplay(in: target.bounds, to: rep) })
            }

            var planeRefresh: [Double] = []
            let beforeRefresh = store.surface(for: tiles[0].id)?.image
            for (index, tile) in tiles.enumerated() {
                planeRefresh.append(try refresh(tile.id, index: index, tag: "plane"))
            }
            guard let beforeRefresh, let afterRefresh = store.surface(for: tiles[0].id)?.image else {
                throw Failure(message: "bake cost: the refresh path stored no surface")
            }
            let refreshDelta = meanChannelDifference(beforeRefresh, afterRefresh)

            // Now the state Option A lives in: the body parked outside the world
            // plane, reached through the PRODUCTION residency pass rather than by
            // moving views here. Production never bakes in this state — the pass bakes
            // while a tile is still native and demotes afterwards — so this is a
            // deliberate look at what it would get if it did.
            //
            // The A/B is deliberately tight: quiet the canvas, bake IN-PLANE, then run
            // the pass whose only effect is the demotion, then bake PARKED. Nothing is
            // ingested in between. A first attempt compared bakes taken either side of
            // a settle AND a streaming loop and reported 3.2844, which measured the
            // fixture's own progress, not the park.
            world.canvas.surfaceResidencyEnabled = true
            world.settle()
            world.window.makeFirstResponder(nil)
            world.evaluateResidency()
            world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
            world.pump()

            let transcript = try agent(tiles[0].id).qaTranscriptCollectionFixture
            let planeVisibleRect = transcript?.visibleRect ?? .zero
            let planeDocumentHeight = transcript?.qaTranscriptDocumentHeight ?? 0
            guard let inPlaneReference = store.bake(
                tileId: tiles[0].id, body: try body(tiles[0].id), revision: try revision(tiles[0].id)
            )?.image else {
                throw Failure(message: "bake cost: the in-plane reference bake produced nothing")
            }

            // The residency pass is what parks the bodies. The camera never moves here,
            // so both bakes are the same shape — and even if it did, a parked body is
            // OUT of the plane's backing cascade, so its effective scale is the
            // display's alone. A first attempt learned that the loud way, comparing
            // 840x552 against 757x497 for an `.infinity` difference.
            world.evaluateResidency(passes: 6)
            try expect(world.canvas.qaParkedBodyCount == tiles.count,
                       "bake cost: the parked measurement needs every body parked, saw "
                       + "\(world.canvas.qaParkedBodyCount) of \(tiles.count)")

            guard let parkedReference = store.bake(
                tileId: tiles[0].id, body: try body(tiles[0].id), revision: try revision(tiles[0].id)
            )?.image else {
                throw Failure(message: "bake cost: the parked reference bake produced nothing")
            }
            let parkedVisibleRect = transcript?.visibleRect ?? .zero
            let parkedVsPlane = meanChannelDifference(inPlaneReference, parkedReference)
            if let dir = ProcessInfo.processInfo.environment["TILE_SURFACE_DUMP_DIR"] {
                func write(_ image: CGImage, _ name: String) {
                    let rep = NSBitmapImageRep(cgImage: image)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                    }
                }
                write(inPlaneReference, "plane-\(Int(size.width)).png")
                write(parkedReference, "parked-\(Int(size.width)).png")
            }

            var parkedClean: [Double] = []
            for tile in tiles {
                let target = try body(tile.id)
                let rev = try revision(tile.id)
                parkedClean.append(milliseconds { store.bake(tileId: tile.id, body: target, revision: rev) })
            }

            // Does a parked body stay CURRENT? The model does — that is slice 1's
            // claim and it holds — so the row count is asserted separately from the
            // pixels. Without that split a zero pixel delta is unreadable: it could
            // mean the content never arrived.
            let rowsBeforeParkedRefresh = transcript?.qaSemanticRowCount ?? 0
            var parkedRefresh: [Double] = []
            for (index, tile) in tiles.enumerated() {
                parkedRefresh.append(try refresh(tile.id, index: index, tag: "parked"))
            }
            guard let afterParkedRefresh = store.surface(for: tiles[0].id)?.image else {
                throw Failure(message: "bake cost: the parked refresh path stored no surface")
            }
            let rowsAfterParkedRefresh = transcript?.qaSemanticRowCount ?? 0
            let parkedRefreshDelta = meanChannelDifference(parkedReference, afterParkedRefresh)

            // The gate this finding earns: **no bake may be taken while a body is
            // parked.** Option A satisfies it by construction — the residency pass
            // bakes before it demotes and never after — and this pins it, because a
            // parked bake is not the body. See the published numbers below.
            // Every body here is parked and every surface is stale — the refresh loop
            // above ingested into all of them — which is exactly the state a caller
            // that baked before promoting would bake from. One production pass must
            // promote them all and bake none.
            let bakesBeforeReclaim = world.canvas.tileSurfaceStore.qaBakeCount
            world.canvas.evaluateTileResidency()
            world.pump()
            try expect(world.canvas.tileSurfaceStore.qaBakeCount == bakesBeforeReclaim,
                       "bake cost: production baked "
                       + "\(world.canvas.tileSurfaceStore.qaBakeCount - bakesBeforeReclaim) surfaces from "
                       + "PARKED bodies, which do not render what the native body renders")
            try expect(world.canvas.qaParkedBodyCount == 0,
                       "bake cost: the pass left \(world.canvas.qaParkedBodyCount) bodies parked behind "
                       + "stale surfaces — a stale surface is a picture of a state the tile no longer has")

            let cleanMs = p50(planeClean)
            let parkedCleanMs = p50(parkedClean)
            let refreshMs = p50(planeRefresh)
            let parkedRefreshMs = p50(parkedRefresh)
            let megapixels = Double(warmed.image.width * warmed.image.height) / 1_000_000
            let streamersPerFrame = parkedRefreshMs > 0 ? frameBudgetMs / parkedRefreshMs : .infinity
            let coreShare = parkedRefreshMs * refreshHz / 10

            print(String(
                format: "tile-surface-residency bake: body %.0fx%.0f -> %dx%d px (%.2f MP, %.0f KB, "
                + "50 tiles = %.0f MB) | clean bake p50 in-plane %.2f ms, parked %.2f ms (alloc %.2f / "
                + "draw %.2f) | streaming refresh p50 in-plane %.2f ms, parked %.2f ms | one visible "
                + "streamer at %.0f Hz = %.1f%% of one core | %.1f streamers fit an %.1f ms frame",
                size.width, size.height, warmed.image.width, warmed.image.height, megapixels,
                Double(warmed.byteCount) / 1_024, Double(warmed.byteCount) * 50 / 1_048_576,
                cleanMs, parkedCleanMs, p50(allocSamples), p50(drawSamples),
                refreshMs, parkedRefreshMs, refreshHz, coreShare, streamersPerFrame, frameBudgetMs
            ))

            try expect(store.qaBakeFailureCount == 0,
                       "bake cost: \(store.qaBakeFailureCount) bakes failed, so the timings are of nothing")
            try expect(refreshDelta > 0 && refreshDelta.isFinite,
                       String(format: "bake cost: a refresh must produce different pixels or it is a no-op "
                              + "being timed as a bake — mean channel difference %.4f", refreshDelta))
            // **The finding, and the reason Step 0 existed.** A parked body's pixels
            // are neither current nor equivalent, and the cause is one thing: the
            // transcript's scroll geometry degenerates once no ancestor places the body
            // in the visible area. Its `visibleRect` lands nowhere near its own content
            // (published below), so the collection view materialises no item for a row
            // that just arrived, and the offset it does present is not the offset the
            // native body presents. Sizing the park does not move it — the offset is
            // what degenerates, not the size.
            //
            // Both numbers are PUBLISHED, not gated. Gating "a parked refresh changes
            // pixels" would assert a behaviour the mechanism does not have; gating "it
            // does not" would freeze a defect into a requirement. The gate above — that
            // production never bakes a parked body — is the behaviour worth protecting,
            // and the row count is gated so this zero cannot be read as "no content
            // arrived".
            print(String(format: "tile-surface-residency bake: PARKED PIXELS ARE NOT THE BODY'S — parked "
                         + "vs in-plane bake of the same body at the same content, mean channel difference "
                         + "%.4f | parked refresh is FROZEN: rows %d -> %d, pixels unchanged (%.4f) | "
                         + "transcript visibleRect in plane %@ vs parked %@ against a %.0fpt document. "
                         + "A surfaced body cannot be re-baked in place; see .plans/37 Step 0.",
                         parkedVsPlane, rowsBeforeParkedRefresh, rowsAfterParkedRefresh, parkedRefreshDelta,
                         NSStringFromRect(planeVisibleRect), NSStringFromRect(parkedVisibleRect),
                         planeDocumentHeight))
            try expect(rowsAfterParkedRefresh > rowsBeforeParkedRefresh,
                       "bake cost: the parked model must still ingest content (\(rowsBeforeParkedRefresh) "
                       + "-> \(rowsAfterParkedRefresh) rows), or the frozen pixels above mean something else")
            // Instrument integrity, the same guard the demote breakdown carries: a
            // split that stops adding up turns a published number into fiction.
            let attributed = p50(allocSamples) + p50(drawSamples)
            try expect(attributed >= cleanMs * 0.6,
                       String(format: "bake cost: the alloc/draw split no longer explains the bake: "
                              + "%.2f ms attributed of %.2f ms measured", attributed, cleanMs))
        }
    }
}
