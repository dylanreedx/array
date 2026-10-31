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

        print("STAGE shared area zone: dock")
        let dock = scene.session.scene
        try expect(dock.pinnedAgreement == scene.agreement.id && dock.agreementPanel.summaryText.hasPrefix("Revision 2 · endorsed by 1 teammate")
            && dock.agreementPanel.canEndorse && dock.selectedEntryText.contains("Yes, the link.")
            && dock.selectedEntryText.contains("Copy draft 2"),
            "the dock pins the agreement's current revision with Endorse, and reads the whole thread")
        try expect(close(scene.worldFrame(of: dock.zoneDock).maxX, scene.zone.origin.x + scene.zone.size.width - 12)
            && scene.worldFrame(of: dock.zoneDock).minY > scene.zone.origin.y + Double(ZoneChromeNSView.headerHeight),
            "the dock is inside the zone's right edge, under its header")
        await dock.agreementPanel.endorseCurrentRevision()
        try await SharedAreaCheckRig.eventually("endorsement lands") {
            await scene.authority.document.endorsements.contains { $0.person == scene.me.person }
        }
        try expect(dock.agreementPanel.summaryText.contains("endorsed by you"),
            "Endorse in the dock reaches the area's agreement through the existing controller")

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
        // One warm-up frame settles anything the follow stage left pending;
        // the budget is what each further frame costs.
        try await scene.authority.setPresence(.init(identity: scene.mate, cursor: .init(x: 290, y: 260),
            viewport: .init(x: 200, y: 300, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan"))
        try await SharedAreaCheckRig.eventually("the warm-up frame lands") {
            scene.session.controller.presence.first(where: { $0.identity.device == scene.mate.device })?.cursor?.x == 290
        }
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
        let headerDraws = headerView.drawCount, agentDraws = budgetView.drawCount
        let cursorDraws = publisher.overlay.drawCount
        for step in 0..<20 {
            try await scene.authority.setPresence(.init(identity: scene.mate, cursor: .init(x: 300 + Double(step) * 7, y: 260),
                viewport: .init(x: 200, y: 300, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan"))
            canvas.displayIfNeeded()
        }
        try await SharedAreaCheckRig.eventually("the last cursor frame lands") {
            scene.session.controller.presence.first(where: { $0.identity.device == scene.mate.device })?.cursor?.x == 300 + 19 * 7
        }
        canvas.displayIfNeeded()
        try expect(headerView.drawCount == headerDraws && budgetView.drawCount == agentDraws,
            "20 cursor-only presence frames repaint neither the zone header nor an agent view (header \(headerDraws)→\(headerView.drawCount), agent \(agentDraws)→\(budgetView.drawCount))")
        try expect(publisher.overlay.drawCount > cursorDraws, "the cursor overlay is what repaints for them")

        print("STAGE shared area zone: host offline")
        try await render(scene, "online")
        let fourMinutesAgo = Date().addingTimeInterval(-4 * 60 - 5)
        try await scene.authority.setHosts([liveness(scene.mateHost, .offline, lastSeen: fourMinutesAgo)])
        try await SharedAreaCheckRig.eventually("the host goes offline") {
            scene.session.scene.zoneAgentViews[scene.mateAgent.id]?.offline == true
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
        try await SharedAreaCheckRig.eventually("back online") { scene.session.scene.zoneAgentViews[scene.mateAgent.id]?.offline == false }
        try expect(canvas.zoneChromeSnapshot(for: scene.session.zoneId)?.outlineDashed == false, "back online, the edge is solid again")
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
