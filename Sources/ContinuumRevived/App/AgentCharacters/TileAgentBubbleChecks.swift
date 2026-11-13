import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ObjectiveC

// The agent's icon in a bubble at its tile's top-right corner.
//
// `--tile-agent-bubble-check`: four real agent tiles in a tinted zone, attached to
// a real supervisor with identity colours, two of them working. Asserts the
// bubble's place and size at every chrome scale bucket (and that its layer is
// drawn where the view says it is), that the band's controls and the title stay
// clear of it, the working light following the agent's status and the sidebar's
// style, the identity colour, the Minimal/Orb setting live, the bubble holding
// still out of sight, a camera pan costing it nothing, and icons off restoring
// today's bar. `TILE_AGENT_BUBBLE_PNG_DIR=<dir>` writes both styles in light and
// dark at two zooms; `TILE_AGENT_BUBBLE_FILM_DIR=<dir>` writes frames of the
// working light. The matrix sets neither.
//
// `--tile-agent-bubble-drag-check`: on the production mount, a drag that starts
// on the bubble moves the tile through `NSApp.sendEvent` (local monitors, the
// window's hit-test, AppKit's drag routing) — including from the part of the
// bubble that lies in the corner's resize band — at zoom 1 and 0.5.
@MainActor
enum TileAgentBubbleChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    static func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static func acceptFirstMouseEverywhere() {
        for cls in [NSView.self, NSTextView.self] {
            guard let method = class_getInstanceMethod(cls, #selector(NSView.acceptsFirstMouse(for:))) else { continue }
            let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
            method_setImplementation(method, imp_implementationWithBlock(always))
        }
    }

    private static func setSetting(_ defaults: UserDefaults, _ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        SettingChangeEvent.post(SettingID(rawValue: key))
    }

