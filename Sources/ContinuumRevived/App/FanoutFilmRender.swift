import AppKit
import AVFoundation
import ContinuumRevivedCore
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Offline playback of FanoutLayoutProbe's recordings. No solver, agent process,
/// production store, or screen capture is involved: the pixels are real Array
/// note tiles and zone chrome, mounted through the isolated boot fixture.
@MainActor
enum FanoutFilmRender {
    private typealias Fixture = WorkspaceInvariantsFixture
    private static let width = 1600
    private static let height = 1000
    private static let captionHeight = 56.0

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // Kept local: the executable cannot import the CoreChecks target.
    private struct Run: Codable {
        var model: String
        var scenario: String
        var frames: [Frame]
        var metrics: [String: Double]
        var notes: [String]
    }

    private struct Frame: Codable {
        struct TileRecord: Codable {
            var id: UUID
            var name: String
            var kind: String
            var x, y, w, h: Double
            var parent: UUID?
            var worldFrame: TileFrame { TileFrame(x: x, y: y, width: w, height: h) }
        }
        var label: String
        var tiles: [TileRecord]
        var zone: [Double]
        var view: [Double]
        var active: UUID?
        var latch: String?
        var slot: [Double]?
        var pointer: [Double]?
    }

    static func run(arguments: [String]) throws -> URL {
        guard arguments.count == 2 else {
            throw Failure("usage: Array --fanout-film-render <runs dir> <out dir>")
        }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw Failure("no JSON runs in \(source.path)") }
        var names = Set<String>()
        let runs = try files.map { file -> Run in
            let run = try JSONDecoder().decode(Run.self, from: Data(contentsOf: file))
            try validate(run)
            guard names.insert("\(run.model)--\(run.scenario)").inserted else {
                throw Failure("duplicate model/scenario in \(file.lastPathComponent)")
            }
            return run
        }
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw Failure("WindowServer is unavailable; run this command outside the sandbox in a logged-in macOS session")
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let index = output.appendingPathComponent("index.txt")
        var entries = ["Array fanout films — 1600x1000, H.264, 30 fps; real note tiles; fixed camera per run."]
        try entries.joined(separator: "\n").appending("\n").write(to: index, atomically: true, encoding: .utf8)
        for run in runs {
            let directory = output.appendingPathComponent("\(run.model)--\(run.scenario)", isDirectory: true)
            print("Rendering \(directory.lastPathComponent) (\(run.frames.count) recorded frames)")
            fflush(stdout)
            do {
                let produced = try render(run, into: directory)
                entries.append(contentsOf: produced.map { "\(directory.lastPathComponent)/\($0)" })
                try entries.joined(separator: "\n").appending("\n").write(to: index, atomically: true, encoding: .utf8)
            } catch {
                entries.append("FAILED \(directory.lastPathComponent): \(error)")
                try? entries.joined(separator: "\n").appending("\n").write(to: index, atomically: true, encoding: .utf8)
                throw error
            }
        }
        return index
    }

    private static func validate(_ run: Run) throws {
        for component in [run.model, run.scenario] {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"),
                  !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw Failure("invalid model/scenario directory component")
            }
        }
        guard !run.frames.isEmpty else { throw Failure("\(run.model)/\(run.scenario): empty run") }
        func validRect(_ values: [Double]) -> Bool {
            values.count == 4 && values.allSatisfy(\.isFinite) && values[2] > 0 && values[3] > 0
        }
        for frame in run.frames {
            guard validRect(frame.zone), validRect(frame.view),
                  frame.slot.map(validRect) ?? true,
                  frame.pointer.map({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) ?? true,
                  frame.tiles.allSatisfy({ validRect([$0.x, $0.y, $0.w, $0.h]) }),
                  Set(frame.tiles.map(\.id)).count == frame.tiles.count else {
                throw Failure("\(run.model)/\(run.scenario), \(frame.label): invalid geometry or duplicate tile IDs")
            }
        }
    }

    private static func rect(_ values: [Double]) -> CGRect {
        CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func render(_ run: Run, into directory: URL) throws -> [String] {
        let fixture = try Fixture(label: "fanout-film")
        // Set before NSApplication/AppDelegate initialization, and keep it set
        // through fixture teardown (which flushes the isolated project stores).
        let previousSupport = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]
        setenv("CONTINUUM_APP_SUPPORT", fixture.appSupport.path, 1)
        defer {
            fixture.dispose()
            if let previousSupport { setenv("CONTINUUM_APP_SUPPORT", previousSupport, 1) }
            else { unsetenv("CONTINUUM_APP_SUPPORT") }
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let union = run.frames.map { rect($0.zone) }.reduce(CGRect.null) { $0.union($1) }
        // Six percent on each side, with a separate screen-space caption band.
        let fit = union.insetBy(dx: -union.width * 0.06, dy: -union.height * 0.06)
        let visibleHeight = Double(height) - captionHeight
        let zoom = min(Double(width) / fit.width, visibleHeight / fit.height)
        let camera = CanvasViewport(x: fit.midX - Double(width) / zoom / 2,
                                    y: fit.midY - visibleHeight / zoom / 2, zoom: zoom)
        var zone = ZonePlacement(
            zoneId: Fixture.zoneA1, projectId: Fixture.projectA1,
            origin: ZonePoint(x: union.minX, y: union.minY),
            size: ZoneSize(width: union.width, height: union.height),
            color: "blue", collapsed: false, hydrationPolicy: .automatic,
            autoLayoutMode: .disabled, name: run.scenario)
        let store = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try store.load()
        document.zones = [zone]
        document.viewport = camera
        document.lastActiveZoneId = zone.zoneId
        try store.save(document)

        // Hydrate each ID once, then hide IDs absent from the recorded frame.
        // This avoids the spawn path's zone growth and any repeated text stacks.
        var records: [UUID: Frame.TileRecord] = [:]
        var ordered: [Frame.TileRecord] = []
        for frame in run.frames {
            for tile in frame.tiles where records[tile.id] == nil {
                records[tile.id] = tile
                ordered.append(tile)
            }
        }
        let project = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        let tiles = try ordered.enumerated().map { rank, record -> Tile in
            var metadata = TileMetadata(noteId: record.id)
            metadata.markdownDocumentMode = .edit
            var tile = Tile(id: record.id, kind: .note, title: record.name, frame: record.worldFrame,
                            zPosition: .fromLegacyRank(rank + 1), runtimeRef: nil, metadata: metadata)
            tile.zoneId = zone.zoneId
            try project.saveNoteBody(id: record.id, text: record.name)
            return tile
        }
        try project.saveCanvas(CanvasState(viewport: camera, tiles: tiles, groups: [], lastActiveTileId: nil))
        // A volatile, named suite: never write the user's auto-layout defaults.
        let suite = "fanout-film-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("cannot create fixture defaults") }
        // A named suite's reads never consult volatile domains, so write the
        // suite itself (as TileInsertSlideChecks.pin does) and remove it after.
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        defaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        fixture.configureMount = { delegate, _ in
            guard let canvas = delegate.canvasView else { return }
            canvas.autoLayoutDefaults = defaults
            canvas.dragMagnetizeDefaults = defaults
            canvas.breakoutDefaults = defaults
            canvas.autoLayoutReduceMotionProvider = { true }
            canvas.surfaceResidencyEnabled = false
        }
        try fixture.mount()
        let canvas = try fixture.requireMounted("fanout film").canvas
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.appearance = NSAppearance(named: .darkAqua)
        let window = ZoneTruthChecks.hostInWindow(canvas)
        defer { window.orderOut(nil); window.contentView = nil }
        guard !window.isKeyWindow, !window.isMainWindow else { throw Failure("fixture window took focus") }
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            throw Failure("fixture window \(window.frame) is on a screen \(NSScreen.screens.map(\.frame))")
        }
        guard !canvas.isAutoLayoutEnabled else { throw Failure("fixture canvas has auto layout on") }
        canvas.setViewport(camera)
        var views: [UUID: NoteTileNSView] = [:]
        for record in ordered {
            guard let view = canvas.tileView(for: record.id) as? NoteTileNSView else {
                throw Failure("fixture failed to hydrate note \(record.name)")
            }
            view.textView.font = NSFont.systemFont(ofSize: min(120, max(40, 24 / zoom)), weight: .semibold)
            view.textView.textContainerInset = NSSize(width: 24, height: 24)
            view.textView.isEditable = false
            view.textView.isSelectable = false
            views[record.id] = view
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = try Movie(url: directory.appendingPathComponent("film.mp4"))
        defer { movie.cancelIfUnfinished() }
        let keys = keyIndices(run.frames)
        var keyImages: [Int: CGImage] = [:]
        for (index, frame) in run.frames.enumerated() {
            try autoreleasepool {
                zone.origin = ZonePoint(x: frame.zone[0], y: frame.zone[1])
                zone.size = ZoneSize(width: frame.zone[2], height: frame.zone[3])
                canvas.setZonePlacement(zone)
                let present = Set(frame.tiles.map(\.id))
                for tile in frame.tiles where views[tile.id]?.textView.string != tile.name {
                    views[tile.id]?.textView.string = tile.name
                }
                let frames = Dictionary(uniqueKeysWithValues: frame.tiles.map { ($0.id, $0.worldFrame) })
                guard canvas.applySelectionFrames(frames) else { throw Failure("cannot apply \(frame.label)") }
                canvas.layoutSubtreeIfNeeded()
                // Layer layout restores collapsed-state visibility, so apply
                // recording visibility after every geometry/layout pass.
                for (id, view) in views { view.isHidden = !present.contains(id) }
                guard canvas.qaZoneDrawnWorldBounds(for: zone.zoneId) == CanvasEngine.zoneWorldFrame(zone),
                      canvas.viewport == camera else {
                    throw Failure("\(frame.label): zone geometry or fixed camera changed")
                }
                guard canvas.viewport == camera, canvas.zonePlacement(for: zone.zoneId) == zone else {
                    throw Failure("\(frame.label): camera or zone changed during replay")
                }
                // Verify the rendered geometry, not just the zone stamps. This
                // also catches a future accidental solver/camera intervention.
                for tile in frame.tiles {
                    guard let view = views[tile.id] else { throw Failure("missing tile view") }
                    let shown = view.convert(view.bounds, to: canvas)
                    let expected = CanvasEngine.tileScreenFrame(tile.worldFrame, viewport: camera)
                    guard abs(shown.minX - expected.minX) < 0.1, abs(shown.minY - expected.minY) < 0.1,
                          abs(shown.width - expected.width) < 0.1, abs(shown.height - expected.height) < 0.1 else {
                        throw Failure("\(frame.label): rendered world frame differs for \(tile.name)")
                    }
                }
                let image = try capture(canvas, run: run, frame: frame, camera: camera)
                if keys.contains(index) { keyImages[index] = image }
                let hold = index == 0 ? 15 : frame.label == "drop" ? 45 : frame.label.hasPrefix("spawn ") ? 18 : 1
                try movie.append(image, count: hold)
            }
        }
        try movie.finish()
        var produced = ["film.mp4 (\(movie.frameCount) frames, \(String(format: "%.2f", Double(movie.frameCount) / 30)) seconds)"]
        let strip = try context(width: 480 * keys.count, height: 300)
        for (position, index) in keys.enumerated() {
            guard let image = keyImages[index] else { throw Failure("missing key frame \(index)") }
            let label = run.frames[index].label
            let safeLabel = String(label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" ? $0 : "-" })
            let name = String(format: "key-%02d-", position + 1) + safeLabel + ".png"
            try writePNG(image, to: directory.appendingPathComponent(name))
            produced.append(name)
            strip.draw(image, in: CGRect(x: position * 480, y: 0, width: 480, height: 300))
            strip.setFillColor(CGColor(gray: 0.04, alpha: 1))
            strip.fill(CGRect(x: position * 480, y: 0, width: 480, height: 28))
            drawText(label, at: CGPoint(x: position * 480 + 12, y: 8), size: 14, maxWidth: 456, in: strip)
        }
        guard let stripImage = strip.makeImage() else { throw Failure("cannot create strip") }
        try writePNG(stripImage, to: directory.appendingPathComponent("strip.png"))
        produced.append("strip.png")
        print("Wrote \(directory.path): \(movie.frameCount) video frames, \(keys.count) key PNGs and strip.png")
        return produced
    }

    private static func keyIndices(_ frames: [Frame]) -> [Int] {
        let spawn = frames.lastIndex { $0.label.hasPrefix("spawn ") } ?? 0
        let drag = frames.indices.filter { frames[$0].label.hasPrefix("drag ") }
        let samples = (0..<4).map { step in
            drag.isEmpty ? spawn : drag[Int((Double(step) * Double(drag.count - 1) / 3).rounded())]
        }
        return [spawn] + samples + [frames.lastIndex { $0.label == "drop" } ?? frames.count - 1]
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("cannot allocate \(width)x\(height) image")
        }
        context.interpolationQuality = .high
        return context
    }

    private static func capture(_ canvas: CanvasNSView, run: Run, frame: Frame, camera: CanvasViewport) throws -> CGImage {
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw Failure("AppKit cannot allocate canvas backing image (WindowServer unavailable?)")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard let captured = bitmap.cgImage else { throw Failure("AppKit returned no canvas pixels") }
        let cg = try context(width: width, height: height)
        cg.draw(captured, in: CGRect(x: 0, y: 0, width: width, height: height))
        // AppKit's canvas is flipped; this bitmap context is bottom-left based.
        func screenRect(_ world: TileFrame) -> CGRect {
            let r = CanvasEngine.tileScreenFrame(world, viewport: camera)
            return CGRect(x: r.minX, y: Double(height) - r.maxY, width: r.width, height: r.height)
        }
        let tiles = Dictionary(uniqueKeysWithValues: frame.tiles.map { ($0.id, $0) })
        cg.setStrokeColor(CGColor(red: 0.62, green: 0.77, blue: 0.92, alpha: 0.65))
        cg.setLineWidth(1)
        for tile in frame.tiles {
            guard let parentID = tile.parent, let parent = tiles[parentID] else { continue }
            let a = screenRect(tile.worldFrame), b = screenRect(parent.worldFrame)
            cg.move(to: CGPoint(x: a.midX, y: a.midY))
            cg.addLine(to: CGPoint(x: b.midX, y: b.midY))
            cg.strokePath()
        }
        let accent = CGColor(red: 0.25, green: 0.75, blue: 1, alpha: 1)
        cg.setStrokeColor(accent)
        cg.setLineWidth(2)
        if let active = frame.active, let tile = tiles[active] {
            cg.stroke(screenRect(tile.worldFrame).insetBy(dx: -1, dy: -1))
        }
        if let slot = frame.slot {
            let r = screenRect(TileFrame(x: slot[0], y: slot[1], width: slot[2], height: slot[3]))
            cg.setLineDash(phase: 0, lengths: [7, 5])
            cg.stroke(r)
            cg.setLineDash(phase: 0, lengths: [])
        }
        if let pointer = frame.pointer {
            let p = CGPoint(x: (pointer[0] - camera.x) * camera.zoom,
                            y: Double(height) - (pointer[1] - camera.y) * camera.zoom)
            cg.setFillColor(accent)
            cg.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
            cg.setLineWidth(1)
            cg.strokeEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
        cg.setFillColor(CGColor(gray: 0.035, alpha: 0.96))
        cg.fill(CGRect(x: 0, y: 0, width: Double(width), height: captionHeight))
        drawText("\(run.model) · \(run.scenario) · \(frame.label) · latch: \(frame.latch ?? "-")",
                 at: CGPoint(x: 24, y: 19), size: 22, maxWidth: Double(width - 48), in: cg)
        guard let image = cg.makeImage() else { throw Failure("cannot create composited frame") }
        return image
    }

    private static func drawText(_ text: String, at point: CGPoint, size: Double, maxWidth: Double, in cg: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, maxWidth, .end, token) ?? line
        cg.saveGState()
        cg.textMatrix = .identity
        cg.textPosition = point
        CTLineDraw(fitted, cg)
        cg.restoreGState()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finish \(url.path)") }
    }

    /// Stream frames into AVFoundation, retaining only one input pixel buffer
    /// plus the six key images. Bounded waits turn codec/service failure into an
    /// actionable error instead of a hung render process.
    @MainActor
    private final class Movie {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private(set) var frameCount = 0

        init(url: URL) throws {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
            guard writer.canAdd(input) else { throw Failure("AVFoundation cannot add H.264 input") }
            writer.add(input)
            guard writer.startWriting() else { throw Failure("AVFoundation start failed: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
        }

        func append(_ image: CGImage, count: Int) throws {
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw Failure("AVFoundation cannot allocate H.264 pixel buffer: \(String(describing: writer.error))")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw Failure("cannot draw video buffer")
            }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<count {
                let deadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, Date() < deadline else {
                        throw Failure("AVFoundation H.264 encoder unavailable or stalled: \(String(describing: writer.error))")
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frameCount), timescale: 30)) else {
                    throw Failure("AVFoundation append failed: \(String(describing: writer.error))")
                }
                frameCount += 1
            }
        }

        func finish() throws {
            writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: 30))
            input.markAsFinished()
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
                throw Failure("AVFoundation finish failed or timed out: \(String(describing: writer.error))")
            }
        }

        func cancelIfUnfinished() {
            if writer.status == .writing { writer.cancelWriting() }
        }
    }
}
