import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Process-local audit controls. Defaults retain every candidate; no preference
/// is persisted and the environment is read only once, never in a layout loop.
enum CanvasMotionVariants {
    static let requestedValue = ProcessInfo.processInfo.environment["CANVAS_MOTION_VARIANT"] ?? "full"
    private static let parsedMask: Int? = {
        let names = ["full": 15, "baseline": 0, "no-code": 14, "no-diff": 13,
                     "no-prose": 11, "no-pacing": 7]
        if let named = names[requestedValue] { return named }
        guard let numeric = Int(requestedValue), (0...15).contains(numeric) else { return nil }
        return numeric
    }()
    static let isValid = parsedMask != nil
    static let mask = parsedMask ?? 15
    static let codeEnabled = (mask & 1) != 0
    static let diffEnabled = (mask & 2) != 0
    static let proseEnabled = (mask & 4) != 0
    static let pacingEnabled = (mask & 8) != 0
    /// Comparison arm: far parking off. Residency takes its
    /// ordinary environment override (`ARRAY_TILE_SURFACE_RESIDENCY`).
    static let farParkingEnabled = ProcessInfo.processInfo.environment["CANVAS_MOTION_FAR_PARK"] != "off"
}

/// A visible, isolated production workspace for wall-clock camera measurements.
/// The provider is an offline event source; mounting, event delivery, transcript
/// persistence, tile presentation, camera routing and AppKit display are real.
/// Motion methods only enqueue input. They never force layout, display or a CA flush.
@MainActor
final class CanvasMotionWorkload {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let canvas: CanvasNSView
    let window: NSWindow
    let inputKind = "queued-canvas-responder-scroll + command-scroll-zoom"
    /// Timestamp observer at the queued production responder's entry, not enqueue.
    /// Pointer events continue through NSApp and do not call this hook.
    var onInputDispatched: ((NSEvent) -> Void)?
    let markdownMode: String
    private let realDocumentCopies: Int
    private let appDelegate: AppDelegate
    private let browserEngine: BrowserEngineContext
    private let supervisor: AgentSupervisor
    private let emitter: CanvasMotionEmitter
    private let agentIDs: [AgentID]
    private let agentTileIDs: [UUID]
    private let markdownTileIDs: [UUID]
    private let defaults: UserDefaults
    private let defaultsName: String
    private var closed = false
    private var sentPrompts = false
    private(set) var postedInputCount = 0
    private(set) var responderDispatchedInputCount = 0
    private(set) var rejectedInputCount = 0
    private(set) var postedScrollDX = 0.0
    private(set) var postedScrollDY = 0.0
    private(set) var postedLogZoom = 0.0
    private var maximumInputAnchorError = 0.0
    private var residualPanX = 0.0
    private var residualPanY = 0.0
    private var residualZoom = 0.0
    private var pointerPanLocation: NSPoint?
    private var replaySummary: [String: Any]?
    private var bareTiles: (stripped: Int, of: Int)?
    private(set) var replayWindowSize: NSSize?

