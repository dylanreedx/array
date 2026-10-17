// Film harness: per-frame capture of the app's OWN window, in lock-step with the
// director. ScreenCaptureKit's desktop-independent window filter sees Ghostty (Metal)
// and WebKit (remote layers) pixels, works while the window is parked off-screen and
// never key, and needs no Screen Recording grant for the calling process's own window
// (witnessed by the 2026-10-04 spike). Each take writes a PNG sequence (policy), a
// ProRes or H.264 movie encoded in-process, and `frames.json`.
//
// `frames.json`, schema `array.film.frames.v2` (v1 plus the pointer track and geometry):
//
//   top level   schema, scene, take, takeIndex, fps, count, verdict, video, blankFrames,
//               pixelSize [w, h] (PNG/movie pixels: 2x points on a Retina capture),
//               pointSize [w, h] (window points: the space of every coordinate below),
//               marks {name: frame},
//               events [{frame, type}], type one of press | release | click | dragStart
//                 | drop | panStart | panEnd | zoomStart | zoomEnd | revealStart | revealEnd
//                 | panelOpen | panelClose (Settings) | sound,
//                 in firing order
//                 (a click logs press at its first frame, then release + click 5 later);
//   per frame   i, t, png, viewport {x, y, zoom}, actions, digest, and
//               pointer {x, y, down, mode}: the scripted pointer AFTER the frame's
//                 actions, TOP-LEFT window points (rounded to 0.01), every frame; until a
//                 scene first moves it, it waits off-window at (pointSize.w + 60,
//                 pointSize.h * 0.7). mode is arrow | hand | grab | pinch | scroll;
//               rects {"<tileKey>": [x, y, w, h], "card:<cardKey>": [...], "sidebar": [...]
//                 (the whole workspace sidebar, when the scene shows it),
//                 "sidebar:<agentTileKey>": [...] (that agent's row cell),
//                 "zone:<zoneKey>": [...] (live placement through the camera),
//                 "window:<label>": [...] (a visible child window of the app's own:
//                 "picker" for the home-folder picker, "settings" for Settings, else its
//                 class), "hoverCard" (the sidebar row hover card), "nudge:<agentKey>"
//                 (that row's "Close" settle nudge), "settings:<target>" (a Settings
//                 control a pointer targets), "bulk" / "bulk:menu" / "bulk:<action>" (the
//                 multi-select bar, its actions button, a row of its open list), "toast"
//                 (the sidebar's undo toast)}: TOP-LEFT
//                 window points rounded to 0.1, measured from the live views through the
//                 view tree (a carried card reports its lifted copy), listed only when
//                 the rect intersects the window. Rects are unclipped. Tiles and agents
//                 a take adopts or opens appear under their keys.
//   keys        [{frame, label, kind, text?}]: the key-cap track. kind press (label
//                 "⌘K", "Return", "⌥A"), holdStart / holdEnd (label "⌥"), type (label the
//                 characters typed on that frame, text everything typed so far).
//   sounds      [{frame, sound, kind}]: a sound production asked to play (kind preview: a
//                 Settings Preview button; signal: a completion/push/merge sound), by its
//                 AgentSoundReference ("orbit", "prism"). Never played in a film: the edit
//                 places it. Each also logs an event "sound".
//   menus       [{frame, kind, anchor [x, y], title?, items?, path?}]: a menu production
//                 built (kind open: its title and items [{title, enabled, on, submenu?} |
//                 {separator}] at anchor, top-left window points), then choose (path of
//                 titles) or dismiss. Menus are never on screen in a film; the overlay
//                 draws them.
//
// Pixels: the desktop-independent window filter captures the window together with its
// attached child windows (witnessed 2026-10-05: the home-folder picker panel lands in
// the frame at its real offset and scale), so a popover's pixels are real with no
// compositing. A per-child filter is NOT a substitute: it returns the whole window
// group scaled into the child's size.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import AVFoundation
import ContinuumRevivedCore
import CoreVideo
import CryptoKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// How a take is captured. Full (the default): the window's native scale (2x on
/// Retina), every frame, the scene's PNG policy and its movie. Proto
/// (`scripts/film-capture.sh --proto`, `ARRAY_FILM_PROTO=1`): 1x, 30 fps (every
/// other frame of a 60 fps scene), JPEG, no movie: fast iteration, never the edit.
/// `ARRAY_FILM_FRAMES=A-B` captures only scene frames A...B of each captured take,
/// and the run stops after the last one. Frames keep their scene index (`i`, file
/// name) in both modes, so a proto frame lines up with the full take's.
/// A proto `frames.json` lists the events, keys, menus and sounds of the frames it
/// captured only.
struct FilmCaptureMode {
    var proto: Bool
    var range: ClosedRange<Int>?
    /// Scene frames per captured frame: 1, or sceneFps / 30 in proto.
    var stride: Int

