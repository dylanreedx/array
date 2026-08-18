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

        init(tileCount: Int, turns: Int = 4, viewportSize: CGSize = CGSize(width: 1_600, height: 1_000)) {
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
                        x: Double(index % 3) * 480 + 40, y: Double(index / 3) * 360 + 60,
                        width: 420, height: 300
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
            pump()
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
        try checkMotionSurfacesAndRestRestores()
        try checkPixelEquivalence()
        try checkSharpnessNeverRegresses()
        try checkStreamingSurvivesTheGesture()
        try checkClickDuringSettleWindowReachesTheBody()
        try checkNothingIsStranded()
        try checkCost()
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

    /// The two-state machine, from production transitions only.
    private static func checkMotionSurfacesAndRestRestores() throws {
        let world = World(tileCount: 6)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        // A settle first, so the store holds surfaces before the gesture starts —
        // the steady state a real canvas is in.
        world.settle()
        world.canvas.refreshTileSurfaces()
        for _ in 0..<3 {
            world.settle()
            world.canvas.refreshTileSurfaces()
        }
        try expect(world.canvas.tileSurfaceStore.count > 0,
                   "the settle pass must produce at least one surface, or a gesture has nothing to use")

        world.canvas.qaResetSurfaceResidencyCounters()
        world.cameraStep(toZoom: 0.8)
        world.pump()

        let surfaced = world.canvas.qaSurfacedTileViews.count
        try expect(surfaced > 0, "entering motion must surface at least one tile")
        try expect(world.canvas.qaParkedBodyCount == surfaced,
                   "every surfaced tile must have exactly one body in the park: \(surfaced) surfaced, "
                   + "\(world.canvas.qaParkedBodyCount) parked")

        // The whole point, in two assertions — and the counter to use is the PARK
        // walk, not `qaTotalTranscriptLayoutPassCount`. That one sums over
        // `tileViewsInVisualOrder`, i.e. the world plane, so it cannot see a parked
        // body at all: it goes to zero when a tile is surfaced, which reads like
        // proof and is really blindness. Baselines are taken AFTER the first step,
        // because being adopted by the park legitimately costs each body one layout.
        let parkedBaseline = world.parkedTranscriptLayoutPasses
        let planeBaseline = world.transcriptLayoutPasses
        for step in 1...6 {
            world.cameraStep(toZoom: 0.8 - 0.09 * Double(step))
            world.pump()
        }
        try expect(world.canvas.qaSurfacedTileViews.count > 0, "tiles must stay surfaced across the gesture")
        try expect(world.parkedTranscriptLayoutPasses == parkedBaseline,
                   "a camera step reached a PARKED transcript: \(parkedBaseline) -> "
                   + "\(world.parkedTranscriptLayoutPasses). The park is not outside the cascade.")
        try expect(world.transcriptLayoutPasses == planeBaseline,
                   "a camera step laid out a transcript still in the world plane: \(planeBaseline) -> "
                   + "\(world.transcriptLayoutPasses)")

        world.settle()
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "settling must restore every real body — at rest nothing may be surfaced")
        try expect(world.canvas.qaParkedBodyCount == 0,
                   "settling must empty the park, saw \(world.canvas.qaParkedBodyCount)")
        for view in world.agentViews.values {
            try expect(view.surfaceableBody === view.contentView,
                       "a restored tile's content view must be its real body again")
        }
    }

    /// The gate Dylan's requirement actually names, aimed at the PRODUCER.
    ///
    /// The surface is compared against a native bake of the same body at the same
    /// moment and therefore the same resolution — no camera movement between them,
    /// so no resampling in the comparison. That isolates what Array owns (does the
    /// producer render the right pixels?) from what Core Animation owns (drawing a
    /// sharp image smaller, which is inherent to showing any cached image at all
    /// and is bounded by the sharpness rule to downscaling only).
    ///
    /// The first version of this check compared a surfaced tile against a native
    /// bake taken at a DIFFERENT zoom. Two things were wrong with it, and both
    /// mattered: `bitmapImageRepForCachingDisplay` sizes itself from the view's
    /// effective scale, so the two reps were not even the same shape; and once that
    /// was fixed the metric was dominated by resampling, which left the
    /// half-scale negative witness indistinguishable from the green path (4.44 vs
    /// 4.62 — a gate that cannot fail).
    private static func checkPixelEquivalence() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        for _ in 0..<4 {
            world.settle()
            world.canvas.refreshTileSurfaces()
        }
        world.pump()

        var worstDifference = 0.0
        var compared = 0
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id],
                  let body = view.surfaceableBody,
                  let surface = world.canvas.tileSurfaceStore.surface(for: tile.id) else { continue }
            let nativeRep = try bake(body)
            guard let nativeImage = nativeRep.cgImage else {
                throw Failure(message: "the native comparison bake produced no image")
            }
            try expect(!VisualSnapshot.metrics(of: nativeRep).isBlank,
                       "the native body rendered blank — the fixture, not the surface, is wrong")
            worstDifference = max(worstDifference, meanChannelDifference(surface.image, nativeImage))
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
        world.cameraStep(toZoom: 0.9)
        world.pump()
        var checkedComposite = 0
        for tile in world.tiles {
            guard let view = world.agentViews[tile.id], view.surfaceResidency == .surfaced else { continue }
            let composite = try bake(view)
            try expect(!VisualSnapshot.metrics(of: composite).isBlank,
                       "a surfaced tile composited blank — the worst possible outcome of this design")
            checkedComposite += 1
        }
        try expect(checkedComposite > 0, "no tile surfaced, so the composite was never checked")
        world.settle()
    }

    /// Mean per-channel difference the producer may show against the real body.
    /// Calibrated against the negative witness, not guessed — see
    /// docs/internals/performance-budgets.md for both measured numbers.
    private static let surfaceFidelityThreshold = 0.25

    /// Zooming IN past what a surface carries must refuse the surface, not show a
    /// soft one. This is the rule that keeps sharpness from ever regressing.
    private static func checkSharpnessNeverRegresses() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.settle()
        world.canvas.refreshTileSurfaces()
        for _ in 0..<3 {
            world.settle()
            world.canvas.refreshTileSurfaces()
        }
        try expect(world.canvas.tileSurfaceStore.count > 0, "need surfaces before testing refusal")
        let bakedScale = world.canvas.tileSurfaceStore.surface(for: world.tiles[0].id)?.bakedScale ?? 0
        try expect(bakedScale > 0, "a stored surface must know its own density")

        // Jump to a zoom whose demand exceeds what any surface carries.
        world.canvas.qaResetSurfaceResidencyCounters()
        let backing = world.window.backingScaleFactor
        let tooSharp = Double(bakedScale / backing) * 2
        world.cameraStep(toZoom: tooSharp)
        world.pump()
        try expect(world.canvas.qaSurfacedTileViews.isEmpty,
                   "zooming past the baked density must leave every tile native, saw "
                   + "\(world.canvas.qaSurfacedTileViews.count) surfaced at zoom \(tooSharp)")
        try expect(world.canvas.qaSurfaceRefusedSharpnessCount > 0,
                   "the refusal must be the SHARPNESS one, so the reason is observable and not a coincidence")
        world.settle()
    }

    /// A parked body is quiet, not dead: events ingested mid-gesture are in the
    /// transcript once the gesture ends.
    private static func checkStreamingSurvivesTheGesture() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.settle()
        world.canvas.refreshTileSurfaces()
        for _ in 0..<3 {
            world.settle()
            world.canvas.refreshTileSurfaces()
        }
        world.cameraStep(toZoom: 0.85)
        world.pump()

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

        world.settle()
        // At rest the real body is back, and it must show what arrived while it was
        // parked. `flushPendingVisualUpdate` is the transcript's own 30 Hz gate.
        view.qaTranscriptCollectionFixture?.flushPendingVisualUpdate()
        world.pump()
        try expect(view.surfaceResidency == .native, "the tile must be native again after settling")
        try expect(view.qaTranscriptText.contains("while the tile was rendering from a surface"),
                   "content ingested during the gesture is missing from the restored transcript")
    }

    /// A picture swallows clicks. `hitTest` promotes first, so the event lands on
    /// the real body — the 250 ms settle window is when a user actually reaches for
    /// a tile they were just looking at.
    private static func checkClickDuringSettleWindowReachesTheBody() throws {
        let world = World(tileCount: 3)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.settle()
        world.canvas.refreshTileSurfaces()
        for _ in 0..<3 {
            world.settle()
            world.canvas.refreshTileSurfaces()
        }
        world.cameraStep(toZoom: 0.9)
        world.pump()

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
        world.settle()
    }

    /// Nothing may be left in the park, and no surface may outlive its tile.
    private static func checkNothingIsStranded() throws {
        let world = World(tileCount: 4)
        defer { world.teardown() }
        world.canvas.surfaceResidencyEnabled = true
        world.settle()
        world.canvas.refreshTileSurfaces()
        for _ in 0..<3 {
            world.settle()
            world.canvas.refreshTileSurfaces()
        }
        world.cameraStep(toZoom: 0.9)
        world.pump()
        try expect(world.canvas.qaParkedBodyCount > 0, "need a populated park before testing teardown")

        // Removing a tile MID-GESTURE is the case that strands a body: the tile view
        // leaves the world plane while its real body is somewhere else entirely.
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
        world.cameraStep(toZoom: 0.7)
        world.pump()
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

    /// Cost, with the Core Animation flush kept OUT of the Array-owned number: a
    /// returning `CATransaction.flush()` is compositor synchronisation, and folding
    /// it in once reported a 0.07 ms camera path as 119% over budget.
    ///
    /// Reports the per-step win AND decomposes the gesture-start transition, because
    /// the transition is where this variant can lose: entering motion reparents every
    /// eligible body into the park, and `addSubview` invalidates the view it adopts —
    /// so a transition pays one full transcript layout per demoted tile unless
    /// something stops it. Bakes are separated out by pre-baking every surface
    /// through `qaBakeAllSurfaces`, so the two costs cannot hide inside each other.
    private static func checkCost() throws {
        let tileCount = 12
        let frameBudgetMs = 8.3

        struct Arm {
            var perStep = 0.0
            var transition = 0.0
            var demotions = 0
            var bakesDuringTransition = 0
            var parkedLayoutsDuringTransition = 0
            var commit = 0.0
            var layout = 0.0
            var display = 0.0
            var demoteHost = 0.0
            var demoteContentSwap = 0.0
            var demotePark = 0.0
        }

        func measure(residency: Bool, preBakeEverything: Bool) throws -> Arm {
            let world = World(tileCount: tileCount)
            defer { world.teardown() }
            world.canvas.surfaceResidencyEnabled = residency
            for _ in 0..<3 {
                world.settle()
                world.canvas.refreshTileSurfaces()
            }
            if preBakeEverything { world.canvas.qaBakeAllSurfaces() }
            // Drain the first rasterisation and any symbol-cache population before
            // the clock: a cold first step belongs to construction.
            world.cameraStep(toZoom: 0.95)
            world.pump()
            world.settle()
            if preBakeEverything { world.canvas.qaBakeAllSurfaces() }
            world.canvas.qaResetSurfaceResidencyCounters()

            var arm = Arm()
            let bakesBefore = world.canvas.tileSurfaceStore.qaBakeCount
            let layoutsBefore = world.fixtureTranscriptLayoutPasses
            TileNSView.qaResetDemoteTiming()
            // Split, because "the transition is slow" is not actionable and two
            // guesses at WHY it was slow were already wrong (a fresh texture upload
            // per gesture; an empty visibleRect in the park). `onActivityBegin` fires
            // synchronously from `noteScrollZoom`, so the demote loop is inside the
            // commit stage.
            let commitMs = milliseconds { world.cameraStep(toZoom: 0.9) }
            let layoutMs = milliseconds { world.canvas.layoutSubtreeIfNeeded() }
            let displayMs = milliseconds { world.window.displayIfNeeded() }
            arm.commit = commitMs
            arm.layout = layoutMs
            arm.display = displayMs
            arm.demoteHost = TileNSView.qaDemoteHostMs
            arm.demoteContentSwap = TileNSView.qaDemoteContentSwapMs
            arm.demotePark = TileNSView.qaDemoteParkMs
            arm.transition = commitMs + layoutMs + displayMs
            arm.bakesDuringTransition = world.canvas.tileSurfaceStore.qaBakeCount - bakesBefore
            arm.demotions = world.canvas.qaSurfaceDemotionCount
            arm.parkedLayoutsDuringTransition = world.fixtureTranscriptLayoutPasses - layoutsBefore
            CATransaction.flush()

            var steps: [Double] = []
            for index in 1...12 {
                steps.append(milliseconds {
                    world.cameraStep(toZoom: 0.9 - 0.05 * Double(index))
                    world.canvas.layoutSubtreeIfNeeded()
                    world.window.displayIfNeeded()
                })
                CATransaction.flush()
            }
            if residency {
                try expect(arm.demotions > 0,
                           "the residency arm never demoted anything, so its cost is the native arm's")
                try expect(world.canvas.qaTrackedSurfacedTileCount == world.canvas.qaSurfacedTileViews.count,
                           "the maintained surfaced set drifted from the view tree: "
                           + "\(world.canvas.qaTrackedSurfacedTileCount) tracked vs "
                           + "\(world.canvas.qaSurfacedTileViews.count) in the tree")
            }
            world.settle()
            let sorted = steps.sorted()
            arm.perStep = sorted[sorted.count / 2]
            return arm
        }

        let native = try measure(residency: false, preBakeEverything: false)
        let stale = try measure(residency: true, preBakeEverything: false)
        let fresh = try measure(residency: true, preBakeEverything: true)

        print(String(
            format: "tile-surface-residency: %d tiles | per step p50 native %.2f ms -> surfaced %.2f ms "
            + "(%.4fx) | transition native %.2f ms, surfaced-with-stale %.2f ms (%d demoted, %d baked), "
            + "surfaced-all-fresh %.2f ms (%d demoted, %d baked, %d transcript layouts; native "
            + "transition cost %d) | transition stages native commit %.2f/layout %.2f/display %.2f "
            + "-> surfaced commit %.2f/layout %.2f/display %.2f | demote breakdown host %.2f/"
            + "contentSwap %.2f/park %.2f",
            tileCount, native.perStep, fresh.perStep,
            native.perStep > 0 ? fresh.perStep / native.perStep : 1,
            native.transition,
            stale.transition, stale.demotions, stale.bakesDuringTransition,
            fresh.transition, fresh.demotions, fresh.bakesDuringTransition,
            fresh.parkedLayoutsDuringTransition, native.parkedLayoutsDuringTransition,
            native.commit, native.layout, native.display,
            fresh.commit, fresh.layout, fresh.display,
            fresh.demoteHost, fresh.demoteContentSwap, fresh.demotePark
        ))

        try expect(fresh.perStep <= frameBudgetMs,
                   String(format: "surfaced camera step must fit a frame: %.2f ms > %.2f ms",
                          fresh.perStep, frameBudgetMs))
        try expect(fresh.perStep < native.perStep,
                   String(format: "surfacing must be cheaper than not surfacing: %.2f ms vs %.2f ms",
                          fresh.perStep, native.perStep))
        // The transition is PUBLISHED and deliberately NOT gated.
        //
        // It was a gate, it fired, and it did its job: entering motion costs ~4x a
        // native step with every surface already fresh, and the demote breakdown
        // attributes all of it to plain AppKit subtree surgery — ~2.1 ms to remove a
        // deep body from the tile and ~2.9 ms to re-add it to the park, per tile, per
        // direction, with host construction at 0.00 ms. That killed "surfaced in
        // motion only" (`.plans/36`), because any policy that reparents per gesture
        // pays it twice per tile per gesture.
        //
        // Keeping it as a gate now would assert a decision rather than protect a
        // behaviour: the policy is abandoned, so there is no regression left to
        // catch. What this leg still protects is the MECHANISM, which the next policy
        // reuses unchanged — the per-step cost above, the producer's fidelity, the
        // sharpness refusal, streaming through a park, and the absence of leaks.
        //
        // Three hypotheses for this number were measured and refuted along the way:
        // a fresh CALayer texture upload per gesture (retaining the host moved it
        // 0.1 ms), an empty visibleRect in the park (sizing the park changed
        // nothing), and the forced offscreen pass in `AgentTranscriptListView.layout`
        // (gating it changed the native step by 0.2 ms — those calls really were
        // nearly free, and the ~960 profile samples belong to AppKit's own forced
        // subtree layout).
        let transitionRatio = native.transition > 0 ? fresh.transition / native.transition : 0
        print(String(format: "tile-surface-residency: transition is PUBLISHED, not gated — %.2fx a native "
                     + "step. Reparenting a deep body costs ~%.2f ms/tile out and ~%.2f ms/tile back; this "
                     + "is why \"surfaced in motion only\" was abandoned (.plans/36).",
                     transitionRatio,
                     fresh.demotions > 0 ? fresh.demoteContentSwap / Double(fresh.demotions) : 0,
                     fresh.demotions > 0 ? fresh.demotePark / Double(fresh.demotions) : 0))
        // What DOES stay gated about the transition: the breakdown must account for
        // the commit stage it claims to explain. An instrument that stops adding up
        // is how a published number quietly becomes fiction.
        let attributed = fresh.demoteHost + fresh.demoteContentSwap + fresh.demotePark
        try expect(attributed >= fresh.commit * 0.6,
                   String(format: "the demote breakdown no longer explains the commit stage: %.2f ms "
                          + "attributed of %.2f ms measured", attributed, fresh.commit))
    }
}
