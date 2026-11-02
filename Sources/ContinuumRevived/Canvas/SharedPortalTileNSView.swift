import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Part of someone else's canvas on this one (`.plans/105-collaboration/SHARE-REDESIGN.md`,
/// mode B). An ordinary tile in this person's own zone: they move, resize and
/// close it, and none of that reaches the owner. Inside, the owner's chosen
/// tiles sit where they sit on the owner's canvas; this person can pan and
/// zoom around them but never move them. Every tile in it runs on the
/// owner's Mac. It is never a zone, and holds only a reference.
@MainActor
final class SharedPortalTileNSView: TileNSView {
    typealias State = SharedAgentTileNSView.State

    let reference: SharedPortalTileReference?
    private(set) var state: State = .connecting
    private let container = SharedPortalTileBody()
    /// The session that feeds this tile; set by `AppDelegate.attachSharedPortalTile`.
    var session: SharedPortalTileSession?
    var attaching = false
    var onWindowChange: ((SharedPortalTileNSView, Bool) -> Void)?

    override init(tile: Tile) {
        reference = tile.metadata.sharedPortal
        super.init(tile: tile)
        setContentView(container)
        let host = reference?.hostName ?? "Someone"
        apply(.placeholder("Shared by \(host) · sign in to see it"), hostName: host, colour: .systemOrange)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hostName: String { reference?.hostName ?? "Someone" }
    var portalName: String { reference?.name ?? "Shared canvas" }
    var body: SharedPortalBodyView? { container.body }
    var qaFooterText: String { container.footerText }
    var qaPlaceholderText: String? { container.placeholderText }

    func install(body: SharedPortalBodyView) { container.install(body: body) }

    func apply(_ next: State, hostName: String, colour: NSColor) {
        state = next
        let mark: OwnershipMark
        switch next {
        case .placeholder:
            mark = .init(text: "\(hostName)'s canvas · runs on \(hostName)'s Mac", colour: colour, outlined: true, dashed: true)
        case .connecting:
            mark = .init(text: "\(hostName)'s canvas · \(portalName) · connecting", colour: colour, outlined: true)
        case .live:
            mark = .init(text: "\(hostName)'s canvas · \(portalName) · Live · runs on \(hostName)'s Mac", colour: colour, outlined: true)
        case .offline(let lastSeen):
            let ago = lastSeen.map { SharedAreaPersonColour.ago($0) } ?? "earlier"
            mark = .init(text: "\(hostName)'s Mac is offline · last update \(ago)", colour: colour, outlined: true, dashed: true)
        case .stopped:
            mark = .init(text: "\(hostName)'s canvas · no longer shared", colour: colour, outlined: true, dashed: true)
        }
        if ownershipMark != mark { setOwnershipMark(mark) }
        container.apply(next, hostName: hostName)
    }

    /// The person's own camera inside the portal changed: persist it on the
    /// tile, never on the owner's side.
    func persistCamera(_ camera: SharedPortal.Camera?) {
        guard var reference = tile.metadata.sharedPortal, reference.camera != camera else { return }
        reference.camera = camera
        var updated = tile
        updated.metadata.sharedPortal = reference
        canvas?.updateTile(updated, recalculateZoneBounds: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self, window != nil)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(body ?? self)
        return true
    }
}

/// The portal tile's content: the body once a session attaches, a footer
/// while the owner is offline or sharing stopped, and a placeholder when this
/// install cannot open the portal.
@MainActor
final class SharedPortalTileBody: NSView {
    private(set) var body: SharedPortalBodyView?
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let footerLine = NSTextField(labelWithString: "")
    private let footerDetail = NSTextField(wrappingLabelWithString: "")
    private var showsFooter = false
    override var isFlipped: Bool { true }
    static let footerHeight: CGFloat = 46

