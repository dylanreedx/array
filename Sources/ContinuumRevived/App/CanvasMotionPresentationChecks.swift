import AppKit
import ContinuumRevivedCore
import CoreMedia
import CoreVideo
import Darwin
import ScreenCaptureKit

// Opt-in wall-clock probe. A captured marker proves a composited camera commit,
// not physical scanout or that every document's backing pixels are up to date.
private enum MotionClock {
    static func seconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    static func ticks(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64((seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer)).rounded())
    }
    static var now: Double { seconds(mach_absolute_time()) }
}

@MainActor
private final class MotionCommitMarker: NSView {
    static let cellWidth: CGFloat = 8
    static let cells = 36
    private var bits: [CALayer] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: NSRect(x: 16, y: 16, width: 288, height: 16))
        wantsLayer = true
        layer?.zPosition = 1_000_000
        for i in 0..<Self.cells {
            let cell = CALayer()
            cell.frame = CGRect(x: CGFloat(i) * Self.cellWidth, y: 0, width: Self.cellWidth, height: 16)
            layer?.addSublayer(cell)
            bits.append(cell)
        }
        apply(serial: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(serial: Int) {
        let value = UInt32(serial) & 0x00ff_ffff
        let check = ((value >> 16) ^ (value >> 8) ^ value ^ 0xa7) & 0xff
        let payload = (value << 8) | check
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bits[0].backgroundColor = NSColor.magenta.cgColor
        bits[1].backgroundColor = NSColor.cyan.cgColor
        for index in 0..<32 {
            bits[index + 2].backgroundColor = ((payload >> UInt32(31 - index)) & 1) == 1
                ? NSColor.white.cgColor : NSColor.black.cgColor
        }
        bits[34].backgroundColor = NSColor.yellow.cgColor
        bits[35].backgroundColor = NSColor.blue.cgColor
        CATransaction.commit()
    }
}

private struct MotionCapturedFrame: Sendable {
    let arrival: Double
    let display: Double?
    let displayMach: UInt64?
    let status: Int
    let serial: Int?
    let geometryValid: Bool?
    let geometryEdgeErrorPixels: Double?
    let geometryRectPixels: [Double]?
    let decodeMilliseconds: Double
    var json: [String: Any] {
        ["arrivalSeconds": arrival, "displaySeconds": display as Any? ?? NSNull(),
         "displayMach": displayMach as Any? ?? NSNull(), "status": status,
         "serial": serial as Any? ?? NSNull(), "geometryValid": geometryValid as Any? ?? NSNull(),
         "geometryEdgeErrorPixels": geometryEdgeErrorPixels as Any? ?? NSNull(),
         "geometryRectPixels": geometryRectPixels as Any? ?? NSNull(),
         "decodeMilliseconds": decodeMilliseconds]
    }
}

