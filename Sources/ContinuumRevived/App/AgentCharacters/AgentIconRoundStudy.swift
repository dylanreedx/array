import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Opt-in design studies on the existing real tile fixture. No app setting.
@MainActor
enum AgentIconRoundStudy {
    static func render(canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                       views: [ManagedAgentTileNSView], directory: URL) throws -> String {
        typealias Check = TileAgentBubbleChecks
        if let mode = ProcessInfo.processInfo.environment["ARRAY_AGENT_ICON_ROUND_MODE"], mode.hasPrefix("lens") {
            return try renderLens(clip: mode == "lens-clip", canvas: canvas, window: window, defaults: defaults,
                                  views: views, directory: directory)
        }
        if let mode = ProcessInfo.processInfo.environment["ARRAY_AGENT_ICON_ROUND_MODE"], !mode.isEmpty {
            return try renderInside(clips: mode == "clips", canvas: canvas, window: window, defaults: defaults,
                                    views: views, directory: directory)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stills = directory.appendingPathComponent("stills")
        let motion = directory.appendingPathComponent("frames")
        try fm.createDirectory(at: stills, withIntermediateDirectories: true)
        try fm.createDirectory(at: motion, withIntermediateDirectories: true)
        var report: [String] = []
        var measurements: [[String: Any]] = []
        let subject = views[0]
        let world = canvas.allTilesInWorldFrames().first { $0.id == subject.tile.id }!.frame
        let sizes: [(String, CGFloat)] = [("small", 0.8), ("default", 1), ("large", 1.2)]
        let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
        let rect = NSRect(x: 0, y: 0, width: 820, height: 460)
        func setting(_ key: String, _ value: Any) {
            defaults.set(value, forKey: key)
            SettingChangeEvent.post(SettingID(rawValue: key))
        }
        func study(_ name: String, zoom: Double, size: CGFloat = 1) {
            let taper = min(1, CGFloat(zoom / 0.8).squareRoot())
            TileAgentBubbleLayer.qaRoundSizeMultiplier = size * taper
            setting(AgentCharacterConfig.bubbleStyleKey, name.hasPrefix("minimal-") ? "squircle" : "orb")
            canvas.setViewport(CanvasViewport(x: world.x - 70 / zoom, y: world.y - 70 / zoom, zoom: zoom))
            Check.pump(0.15)
            for view in views {
                view.qaRoundProviderMarkInPlate(name.hasPrefix("minimal-"))
                view.qaAgentBubble?.qaRoundStudy = name
                view.needsLayout = true
                view.qaTitleBarView?.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.placeAgentBubble()
                view.qaAgentBubble?.layoutIfNeeded()
            }
            canvas.layoutSubtreeIfNeeded()
            Check.pump(0.15)
        }
        func mark(dark: Bool) -> CGImage? {
            guard let source = BrandMark96.mark(forModel: "anthropic/claude-haiku-4-5-20251001") else { return nil }
            let result = NSImage(size: NSSize(width: 128, height: 128))
            result.lockFocus()
            source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
            (dark ? NSColor.white : NSColor.black).setFill()
            NSRect(x: 0, y: 0, width: 128, height: 128).fill(using: .sourceIn)
            result.unlockFocus()
            return result.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        func appearance(_ name: NSAppearance.Name) {
            window.appearance = NSAppearance(named: name)
            Check.pump(0.2)
            let image = mark(dark: name == .darkAqua)
            for view in views { view.qaAgentBubble?.qaRoundMark = image }
        }
        setting(AgentCharacterConfig.sizeKey, "small")
        setting(SidebarActiveIndicatorStyle.defaultsKey, "classic")
        Check.pump(0.2)
        // Three complete bordered minimal shapes, with real working and idle tiles.
        for (theme, app) in appearances {
            appearance(app)
            for kind in ["minimal-circle", "minimal-square", "minimal-squircle"] {
                study(kind, zoom: 1.25)
                try Check.write(Check.capture(canvas, window, rect: rect), to: stills.appendingPathComponent("\(kind)-\(theme).png"))
                let bubble = subject.qaAgentBubble!
                try Check.expect(bubble.qaParts.ringShown && bubble.qaPlateColors.allSatisfy { $0.alpha == 1 },
                                 "\(kind): full border and opaque token background")
                try Check.expect(bubble.isMoving && !bubble.qaAnimationKeys.isEmpty, "\(kind): working has a layer animation")
                bubble.setWorking(false, style: "classic", phase: 0)
                try Check.expect(!bubble.isMoving && bubble.qaAnimationKeys.isEmpty, "\(kind): idle removes layer animations")
                try Check.write(Check.capture(canvas, window, rect: rect), to: stills.appendingPathComponent("\(kind)-\(theme)-idle.png"))
                bubble.setWorking(true, style: "classic", phase: 0)
            }
            for kind in ["minimal-squircle", "orb-rim"] {
                for (sizeName, scale) in sizes {
                    for (zoomName, zoom) in [("30", 0.3), ("80", 0.8), ("125", 1.25)] {
                        study(kind, zoom: zoom, size: scale)
                        guard let host = subject.agentBubbleView, let plane = host.superview else { throw Check.Failure(description: "no icon host") }
                        let frame = canvas.convert(host.frame, from: plane)
                        measurements.append(["style": kind, "appearance": theme, "size": sizeName, "zoom": zoom,
                                             "screenSide": frame.width, "worldSide": host.frame.width])
                        try Check.expect(frame.width > 0 && frame.width < 40, "bounded visible icon at \(zoom)")
                        try Check.write(Check.capture(canvas, window, rect: rect),
                                        to: stills.appendingPathComponent("size-\(kind)-\(sizeName)-\(theme)-\(zoomName).png"))
                    }
                }
            }
        }
        // Live render-server frames. Time stamps preserve the capture cadence.
        for (theme, app) in appearances {
            appearance(app)
            for kind in ["minimal-circle", "minimal-square", "minimal-squircle", "orb-rim", "orb-breath", "orb-current"] {
                study(kind, zoom: 1.25)
                let output = motion.appendingPathComponent("\(kind)-\(theme)")
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                var times: [Double] = []
                let start = CACurrentMediaTime()
                let layoutsBefore = subject.qaTitleBarLayoutPasses
                for frame in 0..<36 {
                    let image = try Check.capture(canvas, window, rect: NSRect(x: 30, y: 30, width: 600, height: 160))
                    times.append(CACurrentMediaTime() - start)
                    try Check.write(image, to: output.appendingPathComponent(String(format: "%03d.png", frame)))
                }
                try Check.expect(subject.qaTitleBarLayoutPasses == layoutsBefore,
                                 "\(kind): motion must not lay out the title bar")
                try JSONSerialization.data(withJSONObject: times).write(to: output.appendingPathComponent("times.json"))
                let bubble = subject.qaAgentBubble!
                bubble.setWorking(false, style: "classic", phase: 0)
                try Check.expect(bubble.qaAnimationKeys.isEmpty && !bubble.isMoving, "\(kind): idle motion removed")
                bubble.setWorking(true, style: "classic", phase: 0)
                bubble.setPaused(true)
                try Check.expect(bubble.qaAnimationKeys.isEmpty, "\(kind): paused motion removed")
                bubble.setPaused(false)
                try Check.expect(!bubble.qaAnimationKeys.isEmpty, "\(kind): working motion resumes")
                report.append("PASS \(kind) \(theme): working / idle / paused / resume; 36 real-window frames")
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("measurements.json"))
        let summary = (["PASS agent icon design round", "48 stills, 432 live motion frames, isolated fixture; no app settings added"] + report).joined(separator: "\n")
        try summary.write(to: directory.appendingPathComponent("capture-checks.txt"), atomically: true, encoding: .utf8)
        TileAgentBubbleLayer.qaRoundSizeMultiplier = 1
        return summary
    }

    /// Round 2: the art seated inside the orb's glass, the provider mark's home,
    /// and frame-exact clips of the working motion.
    static func renderInside(clips: Bool, canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                             views: [ManagedAgentTileNSView], directory: URL) throws -> String {
        typealias Check = TileAgentBubbleChecks
        let fm = FileManager.default
        let out = directory.appendingPathComponent(clips ? "clips-frames" : "inside")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let subject = views[0]
        let world = canvas.allTilesInWorldFrames().first { $0.id == subject.tile.id }!.frame
        let rect = NSRect(x: 0, y: 0, width: 820, height: 460)
        var report: [String] = []
        func setting(_ key: String, _ value: Any) {
            defaults.set(value, forKey: key)
            SettingChangeEvent.post(SettingID(rawValue: key))
        }
        func study(_ name: String?, inside: String?, zoom: Double) {
            let taper = min(1, CGFloat(zoom / 0.8).squareRoot())
            TileAgentBubbleLayer.qaRoundSizeMultiplier = taper
            setting(AgentCharacterConfig.bubbleStyleKey, (name ?? "orb").hasPrefix("minimal-") ? "squircle" : "orb")
            canvas.setViewport(CanvasViewport(x: world.x - 70 / zoom, y: world.y - 70 / zoom, zoom: zoom))
            Check.pump(0.15)
            for view in views {
                view.qaRoundProviderMarkInPlate((name ?? "").hasPrefix("minimal-"))
                view.qaAgentBubble?.qaRoundStudy = name
                view.qaAgentBubble?.qaInside = inside
                view.needsLayout = true
                view.qaTitleBarView?.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.placeAgentBubble()
                view.qaAgentBubble?.layoutIfNeeded()
            }
            canvas.layoutSubtreeIfNeeded()
            Check.pump(0.15)
        }
        func mark(dark: Bool) -> CGImage? {
            guard let source = BrandMark96.mark(forModel: "anthropic/claude-haiku-4-5-20251001") else { return nil }
            let result = NSImage(size: NSSize(width: 128, height: 128))
            result.lockFocus()
            source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
            (dark ? NSColor.white : NSColor.black).setFill()
            NSRect(x: 0, y: 0, width: 128, height: 128).fill(using: .sourceIn)
            result.unlockFocus()
            return result.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        func appearance(_ name: NSAppearance.Name) {
            window.appearance = NSAppearance(named: name)
            Check.pump(0.2)
            let image = mark(dark: name == .darkAqua)
            for view in views { view.qaAgentBubble?.qaRoundMark = image }
        }
        setting(AgentCharacterConfig.sizeKey, "small")
        setting(SidebarActiveIndicatorStyle.defaultsKey, "classic")
        Check.pump(0.2)
        let themes: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
        if !clips {
            for (theme, app) in themes {
                appearance(app)
                // Treatments, idle, at 80% and 125%.
                for (name, inside) in [("today", nil), ("a", "a"), ("b", "b"), ("c", "c")] as [(String, String?)] {
                    for (zn, z) in [("80", 0.8), ("125", 1.25)] {
                        study(inside == nil ? nil : "orb-rim", inside: inside, zoom: z)
                        subject.qaAgentBubble?.setWorking(false, style: "classic", phase: 0)
                        Check.pump(0.1)
                        try Check.write(Check.capture(canvas, window, rect: rect), to: out.appendingPathComponent("inside-\(name)-\(theme)-\(zn).png"))
                    }
                }
                // Where the provider mark lives, and that it never moves.
                for style in ["orb-today", "minimal-circle", "minimal-square", "minimal-squircle"] {
                    study(style == "orb-today" ? nil : style, inside: nil, zoom: 1.25)
                    let bubble = subject.qaAgentBubble!
                    bubble.setWorking(false, style: "classic", phase: 0)
                    Check.pump(0.1)
                    try Check.write(Check.capture(canvas, window, rect: rect), to: out.appendingPathComponent("titlebar-\(style)-\(theme).png"))
                    if style == "orb-today" { continue }
                    bubble.setWorking(true, style: "classic", phase: 0)
                    var markRects = Set<String>(), plateMarks = Set<String>()
                    for step in 0..<24 {
                        bubble.qaSeekMotion(Double(step) * 0.25)
                        Check.pump(0.03)
                        markRects.insert(String(describing: subject.qaProviderMarkRect))
                        plateMarks.insert(String(describing: bubble.qaMarkFrame))
                    }
                    bubble.qaSeekMotion(nil)
                    try Check.expect(markRects.count == 1 && plateMarks.count == 1,
                                     "\(style) \(theme): the provider mark moved while working (\(markRects.count)/\(plateMarks.count))")
                    try Check.expect(subject.qaProviderMarkRect == nil, "\(style): mark beside the title is hidden (it lives in the plate)")
                    report.append("PASS \(style) \(theme): mark frame constant over 24 samples of a 6 s working run; animated layers: \(bubble.qaAnimationKeys)")
                }
            }
        } else {
            let inside = ProcessInfo.processInfo.environment["ARRAY_AGENT_ICON_ROUND_INSIDE"] ?? "b"
            let clipRect = NSRect(x: 30, y: 30, width: 120, height: 80)
            for (theme, app) in themes {
                appearance(app)
                for motion in ["orb-rim", "orb-breath", "orb-current"] {
                    study(motion, inside: inside, zoom: 1.25)
                    let bubble = subject.qaAgentBubble!
                    bubble.setWorking(true, style: "classic", phase: 0)
                    let dir = out.appendingPathComponent("\(motion)-\(theme)")
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    for frame in 0..<180 {
                        bubble.qaSeekMotion(Double(frame) / 30)
                        Check.pump(0.02)
                        try Check.write(Check.capture(canvas, window, rect: clipRect), to: dir.appendingPathComponent(String(format: "%03d.png", frame)))
                    }
                    bubble.qaSeekMotion(nil)
                    report.append("PASS \(motion) \(theme): 180 frames at 30 fps")
                }
            }
        }
        TileAgentBubbleLayer.qaRoundSizeMultiplier = 1
        let summary = (["PASS agent icon round 2 (\(clips ? "clips" : "inside"))"] + report).joined(separator: "\n")
        try summary.write(to: directory.appendingPathComponent(clips ? "clips-checks.txt" : "inside-checks.txt"), atomically: true, encoding: .utf8)
        return summary
    }

    // MARK: Round 3: a glass lens baked into the atlas once

    /// A copy of the atlas picture with every frame seen through a glass sphere
    /// centred on the character's body: the middle magnified, the edge
    /// compressed (source radius = r (a + (1 - a) r^2), a = 1 / centre magnification). Done once, off the render path, so
    /// a pose animation only steps through already-warped frames. `supersample`
    /// 1 samples nearest at the atlas's native scale; n > 1 samples n x n nearest
    /// points per pixel and box-averages them.
    static func warpedAtlas(_ sprite: AgentCharacterSpriteAtlas, magnification: Double, supersample: Int) -> CGImage? {
        let atlas = sprite.atlas
        let src = atlas.pixels
        var dst = src
        let radius = 0.63 * Double(sprite.typicalInkSide)
        let n = max(1, supersample)
        let a = 1 / magnification
        for frame in atlas.frames {
            let cx = Double(frame.x) + Double(sprite.bodyCentre.x)
            let cy = Double(frame.y) + Double(sprite.bodyCentre.y)
            let x0 = Int(cx - radius) - 1, x1 = Int(cx + radius) + 1
            let y0 = Int(cy - radius) - 1, y1 = Int(cy + radius) + 1
            for y in max(frame.y, y0)..<min(frame.y + frame.height, y1 + 1) {
                for x in max(frame.x, x0)..<min(frame.x + frame.width, x1 + 1) {
                    var acc = [Double](repeating: 0, count: 4)
                    for j in 0..<n {
                        for i in 0..<n {
                            let px = Double(x) + (Double(i) + 0.5) / Double(n)
                            let py = Double(y) + (Double(j) + 0.5) / Double(n)
                            var ox = px - cx, oy = py - cy
                            let rr = (ox * ox + oy * oy).squareRoot() / radius
                            if rr > 0, rr < 1 {
                                let k = a + (1 - a) * rr * rr
                                ox *= k; oy *= k
                            }
                            let sx = Int((cx + ox).rounded(.down)), sy = Int((cy + oy).rounded(.down))
                            guard sx >= frame.x, sx < frame.x + frame.width, sy >= frame.y, sy < frame.y + frame.height else { continue }
                            let at = (sy * atlas.width + sx) * 4
                            for c in 0..<4 { acc[c] += Double(src[at + c]) }
                        }
                    }
                    let out = (y * atlas.width + x) * 4
                    for c in 0..<4 { dst[out + c] = UInt8(min(255, (acc[c] / Double(n * n)).rounded())) }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(dst) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: atlas.width, height: atlas.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: atlas.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func renderLens(clip: Bool, canvas: CanvasNSView, window: NSWindow, defaults: UserDefaults,
                           views: [ManagedAgentTileNSView], directory: URL) throws -> String {
        typealias Check = TileAgentBubbleChecks
        let fm = FileManager.default
        let out = directory.appendingPathComponent(clip ? "lens-clip-frames" : "lens")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let subject = views[0]
        let world = canvas.allTilesInWorldFrames().first { $0.id == subject.tile.id }!.frame
        let rect = NSRect(x: 0, y: 0, width: 820, height: 460)
        var report: [String] = []
        func setting(_ key: String, _ value: Any) {
            defaults.set(value, forKey: key)
            SettingChangeEvent.post(SettingID(rawValue: key))
        }
        func study(inside: String?, zoom: Double) {
            let taper = min(1, CGFloat(zoom / 0.8).squareRoot())
            TileAgentBubbleLayer.qaRoundSizeMultiplier = taper
            setting(AgentCharacterConfig.bubbleStyleKey, "orb")
            canvas.setViewport(CanvasViewport(x: world.x - 70 / zoom, y: world.y - 70 / zoom, zoom: zoom))
            Check.pump(0.15)
            for view in views {
                view.qaAgentBubble?.qaRoundStudy = inside == nil ? nil : "orb-rim"
                view.qaAgentBubble?.qaInside = inside
                view.needsLayout = true
                view.qaTitleBarView?.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.placeAgentBubble()
                view.qaAgentBubble?.layoutIfNeeded()
            }
            canvas.layoutSubtreeIfNeeded()
            Check.pump(0.15)
        }
        var cache: [String: CGImage] = [:]
        var originals: [ObjectIdentifier: CGImage] = [:]
        func picture(_ view: ManagedAgentTileNSView, _ variant: String) -> CGImage? {
            guard let layer = view.qaAgentBubble?.sprite, let atlas = layer.sprite else { return nil }
            if originals[ObjectIdentifier(atlas)] == nil { originals[ObjectIdentifier(atlas)] = atlas.image }
            guard variant != "plain" else { return atlas.image }
            let key = "\(ObjectIdentifier(atlas).hashValue)-\(variant)"
            if let hit = cache[key] { return hit }
            let magnification = (Double(variant.dropFirst(1)) ?? 130) / 100
            let started = CACurrentMediaTime()
            let image = warpedAtlas(atlas, magnification: magnification, supersample: variant.hasPrefix("s") ? 3 : 1)
            report.append("bake \(variant): \(Int((CACurrentMediaTime() - started) * 1000)) ms once per atlas (\(atlas.atlas.width)x\(atlas.atlas.height))")
            if let image { cache[key] = image }
            return image
        }
        func apply(_ variant: String) throws {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for view in views {
                guard let image = picture(view, variant) else { throw Check.Failure(description: "no atlas for \(variant)") }
                view.qaAgentBubble?.sprite.contents = image
            }
            CATransaction.commit()
            Check.pump(0.1)
        }
        func mark(dark: Bool) -> CGImage? { nil }
        func appearance(_ name: NSAppearance.Name) {
            window.appearance = NSAppearance(named: name)
            Check.pump(0.2)
        }
        _ = mark
        setting(AgentCharacterConfig.sizeKey, "small")
        setting(SidebarActiveIndicatorStyle.defaultsKey, "classic")
        Check.pump(0.2)
        let themes: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
        if !clip {
            let variants: [(String, String?, String)] = [
                ("today", nil, "plain"), ("a", "a", "plain"),
                ("n125", "a", "n125"), ("n150", "a", "n150"), ("n190", "a", "n190"),
                ("s125", "a", "s125"), ("s150", "a", "s150"), ("s190", "a", "s190")]
            for (theme, app) in themes {
                appearance(app)
                for (name, inside, variant) in variants {
                    for (zn, z) in [("80", 0.8), ("125", 1.25)] {
                        study(inside: inside, zoom: z)
                        try apply(variant)
                        for view in views {
                            // Every variant shows the same still pose.
                            guard let sprite = view.qaAgentBubble?.sprite, let plan = sprite.plan, let atlas = sprite.sprite else { continue }
                            sprite.removeAnimation(forKey: CharacterSpriteLayer.animationKey)
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            sprite.contentsRect = sprite.rect(of: atlas.atlas.frameIndex(of: plan.still))
                            CATransaction.commit()
                        }
                        subject.qaAgentBubble?.setWorking(false, style: "classic", phase: 0)
                        Check.pump(0.1)
                        try Check.write(Check.capture(canvas, window, rect: rect), to: out.appendingPathComponent("lens-\(name)-\(theme)-\(zn).png"))
                    }
                }
                report.append("PASS stills \(theme)")
            }
        } else {
            let variant = ProcessInfo.processInfo.environment["ARRAY_AGENT_ICON_ROUND_VARIANT"] ?? "n150"
            let clipRect = NSRect(x: 30, y: 30, width: 120, height: 80)
            for (theme, app) in themes {
                appearance(app)
                study(inside: "a", zoom: 1.25)
                try apply(variant)
                let bubble = subject.qaAgentBubble!
                bubble.setWorking(true, style: "classic", phase: 0)
                let dir = out.appendingPathComponent(theme)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for frame in 0..<180 {
                    bubble.qaSeekMotion(Double(frame) / 30)
                    Check.pump(0.02)
                    try Check.write(Check.capture(canvas, window, rect: clipRect), to: dir.appendingPathComponent(String(format: "%03d.png", frame)))
                }
                bubble.qaSeekMotion(nil)
                report.append("PASS clip \(theme): 180 frames, variant \(variant)")
            }
        }
        TileAgentBubbleLayer.qaRoundSizeMultiplier = 1
        let summary = (["PASS agent icon round 3 (\(clip ? "clip" : "stills"))"] + report).joined(separator: "\n")
        try summary.write(to: directory.appendingPathComponent(clip ? "lens-clip-checks.txt" : "lens-checks.txt"), atomically: true, encoding: .utf8)
        return summary
    }
}
