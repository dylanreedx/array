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

    func dehydrateForSnapshot() {
        guard let terminalView else { return }
        blur()
        terminalView.isHidden = true
        terminalView.setSnapshotOccluded(true)
    }

    func rehydrateFromSnapshot() {
        guard let terminalView else { return }
        terminalView.isHidden = false
        terminalView.setSnapshotOccluded(false)
        terminalView.updateSurfaceSize()
    }

    var isProcessExitedForSnapshotCheck: Bool {
        terminalView?.isProcessExited() ?? true
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

    static func runSnapshotTierSelfCheck() throws -> URL {
        let started = Date()
        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }

        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let runtime = GhosttyTerminalRuntime(
            title: "Terminal snapshot check",
            launchProfile: LaunchProfile(command: "/bin/sh", arguments: [], cwd: FileManager.default.currentDirectoryPath, title: "Terminal snapshot check"),
            ghostty: context
        )
        let sessionId = runtime.id
        host.attach(runtime: runtime)
        host.layoutSubtreeIfNeeded()
        runtime.sendInput(Data("printf 'con44-ready\\n'\n".utf8))
        try tick(context: context, timeout: 4.0) { runtime.visibleText().contains("con44-ready") }

        runtime.dehydrateForSnapshot()
        try tick(context: context, seconds: 0.5)
        let aliveWhileSnapshotted = !runtime.isProcessExitedForSnapshotCheck
        let sameIdWhileSnapshotted = runtime.id == sessionId

        runtime.rehydrateFromSnapshot()
        runtime.sendInput(Data("printf 'con44-input-ok\\n'\n".utf8))
        try tick(context: context, timeout: 4.0) { runtime.visibleText().contains("con44-input-ok") }
        let sameIdAfterRehydrate = runtime.id == sessionId
        let inputWorked = runtime.visibleText().contains("con44-input-ok")

        runtime.terminate(policy: .force)
        host.detachRuntime()

        guard aliveWhileSnapshotted, sameIdWhileSnapshotted, sameIdAfterRehydrate, inputWorked else {
            throw NSError(
                domain: "ContinuumRevivedTerminalSnapshotTierCheck",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "terminal snapshot check failed: alive=\(aliveWhileSnapshotted), sameSnapshot=\(sameIdWhileSnapshotted), sameRehydrate=\(sameIdAfterRehydrate), input=\(inputWorked)"]
            )
        }

        let runId = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: "qa-runs/terminal-snapshot-tier-\(runId)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("terminal-snapshot-tier.log")
        let lines = [
            "session_id=\(sessionId)",
            "alive_while_snapshotted=\(aliveWhileSnapshotted)",
            "same_id_while_snapshotted=\(sameIdWhileSnapshotted)",
            "same_id_after_rehydrate=\(sameIdAfterRehydrate)",
            "input_after_rehydrate=\(inputWorked)"
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return log
    }

    private static func tick(context: GhosttyRuntimeContext, seconds: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            ghostty_app_tick(try context.app)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func tick(context: GhosttyRuntimeContext, timeout: TimeInterval, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            ghostty_app_tick(try context.app)
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        throw NSError(
            domain: "ContinuumRevivedTerminalSnapshotTierCheck",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "terminal snapshot check timed out"]
        )
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
            action_cb: { _, _, _ in false },
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
