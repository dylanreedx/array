import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

@MainActor
final class GhosttyTerminalView: NSView {
    private let launchProfile: LaunchProfile
    private let statusChanged: (TerminalStatus) -> Void
    private(set) var surface: ghostty_surface_t?
    private var processExitPoller: Timer?
    private var previousModifierFlags: NSEvent.ModifierFlags = []

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
        sendKey(event: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event: event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        let relevantPrevious = previousModifierFlags.intersection(Self.modifierOnlyFlags)
        let relevantCurrent = event.modifierFlags.intersection(Self.modifierOnlyFlags)
        defer { previousModifierFlags = relevantCurrent }

        guard Self.modifierGhosttyMod(forKeyCode: event.keyCode) != nil else { return }
        if relevantPrevious == relevantCurrent { return }

        let action: ghostty_input_action_e
        if relevantCurrent.isStrictSuperset(of: relevantPrevious) {
            action = GHOSTTY_ACTION_PRESS
        } else {
            action = GHOSTTY_ACTION_RELEASE
        }
        sendKey(event: event, action: action)
    }

    private func sendKey(event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }

        var keyEv = ghostty_input_key_s()
        keyEv.action = action
        keyEv.keycode = UInt32(event.keyCode)
        keyEv.mods = Self.ghosttyMods(event.modifierFlags)
        // Heuristic from upstream: control and command never contribute to text
        // translation; everything else does.
        keyEv.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        keyEv.composing = false
        keyEv.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            keyEv.unshifted_codepoint = codepoint.value
        }

        // Set text only for non-control, non-PUA characters. Ghostty does its
        // own control-character encoding from `mods`, and PUA function-key
        // codepoints (arrows, F-keys) must be conveyed via `keycode` only.
        if (event.type == .keyDown || event.type == .keyUp),
           let text = Self.ghosttyText(for: event),
           !text.isEmpty,
           let leadingByte = text.utf8.first,
           leadingByte >= 0x20 {
            text.withCString { ptr in
                keyEv.text = ptr
                _ = ghostty_surface_key(surface, keyEv)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEv)
        }
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static let modifierOnlyFlags: NSEvent.ModifierFlags = [
        .shift,
        .control,
        .option,
        .command,
        .capsLock
    ]

    private static func modifierGhosttyMod(forKeyCode keyCode: UInt16) -> ghostty_input_mods_e? {
        switch keyCode {
        case 0x39:
            GHOSTTY_MODS_CAPS
        case 0x38, 0x3C:
            GHOSTTY_MODS_SHIFT
        case 0x3B, 0x3E:
            GHOSTTY_MODS_CTRL
        case 0x3A, 0x3D:
            GHOSTTY_MODS_ALT
        case 0x37, 0x36:
            GHOSTTY_MODS_SUPER
        default:
            nil
        }
    }

    private static func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            // Drop control characters: Ghostty re-derives them from mods.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Drop PUA function-key codepoints: convey via keycode only.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setGhosttyFocus(true)
        forwardMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        forwardMouseButton(event: event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardMouseButton(event: event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMousePos(event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMousePos(event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardMousePos(event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardMousePos(event: event)
    }

    override func mouseEntered(with event: NSEvent) {
        forwardMousePos(event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        // Match upstream's 2x speedup for precision deltas; it "feels right."
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, 0)
    }

    private func forwardMouseButton(
        event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMods(event.modifierFlags))
    }

    private func forwardMousePos(event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // NSView origin is bottom-left; Ghostty expects top-left.
        ghostty_surface_mouse_pos(
            surface,
            pos.x,
            frame.height - pos.y,
            Self.ghosttyMods(event.modifierFlags)
        )
    }

    func scrollDirectly(deltaX: Double, deltaY: Double) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, 0)
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
        startProcessExitPoller()
    }

    private func startProcessExitPoller() {
        // Poll ghostty_surface_process_exited at 250ms intervals. The
        // close_surface_cb path is only triggered by explicit requestClose
        // calls in this Ghostty build; natural shell exits (e.g. `exit`
        // typed at the prompt) are only observable via this polling API.
        // The exit code is delivered via the action_cb's child_exited message
        // (currently a no-op); until that's wired through, we stamp nil.
        // TODO: route action_cb's GHOSTTY_ACTION_CHILD_EXITED to capture the code.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let surface = self.surface else { return }
                if ghostty_surface_process_exited(surface) {
                    self.processExitPoller?.invalidate()
                    self.processExitPoller = nil
                    self.statusChanged(.exited(exitCode: nil))
                    self.closeSurface()
                }
            }
        }
        // .common mode keeps the timer firing during modal tracking, drag
        // gestures, and menu sessions. Default scheduledTimer uses .default
        // which would miss exits while the user holds a drag.
        RunLoop.main.add(timer, forMode: .common)
        processExitPoller = timer
    }

    private func closeSurface() {
        processExitPoller?.invalidate()
        processExitPoller = nil
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
