import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// One human view owns one ephemeral cursor session. Closing it stops presence,
/// never source execution or the separately owned durable usage/host session.
@MainActor
final class SharedAreaPresencePublisher {
    let overlay: SharedAreaPresenceOverlay
    private let scene: SharedAreaSceneView
    private let controller: SharedAreaController
    private var observer: UUID?
    private var cursorObserver: UUID?
    private var monitor: Any?
    private var timer: Timer?
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var cursor: Collaboration.Point?
    private var screenCursor: NSPoint?
    /// When `cursor` was sampled, on this Mac's monotonic clock. Receivers play
    /// positions back at the spacing they were sampled.
    private var cursorSampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastSent = Date.distantPast
    /// A position changed while a send was out or inside the 50 ms window. It is
    /// sent as soon as either clears, so the last position is never dropped.
    private var trailing = false
    private var trailingTimer: Timer?
    private var stopped = true
    private var lastStatus: SharedAreaController.Status?
    /// Follow is a private camera concern: it reads a teammate's published
    /// area-local viewport and never writes the shared document or a source.
    private(set) var followedDevice: UUID?
    private var followedLabel = ""
    /// Camera frames actually applied from a followed viewport.
    private(set) var followCameraApplies = 0
    /// Follow started (device, name) or ended (nil). A zone shows it over the canvas.
    var onFollowChange: ((UUID?, String) -> Void)?
    var followedLabelText: String { followedLabel }