    init(root: URL, support: URL, markdownCount: Int, agentCount: Int) throws {
        let env = ProcessInfo.processInfo.environment
        guard CanvasMotionVariants.isValid else {
            throw Failure(description: "CANVAS_MOTION_VARIANT must be full, baseline, no-code, no-diff, no-prose, no-pacing or a mask from 0 through 15")
        }
        guard markdownCount >= 0, agentCount >= 0 else {
            throw Failure(description: "motion workload requires nonnegative tile counts")
        }
        guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier,
              let supportPath = env["CONTINUUM_APP_SUPPORT"],
              URL(fileURLWithPath: supportPath).standardizedFileURL == support.standardizedFileURL else {
            throw Failure(description: "motion workload requires a non-PROD process with CONTINUUM_APP_SUPPORT matching its isolated support directory")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent(".array").path),
              !fm.fileExists(atPath: support.appendingPathComponent("registry.json").path) else {
            throw Failure(description: "motion workload refuses to replace an existing project or registry")
        }
        for directory in [root, support] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let mode = env["CANVAS_MOTION_MARKDOWN_MODE"] ?? "mixed"
        guard ["preview", "split", "edit", "mixed"].contains(mode) else {
            throw Failure(description: "CANVAS_MOTION_MARKDOWN_MODE must be preview, split, edit or mixed")
        }
        markdownMode = mode
        let sections = max(1, Int(env["CANVAS_MOTION_DOCUMENT_SECTIONS"] ?? "") ?? 32)
        let turns = max(1, Int(env["CANVAS_MOTION_HISTORY_TURNS"] ?? "") ?? 12)
        var realDocument: String?
        if let path = env["CANVAS_MOTION_DOCUMENT_PATH"], markdownCount > 0 {
            let source = URL(fileURLWithPath: path)
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else {
                throw Failure(description: "CANVAS_MOTION_DOCUMENT_PATH exceeds the 1 MiB fixture cap")
            }
            let data = try Data(contentsOf: source)
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
                throw Failure(description: "CANVAS_MOTION_DOCUMENT_PATH must be UTF-8 and at most 1 MiB")
            }
            realDocument = text
        }
        realDocumentCopies = realDocument == nil ? 0 : min(markdownCount, 2)
        let now = Date()
        let workspaceID = UUID(), projectID = UUID(), zoneID = UUID()
        let startZoom = Double(env["CANVAS_MOTION_ZOOM"] ?? "").flatMap { $0 > 0.05 && $0 <= 4 ? $0 : nil } ?? 0.35
        let initialViewport = CanvasViewport(x: 0, y: 0, zoom: startZoom)
        let project = Project(
            id: projectID, name: "Canvas motion workload", rootPath: root.path,
            createdAt: now, updatedAt: now, defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors,
                                      browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning))
        let projectStore = ProjectStore(projectRoot: root)
        try projectStore.saveProject(project)

        // Four documents and four agents form the near cluster. Additional tiles
        // remain installed in the same pinned-live zone, outside the initial view.
        func frame(index: Int, agent: Bool) -> TileFrame {
            if index < 4 {
                let slot = index * 2 + (agent ? 1 : 0)
                return TileFrame(x: 120 + Double(slot % 4) * 670,
                                 y: 120 + Double(slot / 4) * 720, width: 620, height: 660)
            }
            let slot = (index - 4) * 2 + (agent ? 1 : 0)
            return TileFrame(x: 7_000 + Double(slot % 8) * 670,
                             y: 120 + Double(slot / 8) * 720, width: 620, height: 660)
        }
        var tiles: [Tile] = []
        var fileIDs: [UUID] = []
        for index in 0..<(env["CANVAS_MOTION_REPLAY"] == nil ? markdownCount : 0) {
            let path = root.appendingPathComponent(String(format: "document-%02d.md", index))
            let content = index < 2 ? (realDocument ?? Self.markdown(index: index, sections: sections))
                : Self.markdown(index: index, sections: sections)
            try content.write(to: path, atomically: true, encoding: .utf8)
            var metadata = TileMetadata()
            metadata.filePath = path.path
            metadata.markdownDocumentMode = mode == "mixed"
                ? (index.isMultiple(of: 2) ? .preview : .split)
                : MarkdownDocumentMode(rawValue: mode)
            let tile = Tile(id: UUID(), kind: .file, title: path.lastPathComponent,
                            frame: frame(index: index, agent: false), zPosition: .fromLegacyRank(tiles.count + 1),
                            zoneId: zoneID, runtimeRef: nil, metadata: metadata)
            fileIDs.append(tile.id)
            tiles.append(tile)
        }
        var managedTileIDs: [UUID] = []
        for index in 0..<(env["CANVAS_MOTION_REPLAY"] == nil ? agentCount : 0) {
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "Motion agent \(index + 1)",
                            frame: frame(index: index, agent: true), zPosition: .fromLegacyRank(tiles.count + 1),
                            zoneId: zoneID, runtimeRef: nil,
                            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
            managedTileIDs.append(tile.id)
            tiles.append(tile)
        }
        // CANVAS_MOTION_REPLAY: a real workspace's layout and agents instead of the
        // synthetic grid (`scripts/canvas-motion/export-replay.py`).
        let replay = try env["CANVAS_MOTION_REPLAY"].map {
            try CanvasMotionReplay.load(spec: URL(fileURLWithPath: $0), root: root, projectID: projectID)
        }
        if let replay {
            tiles = replay.tiles
            fileIDs = replay.tiles.filter { $0.kind == .file }.map(\.id)
            managedTileIDs = replay.tiles.filter { $0.kind == .managedAgent }.map(\.id)
        }
        let viewport = replay.map { replay in
            env["CANVAS_MOTION_ZOOM"] == nil ? replay.document.viewport
                : CanvasViewport(x: replay.document.viewport.x, y: replay.document.viewport.y, zoom: startZoom)
        } ?? initialViewport
        let state = CanvasState(viewport: viewport, tiles: tiles, groups: [], lastActiveTileId: nil)
        try projectStore.saveCanvas(state)
        let zone = replay?.document.zones.first ?? ZonePlacement(zoneId: zoneID, projectId: projectID,
                                 origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 14_000, height: 12_000),
                                 color: "blue", collapsed: false, hydrationPolicy: .pinnedLive)
        var document = replay?.document ?? WorkspaceDocument(viewport: initialViewport, zones: [zone],
                                         zoneZOrder: [zoneID], lastActiveZoneId: zoneID)
        document.viewport = viewport
        try WorkspaceStore(workspaceId: workspaceID, applicationSupportDirectory: support).save(document)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceID
        registry.workspaces = [WorkspaceEntry(id: workspaceID, name: "Canvas motion workload", projectIds: [projectID],
                                              createdAt: now, updatedAt: now)]
        registry.projects = [ProjectEntry(id: projectID, name: project.name, rootPath: root.path,
                                         workspaceId: workspaceID, lastOpenedAt: now, pinned: false, missing: false)]
        let registryStore = RegistryStore(applicationSupportDirectory: support)
        try registryStore.save(registry)

        let delegate = AppDelegate()
        // Boot's launch sweep arms the managed-session source; without it every
        // activity rebuild refuses and retries four times a second.
        try delegate.reconciledManagedSessionSource.reconcile(registry: registry, reason: .continuumRestarted, now: now)
        let suiteName = "dev.arrayapp.canvas-motion.\(UUID().uuidString)"
        guard let isolatedDefaults = QAIsolatedDefaults(isolatedSuiteName: suiteName) else {
            throw Failure(description: "cannot create isolated settings suite")
        }
        isolatedDefaults.set(WorkspaceToolsPermission.off.rawValue, forKey: WorkspaceToolsConfig.permissionKey)
        delegate.qaSettingsDefaults = isolatedDefaults
        delegate.qaSetMotionDefaults(isolatedDefaults)
        let events = CanvasMotionEmitter()
        let agents = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: { launch in events.runner(for: launch.record.id) },
            claudeSessionTitle: { _, _ in nil },
            transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
        delegate.agentSupervisor = agents
        agents.workspaceToolsPermission = { .off }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(
            harness: .codex, readiness: .ready, models: ["fixture/canvas-motion"],
            displayNames: ["fixture/canvas-motion": "Offline motion fixture"],
            contextWindows: ["fixture/canvas-motion": 200_000]))
        if let replay {
            // Each harness offers exactly the models its replayed agents ran.
            for harness in Set(replay.agents.values.map(\.harness)) {
                let models = Array(Set(replay.agents.values.filter { $0.harness == harness }.map(\.model))).sorted()
                AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: harness, readiness: .ready, models: models))
            }
        }
        var ids: [AgentID] = []
        var replayHistory: [String: Any] = [:]
        for (index, tileID) in managedTileIDs.enumerated() {
            if let source = replay?.agents[tileID] {
                let id = agents.spawn(role: nil, prompt: nil, cwd: root, harness: source.harness,
                                      model: source.model, thinking: "low",
                                      projectId: projectID, projectRoot: root, tileId: tileID,
                                      displayName: source.name)
                // The history the app shows at boot: rebuilt from the CLI's own
                // session log of the ORIGINAL agent, read only.
                let history = source.rehydrate()
                if let history { agents.seedRehydratedTranscript(history, for: id) }
                replayHistory[tileID.uuidString] = history.map { ["steps": $0.steps.count,
                    "messages": $0.restoredMessageCount, "omittedEarlier": $0.omittedEarlier] } ?? NSNull()
                ids.append(id)
                continue
            }
            let id = agents.spawn(role: nil, prompt: nil, cwd: root, harness: .codex,
                                  model: "fixture/canvas-motion", thinking: "low",
                                  projectId: projectID, projectRoot: root, tileId: tileID,
                                  displayName: "Motion agent \(index + 1)")
            agents.seedRehydratedTranscript(Self.history(index: index, turns: turns), for: id)
            ids.append(id)
        }

        let browser = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { requested in
            guard requested == projectID else { throw Failure(description: "unexpected workload project") }
            return ZoneRuntimeController(projectRoot: root, projectStore: projectStore, project: project)
        })
        let runtime = WorkspaceRuntime(boot: try zoneRegistry.acquire(projectId: projectID),
                                       workspaceId: workspaceID, document: document, registry: zoneRegistry,
                                       focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
                                       ghostty: nil, browserEngine: browser)
        let scene = CanvasNSView(canvasState: state, activeZone: zone,
                                 zoneRenderModels: document.zones.map { .init(placement: $0, displayName: $0.name) })
        let windowSize = replay?.window ?? NSSize(width: 1280, height: 800)
        scene.frame = NSRect(origin: .zero, size: windowSize)
        if env["CANVAS_MOTION_NATIVE_PREVIEWS"] == "1" { scene.filePreviewResidencyEnabled = false }
        scene.farParkingEnabled = CanvasMotionVariants.farParkingEnabled
        delegate.wireCanvasCallbacks(scene)
        delegate.qaPrepareForBootMountCheck(canvas: scene, browserEngine: browser,
                                            runtime: runtime, registryStore: registryStore)
        let spawner = TileSpawner(canvasView: scene, ghostty: nil, browserEngine: browser,
                                  projectStore: projectStore, project: project)
        try delegate.mountWorkspaceSceneAtBoot(canvasView: scene, spawner: spawner,
                                               projectStore: projectStore, canvasState: state,
                                               installsGlobalEventMonitors: true)
        for (index, tileID) in managedTileIDs.enumerated() {
            guard let view = scene.tileView(for: tileID) as? ManagedAgentTileNSView else {
                // A replayed zone below the live hydration tier installs no tiles at
                // boot, exactly as in the app; its agents run tile-less.
                if replay != nil { continue }
                throw Failure(description: "production mount did not install agent tile \(index)")
            }
            if view.attachedAgentID != ids[index] { delegate.wireManagedAgentTile(tileID, agentID: ids[index]) }
            guard view.attachedAgentID == ids[index] else {
                throw Failure(description: "production mount did not attach agent \(index)")
            }
        }
        guard replay != nil || fileIDs.allSatisfy({ scene.tileView(for: $0) is FileTileNSView }) else {
            throw Failure(description: "production mount did not install every Markdown tile")
        }
        let host = delegate.makeWorkspaceWindow(canvasView: scene, title: "Array Dev — live canvas performance")
        host.isReleasedWhenClosed = false
        delegate.qaAttachWindowForOfflineCheck(host)
        canvas = scene
        window = host
        appDelegate = delegate
        browserEngine = browser
        supervisor = agents
        emitter = events
        agentIDs = ids
        events.deltaIntervalMs = max(5, Int(env["CANVAS_MOTION_DELTA_MS"] ?? "") ?? 50)
        // CANVAS_MOTION_STREAMING_AGENTS=k: the k agents nearest the camera stream.
        if let count = Int(env["CANVAS_MOTION_STREAMING_AGENTS"] ?? ""), count < ids.count {
            let center = CGPoint(x: viewport.x + windowSize.width / 2 / viewport.zoom,
                                 y: viewport.y + windowSize.height / 2 / viewport.zoom)
            func distance(_ tileID: UUID) -> Double {
                guard let frame = scene.tileView(for: tileID)?.tile.frame else { return .infinity }
                return hypot(frame.x + frame.width / 2 - center.x, frame.y + frame.height / 2 - center.y)
            }
            let nearest = zip(managedTileIDs, ids).sorted { distance($0.0) < distance($1.0) }.prefix(max(0, count))
            events.streaming = Set(nearest.map(\.1))
        }
        replayWindowSize = replay?.window
        replaySummary = replay.map { replay in
            ["source": replay.source, "zones": replay.document.zones.count, "tiles": replay.tiles.count,
             "agents": replay.agents.count, "omitted": replay.omitted, "history": replayHistory,
             "window": ["width": windowSize.width, "height": windowSize.height]]
        }
        agentTileIDs = managedTileIDs
        markdownTileIDs = fileIDs
        defaults = isolatedDefaults
        defaultsName = suiteName
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(scene)
        NSApp.activate(ignoringOtherApps: true)
        // Construction only. All measured rendering is the ordinary AppKit cycle.
        scene.layoutSubtreeIfNeeded()
    }

    /// Starts held offline runners and positions their real transcript views,
    /// without emitting provider chunks during static scene warmup.
    /// `CANVAS_MOTION_BARE_TILES=1`, after warmup: every surfaced agent tile becomes
    /// its one surface view, to measure the zoom ceiling with one view per tile.
    func stripTilesIfRequested() {
        guard ProcessInfo.processInfo.environment["CANVAS_MOTION_BARE_TILES"] == "1" else { return }
        let agents = agentTileIDs.compactMap { canvas.tileView(for: $0) }
        bareTiles = (stripped: agents.filter { $0.qaStripToSurfaceForMotionCeiling() }.count, of: agents.count)
        // `CANVAS_MOTION_BARE_TILES_ALL=1`: also take every tile that is not a lone surface out of the plane,
        // leaving only one view per remaining tile.
        guard ProcessInfo.processInfo.environment["CANVAS_MOTION_BARE_TILES_ALL"] == "1" else { return }
        for view in canvas.worldPlane.subviews.compactMap({ $0 as? TileNSView })
        where view.surfaceResidency != .surfaced || view.subviews.count > 1 {
            view.removeFromSuperview()
            bareRemoved += 1
        }
    }
    private(set) var bareRemoved = 0

    func prepareStreaming() {
        guard !closed else { return }
        if !sentPrompts {
            let streaming = emitter.streamingIDs
            for (id, tileID) in zip(agentIDs, agentTileIDs) where streaming?.contains(id) ?? true {
                if !supervisor.send("Continue reviewing the canvas rendering path and show the next implementation detail.", to: id) {
                    rejectedInputCount += 1
                }
                // The real user action arms the transcript's ordinary
                // near-bottom policy before live provider events begin.
                (canvas.tileView(for: tileID) as? ManagedAgentTileNSView)?
                    .qaTranscriptForChecks?.jumpToLatest()
            }
            sentPrompts = true
        }
    }

    /// A fixed provider budget prevents a slower main thread from receiving a
    /// longer transcript than a faster comparison run. The source finishes on
    /// its own background clock, independently of the main actor's drain time.
    func startStreaming(delay: TimeInterval = 0, tickLimit: Int = 120) {
        guard !closed else { return }
        prepareStreaming()
        emitter.start(delay: delay, tickLimit: tickLimit)
    }

    /// Ends the fixture's measured turn and queues its final delivery witness.
    /// The normal turnCompleted boundary flushes the supervisor's pending
    /// streaming markup; an idle contentDelta alone deliberately does not.
    /// Runner processes themselves are stopped only during close().
    func stopStreaming() { emitter.stop() }

    /// Agents the source streams into (all of them unless the run picked a subset).
    var streamingAgentCount: Int { emitter.streamingCount ?? agentIDs.count }

    /// Call only outside measured motion, after stopStreaming(). This reads the
    /// real semantic projections; it does not flush their pending event queues.
    var hasDeliveredStreamingSource: Bool {
        streamDeliveryWitnesses().allSatisfy { $0["finalSourceDelivered"] as? Bool == true }
    }

    private func streamDeliveryWitnesses() -> [[String: Any]] {
        let progress = emitter.deliveryProgress()
        func latestAssistant(_ document: AgentDocument?) -> (text: String, revision: UInt64) {
            guard let entry = document?.entries.last(where: { $0.role == .assistant }) else { return ("", 0) }
            return (AgentTranscriptCopyController.plainText(for: entry.blocks), entry.revision)
        }
        func marker(_ prefix: String, in text: String) -> Int {
            guard let range = text.range(of: prefix, options: .backwards) else { return -1 }
            return Int(text[range.upperBound...].prefix(while: { $0.isNumber })) ?? -1
        }
        let streaming = emitter.streamingIDs
        return zip(agentIDs, agentTileIDs).filter { streaming?.contains($0.0) ?? true }.map { id, tileID in
            let tile = canvas.tileView(for: tileID) as? ManagedAgentTileNSView
            let local = latestAssistant(tile?.qaDocumentForChecks)
            let durable = latestAssistant(supervisor.transcriptDocumentProjection(for: id))
            let produced = progress[id]?.deltas ?? 0
            let expected = produced >= 8 ? (produced / 8) * 8 - 1 : -1
            let expectedFinal = progress[id]?.finalMarker ?? -1
            let tileMarker = marker("motion-stream-", in: local.text)
            let supervisorMarker = marker("motion-stream-", in: durable.text)
            let tileFinal = marker("motion-final-", in: local.text)
            let supervisorFinal = marker("motion-final-", in: durable.text)
            let sourceFinal = marker("motion-final-", in: supervisor.latestAssistantLine(for: id) ?? "")
            let textsMatch = !local.text.isEmpty && local.text == durable.text
            return [
                "agentID": id.rawValue.uuidString, "sourceDeltas": produced,
                "expectedMarker": expected, "tileLastMarker": tileMarker,
                "supervisorLastMarker": supervisorMarker,
                "tileLatestRevision": local.revision, "supervisorLatestRevision": durable.revision,
                "latestSemanticTextMatches": textsMatch,
                "expectedFinalMarker": expectedFinal, "tileFinalMarker": tileFinal,
                "supervisorFinalMarker": supervisorFinal,
                "supervisorRawSourceFinalMarker": sourceFinal,
                "finalSourceDelivered": expectedFinal >= 0 && tileFinal == expectedFinal
                    && supervisorFinal == expectedFinal && textsMatch
            ] as [String: Any]
        }
    }

    /// Pixel-scroll deltas, with the same sign convention as CanvasNSView.scrollWheel.
    func postPan(dx: Double, dy: Double) {
        residualPanX += dx
        residualPanY += dy
        guard let event = scrollEvent(dx: residualPanX, dy: residualPanY, command: false) else { return }
        residualPanX -= Double(event.scrollingDeltaX)
        residualPanY -= Double(event.scrollingDeltaY)
        postedScrollDX += Double(event.scrollingDeltaX)
        postedScrollDY += Double(event.scrollingDeltaY)
        post(event)
    }

    /// Command-scroll zoom, NOT a fabricated native pinch. `delta` is a fractional
    /// zoom change: 0.01 requests ×1.01. Public fixed-point event fields retain
    /// fractional wheel motion where AppKit supports it; residuals carry any
    /// delivered quantization forward, and the snapshot reports actual input.
    func postMagnify(delta: Double) {
        guard delta.isFinite, delta > -1 else { rejectedInputCount += 1; return }
        residualZoom += log1p(delta) / canvas.cameraDriver.tuning.scrollZoomGain
        guard let event = scrollEvent(dx: 0, dy: residualZoom, command: true) else { return }
        let actual = Double(event.scrollingDeltaY)
        residualZoom -= actual
        postedLogZoom += actual * canvas.cameraDriver.tuning.scrollZoomGain
        post(event)
    }

    /// Scroll replay enters the canvas responder directly, so finding a blank
    /// tile-free point is unnecessary and would add fixture hit testing per event.
    /// Keep this canvas-local anchor fixed throughout every variant and gesture.
    var inputPointInWindow: NSPoint {
        canvas.convert(CGPoint(x: 12, y: 12), to: nil)
    }

    var inputPointInScreen: NSPoint { window.convertPoint(toScreen: inputPointInWindow) }

    func beginPointerPan() {
        let point = inputPointInWindow
        pointerPanLocation = point
        postMouse(.leftMouseDown, location: point)
    }

    /// Pointer delta in window coordinates (positive y goes up).
    func postPointerPan(dx: Double, dy: Double) {
        guard var point = pointerPanLocation else { return }
        point.x += dx; point.y += dy
        pointerPanLocation = point
        postMouse(.leftMouseDragged, location: point)
    }

    func endPointerPan() {
        guard let point = pointerPanLocation else { return }
        postMouse(.leftMouseUp, location: point)
        pointerPanLocation = nil
    }

    private func postMouse(_ type: NSEvent.EventType, location: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: postedInputCount + 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1) else { rejectedInputCount += 1; return }
        post(event)
    }

    private func post(_ event: NSEvent) {
        guard !closed else { return }
        postedInputCount += 1
        if event.type == .scrollWheel {
            // NSEvent(cgEvent:) does not attach a window on this OS, even with
            // the documented CG window-under-pointer fields. A public queued
            // responder call preserves the production scroll/driver/display
            // path without claiming a WindowServer or NSApp routing witness.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.responderDispatchedInputCount += 1
                self.onInputDispatched?(event)
                self.canvas.scrollWheel(with: event)
            }
        } else {
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func scrollEvent(dx: Double, dy: Double, command: Bool) -> NSEvent? {
        guard dx.isFinite, dy.isFinite else { rejectedInputCount += 1; return nil }
        let desired = inputPointInWindow
        let screenPoint = window.convertPoint(toScreen: desired)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func make(_ units: CGScrollEventUnit) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                   wheel1: Int32(clamping: Int(dy.rounded())),
                                   wheel2: Int32(clamping: Int(dx.rounded())), wheel3: 0) else { return nil }
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            cg.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            cg.flags = command ? .maskCommand : []
            cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            guard let event = NSEvent(cgEvent: cg) else { return nil }
            if event.window !== window {
                // A window-less NSEvent reports a screen point as its
                // locationInWindow. The responder expects a window-local
                // anchor. Correct that public coordinate before enqueueing.
                let actual = event.locationInWindow
                cg.location.x += desired.x - actual.x
                cg.location.y -= desired.y - actual.y
                return NSEvent(cgEvent: cg)
            }
            return event
        }
        var event = make(.pixel)
        // Cmd-scroll has the same gain for wheel and precise devices. A line
        // event may preserve a subpixel fixed-point delta that the pixel form
        // rounds; both reach the production canvas responder at the same anchor.
        if command, let line = make(.line),
           abs(Double(line.scrollingDeltaY) - dy) < abs(Double(event?.scrollingDeltaY ?? 0) - dy) {
            event = line
        }
        guard let event,
              event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return nil }
        maximumInputAnchorError = max(maximumInputAnchorError,
            hypot(event.locationInWindow.x - desired.x, event.locationInWindow.y - desired.y))
        return event
    }

    /// Sample outside the measured input loop: semantic scans are intentionally
    /// absent from per-frame instrumentation.
    func snapshot() -> [String: Any] {
        let tiles = canvas.tileViewsInVisualOrder
        let agents = agentTileIDs.compactMap { canvas.tileView(for: $0) as? ManagedAgentTileNSView }
        let documents = agents.map(\.qaDocumentForChecks)
        let supervisorDocuments = agentIDs.compactMap { supervisor.transcriptDocumentProjection(for: $0) }
        let source = emitter.snapshot()
        return [
            "protocolTag": "fixed-anchor-finite-source-v3",
            "variantName": CanvasMotionVariants.requestedValue, "variantMask": CanvasMotionVariants.mask,
            "inputKind": inputKind, "markdownMode": markdownMode, "realDocumentCopies": realDocumentCopies,
            "installedTiles": tiles.count, "visibleTiles": canvas.visibleTileViews.count,
            "markdownTiles": markdownTileIDs.count, "agentTiles": agents.count,
            "attachedAgents": agents.filter(\.isAttachedToAgent).count,
            "agentNearBottom": agents.map { $0.qaTranscriptForChecks?.qaIsNearBottom ?? false },
            "agentShowsJumpToLatest": agents.map { $0.qaTranscriptForChecks?.qaShowsJumpToLatest ?? false },
            "nativeTiles": tiles.filter { $0.surfaceResidency == .native }.count,
            "surfacedTiles": canvas.qaTrackedSurfacedTileCount,
            "surfaceBytes": canvas.qaTotalSurfaceBytes,
            "filePreviewResidency": canvas.filePreviewResidencyEnabled,
            "agentSurfaceResidency": canvas.surfaceResidencyEnabled,
            "farParking": canvas.farParkingEnabled,
            "replay": replaySummary as Any? ?? NSNull(),
            "bareTiles": bareTiles.map { ["stripped": $0.stripped, "of": $0.of, "removed": bareRemoved] } as Any? ?? NSNull(),
            "streamingAgents": emitter.streamingCount ?? agentIDs.count,
            "farParkedTiles": canvas.qaFarParkedTileCount,
            "lastGestureReport": canvas.qaLastGestureReport?.summary as Any? ?? NSNull(),
            "work": canvas.qaFrameWorkCounters,
            "viewportApplies": canvas.qaViewportApplyCount,
            "viewport": ["x": canvas.viewport.x, "y": canvas.viewport.y, "zoom": canvas.viewport.zoom],
            "postedInputs": postedInputCount, "rejectedInputs": rejectedInputCount,
            "responderDispatchedInputs": responderDispatchedInputCount,
            "scrollInputRoute": "main-queue to CanvasNSView.scrollWheel production responder",
            "pointerInputRoute": "NSApp.postEvent",
            "maximumInputAnchorErrorPoints": maximumInputAnchorError,
            "postedPanDX": postedScrollDX, "postedPanDY": postedScrollDY,
            "postedLogZoom": postedLogZoom, "remainingZoomWheelUnits": residualZoom,
            "tileLayoutPasses": canvas.qaTotalTileLayoutPassCount,
            "transcriptLayoutPasses": canvas.qaTotalTranscriptLayoutPassCount,
            "markdownMeasurePasses": FileMarkdownDocumentView.qaTotalMeasurePasses,
            "proseMeasurements": AssistantProseView.qaMeasurementCount,
            "codeHeightMeasurements": CodeTextView.qaUnwrappedMeasurementCount,
            "agentDocumentVersions": documents.map(\.version),
            "agentDocumentEntries": documents.map { $0.entries.count },
            "supervisorDocumentVersions": supervisorDocuments.map(\.version),
            "supervisorDocumentEntries": supervisorDocuments.map { $0.entries.count },
            "agentDocumentEncodedBytes": documents.map { (try? JSONEncoder().encode($0).count) ?? 0 },
            "agentSourceDelivery": streamDeliveryWitnesses(),
            "source": source,
            "windowVisible": window.isVisible, "windowKey": window.isKeyWindow,
            "appActive": NSApp.isActive,
            "windowOcclusionVisible": window.occlusionState.contains(.visible),
            "backingScale": window.backingScaleFactor,
            "screenMaximumFPS": window.screen?.maximumFramesPerSecond ?? 0
        ]
    }

    func close() {
        guard !closed else { return }
        closed = true
        emitter.stop()
        supervisor.stopAll()
        _ = appDelegate.qaQuitForRemount()
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        browserEngine.shutdown()
        defaults.removePersistentDomain(forName: defaultsName)
    }

    func teardown() { close() }

    private static func markdown(index: Int, sections: Int) -> String {
        var text = "# Canvas architecture review \(index + 1)\n\n"
        for section in 0..<sections {
            text += "## Rendering path \(section + 1)\n\n```swift\n"
            for line in 0..<12 {
                text += "let candidate\(line) = tiles.filter { $0.frame.intersects(viewport) } // section \(section)\n"
            }
            text += "```\n\n"
            text += String(repeating: "The retained canvas preserves **document detail**, `world coordinates`, and the ordering of visible updates. A camera move should leave logical text width unchanged. ", count: 4)
            text += "\n\n- Inspect the visible working set.\n- Measure queued input and delivered frames.\n- Preserve focus and scroll position.\n\n"
            if section.isMultiple(of: 4) {
                text += "| Component | Expected work | Evidence |\n| --- | --- | --- |\n| Camera | One committed viewport | Independent geometry oracle |\n| Document | Stable logical width | Text measurement counts |\n\n"
            }
        }
        return text
    }

    private static func history(index: Int, turns: Int) -> RehydratedTranscript {
        let thread = "motion-history-\(index)"
        var steps: [RehydratedTranscriptStep] = []
        for turn in 0..<turns {
            let id = "history-\(index)-\(turn)"
            steps.append(.userPrompt("Review rendering path \(turn) and explain its scaling."))
            steps.append(.event(.turnStarted(threadId: thread, turnId: id)))
            steps.append(.event(.contentDelta(threadId: thread, turnId: id, streamKind: .assistant,
                delta: "The visible content stays complete while the camera moves.\n\n```swift\n"
                    + (0..<12).map { "let item\($0) = viewport.contains(point\($0))" }.joined(separator: "\n")
                    + "\n```\n\n" + String(repeating: "I verified logical bounds, scroll continuity, and content revisions. ", count: 8))))
            steps.append(.event(.itemStarted(threadId: thread, itemId: id + "-tool", kind: .commandExecution, title: "Inspect render counters")))
            steps.append(.event(.contentDelta(threadId: thread, turnId: id, streamKind: .commandOutput,
                                             delta: "Layout oracle passed. Content stayed current.\n")))
            steps.append(.event(.itemCompleted(threadId: thread, itemId: id + "-tool", kind: .commandExecution, status: .completed)))
            steps.append(.event(.turnCompleted(threadId: thread, turnId: id, outcome: .completed, errorMessage: nil)))
        }
        return RehydratedTranscript(steps: steps, restoredMessageCount: turns * 2, omittedEarlier: false)
    }
}