    var footerText: String { showsFooter ? footerLine.stringValue + " · " + footerDetail.stringValue : "" }
    var placeholderText: String? { placeholder.isHidden ? nil : placeholder.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholder.font = .token(.body); placeholder.alignment = .center
        footerLine.font = .token(.label); footerLine.lineBreakMode = .byTruncatingTail
        footerDetail.font = .token(.caption); footerDetail.maximumNumberOfLines = 1
        footerDetail.lineBreakMode = .byTruncatingTail
        for view in [placeholder, footerLine, footerDetail] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(body: SharedPortalBodyView) {
        guard self.body !== body else { return }
        self.body?.removeFromSuperview()
        self.body = body
        addSubview(body, positioned: .below, relativeTo: placeholder)
        body.isHidden = !placeholder.isHidden
        needsLayout = true
    }

    func apply(_ state: SharedPortalTileNSView.State, hostName: String) {
        var line = "", detail = ""
        var placeholderValue: String?
        switch state {
        case .placeholder(let text): placeholderValue = text
        case .connecting, .live: break
        case .offline(let lastSeen):
            line = "\(hostName)'s Mac is offline"
            detail = "Showing the last update, \(lastSeen.map { SharedAreaPersonColour.ago($0) } ?? "earlier"). It comes back live when \(hostName)'s Mac does."
        case .stopped(let text):
            line = text
            detail = "Nothing new arrives. What you already saw stays until you close this tile."
        }
        if placeholder.stringValue != (placeholderValue ?? "") { placeholder.stringValue = placeholderValue ?? "" }
        placeholder.isHidden = placeholderValue == nil
        body?.isHidden = placeholderValue != nil
        showsFooter = !line.isEmpty
        if footerLine.stringValue != line { footerLine.stringValue = line }
        if footerDetail.stringValue != detail { footerDetail.stringValue = detail }
        footerLine.isHidden = !showsFooter; footerDetail.isHidden = !showsFooter
        setAccessibilityLabel(placeholderValue ?? (showsFooter ? "\(line). \(detail)" : "Part of \(hostName)'s canvas"))
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        placeholder.frame = NSRect(x: 12, y: bounds.height / 2 - 24, width: max(0, bounds.width - 24), height: 48)
        let footer = showsFooter ? Self.footerHeight : 0
        let bodyFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footer))
        if let body, body.frame != bodyFrame { body.frame = bodyFrame }
        let top = bounds.height - footer
        footerLine.frame = NSRect(x: 26, y: top + 6, width: max(0, bounds.width - 38), height: 18)
        footerDetail.frame = NSRect(x: 12, y: top + 24, width: max(0, bounds.width - 24), height: 18)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        placeholder.textColor = TextToken.textSecondary.color.nsColor(in: self)
        footerLine.textColor = TextToken.textPrimary.color.nsColor(in: self)
        footerDetail.textColor = TextToken.textSecondary.color.nsColor(in: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        bounds.fill()
        guard showsFooter else { return }
        let top = bounds.height - Self.footerHeight
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
        TextToken.textSecondary.color.nsColor(in: self).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: top + 11, width: 7, height: 7)).fill()
    }
}

/// Inside the portal: the owner's tiles at their area positions under this
/// person's own camera. Scroll pans, pinch or Command-scroll zooms, and a
/// double click on empty space fits everything again. Cursors and Follow ride
/// the shared presence publisher through `SharedAreaPresenceSurface`.
@MainActor
final class SharedPortalBodyView: NSView, SharedAreaPresenceSurface {
    let controller: SharedAreaController
    private let itemLayer = FlippedView()
    private(set) var items: [SharedArea.ID<SharedArea.Object>: SharedPortalItemView] = [:]
    private(set) var rects: [SharedArea.ID<SharedArea.Object>: SharedArea.Rect] = [:]
    private var order: [SharedArea.ID<SharedArea.Object>] = []
    /// Nil fits the content: the portal re-fits as the owner's tiles move,
    /// until this person pans or zooms.
    private(set) var userCamera: SharedPortal.Camera?
    private var followCamera: SharedPortal.Camera?
    private let hoverButton = ComposerActionButton(presentation: CollaborationHubView.action("Open beside", symbol: "rectangle.portrait.and.arrow.right"))
    private let followButton = ComposerActionButton(presentation: CollaborationHubView.action("Follow", symbol: "eye"))
    private var hovered: SharedArea.ID<SharedArea.Object>?
    private var tracking: NSTrackingArea?
    private var followTargets: [SharedAreaSceneView.FollowTarget] = []
    private var followed: UUID?
    private(set) var cameraChanges = 0

