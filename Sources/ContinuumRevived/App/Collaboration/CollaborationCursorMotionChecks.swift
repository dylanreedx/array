import AppKit
import Network
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A teammate's cursor, end to end, over a network as slow as the real relay.
///
/// Everything is production except the network: the real `continuum-relay`
/// (built beside Array) on loopback, reached through a proxy that holds every
/// byte 50 ms each way (a 100 ms round trip; production measured 60-110 ms).
/// Peer A's publisher is driven by posted 60 Hz mouse events; peer B's
/// controller, publisher and overlay draw what arrives, one display frame at a
/// time at 60 Hz and at 120 Hz (ProMotion). The fixture windows sit off every
/// display, where display links do not tick, so the check steps the overlay's
/// own frame callback at the display's cadence.
///
/// It runs twice: on update pages alone (a relay or network without the cursor
/// lane — the fallback, and how every cursor moved before the lane), then with
/// the cursor lane. For each it reports, on B's painted overlay:
/// - display frames on which A's cursor moved, as a share of all frames;
/// - distinct positions B received per second;
/// - how long after A's mouse stopped B painted the final position.
@MainActor
enum CollaborationCursorMotionChecks {
    private typealias Rig = SharedAreaCheckRig
    static let oneWay: TimeInterval = 0.05

    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Rig.Failure(description: "cursor motion: \(message)") }
        print("PASS cursor motion: \(message)")
    }

    // MARK: - The network

    /// A loopback TCP proxy that delivers every chunk `oneWay` after it arrived,
    /// in order, in both directions. HTTP and WebSocket bytes alike.
    final class DelayProxy: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "dev.arrayapp.cursor-motion.proxy")
        private let upstream: NWEndpoint.Port
        private let delay: TimeInterval
        private var connections: [NWConnection] = []
        var port: Int { Int(listener.port?.rawValue ?? 0) }

        init(upstream: Int, oneWay: TimeInterval) throws {
            self.upstream = NWEndpoint.Port(rawValue: UInt16(upstream))!
            delay = oneWay
            listener = try NWListener(using: Self.parameters(), on: .any)
        }
        private static func parameters() -> NWParameters {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return parameters
        }
        func start() async throws {
            let ready = LaneSwitch()
            listener.stateUpdateHandler = { state in if case .ready = state { ready.enabled = true } }
            listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
            listener.start(queue: queue)
            let deadline = Date().addingTimeInterval(5)
            while !ready.enabled {
                guard Date() < deadline else { throw Rig.Failure(description: "cursor motion: the delay proxy did not listen") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func stop() {
            queue.sync {
                listener.cancel()
                for connection in connections { connection.cancel() }
                connections = []
            }
        }
        private func accept(_ client: NWConnection) {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let server = NWConnection(host: "127.0.0.1", port: upstream, using: NWParameters(tls: nil, tcp: tcp))
            connections += [client, server]
            client.start(queue: queue); server.start(queue: queue)
            pump(client, server); pump(server, client)
        }
        private func pump(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    queue.asyncAfter(deadline: .now() + delay) { to.send(content: data, completion: .contentProcessed { _ in }) }
                }
                if complete || error != nil {
                    queue.asyncAfter(deadline: .now() + delay) {
                        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in to.cancel() })
                    }
                    return
                }
                pump(from, to)
            }
        }
    }

    /// The production transport, with the cursor lane switchable: off, the
    /// relay is reached exactly as one that predates the lane would be.
    final class LaneSwitch: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        var enabled: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
    }
    struct Transport: SharedAreaControllerTransport {
        let base: any SharedAreaControllerTransport
        let lane: LaneSwitch
        func identity() async throws -> Collaboration.Identity { try await base.identity() }
        func state() async throws -> Collaboration.State { try await base.state() }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await base.connection(initial: initial) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await base.apply(mutation) }
        func beginPresence() async throws -> Collaboration.PresenceSession { try await base.beginPresence() }
        func publishPresence(_ input: Collaboration.PresenceInput) async throws { try await base.publishPresence(input) }
        func endPresence(_ session: UUID) async throws { try await base.endPresence(session) }
        func reportUsage(_ report: Collaboration.UsageReport) async throws { try await base.reportUsage(report) }
        func openCursorLane() async throws -> any SharedAreaCursorLane {
            // What a relay without the lane answers to the upgrade.
            guard lane.enabled else { throw CollaborationClientError.server(status: 404, code: "cursorLaneRefused") }
            return try await base.openCursorLane()
        }
    }

    // MARK: - The run

    struct Measurement {
        let lane: Bool, fps: Int
        let movedShare: Double, framesSampled: Int, meanStep: Double, maxStep: Double
        let positionsPerSecond: Double, changesPerSecond: Double
        let lagMedian: Double, finalPaintedAfter: Double?
        let frameCostMedian: Double, frameCostMax: Double
        var line: String {
            String(format: "%@ at %d Hz: cursor moved on %.1f%% of %d frames (mean step %.2f pt, max %.2f pt); B received %.1f positions/s and %.1f scene changes/s; drawn behind the mouse median %.0f ms; final position painted %@ after the mouse stopped; one frame (advance + paint) median %.3f ms max %.3f ms",
                lane ? "cursor lane" : "update pages only", fps, movedShare * 100, framesSampled, meanStep, maxStep,
                positionsPerSecond, changesPerSecond, lagMedian, finalPaintedAfter.map { String(format: "%.0f ms", $0) } ?? "never (>3 s)",
                frameCostMedian, frameCostMax)
        }
    }

    static func run(delegate: AppDelegate) async throws {
        let root = try Rig.root("cursor-motion")
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = try ShareEntryRelayChecks.Relay(root: root.appendingPathComponent("relay"))
        defer { relay.stop() }
        try await relay.start()
        let proxy = try DelayProxy(upstream: relay.port, oneWay: oneWay)
        defer { proxy.stop() }
        try await proxy.start()

        // Two people and an area, set up directly on the relay.
        let direct = URL(string: "http://127.0.0.1:\(relay.port)")!
        let signup = try CollaborationAPI(baseURL: direct, allowsInsecureLoopback: true)
        let credentialA = try await signup.selfEnroll(.init(displayName: "Peer A", deviceLabel: "Peer A's Mac"))
        let credentialB = try await signup.selfEnroll(.init(displayName: "Peer B", deviceLabel: "Peer B's Mac"))
        let apiA = try CollaborationAPI(baseURL: direct, credential: credentialA.token, allowsInsecureLoopback: true)
        let apiB = try CollaborationAPI(baseURL: direct, credential: credentialB.token, allowsInsecureLoopback: true)
        let area = try await apiA.createArea().document.id
        _ = try await apiB.accept(code: try await apiA.invite(area: area.rawValue, request: .init(person: credentialB.identity.person)).code)
        let a = credentialA.identity, b = credentialB.identity

        // Production controllers on the delayed endpoint.
        let endpoint = try CollaborationServiceEndpoint(URL(string: "http://127.0.0.1:\(proxy.port)")!, allowsInsecureLoopback: true)
        let lane = LaneSwitch()
        func controller(_ name: String, _ credential: Collaboration.Credential) throws -> SharedAreaController {
            let credentials = CollaborationCredentialStore(vault: Rig.MemoryVault(), bundleIdentifier: nil)
            let scope = CollaborationCredentialScope(endpoint: endpoint, identity: credential.identity)
            try credentials.save(credential, for: scope)
            let cache = try SharedAreaLocalStore(applicationSupportRoot: root.appendingPathComponent(name), bundleIdentifier: nil,
                endpoint: endpoint, person: credential.identity.person, area: area)
            return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope, bundleIdentifier: nil,
                transportFactory: { endpoint, credential, area in
                    Transport(base: try SharedAreaController.liveTransport(endpoint: endpoint, credential: credential, area: area), lane: lane)
                })
        }
        let modelA = try controller("a", credentialA), modelB = try controller("b", credentialB)

        func window() -> (NSWindow, NSView) {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 700)); window.contentView = host
            window.orderFrontOffscreenForChecks()
            return (window, host)
        }
        let (windowA, hostA) = window(), (windowB, hostB) = window()
        let sceneA = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: modelA, person: a.person, in: hostA)
        let sceneB = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: modelB, person: b.person, in: hostB)
        hostA.layoutSubtreeIfNeeded(); hostB.layoutSubtreeIfNeeded()
        // Motion on, whatever this Mac's accessibility setting; Reduce Motion is
        // asserted separately below.
        sceneA.reduceMotion = { false }; sceneB.reduceMotion = { false }
        await modelA.open(); await modelB.open()
        try sceneA.setCamera(.init(x: 0, y: 0, zoom: 1)); try sceneB.setCamera(.init(x: 0, y: 0, zoom: 1))
        let publisherA = SharedAreaPresencePublisher(scene: sceneA), publisherB = SharedAreaPresencePublisher(scene: sceneB)
        publisherA.start(); publisherB.start()
        defer {
            publisherA.stop(); publisherB.stop(); sceneA.unmount(); sceneB.unmount()
            windowA.close(); windowB.close()
        }
        let overlay = publisherB.overlay
        try await Rig.eventually("both peers connected", attempts: 2000) { modelA.status == .connected && modelB.status == .connected }
        try await Rig.eventually("both peers settle on update pages", attempts: 1000) {
            modelA.cursorLaneState == .off && modelB.cursorLaneState == .off
        }
        try expect(modelA.status == .connected && modelB.status == .connected,
            "a relay that refuses the lane leaves both peers connected on update pages")

        // What B's model received for A: every distinct position, from pages
        // and lane alike, and every whole-scene change notification.
        var received: [(CFTimeInterval, Double)] = [], changes: [CFTimeInterval] = []
        var lastReceived: Collaboration.Point?
        func noteReceived() {
            guard let cursor = modelB.presence.first(where: { $0.identity.device == a.device })?.cursor, cursor != lastReceived else { return }
            lastReceived = cursor; received.append((CACurrentMediaTime(), cursor.x))
        }
        let changeObserver = modelB.addChangeObserver { changes.append(CACurrentMediaTime()); noteReceived() }
        let cursorObserver = modelB.addCursorObserver { _ in noteReceived() }
        defer { modelB.removeChangeObserver(changeObserver); modelB.removeCursorObserver(cursorObserver) }

        // A's mouse, in A's area coordinates (zoom 1, so points), through the
        // event queue the publisher's local monitor reads.
        func post(areaX: Double, areaY: Double = 300) {
            let location = sceneA.convert(sceneA.screenPoint(forAreaPoint: .init(x: areaX, y: areaY)), to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowA.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        /// One display frame on B: the overlay's own frame callback (its link
        /// cannot fire off every display), then the display pass. Returns what
        /// B painted for A, in area coordinates, and what the frame cost.
        func frame() -> (CGPoint?, Double) {
            let began = CACurrentMediaTime()
            if overlay.isAnimating { overlay.advanceFrame() }
            CATransaction.begin(); overlay.displayIfNeeded(); CATransaction.commit()
            let cost = (CACurrentMediaTime() - began) * 1000
            CATransaction.flush()
            guard let point = overlay.drawnCursors[a.device] else { return (nil, cost) }
            return (sceneB.areaPoint(forScreenPoint: overlay.convert(point, to: sceneB)), cost)
        }
        let reach = sceneA.areaPoint(forScreenPoint: publisherA.overlay.convert(NSPoint(x: publisherA.overlay.bounds.maxX - 40, y: 0), to: sceneA)).x

        func measure(fps: Int) async throws -> Measurement {
            let period = 1.0 / Double(fps), mousePeriod = 1.0 / 60
            // Settle at the start of the stroke.
            let startX = 60.0, speed = 150.0, duration = 3.0
            post(areaX: startX)
            try await Rig.eventually("B paints A's cursor at the start", attempts: 1000) { frame().0.map { abs($0.x - startX) < 0.5 } ?? false }
            try await Task.sleep(for: .milliseconds(300))
            try expect(startX + speed * duration < reach, "the stroke stays inside A's shared area (ends at \(Int(startX + speed * duration)) of \(Int(reach)))")

            var samples: [(t: Double, drawn: Double, mouse: Double)] = [], costs: [Double] = []
            let start = CACurrentMediaTime()
            var nextFrame = start, nextMouse = start, lastPosted = startX
            while true {
                let now = CACurrentMediaTime(), t = now - start
                if t > duration { break }
                if now >= nextMouse {
                    lastPosted = startX + speed * t; post(areaX: lastPosted)
                    nextMouse += mousePeriod
                }
                if now >= nextFrame {
                    let (drawn, cost) = frame()
                    costs.append(cost)
                    if let drawn { samples.append((t, drawn.x, startX + speed * (CACurrentMediaTime() - start))) }
                    // A display that falls behind drops a frame; it never shows two at once.
                    nextFrame = max(nextFrame + period, CACurrentMediaTime() + period / 2)
                }
                let wake = min(nextFrame, nextMouse) - CACurrentMediaTime()
                if wake > 0 { try await Task.sleep(for: .microseconds(Int(wake * 1_000_000))) } else { await Task.yield() }
            }
            let stopped = CACurrentMediaTime(), finalX = lastPosted
            var landed: Double?
            for _ in 0..<(3 * fps) {
                if let drawn = frame().0, abs(drawn.x - finalX) < 0.5 { landed = (CACurrentMediaTime() - stopped) * 1000; break }
                try await Task.sleep(for: .microseconds(Int(period * 1_000_000)))
            }

            let steady = samples.filter { $0.t > 0.6 }
            let steps = zip(steady, steady.dropFirst()).map { $1.drawn - $0.drawn }
            let moved = steps.filter { abs($0) > 0.05 }.count
            let window = (start + 0.6, stopped)
            let seconds = window.1 - window.0
            let lags = steady.map { ($0.mouse - $0.drawn) / speed * 1000 }.sorted()
            let sortedCosts = costs.sorted()
            return Measurement(lane: lane.enabled, fps: fps,
                movedShare: steps.isEmpty ? 0 : Double(moved) / Double(steps.count), framesSampled: steps.count,
                meanStep: steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count), maxStep: steps.max() ?? 0,
                positionsPerSecond: Double(received.filter { $0.0 >= window.0 && $0.0 <= window.1 }.count) / seconds,
                changesPerSecond: Double(changes.filter { $0 >= window.0 && $0 <= window.1 }.count) / seconds,
                lagMedian: lags.isEmpty ? 0 : lags[lags.count / 2], finalPaintedAfter: landed,
                frameCostMedian: sortedCosts.isEmpty ? 0 : sortedCosts[sortedCosts.count / 2], frameCostMax: sortedCosts.last ?? 0)
        }

        // Before: update pages only.
        var results: [Measurement] = []
        for fps in [60, 120] { results.append(try await measure(fps: fps)) }

        // After: the cursor lane. Reopening is how a view meets a relay again.
        lane.enabled = true
        await modelA.open(); await modelB.open()
        try await Rig.eventually("both peers reconnected with the cursor lane open", attempts: 2000) {
            modelA.status == .connected && modelB.status == .connected && modelA.cursorLaneState == .live && modelB.cursorLaneState == .live
        }
        let laneFramesBefore = modelB.cursorLaneFramesApplied
        for fps in [60, 120] { results.append(try await measure(fps: fps)) }
        let laneFrames = modelB.cursorLaneFramesApplied - laneFramesBefore

        for result in results { print("MEASURE cursor motion (one-way \(Int(oneWay * 1000)) ms, real continuum-relay): \(result.line)") }

        let pages = results.filter { !$0.lane }, lanes = results.filter(\.lane)
        for result in pages {
            try expect(result.finalPaintedAfter.map { $0 < 600 } == true,
                "update pages alone still land A's final position within 600 ms at \(result.fps) Hz")
        }
        try expect(laneFrames > 0, "B applied \(laneFrames) positions from the cursor lane")
        for result in lanes {
            try expect(result.movedShare >= 0.95,
                String(format: "with the lane, B's cursor moves on at least 95%% of display frames at %d Hz (%.1f%%)", result.fps, result.movedShare * 100))
            try expect(result.positionsPerSecond >= 30,
                String(format: "with the lane, B receives at least 30 positions a second at %d Hz (%.1f)", result.fps, result.positionsPerSecond))
            try expect(result.maxStep <= max(3 * result.meanStep, 1),
                String(format: "with the lane, no frame jumps more than 3x the mean step at %d Hz (max %.2f pt, mean %.2f pt)", result.fps, result.maxStep, result.meanStep))
            try expect(result.finalPaintedAfter.map { $0 < 250 } == true,
                "with the lane, B paints A's final position within 250 ms at \(result.fps) Hz")
            // Lane positions skip the whole-scene refresh: changes stay at the
            // pages' 20 Hz ceiling while positions run far past it.
            try expect(result.changesPerSecond <= 25,
                String(format: "lane positions do not refresh B's scene per frame at %d Hz (%.1f changes/s)", result.fps, result.changesPerSecond))
            try expect(result.frameCostMedian < 2,
                String(format: "one playback frame costs B's main thread under 2 ms at %d Hz (median %.3f ms)", result.fps, result.frameCostMedian))
        }

        // Reduce Motion: a new position is placed, never played back.
        sceneB.reduceMotion = { true }
        let placed = 300.0
        post(areaX: placed)
        try await Rig.eventually("B's model holds the Reduce Motion position", attempts: 1000) {
            modelB.presence.first(where: { $0.identity.device == a.device })?.cursor?.x == placed
        }
        let atOnce = frame().0
        try expect(atOnce.map { abs($0.x - placed) < 0.5 } == true && !overlay.isAnimating,
            "with Reduce Motion the cursor is painted at its new position at once, with no playback")
        print("PASS collaboration cursor motion")
    }
}
