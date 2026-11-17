import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

/// `--tile-agent-icon-styles-check`: the four tile icon styles, the icon size
/// setting, the working light and icons-off, on the real
/// tiles of `--tile-agent-bubble-check`'s fixture.
///
/// - Every style renders and is opaque; Minimal holds the provider mark in its
///   plate (the one beside the title steps aside), the others do not.
/// - The size setting changes the side the icon really has on screen, at 30, 80
///   and 125 % zoom, and below 80 % it tapers by `sqrt(zoom / 0.8)`.
/// - The working light is attached while working and gone when idle or paused;
///   it never lays the title bar out; the provider mark never animates.
/// - No style warps the art: the sprite's contents are the atlas picture.
/// - Icons off draw nothing in the corner, whatever the style, and the provider
///   mark stays beside the title.
///
/// `ARRAY_AGENT_ICON_STILLS_DIR=<dir>` also writes a still of every style, size
/// and appearance. The matrix sets nothing.
@MainActor
enum TileAgentIconStyleChecks {
    typealias Check = TileAgentBubbleChecks
    typealias Style = AgentCharacterConfig.BubbleStyle

    private static func setting(_ defaults: UserDefaults, _ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        SettingChangeEvent.post(SettingID(rawValue: key))
    }

    private static func settle(_ canvas: CanvasNSView, _ views: [ManagedAgentTileNSView], zoom: Double, around world: TileFrame) {
        canvas.setViewport(CanvasViewport(x: world.x - 70 / zoom, y: world.y - 70 / zoom, zoom: zoom))
        for _ in 0..<2 {
            canvas.layoutSubtreeIfNeeded()
            for view in views { view.layoutSubtreeIfNeeded(); view.placeAgentBubble() }
        }
        Check.pump(0.12)
        canvas.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    private static func show(_ style: Style, _ views: [ManagedAgentTileNSView], _ canvas: CanvasNSView,
                             _ defaults: UserDefaults) throws {
        setting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
        try Check.expect(Check.pump(until: {
            canvas.layoutSubtreeIfNeeded()
            return views.allSatisfy { view in
                view.layoutSubtreeIfNeeded()
                return view.qaAgentBubble?.bubbleStyle == style && view.agentBubbleFrame != nil
            }
        }), "\(style.title) reaches every tile")
    }

    private static func choose(size: AgentCharacterConfig.IconScale, _ views: [ManagedAgentTileNSView],
                               _ canvas: CanvasNSView, _ defaults: UserDefaults) throws {
        setting(defaults, AgentCharacterConfig.iconScaleKey, size.rawValue)
        try Check.expect(Check.pump(until: { AgentCharacterController.shared.iconScale == size }), "\(size.title) size reaches the controller")
    }

    /// The icon's side on screen, in points: what the user sees.
    private static func screenSide(_ view: ManagedAgentTileNSView, in canvas: CanvasNSView) throws -> CGFloat {
        guard let host = view.agentBubbleView, let plane = host.superview, !host.isHidden else {
            throw Check.Failure(description: "no icon host")
        }
        return canvas.convert(host.frame, from: plane).width
    }

    static func run(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                    views: [ManagedAgentTileNSView]) throws -> String {
        var report: [String] = []
        let subject = views[0]
        let world = canvas.allTilesInWorldFrames().first { $0.id == subject.tile.id }!.frame
        let controller = AgentCharacterController.shared
        let stills = ProcessInfo.processInfo.environment["ARRAY_AGENT_ICON_STILLS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        if let stills { try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true) }
        setting(defaults, SidebarActiveIndicatorStyle.defaultsKey, "classic")

        // 0. Defaults: nothing about a fresh install changed.
        try Check.expect(AgentCharacterConfig.defaultBubbleStyle == .inline, "the default style is still Inline")
        try Check.expect(AgentCharacterConfig.defaultIconScale == .standard && AgentCharacterConfig.defaultIconScale.factor == 1,
                         "the default icon size is 1x")
        try Check.expect(AgentCharacterConfig.defaultEnabled == false, "icons are off by default")
        try Check.expect(AgentCharacterConfig.BubbleStyle.allCases.map(\.title) == ["Inline", "Squircle", "Orb", "Minimal"],
                         "the Tile icon choices are Inline, Squircle, Orb, Minimal")
        try Check.expect(AgentCharacterConfig.IconScale.allCases.map(\.factor) == [0.8, 1, 1.2], "sizes are 0.8x, 1x, 1.2x")
        try Check.expect(abs(AgentCharacterConfig.iconTaper(zoom: 0.2) - 0.5) < 1e-9
                         && AgentCharacterConfig.iconTaper(zoom: 0.8) == 1 && AgentCharacterConfig.iconTaper(zoom: 1.25) == 1,
                         "the taper is sqrt(zoom / 0.8) below 80% and 1 above")

        // 1. No style bends the art: every sprite shows its atlas's own picture.
        for style in Style.allCases {
            try show(style, views, canvas, defaults)
            for view in views {
                guard let layer = view.qaAgentBubble?.sprite, let atlas = layer.sprite else { continue }
                try Check.expect((layer.contents as AnyObject?) === atlas.image, "\(style.title) shows the atlas picture, unwarped")
            }
        }
        report.append("art: pixel-exact atlas in every style")

        // 1. Each style renders, opaque, in both appearances; Minimal holds the mark.
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            Check.pump(0.2)
            for style in Style.allCases {
                try show(style, views, canvas, defaults)
                settle(canvas, views, zoom: 1.25, around: world)
                for (index, view) in views.enumerated() {
                    let label = "\(style.title) \(theme) tile \(index)"
                    guard let bubble = view.qaAgentBubble, let host = view.agentBubbleView else {
                        throw Check.Failure(description: "\(label): no icon")
                    }
                    try Check.expect(!host.isHidden && bubble.qaPlateColors.count == 2 && bubble.qaPlateColors.allSatisfy { $0.alpha == 1 },
                                     "\(label): the plate is not opaque")
                    try Check.expect(bubble.qaPlateMaskPath != nil && bubble.qaParts.plateShown, "\(label): no plate")
                    if style == .minimalSquircle {
                        try Check.expect(bubble.qaMarkShown, "\(label): Minimal holds the provider mark")
                        try Check.expect(view.qaProviderMarkRect == nil, "\(label): the title's own mark steps aside")
                        try Check.expect(view.qaCharacterRect == nil, "\(label): Minimal shows no character")
                        try Check.expect(bubble.qaParts.ringShown && !bubble.qaParts.glassShown, "\(label): a full border, no glass")
                    } else {
                        try Check.expect(!bubble.qaMarkShown, "\(label): only Minimal draws the mark in the plate")
                        try Check.expect(view.qaProviderMarkRect != nil, "\(label): the provider mark stays beside the title")
                        try Check.expect(view.qaCharacterRect != nil, "\(label): the character shows")
                    }
                }
                // Rendered: the plate's centre is painted, not the tile's bar behind it.
                let frame = try { () throws -> NSRect in
                    guard let host = subject.agentBubbleView, let plane = host.superview else { throw Check.Failure(description: "no host") }
                    return canvas.convert(host.frame, from: plane)
                }()
                let picture = try Check.capture(canvas, window, rect: frame)
                let data = try Check.rgba(picture)
                var distinct = Set<UInt32>()
                for offset in stride(from: 0, to: data.count, by: 4) {
                    let red = UInt32(data[offset]), green = UInt32(data[offset + 1]), blue = UInt32(data[offset + 2])
                    distinct.insert((red << 16) | (green << 8) | blue)
                }
                try Check.expect(distinct.count >= 3, "\(style.title) \(theme): the icon rendered nothing (\(distinct.count) colours)")
                report.append("\(style.title) \(theme): renders, opaque")
            }
        }
        window.appearance = nil

        // 2. Size: the side on screen follows the setting at 30/80/125 %.
        try show(.orb, views, canvas, defaults)
        var sides: [String: [Double: CGFloat]] = [:]
        for size in AgentCharacterConfig.IconScale.allCases {
            try choose(size: size, views, canvas, defaults)
            for zoom in [0.3, 0.8, 1.25] {
                settle(canvas, views, zoom: zoom, around: world)
                for (index, view) in views.enumerated() {
                    let side = try screenSide(view, in: canvas)
                    if index == 0 { sides[size.rawValue, default: [:]][zoom] = side }
                    try Check.expect(side > 0 && side < 45, "\(size.title) at \(zoom): the icon is \(side) pt on screen")
                }
            }
        }
        for zoom in [0.3, 0.8, 1.25] {
            let small = sides["small"]![zoom]!, standard = sides["standard"]![zoom]!, large = sides["large"]![zoom]!
            try Check.expect(small < standard && standard < large, "at \(Int(zoom * 100))% sizes must differ: \(small) / \(standard) / \(large)")
            try Check.expect(abs(small / standard - 0.8) < 0.08 && abs(large / standard - 1.2) < 0.08,
                             "at \(Int(zoom * 100))% Small and Large are 0.8x and 1.2x of Default: \(small) / \(standard) / \(large)")
            report.append(String(format: "size at %d%%: small %.1f / default %.1f / large %.1f pt", Int(zoom * 100), small, standard, large))
        }
        try Check.expect(sides["standard"]![0.3]! < sides["standard"]![0.8]!, "the icon keeps shrinking below 80% zoom")
        try choose(size: .standard, views, canvas, defaults)

        // 4. The working light: attached while working, removed when idle or paused.
        for style in [Style.orb, .minimalSquircle] {
            try show(style, views, canvas, defaults)
            settle(canvas, views, zoom: 1.25, around: world)
            let bubble = subject.qaAgentBubble!
            let phase = bubble.phase
            try Check.expect(bubble.isWorking, "\(style.title): the fixture's first agent is working")
            try Check.expect(bubble.isMoving && bubble.qaAnimationKeys.contains(TileAgentBubbleLayer.motionKeyPrefix + (style == .orb ? "churn.current" : "rim")),
                             "\(style.title): the working light is attached while working (\(bubble.qaAnimationKeys))")
            try Check.expect(bubble.qaParts.orbitShown, "\(style.title): the rim light is visible while working")
            let layouts = subject.qaTitleBarLayoutPasses
            let markFrame = bubble.qaMarkFrame
            Check.pump(0.6)
            try Check.expect(subject.qaTitleBarLayoutPasses == layouts, "\(style.title): the working light must not lay out the title bar")
            try Check.expect(bubble.qaMarkAnimationKeys.isEmpty && bubble.qaMarkFrame == markFrame,
                             "\(style.title): the provider mark never animates")
            bubble.setWorking(false, style: "classic", phase: phase)
            try Check.expect(!bubble.isMoving && bubble.qaAnimationKeys.isEmpty && !bubble.qaParts.orbitShown,
                             "\(style.title): idle removes every layer animation (\(bubble.qaAnimationKeys))")
            bubble.setWorking(true, style: "classic", phase: phase)
            bubble.setPaused(true)
            try Check.expect(bubble.qaAnimationKeys.isEmpty, "\(style.title): paused removes every layer animation")
            bubble.setPaused(false)
            try Check.expect(!bubble.qaAnimationKeys.isEmpty, "\(style.title): resuming brings the rim light back")
            // The idle tile of the fixture never animates.
            let idle = views[1].qaAgentBubble!
            try Check.expect(!idle.isWorking && idle.qaAnimationKeys.isEmpty, "\(style.title): an idle agent's icon holds still")
            report.append("\(style.title): rim light attached working, removed idle/paused, no layout, mark still")
        }

        report.append(try checkWorkingStyleTransitions(canvas: canvas, window: window, defaults: defaults, views: views))

        // 5. Stills of every style, size and appearance.
        if let stills {
            let rect = NSRect(x: 0, y: 0, width: 820, height: 460)
            for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                window.appearance = NSAppearance(named: appearance)
                Check.pump(0.2)
                for style in Style.allCases {
                    try show(style, views, canvas, defaults)
                    for size in AgentCharacterConfig.IconScale.allCases {
                        try choose(size: size, views, canvas, defaults)
                        for (zoomName, zoom) in [("30", 0.3), ("80", 0.8), ("125", 1.25)] where size == .standard || zoom == 1.25 {
                            settle(canvas, views, zoom: zoom, around: world)
                            try Check.write(try Check.capture(canvas, window, rect: rect),
                                            to: stills.appendingPathComponent("\(style.rawValue)-\(size.rawValue)-\(zoomName)-\(theme).png"))
                        }
                    }
                    try choose(size: .standard, views, canvas, defaults)
                    // Idle, to read the plate itself.
                    settle(canvas, views, zoom: 1.25, around: world)
                    let bubble = subject.qaAgentBubble!
                    let phase = bubble.phase
                    bubble.setWorking(false, style: "classic", phase: phase)
                    try Check.write(try Check.capture(canvas, window, rect: rect),
                                    to: stills.appendingPathComponent("\(style.rawValue)-idle-125-\(theme).png"))
                    bubble.setWorking(true, style: "classic", phase: phase)
                }
            }
            window.appearance = nil
            report.append("stills written to \(stills.path)")
        }

        // 6. Icons off: nothing in the corner, the provider mark beside the title.
        settle(canvas, views, zoom: 1.25, around: world)
        var corner: [Style: CGImage] = [:]
        let cornerRect = NSRect(x: 0, y: 0, width: 360, height: 220)
        setting(defaults, AgentCharacterConfig.enabledKey, false)
        try Check.expect(Check.pump(until: { views.allSatisfy { $0.agentBubbleFrame == nil } }), "icons off removes every icon")
        for style in Style.allCases {
            setting(defaults, AgentCharacterConfig.bubbleStyleKey, style.rawValue)
            Check.pump(0.3)
            settle(canvas, views, zoom: 1.25, around: world)
            for (index, view) in views.enumerated() {
                let label = "icons off, \(style.title), tile \(index)"
                try Check.expect(view.agentBubbleFrame == nil, "\(label): an icon frame remains")
                try Check.expect(view.agentBubbleView.map { $0.isHidden || $0.bubble.isHidden } ?? true, "\(label): an icon view still shows")
                try Check.expect(view.qaCharacterRect == nil, "\(label): a character remains")
                try Check.expect(view.qaProviderMarkRect != nil, "\(label): the provider mark left the title")
            }
            corner[style] = try Check.capture(canvas, window, rect: cornerRect)
        }
        let base = corner[.inline]!
        for style in Style.allCases where style != .inline {
            let change = try Check.largestChannelChange(base, corner[style]!)
            try Check.expect(change == 0, "icons off: \(style.title) draws something in the corner (change \(change))")
        }
        controller.reload(force: true)
        report.append("icons off: no plate, no hanging icon, provider mark beside the title, corner identical in all styles")

        return (["PASS tile agent icon styles"] + report).joined(separator: "\n")
    }

