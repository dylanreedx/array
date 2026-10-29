// Standalone feasibility harness. Deliberately not a registered canvas tile.
import AppKit
import Foundation
import ImageIO

let proofDevice = "11111111-1111-4111-8111-111111111111"

enum Orientation: Int, CaseIterable {
    case portrait, landscapeLeft, upsideDown, landscapeRight
    func rawPoint(_ p: CGPoint) -> CGPoint {
        #if PROOF_WRONG_ROTATION
        return p
        #else
        switch self {
        case .portrait: return p
        case .landscapeLeft: return CGPoint(x: 1 - p.y, y: p.x)
        case .upsideDown: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .landscapeRight: return CGPoint(x: p.y, y: 1 - p.x)
        }
        #endif
    }
}

struct ScreenGeometry {
    var bounds: CGRect
    var pixels: CGSize
    var rect: CGRect {
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    func normalized(_ point: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard clamped || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
}

// One pending frame, independent of producer speed. Generations fence old callbacks.
final class FrameInbox {
    private let lock = NSLock()
    private var pending: (Int, CGImage)?
    private(set) var generation = 0
    func reset() { lock.lock(); generation += 1; pending = nil; lock.unlock() }
    func offer(_ image: CGImage, generation value: Int) {
        lock.lock(); defer { lock.unlock() }
        if value == generation { pending = (value, image) }
    }
    func take() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let image = pending?.1; pending = nil; return image
    }
}

// Minimal incremental MJPEG reader: content-length framing, split-chunk safe,
// bounded allocation. Production may instead use H.264/native IOSurface.
struct MJPEGReader {
    private var buffer = Data()
    private(set) var rejected = 0
    private let limit = 4 * 1024 * 1024
    mutating func push(_ data: Data) -> [Data] {
        guard buffer.count + data.count <= limit else {
            buffer.removeAll(); rejected += 1; return []
        }
        buffer.append(data)
        var frames: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            guard let line = header.components(separatedBy: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }), let length = Int(line.split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)), length > 0, length < limit else {
                buffer.removeAll(); rejected += 1; return frames
            }
            let body = end.upperBound
            guard buffer.count - body >= length + 2 else { break }
            guard buffer[body + length] == 13, buffer[body + length + 1] == 10 else {
                buffer.removeAll(); rejected += 1; return frames
            }
            frames.append(Data(buffer[body..<(body + length)]))
            buffer = Data(buffer[(body + length + 2)...])
        }
        return frames
    }
}

