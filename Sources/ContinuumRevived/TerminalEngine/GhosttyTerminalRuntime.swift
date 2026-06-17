import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

@MainActor
final class GhosttyTerminalRuntime: TerminalRuntime, AgentTileTextEndpoint {
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

    /// QA hook: the live terminal view, for headless scale/geometry checks.
    var qaTerminalView: GhosttyTerminalView? { terminalView }

    /// Authoritative surface sizing pushed by the canvas (CanvasNSView.layoutTile)
    /// from the tile's WORLD content size × backing scale — independent of the
    /// canvas zoom. Keeps the column grid tied to the tile's logical size so zoom
    /// is pure navigation (no reflow) and the surface always fills the tile,
    /// bypassing the stale-bounds-at-attach race.
    func setSurfacePixelSize(_ size: CGSize) {
        terminalView?.setSurfacePixelSize(size)
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

    var readVisibleText: String {
        visibleText()
    }

    /// Captures the current working directory for persistence. Returns the last cwd
    /// reported via OSC 7 (GHOSTTY_ACTION_PWD) if available, falling back to the
    /// launch profile's cwd when no OSC 7 has fired yet.
    var capturedCwd: String {
        terminalView?.lastReportedCwd ?? launchProfile.cwd
    }

    /// Captures the current visible/scrollback text for persistence. Reuses
    /// the existing `ghostty_surface_read_text` path via `visibleText()`.
    var capturedScrollback: String {
        visibleText()
    }

    /// Scrollback replay entry point. Option (c) per the spec NEEDS-HUMAN gotcha:
    /// the replay mechanism (display-only injection vs. typed banner) requires a
    /// human decision before wiring. This function exists so callers can be written
    /// against the interface; the body is intentionally a no-op until the mechanism
    /// is chosen. The scrollback IS persisted to disk — only the on-screen replay is
    /// deferred.
    func replayScrollback(_ text: String) {
        // No-op: replay mechanism deferred (NEEDS-HUMAN). Scrollback persisted on disk.
    }

    func sendReturn() {
        sendInput(Data("\n".utf8))
    }

    func sendInsertedText(_ text: String) -> Bool {
        dispatchInsertedText(text)
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
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
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

    static func runStrayWindowAuditSelfCheck() throws -> URL {
        struct WindowSample {
            let label: String
            let windows: [[String: Any]]
        }

        func ownedWindows() -> [[String: Any]] {
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.map { window in
                var out: [String: Any] = [:]
                out["windowNumber"] = window[kCGWindowNumber as String]
                out["name"] = window[kCGWindowName as String] as? String ?? ""
                out["layer"] = window[kCGWindowLayer as String]
                out["alpha"] = window[kCGWindowAlpha as String]
                out["bounds"] = window[kCGWindowBounds as String]
                return out
            }
        }

        func pump(_ context: GhosttyRuntimeContext, seconds: TimeInterval = 0.3) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }
        var samples: [WindowSample] = [WindowSample(label: "baseline", windows: ownedWindows())]

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = host
        window.orderFront(nil)
        try pump(context)
        samples.append(WindowSample(label: "mainWindow", windows: ownedWindows()))

        let profile = try ShellLaunchResolver().resolveShell(cwd: FileManager.default.temporaryDirectory.path)
        let runtime = GhosttyTerminalRuntime(title: "stray-window-audit", launchProfile: profile, ghostty: context)
        host.attach(runtime: runtime)
        try pump(context)
        samples.append(WindowSample(label: "terminalAttached", windows: ownedWindows()))

        runtime.terminate(policy: .force)
        host.detachRuntime()
        window.close()
        try pump(context)
        samples.append(WindowSample(label: "closed", windows: ownedWindows()))

        let baselineCount = samples[0].windows.count
        let mainCount = samples[1].windows.count
        let attachedCount = samples[2].windows.count
        let terminalDelta = attachedCount - mainCount
        guard terminalDelta == 0 else {
            throw NSError(domain: "ContinuumRevivedStrayWindowAuditCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "terminal attach added \(terminalDelta) process-owned CG windows (baseline=\(baselineCount), main=\(mainCount), attached=\(attachedCount))"])
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("stray-window-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "stray-window-audit",
            "baselineCount": baselineCount,
            "mainWindowCount": mainCount,
            "terminalAttachedCount": attachedCount,
            "terminalDelta": terminalDelta,
            "samples": samples.map { ["label": $0.label, "windows": $0.windows] },
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    /// P1 (terminal scale / Option B): installs a REAL terminal tile in a
    /// CanvasNSView+window and asserts the navigation-zoom invariant — the ghostty
    /// surface fills the tile (surface width ≈ tile world content width × backing)
    /// and the column grid is INVARIANT across a canvas-zoom sweep (zoom is pure
    /// navigation, not reflow). RED before the fix: today `updateSurfaceSize` uses
    /// `convertToBacking(bounds)`, which composes the tile's zoom transform, so the
    /// surface width scales with zoom (≠ world×backing) and columns reflow.
    static func runTerminalFillsTileSelfCheck() throws -> URL {
        struct CheckError: Error, CustomStringConvertible {
            let message: String
            var description: String { message }
        }

        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }

        let worldWidth: Double = 800
        let worldHeight: Double = 520
        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000005CB")!,
            kind: .terminal,
            title: "FILLS_TILE_PROBE",
            frame: TileFrame(x: 0, y: 0, width: worldWidth, height: worldHeight),
            zIndex: 1,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [tile],
            groups: [],
            lastActiveTileId: nil
        ))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 820)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 820),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.close() }

