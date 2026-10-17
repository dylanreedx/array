// Film harness: the director. Runs a scene's takes on a fixed film clock, one frame at
// a time, through production seams only:
//
//  - camera: `CanvasNSView.setViewport`, interpolated in log-zoom (pan weighted by
//    1/zoom so the shared screen point stays put), eased on a cubic bezier;
//  - agents: spawned post-boot by `TileSpawner.spawnManagedAgent` into their zone
//    (hazard 9: one target zone for framing and install), wired by the app, framed by
//    `applyProgrammaticTileGeometry`; their turns arrive as real `AgentRuntimeEvent`s
//    through `AgentSupervisor.qaDeliver`, and tool details through the supervisor's
//    observation fan-out. No provider process ever runs;
//  - board: the card drag is the board's own drag controller fed synthetic in-window
//    events (begin/continue/finish) AT THE POINTER, so the lift, the assignment hint
//    and the commit are the shipping ones; "advance" is the accepted-send lifecycle hook;
//  - pointer: one scripted pointer (FilmPointer.swift) the app experiences — card drags
//    and hand-grab pans are fed at its position (pans through the canvas's own
//    `beginPointerPan`/`continuePointerPan`/`endPointerPan`), pinches put it on the
//    zoom's fixed point. Each frame records it and the real views' window rects, so an
//    overlay drawn later lines up with the footage exactly;
//  - open: an agent opening a file beside itself is the claude runner's own lines
//    (`mcp__array_workspace__array_open_document` tool_use, then its tool_result) fed
//    through the production `ClaudeEventTranslator`, and the open itself is the request
//    `array-workspace-mcp` posts, handed to the host's MCP handler — so the row, the
//    grant check and the tile's placement are all production's;
//  - terminal: bytes written into a tap shell (`cat` of a FIFO, so ANSI arrives raw),
//    rendered by Ghostty for real;
//  - input (`gesture`, `click {deliver}`, `key`, `hold`, `type`): real NSEvents posted to
//    the app's own queue (FilmInput.swift), so monitors, hit-testing, first responders,
//    field editors and tracking loops are all the user's; the window is made key (never
//    the app active) so key events reach it;
//  - menus: production builds them; `FilmMenuHost` hands them to the director instead of
//    AppKit's tracking loop, which would draw on a real display. `menu` performs the
//    chosen item's own action (FilmDirectorDay.swift);
//  - adopt: tiles and zones production creates during a take (palette, ⌘3, picker,
//    a subagent chip) get scene keys after the fact;
//  - Core Animation: the window's root layer is paused and stepped on film time, so
//    every CA animation (transcript fades, ants, drag settles) plays at film rate.
//
// Wall-clock timers (transcript scheduler, streaming markup parse) are flushed
// explicitly every frame so what is on screen is decided by the film clock.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedCore
import WebKit

@MainActor
final class FilmDirector {
    struct AgentHandle {
        var tileId: UUID
        var agentId: AgentID
        var zoneId: UUID
        var threadId: String
        var turnId: String?
        var turnCount = 0
        /// The last thing delivered was assistant prose: the next `say` is a new
        /// paragraph, not a continuation of the last one.
        var proseOpen = false
    }

    struct FrameRecord {
        var index: Int
        var time: Double
        /// Film seconds (frame time plus every forward `clock` jump).
        var filmTime: Double = 0
        var viewport: CanvasViewport
        var actions: [String]
        /// Top-left window points, after this frame's actions.
        var pointer: FilmPointerState
        /// Tile key / "card:<key>" -> top-left window rect, measured from the views.
        var rects: [String: CGRect]
        /// press|release|click|dragStart|drop|panStart|panEnd|zoomStart|zoomEnd|
        /// revealStart|revealEnd.
        var events: [String]
        /// Cards whose rect is the lifted copy the pointer is carrying (witness only).
        var carried: Set<String> = []
        /// Agent tile key -> the drawn status text of its sidebar row (witness only).
        var sidebarStates: [String: String] = [:]
        /// Key caps this frame: {label, kind: press|holdStart|holdEnd|type, text?}.
        var keys: [[String: Any]] = []
        /// Menus this frame: {kind: open|choose|dismiss, title, anchor [x, y], items, path?}.
        var menus: [[String: Any]] = []
        /// Sounds production asked to play this frame (never played in a film):
        /// {sound, kind: preview|signal}.
        var sounds: [[String: Any]] = []
    }

    /// One `reveal`, as it happened (witness only): the camera before it, the viewport
    /// `framedViewportForTileJump` named just before the click, the viewport production's
    /// own reveal path handed to the cut, and the inbox selection after the click.
    struct RevealRecord {
        var agentKey: String
        var takeIndex: Int
        var at: Int
        var before: CanvasViewport
        var framed: CanvasViewport?
        var production: CanvasViewport?
        var clicked: Bool
        var selection: [UUID]
        var focusedTile: UUID?
        /// The inbox's route-active row (the "open" agent, its loudest fill) before and
        /// after the click.
        var routeBefore: UUID?
        var routeAfter: UUID?
    }

    /// One `open`, as it happened (witness only): the tile production placed, the
    /// result the workspace API reported, and the camera either side of the call.
    struct OpenRecord {
        var key: String
        var agentKey: String
        var path: String
        var toolId: String
        var takeIndex: Int
        var at: Int
        var result: ArtifactOpenResult
        var tileId: UUID
        var before: CanvasViewport
        var after: CanvasViewport
        /// The viewport production's `revealResult` would have cut to (nil: it
        /// presented no camera change); the director glides there over the action.
        var production: CanvasViewport?
    }

    let scene: FilmScene
    let delegate: AppDelegate
    let window: NSWindow
    let canvas: CanvasNSView
    let roots: FilmStager.Roots
    let log: (String) -> Void

    var agents: [String: AgentHandle] = [:]
    private(set) var reveals: [RevealRecord] = []
    private(set) var opens: [OpenRecord] = []
    /// `open`'s `as` key -> the tile production opened.
    private(set) var openedTiles: [String: UUID] = [:]
    /// `adopt`'s `as` key -> the tile / zone production created during a take.
    var adoptedTiles: [String: UUID] = [:]
    var adoptedZones: [String: UUID] = [:]
    /// Cards an agent's `array_board_apply` created, by `bind` key.
    var boundCards: [String: (board: UUID, card: UUID)] = [:]
    /// One claude stream translator per agent, as one runner process has.
    var claudeTranslators: [String: ClaudeEventTranslator] = [:]
    /// One codex app-server translator per codex agent.
    var codexTranslators: [String: CodexAppServerEventTranslator] = [:]
    /// One pi rpc translator per pi agent (FilmDirectorPi.swift).
    var piTranslators: [String: PiEventTranslator] = [:]
    private(set) var globalFrame = 0
    private(set) var firedActions: [String] = []
    var actionState: [String: Any] = [:]
    private var rootLayer: CALayer?
    private var rootBaseTime: CFTimeInterval = 0
    private var pendingTerminalTails: [String: String] = [:]
    var pendingBrowserLoads: [String: Date] = [:]
    private var terminalTaps: [String: FileHandle] = [:]
    private var activity: NSObjectProtocol?
    var pointer: FilmPointerState
    var frameEvents: [String] = []
    var frameKeys: [[String: Any]] = []
    var frameMenus: [[String: Any]] = []
    var frameSounds: [[String: Any]] = []
    /// Every sound production asked for, with its global frame (witness only).
    var soundLog: [(frame: Int, sound: String, preview: Bool)] = []
    /// The input action whose `dur` a navigation it causes glides over (`ownsNavigation`),
    /// with its frame; nil when no such action is active (a navigation then cuts).
    /// Agents whose turn just ended through their film runner (a composer send's): the
    /// supervisor unwinds the runner off the main actor, so the frame waits for it.
    var pendingRunnerCompletions: Set<String> = []
    var navigationOwner: (key: String, local: Int, duration: Int, takeIndex: Int, at: Int, label: String)?
    /// Every navigation production made during the film (witness only).
    var navigations: [NavigationRecord] = []
    /// Production callbacks waiting on the film clock (`filmSchedule`).
    var filmCallbacks: [(deadline: Double, id: Int, run: () -> Void)] = []
    var filmCallbackSerial = 0
    /// Film seconds of the last inbox re-render for clock-derived state (the nudge).
    var lastInboxClockRedraw: Double?
    /// After the first hover, every pointer move sends real mouseMoved events.
    var pointerTracked = false
    var lastMovedPoint: CGPoint?
    /// The Settings panel's throwaway defaults suite (`FilmPanelHost.defaults`).
    var settingsSuite: String?
    /// Warn once per action key, not once per frame.
    private var warned: Set<String> = []
    /// Real input (FilmInput.swift) and the modifiers `hold` keeps down.
    lazy var input = FilmInput(log: log)
    var heldModifiers: NSEvent.ModifierFlags = []
    /// The menu production handed `FilmMenuHost` and has not been chosen from yet.
    var openMenu: (menu: NSMenu, anchor: CGPoint)?
    /// Production waits (`filmDelay`) that end when the film clock reaches them.
    var filmTimers: [(deadline: Double, resume: CheckedContinuation<Void, Never>)] = []

    init(scene: FilmScene, delegate: AppDelegate, window: NSWindow, canvas: CanvasNSView,
         roots: FilmStager.Roots, log: @escaping (String) -> Void) {
        self.scene = scene
        self.delegate = delegate
        self.window = window
        self.canvas = canvas
        self.roots = roots
        self.log = log
        self.pointer = .offWindow(window.contentLayoutRect.size)
    }

    var fps: Double { Double(scene.framesPerSecond) }
    var supervisor: AgentSupervisor { delegate.qaAgentSupervisor }

    // MARK: - Window placement (before the window is ever shown)

    /// Sized to the scene and made fully transparent BEFORE it is ordered front, so a
    /// film run never shows anything on the user's screen. It cannot be parked yet:
    /// ordering a titled window front constrains it back onto a display.
    static func parkWindow(_ window: NSWindow, scene: FilmScene) {
        window.setContentSize(NSSize(width: scene.window.width, height: scene.window.height))
        window.alphaValue = 0
    }

    /// After it is on screen: off every display (macOS leaves a small corner showing;
    /// capture is per-window, so that does not matter), then opaque for capture.
    /// Ordering front constrains a window taller than the screen back onto it, so the
    /// scene's size is applied again once it is parked (nothing constrains it there).
    func parkShownWindow() {
        let parked = NSPoint(x: -6000, y: -6000)
        window.setFrameOrigin(parked)
        window.setContentSize(NSSize(width: scene.window.width, height: scene.window.height))
        window.setFrameOrigin(parked)
        window.alphaValue = 1
    }

    // MARK: - Post-boot staging

    /// Everything that must exist before frame 0: a canvas that never sleeps, agents
    /// spawned and framed, terminals and pages loaded.
    func prepare(spawnTimeout: TimeInterval = 20, settle: TimeInterval = 1.5) async throws {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Array film")
        // The window is parked off-screen and never key; without this the canvas sleeps
        // and Ghostty stops rendering.
        if window.styleMask.contains(.titled) {
            parkShownWindow()
            delegate.filmApplySidebarLayout()
        }
        canvas.occlusionVisibilityProvider = { true }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)