// Only scalar records cross the queue boundary. No CMSampleBuffer/IOSurface is
// retained. Lock protects snapshots and stop errors; decoding runs on one queue.
private final class MotionStreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.arrayapp.motion-capture", qos: .userInitiated)
    private let lock = NSLock()
    private var frames: [MotionCapturedFrame] = []
    private var failure: String?
    private var geometryBySerial: [Int: CGRect] = [:]
    private var markerOrigin: (Double, Double)?
    private var callbackCount = 0
    let cellPixels: Double

    init(cellPixels: Double) {
        self.cellPixels = cellPixels
        super.init()
        frames.reserveCapacity(8_000)
    }

    func register(serial: Int, viewport: CanvasViewport, worldRect: CGRect) {
        let origin = CanvasEngine.worldToScreen(worldRect.origin, viewport: viewport)
        let rect = CGRect(origin: origin, size: CGSize(width: worldRect.width * viewport.zoom,
                                                       height: worldRect.height * viewport.zoom))
        lock.lock(); defer { lock.unlock() }
        geometryBySerial[serial] = rect
    }

    func snapshot() -> ([MotionCapturedFrame], String?) {
        lock.lock(); defer { lock.unlock() }
        return (frames, failure)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); defer { lock.unlock() }
        failure = String(describing: error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let arrival = MotionClock.now
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        let status = (attachments?[.status] as? NSNumber)?.intValue ?? -1
        let displayMach = (attachments?[.displayTime] as? NSNumber)?.uint64Value
        callbackCount += 1
        var decoded: (serial: Int, valid: Bool?, error: Double?, rect: [Double]?)?
        if status == SCFrameStatus.complete.rawValue,
           let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            decoded = decode(buffer)
        }
        let record = MotionCapturedFrame(arrival: arrival,
            display: displayMach.map(MotionClock.seconds), displayMach: displayMach,
            status: status, serial: decoded?.serial, geometryValid: decoded?.valid,
            geometryEdgeErrorPixels: decoded?.error, geometryRectPixels: decoded?.rect,
            decodeMilliseconds: (MotionClock.now - arrival) * 1_000)
        lock.lock()
        if frames.count < 50_000 { frames.append(record) }
        else { failure = "capture record capacity exceeded" }
        lock.unlock()
    }

    private func decode(_ buffer: CVPixelBuffer) -> (serial: Int, valid: Bool?, error: Double?, rect: [Double]?)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func rgb(_ x: Double, _ y: Double) -> (Int, Int, Int)? {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, iy >= 0, ix < width, iy < height else { return nil }
            let p = base.advanced(by: iy * stride + ix * 4)
            return (Int(p[2]), Int(p[1]), Int(p[0]))
        }
        func read(_ x: Double, _ y: Double) -> Int? {
            guard let a = rgb(x, y), a.0 > 180, a.1 < 100, a.2 > 180,
                  let b = rgb(x + cellPixels, y), b.0 < 100, b.1 > 180, b.2 > 180,
                  let c = rgb(x + 34 * cellPixels, y), c.0 > 180, c.1 > 180, c.2 < 100,
                  let d = rgb(x + 35 * cellPixels, y), d.0 < 100, d.1 < 100, d.2 > 180 else { return nil }
            var payload: UInt32 = 0
            for bit in 0..<32 {
                guard let color = rgb(x + Double(bit + 2) * cellPixels, y) else { return nil }
                let sum = color.0 + color.1 + color.2
                guard sum < 180 || sum > 585 else { return nil }
                payload = (payload << 1) | (sum > 585 ? 1 : 0)
            }
            let value = payload >> 8
            guard (payload & 0xff) == ((value >> 16) ^ (value >> 8) ^ value ^ 0xa7) & 0xff else { return nil }
            return Int(value)
        }
        func validate(_ serial: Int) -> (Int, Bool?, Double?, [Double]?) {
            lock.lock()
            let expected = geometryBySerial[serial]
            lock.unlock()
            guard let expected, let (mx, my) = markerOrigin else { return (serial, nil, nil, nil) }
            // The barcode's first cell center is at canvas (20,24). It supplies
            // the capture-space origin/scale without assuming title-bar height.
            let scale = cellPixels / 8
            let x = mx + (expected.minX - 20) * scale
            let y = my + (expected.minY - 24) * scale
            let w = expected.width * scale, h = expected.height * scale
            let rect = [x, y, w, h]
            guard w >= 12, h >= 12, x >= 6, y >= 6,
                  x + w + 6 < Double(width), y + h + 6 < Double(height) else {
                return (serial, false, nil, rect)
            }
            func magenta(_ color: (Int, Int, Int)?) -> Bool {
                guard let c = color else { return false }
                return c.0 > 180 && c.1 < 100 && c.2 > 180
            }
            func cyan(_ color: (Int, Int, Int)?) -> Bool {
                guard let c = color else { return false }
                return c.0 < 100 && c.1 > 180 && c.2 > 180
            }
            guard cyan(rgb(x + w / 2, y + h / 2)) else { return (serial, false, nil, rect) }
            // Locate four actual colored edges on two short scanlines. Checking
            // only the center would accept an old, overlapping camera image.
            let horizontal = (Int(floor(x - 5))...Int(ceil(x + w + 5))).filter {
                magenta(rgb(Double($0), y + h / 2))
            }
            let vertical = (Int(floor(y - 5))...Int(ceil(y + h + 5))).filter {
                magenta(rgb(x + w / 2, Double($0)))
            }
            guard let left = horizontal.first, let right = horizontal.last,
                  let top = vertical.first, let bottom = vertical.last else { return (serial, false, nil, rect) }
            let edgeError = max(abs(Double(left) - x), abs(Double(right + 1) - (x + w)),
                                abs(Double(top) - y), abs(Double(bottom + 1) - (y + h)))
            return (serial, edgeError <= 2, edgeError, rect)
        }
        if let (x, y) = markerOrigin, let value = read(x, y) { return validate(value) }
        // Search only until the fixed marker is located. If geometry changes,
        // retry at a bounded cadence rather than scanning every captured frame.
        guard callbackCount == 1 || callbackCount.isMultiple(of: 30) else { return nil }
        for y in 0..<min(height, 220) {
            for x in 0..<max(0, width - Int(36 * cellPixels)) {
                let p = base.advanced(by: y * stride + x * 4)
                guard p[2] > 180, p[1] < 100, p[0] > 180 else { continue }
                let cx = Double(x) + cellPixels * 0.5
                let cy = Double(y) + cellPixels
                if let value = read(cx, cy) {
                    markerOrigin = (cx, cy)
                    return validate(value)
                }
            }
        }
        return nil
    }
}

