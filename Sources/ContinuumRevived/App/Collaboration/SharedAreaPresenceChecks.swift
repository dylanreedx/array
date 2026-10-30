import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

@MainActor
enum SharedAreaPresenceChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS cursor usage: \(message)")
    }
    static func run() async throws {
        let host = try SharedAreaSceneChecks.makeAppearanceFixture()
        func scene(in view: NSView) -> SharedAreaSceneView? {
            if let value = view as? SharedAreaSceneView { return value }
            return view.subviews.lazy.compactMap { scene(in: $0) }.first
        }
        guard let scene = scene(in: host) else { throw Failure(message: "missing production scene fixture") }
        let overlay = SharedAreaPresenceOverlay(scene: scene)
        scene.areaCanvasView.addSubview(overlay)
        let identity = Collaboration.Identity(person: .init(), device: UUID())
        let now = Date(), area = scene.areaPoint(forScreenPoint: .init(x: 210, y: 210))
        let usage = Collaboration.UsageSnapshot(host: .init(), sequence: 1, inputTokens: 100, outputTokens: 20,
            todayInputTokens: 60, todayOutputTokens: 10, dayUTC: SharedAreaUsageLedger.dayUTC(now),
            observedSince: now, measuredAt: now, coveredAgents: 2, runningAgents: 1, partial: true)
        let peer = Collaboration.Presence(identity: identity, cursor: .init(x: area.x, y: area.y), viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: usage)
        overlay.peers = [peer]
        let point = overlay.convert(scene.screenPoint(forAreaPoint: area), from: scene)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            overlay.inspect(device: nil)
            _ = try UIProbe.render(.init(id: "collaboration.presence.rest.\(appearance.rawValue)", size: .init(width: 960, height: 680), appearance: appearance), make: { host })
            try expect(overlay.renderedUsageText == nil && overlay.inspectedDevice == nil,
                "\(appearance.rawValue) resting cursor paints no persistent usage overlay")
            overlay.pointerMoved(to: point)
            let probe = try UIProbe.render(.init(id: "collaboration.presence.hover.\(appearance.rawValue)", size: .init(width: 960, height: 680), appearance: appearance), make: { host })
            try expect(overlay.inspectedDevice == identity.device && overlay.renderedUsageText?.contains("120 tokens") == true
                && overlay.renderedUsageText?.contains("Observed today (UTC): 70") == true
                && overlay.renderedUsageText?.contains("Partial coverage") == true,
                "\(appearance.rawValue) hovering the actual cursor reveals measured totals, UTC day and honest coverage")
            if let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"],
               let data = probe.hostRep.representation(using: .png, properties: [:]) {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("cursor-hover-\(appearance == .aqua ? "light" : "dark").png"))
            }
            overlay.pointerMoved(to: nil)
            try expect(overlay.renderedUsageText == nil && overlay.inspectedDevice == nil,
                "leaving the cursor removes its usage immediately")
        }
        overlay.peers = [peer]; overlay.pointerMoved(to: point)
        overlay.peers = [.init(identity: identity, cursor: .init(x: area.x + 1000, y: area.y + 1000), viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: usage)]
        try expect(overlay.inspectedDevice == nil && overlay.renderedUsageText == nil,
            "a teammate moving away dismisses hover without another local mouse event")
        overlay.peers = [peer]; overlay.pointerMoved(to: point)
        _ = try UIProbe.render(.init(id: "collaboration.presence.stationary", size: .init(width: 960, height: 680), appearance: .aqua), make: { host })
        let zoom = scene.localViewCamera.zoom
        overlay.peers = [.init(identity: identity, cursor: .init(x: area.x - 80 / zoom, y: area.y - 80 / zoom), viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: usage)]
        try expect(overlay.inspectedDevice == nil,
            "a moving cursor cannot create a new clamped card underneath a stationary pointer")
        overlay.peers = [peer]; overlay.pointerMoved(to: point)
        let camera = scene.localViewCamera
        try scene.setCamera(.init(x: camera.x + 1000, y: camera.y + 1000, zoom: camera.zoom))
        overlay.refreshGeometry()
        try expect(overlay.inspectedDevice == nil,
            "camera navigation rechecks a stationary hover against the transformed cursor")
        try scene.setCamera(camera)
        overlay.pointerMoved(to: point); overlay.updateTrackingAreas()
        guard let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
            throw Failure(message: "could not construct native cursor exit")
        }
        var publishedExit = false
        overlay.onPointerExit = { publishedExit = true }
        overlay.mouseExited(with: exit)
        try expect(publishedExit && overlay.inspectedDevice == nil && overlay.renderedUsageText == nil,
            "the native tracking exit clears hover and informs cursor publication")
        overlay.peers = [peer]
        guard let accessible = overlay.accessibilityChildren()?.first as? NSAccessibilityElement else {
            throw Failure(message: "cursor has no accessibility inspection target")
        }
        try expect(accessible.accessibilityPerformPress() && overlay.inspectedDevice == identity.device,
            "accessibility focus exposes the same transient teammate inspection without a constant counter")
        overlay.peers = [.init(identity: identity, cursor: peer.cursor, viewport: nil,
            expiresAt: now.addingTimeInterval(-1), label: "Peer A", usage: usage)]
        try expect(overlay.visiblePeers.isEmpty && overlay.inspectedDevice == nil && overlay.renderedUsageText == nil,
            "expired cursor/usage disappears even without another local mouse event")
        let unknown = Collaboration.Presence(identity: identity, cursor: peer.cursor, viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A")
        try expect(SharedAreaPresenceOverlay.usageLines(unknown).contains("Usage has not been reported"),
            "missing telemetry is unavailable rather than a fabricated zero")
        let invalidUsage = Collaboration.UsageSnapshot(host: .init(), sequence: 1, inputTokens: .max, outputTokens: .max,
            todayInputTokens: .max, todayOutputTokens: .max, dayUTC: usage.dayUTC,
            observedSince: now, measuredAt: now, coveredAgents: 1, runningAgents: 1, partial: true)
        let malformed = Collaboration.Presence(identity: identity, cursor: peer.cursor, viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: invalidUsage)
        try expect(SharedAreaPresenceOverlay.usageLines(malformed).contains("Token usage unavailable"),
            "invalid maximum counters render unavailable without integer overflow")
        overlay.removeFromSuperview(); scene.unmount(); await scene.controller.close()
        try await runFollow()
        try await SharedAreaHostSessionChecks.run()
    }

    // MARK: - Voluntary follow (COL-18)

    private static func eventually(_ label: String, attempts: Int = 400, _ value: @MainActor () async -> Bool) async throws {
        for _ in 0..<attempts {
            if await value() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(message: "Timed out: \(label)")
    }
    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
    /// Everything presence/follow traffic must leave untouched.
    private struct Census: Equatable {
        let transcriptLayouts: Int, codeMeasures: Int, bandMeasures: Int, markdownMeasures: Int, tableSolves: Int
        let executors: Int, applies: Int, usageReports: Int
        @MainActor static func take(executors: Int, authority: FollowAuthority) async -> Census {
            .init(transcriptLayouts: AgentTranscriptListView.qaTotalLayoutPasses,
                  codeMeasures: CodeTextView.qaUnwrappedMeasurementCount, bandMeasures: BandTextWidth.qaMeasurements,
                  markdownMeasures: FileMarkdownDocumentView.qaTotalMeasurePasses, tableSolves: AgentTableView.qaNaturalWidthSolves,
                  executors: executors, applies: await authority.applies, usageReports: await authority.usageReports)
        }
    }

    /// Two production-mounted scenes of different sizes with live publishers.
    /// The follower's private camera must track the leader's published
    /// area-local viewport, exit on any local navigation, and stop cleanly.
    private static func runFollow() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(message: "follow witness requires isolated app support")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("follow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leaderID = Collaboration.Identity(person: .init(), device: UUID())
        let followerID = Collaboration.Identity(person: .init(), device: UUID())
        let near = SharedArea.Item(id: .init(), kind: .discussion), far = SharedArea.Item(id: .init(), kind: .agreement)
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(near, .init(id: .init(), object: near.id, rect: .init(x: 40, y: 30, width: 260, height: 180), z: 1)),
            .admit(far, .init(id: .init(), object: far.id, rect: .init(x: 1400, y: 900, width: 300, height: 220), z: 2))]))
        let authority = FollowAuthority(document: document, leader: leaderID, follower: followerID)
        let delegate = AppDelegate()
        var constructions = 0
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("supervisor")),
            makeRunner: { _ in constructions += 1; return ScriptedAgentRunner(script: []) })
        delegate.agentSupervisor = supervisor
        let executors: @MainActor () -> Int = { supervisor.records.keys.filter { supervisor.isRunning($0) }.count + constructions }
        let leaderRoot = root.appendingPathComponent("leader"), followerRoot = root.appendingPathComponent("follower")
        let leaderModel = try followController(root: leaderRoot, identity: leaderID, authority: authority)
        let followerModel = try followController(root: followerRoot, identity: followerID, authority: authority)
        let leaderHost = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let followerHost = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 700))
        let leader = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: leaderModel, person: leaderID.person, in: leaderHost)
        let follower = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: followerModel, person: followerID.person, in: followerHost)
        leaderHost.layoutSubtreeIfNeeded(); followerHost.layoutSubtreeIfNeeded()
        await leaderModel.open(); await followerModel.open()
        try leader.setCamera(.init(x: -60, y: -40, zoom: 1.25))
        try follower.setCamera(.init(x: -300, y: -200, zoom: 0.5))
        let leaderPublisher = SharedAreaPresencePublisher(scene: leader)
        let followerPublisher = SharedAreaPresencePublisher(scene: follower)
        leaderPublisher.start(); followerPublisher.start()
        defer { leaderPublisher.stop(); followerPublisher.stop() }
        let source = root.appendingPathComponent("source/.array/canvas.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data("personal canvas stays out of follow".utf8)
        try sourceBytes.write(to: source)

        func leaderViewport() -> SharedArea.Rect {
            let camera = leader.localViewCamera, bounds = leader.areaCanvasView.bounds
            return .init(x: camera.x, y: camera.y, width: max(1, bounds.width / camera.zoom), height: max(1, bounds.height / camera.zoom))
        }
        let pointer = Collaboration.Point(x: 120, y: 90)
        func publishLeader() async throws {
            let wanted = leaderViewport()
            try await eventually("leader viewport published") {
                let seen = followerModel.presence.first(where: { $0.identity.device == leaderID.device })
                if await authority.lastInput(leaderID)?.viewport == wanted, seen?.viewport == wanted, seen?.cursor == pointer { return true }
                await leaderPublisher.publishPointer(pointer); return false
            }
        }
        func followerCentre() -> CGPoint {
            let canvas = follower.areaCanvasView.frame
            return follower.areaPoint(forScreenPoint: .init(x: canvas.midX, y: canvas.midY))
        }
        func tracksLeader() -> Bool {
            let viewport = leaderViewport(), centre = followerCentre(), bounds = follower.areaCanvasView.bounds
            let zoom = min(Double(bounds.width) / viewport.width, Double(bounds.height) / viewport.height)
            return close(centre.x, viewport.x + viewport.width / 2) && close(centre.y, viewport.y + viewport.height / 2)
                && close(follower.localViewCamera.zoom, zoom)
        }
        func cursorPoint() -> NSPoint {
            followerPublisher.overlay.convert(follower.screenPoint(forAreaPoint: .init(x: 120, y: 90)), from: follower)
        }
        try await publishLeader()

        // Pointer path: hover the teammate's cursor, then press Follow in its card.
        followerPublisher.overlay.pointerMoved(to: cursorPoint())
        guard let button = followerPublisher.overlay.followButtonFrame,
              followerPublisher.overlay.followButtonTitle == "Follow view" else {
            throw Failure(message: "hover card offers no Follow action")
        }
        let press = NSPoint(x: button.midX, y: button.midY)
        try expect(followerPublisher.overlay.hitTest(followerPublisher.overlay.convert(press, to: follower.areaCanvasView)) === followerPublisher.overlay
            && followerPublisher.overlay.hitTest(followerPublisher.overlay.convert(NSPoint(x: 4, y: followerPublisher.overlay.bounds.maxY - 4), to: follower.areaCanvasView)) == nil,
            "only the card's Follow button takes the pointer; the rest of the canvas stays interactive")
        let followerWritesBefore = follower.privateViewWrites
        StoreFileWriter.install(.init(fault: .none, scope: root,
            matching: { !$0.standardizedFileURL.path.hasPrefix(leaderRoot.standardizedFileURL.path) }))
        defer { StoreFileWriter.uninstall() }
        let census = await Census.take(executors: executors(), authority: authority)
        followerPublisher.overlay.mouseDown(with: try mouse(.leftMouseDown, at: press, in: followerPublisher.overlay))
        try expect(followerPublisher.followedDevice == leaderID.device && tracksLeader(),
            "Follow from the cursor card centres the leader's area-local viewport at the follower's own size and zoom")
        guard let leaderNear = leader.renderedFrame(for: near.id), let followerNear = follower.renderedFrame(for: near.id) else {
            throw Failure(message: "shared content not visible to both")
        }
        let a = leader.areaPoint(forScreenPoint: .init(x: leaderNear.midX, y: leaderNear.midY))
        let b = follower.areaPoint(forScreenPoint: .init(x: followerNear.midX, y: followerNear.midY))
        try expect(close(a.x, b.x) && close(a.y, b.y) && follower.renderedFrame(for: far.id) == nil
            && follower.localViewCamera.zoom != leader.localViewCamera.zoom,
            "different windows and zooms point at the same shared content")
        try expect(followerPublisher.overlay.followBanner?.hasPrefix("Following") == true, "following shows a clear state")
        try await eventually("follower withdraws its own viewport") {
            await authority.lastInput(followerID).map { $0.viewport == nil } == true
        }
        for step in 1...3 {
            try leader.setCamera(.init(x: -60 + Double(step) * 140, y: -40 + Double(step) * 90, zoom: 1.25 - Double(step) * 0.2))
            try await publishLeader()
            try await eventually("follower tracks leader move \(step)") { tracksLeader() }
        }
        try expect(follower.privateViewWrites == followerWritesBefore,
            "tracked camera frames are applied without saving the private camera per frame")
        let movedLeader = leader.localViewCamera
        for _ in 0..<3 { await followerPublisher.publishPointer(.init(x: 300, y: 200)) }
        try await Task.sleep(for: .milliseconds(50))
        try expect(leader.localViewCamera == movedLeader && leaderModel.view.x == movedLeader.x && leaderModel.view.zoom == movedLeader.zoom
            && leaderPublisher.followedDevice == nil, "the follower's publications never move the followed person's camera")
        try expect(!leaderPublisher.follow(device: followerID.device) && leader.localViewCamera == movedLeader
            && leaderPublisher.overlay.followBanner?.contains("not sharing a view") == true,
            "following back a follower is refused, so two cameras cannot chase each other")
        let trace = StoreFileWriter.trace
        let after = await Census.take(executors: executors(), authority: authority)
        try expect(trace.isEmpty && after == census && after.applies == 0 && after.usageReports == 0
            && followerPublisher.followCameraApplies >= 4,
            "follow traffic made zero transcript measurements, canvas or store saves, executor/model calls or shared operations (\(followerPublisher.followCameraApplies) camera frames)")

        // Every kind of local navigation exits follow immediately.
        let canvas = follower.areaCanvasView
        func refollow(_ how: String) throws {
            try expect(followerPublisher.follow(device: leaderID.device) && tracksLeader(), "follow resumes for the \(how) exit")
        }
        canvas.keyDown(with: try arrow(124))
        try expect(followerPublisher.followedDevice == nil && followerPublisher.overlay.followBanner == nil,
            "a keyboard camera pan exits follow immediately")
        let exitedCamera = follower.localViewCamera
        try leader.setCamera(.init(x: 20, y: 10, zoom: 0.9)); try await publishLeader()
        try expect(follower.localViewCamera == exitedCamera, "after exiting, leader movement no longer moves the follower")

        // Accessibility / keyboard path: the cursor element's custom action.
        followerPublisher.overlay.inspect(device: nil)
        guard let element = followerPublisher.overlay.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement })
                .first(where: { $0.accessibilityLabel()?.contains("Peer Leader") == true }),
              let action = element.accessibilityCustomActions()?.first(where: { $0.name.hasPrefix("Follow") }) else {
            throw Failure(message: "teammate cursor offers no accessible Follow action")
        }
        try expect(action.handler?() == true && followerPublisher.followedDevice == leaderID.device && tracksLeader(),
            "the accessibility Follow action on the teammate's cursor starts the same follow")
        let empty = NSPoint(x: 6, y: canvas.bounds.maxY - 6)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: empty, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: .init(x: empty.x + 40, y: empty.y - 30), in: canvas))
        try expect(followerPublisher.followedDevice == nil, "a pointer pan exits follow immediately")
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: .init(x: empty.x + 40, y: empty.y - 30), in: canvas))
        try refollow("scroll")
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -24, wheel2: -12, wheel3: 0),
              let scroll = NSEvent(cgEvent: wheel) else { throw Failure(message: "scroll event unavailable") }
        canvas.scrollWheel(with: scroll)
        try expect(followerPublisher.followedDevice == nil, "a scroll exits follow immediately")
        try refollow("zoom")
        try follower.fitContent()
        try expect(followerPublisher.followedDevice == nil, "a zoom to fit exits follow immediately")
        try refollow("grab")
        try expect(follower.beginGeometry(placements: [document.positions[0].id]) && followerPublisher.followedDevice == nil,
            "taking hold of shared content exits follow before a followed frame could cancel the gesture")
        follower.cancelGeometry()
        try await eventually("follower republishes its own view after exiting") {
            await followerPublisher.publishPointer(.init(x: 300, y: 200))
            return await authority.lastInput(followerID)?.viewport != nil
        }

        // A teammate who stops sharing a view, leaves, or goes stale ends follow cleanly.
        try refollow("off-screen")
        let writes = follower.privateViewWrites, held = follower.localViewCamera
        await authority.withdrawViewport(leaderID)
        try await eventually("off-screen view stops follow") { followerPublisher.followedDevice == nil }
        try expect(followerPublisher.overlay.followBanner == "Peer Leader's view is off screen · stopped following"
            && follower.localViewCamera == held && follower.privateViewWrites - writes <= 1
            && followerModel.view.x == held.x && followerModel.view.y == held.y && followerModel.view.zoom == held.zoom,
            "an off-screen teammate shows a clear state, keeps the last view and saves it at most once")
        try await publishLeader()
        try refollow("away")
        leaderPublisher.stop()
        try await eventually("departure stops follow") { followerPublisher.followedDevice == nil }
        try expect(followerPublisher.overlay.followBanner == "Peer Leader left · stopped following",
            "a teammate who leaves shows a clear state and follow stops")
        leaderPublisher.start(); try await publishLeader()
        try refollow("stale")
        followerPublisher.overlay.pointerMoved(to: cursorPoint())
        try expect(followerPublisher.overlay.followButtonTitle == "Stop following", "the followed teammate's card offers Stop following")
        // Rendering re-hosts the view in a probe window, so pictures come last.
        try await render(followerHost, publisher: followerPublisher, name: "follow-active")
        followerPublisher.overlay.pointerMoved(to: nil)
        await authority.freeze(leaderID, expiringIn: 0.3)
        try await eventually("stale presence stops follow without another frame", attempts: 600) { followerPublisher.followedDevice == nil }
        try expect(followerPublisher.overlay.followBanner == "Peer Leader is away · stopped following",
            "a teammate whose presence goes stale shows away and follow stops")
        try await render(followerHost, publisher: followerPublisher, name: "follow-stopped")
        let finalApplies = await authority.applies
        try expect(try Data(contentsOf: source) == sourceBytes && executors() == 0 && supervisor.records.isEmpty
            && finalApplies == 0, "follow never touches the source canvas, executors or the shared document")
        followerPublisher.stop(); leaderPublisher.stop()
        leader.unmount(); follower.unmount()
        await leaderModel.close(); await followerModel.close()
        print("Voluntary follow passed: pointer and accessibility entry, area-local tracking across sizes and zooms, immediate exit on keyboard/pan/scroll/zoom/grab, no feedback loop, stale/away/off-screen stops, zero transcript/canvas/model work.")
    }
    private static func render(_ host: NSView, publisher: SharedAreaPresencePublisher, name: String) async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let probe = try UIProbe.render(.init(id: "collaboration.\(name).\(appearance.rawValue)", size: host.frame.size, appearance: appearance), make: { host })
            try expect(publisher.overlay.followBanner != nil, "\(appearance.rawValue) \(name) render keeps the follow state visible")
            if let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"],
               let data = probe.hostRep.representation(using: .png, properties: [:]) {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(message: "pointer event unavailable")
        }
        return event
    }
    private static func arrow(_ code: UInt16) throws -> NSEvent {
        let character = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else {
            throw Failure(message: "arrow key unavailable")
        }
        return event
    }
    private static func followController(root: URL, identity: Collaboration.Identity, authority: FollowAuthority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://follow.example.test")!)
        let credentials = CollaborationCredentialStore(vault: FollowVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-follow-device"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
            person: identity.person, area: authority.area)
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in FollowTransport(identityValue: identity, authority: authority) })
    }
}

