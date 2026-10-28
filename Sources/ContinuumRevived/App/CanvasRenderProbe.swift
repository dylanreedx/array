import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import CoreText
import IOSurface
import QuartzCore

/// `--canvas-render-probe` (`.plans/84`, inventory round 1, step 5): can tile text be
/// drawn at the exact zoom scale on every frame without AppKit views inside tiles?
///
/// A replayed workspace (`CANVAS_MOTION_REPLAY`) is laid out ONCE with CoreText at
/// world size; each display-link frame rasterizes only the on-screen part of each
/// visible tile at `zoom × backing` on a concurrent queue and hands the bitmaps to
/// plain layers under one layer-hosting view (no subviews). No pictures are scaled:
/// every frame is drawn at the scale it is shown at. Prints per-frame timings and
/// writes `CANVAS_RENDER_OUTPUT` JSON; PNGs of mid-zoom frames go beside it.
@MainActor
final class CanvasRenderProbe: NSObject {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// One tile's text, laid out once in world points.
    final class TileText: @unchecked Sendable {
        let frame: CGRect                      // world
        let title: String
        let lines: [(line: CTLine, origin: CGPoint)]  // tile-local, y down from tile top
        let contentHeight: CGFloat
        static let header: CGFloat = 34
        static let padding: CGFloat = 14