/// Wall-clock provider work continues independently when the main actor stalls.
/// `ScriptedAgentRunner.emit` reaches AgentSupervisor's normal delivery queue;
/// no tile or parser is called directly.
private final class CanvasMotionEmitter: @unchecked Sendable {
    private struct Entry {
        let runner: ScriptedAgentRunner
        let thread: String
        let turn: String
        var started = false
        var deltas = 0
        var bytes = 0
        var finalMarker: Int?
        var finalBoundary = false
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "array.canvas-motion.fixture-provider", qos: .userInitiated)
    private var entries: [AgentID: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var attemptedTicks = 0
    private var tickLimit = 0
    private var sourceStarted = false
    private var sourceFinished = false
    private var finalized = false
    private var firstTickUptime: TimeInterval?
    /// Agents that stream; nil streams all. The rest stay attached and idle.
    var streaming: Set<AgentID>?
    /// Milliseconds between deltas per streaming agent (`CANVAS_MOTION_DELTA_MS`).
    var deltaIntervalMs = 50
    private var lastTickUptime: TimeInterval?

    func runner(for id: AgentID) -> ScriptedAgentRunner {
        lock.withLock {
            if let entry = entries[id] { return entry.runner }
            let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)], holdUntilStopped: true)
            entries[id] = Entry(runner: runner, thread: "motion-\(id.rawValue.uuidString)", turn: "live-\(id.rawValue.uuidString)")
            return runner
        }
    }

    func start(delay: TimeInterval, tickLimit: Int) {
        lock.withLock {
            guard !sourceStarted, !finalized else { return }
            sourceStarted = true
            self.tickLimit = max(0, tickLimit)
            guard self.tickLimit > 0 else { sourceFinished = true; return }
            let next = DispatchSource.makeTimerSource(queue: queue)
            let startDelay = delay.isFinite ? max(0, delay) : 0
            next.schedule(deadline: .now() + startDelay + 0.05,
                          repeating: .milliseconds(deltaIntervalMs), leeway: .milliseconds(1))
            next.setEventHandler { [weak self] in self?.tick() }
            timer = next
            next.resume()
        }
    }

    func stop() {
        lock.withLock {
            guard !finalized else { return }
            finalized = true
            timer?.cancel()
            timer = nil
            // A diagnostic delta after measured motion proves receipt of the
            // final partial eight-chunk cycle, too. It uses the same provider
            // delivery path and never calls a tile or parser directly.
            for id in Array(entries.keys) {
                guard var entry = entries[id], entry.started else { continue }
                let delta = "\n\nmotion-final-\(entry.deltas)\n\n"
                if entry.runner.emit(.contentDelta(threadId: entry.thread, turnId: entry.turn,
                                                    streamKind: .assistant, delta: delta)) {
                    entry.finalMarker = entry.deltas
                    entry.bytes += delta.utf8.count
                    // The supervisor intentionally has no idle markup timer.
                    // Complete the offline turn through its ordinary provider
                    // boundary after every measured motion phase has ended.
                    entry.finalBoundary = entry.runner.emit(.turnCompleted(
                        threadId: entry.thread, turnId: entry.turn,
                        outcome: .completed, errorMessage: nil))
                }
                entries[id] = entry
            }
        }
    }

    var streamingCount: Int? { lock.withLock { streaming?.count } }
    var streamingIDs: Set<AgentID>? { lock.withLock { streaming } }

    func deliveryProgress() -> [AgentID: (deltas: Int, finalMarker: Int?)] {
        lock.withLock { entries.mapValues { (deltas: $0.deltas, finalMarker: $0.finalMarker) } }
    }

    private func tick() {
        lock.withLock {
            guard !finalized, !sourceFinished, attemptedTicks < tickLimit else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if firstTickUptime == nil { firstTickUptime = now }
            lastTickUptime = now
            attemptedTicks += 1
            for id in Array(entries.keys) where streaming?.contains(id) ?? true {
                guard var entry = entries[id] else { continue }
                if !entry.started {
                    guard entry.runner.emit(.turnStarted(threadId: entry.thread, turnId: entry.turn)) else { continue }
                    entry.started = true
                }
                let chunks = [
                    "\n\nI am checking the visible rendering path and its update cost. ",
                    "The document retains its logical width while the camera changes. ",
                    "\n\n```swift\n", "let visible = tiles.filter { tile in\n",
                    "    tile.frame.intersects(viewport)\n", "}\n", "```\n\n",
                    "The source witness is motion-stream-\(entry.deltas). "
                ]
                let delta = chunks[entry.deltas % chunks.count]
                if entry.runner.emit(.contentDelta(threadId: entry.thread, turnId: entry.turn,
                                                    streamKind: .assistant, delta: delta)) {
                    entry.deltas += 1
                    entry.bytes += delta.utf8.count
                }
                entries[id] = entry
            }
            if attemptedTicks == tickLimit {
                timer?.cancel()
                timer = nil
                sourceFinished = true
            }
        }
    }

    func snapshot() -> [String: Any] {
        lock.withLock {
            ["timerRunning": timer != nil, "ticks": attemptedTicks, "runners": entries.count,
             "tickLimit": tickLimit, "sourceStarted": sourceStarted, "sourceFinished": sourceFinished,
             "finalized": finalized, "firstTickUptimeSeconds": firstTickUptime as Any? ?? NSNull(),
             "lastTickUptimeSeconds": lastTickUptime as Any? ?? NSNull(),
             "activeRunners": entries.values.filter { $0.runner.runCount > 0 && $0.runner.completedRuns == 0 }.count,
             "successfulDeltas": entries.values.reduce(0) { $0 + $1.deltas },
             "finalWitnessEvents": entries.values.filter { $0.finalMarker != nil }.count,
             "finalWitnessBoundaries": entries.values.filter(\.finalBoundary).count,
             "emittedUTF8Bytes": entries.values.reduce(0) { $0 + $1.bytes },
             "deltasPerAgent": entries.filter { streaming?.contains($0.key) ?? true }.values.map(\.deltas),
             "deltasByAgentID": Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue.uuidString, $0.value.deltas) })]
        }
    }
}

