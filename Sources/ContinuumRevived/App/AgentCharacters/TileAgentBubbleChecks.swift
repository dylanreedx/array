import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ObjectiveC

// The agent's icon in a bubble breaking its tile's top-left corner.
//
// `--tile-agent-bubble-check`: four real agent tiles in a tinted zone, attached to
// a real supervisor with identity colours, two of them working. Asserts the
// bubble's place and size at every chrome scale bucket — hanging past the tile's
// top and left edges, drawn where the view says it is, with no clipping layer
// between it and the world plane, its overflow actually painted, stacked above
// every tile, and a press on its outside part hitting the tile — that the
// mark and title start after it, that it lands with its tile's snap animation, the working light following the agent's status and the sidebar's
// style, the identity colour, the Minimal/Orb setting live, the bubble holding
// still out of sight, a camera pan costing it nothing, and icons off restoring
// today's bar. `TILE_AGENT_BUBBLE_PNG_DIR=<dir>` writes both styles in light and
// dark at two zooms; `TILE_AGENT_BUBBLE_FILM_DIR=<dir>` writes frames of the
// working light. The matrix sets neither.
//
// `--tile-agent-bubble-drag-check`: on the production mount, a drag that starts
// on the bubble moves the tile through `NSApp.sendEvent` (local monitors, the
// window's hit-test, AppKit's drag routing) — from its centre, from the part
// outside the tile, and from the part in the top edge's resize band — at zoom 1
// and 0.5, and the bubble's view travels with the tile.
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
        // Accessibility refresh must reconcile motion with unchanged status/geometry.
        var reduced = false
        controller.reduceMotion = { reduced }
        let unchangedFrames = views.map { $0.agentBubbleFrame }
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        pump()
        let stopped = views[0].qaAgentBubble!.qaAnimationKeys.isEmpty
        reduced = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        pump()
        let resumed = !views[0].qaAgentBubble!.qaAnimationKeys.isEmpty
        views[0].resetCursorRects()
        let disc = views[0].agentBubbleFrame!
        let corner = NSPoint(x: 0.1, y: disc.maxY - 0.1)
        try expect(stopped && resumed && unchangedFrames == views.map { $0.agentBubbleFrame }
                   && !views[0].agentBubbleContains(corner) && views[0].qaResizeEdge(at: corner) != nil,
                   "live Reduce Motion stopped=\(stopped) resumed=\(resumed); off the circle, the left edge must resize")
        // Real cursor output from both tracking handlers, at caps and corners.
        try checkCursor(view: views[0], window: window)
        _ = supervisor.setIdentityColor(agentID: agents[3], "mint")
        try expect(pump(until: { views[3].qaAgentBubble?.tint == ZoneChromeNSView.color(named: "mint") }),
                   "a new identity colour reaches the bubble")
        _ = supervisor.setIdentityColor(agentID: agents[3], nil)
        try expect(pump(until: { views[3].qaAgentBubble?.tint == nil }), "clearing the colour reaches the bubble")

        try expect(views[0].qaManagedBadgeFrameInTile != nil, "fixture: the Managed badge shows, so its clearance is tested")

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
                if index == 0 && (zoom == 1 || zoom == 0.5) {
                    try checkCursor(view: view, window: window)
                }
                let chrome = view.zoomChromeScale
                buckets.insert(Double(chrome))
                let side = TileNSView.agentBubbleSide * max(chrome, view.titleBarScale)
                try expect(abs(frame.width - side) < 0.01 && abs(frame.height - side) < 0.01,
                           "\(label): a \(side) pt bubble at chrome scale \(chrome), got \(frame.size)")
                try expect(frame.width * zoom >= TileNSView.agentBubbleSide - 0.01,
                           "\(label): never smaller than \(TileNSView.agentBubbleSide) pt on screen (\(frame.width * zoom))")
                let pixel = 1 / ((window.backingScaleFactor) * zoom) + 0.01
                let overflow = TileNSView.agentBubbleOverflow * max(chrome, view.titleBarScale)
                try expect(abs(frame.minX + overflow) <= pixel && abs(frame.minY + overflow) <= pixel,
                           "\(label): hangs \(overflow) pt past the top-left corner, got left \(frame.minX) top \(frame.minY)")
                try expect(frame.minX < 0 && frame.minY < 0 && frame.maxX > 0 && frame.maxY > 0,
                           "\(label): the bubble breaks the corner, partly outside the tile \(frame)")
                try expect(frame.maxY <= view.chromeBarHeight + pixel,
                           "\(label): inside the tile it stays within the bar (\(frame.maxY) vs \(view.chromeBarHeight))")
                // The layer is drawn where the view says the bubble is (a flipped
                // host would otherwise put it upside down), by a view in the
                // world plane, stacked above every tile.
                guard let host = view.agentBubbleView, let plane = view.superview, host.superview === plane else {
                    throw Failure(description: "\(label): the bubble has no view in the tile's superview")
                }
                let drawn = view.convert(plane.convert(host.convertFromLayer(bubble.frame), from: host), from: plane)
                try expect(abs(drawn.minX - frame.minX) < 0.01 && abs(drawn.minY - frame.minY) < 0.01
                           && abs(drawn.width - frame.width) < 0.01,
                           "\(label): the bubble's layer is drawn at \(drawn), the view expects \(frame)")
                // No clipping: no layer between the bubble and the world plane masks.
                var clips: [String] = []
                var ancestor = bubble.superlayer
                while let current = ancestor, current !== plane.layer {
                    if current.masksToBounds || current.mask != nil { clips.append(String(describing: current.delegate.map { type(of: $0) })) }
                    ancestor = current.superlayer
                }
                try expect(ancestor === plane.layer && clips.isEmpty,
                           "\(label): the bubble reaches the world plane unclipped (clipped by \(clips))")
                let hostIndex = plane.subviews.firstIndex(of: host) ?? -1
                let topTile = plane.subviews.lastIndex { $0 is TileNSView } ?? Int.max
                try expect(hostIndex > topTile, "\(label): the bubble is stacked above every tile (\(hostIndex) vs \(topTile))")
                // A press on the part outside the tile is the tile's.
                let r = frame.width / 2
                let outside = NSPoint(x: frame.midX - r * 0.6, y: frame.midY - r * 0.6)
                try expect(!view.bounds.contains(outside) && view.agentBubbleContains(outside),
                           "\(label): fixture point \(outside) is on the bubble, outside the tile")
                if let frameView = canvas.superview {
                    let hit = canvas.hitTest(frameView.convert(view.convert(outside, to: nil), from: nil))
                    try expect(hit === view, "\(label): a press outside the tile on its bubble hit \(String(describing: hit.map { type(of: $0) }))")
                }
                if let sprite = view.qaCharacterRect {
                    let inTile = bar.convert(sprite, to: view)
                    try expect(abs(inTile.midX - frame.midX) <= pixel && abs(inTile.midY - frame.midY) <= pixel,
                               "\(label): the icon is centred in its bubble (\(inTile) in \(frame))")
                    try expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(inTile.insetBy(dx: 0, dy: 0)) || inTile.width > frame.width,
                               "\(label): the icon sits inside its bubble")
                }
                let close = view.qaCloseButtonFrame
                try expect(close.minX >= frame.maxX, "\(label): × stays clear of the bubble (\(close.minX) vs \(frame.maxX))")
                if let mark = view.qaProviderMarkRect {
                    try expect(bar.convert(mark, to: view).minX >= frame.maxX, "\(label): the provider mark starts after the bubble")
                }
                if let title = view.qaTitleRectInBar(), title.width > 0 {
                    try expect(bar.convert(title, to: view).minX >= frame.maxX, "\(label): the title starts after the bubble")
                }
                if let pill = view.qaStatusPillRectInBar() {
                    try expect(!bar.convert(pill, to: view).intersects(frame), "\(label): the status pill never runs under the bubble")
                }
                if let badge = view.qaManagedBadgeFrameInTile {
                    try expect(!badge.intersects(frame), "\(label): the Managed badge \(badge) runs under the bubble \(frame)")
                }
            }
        }
        try expect(buckets.count >= 3, "the sweep crossed several chrome scale buckets: \(buckets.sorted())")

        // 2b. The overflow is painted. The world plane's layer tree is rendered
        // in-process (`render(in:)` honours every clip on the way, as the render
        // server does) with the bubble shown and faded out; the columns left of
        // the tile's edge lie outside the tile, so a change there is the overflow.
        // (Not the window server's picture: for an offscreen check window it
        // trails model changes by a second or more.)
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        guard views[0].agentBubbleFrame != nil, let paintedHost = views[0].agentBubbleView,
              let planeLayer = views[0].superview?.layer, let hostLayer = paintedHost.layer, let tileLayer = views[0].layer else {
            throw Failure(description: "no bubble to render")
        }
        let square = hostLayer.frame
        let outsideColumns = Int(((tileLayer.frame.minX - square.minX) * 2).rounded(.down))
        try expect(outsideColumns > 0, "the bubble's square starts left of its tile (\(square) vs \(tileLayer.frame))")
        func render() throws -> CGImage {
            let width = Int((square.width * 2).rounded(.up)), height = Int((square.height * 2).rounded(.up))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "no render context")
            }
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: -square.minX, y: -square.minY)
            planeLayer.render(in: context)
            guard let image = context.makeImage() else { throw Failure(description: "no render") }
            return image
        }
        let shown = try render()
        paintedHost.alphaValue = 0
        let faded = try render()
        paintedHost.alphaValue = 1
        let change = try largestChannelChange(shown, faded) { x, _ in x * CGFloat(shown.width) < CGFloat(outsideColumns) }
        try expect(change >= 48, "the bubble's part outside its tile is painted (largest channel change \(change))")

        // 2c. It lands with its tile: a snap landing gives the bubble's view the
        // same flight as the tile's — same timing, same displacement.
        canvas.autoLayoutReduceMotionProvider = { false }
        let rest = views[0].frame.origin
        let restOffset = CGPoint(x: paintedHost.frame.minX - rest.x, y: paintedHost.frame.minY - rest.y)
        canvas.animateSnapLanding(tileId: views[0].tile.id, from: NSPoint(x: rest.x + 90, y: rest.y + 60))
        // AppKit installs a position flight on each layer; whatever it starts
        // from, the bubble's must start the same distance from its resting
        // place as the tile's does, and last as long.
        func flight(_ layer: CALayer) -> (from: CGPoint, duration: CFTimeInterval)? {
            guard let animation = layer.animation(forKey: "position") as? CABasicAnimation,
                  let from = (animation.fromValue as? NSValue)?.pointValue else { return nil }
            return (from, animation.duration)
        }
        guard let tileFlight = flight(tileLayer), let hostFlight = flight(hostLayer) else {
            throw Failure(description: "a snap landing animates the tile and its bubble: tile \(tileLayer.animationKeys() ?? []) bubble \(hostLayer.animationKeys() ?? [])")
        }
        func start(_ from: CGPoint, _ layer: CALayer, restingAt origin: CGPoint) -> CGFloat {
            from.x - (origin.x + layer.anchorPoint.x * layer.bounds.width)
        }
        let tileStart = start(tileFlight.from, tileLayer, restingAt: rest)
        let hostStart = start(hostFlight.from, hostLayer, restingAt: CGPoint(x: rest.x + restOffset.x, y: rest.y + restOffset.y))
        try expect(abs(hostStart - tileStart) < 0.5 && hostFlight.duration == tileFlight.duration,
                   "the bubble flies with its tile: tile starts \(tileStart) pt out over \(tileFlight.duration)s, bubble \(hostStart) pt over \(hostFlight.duration)s")
        pump(0.3)
        try expect(paintedHost.frame.origin == CGPoint(x: rest.x + restOffset.x, y: rest.y + restOffset.y),
                   "after the landing the bubble is back on its tile's corner")

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

    /// The largest change in any colour channel between two same-size pictures.
    /// `where` takes a pixel's centre as a fraction of the picture (top-left origin).
    static func largestChannelChange(_ a: CGImage, _ b: CGImage,
                                     where include: (CGFloat, CGFloat) -> Bool = { _, _ in true }) throws -> Int {
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "could not read a capture")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        guard a.width == b.width, a.height == b.height else { throw Failure(description: "captures differ in size") }
        let (left, right) = (try pixels(a), try pixels(b))
        var largest = 0
        for y in 0..<a.height {
            for x in 0..<a.width where include((CGFloat(x) + 0.5) / CGFloat(a.width), (CGFloat(y) + 0.5) / CGFloat(a.height)) {
                let i = (y * a.width + x) * 4
                for c in 0..<3 { largest = max(largest, abs(Int(left[i + c]) - Int(right[i + c]))) }
            }
        }
        return largest
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
                // Whole zone at 1, 0.5 and 0.3 (the same window, zoomed out).
                for zoom in [1.0, 0.5, 0.3] {
                    canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                    pump(0.3)
                    let image = try capture(canvas, window, rect: canvas.bounds)
                    let url = directory.appendingPathComponent("bubble-\(style.rawValue)-\(name)-zoom\(Int((zoom * 100).rounded())).png")
                    try write(image, to: url)
                    written.append(url.path)
                }
                // A close-up at 200%: a bubble breaking its corner beside its neighbour.
                canvas.setViewport(CanvasViewport(x: 370, y: 40, zoom: 2))
                pump(0.3)
                let close = try capture(canvas, window, rect: NSRect(x: 260, y: 0, width: 760, height: 380))
                let url = directory.appendingPathComponent("bubble-\(style.rawValue)-\(name)-closeup200.png")
                try write(close, to: url)
                written.append(url.path)
                // Where four tiles meet: a bubble over its neighbours' corners.
                canvas.setViewport(CanvasViewport(x: 375, y: 300, zoom: 2))
                pump(0.3)
                let junction = try capture(canvas, window, rect: NSRect(x: 250, y: 60, width: 700, height: 500))
                let junctionURL = directory.appendingPathComponent("bubble-\(style.rawValue)-\(name)-junction200.png")
                try write(junction, to: junctionURL)
                written.append(junctionURL.path)
            }
        }
        window.appearance = nil
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, AgentCharacterConfig.BubbleStyle.minimal.rawValue)
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump(0.2)
        return written.map { "wrote \($0)" }
    }

    /// Frames of the working light, every sidebar style, both bubble styles: a
    /// working tile's corner at 200%, 0.1 s apart.
    private static func writeFilm(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                  views: [ManagedAgentTileNSView], to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        window.appearance = NSAppearance(named: .darkAqua)
        canvas.setViewport(CanvasViewport(x: 20, y: 60, zoom: 2))
        for style in AgentCharacterConfig.BubbleStyle.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            for working in SidebarActiveIndicatorStyle.allCases {
                setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, working.rawValue)
                pump(0.3)
                for frame in 0..<12 {
                    let image = try capture(canvas, window, rect: NSRect(x: 40, y: 40, width: 560, height: 200))
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

    private static func checkCursor(view: ManagedAgentTileNSView, window: NSWindow) throws {
        view.resetCursorRects()
        guard let host = view.agentBubbleView, let plane = host.superview else {
            throw Failure(description: "the bubble has no view")
        }
        host.updateTrackingAreas()
        let disc = view.agentBubbleFrame!
        let discInHost = host.convert(plane.convert(disc, from: view), from: plane)
        try expect(host.trackingAreas.contains { $0.rect.contains(discInHost) && $0.options.contains(.mouseMoved)
            && $0.options.contains(.cursorUpdate) }, "bubble has pointer and cursor tracking over its whole circle")
        let points: [(String, NSPoint, NSCursor)] = [
            ("right cap", NSPoint(x: disc.maxX - 0.1, y: disc.midY), .openHand),
            ("top cap, outside the tile", NSPoint(x: disc.midX, y: disc.minY + 0.1), .openHand),
            ("left cap, outside the tile", NSPoint(x: disc.minX + 0.1, y: disc.midY), .openHand),
            ("bottom cap", NSPoint(x: disc.midX, y: disc.maxY - 0.1), .openHand),
            ("centre", NSPoint(x: disc.midX, y: disc.midY), .openHand),
            ("square corner, outside the tile", NSPoint(x: disc.minX + 0.1, y: disc.minY + 0.1), .arrow),
            ("square corner on the left edge", NSPoint(x: 0.1, y: disc.maxY - 0.1), .resizeLeftRight),
        ]
        let savedCursor = NSCursor.current
        defer { savedCursor.set() }
        for (label, point, expected) in points {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            try expect(view.agentBubbleContains(point) == (expected == NSCursor.openHand),
                       "\(label): cursor and circular grab agree")
            NSCursor.arrow.set()
            if expected == .arrow { NSCursor.openHand.set() }
            host.mouseMoved(with: event)
            try expect(NSCursor.current == expected, "\(label): pointer movement selects \(expected)")
            NSCursor.openHand.set()
            if expected == .openHand { NSCursor.arrow.set() }
            host.cursorUpdate(with: event)
            try expect(NSCursor.current == expected, "\(label): cursor entry selects \(expected)")
        }
        for point in [NSPoint(x: disc.maxX, y: disc.midY), NSPoint(x: disc.midX, y: disc.maxY), NSPoint(x: disc.minX, y: disc.midY)] {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            NSCursor.arrow.set()
            host.mouseMoved(with: event)
            let receivedPoint = view.convert(event.locationInWindow, from: nil)
            try expect((NSCursor.current == NSCursor.openHand) == view.agentBubbleContains(receivedPoint),
                       "circumference: cursor and circular hit-test agree at the received window point \(receivedPoint)")
        }
    }

    // MARK: Drag from the bubble, on the production mount

    static func runDrag() async throws -> String {
        acceptFirstMouseEverywhere()
        var lines: [String] = []
        for zoom in [1.0, 0.5] {
            lines.append(try await exerciseDrag(zoom: zoom).0)
            let bubble = try await exerciseDrag(zoom: zoom, snapping: true)
            let title = try await exerciseDrag(zoom: zoom, snapping: true, titleBar: true)
            try expect(bubble.1 == title.1, "zoom=\(zoom): snapped bubble and title-bar final frames differ: \(bubble.1) vs \(title.1)")
            lines.append("zoom=\(zoom): production snapping bubble/title-bar parity PASS: \(bubble.1)")
        }
        return lines.joined(separator: "\n")
    }

    private static func exerciseDrag(zoom: Double, snapping: Bool = false, titleBar: Bool = false) async throws -> (String, TileFrame) {
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
        state.tiles[index].frame = TileFrame(x: 440, y: 720, width: 360, height: 260)
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
        // No magnet: the tile must follow the pointer exactly, so the witness can
        // tell a move from a snap.
        canvas.dragMagnetizeDefaults.set(snapping, forKey: DragMagnetizeConfig.enabledKey)
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
        var filmed = 0
        #if ARRAY_FILM
        let filmDirectory = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_FILM_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let filmDirectory { try FileManager.default.createDirectory(at: filmDirectory, withIntermediateDirectories: true) }
        func film(_ name: String) throws {
            guard let filmDirectory, zoom == 1, !snapping else { return }
            let around = view.frame.insetBy(dx: -80, dy: -80)
            let image = try capture(canvas, window, rect: canvas.convert(around, from: view.superview))
            try write(image, to: filmDirectory.appendingPathComponent("drag-\(name).png"))
            filmed += 1
        }

        #endif

        /// Drag from `local` (tile coordinates) by `delta` screen points in three steps.
        func drag(from local: NSPoint, by delta: CGSize, name: String) throws -> (before: TileFrame, after: TileFrame) {
            guard let before = world() else { throw Failure(description: "\(label): no world frame") }
            let bar = view.qaTitleBarView!
            let grab = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: view)
            let start = view.convert(titleBar ? grab : local, to: nil)
            // The real hit-test answers the tile itself, not the bar or the body.
            if !titleBar, let host = canvas.superview {
                let hit = canvas.hitTest(canvas.convert(canvas.convert(start, from: nil), to: host))
                var chain: [String] = []
                var cursor: NSView? = hit
                while let current = cursor, chain.count < 8 { chain.append(String(describing: type(of: current))); cursor = current.superview }
                try expect(hit === view, "\(label) \(name): a press on the bubble at \(start) hit \(chain.joined(separator: " < ")) (tile frame in window \(view.convert(view.bounds, to: nil)))")
            }
            try send(.leftMouseDown, start)
            #if ARRAY_FILM
            try film("\(name)-0")
            #endif
            for (step, t) in [0.33, 0.66, 1.0].enumerated() {
                try send(.leftMouseDragged, NSPoint(x: start.x + delta.width * t, y: start.y - delta.height * t))
                canvas.layoutSubtreeIfNeeded()
            #if ARRAY_FILM
                try film("\(name)-\(step + 1)")
            #endif
            }
            try send(.leftMouseUp, NSPoint(x: start.x + delta.width, y: start.y - delta.height))
            canvas.layoutSubtreeIfNeeded()
            #if ARRAY_FILM
            try film("\(name)-4")
            #endif
            guard let after = world() else { throw Failure(description: "\(label): no world frame after the drag") }
            return (before, after)
        }

        // 1. From the bubble's centre.
        guard let bubble = view.agentBubbleFrame else { throw Failure(description: "\(label): no bubble") }
        try expect(view.qaDragKindIsMove(at: NSPoint(x: bubble.midX, y: bubble.midY)), "\(label): the bubble's centre is a grab")
        let centre = try drag(from: NSPoint(x: bubble.midX, y: bubble.midY), by: snapping ? CGSize(width: 245 * zoom, height: -98 * zoom) : CGSize(width: 48, height: 36), name: "centre")
        try expect(centre.after.width == centre.before.width && centre.after.height == centre.before.height,
                   "\(label): dragging the bubble resized the tile (\(centre.before) → \(centre.after))")
        if snapping {
            try expect(centre.after.x != centre.before.x + 245 || centre.after.y != centre.before.y - 98,
                       "\(label): snapping arm must engage a magnet, not merely follow freely")
        }
        let moved = (x: centre.after.x - centre.before.x, y: centre.after.y - centre.before.y)
        try expect(snapping || (abs(moved.x - 48 / zoom) < 2 / zoom && abs(moved.y - 36 / zoom) < 2 / zoom),
                   "\(label): the tile follows the bubble by the pointer's delta (moved \(moved), expected \((48 / zoom, 36 / zoom)))")

        // The bubble's view travels with the tile.
        canvas.layoutSubtreeIfNeeded()
        guard let again = view.agentBubbleFrame, let host = view.agentBubbleView, let plane = view.superview else {
            throw Failure(description: "\(label): no bubble after the drag")
        }
        let expectedHost = view.convert(again, to: plane)
        try expect(host.superview === plane && abs(host.frame.minX - expectedHost.minX) < 0.01
                   && abs(host.frame.minY - expectedHost.minY) < 0.01,
                   "\(label): the bubble's view \(host.frame) followed its tile to \(expectedHost)")

        // 2. From the part of the bubble outside the tile: the press hits the tile.
        let r = again.width / 2
        let outside = NSPoint(x: again.midX - r * 0.6, y: again.midY - r * 0.6)
        try expect(!view.bounds.contains(outside) && view.agentBubbleContains(outside),
                   "\(label): the probe point lies on the bubble, outside the tile")
        let hung = try drag(from: outside, by: CGSize(width: 36, height: -30), name: "outside")
        try expect(hung.after.width == hung.before.width && hung.after.height == hung.before.height,
                   "\(label): dragging the bubble from outside the tile resized it (\(hung.before) → \(hung.after))")
        try expect(snapping || (abs(hung.after.x - hung.before.x - 36 / zoom) < 2 / zoom
                                && abs(hung.after.y - hung.before.y + 30 / zoom) < 2 / zoom),
                   "\(label): ...and moved it with the pointer (\(hung.after.x - hung.before.x), \(hung.after.y - hung.before.y))")

        // 3. From the part of the bubble that lies in the top edge's resize band.
        canvas.layoutSubtreeIfNeeded()
        guard let third = view.agentBubbleFrame else { throw Failure(description: "\(label): no bubble") }
        let corner = NSPoint(x: third.midX + third.width / 4, y: 1 / zoom)
        try expect(view.qaResizeEdge(at: corner) != nil, "\(label): the probe point lies in the top edge's resize band")
        try expect(view.agentBubbleContains(corner), "\(label): the probe point lies on the bubble")
        let banded = try drag(from: corner, by: CGSize(width: -40, height: 24), name: "corner")
        try expect(banded.after.width == banded.before.width && banded.after.height == banded.before.height,
                   "\(label): a press on the bubble inside the resize band resized the tile (\(banded.before) → \(banded.after))")
        try expect(snapping || abs(banded.after.x - banded.before.x + 40 / zoom) < 2 / zoom,
                   "\(label): ...and moved it with the pointer (\(banded.after.x - banded.before.x))")

        // 4. The far corner, nowhere near the bubble, still resizes.
        canvas.layoutSubtreeIfNeeded()
        guard let last = view.agentBubbleFrame else { throw Failure(description: "\(label): no bubble") }
        let farCorner = NSPoint(x: view.bounds.width - 1 / zoom, y: 1 / zoom)
        try expect(!view.agentBubbleContains(farCorner) && view.qaResizeEdge(at: farCorner) == .topRight,
                   "\(label): the corner itself, outside the bubble \(last), is still a resize")
        return ("tile agent bubble drag \(label): centre moved \(moved), outside part and edge band moved, PASS"
            + (filmed > 0 ? " (\(filmed) drag frames)" : ""), banded.after)
    }
}
