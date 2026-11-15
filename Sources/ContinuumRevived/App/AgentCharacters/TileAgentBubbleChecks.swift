import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ObjectiveC

// The agent's icon on its tile: Inline (the default, in the title bar) or a
// Squircle / Orb tucked into the tile's top-left corner.
//
// `--tile-agent-bubble-check`: four real agent tiles in a tinted zone, attached to
// a real supervisor with identity colours, two of them working. Asserts, at every
// chrome scale bucket:
// - Inline never leaves its tile: its slot lies inside the bar, the bar hosts it
//   behind a clip, there is no view in the world plane, and rendering the plane
//   with and without it changes no pixel outside the tile.
// - The squircle hangs exactly its overflow past the corner, is drawn where the
//   view says, unclipped and above every tile, and paints that overflow; its hit
//   shape is its visible shape (the empty corner of its box is canvas); and every
//   selection ring — the focus ants, and a group's member rings — stops short of
//   it and of a neighbour's plate in the gutter, at 100%, 50% and 30%, live as a
//   neighbour moves, asking the plane only the cells the ring crosses (a few
//   hundred far plates cost the ring nothing more).
// - The art is centred in its slot, and the mark and title start after it.
// - The real Settings ChoiceButton switches every tile's style live, and 0.7.50's
//   stored `minimal` reads as Inline.
// Plus the working light, identity colour, Reduce Motion, a camera pan costing
// nothing, and icons off restoring today's bar. `TILE_AGENT_BUBBLE_PNG_DIR=<dir>`
// writes stills (both finalists, light and dark: a selected agent with no
// colour at 125%, and the zone at 30%); `TILE_AGENT_BUBBLE_FILM_DIR=<dir>`
// writes frames of the working light. The matrix sets neither.
//
// `--tile-agent-bubble-drag-check`: on the production mount, a drag that starts
// on the icon moves the tile through `NSApp.sendEvent` (local monitors, the
// window's hit-test, AppKit's drag routing) — from its centre, from the squircle's
// part outside the tile, and from the part in the top edge's resize band — at
// zoom 1 and 0.5, Inline and Squircle, and the squircle's view travels with the tile.
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
            return attached && (style.breaksCorner ? host.superview === view.superview && frame.minX < 0
                                                   : host.superview === bar && frame.minX >= 0)
        }
    }

    /// A plate's outline in canvas coordinates.
    private static func platePath(_ view: TileNSView, in canvas: CanvasNSView) -> CGPath? {
        guard let host = view.agentBubbleView, let plane = host.superview, !host.isHidden else { return nil }
        let zoom = CGFloat(canvas.viewport.zoom)
        return TileAgentBubbleLayer.Squircle.path(in: canvas.convert(host.frame, from: plane),
                                                  tileRadius: host.bubble.tileRadius * zoom,
                                                  scale: host.bubble.chromeScale * zoom)
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
            if style == .orb {
                try expect(views[0].qaAgentBubble?.qaParts.sphereShown == true && views[0].qaAgentBubble?.qaParts.glossShown == true,
                           "an Orb draws its sphere and gloss")
            } else if style == .squircle {
                try expect(views[0].qaAgentBubble?.qaParts.sphereShown == false && views[0].qaAgentBubble?.qaParts.plateShown == true,
                           "a Squircle draws a plate and no sphere")
            } else {
                try expect(views[0].qaAgentBubble?.qaParts.plateShown == true && views[0].qaAgentBubble?.qaParts.sphereShown == false,
                           "Inline draws its own plate")
            }
        }
        try expect(buckets.count >= 3, "the sweep crossed several chrome scale buckets: \(buckets.sorted())")

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
        // Inline: around the tile's top-left corner, 40 pt each way.
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.inline.rawValue)
        try expect(pump(until: { showsStyle(.inline, views, canvas) }), "Inline comes back")
        do {
            let view = views[0]
            let tileInPlane = view.frame
            let region = CGRect(x: tileInPlane.minX - 40, y: tileInPlane.minY - 40, width: 120, height: 100)
            let shown = try render(region)
            let faded = try withIconFaded(view) { try render(region) }
            let slotInPlane = plane.convert(view.agentBubbleFrame!, from: view)
            func inPlane(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: region.minX + x * region.width, y: region.minY + y * region.height) }
            let outside = try largestChannelChange(shown, faded) { x, y in !tileInPlane.contains(inPlane(x, y)) }
            let inside = try largestChannelChange(shown, faded) { x, y in slotInPlane.contains(inPlane(x, y)) }
            try expect(inside >= 48, "Inline paints its art in the bar (largest channel change \(inside))")
            try expect(outside == 0, "Inline never paints outside its tile (largest channel change \(outside) outside it)")
        }
        // Squircle: the columns left of the tile's edge lie outside the tile, so
        // a change there is the overflow.
        setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.squircle.rawValue)
        try expect(pump(until: { showsStyle(.squircle, views, canvas) }), "Squircle comes back")
        guard let paintedHost = views[0].agentBubbleView, let tileLayer = views[0].layer, let hostLayer = paintedHost.layer else {
            throw Failure(description: "no squircle to render")
        }
        do {
            let square = paintedHost.frame
            let outsideColumns = (views[0].frame.minX - square.minX) / square.width
            try expect(outsideColumns > 0, "the squircle's box starts left of its tile (\(square) vs \(views[0].frame))")
            let shown = try render(square)
            let faded = try withIconFaded(views[0]) { try render(square) }
            let change = try largestChannelChange(shown, faded) { x, _ in x < outsideColumns }
            try expect(change >= 48, "the squircle's part outside its tile is painted (largest channel change \(change))")
        }

        // 2c-0. The plate: opaque (nothing behind it shows through), clear of
        // its bar in both appearances, with or without a colour, and filled by
        // the art. At Dylan's 125%.
        for style in [Style.inline, .squircle] {
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
                    let fill = view.qaArtFill ?? 0
                    try expect(fill >= 0.6, "\(label): the art fills its plate (\(fill) of the side)")
                    // Opaque, witnessed: the plate's own layer tree, rendered
                    // over magenta and over green, shows neither inside its outline.
                    guard let host = view.agentBubbleView, let hostLayer = host.layer else {
                        throw Failure(description: "\(label): no host")
                    }
                    let plateBox = CGRect(origin: .zero, size: frame.size)
                    let outline = style.breaksCorner
                        ? TileAgentBubbleLayer.Squircle.path(in: plateBox, tileRadius: bubble.tileRadius, scale: bubble.chromeScale)
                        : TileAgentBubbleLayer.Inline.path(in: plateBox, tileRadius: bubble.tileRadius, scale: bubble.chromeScale)
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
                    try expect(corner >= 100 || !style.breaksCorner || bubble.tileRadius == 0,
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
                    try expect(ratio >= 1.3, "\(label): the plate \(plateColour) stands clear of its bar \(barColour) (contrast \(ratio))")
                }
            }
            window.appearance = nil
        }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()

        // 2c. The squircle's hit shape is its visible shape, outside the tile
        // where it matters (a press there is the tile's, or the canvas's). A dark
        // plate in a colour, at two scales; points within the shadow's reach of
        // the outline are left to anti-aliasing.
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
            let path = TileAgentBubbleLayer.Squircle.path(in: frame, tileRadius: bubble.tileRadius, scale: bubble.chromeScale)
            let fuzz = path.copy(strokingWithWidth: 2 * (2 * bubble.chromeScale + 1), lineCap: .round, lineJoin: .round, miterLimit: 10)
            var visibleHits = 0, emptyMisses = 0, mismatches: [String] = []
            let step = max(0.5, bubble.chromeScale * 0.5)
            var y = frame.minY
            while y < frame.maxY {
                var x = frame.minX
                while x < frame.maxX {
                    let local = NSPoint(x: x, y: y)
                    defer { x += step }
                    guard !view.bounds.contains(local), !fuzz.contains(local) else { continue }
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
            try expect(mismatches.isEmpty, "zoom \(zoom): the squircle's hit shape is its visible shape outside the tile: \(mismatches)")
            try expect(visibleHits >= 4 && emptyMisses >= 1,
                       "zoom \(zoom): the comparison saw the plate (\(visibleHits)) and its empty corner (\(emptyMisses))")
        }
        window.appearance = nil

        // 2d. It lands with its tile: a snap landing gives the squircle's view the
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
            throw Failure(description: "a snap landing animates the tile and its squircle: tile \(tileLayer.animationKeys() ?? []) squircle \(hostLayer.animationKeys() ?? [])")
        }
        func start(_ from: CGPoint, _ layer: CALayer, restingAt origin: CGPoint) -> CGFloat {
            from.x - (origin.x + layer.anchorPoint.x * layer.bounds.width)
        }
        let tileStart = start(tileFlight.from, tileLayer, restingAt: rest)
        let hostStart = start(hostFlight.from, hostLayer, restingAt: CGPoint(x: rest.x + restOffset.x, y: rest.y + restOffset.y))
        try expect(abs(hostStart - tileStart) < 0.5 && hostFlight.duration == tileFlight.duration,
                   "the squircle flies with its tile: tile starts \(tileStart) pt out over \(tileFlight.duration)s, squircle \(hostStart) pt over \(hostFlight.duration)s")
        pump(0.3)
        try expect(paintedHost.frame.origin == CGPoint(x: rest.x + restOffset.x, y: rest.y + restOffset.y),
                   "after the landing the squircle is back on its tile's corner")

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
        return (["tile agent bubble: \(views.count) tiles, Inline/Squircle/Orb, buckets \(buckets.sorted()), PASS"] + notes)
            .joined(separator: "\n")
    }

    // MARK: Geometry

    private static func checkGeometry(view: ManagedAgentTileNSView, canvas: CanvasNSView, window: NSWindow,
                                      style: Style, zoom: Double, label: String) throws {
        guard let frame = view.agentBubbleFrame, let bubble = view.qaAgentBubble,
              let bar = view.qaTitleBarView else { throw Failure(description: "\(label): no icon") }
        let scale = max(view.zoomChromeScale, view.titleBarScale)
        let pixel = 1 / ((window.backingScaleFactor) * zoom) + 0.01
        if style.breaksCorner {
            let side = TileNSView.agentBubbleSide * scale
            let overflow = TileNSView.agentBubbleOverflow * scale
            try expect(abs(frame.width - side) <= pixel && abs(frame.height - side) <= pixel,
                       "\(label): a \(side) pt squircle at scale \(scale), got \(frame.size)")
            try expect(frame.width * zoom >= TileNSView.agentBubbleSide - 0.01,
                       "\(label): never smaller than \(TileNSView.agentBubbleSide) pt on screen (\(frame.width * zoom))")
            try expect(abs(frame.minX + overflow) <= pixel && abs(frame.minY + overflow) <= pixel,
                       "\(label): hangs \(overflow) pt past the top-left corner, got left \(frame.minX) top \(frame.minY)")
            try expect(frame.maxY <= view.chromeBarHeight + pixel,
                       "\(label): inside the tile it stays within the bar (\(frame.maxY) vs \(view.chromeBarHeight))")
            guard let host = view.agentBubbleView, let plane = view.superview, host.superview === plane else {
                throw Failure(description: "\(label): the squircle has no view in the tile's superview")
            }
            let drawn = view.convert(plane.convert(host.convertFromLayer(bubble.frame), from: host), from: plane)
            try expect(abs(drawn.minX - frame.minX) < 0.01 && abs(drawn.minY - frame.minY) < 0.01
                       && abs(drawn.width - frame.width) < 0.01,
                       "\(label): the squircle's layer is drawn at \(drawn), the view expects \(frame)")
            var clips: [String] = []
            var ancestor = bubble.superlayer
            while let current = ancestor, current !== plane.layer {
                if current.masksToBounds || current.mask != nil { clips.append(String(describing: current.delegate.map { type(of: $0) })) }
                ancestor = current.superlayer
            }
            try expect(ancestor === plane.layer && clips.isEmpty,
                       "\(label): the squircle reaches the world plane unclipped (clipped by \(clips))")
            let hostIndex = plane.subviews.firstIndex(of: host) ?? -1
            let topTile = plane.subviews.lastIndex { $0 is TileNSView } ?? Int.max
            try expect(hostIndex > topTile, "\(label): the squircle is stacked above every tile (\(hostIndex) vs \(topTile))")
            // A press on the plate outside the tile is the tile's; one on the
            // empty corner of its box is not.
            let onPlate = NSPoint(x: frame.minX + overflow / 2, y: frame.midY)
            let corner = NSPoint(x: frame.minX + 0.3 * scale, y: frame.minY + 0.3 * scale)
            try expect(!view.bounds.contains(onPlate) && view.agentBubbleContains(onPlate),
                       "\(label): fixture point \(onPlate) is on the plate, outside the tile")
            try expect(!view.bounds.contains(corner) && !view.agentBubbleContains(corner),
                       "\(label): the empty corner of the box \(corner) is not the plate")
            if let frameView = canvas.superview {
                let hit = canvas.hitTest(frameView.convert(view.convert(onPlate, to: nil), from: nil))
                try expect(hit === view, "\(label): a press outside the tile on its plate hit \(String(describing: hit.map { type(of: $0) }))")
                let miss = canvas.hitTest(frameView.convert(view.convert(corner, to: nil), from: nil))
                try expect(miss !== view, "\(label): a press on the box's empty corner hit the tile")
            }
            try expect(bubble.qaArtClippedToPlate, "\(label): the art stays on its plate")
        } else {
            // Inline never leaves the tile: in the bar, hosted by it, clipped.
            try expect(frame.minX >= 0 && frame.minY >= -0.01 && frame.maxX <= view.bounds.width
                       && frame.maxY <= view.chromeBarHeight + pixel,
                       "\(label): Inline sits inside the bar \(frame) (bar \(view.chromeBarHeight))")
            let margin = 2 * TileAgentBubbleLayer.Inline.inset * scale
            try expect(frame.height <= view.chromeBarHeight + pixel && frame.height >= view.chromeBarHeight - margin - pixel
                       && abs(frame.width - frame.height) <= pixel,
                       "\(label): Inline is a square plate a little less than the bar tall (\(frame.size) vs \(view.chromeBarHeight))")
            try expect(bubble.qaArtClippedToPlate, "\(label): the art stays on its plate")
            try expect(view.agentBubbleView?.superview === bar, "\(label): Inline is hosted in its title bar, not the world plane")
            var ancestor: CALayer? = bubble.superlayer
            while let current = ancestor, current !== view.layer { ancestor = current.superlayer }
            try expect(ancestor === view.layer, "\(label): Inline's host lies inside its tile's layer")
            if let frameView = canvas.superview {
                let hit = canvas.hitTest(frameView.convert(view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), from: nil))
                try expect(hit === view, "\(label): a press on the inline icon is the tile's (\(String(describing: hit.map { type(of: $0) })))")
            }
            try expect(view.qaDragKindIsMove(at: NSPoint(x: frame.midX, y: frame.midY)), "\(label): the inline icon is a grab")
        }
        if let ink = view.qaCharacterInk {
            try expect(abs(ink.rect.midX - ink.target.x) <= pixel && abs(ink.rect.midY - ink.target.y) <= pixel,
                       "\(label): the art is centred in its slot (\(ink.rect) at \(ink.target))")
        } else {
            throw Failure(description: "\(label): no art")
        }
        let close = view.qaCloseButtonFrame
        try expect(close.minX >= frame.maxX, "\(label): × stays clear of the icon (\(close.minX) vs \(frame.maxX))")
        if let mark = view.qaProviderMarkRect {
            try expect(bar.convert(mark, to: view).minX >= frame.maxX, "\(label): the provider mark starts after the icon")
        }
        if let title = view.qaTitleRectInBar(), title.width > 0 {
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
        for zoom in [1.0, 0.5, 0.3] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded() }
            canvas.layoutSubtreeIfNeeded()
            try expect(plates().count == views.count, "zoom \(zoom): every tile shows its plate")
            guard let stroke = canvas.qaFocusBorderVisibleStrokePath, let overlay = canvas.qaFocusBorderOverlay else {
                throw Failure(description: "zoom \(zoom): no focus ants")
            }
            let would = uncutCrossings()
            try expect(would.contains(where: { $0 != 0 }),
                       "zoom \(zoom): fixture: the uncut ants would cross a neighbour's plate in the gutter (\(would))")
            try expect(crossings(stroke).isEmpty, "zoom \(zoom): the focus ants cross the plates of tiles \(crossings(stroke))")
            let painted = stroke.boundingBoxOfPath
            try expect(painted.width > overlay.frame.width * 0.9 && painted.height > overlay.frame.height * 0.9,
                       "zoom \(zoom): the ants still run round the tile (\(painted) in \(overlay.frame))")
        }

        // A tight outline gap brings the ants onto their own tile's plate too.
        let gapSuite = "ArrayTileAgentBubbleGap-\(UUID().uuidString)"
        let gapDefaults = UserDefaults(suiteName: gapSuite)!
        defer { gapDefaults.removePersistentDomain(forName: gapSuite) }
        gapDefaults.set(2.0, forKey: FocusBorderConfig.gapKey)
        let savedDefaults = canvas.focusBorderDefaults
        canvas.focusBorderDefaults = gapDefaults
        canvas.focusBorderConfigDidChange()
        canvas.layoutSubtreeIfNeeded()
        let tight = uncutCrossings()
        try expect(tight.contains(0), "fixture: at a 2 px gap the uncut ants cross their own plate (\(tight))")
        guard let tightStroke = canvas.qaFocusBorderVisibleStrokePath else { throw Failure(description: "no ants at 2 px") }
        try expect(crossings(tightStroke).isEmpty, "at a 2 px gap the ants cross the plates of tiles \(crossings(tightStroke))")
        canvas.focusBorderDefaults = savedDefaults
        canvas.focusBorderConfigDidChange()
        canvas.layoutSubtreeIfNeeded()

        // A neighbour moves under still ants: the cut follows it, filed by the move.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        let below = views[2]
        let home = below.frame.origin
        for dy in [-3.0, -5.0, 2.0] {
            below.setFrameOrigin(NSPoint(x: home.x + 2, y: home.y + dy))
            canvas.layoutSubtreeIfNeeded()
            guard let stroke = canvas.qaFocusBorderVisibleStrokePath else { throw Failure(description: "no ants") }
            try expect(crossings(stroke).isEmpty, "a neighbour moved \(dy) pt: the ants cross plates \(crossings(stroke))")
        }
        below.setFrameOrigin(home)
        canvas.layoutSubtreeIfNeeded()

        // O(1): a few hundred plates far away cost the ring nothing more.
        guard let overlay = canvas.qaFocusBorderOverlay else { throw Failure(description: "no ants") }
        var visits = plane.qaAgentBubbleCandidateVisits
        overlay.refreshBubbleCut()
        let near = plane.qaAgentBubbleCandidateVisits - visits
        var far: [TileAgentBubbleView] = []
        for index in 0..<400 {
            let host = TileAgentBubbleView(bubble: TileAgentBubbleLayer(sprite: CharacterSpriteLayer()), tile: views[0])
            host.frame = NSRect(x: 40_000 + Double(index % 20) * 600, y: 40_000 + Double(index / 20) * 400, width: 28, height: 28)
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
        canvas.tileSelection.selectByMarquee(Set([views[1].tile.id, views[2].tile.id, views[3].tile.id]))
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
        // Positive control: a neighbour's plate moving does rebuild them.
        below.setFrameOrigin(NSPoint(x: below.frame.minX + 3, y: below.frame.minY - 3))
        canvas.layoutSubtreeIfNeeded()
        _ = selection.qaVisibleStrokePaths
        try expect(overlay.qaMaskBuilds > maskBuilds || selection.qaAreaBuilds > areaBuilds,
                   "fixture: moving a plate near the rings rebuilds a mask")
        below.setFrameOrigin(home)
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        canvas.tileSelection.clear()
        canvas.layoutSubtreeIfNeeded()

        // Every corner style: the plate's top-left stays concentric with the
        // tile's corner (Rounded's radius outgrows half the plate), and the
        // ants cut around the new outline.
        defer { CornerStyleController.apply(.standard); canvas.layoutSubtreeIfNeeded() }
        for cornerStyle in CornerStyle.allCases {
            CornerStyleController.apply(cornerStyle)
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded() }
            canvas.layoutSubtreeIfNeeded()
            let view = views[3]
            guard let frame = view.agentBubbleFrame, let radius = view.layer?.cornerRadius else {
                throw Failure(description: "\(cornerStyle): no plate")
            }
            let overflow = -frame.minX
            let diagonal = CGPoint(x: -1 / 2.0.squareRoot(), y: -1 / 2.0.squareRoot())
            if radius > 0 {
                let reach = radius + overflow
                let inner = NSPoint(x: radius + diagonal.x * (reach - 0.75), y: radius + diagonal.y * (reach - 0.75))
                let outer = NSPoint(x: radius + diagonal.x * (reach + 0.75), y: radius + diagonal.y * (reach + 0.75))
                try expect(view.agentBubbleContains(inner) && !view.agentBubbleContains(outer),
                           "\(cornerStyle): the plate's top-left is concentric with the tile's \(radius) pt corner (in \(inner): \(view.agentBubbleContains(inner)), out \(outer): \(view.agentBubbleContains(outer)))")
            } else {
                try expect(view.agentBubbleContains(NSPoint(x: frame.minX + 0.3, y: frame.minY + 0.3)),
                           "\(cornerStyle): a sharp tile has a square plate")
            }
            guard let stroke = canvas.qaFocusBorderVisibleStrokePath else { throw Failure(description: "no ants") }
            try expect(crossings(stroke).isEmpty, "\(cornerStyle): the ants cross the plates of tiles \(crossings(stroke))")
        }
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

    /// Dylan's state: the agent with no colour, selected, at 125%, and the
    /// zone at 30%, in both finalists, light and dark.
    private static func writeRenders(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                     views: [ManagedAgentTileNSView], focusBroker: FocusBroker,
                                     to directory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        let subject = views[3]
        guard let world = canvas.allTilesInWorldFrames().first(where: { $0.id == subject.tile.id })?.frame else {
            throw Failure(description: "no world frame for the uncoloured agent")
        }
        for style in [Style.inline, .squircle] {
            setSetting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            try expect(pump(until: { showsStyle(style, views, canvas) }), "\(style.title) for the stills")
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                let zoom = 1.25
                canvas.setViewport(CanvasViewport(x: world.x - 140 / zoom, y: world.y - 110 / zoom, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                canvas.markActive(tileId: subject.tile.id)
                canvas.qaFocusBorderOverlay?.qaFreeze()
                pump(0.3)
                let close = try capture(canvas, window, rect: NSRect(x: 40, y: 20, width: 640, height: 300))
                let closeURL = directory.appendingPathComponent("\(style.rawValue)-\(name)-selected-nocolour-125.png")
                try write(close, to: closeURL)
                written.append(closeURL.path)
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 0.3))
                canvas.layoutSubtreeIfNeeded()
                canvas.qaFocusBorderOverlay?.qaFreeze()
                pump(0.3)
                let overview = try capture(canvas, window, rect: NSRect(x: 0, y: 0, width: 400, height: 260))
                let overviewURL = directory.appendingPathComponent("\(style.rawValue)-\(name)-selected-zoom30.png")
                try write(overview, to: overviewURL)
                written.append(overviewURL.path)
            }
        }
        window.appearance = nil
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        pump(0.2)
        return written.map { "wrote \($0)" }
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
        if !style.breaksCorner {
            // Inline overlaps the tile's top resize band: there, as a press
            // moves the tile, the cursor is the open hand.
            let banded = NSPoint(x: icon.midX, y: icon.minY + 0.5)
            try expect(view.qaResizeEdge(at: banded) != nil, "fixture: Inline's top lies in the resize band")
            points.append(("on the plate, in the top resize band", banded, .openHand))
            try expect(view.agentBubbleCursor(at: NSPoint(x: 0.1, y: icon.maxY - 0.1)) == .resizeLeftRight,
                       "Inline: the left edge beside the icon resizes")
        }
        let overflow = -icon.minX
        if style.breaksCorner { points += [
            ("right edge", NSPoint(x: icon.maxX - 0.1, y: icon.midY), .openHand),
            ("left edge, outside the tile", NSPoint(x: icon.minX + 0.1, y: icon.midY), .openHand),
            ("top edge, outside the tile", NSPoint(x: icon.midX, y: icon.minY + 0.1), .openHand),
            ("on the plate, outside the tile", NSPoint(x: icon.minX + overflow / 2, y: icon.midY), .openHand),
            ("the box's empty corner, outside the tile", NSPoint(x: icon.minX + 0.1, y: icon.minY + 0.1), .arrow),
            ("the box's lower-left corner on the left edge", NSPoint(x: 0.1, y: icon.maxY - 0.1), .resizeLeftRight),
        ] }
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
    }

    // MARK: Drag from the icon, on the production mount

    static func runDrag() async throws -> String {
        acceptFirstMouseEverywhere()
        var lines: [String] = []
        for zoom in [1.0, 0.5] {
            lines.append(try await exerciseDrag(zoom: zoom, style: .inline).0)
            lines.append(try await exerciseDrag(zoom: zoom, style: .squircle).0)
            let bubble = try await exerciseDrag(zoom: zoom, style: .squircle, snapping: true)
            let title = try await exerciseDrag(zoom: zoom, style: .squircle, snapping: true, titleBar: true)
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

        if style.breaksCorner {
            // The squircle's view travels with the tile.
            guard let host = view.agentBubbleView, let plane = view.superview else {
                throw Failure(description: "\(label): no squircle view after the drag")
            }
            let expectedHost = view.convert(again, to: plane)
            try expect(host.superview === plane && abs(host.frame.minX - expectedHost.minX) < 0.01
                       && abs(host.frame.minY - expectedHost.minY) < 0.01,
                       "\(label): the squircle's view \(host.frame) followed its tile to \(expectedHost)")

            // 2. From the part of the plate outside the tile: the press hits the tile.
            let outside = NSPoint(x: again.minX - again.minX / 2, y: again.midY)
            try expect(!view.bounds.contains(outside) && view.agentBubbleContains(outside),
                       "\(label): the probe point lies on the plate, outside the tile")
            let hung = try drag(from: outside, by: CGSize(width: 36, height: -30), name: "outside")
            try expect(hung.after.width == hung.before.width && hung.after.height == hung.before.height,
                       "\(label): dragging the plate from outside the tile resized it (\(hung.before) → \(hung.after))")
            try expect(snapping || (abs(hung.after.x - hung.before.x - 36 / zoom) < 2 / zoom
                                    && abs(hung.after.y - hung.before.y + 30 / zoom) < 2 / zoom),
                       "\(label): ...and moved it with the pointer (\(hung.after.x - hung.before.x), \(hung.after.y - hung.before.y))")
        } else {
            try expect(view.agentBubbleView?.superview === view.qaTitleBarView && again.minX >= 0 && again.minY >= -0.01,
                       "\(label): Inline stays in its title bar through the drag (\(again))")
        }

        // 3. From the part of the icon that lies in the top edge's resize band.
        canvas.layoutSubtreeIfNeeded()
        guard let third = view.agentBubbleFrame else { throw Failure(description: "\(label): no icon") }
        // The squircle's top crosses the tile's edge; Inline's sits just below it.
        let corner = NSPoint(x: third.midX + third.width / 4, y: max(1 / zoom, third.minY + 0.5 / zoom))
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
