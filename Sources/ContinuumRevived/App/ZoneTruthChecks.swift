import AppKit
import ContinuumRevivedCore
import Foundation

/// Confidence pass, stream S2 ("tiles never vanish, and every zone the user can
/// see can hold tiles"). Every leg mounts `WorkspaceInvariantsFixture` through
/// `mountWorkspaceSceneAtBoot`, drives a real entry point, and asserts the model,
/// the bytes on disk, and the scene after a remount.
@MainActor
enum ZoneTruthChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    static func writeArtifact(_ name: String, _ manifest: [String: Any]) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    /// Deterministic canvas preferences: no drag snapping, auto-layout as asked.
    static func pinPreferences(_ canvas: CanvasNSView, autoLayout: Bool) -> UserDefaults {
        let suite = "zone-truth-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
        defaults.set(autoLayout, forKey: CanvasAutoLayoutConfig.enabledKey)
        canvas.dragMagnetizeDefaults = defaults
        canvas.autoLayoutDefaults = defaults
        canvas.breakoutDefaults = defaults
        return defaults
    }

    /// A real (offscreen) window, so synthetic pointer events convert.
    static func hostInWindow(_ canvas: CanvasNSView) -> NSWindow {
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        canvas.layoutSubtreeIfNeeded()
        return window
    }

    /// A pointer drag on the tile's grab strip, through `TileNSView`'s own
    /// mouseDown / mouseDragged / mouseUp. `worldDelta` is in WORLD points
    /// (zoom is 1 in every fixture viewport).
    static func dragTile(_ view: TileNSView, worldDelta: CGSize, window: NSWindow) throws {
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(message: "could not synthesize \(type)") }
            return e
        }
        let grab = view.convert(NSPoint(x: view.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        // Window y goes up; the canvas is flipped.
        let drop = NSPoint(x: grab.x + worldDelta.width, y: grab.y - worldDelta.height)
        view.mouseDown(with: try event(.leftMouseDown, at: grab))
        view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: (grab.x + drop.x) / 2, y: (grab.y + drop.y) / 2)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: drop))
        view.mouseUp(with: try event(.leftMouseUp, at: drop))
    }

    static func contains(_ zone: ZonePlacement, _ frame: TileFrame) -> Bool {
        let rect = CanvasEngine.zoneWorldFrame(zone)
        return frame.x >= rect.x - 0.001 && frame.y >= rect.y - 0.001
            && frame.x + frame.width <= rect.x + rect.width + 0.001
            && frame.y + frame.height <= rect.y + rect.height + 0.001
    }

    // MARK: - --zone-layer-move-check

    /// F1 #7: after the mount a tile could never change zone. Membership was
    /// re-evaluated against the flat boot snapshot (`canvasState.tiles`), which
    /// does not hold a layer's tiles, so a drop into another zone of the same
    /// project did nothing and auto-layout clamped the tile back. And
    /// `retireFlatCompatibilityScene` left that snapshot populated, so every
    /// ungated reader got the boot project's launch-time frames.
    static func runLayerMove() throws -> URL {
        var manifest: [String: Any] = [:]
        for autoLayout in [false, true] {
            let fixture = try Fixture(label: "layer-move-\(autoLayout)")
            defer { fixture.dispose() }
            try fixture.mount()
            let m = try fixture.requireMounted("layer-move")
            _ = pinPreferences(m.canvas, autoLayout: autoLayout)
            let window = hostInWindow(m.canvas)
            defer { window.orderOut(nil) }
            let label = autoLayout ? "auto-layout on" : "auto-layout off"

            try expect(m.canvas.canvasState.tiles.isEmpty,
                       "\(label): the retired flat scene still holds \(m.canvas.canvasState.tiles.count) boot-time "
                       + "tile(s); every ungated reader of `canvasState.tiles` answers from that stale snapshot")

            let mover = Fixture.noteA1a
            let target = Fixture.zoneA3
            guard let view = m.canvas.tileView(for: mover) else {
                throw Failure(message: "\(label): the mover has no tile view")
            }
            try expect(m.canvas.installedZoneIds(containing: mover) == [Fixture.zoneA1],
                       "\(label): precondition, the mover starts in zone A1")
            // From (640, 280) to (960, 1060): fully inside A3, clear of A3's own tile.
            let dropFrame = TileFrame(x: 960, y: 1060, width: 240, height: 160)
            try dragTile(view, worldDelta: CGSize(width: 320, height: 780), window: window)
            m.canvas.layoutSubtreeIfNeeded()

            try expect(m.canvas.installedZoneIds(containing: mover) == [target],
                       "\(label): THE reported bug. A tile dropped inside another zone of its own project "
                       + "must move to that zone's layer; it is in \(m.canvas.installedZoneIds(containing: mover))")
            guard let world = m.canvas.tilesInWorldFrames(forZoneId: target)?.first(where: { $0.id == mover })?.frame,
                  let zone = m.canvas.zonePlacement(for: target) else {
                throw Failure(message: "\(label): the target layer cannot report the mover's frame")
            }
            try expect(contains(zone, world), "\(label): the mover \(world) must sit inside its new zone \(zone.origin)/\(zone.size)")
            if !autoLayout {
                try expect(world == dropFrame, "\(label): the move must keep the drop's WORLD frame \(dropFrame); got \(world)")
                // Undo puts the record back in the zone it left, exactly; redo
                // carries it over again.
                m.canvas.undo(nil)
                try expect(m.canvas.installedZoneIds(containing: mover) == [Fixture.zoneA1]
                           && m.canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA1)?.first(where: { $0.id == mover })?.frame
                               == Fixture.seed.tiles[mover],
                           "\(label): undo must return the mover to zone A1 at its seeded frame; it is in "
                           + "\(m.canvas.installedZoneIds(containing: mover))")
                m.canvas.redo(nil)
                try expect(m.canvas.installedZoneIds(containing: mover) == [target]
                           && m.canvas.tilesInWorldFrames(forZoneId: target)?.first(where: { $0.id == mover })?.frame == dropFrame,
                           "\(label): redo must carry the mover back into A3 at the drop frame")
            }
            fixture.drain()

            try fixture.remount(crash: false)
            let disk = fixture.readProjectFile(Fixture.projectA1).canvas
            guard let persisted = disk?.tiles.first(where: { $0.id == mover }) else {
                throw Failure(message: "\(label): the mover vanished from its project's canvas.json")
            }
            try expect(persisted.zoneId == target,
                       "\(label): canvas.json must stamp the mover with its new zone; got \(String(describing: persisted.zoneId))")
            try expect(persisted.frame == world, "\(label): canvas.json must hold the WORLD frame it was drawn at: \(persisted.frame) vs \(world)")
            let remounted = try fixture.requireMounted("layer-move remount")
            try expect(remounted.canvas.installedZoneIds(containing: mover) == [target],
                       "\(label): after a remount the new zone's layer must own the mover")
            manifest[label] = ["frame": [world.x, world.y, world.width, world.height]]
        }
        return try writeArtifact("zone-layer-move", manifest)
    }

    // MARK: - --canvas-unreadable-check

    /// F1 #3: a `canvas.json` that exists and does not decode (an unknown tile
    /// kind from a newer build, a newer schema, corruption) read as EMPTY. The
    /// mount built empty layers over it, and the first pan's camera save merged
    /// against "nothing" and wrote that over the file; three more saves rotated
    /// the original out of the backups for good.
    static func runCanvasUnreadable() throws -> URL {
        var manifest: [String: Any] = [:]
        let variants: [(String, (inout [String: Any]) -> Void)] = [
            ("unknown tile kind", { json in
                var tiles = json["tiles"] as! [[String: Any]]
                tiles[0]["kind"] = "futureKind"
                json["tiles"] = tiles
            }),
            ("newer schema", { json in json["schemaVersion"] = 99 }),
        ]
        for (label, corrupt) in variants {
            let fixture = try Fixture(label: "unreadable")
            defer { fixture.dispose() }
            // Birch (A2) is not the boot project, so the mount itself must cope.
            let victim = Fixture.projectA2
            let layout = ProjectStoreLayout(projectRoot: fixture.projectRoots[victim]!)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.canvasFile)) as! [String: Any]
            corrupt(&json)
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: layout.canvasFile)
            try? FileManager.default.removeItem(at: layout.backupsDirectory)
            let original = try Data(contentsOf: layout.canvasFile)

            try fixture.mount()
            var m = try fixture.requireMounted("unreadable")
            try expect(m.canvas.installedZonePlacement(for: Fixture.zoneA2) == nil,
                       "\(label): an unreadable project must not mount as an EMPTY zone; that empty layer is what "
                       + "the next save wrote over the file")
            try expect(m.canvas.qaZoneChromeIds.contains(Fixture.zoneA2),
                       "\(label): the zone itself must still draw")
            let message = m.delegate.qaWorkspaceManagementMessage ?? ""
            try expect(message.contains("Birch") && message.contains("unavailable"),
                       "\(label): the user must be told the project is unavailable; message: \(message)")

            // Pan, arm, spawn, flush: every writer a user can reach.
            m.canvas.setViewport(CanvasViewport(x: 1200, y: -50, zoom: 1))
            m.delegate.canvasDidChange(m.canvas)
            try fixture.armByClick(Fixture.zoneA2)
            m.delegate.canvasDidChange(m.canvas)
            fixture.drain()
            _ = m.delegate.qaPerformPaletteAction(.newNote)
            try expect(m.canvas.installedZonePlacement(for: Fixture.zoneA2) == nil,
                       "\(label): a spawn must not build an empty layer over the unreadable project")
            try m.runtime.flushMountedWorkspaceState()
            fixture.drain()
            let afterSession = try Data(contentsOf: layout.canvasFile)
            try expect(afterSession == original,
                       "\(label): THE reported bug. The unreadable canvas.json was written over")

            try fixture.remount(crash: false)
            m = try fixture.requireMounted("unreadable remount")
            let afterRemount = try Data(contentsOf: layout.canvasFile)
            try expect(afterRemount == original,
                       "\(label): quit and remount must leave the file byte-identical")
            try expect(m.canvas.installedZonePlacement(for: Fixture.zoneA2) == nil,
                       "\(label): still unavailable after a remount")
            // The readable projects are untouched by the refusal.
            try expect(m.canvas.installedZoneIds(containing: Fixture.noteA1a) == [Fixture.zoneA1],
                       "\(label): a readable neighbour must still mount its tiles")
            manifest[label] = ["bytes": original.count]
        }
        return try writeArtifact("canvas-unreadable", manifest)
    }
}
