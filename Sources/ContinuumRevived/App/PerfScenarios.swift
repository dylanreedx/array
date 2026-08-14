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
            Scenario(name: "canvas.stress", isStress: true, run: { try canvasStress() })
        ]
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

        measurements.append(PerfBudget(
            metric: "stress.frameWrites",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera must still reposition tiles"
        ).evaluate(Double(stats.frameWrites)))

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

        // Teeth in the other direction: the assertions above must not be
        // satisfiable by a canvas that quietly stopped laying anything out.
        // A zoom changes every visible tile's screen frame; a pan changes its
        // origin. Either way frames must still be written.
        measurements.append(PerfBudget(
            metric: "\(label).frameWrites",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera must still reposition tiles — a zero here means the canvas stopped working, not that it got fast"
        ).evaluate(Double(stats.frameWrites)))

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
