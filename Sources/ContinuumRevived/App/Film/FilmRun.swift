// Film harness: the two entry points.
//
//  - `--film <scene.json> --film-out <dir>`: NOT a check (precedent `--workspace-api-demo`).
//    `main()` stages the scene before boot; the real launch path mounts it; this runs
//    the director after boot and captures every take, then exits. Driven by
//    `scripts/film-capture.sh`, never typed by hand.
//  - `--film-scene-check`: the witness. For EVERY scene in film/scenes/<video>/ (a scene
//    is committed by existing; the v2 verbs are checked by FilmRunV2Checks.swift on any
//    scene that uses them) it stages the scene into temp roots, boots it through `mountWorkspaceSceneAtBoot` on
//    an off-display window, runs every take with no capture, and asserts staging, camera,
//    pointer and timeline outcomes, after offline assertions on the pointer math and on
//    action decoding/validation.
//
// Output contract of `--film`: per take `<take>/frames.json` (schema
// `array.film.frames.v2`, fields documented at the top of FilmCapture.swift), the movie,
// the PNG sequence, and `run.json` (`array.film.run.v1`) for the run.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

extension AppDelegate {
    /// Post-boot half of `--film`. The window is already parked (see `FilmDirector.parkWindow`).
    func runFilm(window: NSWindow) {
        let outPath = FilmScene.requestedOutput ?? ""
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let logURL = out.appendingPathComponent("log.txt")
        let log: (String) -> Void = { line in
            FileHandle.standardError.write(Data("[film] \(line)\n".utf8))
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
            } else {
                try? Data((line + "\n").utf8).write(to: logURL)
            }
        }
        Task { @MainActor in
            do {
                guard !outPath.isEmpty, let path = FilmScene.requestedPath else { throw FilmError("--film needs --film-out <dir>") }
                let scene = try FilmScene.load(URL(fileURLWithPath: path))
                let roots = try FilmStager.liveRoots(for: scene)
                guard let canvas = filmCanvas else { throw FilmError("no canvas after boot") }
                // Let the mount finish its own async work before staging on top of it.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let director = FilmDirector(scene: scene, delegate: self, window: window, canvas: canvas, roots: roots, log: log)
                try await director.prepare()
                log("staged: \(director.agents.count) agents; window \(window.frame), content \(window.contentLayoutRect), "
                    + "canvas \(canvas.bounds.size), sidebar \(self.filmSidebar.map { "\($0.convert($0.bounds, to: nil))" } ?? "hidden")")
                var current: FilmCapture?
                var verdicts: [[String: Any]] = []
                // Full, or proto (1x, 30 fps, JPEG, no movie, optionally a frame range).
                let mode = try FilmCaptureMode.fromEnvironment(sceneFps: scene.framesPerSecond)
                // `ARRAY_FILM_TAKES=a,b` captures only those takes; the others still
                // run, uncaptured, so the state each captured take starts from is real.
                let only = ProcessInfo.processInfo.environment["ARRAY_FILM_TAKES"]?
                    .split(separator: ",").map(String.init)
                let capturedTakes = scene.takes.filter { take in
                    take.capture ?? true && only.map({ $0.contains(take.name) }) ?? true
                        && !mode.capturedFrames(of: take).isEmpty
                }
                log("capture: \(mode.proto ? "proto (1x, \(scene.framesPerSecond / mode.stride) fps, JPEG, no movie)" : "full")"
                    + (mode.range.map { ", frames \($0.lowerBound)-\($0.upperBound)" } ?? "")
                    + ", takes \(capturedTakes.map(\.name))")
                struct RangeComplete: Error {}
                do {
                    try await director.run { take, takeIndex, record in
                        guard capturedTakes.contains(where: { $0.name == take.name }), mode.captures(record.index),
                              let last = mode.capturedFrames(of: take).last else { return }
                        if current == nil {
                            let capture = FilmCapture(
                                window: window, directory: out.appendingPathComponent(take.name), take: take, sceneId: scene.id,
                                fps: scene.framesPerSecond, png: scene.png ?? .all, video: scene.video ?? "prores", mode: mode)
                            try await capture.prepare()
                            for action in take.actions where action.at < take.frames {
                                if let mark = action.mark { capture.mark(mark, frame: action.at) }
                            }
                            current = capture
                        }
                        guard let capture = current else { return }
                        let isLast = record.index == last
                        try await capture.capture(record, isLast: isLast)
                        if isLast {
                            let verdict = try await capture.finish(extra: ["takeIndex": takeIndex])
                            log("take \(take.name): \(mode.capturedFrames(of: take).count) frames -> \(verdict)")
                            verdicts.append(["take": take.name, "frames": mode.capturedFrames(of: take).count, "verdict": verdict,
                                             "dir": out.appendingPathComponent(take.name).path])
                            current = nil
                            // A range has nothing after its last frame worth stepping.
                            if mode.range != nil, take.name == capturedTakes.last?.name { throw RangeComplete() }
                        }
                    }
                } catch is RangeComplete {
                    log("capture: frame range done, stopping the run")
                }
                director.finish()
                let pass = !verdicts.isEmpty && verdicts.allSatisfy { ($0["verdict"] as? String) == "PASS" }
                let summary: [String: Any] = [
                    "schema": "array.film.run.v1", "scene": scene.id, "verdict": pass ? "PASS" : "FAIL",
                    "takes": verdicts, "firedActions": director.firedActions.count,
                    "bundleId": Bundle.main.bundleIdentifier ?? "", "bundlePath": Bundle.main.bundlePath,
                ]
                try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                    .write(to: out.appendingPathComponent("run.json"), options: .atomic)
                log("\(pass ? "PASS" : "FAIL"): \(verdicts.count) take(s) -> \(out.path)")
                Foundation.exit(pass ? 0 : 1)
            } catch {
                log("FAIL: \(error)")
                let summary: [String: Any] = ["schema": "array.film.run.v1", "verdict": "FAIL", "error": "\(error)"]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
                    try? data.write(to: out.appendingPathComponent("run.json"), options: .atomic)
                }
                Foundation.exit(1)
            }
        }
    }
}

@MainActor
enum FilmSceneCheck {
    /// Every scene: each `film/scenes/<video>/*.json`, sorted. A new scene is checked
    /// the day it lands, with no list to keep in step.
    static func committedScenes() -> [URL] {
        let fm = FileManager.default
        let videos = (try? fm.contentsOfDirectory(at: committedSceneURL("film/scenes"), includingPropertiesForKeys: nil)) ?? []
        return videos.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
    }

