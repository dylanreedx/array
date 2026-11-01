import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A teammate's cursor, end to end, over a network as slow as the real relay.
///
/// Peer A's production publisher is driven by posted 60 Hz mouse events; peer
/// B's production controller and overlay draw what arrives. Between them sits a
/// relay model calibrated on the real `continuum-relay` (measured 2026-11-01):
/// one-way delay on every request and response, the service's 20 Hz per-sender
/// coalescing with a trailing flush, and a long-poll subscription that delivers
/// at most one page per round trip. Production relay RTT measured 60-110 ms.
///
/// What it asserts, all on B's painted overlay:
/// - the cursor lands where A's mouse stopped within a few round trips, not when
///   A's one-second presence timer happens to fire;
/// - during steady motion the painted cursor advances on (nearly) every display
///   frame instead of jumping once per network delivery;
/// - B's main thread applies and paints each delivery quickly.
@MainActor
enum CollaborationCursorMotionChecks {
    private typealias Rig = SharedAreaCheckRig
    static let oneWay: Duration = .milliseconds(50)

    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Rig.Failure(description: "cursor motion: \(message)") }
        print("PASS cursor motion: \(message)")
    }

    // MARK: - Relay model

    actor Relay {
        nonisolated let area: SharedArea.ID<SharedArea.Area>
        let document: SharedArea.Document
        private let members: [UUID: Collaboration.Identity]
        private var published: [UUID: Collaboration.Presence] = [:]
        private var lastFlush: [UUID: ContinuousClock.Instant] = [:]
        private var pending: [UUID: Collaboration.Presence] = [:]
        private var flushes: [UUID: Task<Void, Never>] = [:]
        private var version = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// Arrival instant and cursor of every publish from a device.
        private(set) var arrivals: [UUID: [(ContinuousClock.Instant, Collaboration.Point?)]] = [:]

        init(document: SharedArea.Document, members: [Collaboration.Identity]) {
            self.document = document; area = document.id
            self.members = Dictionary(uniqueKeysWithValues: members.map { ($0.device, $0) })
        }
        func scope(_ identity: Collaboration.Identity) -> Collaboration.Scope { .init(area: area, epoch: 1, role: .editor) }
        /// The service's rule (`CollaborationStore.publishPresence`): keep the
        /// latest observation, fan out at most every 50 ms, flush the trailing one.
        func publish(_ input: Collaboration.PresenceInput, from identity: Collaboration.Identity, label: String) {
            let now = ContinuousClock.now
            arrivals[identity.device, default: []].append((now, input.cursor))
            let value = Collaboration.Presence(identity: identity, cursor: input.cursor, viewport: input.viewport,
                expiresAt: Date().addingTimeInterval(15), label: label)
            if let last = lastFlush[identity.device], now - last < .milliseconds(50) {
                pending[identity.device] = value
                guard flushes[identity.device] == nil else { return }
                let delay = .milliseconds(50) - (now - last)
                flushes[identity.device] = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    await self?.flush(identity.device)
                }
            } else {
                flushes.removeValue(forKey: identity.device)?.cancel(); pending[identity.device] = nil
                lastFlush[identity.device] = now; published[identity.device] = value; changed()
            }
        }
        private func flush(_ device: UUID) {
            flushes[device] = nil
            guard let value = pending.removeValue(forKey: device) else { return }
            lastFlush[device] = .now; published[device] = value; changed()
        }
        private func changed() {
            version += 1
            let ready = waiters; waiters = []
            for waiter in ready { waiter.resume() }
        }
        /// A held update request: returns at once when the version moved since the
        /// caller's last page, otherwise when it next moves.
        func page(after seen: Int) async -> (Int, [Collaboration.Presence]) {
            if version == seen { await withCheckedContinuation { waiters.append($0) } }
            return (version, Array(published.values))
        }
        func lastArrival(_ device: UUID) -> (ContinuousClock.Instant, Collaboration.Point?)? { arrivals[device]?.last }
        func publishes(_ device: UUID, from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
            (arrivals[device] ?? []).filter { $0.0 >= start && $0.0 <= end }.count
        }
    }

    /// One long-poll subscription: request travels, waits for a change, the page
    /// travels back, then the next request leaves. One page per round trip.
    actor Connection: SharedAreaControllerConnection {
        let relay: Relay, identity: Collaboration.Identity
        private var loop: Task<Void, Never>?
        private var continuation: AsyncStream<CollaborationSession.Status>.Continuation?
        private(set) var deliveries: [ContinuousClock.Instant] = []
        init(relay: Relay, identity: Collaboration.Identity) { self.relay = relay; self.identity = identity }
        func start() async -> AsyncStream<CollaborationSession.Status> {
            let pair = AsyncStream<CollaborationSession.Status>.makeStream()
            let relay = relay, identity = identity
            continuation = pair.continuation
            loop = Task { [weak self] in
                var seen = -1
                while !Task.isCancelled {
                    try? await Task.sleep(for: oneWay)
                    let (version, presence) = await relay.page(after: seen)
                    seen = version
                    try? await Task.sleep(for: oneWay)
                    guard !Task.isCancelled else { break }
                    let scope = await relay.scope(identity), document = relay.document
                    guard var replica = try? CollaborationReplica(state: .init(scope: scope, document: document)) else { break }
                    try? replica.receive(.init(scope: scope, after: document.revision, through: document.revision, events: [],
                        nextCursor: document.revision, presenceVersion: UUID(), presence: presence, serverTime: Date()))
                    await self?.delivered()
                    pair.continuation.yield(.connected(replica))
                }
            }
            return pair.stream
        }
        private func delivered() { deliveries.append(.now) }
        /// One page carrying exactly `presence`, outside the network model, to
        /// time B's own handling of a frame.
        func inject(_ presence: [Collaboration.Presence]) async {
            let scope = await relay.scope(identity), document = relay.document
            guard var replica = try? CollaborationReplica(state: .init(scope: scope, document: document)) else { return }
            try? replica.receive(.init(scope: scope, after: document.revision, through: document.revision, events: [],
                nextCursor: document.revision, presenceVersion: UUID(), presence: presence, serverTime: Date()))
            continuation?.yield(.connected(replica))
        }
        func stop() async { loop?.cancel(); loop = nil }
    }

    struct Transport: SharedAreaControllerTransport {
        let identityValue: Collaboration.Identity, label: String, relay: Relay, connectionValue: Connection
        func identity() async throws -> Collaboration.Identity { identityValue }
        func state() async throws -> Collaboration.State { .init(scope: await relay.scope(identityValue), document: relay.document) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { connectionValue }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
            throw CollaborationClientError.server(status: 403, code: "forbidden")
        }
        func beginPresence() async throws -> Collaboration.PresenceSession {
            try await Task.sleep(for: oneWay * 2); return .init(id: UUID())
        }
        func publishPresence(_ input: Collaboration.PresenceInput) async throws {
            try await Task.sleep(for: oneWay)
            await relay.publish(input, from: identityValue, label: label)
            try await Task.sleep(for: oneWay)
        }
        func endPresence(_ session: UUID) async throws {}
        func reportUsage(_ report: Collaboration.UsageReport) async throws {}
    }

    private static func controller(root: URL, identity: Collaboration.Identity, label: String, relay: Relay) throws -> (SharedAreaController, Connection) {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://rig.example.test")!)
        let credentials = CollaborationCredentialStore(vault: Rig.MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-cursor-device"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
            person: identity.person, area: relay.area)
        let connection = Connection(relay: relay, identity: identity)
        let transport = Transport(identityValue: identity, label: label, relay: relay, connectionValue: connection)
        let model = try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in transport })
        return (model, connection)
    }

    // MARK: - The run

    static func run(delegate: AppDelegate) async throws {
        let root = try Rig.root("cursor-motion")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let discussion = SharedArea.Item(id: .init(), kind: .discussion)
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 40, y: 40, width: 260, height: 180), z: 1))]))
        let relay = Relay(document: document, members: [a, b])
        let (modelA, _) = try controller(root: root.appendingPathComponent("a"), identity: a, label: "Peer A", relay: relay)
        let (modelB, connectionB) = try controller(root: root.appendingPathComponent("b"), identity: b, label: "Peer B", relay: relay)

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
        try await Rig.eventually("both peers connected") { modelA.status == .connected && modelB.status == .connected }

        // A's mouse, in A's area coordinates (zoom 1, so points), through the
        // event queue the publisher's local monitor reads.
        func post(areaX: Double, areaY: Double = 300) {
            let inScene = sceneA.screenPoint(forAreaPoint: .init(x: areaX, y: areaY))
            let location = sceneA.convert(inScene, to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowA.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        /// What B has painted for A, in area coordinates.
        var framesGliding = 0, framesSampled = 0
        func painted() -> CGPoint? {
            // A display frame: the production glide tick (its link cannot fire
            // off every display), then the display pass.
            framesSampled += 1
            if overlay.isGliding { framesGliding += 1; overlay.advanceGlide() }
            CATransaction.begin(); overlay.displayIfNeeded(); CATransaction.commit(); CATransaction.flush()
            guard let point = overlay.drawnCursors[a.device] else { return nil }
            return sceneB.areaPoint(forScreenPoint: overlay.convert(point, to: sceneB))
        }
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }

        // Warm up: one position delivered and painted.
        post(areaX: 60)
        try await Rig.eventually("first cursor painted", attempts: 600) { painted().map { abs($0.x - 60) < 0.5 } ?? false }

        // Steady motion: 60 Hz events at 150 pt/s for 2.5-3.5 s, inside both areas.
        // Sample B's paint once per display frame (the check forces each frame's
        // display).
        let speed = 150.0, startX = 60.0
        let reach = sceneA.areaPoint(forScreenPoint: publisherA.overlay.convert(NSPoint(x: publisherA.overlay.bounds.maxX - 40, y: 0), to: sceneA)).x
        // The publisher re-sends once a second whether or not anything moved.
        // Find that timer's phase from a still mouse, and stop the stroke just
        // after a tick: the moment where only a real "send the last position"
        // rule, not the timer, can land the final position promptly.
        let still = ContinuousClock.now
        try await Rig.eventually("A's presence timer ticks with the mouse still", attempts: 800) {
            await relay.publishes(a.device, from: still + .milliseconds(150), to: .now) > 0
        }
        let tick = (await relay.lastArrival(a.device)?.0 ?? .now) - oneWay
        let start = ContinuousClock.now
        var stopAt = tick + .milliseconds(150)
        while stopAt - start < .milliseconds(2500) { stopAt += .seconds(1) }
        let duration = ms(stopAt - start) / 1000
        try expect(startX + speed * duration < reach, "the whole stroke stays inside A's shared area (ends at \(Int(startX + speed * duration)) of \(Int(reach)))")
        var samples: [(t: Double, mouse: Double, drawn: Double)] = []
        var lastPosted = startX
        while true {
            let t = ms(ContinuousClock.now - start) / 1000
            if t > duration { break }
            lastPosted = startX + speed * t
            post(areaX: lastPosted)
            try await Task.sleep(for: .milliseconds(16))
            if let drawn = painted() { samples.append((t, startX + speed * ms(ContinuousClock.now - start) / 1000, drawn.x)) }
        }
        let stoppedAt = ContinuousClock.now
        let finalX = lastPosted

        // Stop: when does B paint the final position?
        var landed: Double?
        for _ in 0..<600 {
            if let drawn = painted(), abs(drawn.x - finalX) < 0.5 { landed = ms(ContinuousClock.now - stoppedAt); break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let relayHeldFinal = await relay.lastArrival(a.device)
        let finalSentAfter = relayHeldFinal.flatMap { arrival in arrival.1.map { abs($0.x - finalX) < 0.5 ? ms(arrival.0 - stoppedAt) : nil } ?? nil }

        // Measurements.
        let glidingDuringMotion = Double(framesGliding) / Double(max(1, framesSampled))
        let steady = samples.filter { $0.t > 0.6 }
        let steps = zip(steady, steady.dropFirst()).map { $1.drawn - $0.drawn }
        let advancing = steps.filter { $0 > 0.5 }.count
        let advanceRatio = steps.isEmpty ? 0 : Double(advancing) / Double(steps.count)
        let meanStep = steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count)
        let maxStep = steps.max() ?? 0
        let lags = steady.map { ($0.mouse - $0.drawn) / speed * 1000 }.sorted()
        let lagMedian = lags.isEmpty ? 0 : lags[lags.count / 2], lagP90 = lags.isEmpty ? 0 : lags[lags.count * 9 / 10]
        let window = (start + .milliseconds(600), stoppedAt)
        let posts = await relay.publishes(a.device, from: window.0, to: window.1)
        let postRate = Double(posts) / (ms(window.1 - window.0) / 1000)
        let deliveries = await connectionB.deliveries.filter { $0 >= window.0 && $0 <= window.1 }.count
        let deliveryRate = Double(deliveries) / (ms(window.1 - window.0) / 1000)

        // Receive-side cost: a page handed to B until B's model holds it, then
        // the paint. B's whole main-thread handling of one presence frame.
        var handleCosts: [Double] = [], paintCosts: [Double] = []
        for i in 0..<30 {
            let x = 600.0 - Double(i) * 10
            let frame = Collaboration.Presence(identity: a, cursor: .init(x: x, y: 300), viewport: nil,
                expiresAt: Date().addingTimeInterval(15), label: "Peer A")
            var handled: CFTimeInterval?
            let observer = modelB.addChangeObserver {
                if handled == nil, modelB.presence.first(where: { $0.identity.device == a.device })?.cursor?.x == x { handled = CACurrentMediaTime() }
            }
            let began = CACurrentMediaTime()
            await connectionB.inject([frame])
            try await Rig.eventually("injected frame \(i) handled", attempts: 400) { handled != nil }
            modelB.removeChangeObserver(observer)
            handleCosts.append(((handled ?? began) - began) * 1000)
            let paintBegan = CACurrentMediaTime()
            CATransaction.begin(); overlay.displayIfNeeded(); CATransaction.commit(); CATransaction.flush()
            paintCosts.append((CACurrentMediaTime() - paintBegan) * 1000)
            try await Task.sleep(for: .milliseconds(20))
        }
        let refreshCost = handleCosts.sorted()[handleCosts.count / 2]
        let paintCost = paintCosts.sorted()[paintCosts.count / 2]

        print(String(format: "MEASURE cursor motion: B's glide display link was installed on %.0f%% of sampled frames", glidingDuringMotion * 100))
        print(String(format: "MEASURE cursor motion (one-way %.0f ms): A posted %.1f/s; B received %.1f pages/s; B painted a new position on %.0f%% of frames (mean step %.1f pt, max step %.1f pt); drawn behind the mouse median %.0f ms p90 %.0f ms; final position reached the relay %@ and was painted %@ after the mouse stopped; one overlay paint %.2f ms; one presence page handed to B until its model holds it (controller install, scene refresh, publisher, overlay) %.2f ms",
            ms(oneWay), postRate, deliveryRate, advanceRatio * 100, meanStep, maxStep, lagMedian, lagP90,
            finalSentAfter.map { String(format: "%.0f ms", $0) } ?? "never",
            landed.map { String(format: "%.0f ms", $0) } ?? "never (>3 s)",
            paintCost, refreshCost))

        try expect(landed.map { $0 < 400 } == true,
            "B paints the position where A's mouse stopped within 400 ms (\(landed.map { String(format: "%.0f ms", $0) } ?? "not within 3 s"))")
        try expect(advanceRatio >= 0.8,
            String(format: "during steady motion B's cursor advances on at least 80%% of display frames (%.0f%%)", advanceRatio * 100))
        try expect(maxStep <= max(3 * meanStep, 1),
            String(format: "no frame jumps more than 3x the mean step (max %.1f pt, mean %.1f pt)", maxStep, meanStep))
        try expect(lagMedian < 300,
            String(format: "gliding keeps the cursor within 300 ms of the mouse at a 100 ms round trip (median %.0f ms)", lagMedian))
        try expect(refreshCost < 4,
            String(format: "one presence frame costs B's main thread under 4 ms (%.2f ms)", refreshCost))

        // Reduce Motion: a new position is placed, never glided.
        sceneB.reduceMotion = { true }
        let placed = 300.0
        await connectionB.inject([.init(identity: a, cursor: .init(x: placed, y: 300), viewport: nil,
            expiresAt: Date().addingTimeInterval(15), label: "Peer A")])
        try await Rig.eventually("Reduce Motion frame handled", attempts: 400) {
            modelB.presence.first(where: { $0.identity.device == a.device })?.cursor?.x == placed
        }
        let atOnce = painted()
        try expect(atOnce.map { abs($0.x - placed) < 0.5 } == true && !overlay.isGliding,
            "with Reduce Motion the cursor is painted at its new position at once, with no glide")
        print("PASS collaboration cursor motion")
    }
}
