import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// The registry of measured performance scenarios, and the runner behind
/// `--perf-budget-check`.
///
/// Adding a scenario here is how a surface gets a standing performance target.
/// The rules are in `PerfBudget`; the short version is that every scenario
/// carries at least one COUNT budget (deterministic, names the defect) alongside
/// its duration budget (coarse, generous, drifts with machine load).
///
/// Run it:
///
///     .build/debug/Array --perf-budget-check                  # everything
///     .build/debug/Array --perf-budget-check --scenario canvas.zoom
///     .build/debug/Array --perf-budget-check --perf-json out.json
///
/// It prints a table with each metric against its budget and the percentage of
/// budget used, then a summary — including metrics that PASSED but are over half
/// their budget, because those are the next failures and a green run should
/// still show them.
@MainActor
enum PerfScenarios {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// A 120 Hz frame. Every camera step budget is stated against this rather
    /// than 60 Hz: ProMotion is what the target machine has, and a step that
    /// only fits 16.7 ms is visibly worse there.
    static let frameBudgetMs = 8.3

    // MARK: - Runner

    static func run(scenarioFilter: String?, jsonPath: String?) throws {
        var results: [PerfScenarioResult] = []
        var skippedStress: [String] = []
        for scenario in all {
            if let filter = scenarioFilter {
                if !scenario.name.hasPrefix(filter) { continue }
            } else if scenario.isStress {
                // Opt-in only: never part of a default or matrix run.
                skippedStress.append(scenario.name)
                continue
            }
            results.append(try scenario.run())
        }
        guard !results.isEmpty else {
            throw Failure(message: "no scenario matched \(scenarioFilter ?? "(none)"); known: \(all.map(\.name).joined(separator: ", "))")
        }

        print("performance budgets")
        print(PerfReport.table(results))
        print(PerfReport.summary(results))
        if !skippedStress.isEmpty {
            // Say what was NOT run. A report that silently omits a scenario reads
            // as "everything is covered" when it is not.
            print("  Stress scenarios skipped (opt-in): \(skippedStress.joined(separator: ", "))"
                  + " — run with --scenario \(skippedStress[0])")
        }

        if let jsonPath {
            let context = [
                "host": ProcessInfo.processInfo.hostName,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cores": String(ProcessInfo.processInfo.processorCount),
                "configuration": buildConfiguration
            ]
            try PerfReport.json(results, context: context).write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
            print("\n  wrote \(jsonPath)")
        }

        let failures = results.flatMap(\.failures)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) budget(s) over: "
                          + failures.map(\.budget.metric).joined(separator: ", "))
        }
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    struct Scenario {
        let name: String
        /// Stress scenarios are OPT-IN. They build a deliberately oversized
        /// workspace — dozens of live agent tiles with real transcripts — which
        /// is slow and memory-hungry, and Array is not alone on the machine
        /// (docs/internals/performance.md: a matrix run while the user works is a
        /// memory event, not just a CPU one). They answer "where does it break?",
        /// which is a question you ask deliberately, not on every commit.
        var isStress = false
        let run: () throws -> PerfScenarioResult
    }

    static var all: [Scenario] {
        [
            Scenario(name: "canvas.pan", run: { try canvasCamera(.pan) }),
            Scenario(name: "canvas.zoom", run: { try canvasCamera(.zoom) }),
            // The float-tolerance trap witness. AppKit does not store `bounds`
            // verbatim — it keeps the bounds/frame SCALE and recomputes the
            // size — so at any zoom other than 1 a bounds set to 420 reads back
            // as 420.00000000000006 and an exact "skip unchanged writes" compare
            // rewrites every tile's bounds on every step, forever. The zoom-1
            // pan scenario above is structurally blind to that defect; this leg
            // pans the SAME fixture at zoom 0.35 and must stay at zero bounds
            // writes. The name deliberately shares no prefix with canvas.pan /
            // canvas.zoom — the scenario filter is prefix-matched.
            Scenario(name: "canvas.fractional-pan", run: { try canvasCamera(.pan, zoom: 0.35, label: "fractional-pan") }),
            // The camera's COMPLEXITY witness, as opposed to the three scenarios
            // above which measure one fixed canvas. It sweeps the number of
            // INSTALLED tiles while holding the visible count fixed, so what it
            // reports is the slope: does a camera step cost more because more
            // tiles exist somewhere, whether or not the user can see them?
            // Known-red against the product target today, by construction.
            Scenario(name: "canvas.camera-slope", run: { try canvasCameraSlope() }),
            // The same complexity question for ZOOM, which camera-slope does not
            // ask. "O(1) in tiles" is the contract for both gestures, and only one
            // of them had a witness. The name shares no prefix with canvas.zoom —
            // the filter is prefix-matched, so `--scenario canvas.zoom` would
            // otherwise sweep this in too.
            Scenario(name: "canvas.magnify-slope", run: { try canvasZoomSlope() }),
            // The document-relationship overlay's own per-step cost, which
            // magnify-slope's cheap descriptor tiles never exercise (it never sets
            // up any document links). `.plans/44` item 1.
            Scenario(name: "canvas.document-relationship-zoom-cost", run: { try canvasDocumentRelationshipZoomCost() }),
            // The TRANSITION between gestures, which every scenario above is
            // blind to: they each drive one pure gesture, and the complaint
            // that reframed the zoom program lived exactly at the seam ("it
            // lags when zooming when you start panning"). Four windows on one
            // fixture — pure pan, zoom→pan handoff, a pure-zoom control, and a
            // strict interleave over the SAME zoom sequence — so "a pan step
            // costs more because a zoom preceded it" is a measured difference,
            // not a feeling. The name shares no prefix with canvas.pan/zoom.
            Scenario(name: "canvas.gesture-transition", run: { try canvasGestureTransition() }),
            // A causal A/B probe, not the geometry-hold mechanism: real managed
            // agent subtrees, real display commits, and the exact profiled
            // variable (`setBoundsSize`) stepped versus held. Opt-in until its
            // first measurements establish the recoverable fraction.
            Scenario(name: "canvas.geometry-hold-probe", isStress: true, run: { try canvasGeometryHoldProbe() }),
            // First bounded motion-presenter experiment. A real managed-agent
            // tree remains installed and geometrically held while a separate
            // layer-hosting view presents synthetic tile-shell pixels through
            // one owned root affine. Opt-in only: this proves the scene shape,
            // not cache/provider fidelity or production CanvasNSView wiring.
            Scenario(name: "canvas.proxy-scene-probe", isStress: true, run: { try canvasProxySceneProbe() }),
            // The Shape A witness (.plans/34 I15): three arms over one real
            // agent fixture — deep native tiles, flat surface hosts at the same
            // installed count, and flat surface hosts culled to the viewport's
            // presentation set — every step a real production driver commit.
            // Opt-in: it bakes one distinct surface per host from a real agent
            // body, so the fixture is a memory event as well as a CPU one.
            Scenario(name: "canvas.surface-host-slope", isStress: true, run: { try canvasSurfaceHostSlope() }),
            // Supported-presentation experiment: AppKit owns an outer
            // NSScrollView/NSClipView and magnifies a real managed-agent
            // document tree. This stays opt-in until the real display pump says
            // whether sanctioned magnification avoids or reproduces the backing
            // cascade that geometry-hold-probe isolated.
            Scenario(name: "canvas.scroll-magnification-probe", isStress: true, run: { try canvasScrollMagnificationProbe() }),
            // The RASTERIZATION witness — every scenario above counts asks
            // (invalidations, layout) and never renders, which is how
            // canvas.zoom lied. This one pumps window.displayIfNeeded per step
            // and counts executed title-bar draws. Display-dependent: its
            // matrix leg sits behind CONTINUUM_SKIP_UI_BASELINES.
            Scenario(name: "canvas.raster", run: { try canvasRaster() }),
            // The streaming axis, and the same slope argument as camera-slope one
            // line up: the cost driver is HISTORY LENGTH, so a fixture that never
            // varies it can be green while a delta is linear in the conversation.
            // The name shares no prefix with canvas.* — the filter is prefix-matched.
            Scenario(name: "transcript.delta", run: { try transcriptDelta() }),
            Scenario(name: "canvas.stress", isStress: true, run: { try canvasStress() })
        ]
    }

    // MARK: - Scenario: camera cost against INSTALLED tile count

    /// Does a camera step cost more simply because more tiles exist?
    ///
    /// The three fixed-canvas scenarios can all be green while the camera is
    /// still O(installed tiles) — they just never change that number. This one
    /// sweeps installed tiles `16 → 128` while holding the VISIBLE count fixed
    /// (a small cluster near the origin stays on screen; the filler tiles sit far
    /// outside the viewport at every zoom used), and reports the slope.
    ///
    /// What it asserts, and why each budget exists:
    ///
    /// - `cameraMutations` — the camera should write ONE ancestor's geometry per
    ///   step. Today nothing does, so this reads 0 and is RED. It turns green
    ///   when the retained world plane lands (.plans/22 Slice 3).
    /// - `tileGeometryWrites` / `writeSlope` — a camera step must not touch tile
    ///   geometry at all, so growing the installed count must not grow the work.
    ///   Today every installed tile takes a frame-origin write every step, so
    ///   both are RED and the slope is exactly the tile-count delta.
    /// - `screenFrameMismatches` — the correctness invariant, GREEN today and
    ///   required to stay green: every visible tile sits where
    ///   `CanvasEngine.tileScreenFrame` says. This is what makes the zeroes above
    ///   trustworthy; a canvas that stopped moving tiles would report zero writes
    ///   and zero mutations too, and only this budget would catch it.
    ///
    /// Duration here is a coarse alarm and NOT the scaling signal: the fixture
    /// deliberately uses cheap `DescriptorTileNSView`s so 128 tiles × 8
    /// configurations stays affordable in the matrix. `canvas.stress` owns the
    /// real-content cost curve.
    static func canvasCameraSlope() throws -> PerfScenarioResult {
        let installedCounts = [16, 32, 64, 128]
        let zooms: [Double] = [1.0, 0.35]
        let steps = 40
        let visibleClusterCount = 12

        struct Sample {
            let installed: Int
            let zoom: Double
            let onScreen: Int
            let mutations: Int
            let geometryWrites: Int
            let mismatches: Int
            let perStepMs: Double
        }
        var samples: [Sample] = []

        for zoom in zooms {
            for installed in installedCounts {
                let canvas = CanvasNSView(
                    canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: zoom),
                                             tiles: [], groups: [], lastActiveTileId: nil),
                    activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
                )
                canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
                let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.contentView = canvas
                window.orderFrontOffscreenForChecks()

                var tiles: [Tile] = []
                for index in 0..<installed {
                    // The first `visibleClusterCount` tiles form the on-screen
                    // cluster; everything after sits far enough out to be
                    // off-screen at zoom 1.0 AND at 0.35 (where the viewport
                    // covers ~4571 x 2857 world units), and stays off-screen
                    // across the pan below.
                    let frame: TileFrame
                    if index < visibleClusterCount {
                        frame = TileFrame(x: Double(index % 4) * 380 + 40,
                                          y: Double(index / 4) * 300 + 60,
                                          width: 340, height: 240)
                    } else {
                        let filler = index - visibleClusterCount
                        frame = TileFrame(x: 9_000 + Double(filler % 16) * 500,
                                          y: 7_000 + Double(filler / 16) * 400,
                                          width: 340, height: 240)
                    }
                    tiles.append(Tile(
                        id: UUID(), kind: .note, title: "slope-\(index)",
                        frame: frame, zPosition: .fromLegacyRank(index + 1),
                        runtimeRef: nil, metadata: TileMetadata()
                    ))
                }
                // `install` is what appends to the flat model, so the harness
                // does not (and cannot) write `canvasState` itself.
                for tile in tiles {
                    canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
                }
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()

                guard canvas.qaTotalInstalledTileCount == installed else {
                    throw Failure(message: "camera-slope harness must install \(installed) tiles; got \(canvas.qaTotalInstalledTileCount)")
                }

                let onScreen = canvas.qaTilesIntersectingViewport
                canvas.qaResetCameraLayoutStats()
                let start = ProcessInfo.processInfo.systemUptime
                for step in 0..<steps {
                    // Start at 1, not 0: the settle above already put the camera at
                    // the origin, so a step-0 pan to (0,0) moves nothing and is
                    // correctly skipped by the camera's own unchanged-value guard.
                    // Counting it as a step would make "one mutation per step" an
                    // off-by-one instead of an invariant.
                    let t = Double(step + 1)
                    canvas.setViewport(CanvasViewport(x: t * 12, y: t * 8, zoom: zoom))
                    canvas.layoutSubtreeIfNeeded()
                }
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let stats = canvas.qaCameraLayoutStats
                samples.append(Sample(
                    installed: installed, zoom: zoom, onScreen: onScreen,
                    mutations: stats.cameraMutations,
                    geometryWrites: stats.frameWrites + stats.boundsWrites,
                    mismatches: canvas.qaTileScreenFrameMismatchCount,
                    perStepMs: seconds / Double(steps) * 1_000
                ))
                window.orderOut(nil)
                window.contentView = nil
            }
        }

        // The visible count must be constant across a zoom's sweep, or the slope
        // conflates "more installed" with "more visible" and proves nothing.
        for zoom in zooms {
            let onScreenCounts = Set(samples.filter { $0.zoom == zoom }.map(\.onScreen))
            guard onScreenCounts.count == 1 else {
                throw Failure(message: "camera-slope must hold the visible count fixed at zoom \(zoom); saw \(onScreenCounts.sorted())")
            }
        }

        // Slope = the per-step work added by going from the smallest installed
        // count to the largest, summed over both zooms. Zero is the contract.
        var writeSlope = 0.0
        for zoom in zooms {
            let atZoom = samples.filter { $0.zoom == zoom }
            guard let smallest = atZoom.first(where: { $0.installed == installedCounts.first }),
                  let largest = atZoom.first(where: { $0.installed == installedCounts.last })
            else { throw Failure(message: "camera-slope is missing an endpoint at zoom \(zoom)") }
            writeSlope += Double(largest.geometryWrites - smallest.geometryWrites) / Double(steps)
        }

        let totalMutations = samples.reduce(0) { $0 + $1.mutations }
        let totalWrites = samples.reduce(0) { $0 + $1.geometryWrites }
        let totalMismatches = samples.reduce(0) { $0 + $1.mismatches }
        let worstStepMs = samples.map(\.perStepMs).max() ?? 0
        let expectedMutations = Double(steps * samples.count)

        var measurements: [PerfMeasurement] = []
        measurements.append(PerfBudget(
            metric: "camera-slope.cameraMutations",
            limit: .exactly(expectedMutations),
            unit: .count,
            rationale: "a camera step should move ONE ancestor; today no single place applies the camera, so this is zero until the retained world plane lands"
        ).evaluate(Double(totalMutations)))

        measurements.append(PerfBudget(
            metric: "camera-slope.tileGeometryWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "moving the camera must not write any tile's geometry, at any installed count"
        ).evaluate(Double(totalWrites)))

        measurements.append(PerfBudget(
            metric: "camera-slope.writeSlope",
            limit: .exactly(0),
            unit: .count,
            rationale: "per-step camera work must not grow with tiles the user cannot see: work(128 tiles) - work(16 tiles) per step"
        ).evaluate(writeSlope))

        measurements.append(PerfBudget(
            metric: "camera-slope.screenFrameMismatches",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: every visible tile must sit exactly where CanvasEngine says, so the zero counts above cannot be satisfied by a canvas that stopped moving tiles"
        ).evaluate(Double(totalMismatches)))

        measurements.append(PerfBudget(
            metric: "camera-slope.worstStepDuration",
            limit: .atMost(frameBudgetMs),
            unit: .milliseconds,
            rationale: "coarse alarm only — cheap descriptor tiles understate real content cost, which canvas.stress owns"
        ).evaluate(worstStepMs))

        let detail = "\(steps) pan steps per configuration, installed "
            + installedCounts.map(String.init).joined(separator: "/")
            + " at zoom " + zooms.map { String(format: "%.2f", $0) }.joined(separator: "/")
            + "; " + samples.map {
                "\($0.installed)@\(String(format: "%.2f", $0.zoom)): \($0.onScreen) on screen, "
                + "\($0.geometryWrites / steps) writes/step, \(String(format: "%.2f", $0.perStepMs)) ms"
            }.joined(separator: " | ")
        return PerfScenarioResult(name: "canvas.camera-slope", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: ZOOM cost against installed tile count

    /// Is a zoom step O(1) in tiles?
    ///
    /// `canvas.camera-slope` proves that for a PAN and nothing proves it for a
    /// zoom, which is the gap this fills. The distinction is not academic: a pan
    /// moves the plane's bounds origin and touches no tile, while a zoom step also
    /// refreshes every tile's zoom-dependent chrome — and it does so over
    /// `tileViewsInVisualOrder`, which is every INSTALLED tile, not just the ones
    /// on screen. So the suspected shape is worse than O(visible): it is
    /// O(installed), and a tile parked far off-screen costs a real canvas exactly
    /// as much as one the user is looking at.
    ///
    /// Same construction as the pan slope: sweep installed 16 -> 128 with the
    /// VISIBLE count pinned, and report the slope. Zero is the contract.
    ///
    /// Cheap `DescriptorTileNSView`s keep 128 tiles affordable. That deliberately
    /// understates the per-tile cost of a real agent tile — this scenario answers
    /// "does the work grow with tile count", not "what does one tile cost".
    static func canvasZoomSlope() throws -> PerfScenarioResult {
        let installedCounts = [16, 32, 64, 128]
        let steps = 40
        let visibleClusterCount = 12

        struct Sample {
            let installed: Int
            let onScreen: Int
            let chromeRedraws: Int
            let layoutPasses: Int
            let mutations: Int
            let mismatches: Int
            let perStepMs: Double
        }
        var samples: [Sample] = []

        for installed in installedCounts {
            let canvas = CanvasNSView(
                canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                         tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
            )
            canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()

            for index in 0..<installed {
                // The visible cluster sits near the origin; filler is parked far
                // enough out to stay off-screen across the whole 0.4–1.0 sweep
                // (at zoom 0.4 the viewport covers ~4000 x 2500 world units).
                let frame: TileFrame
                if index < visibleClusterCount {
                    frame = TileFrame(x: Double(index % 4) * 380 + 40,
                                      y: Double(index / 4) * 300 + 60,
                                      width: 340, height: 240)
                } else {
                    let filler = index - visibleClusterCount
                    frame = TileFrame(x: 9_000 + Double(filler % 16) * 500,
                                      y: 7_000 + Double(filler / 16) * 400,
                                      width: 340, height: 240)
                }
                let tile = Tile(
                    id: UUID(), kind: .note, title: "zoom-slope-\(index)",
                    frame: frame, zPosition: .fromLegacyRank(index + 1),
                    runtimeRef: nil, metadata: TileMetadata()
                )
                canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
            }
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()

            guard canvas.qaTotalInstalledTileCount == installed else {
                throw Failure(message: "zoom-slope harness must install \(installed) tiles; got \(canvas.qaTotalInstalledTileCount)")
            }

            let onScreen = canvas.qaTilesIntersectingViewport
            canvas.qaResetCameraLayoutStats()
            let chromeBefore = canvas.qaTotalTileChromeRedrawCount
            let passesBefore = canvas.qaTotalTileLayoutPassCount
            let start = ProcessInfo.processInfo.systemUptime
            for step in 0..<steps {
                let zoom = 0.4 + 0.6 * (1 + sin(Double(step) / 6.0)) / 2
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
            }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            samples.append(Sample(
                installed: installed,
                onScreen: onScreen,
                chromeRedraws: canvas.qaTotalTileChromeRedrawCount - chromeBefore,
                layoutPasses: canvas.qaTotalTileLayoutPassCount - passesBefore,
                mutations: canvas.qaCameraLayoutStats.cameraMutations,
                mismatches: canvas.qaTileScreenFrameMismatchCount,
                perStepMs: seconds / Double(steps) * 1_000
            ))
            window.orderOut(nil)
            window.contentView = nil
        }

        // The visible count must be constant, or the slope conflates "more
        // installed" with "more visible" and proves nothing.
        let onScreenCounts = Set(samples.map(\.onScreen))
        guard onScreenCounts.count == 1 else {
            throw Failure(message: "zoom-slope must hold the visible count fixed; saw \(onScreenCounts.sorted())")
        }

        guard let smallest = samples.first, let largest = samples.last else {
            throw Failure(message: "zoom-slope is missing a sweep endpoint")
        }
        let chromeSlope = Double(largest.chromeRedraws - smallest.chromeRedraws) / Double(steps)
        let passSlope = Double(largest.layoutPasses - smallest.layoutPasses) / Double(steps)
        let durationSlope = largest.perStepMs - smallest.perStepMs

        var measurements: [PerfMeasurement] = []

        measurements.append(PerfBudget(
            metric: "magnify-slope.chromeRedrawSlope",
            limit: .exactly(0),
            unit: .count,
            rationale: "per-step chrome work must not grow with tiles the user cannot see: work(128) - work(16), per step"
        ).evaluate(chromeSlope))

        measurements.append(PerfBudget(
            metric: "magnify-slope.layoutPassSlope",
            limit: .exactly(0),
            unit: .count,
            rationale: "the same for tile layout: a zoom step must lay out no more tiles because more exist off-screen"
        ).evaluate(passSlope))

        measurements.append(PerfBudget(
            metric: "magnify-slope.durationSlope",
            limit: .atMost(0.5),
            unit: .milliseconds,
            rationale: "the wall-clock consequence: going from 16 to 128 installed tiles must not measurably slow a zoom step"
        ).evaluate(durationSlope))

        measurements.append(PerfBudget(
            metric: "magnify-slope.worstStepDuration",
            limit: .atMost(frameBudgetMs),
            unit: .milliseconds,
            rationale: "coarse alarm; cheap descriptor tiles understate a real agent tile, which canvas.stress owns"
        ).evaluate(samples.map(\.perStepMs).max() ?? 0))

        measurements.append(PerfBudget(
            metric: "magnify-slope.cameraMutations",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera must actually have zoomed — zero means the gesture did nothing, not that it got cheap"
        ).evaluate(Double(samples.reduce(0) { $0 + $1.mutations })))

        measurements.append(PerfBudget(
            metric: "magnify-slope.screenFrameMismatches",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: every visible tile must sit where CanvasEngine says, so the zeroes above cannot be met by a canvas that stopped presenting"
        ).evaluate(Double(samples.reduce(0) { $0 + $1.mismatches })))

        let detail = "\(steps) zoom steps per configuration, installed "
            + installedCounts.map(String.init).joined(separator: "/")
            + "; " + samples.map {
                "\($0.installed): \($0.onScreen) on screen, "
                + "\($0.chromeRedraws / steps) chrome/step, \($0.layoutPasses / steps) layouts/step, "
                + String(format: "%.2f ms", $0.perStepMs)
            }.joined(separator: " | ")
        return PerfScenarioResult(name: "canvas.magnify-slope", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: document-relationship overlay cost during a zoom sweep

    /// Does a zoom step touch the document-relationship overlay at all?
    ///
    /// `CanvasNSView.updateDocumentRelationshipOverlay` used to run from
    /// `syncWorldPlaneToCamera` on every camera step: a full re-walk of every
    /// installed tile (`tileIndexVisits`) and every document link
    /// (`linkEvaluations`), plus an unconditional viewport-sized frame write
    /// (`frameWrites`) — all of it on a canvas with ZERO document links, since
    /// there was no early-out. `.plans/44` item 1.
    ///
    /// Two arms over the SAME fixture shape (installed tiles held fixed, only
    /// the presence of document links differs), each swept through 40 zoom
    /// steps:
    ///
    /// 1. No document links at all — the common case. The overlay must not be
    ///    touched.
    /// 2. Several real links between installed tiles — the overlay is now a
    ///    world-space sibling (frame sized to content, not the viewport), so a
    ///    camera step still must not touch it: the connectors track the
    ///    camera for free via the normal view hierarchy, the same way tiles do.
    ///
    /// The teeth: `segmentCountAfterZoom` proves arm 2 actually drew something
    /// (an early-out that fired unconditionally would zero this too), and
    /// `cameraMutations` proves the sweep really moved the camera.
    static func canvasDocumentRelationshipZoomCost() throws -> PerfScenarioResult {
        let installed = 24
        let linkedPairCount = 6
        let steps = 40

        struct Arm {
            let label: String
            let updateCalls: Int
            let tileIndexVisits: Int
            let linkEvaluations: Int
            let frameWrites: Int
            let segmentCountAfterZoom: Int
            let cameraMutations: Int
        }

        func runArm(withLinks: Bool) throws -> Arm {
            let canvas = CanvasNSView(
                canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                         tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
            )
            canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()

            var tiles: [Tile] = []
            for index in 0..<installed {
                let frame = TileFrame(x: Double(index % 6) * 260 + 40, y: Double(index / 6) * 260 + 60,
                                      width: 220, height: 180)
                let tile = Tile(id: UUID(), kind: .note, title: "doc-rel-\(index)",
                                frame: frame, zPosition: .fromLegacyRank(index + 1),
                                runtimeRef: nil, metadata: TileMetadata())
                tiles.append(tile)
                canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
            }
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()

            if withLinks {
                var links: [DocumentAgentLink] = []
                var agentTileIds: [AgentID: UUID] = [:]
                let now = Date(timeIntervalSince1970: 1_900_000_000)
                for pairIndex in 0..<linkedPairCount {
                    let agentId = AgentID(rawValue: UUID())
                    agentTileIds[agentId] = tiles[pairIndex * 2].id
                    links.append(DocumentAgentLink(agentId: agentId, documentTileId: tiles[pairIndex * 2 + 1].id,
                                                   createdAt: now, updatedAt: now))
                }
                canvas.setDocumentRelationships(links, agentTileIds: agentTileIds)
                canvas.layoutSubtreeIfNeeded()
            }

            canvas.qaResetDocumentRelationshipStats()
            canvas.qaResetCameraLayoutStats()
            for step in 0..<steps {
                let zoom = 0.4 + 0.6 * (1 + sin(Double(step) / 6.0)) / 2
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
            }
            let stats = canvas.qaDocumentRelationshipStats
            let arm = Arm(
                label: withLinks ? "with \(linkedPairCount) links" : "no links",
                updateCalls: stats.updateCalls,
                tileIndexVisits: stats.tileIndexVisits,
                linkEvaluations: stats.linkEvaluations,
                frameWrites: stats.frameWrites,
                segmentCountAfterZoom: canvas.qaDocumentRelationshipSegmentCount,
                cameraMutations: canvas.qaCameraLayoutStats.cameraMutations
            )
            window.orderOut(nil)
            window.contentView = nil
            return arm
        }

        let noLinks = try runArm(withLinks: false)
        let withLinks = try runArm(withLinks: true)

        var measurements: [PerfMeasurement] = []

        for arm in [noLinks, withLinks] {
            let prefix = "document-relationship-zoom-cost.\(arm.label == "no links" ? "empty" : "linked")"
            measurements.append(PerfBudget(
                metric: "\(prefix).updateCalls",
                limit: .exactly(0),
                unit: .count,
                rationale: "a camera step must not invoke updateDocumentRelationshipOverlay at all — "
                    + "it is a world-space sibling now, camera-invariant by construction"
            ).evaluate(Double(arm.updateCalls)))

            measurements.append(PerfBudget(
                metric: "\(prefix).tileIndexVisits",
                limit: .exactly(0),
                unit: .count,
                rationale: "no camera step may re-walk installed tiles for this overlay"
            ).evaluate(Double(arm.tileIndexVisits)))

            measurements.append(PerfBudget(
                metric: "\(prefix).linkEvaluations",
                limit: .exactly(0),
                unit: .count,
                rationale: "no camera step may re-evaluate document links"
            ).evaluate(Double(arm.linkEvaluations)))

            measurements.append(PerfBudget(
                metric: "\(prefix).frameWrites",
                limit: .exactly(0),
                unit: .count,
                rationale: "the overlay's frame tracks content, not the viewport — a camera step must "
                    + "never rewrite it"
            ).evaluate(Double(arm.frameWrites)))
        }

        measurements.append(PerfBudget(
            metric: "document-relationship-zoom-cost.segmentCountAfterZoom",
            limit: .atLeast(Double(linkedPairCount)),
            unit: .count,
            rationale: "teeth: the linked arm must still have every connector drawn after the sweep — "
                + "zero updates must not mean zero output"
        ).evaluate(Double(withLinks.segmentCountAfterZoom)))

        measurements.append(PerfBudget(
            metric: "document-relationship-zoom-cost.cameraMutations",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the sweep must have actually moved the camera in both arms"
        ).evaluate(Double(min(noLinks.cameraMutations, withLinks.cameraMutations))))

        let detail = "\(steps) zoom steps, \(installed) installed tiles; "
            + "no links: \(noLinks.updateCalls) update calls / \(noLinks.tileIndexVisits) tile visits; "
            + "\(linkedPairCount) links: \(withLinks.updateCalls) update calls / "
            + "\(withLinks.tileIndexVisits) tile visits / \(withLinks.segmentCountAfterZoom) segments after sweep"
        return PerfScenarioResult(name: "canvas.document-relationship-zoom-cost", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: the zoom→pan transition

    /// Does a pan step cost more because a zoom preceded it?
    ///
    /// Every other camera scenario drives ONE pure gesture, so all of them were
    /// green while the felt defect lived at the seam: deferred zoom work — a
    /// settle burst, re-armed debounce timers, chrome floors still moving —
    /// landing on the first pan frames after a zoom. Four windows over the
    /// `canvas.pan`/`canvas.zoom` fixture (same 3 Markdown documents + 9 notes,
    /// so the numbers are comparable):
    ///
    /// - P  — steady-state pan at a fixed zoom: the baseline.
    /// - T  — 30 zoom steps then IMMEDIATELY 30 pan steps at the final zoom:
    ///        the user's exact complaint, isolated. The pan window must inherit
    ///        nothing: zero chrome redraws, zero layout passes.
    /// - Zc — a pure-zoom control over a fixed zoom sequence.
    /// - I  — a strict interleave (pan step after every zoom step) over the
    ///        SAME zoom sequence as Zc, so interleaving pans must add exactly
    ///        zero chrome/layout work over the control. This defeats any
    ///        per-gesture caching a fix might install and any zoom-cost
    ///        differences bucket crossings would otherwise smuggle in.
    static func canvasGestureTransition() throws -> PerfScenarioResult {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("continuum-perf-gesture-transition-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let root = tempRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The canvas.pan / canvas.zoom fixture, verbatim: comparability against
        // their published numbers is the point of measuring on the same tiles.
        let harness = try makeHarness(root: root, tempRoot: tempRoot)
        let canvas = harness.canvas
        for index in 0..<3 {
            let path = root.appendingPathComponent("doc-\(index).md")
            try documentFixture(index: index).write(to: path, atomically: true, encoding: .utf8)
            guard case .opened = harness.runtime.openProjectFile(path: path.path) else {
                throw Failure(message: "the fixture document must open as a tile")
            }
        }
        guard let spawner = harness.runtime.activeController?.tileSpawner else {
            throw Failure(message: "the harness must expose the active project's tile spawner")
        }
        for index in 0..<9 {
            if case let .failure(error) = spawner.spawnNote(title: "perf-note-\(index)") {
                throw Failure(message: "spawning a note tile failed: \(error)")
            }
        }
        canvas.layoutSubtreeIfNeeded()
        let tileCount = canvas.qaTotalInstalledTileCount
        guard tileCount >= 12 else {
            throw Failure(message: "the fixture canvas must hold a realistic number of tiles; got \(tileCount)")
        }

        let panZoom = 0.7
        // The zoom sequence Zc and I share. Same construction as canvas.zoom's
        // sweep (never repeat a value), compressed to 30 steps.
        func zoomValue(_ step: Int) -> Double { 0.4 + 0.6 * (1 + sin(Double(step) / 6.0)) / 2 }

        struct Window {
            let chromeRedraws: Int
            let layoutPasses: Int
            let stepMs: [Double]
        }
        func runWindow(_ count: Int, viewport: (Int) -> CanvasViewport) -> Window {
            let chromeBefore = canvas.qaTotalTileChromeRedrawCount
            let passesBefore = canvas.qaTotalTileLayoutPassCount
            var stepMs: [Double] = []
            stepMs.reserveCapacity(count)
            for step in 0..<count {
                let start = ProcessInfo.processInfo.systemUptime
                canvas.setViewport(viewport(step))
                canvas.layoutSubtreeIfNeeded()
                stepMs.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            return Window(
                chromeRedraws: canvas.qaTotalTileChromeRedrawCount - chromeBefore,
                layoutPasses: canvas.qaTotalTileLayoutPassCount - passesBefore,
                stepMs: stepMs
            )
        }
        // Settle steps run OUTSIDE the measured windows: crossing back to the
        // pan zoom costs chrome by design and must not be charged to a window.
        func settle(x: Double = 0, y: Double = 0, zoom: Double) {
            canvas.setViewport(CanvasViewport(x: x, y: y, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
        }

        settle(zoom: panZoom)
        canvas.qaResetCameraLayoutStats()
        let proseBefore = AssistantProseView.qaMeasurementCount
        let invalidationsBefore = canvas.qaTotalTileLayoutInvalidationCount

        // P — steady-state pan baseline.
        let pure = runWindow(60) { step in
            CanvasViewport(x: Double(step) * 3, y: Double(step) * 2, zoom: panZoom)
        }
        let panMedianMs = pure.stepMs.sorted()[pure.stepMs.count / 2]

        // T — the handoff: a zoom sweep, then the pan begins where it ended.
        settle(x: 120, y: 90, zoom: panZoom)
        _ = runWindow(30) { step in CanvasViewport(x: 120, y: 90, zoom: zoomValue(step)) }
        let handoffZoom = zoomValue(29)
        let transitionPan = runWindow(30) { step in
            CanvasViewport(x: 120 + Double(step + 1) * 3, y: 90 + Double(step + 1) * 2, zoom: handoffZoom)
        }

        // Zc — the pure-zoom control for the interleave.
        settle(x: 120, y: 90, zoom: panZoom)
        let control = runWindow(30) { step in CanvasViewport(x: 120, y: 90, zoom: zoomValue(step)) }

        // I — strict interleave over the SAME zoom sequence: every pan step is
        // a first-pan-after-zoom.
        settle(x: 120, y: 90, zoom: panZoom)
        let interleave = runWindow(60) { step in
            let k = step / 2
            let x = 120 + Double(k + step % 2) * 3
            let y = 90 + Double(k + step % 2) * 2
            return CanvasViewport(x: x, y: y, zoom: zoomValue(k))
        }

        // Structural guards, in the slope scenarios' style: a degenerate drive
        // makes every zero budget pass vacuously, so prove the interleave really
        // mixed both gestures before believing any of them.
        let interleaveZooms = Set((0..<30).map { (zoomValue($0) * 10_000).rounded() })
        guard interleaveZooms.count >= 2 else {
            throw Failure(message: "the interleave must walk at least two distinct zooms; got \(interleaveZooms.count)")
        }
        guard abs(canvas.viewport.x - 120) > 1 else {
            throw Failure(message: "the interleave must actually pan; x stayed at \(canvas.viewport.x)")
        }

        let stats = canvas.qaCameraLayoutStats
        let prose = AssistantProseView.qaMeasurementCount - proseBefore
        let invalidations = canvas.qaTotalTileLayoutInvalidationCount - invalidationsBefore
        let allStepMs = pure.stepMs + transitionPan.stepMs + control.stepMs + interleave.stepMs
        let transitionSpikeMs = (transitionPan.stepMs.prefix(5).max() ?? 0) - panMedianMs

        var measurements: [PerfMeasurement] = []

        measurements.append(PerfBudget(
            metric: "gesture-transition.transitionPanChromeRedraws",
            limit: .exactly(0),
            unit: .count,
            rationale: "a pan at the handed-off zoom changes no chrome floor; a nonzero here is zoom work leaking into the pan window"
        ).evaluate(Double(transitionPan.chromeRedraws)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.transitionPanLayoutPasses",
            limit: .exactly(0),
            unit: .count,
            rationale: "the pan window must not inherit the zoom's per-tile layout — a value near the tile count is the deferred settling flush arriving on the first pan frames, which is the felt spike"
        ).evaluate(Double(transitionPan.layoutPasses)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.excessChromeRedraws",
            limit: .exactly(0),
            unit: .count,
            rationale: "interleaved pans must add zero chrome work over the same zoom sequence run pure — the control and interleave cross identical scale buckets"
        ).evaluate(Double(interleave.chromeRedraws - control.chromeRedraws)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.excessLayoutPasses",
            limit: .exactly(0),
            unit: .count,
            rationale: "the same for layout passes: a pan step between two zoom steps is not allowed to buy extra tile layout"
        ).evaluate(Double(interleave.layoutPasses - control.layoutPasses)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.transitionStepOverhead",
            limit: .atMost(1.0),
            unit: .milliseconds,
            rationale: "the direct encoding of the complaint: the worst of the first five pan steps after a zoom, over the steady-state pan median — lag at the transition is a spike, and a mean hides it"
        ).evaluate(transitionSpikeMs))

        measurements.append(PerfBudget(
            metric: "gesture-transition.worstStepDuration",
            limit: .atMost(frameBudgetMs),
            unit: .milliseconds,
            rationale: "coarse alarm over every step of every window"
        ).evaluate(allStepMs.max() ?? 0))

        measurements.append(PerfBudget(
            metric: "gesture-transition.boundsWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "no gesture mix may resize a tile's logical bounds"
        ).evaluate(Double(stats.boundsWrites)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.modelWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "no gesture mix touches tile models"
        ).evaluate(Double(stats.modelWrites)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.proseMeasurements",
            limit: .exactly(0),
            unit: .count,
            rationale: "no gesture mix may re-measure text"
        ).evaluate(Double(prose)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.tileLayoutInvalidations",
            limit: .exactly(0),
            unit: .count,
            rationale: "the canvas must not ASK for tile relayout on any step of a mixed gesture"
        ).evaluate(Double(invalidations)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.cameraMutations",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera actually moved — zero means the drive did nothing, not that it got cheap"
        ).evaluate(Double(stats.cameraMutations)))

        measurements.append(PerfBudget(
            metric: "gesture-transition.screenFrameMismatches",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: after both gestures have composed, every visible tile sits where CanvasEngine says"
        ).evaluate(Double(canvas.qaTileScreenFrameMismatchCount)))

        let detail = "\(tileCount) tiles; P \(String(format: "%.2f", panMedianMs)) ms median | "
            + "T-pan \(transitionPan.chromeRedraws) chrome, \(transitionPan.layoutPasses) layouts, "
            + "first-5 spike \(String(format: "%.2f", transitionSpikeMs)) ms | "
            + "Zc \(control.chromeRedraws) chrome, \(control.layoutPasses) layouts | "
            + "I \(interleave.chromeRedraws) chrome, \(interleave.layoutPasses) layouts"
        return PerfScenarioResult(name: "canvas.gesture-transition", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: what a camera gesture actually RASTERIZES

    /// Every other camera scenario counts invalidations and layout — the ASK.
    /// None of them ever renders, and that blindness is how `canvas.zoom`
    /// reported "green at 4.7 ms" the morning a real pinch was visibly bad.
    /// This one pumps a real display cycle (`window.displayIfNeeded()`) after
    /// every camera step and counts the title-bar draws AppKit EXECUTED, so
    /// "a pan rasterizes no chrome" and "a zoom rasterizes chrome only at
    /// bucket crossings" are witnessed as pixels-level facts, not inferred
    /// from invalidation counts.
    ///
    /// Display-dependent by construction: it needs a WindowServer session, so
    /// its matrix leg sits behind `CONTINUUM_SKIP_UI_BASELINES` with the two
    /// baseline legs. Scope honesty: this witnesses CHROME rasterization; the
    /// deep-content rasterization a live agent tile pays (`CA::Layer` display
    /// of text/terminal surfaces) is still only visible to a profile of the
    /// real app.
    static func canvasRaster() throws -> PerfScenarioResult {
        let tileCount = 12
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for index in 0..<tileCount {
            let tile = Tile(
                id: UUID(), kind: .note, title: "raster-\(index)",
                frame: TileFrame(x: Double(index % 4) * 380 + 40,
                                 y: Double(index / 4) * 300 + 60,
                                 width: 340, height: 240),
                zPosition: .fromLegacyRank(index + 1),
                runtimeRef: nil, metadata: TileMetadata()
            )
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }

        func pump() {
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Layer-backed views do not run draw(_:) inside displayIfNeeded —
            // the backing-store update happens when the CATransaction commits,
            // which a scenario loop never lets happen on its own. The flush IS
            // the display cycle here; without it this witness counted 144
            // invalidations and 0 executed draws, which is precisely the
            // blindness it exists to close.
            CATransaction.flush()
        }
        // Drain the first render so the measured windows start from settled,
        // already-drawn bars.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump()

        // Pan window: a translation rasterizes nothing.
        let panDrawsBefore = canvas.qaTotalTitleBarDrawCount
        for step in 0..<20 {
            let t = Double(step + 1)
            canvas.setViewport(CanvasViewport(x: t * 3, y: t * 2, zoom: 1))
            pump()
        }
        let panDraws = canvas.qaTotalTitleBarDrawCount - panDrawsBefore

        // Zoom window: chrome rasterizes at bucket crossings and nowhere else.
        let zoomDrawsBefore = canvas.qaTotalTitleBarDrawCount
        let zoomInvalidationsBefore = canvas.qaTotalTileChromeRedrawCount
        for step in 0..<40 {
            let zoom = 0.4 + 0.6 * (1 + sin(Double(step) / 6.0)) / 2
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            pump()
        }
        let zoomDraws = canvas.qaTotalTitleBarDrawCount - zoomDrawsBefore
        let zoomInvalidations = canvas.qaTotalTileChromeRedrawCount - zoomInvalidationsBefore

        var measurements: [PerfMeasurement] = []

        measurements.append(PerfBudget(
            metric: "raster.panTitleBarDraws",
            limit: .exactly(0),
            unit: .count,
            rationale: "a pan is a composited translation; a single executed chrome draw means the camera is rasterizing what it only needed to move"
        ).evaluate(Double(panDraws)))

        measurements.append(PerfBudget(
            metric: "raster.zoomTitleBarDraws",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the display pump must actually rasterize — zero draws across a bucket-crossing sweep means this harness never rendered, which is the exact blindness it exists to close"
        ).evaluate(Double(zoomDraws)))

        measurements.append(PerfBudget(
            metric: "raster.zoomDrawOverdraw",
            limit: .atMost(0),
            unit: .count,
            rationale: "draws minus invalidations: every executed chrome draw must trace to an invalidation we chose — an excess is something repainting chrome without asking, which no invalidation counter can see"
        ).evaluate(Double(zoomDraws - zoomInvalidations)))

        measurements.append(PerfBudget(
            metric: "raster.zoomInvalidations",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the sweep must cross at least one chrome bucket, or the zero pan budget above passes vacuously"
        ).evaluate(Double(zoomInvalidations)))

        measurements.append(PerfBudget(
            metric: "raster.screenFrameMismatches",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: the rendered canvas still presents every visible tile where CanvasEngine says"
        ).evaluate(Double(canvas.qaTileScreenFrameMismatchCount)))

        let detail = "\(tileCount) tiles; pan 20 pumped steps: \(panDraws) draws | "
            + "zoom 40 pumped steps: \(zoomDraws) draws / \(zoomInvalidations) invalidations"
        return PerfScenarioResult(name: "canvas.raster", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: transcript delta cost against history length

    /// Does applying ONE row's delta cost more simply because the conversation is
    /// longer?
    ///
    /// This is the streaming axis of the contract in
    /// [scalability-tdd.md](../../../docs/internals/scalability-tdd.md): a delta
    /// must cost `O(changed + visible rows)` and never `O(history)`.
    ///
    /// **This scenario drives the seam production actually uses, and for most of
    /// its life it did not.** It called `apply(document:patch:)` with a real,
    /// node-level `AgentDocumentPatch` — a method with ZERO production callers.
    /// A streaming tile goes through `enqueue(document:patch:final:)` with
    /// `AgentDocumentPatch.empty(...)`, because the 30Hz scheduler coalesces
    /// several reducer results into one presentation and a caller's patch cannot
    /// describe the coalesced step. So the budgets below were measured on an
    /// incremental path nothing reached, while production full-flattened on every
    /// chunk — the same failure shape CLAUDE.md hazard 9 records for
    /// `WorkspaceRuntime.install(into:)`, and the reason a headline
    /// 50.2ms → 5.7ms win was banked on a seam nothing calls.
    ///
    /// The fixture also alternates user and assistant entries. It used to be
    /// uniformly `.assistant`, so `startsTurn` was never true, `turnRanges`
    /// returned a single range, `foldTurns` early-returned, and turn headers,
    /// `clusterSummaryText` and every tool-detail path were unreachable BY
    /// CONSTRUCTION — invisible to the gate no matter how expensive they became.
    ///
    /// The fixture sweeps history length and reports the SLOPE for the same reason
    /// `canvas.camera-slope` does: a single-size fixture can sit green while the
    /// cost is linear, because it never changes the number that drives the cost.
    /// The delta shape is a tail revision, which is what a streaming answer
    /// actually produces on every chunk.
    ///
    /// Lands KNOWN-RED by construction.
    static func transcriptDelta() throws -> PerfScenarioResult {
        let historyCounts = [10, 100, 1_000, 10_000]
        let deltas = 20

        func nodeID(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func promptBlock(_ index: Int) -> AgentBlock {
            AgentBlock(
                id: nodeID("delta-block-\(index)"), revision: 1, kind: .paragraph,
                payload: .paragraph([.text("prompt \(index)")])
            )
        }
        func fixtureBlock(_ index: Int, revision: UInt64 = 1) -> AgentBlock {
            AgentBlock(
                id: nodeID("delta-block-\(index)"), revision: revision,
                kind: AgentBlockKind(rawValue: "fixture-opaque")!,
                payload: .opaque(AgentOpaquePayload(debugLabel: "row-\(index)", value: .null))
            )
        }

        struct Sample {
            let history: Int
            let historyScansPerDelta: Double
            let visitsPerDelta: Double
            let rowsPerDelta: Double
            let fullFlattens: Int
            let deltasWithoutInvalidation: Int
            let worstInvalidated: Int
            let rowsHeld: Int
            let perDeltaMs: Double
        }
        var samples: [Sample] = []

        for history in historyCounts {
            // ONE ENTRY PER TURN, one block in each. This is the shape a real
            // conversation has, and the shape matters: a single entry holding
            // `history` blocks exercises the row walk but is structurally blind to
            // any per-delta pass over `document.entries`, and
            // `prepareToolDetailLifecycle` builds a dictionary over every entry on
            // every delta. Measuring the realistic shape catches both.
            var entries = (0..<history).map { index in
                // Alternating roles, so the document has REAL turns. A user entry
                // is what makes `startsTurn` true, and without one the whole
                // folding projection is dead code as far as this gate is
                // concerned.
                index.isMultiple(of: 2)
                    ? AgentEntry(
                        id: nodeID("delta-entry-\(index)"), revision: 1, role: .user,
                        provenance: .localPrompt(promptID: "delta-\(index)"),
                        lifecycle: .finished,
                        blocks: [promptBlock(index)])
                    : AgentEntry(
                        id: nodeID("delta-entry-\(index)"), revision: 1, role: .assistant,
                        provenance: .localNotice(reason: "transcript delta fixture"),
                        blocks: [fixtureBlock(index)])
            }
            let list = AgentTranscriptListView()
            list.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            let host = NSView(frame: list.frame)
            host.addSubview(list)
            list.autoresizingMask = [.width, .height]

            // Setup is deliberately OUTSIDE the measurement: the first render of a
            // 10,000-row document is a full index by definition, and this scenario
            // is about the cost of the next delta, not the first paint.
            try list.apply(
                document: AgentDocument(version: 1, entries: entries),
                patch: try AgentDocumentPatch(
                    fromVersion: 0, toVersion: 1,
                    inserted: entries.flatMap { $0.blocks.map(\.id) }
                )
            )
            list.flushPendingVisualUpdate()
            host.layoutSubtreeIfNeeded()
            list.collectionView.layoutSubtreeIfNeeded()

            guard list.qaSemanticRowCount == history else {
                throw Failure(message: "transcript-delta harness must hold \(history) rows; got \(list.qaSemanticRowCount)")
            }

            // Every sweep size is even, so the last entry is the ASSISTANT half of
            // the final turn — which is what a streaming answer actually revises.
            let tailIndex = history - 1
            let tailEntryID = entries[tailIndex].id
            let tailID = entries[tailIndex].blocks[0].id
            var deltasWithoutInvalidation = 0
            var worstInvalidated = 0
            list.qaResetFlattenStats()
            let start = ProcessInfo.processInfo.systemUptime
            for step in 0..<deltas {
                // A streaming answer revises its OPEN tail block on every chunk, so
                // the revision advances while the id and the position stay put.
                let version = UInt64(step + 2)
                entries[tailIndex] = AgentEntry(
                    id: tailEntryID, revision: version, role: .assistant,
                    provenance: .localNotice(reason: "transcript delta fixture"),
                    blocks: [fixtureBlock(tailIndex, revision: version)]
                )
                // EXACTLY what `ManagedAgentTileNSView` does per chunk: one
                // version step carrying the reducer's own changed set, through the
                // coalescing scheduler. The two things that make this faithful and
                // that it previously got wrong are (1) `enqueue`, not the
                // `apply(document:patch:)` seam which has no production callers,
                // and (2) a patch naming only what a content delta touches — the
                // tile drains it from the model rather than diffing documents.
                try list.enqueue(
                    document: AgentDocument(version: version, entries: entries),
                    patch: try AgentDocumentPatch(
                        fromVersion: version - 1, toVersion: version,
                        updated: [tailID, tailEntryID])
                )
                // The scheduler gates presentation at 30Hz; a gate that let it
                // coalesce would measure a fraction of the deltas and call the
                // rest free. Flushing every step measures the per-delta cost the
                // budget names, which is also what a slow chunk rate produces.
                list.flushPendingVisualUpdate()
                let invalidated = list.qaLastInvalidatedTopLevelCount
                if invalidated == 0 { deltasWithoutInvalidation += 1 }
                worstInvalidated = max(worstInvalidated, invalidated)
            }
            let seconds = ProcessInfo.processInfo.systemUptime - start

            samples.append(Sample(
                history: history,
                historyScansPerDelta: Double(list.qaHistoryScanCount) / Double(deltas),
                visitsPerDelta: Double(list.qaFlattenNodeVisits) / Double(deltas),
                rowsPerDelta: Double(list.qaFlattenedRowCount) / Double(deltas),
                fullFlattens: list.qaFullFlattenCount,
                deltasWithoutInvalidation: deltasWithoutInvalidation,
                worstInvalidated: worstInvalidated,
                rowsHeld: list.qaSemanticRowCount,
                perDeltaMs: seconds / Double(deltas) * 1_000
            ))
            list.removeFromSuperview()
        }

        guard let smallest = samples.first(where: { $0.history == historyCounts.first }),
              let largest = samples.first(where: { $0.history == historyCounts.last })
        else { throw Failure(message: "transcript-delta is missing a sweep endpoint") }

        let worstHistoryScans = samples.map(\.historyScansPerDelta).max() ?? 0
        let visitSlope = largest.visitsPerDelta - smallest.visitsPerDelta
        let worstVisits = samples.map(\.visitsPerDelta).max() ?? 0
        let totalFullFlattens = samples.reduce(0) { $0 + $1.fullFlattens }
        let totalDeltasWithoutInvalidation = samples.reduce(0) { $0 + $1.deltasWithoutInvalidation }
        let worstInvalidated = samples.map(\.worstInvalidated).max() ?? 0
        let rowsLost = samples.reduce(0) { $0 + ($1.history - $1.rowsHeld) }
        let worstDeltaMs = samples.map(\.perDeltaMs).max() ?? 0

        // The bound is "the change plus what is on screen". The fixture's viewport
        // holds well under a hundred rows and the changed subtree is one block, so
        // any correct implementation lands far below this; 10,000 does not.
        let localityBound = 64.0

        var measurements: [PerfMeasurement] = []

        measurements.append(PerfBudget(
            metric: "transcript-delta.worstHistoryScansPerDelta",
            limit: .exactly(0),
            unit: .count,
            rationale: "a content-only delta must not walk the whole applied history; the row index made the INDEX incremental while the presentation half kept rebuilding every per-row structure, which is why the wall clock never moved"
        ).evaluate(worstHistoryScans))

        measurements.append(PerfBudget(
            metric: "transcript-delta.visitSlope",
            limit: .exactly(0),
            unit: .count,
            rationale: "extra block nodes walked per delta when the history grows from \(historyCounts.first ?? 0) to \(historyCounts.last ?? 0) rows; the streaming contract makes this zero"
        ).evaluate(visitSlope))

        measurements.append(PerfBudget(
            metric: "transcript-delta.worstVisitsPerDelta",
            limit: .atMost(localityBound),
            unit: .count,
            rationale: "one revised tail row must re-index the changed subtree and the visible rows, not the conversation"
        ).evaluate(worstVisits))

        measurements.append(PerfBudget(
            metric: "transcript-delta.fullFlattens",
            limit: .exactly(0),
            unit: .count,
            rationale: "a patch that names its changed nodes must not trigger a whole-document rebuild"
        ).evaluate(Double(totalFullFlattens)))

        measurements.append(PerfBudget(
            metric: "transcript-delta.rowsLost",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: every row must still be present after the sweep, so the zeroes above cannot be met by a transcript that dropped its history"
        ).evaluate(Double(rowsLost)))

        measurements.append(PerfBudget(
            metric: "transcript-delta.deltasWithoutInvalidation",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: every delta must invalidate the top-level row it changed — a delta that invalidates nothing did not get cheap, it stopped working"
        ).evaluate(Double(totalDeltasWithoutInvalidation)))

        measurements.append(PerfBudget(
            metric: "transcript-delta.worstInvalidatedTopLevel",
            limit: .atMost(2),
            unit: .count,
            rationale: "the CHANGED half of changed+visible: revising one tail block must invalidate that row, not fan out across the entry's siblings"
        ).evaluate(Double(worstInvalidated)))

        measurements.append(PerfBudget(
            metric: "transcript-delta.worstDeltaDuration",
            limit: .atMost(frameBudgetMs),
            unit: .milliseconds,
            rationale: "a streaming chunk arrives many times a second; applying one must fit inside a frame"
        ).evaluate(worstDeltaMs))

        let detail = "\(deltas) tail-revision deltas per configuration, one block per entry, history "
            + historyCounts.map(String.init).joined(separator: "/")
            + "; " + samples.map {
                "\($0.history): \(String(format: "%.0f", $0.visitsPerDelta)) nodes/delta, "
                + "\(String(format: "%.0f", $0.rowsPerDelta)) rows/delta, "
                + "\(String(format: "%.3f", $0.perDeltaMs)) ms"
            }.joined(separator: " | ")
        return PerfScenarioResult(name: "transcript.delta", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: bounds-stepping versus held geometry

    /// How much of a real managed-agent zoom frame is recoverable if the world
    /// plane's bounds size stops changing on every tick?
    ///
    /// This deliberately does NOT present held zoom pixels. That mechanism is
    /// the design decision this probe precedes. Instead it isolates the causal
    /// AppKit write from the real-pinch profile: A steps the plane's bounds size
    /// through every target; B pumps the same number of display frames with the
    /// bounds held, then pays one final bake. The result is an upper bound on the
    /// geometry/backing work a supported presentation mechanism may recover.
    static func canvasGeometryHoldProbe() throws -> PerfScenarioResult {
        // Defaults preserve the gating witness. The opt-in overrides let the
        // architecture probe measure the final one-bake slope at realistic
        // workspace sizes without cloning a second, subtly different harness.
        let tileCount = Int(ProcessInfo.processInfo.environment["PERF_GEOMETRY_HOLD_TILES"] ?? "") ?? 10
        let turnsPerAgent = Int(ProcessInfo.processInfo.environment["PERF_GEOMETRY_HOLD_TURNS"] ?? "") ?? 6
        let steps = Int(ProcessInfo.processInfo.environment["PERF_GEOMETRY_HOLD_STEPS"] ?? "") ?? 60
        guard tileCount > 0, turnsPerAgent > 0, steps > 0 else {
            throw Failure(message: "geometry-hold overrides must all be positive")
        }
        let baselineZoom = 1.0
        let finalZoom = 0.45

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: baselineZoom),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let zoneId = UUID()
        let placement = ZonePlacement(
            zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
            size: ZoneSize(width: 2_500, height: 900), color: "blue",
            collapsed: false, hydrationPolicy: .automatic
        )
        var tiles: [Tile] = []
        for index in 0..<tileCount {
            let x = Double(index % 5) * 480 + 40
            let y = Double(index / 5) * 360 + 60
            let frame = TileFrame(x: x, y: y, width: 420, height: 300)
            tiles.append(Tile(
                id: UUID(), kind: .managedAgent, title: "geometry-hold-\(index)", frame: frame,
                zPosition: .fromLegacyRank(index + 1), zoneId: zoneId,
                runtimeRef: nil, metadata: TileMetadata()
            ))
        }
        let layer = CanvasNSView.ZoneLayer(
            placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Geometry hold probe"),
            tiles: tiles
        )
        for (index, tile) in tiles.enumerated() {
            let view = ManagedAgentTileNSView(tile: tile, threadId: "geometry-hold-\(index)")
            view.renderRehydratedPreviousSession(
                transcriptFixture(threadId: "geometry-hold-\(index)", turns: turnsPerAgent)
            )
            layer.tileViews[tile.id] = view
        }
        canvas.setZones([layer])

        func pump() {
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // The backing store commits here, not in `displayIfNeeded()`; without
            // this flush the raster witness observed 144 invalidations and zero
            // executed draws. Timing without it would recreate that blindness.
            CATransaction.flush()
        }

        func milliseconds(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }

        func resetToBaseline() {
            _ = canvas.worldPlane.applyCamera(
                viewportSize: canvas.bounds.size, worldOrigin: .zero, zoom: baselineZoom
            )
            pump()
            canvas.worldPlane.qaResetBoundsSizeWriteCount()
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
            return sorted[min(max(index, 0), sorted.count - 1)]
        }

        let targets = (1...steps).map { step in
            baselineZoom + (finalZoom - baselineZoom) * Double(step) / Double(steps)
        }

        // Drain construction, first layout, transcript rasterization, and symbol
        // cache population before either arm owns a clock.
        resetToBaseline()
        for zoom in targets.prefix(4) {
            _ = canvas.worldPlane.applyCamera(
                viewportSize: canvas.bounds.size, worldOrigin: .zero, zoom: zoom
            )
            pump()
        }
        resetToBaseline()

        var steppedFrames: [Double] = []
        var heldFrames: [Double] = []
        var bakeFrames: [Double] = []
        var steppedWrites = 0
        var heldFrameWrites = 0
        var bakeWrites = 0
        var steppedTileLayouts = 0
        var steppedTranscriptLayouts = 0
        var heldTileLayouts = 0
        var heldTranscriptLayouts = 0

        enum Arm { case stepped, held }
        // ABBA: the second observation of each arm sees the opposite order, so
        // first-run caches and short thermal drift do not belong to one side.
        for arm in [Arm.stepped, .held, .held, .stepped] {
            resetToBaseline()
            let tileLayoutsBefore = canvas.qaTotalTileLayoutPassCount
            let transcriptLayoutsBefore = canvas.qaTotalTranscriptLayoutPassCount
            switch arm {
            case .stepped:
                for zoom in targets {
                    steppedFrames.append(milliseconds {
                        _ = canvas.worldPlane.applyCamera(
                            viewportSize: canvas.bounds.size, worldOrigin: .zero, zoom: zoom
                        )
                        pump()
                    })
                }
                steppedWrites += canvas.worldPlane.qaBoundsSizeWriteCount
                steppedTileLayouts += canvas.qaTotalTileLayoutPassCount - tileLayoutsBefore
                steppedTranscriptLayouts += canvas.qaTotalTranscriptLayoutPassCount - transcriptLayoutsBefore
            case .held:
                for _ in targets {
                    heldFrames.append(milliseconds { pump() })
                }
                heldFrameWrites += canvas.worldPlane.qaBoundsSizeWriteCount
                heldTileLayouts += canvas.qaTotalTileLayoutPassCount - tileLayoutsBefore
                heldTranscriptLayouts += canvas.qaTotalTranscriptLayoutPassCount - transcriptLayoutsBefore

                canvas.worldPlane.qaResetBoundsSizeWriteCount()
                bakeFrames.append(milliseconds {
                    _ = canvas.worldPlane.applyCamera(
                        viewportSize: canvas.bounds.size, worldOrigin: .zero, zoom: finalZoom
                    )
                    pump()
                })
                bakeWrites += canvas.worldPlane.qaBoundsSizeWriteCount
            }
        }

        resetToBaseline()
        let restoredMismatches = canvas.qaTileScreenFrameMismatchCount
        let steppedTotal = steppedFrames.reduce(0, +)
        let heldTicksTotal = heldFrames.reduce(0, +)
        let bakeTotal = bakeFrames.reduce(0, +)
        let heldGestureTotal = heldTicksTotal + bakeTotal
        let gestureCostRatio = steppedTotal > 0 ? heldGestureTotal / steppedTotal : 1
        let recoverablePercent = max(0, (1 - gestureCostRatio) * 100)
        let cascadeOnlyDenominator = steppedTotal - heldTicksTotal
        let cascadeOnlyRecoverablePercent = cascadeOnlyDenominator > 0
            ? max(0, min(100, (steppedTotal - heldGestureTotal) / cascadeOnlyDenominator * 100))
            : 0
        let steppedMedian = percentile(steppedFrames, 0.5)
        let steppedP95 = percentile(steppedFrames, 0.95)
        let heldMedian = percentile(heldFrames, 0.5)
        let heldP95 = percentile(heldFrames, 0.95)
        let bakeMedian = percentile(bakeFrames, 0.5)
        let steppedLateShare = Double(steppedFrames.filter { $0 > frameBudgetMs }.count)
            / Double(max(steppedFrames.count, 1)) * 100
        let heldLateShare = Double(heldFrames.filter { $0 > frameBudgetMs }.count)
            / Double(max(heldFrames.count, 1)) * 100

        var measurements: [PerfMeasurement] = []
        measurements.append(PerfBudget(
            metric: "geometry-hold.managedAgentTiles", limit: .exactly(Double(tileCount)), unit: .count,
            rationale: "the probe must carry the profiled shape: ten real managed-agent subtrees, not cheap descriptor tiles"
        ).evaluate(Double(canvas.qaTotalInstalledTileCount)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.steppedBoundsSizeWrites", limit: .exactly(Double(steps * 2)), unit: .count,
            rationale: "the A arm must trigger one real world-plane bounds-size write per target in both observations"
        ).evaluate(Double(steppedWrites)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.heldFrameBoundsSizeWrites", limit: .exactly(0), unit: .count,
            rationale: "the B arm's presentation ticks are the held-geometry control and must not smuggle in a backing cascade"
        ).evaluate(Double(heldFrameWrites)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.bakeBoundsSizeWrites", limit: .exactly(2), unit: .count,
            rationale: "each held observation must still pay exactly one final geometry bake; omitting it exaggerates recoverability"
        ).evaluate(Double(bakeWrites)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.steppedTranscriptLayouts", limit: .atLeast(1), unit: .count,
            rationale: "teeth: the stepped backing cascade must reach the real transcript subtree, or this is another layout-blind harness"
        ).evaluate(Double(steppedTranscriptLayouts)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.heldFrameTileLayouts", limit: .exactly(0), unit: .count,
            rationale: "a held, already-settled display tick should not re-lay any tile; work here would be a second mechanism contaminating the control"
        ).evaluate(Double(heldTileLayouts)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.heldFrameTranscriptLayouts", limit: .exactly(0), unit: .count,
            rationale: "the held control must leave the heaviest body settled between the one final bake"
        ).evaluate(Double(heldTranscriptLayouts)))
        measurements.append(PerfBudget(
            metric: "geometry-hold.heldP95Duration", limit: .atMost(frameBudgetMs), unit: .milliseconds,
            rationale: "the held frame floor itself must fit a 120 Hz frame before a presentation mechanism can plausibly use it"
        ).evaluate(heldP95))
        measurements.append(PerfBudget(
            metric: "geometry-hold.heldGestureCostRatio", limit: .atMost(0.1), unit: .count,
            rationale: "including the final bake, the isolated geometry arm must stay below 10% of stepped cost; two establishing ABBA runs measured 1.5%"
        ).evaluate(gestureCostRatio))
        measurements.append(PerfBudget(
            metric: "geometry-hold.restoredScreenFrameMismatches", limit: .exactly(0), unit: .count,
            rationale: "after the causal probe restores baseline geometry, the production camera oracle must agree again"
        ).evaluate(Double(restoredMismatches)))

        let detail = "ABBA, \(steps) ticks/arm over \(tileCount) real agent tiles x \(turnsPerAgent) turns; "
            + String(format: "stepped p50 %.2f / p95 %.2f ms (%.0f%% late), ", steppedMedian, steppedP95, steppedLateShare)
            + String(format: "held p50 %.2f / p95 %.2f ms (%.0f%% late), ", heldMedian, heldP95, heldLateShare)
            + String(format: "one-bake p50 %.2f ms; gross recoverable %.1f%%, cascade-only %.1f%%; ",
                     bakeMedian, recoverablePercent, cascadeOnlyRecoverablePercent)
            + "layouts stepped tile/transcript \(steppedTileLayouts)/\(steppedTranscriptLayouts), "
            + "held ticks \(heldTileLayouts)/\(heldTranscriptLayouts)"
        return PerfScenarioResult(name: "canvas.geometry-hold-probe", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: shallow proxy scene versus bounds stepping

    /// Can an Array-owned, image-only layer scene keep active zoom work bounded
    /// while a real native agent tree remains installed behind it?
    ///
    /// This is deliberately not production integration. The proxy uses one
    /// shared synthetic tile-shell image, one layer per fixture tile, and one
    /// root affine per desired camera tick. It performs no capture, admission,
    /// cache generation, or native view conversion on the frame path. The same
    /// fixture first runs the current bounds-stepping control, then holds native
    /// geometry for the proxy arm and pays exactly one final native bake.
    static func canvasProxySceneProbe() throws -> PerfScenarioResult {
        let environment = ProcessInfo.processInfo.environment
        let requestedCounts = environment["PERF_PROXY_SCENE_TILE_COUNTS"]
            .map { raw in
                raw.split(separator: ",").compactMap { token in
                    Int(token.trimmingCharacters(in: .whitespaces))
                }
            } ?? [5, 10, 25, 50]
        let turnsPerAgent = Int(environment["PERF_PROXY_SCENE_TURNS"] ?? "") ?? 6
        let steps = Int(environment["PERF_PROXY_SCENE_STEPS"] ?? "") ?? 60
        guard !requestedCounts.isEmpty,
              requestedCounts.allSatisfy({ $0 > 0 }),
              turnsPerAgent > 0,
              steps > 1 else {
            throw Failure(message: "proxy-scene counts/turns must be positive and steps must exceed one")
        }

        let viewportSize = CGSize(width: 1_600, height: 1_000)
        let baseline = CanvasViewport(x: 0, y: 0, zoom: 1)
        let finalZoom = 0.45

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
            return sorted[min(max(index, 0), sorted.count - 1)]
        }

        func milliseconds(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }

        func makeShellImage() throws -> CGImage {
            let width = 420
            let height = 300
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw Failure(message: "proxy-scene could not allocate its synthetic shell bitmap")
            }
            context.setFillColor(SurfaceToken.tileBody.color.cgColor(for: .dark))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(SurfaceToken.tileChrome.color.cgColor(for: .dark))
            context.fill(CGRect(x: 0, y: height - 46, width: width, height: 46))
            context.setFillColor(AccentToken.accentWorking.color.cgColor(for: .dark))
            context.fill(CGRect(x: 16, y: height - 29, width: 94, height: 7))
            context.setFillColor(TextToken.textSecondary.color.cgColor(for: .dark))
            for row in 0..<7 {
                context.fill(CGRect(x: 18, y: 26 + row * 29, width: 300 + (row % 3) * 34, height: 8))
            }
            context.setStrokeColor(AgentLineRole.decorativeHairline.color.cgColor(for: .dark))
            context.setLineWidth(2)
            context.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
            guard let image = context.makeImage() else {
                throw Failure(message: "proxy-scene could not finish its synthetic shell bitmap")
            }
            return image
        }

        struct Row {
            let count: Int
            let steppedP50: Double
            let steppedP95: Double
            let proxyP50: Double
            let proxyP95: Double
            let bakeMs: Double
            let steppedWrites: Int
            let steppedTranscriptLayouts: Int
            let proxyWrites: Int
            let proxyTileLayouts: Int
            let proxyTranscriptLayouts: Int
            let rootMutations: Int
            let bakeWrites: Int
            let anchorError: CGFloat
            let mappingError: CGFloat
            let visualTravel: CGFloat
            let finalMismatches: Int
            let proxySubviewCount: Int
            let proxyImageLayerCount: Int
        }

        let shellImage = try makeShellImage()
        var rows: [Row] = []
        var measurements: [PerfMeasurement] = []

        for tileCount in requestedCounts {
            let canvas = CanvasNSView(
                canvasState: CanvasState(viewport: baseline, tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
            )
            canvas.frame = CGRect(origin: .zero, size: viewportSize)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }

            let zoneId = UUID()
            let rowCount = Int(ceil(Double(tileCount) / 5.0))
            let placement = ZonePlacement(
                zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 2_500, height: Double(max(rowCount, 1)) * 360 + 120),
                color: "blue", collapsed: false, hydrationPolicy: .automatic
            )
            var tiles: [Tile] = []
            for index in 0..<tileCount {
                tiles.append(Tile(
                    id: UUID(), kind: .managedAgent, title: "proxy-scene-\(tileCount)-\(index)",
                    frame: TileFrame(x: Double(index % 5) * 480 + 40,
                                     y: Double(index / 5) * 360 + 60,
                                     width: 420, height: 300),
                    zPosition: .fromLegacyRank(index + 1), zoneId: zoneId,
                    runtimeRef: nil, metadata: TileMetadata()
                ))
            }
            let zoneLayer = CanvasNSView.ZoneLayer(
                placement: placement,
                renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Proxy scene probe"),
                tiles: tiles
            )
            for (index, tile) in tiles.enumerated() {
                let view = ManagedAgentTileNSView(tile: tile, threadId: "proxy-scene-\(tileCount)-\(index)")
                view.renderRehydratedPreviousSession(
                    transcriptFixture(threadId: "proxy-scene-\(tileCount)-\(index)", turns: turnsPerAgent)
                )
                zoneLayer.tileViews[tile.id] = view
            }
            canvas.setZones([zoneLayer])

            func pump() {
                canvas.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
            }

            func applyNative(_ viewport: CanvasViewport) {
                _ = canvas.worldPlane.applyCamera(
                    viewportSize: viewportSize,
                    worldOrigin: CGPoint(x: viewport.x, y: viewport.y),
                    zoom: viewport.zoom
                )
            }

            // Alternate the anchor across the viewport. Each desired viewport
            // preserves the baked world point under that tick's anchor, which
            // exercises both scale and translation rather than a center-only
            // scale that could accidentally look correct.
            let targets: [(viewport: CanvasViewport, anchor: CGPoint)] = (1...steps).map { step in
                let progress = Double(step) / Double(steps)
                let zoom = baseline.zoom + (finalZoom - baseline.zoom) * progress
                let anchor = step.isMultiple(of: 2)
                    ? CGPoint(x: 800, y: 500)
                    : CGPoint(x: 220, y: 170)
                let worldAtAnchor = CGPoint(
                    x: baseline.x + anchor.x / baseline.zoom,
                    y: baseline.y + anchor.y / baseline.zoom
                )
                return (
                    CanvasViewport(
                        x: worldAtAnchor.x - anchor.x / zoom,
                        y: worldAtAnchor.y - anchor.y / zoom,
                        zoom: zoom
                    ),
                    anchor
                )
            }

            // Drain fixture construction and first rasterization, then warm the
            // exact stepped geometry path before its clock starts.
            applyNative(baseline)
            pump()
            for target in targets.prefix(3) {
                applyNative(target.viewport)
                pump()
            }
            applyNative(baseline)
            pump()
            canvas.worldPlane.qaResetBoundsSizeWriteCount()

            let steppedTranscriptBefore = canvas.qaTotalTranscriptLayoutPassCount
            var steppedFrames: [Double] = []
            for target in targets {
                steppedFrames.append(milliseconds {
                    applyNative(target.viewport)
                    pump()
                })
            }
            let steppedWrites = canvas.worldPlane.qaBoundsSizeWriteCount
            let steppedTranscriptLayouts = canvas.qaTotalTranscriptLayoutPassCount - steppedTranscriptBefore

            // Settle native geometry back to B before admitting the proxy. This
            // reset is outside all proxy counters and clocks.
            applyNative(baseline)
            pump()

            let hostLayer = CALayer()
            hostLayer.frame = CGRect(origin: .zero, size: viewportSize)
            hostLayer.masksToBounds = true
            hostLayer.isGeometryFlipped = true
            let proxyHost = NSView(frame: CGRect(origin: .zero, size: viewportSize))
            proxyHost.layer = hostLayer
            proxyHost.wantsLayer = true

            let rootLayer = CALayer()
            rootLayer.bounds = CGRect(origin: .zero, size: viewportSize)
            rootLayer.anchorPoint = .zero
            rootLayer.position = .zero
            rootLayer.isGeometryFlipped = true
            hostLayer.addSublayer(rootLayer)
            for tile in tiles {
                let imageLayer = CALayer()
                imageLayer.frame = CGRect(x: tile.frame.x, y: tile.frame.y,
                                          width: tile.frame.width, height: tile.frame.height)
                imageLayer.contents = shellImage
                imageLayer.contentsGravity = .resize
                imageLayer.contentsScale = 1
                rootLayer.addSublayer(imageLayer)
            }
            canvas.addSubview(proxyHost, positioned: .above, relativeTo: nil)
            pump()

            canvas.worldPlane.qaResetBoundsSizeWriteCount()
            let proxyTileLayoutsBefore = canvas.qaTotalTileLayoutPassCount
            let proxyTranscriptLayoutsBefore = canvas.qaTotalTranscriptLayoutPassCount
            var proxyFrames: [Double] = []
            var rootMutations = 0
            var worstAnchorError: CGFloat = 0
            var worstMappingError: CGFloat = 0
            var firstPresentedPoint: CGPoint?
            var lastPresentedPoint: CGPoint?
            let witnessWorldPoint = CGPoint(x: tiles[0].frame.x + 37, y: tiles[0].frame.y + 29)

            for target in targets {
                let q = target.viewport.zoom / baseline.zoom
                let translation = CGPoint(
                    x: (baseline.x - target.viewport.x) * target.viewport.zoom,
                    y: (baseline.y - target.viewport.y) * target.viewport.zoom
                )
                let affine = CGAffineTransform(a: q, b: 0, c: 0, d: q,
                                               tx: translation.x, ty: translation.y)
                proxyFrames.append(milliseconds {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    rootLayer.setAffineTransform(affine)
                    rootMutations += 1
                    CATransaction.commit()
                    pump()
                })

                let bakedWorldAtAnchor = CGPoint(
                    x: baseline.x + target.anchor.x / baseline.zoom,
                    y: baseline.y + target.anchor.y / baseline.zoom
                )
                // Read back the transform installed on the scene root rather
                // than reusing the harness value. `CALayer.convert` expresses a
                // geometry-flipped layer's local point in Core Animation's
                // unflipped coordinate convention; the model affine itself is
                // the visual world-to-screen mapping used by this scene.
                let installedAffine = rootLayer.affineTransform()
                let presentedAnchor = bakedWorldAtAnchor.applying(installedAffine)
                worstAnchorError = max(
                    worstAnchorError,
                    hypot(presentedAnchor.x - target.anchor.x, presentedAnchor.y - target.anchor.y)
                )
                let presentedWitness = witnessWorldPoint.applying(installedAffine)
                let expectedWitness = CGPoint(
                    x: (witnessWorldPoint.x - target.viewport.x) * target.viewport.zoom,
                    y: (witnessWorldPoint.y - target.viewport.y) * target.viewport.zoom
                )
                worstMappingError = max(
                    worstMappingError,
                    hypot(presentedWitness.x - expectedWitness.x, presentedWitness.y - expectedWitness.y)
                )
                if firstPresentedPoint == nil { firstPresentedPoint = presentedWitness }
                lastPresentedPoint = presentedWitness
            }

            let proxyWrites = canvas.worldPlane.qaBoundsSizeWriteCount
            let proxyTileLayouts = canvas.qaTotalTileLayoutPassCount - proxyTileLayoutsBefore
            let proxyTranscriptLayouts = canvas.qaTotalTranscriptLayoutPassCount - proxyTranscriptLayoutsBefore
            let visualTravel: CGFloat
            if let firstPresentedPoint, let lastPresentedPoint {
                visualTravel = hypot(lastPresentedPoint.x - firstPresentedPoint.x,
                                     lastPresentedPoint.y - firstPresentedPoint.y)
            } else {
                visualTravel = 0
            }

            // Keep the proxy installed and visible through the real native
            // display/CA flush. Removal happens only after the one measured bake.
            canvas.worldPlane.qaResetBoundsSizeWriteCount()
            let bakeMs = milliseconds {
                // Use the production camera funnel for the final bake so the
                // semantic viewport and the retained native plane become the
                // same truth before the proxy disappears.
                canvas.setViewport(targets[targets.count - 1].viewport)
                pump()
            }
            let bakeWrites = canvas.worldPlane.qaBoundsSizeWriteCount
            let proxyWasPresentThroughBake = proxyHost.superview === canvas
            proxyHost.removeFromSuperview()

            let finalMismatches = canvas.qaTileScreenFrameMismatchCount
            let row = Row(
                count: tileCount,
                steppedP50: percentile(steppedFrames, 0.5),
                steppedP95: percentile(steppedFrames, 0.95),
                proxyP50: percentile(proxyFrames, 0.5),
                proxyP95: percentile(proxyFrames, 0.95),
                bakeMs: bakeMs,
                steppedWrites: steppedWrites,
                steppedTranscriptLayouts: steppedTranscriptLayouts,
                proxyWrites: proxyWrites,
                proxyTileLayouts: proxyTileLayouts,
                proxyTranscriptLayouts: proxyTranscriptLayouts,
                rootMutations: rootMutations,
                bakeWrites: bakeWrites,
                anchorError: worstAnchorError,
                mappingError: worstMappingError,
                visualTravel: visualTravel,
                finalMismatches: finalMismatches,
                proxySubviewCount: proxyHost.subviews.count,
                proxyImageLayerCount: rootLayer.sublayers?.count ?? 0
            )
            rows.append(row)

            let prefix = "proxy-scene.\(tileCount)"
            measurements.append(PerfBudget(
                metric: "\(prefix).managedAgentTiles", limit: .exactly(Double(tileCount)), unit: .count,
                rationale: "each scene-size cell must retain the requested number of real managed-agent transcript trees behind the proxy"
            ).evaluate(Double(canvas.qaTotalInstalledTileCount)))
            measurements.append(PerfBudget(
                metric: "\(prefix).steppedBoundsSizeWrites", limit: .exactly(Double(steps)), unit: .count,
                rationale: "the control must exercise one real world-plane bounds-size write per desired zoom tick"
            ).evaluate(Double(steppedWrites)))
            measurements.append(PerfBudget(
                metric: "\(prefix).steppedTranscriptLayouts", limit: .atLeast(1), unit: .count,
                rationale: "the stepped control must reproduce the native transcript cascade or the comparison has no teeth"
            ).evaluate(Double(steppedTranscriptLayouts)))
            measurements.append(PerfBudget(
                metric: "\(prefix).rootMutations", limit: .exactly(Double(steps)), unit: .count,
                rationale: "the shallow presenter is O(1) in camera mutations: exactly one owned root affine per desired camera commit"
            ).evaluate(Double(rootMutations)))
            measurements.append(PerfBudget(
                metric: "\(prefix).proxyBoundsSizeWrites", limit: .exactly(0), unit: .count,
                rationale: "active proxy motion must leave native world-plane geometry held"
            ).evaluate(Double(proxyWrites)))
            measurements.append(PerfBudget(
                metric: "\(prefix).proxyTileLayouts", limit: .exactly(0), unit: .count,
                rationale: "an image-only root affine must not lay out installed native tile trees"
            ).evaluate(Double(proxyTileLayouts)))
            measurements.append(PerfBudget(
                metric: "\(prefix).proxyTranscriptLayouts", limit: .exactly(0), unit: .count,
                rationale: "the heaviest native subtree must remain untouched throughout active proxy motion"
            ).evaluate(Double(proxyTranscriptLayouts)))
            measurements.append(PerfBudget(
                metric: "\(prefix).bakeBoundsSizeWrites", limit: .exactly(1), unit: .count,
                rationale: "a normal held gesture pays one and only one final native geometry bake"
            ).evaluate(Double(bakeWrites)))
            measurements.append(PerfBudget(
                metric: "\(prefix).anchorError", limit: .atMost(0.5), unit: .count,
                rationale: "the root affine must preserve each changing gesture anchor to within one device pixel"
            ).evaluate(Double(worstAnchorError)))
            measurements.append(PerfBudget(
                metric: "\(prefix).worldMappingError", limit: .atMost(0.5), unit: .count,
                rationale: "an independent world point must land at the desired camera's screen coordinate, not merely keep the anchor fixed"
            ).evaluate(Double(worstMappingError)))
            measurements.append(PerfBudget(
                metric: "\(prefix).visualTravel", limit: .atLeast(1), unit: .count,
                rationale: "teeth: the synthetic tile scene must visibly move across the driven camera sequence"
            ).evaluate(Double(visualTravel)))
            measurements.append(PerfBudget(
                metric: "\(prefix).proxySubviews", limit: .exactly(0), unit: .count,
                rationale: "the layer-hosting proxy may contain only Array-owned layers/images, never AppKit subviews"
            ).evaluate(Double(proxyHost.subviews.count)))
            measurements.append(PerfBudget(
                metric: "\(prefix).imageLayers", limit: .exactly(Double(tileCount)), unit: .count,
                rationale: "the scene must actually present one synthetic tile shell for every real fixture tile"
            ).evaluate(Double(rootLayer.sublayers?.count ?? 0)))
            measurements.append(PerfBudget(
                metric: "\(prefix).proxyP95Duration", limit: .atMost(frameBudgetMs), unit: .milliseconds,
                rationale: "the isolated one-root affine and real display flush must fit a 120 Hz frame"
            ).evaluate(row.proxyP95))
            measurements.append(PerfBudget(
                metric: "\(prefix).proxyPresentThroughBake", limit: .exactly(1), unit: .count,
                rationale: "the presenter must survive through the native display/CA flush so the one-bake hitch can be visually covered"
            ).evaluate(proxyWasPresentThroughBake ? 1 : 0))
            measurements.append(PerfBudget(
                metric: "\(prefix).finalScreenFrameMismatches", limit: .exactly(0), unit: .count,
                rationale: "after the bake, the native camera oracle must exactly match the final desired viewport"
            ).evaluate(Double(finalMismatches)))
        }

        let detail = "\(steps) ticks, \(turnsPerAgent) turns/real agent, one shared synthetic shell image; "
            + rows.map { row in
                String(format: "%d tiles stepped %.2f/%.2f ms, proxy %.2f/%.2f ms, bake %.2f ms, writes %d/%d+%d, layouts %d/%d, root %d, anchor %.3f px",
                       row.count, row.steppedP50, row.steppedP95,
                       row.proxyP50, row.proxyP95, row.bakeMs,
                       row.steppedWrites, row.proxyWrites, row.bakeWrites,
                       row.proxyTileLayouts, row.proxyTranscriptLayouts,
                       row.rootMutations, row.anchorError)
            }.joined(separator: " | ")
        return PerfScenarioResult(name: "canvas.proxy-scene-probe", detail: detail,
                                  measurements: measurements)
    }

    // MARK: - Scenario: flat surface hosts versus deep native tiles

    /// **The Shape A witness.** `.plans/34` decided that a retained scene's
    /// surface hosts are `TileNSView`s at WORLD frames installed as ordinary
    /// children of `CanvasWorldPlaneView` — chrome untouched, only the BODY
    /// replaced. That keeps z-order, hit testing, the install path, chrome, focus
    /// registration and the camera oracle working unchanged, and it leaves the
    /// camera still writing `bounds.size`. So it trades the `O(1)` camera for a
    /// traversal over a FLAT tree, and the whole architecture rests on one
    /// unmeasured number: what does a camera step cost when the plane's children
    /// are flat layer hosts instead of deep native tiles?
    ///
    /// `canvas.magnify-slope` already brackets it from one side: 16 -> 128
    /// installed `DescriptorTileNSView`s (shallower than a real tile, deeper than
    /// a surface host) adds ~1.9-2.3 ms/step of pure AppKit traversal with every
    /// WORK counter flat at zero. Its published rationale also names the escape —
    /// "not reachable from our code without culling installed views, which the
    /// always-render-live constraint forbids" — and a retained scene is exactly
    /// what makes culling legal, because runtime residency stops implying view
    /// residency. An offscreen agent keeps streaming with no installed host.
    ///
    /// Hence three arms over ONE fixture, all of them moving the camera for real:
    ///
    /// - **native** — real `ManagedAgentTileNSView`, all installed. Does the
    ///   control reproduce the known cascade? If not, no other number is
    ///   admissible.
    /// - **unculled** — surface hosts, all installed. Isolates what replacing the
    ///   BODY buys at equal installed count.
    /// - **culled** — surface hosts, visible presentation set only. Isolates what
    ///   CULLING buys, and answers whether the slope against TOTAL tiles goes
    ///   flat.
    ///
    /// Four things this probe does that its predecessors did not, all from
    /// `.plans/31`'s red-team corrections and `.plans/34`'s findings:
    ///
    /// - **It measures the PRODUCTION camera step, not a bare bounds write.**
    ///   Every step is a real `CanvasCameraDriver` commit through the driver's
    ///   deterministic QA seams, so `isApplying` is true, cursor-rect housekeeping
    ///   defers exactly as it does in a gesture, and the visible-tile chrome
    ///   refresh — which Shape A deliberately KEEPS — is inside the measurement.
    ///   Zoom targets are hit by inverting the driver's own log-zoom gain, so the
    ///   trajectory and the anchor mathematics belong to production code and the
    ///   harness computes no geometry of its own.
    /// - **The surfaces are the real tiles' pixels.** Each agent body is baked
    ///   once through `cacheDisplay` before any clock starts — an exact-surface
    ///   scene rather than the synthetic shells that were rejected as a product
    ///   design — with one DISTINCT bake per host so Core Animation cannot
    ///   collapse the scene onto a single shared texture and understate it.
    /// - **Zone chrome is on and the gesture reaches the real overview (0.2).**
    ///   Translucency, rounded masks and low zoom are what CA and WindowServer
    ///   actually charge for, and every earlier probe omitted them while stopping
    ///   at 0.45.
    /// - **It settles the `contentsScale` trap instead of assuming it.** A
    ///   bounds-size write reaches descendants through
    ///   `viewDidChangeBackingProperties`; if that callback re-derives a surface at
    ///   the ancestor's new effective scale then every zoom step re-rasterises
    ///   every surface — a green geometry counter over a red gesture. The host owns
    ///   its layer, so it applies a BUCKETED policy and counts what a camera step
    ///   actually caused. `PERF_SURFACE_HOST_NAIVE_SCALE=1` swaps in the naive
    ///   policy that tracks the live effective scale: that is the permanent
    ///   negative witness proving the counter can fail.
    ///
    /// Not a production mechanism: no snapshot revisions, no cache generation, no
    /// dirty regions, no promotion, no interaction. It measures the camera under
    /// Shape A geometry and nothing else.
    static func canvasSurfaceHostSlope() throws -> PerfScenarioResult {
        let environment = ProcessInfo.processInfo.environment
        // The default sweep stops at 50 because every host needs its OWN baked
        // surface to keep the texture count honest, and a bake needs a real agent
        // tile: 50 is the top of the ladder `.plans/31` published, and
        // docs/internals/performance.md is explicit that a big fixture is a memory
        // event and not just a CPU one. 100/200 are available, deliberately opt-in.
        let requestedCounts = environment["PERF_SURFACE_HOST_TILE_COUNTS"]
            .map { raw in
                raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } ?? [5, 15, 25, 50]
        let turnsPerAgent = Int(environment["PERF_SURFACE_HOST_TURNS"] ?? "") ?? 6
        let steps = Int(environment["PERF_SURFACE_HOST_STEPS"] ?? "") ?? 60
        let visibleClusterCount = Int(environment["PERF_SURFACE_HOST_VISIBLE"] ?? "") ?? 5
        let usesNaiveScalePolicy = environment["PERF_SURFACE_HOST_NAIVE_SCALE"] == "1"
        guard !requestedCounts.isEmpty,
              requestedCounts.allSatisfy({ $0 >= visibleClusterCount }),
              requestedCounts == requestedCounts.sorted(),
              visibleClusterCount > 0,
              turnsPerAgent > 0,
              steps > 1 else {
            throw Failure(message: "surface-host counts must be ascending and >= the visible cluster, "
                          + "with positive turns and steps > 1")
        }

        let viewportSize = CGSize(width: 1_600, height: 1_000)
        let baselineZoom = 1.0
        let finalZoom = 0.2

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
            return sorted[min(max(index, 0), sorted.count - 1)]
        }

        func milliseconds(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }

        enum Arm: String, CaseIterable {
            case native
            case unculled
            case culled
            /// Surface hosts in the plane AND every real agent body still alive,
            /// parked in the window but OUTSIDE `CanvasWorldPlaneView`. This is the
            /// arm the first production slice is downstream of: an interim
            /// `cacheDisplay` producer needs the native body to keep laying out and
            /// streaming (I11), and the only way that is affordable is if a camera
            /// step cannot reach it. If a parked body re-lays out on camera steps,
            /// parking is not a producer strategy and the slice needs an off-main
            /// display list before it can ship at all.
            case parked
        }

        struct ArmSample {
            /// Every observed interval per stage, retained rather than reduced:
            /// doc 33 requires the raw values, and pooling both ABBA observations
            /// is only possible if neither is collapsed to a percentile first.
            var commit: [Double] = []
            var layout: [Double] = []
            var display: [Double] = []
            var flush: [Double] = []

            /// Work Array itself performed: the driver commit, the layout pass it
            /// caused, and the draw cycle. This is the number a renderer change can
            /// actually move.
            var arrayCPU: [Double] {
                zip(zip(commit, layout), display).map { $0.0 + $0.1 + $1 }
            }
            /// Everything, including the transaction flush. Named `step`, never
            /// "presented": a flush returning is not a frame on screen.
            var step: [Double] {
                zip(arrayCPU, flush).map(+)
            }

            static func quantile(_ values: [Double], _ fraction: Double) -> Double {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
                return sorted[min(max(index, 0), sorted.count - 1)]
            }
            var p50: Double { Self.quantile(step, 0.5) }
            var p95: Double { Self.quantile(step, 0.95) }
            var worst: Double { step.max() ?? 0 }
            var arrayP50: Double { Self.quantile(arrayCPU, 0.5) }
            var arrayP95: Double { Self.quantile(arrayCPU, 0.95) }
            var flushP50: Double { Self.quantile(flush, 0.5) }
            var flushP95: Double { Self.quantile(flush, 0.95) }
            func lateShare(_ budget: Double) -> Double {
                let values = step
                guard !values.isEmpty else { return 0 }
                return Double(values.filter { $0 > budget }.count) / Double(values.count) * 100
            }
            func arrayLateShare(_ budget: Double) -> Double {
                let values = arrayCPU
                guard !values.isEmpty else { return 0 }
                return Double(values.filter { $0 > budget }.count) / Double(values.count) * 100
            }

            var boundsSizeWrites = 0
            var driverCommits = 0
            var tileLayouts = 0
            var transcriptLayouts = 0
            var chromeRedraws = 0
            var installedHosts = 0
            var onScreen = 0
            var backingCallbacks = 0
            var rasterRequests = 0
            /// Transcript layout passes inside the park during the clocked schedule.
            /// The decisive number for the parked arm: zero means a camera step
            /// cannot reach a demoted tile's live body.
            var parkedTranscriptLayouts = 0
            var parkedBodies = 0
            var oracleMismatches = 0
        }

        struct Row {
            let count: Int
            var arms: [Arm: ArmSample] = [:]
            var orderControl: [Arm: ArmSample] = [:]
            /// [first-pass p50, second-pass p50] per arm — the order/drift control.
            var passMedians: [Arm: [Double]] = [:]
            var bakedPixels = 0
            var bakedMegabytes = 0.0
            var distinctSurfaces = 0
            var finalZoomReached = 0.0
            /// Liveness of the park, measured once per row after the ABBA passes:
            /// a parked body must be QUIET, not dead. Cards are the model side;
            /// the pixel delta is the side an interim `cacheDisplay` producer
            /// actually depends on.
            var parkedStreamingCards = 0
            var parkedStreamingPixelDelta = 0
            var parkedBakeColors = 0
        }

        var rows: [Row] = []

        for tileCount in requestedCounts {
            let canvas = CanvasNSView(
                canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: baselineZoom),
                                         tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
            )
            canvas.frame = CGRect(origin: .zero, size: viewportSize)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }

            // The visible cluster sits near the origin and stays on screen across
            // the whole 1.0 -> 0.2 sweep; filler is parked beyond the envelope at
            // zoom 0.2 (which covers ~8,000 x 5,000 world units), so "installed"
            // and "visible" are independent and the slope means something. This is
            // canvas.magnify-slope's methodology, on real content.
            let zoneId = UUID()
            let placement = ZonePlacement(
                zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 40_000, height: 30_000), color: "blue",
                collapsed: false, hydrationPolicy: .automatic
            )
            var tiles: [Tile] = []
            for index in 0..<tileCount {
                let frame: TileFrame
                if index < visibleClusterCount {
                    frame = TileFrame(x: Double(index % 3) * 480 + 40,
                                      y: Double(index / 3) * 360 + 60,
                                      width: 420, height: 300)
                } else {
                    let filler = index - visibleClusterCount
                    frame = TileFrame(x: 12_000 + Double(filler % 16) * 500,
                                      y: 9_000 + Double(filler / 16) * 400,
                                      width: 420, height: 300)
                }
                tiles.append(Tile(
                    id: UUID(), kind: .managedAgent, title: "surface-host-\(tileCount)-\(index)",
                    frame: frame, zPosition: .fromLegacyRank(index + 1), zoneId: zoneId,
                    runtimeRef: nil, metadata: TileMetadata()
                ))
            }
            let layer = CanvasNSView.ZoneLayer(
                placement: placement,
                renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Surface host slope"),
                tiles: tiles
            )

            // Retained for the whole sweep so the native arm can be reinstalled
            // without rebuilding — that is what makes the three arms PAIRED
            // observations of one fixture rather than three separate fixtures.
            var agentViews: [UUID: ManagedAgentTileNSView] = [:]
            for (index, tile) in tiles.enumerated() {
                let threadId = "surface-host-\(tileCount)-\(index)"
                let view = ManagedAgentTileNSView(tile: tile, threadId: threadId)
                view.renderRehydratedPreviousSession(
                    transcriptFixture(threadId: threadId, turns: turnsPerAgent)
                )
                // `_installLayer` (the setZones path) does not set this; only
                // `install(tileView:for:)` and `installProjectTile` do. Without it
                // `canvas` is nil, every chrome floor collapses to its unfloored
                // constant, and the visible-tile chrome refresh this probe claims
                // to include becomes a no-op — the first run reported 0 chrome
                // redraws across a 1.0 -> 0.2 gesture that should cross ~9 buckets.
                view.canvas = canvas
                agentViews[tile.id] = view
                layer.tileViews[tile.id] = view
            }
            canvas.setZones([layer])

            // Where the eventual production slice keeps a DEMOTED tile's real body:
            // in the window — so appearance, backing scale and the layout cycle stay
            // the real ones — but not under the world plane, so a camera step's
            // `bounds.size` write cannot cascade into it. Zero-sized, so AppKit
            // clips every parked body out of the draw without `isHidden`, which
            // would also stop the layout this arm exists to keep alive.
            let parkContainer = NSView(frame: .zero)
            parkContainer.identifier = NSUserInterfaceItemIdentifier("surfaceHost.park")
            canvas.addSubview(parkContainer)

            /// Transcript layout passes inside the park, which
            /// `canvas.qaTotalTranscriptLayoutPassCount` cannot see: that walks
            /// `tileViewsInVisualOrder`, i.e. the world plane, and the whole point of
            /// a parked body is that it is not there. Cumulative, so callers take
            /// deltas.
            func parkedTranscriptLayoutPasses() -> Int {
                func walk(_ view: NSView) -> Int {
                    var total = (view as? AgentTranscriptListView)?.qaLayoutPassCount ?? 0
                    for subview in view.subviews { total += walk(subview) }
                    return total
                }
                return parkContainer.subviews.reduce(0) { $0 + walk($1) }
            }

            func pump() {
                canvas.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                // The backing store commits here, not in `displayIfNeeded()` —
                // canvas.raster observed 144 invalidations and zero executed draws
                // without this flush, and timing without it would recreate that
                // blindness.
                CATransaction.flush()
            }

            // ---- Drive the REAL production camera path ----
            //
            // A bare `worldPlane.applyCamera` is not a camera step: Shape A keeps
            // the visible-tile chrome refresh, and a driver commit also defers
            // cursor-rect housekeeping that an external `setViewport` would pay.
            // Driving the actual driver with an injected clock gets both right and
            // leaves every geometry decision — the log-zoom curve, the anchor
            // mathematics, the float tolerance — in production code.
            final class Clock {
                var now: TimeInterval = 1_000
            }
            let clock = Clock()
            canvas.cameraDriver.nowProvider = { [clock] in clock.now }
            let zoomGain = canvas.cameraDriver.tuning.scrollZoomGain
            let commitGap = canvas.cameraDriver.tuning.minCommitInterval + 0.001

            /// One driver commit that lands on `target`, by inverting the driver's
            /// own gain. Returns whether the driver actually committed.
            @discardableResult
            func cameraStep(toZoom target: Double, anchor: CGPoint) -> Bool {
                let current = canvas.viewport.zoom
                guard current > 0, target > 0, zoomGain > 0 else { return false }
                let deltaY = log(target / current) / zoomGain
                guard deltaY.isFinite, deltaY != 0 else { return false }
                clock.now += commitGap
                canvas.cameraDriver.noteScrollZoom(deltaY: deltaY, location: anchor)
                return true
            }

            func resetCamera() {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: baselineZoom))
                pump()
            }

            /// Alternating anchor, so each step exercises translation as well as
            /// scale rather than a centre-only zoom that could look correct by
            /// accident.
            let schedule: [(zoom: Double, anchor: CGPoint)] = (1...steps).map { step in
                let progress = Double(step) / Double(steps)
                return (
                    baselineZoom + (finalZoom - baselineZoom) * progress,
                    step.isMultiple(of: 2) ? CGPoint(x: 800, y: 500) : CGPoint(x: 220, y: 170)
                )
            }

            // ---- Bake one distinct real surface per host, before any clock ----
            resetCamera()
            var bakedBodies: [UUID: CGImage] = [:]
            var bakedPixels = 0
            for tile in tiles {
                guard let agentView = agentViews[tile.id], let body = agentView.contentView else {
                    throw Failure(message: "surface-host bake found no agent body for a fixture tile")
                }
                let bodyBounds = body.bounds
                guard bodyBounds.width > 1, bodyBounds.height > 1,
                      let rep = body.bitmapImageRepForCachingDisplay(in: bodyBounds) else {
                    throw Failure(message: "surface-host could not allocate a bake for a real agent body")
                }
                body.cacheDisplay(in: bodyBounds, to: rep)
                guard let image = rep.cgImage else {
                    throw Failure(message: "surface-host bake produced no image for a real agent body")
                }
                // A blank bake would make every surface arm cheap for the wrong
                // reason. `VisualSnapshot.isBlank` is only a smoke floor, and a
                // smoke floor is exactly what is wanted here: prove pixels exist.
                if VisualSnapshot.metrics(of: rep).isBlank {
                    throw Failure(message: "surface-host baked a blank agent body — "
                                  + "the surface arms would be cheap for the wrong reason")
                }
                bakedBodies[tile.id] = image
                bakedPixels += image.width * image.height
            }

            var row = Row(count: tileCount)
            row.bakedPixels = bakedPixels
            row.bakedMegabytes = Double(bakedPixels * 4) / 1_048_576
            row.distinctSurfaces = bakedBodies.count

            var surfaceViews: [UUID: TileSurfaceProbeView] = [:]
            for tile in tiles {
                guard let image = bakedBodies[tile.id] else { continue }
                let view = TileSurfaceProbeView(tile: tile, surface: image)
                view.usesNaiveScalePolicy = usesNaiveScalePolicy
                // Same reason as the agent views: a surface host must pay the
                // chrome refresh Shape A keeps, or the arms are not comparable.
                view.canvas = canvas
                surfaceViews[tile.id] = view
            }

            // Whatever the previous arm put in the world plane, tracked
            // explicitly. `setZones` removes the views in `layer.tileViews` as it
            // finds them, so mutating that dictionary FIRST makes it remove the
            // incoming set and orphan the outgoing one — which leaves the previous
            // arm's tiles installed, in the view tree, and being laid out. The
            // first run of this probe measured three arms that were all paying the
            // native agent cost and reported them as identical; the
            // `surfaceArmTranscriptLayouts == 0` tooth is what caught it.
            var installedForArm: [TileNSView] = []

            func installArm(_ arm: Arm) throws {
                for view in installedForArm { view.removeFromSuperview() }
                installedForArm = []
                var installed: [UUID: TileNSView] = [:]
                switch arm {
                case .native:
                    for (id, view) in agentViews { installed[id] = view }
                case .unculled:
                    for (id, view) in surfaceViews { installed[id] = view }
                case .culled:
                    // The presentation set a scene would freeze for the gesture
                    // (`.plans/34` D-G), computed once BEFORE the clock: installing
                    // per frame would itself be the cost under measurement.
                    for tile in tiles.prefix(visibleClusterCount) {
                        if let view = surfaceViews[tile.id] { installed[tile.id] = view }
                    }
                case .parked:
                    for (id, view) in surfaceViews { installed[id] = view }
                }
                layer.tileViews = installed
                installedForArm = Array(installed.values)
                // Unpark unconditionally: `setZones` only knows about the views in
                // `layer.tileViews`, so a body left in the park would stay in the
                // window's layout tree for an arm that never asked for it — the same
                // shape of mistake as the `layer.tileViews` aliasing trap above.
                for view in agentViews.values where view.superview === parkContainer {
                    view.removeFromSuperview()
                }
                if arm == .parked {
                    // Stacked at world size at scale 1, so each body lays out at the
                    // width it would really have. Frames are set BEFORE the clock;
                    // nothing here moves during the gesture.
                    for (index, tile) in tiles.enumerated() {
                        guard let view = agentViews[tile.id] else { continue }
                        view.frame = CGRect(x: 0, y: Double(index) * (tile.frame.height + 8),
                                            width: tile.frame.width, height: tile.frame.height)
                        parkContainer.addSubview(view)
                    }
                }
                canvas.setZones([layer])
                pump()
                // The arm's composition is a PRECONDITION for its numbers, not
                // something to discover in the report afterwards. This sums only
                // over currently-installed tile views, so a nonzero value in a
                // surface arm means a native body is still in the world plane.
                if arm != .native, canvas.qaTotalTranscriptLayoutPassCount != 0 {
                    throw Failure(message: "surface-host \(arm.rawValue) arm still has a native "
                                  + "transcript installed; its timings would be the native arm's")
                }
            }

            func measure(_ arm: Arm) throws -> ArmSample {
                try installArm(arm)
                resetCamera()
                // Drain first rasterisation and symbol-cache population before the
                // clock: a cold first step belongs to construction, not the camera.
                for entry in schedule.prefix(3) {
                    cameraStep(toZoom: entry.zoom, anchor: entry.anchor)
                    pump()
                }
                resetCamera()

                canvas.worldPlane.qaResetBoundsSizeWriteCount()
                canvas.qaResetCameraLayoutStats()
                for view in surfaceViews.values { view.qaResetSurfaceCounters() }
                let tileLayoutsBefore = canvas.qaTotalTileLayoutPassCount
                let transcriptLayoutsBefore = canvas.qaTotalTranscriptLayoutPassCount
                let chromeBefore = canvas.qaTotalTileChromeRedrawCount
                let viewportApplyBefore = canvas.qaViewportApplyCount
                let onScreen = canvas.qaTilesIntersectingViewport
                let parkedTranscriptBefore = parkedTranscriptLayoutPasses()

                // Doc 33's "one honest timeline": Array-owned work and the Core
                // Animation transaction flush are DIFFERENT stages and must never
                // be one number. `CATransaction.flush()` can block on the render
                // server, so folding it into the step time reports compositor
                // synchronisation as if it were Array CPU — which is exactly the
                // mistake that would make a fast path look over budget. The first
                // decomposed run is what settles which stage the tail lives in.
                var commitMs: [Double] = []
                var layoutMs: [Double] = []
                var displayMs: [Double] = []
                var flushMs: [Double] = []
                for entry in schedule {
                    commitMs.append(milliseconds { cameraStep(toZoom: entry.zoom, anchor: entry.anchor) })
                    layoutMs.append(milliseconds { canvas.layoutSubtreeIfNeeded() })
                    displayMs.append(milliseconds { window.displayIfNeeded() })
                    flushMs.append(milliseconds { CATransaction.flush() })
                }

                var sample = ArmSample()
                sample.commit = commitMs
                sample.layout = layoutMs
                sample.display = displayMs
                sample.flush = flushMs
                sample.boundsSizeWrites = canvas.worldPlane.qaBoundsSizeWriteCount
                sample.driverCommits = canvas.qaViewportApplyCount - viewportApplyBefore
                sample.tileLayouts = canvas.qaTotalTileLayoutPassCount - tileLayoutsBefore
                sample.transcriptLayouts = canvas.qaTotalTranscriptLayoutPassCount - transcriptLayoutsBefore
                sample.chromeRedraws = canvas.qaTotalTileChromeRedrawCount - chromeBefore
                sample.installedHosts = canvas.qaTotalInstalledTileCount
                sample.onScreen = onScreen
                // Captured here, before the unclocked oracle pass drives the same
                // schedule again — otherwise the oracle's own steps would double it.
                sample.parkedTranscriptLayouts = parkedTranscriptLayoutPasses() - parkedTranscriptBefore
                sample.parkedBodies = parkContainer.subviews.count
                for view in surfaceViews.values where view.superview != nil {
                    sample.backingCallbacks += view.qaBackingCallbackCount
                    sample.rasterRequests += view.qaRasterRequestCount
                }

                // The geometry oracle runs on its own unclocked pass over the same
                // schedule, so a thorough per-step check never inflates the timing
                // it is protecting. Zero here is what makes the durations above
                // claims about a CORRECT presentation rather than a stalled one.
                resetCamera()
                var mismatches = 0
                for entry in schedule {
                    cameraStep(toZoom: entry.zoom, anchor: entry.anchor)
                    pump()
                    mismatches += canvas.qaTileScreenFrameMismatchCount
                }
                sample.oracleMismatches = mismatches
                return sample
            }

            // ABBA across three arms: the second observation of each sees the
            // reversed order, so first-run caches and short thermal drift cannot
            // belong to one side.
            //
            // Both observations are POOLED into one sample per arm rather than
            // reporting the later one, which is what `canvasGeometryHoldProbe`
            // already does. The first version of this probe reported only the
            // second pass and printed a 4x disagreement between passes at 15 tiles
            // (1.48 vs 6.15 ms p50) — a number that would have been published as
            // if it were the arm's cost. The per-pass medians are kept as an
            // explicit DRIFT metric instead of being averaged away.
            for arm in Arm.allCases {
                row.orderControl[arm] = try measure(arm)
            }
            for arm in Arm.allCases.reversed() {
                var pooled = try measure(arm)
                if let first = row.orderControl[arm] {
                    row.passMedians[arm] = [first.arrayP50, pooled.arrayP50]
                    pooled.commit.append(contentsOf: first.commit)
                    pooled.layout.append(contentsOf: first.layout)
                    pooled.display.append(contentsOf: first.display)
                    pooled.flush.append(contentsOf: first.flush)
                }
                row.arms[arm] = pooled
            }
            row.finalZoomReached = canvas.viewport.zoom

            // ---- I11 liveness: a parked body must be QUIET, not DEAD ----
            //
            // `parkedTranscriptLayouts == 0` is also what a body that had stopped
            // being a view at all would report, and that reading would make the
            // parked arm meaningless. So ingest one real streaming event into a
            // parked agent and require the transcript to respond. This is the exact
            // property an interim `cacheDisplay` producer depends on: the body keeps
            // receiving its stream and re-laying out while the camera cannot see it.
            try installArm(.parked)
            pump()
            guard let livenessView = agentViews[tiles[0].id] else {
                throw Failure(message: "surface-host has no parked body to test for liveness")
            }
            let livenessThread = "surface-host-\(tileCount)-0"
            let livenessTurn = "\(livenessThread)-liveness"
            /// A bake of a body while it is parked — the interim producer's exact
            /// operation. If this cannot produce pixels from a clipped-out view, the
            /// `cacheDisplay` producer is not available and the slice needs the
            /// off-main display list (I2) before it can ship at all.
            func bakeParked(_ view: ManagedAgentTileNSView) throws -> NSBitmapImageRep {
                guard let body = view.contentView, body.bounds.width > 1, body.bounds.height > 1,
                      let rep = body.bitmapImageRepForCachingDisplay(in: body.bounds) else {
                    throw Failure(message: "surface-host could not allocate a bake of a parked body")
                }
                body.cacheDisplay(in: body.bounds, to: rep)
                return rep
            }
            func differingBytes(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep) -> Int {
                guard let a = before.bitmapData, let b = after.bitmapData,
                      before.bytesPerPlane == after.bytesPerPlane else { return 0 }
                var differing = 0
                for offset in 0..<before.bytesPerPlane where a[offset] != b[offset] { differing += 1 }
                return differing
            }

            let livenessCardsBefore = livenessView.transcriptCardCount
            let livenessBakeBefore = try bakeParked(livenessView)
            livenessView.ingest(.turnStarted(threadId: livenessThread, turnId: livenessTurn))
            livenessView.ingest(.contentDelta(
                threadId: livenessThread, turnId: livenessTurn, streamKind: .assistant,
                delta: "A parked body still receives its stream, and this delta must reach layout."
            ))
            // `AgentTranscriptListView.enqueue` gates presentation at 30 Hz, so the
            // model gains its card immediately while the view is scheduled — the
            // first version of this witness read that gate as deadness (1 card, 0
            // layouts). Flushing it is the same call the gate itself makes a frame
            // later, and it keeps the witness synchronous instead of racing a timer.
            livenessView.qaTranscriptCollectionFixture?.flushPendingVisualUpdate()
            pump()
            // NOT the list view's own `qaLayoutPassCount`: a content change does not
            // move that view's frame, so its `layout()` legitimately does not run,
            // and reading zero there as deadness is what the first version of this
            // witness did. The producer's requirement is narrower and checkable —
            // a bake taken after the event must differ from one taken before.
            let livenessBakeAfter = try bakeParked(livenessView)
            row.parkedStreamingCards = livenessView.transcriptCardCount - livenessCardsBefore
            row.parkedStreamingPixelDelta = differingBytes(livenessBakeBefore, livenessBakeAfter)
            row.parkedBakeColors = VisualSnapshot.metrics(of: livenessBakeAfter).distinctSampledColors

            for view in agentViews.values where view.superview === parkContainer {
                view.removeFromSuperview()
            }
            parkContainer.removeFromSuperview()
            for view in installedForArm { view.removeFromSuperview() }
            installedForArm = []
            for (_, view) in surfaceViews { view.removeFromSuperview() }
            for (_, view) in agentViews { view.removeFromSuperview() }
            rows.append(row)
        }

        guard let smallest = rows.first, let largest = rows.last else {
            throw Failure(message: "surface-host is missing a sweep endpoint")
        }
        func arm(_ row: Row, _ key: Arm) throws -> ArmSample {
            guard let sample = row.arms[key] else {
                throw Failure(message: "surface-host row \(row.count) is missing its \(key.rawValue) arm")
            }
            return sample
        }
        let smallestCulled = try arm(smallest, .culled)
        let largestCulled = try arm(largest, .culled)
        let smallestUnculled = try arm(smallest, .unculled)
        let largestUnculled = try arm(largest, .unculled)
        let largestNative = try arm(largest, .native)
        let smallestParked = try arm(smallest, .parked)
        let largestParked = try arm(largest, .parked)

        let culledSlope = largestCulled.arrayP50 - smallestCulled.arrayP50
        let unculledSlope = largestUnculled.arrayP50 - smallestUnculled.arrayP50
        let worstCulled = rows.compactMap { $0.arms[.culled]?.worst }.max() ?? 0
        let p95Culled = rows.compactMap { $0.arms[.culled]?.p95 }.max() ?? 0
        let arrayP95Culled = rows.compactMap { $0.arms[.culled]?.arrayP95 }.max() ?? 0
        let flushP95Culled = rows.compactMap { $0.arms[.culled]?.flushP95 }.max() ?? 0
        let arrayLateShareCulled = rows.compactMap {
            $0.arms[.culled]?.arrayLateShare(frameBudgetMs)
        }.max() ?? 0
        // The largest disagreement between any arm's two ABBA observations, across
        // the whole sweep. Ratios only mean something once the numbers are off the
        // timer's floor, so sub-0.5 ms pairs are excluded rather than allowed to
        // manufacture a huge ratio out of noise.
        let worstPassDrift = rows.flatMap { row in
            row.passMedians.values.compactMap { pair -> Double? in
                guard pair.count == 2, let low = pair.min(), let high = pair.max(),
                      low > 0.5 else { return nil }
                return high / low
            }
        }.max() ?? 1
        let culledVsNative = largestNative.arrayP50 > 0
            ? largestCulled.arrayP50 / largestNative.arrayP50 : 1
        let unculledVsNative = largestNative.arrayP50 > 0
            ? largestUnculled.arrayP50 / largestNative.arrayP50 : 1
        let surfaceRasterRequests = rows.reduce(0) { total, row in
            total + Arm.allCases.filter { $0 != .native }
                .reduce(0) { $0 + (row.arms[$1]?.rasterRequests ?? 0) }
        }
        let surfaceTranscriptLayouts = rows.reduce(0) { total, row in
            total + Arm.allCases.filter { $0 != .native }
                .reduce(0) { $0 + (row.arms[$1]?.transcriptLayouts ?? 0) }
        }
        // Summed over every row and both ABBA observations: one re-layout anywhere
        // in the park, on any camera step, at any tile count, kills parking as a
        // producer strategy.
        let parkedTranscriptLayouts = rows.reduce(0) { $0 + ($1.arms[.parked]?.parkedTranscriptLayouts ?? 0) }
        let parkedSlope = largestParked.arrayP50 - smallestParked.arrayP50
        let arrayP95Parked = rows.compactMap { $0.arms[.parked]?.arrayP95 }.max() ?? 0
        let parkedVsNative = largestNative.arrayP50 > 0
            ? largestParked.arrayP50 / largestNative.arrayP50 : 1
        let parkedVsUnculled = largestUnculled.arrayP50 > 0
            ? largestParked.arrayP50 / largestUnculled.arrayP50 : 1
        // Per-row shortfall, because the count that has to be right differs per
        // row: gating the minimum parked-body count across the sweep against the
        // LARGEST row's tile count fails on the smallest row by construction, which
        // is exactly how the first run of this arm reported 5 against a budget of 15.
        let worstParkedShortfall = rows.map { row in
            (row.arms[.parked]?.parkedBodies ?? 0) - row.count
        }.min() ?? 0
        let weakestStreamingCards = rows.map { $0.parkedStreamingCards }.min() ?? 0
        let weakestStreamingPixels = rows.map { $0.parkedStreamingPixelDelta }.min() ?? 0
        let weakestBakeColors = rows.map { $0.parkedBakeColors }.min() ?? 0
        let nativeTranscriptLayouts = rows.reduce(0) { $0 + ($1.arms[.native]?.transcriptLayouts ?? 0) }
        let oracleMismatches = rows.reduce(0) { row, next in
            row + Arm.allCases.reduce(0) { $0 + (next.arms[$1]?.oracleMismatches ?? 0) }
        }
        let onScreenCounts = Set(rows.compactMap { $0.arms[.culled]?.onScreen })
        let worstFinalZoomError = rows.map { abs($0.finalZoomReached - finalZoom) }.max() ?? 0

        guard onScreenCounts.count <= 1 else {
            throw Failure(message: "surface-host must hold the culled arm's visible count fixed; "
                          + "saw \(onScreenCounts.sorted()) — the slope would conflate installed with visible")
        }

        var measurements: [PerfMeasurement] = []

        // ---- Structural gate: the arms are what they claim to be ----
        measurements.append(PerfBudget(
            metric: "surface-host.nativeArmTranscriptLayouts", limit: .atLeast(1), unit: .count,
            rationale: "teeth: the control must reproduce the real backing cascade, or the surface arms are being compared against nothing"
        ).evaluate(Double(nativeTranscriptLayouts)))
        measurements.append(PerfBudget(
            metric: "surface-host.surfaceArmTranscriptLayouts", limit: .exactly(0), unit: .count,
            rationale: "a flat surface body has no transcript to lay out; a pass here means a native tree is still installed in a surface arm"
        ).evaluate(Double(surfaceTranscriptLayouts)))
        measurements.append(PerfBudget(
            metric: "surface-host.culledDriverCommits", limit: .exactly(Double(steps)), unit: .count,
            rationale: "teeth: every step must be one real production driver commit — a cheap arm that stopped committing is not a fast arm"
        ).evaluate(Double(largestCulled.driverCommits)))
        measurements.append(PerfBudget(
            metric: "surface-host.culledBoundsSizeWrites", limit: .atLeast(Double(steps)), unit: .count,
            rationale: "teeth: Shape A still moves the camera through bounds.size — the zoom cascade is entered for real, nothing is held"
        ).evaluate(Double(largestCulled.boundsSizeWrites)))
        measurements.append(PerfBudget(
            metric: "surface-host.culledInstalledHosts", limit: .exactly(Double(visibleClusterCount)), unit: .count,
            rationale: "teeth: the culled arm must actually have culled — the claim is that installed count follows the viewport, not the world"
        ).evaluate(Double(largestCulled.installedHosts)))
        measurements.append(PerfBudget(
            metric: "surface-host.unculledInstalledHosts", limit: .exactly(Double(largest.count)), unit: .count,
            rationale: "teeth: the unculled arm must hold every host, or there is no culling contrast and the two effects cannot be separated"
        ).evaluate(Double(largestUnculled.installedHosts)))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedInstalledHosts", limit: .exactly(Double(largest.count)), unit: .count,
            rationale: "teeth: the parked arm installs the same hosts as the unculled arm, so the only difference between them is that the real bodies are still alive"
        ).evaluate(Double(largestParked.installedHosts)))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedBodyShortfall", limit: .exactly(0), unit: .count,
            rationale: "teeth: every real agent body is actually IN the park, at every count in the sweep — an empty park would make the parked arm a duplicate of the unculled one"
        ).evaluate(Double(worstParkedShortfall)))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedStreamingCards", limit: .atLeast(1), unit: .count,
            rationale: "teeth at the model level: the ingested event became transcript content, so the park preserves the subscriber and not merely the view"
        ).evaluate(Double(weakestStreamingCards)))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedBakeColors", limit: .atLeast(2), unit: .count,
            rationale: "teeth: cacheDisplay of a body clipped out of every draw still yields real pixels. A blank bake here means the interim producer does not exist and the slice needs the off-main display list first"
        ).evaluate(Double(weakestBakeColors)))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedStreamingPixelDelta", limit: .atLeast(1), unit: .count,
            rationale: "teeth: a parked body must be QUIET, not dead — a bake taken after one real streaming event must differ from one taken before, or every surface would be stale by construction"
        ).evaluate(Double(weakestStreamingPixels)))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedTranscriptLayouts", limit: .exactly(0), unit: .count,
            rationale: "the question the first production slice is downstream of: a camera step must not reach a demoted tile's live body. Nonzero means parking is not a producer strategy and an off-main display list is required before anything ships"
        ).evaluate(Double(parkedTranscriptLayouts)))
        measurements.append(PerfBudget(
            metric: "surface-host.cameraCausedRasterRequests", limit: .exactly(0), unit: .count,
            rationale: "the contentsScale trap: a camera step may not re-derive a surface. PERF_SURFACE_HOST_NAIVE_SCALE=1 is the negative witness that this counter can fail"
        ).evaluate(Double(surfaceRasterRequests)))
        measurements.append(PerfBudget(
            metric: "surface-host.distinctSurfaces", limit: .exactly(Double(largest.count)), unit: .count,
            rationale: "one real bake per host: a shared texture would let Core Animation collapse the scene and understate every surface arm"
        ).evaluate(Double(largest.distinctSurfaces)))
        measurements.append(PerfBudget(
            metric: "surface-host.surfaceMegabytes", limit: .atLeast(1), unit: .megabytes,
            rationale: "published, not gated down: a cheap camera result is only interesting if the pixels it moved were real ones"
        ).evaluate(largest.bakedMegabytes))

        // ---- Correctness gate: it was correct while it was fast ----
        measurements.append(PerfBudget(
            metric: "surface-host.oracleMismatches", limit: .exactly(0), unit: .count,
            rationale: "teeth: on an unclocked pass over the same schedule every installed tile must sit where CanvasEngine says, in every arm"
        ).evaluate(Double(oracleMismatches)))
        measurements.append(PerfBudget(
            metric: "surface-host.finalZoomError", limit: .atMost(0.01), unit: .count,
            rationale: "teeth: the driver-inverted trajectory must actually arrive at the overview zoom it claims to measure"
        ).evaluate(worstFinalZoomError))

        // ---- Product targets ----
        measurements.append(PerfBudget(
            metric: "surface-host.culledArrayCpuP95", limit: .atMost(frameBudgetMs), unit: .milliseconds,
            rationale: "Shape A's product target, on the stage Array owns: driver commit + layout + draw must fit a 120 Hz frame at every count in the sweep"
        ).evaluate(arrayP95Culled))
        measurements.append(PerfBudget(
            metric: "surface-host.culledArrayCpuLateShare", limit: .atMost(10), unit: .count,
            rationale: "the tail an average hides: at most a tenth of Array-owned steps may overrun a frame, so a good median cannot cover a bimodal gesture"
        ).evaluate(arrayLateShareCulled))
        measurements.append(PerfBudget(
            metric: "surface-host.culledFlushP95", limit: .atLeast(0), unit: .milliseconds,
            rationale: "published, never gated as Array cost: CATransaction.flush can block on the render server, so this is compositor synchronisation and NOT proof of anything presented"
        ).evaluate(flushP95Culled))
        measurements.append(PerfBudget(
            metric: "surface-host.culledStepP95", limit: .atLeast(0), unit: .milliseconds,
            rationale: "published: Array CPU plus the flush. Reported so the two stages can never be silently traded against each other"
        ).evaluate(p95Culled))
        measurements.append(PerfBudget(
            metric: "surface-host.culledWorstStep", limit: .atLeast(0), unit: .milliseconds,
            rationale: "published: over a short trace the single worst step is usually the first display cycle after a reset, which is not the gesture a user feels"
        ).evaluate(worstCulled))
        measurements.append(PerfBudget(
            metric: "surface-host.armPassDrift", limit: .atMost(2), unit: .count,
            rationale: "doc 33's A/A rule: if one arm's two ABBA observations disagree by more than 2x the environment is not stable enough for an A/B conclusion, and the durations below are not admissible"
        ).evaluate(worstPassDrift))
        measurements.append(PerfBudget(
            metric: "surface-host.culledDurationSlope", limit: .atMost(0.5), unit: .milliseconds,
            rationale: "the same target magnify-slope publishes: culling is supposed to make a camera step independent of TOTAL tile count"
        ).evaluate(culledSlope))
        measurements.append(PerfBudget(
            metric: "surface-host.unculledDurationSlope", limit: .atLeast(-frameBudgetMs), unit: .milliseconds,
            rationale: "effectively published: the slope culling has to remove (magnify-slope measured ~2 ms over 16 -> 128 shallow tiles). A slope may sit slightly BELOW zero when both endpoints are near the timer floor, so the floor is a frame rather than zero — a fast path must not be reported as failing because noise ordered two sub-millisecond medians the other way"
        ).evaluate(unculledSlope))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedArrayCpuP95", limit: .atMost(frameBudgetMs), unit: .milliseconds,
            rationale: "the shippable configuration's product target: surfaces on the canvas with every real body still streaming beside it must fit a 120 Hz frame"
        ).evaluate(arrayP95Parked))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedDurationSlope", limit: .atMost(0.5), unit: .milliseconds,
            rationale: "keeping N live bodies out of the plane must not reintroduce a per-tile camera cost by another route"
        ).evaluate(parkedSlope))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedVsNativeRatio", limit: .atMost(0.5), unit: .count,
            rationale: "the honest headline for the slice: same tiles, same live agents, same installed count — only the body in the plane differs"
        ).evaluate(parkedVsNative))
        measurements.append(PerfBudget(
            metric: "surface-host.parkedVsUnculledRatio", limit: .atLeast(0), unit: .count,
            rationale: "published, not gated: what keeping the real bodies alive costs on top of surfaces alone. Above 1 by much means the window's layout pass still charges for the park"
        ).evaluate(parkedVsUnculled))
        measurements.append(PerfBudget(
            metric: "surface-host.culledVsNativeRatio", limit: .atMost(0.5), unit: .count,
            rationale: "a Shape A step must cost under half a native step at the top of the sweep, or replacing the body and culling together bought nothing"
        ).evaluate(culledVsNative))
        measurements.append(PerfBudget(
            metric: "surface-host.unculledVsNativeRatio", limit: .atLeast(0), unit: .count,
            rationale: "published, not gated: at equal installed count this isolates what replacing the BODY bought, separately from what culling bought"
        ).evaluate(unculledVsNative))

        let policyLabel = usesNaiveScalePolicy
            ? "NAIVE scale policy (negative witness)"
            : "owned bucketed scale policy"
        let detail = "ABBA over 3 arms, \(steps) production driver commits 1.0->"
            + String(format: "%.2f", finalZoom)
            + " on real agent tiles x \(turnsPerAgent) turns, \(policyLabel), zone chrome on, counts "
            + requestedCounts.map(String.init).joined(separator: "/")
            + "; " + rows.map { row in
                let perArm = Arm.allCases.map { key -> String in
                    guard let s = row.arms[key] else { return "\(key.rawValue) missing" }
                    let passes = (row.passMedians[key] ?? []).map { String(format: "%.2f", $0) }
                        .joined(separator: "/")
                    return String(format: "%@ arrayCPU p50 %.2f p95 %.2f (%.0f%% late) + flush p50 %.2f p95 %.2f = step p50 %.2f p95 %.2f worst %.2f ms (passes %@, %d inst, %d vis, %d tileLay, %d chrome, %d cb)",
                                  key.rawValue, s.arrayP50, s.arrayP95, s.arrayLateShare(frameBudgetMs),
                                  s.flushP50, s.flushP95, s.p50, s.p95, s.worst,
                                  passes, s.installedHosts, s.onScreen, s.tileLayouts,
                                  s.chromeRedraws, s.backingCallbacks)
                }.joined(separator: ", ")
                return String(format: "[%d tiles, %.1f MB, park liveness %d cards/%d px bytes/%d colors] ",
                              row.count, row.bakedMegabytes, row.parkedStreamingCards,
                              row.parkedStreamingPixelDelta, row.parkedBakeColors) + perArm
            }.joined(separator: " | ")
        return PerfScenarioResult(name: "canvas.surface-host-slope", detail: detail, measurements: measurements)
    }

    /// A Shape A surface host, exactly as `.plans/34` I15 describes it: a normal
    /// `TileNSView` — chrome, close button, grab strip, resize edges, cursor
    /// rects, focus adapter and z-order all inherited untouched — whose CONTENT
    /// VIEW is one layer-hosting view carrying an Array-owned layer.
    ///
    /// The body owns its layer, so it also owns the response to a backing-property
    /// change. AppKit's default would track the window/effective scale; this
    /// applies a BUCKETED policy and counts what a camera step actually caused, so
    /// the `contentsScale` trap becomes a measured fact rather than an assumption.
    @MainActor
    final class TileSurfaceProbeView: TileNSView {
        /// Swap the owned policy for the naive one that follows the live effective
        /// scale. This is the permanent negative witness for
        /// `surface-host.cameraCausedRasterRequests`: with it on, a camera step
        /// re-derives every surface and the counter must go nonzero.
        var usesNaiveScalePolicy = false {
            didSet { surfaceBody.usesNaiveScalePolicy = usesNaiveScalePolicy }
        }

        private let surfaceBody: SurfaceBodyView

        var qaBackingCallbackCount: Int { surfaceBody.qaBackingCallbackCount }
        var qaRasterRequestCount: Int { surfaceBody.qaRasterRequestCount }
        func qaResetSurfaceCounters() { surfaceBody.qaResetCounters() }

        init(tile: Tile, surface: CGImage) {
            surfaceBody = SurfaceBodyView(surface: surface)
            super.init(tile: tile)
            setContentView(surfaceBody)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        private final class SurfaceBodyView: NSView {
            /// Geometric, and the same 4 steps/octave the chrome floor already
            /// uses, so a surface's resolution changes at a bounded number of
            /// boundaries across a gesture instead of on every step.
            private static let stepsPerOctave: Double = 4

            private let surface: CGImage
            private let surfaceLayer = CALayer()

            var usesNaiveScalePolicy = false
            private(set) var qaBackingCallbackCount = 0
            private(set) var qaRasterRequestCount = 0

            init(surface: CGImage) {
                self.surface = surface
                super.init(frame: .zero)
                surfaceLayer.contents = surface
                surfaceLayer.contentsGravity = .resize
                surfaceLayer.contentsScale = 2
                surfaceLayer.isGeometryFlipped = true
                surfaceLayer.masksToBounds = true
                // Layer-HOSTING, not layer-backed: AppKit does not own these
                // contents, which is the whole point — a camera step must not be
                // able to invalidate them behind our back.
                layer = surfaceLayer
                wantsLayer = true
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

            override var isFlipped: Bool { true }

            override func layout() {
                super.layout()
                // Guarded: an unchanged frame assignment still marks the layer
                // dirty, which is the identity-write mistake AssistantProseView
                // already documents.
                if surfaceLayer.frame != bounds { surfaceLayer.frame = bounds }
            }

            /// The effective points-to-device-pixels ratio this view is currently
            /// rasterised at: the ancestor camera scale times the window's backing
            /// scale. A naive implementation reads exactly this and re-derives.
            private var effectiveScale: CGFloat {
                let backing = window?.backingScaleFactor ?? 2
                let unit = convert(CGSize(width: 1, height: 1), to: nil)
                return max(0.01, unit.width) * backing
            }

            private static func bucket(_ scale: CGFloat) -> CGFloat {
                guard scale.isFinite, scale > 0 else { return 1 }
                let bucketed = pow(2, (log2(Double(scale)) * stepsPerOctave).rounded(.down) / stepsPerOctave)
                return bucketed.isFinite && bucketed > 0 ? CGFloat(bucketed) : scale
            }

            override func viewDidChangeBackingProperties() {
                qaBackingCallbackCount += 1
                // The owned policy deliberately ignores the ancestor's effective
                // scale and follows only the DISPLAY's backing scale, which canvas
                // zoom does not change. The naive policy is the bug this probe
                // exists to be able to fail on.
                let desired = usesNaiveScalePolicy
                    ? effectiveScale
                    : Self.bucket(window?.backingScaleFactor ?? 2)
                guard abs(surfaceLayer.contentsScale - desired) > 0.0001 else { return }
                surfaceLayer.contentsScale = desired
                // A scale change is a re-derivation request: the surface has to be
                // produced again at the new density. The probe does the real work
                // rather than only counting, so the negative arm pays what the bug
                // would actually cost.
                qaRasterRequestCount += 1
                // Re-publishing the SAME image is deliberately not a real
                // re-rasterisation, and the negative arm is therefore a witness
                // about the DECISION, not about the cost: with the naive policy the
                // counter goes to steps x hosts while the duration barely moves
                // (measured 0.12 vs 0.07 ms p50). A real producer would re-render
                // the surface here and pay for it. Counts prove causality; do not
                // read this arm as a cost measurement.
                surfaceLayer.contents = surface
                surfaceLayer.setNeedsDisplay()
            }

            func qaResetCounters() {
                qaBackingCallbackCount = 0
                qaRasterRequestCount = 0
            }
        }
    }

    // MARK: - Scenario: AppKit scroll-view magnification

    /// Can AppKit's supported magnification boundary present a real native view
    /// tree without recreating the per-frame backing/layout cascade?
    ///
    /// This is deliberately an isolated prototype, not production camera code.
    /// The document contains the same ten real managed-agent transcript trees as
    /// the geometry-hold probe. Every magnification tick includes the real display
    /// and Core Animation commit where the profile's work landed.
    static func canvasScrollMagnificationProbe() throws -> PerfScenarioResult {
        let tileCount = 10
        let turnsPerAgent = 6
        let steps = 60
        let baselineZoom: CGFloat = 1
        let finalZoom: CGFloat = 0.45

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)

        let zoneId = UUID()
        let placement = ZonePlacement(
            zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
            size: ZoneSize(width: 2_500, height: 900), color: "blue",
            collapsed: false, hydrationPolicy: .automatic
        )
        var tiles: [Tile] = []
        for index in 0..<tileCount {
            tiles.append(Tile(
                id: UUID(), kind: .managedAgent, title: "scroll-magnification-\(index)",
                frame: TileFrame(x: Double(index % 5) * 480 + 40,
                                 y: Double(index / 5) * 360 + 60,
                                 width: 420, height: 300),
                zPosition: .fromLegacyRank(index + 1), zoneId: zoneId,
                runtimeRef: nil, metadata: TileMetadata()
            ))
        }
        let layer = CanvasNSView.ZoneLayer(
            placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Scroll magnification probe"),
            tiles: tiles
        )
        for (index, tile) in tiles.enumerated() {
            let view = ManagedAgentTileNSView(tile: tile, threadId: "scroll-magnification-\(index)")
            view.renderRehydratedPreviousSession(
                transcriptFixture(threadId: "scroll-magnification-\(index)", turns: turnsPerAgent)
            )
            layer.tileViews[tile.id] = view
        }
        canvas.setZones([layer])

        // Reuse CanvasNSView only as the real fixture builder/counter owner. The
        // experiment itself gives AppKit a normal document view through its
        // supported NSScrollView boundary; no production view hierarchy changes.
        let document = canvas.worldPlane
        document.removeFromSuperview()
        document.frame = CGRect(x: 0, y: 0, width: 2_500, height: 1_000)
        document.bounds = document.frame
        document.clipsToBounds = false

        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000))
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.allowsMagnification = false
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4
        scrollView.documentView = document

        let viewportHost = NSView(frame: scrollView.frame)
        viewportHost.wantsLayer = true
        viewportHost.addSubview(scrollView)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = viewportHost
        window.orderFrontOffscreenForChecks()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            scrollView.documentView = nil
        }

        func pump() {
            scrollView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }

        func milliseconds(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
            return sorted[min(max(index, 0), sorted.count - 1)]
        }

        func reset() {
            scrollView.setMagnification(baselineZoom, centeredAt: CGPoint(x: 800, y: 500))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            pump()
        }

        let targets = (1...steps).map { step in
            baselineZoom + (finalZoom - baselineZoom) * CGFloat(step) / CGFloat(steps)
        }

        // Drain construction and warm the exact API before either clock starts.
        reset()
        for zoom in targets.prefix(4) {
            scrollView.setMagnification(zoom, centeredAt: CGPoint(x: 800, y: 500))
            pump()
        }
        reset()

        var magnifiedFrames: [Double] = []
        var heldFrames: [Double] = []
        var magnifiedTileLayouts = 0
        var magnifiedTranscriptLayouts = 0
        var heldTileLayouts = 0
        var heldTranscriptLayouts = 0
        var worstAnchorError: CGFloat = 0

        enum Arm { case magnified, held }
        for arm in [Arm.magnified, .held, .held, .magnified] {
            reset()
            let tileLayoutsBefore = canvas.qaTotalTileLayoutPassCount
            let transcriptLayoutsBefore = canvas.qaTotalTranscriptLayoutPassCount
            switch arm {
            case .magnified:
                for zoom in targets {
                    let anchor = CGPoint(x: 800, y: 500)
                    let documentPoint = document.convert(anchor, from: scrollView.contentView)
                    magnifiedFrames.append(milliseconds {
                        scrollView.setMagnification(zoom, centeredAt: anchor)
                        pump()
                    })
                    let resultingAnchor = scrollView.contentView.convert(documentPoint, from: document)
                    worstAnchorError = max(worstAnchorError,
                                           hypot(resultingAnchor.x - anchor.x, resultingAnchor.y - anchor.y))
                }
                magnifiedTileLayouts += canvas.qaTotalTileLayoutPassCount - tileLayoutsBefore
                magnifiedTranscriptLayouts += canvas.qaTotalTranscriptLayoutPassCount - transcriptLayoutsBefore
            case .held:
                for _ in targets { heldFrames.append(milliseconds { pump() }) }
                heldTileLayouts += canvas.qaTotalTileLayoutPassCount - tileLayoutsBefore
                heldTranscriptLayouts += canvas.qaTotalTranscriptLayoutPassCount - transcriptLayoutsBefore
            }
        }

        let magnifiedMedian = percentile(magnifiedFrames, 0.5)
        let magnifiedP95 = percentile(magnifiedFrames, 0.95)
        let heldMedian = percentile(heldFrames, 0.5)
        let heldP95 = percentile(heldFrames, 0.95)
        let ratio = magnifiedFrames.reduce(0, +) / max(heldFrames.reduce(0, +), 0.001)
        let lateShare = Double(magnifiedFrames.filter { $0 > frameBudgetMs }.count)
            / Double(max(magnifiedFrames.count, 1)) * 100

        // If the supported live boundary fails, quantify the bounded fallback
        // on the SAME rendered fixture: one settled bitmap capture, followed by
        // shallow image-view transforms while the native document stays held.
        // This does not establish terminal/browser fidelity or zoom-out coverage;
        // those are explicit product blockers recorded by the probe detail.
        reset()
        var snapshotRep: NSBitmapImageRep?
        let snapshotCaptureMs = milliseconds {
            snapshotRep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
            if let snapshotRep { scrollView.cacheDisplay(in: scrollView.bounds, to: snapshotRep) }
        }
        guard let snapshotRep else {
            throw Failure(message: "scroll magnification probe could not allocate its snapshot fallback")
        }
        let snapshotBytes = snapshotRep.pixelsWide * snapshotRep.pixelsHigh * 4
        let snapshotImage = NSImage(size: scrollView.bounds.size)
        snapshotImage.addRepresentation(snapshotRep)
        let proxy = NSImageView(frame: scrollView.frame)
        proxy.imageScaling = .scaleAxesIndependently
        proxy.image = snapshotImage
        viewportHost.addSubview(proxy, positioned: .above, relativeTo: scrollView)
        scrollView.isHidden = true
        pump()

        let proxyTileLayoutsBefore = canvas.qaTotalTileLayoutPassCount
        let proxyTranscriptLayoutsBefore = canvas.qaTotalTranscriptLayoutPassCount
        var proxyFrames: [Double] = []
        for zoom in targets + targets.reversed() {
            let scale = zoom / baselineZoom
            let size = CGSize(width: scrollView.bounds.width * scale,
                              height: scrollView.bounds.height * scale)
            let origin = CGPoint(x: 800 - 800 * scale, y: 500 - 500 * scale)
            proxyFrames.append(milliseconds {
                proxy.frame = CGRect(origin: origin, size: size)
                pump()
            })
        }
        let proxyTileLayouts = canvas.qaTotalTileLayoutPassCount - proxyTileLayoutsBefore
        let proxyTranscriptLayouts = canvas.qaTotalTranscriptLayoutPassCount - proxyTranscriptLayoutsBefore
        let proxyMedian = percentile(proxyFrames, 0.5)
        let proxyP95 = percentile(proxyFrames, 0.95)

        var measurements: [PerfMeasurement] = []
        measurements.append(PerfBudget(
            metric: "scroll-magnification.managedAgentTiles", limit: .exactly(Double(tileCount)), unit: .count,
            rationale: "the supported-boundary probe must carry ten real managed-agent transcript subtrees"
        ).evaluate(Double(canvas.qaTotalInstalledTileCount)))
        measurements.append(PerfBudget(
            metric: "scroll-magnification.heldTileLayouts", limit: .exactly(0), unit: .count,
            rationale: "the no-op control must stay settled or the comparison contains unrelated work"
        ).evaluate(Double(heldTileLayouts)))
        measurements.append(PerfBudget(
            metric: "scroll-magnification.heldTranscriptLayouts", limit: .exactly(0), unit: .count,
            rationale: "the no-op control must not re-layout transcript content"
        ).evaluate(Double(heldTranscriptLayouts)))
        measurements.append(PerfBudget(
            metric: "scroll-magnification.anchorError", limit: .atMost(0.5), unit: .count,
            rationale: "AppKit's supported centered magnification must keep the same document point under the requested viewport pixel"
        ).evaluate(Double(worstAnchorError)))
        measurements.append(PerfBudget(
            metric: "scroll-magnification.p95Duration", limit: .atMost(frameBudgetMs), unit: .milliseconds,
            rationale: "a viable presentation boundary must fit the 120 Hz frame budget with real managed-agent descendants"
        ).evaluate(magnifiedP95))
        measurements.append(PerfBudget(
            metric: "snapshot-proxy.captureDuration", limit: .atMost(16.7), unit: .milliseconds,
            rationale: "a gesture-start proxy must be captured without a visible multi-frame hitch; transform-only speed cannot hide capture latency"
        ).evaluate(snapshotCaptureMs))
        measurements.append(PerfBudget(
            metric: "snapshot-proxy.p95Duration", limit: .atMost(frameBudgetMs), unit: .milliseconds,
            rationale: "after capture, the shallow bitmap presenter must fit a 120 Hz frame"
        ).evaluate(proxyP95))
        measurements.append(PerfBudget(
            metric: "snapshot-proxy.tileLayouts", limit: .exactly(0), unit: .count,
            rationale: "proxy presentation must leave the held native tile tree geometrically untouched"
        ).evaluate(Double(proxyTileLayouts)))
        measurements.append(PerfBudget(
            metric: "snapshot-proxy.transcriptLayouts", limit: .exactly(0), unit: .count,
            rationale: "proxy presentation must not reach the held transcript subtree"
        ).evaluate(Double(proxyTranscriptLayouts)))

        let detail = "ABBA, \(steps) ticks/arm over \(tileCount) real agent tiles x \(turnsPerAgent) turns; "
            + String(format: "magnification p50 %.2f / p95 %.2f ms (%.0f%% late), ",
                     magnifiedMedian, magnifiedP95, lateShare)
            + String(format: "held p50 %.2f / p95 %.2f ms; ratio %.1fx; ", heldMedian, heldP95, ratio)
            + "layouts magnified tile/transcript \(magnifiedTileLayouts)/\(magnifiedTranscriptLayouts), "
            + "held \(heldTileLayouts)/\(heldTranscriptLayouts); "
            + String(format: "worst anchor error %.3f px; ", worstAnchorError)
            + String(format: "snapshot capture %.2f ms / %.1f MiB, proxy p50 %.2f / p95 %.2f ms, layouts %d/%d; ",
                     snapshotCaptureMs, Double(snapshotBytes) / 1_048_576, proxyMedian, proxyP95,
                     proxyTileLayouts, proxyTranscriptLayouts)
            + "snapshot remains fidelity/zoom-out-coverage disqualified until separately proven"
        return PerfScenarioResult(name: "canvas.scroll-magnification-probe", detail: detail,
                                  measurements: measurements)
    }

    // MARK: - Scenario: many tiles across many zones

    /// The scaling question the 12-tile scenario cannot answer.
    ///
    /// `layoutAllTiles` is O(every tile on the canvas) with no culling: it visits
    /// the flat collection AND every tile of every installed `ZoneLayer`, whether
    /// or not the tile is anywhere near the viewport. At a dozen tiles that pass
    /// is 4% of a frame and culling would be solving a problem that does not
    /// exist. At the size a real workspace reaches — dozens of agent tiles spread
    /// across several zones — the same pass is the whole frame.
    ///
    /// This drives the REAL multi-zone model (`setZones`, the `_layoutLayerTile`
    /// path that owns the active project once `WorkspaceRuntime` has installed
    /// zones) at several sizes and reports the cost per tile per step, so the
    /// point where the canvas stops fitting in a frame is a measured number
    /// rather than a guess.
    static func canvasStress() throws -> PerfScenarioResult {
        let zoneCount = Int(ProcessInfo.processInfo.environment["PERF_STRESS_ZONES"] ?? "") ?? 6
        let tilesPerZone = Int(ProcessInfo.processInfo.environment["PERF_STRESS_TILES_PER_ZONE"] ?? "") ?? 8
        let turnsPerAgent = Int(ProcessInfo.processInfo.environment["PERF_STRESS_TURNS"] ?? "") ?? 6
        let steps = Int(ProcessInfo.processInfo.environment["PERF_STRESS_STEPS"] ?? "") ?? 60
        let stressZoom = Double(ProcessInfo.processInfo.environment["PERF_STRESS_ZOOM"] ?? "") ?? 0.35

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: true
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()

        var layers: [CanvasNSView.ZoneLayer] = []
        for zoneIndex in 0..<zoneCount {
            let zoneId = UUID()
            let placement = ZonePlacement(
                zoneId: zoneId, projectId: UUID(),
                origin: ZonePoint(x: Double(zoneIndex % 3) * 2_600, y: Double(zoneIndex / 3) * 2_000),
                size: ZoneSize(width: 2_400, height: 1_800), color: "blue",
                collapsed: false, hydrationPolicy: .automatic
            )
            var tiles: [Tile] = []
            for tileIndex in 0..<tilesPerZone {
                tiles.append(Tile(
                    id: UUID(), kind: .managedAgent, title: "stress-\(zoneIndex)-\(tileIndex)",
                    frame: TileFrame(x: Double(tileIndex % 5) * 460 + 40,
                                     y: Double(tileIndex / 5) * 340 + 60,
                                     width: 420, height: 300),
                    zPosition: .fromLegacyRank(tileIndex + 1),
                    zoneId: zoneId, runtimeRef: nil, metadata: TileMetadata()
                ))
            }
            let layer = CanvasNSView.ZoneLayer(
                placement: placement,
                renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Zone \(zoneIndex)"),
                tiles: tiles
            )
            for (tileIndex, tile) in tiles.enumerated() {
                // REAL managed-agent tiles carrying REAL transcripts. A note tile
                // would understate the load by the entire transcript renderer —
                // `AssistantProseView` is what took the app to 98.6% CPU in
                // 0.4.16, and an agent tile is what a busy workspace is full of.
                let view = ManagedAgentTileNSView(tile: tile, threadId: "stress-\(zoneIndex)-\(tileIndex)")
                view.renderRehydratedPreviousSession(
                    transcriptFixture(threadId: "stress-\(zoneIndex)-\(tileIndex)", turns: turnsPerAgent)
                )
                layer.tileViews[tile.id] = view
            }
            layers.append(layer)
        }
        canvas.setZones(layers)
        canvas.layoutSubtreeIfNeeded()

        let tileCount = canvas.qaTotalInstalledTileCount
        guard tileCount == zoneCount * tilesPerZone else {
            throw Failure(message: "stress harness must install \(zoneCount * tilesPerZone) tiles; got \(tileCount)")
        }

        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: stressZoom))
        canvas.layoutSubtreeIfNeeded()

        canvas.qaResetCameraLayoutStats()
        let start = ProcessInfo.processInfo.systemUptime
        for step in 0..<steps {
            let t = Double(step)
            canvas.setViewport(CanvasViewport(x: t * 12, y: t * 8, zoom: stressZoom))
            canvas.layoutSubtreeIfNeeded()
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        let stats = canvas.qaCameraLayoutStats
        let perStepMs = seconds / Double(steps) * 1_000

        // How many of those tiles were anywhere near the screen. Everything else
        // was laid out for nothing — this is the number that decides whether
        // culling is worth building.
        let onScreen = canvas.qaTilesIntersectingViewport
        let offScreenShare = tileCount > 0 ? Double(tileCount - onScreen) / Double(tileCount) : 0

        var measurements: [PerfMeasurement] = []
        measurements.append(PerfBudget(
            metric: "stress.stepDuration",
            limit: .atMost(frameBudgetMs),
            unit: .milliseconds,
            rationale: "a pan over a large multi-zone workspace is the same camera step a small one runs; it gets the same 8.3 ms"
        ).evaluate(perStepMs))

        measurements.append(PerfBudget(
            metric: "stress.boundsWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "a pan changes no tile's logical size, at any canvas size"
        ).evaluate(Double(stats.boundsWrites)))

        // The culling budget. Laying out a tile that cannot be seen is work with
        // no product effect; allowing a little slack covers tiles straddling the
        // edge, but a pass that is mostly off-screen tiles is the definition of
        // the missing optimisation.
        measurements.append(PerfBudget(
            metric: "stress.tilesLaidOutPerStep",
            limit: .atMost(Double(onScreen) * 1.5 + 4),
            unit: .count,
            rationale: "a camera step should lay out what is visible, not the whole workspace; off-screen tiles cost a frame and change nothing on screen"
        ).evaluate(Double(stats.tilesLaidOut) / Double(steps)))

        // Same replacement as the camera scenarios: tile frame writes are the old
        // architecture's proof of life, and the retained world plane makes them
        // legitimately zero. The camera moved, and the presentation followed.
        measurements.append(PerfBudget(
            metric: "stress.cameraMutations",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera must actually have moved"
        ).evaluate(Double(stats.cameraMutations)))

        measurements.append(PerfBudget(
            metric: "stress.screenFrameMismatches",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: every visible tile must end up where the camera says"
        ).evaluate(Double(canvas.qaTileScreenFrameMismatchCount)))

        let detail = "\(steps) pan steps over \(tileCount) tiles in \(zoneCount) zones "
            + "(\(onScreen) on screen, \(Int(offScreenShare * 100))% off screen), "
            + "\(String(format: "%.3f", seconds))s total, "
            + String(format: "%.4f ms per tile per step", perStepMs / Double(max(tileCount, 1)))
        return PerfScenarioResult(name: "canvas.stress", detail: detail, measurements: measurements)
    }

    // MARK: - Scenario: canvas camera

    enum CameraGesture: String {
        case pan
        case zoom
    }

    /// Drives the REAL camera funnel — `CanvasNSView.setViewport`, the same entry
    /// point the trackpad scroll branch, the pinch branch and the pointer-pan
    /// drag all reach — over a canvas holding real tiles including large Markdown
    /// documents, and reports what one step costs.
    ///
    /// `zoom` is the constant camera scale a PAN runs at (a zoom gesture walks
    /// the scale itself and ignores it). `label` names the scenario and its
    /// metrics when one gesture runs under more than one configuration.
    static func canvasCamera(_ gesture: CameraGesture, zoom: Double = 1, label: String? = nil) throws -> PerfScenarioResult {
        let label = label ?? gesture.rawValue
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("continuum-perf-\(label)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let root = tempRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let harness = try makeHarness(root: root, tempRoot: tempRoot)
        let canvas = harness.canvas

        for index in 0..<3 {
            let path = root.appendingPathComponent("doc-\(index).md")
            try documentFixture(index: index).write(to: path, atomically: true, encoding: .utf8)
            guard case .opened = harness.runtime.openProjectFile(path: path.path) else {
                throw Failure(message: "the fixture document must open as a tile")
            }
        }
        guard let spawner = harness.runtime.activeController?.tileSpawner else {
            throw Failure(message: "the harness must expose the active project's tile spawner")
        }
        for index in 0..<9 {
            if case let .failure(error) = spawner.spawnNote(title: "perf-note-\(index)") {
                throw Failure(message: "spawning a note tile failed: \(error)")
            }
        }
        canvas.layoutSubtreeIfNeeded()

        let tileCount = canvas.qaTotalInstalledTileCount
        guard tileCount >= 12 else {
            throw Failure(message: "the fixture canvas must hold a realistic number of tiles; got \(tileCount)")
        }

        // Settle first, so the measured steps are steady-state and not paying for
        // the first render of three documents.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
        canvas.layoutSubtreeIfNeeded()

        let steps = 120
        canvas.qaResetCameraLayoutStats()
        let proseBefore = AssistantProseView.qaMeasurementCount
        let chromeRedrawsBefore = canvas.qaTotalTileChromeRedrawCount
        let layoutInvalidationsBefore = canvas.qaTotalTileLayoutInvalidationCount
        let layoutPassesBefore = canvas.qaTotalTileLayoutPassCount
        let transcriptPassesBefore = canvas.qaTotalTranscriptLayoutPassCount
        let start = ProcessInfo.processInfo.systemUptime
        for step in 0..<steps {
            switch gesture {
            case .pan:
                let t = Double(step)
                canvas.setViewport(CanvasViewport(x: t * 3, y: t * 2, zoom: zoom))
            case .zoom:
                // A real pinch walks the scale continuously; never repeat a value.
                let zoom = 0.4 + 0.6 * (1 + sin(Double(step) / 18.0)) / 2
                canvas.setViewport(CanvasViewport(x: 120, y: 90, zoom: zoom))
            }
            canvas.layoutSubtreeIfNeeded()
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        let stats = canvas.qaCameraLayoutStats
        let prose = AssistantProseView.qaMeasurementCount - proseBefore
        let chromeRedraws = canvas.qaTotalTileChromeRedrawCount - chromeRedrawsBefore
        let layoutInvalidations = canvas.qaTotalTileLayoutInvalidationCount - layoutInvalidationsBefore
        let layoutPasses = canvas.qaTotalTileLayoutPassCount - layoutPassesBefore
        let transcriptPasses = canvas.qaTotalTranscriptLayoutPassCount - transcriptPassesBefore
        let perStepMs = seconds / Double(steps) * 1_000

        var measurements: [PerfMeasurement] = []

        measurements.append(PerfBudget(
            metric: "\(label).stepDuration",
            limit: .atMost(frameBudgetMs),
            unit: .milliseconds,
            rationale: "a camera step runs once per display refresh; at 120 Hz the whole frame is 8.3 ms, and the canvas is not the only thing in it"
        ).evaluate(perStepMs))

        // The tile's LOGICAL size is zoom-independent — `bounds` is deliberately
        // held at the tile's own size while `frame` carries the scaled screen
        // rect. So NEITHER gesture has any reason to write bounds. Writing an
        // unchanged bounds still marks the view for layout and, for a text view,
        // costs a TextKit glyph-bounds pass: trap 3 in
        // docs/internals/performance.md, and the 0.4.17 fix one level down.
        measurements.append(PerfBudget(
            metric: "\(label).boundsWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "a tile's logical size does not change with the camera, so re-assigning bounds is pure waste that re-marks the whole subtree for layout"
        ).evaluate(Double(stats.boundsWrites)))

        measurements.append(PerfBudget(
            metric: "\(label).modelWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "nothing about a tile's model changes when the camera moves"
        ).evaluate(Double(stats.modelWrites)))

        // The document did not change and its logical width did not change, so a
        // camera move must cost no text measurement at all. This is the property
        // `--file-markdown-perf-check` asserts for a relayout, asserted here
        // through the real camera funnel instead.
        measurements.append(PerfBudget(
            metric: "\(label).proseMeasurements",
            limit: .exactly(0),
            unit: .count,
            rationale: "moving the camera does not change any document's content or logical width, so no row may be re-measured"
        ).evaluate(Double(prose)))

        // The REDRAW budget, and the reason this scenario was green while a real
        // pinch stayed choppy.
        //
        // Everything above measures LAYOUT. The harness never rasterizes, so a
        // step that marks all twelve tiles for redraw at a new scale costs it
        // nothing — while on a real canvas that is the dominant cost, because a
        // zoom changes SCALE and layer-backed content has to be re-rendered at it.
        // A 30-second sample of a real pinch over 9 live tiles (2026-08-14) put
        // ~2,600 samples in CA::Layer::display_if_needed and ~960 in the forced
        // subtree layout underneath it, against ~380 in the camera itself. The
        // camera was the third-largest cost and the only one this scenario could
        // see.
        //
        // The bound is stated in scale BUCKETS, which is the shape the fix has to
        // take (see the research doc's semantic-zoom section): chrome and content
        // hold steady through a pinch and refine when the bucket changes. This
        // sweep traverses 0.4–1.0 about twice, so a bucketed implementation costs
        // each tile a handful of crossings; today it costs each tile one redraw
        // per step, which is \(steps).
        measurements.append(PerfBudget(
            metric: "\(label).chromeRedraws",
            limit: .atMost(Double(tileCount * 16)),
            unit: .count,
            rationale: "a camera gesture may re-rasterize a tile's chrome when its SCALE BUCKET changes, not on every step — per-step refresh is \(tileCount * steps) here"
        ).evaluate(Double(chromeRedraws)))

        measurements.append(PerfBudget(
            metric: "\(label).tileLayoutInvalidations",
            limit: .exactly(0),
            unit: .count,
            rationale: "a camera step must not mark a tile body for relayout; that is what drags a whole subtree into the rasterization pass"
        ).evaluate(Double(layoutInvalidations)))

        // The LAYOUT-PASS budget, and the largest cost no budget was watching.
        //
        // `tileLayoutInvalidations` above counts the canvas ASKING for a relayout,
        // and reads 0 for both gestures — nothing on the camera path calls
        // `invalidateForCanvasLayout`. But a 30-second sample of a real pinch put
        // its biggest single block in the WINDOW's own display-cycle layout pass
        // (`NSWindow _layoutViewTree` -> `layoutSubtreeIfNeeded`, ~3,355 samples),
        // recursing through every mounted tile. Nobody asked for that; AppKit did
        // it because the plane's bounds SIZE changed, which is a resize. So the
        // question this budget answers is not "did we ask" but "did it arrive".
        //
        // A pan changes the plane's bounds ORIGIN — a translation — and is
        // expected at 0. A zoom changes bounds SIZE and is expected at roughly one
        // pass per tile per step. The contrast is the whole assertion.
        measurements.append(PerfBudget(
            metric: "\(label).tileLayoutPasses",
            limit: .atMost(Double(tileCount)),
            unit: .count,
            rationale: "a camera gesture may cost each visible tile about one settling layout, not one per step — per-step layout is \(tileCount * steps) here"
        ).evaluate(Double(layoutPasses)))

        measurements.append(PerfBudget(
            metric: "\(label).transcriptLayoutPasses",
            limit: .atMost(Double(tileCount)),
            unit: .count,
            rationale: "the same for the heaviest body we own; 0 here means the fixture holds no agent tile and cannot speak for a canvas that does"
        ).evaluate(Double(transcriptPasses)))

        // Teeth in the other direction: the assertions above must not be
        // satisfiable by a canvas that quietly stopped presenting anything.
        //
        // This used to assert `frameWrites >= 1` — "the camera must still
        // reposition tiles". That encoded the OLD architecture, in which the only
        // way a camera could move anything was to write every tile's frame. The
        // retained world plane moves one ancestor instead, so tile frame writes
        // are now correctly zero and the old budget would fail a working canvas.
        // Replaced, deliberately and with a strictly stronger pair rather than a
        // deletion: the camera must have moved, AND the presentation must have
        // followed it. `screenFrameMismatches` compares each visible tile's actual
        // rect — converted through the real view tree — against
        // CanvasEngine.tileScreenFrame, so a canvas that stopped presenting fails
        // here no matter which architecture is underneath.
        measurements.append(PerfBudget(
            metric: "\(label).cameraMutations",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera must actually have moved — a zero means the gesture did nothing, not that it got fast"
        ).evaluate(Double(stats.cameraMutations)))

        measurements.append(PerfBudget(
            metric: "\(label).screenFrameMismatches",
            limit: .exactly(0),
            unit: .count,
            rationale: "teeth: every visible tile must end up where the camera says, so the zero-write budgets above cannot be satisfied by a canvas that stopped presenting"
        ).evaluate(Double(canvas.qaTileScreenFrameMismatchCount)))

        let detail = "\(steps) \(label) steps over \(tileCount) tiles "
            + "(3 large Markdown documents + 9 notes), \(String(format: "%.3f", seconds))s total"
        return PerfScenarioResult(name: "canvas.\(label)", detail: detail, measurements: measurements)
    }

    /// A believable agent conversation: alternating prompts and replies, with
    /// prose (which is what `AssistantProseView` measures), a tool call and a
    /// command output per turn. The point is that each tile carries a real
    /// transcript view tree, not an empty shell.
    private static func transcriptFixture(threadId: String, turns: Int) -> RehydratedTranscript {
        var steps: [RehydratedTranscriptStep] = []
        for turn in 0..<turns {
            let turnId = "\(threadId)-turn-\(turn)"
            steps.append(.userPrompt("Refactor the \(turn) path and explain the tradeoffs you took."))
            steps.append(.event(.turnStarted(threadId: threadId, turnId: turnId)))
            steps.append(.event(.contentDelta(
                threadId: threadId, turnId: turnId, streamKind: .assistant,
                delta: String(repeating: "Here is what changed and why it is safe: `applyTileGeometry` now writes only what moved, "
                              + "which matters because an unchanged assignment still marks the subtree for layout. ", count: 4)
            )))
            steps.append(.event(.itemStarted(
                threadId: threadId, itemId: "\(turnId)-tool", kind: .commandExecution, title: "swift build --product Array"
            )))
            steps.append(.event(.contentDelta(
                threadId: threadId, turnId: turnId, streamKind: .commandOutput,
                delta: "Compiling ContinuumRevived CanvasNSView.swift\nBuild complete!\n"
            )))
            steps.append(.event(.itemCompleted(
                threadId: threadId, itemId: "\(turnId)-tool", kind: .commandExecution, status: .completed
            )))
            steps.append(.event(.turnCompleted(
                threadId: threadId, turnId: turnId, outcome: .completed, errorMessage: nil
            )))
        }
        return RehydratedTranscript(steps: steps, restoredMessageCount: turns * 2, omittedEarlier: false)
    }

    /// A document big enough that re-measuring it is visible, in the shape a user
    /// actually opens: headings, prose, lists, a wide table.
    private static func documentFixture(index: Int) -> String {
        var lines: [String] = ["# perf-sentinel-\(index)", ""]
        for section in 0..<40 {
            lines.append("## Section \(section)")
            lines.append("")
            lines.append(String(repeating: "Prose with `code`, **strong** text and a [link](https://example.com/\(section)). ", count: 6))
            lines.append("")
            lines.append("- item one for \(section)")
            lines.append("- item two for \(section)")
            lines.append("")
        }
        lines.append("| version | build | notes |")
        lines.append("| ------- | ----- | ----- |")
        for row in 0..<12 {
            lines.append("| 0.\(row).0 | \(row) | \(String(repeating: "a long ledger note that never wraps ", count: 40)) |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Harness

    private struct Harness {
        let runtime: WorkspaceRuntime
        let canvas: CanvasNSView
    }

    private static func makeHarness(root: URL, tempRoot: URL) throws -> Harness {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000CA10")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000CA11")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000CA12")!

        let project = Project(id: projectId, name: "PerfBudget", rootPath: root.path, createdAt: now, updatedAt: now,
                              defaultLaunchProfileId: "shell", editorPreference: .auto,
                              settings: ProjectSettings(restorePolicy: .restoreDescriptors,
                                                        browserStoragePolicy: .perProject,
                                                        terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 0, y: 0),
                                  size: ZoneSize(width: 4_000, height: 3_000), color: "blue",
                                  collapsed: false, hydrationPolicy: .automatic)],
            zoneZOrder: [zoneId],
            lastActiveZoneId: zoneId
        )
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.projects = [ProjectEntry(id: projectId, name: "PerfBudget", rootPath: root.path,
                                             workspaceId: workspaceId, lastOpenedAt: now,
                                             pinned: false, missing: false)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let focusBroker = FocusBroker()
        let browserEngine = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { _ in
            ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        })
        let runtime = WorkspaceRuntime(workspaceId: workspaceId, document: document, registry: zoneRegistry,
                                       focusBroker: focusBroker, registryStore: registryStore,
                                       ghostty: nil, browserEngine: browserEngine)
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        // A real window, so views have a backing scale and AppKit runs the layout
        // it would run in the app rather than short-circuiting offscreen.
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()
        return Harness(runtime: runtime, canvas: canvas)
    }
}