        guard let runtime = delegate.filmWorkspaceRuntime else { throw FilmError("no workspace runtime after boot") }
        for spec in scene.tiles where spec.kind == "agent" {
            guard let zone = scene.zone(spec.zone), let root = roots.projects[zone.project] else { continue }
            let projectId = scene.projectId(zone.project)
            let zoneId = scene.zoneId(zone.key)
            guard let spawner = runtime.controller(for: projectId)?.tileSpawner else {
                throw FilmError("agent \(spec.key): project \(zone.project) has no live spawner")
            }
            let frame = scene.worldFrame(of: spec)
            let scope = CreationScope(projectId: projectId, projectRoot: root.path, source: .zone, zoneId: zoneId)
            let harness = scene.agentHarness(spec.key)
            guard let entry = scene.catalogEntry(harness) else { throw FilmError("agent \(spec.key): no catalog entry for \(harness.rawValue)") }
            let selection = AgentLaunchSelection(harness: harness, model: entry.model, thinking: "medium")
            // Spawned where production's DEFAULT-sized tile already fits inside the zone,
            // then framed: a spawn whose default tile pokes past the zone's margin grows
            // the zone (and shifts it), and the staged zone is the shot.
            let spawnAt = Self.spawnPoint(for: frame, defaultSize: CanvasEngine.defaultFrame(for: .managedAgent),
                                          zone: scene.zoneRect(zone.key) ?? .null)
            guard case let .spawned(tileId) = spawner.spawnManagedAgent(
                at: spawnAt,
                launchSelection: selection, creationScope: scope) else {
                throw FilmError("agent \(spec.key): spawnManagedAgent refused")
            }
            delegate.wireManagedAgentTile(tileId)
            guard let agentId = supervisor.agent(forTile: tileId),
                  let view = canvas.tileView(for: tileId) as? ManagedAgentTileNSView else {
                throw FilmError("agent \(spec.key): no agent record bound to its tile")
            }
            if let name = spec.name { _ = supervisor.rename(agentID: agentId, to: name) }
            // The tile menu's "Workspace Tools" item writes through this same setter.
            if spec.workspaceTools == true { _ = supervisor.setWorkspaceToolsEnabled(agentID: agentId, true) }
            _ = canvas.applyProgrammaticTileGeometry(tileId: tileId, in: zoneId, worldFrame: frame, action: .resizeTile)
            if worldFrame(of: tileId) != frame {
                _ = canvas.applyProgrammaticTileGeometry(tileId: tileId, in: zoneId, worldFrame: frame, action: .moveTile)
            }
            agents[spec.key] = AgentHandle(tileId: tileId, agentId: agentId, zoneId: zoneId, threadId: view.wiringThreadId)
        }
        delegate.filmRefreshAgentSurfaces()

