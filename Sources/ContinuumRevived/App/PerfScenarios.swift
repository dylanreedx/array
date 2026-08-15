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
            // The TRANSITION between gestures, which every scenario above is
            // blind to: they each drive one pure gesture, and the complaint
            // that reframed the zoom program lived exactly at the seam ("it
            // lags when zooming when you start panning"). Four windows on one
            // fixture — pure pan, zoom→pan handoff, a pure-zoom control, and a
            // strict interleave over the SAME zoom sequence — so "a pan step
            // costs more because a zoom preceded it" is a measured difference,
            // not a feeling. The name shares no prefix with canvas.pan/zoom.
            Scenario(name: "canvas.gesture-transition", run: { try canvasGestureTransition() }),
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
                window.orderFrontRegardless()

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
            window.orderFrontRegardless()

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
        window.orderFrontRegardless()
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
    /// must cost `O(changed + visible rows)` and never `O(history)`. Today
    /// `AgentTranscriptListView.apply(document:patch:)` takes a real
    /// `AgentDocumentPatch` and then ignores its locality entirely, calling
    /// `flatten(document)` — which walks every entry, every top-level block, and
    /// recursively every child. So one revised token at the tail re-indexes the
    /// whole conversation.
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
        func fixtureBlock(_ index: Int, revision: UInt64 = 1) -> AgentBlock {
            AgentBlock(
                id: nodeID("delta-block-\(index)"), revision: revision,
                kind: AgentBlockKind(rawValue: "fixture-opaque")!,
                payload: .opaque(AgentOpaquePayload(debugLabel: "row-\(index)", value: .null))
            )
        }

        struct Sample {
            let history: Int
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
                AgentEntry(
                    id: nodeID("delta-entry-\(index)"), revision: 1, role: .assistant,
                    provenance: .localNotice(reason: "transcript delta fixture"),
                    blocks: [fixtureBlock(index)]
                )
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
            host.layoutSubtreeIfNeeded()
            list.collectionView.layoutSubtreeIfNeeded()

            guard list.qaSemanticRowCount == history else {
                throw Failure(message: "transcript-delta harness must hold \(history) rows; got \(list.qaSemanticRowCount)")
            }

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
                try list.apply(
                    document: AgentDocument(version: version, entries: entries),
                    patch: try AgentDocumentPatch(
                        fromVersion: version - 1, toVersion: version,
                        updated: [tailID, tailEntryID]
                    )
                )
                // `apply(document:patch:)` is the SYNCHRONOUS seam — the 30 Hz
                // visual scheduler sits on the enqueue path, not this one — so the
                // invalidation count below is already final for this delta.
                let invalidated = list.qaLastInvalidatedTopLevelCount
                if invalidated == 0 { deltasWithoutInvalidation += 1 }
                worstInvalidated = max(worstInvalidated, invalidated)
            }
            let seconds = ProcessInfo.processInfo.systemUptime - start

            samples.append(Sample(
                history: history,
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
        window.orderFrontRegardless()

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
        window.orderFrontRegardless()
        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()
        return Harness(runtime: runtime, canvas: canvas)
    }
}
