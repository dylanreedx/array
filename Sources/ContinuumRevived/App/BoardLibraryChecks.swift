import AppKit
import ContinuumRevivedCore
import Foundation

/// Drives the board library through a production-mounted scene. In particular,
/// no view is manually attached and no check-only scene installer is called.
@MainActor
enum BoardLibraryChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func run() throws {
        try writePreviewsIfRequested()
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var firstBoard = UUID()
        var secondBoard = UUID()
        var thirdBoard = UUID()
        var replacementTile = UUID()
        var thirdTile = UUID()
        let cardId = UUID()

        try fixture.withMountedScene { canvas, delegate, spawner, runtime, controller in
            guard case let .spawned(a, aTile) = spawner.spawnBoard(title: "Alpha"),
                  case let .spawned(b, bTile) = spawner.spawnBoard(title: "Beta"),
                  case let .spawned(c, cTile) = spawner.spawnBoard(title: "Gamma") else {
                throw Failure(description: "production spawner did not create the three library boards")
            }
            firstBoard = a; secondBoard = b; thirdBoard = c
            replacementTile = aTile; thirdTile = cTile
            guard let beta = controller.boardRuntime.board(id: b),
                  let column = beta.orderedColumns.first else {
                throw Failure(description: "Beta has no persisted default columns")
            }
            guard case .applied = controller.boardRuntime.apply(
                .createCard(id: cardId, columnId: column.id, title: "Keep me", after: nil, before: nil), to: b) else {
                throw Failure(description: "could not add the preservation control card")
            }
            delegate.deleteTile(id: bTile)
            try expect(FileManager.default.fileExists(atPath: fixture.store.layout.boardFile(id: b).path),
                       "closing Beta must preserve its actual board file")
            guard let alphaView = canvas.tileView(for: aTile) as? KanbanTileNSView else {
                throw Failure(description: "Alpha did not mount as a board tile")
            }
            alphaView.toggleBoardSidebar()
            alphaView.refreshBoardLibrary()
            try expect(alphaView.qaBoardSidebarExpanded, "the board library toggle must expand the sidebar")
            try expect(Set(alphaView.qaBoardLibraryEntries.map(\.id)) == Set([a, b, c]),
                       "sidebar must discover both open boards and closed Beta")
            try expect(alphaView.qaBoardLibraryEntries.first(where: { $0.id == b })?.isOpen == false,
                       "Beta must appear as closed after its tile closes")
            // The canvas is authoritative even when a previous interrupted save
            // left the source board's discovery pointer stale.
            var staleIndex = try fixture.store.loadBoardState()
            staleIndex.boards[staleIndex.boards.firstIndex(where: { $0.id == a })!].tileId = UUID()
            try fixture.store.saveBoardState(staleIndex)
            alphaView.activateLibraryBoard(b)
            canvas.layoutSubtreeIfNeeded()
            guard let betaView = canvas.tileView(for: aTile) as? KanbanTileNSView else {
                throw Failure(description: "switching to closed Beta must keep the host tile")
            }
            try expect(betaView.board.id == b && betaView.board.card(cardId)?.title == "Keep me",
                       "selecting closed Beta must replace Alpha with the preserved Beta document")
            try expect(canvas.allTilesInWorldFrames().filter { $0.metadata.boardId == b }.count == 1,
                       "selecting a closed board must yield exactly one tile")
            try expect(canvas.allTilesInWorldFrames().allSatisfy { $0.metadata.boardId != a },
                       "the replaced Alpha board must no longer have an open tile")
            let saved = try fixture.store.loadCanvas()
            try expect(saved.tiles.first(where: { $0.id == aTile })?.metadata.boardId == b,
                       "switching must persist the tile's new board identity")
            try expect(try fixture.indexEntry(a).tileId == nil && fixture.indexEntry(b).tileId == aTile,
                       "switching must atomically transfer index ownership")

            let invalidName = betaView.renameLibraryBoard(b, title: "   ")
            try expect(invalidName != nil && betaView.board.title == "Beta",
                       "blank rename must report refusal and preserve the current title")
            let error = betaView.renameLibraryBoard(b, title: "Beta renamed")
            try expect(error == nil, "production rename callback failed: \(error ?? "")")
            try expect(betaView.board.title == "Beta renamed", "rename must render the new board name")
            try expect(try fixture.store.loadBoard(id: b).title == "Beta renamed",
                       "rename must persist the authoritative document title")
            try expect(try fixture.indexEntry(b).title == "Beta renamed", "rename must update the durable index title")
            controller.boardRuntime.history(for: b).undoManager.undo()
            let undoneTitle = try fixture.indexEntry(b).title
            try expect(betaView.board.title == "Beta" && undoneTitle == "Beta",
                       "rename undo must restore rendered and indexed names")
            controller.boardRuntime.history(for: b).undoManager.redo()
            let redoneTitle = try fixture.indexEntry(b).title
            try expect(betaView.board.title == "Beta renamed" && redoneTitle == "Beta renamed",
                       "rename redo must restore rendered and indexed names")
            betaView.refreshBoardLibrary()
            try expect(betaView.qaBoardLibraryEntries.first(where: { $0.id == b })?.title == "Beta renamed",
                       "rename must refresh the sidebar name")

            // Choosing an already-open board reveals its own tile, rather than
            // moving its document into this tile and leaving a duplicate behind.
            betaView.activateLibraryBoard(c)
            try expect((canvas.tileView(for: aTile) as? KanbanTileNSView)?.board.id == b,
                       "navigating to open Gamma must leave Beta's own tile intact")
            try expect((canvas.tileView(for: cTile) as? KanbanTileNSView)?.board.id == c,
                       "navigating to open Gamma must preserve its existing tile")
            for _ in 0..<3 {
                _ = runtime.openBoard(projectId: fixture.project.id, boardId: c, replacingTileId: aTile)
            }
            try expect(canvas.allTilesInWorldFrames().filter { $0.metadata.boardId == c }.map(\.id) == [cTile],
                       "repeated opening must reuse Gamma's existing tile")
            try controller.flushCanvasSave()
            try fixture.assertUniquePersistedBoards()
        }