final class PreviewConnection: NSObject, URLSessionDataDelegate {
    let origin: URL
    let device: String
    let inbox = FrameInbox()
    private var parser = MJPEGReader()
    private var partLength: Int?
    private var part = Data()
    private var session: URLSession!
    private var stream: URLSessionDataTask?
    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var outgoing: [Data] = []
    private var sending = false
    private(set) var admitted = false
    private(set) var framesDecoded = 0
    private(set) var failure: String?
    private let decodeQueue = DispatchQueue(label: "array.preview-proof.decode")
    init(origin: URL, device: String) {
        self.origin = origin; self.device = device
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    }
    func start() {
        stream = session.dataTask(with: origin.appendingPathComponent("helper/\(device)/stream.mjpeg"))
        stream?.resume()
        var parts = URLComponents(url: origin.appendingPathComponent("helper/ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = origin.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "device", value: device)]
        socket = session.webSocketTask(with: parts.url!); socket?.resume()
        receive()
    }
    private func receive() {
        let task = socket
        Task { @MainActor in
            do {
                guard let message = try await task?.receive(), !stopped else { return }
                if case .data(let data) = message, data.first == 0x83 { admitted = true }
                receive()
            } catch { if !stopped { failure = String(describing: error) } }
        }
    }
    func send(tag: UInt8, payload: [String: Any]) {
        guard admitted, !stopped else { return }
        let data = Data([tag]) + (try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        outgoing.append(data)
        guard !sending else { return }
        sending = true
        let task = socket
        Task { @MainActor in
            defer { sending = false }
            while !stopped, !outgoing.isEmpty {
                let next = outgoing.removeFirst()
                do { try await task?.send(.data(next)) }
                catch { if !stopped { failure = String(describing: error) }; outgoing.removeAll(); break }
            }
        }
    }
    func stop() {
        stopped = true; admitted = false; inbox.reset()
        outgoing.removeAll()
        stream?.cancel(); socket?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // CFNetwork demultiplexes multipart/x-mixed-replace on macOS and
        // delivers a response per JPEG part, without the multipart headers.
        part.removeAll()
        partLength = response.mimeType == "image/jpeg" ? Int(response.expectedContentLength) : nil
        if let length = partLength, length <= 0 || length > 4 * 1024 * 1024 {
            failure = "invalid JPEG part length"; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        let frames: [Data]
        if let length = partLength {
            guard part.count + data.count <= length else { failure = "oversized JPEG part"; return }
            part.append(data)
            guard part.count == length else { return }
            frames = [part]; part.removeAll()
        } else {
            frames = parser.push(data)
        }
        let generation = inbox.generation
        // Decode only the newest complete frame from this network chunk.
        guard let frame = frames.last else { return }
        decodeQueue.async { [weak self] in
            guard let self, let source = CGImageSourceCreateWithData(frame as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            self.inbox.offer(image, generation: generation)
            DispatchQueue.main.async { if !self.stopped { self.framesDecoded += 1 } }
        }
    }
}

final class DeviceSurface: NSView {
    var image: CGImage?
    var orientation: Orientation = .portrait
    var send: ((UInt8, [String: Any]) -> Void)?
    private var contact: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var geometry: ScreenGeometry {
        ScreenGeometry(bounds: bounds.insetBy(dx: 12, dy: 12),
                       pixels: CGSize(width: image?.width ?? 390, height: image?.height ?? 844))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 28, yRadius: 28).fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let rect = geometry.rect
        NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).addClip()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    func pointer(_ phase: String, point: CGPoint) {
        guard let normalized = geometry.normalized(point, clamped: phase != "begin"),
              phase == "begin" || contact != nil else { return }
        let raw = orientation.rawPoint(normalized)
        contact = phase == "end" ? nil : raw
        send?(0x03, ["type": phase, "x": raw.x, "y": raw.y])
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointer("begin", point: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        pointer("move", point: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        pointer("end", point: convert(event.locationInWindow, from: nil))
    }
    // Proof intentionally covers physical A only. No claim of IME/paste support.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0 { send?(0x06, ["type": "down", "usage": 4]) }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 0 { send?(0x06, ["type": "up", "usage": 4]) }
    }
    override func resignFirstResponder() -> Bool {
        if let contact { send?(0x03, ["type": "end", "x": contact.x, "y": contact.y]) }
        contact = nil
        return true
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
func waitFor(_ message: String, seconds: Double = 8, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    var satisfied = condition()
    while !satisfied, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        satisfied = condition()
    }
    require(satisfied, message)
}
func fixtureImage(changed: Bool, dark: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 390, pixelsHigh: 844,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (dark ? NSColor(calibratedWhite: 0.1, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 390, height: 844)).fill()
    let foreground: NSColor = dark ? .white : .black
    func label(_ text: String, _ y: CGFloat, _ size: CGFloat) {
        (text as NSString).draw(at: NSPoint(x: 26, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: foreground])
    }
    label("Array", 739, 30)
    label("iOS Preview · Fixture", 705, 16)
    label("Controlled test screen", 666, 15)
    (changed ? NSColor.systemGreen : NSColor.systemBlue).setFill()
    NSBezierPath(roundedRect: NSRect(x: 26, y: 420, width: 338, height: 180), xRadius: 18, yRadius: 18).fill()
    label(changed ? "Input received" : "Tap to change state", 382, 21)
    label("Fixture transport, not a simulator", 100, 14)
    label("Live simulator proof is pending", 74, 14)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func liveProof(origin: URL, device: String, output: URL, statePath: String?) {
    let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    let connection = PreviewConnection(origin: origin, device: device)
    connection.start()
    defer { connection.stop() }
    waitFor("live helper input admitted", seconds: 30) { connection.admitted }
    var image: CGImage?
    waitFor("real simulator framebuffer decoded in AppKit", seconds: 30) {
        if let frame = connection.inbox.take() { image = frame; return true }; return false
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 940),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let surface = DeviceSurface(frame: NSRect(x: 24, y: 24, width: 422, height: 892))
    surface.image = image
    surface.send = { connection.send(tag: $0, payload: $1) }
    window.contentView!.addSubview(surface)
    func snapshot(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if let frame = connection.inbox.take() { surface.image = frame }
        let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
        surface.cacheDisplay(in: surface.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
    guard let statePath else { snapshot("companion-native.png"); return }
    func state() -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return value
    }
    func tap(_ name: String) {
        guard let target = state()[name] as? [String: Double], let x = target["x"], let y = target["y"] else {
            fatalError("input witness did not report target \(name)")
        }
        let rect = surface.geometry.rect
        let local = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        let point = surface.convert(local, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        surface.mouseDown(with: event(.leftMouseDown))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        surface.mouseUp(with: event(.leftMouseUp))
    }
    snapshot("live-initial.png")
    let tapsBefore = state()["taps"] as? Int ?? 0
    tap("button")
    waitFor("AppKit click increments the real iOS button counter") { state()["taps"] as? Int == tapsBefore + 1 }
    tap("field")
    waitFor("AppKit click focuses the real iOS text field") { state()["fieldFocused"] as? Bool == true }
    let textBefore = state()["text"] as? String ?? ""
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
        isARepeat: false, keyCode: 0)!
    surface.keyDown(with: key)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    surface.keyUp(with: key)
    waitFor("native physical-key HID inserts text in the real iOS app") { state()["text"] as? String == textBefore + "a" }
    snapshot("live-typed.png")
    // The runner seeds only this disposable simulator's pasteboard. Exercise
    // the normal hardware Command-V path, including Unicode/emoji readback.
    for (type, usage) in [("down", 227), ("down", 25), ("up", 25), ("up", 227)] {
        connection.send(tag: 6, payload: ["type": type, "usage": usage])
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    }
    waitFor("Command-V pastes Unicode and emoji into the real iOS app", seconds: 12) {
        let text = state()["text"] as? String ?? ""
        // UIKit may insert a space between existing text and a pasted word.
        return text == textBefore + "aArray café 🧪" || text == textBefore + "a Array café 🧪"
    }
    snapshot("live-pasted.png")
    let result: [String: Any] = ["liveSimulator": "PASS", "device": device,
        "input": "AppKit mouse/key events through native helper into UIKit with app-owned state readback",
        "state": state(), "captureWidth": image!.width, "captureHeight": image!.height,
        "hostFrontmostBefore": frontmostBefore,
        "hostFrontmostAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
        "notProven": ["human focus routing", "production canvas lifecycle", "H264 performance"]]
    try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("live-report.json"))
    print("IOS PREVIEW LIVE PROOF: touch, keyboard and Unicode paste PASS")
}

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: PreviewProof --fixtures DIR | --check ORIGIN OUTPUT") }
if args[1] == "--live-check" || args[1] == "--capture-live" {
    guard args.count >= 5, let origin = URL(string: args[2]), UUID(uuidString: args[3]) != nil else {
        fatalError("usage: PreviewProof --live-check ORIGIN DEVICE OUTPUT STATE | --capture-live ORIGIN DEVICE OUTPUT")
    }
    liveProof(origin: origin, device: args[3], output: URL(fileURLWithPath: args[4]),
              statePath: args.count > 5 ? args[5] : nil)
    exit(0)
}
if args[1] == "--fixtures" {
    for dark in [false, true] {
        for changed in [false, true] {
            let name = "\(dark ? "dark" : "light")-\(changed ? "changed" : "initial").jpg"
            try fixtureImage(changed: changed, dark: dark).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
                .write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
        }
    }
    print("Generated labeled fixture images")
    exit(0)
}
guard args[1] == "--check", args.count == 4, let origin = URL(string: args[2]) else { fatalError("invalid arguments") }
let output = URL(fileURLWithPath: args[3])
let connection = PreviewConnection(origin: origin, device: proofDevice)
var firstImage: CGImage?
connection.start()
waitFor("binary input admission received") { connection.admitted }
waitFor("MJPEG decoded into native image") { connection.inbox.take().map { firstImage = $0; return true } ?? false }
require(firstImage?.width == 390 && firstImage?.height == 844, "actual decoded frame dimensions")

// Assertions use explicit expected coordinates, not the implementation's inverse.
let expected = [CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.3, y: 0.2),
                CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.7, y: 0.8)]
for orientation in Orientation.allCases {
    let actual = orientation.rawPoint(CGPoint(x: 0.2, y: 0.7))
    require(abs(actual.x - expected[orientation.rawValue].x) < 0.0001 &&
            abs(actual.y - expected[orientation.rawValue].y) < 0.0001,
            "rotation \(orientation.rawValue) maps to expected raw coordinates")
}
for zoom: CGFloat in [0.25, 0.5, 1, 2] {
    let geometry = ScreenGeometry(bounds: CGRect(x: 15, y: 25, width: 800 * zoom, height: 900 * zoom),
                                  pixels: CGSize(width: 390, height: 844))
    let point = CGPoint(x: geometry.rect.minX + geometry.rect.width * 0.2,
                        y: geometry.rect.minY + geometry.rect.height * 0.7)
    let mapped = geometry.normalized(point)!
    require(abs(mapped.x - 0.2) < 0.0001 && abs(mapped.y - 0.7) < 0.0001,
            "letterboxed screen at scale \(zoom) maps input")
    require(geometry.normalized(CGPoint(x: 16, y: 26)) == nil, "letterbox rejects initial touch at scale \(zoom)")
}

// Feed byte-by-byte data to the same parser used by URLSession.
var splitParser = MJPEGReader()
let tinyPart = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 3\r\n\r\nabc\r\n".utf8)
var parts: [Data] = []
for byte in tinyPart { parts += splitParser.push(Data([byte])) }
require(parts == [Data("abc".utf8)], "multipart frame survives arbitrary network chunk boundaries")
_ = splitParser.push(Data(repeating: 0, count: 4 * 1024 * 1024 + 1))
require(splitParser.rejected == 1, "oversized transport data rejected with bounded storage")
require(splitParser.push(tinyPart) == [Data("abc".utf8)], "parser recovers after oversized input")

let inbox = FrameInbox()
for _ in 0..<1000 { inbox.offer(firstImage!, generation: 0) }
require(inbox.take() != nil && inbox.take() == nil, "1000-frame burst retains one pending frame")
inbox.reset(); inbox.offer(firstImage!, generation: 0)
require(inbox.take() == nil, "prior-generation frame rejected after teardown")

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 940),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let surface = DeviceSurface(frame: NSRect(x: 24, y: 24, width: 422, height: 892))
window.contentView!.addSubview(surface)
surface.image = firstImage
surface.send = { connection.send(tag: $0, payload: $1) }
let rect = surface.geometry.rect
let point = CGPoint(x: rect.midX, y: rect.midY)
let windowPoint = surface.convert(point, to: nil)
func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
surface.mouseDown(with: mouse(.leftMouseDown, windowPoint))
surface.mouseDragged(with: mouse(.leftMouseDragged, surface.convert(CGPoint(x: rect.maxX + 100, y: rect.maxY + 100), to: nil)))
surface.mouseUp(with: mouse(.leftMouseUp, windowPoint))
let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
    isARepeat: false, keyCode: 0)!
surface.keyDown(with: key)
surface.keyUp(with: key)
waitFor("input causes a changed frame over actual loopback transport") {
    if let image = connection.inbox.take() {
        if image.dataProvider!.data! as Data != firstImage!.dataProvider!.data! as Data {
            surface.image = image; return true
        }
    }
    return false
}

func getJSON(_ path: String) -> [String: Any] {
    var result: [String: Any]?
    let session = URLSession(configuration: .ephemeral)
    session.dataTask(with: origin.appendingPathComponent(path)) { data, _, _ in
        if let data {
            DispatchQueue.main.async {
                result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
    }.resume()
    waitFor("fixture response \(path)") { result != nil }
    session.invalidateAndCancel()
    return result!
}
let events = getJSON("events")["events"] as! [[String: Any]]
try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("input-events.json"))
require(events.count >= 5, "fixture received actual binary WebSocket messages")
require(events[0]["tag"] as? Int == 3 && events[0]["type"] as? String == "begin" &&
        abs((events[0]["x"] as! Double) - 0.5) < 0.001 &&
        abs((events[0]["y"] as! Double) - 0.5) < 0.001, "AppKit mouse down reaches helper protocol at screen center")
require(events[1]["x"] as? Double == 1 && events[1]["y"] as? Double == 1,
        "drag leaving screen clamps the active contact")
require(events[2]["type"] as? String == "end", "mouse up releases touch through transport")
require(events.contains { $0["tag"] as? Int == 6 && $0["usage"] as? Int == 4 && $0["type"] as? String == "down" },
        "AppKit physical A key reaches HID protocol")
require(events[4]["tag"] as? Int == 6 && events[4]["type"] as? String == "up",
        "physical key release follows key down in order")
surface.pointer("begin", point: point)
_ = surface.resignFirstResponder()
waitFor("focus loss delivers touch end") {
    let events = getJSON("events")["events"] as! [[String: Any]]
    return events.count >= 7 && events.last?["type"] as? String == "end"
}

func snapshot(_ name: String) {
    surface.needsDisplay = true
    let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
    surface.cacheDisplay(in: surface.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    require(rep.pixelsWide >= 422, "native view snapshot \(name)")
}
snapshot("native-light.png")
_ = getJSON("dark")
waitFor("dark fixture frame decoded") {
    if let image = connection.inbox.take() { surface.image = image; return true }
    return false
}
snapshot("native-dark.png")
connection.stop()
let decodedBefore = connection.framesDecoded
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
require(!connection.admitted && connection.inbox.take() == nil && connection.framesDecoded == decodedBefore,
        "detach clears admission and prevents later frame presentation")
waitFor("fixture observes viewer connections released") {
    let stats = getJSON("events")
    return stats["streams"] as? Int == 0 && stats["sockets"] as? Int == 0
}
window.close()
let report: [String: Any] = ["fixture": "PASS", "liveSimulator": "NOT_VERIFIED",
    "renderer": "native AppKit + ImageIO MJPEG", "input": "AppKit-injected mouse and physical A HID over WebSocket",
    "notProven": ["real simulator input", "human focus", "Unicode/IME/paste", "production canvas lifecycle", "H264 performance"],
    "framesDecoded": decodedBefore]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("fixture-report.json"))
print("IOS PREVIEW PROOF: fixture PASS; live simulator NOT VERIFIED")
