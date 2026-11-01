import AppKit
import ObjectiveC
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-area-zone-check`: a shared area as a zone on the person's own
/// canvas (`.plans/105-collaboration/IN-CANVAS.md`, option A).
///
/// Every scene here is the production one: `WorkspaceInvariantsFixture` mounts
/// the workspace through `mountWorkspaceSceneAtBoot`, the area opens through
/// `AppDelegate.openSharedAreaZone` (the hub's own route), and pointer input
/// goes through `NSWindow.sendEvent`, so hit-testing is part of what is
/// witnessed. Geometry is asserted as WORLD frames against the zone's world rect.
@MainActor
enum SharedAreaZoneChecks {
    typealias Fixture = WorkspaceInvariantsFixture
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
        print("  ok: \(message)")
    }
    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.5) -> Bool { abs(a - b) <= tolerance }
    static func close(_ a: NSRect, _ b: TileFrame) -> Bool {
        close(a.minX, b.x) && close(a.minY, b.y) && close(a.width, b.width) && close(a.height, b.height)
    }

    /// Sam's canvas. Dylan hosts the area: his agent and a spec run on his Mac.
    /// Sam shared an agent of his own. The thread has two posts; the agreement
    /// has two revisions, the second endorsed by Dylan.
    @MainActor struct Scene {
        let fixture: Fixture
        let mounted: Fixture.Mounted
        let window: NSWindow
        let authority: SharedAreaCheckRig.Authority
        let me: Collaboration.Identity      // Sam, this canvas
        let mate: Collaboration.Identity    // Dylan, the host
        let mateHost: SharedArea.ID<SharedArea.Host>
        let session: SharedAreaZoneSession
        let mateAgent: SharedArea.Item
        let myAgent: SharedArea.Item
        let discussion: SharedArea.Item
        let agreement: SharedArea.Item
        var canvas: CanvasNSView { mounted.canvas }
        var zone: ZonePlacement { mounted.canvas.sharedAreaZonePlacement(session.zoneId)! }
        func position(_ item: SharedArea.Item, in document: SharedArea.Document?) -> SharedArea.Rect? {
            document?.positions.last(where: { $0.object == item.id })?.rect
        }
        func world(_ rect: SharedArea.Rect) -> TileFrame {
            TileFrame(x: zone.origin.x + rect.x, y: zone.origin.y + rect.y, width: rect.width, height: rect.height)
        }
        /// A view's frame in the world plane, which is WORLD coordinates.
        func worldFrame(of view: NSView) -> NSRect { view.convert(view.bounds, to: canvas.worldPlane) }
    }

    static let mateAgentRect = SharedArea.Rect(x: 24, y: 58, width: 420, height: 520)
    static let myAgentRect = SharedArea.Rect(x: 470, y: 58, width: 420, height: 520)

    static func mount(appearance: NSAppearance.Name = .darkAqua) async throws -> Scene {
        let fixture = try Fixture(label: "shared-area-zone")
        let suite = "shared-area-zone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        defaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
        fixture.configureMount = { delegate, _ in
            guard let canvas = delegate.canvasView else { return }
            canvas.autoLayoutDefaults = defaults
            canvas.dragMagnetizeDefaults = defaults
            canvas.breakoutDefaults = defaults
            canvas.autoLayoutReduceMotionProvider = { true }
            canvas.surfaceResidencyEnabled = false
        }
        try fixture.mount()
        let mounted = try fixture.requireMounted("shared area zone")
        mounted.canvas.appearance = NSAppearance(named: appearance)
        mounted.canvas.frame = CGRect(x: 0, y: 0, width: 1800, height: 1040)
        // The user's window is key when they click it; this one says so instead
        // of taking the user's keyboard (`CanvasPointerPathChecks.KeyWindow`).
        let window = KeyWindow(contentRect: mounted.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = mounted.canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        mounted.canvas.layoutSubtreeIfNeeded()
        window.appearance = mounted.canvas.appearance

        let me = Collaboration.Identity(person: .init(), device: UUID())
        let mate = Collaboration.Identity(person: .init(), device: UUID())
        let mateHost = SharedArea.ID<SharedArea.Host>(), myHost = SharedArea.ID<SharedArea.Host>()
        let mateAgent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: mate.person, host: mateHost, binding: .init()))
        let spec = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: mate.person, host: mateHost, binding: .init()))
        let myAgent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: me.person, host: myHost, binding: .init()))
        let discussion = SharedArea.Item(id: .init(), kind: .discussion)
        let agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let first = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: mate.person,
            text: "Retry a failed payment at most twice.")
        let second = SharedArea.Context(id: .init(), object: agreement.id, parent: first.id, author: me.person,
            text: "Retry a failed payment at most twice, 4 s then 12 s. After the second failure show the support link; never retry a declined card.")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(mateAgent, .init(id: .init(), object: mateAgent.id, rect: mateAgentRect, z: 1)),
            .admit(myAgent, .init(id: .init(), object: myAgent.id, rect: myAgentRect, z: 2)),
            .admit(spec, .init(id: .init(), object: spec.id, rect: .init(x: 24, y: 604, width: 420, height: 150), z: 3)),
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 920, y: 58, width: 300, height: 200), z: 4)),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 920, y: 300, width: 300, height: 200), z: 5)),
            .context(first), .context(second), .endorse(.init(revision: second.id, person: mate.person)),
            .post(.init(id: .init(), object: discussion.id, author: me.person,
                        text: "Copy draft 2 says \"contact support\" but the agreement says we show the link. Same thing?")),
            .post(.init(id: .init(), object: discussion.id, author: mate.person,
                        text: "Yes, the link. I'll send the agreement to my agent so the state map uses it."))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (mate, .owner)])
        let controller = try SharedAreaCheckRig.controller(root: try SharedAreaCheckRig.root("zone-sam"), identity: me,
                                                           label: "Sam", authority: authority)
        let session = try mounted.delegate.openSharedAreaZone(controller: controller, person: me.person,
            area: authority.area.rawValue, accountID: "rig-account", name: "Checkout redesign")
        session.scene.reduceMotion = { true }
        await session.waitUntilOpen()
        try await authority.setPresence(.init(identity: mate, cursor: .init(x: 640, y: 300),
            viewport: .init(x: 400, y: 100, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan"))
        try await authority.setHosts([liveness(mateHost, .online), liveness(myHost, .online)])
        try await SharedAreaCheckRig.eventually("the zone shows the area") {
            controller.status == .connected && session.scene.zoneAgentViews.count == 2
                && session.scene.zoneHeader.members.contains(where: { $0.device == mate.device })
        }
        mounted.canvas.layoutSubtreeIfNeeded()
        return Scene(fixture: fixture, mounted: mounted, window: window, authority: authority, me: me, mate: mate,
                     mateHost: mateHost, session: session, mateAgent: mateAgent, myAgent: myAgent,
                     discussion: discussion, agreement: agreement)
    }

    static func liveness(_ host: SharedArea.ID<SharedArea.Host>, _ state: Collaboration.HostLivenessState,
                         lastSeen: Date = Date()) -> Collaboration.HostLiveness {
        .init(host: host, generation: UUID(), state: state, lastSeen: lastSeen, staleAt: lastSeen.addingTimeInterval(30),
              offlineAt: lastSeen.addingTimeInterval(90), reason: state == .offline ? .expired : nil)
    }

    // MARK: Pointer input through the window

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// The check app is inactive and its window is never key, so AppKit would
    /// eat every press as an activation click; the user's app is active when
    /// they click. Same answer `CanvasPointerPathChecks` and the film harness give.
    static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    static func send(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            throw Failure(description: "could not synthesize \(type)")
        }
        NSApp.sendEvent(event)
    }
    /// A pointer drag between two WORLD points, through the window.
    static func drag(from start: CGPoint, by delta: CGSize, in scene: Scene) throws {
        let plane = scene.canvas.worldPlane
        let a = plane.convert(start, to: nil)
        let b = plane.convert(CGPoint(x: start.x + delta.width, y: start.y + delta.height), to: nil)
        try send(.leftMouseDown, at: a, in: scene.window)
        try send(.leftMouseDragged, at: NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), in: scene.window)
        try send(.leftMouseDragged, at: b, in: scene.window)
        try send(.leftMouseUp, at: b, in: scene.window)
    }
    /// A WORLD point on an empty stretch of a tile's title strip: where the
    /// window's hit test answers the tile itself, never a control in its bar.
    static func grabPoint(_ view: TileNSView, in scene: Scene) throws -> CGPoint {
        let world = scene.worldFrame(of: view)
        // Clear of the resize corners and edge ring, inside the grab strip.
        for dy in [16.0, 12, 20] {
            for fraction in [0.2, 0.25, 0.35, 0.45, 0.55, 0.15, 0.12, 0.1, 0.08] {
                let point = CGPoint(x: world.minX + world.width * fraction, y: world.minY + dy)
                guard let hit = scene.window.contentView?.superview?.hitTest(scene.canvas.worldPlane.convert(point, to: nil)) else { continue }
                // The tile, or a label in its bar that hands the press to it.
                if hit === view || (hit.isDescendant(of: view) && !(hit is NSControl && !(hit is NSTextField))) { return point }
            }
        }
        let seen = [0.2, 0.45].map { fraction -> String in
            let point = CGPoint(x: world.minX + world.width * fraction, y: world.minY + 16)
            return String(describing: scene.window.contentView?.superview?.hitTest(scene.canvas.worldPlane.convert(point, to: nil)).map { type(of: $0) })
        }
        throw Failure(description: "no empty stretch of \(view.tile.title)'s title strip takes the press (hits \(seen), tile at \(world), window \(scene.window.frame))")
    }
    /// A press on a real control, through the window. A control's tracking
    /// loop reads its mouse-up from the queue, so the up is queued first; a
    /// directly sent up would never reach it and the down would never return.
    static func press(_ control: NSControl, in window: NSWindow) throws {
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        guard let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0) else { throw Failure(description: "could not synthesize a mouse-up") }
        NSApp.postEvent(up, atStart: false)
        try send(.leftMouseDown, at: point, in: window)
    }
    static func click(_ view: NSView, at local: NSPoint, in window: NSWindow) throws {
        let point = view.convert(local, to: nil)
        try send(.leftMouseDown, at: point, in: window)
        try send(.leftMouseUp, at: point, in: window)
    }
    static func canvasFileBytes(_ fixture: Fixture) throws -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        for (project, root) in fixture.projectRoots {
            let file = ProjectStore(projectRoot: root).layout.canvasFile
            if FileManager.default.fileExists(atPath: file.path) { result[project] = try Data(contentsOf: file) }
        }
        return result
    }
    static func persistedTiles(_ fixture: Fixture, _ project: UUID) throws -> [Tile] {
        try ProjectStore(projectRoot: fixture.projectRoots[project]!).tryLoadCanvas()?.tiles ?? []
    }

    // MARK: - The witness

    static func run() async throws {
        acceptFirstMouseEverywhere()
        let scene = try await mount()
        defer { scene.session.close(); scene.window.orderOut(nil); scene.fixture.dispose() }
        let canvas = scene.canvas, runtime = scene.mounted.runtime
        let zoneId = scene.session.zoneId

        print("STAGE shared area zone: the area is a projectless Model B zone")
        guard let anchor = runtime.document.zones.first(where: { $0.zoneId == zoneId }) else {
            throw Failure(description: "the area has no zone in the workspace document")
        }
        try expect(anchor.projectId == nil && anchor.sharedAreaId == scene.authority.area.rawValue,
            "the anchor is a ZonePlacement with no project and the area's id, in the workspace document")
        let chrome = canvas.zoneChromeSnapshot(for: zoneId)
        try expect(chrome?.isSharedArea == true && chrome?.displayName == "Checkout redesign" && chrome?.scopeLabel == nil,
            "Model B draws its chrome: the area's name, no Home label")
        try expect(scene.session.scene.superview === canvas.worldPlane && close(scene.session.scene.frame, CanvasEngine.zoneWorldFrame(scene.zone)),
            "the area's body sits in the world plane at exactly the zone's WORLD rect")
        guard let mateView = scene.session.scene.zoneAgentViews[scene.mateAgent.id],
              let myView = scene.session.scene.zoneAgentViews[scene.myAgent.id] else {
            throw Failure(description: "the published agents have no live views in the zone")
        }
        try expect(close(scene.worldFrame(of: mateView), scene.world(mateAgentRect))
            && close(scene.worldFrame(of: myView), scene.world(myAgentRect)),
            "each agent's live view is at the zone's origin plus its area-local position, in WORLD frames")
        try expect(!mateView.isMine && mateView.chipText == "Dylan's · on Dylan's Mac" && mateView.footerMode == .composer
            && mateView.live.frame.maxY > mateView.bounds.height - 12
            && myView.isMine && myView.chipText == "Yours · shared" && myView.footerMode == .mine,
            "the teammate's agent carries their chip, and its live view (with its composer) fills the tile; mine says it is shared")
        try expect(scene.session.scene.zoneHeader.statusText == "Live · hosted by Dylan"
            && scene.session.scene.zoneHeader.members.map(\.name).contains("Dylan"),
            "the header says the area is live, who hosts it, and who is in it")

        print("STAGE shared area zone: a second shared zone takes free space")
        let second = try runtime.ensureSharedAreaZone(areaId: UUID(), name: "Second area")
        let third = try runtime.ensureSharedAreaZone(areaId: UUID(), name: "Third area", origin: scene.zone.origin)
        func rect(_ zone: ZonePlacement) -> NSRect {
            let frame = CanvasEngine.zoneWorldFrame(zone)
            return NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        let everyZone = runtime.document.zones.filter { !$0.collapsed }
        for added in [second, third] {
            let overlapping = everyZone.filter { $0.zoneId != added.zoneId && rect($0).intersects(rect(added)) }.map(\.name)
            try expect(overlapping.isEmpty,
                "a new shared zone (\(added.name)) covers no other zone's frame, even when asked for an existing one's (overlaps \(overlapping))")
        }
        try runtime.cancelSharedZone(second.zoneId); try runtime.cancelSharedZone(third.zoneId)

        print("STAGE shared area zone: the zone never arms creation")
        let armedBefore = canvas.armedZoneId, lastActive = runtime.document.lastActiveZoneId
        try expect(runtime.setActiveZone(zoneId, reason: .click) == false && canvas.armedZoneId == armedBefore
            && runtime.document.lastActiveZoneId == lastActive && canvas.activeProjectZoneId != zoneId,
            "setActiveZone refuses the shared zone; the armed zone and creation scope are unchanged")
        let body = scene.zone
        let inside = CGPoint(x: body.origin.x + 700, y: body.origin.y + 700)
        try send(.leftMouseDown, at: canvas.worldPlane.convert(inside, to: nil), in: scene.window)
        try send(.leftMouseUp, at: canvas.worldPlane.convert(inside, to: nil), in: scene.window)
        try expect(canvas.armedZoneId == armedBefore && runtime.document.lastActiveZoneId == lastActive,
            "a click inside the zone, through the window, still arms nothing")

        print("STAGE shared area zone: moving an item shares a .place")
        try runtime.flushMountedWorkspaceState()
        let filesBefore = try canvasFileBytes(scene.fixture)
        let header = CGPoint(x: scene.world(mateAgentRect).x + 200, y: scene.world(mateAgentRect).y + 14)
        try drag(from: header, by: .init(width: 120, height: 40), in: scene)
        let moved = SharedArea.Rect(x: mateAgentRect.x + 120, y: mateAgentRect.y + 40, width: mateAgentRect.width, height: mateAgentRect.height)
        try await SharedAreaCheckRig.eventually("the move reaches the area") {
            scene.position(scene.mateAgent, in: await scene.authority.document).map { close($0.x, moved.x, 1) && close($0.y, moved.y, 1) } == true
        }
        canvas.layoutSubtreeIfNeeded()
        try expect(close(scene.worldFrame(of: mateView).minX, scene.world(moved).x, 1) && close(scene.worldFrame(of: mateView).minY, scene.world(moved).y, 1),
            "a header drag through the window moves the agent's live view and sends the shared .place")
        try runtime.flushMountedWorkspaceState()
        let filesAfter = try canvasFileBytes(scene.fixture)
        for (project, bytes) in filesAfter where filesBefore[project] != bytes {
            print("  changed canvas.json \(project): \(String(decoding: filesBefore[project] ?? Data(), as: UTF8.self).prefix(400)) -> \(String(decoding: bytes, as: UTF8.self).prefix(400))")
        }
        try expect(filesAfter == filesBefore,
            "no project's canvas.json changes when the shared area moves")

        print("STAGE shared area zone: a tile dropped over the zone is not published")
        guard let note = canvas.tileView(for: Fixture.noteA2a) else { throw Failure(description: "seed note missing") }
        // Both the note's zone and the shared zone in view, at zoom 1.
        canvas.setViewport(CanvasViewport(x: 1650, y: 150, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        let noteWorld = scene.worldFrame(of: note)
        let grab = try grabPoint(note, in: scene)
        let plane = canvas.worldPlane
        let into = CGPoint(x: grab.x + scene.zone.origin.x + 200 - noteWorld.midX, y: grab.y + 120)
        try send(.leftMouseDown, at: plane.convert(grab, to: nil), in: scene.window)
        try send(.leftMouseDragged, at: plane.convert(CGPoint(x: (grab.x + into.x) / 2, y: (grab.y + into.y) / 2), to: nil), in: scene.window)
        try send(.leftMouseDragged, at: plane.convert(into, to: nil), in: scene.window)
        let carried = scene.worldFrame(of: note)
        let zoneRect = CanvasEngine.zoneWorldFrame(scene.zone)
        try expect(NSRect(x: zoneRect.x, y: zoneRect.y, width: zoneRect.width, height: zoneRect.height).contains(NSPoint(x: carried.midX, y: carried.midY)),
            "mid-drag, through the window, the tile's centre is inside the shared zone")
        try send(.leftMouseUp, at: plane.convert(into, to: nil), in: scene.window)
        canvas.layoutSubtreeIfNeeded()
        try expect(canvas.zoneId(containing: Fixture.noteA2a) == Fixture.zoneA2 && canvas.lentTile(Fixture.noteA2a) == nil
            && scene.session.scene.locallyShownObjects.isEmpty
            && canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA2)?.first(where: { $0.id == Fixture.noteA2a })?.zoneId == Fixture.zoneA2,
            "dropped there, the project tile stays a member of its project zone: the drop publishes nothing (\(scene.worldFrame(of: note)))")
        try runtime.flushMountedWorkspaceState()
        let allPersisted = try Fixture.projectNames.keys.flatMap { try persistedTiles(scene.fixture, $0) }
        try expect(!allPersisted.contains(where: { $0.zoneId == zoneId }),
            "no project's canvas.json names the shared zone")

        print("STAGE shared area zone: createSharedZone lends tiles and cancels cleanly")
        scene.session.reveal()
        canvas.layoutSubtreeIfNeeded()
        guard let lentView = canvas.tileView(for: Fixture.noteA1a),
              let homeWorld = canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA1)?.first(where: { $0.id == Fixture.noteA1a })?.frame else {
            throw Failure(description: "seed note A1a missing")
        }
        let homeBytes = try persistedTiles(scene.fixture, Fixture.projectA1).first(where: { $0.id == Fixture.noteA1a })
        let conversion = try runtime.createSharedZone(fromTiles: [Fixture.noteA1a], areaId: scene.authority.area.rawValue, name: "ignored")
        guard let areaFrame = conversion.areaFrames[Fixture.noteA1a] else { throw Failure(description: "no area frame") }
        canvas.layoutSubtreeIfNeeded()
        try expect(conversion.zoneId == zoneId && canvas.tileView(for: Fixture.noteA1a) === lentView && lentView.superview === canvas.worldPlane
            && close(scene.worldFrame(of: lentView), scene.world(areaFrame))
            && canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA1)?.contains(where: { $0.id == Fixture.noteA1a }) == false,
            "the tile leaves its project layer for the open area's zone, same view, at zone origin plus its area frame")
        try expect((try? runtime.createSharedZone(fromTiles: [Fixture.noteA1a], areaId: UUID(), name: "x")) == nil,
            "a lent tile cannot be lent twice")
        // Part 3's flow: admit the tile as an item at its area frame, then bind.
        let item = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: scene.me.person, host: .init(), binding: .init()))
        let controller = scene.session.controller
        guard let current = controller.document,
              case .accepted = await controller.submit(.init(area: current.id, expectedRevision: current.revision,
                  edits: [.admit(item, .init(id: .init(), object: item.id, rect: areaFrame, z: 9))])) else {
            throw Failure(description: "could not admit the lent tile's item")
        }
        runtime.bindSharedTile(Fixture.noteA1a, to: item.id, inZone: zoneId)
        try expect(scene.session.scene.locallyShownObjects.contains(item.id),
            "a bound lent tile shows its item; the zone draws no second view of it")
        let tileHeader = try grabPoint(lentView, in: scene)
        try drag(from: tileHeader, by: .init(width: 60, height: 30), in: scene)
        await scene.session.waitForLentMove()
        try await SharedAreaCheckRig.eventually("the lent tile's move reaches the area") {
            scene.position(item, in: await scene.authority.document).map { close($0.x, areaFrame.x + 60, 1) && close($0.y, areaFrame.y + 30, 1) } == true
        }
        try await scene.authority.remote([.place(.init(id: controller.document!.positions.last(where: { $0.object == item.id })!.id,
            object: item.id, rect: .init(x: 700, y: 620, width: areaFrame.width, height: areaFrame.height), z: 9))])
        try await SharedAreaCheckRig.eventually("a teammate's .place moves the lent tile") {
            canvas.layoutSubtreeIfNeeded()
            return close(scene.worldFrame(of: lentView).minX, scene.zone.origin.x + 700, 1)
        }
        try runtime.flushMountedWorkspaceState()
        let lentRecord = try persistedTiles(scene.fixture, Fixture.projectA1).first(where: { $0.id == Fixture.noteA1a })
        try expect(lentRecord == homeBytes,
            "while lent, its project's canvas.json keeps the pre-share record unchanged")
        try runtime.cancelSharedZone(zoneId)
        canvas.layoutSubtreeIfNeeded()
        try expect(canvas.tileView(for: Fixture.noteA1a) === lentView
            && canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA1)?.first(where: { $0.id == Fixture.noteA1a })?.frame == homeWorld
            && close(scene.worldFrame(of: lentView), homeWorld)
            && runtime.sharedAreaZone(for: scene.authority.area.rawValue) == nil && canvas.sharedAreaZonePlacement(zoneId) == nil
            && scene.session.isClosed,
            "cancelSharedZone returns the tile home, same view, same WORLD frame, and removes the zone and its session")
    }

    /// Follow, offline and the renders, on a fresh scene.
    static func runFollowAndOffline() async throws {
        let scene = try await mount()
        defer { scene.session.close(); scene.window.orderOut(nil); scene.fixture.dispose() }
        let canvas = scene.canvas, runtime = scene.mounted.runtime
        let publisher = scene.session.presencePublisher

        print("STAGE shared area zone: follow from the header")
        let headerView = scene.session.scene.zoneHeader
        guard let avatar = headerView.avatarFrames().first(where: { $0.member.device == scene.mate.device })?.frame else {
            throw Failure(description: "the host has no followable avatar")
        }
        let generation = runtime.interactionGeneration
        try click(headerView, at: NSPoint(x: avatar.midX, y: avatar.midY), in: scene.window)
        let zone = scene.zone, size = canvas.bounds.size
        let fit = min(Double(size.width) / 800, Double(size.height) / 500)
        func tracking(_ viewport: SharedArea.Rect) -> Bool {
            let v = canvas.viewport
            return close(v.zoom, min(8, fit), 0.001)
                && close(v.x + Double(size.width) / v.zoom / 2, zone.origin.x + viewport.x + viewport.width / 2, 1)
                && close(v.y + Double(size.height) / v.zoom / 2, zone.origin.y + viewport.y + viewport.height / 2, 1)
        }
        try expect(publisher.followedDevice == scene.mate.device && tracking(.init(x: 400, y: 100, width: 800, height: 500)),
            "clicking Dylan's avatar centres the canvas camera on his view of the area")
        try expect(canvas.qaFollowIndicator?.pillText == "Following Dylan" && headerView.followedDevice == scene.mate.device,
            "a frame and pill in his colour say who is followed")
        try expect(runtime.interactionGeneration == generation,
            "follow moves the camera programmatically: the interaction generation does not move")
        try await scene.authority.setPresence(.init(identity: scene.mate, cursor: nil,
            viewport: .init(x: 200, y: 300, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan"))
        try await SharedAreaCheckRig.eventually("the camera tracks Dylan") { tracking(.init(x: 200, y: 300, width: 800, height: 500)) }
        try expect(runtime.interactionGeneration == generation, "tracking him is not the user's interaction either")
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: scene.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53) else { throw Failure(description: "no escape event") }
        NSApp.sendEvent(escape)
        try expect(publisher.followedDevice == nil && canvas.qaFollowIndicator == nil, "esc stops following")
        // Following moved the camera into Dylan's view; bring the header back first.
        scene.session.reveal(); canvas.layoutSubtreeIfNeeded()
        try click(headerView, at: NSPoint(x: avatar.midX, y: avatar.midY), in: scene.window)
        try expect(publisher.followedDevice == scene.mate.device,
            "following again (banner \(String(describing: publisher.overlay.followBanner)), hit \(String(describing: scene.window.contentView?.superview?.hitTest(headerView.convert(NSPoint(x: avatar.midX, y: avatar.midY), to: nil)).map { type(of: $0) })), members \(headerView.members.map { "\($0.name):\($0.device != nil)" }))")
        canvas.cameraDriver.noteScrollPan(dx: 40, dy: 0, location: CGPoint(x: 400, y: 400))
        canvas.cameraDriver.qaFlushPending()
        try expect(publisher.followedDevice == nil && canvas.qaFollowIndicator == nil, "a trackpad pan stops following")
        // Following moved the camera into Dylan's view; bring the header back first.
        scene.session.reveal(); canvas.layoutSubtreeIfNeeded()
        try click(headerView, at: NSPoint(x: avatar.midX, y: avatar.midY), in: scene.window)
        guard let pill = canvas.qaFollowIndicator?.pillFrame else { throw Failure(description: "no pill") }
        try click(canvas.qaFollowIndicator!, at: NSPoint(x: pill.midX, y: pill.midY), in: scene.window)
        try expect(publisher.followedDevice == nil, "the pill's Stop stops following")

        print("STAGE shared area zone: presence frames stay inside their budget")
        guard let budgetView = scene.session.scene.zoneAgentViews[scene.mateAgent.id] else { throw Failure(description: "no agent view") }
        // Look at the area, cursors in view: follow left the camera on Dylan's.
        scene.session.reveal(); canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
        // One warm-up frame settles anything the follow stage left pending;
        // the budget is what each further frame costs.
        try await scene.authority.setPresence(.init(identity: scene.mate, cursor: .init(x: 290, y: 260),
            viewport: .init(x: 200, y: 300, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan"))
        try await SharedAreaCheckRig.eventually("the warm-up frame lands") {
            scene.session.controller.presence.first(where: { $0.identity.device == scene.mate.device })?.cursor?.x == 290
        }
        // What each view shows, so a repaint names its cause.
        func shown() -> String {
            "header \(headerView.members.map { "\($0.name):\($0.online):\($0.device != nil)" }) \(headerView.statusText) offline \(headerView.hostOffline) "
                + "followed \(String(describing: headerView.followedDevice)) frame \(headerView.frame) appearance \(headerView.effectiveAppearance.name.rawValue); "
                + "agent \(budgetView.chipText) | \(budgetView.footerText) offline \(budgetView.offline) frame \(budgetView.frame); "
                + "camera \(canvas.viewport) key \(scene.window.isKeyWindow) main \(scene.window.isMainWindow) scale \(scene.window.backingScaleFactor)"
        }
        // A layer-backed view paints when Core Animation commits, not in
        // displayIfNeeded (the check window is off screen). Commit before the
        // counts are read, so a paint that reveal() or the warm-up left pending
        // cannot land inside the window, and commit after the frames, so a paint
        // they asked for is counted.
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
        let headerDraws = headerView.drawCount, agentDraws = budgetView.drawCount
        let cursorDraws = publisher.overlay.drawCount
        let before = shown()
        SharedAreaZoneHeaderView.qaRepaintTrace = []; SharedAreaZoneAgentView.qaRepaintTrace = []
        defer { SharedAreaZoneHeaderView.qaRepaintTrace = nil; SharedAreaZoneAgentView.qaRepaintTrace = nil }
        for step in 0..<20 {
            try await scene.authority.setPresence(.init(identity: scene.mate, cursor: .init(x: 300 + Double(step) * 7, y: 260),
                viewport: .init(x: 200, y: 300, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan"))
            canvas.displayIfNeeded()
        }
        try await SharedAreaCheckRig.eventually("the last cursor frame lands") {
            scene.session.controller.presence.first(where: { $0.identity.device == scene.mate.device })?.cursor?.x == 300 + 19 * 7
        }
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
        let clean = headerView.drawCount == headerDraws && budgetView.drawCount == agentDraws
        let requests = (SharedAreaZoneHeaderView.qaRepaintTrace ?? []) + (SharedAreaZoneAgentView.qaRepaintTrace ?? [])
        try expect(clean,
            "20 cursor-only presence frames repaint neither the zone header nor an agent view (header \(headerDraws)→\(headerView.drawCount), agent \(agentDraws)→\(budgetView.drawCount))"
            + (clean ? "" : "\n  before: \(before)\n  after:  \(shown())\n  requests:\n    " + requests.joined(separator: "\n    ")))
        try expect(publisher.overlay.drawCount > cursorDraws, "the cursor overlay is what repaints for them")

        print("STAGE shared area zone: host offline")
        try await render(scene, "online")
        let fourMinutesAgo = Date().addingTimeInterval(-4 * 60 - 5)
        try await scene.authority.setHosts([liveness(scene.mateHost, .offline, lastSeen: fourMinutesAgo)])
        try await SharedAreaCheckRig.eventually("the host goes offline", attempts: 2000) {
            scene.session.controller.hostLiveness.first(where: { $0.host == scene.mateHost })?.state == .offline
                && scene.session.scene.zoneAgentViews[scene.mateAgent.id]?.offline == true
                && canvas.zoneChromeSnapshot(for: scene.session.zoneId)?.sharedHostOffline == true
        }
        canvas.layoutSubtreeIfNeeded()
        guard let mateView = scene.session.scene.zoneAgentViews[scene.mateAgent.id] else { throw Failure(description: "no agent view") }
        try expect(close(scene.worldFrame(of: mateView), scene.world(mateAgentRect)) && mateView.live.alphaValue < 0.6
            && mateView.chipText == "Dylan's · offline"
            && mateView.footerText.contains("Dylan's Mac is offline") && mateView.footerText.contains("4 min ago"),
            "his agent keeps its place, dimmed, with the time of its last update")
        let chrome = canvas.zoneChromeSnapshot(for: scene.session.zoneId)
        try expect(chrome?.sharedHostOffline == true && chrome?.outlineDashed == true
            && headerView.members.first(where: { $0.person == scene.mate.person })?.online == false
            && headerView.statusText == "Dylan's Mac is offline",
            "the zone dims with a dashed edge and his avatar greys out")
        try await render(scene, "offline")
        try await scene.authority.setHosts([liveness(scene.mateHost, .online)])
        // Wait on the liveness change itself, through to the zone's state, never
        // on a delay: the controller sees the host online, the card and the
        // zone both drop offline. Only then is the edge read.
        try await SharedAreaCheckRig.eventually("back online", attempts: 2000) {
            scene.session.controller.hostLiveness.first(where: { $0.host == scene.mateHost })?.state == .online
                && scene.session.scene.zoneAgentViews[scene.mateAgent.id]?.offline == false
                && canvas.zoneChromeSnapshot(for: scene.session.zoneId)?.sharedHostOffline == false
        }
        canvas.layoutSubtreeIfNeeded()
        let solid = canvas.zoneChromeSnapshot(for: scene.session.zoneId)
        try expect(solid?.outlineDashed == false, "back online, the edge is solid again (offline \(String(describing: solid?.sharedHostOffline)), dashed \(String(describing: solid?.outlineDashed)))")
    }

    /// Light and dark pictures for a person to look at.
    static func render(_ scene: Scene, _ name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("zone")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canvas = scene.canvas
        let saved = canvas.viewport
        defer { canvas.setViewport(saved) }
        scene.session.reveal()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            canvas.appearance = NSAppearance(named: appearance)
            scene.window.appearance = canvas.appearance
            canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
        }
    }
}

// MARK: - Follow-ups: hand over, resize, switch, relaunch, refusals

extension SharedAreaZoneChecks {
    /// A scripted control authority for one shared agent: who drives it, any
    /// offer, and what Hand over and Take back asked for.
    actor HandOverAuthority: SharedAgentHandoffTransport {
        let area: Collaboration.State
        var current: Collaboration.AgentControlState
        private(set) var offers: [SharedArea.ID<SharedArea.Person>] = []
        private(set) var reclaims = 0
        init(area: Collaboration.State, object: SharedArea.ID<SharedArea.Object>, source: SharedArea.Source, owner: SharedArea.ID<SharedArea.Person>) {
            self.area = area
            current = .init(area: area.document.id, object: object, source: source, hostGeneration: UUID(), epoch: 1, revision: 1, controller: owner)
        }
        func state() async throws -> Collaboration.State { area }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { current }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { current }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState {
            switch request.action {
            case .offer(let offer): offers.append(offer.recipient); current.offer = offer
            case .reclaim: reclaims += 1; current.offer = nil
            default: break
            }
            current.revision += 1
            return current
        }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(description: "no prompts here") }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(description: "no receipts here") }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { [] }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(description: "no host") }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(description: "no host") }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Failure(description: "no host") }
    }

    /// One Mac, launched twice. The first launch shares a real agent tile,
    /// hands it over and takes it back, resizes it, refuses bad shares in plain
    /// words, and switches workspace away and back. The second launch, on the
    /// same collaboration account, finds the area's zone in its workspace.
    static func runFollowUps() async throws {
        acceptFirstMouseEverywhere()
        let root = try SharedAreaCheckRig.root("zone-follow-ups")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Collaboration.Identity(person: .init(), device: UUID())
        let mate = Collaboration.Identity(person: .init(), device: UUID())
        let authority = SharedAreaCheckRig.Authority(document: .init(), members: [(owner, .owner), (mate, .editor)])
        let links = ShareLinkAppChecks.Links()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://share-links.example.test")!)
        let account = try ShareLinkAppChecks.account(root: root.appendingPathComponent("owner"), identity: owner, authority: authority, links: links)
        _ = try await account.enroll(endpoint: endpoint, code: "scripted-owner-enrollment", deviceLabel: "Dylan's Mac", accountLabel: "Dylan")

        func launch(seedAnchor anchor: ZonePlacement?) throws -> WorkspaceAPIChecks.Fixture {
            try WorkspaceAPIChecks.makeFixture(configureRuntime: { runtime in
                // The workspace this launch opens carries the area's zone.
                guard let anchor else { return }
                var document = runtime.document
                document.zones.append(anchor)
                runtime.replaceDocument(document, for: runtime.workspaceId)
            }, beforeMount: { delegate, directory in
                let source = ProjectStore(projectRoot: directory.appendingPathComponent("Pb"))
                var canvas = try source.loadCanvas()
                let record = delegate.qaAgentSupervisor.records.values.first(where: { $0.projectRoot == directory.appendingPathComponent("Pb").path && $0.tileId != nil })
                guard let index = canvas.tiles.firstIndex(where: { $0.id == record?.tileId }) else { throw Failure(description: "source agent tile absent") }
                canvas.tiles[index].kind = .managedAgent; canvas.tiles[index].title = "Map the checkout state machine"
                try source.saveCanvas(canvas)
                delegate.qaAdoptCollaborationAccount(account)
            })
        }
        func host(_ fixture: WorkspaceAPIChecks.Fixture) -> NSWindow {
            fixture.canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
            let window = KeyWindow(contentRect: fixture.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = fixture.canvas
            window.orderFrontOffscreenForChecks(); window.makeKey()
            fixture.canvas.layoutSubtreeIfNeeded()
            return window
        }
        func world(_ view: NSView, _ fixture: WorkspaceAPIChecks.Fixture) -> NSRect { view.convert(view.bounds, to: fixture.canvas.worldPlane) }

        // First launch.
        let first = try launch(seedAnchor: nil)
        let firstWindow = host(first)
        let delegate = first.delegate, canvas = first.canvas, runtime = first.runtime
        guard let agentView = canvas.tileView(for: first.agentTileB) else { throw Failure(description: "agent tile has no view") }

        print("STAGE shared area zone: a refused share says why")
        for (tiles, words) in [([UUID](), "Select the tiles you want to share first."),
                               ([UUID()], "One of these tiles isn't open on this canvas, so it can't be shared from here.")] {
            do { _ = try await delegate.createSharedZone(fromTiles: tiles, name: "Nothing"); throw Failure(description: "a bad share was accepted") }
            catch let error as WorkspaceRuntime.SharedZoneError {
                try expect(ShareLinkSession.message(for: error) == words, "a refused share reads \"\(words)\"")
            }
        }
        try expect(ShareLinkSession.message(for: WorkspaceRuntime.SharedZoneError.terminalStaysPrivate(UUID()))
            == "Terminals stay private, so a terminal can't be shared. Leave it out and share the rest.",
            "a terminal in the selection is refused with the reason, not \"Sharing could not finish\"")

        let share = try await delegate.createSharedZone(fromTiles: [first.agentTileB], name: "Checkout redesign")
        guard let object = share.objects[first.agentTileB],
              let session = delegate.qaSharedAreaZoneSessions.first(where: { $0.areaId == share.areaId && !$0.isClosed }) else {
            throw Failure(description: "the share opened no zone")
        }
        do { _ = try await delegate.createSharedZone(fromTiles: [first.agentTileB], name: "Again"); throw Failure(description: "shared twice") }
        catch let error as WorkspaceRuntime.SharedZoneError {
            try expect(ShareLinkSession.message(for: error) == "One of these tiles is already in a shared area.",
                "sharing a tile twice says it is already shared")
        }
        let anchor = runtime.sharedAreaZone(for: share.areaId)!

        print("STAGE shared area zone: hand over from the tile's ⋯ menu")
        try await authority.setPresence(.init(identity: mate, cursor: nil, viewport: nil, expiresAt: .distantFuture, label: "Sam"))
        try await SharedAreaCheckRig.eventually("Sam is in the area") {
            session.scene.zoneHeader.members.contains(where: { $0.person == mate.person })
        }
        guard let item = session.controller.document?.items.first(where: { $0.id == object }), let source = item.source,
              let state = session.controller.scope.map({ Collaboration.State(scope: $0, document: session.controller.document!) }) else {
            throw Failure(description: "the published agent has no source")
        }
        let control = HandOverAuthority(area: state, object: object, source: source, owner: owner.person)
        session.prompter = try SharedAgentHandoffController(identity: owner, transport: control,
                                                            directory: root.appendingPathComponent("handoff"))
        func tileMenu() -> [NSMenuItem] { agentView.qaTileContextMenu()?.items ?? [] }
        guard let handOver = tileMenu().first(where: { $0.identifier?.rawValue == "sharedArea.handOver" }) else {
            throw Failure(description: "the lent agent's ⋯ menu offers no Hand over… (\(tileMenu().map(\.title)))")
        }
        try expect(handOver.title == "Hand over…", "the lent agent's own ⋯ menu offers Hand over…")
        NSApp.sendAction(handOver.action!, to: handOver.target, from: handOver)
        guard let list = session.handOverPopover.listView, session.handOverPopover.isPresented else {
            throw Failure(description: "Hand over… opened no teammate list")
        }
        try expect(session.handOverPopover.panel?.parent === firstWindow
            && list.items.map(\.title) == ["Hand over to Sam"],
            "Hand over… opens the teammate list on the canvas's own window, not a handoff window")
        list.choose(id: mate.person.rawValue.uuidString)
        await session.handOverTask?.value
        let offered = await control.offers
        try expect(offered == [mate.person], "choosing Sam offers him the agent through the area's handoff controller")
        guard let takeBack = tileMenu().first(where: { $0.identifier?.rawValue == "sharedArea.takeBack" }) else {
            throw Failure(description: "after the offer the tile offers no Take back (\(tileMenu().map(\.title)))")
        }
        NSApp.sendAction(takeBack.action!, to: takeBack.target, from: takeBack)
        await session.handOverTask?.value
        let reclaimed = await control.reclaims
        try expect(reclaimed == 1 && tileMenu().contains(where: { $0.identifier?.rawValue == "sharedArea.handOver" }),
            "Take back on the tile reclaims it, and Hand over… returns")

        print("STAGE shared area zone: resizing a lent tile is shared")
        session.reveal(); canvas.layoutSubtreeIfNeeded()
        let before = world(agentView, first)
        let corner = CGPoint(x: before.maxX - 3, y: before.maxY - 3)
        try send(.leftMouseDown, at: canvas.worldPlane.convert(corner, to: nil), in: firstWindow)
        try send(.leftMouseDragged, at: canvas.worldPlane.convert(CGPoint(x: corner.x + 30, y: corner.y + 20), to: nil), in: firstWindow)
        try send(.leftMouseDragged, at: canvas.worldPlane.convert(CGPoint(x: corner.x + 60, y: corner.y + 40), to: nil), in: firstWindow)
        try send(.leftMouseUp, at: canvas.worldPlane.convert(CGPoint(x: corner.x + 60, y: corner.y + 40), to: nil), in: firstWindow)
        await session.waitForLentMove()
        try await SharedAreaCheckRig.eventually("the resize reaches the area") {
            guard let rect = await authority.document.positions.last(where: { $0.object == object })?.rect else { return false }
            return rect.width >= Double(before.width) + 59 && rect.height >= Double(before.height) + 39
        }
        try expect(canvas.zoneId(containing: first.agentTileB) == nil && canvas.lentTile(first.agentTileB) != nil,
            "an edge drag on a lent tile resizes it in the area and shares a .resize; it stays lent")

        print("STAGE shared area zone: a workspace switch closes the area and reopens it")
        guard delegate.qaSwitchWorkspaceFromSidebar(first.workspaceWB) else { throw Failure(description: "switch to B refused") }
        try expect(session.isClosed && !delegate.qaSharedAreaZoneSessions.contains(where: { !$0.isClosed })
            && canvas.lentTile(first.agentTileB) == nil && canvas.sharedAreaZonePlacement(anchor.zoneId) == nil
            && session.scene.superview == nil,
            "switching away closes the area's session and its zone leaves the canvas; the tile went home (closed \(session.isClosed), open \(delegate.qaSharedAreaZoneSessions.filter { !$0.isClosed }.count), lent \(canvas.lentTile(first.agentTileB) != nil), zone \(canvas.sharedAreaZonePlacement(anchor.zoneId) != nil), body \(session.scene.superview != nil), workspace \(runtime.workspaceId == first.workspaceWB))")
        try await SharedAreaCheckRig.eventually("the departing controller closes") { session.controller.status == .closed }
        guard delegate.qaSwitchWorkspaceFromSidebar(first.workspaceWA) else { throw Failure(description: "switch back refused") }
        await delegate.sharedAreaReopenTask?.value
        guard let reopened = delegate.qaSharedAreaZoneSessions.first(where: { $0.areaId == share.areaId && !$0.isClosed }) else {
            throw Failure(description: "switching back did not reopen the area")
        }
        canvas.layoutSubtreeIfNeeded()
        let position = reopened.controller.document?.positions.last(where: { $0.object == object })?.rect
        let zone = canvas.sharedAreaZonePlacement(anchor.zoneId)
        try expect(reopened !== session && reopened.zoneId == anchor.zoneId && zone?.origin == anchor.origin
            && canvas.lentTile(first.agentTileB)?.tile.object == object.rawValue && canvas.tileView(for: first.agentTileB) === agentView
            && position.map { close(world(agentView, first), TileFrame(x: zone!.origin.x + $0.x, y: zone!.origin.y + $0.y, width: $0.width, height: $0.height)) } == true,
            "switching back reopens the area in its zone at its saved place, and lends its agent tile back where the area has it")
        let viewport = canvas.viewport

        // Second launch of the same Mac: the same account, a workspace whose
        // document carries the area's zone.
        firstWindow.orderOut(nil); delegate.closeSharedAreaSessions()
        first.runtime.closeAll(); first.tearDown()

        print("STAGE shared area zone: at launch, areas reopen as zones")
        let second = try launch(seedAnchor: anchor)
        defer { second.delegate.closeSharedAreaSessions(); second.runtime.closeAll(); second.tearDown() }
        let secondWindow = host(second)
        defer { secondWindow.orderOut(nil) }
        // As in the walkthrough: the camera sits close on the shared zone, so the
        // agent's home tile is far away and its body is parked before the reopen
        // lends it. Nothing moves the camera afterwards.
        let zoneRect = CanvasEngine.zoneWorldFrame(anchor), size = second.canvas.bounds.size, zoom = 6.0
        second.canvas.setViewport(CanvasViewport(x: zoneRect.x + zoneRect.width / 2 - Double(size.width) / zoom / 2,
                                                 y: zoneRect.y + zoneRect.height / 2 - Double(size.height) / zoom / 2, zoom: zoom))
        second.canvas.layoutSubtreeIfNeeded()
        second.canvas.qaRunFarParkingPass()
        guard second.canvas.tileView(for: second.agentTileB)?.isFarParked == true else {
            throw Failure(description: "precondition: the agent's home tile was not far-parked before the reopen")
        }
        let cameraAtLaunch = second.canvas.viewport
        await second.delegate.sharedAreaReopenTask?.value
        guard let relaunched = second.delegate.qaSharedAreaZoneSessions.first(where: { $0.areaId == share.areaId && !$0.isClosed }) else {
            throw Failure(description: "launch did not reopen the area (document shared zones \(second.runtime.document.zones.filter(\.isSharedArea).count), account \(account.status), known \(account.activeAccount?.knownAreas.map(\.id) ?? []) wants \(share.areaId), task \(second.delegate.sharedAreaReopenTask != nil), sessions \(second.delegate.qaSharedAreaZoneSessions.count))")
        }
        try expect(relaunched.zoneId == anchor.zoneId && second.canvas.sharedAreaZonePlacement(anchor.zoneId)?.origin == anchor.origin
            && relaunched.scene.superview === second.canvas.worldPlane && second.canvas.viewport == cameraAtLaunch,
            "launch reopens the area in its zone at the saved local anchor, without moving the camera")
        try expect(second.canvas.lentTile(second.agentTileB)?.tile.object == object.rawValue,
            "and the agent tile this Mac shared is lent to it again")
        // The walkthrough's relaunch drew only its header: no body, no runner.
        second.canvas.layoutSubtreeIfNeeded(); second.canvas.displayIfNeeded()
        guard let relent = second.canvas.tileView(for: second.agentTileB) as? ManagedAgentTileNSView else {
            throw Failure(description: "the relaunched shared agent tile is not an agent tile view (\(String(describing: second.canvas.tileView(for: second.agentTileB).map { type(of: $0) })))")
        }
        let record = second.delegate.qaAgentSupervisor.records.values.first(where: { $0.tileId == second.agentTileB })
        try expect(record != nil && relent.attachedAgentID == record?.id && relent.qaComposerForChecks?.window != nil
            && !relent.isFarParked && relent.surfaceResidency == .native && relent.window === secondWindow
            && second.canvas.viewport == cameraAtLaunch,
            "after relaunch the shared agent tile is whole: bound to its agent, with its body and composer in the window (attached \(String(describing: relent.attachedAgentID)) record \(String(describing: record?.id)) composer \(relent.qaComposerForChecks != nil)/\(relent.qaComposerForChecks?.window != nil) parked \(relent.isFarParked) residency \(relent.surfaceResidency))")
        _ = viewport
    }
}

// MARK: - Walkthrough round 2: names that outlive presence, and access that ends

extension SharedAreaZoneChecks {
    static func runEndings() async throws {
        let scene = try await mount()
        defer { scene.session.close(); scene.window.orderOut(nil); scene.fixture.dispose() }
        let canvas = scene.canvas, runtime = scene.mounted.runtime, header = scene.session.scene.zoneHeader

        print("STAGE shared area zone: a teammate keeps their name when their Mac goes offline")
        // The relay records Dylan as "Dylan Reed"; his presence said "Dylan".
        try await scene.authority.setMemberLabel(scene.mate.person, "Dylan Reed")
        try await scene.authority.end(scene.mate)
        try await scene.authority.setHosts([liveness(scene.mateHost, .offline, lastSeen: Date().addingTimeInterval(-300))])
        try await SharedAreaCheckRig.eventually("Dylan's presence is gone and his Mac is offline") {
            !scene.session.controller.presence.contains(where: { $0.identity.person == scene.mate.person })
                && scene.session.scene.zoneAgentViews[scene.mateAgent.id]?.offline == true
        }
        guard let mateView = scene.session.scene.zoneAgentViews[scene.mateAgent.id] else { throw Failure(description: "no agent view") }
        try expect(header.members.first(where: { $0.person == scene.mate.person })?.name == "Dylan Reed"
            && header.statusText == "Dylan Reed's Mac is offline" && mateView.chipText == "Dylan Reed's · offline"
            && mateView.footerText.contains("Dylan Reed's Mac is offline"),
            "offline, he is still named by the relay's member record, never \"Teammate\" (header \(header.members.map(\.name)), \(header.statusText), chip \(mateView.chipText))")

        print("STAGE shared area zone: the host stops sharing")
        let hostItems = scene.session.controller.document?.items.filter { $0.source?.owner == scene.mate.person }.map(\.id) ?? []
        try await scene.authority.remote(hostItems.map { .remove($0) })
        try await SharedAreaCheckRig.eventually("Dylan's items leave the zone") { scene.session.scene.zoneAgentViews[scene.mateAgent.id] == nil }
        try expect(scene.session.scene.zoneEnding == nil && scene.session.scene.zoneAgentViews[scene.myAgent.id] != nil && !scene.session.scene.areaCanvasView.isHidden,
            "while this Mac's own agent is still in the area, the zone stays live (ending \(String(describing: scene.session.scene.zoneEnding)))")
        let rest = scene.session.controller.document?.items.map(\.id) ?? []
        try await scene.authority.remote(rest.map { .remove($0) })
        let ended = scene.session.scene.zoneEnded
        try await SharedAreaCheckRig.eventually("the zone says the host stopped sharing") { scene.session.scene.zoneEnding != nil }
        canvas.layoutSubtreeIfNeeded()
        try expect(scene.session.scene.zoneEnding == .stoppedSharing(host: "Dylan Reed") && !ended.isHidden
            && ended.titleLabel.stringValue == "Dylan Reed stopped sharing" && header.statusText == "Dylan Reed stopped sharing"
            && scene.session.scene.areaCanvasView.isHidden && scene.session.scene.zoneAgentViews.isEmpty,
            "when everything is taken back, the zone says who stopped sharing and keeps no empty cards (ending \(String(describing: scene.session.scene.zoneEnding)), hidden \(ended.isHidden), title \(ended.titleLabel.stringValue), status \(header.statusText), canvas hidden \(scene.session.scene.areaCanvasView.isHidden), cards \(scene.session.scene.zoneAgentViews.count))")

        print("STAGE shared area zone: access removed, and the zone taken off the canvas")
        await scene.authority.endAccess(scene.me)
        try await SharedAreaCheckRig.eventually("access ends") { scene.session.controller.status == .unavailable(.accessDenied) }
        canvas.layoutSubtreeIfNeeded()
        try expect(scene.session.scene.zoneEnding == .accessRemoved(host: "Dylan Reed") && ended.titleLabel.stringValue == "Your access was removed"
            && ended.detailLabel.stringValue.hasPrefix("Dylan Reed stopped sharing this area with you"),
            "when access is removed the zone says so, and who stopped sharing")
        let zoneId = scene.session.zoneId
        scene.session.reveal(); canvas.layoutSubtreeIfNeeded()
        try press(ended.removeButton, in: scene.window)
        try expect(runtime.sharedAreaZone(for: scene.authority.area.rawValue) == nil && canvas.sharedAreaZonePlacement(zoneId) == nil
            && scene.session.isClosed && scene.session.scene.superview == nil,
            "Remove from canvas, through the window, takes the zone and its session away")
    }
}
