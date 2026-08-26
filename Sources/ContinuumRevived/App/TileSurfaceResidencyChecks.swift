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
            window.orderFrontOffscreenForChecks()

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
            // And visibility, ALWAYS — for the same reason. Production refuses to
            // bake a window the system is not showing (a body in a window with no
            // valid backing store bakes to nothing), and a borderless fixture
            // window ordered front in a check process genuinely reports NOT
            // visible: measured, every witness went to "0 of 6 surfaced" the
            // moment that guard landed. The occlusion witness overrides this to
            // drive the real transitions.
            canvas.occlusionVisibilityProvider = { true }
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
        try checkPointerJitterAtATileEdgeDoesNotFlap()
        try checkPixelEquivalence()
        try checkSharpnessHoldsDuringAGestureAndConvergesAtSettle()
        try checkContentWhileSurfacedPromotesAndSurvives()
        try checkClickOnASurfacedTileReachesTheBody()
        try checkFocusNeverLandsOnAPicture()
        try checkNothingIsStranded()
        try checkAppearanceChangeGivesTheBodyBack()
        try checkAccessibilityFindsTheRealBody()
        try checkAPassiveAccessibilitySweepPromotesNothing()
        try checkFileAndNoteTilesSurface()
        try checkAGestureThatBeginsAllNativeConvergesAtSettle()
        try checkSurfaceMemoryIsBounded()
        try checkLeavingTheWindowRestoresEveryBody()
        try checkParkedBodiesPaintNoPixels()
        try checkSurfacesAreNeverBlankAfterAParkRoundTrip()
        try checkNoBakeWhileTheWindowIsNotShown()
        try checkOcclusionPausesAndResumesResidency()
        try checkTheSurfaceLandsExactlyWhereTheBodyDrew()
        try checkAScrollIsNeverShownStale()
        try checkAZoomGestureCrossesResidencyAlmostNever()
        try checkCost()
        try checkBakeCost()
        // AFTER the timing legs on purpose: this witness bakes ~100 MB of dense
        // surfaces, and running it first shifted checkCost's marginal by +0.5 ms
        // (5.0-5.2 vs 4.5) purely through heap state — measured both orders,
        // same binary, 2026-08-19. Timing legs run on a clean heap.
        try checkOffscreenBakesAreCappedSoTheBudgetHoldsAtAnyZoom()
        try checkAWhaleBodyBakesBoundedAndNeverFlaps()
        try checkBudgetPressureDegradesInsteadOfStranding()
        print("tile-surface-residency check: ok")
    }

    /// **The picture has to sit exactly where the body sat.** A surfaced tile's
    /// host is framed at `(0, titleBarHeight)` inside the tile, and the host's
    /// hosted layer IS the view's root layer — AppKit's convention for which is the
    /// view's FRAME, in the superlayer's space. `layout()` wrote `bounds` instead,
    /// whose origin is `(0, 0)`, so every layout pass over a surfaced tile shoved
    /// the baked picture UP by the full title-bar height while the native body drew
    /// at the correct offset. Measured before the fix: correct at `(0, 24, 420, 276)`
    /// the instant the swap happened, then `(0, 0, 420, 276)` after one layout pass —
    /// and not on every tile in the same pass, which is why Dylan saw tiles shift
    /// intermittently rather than uniformly.
    ///
    /// Asserted through a real pump, because the corruption is the LAYOUT pass, not
    /// the swap: a witness that only looked at the swap turn reads green.
    private static func checkTheSurfaceLandsExactlyWhereTheBodyDrew() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()

        var checked = 0
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id],
                  let hostFrame = view.qaSurfaceHostFrame,
                  let layerFrame = view.qaSurfaceHostLayerFrame else { continue }
            checked += 1
            try expect(
                geometryNearlyEqual(layerFrame, hostFrame),
                "a surfaced tile's hosted layer must sit at the host's frame — the picture is "
                + "drawn where the body drew or it is drawn in the wrong place. host=\(hostFrame) "
                + "layer=\(layerFrame)"
            )
        }
        try expect(checked > 0, "nothing was surfaced, so this witness proved nothing")

        // And it must survive the camera: a reused host carries its layer geometry
        // across a gesture, so a zoom is the other way this can go wrong.
        for step in 1...4 {
            world.cameraStep(toZoom: 1.0 + 0.1 * Double(step))
            world.pump()
        }
        world.settle()
        world.pump()
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id],
                  let hostFrame = view.qaSurfaceHostFrame,
                  let layerFrame = view.qaSurfaceHostLayerFrame else { continue }
            try expect(
                geometryNearlyEqual(layerFrame, hostFrame),
                "after a zoom, a surfaced tile's hosted layer drifted from its host: "
                + "host=\(hostFrame) layer=\(layerFrame)"
            )
        }

        // No implicit animation may ride the swap either. The host is layer-HOSTING,
        // so AppKit is not the layer's delegate and nothing disables actions on it.
        // Measured empty before the geometry fix — recorded here so a future
        // `CATransaction`-less write cannot start animating the picture unnoticed.
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id], view.qaSurfaceHostFrame != nil else { continue }
            let keys = view.qaSurfaceHostLayerAnimationKeys
            try expect(keys.isEmpty,
                       "an implicit animation is riding the surface swap: \(keys)")
        }
    }

    /// **The number that tracks what Dylan actually feels: crossings per gesture.**
    ///
    /// Every other witness in this file asserts an END STATE, which is how a real
    /// session came to log **738 surface<->native crossings** in 2m45s — 253 policy
    /// promotions and 485 demotions, surface memory swinging 0 -> 62 MB, 70% of
    /// lines reporting a tile native while the policy wanted it surfaced — with the
    /// whole suite green. Each crossing is a visible blur<->sharp flip AND ~5 ms of
    /// AppKit subtree surgery, so the count IS the complaint: "SOOO much
    /// flickering/jitering tiles with the bluring/focusing".
    ///
    /// The ruling being witnessed (Dylan, 2026-08-19): during an active gesture
    /// tiles HOLD — soft is allowed, flipping is not — and converge ONCE at settle.
    private static func checkAZoomGestureCrossesResidencyAlmostNever() throws {
        // Both directions. Zoom-OUT is not a formality: it never fails the sharpness
        // test, so `zoomingIn` read false and the mid-gesture demotion budget opened
        // to 2 per pass — a witness that only zoomed in would call this fixed while
        // half the crossings continued.
        try expectNoCrossingsDuring(gesture: "zoom-in", from: 1.0, to: 2.0)
        try expectNoCrossingsDuring(gesture: "zoom-out", from: 1.0, to: 0.5)
    }

    private static func expectNoCrossingsDuring(
        gesture: String, from start: Double, to target: Double
    ) throws {
        let world = World(tileCount: 12)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: start))
        world.quiesceAndSurface()
        let surfaced = world.canvas.qaSurfacedTileViews.count
        try expect(surfaced == world.tiles.count,
                   "\(gesture): need every tile surfaced before the gesture, got "
                   + "\(surfaced) of \(world.tiles.count)")
        world.canvas.qaResetSurfaceResidencyCounters()

        // A real gesture: eight driver commits, a display pass each, and the 10 Hz
        // heartbeat interleaved — because the heartbeat running DURING a gesture is
        // half of where the crossings came from, and stubbing it out would hide that.
        let steps = 8
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            world.cameraStep(toZoom: start + (target - start) * t)
            world.pump()
            if step % 2 == 0 { world.evaluateResidency() }
        }

        let promotedDuring = world.canvas.qaSurfacePromotionCount
        let demotedDuring = world.canvas.qaSurfaceDemotionCount
        try expect(
            promotedDuring + demotedDuring == 0,
            "\(gesture): \(promotedDuring + demotedDuring) residency crossings DURING the "
            + "gesture (\(promotedDuring) promotions, \(demotedDuring) demotions). Every one "
            + "is a visible blur<->sharp flip plus ~10 ms of reparenting. Tiles are allowed to "
            + "go soft while the camera moves; they are not allowed to flip."
        )

        // Converge once. A tile that must re-sharpen inherently costs a promote AND a
        // demote, so the honest bound is one crossing per tile PER DIRECTION — what
        // is being forbidden is the cascade (56 tiles recovering 4 per pass over
        // 2.1 s), not the single convergence.
        world.settle()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        // THREE passes, not twelve. Dylan's report (2026-08-19): "seeing a tile
        // focus, blurry to hi res is [not] the best". The blur->sharp pops were
        // real and the parade was the artifact: promote 2/pass + bake 4/pass
        // sharpened a 20-tile view as seconds of individual pops. The contract is
        // ONE beat: the settle edge promotes every soft visible tile at once, and
        // the next pass re-bakes them all under the visible budget.
        world.evaluateResidency(passes: 3)
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id],
                  view.frame.intersects(world.canvas.qaVisibleWorldRect) else { continue }
            try expect(view.surfaceResidency == .surfaced,
                       "\(gesture): a visible tile is still mid-sharpen three passes after "
                       + "settle — the parade of pops is back")
        }

        let promoted = world.canvas.qaSurfacePromotionCount
        let demoted = world.canvas.qaSurfaceDemotionCount
        try expect(
            promoted <= world.tiles.count,
            "\(gesture): \(promoted) promotions to converge \(world.tiles.count) tiles — more "
            + "than one per tile means tiles crossed repeatedly, which is the cascade"
        )
        try expect(
            demoted <= world.tiles.count,
            "\(gesture): \(demoted) demotions to converge \(world.tiles.count) tiles — more "
            + "than one per tile means tiles crossed repeatedly, which is the cascade"
        )

        // And the end state still has to be right, or "no crossings" is just a
        // canvas that gave up.
        let settledSurfaced = world.canvas.qaSurfacedTileViews.count
        try expect(settledSurfaced == world.tiles.count,
                   "\(gesture): after settling, \(settledSurfaced) of \(world.tiles.count) tiles "
                   + "are surfaced — holding during the gesture must not strand tiles native")
        print("tile-surface-residency \(gesture): 0 crossings during the gesture, "
              + "\(promoted) promotions + \(demoted) demotions to converge \(world.tiles.count) tiles")
    }

    /// **A surface must never outlive the scroll position it was taken at.**
    ///
    /// `TileSurfaceRevision` is a CONTENT fingerprint — version, body size,
    /// appearance — and scrolling changes no content. So a surface baked at one
    /// offset still passed the freshness test after the body scrolled somewhere
    /// else, `surfaceIfAdmissible` skipped the bake, and the tile was handed back a
    /// perfectly faithful picture of where it used to be looking. That is the
    /// largest single displacement this design can produce and it reads as the tile
    /// jumping — `.plans/39` mechanism 1.
    ///
    /// Driven exactly as production reaches it, which is the whole point: the tile
    /// is promoted by the POINTER (so its content version never moves and its
    /// existing surface stays valid), scrolled while native, then left to fall
    /// quiet. A witness that instead scrolled a PARKED body would be asserting
    /// against degenerate clip geometry and would demand behaviour that thrashes.
    private static func checkAScrollIsNeverShownStale() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()

        guard let tile = world.tiles.first, let view = world.agentViews[tile.id] else {
            throw Failure(message: "fixture built no agent tile")
        }
        try expect(view.surfaceResidency == .surfaced,
                   "the tile must start surfaced or this witness has nothing to say")
        let staleImage = world.canvas.tileSurfaceStore.surface(for: tile.id)?.image
        try expect(staleImage != nil, "a surfaced tile must have a stored surface")

        // Rest the pointer on it: promoted for a reason that does not touch content,
        // so the surface it already has stays revision-fresh.
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        world.injectedPointer = view.convert(centre, to: nil)
        // Two passes: the first OBSERVES the pointer arriving, the second sees that
        // it has not moved for the rest delay. Rest is achieved, never just elapsed.
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.pointerRestDelay + 0.05)
        world.evaluateResidency()
        try expect(view.surfaceResidency == .native,
                   "a resting pointer must give the body back, or the scroll below is not real")
        try expect(world.canvas.tileSurfaceStore.surface(for: tile.id)?.image === staleImage,
                   "the surface must still be the one baked before the scroll, else this "
                   + "witness cannot tell a re-bake from a replacement")

        // Scroll where the user would: a native body, in the plane.
        let offsetsBefore = view.surfaceScrollOffsets
        view.qaScrollTranscript(toY: 180)
        world.pump()
        try expect(view.surfaceScrollOffsets != offsetsBefore,
                   "the fixture did not actually scroll (\(offsetsBefore) -> "
                   + "\(view.surfaceScrollOffsets)), so nothing was tested")

        // Let it fall quiet. The surface it is offered is revision-fresh and sharp,
        // so ONLY the scroll comparison can refuse it.
        world.injectedPointer = nil
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 3)
        try expect(view.surfaceResidency == .surfaced,
                   "the tile must come back to a surface once it is quiet again")

        guard let shown = world.canvas.tileSurfaceStore.surface(for: tile.id) else {
            throw Failure(message: "a surfaced tile must have a stored surface")
        }
        try expect(shown.image !== staleImage,
                   "the tile re-surfaced with the very picture taken before the scroll — a "
                   + "faithful image of a position the body has left")
        try expect(shown.bakedScrollOffsets == view.surfaceScrollOffsets,
                   "the installed surface does not record the body's current scroll position "
                   + "(\(shown.bakedScrollOffsets) vs \(view.surfaceScrollOffsets)), so the next "
                   + "scroll can be missed the same way")
    }

    private static func geometryNearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.01 && abs(lhs.origin.y - rhs.origin.y) < 0.01
            && abs(lhs.width - rhs.width) < 0.01 && abs(lhs.height - rhs.height) < 0.01
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

    /// Exit hysteresis on the pointer clause, because entry hysteresis alone
    /// FLAPPED in production: a cursor jittering at a tile edge (a thumb resting
    /// on the trackpad is enough) promoted and demoted the same tile several
    /// times a second, for minutes, on an idle canvas — each cycle a ~10 ms
    /// reparent pair plus a damaged window for WindowServer to recomposite.
    /// Attributed live on 2026-08-19: `native by: [pointerResting 1]` and
    /// `native by: []` alternating at up to 5 Hz with surface bytes constant.
    ///
    /// The rule mirrors the accessibility clause: once a tile is native for a
    /// RESTING pointer, it stays native until the pointer has been away for the
    /// quiet delay. A sweep still promotes nothing — lingering is keyed on rest
    /// having been achieved, never on mere transit.
    private static func checkPointerJitterAtATileEdgeDoesNotFlap() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "the jitter witness needs every tile surfaced first")
        guard let view = world.agentViews[world.tiles[0].id] else {
            throw Failure(message: "fixture tile 0 has no view")
        }
        let inside = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        // The gutter just past the tile's edge — still no other tile there.
        let outside = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.maxY + 30), to: nil)

        // Rest inside long enough to promote — that half is designed behaviour.
        world.injectedPointer = inside
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.pointerRestDelay + 0.05)
        world.evaluateResidency()
        try expect(view.surfaceResidency == .native, "a rested pointer must promote its tile")

        // Jitter: out for one pass, back in long enough to rest again, repeatedly.
        // This is the flap's exact shape, and it must cost NOTHING after the
        // initial promotion.
        world.canvas.qaResetSurfaceResidencyCounters()
        for _ in 0..<6 {
            world.injectedPointer = outside
            world.advance(0.1)
            world.evaluateResidency()
            world.injectedPointer = inside
            world.advance(0.1)
            world.evaluateResidency()
            world.advance(0.1)
            world.evaluateResidency()
            // Long enough inside to REST again (0.2 s since the first inside
            // pass), so the unfixed policy re-promotes and the cycle is the real
            // flap — promote, demote, promote — not a single demotion.
            world.advance(0.1)
            world.evaluateResidency()
        }
        try expect(world.canvas.qaSurfaceDemotionCount == 0,
                   "pointer jitter at a tile edge cost \(world.canvas.qaSurfaceDemotionCount) demotions "
                   + "— that is the resting-pointer flap, reparenting an idle canvas at up to 5 Hz")
        try expect(view.surfaceResidency == .native,
                   "the tile under a jittering-but-present pointer must stay native")

        // And the linger ends: once the pointer is genuinely gone, the tile
        // surfaces again — this is hysteresis, not a leak of native residency.
        world.injectedPointer = nil
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 3)
        try expect(view.surfaceResidency == .surfaced,
                   "after the pointer leaves for good the tile must surface again")
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

    /// Zooming IN past what the surfaces carry must NOT flip anything while the
    /// camera moves, and must converge once it settles.
    ///
    /// **This witness was rewritten, and the old guarantee is gone deliberately.**
    /// It used to assert that each camera step promoted exactly
    /// `maxSharpnessPromotionsPerStep` tiles and that every step made progress —
    /// i.e. it asserted the storm was SPREAD OUT rather than absent. A real session
    /// then measured 738 surface<->native crossings in 2m45s and Dylan reported it
    /// as "SOOO much flickering/jitering tiles with the bluring/focusing": one
    /// promotion per camera step is one visible blur->sharp flip per step, so the
    /// spread-out storm was itself the artifact. Its per-step clauses would now be
    /// vacuously green (nothing crosses mid-gesture), which is worse than deleted.
    ///
    /// The guarantee now witnessed: tiles may go progressively soft during a
    /// gesture, the softness is COUNTED so it cannot become permanent unnoticed,
    /// nothing crosses until the camera stops, and the settled heartbeat converges
    /// every tile back to a sharp surface at a bounded rate. Kept from the old
    /// version: the per-pass catch-up cap (a storm moved to the settle edge is still
    /// a storm), the re-bake density assertion, and the convergence/no-thrash
    /// clause. Dropped from it: the nearest-anchor ORDERING assertion, because
    /// mid-gesture ordering no longer has anything to order — the settled catch-up
    /// walks `surfacedTiles` unordered, and asserting an order the code does not
    /// implement would be fiction. Center-out settle ordering is a separate,
    /// unimplemented step.
    private static func checkSharpnessHoldsDuringAGestureAndConvergesAtSettle() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "need every tile surfaced before zooming in")
        let bakedScale = world.canvas.tileSurfaceStore.surface(for: world.tiles[0].id)?.bakedScale ?? 0
        try expect(bakedScale > 0, "a stored surface must know its own density")

        // A fresh bake must satisfy its OWN sharpness test at the zoom it was taken
        // at. `bakedScale` is `rep.pixelsWide / bounds.width`, whose quantum for a
        // 420 pt body is ~0.0024 — twenty-four times the 0.0001 epsilon in
        // `isSharpEnough`. If AppKit ever rounded that pixel width DOWN, a surface
        // would fail its own test at its own zoom and re-bake forever. It rounds up
        // today; this pins that, because nothing else does.
        let backingAtBake = world.window.backingScaleFactor
        try expect(
            world.canvas.tileSurfaceStore.surface(for: world.tiles[0].id)?
                .isSharpEnough(forZoom: world.canvas.viewport.zoom, backingScale: backingAtBake) == true,
            "a surface baked at this very zoom does not satisfy its own sharpness test — "
            + "bakedScale \(bakedScale) against zoom \(world.canvas.viewport.zoom) x "
            + "backing \(backingAtBake). That is an unbounded re-bake loop."
        )

        world.canvas.qaResetSurfaceResidencyCounters()
        let backing = world.window.backingScaleFactor
        let tooSharp = Double(bakedScale / backing) * 2
        let anchor = CGPoint(x: 800, y: 500)
        world.cameraStep(toZoom: tooSharp, anchor: anchor)
        world.pump()

        // 1. The hold: a step that makes every surface too soft crosses NOTHING.
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "a mid-gesture step promoted \(world.canvas.qaSurfacePromotionCount) tiles — under "
                   + "the hold, tiles go soft while the camera moves and flip only when it stops")
        try expect(world.canvas.qaSurfaceDemotionCount == 0,
                   "a mid-gesture step demoted \(world.canvas.qaSurfaceDemotionCount) tiles — a demote "
                   + "is a sharp body becoming a picture, which is just as visible as the reverse")

        // 2. And the softness it chose is OBSERVABLE. A hold that silences its own
        // instrument is how "briefly soft" becomes "soft forever" with every gate
        // green, so the deferral count is the thing that makes the trade auditable.
        try expect(world.canvas.qaSurfaceSharpnessDeferredCount > 0,
                   "the tiles left soft by the hold must be counted, or softness and a stall "
                   + "are indistinguishable from outside")

        // 3. Still nothing on a later step — the hold is for the whole gesture, not
        // a one-step rate limit.
        world.cameraStep(toZoom: tooSharp * 1.05, anchor: anchor)
        world.pump()
        world.evaluateResidency()
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "a second mid-gesture step promoted \(world.canvas.qaSurfacePromotionCount) — the hold "
                   + "must cover the gesture, and the 10 Hz heartbeat running inside it must not "
                   + "cross either")
        try expect(world.canvas.qaSurfaceDemotionCount == 0,
                   "the heartbeat demoted \(world.canvas.qaSurfaceDemotionCount) tiles mid-gesture")

        // 4. Settle: every deferred tile sharpens in ONE beat. This REVERSES the
        // clause that stood here ("a storm moved to the settle edge is still a
        // storm", cap 2 per pass): rationing the recovery turned one gesture's
        // sharpen into seconds of one-by-one blur->sharp pops, which is exactly
        // what Dylan rejected (2026-08-19, "blurry to hi res is [not] the best").
        // The settle edge now promotes every soft in-lead tile together, and the
        // visible bake budget returns them together — so the allowance is THREE
        // passes, total, before every tile is surfaced sharp again. The old
        // anti-storm concern survives as the crossing bound: one promote and one
        // demote per tile per gesture, never more (asserted below and in the
        // zoom-crossing witness).
        world.settle() // fires cameraGestureDidSettle: the sweep plus one pass
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 2)
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "after settling zoomed IN, every quiet tile must be re-baked and surfaced within "
                   + "three passes of the settle edge: \(world.canvas.qaSurfacedTileViews.count) of "
                   + "\(world.tiles.count) surfaced — the one-by-one pop parade is back")
        try expect(world.canvas.qaSurfacePromotionCount <= world.tiles.count,
                   "\(world.canvas.qaSurfacePromotionCount) promotions to sharpen \(world.tiles.count) "
                   + "tiles — more than one per tile is a flap, which is the storm that matters")
        let backingNow = world.window.backingScaleFactor
        for tile in world.tiles {
            guard let rebaked = world.canvas.tileSurfaceStore.surface(for: tile.id) else {
                throw Failure(message: "a re-surfaced tile has no surface behind it")
            }
            try expect(rebaked.isSharpEnough(forZoom: world.canvas.viewport.zoom, backingScale: backingNow),
                       "the re-bake must carry the density the current zoom needs")
        }
        // And it converges: nothing changed, so further passes bake nothing.
        let bakesAfter = world.canvas.tileSurfaceStore.qaBakeCount
        world.evaluateResidency(passes: 6)
        try expect(world.canvas.tileSurfaceStore.qaBakeCount == bakesAfter,
                   "the too-soft re-bake thrashes: \(world.canvas.tileSurfaceStore.qaBakeCount - bakesAfter) "
                   + "extra bakes on a canvas where nothing changed")
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

        let bytesWhileSurfaced = world.canvas.tileSurfaceStore.totalBytes
        world.window.appearance = NSAppearance(named: .darkAqua)
        world.pump()
        world.evaluateResidency()
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "an appearance change left \(world.canvas.qaSurfacedTileViews.count) tiles showing a "
                   + "light-mode picture")
        try expect(world.canvas.qaSurfaceStalePromotionCount == world.tiles.count,
                   "the promotions must be attributed to STALENESS, not to a liveness clause: "
                   + "\(world.canvas.qaSurfaceStalePromotionCount) of \(world.tiles.count)")
        // And the pixels of the appearance nobody is in any more do not stay
        // resident. A stale surface will be re-baked before it is shown again, so
        // holding it is memory with no reader.
        try expect(world.canvas.tileSurfaceStore.totalBytes == 0,
                   "stale surfaces stayed resident: "
                   + "\(world.canvas.tileSurfaceStore.totalBytes / 1_024) KB of "
                   + "\(bytesWhileSurfaced / 1_024) KB survived a whole-canvas invalidation")
        print(String(format: "tile-surface-residency: %d surfaces held %.0f KB, dropped to %.0f KB when "
                     + "the appearance changed",
                     world.tiles.count, Double(bytesWhileSurfaced) / 1_024,
                     Double(world.canvas.tileSurfaceStore.totalBytes) / 1_024))

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
        // This witness is the ASSISTIVE arm; the passive arm is the next check.
        let originalProvider = TileNSView.assistiveClientActive
        defer { TileNSView.assistiveClientActive = originalProvider }
        TileNSView.assistiveClientActive = { true }
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

    /// **A passive accessibility sweep promotes nothing.** The hand-the-body-back
    /// rule above was written for VoiceOver, but the AX API has passive clients —
    /// launchers, window managers, screen recorders — that walk the whole tree with
    /// no user behind them. Measured live (2026-08-19): one such sweep touched all
    /// 83 tiles in a pass, every surface on the canvas handed its body back at
    /// once, and the 4-bake-per-pass recovery spent twenty seconds flipping tiles
    /// while a zoom ran through it at 5 fps. So the body is handed back only when
    /// an assistive client is genuinely active; a passive sweeper still gets the
    /// tile (and its read is still counted for the log), but nothing on screen
    /// moves.
    private static func checkAPassiveAccessibilitySweepPromotesNothing() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        let originalProvider = TileNSView.assistiveClientActive
        defer { TileNSView.assistiveClientActive = originalProvider }
        TileNSView.assistiveClientActive = { false }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        world.canvas.qaResetSurfaceResidencyCounters()

        // The sweep: every tile read, twice, the way a full-tree walker does.
        for _ in 0..<2 {
            for tile in world.tiles {
                _ = world.agentViews[tile.id]?.accessibilityChildren()
            }
        }
        for tile in world.tiles {
            try expect(world.agentViews[tile.id]?.surfaceResidency == .surfaced,
                       "a passive AX sweep made a tile hand its body back with no assistive client")
        }

        // And the residency pass must not finish the job: the reads were counted,
        // but with no assistive client they are not liveness.
        world.evaluateResidency(passes: 2)
        world.advance(0.3)
        world.evaluateResidency(passes: 2)
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "\(world.canvas.qaSurfacePromotionCount) promotions after a passive sweep — the "
                   + "policy treated counted reads as liveness with no assistive client attached")
        for tile in world.tiles {
            try expect(world.agentViews[tile.id]?.surfaceResidency == .surfaced,
                       "the residency pass took a body back after a passive AX sweep")
        }
    }

    /// **Density follows visibility, so the byte budget holds at any zoom.**
    ///
    /// Bakes happen in-plane, so `cacheDisplay` renders at zoom x backing no matter
    /// who will see the result. At zoom 2 that is ~8 MB per 420x300 tile — a full
    /// canvas needs ~650 MB against a 256 MB budget. Measured live (2026-08-19):
    /// once the budget filled, every native tile's re-bake was refused
    /// (refusedMemory 2 -> 225, evictions 0), so tiles stranded native and the
    /// surfaced count bled 83 -> 59 while each stranded body made gestures heavier.
    ///
    /// The rule: a tile OUTSIDE the lead rect only needs `offscreenBakeZoomCap`
    /// density — softness nobody can see costs nothing, and the lead-rect catch-up
    /// re-bakes it at full density just before it arrives on screen.
    private static func checkOffscreenBakesAreCappedSoTheBudgetHoldsAtAnyZoom() throws {
        let world = World(tileCount: 18)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        let backing = world.window.backingScaleFactor

        func leadRect() -> CGRect {
            let vp = world.canvas.viewport
            let visible = CGRect(
                x: vp.x, y: vp.y,
                width: 1_600 / CGFloat(vp.zoom), height: 1_000 / CGFloat(vp.zoom)
            )
            return visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25)
        }
        func frames(inLead: Bool) -> [Tile] {
            world.tiles.filter {
                CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)
                    .intersects(leadRect()) == inLead
            }
        }

        // A real zoom to 2, settled — the state that filled the budget in production.
        for step in 1...8 {
            _ = world.cameraStep(toZoom: 1.0 + 0.125 * Double(step))
            world.pump()
        }
        world.settle()
        world.evaluateResidency(passes: 6)

        let inLead = frames(inLead: true)
        let outOfLead = frames(inLead: false)
        try expect(inLead.count >= 3 && outOfLead.count >= 3,
                   "the fixture must straddle the lead rect (in \(inLead.count), out \(outOfLead.count)) "
                   + "or this witness tests nothing")

        // The production path that stranded tiles: every tile native, then allowed
        // back. Off-screen tiles must come back CHEAP; on-screen ones dense.
        for tile in world.tiles { world.agentViews[tile.id]?.promoteBodyToNative() }
        world.advance(0.3)
        world.evaluateResidency(passes: 10)

        let full = CGFloat(2.0) * backing
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id] else { continue }
            try expect(view.surfaceResidency == .surfaced,
                       "tile at y=\(tile.frame.y) is still native after 10 settled passes — "
                       + "the state that bled the canvas in production")
        }
        for tile in inLead {
            let scale = world.canvas.tileSurfaceStore.surface(for: tile.id)?.bakedScale ?? 0
            try expect(scale + 0.01 >= full,
                       "an on-screen tile at y=\(tile.frame.y) is surfaced at \(scale), "
                       + "softer than the zoom needs (\(full))")
        }
        for tile in outOfLead {
            let scale = world.canvas.tileSurfaceStore.surface(for: tile.id)?.bakedScale ?? 0
            try expect(scale <= backing * 1.01,
                       "an OFF-SCREEN tile at y=\(tile.frame.y) baked at \(scale) — full zoom "
                       + "density for a tile nobody can see is what fills the budget")
        }

        let bytesAtDenseConvergence = world.canvas.tileSurfaceStore.totalBytes

        // The arithmetic the budget depends on: bytes scale with the VISIBLE set.
        let denseBytes = world.tiles.count
            * Int(420 * full) * Int(300 * full) * 4
        try expect(world.canvas.tileSurfaceStore.totalBytes < denseBytes * 65 / 100,
                   "\(world.canvas.tileSurfaceStore.totalBytes) bytes held vs \(denseBytes) if "
                   + "everything baked dense — the cap saved less than a third")

        // The upgrade path: zoom out enough that a capped row enters the lead, and
        // it must be re-baked to the new requirement, not left visibly soft.
        for step in 1...4 {
            _ = world.cameraStep(toZoom: 2.0 - 0.225 * Double(step))
            world.pump()
        }
        world.settle()
        world.advance(0.3)
        world.evaluateResidency(passes: 10)
        let nowNeeded = CGFloat(1.1) * backing
        for tile in frames(inLead: true) {
            guard world.agentViews[tile.id]?.surfaceResidency == .surfaced else { continue }
            let scale = world.canvas.tileSurfaceStore.surface(for: tile.id)?.bakedScale ?? 0
            // Within one sharpness band of the requirement, not exactly at it:
            // the band exists so a nudge does not re-bake the world, and this
            // clause must not pin the exactness the band deliberately removed.
            try expect(scale * TileSurface.sharpnessTolerance + 0.01 >= nowNeeded,
                       "a tile that entered the lead at y=\(tile.frame.y) is showing \(scale) "
                       + "against a needed \(nowNeeded) — beyond the band, and never re-baked")
        }

        // The other half of the budget holding: surfaces DENSER than their tile's
        // current requirement give the bytes back, in place, with zero flips.
        // One deep zoom-in left enough over-dense survivors to pin the budget
        // after the zoom back out (261 MB held, refusedMemory in the thousands,
        // measured live 2026-08-19). The slims run as the requirement falls, so
        // the count is read across the whole zoom-out and the no-flip clause is
        // pinned on fresh counters over settled housekeeping passes.
        try expect(world.canvas.qaSurfaceSlimCount > 0,
                   "no surface was slimmed though the zoom-out dropped every tile's requirement")
        for step in 1...2 {
            _ = world.cameraStep(toZoom: 1.1 - 0.05 * Double(step))
            world.pump()
        }
        world.settle()
        world.advance(0.3)
        world.canvas.qaResetSurfaceResidencyCounters()
        world.evaluateResidency(passes: 14)
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "\(world.canvas.qaSurfacePromotionCount) promotions during byte housekeeping — "
                   + "a slim must never flip a tile")
        let bytesAfterSlim = world.canvas.tileSurfaceStore.totalBytes
        try expect(bytesAfterSlim < bytesAtDenseConvergence * 6 / 10,
                   "slims reclaimed too little: \(bytesAtDenseConvergence) -> \(bytesAfterSlim) bytes")
        let restNeed = CGFloat(1.0) * backing
        for tile in world.tiles {
            try expect(world.agentViews[tile.id]?.surfaceResidency == .surfaced,
                       "a tile ended native after slimming — housekeeping changed residency")
            let scale = world.canvas.tileSurfaceStore.surface(for: tile.id)?.bakedScale ?? 0
            try expect(scale <= restNeed * 1.30,
                       "a tile at y=\(tile.frame.y) still holds \(scale) against a zoom-1.0 "
                       + "requirement of \(restNeed) — its dense bytes were never given back")
        }
    }

    /// **A huge body's bake is byte-bounded, and the bound never causes a flap.**
    ///
    /// The lead test is binary and a bake is whole-body, so at deep zoom a
    /// barely-on-screen 900x900 body would bake tens of MB for pixels mostly
    /// nobody sees. `maxBytesPerBakedSurface` caps the scale such a bake is asked
    /// for — and the cap MUST flow through the same `requiredSurfaceScale` the
    /// sharpness catch-up judges by, or a capped tile fails a sharpness test no
    /// bake is allowed to fix and flaps native<->surfaced forever.
    private static func checkAWhaleBodyBakesBoundedAndNeverFlaps() throws {
        let world = World(tileCount: 4, tileSize: CGSize(width: 900, height: 900))
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        for step in 1...8 {
            _ = world.cameraStep(toZoom: 1.0 + 0.125 * Double(step))
            world.pump()
        }
        world.settle()
        world.advance(0.3)
        world.evaluateResidency(passes: 10)

        let cap = world.canvas.residencyTuning.maxBytesPerBakedSurface
        for tile in world.tiles {
            guard let surface = world.canvas.tileSurfaceStore.surface(for: tile.id) else {
                throw Failure(message: "a whale tile has no surface at all after convergence")
            }
            try expect(surface.byteCount <= cap * 105 / 100,
                       "a whale bake holds \(surface.byteCount) bytes against a \(cap) cap")
            try expect(world.agentViews[tile.id]?.surfaceResidency == .surfaced,
                       "a whale tile is stranded native — the cap must bound bytes, not residency")
        }

        // The flap guard: converged means CONVERGED. If the catch-up judged by
        // uncapped zoom sharpness, every pass would promote a tile whose best
        // allowed bake it just refused.
        world.canvas.qaResetSurfaceResidencyCounters()
        for _ in 0..<6 {
            world.advance(0.15)
            world.evaluateResidency()
        }
        try expect(world.canvas.qaSurfacePromotionCount == 0,
                   "\(world.canvas.qaSurfacePromotionCount) promotions on a converged canvas — "
                   + "a byte-capped tile is flapping against a sharpness test it can never pass")
    }

    /// **Budget pressure degrades the bake, never the residency.** A refused tile
    /// stays native, and stranded natives are what the lag is made of (~4.5 ms per
    /// native tile per camera step, measured live 2026-08-19). Under pressure the
    /// ask drops to rest density — a fraction of the bytes, soft only until the
    /// slim pass frees room — and the tile still surfaces.
    private static func checkBudgetPressureDegradesInsteadOfStranding() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        let backing = world.window.backingScaleFactor
        for step in 1...8 {
            _ = world.cameraStep(toZoom: 1.0 + 0.125 * Double(step))
            world.pump()
        }
        world.settle()
        world.advance(0.3)
        world.evaluateResidency(passes: 8)

        // Room for a rest-density bake of one tile, but nowhere near a dense one.
        let tile = world.tiles[0]
        guard let view = world.agentViews[tile.id] else {
            throw Failure(message: "the degrade witness lost its tile view")
        }
        view.promoteBodyToNative()
        world.canvas.tileSurfaceStore.drop(tile.id)
        world.canvas.residencySurfaceByteBudget =
            world.canvas.tileSurfaceStore.totalBytes + (3 << 20)
        world.canvas.qaResetSurfaceResidencyCounters()
        world.advance(0.3)
        world.evaluateResidency(passes: 4)

        try expect(view.surfaceResidency == .surfaced,
                   "under budget pressure the tile stranded native instead of degrading its bake")
        try expect(world.canvas.qaSurfaceDegradedBakeCount > 0,
                   "the tile surfaced but no degraded bake was counted — the budget was not actually tight")
        try expect(world.canvas.qaSurfaceRefusedMemoryCount == 0,
                   "memory refusals under a budget a rest bake fits — degradation did not engage")
        let scale = world.canvas.tileSurfaceStore.surface(for: tile.id)?.bakedScale ?? 0
        try expect(scale <= backing * 1.01,
                   "a degraded bake claims scale \(scale), denser than rest (\(backing))")
    }

    /// **Resident surface memory is bounded, and bounding it costs nothing a user
    /// can see.**
    ///
    /// Measured in a real workspace, not extrapolated: 10.4 MB per surface for a
    /// 760x900 agent body, so six large tiles held 62 MB and fifty would hold half a
    /// gigabyte. The cap is enforced by handing the FARTHEST tiles their real bodies
    /// back — which costs camera time (~2.9 ms per live tile per step) and changes
    /// nothing visible. Evicting means promoting: the host holds the same `CGImage`
    /// the store does, so dropping the store entry alone would free nothing.
    private static func checkSurfaceMemoryIsBounded() throws {
        let world = World(tileCount: 8)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface(passes: 8)
        let unbounded = world.canvas.tileSurfaceStore.totalBytes
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "the budget witness needs every tile surfaced first")
        try expect(unbounded > 0, "no surfaces were held, so there is no memory to bound")

        // A budget that fits about half of them.
        let budget = unbounded / 2
        world.canvas.residencySurfaceByteBudget = budget
        world.canvas.qaResetSurfaceResidencyCounters()
        world.evaluateResidency()

        try expect(world.canvas.tileSurfaceStore.totalBytes <= budget,
                   "surfaces stayed at \(world.canvas.tileSurfaceStore.totalBytes / 1_024) KB over a "
                   + "\(budget / 1_024) KB budget")
        try expect(world.canvas.qaSurfaceEvictionCount > 0,
                   "nothing was evicted, so the budget was met by accident rather than by policy")
        // Evicted tiles are NATIVE, not blank. A surfaced tile with no surface would
        // be a picture with no source.
        for tile in world.tiles {
            let view = world.agentViews[tile.id]
            if view?.surfaceResidency == .surfaced {
                try expect(world.canvas.tileSurfaceStore.surface(for: tile.id) != nil,
                           "a tile is surfaced with no surface behind it")
            }
        }
        try expect(world.canvas.qaParkedBodyCount == world.canvas.qaSurfacedTileViews.count,
                   "the park and the surfaced set disagree after eviction: "
                   + "\(world.canvas.qaParkedBodyCount) parked, "
                   + "\(world.canvas.qaSurfacedTileViews.count) surfaced")

        // The near ones survive: eviction is farthest-first, so what is left holding
        // surfaces is what the camera is actually moving.
        let centre = CGPoint(x: world.canvas.qaWorldPlaneBounds.midX,
                             y: world.canvas.qaWorldPlaneBounds.midY)
        func distance(_ view: TileNSView) -> CGFloat {
            hypot(view.frame.midX - centre.x, view.frame.midY - centre.y)
        }
        let survivors = world.canvas.qaSurfacedTileViews.map(distance)
        let evicted = world.tiles.compactMap { world.agentViews[$0.id] }
            .filter { $0.surfaceResidency == .native }.map(distance)
        if let nearestEvicted = evicted.min(), let farthestSurvivor = survivors.max() {
            try expect(farthestSurvivor <= nearestEvicted + 1,
                       String(format: "eviction was not farthest-first: a surface survived at %.0f pt "
                              + "while one was evicted at %.0f pt", farthestSurvivor, nearestEvicted))
        }
        // **And it must CONVERGE.** Eviction alone thrashes: the pass bakes, the
        // budget evicts the farthest, and 100 ms later those tiles are still quiet
        // and get baked again — forever, at ~2 ms a bake and ~5 ms a reparent. So
        // the budget is also enforced BEFORE baking, and the witness is that a
        // steady canvas over budget stops doing work.
        let bakesAfterEviction = world.canvas.tileSurfaceStore.qaBakeCount
        world.evaluateResidency(passes: 10)
        try expect(world.canvas.tileSurfaceStore.qaBakeCount == bakesAfterEviction,
                   "the budget thrashes: 10 further passes baked "
                   + "\(world.canvas.tileSurfaceStore.qaBakeCount - bakesAfterEviction) more surfaces on a "
                   + "canvas where nothing changed")
        try expect(world.canvas.qaSurfaceRefusedMemoryCount > 0,
                   "no bake was refused for memory, so convergence came from somewhere else")
        try expect(world.canvas.tileSurfaceStore.totalBytes <= budget,
                   "bytes drifted back over budget across repeated passes")

        print(String(format: "tile-surface-residency: %d surfaces held %.0f KB; under a %.0f KB budget "
                     + "%d were evicted, leaving %.0f KB",
                     world.tiles.count, Double(unbounded) / 1_024, Double(budget) / 1_024,
                     world.canvas.qaSurfaceEvictionCount,
                     Double(world.canvas.tileSurfaceStore.totalBytes) / 1_024))
    }

    /// **File and note tiles surface too, and hand their bodies back for focus.**
    ///
    /// The real-gesture profile put the single heaviest body in a markdown FILE
    /// tile — a 183-block document re-measuring inside the camera cascade — and
    /// notes are static text except while focused. Both families now opt in, and
    /// each carries the two hazards this witness pins: their `acquireFocus`
    /// overrides target views inside the (possibly parked) body directly, and the
    /// file tile SWAPS its content view between modes, which would replace the
    /// surface host and strand the parked body without its promote-first guard.
    private static func checkFileAndNoteTilesSurface() throws {
        let world = World(tileCount: 2)
        defer { world.teardown() }

        let markdownPath = NSTemporaryDirectory() + "surface-residency-\(UUID().uuidString).md"
        let markdown = "# A document\n\n" + String(
            repeating: "A paragraph long enough to wrap and to cost something to measure. ", count: 20
        )
        try markdown.write(toFile: markdownPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: markdownPath) }

        var fileMetadata = TileMetadata()
        fileMetadata.filePath = markdownPath
        let zoneId = world.layer.placement.zoneId
        let fileTile = Tile(
            id: UUID(), kind: .file, title: "readme.md",
            frame: TileFrame(x: 40, y: 800, width: 420, height: 300),
            zPosition: .fromLegacyRank(90), zoneId: zoneId, runtimeRef: nil, metadata: fileMetadata
        )
        let noteTile = Tile(
            id: UUID(), kind: .note, title: "note",
            frame: TileFrame(x: 520, y: 800, width: 420, height: 300),
            zPosition: .fromLegacyRank(91), zoneId: zoneId, runtimeRef: nil, metadata: TileMetadata()
        )
        let fileView = FileTileNSView(tile: fileTile)
        let noteView = NoteTileNSView(tile: noteTile, noteId: UUID(), initialBody: "static note text")
        world.layer.tileViews[fileTile.id] = fileView
        world.layer.tiles.append(fileTile)
        world.layer.tileViews[noteTile.id] = noteView
        world.layer.tiles.append(noteTile)
        world.canvas.setZones([world.layer])
        world.canvas.surfaceResidencyEnabled = true
        world.pump()

        world.quiesceAndSurface()
        try expect(fileView.surfaceResidency == .surfaced,
                   "a quiet markdown file tile must surface — it was the heaviest body in the profile")
        try expect(noteView.surfaceResidency == .surfaced, "a quiet note tile must surface")

        // Focus lands on the real body, not the picture — through each family's own
        // override, which targets an inner view directly.
        _ = noteView.acquireFocus(reason: .userClick)
        world.pump()
        try expect(noteView.surfaceResidency == .native,
                   "focusing a surfaced note must promote it first")
        guard let responder = world.window.firstResponder as? NSView else {
            throw Failure(message: "note focus landed on no view")
        }
        try expect(responder.isDescendant(of: noteView),
                   "the note's first responder is not inside the note tile")
        // And the policy holds it native while focused.
        world.evaluateResidency()
        try expect(noteView.surfaceResidency == .native,
                   "a focused note was demoted under the user's cursor")

        // Editing bumps the revision, so the pre-edit surface can never be shown.
        let revisionBefore = noteView.currentSurfaceRevision
        noteView.textView.insertText("more", replacementRange: NSRange(location: 0, length: 0))
        try expect(noteView.currentSurfaceRevision != revisionBefore,
                   "a note edit must invalidate its surface revision")

        // The file tile's programmatic mode switch swaps the content view; the
        // promote-first guard is what keeps that from replacing the surface host.
        try expect(fileView.surfaceResidency == .surfaced, "precondition: file tile still surfaced")
        fileView.setMode(.edit)
        world.pump()
        try expect(fileView.surfaceResidency == .native,
                   "a mode switch on a surfaced file tile must promote before swapping the body")
        try expect(fileView.qaParkedBody == nil,
                   "the mode switch stranded the previous body in the park")
        try expect(fileView.contentView !== nil && fileView.surfaceableBody === fileView.contentView,
                   "after the swap the tracked body must be the installed content view")

        world.window.makeFirstResponder(nil)
    }

    /// **A gesture that begins all-native must converge — at the settle edge, not
    /// during the gesture.**
    ///
    /// This is a deliberate behaviour REVERSAL, and the reason is worth keeping.
    /// This witness used to assert the opposite: that mid-gesture passes clawed
    /// tiles back two at a time, because a real 96-step zoom once ran every frame
    /// over eight native transcripts (~3 ms each) after a previous zoom-in had
    /// promoted them, and one demotion paid for itself in two frames.
    ///
    /// That trade no longer applies, because its own precondition is gone: the tiles
    /// in that story were native "because the previous zoom-in had promoted them",
    /// and the hold is precisely what stops a zoom-in promoting anything. What is
    /// still native across a gesture is native for a LIVE reason — streaming, focus,
    /// a resting pointer — which a demote sweep should never have been touching. And
    /// a demotion is a sharp body becoming a picture: as visible as the promotion in
    /// the other direction, which is what Dylan was reporting as flicker.
    ///
    /// So the protective intent is preserved exactly — nothing may be left stranded
    /// native — and only the deadline moves, from "two per pass during the gesture"
    /// to "all of them at settle". The cost is bounded by the gesture plus
    /// `settleQuiet` (0.25 s), and `checkCost` is the gate on it.
    private static func checkAGestureThatBeginsAllNativeConvergesAtSettle() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.quiesceAndSurface()
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "precondition: all quiet tiles surfaced")

        // Everything promotes (content arrives everywhere), then falls quiet — the
        // all-native gesture start this witness is named for.
        for (index, tile) in world.tiles.enumerated() {
            guard let view = world.agentViews[tile.id] else { continue }
            let thread = "surface-residency-\(index)"
            let turn = "\(thread)-midgesture"
            view.ingest(.turnStarted(threadId: thread, turnId: turn))
            view.ingest(.contentDelta(
                threadId: thread, turnId: turn, streamKind: .assistant, delta: "wake"
            ))
        }
        world.evaluateResidency()
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "precondition: content promoted every tile")
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.canvas.qaResetSurfaceResidencyCounters()

        // Both directions of gesture, because the demotion budget used to depend on a
        // zoom-direction predicate that read false on every zoom-OUT.
        for target in [0.9, 0.85] {
            world.cameraStep(toZoom: target)
            world.pump()
            world.evaluateResidency()
            try expect(world.canvas.qaSurfaceDemotionCount == 0,
                       "a mid-gesture pass demoted \(world.canvas.qaSurfaceDemotionCount) tiles at zoom "
                       + "\(target) — under the hold nothing crosses until the camera stops")
        }
        try expect(world.canvas.qaResidencySuppressedDemotionCount > 0,
                   "the mid-gesture suppression must be RECORDED, not coincidental — otherwise a "
                   + "canvas that simply had nothing to demote is indistinguishable from the hold")

        // The deadline: settling converges every one of them.
        world.settle()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 8)
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "settling must converge every quiet tile — the hold defers crossings, it does not "
                   + "strand tiles native: \(world.canvas.qaSurfacedTileViews.count) of "
                   + "\(world.tiles.count) surfaced")
    }

    /// A canvas that leaves its window must hand every body back. Nothing evaluates
    /// residency out there, so a body parked in a windowless canvas is a body no
    /// policy will ever reclaim.
    /// Parked bodies must contribute NOTHING to the rendered window.
    ///
    /// The park's design claims "AppKit clips children to an ancestor's bounds
    /// when drawing, so nothing parked is ever painted" — true before macOS 14,
    /// FALSE since: `NSView.clipsToBounds` now defaults to `false`, nothing set
    /// it on the park, and the deployment target is macOS 14. So every parked
    /// full-size body was drawn at the park's origin AND left in the window's
    /// composited layer tree — measured live as roughly doubling the window's
    /// resident surface footprint beside the baked images (2026-08-19).
    ///
    /// The witness renders the exact region parked bodies land in (the park sits
    /// at the canvas origin with frame .zero) through the real view-drawing path
    /// — the same path the macOS 14 default un-clipped — with every tile panned
    /// far off screen, and demands the pixels be byte-identical before and after
    /// parking. A property echo ("clipsToBounds is true") could pass while the
    /// render regressed some other way; the pixels cannot.
    /// A fully occluded window must cost nothing: no heartbeat, no bakes, no
    /// mouse polling — and every tile family with its own render loop gets told.
    ///
    /// Nothing in the app observed occlusion, spaces, or activation before this:
    /// the 10 Hz heartbeat ran identically whether the user was looking at Array
    /// or it sat buried three Spaces away, polling the window server for the
    /// mouse and baking up to 4 bodies per pass. The rule: occluded means the
    /// canvas is ASLEEP — residency state untouched (waking must not storm),
    /// evaluation provably inert, timers stopped — and visible again means one
    /// immediate catch-up pass, then the ordinary cadence.
    /// **A surface may never be a picture of nothing.**
    ///
    /// Reported from the real 89-tile canvas: after clicking in and out of the
    /// window and navigating, tiles rendered chrome with a BLANK body — and the
    /// residency log said "surfaced 83 of 83", so those were surfaces whose baked
    /// image carried no content.
    ///
    /// The suspected cause is worth stating because it inverts an earlier fix: an
    /// UNCLIPPED parked body was still being drawn (that is exactly what
    /// `checkParkedBodiesPaintNoPixels` measured before the park was clipped), and
    /// being drawn is what kept a transcript's rows MATERIALIZED. Clipped, a
    /// parked body stops drawing, its collection view releases its item views,
    /// and a body promoted out of the park can be baked before any layout pass
    /// re-materialises it — so the surface is blank, and it stays blank until
    /// something happens to re-bake it.
    ///
    /// This witness drives the round trip the user drove: surface, promote, dirty
    /// the content, let it go quiet, re-bake — then demands every stored surface
    /// carry real pixels.
    private static func checkSurfacesAreNeverBlankAfterAParkRoundTrip() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true

        func assertNoBlankSurfaces(_ stage: String) throws {
            for (index, tile) in world.tiles.enumerated() {
                guard let surface = world.canvas.tileSurfaceStore.surface(for: tile.id) else { continue }
                let rep = NSBitmapImageRep(cgImage: surface.image)
                let metrics = VisualSnapshot.metrics(of: rep)
                try expect(!metrics.isBlank,
                           "\(stage): tile \(index)'s surface is BLANK — \(metrics.distinctSampledColors) distinct "
                           + "sampled colour(s) at \(metrics.width)x\(metrics.height). A surfaced tile is showing a "
                           + "picture of nothing, which is what the user saw as empty tile bodies")
            }
        }

        // First bake: the body has never been parked. This is the baseline, and it
        // is what a fresh canvas shows.
        world.quiesceAndSurface()
        try expect(world.canvas.tileSurfaceStore.count > 0, "precondition: something must be surfaced")
        try assertNoBlankSurfaces("first bake")

        // The round trip: every body back to native (this is what a click, a
        // focus, or a sharpness promotion does), then content changes so the next
        // quiet pass MUST re-bake from a body that has just come out of the park.
        world.canvas.promoteAllSurfacedTiles()
        world.pump()
        for (index, tile) in world.tiles.enumerated() {
            guard let view = world.agentViews[tile.id] else { continue }
            let thread = "surface-residency-\(index)"
            let turn = "\(thread)-roundtrip"
            view.ingest(.turnStarted(threadId: thread, turnId: turn))
            view.ingest(.contentDelta(
                threadId: thread, turnId: turn, streamKind: .assistant,
                delta: "A body promoted out of the park must still know how to draw itself."
            ))
            view.ingest(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        }
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 8)
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "after the round trip every quiet tile must be surfaced again, got "
                   + "\(world.canvas.qaSurfacedTileViews.count) of \(world.tiles.count)")
        try assertNoBlankSurfaces("re-bake after a park round trip")

        // **And the same round trip for a tile the camera cannot see**, which is
        // the state most of a big canvas is in: 83 tiles, a handful on screen. An
        // off-screen tile is clipped by the world plane, so its transcript's
        // `visibleRect` is empty and its collection view has no reason to hold any
        // item views — nothing re-materialises it the way an on-screen layout pass
        // does. If a bake in that state yields blank pixels, every off-screen tile
        // on the canvas is a picture of nothing waiting for the user to pan to it.
        world.canvas.promoteAllSurfacedTiles()
        world.canvas.setViewport(CanvasViewport(x: 40_000, y: 40_000, zoom: 1))
        world.pump()
        try expect(world.canvas.visibleTileViews.isEmpty, "precondition: every tile must be off-screen")
        for (index, tile) in world.tiles.enumerated() {
            guard let view = world.agentViews[tile.id] else { continue }
            let thread = "surface-residency-\(index)"
            let turn = "\(thread)-offscreen"
            view.ingest(.turnStarted(threadId: thread, turnId: turn))
            view.ingest(.contentDelta(
                threadId: thread, turnId: turn, streamKind: .assistant,
                delta: "An off-screen body must still bake the content it holds."
            ))
            view.ingest(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil))
        }
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.evaluateResidency(passes: 8)
        try assertNoBlankSurfaces("re-bake while off-screen")
    }

    /// **The notification-lag gap: a pass may run after the window has stopped
    /// being shown but before anyone has been told.**
    ///
    /// This is the reported blank-tile bug's most likely origin. Clicking in and
    /// out of the window repeatedly means many visibility transitions, and in the
    /// gap between the window actually going away and
    /// `didChangeOcclusionStateNotification` arriving, the 10 Hz pass can still
    /// fire — baking bodies in a window with no valid backing store, up to four
    /// blank surfaces per gap, each persisting because its revision still matched
    /// its content. The cached occlusion flag cannot close this; only reading the
    /// state at bake time can.
    ///
    /// The fixture reproduces the gap exactly: flip the injected visibility
    /// WITHOUT posting the notification, so the canvas still believes it is
    /// visible, and demand that no bake happens anyway.
    private static func checkNoBakeWhileTheWindowIsNotShown() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.settle()
        world.window.makeFirstResponder(nil)
        world.injectedPointer = nil
        world.evaluateResidency()
        world.advance(world.canvas.residencyTuning.contentQuietDelay + 0.05)
        world.canvas.qaResetSurfaceResidencyCounters()

        // The gap: not shown any more, nobody has been told.
        world.canvas.occlusionVisibilityProvider = { false }
        world.evaluateResidency(passes: 4)

        try expect(world.canvas.tileSurfaceStore.qaBakeCount == 0,
                   "baked \(world.canvas.tileSurfaceStore.qaBakeCount) times while the window was not being "
                   + "shown — those are the blank surfaces users saw as empty tile bodies")
        try expect(world.canvas.qaSurfaceRefusedOccludedCount > 0,
                   "the refusal must be attributed to the window not being shown, so the reason stays observable")
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "nothing may be surfaced from a bake that never happened")

        // And it recovers on its own once the window is shown again: no
        // notification needed, because the same authoritative read allows it.
        world.canvas.occlusionVisibilityProvider = { true }
        world.evaluateResidency(passes: 6)
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "once the window is shown again every quiet tile must surface: "
                   + "\(world.canvas.qaSurfacedTileViews.count) of \(world.tiles.count)")
    }

    private static func checkOcclusionPausesAndResumesResidency() throws {
        final class OcclusionRecordingTileView: TileNSView {
            var feeds: [Bool] = []
            override func windowOcclusionChanged(visible: Bool) { feeds.append(visible) }
        }

        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        // The fixture enabled the flag after the window attach, so start the
        // heartbeat the way production does — through viewDidMoveToWindow, whose
        // installs are idempotent.
        world.canvas.viewDidMoveToWindow()
        try expect(world.canvas.qaResidencyTimerRunning, "precondition: the heartbeat runs while windowed and visible")

        let recorder = OcclusionRecordingTileView(tile: Tile(
            id: UUID(), kind: .note, title: "occlusion-recorder",
            frame: TileFrame(x: 2_000, y: 60, width: 200, height: 120),
            zPosition: .fromLegacyRank(99), zoneId: nil, runtimeRef: nil, metadata: TileMetadata()
        ))
        world.canvas.install(tileView: recorder, for: recorder.tile)

        world.quiesceAndSurface()
        let surfacedBefore = world.canvas.qaSurfacedTileViews.count
        try expect(surfacedBefore == world.tiles.count,
                   "precondition: every fixture tile surfaced, got \(surfacedBefore) of \(world.tiles.count)")

        // The window becomes fully occluded (covered, hidden, or on another
        // space — AppKit reports all of them through this one notification).
        world.canvas.occlusionVisibilityProvider = { false }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: world.window)
        try expect(!world.canvas.qaResidencyTimerRunning,
                   "occlusion must stop the 10 Hz heartbeat — it was polling the window server and baking for a window nobody can see")
        let evaluationsWhileOccluded = world.canvas.qaResidencyEvaluationCount
        world.canvas.evaluateTileResidency()
        try expect(world.canvas.qaResidencyEvaluationCount == evaluationsWhileOccluded,
                   "a stray evaluation while occluded must no-op — the guard, not the timer, is the safety")
        try expect(world.canvas.qaSurfacedTileViews.count == surfacedBefore,
                   "occlusion must not change residency: the canvas is asleep, not rearranged")
        try expect(recorder.feeds.last == false,
                   "every tile must be told the window is occluded, so families with render loops can pause them")

        // Visible again: one immediate catch-up pass, then the ordinary cadence.
        world.canvas.occlusionVisibilityProvider = { true }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: world.window)
        try expect(world.canvas.qaResidencyTimerRunning, "becoming visible must restart the heartbeat")
        // NO immediate evaluation on waking, deliberately: a window that has just
        // come back has not necessarily redrawn itself, and a bake taken in that
        // instant captures nothing — which is exactly the blank-tile report that
        // `qaSurfaceRefusedOccludedCount` and the uniform-bake refusal now guard.
        // The heartbeat is at most 100 ms away and a tile surfaced 100 ms late is
        // invisible.
        try expect(world.canvas.qaResidencyEvaluationCount == evaluationsWhileOccluded,
                   "waking must not evaluate (and therefore must not bake) inline — it restarts the heartbeat and asks for a redraw")
        world.evaluateResidency()
        try expect(world.canvas.qaResidencyEvaluationCount == evaluationsWhileOccluded + 1,
                   "the next tick after waking must evaluate normally")
        try expect(world.canvas.qaSurfacedTileViews.count == surfacedBefore,
                   "no storm on waking: quiet tiles stay surfaced")
        try expect(recorder.feeds.last == true, "every tile must be told the window is visible again")
    }

    private static func checkParkedBodiesPaintNoPixels() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        // Pan every tile far off screen so the park's landing zone shows pure
        // canvas background. Tiles stay installed and eligible; visibility only
        // orders the bake budget, it never refuses residency.
        world.canvas.setViewport(CanvasViewport(x: 50_000, y: 50_000, zoom: 1))
        world.pump()
        try expect(world.canvas.visibleTileViews.isEmpty, "precondition: no tile may intersect the canvas")

        // Parked bodies land ABOVE the canvas: the park (frame .zero, at the
        // canvas origin) is not flipped, so a body framed (0,0,w,h) extends into
        // NEGATIVE canvas y — measured at (0,-276,420,276) for this fixture.
        // Inside the canvas they were never visible even unclipped, which is why
        // nobody saw them; but they render into the region above the canvas
        // (window chrome territory in production) and their layers stay in the
        // composited tree. Probe that overflow region.
        let probe = CGRect(x: 0, y: -320, width: 520, height: 320)
        func probePixels() throws -> [UInt8] {
            world.pump()
            guard let rep = world.canvas.bitmapImageRepForCachingDisplay(in: probe) else {
                throw Failure(message: "could not allocate the park-region probe bake")
            }
            world.canvas.cacheDisplay(in: probe, to: rep)
            guard let cg = rep.cgImage, let bytes = normalizedBytes(cg) else {
                throw Failure(message: "could not normalize the park-region probe bake")
            }
            return bytes
        }

        let allNative = try probePixels()
        world.quiesceAndSurface()
        try expect(world.canvas.qaSurfacedTileViews.count == world.tiles.count,
                   "precondition: every tile parked, got \(world.canvas.qaSurfacedTileViews.count) of \(world.tiles.count)")
        let parked = try probePixels()
        try expect(allNative == parked,
                   "parking painted pixels into the park's landing zone — parked bodies are being drawn "
                   + "(macOS 14 clipsToBounds default): the park must clip its children out of every draw")
        // The compositing half: a masked, zero-sized layer is culled from the
        // render tree by documented CA semantics. Assert the properties that
        // guarantee it — the pixel assertion above keeps this honest.
        try expect(world.canvas.surfaceParkView.clipsToBounds,
                   "the park must clip its children (macOS 14 defaults this OFF)")
        try expect(world.canvas.surfaceParkView.layer?.masksToBounds == true,
                   "the park's layer must mask to bounds so the compositor culls parked subtrees")
        try expect(world.canvas.surfaceParkView.frame.size == .zero,
                   "the park must stay zero-sized — clipping a non-empty park would still composite it")
    }

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
        func perStepMs(liveCount: Int, residency: Bool = true) throws -> (step: Double, flush: Double) {
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
            var flushes: [Double] = []
            for index in 1...12 {
                steps.append(milliseconds {
                    world.cameraStep(toZoom: 0.9 - 0.03 * Double(index))
                    world.canvas.layoutSubtreeIfNeeded()
                    world.window.displayIfNeeded()
                })
                // Measured SEPARATELY, never folded in — a returning
                // `CATransaction.flush()` is compositor synchronisation, and folding
                // it into a step once reported a 0.07 ms camera path as 119% over
                // budget. But the same rule makes the Array-owned number BLIND to it,
                // and a real gesture felt laggy with 7 of 8 tiles surfaced while this
                // check measured 0.16 ms a step. So it is published beside the step:
                // if surfacing collapses the step and leaves the flush alone, the
                // felt cost was never in Array's camera path.
                flushes.append(milliseconds { CATransaction.flush() })
            }
            let sorted = steps.sorted()
            let sortedFlushes = flushes.sorted()
            return (sorted[sorted.count / 2], sortedFlushes[sortedFlushes.count / 2])
        }

        let nativeArm = try perStepMs(liveCount: 0, residency: false)
        let quietArm = try perStepMs(liveCount: 0)
        let oneLiveArm = try perStepMs(liveCount: 1)
        let threeLiveArm = try perStepMs(liveCount: 3)
        let sixLiveArm = try perStepMs(liveCount: 6)
        let native = nativeArm.step
        let quiet = quietArm.step
        let oneLive = oneLiveArm.step
        let threeLive = threeLiveArm.step
        let sixLive = sixLiveArm.step
        print(String(format: "tile-surface-residency: PRESENTATION, published and not gated — "
                     + "CATransaction.flush() p50 %.2f ms with every tile native, %.2f ms with none live, "
                     + "%.2f ms with three live. Array's camera path is %.2f ms and %.2f ms in those two "
                     + "arms, so if a real gesture still feels bad the cost is here, not there.",
                     nativeArm.flush, quietArm.flush, threeLiveArm.flush, native, quiet))

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
        // 4.5, not 3.1: the bound must hold on a LOADED machine. A matrix run
        // beside a live 89-tile Array measured 3.58 here while the native arm ran
        // 40% over its own usual number — same code, busy box. The regression this
        // exists to catch (a live tile going back toward the ~29 ms native cost)
        // clears 4.5 by an order of magnitude.
        try expect(marginal <= 4.5,
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
            let scanMs = TileSurfaceStore.qaBakeScanCount > 0
                ? TileSurfaceStore.qaBakeScanMsTotal / Double(TileSurfaceStore.qaBakeScanCount)
                : 0
            print(String(format: "tile-surface-residency bake: uniformity scan (the blank-bake guard) "
                         + "costs %.3f ms per bake, %.1f%% of a %.2f ms clean bake",
                         scanMs, scanMs / max(0.0001, cleanMs) * 100, cleanMs))
            let attributed = p50(allocSamples) + p50(drawSamples) + scanMs
            try expect(attributed >= cleanMs * 0.6,
                       String(format: "bake cost: the alloc/draw split no longer explains the bake: "
                              + "%.2f ms attributed of %.2f ms measured", attributed, cleanMs))
        }
    }
}
