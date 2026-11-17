import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

/// Counts the work itself, rather than using a machine-sensitive frame time as
/// proof. Disabled outside this witness so production camera steps pay no count.
@MainActor
enum StickyHeadWorkCounters {
    static var isEnabled = false
    static var layoutRequests = 0
    static var unpinnedLayoutRequests = 0
    static var headLayouts = 0
    static var allocations = 0
    static var draws = 0
    static var textMeasurements = 0
    static var frameWrites = 0
    static var candidateVisits = 0
    static var indexVisits = 0
    static var updateDurationMS = 0.0

    static func reset() {
        layoutRequests = 0
        unpinnedLayoutRequests = 0
        headLayouts = 0
        allocations = 0
        draws = 0
        textMeasurements = 0
        frameWrites = 0
        candidateVisits = 0
        indexVisits = 0
        updateDurationMS = 0
    }
}

/// `--sticky-head-performance-check`: four pinned heads among 40, then 64
/// installed agent tiles. The other visible headers and parked tiles must not
/// acquire sticky-head work. Pan and zoom use the real camera writer, actual
/// ManagedAgentTileNSViews, the world-plane index and pumped AppKit display.
@MainActor
enum StickyHeadPerformanceChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static let steps = 30
    private static let pinnedCount = 4

    @MainActor
    private struct Sample {
        let installed: Int
        let name: String
        let pinned: Int
        let layouts: Int
        let unpinned: Int
        let actualLayouts: Int
        let allocations: Int
        let draws: Int
        let measurements: Int
        let frameWrites: Int
        let candidates: Int
        let indexVisits: Int
        let updateDurationMS: Double
        let tileLayouts: Int
        let headerInvalidations: Int
        let cameraMs: [Double]
        let displayMs: [Double]
        let flushMs: [Double]

        var report: String {
            func timing(_ values: [Double]) -> String {
                let sorted = values.sorted()
                let mean = values.reduce(0, +) / Double(max(1, values.count))
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
                return String(format: "mean %.3f / p95 %.3f ms", mean, p95)
            }
            return "  installed=\(installed) \(name), pinned=\(pinned), frames=\(StickyHeadPerformanceChecks.steps): "
                + "layoutRequests=\(layouts), unpinnedRequests=\(unpinned), headLayouts=\(actualLayouts), "
                + "allocations=\(allocations), draws=\(draws), textMeasurements=\(measurements), "
                + "frameWrites=\(frameWrites), candidates=\(candidates), indexVisits=\(indexVisits), "
                + "tileLayouts=\(tileLayouts), headerInvalidations=\(headerInvalidations); sticky update mean \(String(format: "%.3f", updateDurationMS / Double(StickyHeadPerformanceChecks.steps))) ms; "
                + "setViewport \(timing(cameraMs)); "
                + "layout/display \(timing(displayMs)); CA flush \(timing(flushMs))"
        }
    }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "sticky-head-performance requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let suite = "array.qa.sticky-head-performance.\(UUID().uuidString)"
        guard let settings = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated settings")
        }
        defer { settings.removePersistentDomain(forName: suite) }
        settings.set(true, forKey: AgentJumpConfig.composerFirstKey)
        settings.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        settings.set(true, forKey: AgentCharacterConfig.enabledKey)
        settings.set(AgentCharacterConfig.BubbleStyle.orb.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
        let characters = AgentCharacterController.shared
        characters.reduceMotion = { true }
        characters.windowIsVisible = { _ in true }
        characters.adopt(defaults: settings)
        defer { StickyHeadWorkCounters.isEnabled = false }

        var samples: [Sample] = []
        var failures: [String] = []
        var contentRedraws: [Int] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        for installed in [40, 64] {
            let canvas = CanvasNSView(
                canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 600, zoom: 0.8),
                                         tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
            canvas.agentJumpDefaults = settings
            canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            canvas.occlusionVisibilityProvider = { true }
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil); window.contentView = nil }

            let zone = UUID()
            let placement = ZonePlacement(
                zoneId: zone, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 30000, height: 30000), color: "blue", collapsed: false,
                hydrationPolicy: .automatic)
            var tiles: [Tile] = []
            var views: [ManagedAgentTileNSView] = []
            for index in 0..<installed {
                let frame: TileFrame
                if index < pinnedCount {
                    frame = TileFrame(x: 80 + Double(index) * 280, y: 0, width: 240, height: 1800)
                } else if index < 12 {
                    let visibleIndex = index - pinnedCount
                    frame = TileFrame(x: 80 + Double(visibleIndex % 4) * 280,
                                      y: 1000 + Double(visibleIndex / 4) * 240, width: 240, height: 160)
                } else {
                    let parked = index - 12
                    frame = TileFrame(x: 10000 + Double(parked % 16) * 600,
                                      y: 10000 + Double(parked / 16) * 400, width: 240, height: 160)
                }
                let tile = Tile(id: UUID(), kind: .managedAgent, title: "Sticky head agent \(index)",
                                frame: frame, zPosition: .fromLegacyRank(index + 1), zoneId: zone,
                                runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
                tiles.append(tile)
                let view = ManagedAgentTileNSView(tile: tile)
                // init rests a zero-sized body in the shared hidden host.
                // Remove it until real geometry is installed, so constructing
                // N agents does not repeatedly solve N zero-sized body trees.
                view.wakeChrome()
                view.setAgentCharacter(agentID: UUID(), snapshot: AgentCharacterSnapshot(state: .ready, allowsMotion: false))
                views.append(view)
            }
            let layer = CanvasNSView.ZoneLayer(
                placement: placement, renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Sticky perf"),
                tiles: tiles)
            for view in views { layer.tileViews[view.tile.id] = view }
            canvas.setZones([layer])
            canvas.layoutSubtreeIfNeeded()
            for view in views { _ = view.restChromeIfIdle() }

            func display() {
                canvas.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
            }
            func warm(_ viewport: CanvasViewport) {
                StickyHeadWorkCounters.isEnabled = false
                canvas.setViewport(viewport)
                for _ in 0..<3 { display() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                display()
            }

            let base = CanvasViewport(x: 0, y: 600, zoom: 0.8)
            let phases: [(String, CanvasViewport, (Int) -> CanvasViewport, Int)] = [
                ("horizontal-pan", base, { CanvasViewport(x: Double($0 + 1), y: 600, zoom: 0.8) }, pinnedCount),
                ("vertical-pan", base, { CanvasViewport(x: 0, y: 600 + Double($0 + 1), zoom: 0.8) }, pinnedCount),
                ("within-bucket-zoom", base, { CanvasViewport(x: 0, y: 600, zoom: 0.8 + Double($0 + 1) / 7500) }, pinnedCount),
                ("no-pinned-heads", CanvasViewport(x: 0, y: -1000, zoom: 0.8),
                 { CanvasViewport(x: Double($0 + 1), y: -1000, zoom: 0.8) }, 0),
            ]
            for (name, start, camera, expectedPinned) in phases {
                warm(start)
                expect(canvas.qaTotalInstalledTileCount == installed, "\(installed)/\(name): incorrect installed population")
                expect(views.allSatisfy { view in
                    guard let host = view.agentBubbleView, let bubble = view.qaAgentBubble else { return false }
                    return !bubble.isHidden && view.qaCharacterLayer?.contents != nil
                        && host.superview === view.superview && bubble.superlayer === host.layer
                }, "\(installed)/\(name): real icons/art were not installed")
                let pinned = views.filter { $0.qaStickyHead != nil }.count
                expect(pinned == expectedPinned, "\(installed)/\(name): expected \(expectedPinned) pinned heads, got \(pinned)")
                if name == "within-bucket-zoom" {
                    expect(TileNSView.chromeScaleBucket(for: camera(steps - 1).zoom) == TileNSView.chromeScaleBucket(for: start.zoom),
                           "fixture crossed a chrome scale bucket")
                }
                let tileLayoutStart = views.reduce(0) { $0 + $1.qaLayoutPassCount }
                let headerInvalidationStart = views.reduce(0) { $0 + $1.qaTitleBarRedrawCount }
                StickyHeadWorkCounters.reset()
                StickyHeadWorkCounters.isEnabled = true
                var cameraMs: [Double] = [], displayMs: [Double] = [], flushMs: [Double] = []
                for step in 0..<steps {
                    let previousDraws = StickyHeadWorkCounters.draws
                    let previousInvalidations = views.prefix(pinnedCount).reduce(0) { $0 + $1.qaTitleBarRedrawCount }
                    let pendingDraws = views.prefix(pinnedCount).map { $0.qaStickyHeadView?.needsDisplay ?? false }
                    let oldScale = views.first?.qaStickyHeadView?.layer?.contentsScale ?? 0
                    let begin = ProcessInfo.processInfo.systemUptime
                    canvas.setViewport(camera(step))
                    let cameraEnd = ProcessInfo.processInfo.systemUptime
                    canvas.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let displayEnd = ProcessInfo.processInfo.systemUptime
                    CATransaction.flush()
                    let flushEnd = ProcessInfo.processInfo.systemUptime
                    cameraMs.append((cameraEnd - begin) * 1000)
                    displayMs.append((displayEnd - cameraEnd) * 1000)
                    flushMs.append((flushEnd - displayEnd) * 1000)
                    if StickyHeadWorkCounters.draws > previousDraws {
                        let invalidations = views.prefix(pinnedCount).reduce(0) { $0 + $1.qaTitleBarRedrawCount } - previousInvalidations
                        let newScale = views.first?.qaStickyHeadView?.layer?.contentsScale ?? 0
                        print("  redraw trace: \(installed)/\(name) step=\(step), draws=\(StickyHeadWorkCounters.draws - previousDraws), headerInvalidations=\(invalidations), pendingBefore=\(pendingDraws), contentsScale=\(oldScale)→\(newScale), zoom=\(camera(step).zoom)")
                    }
                }
                StickyHeadWorkCounters.isEnabled = false
                let sample = Sample(
                    installed: installed, name: name, pinned: pinned,
                    layouts: StickyHeadWorkCounters.layoutRequests,
                    unpinned: StickyHeadWorkCounters.unpinnedLayoutRequests,
                    actualLayouts: StickyHeadWorkCounters.headLayouts,
                    allocations: StickyHeadWorkCounters.allocations,
                    draws: StickyHeadWorkCounters.draws,
                    measurements: StickyHeadWorkCounters.textMeasurements,
                    frameWrites: StickyHeadWorkCounters.frameWrites,
                    candidates: StickyHeadWorkCounters.candidateVisits,
                    indexVisits: StickyHeadWorkCounters.indexVisits,
                    updateDurationMS: StickyHeadWorkCounters.updateDurationMS,
                    tileLayouts: views.reduce(0) { $0 + $1.qaLayoutPassCount } - tileLayoutStart,
                    headerInvalidations: views.reduce(0) { $0 + $1.qaTitleBarRedrawCount } - headerInvalidationStart,
                    cameraMs: cameraMs, displayMs: displayMs, flushMs: flushMs)
                samples.append(sample)
                print(sample.report)
                fflush(stdout)
            }

            // Anti-teeth: display is live, and a content change really redraws
            // the pinned header. Zero camera redraws cannot pass by never drawing.
            warm(base)
            StickyHeadWorkCounters.reset()
            StickyHeadWorkCounters.isEnabled = true
            views[0].setTitleBarIdentity(title: "Updated sticky header content")
            display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            display()
            contentRedraws.append(StickyHeadWorkCounters.draws)
            StickyHeadWorkCounters.isEnabled = false
        }

        // Always print the evidence BEFORE any failure, so the RED run records
        // the same counters and timing columns as the GREEN run.
        let evidence = (["Sticky-head camera work (counts total over 30 frames; timing per frame; CA flush is separate compositor/commit wall time):"]
            + samples.map(\.report)
            + ["  content-change draws (40/64 installed): \(contentRedraws)"]).joined(separator: "\n")
        print(evidence)

        for sample in samples {
            let label = "\(sample.installed)/\(sample.name)"
            expect(sample.unpinned == 0, "\(label): \(sample.unpinned) sticky layout requests ran for unpinned tiles")
            expect(sample.allocations == 0, "\(label): \(sample.allocations) head views allocated after warm-up")
            expect(sample.actualLayouts == 0, "\(label): \(sample.actualLayouts) head layouts for unchanged-size camera motion")
            // Budget AppKit's observed one-off zoom redraw per head separately
            // from Array's title-bar invalidations. Bound it by HEADS, never
            // heads × frames; a per-camera-tick redraw is RED.
            // Pan must reuse the retained backing entirely.
            let rasterBudget = sample.name == "within-bucket-zoom" ? sample.pinned : 0
            expect(sample.headerInvalidations == 0,
                   "\(label): \(sample.headerInvalidations) Array header invalidations for unchanged content")
            expect(sample.draws <= rasterBudget,
                   "\(label): \(sample.draws) head redraws exceed one per zooming head (budget \(rasterBudget))")
            expect(sample.measurements <= rasterBudget,
                   "\(label): \(sample.measurements) sticky text measurements exceed bounded raster work \(rasterBudget)")
            expect(sample.layouts <= sample.pinned * steps,
                   "\(label): \(sample.layouts) sticky layout requests exceed pinned-head work \(sample.pinned * steps)")
            expect(sample.frameWrites == (sample.name == "vertical-pan" ? sample.pinned * steps : 0),
                   "\(label): unexpected frame writes \(sample.frameWrites)")
            expect(zip(sample.cameraMs, sample.displayMs).allSatisfy { $0 + $1 < 1000 },
                   "\(label): camera plus layout/display exceeded one second")
            expect(sample.candidates == sample.pinned * steps,
                   "\(label): \(sample.candidates) head candidates, expected \(sample.pinned * steps)")
            // A coarse alarm has generous headroom. The counters above have
            // the teeth; this wall-time cap only catches a newly blocking path.
            expect((sample.cameraMs.max() ?? 0) < 1000, "\(label): a camera application exceeded one second")
        }
        for name in ["horizontal-pan", "vertical-pan", "within-bucket-zoom", "no-pinned-heads"] {
            let pair = samples.filter { $0.name == name }
            if pair.count == 2 {
                expect(pair[0].candidates == pair[1].candidates, "\(name): head candidate work grew with parked tile count")
                expect(pair[0].indexVisits == pair[1].indexVisits, "\(name): index work grew with parked tile count")
            }
        }
        expect(contentRedraws.count == 2 && contentRedraws.allSatisfy { $0 > 0 },
               "content change did not redraw the pinned head: \(contentRedraws)")
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        return "Sticky-head performance: all deterministic work and scaling assertions passed."
    }
}
