import AppKit
import ObjectiveC
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Every collaboration surface, in the state a person sees it. The ui-probe
/// appearance sweep and token census render this list, and the class census
/// below fails when a collaboration view class appears in none of them, so a
/// new view is covered the day it lands rather than when someone remembers.
@MainActor
enum CollaborationAppearanceSurfaces {
    struct Surface {
        let id: String
        let size: NSSize
        let view: NSView
    }

    static func all() throws -> [Surface] {
        [
            .init(id: "sharedAreaScene", size: .init(width: 960, height: 680), view: try SharedAreaSceneChecks.makeAppearanceFixture()),
            .init(id: "sharedAreaAgreement", size: .init(width: 960, height: 680), view: try agreementScene(following: false)),
            .init(id: "sharedAreaFollow", size: .init(width: 960, height: 680), view: try agreementScene(following: true)),
            .init(id: "sharedAreaAgent", size: .init(width: 960, height: 680), view: try selectedScene(.agentObservation)),
            .init(id: "sharedAreaArtifact", size: .init(width: 960, height: 680), view: try selectedScene(.artifact)),
            .init(id: "collaborationHub", size: .init(width: 680, height: 720), view: try CollaborationHubChecks.makeAppearanceFixture()),
            .init(id: "collaborationCapture", size: .init(width: 780, height: 800), view: try SharedAreaCaptureChecks.makeAppearanceFixture()),
            .init(id: "collaborationCaptureArea", size: .init(width: 800, height: 500), view: captureArea()),
            .init(id: "collaborationHandoff", size: .init(width: 780, height: 820), view: try SharedAreaHandoffViewChecks.makeAppearanceFixture()),
            .init(id: "sharedAreaZone", size: .init(width: 1440, height: 900), view: try sharedZone(offline: false, following: false)),
            .init(id: "sharedAreaZoneOffline", size: .init(width: 1440, height: 900), view: try sharedZone(offline: true, following: false)),
            .init(id: "sharedAreaZoneFollow", size: .init(width: 1440, height: 900), view: try sharedZone(offline: false, following: true)),
            .init(id: "sharedAreaZoneEnded", size: .init(width: 1440, height: 900), view: try sharedZone(offline: false, following: false, ended: true)),
            .init(id: "sharedAgentTile", size: SharedAgentAppearance.size, view: try SharedAgentAppearance.surface())
        ]
    }