    var onCameraChange: ((SharedPortal.Camera?) -> Void)?
    var onCanvasTransformChange: (() -> Void)?
    var onLocalCameraNavigation: (() -> Void)?
    var onFollowTeammate: ((UUID?) -> Void)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(controller: SharedAreaController, camera: SharedPortal.Camera?) {
        self.controller = controller
        userCamera = camera
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        itemLayer.autoresizingMask = [.width, .height]
        addSubview(itemLayer)
        hoverButton.target = self; hoverButton.action = #selector(hoverPressed)
        hoverButton.isHidden = true
        followButton.target = self; followButton.action = #selector(followPressed)
        followButton.isHidden = true
        addSubview(hoverButton); addSubview(followButton)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Shared canvas")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Items

    /// Sets the items and their area rects. Views are reused by object.
    func setItems(_ next: [(SharedArea.ID<SharedArea.Object>, SharedArea.Rect)], make: (SharedArea.ID<SharedArea.Object>) -> SharedPortalItemView?) {
        let wanted = Set(next.map(\.0))
        for (object, view) in items where !wanted.contains(object) {
            (view as? SharedPortalAgentItemView)?.stop()
            view.removeFromSuperview(); items.removeValue(forKey: object)
        }
        var changed = false
        for (object, rect) in next {
            if items[object] == nil, let view = make(object) {
                items[object] = view; itemLayer.addSubview(view); changed = true
            }
            if rects[object] != rect { rects[object] = rect; changed = true }
        }
        rects = rects.filter { wanted.contains($0.key) }
        order = next.map(\.0)
        if changed || order.count != itemLayer.subviews.count { layoutItems() }
    }
    func item(_ object: SharedArea.ID<SharedArea.Object>) -> SharedPortalItemView? { items[object] }

    var contentRect: SharedArea.Rect? {
        let all = order.compactMap { rects[$0] }
        guard let first = all.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for r in all.dropFirst() { minX = min(minX, r.x); minY = min(minY, r.y); maxX = max(maxX, r.x + r.width); maxY = max(maxY, r.y + r.height) }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// What is on screen: the follow camera, else this person's, else a fit.
    var camera: SharedPortal.Camera {
        if let followCamera { return followCamera }
        if let userCamera { return userCamera }
        guard let content = contentRect else { return .init(x: 0, y: 0, zoom: 1) }
        return SharedPortal.Camera.fitting(content, in: bounds.size)
    }

    /// The item's frame in this view: its area rect under the camera.
    func displayedFrame(for object: SharedArea.ID<SharedArea.Object>) -> NSRect? {
        rects[object].map { camera.screen($0) }
    }

    func layoutItems() {
        let camera = self.camera
        for object in order {
            guard let view = items[object], let rect = rects[object] else { continue }
            let frame = camera.screen(rect)
            if view.frame != frame { view.frame = frame }
            let hostSize = NSSize(width: rect.width, height: rect.height)
            if view.bounds.size != hostSize { view.setBoundsSize(hostSize) }
        }
        // Later items draw above earlier ones, as on the owner's canvas.
        let sorted = order.compactMap { items[$0] }
        if itemLayer.subviews != sorted { itemLayer.subviews = sorted }
        positionHoverButton()
        positionFollowButton()
        onCanvasTransformChange?()
    }

    override func layout() {
        super.layout()
        itemLayer.frame = bounds
        layoutItems()
    }

    // MARK: Camera

    private func setUserCamera(_ next: SharedPortal.Camera?) {
        userCamera = next
        cameraChanges += 1
        onLocalCameraNavigation?()
        layoutItems()
        onCameraChange?(next)
    }

    override func scrollWheel(with event: NSEvent) {
        var current = camera
        if event.modifierFlags.contains(.command) {
            let factor = exp(-Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
            zoom(by: factor, around: convert(event.locationInWindow, from: nil))
            return
        }
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        current.x -= Double(event.scrollingDeltaX) * scale / current.zoom
        current.y -= Double(event.scrollingDeltaY) * scale / current.zoom
        followCamera = nil
        setUserCamera(current)
    }
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Double(event.magnification), around: convert(event.locationInWindow, from: nil))
    }
    /// Zooms about a point in this view, keeping that point under the pointer.
    func zoom(by factor: Double, around point: CGPoint) {
        var current = camera
        let anchor = current.area(point)
        current.zoom = min(SharedPortal.Camera.zoomRange.upperBound, max(SharedPortal.Camera.zoomRange.lowerBound, current.zoom * factor))
        current.x = Double(anchor.x) - Double(point.x) / current.zoom
        current.y = Double(anchor.y) - Double(point.y) / current.zoom
        followCamera = nil
        setUserCamera(current)
    }
    /// Pans by a distance in this view's points.
    func pan(dx: Double, dy: Double) {
        var current = camera
        current.x -= dx / current.zoom; current.y -= dy / current.zoom
        followCamera = nil
        setUserCamera(current)
    }
    func fit() {
        followCamera = nil
        setUserCamera(nil)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { fit() }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    /// The item under a point in this view, topmost first.
    func object(at point: CGPoint) -> SharedArea.ID<SharedArea.Object>? {
        let camera = self.camera
        return order.reversed().first { object in rects[object].map { camera.screen($0).contains(point) } ?? false }
    }
    func hover(at point: CGPoint?) {
        // The button itself keeps the item it belongs to.
        if let point, !hoverButton.isHidden, hoverButton.frame.contains(point) { return }
        let next = point.flatMap { object(at: $0) }
        guard next != hovered else { return }
        hovered = next
        positionHoverButton()
    }
    var qaHoverActionTitles: [String] { hovered.flatMap { items[$0]?.hoverActions.map(\.title) } ?? [] }
    var qaHovered: SharedArea.ID<SharedArea.Object>? { hovered }

    private func positionHoverButton() {
        guard let hovered, let view = items[hovered], let action = view.hoverActions.first else {
            hoverButton.isHidden = true; return
        }
        hoverButton.presentation = CollaborationHubView.action(action.title, symbol: action.symbolName)
        let size = hoverButton.intrinsicContentSize
        let frame = view.frame
        hoverButton.frame = NSRect(x: max(8, frame.maxX - size.width - 10), y: max(8, frame.minY + 8), width: size.width, height: size.height)
        hoverButton.isHidden = false
    }
    @objc private func hoverPressed() {
        guard let hovered, let action = items[hovered]?.hoverActions.first else { return }
        action.perform()
    }
    /// Runs the hovered item's first action, as a click on its button does.
    @discardableResult
    func performHoverAction(on object: SharedArea.ID<SharedArea.Object>) -> Bool {
        guard let action = items[object]?.hoverActions.first else { return false }
        action.perform(); return true
    }

    // MARK: Follow

    private func positionFollowButton() {
        let target = followTargets.first
        guard target != nil || followed != nil else { followButton.isHidden = true; return }
        let title = followed != nil ? "Stop following" : "Follow \(target?.label ?? "")"
        followButton.presentation = CollaborationHubView.action(title, symbol: followed != nil ? "eye.slash" : "eye")
        let size = followButton.intrinsicContentSize
        followButton.frame = NSRect(x: 10, y: max(8, bounds.height - size.height - 10), width: size.width, height: size.height)
        followButton.isHidden = false
    }
    @objc private func followPressed() {
        onFollowTeammate?(followed != nil ? nil : followTargets.first?.device)
    }
    var isFollowing: Bool { followed != nil }
    var qaFollowTitle: String? { followButton.isHidden ? nil : followButton.presentation.title }

    // MARK: SharedAreaPresenceSurface

    var areaCanvasView: NSView { self }
    var isZone: Bool { false }
    var localViewCamera: SharedAreaLocalView { let c = camera; return .init(x: c.x, y: c.y, zoom: c.zoom) }
    var cameraViewportSize: CGSize { bounds.size }
    func areaPoint(forScreenPoint point: CGPoint) -> CGPoint { camera.area(point) }
    func screenPoint(forAreaPoint point: CGPoint) -> CGPoint { camera.screen(point) }
    func setFollowTargets(_ targets: [SharedAreaSceneView.FollowTarget], followed: UUID?) {
        guard targets != followTargets || followed != self.followed else { return }
        followTargets = targets; self.followed = followed
        if followed == nil, followCamera != nil { followCamera = nil; layoutItems() }
        positionFollowButton()
    }
    func applyFollowedCamera(_ value: SharedAreaLocalView) -> Bool {
        let next = SharedPortal.Camera(x: value.x, y: value.y, zoom: value.zoom)
        guard next != followCamera else { return false }
        followCamera = next
        layoutItems()
        return true
    }
    func persistFollowedCamera() throws {
        guard let followCamera else { return }
        self.followCamera = nil
        userCamera = followCamera
        onCameraChange?(followCamera)
    }
    /// Cursors travel only over a shared tile.
    func publishesCursor(at area: CGPoint) -> Bool {
        order.contains { rects[$0].map { area.x >= $0.x && area.x <= $0.x + $0.width && area.y >= $0.y && area.y <= $0.y + $0.height } ?? false }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.canvas.color.nsColor(in: self).setFill()
        bounds.fill()
    }
}