    static func fromEnvironment(sceneFps: Int,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws -> FilmCaptureMode {
        let proto = environment["ARRAY_FILM_PROTO"] == "1"
        var range: ClosedRange<Int>?
        if let text = environment["ARRAY_FILM_FRAMES"], !text.isEmpty {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 2, let low = parts[0], let high = parts[1], low >= 0, low <= high else {
                throw FilmError("ARRAY_FILM_FRAMES \(text): want A-B, 0 <= A <= B")
            }
            range = low...high
        }
        return FilmCaptureMode(proto: proto, range: range, stride: proto ? max(1, sceneFps / 30) : 1)
    }

    func captures(_ frame: Int) -> Bool { (range?.contains(frame) ?? true) && frame % stride == 0 }
    func capturedFrames(of take: FilmScene.Take) -> [Int] { (0..<take.frames).filter(captures) }
}

@MainActor
final class FilmCapture {
    struct Frame: Encodable {
        var i: Int
        var t: Double
        var png: String?
        var viewport: [String: Double]
        var actions: [String]
        var digest: String
        var pointer: Pointer
        var rects: [String: [Double]]
    }
    struct Pointer: Encodable {
        var x: Double
        var y: Double
        var down: Bool
        var mode: String
    }

    let window: NSWindow
    let directory: URL
    let take: FilmScene.Take
    let sceneId: String
    let fps: Int
    let png: FilmPNGPolicy
    let video: String
    let mode: FilmCaptureMode

    private var filter: SCContentFilter?
    private let config = SCStreamConfiguration()
    private var keys: [[String: Any]] = []
    private var menus: [[String: Any]] = []
    private var sounds: [[String: Any]] = []
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frames: [Frame] = []
    private var marks: [String: Int] = [:]
    private var events: [[String: Any]] = []
    private var pixelSize: CGSize = .zero
    private var blankFrames: [Int] = []
    private let pngQueue = DispatchQueue(label: "array.film.png", qos: .userInitiated, attributes: .concurrent)
    private let pngGroup = DispatchGroup()

    init(window: NSWindow, directory: URL, take: FilmScene.Take, sceneId: String, fps: Int, png: FilmPNGPolicy, video: String,
         mode: FilmCaptureMode) {
        self.window = window
        self.directory = directory
        self.take = take
        self.sceneId = sceneId
        self.fps = fps
        // Proto writes every frame it captures, as JPEG, and no movie.
        self.png = mode.proto ? .all : png
        self.video = mode.proto ? "none" : video
        self.mode = mode
    }

    func prepare() async throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let content: SCShareableContent
        if #available(macOS 14.4, *) {
            content = try await SCShareableContent.currentProcess
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw FilmError("ScreenCaptureKit does not list this process's window \(window.windowNumber)")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = mode.proto ? 1 : CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        self.filter = filter
    }

    /// The window's content area (no title bar) in the captured image's pixels.
    private func contentCrop(for image: CGImage) -> CGRect {
        let scale = CGFloat(image.width) / window.frame.width
        let content = window.contentLayoutRect
        return CGRect(x: content.minX * scale, y: (window.frame.height - content.maxY) * scale,
                      width: content.width * scale, height: content.height * scale).integral
    }

    func grab() async throws -> CGImage {
        guard let filter else { throw FilmError("capture not prepared") }
        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return full.cropping(to: contentCrop(for: full)) ?? full
    }

