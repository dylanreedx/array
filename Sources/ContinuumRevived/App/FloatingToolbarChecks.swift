import AppKit
import ContinuumRevivedCore
import Foundation

/// `--floating-toolbar-check`. Drives `FloatingToolbarHostView` installed in a
/// canvas-sized pane of a real (offscreen) window, the way
/// `makeWorkspaceContentView` installs it, and asserts what Dylan rejected the
/// panel version for: it must live in that pane and open no window, rest only
/// on canvas edges, land on the nearest edge after a drag with the matching
/// orientation, keep that edge for every later host, and show hover labels and
/// menus beside the bar rather than inside (and clipped by) it.
@MainActor
enum FloatingToolbarChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    static func run() throws {
        try checkCommandRegistryDrivesButtons()
        try checkLivesInsideTheCanvas()
        try checkDragSnapsToEveryEdge()
        try checkEdgeIsSharedAcrossHosts()
        try checkRestingBarClearsTheShortcutRail()
        try checkMotionIsOneSmoothModel()
        try checkFlickCarriesToTheFarEdge()
        try checkZoneToolArmsAndDraws()
        try checkHoverLabelSitsBesideTheBar()
        try checkAgentAndTerminalMenus()
        try checkSettingsWriteAndReset()
        print("floating-toolbar: in-canvas overlay with no window, edge-only landing on all four edges with orientation, global edge restore, rail clearance, frame-by-frame capsule/icon agreement through a swing, no turn in open canvas, flick projection, zone draw tool, unclipped hover labels, provider and profile menus, settings")
    }

    private struct Fixture {
        let window: NSWindow
        let pane: NSView
        let host: FloatingToolbarHostView
        let defaults: UserDefaults
        let suite: String
        var selections: [FloatingToolbarHostView.Selection] { box.selections }
        let box: SelectionBox

        func tearDown() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private final class SelectionBox { var selections: [FloatingToolbarHostView.Selection] = [] }

    private static func makeFixture(suite: String? = nil, size: NSSize = NSSize(width: 1_200, height: 800)) throws -> Fixture {
        let suite = suite ?? "array.floatingToolbar.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated toolbar preferences")
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pane = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = pane
        let box = SelectionBox()
        let host = FloatingToolbarHostView(
            defaults: defaults,
            terminalProfiles: { [FloatingToolbarProfile(id: "shell", title: "Shell"), FloatingToolbarProfile(id: "claude", title: "Claude")] },
            onSelection: { box.selections.append($0) })
        host.reduceMotion = { true }
        host.install(in: pane)
        return Fixture(window: window, pane: pane, host: host, defaults: defaults, suite: suite, box: box)
    }

    private static func checkCommandRegistryDrivesButtons() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let expected = CommandRegistry.definitions().compactMap(\.floatingToolbarItem)
        let titles = fixture.host.toolbar.buttons.map(\.item.title)
        try expect(Set(titles) == Set(expected.map(\.title)) && titles.count == expected.count,
                   "toolbar buttons diverged from CommandRegistry.definitions(): \(titles)")
        try expect(titles.first == "Zone", "Create Zone is not the first group: \(titles)")
        let dividers = fixture.host.toolbar.subviews.filter { $0 is ToolbarDividerView }.count
        try expect(dividers == 2, "expected two group dividers (zone | agent, terminal | tiles), found \(dividers)")
        let choiceButtons = fixture.host.toolbar.buttons.filter { FloatingToolbarView.hasChoices($0.item) }.map(\.item.title)
        try expect(Set(choiceButtons) == ["Agent", "Terminal"], "chevron menus belong to Agent and Terminal only, got \(choiceButtons)")
    }

    private static func checkLivesInsideTheCanvas() throws {
        let windowsBefore = NSApp.windows.count
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        try expect(NSApp.windows.count == windowsBefore + 1,
                   "installing the toolbar opened a window of its own (\(NSApp.windows.count - windowsBefore - 1) extra)")
        try expect(host.superview === fixture.pane && host.toolbar.window === fixture.window,
                   "the toolbar is not a view of the canvas pane's window")
        try expect(host.frame == fixture.pane.bounds, "the toolbar host does not cover the canvas pane")
        try expect(fixture.pane.subviews.last === host, "the toolbar host is not stacked above the canvas")
        try expect((host.toolbar.layer?.borderWidth ?? 1) == 0, "the toolbar paints a border")
        let empty = NSPoint(x: fixture.pane.bounds.midX, y: fixture.pane.bounds.midY)
        try expect(host.hitTest(empty) == nil, "the host swallows clicks on the empty canvas")
        let onBar = NSPoint(x: host.toolbar.frame.midX, y: host.toolbar.frame.midY)
        try expect(host.hitTest(onBar)?.isDescendant(of: host.toolbar) == true, "the bar does not receive its own clicks")
    }

    private static func restingFrame(_ host: FloatingToolbarHostView, _ edge: FloatingToolbarEdge) -> NSRect {
        FloatingToolbarGeometry.restingFrame(
            size: host.toolbar.preferredSize(for: edge.orientation), edge: edge, in: host.bounds)
    }

    private static func checkDragSnapsToEveryEdge() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        let bounds = host.bounds
        try expect(host.edge == .bottom && host.toolbar.frame == restingFrame(host, .bottom),
                   "a fresh toolbar does not rest centred on the bottom edge: \(host.toolbar.frame)")
        var moves = 0
        host.onPositionChanged = { moves += 1 }
        // Release points near each edge but well off-centre: the bar must land
        // centred on that edge regardless of where along it the hand let go.
        let releases: [(FloatingToolbarEdge, NSPoint)] = [
            (.left, NSPoint(x: bounds.minX + 60, y: bounds.minY + 230)),
            (.top, NSPoint(x: bounds.maxX - 300, y: bounds.maxY - 50)),
            (.right, NSPoint(x: bounds.maxX - 40, y: bounds.maxY - 260)),
            (.bottom, NSPoint(x: bounds.minX + 280, y: bounds.minY + 30)),
        ]
        for (edge, release) in releases {
            let start = NSPoint(x: host.toolbar.frame.midX, y: host.toolbar.frame.midY)
            host.qaDrag(from: start, to: release)
            let frame = host.toolbar.frame
            try expect(host.edge == edge, "a release near the \(edge) edge landed on \(host.edge)")
            try expect(frame == restingFrame(host, edge), "the \(edge) landing is not centred on the edge: \(frame)")
            try expect(host.toolbar.orientation == edge.orientation,
                       "the \(edge) edge left the bar \(host.toolbar.orientation == .vertical ? "vertical" : "horizontal")")
            try expect(edge.orientation == .vertical ? frame.height > frame.width : frame.width > frame.height,
                       "the \(edge) bar's shape does not match its orientation: \(frame)")
            try expect(fixture.defaults.string(forKey: FloatingToolbarConfig.positionEdgeKey) == edge.rawValue,
                       "the \(edge) landing was not persisted")
            try expect(bounds.contains(frame), "the \(edge) bar left the canvas: \(frame)")
        }
        try expect(moves == releases.count, "onboarding heard \(moves) moves for \(releases.count) drags")

        // A press that never travels is a click, not a move.
        let before = host.toolbar.frame
        let center = NSPoint(x: before.midX, y: before.midY)
        host.qaDrag(from: center, to: center)
        try expect(host.toolbar.frame == before && moves == releases.count, "a stationary press moved the bar")

        // Resizing the canvas keeps the bar centred on its edge.
        fixture.pane.setFrameSize(NSSize(width: 900, height: 640))
        fixture.pane.layoutSubtreeIfNeeded()
        try expect(host.toolbar.frame == restingFrame(host, .bottom), "a canvas resize left the bar off its edge")
    }

    private static func checkEdgeIsSharedAcrossHosts() throws {
        let first = try makeFixture()
        first.host.qaDrag(
            from: NSPoint(x: first.host.toolbar.frame.midX, y: first.host.toolbar.frame.midY),
            to: NSPoint(x: first.host.bounds.maxX - 30, y: first.host.bounds.midY))
        try expect(first.host.edge == .right, "setup drag did not reach the right edge")
        first.window.close()
        // A second host on the same preferences — another workspace, or a relaunch.
        let second = try makeFixture(suite: first.suite)
        defer { second.tearDown() }
        try expect(second.host.edge == .right && second.host.toolbar.frame == restingFrame(second.host, .right)
                   && second.host.toolbar.orientation == .vertical,
                   "a new host did not restore the right edge: \(second.host.edge) \(second.host.toolbar.frame)")
    }

    private static func checkRestingBarClearsTheShortcutRail() throws {
        let fixture = try makeFixture(size: NSSize(width: 900, height: 640))
        defer { fixture.tearDown() }
        let host = fixture.host
        // The rail's real shape: bottom-right, 12pt in, wide enough to reach
        // under a centred bar on a narrow canvas.
        let rail = NSRect(x: host.bounds.maxX - 12 - 360, y: 12, width: 360, height: 18)
        try expect(restingFrame(host, .bottom).intersects(rail), "fixture rail does not reach the centred bar; the case is vacuous")
        host.obstacles = { [rail] }
        host.refreshSettings()
        let frame = host.toolbar.frame
        try expect(!frame.intersects(rail), "the resting bar covers the shortcut rail: \(frame) vs \(rail)")
        try expect(frame.minY == FloatingToolbarGeometry.margin, "clearing the rail lifted the bar off the bottom edge: \(frame)")
        try expect(host.bounds.insetBy(dx: FloatingToolbarGeometry.margin, dy: FloatingToolbarGeometry.margin).contains(frame),
                   "clearing the rail pushed the bar off the canvas: \(frame)")
    }

    private static func checkHoverLabelSitsBesideTheBar() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        for edge in FloatingToolbarEdge.allCases {
            fixture.defaults.set(edge.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)
            host.refreshSettings()
            for button in host.toolbar.buttons {
                try expect(host.qaHover(title: button.item.title, inside: true), "could not hover \(button.item.title)")
                guard let pill = host.hoverPill else {
                    throw Failure(description: "hovering \(button.item.title) on the \(edge) edge showed no label")
                }
                try expect(pill.superview === host && !pill.isDescendant(of: host.toolbar),
                           "the \(button.item.title) label is inside the bar, where it gets clipped")
                try expect(host.bounds.contains(pill.frame), "the \(button.item.title) label leaves the canvas on the \(edge) edge")
                try expect(!pill.frame.intersects(host.toolbar.frame), "the \(button.item.title) label covers the bar on the \(edge) edge")
                try expect((pill.layer?.borderWidth ?? 1) == 0, "the hover label paints a border")
                try expect(pill.qaLabelsFit, "the \(button.item.title) label is truncated")
                host.qaHover(title: button.item.title, inside: false)
                try expect(host.hoverPill == nil, "leaving \(button.item.title) left its label up")
            }
        }
    }

    private static func checkAgentAndTerminalMenus() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        try expect(host.qaActivate(title: "Agent"), "no Agent button")
        guard let agentMenu = host.choicesMenu else { throw Failure(description: "Agent opened no menu") }
        try expect(agentMenu.superview === host && !agentMenu.frame.intersects(host.toolbar.frame)
                   && host.bounds.contains(agentMenu.frame), "the Agent menu is not beside the bar inside the canvas")
        let expected = FloatingToolbarHostView.agentChoices.map(\.0)
        try expect(agentMenu.rows.map(\.title) == expected && Array(expected.prefix(3)) == ["Claude Code", "Codex", "Pi"],
                   "the Agent menu rows are \(agentMenu.rows.map(\.title))")
        try expect(agentMenu.owner?.isActive == true, "the Agent button is not marked while its menu is open")
        agentMenu.rows[1].qaPress()
        try expect(fixture.selections.last == .agentHarness(.codex), "choosing Codex dispatched \(String(describing: fixture.selections.last))")
        try expect(host.choicesMenu == nil && host.toolbar.buttons.allSatisfy { !$0.isActive }, "choosing a provider left the menu open")

        try expect(host.qaActivate(title: "Agent") && host.qaActivate(title: "Agent") && host.choicesMenu == nil,
                   "a second press on Agent did not close its menu")
        try expect(host.qaActivate(title: "Terminal"), "no Terminal button")
        try expect(host.choicesMenu?.rows.map(\.title) == ["Shell", "Claude"], "the Terminal menu does not list launch profiles")
        host.choicesMenu?.rows[0].qaPress()
        try expect(fixture.selections.last == .terminalProfile("shell") && host.choicesMenu == nil, "choosing a profile did not dispatch it")

    }

    private final class ZoneTargetStub: NSResponder, ZoneDrawingTarget {
        var began = 0
        var drawn = 0
        var drawsOnFinish = true
        func beginZoneDrawing(with event: NSEvent) { began += 1 }
        func continueZoneDrawing(with event: NSEvent) {}
        func finishZoneDrawing(with event: NSEvent) -> Bool {
            if drawsOnFinish { drawn += 1 }
            return drawsOnFinish
        }
    }

    private static func checkZoneToolArmsAndDraws() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        let target = ZoneTargetStub()
        host.zoneDrawing = target
        try expect(host.qaActivate(title: "Zone"), "no Zone button")
        guard let capture = host.zoneCapture else { throw Failure(description: "Zone did not arm the draw tool") }
        try expect(fixture.selections.isEmpty, "Zone created something instead of arming the tool: \(fixture.selections)")
        try expect(capture.frame == host.bounds && host.toolbar.buttons.first { $0.item.title == "Zone" }?.isActive == true,
                   "the armed tool does not cover the canvas or the Zone button is not marked")
        let overTile = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        try expect(host.hitTest(overTile) === capture, "an armed tool does not own presses on the canvas")
        try expect(host.hitTest(NSPoint(x: host.toolbar.frame.midX, y: host.toolbar.frame.midY))?.isDescendant(of: host.toolbar) == true,
                   "the armed tool covers the toolbar")
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: host.convert(overTile, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw Failure(description: "could not synthesise \(type)") }
            return e
        }
        // A press that draws nothing keeps the tool armed.
        target.drawsOnFinish = false
        capture.mouseDown(with: try event(.leftMouseDown))
        capture.mouseUp(with: try event(.leftMouseUp))
        try expect(target.began == 1 && host.zoneCapture != nil, "a click without a drag disarmed the tool")
        // A drag that draws a zone disarms it.
        target.drawsOnFinish = true
        capture.mouseDown(with: try event(.leftMouseDown))
        capture.mouseUp(with: try event(.leftMouseUp))
        try expect(target.drawn == 1 && host.zoneCapture == nil && capture.superview == nil
                   && host.toolbar.buttons.allSatisfy { !$0.isActive }, "drawing a zone left the tool armed")
        // Pressing Zone again disarms.
        host.qaActivate(title: "Zone")
        host.qaActivate(title: "Zone")
        try expect(host.zoneCapture == nil, "a second press on Zone did not disarm the tool")
    }

    private static func checkMotionIsOneSmoothModel() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        host.reduceMotion = { false }
        let bounds = host.bounds
        var time = ProcessInfo.processInfo.systemUptime
        var frames = 0
        var largestTurnPerFrame: CGFloat = 0
        func frame() throws {
            let before = host.qaAngle
            host.step(by: 1.0 / 120)
            frames += 1
            largestTurnPerFrame = max(largestTurnPerFrame, abs(host.qaAngle - before))
            try expect(host.toolbar.qaItemsRideTheCapsule, "frame \(frames): an icon left the capsule at angle \(host.qaAngle)")
        }
        func move(to point: NSPoint) throws {
            time += 1.0 / 60
            host.qaPointer(.moved, at: point, time: time)
            try expect(host.toolbar.qaItemsRideTheCapsule, "after a move to \(point): an icon left the capsule")
            try frame()
            try frame()
        }
        let start = NSPoint(x: host.toolbar.frame.midX, y: host.toolbar.frame.midY)
        host.qaPointer(.began, at: start, time: time)
        // Out into open canvas, angled toward the left side: it must not turn.
        let open = NSPoint(x: bounds.minX + 340, y: bounds.midY)
        for step in 1...20 {
            let t = CGFloat(step) / 20
            try move(to: NSPoint(x: start.x + (open.x - start.x) * t, y: start.y + (open.y - start.y) * t))
        }
        try expect(host.qaAngle == 0, "the bar turned in open canvas (angle \(host.qaAngle))")
        // Into the left edge's band: it swings to stand, over several frames.
        let nearLeft = NSPoint(x: bounds.minX + 60, y: bounds.midY + 40)
        for step in 1...10 {
            let t = CGFloat(step) / 10
            try move(to: NSPoint(x: open.x + (nearLeft.x - open.x) * t, y: open.y + (nearLeft.y - open.y) * t))
        }
        for _ in 0..<120 { try frame() }
        try expect(abs(host.qaAngle + .pi / 2) < 0.001, "near the left edge the bar did not stand (angle \(host.qaAngle))")
        try expect(largestTurnPerFrame < .pi / 2 / 6, "the swing jumped \(largestTurnPerFrame) rad in one frame")
        // Hover labels wait for rest.
        host.qaHover(title: "Agent", inside: true)
        try expect(host.hoverPill == nil, "a hover label appeared on a moving bar")
        time += 0.2
        host.qaPointer(.ended, at: nearLeft, time: time)
        var guardFrames = 0
        while host.isMoving, guardFrames < 600 { try frame(); guardFrames += 1 }
        try expect(!host.isMoving, "the landing never came to rest")
        try expect(host.edge == .left && host.toolbar.frame == restingFrame(host, .left),
                   "the bar did not land centred on the left edge: \(host.edge) \(host.toolbar.frame)")
    }

    private static func checkFlickCarriesToTheFarEdge() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        fixture.defaults.set(FloatingToolbarEdge.left.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)
        host.refreshSettings()
        // A short, fast throw toward the right, released while still on the
        // left-hand side of the canvas.
        let start = NSPoint(x: host.toolbar.frame.midX, y: host.toolbar.frame.midY)
        let release = NSPoint(x: start.x + 220, y: start.y)
        try expect(FloatingToolbarGeometry.region(of: release, in: host.bounds) == .left,
                   "fixture release point is not on the left side; the flick case is vacuous")
        var time = ProcessInfo.processInfo.systemUptime
        host.qaPointer(.began, at: start, time: time)
        for step in 1...4 {
            time += 0.012
            host.qaPointer(.moved, at: NSPoint(x: start.x + 55 * CGFloat(step), y: start.y), time: time)
        }
        host.qaPointer(.ended, at: release, time: time + 0.004)
        try expect(host.edge == .right, "a fast throw to the right landed on \(host.edge)")
        // The same path, released after a pause, stays where the hand left it.
        host.qaRunMotion()
        let second = NSPoint(x: host.toolbar.frame.midX, y: host.toolbar.frame.midY)
        time += 1
        host.qaPointer(.began, at: second, time: time)
        for step in 1...4 {
            time += 0.012
            host.qaPointer(.moved, at: NSPoint(x: second.x - 55 * CGFloat(step), y: second.y), time: time)
        }
        host.qaPointer(.ended, at: NSPoint(x: second.x - 220, y: second.y), time: time + 0.3)
        try expect(host.edge == .right, "a paused release was thrown anyway (landed \(host.edge))")
    }

    private static func checkSettingsWriteAndReset() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let host = fixture.host
        let defaults = fixture.defaults
        let definitions = CommandRegistry.definitions().filter { $0.floatingToolbarItem != nil }
        guard let first = definitions.first, let firstItem = first.floatingToolbarItem else {
            throw Failure(description: "the command registry has no toolbar items")
        }
        let count = host.toolbar.buttons.count
        let key = FloatingToolbarConfig.itemVisibleKey(commandID: first.id.rawValue)
        let settings = FloatingToolbarSettingsView(defaults: defaults)
        try settings.qaActivateControl("ArrayFloatingToolbarSetting.\(key)")
        host.refreshSettings()
        try expect(host.toolbar.buttons.count == count - 1 && !host.toolbar.buttons.contains { $0.item.title == firstItem.title },
                   "hiding \(firstItem.title) in Settings did not remove its button")
        try expect(host.toolbar.frame == restingFrame(host, host.edge), "the bar did not re-centre after losing a button")

        try settings.qaActivateControl("ArrayFloatingToolbarSetting.\(FloatingToolbarConfig.visibleKey)")
        host.refreshSettings()
        try expect(host.toolbar.isHidden, "Show Toolbar off did not hide the bar")
        try settings.qaActivateControl("ArrayFloatingToolbarSetting.\(FloatingToolbarConfig.visibleKey)")
        host.refreshSettings()
        try expect(!host.toolbar.isHidden, "Show Toolbar on did not bring the bar back")

        defaults.set(FloatingToolbarEdge.left.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)
        host.refreshSettings()
        try settings.qaActivateControl("ArrayFloatingToolbarResetPosition")
        host.refreshSettings()
        try expect(defaults.object(forKey: FloatingToolbarConfig.positionEdgeKey) == nil && host.edge == .bottom,
                   "Reset Position did not return the bar to the bottom edge")
    }
}