    /// The scene under check: `ARRAY_FILM_SCENE`, else the first committed scene.
    static func sceneURL() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["ARRAY_FILM_SCENE"] { return URL(fileURLWithPath: explicit) }
        return committedScenes()[0]
    }

    /// A committed scene from the working directory or from this source file's checkout.
    static func committedSceneURL(_ relative: String) -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
    }

    /// Every committed scene (or just `ARRAY_FILM_SCENE`), each in its own isolated child.
    /// Every scene runs, whatever an earlier one did, and the summary names each verdict.
    static func runIsolated() -> Int32 {
        let scenes = ProcessInfo.processInfo.environment["ARRAY_FILM_SCENE"].map { [URL(fileURLWithPath: $0)] }
            ?? committedScenes()
        guard !scenes.isEmpty else {
            fputs("FAIL: --film-scene-check found no scene under film/scenes/<video>/\n", stderr)
            return 1
        }
        var failed: [String] = []
        for scene in scenes {
            let name = scene.deletingLastPathComponent().lastPathComponent + "/" + scene.lastPathComponent
            let started = Date()
            let status = runIsolated(scene: scene)
            print("film-scene-check \(status == 0 ? "PASS" : "FAIL") \(name) (\(Int(Date().timeIntervalSince(started)))s)")
            if status != 0 { failed.append(name) }
        }
        if !failed.isEmpty {
            fputs("FAIL: --film-scene-check: \(failed.count) of \(scenes.count) scene(s) failed: \(failed.joined(separator: ", "))\n", stderr)
            return 1
        }
        print("FilmSceneChecks passed: all \(scenes.count) scenes")
        return 0
    }

    /// Re-executes this binary with `CONTINUUM_APP_SUPPORT` pointing into a temp root:
    /// the director spawns real agent records, and without the override `AgentStore`
    /// would write them into the dev channel's real store.
    static func runIsolated(scene: URL) -> Int32 {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-film-scene-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if !FileManager.default.isExecutableFile(atPath: process.executableURL!.path) {
            process.executableURL = Bundle.main.executableURL
        }
        process.arguments = ["--film-scene-check"]
        var environment = ProcessInfo.processInfo.environment
        environment["CONTINUUM_APP_SUPPORT"] = temp.appendingPathComponent("app-support").path
        environment["ARRAY_FILM_CHECK_ROOT"] = temp.path
        environment["ARRAY_FILM_SCENE"] = scene.path
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("FAIL: --film-scene-check could not re-exec: \(error)\n", stderr)
            return 1
        }
    }

    static func run() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["ARRAY_FILM_CHECK_ROOT"], let support = environment["CONTINUUM_APP_SUPPORT"],
              support.hasPrefix(rootPath) else { throw FilmError("run through runIsolated()") }
        let scene = try FilmScene.load(sceneURL())
        // 0) Offline: the pointer math and action decoding, before anything boots.
        let offline = offlineAssertions(scene: scene)
        if !offline.failures.isEmpty { throw FilmError("offline:\n  " + offline.failures.joined(separator: "\n  ")) }
        let base = URL(fileURLWithPath: rootPath, isDirectory: true)
        var projects: [String: URL] = [:]
        for project in scene.projects { projects[project.key] = base.appendingPathComponent("projects/\(project.name)", isDirectory: true) }
        let roots = FilmStager.Roots(projects: projects, appSupport: URL(fileURLWithPath: support, isDirectory: true))
        try FilmStager.stage(scene, roots: roots)
        scene.catalogSnapshots.forEach(AgentModelCatalog.shared.resetForQA(snapshot:))

        // Boot exactly as `applicationDidFinishLaunching` does for a persisted
        // workspace, then hand the canvas to the production mount.
        let registryStore = RegistryStore(applicationSupportDirectory: roots.appSupport)
        let registry = try registryStore.loadOrEmpty()
        let document = try WorkspaceStore(workspaceId: scene.workspaceId, applicationSupportDirectory: roots.appSupport).load()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            guard let entry = registry.projects.first(where: { $0.id == projectId }) else {
                throw FilmError("unexpected project \(projectId)")
            }
            let root = URL(fileURLWithPath: entry.rootPath, isDirectory: true)
            let store = ProjectStore(projectRoot: root)
            return ZoneRuntimeController(projectRoot: root, projectStore: store, project: try store.loadProject())
        })
        let bootProjectId = scene.projectId(scene.projects[0].key)
        let bootController = try zoneRegistry.acquire(projectId: bootProjectId)
        let bootStore = bootController.projectStore
        let bootCanvasState = try bootStore.loadCanvas()
        let renderModels = document.zones.map { CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name) }
        let canvas = CanvasNSView(canvasState: bootCanvasState,
                                  activeZone: document.zones.first(where: { $0.projectId == bootProjectId }),
                                  zoneRenderModels: renderModels)
        let size = NSSize(width: scene.window.width, height: scene.window.height)
        // A scene that drives keys or hover gets a window that can be key (tracking areas
        // and the leader read key-ness; the app is still never activated).
        let window: NSWindow = scene.drivesRealInput
            ? FilmCheckWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A scene with the sidebar gets the production arrangement: the real
        // `WorkspaceSidebarView` at the left, a 1 pt divider, the canvas filling the rest.
        var sidebarView: WorkspaceSidebarView?
        if scene.showsSidebar {
            let width = CGFloat(scene.resolvedSidebarWidth)
            let content = NSView(frame: CGRect(origin: .zero, size: size))
            let sidebar = WorkspaceSidebarView(frame: CGRect(x: 0, y: 0, width: width, height: size.height))
            canvas.frame = CGRect(x: width + 1, y: 0, width: size.width - width - 1, height: size.height)
            content.addSubview(sidebar)
            content.addSubview(canvas)
            window.contentView = content
            sidebarView = sidebar
        } else {
            canvas.frame = CGRect(origin: .zero, size: size)
            window.contentView = canvas
        }
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let delegate = AppDelegate()
        // The app's main window, as `applicationDidFinishLaunching` sets it: the ⌘K
        // palette and other window-hosted surfaces present into it, and without it
        // ⌘K was a silent no-op here (full-day, full-day-v2, v2-smoke-day).
        delegate.filmAdoptWindowForCheck(window)
        // The canvas's production callbacks (zone create/scope picker, move, rename, close),
        // wired before the mount exactly as `applicationDidFinishLaunching` wires them.
        delegate.wireCanvasCallbacks(canvas)
        let runtime = WorkspaceRuntime(boot: bootController, workspaceId: scene.workspaceId, document: document,
                                       registry: zoneRegistry, focusBroker: delegate.qaFocusBroker,
                                       registryStore: registryStore, ghostty: nil, browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
                                  projectStore: bootStore, project: bootController.project)
        // === The production seam. NOT `install(into:)`. ===
        // The app's own local event monitors (⌘K, ⌘,, the ⌥ leader, tile focus, canvas
        // gestures) for a scene that drives keys: process-local, as at launch.
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: bootStore,
                                               canvasState: bootCanvasState, installsGlobalEventMonitors: scene.drivesRealInput)
        canvas.layoutSubtreeIfNeeded()
        defer { delegate.qaAgentSupervisor.stopAll() }
        if let sidebarView { try delegate.filmAdoptSidebarForCheck(sidebarView) }

        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }
        func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.5) -> Bool { abs(a - b) <= tolerance }
        func same(_ a: TileFrame?, _ b: TileFrame) -> Bool {
            guard let a else { return false }
            return near(a.x, b.x) && near(a.y, b.y) && near(a.width, b.width) && near(a.height, b.height)
        }

        // 1) Staging: every staged tile hydrated at exactly the scene's world frame.
        var stagedChecked = 0
        for spec in scene.tiles where spec.kind != "agent" {
            let actual = canvas.navigationTileSnapshot(for: scene.tileId(spec.key))?.worldFrame
            expect(same(actual, scene.worldFrame(of: spec)),
                   "staged \(spec.kind) \(spec.key): world frame \(String(describing: actual)) != scene \(scene.worldFrame(of: spec))")
            stagedChecked += 1
        }

        let director = FilmDirector(scene: scene, delegate: delegate, window: window, canvas: canvas, roots: roots,
                                    log: { FileHandle.standardError.write(Data("[film-check] \($0)\n".utf8)) })
        // The user's own sound settings, before anything the film's Settings panel does.
        let standardSoundSettings = soundSettingsSnapshot(UserDefaults.standard)
        try await director.prepare(spawnTimeout: 0.5, settle: 0.2)

        // 2) Post-boot agents: spawned into their zone and framed exactly.
        for spec in scene.tiles where spec.kind == "agent" {
            guard let handle = director.agents[spec.key] else { failures.append("agent \(spec.key) was not spawned"); continue }
            expect(same(director.worldFrame(of: handle.tileId), scene.worldFrame(of: spec)),
                   "agent \(spec.key): world frame \(String(describing: director.worldFrame(of: handle.tileId))) != scene \(scene.worldFrame(of: spec))")
            expect(canvas.navigationTileSnapshot(for: handle.tileId)?.zoneId == handle.zoneId,
                   "agent \(spec.key): not installed in its scene zone")
        }

        // 2b) Every staged zone is still exactly its staged rect once the agents are in:
        //     spawning one must not grow (or shift) the zone it lands in.
        for zone in scene.zones {
            let live = director.zoneWorldRect(zone.key), staged = scene.zoneRect(zone.key)
            expect(live != nil && staged != nil && near(Double(live!.minX), Double(staged!.minX)) && near(Double(live!.minY), Double(staged!.minY))
                   && near(Double(live!.width), Double(staged!.width)) && near(Double(live!.height), Double(staged!.height)),
                   "zone \(zone.key): live \(live.map { "\($0)" } ?? "nil") after staging, scene \(staged.map { "\($0)" } ?? "nil")")
        }

        // 3) The timeline, frame by frame, no capture. Camera endpoints are analytic:
        //    CanvasEngine.fit of the scene's own rects; the path must be monotone in
        //    log-zoom and free of jumps.
        var viewports: [Int: [CanvasViewport]] = [:]
        var records: [Int: [FilmDirector.FrameRecord]] = [:]
        var clockErrors = 0
        zoneHistory = [:]
        try await director.run { _, takeIndex, record in
            // Every zone's and tile's LIVE world rect as this frame left it, the geometry
            // the director frames: a camera move is judged against the canvas as it stood
            // then, not as staged (auto layout grows a zone a spawn lands in) and not
            // after later spawns grew it.
            var live: [String: CGRect] = [:]
            for key in scene.zones.map(\.key) + Array(director.adoptedZones.keys) { live[key] = director.zoneWorldRect(key) }
            for key in scene.tiles.map(\.key) + Array(director.agents.keys) + Array(director.adoptedTiles.keys) {
                if let f = director.worldFrame(of: director.tileId(forKey: key)) {
                    live["tile:" + key] = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
                }
            }
            zoneHistory[takeIndex, default: []].append(live)
            viewports[takeIndex, default: []].append(record.viewport)
            records[takeIndex, default: []].append(record)
            if let filmTime = director.coreAnimationFilmTime, !near(filmTime, record.time, 1e-6) { clockErrors += 1 }
        }
        expect(clockErrors == 0, "Core Animation clock drifted from film time on \(clockErrors) frame(s)")
        let opened = director.reportedOpenRects
        var camerasChecked = 0
        var v2ZoomsChecked = 0
        for (takeIndex, take) in scene.takes.enumerated() {
            let frames = viewports[takeIndex] ?? []
            for action in take.actions {
                guard let target = action.camera ?? action.zoom?.to,
                      let expected = analyticViewport(target, scene: scene, size: canvas.bounds.size, opened: opened,
                                                      drawn: drawnZones(scene: scene, director: director, takeIndex: takeIndex, at: action.at)) else { continue }
                let curve = scene.cameraCurve(for: action)
                // cameraModel v2: a zoom splits centre and zoom (FilmCameraMath); a
                // camera move keeps the similarity path, on v2's default curve.
                let staggered = scene.isCameraV2 && action.zoom != nil
                if target.all != true, let floor = scene.closeUpMinZoom {
                    let framed = analyticRect(target, scene: scene, opened: opened,
                                              drawn: drawnZones(scene: scene, director: director, takeIndex: takeIndex, at: action.at))
                    expect(expected.zoom >= floor,
                           "take \(take.name) camera at \(action.at): a close-up at zoom \(expected.zoom) is below \(floor) "
                           + "(it frames \(framed.map { "\($0)" } ?? "nothing"))")
                }
                let end = action.at + action.duration
                guard end < frames.count else { failures.append("take \(take.name): camera move ends after the take"); continue }
                let actual = frames[end]
                expect(near(actual.x, expected.x, 0.01) && near(actual.y, expected.y, 0.01) && near(actual.zoom, expected.zoom, 1e-6),
                       "take \(take.name) frame \(end): viewport \(actual) != analytic \(expected)")
                if action.duration > 1, action.at > 0 || takeIndex > 0 {
                    let path = Array(frames[max(action.at - 1, 0)...end])
                    let zooms = path.map { log($0.zoom) }
                    let rising = (zooms.last ?? 0) >= (zooms.first ?? 0)
                    let monotone = zip(zooms, zooms.dropFirst()).allSatisfy { rising ? $1 >= $0 - 1e-9 : $1 <= $0 + 1e-9 }
                    // An underdamped spring overshoots by design; its path is checked
                    // against the curve itself below instead.
                    expect(!curve.isMonotone || monotone, "take \(take.name) camera at \(action.at): log-zoom is not monotone")
                    // The path IS the declared curve: every frame is interpolate(v0, v1, e(p)).
                    let v0 = path[0]
                    let seconds = Double(action.duration) / Double(scene.framesPerSecond)
                    for local in 0...action.duration {
                        let p = Double(local) / Double(action.duration)
                        let want = staggered
                            ? FilmCameraMath.interpolate(v0, expected, p: p, curve: curve, duration: seconds, size: canvas.bounds.size)
                            : FilmDirector.interpolate(v0, expected, curve.value(p, duration: seconds), size: canvas.bounds.size)
                        let got = frames[action.at + local]
                        if !(near(got.x, want.x, 1e-6) && near(got.y, want.y, 1e-6) && near(got.zoom, want.zoom, 1e-9)) {
                            failures.append("take \(take.name) camera at \(action.at)+\(local): \(got) is not the curve's \(want)"); break
                        }
                    }
                    // No frame may move faster than the easing curve's own peak
                    // slope allows (with headroom): a snap or a restarted move would.
                    let total = abs((zooms.last ?? 0) - (zooms.first ?? 0))
                    let largest = zip(zooms, zooms.dropFirst()).map { abs($1 - $0) }.max() ?? 0
                    // A staggered zoom spends only `span` of the move zooming, so its
                    // steepest frame is 1/span steeper.
                    let span = staggered ? FilmCameraMath.span(v0, expected) : 1
                    let peakSlope = curve.peakSlope(duration: seconds * span) / span
                    expect(total < 1e-6 || largest <= 1.25 * peakSlope * total / Double(action.duration),
                           "take \(take.name) camera at \(action.at): a \(largest) log-zoom step in a \(total) move of \(action.duration) frames is a jump")
                    if staggered, let rect = analyticRect(target, scene: scene, opened: opened,
                                                          drawn: drawnZones(scene: scene, director: director, takeIndex: takeIndex, at: action.at)) {
                        // Pivot on the target: its centre's distance from the canvas centre
                        // only ever shrinks (no streaming toward a corner) and ends at zero.
                        let centre = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
                        let world = CGPoint(x: rect.midX, y: rect.midY)
                        let distances = frames[action.at...end].map { v -> Double in
                            let screen = CanvasEngine.worldToScreen(world, viewport: v)
                            return hypot(Double(screen.x - centre.x), Double(screen.y - centre.y))
                        }
                        let approaches = zip(distances, distances.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }
                        expect(approaches, "take \(take.name) zoom at \(action.at): the target's centre moves away from the canvas centre (\(distances.map { Int($0) }.prefix(12)))")
                        expect((distances.last ?? 1) < 0.01, "take \(take.name) zoom at \(action.at): the target's centre ends \(distances.last ?? -1) pt from the canvas centre")
                        v2ZoomsChecked += 1
                    }
                }
                camerasChecked += 1
            }
        }

        // 3b) The pointer track and the geometry log.
        let pointerReport = pointerAssertions(scene: scene, director: director, canvas: canvas, records: records,
                                              failures: &failures)
        // 3c) The sidebar: on screen, rows measured, elapsed on the film clock, reveals.
        let sidebarReport = scene.showsSidebar
            ? try await sidebarAssertions(scene: scene, director: director, delegate: delegate, canvas: canvas,
                                          records: records, failures: &failures)
            : "no sidebar"

        // 3d) Opens: production opened the file AS the agent and placed it beside it, and
        //     the agent's own transcript row says so.
        let openReport = try await openAssertions(scene: scene, director: director, delegate: delegate, canvas: canvas,
                                                  roots: roots, records: records, failures: &failures)

        // 3e) The v2 surfaces: hover card, navigation glides, Settings and its sounds,
        //     unseen Done, the close nudge, follow-ups, the bulk bar, every zone.
        let v2Report = v2Assertions(scene: scene, director: director, delegate: delegate, canvas: canvas, records: records,
                                    standardSoundSettings: standardSoundSettings, failures: &failures)

        // 4) Every action fired, and the end state the scene declares holds.
        let totalActions = scene.takes.reduce(0) { $0 + $1.actions.count }
        expect(director.firedActions.count == totalActions, "fired \(director.firedActions.count) of \(totalActions) actions")
        for (cardKey, columnName) in scene.expect?.cards ?? [:] {
            let board = boardView(for: cardKey, scene: scene, canvas: canvas)
            let card = board?.board.card(scene.uuid("card", cardKey))
            let column = card.flatMap { board?.board.column($0.columnId)?.name }
            expect(column == columnName, "card \(cardKey) is in \(column ?? "nothing"), expected \(columnName)")
        }
        for (cardKey, agentKey) in scene.expect?.assignees ?? [:] {
            let card = boardView(for: cardKey, scene: scene, canvas: canvas)?.board.card(scene.uuid("card", cardKey))
            expect(card?.assignee != nil && card?.assignee == director.agents[agentKey]?.agentId,
                   "card \(cardKey) is assigned to \(String(describing: card?.assignee)), expected agent \(agentKey)")
        }
        // An AgentStatus raw value, or "completed": the awareness signal a finished
        // turn raises while nobody is looking (the green ring), which is what a
        // completed agent shows — its tile state itself returns to idle.
        for (agentKey, status) in scene.expect?.agentStatus ?? [:] {
            let actual: String?
            if status == "completed" {
                actual = director.agents[agentKey].flatMap { delegate.filmAwarenessKind(tileId: $0.tileId) }
            } else {
                actual = director.agentView(agentKey)?.currentAgentStatus.rawValue
            }
            expect(actual == status, "agent \(agentKey) status \(actual ?? "nil"), expected \(status)")
        }
        var transcriptCards = 0
        for key in director.agents.keys { transcriptCards += director.agentView(key)?.transcriptCardCount ?? 0 }
        expect(transcriptCards > 0, "no transcript content reached any agent tile")
        director.finish()

        if !failures.isEmpty { throw FilmError(failures.joined(separator: "\n  ")) }
        return "\(stagedChecked) staged tiles and \(director.agents.count) agents at their scene world frames; "
            + "\(scene.takes.reduce(0) { $0 + $1.frames }) frames over \(scene.takes.count) takes on the film clock; "
            + "\(camerasChecked) camera moves landed on CanvasEngine.fit and stayed monotone and jump-free"
            + (scene.isCameraV2 ? " (cameraModel v2: \(v2ZoomsChecked) zooms pivoted on their target and ended it dead centre)" : "") + "; "
            + "\(totalActions) actions fired; end state \(scene.expect.map { "\($0.cards?.count ?? 0) cards, \($0.assignees?.count ?? 0) assignees, \($0.agentStatus?.count ?? 0) statuses" } ?? "none") held; "
            + "\(transcriptCards) transcript cards; \(offline.summary); \(pointerReport); \(sidebarReport); \(openReport); \(v2Report)"
    }

    // MARK: Offline assertions

    static func offlineAssertions(scene: FilmScene) -> (failures: [String], summary: String) {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

        // The spring is the overlay's TS, number for number (reference values computed
        // from the TS formula in double precision).
        let references: [(FilmSpring, String, Double, Double)] = [
            (.snappy, "snappy", 1.0228421998533768, 1.0017435123451353),
            (.soft, "soft", 0.6662528601055924, 0.9614636037125517),
            (.glide, "glide", 0.465583948701782, 0.8323462377208007),
        ]
        for (spring, name, at025, norm05) in references {
            expect(FilmSpring.named(name) == spring, "spring preset \(name)")
            expect(near(spring.at(0.25), at025, 1e-12), "spring \(name): springAt(0.25) = \(spring.at(0.25)), TS says \(at025)")
            expect(near(spring.normalized(0.5, duration: 1), norm05, 1e-12), "spring \(name): e(0.5) over 1 s = \(spring.normalized(0.5, duration: 1)), TS says \(norm05)")
            for duration in [0.2, 0.4, 1.0, 1.7] {
                expect(spring.normalized(0, duration: duration) == 0 && spring.normalized(1, duration: duration) == 1
                       && spring.normalized(1.3, duration: duration) == 1, "spring \(name) does not land exactly at \(duration) s")
                expect(near(spring.normalized(0.9999, duration: duration), 1, 1e-3), "spring \(name) jumps at its end over \(duration) s")
            }
        }
        expect(FilmCurve.named("aim") == .bezier(.inOut) && FilmCurve.pointer(spring: nil, ease: nil) == .bezier(.inOut)
               && FilmEase.inOut.p1 == (0.65, 0) && FilmEase.inOut.p2 == (0.35, 1), "the pointer default is not aim = cubic-bezier(0.65, 0, 0.35, 1)")
        expect(FilmCurve.pointer(spring: "soft", ease: "aim") == .spring(.soft), "a pointer spring must win over its ease")
        expect(FilmCurve.named("spring:wobbly") == nil && FilmCurve.named("bounce") == nil, "unknown curves must not resolve")

        // Momentum: front-loaded, monotone, exact ends.
        expect(FilmPointerMath.momentum(0) == 0 && FilmPointerMath.momentum(1) == 1, "momentum ends")
        expect(near(FilmPointerMath.momentum(0.2), (1 - exp(-1)) / (1 - exp(-5)), 1e-12), "momentum formula")
        expect((0..<100).allSatisfy { FilmPointerMath.momentum(Double($0 + 1) / 100) > FilmPointerMath.momentum(Double($0) / 100) }, "momentum is not monotone")

        // Arc: exact endpoints, bow of arc*dist at the middle, to the left of travel.
        let a = CGPoint(x: 100, y: 300), b = CGPoint(x: 500, y: 300)
        let mid = FilmPointerMath.path(from: a, to: b, e: 0.5, arc: 0.08)
        expect(FilmPointerMath.path(from: a, to: b, e: 0, arc: 0.08) == a && FilmPointerMath.path(from: a, to: b, e: 1, arc: 0.08) == b,
               "arc moves an endpoint")
        expect(near(Double(mid.x), 300, 1e-9) && near(Double(mid.y), 300 - 0.08 * 400, 1e-9), "arc bow at e=0.5 is \(mid), want (300, 268)")

        // Pinch fixed point: the world point under it never moves through interpolate.
        let size = CGSize(width: 1440, height: 778)
        let pairs: [(CanvasViewport, CanvasViewport)] = [
            (CanvasViewport(x: -278, y: -557, zoom: 0.2157), CanvasViewport(x: -4.7, y: -5.1, zoom: 0.894)),
            (CanvasViewport(x: 1025, y: 717, zoom: 0.894), CanvasViewport(x: -278, y: -557, zoom: 0.2157)),
            (CanvasViewport(x: 300, y: -120, zoom: 1.6), CanvasViewport(x: 2400, y: 900, zoom: 0.5)),
        ]
        var fixedChecked = 0
        for (v0, v1) in pairs {
            guard let fixed = FilmPointerMath.fixedPoint(v0, v1) else { failures.append("no fixed point for \(v0) -> \(v1)"); continue }
            let anchor = CanvasEngine.screenToWorld(fixed, viewport: v0)
            let landed = CanvasEngine.screenToWorld(fixed, viewport: v1)
            expect(near(Double(anchor.x), Double(landed.x), 1e-6) && near(Double(anchor.y), Double(landed.y), 1e-6),
                   "fixed point \(fixed) is not shared by \(v0) and \(v1)")
            for step in 1..<20 {
                let v = FilmDirector.interpolate(v0, v1, Double(step) / 20, size: size)
                let world = CanvasEngine.screenToWorld(fixed, viewport: v)
                if !(near(Double(world.x), Double(anchor.x), 1e-6) && near(Double(world.y), Double(anchor.y), 1e-6)) {
                    failures.append("interpolate drifts off the fixed point at e=\(Double(step) / 20): \(world) != \(anchor)"); break
                }
            }
            fixedChecked += 1
        }
        expect(FilmPointerMath.fixedPoint(CanvasViewport(x: 0, y: 0, zoom: 1), CanvasViewport(x: 50, y: 0, zoom: 1)) == nil,
               "a pure pan must have no fixed point")

        // Hand-grab pan: the grabbed world point stays under the pointer.
        let v0 = CanvasViewport(x: -4.7, y: -5.1, zoom: 0.894)
        let v1 = FilmPointerMath.panViewport(from: v0, centering: CGRect(x: 900, y: 80, width: 1520, height: 700), size: size)
        expect(v1.zoom == v0.zoom && near(v1.x + 720 / v1.zoom, 1660, 1e-9) && near(v1.y + 389 / v1.zoom, 430, 1e-9), "pan viewport does not centre its target")
        let grab = CGPoint(x: 1100, y: 400)
        let grabbedWorld = CanvasEngine.screenToWorld(grab, viewport: v0)
        for step in 0...10 {
            let v = FilmDirector.interpolate(v0, v1, Double(step) / 10, size: size)
            let world = CanvasEngine.screenToWorld(FilmPointerMath.grabbedPointer(start: grab, from: v0, to: v), viewport: v)
            if !(near(Double(world.x), Double(grabbedWorld.x), 1e-9) && near(Double(world.y), Double(grabbedWorld.y), 1e-9)) {
                failures.append("hand pan lets go of its world point at step \(step)"); break
            }
        }

        // cameraModel v2 (FilmCameraMath): curves, the staggered zoom, the speed guard.
        let v2Report = cameraV2Offline(scene: scene, size: size, failures: &failures)

        // Decoding and validation: the director must never be handed half an action.
        // The fixtures name board-story's keys (fix, board, site, jump, canvas); a scene
        // without them is decoded against v2-smoke, which has them and the sidebar.
        let decodeScene = scene.tile("fix") != nil ? scene
            : ((try? FilmScene.load(committedSceneURL("film/scenes/v2-smoke/v2-smoke.json"))) ?? scene)
        var accepted = [
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix","at":"header"},"spring":"soft","arc":0.1}}"#,
            #"{"at":0,"pointer":{"mode":"hand"}}"#,
            #"{"at":0,"click":{"deliver":false}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"card":"jump"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"zone":"canvas","at":"center"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"window":[10,20]},"ease":"aim"}}"#,
            #"{"at":0,"dur":30,"pointer":{"to":{"by":[4,-3]}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"board","at":[0.2,0.8]}}}"#,
            #"{"at":0,"dur":60,"pan":{"to":{"tiles":["board"]},"style":"drag"}}"#,
            #"{"at":0,"dur":60,"pan":{"to":{"tiles":["site"]}}}"#,
            #"{"at":0,"dur":60,"zoom":{"to":{"all":true}},"ease":"spring:soft"}"#,
            #"{"at":0,"dur":60,"drag":{"card":"jump","toAgent":"fix","spring":"snappy"}}"#,
        ]
        var rejected = [
            #"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"board"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"fix","at":"header"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"fix","tile":"fix"}}}"#,
            #"{"at":0,"dur":60,"reveal":"board"}"#,
            #"{"at":0,"reveal":"fix"}"#,
            #"{"at":0,"dur":60,"pan":{"to":{"tiles":["site"]}},"ease":"smootherer"}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"nope"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix"},"spring":"bouncy"}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix"},"mode":"hand"}}"#,
            #"{"at":0,"pointer":{"mode":"laser"}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix","card":"jump"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix","at":"middle"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix","at":[0.5]}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"zone":"canvas","at":"body"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"window":[10]}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"by":[3,4],"tile":"fix"}}}"#,
            #"{"at":0,"dur":60,"pan":{"to":{"tiles":["board"]},"style":"swipe"}}"#,
            #"{"at":0,"pan":{"to":{"tiles":["board"]}}}"#,
            #"{"at":0,"dur":60,"pan":{"to":{}}}"#,
            #"{"at":0,"dur":60,"zoom":{"to":{"all":true},"ease":"spring:wobbly"}}"#,
            #"{"at":0,"zoom":{"to":{"all":true}}}"#,
            #"{"at":0,"dur":10,"pointer":{"mode":"hand"},"click":{}}"#,
            #"{"at":0,"dur":60,"drag":{"card":"nope","toAgent":"fix"}}"#,
            #"{"at":0,"dur":60,"drag":{"card":"jump","toAgent":"board"}}"#,
            #"{"at":0,"dur":60,"camera":{"all":true},"ease":"bounce"}"#,
        ]
        accepted.append(#"{"at":0,"dur":60,"pan":{"to":{"tiles":["site"]}},"ease":"smoother"}"#)
        // The `open` verb, on an agent whose workspace tools the scene turns on.
        if let opener = decodeScene.tiles.first(where: { $0.kind == "agent" && $0.workspaceTools == true }) {
            accepted.append(#"{"at":0,"agent":"\#(opener.key)","open":{"path":"README.md","as":"readme","toolId":"t1"}}"#)
            rejected += [
                #"{"at":0,"open":{"path":"README.md","as":"readme","toolId":"t1"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","open":{"path":"/etc/hosts","as":"readme","toolId":"t1"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","open":{"path":"../README.md","as":"readme","toolId":"t1"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","open":{"path":"NOT-THERE.md","as":"readme","toolId":"t1"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","open":{"path":"README.md","as":"\#(opener.key)","toolId":"t1"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","open":{"path":"README.md","as":"readme","toolId":""}}"#,
                #"{"at":0,"agent":"\#(opener.key)","open":{"path":"README.md","as":"readme","toolId":"t1"},"say":"hi"}"#,
            ]
        }
        if let opener = decodeScene.tiles.first(where: { $0.kind == "agent" && $0.workspaceTools == true }) {
            accepted += [
                #"{"at":0,"agent":"\#(opener.key)","tool":{"id":"q1","name":"mcp__array_workspace__array_canvas_query","input":{"limit":5}}}"#,
                #"{"at":0,"agent":"\#(opener.key)","tool":{"id":"r1","name":"Read","input":{"file_path":"README.md"}}}"#,
            ]
            rejected += [
                // A workspace tool the catalogue does not list (integration catalogues
                // `array_delegate` since 0.7.26, so that is no longer the example).
                #"{"at":0,"agent":"\#(opener.key)","tool":{"id":"q1","name":"mcp__array_workspace__array_not_a_tool"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","tool":{"id":"q1","name":"Read","kind":"commandExecution"}}"#,
                #"{"at":0,"agent":"\#(opener.key)","tool":{"id":"q1","kind":"commandExecution","title":"Bash","input":{}}}"#,
                #"{"at":0,"tool":{"id":"q1","name":"Read"}}"#,
            ]
        }
        if let closed = decodeScene.tiles.first(where: { $0.kind == "agent" && $0.workspaceTools != true }) {
            rejected.append(#"{"at":0,"agent":"\#(closed.key)","tool":{"id":"q1","name":"mcp__array_workspace__array_canvas_query"}}"#)
            rejected.append(#"{"at":0,"agent":"\#(closed.key)","open":{"path":"README.md","as":"readme","toolId":"t1"}}"#)
        }
        accepted.append(#"{"at":0,"dur":60,"zoom":{"to":{"all":true}},"ease":"pan"}"#)
        // Real input, menus, adopt (FilmInput.swift, FilmDirectorDay.swift).
        accepted += [
            #"{"at":0,"dur":40,"gesture":{"to":{"world":[100,200]},"ease":"aim"}}"#,
            #"{"at":0,"dur":40,"gesture":{"to":{"by":[150,0]}}}"#,
            #"{"at":0,"click":{"deliver":true,"count":2}}"#,
            #"{"at":0,"key":"k","mods":["cmd"]}"#,
            #"{"at":0,"dur":30,"key":"a"}"#,
            #"{"at":0,"key":"Return"}"#,
            #"{"at":0,"dur":60,"hold":"option"}"#,
            #"{"at":0,"dur":20,"type":"Storefront"}"#,
            #"{"at":0,"menu":{"choose":["Color","Orange"]}}"#,
            #"{"at":0,"adopt":{"as":"newBoard","kind":"kanban"}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"choice":"roast-web"}}}"#,
        ]
        rejected += [
            #"{"at":0,"gesture":{"to":{"world":[100,200]}}}"#,
            #"{"at":0,"dur":40,"gesture":{"to":{"world":[100]}}}"#,
            #"{"at":0,"click":{"deliver":true,"count":3}}"#,
            #"{"at":0,"click":{"count":2}}"#,
            #"{"at":0,"key":"notakey"}"#,
            #"{"at":0,"key":"k","mods":["hyper"]}"#,
            #"{"at":0,"dur":10,"pointer":{"mode":"hand"},"mods":["cmd"]}"#,
            #"{"at":0,"hold":"option"}"#,
            #"{"at":0,"dur":10,"hold":"fn"}"#,
            #"{"at":0,"type":""}"#,
            #"{"at":0,"menu":{"choose":["Color"],"dismiss":true}}"#,
            #"{"at":0,"adopt":{"as":"x","kind":"kanban","child":"t1","of":"y"}}"#,
            #"{"at":0,"adopt":{"as":"x","kind":"wall"}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"choice":"roast-web","at":"center"}}}"#,
            #"{"at":0,"setting":{"agentHarness":"pi"}}"#,
        ]
        // v2: hover/dwell, click mods and glides, jumpZone, nudge/settings/bulk targets.
        accepted += [
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix"},"hover":true,"dwell":30}}"#,
            #"{"at":0,"dur":60,"click":{"deliver":true}}"#,
            #"{"at":0,"click":{"deliver":true,"mods":["cmd"]}}"#,
            #"{"at":0,"click":{"deliver":true},"mods":["shift"]}"#,
            #"{"at":0,"dur":60,"jumpZone":"canvas"}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"section.Agents"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"agentSounds.gitPushSucceeded.enabled"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"agentSounds.gitMergeSucceeded.preview"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"agentSounds.master"}}}"#,
        ]
        rejected += [
            #"{"at":0,"pointer":{"mode":"hand","dwell":10}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix"},"dwell":-1}}"#,
            #"{"at":0,"click":{"deliver":true,"mods":["hyper"]}}"#,
            #"{"at":0,"dur":60,"jumpZone":"nowhere"}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix","at":"nudge"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"zone":"canvas","at":"nudge"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"history","at":"nudge"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"agentSounds.gitPushSucceeded.volume"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"agentSounds.nope.enabled"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"section."}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"section.Agents","tile":"fix"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"settings":"section.Agents","at":"center"}}}"#,
            #"{"at":0,"dur":20,"pointer":{"to":{"bulk":"explode"}}}"#,
        ]
        let sidebarV2 = [#"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"fix","at":"nudge"}}}"#,
                         #"{"at":0,"dur":20,"pointer":{"to":{"bulk":"menu"}}}"#,
                         #"{"at":0,"dur":20,"pointer":{"to":{"bulk":"archive"}}}"#]
        if decodeScene.showsSidebar { accepted += sidebarV2 } else { rejected += sidebarV2 }
        let glide = try? JSONDecoder().decode(FilmAction.self, from: Data(#"{"at":0,"dur":60,"click":{"deliver":true}}"#.utf8))
        expect(glide?.duration == 60 && glide?.ownsNavigation == true, "a click with dur 60 must span 60 frames and own its navigation")
        let dwell = try? JSONDecoder().decode(FilmAction.self, from: Data(#"{"at":0,"dur":20,"pointer":{"to":{"tile":"fix"},"dwell":30}}"#.utf8))
        expect(dwell?.duration == 50 && dwell?.ownsPointer == true, "a pointer move's dwell must extend its ownership of the pointer")
        // The sidebar verbs exist only in a scene that shows the sidebar.
        let sidebarVerbs = [#"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"fix"}}}"#,
                            #"{"at":0,"dur":20,"pointer":{"to":{"sidebar":"fix","at":[0.2,0.5]}}}"#,
                            #"{"at":0,"dur":60,"reveal":"fix"}"#]
        if decodeScene.showsSidebar { accepted += sidebarVerbs } else { rejected += sidebarVerbs }
        func admits(_ json: String) -> Bool {
            guard let action = try? JSONDecoder().decode(FilmAction.self, from: Data(json.utf8)) else { return false }
            return (try? action.validate(in: decodeScene)) != nil
        }
        for json in accepted { expect(admits(json), "valid action rejected: \(json)") }
        for json in rejected { expect(!admits(json), "invalid action admitted: \(json)") }
        let click = try? JSONDecoder().decode(FilmAction.self, from: Data(#"{"at":7,"click":{}}"#.utf8))
        expect(click?.duration == 5 && click?.isPointerVerb == true, "a click must span 6 frames and run in the pointer pass")

        return (failures, "offline: 3 springs match the TS, aim/momentum/arc exact, \(fixedChecked) pinch fixed points held through interpolate, hand pan holds its world point, \(v2Report), \(accepted.count) actions admitted and \(rejected.count) refused")
    }

    // MARK: Pointer assertions (over the run's frame records)

    static func pointerAssertions(scene: FilmScene, director: FilmDirector, canvas: CanvasNSView,
                                  records: [Int: [FilmDirector.FrameRecord]], failures: inout [String]) -> String {
        var local: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { local.append(message()) } }
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
        func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double) -> Bool {
            near(Double(a.x), Double(b.x), tolerance) && near(Double(a.y), Double(b.y), tolerance)
        }
        let fps = Double(scene.framesPerSecond)
        let size = canvas.bounds.size
        var counts = (drags: 0, dragFrames: 0, pans: 0, zooms: 0, moves: 0, clicks: 0, rects: 0, sidebarMoves: 0)

        // Before anything moves it, the pointer waits off-window to fly in.
        let offWindow = FilmPointerState.offWindow(director.pointSize)
        if let first = records[0]?.first, !(scene.takes.first?.actions.contains { $0.at == 0 && $0.isPointerVerb } ?? false) {
            expect(close(first.pointer.point, offWindow.point, 1e-9), "frame 0 pointer \(first.pointer.point) is not off-window at \(offWindow.point)")
        }

        for (takeIndex, take) in scene.takes.enumerated() {
            guard let frames = records[takeIndex], frames.count == take.frames else { local.append("take \(take.name): records missing"); continue }
            func before(_ at: Int) -> FilmDirector.FrameRecord? { at > 0 ? frames[at - 1] : records[takeIndex - 1]?.last }
            func events(_ type: String, at frame: Int) -> Bool { frame < frames.count && frames[frame].events.contains(type) }

            // Measured rects hug the tiles: every staged tile rect equals its world
            // frame through the frame's own viewport (sampled every 20 frames).
            for record in frames where record.index % 20 == 0 {
                for spec in scene.tiles where spec.kind != "agent" {
                    guard let rect = record.rects[spec.key] else { continue }
                    let f = scene.worldFrame(of: spec)
                    let screen = CanvasEngine.tileScreenFrame(f, viewport: record.viewport)
                    let origin = director.topLeft(fromCanvas: screen.origin)
                    expect(close(rect.origin, origin, 0.5) && near(Double(rect.width), Double(screen.width), 0.5)
                           && near(Double(rect.height), Double(screen.height), 0.5),
                           "take \(take.name) frame \(record.index): measured \(spec.key) \(rect) != analytic \(origin) \(screen.size)")
                    counts.rects += 1
                }
            }

            for action in take.actions {
                let end = action.at + action.duration
                guard end < frames.count else { continue }
                if let drag = action.drag {
                    counts.drags += 1
                    expect(events("dragStart", at: action.at) && events("press", at: action.at), "drag \(drag.card): no press/dragStart at \(action.at)")
                    expect(events("drop", at: end) && events("release", at: end), "drag \(drag.card): no drop/release at \(end)")
                    var offsets: [CGPoint] = []
                    var carriedFrames = 0
                    // Through the frame before the drop: on the drop frame the lifted
                    // copy is gone and the card is back in its lane (or reassigned).
                    for frame in action.at..<end {
                        let record = frames[frame]
                        guard let card = record.rects["card:\(drag.card)"] else {
                            local.append("drag \(drag.card) frame \(frame): card has no rect"); break
                        }
                        expect(card.insetBy(dx: -0.5, dy: -0.5).contains(record.pointer.point),
                               "drag \(drag.card) frame \(frame): pointer \(record.pointer.point) is off the card \(card)")
                        expect(record.pointer.down && record.pointer.mode == "grab",
                               "drag \(drag.card) frame \(frame): pointer down/mode \(record.pointer.down)/\(record.pointer.mode)")
                        if record.carried.contains(drag.card) {
                            offsets.append(CGPoint(x: record.pointer.x - Double(card.minX), y: record.pointer.y - Double(card.minY)))
                            carriedFrames += 1
                        }
                        counts.dragFrames += 1
                    }
                    expect(!frames[end].pointer.down, "drag \(drag.card): pointer still down after the drop")
                    // Once lifted, the card rides the pointer at one fixed grab offset.
                    expect(carriedFrames >= action.duration / 2, "drag \(drag.card): the card was carried on only \(carriedFrames) frames")
                    if let first = offsets.first {
                        expect(offsets.allSatisfy { close($0, first, 0.01) }, "drag \(drag.card): grab offset drifts \(offsets.map { "\($0)" }.prefix(4))")
                    }
                    if let agent = drag.toAgent, let rect = frames[end - 1].rects[agent] {
                        expect(rect.contains(frames[end].pointer.point), "drag \(drag.card): released at \(frames[end].pointer.point), not on agent \(agent) \(rect)")
                    }
                }
                if let pan = action.pan, let prior = before(action.at) {
                    counts.pans += 1
                    let v0 = prior.viewport
                    guard let rect = analyticRect(pan.to, scene: scene, opened: director.reportedOpenRects,
                                                  drawn: drawnZones(scene: scene, director: director, takeIndex: takeIndex, at: action.at)) else { continue }
                    let v1 = FilmPointerMath.panViewport(from: v0, centering: rect, size: size)
                    let last = frames[end].viewport
                    expect(near(last.x, v1.x, 0.01) && near(last.y, v1.y, 0.01) && last.zoom == v0.zoom,
                           "pan at \(action.at): ended at \(last), want \(v1)")
                    expect(events("panStart", at: action.at) && events("panEnd", at: end), "pan at \(action.at): panStart/panEnd missing")
                    if pan.style == "drag" {
                        let grabbed = CanvasEngine.screenToWorld(director.canvasPoint(fromTopLeft: frames[action.at].pointer.point), viewport: frames[action.at].viewport)
                        for frame in action.at...end {
                            let record = frames[frame]
                            let world = CanvasEngine.screenToWorld(director.canvasPoint(fromTopLeft: record.pointer.point), viewport: record.viewport)
                            if !close(world, grabbed, 0.01) {
                                local.append("drag pan at \(action.at) frame \(frame): the pointer let go of world \(grabbed) (now over \(world))"); break
                            }
                            expect(record.pointer.down == (frame < end), "drag pan frame \(frame): pointer down \(record.pointer.down)")
                        }
                        expect(events("press", at: action.at) && events("release", at: end), "drag pan at \(action.at): press/release missing")
                    } else {
                        let still = prior.pointer.point
                        expect((action.at...end).allSatisfy { frames[$0].pointer.point == still }, "scroll pan at \(action.at): the pointer moved")
                        expect((action.at..<end).allSatisfy { frames[$0].pointer.mode == "scroll" }, "scroll pan at \(action.at): mode is not scroll")
                        let curve = scene.cameraCurve(for: action)
                        for l in 0...action.duration {
                            let want = FilmDirector.interpolate(v0, v1, curve.value(Double(l) / Double(action.duration), duration: Double(action.duration) / fps), size: size)
                            let got = frames[action.at + l].viewport
                            if !(near(got.x, want.x, 1e-6) && near(got.y, want.y, 1e-6)) { local.append("scroll pan at \(action.at)+\(l): \(got) off the curve \(want)"); break }
                        }
                    }
                }
                if scene.isCameraV2, let zoom = action.zoom, let rect = analyticRect(zoom.to, scene: scene, opened: director.reportedOpenRects,
                                                                                      drawn: drawnZones(scene: scene, director: director, takeIndex: takeIndex, at: action.at)) {
                    // v2: the pinch rides the TARGET's centre through the live viewport,
                    // held inside the canvas (inset) while that centre is off screen.
                    counts.zooms += 1
                    let world = CGPoint(x: rect.midX, y: rect.midY)
                    let inside = director.topLeftRect(of: canvas, canvas.bounds).insetBy(dx: FilmDirector.pinchInset, dy: FilmDirector.pinchInset)
                    expect(events("zoomStart", at: action.at) && events("zoomEnd", at: end), "zoom at \(action.at): zoomStart/zoomEnd missing")
                    for frame in (action.at + min(FilmPointerMath.pinchApproachFrames, action.duration))...end {
                        let record = frames[frame]
                        let screen = director.topLeft(fromCanvas: CanvasEngine.worldToScreen(world, viewport: record.viewport))
                        let want = CGPoint(x: min(max(screen.x, inside.minX), inside.maxX), y: min(max(screen.y, inside.minY), inside.maxY))
                        expect(close(record.pointer.point, want, 1e-6), "v2 zoom frame \(frame): pointer \(record.pointer.point) is off the target centre \(want)")
                    }
                    let last = frames[end]
                    let canvasCentre = director.topLeft(fromCanvas: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
                    expect(close(last.pointer.point, canvasCentre, 0.01), "v2 zoom at \(action.at): the pinch ends at \(last.pointer.point), not the canvas centre \(canvasCentre)")
                    expect((action.at..<end).allSatisfy { frames[$0].pointer.mode == "pinch" }, "zoom at \(action.at): mode is not pinch")
                } else if let zoom = action.zoom, let prior = before(action.at),
                   let v1 = analyticViewport(zoom.to, scene: scene, size: size, opened: director.reportedOpenRects,
                                             drawn: drawnZones(scene: scene, director: director, takeIndex: takeIndex, at: action.at)),
                   let fixedCanvas = FilmPointerMath.fixedPoint(prior.viewport, v1) {
                    counts.zooms += 1
                    let fixed = director.topLeft(fromCanvas: fixedCanvas)
                    let anchor = CanvasEngine.screenToWorld(fixedCanvas, viewport: prior.viewport)
                    expect(events("zoomStart", at: action.at) && events("zoomEnd", at: end), "zoom at \(action.at): zoomStart/zoomEnd missing")
                    for frame in (action.at + min(FilmPointerMath.pinchApproachFrames, action.duration))...end {
                        let record = frames[frame]
                        expect(close(record.pointer.point, fixed, 1e-6), "zoom frame \(frame): pointer \(record.pointer.point) is off the fixed point \(fixed)")
                        let world = CanvasEngine.screenToWorld(director.canvasPoint(fromTopLeft: record.pointer.point), viewport: record.viewport)
                        expect(close(world, anchor, 1e-3), "zoom frame \(frame): the world under the pointer moved \(anchor) -> \(world)")
                    }
                    expect((action.at..<end).allSatisfy { frames[$0].pointer.mode == "pinch" }, "zoom at \(action.at): mode is not pinch")
                }
                if let move = action.pointer, let target = move.to {
                    counts.moves += 1
                    let landed = frames[end].pointer.point
                    var want: CGPoint?
                    if let point = target.window { want = CGPoint(x: point[0], y: point[1]) }
                    if let delta = target.by, let prior = before(action.at) {
                        want = CGPoint(x: prior.pointer.x + delta[0], y: prior.pointer.y + delta[1])
                    }
                    if let key = target.tile, (target.at ?? .center) == .center, let rect = frames[end].rects[key] { want = CGPoint(x: rect.midX, y: rect.midY) }
                    if let key = target.card, target.at == nil, let rect = frames[end].rects["card:\(key)"] { want = CGPoint(x: rect.midX, y: rect.midY) }
                    if let key = target.sidebar, target.at == .nudge {
                        if let rect = frames[end].rects["nudge:\(key)"] { want = CGPoint(x: rect.midX, y: rect.midY) }
                        else { local.append("pointer move at \(action.at): \(key)'s nudge has no rect") }
                    } else if let key = target.sidebar {
                        // A sidebar row is measured from its live cell; a row that is not
                        // there leaves nothing to land on.
                        if let rect = frames[end].rects["sidebar:\(key)"] {
                            switch target.at ?? .center {
                            case let .fraction(fx, fy): want = CGPoint(x: Double(rect.minX) + Double(rect.width) * fx, y: Double(rect.minY) + Double(rect.height) * fy)
                            default: want = CGPoint(x: rect.midX, y: rect.midY)
                            }
                            counts.sidebarMoves += 1
                        } else {
                            local.append("pointer move at \(action.at): sidebar row \(key) has no rect")
                        }
                    }
                    if let want { expect(close(landed, want, 0.1), "pointer move at \(action.at): landed \(landed), target \(want)") }
                }
                if action.click != nil {
                    // Press .. release is always frames 0..5; a longer `dur` is a glide after it.
                    let release = action.at + 5
                    counts.clicks += 1
                    expect(events("press", at: action.at) && events("release", at: release) && events("click", at: release),
                           "click at \(action.at): press/release/click events missing")
                    expect((action.at..<release).allSatisfy { frames[$0].pointer.down } && !frames[release].pointer.down,
                           "click at \(action.at): pointer not held down for the press")
                }
            }
        }
        failures += local
        return "pointer: \(counts.drags) drags kept the card under the pointer for \(counts.dragFrames) frames at a fixed grab offset once lifted, \(counts.pans) pans (hand pans held their world point), \(counts.zooms) pinches held the pointer on \(scene.isCameraV2 ? "the target's live centre" : "the fixed point"), \(counts.moves) moves landed (\(counts.sidebarMoves) on sidebar rows), \(counts.clicks) clicks; \(counts.rects) measured rects matched their world frames"
    }

    // MARK: cameraModel v2 (offline)

    static func cameraV2Offline(scene: FilmScene, size: CGSize, failures: inout [String]) -> String {
        var local: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { local.append(message()) } }
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

        // The two zero-start curves, exactly as named.
        let pan = FilmCurve.bezier(.pan)
        expect(FilmCurve.named("pan") == pan && FilmEase.pan.p1 == (0.4, 0) && FilmEase.pan.p2 == (0.2, 1),
               "pan is not cubic-bezier(0.4, 0, 0.2, 1)")
        expect(FilmCurve.named("smoother") == .smoother, "smoother does not resolve")
        for p in [0.1, 0.25, 0.5, 0.8] {
            let want = 6 * pow(p, 5) - 15 * pow(p, 4) + 10 * pow(p, 3)
            expect(near(FilmCurve.smoother.value(p, duration: 1), want, 1e-12), "smootherstep(\(p)) is not 6p^5-15p^4+10p^3")
        }
        for (name, curve) in [("pan", pan), ("smoother", FilmCurve.smoother)] {
            let start = curve.value(1e-3, duration: 1) / 1e-3
            expect(start < 0.02, "\(name) starts at slope \(start), not zero")
            expect(curve.value(0, duration: 1) == 0 && curve.value(1, duration: 1) == 1, "\(name) ends")
            expect((0..<200).allSatisfy { curve.value(Double($0 + 1) / 200, duration: 1) >= curve.value(Double($0) / 200, duration: 1) },
                   "\(name) is not monotone")
        }
        // The probe has teeth: the curves the review measured as fast-attack do not pass it.
        expect(FilmCurve.momentum.value(1e-3, duration: 1) / 1e-3 > 1 && FilmCurve.bezier(.cam).value(1e-3, duration: 1) / 1e-3 > 0.1,
               "the zero-slope probe cannot tell momentum or cam from pan")
        expect(near(FilmCurve.smoother.peakSlope(duration: 1), 1.875, 1e-3), "smoother peak slope \(FilmCurve.smoother.peakSlope(duration: 1)) != 1.875")
        let panPeak = pan.peakSlope(duration: 1)
        expect(panPeak > 2.6 && panPeak < 2.9, "pan peak slope \(panPeak) is outside 2.6...2.9")

        // Curve defaults: v1 keeps its own, v2 is pan everywhere, an explicit ease wins.
        var v1Scene = scene; v1Scene.cameraModel = nil
        var v2Scene = scene; v2Scene.cameraModel = "v2"
        func action(_ json: String) -> FilmAction { try! JSONDecoder().decode(FilmAction.self, from: Data(json.utf8)) }
        let zoomAction = action(#"{"at":0,"dur":60,"zoom":{"to":{"all":true}}}"#)
        let scrollAction = action(#"{"at":0,"dur":60,"pan":{"to":{"all":true}}}"#)
        let dragAction = action(#"{"at":0,"dur":60,"pan":{"to":{"all":true},"style":"drag"}}"#)
        let cameraAction = action(#"{"at":0,"dur":60,"camera":{"all":true}}"#)
        expect(v1Scene.cameraCurve(for: zoomAction) == .bezier(.cam) && v1Scene.cameraCurve(for: scrollAction) == .momentum
               && v1Scene.cameraCurve(for: dragAction) == .bezier(.inOut) && v1Scene.cameraCurve(for: cameraAction) == .bezier(.cam),
               "cameraModel v1 lost its original defaults")
        expect([zoomAction, scrollAction, dragAction, cameraAction].allSatisfy { v2Scene.cameraCurve(for: $0) == pan },
               "cameraModel v2 does not default camera/pan/zoom to pan")
        expect(v2Scene.cameraCurve(for: action(#"{"at":0,"dur":60,"zoom":{"to":{"all":true},"ease":"spring:soft"}}"#)) == .spring(.soft)
               && v2Scene.cameraCurve(for: action(#"{"at":0,"dur":60,"pan":{"to":{"all":true},"ease":"momentum"}}"#)) == .momentum
               && v2Scene.cameraCurve(for: action(#"{"at":0,"dur":60,"camera":{"all":true},"ease":"inOut"}"#)) == .bezier(.inOut),
               "an explicit ease must win under v2")

        // The staggered zoom, in and out, on the review's own zoomIn numbers.
        let wide = CanvasViewport(x: -278, y: -557, zoom: 0.2157)
        let target = CGRect(x: 40, y: 80, width: 1520, height: 700)
        let close = CanvasEngine.fit(worldRect: target, viewportSize: size, padding: 40)
        let world = CGPoint(x: target.midX, y: target.midY)
        let screenCentre = CGPoint(x: size.width / 2, y: size.height / 2)
        func distance(_ v: CanvasViewport) -> Double {
            let s = CanvasEngine.worldToScreen(world, viewport: v)
            return hypot(Double(s.x - screenCentre.x), Double(s.y - screenCentre.y))
        }
        for (v0, v1, label) in [(wide, close, "in"), (close, wide, "out")] {
            let c0 = FilmCameraMath.centre(of: v0, size: size), c1 = FilmCameraMath.centre(of: v1, size: size)
            var previous: CanvasViewport?
            var held = (zoom: 0, centre: 0)
            for i in 0...240 {
                let p = Double(i) / 240
                let v = FilmCameraMath.interpolate(v0, v1, p: p, curve: pan, duration: 3, size: size)
                let c = FilmCameraMath.centre(of: v, size: size)
                if let previous {
                    let monotone = v1.zoom > v0.zoom ? v.zoom >= previous.zoom - 1e-12 : v.zoom <= previous.zoom + 1e-12
                    if !monotone { local.append("v2 zoom \(label): zoom reverses at p=\(p)"); break }
                    if label == "in", distance(v) > distance(previous) + 1e-6 {
                        local.append("v2 zoom in: the target streams away from the centre at p=\(p) (\(distance(previous)) -> \(distance(v)))"); break
                    }
                }
                // Zooming in, the centre leads: the zoom holds for the first 12%, the
                // centre is home for the last 12%. Zooming out, the zoom leads.
                let laggard = label == "in" ? near(v.zoom, v0.zoom, 1e-12) : (near(Double(c.x), Double(c0.x), 1e-9) && near(Double(c.y), Double(c0.y), 1e-9))
                let leader = label == "in" ? (near(Double(c.x), Double(c1.x), 1e-9) && near(Double(c.y), Double(c1.y), 1e-9)) : near(v.zoom, v1.zoom, 1e-12)
                if p <= FilmCameraMath.zoomLag { held.zoom += laggard ? 1 : 0; expect(laggard, "v2 zoom \(label): the trailing half moved at p=\(p)") }
                if p >= 1 - FilmCameraMath.zoomLag { held.centre += leader ? 1 : 0; expect(leader, "v2 zoom \(label): the leading half is not home at p=\(p)") }
                previous = v
            }
            expect(held.zoom > 0 && held.centre > 0, "v2 zoom \(label): the lag windows were never sampled")
            expect(FilmCameraMath.interpolate(v0, v1, p: 1, curve: pan, duration: 3, size: size) == v1
                   && FilmCameraMath.interpolate(v0, v1, p: 0, curve: pan, duration: 3, size: size) == v0, "v2 zoom \(label): ends are not exact")
        }
        expect(distance(close) < 1e-6, "fit does not centre the zoom target")
        // A move that does not zoom has no lag: its centre runs on e(p) itself.
        let flat0 = CanvasViewport(x: 0, y: 0, zoom: 1), flat1 = CanvasViewport(x: 800, y: 300, zoom: 1)
        let flat = FilmCameraMath.interpolate(flat0, flat1, p: 0.3, curve: pan, duration: 1, size: size)
        expect(near(flat.x, 800 * pan.value(0.3, duration: 1), 1e-9) && flat.zoom == 1, "a non-zooming v2 move must not lag")

        // The speed guard: peak slope x distance / duration, and it warns past its limits.
        let across = FilmCameraMath.peakSpeed(from: flat0, to: CanvasViewport(x: Double(size.width), y: 0, zoom: 1),
                                              curve: .smoother, duration: 1, size: size, staggered: false)
        expect(near(across.panWidthsPerSecond, 1.875, 2e-3) && across.zoomOctavesPerSecond == 0 && across.warnings.count == 1,
               "one canvas width in 1 s on smoother: \(across)")
        let slower = FilmCameraMath.peakSpeed(from: flat0, to: CanvasViewport(x: Double(size.width), y: 0, zoom: 1),
                                              curve: .smoother, duration: 2, size: size, staggered: false)
        expect(near(slower.panWidthsPerSecond, 0.9375, 1e-3) && slower.warnings.isEmpty, "one canvas width in 2 s on smoother: \(slower)")
        let centre = CGPoint(x: 1000, y: 600)
        let quarter = FilmCameraMath.viewport(centre: centre, zoom: 0.25, size: size)
        let one = FilmCameraMath.viewport(centre: centre, zoom: 1, size: size)
        let zoom3 = FilmCameraMath.peakSpeed(from: quarter, to: one, curve: .smoother, duration: 3, size: size, staggered: true)
        expect(near(zoom3.zoomOctavesPerSecond, 1.875 / 0.88 * 2 / 3, 2e-3) && near(zoom3.panWidthsPerSecond, 0, 1e-9)
               && zoom3.warnings.count == 1, "two octaves in 3 s, staggered: \(zoom3)")
        let zoom4 = FilmCameraMath.peakSpeed(from: quarter, to: one, curve: .smoother, duration: 4, size: size, staggered: true)
        expect(near(zoom4.zoomOctavesPerSecond, 1.875 / 0.88 * 2 / 4, 2e-3) && zoom4.warnings.isEmpty, "two octaves in 4 s, staggered: \(zoom4)")
        let plain = FilmCameraMath.peakSpeed(from: quarter, to: one, curve: .smoother, duration: 3, size: size, staggered: false)
        expect(near(plain.zoomOctavesPerSecond, 1.25, 2e-3), "two octaves in 3 s, unstaggered: \(plain)")

        failures += local
        return "camera v2: pan/smoother start at slope 0 (momentum/cam do not), v1 defaults intact and v2 defaults to pan, the staggered zoom leads/lags by 12% and pivots on its target, speed guard 1.875 w/s and \(String(format: "%.3f", zoom3.zoomOctavesPerSecond)) oct/s flagged, slower moves not"
    }

    // MARK: Sidebar, film clock and reveals (scenes with "sidebar": true)

    static func sidebarAssertions(scene: FilmScene, director: FilmDirector, delegate: AppDelegate, canvas: CanvasNSView,
                                  records: [Int: [FilmDirector.FrameRecord]], failures: inout [String]) async throws -> String {
        var local: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { local.append(message()) } }
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
        let fps = Double(scene.framesPerSecond)

        // 1) On screen every frame at the scene's width, each agent's row inside it.
        var sidebarFrames = 0, rowRects = 0
        for (takeIndex, take) in scene.takes.enumerated() {
            for record in records[takeIndex] ?? [] {
                guard let bar = record.rects["sidebar"] else { local.append("take \(take.name) frame \(record.index): no sidebar rect"); break }
                expect(near(Double(bar.minX), 0, 0.5) && near(Double(bar.width), scene.resolvedSidebarWidth, 0.5),
                       "take \(take.name) frame \(record.index): sidebar \(bar) is not x=0 w=\(scene.resolvedSidebarWidth)")
                for key in director.agents.keys {
                    guard let row = record.rects["sidebar:\(key)"] else { continue }
                    expect(bar.insetBy(dx: -0.5, dy: -0.5).contains(row), "take \(take.name) frame \(record.index): row \(key) \(row) is outside the sidebar \(bar)")
                    rowRects += 1
                }
                sidebarFrames += 1
            }
        }
        let lastRecord = records[scene.takes.count - 1]?.last
        for key in director.agents.keys.sorted() {
            expect(lastRecord?.rects["sidebar:\(key)"] != nil, "agent \(key) has no sidebar row on the last frame")
        }

        // 2) Elapsed on the film clock: a working row reads the film seconds since its
        //    turn started, computed with the same date arithmetic the stamps use.
        var turnEvents: [String: [(frame: Int, start: Bool, ago: Double, failed: Bool)]] = [:]
        var offset = 0
        var takeOffsets: [Int] = []
        for take in scene.takes {
            takeOffsets.append(offset)
            for action in take.actions {
                // A child's turn is its own; `ago` back-dates a start.
                if let agent = action.agent, action.child == nil, let turn = action.turn {
                    turnEvents[agent, default: []].append((offset + action.at, turn == "start", action.ago ?? 0, turn == "failed"))
                }
            }
            offset += take.frames
        }
        // Film time per global frame, clock jumps included (a `clock` take moves it hours).
        var filmTimes: [Int: Double] = [:]
        for (takeIndex, _) in scene.takes.enumerated() {
            for record in records[takeIndex] ?? [] { filmTimes[takeOffsets[takeIndex] + record.index] = record.filmTime }
        }
        func filmDate(_ frame: Int) -> Date { director.filmEpoch.addingTimeInterval(filmTimes[frame] ?? Double(frame) / fps) }
        var elapsedChecked = 0
        for (takeIndex, _) in scene.takes.enumerated() {
            for record in records[takeIndex] ?? [] where record.index % 15 == 0 {
                let frame = takeOffsets[takeIndex] + record.index
                for (key, label) in record.sidebarStates {
                    // A turn event on this very frame has already been applied when it is recorded.
                    guard let last = turnEvents[key]?.filter({ $0.frame <= frame }).last, last.start else { continue }
                    guard let want = AgentInboxCellView.elapsedText(filmDate(frame).timeIntervalSince(filmDate(last.frame)) + last.ago) else { continue }
                    expect(label == want || label.hasSuffix(" " + want),
                           "frame \(frame): \(key)'s row reads \"\(label)\", the film clock says \(want)")
                    elapsedChecked += 1
                }
            }
        }
        expect(elapsedChecked > 0, "no working sidebar row was sampled for its elapsed time")
        // ...regardless of the wall clock: let real seconds pass, tick, read again.
        // Tick first: the last record was read one film frame before the clock now stands.
        delegate.filmTickSidebar()
        let frozen = director.sidebarStates()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        delegate.filmTickSidebar()
        let later = director.sidebarStates()
        let timed = frozen.filter { !$0.value.isEmpty }
        for (key, label) in timed { expect(later[key] == label, "\(key)'s row moved with the wall clock: \"\(label)\" -> \"\(later[key] ?? "nil")\"") }
        expect(!timed.isEmpty, "no sidebar row showed a time to hold still")

        // 3) A finished turn rests in production's uncoloured "ready"; a failed one in
        //    `.failed` (which-tab's Order export ends that way on purpose).
        let rows = delegate.filmSidebar?.agentInbox.qaAllRowsForQA ?? []
        var readyChecked = 0
        for (key, events) in turnEvents where events.last?.start == false {
            guard let agent = director.agents[key] else { continue }
            let row = rows.first { $0.id == agent.agentId.rawValue }
            let want: InboxState = events.last?.failed == true ? .failed : .ready
            expect(row?.state == want, "agent \(key) ended its turn (\(want)), but its row is \(String(describing: row?.state))")
            readyChecked += 1
        }

        // 4) Reveals: production's selection and focus, and a glide that ends exactly on
        //    the viewport production cuts to.
        var revealsChecked = 0
        for (takeIndex, take) in scene.takes.enumerated() {
            guard let frames = records[takeIndex] else { continue }
            for action in take.actions {
                guard let key = action.reveal else { continue }
                guard let agent = director.agents[key],
                      let record = director.reveals.first(where: { $0.takeIndex == takeIndex && $0.at == action.at }) else {
                    local.append("reveal \(key) at \(action.at): never ran"); continue
                }
                expect(record.clicked, "reveal \(key): its row was not clicked")
                // Production's highlight after a reveal: the agent becomes the route-active
                // row (`openAgentId`), and because that re-renders the list, the table
                // selection the click made is emptied (AgentInboxView.openAgentId,
                // `completePendingAdvance`'s note). Re-revealing the open agent keeps it.
                let id = agent.agentId.rawValue
                expect(record.routeAfter == id, "reveal \(key): the route-active row is \(String(describing: record.routeAfter)), want its agent")
                let wantSelection = record.routeBefore == id ? [id] : []
                expect(record.selection == wantSelection, "reveal \(key): table selection \(record.selection), production leaves \(wantSelection)")
                expect(record.focusedTile == agent.tileId, "reveal \(key): focused tile \(String(describing: record.focusedTile)), want \(agent.tileId)")
                guard let production = record.production else { local.append("reveal \(key): production framed no camera move"); continue }
                expect(record.framed == production, "reveal \(key): production cut to \(production), framedViewportForTileJump said \(String(describing: record.framed))")
                if let snapshot = canvas.navigationTileSnapshot(for: agent.tileId) {
                    let f = snapshot.worldFrame
                    let want = CameraFraming.revealWorkViewport(for: CGRect(x: f.x, y: f.y, width: f.width, height: f.height), kind: snapshot.kind,
                                                                currentViewport: record.before, viewportSize: canvas.bounds.size)
                    expect(want == production, "reveal \(key): CameraFraming frames \(want), production cut to \(production)")
                }
                let end = action.at + action.duration
                guard end < frames.count else { local.append("reveal \(key): ends after the take"); continue }
                let landed = frames[end].viewport
                expect(near(landed.x, production.x, 1e-9) && near(landed.y, production.y, 1e-9) && near(landed.zoom, production.zoom, 1e-12),
                       "reveal \(key): the glide ended at \(landed), production cuts to \(production)")
                expect(frames[action.at].viewport == record.before, "reveal \(key): the camera cut on the click frame")
                let curve = scene.cameraCurve(for: action)
                for l in 0...action.duration {
                    let want = FilmCameraMath.interpolate(record.before, production, p: Double(l) / Double(action.duration), curve: curve,
                                                          duration: Double(action.duration) / fps, size: canvas.bounds.size)
                    let got = frames[action.at + l].viewport
                    if !(near(got.x, want.x, 1e-6) && near(got.y, want.y, 1e-6) && near(got.zoom, want.zoom, 1e-9)) {
                        local.append("reveal \(key) +\(l): \(got) is off the v2 glide \(want)"); break
                    }
                }
                expect(frames[action.at].events.contains("revealStart") && frames[end].events.contains("revealEnd"),
                       "reveal \(key): revealStart/revealEnd missing")
                revealsChecked += 1
            }
        }
        failures += local
        return "sidebar: on screen \(sidebarFrames) frames at \(Int(scene.resolvedSidebarWidth)) pt, \(rowRects) row rects inside it, \(elapsedChecked) elapsed readouts on the film clock and still after 2.5 s of wall time, \(readyChecked) finished rows ready, \(revealsChecked) reveals made their agent the route-active row and focused its tile and glided exactly onto production's framed viewport"
    }

    // MARK: Opens (Array's own workspace tool, staged through production)

    static func openAssertions(scene: FilmScene, director: FilmDirector, delegate: AppDelegate, canvas: CanvasNSView,
                               roots: FilmStager.Roots, records: [Int: [FilmDirector.FrameRecord]],
                               failures: inout [String]) async throws -> String {
        var local: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { local.append(message()) } }
        func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.5) -> Bool { abs(a - b) <= tolerance }
        var checked = 0, rectsChecked = 0
        var placements: [String] = []

        for spec in scene.tiles where spec.workspaceTools == true {
            let enabled = director.agents[spec.key].flatMap { delegate.qaAgentSupervisor.records[$0.agentId]?.workspaceToolsEnabled }
            expect(enabled == true, "agent \(spec.key): workspaceTools is \(String(describing: enabled)) after staging, want true")
        }
        for (takeIndex, take) in scene.takes.enumerated() {
            for action in take.actions {
                guard let open = action.open, let agentKey = action.agent else { continue }
                guard let record = director.opens.first(where: { $0.key == open.as }) else {
                    local.append("open \(open.as): never ran"); continue
                }
                guard let agent = director.agents[agentKey], let agentFrame = director.worldFrame(of: agent.tileId) else {
                    local.append("open \(open.as): agent \(agentKey) has no tile"); continue
                }
                // The tile registered under the key (what later targets and `rects` use) is
                // the one production reported, exists, is a file tile, and shows exactly
                // that checkout file.
                guard let tileId = director.openedTiles[open.as] else { local.append("open \(open.as): nothing registered"); continue }
                expect(tileId == record.result.tileId, "open \(open.as): registered tile \(tileId) is not the one production opened, \(String(describing: record.result.tileId))")
                guard let snapshot = canvas.navigationTileSnapshot(for: tileId) else {
                    local.append("open \(open.as): no tile \(tileId) on the canvas"); continue
                }
                expect(snapshot.kind == .file, "open \(open.as): tile kind \(snapshot.kind), want file")
                expect(record.result.document == .opened && record.result.placement == .created,
                       "open \(open.as): production reported document \(record.result.document.rawValue) / placement \(record.result.placement.rawValue), want opened / created")
                let root = scene.zone(scene.tile(agentKey)?.zone ?? "").flatMap { roots.projects[$0.project] }
                let want = root.map { $0.appendingPathComponent(open.path).resolvingSymlinksInPath().path }
                let shown = canvas.allWorkspaceTiles().first { $0.id == tileId }
                    .flatMap { $0.metadata.documentLocation?.path ?? $0.metadata.filePath }
                    .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                expect(want != nil && shown == want, "open \(open.as): the tile shows \(shown ?? "nothing"), want \(want ?? "?")")
                // Placed by production: the live frame IS the rect the API reported.
                let f = snapshot.worldFrame
                if let reported = record.result.actualWorldRect {
                    expect(near(f.x, reported.x) && near(f.y, reported.y) && near(f.width, reported.width) && near(f.height, reported.height),
                           "open \(open.as): live world frame \(f) != the workspace API's reported \(reported)")
                } else {
                    local.append("open \(open.as): the workspace API reported no world rect")
                }
                expect(snapshot.zoneId == agent.zoneId, "open \(open.as): opened into zone \(String(describing: snapshot.zoneId)), not the agent's \(agent.zoneId)")
                // Beside the agent: disjoint, docked across a small gap on one axis
                // while overlapping it on the other.
                let a = CGRect(x: agentFrame.x, y: agentFrame.y, width: agentFrame.width, height: agentFrame.height)
                let t = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
                let horizontalGap = max(t.minX - a.maxX, a.minX - t.maxX)
                let verticalGap = max(t.minY - a.maxY, a.minY - t.maxY)
                let besideX = horizontalGap >= 0 && horizontalGap <= 64 && t.minY < a.maxY && a.minY < t.maxY
                let besideY = verticalGap >= 0 && verticalGap <= 64 && t.minX < a.maxX && a.minX < t.maxX
                expect(!t.intersects(a) && (besideX || besideY),
                       "open \(open.as): \(t) is not beside agent \(agentKey) \(a) (gaps x \(horizontalGap), y \(verticalGap))")
                // `rects` records it under its key, at its world frame through each frame's camera.
                for frame in records[takeIndex] ?? [] where frame.index >= action.at {
                    guard let rect = frame.rects[open.as] else { continue }
                    let screen = CanvasEngine.tileScreenFrame(f, viewport: frame.viewport)
                    let origin = director.topLeft(fromCanvas: screen.origin)
                    expect(near(Double(rect.minX), Double(origin.x)) && near(Double(rect.minY), Double(origin.y))
                           && near(Double(rect.width), Double(screen.width)) && near(Double(rect.height), Double(screen.height)),
                           "open \(open.as) frame \(frame.index): rect \(rect) != its world frame through the camera \(origin) \(screen.size)")
                    rectsChecked += 1
                }
                expect((records[takeIndex] ?? []).contains { $0.index >= action.at && $0.rects[open.as] != nil },
                       "open \(open.as): never recorded in frames.json rects")
                // The reveal: production's cut handed over, glided on the v2 split over
                // `dur`, landing exactly on it — monotone, on the curve, no jumps.
                let frames = records[takeIndex] ?? []
                let end = action.at + action.duration
                if let production = record.production, end < frames.count {
                    expect(record.result.presentationEffects.camera == .changed, "open \(open.as): production reports camera \(record.result.presentationEffects.camera)")
                    expect(record.after == record.before, "open \(open.as): the camera cut during the API call (\(record.before) -> \(record.after))")
                    let landed = frames[end].viewport
                    expect(near(landed.x, production.x, 1e-9) && near(landed.y, production.y, 1e-9) && near(landed.zoom, production.zoom, 1e-12),
                           "open \(open.as): the glide ended at \(landed), production cuts to \(production)")
                    expect(frames[action.at].viewport == record.before, "open \(open.as): the camera cut on the open frame")
                    let curve = scene.cameraCurve(for: action)
                    let seconds = Double(action.duration) / Double(scene.framesPerSecond)
                    for l in 0...action.duration {
                        let want = FilmCameraMath.interpolate(record.before, production, p: action.duration == 0 ? 1 : Double(l) / Double(action.duration),
                                                              curve: curve, duration: seconds, size: canvas.bounds.size)
                        let got = frames[action.at + l].viewport
                        if !(near(got.x, want.x, 1e-6) && near(got.y, want.y, 1e-6) && near(got.zoom, want.zoom, 1e-9)) {
                            local.append("open \(open.as) reveal +\(l): \(got) is off the v2 glide \(want)"); break
                        }
                    }
                    let path = frames[action.at...end].map(\.viewport)
                    let zooms = path.map { log($0.zoom) }
                    let rising = (zooms.last ?? 0) >= (zooms.first ?? 0)
                    expect(zip(zooms, zooms.dropFirst()).allSatisfy { rising ? $1 >= $0 - 1e-9 : $1 <= $0 + 1e-9 },
                           "open \(open.as): the reveal's log-zoom is not monotone")
                    // No frame jumps: centre and zoom steps stay within the curve's peak slope.
                    let size = canvas.bounds.size
                    let centres = path.map { FilmCameraMath.centre(of: $0, size: size) }
                    let totalPan = hypot(Double(centres.last!.x - centres.first!.x), Double(centres.last!.y - centres.first!.y))
                    let largestPan = zip(centres, centres.dropFirst()).map { hypot(Double($1.x - $0.x), Double($1.y - $0.y)) }.max() ?? 0
                    let totalZoom = abs((zooms.last ?? 0) - (zooms.first ?? 0))
                    let largestZoom = zip(zooms, zooms.dropFirst()).map { abs($1 - $0) }.max() ?? 0
                    let span = FilmCameraMath.span(record.before, production)
                    let peak = curve.peakSlope(duration: seconds * span) / span
                    let budget = 1.25 * peak / Double(max(action.duration, 1))
                    expect(totalPan < 1e-6 || largestPan <= budget * totalPan, "open \(open.as): a \(largestPan) pt centre step in a \(totalPan) pt glide is a jump")
                    expect(totalZoom < 1e-6 || largestZoom <= budget * totalZoom, "open \(open.as): a \(largestZoom) log-zoom step in a \(totalZoom) glide is a jump")
                    expect(frames[action.at].events.contains("revealStart") && frames[end].events.contains("revealEnd"),
                           "open \(open.as): revealStart/revealEnd missing")
                    placements.append("reveal \(record.before) -> \(production) over \(action.duration) frames")
                } else {
                    local.append("open \(open.as): production presented no camera reveal (\(record.result.presentationEffects.camera))")
                }
                // The agent's transcript: production's row for the claude MCP call.
                let list = director.agentView(agentKey)?.qaTranscriptForChecks
                await list?.qaWaitForToolDetailRefresh()
                let title = list?.qaPresentedToolTitle(forProviderItemID: open.toolId)
                let basename = URL(fileURLWithPath: open.path).lastPathComponent
                expect(title == "Opened \(basename) on the canvas",
                       "open \(open.as): \(agentKey)'s row reads \(title.map { "\"\($0)\"" } ?? "nothing"), want \"Opened \(basename) on the canvas\"")
                placements.append("\(open.as) at \(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)) beside \(agentKey) \(Int(a.minX)),\(Int(a.minY)) \(Int(a.width))x\(Int(a.height))"
                                  + " (camera \(record.result.presentationEffects.camera))")
                checked += 1
            }
        }
        // Runner-spelled tools: each row titled by the production claude translator +
        // presenter from the raw name and input a live call carries.
        var namedTools = 0
        for take in scene.takes {
            for action in take.actions {
                guard let tool = action.tool, let name = tool.name, let agentKey = action.agent,
                      let workspaceTool = ArrayWorkspaceTool(toolName: name) else { continue }
                let list = director.agentView(agentKey)?.qaTranscriptForChecks
                await list?.qaWaitForToolDetailRefresh()
                let title = list?.qaPresentedToolTitle(forProviderItemID: tool.id)
                let path: String? = { if case let .string(value)? = tool.input?["relativePath"] { return value }; return nil }()
                var want = workspaceTool.actionLine(fileBasename: path.map { URL(fileURLWithPath: $0).lastPathComponent })
                var matches = title == want
                if workspaceTool == .boardApply {
                    // A named board change reads as production's `boardChangeLine`: the
                    // whole sentence when the input carries the title (create, edit), else
                    // its verb (the card and column names come from the host's reply).
                    func string(_ key: String) -> String? { if case let .string(v)? = tool.input?[key] { return v }; return nil }
                    let op = string("op")
                    let inputTitle = (op == "create" || op == "edit") ? string("title") : nil
                    want = ArrayWorkspaceTool.boardChangeLine(op: op, cardTitle: inputTitle, columnName: nil, assigneeName: nil)
                    let verb = want.split(separator: " ").first.map(String.init) ?? want
                    matches = inputTitle != nil || op.flatMap(BoardApplyRequest.Op.init(rawValue:)) == nil
                        ? title == want : title?.hasPrefix(verb + " ") == true
                }
                expect(matches, "tool \(name) (\(tool.id)): \(agentKey)'s row reads \(title.map { "\"\($0)\"" } ?? "nothing"), want \"\(want)\"")
                namedTools += 1
            }
        }
        failures += local
        return "\(namedTools) runner-spelled workspace tool row(s) titled by the claude translator; opens: \(checked) file(s) opened by their agent through the workspace API, placed where it reported, beside the agent, in \(rectsChecked) frame rects, row titled by the claude translator [\(placements.joined(separator: "; "))]"
    }

    /// `opened`: the world rects the workspace API REPORTED for tiles an `open`
    /// registered, so a target naming one is checked against production's placement.
    /// `drawn`: zones a take drew and adopted before this action, at their live rects.
    /// What a camera target frames: `drawn` (live geometry, from `drawnZones`) first, the
    /// staged scene geometry when the run recorded none.
    static func analyticRect(_ target: FilmAction.CameraTarget, scene: FilmScene, opened: [String: CGRect] = [:],
                             drawn: [String: CGRect] = [:]) -> CGRect? {
        var rects: [CGRect] = []
        for key in (target.zones ?? []) + (target.zone.map { [$0] } ?? []) { (drawn[key] ?? scene.zoneRect(key)).map { rects.append($0) } }
        for key in target.tiles ?? [] {
            if let rect = drawn["tile:" + key] { rects.append(rect) }
            else if let f = scene.tile(key).map(scene.worldFrame(of:)) { rects.append(CGRect(x: f.x, y: f.y, width: f.width, height: f.height)) }
            else if let rect = opened[key] { rects.append(rect) }
        }
        if let r = target.rect, r.count == 4 { rects.append(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) }
        if target.all == true {
            let zoneKeys = Set(scene.zones.map(\.key)).union(drawn.keys.filter { !$0.hasPrefix("tile:") })
            rects += zoneKeys.sorted().compactMap { drawn[$0] ?? scene.zoneRect($0) }
        }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    static func analyticViewport(_ target: FilmAction.CameraTarget, scene: FilmScene, size: CGSize,
                                 opened: [String: CGRect] = [:], drawn: [String: CGRect] = [:]) -> CanvasViewport? {
        guard let rect = analyticRect(target, scene: scene, opened: opened, drawn: drawn) else { return nil }
        return CanvasEngine.fit(worldRect: rect, viewportSize: size, padding: target.padding ?? 40)
    }

    /// Zones an `adopt` named before (`takeIndex`, `at`), at their live (end-of-film) rects.
    /// Per take, per frame: every zone's (key) and tile's ("tile:" + key) live world rect
    /// after that frame (the run loop in `run()` records it).
    static var zoneHistory: [Int: [[String: CGRect]]] = [:]

    /// The live geometry a camera move at frame `at` of take `takeIndex` frames: every
    /// staged zone and tile, and every zone the scene drew before `at`, each as it stood
    /// at the end of the frame before (the camera's target is resolved at the start of
    /// its frame). A drawn zone with no recorded history falls back to its current rect.
    static func drawnZones(scene: FilmScene, director: FilmDirector, takeIndex: Int, at: Int) -> [String: CGRect] {
        let before: [String: CGRect] = (at > 0
            ? zoneHistory[takeIndex].flatMap { at - 1 < $0.count ? $0[at - 1] : nil }
            : (takeIndex > 0 ? zoneHistory[takeIndex - 1]?.last : nil)) ?? [:]
        var drawn = before.filter { key, _ in key.hasPrefix("tile:") || scene.zone(key) != nil }
        for (index, take) in scene.takes.enumerated() where index <= takeIndex {
            for action in take.actions where index < takeIndex || action.at < at {
                guard let adopt = action.adopt, adopt.kind == "zone",
                      let rect = before[adopt.as] ?? director.zoneWorldRect(adopt.as) else { continue }
                drawn[adopt.as] = rect
            }
        }
        return drawn
    }

    static func boardView(for cardKey: String, scene: FilmScene, canvas: CanvasNSView) -> KanbanTileNSView? {
        scene.tiles.first { $0.board?.cards.contains { $0.key == cardKey } == true }
            .flatMap { canvas.tileView(for: scene.tileId($0.key)) as? KanbanTileNSView }
    }
}
#endif