private final class FollowVault: CollaborationCredentialVault, @unchecked Sendable {
    let lock = NSLock(); var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private actor FollowConnection: SharedAreaControllerConnection {
    let pair = AsyncStream<CollaborationSession.Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
    func stop() async { pair.continuation.finish() }
    func emit(_ replica: CollaborationReplica) { pair.continuation.yield(.connected(replica)) }
}
/// A scripted authority whose presence frames carry no document change, so
/// every follow frame exercises the presence-only path of the real controller.
private actor FollowAuthority {
    nonisolated let area: SharedArea.ID<SharedArea.Area>
    let leader: Collaboration.Identity, follower: Collaboration.Identity
    let document: SharedArea.Document
    var connections: [FollowConnection] = []
    var presence: [UUID: Collaboration.Presence] = [:]
    var inputs: [UUID: Collaboration.PresenceInput] = [:]
    var frozen = Set<UUID>()
    private(set) var applies = 0
    private(set) var usageReports = 0
    init(document: SharedArea.Document, leader: Collaboration.Identity, follower: Collaboration.Identity) {
        self.document = document; area = document.id; self.leader = leader; self.follower = follower
    }
    func state(_ identity: Collaboration.Identity) throws -> Collaboration.State {
        guard identity == leader || identity == follower else { throw CollaborationClientError.server(status: 404, code: "notFound") }
        return .init(scope: .init(area: area, epoch: 1, role: .editor), document: document)
    }
    func connection(_ identity: Collaboration.Identity) throws -> FollowConnection {
        _ = try state(identity); let value = FollowConnection(); connections.append(value); return value
    }
    func lastInput(_ identity: Collaboration.Identity) -> Collaboration.PresenceInput? { inputs[identity.device] }
    func publish(_ input: Collaboration.PresenceInput, from identity: Collaboration.Identity) async throws {
        inputs[identity.device] = input
        guard !frozen.contains(identity.device) else { return }
        presence[identity.device] = .init(identity: identity, cursor: input.cursor, viewport: input.viewport,
            expiresAt: Date().addingTimeInterval(30), label: identity == leader ? "Peer Leader" : "Peer Follower")
        try await broadcast()
    }
    func end(_ identity: Collaboration.Identity) async throws {
        presence.removeValue(forKey: identity.device); try await broadcast()
    }
    func withdrawViewport(_ identity: Collaboration.Identity) async {
        guard let current = presence[identity.device] else { return }
        presence[identity.device] = .init(identity: identity, cursor: current.cursor, viewport: nil,
            expiresAt: current.expiresAt, label: current.label)
        try? await broadcast()
    }
    /// Heartbeats stop arriving: the last presence expires on its own clock.
    func freeze(_ identity: Collaboration.Identity, expiringIn seconds: TimeInterval) async {
        guard let current = presence[identity.device] else { return }
        presence[identity.device] = .init(identity: identity, cursor: current.cursor, viewport: current.viewport,
            expiresAt: Date().addingTimeInterval(seconds), label: current.label)
        try? await broadcast()
        frozen.insert(identity.device)
    }
    func thaw(_ identity: Collaboration.Identity) { frozen.remove(identity.device) }
    func applied() { applies += 1 }
    func reported() { usageReports += 1 }
    private func broadcast() async throws {
        let scope = Collaboration.Scope(area: area, epoch: 1, role: .editor)
        var replica = try CollaborationReplica(state: .init(scope: scope, document: document))
        try replica.receive(.init(scope: scope, after: document.revision, through: document.revision, events: [],
            nextCursor: document.revision, presenceVersion: UUID(), presence: Array(presence.values), serverTime: Date()))
        for connection in connections { await connection.emit(replica) }
    }
}
private struct FollowTransport: SharedAreaControllerTransport {
    let identityValue: Collaboration.Identity
    let authority: FollowAuthority
    func identity() async throws -> Collaboration.Identity { identityValue }
    func state() async throws -> Collaboration.State { try await authority.state(identityValue) }
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await authority.connection(identityValue) }
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        await authority.applied(); throw CollaborationClientError.server(status: 403, code: "forbidden")
    }
    func beginPresence() async throws -> Collaboration.PresenceSession { .init(id: UUID()) }
    func publishPresence(_ input: Collaboration.PresenceInput) async throws { try await authority.publish(input, from: identityValue) }
    func endPresence(_ session: UUID) async throws { try await authority.end(identityValue) }
    func reportUsage(_ report: Collaboration.UsageReport) async throws { await authority.reported() }
}
