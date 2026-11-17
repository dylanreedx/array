import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ObjectiveC

// The agent's icon on its tile: Inline (a rounded square, the default),
// Squircle or Orb (a circle in glass), each on an opaque plate on the title's
// line, sized from the title.
//
// `--tile-agent-bubble-check`: four real agent tiles in a tinted zone, attached to
// a real supervisor with identity colours, two of them working. Asserts, at every
// chrome scale bucket:
// - The plate sits in the title bar, sized from the title (never taller than
//   the bar or the title's line), centred on the title's capitals with a tight
//   gap after it; its view is in the world plane, stacked above every tile and
//   unclipped; the icon never paints outside its tile.
// - Dylan's three rules (`TileAgentIconWitnesses`): title-sized at 125/50/30%,
//   opaque in both appearances, and on top of a neighbour stacked over its tile.
// - The art fills its plate, its body centred there, at a whole number of
//   device pixels per art pixel; its hit shape is its visible shape.
// - Every selection ring stops short of a plate it passes (a neighbour's
//   overlapping the ringed tile), live as it moves, asking the plane only the
//   cells the ring crosses (a few hundred far plates cost the ring nothing more).
// - The real Settings ChoiceButton switches every tile's style live, and 0.7.50's
//   stored `minimal` reads as Inline.
// Plus the working light, identity colour, the orb's hover, Reduce Motion, a
// camera pan costing nothing, and icons off restoring today's bar.
// `TILE_AGENT_BUBBLE_PNG_DIR=<dir>` writes stills (every style, dark and light:
// a selected agent with no colour among its neighbours at 125%, 50% and 30%,
// and the orb's two glass treatments); `TILE_AGENT_BUBBLE_FILM_DIR=<dir>`
// writes frames of the working light. The matrix sets neither.
//
// `--tile-agent-bubble-drag-check`: on the production mount, a drag that starts
// on the icon moves the tile through `NSApp.sendEvent` (local monitors, the
// window's hit-test, AppKit's drag routing) — from its centre and from the part
// in the top edge's resize band — at zoom 1 and 0.5, Inline and Orb, and the
// icon's view travels with the tile.
@MainActor
enum TileAgentBubbleChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    typealias Style = AgentCharacterConfig.BubbleStyle

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

    /// Whether every tile shows `style`, placed where that style lives.
    private static func showsStyle(_ style: Style, _ views: [ManagedAgentTileNSView], _ canvas: CanvasNSView) -> Bool {
        canvas.layoutSubtreeIfNeeded()
        return views.allSatisfy { view in
            view.layoutSubtreeIfNeeded()
            guard view.qaAgentBubble?.bubbleStyle == style, let frame = view.agentBubbleFrame else { return false }
            guard let host = view.agentBubbleView, let bar = view.qaTitleBarView else { return false }
            // AppKit attaches a newly added view's layer on the next turn of the run loop.
            let attached = host.layer?.superlayer != nil && host.layer?.superlayer === host.superview?.layer
                && host.bubble.superlayer === host.layer
            // Laid out for this style: a hanging plate straddles the tile's
            // corner, at least a third of it past each edge and the rest over
            // the tile (never wholly inside or wholly off it); any other plate
            // sits inside the bar.
            let placed = TileAgentBubbleLayer.Plate.hangs(style)
                ? frame.width > 0 && -frame.minX >= frame.width / 3 - 0.01 && -frame.minY >= frame.height / 3 - 0.01
                    && frame.maxX > 0 && frame.maxY > 0
                : frame.minX >= 0 && frame.maxY <= bar.frame.maxY + 0.5
            return attached && host.superview === view.superview && placed
        }
    }

    /// A plate's outline in canvas coordinates.
    private static func platePath(_ view: TileNSView, in canvas: CanvasNSView) -> CGPath? {
        guard let host = view.agentBubbleView, let plane = host.superview, !host.isHidden else { return nil }
        let zoom = CGFloat(canvas.viewport.zoom)
        return TileAgentBubbleLayer.Plate.path(host.bubble.bubbleStyle, in: canvas.convert(host.frame, from: plane),
                                               tileRadius: host.bubble.tileRadius * zoom)
    }

    private static func overlaps(_ a: CGPath, _ b: CGPath) -> Bool {
        let box = a.intersection(b).boundingBoxOfPath
        return !box.isNull && box.width * box.height > 0.01
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
        try expect(controller.bubbleStyle == .inline, "the icon is Inline by default (\(controller.bubbleStyle))")
        // 0.7.50 stored `minimal` for its circle: it reads as the default now.
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, "minimal")
        try expect(pump(until: { controller.bubbleStyle == .inline }), "a stored 0.7.50 Minimal reads as Inline")
        defaults.removeObject(forKey: AgentCharacterConfig.bubbleStyleKey)

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
        let focusBroker = FocusBroker()
        canvas.focusBroker = focusBroker
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
                   "every attached agent's tile shows its icon")
        guard let plane = views[0].superview as? CanvasWorldPlaneView else {
            throw Failure(description: "the tiles are not in the world plane")
        }

        // `--tile-agent-icon-styles-check`: the style, size, lens and icons-off witnesses
        // on this same fixture, instead of the rest of this check.
        if CommandLine.arguments.contains("--tile-agent-icon-styles-check") {
            return try TileAgentIconStyleChecks.run(canvas: canvas, window: window, defaults: defaults, views: views)
        }

        // 1. State: the working light follows the status; the colour follows the record.
        try expect(pump(until: {
            zip(views, specs).allSatisfy { view, spec in view.qaAgentBubble?.isWorking == spec.working }
        }), "the working light follows the agent's status: "
            + views.map { "\($0.agentStatus.map(\.rawValue) ?? "nil")=\($0.qaAgentBubble?.isWorking == true)" }.joined(separator: ", "))
        for (view, spec) in zip(views, specs) {
            let bubble = view.qaAgentBubble!
            try expect(bubble.isMoving == spec.working,
                       "\(spec.name): a working icon moves and an idle one holds still (moving \(bubble.isMoving))")
            try expect(spec.working == !bubble.qaAnimationKeys.isEmpty,
                       "\(spec.name): animations \(bubble.qaAnimationKeys)")
            let expected = spec.colour.map { ZoneChromeNSView.color(named: $0) }
            try expect(bubble.tint == expected, "\(spec.name): the icon wears the agent's colour (\(String(describing: bubble.tint)))")
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
        let slot = views[0].agentBubbleFrame!
        let edge = NSPoint(x: 0.1, y: slot.maxY - 0.1)
        try expect(stopped && resumed && unchangedFrames == views.map { $0.agentBubbleFrame }
                   && !views[0].agentBubbleContains(edge) && views[0].qaResizeEdge(at: edge) != nil,
                   "live Reduce Motion stopped=\(stopped) resumed=\(resumed); left of the icon, the left edge must resize")
        _ = supervisor.setIdentityColor(agentID: agents[3], "mint")
        try expect(pump(until: { views[3].qaAgentBubble?.tint == ZoneChromeNSView.color(named: "mint") }),
                   "a new identity colour reaches the icon")
        _ = supervisor.setIdentityColor(agentID: agents[3], nil)
        try expect(pump(until: { views[3].qaAgentBubble?.tint == nil }), "clearing the colour reaches the icon")
        try expect(views[0].qaManagedBadgeFrameInTile != nil, "fixture: the Managed badge shows, so its clearance is tested")

        // 2. Geometry at every chrome scale bucket, for each style.
        var buckets: Set<Double> = []
        for style in [Style.inline, .squircle, .orb] {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) reaches every tile")
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
            try checkCursor(view: views[0], window: window, style: style)
            let zooms: [Double] = style == .orb ? [1, 0.35] : [1.0, 0.75, 0.5, 0.35, 0.2, 1.6]
            for zoom in zooms {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                for view in views { view.layoutSubtreeIfNeeded() }
                for (index, view) in views.enumerated() {
                    let label = "\(style.title) zoom \(zoom) tile \(index)"
                    buckets.insert(Double(view.zoomChromeScale))
                    try checkGeometry(view: view, canvas: canvas, window: window, style: style, zoom: zoom, label: label)
                }
            }
            let parts = views[0].qaAgentBubble?.qaParts
            try expect(parts?.plateShown == true, "\(style.title) draws its plate")
            try expect(parts?.glassShown == (style == .orb), "only the Orb wears glass (\(style.title): \(String(describing: parts)))")
        }
        try expect(buckets.count >= 3, "the sweep crossed several chrome scale buckets: \(buckets.sorted())")

        // 2a. On a 1x display, zoomed out, the art never drops under a device
        // pixel per art pixel on screen (the floor counts the zoom).
        TileNSView.qaCharacterBackingOverride = 1
        for zoom in [0.5, 0.3, 0.2] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            for view in views { view.qaTitleBarView?.needsLayout = true }
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded() }
            for (index, view) in views.enumerated() {
                guard let art = view.qaArtScale else { throw Failure(description: "1x zoom \(zoom) tile \(index): no art") }
                let onScreen = art.perArt * CGFloat(zoom)
                try expect(onScreen >= 0.999,
                           "1x zoom \(zoom) tile \(index): the art draws \(onScreen) device px per art px on screen")
            }
        }
        TileNSView.qaCharacterBackingOverride = nil
        for view in views { view.qaTitleBarView?.needsLayout = true }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()

        // 2b. What is painted where. The world plane's layer tree is rendered
        // in-process (`render(in:)` honours every clip on the way, as the render
        // server does) with the icon shown and faded out. (Not the window
        // server's picture: for an offscreen check window it trails model
        // changes by a second or more.)
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        /// The plane's layer tree over `region` (plane coordinates), 2 px a
        /// point, row 0 at `region.minY`: a probe square at the region's top
        /// decides which way the render's rows run, so every lookup below reads
        /// plane coordinates whichever it is.
        func render(_ region: CGRect, under: CGColor? = nil) throws -> CGImage {
            canvas.layoutSubtreeIfNeeded()
            let width = Int((region.width * 2).rounded(.up)), height = Int((region.height * 2).rounded(.up))
            guard let planeLayer = plane.layer else { throw Failure(description: "no plane layer") }
            func draw(probe: Bool) throws -> CGImage {
                let marker = CALayer()
                if probe {
                    marker.frame = CGRect(x: region.minX, y: region.minY, width: region.width, height: 2)
                    marker.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor
                    marker.zPosition = 10_000
                    planeLayer.addSublayer(marker)
                }
                defer { marker.removeFromSuperlayer() }
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw Failure(description: "no render context")
                }
                if let under {
                    context.setFillColor(under)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                context.scaleBy(x: 2, y: 2)
                context.translateBy(x: -region.minX, y: -region.minY)
                planeLayer.render(in: context)
                guard let image = context.makeImage() else { throw Failure(description: "no render") }
                return image
            }
            let probed = try rgba(try draw(probe: true))
            let topIsFirst = probed[0] > 200 && probed[1] < 60 && probed[2] > 200
            let image = try draw(probe: false)
            guard !topIsFirst else { return image }
            // Rows run bottom-up: turn the picture over.
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "no flip context")
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let flipped = context.makeImage() else { throw Failure(description: "no flipped render") }
            return flipped
        }
        func withIconFaded<T>(_ view: TileNSView, _ body: () throws -> T) rethrows -> T {
            let bubble = view.qaAgentBubble!
            CATransaction.begin(); CATransaction.setDisableActions(true); bubble.opacity = 0; CATransaction.commit()
            defer { CATransaction.begin(); CATransaction.setDisableActions(true); bubble.opacity = 1; CATransaction.commit() }
            return try body()
        }
        // Inline never paints outside its tile; the Orb and the Squircle hang
        // off its corner, so they do: around the tile's top-left corner, 40 pt
        // each way, at 100% and 30%.
        for style in Style.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) for the paint")
            for zoom in [1.0, 0.3] {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                for view in views { view.layoutSubtreeIfNeeded() }
                let view = views[0]
                let tileInPlane = view.frame
                let reach = 40 / zoom
                let region = CGRect(x: tileInPlane.minX - reach, y: tileInPlane.minY - reach, width: 3 * reach, height: 2.5 * reach)
                let shown = try render(region)
                let faded = try withIconFaded(view) { try render(region) }
                let slotInPlane = plane.convert(view.agentBubbleFrame!, from: view)
                func inPlane(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: region.minX + x * region.width, y: region.minY + y * region.height) }
                let outside = try largestChannelChange(shown, faded) { x, y in !tileInPlane.contains(inPlane(x, y)) }
                let inside = try largestChannelChange(shown, faded) { x, y in slotInPlane.contains(inPlane(x, y)) }
                try expect(inside >= 48, "\(style.title) zoom \(zoom): the icon paints where it says (largest channel change \(inside))")
                if TileAgentBubbleLayer.Plate.hangs(style) {
                    try expect(outside >= 48, "\(style.title) zoom \(zoom): the icon does not hang past its tile (largest channel change \(outside))")
                } else {
                    try expect(outside == 0, "\(style.title) zoom \(zoom): the icon paints outside its tile (largest channel change \(outside))")
                }
            }
        }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        guard let paintedHost = views[0].agentBubbleView, let tileLayer = views[0].layer, let hostLayer = paintedHost.layer else {
            throw Failure(description: "no icon to render")
        }

        // 2c-0. The plate: opaque (nothing behind it shows through), clear of
        // its bar in both appearances, with or without a colour, and filled by
        // the art. At Dylan's 125%.
        for style in Style.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) for the plate")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1.25))
                canvas.layoutSubtreeIfNeeded()
                for view in views { view.layoutSubtreeIfNeeded() }
                pump(0.05)
                for (index, view) in views.enumerated() {
                    let label = "\(style.title) \(appearance == .aqua ? "light" : "dark") tile \(index)"
                    guard let frame = view.agentBubbleFrame, let bubble = view.qaAgentBubble, view.qaTitleBarView != nil else {
                        throw Failure(description: "\(label): no plate")
                    }
                    try expect(bubble.qaPlateColors.count >= 2 && bubble.qaPlateColors.allSatisfy { $0.alpha >= 0.999 },
                               "\(label): the plate's fill is opaque (\(bubble.qaPlateColors.map(\.alpha)))")
                    // Minimal holds the agent's character, like every other plate.
                    let fill = view.qaArtFill ?? 0
                    try expect(fill >= 0.85, "\(label): the art fills its plate (\(fill) of the side)")
                    // Opaque, witnessed: the plate's own layer tree, rendered
                    // over magenta and over green, shows neither inside its outline.
                    guard let host = view.agentBubbleView, let hostLayer = host.layer else {
                        throw Failure(description: "\(label): no host")
                    }
                    let plateBox = CGRect(origin: .zero, size: frame.size)
                    let outline = TileAgentBubbleLayer.Plate.path(style, in: plateBox, tileRadius: bubble.tileRadius)
                    let edge = outline.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10)
                    func renderPlate(over colour: CGColor) throws -> CGImage {
                        let width = Int((plateBox.width * 4).rounded(.up)), height = Int((plateBox.height * 4).rounded(.up))
                        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                            throw Failure(description: "no plate context")
                        }
                        context.setFillColor(colour)
                        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        context.scaleBy(x: 4, y: 4)
                        hostLayer.render(in: context)
                        guard let image = context.makeImage() else { throw Failure(description: "no plate render") }
                        return image
                    }
                    let overMagenta = try renderPlate(over: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor)
                    let overGreen = try renderPlate(over: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor)
                    // The outline is symmetric enough top to bottom that either row
                    // order reads it; test both and take the better.
                    func bleed(flipped: Bool) throws -> Int {
                        try largestChannelChange(overMagenta, overGreen) { x, y in
                            let p = CGPoint(x: x * plateBox.width, y: (flipped ? 1 - y : y) * plateBox.height)
                            return outline.contains(p) && !edge.contains(p)
                        }
                    }
                    let through = min(try bleed(flipped: false), try bleed(flipped: true))
                    let corner = try largestChannelChange(overMagenta, overGreen) { x, y in x < 0.04 && y < 0.04 }
                    try expect(corner >= 100 || bubble.tileRadius == 0,
                               "\(label): fixture: past the plate's rounded corner the backdrop shows (\(corner))")
                    try expect(through <= 2, "\(label): what lies behind the plate shows through it (largest channel change \(through))")
                    // Clear of the bar: the plate's fill against the bar's own
                    // colour (its fill with its identity wash over it).
                    func components(_ colour: CGColor?) -> [CGFloat] {
                        guard let c = colour.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else { return [0, 0, 0, 0] }
                        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
                    }
                    let plateColour = Array(components(bubble.qaPlateColors.first).prefix(3))
                    let base = components(view.qaTitleBarView?.layer?.backgroundColor)
                    let wash = components(view.qaTitleBarTint?.cgColor)
                    let barColour = (0..<3).map { base[$0] * (1 - wash[3]) + wash[$0] * wash[3] }
                    let ratio = contrast(plateColour, barColour)
                    let needed: CGFloat = bubble.tint == nil ? 1.3 : TileAgentBubbleLayer.plateContrast - 0.01
                    // Minimal is the flat token background: its even full border,
                    // not a contrasting fill, sets it off its bar.
                    if style == .minimalSquircle { try expect(bubble.qaParts.ringShown, "\(label): Minimal's border shows") }
                    else { try expect(ratio >= needed, "\(label): the plate \(plateColour) stands clear of its bar \(barColour) (contrast \(ratio), needs \(needed))") }
                }
            }
            window.appearance = nil
        }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        // Every colour an agent can wear, pale ones included, in both
        // appearances: a plate stands 1.45:1 clear of its bar's 30 % wash.
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            let theme: TokenTheme = appearanceName == .aqua ? .light : .dark
            let chrome = SurfaceToken.tileChrome.color.nsColor(for: theme)
            _ = appearance
            func rgb(_ c: NSColor) -> [CGFloat] { let s = c.usingColorSpace(.sRGB)!; return [s.redComponent, s.greenComponent, s.blueComponent] }
            for name in ZoneColorConfig.palette {
                let tint = ZoneChromeNSView.color(named: name)
                let plate = TileAgentBubbleLayer.plateFill(tint: tint, chrome: chrome, dark: theme != .light)
                let base = rgb(chrome), wash = rgb(tint), a = ManagedAgentTileNSView.identityBarAlpha
                let bar = (0..<3).map { base[$0] * (1 - a) + wash[$0] * a }
                let ratio = contrast(rgb(plate), bar)
                try expect(ratio >= TileAgentBubbleLayer.plateContrast - 0.01,
                           "\(name) \(theme): the plate stands \(ratio):1 from its bar, needs \(TileAgentBubbleLayer.plateContrast)")
            }
        }

        // 2c. The orb's hit shape is its visible shape: the corners of its box
        // are the bar's, not the icon's. A dark plate in a colour, at two
        // scales; points within the shadow's reach of the outline are left to
        // anti-aliasing.
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.orb.rawValue)
        try expect(pump(until: { showsStyle(.orb, views, canvas) }), "Orb for the hit shape")
        window.appearance = NSAppearance(named: .darkAqua)
        for zoom in [1.0, 0.35] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded() }
            let view = views[1]
            guard let host = view.agentBubbleView, let frame = view.agentBubbleFrame, let bubble = view.qaAgentBubble else {
                throw Failure(description: "zoom \(zoom): no plate")
            }
            let region = host.frame.insetBy(dx: -2, dy: -2)
            let shown = try render(region)
            let faded = try withIconFaded(view) { try render(region) }
            let (a, b) = (try rgba(shown), try rgba(faded))
            let path = TileAgentBubbleLayer.Plate.path(.orb, in: frame, tileRadius: bubble.tileRadius)
            let fuzz = path.copy(strokingWithWidth: 2 * (frame.width * 0.12 + 1 / zoom), lineCap: .round, lineJoin: .round, miterLimit: 10)
            var visibleHits = 0, emptyMisses = 0, mismatches: [String] = []
            let step = max(0.25, frame.width / 40)
            var y = frame.minY
            while y < frame.maxY {
                var x = frame.minX
                while x < frame.maxX {
                    let local = NSPoint(x: x, y: y)
                    defer { x += step }
                    guard !fuzz.contains(local) else { continue }
                    let p = plane.convert(local, from: view)
                    let px = Int(((p.x - region.minX) * 2).rounded(.down)), py = Int(((p.y - region.minY) * 2).rounded(.down))
                    guard px >= 0, py >= 0, px < shown.width, py < shown.height else { continue }
                    let i = (py * shown.width + px) * 4
                    let painted = (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max()! > 12
                    let hit = view.agentBubbleContains(local)
                    if painted && hit { visibleHits += 1 }
                    if !painted && !hit { emptyMisses += 1 }
                    if painted != hit && mismatches.count < 6 { mismatches.append("\(local) painted=\(painted) hit=\(hit)") }
                }
                y += step
            }
            try expect(mismatches.isEmpty, "zoom \(zoom): the orb's hit shape is its visible shape: \(mismatches)")
            try expect(visibleHits >= 4 && emptyMisses >= 1,
                       "zoom \(zoom): the comparison saw the plate (\(visibleHits)) and its empty corner (\(emptyMisses))")
        }
        window.appearance = nil

        // 2d. It lands with its tile: a snap landing gives the icon's view the
        // same flight as the tile's — same timing, same displacement.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        // Let the zoom back from 35% land first: a flight still in the air
        // would be read as the landing's.
        pump(0.4)
        for view in views { view.layer?.removeAllAnimations(); view.agentBubbleView?.layer?.removeAllAnimations() }
        canvas.autoLayoutReduceMotionProvider = { false }
        let rest = views[0].frame.origin
        let restOffset = CGPoint(x: paintedHost.frame.minX - rest.x, y: paintedHost.frame.minY - rest.y)
        canvas.animateSnapLanding(tileId: views[0].tile.id, from: NSPoint(x: rest.x + 90, y: rest.y + 60))
        func flight(_ layer: CALayer) -> (from: CGPoint, duration: CFTimeInterval)? {
            guard let animation = layer.animation(forKey: "position") as? CABasicAnimation,
                  let from = (animation.fromValue as? NSValue)?.pointValue else { return nil }
            return (from, animation.duration)
        }
        guard let tileFlight = flight(tileLayer), let hostFlight = flight(hostLayer) else {
            throw Failure(description: "a snap landing animates the tile and its icon: tile \(tileLayer.animationKeys() ?? []) icon \(hostLayer.animationKeys() ?? [])")
        }
        func start(_ from: CGPoint, _ layer: CALayer, restingAt origin: CGPoint) -> CGFloat {
            from.x - (origin.x + layer.anchorPoint.x * layer.bounds.width)
        }
        let tileStart = start(tileFlight.from, tileLayer, restingAt: rest)
        let hostStart = start(hostFlight.from, hostLayer, restingAt: CGPoint(x: rest.x + restOffset.x, y: rest.y + restOffset.y))
        try expect(abs(hostStart - tileStart) < 0.5 && hostFlight.duration == tileFlight.duration,
                   "the icon flies with its tile: tile starts \(tileStart) pt out over \(tileFlight.duration)s, icon \(hostStart) pt over \(hostFlight.duration)s")
        pump(0.3)
        try expect(paintedHost.frame.origin == CGPoint(x: rest.x + restOffset.x, y: rest.y + restOffset.y),
                   "after the landing the icon is back on its tile's title")

        // 3. A camera pan costs the icon nothing: no new motion, no bar redraw,
        // no plate filed again — in both places.
        for style in [Style.squircle, .inline] {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) for the pan")
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let installs = TileAgentBubbleLayer.motionInstallCount
            let redraws = views.map(\.qaTitleBarRedrawCount)
            let bubbleFrames = views.map { $0.qaAgentBubble?.frame }
            let refiles = plane.qaAgentBubbleRefiles
            for step in 1...24 {
                canvas.setViewport(CanvasViewport(x: Double(step) * 9, y: Double(step) * 4, zoom: 1))
                canvas.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            try expect(TileAgentBubbleLayer.motionInstallCount == installs, "\(style.title): a pan re-installed an icon's motion")
            try expect(views.map(\.qaTitleBarRedrawCount) == redraws, "\(style.title): a pan redrew a title bar")
            try expect(views.map { $0.qaAgentBubble?.frame } == bubbleFrames, "\(style.title): a pan moved an icon inside its host")
            try expect(plane.qaAgentBubbleRefiles == refiles, "\(style.title): a pan filed a plate again (\(plane.qaAgentBubbleRefiles - refiles))")
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
        }

        // 4. Out of sight it holds still; back in sight it moves again.
        controller.windowIsVisible = { _ in false }
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(pump(until: { !views[0].qaAgentBubble!.isMoving }), "a hidden window's icon holds still")
        controller.windowIsVisible = { _ in true }
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(pump(until: { views[0].qaAgentBubble!.isMoving }), "back in sight it moves again")

        // 5. Every sidebar style lends its light, inline and on a plate.
        for bubbleStyle in [Style.inline, .squircle] {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, bubbleStyle.rawValue)
            try expect(pump(until: { showsStyle(bubbleStyle, views, canvas) }), "\(bubbleStyle.title) for the lights")
            for style in SidebarActiveIndicatorStyle.allCases {
                setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, style.rawValue)
                try expect(pump(until: { views[0].qaAgentBubble?.workingStyle == style.rawValue }),
                           "\(bubbleStyle.title): the sidebar's \(style.title) style reaches the icon")
                try expect(views[0].qaAgentBubble?.isMoving == true && views[1].qaAgentBubble?.isMoving == false,
                           "\(bubbleStyle.title) \(style.title): only working agents move")
                if bubbleStyle == .squircle && style == .classic {
                    try expect(views[0].qaAgentBubble?.qaParts.orbitShown == true, "Classic's light travels round the plate")
                }
            }
            setSetting(defaults, SidebarActiveIndicatorStyle.defaultsKey, SidebarActiveIndicatorStyle.fallback.rawValue)
        }

        // 6. Every selection ring stops short of every plate it passes.
        try checkRingCut(views: views, canvas: canvas, plane: plane, window: window, focusBroker: focusBroker, defaults: defaults)

        // 6b. Dylan's three rules: sized from the title, opaque, on top.
        let rules = try TileAgentIconWitnesses.check(views: views, canvas: canvas, plane: plane, window: window, defaults: defaults)


        // 7. The real Settings choice switches every tile's style live.
        try checkSettingsChoice(defaults: defaults, views: views, canvas: canvas)

        // 8. Review renders and film, when asked for.
        var notes: [String] = []
        if let path = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_PNG_DIR"], !path.isEmpty {
            notes += try writeRenders(canvas: canvas, window: window, defaults: defaults, views: views, focusBroker: focusBroker,
                                      to: URL(fileURLWithPath: path, isDirectory: true))
        }
        if let path = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_FILM_DIR"], !path.isEmpty {
            notes += try writeFilm(canvas: canvas, window: window, defaults: defaults, views: views,
                                   to: URL(fileURLWithPath: path, isDirectory: true))
        }

        if let path = ProcessInfo.processInfo.environment["TILE_AGENT_BUBBLE_HOVER_FILM_DIR"], !path.isEmpty {
            notes += try writeHoverFilm(canvas: canvas, window: window, defaults: defaults, views: views,
                                        to: URL(fileURLWithPath: path, isDirectory: true))
        }

        // 8b. The orb's glass under the pointer: at rest it wears its glass
        // (or a flat plate, the other treatment), and hovered it swells a
        // little; the glass never lets the backdrop through.
        try checkOrbHover(views: views, canvas: canvas, defaults: defaults)

        // 9. Icons off: no icon, and the band's controls go back to today's place.
        setSetting(defaults, AgentCharacterConfig.enabledKey, false)
        try expect(pump(until: { views.allSatisfy { $0.agentBubbleFrame == nil } }), "icons off removes every icon")
        canvas.layoutSubtreeIfNeeded()
        for view in views {
            try expect(view.qaAgentBubble?.isMoving == false, "a removed icon holds still")
            try expect(view.agentBubbleView?.superview == nil, "a removed icon leaves no view in the plane")
            try expect(abs(view.bounds.width - view.qaCloseButtonFrame.maxX - 10) < 0.01,
                       "icons off puts × back 10 pt from the edge (\(view.bounds.width - view.qaCloseButtonFrame.maxX))")
        }
        defaults.removeObject(forKey: AgentCharacterConfig.bubbleStyleKey)
        return (["tile agent bubble: \(views.count) tiles, Inline/Squircle/Orb, buckets \(buckets.sorted()), PASS", rules] + notes)
            .joined(separator: "\n")
    }

    // MARK: Geometry

    private static func checkGeometry(view: ManagedAgentTileNSView, canvas: CanvasNSView, window: NSWindow,
                                      style: Style, zoom: Double, label: String) throws {
        guard let frame = view.agentBubbleFrame, let bubble = view.qaAgentBubble,
              let bar = view.qaTitleBarView else { throw Failure(description: "\(label): no icon") }
        let pixel = 1 / ((window.backingScaleFactor) * zoom) + 0.01
        // On the title's line: in the bar, a square sized from the title, its
        // middle on the title's capitals.
        let line = view.qaTitleFontWorldSize * TileAgentBubbleLayer.Plate.titleRatio
        let hangs = TileAgentBubbleLayer.Plate.hangs(style)
        if hangs {
            // Off the tile's top-left corner instead (`TileAgentIconWitnesses`).
            try TileAgentIconWitnesses.expectHanging(view, frame: frame, bar: view.chromeBarHeight, pixel: pixel, label: label)
        } else {
            try expect(frame.minX >= 0 && frame.minY >= -pixel && frame.maxY <= view.chromeBarHeight + pixel,
                       "\(label): the icon sits inside the bar \(frame) (bar \(view.chromeBarHeight))")
            try expect(abs(frame.width - frame.height) <= pixel && frame.height <= line + pixel
                       && frame.height >= min(line, view.chromeBarHeight - 4 * view.zoomChromeScale) - pixel,
                       "\(label): a square plate the title's line tall (\(frame.size), line \(line))")
            if let capMiddle = view.qaTitleCapMiddle {
                try expect(abs(frame.midY - capMiddle) <= 2 * pixel,
                           "\(label): the icon's middle \(frame.midY) sits on the title's capitals \(capMiddle)")
            }
        }
        // In the world plane, above every tile, unclipped, drawn where it says.
        guard let host = view.agentBubbleView, let plane = view.superview, host.superview === plane else {
            throw Failure(description: "\(label): the icon has no view in the tile's superview")
        }
        let drawn = view.convert(plane.convert(host.convertFromLayer(bubble.frame), from: host), from: plane)
        try expect(abs(drawn.minX - frame.minX) < 0.01 && abs(drawn.minY - frame.minY) < 0.01
                   && abs(drawn.width - frame.width) < 0.01,
                   "\(label): the icon's layer is drawn at \(drawn), the view expects \(frame)")
        var clips: [String] = []
        var ancestor = bubble.superlayer
        while let current = ancestor, current !== plane.layer {
            if current.masksToBounds || current.mask != nil { clips.append(String(describing: current.delegate.map { type(of: $0) })) }
            ancestor = current.superlayer
        }
        try expect(ancestor === plane.layer && clips.isEmpty,
                   "\(label): the icon reaches the world plane unclipped (clipped by \(clips))")
        let hostIndex = plane.subviews.firstIndex(of: host) ?? -1
        let topTile = plane.subviews.lastIndex { $0 is TileNSView } ?? Int.max
        try expect(hostIndex > topTile, "\(label): the icon is stacked above every tile (\(hostIndex) vs \(topTile))")
        try expect(bubble.qaArtClippedToPlate, "\(label): the art is cropped to its plate")
        if let frameView = canvas.superview {
            let hit = canvas.hitTest(frameView.convert(view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), from: nil))
            try expect(hit === view, "\(label): a press on the icon is the tile's (\(String(describing: hit.map { type(of: $0) })))")
        }
        try expect(view.qaDragKindIsMove(at: NSPoint(x: frame.midX, y: frame.midY)), "\(label): the icon is a grab")
        // The art: its typical pose fitted to the plate, never under a device
        // pixel per art pixel, its body on the plate's centre.
        if let art = view.qaArtScale, let fill = view.qaArtFill {
            let onScreen = art.perArt * art.backing * CGFloat(zoom)
            try expect(onScreen >= 0.999 && (abs(fill - TileAgentBubbleLayer.Plate.artFit) < 0.01 || fill > TileAgentBubbleLayer.Plate.artFit),
                       "\(label): the art's typical pose fills \(fill) of the plate, \(onScreen) device px per art px on screen")
        }
        do {
        guard let body = view.qaCharacterBody else { throw Failure(description: "\(label): no art") }
        try expect(abs(body.body.x - body.target.x) <= pixel && abs(body.body.y - body.target.y) <= pixel,
                   "\(label): the art's body \(body.body) is centred on its plate \(body.target)")
        }
        // The title follows tightly: one identifier. (A hanging plate reserves
        // no gap: the title keeps its normal start, checked above.)
        let gap = CGFloat(Space.s) * max(1 + (view.titleBarScale - 1) / 2, view.zoomChromeScale)
        if !hangs, let mark = view.qaProviderMarkRect {
            let start = bar.convert(mark, to: view).minX
            try expect(start >= frame.maxX && start - frame.maxX <= gap + pixel,
                       "\(label): the provider mark follows the icon tightly (gap \(start - frame.maxX), at most \(gap))")
        }
        let close = view.qaCloseButtonFrame
        try expect(close.minX >= frame.maxX, "\(label): × stays clear of the icon (\(close.minX) vs \(frame.maxX))")
        if !hangs, let mark = view.qaProviderMarkRect {
            try expect(bar.convert(mark, to: view).minX >= frame.maxX, "\(label): the provider mark starts after the icon")
        }
        if !hangs, let title = view.qaTitleRectInBar(), title.width > 0 {
            try expect(bar.convert(title, to: view).minX >= frame.maxX, "\(label): the title starts after the icon")
        }
        if let pill = view.qaStatusPillRectInBar() {
            try expect(!bar.convert(pill, to: view).intersects(frame), "\(label): the status pill never runs under the icon")
        }
        if let badge = view.qaManagedBadgeFrameInTile {
            try expect(!badge.intersects(frame), "\(label): the Managed badge \(badge) runs under the icon \(frame)")
        }
    }

    // MARK: Rings

    private static func checkRingCut(views: [ManagedAgentTileNSView], canvas: CanvasNSView, plane: CanvasWorldPlaneView,
                                     window: NSWindow, focusBroker: FocusBroker, defaults: UserDefaults) throws {
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.squircle.rawValue)
        try expect(pump(until: { showsStyle(.squircle, views, canvas) }), "Squircle for the rings")
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        // What the focus broker's scope hook calls when a tile becomes the scope.
        func focus(_ view: TileNSView) {
            canvas.markActive(tileId: view.tile.id)
            canvas.layoutSubtreeIfNeeded()
        }
        focus(views[0])
        try expect(canvas.borderedTileId == views[0].tile.id && canvas.qaFocusBorderOverlay != nil,
                   "fixture: the top-left tile wears the focus ants")
        func plates() -> [CGPath] { views.compactMap { platePath($0, in: canvas) } }
        func crossings(_ stroke: CGPath) -> [Int] {
            views.indices.filter { platePath(views[$0], in: canvas).map { overlaps(stroke, $0) } ?? false }
        }
        /// Teeth: which plates the ring's uncut line would have crossed.
        func uncutCrossings() -> [Int] {
            guard let overlay = canvas.qaFocusBorderOverlay, let local = overlay.qaShapePath else { return [] }
            var move = CGAffineTransform(translationX: overlay.frame.minX, y: overlay.frame.minY)
            guard let line = local.copy(using: &move) else { return [] }
            return crossings(line.copy(strokingWithWidth: FocusBorderOverlayView.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
        }
        // A neighbour overlaps the ringed tile's right edge, its plate in the
        // gutter below, straddling the ants and the ring of the tile under it:
        // the icon draws above every tile, and no ring may cross it.
        let side = views[1]
        let sideHome = side.frame.origin
        func straddle() throws {
            canvas.layoutSubtreeIfNeeded()
            guard let overlay = canvas.qaFocusBorderOverlay, let plate = side.agentBubbleFrame else {
                throw Failure(description: "fixture: no ants or no plate to straddle them")
            }
            let ringRight = plane.convert(overlay.frame, from: canvas).maxX
            let gutter = (views[0].frame.maxY + views[2].frame.minY) / 2
            side.setFrameOrigin(NSPoint(x: ringRight - plate.midX, y: gutter - plate.midY))
            canvas.layoutSubtreeIfNeeded()
        }
        defer { side.setFrameOrigin(sideHome); canvas.layoutSubtreeIfNeeded() }
        for zoom in [1.0, 0.5, 0.3] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded() }
            try straddle()
            try expect(plates().count == views.count, "zoom \(zoom): every tile shows its plate")
            guard let stroke = canvas.qaFocusBorderVisibleStrokePath, let overlay = canvas.qaFocusBorderOverlay else {
                throw Failure(description: "zoom \(zoom): no focus ants")
            }
            let would = uncutCrossings()
            try expect(would.contains(1),
                       "zoom \(zoom): fixture: the uncut ants would cross the overlapping neighbour's plate (\(would))")
            try expect(crossings(stroke).isEmpty, "zoom \(zoom): the focus ants cross the plates of tiles \(crossings(stroke))")
            let painted = stroke.boundingBoxOfPath
            try expect(painted.width > overlay.frame.width * 0.9 && painted.height > overlay.frame.height * 0.9,
                       "zoom \(zoom): the ants still run round the tile (\(painted) in \(overlay.frame))")
        }

        // The neighbour moves under still ants: the cut follows it, filed by the move.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        try straddle()
        let straddling = side.frame.origin
        for dy in [-3.0, -5.0, 2.0] {
            side.setFrameOrigin(NSPoint(x: straddling.x + 2, y: straddling.y + dy))
            canvas.layoutSubtreeIfNeeded()
            guard let stroke = canvas.qaFocusBorderVisibleStrokePath else { throw Failure(description: "no ants") }
            try expect(crossings(stroke).isEmpty, "a neighbour moved \(dy) pt: the ants cross plates \(crossings(stroke))")
        }
        side.setFrameOrigin(straddling)
        canvas.layoutSubtreeIfNeeded()

        // O(1): a few hundred plates far away cost the ring nothing more.
        guard let overlay = canvas.qaFocusBorderOverlay else { throw Failure(description: "no ants") }
        var visits = plane.qaAgentBubbleCandidateVisits
        overlay.refreshBubbleCut()
        let near = plane.qaAgentBubbleCandidateVisits - visits
        var far: [TileAgentBubbleView] = []
        for index in 0..<400 {
            let host = TileAgentBubbleView(bubble: TileAgentBubbleLayer(sprite: CharacterSpriteLayer()), tile: views[0])
            host.frame = NSRect(x: 40_000 + Double(index % 20) * 600, y: 40_000 + Double(index / 20) * 400, width: 16, height: 16)
            plane.addSubview(host)
            far.append(host)
        }
        defer { far.forEach { $0.removeFromSuperview() } }
        try expect(plane.qaAgentBubbleCount >= views.count + far.count, "fixture: the far plates are filed (\(plane.qaAgentBubbleCount))")
        visits = plane.qaAgentBubbleCandidateVisits
        overlay.refreshBubbleCut()
        let withFar = plane.qaAgentBubbleCandidateVisits - visits
        try expect(near > 0 && withFar == near,
                   "the ring asks only the cells it crosses: \(near) plates examined, \(withFar) with 400 more far away")
        far.forEach { $0.removeFromSuperview() }
        far.removeAll()

        // A group's member rings, which draw in their own overlay, stop short too.
        canvas.tileSelection.selectByMarquee(Set([views[0].tile.id, views[2].tile.id, views[3].tile.id]))
        canvas.layoutSubtreeIfNeeded()
        guard let selection = canvas.tileSelection.qaOverlay, selection.qaDrawnRingCount >= 2 else {
            throw Failure(description: "fixture: a group's member rings draw")
        }
        for (index, stroke) in selection.qaVisibleStrokePaths.enumerated() {
            try expect(crossings(stroke).isEmpty, "member ring \(index) crosses the plates of tiles \(crossings(stroke))")
        }
        // A pan moves every ring with its plates: no mask is built again, the
        // ants' or a member ring's, and still nothing crosses.
        let maskBuilds = overlay.qaMaskBuilds, areaBuilds = selection.qaAreaBuilds
        for step in 1...12 {
            canvas.setViewport(CanvasViewport(x: Double(step) * 7, y: Double(step) * 3, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for stroke in selection.qaVisibleStrokePaths + [canvas.qaFocusBorderVisibleStrokePath].compactMap({ $0 }) {
                try expect(crossings(stroke).isEmpty, "pan step \(step): a ring crosses plates \(crossings(stroke))")
            }
        }
        try expect(overlay.qaMaskBuilds == maskBuilds && selection.qaAreaBuilds == areaBuilds,
                   "a pan rebuilt ring masks: ants \(overlay.qaMaskBuilds - maskBuilds), members \(selection.qaAreaBuilds - areaBuilds)")
        // A plate moving under still rings: the ants cut again in layout, and
        // the group's overlay redraws (a real display pass, not a QA read).
        side.setFrameOrigin(NSPoint(x: side.frame.minX - 3, y: side.frame.minY + 2))
        canvas.layoutSubtreeIfNeeded()
        selection.displayIfNeeded()
        CATransaction.flush()
        try expect(overlay.qaMaskBuilds > maskBuilds, "a neighbour's plate moved: the ants did not cut again")
        try expect(selection.qaAreaBuilds > areaBuilds, "a plate moved under a member ring: the group's rings did not redraw their cut")
        for stroke in selection.qaVisibleStrokePaths + [canvas.qaFocusBorderVisibleStrokePath].compactMap({ $0 }) {
            try expect(crossings(stroke).isEmpty, "after a plate moved, a ring crosses plates \(crossings(stroke))")
        }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        canvas.tileSelection.clear()
        canvas.layoutSubtreeIfNeeded()

        // Every corner style and every shape: the installed plate mask and the
        // hit shape agree (Inline is square at Sharp, rounded otherwise; the
        // squircle and the orb keep their shapes), and the ants cut around
        // whatever outline it is.
        defer { CornerStyleController.apply(.standard); canvas.layoutSubtreeIfNeeded() }
        for style in Style.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) for the corner styles")
            for cornerStyle in CornerStyle.allCases {
                CornerStyleController.apply(cornerStyle)
                canvas.layoutSubtreeIfNeeded()
                for view in views { view.layoutSubtreeIfNeeded() }
                try straddle()
                CATransaction.flush()
                let view = views[3]
                guard let frame = view.agentBubbleFrame, let radius = view.layer?.cornerRadius,
                      let mask = view.qaAgentBubble?.qaPlateMaskPath else {
                    throw Failure(description: "\(style.title) \(cornerStyle): no plate")
                }
                let corner = NSPoint(x: frame.minX + frame.width * 0.04, y: frame.minY + frame.height * 0.04)
                let squared = style == .inline && radius == 0
                try expect(view.agentBubbleContains(corner) == squared,
                           "\(style.title) \(cornerStyle): the plate's corner is \(squared ? "square" : "round") (tile radius \(radius))")
                try expect(mask.contains(CGPoint(x: corner.x - frame.minX, y: corner.y - frame.minY)) == squared,
                           "\(style.title) \(cornerStyle): the installed plate mask agrees with the hit shape")
                guard let stroke = canvas.qaFocusBorderVisibleStrokePath else { throw Failure(description: "no ants") }
                try expect(crossings(stroke).isEmpty, "\(style.title) \(cornerStyle): the ants cross the plates of tiles \(crossings(stroke))")
            }
        }
    }

    /// The orb under the pointer, through its view's own tracking handlers: at
    /// rest it wears its glass (or, in the other treatment, a flat plate); the
    /// pointer on it swells the orb a little and shows the glass; leaving
    /// settles it back. Opaque throughout.
    private static func checkOrbHover(views: [ManagedAgentTileNSView], canvas: CanvasNSView, defaults: UserDefaults) throws {
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.orb.rawValue)
        try expect(pump(until: { showsStyle(.orb, views, canvas) }), "Orb for the hover")
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1.25))
        canvas.layoutSubtreeIfNeeded()
        let view = views[3]
        guard let host = view.agentBubbleView, let bubble = view.qaAgentBubble, let icon = view.agentBubbleFrame,
              let window = view.window else { throw Failure(description: "no orb to hover") }
        func move(to local: NSPoint, _ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        let saved = TileAgentBubbleLayer.orbGlassAtRest
        defer { TileAgentBubbleLayer.orbGlassAtRest = saved; host.mouseExited(with: move(to: .zero, .mouseMoved)) }
        for atRest in [true, false] {
            TileAgentBubbleLayer.orbGlassAtRest = atRest
            host.mouseExited(with: move(to: .zero, .mouseMoved))
            bubble.setTint(NSColor.white)
            bubble.setTint(nil)
            try expect(bubble.qaParts.glassShown == atRest,
                       "glass at rest \(atRest): resting, the orb \(atRest ? "wears" : "has no") glass")
            host.mouseMoved(with: move(to: NSPoint(x: icon.midX, y: icon.midY), .mouseMoved))
            try expect(bubble.isHovered && bubble.qaParts.glassShown && bubble.transform.m11 > 1.01,
                       "glass at rest \(atRest): the pointer on the orb shows its glass and swells it (scale \(bubble.transform.m11))")
            try TileAgentIconWitnesses.expectOpaque(view, label: "Orb hovered, glass at rest \(atRest)")
            host.mouseMoved(with: move(to: NSPoint(x: icon.minX + 0.2, y: icon.minY + 0.2), .mouseMoved))
            try expect(!bubble.isHovered, "glass at rest \(atRest): the box's empty corner is not the orb")
            host.mouseExited(with: move(to: .zero, .mouseMoved))
            try expect(!bubble.isHovered && abs(bubble.transform.m11 - 1) < 0.001, "leaving the orb settles it")
        }
        // A hovered Orb takes a press on the rim it swelled to, and only then.
        let r = icon.width / 2, swollen = r * (1 + (TileAgentBubbleLayer.orbHoverSwell - 1) / 2)
        let rim = NSPoint(x: icon.midX + swollen / 2.0.squareRoot(), y: icon.midY + swollen / 2.0.squareRoot())
        try expect(!view.agentBubbleContains(rim), "fixture: at rest the swollen rim is off the orb")
        host.mouseMoved(with: move(to: NSPoint(x: icon.midX, y: icon.midY), .mouseMoved))
        try expect(view.agentBubbleContains(rim), "a hovered orb takes a press on the rim it swelled to")
        // The swell belongs to the Orb: changing style while hovered drops it,
        // and leaving afterwards leaves the plate at its size.
        for other in [Style.inline, .squircle] {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.orb.rawValue)
            try expect(pump(until: { showsStyle(.orb, views, canvas) }), "Orb again")
            host.mouseMoved(with: move(to: NSPoint(x: icon.midX, y: icon.midY), .mouseMoved))
            try expect(bubble.transform.m11 > 1.01, "fixture: the hovered orb swells")
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, other.rawValue)
            try expect(pump(until: { showsStyle(other, views, canvas) }), "\(other.title) while hovered")
            try expect(abs(bubble.transform.m11 - 1) < 0.001,
                       "changing a hovered Orb to \(other.title) keeps its swell (scale \(bubble.transform.m11))")
            host.mouseExited(with: move(to: .zero, .mouseMoved))
            try expect(abs(bubble.transform.m11 - 1) < 0.001, "\(other.title) after leaving is at its size")
            // And the reverse: a hovered plate becoming an Orb swells. The plate
            // is hovered where it is now (Inline sits in the bar, the Orb hangs
            // off the corner), and the pointer then finds the Orb: a plate that
            // stayed hovered through the change must still swell.
            guard let plate = view.agentBubbleFrame else { throw Failure(description: "no \(other.title) plate") }
            host.mouseMoved(with: move(to: NSPoint(x: plate.midX, y: plate.midY), .mouseMoved))
            try expect(bubble.isHovered, "fixture: the pointer on the \(other.title) plate hovers it")
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.orb.rawValue)
            try expect(pump(until: { showsStyle(.orb, views, canvas) }), "Orb while hovered")
            guard let orb = view.agentBubbleFrame else { throw Failure(description: "no Orb plate") }
            host.mouseMoved(with: move(to: NSPoint(x: orb.midX, y: orb.midY), .mouseMoved))
            try expect(bubble.isHovered && bubble.transform.m11 > 1.01,
                       "a hovered \(other.title) becoming an Orb swells (scale \(bubble.transform.m11))")
            host.mouseExited(with: move(to: .zero, .mouseMoved))
        }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
    }

    // MARK: Settings

    private static func click(_ view: NSView) throws {
        guard let window = view.window else { throw Failure(description: "click target has no window") }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure(description: "could not make mouse event")
            }
            return event
        }
        // Queue release before the down enters any AppKit tracking loop.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        NSApp.sendEvent(try event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
    }

    /// Settings › Agent Icons › Tile icon is Array's ChoiceButton, and choosing
    /// there moves every tile's icon, live.
    private static func checkSettingsChoice(defaults: UserDefaults, views: [ManagedAgentTileNSView], canvas: CanvasNSView) throws {
        let model = SettingsModel(defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }),
                                  initialPaneID: "agentCharacters")
        let fixture = SettingsFixtureWindow(model: model, size: NSSize(width: 1_100, height: 1_100))
        defer { fixture.tearDown() }
        fixture.show(paneID: "agentCharacters")
        if let entry = model.entries().first(where: { $0.field?.key == AgentCharacterConfig.bubbleStyleKey }) {
            model.reveal(entry)
            fixture.settle()
        }
        guard let button = fixture.descendants(ChoiceButton.self).first(where: { $0.accessibilityLabel() == "Tile icon" }) else {
            throw Failure(description: "Agent Icons has no Tile icon ChoiceButton")
        }
        button.presentsOffscreenForQA = true
        try expect(button.items.map(\.id) == Style.allCases.map(\.rawValue),
                   "Tile icon offers \(Style.allCases.map(\.title)), got \(button.items.map(\.title))")
        try expect(button.selectedID == AgentCharacterConfig.bubbleStyle(defaults).rawValue,
                   "Tile icon shows the stored style (\(String(describing: button.selectedID)))")
        for style in [Style.inline, .orb, .squircle, .inline] where style != AgentCharacterConfig.bubbleStyle(defaults) || style == .inline {
            button.scrollToVisible(button.bounds.insetBy(dx: 0, dy: -80))
            fixture.settle(0.2)
            try click(button)
            fixture.settle()
            guard let list = button.qaPresentedList, let row = list.rowView(id: style.rawValue) else {
                throw Failure(description: "the Tile icon choice did not offer \(style.title); presented=\(button.qaIsPopoverPresented)")
            }
            button.qaPresentedPanel?.makeKey()
            try click(row)
            fixture.settle()
            try expect(defaults.string(forKey: AgentCharacterConfig.bubbleStyleKey) == style.rawValue,
                       "choosing \(style.title) stores it (\(String(describing: defaults.string(forKey: AgentCharacterConfig.bubbleStyleKey))))")
            try expect(pump(until: { showsStyle(style, views, canvas) }),
                       "choosing \(style.title) in Settings moves every tile's icon live")
        }
        // The icon size row: a real ChoiceButton, Small / Default / Large, live.
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.orb.rawValue)
        try expect(pump(until: { showsStyle(.orb, views, canvas) }), "Orb for the size row")
        guard let sizeButton = fixture.descendants(ChoiceButton.self).first(where: { $0.accessibilityLabel() == "Tile icon size" }) else {
            throw Failure(description: "Agent Icons has no Tile icon size ChoiceButton")
        }
        sizeButton.presentsOffscreenForQA = true
        try expect(sizeButton.items.map(\.title) == ["Small", "Default", "Large"], "Tile icon size offers \(sizeButton.items.map(\.title))")
        try expect(sizeButton.selectedID == "standard", "Tile icon size starts at Default")
        let before = views[0].agentBubbleFrame?.width ?? 0
        sizeButton.scrollToVisible(sizeButton.bounds.insetBy(dx: 0, dy: -80))
        fixture.settle(0.2)
        try click(sizeButton)
        fixture.settle()
        guard let sizeList = sizeButton.qaPresentedList, let large = sizeList.rowView(id: "large") else {
            throw Failure(description: "the Tile icon size choice did not offer Large")
        }
        sizeButton.qaPresentedPanel?.makeKey()
        try click(large)
        fixture.settle()
        try expect(defaults.string(forKey: AgentCharacterConfig.iconScaleKey) == "large", "choosing Large stores it")
        try expect(pump(until: { canvas.layoutSubtreeIfNeeded(); return (views[0].agentBubbleFrame?.width ?? 0) > before * 1.1 }),
                   "choosing Large in Settings grows every tile's icon live (\(before) -> \(views[0].agentBubbleFrame?.width ?? 0))")
        setSetting(defaults, AgentCharacterConfig.iconScaleKey, "standard")
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.inline.rawValue)
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

    /// The first pixel's sRGB-ish channels, 0...1.
    static func pixel(_ image: CGImage) throws -> [CGFloat] {
        let data = try rgba(image)
        return (0..<3).map { CGFloat(data[$0]) / 255 }
    }

    /// WCAG contrast ratio of two colours.
    static func contrast(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        func luminance(_ c: [CGFloat]) -> CGFloat {
            let linear = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "could not read a capture")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// The largest change in any colour channel between two same-size pictures.
    /// `where` takes a pixel's centre as a fraction of the picture (top-left origin).
    static func largestChannelChange(_ a: CGImage, _ b: CGImage,
                                     where include: (CGFloat, CGFloat) -> Bool = { _, _ in true }) throws -> Int {
        guard a.width == b.width, a.height == b.height else { throw Failure(description: "captures differ in size") }
        let (left, right) = (try rgba(a), try rgba(b))
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

    /// Dylan's state: the agent with no colour, selected, among its
    /// neighbours, at 125%, 50% and 30%, in every style, dark and light; and
    /// the orb's two glass treatments (worn at rest, or only under the
    /// pointer), at rest and hovered.
    private static func writeRenders(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                     views: [ManagedAgentTileNSView], focusBroker: FocusBroker,
                                     to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        let subject = views[3]
        guard let world = canvas.allTilesInWorldFrames().first(where: { $0.id == subject.tile.id })?.frame else {
            throw Failure(description: "no world frame for the uncoloured agent")
        }
        func shoot(_ name: String, zoom: Double, rect: NSRect) throws {
            if zoom == 1.25 {
                canvas.setViewport(CanvasViewport(x: world.x - 140 / zoom, y: world.y - 110 / zoom, zoom: zoom))
            } else {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            }
            canvas.layoutSubtreeIfNeeded()
            canvas.markActive(tileId: subject.tile.id)
            canvas.qaFocusBorderOverlay?.qaFreeze()
            pump(0.3)
            let image = try capture(canvas, window, rect: rect)
            let url = directory.appendingPathComponent(name)
            try write(image, to: url)
            written.append(url.path)
        }
        let shots: [(String, Double, NSRect)] = [
            ("125", 1.25, NSRect(x: 0, y: 0, width: 720, height: 300)),
            ("50", 0.5, NSRect(x: 0, y: 0, width: 660, height: 420)),
            ("30", 0.3, NSRect(x: 0, y: 0, width: 400, height: 260)),
        ]
        for style in Style.allCases {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) for the stills")
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                window.appearance = NSAppearance(named: appearance)
                for (zoomName, zoom, rect) in shots {
                    try shoot("\(style.rawValue)-\(name)-selected-nocolour-\(zoomName).png", zoom: zoom, rect: rect)
                }
            }
        }
        // The orb's glass: worn at rest, or only under the pointer.
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.orb.rawValue)
        try expect(pump(until: { showsStyle(.orb, views, canvas) }), "Orb for the glass stills")
        let saved = TileAgentBubbleLayer.orbGlassAtRest
        defer { TileAgentBubbleLayer.orbGlassAtRest = saved }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            for (treatment, atRest) in [("glass-always", true), ("glass-hover", false)] {
                TileAgentBubbleLayer.orbGlassAtRest = atRest
                for hovered in [false, true] {
                    // Repaint for the treatment, then hover as the pointer would.
                    subject.qaAgentBubble?.setHovered(!hovered)
                    subject.qaAgentBubble?.setHovered(hovered)
                    for view in views where view !== subject { view.qaAgentBubble?.setTint(view.qaAgentBubble?.tint) }
                    try shoot("orb-\(treatment)-\(hovered ? "hover" : "rest")-\(name)-125.png", zoom: 1.25,
                              rect: NSRect(x: 0, y: 0, width: 720, height: 300))
                }
                subject.qaAgentBubble?.setHovered(false)
            }
        }
        window.appearance = nil
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump(0.2)
        return written.map { "wrote \($0)" }
    }

    /// Real-time frames of the Orb under a scripted pointer: hover in, hold,
    /// out, then a fast flick in and out. Each frame is named by its wall-clock
    /// millisecond and logs the layer's presentation scale.
    private static func writeHoverFilm(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                       views: [ManagedAgentTileNSView], to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // TILE_AGENT_BUBBLE_FILM_MODE=working films the working first agent (no
        // pointer) for 6 s at TILE_AGENT_BUBBLE_FILM_ZOOM; else the hover script.
        let env = ProcessInfo.processInfo.environment
        let mode = env["TILE_AGENT_BUBBLE_FILM_MODE"]
        let working = mode == "working" || mode == "idle"
        let filmStyle = Style(rawValue: env["TILE_AGENT_BUBBLE_FILM_STYLE"] ?? "") ?? .orb
        TileAgentBubbleLayer.orbTreatment = env["TILE_AGENT_BUBBLE_FILM_TREATMENT"] == "inset" ? .inset : .classic
        let seconds = Double(env["TILE_AGENT_BUBBLE_FILM_SECONDS"] ?? "") ?? (working ? 6.2 : 4.4)
        let zoom = Double(env["TILE_AGENT_BUBBLE_FILM_ZOOM"] ?? "") ?? 2
        let subject = mode == "idle" ? views[1] : (working ? views[0] : views[3])
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, filmStyle.rawValue)
        try expect(pump(until: { showsStyle(filmStyle, views, canvas) }), "\(filmStyle.title) for the hover film")
        for view in views { view.qaAgentBubble?.qaRepaint() }
        if env["TILE_AGENT_BUBBLE_FILM_APPEARANCE"] == "light" { window.appearance = NSAppearance(named: .aqua) }
        if env["TILE_AGENT_BUBBLE_FILM_APPEARANCE"] != "light" { window.appearance = NSAppearance(named: .darkAqua) }
        guard let world = canvas.allTilesInWorldFrames().first(where: { $0.id == subject.tile.id })?.frame else {
            throw Failure(description: "no world frame for the Orb film")
        }
        canvas.setViewport(CanvasViewport(x: world.x - 40 / zoom * 2, y: world.y - 40 / zoom * 2, zoom: zoom))
        canvas.layoutSubtreeIfNeeded()
        pump(0.4)
        guard let bubble = subject.qaAgentBubble, let frame = subject.agentBubbleFrame else {
            throw Failure(description: "no Orb to film")
        }
        guard let hostView = window.contentView else { throw Failure(description: "no content view") }
        let box = subject.convert(frame.insetBy(dx: -24, dy: -24), to: hostView)
        // (time, hovered): hover in, hold, out; then a flick in and out.
        let script: [(Double, Bool)] = working ? [] : [(0.4, true), (1.5, false), (2.6, true), (2.68, false), (2.76, true), (2.84, false), (3.6, true), (3.66, false)]
        var next = 0, log = "", count = 0
        pump(0.3)
        let start = Date()
        func scale() -> Double { (bubble.presentation()?.value(forKeyPath: "transform.scale.x") as? Double) ?? 1 }
        while Date().timeIntervalSince(start) < seconds {
            let t = Date().timeIntervalSince(start)
            while next < script.count, script[next].0 <= t { bubble.setHovered(script[next].1); next += 1 }
            CATransaction.flush()
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]), let host = window.contentView {
                let k = CGFloat(image.width) / host.bounds.width
                let r = box
                let y = host.isFlipped ? r.minY : host.bounds.height - r.maxY
                let want = CGRect(x: r.minX * k, y: y * k, width: r.width * k, height: r.height * k).integral
                if count == 0 { FileHandle.standardError.write(Data("hover film crop \(want) of \(image.width)x\(image.height)\n".utf8)) }
                if let crop = image.cropping(to: want) {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    try write(crop, to: directory.appendingPathComponent(String(format: "f%05d.png", ms)))
                    log += "\(ms) \(scale())\n"; count += 1
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            if count == 0, t > 0.5, t < 0.6 { FileHandle.standardError.write(Data("hover film box \(box) frame \(frame)\n".utf8)) }
            if count == 0, t > 1 { FileHandle.standardError.write(Data("hover film: no frame by 1s\n".utf8)); break }
        }
        try log.write(to: directory.appendingPathComponent("scale.log"), atomically: true, encoding: .utf8)
        bubble.setHovered(false)
        window.appearance = nil
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        return ["hover film: \(count) frames"]
    }

    /// Frames of the working light, every sidebar style, every icon style: a
    /// working tile's corner at 200%, 0.1 s apart.
    private static func writeFilm(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                  views: [ManagedAgentTileNSView], to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        window.appearance = NSAppearance(named: .darkAqua)
        canvas.setViewport(CanvasViewport(x: 20, y: 60, zoom: 2))
        for style in Style.allCases {
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
        window.appearance = nil
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump(0.2)
        return ["wrote \(written) working frames to \(directory.path)"]
    }

    private static func checkCursor(view: ManagedAgentTileNSView, window: NSWindow, style: Style) throws {
        view.resetCursorRects()
        guard let icon = view.agentBubbleFrame else { throw Failure(description: "no icon for the cursor") }
        var points: [(String, NSPoint, NSCursor)] = [("centre", NSPoint(x: icon.midX, y: icon.midY), .openHand)]
        let savedCursor = NSCursor.current
        defer { savedCursor.set() }
        guard let host = view.agentBubbleView, let hostSuper = host.superview else {
            throw Failure(description: "\(style.title): the icon has no view")
        }
        host.updateTrackingAreas()
        let boxInHost = host.convert(hostSuper.convert(icon, from: view), from: hostSuper)
        try expect(host.trackingAreas.contains { $0.rect.contains(boxInHost) && $0.options.contains(.mouseMoved)
            && $0.options.contains(.cursorUpdate) }, "\(style.title): pointer and cursor tracking over the whole plate")
        // The plate overlaps the tile's top resize band: there, as a press
        // moves the tile, the cursor is the open hand.
        let hangs = TileAgentBubbleLayer.Plate.hangs(style)
        // (A hanging plate's middle is outside the tile: probe just inside it.)
        let banded = hangs ? NSPoint(x: 2, y: 1) : NSPoint(x: icon.midX, y: icon.minY + 0.5)
        try expect(view.qaResizeEdge(at: banded) != nil, "fixture: \(style.title)'s top lies in the resize band")
        points.append(("on the plate, in the top resize band", banded, .openHand))
        // (Below a hanging plate, past the top-left corner's diagonal zone.)
        try expect(view.agentBubbleCursor(at: NSPoint(x: 0.1, y: hangs ? max(icon.maxY, 2 * TileNSView.cornerHoverSize) + 2 : icon.maxY - 0.1)) == .resizeLeftRight,
                   "\(style.title): the left edge beside the icon resizes")
        for (label, point, expected) in points {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            try expect(view.agentBubbleContains(point) == (expected == NSCursor.openHand),
                       "\(style.title) \(label): cursor and the plate's grab agree")
            NSCursor.arrow.set()
            if expected == .arrow { NSCursor.openHand.set() }
            host.mouseMoved(with: event)
            try expect(NSCursor.current == expected, "\(label): pointer movement selects \(expected)")
            NSCursor.openHand.set()
            if expected == .openHand { NSCursor.arrow.set() }
            host.cursorUpdate(with: event)
            try expect(NSCursor.current == expected, "\(label): cursor entry selects \(expected)")
        }
        // The pointer leaves: nothing stays hovered for the checks after this.
        host.mouseExited(with: NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!)
        try expect(view.qaAgentBubble?.isHovered == false, "\(style.title): the pointer leaving unhovers the icon")
    }

    // MARK: Drag from the icon, on the production mount

    static func runDrag() async throws -> String {
        acceptFirstMouseEverywhere()
        var lines: [String] = []
        for zoom in [1.0, 0.5] {
            lines.append(try await exerciseDrag(zoom: zoom, style: .inline).0)
            lines.append(try await exerciseDrag(zoom: zoom, style: .orb).0)
            let bubble = try await exerciseDrag(zoom: zoom, style: .orb, snapping: true)
            let title = try await exerciseDrag(zoom: zoom, style: .orb, snapping: true, titleBar: true)
            try expect(bubble.1 == title.1, "zoom=\(zoom): snapped icon and title-bar final frames differ: \(bubble.1) vs \(title.1)")
            lines.append("zoom=\(zoom): production snapping icon/title-bar parity PASS: \(bubble.1)")
        }
        return lines.joined(separator: "\n")
    }

    private static func exerciseDrag(zoom: Double, style: Style, snapping: Bool = false,
                                     titleBar: Bool = false) async throws -> (String, TileFrame) {
        let label = "\(style.title) zoom=\(zoom)"
        let suite = "ArrayTileAgentBubbleDrag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        defaults.set(style.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
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
        try expect(pump(until: {
            canvas.layoutSubtreeIfNeeded()
            return view.agentBubbleFrame != nil && view.qaAgentBubble?.bubbleStyle == style
        }), "\(label): the production tile shows its icon")

        func world() -> TileFrame? { canvas.allTilesInWorldFrames().first { $0.id == agentTile }?.frame }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }

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
                try expect(hit === view, "\(label) \(name): a press on the icon at \(start) hit \(chain.joined(separator: " < ")) (tile frame in window \(view.convert(view.bounds, to: nil)))")
            }
            try send(.leftMouseDown, start)
            for t in [0.33, 0.66, 1.0] {
                try send(.leftMouseDragged, NSPoint(x: start.x + delta.width * t, y: start.y - delta.height * t))
                canvas.layoutSubtreeIfNeeded()
            }
            try send(.leftMouseUp, NSPoint(x: start.x + delta.width, y: start.y - delta.height))
            canvas.layoutSubtreeIfNeeded()
            guard let after = world() else { throw Failure(description: "\(label): no world frame after the drag") }
            return (before, after)
        }

        // 1. From the icon's centre.
        guard let icon = view.agentBubbleFrame else { throw Failure(description: "\(label): no icon") }
        try expect(view.qaDragKindIsMove(at: NSPoint(x: icon.midX, y: icon.midY)), "\(label): the icon's centre is a grab")
        let centre = try drag(from: NSPoint(x: icon.midX, y: icon.midY), by: snapping ? CGSize(width: 245 * zoom, height: -98 * zoom) : CGSize(width: 48, height: 36), name: "centre")
        try expect(centre.after.width == centre.before.width && centre.after.height == centre.before.height,
                   "\(label): dragging the icon resized the tile (\(centre.before) → \(centre.after))")
        if snapping {
            try expect(centre.after.x != centre.before.x + 245 || centre.after.y != centre.before.y - 98,
                       "\(label): snapping arm must engage a magnet, not merely follow freely")
        }
        let moved = (x: centre.after.x - centre.before.x, y: centre.after.y - centre.before.y)
        try expect(snapping || (abs(moved.x - 48 / zoom) < 2 / zoom && abs(moved.y - 36 / zoom) < 2 / zoom),
                   "\(label): the tile follows the icon by the pointer's delta (moved \(moved), expected \((48 / zoom, 36 / zoom)))")
        canvas.layoutSubtreeIfNeeded()
        guard let again = view.agentBubbleFrame else { throw Failure(description: "\(label): no icon after the drag") }

        // The icon's view travels with the tile.
        guard let host = view.agentBubbleView, let plane = view.superview else {
            throw Failure(description: "\(label): no icon view after the drag")
        }
        let expectedHost = view.convert(again, to: plane)
        try expect(host.superview === plane && abs(host.frame.minX - expectedHost.minX) < 0.01
                   && abs(host.frame.minY - expectedHost.minY) < 0.01,
                   "\(label): the icon's view \(host.frame) followed its tile to \(expectedHost)")

        // 3. From the part of the icon that lies in the top edge's resize band.
        canvas.layoutSubtreeIfNeeded()
        guard let third = view.agentBubbleFrame else { throw Failure(description: "\(label): no icon") }
        // The plate's top sits just below the tile's edge, in the band.
        // (A hanging plate's middle is outside the tile: probe just inside it.)
        let corner = NSPoint(x: max(third.midX, 2 / zoom), y: max(1 / zoom, third.minY + 0.5 / zoom))
        try expect(view.qaResizeEdge(at: corner) != nil, "\(label): the probe point lies in the top edge's resize band")
        try expect(view.agentBubbleContains(corner), "\(label): the probe point lies on the icon")
        let banded = try drag(from: corner, by: CGSize(width: -40, height: 24), name: "corner")
        try expect(banded.after.width == banded.before.width && banded.after.height == banded.before.height,
                   "\(label): a press on the icon inside the resize band resized the tile (\(banded.before) → \(banded.after))")
        try expect(snapping || abs(banded.after.x - banded.before.x + 40 / zoom) < 2 / zoom,
                   "\(label): ...and moved it with the pointer (\(banded.after.x - banded.before.x))")

        // 4. The far corner, nowhere near the icon, still resizes.
        canvas.layoutSubtreeIfNeeded()
        guard let last = view.agentBubbleFrame else { throw Failure(description: "\(label): no icon") }
        let farCorner = NSPoint(x: view.bounds.width - 1 / zoom, y: 1 / zoom)
        try expect(!view.agentBubbleContains(farCorner) && view.qaResizeEdge(at: farCorner) == .topRight,
                   "\(label): the corner itself, outside the icon \(last), is still a resize")
        return ("tile agent bubble drag \(label)\(snapping ? " snapping" : ""): centre moved \(moved), edge band moved, PASS", banded.after)
    }
}
