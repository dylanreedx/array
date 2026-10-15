import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// What the toolbar's Zone tool drives: the canvas's own zone marquee, started
/// from wherever the user presses. `CanvasNSView` is the one production target.
@MainActor
protocol ZoneDrawingTarget: NSResponder {
    func beginZoneDrawing(with event: NSEvent)
    func continueZoneDrawing(with event: NSEvent)
    /// True when the drag drew a zone.
    func finishZoneDrawing(with event: NSEvent) -> Bool
}

extension CanvasNSView: ZoneDrawingTarget {}

/// The creation toolbar's host: a transparent overlay covering the canvas pane,
/// a sibling of the canvas like the shortcut rail.
///
/// It is deliberately NOT a window. The first version was an `NSPanel`: the
/// panel drew a window border around the whole bar, clipped every hover label
/// to its own corner radius, and floated over other apps. In here the bar, its
/// labels and its menus are all views of one host, so a label can sit beside
/// the bar without being cut off, and nothing exists outside the canvas.
///
/// The bar rests centred on one edge of the canvas; the edge is one global
/// preference, so every workspace shares it. Motion is one model, stepped by a
/// display link: a PIVOT (the point on the bar's centre line the hand holds)
/// and an ANGLE (0 lying along the bottom and top edges, -90° standing on the
/// sides). The bar is drawn from those two values every frame, so the capsule
/// and its icons can never disagree. Changing orientation swings the bar about
/// the pivot like a stick, icons kept upright; landing is a spring seeded with
/// the pointer's own velocity, so a flick carries.
@MainActor
final class FloatingToolbarHostView: NSView {
    enum Selection: Equatable {
        case palette(LaunchPaletteAction)
        case terminalProfile(String)
        case agentHarness(AgentHarness)
        case fanOutQueueSelection
    }

    static let didChangeSettings = Notification.Name("array.floatingToolbar.settingsChanged")

    /// How far the pointer travels before a press on a button becomes a drag.
    static let dragThreshold: CGFloat = 3
    /// The landing spring: settles in about a third of a second with a little
    /// give, the canvas's jelly rather than a hard snap.
    static let landing = FloatingToolbarSpring(response: 0.38, dampingRatio: 0.74)
    /// The swing between orientations: slightly firmer, so icons do not wobble.
    static let swing = FloatingToolbarSpring(response: 0.34, dampingRatio: 0.86)
    /// How long the pointer's recent path counts toward a flick.
    static let flickWindow: TimeInterval = 0.08
    /// How far ahead of the release a flick projects the landing.
    static let flickProjection: TimeInterval = 0.16

    let toolbar = FloatingToolbarView(frame: .zero)
    var onPositionChanged: (() -> Void)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Other canvas chrome, in this view's coordinates, the resting bar must not
    /// cover — the shortcut rail in the bottom-right corner.
    var obstacles: () -> [NSRect] = { [] }
    /// The canvas, for the Zone tool.
    weak var zoneDrawing: ZoneDrawingTarget?
    private(set) var edge: FloatingToolbarEdge
    private(set) var hoverPill: ToolbarHoverPillView?
    private(set) var choicesMenu: ToolbarChoicesMenuView?
    private(set) var zoneCapture: ZoneDrawCaptureView?

    private let defaults: UserDefaults
    private let onSelection: (Selection) -> Void
    private let terminalProfiles: () -> [FloatingToolbarProfile]
    private var menuMonitor: Any?
    private var zoneMonitor: Any?
    private var settingsObserver: NSObjectProtocol?

    // The motion model (see the type comment).
    private var pivot: NSPoint = .zero
    private var pivotVelocity: CGVector = .zero
    private var pivotTarget: NSPoint = .zero
    private var angle: CGFloat = 0
    private var angleVelocity: CGFloat = 0
    private var angleTarget: CGFloat = 0
    /// Distance from the bar's leading end to the pivot, along the bar.
    private var pivotAlong: CGFloat = 0
    /// The hand's offset from the centre line, so a grab never jumps.
    private var pivotAcross: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    private var dragging = false
    private var dragMoved = false
    private var dragStart: NSPoint = .zero
    private var pointer: NSPoint = .zero
    private var samples: [(time: TimeInterval, point: NSPoint)] = []

