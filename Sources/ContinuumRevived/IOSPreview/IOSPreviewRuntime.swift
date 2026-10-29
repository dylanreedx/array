import AppKit
import ContinuumRevivedCore
import Foundation
import ImageIO
import Darwin

@MainActor
protocol IOSPreviewSession: AnyObject {
    var helperPID: Int32? { get }
    var encodedFrameRate: Int? { get }
    func setReducedCapture(_ reduced: Bool)
    var onFrame: ((CGImage) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws
    func send(tag: UInt8, payload: [String: Any])
    func observe() async throws -> IOSPreviewObservation
    func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int?) async throws
    func acknowledgedAction(_ action: IOSPreviewBoundedAction, geometryGeneration: Int?) async throws
    func stop()
    func stop(completion: @escaping @MainActor () -> Void)
}

extension IOSPreviewSession {
    var helperPID: Int32? { nil }
    var encodedFrameRate: Int? { nil }
    func setReducedCapture(_ reduced: Bool) {}
    func observe() async throws -> IOSPreviewObservation { throw IOSPreviewObservation.Failure.unavailable }
    func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int?) async throws { throw IOSPreviewActionChannel.Failure.rejected }
    func acknowledgedAction(_ action: IOSPreviewBoundedAction, geometryGeneration: Int?) async throws {
        if case let .tap(x, y) = action {
            try await acknowledgedTap(x: x, y: y, geometryGeneration: geometryGeneration)
        } else { throw IOSPreviewActionChannel.Failure.rejected }
    }
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
    var encodedFrameRate: Int? { session?.encodedFrameRate }
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
    private var automationRetained = false
    private var automationBuildActive = false
    private(set) var automationController: String?
    private(set) var connectionID = UUID()
    private(set) var controlGeneration: UInt64 = 0
    var onAutomationInvalidated: (() -> Void)?
    var onHumanTakeover: (() -> Void)?

    init(tileID: UUID, deviceID: String?) { self.tileID = tileID; self.deviceID = deviceID }

    static func waitForRetirement(deviceID: String) async {
        await withCheckedContinuation { continuation in
            if retiringDevices.contains(deviceID) { retirementWaiters[deviceID, default: []].append { continuation.resume() } }
            else { continuation.resume() }
        }
    }
    func select(_ deviceID: String?) {
        disconnect(); self.deviceID = deviceID; orientation = 1; onChange?()
    }

    func connect(allowBoot: Bool = true, retainingForAutomation: Bool = false, controllerName: String? = nil) {
        disconnect()
        if retainingForAutomation { automationRetained = true; automationController = controllerName }
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
        connectionID = UUID()
        automationRetained = false; automationBuildActive = false; automationController = nil
        let invalidated = onAutomationInvalidated; onAutomationInvalidated = nil
        onHumanTakeover = nil; invalidated?()
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
        suspended = true
        updateCaptureDemand()
        guard !automationRetained else { return }
        let wanted = wantsConnection
        disconnect(); wantsConnection = wanted; suspended = true
    }
    func resume() {
        guard suspended else { return }; suspended = false
        updateCaptureDemand()
        if wantsConnection, state != .connected, state != .connecting { connect(allowBoot: false) }
    }
    func setAutomationRetained(_ retained: Bool, controllerName: String? = nil) {
        guard automationRetained != retained else { return }
        automationRetained = retained
        automationController = retained ? controllerName : nil
        updateCaptureDemand()
        defer { onChange?() }
        if !retained, suspended {
            let wanted = wantsConnection
            disconnect(); wantsConnection = wanted; suspended = true
        }
    }
    func retireViewer() {
        onFrame = nil; onChange = nil
        suspended = true
        updateCaptureDemand()
        if !automationRetained { disconnect() }
    }
    func setAutomationBuildActive(_ active: Bool) {
        automationBuildActive = active
        updateCaptureDemand()
    }
    private func updateCaptureDemand() {
        session?.setReducedCapture(automationRetained && automationBuildActive && suspended)
    }
    func allowAutomationHandover() {
        IOSPreviewAutomationSessions.shared.allowAutomation(deviceID: deviceID)
        onChange?()
    }
    func humanInputBegan() {
        controlGeneration &+= 1
        onHumanTakeover?()
    }
    func observe() async throws -> IOSPreviewObservation {
        guard state == .connected, let session else { throw IOSPreviewObservation.Failure.unavailable }
        let connection = connectionID
        let observation = try await session.observe()
        guard connectionID == connection, state == .connected else { throw IOSPreviewObservation.Failure.unavailable }
        return observation
    }
    func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int) async throws {
        guard state == .connected, let session else { throw IOSPreviewActionChannel.Failure.rejected }
        try await session.acknowledgedTap(x: x, y: y, geometryGeneration: geometryGeneration)
    }
    func acknowledgedAction(_ action: IOSPreviewBoundedAction, geometryGeneration: Int) async throws {
        guard state == .connected, let session else { throw IOSPreviewActionChannel.Failure.rejected }
        try await session.acknowledgedAction(action, geometryGeneration: geometryGeneration)
        if case let .rotate(value) = action { orientation = value; onChange?() }
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
    private(set) var encodedFrameRate: Int?
    private var reducedCapture = false
    private var captureProfileGeneration = 0
    private var captureProfileAcknowledged = 0
    private var captureProfileTask: Task<Void, Never>?
    func setReducedCapture(_ reduced: Bool) {
        guard active, admitted, reducedCapture != reduced else { return }
        reducedCapture = reduced
        captureProfileGeneration += 1
        let expected = captureProfileGeneration
        captureProfileTask?.cancel()
        guard enqueue(tag: 0x21, payload: ["profile": reduced ? "build_idle" : "interactive", "generation": expected]) else {
            fail("Simulator capture profile failed. Reconnect the preview."); return
        }
        captureProfileTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.active, self.captureProfileAcknowledged < expected else { return }
            self.fail("Simulator capture profile timed out. Reconnect the preview.")
        }
    }
    private var process: Process?
    private var directory: URL?
    private var session: URLSession?
    private var stream: URLSessionDataTask?
    private var socket: URLSessionWebSocketTask?
    private var token = ""
    private var observationURL: URL?
    private var observationTask: Task<IOSPreviewObservation, Error>?
    private var observationSession: URLSession?
    private var active = false
    private let actions = IOSPreviewActionChannel()
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
        actions.onUncertain = { [weak self] in
            self?.fail("Simulator action completion is unknown. Reconnect and observe before acting again.")
        }
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
        observationURL = origin.appendingPathComponent("helper/\(deviceID)/fresh.jpg")
        let snapshotConfiguration = URLSessionConfiguration.ephemeral
        snapshotConfiguration.timeoutIntervalForRequest = 5
        snapshotConfiguration.timeoutIntervalForResource = 5
        observationSession = URLSession(configuration: snapshotConfiguration)
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
                    if data.first == 0x85 {
                        guard let value = try? JSONSerialization.jsonObject(with: Data(data.dropFirst())) as? [String: Any],
                              let rate = value["frameRate"] as? Int, [1, 15, 30, 60].contains(rate),
                              let generation = value["generation"] as? Int, generation >= self.captureProfileAcknowledged,
                              generation <= self.captureProfileGeneration else {
                            self.fail("Simulator capture profile failed. Reconnect the preview."); return
                        }
                        self.encodedFrameRate = rate
                        self.captureProfileAcknowledged = generation
                        if generation == self.captureProfileGeneration { self.captureProfileTask?.cancel(); self.captureProfileTask = nil }
                    }
                    if let tag = data.first, self.actions.receive(tag: tag, body: Data(data.dropFirst())) {
                        self.receive(); return
                    }
                    if data.first == 0x91 {
                        self.fail("Simulator input failed. Reconnect the preview."); return
                    }
                }
                self.receive()
            } catch { self?.fail("Preview disconnected. Connect to try again.") }
        }
    }
    func observe() async throws -> IOSPreviewObservation {
        guard active, admitted, let url = observationURL, let transport = observationSession else { throw IOSPreviewObservation.Failure.unavailable }
        guard observationTask == nil else { throw IOSPreviewObservation.Failure.busy }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = Task {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            let receivedAt = Date()
            return try await Task.detached(priority: .userInitiated) {
                try IOSPreviewObservation.decode(data, response: response, receivedAt: receivedAt)
            }.value
        }
        observationTask = task
        defer { observationTask = nil }
        return try await withTaskCancellationHandler {
            let observation = try await task.value
            try Task.checkCancellation()
            guard active else { throw IOSPreviewObservation.Failure.unavailable }
            return observation
        } onCancel: { task.cancel() }
    }
    /// Raw normalized framebuffer coordinates. The host device adapter owns
    /// image-space transforms, observation epochs, grants and human takeover.
    func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int? = nil) async throws {
        try await acknowledgedAction(.tap(x: x, y: y), geometryGeneration: geometryGeneration)
    }
    func acknowledgedAction(_ action: IOSPreviewBoundedAction, geometryGeneration: Int?) async throws {
        guard active, admitted, var payload = action.payload else { throw IOSPreviewActionChannel.Failure.rejected }
        if let geometryGeneration { payload["geometryGeneration"] = geometryGeneration }
        try await actions.perform { id in
            payload["requestID"] = id
            return enqueue(tag: 0x20, payload: payload)
        }
    }
    func send(tag: UInt8, payload: [String: Any]) {
        _ = enqueue(tag: tag, payload: payload)
    }
    @discardableResult
    private func enqueue(tag: UInt8, payload: [String: Any]) -> Bool {
        guard active, admitted, let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard outgoing.count < 128, body.count < 60000 else { fail("Preview input is too large or fell behind. Reconnect to continue."); return false }
        outgoing.append(Data([tag]) + body)
        guard !sending else { return true }; sending = true
        let socket = self.socket
        Task { [weak self] in
            guard let self else { return }; defer { self.sending = false }
            while self.active, !self.outgoing.isEmpty {
                let data = self.outgoing.removeFirst()
                do { try await socket?.send(.data(data)) }
                catch { self.fail("Preview input disconnected. Connect to try again."); break }
            }
        }
        return true
    }
    private func fail(_ message: String) {
        guard active else { return }
        actions.invalidate()
        onFailure?(message)
        if active { stop() }
    }
    func stop() { stop(completion: {}) }
    func stop(completion: @escaping @MainActor () -> Void) {
        captureProfileTask?.cancel(); captureProfileTask = nil
        actions.invalidate()
        observationTask?.cancel(); observationTask = nil
        observationSession?.invalidateAndCancel(); observationSession = nil; observationURL = nil
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
