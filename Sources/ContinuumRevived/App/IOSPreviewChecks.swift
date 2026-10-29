import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Runs the production mount/spawn/restore paths with a frame/input transport
/// stand-in. No simulator, helper download, user preferences or tmux server.
@MainActor
enum IOSPreviewChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func settle(_ condition: () -> Bool, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "asynchronous preview operation at line \(line) did not settle")
    }
    final class Session: IOSPreviewSession {
        var onFrame: ((CGImage) -> Void)?
        var onFailure: ((String) -> Void)?
        var started = false
        var stopped = false
        var deferStop = false
        var stopCompletion: (@MainActor () -> Void)?
        var allowBootValues: [Bool] = []
        var messages: [(UInt8, [String: Any])] = []
        var image: CGImage
        init(image: CGImage) { self.image = image }
        func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws { allowBootValues.append(allowBoot); started = true; onFrame?(image) }
        func send(tag: UInt8, payload: [String: Any]) { messages.append((tag, payload)) }
        func stop() { stopped = true }
        func stop(completion: @escaping @MainActor () -> Void) {
            stop()
            if deferStop { stopCompletion = completion } else { completion() }
        }
        func finishStop() { let completion = stopCompletion; stopCompletion = nil; completion?() }
    }
    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 402, height: 874, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 402, height: 874))
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fill(CGRect(x: 30, y: 450, width: 340, height: 200))
        return context.makeImage()!
    }

    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-ios-tile-check-\(UUID())")
        let projectRoot = root.appendingPathComponent("Project")
        let otherRoot = root.appendingPathComponent("OtherProject")
        let support = root.appendingPathComponent("Support")
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let projectID = UUID(), otherProjectID = UUID(), workspaceA = UUID(), workspaceB = UUID(), zoneA = UUID(), zoneB = UUID()
        let tileA = UUID(), tileB = UUID(), deviceID = UUID().uuidString
        let project = Project(id: projectID, name: "Preview checks", rootPath: projectRoot.path, createdAt: now, updatedAt: now,
                              defaultLaunchProfileId: "shell", editorPreference: .auto,
                              settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: projectRoot)
        try store.saveProject(project)
        let first = Tile(id: tileA, kind: .iosPreview, title: "iOS Preview", frame: TileFrame(x: 1240, y: 940, width: 440, height: 880),
                         zPosition: .fromLegacyRank(1), zoneId: zoneA, runtimeRef: nil, metadata: TileMetadata(iosPreviewDeviceID: deviceID))
        let second = Tile(id: tileB, kind: .iosPreview, title: "iOS Preview", frame: TileFrame(x: 3640, y: 940, width: 440, height: 880),
                          zPosition: .fromLegacyRank(2), zoneId: zoneB, runtimeRef: nil, metadata: TileMetadata())
        let hiddenID = UUID()
        let hidden = Tile(id: hiddenID, kind: .iosPreview, title: "Other workspace", frame: TileFrame(x: 7000, y: 940, width: 440, height: 880),
                          zPosition: .fromLegacyRank(2), zoneId: UUID(), runtimeRef: nil, metadata: TileMetadata())
        let persisted = CanvasState(viewport: CanvasViewport(x: 1200, y: 900, zoom: 1), tiles: [first, hidden], groups: [], lastActiveTileId: tileA)
        try store.saveCanvas(persisted)
        let otherProject = Project(id: otherProjectID, name: "Other", rootPath: otherRoot.path, createdAt: now, updatedAt: now,
                                   defaultLaunchProfileId: "shell", editorPreference: .auto, settings: project.settings)
        let otherStore = ProjectStore(projectRoot: otherRoot)
        try otherStore.saveProject(otherProject)
        try otherStore.saveCanvas(CanvasState(viewport: CanvasViewport(x: 3600, y: 900, zoom: 1), tiles: [second], groups: [], lastActiveTileId: tileB))
        func document(zone: UUID, project: UUID, x: Double) -> WorkspaceDocument {
            WorkspaceDocument(viewport: CanvasViewport(x: x, y: 900, zoom: 1),
                zones: [ZonePlacement(zoneId: zone, projectId: project, origin: ZonePoint(x: x, y: 900),
                                      size: ZoneSize(width: 1900, height: 1600), color: "blue", collapsed: false, hydrationPolicy: .automatic)],
                zoneZOrder: [zone], lastActiveZoneId: zone)
        }
        let docA = document(zone: zoneA, project: projectID, x: 1200), docB = document(zone: zoneB, project: otherProjectID, x: 3600)
        try WorkspaceStore(workspaceId: workspaceA, applicationSupportDirectory: support).save(docA)
        try WorkspaceStore(workspaceId: workspaceB, applicationSupportDirectory: support).save(docB)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceA
        registry.projects = [ProjectEntry(id: projectID, name: project.name, rootPath: projectRoot.path, workspaceId: workspaceA,
                                          lastOpenedAt: now, pinned: false, missing: false),
                             ProjectEntry(id: otherProjectID, name: "Other", rootPath: otherRoot.path, workspaceId: workspaceB,
                                          lastOpenedAt: now, pinned: false, missing: false)]
        registry.workspaces = [WorkspaceEntry(id: workspaceA, name: "A", projectIds: [projectID], createdAt: now, updatedAt: now),
                              WorkspaceEntry(id: workspaceB, name: "B", projectIds: [otherProjectID], createdAt: now, updatedAt: now)]
        let registryStore = RegistryStore(applicationSupportDirectory: support)
        try registryStore.save(registry)
        let browser = BrowserEngineContext()
        defer { browser.shutdown() }
        let controller = ZoneRuntimeController(projectRoot: projectRoot, projectStore: store, project: project)
        let otherController = ZoneRuntimeController(projectRoot: otherRoot, projectStore: otherStore, project: otherProject)
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: false, makeController: { id in id == projectID ? controller : otherController })
        let canvas = CanvasNSView(canvasState: persisted, activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        canvas.occlusionVisibilityProvider = { true }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        let delegate = AppDelegate()
        let workspace = WorkspaceRuntime(workspaceId: workspaceA, document: docA, registry: zoneRegistry,
                                         focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
                                         ghostty: nil, browserEngine: browser)
        workspace.warmSceneCapacity = 0
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browser, runtime: workspace, registryStore: registryStore)
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browser, projectStore: store, project: project)
        var sessions: [Session] = []
        let factory = IOSPreviewRuntime.sessionFactory
        IOSPreviewRuntime.sessionFactory = {
            let session = Session(image: image()); sessions.append(session); return session
        }
        defer {
            controller.releaseRuntimes()
            otherController.releaseRuntimes()
            IOSPreviewRuntime.sessionFactory = factory
        }
        // This is the shipping boot entry, never the checks-only install(into:).
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: store,
                                               canvasState: persisted, installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()
        guard let view = canvas.tileView(for: tileA) as? IOSPreviewTileNSView else {
            throw Failure(description: "production mount must materialize a real iOS preview, not a descriptor")
        }
        try expect(controller.iosPreviewRuntimes[tileA] === view.runtime, "controller must own the mounted runtime")
        try expect(view.runtime.deviceID == deviceID && sessions.isEmpty, "restore must retain exact identity without booting or connecting")
        try expect(canvas.allTilesInWorldFrames().first(where: { $0.id == tileA })?.frame == first.frame,
                   "mount must retain the preview world frame at a nonzero zone origin")
        view.runtime.connect()
        try settle { view.runtime.state == .connected }
        try expect(view.screen.image?.width == 402 && view.runtime.receivedFrames == 1, "fixture pixels must reach the actual native tile")
        guard let session = sessions.first else { throw Failure(description: "missing fixture session") }
        let rect = view.screen.screenRect
        let point = view.screen.convert(CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.75), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        view.screen.mouseDown(with: event(.leftMouseDown)); view.screen.mouseUp(with: event(.leftMouseUp))
        try expect(session.messages.count == 2, "screen events must deliver exactly one contact down/up pair")
        try expect(abs((session.messages[0].1["x"] as? CGFloat ?? -1) - 0.25) < 0.001 &&
                   abs((session.messages[0].1["y"] as? CGFloat ?? -1) - 0.75) < 0.001,
                   "native tile must map letterboxed mouse coordinates; got \(session.messages), beforeRect=\(rect), afterRect=\(view.screen.screenRect)")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0)!
        view.screen.keyDown(with: key)
        _ = view.screen.resignFirstResponder()
        try expect(session.messages.count == 4 && session.messages[2].1["type"] as? String == "down" &&
                   session.messages[3].1["type"] as? String == "up" && session.messages[3].1["usage"] as? Int == 4,
                   "losing native focus must release an ordinary held keyboard key")
        try IOSPreviewInputChecks.run(view: view, session: session)
        try IOSPreviewEdgeChecks.input(view: view, canvas: canvas, window: window, session: session)

        let duplicate = IOSPreviewRuntime(tileID: UUID(), deviceID: deviceID)
        duplicate.connect()
        if case .failed = duplicate.state {} else { throw Failure(description: "two previews must not compete for one device") }
        try expect(sessions.count == 1, "duplicate device must not start a second helper")
        let stale = session.onFrame
        view.prepareForParking()
        try expect(session.stopped, "parking must detach the viewer")
        let count = view.runtime.receivedFrames
        stale?(image())
        try expect(view.runtime.receivedFrames == count, "a retired session must not deliver stale frames")
        view.runtime.disconnect()

        let selected = UUID().uuidString
        view.selectDevice(id: selected, name: "Selected fixture simulator")
        let selectedCanvas = try store.tryLoadCanvas()
        try expect(selectedCanvas?.tiles.first(where: { $0.id == tileA })?.metadata.iosPreviewDeviceID == selected,
                   "device choice must persist through the owning project store")
        try expect(selectedCanvas?.tiles.first(where: { $0.id == hiddenID }) != nil,
                   "selection persistence must preserve tiles belonging to another workspace")

        try workspace.switchWorkspace(to: workspaceB)
        canvas.layoutSubtreeIfNeeded()
        try expect(canvas.tileView(for: tileB) is IOSPreviewTileNSView,
                   "workspace switch must hydrate the arriving preview; view=\(String(describing: canvas.tileView(for: tileB))), layers=\(canvas.installedZoneLayerIds), tiles=\(canvas.allTilesInWorldFrames().map { ($0.id, $0.kind) })")
        try workspace.switchWorkspace(to: workspaceA)
        canvas.layoutSubtreeIfNeeded()
        guard let restored = canvas.tileView(for: tileA) as? IOSPreviewTileNSView else { throw Failure(description: "return must restore a concrete preview") }
        try expect(restored.runtime.deviceID == selected && restored.runtime.state == .disconnected,
                   "return must restore selection without reconnecting")
        try expect(sessions.count == 1, "workspace switches must not launch helpers")
        try expect(canvas.allTilesInWorldFrames().first(where: { $0.id == tileA })?.frame == first.frame,
                   "hydration must not move the preview or re-tidy its zone")

        try IOSPreviewEdgeChecks.selectionRollback(view: restored, canvas: canvas, store: store, projectRoot: projectRoot)

        // Production palette path, armed zone, one target for frame/z/install.
        _ = workspace.setActiveZone(zoneA, reason: .click)
        try expect(delegate.qaPerformPaletteAction(.newIOSPreview), "palette must create a preview tile")
        let spawned = canvas.allTilesInWorldFrames().filter { $0.kind == .iosPreview && $0.id != tileA }
        guard let created = spawned.first else { throw Failure(description: "palette did not install a tile") }
        try expect(created.zoneId == zoneA && created.frame.x >= 1200 && created.frame.y >= 900,
                   "spawn must use target zone world geometry, not just stamp its ID")
        try expect(controller.iosPreviewRuntimes[created.id] != nil, "spawned runtime must be owned")
        let saved = try store.tryLoadCanvas()
        try expect(saved?.tiles.first(where: { $0.id == created.id })?.frame == created.frame,
                   "spawn must persist world frames")

        let canvasFile = projectRoot.appendingPathComponent(".array/canvas.json")
        let originalBytes = try Data(contentsOf: canvasFile)
        let beforeFailure = Set(canvas.allWorkspaceTiles().map(\.id))
        StoreFileWriter.install(.init(fault: .failFrom(1), scope: projectRoot,
                                     matching: { $0.lastPathComponent == "canvas.json" }))
        defer { StoreFileWriter.uninstall() }
        if case .success = controller.tileSpawner?.spawnIOSPreview() {
            throw Failure(description: "preview spawn must report a failed canvas write")
        }
        try expect(Set(canvas.allWorkspaceTiles().map(\.id)) == beforeFailure,
                   "failed persistence must withdraw the tile and release its viewer")
        try expect(sessions.count == 1, "failed spawn must not start a helper")
        let bytesAfterFailure = try Data(contentsOf: canvasFile)
        try expect(bytesAfterFailure == originalBytes, "failed spawn must preserve the saved canvas")
        StoreFileWriter.uninstall()

        // Warm workspace return retains the view/runtime but detaches its old
        // helper and reattaches once, without silently booting a device.
        workspace.warmSceneCapacity = 1
        restored.runtime.connect()
        try settle { restored.runtime.state == .connected }
        let warmSession = sessions.last!
        let beforeWarmReturn = sessions.count
        try workspace.switchWorkspace(to: workspaceB)
        try expect(warmSession.stopped, "warm parking must stop its old helper")
        try workspace.switchWorkspace(to: workspaceA)
        try settle { restored.runtime.state == .connected }
        try expect(canvas.tileView(for: tileA) === restored && controller.iosPreviewRuntimes[tileA] === restored.runtime,
                   "warm return must retain exactly the same concrete view/runtime owner")
        try expect(sessions.count == beforeWarmReturn + 1 && sessions.last?.allowBootValues == [false],
                   "warm return must create one helper without booting")
        restored.runtime.disconnect()

        // The app-owned attachment survives a real cold scene round trip.
        // Hydration must re-host the retained runtime, never create a helper.
        workspace.warmSceneCapacity = 0
        restored.runtime.connect(allowBoot: false)
        try settle { restored.runtime.state == .connected }
        let retainedRuntime = restored.runtime
        let retainedNative = sessions.last!
        let retainedCount = sessions.count
        let scope = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: projectID,
            checkout: CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot(projectRoot.path)))
        let attachment = try IOSPreviewAutomationSessions.shared.attach(runtime: retainedRuntime, scope: scope)
        try workspace.switchWorkspace(to: workspaceB)
        try expect(!retainedNative.stopped && retainedRuntime.state == .connected,
            "cold workspace switch must preserve the agent's one shared helper")
        try workspace.switchWorkspace(to: workspaceA)
        canvas.layoutSubtreeIfNeeded()
        guard let rehosted = canvas.tileView(for: tileA) as? IOSPreviewTileNSView else { throw Failure(description: "retained preview did not hydrate") }
        try expect(rehosted.runtime === retainedRuntime && controller.iosPreviewRuntimes[tileA] === retainedRuntime && sessions.count == retainedCount,
            "Phase B must re-host exactly the retained runtime without a second helper")
        retainedNative.onFrame?(image())
        try expect(rehosted.screen.image != nil, "new human viewer must subscribe to the retained capture")
        controller.releaseRuntimes(tileId: tileA)
        try expect(retainedNative.stopped && IOSPreviewAutomationSessions.shared.attachments[attachment.id] == nil,
            "explicit tile close must release the app attachment and native helper")
        print("IOSPreviewChecks automation scene passed: production cold switch/re-host shares one helper; explicit close releases it")

        // A retiring helper may still drain HID work after stop() returns. A
        // replacement must wait for real completion, even across another tile.
        let fenceDevice = UUID().uuidString
        let oldOwner = IOSPreviewRuntime(tileID: UUID(), deviceID: fenceDevice)
        oldOwner.connect()
        try settle { oldOwner.state == .connected }
        let retiring = sessions.last!
        retiring.deferStop = true
        oldOwner.disconnect()
        let beforeReplacement = sessions.count
        let replacement = IOSPreviewRuntime(tileID: UUID(), deviceID: fenceDevice)
        replacement.connect(allowBoot: false)
        try expect(replacement.state == .connecting && sessions.count == beforeReplacement,
                   "replacement must not start while the old helper is still draining HID")
        replacement.disconnect() // cancelled waiter must never reconnect later
        retiring.finishStop()
        try expect(sessions.count == beforeReplacement && replacement.state == .disconnected,
                   "a cancelled retirement waiter must stay disconnected")
        oldOwner.connect()
        try settle { oldOwner.state == .connected }
        let retiringAgain = sessions.last!
        retiringAgain.deferStop = true
        oldOwner.disconnect()
        replacement.connect(allowBoot: false)
        try expect(sessions.count == beforeReplacement + 1, "lease must remain held until stop completion")
        retiringAgain.finishStop()
        try settle { replacement.state == .connected }
        try expect(sessions.count == beforeReplacement + 2 && sessions.last?.allowBootValues == [false],
                   "exactly one replacement may attach after old helper exit without booting")
        replacement.disconnect()

        // Real command cancellation releases only the command this viewer owns.
        var commandCancelled = false
        let command = Task {
            do { _ = try await IOSPreviewCommands.run(["/bin/sleep", "30"]) }
            catch is CancellationError { commandCancelled = true }
            catch {}
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        command.cancel()
        try settle { commandCancelled }

        // The production decoder, including a pending callback across reset.
        let jpeg = NSBitmapImageRep(cgImage: image()).representation(using: .jpeg, properties: [:])!
        let decoder = IOSPreviewFrameDecoder()
        var staleFrame = false
        decoder.offer(jpeg) { _ in staleFrame = true }
        decoder.reset()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(!staleFrame, "reset must reject decoded frames queued by an earlier viewer")
        var lastWidth = 0
        for _ in 0..<1000 { decoder.offer(jpeg) { lastWidth = $0.width } }
        let marker = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        decoder.offer(marker.representation(using: .jpeg, properties: [:])!) { lastWidth = $0.width }
        try settle { lastWidth == 8 }
        let decoderMetrics = decoder.metrics
        try expect(decoderMetrics.compressedHighWater == 1 && decoderMetrics.presentationHighWater == 1,
                   "1000-frame burst must hold at most one pending compressed frame and presentation")
        try expect(decoderMetrics.replacedCompressed > 0 && decoderMetrics.decoded < decoderMetrics.offered,
                   "burst must replace queued compressed frames instead of decoding a backlog")
        try expect(decoderMetrics.presented > 0 && decoderMetrics.presented < 1000,
                   "main presentation must coalesce the burst")
        // A valid, very wide one-row JPEG proves dimension rejection without
        // allocating a huge bitmap or relying on ImageIO accepting corrupt SOF.
        let oversizedContext = CGContext(data: nil, width: 4097, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let oversized = NSBitmapImageRep(cgImage: oversizedContext.makeImage()!)
            .representation(using: .jpeg, properties: [:])!
        var oversizeDelivered = false
        decoder.offer(oversized) { _ in oversizeDelivered = true }
        try settle { decoder.metrics.rejectedDimensions == 1 }
        try expect(!oversizeDelivered, "oversized JPEG dimensions must be rejected before bitmap decoding")

        try IOSPreviewStreamChecks.run()
        try IOSPreviewObservationChecks.run()

        var buildCheckFinished = false
        var buildCheckError: Error?
        Task { @MainActor in
            do {
                try await IOSPreviewActionChecks.run()
                try await IOSPreviewSessionChecks.run()
                try await IOSPreviewManagedDeviceChecks.run()
                try await IOSPreviewBuildChecks.run()
                try await IOSPreviewBuildJobChecks.run()
            } catch { buildCheckError = error }
            buildCheckFinished = true
        }
        try settle { buildCheckFinished }
        if let buildCheckError { throw buildCheckError }

        // Render real production controls and tile in both appearances.
        let output = ProcessInfo.processInfo.environment["CONTINUUM_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
        if let output {
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            let rendered = (canvas.tileView(for: tileA) as? IOSPreviewTileNSView) ?? restored
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                rendered.appearance = NSAppearance(named: appearance)
                rendered.applyTokens(); rendered.layoutSubtreeIfNeeded()
                let rep = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds)!
                rendered.cacheDisplay(in: rendered.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("ios-preview-\(name).png"))
            }
        }
        print("IOSPreviewChecks passed: production mount, world-frame placement, persisted choice, frame/input delivery, exclusive ownership, parking, stale frames, workspace round trip, failed-save rollback, command cancellation and latest-frame decode")
    }
}