    init(
        defaults: UserDefaults = .standard,
        terminalProfiles: @escaping () -> [FloatingToolbarProfile],
        onSelection: @escaping (Selection) -> Void
    ) {
        self.defaults = defaults
        self.terminalProfiles = terminalProfiles
        self.onSelection = onSelection
        edge = FloatingToolbarEdge.stored(in: defaults)
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        setAccessibilityIdentifier("ArrayFloatingToolbarHost")
        toolbar.defaults = defaults
        toolbar.onButtonHover = { [weak self] button, inside in self?.buttonHover(button, inside: inside) }
        toolbar.onButtonActivate = { [weak self] button in self?.activate(button) }
        toolbar.onDrag = { [weak self] phase, event in self?.drag(phase, event: event) }
        addSubview(toolbar)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Self.didChangeSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSettings() }
        }
        refreshSettings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let menuMonitor { NSEvent.removeMonitor(menuMonitor) }
        if let zoneMonitor { NSEvent.removeMonitor(zoneMonitor) }
        link?.invalidate()
    }

    /// Covers `pane` and stacks above everything already in it.
    func install(in pane: NSView) {
        frame = pane.bounds
        pane.addSubview(self, positioned: .above, relativeTo: nil)
        settle()
    }

    /// Transparent everywhere but the bar, its label, its menu and an armed Zone
    /// tool, so the canvas keeps every other click, scroll and gesture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        closeMenu()
        hideHoverPill()
        zoneCapture?.frame = bounds
        needsLayout = true
    }

    /// Re-rests the bar on every layout pass, which is when the canvas size and
    /// the obstacles' constraint-solved frames are both current.
    override func layout() {
        super.layout()
        if !dragging, link == nil { settle() }
    }

    func refreshSettings() {
        let visible = defaults.object(forKey: FloatingToolbarConfig.visibleKey) == nil
            ? FloatingToolbarConfig.defaultVisible
            : defaults.bool(forKey: FloatingToolbarConfig.visibleKey)
        closeMenu()
        hideHoverPill()
        disarmZoneTool()
        toolbar.isHidden = !visible
        toolbar.rebuildButtons()
        edge = FloatingToolbarEdge.stored(in: defaults)
        stopMotion()
        settle()
    }

    // MARK: The motion model

    var isMoving: Bool { dragging || link != nil }

    private var restingFrame: NSRect {
        FloatingToolbarGeometry.restingFrame(
            size: toolbar.preferredSize(for: edge.orientation), edge: edge, in: bounds, avoiding: obstacles())
    }

    /// Where the pivot sits when the bar rests on `edge`.
    private func restingPivot(for edge: FloatingToolbarEdge, frame: NSRect) -> NSPoint {
        edge.orientation == .vertical
            ? NSPoint(x: frame.midX, y: frame.maxY - pivotAlong)
            : NSPoint(x: frame.minX + pivotAlong, y: frame.midY)
    }

    /// Puts the bar at rest on its edge, with no motion.
    private func settle() {
        let frame = restingFrame
        angle = edge.angle
        angleTarget = angle
        angleVelocity = 0
        pivot = restingPivot(for: edge, frame: frame)
        pivotTarget = pivot
        pivotVelocity = .zero
        toolbar.orientation = edge.orientation
        toolbar.angle = angle
        toolbar.frame = frame
        toolbar.render()
        window?.invalidateCursorRects(for: toolbar)
    }

    /// Draws the bar from the pivot and angle.
    private func render() {
        let length = toolbar.preferredSize(for: .horizontal).width
        let axis = CGVector(dx: cos(angle), dy: sin(angle))
        let start = NSPoint(x: pivot.x - axis.dx * pivotAlong, y: pivot.y - axis.dy * pivotAlong)
        let center = NSPoint(x: start.x + axis.dx * length / 2, y: start.y + axis.dy * length / 2)
        let size = FloatingToolbarGeometry.boundingSize(length: length, thickness: FloatingToolbarView.thickness, angle: angle)
        toolbar.angle = angle
        toolbar.frame = FloatingToolbarGeometry.frame(centeredAt: center, size: size)
        toolbar.render()
    }

    private func startMotion() {
        if reduceMotion() {
            stopMotion()
            angle = angleTarget
            if dragging {
                pivot = heldPivot
                render()
            } else {
                settle()
            }
            return
        }
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    private func stopMotion() {
        link?.invalidate()
        link = nil
        angleVelocity = 0
        pivotVelocity = .zero
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTick == 0 ? 1.0 / 120 : min(now - lastTick, 1.0 / 30)
        lastTick = now
        step(by: elapsed)
    }

    /// Advances both springs. Public to checks so they can run the motion
    /// frame by frame without a display.
    func step(by elapsed: TimeInterval) {
        var remaining = elapsed
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 240)
            remaining -= dt
            Self.swing.advance(&angle, velocity: &angleVelocity, toward: angleTarget, dt: dt)
            if dragging {
                pivot = heldPivot
            } else {
                var vx = pivotVelocity.dx, vy = pivotVelocity.dy
                Self.landing.advance(&pivot.x, velocity: &vx, toward: pivotTarget.x, dt: dt)
                Self.landing.advance(&pivot.y, velocity: &vy, toward: pivotTarget.y, dt: dt)
                pivotVelocity = CGVector(dx: vx, dy: vy)
            }
        }
        // The bar turns between the two orientations; its resting shape is the
        // one it is closer to.
        toolbar.orientation = abs(angle) > .pi / 4 ? .vertical : .horizontal
        let angleSettled = abs(angle - angleTarget) < 0.001 && abs(angleVelocity) < 0.01
        let pivotSettled = dragging || (hypot(pivot.x - pivotTarget.x, pivot.y - pivotTarget.y) < 0.2
            && hypot(pivotVelocity.dx, pivotVelocity.dy) < 4)
        if angleSettled, pivotSettled {
            stopMotion()
            if dragging { angle = angleTarget; render() } else { settle() }
        } else {
            render()
        }
    }

    // MARK: Drag

    /// The pivot under the hand: the pointer, less the grab's offset from the
    /// centre line at the bar's current angle.
    private var heldPivot: NSPoint {
        NSPoint(x: pointer.x + sin(angle) * pivotAcross, y: pointer.y - cos(angle) * pivotAcross)
    }

    private func drag(_ phase: FloatingToolbarView.DragPhase, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .began:
            closeMenu()
            hideHoverPill()
            disarmZoneTool()
            // Re-anchor the pivot under the hand without moving the bar.
            let axis = CGVector(dx: cos(angle), dy: sin(angle))
            let length = toolbar.preferredSize(for: .horizontal).width
            let start = NSPoint(x: pivot.x - axis.dx * pivotAlong, y: pivot.y - axis.dy * pivotAlong)
            let offset = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            pivotAlong = min(max(offset.dx * axis.dx + offset.dy * axis.dy, 0), length)
            pivotAcross = offset.dx * -axis.dy + offset.dy * axis.dx
            pointer = point
            pivot = heldPivot
            pivotVelocity = .zero
            dragging = true
            dragMoved = false
            dragStart = point
            samples = [(event.timestamp, point)]
        case .moved:
            guard dragging else { return }
            if !dragMoved {
                guard hypot(point.x - dragStart.x, point.y - dragStart.y) > Self.dragThreshold else { return }
                dragMoved = true
            }
            pointer = NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
            samples.append((event.timestamp, pointer))
            samples.removeAll { $0.time < event.timestamp - Self.flickWindow }
            // Turn only near an edge of the other orientation, never in open canvas.
            let region = FloatingToolbarGeometry.region(of: pointer, in: bounds)
            if FloatingToolbarGeometry.isNear(pointer, edge: region, in: bounds) {
                angleTarget = region.angle
            }
            pivot = heldPivot
            if abs(angle - angleTarget) > 0.001 { startMotion() } else { render() }
        case .ended:
            guard dragging else { return }
            dragging = false
            guard dragMoved else { return }
            let velocity = flickVelocity(endingAt: event.timestamp)
            let projected = NSPoint(
                x: pointer.x + velocity.dx * Self.flickProjection,
                y: pointer.y + velocity.dy * Self.flickProjection)
            edge = FloatingToolbarGeometry.region(of: projected, in: bounds)
            defaults.set(edge.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)
            angleTarget = edge.angle
            pivotTarget = restingPivot(for: edge, frame: restingFrame)
            pivotVelocity = velocity
            startMotion()
            onPositionChanged?()
        }
    }

    private func flickVelocity(endingAt time: TimeInterval) -> CGVector {
        guard let first = samples.first, let last = samples.last,
              time - last.time < Self.flickWindow / 2,
              last.time - first.time > 0.008 else { return .zero }
        let dt = last.time - first.time
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    /// Test seam: a whole drag through the mouse path — press at `start`,
    /// travel to `end` in `duration` seconds, release.
    func qaDrag(from start: NSPoint, to end: NSPoint, duration: TimeInterval = 0.6) {
        guard let window else { return }
        let begin = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: convert(point, to: nil), modifierFlags: [], timestamp: begin + time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown, start, 0), let up = event(.leftMouseUp, end, duration) else { return }
        drag(.began, event: down)
        let steps = 12
        for index in 1...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let moved = event(.leftMouseDragged, point, duration * Double(t)) { drag(.moved, event: moved) }
        }
        drag(.ended, event: up)
    }

    /// Test seam: one pointer event of a drag, at `point` in this view's
    /// coordinates and `time` seconds of system uptime.
    func qaPointer(_ phase: FloatingToolbarView.DragPhase, at point: NSPoint, time: TimeInterval) {
        guard let window,
              let event = NSEvent.mouseEvent(
                with: phase == .began ? .leftMouseDown : phase == .moved ? .leftMouseDragged : .leftMouseUp,
                location: convert(point, to: nil), modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        drag(phase, event: event)
    }

    /// Test seam: runs the motion to rest, `frames` steps of 1/120s at most.
    @discardableResult
    func qaRunMotion(frames: Int = 600) -> Int {
        var count = 0
        while link != nil, count < frames {
            step(by: 1.0 / 120)
            count += 1
        }
        return count
    }

    var qaAngle: CGFloat { angle }

    // MARK: Hover labels

    private func buttonHover(_ button: ToolbarIconButton, inside: Bool) {
        guard inside, !isMoving, choicesMenu == nil, zoneCapture == nil else { hideHoverPill(); return }
        hideHoverPill()
        let pill = ToolbarHoverPillView(title: button.item.title, shortcut: button.shortcut)
        let anchor = convert(button.bounds, from: button)
        pill.frame = FloatingToolbarGeometry.besideBar(
            size: pill.frame.size, anchor: anchor, bar: toolbar.frame, edge: edge, in: bounds)
        addSubview(pill)
        hoverPill = pill
    }

    private func hideHoverPill() {
        hoverPill?.removeFromSuperview()
        hoverPill = nil
    }

    // MARK: Actions and menus

    private func activate(_ button: ToolbarIconButton) {
        hideHoverPill()
        switch button.item.action {
        case .createZone:
            closeMenu()
            if zoneCapture == nil { armZoneTool(button) } else { disarmZoneTool() }
        case .palette(let action) where action == .newManagedAgent:
            disarmZoneTool()
            openMenu(for: button, title: Self.agentMenuTitle, choices: Self.agentChoices.map { title, selection in
                (title, { [weak self] in self?.onSelection(selection) })
            })
        case .terminalProfiles:
            disarmZoneTool()
            openMenu(for: button, title: "New terminal", choices: terminalProfiles().map { profile in
                (profile.title, { [weak self] in self?.onSelection(.terminalProfile(profile.id)) })
            })
        case .palette(let action):
            closeMenu()
            disarmZoneTool()
            onSelection(.palette(action))
        }
    }

    // Not "New agent": that literal is the AgentName sentinel and must exist once.
    static let agentMenuTitle = "Start an agent"

    static var agentChoices: [(String, Selection)] {
        var choices: [(String, Selection)] = [
            ("Claude Code", .agentHarness(.claudeCode)),
            ("Codex", .agentHarness(.codex)),
            ("Pi", .agentHarness(.pi)),
        ]
        if let fanOut = CommandRegistry.definitions().first(where: { $0.paletteAction == .fanOutQueueSelection }) {
            choices.append((fanOut.title, .fanOutQueueSelection))
        }
        return choices
    }

    private func openMenu(for button: ToolbarIconButton, title: String, choices: [(String, () -> Void)]) {
        let reopening = choicesMenu?.owner === button
        closeMenu()
        guard !reopening else { return }
        let menu = ToolbarChoicesMenuView(title: title, choices: choices.map { label, fire in
            (label, { [weak self] in
                self?.closeMenu()
                fire()
            })
        })
        menu.owner = button
        let anchor = convert(button.bounds, from: button)
        menu.frame = FloatingToolbarGeometry.besideBar(
            size: menu.frame.size, anchor: anchor, bar: toolbar.frame, edge: edge, in: bounds)
        addSubview(menu)
        choicesMenu = menu
        button.isActive = true
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let menu = self.choicesMenu else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }   // Escape
                self.closeMenu()
                return nil
            }
            guard event.window === self.window else { self.closeMenu(); return event }
            let point = menu.convert(event.locationInWindow, from: nil)
            let onOwner = menu.owner.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            if !menu.bounds.contains(point), !onOwner { self.closeMenu() }
            return event
        }
    }

    func closeMenu() {
        if let menuMonitor { NSEvent.removeMonitor(menuMonitor) }
        menuMonitor = nil
        choicesMenu?.owner?.isActive = false
        choicesMenu?.removeFromSuperview()
        choicesMenu = nil
    }

    // MARK: The Zone tool

    /// Arms a one-shot draw: a crosshair over the whole canvas until the user
    /// drags out a zone or presses Escape. A click without a drag draws nothing
    /// and keeps the tool armed.
    private func armZoneTool(_ button: ToolbarIconButton) {
        guard let target = zoneDrawing else { return }
        let capture = ZoneDrawCaptureView(frame: bounds, target: target) { [weak self] in self?.disarmZoneTool() }
        capture.autoresizingMask = [.width, .height]
        addSubview(capture, positioned: .below, relativeTo: toolbar)
        zoneCapture = capture
        button.isActive = true
        window?.invalidateCursorRects(for: capture)
        zoneMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.zoneCapture != nil else { return event }   // Escape
            self.disarmZoneTool()
            return nil
        }
    }

    func disarmZoneTool() {
        if let zoneMonitor { NSEvent.removeMonitor(zoneMonitor) }
        zoneMonitor = nil
        guard let capture = zoneCapture else { return }
        capture.removeFromSuperview()
        zoneCapture = nil
        toolbar.buttons.first { $0.item.action == .createZone }?.isActive = false
    }

    /// Test seam: presses the button titled `title` as a click would.
    @discardableResult
    func qaActivate(title: String) -> Bool {
        guard let button = toolbar.buttons.first(where: { $0.item.title == title }) else { return false }
        activate(button)
        return true
    }

    /// Test seam: the pointer entering or leaving the button titled `title`.
    @discardableResult
    func qaHover(title: String, inside: Bool) -> Bool {
        guard let button = toolbar.buttons.first(where: { $0.item.title == title }) else { return false }
        buttonHover(button, inside: inside)
        return true
    }
}