        // A second launch loads identity and names from disk; there is no old
        // runtime cache or view left to hide a bad switch/rename write.
        try fixture.withMountedScene { canvas, delegate, _, _, controller in
            guard let betaView = canvas.tileView(for: replacementTile) as? KanbanTileNSView,
                  let gammaView = canvas.tileView(for: thirdTile) as? KanbanTileNSView else {
                throw Failure(description: "the switched Beta and original Gamma did not remount")
            }
            try expect(betaView.board.id == secondBoard && betaView.board.title == "Beta renamed"
                       && betaView.board.card(cardId)?.title == "Keep me",
                       "remount must preserve switched identity, renamed title, and cards")
            try expect(betaView.qaBoardSidebarExpanded,
                       "sidebar expansion must survive switching and remount")
            gammaView.refreshBoardLibrary()
            try expect(Set(gammaView.qaBoardLibraryEntries.map(\.id)) == Set([firstBoard, secondBoard, thirdBoard]),
                       "the closed Alpha must remain discoverable after remount")
            delegate.deleteTile(id: replacementTile)
            gammaView.activateLibraryBoard(secondBoard)
            try expect((canvas.tileView(for: thirdTile) as? KanbanTileNSView)?.board.id == secondBoard,
                       "reopening closed Beta from Gamma must retain the host tile")
            try expect(try fixture.indexEntry(thirdBoard).tileId == nil,
                       "replacing Gamma must preserve its document as a closed board")
            try controller.flushCanvasSave()
            try fixture.assertUniquePersistedBoards()
        }

