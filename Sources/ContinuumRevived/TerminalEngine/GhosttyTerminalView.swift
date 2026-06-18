import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

struct TerminalWheelQASample: Codable, Equatable {
    var rawDeltaX: Double
    var rawDeltaY: Double
    var precise: Bool
    var normalizedDeltaX: Double
    var normalizedDeltaY: Double
    var deliveredViaProductionScrollWheel: Bool
}

@MainActor
final class GhosttyTerminalView: NSView {
    private let ghosttyApp: ghostty_app_t
    private let launchProfile: LaunchProfile
    private let statusChanged: (TerminalStatus) -> Void
    private(set) var surface: ghostty_surface_t?
    private var processExitPoller: Timer?
    private var previousModifierFlags: NSEvent.ModifierFlags = []
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private(set) var qaGhosttyScrollCallCount = 0
    private(set) var qaLastWheelSample: TerminalWheelQASample?
    var reservedShortcutHandler: ((NSEvent) -> Bool)?

    /// Last cwd reported by the shell via OSC 7 (GHOSTTY_ACTION_PWD). Nil until the
    /// first OSC 7 fires. Used by GhosttyTerminalRuntime.capturedCwd.
    private(set) var lastReportedCwd: String?

    /// Called from scheduleGhosttyPwd when Ghostty delivers a GHOSTTY_ACTION_PWD action.
    func applyPwdAction(_ path: String) {
        lastReportedCwd = path
    }


    override var acceptsFirstResponder: Bool { true }

    init(
        ghosttyApp: ghostty_app_t,
        launchProfile: LaunchProfile,
        reservedShortcutHandler: ((NSEvent) -> Bool)? = nil,
        statusChanged: @escaping (TerminalStatus) -> Void
    ) {
        self.ghosttyApp = ghosttyApp
        self.launchProfile = launchProfile
        self.statusChanged = statusChanged
        self.reservedShortcutHandler = reservedShortcutHandler
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        statusChanged(.configuring)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, surface == nil {
            createSurface(app: ghosttyApp)
        }
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
        if reservedShortcutHandler?(event) == true {
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = hasMarkedText()
        interpretKeyEvents([event])
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let textList = keyTextAccumulator, !textList.isEmpty {
            for text in textList {
                sendKey(event: event, action: action, text: text)
            }
        } else {
            sendKey(
                event: event,
                action: action,
                text: Self.ghosttyText(for: event),
                composing: hasMarkedText() || markedTextBefore
            )
        }
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

    private func sendKey(
        event: NSEvent,
        action: ghostty_input_action_e,
        text explicitText: String? = nil,
        composing: Bool = false
    ) {
        guard let surface else { return }

        var keyEv = ghostty_input_key_s()
        keyEv.action = action
        keyEv.keycode = UInt32(event.keyCode)
        keyEv.mods = Self.ghosttyMods(event.modifierFlags)
        // Heuristic from upstream: control and command never contribute to text
        // translation; everything else does.
        keyEv.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        keyEv.composing = composing
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
           let text = explicitText,
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
        let sample = normalizedWheelSample(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            deliveredViaProductionScrollWheel: true
        )
        qaLastWheelSample = sample
        qaGhosttyScrollCallCount += 1
        ghostty_surface_mouse_scroll(surface, sample.normalizedDeltaX, sample.normalizedDeltaY, 0)
    }

    func normalizedWheelSample(deltaX: Double, deltaY: Double, precise: Bool, deliveredViaProductionScrollWheel: Bool) -> TerminalWheelQASample {
        let normalized = TerminalWheelNormalizer.normalize(
            TerminalWheelInput(deltaX: deltaX, deltaY: deltaY, hasPreciseScrollingDeltas: precise),
            settings: TerminalScrollConfig.settings()
        )
        return TerminalWheelQASample(
            rawDeltaX: deltaX,
            rawDeltaY: deltaY,
            precise: precise,
            normalizedDeltaX: normalized.deltaX,
            normalizedDeltaY: normalized.deltaY,
            deliveredViaProductionScrollWheel: deliveredViaProductionScrollWheel
        )
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

    /// Raw lower-level QA/FFI path; intentionally bypasses terminal wheel normalization.
    func scrollDirectly(deltaX: Double, deltaY: Double) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, 0)
    }

    func sendText(_ text: String) {
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func insertCommittedText(_ text: String) {
        guard let surface else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    @discardableResult
    func setMarkedTextForSmoke(_ text: String) -> Bool {
        setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        return hasMarkedText()
    }

    func setGhosttyFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setSnapshotOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, occluded)
    }

    func isProcessExited() -> Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    func setSurfacePixelSize(_ size: CGSize) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
        reportSurfaceSize()
    }