/// A real workspace for `--canvas-motion-probe` (`CANVAS_MOTION_REPLAY=<spec.json>`),
/// exported read-only by `scripts/canvas-motion/export-replay.py`: the zones, tile
/// kinds, frames and camera exactly as the user left them. Every path is rewritten
/// into the disposable replay root; nothing here can reach the source project.
struct CanvasMotionReplay {
    struct Agent {
        let sourceID: UUID
        let harness: AgentHarness
        let model: String
        let cwd: String
        let providerSessionId: String?
        let codexThreadId: String?
        let name: String

        /// What the app restores at boot, from the original agent's CLI session
        /// log under the real home directory. Read only.
        func rehydrate() -> RehydratedTranscript? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return ManagedTranscriptRehydrator.rehydrate(.init(
                agentUUID: sourceID, cwd: cwd, model: model, harness: harness,
                claudeCLIAvailable: false, homeURL: home, codexThreadId: codexThreadId,
                codexHomeURL: home.appendingPathComponent(".codex", isDirectory: true),
                claudeSessionId: providerSessionId))
        }
    }

    let source: [String: Any]
    let document: WorkspaceDocument
    let tiles: [Tile]
    let agents: [UUID: Agent]
    let window: NSSize?
    let omitted: [[String: Any]]

    static func load(spec url: URL, root: URL, projectID: UUID) throws -> CanvasMotionReplay {
        struct Bad: Error, CustomStringConvertible { let description: String }
        guard let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let documentJSON = spec["document"], let tilesJSON = spec["tiles"] as? [[String: Any]] else {
            throw Bad(description: "replay spec \(url.path) has no document or tiles")
        }
        let decoder = JSONDecoder()
        var document = try decoder.decode(WorkspaceDocument.self,
                                          from: JSONSerialization.data(withJSONObject: documentJSON))
        for index in document.zones.indices { document.zones[index].projectId = projectID }
        let files = spec["files"] as? [String: String] ?? [:]
        var tiles: [Tile] = []
        for json in tilesJSON {
            var tile = try decoder.decode(Tile.self, from: JSONSerialization.data(withJSONObject: json))
            let original = tile.metadata
            switch tile.kind {
            case .managedAgent:
                tile.metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
            case .file:
                guard let relative = files[tile.id.uuidString] else { continue }
                let source = url.deletingLastPathComponent().appendingPathComponent(relative)
                let destination = root.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                var metadata = TileMetadata()
                metadata.filePath = destination.path
                metadata.markdownDocumentMode = original.markdownDocumentMode
                tile.metadata = metadata
            default:
                continue
            }
            tiles.append(tile)
        }
        var agents: [UUID: Agent] = [:]
        for (tileID, value) in spec["agents"] as? [String: [String: Any]] ?? [:] {
            guard let tile = UUID(uuidString: tileID), let id = (value["id"] as? String).flatMap(UUID.init),
                  let harness = (value["harness"] as? String).flatMap(AgentHarness.init(rawValue:)),
                  let model = value["model"] as? String, let cwd = value["cwd"] as? String else {
                throw Bad(description: "replay agent for tile \(tileID) is incomplete")
            }
            agents[tile] = Agent(sourceID: id, harness: harness, model: model, cwd: cwd,
                                 providerSessionId: value["providerSessionId"] as? String,
                                 codexThreadId: value["codexThreadId"] as? String,
                                 name: value["displayName"] as? String ?? model)
        }
        let window = (spec["window"] as? [String: Double]).flatMap { size in
            size["width"].flatMap { w in size["height"].map { NSSize(width: w, height: $0) } }
        }
        return CanvasMotionReplay(source: spec["source"] as? [String: Any] ?? [:], document: document,
                                  tiles: tiles, agents: agents, window: window,
                                  omitted: spec["omitted"] as? [[String: Any]] ?? [])
    }
}
