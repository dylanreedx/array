import AppKit
import Foundation
import ContinuumRevivedCore

/// WS3 permanent structural invariant #1: **visibility candidate visits must be
/// independent of total installed content.**
///
/// `canvas.magnify-slope` already pins the CONSEQUENCES of visibility at a zero
/// slope — chrome refreshes and tile layout passes do not grow with parked
/// tiles. What it never counted is the DISCOVERY: `CanvasNSView.visibleTileViews`
/// walked every world-plane subview and rectangle-tested it on every camera
/// commit, so a camera step still paid one frame test per installed tile. That
/// cost is invisible to a chrome counter and hides inside a machine-sensitive
/// duration slope, which is exactly the shape of witness this program has been
/// burned by.
///
/// This leg counts the visits themselves. The visible set is pinned at 12 while
/// the installed count sweeps 16 -> 128; the per-step candidate visits must not
/// move. The counter cannot be satisfied by a canvas that stopped looking:
/// three anti-teeth run alongside it — visits must be nonzero, the index's answer
/// must equal a brute-force subview walk exactly, and every visible tile must
/// still sit where `CanvasEngine` says it does.
///
/// Owned by the **Array** binary (`--canvas-visibility-index-check`).
enum CanvasVisibilityIndexChecks {
    struct CheckError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError(message: message) }
    }

    private static let installedCounts = [16, 32, 64, 128]
    private static let visibleClusterCount = 12
    private static let steps = 40

    private struct Sample {
        let installed: Int
        let onScreen: Int
        let candidateVisits: Int
        let queries: Int
        let rebuilds: Int
        let bruteForceQueries: Int
        let mismatches: Int
    }

    @MainActor
    static func run() throws -> URL {
        var samples: [Sample] = []
        var agreementChecks = 0

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
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }

            // Same corpus shape as `canvas.magnify-slope`: a fixed visible
            // cluster near the origin plus filler parked far enough out to stay
            // off-screen across the whole 0.4 - 1.0 zoom sweep.
            for index in 0..<installed {
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
                    id: UUID(), kind: .note, title: "visibility-index-\(index)",
                    frame: frame, zPosition: .fromLegacyRank(index + 1),
                    runtimeRef: nil, metadata: TileMetadata()
                )
                canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
            }
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()

            try expect(canvas.qaTotalInstalledTileCount == installed,
                       "harness must install \(installed) tiles; got \(canvas.qaTotalInstalledTileCount)")

            let onScreen = canvas.qaTilesIntersectingViewport
            canvas.qaResetVisibilityStats()
            for step in 0..<steps {
                let zoom = 0.4 + 0.6 * (1 + sin(Double(step) / 6.0)) / 2
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
            }
            let stats = canvas.qaVisibilityStats

            // ANTI-TEETH A: the index must answer EXACTLY what a full subview
            // walk answers, at the resting camera and after a tile is dragged
            // across the viewport boundary in each direction. Run outside the
            // counted sweep so it cannot inflate the numbers above.
            try expectAgreement(canvas, label: "installed \(installed), after sweep")
            agreementChecks += 1
            if let parked = canvas.qaWorldPlaneTileViews.last {
                let original = parked.frame
                parked.frame = CGRect(x: 100, y: 100, width: 340, height: 240)
                try expectAgreement(canvas, label: "installed \(installed), parked tile moved into view")
                agreementChecks += 1
                try expect(canvas.visibleTileViews.contains(where: { $0 === parked }),
                           "a tile moved into the viewport must become visible (installed \(installed))")
                parked.frame = original
                try expectAgreement(canvas, label: "installed \(installed), parked tile moved back out")
                agreementChecks += 1
                try expect(!canvas.visibleTileViews.contains(where: { $0 === parked }),
                           "a tile moved back out of the viewport must stop being visible (installed \(installed))")
            }

            // ANTI-TEETH C: sub-cell rects, where the per-candidate intersection
            // test is load-bearing. Deleting that test entirely leaves the
            // VIEWPORT answer identical — every tile sharing a cell with a
            // 1600x1000 viewport also intersects it — so the agreement checks
            // above pass a query that returns its whole cell. These rects are
            // smaller than one 1024-unit cell and sit beside cluster tiles they
            // must NOT return.
            //
            // The last two probe the SECOND cell of a tile that straddles a cell
            // boundary, and nothing else: the cluster tile at x 800-1140 crosses
            // the column-0/1 line at 1024, and the first filler at
            // (9000-9340, 7000-7240) crosses both the column-8/9 and the
            // row-6/7 lines. A grid that files a tile under its origin cell
            // alone answers these two wrong and every other probe right.
            let subCellRects = [
                CGRect(x: 0, y: 0, width: 200, height: 200),
                CGRect(x: 430, y: 70, width: 40, height: 40),
                CGRect(x: 9_050, y: 7_020, width: 80, height: 60),
                CGRect(x: 1_030, y: 70, width: 60, height: 60),
                CGRect(x: 9_250, y: 7_180, width: 60, height: 50)
            ]
            var discriminated = false
            for rect in subCellRects {
                let indexed = canvas.qaIndexedTileViews(intersecting: rect).map { ObjectIdentifier($0) }
                let brute = canvas.qaBruteForceTileViews(intersecting: rect).map { ObjectIdentifier($0) }
                try expect(indexed == brute,
                           "the visibility index disagrees with a brute-force walk over \(rect) "
                           + "(installed \(installed)): index returned \(indexed.count), the walk "
                           + "returned \(brute.count)")
                agreementChecks += 1
                // The probe only proves something if at least one rect returns
                // FEWER tiles than the cells it touches hold. Otherwise a query
                // that returns whole cells would agree with it too.
                let cellWide = CGRect(
                    x: (rect.minX / CanvasWorldPlaneView.visibilityCellSize).rounded(.down)
                        * CanvasWorldPlaneView.visibilityCellSize,
                    y: (rect.minY / CanvasWorldPlaneView.visibilityCellSize).rounded(.down)
                        * CanvasWorldPlaneView.visibilityCellSize,
                    width: CanvasWorldPlaneView.visibilityCellSize,
                    height: CanvasWorldPlaneView.visibilityCellSize)
                if !indexed.isEmpty
                    && indexed.count < canvas.qaBruteForceTileViews(intersecting: cellWide).count {
                    discriminated = true
                }
            }
            try expect(discriminated,
                       "installed \(installed): no sub-cell probe returned fewer tiles than its cell "
                       + "holds, so none of them can tell a real intersection test from one that "
                       + "returns whole cells")

            samples.append(Sample(
                installed: installed,
                onScreen: onScreen,
                candidateVisits: stats.candidateVisits,
                queries: stats.queries,
                rebuilds: stats.rebuilds,
                bruteForceQueries: stats.bruteForceQueries,
                mismatches: canvas.qaTileScreenFrameMismatchCount
            ))
        }

        // The visible count must be constant, or a flat visit count would only
        // mean the sweep never grew what it was supposed to grow.
        let onScreenCounts = Set(samples.map(\.onScreen))
        try expect(onScreenCounts.count == 1,
                   "the visible count must be held fixed across the sweep; saw \(onScreenCounts.sorted())")

        guard let smallest = samples.first, let largest = samples.last else {
            throw CheckError(message: "the sweep is missing an endpoint")
        }

        // ANTI-TEETH B: the path has to have RUN. A canvas that answers "nothing
        // is visible" scores a perfect zero slope.
        for sample in samples {
            try expect(sample.queries >= steps,
                       "installed \(sample.installed): the camera made \(sample.queries) visibility queries over \(steps) steps; it must make at least one per commit")
            try expect(sample.candidateVisits >= steps * sample.onScreen,
                       "installed \(sample.installed): \(sample.candidateVisits) candidate visits is fewer than the \(steps * sample.onScreen) the visible tiles alone require — the query is not examining what it returns")
            try expect(sample.bruteForceQueries == 0,
                       "installed \(sample.installed): \(sample.bruteForceQueries) of \(sample.queries) queries took the zoomed-far-out fallback; this corpus must stay inside the indexed regime or the slope proves nothing")
            try expect(sample.mismatches == 0,
                       "installed \(sample.installed): \(sample.mismatches) tiles are not where the camera says they are")
        }

        // THE TEETH. Per-step candidate visits at 128 installed must equal those
        // at 16 installed, because the 116 extra tiles are all off-screen.
        let visitSlope = Double(largest.candidateVisits - smallest.candidateVisits) / Double(steps)
        try expect(visitSlope == 0,
                   "visibility discovery still grows with installed content: \(smallest.candidateVisits) visits at \(smallest.installed) installed vs \(largest.candidateVisits) at \(largest.installed), a slope of \(visitSlope) extra tile tests per camera step per \(largest.installed - smallest.installed) parked tiles")

        // A camera step must not dirty the index: tile frames are WORLD frames
        // and the camera lives in the plane's bounds. One lazy rebuild for the
        // whole sweep is the budget; per-step rebuilds would put the O(installed)
        // walk straight back on the hot path under a different name.
        for sample in samples {
            try expect(sample.rebuilds <= 1,
                       "installed \(sample.installed): the visibility index was rebuilt \(sample.rebuilds) times across \(steps) camera steps; a camera step changes no tile frame, so it must not invalidate the index")
        }

        let manifest: [String: Any] = [
            "check": "canvas-visibility-index",
            "steps": steps,
            "visibleClusterCount": visibleClusterCount,
            "agreementChecks": agreementChecks,
            "candidateVisitSlopePerStep": visitSlope,
            "samples": samples.map { sample in
                [
                    "installed": sample.installed,
                    "onScreen": sample.onScreen,
                    "candidateVisits": sample.candidateVisits,
                    "candidateVisitsPerStep": Double(sample.candidateVisits) / Double(steps),
                    "queries": sample.queries,
                    "indexRebuilds": sample.rebuilds,
                    "bruteForceQueries": sample.bruteForceQueries,
                    "screenFrameMismatches": sample.mismatches
                ]
            }
        ]
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("canvas-visibility-index-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        return artifact
    }

    @MainActor
    private static func expectAgreement(_ canvas: CanvasNSView, label: String) throws {
        let indexed = canvas.visibleTileViews.map { ObjectIdentifier($0) }
        let brute = canvas.qaBruteForceVisibleTileViews.map { ObjectIdentifier($0) }
        try expect(indexed == brute,
                   "the visibility index disagrees with a brute-force subview walk (\(label)): index returned \(indexed.count) tiles, the walk returned \(brute.count)")
    }
}
