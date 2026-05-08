import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

@MainActor
final class GhosttyTerminalView: NSView {
    private let launchProfile: LaunchProfile
    private let statusChanged: (TerminalStatus) -> Void
    private(set) var surface: ghostty_surface_t?

    override var acceptsFirstResponder: Bool { true }

    init(
        ghosttyApp: ghostty_app_t,
        launchProfile: LaunchProfile,
        statusChanged: @escaping (TerminalStatus) -> Void
    ) {
        self.launchProfile = launchProfile
        self.statusChanged = statusChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        statusChanged(.configuring)
        createSurface(app: ghosttyApp)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurfaceSize()
        window?.makeFirstResponder(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSurfaceSize()
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else { return }
        sendText(characters)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setGhosttyFocus(true)
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    func setGhosttyFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setSurfacePixelSize(_ size: CGSize) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
        reportSurfaceSize()
    }

    func updateSurfaceSize() {
        guard surface != nil else { return }
        let backingSize = convertToBacking(bounds).size
        setSurfacePixelSize(backingSize)
    }

    func requestClose(force: Bool) {
        guard let surface else { return }
        if force {
            closeSurface()
            statusChanged(.exited(exitCode: nil))
        } else {
            ghostty_surface_request_close(surface)
        }
    }

    func visibleText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        guard ghostty_surface_read_text(surface, selection, &text) else {
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    static func handleGhosttyClose(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata else { return }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            view.statusChanged(.exited(exitCode: nil))
            view.closeSurface()
        }
    }

    private func createSurface(app: ghostty_app_t) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = scale
        config.font_size = 0
        config.env_vars = nil
        config.env_var_count = 0
        config.initial_input = nil
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        launchProfile.cwd.withCString { cwdPointer in
            launchProfile.command.withCString { commandPointer in
                config.working_directory = cwdPointer
                config.command = commandPointer
                surface = ghostty_surface_new(app, &config)
            }
        }

        guard surface != nil else {
            statusChanged(.error(message: "ghostty_surface_new returned nil"))
            return
        }

        statusChanged(.running)
        updateSurfaceSize()
    }

    private func closeSurface() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    private func reportSurfaceSize() {
        guard let surface else { return }
        let size = ghostty_surface_size(surface)
        Swift.print("Ghostty size: \(size.columns)x\(size.rows), \(size.width_px)x\(size.height_px) px")
    }
}