        // Terminals: clear the tap's screen. Pages: wait for the load.
        let deadline = Date().addingTimeInterval(spawnTimeout)
        for spec in scene.tiles where spec.kind == "terminal" {
            while terminalRuntime(spec.key) == nil, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let runtime = terminalRuntime(spec.key) else { log("WARN terminal \(spec.key): no runtime"); continue }
            // Typed text is key input (Ghostty drops ESC and maps newline to Return),
            // so output goes through a FIFO the tap `cat`s: raw bytes, real ANSI. The
            // tap names its FIFO after the first line it reads, typed here.
            guard let tapDirectory = ProcessInfo.processInfo.environment["FILM_TAP_DIR"] else {
                log("WARN terminal \(spec.key): no FILM_TAP_DIR, output disabled"); continue
            }
            runtime.sendInput(Data("\(spec.key)\r".utf8))
            var ready = false
            while !ready, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                ready = runtime.visibleText().contains("FILM-TAP-READY")
            }
            let fifo = URL(fileURLWithPath: tapDirectory).appendingPathComponent("\(spec.key).fifo").path
            if ready, let handle = FileHandle(forWritingAtPath: fifo) {
                terminalTaps[spec.key] = handle
                handle.write(Data("\u{1b}[2J\u{1b}[3J\u{1b}[H".utf8))
            } else {
                ready = false
            }
            log("terminal \(spec.key): tap \(ready ? "ready" : "NOT ready: \(runtime.visibleText().prefix(200))")")
        }
        for spec in scene.tiles where spec.kind == "browser" {
            while Date() < deadline {
                if let web = browserWebView(spec.key), !web.isLoading, web.estimatedProgress >= 1 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // Git badges and editor text arrive asynchronously; give them a beat.
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        prepareInput()
        pauseCoreAnimation()
        prepareClock()
        AgentElapsedClock.now = { [weak self] in self?.filmDate ?? Date() }
        let epoch = filmEpoch, uptime = ProcessInfo.processInfo.systemUptime, shift = Self.filmWallShift
        AgentTranscriptClock.monotonic = { uptime + FilmDirector.filmSeconds }
        AgentTranscriptClock.wall = { epoch.addingTimeInterval(shift + FilmDirector.filmSeconds) }
        // A running tool row's "◐ 4s" (integration's `ToolRowLiveClock`, after 0.7.25):
        // film time, ticked once per frame in `step` rather than by its 1 s wall timer.
        ToolRowLiveClock.now = { AgentElapsedClock.now() }
        // Transient badges ("Pushed", "Merged") clear on film time, not wall time.
        AgentSignalCenter.filmDelay = { [weak self] seconds in await self?.filmDelay(seconds) }
        installV2Hooks()
    }

    /// The frame's centre, nudged so a default-sized tile centred there sits inside the
    /// zone with a 48 pt margin (the zone's centre when it cannot).
    nonisolated static func spawnPoint(for frame: TileFrame, defaultSize: CGSize, zone: CGRect) -> CGPoint {
        var point = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        guard !zone.isNull else { return point }
        let inner = zone.insetBy(dx: 48 + defaultSize.width / 2, dy: 48 + defaultSize.height / 2)
        point.x = inner.width >= 0 ? min(max(point.x, inner.minX), inner.maxX) : zone.midX
        point.y = inner.height >= 0 ? min(max(point.y, inner.minY), inner.maxY) : zone.midY
        return point
    }

    func finish() {
        FilmAgentRunner.releaseAll()
        for handle in terminalTaps.values { try? handle.close() }
        terminalTaps.removeAll()
        AgentElapsedClock.now = { Date() }
        AgentTranscriptClock.monotonic = { ProcessInfo.processInfo.systemUptime }
        AgentTranscriptClock.wall = { Date() }
        ToolRowLiveClock.now = { Date() }
        AgentSignalCenter.filmDelay = nil
        FilmMenuHost.present = nil
        uninstallV2Hooks()
        for timer in filmTimers { timer.resume.resume() }
        filmTimers.removeAll()
        input.uninstall()
        resumeCoreAnimation()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Real input needs a key window: key events go to the key window's first
    /// responder, and a click on a window that is not key is AppKit's activation click.
    /// The window becomes key WITHOUT the app becoming active, so nothing the user types
    /// elsewhere ever reaches it. The check's borderless window cannot be key; no
    /// committed scene sends key events.
    private func prepareInput() {
        input.install()
        if window.canBecomeKey { window.makeKey() }
        FilmMenuHost.present = { [weak self] menu, point, view in self?.presentMenu(menu, at: point, in: view) }
        log("input: window key \(window.isKeyWindow), app active \(NSApp.isActive), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
    }

    // MARK: - Lookups

    func terminalRuntime(_ key: String) -> GhosttyTerminalRuntime? {
        (canvas.tileView(for: scene.tileId(key)) as? TerminalTileNSView)?.runtime
    }

    func browserWebView(_ key: String) -> WKWebView? {
        ((canvas.tileView(for: tileId(forKey: key)) as? BrowserTileNSView)?.runtime as? WKWebViewBrowserRuntime)?.webView
    }

    func worldFrame(of tileId: UUID) -> TileFrame? {
        canvas.navigationTileSnapshot(for: tileId)?.worldFrame
    }

    func tileId(forKey key: String) -> UUID {
        agents[key]?.tileId ?? openedTiles[key] ?? adoptedTiles[key] ?? scene.tileId(key)
    }

    func zoneId(forKey key: String) -> UUID { adoptedZones[key] ?? scene.zoneId(key) }

    /// A staged or adopted zone's LIVE world rect (it may have been resized or grown),
    /// falling back to the staged rect while the canvas has no placement for it.
    func zoneWorldRect(_ key: String) -> CGRect? {
        if let placement = canvas.zonePlacement(for: zoneId(forKey: key)) {
            let f = CanvasEngine.zoneWorldFrame(placement)
            return CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
        }
        return scene.zoneRect(key)
    }

    /// Every key a zone is known by (staged, then adopted).
    var zoneKeys: [String] { scene.zones.map(\.key) + adoptedZones.keys.sorted() }

    func agentView(_ key: String) -> ManagedAgentTileNSView? {
        agents[key].flatMap { canvas.tileView(for: $0.tileId) as? ManagedAgentTileNSView }
    }

    // MARK: - Core Animation clock

    private func pauseCoreAnimation() {
        guard let layer = window.contentView?.superview?.layer ?? window.contentView?.layer else { return }
        rootBaseTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = rootBaseTime
        rootLayer = layer
    }

    private func resumeCoreAnimation() {
        guard let layer = rootLayer else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        rootLayer = nil
    }

    /// Film seconds the root layer's clock has advanced since staging (witnessed).
    var coreAnimationFilmTime: Double? { rootLayer.map { $0.timeOffset - rootBaseTime } }

    // MARK: - The frame loop

    /// Runs every take in order. `onFrame` sees each frame after it is committed; the
    /// live run captures there (skipping `capture: false` takes), the witness records.
    func run(onFrame: (@MainActor (_ take: FilmScene.Take, _ takeIndex: Int, _ record: FrameRecord) async throws -> Void)?) async throws {
        for (takeIndex, take) in scene.takes.enumerated() {
            log("take \(take.name): \(take.frames) frames")
            for frame in 0..<take.frames {
                let fired = try await step(take: take, takeIndex: takeIndex, frame: frame)
                let record = FrameRecord(index: frame, time: Double(globalFrame) / fps, filmTime: Self.filmSeconds,
                                         viewport: canvas.viewport, actions: fired,
                                         pointer: pointer, rects: measureRects(), events: frameEvents,
                                         carried: carriedCards(), sidebarStates: sidebarStates(),
                                         keys: frameKeys, menus: frameMenus, sounds: frameSounds)
                try await onFrame?(take, takeIndex, record)
                globalFrame += 1
            }
        }
    }

    /// Applies one frame of one take and commits it. Returns the labels of the actions
    /// active on this frame.
    func step(take: FilmScene.Take, takeIndex: Int, frame: Int) async throws -> [String] {
        var fired: [String] = []
        frameEvents = []
        frameKeys = []
        frameMenus = []
        frameSounds = []
        if frame == 0, let clock = take.clock { advanceClock(to: clock, take: take.name) }
        Self.filmSeconds = Double(globalFrame) / fps + clockJump
        await fireFilmTimers()
        redrawInboxIfClockMoved(takeStart: frame == 0)
        let active = take.actions.enumerated().filter { frame >= $0.element.at && frame <= $0.element.at + $0.element.duration }
        // Camera and content first, pointer and input last: a world-anchored pointer
        // target is resolved against the camera this frame commits. Navigation glides
        // (production's jump targets, handed over by `filmNavigationCamera`) move the
        // camera between the two.
        for (index, action) in active where !action.isPointerVerb {
            try await apply(action, key: "\(takeIndex)/\(index)", frame: frame)
        }
        for (index, action) in active where action.ownsNavigation {
            advanceNavigationGlide(key: "\(takeIndex)/\(index)", action: action, local: frame - action.at)
        }
        navigationOwner = nil
        for (index, action) in active where action.isPointerVerb {
            try await apply(action, key: "\(takeIndex)/\(index)", frame: frame)
            if action.ownsNavigation, frame - action.at < action.duration,
               navigationOwner.map({ action.at >= $0.at }) ?? true {
                navigationOwner = ("\(takeIndex)/\(index)", frame - action.at, action.duration, takeIndex, action.at, action.label)
            }
        }
        // Whatever real input this frame posted has been dispatched before it is drawn.
        await input.settle()
        for (_, action) in active {
            fired.append(action.label)
            if frame == action.at { firedActions.append("\(take.name)@\(frame):\(action.label)") }
        }
        await pump()
        await waitForRunnerCompletions()
        logSignalChanges()
        delegate.filmTickSidebar()
        ToolRowLiveClock.shared.tick()
        // Film time is the frame's own time; nothing reads the wall clock for content.
        rootLayer?.timeOffset = rootBaseTime + Double(globalFrame) / fps
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for child in window.childWindows ?? [] where child.isVisible { child.displayIfNeeded() }
        CATransaction.flush()
        try await waitForTerminals()
        await waitForBrowsers()
        return fired
    }

    /// Each agent tile's awareness badge ("Pushed", "Merged", "Completed"...), logged when
    /// it changes, with the film time: the record that transient badges clear on film time.
    private func logSignalChanges() {
        let names = Dictionary(agents.map { ($0.value.tileId, $0.key) }, uniquingKeysWith: { a, _ in a })
        let current = delegate.agentSignalCenter.currentByTile
            .map { "\(names[$0.key] ?? $0.key.uuidString.prefix(8).description)=\($0.value.kind.rawValue)" }.sorted().joined(separator: ",")
        if (actionState["signals"] as? String ?? "") != current {
            actionState["signals"] = current
            log(String(format: "signals [%@] at film %.2f s (frame %d)", current, Self.filmSeconds, globalFrame))
        }
    }

    /// Let the tiles' event-stream tasks run, then present what they ingested now
    /// instead of when a wall-clock timer next fires.
    private func pump() async {
        for _ in 0..<4 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 1_000_000)
        for _ in 0..<2 { await Task.yield() }
        // A tool row's host-local detail (its fields, "Exit code", output) reaches the
        // transcript through an actor hop and a second task (`AgentTranscriptListView`
        // `scheduleToolDetailRefresh`). Live, that lands within milliseconds of its event;
        // here it raced the frame, landing before or after the next delivery or camera
        // step from run to run, so whether a transcript stayed pinned to its tail differed
        // between captures. Drain it so it lands on its event's frame. Opt-in
        // (`settleToolDetails`): the extra wall time per frame shifts production's
        // wall-clock debounces (the camera arming rule), which the committed scenes'
        // witnesses were recorded against.
        let keys = scene.settleToolDetails == true ? agents.keys.sorted() : []
        for _ in 0..<(keys.isEmpty ? 0 : 3) {
            for key in keys { await agentView(key)?.qaTranscriptForChecks?.qaWaitForToolDetailRefresh() }
            try? await Task.sleep(nanoseconds: 2_000_000)
            for _ in 0..<4 { await Task.yield() }
        }
        for key in agents.keys {
            guard let view = agentView(key) else { continue }
            view.qaFlushStreamingMarkupForChecks()
            view.qaTranscriptForChecks?.flushPendingVisualUpdate()
        }
    }

    /// A turn that ended through its runner is over when the supervisor has let the
    /// runner go (`isRunning` false): wait for that (bounded), then push the surfaces,
    /// so the sidebar row and the tile read Done on this frame, as a CLI's exit would.
    private func waitForRunnerCompletions() async {
        guard !pendingRunnerCompletions.isEmpty else { return }
        let deadline = Date().addingTimeInterval(2)
        for key in pendingRunnerCompletions.sorted() {
            guard let agent = agents[key] else { continue }
            while supervisor.isRunning(agent.agentId), Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            if supervisor.isRunning(agent.agentId) { log("WARN \(key): its runner still holds the turn 2 s after it completed") }
        }
        pendingRunnerCompletions.removeAll()
        delegate.filmRefreshAgentSurfaces()
        await pump()
    }

    /// A frame that wrote terminal bytes waits until Ghostty shows their tail, so the
    /// captured frame and the film clock agree (bounded; logged when it times out).
    private func waitForTerminals() async throws {
        guard !pendingTerminalTails.isEmpty else { return }
        let deadline = Date().addingTimeInterval(0.5)
        for (key, tail) in pendingTerminalTails {
            let needle = Self.visibleNeedle(tail)
            guard !needle.isEmpty, let runtime = terminalRuntime(key) else { continue }
            while !runtime.visibleText().contains(needle), Date() < deadline {
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            if !runtime.visibleText().contains(needle) {
                log("WARN terminal \(key): tail not visible after 0.5s: \(needle); screen: \(runtime.visibleText().suffix(160))")
            }
        }
        pendingTerminalTails.removeAll()
    }

    /// The last printable run of a chunk, with ANSI sequences stripped.
    static func visibleNeedle(_ chunk: String) -> String {
        let stripped = chunk.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = stripped.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
        return String((lines.last { !$0.isEmpty } ?? "").suffix(24))
    }

    // MARK: - Actions

    private func apply(_ action: FilmAction, key: String, frame: Int) async throws {
        let local = frame - action.at
        if let target = action.camera {
            applyCamera(target, action: action, key: key, local: local)
        } else if let pan = action.pan {
            applyPan(pan, action: action, key: key, local: local)
        } else if let zoom = action.zoom {
            applyZoom(zoom, action: action, key: key, local: local)
        } else if let op = action.pointer {
            applyPointer(op, action: action, key: key, local: local)
        } else if let click = action.click {
            applyClick(click, action: action, key: key, local: local)
        } else if let drag = action.drag {
            try applyDrag(drag, action: action, key: key, local: local)
        } else if let gesture = action.gesture {
            try applyGesture(gesture, action: action, key: key, local: local)
        } else if let name = action.key {
            applyKey(name, action: action, key: key, local: local)
        } else if let tileKey = action.jump {
            applyJump(tileKey, action: action, key: key, local: local)
        } else if let zoneKey = action.jumpZone {
            applyJumpZone(zoneKey, action: action, key: key, local: local)
        } else if let modifier = action.hold {
            applyHold(modifier, action: action, local: local)
        } else if let text = action.type {
            applyType(text, action: action, local: local)
        } else if let menu = action.menu {
            if local == 0 { try applyMenu(menu) }
        } else if let adopt = action.adopt {
            if local == 0 { try applyAdopt(adopt) }
        } else if let write = action.write {
            if local == 0 { try applyWrite(write) }
        } else if let scroll = action.scroll {
            applyScroll(scroll, action: action, key: key, local: local)
        } else if let browser = action.browser {
            if local == 0 { try applyBrowser(browser) }
        } else if let setting = action.setting {
            if local == 0 { applySetting(setting) }
        } else if let op = action.board, local == 0 {
            try applyBoard(op)
        } else if let terminalKey = action.terminal {
            try applyTerminal(terminalKey, action: action, key: key, local: local)
        } else if let agentKey = action.reveal {
            try applyReveal(agentKey, action: action, key: key, local: local)
        } else if let agentKey = action.agent {
            try applyAgent(agentKey, action: action, key: key, local: local)
        }
    }

    // MARK: Camera

    func cameraTargetViewport(_ target: FilmAction.CameraTarget) -> CanvasViewport? {
        guard let union = cameraTargetRect(target) else { return nil }
        return CanvasEngine.fit(worldRect: union, viewportSize: canvas.bounds.size, padding: target.padding ?? 40)
    }

    /// The world rect a camera target frames (the union of its parts): zones and tiles
    /// from their LIVE geometry (a zone may have been resized or have grown to fit, a
    /// tile moved or created during the take), staged geometry until they exist.
    func cameraTargetRect(_ target: FilmAction.CameraTarget) -> CGRect? {
        var rects: [CGRect] = []
        for key in (target.zones ?? []) + (target.zone.map { [$0] } ?? []) {
            if let rect = zoneWorldRect(key) { rects.append(rect) }
        }
        for key in target.tiles ?? [] {
            if let f = worldFrame(of: tileId(forKey: key)) {
                rects.append(CGRect(x: f.x, y: f.y, width: f.width, height: f.height))
            } else if let spec = scene.tile(key) {
                let f = scene.worldFrame(of: spec)
                rects.append(CGRect(x: f.x, y: f.y, width: f.width, height: f.height))
            }
        }
        if let r = target.rect, r.count == 4 { rects.append(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) }
        if target.all == true { rects += zoneKeys.compactMap(zoneWorldRect) }
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() { union = union.union(rect) }
        return union
    }

    /// Every `open`'s tile as the workspace API reported it (witness only).
    var reportedOpenRects: [String: CGRect] {
        var rects: [String: CGRect] = [:]
        for record in opens {
            if let r = record.result.actualWorldRect { rects[record.key] = CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        }
        return rects
    }

    /// A tile an `open` registered, from its LIVE world frame (production placed it).
    func openedWorldRect(_ key: String) -> CGRect? {
        guard let tileId = openedTiles[key], let f = worldFrame(of: tileId) else { return nil }
        return CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }

    private func applyCamera(_ target: FilmAction.CameraTarget, action: FilmAction, key: String, local: Int) {
        guard let end = cameraTargetViewport(target) else { log("WARN camera target resolves to nothing"); return }
        let curve = scene.cameraCurve(for: action)
        if local == 0 {
            actionState[key] = canvas.viewport
            guardSpeed(key, "camera", from: canvas.viewport, to: end, curve: curve, action: action, staggered: false)
        }
        guard let start = actionState[key] as? CanvasViewport else { return }
        let progress = action.duration == 0 ? 1 : Double(local) / Double(action.duration)
        let eased = curve.value(progress, duration: Double(action.duration) / fps)
        canvas.setViewport(Self.interpolate(start, end, eased, size: canvas.bounds.size))
    }

    /// The speed guard: warns (never fails) when a move's peak screen speed or zoom rate
    /// exceeds what reads comfortably (`FilmCameraMath`'s limits). A cut (dur 0) is not a move.
    private func guardSpeed(_ key: String, _ verb: String, from v0: CanvasViewport, to v1: CanvasViewport,
                            curve: FilmCurve, action: FilmAction, staggered: Bool) {
        guard action.duration > 0 else { return }
        let speed = FilmCameraMath.peakSpeed(from: v0, to: v1, curve: curve, duration: Double(action.duration) / fps,
                                             size: canvas.bounds.size, staggered: staggered)
        for warning in speed.warnings {
            warn("\(key)/speed/\(warning)", "\(verb) at \(action.at) over \(action.duration) frames: \(warning)")
        }
    }

    /// v0 -> v1 with zoom in log space and the pan weighted by 1/zoom, so the screen
    /// point the two viewports share stays put (a natural push-in / pull-back).
    nonisolated static func interpolate(_ v0: CanvasViewport, _ v1: CanvasViewport, _ e: Double, size: CGSize) -> CanvasViewport {
        if e <= 0 { return v0 }
        if e >= 1 { return v1 }
        let z = exp(Foundation.log(v0.zoom) + (Foundation.log(v1.zoom) - Foundation.log(v0.zoom)) * e)
        let w = Double(size.width), h = Double(size.height)
        let c0 = (x: v0.x + w / 2 / v0.zoom, y: v0.y + h / 2 / v0.zoom)
        let c1 = (x: v1.x + w / 2 / v1.zoom, y: v1.y + h / 2 / v1.zoom)
        let weight = abs(v1.zoom - v0.zoom) < 1e-9 ? e : (1 / z - 1 / v0.zoom) / (1 / v1.zoom - 1 / v0.zoom)
        let c = (x: c0.x + (c1.x - c0.x) * weight, y: c0.y + (c1.y - c0.y) * weight)
        return CanvasViewport(x: c.x - w / 2 / z, y: c.y - h / 2 / z, zoom: z)
    }

    // MARK: Board

    func boardContext(cardKey: String) throws -> (view: KanbanTileNSView, runtime: BoardRuntime, cardId: UUID) {
        if let bound = boundCards[cardKey] {
            guard let view = boardView(boardId: bound.board), let runtime = boardRuntime(for: view) else {
                throw FilmError("card \(cardKey): no live board shows it")
            }
            return (view, runtime, bound.card)
        }
        let cardId = scene.uuid("card", cardKey)
        for spec in scene.tiles where spec.kind == "kanban" {
            guard spec.board?.cards.contains(where: { $0.key == cardKey }) == true,
                  let view = canvas.tileView(for: scene.tileId(spec.key)) as? KanbanTileNSView,
                  let zone = scene.zone(spec.zone),
                  let runtime = delegate.filmBoardRuntime(projectId: scene.projectId(zone.project)) else { continue }
            return (view, runtime, cardId)
        }
        throw FilmError("card \(cardKey): no live board shows it")
    }

    /// The live kanban tile showing `boardId`, staged or created during the take.
    func boardView(boardId: UUID) -> KanbanTileNSView? {
        for tile in liveTiles() where tile.kind == .kanban {
            if let view = canvas.tileView(for: tile.id) as? KanbanTileNSView, view.board.id == boardId { return view }
        }
        return nil
    }

    /// A staged or adopted kanban tile's view.
    func boardView(key: String) -> KanbanTileNSView? { canvas.tileView(for: tileId(forKey: key)) as? KanbanTileNSView }

    /// The board runtime of the project whose zone holds `view`.
    func boardRuntime(for view: KanbanTileNSView) -> BoardRuntime? {
        guard let zoneId = canvas.navigationTileSnapshot(for: view.tile.id)?.zoneId,
              let projectId = canvas.zonePlacement(for: zoneId)?.projectId else { return nil }
        return delegate.filmBoardRuntime(projectId: projectId)
    }

    private func applyBoard(_ op: FilmAction.BoardOp) throws {
        if let cardKey = op.advance, let agentKey = op.agent {
            let context = try boardContext(cardKey: cardKey)
            guard let agent = agents[agentKey] else { throw FilmError("advance: unknown agent \(agentKey)") }
            let outcome = context.runtime.advanceAssignedTaskAfterAcceptedSend(
                boardId: context.view.board.id, cardId: context.cardId, agentId: agent.agentId)
            log("board advance \(cardKey): \(String(describing: outcome))")
            if let view = agentView(agentKey) {
                let boardId = context.view.board.id
                Task { await view.clearBoardTask(boardID: boardId, cardID: context.cardId) }
            }
        } else if let cardKey = op.move, let columnName = op.column {
            let context = try boardContext(cardKey: cardKey)
            guard let column = context.view.board.orderedColumns.first(where: { $0.name == columnName }) else {
                throw FilmError("move: no column \(columnName)")
            }
            let outcome = context.runtime.apply(
                .moveCard(id: context.cardId, toColumn: column.id,
                          after: context.view.board.orderedCards(in: column.id).last?.id, before: nil),
                to: context.view.board.id)
            log("board move \(cardKey) -> \(columnName): \(outcome)")
        }
    }

    private struct DragPlan { var start: CGPoint; var mode: String }

    /// The press happens where the pointer already is; the card rides the pointer's
    /// eased path to the destination (re-resolved every frame) and is released there.
    private func applyDrag(_ drag: FilmAction.Drag, action: FilmAction, key: String, local: Int) throws {
        let context = try boardContext(cardKey: drag.card)
        let board = context.view
        if local == 0 {
            guard let card = board.cardView(for: context.cardId) else { throw FilmError("drag: card \(drag.card) not rendered") }
            let cardRect = topLeftRect(of: card, card.bounds)
            if !cardRect.contains(pointer.point) {
                // A scene that never placed the pointer (board-story) gets it put on
                // the card silently; one that did and missed is an authoring error.
                if pointer.placed { warn(key, "drag \(drag.card): pointer \(pointer.point) is not over the card \(cardRect); snapping it to the card") }
                pointer.point = CGPoint(x: cardRect.midX, y: cardRect.midY)
            }
            actionState[key] = DragPlan(start: pointer.point, mode: pointer.mode)
            pointer.down = true
            pointer.mode = "grab"
            frameEvents += ["press", "dragStart"]
            board.beginCardDrag(cardId: context.cardId, event: mouseEvent(.leftMouseDown, at: windowPoint(fromTopLeft: pointer.point)))
            return
        }
        guard let plan = actionState[key] as? DragPlan else { return }
        guard let end = dragDestination(drag, board: board) else { throw FilmError("drag \(drag.card): no destination") }
        let curve = FilmCurve.pointer(spring: drag.spring, ease: drag.ease) ?? .bezier(.inOut)
        let eased = curve.value(Double(local) / Double(max(action.duration, 1)), duration: Double(action.duration) / fps)
        pointer.point = FilmPointerMath.path(from: plan.start, to: end, e: eased, arc: drag.arc ?? FilmPointerMath.defaultArc)
        board.continueCardDrag(event: mouseEvent(.leftMouseDragged, at: windowPoint(fromTopLeft: pointer.point)))
        if local >= action.duration {
            board.finishCardDrag()
            pointer.down = false
            pointer.mode = plan.mode
            frameEvents += ["drop", "release"]
            log("drag \(drag.card) finished -> \(drag.toAgent ?? drag.toColumn ?? "?")")
        }
    }

    /// Top-left window point a drag releases on: the agent tile's centre, or the
    /// upper third of the lane (where the first card slot sits).
    private func dragDestination(_ drag: FilmAction.Drag, board: KanbanTileNSView) -> CGPoint? {
        if let agentKey = drag.toAgent, let target = agentView(agentKey) {
            let rect = topLeftRect(of: target, target.bounds)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        if let columnName = drag.toColumn,
           let column = board.board.orderedColumns.first(where: { $0.name == columnName }),
           let columnView = board.columnView(for: column.id) {
            let rect = topLeftRect(of: columnView, columnView.bounds)
            return CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.3)
        }
        return nil
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: Double(globalFrame) / fps,
                           windowNumber: window.windowNumber, context: nil, eventNumber: globalFrame,
                           clickCount: 1, pressure: 1)!
    }

    // MARK: Pointer

    private var contentRect: CGRect { window.contentLayoutRect }
    var pointSize: CGSize { contentRect.size }

    func topLeft(fromWindow p: CGPoint) -> CGPoint { CGPoint(x: p.x - contentRect.minX, y: contentRect.maxY - p.y) }
    func windowPoint(fromTopLeft p: CGPoint) -> CGPoint { CGPoint(x: p.x + contentRect.minX, y: contentRect.maxY - p.y) }
    func topLeft(fromCanvas p: CGPoint) -> CGPoint { topLeft(fromWindow: canvas.convert(p, to: nil)) }
    func canvasPoint(fromTopLeft p: CGPoint) -> CGPoint { canvas.convert(windowPoint(fromTopLeft: p), from: nil) }
    func topLeftRect(of view: NSView, _ rect: CGRect) -> CGRect {
        let r = view.convert(rect, to: nil)
        return CGRect(x: r.minX - contentRect.minX, y: contentRect.maxY - r.maxY, width: r.width, height: r.height)
    }
    var windowBounds: CGRect { CGRect(origin: .zero, size: pointSize) }

    func warn(_ key: String, _ message: String) {
        guard warned.insert(key).inserted else { return }
        log("WARN \(message)")
    }

    /// The live view a card is drawn by: the lifted copy while it is being carried,
    /// else its lane view.
    func cardDisplayView(_ cardKey: String) -> NSView? {
        guard let context = try? boardContext(cardKey: cardKey) else { return nil }
        if let session = context.view.dragSession, session.cardId == context.cardId, !session.liftedView.isHidden {
            return session.liftedView
        }
        return context.view.cardView(for: context.cardId)
    }

    /// Resolves a pointer target to a top-left window point from the live views (and,
    /// for zones, the live camera). Nil when the target is not rendered.
    func resolve(_ target: FilmAction.PointerTarget) -> CGPoint? {
        if let point = target.window, point.count == 2 { return CGPoint(x: point[0], y: point[1]) }
        if let point = target.world, point.count == 2 {
            return topLeft(fromCanvas: CanvasEngine.worldToScreen(CGPoint(x: point[0], y: point[1]), viewport: canvas.viewport))
        }
        if let title = target.choice { return choiceRowPoint(title: title) }
        if let toolUseId = target.chip { return chipPoint(toolUseId: toolUseId) }
        if let key = target.tile {
            guard let view = canvas.tileView(for: tileId(forKey: key)) else { return nil }
            let b = view.bounds
            let local: CGPoint
            switch target.at ?? .center {
            case .center: local = CGPoint(x: b.midX, y: b.midY)
            case .header: local = CGPoint(x: b.midX, y: b.minY + view.grabHeightInLocalCoordinates / 2)
            case .body:
                let grab = view.grabHeightInLocalCoordinates
                local = CGPoint(x: b.minX + b.width / 2, y: b.minY + grab + (b.height - grab) / 2)
            case let .fraction(fx, fy): local = CGPoint(x: b.minX + b.width * fx, y: b.minY + b.height * fy)
            // The tile's own resize ring straddles its border (TileNSView.resizeEdge);
            // the flipped tile's local space is top-left, like the edge math.
            case let .edge(edge):
                let inset = b.insetBy(dx: 2, dy: 2)
                local = view.isFlipped ? edge.point(in: inset)
                    : { let p = edge.point(in: inset); return CGPoint(x: p.x, y: b.maxY - (p.y - b.minY)) }()
            case .close:
                let close = view.qaCloseButtonFrame
                guard !close.isEmpty else { return nil }
                local = CGPoint(x: close.midX, y: close.midY)
            case .overflow, .nudge: return nil
            case .address:
                guard let field = (view as? BrowserTileNSView)?.filmURLField, field.window != nil else { return nil }
                return topLeft(fromWindow: field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
            case .composer, .send:
                guard let agent = view as? ManagedAgentTileNSView,
                      let control = target.at == .send ? agent.filmActionButton : agent.filmComposerTextView,
                      control.window != nil else { return nil }
                // The composer's text view can be taller than what shows; aim at its
                // first line's height from the top of the visible part.
                let visible = control.visibleRect.isEmpty ? control.bounds : control.visibleRect
                let point = target.at == .send ? CGPoint(x: visible.midX, y: visible.midY)
                    : CGPoint(x: visible.minX + min(80, visible.width / 2), y: visible.midY)
                return topLeft(fromWindow: control.convert(point, to: nil))
            }
            return topLeft(fromWindow: view.convert(local, to: nil))
        }
        if let settings = target.settings.flatMap(FilmSettingsTarget.init) { return settingsControlRect(settings).map { CGPoint(x: $0.midX, y: $0.midY) } }
        if let bulk = target.bulk { return bulkTargetRect(bulk).map { CGPoint(x: $0.midX, y: $0.midY) } }
        if let key = target.sidebar {
            if target.at == .nudge { return nudgeRect(key).map { CGPoint(x: $0.midX, y: $0.midY) } }
            guard let cell = key == "history" ? historyHeaderCell() : sidebarRowCell(key) else { return nil }
            let rect = topLeftRect(of: cell, cell.bounds)
            if case let .fraction(fx, fy) = target.at { return CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy) }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        if let key = target.card {
            guard let view = cardDisplayView(key) else { return nil }
            let rect = topLeftRect(of: view, view.bounds)
            if case let .fraction(fx, fy) = target.at { return CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy) }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        if let key = target.zone, let world = zoneWorldRect(key) {
            let screen = CanvasEngine.tileScreenFrame(
                TileFrame(x: world.minX, y: world.minY, width: world.width, height: world.height), viewport: canvas.viewport)
            let local: CGPoint
            // The header band is min(32, h) tall (`zoneHeaderScreenRect`); its name sits
            // at the left, its ✕ is a 24 pt square 4 pt in from the top-right, and the ⋯
            // is the 24 pt band 26 pt left of the ✕ (`zoneOverflowButtonZoneId`).
            let header = min(32, screen.height)
            switch target.at ?? .header {
            case .header, .body, .composer, .send, .address, .nudge: local = CGPoint(x: screen.minX + min(110, screen.width / 2), y: screen.minY + header / 2)
            case .center: local = CGPoint(x: screen.midX, y: screen.midY)
            case let .fraction(fx, fy): local = CGPoint(x: screen.minX + screen.width * fx, y: screen.minY + screen.height * fy)
            case .close: local = CGPoint(x: screen.maxX - 4 - 12, y: screen.minY + 4 + min(24, header - 4) / 2)
            case .overflow: local = CGPoint(x: screen.maxX - 4 - 24 - 26 + 12, y: screen.minY + 4 + min(24, header - 4) / 2)
            // ON the border: inside the ±8 pt band; the top edge and top corners are
            // header territory (it moves), so those sit just above the zone.
            case let .edge(edge):
                var p = edge.point(in: screen)
                if [.top, .topLeft, .topRight].contains(edge) { p.y -= 4 }
                local = p
            }
            return topLeft(fromCanvas: local)
        }
        return nil
    }

    /// The child panel row titled `title` (ChoicePopoverController's list: the
    /// home-folder picker), in top-left MAIN window points.
    func choiceRowPoint(title: String) -> CGPoint? {
        for panel in (window.childWindows ?? []).reversed() where panel.isVisible {
            guard let content = panel.contentView, let label = Self.label(titled: title, in: content) else { continue }
            var row: NSView = label
            while let parent = row.superview, !(row is NSControl && row !== label) { row = parent }
            let rect = row.convert(row.bounds, to: nil)
            let screen = panel.convertToScreen(rect)
            let local = window.convertPoint(fromScreen: CGPoint(x: screen.midX, y: screen.midY))
            return topLeft(fromWindow: local)
        }
        return nil
    }

    static func label(titled title: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == title, !field.isHiddenOrHasHiddenAncestor { return field }
        for subview in view.subviews { if let hit = label(titled: title, in: subview) { return hit } }
        return nil
    }

    /// The chip a parent's transcript shows for the subagent its `Agent` tool_use
    /// `toolUseId` spawned (`AgentReferenceChipView`, identified by the child id).
    func chipPoint(toolUseId: String) -> CGPoint? {
        guard let chip = chipView(toolUseId: toolUseId) else { return nil }
        let rect = topLeftRect(of: chip, chip.bounds)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func chipView(toolUseId: String) -> NSView? {
        for (key, handle) in agents {
            let child = AgentRecord.observedChildID(parentAgentID: handle.agentId.rawValue, toolUseID: toolUseId)
            let identifier = NSUserInterfaceItemIdentifier("agent.reference.\(child.uuidString)")
            guard let view = agentView(key), let chip = Self.view(identified: identifier, in: view),
                  chip.window != nil, !chip.isHiddenOrHasHiddenAncestor else { continue }
            return chip
        }
        return nil
    }

    static func view(identified identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identifier { return view }
        for subview in view.subviews { if let hit = self.view(identified: identifier, in: subview) { return hit } }
        return nil
    }

    private func applyPointer(_ op: FilmAction.Pointer, action: FilmAction, key: String, local: Int) {
        if let mode = op.mode {
            if local == 0 { pointer.mode = mode }
            return
        }
        guard let target = op.to else { return }
        if local == 0 { actionState[key] = pointer.point }
        guard let start = actionState[key] as? CGPoint else { return }
        let relative = target.by.map { CGPoint(x: Double(start.x) + $0[0], y: Double(start.y) + $0[1]) }
        guard let end = relative ?? resolve(target) else { warn(key, "pointer target \(target) is not rendered"); return }
        let curve = FilmCurve.pointer(spring: op.spring, ease: op.ease) ?? .bezier(.inOut)
        // The move takes `dur`; a `dwell` after it stays on the (live) target.
        let moveFrames = max(action.dur ?? 0, 0)
        let progress = moveFrames == 0 ? 1 : min(1, Double(local) / Double(moveFrames))
        let eased = curve.value(progress, duration: Double(moveFrames) / fps)
        pointer.point = FilmPointerMath.path(from: start, to: end, e: eased, arc: op.arc ?? FilmPointerMath.defaultArc)
        pointer.placed = true
        if op.hover == true { pointerTracked = true }
        if pointerTracked { postMouseMovedIfNeeded(force: local == 0 && op.hover == true) }
    }

    /// A click is press (frame 0) .. release (frame 5); a delivered one is real
    /// leftMouseDown/Up events at the pointer (FilmInput), a double-click two of them
    /// (clickCount 1 at frames 0/2, clickCount 2 at frames 3/5).
    private func applyClick(_ click: FilmAction.Click, action: FilmAction, key: String, local: Int) {
        let double = click.count == 2
        let mods = (FilmInput.modifiers(action.allMods) ?? []).union(heldModifiers)
        if local == 0 {
            pointer.down = true
            frameEvents.append("press")
        } else if local == 5 {
            pointer.down = false
            frameEvents += ["release", "click"]
            if double { frameEvents.append("doubleClick") }
        }
        guard click.deliver == true else { return }
        let presses: [Int: (NSEvent.EventType, Int)] = double
            ? [0: (.leftMouseDown, 1), 2: (.leftMouseUp, 1), 3: (.leftMouseDown, 2), 5: (.leftMouseUp, 2)]
            : [0: (.leftMouseDown, 1), 5: (.leftMouseUp, 1)]
        guard let (type, count) = presses[local] else { return }
        // A ⇧/⌘-click holds the modifier keys around it, as a hand does (flagsChanged
        // down before the press, up after the release), unless `hold` already does.
        let chord = (FilmInput.modifiers(action.allMods) ?? []).subtracting(heldModifiers)
        let chordKeys = [NSEvent.ModifierFlags.control, .option, .shift, .command].filter { chord.contains($0) }
        if local == 0 {
            var flags = heldModifiers
            for modifier in chordKeys {
                flags.insert(modifier)
                if let code = FilmInput.modifierKeyCodes[modifier.rawValue],
                   let event = input.flagsEvent(code: code, flags: flags, window: NSApp.keyWindow ?? window) { input.post(event) }
            }
        }
        defer {
            if type == .leftMouseUp, count == (double ? 2 : 1) {
                var flags = heldModifiers.union(chord)
                for modifier in chordKeys.reversed() {
                    flags.remove(modifier)
                    if let code = FilmInput.modifierKeyCodes[modifier.rawValue],
                       let event = input.flagsEvent(code: code, flags: flags, window: NSApp.keyWindow ?? window) { input.post(event) }
                }
            }
        }
        // Down and up go to one window (AppKit's own mouse-down window rule).
        if type == .leftMouseDown {
            let target = targetWindow()
            actionState[key] = target
            if ProcessInfo.processInfo.environment["FILM_INPUT_DEBUG"] != nil, let content = target.contentView {
                let local = target.convertPoint(fromScreen: screenPoint(fromTopLeft: pointer.point))
                let hit = content.superview?.hitTest(local) ?? content.hitTest(local)
                log("click at \(pointer.point): window \(Self.windowLabel(target)), hit \(hit.map { "\(Swift.type(of: $0)) \(($0 as? NSButton)?.title ?? "")" } ?? "nil")")
            }
        }
        postMouse(type, clickCount: count, modifiers: mods, window: actionState[key] as? NSWindow)
    }

    /// The window a press at the pointer lands in: a child panel above the main window.
    func targetWindow() -> NSWindow {
        FilmInput.window(atScreen: screenPoint(fromTopLeft: pointer.point), main: window) ?? window
    }

    func screenPoint(fromTopLeft p: CGPoint) -> CGPoint { window.convertPoint(toScreen: windowPoint(fromTopLeft: p)) }

    /// One real mouse event at the pointer, posted to the app's queue.
    func postMouse(_ type: NSEvent.EventType, clickCount: Int, modifiers: NSEvent.ModifierFlags, window target: NSWindow?) {
        let target = target ?? targetWindow()
        guard let event = input.mouseEvent(type, screenPoint: screenPoint(fromTopLeft: pointer.point), window: target,
                                           clickCount: clickCount, modifiers: modifiers) else { return }
        input.post(event)
    }

    private struct PanPlan { var v0: CanvasViewport; var v1: CanvasViewport; var start: CGPoint; var mode: String }

    private func applyPan(_ pan: FilmAction.Pan, action: FilmAction, key: String, local: Int) {
        let drag = pan.style == "drag"
        if local == 0 {
            guard let rect = cameraTargetRect(pan.to) else { warn(key, "pan target resolves to nothing"); return }
            let v0 = canvas.viewport
            let v1 = FilmPointerMath.panViewport(from: v0, centering: rect, size: canvas.bounds.size)
            let padding = pan.to.padding ?? 40
            if Double(rect.width) * v0.zoom > Double(canvas.bounds.width) - 2 * padding
                || Double(rect.height) * v0.zoom > Double(canvas.bounds.height) - 2 * padding {
                warn(key + "/fit", "pan target \(rect) does not fit at zoom \(v0.zoom)")
            }
            let plan = PanPlan(v0: v0, v1: v1, start: pointer.point, mode: pointer.mode)
            actionState[key] = plan
            guardSpeed(key, "pan", from: v0, to: v1, curve: scene.cameraCurve(for: action), action: action, staggered: false)
            frameEvents.append("panStart")
            if drag {
                let landing = FilmPointerMath.grabbedPointer(start: plan.start, from: v0, to: v1)
                if !windowBounds.contains(plan.start) || !windowBounds.contains(landing) {
                    warn(key + "/out", "drag pan: pointer \(plan.start) -> \(landing) leaves the window")
                }
                pointer.down = true
                pointer.mode = "grab"
                frameEvents.insert("press", at: frameEvents.count - 1)
                canvas.beginPointerPan(with: mouseEvent(.leftMouseDown, at: windowPoint(fromTopLeft: plan.start)))
            } else {
                pointer.mode = "scroll"
            }
            return
        }
        guard let plan = actionState[key] as? PanPlan else { return }
        let curve = scene.cameraCurve(for: action)
        let eased = curve.value(Double(local) / Double(action.duration), duration: Double(action.duration) / fps)
        let v = Self.interpolate(plan.v0, plan.v1, eased, size: canvas.bounds.size)
        if drag {
            // Through the canvas's own pan: it moves the camera by the pointer's delta.
            pointer.point = FilmPointerMath.grabbedPointer(start: plan.start, from: plan.v0, to: v)
            pointer.placed = true
            canvas.continuePointerPan(with: mouseEvent(.leftMouseDragged, at: windowPoint(fromTopLeft: pointer.point)))
        } else {
            canvas.setViewport(v)
        }
        if local >= action.duration {
            if drag {
                canvas.endPointerPan()
                pointer.down = false
                frameEvents.append("release")
            }
            pointer.mode = plan.mode
            frameEvents.append("panEnd")
        }
    }

    private struct ZoomPlan {
        var v0: CanvasViewport; var v1: CanvasViewport; var start: CGPoint; var fixed: CGPoint; var mode: String
        /// cameraModel v2: the target's world centre, which the pinch follows.
        var target: CGPoint?
    }

    /// Where a v2 pinch sits: the target's world centre through the LIVE viewport, kept
    /// inside the canvas (inset by `pinchInset`) while it is still off screen.
    func pinchAim(world: CGPoint) -> CGPoint {
        let screen = topLeft(fromCanvas: CanvasEngine.worldToScreen(world, viewport: canvas.viewport))
        let bounds = topLeftRect(of: canvas, canvas.bounds).insetBy(dx: Self.pinchInset, dy: Self.pinchInset)
        return CGPoint(x: min(max(screen.x, bounds.minX), bounds.maxX), y: min(max(screen.y, bounds.minY), bounds.maxY))
    }

    static let pinchInset: CGFloat = 24

    private func applyZoom(_ zoom: FilmAction.Zoom, action: FilmAction, key: String, local: Int) {
        let curve = scene.cameraCurve(for: action)
        let seconds = Double(action.duration) / fps
        if local == 0 {
            guard let v1 = cameraTargetViewport(zoom.to), let rect = cameraTargetRect(zoom.to) else {
                warn(key, "zoom target resolves to nothing"); return
            }
            let v0 = canvas.viewport
            if scene.isCameraV2 {
                guard FilmCameraMath.zooms(v0, v1) else { warn(key, "zoom: the zoom does not change, so there is no pinch; use pan"); return }
                actionState[key] = ZoomPlan(v0: v0, v1: v1, start: pointer.point, fixed: .zero, mode: pointer.mode,
                                            target: CGPoint(x: rect.midX, y: rect.midY))
            } else {
                guard let fixedCanvas = FilmPointerMath.fixedPoint(v0, v1) else {
                    warn(key, "zoom: the zoom does not change, so there is no pinch; use pan"); return
                }
                let fixed = topLeft(fromCanvas: fixedCanvas)
                if !windowBounds.contains(fixed) { warn(key + "/out", "zoom: fixed point \(fixed) is outside the window") }
                actionState[key] = ZoomPlan(v0: v0, v1: v1, start: pointer.point, fixed: fixed, mode: pointer.mode, target: nil)
            }
            guardSpeed(key, "zoom", from: v0, to: v1, curve: curve, action: action, staggered: scene.isCameraV2)
            pointer.mode = "pinch"
            frameEvents.append("zoomStart")
        }
        guard let plan = actionState[key] as? ZoomPlan else { return }
        let progress = Double(local) / Double(action.duration)
        if plan.target != nil {
            canvas.setViewport(FilmCameraMath.interpolate(plan.v0, plan.v1, p: progress, curve: curve, duration: seconds,
                                                          size: canvas.bounds.size))
        } else {
            canvas.setViewport(Self.interpolate(plan.v0, plan.v1, curve.value(progress, duration: seconds), size: canvas.bounds.size))
        }
        let aim = plan.target.map(pinchAim(world:)) ?? plan.fixed
        let approach = min(FilmPointerMath.pinchApproachFrames, action.duration)
        if local >= approach || hypot(plan.start.x - aim.x, plan.start.y - aim.y) < 0.5 {
            pointer.point = aim
        } else {
            let e = FilmSpring.snappy.normalized(Double(local) / Double(approach), duration: Double(approach) / fps)
            pointer.point = FilmPointerMath.path(from: plan.start, to: aim, e: e, arc: 0)
        }
        pointer.placed = true
        if local >= action.duration {
            pointer.mode = plan.mode
            frameEvents.append("zoomEnd")
        }
    }

    // MARK: Sidebar

    /// The live cell drawing an agent's sidebar row, when the sidebar is on screen and
    /// the row is materialized.
    func sidebarRowCell(_ agentKey: String) -> NSView? {
        guard let agentId = sidebarAgentId(agentKey), let inbox = delegate.filmSidebar?.agentInbox,
              let cell = inbox.filmRowCell(id: agentId),
              cell.window != nil, !cell.isHiddenOrHasHiddenAncestor else { return nil }
        return cell
    }

    /// An agent key's record id, or for "<agent>/<toolUseId>" that agent's subagent's.
    private func sidebarAgentId(_ key: String) -> UUID? {
        if let agent = agents[key] { return agent.agentId.rawValue }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let parent = agents[parts[0]] else { return nil }
        return AgentRecord.observedChildID(parentAgentID: parent.agentId.rawValue, toolUseID: parts[1])
    }

    struct RevealPlan { var v0: CanvasViewport; var v1: CanvasViewport }

    /// A sidebar row click, production's own path (`AgentInboxView.clickRowForQA`: the
    /// table selection, then `onRevealRow` -> `revealAgentFromInbox`: focus, read mark,
    /// sidebar reload). The one difference is the camera: `revealTileForWork` hands its
    /// target to `filmRevealCamera` instead of cutting, and the director glides there on
    /// the cameraModel-v2 split over `dur`.
    private func applyReveal(_ agentKey: String, action: FilmAction, key: String, local: Int) throws {
        let curve = scene.cameraCurve(for: action)
        if local == 0 {
            guard let agent = agents[agentKey] else { throw FilmError("reveal: unknown agent \(agentKey)") }
            guard let inbox = delegate.filmSidebar?.agentInbox else { throw FilmError("reveal \(agentKey): the sidebar is not on screen") }
            let v0 = canvas.viewport
            let framed = canvas.framedViewportForTileJump(agent.tileId)
            let routeBefore = inbox.routeActiveAgentIdForQA
            var production: CanvasViewport?
            delegate.filmRevealCamera = { production = $0 }
            let clicked = inbox.clickRowForQA(id: agent.agentId.rawValue)
            delegate.filmRevealCamera = nil
            if !clicked { warn(key, "reveal \(agentKey): its row is not in the sidebar") }
            if production == nil { warn(key + "/still", "reveal \(agentKey): production framed no camera move") }
            let v1 = production ?? v0
            actionState[key] = RevealPlan(v0: v0, v1: v1)
            reveals.append(RevealRecord(agentKey: agentKey, takeIndex: Int(key.split(separator: "/").first ?? "") ?? 0,
                                        at: action.at, before: v0, framed: framed, production: production,
                                        clicked: clicked, selection: inbox.selectedRowIdsForQA,
                                        focusedTile: delegate.filmFocusedTileId,
                                        routeBefore: routeBefore, routeAfter: inbox.routeActiveAgentIdForQA))
            guardSpeed(key, "reveal", from: v0, to: v1, curve: curve, action: action, staggered: true)
            frameEvents.append("revealStart")
            log("reveal \(agentKey): \(v0) -> \(v1)")
        }
        guard let plan = actionState[key] as? RevealPlan else { return }
        canvas.setViewport(FilmCameraMath.interpolate(plan.v0, plan.v1, p: Double(local) / Double(action.duration), curve: curve,
                                                      duration: Double(action.duration) / fps, size: canvas.bounds.size))
        if local >= action.duration { frameEvents.append("revealEnd") }
    }

    /// The sidebar's History (N) heading, when it is drawn.
    func historyHeaderCell() -> NSView? {
        guard let cell = delegate.filmSidebar?.agentInbox.filmHistoryHeaderCell,
              cell.window != nil, !cell.isHiddenOrHasHiddenAncestor else { return nil }
        return cell
    }

    /// Agent tile key -> the drawn status text of its sidebar row.
    func sidebarStates() -> [String: String] {
        var states: [String: String] = [:]
        for key in agents.keys {
            if let cell = sidebarRowCell(key) as? AgentInbox96CellView { states[key] = cell.qaStateLabel }
        }
        return states
    }

    /// The main window's visible child windows, front-most last, each labelled and in
    /// top-left main-window points: "picker" for the home-folder picker, else the
    /// window's class.
    func childWindowRects() -> [(String, CGRect)] {
        var seen: [String: Int] = [:]
        return (window.childWindows ?? []).filter(\.isVisible).map { child in
            var label = Self.windowLabel(child)
            seen[label, default: 0] += 1
            if seen[label]! > 1 { label += "\(seen[label]!)" }
            let local = window.convertFromScreen(child.frame)
            return (label, CGRect(x: local.minX - contentRect.minX, y: contentRect.maxY - local.maxY,
                                  width: local.width, height: local.height))
        }
    }

    static func windowLabel(_ window: NSWindow) -> String {
        if let content = window.contentView, label(titled: "Choose Project & Home", in: content) != nil { return "picker" }
        return String(describing: type(of: window))
    }

    func carriedCards() -> Set<String> {
        Set(scene.cardKeys.filter { key in
            guard let context = try? boardContext(cardKey: key), let session = context.view.dragSession else { return false }
            return session.cardId == context.cardId && !session.liftedView.isHidden
        })
    }

    /// Every tile and card whose live view intersects the window, in top-left window
    /// points, measured through the view tree (camera, zone layers, lifts included).
    func measureRects() -> [String: CGRect] {
        var rects: [String: CGRect] = [:]
        let tileKeys = Set(scene.tiles.map(\.key)).union(openedTiles.keys).union(adoptedTiles.keys).union(agents.keys)
        for key in tileKeys.sorted() {
            guard let view = canvas.tileView(for: tileId(forKey: key)), view.window != nil,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
            let rect = topLeftRect(of: view, view.bounds)
            if rect.intersects(windowBounds) { rects[key] = rect }
        }
        // Zones (live placement through the camera) and the app's own child windows
        // (the picker panel), each when it intersects the window.
        for key in zoneKeys {
            guard let world = zoneWorldRect(key) else { continue }
            let screen = CanvasEngine.tileScreenFrame(
                TileFrame(x: world.minX, y: world.minY, width: world.width, height: world.height), viewport: canvas.viewport)
            let origin = topLeft(fromCanvas: screen.origin)
            let rect = CGRect(origin: origin, size: screen.size)
            if rect.intersects(windowBounds) { rects["zone:\(key)"] = rect }
        }
        for (label, rect) in childWindowRects() where rect.intersects(windowBounds) { rects["window:\(label)"] = rect }
        for cardKey in scene.cardKeys.sorted() {
            guard let view = cardDisplayView(cardKey), view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
            let rect = topLeftRect(of: view, view.bounds)
            if rect.intersects(windowBounds) { rects["card:\(cardKey)"] = rect }
        }
        if let sidebar = delegate.filmSidebar {
            rects["sidebar"] = topLeftRect(of: sidebar, sidebar.bounds)
            for key in agents.keys {
                guard let cell = sidebarRowCell(key) else { continue }
                let rect = topLeftRect(of: cell, cell.bounds)
                if rect.intersects(windowBounds) { rects["sidebar:\(key)"] = rect }
            }
            if let cell = historyHeaderCell() {
                let rect = topLeftRect(of: cell, cell.bounds)
                if rect.intersects(windowBounds) { rects["sidebar:history"] = rect }
            }
        }
        measureV2Rects(into: &rects)
        return rects
    }

    // MARK: Terminal

    private func applyTerminal(_ key: String, action: FilmAction, key stateKey: String, local: Int) throws {
        guard let tap = terminalTaps[key] else { warn(stateKey, "terminal \(key) has no tap"); return }
        if local == 0 {
            var text = action.text ?? ""
            if let file = action.file { text += try String(contentsOf: scene.resolve(file), encoding: .utf8) }
            // The pty's output processing turns each newline into CR LF.
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            actionState[stateKey] = (Array(text.utf8), 0)
        }
        guard let (bytes, sent) = actionState[stateKey] as? ([UInt8], Int) else { return }
        let target = action.duration == 0 ? bytes.count
            : min(bytes.count, Int((Double(local + 1) / Double(action.duration + 1) * Double(bytes.count)).rounded()))
        // Whole lines at a time read as a program printing, not as typing.
        let cut: Int
        if target >= bytes.count {
            cut = bytes.count
        } else if let newline = bytes[sent..<target].lastIndex(of: 0x0A) {
            cut = newline + 1
        } else {
            cut = sent
        }
        guard cut > sent else { return }
        let chunk = Data(bytes[sent..<cut])
        tap.write(chunk)
        pendingTerminalTails[key] = String(decoding: chunk, as: UTF8.self)
        actionState[stateKey] = (bytes, cut)
    }

    // MARK: Agents

    /// Film seconds, readable from the transcript's `@Sendable` clocks: frame time plus
    /// every forward jump a take's `clock` made (never backwards, so it stays monotone).
    nonisolated(unsafe) static var filmSeconds: Double = 0
    /// The wall clock's fixed shift from `filmEpoch`, so the first take with a `clock`
    /// starts at that time of day (wall readouts only; the monotonic clock never sees it).
    nonisolated(unsafe) static var filmWallShift: Double = 0
    /// Sum of the forward jumps later `clock`s made.
    var clockJump: Double = 0

    /// Film time as a date, for every stamp a readout can show (turn start, elapsed).
    private(set) lazy var filmEpoch = Date()
    var filmDate: Date { filmEpoch.addingTimeInterval(Self.filmWallShift + Double(globalFrame) / fps + clockJump) }

    func deliver(_ event: AgentRuntimeEvent, to agent: AgentHandle, ago: Double = 0) {
        supervisor.qaDeliver(event, to: agent.agentId, now: filmDate.addingTimeInterval(-ago))
    }

    private func applyAgent(_ agentKey: String, action: FilmAction, key: String, local: Int) throws {
        guard var agent = agents[agentKey] else { throw FilmError("unknown agent \(agentKey)") }
        if let child = action.child {
            try applyChild(child, parentKey: agentKey, parent: agent, action: action, key: key, local: local)
            return
        }
        if supervisor.records[agent.agentId]?.harness == .codex {
            try applyCodex(agentKey, action: action, key: key, local: local)
            return
        }
        if supervisor.records[agent.agentId]?.harness == .pi {
            try applyPi(agentKey, action: action, key: key, local: local)
            return
        }
        defer { agents[agentKey] = agent }
        let thread = agent.threadId
        if let text = action.say ?? action.think {
            let stream: ContentStreamKind = action.say != nil ? .assistant : .reasoning
            if local == 0 { actionState["\(key)/paragraph"] = stream == .assistant && agent.proseOpen }
            let paragraph = (actionState["\(key)/paragraph"] as? Bool) == true ? "\n\n" : ""
            streamText(paragraph + text, stream: stream, agent: agent, action: action, key: key, local: local)
            agent.proseOpen = stream == .assistant
            return
        }
        if let open = action.open {
            if local == 0 {
                agent.proseOpen = false
                try startOpen(open, agentKey: agentKey, agent: agent, takeIndex: Int(key.split(separator: "/").first ?? "") ?? 0, at: action.at)
                if let record = opens.last, let production = record.production {
                    actionState[key] = RevealPlan(v0: record.before, v1: production)
                    guardSpeed(key, "open reveal", from: record.before, to: production, curve: scene.cameraCurve(for: action),
                               action: action, staggered: true)
                    frameEvents.append("revealStart")
                }
            }
            // Production's reveal, as a cameraModel-v2 glide over `dur` (a cut when dur is 0).
            if let plan = actionState[key] as? RevealPlan {
                let p = action.duration == 0 ? 1 : Double(local) / Double(action.duration)
                canvas.setViewport(FilmCameraMath.interpolate(plan.v0, plan.v1, p: p, curve: scene.cameraCurve(for: action),
                                                              duration: Double(action.duration) / fps, size: canvas.bounds.size))
                if local == action.duration { frameEvents.append("revealEnd") }
            }
            if local == action.duration { completeOpen(open, agentKey: agentKey, agent: agent) }
            delegate.filmRefreshAgentSurfaces()
            return
        }
        guard local == 0 else { return }
        agent.proseOpen = false
        if let prompt = action.prompt {
            agentView(agentKey)?.appendUserPrompt(prompt)
        } else if let turn = action.turn {
            switch turn {
            case "start":
                agent.turnCount += 1
                let turnId = "film-\(agentKey)-\(agent.turnCount)"
                agent.turnId = turnId
                deliver(.sessionStateChanged(.running), to: agent, ago: action.ago ?? 0)
                deliver(.turnStarted(threadId: thread, turnId: turnId), to: agent, ago: action.ago ?? 0)
            case "done", "failed":
                let end: [AgentRuntimeEvent] = [
                    .turnCompleted(threadId: thread, turnId: agent.turnId ?? "film", outcome: turn == "done" ? .completed : .failed,
                                   errorMessage: nil),
                    .sessionStateChanged(.ready),
                ]
                // A real composer send holds a runner: the turn ends through it, as a CLI's would.
                if let runner = FilmAgentRunner.inFlight(for: agent.agentId) {
                    runner.complete(with: end)
                    pendingRunnerCompletions.insert(agentKey)
                } else {
                    for event in end { deliver(event, to: agent) }
                }
            default:
                throw FilmError("turn \(turn)")
            }
        } else if let tool = action.tool, let name = tool.name {
            try startClaudeTool(tool, name: name, agentKey: agentKey, agent: agent)
        } else if let tool = action.tool, let title = tool.title {
            let kind = ItemKind(rawValue: tool.kind ?? "") ?? .commandExecution
            var fields: [(key: String, value: String)] = []
            if let path = tool.path { fields.append((key: "file", value: URL(fileURLWithPath: path).lastPathComponent)) }
            if let pattern = tool.pattern { fields.append((key: "pattern", value: pattern)) }
            if let command = tool.command { fields.append((key: "description", value: command)) }
            let changes = tool.path.flatMap { path -> [AgentToolDetailObservation.FileChange]? in
                guard let actionName = tool.action else { return nil }
                return [AgentToolDetailObservation.FileChange(
                    action: AgentToolDetailObservation.FileAction(rawValue: actionName) ?? .edit, path: path,
                    addedLines: tool.added, removedLines: tool.removed)]
            } ?? []
            supervisor.qaObserve(.toolDetail(itemId: tool.id, detail: AgentToolDetailObservation(
                phase: .started, toolName: title, fields: fields, fileChanges: changes,
                observedAt: filmDate)), for: agent.agentId)
            deliver(.itemStarted(threadId: thread, itemId: tool.id, kind: kind, title: title), to: agent)
            actionState["tool/\(agentKey)/\(tool.id)"] = (kind, tool.output)
        } else if let toolId = action.toolDone, let reply = actionState["claudeTool/\(agentKey)/\(toolId)"] as? String {
            // A runner-spelled tool completes the way claude reports it: its tool_result.
            try feedClaude(["type": "user", "message": ["content": [[
                "type": "tool_result", "tool_use_id": toolId, "is_error": action.status == "failed",
                "content": [["type": "text", "text": reply]],
            ]]]], agentKey: agentKey, agent: agent)
        } else if let toolId = action.toolDone {
            let stored = actionState["tool/\(agentKey)/\(toolId)"] as? (ItemKind, String?)
            if let output = stored?.1 {
                supervisor.qaObserve(.toolDetail(itemId: toolId, detail: AgentToolDetailObservation(
                    phase: .ended, outputPreview: output, exitCode: 0, observedAt: filmDate)), for: agent.agentId)
            }
            let status = ItemStatus(rawValue: action.status ?? "completed") ?? .completed
            deliver(.itemCompleted(threadId: thread, itemId: toolId, kind: stored?.0 ?? .commandExecution, status: status), to: agent)
        } else if let requestId = action.request {
            let kind = ApprovalKind(rawValue: action.requestKind ?? "commandExecutionApproval") ?? .commandExecutionApproval
            deliver(.requestOpened(threadId: thread, requestId: requestId, kind: kind), to: agent)
        } else if let requestId = action.resolve {
            deliver(.requestResolved(threadId: thread, requestId: requestId, decision: action.decision ?? "approve"), to: agent)
        }
        delegate.filmRefreshAgentSurfaces()
    }

    // MARK: Open (Array's own workspace tool)

    /// The claude runner's tool_use for the open, the open itself through the host's
    /// MCP handler, and the opened tile registered under `as`.
    private func startOpen(_ open: FilmAction.Open, agentKey: String, agent: AgentHandle, takeIndex: Int, at: Int) throws {
        let tool = ArrayWorkspaceTool.openDocument
        let input: [String: Any] = ["relativePath": open.path]
        try feedClaude(["type": "assistant", "message": ["content": [[
            "type": "tool_use", "id": open.toolId, "name": ArrayWorkspaceTool.mcpPrefix + tool.rawValue, "input": input,
        ]]]], agentKey: agentKey, agent: agent)
        let before = canvas.viewport
        // Production's reveal cut is handed to the director (glided in `applyAgent`).
        var production: CanvasViewport?
        delegate.workspaceAPI.filmRevealCamera = { production = $0 }
        defer { delegate.workspaceAPI.filmRevealCamera = nil }
        let reply = try callWorkspaceMCP(tool, input: input, requestId: "film-\(open.toolId)", agent: agent)
        guard (reply["status"] as? String) == "ok", let object = reply["result"],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let result = try? JSONDecoder().decode(ArtifactOpenResult.self, from: data),
              let tileId = result.tileId else {
            throw FilmError("open \(open.path) as \(agentKey): the workspace API answered \(reply)")
        }
        openedTiles[open.as] = tileId
        opens.append(OpenRecord(key: open.as, agentKey: agentKey, path: open.path, toolId: open.toolId, takeIndex: takeIndex,
                                at: at, result: result, tileId: tileId, before: before, after: canvas.viewport,
                                production: production))
        // What the MCP server returns to claude: the reply as one text block.
        let replyText = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        actionState["open/\(agentKey)/\(open.toolId)"] = replyText
        log("open \(open.path) as \(open.as) by \(agentKey): document \(result.document.rawValue), placement \(result.placement.rawValue), "
            + "rect \(result.actualWorldRect.map { "\($0)" } ?? "nil"), presentation \(result.presentation.rawValue), camera \(result.presentationEffects.camera)")
    }

    /// Exactly the body `array-workspace-mcp` posts for a tool call (its `call`),
    /// received where `WorkspaceMCPHost` hands it on once the capability checks out.
    private func callWorkspaceMCP(_ tool: ArrayWorkspaceTool, input: [String: Any], requestId: String,
                                  agent: AgentHandle) throws -> [String: Any] {
        guard let catalogued = WorkspaceMCPToolCatalog.tool(named: tool.rawValue) else {
            throw FilmError("\(tool.rawValue) is not in the workspace MCP catalogue")
        }
        return delegate.filmHandleWorkspaceMCP([
            "schema": WorkspaceAPISchema.v1, "kind": "request", "requestId": requestId,
            "agentId": agent.agentId.rawValue.uuidString, "op": catalogued.operation.rawValue, "payload": input,
        ])
    }

    /// A runner-spelled `tool`: claude's tool_use through the production translator,
    /// and, for an Array workspace tool, the real call through the host's MCP handler.
    /// `toolDone` later reports the tool_result (the host's reply, or `output`).
    private func startClaudeTool(_ tool: FilmAction.Tool, name: String, agentKey: String, agent: AgentHandle) throws {
        let input = try resolvedInput(tool)
        try feedClaude(["type": "assistant", "message": ["content": [[
            "type": "tool_use", "id": tool.id, "name": name, "input": input,
        ]]]], agentKey: agentKey, agent: agent)
        var reply = tool.output ?? ""
        if name.hasPrefix(ArrayWorkspaceTool.mcpPrefix), let workspaceTool = ArrayWorkspaceTool(toolName: name) {
            let answer = try callWorkspaceMCP(workspaceTool, input: input, requestId: "film-\(tool.id)", agent: agent)
            guard (answer["status"] as? String) == "ok" else { throw FilmError("tool \(name) as \(agentKey): the workspace API answered \(answer)") }
            reply = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            log("tool \(name) by \(agentKey): ok (\(reply.utf8.count) bytes)")
            if let bind = tool.bind { try bindCreatedCard(bind, answer: answer, input: input) }
        }
        actionState["claudeTool/\(agentKey)/\(tool.id)"] = reply
    }

    /// The tool_result claude reports once the MCP call returns.
    private func completeOpen(_ open: FilmAction.Open, agentKey: String, agent: AgentHandle) {
        let reply = actionState["open/\(agentKey)/\(open.toolId)"] as? String ?? "{}"
        try? feedClaude(["type": "user", "message": ["content": [[
            "type": "tool_result", "tool_use_id": open.toolId, "content": [["type": "text", "text": reply]],
        ]]]], agentKey: agentKey, agent: agent)
    }

    /// One stream-json line through the agent's production claude translator: its
    /// host-local observations through the supervisor's fan-out, then its events,
    /// restamped onto the agent's thread as the supervisor does for a live run.
    ///
    /// The translator's two subagent seams are wired as `AgentSupervisor` wires a live
    /// runner's (`observeSpawnRequests` -> `handleSpawnRequest(_:from:)`,
    /// `observeSubagentEvents` -> `deliverSubagentEvent`): an `Agent`/`Task` tool_use
    /// makes the observed child record (its chip and nested sidebar row), and a frame
    /// carrying `parent_tool_use_id` is the child's own work. Production hops both to
    /// the main queue after the line; so do these, after the line's own events.
    func feedClaude(_ object: [String: Any], agentKey: String, agent: AgentHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let epoch = filmEpoch, shift = Self.filmWallShift
        var translator = claudeTranslators[agentKey] ?? ClaudeEventTranslator(
            workingDirectory: supervisor.records[agent.agentId].map { URL(fileURLWithPath: $0.checkoutRoot, isDirectory: true) },
            runToken: "film-\(agentKey)", now: { epoch.addingTimeInterval(shift + FilmDirector.filmSeconds) })
        let box = FilmObservationBox()
        translator.onRuntimeObservation = box.append
        translator.onSpawnRequest = box.spawn
        translator.onSubagentEvent = box.subagent
        let events = translator.translate(line: String(decoding: data, as: UTF8.self))
        translator.onRuntimeObservation = nil
        translator.onSpawnRequest = nil
        translator.onSubagentEvent = nil
        claudeTranslators[agentKey] = translator
        for observation in box.drain() { supervisor.qaObserve(observation, for: agent.agentId) }
        for event in events { deliver(event.withThreadId(agent.threadId), to: agent) }
        for request in box.drainSpawns() {
            let child = supervisor.handleSpawnRequest(request, from: agent.agentId)
            log("spawn: \(agentKey) -> \(request.displayLabel ?? request.role ?? "child") \(child.map { "\($0.rawValue)" } ?? "REFUSED")")
        }
        for (toolUseID, event) in box.drainSubagentEvents() {
            supervisor.qaDeliverSubagentEvent(event, parent: agent.agentId, toolUseID: toolUseID, now: filmDate)
        }
    }

    /// Streams `text` across the action's frames, cutting at word ends so the tail
    /// grows a word at a time rather than a character at a time.
    private func streamText(_ text: String, stream: ContentStreamKind, agent: AgentHandle, action: FilmAction, key: String, local: Int) {
        let characters = Array(text)
        let sent = (actionState[key] as? Int) ?? 0
        guard let target = streamTarget(characters, action: action, local: local, sent: sent) else { return }
        deliver(.contentDelta(threadId: agent.threadId, turnId: agent.turnId ?? "film", streamKind: stream,
                              delta: String(characters[sent..<target])), to: agent)
        actionState[key] = target
    }
}

/// Collects a translator's observations, spawn requests and child frames; they are
/// replayed on the main actor.
final class FilmObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRuntimeObservation] = []
    private var spawns: [SpawnRequest] = []
    private var children: [(String, AgentRuntimeEvent)] = []
    func append(_ value: AgentRuntimeObservation) { lock.withLock { values.append(value) } }
    func spawn(_ request: SpawnRequest) { lock.withLock { spawns.append(request) } }
    func subagent(_ toolUseID: String, _ event: AgentRuntimeEvent) { lock.withLock { children.append((toolUseID, event)) } }
    func drain() -> [AgentRuntimeObservation] { lock.withLock { defer { values = [] }; return values } }
    func drainSpawns() -> [SpawnRequest] { lock.withLock { defer { spawns = [] }; return spawns } }
    func drainSubagentEvents() -> [(String, AgentRuntimeEvent)] { lock.withLock { defer { children = [] }; return children } }
}

/// Cubic-bezier easing. `cam` is the house camera curve (0.48, 0.1, 0, 0.9).
struct FilmEase {
    let p1: (Double, Double)
    let p2: (Double, Double)

    static let cam = FilmEase(p1: (0.48, 0.1), p2: (0.0, 0.9))
    static let inOut = FilmEase(p1: (0.65, 0.0), p2: (0.35, 1.0))
    /// cameraModel v2's default: zero start slope, a long soft landing.
    static let pan = FilmEase(p1: (0.4, 0.0), p2: (0.2, 1.0))
    static let linear = FilmEase(p1: (0, 0), p2: (1, 1))

    static func named(_ name: String?) -> FilmEase {
        switch name {
        case "linear": return .linear
        case "inOut": return .inOut
        default: return .cam
        }
    }

    func value(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        // Bisection on x(s) = x: monotone for these control points, and exact enough.
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if bezier(mid, p1.0, p2.0) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, p1.1, p2.1)
    }
}

/// Film runs only (`BrowserEngineContext.makeWebView` adds it when `--film` is on the
/// command line): WebKit content runs on the wall clock, not the film clock, so every
/// CSS animation and transition is pinned. A zero-length, single-iteration, both-filled
/// animation sits on its FINAL keyframe from the first frame: entrance animations that
/// start at opacity 0 land visible, and infinite drifts and spinners hold their end pose
/// (which, for a loop, is its start pose). Script-made Web Animations (`Element.animate`,
/// e.g. the site's gyro) get the same treatment: infinite ones pinned at time 0, finite
/// ones finished. Nothing about the page's timing is left.
enum FilmWebFreeze {
    static let css = """
    *, *::before, *::after {
      animation-duration: 0s !important;
      animation-delay: 0s !important;
      animation-iteration-count: 1 !important;
      animation-fill-mode: both !important;
      animation-play-state: paused !important;
      transition: none !important;
      caret-color: transparent !important;
      scroll-behavior: auto !important;
    }
    """

    static var source: String {
        let literal = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        return """
        (() => {
          const style = document.createElement('style');
          style.id = 'array-film-freeze';
          style.textContent = `\(literal)`;
          (document.head || document.documentElement).appendChild(style);
          // Script-made animations (Element.animate) are not CSS: an infinite one is
          // pinned at time 0 and cannot be re-phased or restarted; a finite one finishes.
          const animate = Element.prototype.animate;
          Element.prototype.animate = function (keyframes, options) {
            const animation = animate.call(this, keyframes, options);
            const timing = animation.effect && animation.effect.getComputedTiming ? animation.effect.getComputedTiming() : {};
            if (timing.iterations === Infinity) {
              animation.pause();
              animation.currentTime = 0;
              Object.defineProperty(animation, 'currentTime', { configurable: true, get() { return 0; }, set() {} });
              Object.defineProperty(animation, 'startTime', { configurable: true, get() { return null; }, set() {} });
              animation.play = function () {};
            } else {
              try { animation.finish(); } catch (error) {}
            }
            return animation;
          };
        })();
        """
    }

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
#endif
