import AppKit
import ContinuumRevivedCore

/// Opt-in: the live gate passes the exact device it created and the disposable
/// UIKit witness's state file. No existing simulator or project is adopted.
@MainActor
enum IOSPreviewLiveTileChecks {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw IOSPreviewChecks.Failure(description: message) }
    }
    private static func wait(_ label: String, seconds: Double = 10, _ ready: () -> Bool) throws {
        let end = Date().addingTimeInterval(seconds)
        while !ready(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try expect(ready(), label)
        print("PASS: \(label)")
    }
    static func run() throws {
        let env = ProcessInfo.processInfo.environment
        guard let device = env["CONTINUUM_IOS_PREVIEW_DEVICE_ID"], UUID(uuidString: device) != nil,
              let statePath = env["CONTINUUM_IOS_PREVIEW_STATE_PATH"],
              let outPath = env["CONTINUUM_QA_OUTPUT_DIR"] else {
            throw IOSPreviewChecks.Failure(description: "Run through the isolated iOS preview live matrix with an owned device/state file.")
        }
        let fm = FileManager.default
        let out = URL(fileURLWithPath: outPath)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let root = fm.temporaryDirectory.appendingPathComponent("array-live-tile-\(UUID())")
        let support = root.appendingPathComponent("Support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(), projectID = UUID(), workspaceID = UUID(), zoneID = UUID()
        let project = Project(id: projectID, name: "Live tile proof", rootPath: root.path, createdAt: now, updatedAt: now,
                              defaultLaunchProfileId: "shell", editorPreference: .auto,
                              settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        try store.saveProject(project)
        let empty = CanvasState(viewport: CanvasViewport(x: 1000, y: 700, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
        try store.saveCanvas(empty)
        let document = WorkspaceDocument(viewport: empty.viewport,
            zones: [ZonePlacement(zoneId: zoneID, projectId: projectID, origin: ZonePoint(x: 1000, y: 700),
                                  size: ZoneSize(width: 1400, height: 1600), color: "blue", collapsed: false, hydrationPolicy: .automatic)],
            zoneZOrder: [zoneID], lastActiveZoneId: zoneID)
        try WorkspaceStore(workspaceId: workspaceID, applicationSupportDirectory: support).save(document)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceID
        registry.projects = [ProjectEntry(id: projectID, name: project.name, rootPath: root.path, workspaceId: workspaceID,
                                         lastOpenedAt: now, pinned: false, missing: false)]
        registry.workspaces = [WorkspaceEntry(id: workspaceID, name: "Proof", projectIds: [projectID], createdAt: now, updatedAt: now)]
        let registryStore = RegistryStore(applicationSupportDirectory: support)
        try registryStore.save(registry)
        let browser = BrowserEngineContext()
        defer { browser.shutdown() }
        let controller = ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        defer { controller.releaseRuntimes() }
        let zones = ZoneRuntimeRegistry(closeOnZero: false, makeController: { _ in controller })
        let canvas = CanvasNSView(canvasState: empty, activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
        canvas.frame = CGRect(x: 0, y: 0, width: 1400, height: 1200)
        canvas.occlusionVisibilityProvider = { true }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        let delegate = AppDelegate()
        let workspace = WorkspaceRuntime(workspaceId: workspaceID, document: document, registry: zones,
            focusBroker: delegate.qaFocusBroker, registryStore: registryStore, ghostty: nil, browserEngine: browser)
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browser, runtime: workspace, registryStore: registryStore)
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browser, projectStore: store, project: project)
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: store,
                                               canvasState: empty, installsGlobalEventMonitors: false)
        try expect(delegate.qaPerformPaletteAction(.newIOSPreview), "production palette must spawn a live-test tile")
        guard let record = canvas.allWorkspaceTiles().first(where: { $0.kind == .iosPreview }),
              let tile = canvas.tileView(for: record.id) as? IOSPreviewTileNSView else {
            throw IOSPreviewChecks.Failure(description: "production preview tile missing")
        }
        tile.selectDevice(id: device, name: "iPhone · Live proof")
        canvas.layoutSubtreeIfNeeded()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        tile.runtime.connect(allowBoot: false)
        try wait("production simulator connection settles", seconds: 90) {
            tile.runtime.state == .connected || { if case .failed = tile.runtime.state { return true }; return false }()
        }
        try expect(tile.runtime.state == .connected, "live tile could not connect: \(tile.runtime.state)")
        print("PASS: real simulator frames reach the production canvas tile")
        func state() -> [String: Any] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                  let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
            return value
        }
        func tap(_ target: String, hold: TimeInterval = 0.1) throws {
            guard let point = state()[target] as? [String: Double], let x = point["x"], let y = point["y"] else {
                throw IOSPreviewChecks.Failure(description: "missing live target")
            }
            let rect = tile.screen.screenRect
            let location = tile.screen.convert(CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            tile.screen.mouseDown(with: event(.leftMouseDown))
            if hold > 0 { RunLoop.current.run(until: Date().addingTimeInterval(hold)) }
            tile.screen.mouseUp(with: event(.leftMouseUp))
        }
        if env["IOS_PREVIEW_LIVE_PERFORMANCE"] == "1" {
            try IOSPreviewPerformanceChecks.run(tile: tile, deviceID: device, state: state,
                tap: { try tap("button", hold: 0) }, out: out)
        }
        let before = state()["taps"] as? Int ?? 0
        try tap("button")
        try wait("production tile click reaches UIKit") { state()["taps"] as? Int == before + 1 }
        try tap("field")
        try wait("production tile focuses the iOS text field") { state()["fieldFocused"] as? Bool == true }
        let textBeforeKey = state()["text"] as? String ?? ""
        func key(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: 0)!
        }
        tile.screen.keyDown(with: key(.keyDown)); tile.screen.keyUp(with: key(.keyUp))
        try wait("production keyboard events reach UIKit") { (state()["text"] as? String ?? "").count > textBeforeKey.count }
        tile.runtime.paste("canvas café 🧪")
        try wait("production paste path preserves Unicode/emoji") { (state()["text"] as? String ?? "").contains("canvas café 🧪") }
        func snapshot(_ name: String) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            tile.layoutSubtreeIfNeeded()
            let rep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds)!
            tile.cacheDisplay(in: tile.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        window.appearance = NSAppearance(named: .aqua)
        tile.applyTokens()
        try snapshot("ios-preview-live-tile-light.png")
        tile.runtime.rotate()
        try wait("production Rotate changes real iOS orientation") { (state()["width"] as? Double ?? 0) > (state()["height"] as? Double ?? 1) }
        try snapshot("ios-preview-live-tile-landscape-before-touch.png")
        try tap("button")
        try wait("rotated production tile maps touches correctly") { state()["taps"] as? Int == before + 2 }
        try snapshot("ios-preview-live-tile-landscape.png")
        let preservedText = state()["text"] as? String
        tile.runtime.disconnect()
        tile.runtime.connect(allowBoot: false)
        try wait("production tile reconnects in landscape", seconds: 45) { tile.runtime.state == .connected }
        try expect(tile.runtime.orientation == 3 && state()["text"] as? String == preservedText &&
                   state()["taps"] as? Int == before + 2,
                   "reconnecting must preserve the iOS app's state and viewer angle")
        tile.runtime.rotate()
        try wait("portrait restored") { (state()["height"] as? Double ?? 0) > (state()["width"] as? Double ?? 1) }
        window.appearance = NSAppearance(named: .darkAqua)
        tile.applyTokens()
        try snapshot("ios-preview-live-tile-dark.png")
        let frameCount = tile.runtime.receivedFrames
        tile.runtime.disconnect()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try expect(tile.runtime.receivedFrames == frameCount, "disconnected tile must reject frames")
        // A fresh selection defaults to portrait even if the device was left
        // rotated by another viewer. Admission must wait for that reset.
        tile.runtime.connect(allowBoot: false)
        try wait("prepare device rotation", seconds: 45) { tile.runtime.state == .connected }
        tile.runtime.rotate()
        try wait("device left in landscape") { (state()["width"] as? Double ?? 0) > (state()["height"] as? Double ?? 1) }
        tile.runtime.select(device)
        tile.runtime.connect(allowBoot: false)
        try wait("fresh connection restores portrait before interaction", seconds: 45) {
            tile.runtime.state == .connected && (state()["height"] as? Double ?? 0) > (state()["width"] as? Double ?? 1)
        }
        try expect(state()["text"] as? String == preservedText && state()["taps"] as? Int == before + 2,
                   "reconnecting must preserve the iOS app's state")
        if let project = ProcessInfo.processInfo.environment["IOS_PREVIEW_LIVE_BUILD_PROJECT"],
           let scheme = ProcessInfo.processInfo.environment["IOS_PREVIEW_LIVE_BUILD_SCHEME"] {
            var discovered: [IOSPreviewBuildChoice]?
            var discoveryError: Error?
            Task { @MainActor in
                do { discovered = try await IOSPreviewBuild().choices(in: URL(fileURLWithPath: project).deletingLastPathComponent()) }
                catch { discoveryError = error; discovered = [] }
            }
            try wait("Xcode scheme discovery completes", seconds: 120) { discovered != nil }
            if let discoveryError { throw discoveryError }
            try expect(discovered?.contains(.init(container: URL(fileURLWithPath: project), scheme: scheme)) == true,
                       "real Xcode discovery must offer the requested project and scheme")
            let framesBeforeBuild = tile.runtime.receivedFrames
            tile.startBuild(.init(container: URL(fileURLWithPath: project), scheme: scheme))
            if env["IOS_PREVIEW_LIVE_BUILD_OCCLUSION"] == "1" {
                tile.windowOcclusionChanged(visible: false)
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                try expect(tile.isBuilding, "hiding the preview must not cancel an explicit build")
                tile.windowOcclusionChanged(visible: true)
            }
            try wait("production Build & Run completes", seconds: 950) { !tile.isBuilding }
            guard let directory = tile.buildDirectory else { throw IOSPreviewChecks.Failure(description: "build did not start") }
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("run.json"))) as? [String: Any]
            try expect(receipt?["deviceID"] as? String == device && receipt?["scheme"] as? String == scheme,
                       "production build receipt must pin scheme and exact device")
            try wait("preview remains live after build") { tile.runtime.receivedFrames > framesBeforeBuild }
            // simctl launch returns before SpringBoard's transition completes.
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            try snapshot("ios-preview-build-run-dark.png")
            window.appearance = NSAppearance(named: .aqua); tile.applyTokens()
            try snapshot("ios-preview-build-run-light.png")
            try FileManager.default.copyItem(at: directory.appendingPathComponent("run.json"), to: out.appendingPathComponent("build-run-receipt.json"))
            print("PASS: production tile builds, verifies, installs and launches the requested scheme on its selected simulator")
        }
        tile.runtime.disconnect()
        let report: [String: Any] = ["result": "PASS", "device": device, "state": state(),
            "frames": frameCount, "frontmostBefore": frontmost ?? "unknown",
            "frontmostAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("live-tile-report.json"))
        print("IOSPreviewLiveTileChecks passed: production mount/palette, verified tool installation, authenticated helper, native frames, touch/paste/rotation and detach")
    }
}
