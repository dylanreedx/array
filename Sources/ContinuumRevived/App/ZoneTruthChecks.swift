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

    // MARK: - --zone-close-strand-check

    /// F1 #4, B Z1-Z5, A-history W5: closing a project zone stranded its tiles.
    /// Both alert buttons ended in "keep"; the members' layer records kept the
    /// closed zone's id and were saved that way, the zone left the document, and
    /// the next mount set them aside forever as "another workspace's". "Delete
    /// Tiles" deleted nothing. The canvas stayed armed on the closed zone, and a
    /// project's last zone closing left it owned by the workspace.
    ///
    /// Drives the ✕ the way a click does: arm the zone, then
    /// `onZoneCloseRequested` into the production confirm, answered through its
    /// QA seam.
    static func runZoneCloseStrand() throws -> URL {
        var manifest: [String: Any] = [:]
        /// `armFirst: false` is the header menu's "Close Zone…", which arms
        /// nothing: teardown must still reach the closing zone's own project.
        func closeZone(_ fixture: Fixture, _ zoneId: UUID, choice: NSApplication.ModalResponse,
                       armFirst: Bool = true) throws {
            let m = try fixture.requireMounted("close")
            if armFirst { try fixture.armByClick(zoneId) }
            m.delegate.qaZoneCloseResponse = { _ in choice }
            m.canvas.onZoneCloseRequested?(zoneId)
            m.canvas.layoutSubtreeIfNeeded()
            fixture.drain()
        }
        func worldFrames(_ m: Fixture.Mounted, _ ids: [UUID]) -> [UUID: (zone: UUID, frame: TileFrame)] {
            var out: [UUID: (zone: UUID, frame: TileFrame)] = [:]
            for zone in m.runtime.document.zones {
                for tile in m.canvas.tilesInWorldFrames(forZoneId: zone.zoneId) ?? [] where ids.contains(tile.id) {
                    out[tile.id] = (zone.zoneId, tile.frame)
                }
            }
            return out
        }
        let a1Members = [Fixture.noteA1a, Fixture.noteA1b, Fixture.fileA1]

        // 1. Keep, with another zone of the same project left: the members move
        //    to it at their WORLD frames, and stay there across a remount.
        do {
            let fixture = try Fixture(label: "close-keep")
            defer { fixture.dispose() }
            try fixture.mount()
            // The spawn below may re-settle its zone when auto-layout is on (a
            // spawn authorizes that); pin it off so frames are the close's alone.
            _ = pinPreferences(try fixture.requireMounted("keep").canvas, autoLayout: false)
            try closeZone(fixture, Fixture.zoneA1, choice: .alertFirstButtonReturn)
            var m = try fixture.requireMounted("keep")
            try expect(!m.runtime.document.zones.contains(where: { $0.zoneId == Fixture.zoneA1 }),
                       "keep: the closed zone must leave the document")
            try expect(!m.canvas.qaInstalledLayerZoneIds.contains(Fixture.zoneA1),
                       "keep: the closed zone's layer must go with it; an orphan layer is what creation "
                       + "stayed armed on")
            var placed = worldFrames(m, a1Members)
            for id in a1Members {
                try expect(placed[id]?.zone == Fixture.zoneA3,
                           "keep: THE reported bug. Kept tile \(id) must belong to the project's remaining zone A3; "
                           + "it is in \(String(describing: placed[id]?.zone))")
                try expect(placed[id]?.frame == Fixture.seed.tiles[id],
                           "keep: kept tile \(id) must not move; \(String(describing: placed[id]?.frame)) vs \(Fixture.seed.tiles[id]!)")
            }
            // Z2: nothing may be created in the closed zone.
            try expect(m.canvas.armedZoneId != Fixture.zoneA1 && m.runtime.qaArmedZoneId != Fixture.zoneA1,
                       "keep: Z2. Creation stays armed on the closed zone (canvas \(String(describing: m.canvas.armedZoneId)), "
                       + "document \(String(describing: m.runtime.qaArmedZoneId)))")
            let before = Set(m.canvas.allWorkspaceTiles().map(\.id))
            _ = m.delegate.qaPerformPaletteAction(.newNote)
            let spawned = Set(m.canvas.allWorkspaceTiles().map(\.id)).subtracting(before)
            guard spawned.count == 1, let note = spawned.first else {
                throw Failure(message: "keep: ⌘K New Note after the close must create one tile; got \(spawned.count)")
            }
            let noteZones = m.canvas.installedZoneIds(containing: note)
            try expect(noteZones.count == 1 && noteZones.allSatisfy { id in
                m.runtime.document.zones.contains(where: { $0.zoneId == id }) },
                       "keep: a tile created after the close must land in a zone that exists; got \(noteZones)")
            try fixture.remount(crash: false)
            m = try fixture.requireMounted("keep remount")
            placed = worldFrames(m, a1Members)
            for id in a1Members {
                try expect(placed[id]?.zone == Fixture.zoneA3 && placed[id]?.frame == Fixture.seed.tiles[id],
                           "keep: after a remount kept tile \(id) must still be in A3 at its frame; got \(String(describing: placed[id]))")
            }
            let disk = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles ?? []
            try expect(!disk.contains(where: { $0.zoneId == Fixture.zoneA1 }),
                       "keep: no tile in canvas.json may still name the closed zone")
            manifest["keep"] = "moved to sibling zone"
        }

        // 2. Keep on a project's ONLY zone: a fresh zone for that project takes
        //    the members, unmoved.
        do {
            let fixture = try Fixture(label: "close-keep-last")
            defer { fixture.dispose() }
            try fixture.mount()
            try closeZone(fixture, Fixture.zoneA2, choice: .alertFirstButtonReturn)
            try fixture.remount(crash: false)
            let m = try fixture.requireMounted("keep-last remount")
            let placed = worldFrames(m, [Fixture.noteA2a])
            guard let home = placed[Fixture.noteA2a] else {
                throw Failure(message: "keep-last: the kept tile is hidden after a remount")
            }
            try expect(home.zone != Fixture.zoneA2
                       && m.runtime.document.zones.first(where: { $0.zoneId == home.zone })?.projectId == Fixture.projectA2,
                       "keep-last: the kept tile must live in a zone of its own project")
            try expect(home.frame == Fixture.seed.tiles[Fixture.noteA2a], "keep-last: the kept tile must not move")
            manifest["keepLast"] = "fresh zone"
        }

        // 3. Delete Tiles on a project zone deletes them: gone from the scene,
        //    from canvas.json and from the notes store, for good.
        do {
            let fixture = try Fixture(label: "close-delete")
            defer { fixture.dispose() }
            try fixture.mount()
            // Another project's zone is armed, as after "Close Zone…" from A1's menu.
            try fixture.armByClick(Fixture.zoneA2)
            try closeZone(fixture, Fixture.zoneA1, choice: .alertSecondButtonReturn, armFirst: false)
            var m = try fixture.requireMounted("delete")
            for id in a1Members {
                try expect(m.canvas.tileRecord(for: id) == nil,
                           "delete: W5. \"Delete Tiles\" on a project zone must delete tile \(id)")
            }
            try fixture.remount(crash: false)
            m = try fixture.requireMounted("delete remount")
            let disk = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles.map(\.id) ?? []
            for id in a1Members {
                try expect(!disk.contains(id), "delete: deleted tile \(id) is still in canvas.json")
            }
            try expect(disk.contains(Fixture.noteA3a) && m.canvas.tileRecord(for: Fixture.noteA3a) != nil,
                       "delete: the project's other zone keeps its tile")
            let store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
            try expect(((try? store.tryLoadNoteState()) ?? nil)?.tiles.contains(where: { $0.tileId == Fixture.noteA1a }) != true,
                       "delete: the deleted note's index row must go")
            manifest["delete"] = "deleted"
        }

        // 4. Z5: Delete Tiles on a project's LAST zone lets the project go: no
        //    controller held, and no workspace claiming it, so it can be added
        //    anywhere again.
        do {
            let fixture = try Fixture(label: "close-last")
            defer { fixture.dispose() }
            try fixture.mount()
            try closeZone(fixture, Fixture.zoneA2, choice: .alertSecondButtonReturn)
            let m = try fixture.requireMounted("close-last")
            try expect(m.runtime.controller(for: Fixture.projectA2) == nil,
                       "close-last: Z5. The project's controller (and its .array/lock) is still held")
            let registry = try fixture.registryStore.loadOrEmpty()
            let owner = try registry.exclusiveWorkspaceOwner(of: Fixture.projectA2)
            try expect(owner == nil,
                       "close-last: Z5. The project is still owned by the workspace it has no zone in, so adding "
                       + "it elsewhere asks to switch to a workspace that cannot show it")
            manifest["closeLast"] = "released"
        }
        // 5. Z6: Keep on a legacy GROUP zone. Its members used to become
        //    zone-less ambient tiles, which no mount renders: gone after a
        //    relaunch. The zone must stay, with its tile, across a remount.
        do {
            let fixture = try Fixture(label: "close-group")
            defer { fixture.dispose() }
            let group = UUID(uuidString: "00000000-0000-0000-0000-0000000067C1")!
            let member = UUID(uuidString: "00000000-0000-0000-0000-00000067C101")!
            let store = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
            var document = try store.load()
            document.zones.append(ZonePlacement(
                zoneId: group, projectId: nil, origin: ZonePoint(x: 600, y: 1400), size: ZoneSize(width: 700, height: 400),
                color: "gray", collapsed: false, hydrationPolicy: .automatic, name: "Group"))
            var tile = Tile(id: member, kind: .note, title: "grouped", frame: TileFrame(x: 650, y: 1480, width: 240, height: 160),
                            zPosition: .fromLegacyRank(80), runtimeRef: nil, metadata: TileMetadata(noteId: member))
            tile.zoneId = group
            document.ambientTiles.append(tile)
            try store.save(document)
            try fixture.mount()
            try closeZone(fixture, group, choice: .alertFirstButtonReturn, armFirst: false)
            try fixture.remount(crash: false)
            let m = try fixture.requireMounted("close-group remount")
            let kept = m.canvas.tilesInWorldFrames(forZoneId: group)?.first(where: { $0.id == member })
            try expect(kept?.frame == tile.frame,
                       "close-group: Z6. The kept group tile vanished after a remount; it is \(String(describing: kept))")
            manifest["closeGroup"] = "kept"
        }
        return try writeArtifact("zone-close-strand", manifest)
    }

    // MARK: - --stranded-tile-recovery-check

    /// G (prod state, 2026-10-11): of 49 real tiles only 3 sat in a zone of a
    /// registered document. Harmony's tiles were stamped with a zone only an
    /// unregistered orphan document held; selectus's with a zone no document
    /// held; the mount deferred them all as "another workspace's" and showed an
    /// empty zone. Shapes copied from that report, never its files.
    ///
    /// The rule (`.plans/67` §4): preserve, classify, offer. The mount must not
    /// move or restamp them; it must say how many are hidden and offer Recover;
    /// Recover must bring every one back into a zone of its own project with its
    /// relative layout exact, overlapping no zone, and it must survive a remount.
    static func runStrandedTileRecovery() throws -> URL {
        let fixture = try Fixture(label: "stranded")
        defer { fixture.dispose() }
        let orphanWorkspace = UUID(uuidString: "00000000-0000-0000-0000-0000000067E0")!
        let orphanZone = UUID(uuidString: "00000000-0000-0000-0000-0000000067E1")!
        let deadZone = UUID(uuidString: "00000000-0000-0000-0000-0000000067E2")!
        // Harmony-shaped: stamped with an orphan document's zone, laid out right
        // on top of zone A1, so recovery must translate them as a group.
        let harmonyShaped: [(UUID, TileFrame)] = [
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E101")!, TileFrame(x: 700, y: 300, width: 300, height: 200)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E102")!, TileFrame(x: 1020, y: 300, width: 240, height: 160)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E103")!, TileFrame(x: 700, y: 520, width: 560, height: 260)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E104")!, TileFrame(x: 1280, y: 640, width: 240, height: 160)),
        ]
        // Selectus-shaped: stamped with a zone no document holds, far from the
        // project's live zone and overlapping nothing, so they stay put.
        let selectusShaped: [(UUID, TileFrame)] = [
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E201")!, TileFrame(x: 3600, y: 2200, width: 240, height: 160)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E202")!, TileFrame(x: 3860, y: 2200, width: 240, height: 160)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E203")!, TileFrame(x: 3600, y: 2380, width: 500, height: 200)),
        ]
        // Negative control: a stamp naming ANOTHER REGISTERED workspace's zone is
        // that workspace's business, never offered and never moved.
        let otherWorkspaceTile = UUID(uuidString: "00000000-0000-0000-0000-00000067E301")!

        func append(_ project: UUID, _ rows: [(UUID, TileFrame)], zone: UUID) throws {
            let store = ProjectStore(projectRoot: fixture.projectRoots[project]!)
            var canvas = try store.loadCanvas()
            for (index, row) in rows.enumerated() {
                var tile = Tile(id: row.0, kind: .note, title: "stranded \(index)", frame: row.1,
                                zPosition: .fromLegacyRank(40 + index), runtimeRef: nil,
                                metadata: TileMetadata(noteId: row.0))
                tile.zoneId = zone
                canvas.tiles.append(tile)
                try store.saveNoteBody(id: row.0, text: "stranded \(index)")
            }
            try store.saveCanvas(canvas)
        }
        try append(Fixture.projectA1, harmonyShaped, zone: orphanZone)
        try append(Fixture.projectA2, selectusShaped, zone: deadZone)
        try append(Fixture.projectA1, [(otherWorkspaceTile, TileFrame(x: 500, y: 2600, width: 240, height: 160))],
                   zone: Fixture.zoneB1)
        try WorkspaceStore(workspaceId: orphanWorkspace, applicationSupportDirectory: fixture.appSupport).save(
            WorkspaceDocument(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                zones: [ZonePlacement(zoneId: orphanZone, projectId: Fixture.projectB1,
                                      origin: ZonePoint(x: 600, y: 200), size: ZoneSize(width: 1000, height: 700),
                                      color: "mint", collapsed: false, hydrationPolicy: .automatic, name: "peronsal")],
                zoneZOrder: [orphanZone], lastActiveZoneId: orphanZone))
        // Copies (G: harmony's file holds 18 of personal's tiles, same ids and
        // frames). Cedar (B1) owns three notes, bodies and all; Alder (A1) holds
        // copies of them. And an agent tile in Alder whose session lives in
        // Cedar's `.array/`. Recovering any of these into Alder would show one
        // tile, or one agent, twice: they must be left alone and said so.
        let personalShaped: [(UUID, TileFrame)] = [
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E401")!, TileFrame(x: 5200, y: 300, width: 240, height: 160)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E402")!, TileFrame(x: 5460, y: 300, width: 240, height: 160)),
            (UUID(uuidString: "00000000-0000-0000-0000-00000067E403")!, TileFrame(x: 5200, y: 480, width: 500, height: 200)),
        ]
        try append(Fixture.projectB1, personalShaped, zone: orphanZone)   // owner, with note bodies
        do {
            let store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
            var canvas = try store.loadCanvas()
            for (index, row) in personalShaped.enumerated() {
                var copy = Tile(id: row.0, kind: .note, title: "stranded \(index)", frame: row.1,
                                zPosition: .fromLegacyRank(60 + index), runtimeRef: nil,
                                metadata: TileMetadata(noteId: row.0))
                copy.zoneId = orphanZone
                canvas.tiles.append(copy)
            }
            let agentTile = UUID(uuidString: "00000000-0000-0000-0000-00000067E501")!
            var agent = Tile(id: agentTile, kind: .managedAgent, title: "agent", frame: TileFrame(x: 5200, y: 800, width: 480, height: 360),
                             zPosition: .fromLegacyRank(70), runtimeRef: nil, metadata: TileMetadata())
            agent.zoneId = deadZone
            canvas.tiles.append(agent)
            try store.saveCanvas(canvas)
            try ManagedAgentSessionStore(projectRoot: fixture.projectRoots[Fixture.projectB1]!).upsert(
                ManagedAgentSessionRecord(tileId: agentTile, agentKind: .shell, status: .running,
                                          lastSeenAt: Date(timeIntervalSince1970: 1_900_000_000)))
        }
        let leftAloneIds = personalShaped.map(\.0) + [UUID(uuidString: "00000000-0000-0000-0000-00000067E501")!]
        let strandedIds = (harmonyShaped + selectusShaped).map(\.0)
        let owner = Dictionary(uniqueKeysWithValues:
            harmonyShaped.map { ($0.0, Fixture.projectA1) } + selectusShaped.map { ($0.0, Fixture.projectA2) })
        let originalCanvasA1 = try ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!).loadCanvas()
        let originalCanvasA2 = try ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA2]!).loadCanvas()

        try fixture.mount()
        var m = try fixture.requireMounted("stranded")
        let offer = m.delegate.qaWorkspaceManagementMessage ?? ""
        try expect(offer.contains("7 tiles are hidden"),
                   "classify: THE reported state. 7 tiles sit in zones no registered document holds and the user "
                   + "is not told; the notification reads \(offer.isEmpty ? "nothing" : offer)")
        try expect(offer.contains("4 copies of tiles in \u{201C}Cedar\u{201D} are left alone"),
                   "classify: copies of another project's tiles, and an agent tile whose session is another "
                   + "project's, must be left alone and said so; the notification reads \(offer)")
        var duplicateOffers = 0
        let deliverOffer = m.runtime.onStrandedTilesFound
        m.runtime.onStrandedTilesFound = { recoverable, leftAlone in
            duplicateOffers += 1
            deliverOffer?(recoverable, leftAlone)
        }
        m.runtime.classifyStrandedTiles()
        try expect(duplicateOffers == 0 && m.delegate.qaWorkspaceManagementMessage == offer,
                   "classify: mounting the same stranded content again must not replace or repeat its notification")
        for id in strandedIds + [otherWorkspaceTile] {
            try expect(m.canvas.tileRecord(for: id) == nil, "classify: tile \(id) must not be placed before the user accepts")
        }
        // Preserve: the mount moved and restamped nothing.
        func disk(_ project: UUID) -> [UUID: Tile] {
            Dictionary(uniqueKeysWithValues: (fixture.readProjectFile(project).canvas?.tiles ?? []).map { ($0.id, $0) })
        }
        for (id, frame) in harmonyShaped {
            try expect(disk(Fixture.projectA1)[id]?.zoneId == orphanZone && disk(Fixture.projectA1)[id]?.frame == frame,
                       "preserve: the mount must not repair stranded tile \(id) silently")
        }

        guard m.delegate.qaPerformWorkspaceNotificationAction() == "Recover" else {
            throw Failure(message: "offer: the notification must offer Recover")
        }
        m.canvas.layoutSubtreeIfNeeded()

        func placedFrames(_ m: Fixture.Mounted) throws -> [UUID: (zone: ZonePlacement, frame: TileFrame)] {
            var out: [UUID: (zone: ZonePlacement, frame: TileFrame)] = [:]
            for id in strandedIds {
                let zones = m.canvas.installedZoneIds(containing: id)
                guard zones.count == 1, let zone = m.runtime.document.zones.first(where: { $0.zoneId == zones[0] }),
                      let frame = m.canvas.tilesInWorldFrames(forZoneId: zone.zoneId)?.first(where: { $0.id == id })?.frame
                else {
                    throw Failure(message: "recover: tile \(id) is not in exactly one zone of the document; zones "
                                  + "\(zones); the notification reads \(m.delegate.qaWorkspaceManagementMessage ?? "nothing")")
                }
                out[id] = (zone, frame)
            }
            return out
        }
        let placed = try placedFrames(m)
        for (id, home) in placed {
            try expect(home.zone.projectId == owner[id], "recover: tile \(id) must live in a zone of its own project")
            try expect(contains(home.zone, home.frame), "recover: tile \(id) must sit inside its new zone")
        }
        // Relative layout exact, per project group.
        for group in [harmonyShaped, selectusShaped] {
            let dx = placed[group[0].0]!.frame.x - group[0].1.x
            let dy = placed[group[0].0]!.frame.y - group[0].1.y
            for (id, original) in group {
                let got = placed[id]!.frame
                try expect(got.x - original.x == dx && got.y - original.y == dy
                           && got.width == original.width && got.height == original.height,
                           "recover: tile \(id) lost its place in its group: \(got) vs \(original) shifted by (\(dx), \(dy))")
            }
        }
        try expect(placed[selectusShaped[0].0]!.frame == selectusShaped[0].1,
                   "recover: a group that overlaps nothing is recovered where it already is")
        // No recovered zone overlaps another zone.
        let zones = m.runtime.document.zones
        for zone in Set(placed.values.map(\.zone.zoneId)) {
            guard let a = zones.first(where: { $0.zoneId == zone }) else { continue }
            let ra = CanvasEngine.zoneWorldFrame(a)
            for b in zones where b.zoneId != zone {
                let rb = CanvasEngine.zoneWorldFrame(b)
                let overlap = ra.x < rb.x + rb.width && rb.x < ra.x + ra.width && ra.y < rb.y + rb.height && rb.y < ra.y + ra.height
                try expect(!overlap, "recover: recovered zone \(zone) overlaps zone \(b.zoneId)")
            }
        }
        try expect(m.canvas.tileRecord(for: otherWorkspaceTile) == nil
                   && disk(Fixture.projectA1)[otherWorkspaceTile]?.zoneId == Fixture.zoneB1,
                   "recover: a tile of another registered workspace's zone must be left alone")
        for id in leftAloneIds {
            try expect(m.canvas.tileRecord(for: id) == nil,
                       "recover: THE duplicate hazard. Copy \(id) was recovered, so one tile (or agent) now shows twice")
            try expect(disk(Fixture.projectA1)[id]?.zoneId != nil
                       && m.runtime.document.zones.allSatisfy { $0.zoneId != disk(Fixture.projectA1)[id]?.zoneId },
                       "recover: copy \(id) must stay untouched on disk")
        }

        // A genuinely resolved interval clears the prior content fingerprint.
        // Reintroducing the same durable fixture within this SAME runtime must
        // raise a fresh offer; a lifetime Set of every fingerprint would suppress
        // this recurrence forever.
        let projectA1Store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        let projectA2Store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA2]!)
        // Keep the successfully recovered disk state so the recurrence fixture
        // can be restored before the remount durability assertions below.
        let recoveredCanvasA1 = try projectA1Store.loadCanvas()
        let recoveredCanvasA2 = try projectA2Store.loadCanvas()
        let leftAloneSet = Set(leftAloneIds)
        var canvasWithoutCopies = try projectA1Store.loadCanvas()
        canvasWithoutCopies.tiles.removeAll { leftAloneSet.contains($0.id) }
        try projectA1Store.saveCanvas(canvasWithoutCopies)
        m.runtime.classifyStrandedTiles()
        try expect(m.runtime.strandedTiles.isEmpty && m.runtime.strandedLeftAlone.isEmpty,
                   "resolve: removing the duplicate records should leave no stranded content")
        let offersBeforeRecurrence = duplicateOffers
        try projectA1Store.saveCanvas(originalCanvasA1)
        try projectA2Store.saveCanvas(originalCanvasA2)
        m.runtime.classifyStrandedTiles()
        try expect(duplicateOffers == offersBeforeRecurrence + 1,
                   "recur: the same stranded-content fingerprint must be offered again after a resolved interval")
        try expect((m.delegate.qaWorkspaceManagementMessage ?? "").contains("7 tiles are hidden"),
                   "recur: the repeated incident must restore its actionable recovery notice")

        // The recurrence probe above deliberately rewrites the durable fixtures
        // to their pre-recovery bytes. Restore the recovered snapshots so the
        // following remount checks the actual recovery output, including the
        // WORLD frame of tile 67E202, rather than the adversarial recurrence data.
        try projectA1Store.saveCanvas(recoveredCanvasA1)
        try projectA2Store.saveCanvas(recoveredCanvasA2)

        try fixture.remount(crash: false)
        m = try fixture.requireMounted("stranded remount")
        // Durable: the stamps and WORLD frames on disk, and the zones in the
        // document. A recovered zone off-screen is below the live tier after a
        // remount and has no layer until reached, so it is reached here.
        for (id, home) in placed {
            let persisted = disk(owner[id]!)[id]
            try expect(persisted?.zoneId == home.zone.zoneId && persisted?.frame == home.frame,
                       "remount: canvas.json must hold recovered tile \(id) in its new zone at its WORLD frame")
            try expect(m.runtime.document.zones.contains(where: { $0.zoneId == home.zone.zoneId }),
                       "remount: the recovered zone must be in the workspace document")
        }
        for zone in Set(placed.values.map(\.zone.zoneId)) { m.runtime.ensureZoneLayer(forZone: zone) }
        let after = try placedFrames(m)
        for (id, home) in placed {
            try expect(after[id]?.zone.zoneId == home.zone.zoneId && after[id]?.frame == home.frame,
                       "remount: recovered tile \(id) must come back in the same zone at the same WORLD frame")
        }
        let again = m.delegate.qaWorkspaceManagementMessage ?? ""
        try expect(!again.contains("hidden"), "remount: nothing is hidden any more; the notification reads \(again)")
        return try writeArtifact("stranded-tile-recovery", [
            "recovered": strandedIds.count,
            "harmonyShift": placed[harmonyShaped[0].0]!.frame.x - harmonyShaped[0].1.x,
        ])
    }

    // MARK: - --layout-commit-truth-check

    /// F1 10.2 / `.plans/67` §2 row 5: the layout commit skipped every tile it
    /// could not place in a file (an unregistered project, a missing canvas) and
    /// still reported success, so a move looked saved and came back undone on
    /// the next launch. It must now fail, roll the move back and say so.
    static func runLayoutCommitTruth() throws -> URL {
        let fixture = try Fixture(label: "layout-truth")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("layout-truth")
        _ = pinPreferences(m.canvas, autoLayout: false)
        let tile = Fixture.noteA2a
        let seeded = Fixture.seed.tiles[tile]!
        let moved = TileFrame(x: seeded.x + 40, y: seeded.y + 30, width: seeded.width, height: seeded.height)

        // Positive control: with its store present the same move commits.
        let control = m.canvas.applyProgrammaticTileGeometry(
            tileId: tile, in: Fixture.zoneA2, worldFrame: moved, action: .moveTile)
        try expect(control == .committed(undoRecorded: true) || control == .committed(undoRecorded: false),
                   "control: a move with its store present must commit; got \(control)")
        try expect(fixture.readProjectFile(Fixture.projectA2).canvas?.tiles.first(where: { $0.id == tile })?.frame == moved,
                   "control: the committed move must be on disk")

        // The project's canvas goes missing while it is mounted, backups and all
        // (a backup alone would be read in its place and written back).
        let layout = ProjectStoreLayout(projectRoot: fixture.projectRoots[Fixture.projectA2]!)
        try FileManager.default.removeItem(at: layout.canvasFile)
        try? FileManager.default.removeItem(at: layout.backupsDirectory)
        let outcome = m.canvas.applyProgrammaticTileGeometry(
            tileId: tile, in: Fixture.zoneA2, worldFrame: seeded, action: .moveTile)
        try expect(outcome == .persistenceFailed,
                   "THE reported bug. A move whose tile is in no saved canvas reported \(outcome); it was never "
                   + "written anywhere")
        let shown = m.canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA2)?.first(where: { $0.id == tile })?.frame
        try expect(shown == moved, "the failed move must be rolled back on screen; tile is at \(String(describing: shown))")
        let message = m.delegate.qaWorkspaceManagementMessage ?? ""
        try expect(message.contains("couldn't be saved"), "the failure must be shown; the notification reads \(message)")
        return try writeArtifact("layout-commit-truth", ["outcome": "\(outcome)"])
    }

    // MARK: - --refused-spawn-teardown-check

    /// A spawn that cannot be placed or persisted must leave nothing behind. A
    /// refused browser spawn kept its WKWebView process alive with nothing to
    /// reach it, and a spawn whose canvas write failed left its tile drawn with
    /// no record on disk: it vanished on the next launch, its runtime with it.
    static func runRefusedSpawnTeardown() throws -> URL {
        // A. Refused outright: the armed zone's project is unavailable, so no
        //    layer exists to install into.
        do {
            let fixture = try Fixture(label: "refused-spawn")
            defer { fixture.dispose() }
            let layout = ProjectStoreLayout(projectRoot: fixture.projectRoots[Fixture.projectA2]!)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.canvasFile)) as! [String: Any]
            var tiles = json["tiles"] as! [[String: Any]]
            tiles[0]["kind"] = "futureKind"
            json["tiles"] = tiles
            try JSONSerialization.data(withJSONObject: json).write(to: layout.canvasFile)
            try? FileManager.default.removeItem(at: layout.backupsDirectory)
            try fixture.mount()
            let m = try fixture.requireMounted("refused-spawn")
            try fixture.armByClick(Fixture.zoneA2)
            let before = Set(m.canvas.allWorkspaceTiles().map(\.id))
            let live = WKWebViewBrowserRuntime.qaUnterminatedCount
            _ = m.delegate.qaPerformPaletteAction(.newBrowser)
            try expect(Set(m.canvas.allWorkspaceTiles().map(\.id)) == before,
                       "refused: a refused browser spawn must not add a tile")
            try expect(WKWebViewBrowserRuntime.qaUnterminatedCount == live,
                       "refused: a refused browser spawn leaked its web view runtime "
                       + "(\(WKWebViewBrowserRuntime.qaUnterminatedCount - live) left running)")
        }
        // B. Installed, then the canvas write failed.
        do {
            let fixture = try Fixture(label: "failed-spawn")
            defer { fixture.dispose() }
            try fixture.mount()
            let m = try fixture.requireMounted("failed-spawn")
            try fixture.armByClick(Fixture.zoneA1)
            fixture.drain()
            let root = fixture.projectRoots[Fixture.projectA1]!
            let store = ProjectStore(projectRoot: root)
            let browserRowsBefore = ((try? store.tryLoadBrowserState()) ?? nil)?.tiles.count ?? 0
            let before = Set(m.canvas.allWorkspaceTiles().map(\.id))
            let live = WKWebViewBrowserRuntime.qaUnterminatedCount
            // Write 1 is the browser-state row, write 2 the canvas.
            StoreFileWriter.install(.init(fault: .failWrite(2), scope: root))
            _ = m.delegate.qaPerformPaletteAction(.newBrowser)
            StoreFileWriter.uninstall()
            let added = Set(m.canvas.allWorkspaceTiles().map(\.id)).subtracting(before)
            try expect(added.isEmpty,
                       "failed: THE ghost. A spawn whose canvas write failed left tile(s) \(added) on the canvas "
                       + "with no record on disk")
            try expect(WKWebViewBrowserRuntime.qaUnterminatedCount == live,
                       "failed: the failed browser spawn leaked its web view runtime")
            let browserRowsAfter = ((try? store.tryLoadBrowserState()) ?? nil)?.tiles.count ?? 0
            try expect(browserRowsAfter == browserRowsBefore,
                       "failed: the failed spawn left a browser-state row for a tile that does not exist")
        }
        return try writeArtifact("refused-spawn-teardown", ["ok": true])
    }
}
