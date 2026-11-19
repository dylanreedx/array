import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit
import IOSurface

/// Part of `--terminal-viewport-visibility-check`: every way a terminal can
/// come back into view WITHOUT a camera step must wake its renderer, and a
/// terminal nobody can see must not draw, whatever the reason it cannot be
/// seen.
///
/// Viewport gating sleeps a surface's renderer and nothing else. These are the
/// return paths the first version missed, because it re-evaluated visibility
/// only when the camera moved: a programmatic move into view, a workspace
/// leaving and returning, the window being covered. Each case drives the
/// production entry point (`setZones`, `parkZoneLayers`, `updateTile`, the
/// window occlusion notification) and asserts the outcome on the IOSurface
/// Ghostty presents into — draws counted from its seed, and the first frame
/// after a reveal read back as pixels.
@MainActor
enum TerminalRendererReturnChecks {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }

    private struct DrawProbe {
        var lastSeed: UInt32?
        var lastContents: UInt?
        var draws = 0
        /// True when this sample saw a new frame.
        @discardableResult
        mutating func sample(_ view: GhosttyTerminalView) -> Bool {
            guard let contents = view.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return false }
            let key = UInt(bitPattern: Unmanaged.passUnretained(contents as AnyObject).toOpaque())
            // swiftlint:disable:next force_cast
            let seed = IOSurfaceGetSeed(contents as! IOSurfaceRef)
            defer { lastSeed = seed; lastContents = key }
            guard lastSeed != nil, seed != lastSeed || key != lastContents else { return false }
            draws += 1
            return true
        }
    }

    /// The presented frame's centre pixel, as (r, g, b).
    private static func centrePixel(_ view: GhosttyTerminalView) -> (r: Int, g: Int, b: Int)? {
        guard let contents = view.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let surface = contents as! IOSurfaceRef
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0, IOSurfaceGetBytesPerElement(surface) == 4 else { return nil }
        let row = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            + (height / 2) * IOSurfaceGetBytesPerRow(surface)
        let pixel = row + (width / 2) * 4
        return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))   // BGRA
    }

    static func run() throws -> String {
        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 820)
        // The real occlusion answer for an off-display window is "not visible",
        // so the fixture says visible until the occlusion case asks the OS.
        var windowVisibleOverride: Bool? = true
        canvas.occlusionVisibilityProvider = { windowVisibleOverride ?? false }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil); window.close() }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terminal-return-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trigger = root.appendingPathComponent("paint-red")

        // A ticks continuously; B ticks far away; C paints its whole screen red
        // when the trigger file appears, and is otherwise silent.
        let ticker = "i=0; while :; do i=$((i+1)); echo TICK$i; sleep 0.01; done"
        let painter = "printf 'READY\\n'; while :; do if [ -f '\(trigger.path)' ]; then rm -f '\(trigger.path)'; "
            + "printf '\\033[48;2;255;0;0m\\033[2J'; fi; sleep 0.02; done"
        let zone = UUID()
        let placement = ZonePlacement(
            zoneId: zone, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
            size: ZoneSize(width: 30000, height: 30000), color: "blue", collapsed: false,
            hydrationPolicy: .automatic)
        let specs: [(String, String, Double)] = [("A", ticker, 20), ("B", ticker, 8000), ("C", painter, 760)]
        var tiles: [Tile] = []
        var runtimes: [GhosttyTerminalRuntime] = []
        var views: [TerminalTileNSView] = []
        for (index, spec) in specs.enumerated() {
            let tile = Tile(
                id: UUID(), kind: .terminal, title: "RET_\(spec.0)",
                frame: TileFrame(x: spec.2, y: 20, width: 400, height: 300),
                zPosition: .fromLegacyRank(index + 1), zoneId: zone, runtimeRef: nil, metadata: TileMetadata())
            let runtime = GhosttyTerminalRuntime(
                tileId: tile.id, title: tile.title,
                launchProfile: LaunchProfile(command: "/bin/sh", arguments: ["-c", spec.1],
                                             cwd: root.path, title: tile.title),
                ghostty: ghostty)
            tiles.append(tile); runtimes.append(runtime); views.append(TerminalTileNSView(tile: tile, runtime: runtime))
        }
        let layer = CanvasNSView.ZoneLayer(
            placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Return paths"),
            tiles: tiles)
        for view in views { layer.tileViews[view.tile.id] = view }
        canvas.setZones([layer])
        canvas.layoutSubtreeIfNeeded()
        defer {
            for (runtime, view) in zip(runtimes, views) {
                runtime.terminate(policy: .force)
                view.hostView.detachRuntime()
            }
        }

        var probes = Array(repeating: DrawProbe(), count: runtimes.count)
        func pump(_ seconds: TimeInterval, until condition: (() -> Bool)? = nil) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try ghostty.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
                for (index, runtime) in runtimes.enumerated() {
                    if let view = runtime.qaTerminalView { probes[index].sample(view) }
                }
                if let condition, condition() { return }
            }
        }
        func rate(_ index: Int, over seconds: TimeInterval) throws -> Double {
            probes = Array(repeating: DrawProbe(), count: runtimes.count)
            try pump(seconds)
            return Double(probes[index].draws) / seconds
        }
        func newestTick(_ index: Int) -> Int {
            runtimes[index].visibleText().split(whereSeparator: \.isNewline)
                .compactMap { $0.hasPrefix("TICK") ? Int($0.dropFirst(4)) : nil }.max() ?? -1
        }
        func told(_ index: Int) -> Bool? { runtimes[index].qaTerminalView?.qaLastAppliedGhosttyVisibility }
        var notes: [String] = []

        try pump(1.0)
        guard told(0) == true, told(2) == true else {
            throw CheckError(description: "on-screen terminals are not visible after the zone installs (A \(String(describing: told(0))), C \(String(describing: told(2))))")
        }
        guard told(1) == false else { throw CheckError(description: "terminal B, 8000 pt away, was not put to sleep") }
        guard try rate(1, over: 1.0) <= 1 else { throw CheckError(description: "terminal B draws while off-screen") }

        // 1. A programmatic move into view (the workspace API, tidy, a fit):
        //    no camera step happens, so nothing but the move can wake it.
        var moved = tiles[1]
        moved.frame = TileFrame(x: 20, y: 360, width: 400, height: 300)
        canvas.updateTile(moved, recalculateZoneBounds: false)
        try pump(0.5)
        guard told(1) == true else {
            throw CheckError(description: "terminal moved into view by updateTile stays asleep (blank) until the camera moves")
        }
        let movedRate = try rate(1, over: 1.0)
        guard movedRate >= 10 else {
            throw CheckError(description: String(format: "terminal moved into view barely draws: %.1f draws/s", movedRate))
        }
        notes.append(String(format: "moved-in %.0f draws/s", movedRate))
        moved.frame = TileFrame(x: 8000, y: 20, width: 400, height: 300)
        canvas.updateTile(moved, recalculateZoneBounds: false)
        try pump(0.3)
        guard told(1) == false else { throw CheckError(description: "terminal moved out of view by updateTile keeps rendering") }

        // 2. The workspace leaves (parked warm) and the camera changes while it
        //    is away. Parked terminals are out of every window: none may draw.
        let parked = canvas.parkZoneLayers()
        try pump(0.3)
        let parkedRate = try rate(0, over: 1.5)
        guard parkedRate <= 1 else {
            throw CheckError(description: String(format: "terminal A draws %.1f/s while its workspace is parked out of the window", parkedRate))
        }
        notes.append(String(format: "parked %.1f draws/s", parkedRate))
        let tickBeforeReturn = newestTick(0)
        canvas.setViewport(CanvasViewport(x: 7900, y: 0, zoom: 1))
        canvas.setZones(parked)
        canvas.layoutSubtreeIfNeeded()
        try pump(0.5)
        guard told(1) == true, told(0) == false else {
            throw CheckError(description: "after the workspace returned with the camera on B: B told \(String(describing: told(1))), A told \(String(describing: told(0)))")
        }
        let returnedRate = try rate(1, over: 1.0)
        guard returnedRate >= 10 else {
            throw CheckError(description: String(format: "terminal B barely draws after the workspace returned: %.1f draws/s", returnedRate))
        }
        // A kept running while parked: its screen moved on.
        guard newestTick(0) > tickBeforeReturn + 50 else {
            throw CheckError(description: "terminal A stopped consuming output while parked (tick \(tickBeforeReturn) -> \(newestTick(0)))")
        }
        notes.append(String(format: "returned %.0f draws/s", returnedRate))

        // 3. The window stops being visible (covered, minimised, hidden, another
        //    space): the OS's own answer for this off-display window is "not
        //    visible", so stop overriding it and post the notification AppKit posts.
        windowVisibleOverride = nil
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try pump(0.3)
        let occludedRate = try rate(1, over: 1.5)
        guard told(1) == false, occludedRate <= 1 else {
            throw CheckError(description: String(format: "an on-canvas terminal in an invisible window still draws %.1f/s", occludedRate))
        }
        notes.append(String(format: "window occluded %.1f draws/s", occludedRate))
        windowVisibleOverride = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try pump(0.3)
        guard told(1) == true, try rate(1, over: 1.0) >= 10 else {
            throw CheckError(description: "terminal B did not resume drawing when the window became visible again")
        }

        // 4. Content that changes while asleep is on the FIRST frame after a reveal.
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.updateRendererViewportVisibility(full: true)
        try pump(5.0) { runtimes[2].visibleText().contains("READY") }
        try pump(0.5)
        guard told(2) == true, let before = runtimes[2].qaTerminalView.flatMap(centrePixel), before.r < 200 || before.g > 60 else {
            throw CheckError(description: "painter terminal not ready and visible before the hidden paint")
        }
        canvas.setViewport(CanvasViewport(x: 7900, y: 0, zoom: 1))
        canvas.updateRendererViewportVisibility(full: true)
        try pump(0.3)
        guard told(2) == false else { throw CheckError(description: "painter terminal was not put to sleep") }
        probes = Array(repeating: DrawProbe(), count: runtimes.count)
        try pump(0.1)
        FileManager.default.createFile(atPath: trigger.path, contents: Data())
        try pump(3.0) { !FileManager.default.fileExists(atPath: trigger.path) }
        try pump(0.5)
        guard probes[2].draws <= 1 else {
            throw CheckError(description: "painter terminal drew \(probes[2].draws) frames while asleep")
        }
        guard let view = runtimes[2].qaTerminalView else { throw CheckError(description: "painter surface gone") }
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.updateRendererViewportVisibility(full: true)
        var first: (r: Int, g: Int, b: Int)?
        var reveal = DrawProbe()
        reveal.sample(view)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, first == nil {
            ghostty_app_tick(try ghostty.app)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            if reveal.sample(view) { first = centrePixel(view) }
        }
        guard let first else { throw CheckError(description: "revealed painter terminal presented no frame within 2 s") }
        guard first.r > 200, first.g < 60, first.b < 60 else {
            throw CheckError(description: "first frame after reveal is stale: centre pixel \(first), want the red painted while asleep")
        }
        notes.append("first revealed frame current")
        return "return paths: " + notes.joined(separator: ", ")
    }
}
