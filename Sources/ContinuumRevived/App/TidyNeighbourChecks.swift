import AppKit
import ContinuumRevivedCore
import ObjectiveC

/// Tidy against neighbouring zones (`.plans/auto-layout-night`). The packer can
/// GROW a zone (height first, then width) and shrink an oversized one; what it
/// grows into must move clear, and nothing it leaves may be pulled in.
///
/// Through production: the zone header's own context menu ("Tidy Zone Now", its
/// real action) for one zone, and the palette's Tidy Canvas for all of them, on a
/// mounted workspace. Each zone is its own project, so every commit goes through
/// the scoped save, and the WORLD frames on disk are asserted too.
@MainActor
enum TidyNeighbourChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    typealias Fixture = WorkspaceInvariantsFixture

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static var failures: [String] = []
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    static func run() throws {
        failures = []
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = saved
        // Every zone of the scene live, so each has tiles to tidy.
        arguments[ZoneHydrationBudgetConfig.maxLiveZonesKey] = 32
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }

        for autoLayout in [true, false] {
            try growIntoNeighbours(autoLayout: autoLayout)
        }
        try shrinkLeavesNeighbours()
        let first = try tidyCanvasGrid(label: "grid run 1")
        let second = try tidyCanvasGrid(label: "grid run 2")
        check(first == second, "Tidy Canvas is not deterministic: two identical workspaces tidied to different frames")
        bareTilesArePushedNotAdopted()

        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
        print("TidyNeighbourChecks passed: growth pushes neighbours clear, shrink leaves them, Tidy Canvas fills and is a fixed point")
    }

    // MARK: - 1 and 5: a zone grows into its neighbours

    /// Zone G is cramped: four 400x300 notes in a 900x420 zone, so the packer
    /// grows its height. N sits 40pt below it. Zone W holds a browser inspector
    /// (minimum 520 wide) in a 500-wide zone, so the packer must grow its width;
    /// E sits 40pt to its right.
    private static func growIntoNeighbours(autoLayout: Bool) throws {
        let mode = "autoLayout=\(autoLayout)"
        let scene = try Scene(seed: 1)
        let g = scene.zone("G", CGRect(x: 6000, y: 0, width: 900, height: 420),
                           notes: (0..<4).map { CGRect(x: 6024 + Double($0 % 2) * 420, y: 58 + Double($0 / 2) * 170, width: 400, height: 300) })
        let n = scene.zone("N", CGRect(x: 6000, y: 460, width: 900, height: 500),
                           notes: [CGRect(x: 6024, y: 518, width: 300, height: 200), CGRect(x: 6340, y: 518, width: 300, height: 200)])
        let w = scene.zone("W", CGRect(x: 8000, y: 0, width: 500, height: 600),
                           notes: [], inspectors: [CGRect(x: 8024, y: 58, width: 452, height: 400)])
        let e = scene.zone("E", CGRect(x: 8540, y: 0, width: 600, height: 600),
                           notes: [CGRect(x: 8564, y: 58, width: 300, height: 200)])
        let host = try scene.mount(autoLayout: autoLayout, label: mode)
        defer { host.close() }

        for (grower, neighbour, axis) in [(g, n, "height"), (w, e, "width")] {
            let before = host.snapshot()
            try host.tidyFromZoneMenu(grower.zoneId)
            let after = host.snapshot()
            let label = "\(mode) tidy \(grower.name)"
            let grew = axis == "height"
                ? after.zones[grower.zoneId]!.height > before.zones[grower.zoneId]!.height + 1
                : after.zones[grower.zoneId]!.width > before.zones[grower.zoneId]!.width + 1
            check(grew, "\(label): precondition: the cramped zone must grow in \(axis); \(before.zones[grower.zoneId]!) -> \(after.zones[grower.zoneId]!)")
            host.expectNoZoneOverlaps(after, label)
            host.expectRigid(neighbour, before: before, after: after, label)
            host.expectMembershipUnchanged(before: before, after: after, label)
            host.expectOnDisk(after, label)
        }
    }

    // MARK: - 3: a zone that shrinks leaves its neighbours

    private static func shrinkLeavesNeighbours() throws {
        let scene = try Scene(seed: 2)
        let s = scene.zone("S", CGRect(x: 6000, y: 0, width: 2400, height: 1600),
                           notes: [CGRect(x: 6024, y: 58, width: 240, height: 160)])
        let right = scene.zone("R", CGRect(x: 8440, y: 0, width: 600, height: 600),
                               notes: [CGRect(x: 8464, y: 58, width: 300, height: 200)])
        let below = scene.zone("B", CGRect(x: 6000, y: 1640, width: 600, height: 600),
                               notes: [CGRect(x: 6024, y: 1698, width: 300, height: 200)])
        let host = try scene.mount(autoLayout: true, label: "shrink")
        defer { host.close() }
        let before = host.snapshot()
        try host.tidyFromZoneMenu(s.zoneId)
        let after = host.snapshot()
        check(after.zones[s.zoneId]!.width < before.zones[s.zoneId]!.width - 1
              || after.zones[s.zoneId]!.height < before.zones[s.zoneId]!.height - 1,
              "shrink: precondition: the oversized zone must shrink; \(before.zones[s.zoneId]!) -> \(after.zones[s.zoneId]!)")
        for neighbour in [right, below] {
            check(after.zones[neighbour.zoneId] == before.zones[neighbour.zoneId],
                  "shrink: neighbour \(neighbour.name) moved from \(before.zones[neighbour.zoneId]!) to \(after.zones[neighbour.zoneId]!); tidy must never pull a neighbour in")
            for tile in neighbour.tileIds {
                check(after.tiles[tile]?.frame == before.tiles[tile]?.frame, "shrink: a tile of neighbour \(neighbour.name) moved")
            }
        }
        host.expectNoZoneOverlaps(after, "shrink")
        host.expectOnDisk(after, "shrink")
    }

    // MARK: - 2: Tidy Canvas over a 2x3 grid

    /// Six 1000x400 zones, three columns 100pt apart by two rows 20pt apart: cramped ones
    /// (six 400x300 notes, which must grow) and roomy ones (one note, which
    /// shrink). Returns the result,
    /// keyed by the scene's stable ids, for the determinism comparison.
    private static func tidyCanvasGrid(label: String) throws -> [String: TileFrame] {
        let scene = try Scene(seed: 3)
        var zones: [SceneZone] = []
        for row in 0..<2 {
            for column in 0..<3 {
                let origin = CGPoint(x: 12000 + Double(column) * 1100, y: Double(row) * 420)
                let cramped = (row + column) % 2 == 0
                // Six 400x300 notes in a 1000x400 zone (952x318 of content): it
                // must grow in height, into the row 20pt below it.
                let notes = cramped
                    ? (0..<6).map { CGRect(x: origin.x + 24 + Double($0 % 3) * 310, y: origin.y + 58 + Double($0 / 3) * 20,
                                           width: 400, height: 300) }
                    : [CGRect(x: origin.x + 24, y: origin.y + 58, width: 300, height: 200)]
                zones.append(scene.zone("grid\(row)\(column)", CGRect(origin: origin, size: CGSize(width: 1000, height: 400)), notes: notes))
            }
        }
        let host = try scene.mount(autoLayout: true, label: label)
        defer { host.close() }
        let before = host.snapshot()
        try host.tidyCanvas()
        let after = host.snapshot()
        let grew = zones.filter { (after.zones[$0.zoneId]?.height ?? 0) > (before.zones[$0.zoneId]?.height ?? 0) + 1
            || (after.zones[$0.zoneId]?.width ?? 0) > (before.zones[$0.zoneId]?.width ?? 0) + 1 }.count
        let shrank = zones.filter { (after.zones[$0.zoneId]?.height ?? 0) < (before.zones[$0.zoneId]?.height ?? 0) - 1
            || (after.zones[$0.zoneId]?.width ?? 0) < (before.zones[$0.zoneId]?.width ?? 0) - 1 }.count
        check(grew > 0 && shrank > 0, "\(label) precondition: the grid must both grow and shrink zones; grew \(grew), shrank \(shrank)")
        print("tidy-zone-neighbours: \(label) Tidy Canvas grew \(grew) zone(s), shrank \(shrank)")
        host.expectNoZoneOverlaps(after, "\(label) Tidy Canvas")
        host.expectMembershipUnchanged(before: before, after: after, "\(label) Tidy Canvas")
        for zone in zones {
            host.expectFilled(zone, after, "\(label) Tidy Canvas")
            host.expectNoTileOverlaps(zone, after, "\(label) Tidy Canvas")
        }
        host.expectOnDisk(after, "\(label) Tidy Canvas")
        // A tidy result is its own fixed point.
        try host.tidyCanvas()
        let again = host.snapshot()
        for zone in zones {
            check(again.zones[zone.zoneId] == after.zones[zone.zoneId],
                  "\(label): a second Tidy Canvas moved zone \(zone.name): \(after.zones[zone.zoneId]!) -> \(again.zones[zone.zoneId]!)")
            for tile in zone.tileIds where again.tiles[tile]?.frame != after.tiles[tile]?.frame {
                check(false, "\(label): a second Tidy Canvas moved a tile of \(zone.name)")
            }
        }
        var keyed: [String: TileFrame] = [:]
        for zone in zones {
            keyed["zone \(zone.name)"] = after.zones[zone.zoneId]
            for (index, tile) in zone.tileIds.enumerated() { keyed["\(zone.name) tile \(index)"] = after.tiles[tile]?.frame }
        }
        return keyed
    }

    // MARK: - 4: bare tiles

    /// Bare project tiles exist only on array/bare-tiles; on this branch the
    /// engine still owns the rule, so it is asserted there: a grown zone pushes a
    /// bare tile clear and never adopts it.
    private static func bareTilesArePushedNotAdopted() {
        let zoneId = UUID(), bareId = UUID(), memberId = UUID()
        let before = ZonePlacement(zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                                   size: ZoneSize(width: 600, height: 400), color: "blue", collapsed: false,
                                   hydrationPolicy: .automatic)
        var grown = before
        grown.size.height = 900
        let scene = CanvasAutoLayoutEngine.Scene(
            tiles: [
                .init(id: memberId, frame: TileFrame(x: 24, y: 58, width: 300, height: 800), zoneId: zoneId,
                      minimumSize: CGSize(width: 240, height: 160)),
                .init(id: bareId, frame: TileFrame(x: 100, y: 500, width: 240, height: 160), zoneId: nil,
                      minimumSize: CGSize(width: 240, height: 160)),
            ],
            zones: [grown], globalEnabled: true)
        let push = CanvasAutoLayoutEngine.pushPeers(ofGrownZone: zoneId, from: before, scene: scene, gap: 8)
        let moved = push.tileFrames[bareId]
        check(moved.map { $0.y >= 900 + 8 - 0.001 } == true,
              "bare: a zone grown over a bare tile must push it clear below; got \(String(describing: moved))")
        check(push.tileZoneIds[bareId] == nil, "bare: a pushed bare tile must never be adopted")
        check(push.tileFrames[memberId] == nil, "bare: the grown zone's own member must not move")
    }

    // MARK: - Fixture

    struct SceneZone {
        let name: String
        let projectId: UUID
        let zoneId: UUID
        let tileIds: [UUID]
        let root: URL
    }

    struct Snapshot {
        var zones: [UUID: TileFrame]
        var tiles: [UUID: (frame: TileFrame, zone: UUID?)]
    }

    /// Zones each in their own project, owned by workspace A, far right of the
    /// fixture's seeded zones. Ids derive from the seed and the order of calls,
    /// so two scenes built the same way are identical.
    @MainActor
    final class Scene {
        let fixture: Fixture
        private(set) var zones: [SceneZone] = []
        private var counter = 0
        private let seed: Int
        private var pending: [(SceneZone, CGRect, [Tile])] = []

        init(seed: Int) throws {
            self.seed = seed
            fixture = try Fixture(label: "tidy-neighbours-\(seed)")
        }

        private func nextId() -> UUID {
            counter += 1
            return UUID(uuidString: String(format: "7D0E0000-0000-4000-8000-%04d%08d", seed, counter))!
        }

        @discardableResult
        func zone(_ name: String, _ rect: CGRect, notes: [CGRect], inspectors: [CGRect] = []) -> SceneZone {
            let projectId = nextId(), zoneId = nextId()
            let root = fixture.root.appendingPathComponent("zone-\(name)", isDirectory: true)
            var tiles: [Tile] = []
            for frame in notes {
                let id = nextId()
                var tile = Tile(id: id, kind: .note, title: name,
                                frame: TileFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                                zPosition: .fromLegacyRank(tiles.count + 1), runtimeRef: nil, metadata: TileMetadata(noteId: id))
                tile.zoneId = zoneId
                tiles.append(tile)
            }
            for frame in inspectors {
                var tile = Tile(id: nextId(), kind: .browserInspector, title: name,
                                frame: TileFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                                zPosition: .fromLegacyRank(tiles.count + 1), runtimeRef: nil, metadata: TileMetadata())
                tile.zoneId = zoneId
                tiles.append(tile)
            }
            let zone = SceneZone(name: name, projectId: projectId, zoneId: zoneId, tileIds: tiles.map(\.id), root: root)
            zones.append(zone)
            pending.append((zone, rect, tiles))
            return zone
        }

        func mount(autoLayout: Bool, label: String) throws -> Host {
            let now = Date(timeIntervalSince1970: 1_900_000_000)
            var registry = try fixture.registryStore.loadOrEmpty()
            let workspaceStore = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
            var document = try workspaceStore.load()
            for (zone, rect, tiles) in pending {
                try FileManager.default.createDirectory(at: zone.root, withIntermediateDirectories: true)
                let store = ProjectStore(projectRoot: zone.root)
                try store.saveProject(Project(
                    id: zone.projectId, name: zone.name, rootPath: zone.root.path, createdAt: now, updatedAt: now,
                    defaultLaunchProfileId: "shell", editorPreference: .auto,
                    settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                              terminalClosePolicy: .askWhenRunning)))
                for tile in tiles where tile.kind == .note { try store.saveNoteBody(id: tile.id, text: "") }
                try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                                 tiles: tiles, groups: [], lastActiveTileId: nil))
                var placement = ZonePlacement(
                    zoneId: zone.zoneId, projectId: zone.projectId,
                    origin: ZonePoint(x: Double(rect.minX), y: Double(rect.minY)),
                    size: ZoneSize(width: Double(rect.width), height: Double(rect.height)),
                    color: "blue", collapsed: false, hydrationPolicy: .automatic, name: zone.name)
                placement.zPosition = FracIndex.after(document.zones.map(\.zPosition).max() ?? .first)
                document.zones.append(placement)
                registry.projects.append(ProjectEntry(
                    id: zone.projectId, name: zone.name, rootPath: zone.root.path, workspaceId: Fixture.workspaceA,
                    lastOpenedAt: now, pinned: false, missing: false))
                if let index = registry.workspaces.firstIndex(where: { $0.id == Fixture.workspaceA }) {
                    registry.workspaces[index].projectIds.append(zone.projectId)
                }
            }
            // The saved camera frames the scene's zones, so the mount's hydration
            // plan makes every one of them live (the live tier follows the camera).
            let union = pending.map(\.1).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -200, dy: -200)
            let zoom = min(2600 / Double(union.width), 1400 / Double(union.height), 1)
            document.viewport = CanvasViewport(x: Double(union.minX), y: Double(union.minY), zoom: zoom)
            try fixture.registryStore.save(registry)
            try workspaceStore.save(document)
            try fixture.mount()
            fixture.drain(0.4)
            return try Host(scene: self, autoLayout: autoLayout, label: label)
        }
    }

    @MainActor
    struct Host {
        let scene: Scene
        let mounted: Fixture.Mounted
        let window: KeyWindow
        let label: String
        var canvas: CanvasNSView { mounted.canvas }

        init(scene: Scene, autoLayout: Bool, label: String) throws {
            self.scene = scene
            self.label = label
            mounted = try scene.fixture.requireMounted("tidy neighbours \(label)")
            TileInsertSlideChecks.pin(mounted.canvas, autoLayout: autoLayout)
            window = KeyWindow(contentRect: mounted.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = mounted.canvas
            window.orderFrontOffscreenForChecks()
            mounted.canvas.layoutSubtreeIfNeeded()
            for zone in scene.zones where mounted.canvas.tiles(inZone: zone.zoneId) == nil {
                TidyNeighbourChecks.check(false, "\(label): precondition: zone \(zone.name) has no live layer")
            }
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            scene.fixture.dispose()
        }

        func snapshot() -> Snapshot {
            var zones: [UUID: TileFrame] = [:]
            for zone in mounted.runtime.document.zones {
                if let live = canvas.zonePlacement(for: zone.zoneId) { zones[zone.zoneId] = CanvasEngine.zoneWorldFrame(live) }
            }
            var tiles: [UUID: (frame: TileFrame, zone: UUID?)] = [:]
            for tile in canvas.allTilesInWorldFrames() { tiles[tile.id] = (tile.frame, canvas.zoneId(containing: tile.id)) }
            return Snapshot(zones: zones, tiles: tiles)
        }

        /// The zone header's own context menu, its "Tidy Zone Now" item, its action.
        func tidyFromZoneMenu(_ zoneId: UUID) throws {
            guard let zone = canvas.zonePlacement(for: zoneId) else { throw Failure(message: "\(label): no zone \(zoneId)") }
            canvas.setViewport(CanvasViewport(x: zone.origin.x - 200, y: zone.origin.y - 200, zoom: 0.5))
            canvas.layoutSubtreeIfNeeded()
            guard let header = canvas.qaZoneHeaderGrabRect(zoneId) else { throw Failure(message: "\(label): zone has no header") }
            let point = canvas.convert(NSPoint(x: header.minX + header.width * 0.35, y: header.midY), to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let item = canvas.menu(for: event)?.items.first(where: { $0.title == "Tidy Zone Now" }),
                  let action = item.action
            else { throw Failure(message: "\(label): the zone header menu has no Tidy Zone Now") }
            NSApp.sendAction(action, to: item.target, from: item)
            canvas.layoutSubtreeIfNeeded()
            scene.fixture.drain(0.4)
        }

        func tidyCanvas() throws {
            guard mounted.delegate.qaPerformPaletteAction(.tidyCanvas) else { throw Failure(message: "\(label): palette refused Tidy Canvas") }
            canvas.layoutSubtreeIfNeeded()
            scene.fixture.drain(0.4)
        }

        func expectNoZoneOverlaps(_ s: Snapshot, _ context: String) {
            let ids = s.zones.keys.sorted { $0.uuidString < $1.uuidString }
            for (i, a) in ids.enumerated() {
                for b in ids.dropFirst(i + 1) {
                    let ra = s.zones[a]!, rb = s.zones[b]!
                    let overlap = ra.x < rb.x + rb.width - 0.01 && rb.x < ra.x + ra.width - 0.01
                        && ra.y < rb.y + rb.height - 0.01 && rb.y < ra.y + ra.height - 0.01
                    TidyNeighbourChecks.check(!overlap, "\(context): zones \(name(a)) \(ra) and \(name(b)) \(rb) overlap")
                }
            }
        }

        func expectRigid(_ zone: SceneZone, before: Snapshot, after: Snapshot, _ context: String) {
            guard let b = before.zones[zone.zoneId], let a = after.zones[zone.zoneId] else {
                TidyNeighbourChecks.check(false, "\(context): neighbour \(zone.name) vanished"); return
            }
            TidyNeighbourChecks.check(abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01,
                  "\(context): neighbour \(zone.name) changed size \(b) -> \(a); it must move as a rigid body")
            let dx = a.x - b.x, dy = a.y - b.y
            for tile in zone.tileIds {
                guard let tb = before.tiles[tile]?.frame, let ta = after.tiles[tile]?.frame else { continue }
                TidyNeighbourChecks.check(abs(ta.x - tb.x - dx) < 0.01 && abs(ta.y - tb.y - dy) < 0.01 && ta.width == tb.width && ta.height == tb.height,
                      "\(context): a tile of neighbour \(zone.name) did not move with its zone (zone by \(dx),\(dy); tile \(tb) -> \(ta))")
            }
        }

        func expectMembershipUnchanged(before: Snapshot, after: Snapshot, _ context: String) {
            for (id, value) in before.tiles {
                TidyNeighbourChecks.check(after.tiles[id]?.zone == value.zone,
                      "\(context): a tile changed zone \(String(describing: value.zone)) -> \(String(describing: after.tiles[id]?.zone))")
            }
        }

        func expectFilled(_ zone: SceneZone, _ s: Snapshot, _ context: String) {
            guard let rect = s.zones[zone.zoneId] else { return }
            let frames = zone.tileIds.compactMap { s.tiles[$0]?.frame }
            guard !frames.isEmpty else { return }
            let padding = ZoneBoundsConfig.padding(defaults: canvas.autoLayoutDefaults)
            let header = Double(ZoneChromeNSView.headerHeight)
            let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
            let maxX = frames.map { $0.x + $0.width }.max()!, maxY = frames.map { $0.y + $0.height }.max()!
            let tolerance = 0.1
            TidyNeighbourChecks.check(abs(minX - (rect.x + padding)) < tolerance && abs(minY - (rect.y + header + padding)) < tolerance
                  && abs(maxX - (rect.x + rect.width - padding)) < tolerance && abs(maxY - (rect.y + rect.height - padding)) < tolerance,
                  "\(context): zone \(zone.name) \(rect) is not filled edge to edge: members span (\(minX), \(minY))-(\(maxX), \(maxY))")
        }

        func expectNoTileOverlaps(_ zone: SceneZone, _ s: Snapshot, _ context: String) {
            let frames = zone.tileIds.compactMap { s.tiles[$0]?.frame }
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) {
                    let overlap = a.x < b.x + b.width - 0.01 && b.x < a.x + a.width - 0.01
                        && a.y < b.y + b.height - 0.01 && b.y < a.y + a.height - 0.01
                    TidyNeighbourChecks.check(!overlap, "\(context): two tiles of \(zone.name) overlap: \(a) and \(b)")
                }
            }
        }

        /// The scoped save must have written every scene tile's WORLD frame and
        /// every scene zone's placement.
        func expectOnDisk(_ s: Snapshot, _ context: String) {
            scene.fixture.drain(0.3)
            try? mounted.runtime.flushPendingArmingSave()
            let document = try? WorkspaceStore(workspaceId: Fixture.workspaceA,
                                               applicationSupportDirectory: scene.fixture.appSupport).load()
            for zone in scene.zones {
                let persisted = (try? ProjectStore(projectRoot: zone.root).loadCanvas())?.tiles ?? []
                for id in zone.tileIds {
                    let disk = persisted.first { $0.id == id }
                    TidyNeighbourChecks.check(disk?.frame == s.tiles[id]?.frame && disk?.zoneId == zone.zoneId,
                          "\(context): \(zone.name)'s canvas.json holds \(String(describing: disk?.frame)) in \(String(describing: disk?.zoneId)); on screen \(String(describing: s.tiles[id]?.frame))")
                }
                let placed = document?.zones.first { $0.zoneId == zone.zoneId }.map(CanvasEngine.zoneWorldFrame)
                TidyNeighbourChecks.check(placed == s.zones[zone.zoneId],
                      "\(context): the workspace document holds zone \(zone.name) at \(String(describing: placed)); on screen \(String(describing: s.zones[zone.zoneId]))")
            }
        }

        private func name(_ zoneId: UUID) -> String {
            scene.zones.first { $0.zoneId == zoneId }?.name ?? "seeded \(zoneId.uuidString.prefix(8))"
        }
    }
}