    func updateSurfaceSize() {
        guard surface != nil else { return }
        // Size the surface to the view's WORLD bounds × backing scale — NOT
        // `convertToBacking(bounds)`, which composes the tile's frame/bounds zoom
        // transform and would make the column grid reflow as the canvas zooms.
        // Canvas zoom is navigation: it bitmap-scales the rendered tile; the grid
        // stays tied to the tile's logical size. (In the live canvas the
        // authoritative size is pushed from CanvasNSView.layoutTile; this path
        // covers resize + standalone/non-canvas hosts.)
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        setSurfacePixelSize(CGSize(width: bounds.width * backing, height: bounds.height * backing))
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

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(text.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    static func handleGhosttyClose(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata else { return }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            view.statusChanged(.exited(exitCode: nil))
            view.closeSurface()
        }
    }

    private static func commandLine(for launchProfile: LaunchProfile) -> String {
        ([launchProfile.command] + launchProfile.arguments).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=,@%")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

        let commandLine = Self.commandLine(for: launchProfile)
        launchProfile.cwd.withCString { cwdPointer in
            commandLine.withCString { commandPointer in
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

    struct ZoomScaleSample {
        let scale: Double
        let columns: UInt16
        let rows: UInt16
        let widthPx: UInt32
        let heightPx: UInt32
        let cellWidthPx: UInt32
        let cellHeightPx: UInt32
        let elapsedMs: Double
    }

    static func runZoomScaleSpike() throws -> URL {
        let started = Date()
        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }

        let cwd = FileManager.default.currentDirectoryPath
        let view = GhosttyTerminalView(
            ghosttyApp: try context.app,
            launchProfile: LaunchProfile(command: "/bin/sh", arguments: [], cwd: cwd, title: "Ghostty zoom scale spike"),
            statusChanged: { _ in }
        )
        view.setFrameSize(NSSize(width: 900, height: 600))
        view.updateSurfaceSize()

        // Give libghostty a short chance to finish its initial surface sizing work.
        for _ in 0..<5 {
            ghostty_app_tick(try context.app)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let scales: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        var samples: [ZoomScaleSample] = []
        for scale in scales {
            guard let surface = view.surface else { throw ZoomScaleSpikeError.surfaceMissing }
            let before = Date()
            ghostty_surface_set_content_scale(surface, scale, scale)
            for _ in 0..<3 {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            let size = ghostty_surface_size(surface)
            samples.append(ZoomScaleSample(
                scale: scale,
                columns: size.columns,
                rows: size.rows,
                widthPx: size.width_px,
                heightPx: size.height_px,
                cellWidthPx: size.cell_width_px,
                cellHeightPx: size.cell_height_px,
                elapsedMs: Date().timeIntervalSince(before) * 1000
            ))
        }

        view.requestClose(force: true)
        let runId = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: "qa-runs/ghostty-zoom-scale-spike-\(runId)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("scale-sweep.log")
        var lines = ["scale,columns,rows,width_px,height_px,cell_width_px,cell_height_px,elapsed_ms"]
        lines.append(contentsOf: samples.map { sample in
            String(format: "%.2f,%u,%u,%u,%u,%u,%u,%.2f", sample.scale, sample.columns, sample.rows, sample.widthPx, sample.heightPx, sample.cellWidthPx, sample.cellHeightPx, sample.elapsedMs)
        })
        try lines.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return log
    }

    struct HeadlessSurfaceSample {
        let elapsedSeconds: Int
        let residentKb: Int
        let surfacesAlive: Int
        let firstSurfaceExited: Bool
        let firstSurfaceTextBytes: Int
    }

    static func runHeadlessSurfaceSpike() throws -> URL {
        let started = Date()
        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }

        let cwd = FileManager.default.currentDirectoryPath
        var views: [GhosttyTerminalView] = []
        for index in 0..<10 {
            let view = GhosttyTerminalView(
                ghosttyApp: try context.app,
                launchProfile: LaunchProfile(command: "/usr/bin/yes", arguments: [], cwd: cwd, title: "Hidden Ghostty spike \(index + 1)"),
                statusChanged: { _ in }
            )
            view.isHidden = true
            view.setFrameSize(NSSize(width: 900, height: 600))
            view.updateSurfaceSize()
            views.append(view)
        }

        var samples: [HeadlessSurfaceSample] = []
        for second in 0...60 {
            for _ in 0..<4 {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
            let firstSurface = views.first?.surface
            let exited = firstSurface.map { ghostty_surface_process_exited($0) } ?? true
            let visibleText = views.first?.visibleText() ?? ""
            samples.append(HeadlessSurfaceSample(
                elapsedSeconds: second,
                residentKb: currentResidentKilobytes(),
                surfacesAlive: views.filter { $0.surface != nil }.count,
                firstSurfaceExited: exited,
                firstSurfaceTextBytes: visibleText.utf8.count
            ))
        }

        for view in views {
            view.requestClose(force: true)
        }

        let runId = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: "qa-runs/ghostty-headless-surface-spike-\(runId)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("hidden-surfaces.log")
        var lines = ["elapsed_seconds,resident_kb,surfaces_alive,first_surface_exited,first_surface_text_bytes"]
        lines.append(contentsOf: samples.map { sample in
            "\(sample.elapsedSeconds),\(sample.residentKb),\(sample.surfacesAlive),\(sample.firstSurfaceExited),\(sample.firstSurfaceTextBytes)"
        })
        try lines.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return log
    }

    private static func currentResidentKilobytes() -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
        } catch {
            return -1
        }
    }

    enum ZoomScaleSpikeError: Error {
        case surfaceMissing
    }
}

extension GhosttyTerminalView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0, let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else {
            return window?.convertToScreen(convert(bounds, to: nil)) ?? bounds
        }

        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let viewRect = NSRect(
            x: x,
            y: bounds.height - y,
            width: width,
            height: max(height, 1)
        )
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let plain as String:
            text = plain
        default:
            return
        }

        unmarkText()
        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
            return
        }

        insertCommittedText(text)
    }

    override func doCommand(by selector: Selector) {
    }
}
