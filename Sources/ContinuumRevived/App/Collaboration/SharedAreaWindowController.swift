import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A shared window owns a subscription and private camera, never source runtimes.
@MainActor
final class SharedAreaWindowController: NSObject, NSWindowDelegate {
    let controller: SharedAreaController
    let window: NSWindow
    let scene: SharedAreaSceneView
    let presencePublisher: SharedAreaPresencePublisher
    var onClose: (() -> Void)?
    private var openTask: Task<Void, Never>?
    private var closed = false

    init(controller: SharedAreaController, person: SharedArea.ID<SharedArea.Person>, delegate: AppDelegate) {
        self.controller = controller
        window = CollaborationWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Shared workspace"
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        scene = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: controller, person: person, in: window)
        presencePublisher = SharedAreaPresencePublisher(scene: scene)
        super.init()
        window.initialFirstResponder = scene.areaCanvasView
        window.delegate = self
        window.center()
    }
    func show() {
        guard !closed else { return }
        CollaborationWindow.present(window)
        presencePublisher.start()
        guard openTask == nil else { return }
        openTask = Task { [weak self] in
            guard let self, !closed else { return }
            await controller.open()
        }
    }
    func waitUntilOpen() async { await openTask?.value }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; openTask?.cancel(); openTask = nil
        presencePublisher.stop()
        scene.unmount()
        let controller = controller
        Task { await controller.close() }
        onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try scene.prepareToClose(); return true }
        catch {
            let alert = NSAlert()
            alert.messageText = "Your private draft could not be saved"
            alert.informativeText = "The shared workspace stays open so you can copy your draft or retry saving."
            alert.beginSheetModal(for: sender)
            return false
        }
    }
}

extension AppDelegate {
    /// Dedicated shared-scene branch of the shipping mount seam. It deliberately
    /// receives no project spawner/controller or source-canvas persistence route.
    @discardableResult
    func mountWorkspaceSceneAtBoot(sharedAreaController: SharedAreaController,
                                   person: SharedArea.ID<SharedArea.Person>, in window: NSWindow) -> SharedAreaSceneView {
        CollaborationWindow.mark(window)
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        return mountWorkspaceSceneAtBoot(sharedAreaController: sharedAreaController, person: person, in: host)
    }
    @discardableResult
    func mountWorkspaceSceneAtBoot(sharedAreaController: SharedAreaController,
                                   person: SharedArea.ID<SharedArea.Person>, in host: NSView) -> SharedAreaSceneView {
        let view = SharedAreaSceneView(controller: sharedAreaController, person: person)
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        view.mount()
        return view
    }
}
