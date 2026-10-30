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
    private var monitor: Any?
    private var timer: Timer?
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var cursor: Collaboration.Point?
    private var screenCursor: NSPoint?
    private var lastSent = Date.distantPast
    private var stopped = true
    private var lastStatus: SharedAreaController.Status?

    init(scene: SharedAreaSceneView) {
        self.scene = scene; controller = scene.controller
        overlay = SharedAreaPresenceOverlay(scene: scene)
    }
    func start() {
        guard stopped else { return }; stopped = false
        overlay.frame = scene.areaCanvasView.bounds
        scene.areaCanvasView.addSubview(overlay)
        scene.onCanvasTransformChange = { [weak self] in self?.refreshPointerGeometry() }
        overlay.onPointerExit = { [weak self] in
            guard let self else { return }
            cursor = nil; screenCursor = nil; send(force: false)
        }
        scene.window?.acceptsMouseMovedEvents = true
        observer = controller.addChangeObserver { [weak self] in self?.refresh() }
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
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        timer?.invalidate(); timer = nil; task?.cancel(); task = nil
        scene.onCanvasTransformChange = nil; overlay.onPointerExit = nil
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
        guard controller.status == .connected else { return }
        if changed { send(force: true) }
    }
    func publishPointer(_ point: Collaboration.Point?) async {
        cursor = point
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
        }
        send(force: false)
    }
    private func send(force: Bool) {
        guard !stopped, controller.status == .connected, task == nil,
              force || Date().timeIntervalSince(lastSent) >= 0.05 else { return }
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == generation { task = nil } }
            do {
                if session == nil {
                    let next = try await controller.beginPresence()
                    guard ticket == generation, !stopped else { try? await controller.endPresence(next.id); return }
                    session = next.id; sequence = 0
                }
                guard let session, sequence < UInt64.max else { return }
                sequence += 1
                let camera = scene.localViewCamera, bounds = scene.areaCanvasView.bounds
                let viewport = SharedArea.Rect(x: camera.x, y: camera.y,
                    width: max(1, bounds.width / camera.zoom), height: max(1, bounds.height / camera.zoom))
                try await controller.publishPresence(.init(session: session, sequence: sequence, cursor: cursor, viewport: viewport))
                if ticket == generation { lastSent = Date() }
            } catch { if ticket == generation { session = nil } }
        }
    }
}
