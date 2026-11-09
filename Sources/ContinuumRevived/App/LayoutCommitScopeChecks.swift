import AppKit
import ContinuumRevivedCore

/// A layout commit loads, merges and writes only the projects that own the
/// committed tiles (`.plans/auto-layout-night`). It used to load and verify every
/// project canvas in the workspace on each drag and tidy, so its cost grew with
/// the project count, on the main thread, right as the movement started.
///
/// A mounted workspace with 1, 5 and 20 extra projects (each a zone and a note),
/// auto layout on. Through the production commit (`performGeometryEdit` →
/// `commitGeometryEdit` → `persistLayoutTransaction`): a move in one project, then
/// the palette's Tidy. Asserted per commit: the store reads it cost (the shared
/// `StoreReadProbe`), the projects it loaded and wrote, every other project's
/// canvas.json byte-identical, and the commit time flat in the project count.
/// Positive control: one commit that edits two projects loads and writes both.
@MainActor
enum LayoutCommitScopeChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    typealias Fixture = WorkspaceInvariantsFixture

    private static var failures: [String] = []
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    struct Sample {
        let extraProjects: Int
        let moveReads: Int
        let moveMs: Double
        let tidyMs: Double
    }

    static func run() throws {
        failures = []
        var samples: [Sample] = []
        for extra in [1, 5, 20] {
            samples.append(try exercise(extraProjects: extra))
        }
        // Flat in the project count: the store reads a one-project commit costs
        // do not depend on how many projects the workspace holds.
        let reads = samples.map(\.moveReads)
        check(Set(reads).count == 1,
              "a one-project move's store reads must not grow with the project count: \(zip(samples.map(\.extraProjects), reads).map { "\($0.0)→\($0.1)" })")
        if let first = samples.first, let last = samples.last {
            // Loose by design: a debug build on a shared Mac. Linear growth over
            // 20 extra project loads is what this rules out.
            check(last.moveMs <= first.moveMs * 2 + 5,
                  "a one-project move took \(String(format: "%.1f", last.moveMs)) ms with 20 extra projects vs \(String(format: "%.1f", first.moveMs)) ms with 1")
        }
        for sample in samples {
            print(String(format: "layout-commit-scope: %2d extra projects  move %d reads %.1f ms  tidy %.1f ms",
                         sample.extraProjects, sample.moveReads, sample.moveMs, sample.tidyMs))
        }
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
        print("LayoutCommitScopeChecks passed: a commit reads and writes only the projects it changed")
    }

    private static func exercise(extraProjects: Int) throws -> Sample {
        let label = "\(extraProjects) extra projects"
        let fixture = try Fixture(label: "commit-scope-\(extraProjects)")
        defer { fixture.dispose() }
        var extraRoots: [UUID: URL] = [:]
        try addProjects(extraProjects, to: fixture, roots: &extraRoots)
        try fixture.mount()
        let m = try fixture.requireMounted("commit scope")
        TileInsertSlideChecks.pin(m.canvas, autoLayout: true)
        m.canvas.layoutSubtreeIfNeeded()

        var roots = extraRoots
        roots[Fixture.projectA1] = fixture.projectRoots[Fixture.projectA1]
        roots[Fixture.projectA2] = fixture.projectRoots[Fixture.projectA2]
        func canvasFiles() -> [UUID: Data] {
            var files: [UUID: Data] = [:]
            for (projectId, root) in roots {
                files[projectId] = try? Data(contentsOf: ProjectStoreLayout(projectRoot: root).canvasFile)
            }
            return files
        }
        func persistedFrame(_ projectId: UUID, _ tileId: UUID) -> TileFrame? {
            guard let root = roots[projectId] else { return nil }
            return (try? ProjectStore(projectRoot: root).loadCanvas())?.tiles.first { $0.id == tileId }?.frame
        }
        func world(_ id: UUID) -> TileFrame? { m.canvas.allTilesInWorldFrames().first { $0.id == id }?.frame }
        func move(_ ids: [UUID], by dx: Double) {
            _ = m.canvas.performGeometryEdit(.moveTile, tileIds: Set(ids), includeAllZones: true) {
                for id in ids {
                    guard var tile = m.canvas.tileRecord(for: id), let current = world(id) else { continue }
                    var moved = current
                    moved.x += dx
                    tile.frame = m.canvas.tileFrame(fromWorldFrame: moved, tileId: id)
                    m.canvas.updateTile(tile, recalculateZoneBounds: false, notifyChange: false)
                }
            }
            m.canvas.layoutSubtreeIfNeeded()
        }
        /// One commit, measured: reads, projects, files changed, wall time.
        func measure(_ action: () -> Void) -> (reads: Int, ms: Double, changed: Set<UUID>,
                                               projects: (loaded: [UUID], written: [UUID])?) {
            fixture.drain(0.2)
            m.delegate.qaLastLayoutCommitProjects = nil
            let before = canvasFiles()
            let readsBefore = StoreReadProbe.shared.count
            let start = ProcessInfo.processInfo.systemUptime
            action()
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            let reads = StoreReadProbe.shared.count - readsBefore
            let after = canvasFiles()
            let changed = Set(after.keys.filter { after[$0] != before[$0] })
            return (reads, ms, changed, m.delegate.qaLastLayoutCommitProjects)
        }

        // Settle every zone once, so the measured tidy below only has work in one.
        _ = m.delegate.qaPerformPaletteAction(.tidyCanvas)
        m.canvas.layoutSubtreeIfNeeded()
        fixture.drain(0.4)

        // 1. A move in one project: project A1's note.
        let moved = measure { move([Fixture.noteA1a], by: 40) }
        check(moved.projects?.loaded == [Fixture.projectA1],
              "\(label) move: loaded \(String(describing: moved.projects?.loaded)), expected only project A1")
        check(moved.projects?.written == [Fixture.projectA1],
              "\(label) move: wrote \(String(describing: moved.projects?.written)), expected only project A1")
        check(moved.changed == [Fixture.projectA1],
              "\(label) move: canvas.json changed in \(moved.changed.count) project(s), expected only A1's")
        check(persistedFrame(Fixture.projectA1, Fixture.noteA1a) == world(Fixture.noteA1a),
              "\(label) move: canvas.json holds \(String(describing: persistedFrame(Fixture.projectA1, Fixture.noteA1a))) for the note, on screen \(String(describing: world(Fixture.noteA1a)))")

        // 2. The palette's Tidy, with only zone A1 untidy after the move.
        let tidied = measure {
            _ = m.delegate.qaPerformPaletteAction(.tidyCanvas)
            m.canvas.layoutSubtreeIfNeeded()
        }
        if let projects = tidied.projects {
            check(Set(projects.loaded).isSubset(of: [Fixture.projectA1]),
                  "\(label) tidy: loaded \(projects.loaded), expected at most project A1")
        }
        check(tidied.changed.isSubset(of: [Fixture.projectA1]),
              "\(label) tidy: canvas.json changed in \(tidied.changed.count) project(s) outside A1")

        // 3. Positive control: one commit editing two projects loads and writes both.
        let both = measure { move([Fixture.noteA1a, Fixture.noteA2a], by: 30) }
        check(Set(both.projects?.loaded ?? []) == [Fixture.projectA1, Fixture.projectA2],
              "\(label) two-project move: loaded \(String(describing: both.projects?.loaded)), expected A1 and A2")
        check(Set(both.projects?.written ?? []) == [Fixture.projectA1, Fixture.projectA2],
              "\(label) two-project move: wrote \(String(describing: both.projects?.written)), expected A1 and A2")
        check(both.changed == [Fixture.projectA1, Fixture.projectA2],
              "\(label) two-project move: canvas.json changed in \(both.changed.count) project(s), expected exactly A1 and A2")
        check(persistedFrame(Fixture.projectA2, Fixture.noteA2a) == world(Fixture.noteA2a),
              "\(label) two-project move: A2's note is \(String(describing: persistedFrame(Fixture.projectA2, Fixture.noteA2a))) on disk, \(String(describing: world(Fixture.noteA2a))) on screen")

        return Sample(extraProjects: extraProjects, moveReads: moved.reads, moveMs: moved.ms, tidyMs: tidied.ms)
    }

    /// `count` more projects owned by workspace A, each with one zone (far right of
    /// the seeded ones, so none overlaps) and one note in it, WORLD frames on disk.
    private static func addProjects(_ count: Int, to fixture: Fixture, roots: inout [UUID: URL]) throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var registry = try fixture.registryStore.loadOrEmpty()
        let workspaceStore = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try workspaceStore.load()
        for index in 0..<count {
            let projectId = UUID()
            let zoneId = UUID()
            let root = fixture.root.appendingPathComponent("extra-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = ProjectStore(projectRoot: root)
            try store.saveProject(Project(
                id: projectId, name: "Extra \(index)", rootPath: root.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                          terminalClosePolicy: .askWhenRunning)))
            let origin = ZonePoint(x: 3000 + Double(index % 5) * 1000, y: Double(index / 5) * 800)
            let noteId = UUID()
            var note = Tile(
                id: noteId, kind: .note, title: "extra \(index)",
                frame: TileFrame(x: origin.x + 24, y: origin.y + 58, width: 240, height: 160),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(noteId: noteId))
            note.zoneId = zoneId
            try store.saveNoteBody(id: noteId, text: "")
            try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                             tiles: [note], groups: [], lastActiveTileId: nil))
            var placement = ZonePlacement(
                zoneId: zoneId, projectId: projectId, origin: origin, size: ZoneSize(width: 900, height: 700),
                color: "blue", collapsed: false, hydrationPolicy: .automatic, name: "Extra \(index)")
            placement.zPosition = FracIndex.after(document.zones.map(\.zPosition).max() ?? .first)
            document.zones.append(placement)
            registry.projects.append(ProjectEntry(
                id: projectId, name: "Extra \(index)", rootPath: root.path, workspaceId: Fixture.workspaceA,
                lastOpenedAt: now, pinned: false, missing: false))
            if let index = registry.workspaces.firstIndex(where: { $0.id == Fixture.workspaceA }) {
                registry.workspaces[index].projectIds.append(projectId)
            }
            roots[projectId] = root
        }
        try fixture.registryStore.save(registry)
        try workspaceStore.save(document)
    }
}
