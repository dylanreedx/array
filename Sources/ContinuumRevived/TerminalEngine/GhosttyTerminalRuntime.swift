import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

@MainActor
final class GhosttyTerminalRuntime: TerminalRuntime {
    let id: TerminalSessionID
    let tileId: TileID
    let title: String

    private let ghostty: GhosttyRuntimeContext
    private let launchProfile: LaunchProfile
    private var state = TerminalRuntimeState()
    private weak var hostView: TerminalHostView?
    private var terminalView: GhosttyTerminalView?
    private var didNotifyExit = false

    var reservedShortcutHandler: ((NSEvent) -> Bool)? {
        didSet { terminalView?.reservedShortcutHandler = reservedShortcutHandler }
    }

    /// Invoked when the underlying shell exits while the runtime is attached.
    /// Fires at most once per runtime instance. Always called on MainActor.
    var onRuntimeExited: ((TerminalSessionID, Int32?) -> Void)?

    var status: TerminalStatus { state.status }

    init(
        id: TerminalSessionID = UUID(),
        tileId: TileID = UUID(),
        title: String,
        launchProfile: LaunchProfile,
        ghostty: GhosttyRuntimeContext
    ) {
        self.id = id
        self.tileId = tileId
        self.title = title
        self.launchProfile = launchProfile
        self.ghostty = ghostty
    }

    func attach(to hostView: TerminalHostView) {
        self.hostView = hostView

        let view = GhosttyTerminalView(
            ghosttyApp: try! ghostty.app,
            launchProfile: launchProfile,
            reservedShortcutHandler: reservedShortcutHandler
        ) { [weak self] status in
            guard let self else { return }
            switch status {
            case .configuring:
                self.state = TerminalRuntimeState(status: .configuring)
            case .running:
                self.state.markRunning()
            case .exited(let exitCode):
                self.state.markExited(exitCode: exitCode)
                if !self.didNotifyExit {
                    self.didNotifyExit = true
                    self.onRuntimeExited?(self.id, exitCode)
                }
            case .error(let message):
                self.state.markError(message)
            }
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            view.topAnchor.constraint(equalTo: hostView.topAnchor),
            view.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])

        terminalView = view
        view.updateSurfaceSize()
        focus()
    }

    func detach() {
        terminalView?.removeFromSuperview()
        terminalView = nil
        hostView = nil
    }

    func focus() {
        guard let terminalView else { return }
        terminalView.window?.makeFirstResponder(terminalView)
        terminalView.setGhosttyFocus(true)
    }

    func blur() {
        terminalView?.setGhosttyFocus(false)
    }

    func resize(cols: Int, rows: Int, pixelSize: CGSize) {
        terminalView?.setSurfacePixelSize(pixelSize)
    }

    func sendInput(_ bytes: Data) {
        guard let text = String(data: bytes, encoding: .utf8) else { return }
        terminalView?.sendText(text)
    }

    @discardableResult
    func dispatchInsertedText(_ text: String) -> Bool {
        guard let terminalView else { return false }
        terminalView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return !terminalView.hasMarkedText()
    }

    @discardableResult
    func dispatchMarkedText(_ text: String) -> Bool {
        terminalView?.setMarkedTextForSmoke(text) ?? false
    }

    func terminate(policy: TerminationPolicy) {
        terminalView?.requestClose(force: policy == .force)
    }

    func visibleText() -> String {
        terminalView?.visibleText() ?? ""
    }

    func scrollDirectly(deltaX: Double = 0, deltaY: Double) {
        terminalView?.scrollDirectly(deltaX: deltaX, deltaY: deltaY)
    }

    func dispatchKeyDown(
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String? = nil,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let terminalView, let window = terminalView.window else { return }
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )
        guard let event else { return }
        terminalView.keyDown(with: event)
    }

    func dispatchModifierFlagsChanged(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let terminalView, let window = terminalView.window else { return }
        let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
        guard let event else { return }
        terminalView.flagsChanged(with: event)
    }
}

final class GhosttyRuntimeContext {
    private var appPointer: ghostty_app_t?
    private var configPointer: ghostty_config_t?

    var app: ghostty_app_t {
        get throws {
            guard let appPointer else {
                throw GhosttyRuntimeError.appCreationFailed
            }
            return appPointer
        }
    }

    init() throws {
        guard let config = ghostty_config_new() else {
            throw GhosttyRuntimeError.configCreationFailed
        }
        configPointer = config

        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let context = Unmanaged<GhosttyRuntimeContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let appPointer = context.appPointer else { return }
                let appAddress = UInt(bitPattern: appPointer)
                DispatchQueue.main.async {
                    guard let app = UnsafeMutableRawPointer(bitPattern: appAddress) else { return }
                    ghostty_app_tick(app)
                }
            },
            action_cb: { _, target, action in
                GhosttyTerminalView.handleGhosttyAction(target: target, action: action)
            },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { userdata, processAlive in
                scheduleGhosttyClose(userdata: userdata, processAlive: processAlive)
            }
        )

        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            configPointer = nil
            throw GhosttyRuntimeError.appCreationFailed
        }

        appPointer = app
        ghostty_app_set_focus(app, true)
    }

    func shutdown() {
        if let appPointer {
            ghostty_app_free(appPointer)
            self.appPointer = nil
        }
        if let configPointer {
            ghostty_config_free(configPointer)
            self.configPointer = nil
        }
    }

}

enum GhosttyRuntimeError: Error {
    case configCreationFailed
    case appCreationFailed
}

private func scheduleGhosttyClose(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
    let userdataAddress = userdata.map { UInt(bitPattern: $0) }
    DispatchQueue.main.async {
        let pointer = userdataAddress.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
        GhosttyTerminalView.handleGhosttyClose(userdata: pointer, processAlive: processAlive)
    }
}