    init(scene: SharedAreaSceneView) {
        self.scene = scene; controller = scene.controller
        overlay = SharedAreaPresenceOverlay(scene: scene)
    }
    func start() {
        guard stopped else { return }; stopped = false
        overlay.frame = scene.areaCanvasView.bounds
        overlay.showsBanner = !scene.isZone
        scene.areaCanvasView.addSubview(overlay)
        scene.onCanvasTransformChange = { [weak self] in self?.refreshPointerGeometry() }
        overlay.onPointerExit = { [weak self] in
            guard let self else { return }
            cursor = nil; screenCursor = nil; send(force: false)
        }
        overlay.onFollow = { [weak self] device in _ = self?.follow(device: device) }
        overlay.onStopFollowing = { [weak self] in self?.stopFollowing(notice: nil) }
        scene.onLocalCameraNavigation = { [weak self] in self?.localNavigation() }
        scene.onFollowTeammate = { [weak self] device in
            guard let self else { return }
            if let device { _ = follow(device: device) } else { stopFollowing(notice: nil) }
        }
        scene.window?.acceptsMouseMovedEvents = true
        observer = controller.addChangeObserver { [weak self] in self?.refresh() }
        cursorObserver = controller.addCursorObserver { [weak self] update in self?.cursorArrived(update) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] event in
            guard let self, event.window === self.scene.window else { return event }
            let local = self.overlay.convert(event.locationInWindow, from: nil)
            let inside = self.overlay.bounds.contains(local) && event.type != .mouseExited
            self.overlay.pointerMoved(to: inside ? local : nil)
            self.screenCursor = inside ? local : nil
            if inside {
                let area = self.scene.areaPoint(forScreenPoint: self.scene.convert(event.locationInWindow, from: nil))
                self.cursor = .init(x: area.x, y: area.y)
            } else { self.cursor = nil }
            self.cursorSampledAt = ProcessInfo.processInfo.systemUptime
            self.send(force: false)
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.send(force: true) }
        }
        refresh()
    }
    func stop() {
        guard !stopped else { return }; stopped = true; generation = UUID()
        if let observer { controller.removeChangeObserver(observer) }; observer = nil
        if let cursorObserver { controller.removeCursorObserver(cursorObserver) }; cursorObserver = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        timer?.invalidate(); timer = nil; task?.cancel(); task = nil
        trailingTimer?.invalidate(); trailingTimer = nil; trailing = false
        scene.onCanvasTransformChange = nil; overlay.onPointerExit = nil
        scene.onLocalCameraNavigation = nil; overlay.onFollow = nil; overlay.onStopFollowing = nil
        scene.onFollowTeammate = nil; scene.setFollowTargets([], followed: nil)
        if followedDevice != nil { onFollowChange?(nil, "") }
        followedDevice = nil; overlay.followedDevice = nil; overlay.followBanner = nil
        cursor = nil; screenCursor = nil; lastStatus = nil
        overlay.peers = []; overlay.inspect(device: nil); overlay.removeFromSuperview()
        if let session { Task { [controller] in try? await controller.endPresence(session) } }
        session = nil
    }
    func refresh() {
        guard !stopped else { return }
        overlay.peers = controller.status == .connected
            ? controller.presence.filter { $0.identity.device != controller.identity.device } : []
        let changed = lastStatus != controller.status
        lastStatus = controller.status
        if changed {
            task?.cancel(); task = nil; session = nil; generation = UUID()
        }
        updateFollow()
        publishFollowTargets()
        guard controller.status == .connected else { return }
        if changed { send(force: true) }
    }
    /// Starts following a teammate's published view. Refused, with a visible
    /// reason, when that teammate is not currently sharing one.
    @discardableResult
    func follow(device: UUID) -> Bool {
        guard !stopped, controller.status == .connected, device != controller.identity.device,
              let peer = controller.presence.first(where: { $0.identity.device == device }) else { return false }
        let name = overlay.label(peer)
        guard peer.expiresAt > Date(), let viewport = peer.viewport, viewport.valid else {
            overlay.followBanner = "\(name) is not sharing a view"
            return false
        }
        followedDevice = device; followedLabel = name
        overlay.followedDevice = device
        overlay.followBanner = "Following \(name) · pan, scroll or zoom to stop"
        applyFollow(viewport)
        publishFollowTargets()
        onFollowChange?(device, name)
        // Publish at once that this view is now borrowed, so nobody follows it back.
        send(force: true)
        return true
    }
    func stopFollowing(notice: String?) {
        guard followedDevice != nil else { return }
        followedDevice = nil
        overlay.followedDevice = nil; overlay.followBanner = notice
        // One private camera write when following ends, never one per frame.
        try? scene.persistFollowedCamera()
        publishFollowTargets()
        onFollowChange?(nil, "")
        send(force: true)
    }
    /// Teammates currently sharing a view, for the keyboard path in the
    /// Workspace menu. The scene ignores an unchanged list.
    private func publishFollowTargets() {
        guard !stopped else { return }
        let now = Date(), own = controller.identity.device
        var targets: [SharedAreaSceneView.FollowTarget] = []
        if controller.status == .connected {
            for peer in controller.presence where peer.identity.device != own && peer.expiresAt > now && peer.viewport?.valid == true {
                targets.append(.init(device: peer.identity.device, label: overlay.label(peer)))
            }
        }
        targets.sort { $0.label == $1.label ? $0.device.uuidString < $1.device.uuidString : $0.label < $1.label }
        scene.setFollowTargets(Array(targets.prefix(16)), followed: followedDevice)
    }
    /// A teammate's position from the cursor lane: straight to the overlay's
    /// playback, and to the camera when following them. No scene refresh.
    private func cursorArrived(_ update: SharedAreaController.CursorUpdate) {
        guard !stopped else { return }
        overlay.receive(update)
        if update.device == followedDevice, let viewport = update.viewport, viewport.valid { applyFollow(viewport) }
    }
    private func localNavigation() {
        if followedDevice != nil { stopFollowing(notice: nil) } else { overlay.followBanner = nil }
    }
    private func updateFollow() {
        guard let device = followedDevice else { return }
        guard controller.status == .connected else { stopFollowing(notice: "Connection lost · stopped following"); return }
        guard let peer = controller.presence.first(where: { $0.identity.device == device }) else {
            stopFollowing(notice: "\(followedLabel) left · stopped following"); return
        }
        guard peer.expiresAt > Date() else { stopFollowing(notice: "\(followedLabel) is away · stopped following"); return }
        guard let viewport = peer.viewport, viewport.valid else {
            stopFollowing(notice: "\(followedLabel)'s view is off screen · stopped following"); return
        }
        applyFollow(viewport)
    }
    /// Fits the teammate's whole area-local viewport, centred, into this
    /// person's canvas. Different window sizes and zooms see the same content.
    private func applyFollow(_ viewport: SharedArea.Rect) {
        let bounds = scene.cameraViewportSize
        guard bounds.width > 0, bounds.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let zoom = min(8, max(0.1, min(Double(bounds.width) / viewport.width, Double(bounds.height) / viewport.height)))
        let camera = SharedAreaLocalView(x: viewport.x + viewport.width / 2 - Double(bounds.width) / zoom / 2,
                                         y: viewport.y + viewport.height / 2 - Double(bounds.height) / zoom / 2, zoom: zoom)
        if scene.applyFollowedCamera(camera) { followCameraApplies += 1 }
    }
    func publishPointer(_ point: Collaboration.Point?) async {
        cursor = point; cursorSampledAt = ProcessInfo.processInfo.systemUptime
        screenCursor = point.map { overlay.convert(scene.screenPoint(forAreaPoint: .init(x: $0.x, y: $0.y)), from: scene) }
        send(force: true); await task?.value
    }
    private func refreshPointerGeometry() {
        guard !stopped else { return }
        overlay.refreshGeometry()
        if let screenCursor {
            if overlay.bounds.contains(screenCursor) {
                let area = scene.areaPoint(forScreenPoint: overlay.convert(screenCursor, to: scene))
                cursor = .init(x: area.x, y: area.y)
            } else { cursor = nil; self.screenCursor = nil; overlay.pointerMoved(to: nil) }
            cursorSampledAt = ProcessInfo.processInfo.systemUptime
        }
        send(force: false)
    }
    /// One send in flight, at most one every 50 ms over update pages (the
    /// service wakes readers at 20 Hz), or one a display frame at 60 Hz over the
    /// cursor lane, where a send is a WebSocket write rather than a round trip.
    /// A move that cannot go now is not dropped: the newest position leaves the
    /// moment the flight lands or the window opens. Before this, a stopped
    /// mouse waited for the one-second timer, up to a second behind.
    static let laneInterval: TimeInterval = 1.0 / 60
    static let pageInterval: TimeInterval = 0.05
    private func send(force: Bool) {
        guard !stopped, controller.status == .connected else { return }
        guard task == nil else { trailing = true; return }
        let window = controller.cursorLaneState == .live ? Self.laneInterval : Self.pageInterval
        let wait = window - Date().timeIntervalSince(lastSent)
        if !force, wait > 0 {
            trailing = true
            if trailingTimer == nil {
                trailingTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.sendTrailing() }
                }
            }
            return
        }
        trailing = false
        trailingTimer?.invalidate(); trailingTimer = nil
        let ticket = generation
        // The window counts from when a send leaves, so a round trip longer than
        // the window is the only limit on the rate.
        lastSent = Date()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if ticket == generation {
                    task = nil
                    if trailing { sendTrailing() }
                }
            }
            do {
                if session == nil {
                    let next = try await controller.beginPresence()
                    guard ticket == generation, !stopped else { try? await controller.endPresence(next.id); return }
                    session = next.id; sequence = 0
                }
                guard let session, sequence < UInt64.max else { return }
                sequence += 1
                let camera = scene.localViewCamera, bounds = scene.cameraViewportSize
                // A follower publishes no viewport: following a follower would
                // otherwise let two cameras chase each other.
                let viewport = followedDevice != nil ? nil : SharedArea.Rect(x: camera.x, y: camera.y,
                    width: max(1, bounds.width / camera.zoom), height: max(1, bounds.height / camera.zoom))
                try await controller.publishPresence(.init(session: session, sequence: sequence, cursor: cursor, viewport: viewport,
                    sentAt: cursorSampledAt))
            } catch { if ticket == generation { session = nil } }
        }
    }
    private func sendTrailing() {
        trailingTimer?.invalidate(); trailingTimer = nil
        guard trailing else { return }
        send(force: false)
    }
}
