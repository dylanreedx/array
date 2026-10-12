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
///  - note edits and file-tree state save into A2's `.array/`, never A1's, after
///    a mount, after a switch away and back, and for a note spawned into A2;
///  - closing A2's terminal, browser and note removes them from A2's
///    `canvas.json` and stores and frees the terminal's surface, and a remount
///    does not bring them back;
///  - a shell exiting in A2 leaves a Restart placeholder exactly where the
///    terminal was, stamps `lastExit` in A2's store, and Restart rebuilds it
///    through A2's controller; a restored terminal opens in A2's own root;
///  - switching away frees the departed projects' Ghostty surfaces, and no
///    surface of any mounted project is alive when the quit teardown reaches
///    `ghostty_app_free`;
///  - an agent-status write and a web link opened beside A2's tile land in A2;
///  - a view's spawner callbacks (Save as Markdown, a file tree's open-file)
///    survive arming another project, because a project keeps one spawner;
///  - a tile record change, a browser profile deletion, the quit's
///    managed-session sweep, a ticket dispatch, focus-mode pairing and a review
///    flyback each act in A2;
///  - `GhosttyRuntimeContext.shutdown` frees a surface a teardown missed
///    instead of trapping in `ghostty_app_free`.
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
    static let diffA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2D01")!
    static let reviewA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2D02")!
    static let queueA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2C01")!
    /// A browser profile that exists before the mount, so every project's
    /// spawner is built offering it.
    static let profileScope = BrowserProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000051AB901")!, name: "Scope",
        dataStoreIdentifier: "00000000-0000-0000-0000-0000051AB902", createdAt: Date(timeIntervalSince1970: 1_900_000_000))
    /// A browser of A2's that is not on the canvas (a zone not hydrated), whose
    /// saved state only a rewrite of A2's own store can reach.
    static let offCanvasBrowserA2 = UUID(uuidString: "00000000-0000-0000-0000-0000051A2B09")!

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
            },
            tile(diffA2, .diffReview, TileFrame(x: 1760, y: 840, width: 400, height: 100), rank: 13, zone: Fixture.zoneA2) {
                $0.reviewId = reviewA2
            },
            tile(queueA2, .ticketQueue, TileFrame(x: 2360, y: 340, width: 220, height: 200), rank: 14, zone: Fixture.zoneA2) { _ in }
        ])
        try ProjectStore(projectRoot: rootA2).saveReviewCommentState(ReviewCommentState(reviewId: reviewA2, comments: []))
        var registry = try fixture.registryStore.loadOrEmpty()
        _ = registry.settings.upsertBrowserProfile(profileScope)
        try fixture.registryStore.save(registry)
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
            ("notes-and-trees-save-to-owner", notesAndTreesSaveToOwner),
            ("close-in-unarmed-zone", closeInUnarmedZone),
            ("exit-and-restart-in-unarmed-zone", exitAndRestartInUnarmedZone),
            ("switch-away-frees-departed-surfaces", switchAwayFreesDepartedSurfaces),
            ("quit-frees-every-surface", quitFreesEverySurface),
            ("status-and-link-in-unarmed-zone", statusAndLinkInUnarmedZone),
            ("spawner-callbacks-survive-arming", spawnerCallbacksSurviveArming),
            ("tile-record-profiles-sweep-queue-pairing", tileRecordProfilesSweepQueuePairing),
            ("review-flyback-in-unarmed-zone", reviewFlybackInUnarmedZone),
            // Last: it frees the leg's Ghostty app.
            ("shutdown-frees-missed-surfaces", shutdownFreesMissedSurfaces)
        ]
        for (label, body) in scenarios {
            let fixture = try Fixture(label: "project-scope-\(label)")
            fixture.ghostty = ghostty
            if label == "switch-away-frees-departed-surfaces" {
                // `.plans/70` S5: a left workspace is kept warm by default, its
                // surfaces alive on purpose. This scenario is about the RELEASE
                // path, so nothing is kept warm here.
                fixture.configureMount = { _, runtime in runtime.warmSceneCapacity = 0 }
            }
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

    /// A note typed into, and a file tree's state, in project A2 while A1 is armed.
    private static func notesAndTreesSaveToOwner(_ fixture: Fixture) throws -> [String: Any] {
        func editNote(tile tileId: UUID, note noteId: UUID, _ text: String, step: String) throws {
            let m = try fixture.requireMounted(step)
            guard let view = m.canvas.tileView(for: tileId) as? NoteTileNSView else {
                throw Failure(message: "\(step): tile \(tileId.uuidString.suffix(4)) is not a live note view")
            }
            view.textView.string = text
            view.onTextChange?()
            try m.runtime.flushMountedWorkspaceState()
            try expect(noteBytes(fixture, Fixture.projectA2, noteId) == text,
                       "\(step): project A2's note file holds \(noteBytes(fixture, Fixture.projectA2, noteId).map { "\"\($0)\"" } ?? "nothing"), not the edit")
            try expect(noteBytes(fixture, Fixture.projectA1, noteId) == nil,
                       "\(step): the edit was written into project A1's .array/notes")
        }

        // 1. The hydrated note, at mount.
        try editNote(tile: Fixture.noteA2a, note: Fixture.noteA2a, "edited at mount", step: "mounted note")

        // 2. The hydrated file tree. Its sidecar on disk is made stale, so only a
        //    write from the live view through A2's own flush can restore it.
        let staleQuery = "stale-on-disk"
        try store(fixture, Fixture.projectA2).saveFileTreeState(FileTreeState(tiles: [
            FileTreeTile(tileId: treeA2, rootPath: fixture.projectRoots[Fixture.projectA2]!.path, expandedPaths: [],
                         selectedPath: nil, searchQuery: staleQuery, ignoredNames: [], gitBadges: .off)
        ]))
        let m = try fixture.requireMounted("tree")
        guard let tree = m.canvas.tileView(for: treeA2) as? FileTreeTileNSView, !tree.isRecoverableError else {
            throw Failure(message: "precondition: file tree A2 did not restore live")
        }
        tree.onPersist?(tree.currentFileTreeTile)
        try m.runtime.flushMountedWorkspaceState()
        let a2Tree = try store(fixture, Fixture.projectA2).tryLoadFileTreeState()?.tiles.first { $0.tileId == treeA2 }
        try expect(a2Tree?.searchQuery == "",
                   "file tree: project A2's sidecar still reads \(a2Tree.map { "\"\($0.searchQuery)\"" } ?? "nothing"); the live view was never saved to its own project")
        let a1Trees = try store(fixture, Fixture.projectA1).tryLoadFileTreeState()?.tiles.map(\.tileId) ?? []
        try expect(!a1Trees.contains(treeA2), "file tree: A2's tree was written into project A1's file-tree sidecar")

        // 3. After a switch away and back: Phase A builds the arriving views
        //    before the arriving project is the active one.
        try fixture.switchTo(Fixture.workspaceB)
        try fixture.switchTo(Fixture.workspaceA)
        try expect(m.runtime.qaArmedZoneId == Fixture.zoneA1,
                   "precondition: zone A1 is not armed after switching back")
        try editNote(tile: Fixture.noteA2a, note: Fixture.noteA2a, "edited after a switch back", step: "note after switch back")

        // 4. A note SPAWNED into A2, typed into after A1 is armed again.
        try fixture.armByClick(Fixture.zoneA2)
        try expect(m.runtime.activeController?.project.id == Fixture.projectA2,
                   "precondition: clicking zone A2 did not make project A2 active")
        let before = Set(m.canvas.allWorkspaceTiles().map(\.id))
        _ = m.delegate.qaPerformPaletteAction(.newNote)
        let spawned = m.canvas.allWorkspaceTiles().filter { !before.contains($0.id) }
        guard spawned.count == 1, let spawnedNote = spawned.first, spawnedNote.kind == .note,
              let spawnedNoteId = spawnedNote.metadata.noteId else {
            throw Failure(message: "precondition: the palette spawned \(spawned.map(\.kind.rawValue)), not one note")
        }
        try expect(m.canvas.zoneId(containing: spawnedNote.id) == Fixture.zoneA2,
                   "precondition: the spawned note is not in zone A2")
        // Let the spawn's own pending saves land, so the edit below is the only
        // thing left for a flush to write.
        fixture.drain()
        try fixture.armByClick(Fixture.zoneA1)
        try expect(m.runtime.activeController?.project.id == Fixture.projectA1,
                   "precondition: clicking zone A1 did not make project A1 active")
        try editNote(tile: spawnedNote.id, note: spawnedNoteId, "typed after arming A1", step: "spawned note")
        return ["spawnedNote": spawnedNoteId.uuidString]
    }

    /// Close A2's terminal, browser and note through the tile's own close
    /// action — the one the × button and the context menu's Close both fire.
    private static func closeInUnarmedZone(_ fixture: Fixture) throws -> [String: Any] {
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("close")
        let a2 = try controller(fixture, Fixture.projectA2, "close")
        guard let terminalView = m.canvas.tileView(for: terminalA2) as? TerminalTileNSView,
              pump(until: 5, { terminalView.runtime.qaTerminalView?.surface != nil }) else {
            throw Failure(message: "precondition: terminal A2 has no live surface")
        }
        let terminalRuntime = terminalView.runtime
        try expect(m.canvas.tileView(for: browserA2) is BrowserTileNSView, "precondition: browser A2 is not live")
        try expect(noteBytes(fixture, Fixture.projectA2, Fixture.noteA2a) != nil, "precondition: note A2a has no body file")
        let closed = [terminalA2, browserA2, Fixture.noteA2a]
        for id in closed {
            guard let view = m.canvas.tileView(for: id), let close = view.onClose else {
                throw Failure(message: "precondition: tile \(id.uuidString.suffix(4)) has no close action")
            }
            close()
        }
        fixture.drain(0.3)

        let onDisk = canvasTileIds(fixture, Fixture.projectA2)
        let kept = closed.filter { onDisk.contains($0) }
        try expect(kept.isEmpty, "project A2's canvas.json still holds closed tile(s) \(kept.map { $0.uuidString.suffix(4) })")
        try expect(canvasTileIds(fixture, Fixture.projectA1).contains(terminalA1), "project A1's canvas lost its own terminal")
        try expect(!a2.runtimes.contains { $0.tileId == terminalA2 }, "project A2's controller still holds the closed terminal's runtime")
        try expect(!a2.browserRuntimes.contains { $0.tileId == browserA2 }, "project A2's controller still holds the closed browser's runtime")
        try expect(terminalRuntime.qaTerminalView?.surface == nil, "the closed terminal's Ghostty surface is still alive")
        let browserState = try store(fixture, Fixture.projectA2).tryLoadBrowserState()
        try expect(!(browserState?.tiles.contains { $0.tileId == browserA2 } ?? false),
                   "project A2's browser state still holds the closed browser, which resurrects it")
        try expect(noteBytes(fixture, Fixture.projectA2, Fixture.noteA2a) == nil, "project A2 still holds the closed note's body")
        let sessions = try store(fixture, Fixture.projectA2).listSessions()
        try expect(!sessions.contains { $0.tileId == terminalA2 }, "project A2 still holds the closed terminal's session descriptor")

        // Positive control: the armed project's own terminal closes too.
        m.canvas.tileView(for: terminalA1)?.onClose?()
        fixture.drain(0.3)
        try expect(!canvasTileIds(fixture, Fixture.projectA1).contains(terminalA1), "control: closing A1's own terminal left it in A1's canvas.json")

        try fixture.remount(crash: false)
        let remounted = try fixture.requireMounted("remount")
        let back = (closed + [terminalA1]).filter { remounted.canvas.tileRecord(for: $0) != nil }
        try expect(back.isEmpty, "a remount brought closed tile(s) back: \(back.map { $0.uuidString.suffix(4) })")
        return ["closed": closed.map(\.uuidString)]
    }

    /// The shell in A2's terminal exits; then the placeholder's Restart.
    private static func exitAndRestartInUnarmedZone(_ fixture: Fixture) throws -> [String: Any] {
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("exit")
        let a1 = try controller(fixture, Fixture.projectA1, "exit")
        let a2 = try controller(fixture, Fixture.projectA2, "exit")
        let rootA2 = fixture.projectRoots[Fixture.projectA2]!.path

        // A restored terminal opens in its OWN project, not the armed one's.
        guard let restored = try store(fixture, Fixture.projectA2).listSessions().first(where: { $0.tileId == terminalA2 }) else {
            throw Failure(message: "precondition: project A2 has no session for its restored terminal")
        }
        try expect(sameFile(restored.cwd, rootA2), "terminal A2 was restored in \(restored.cwd), not project A2's root \(rootA2)")

        guard let live = m.canvas.tileView(for: terminalA2) as? TerminalTileNSView,
              pump(until: 5, { live.runtime.qaTerminalView?.surface != nil }) else {
            throw Failure(message: "precondition: terminal A2 has no live surface")
        }
        let liveFrame = live.frame
        let exitedRuntime = live.runtime
        let a1SessionsBefore = Set(try store(fixture, Fixture.projectA1).listSessions().map(\.id))
        exitedRuntime.sendInput(Data("exit\n".utf8))
        let placeholderAppeared = pump(until: 15) { m.canvas.tileView(for: terminalA2) is TerminalRestartTileNSView }
        try expect(placeholderAppeared,
                   "the shell exited but terminal A2 shows \(String(describing: m.canvas.tileView(for: terminalA2).map { type(of: $0) })), not a Restart placeholder")
        let planeViews = m.canvas.qaWorldPlaneTileViews(for: terminalA2)
        try expect(planeViews.count == 1, "the world plane holds \(planeViews.count) views for terminal A2 after the exit")
        try expect(planeViews.first?.frame == liveFrame, "the placeholder sits at \(String(describing: planeViews.first?.frame)), not where the terminal was (\(liveFrame))")
        let exitedDescriptor = try? store(fixture, Fixture.projectA2).loadSession(id: exitedRuntime.id)
        try expect(exitedDescriptor?.lastExit != nil, "project A2's session for the exited terminal has no lastExit")
        try expect(!a2.runtimes.contains { $0 === exitedRuntime }, "project A2's controller still holds the exited runtime")

        // Restart, as the placeholder's button does.
        m.delegate.qaRestartTerminalTile(terminalA2)
        guard let restarted = m.canvas.tileView(for: terminalA2) as? TerminalTileNSView else {
            throw Failure(message: "Restart left terminal A2 as \(String(describing: m.canvas.tileView(for: terminalA2).map { type(of: $0) }))")
        }
        let restartViews = m.canvas.qaWorldPlaneTileViews(for: terminalA2)
        try expect(restartViews.count == 1 && restartViews.first === restarted,
                   "the world plane holds \(restartViews.count) views for terminal A2 after Restart")
        try expect(restarted.frame == liveFrame, "the restarted terminal sits at \(restarted.frame), not \(liveFrame)")
        try expect(a2.runtimes.contains { $0 === restarted.runtime }, "the restarted runtime is not held by project A2's controller")
        try expect(!a1.runtimes.contains { $0 === restarted.runtime }, "the restarted runtime is held by project A1's controller")
        try expect((try? store(fixture, Fixture.projectA2).loadSession(id: restarted.runtime.id)) != nil,
                   "project A2's store has no session for the restarted terminal")
        let a1SessionsAfter = Set(try store(fixture, Fixture.projectA1).listSessions().map(\.id))
        try expect(a1SessionsAfter == a1SessionsBefore, "the restart wrote a session into project A1's store")

        // The restarted terminal's exit is handled too.
        guard pump(until: 5, { restarted.runtime.qaTerminalView?.surface != nil }) else {
            throw Failure(message: "the restarted terminal has no live surface")
        }
        restarted.runtime.sendInput(Data("exit\n".utf8))
        try expect(pump(until: 15) { m.canvas.tileView(for: terminalA2) is TerminalRestartTileNSView },
                   "the restarted terminal's exit left no Restart placeholder")
        return ["placeholderFrame": "\(liveFrame)"]
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

    /// The agent-status write, and an Array-opened web link beside A2's note.
    private static func statusAndLinkInUnarmedZone(_ fixture: Fixture) throws -> [String: Any] {
        let m = try fixture.requireMounted("status")
        let a2Store = store(fixture, Fixture.projectA2)
        guard var session = try a2Store.listSessions().first(where: { $0.tileId == terminalA2 }) else {
            throw Failure(message: "precondition: project A2 has no session for terminal A2")
        }
        session.agentDescriptor = AgentDescriptor(agentKind: .claude, worktreePath: nil, status: .working,
                                                  statusUpdatedAt: Date(timeIntervalSince1970: 1_900_000_000))
        try a2Store.saveSession(session)
        m.delegate.qaUpdateAgentStatus(terminalA2, .done)
        // The raw file: `loadSession` reports every restored agent as `.stale`.
        let sessionFile = ProjectStoreLayout(projectRoot: fixture.projectRoots[Fixture.projectA2]!).sessionFile(id: session.id)
        let written = try JSONCodec.makeDecoder().decode(TerminalSessionDescriptor.self, from: Data(contentsOf: sessionFile))
            .agentDescriptor?.status
        try expect(written == .done, "the status write left project A2's descriptor at \(String(describing: written))")

        let a1Before = canvasTileIds(fixture, Fixture.projectA1)
        let a2Before = canvasTileIds(fixture, Fixture.projectA2)
        let opened = m.delegate.openAgentWebLink(
            URL(string: "https://project-scope.invalid/")!, target: .array, sourceTileId: Fixture.noteA2a)
        try expect(opened, "precondition: the web link did not open a tile")
        fixture.drain(0.3)
        let a1New = canvasTileIds(fixture, Fixture.projectA1).subtracting(a1Before)
        let a2New = canvasTileIds(fixture, Fixture.projectA2).subtracting(a2Before)
        try expect(a1New.isEmpty, "the browser opened beside A2's note was persisted into project A1's canvas.json")
        try expect(a2New.count == 1, "project A2's canvas.json gained \(a2New.count) tile(s) for the opened link, not 1")
        let a2 = try controller(fixture, Fixture.projectA2, "link")
        try expect(a2.browserRuntimes.contains { a2New.contains($0.tileId) }, "the opened browser's runtime is not held by project A2's controller")
        return ["opened": a2New.first?.uuidString ?? ""]
    }

    /// Views a spawner built keep working after a click arms another project:
    /// the project's spawner is the one that built them.
    private static func spawnerCallbacksSurviveArming(_ fixture: Fixture) throws -> [String: Any] {
        let m = try fixture.requireMounted("spawner")
        let a2 = try controller(fixture, Fixture.projectA2, "spawner")
        let rootA2 = fixture.projectRoots[Fixture.projectA2]!
        try fixture.armByClick(Fixture.zoneA2)
        let before = Set(m.canvas.allWorkspaceTiles().map(\.id))
        _ = m.delegate.qaPerformPaletteAction(.newNote)
        guard let spawned = m.canvas.allWorkspaceTiles().first(where: { !before.contains($0.id) && $0.kind == .note }) else {
            throw Failure(message: "precondition: the palette spawned no note into zone A2")
        }
        let spawnerBefore = a2.tileSpawner
        try fixture.armByClick(Fixture.zoneA1)
        try expect(m.runtime.activeController?.project.id == Fixture.projectA1, "precondition: project A1 is not active")
        try expect(a2.tileSpawner === spawnerBefore, "arming project A1 replaced project A2's spawner")

        // Save as Markdown, from the note's own menu callback.
        guard let note = m.canvas.tileView(for: spawned.id) as? NoteTileNSView else {
            throw Failure(message: "precondition: the spawned note is not a live note view")
        }
        let destination = rootA2.appendingPathComponent("saved-after-arming.md")
        note.onSaveAsMarkdownRequested?(destination)
        try expect(m.canvas.tileView(for: spawned.id) is FileTileNSView,
                   "Save as Markdown on the spawned note did nothing after arming another project")
        try expect(FileManager.default.fileExists(atPath: destination.path), "Save as Markdown wrote no file")

        // A file tree's open-file, from its own callback.
        let target = rootA2.appendingPathComponent("opened-from-tree.md")
        try "# opened\n".write(to: target, atomically: true, encoding: .utf8)
        guard let tree = m.canvas.tileView(for: treeA2) as? FileTreeTileNSView else {
            throw Failure(message: "precondition: file tree A2 is not live")
        }
        let tilesBefore = Set(m.canvas.allWorkspaceTiles().map(\.id))
        tree.onSpawnFile?(target.path)
        fixture.drain(0.3)
        let opened = m.canvas.allWorkspaceTiles().filter { !tilesBefore.contains($0.id) && $0.kind == .file }
        try expect(opened.count == 1, "the file tree's open-file opened \(opened.count) tile(s) after arming another project")
        return ["converted": spawned.id.uuidString]
    }

    /// Five project-scoped acts on A2 with A1 armed.
    private static func tileRecordProfilesSweepQueuePairing(_ fixture: Fixture) throws -> [String: Any] {
        let m = try fixture.requireMounted("acts")
        let a2Store = store(fixture, Fixture.projectA2)

        // 1. A tile record change (a retitle, as a diff review's source change or
        //    an inspector's title does) saves A2's canvas.
        guard var record = m.canvas.tileRecord(for: Fixture.noteA2a) else {
            throw Failure(message: "precondition: note A2a has no record")
        }
        record.title = "retitled in A2"
        m.canvas.updateTile(record, recalculateZoneBounds: false)
        fixture.drain()
        let persistedTitle = fixture.readProjectFile(Fixture.projectA2).canvas?.tiles.first { $0.id == Fixture.noteA2a }?.title
        try expect(persistedTitle == "retitled in A2",
                   "a retitled A2 tile was never saved: A2's canvas.json says \(persistedTitle.map { "\"\($0)\"" } ?? "nothing")")

        // 2. Deleting a browser profile rewrites A2's browser state and spawner.
        let profile = profileScope
        let a2Spawner = try controller(fixture, Fixture.projectA2, "profiles").tileSpawner
        try expect(a2Spawner?.browserProfiles.contains { $0.id == profile.id } == true,
                   "precondition: project A2's spawner was not built offering the seeded profile")
        guard var browserState = try a2Store.tryLoadBrowserState(),
              let live = browserState.tiles.first(where: { $0.tileId == browserA2 }) else {
            throw Failure(message: "precondition: project A2 has no browser state for its browser")
        }
        browserState.tiles.append(BrowserTile(
            id: UUID(), tileId: offCanvasBrowserA2, url: live.url, title: live.title,
            storageGroupId: profile.dataStoreIdentifier, profileId: profile.id, createdAt: live.createdAt,
            updatedAt: live.updatedAt, interactionState: nil, tabs: live.tabs, activeTabId: live.activeTabId))
        try a2Store.saveBrowserState(browserState)
        m.delegate.qaDeleteBrowserProfile(tileId: browserA2, profileId: profile.id)
        fixture.drain(0.3)
        let stillUsing = (try a2Store.tryLoadBrowserState())?.tiles.filter { $0.profileId == profile.id }.map(\.tileId) ?? []
        try expect(stillUsing.isEmpty, "project A2's browser state still points at the deleted profile")
        let a2Profiles = try controller(fixture, Fixture.projectA2, "profiles").tileSpawner?.browserProfiles.map(\.id) ?? []
        try expect(!a2Profiles.contains(profile.id), "project A2's spawner still offers the deleted profile")

        // 3. The quit's managed-session sweep reaches A2's store.
        let a2 = try controller(fixture, Fixture.projectA2, "sweep")
        let liveRecordTile = UUID()
        try a2.managedSessionStore.upsert(ManagedAgentSessionRecord(
            tileId: liveRecordTile, agentKind: .claude, status: .starting, lastSeenAt: Date()))
        m.delegate.qaSweepManagedSessionsAtQuit()
        let swept = try a2.managedSessionStore.load(tileId: liveRecordTile)
        try expect(swept?.endedReason == .continuumQuit,
                   "the quit sweep left project A2's live session record at \(String(describing: swept?.status))")

        // 4. Focus mode pairs a tile with an agent in its OWN zone.
        guard var session = try a2Store.listSessions().first(where: { $0.tileId == terminalA2 }) else {
            throw Failure(message: "precondition: project A2 has no session for terminal A2")
        }
        session.agentDescriptor = AgentDescriptor(agentKind: .claude, worktreePath: nil, status: .idle, statusUpdatedAt: Date())
        try a2Store.saveSession(session)
        let companion = m.delegate.qaFocusModeCompanion(for: Fixture.noteA2a)
        try expect(companion == terminalA2,
                   "focus mode paired A2's note with \(companion.map { String($0.uuidString.suffix(4)) } ?? "nothing"), not A2's agent terminal")
        // 5. A ticket dispatched from A2's queue lands beside the queue, in A2.
        let fakeBin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeClaude = fakeBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", fakeBin.path + ":" + originalPath, 1)
        defer { setenv("PATH", originalPath, 1) }
        let a1Before = canvasTileIds(fixture, Fixture.projectA1)
        let a2Before = canvasTileIds(fixture, Fixture.projectA2)
        m.delegate.qaDispatchTicket(
            LinearTicketQueueRow(identifier: "SCOPE-1", title: "Scope", state: "Todo", stateType: nil, priority: .none, labels: []),
            fromQueueTile: queueA2)
        fixture.drain(0.3)
        let a1New = canvasTileIds(fixture, Fixture.projectA1).subtracting(a1Before)
        let a2New = canvasTileIds(fixture, Fixture.projectA2).subtracting(a2Before)
        try expect(a1New.isEmpty, "a ticket dispatched from A2's queue put \(a1New.count) tile(s) in project A1")
        try expect(a2New.count == 1, "a ticket dispatched from A2's queue added \(a2New.count) tile(s) to project A2, not 1")
        try expect(m.canvas.zoneId(containing: a2New.first!) == Fixture.zoneA2, "the dispatched terminal is not in the queue's zone")

        return ["dispatched": a2New.first?.uuidString ?? ""]
    }

    /// Review comments from A2's diff review reach A2's agent terminal.
    private static func reviewFlybackInUnarmedZone(_ fixture: Fixture) throws -> [String: Any] {
        let window = try attachWindow(fixture)
        defer { window.close() }
        let m = try fixture.requireMounted("review")
        _ = try liveTerminalRuntimes(fixture, "precondition")
        let a2Store = store(fixture, Fixture.projectA2)
        guard var session = try a2Store.listSessions().first(where: { $0.tileId == terminalA2 }) else {
            throw Failure(message: "precondition: project A2 has no session for terminal A2")
        }
        session.agentDescriptor = AgentDescriptor(agentKind: .claude, worktreePath: nil, status: .idle, statusUpdatedAt: Date())
        try a2Store.saveSession(session)
        m.canvas.tileView(for: terminalA2)?.agentStatus = .idle
        let prompt: ReviewFlybackPrompt
        do {
            prompt = try m.delegate.sendReviewCommentsToAgent(
                reviewTileId: diffA2, targetAgentTileId: terminalA2, diffSourceDescription: "scope")
        } catch {
            throw Failure(message: "review flyback from A2's diff review failed: \(error)")
        }
        try expect(prompt.text.contains(reviewA2.uuidString), "the flyback prompt does not name A2's review")
        return ["sent": true]
    }

    /// A surface a teardown missed is freed by the shutdown itself, which then
    /// frees the Ghostty app instead of trapping on the live surface.
    /// It frees the leg's own Ghostty app — production has exactly one, and a
    /// second app freed in-process takes shared Ghostty state with it — so it
    /// must run last.
    private static func shutdownFreesMissedSurfaces(_ fixture: Fixture) throws -> [String: Any] {
        guard let context = fixture.ghostty else { throw Failure(message: "precondition: the leg has no Ghostty app") }
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        defer { window.close() }
        let runtime = GhosttyTerminalRuntime(
            title: "missed",
            launchProfile: LaunchProfile(command: "/bin/sh", arguments: [], cwd: fixture.root.path, title: "missed"),
            ghostty: context)
        host.attach(runtime: runtime)
        host.layoutSubtreeIfNeeded()
        try expect(pump(until: 5) { runtime.qaTerminalView?.surface != nil }, "precondition: the terminal got no surface")
        let before = GhosttyTerminalView.liveSurfaceCount
        context.shutdown()
        try expect(runtime.qaTerminalView?.surface == nil, "shutdown left the missed surface alive")
        try expect(GhosttyTerminalView.liveSurfaceCount == before - 1, "the live-surface count did not drop by the one freed")
        return ["freed": 1]
    }
}