/// A damped spring, stepped explicitly. `response` is the period of the
/// undamped oscillation in seconds; `dampingRatio` below 1 leaves a little give.
struct FloatingToolbarSpring {
    let stiffness: CGFloat
    let damping: CGFloat

    init(response: CGFloat, dampingRatio: CGFloat) {
        let omega = 2 * .pi / response
        stiffness = omega * omega
        damping = 2 * dampingRatio * omega
    }

    func advance(_ value: inout CGFloat, velocity: inout CGFloat, toward target: CGFloat, dt: CGFloat) {
        let acceleration = -stiffness * (value - target) - damping * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }
}

/// While the Zone tool is armed: covers the canvas, shows a crosshair, and hands
/// the pointer to the canvas's marquee. Scrolls and pinches pass through so the
/// user can still frame the canvas before drawing.
@MainActor
final class ZoneDrawCaptureView: NSView {
    private weak var target: ZoneDrawingTarget?
    private let onDrawn: () -> Void

    init(frame: NSRect, target: ZoneDrawingTarget, onDrawn: @escaping () -> Void) {
        self.target = target
        self.onDrawn = onDrawn
        super.init(frame: frame)
        setAccessibilityIdentifier("ArrayZoneDrawCapture")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) { target?.beginZoneDrawing(with: event) }
    override func mouseDragged(with event: NSEvent) { target?.continueZoneDrawing(with: event) }
    override func mouseUp(with event: NSEvent) {
        if target?.finishZoneDrawing(with: event) == true { onDrawn() }
    }

