import AppKit
import ContinuumRevivedCore
import Foundation
import ImageIO
import Darwin

@MainActor
protocol IOSPreviewSession: AnyObject {
    var helperPID: Int32? { get }
    var onFrame: ((CGImage) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws
    func send(tag: UInt8, payload: [String: Any])
    func stop()
    func stop(completion: @escaping @MainActor () -> Void)
}

extension IOSPreviewSession {
    var helperPID: Int32? { nil }
    func stop(completion: @escaping @MainActor () -> Void) { stop(); completion() }
}

/// One runtime belongs to one tile/controller. A device has at most one input
/// owner; release a viewer without shutting down its simulator or application.
@MainActor
final class IOSPreviewRuntime {
    enum State: Equatable { case disconnected, connecting, connected, failed(String) }
    static var sessionFactory: () -> any IOSPreviewSession = { IOSPreviewProcessSession() }
    private static var owners: [String: UUID] = [:]
    private static var retiringDevices: Set<String> = []
    private static var retirementWaiters: [String: [@MainActor () -> Void]] = [:]
    let id = UUID()
    let tileID: UUID
    var helperPID: Int32? { session?.helperPID }
    private(set) var state: State = .disconnected { didSet { onChange?() } }
    private(set) var deviceID: String?
    private(set) var receivedFrames = 0
    private(set) var orientation = 1
    var onFrame: ((CGImage) -> Void)?
    var onChange: (() -> Void)?
    private var session: (any IOSPreviewSession)?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var wantsConnection = false
    private var suspended = false

    init(tileID: UUID, deviceID: String?) { self.tileID = tileID; self.deviceID = deviceID }

    func select(_ deviceID: String?) {
        disconnect(); self.deviceID = deviceID; orientation = 1; onChange?()
    }

    func connect(allowBoot: Bool = true) {
        disconnect()
        guard let deviceID, UUID(uuidString: deviceID) != nil else {
            state = .failed("Choose a simulator first."); return
        }
        wantsConnection = true; suspended = false; state = .connecting
        let generation = self.generation
        let start: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == generation, self.wantsConnection else { return }
            self.beginConnection(deviceID: deviceID, allowBoot: allowBoot, generation: generation)
        }
        if Self.retiringDevices.contains(deviceID) {
            Self.retirementWaiters[deviceID, default: []].append(start)
        } else { start() }
    }