    func capture(_ record: FilmDirector.FrameRecord, isLast: Bool) async throws {
        // Two refreshes for the render server to composite what the director committed.
        try await Task.sleep(nanoseconds: 34_000_000)
        let image = try await grab()
        if writer == nil && video != "none" { try startWriter(width: image.width, height: image.height) }
        pixelSize = CGSize(width: image.width, height: image.height)
        guard let buffer = makePixelBuffer(image) else { throw FilmError("frame \(record.index): no pixel buffer") }
        let (digest, blank) = Self.inspect(buffer)
        if blank { blankFrames.append(record.index) }

        var pngName: String?
        if png.writes(frame: record.index, last: take.frames - 1) {
            let name = String(format: mode.proto ? "frames/%06d.jpg" : "frames/%06d.png", record.index)
            pngName = name
            let url = directory.appendingPathComponent(name)
            let type = mode.proto ? UTType.jpeg : UTType.png
            let properties = mode.proto ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
            pngGroup.enter()
            pngQueue.async { [pngGroup] in
                defer { pngGroup.leave() }
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, image, properties)
                CGImageDestinationFinalize(dest)
            }
        }
        if let input, let adaptor {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(record.index), timescale: CMTimeScale(fps))) else {
                throw FilmError("frame \(record.index): video append failed: \(String(describing: writer?.error))")
            }
        }
        func round(_ value: CGFloat, _ scale: Double) -> Double { (Double(value) * scale).rounded() / scale }
        frames.append(Frame(i: record.index, t: Double(record.index) / Double(fps), png: pngName,
                            viewport: ["x": record.viewport.x, "y": record.viewport.y, "zoom": record.viewport.zoom],
                            actions: record.actions, digest: digest,
                            pointer: Pointer(x: round(record.pointer.point.x, 100), y: round(record.pointer.point.y, 100),
                                             down: record.pointer.down, mode: record.pointer.mode),
                            rects: record.rects.mapValues { r in [round(r.minX, 10), round(r.minY, 10), round(r.width, 10), round(r.height, 10)] }))
        for type in record.events { events.append(["frame": record.index, "type": type]) }
        for key in record.keys { keys.append(key.merging(["frame": record.index]) { $1 }) }
        for menu in record.menus { menus.append(menu.merging(["frame": record.index]) { $1 }) }
        for sound in record.sounds { sounds.append(sound.merging(["frame": record.index]) { $1 }) }
    }

    func mark(_ name: String, frame: Int) { marks[name] = frame }

    /// Finishes the movie and writes `frames.json`. Returns the verdict.
    @discardableResult
    func finish(extra: [String: Any] = [:]) async throws -> String {
        if let writer, let input {
            input.markAsFinished()
            await writer.finishWriting()
            if writer.status != .completed { throw FilmError("video: \(String(describing: writer.error))") }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            pngGroup.notify(queue: .main) { done.resume() }
        }
        let verdict = blankFrames.isEmpty && frames.count == mode.capturedFrames(of: take).count ? "PASS" : "FAIL"
        var payload: [String: Any] = [
            "schema": "array.film.frames.v2",
            "scene": sceneId,
            "take": take.name,
            // The rate the captured frames play at; `i` and `t` stay on the scene's clock.
            "fps": fps / mode.stride,
            "sourceFps": fps,
            "mode": mode.proto ? "proto" : "full",
            "frameStride": mode.stride,
            "frameRange": mode.range.map { [$0.lowerBound, $0.upperBound] as Any } ?? NSNull(),
            "pixelSize": [Int(pixelSize.width), Int(pixelSize.height)],
            "pointSize": [Int(window.contentLayoutRect.width), Int(window.contentLayoutRect.height)],
            "count": frames.count,
            "video": video == "none" ? NSNull() : videoFileName as Any,
            "marks": marks,
            "events": events,
            "keys": keys,
            "menus": menus,
            "sounds": sounds,
            "blankFrames": blankFrames,
            "verdict": verdict,
            "frames": try frames.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ]
        for (key, value) in extra { payload[key] = value }
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("frames.json"), options: .atomic)
        return verdict
    }

    private var videoFileName: String { "\(take.name).\(video == "h264" ? "mp4" : "mov")" }

    private func startWriter(width: Int, height: Int) throws {
        let url = directory.appendingPathComponent(videoFileName)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: video == "h264" ? .mp4 : .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: video == "h264" ? AVVideoCodecType.h264 : AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if video == "h264" {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 40_000_000,
                                                         AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw FilmError("video: cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw FilmError("video: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func makePixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor?.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// MD5 of the pixels (the determinism witness across runs) and a blank verdict:
    /// fewer than 8 distinct colours on a 64x36 sample grid is not a frame of Array.
    static func inspect(_ buffer: CVPixelBuffer) -> (digest: String, blank: Bool) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return ("", true) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let digest = Insecure.MD5.hash(data: UnsafeRawBufferPointer(start: base, count: rowBytes * height))
            .map { String(format: "%02x", $0) }.joined()
        var colours = Set<UInt32>()
        for gy in 0..<36 {
            for gx in 0..<64 {
                let x = (gx * 2 + 1) * width / 128, y = (gy * 2 + 1) * height / 72
                colours.insert(base.load(fromByteOffset: y * rowBytes + x * 4, as: UInt32.self))
            }
        }
        return (digest, colours.count < 8)
    }
}
#endif