    override func scrollWheel(with event: NSEvent) { target?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { target?.magnify(with: event) }
}

struct FloatingToolbarProfile: Equatable {
    let id: String
    let title: String
}

enum FloatingToolbarEdge: String, CaseIterable {
    case top, bottom, left, right

    static let fallback: Self = .bottom

    var orientation: NSUserInterfaceLayoutOrientation {
        self == .left || self == .right ? .vertical : .horizontal
    }

    /// The bar's angle on this edge: lying flat, or standing with its leading
    /// end at the top.
    var angle: CGFloat { orientation == .vertical ? -.pi / 2 : 0 }

    static func stored(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: FloatingToolbarConfig.positionEdgeKey).flatMap(Self.init(rawValue:)) ?? fallback
    }
}

enum FloatingToolbarGeometry {
    /// The gap between the bar and the canvas edge it rests on.
    static let margin: CGFloat = 12
    /// The gap between the bar and a label or menu beside it.
    static let besideGap: CGFloat = 8
    /// How close to an edge the hand must come before the bar turns to suit it.
    static let turnBand: CGFloat = 140

    /// The edge whose side of the canvas `point` is on, split along the canvas
    /// diagonals: drag toward a side and that side is where the bar goes, on a
    /// wide canvas as much as a square one.
    static func region(of point: NSPoint, in bounds: NSRect) -> FloatingToolbarEdge {
        guard bounds.width > 0, bounds.height > 0 else { return FloatingToolbarEdge.fallback }
        let x = min(max((point.x - bounds.minX) / bounds.width, 0), 1)
        let y = min(max((point.y - bounds.minY) / bounds.height, 0), 1)
        let distances: [(FloatingToolbarEdge, CGFloat)] = [(.bottom, y), (.top, 1 - y), (.left, x), (.right, 1 - x)]
        return distances.min { $0.1 < $1.1 }?.0 ?? FloatingToolbarEdge.fallback
    }

