import AppKit
import ObjectiveC
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--sticky-head-gesture-check` — the pinned head of a tall agent tile is the
/// header: a click focuses the tile, a drag moves it, and a drag onto another
/// agent references it. Dylan, 2026-11-25: "i want to be able to click the
/// header of an agent tile when sticky, i want to even be able to move it / drag
/// to reference to another agent".
///
/// Production defaults — auto layout and the magnet ON — and the person's state
/// as they reach a pinned head: the tall tile focused, its composer holding the
/// keyboard, a second agent on screen. Every press is a real event through
/// `NSApp.sendEvent` into a key window, paced the way a hand moves, so camera
/// steps run between drag events. Asserts what the person sees: where the tile
/// and the camera are, who is focused, what the recipient's draft holds.
///
/// - click on the pinned head: the tile is selected and focused, nothing moves.
/// - drag the pinned head: the camera eases out until the whole tile fits, the
///   tile follows the pointer by the point grabbed, and at the drop the camera
///   settles back to the zoom it had, with the head under the pointer again.
/// - drag the pinned head onto another agent: that agent's draft references the
///   dragged one, the dragged tile stays where it was, and the camera returns.
/// - the unpinned header: click focuses, a drag moves the tile by the pointer's
///   travel at an unchanged camera, and a drag onto an agent references it.
@MainActor
enum StickyHeadGestureChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// An inactive app swallows a press as an activation click unless the view
    /// accepts the first mouse; the person's app is active when they click.
    /// Same answer `CanvasPointerPathChecks` and the film harness give.
    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "sticky-head-gesture requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        acceptFirstMouseEverywhere()
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.sticky-head-gesture.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        let characters = AgentCharacterController.shared
        characters.reduceMotion = { true }
        characters.windowIsVisible = { _ in true }
        characters.adopt(defaults: settings)

        let tallTile = UUID(), targetTile = UUID()
        let tallStart = TileFrame(x: 4600, y: 440, width: 640, height: 2200)
        let targetStart = TileFrame(x: 5320, y: 900, width: 560, height: 520)
        var tallAgent: AgentID?, targetAgent: AgentID?
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings, beforeMount: { delegate, root in
            let project = UUID(uuidString: "00000000-0000-0000-0000-0000000CA104")!
            let zone = UUID(uuidString: "00000000-0000-0000-0000-0000000CA107")!
            let cwd = root.appendingPathComponent("Pb")
            let store = ProjectStore(projectRoot: cwd)
            var state = try store.loadCanvas()
            for (id, title, frame) in [(tallTile, "Tall agent", tallStart), (targetTile, "Target agent", targetStart)] {
                let agent = delegate.qaAgentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: cwd, harness: .codex, mode: .managed,
                    model: AgentCatalogQAFixture.codex.models[0], thinking: "medium",
                    projectId: project, projectRoot: cwd, tileId: id)
                _ = delegate.qaAgentSupervisor.rename(agentID: agent, to: title)
                if id == tallTile { tallAgent = agent } else { targetAgent = agent }
                var tile = Tile(id: id, kind: .managedAgent, title: title, frame: frame,
                                zPosition: .fromLegacyRank(20), runtimeRef: nil,
                                metadata: TileMetadata(launchProfileId: "managed"))
                tile.zoneId = zone
                state.tiles.append(tile)
            }
            try store.saveCanvas(state)
        })
        defer { f.delegate.qaAgentSupervisor.stopAll(); f.tearDown() }
        guard let tallAgent, targetAgent != nil else { throw Failure(description: "precondition: agents were not spawned") }
        let delegate = f.delegate
        let canvas = f.canvas
        canvas.agentJumpDefaults = settings
        canvas.dragMagnetizeDefaults = settings
        guard let tall = canvas.tileView(for: tallTile) as? ManagedAgentTileNSView,
              let target = canvas.tileView(for: targetTile) as? ManagedAgentTileNSView else {
            throw Failure(description: "precondition: the boot mount did not hydrate both agent tiles")
        }

        let canvasSize = NSSize(width: 1200, height: 900)
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: canvasSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.frame = container.bounds
        container.addSubview(canvas)
        window.contentView = container
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        delegate.qaInstallTileFocusMonitor()
        defer { delegate.qaRemoveTileFocusMonitor() }
        delegate.qaRefreshAgentSurfaces()
        spin(0.3)

        var report: [String] = []
        var failures: [String] = []
        let captures = ProcessInfo.processInfo.environment["CONTINUUM_STICKY_HEAD_GESTURE_STILLS"].map { URL(fileURLWithPath: $0) }
        if let captures { try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true) }
        func still(_ name: String) {
            guard let captures else { return }
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            CATransaction.flush()
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: captures.appendingPathComponent("\(name).png"))
        }

        func world(_ id: UUID) -> TileFrame? { canvas.navigationTileSnapshot(for: id)?.worldFrame }
        func hit(_ point: NSPoint) -> NSView? {
            guard let content = window.contentView else { return nil }
            return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        }
        func headPoint(_ fractionX: CGFloat) -> NSPoint? {
            guard let head = tall.qaStickyHeadView else { return nil }
            return head.convert(NSPoint(x: head.bounds.width * fractionX, y: head.bounds.midY), to: nil)
        }
        /// An empty spot on the real title bar: one that moves the tile, and
        /// that the window's hit test gives the tile, never one of its controls.
        func headerPoint() -> NSPoint {
            for step in [0.3, 0.2, 0.1, 0.4, 0.5, 0.6, 0.7, 0.85] {
                let local = NSPoint(x: tall.bounds.width * step, y: tall.chromeBarHeight / 2)
                guard tall.qaDragKindIsMove(at: local) else { continue }
                let point = tall.convert(local, to: nil)
                let view = hit(point)
                if view === tall || view?.superview === tall && !(view is NSControl) { return point }
            }
            return tall.convert(NSPoint(x: tall.bounds.width * 0.3, y: tall.chromeBarHeight / 2), to: nil)
        }
        func clearReferences() {
            guard let composer = target.qaChromeViews.composer else { return }
            while !composer.draft.agentReferences.isEmpty { composer.qaRemoveAgentReference(at: 0) }
            spin(0.1)
        }
        /// The person's state when they reach for a pinned head: working in the
        /// tall agent, its composer holding the keyboard, the camera low on it.
        let pinnedCamera = CanvasViewport(x: 4500, y: 700, zoom: 0.9)
        func settle(camera: CanvasViewport) throws {
            try resetTiles()
            canvas.setViewport(camera)
            spin(0.2)
            _ = delegate.qaFocusBroker.enterScope(.tile(tallTile), reason: .userClick)
            if let text = tall.qaChromeViews.composer?.textView { window.makeFirstResponder(text) }
            spin(0.2)
        }
        func targetDropPoint() -> NSPoint? {
            target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        }
        /// Both tiles back where they started, so no leg inherits another's drop.
        func resetTiles() throws {
            for (view, id, frame) in [(tall as TileNSView, tallTile, tallStart), (target as TileNSView, targetTile, targetStart)] {
                var tile = view.tile
                tile.frame = canvas.tileFrame(fromWorldFrame: frame, tileId: id)
                canvas.updateTile(tile)
            }
            spin(0.3)
            guard world(tallTile) == tallStart, world(targetTile) == targetStart else {
                throw Failure(description: "precondition: could not put the tiles back: \(String(describing: world(tallTile))), \(String(describing: world(targetTile)))")
            }
        }
        func references() -> [AgentID] { target.qaChromeViews.composer?.draft.agentReferences.map(\.agentID) ?? [] }

        // 1. Click on the pinned head.
        do {
            let label = "click on the pinned head"
            try settle(camera: pinnedCamera)
            _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            canvas.tileSelection.clear()
            spin(0.1)
            let before = world(tallTile), camera = canvas.viewport
            still("01-pinned-before-click")
            if let point = headPoint(0.5), hit(point) === tall.qaStickyHeadView {
                try click(at: point, in: window)
                spin(0.4)
                var problems: [String] = []
                if delegate.qaFocusBroker.activeSurface != .tile(tallTile) {
                    problems.append("the tile did not take focus: \(String(describing: delegate.qaFocusBroker.activeSurface))")
                }
                if canvas.canvasState.lastActiveTileId != tallTile, !canvas.tileSelection.ids.contains(tallTile) {
                    problems.append("the tile is not selected")
                }
                if world(tallTile) != before { problems.append("the click moved the tile") }
                if canvas.viewport != camera { problems.append("the click moved the camera: \(camera) → \(canvas.viewport)") }
                if problems.isEmpty { report.append("  \(label): selected and focused, nothing moved") }
                else { failures += problems.map { "[\(label)] \($0)" } }
            } else {
                failures.append("[\(label)] precondition: no pinned head under the window's hit test")
            }
        }

        // 2. The unpinned header keeps its behaviour.
        let headerCamera = CanvasViewport(x: 4500, y: 300, zoom: 0.5)
        do {
            let label = "unpinned header click"
            try settle(camera: headerCamera)
            _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            spin(0.1)
            if tall.qaStickyHead != nil { failures.append("[\(label)] precondition: the head is pinned") }
            let point = headerPoint()
            try click(at: point, in: window)
            spin(NSEvent.doubleClickInterval + 0.5)
            if delegate.qaFocusBroker.activeSurface != .tile(tallTile) {
                failures.append("[\(label)] the tile did not take focus")
            } else {
                report.append("  \(label): focused")
            }
        }
        do {
            let label = "unpinned header drag"
            try settle(camera: headerCamera)
            guard let before = world(tallTile) else { throw Failure(description: "[\(label)] no tile") }
            let camera = canvas.viewport
            let start = headerPoint()
            let grabbed = CanvasEngine.screenToWorld(canvas.convert(start, from: nil), viewport: camera)
            var followed = false, midX = before.x
            try drag(from: start, to: NSPoint(x: start.x - 100, y: start.y), in: window, steps: 8) { step, point in
                guard step == 8, let now = world(tallTile) else { return }
                midX = now.x
                let pointer = CanvasEngine.screenToWorld(canvas.convert(point, from: nil), viewport: canvas.viewport)
                let tolerance = DragMagnetizeConfig.snapReleaseScreenPoints / camera.zoom + 1
                followed = abs((now.x - before.x) - Double(pointer.x - grabbed.x)) <= tolerance
                    && abs(now.y - before.y) <= tolerance
            }
            spin(0.8)
            let after = world(tallTile) ?? before
            var problems: [String] = []
            if canvas.viewport != camera { problems.append("the camera moved: \(camera) → \(canvas.viewport)") }
            if !followed { problems.append("the tile did not follow the pointer: \(midX - before.x) world at the last drag event") }
            if problems.isEmpty { report.append("  \(label): followed the pointer (\(String(format: "%.0f", midX - before.x)) world), landed \(String(format: "%.0f", after.x - before.x)) after auto layout, camera unchanged") }
            else { failures += problems.map { "[\(label)] \($0)" } }
        }
        do {
            let label = "unpinned header onto another agent"
            try settle(camera: headerCamera)
            clearReferences()
            let camera = canvas.viewport
            try drag(from: headerPoint(), to: { targetDropPoint() ?? .zero }, in: window, steps: 10)
            spin(0.5)
            var problems: [String] = []
            if references() != [tallAgent] {
                problems.append("the target's draft does not reference the dragged agent: \(references())")
            }
            if canvas.viewport != camera { problems.append("the camera moved: \(camera) → \(canvas.viewport)") }
            if problems.isEmpty { report.append("  \(label): referenced, camera unchanged") }
            else { failures += problems.map { "[\(label)] \($0)" } }
        }

        // 3. Drag the pinned head to move the tile.
        do {
            let label = "drag the pinned head"
            try settle(camera: pinnedCamera)
            guard let start = headPoint(0.3), let before = world(tallTile) else {
                throw Failure(description: "[\(label)] precondition: no pinned head")
            }
            let camera = canvas.viewport
            let grabbed = CanvasEngine.screenToWorld(canvas.convert(start, from: nil), viewport: camera)
            let grab = CGPoint(x: grabbed.x - before.x, y: grabbed.y - before.y)
            // The real header's middle, as a world offset from the tile's top.
            let headerY = Double(tall.chromeBarHeight) * before.height / Double(tall.bounds.height) / 2
            var zoomedOut = false, fits = false, inHand = false, unpinnedUnderPress = false
            let end = NSPoint(x: start.x - 160, y: start.y)
            try drag(from: start, to: end, in: window, steps: 16) { step, point in
                guard step == 8 else { return }
                still("02-pinned-drag-mid")
                zoomedOut = canvas.viewport.zoom < camera.zoom - 0.01
                // The cause of the bug: the head unpins under the press as the
                // real header comes back, and the drag must carry on regardless.
                unpinnedUnderPress = tall.qaStickyHead == nil
                guard let now = world(tallTile) else { return }
                let screen = CanvasEngine.worldToScreen(CGPoint(x: now.x, y: now.y), viewport: canvas.viewport)
                fits = screen.y >= -0.5 && Double(screen.y) + now.height * canvas.viewport.zoom <= Double(canvasSize.height) + 0.5
                // Eased out, the real header is in the hand, at the grabbed x.
                let pointer = CanvasEngine.screenToWorld(canvas.convert(point, from: nil), viewport: canvas.viewport)
                let tolerance = DragMagnetizeConfig.snapReleaseScreenPoints / canvas.viewport.zoom + 1
                inHand = abs(Double(pointer.x) - (now.x + Double(grab.x))) <= tolerance
                    && abs(Double(pointer.y) - (now.y + headerY)) <= tolerance
            }
            spin(0.8)
            still("03-pinned-drag-dropped")
            var problems: [String] = []
            if !zoomedOut { problems.append("the camera did not ease out while a tile taller than the screen moved") }
            if !fits { problems.append("eased out, the whole tile is not on screen") }
            if !unpinnedUnderPress { problems.append("precondition: the head stayed pinned, so the unpin-under-press path did not run") }
            if !inHand { problems.append("eased out, the real header is not under the pointer") }
            if abs(canvas.viewport.zoom - camera.zoom) > 0.001 { problems.append("the camera did not settle back to zoom \(camera.zoom): \(canvas.viewport.zoom)") }
            guard let after = world(tallTile) else { throw Failure(description: "[\(label)] the tile vanished") }
            if after.x >= before.x - 20 { problems.append("the tile did not move left: \(before.x) → \(after.x)") }
            let pointer = CanvasEngine.screenToWorld(canvas.convert(end, from: nil), viewport: canvas.viewport)
            let tolerance = DragMagnetizeConfig.snapReleaseScreenPoints / canvas.viewport.zoom + 1
            if abs(Double(pointer.x) - (after.x + Double(grab.x))) > tolerance || abs(Double(pointer.y) - (after.y + Double(grab.y))) > tolerance {
                problems.append("after the drop the point grabbed is not under the pointer")
            }
            if tall.qaStickyHead == nil { problems.append("after the drop the head is not pinned") }
            if let head = tall.qaStickyHeadView, hit(end) !== head {
                problems.append("after the drop the pinned head is not under the pointer")
            }
            if problems.isEmpty {
                report.append("  \(label): head unpinned under the press and the drag carried on; eased out to fit with the header in hand, settled back at zoom \(camera.zoom); moved \(String(format: "%.0f", after.x - before.x)), \(String(format: "%.0f", after.y - before.y)) world")
            } else {
                failures += problems.map { "[\(label)] \($0)" }
            }
        }

        // 4. Drag the pinned head onto another agent.
        do {
            let label = "drag the pinned head onto another agent"
            try settle(camera: pinnedCamera)
            guard let start = headPoint(0.3), let before = world(tallTile) else {
                throw Failure(description: "[\(label)] precondition: no pinned head")
            }
            let camera = canvas.viewport
            clearReferences()
            let referenced = references()
            try drag(from: start, to: { targetDropPoint() ?? start }, in: window, steps: 16) { step, _ in
                if step == 14 { still("04-pinned-reference-over-target") }
            }
            spin(0.8)
            var problems: [String] = []
            if references() != referenced + [tallAgent] {
                problems.append("the target's draft does not reference the dragged agent: \(references())")
            }
            if let after = world(tallTile), abs(after.x - before.x) > 0.5 || abs(after.y - before.y) > 0.5 {
                problems.append("a reference moved the dragged tile: \(before) → \(after)")
            }
            if abs(canvas.viewport.zoom - camera.zoom) > 0.001 || abs(canvas.viewport.x - camera.x) > 0.5 || abs(canvas.viewport.y - camera.y) > 0.5 {
                problems.append("the camera did not return after the reference: \(camera) → \(canvas.viewport)")
            }
            if problems.isEmpty { report.append("  \(label): referenced, the tile stayed, the camera returned") }
            else { failures += problems.map { "[\(label)] \($0)" } }
        }

        guard failures.isEmpty else {
            throw Failure(description: "sticky-head-gesture: \(failures.count) failing:\n  " + failures.joined(separator: "\n  ") + "\n passing:\n" + report.joined(separator: "\n"))
        }
        return report.joined(separator: "\n")
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesise \(type)") }
        return event
    }

    /// A real click through the window: mouse-up queued first, mouse-down sent.
    private static func click(at point: NSPoint, in window: NSWindow) throws {
        NSApp.postEvent(try mouse(.leftMouseUp, point, in: window), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, point, in: window))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    private static func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow, steps: Int,
                             each: (Int, NSPoint) -> Void = { _, _ in }) throws {
        try drag(from: start, to: { end }, in: window, steps: steps, each: each)
    }

    /// A paced drag through the window, as a hand makes one: each drag event is
    /// sent through `NSApp.sendEvent` with the run loop turning between them, so
    /// camera steps land mid-drag. `end` is read after the first half, so a
    /// target that moved on screen (the camera eased) is aimed at where it is.
    private static func drag(from start: NSPoint, to end: () -> NSPoint, in window: NSWindow, steps: Int,
                             each: (Int, NSPoint) -> Void = { _, _ in }) throws {
        NSApp.sendEvent(try mouse(.leftMouseDown, start, in: window))
        spin(0.05)
        // A short opening pull, then the rest of the way.
        var point = start
        let opening = NSPoint(x: start.x - 12, y: start.y)
        for step in 1...3 {
            let t = CGFloat(step) / 3
            point = NSPoint(x: start.x + (opening.x - start.x) * t, y: start.y + (opening.y - start.y) * t)
            NSApp.sendEvent(try mouse(.leftMouseDragged, point, in: window))
            spin(0.03)
        }
        spin(0.6)
        let from = point, to = end()
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            point = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            NSApp.sendEvent(try mouse(.leftMouseDragged, point, in: window))
            spin(0.02)
            each(step, point)
        }
        spin(0.1)
        NSApp.sendEvent(try mouse(.leftMouseUp, point, in: window))
    }
}