    private func beginConnection(deviceID: String, allowBoot: Bool, generation: Int) {
        guard Self.owners[deviceID] == nil else {
            wantsConnection = false
            state = .failed("This simulator is connected to another preview. Disconnect it there first."); return
        }
        Self.owners[deviceID] = id
        let connection = Self.sessionFactory()
        session = connection
        connection.onFrame = { [weak self] frame in
            guard let self, self.generation == generation else { return }
            self.receivedFrames += 1
            if self.state != .connected { self.state = .connected }
            self.onFrame?(frame)
        }
        connection.onFailure = { [weak self] message in
            guard let self, self.generation == generation else { return }
            self.disconnect(); self.state = .failed(message)
        }
        task = Task { [weak self] in
            do { try await connection.start(deviceID: deviceID, allowBoot: allowBoot, orientation: self?.orientation ?? 1) }
            catch {
                guard let self, self.generation == generation else { return }
                self.disconnect()
                if !(error is CancellationError) { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    func disconnect() {
        generation += 1; task?.cancel(); task = nil
        let retiring = session; session = nil
        retiring?.onFrame = nil; retiring?.onFailure = nil
        wantsConnection = false; state = .disconnected
        guard let retiring else { return }
        guard let deviceID, Self.owners[deviceID] == id else { retiring.stop(); return }
        let owner = id
        Self.retiringDevices.insert(deviceID)
        retiring.stop {
            // An exited helper can no longer drain queued HID commands into a
            // replacement session controlling the same simulator.
            if Self.owners[deviceID] == owner { Self.owners.removeValue(forKey: deviceID) }
            Self.retiringDevices.remove(deviceID)
            let waiters = Self.retirementWaiters.removeValue(forKey: deviceID) ?? []
            for waiter in waiters { waiter() }
        }
    }
    func suspend() {
        guard !suspended else { return }
        let wanted = wantsConnection
        disconnect(); wantsConnection = wanted; suspended = true
    }
    func resume() {
        guard suspended else { return }; suspended = false
        if wantsConnection { connect(allowBoot: false) }
    }
    func send(tag: UInt8, payload: [String: Any]) {
        guard state == .connected else { return }
        session?.send(tag: tag, payload: payload)
    }
    func rotate() {
        orientation = orientation == 1 ? 3 : 1
        send(tag: 7, payload: ["orientation": orientation]); onChange?()
    }
    func home() { send(tag: 4, payload: ["button": "home"]) }
    func paste(_ text: String) { send(tag: 8, payload: ["text": text]) }
}

/// Native addon loading stays in a supervised Node process. Only authenticated
/// loopback frame/input endpoints reach this process; no shell endpoint exists.
@MainActor
final class IOSPreviewProcessSession: NSObject, IOSPreviewSession {
    static var captureFramesPerSecond = 30
    var onFrame: ((CGImage) -> Void)?
    var onFailure: ((String) -> Void)?
    var helperPID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    private var process: Process?
    private var directory: URL?
    private var session: URLSession?
    private var stream: URLSessionDataTask?
    private var socket: URLSessionWebSocketTask?
    private var token = ""
    private var active = false
    private var admitted = false
    private var waitingImage: CGImage?
    private var openedAt = Date()
    private var outgoing: [Data] = []
    private var sending = false
    private var streamReceiver: IOSPreviewStreamReceiver?
    private let decoder = IOSPreviewFrameDecoder()
    private var logHandle: FileHandle?
    private var timer: Timer?
    private var lastFrame = Date()

    func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws {
        active = true
        let devices = try await IOSPreviewTools.devices()
        try Task.checkCancellation()
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            throw IOSPreviewError.unavailable("The selected simulator is unavailable. Choose another device.")
        }
        if !device.isBooted {
            guard allowBoot else { throw IOSPreviewError.unavailable("Simulator stopped. Connect to start it again.") }
            _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "boot", deviceID])
        }
        _ = try await IOSPreviewCommands.run(["/usr/bin/xcrun", "simctl", "bootstatus", deviceID, "-b"])
        try Task.checkCancellation()
        let tools = try await IOSPreviewTools.shared.installation()
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-ios-viewer-\(UUID())")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        token = UUID().uuidString + UUID().uuidString
        let ready = directory.appendingPathComponent("ready.json")
        let config = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["device": deviceID, "token": token, "orientation": orientation, "frameRate": Self.captureFramesPerSecond,
            "addon": tools.addon.path, "ws": tools.ws.path, "readyFile": ready.path]).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let log = directory.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = tools.node
        process.arguments = [tools.bridge.path, config.path]
        process.environment = ToolEnvironment.shared.environment()
        process.standardOutput = logHandle; process.standardError = logHandle
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.fail("Preview helper disconnected. Connect to try again.")
            }
        }
        self.process = process
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        var origin: URL?
        while origin == nil {
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
            if let data = try? Data(contentsOf: ready),
               let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let string = response["origin"] as? String {
                guard response["keyboard"] as? Bool != false else {
                    throw IOSPreviewError.unavailable("Keyboard input is unavailable for this simulator. Update Xcode and reconnect.")
                }
                origin = URL(string: string)
            }
            guard process.isRunning, Date() < deadline else {
                throw IOSPreviewError.unavailable("Preview helper could not connect to this Xcode simulator. Try Connect again.")
            }
            if origin == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let origin, origin.host == "127.0.0.1", origin.scheme == "http" else {
            throw IOSPreviewError.unavailable("Preview helper returned an invalid local address.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        let receiver = IOSPreviewStreamReceiver(decoder: decoder, onFrame: { [weak self] image in
            guard let self, self.active else { return }
            self.lastFrame = Date()
            if self.admitted { self.onFrame?(image) } else { self.waitingImage = image }
        }, onFailure: { [weak self] message in self?.fail(message) })
        streamReceiver = receiver
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: receiver.delegateQueue)
        self.session = session
        var request = URLRequest(url: origin.appendingPathComponent("helper/\(deviceID)/stream.mjpeg"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        stream = session.dataTask(with: request); stream?.resume()
        var components = URLComponents(url: origin.appendingPathComponent("helper/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = "ws"; components.queryItems = [URLQueryItem(name: "device", value: deviceID)]
        request.url = components.url
        socket = session.webSocketTask(with: request); socket?.resume(); receive()
        lastFrame = Date()
        openedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                if Date().timeIntervalSince(self.lastFrame) > 20 || (!self.admitted && Date().timeIntervalSince(self.openedAt) > 20) {
                    self.fail("Preview stopped receiving frames or input. Connect to try again.")
                }
            }
        }
    }

    private func receive() {
        let socket = self.socket
        Task { [weak self] in
            do {
                guard let value = try await socket?.receive(), let self, self.active else { return }
                if case .data(let data) = value {
                    if data.first == 0x83 {
                        self.admitted = true
                        if let image = self.waitingImage { self.waitingImage = nil; self.onFrame?(image) }
                    }
                    if data.first == 0x91 {
                        self.fail("Simulator input failed. Reconnect the preview."); return
                    }
                }
                self.receive()
            } catch { self?.fail("Preview disconnected. Connect to try again.") }
        }
    }
    func send(tag: UInt8, payload: [String: Any]) {
        guard active, admitted, let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        guard outgoing.count < 128, body.count < 60000 else { fail("Preview input is too large or fell behind. Reconnect to continue."); return }
        outgoing.append(Data([tag]) + body)
        guard !sending else { return }; sending = true
        let socket = self.socket
        Task { [weak self] in
            guard let self else { return }; defer { self.sending = false }
            while self.active, !self.outgoing.isEmpty {
                let data = self.outgoing.removeFirst()
                do { try await socket?.send(.data(data)) }
                catch { self.fail("Preview input disconnected. Connect to try again."); break }
            }
        }
    }
    private func fail(_ message: String) { guard active else { return }; onFailure?(message) }
    func stop() { stop(completion: {}) }
    func stop(completion: @escaping @MainActor () -> Void) {
        active = false; admitted = false; waitingImage = nil
        streamReceiver?.stop(); streamReceiver = nil; decoder.reset(); outgoing.removeAll()
        timer?.invalidate(); timer = nil
        stream?.cancel(); socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel(); session = nil; stream = nil; socket = nil
        let process = self.process; self.process = nil
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? logHandle?.close(); logHandle = nil
        let directory = self.directory; self.directory = nil
        DispatchQueue.global().async {
            if let process, process.processIdentifier > 0 { process.waitUntilExit() }
            if let directory { try? FileManager.default.removeItem(at: directory) }
            DispatchQueue.main.async { completion() }
        }
    }
}