    static func isNear(_ point: NSPoint, edge: FloatingToolbarEdge, in bounds: NSRect) -> Bool {
        switch edge {
        case .bottom: return point.y - bounds.minY < turnBand
        case .top: return bounds.maxY - point.y < turnBand
        case .left: return point.x - bounds.minX < turnBand
        case .right: return bounds.maxX - point.x < turnBand
        }
    }

    /// Centred on `edge`; when that covers an obstacle, slid along the edge to
    /// clear it, and only lifted off the edge if sliding cannot.
    static func restingFrame(size: NSSize, edge: FloatingToolbarEdge, in bounds: NSRect, avoiding obstacles: [NSRect]) -> NSRect {
        var frame = restingFrame(size: size, edge: edge, in: bounds)
        let horizontal = edge.orientation == .horizontal
        for obstacle in obstacles where !obstacle.isEmpty {
            let padded = obstacle.insetBy(dx: -besideGap, dy: -besideGap)
            guard frame.intersects(padded) else { continue }
            var slid = frame
            if horizontal {
                slid.origin.x = padded.midX > frame.midX ? padded.minX - frame.width : padded.maxX
            } else {
                slid.origin.y = padded.midY > frame.midY ? padded.minY - frame.height : padded.maxY
            }
            let lane = bounds.insetBy(dx: margin, dy: margin)
            if lane.contains(slid), !obstacles.contains(where: { $0.insetBy(dx: -besideGap, dy: -besideGap).intersects(slid) }) {
                frame = slid
                continue
            }
            switch edge {
            case .bottom: frame.origin.y = padded.maxY
            case .top: frame.origin.y = padded.minY - frame.height
            case .left: frame.origin.x = padded.maxX
            case .right: frame.origin.x = padded.minX - frame.width
            }
        }
        return frame.integral
    }

    static func restingFrame(size: NSSize, edge: FloatingToolbarEdge, in bounds: NSRect) -> NSRect {
        let origin: NSPoint
        switch edge {
        case .top: origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - margin - size.height)
        case .bottom: origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + margin)
        case .left: origin = NSPoint(x: bounds.minX + margin, y: bounds.midY - size.height / 2)
        case .right: origin = NSPoint(x: bounds.maxX - margin - size.width, y: bounds.midY - size.height / 2)
        }
        return NSRect(origin: origin, size: size).integral
    }

    static func frame(centeredAt center: NSPoint, size: NSSize) -> NSRect {
        NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The axis-aligned box around a `length` × `thickness` capsule turned by `angle`.
    static func boundingSize(length: CGFloat, thickness: CGFloat, angle: CGFloat) -> NSSize {
        let c = abs(cos(angle)), s = abs(sin(angle))
        return NSSize(width: c * length + s * thickness, height: s * length + c * thickness)
    }

    /// A label or menu on the canvas side of the bar, centred on `anchor` along
    /// the bar and kept inside `bounds`.
    static func besideBar(size: NSSize, anchor: NSRect, bar: NSRect, edge: FloatingToolbarEdge, in bounds: NSRect) -> NSRect {
        var origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: bar.maxY + besideGap)
        case .top: origin = NSPoint(x: anchor.midX - size.width / 2, y: bar.minY - besideGap - size.height)
        case .left: origin = NSPoint(x: bar.maxX + besideGap, y: anchor.midY - size.height / 2)
        case .right: origin = NSPoint(x: bar.minX - besideGap - size.width, y: anchor.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, bounds.minX + besideGap), bounds.maxX - besideGap - size.width)
        origin.y = min(max(origin.y, bounds.minY + besideGap), bounds.maxY - besideGap - size.height)
        return NSRect(origin: origin, size: size).integral
    }
}