        init(frame: CGRect, title: String, text: NSAttributedString) {
            self.frame = frame
            self.title = title
            let width = max(40, frame.width - 2 * Self.padding)
            let setter = CTFramesetterCreateWithAttributedString(text)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: text.length), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let height = ceil(size.height) + 4
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
            let ctFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            let ctLines = CTFrameGetLines(ctFrame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: ctLines.count)
            CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)
            // Scrolled to the bottom, as a transcript sits: the last lines fill the body.
            let body = frame.height - Self.header - Self.padding
            let shift = max(0, height - body)
            var kept: [(CTLine, CGPoint)] = []
            for (line, origin) in zip(ctLines, origins) {
                let yDown = height - origin.y - shift          // baseline, from body top
                guard yDown > -20, yDown < body + 20 else { continue }
                kept.append((line, CGPoint(x: Self.padding + origin.x, y: Self.header + yDown)))
            }
            lines = kept
            contentHeight = height
        }

        /// Draw the part of the tile at `visible` (tile-local points) at `scale` px/pt.
        func render(visible: CGRect, scale: CGFloat, dark: Bool) -> CGImage? {
            let pixelW = Int(ceil(visible.width * scale)), pixelH = Int(ceil(visible.height * scale))
            guard pixelW > 0, pixelH > 0, pixelW * pixelH < 40_000_000,
                  let context = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            draw(into: context, pixelHeight: pixelH, visible: visible, scale: scale, dark: dark)
            return context.makeImage()
        }

        /// Draw into an IOSurface the compositor reads directly: no copy at commit.
        func render(into surface: IOSurface, visible: CGRect, scale: CGFloat, dark: Bool) -> (Int, Int)? {
            let pixelW = Int(ceil(visible.width * scale)), pixelH = Int(ceil(visible.height * scale))
            guard pixelW > 0, pixelH > 0, pixelW <= surface.width, pixelH <= surface.height else { return nil }
            surface.lock(options: [], seed: nil)
            defer { surface.unlock(options: [], seed: nil) }
            guard let context = CGContext(data: surface.baseAddress, width: pixelW, height: pixelH, bitsPerComponent: 8,
                                          bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            draw(into: context, pixelHeight: pixelH, visible: visible, scale: scale, dark: dark)
            return (pixelW, pixelH)
        }

        private func draw(into context: CGContext, pixelHeight pixelH: Int, visible: CGRect, scale: CGFloat, dark: Bool) {
            context.clear(CGRect(x: 0, y: 0, width: context.width, height: pixelH))
            // Flip to y-down tile space, then move the visible rect to the origin.
            context.translateBy(x: 0, y: CGFloat(pixelH))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -visible.minX, y: -visible.minY)
            let bounds = CGRect(origin: .zero, size: frame.size)
            context.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.98, alpha: 1))
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
            context.setStrokeColor(CGColor(gray: dark ? 0.3 : 0.8, alpha: 1))
            context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
            context.setFillColor(CGColor(gray: dark ? 0.18 : 0.94, alpha: 1))
            context.fill(CGRect(x: 1, y: 1, width: frame.width - 2, height: Self.header - 1))
            context.clip(to: CGRect(x: 0, y: Self.header, width: frame.width, height: frame.height - Self.header))
            // CoreText draws y-up: flip each line about its own baseline.
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for (line, origin) in lines where origin.y > visible.minY - 30 && origin.y < visible.maxY + 30 {
                context.textPosition = origin
                CTLineDraw(line, context)
            }
            context.resetClip()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: Self.padding, y: 22)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: TextToken.textPrimary.color.nsColor(for: dark ? .dark : .light)])), context)
        }
    }

    private let tiles: [TileText]
    private let layers: [CALayer]
    /// Three surfaces per tile, so the one being drawn is never the one shown.
    private var surfaces: [[IOSurface]] = []
    private var frameIndex = 0
    private let useSurfaces = ProcessInfo.processInfo.environment["CANVAS_RENDER_IMAGES"] != "1"

    private static func makeSurface(width: Int, height: Int) -> IOSurface? {
        let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                             .pixelFormat: 0x42475241 /* 'BGRA' */])
        if let surface, let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
        }
        return surface
    }
    private let window: NSWindow
    private let host: NSView
    private let start: CanvasViewport
    private let dark: Bool
    private var link: CADisplayLink?
    private var t0: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    private var frames: [[String: Double]] = []
    private var snapshots: [(zoom: Double, image: CGImage)] = []
    private let duration: Double
    private let output: URL?
    private var finished: (() -> Void)?

    static func run() throws {
        let env = ProcessInfo.processInfo.environment
        guard let specPath = env["CANVAS_MOTION_REPLAY"] else {
            throw Failure(description: "--canvas-render-probe needs CANVAS_MOTION_REPLAY=<spec.json>")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("render-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let replay = try CanvasMotionReplay.load(spec: URL(fileURLWithPath: specPath), root: scratch, projectID: UUID())
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let probe = try CanvasRenderProbe(replay: replay, output: env["CANVAS_RENDER_OUTPUT"].map(URL.init(fileURLWithPath:)),
                                          duration: Double(env["CANVAS_RENDER_SECONDS"] ?? "") ?? 6)
        probe.finished = { app.stop(nil); app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true) }
        probe.begin()
        app.run()
    }

    init(replay: CanvasMotionReplay, output: URL?, duration: Double) throws {
        self.output = output
        self.duration = duration
        start = replay.document.viewport
        dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme: TokenTheme = dark ? .dark : .light
        let prose: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme)]
        let user: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme)]
        let code: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: TextToken.textSecondary.color.nsColor(for: theme)]
        var built: [TileText] = []
        for tile in replay.tiles {
            let text = NSMutableAttributedString()
            if let agent = replay.agents[tile.id], let history = agent.rehydrate() {
                for step in history.steps {
                    switch step {
                    case .userPrompt(let prompt):
                        text.append(NSAttributedString(string: "\n" + prompt + "\n\n", attributes: user))
                    case .event(.contentDelta(_, _, let kind, let delta)):
                        text.append(NSAttributedString(string: delta, attributes: kind == .assistant ? prose : code))
                    case .event(.itemStarted(_, _, _, let title)):
                        text.append(NSAttributedString(string: "\n▸ " + (title ?? "tool") + "\n", attributes: code))
                    default: break
                    }
                }
            } else if let path = tile.metadata.filePath, let body = try? String(contentsOfFile: path, encoding: .utf8) {
                text.append(NSAttributedString(string: body, attributes: prose))
            }
            let world = CGRect(x: tile.frame.x, y: tile.frame.y, width: tile.frame.width, height: tile.frame.height)
            built.append(TileText(frame: world, title: tile.title ?? "", text: text))
        }
        tiles = built
        let size = replay.window ?? NSSize(width: 1400, height: 900)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Array — canvas render probe"
        window.isReleasedWhenClosed = false
        // Layer-HOSTING: we own the layer tree and the view has no subviews.
        host = NSView(frame: NSRect(origin: .zero, size: size))
        let root = CALayer()
        root.backgroundColor = CGColor(gray: dark ? 0.08 : 0.9, alpha: 1)
        root.isGeometryFlipped = true
        host.layer = root
        host.wantsLayer = true
        layers = built.map { _ in
            let layer = CALayer()
            layer.contentsGravity = .resize
            layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            root.addSublayer(layer)
            return layer
        }
        window.contentView = host
        super.init()
    }

    private func begin() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let link = host.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Zoom 0.3 → 1.2 → 0.3 (geometric) about the start camera's screen centre.
    private func viewport(at t: Double) -> CanvasViewport {
        let phase = min(1, max(0, t / duration))
        let s = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let zoom = 0.3 * pow(4, s)
        let size = host.bounds.size
        let centre = CGPoint(x: start.x + size.width / 2 / start.zoom, y: start.y + size.height / 2 / start.zoom)
        return CanvasViewport(x: centre.x - size.width / 2 / zoom, y: centre.y - size.height / 2 / zoom, zoom: zoom)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let mainStart = CACurrentMediaTime()
        if t0 == 0 { t0 = link.timestamp }
        let t = link.timestamp - t0
        if t > duration + 0.5 { finish(); return }
        let camera = viewport(at: t)
        let scale = (window.backingScaleFactor) * camera.zoom
        let screen = CGRect(origin: .zero, size: host.bounds.size)
        // Which tiles are on screen, and which part of each.
        var jobs: [(index: Int, visible: CGRect, screenRect: CGRect)] = []
        for (index, tile) in tiles.enumerated() {
            let rect = CGRect(x: (tile.frame.minX - camera.x) * camera.zoom, y: (tile.frame.minY - camera.y) * camera.zoom,
                              width: tile.frame.width * camera.zoom, height: tile.frame.height * camera.zoom)
            let onScreen = rect.intersection(screen)
            guard !onScreen.isNull, onScreen.width > 0.5, onScreen.height > 0.5 else { continue }
            let visible = CGRect(x: (onScreen.minX - rect.minX) / camera.zoom, y: (onScreen.minY - rect.minY) / camera.zoom,
                                 width: onScreen.width / camera.zoom, height: onScreen.height / camera.zoom)
            jobs.append((index, visible, onScreen))
        }
        let rasterStart = CACurrentMediaTime()
        var images = [CGImage?](repeating: nil, count: jobs.count)
        var drawn = [(Int, Int)?](repeating: nil, count: jobs.count)
        let tilesRef = tiles, dark = self.dark
        frameIndex += 1
        var targets: [IOSurface?] = []
        if useSurfaces {
            if surfaces.isEmpty { surfaces = tiles.map { _ in [] } }
            for job in jobs {
                let w = Int(ceil(job.visible.width * scale)), h = Int(ceil(job.visible.height * scale))
                var pool = surfaces[job.index]
                if pool.count < 3 || pool[0].width < w || pool[0].height < h {
                    // Grow in 25% steps so a zoom-in does not reallocate every frame.
                    let cw = max(w, Int(Double(pool.first?.width ?? 0))) * 5 / 4 + 16
                    let ch = max(h, Int(Double(pool.first?.height ?? 0))) * 5 / 4 + 16
                    pool = (0..<3).compactMap { _ in Self.makeSurface(width: cw, height: ch) }
                    surfaces[job.index] = pool
                }
                targets.append(pool.isEmpty ? nil : pool[frameIndex % pool.count])
            }
        }
        let useSurfaces = self.useSurfaces
        images.withUnsafeMutableBufferPointer { imageBuffer in
            drawn.withUnsafeMutableBufferPointer { drawnBuffer in
                let out = imageBuffer, sizes = drawnBuffer
                DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                    if useSurfaces, let target = targets[i] {
                        sizes[i] = tilesRef[jobs[i].index].render(into: target, visible: jobs[i].visible,
                                                                  scale: CGFloat(scale), dark: dark)
                    } else {
                        out[i] = tilesRef[jobs[i].index].render(visible: jobs[i].visible, scale: CGFloat(scale), dark: dark)
                    }
                }
            }
        }
        let rasterMs = (CACurrentMediaTime() - rasterStart) * 1_000
        let commitStart = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shown = Set(jobs.map(\.index))
        for (i, job) in jobs.enumerated() {
            let layer = layers[job.index]
            layer.isHidden = false
            layer.frame = job.screenRect
            if useSurfaces, let target = targets[i], let (w, h) = drawn[i] {
                layer.contents = target
                layer.contentsRect = CGRect(x: 0, y: 0, width: CGFloat(w) / CGFloat(target.width),
                                            height: CGFloat(h) / CGFloat(target.height))
            } else {
                layer.contents = images[i]
            }
        }
        for (index, layer) in layers.enumerated() where !shown.contains(index) { layer.isHidden = true }
        CATransaction.commit()
        CATransaction.flush()
        let commitMs = (CACurrentMediaTime() - commitStart) * 1_000
        let mainMs = (CACurrentMediaTime() - mainStart) * 1_000
        let interval = lastTimestamp.map { (link.timestamp - $0) * 1_000 } ?? 0
        lastTimestamp = link.timestamp
        let pixels = jobs.reduce(0.0) { $0 + Double($1.visible.width * $1.visible.height) * scale * scale }
        frames.append(["t": t, "zoom": camera.zoom, "tiles": Double(jobs.count), "rasterMs": rasterMs, "commitMs": commitMs,
                       "mainMs": mainMs, "intervalMs": interval, "megapixels": pixels / 1e6])
        // Mid-gesture witnesses: the whole window as drawn at three zooms.
        if snapshots.count < 3, [0.25, 0.5, 0.75].contains(where: { abs(t / duration - $0) < 0.004 }),
           let biggest = jobs.indices.max(by: { jobs[$0].screenRect.width < jobs[$1].screenRect.width }),
           let image = images[biggest] ?? (targets.indices.contains(biggest) ? targets[biggest].flatMap({ surface in
               drawn[biggest].flatMap { Self.image(of: surface, width: $0.0, height: $0.1) } }) : nil) {
            snapshots.append((camera.zoom, image))
        }
    }

    private static func image(of surface: IOSurface, width: Int, height: Int) -> CGImage? {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        return CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
            .makeImage()
    }

    private func finish() {
        link?.invalidate()
        link = nil
        func pct(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let body = frames.dropFirst()
        let commit = body.map { $0["commitMs"]! }
        let raster = body.map { $0["rasterMs"]! }, main = body.map { $0["mainMs"]! }, interval = body.map { $0["intervalMs"]! }
        let summary: [String: Any] = [
            "frames": body.count, "seconds": duration,
            "framesPerSecond": Double(body.count) / duration,
            "rasterMs": ["p50": pct(raster, 0.5), "p95": pct(raster, 0.95), "max": raster.max() ?? 0],
            "commitMs": ["p50": pct(commit, 0.5), "p95": pct(commit, 0.95), "max": commit.max() ?? 0],
            "surfaces": useSurfaces,
            "mainMs": ["p50": pct(main, 0.5), "p95": pct(main, 0.95), "max": main.max() ?? 0],
            "intervalMs": ["p50": pct(interval, 0.5), "p95": pct(interval, 0.95), "max": interval.max() ?? 0],
            "intervalsOver12ms": interval.filter { $0 > 12 }.count,
            "intervalsOver25ms": interval.filter { $0 > 25 }.count,
            "tilesLaidOut": tiles.count, "linesLaidOut": tiles.reduce(0) { $0 + $1.lines.count },
            "maxTilesOnScreen": body.map { $0["tiles"]! }.max() ?? 0,
            "maxMegapixels": body.map { $0["megapixels"]! }.max() ?? 0,
            "backingScale": window.backingScaleFactor,
        ]
        print("render probe:", summary)
        if let output {
            let data = try? JSONSerialization.data(withJSONObject: ["summary": summary, "frames": frames], options: [.prettyPrinted])
            try? data?.write(to: output)
            for (i, shot) in snapshots.enumerated() {
                let url = output.deletingPathExtension().appendingPathExtension("mid-\(i)-zoom-\(String(format: "%.2f", shot.zoom)).png")
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, shot.image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
        }
        window.orderOut(nil)
        finished?()
    }
}
