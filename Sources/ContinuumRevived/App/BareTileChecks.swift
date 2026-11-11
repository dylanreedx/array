import AppKit
import ContinuumRevivedCore
import ObjectiveC

/// A project tile dragged clearly outside every zone becomes BARE: its stamp is
/// cleared, its WORLD frame is kept, and it stays that way through an auto-layout
/// off→on toggle, a move of its old zone and a remount. Dropping it back into a
/// zone adopts it again (`.plans/auto-layout-night`, the drag-out card).
///
/// Every gesture takes the user's path, `NSApp.sendEvent`, as
/// `CanvasPointerPathChecks` does: the window hit-tests and AppKit routes the drag
/// and release to the view that took the press. Run with auto layout off and on.
@MainActor
enum BareTileChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    typealias Fixture = WorkspaceInvariantsFixture

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// An inactive check app swallows a press as an activation click unless the
    /// view accepts the first mouse; the user's app is active when they drag.
    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    /// Every failed outcome, across both modes: one run names all of them.
    private static var failures: [String] = []
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    static func run() throws {
        acceptFirstMouseEverywhere()
        failures = []
        for autoLayout in [false, true] {
            try exercise(autoLayout: autoLayout)
        }
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
        print("BareTileChecks passed: drag-out stays bare through toggle, zone move and remount; drag-in adopts")
    }

    /// The world delta of the drag-out: note A1a (640,280 240x160, zone A1 at
    /// 600,200 900x700) lands at (-200,1500), centre (-80,1580), clear of every
    /// zone in workspace A by hundreds of points.
    private static let dragOut = CGSize(width: -840, height: 1220)
    private static let zoom = 0.5

    private static func exercise(autoLayout: Bool) throws {
        let mode = "autoLayout=\(autoLayout)"
        let fixture = try Fixture(label: "bare-tile-\(autoLayout)")
        defer { fixture.dispose() }
        try fixture.mount()
        var host = try Host(fixture: fixture, autoLayout: autoLayout, label: mode)
        defer { host.close() }

        let tile = Fixture.noteA1a
        guard let start = host.world(tile) else { throw Failure(message: "\(mode): note A1a is not on the canvas") }
        try host.expectMember(tile, of: Fixture.zoneA1, "\(mode) precondition")
        let expected = TileFrame(x: start.x + dragOut.width, y: start.y + dragOut.height,
                                 width: start.width, height: start.height)

        // 1. Drag it out.
        host.mounted.delegate.qaLastLayoutCommitProjects = nil
        try host.dragHeader(of: tile, byWorld: dragOut)
        // The scoped layout save finds a bare tile's owner through its bare
        // layer: only project A1 is read and written, no full scan.
        let commit = host.mounted.delegate.qaLastLayoutCommitProjects
        check(commit?.loaded == [Fixture.projectA1] && commit?.written == [Fixture.projectA1],
              "\(mode) drag out: the save loaded \(String(describing: commit?.loaded)) and wrote \(String(describing: commit?.written)), expected only project A1")
        host.expectBare(tile, at: expected, "\(mode) after the drag out")

        // 1b. Undo puts it back in its zone where it started; redo takes it out again.
        host.undo()
        let undone = host.world(tile)
        check(host.canvas.qaZoneMembership(of: tile) == Fixture.zoneA1,
              "\(mode) undo of the drag out: membership \(String(describing: host.canvas.qaZoneMembership(of: tile))), expected zone A1")
        check(undone.map { abs($0.x - start.x) < 1 && abs($0.y - start.y) < 1 } == true,
              "\(mode) undo of the drag out: the tile is at \(String(describing: undone)), expected \(start)")
        check(host.persisted(tile)?.zoneId == Fixture.zoneA1,
              "\(mode) undo of the drag out: canvas.json stamps \(String(describing: host.persisted(tile)?.zoneId)), expected zone A1")
        host.redo()
        host.expectBare(tile, at: expected, "\(mode) after redo of the drag out")

        // 1c. A bare tile of the project that sorts SECOND (A2): a save that fell
        // back to scanning every project would read A1 first, so this is the
        // drag that tells a scoped save from a lucky scan.
        if let a2 = host.world(Fixture.noteA2a) {
            host.mounted.delegate.qaLastLayoutCommitProjects = nil
            try host.dragHeader(of: Fixture.noteA2a, byWorld: CGSize(width: 1300, height: 1300))
            let a2Commit = host.mounted.delegate.qaLastLayoutCommitProjects
            check(host.canvas.bareTileIds.contains(Fixture.noteA2a),
                  "\(mode) precondition: note A2a must break out of zone A2 (from \(a2))")
            check(a2Commit?.loaded == [Fixture.projectA2] && a2Commit?.written == [Fixture.projectA2],
                  "\(mode) A2 drag out: the save loaded \(String(describing: a2Commit?.loaded)), expected only project A2")
        } else {
            check(false, "\(mode) precondition: note A2a is not on the canvas")
        }

        // 2. Auto layout off, then on: the toggle Dylan reported.
        host.setAutoLayout(false)
        host.setAutoLayout(true)
        host.expectBare(tile, at: expected, "\(mode) after auto layout off→on")
        if !autoLayout { host.setAutoLayout(false) }

        // 3. Move its old zone: a bare tile is not carried.
        if let before = host.canvas.qaLiveZonePlacement(Fixture.zoneA1) {
            try host.dragZoneHeader(Fixture.zoneA1, byWorld: CGSize(width: -150, height: 0))
            let after = host.canvas.qaLiveZonePlacement(Fixture.zoneA1)
            check(after.map { abs($0.origin.x - (before.origin.x - 150)) < 1 } == true,
                  "\(mode) precondition: dragging zone A1's header did not move it: \(before.origin) -> \(String(describing: after?.origin))")
            host.expectBare(tile, at: expected, "\(mode) after its old zone moved")
        } else {
            check(false, "\(mode) precondition: zone A1 is not live")
        }

        // 4. Remount: quit and mount again, as a relaunch does.
        host.close()
        try fixture.remount(crash: false)
        host = try Host(fixture: fixture, autoLayout: autoLayout, label: mode)
        host.expectBare(tile, at: expected, "\(mode) after a remount")

        // 5. Dropping it inside a zone adopts it: into zone A1, wherever it now is.
        guard let zone = host.canvas.qaLiveZonePlacement(Fixture.zoneA1) else {
            check(false, "\(mode): zone A1 vanished after the remount"); return
        }
        guard let bare = host.world(tile) else { check(false, "\(mode): the tile vanished after the remount"); return }
        // Its centre into the zone's lower-left quarter, clear of the seeded notes.
        let target = CGPoint(x: zone.origin.x + zone.size.width * 0.2, y: zone.origin.y + zone.size.height * 0.8)
        try host.dragHeader(of: tile, byWorld: CGSize(width: target.x - (bare.x + bare.width / 2),
                                                      height: target.y - (bare.y + bare.height / 2)))
        check(host.canvas.qaZoneMembership(of: tile) == Fixture.zoneA1,
              "\(mode) drag back in: the tile was not adopted by zone A1, membership \(String(describing: host.canvas.qaZoneMembership(of: tile)))")
        let persisted = host.persisted(tile)
        check(persisted?.zoneId == Fixture.zoneA1,
              "\(mode) drag back in: canvas.json stamps \(String(describing: persisted?.zoneId)), expected zone A1")
        check(persisted?.isBare == false, "\(mode) drag back in: canvas.json still marks the adopted tile bare")
        if let frame = host.world(tile), let zoneNow = host.canvas.qaLiveZonePlacement(Fixture.zoneA1) {
            let rect = CanvasEngine.zoneWorldFrame(zoneNow)
            check(frame.x >= rect.x - 0.5 && frame.y >= rect.y - 0.5
                  && frame.x + frame.width <= rect.x + rect.width + 0.5
                  && frame.y + frame.height <= rect.y + rect.height + 0.5,
                  "\(mode) drag back in: world frame \(frame) is not inside zone A1 \(rect)")
        }
    }

    // MARK: - A mounted canvas in an offscreen window

    @MainActor
    private struct Host {
        let fixture: Fixture
        let mounted: Fixture.Mounted
        let window: KeyWindow
        let label: String
        var canvas: CanvasNSView { mounted.canvas }

        init(fixture: Fixture, autoLayout: Bool, label: String) throws {
            self.fixture = fixture
            self.label = label
            mounted = try fixture.requireMounted("bare tile \(label)")
            TileInsertSlideChecks.pin(mounted.canvas, autoLayout: autoLayout)
            mounted.canvas.setViewport(CanvasViewport(x: -400, y: -400, zoom: BareTileChecks.zoom))
            window = KeyWindow(contentRect: mounted.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = mounted.canvas
            window.orderFrontOffscreenForChecks()
            window.makeKey()
            mounted.delegate.qaInstallTileFocusMonitor()
            mounted.canvas.layoutSubtreeIfNeeded()
        }

        func close() {
            mounted.delegate.qaRemoveTileFocusMonitor()
            window.orderOut(nil)
            window.contentView = nil
        }

        func world(_ id: UUID) -> TileFrame? {
            canvas.allTilesInWorldFrames().first { $0.id == id }?.frame
        }

        /// The tile as `canvas.json` holds it, after the project's queued save drains.
        func persisted(_ id: UUID) -> Tile? {
            fixture.drain(0.3)
            try? mounted.runtime.controller(for: Fixture.projectA1)?.flushCanvasSave()
            let store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
            return (try? store.loadCanvas())?.tiles.first { $0.id == id }
        }

        /// The canvas's own Undo / Redo actions (the Edit menu's), with the canvas
        /// focused so no tile's text undo takes them.
        func undo() {
            _ = mounted.delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            canvas.undo(nil)
            canvas.layoutSubtreeIfNeeded()
            fixture.drain(0.3)
        }
        func redo() {
            _ = mounted.delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            canvas.redo(nil)
            canvas.layoutSubtreeIfNeeded()
            fixture.drain(0.3)
        }

        func setAutoLayout(_ enabled: Bool) {
            canvas.autoLayoutDefaults.set(enabled, forKey: CanvasAutoLayoutConfig.enabledKey)
            NotificationCenter.default.post(
                name: SettingChangeEvent.name(for: SettingID(rawValue: CanvasAutoLayoutConfig.enabledKey)), object: nil)
            canvas.layoutSubtreeIfNeeded()
            fixture.drain(0.3)
        }

        func expectMember(_ id: UUID, of zoneId: UUID, _ context: String) throws {
            guard canvas.qaZoneMembership(of: id) == zoneId else {
                throw Failure(message: "\(context): tile is in \(String(describing: canvas.qaZoneMembership(of: id))), expected \(zoneId)")
            }
        }

        func expectBare(_ id: UUID, at expected: TileFrame, _ context: String) {
            func near(_ a: TileFrame?, _ b: TileFrame) -> Bool {
                guard let a else { return false }
                return abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1
                    && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
            }
            let membership = canvas.qaZoneMembership(of: id)
            BareTileChecks.check(membership == nil, "\(context): on screen the tile is still a member of \(String(describing: membership))")
            let shown = world(id)
            BareTileChecks.check(near(shown, expected), "\(context): on screen the tile is at \(String(describing: shown)), expected \(expected)")
            let saved = persisted(id)
            BareTileChecks.check(saved != nil, "\(context): canvas.json lost the tile")
            if let saved {
                BareTileChecks.check(saved.zoneId == nil, "\(context): canvas.json stamps it into \(String(describing: saved.zoneId))")
                BareTileChecks.check(saved.isBare, "\(context): canvas.json does not mark it bare, so a relaunch would rescue it")
                BareTileChecks.check(near(saved.frame, expected), "\(context): canvas.json WORLD frame is \(saved.frame), expected \(expected)")
            }
        }

        private func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(message: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }

        /// Press at `grab` (window space), drag in steps by `world` (world points),
        /// release. Canvas space is flipped like the world, so the delta is
        /// applied there and converted back to the window.
        private func drag(fromWindow grab: NSPoint, byWorld delta: CGSize) throws {
            let grabCanvas = canvas.convert(grab, from: nil)
            let zoom = canvas.viewport.zoom
            try send(.leftMouseDown, grab)
            let steps = 8
            var end = grab
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                end = canvas.convert(NSPoint(x: grabCanvas.x + delta.width * zoom * t,
                                             y: grabCanvas.y + delta.height * zoom * t), to: nil)
                try send(.leftMouseDragged, end)
            }
            try send(.leftMouseUp, end)
            canvas.layoutSubtreeIfNeeded()
            fixture.drain(0.4)
        }

        func dragHeader(of id: UUID, byWorld delta: CGSize) throws {
            guard let view = canvas.tileView(for: id) else { throw Failure(message: "\(label): tile \(id) has no view") }
            guard let host = canvas.superview ?? window.contentView else { throw Failure(message: "no canvas host") }
            var tried: [String] = []
            // A note's controls fill the middle of its bar: probe a grid over it.
            let rows = [0.5, 0.35, 0.65, 0.8, 0.2].map { view.chromeBarHeight * $0 }
            let columns = [0.1, 0.14, 0.9, 0.86, 0.5, 0.3, 0.7, 0.06, 0.94]
            for (y, step) in rows.flatMap({ y in columns.map { (y, $0) } }) {
                let local = NSPoint(x: view.bounds.width * step, y: y)
                let move = view.qaDragKindIsMove(at: local)
                let candidate = view.convert(local, to: nil)
                let hit = canvas.hitTest(canvas.convert(canvas.convert(candidate, from: nil), to: host))
                tried.append("\(step),\(Int(y)): move=\(move) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                guard move else { continue }
                if hit === view || (hit?.isDescendant(of: view) == true && !(hit is NSControl)) {
                    try drag(fromWindow: candidate, byWorld: delta)
                    return
                }
            }
            throw Failure(message: "\(label): tile \(id) has no empty title-bar point; bar \(view.chromeBarHeight), bounds \(view.bounds); \(tried)")
        }

        func dragZoneHeader(_ zoneId: UUID, byWorld delta: CGSize) throws {
            guard let header = canvas.qaZoneHeaderGrabRect(zoneId) else {
                throw Failure(message: "\(label): zone \(zoneId) has no header")
            }
            // Left of centre: clear of the name field and the header's buttons.
            let grab = canvas.convert(NSPoint(x: header.minX + header.width * 0.35, y: header.midY), to: nil)
            try drag(fromWindow: grab, byWorld: delta)
        }
    }
}