        try fixture.withMountedScene { canvas, _, _, _, _ in
            guard let betaView = canvas.tileView(for: thirdTile) as? KanbanTileNSView else {
                throw Failure(description: "the reopened board did not survive a third launch")
            }
            try expect(betaView.board.id == secondBoard && betaView.board.card(cardId) != nil,
                       "closed/reopened Beta must retain its stable identity and contents across launch")
            try expect(try fixture.indexEntry(firstBoard).tileId == nil
                       && fixture.indexEntry(thirdBoard).tileId == nil,
                       "past Alpha and Gamma must remain preserved without open tiles")
            try fixture.assertUniquePersistedBoards()
        }
        try runFailureAndDeletionChecks()
        try runUnhydratedOwnershipCheck()
        print("board-library: production sidebar switches closed boards, reveals open boards without duplicates, "
              + "persists renamed titles and ownership, and preserves cards across close/reopen and three mounts")
    }

    private static func writePreviewsIfRequested() throws {
        let directory = ProcessInfo.processInfo.environment["CONTINUUM_BOARD_QA_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var board = Board.makeDefault(id: UUID(), title: "Release planning", now: now)
        board.cards = [BoardCard(id: UUID(), columnId: board.orderedColumns[0].id,
            position: .fromLegacyRank(0), title: "Verify the board refresh", body: "Close, reopen, and reference this board.",
            createdAt: now, updatedAt: now)]
        let entries = [BoardLibraryEntry(id: board.id, title: board.title, isOpen: true),
                       BoardLibraryEntry(id: UUID(), title: "Product ideas", isOpen: true),
                       BoardLibraryEntry(id: UUID(), title: "Previous release", isOpen: false)]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let probe = try UIProbe.render(.init(id: "board-library", size: NSSize(width: 900, height: 460), appearance: appearance)) {
                let tile = Tile(id: UUID(), kind: .kanban, title: board.title,
                    frame: TileFrame(x: 0, y: 0, width: 900, height: 460), zPosition: .fromLegacyRank(0),
                    runtimeRef: nil, metadata: TileMetadata(boardViewState: BoardViewState(sidebarExpanded: true), boardId: board.id))
                let view = KanbanTileNSView(tile: tile, board: board)
                view.boardLibraryProvider = { entries }
                view.refreshBoardLibrary()
                return view
            }
            try expect((probe.view as? KanbanTileNSView)?.qaVisibleBoardLibraryRows.count == 3,
                       "the rendered board sidebar must show all three actual table rows in \(appearance.rawValue)")
            guard let directory else { continue }
            // NSTableView installs visible cells after receiving its window and
            // viewport; capture after that materialization, as the sidebar probe does.
            let rendered = probe.hostRep
            probe.host.cacheDisplay(in: probe.host.bounds, to: rendered)
            guard let png = rendered.representation(using: .png, properties: [:]) else {
                throw Failure(description: "Could not render board preview")
            }
            try png.write(to: directory.appendingPathComponent("board-library-\(appearance.rawValue).png"))
        }
        if let directory { print("board-library previews: \(directory.path)") }
    }

    private static func runFailureAndDeletionChecks() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let throwingStore = FailingIndexStore(base: fixture.store)
        let runtime = BoardRuntime(projectStore: throwingStore)
        let boardId = UUID()
        guard let original = runtime.createBoard(id: boardId, title: "Durable") else {
            throw Failure(description: "could not create failure-injection board")
        }
        // A second save deliberately leaves a recoverable predecessor. Deletion
        // must still remain deleted when a new runtime discovers the project.
        try fixture.store.saveBoard(original)
        let tile = Tile(id: UUID(), kind: .kanban, title: original.title,
                        frame: TileFrame(x: 0, y: 0, width: 700, height: 500),
                        zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: TileMetadata(boardId: boardId))
        let view = KanbanTileNSView(tile: tile, board: original)
        runtime.attach(view, to: boardId)
        var published = 0
        runtime.onCommittedTransaction = { _, _ in published += 1 }
        throwingStore.rejectIndexWrites = true
        guard case .persistenceFailed = runtime.apply(.renameBoard(title: "Must not publish"), to: boardId) else {
            throw Failure(description: "rename must report an index persistence failure")
        }
        try expect(runtime.board(id: boardId) == original && view.board == original,
                   "failed rename must restore both the runtime and rendered document")
        try expect(try fixture.store.loadBoard(id: boardId) == original
                   && fixture.indexEntry(boardId).title == original.title,
                   "failed rename must roll the document and index back to their durable prior state")
        try expect(published == 0 && !runtime.history(for: boardId).undoManager.canUndo,
                   "failed rename must not publish a committed transaction or enter undo history")
        do {
            try runtime.deleteClosedBoard(id: boardId)
            throw Failure(description: "delete must report an index write failure")
        } catch is Failure { throw Failure(description: "delete silently succeeded despite the failed index write") }
        catch { }
        try expect(FileManager.default.fileExists(atPath: fixture.store.layout.boardFile(id: boardId).path),
                   "failed delete must restore the physical board file")
        try expect(try fixture.store.loadBoard(id: boardId) == original && fixture.indexEntry(boardId).title == original.title,
                   "failed delete must preserve the original document and discovery entry")
        runtime.detach(view)
        throwingStore.rejectIndexWrites = false
        try runtime.deleteClosedBoard(id: boardId)
        try expect(!FileManager.default.fileExists(atPath: fixture.store.layout.boardFile(id: boardId).path),
                   "successful permanent delete must remove the physical document")
        let fresh = BoardRuntime(projectStore: ProjectStore(projectRoot: fixture.projectRoot))
        try expect(!fresh.boardIndexEntries().contains(where: { $0.id == boardId }) && fresh.board(id: boardId) == nil,
                   "deleted boards must disappear from discovery and not resurrect from recovery backups")
        try expect(!FileManager.default.fileExists(atPath: fixture.store.layout.boardFile(id: boardId).path),
                   "querying a deleted board must not restore its file from a backup")
        print("board-library: failed index writes roll back rename/delete without publishing or undo; permanent deletion survives a fresh runtime")
    }

    private static func runUnhydratedOwnershipCheck() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seedRuntime = BoardRuntime(projectStore: fixture.store)
        let boardId = UUID()
        let tileId = UUID()
        let farZoneId = UUID()
        guard let board = seedRuntime.createBoard(id: boardId, title: "Far board") else {
            throw Failure(description: "could not create the unhydrated ownership control")
        }
        var document = try fixture.workspaceStore.load()
        document.zones.append(ZonePlacement(zoneId: farZoneId, projectId: fixture.project.id,
                                           origin: ZonePoint(x: 90_000, y: 80_000),
                                           size: ZoneSize(width: 2_000, height: 1_500), color: "blue", collapsed: false,
                                           hydrationPolicy: .automatic))
        try fixture.workspaceStore.save(document)
        var tile = Tile(id: tileId, kind: .kanban, title: board.title,
                        frame: TileFrame(x: 90_040, y: 80_040, width: 700, height: 500),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(boardId: boardId))
        tile.zoneId = farZoneId
        var state = try fixture.store.loadCanvas()
        state.tiles.append(tile)
        try fixture.store.saveCanvas(state)
        try seedRuntime.setTileBinding(tileId, for: boardId)
        try fixture.withMountedScene { canvas, _, spawner, runtime, controller in
            try expect(!canvas.installedZoneLayerIds.contains(farZoneId),
                       "control: the distant board zone must start below the live hydration tier")
            try expect(!(canvas.tileView(for: tileId) is KanbanTileNSView),
                       "control: the distant board must not have a hydrated view")
            guard case let .existing(existing) = spawner.openSavedBoard(boardId) else {
                throw Failure(description: "opening a persisted unhydrated board must find its existing tile")
            }
            try expect(existing.id == tileId, "unhydrated ownership lookup must retain the original tile ID")
            guard case .existing = runtime.openBoard(projectId: fixture.project.id, boardId: boardId) else {
                throw Failure(description: "production board navigation did not reveal the unhydrated existing tile")
            }
            try expect((canvas.tileView(for: tileId) as? KanbanTileNSView)?.board.id == boardId,
                       "navigation must hydrate the original board tile")
            try expect(canvas.allTilesInWorldFrames().filter { $0.metadata.boardId == boardId }.map(\.id) == [tileId],
                       "revealing an unhydrated board must not spawn a replacement")
            try controller.flushCanvasSave()
            try fixture.assertUniquePersistedBoards()
        }
        print("board-library: an unhydrated distant board is found in persisted canvas data and revealed with its original tile identity")
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let support: URL
        let projectRoot: URL
        let project: Project
        let store: ProjectStore
        let workspaceStore: WorkspaceStore
        let registryStore: RegistryStore
        let workspaceId = UUID()
        let zoneId = UUID()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("array-board-library-\(UUID().uuidString)")
            support = root.appendingPathComponent("support")
            projectRoot = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            project = Project(id: UUID(), name: "Library fixture", rootPath: projectRoot.path,
                              createdAt: now, updatedAt: now, defaultLaunchProfileId: "shell", editorPreference: .auto,
                              settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                                        terminalClosePolicy: .askWhenRunning))
            store = ProjectStore(projectRoot: projectRoot)
            try store.saveProject(project)
            let viewport = CanvasViewport(x: 1_400, y: 900, zoom: 1)
            try store.saveCanvas(CanvasState(viewport: viewport, tiles: [], groups: [], lastActiveTileId: nil))
            workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: support)
            let zone = ZonePlacement(zoneId: zoneId, projectId: project.id, origin: ZonePoint(x: 1_000, y: 600),
                                     size: ZoneSize(width: 3_000, height: 2_000), color: "blue", collapsed: false,
                                     hydrationPolicy: .automatic)
            try workspaceStore.save(WorkspaceDocument(viewport: viewport, zones: [zone], zoneZOrder: [zoneId],
                                                       lastActiveZoneId: zoneId, ambientTiles: []))
            registryStore = RegistryStore(applicationSupportDirectory: support)
            var registry = Registry.empty()
            registry.lastActiveWorkspaceId = workspaceId
            registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "Library", projectIds: [project.id],
                                                   createdAt: now, updatedAt: now)]
            registry.projects = [ProjectEntry(id: project.id, name: project.name, rootPath: projectRoot.path,
                                               workspaceId: workspaceId, lastOpenedAt: now, pinned: false, missing: false)]
            try registryStore.save(registry)
        }

        func indexEntry(_ boardId: UUID) throws -> BoardIndexEntry {
            guard let entry = try ProjectStore(projectRoot: projectRoot).tryLoadBoardState()?.boards.first(where: { $0.id == boardId }) else {
                throw Failure(description: "missing durable library entry for \(boardId)")
            }
            return entry
        }

        func assertUniquePersistedBoards() throws {
            let tiles = try ProjectStore(projectRoot: projectRoot).loadCanvas().tiles.filter { $0.kind == .kanban }
            let ids = tiles.compactMap(\.metadata.boardId)
            try expect(ids.count == Set(ids).count, "persisted canvas contains duplicate tiles for a board")
            for tile in tiles {
                guard let boardId = tile.metadata.boardId else {
                    throw Failure(description: "persisted board tile has no board identity")
                }
                try expect(try indexEntry(boardId).tileId == tile.id, "index pointer disagrees with persisted tile ownership")
            }
        }

        func withMountedScene(_ body: (CanvasNSView, AppDelegate, TileSpawner, WorkspaceRuntime, ZoneRuntimeController) throws -> Void) throws {
            let browser = BrowserEngineContext()
            defer { browser.shutdown() }
            let registry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { [self] id in
                guard id == project.id else { throw Failure(description: "fixture acquired an unrelated project") }
                return ZoneRuntimeController(projectRoot: projectRoot, projectStore: store, project: project)
            })
            let document = try workspaceStore.load()
            let state = try store.loadCanvas()
            let canvas = CanvasNSView(canvasState: state, activeZone: document.zones.first,
                                      zoneRenderModels: document.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: "Library")
            })
            canvas.frame = CGRect(x: 0, y: 0, width: 1_100, height: 800)
            let delegate = AppDelegate()
            let runtime = WorkspaceRuntime(boot: try registry.acquire(projectId: project.id), workspaceId: workspaceId,
                                           document: document, registry: registry, focusBroker: delegate.qaFocusBroker,
                                           registryStore: registryStore, ghostty: nil, browserEngine: browser)
            delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browser, runtime: runtime, registryStore: registryStore)
            let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browser, projectStore: store, project: project)
            spawner.boardRuntimeProvider = { runtime.controller(for: self.project.id)?.boardRuntime }
            try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: store,
                                                   canvasState: state, installsGlobalEventMonitors: false)
            canvas.layoutSubtreeIfNeeded()
            guard let controller = runtime.controller(for: project.id) else {
                throw Failure(description: "production mount did not acquire the project controller")
            }
            try body(canvas, delegate, spawner, runtime, controller)
        }
    }

    private final class FailingIndexStore: ProjectStoring, @unchecked Sendable {
        enum StoreError: Error { case saveBoardIndexFailed }
        private let base: ProjectStore
        var rejectIndexWrites = false
        init(base: ProjectStore) { self.base = base }
        func saveProject(_ project: Project) throws { try base.saveProject(project) }
        func loadProject() throws -> Project { try base.loadProject() }
        func tryLoadProject() throws -> Project? { try base.tryLoadProject() }
        func saveCanvas(_ canvas: CanvasState) throws { try base.saveCanvas(canvas) }
        func loadCanvas() throws -> CanvasState { try base.loadCanvas() }
        func loadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult { try base.loadCanvasWithSanitizationResult() }
        func tryLoadCanvas() throws -> CanvasState? { try base.tryLoadCanvas() }
        func tryLoadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult? { try base.tryLoadCanvasWithSanitizationResult() }
        func saveSession(_ descriptor: TerminalSessionDescriptor) throws { try base.saveSession(descriptor) }
        func loadSession(id: UUID) throws -> TerminalSessionDescriptor { try base.loadSession(id: id) }
        func deleteSession(id: UUID) throws { try base.deleteSession(id: id) }
        func listSessions() throws -> [TerminalSessionDescriptor] { try base.listSessions() }
        func saveBrowserState(_ state: BrowserState) throws { try base.saveBrowserState(state) }
        func loadBrowserState() throws -> BrowserState { try base.loadBrowserState() }
        func tryLoadBrowserState() throws -> BrowserState? { try base.tryLoadBrowserState() }
        func browserStateFileExists() -> Bool { base.browserStateFileExists() }
        func saveFileTreeState(_ state: FileTreeState) throws { try base.saveFileTreeState(state) }
        func loadFileTreeState() throws -> FileTreeState { try base.loadFileTreeState() }
        func tryLoadFileTreeState() throws -> FileTreeState? { try base.tryLoadFileTreeState() }
        func fileTreeStateFileExists() -> Bool { base.fileTreeStateFileExists() }
        func saveBoardState(_ state: BoardState) throws {
            if rejectIndexWrites { throw StoreError.saveBoardIndexFailed }
            try base.saveBoardState(state)
        }
        func tryLoadBoardState() throws -> BoardState? { try base.tryLoadBoardState() }
        func saveBoard(_ board: Board) throws { try base.saveBoard(board) }
        func tryLoadBoard(id: UUID) throws -> Board? { try base.tryLoadBoard(id: id) }
        func deleteBoard(id: UUID) throws { try base.deleteBoard(id: id) }
        func saveNoteState(_ state: NoteState) throws { try base.saveNoteState(state) }
        func loadNoteState() throws -> NoteState { try base.loadNoteState() }
        func tryLoadNoteState() throws -> NoteState? { try base.tryLoadNoteState() }
        func saveNoteBody(id: UUID, text: String) throws { try base.saveNoteBody(id: id, text: text) }
        func loadNoteBody(id: UUID) throws -> String { try base.loadNoteBody(id: id) }
        func tryLoadNoteBody(id: UUID) -> String? { base.tryLoadNoteBody(id: id) }
        func deleteNoteBody(id: UUID) throws { try base.deleteNoteBody(id: id) }
        func saveReviewCommentState(_ state: ReviewCommentState) throws { try base.saveReviewCommentState(state) }
        func loadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState { try base.loadReviewCommentState(reviewId: reviewId) }
        func tryLoadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState? { try base.tryLoadReviewCommentState(reviewId: reviewId) }
        func deleteReviewCommentState(reviewId: UUID) throws { try base.deleteReviewCommentState(reviewId: reviewId) }
    }
}