/// The bar itself: a borderless capsule of icon buttons, grouped by dividers,
/// drawn at any angle between lying flat and standing up. Icons stay upright.
@MainActor
final class FloatingToolbarView: NSView, TokenThemed {
    enum DragPhase { case began, moved, ended }

    /// The capsule's thickness across its axis.
    static let thickness: CGFloat = 44
    static let buttonSize: CGFloat = 36
    static let inset: CGFloat = 4
    static let spacing: CGFloat = 2
    static let dividerLength: CGFloat = 18
    static let dividerSpan: CGFloat = 13

    var defaults: UserDefaults = .standard
    /// The resting orientation, which the bar's shape and hover labels follow.
    var orientation: NSUserInterfaceLayoutOrientation = .horizontal
    /// The capsule's angle: 0 flat, -π/2 standing.
    var angle: CGFloat = 0
    var onButtonHover: ((ToolbarIconButton, Bool) -> Void)?
    var onButtonActivate: ((ToolbarIconButton) -> Void)?
    var onDrag: ((DragPhase, NSEvent) -> Void)?
    private(set) var buttons: [ToolbarIconButton] = []
    private var arranged: [NSView] = []
    private let capsule = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        capsule.shadowOpacity = 1
        capsule.shadowRadius = 10
        capsule.shadowOffset = NSSize(width: 0, height: -2)
        layer?.addSublayer(capsule)
        setAccessibilityIdentifier("ArrayFloatingToolbarRoot")
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Create")
        rebuildButtons()
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        capsule.fillColor = SurfaceToken.overlay.color.cgColor(in: self)
        capsule.shadowColor = NSColor.black.withAlphaComponent(effectiveTokenTheme == .dark ? 0.45 : 0.16).cgColor
    }

    /// Commands, in `CommandRegistry` order within three groups: zone, the two
    /// with a choice menu, then every other tile. A tile command registered
    /// tomorrow lands in the last group with no change here.
    static func visibleItems(defaults: UserDefaults) -> [(item: FloatingToolbarItem, shortcut: String?)] {
        let items: [(FloatingToolbarItem, String?)] = CommandRegistry.definitions().compactMap { definition in
            guard let item = definition.floatingToolbarItem else { return nil }
            let key = FloatingToolbarConfig.itemVisibleKey(commandID: definition.id.rawValue)
            let visible = defaults.object(forKey: key) == nil
                ? FloatingToolbarConfig.defaultItemVisible
                : defaults.bool(forKey: key)
            guard visible else { return nil }
            return (item, definition.shortcuts.first?.defaultGestures.first?.displayString)
        }
        return items.enumerated()
            .sorted { (group($0.element.0), $0.offset) < (group($1.element.0), $1.offset) }
            .map { (item: $0.element.0, shortcut: $0.element.1) }
    }

    static func group(_ item: FloatingToolbarItem) -> Int {
        switch item.action {
        case .createZone: return 0
        case .terminalProfiles, .palette(.newManagedAgent): return 1
        default: return 2
        }
    }

    static func hasChoices(_ item: FloatingToolbarItem) -> Bool { group(item) == 1 }

    func rebuildButtons() {
        arranged.forEach { $0.removeFromSuperview() }
        arranged = []
        buttons = []
        var lastGroup: Int?
        for entry in Self.visibleItems(defaults: defaults) {
            let group = Self.group(entry.item)
            if let lastGroup, lastGroup != group { arranged.append(ToolbarDividerView(frame: .zero)) }
            lastGroup = group
            let button = ToolbarIconButton(item: entry.item, shortcut: entry.shortcut, hasChoices: Self.hasChoices(entry.item))
            button.onHover = { [weak self] button, inside in self?.onButtonHover?(button, inside) }
            button.onActivate = { [weak self] button in self?.onButtonActivate?(button) }
            button.onDrag = { [weak self] phase, event in self?.onDrag?(phase, event) }
            buttons.append(button)
            arranged.append(button)
        }
        arranged.forEach(addSubview)
        render()
    }

    /// The bar's length along its axis: every button and divider, end to end.
    private var length: CGFloat {
        let spans = arranged.map { $0 is ToolbarDividerView ? Self.dividerSpan : Self.buttonSize }
        return Self.inset * 2 + spans.reduce(0, +) + Self.spacing * CGFloat(max(0, spans.count - 1))
    }

    func preferredSize(for orientation: NSUserInterfaceLayoutOrientation) -> NSSize {
        orientation == .horizontal
            ? NSSize(width: length, height: Self.thickness)
            : NSSize(width: Self.thickness, height: length)
    }

    /// Draws the capsule and places every item for the current `angle`, about
    /// the centre of `bounds`.
    func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let length = self.length
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
        let path = CGPath(
            roundedRect: CGRect(x: -length / 2, y: -Self.thickness / 2, width: length, height: Self.thickness),
            cornerWidth: Self.thickness / 2, cornerHeight: Self.thickness / 2, transform: &transform)
        capsule.frame = bounds
        capsule.path = path
        capsule.shadowPath = path
        let axis = CGVector(dx: cos(angle), dy: sin(angle))
        var cursor = Self.inset - length / 2
        for view in arranged {
            let span = view is ToolbarDividerView ? Self.dividerSpan : Self.buttonSize
            let along = cursor + span / 2
            let point = NSPoint(x: center.x + axis.dx * along, y: center.y + axis.dy * along)
            let side = view is ToolbarDividerView ? Self.dividerLength : Self.buttonSize
            view.frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            (view as? ToolbarDividerView)?.angle = angle
            cursor += span + Self.spacing
        }
    }

    override func layout() {
        super.layout()
        render()
    }

    /// Every item's centre on the capsule's axis and inside the capsule: the
    /// bar and its icons agree, whatever the angle.
    var qaItemsRideTheCapsule: Bool {
        guard let path = capsule.path else { return false }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        return arranged.allSatisfy { view in
            let point = NSPoint(x: view.frame.midX, y: view.frame.midY)
            let offAxis = abs(-(point.x - center.x) * sin(angle) + (point.y - center.y) * cos(angle))
            return offAxis < 0.5 && path.contains(point)
        }
    }

    /// Only the capsule is solid; its bounding box's corners belong to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let path = capsule.path, path.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // The capsule between buttons is a drag handle.
    override func mouseDown(with event: NSEvent) { onDrag?(.began, event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(.moved, event) }
    override func mouseUp(with event: NSEvent) { onDrag?(.ended, event) }
}