        let cwd = FileManager.default.currentDirectoryPath
        let runtime = GhosttyTerminalRuntime(
            tileId: tile.id,
            title: "fills-tile",
            launchProfile: LaunchProfile(command: "/bin/sh", arguments: [], cwd: cwd, title: "fills-tile"),
            ghostty: context
        )
        let tileView = TerminalTileNSView(tile: tile, runtime: runtime)
        canvas.install(tileView: tileView, for: tile)
        tileView.layoutSubtreeIfNeeded()

        func pump(_ seconds: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        try pump(0.6)

        let backing = Double(window.backingScaleFactor)
        // The terminal fills the full tile width (no horizontal inset), so the
        // surface should be the tile WORLD width × backing — at EVERY zoom.
        let expectedWidthPx = worldWidth * backing

        struct Sample { let zoom: Double; let widthPx: Int; let columns: Int }
        var samples: [Sample] = []
        let zooms: [Double] = [1.0, 0.6, 1.8]
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.layoutSubtreeIfNeeded()
            try pump(0.25)
            guard let term = runtime.qaTerminalView, let surface = term.surface else {
                throw CheckError(message: "zoom \(zoom): terminal surface missing")
            }
            let size = ghostty_surface_size(surface)
            samples.append(Sample(zoom: zoom, widthPx: Int(size.width_px), columns: Int(size.columns)))
        }

        runtime.terminate(policy: .force)
        tileView.hostView.detachRuntime()

        let summary = samples.map { String(format: "z=%.2f surf=%dpx cols=%d", $0.zoom, $0.widthPx, $0.columns) }.joined(separator: " | ")

        // (1) Surface fills the tile width at every zoom (zoom-independent).
        for sample in samples {
            let drift = abs(Double(sample.widthPx) - expectedWidthPx) / max(1.0, expectedWidthPx)
            if drift > 0.03 {
                throw CheckError(message: "surface width != tile world width × backing at zoom \(sample.zoom): got \(sample.widthPx)px, expected ≈\(Int(expectedWidthPx))px (drift \(Int(drift * 100))%). zoom must not resize the grid. [\(summary)]")
            }
        }
        // (2) Columns invariant across the zoom sweep (navigation, not reflow).
        if let baseline = samples.first?.columns {
            for sample in samples where abs(sample.columns - baseline) > 1 {
                throw CheckError(message: "columns reflow with zoom: \(sample.columns) vs baseline \(baseline). [\(summary)]")
            }
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("terminal-fills-tile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "terminal-fills-tile",
            "worldWidth": worldWidth,
            "backing": backing,
            "expectedWidthPx": expectedWidthPx,
            "samples": samples.map { ["zoom": $0.zoom, "widthPx": $0.widthPx, "columns": $0.columns] }
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
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
                // Intercept GHOSTTY_ACTION_PWD (OSC 7): deliver the reported cwd to the
                // surface's view so GhosttyTerminalRuntime.capturedCwd can read it.
                if action.tag == GHOSTTY_ACTION_PWD,
                   target.tag == GHOSTTY_TARGET_SURFACE,
                   let surface = Optional(target.target.surface) {
                    let userdata = ghostty_surface_userdata(surface)
                    let pwd = action.action.pwd.pwd
                    scheduleGhosttyPwd(userdata: userdata, pwd: pwd)
                }
                return false
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

/// Delivers an OSC-7 cwd update (GHOSTTY_ACTION_PWD) to the surface's view.
/// Called from the action_cb C closure; schedules on the main queue to maintain
/// MainActor isolation on GhosttyTerminalView.
private func scheduleGhosttyPwd(userdata: UnsafeMutableRawPointer?, pwd: UnsafePointer<CChar>?) {
    guard let userdata, let pwd else { return }
    // Copy the C string before the callback frame is torn down.
    let path = String(cString: pwd)
    let userdataAddress = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: userdataAddress) else { return }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
        view.applyPwdAction(path)
    }
}