    /// A shared area as a zone on a canvas (IN-CANVAS option A): the shared
    /// header, a teammate's live agent with its chip and read-only footer, and
    /// my own shared agent. Offline dims and dashes the host's agent and the
    /// zone; following draws the frame and pill.
    private static func sharedZone(offline: Bool, following: Bool, ended: Bool = false) throws -> NSView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-zone-appearance-\(UUID())")
        let me = Collaboration.Identity(person: .init(), device: UUID()), mate = Collaboration.Identity(person: .init(), device: UUID())
        let mateHost = SharedArea.ID<SharedArea.Host>()
        let mateAgent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: mate.person, host: mateHost, binding: .init()))
        let spec = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: mate.person, host: mateHost, binding: .init()))
        let mine = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: me.person, host: .init(), binding: .init()))
        let discussion = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let revision = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: mate.person,
            text: "Retry a failed payment at most twice, 4 s then 12 s. Never retry a declined card.")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(mateAgent, .init(id: .init(), object: mateAgent.id, rect: .init(x: 24, y: 58, width: 380, height: 460), z: 1)),
            .admit(mine, .init(id: .init(), object: mine.id, rect: .init(x: 430, y: 58, width: 380, height: 460), z: 2)),
            .admit(spec, .init(id: .init(), object: spec.id, rect: .init(x: 24, y: 540, width: 380, height: 130), z: 3)),
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 840, y: 58, width: 300, height: 200), z: 4)),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 840, y: 300, width: 300, height: 200), z: 5)),
            .context(revision), .endorse(.init(revision: revision.id, person: mate.person)),
            .post(.init(id: .init(), object: discussion.id, author: mate.person, text: "I'll send the agreement to my agent."))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (mate, .owner)])
        let model = try SharedAreaCheckRig.controller(root: root, identity: me, label: "You", authority: authority, seed: (document, .editor))
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = .init(x: 0, y: 0, width: 1440, height: 900)
        let zone = ZonePlacement(zoneId: UUID(), projectId: nil, origin: .init(x: 40, y: 40), size: .init(width: 1360, height: 720),
            color: "teal", collapsed: false, hydrationPolicy: .automatic, autoLayoutMode: .disabled, name: "Checkout redesign",
            sharedAreaId: document.id.rawValue)
        canvas.addSharedAreaZone(zone)
        let scene = SharedAreaSceneView(controller: model, person: me.person, presentation: .zone)
        scene.outerViewportSize = canvas.bounds.size
        canvas.installSharedAreaLayer(zoneId: zone.zoneId, body: scene)
        scene.mount()
        let now = Date()
        let hostState: Collaboration.HostLiveness = .init(host: mateHost, generation: UUID(), state: offline ? .offline : .online,
            lastSeen: now.addingTimeInterval(offline ? -245 : 0), staleAt: now.addingTimeInterval(30), offlineAt: now.addingTimeInterval(90),
            reason: offline ? .expired : nil)
        // The cached document paints at once; the header reads the connected
        // presence and liveness the rig would relay.
        scene.zoneHeader.person = me.person
        scene.qaApplyZoneState(hosts: [hostState], presence: [.init(identity: mate, cursor: .init(x: 300, y: 260),
            viewport: .init(x: 0, y: 0, width: 800, height: 500), expiresAt: .distantFuture, label: "Dylan")])
        canvas.setSharedAreaHostOffline(offline, zoneId: zone.zoneId)
        for view in scene.zoneAgentViews.values { view.live.stop() }
        if ended { scene.qaApplyZoneEnding(.accessRemoved(host: "Dylan")) }
        if following {
            canvas.showFollowIndicator(name: "Dylan", color: SharedAreaPersonColour.color(for: mate.person, host: mate.person))
            scene.zoneHeader.followedDevice = mate.device
        }
        let host = OwnedRootHost(root: root, size: canvas.frame.size)
        host.addSubview(canvas)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// A scene with a working agreement selected, optionally while following
    /// a teammate whose usage card is open.
    private static func agreementScene(following: Bool) throws -> NSView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-agreement-appearance-\(UUID())")
        let me = Collaboration.Identity(person: .init(), device: UUID()), mate = Collaboration.Identity(person: .init(), device: UUID())
        let agreement = SharedArea.Item(id: .init(), kind: .agreement), discussion = SharedArea.Item(id: .init(), kind: .discussion)
        let first = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: mate.person,
            text: "Agents keep changes inside the parser module and ask before touching tests.")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 40, y: 40, width: 360, height: 220), z: 1)),
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 440, y: 60, width: 260, height: 180), z: 2)),
            .context(first), .endorse(.init(revision: first.id, person: mate.person))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (mate, .editor)])
        let model = try SharedAreaCheckRig.controller(root: root, identity: me, label: "You", authority: authority, seed: (document, .editor))
        let host = OwnedRootHost(root: root, size: .init(width: 960, height: 680))
        let scene = SharedAreaSceneView(controller: model, person: me.person)
        scene.frame = host.bounds; scene.autoresizingMask = [.width, .height]
        host.addSubview(scene); scene.mount(); host.layoutSubtreeIfNeeded()
        try scene.fitContent(); try scene.selectObject(agreement.id)
        scene.setDraftText("Proposed: agents may also edit the lexer.")
        host.layoutSubtreeIfNeeded()
        if following {
            let overlay = SharedAreaPresenceOverlay(scene: scene)
            scene.areaCanvasView.addSubview(overlay)
            let cursor = scene.areaPoint(forScreenPoint: .init(x: 260, y: 300))
            overlay.peers = [.init(identity: mate, cursor: .init(x: cursor.x, y: cursor.y), viewport: .init(x: 0, y: 0, width: 800, height: 500),
                expiresAt: .distantFuture, label: "Peer Mate")]
            overlay.followedDevice = mate.device
            overlay.followBanner = "Following Peer Mate · pan, scroll or zoom to stop"
            overlay.pointerMoved(to: overlay.convert(scene.screenPoint(forAreaPoint: cursor), from: scene))
        }
        return host
    }

    /// A scene with one published agent or artifact selected: the agent shows
    /// its live view, the artifact its revision panel.
    private static func selectedScene(_ kind: SharedArea.Kind) throws -> NSView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-\(kind.rawValue)-appearance-\(UUID())")
        let me = Collaboration.Identity(person: .init(), device: UUID()), mate = Collaboration.Identity(person: .init(), device: UUID())
        let item = SharedArea.Item(id: .init(), kind: kind, source: .init(owner: mate.person, host: .init(), binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 40, y: 40, width: 420, height: 300), z: 1))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (mate, .editor)])
        let model = try SharedAreaCheckRig.controller(root: root, identity: me, label: "You", authority: authority, seed: (document, .editor))
        let host = OwnedRootHost(root: root, size: .init(width: 960, height: 680))
        let scene = SharedAreaSceneView(controller: model, person: me.person)
        scene.frame = host.bounds; scene.autoresizingMask = [.width, .height]
        host.addSubview(scene); scene.mount(); host.layoutSubtreeIfNeeded()
        try scene.fitContent(); try scene.selectObject(item.id)
        // The rig serves no projection: keep the live view on its first
        // rendered state rather than polling for the life of the process.
        scene.livePanel.stop()
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The capture drag hint over a personal canvas.
    private static func captureArea() -> NSView {
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = .init(x: 0, y: 0, width: 800, height: 500)
        let selection = SharedAreaCaptureSelectionView(canvas: canvas)
        canvas.addSubview(selection)
        return canvas
    }

    // MARK: - Class census

    /// Collaboration view classes in the app module. Fixture classes nested in a
    /// `…Checks` type are excluded; everything else must be on a surface.
    static func collaborationViewClasses() -> Set<String> {
        // Only Array's own image: the process-wide class list includes system
        // root classes that abort when touched.
        guard let image = class_getImageName(SharedAreaSceneView.self) else { return [] }
        var count: UInt32 = 0
        guard let list = objc_copyClassNamesForImage(image, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(list)) }
        var names = Set<String>()
        for index in 0..<Int(count) {
            let runtime = String(cString: list[index])
            guard runtime.contains("SharedArea") || runtime.contains("SharedAgent") || runtime.contains("Collaboration"), !runtime.contains("Checks"),
                  let cls = NSClassFromString(runtime), cls.isSubclass(of: NSView.self) else { continue }
            names.insert(String(describing: cls))
        }
        return names
    }

    /// Renders every surface in light and dark, writes the pictures when asked,
    /// and fails on a collaboration view class that no surface shows.
    static func runCensus() throws {
        let surfaces = try all()
        var shown = Set<String>()
        for surface in surfaces {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let probe = try UIProbe.render(.init(id: "collaboration.census.\(surface.id).\(appearance.rawValue)",
                    size: surface.size, appearance: appearance), make: { surface.view })
                guard probe.view.effectiveTokenTheme == (appearance == .aqua ? .light : .dark) else {
                    throw SharedAreaCheckRig.Failure(description: "\(surface.id) did not take \(appearance.rawValue)")
                }
                for view in SharedAreaCheckRig.descendants(probe.view) where !view.isHiddenOrHasHiddenAncestor {
                    shown.insert(String(describing: type(of: view)))
                }
                if let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"],
                   let png = probe.hostRep.representation(using: .png, properties: [:]) {
                    let directory = URL(fileURLWithPath: path).appendingPathComponent("census")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appendingPathComponent("\(surface.id)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
        }
        let classes = collaborationViewClasses()
        let missing = classes.subtracting(shown).sorted()
        guard classes.count >= 8, missing.isEmpty else {
            throw SharedAreaCheckRig.Failure(description: "collaboration view classes on no appearance surface: \(missing) (of \(classes.sorted())) — add the view, visible, to CollaborationAppearanceSurfaces.all() so the ui-probe census covers its colours")
        }
        print("PASS collaboration census: \(classes.count) collaboration view classes (\(classes.sorted().joined(separator: ", "))) each render visibly in light and dark across \(surfaces.count) surfaces")
    }
}