/// One command: an icon on nothing at rest, a filled circle under the pointer
/// or while its menu or tool is active.
@MainActor
final class ToolbarIconButton: NSView, TokenThemed {
    let item: FloatingToolbarItem
    let shortcut: String?
    var onHover: ((ToolbarIconButton, Bool) -> Void)?
    var onActivate: ((ToolbarIconButton) -> Void)?
    var onDrag: ((FloatingToolbarView.DragPhase, NSEvent) -> Void)?
    var isActive = false { didSet { applyTokens() } }
    private(set) var isHovered = false { didSet { applyTokens() } }

    private let icon = NSImageView()
    private let chevron: NSImageView?
    private var tracking: NSTrackingArea?
    private var pressEvent: NSEvent?
    private var dragging = false

    init(item: FloatingToolbarItem, shortcut: String?, hasChoices: Bool) {
        self.item = item
        self.shortcut = shortcut
        chevron = hasChoices ? NSImageView() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: FloatingToolbarView.buttonSize, height: FloatingToolbarView.buttonSize))
        wantsLayer = true
        icon.image = CanvasSymbolImage.image(named: item.symbolName, pointSize: 15, weight: .medium)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        if let chevron {
            chevron.image = CanvasSymbolImage.image(named: "chevron.down", pointSize: 7, weight: .bold)
            chevron.imageScaling = .scaleNone
            addSubview(chevron)
        }
        identifier = NSUserInterfaceItemIdentifier("ArrayFloatingToolbar.\(item.title.replacingOccurrences(of: " ", with: ""))")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("ArrayFloatingToolbarButton.\(item.title.replacingOccurrences(of: " ", with: ""))")
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        icon.frame = bounds
        chevron?.frame = NSRect(x: bounds.maxX - 11, y: bounds.minY + 3, width: 8, height: 8)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let role: AgentSurfaceRole? = isActive ? .rowSelected : isHovered ? .rowHover : nil
        layer?.backgroundColor = role?.color.cgColor(in: self)
        icon.contentTintColor = TextToken.textPrimary.color.nsColor(in: self)
        chevron?.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(self, false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // A press that travels becomes a drag of the whole bar; one that does not
    // is a click.
    override func mouseDown(with event: NSEvent) {
        pressEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent else { return }
        if !dragging {
            let dx = event.locationInWindow.x - press.locationInWindow.x
            let dy = event.locationInWindow.y - press.locationInWindow.y
            guard hypot(dx, dy) > FloatingToolbarHostView.dragThreshold else { return }
            dragging = true
            isHovered = false
            onDrag?(.began, press)
        }
        onDrag?(.moved, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressEvent = nil; dragging = false }
        if dragging {
            onDrag?(.ended, event)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onActivate?(self)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?(self)
        return true
    }
}

/// A hairline between groups, across the bar at whatever angle the bar is at,
/// painted with the separator line token.
@MainActor
final class ToolbarDividerView: NSView, TokenThemed {
    private let line = CALayer()
    var angle: CGFloat = 0 { didSet { if angle != oldValue { needsLayout = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(line)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.bounds = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        line.position = CGPoint(x: bounds.midX, y: bounds.midY)
        line.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        line.backgroundColor = LineToken.separator.color.cgColor(in: self)
    }
}

/// The label beside a hovered button: its title and, when it has one, its
/// shortcut, on a borderless capsule.
@MainActor
final class ToolbarHoverPillView: NSView, TokenThemed {
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField?
    private static let height: CGFloat = 26
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 4

    init(title: String, shortcut: String?) {
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        shortcutLabel = shortcut.map {
            let label = NSTextField(labelWithString: $0)
            label.font = .systemFont(ofSize: 11, weight: .regular)
            return label
        }
        // Sized by what the cell needs to draw, not `intrinsicContentSize`, which
        // is narrower and clipped "Terminal" to "Termina".
        let labels = [titleLabel] + (shortcutLabel.map { [$0] } ?? [])
        let widths = labels.map { ceil($0.cell?.cellSize.width ?? $0.intrinsicContentSize.width) }
        let width = widths.reduce(0, +) + Self.gap * CGFloat(widths.count - 1) + Self.padding * 2
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        labels.forEach(addSubview)
        setAccessibilityIdentifier("ArrayFloatingToolbarHoverPill")
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var x = Self.padding
        for label in [titleLabel] + (shortcutLabel.map { [$0] } ?? []) {
            let size = label.cell?.cellSize ?? label.intrinsicContentSize
            label.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: ceil(size.width), height: ceil(size.height))
            x = label.frame.maxX + Self.gap
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Every label is laid out at least as wide as AppKit needs to draw it whole.
    var qaLabelsFit: Bool {
        layoutSubtreeIfNeeded()
        return ([titleLabel] + (shortcutLabel.map { [$0] } ?? [])).allSatisfy {
            $0.frame.width >= ($0.cell?.cellSize.width ?? .greatestFiniteMagnitude) && bounds.contains($0.frame)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 0
        layer?.shadowColor = NSColor.black.withAlphaComponent(effectiveTokenTheme == .dark ? 0.4 : 0.14).cgColor
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        shortcutLabel?.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
}

/// The small menu a chevron button opens, beside the bar on the canvas.
@MainActor
final class ToolbarChoicesMenuView: NSView, TokenThemed {
    weak var owner: ToolbarIconButton?
    let rows: [ToolbarChoiceRowView]
    private let heading: NSTextField
    private static let padding: CGFloat = 6
    private static let headingHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 28

    init(title: String, choices: [(String, () -> Void)]) {
        heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        rows = choices.map { ToolbarChoiceRowView(title: $0.0, fire: $0.1) }
        let widest = rows.map(\.idealWidth).max() ?? 0
        let width = max(168, widest + Self.padding * 2)
        let height = Self.padding * 2 + Self.headingHeight + Self.rowHeight * CGFloat(rows.count)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: height))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        addSubview(heading)
        rows.forEach(addSubview)
        setAccessibilityRole(.menu)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("ArrayFloatingToolbarMenu")
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var title: String { heading.stringValue }

    override func layout() {
        super.layout()
        let top = bounds.height - Self.padding
        heading.frame = NSRect(x: Self.padding + 8, y: top - Self.headingHeight + 5,
                               width: bounds.width - Self.padding * 2 - 16, height: 15)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Self.padding, y: top - Self.headingHeight - Self.rowHeight * CGFloat(index + 1),
                               width: bounds.width - Self.padding * 2, height: Self.rowHeight)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        layer?.cornerRadius = 12
        layer?.borderWidth = 0
        layer?.shadowColor = NSColor.black.withAlphaComponent(effectiveTokenTheme == .dark ? 0.45 : 0.16).cgColor
        heading.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
}

@MainActor
final class ToolbarChoiceRowView: NSView, TokenThemed {
    private let label: NSTextField
    private let fire: () -> Void
    private var tracking: NSTrackingArea?
    var isHovered = false { didSet { applyTokens() } }

    init(title: String, fire: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        self.fire = fire
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var title: String { label.stringValue }
    var idealWidth: CGFloat { ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width) + 32 }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 7
        let size = label.cell?.cellSize ?? label.intrinsicContentSize
        label.frame = NSRect(x: 8, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width - 16, height: ceil(size.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = isHovered ? AgentSurfaceRole.rowHover.color.cgColor(in: self) : nil
        label.textColor = TextToken.textPrimary.color.nsColor(in: self)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { fire() }
    }

    override func accessibilityPerformPress() -> Bool {
        fire()
        return true
    }

    func qaPress() { fire() }
}

@MainActor
final class FloatingToolbarSettingsView: NSView {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let itemCount = CommandRegistry.definitions().filter { $0.floatingToolbarItem != nil }.count
        super.init(frame: NSRect(x: 0, y: 0, width: 510, height: CGFloat(110 + itemCount * 28)))
        heightAnchor.constraint(equalToConstant: CGFloat(110 + itemCount * 28)).isActive = true
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func qaActivateControl(_ identifier: String) throws {
        guard let button = descendants(of: self).compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw FloatingToolbarChecks.Failure(description: "missing settings control \(identifier)")
        }
        button.performClick(nil)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        stack.addArrangedSubview(toggle("Show Toolbar", key: FloatingToolbarConfig.visibleKey, fallback: true))
        for definition in CommandRegistry.definitions() {
            guard let item = definition.floatingToolbarItem else { continue }
            let key = FloatingToolbarConfig.itemVisibleKey(commandID: definition.id.rawValue)
            stack.addArrangedSubview(toggle("Show \(item.title) Button", key: key, fallback: FloatingToolbarConfig.defaultItemVisible))
        }
        let reset = NSButton(title: "Reset Position", target: self, action: #selector(resetPosition(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setAccessibilityIdentifier("ArrayFloatingToolbarResetPosition")
        stack.addArrangedSubview(reset)
    }

    private func toggle(_ title: String, key: String, fallback: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingChanged(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.state = (defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)) ? .on : .off
        button.setAccessibilityIdentifier("ArrayFloatingToolbarSetting.\(key)")
        return button
    }

    @objc private func settingChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        defaults.set(sender.state == .on, forKey: key)
        NotificationCenter.default.post(name: FloatingToolbarHostView.didChangeSettings, object: nil)
        SettingChangeEvent.post(SettingID(rawValue: key))
    }

    @objc private func resetPosition(_ sender: Any?) {
        defaults.removeObject(forKey: FloatingToolbarConfig.positionEdgeKey)
        NotificationCenter.default.post(name: FloatingToolbarHostView.didChangeSettings, object: nil)
    }
}
