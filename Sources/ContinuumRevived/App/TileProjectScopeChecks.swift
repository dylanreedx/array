import AppKit
import ContinuumRevivedCore
import Foundation

/// A tile's own project, never the armed zone's, owns everything done to it.
///
/// One workspace mounts several projects, each with its own controller: its
/// runtimes, its note and file-tree views, its stores, its spawner. The app used
/// to reach all of those through accessors that resolved to the ARMED zone's
/// project, from code acting on one particular tile. With project A1's zone
/// armed, every scenario here acts on a tile of project A2 — whose zone is on
/// screen, live and simply not armed — and asserts the outcome in A2's files and
/// A2's controller, with A1's left alone.
///
///  - switching away frees the departed projects' Ghostty surfaces, and no
///    surface of any mounted project is alive when the quit teardown reaches
///    `ghostty_app_free`.
///
/// Terminals run a real shell in a real (off-display) window, with tmux and the
/// delete confirmation turned off through the volatile argument domain only —
/// nothing is written to any defaults domain, and no tmux server is touched.
@MainActor
enum TileProjectScopeChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    static let terminalA1 = UUID(uuidString: "00000000-0000-0000-0000-0000051A1701")!
    static let terminalA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2701")!
    static let browserA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2B01")!
    static let treeA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2E01")!

    /// Zone A1 (600,200 900x700, project A1, armed) and zone A2 (1700,260 900x700,
    /// project A2) — both fully in the seeded camera, so both hydrate live.
    private static func seedScene(_ fixture: Fixture) throws {
        func add(_ projectId: UUID, _ tiles: [Tile]) throws {
            let store = ProjectStore(projectRoot: fixture.projectRoots[projectId]!)
            guard var canvas = try store.tryLoadCanvas() else { throw Failure(message: "seed: project \(projectId) has no canvas") }
            canvas.tiles.append(contentsOf: tiles)
            try store.saveCanvas(canvas)
        }
        func tile(_ id: UUID, _ kind: TileKind, _ frame: TileFrame, rank: Int, zone: UUID,
                  _ configure: (inout TileMetadata) -> Void) -> Tile {
            var metadata = TileMetadata()
            configure(&metadata)
            var tile = Tile(id: id, kind: kind, title: kind.rawValue, frame: frame, zPosition: .fromLegacyRank(rank),
                            runtimeRef: nil, metadata: metadata)
            tile.zoneId = zone
            return tile
        }
        let rootA2 = fixture.projectRoots[Fixture.projectA2]!
        try add(Fixture.projectA1, [
            tile(terminalA1, .terminal, TileFrame(x: 640, y: 620, width: 260, height: 200), rank: 10, zone: Fixture.zoneA1) {
                $0.launchProfileId = "shell"
            }
        ])
        try add(Fixture.projectA2, [
            tile(terminalA2, .terminal, TileFrame(x: 2060, y: 340, width: 280, height: 200), rank: 10, zone: Fixture.zoneA2) {
                $0.launchProfileId = "shell"
            },
            tile(browserA2, .browser, TileFrame(x: 1760, y: 560, width: 400, height: 260), rank: 11, zone: Fixture.zoneA2) {
                $0.url = "about:blank"
            },
            tile(treeA2, .fileTree, TileFrame(x: 2200, y: 600, width: 240, height: 300), rank: 12, zone: Fixture.zoneA2) {
                $0.filePath = rootA2.path
            }
        ])
        // The fixture seeds note bodies only. Without an index entry every flush
        // of A2's notes fails and leaves A2 dirty, which would let an edit routed
        // to the wrong project ride along on A2's retry and look saved.
        let seededAt = Date(timeIntervalSince1970: 1_900_000_000)
        try ProjectStore(projectRoot: rootA2).saveNoteState(NoteState(tiles: [
            NoteTile(id: Fixture.noteA2a, tileId: Fixture.noteA2a, filename: "\(Fixture.noteA2a.uuidString).md",
                     title: "note", createdAt: seededAt, updatedAt: seededAt)
        ]))
        try ProjectStore(projectRoot: rootA2).saveFileTreeState(FileTreeState(tiles: [
            FileTreeTile(tileId: treeA2, rootPath: rootA2.path, expandedPaths: [], selectedPath: nil,
                         searchQuery: "", ignoredNames: [], gitBadges: .off)
        ]))
    }

    // MARK: - Reading the projects back

    private static func store(_ fixture: Fixture, _ projectId: UUID) -> ProjectStore {
        ProjectStore(projectRoot: fixture.projectRoots[projectId]!)
    }

    private static func noteBytes(_ fixture: Fixture, _ projectId: UUID, _ noteId: UUID) -> String? {
        let url = ProjectStoreLayout(projectRoot: fixture.projectRoots[projectId]!).noteFile(id: noteId)
        return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func canvasTileIds(_ fixture: Fixture, _ projectId: UUID) -> Set<UUID> {
        Set(fixture.readProjectFile(projectId).canvas?.tiles.map(\.id) ?? [])
    }

    private static func controller(_ fixture: Fixture, _ projectId: UUID, _ step: String) throws -> ZoneRuntimeController {
        let m = try fixture.requireMounted(step)
        guard let controller = m.runtime.controller(for: projectId) else {
            throw Failure(message: "\(step): project \(projectId.uuidString.suffix(4)) has no live controller")
        }
        return controller
    }

    private static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Run the main loop until `condition` holds or `timeout` passes.
    private static func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Host the mounted canvas in a real, off-display window: Ghostty creates a
    /// terminal's surface (and starts its shell) only once its view is in one.
    private static func attachWindow(_ fixture: Fixture) throws -> NSWindow {
        let m = try fixture.requireMounted("window")
        let window = NSWindow(contentRect: m.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = m.canvas
        window.orderFrontOffscreenForChecks()
        m.canvas.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: - Scenarios

    static func run() throws -> URL {
        let ghostty = try GhosttyRuntimeContext()
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        var isolated = arguments
        isolated[TmuxPersistenceConfig.enabledKey] = false
        isolated[DeleteConfirmPolicy.userDefaultsKey] = DeleteConfirmPolicy.never.rawValue
        UserDefaults.standard.setVolatileDomain(isolated, forName: UserDefaults.argumentDomain)

        var manifest: [String: Any] = [:]
        var failures: [String] = []
        let scenarios: [(String, (Fixture) throws -> [String: Any])] = [
            ("switch-away-frees-departed-surfaces", switchAwayFreesDepartedSurfaces),
            ("quit-frees-every-surface", quitFreesEverySurface)
        ]
        for (label, body) in scenarios {
            let fixture = try Fixture(label: "project-scope-\(label)")
            fixture.ghostty = ghostty
            do {
                try seedScene(fixture)
                try fixture.mount()
                let m = try fixture.requireMounted("mount")
                try expect(m.runtime.qaArmedZoneId == Fixture.zoneA1, "precondition: zone A1 is not the armed zone")
                try expect(m.runtime.activeController?.project.id == Fixture.projectA1,
                           "precondition: project A1 is not the active project")
                var result = try body(fixture)
                result["actions"] = fixture.actionLog
                manifest[label] = result
            } catch {
                failures.append("\(label): \(error)")
                manifest[label] = ["failure": "\(error)", "actions": fixture.actionLog]
            }
            fixture.dispose()
        }
        let dir = URL(fileURLWithPath: "qa-runs/\(Int(Date().timeIntervalSince1970))/tile-project-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) of \(scenarios.count) scenario(s) failed (\(artifact.path)):\n  "
                          + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    /// The live terminals of both projects, each with a surface.
    private static func liveTerminalRuntimes(_ fixture: Fixture, _ step: String) throws -> [GhosttyTerminalRuntime] {
        let m = try fixture.requireMounted(step)
        let runtimes = [terminalA1, terminalA2].compactMap { (m.canvas.tileView(for: $0) as? TerminalTileNSView)?.runtime }
        try expect(runtimes.count == 2, "\(step): \(runtimes.count) of 2 terminals are live")
        try expect(pump(until: 5) { runtimes.allSatisfy { $0.qaTerminalView?.surface != nil } },
                   "\(step): the two terminals did not both get a surface")
        return runtimes
    }

    /// Switching away releases A1's and A2's controllers: no surface of either
    /// may outlive its controller. Then back, which rebuilds both.
    private static func switchAwayFreesDepartedSurfaces(_ fixture: Fixture) throws -> [String: Any] {
        let window = try attachWindow(fixture)
        defer { window.close() }
        let departing = try liveTerminalRuntimes(fixture, "precondition")
        try fixture.switchTo(Fixture.workspaceB)
        let leaked = departing.filter { $0.qaTerminalView?.surface != nil }
        try expect(leaked.isEmpty, "switching away left \(leaked.count) departed terminal surface(s) alive with no controller")
        try fixture.switchTo(Fixture.workspaceA)
        _ = try liveTerminalRuntimes(fixture, "switch back")
        return ["departedFreed": departing.count]
    }

    /// The quit teardown with A1 armed: A2's surface is freed before
    /// `ghostty_app_free` exactly like A1's.
    private static func quitFreesEverySurface(_ fixture: Fixture) throws -> [String: Any] {
        let window = try attachWindow(fixture)
        defer { window.close() }
        let live = try liveTerminalRuntimes(fixture, "precondition")
        let delegate = try fixture.requireMounted("quit").delegate
        try fixture.quit()
        try expect(delegate.qaLiveTerminalSurfacesAtGhosttyShutdown != nil, "the quit teardown never reached the Ghostty shutdown step")
        let atShutdown = live.filter { $0.qaTerminalView?.surface != nil }
        try expect(atShutdown.isEmpty,
                   "\(atShutdown.count) terminal surface(s) were alive when the quit teardown freed the Ghostty app "
                   + "(\(delegate.qaLiveTerminalSurfacesAtGhosttyShutdown ?? -1) process-wide)")
        return ["surfacesAtShutdown": delegate.qaLiveTerminalSurfacesAtGhosttyShutdown ?? -1]
    }

}
