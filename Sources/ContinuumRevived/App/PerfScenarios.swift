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
        for scenario in all {
            if let filter = scenarioFilter, !scenario.name.hasPrefix(filter) { continue }
            results.append(try scenario.run())
        }
        guard !results.isEmpty else {
            throw Failure(message: "no scenario matched \(scenarioFilter ?? "(none)"); known: \(all.map(\.name).joined(separator: ", "))")
        }

        print("performance budgets")
        print(PerfReport.table(results))
        print(PerfReport.summary(results))

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
        let run: () throws -> PerfScenarioResult
    }

    static var all: [Scenario] {
        [
            Scenario(name: "canvas.pan", run: { try canvasCamera(.pan) }),
            Scenario(name: "canvas.zoom", run: { try canvasCamera(.zoom) })
        ]
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
    static func canvasCamera(_ gesture: CameraGesture) throws -> PerfScenarioResult {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("continuum-perf-\(gesture.rawValue)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
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
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()

        let steps = 120
        canvas.qaResetCameraLayoutStats()
        let proseBefore = AssistantProseView.qaMeasurementCount
        let start = ProcessInfo.processInfo.systemUptime
        for step in 0..<steps {
            switch gesture {
            case .pan:
                let t = Double(step)
                canvas.setViewport(CanvasViewport(x: t * 3, y: t * 2, zoom: 1))
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
            metric: "\(gesture.rawValue).stepDuration",
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
            metric: "\(gesture.rawValue).boundsWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "a tile's logical size does not change with the camera, so re-assigning bounds is pure waste that re-marks the whole subtree for layout"
        ).evaluate(Double(stats.boundsWrites)))

        measurements.append(PerfBudget(
            metric: "\(gesture.rawValue).modelWrites",
            limit: .exactly(0),
            unit: .count,
            rationale: "nothing about a tile's model changes when the camera moves"
        ).evaluate(Double(stats.modelWrites)))

        // The document did not change and its logical width did not change, so a
        // camera move must cost no text measurement at all. This is the property
        // `--file-markdown-perf-check` asserts for a relayout, asserted here
        // through the real camera funnel instead.
        measurements.append(PerfBudget(
            metric: "\(gesture.rawValue).proseMeasurements",
            limit: .exactly(0),
            unit: .count,
            rationale: "moving the camera does not change any document's content or logical width, so no row may be re-measured"
        ).evaluate(Double(prose)))

        // Teeth in the other direction: the assertions above must not be
        // satisfiable by a canvas that quietly stopped laying anything out.
        // A zoom changes every visible tile's screen frame; a pan changes its
        // origin. Either way frames must still be written.
        measurements.append(PerfBudget(
            metric: "\(gesture.rawValue).frameWrites",
            limit: .atLeast(1),
            unit: .count,
            rationale: "teeth: the camera must still reposition tiles — a zero here means the canvas stopped working, not that it got fast"
        ).evaluate(Double(stats.frameWrites)))

        let detail = "\(steps) \(gesture.rawValue) steps over \(tileCount) tiles "
            + "(3 large Markdown documents + 9 notes), \(String(format: "%.3f", seconds))s total"
        return PerfScenarioResult(name: "canvas.\(gesture.rawValue)", detail: detail, measurements: measurements)
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