/// Decode work never builds a frame queue. At most one compressed frame waits
/// behind the current decode, and at most one presentation waits on the main actor.
final class IOSPreviewFrameDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "array.ios-preview.decode", qos: .userInitiated)
    private var pending: (Data, @MainActor (CGImage) -> Void, Int)?
    private var decoding = false
    private var image: (CGImage, @MainActor (CGImage) -> Void, Int)?
    private var scheduled = false
    private var epoch = 0
    struct Metrics {
        var offered = 0
        var decoded = 0
        var presented = 0
        var replacedCompressed = 0
        var replacedPresentation = 0
        var rejectedDimensions = 0
        var compressedHighWater = 0
        var presentationHighWater = 0
    }
    private var counters = Metrics()
    var metrics: Metrics { lock.withLock { counters } }
    var generation: Int { lock.withLock { epoch } }
    /// Offline worker witness barrier; production presentation never blocks here.
    func waitForPendingDecode() { queue.sync {} }
    func reset() { lock.withLock { epoch += 1; pending = nil; image = nil } }
    func offer(_ data: Data, present: @escaping @MainActor (CGImage) -> Void) {
        let starts = lock.withLock { () -> Bool in
            counters.offered += 1
            if pending != nil { counters.replacedCompressed += 1 }
            pending = (data, present, epoch)
            counters.compressedHighWater = max(counters.compressedHighWater, 1)
            if decoding { return false }; decoding = true; return true
        }
        if starts { queue.async { self.drain() } }
    }
    private func drain() {
        while let next = lock.withLock({ () -> (Data, @MainActor (CGImage) -> Void, Int)? in
            let value = pending; pending = nil
            if value == nil { decoding = false }; return value
        }) {
            guard let source = CGImageSourceCreateWithData(next.0 as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            guard width > 0, height > 0, width <= 4096, height <= 4096, width <= 4_000_000 / height else {
                lock.withLock { counters.rejectedDimensions += 1 }; continue
            }
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
            let schedules = lock.withLock { () -> Bool in
                counters.decoded += 1
                guard next.2 == epoch else { return false }
                if image != nil { counters.replacedPresentation += 1 }
                counters.presentationHighWater = max(counters.presentationHighWater, 1)
                image = (decoded, next.1, next.2)
                if scheduled { return false }; scheduled = true; return true
            }
            if schedules {
                DispatchQueue.main.async {
                    let value = self.lock.withLock { () -> (CGImage, @MainActor (CGImage) -> Void, Int)? in
                        self.scheduled = false
                        let result = self.image; self.image = nil
                        guard result?.2 == self.epoch else { return nil }
                        if result != nil { self.counters.presented += 1 }
                        return result
                    }
                    if let value { value.1(value.0) }
                }
            }
        }
    }
}
