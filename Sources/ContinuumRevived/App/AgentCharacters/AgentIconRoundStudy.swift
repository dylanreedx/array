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
}
