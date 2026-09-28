import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/67` slice 4 (ARC-4a): replacing the view of a tile that already
/// exists is not a spawn. Browser snapshot and restart, budget eviction,
/// terminal restart, file-tree installs and note conversion swap the view of a
/// record the user already placed; none of them may move, grow, re-home or
/// re-stack anything, and the view they replace must let go exactly once.
///
/// Every scenario mounts the invariants fixture's two workspaces with a
/// hand-spaced scene added to workspace A: members deliberately NOT at gap
/// contact, so a settle pass would visibly move them. The baseline is the
/// seeded bytes themselves, decoded before the mount. After each lifecycle
/// step the WORLD frame, zone membership and z-position of every tile, and
/// every zone's rect, must equal that baseline exactly (tolerance 0), both in
/// the mounted model and in the files on disk.
///
/// The positive control is a real user spawn into the same zone. It is allowed
/// to move and grow things, and it must: if it moved nothing, this scene could
/// not tell a spawn from a materialization and every GREEN here would be vacuous.
@MainActor
enum TileMaterializeChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    // MARK: - The hand-spaced additions to workspace A

    static let terminalA1 = UUID(uuidString: "00000000-0000-0000-0000-00004A4A1701")!
    static let treeA1 = UUID(uuidString: "00000000-0000-0000-0000-00004A4A1702")!
    /// A file tree with no sidecar entry: it restores as the recoverable error view.
    static let treeA3 = UUID(uuidString: "00000000-0000-0000-0000-00004A4A3701")!
    static let browserA2a = UUID(uuidString: "00000000-0000-0000-0000-00004A4A2B01")!
    static let browserA2b = UUID(uuidString: "00000000-0000-0000-0000-00004A4A2B02")!

    /// Zone A1 is (600,200 900x700), A3 (600,1000 900x280), A2 (1700,260 900x700).
    /// The fixture's notes and file tile are already there; these fill the gaps
    /// at irregular distances. Sizes are at or above each kind's minimum, which
    /// the mount enforces on load.
    private static func seedHandSpacedScene(_ fixture: Fixture) throws {
        func add(_ projectId: UUID, _ tiles: [Tile]) throws {
            let store = ProjectStore(projectRoot: fixture.projectRoots[projectId]!)
            guard var canvas = try store.tryLoadCanvas() else { throw Failure(message: "seed: project \(projectId) has no canvas") }
            canvas.tiles.append(contentsOf: tiles)
            try store.saveCanvas(canvas)
        }
        func tile(_ id: UUID, _ kind: TileKind, _ title: String, _ frame: TileFrame, rank: Int, zone: UUID,
                  _ configure: (inout TileMetadata) -> Void) -> Tile {
            var metadata = TileMetadata()
            configure(&metadata)
            var tile = Tile(id: id, kind: kind, title: title, frame: frame, zPosition: .fromLegacyRank(rank),
                            runtimeRef: nil, metadata: metadata)
            tile.zoneId = zone
            return tile
        }
        let rootA1 = fixture.projectRoots[Fixture.projectA1]!
        try add(Fixture.projectA1, [
            tile(terminalA1, .terminal, "Shell", TileFrame(x: 1180, y: 560, width: 280, height: 200),
                 rank: 10, zone: Fixture.zoneA1) { $0.launchProfileId = "shell" },
            tile(treeA1, .fileTree, "Alder", TileFrame(x: 640, y: 520, width: 240, height: 300),
                 rank: 11, zone: Fixture.zoneA1) { $0.filePath = rootA1.path },
            tile(treeA3, .fileTree, "Alder", TileFrame(x: 960, y: 1036, width: 240, height: 240),
                 rank: 12, zone: Fixture.zoneA3) { $0.filePath = rootA1.path }
        ])
        try ProjectStore(projectRoot: rootA1).saveFileTreeState(FileTreeState(tiles: [
            FileTreeTile(tileId: treeA1, rootPath: rootA1.path, expandedPaths: [], selectedPath: nil,
                         searchQuery: "", ignoredNames: [], gitBadges: .off)
        ]))
        try add(Fixture.projectA2, [
            tile(browserA2a, .browser, "Blank A", TileFrame(x: 2100, y: 360, width: 400, height: 260),
                 rank: 10, zone: Fixture.zoneA2) { $0.url = "about:blank" },
            tile(browserA2b, .browser, "Blank B", TileFrame(x: 1760, y: 660, width: 320, height: 240),
                 rank: 11, zone: Fixture.zoneA2) { $0.url = "about:blank" }
        ])
    }

    // MARK: - Geometry facts

    struct TileFact: Equatable, CustomStringConvertible {
        let frame: TileFrame
        let zoneId: UUID?
        let zPosition: FracIndex
        var description: String {
            "\(frame.x),\(frame.y) \(frame.width)x\(frame.height) in \(zoneId.map { String($0.uuidString.suffix(5)) } ?? "root") z \(zPosition)"
        }
    }

    struct Scene: Equatable {
        var tiles: [UUID: TileFact] = [:]
        var zones: [UUID: String] = [:]
    }

    private static let workspaceAProjects = [Fixture.projectA1, Fixture.projectA2]

    private static func zoneFact(_ zone: ZonePlacement) -> String {
        "\(zone.origin.x),\(zone.origin.y) \(zone.size.width)x\(zone.size.height) z \(zone.zPosition)"
    }

    /// What the mounted canvas holds: every tile's WORLD frame, the zone whose
    /// LAYER holds it, its z-position; and each zone as the document records it
    /// and as the canvas draws it.
    private static func modelScene(_ fixture: Fixture) throws -> Scene {
        let m = try fixture.requireMounted("model scene")
        m.canvas.layoutSubtreeIfNeeded()
        var scene = Scene()
        for projectId in workspaceAProjects {
            for tile in m.canvas.tilesInWorldFrames(forProjectId: projectId) {
                scene.tiles[tile.id] = TileFact(
                    frame: tile.frame, zoneId: m.canvas.zoneId(containing: tile.id), zPosition: tile.zPosition)
            }
        }
        let drawn = Dictionary(m.canvas.renderedZonesInZOrder.map { ($0.zoneId, $0) }, uniquingKeysWith: { first, _ in first })
        for zone in m.runtime.document.zones {
            scene.zones[zone.zoneId] = zoneFact(zone) + " | drawn " + (drawn[zone.zoneId].map(zoneFact) ?? "nothing")
        }
        return scene
    }

    /// What the files say, decoded from the raw bytes.
    private static func diskScene(_ fixture: Fixture) throws -> Scene {
        var scene = Scene()
        for projectId in workspaceAProjects {
            for tile in fixture.readProjectFile(projectId).canvas?.tiles ?? [] {
                scene.tiles[tile.id] = TileFact(frame: tile.frame, zoneId: tile.zoneId, zPosition: tile.zPosition)
            }
        }
        for zone in try fixture.readWorkspaceFile(Fixture.workspaceA).document?.zones ?? [] {
            scene.zones[zone.zoneId] = zoneFact(zone)
        }
        return scene
    }

    /// The same shape as a model scene, so a baseline read from disk compares
    /// against both views: a zone's document rect and its drawn rect are both
    /// the seeded rect.
    private static func asModelBaseline(_ disk: Scene) -> Scene {
        var scene = disk
        for (id, fact) in disk.zones { scene.zones[id] = fact + " | drawn " + fact }
        return scene
    }

    private static func differences(_ got: Scene, _ want: Scene) -> [String] {
        var lines: [String] = []
        for id in Set(got.tiles.keys).union(want.tiles.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let g = got.tiles[id], w = want.tiles[id]
            if g != w {
                lines.append("tile \(id.uuidString.suffix(5)): \(g.map(\.description) ?? "missing"), expected \(w.map(\.description) ?? "absent")")
            }
        }
        for id in Set(got.zones.keys).union(want.zones.keys).sorted(by: { $0.uuidString < $1.uuidString }) where got.zones[id] != want.zones[id] {
            lines.append("zone \(id.uuidString.suffix(5)): \(got.zones[id] ?? "missing"), expected \(want.zones[id] ?? "absent")")
        }
        return lines
    }

    /// Model and disk both equal the seeded scene, exactly.
    private static func expectUnmoved(_ fixture: Fixture, baseline: Scene, after step: String) throws {
        fixture.drain()
        let model = differences(try modelScene(fixture), asModelBaseline(baseline))
        let disk = differences(try diskScene(fixture), baseline)
        try expect(model.isEmpty && disk.isEmpty,
                   "\(step) moved the hand-spaced scene. model: \(model.isEmpty ? ["unchanged"] : model); "
                   + "disk: \(disk.isEmpty ? ["unchanged"] : disk)")
    }

    /// The replaced view is out of the scene: not in the world plane, not the
    /// broker's adapter for the tile; its successor is both, and alone.
    private static func expectReplaced(_ old: TileNSView, in fixture: Fixture, tileId: UUID, step: String) throws {
        let m = try fixture.requireMounted(step)
        guard let current = m.canvas.tileView(for: tileId) else { throw Failure(message: "\(step): tile has no view") }
        try expect(current !== old, "\(step): the tile still resolves to the view it replaced")
        try expect(old.superview == nil, "\(step): the replaced view is still in the view tree")
        let planeViews = m.canvas.qaWorldPlaneTileViews(for: tileId)
        try expect(planeViews.count == 1 && planeViews.first === current,
                   "\(step): the world plane holds \(planeViews.count) view(s) for the tile")
        let adapter = m.delegate.qaFocusBroker.qaAdapter(for: .tile(tileId)) as AnyObject?
        try expect(adapter === current, "\(step): the focus broker's adapter for the tile is not its current view")
    }

    // MARK: - Scenarios

    static func run() throws -> URL {
        // One real Ghostty context for every mount: a runtime spawns nothing until
        // a surface attaches, and this leg never gives one a window.
        let ghostty = try GhosttyRuntimeContext()
        var manifest: [String: Any] = [:]
        var failures: [String] = []
        let scenarios: [(String, (Fixture, Scene) throws -> [String: Any])] = [
            ("mount-switch-remount", mountSwitchRemount),
            ("browser-budget-eviction", browserBudgetEviction),
            ("pan-away-and-back", panAwayAndBack),
            ("terminal-restart", terminalRestart),
            ("note-conversion", noteConversion),
            ("note-conversion-rollback", noteConversionRollback),
            ("user-spawn-control", userSpawnControl)
        ]
        for (label, body) in scenarios {
            let fixture = try Fixture(label: "materialize-\(label)")
            fixture.ghostty = ghostty
            do {
                try seedHandSpacedScene(fixture)
                let baseline = try diskScene(fixture)
                try fixture.mount()
                try expectUnmoved(fixture, baseline: baseline, after: "the mount")
                var result = try body(fixture, baseline)
                result["actions"] = fixture.actionLog
                manifest[label] = result
            } catch {
                failures.append("\(label): \(error)")
                manifest[label] = ["failure": "\(error)", "actions": fixture.actionLog]
            }
            fixture.dispose()
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/tile-materialize", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) of \(scenarios.count) scenario(s) failed (\(artifact.path)):\n  "
                          + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    /// Hydration's Phase B restarts every browser, terminal and file tree on the
    /// mount and on each switch back; a clean quit and remount does it again.
    private static func mountSwitchRemount(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        func expectHydrated(_ step: String) throws {
            let canvas = try fixture.requireMounted(step).canvas
            for id in [browserA2a, browserA2b] {
                try expect(canvas.tileView(for: id) is BrowserTileNSView, "\(step): browser \(id.uuidString.suffix(5)) is not live")
            }
            try expect(canvas.tileView(for: terminalA1) is TerminalTileNSView, "\(step): the terminal is not live")
            try expect((canvas.tileView(for: treeA1) as? FileTreeTileNSView)?.isRecoverableError == false,
                       "\(step): file tree A1 did not restore")
            try expect((canvas.tileView(for: treeA3) as? FileTreeTileNSView)?.isRecoverableError == true,
                       "\(step): file tree A3 did not restore as its error view")
        }
        try expectHydrated("the mount")
        try fixture.switchTo(Fixture.workspaceB)
        try fixture.switchTo(Fixture.workspaceA)
        try expectHydrated("switch B then A")
        try expectUnmoved(fixture, baseline: baseline, after: "switch B then A")
        try fixture.remount(crash: false)
        try expectHydrated("quit and remount")
        try expectUnmoved(fixture, baseline: baseline, after: "quit and remount")
        return ["hydrated": true]
    }

    /// The real cross-zone cap, lowered to one: one of zone A2's two live
    /// browsers is snapshotted.
    private static func browserBudgetEviction(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        let m = try fixture.requireMounted("budget")
        let before = [browserA2a, browserA2b].compactMap { id in m.canvas.tileView(for: id).map { (id, $0) } }
        m.runtime.qaSetBrowserRuntimeMaxLive(1)
        m.runtime.enforceBrowserRuntimeBudget()
        let evicted = before.filter { m.canvas.tileView(for: $0.0) is BrowserSnapshotTileNSView }
        try expect(evicted.count == 1, "precondition: the budget of one must snapshot exactly one of two browsers; it snapshotted \(evicted.count)")
        try expectReplaced(evicted[0].1, in: fixture, tileId: evicted[0].0, step: "budget eviction")
        try expectUnmoved(fixture, baseline: baseline, after: "budget eviction")
        return ["evicted": evicted[0].0.uuidString]
    }

    /// Pan every zone out of view (zone A2's browsers are snapshotted), then
    /// back (they restart).
    private static func panAwayAndBack(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        let m = try fixture.requireMounted("pan")
        let seeded = m.canvas.viewport
        let live = [browserA2a, browserA2b].compactMap { m.canvas.tileView(for: $0) }
        m.canvas.setViewport(CanvasViewport(x: -4000, y: -100, zoom: 1))
        m.runtime.flushPendingHydrationReconcile()
        for (id, old) in zip([browserA2a, browserA2b], live) {
            try expect(m.canvas.tileView(for: id) is BrowserSnapshotTileNSView,
                       "precondition: panning away must snapshot browser \(id.uuidString.suffix(5))")
            try expectReplaced(old, in: fixture, tileId: id, step: "pan away")
        }
        try expectUnmoved(fixture, baseline: baseline, after: "panning away (snapshot)")
        let snapshots = [browserA2a, browserA2b].compactMap { m.canvas.tileView(for: $0) }
        m.canvas.setViewport(seeded)
        m.runtime.flushPendingHydrationReconcile()
        for (id, old) in zip([browserA2a, browserA2b], snapshots) {
            try expect(m.canvas.tileView(for: id) is BrowserTileNSView,
                       "precondition: panning back must restart browser \(id.uuidString.suffix(5))")
            try expectReplaced(old, in: fixture, tileId: id, step: "pan back")
        }
        try expectUnmoved(fixture, baseline: baseline, after: "panning back (restart)")
        return ["snapshotted": 2, "restarted": 2]
    }

    /// The restart a terminal placeholder's button fires.
    private static func terminalRestart(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        let m = try fixture.requireMounted("terminal restart")
        guard let old = m.canvas.tileView(for: terminalA1) as? TerminalTileNSView else {
            throw Failure(message: "precondition: the terminal did not hydrate live")
        }
        m.delegate.qaRestartTerminalTile(terminalA1)
        try expect(m.canvas.tileView(for: terminalA1) is TerminalTileNSView && m.canvas.tileView(for: terminalA1) !== old,
                   "precondition: the restart did not install a new terminal view")
        try expectReplaced(old, in: fixture, tileId: terminalA1, step: "terminal restart")
        try expectUnmoved(fixture, baseline: baseline, after: "terminal restart")
        return ["restarted": true]
    }

    /// The note's own Save-as-Markdown callback: the note becomes a file tile in
    /// place.
    private static func noteConversion(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        let m = try fixture.requireMounted("note conversion")
        guard let noteView = m.canvas.tileView(for: Fixture.noteA2a) as? NoteTileNSView else {
            throw Failure(message: "precondition: note A2a is not hydrated as a note view")
        }
        let destination = fixture.projectRoots[Fixture.projectA2]!.appendingPathComponent("converted.md")
        noteView.onSaveAsMarkdownRequested?(destination)
        try expect(m.canvas.tileView(for: Fixture.noteA2a) is FileTileNSView, "precondition: the note was not converted")
        try expectReplaced(noteView, in: fixture, tileId: Fixture.noteA2a, step: "note conversion")
        try expectUnmoved(fixture, baseline: baseline, after: "note conversion")
        return ["converted": true]
    }

    /// The same conversion with project A2's canvas file unwritable: the file
    /// view is installed, the save fails, and the note view is restored over it.
    /// The file view must retire exactly once (its document closes once), and a
    /// later retirement of a file view must be seen by the same counter, or the
    /// counter proves nothing.
    private static func noteConversionRollback(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        let m = try fixture.requireMounted("rollback")
        guard let spawner = m.runtime.controller(for: Fixture.projectA2)?.tileSpawner else {
            throw Failure(message: "precondition: project A2 has no live spawner")
        }
        var closes = 0
        let production = spawner.fileEditorConfigurator
        spawner.fileEditorConfigurator = { view in
            production?(view)
            view.onLanguageDocumentClose = { _ in closes += 1 }
        }
        guard m.canvas.tileView(for: Fixture.noteA2a) is NoteTileNSView else {
            throw Failure(message: "precondition: note A2a is not hydrated as a note view")
        }
        let canvasFile = ProjectStoreLayout(projectRoot: fixture.projectRoots[Fixture.projectA2]!).canvasFile.standardizedFileURL.path
        StoreFileWriter.install(.init(fault: .failFrom(1), scope: fixture.root, matching: { url in
            url.standardizedFileURL.path == canvasFile
        }))
        // The conversion the note's menu callback runs, called directly: on
        // failure that callback raises a modal alert, which a check may not.
        let outcome = spawner.convertNoteToDocument(
            noteId: Fixture.noteA2a, tileId: Fixture.noteA2a,
            destination: fixture.projectRoots[Fixture.projectA2]!.appendingPathComponent("rollback.md"))
        let failedWrites = StoreFileWriter.uninstall().filter { $0.outcome == .failed }.count
        try expect(failedWrites >= 1, "precondition: the conversion never tried to save project A2's canvas")
        guard case .failure = outcome else { throw Failure(message: "precondition: the conversion reported \(outcome) with its canvas unwritable") }
        try expect(m.canvas.tileView(for: Fixture.noteA2a) is NoteTileNSView,
                   "precondition: the failed conversion did not restore the note view")
        try expect(closes == 1, "the rolled-back file view retired \(closes) time(s); it must let go of its document exactly once")
        try expectUnmoved(fixture, baseline: baseline, after: "the rolled-back note conversion")

        // Control for the counter: a successful conversion, then a switch away,
        // which retires the file view through the scene teardown.
        guard let restored = m.canvas.tileView(for: Fixture.noteA2a) as? NoteTileNSView else {
            throw Failure(message: "control: note A2a is not a note view")
        }
        restored.onSaveAsMarkdownRequested?(fixture.projectRoots[Fixture.projectA2]!.appendingPathComponent("control.md"))
        try expect(m.canvas.tileView(for: Fixture.noteA2a) is FileTileNSView, "control: the second conversion did not land")
        try fixture.switchTo(Fixture.workspaceB)
        try expect(closes == 2, "control: switching away retired the converted file view, but the counter reads \(closes), "
                   + "not 2, so it does not observe a retirement")
        return ["closes": closes]
    }

    /// A real user spawn into zone A2 through the palette. Allowed to move and
    /// grow things; required to, or the scene cannot tell spawn from materialize.
    private static func userSpawnControl(_ fixture: Fixture, baseline: Scene) throws -> [String: Any] {
        let m = try fixture.requireMounted("spawn control")
        try fixture.armByClick(Fixture.zoneA2)
        let before = Set(try modelScene(fixture).tiles.keys)
        _ = m.delegate.qaPerformPaletteAction(.newNote)
        fixture.drain()
        let after = try modelScene(fixture)
        let spawned = Set(after.tiles.keys).subtracting(before)
        try expect(spawned.count == 1, "control: the palette spawn added \(spawned.count) tile(s)")
        try expect(after.tiles[spawned.first!]?.zoneId == Fixture.zoneA2, "control: the spawned note is not in zone A2")
        var existing = after
        existing.tiles[spawned.first!] = nil
        let moved = differences(existing, asModelBaseline(baseline))
        try expect(!moved.isEmpty,
                   "control: a user spawn into the hand-spaced zone moved and grew nothing, so this leg cannot "
                   + "tell a spawn from a materialization")
        return ["spawnMoved": moved]
    }
}
