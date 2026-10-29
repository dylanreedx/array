import AppKit
import ContinuumRevivedCore
import ObjectiveC

/// Every pointer gesture here takes the user's path: `NSApp.sendEvent`, so the
/// app's local monitors (the tile focus monitor among them) run first; then the
/// window hit-tests and AppKit routes drags and the release to the view that
/// took the press. 0.7.31 shipped three regressions behind witnesses that
/// called `tileView.mouseDown` directly and so never crossed any of that.
@MainActor
enum CanvasPointerPathChecks {
    private static let agentA = TileInsertSlideChecks.tileA
    private static let agentB = TileInsertSlideChecks.tileB
    private static let noteC = TileInsertSlideChecks.tileC
    private static let agentD = TileInsertSlideChecks.tileD

    /// The user's window is key when they click it. Activating the check app
    /// would take the user's keyboard, so the window says it is key instead,
    /// and AppKit delivers the press rather than eating it as an activation click.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// An inactive app treats every press as an activation click and swallows
    /// it unless the view accepts the first mouse; the user's app is active when
    /// they click. Same answer the film harness gives (`FilmInput`).
    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    /// Every failed outcome, across every leg: one run names all of them.
    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    static func run() async throws {
        acceptFirstMouseEverywhere()
        failures = []
        for zoom in [1.0, 0.5] {
            for autoLayout in [false, true] {
                try await exercise(autoLayout: autoLayout, zoom: zoom)
            }
        }
        guard failures.isEmpty else {
            throw TileInsertSlideChecks.Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
    }

    private static func exercise(autoLayout: Bool, zoom: Double) async throws {
        let label = "zoom=\(zoom) autoLayout=\(autoLayout)"
        let fixture = try TileInsertSlideChecks.makeFixture("pointer-path")
        defer { fixture.dispose() }
        // Room past the 44pt resize snap on every side, and no zone clamp.
        let workspaceStore = WorkspaceStore(workspaceId: WorkspaceInvariantsFixture.workspaceA,
                                            applicationSupportDirectory: fixture.appSupport)
        var document = try workspaceStore.load()
        if let index = document.zones.firstIndex(where: { $0.zoneId == WorkspaceInvariantsFixture.zoneA1 }) {
            document.zones[index].size = ZoneSize(width: 2400, height: 1200)
        }
        try workspaceStore.save(document)
        let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        let projectStore = ProjectStore(projectRoot: root)
        var state = try projectStore.loadCanvas()
        let layout: [(UUID, TileFrame, Bool)] = [
            (agentA, TileFrame(x: 600, y: 520, width: 320, height: 260), true),
            (agentB, TileFrame(x: 1300, y: 520, width: 320, height: 260), true),
            (noteC, TileFrame(x: 2000, y: 520, width: 600, height: 260), false),
            (agentD, TileFrame(x: 600, y: 900, width: 320, height: 260), true),
        ]
        for (id, frame, agent) in layout {
            let index = state.tiles.firstIndex { $0.id == id }!
            if agent {
                state.tiles[index].kind = .managedAgent
                state.tiles[index].metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
            }
            state.tiles[index].frame = frame
        }
        try projectStore.saveCanvas(state)
        var agents: [AgentID] = []
        let appSupport = fixture.appSupport
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            for (id, name) in [(agentA, "Alpha"), (agentB, "Beta"), (agentD, "Delta")] {
                agents.append(delegate.agentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                    model: "fixture/pointer", thinking: "medium",
                    projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root,
                    tileId: id, displayName: name))
            }
        }
        try fixture.mount()
        let mounted = try fixture.requireMounted("pointer path")
        let canvas = mounted.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: autoLayout)
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: zoom))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        canvas.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        mounted.delegate.wireManagedAgentTile(agentA, agentID: agents[0])
        mounted.delegate.wireManagedAgentTile(agentB, agentID: agents[1])
        mounted.delegate.wireManagedAgentTile(agentD, agentID: agents[2])
        mounted.delegate.qaInstallTileFocusMonitor()
        defer { mounted.delegate.qaRemoveTileFocusMonitor() }
        canvas.layoutSubtreeIfNeeded()
        let broker = mounted.delegate.qaFocusBroker
        // B is a live recipient with a bound draft, so an agent header drag sees
        // a real reference target, as it does on the user's canvas.
        guard let recipient = canvas.tileView(for: agentB) as? ManagedAgentTileNSView,
              let composer = recipient.qaComposerForChecks else {
            throw TileInsertSlideChecks.Failure(message: "\(label): production mount did not hydrate agent B")
        }
        await composer.qaAwaitDraftRestore()
        let composerDrafts = AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport)
        composer.bindDraftStore(composerDrafts, agentID: agents[1])
        await composer.qaAwaitDraftRestore()
        canvas.layoutSubtreeIfNeeded()
        if autoLayout { _ = mounted.delegate.agentSupervisor.setIdentityColor(agentID: agents[0], "teal") }
        try TileInsertSlideChecks.expect(
            recipient.acceptsAgentReference(AgentPromptReference(agentID: agents[0], displayName: "Alpha"))
                && !recipient.agentReferenceDropRegions.isEmpty,
            "\(label): fixture: agent B must accept a reference from A")

        func view(_ id: UUID) throws -> TileNSView {
            guard let view = canvas.tileView(for: id) else {
                throw TileInsertSlideChecks.Failure(message: "\(label): tile \(id) has no view")
            }
            return view
        }
        func world(_ id: UUID) -> TileFrame? {
            canvas.allTilesInWorldFrames().first { $0.id == id }?.frame
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw TileInsertSlideChecks.Failure(message: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }
        /// A local tile point (flipped, world units at zoom 1) in window space.
        func point(_ id: UUID, _ local: NSPoint) throws -> NSPoint {
            try view(id).convert(local, to: nil)
        }
        /// An empty stretch of the title bar: where AppKit's hit-test answers the
        /// tile or its bar, never a control in it.
        func header(_ id: UUID) throws -> NSPoint {
            let v = try view(id)
            guard let host = canvas.superview else { throw TileInsertSlideChecks.Failure(message: "canvas has no superview") }
            for step in [0.3, 0.2, 0.1, 0.4, 0.5, 0.6, 0.7, 0.85] {
                let local = NSPoint(x: v.bounds.width * step, y: v.chromeBarHeight / 2)
                guard v.qaDragKindIsMove(at: local) else { continue }
                let candidate = try point(id, local)
                let hit = canvas.hitTest(canvas.convert(canvas.convert(candidate, from: nil), to: host))
                if hit === v || hit?.superview === v && !(hit is NSControl) { return candidate }
            }
            throw TileInsertSlideChecks.Failure(message: "\(label): tile \(id) has no empty title-bar point")
        }
        func click(_ at: NSPoint, _ flags: NSEvent.ModifierFlags = []) throws {
            try send(.leftMouseDown, at, flags)
            try send(.leftMouseUp, at, flags)
            canvas.layoutSubtreeIfNeeded()
        }

        /// Every corner of an agent and a note, then the seeded geometry again.
        func resizeCorners(_ context: String) throws {
            for id in [agentA, noteC] {
                // 5 screen points in from the corner: inside the 8pt resize ring,
                // clear of a selected group's handle, which overhangs 2pt.
                let i = 5 / CGFloat(zoom)
                let corners: [(String, (NSRect) -> NSPoint, CGPoint, Bool, Bool)] = [
                    ("topLeft", { _ in NSPoint(x: i, y: i) }, CGPoint(x: -80, y: 60), true, true),
                    ("topRight", { NSPoint(x: $0.maxX - i, y: i) }, CGPoint(x: 80, y: 60), false, true),
                    ("bottomLeft", { NSPoint(x: i, y: $0.maxY - i) }, CGPoint(x: -80, y: -60), true, false),
                    ("bottomRight", { NSPoint(x: $0.maxX - i, y: $0.maxY - i) }, CGPoint(x: 80, y: -60), false, false),
                ]
                for (name, local, delta, movesLeft, movesTop) in corners {
                    guard let before = world(id) else { throw TileInsertSlideChecks.Failure(message: "\(label): no frame") }
                    let start = try point(id, local(try view(id).bounds))
                    let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
                    try send(.leftMouseDown, start)
                    try send(.leftMouseDragged, NSPoint(x: start.x + delta.x / 2, y: start.y + delta.y / 2))
                    try send(.leftMouseDragged, end)
                    try send(.leftMouseUp, end)
                    canvas.layoutSubtreeIfNeeded()
                    guard let after = world(id) else { throw TileInsertSlideChecks.Failure(message: "\(label): no frame") }
                    let grew = after.width > before.width && after.height > before.height
                    let anchored = (movesLeft ? after.x < before.x : abs(after.x - before.x) < 0.5)
                        && (movesTop ? after.y < before.y : abs(after.y - before.y) < 0.5)
                    check(grew && anchored,
                        "\(label) \(context): \(id == agentA ? "agent" : "note") \(name) corner drag did not resize: \(before) -> \(after)")
                }
            }
            reseat()
        }
        func reseat() {
            for (id, frame, _) in layout {
                guard var tile = canvas.tileRecord(for: id) else { continue }
                tile.frame = canvas.tileFrame(fromWorldFrame: frame, tileId: id)
                canvas.updateTile(tile, recalculateZoneBounds: false, notifyChange: false)
            }
            canvas.layoutSubtreeIfNeeded()
        }

        // 1. Corner resize on a fresh canvas.
        try resizeCorners("fresh")

        // 2. A title-bar click focuses the tile, agent and note alike.
        try click(try point(noteC, NSPoint(x: 100, y: 100)))
        try click(try header(agentA))
        check(broker.activeSurface == .tile(agentA),
            "\(label): clicking agent A's title bar left focus on \(String(describing: broker.activeSurface))")
        try click(try header(agentB))
        check(broker.activeSurface == .tile(agentB),
            "\(label): clicking agent B's title bar left focus on \(String(describing: broker.activeSurface))")
        try click(try header(noteC))
        check(broker.activeSurface == .tile(noteC),
            "\(label): clicking note C's title bar left focus on \(String(describing: broker.activeSurface))")
        // Resizing the tile you are working in: an agent focused, its composer typing.
        try click(try header(agentA))
        try resizeCorners("with agent A focused")

        // 3. Shift-click title bars builds a selection.
        try click(try header(agentA))
        try click(try header(agentB), [.shift])
        try click(try header(noteC), [.shift])
        check(canvas.tileSelection.ids == [agentA, agentB, noteC],
            "\(label): shift-clicking three title bars selected \(canvas.tileSelection.ids)")
        // One outline per tile: the focused member keeps its ants, the others
        // get rings in the same geometry, never a second ring on one tile.
        let rings = canvas.tileSelection.qaOverlay?.qaDrawnRingCount ?? 0
        let antsInGroup = [agentA, agentB, noteC].filter { canvas.tileWearsRing($0) }.count
        check(rings + antsInGroup == 3,
            "\(label): a three-tile group drew \(rings) selection rings beside \(antsInGroup) focus rings")
        if autoLayout {
            let directory = URL(fileURLWithPath: "qa-runs/canvas-pointer-path", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let group = canvas.tileSelection.qaOverlay?.groupRect.insetBy(dx: -30, dy: -30) ?? canvas.bounds
            let around = group.intersection(canvas.bounds)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                canvas.layoutSubtreeIfNeeded()
                canvas.displayIfNeeded()
                guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: around) else { continue }
                canvas.cacheDisplay(in: around, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("selection-group-zoom\(zoom)-\(name).png"))
            }
            window.appearance = nil
        }
        // A single tile's own corner still resizes it while a group is selected.
        try resizeCorners("with a group selected")
        try click(try header(agentA))
        try click(try header(agentB), [.shift])
        try click(try header(noteC), [.shift])
        // A plain click on one member is a click: that tile alone, focused.
        try click(try header(agentB))
        check(canvas.tileSelection.ids == [agentB],
            "\(label): a plain click after a multi-selection selected \(canvas.tileSelection.ids)")
        check(canvas.tileSelection.qaOverlay?.qaDrawnRingCount ?? 0 == 0,
            "\(label): one selected tile drew a selection ring on top of its focus ring")
        check(broker.activeSurface == .tile(agentB),
            "\(label): a plain title-bar click after a multi-selection left focus on \(String(describing: broker.activeSurface))")

        // 4. An agent header drag moves the tile LIVE: the tile follows the
        // pointer mid-gesture, through the solver and magnet, not a ghost
        // replayed at release.
        // Each move leg starts from no group, so it watches one thing.
        canvas.tileSelection.clear()
        guard let aBefore = world(agentA) else { throw TileInsertSlideChecks.Failure(message: "\(label): no A") }
        let grab = try header(agentA)
        try send(.leftMouseDown, grab)
        try send(.leftMouseDragged, NSPoint(x: grab.x + 20, y: grab.y - 30))
        try send(.leftMouseDragged, NSPoint(x: grab.x + 40, y: grab.y - 60))
        canvas.layoutSubtreeIfNeeded()
        let aMid = world(agentA)
        try send(.leftMouseUp, NSPoint(x: grab.x + 40, y: grab.y - 60))
        canvas.layoutSubtreeIfNeeded()
        check(aMid != nil && aMid != aBefore,
            "\(label): agent A did not move while its header was dragged (frame stayed \(aBefore))")
        canvas.tileSelection.clear()
        // 5. Header onto another agent's body: a reference. Every tile holds
        // at rest while it hovers, so B stays under the pointer; release adds
        // exactly one reference to B's draft and moves nothing.
        reseat()
        let rest = canvas.allTilesInWorldFrames()
        let restA = world(agentA), restB = world(agentB)
        let bView = try view(agentB)
        let grabA = try header(agentA)
        let onBody = try point(agentB, NSPoint(x: bView.bounds.midX, y: bView.bounds.height * 0.6))
        try send(.leftMouseDown, grabA)
        for t in [0.33, 0.66, 1.0] {
            try send(.leftMouseDragged, NSPoint(x: grabA.x + (onBody.x - grabA.x) * t, y: grabA.y + (onBody.y - grabA.y) * t))
        }
        canvas.layoutSubtreeIfNeeded()
        check(world(agentA) == restA && world(agentB) == restB,
            "\(label): hovering A on B's body must hold both at rest: A \(String(describing: world(agentA))) B \(String(describing: world(agentB)))")
        check(composer.referenceDropHighlighted, "\(label): B's composer did not light while A hovered its body")
        let cards = canvas.subviews.compactMap { $0 as? AgentReferenceDragCard }.filter { !$0.isHidden }
        check(cards.count == 1 && cards.first?.qaText == "Reference Alpha",
            "\(label): over B the pointer card read \(cards.map(\.qaText))")
        if zoom == 1, let card = cards.first {
            // The card in place, beside B's lit composer, in both appearances.
            let directory = URL(fileURLWithPath: "qa-runs/canvas-pointer-path", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let around = card.frame.insetBy(dx: -260, dy: -160)
            // Layout off renders the uncoloured agent; layout on, a teal one.
            let variant = autoLayout ? "teal" : "plain"
            for (name, appearance) in [("reference-card-\(variant)-light", NSAppearance.Name.aqua), ("reference-card-\(variant)-dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                canvas.layoutSubtreeIfNeeded()
                canvas.displayIfNeeded()
                guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: around) else { continue }
                canvas.cacheDisplay(in: around, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            }
            window.appearance = nil
        }
        try send(.leftMouseUp, onBody)
        await recipient.qaAwaitReferenceDrop()
        canvas.layoutSubtreeIfNeeded()
        check(composer.draft.agentReferences.map(\.agentID) == [agents[0]],
            "\(label): dropping A's header on B's body left B's draft with \(composer.draft.agentReferences.map(\.displayName))")
        check(canvas.allTilesInWorldFrames() == rest, "\(label): a reference drop moved tiles")
        check(!composer.referenceDropHighlighted && !canvas.subviews.contains { $0 is AgentReferenceDragCard },
            "\(label): the reference highlight or card outlived the drop")
        check(!canvas.isGeometryGestureActive, "\(label): a reference drop left a geometry gesture open")
        check(broker.activeSurface == .tile(agentB),
            "\(label): after a reference drop focus is on \(String(describing: broker.activeSurface)), not B")

        canvas.tileSelection.clear()
        // 6. Header onto another agent's title bar: still a move. With layout
        // on it swaps live; either way no reference is added.
        reseat()
        let referencesBefore = composer.draft.agentReferences.count
        let grabA2 = try header(agentA)
        let onTitle = try point(agentB, NSPoint(x: bView.bounds.midX, y: bView.chromeBarHeight / 2))
        try send(.leftMouseDown, grabA2)
        for t in [0.33, 0.66, 1.0] {
            try send(.leftMouseDragged, NSPoint(x: grabA2.x + (onTitle.x - grabA2.x) * t, y: grabA2.y + (onTitle.y - grabA2.y) * t))
        }
        canvas.layoutSubtreeIfNeeded()
        check(!composer.referenceDropHighlighted, "\(label): B's title bar read as a reference target")
        if autoLayout {
            check(world(agentB) != restB, "\(label): A over B's title bar did not swap B live")
        }
        try send(.leftMouseUp, onTitle)
        await recipient.qaAwaitReferenceDrop()
        canvas.layoutSubtreeIfNeeded()
        check(composer.draft.agentReferences.count == referencesBefore, "\(label): a title-bar drop added a reference")
        if let a = world(agentA), let b = world(agentB) {
            check(autoLayout ? a.x > b.x : a != restA,
                "\(label): the title-bar drop did not \(autoLayout ? "swap" : "move") A: A \(a) B \(b)")
        }
        // 7. Two selected agents drop as one reference batch through real
        // window dispatch. Previous move previews must roll back completely.
        canvas.tileSelection.clear()
        reseat()
        try click(try header(agentA))
        try click(try header(agentD), [.shift])
        check(canvas.tileSelection.ids == [agentA, agentD], "\(label): batch selection failed")
        let batchRest = canvas.allTilesInWorldFrames()
        try mounted.runtime.controller(for: WorkspaceInvariantsFixture.projectA1)?.flushCanvasSave()
        let batchDisk = try projectStore.loadCanvas().tiles
        let draftText = composer.draft.text
        let referencesBeforeBatch = composer.draft.agentReferences
        let batchStart = try header(agentA)
        try send(.leftMouseDown, batchStart)
        try send(.leftMouseDragged, onTitle)
        try send(.leftMouseDragged, onBody)
        check(canvas.allTilesInWorldFrames() == batchRest,
              "\(label): batch reference hover must restore selected and pushed tiles")
        check(composer.referenceDropHighlighted, "\(label): batch drop did not highlight recipient")
        let batchCards = canvas.subviews.compactMap { $0 as? AgentReferenceDragCard }.filter { !$0.isHidden }
        check(batchCards.count == 1 && batchCards.first?.qaText == "Reference 2 agents",
              "\(label): batch card must identify both agents: \(batchCards.map(\.qaText))")
        // Option changes intent at the SAME coordinate, without a pointer move.
        try send(.leftMouseDragged, onBody, [.option])
        check(!composer.referenceDropHighlighted, "\(label): Option must keep a batch drag as layout")
        check(composer.draft.agentReferences == referencesBeforeBatch,
              "\(label): hover or Option must never insert references")
        try send(.leftMouseDragged, onBody)
        check(composer.referenceDropHighlighted && canvas.allTilesInWorldFrames() == batchRest,
              "\(label): returning from Option must restore reference hover at the same point")
        if zoom == 1 {
            let directory = URL(fileURLWithPath: "qa-runs/canvas-pointer-path", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let region = (batchCards.first?.frame ?? canvas.bounds).insetBy(dx: -160, dy: -80).intersection(canvas.bounds)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                canvas.layoutSubtreeIfNeeded()
                canvas.displayIfNeeded()
                if let image = canvas.bitmapImageRepForCachingDisplay(in: region) {
                    canvas.cacheDisplay(in: region, to: image)
                    try image.representation(using: .png, properties: [:])?
                        .write(to: directory.appendingPathComponent("batch-reference-\(autoLayout)-\(name).png"))
                }
            }
            window.appearance = nil
        }
        try send(.leftMouseUp, onBody)
        await recipient.qaAwaitReferenceDrop()
        let expectedReferences = Set([agents[0], agents[2]])
        check(Set(composer.draft.agentReferences.map(\.agentID)) == expectedReferences
                && composer.draft.agentReferences.count == 2,
              "\(label): batch drop must add both stable identities, deduplicating the existing Alpha chip")
        check(composer.draft.text == draftText, "\(label): batch reference drop changed draft text")
        check(canvas.allTilesInWorldFrames() == batchRest, "\(label): batch reference drop changed canvas geometry")
        let batchDiskAfter = try projectStore.loadCanvas().tiles
        check(batchDiskAfter == batchDisk, "\(label): batch reference drop persisted tile changes")
        check(!canvas.isGeometryGestureActive && !composer.referenceDropHighlighted
                && !canvas.subviews.contains { $0 is AgentReferenceDragCard },
              "\(label): batch drop leaked gesture chrome or a geometry edit")
        try await composerDrafts.flushReportingFailure(agentID: agents[1])
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: fixture.appSupport)
        let restoredDraft = await drafts.load(for: agents[1])
        check(Set(restoredDraft?.agentReferences.map(\.agentID) ?? []) == expectedReferences,
              "\(label): both references must survive draft-store reload")

        // Escape cancels the pending reference intent; a mixed tile selection
        // remains a layout gesture rather than silently dropping only its agents.
        canvas.tileSelection.clear()
        reseat()
        try click(try header(agentA))
        try click(try header(agentD), [.shift])
        let cancelStart = try header(agentA)
        let beforeCancel = canvas.allTilesInWorldFrames()
        try send(.leftMouseDown, cancelStart)
        try send(.leftMouseDragged, onBody)
        canvas.cancelOperation(nil)
        try send(.leftMouseUp, onBody)
        await recipient.qaAwaitReferenceDrop()
        check(canvas.allTilesInWorldFrames() == beforeCancel && !composer.referenceDropHighlighted
                && !canvas.subviews.contains { $0 is AgentReferenceDragCard },
              "\(label): cancelling batch reference must restore geometry and remove its highlight/card")
        try click(try header(noteC), [.shift])
        let mixedStart = try header(agentA)
        try send(.leftMouseDown, mixedStart)
        try send(.leftMouseDragged, onBody)
        check(!composer.referenceDropHighlighted, "\(label): mixed agent/note selection must remain a move")
        canvas.cancelOperation(nil)
        try send(.leftMouseUp, onBody)
        print("CanvasPointerPathChecks batch reference scenarios exercised \(label)")
        print("CanvasPointerPathChecks ran \(label)")
    }
}