    // MARK: Render, geometry and state

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-tile-bubble-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayTileAgentBubbleChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        try expect(controller.bubbleStyle == .minimal, "the bubble is Minimal by default")

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }

        // Four agents: three colours and one without, two of them working.
        let specs: [(name: String, colour: String?, working: Bool)] = [
            ("Rework the sign-in screen", "teal", true),
            ("Profile the pinch", "purple", false),
            ("Fix the flaky upload test", "orange", true),
            ("Write the release notes", nil, false),
        ]
        var agents: [AgentID] = []
        for spec in specs {
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                                      model: "anthropic/claude-haiku-4-5-20251001", thinking: "low",
                                      displayName: spec.name)
            if let colour = spec.colour { _ = supervisor.setIdentityColor(agentID: id, colour) }
            agents.append(id)
        }

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [],
                                     lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: true)
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(x: 0, y: 0, width: 1_240, height: 780)
        canvas.occlusionVisibilityProvider = { true }
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil); window.contentView = nil }

        let zoneId = UUID()
        let placement = ZonePlacement(
            zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 20, y: 20),
            size: ZoneSize(width: 1_200, height: 740), color: "blue", collapsed: false, hydrationPolicy: .automatic)
        var tiles: [Tile] = []
        let size = (width: 560.0, height: 320.0), gap = 8.0
        for index in 0..<4 {
            let column = Double(index % 2), row = Double(index / 2)
            tiles.append(Tile(
                id: UUID(), kind: .managedAgent, title: specs[index].name,
                frame: TileFrame(x: 50 + column * (size.width + gap), y: 90 + row * (size.height + gap),
                                 width: size.width, height: size.height),
                zPosition: .fromLegacyRank(index + 1), zoneId: zoneId, runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
        }
        let layer = CanvasNSView.ZoneLayer(
            placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Bubbles"),
            tiles: tiles)
        var views: [ManagedAgentTileNSView] = []
        for tile in tiles {
            let view = ManagedAgentTileNSView(tile: tile)
            views.append(view)
            layer.tileViews[tile.id] = view
        }
        canvas.setZones([layer])
        canvas.layoutSubtreeIfNeeded()
        for (view, agent) in zip(views, agents) { view.attach(agentID: agent, supervisor: supervisor) }
        canvas.layoutSubtreeIfNeeded()
        for (index, agent) in agents.enumerated() where specs[index].working {
            supervisor.qaDeliver(.turnStarted(threadId: "t\(index)", turnId: "u\(index)"), to: agent)
            supervisor.qaDeliver(.itemStarted(threadId: "t\(index)", itemId: "e\(index)", kind: .fileChange,
                                              title: "Sources/App.swift"), to: agent)
        }
        try expect(pump(until: { views.allSatisfy { $0.agentBubbleFrame != nil } }),
                   "every attached agent's tile shows its bubble")

        // 1. State: the working light follows the status; the colour follows the record.
        try expect(pump(until: {
            zip(views, specs).allSatisfy { view, spec in view.qaAgentBubble?.isWorking == spec.working }
        }), "the working light follows the agent's status: "
            + views.map { "\($0.agentStatus.map(\.rawValue) ?? "nil")=\($0.qaAgentBubble?.isWorking == true)" }.joined(separator: ", "))
        for (view, spec) in zip(views, specs) {
            let bubble = view.qaAgentBubble!
            try expect(bubble.isMoving == spec.working,
                       "\(spec.name): a working bubble moves and an idle one holds still (moving \(bubble.isMoving))")
            try expect(spec.working == !bubble.qaAnimationKeys.isEmpty,
                       "\(spec.name): animations \(bubble.qaAnimationKeys)")
            let expected = spec.colour.map { ZoneChromeNSView.color(named: $0) }
            try expect(bubble.tint == expected, "\(spec.name): the bubble wears the agent's colour (\(String(describing: bubble.tint)))")
        }
        _ = supervisor.setIdentityColor(agentID: agents[3], "mint")
        try expect(pump(until: { views[3].qaAgentBubble?.tint == ZoneChromeNSView.color(named: "mint") }),
                   "a new identity colour reaches the bubble")
        _ = supervisor.setIdentityColor(agentID: agents[3], nil)
        try expect(pump(until: { views[3].qaAgentBubble?.tint == nil }), "clearing the colour reaches the bubble")

        // 2. Geometry at every chrome scale bucket.
        var buckets: Set<Double> = []
        for zoom in [1.0, 0.75, 0.5, 0.35, 0.2, 1.6] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded() }
            for (index, view) in views.enumerated() {
                let label = "zoom \(zoom) tile \(index)"
                guard let frame = view.agentBubbleFrame, let bubble = view.qaAgentBubble,
                      let bar = view.qaTitleBarView else { throw Failure(description: "\(label): no bubble") }
                let chrome = view.zoomChromeScale
                buckets.insert(Double(chrome))
                let side = TileNSView.agentBubbleSide * max(chrome, view.titleBarScale)
                try expect(abs(frame.width - side) < 0.01 && abs(frame.height - side) < 0.01,
                           "\(label): a \(side) pt bubble at chrome scale \(chrome), got \(frame.size)")
                try expect(frame.width * zoom >= TileNSView.agentBubbleSide - 0.01,
                           "\(label): never smaller than \(TileNSView.agentBubbleSide) pt on screen (\(frame.width * zoom))")
                let pixel = 1 / ((window.backingScaleFactor) * zoom) + 0.01
                let inset = TileNSView.agentBubbleInset * max(chrome, view.titleBarScale)
                try expect(abs(view.bounds.width - frame.maxX - inset) <= pixel && abs(frame.minY - inset) <= pixel,
                           "\(label): tucked \(inset) pt into the top-right corner, got right \(view.bounds.width - frame.maxX) top \(frame.minY)")
                // The layer is drawn where the view says the bubble is (a flipped
                // host would otherwise put it at the bottom of the tile).
                let drawn = view.convertFromLayer(bubble.frame)
                try expect(abs(drawn.minX - frame.minX) < 0.01 && abs(drawn.minY - frame.minY) < 0.01
                           && abs(drawn.width - frame.width) < 0.01,
                           "\(label): the bubble's layer is drawn at \(drawn), the view expects \(frame)")
                if let sprite = view.qaCharacterRect {
                    let inTile = bar.convert(sprite, to: view)
                    try expect(abs(inTile.midX - frame.midX) <= pixel && abs(inTile.midY - frame.midY) <= pixel,
                               "\(label): the icon is centred in its bubble (\(inTile) in \(frame))")
                    try expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(inTile.insetBy(dx: 0, dy: 0)) || inTile.width > frame.width,
                               "\(label): the icon sits inside its bubble")
                }
                let close = view.qaCloseButtonFrame
                try expect(close.maxX <= frame.minX + 0.01, "\(label): × stays clear of the bubble (\(close.maxX) vs \(frame.minX))")
                if let actions = view.titleBarActionsFrameForQA, actions.width > 0 {
                    try expect(actions.maxX <= frame.minX + 0.01, "\(label): ⋯ stays clear of the bubble")
                }
                if let title = view.qaTitleRectInBar(), title.width > 0 {
                    try expect(bar.convert(title, to: view).maxX <= frame.minX, "\(label): the title stops before the bubble")
                }
                if let pill = view.qaStatusPillRectInBar() {
                    try expect(!bar.convert(pill, to: view).intersects(frame), "\(label): the status pill never runs under the bubble")
                }
                try expect(view.bounds.contains(frame), "\(label): the bubble stays inside its tile, clear of its neighbours")
            }
        }
        try expect(buckets.count >= 3, "the sweep crossed several chrome scale buckets: \(buckets.sorted())")

        // 3. A camera pan costs the bubble nothing: no new motion, no bar redraw.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let installs = TileAgentBubbleLayer.motionInstallCount
        let redraws = views.map(\.qaTitleBarRedrawCount)
        let bubbleFrames = views.map { $0.qaAgentBubble?.frame }
        for step in 1...24 {
            canvas.setViewport(CanvasViewport(x: Double(step) * 9, y: Double(step) * 4, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        try expect(TileAgentBubbleLayer.motionInstallCount == installs, "a pan re-installed a bubble's motion")
        try expect(views.map(\.qaTitleBarRedrawCount) == redraws, "a pan redrew a title bar")
        try expect(views.map { $0.qaAgentBubble?.frame } == bubbleFrames, "a pan moved a bubble inside its tile")
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()

        // 4. Out of sight it holds still; back in sight it moves again.
        controller.windowIsVisible = { _ in false }
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(pump(until: { !views[0].qaAgentBubble!.isMoving }), "a hidden window's bubble holds still")
        controller.windowIsVisible = { _ in true }
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(pump(until: { views[0].qaAgentBubble!.isMoving }), "back in sight it moves again")

        // 5. Every sidebar style lends its light; the Orb setting reaches every tile live.
        for style in SidebarActiveIndicatorStyle.allCases {
            setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, style.rawValue)
            try expect(pump(until: { views[0].qaAgentBubble?.workingStyle == style.rawValue }),
                       "the sidebar's \(style.title) style reaches the bubble")
            try expect(views[0].qaAgentBubble?.isMoving == true && views[1].qaAgentBubble?.isMoving == false,
                       "\(style.title): only working agents move")
        }
        setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, SidebarActiveIndicatorStyle.fallback.rawValue)
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, AgentCharacterConfig.BubbleStyle.orb.rawValue)
        try expect(pump(until: { views.allSatisfy { $0.qaAgentBubble?.bubbleStyle == .orb } }), "Orb reaches every tile live")
        try expect(views[0].qaAgentBubble?.qaParts.sphereShown == true && views[0].qaAgentBubble?.qaParts.glossShown == true,
                   "an Orb draws its sphere and gloss")
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, AgentCharacterConfig.BubbleStyle.minimal.rawValue)
        try expect(pump(until: { views.allSatisfy { $0.qaAgentBubble?.bubbleStyle == .minimal } }), "Minimal comes back live")
        try expect(views[0].qaAgentBubble?.qaParts.sphereShown == false, "Minimal draws no sphere")

        // 6. Review renders and film, when asked for.
        var notes: [String] = []
        if let path = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_PNG_DIR"], !path.isEmpty {
            notes += try writeRenders(canvas: canvas, window: window, defaults: defaults,
                                      to: URL(fileURLWithPath: path, isDirectory: true))
        }
        if let path = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_FILM_DIR"], !path.isEmpty {
            notes += try writeFilm(canvas: canvas, window: window, defaults: defaults, views: views,
                                   to: URL(fileURLWithPath: path, isDirectory: true))
        }

        // 7. Icons off: no bubble, and the band's controls go back to today's place.
        setSetting(defaults, AgentCharacterConfig.enabledKey, false)
        try expect(pump(until: { views.allSatisfy { $0.agentBubbleFrame == nil } }), "icons off removes every bubble")
        canvas.layoutSubtreeIfNeeded()
        for view in views {
            try expect(view.qaAgentBubble?.isMoving == false, "a removed bubble holds still")
            try expect(abs(view.bounds.width - view.qaCloseButtonFrame.maxX - 10) < 0.01,
                       "icons off puts × back 10 pt from the edge (\(view.bounds.width - view.qaCloseButtonFrame.maxX))")
        }
        return (["tile agent bubble: \(views.count) tiles, buckets \(buckets.sorted()), PASS"] + notes).joined(separator: "\n")
    }

    // MARK: Pictures

    /// The window server's composite of `rect` (canvas coordinates).
    static func capture(_ canvas: CanvasNSView, _ window: NSWindow, rect: NSRect) throws -> CGImage {
        canvas.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        pump(0.15)
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
        ) else { throw Failure(description: "the window server returned no image of the check's own window") }
        guard let host = window.contentView else { throw Failure(description: "no content view") }
        let scale = CGFloat(image.width) / host.bounds.width
        let inHost = canvas.convert(rect, to: host)
        let y = host.isFlipped ? inHost.minY : host.bounds.height - inHost.maxY
        let crop = CGRect(x: inHost.minX * scale, y: y * scale, width: inHost.width * scale, height: inHost.height * scale).integral
        guard let cropped = image.cropping(to: crop) else { throw Failure(description: "could not crop \(rect)") }
        return cropped
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }

    private static func writeRenders(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                     to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for style in AgentCharacterConfig.BubbleStyle.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            pump(0.2)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                // Whole zone at 1 and at 0.5 (the 0.5 picture is the same window, zoomed out).
                for zoom in [1.0, 0.5] {
                    canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                    pump(0.3)
                    let image = try capture(canvas, window, rect: canvas.bounds)
                    let url = directory.appendingPathComponent("bubble-\(style.rawValue)-\(name)-zoom\(zoom == 1 ? "100" : "50").png")
                    try write(image, to: url)
                    written.append(url.path)
                }
                // A close-up of two neighbours' corners at 200%.
                canvas.setViewport(CanvasViewport(x: 380, y: 60, zoom: 2))
                pump(0.3)
                let close = try capture(canvas, window, rect: NSRect(x: 260, y: 0, width: 760, height: 380))
                let url = directory.appendingPathComponent("bubble-\(style.rawValue)-\(name)-closeup200.png")
                try write(close, to: url)
                written.append(url.path)
            }
        }
        window.appearance = nil
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, AgentCharacterConfig.BubbleStyle.minimal.rawValue)
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump(0.2)
        return written.map { "wrote \($0)" }
    }

    /// Frames of the working light, every sidebar style, both bubble styles: the
    /// two working tiles' corners at 200%, 0.25 s apart.
    private static func writeFilm(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                  views: [ManagedAgentTileNSView], to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        window.appearance = NSAppearance(named: .darkAqua)
        canvas.setViewport(CanvasViewport(x: 380, y: 60, zoom: 2))
        for style in AgentCharacterConfig.BubbleStyle.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            for working in SidebarActiveIndicatorStyle.allCases {
                setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, working.rawValue)
                pump(0.3)
                for frame in 0..<12 {
                    let image = try capture(canvas, window, rect: NSRect(x: 360, y: 0, width: 560, height: 200))
                    try write(image, to: directory.appendingPathComponent(
                        "working-\(style.rawValue)-\(working.rawValue)-\(String(format: "%02d", frame)).png"))
                    written += 1
                    pump(0.1)
                }
            }
        }
        setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, SidebarActiveIndicatorStyle.fallback.rawValue)
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, AgentCharacterConfig.BubbleStyle.minimal.rawValue)
        window.appearance = nil
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump(0.2)
        return ["wrote \(written) working frames to \(directory.path)"]
    }

    // MARK: Drag from the bubble, on the production mount

    static func runDrag() async throws -> String {
        acceptFirstMouseEverywhere()
        var lines: [String] = []
        for zoom in [1.0, 0.5] { lines.append(try await exerciseDrag(zoom: zoom)) }
        return lines.joined(separator: "\n")
    }

    private static func exerciseDrag(zoom: Double) async throws -> String {
        let label = "zoom=\(zoom)"
        let suite = "ArrayTileAgentBubbleDrag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)

        let agentTile = TileInsertSlideChecks.tileA
        let fixture = try TileInsertSlideChecks.makeFixture("tile-bubble")
        defer { fixture.dispose() }
        let workspaceStore = WorkspaceStore(workspaceId: WorkspaceInvariantsFixture.workspaceA,
                                            applicationSupportDirectory: fixture.appSupport)
        var document = try workspaceStore.load()
        if let index = document.zones.firstIndex(where: { $0.zoneId == WorkspaceInvariantsFixture.zoneA1 }) {
            document.zones[index].size = ZoneSize(width: 2400, height: 1200)
        }
        try workspaceStore.save(document)
        let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        let projectStore = ProjectStore(projectRoot: root)
        var state = try projectStore.loadCanvas()
        guard let index = state.tiles.firstIndex(where: { $0.id == agentTile }) else {
            throw Failure(description: "\(label): seed has no tile A")
        }
        state.tiles[index].kind = .managedAgent
        state.tiles[index].metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
        state.tiles[index].frame = TileFrame(x: 600, y: 520, width: 360, height: 260)
        try projectStore.saveCanvas(state)
        var agent: AgentID?
        let appSupport = fixture.appSupport
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            agent = delegate.agentSupervisor.spawn(
                role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: "fixture/bubble", thinking: "medium",
                projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root, tileId: agentTile, displayName: "Alpha")
        }
        try fixture.mount()
        let mounted = try fixture.requireMounted("tile bubble drag")
        let canvas = mounted.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: zoom))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        guard let agent else { throw Failure(description: "\(label): no agent") }
        mounted.delegate.wireManagedAgentTile(agentTile, agentID: agent)
        _ = mounted.delegate.agentSupervisor.setIdentityColor(agentID: agent, "purple")
        mounted.delegate.qaInstallTileFocusMonitor()
        defer { mounted.delegate.qaRemoveTileFocusMonitor() }
        canvas.layoutSubtreeIfNeeded()
        guard let view = canvas.tileView(for: agentTile) else { throw Failure(description: "\(label): tile A has no view") }
        try expect(pump(until: { canvas.layoutSubtreeIfNeeded(); return view.agentBubbleFrame != nil }),
                   "\(label): the production tile shows its bubble")

        func world() -> TileFrame? { canvas.allTilesInWorldFrames().first { $0.id == agentTile }?.frame }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }
        let filmDirectory = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_FILM_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let filmDirectory { try FileManager.default.createDirectory(at: filmDirectory, withIntermediateDirectories: true) }
        var filmed = 0
        func film(_ name: String) throws {
            guard let filmDirectory, zoom == 1 else { return }
            let around = view.frame.insetBy(dx: -80, dy: -80)
            let image = try capture(canvas, window, rect: canvas.convert(around, from: view.superview))
            try write(image, to: filmDirectory.appendingPathComponent("drag-\(name).png"))
            filmed += 1
        }

        /// Drag from `local` (tile coordinates) by `delta` screen points in three steps.
        func drag(from local: NSPoint, by delta: CGSize, name: String) throws -> (before: TileFrame, after: TileFrame) {
            guard let before = world() else { throw Failure(description: "\(label): no world frame") }
            let start = view.convert(local, to: nil)
            // The real hit-test answers the tile itself, not the bar or the body.
            if let host = canvas.superview {
                let hit = canvas.hitTest(canvas.convert(canvas.convert(start, from: nil), to: host))
                try expect(hit === view, "\(label) \(name): a press on the bubble hit \(String(describing: hit.map { type(of: $0) }))")
            }
            try send(.leftMouseDown, start)
            try film("\(name)-0")
            for (step, t) in [0.33, 0.66, 1.0].enumerated() {
                try send(.leftMouseDragged, NSPoint(x: start.x + delta.width * t, y: start.y - delta.height * t))
                canvas.layoutSubtreeIfNeeded()
                try film("\(name)-\(step + 1)")
            }
            try send(.leftMouseUp, NSPoint(x: start.x + delta.width, y: start.y - delta.height))
            canvas.layoutSubtreeIfNeeded()
            try film("\(name)-4")
            guard let after = world() else { throw Failure(description: "\(label): no world frame after the drag") }
            return (before, after)
        }

        // 1. From the bubble's centre.
        guard let bubble = view.agentBubbleFrame else { throw Failure(description: "\(label): no bubble") }
        try expect(view.qaDragKindIsMove(at: NSPoint(x: bubble.midX, y: bubble.midY)), "\(label): the bubble's centre is a grab")
        let centre = try drag(from: NSPoint(x: bubble.midX, y: bubble.midY), by: CGSize(width: 48, height: 36), name: "centre")
        try expect(centre.after.width == centre.before.width && centre.after.height == centre.before.height,
                   "\(label): dragging the bubble resized the tile (\(centre.before) → \(centre.after))")
        let moved = (x: centre.after.x - centre.before.x, y: centre.after.y - centre.before.y)
        try expect(abs(moved.x - 48 / zoom) < 2 / zoom && abs(moved.y - 36 / zoom) < 2 / zoom,
                   "\(label): the tile follows the bubble by the pointer's delta (moved \(moved), expected \((48 / zoom, 36 / zoom)))")

        // 2. From the part of the bubble that lies in the corner's resize band.
        canvas.layoutSubtreeIfNeeded()
        guard let again = view.agentBubbleFrame else { throw Failure(description: "\(label): no bubble after the drag") }
        let r = again.width / 2
        let corner = NSPoint(x: again.midX + r * 0.45, y: again.midY - r * 0.45)
        try expect(view.qaResizeEdge(at: corner) != nil, "\(label): the probe point lies in the corner's resize band")
        try expect(view.agentBubbleContains(corner), "\(label): the probe point lies on the bubble")
        let banded = try drag(from: corner, by: CGSize(width: -40, height: 24), name: "corner")
        try expect(banded.after.width == banded.before.width && banded.after.height == banded.before.height,
                   "\(label): a press on the bubble inside the resize band resized the tile (\(banded.before) → \(banded.after))")
        try expect(abs(banded.after.x - banded.before.x + 40 / zoom) < 2 / zoom,
                   "\(label): ...and moved it with the pointer (\(banded.after.x - banded.before.x))")

        // 3. Just outside the bubble, the corner still resizes.
        canvas.layoutSubtreeIfNeeded()
        guard let last = view.agentBubbleFrame else { throw Failure(description: "\(label): no bubble") }
        let outside = NSPoint(x: view.bounds.width - 1 / zoom, y: 1 / zoom)
        try expect(!view.agentBubbleContains(outside) && view.qaResizeEdge(at: outside) == .topRight,
                   "\(label): the corner itself, outside the bubble \(last), is still a resize")
        return "tile agent bubble drag \(label): centre moved \(moved), corner band moved, PASS"
            + (filmed > 0 ? " (\(filmed) drag frames)" : "")
    }
}