/// A display-link heartbeat on the main thread. A late tick is a main-thread
/// stall whatever the camera was doing (settle and swap included), and the work
/// counters read at each tick name what ran in between.
@MainActor
private final class MotionFrameTicker: NSObject {
    private var link: CADisplayLink?
    private let read: () -> [String: Any]
    private(set) var ticks: [[String: Any]] = []

    init(view: NSView, read: @escaping () -> [String: Any]) {
        self.read = read
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        var record = read()
        record["seconds"] = MotionClock.now
        record["targetTimestamp"] = link.targetTimestamp
        ticks.append(record)
    }

    func stop() { link?.invalidate(); link = nil }
}

@MainActor
private final class MotionRunState {
    var serial = 0
    var phase = "warmup"
    var lastInput = -1
    var commits: [[String: Any]] = []
    var inputs: [[String: Any]] = []
    var dispatches: [[String: Any]] = []
    var phases: [[String: Any]] = []
}

private func motionDistribution(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["count": 0] }
    let sorted = values.sorted()
    func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    return ["count": values.count, "p50": percentile(0.5), "p95": percentile(0.95),
            "p99": percentile(0.99), "max": sorted.last!,
            "mean": values.reduce(0, +) / Double(values.count)]
}

@MainActor
func runCanvasMotionPresentationCheck() async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let output = env["CANVAS_MOTION_OUTPUT"].map { URL(fileURLWithPath: $0) }
    func save(_ report: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
    func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        guard let text = env[key], let value = Double(text), value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    var workload: CanvasMotionWorkload?
    var capture: SCStream?
    var receiver: MotionStreamReceiver?
    var screenshotFilter: SCContentFilter?
    var captureGeometry: [String: Any] = [:]
    defer {
        workload?.canvas.qaOnViewportApplied = nil
        workload?.onInputDispatched = nil
        workload?.close()
    }
    do {
        guard #available(macOS 14.4, *) else { throw Failure(description: "own-process ScreenCaptureKit requires macOS 14.4") }
        guard let output, let rootPath = env["CONTINUUM_PROJECT_ROOT"], let supportPath = env["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "requires CANVAS_MOTION_OUTPUT, isolated CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let markdownCount = max(0, Int(env["CANVAS_MOTION_MARKDOWN_COUNT"] ?? "") ?? 24)
        let agentCount = max(0, Int(env["CANVAS_MOTION_AGENT_COUNT"] ?? "") ?? 8)
        let duration = number("CANVAS_MOTION_PHASE_SECONDS", 6, 0.5...30)
        let warmup = number("CANVAS_MOTION_WARMUP_SECONDS", 8, 0.5...60)
        let settle = number("CANVAS_MOTION_SETTLE_SECONDS", 2, 0.5...10)
        let hz = number("CANVAS_MOTION_INPUT_HZ", 120, 30...240)
        let captureEnabled = env["CANVAS_MOTION_CAPTURE"] != "0"
        let selectedPhase = env["CANVAS_MOTION_PHASE"] ?? "zoom"
        guard ["pan", "zoom", "mixed"].contains(selectedPhase) else {
            throw Failure(description: "CANVAS_MOTION_PHASE must be pan, zoom or mixed")
        }
        // CANVAS_MOTION_STREAM=0 is the quiet control: agents attached, nothing streaming.
        let streams = env["CANVAS_MOTION_STREAM"] != "0"
        let deltaMs = max(5, Int(env["CANVAS_MOTION_DELTA_MS"] ?? "") ?? 50)
        let sourceTickLimit = streams ? Int(duration * 1_000 / Double(deltaMs)) : 0
        let fixture = try CanvasMotionWorkload(root: URL(fileURLWithPath: rootPath),
            support: URL(fileURLWithPath: supportPath), markdownCount: markdownCount, agentCount: agentCount)
        workload = fixture
        if let screen = NSScreen.screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            // A replay keeps the source window's size (its frame, as the window
            // server reported it); otherwise the fixed benchmark size.
            let wanted = fixture.replayWindowSize ?? NSSize(width: 1_400, height: 900)
            let size = NSSize(width: min(wanted.width, visible.width), height: min(wanted.height, visible.height))
            fixture.window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                          width: size.width, height: size.height), display: true)
        }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let worldCenter = CanvasEngine.screenToWorld(CGPoint(x: fixture.canvas.bounds.midX,
            y: fixture.canvas.bounds.midY), viewport: fixture.canvas.viewport)
        let worldRect = CGRect(x: worldCenter.x - 80, y: worldCenter.y - 60, width: 160, height: 120)
        let fiducial = NSView(frame: worldRect)
        fiducial.wantsLayer = true
        fiducial.layer?.backgroundColor = NSColor.cyan.cgColor
        fiducial.layer?.borderColor = NSColor.magenta.cgColor
        fiducial.layer?.borderWidth = 32
        fiducial.layer?.zPosition = 1_000_000
        fixture.canvas.worldPlane.addSubview(fiducial, positioned: .above, relativeTo: nil)
        let marker = MotionCommitMarker()
        fixture.canvas.addSubview(marker, positioned: .above, relativeTo: nil)
        let state = MotionRunState()
        fixture.canvas.qaOnViewportApplied = { viewport in
            state.serial += 1
            receiver?.register(serial: state.serial, viewport: viewport, worldRect: worldRect)
            marker.apply(serial: state.serial)
            state.commits.append(["serial": state.serial, "seconds": MotionClock.now,
                "phase": state.phase, "latestEnqueuedInput": state.lastInput,
                "x": viewport.x, "y": viewport.y, "zoom": viewport.zoom,
                "work": fixture.canvas.qaFrameWorkCounters])
        }
        // Public CGEvent→NSEvent conversion does not reliably bind the event to
        // an NSWindow. The workload queues the real scroll responder directly;
        // the callback timestamps handler entry before the ordinary driver runs.
        fixture.onInputDispatched = { event in
            state.dispatches.append(["seconds": MotionClock.now, "eventTimestamp": event.timestamp,
                "phase": state.phase, "dx": event.scrollingDeltaX, "dy": event.scrollingDeltaY,
                "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                "command": event.modifierFlags.contains(.command), "route": "queued-production-responder",
                "eventWindowNumber": event.windowNumber, "eventWindowBound": event.window === fixture.window])
        }
        try save(["pid": ProcessInfo.processInfo.processIdentifier, "stage": "preparing-capture",
            "output": output.path, "captureEnabled": captureEnabled],
            to: URL(fileURLWithPath: output.path + ".ready.json"))
        // WindowServer can enumerate a just-created window before its filter's
        // dimensions are available. Yield normally; never force a display pass.
        try await Task.sleep(for: .milliseconds(300))
        if captureEnabled {
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(fixture.window.windowNumber) }) else {
                throw Failure(description: "own visible window unavailable to ScreenCaptureKit")
            }
            let filter = SCContentFilter(desktopIndependentWindow: own)
            screenshotFilter = filter
            let filterRect = filter.contentRect
            let dimensions = filterRect.width > 0 && filterRect.height > 0 ? filterRect.size
                : (own.frame.width > 0 && own.frame.height > 0 ? own.frame.size : fixture.window.frame.size)
            guard dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width >= 100, dimensions.height >= 100,
                  dimensions.width <= 10_000, dimensions.height <= 10_000 else {
                throw Failure(description: "invalid own-window capture dimensions: \(dimensions)")
            }
            let config = SCStreamConfiguration()
            config.width = max(640, Int(dimensions.width * 0.5))
            config.height = Int(Double(config.width) * dimensions.height / dimensions.width)
            config.minimumFrameInterval = .zero
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true
            config.colorSpaceName = CGColorSpace.sRGB
            if #available(macOS 15.0, *) { config.captureMicrophone = false }
            captureGeometry = ["width": config.width, "height": config.height,
                "windowWidthPoints": dimensions.width, "windowHeightPoints": dimensions.height,
                "filterWidthPoints": filterRect.width, "filterHeightPoints": filterRect.height,
                "displayID": (fixture.window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) as Any? ?? NSNull(),
                "screenMaximumFPS": fixture.window.screen?.maximumFramesPerSecond ?? 0,
                "screenBackingScale": fixture.window.backingScaleFactor,
                "worldFiducial": [worldRect.minX, worldRect.minY, worldRect.width, worldRect.height]]
            let sink = MotionStreamReceiver(cellPixels: 8 * Double(config.width) / dimensions.width)
            receiver = sink
            sink.register(serial: state.serial, viewport: fixture.canvas.viewport, worldRect: worldRect)
            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            capture = stream
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            let timeout = MotionClock.now + 8
            while sink.snapshot().0.allSatisfy({ $0.geometryValid != true }), MotionClock.now < timeout {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard sink.snapshot().0.contains(where: { $0.serial != nil && $0.geometryValid == true }) else {
                throw Failure(description: "capture did not validate initial camera barcode and world geometry; refusing zero-frame success")
            }
        }
        // Warm the same seeded history in every variant without admitting live
        // text. Live source work has a finite independent budget during motion.
        fixture.prepareStreaming()
        try save(["pid": ProcessInfo.processInfo.processIdentifier, "readySeconds": MotionClock.now,
            "stage": "warming-up",
            "output": output.path, "captureEnabled": captureEnabled, "warmupSeconds": warmup,
            "workload": fixture.snapshot()], to: URL(fileURLWithPath: output.path + ".ready.json"))
        print("[canvas-motion] ready pid=\(ProcessInfo.processInfo.processIdentifier) output=\(output.path)")
        try await Task.sleep(for: .seconds(warmup))
        let baseline = fixture.snapshot()
        var visibilityErrors: [String] = []
        @MainActor func checkVisibility(_ snapshot: [String: Any], _ label: String) {
            let shown = snapshot["windowVisible"] as? Bool == true
            let unoccluded = snapshot["windowOcclusionVisible"] as? Bool == true
            if !shown || !unoccluded {
                visibilityErrors.append("\(label): benchmark window was hidden or fully occluded")
            }
        }
        checkVisibility(baseline, "baseline")
        let ticker = MotionFrameTicker(view: fixture.canvas) {
            ["phase": state.phase,
             "work": fixture.canvas.qaFrameWorkCounters]
        }
        defer { ticker.stop() }
        let producer = DispatchQueue(label: "dev.arrayapp.motion-input", qos: .userInteractive)
        // Lets an external profiler start with the motion, not the warmup.
        try save(["pid": ProcessInfo.processInfo.processIdentifier, "stage": "motion",
            "output": output.path, "warmupSeconds": warmup],
            to: URL(fileURLWithPath: output.path + ".ready.json"))
        for phase in [selectedPhase] {
            state.phase = phase
            let before = fixture.snapshot()
            checkVisibility(before, phase + "-before")
            let beginMach = mach_absolute_time() + MotionClock.ticks(0.1)
            let begin = MotionClock.seconds(beginMach)
            fixture.startStreaming(delay: 0.1, tickLimit: sourceTickLimit)
            let count = Int((duration * hz).rounded())
            let inputBase = state.inputs.count
            // Kernel absolute waits keep the producer independent of main-thread
            // progress and avoid dispatch_after's deadline-dependent timer leeway.
            // Only this background queue waits; intended and actual times remain
            // separate so missed host deadlines cannot masquerade as app stalls.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                producer.async {
                    for index in 0..<count {
                        let t = Double(index) / hz
                        let inputDeadline = beginMach + MotionClock.ticks(t)
                        while mach_absolute_time() < inputDeadline {
                            mach_wait_until(inputDeadline)
                        }
                        let queued = MotionClock.now
                        let previous = Double(max(0, index - 1)) / hz
                        let omega = 2 * Double.pi / 3
                        let dx = 100 * (sin(omega * t) - sin(omega * previous))
                        let dy = 60 * (cos(omega * t) - cos(omega * previous))
                        let logDelta = 0.4 * (sin(omega * t) - sin(omega * previous))
                        DispatchQueue.main.async {
                            state.lastInput = inputBase + index
                            state.inputs.append(["index": state.lastInput, "phase": phase,
                                "scheduledSeconds": begin + t, "producerSeconds": queued,
                                "mainSeconds": MotionClock.now, "panDX": dx, "panDY": dy,
                                "logZoom": logDelta])
                            if phase != "zoom" { fixture.postPan(dx: dx, dy: dy) }
                            if phase != "pan" { fixture.postMagnify(delta: exp(logDelta) - 1) }
                        }
                    }
                    let endDeadline = beginMach + MotionClock.ticks(duration)
                    while mach_absolute_time() < endDeadline {
                        mach_wait_until(endDeadline)
                    }
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
            let drained = MotionClock.now
            let afterInput = fixture.snapshot()
            checkVisibility(afterInput, phase + "-afterInput")
            state.phase = phase + "-settle"
            try await Task.sleep(for: .seconds(settle))
            let afterSettle = fixture.snapshot()
            checkVisibility(afterSettle, phase + "-afterSettle")
            state.phases.append(["name": phase, "startSeconds": begin, "endSeconds": begin + duration,
                "mainQueueDrainedSeconds": drained, "settleEndSeconds": MotionClock.now,
                "sourceTickLimit": sourceTickLimit, "sourceScheduledStartSeconds": begin,
                "lastCameraSerial": state.serial, "before": before,
                "afterInput": afterInput, "afterSettle": afterSettle])
        }
        // The provider stops itself at its finite budget, including the final
        // tick at the motion boundary. Complete the normal turn only after the
        // post-input observation so that cancellation cannot race that tick.
        fixture.stopStreaming()
        let drainDeadline = MotionClock.now + 3
        while streams, !fixture.hasDeliveredStreamingSource, MotionClock.now < drainDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if let capture { try await capture.stopCapture() }
        capture = nil
        let (frames, captureError) = receiver?.snapshot() ?? ([], nil)
        var summaries: [[String: Any]] = []
        for phase in state.phases {
            let name = phase["name"] as! String
            let begin = phase["startSeconds"] as! Double
            let end = phase["endSeconds"] as! Double
            let tailEnd = phase["settleEndSeconds"] as! Double
            let valid = frames.filter { $0.serial != nil && ($0.display ?? 0) >= begin && ($0.display ?? 0) <= tailEnd }
                .sorted { ($0.display ?? 0) < ($1.display ?? 0) }
            var lastSerial = frames.last(where: { ($0.display ?? 0) < begin && $0.serial != nil })?.serial
            var changes: [MotionCapturedFrame] = []
            for frame in valid {
                if frame.serial != lastSerial { changes.append(frame); lastSerial = frame.serial }
            }
            let active = changes.filter { ($0.display ?? 0) < end }
            var lastVerifiedSerial = frames.last(where: {
                ($0.display ?? 0) < begin && $0.geometryValid == true
            })?.serial
            var verified: [MotionCapturedFrame] = []
            for frame in valid where frame.geometryValid == true {
                if frame.serial != lastVerifiedSerial {
                    if (frame.display ?? 0) < end { verified.append(frame) }
                    lastVerifiedSerial = frame.serial
                }
            }
            let times = active.compactMap(\.display)
            let verifiedTimes = verified.compactMap(\.display)
            let verifiedIntervals = zip(verifiedTimes.dropFirst(), verifiedTimes).map { ($0 - $1) * 1_000 }
            let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1_000 }
            let boundaries = [begin] + times + [end]
            let holds = zip(boundaries.dropFirst(), boundaries).map { ($0 - $1) * 1_000 }
            let phaseInputs = state.inputs.filter { $0["phase"] as? String == name }
            let lags = phaseInputs.map { (($0["mainSeconds"] as! Double) - ($0["scheduledSeconds"] as! Double)) * 1_000 }
            let phaseCommits = state.commits.filter {
                let time = $0["seconds"] as! Double
                return time >= begin && time < end
            }
            let tailCommits = state.commits.filter {
                let time = $0["seconds"] as! Double
                return time >= end && time <= tailEnd
            }
            let producerLags = phaseInputs.map { (($0["producerSeconds"] as! Double) - ($0["scheduledSeconds"] as! Double)) * 1_000 }
            let mainLags = phaseInputs.map { (($0["mainSeconds"] as! Double) - ($0["producerSeconds"] as! Double)) * 1_000 }
            let bySerial = Dictionary(uniqueKeysWithValues: state.commits.map { ($0["serial"] as! Int, $0["seconds"] as! Double) })
            let latency = active.compactMap { frame -> Double? in
                guard let serial = frame.serial, let commit = bySerial[serial], let display = frame.display else { return nil }
                return (display - commit) * 1_000
            }
            let finalSerial = phase["lastCameraSerial"] as! Int
            let finalFrame = valid.first { $0.serial == finalSerial }
            let finalVerifiedFrame = valid.first { $0.serial == finalSerial && $0.geometryValid == true }
            summaries.append(["phase": name, "scheduledInputCount": phaseInputs.count,
                "cameraCommitCount": phaseCommits.count, "distinctCapturedCameraStates": active.count,
                "tailCameraCommitCount": tailCommits.count,
                "tailCapturedCameraStates": changes.filter { ($0.display ?? 0) >= end }.count,
                "tailObservationSeconds": tailEnd - end,
                "mainInputDrainAfterEndMs": ((phase["mainQueueDrainedSeconds"] as! Double) - end) * 1_000,
                "capturedCameraStatesPerSecond": Double(active.count) / duration,
                "geometryVerifiedCameraStates": verified.count,
                "geometryVerifiedCameraStatesPerSecond": Double(verified.count) / duration,
                "geometryInvalidCameraStates": active.filter { $0.geometryValid != true }.count,
                "geometryVerifiedChangeIntervalsMs": motionDistribution(verifiedIntervals),
                "cameraChangeIntervalsMs": motionDistribution(intervals),
                "activeHoldIntervalsMs": motionDistribution(holds),
                "scheduledToMainMs": motionDistribution(lags),
                "scheduledToProducerMs": motionDistribution(producerLags),
                "producerToMainMs": motionDistribution(mainLags),
                "commitToCapturedDisplayMs": motionDistribution(latency),
                "firstCapturedChangeMs": times.first.map { ($0 - begin) * 1_000 } as Any? ?? NSNull(),
                "firstCapturedChangeIncludingTailMs": changes.first?.display.map { ($0 - begin) * 1_000 } as Any? ?? NSNull(),
                "firstGeometryVerifiedChangeMs": verifiedTimes.first.map { ($0 - begin) * 1_000 } as Any? ?? NSNull(),
                "finalCameraCaptured": finalFrame != nil,
                "finalCameraGeometryVerified": finalVerifiedFrame != nil,
                "finalCameraAfterInputEndMs": finalFrame?.display.map { ($0 - end) * 1_000 } as Any? ?? NSNull(),
                "gapsOver16_7ms": intervals.filter { $0 > 16.7 }.count,
                "gapsOver33ms": intervals.filter { $0 > 33 }.count,
                "gapsOver50ms": intervals.filter { $0 > 50 }.count,
                "gapsOver100ms": intervals.filter { $0 > 100 }.count])
        }
        let validFrames = frames.filter { $0.serial != nil }
        let finalSnapshot = fixture.snapshot()
        let initialSource = baseline["source"] as? [String: Any] ?? [:]
        let finalSource = finalSnapshot["source"] as? [String: Any] ?? [:]
        var sourceErrors: [String] = []
        if initialSource["successfulDeltas"] as? Int != 0 {
            sourceErrors.append("live source emitted deltas during static warmup")
        }
        let sourceFinished = finalSource["sourceFinished"] as? Bool == true
        let sourceTicks = finalSource["ticks"] as? Int ?? -1
        if !sourceFinished || sourceTicks != sourceTickLimit {
            sourceErrors.append("independent source did not finish its exact \(sourceTickLimit)-tick budget")
        }
        let deltas = finalSource["deltasPerAgent"] as? [Int] ?? []
        let expectedPerAgentDelivered = deltas.allSatisfy { $0 == sourceTickLimit }
        let successfulDeltas = finalSource["successfulDeltas"] as? Int ?? -1
        let streamingCount = fixture.streamingAgentCount
        if deltas.count != streamingCount || !expectedPerAgentDelivered ||
            successfulDeltas != sourceTickLimit * streamingCount {
            sourceErrors.append("source per-agent delta counts do not match the fixed offered workload")
        }
        let errors = summaries.compactMap { summary -> String? in
            if (summary["cameraCommitCount"] as? Int ?? 0) < 2 { return "\(summary["phase"]!): camera did not move" }
            if captureEnabled && (summary["distinctCapturedCameraStates"] as? Int ?? 0) < 2 { return "\(summary["phase"]!): no distinct captured camera changes" }
            if captureEnabled && summary["finalCameraCaptured"] as? Bool != true { return "\(summary["phase"]!): final camera not captured during settle" }
            if captureEnabled && summary["finalCameraGeometryVerified"] as? Bool != true { return "\(summary["phase"]!): final camera geometry not verified during settle" }
            if captureEnabled && (summary["geometryVerifiedCameraStates"] as? Int ?? 0) < 2 { return "\(summary["phase"]!): transformed world geometry not verified" }
            return nil
        } + (captureError.map { [$0] } ?? [])
          + (!streams || fixture.hasDeliveredStreamingSource ? [] : ["stream source did not reach tile and supervisor semantics before drain deadline"])
          + visibilityErrors + sourceErrors
        var screenshot: String?
        var screenshotError: String?
        if let filter = screenshotFilter {
            do {
                let config = SCStreamConfiguration()
                config.width = Int(fixture.window.frame.width * fixture.window.backingScaleFactor)
                config.height = Int(fixture.window.frame.height * fixture.window.backingScaleFactor)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw Failure(description: "final screenshot PNG encoding failed")
                }
                let path = output.deletingPathExtension().appendingPathExtension("png")
                try data.write(to: path, options: .atomic)
                screenshot = path.path
            } catch { screenshotError = String(describing: error) }
        }
        let report: [String: Any] = ["check": "canvas-motion-presentation", "version": 2,
            "success": errors.isEmpty, "errors": errors, "pid": ProcessInfo.processInfo.processIdentifier,
            "measurement": captureEnabled ? "own-window-composited-camera-markers" : "observer-disabled-control",
            "limitations": ["Not physical display scanout; independent-window capture can include occluded content.",
                "World-plane fiducial edges must match viewport within two capture pixels; document backing pixels are not individually validated.",
                "Input is queued to the production CanvasNSView scroll responder; not physical HID or OS responder-chain proof. Provider emits deterministic offline events.",
                "Missing serials can reflect camera coalescing or capture loss; calibrate capture ceiling separately."],
            "clock": "mach_absolute_time converted to seconds with mach_timebase_info",
            "configuration": ["markdownCount": markdownCount, "agentCount": agentCount,
                "phase": selectedPhase, "sourceProtocol": "static-warmup-then-finite-motion-burst",
                "sourceHz": 20, "sourceTickLimit": sourceTickLimit,
                "expectedSourceDeltas": sourceTickLimit * agentCount,
                "phaseSeconds": duration, "warmupSeconds": warmup, "settleSeconds": settle,
                "inputHz": hz, "captureEnabled": captureEnabled, "captureQueueDepth": 5,
                "minimumFrameInterval": "zero/native", "os": ProcessInfo.processInfo.operatingSystemVersionString],
            "baseline": baseline, "final": finalSnapshot, "phases": state.phases, "summaries": summaries,
            "captureGeometry": captureGeometry, "screenshot": screenshot as Any? ?? NSNull(),
            "screenshotError": screenshotError as Any? ?? NSNull(),
            "capture": ["frames": frames.count, "validMarkerFrames": validFrames.count,
                "decodeMilliseconds": motionDistribution(frames.map(\.decodeMilliseconds)),
                "deliveryLagMs": motionDistribution(frames.compactMap { frame in
                    frame.display.flatMap { $0 > 0 ? (frame.arrival - $0) * 1_000 : nil }
                })],
            "inputs": state.inputs, "dispatches": state.dispatches, "commits": state.commits,
            "ticks": ticker.ticks,
            "frames": frames.map(\.json)]
        fixture.close()
        try save(report, to: output)
        print("[canvas-motion] \(errors.isEmpty ? "PASS" : "FAIL") \(output.path)")
        return errors.isEmpty ? 0 : 1
    } catch {
        if let capture { try? await capture.stopCapture() }
        var failureScreenshot: String?
        var failureScreenshotError: String?
        if let filter = screenshotFilter, let output {
            do {
                let config = SCStreamConfiguration()
                config.width = max(640, (captureGeometry["width"] as? Int ?? 700) * 2)
                config.height = max(400, (captureGeometry["height"] as? Int ?? 450) * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw Failure(description: "failure screenshot PNG encoding failed")
                }
                let path = output.deletingPathExtension().appendingPathExtension("failure.png")
                try data.write(to: path, options: .atomic)
                failureScreenshot = path.path
            } catch { failureScreenshotError = String(describing: error) }
        }
        workload?.close()
        let message = String(describing: error)
        if let output {
            let (frames, streamError) = receiver?.snapshot() ?? ([], nil)
            try? save(["check": "canvas-motion-presentation", "success": false, "error": message,
                "streamError": streamError as Any? ?? NSNull(), "captureGeometry": captureGeometry,
                "failureScreenshot": failureScreenshot as Any? ?? NSNull(),
                "failureScreenshotError": failureScreenshotError as Any? ?? NSNull(),
                "frames": frames.map(\.json)], to: output)
        }
        print("[canvas-motion] FAIL: \(message)")
        return 1
    }
}