    /// Sidebar light choices do not remove the Orb's static liquid glow or
    /// strand gradient stops in another style. A live size change must also
    /// update the installed liquid movement to the icon that is actually drawn.
    private static func checkWorkingStyleTransitions(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                                                     views: [ManagedAgentTileNSView]) throws -> String {
        var failures: [String] = []
        func verdict(_ condition: Bool, _ message: String) {
            print("icon transition \(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures.append(message) }
        }
        defer {
            window.appearance = nil
            setting(defaults, SidebarActiveIndicatorStyle.defaultsKey, "classic")
            setting(defaults, AgentCharacterConfig.iconScaleKey, AgentCharacterConfig.IconScale.standard.rawValue)
            setting(defaults, AgentCharacterConfig.bubbleStyleKey, Style.inline.rawValue)
        }
        let idle = views[1], working = views[0]
        guard let idleWorld = canvas.allTilesInWorldFrames().first(where: { $0.id == idle.tile.id })?.frame,
              let workingWorld = canvas.allTilesInWorldFrames().first(where: { $0.id == working.tile.id })?.frame else {
            throw Check.Failure(description: "working-style transitions require real installed tiles")
        }
        func light(_ value: String) throws {
            setting(defaults, SidebarActiveIndicatorStyle.defaultsKey, value)
            try Check.expect(Check.pump(until: {
                views.allSatisfy { $0.qaAgentBubble?.workingStyle == value }
            }), "the \(value) light choice reaches every real icon")
        }

        // At rest only the Orb's own liquid/glass is visible. The sidebar's
        // Sheen choice must render the same globe as Classic, in both themes.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try show(.orb, views, canvas, defaults)
            try light("classic")
            settle(canvas, views, zoom: 1.25, around: idleWorld)
            guard let bubble = idle.qaAgentBubble else { throw Check.Failure(description: "no idle globe") }
            try Check.expect(!bubble.isWorking && bubble.qaParts.sheenShown,
                             "\(name): the idle globe is a positive control with a visible middle glow")
            let centre = CGPoint(x: bubble.bounds.midX, y: bubble.bounds.midY)
            try Check.expect(bubble.qaSheenFrame.contains(centre), "\(name): Classic's liquid glow covers the globe's middle")
            let classic = try modelPicture(idle)
            try light("sheen")
            settle(canvas, views, zoom: 1.25, around: idleWorld)
            verdict(bubble.qaSheenFrame.contains(centre), "\(name): Orb under Sheen keeps the liquid glow in the globe")
            let sheen = try modelPicture(idle)
            let delta = try Check.largestChannelChange(classic, sheen)
            verdict(delta <= 1, "\(name): Orb's static rendered glow survives the Sheen setting (pixel change \(delta))")
        }

        // Leaving the Orb's two-stop radial glow must not leave those locations
        // on the different highlight used by the working Inline or Squircle.
        try light("sheen")
        for style in [Style.inline, .squircle] {
            try show(.orb, views, canvas, defaults)
            settle(canvas, views, zoom: 1.25, around: workingWorld)
            try show(style, views, canvas, defaults)
            settle(canvas, views, zoom: 1.25, around: workingWorld)
            guard let bubble = working.qaAgentBubble else { throw Check.Failure(description: "no working icon") }
            try Check.expect(bubble.isWorking && bubble.qaParts.sheenShown, "\(style.title): the working Sheen highlight is present")
            let stops = bubble.qaSheenStops
            verdict(stops.colors >= 2 && (stops.locations == nil || stops.locations == stops.colors),
                    "Orb → \(style.title) Sheen has compatible gradient stops (\(stops.colors) colors, \(String(describing: stops.locations)) locations)")
        }

        // Both choices used to skip motion reconciliation on ordinary bounds
        // changes. Drive the actual icon-size setting while the Orb is working.
        for choice in ["classic", "gradient"] {
            try light(choice)
            try show(.orb, views, canvas, defaults)
            settle(canvas, views, zoom: 1.25, around: workingWorld)
            guard let bubble = working.qaAgentBubble else { throw Check.Failure(description: "no working globe") }
            try Check.expect(bubble.isWorking && !bubble.isPaused, "\(choice): the globe must be working and visible")
            var sizes: [CGFloat] = []
            for size in [AgentCharacterConfig.IconScale.small, .large] {
                try choose(size: size, views, canvas, defaults)
                settle(canvas, views, zoom: 1.25, around: workingWorld)
                sizes.append(bubble.bounds.height)
                guard let offsets = bubble.qaLiquidSurfaceOffsets else {
                    throw Check.Failure(description: "\(choice): the working globe has no installed liquid movement")
                }
                let amplitude = bubble.bounds.height * 0.02
                verdict(abs(offsets.from + amplitude) < 0.0001 && abs(offsets.to - amplitude) < 0.0001,
                        "\(choice) live \(size.title): installed liquid offsets \(offsets.from)/\(offsets.to) fit current \(bubble.bounds.height)pt globe")
            }
            try Check.expect(sizes.count == 2 && sizes[1] > sizes[0] * 1.2,
                             "\(choice): the real size setting must resize the globe, not just its expected amplitude")
        }
        try Check.expect(failures.isEmpty, "working-style transitions: \(failures.joined(separator: "; "))")
        return "working-style transitions: static glow in light/dark, valid Orb→Sheen stops, live resized liquid movement"
    }

    /// Render the actual icon's model layer tree so comparison is independent of
    /// render-server animation phase while retaining its real masks and gradients.
    private static func modelPicture(_ view: ManagedAgentTileNSView) throws -> CGImage {
        guard let host = view.agentBubbleView, let layer = host.layer,
              host.bounds.width > 0, host.bounds.height > 0 else {
            throw Check.Failure(description: "no real icon layer to render")
        }
        view.qaAgentBubble?.layoutIfNeeded()
        let scale: CGFloat = 4
        let width = Int(ceil(host.bounds.width * scale)), height = Int(ceil(host.bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Check.Failure(description: "could not allocate the icon comparison")
        }
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { throw Check.Failure(description: "could not render the real icon") }
        return image
    }
}
